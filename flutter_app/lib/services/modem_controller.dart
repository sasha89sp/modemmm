import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/app_settings.dart';
import '../models/modem_models.dart';
import '../models/scenario_models.dart';
import 'app_paths.dart';
import 'database_service.dart';
import 'excel_exporter.dart';
import 'huawei_e173_service.dart';
import 'ras_dialer.dart';
import 'scenario_engine.dart';
import 'voice_service.dart';
import 'win32_serial.dart';
import 'winmm_audio.dart';

class _LoopStats {
  int lastMs = 0;
  int maxMs = 0;
  int totalMs = 0;
  int count = 0;

  void record(int ms) {
    lastMs = ms;
    if (ms > maxMs) maxMs = ms;
    totalMs += ms;
    count++;
  }

  double get avgMs => count == 0 ? 0 : totalMs / count;
}

/// Главный координатор приложения:
/// - USB Hotplug (мгновенное освобождение при извлечении и автопереподключение при возврате);
/// - адаптивные интервалы (активный / простой / свёрнуто / 60с при отсутствии SIM);
/// - пропуск перерисовок при неизменном снимке состояния;
/// - автосинхронизация SMS (+CMTI и расписание) + звуковое оповещение winmm.dll;
/// - автозапуск сценариев при регистрации в сети с защитой от повтора в сессии;
/// - телеметрия длительности фоновых циклов DIAG.
class ModemController extends ChangeNotifier {
  final DatabaseService db = DatabaseService();
  final WinmmAudio audio = WinmmAudio();
  late final Win32SerialPort serial;
  late final HuaweiE173Service modem;
  late final VoiceService voice;
  late final ScenarioEngine scenarioEngine;

  AppSettings settings = AppSettings();
  List<ComPortInfo> ports = [];
  String? selectedPort;
  ModemSnapshot snapshot = const ModemSnapshot();
  SmsDiagnostics smsDiag = const SmsDiagnostics();
  List<ActiveCallInfo> activeCalls = [];
  List<SimContact> contacts = [];
  List<ScenarioDefinition> scenarios = [];
  List<ScenarioRunRecord> scenarioRuns = [];
  List<VoicePhraseItem> voicePhrases = [];

  final List<String> liveAtLines = [];
  final List<String> scenarioProgressLog = [];

  String? incomingCallerNumber;
  String rasStatus = 'Отключено';
  String? lastToastMessage;
  bool busy = false;
  bool initialized = false;

  // Энергосбережение и состояние окна
  bool _windowHiddenOrMinimized = false;
  DateTime _lastUserActivity = DateTime.now();

  // Таймеры фоновых циклов
  Timer? _usbWatchTimer;
  Timer? _urcPollTimer;
  Timer? _statusLoopTimer;
  Timer? _smsLoopTimer;

  Set<String> _knownPortNames = {};
  final Set<String> _autoRunCompletedSessions = {};
  bool _manualDisconnected = false;

  // DIAG метрики циклов
  final _usbStats = _LoopStats();
  final _statusStats = _LoopStats();
  final _smsStats = _LoopStats();

  ModemController() {
    serial = Win32SerialPort(
      onUnexpectedDisconnect: _handleUnexpectedUsbDisconnect,
      onUnsolicitedLine: _handleUnsolicitedLine,
    );
    modem = HuaweiE173Service(serial, onLog: _handleAtLog);
    voice = VoiceService(audio, onChanged: notifyListeners);
    scenarioEngine = ScenarioEngine(
      modem: modem,
      db: db,
      voice: voice,
      syncSmsNow: () => syncSmsFromModem(silent: true),
      onProgress: (line) {
        scenarioProgressLog.insert(0, '[${DatabaseService.nowIso().substring(11)}] $line');
        if (scenarioProgressLog.length > 300) scenarioProgressLog.removeLast();
        notifyListeners();
      },
    );
  }

