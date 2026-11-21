import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:path/path.dart' as p;
import 'app_paths.dart';

// Win32 FILETIME (8 байт)
final class _FILETIME extends Struct {
  @Uint32()
  external int dwLowDateTime;
  @Uint32()
  external int dwHighDateTime;

  int get asUint64 => ((dwHighDateTime & 0xFFFFFFFF) << 32) | (dwLowDateTime & 0xFFFFFFFF);
}

// Win32 PROCESS_MEMORY_COUNTERS (72 байта на Windows x64)
final class _PROCESS_MEMORY_COUNTERS extends Struct {
  @Uint32()
  external int cb;
  @Uint32()
  external int pageFaultCount;
  @IntPtr()
  external int peakWorkingSetSize;
  @IntPtr()
  external int workingSetSize;
  @IntPtr()
  external int quotaPeakPagedPoolUsage;
  @IntPtr()
  external int quotaPagedPoolUsage;
  @IntPtr()
  external int quotaPeakNonPagedPoolUsage;
  @IntPtr()
  external int quotaNonPagedPoolUsage;
  @IntPtr()
  external int pagefileUsage;
  @IntPtr()
  external int peakPagefileUsage;
}

typedef _GetCurrentProcessNative = IntPtr Function();
typedef _GetCurrentProcessDart = int Function();

typedef _GetCurrentProcessIdNative = Uint32 Function();
typedef _GetCurrentProcessIdDart = int Function();

typedef _GetProcessTimesNative = Int32 Function(
  IntPtr hProcess,
  Pointer<_FILETIME> lpCreationTime,
  Pointer<_FILETIME> lpExitTime,
  Pointer<_FILETIME> lpKernelTime,
  Pointer<_FILETIME> lpUserTime,
);
typedef _GetProcessTimesDart = int Function(
  int hProcess,
  Pointer<_FILETIME> lpCreationTime,
  Pointer<_FILETIME> lpExitTime,
  Pointer<_FILETIME> lpKernelTime,
  Pointer<_FILETIME> lpUserTime,
);

typedef _GetProcessHandleCountNative = Int32 Function(
  IntPtr hProcess,
  Pointer<Uint32> pdwHandleCount,
);
typedef _GetProcessHandleCountDart = int Function(
  int hProcess,
  Pointer<Uint32> pdwHandleCount,
);

typedef _GetProcessMemoryInfoNative = Int32 Function(
  IntPtr hProcess,
  Pointer<_PROCESS_MEMORY_COUNTERS> ppsmemCounters,
  Uint32 cb,
);
typedef _GetProcessMemoryInfoDart = int Function(
  int hProcess,
  Pointer<_PROCESS_MEMORY_COUNTERS> ppsmemCounters,
  int cb,
);

typedef _GetGuiResourcesNative = Uint32 Function(
  IntPtr hProcess,
  Uint32 uiFlags,
);
typedef _GetGuiResourcesDart = int Function(int hProcess, int uiFlags);

class ProcessResourceSnapshot {
  final int pid;
  final int logicalCores;
  final double cpuTotalPercent;
  final double cpuUserPercent;
  final double cpuKernelPercent;
  final double peakCpuPercent;
  final double workingSetMb;
  final double peakWorkingSetMb;
  final double privateMb;
  final int handleCount;
  final int gdiObjects;
  final int userObjects;
  final double fps;
  final double avgBuildMs;
  final double maxBuildMs;
  final double avgRasterMs;
  final double maxRasterMs;
  final int jankFrames;
  final int severeFreezeFrames;
  final int uiNotifiesPerSec;
  final int totalUiNotifies;
  final Duration uptime;

  const ProcessResourceSnapshot({
    this.pid = 0,
    this.logicalCores = 1,
    this.cpuTotalPercent = 0,
    this.cpuUserPercent = 0,
    this.cpuKernelPercent = 0,
    this.peakCpuPercent = 0,
    this.workingSetMb = 0,
    this.peakWorkingSetMb = 0,
    this.privateMb = 0,
    this.handleCount = 0,
    this.gdiObjects = 0,
    this.userObjects = 0,
    this.fps = 0,
    this.avgBuildMs = 0,
    this.maxBuildMs = 0,
    this.avgRasterMs = 0,
    this.maxRasterMs = 0,
    this.jankFrames = 0,
    this.severeFreezeFrames = 0,
    this.uiNotifiesPerSec = 0,
    this.totalUiNotifies = 0,
    this.uptime = Duration.zero,
  });
}

