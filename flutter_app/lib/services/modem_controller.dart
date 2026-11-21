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
/// - Мгновенный запуск UI (initLocal) + асинхронная инициализация портов (startHardwareAndLoops);
/// - USB Hotplug (мгновенное освобождение при извлечении и автопереподключение при возврате);
/// - адаптивные интервалы (активный / простой / свёрнуто / 60с при отсутствии SIM);
/// - кэширование счётчика непрочитанных SMS и пропуск лишних перерисовок UI;
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
  String callStateBanner = '';
  String voiceCapabilityStatus = 'Не проверено';
  bool? voiceCapabilityEnabled;
  String rasStatus = 'Отключено';
  String? lastToastMessage;
  bool busy = false;
  bool initialized = false;
  bool _hardwareStarted = false;

  // Кэш и версии данных (исключают синхронные SQLite-запросы на каждом кадре build())
  int _unreadSmsCount = 0;
  int smsDataVersion = 0;
  int logsDataVersion = 0;

  // Энергосбережение и состояние окна
  bool _windowHiddenOrMinimized = false;
  DateTime _lastUserActivity = DateTime.now();

  // Таймеры фоновых циклов и защита от перекрытия (re-entrancy guards)
  Timer? _usbWatchTimer;
  Timer? _urcPollTimer;
  Timer? _statusLoopTimer;
  Timer? _smsLoopTimer;
  Timer? _atNotifyDebounce;

  bool _usbLoopRunning = false;
  bool _statusLoopRunning = false;
  bool _smsLoopRunning = false;
  bool _scanningPorts = false;
  bool _disposed = false;

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
    voice = VoiceService(audio, onChanged: _safeNotify);
    scenarioEngine = ScenarioEngine(
      modem: modem,
      db: db,
      voice: voice,
      syncSmsNow: () => syncSmsFromModem(silent: true),
      onProgress: (line) {
        scenarioProgressLog.insert(
          0,
          '[${DatabaseService.nowIso().substring(11)}] $line',
        );
        if (scenarioProgressLog.length > 300) scenarioProgressLog.removeLast();
        _safeNotify();
      },
    );
  }

  int get unreadSmsCount => _unreadSmsCount;
  bool get scanningPorts => _scanningPorts;
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
          stateNote: _windowHiddenOrMinimized ? 'Окно скрыто' : 'Активен (Win32 реестр)',
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

  void _safeNotify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  void _refreshUnreadCache() {
    if (!initialized) return;
    _unreadSmsCount = db.getUnreadInboxCount();
    smsDataVersion++;
  }

  void _bumpLogsVersion() {
    logsDataVersion++;
  }

  void markUserActivity() {
    final now = DateTime.now();
    if (now.difference(_lastUserActivity).inSeconds >= 2) {
      _lastUserActivity = now;
    }
  }

  void setWindowHidden(bool hidden) {
    if (_windowHiddenOrMinimized == hidden) return;
    _windowHiddenOrMinimized = hidden;
    _rescheduleStatusLoop();
    _safeNotify();
  }

  /// Фаза 1: быстрая локальная инициализация (настройки + SQLite, ~20 мс) до показа первого кадра UI.
  Future<void> initLocal() async {
    if (initialized) return;
    await AppPaths.ensureDirectories();
    settings = await AppSettings.load();
    await db.init();
    scenarios = db.getScenarios();
    scenarioRuns = db.getScenarioRuns();
    initialized = true;
    _refreshUnreadCache();
  }

  /// Фаза 2: асинхронный запуск сканирования COM-портов, автоподключения и фоновых циклов
  /// уже после того, как окно отрисовано и полностью отзывчиво.
  Future<void> startHardwareAndLoops() async {
    if (_hardwareStarted) return;
    _hardwareStarted = true;

    voicePhrases = await voice.listPhrases();
    _safeNotify();

    await scanPorts();
    _startBackgroundLoops();

    if (settings.autoConnect && selectedPort != null) {
      await connectPort(selectedPort!, isAuto: true);
    }
  }

  Future<void> shutdown() async {
    _disposed = true;
    _usbWatchTimer?.cancel();
    _urcPollTimer?.cancel();
    _statusLoopTimer?.cancel();
    _smsLoopTimer?.cancel();
    _atNotifyDebounce?.cancel();
    voice.dispose();
    audio.dispose();
    serial.close();
    db.close();
  }

  void _emitToast(String msg) {
    lastToastMessage = msg;
    _safeNotify();
  }

  void clearToast() {
    lastToastMessage = null;
  }

  void _handleAtLog(String dir, String line) {
    final ts = DatabaseService.nowIso().substring(11);
    liveAtLines.insert(0, '[$ts] $dir  $line');
    if (liveAtLines.length > 300) liveAtLines.removeLast();

    // В SQLite пишем только ошибки и важные события, чтобы фоновый опрос не нагружал диск
    if (initialized && (dir == 'ERR' || dir == 'WARN' || line.contains('ERROR'))) {
      db.logSystem(dir, line);
      _bumpLogsVersion();
    }

    // Коалесцируем обновления UI при потоке AT-строк (не чаще 4 раз/сек)
    if (!_windowHiddenOrMinimized && _atNotifyDebounce == null) {
      _atNotifyDebounce = Timer(const Duration(milliseconds: 250), () {
        _atNotifyDebounce = null;
        _safeNotify();
      });
    }
  }

  Future<String> sendManualAtCommand(String cmd) async {
    final clean = cmd.trim();
    if (clean.isEmpty || !serial.isOpen) return '';
    if (initialized) {
      db.logSystem('TX', clean);
    }
    final res = await modem.exec(clean, timeout: const Duration(seconds: 5));
    if (initialized && res.trim().isNotEmpty) {
      db.logSystem('RX', res.trim());
      _bumpLogsVersion();
    }
    _safeNotify();
    return res;
  }

  // ---------------- USB Hotplug & Port Management ----------------

  Future<void> scanPorts() async {
    if (_scanningPorts) return;
    _scanningPorts = true;
    _safeNotify();
    try {
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
    } finally {
      _scanningPorts = false;
      _safeNotify();
    }
  }

  Future<void> connectPort(String port, {bool isAuto = false}) async {
    if (busy || (serial.isOpen && serial.portName == port)) return;
    busy = true;
    _manualDisconnected = false;
    _safeNotify();

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
      db.logSystem('INFO', 'Подключён модем $port (${next.model}, ${next.simStatus})');
      _bumpLogsVersion();
      _emitToast('Подключено к $port (${next.model})');

      if (!next.simMissing) {
        await checkVoiceCapability();
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
      _bumpLogsVersion();
      if (!isAuto) _emitToast('Ошибка подключения: $e');
    } finally {
      busy = false;
      _safeNotify();
    }
  }

  void disconnectPort({bool manual = true}) {
    _manualDisconnected = manual;
    voice.stopVoiceBridge();
    final prevPort = serial.portName;
    serial.close();
    incomingCallerNumber = null;
    callStateBanner = '';
    voiceCapabilityStatus = 'Не проверено';
    voiceCapabilityEnabled = null;
    activeCalls = [];
    _applySnapshotIfChanged(const ModemSnapshot());
    if (prevPort != null) {
      db.logOperation('Подключение', 'Закрыт порт $prevPort', 'OK');
      _bumpLogsVersion();
    }
    _safeNotify();
  }

  void _handleUnexpectedUsbDisconnect(String reason) {
    voice.stopVoiceBridge();
    incomingCallerNumber = null;
    callStateBanner = '';
    activeCalls = [];
    _applySnapshotIfChanged(const ModemSnapshot());
    db.logSystem('WARN', 'Мгновенное освобождение порта: $reason');
    db.logOperation('USB Hotplug', 'Модем извлечён', 'Отключён', reason);
    _bumpLogsVersion();
    _emitToast('Модем извлечён из USB — порт освобождён.');
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
      _bumpLogsVersion();
      if (settings.autoFetchSms && !snapshot.simMissing) {
        unawaited(syncSmsFromModem(silent: false));
      }
      _safeNotify();
    } else if (line == 'RING') {
      incomingCallerNumber ??= 'Входящий вызов...';
      callStateBanner = 'Входящий вызов (RING)';
      _safeNotify();
    } else if (line.startsWith('+CLIP:')) {
      final m = RegExp(r'\+CLIP:\s*"([^"]+)"').firstMatch(line);
      if (m != null) {
        incomingCallerNumber = m.group(1);
        callStateBanner = 'Входящий вызов: ${m.group(1)}';
        _safeNotify();
      }
    } else if (line.startsWith('^ORIG:')) {
      callStateBanner = 'Набор номера (^ORIG)...';
      _safeNotify();
    } else if (line.startsWith('^CONF:')) {
      callStateBanner = 'Идут гудки (^CONF)...';
      _safeNotify();
    } else if (line.startsWith('^CONN:')) {
      callStateBanner = 'Разговор активен (^CONN)';
      db.logSystem('INFO', 'Соединение установлено: $line');
      _bumpLogsVersion();
      // На Huawei E173 обязательно активируем AT^DDSETEX=2 именно после ^CONN:
      unawaited(_activateVoiceAudioOnConnect());
      _safeNotify();
    } else if (line.startsWith('^CEND:')) {
      incomingCallerNumber = null;
      callStateBanner = '';
      activeCalls = [];
      voice.stopVoiceBridge();
      db.logSystem('INFO', 'Вызов завершён: $line');
      _bumpLogsVersion();
      _safeNotify();
    }
  }

  Future<void> _activateVoiceAudioOnConnect() async {
    if (!serial.isOpen) return;
    try {
      await modem.enableHuaweiVoiceChannel();
      final voicePort = settings.preferredVoicePort;
      if (voicePort.isNotEmpty &&
          voicePort != serial.portName &&
          !voice.isBridgeActive) {
        voice.startVoiceBridge(voicePort);
      }
      await refreshActiveCalls();
    } catch (e) {
      db.logSystem('WARN', 'Не удалось открыть аудиоканал после ^CONN: $e');
      _bumpLogsVersion();
    }
  }

  Future<void> checkVoiceCapability() async {
    if (!serial.isOpen) return;
    final (enabled, raw) = await modem.queryVoiceCapability();
    voiceCapabilityEnabled = enabled;
    voiceCapabilityStatus = enabled
        ? 'Голос включён ($raw)'
        : 'Голос отключён в прошивке ($raw)';
    _safeNotify();
  }

  Future<(bool ok, String raw)> tryEnableVoiceCapability() async {
    if (!serial.isOpen) return (false, 'Модем не подключён');
    final res = await modem.enableVoiceCapability();
    await checkVoiceCapability();
    return res;
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
    _safeNotify();
  }

  // ---------------- Background Adaptive Loops + DIAG ----------------

  void _startBackgroundLoops() {
    // 1. Быстрый неблокирующий перехват URC (+CMTI / RING) и проверка дескриптора
    _urcPollTimer?.cancel();
    _urcPollTimer = Timer.periodic(const Duration(milliseconds: 700), (_) {
      if (serial.isOpen && !serial.isBusy && !busy && !scenarioEngine.isRunning) {
        serial.pollUnsolicited();
      }
    });

    // 2. USB Hotplug цикл через прямой Win32 реестр (<0.1 мс, без запуска reg.exe)
    _usbWatchTimer?.cancel();
    _usbWatchTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (_usbLoopRunning || _disposed) return;
      _usbLoopRunning = true;
      final sw = Stopwatch()..start();
      try {
        final currentNames = await Win32SerialPort.listQuickPortNames();
        // Если текущий открытый порт исчез из реестра — мгновенно освобождаем
        if (serial.isOpen &&
            serial.portName != null &&
            !currentNames.contains(serial.portName)) {
          _handleUnexpectedUsbDisconnect(
            'Порт ${serial.portName} исчез из системы',
          );
        }

        final changed = currentNames.length != _knownPortNames.length ||
            !currentNames.containsAll(_knownPortNames);
        if (changed) {
          _knownPortNames = currentNames;
          await scanPorts();

          // Автоподключение при возврате/появлении USB-модема
          if (!serial.isOpen &&
              !busy &&
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
        _usbLoopRunning = false;
      }
    });

    _rescheduleStatusLoop();
    _rescheduleSmsLoop();
  }

  void _rescheduleStatusLoop() {
    _statusLoopTimer?.cancel();
    final sec = currentStatusIntervalSec;
    _statusLoopTimer = Timer.periodic(Duration(seconds: sec), (_) async {
      // Не дёргаем фоновые AT-команды (AT+CPIN?/COPS?) во время активного звонка
      final inActiveCall = activeCalls.isNotEmpty ||
          voice.isBridgeActive ||
          callStateBanner.isNotEmpty ||
          incomingCallerNumber != null;
      if (_statusLoopRunning ||
          _disposed ||
          busy ||
          inActiveCall ||
          !serial.isOpen ||
          serial.isBusy ||
          scenarioEngine.isRunning) {
        return;
      }
      _statusLoopRunning = true;
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
        _bumpLogsVersion();
      } finally {
        sw.stop();
        _statusStats.record(sw.elapsedMilliseconds);
        _statusLoopRunning = false;
      }
    });
  }

  void _rescheduleSmsLoop() {
    _smsLoopTimer?.cancel();
    final sec = settings.smsPollIntervalSec.clamp(10, 600).toInt();
    _smsLoopTimer = Timer.periodic(Duration(seconds: sec), (_) async {
      if (_smsLoopRunning ||
          _disposed ||
          busy ||
          !serial.isOpen ||
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
    if (!serial.isOpen || snapshot.simMissing || _smsLoopRunning) return 0;
    _smsLoopRunning = true;
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
        _refreshUnreadCache();
        db.logOperation('SMS', 'Синхронизация PDU', 'Новых: $addedCount');
        _bumpLogsVersion();
        _safeNotify();
      }
    } catch (e) {
      db.logSystem('ERR', 'Ошибка синхронизации SMS: $e');
      _bumpLogsVersion();
    } finally {
      sw.stop();
      _smsStats.record(sw.elapsedMilliseconds);
      _smsLoopRunning = false;
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
    _safeNotify();
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
      _refreshUnreadCache();
      db.logOperation('SMS', 'Отправка на $phone', 'OK');
      _bumpLogsVersion();
      _safeNotify();
    } else {
      db.logOperation('SMS', 'Отправка на $phone', 'Ошибка');
      _bumpLogsVersion();
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
    _safeNotify();
  }

  void markSmsRead(List<int> ids, {bool read = true}) {
    db.markSmsRead(ids, read: read);
    _refreshUnreadCache();
    _safeNotify();
  }

  void moveSmsToTrash(List<int> ids) {
    db.moveSmsToTrash(ids);
    _refreshUnreadCache();
    _safeNotify();
  }

  void restoreSmsFromTrash(List<int> ids) {
    db.restoreSmsFromTrash(ids);
    _refreshUnreadCache();
    _safeNotify();
  }

  void deleteSmsPermanently(List<int> ids) {
    db.deleteSmsPermanently(ids);
    _refreshUnreadCache();
    _safeNotify();
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
    _safeNotify();
    final res = await scenarioEngine.runScenario(
      scenario: scenario,
      snapshot: snapshot,
      settings: settings,
    );
    scenarioRuns = db.getScenarioRuns();
    _bumpLogsVersion();
    _safeNotify();
    return res;
  }

  void saveScenario(ScenarioDefinition sc) {
    db.upsertScenario(sc);
    scenarios = db.getScenarios();
    _safeNotify();
  }

  void deleteScenario(String id) {
    db.deleteScenario(id);
    scenarios = db.getScenarios();
    _safeNotify();
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
    _bumpLogsVersion();
    _safeNotify();
    return res;
  }

  // ---------------- Calls, Voice, Contacts, RAS ----------------

  Future<void> refreshActiveCalls() async {
    if (!serial.isOpen) return;
    activeCalls = await modem.listActiveCalls();
    _safeNotify();
  }

  Future<void> refreshContacts() async {
    if (!serial.isOpen || snapshot.simMissing) return;
    contacts = await modem.readSimContacts();
    _safeNotify();
  }

  Future<void> refreshVoicePhrases() async {
    voicePhrases = await voice.listPhrases();
    _safeNotify();
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
    _bumpLogsVersion();
    _safeNotify();
  }

  Future<void> disconnectRasInternet() async {
    rasStatus = await RasDialer.disconnect();
    db.logOperation('Интернет RAS', 'Отключение', rasStatus);
    _bumpLogsVersion();
    _safeNotify();
  }

  Future<void> saveSettings() async {
    await settings.save();
    _rescheduleStatusLoop();
    _rescheduleSmsLoop();
    _safeNotify();
  }
}