  int get unreadSmsCount => initialized ? db.getUnreadInboxCount() : 0;
  bool get isWindowHidden => _windowHiddenOrMinimized;
  bool get isIdle =>
      DateTime.now().difference(_lastUserActivity).inSeconds >= 90;

  int get currentStatusIntervalSec {
    if (snapshot.simMissing) return 60;
    if (_windowHiddenOrMinimized) return settings.hiddenPollSec;
    if (isIdle) return settings.idlePollSec;
    return settings.activePollSec;
  }

  List<DiagMetric> get diagMetrics => [
        DiagMetric(
          loopName: 'USB Hotplug сканер',
          lastDurationMs: _usbStats.lastMs,
          avgDurationMs: _usbStats.avgMs,
          maxDurationMs: _usbStats.maxMs,
          executions: _usbStats.count,
          currentIntervalSec: _windowHiddenOrMinimized ? 6 : 3,
          stateNote: _windowHiddenOrMinimized ? 'Окно скрыто' : 'Активен',
        ),
        DiagMetric(
          loopName: 'Мониторинг модема/сети',
          lastDurationMs: _statusStats.lastMs,
          avgDurationMs: _statusStats.avgMs,
          maxDurationMs: _statusStats.maxMs,
          executions: _statusStats.count,
          currentIntervalSec: currentStatusIntervalSec,
          stateNote: snapshot.simMissing
              ? 'SIM не обнаружена (60с)'
              : (_windowHiddenOrMinimized
                  ? 'Свёрнуто (${settings.hiddenPollSec}с)'
                  : (isIdle
                      ? 'Простой (${settings.idlePollSec}с)'
                      : 'Активный (${settings.activePollSec}с)')),
        ),
        DiagMetric(
          loopName: 'Синхронизация PDU SMS',
          lastDurationMs: _smsStats.lastMs,
          avgDurationMs: _smsStats.avgMs,
          maxDurationMs: _smsStats.maxMs,
          executions: _smsStats.count,
          currentIntervalSec: settings.smsPollIntervalSec,
          stateNote: snapshot.simMissing
              ? 'Отключено (нет SIM)'
              : (settings.autoFetchSms ? 'Авто + +CMTI' : 'Только вручную'),
        ),
      ];

  void markUserActivity() {
    _lastUserActivity = DateTime.now();
  }

  void setWindowHidden(bool hidden) {
    if (_windowHiddenOrMinimized == hidden) return;
    _windowHiddenOrMinimized = hidden;
    _rescheduleStatusLoop();
    notifyListeners();
  }

  Future<void> init() async {
    await AppPaths.ensureDirectories();
    settings = await AppSettings.load();
    await db.init();
    scenarios = db.getScenarios();
    scenarioRuns = db.getScenarioRuns();
    voicePhrases = await voice.listPhrases();
    initialized = true;

    await scanPorts();
    if (settings.autoConnect && selectedPort != null) {
      await connectPort(selectedPort!, isAuto: true);
    }

    _startBackgroundLoops();
    notifyListeners();
  }

  Future<void> shutdown() async {
    _usbWatchTimer?.cancel();
    _urcPollTimer?.cancel();
    _statusLoopTimer?.cancel();
    _smsLoopTimer?.cancel();
    voice.dispose();
    audio.dispose();
    serial.close();
    db.close();
  }

  void _emitToast(String msg) {
    lastToastMessage = msg;
    notifyListeners();
  }

  void clearToast() {
    lastToastMessage = null;
    notifyListeners();
  }

  void _handleAtLog(String dir, String line) {
    final ts = DatabaseService.nowIso().substring(11);
    liveAtLines.insert(0, '[$ts] $dir  $line');
    if (liveAtLines.length > 350) liveAtLines.removeLast();
    if (initialized) {
      db.logSystem(dir, line);
    }
    if (!_windowHiddenOrMinimized) {
      notifyListeners();
    }
  }

  // ---------------- USB Hotplug & Port Management ----------------

