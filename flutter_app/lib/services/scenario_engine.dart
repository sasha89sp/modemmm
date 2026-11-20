import 'dart:async';
import '../models/app_settings.dart';
import '../models/modem_models.dart';
import '../models/scenario_models.dart';
import 'database_service.dart';
import 'excel_exporter.dart';
import 'huawei_e173_service.dart';
import 'ucs2_codec.dart';
import 'voice_service.dart';

/// Движок пошагового выполнения сценариев Huawei E173:
/// - кэширование USSD-ответов в рамках одного прогона;
/// - раздельный разбор номера и баланса из комбинированных ответов;
/// - ожидание входящего SMS с таймаутом и фильтром отправителя;
/// - проверка минимального порога баланса перед отправкой SMS;
/// - голосовой вызов с действиями по секундам (фраза или DTMF);
/// - сверка первого и последнего баланса (СОВПАЛ / НЕ СОВПАЛ) + запись в SQLite и Excel.
class ScenarioEngine {
  final HuaweiE173Service modem;
  final DatabaseService db;
  final VoiceService voice;
  final Future<int> Function() syncSmsNow;
  final void Function(String line)? onProgress;

  bool _running = false;
  bool _cancelRequested = false;

  ScenarioEngine({
    required this.modem,
    required this.db,
    required this.voice,
    required this.syncSmsNow,
    this.onProgress,
  });

  bool get isRunning => _running;

  void requestCancel() {
    _cancelRequested = true;
  }

