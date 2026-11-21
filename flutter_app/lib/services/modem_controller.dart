import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/app_settings.dart';
import '../models/modem_models.dart';
import '../models/scenario_models.dart';
import 'app_paths.dart';
import 'database_service.dart';
import 'debug_profiler_service.dart';
import 'excel_exporter.dart';
import 'huawei_e173_service.dart';
import 'pdu_codec.dart';
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

enum PopupNotificationType { incomingCall, incomingSms }

class PopupNotificationData {
  final String id;
  final PopupNotificationType type;
  final String title;
  final String senderOrNumber;
  final String contactName;
  final String body;
  final String timestamp;
  final int smsCount;
  final bool isTest;

  const PopupNotificationData({
    required this.id,
    required this.type,
    required this.title,
    required this.senderOrNumber,
    this.contactName = '',
    this.body = '',
    this.timestamp = '',
    this.smsCount = 1,
    this.isTest = false,
  });

  String get displaySender => contactName.isNotEmpty
      ? '$contactName ($senderOrNumber)'
      : senderOrNumber;
}

/// Главный координатор приложения:
/// - Мгновенный запуск UI (initLocal) + асинхронная инициализация портов (startHardwareAndLoops);
/// - USB Hotplug (мгновенное освобождение при извлечении и автопереподключение при возврате);
/// - адаптивные интервалы (активный / простой / свёрнуто / 60с при отсутствии SIM);
/// - кэширование счётчика непрочитанных SMS и пропуск лишних перерисовок UI;
/// - автосинхронизация SMS (+CMTI и расписание), звуковые оповещения SMS и входящего звонка (winmm.dll);
/// - всплывающие окна поверх всех окон для SMS и входящих звонков;
/// - встроенный профилировщик и отладчик производительности в реальном времени (выключаемый).
class ModemController extends ChangeNotifier {
  final DebugProfilerService profiler = DebugProfilerService();
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
  bool incomingRingtoneMuted = false;
  String callStateBanner = '';
  String voiceCapabilityStatus = 'Не проверено';
  bool? voiceCapabilityEnabled;
  String rasStatus = 'Отключено';
  String? lastToastMessage;
  bool busy = false;
  bool initialized = false;
  bool _hardwareStarted = false;

  // Активное всплывающее уведомление поверх всех окон (SMS или входящий звонок)
  PopupNotificationData? activePopup;
  Future<void> Function({required bool isCall})? onPopupShowRequested;
  Future<void> Function({bool restoreFullWindow})? onPopupDismissRequested;

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
  Timer? _ringWatchdogTimer;
  Timer? _smsPopupAutoHideTimer;

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
    db.profiler = profiler;
    serial = Win32SerialPort(
      onUnexpectedDisconnect: _handleUnexpectedUsbDisconnect,
      onUnsolicitedLine: _handleUnsolicitedLine,
    );
    modem = HuaweiE173Service(
      serial,
      onLog: _handleAtLog,
      profiler: profiler,
    );
    voice = VoiceService(
      audio,
      onChanged: () => _safeNotify('voice_service'),
      profiler: profiler,
    );
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
        _safeNotify('scenario_progress');
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
          stateNote: _windowHiddenOrMinimized
              ? 'Окно скрыто'
              : 'Активен (Win32 реестр)',
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