  Future<void> scanPorts() async {
    final found = await Win32SerialPort.scanPorts();
    ports = found;
    _knownPortNames = found.map((e) => e.port).toSet();

    // Выбор основного COM-порта с учётом предпочтительного
    if (settings.preferredPort.isNotEmpty &&
        found.any((p) => p.port == settings.preferredPort)) {
      selectedPort = settings.preferredPort;
    } else if (selectedPort == null ||
        !found.any((p) => p.port == selectedPort)) {
      selectedPort = found.isNotEmpty ? found.first.port : null;
    }

    // Автоподбор звукового COM-порта при первом подключении
    if (settings.preferredVoicePort.isEmpty) {
      final voiceCandidate = found
          .where((p) => p.isHuaweiVoiceCandidate && p.port != selectedPort)
          .toList();
      if (voiceCandidate.isNotEmpty) {
        settings.preferredVoicePort = voiceCandidate.first.port;
        await settings.save();
      }
    }

    notifyListeners();
  }

  Future<void> connectPort(String port, {bool isAuto = false}) async {
    if (serial.isOpen && serial.portName == port) return;
    busy = true;
    _manualDisconnected = false;
    notifyListeners();

    try {
      serial.open(port, baudRate: settings.baudRate);
      selectedPort = port;
      if (!isAuto && settings.preferredPort != port) {
        settings.preferredPort = port;
        await settings.save();
      }

      await modem.initialize();
      final next = await modem.pollSnapshot(
        current: snapshot.copyWith(connected: true, port: port),
        fetchStaticInfo: true,
      );
      _applySnapshotIfChanged(next);
      db.logOperation('Подключение', 'Открыт порт $port', 'OK',
          '${next.model} · ${next.imei} · ${next.simStatus}');
      _emitToast('Подключено к $port (${next.model})');

      if (!next.simMissing) {
        await refreshSmsDiagnostics();
        if (settings.autoFetchSms) {
          unawaited(syncSmsFromModem(silent: true));
        }
        _maybeAutoRunScenarios();
      }
      _rescheduleStatusLoop();
    } catch (e) {
      serial.close();
      _applySnapshotIfChanged(const ModemSnapshot());
      db.logSystem('ERR', 'Ошибка подключения к $port: $e');
      if (!isAuto) _emitToast('Ошибка подключения: $e');
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  void disconnectPort({bool manual = true}) {
    _manualDisconnected = manual;
    voice.stopVoiceBridge();
    final prevPort = serial.portName;
    serial.close();
    incomingCallerNumber = null;
    activeCalls = [];
    _applySnapshotIfChanged(const ModemSnapshot());
    if (prevPort != null) {
      db.logOperation('Подключение', 'Закрыт порт $prevPort', 'OK');
    }
    notifyListeners();
  }

  void _handleUnexpectedUsbDisconnect(String reason) {
    voice.stopVoiceBridge();
    incomingCallerNumber = null;
    activeCalls = [];
    _applySnapshotIfChanged(const ModemSnapshot());
    db.logSystem('WARN', 'Мгновенное освобождение порта: $reason');
    db.logOperation('USB Hotplug', 'Модем извлечён', 'Отключён', reason);
    _emitToast('Модем извлечён из USB — порт освобождён.');
    notifyListeners();
  }

  void _handleUnsolicitedLine(String line) {
    if (line.startsWith('+CMTI:')) {
      smsDiag = SmsDiagnostics(
        cnmi: smsDiag.cnmi,
        cpms: smsDiag.cpms,
        cmtiCount: smsDiag.cmtiCount + 1,
        lastSyncAt: smsDiag.lastSyncAt,
      );
      db.logSystem('INFO', 'Получено уведомление о новой SMS: $line');
      if (settings.autoFetchSms && !snapshot.simMissing) {
        unawaited(syncSmsFromModem(silent: false));
      }
      notifyListeners();
    } else if (line == 'RING') {
      incomingCallerNumber ??= 'Входящий вызов...';
      notifyListeners();
    } else if (line.startsWith('+CLIP:')) {
      final m = RegExp(r'\+CLIP:\s*"([^"]+)"').firstMatch(line);
      if (m != null) {
        incomingCallerNumber = m.group(1);
        notifyListeners();
      }
    } else if (line.startsWith('^CEND:')) {
      incomingCallerNumber = null;
      voice.stopVoiceBridge();
      notifyListeners();
    }
  }

  void _applySnapshotIfChanged(ModemSnapshot next) {
    if (next == snapshot) return;
    final wasRegistered = snapshot.isRegistered;
    final wasMissingSim = snapshot.simMissing;
    snapshot = next;
    if (wasMissingSim != next.simMissing) {
      _rescheduleStatusLoop();
    }
    if (!wasRegistered && next.isRegistered && !next.simMissing) {
      _maybeAutoRunScenarios();
    }
    notifyListeners();
  }

  // ---------------- Background Adaptive Loops + DIAG ----------------

  void _startBackgroundLoops() {
    // 1. Быстрый перехват URC (+CMTI / RING) и проверка живости дескриптора
    _urcPollTimer?.cancel();
    _urcPollTimer = Timer.periodic(const Duration(milliseconds: 600), (_) {
      if (serial.isOpen && !serial.isBusy && !scenarioEngine.isRunning) {
        serial.pollUnsolicited();
      }
    });

    // 2. USB Hotplug цикл (появление/исчезновение COM-портов)
    _usbWatchTimer?.cancel();
    _usbWatchTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      final sw = Stopwatch()..start();
      try {
        final currentNames = await Win32SerialPort.listQuickPortNames();
        // Если текущий открытый порт исчез из реестра — мгновенно освобождаем
        if (serial.isOpen &&
            serial.portName != null &&
            !currentNames.contains(serial.portName)) {
          _handleUnexpectedUsbDisconnect(
              'Порт ${serial.portName} исчез из системы');
        }

        final changed = currentNames.length != _knownPortNames.length ||
            !currentNames.containsAll(_knownPortNames);
        if (changed) {
          _knownPortNames = currentNames;
          await scanPorts();

          // Автоподключение при возврате/появлении USB-модема
          if (!serial.isOpen &&
              !_manualDisconnected &&
              settings.autoConnect &&
              selectedPort != null &&
              currentNames.contains(selectedPort)) {
            await connectPort(selectedPort!, isAuto: true);
          }
        }
      } finally {
        sw.stop();
        _usbStats.record(sw.elapsedMilliseconds);
      }
    });

    _rescheduleStatusLoop();
    _rescheduleSmsLoop();
  }