  Future<(ScenarioRunRecord, ExcelExportResult?)> runScenario({
    required ScenarioDefinition scenario,
    required ModemSnapshot snapshot,
    required AppSettings settings,
  }) async {
    if (_running) {
      throw StateError('Другой сценарий уже выполняется.');
    }
    _running = true;
    _cancelRequested = false;

    final sw = Stopwatch()..start();
    final startedAt = DatabaseService.nowIso();
    final ussdCache = <String, String>{};
    final errors = <String>[];
    final stepNotes = <String>[];

    String detectedPhone = '';
    double? firstBalance;
    double? lastBalance;
    bool aborted = false;

    void recordBalance(double val) {
      firstBalance ??= val;
      lastBalance = val;
    }

    onProgress?.call('Запуск сценария «${scenario.name}» (${scenario.steps.length} шагов)...');

    try {
      for (var i = 0; i < scenario.steps.length; i++) {
        if (_cancelRequested) {
          aborted = true;
          errors.add('Остановлено пользователем на шаге ${i + 1}');
          break;
        }
        final step = scenario.steps[i];
        final stepLabel = step.title.isNotEmpty ? step.title : step.type.label;
        onProgress?.call('[${i + 1}/${scenario.steps.length}] $stepLabel');

        try {
          switch (step.type) {
            case ScenarioStepType.detectOwnNumberUssd:
              final cacheKey = '${step.ussdCode}|${step.ussdDcs}';
              final reply = ussdCache.containsKey(cacheKey)
                  ? ussdCache[cacheKey]!
                  : await modem.sendUssd(step.ussdCode, dcs: step.ussdDcs);
              ussdCache[cacheKey] = reply;

              final phone = Ucs2Codec.extractPhoneNumber(reply);
              final bal = Ucs2Codec.extractBalance(reply);
              if (phone != null) detectedPhone = phone;
              if (bal != null) recordBalance(bal);

              stepNotes.add(
                'Номер(${step.ussdCode}): ${phone ?? 'не найден'}${bal != null ? ', баланс=$bal' : ''}',
              );
              onProgress?.call('  Ответ: $reply');
              if (phone == null) {
                throw StateError('Номер не найден в USSD-ответе (${step.ussdCode})');
              }
              break;

            case ScenarioStepType.customUssd:
              final reply = await modem.sendUssd(step.ussdCode, dcs: step.ussdDcs);
              ussdCache['${step.ussdCode}|${step.ussdDcs}'] = reply;
              stepNotes.add('USSD(${step.ussdCode}): ${_trim(reply, 60)}');
              onProgress?.call('  Ответ: $reply');
              if (reply.contains('+CME ERROR')) {
                throw StateError(reply);
              }
              break;

            case ScenarioStepType.checkBalanceUssd:
              final cacheKey = '${step.ussdCode}|${step.ussdDcs}';
              // Для первой проверки можно использовать кэш, для повторной всегда опрашиваем сеть
              final useCache = firstBalance == null && ussdCache.containsKey(cacheKey);
              final reply = useCache
                  ? ussdCache[cacheKey]!
                  : await modem.sendUssd(step.ussdCode, dcs: step.ussdDcs);
              ussdCache[cacheKey] = reply;
              onProgress?.call('  USSD баланс: $reply');

              var bal = Ucs2Codec.extractBalance(reply);
              final phoneInReply = Ucs2Codec.extractPhoneNumber(reply);
              if (detectedPhone.isEmpty && phoneInReply != null) {
                detectedPhone = phoneInReply;
              }

              // Если сумма не пришла в USSD — ждём входящее SMS с балансом
              if (bal == null && step.waitSmsIfNoBalance) {
                onProgress?.call(
                  '  Сумма в USSD не найдена, ожидание SMS (${step.smsWaitTimeoutSec} сек)...',
                );
                final smsBal = await _waitBalanceFromSms(
                  timeoutSec: step.smsWaitTimeoutSec,
                  senderFilter: step.smsSenderFilter,
                );
                if (smsBal != null) {
                  bal = smsBal.$1;
                  onProgress?.call('  Баланс из SMS (${smsBal.$2}): $bal');
                }
              }

              if (bal != null) {
                recordBalance(bal);
                stepNotes.add('Баланс: ${bal.toStringAsFixed(2)}');
              } else {
                stepNotes.add('Баланс: не распознан');
                throw StateError('Не удалось извлечь баланс (${step.ussdCode})');
              }
              break;

            case ScenarioStepType.sendSms:
              if (step.checkMinBalance) {
                final currentBal = lastBalance ?? firstBalance;
                if (currentBal == null || currentBal < step.minBalanceThreshold) {
                  throw StateError(
                    'Баланс (${currentBal?.toStringAsFixed(2) ?? 'неизвестен'}) ниже порога ${step.minBalanceThreshold}',
                  );
                }
              }
              final ok = await modem.sendSms(
                phone: step.smsRecipient,
                message: step.smsBody,
                requestDeliveryReport: settings.requestSmsDeliveryReport,
              );
              if (!ok) {
                throw StateError('Ошибка отправки SMS на ${step.smsRecipient}');
              }
              db.insertSmsIfNew(
                simImsi: snapshot.imsi,
                folder: 'sent',
                address: step.smsRecipient,
                body: step.smsBody,
                timestamp: DatabaseService.nowIso(),
                isRead: true,
                deliveryStatus:
                    settings.requestSmsDeliveryReport ? 'Запрошен отчёт' : 'Отправлено',
              );
              stepNotes.add('SMS -> ${step.smsRecipient}: OK');
              onProgress?.call('  SMS отправлено на ${step.smsRecipient}');
              break;

            case ScenarioStepType.pause:
              onProgress?.call('  Пауза ${step.pauseSec} сек...');
              for (var s = 0; s < step.pauseSec; s++) {
                if (_cancelRequested) break;
                await Future.delayed(const Duration(seconds: 1));
              }
              stepNotes.add('Пауза ${step.pauseSec}с');
              break;

            case ScenarioStepType.voiceCall:
              final dialed = await modem.dialVoice(step.callNumber);
              if (!dialed) {
                throw StateError('Не удалось набрать ${step.callNumber}');
              }
              onProgress?.call(
                '  Вызов ${step.callNumber} (${step.callDurationSec} сек)...',
              );
              try {
                for (var sec = 1; sec <= step.callDurationSec; sec++) {
                  if (_cancelRequested) break;
                  await Future.delayed(const Duration(seconds: 1));
                  final dueActions =
                      step.callActions.where((a) => a.atSecond == sec).toList();
                  for (final act in dueActions) {
                    if (act.kind == 'dtmf') {
                      onProgress?.call('  [${sec}с] DTMF: ${act.value}');
                      await modem.sendDtmf(act.value);
                    } else if (act.kind == 'phrase') {
                      onProgress?.call('  [${sec}с] Фраза: ${act.value}');
                      await voice.playPhraseIntoCall(
                        filePathOrName: act.value,
                        voiceComPort: settings.preferredVoicePort,
                      );
                    }
                  }
                }
              } finally {
                await modem.hangupCall();
              }
              stepNotes.add('Звонок ${step.callNumber} (${step.callDurationSec}с)');
              break;

            case ScenarioStepType.sendDtmf:
              await modem.sendDtmf(step.dtmfDigits);
              stepNotes.add('DTMF(${step.dtmfDigits})');
              onProgress?.call('  Отправлен DTMF: ${step.dtmfDigits}');
              break;
          }
        } catch (e) {
          final errMsg = 'Шаг ${i + 1} ($stepLabel): $e';
          errors.add(errMsg);
          onProgress?.call('  ОШИБКА: $errMsg');
          if (scenario.stopOnError) {
            aborted = true;
            break;
          }
        }
      }
    } finally {
      sw.stop();
      _running = false;
    }

    double? diff;
    String matchStatus = 'Н/Д';
    if (firstBalance != null && lastBalance != null) {
      diff = double.parse((lastBalance - firstBalance).toStringAsFixed(2));
      matchStatus = diff.abs() < 0.005 ? 'СОВПАЛ' : 'НЕ СОВПАЛ';
    }

    final status = aborted
        ? 'ПРЕРВАН'
        : (errors.isEmpty ? 'УСПЕШНО' : 'С ОШИБКАМИ');

    final run = ScenarioRunRecord(
      id: 0,
      startedAt: startedAt,
      scenarioName: scenario.name,
      operatorName: snapshot.operatorName,
      phoneNumber: detectedPhone,
      imei: snapshot.imei,
      imsi: snapshot.imsi,
      firstBalance: firstBalance,
      lastBalance: lastBalance,
      balanceDiff: diff,
      balanceMatchStatus: matchStatus,
      status: status,
      durationSec: sw.elapsed.inSeconds,
      errorText: errors.join(' | '),
      stepSummary: stepNotes.join('; '),
    );

    final runId = db.insertScenarioRun(run);
    db.logOperation(
      'Сценарий',
      scenario.name,
      status,
      'Баланс: $firstBalance -> $lastBalance ($matchStatus). ${errors.isEmpty ? '' : errors.join('; ')}',
    );

    ExcelExportResult? excelRes;
    try {
      final allRuns = db.getScenarioRuns(ascending: true);
      excelRes = await ExcelExporter.rebuildFromRuns(
        runs: allRuns,
        columns: settings.excelColumns,
      );
      onProgress?.call(
        excelRes.usedBackup
            ? 'Excel был занят — сохранена резервная копия: ${excelRes.savedPath}'
            : 'Excel обновлён: ${excelRes.savedPath}',
      );
    } catch (e) {
      onProgress?.call('Ошибка записи Excel: $e');
    }

    final savedRun = ScenarioRunRecord(
      id: runId,
      startedAt: run.startedAt,
      scenarioName: run.scenarioName,
      operatorName: run.operatorName,
      phoneNumber: run.phoneNumber,
      imei: run.imei,
      imsi: run.imsi,
      firstBalance: run.firstBalance,
      lastBalance: run.lastBalance,
      balanceDiff: run.balanceDiff,
      balanceMatchStatus: run.balanceMatchStatus,
      status: run.status,
      durationSec: run.durationSec,
      errorText: run.errorText,
      stepSummary: run.stepSummary,
    );

    return (savedRun, excelRes);
  }

  Future<(double, String)?> _waitBalanceFromSms({
    required int timeoutSec,
    required String senderFilter,
  }) async {
    final beforeIds =
        db.getMessages(folder: 'inbox').map((m) => m.id).toSet();
    final deadline = DateTime.now().add(Duration(seconds: timeoutSec));

    while (DateTime.now().isBefore(deadline) && !_cancelRequested) {
      await Future.delayed(const Duration(seconds: 3));
      await syncSmsNow();
      final inbox = db.getMessages(folder: 'inbox');
      for (final msg in inbox) {
        if (beforeIds.contains(msg.id)) continue;
        if (senderFilter.trim().isNotEmpty &&
            !msg.address
                .toLowerCase()
                .contains(senderFilter.trim().toLowerCase())) {
          continue;
        }
        final bal = Ucs2Codec.extractBalance(msg.body);
        if (bal != null) {
          return (bal, msg.address);
        }
      }
    }
    return null;
  }

  static String _trim(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}...';
}