  void _safeNotify([String source = 'general']) {
    if (!_disposed) {
      if (profiler.enabled) {
        profiler.recordUiNotify(source);
      }
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
    profiler.logEvent(
      level: 'PROC',
      category: 'UI',
      subsystem: 'window_state',
      message: hidden
          ? 'Окно скрыто/свёрнуто -> переход на интервал ${currentStatusIntervalSec}с'
          : 'Окно активно -> интервал ${currentStatusIntervalSec}с',
    );
    _rescheduleStatusLoop();
    _safeNotify('window_visibility');
  }

  Future<void> setDebugProfilerEnabled(bool enabled) async {
    settings.debugProfilerEnabled = enabled;
    profiler.setEnabled(enabled);
    await settings.save();
    _safeNotify('profiler_toggle');
  }

  /// Фаза 1: быстрая локальная инициализация (настройки + SQLite, ~20 мс) до показа первого кадра UI.
  Future<void> initLocal() async {
    if (initialized) return;
    await AppPaths.ensureDirectories();
    settings = await AppSettings.load();
    profiler.setEnabled(settings.debugProfilerEnabled);
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
    _safeNotify('phrases_loaded');

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
    _ringWatchdogTimer?.cancel();
    _smsPopupAutoHideTimer?.cancel();
    profiler.dispose();
    voice.dispose();
    audio.dispose();
    serial.close();
    db.close();
  }

  void _emitToast(String msg) {
    lastToastMessage = msg;
    _safeNotify('toast');
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
        _safeNotify('at_log');
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
    _safeNotify('manual_at');
    return res;
  }

  // ---------------- Поиск имени контакта и всплывающие уведомления ----------------

  String resolveContactName(String rawNumber) {
    final digits = rawNumber.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 7 || contacts.isEmpty) return '';
    final tail = digits.length > 10 ? digits.substring(digits.length - 10) : digits;
    for (final ct in contacts) {
      final cDigits = ct.phone.replaceAll(RegExp(r'\D'), '');
      if (cDigits.isEmpty) continue;
      final cTail =
          cDigits.length > 10 ? cDigits.substring(cDigits.length - 10) : cDigits;
      if (cTail == tail && ct.name.trim().isNotEmpty) {
        return ct.name.trim();
      }
    }
    return '';
  }

  void _startRingtoneIfEnabled() {
    if (!settings.callRingtoneEnabled || incomingRingtoneMuted) return;
    if (audio.isRingtonePlaying) return;
    profiler.trackSync('audio_sound', () {
      audio.playCallRingtone(
        volume: settings.callRingtoneVolume,
        loop: true,
      );
    }, detail: 'incoming_call_ringtone');
  }

  void _stopIncomingRingtone() {
    _ringWatchdogTimer?.cancel();
    _ringWatchdogTimer = null;
    if (audio.isRingtonePlaying) {
      audio.stopCallRingtone();
    }
  }

  void muteCurrentRingtone() {
    incomingRingtoneMuted = true;
    audio.stopCallRingtone();
    _safeNotify('ringtone_muted');
  }

  void testCallRingtone({bool stop = false}) {
    if (stop || audio.isRingtonePlaying) {
      audio.stopCallRingtone();
    } else {
      profiler.trackSync('audio_sound', () {
        audio.playCallRingtone(
          volume: settings.callRingtoneVolume,
          loop: false,
        );
      }, detail: 'test_call_ringtone');
    }
    _safeNotify('test_ringtone');
  }

  Future<void> _presentPopup(PopupNotificationData data) async {
    _smsPopupAutoHideTimer?.cancel();
    _smsPopupAutoHideTimer = null;

    activePopup = data;
    _safeNotify('popup_show');

    await profiler.trackAsync('popup_window', () async {
      await onPopupShowRequested?.call(
        isCall: data.type == PopupNotificationType.incomingCall,
      );
    }, detail: data.type == PopupNotificationType.incomingCall ? 'call' : 'sms');

    // SMS-уведомление автоматически скрывается через 14 секунд (звонок остаётся до ответа/сброса)
    if (data.type == PopupNotificationType.incomingSms) {
      final popupId = data.id;
      _smsPopupAutoHideTimer = Timer(const Duration(seconds: 14), () {
        if (activePopup?.id == popupId) {
          unawaited(dismissActivePopup(restoreFullWindow: false));
        }
      });
    }
  }