  void _rescheduleStatusLoop() {
    _statusLoopTimer?.cancel();
    final sec = currentStatusIntervalSec;
    _statusLoopTimer = Timer.periodic(Duration(seconds: sec), (_) async {
      if (!serial.isOpen || serial.isBusy || scenarioEngine.isRunning) return;
      final sw = Stopwatch()..start();
      try {
        if (!serial.checkAlive()) return;
        if (snapshot.simMissing) {
          // Режим «SIM не обнаружена»: только редкая проверка наличия SIM раз в 60с
          final present = await modem.checkSimPresent();
          if (present) {
            final full = await modem.pollSnapshot(
              current: snapshot,
              fetchStaticInfo: true,
            );
            _applySnapshotIfChanged(full);
          }
        } else {
          final next = await modem.pollSnapshot(current: snapshot);
          _applySnapshotIfChanged(next);
        }
      } catch (e) {
        db.logSystem('DIAG', 'Ошибка фонового опроса: $e');
      } finally {
        sw.stop();
        _statusStats.record(sw.elapsedMilliseconds);
        db.logSystem('DIAG', 'StatusLoop ${sw.elapsedMilliseconds}ms (интервал ${sec}с)');
      }
    });
  }

  void _rescheduleSmsLoop() {
    _smsLoopTimer?.cancel();
    final sec = settings.smsPollIntervalSec.clamp(10, 600);
    _smsLoopTimer = Timer.periodic(Duration(seconds: sec), (_) async {
      if (!serial.isOpen ||
          !settings.autoFetchSms ||
          snapshot.simMissing ||
          serial.isBusy ||
          scenarioEngine.isRunning) {
        return;
      }
      await syncSmsFromModem(silent: false);
    });
  }