class SubsystemProfile {
  final String id;
  final String label;
  final String category; // MODEM, SQL, VOICE, UI, SYSTEM
  final double slowThresholdMs;

  int calls = 0;
  int slowCount = 0;
  int errorCount = 0;
  double lastMs = 0;
  double maxMs = 0;
  double totalMs = 0;
  DateTime? lastRunAt;
  String lastDetail = '';

  SubsystemProfile({
    required this.id,
    required this.label,
    required this.category,
    required this.slowThresholdMs,
  });

  double get avgMs => calls == 0 ? 0 : totalMs / calls;

  void reset() {
    calls = 0;
    slowCount = 0;
    errorCount = 0;
    lastMs = 0;
    maxMs = 0;
    totalMs = 0;
    lastRunAt = null;
    lastDetail = '';
  }
}

class DebugEventEntry {
  final DateTime timestamp;
  final String level; // PERF, PROC, WARN, ERR
  final String category; // MODEM, SQL, VOICE, UI, SYSTEM
  final String subsystem;
  final String message;
  final double? durationMs;

  const DebugEventEntry({
    required this.timestamp,
    required this.level,
    required this.category,
    required this.subsystem,
    required this.message,
    this.durationMs,
  });

  String get timeLabel {
    String two(int n) => n.toString().padLeft(2, '0');
    String three(int n) => n.toString().padLeft(3, '0');
    return '${two(timestamp.hour)}:${two(timestamp.minute)}:${two(timestamp.second)}.${three(timestamp.millisecond)}';
  }
}

class DetectedIssue {
  final String severity; // HIGH, MED, INFO
  final String title;
  final String description;

  const DetectedIssue({
    required this.severity,
    required this.title,
    required this.description,
  });
}

/// Встроенный профилировщик и отладчик производительности Windows x64 в реальном времени.
/// Когда [enabled] == false — не запускает никаких таймеров, не слушает FrameTimings и
/// мгновенно выходит из всех замеров с нулевой нагрузкой на CPU/память.
class DebugProfilerService extends ChangeNotifier {
  bool _enabled = false;
  bool _disposed = false;
  DateTime _startedAt = DateTime.now();

  Timer? _sampleTimer;
  bool _timingsRegistered = false;

  // Win32 FFI (инициализируются лениво только при первом включении отладки)
  bool _win32Loaded = false;
  int _hProcess = 0;
  int _pid = 0;
  _GetProcessTimesDart? _getProcessTimes;
  _GetProcessHandleCountDart? _getProcessHandleCount;
  _GetProcessMemoryInfoDart? _getProcessMemoryInfo;
  _GetGuiResourcesDart? _getGuiResources;

  // Базовые значения для расчёта дельты CPU
  int _prevKernelTicks = 0;
  int _prevUserTicks = 0;
  DateTime? _prevCpuSampleAt;
  double _peakCpuPercent = 0;
  int _initialHandles = 0;

  // Метрики Flutter FrameTimings за последнюю секунду и за сессию
  int _framesInWindow = 0;
  double _windowBuildSumMs = 0;
  double _windowRasterSumMs = 0;
  double _maxBuildMs = 0;
  double _maxRasterMs = 0;
  int _jankFrames = 0;
  int _severeFreezeFrames = 0;

  // Счётчики notifyListeners()
  int _notifiesInWindow = 0;
  int _totalNotifies = 0;
  final Map<String, int> _notifySources = {};

  ProcessResourceSnapshot _resources = const ProcessResourceSnapshot();
  final Map<String, SubsystemProfile> _subsystems = {};
  final List<DebugEventEntry> _events = [];
  final List<double> _cpuHistory = [];
  final List<double> _ramHistory = [];

  bool get enabled => _enabled;
  ProcessResourceSnapshot get resources => _resources;
  List<DebugEventEntry> get events => List.unmodifiable(_events);
  List<double> get cpuHistory => List.unmodifiable(_cpuHistory);
  List<double> get ramHistory => List.unmodifiable(_ramHistory);
  Map<String, int> get notifySources => Map.unmodifiable(_notifySources);