  Future<void> dismissActivePopup({bool restoreFullWindow = false}) async {
    _smsPopupAutoHideTimer?.cancel();
    _smsPopupAutoHideTimer = null;

    final wasTestCall = activePopup?.isTest == true &&
        activePopup?.type == PopupNotificationType.incomingCall;
    if (wasTestCall) {
      _stopIncomingRingtone();
      incomingRingtoneMuted = false;
    }

    activePopup = null;
    _safeNotify('popup_dismiss');
    await onPopupDismissRequested?.call(restoreFullWindow: restoreFullWindow);
  }

  Future<void> triggerTestSmsPopup() async {
    if (settings.smsSoundEnabled) {
      profiler.trackSync('audio_sound', () {
        audio.playSmsNotification(volume: settings.smsSoundVolume);
      }, detail: 'test_sms_sound');
    }
    await _presentPopup(PopupNotificationData(
      id: 'test-sms-${DateTime.now().millisecondsSinceEpoch}',
      type: PopupNotificationType.incomingSms,
      title: 'Новое входящее SMS (тест)',
      senderOrNumber: '+7 999 000-00-00',
      contactName: 'Проверка уведомления',
      body: 'Пример всплывающего окна SMS поверх всех окон Windows. Его можно отключить в Настройках.',
      timestamp: DatabaseService.nowIso(),
      smsCount: 1,
      isTest: true,
    ));
  }

  Future<void> triggerTestCallPopup() async {
    incomingRingtoneMuted = false;
    if (settings.callRingtoneEnabled) {
      profiler.trackSync('audio_sound', () {
        audio.playCallRingtone(
          volume: settings.callRingtoneVolume,
          loop: true,
        );
      }, detail: 'test_call_popup_ringtone');
    }
    await _presentPopup(PopupNotificationData(
      id: 'test-call-${DateTime.now().millisecondsSinceEpoch}',
      type: PopupNotificationType.incomingCall,
      title: 'Входящий звонок (тест)',
      senderOrNumber: '+7 999 123-45-67',
      contactName: 'Тестовый абонент',
      body: 'Проверка всплывающего окна входящего вызова поверх всех окон Windows.',
      timestamp: DatabaseService.nowIso(),
      isTest: true,
    ));
  }

  Future<void> answerIncomingCall() async {
    final isTest = activePopup?.isTest == true;
    _stopIncomingRingtone();
    incomingRingtoneMuted = false;
    if (isTest) {
      await dismissActivePopup(restoreFullWindow: false);
      _emitToast('Тестовый входящий звонок принят.');
      return;
    }
    if (serial.isOpen) {
      await modem.answerCall();
      final voicePort = settings.preferredVoicePort;
      if (voicePort.isNotEmpty &&
          voicePort != serial.portName &&
          !voice.isBridgeActive) {
        try {
          voice.startVoiceBridge(voicePort);
        } catch (_) {}
      }
      incomingCallerNumber = null;
      callStateBanner = 'Разговор активен';
      await dismissActivePopup(restoreFullWindow: true);
      await refreshActiveCalls();
    } else {
      await dismissActivePopup(restoreFullWindow: false);
    }
  }

  Future<void> rejectIncomingCall() async {
    final isTest = activePopup?.isTest == true;
    _stopIncomingRingtone();
    incomingRingtoneMuted = false;
    if (isTest) {
      await dismissActivePopup(restoreFullWindow: false);
      _emitToast('Тестовый входящий звонок сброшен.');
      return;
    }
    if (serial.isOpen) {
      await modem.hangupCall();
    }
    voice.stopVoiceBridge();
    incomingCallerNumber = null;
    callStateBanner = '';
    activeCalls = [];
    await dismissActivePopup(restoreFullWindow: false);
    if (serial.isOpen) {
      await refreshActiveCalls();
    } else {
      _safeNotify('call_rejected');
    }
  }

  // ---------------- USB Hotplug & Port Management ----------------

  Future<void> scanPorts() async {
    if (_scanningPorts) return;
    _scanningPorts = true;
    _safeNotify('scan_ports_start');
    try {
      final found = await profiler.trackAsync(
        'port_pnp_scan',
        () => Win32SerialPort.scanPorts(),
        detail: 'Win32_PnPEntity',
      );
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
      _safeNotify('scan_ports_done');
    }
  }