  // ---------------- SMS Sync & Sound ----------------

  Future<int> syncSmsFromModem({bool silent = false}) async {
    if (!serial.isOpen || snapshot.simMissing) return 0;
    final sw = Stopwatch()..start();
    var addedCount = 0;
    try {
      final assembled = await modem.readAllSmsPdu();
      for (final msg in assembled) {
        final inserted = db.insertSmsIfNew(
          simImsi: snapshot.imsi,
          folder: msg.folder,
          address: msg.address,
          body: msg.body,
          timestamp: msg.timestamp.isNotEmpty
              ? msg.timestamp
              : DatabaseService.nowIso(),
          isRead: msg.folder == 'sent' ? true : msg.isRead,
          modemIndex:
              msg.modemIndices.isNotEmpty ? msg.modemIndices.first : null,
        );
        if (inserted && msg.folder == 'inbox') {
          addedCount++;
        }
        if (settings.deleteSmsFromModemAfterSave) {
          for (final idx in msg.modemIndices) {
            await modem.deleteSmsFromModem(idx);
          }
        }
      }

      smsDiag = SmsDiagnostics(
        cnmi: smsDiag.cnmi,
        cpms: smsDiag.cpms,
        cmtiCount: smsDiag.cmtiCount,
        lastSyncAt: DateTime.now(),
      );

      if (addedCount > 0 && !silent && settings.smsSoundEnabled) {
        audio.playSmsNotification(volume: settings.smsSoundVolume);
      }
      if (addedCount > 0) {
        db.logOperation('SMS', 'Синхронизация PDU', 'Новых: $addedCount');
        notifyListeners();
      }
    } catch (e) {
      db.logSystem('ERR', 'Ошибка синхронизации SMS: $e');
    } finally {
      sw.stop();
      _smsStats.record(sw.elapsedMilliseconds);
    }
    return addedCount;
  }

  Future<void> refreshSmsDiagnostics() async {
    if (!serial.isOpen) return;
    final (cnmi, cpms) = await modem.querySmsDiagnostics();
    smsDiag = SmsDiagnostics(
      cnmi: cnmi,
      cpms: cpms,
      cmtiCount: smsDiag.cmtiCount,
      lastSyncAt: smsDiag.lastSyncAt,
    );
    notifyListeners();
  }

  Future<bool> sendSmsAndStore(String phone, String body) async {
    if (!serial.isOpen) return false;
    final ok = await modem.sendSms(
      phone: phone,
      message: body,
      requestDeliveryReport: settings.requestSmsDeliveryReport,
    );
    if (ok) {
      db.insertSmsIfNew(
        simImsi: snapshot.imsi,
        folder: 'sent',
        address: phone.trim(),
        body: body.trim(),
        timestamp: DatabaseService.nowIso(),
        isRead: true,
        deliveryStatus: settings.requestSmsDeliveryReport
            ? 'Запрошен отчёт (+CDS)'
            : 'Отправлено',
      );
      db.logOperation('SMS', 'Отправка на $phone', 'OK');
      notifyListeners();
    } else {
      db.logOperation('SMS', 'Отправка на $phone', 'Ошибка');
    }
    return ok;
  }

  Future<void> manualRefreshSnapshot() async {
    if (!serial.isOpen) return;
    final next = await modem.pollSnapshot(
      current: snapshot,
      fetchStaticInfo: true,
    );
    snapshot = next;
    notifyListeners();
  }

  void markSmsRead(List<int> ids, {bool read = true}) {
    db.markSmsRead(ids, read: read);
    notifyListeners();
  }