  List<SubsystemProfile> get sortedSubsystems {
    final list = _subsystems.values.toList();
    list.sort((a, b) {
      final totalDiff = b.totalMs.compareTo(a.totalMs);
      if (totalDiff != 0) return totalDiff;
      return b.maxMs.compareTo(a.maxMs);
    });
    return list;
  }

  double get totalTrackedMs {
    var sum = 0.0;
    for (final s in _subsystems.values) {
      sum += s.totalMs;
    }
    return sum;
  }

  DebugProfilerService() {
    _registerDefaultSubsystems();
  }

  void _registerDefaultSubsystems() {
    void add(String id, String label, String cat, double thresholdMs) {
      _subsystems[id] = SubsystemProfile(
        id: id,
        label: label,
        category: cat,
        slowThresholdMs: thresholdMs,
      );
    }

    add('usb_hotplug_scan', 'USB Hotplug (Win32 реестр)', 'SYSTEM', 15);
    add('port_pnp_scan', 'Сканирование PnP (PowerShell WMI)', 'SYSTEM', 1500);
    add('urc_serial_poll', 'Опрос входящих URC (+CMTI/RING)', 'MODEM', 15);
    add('status_modem_poll', 'Опрос модема и сети (AT)', 'MODEM', 1200);
    add('at_command', 'Выполнение AT-команд', 'MODEM', 1500);
    add('sms_pdu_sync', 'Синхронизация PDU SMS', 'MODEM', 2000);
    add('sqlite_read', 'Чтение базы SQLite', 'SQL', 20);
    add('sqlite_write', 'Запись в базу SQLite', 'SQL', 25);
    add('voice_rx_bridge', 'Аудиомост приём (COM -> winmm)', 'VOICE', 12);
    add('voice_tx_mic', 'Аудиомост микрофон (winmm -> COM)', 'VOICE', 12);
    add('audio_sound', 'Звук уведомлений/рингтона (winmm)', 'VOICE', 30);
    add('ui_frame_build', 'Построение кадра Flutter (UI)', 'UI', 16.6);
    add('ui_frame_raster', 'Рендер кадра Flutter (Raster)', 'UI', 16.6);
    add('ui_notify', 'Перерисовки UI (notifyListeners)', 'UI', 8);
    add('scenario_run', 'Выполнение сценариев', 'MODEM', 5000);
    add('excel_export', 'Экспорт / пересборка Excel', 'SYSTEM', 800);
    add('popup_window', 'Всплывающие окна SMS/Звонков', 'UI', 120);
  }

  void _ensureWin32Loaded() {
    if (_win32Loaded || !Platform.isWindows) return;
    _win32Loaded = true;
    try {
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      final getCurrProc = kernel32.lookupFunction<_GetCurrentProcessNative,
          _GetCurrentProcessDart>('GetCurrentProcess');
      final getCurrPid = kernel32.lookupFunction<_GetCurrentProcessIdNative,
          _GetCurrentProcessIdDart>('GetCurrentProcessId');
      _hProcess = getCurrProc();
      _pid = getCurrPid();
      _getProcessTimes = kernel32.lookupFunction<_GetProcessTimesNative,
          _GetProcessTimesDart>('GetProcessTimes');
      _getProcessHandleCount = kernel32.lookupFunction<
          _GetProcessHandleCountNative,
          _GetProcessHandleCountDart>('GetProcessHandleCount');

      final psapi = DynamicLibrary.open('psapi.dll');
      _getProcessMemoryInfo = psapi.lookupFunction<_GetProcessMemoryInfoNative,
          _GetProcessMemoryInfoDart>('GetProcessMemoryInfo');

      final user32 = DynamicLibrary.open('user32.dll');
      _getGuiResources = user32.lookupFunction<_GetGuiResourcesNative,
          _GetGuiResourcesDart>('GetGuiResources');
    } catch (_) {
      // Безопасная деградация, если какая-либо системная DLL недоступна
    }
  }

  void setEnabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;