  Future<void> connectPort(String port, {bool isAuto = false}) async {
    if (busy || (serial.isOpen && serial.portName == port)) return;
    busy = true;
    _manualDisconnected = false;
    _safeNotify('connect_start');

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
      db.logSystem(
          'INFO', 'Подключён модем $port (${next.model}, ${next.simStatus})');
      profiler.logEvent(
        level: 'PROC',
        category: 'MODEM',
        subsystem: 'connect',
        message: 'Подключён порт $port (${next.model}, ${next.simStatus})',
      );
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
      profiler.logEvent(
        level: 'ERR',
        category: 'MODEM',
        subsystem: 'connect',
        message: 'Ошибка подключения к $port: $e',
      );
      _bumpLogsVersion();
      if (!isAuto) _emitToast('Ошибка подключения: $e');
    } finally {
      busy = false;
      _safeNotify('connect_done');
    }
  }

  void disconnectPort({bool manual = true}) {
    _manualDisconnected = manual;
    _stopIncomingRingtone();
    incomingRingtoneMuted = false;
    voice.stopVoiceBridge();
    final prevPort = serial.portName;
    serial.close();
    incomingCallerNumber = null;
    callStateBanner = '';
    voiceCapabilityStatus = 'Не проверено';
    voiceCapabilityEnabled = null;
    activeCalls = [];
    if (activePopup?.type == PopupNotificationType.incomingCall &&
        activePopup?.isTest != true) {
      unawaited(dismissActivePopup(restoreFullWindow: false));
    }
    _applySnapshotIfChanged(const ModemSnapshot());
    if (prevPort != null) {
      db.logOperation('Подключение', 'Закрыт порт $prevPort', 'OK');
      profiler.logEvent(
        level: 'PROC',
        category: 'MODEM',
        subsystem: 'disconnect',
        message: 'Порт $prevPort закрыт вручную',
      );
      _bumpLogsVersion();
    }
    _safeNotify('disconnect');
  }

  void _handleUnexpectedUsbDisconnect(String reason) {
    _stopIncomingRingtone();
    incomingRingtoneMuted = false;
    voice.stopVoiceBridge();
    incomingCallerNumber = null;
    callStateBanner = '';
    activeCalls = [];
    if (activePopup?.type == PopupNotificationType.incomingCall &&
        activePopup?.isTest != true) {
      unawaited(dismissActivePopup(restoreFullWindow: false));
    }
    _applySnapshotIfChanged(const ModemSnapshot());
    db.logSystem('WARN', 'Мгновенное освобождение порта: $reason');
    db.logOperation('USB Hotplug', 'Модем извлечён', 'Отключён', reason);
    profiler.logEvent(
      level: 'WARN',
      category: 'SYSTEM',
      subsystem: 'usb_hotplug_scan',
      message: 'USB-модем извлечён: $reason',
    );
    _bumpLogsVersion();
    _emitToast('Модем извлечён из USB — порт освобождён.');
  }

  void _refreshRingWatchdog() {
    _ringWatchdogTimer?.cancel();
    _ringWatchdogTimer = Timer(const Duration(seconds: 6), () {
      // Если 6 секунд подряд не приходил RING (звонящий сбросил без ^CEND) — останавливаем рингтон и окно
      if (incomingCallerNumber != null &&
          !callStateBanner.contains('Разговор активен')) {
        _stopIncomingRingtone();
        incomingRingtoneMuted = false;
        incomingCallerNumber = null;
        callStateBanner = '';
        if (activePopup?.type == PopupNotificationType.incomingCall &&
            activePopup?.isTest != true) {
          unawaited(dismissActivePopup(restoreFullWindow: false));
        }
        _safeNotify('ring_timeout');
      }
    });
  }

  void _handleIncomingCallSignal(String? callerNumber) {
    final isNewRing = incomingCallerNumber == null;
    if (isNewRing) {
      incomingRingtoneMuted = false;
    }
    final displayNum = (callerNumber != null && callerNumber.trim().isNotEmpty)
        ? callerNumber.trim()
        : (incomingCallerNumber ?? 'Неизвестный номер');
    incomingCallerNumber = displayNum;
    callStateBanner = 'Входящий вызов: $displayNum';

    _refreshRingWatchdog();
    _startRingtoneIfEnabled();

    if (settings.callPopupEnabled) {
      final shouldShowOrUpdate = activePopup == null ||
          activePopup!.type != PopupNotificationType.incomingCall ||
          activePopup!.senderOrNumber != displayNum;
      if (shouldShowOrUpdate) {
        final contactName = resolveContactName(displayNum);
        unawaited(_presentPopup(PopupNotificationData(
          id: 'call-${DateTime.now().millisecondsSinceEpoch}',
          type: PopupNotificationType.incomingCall,
          title: 'Входящий звонок',
          senderOrNumber: displayNum,
          contactName: contactName,
          body: 'Модем ${snapshot.port} · ${snapshot.operatorName}',
          timestamp: DatabaseService.nowIso(),
        )));
      }
    }
    _safeNotify('incoming_call');
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
      profiler.logEvent(
        level: 'PROC',
        category: 'MODEM',
        subsystem: 'urc_serial_poll',
        message: 'Получен URC новой SMS: $line',
      );
      _bumpLogsVersion();
      if (settings.autoFetchSms && !snapshot.simMissing) {
        unawaited(syncSmsFromModem(silent: false));
      }
      _safeNotify('urc_cmti');
    } else if (line == 'RING') {
      _handleIncomingCallSignal(null);
    } else if (line.startsWith('+CLIP:')) {
      final m = RegExp(r'\+CLIP:\s*"([^"]+)"').firstMatch(line);
      _handleIncomingCallSignal(m?.group(1));
    } else if (line.startsWith('^ORIG:')) {
      callStateBanner = 'Набор номера (^ORIG)...';
      _safeNotify('urc_orig');
    } else if (line.startsWith('^CONF:')) {
      callStateBanner = 'Идут гудки (^CONF)...';
      _safeNotify('urc_conf');
    } else if (line.startsWith('^CONN:')) {
      _stopIncomingRingtone();
      incomingRingtoneMuted = false;
      incomingCallerNumber = null;
      callStateBanner = 'Разговор активен (^CONN)';
      if (activePopup?.type == PopupNotificationType.incomingCall &&
          activePopup?.isTest != true) {
        unawaited(dismissActivePopup(restoreFullWindow: false));
      }
      db.logSystem('INFO', 'Соединение установлено: $line');
      profiler.logEvent(
        level: 'PROC',
        category: 'VOICE',
        subsystem: 'voice_rx_bridge',
        message: 'Соединение вызова установлено ($line) -> запуск AT^DDSETEX=2',
      );
      _bumpLogsVersion();
      // На Huawei E173 обязательно активируем AT^DDSETEX=2 именно после ^CONN:
      unawaited(_activateVoiceAudioOnConnect());
      _safeNotify('urc_conn');
    } else if (line.startsWith('^CEND:')) {
      _stopIncomingRingtone();
      incomingRingtoneMuted = false;
      incomingCallerNumber = null;
      callStateBanner = '';
      activeCalls = [];
      voice.stopVoiceBridge();
      if (activePopup?.type == PopupNotificationType.incomingCall &&
          activePopup?.isTest != true) {
        unawaited(dismissActivePopup(restoreFullWindow: false));
      }
      db.logSystem('INFO', 'Вызов завершён: $line');
      profiler.logEvent(
        level: 'PROC',
        category: 'VOICE',
        subsystem: 'voice_rx_bridge',
        message: 'Вызов завершён ($line)',
      );
      _bumpLogsVersion();
      _safeNotify('urc_cend');
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
      profiler.logEvent(
        level: 'WARN',
        category: 'VOICE',
        subsystem: 'voice_rx_bridge',
        message: 'Ошибка открытия аудиоканала после ^CONN: $e',
      );
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
    _safeNotify('voice_cap');
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
    _safeNotify('snapshot_changed');
  }

  // ---------------- Background Adaptive Loops + DIAG ----------------

  void _startBackgroundLoops() {
    // 1. Быстрый неблокирующий перехват URC (+CMTI / RING) и проверка дескриптора
    _urcPollTimer?.cancel();
    _urcPollTimer = Timer.periodic(const Duration(milliseconds: 700), (_) {
      if (serial.isOpen && !serial.isBusy && !busy && !scenarioEngine.isRunning) {
        profiler.trackSync('urc_serial_poll', () {
          serial.pollUnsolicited();
        }, detail: serial.portName ?? '');
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
        profiler.recordDuration(
          'usb_hotplug_scan',
          sw.elapsedMicroseconds / 1000.0,
          detail: 'портов: ${_knownPortNames.length}',
        );
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
        profiler.recordDuration(
          'status_modem_poll',
          sw.elapsedMicroseconds / 1000.0,
          detail: '$e',
          isError: true,
        );
        _bumpLogsVersion();
      } finally {
        sw.stop();
        _statusStats.record(sw.elapsedMilliseconds);
        profiler.recordDuration(
          'status_modem_poll',
          sw.elapsedMicroseconds / 1000.0,
          detail: 'интервал ${sec}с',
        );
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

  // ---------------- SMS Sync, Sound & Topmost Popup ----------------

  Future<int> syncSmsFromModem({bool silent = false}) async {
    if (!serial.isOpen || snapshot.simMissing || _smsLoopRunning) return 0;
    _smsLoopRunning = true;
    final sw = Stopwatch()..start();
    var addedCount = 0;
    AssembledSms? latestNewInbox;
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
          latestNewInbox = msg;
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

      if (addedCount > 0 && !silent) {
        if (settings.smsSoundEnabled) {
          profiler.trackSync('audio_sound', () {
            audio.playSmsNotification(volume: settings.smsSoundVolume);
          }, detail: 'sms_chime');
        }
        if (settings.smsPopupEnabled &&
            latestNewInbox != null &&
            activePopup?.type != PopupNotificationType.incomingCall) {
          final sender = latestNewInbox.address.trim().isEmpty
              ? 'Неизвестный отправитель'
              : latestNewInbox.address.trim();
          final contactName = resolveContactName(sender);
          unawaited(_presentPopup(PopupNotificationData(
            id: 'sms-${DateTime.now().millisecondsSinceEpoch}',
            type: PopupNotificationType.incomingSms,
            title: addedCount > 1
                ? 'Новые входящие SMS ($addedCount)'
                : 'Новое входящее SMS',
            senderOrNumber: sender,
            contactName: contactName,
            body: latestNewInbox.body,
            timestamp: latestNewInbox.timestamp.isNotEmpty
                ? latestNewInbox.timestamp
                : DatabaseService.nowIso(),
            smsCount: addedCount,
          )));
        }
      }
      if (addedCount > 0) {
        _refreshUnreadCache();
        db.logOperation('SMS', 'Синхронизация PDU', 'Новых: $addedCount');
        _bumpLogsVersion();
        _safeNotify('sms_synced');
      }
    } catch (e) {
      db.logSystem('ERR', 'Ошибка синхронизации SMS: $e');
      profiler.recordDuration(
        'sms_pdu_sync',
        sw.elapsedMicroseconds / 1000.0,
        detail: '$e',
        isError: true,
      );
      _bumpLogsVersion();
    } finally {
      sw.stop();
      _smsStats.record(sw.elapsedMilliseconds);
      profiler.recordDuration(
        'sms_pdu_sync',
        sw.elapsedMicroseconds / 1000.0,
        detail: 'новых: $addedCount',
      );
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
    _safeNotify('sms_diag');
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
      _safeNotify('sms_sent');
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
    _safeNotify('manual_refresh');
  }

  void markSmsRead(List<int> ids, {bool read = true}) {
    db.markSmsRead(ids, read: read);
    _refreshUnreadCache();
    _safeNotify('sms_mark_read');
  }

  void markAllInboxSmsRead() {
    final unread = db
        .getMessages(folder: 'inbox')
        .where((m) => !m.isRead)
        .map((m) => m.id)
        .toList();
    if (unread.isNotEmpty) {
      markSmsRead(unread, read: true);
    }
  }

  void moveSmsToTrash(List<int> ids) {
    db.moveSmsToTrash(ids);
    _refreshUnreadCache();
    _safeNotify('sms_trash');
  }

  void restoreSmsFromTrash(List<int> ids) {
    db.restoreSmsFromTrash(ids);
    _refreshUnreadCache();
    _safeNotify('sms_restore');
  }

  void deleteSmsPermanently(List<int> ids) {
    db.deleteSmsPermanently(ids);
    _refreshUnreadCache();
    _safeNotify('sms_delete');
  }

  // ---------------- Scenarios Auto-Run & Manual Run ----------------

  void _maybeAutoRunScenarios() {
    if (snapshot.simMissing ||
        !snapshot.isRegistered ||
        scenarioEngine.isRunning) {
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
    _safeNotify('scenario_start');
    final res = await profiler.trackAsync(
      'scenario_run',
      () => scenarioEngine.runScenario(
        scenario: scenario,
        snapshot: snapshot,
        settings: settings,
      ),
      detail: scenario.name,
    );
    scenarioRuns = db.getScenarioRuns();
    _bumpLogsVersion();
    _safeNotify('scenario_done');
    return res;
  }

  void saveScenario(ScenarioDefinition sc) {
    db.upsertScenario(sc);
    scenarios = db.getScenarios();
    _safeNotify('scenario_save');
  }

  void deleteScenario(String id) {
    db.deleteScenario(id);
    scenarios = db.getScenarios();
    _safeNotify('scenario_delete');
  }

  Future<ExcelExportResult> rebuildExcelNow() async {
    final allRuns = db.getScenarioRuns(ascending: true);
    final res = await profiler.trackAsync(
      'excel_export',
      () => ExcelExporter.rebuildFromRuns(
        runs: allRuns,
        columns: settings.excelColumns,
      ),
      detail: 'строк: ${allRuns.length}',
    );
    db.logOperation(
      'Excel',
      'Пересборка таблицы из БД',
      res.usedBackup ? 'Резервная копия' : 'OK',
      res.savedPath,
    );
    _bumpLogsVersion();
    _safeNotify('excel_rebuild');
    return res;
  }

  // ---------------- Calls, Voice, Contacts, RAS ----------------

  Future<void> refreshActiveCalls() async {
    if (!serial.isOpen) return;
    activeCalls = await modem.listActiveCalls();
    _safeNotify('active_calls');
  }

  Future<void> refreshContacts() async {
    if (!serial.isOpen || snapshot.simMissing) return;
    contacts = await modem.readSimContacts();
    _safeNotify('contacts');
  }

  Future<void> refreshVoicePhrases() async {
    voicePhrases = await voice.listPhrases();
    _safeNotify('phrases');
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
    _safeNotify('ras_connect');
  }

  Future<void> disconnectRasInternet() async {
    rasStatus = await RasDialer.disconnect();
    db.logOperation('Интернет RAS', 'Отключение', rasStatus);
    _bumpLogsVersion();
    _safeNotify('ras_disconnect');
  }

  Future<void> saveSettings() async {
    profiler.setEnabled(settings.debugProfilerEnabled);
    await settings.save();
    _rescheduleStatusLoop();
    _rescheduleSmsLoop();
    _safeNotify('save_settings');
  }
}