  void moveSmsToTrash(List<int> ids) {
    db.moveSmsToTrash(ids);
    notifyListeners();
  }

  void restoreSmsFromTrash(List<int> ids) {
    db.restoreSmsFromTrash(ids);
    notifyListeners();
  }

  void deleteSmsPermanently(List<int> ids) {
    db.deleteSmsPermanently(ids);
    notifyListeners();
  }

  // ---------------- Scenarios Auto-Run & Manual Run ----------------

  void _maybeAutoRunScenarios() {
    if (snapshot.simMissing || !snapshot.isRegistered || scenarioEngine.isRunning) {
      return;
    }
    final sessionKey = '${snapshot.imei}|${snapshot.imsi}';
    if (_autoRunCompletedSessions.contains(sessionKey)) return;

    final eligible = scenarios.where((s) {
      if (!s.autoRunOnRegister) return false;
      if (s.operatorFilter.trim().isEmpty) return true;
      return snapshot.operatorName
          .toLowerCase()
          .contains(s.operatorFilter.trim().toLowerCase());
    }).toList();

    if (eligible.isEmpty) return;
    _autoRunCompletedSessions.add(sessionKey);

    unawaited(() async {
      for (final sc in eligible) {
        if (!serial.isOpen) break;
        await executeScenario(sc);
      }
    }());
  }

  Future<(ScenarioRunRecord, ExcelExportResult?)> executeScenario(
    ScenarioDefinition scenario,
  ) async {
    scenarioProgressLog.clear();
    notifyListeners();
    final res = await scenarioEngine.runScenario(
      scenario: scenario,
      snapshot: snapshot,
      settings: settings,
    );
    scenarioRuns = db.getScenarioRuns();
    notifyListeners();
    return res;
  }

  void saveScenario(ScenarioDefinition sc) {
    db.upsertScenario(sc);
    scenarios = db.getScenarios();
    notifyListeners();
  }

  void deleteScenario(String id) {
    db.deleteScenario(id);
    scenarios = db.getScenarios();
    notifyListeners();
  }

  Future<ExcelExportResult> rebuildExcelNow() async {
    final allRuns = db.getScenarioRuns(ascending: true);
    final res = await ExcelExporter.rebuildFromRuns(
      runs: allRuns,
      columns: settings.excelColumns,
    );
    db.logOperation(
      'Excel',
      'Пересборка таблицы из БД',
      res.usedBackup ? 'Резервная копия' : 'OK',
      res.savedPath,
    );
    notifyListeners();
    return res;
  }

  // ---------------- Calls, Voice, Contacts, RAS ----------------

  Future<void> refreshActiveCalls() async {
    if (!serial.isOpen) return;
    activeCalls = await modem.listActiveCalls();
    notifyListeners();
  }

  Future<void> refreshContacts() async {
    if (!serial.isOpen || snapshot.simMissing) return;
    contacts = await modem.readSimContacts();
    notifyListeners();
  }

  Future<void> refreshVoicePhrases() async {
    voicePhrases = await voice.listPhrases();
    notifyListeners();
  }

  Future<void> connectRasInternet(String apn) async {
    settings.apn = apn.trim();
    await settings.save();
    if (serial.isOpen) {
      await modem.setApn(settings.apn);
    }
    rasStatus = await RasDialer.connect(
      dialNumber: settings.dialNumber,
      username: settings.rasUsername,
      password: settings.rasPassword,
    );
    db.logOperation('Интернет RAS', 'Подключение ($apn)', rasStatus);
    notifyListeners();
  }

  Future<void> disconnectRasInternet() async {
    rasStatus = await RasDialer.disconnect();
    db.logOperation('Интернет RAS', 'Отключение', rasStatus);
    notifyListeners();
  }

  Future<void> saveSettings() async {
    await settings.save();
    _rescheduleStatusLoop();
    _rescheduleSmsLoop();
    notifyListeners();
  }
}