    if (_enabled) {
      _startedAt = DateTime.now();
      _ensureWin32Loaded();
      _prevCpuSampleAt = null;
      _prevKernelTicks = 0;
      _prevUserTicks = 0;
      _registerFrameTimings();
      _startSampleTimer();
      logEvent(
        level: 'PROC',
        category: 'SYSTEM',
        subsystem: 'profiler',
        message: 'Отладка и профилировщик запущены (PID $_pid, ядер CPU: ${Platform.numberOfProcessors})',
      );
      _sampleSystemResources();
    } else {
      _stopSampleTimer();
      _unregisterFrameTimings();
    }
    _safeNotify();
  }

  void resetStats() {
    _startedAt = DateTime.now();
    _peakCpuPercent = 0;
    _maxBuildMs = 0;
    _maxRasterMs = 0;
    _jankFrames = 0;
    _severeFreezeFrames = 0;
    _notifiesInWindow = 0;
    _totalNotifies = 0;
    _notifySources.clear();
    _events.clear();
    _cpuHistory.clear();
    _ramHistory.clear();
    for (final s in _subsystems.values) {
      s.reset();
    }
    if (_enabled) {
      logEvent(
        level: 'PROC',
        category: 'SYSTEM',
        subsystem: 'profiler',
        message: 'Счётчики и журнал отладки сброшены.',
      );
      _sampleSystemResources();
    }
    _safeNotify();
  }

  void _startSampleTimer() {
    _sampleTimer?.cancel();
    _sampleTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_enabled || _disposed) return;
      _sampleSystemResources();
      _safeNotify();
    });
  }

  void _stopSampleTimer() {
    _sampleTimer?.cancel();
    _sampleTimer = null;
  }

  void _registerFrameTimings() {
    if (_timingsRegistered) return;
    _timingsRegistered = true;
    try {
      SchedulerBinding.instance.addTimingsCallback(_onFrameTimings);
    } catch (_) {
      _timingsRegistered = false;
    }
  }

  void _unregisterFrameTimings() {
    if (!_timingsRegistered) return;
    _timingsRegistered = false;
    try {
      SchedulerBinding.instance.removeTimingsCallback(_onFrameTimings);
    } catch (_) {}
  }

  void _onFrameTimings(List<FrameTiming> timings) {
    if (!_enabled || _disposed) return;
    for (final t in timings) {
      final buildMs = t.buildDuration.inMicroseconds / 1000.0;
      final rasterMs = t.rasterDuration.inMicroseconds / 1000.0;
      _framesInWindow++;
      _windowBuildSumMs += buildMs;
      _windowRasterSumMs += rasterMs;
      if (buildMs > _maxBuildMs) _maxBuildMs = buildMs;
      if (rasterMs > _maxRasterMs) _maxRasterMs = rasterMs;

      _recordInternal('ui_frame_build', buildMs, emitSlowLog: false);
      _recordInternal('ui_frame_raster', rasterMs, emitSlowLog: false);

      final worst = buildMs > rasterMs ? buildMs : rasterMs;
      if (worst > 16.6) {
        _jankFrames++;
      }
      if (worst > 50.0) {
        _severeFreezeFrames++;
        logEvent(
          level: 'PERF',
          category: 'UI',
          subsystem: 'ui_frame',
          durationMs: worst,
          message:
              'Фриз UI кадра: build=${buildMs.toStringAsFixed(1)} мс, raster=${rasterMs.toStringAsFixed(1)} мс',
        );
      }
    }
  }

  void _sampleSystemResources() {
    if (!_enabled) return;

    final cores = Platform.numberOfProcessors > 0 ? Platform.numberOfProcessors : 1;
    var cpuTotal = _resources.cpuTotalPercent;
    var cpuUser = _resources.cpuUserPercent;
    var cpuKernel = _resources.cpuKernelPercent;
    var workingSetMb = _resources.workingSetMb;
    var peakWorkingSetMb = _resources.peakWorkingSetMb;
    var privateMb = _resources.privateMb;
    var handles = _resources.handleCount;
    var gdi = _resources.gdiObjects;
    var userObj = _resources.userObjects;

    if (Platform.isWindows && _hProcess != 0) {
      if (_getProcessTimes != null) {
        final c = calloc<_FILETIME>();
        final e = calloc<_FILETIME>();
        final k = calloc<_FILETIME>();
        final u = calloc<_FILETIME>();
        try {
          if (_getProcessTimes!(_hProcess, c, e, k, u) != 0) {
            final now = DateTime.now();
            final kTicks = k.ref.asUint64;
            final uTicks = u.ref.asUint64;
            if (_prevCpuSampleAt != null) {
              final elapsedUs = now.difference(_prevCpuSampleAt!).inMicroseconds;
              if (elapsedUs > 50000) {
                // FILETIME тики в 100 нс (10 тиков = 1 мкс)
                final dKernelUs = (kTicks - _prevKernelTicks) / 10.0;
                final dUserUs = (uTicks - _prevUserTicks) / 10.0;
                final denom = elapsedUs * cores;
                cpuKernel = ((dKernelUs / denom) * 100.0).clamp(0.0, 100.0).toDouble();
                cpuUser = ((dUserUs / denom) * 100.0).clamp(0.0, 100.0).toDouble();
                cpuTotal = (cpuKernel + cpuUser).clamp(0.0, 100.0).toDouble();
                if (cpuTotal > _peakCpuPercent) {
                  _peakCpuPercent = cpuTotal;
                }
                if (cpuTotal >= 25.0) {
                  logEvent(
                    level: 'WARN',
                    category: 'SYSTEM',
                    subsystem: 'cpu_spike',
                    message:
                        'Повышенная нагрузка CPU процесса: ${cpuTotal.toStringAsFixed(1)}% (user ${cpuUser.toStringAsFixed(1)}%, kernel ${cpuKernel.toStringAsFixed(1)}%)',
                  );
                }
              }
            }
            _prevKernelTicks = kTicks;
            _prevUserTicks = uTicks;
            _prevCpuSampleAt = now;
          }
        } finally {
          calloc.free(c);
          calloc.free(e);
          calloc.free(k);
          calloc.free(u);
        }
      }

      if (_getProcessMemoryInfo != null) {
        final mem = calloc<_PROCESS_MEMORY_COUNTERS>();
        try {
          final cb = sizeOf<_PROCESS_MEMORY_COUNTERS>();
          mem.ref.cb = cb;
          if (_getProcessMemoryInfo!(_hProcess, mem, cb) != 0) {
            const mb = 1024.0 * 1024.0;
            workingSetMb = mem.ref.workingSetSize / mb;
            peakWorkingSetMb = mem.ref.peakWorkingSetSize / mb;
            privateMb = mem.ref.pagefileUsage / mb;
          }
        } finally {
          calloc.free(mem);
        }
      }

      if (_getProcessHandleCount != null) {
        final hPtr = calloc<Uint32>();
        try {
          if (_getProcessHandleCount!(_hProcess, hPtr) != 0) {
            handles = hPtr.value;
            if (_initialHandles == 0) _initialHandles = handles;
          }
        } finally {
          calloc.free(hPtr);
        }
      }

      if (_getGuiResources != null) {
        gdi = _getGuiResources!(_hProcess, 0);
        userObj = _getGuiResources!(_hProcess, 1);
      }
    }

    final fps = _framesInWindow.toDouble();
    final avgBuild =
        _framesInWindow == 0 ? 0.0 : _windowBuildSumMs / _framesInWindow;
    final avgRaster =
        _framesInWindow == 0 ? 0.0 : _windowRasterSumMs / _framesInWindow;
    final notifiesPerSec = _notifiesInWindow;

    if (notifiesPerSec >= 15) {
      logEvent(
        level: 'WARN',
        category: 'UI',
        subsystem: 'ui_notify',
        message: 'Шторм перерисовок UI: $notifiesPerSec вызовов notifyListeners/сек',
      );
    }

    _framesInWindow = 0;
    _windowBuildSumMs = 0;
    _windowRasterSumMs = 0;
    _notifiesInWindow = 0;

    _cpuHistory.add(cpuTotal);
    if (_cpuHistory.length > 60) _cpuHistory.removeAt(0);
    _ramHistory.add(workingSetMb);
    if (_ramHistory.length > 60) _ramHistory.removeAt(0);

    _resources = ProcessResourceSnapshot(
      pid: _pid,
      logicalCores: cores,
      cpuTotalPercent: cpuTotal,
      cpuUserPercent: cpuUser,
      cpuKernelPercent: cpuKernel,
      peakCpuPercent: _peakCpuPercent,
      workingSetMb: workingSetMb,
      peakWorkingSetMb: peakWorkingSetMb,
      privateMb: privateMb,
      handleCount: handles,
      gdiObjects: gdi,
      userObjects: userObj,
      fps: fps,
      avgBuildMs: avgBuild,
      maxBuildMs: _maxBuildMs,
      avgRasterMs: avgRaster,
      maxRasterMs: _maxRasterMs,
      jankFrames: _jankFrames,
      severeFreezeFrames: _severeFreezeFrames,
      uiNotifiesPerSec: notifiesPerSec,
      totalUiNotifies: _totalNotifies,
      uptime: DateTime.now().difference(_startedAt),
    );
  }

  /// Быстрый замер длительности операции подсистемы.
  /// При [enabled] == false — мгновенный выход без аллокаций.
  void recordDuration(
    String subsystemId,
    double durationMs, {
    String? detail,
    bool isError = false,
  }) {
    if (!_enabled || _disposed) return;
    _recordInternal(
      subsystemId,
      durationMs,
      detail: detail,
      isError: isError,
      emitSlowLog: true,
    );
  }

  /// Удобная обёртка для замера синхронных операций.
  T trackSync<T>(
    String subsystemId,
    T Function() fn, {
    String? detail,
  }) {
    if (!_enabled || _disposed) return fn();
    final sw = Stopwatch()..start();
    try {
      return fn();
    } catch (e) {
      sw.stop();
      _recordInternal(
        subsystemId,
        sw.elapsedMicroseconds / 1000.0,
        detail: '${detail ?? ''} -> ERR: $e'.trim(),
        isError: true,
        emitSlowLog: true,
      );
      rethrow;
    } finally {
      if (sw.isRunning) {
        sw.stop();
        _recordInternal(
          subsystemId,
          sw.elapsedMicroseconds / 1000.0,
          detail: detail,
          emitSlowLog: true,
        );
      }
    }
  }

  /// Удобная обёртка для замера асинхронных операций.
  Future<T> trackAsync<T>(
    String subsystemId,
    Future<T> Function() fn, {
    String? detail,
  }) async {
    if (!_enabled || _disposed) return fn();
    final sw = Stopwatch()..start();
    try {
      return await fn();
    } catch (e) {
      sw.stop();
      _recordInternal(
        subsystemId,
        sw.elapsedMicroseconds / 1000.0,
        detail: '${detail ?? ''} -> ERR: $e'.trim(),
        isError: true,
        emitSlowLog: true,
      );
      rethrow;
    } finally {
      if (sw.isRunning) {
        sw.stop();
        _recordInternal(
          subsystemId,
          sw.elapsedMicroseconds / 1000.0,
          detail: detail,
          emitSlowLog: true,
        );
      }
    }
  }

  void recordUiNotify(String source) {
    if (!_enabled || _disposed) return;
    _notifiesInWindow++;
    _totalNotifies++;
    _notifySources[source] = (_notifySources[source] ?? 0) + 1;
    final prof = _subsystems['ui_notify'];
    if (prof != null) {
      prof.calls++;
      prof.lastRunAt = DateTime.now();
      prof.lastDetail = source;
    }
  }

  void _recordInternal(
    String subsystemId,
    double durationMs, {
    String? detail,
    bool isError = false,
    bool emitSlowLog = true,
  }) {
    final prof = _subsystems.putIfAbsent(
      subsystemId,
      () => SubsystemProfile(
        id: subsystemId,
        label: subsystemId,
        category: 'SYSTEM',
        slowThresholdMs: 50,
      ),
    );

    prof.calls++;
    prof.lastMs = durationMs;
    if (durationMs > prof.maxMs) prof.maxMs = durationMs;
    prof.totalMs += durationMs;
    prof.lastRunAt = DateTime.now();
    if (detail != null && detail.isNotEmpty) {
      prof.lastDetail = detail;
    }
    if (isError) {
      prof.errorCount++;
      logEvent(
        level: 'ERR',
        category: prof.category,
        subsystem: subsystemId,
        durationMs: durationMs,
        message: 'Ошибка в ${prof.label}: ${detail ?? 'неизвестная ошибка'}',
      );
      return;
    }

    if (durationMs >= prof.slowThresholdMs) {
      prof.slowCount++;
      if (emitSlowLog) {
        final suffix = (detail != null && detail.isNotEmpty) ? ' ($detail)' : '';
        logEvent(
          level: 'PERF',
          category: prof.category,
          subsystem: subsystemId,
          durationMs: durationMs,
          message:
              'Медленная операция ${prof.id}: ${durationMs.toStringAsFixed(1)} мс (порог ${prof.slowThresholdMs.toStringAsFixed(0)} мс)$suffix',
        );
      }
    }
  }

  void logEvent({
    required String level,
    required String category,
    required String subsystem,
    required String message,
    double? durationMs,
  }) {
    if (!_enabled || _disposed) return;
    _events.insert(
      0,
      DebugEventEntry(
        timestamp: DateTime.now(),
        level: level,
        category: category,
        subsystem: subsystem,
        message: message,
        durationMs: durationMs,
      ),
    );
    if (_events.length > 500) {
      _events.removeLast();
    }
  }

  /// Автоматический анализ узких мест и потенциальных утечек.
  List<DetectedIssue> detectProblems() {
    if (!_enabled) return const [];
    final issues = <DetectedIssue>[];

    if (_resources.cpuTotalPercent >= 15.0 || _resources.peakCpuPercent >= 35.0) {
      issues.add(DetectedIssue(
        severity: 'HIGH',
        title: 'Высокая загрузка процессора',
        description:
            'Текущий CPU: ${_resources.cpuTotalPercent.toStringAsFixed(1)}%, пик: ${_resources.peakCpuPercent.toStringAsFixed(1)}%. Проверьте подсистемы с наибольшим суммарным временем ниже.',
      ));
    }

    if (_resources.severeFreezeFrames > 0) {
      issues.add(DetectedIssue(
        severity: 'HIGH',
        title: 'Обнаружены фризы интерфейса (>50 мс)',
        description:
            'Тяжёлых кадров: ${_resources.severeFreezeFrames}, всего лагов >16.6мс: ${_resources.jankFrames}, макс. UI build: ${_resources.maxBuildMs.toStringAsFixed(1)} мс.',
      ));
    }

    if (_resources.uiNotifiesPerSec >= 10) {
      issues.add(DetectedIssue(
        severity: 'MED',
        title: 'Частые перерисовки UI',
        description:
            '${_resources.uiNotifiesPerSec} вызовов notifyListeners/сек. Основной источник — проверьте таблицу источников ниже.',
      ));
    }

    if (_initialHandles > 0 && _resources.handleCount - _initialHandles > 150) {
      issues.add(DetectedIssue(
        severity: 'HIGH',
        title: 'Подозрение на утечку Win32 Handles',
        description:
            'Число дескрипторов выросло с $_initialHandles до ${_resources.handleCount} (+${_resources.handleCount - _initialHandles}).',
      ));
    }

    for (final s in sortedSubsystems) {
      if (s.errorCount > 0) {
        issues.add(DetectedIssue(
          severity: 'HIGH',
          title: 'Ошибки в подсистеме «${s.label}» (${s.errorCount})',
          description: s.lastDetail.isNotEmpty
              ? 'Последняя деталь: ${s.lastDetail}'
              : 'Зафиксированы ошибки выполнения.',
        ));
      } else if (s.slowCount >= 2 && s.id != 'ui_frame_build' && s.id != 'ui_frame_raster') {
        issues.add(DetectedIssue(
          severity: 'MED',
          title: 'Медленная подсистема: ${s.label}',
          description:
              'Превышений порога (${s.slowThresholdMs.toStringAsFixed(0)} мс): ${s.slowCount} из ${s.calls} вызовов · средн. ${s.avgMs.toStringAsFixed(1)} мс · макс. ${s.maxMs.toStringAsFixed(1)} мс.',
        ));
      }
    }

    return issues;
  }

  /// Формирует полный подробный текстовый отчёт для анализа и отправки разработчику.
  String buildTextReport({
    String? modemSummary,
    String? voiceSummary,
  }) {
    final r = _resources;
    final sb = StringBuffer();
    sb.writeln('=== HUAWEI E173 PORTABLE MANAGER — ПОЛНЫЙ ОТЧЁТ ОТЛАДКИ ===');
    sb.writeln('Время отчёта: ${DateTime.now().toIso8601String()}');
    sb.writeln('Статус профилировщика: ${_enabled ? 'ВКЛЮЧЁН' : 'ВЫКЛЮЧЕН'}');
    sb.writeln('PID: ${r.pid} | Логических ядер CPU: ${r.logicalCores} | Аптайм профилирования: ${r.uptime.inSeconds} сек');
    if (modemSummary != null) sb.writeln('Модем: $modemSummary');
    if (voiceSummary != null) sb.writeln('Голос/аудио: $voiceSummary');
    sb.writeln('');
    sb.writeln('--- РЕСУРСЫ ПРОЦЕССА ---');
    sb.writeln('CPU: ${r.cpuTotalPercent.toStringAsFixed(2)}% (User: ${r.cpuUserPercent.toStringAsFixed(2)}%, Kernel: ${r.cpuKernelPercent.toStringAsFixed(2)}%, Пик: ${r.peakCpuPercent.toStringAsFixed(2)}%)');
    sb.writeln('RAM: WorkingSet=${r.workingSetMb.toStringAsFixed(1)} МБ (Пик=${r.peakWorkingSetMb.toStringAsFixed(1)} МБ), Private=${r.privateMb.toStringAsFixed(1)} МБ');
    sb.writeln('Win32 Handles: ${r.handleCount} (старт: $_initialHandles) | GDI: ${r.gdiObjects} | USER: ${r.userObjects}');
    sb.writeln('Flutter UI: FPS=${r.fps.toStringAsFixed(0)} | build avg=${r.avgBuildMs.toStringAsFixed(2)}мс max=${r.maxBuildMs.toStringAsFixed(1)}мс | raster avg=${r.avgRasterMs.toStringAsFixed(2)}мс max=${r.maxRasterMs.toStringAsFixed(1)}мс');
    sb.writeln('Фризы: >16.6мс=${r.jankFrames}, >50мс=${r.severeFreezeFrames} | UI notify: ${r.uiNotifiesPerSec}/сек (всего ${r.totalUiNotifies})');
    sb.writeln('');

    final problems = detectProblems();
    sb.writeln('--- ОБНАРУЖЕННЫЕ ПРОБЛЕМЫ (${problems.length}) ---');
    if (problems.isEmpty) {
      sb.writeln('Проблем и узких мест не обнаружено.');
    } else {
      for (final p in problems) {
        sb.writeln('[${p.severity}] ${p.title}: ${p.description}');
      }
    }
    sb.writeln('');

    sb.writeln('--- ПРОФИЛЬ ПОДСИСТЕМ (СОРТИРОВКА ПО НАГРУЗКЕ) ---');
    final tot = totalTrackedMs > 0 ? totalTrackedMs : 1.0;
    for (final s in sortedSubsystems) {
      if (s.calls == 0) continue;
      final share = (s.totalMs / tot * 100.0).toStringAsFixed(1);
      sb.writeln(
        '${s.id.padRight(20)} | выз: ${s.calls.toString().padLeft(5)} | ср: ${s.avgMs.toStringAsFixed(2).padLeft(7)} мс | макс: ${s.maxMs.toStringAsFixed(1).padLeft(7)} мс | сумма: ${s.totalMs.toStringAsFixed(1).padLeft(8)} мс ($share%) | медл: ${s.slowCount} | ош: ${s.errorCount}${s.lastDetail.isNotEmpty ? ' | ${s.lastDetail}' : ''}',
      );
    }
    sb.writeln('');

    if (_notifySources.isNotEmpty) {
      sb.writeln('--- ИСТОЧНИКИ ПЕРЕРИСОВОК UI (notifyListeners) ---');
      final entries = _notifySources.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      for (final e in entries) {
        sb.writeln('  ${e.key}: ${e.value}');
      }
      sb.writeln('');
    }

    sb.writeln('--- ПОСЛЕДНИЕ СОБЫТИЯ ОТЛАДКИ (до 150) ---');
    for (final ev in _events.take(150)) {
      sb.writeln(
          '[${ev.timeLabel}] [${ev.level}] [${ev.category}/${ev.subsystem}] ${ev.message}');
    }
    return sb.toString();
  }

  Future<String> exportReportToFile({
    String? modemSummary,
    String? voiceSummary,
  }) async {
    await AppPaths.ensureDirectories();
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp =
        '${now.year}${two(now.month)}${two(now.day)}_${two(now.hour)}${two(now.minute)}${two(now.second)}';
    final path = p.join(AppPaths.exportsDir, 'debug_report_$stamp.txt');
    final report = buildTextReport(
      modemSummary: modemSummary,
      voiceSummary: voiceSummary,
    );
    await File(path).writeAsString(report);
    return path;
  }

  void _safeNotify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _stopSampleTimer();
    _unregisterFrameTimings();
    super.dispose();
  }
}
