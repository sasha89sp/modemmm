import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import '../models/modem_models.dart';

// Win32 DCB структура (28 байт)
final class DCB extends Struct {
  @Uint32()
  external int dcbLength;
  @Uint32()
  external int baudRate;
  @Uint32()
  external int flags;
  @Uint16()
  external int wReserved;
  @Uint16()
  external int xonLim;
  @Uint16()
  external int xoffLim;
  @Uint8()
  external int byteSize;
  @Uint8()
  external int parity;
  @Uint8()
  external int stopBits;
  @Int8()
  external int xonChar;
  @Int8()
  external int xoffChar;
  @Int8()
  external int errorChar;
  @Int8()
  external int eofChar;
  @Int8()
  external int evtChar;
  @Uint16()
  external int wReserved1;
}

// Win32 COMMTIMEOUTS структура (20 байт)
final class COMMTIMEOUTS extends Struct {
  @Uint32()
  external int readIntervalTimeout;
  @Uint32()
  external int readTotalTimeoutMultiplier;
  @Uint32()
  external int readTotalTimeoutConstant;
  @Uint32()
  external int writeTotalTimeoutMultiplier;
  @Uint32()
  external int writeTotalTimeoutConstant;
}

// Win32 COMSTAT (12 байт)
final class COMSTAT extends Struct {
  @Uint32()
  external int flags;
  @Uint32()
  external int cbInQue;
  @Uint32()
  external int cbOutQue;
}

typedef _CreateFileWNative = IntPtr Function(
  Pointer<Utf16> lpFileName,
  Uint32 dwDesiredAccess,
  Uint32 dwShareMode,
  Pointer<Void> lpSecurityAttributes,
  Uint32 dwCreationDisposition,
  Uint32 dwFlagsAndAttributes,
  IntPtr hTemplateFile,
);
typedef _CreateFileWDart = int Function(
  Pointer<Utf16> lpFileName,
  int dwDesiredAccess,
  int dwShareMode,
  Pointer<Void> lpSecurityAttributes,
  int dwCreationDisposition,
  int dwFlagsAndAttributes,
  int hTemplateFile,
);

typedef _GetSetCommStateNative = Int32 Function(
    IntPtr hFile, Pointer<DCB> lpDCB);
typedef _GetSetCommStateDart = int Function(int hFile, Pointer<DCB> lpDCB);

typedef _SetCommTimeoutsNative = Int32 Function(
  IntPtr hFile,
  Pointer<COMMTIMEOUTS> lpCommTimeouts,
);
typedef _SetCommTimeoutsDart = int Function(
  int hFile,
  Pointer<COMMTIMEOUTS> lpCommTimeouts,
);

typedef _PurgeCommNative = Int32 Function(IntPtr hFile, Uint32 dwFlags);
typedef _PurgeCommDart = int Function(int hFile, int dwFlags);

typedef _ClearCommErrorNative = Int32 Function(
  IntPtr hFile,
  Pointer<Uint32> lpErrors,
  Pointer<COMSTAT> lpStat,
);
typedef _ClearCommErrorDart = int Function(
  int hFile,
  Pointer<Uint32> lpErrors,
  Pointer<COMSTAT> lpStat,
);

typedef _ReadWriteFileNative = Int32 Function(
  IntPtr hFile,
  Pointer<Uint8> lpBuffer,
  Uint32 nNumberOfBytesToTransfer,
  Pointer<Uint32> lpNumberOfBytesTransferred,
  Pointer<Void> lpOverlapped,
);
typedef _ReadWriteFileDart = int Function(
  int hFile,
  Pointer<Uint8> lpBuffer,
  int nNumberOfBytesToTransfer,
  Pointer<Uint32> lpNumberOfBytesTransferred,
  Pointer<Void> lpOverlapped,
);

typedef _CloseHandleNative = Int32 Function(IntPtr hObject);
typedef _CloseHandleDart = int Function(int hObject);

typedef _GetLastErrorNative = Uint32 Function();
typedef _GetLastErrorDart = int Function();

/// Нативный драйвер Windows COM-порта через dart:ffi + kernel32.dll.
/// Поддерживает мгновенное освобождение при извлечении USB и чтение URC (+CMTI, RING, +CUSD).
class Win32SerialPort {
  static const int _invalidHandleValue = -1;
  static const int _genericReadWrite = 0xC0000000;
  static const int _openExisting = 3;
  static const int _purgeRxClear = 0x0008;
  static const int _purgeTxClear = 0x0004;

  late final DynamicLibrary _kernel32;
  late final _CreateFileWDart _createFileW;
  late final _GetSetCommStateDart _getCommState;
  late final _GetSetCommStateDart _setCommState;
  late final _SetCommTimeoutsDart _setCommTimeouts;
  late final _PurgeCommDart _purgeComm;
  late final _ClearCommErrorDart _clearCommError;
  late final _ReadWriteFileDart _readFile;
  late final _ReadWriteFileDart _writeFile;
  late final _CloseHandleDart _closeHandle;
  late final _GetLastErrorDart _getLastError;

  int _handle = _invalidHandleValue;
  String? _portName;
  bool _busy = false;
  void Function(String reason)? onUnexpectedDisconnect;
  void Function(String line)? onUnsolicitedLine;

  bool get isOpen => _handle != _invalidHandleValue;
  bool get isBusy => _busy;
  String? get portName => _portName;

  Win32SerialPort({
    this.onUnexpectedDisconnect,
    this.onUnsolicitedLine,
  }) {
    if (!Platform.isWindows) return;
    _kernel32 = DynamicLibrary.open('kernel32.dll');
    _createFileW = _kernel32
        .lookupFunction<_CreateFileWNative, _CreateFileWDart>('CreateFileW');
    _getCommState = _kernel32
        .lookupFunction<_GetSetCommStateNative, _GetSetCommStateDart>(
            'GetCommState');
    _setCommState = _kernel32
        .lookupFunction<_GetSetCommStateNative, _GetSetCommStateDart>(
            'SetCommState');
    _setCommTimeouts = _kernel32
        .lookupFunction<_SetCommTimeoutsNative, _SetCommTimeoutsDart>(
            'SetCommTimeouts');
    _purgeComm = _kernel32
        .lookupFunction<_PurgeCommNative, _PurgeCommDart>('PurgeComm');
    _clearCommError = _kernel32
        .lookupFunction<_ClearCommErrorNative, _ClearCommErrorDart>(
            'ClearCommError');
    _readFile = _kernel32
        .lookupFunction<_ReadWriteFileNative, _ReadWriteFileDart>('ReadFile');
    _writeFile = _kernel32
        .lookupFunction<_ReadWriteFileNative, _ReadWriteFileDart>('WriteFile');
    _closeHandle = _kernel32
        .lookupFunction<_CloseHandleNative, _CloseHandleDart>('CloseHandle');
    _getLastError = _kernel32
        .lookupFunction<_GetLastErrorNative, _GetLastErrorDart>('GetLastError');
  }

  /// Быстрый список активных COM-портов из реестра Windows (для экономичного мониторинга USB).
  static Future<Set<String>> listQuickPortNames() async {
    if (!Platform.isWindows) return {};
    try {
      final reg = await Process.run(
        'reg',
        ['query', r'HKLM\HARDWARE\DEVICEMAP\SERIALCOMM'],
      );
      return RegExp(r'COM\d+')
          .allMatches(reg.stdout.toString())
          .map((m) => m.group(0)!)
          .toSet();
    } catch (_) {
      return {};
    }
  }

  /// Полное сканирование COM-портов с чтением PnP-метаданных (VID_12D1, PC UI, Modem, Application/Voice).
  static Future<List<ComPortInfo>> scanPorts() async {
    final results = <ComPortInfo>[];
    if (!Platform.isWindows) return results;

    try {
      final proc = await Process.run(
        'powershell',
        [
          '-NoProfile',
          '-Command',
          r"Get-CimInstance Win32_PnPEntity | Where-Object { $_.Name -match '\(COM\d+\)' } | Select-Object Name, DeviceID | ConvertTo-Json -Compress",
        ],
      );

      final out = (proc.stdout as String).trim();
      if (out.isNotEmpty) {
        final decoded = jsonDecode(out);
        final list = decoded is List ? decoded : [decoded];
        final comRegex = RegExp(r'\((COM\d+)\)');

        for (final item in list) {
          if (item is! Map) continue;
          final name = item['Name']?.toString() ?? '';
          final deviceId = item['DeviceID']?.toString() ?? '';
          final match = comRegex.firstMatch(name);
          if (match == null) continue;
          final port = match.group(1)!;
          final lower = name.toLowerCase();
          final isHuawei = deviceId.toUpperCase().contains('VID_12D1') ||
              lower.contains('huawei');
          final isPcUi = isHuawei && lower.contains('pc ui');
          final isModem = isHuawei && lower.contains('modem');
          final isVoice = isHuawei &&
              (lower.contains('application') ||
                  lower.contains('voice') ||
                  lower.contains('audio') ||
                  lower.contains('diag'));

          results.add(ComPortInfo(
            port: port,
            description: name,
            deviceId: deviceId,
            isHuaweiPcUi: isPcUi,
            isHuaweiModem: isModem,
            isHuaweiVoiceCandidate: isVoice,
          ));
        }
      }
    } catch (_) {
      final quick = await listQuickPortNames();
      for (final p in quick) {
        results.add(ComPortInfo(
          port: p,
          description: 'Последовательный порт $p',
          deviceId: '',
          isHuaweiPcUi: false,
        ));
      }
    }

    results.sort((a, b) {
      final diff = b.priorityScore.compareTo(a.priorityScore);
      if (diff != 0) return diff;
      return a.port.compareTo(b.port);
    });
    return results;
  }

  void open(
    String port, {
    int baudRate = 115200,
    int readTimeoutMs = 120,
  }) {
    close();
    final path = '\\\\.\\${port.trim().toUpperCase()}';
    final pathPtr = path.toNativeUtf16();

    try {
      final h = _createFileW(
        pathPtr,
        _genericReadWrite,
        0,
        nullptr,
        _openExisting,
        0,
        0,
      );
      if (h == _invalidHandleValue) {
        throw StateError(
          'Не удалось открыть $port (Win32 код: ${_getLastError()}). Возможно, порт занят.',
        );
      }
      _handle = h;
      _portName = port.trim().toUpperCase();

      final dcb = calloc<DCB>();
      final timeouts = calloc<COMMTIMEOUTS>();
      try {
        dcb.ref.dcbLength = sizeOf<DCB>();
        if (_getCommState(_handle, dcb) == 0) {
          throw StateError('Ошибка GetCommState: ${_getLastError()}');
        }
        dcb.ref.baudRate = baudRate;
        dcb.ref.byteSize = 8;
        dcb.ref.parity = 0;
        dcb.ref.stopBits = 0;
        // fBinary=1, fDtrControl=ENABLE (1), fRtsControl=ENABLE (1)
        dcb.ref.flags = 0x00001011;

        if (_setCommState(_handle, dcb) == 0) {
          throw StateError('Ошибка SetCommState: ${_getLastError()}');
        }

        timeouts.ref.readIntervalTimeout = 20;
        timeouts.ref.readTotalTimeoutMultiplier = 5;
        timeouts.ref.readTotalTimeoutConstant = readTimeoutMs;
        timeouts.ref.writeTotalTimeoutMultiplier = 10;
        timeouts.ref.writeTotalTimeoutConstant = 400;
        _setCommTimeouts(_handle, timeouts);
        _purgeComm(_handle, _purgeRxClear | _purgeTxClear);
      } finally {
        calloc.free(dcb);
        calloc.free(timeouts);
      }
    } finally {
      calloc.free(pathPtr);
    }
  }

  void close() {
    if (_handle != _invalidHandleValue) {
      _closeHandle(_handle);
      _handle = _invalidHandleValue;
      _portName = null;
    }
  }

  /// Проверяет, жив ли дескриптор порта (мгновенно обнаруживает извлечение USB).
  bool checkAlive() {
    if (!isOpen) return false;
    final errs = calloc<Uint32>();
    final stat = calloc<COMSTAT>();
    try {
      final ok = _clearCommError(_handle, errs, stat);
      if (ok == 0) {
        final code = _getLastError();
        _handleDisconnect('USB-устройство извлечено (ClearCommError: $code)');
        return false;
      }
      return true;
    } finally {
      calloc.free(errs);
      calloc.free(stat);
    }
  }

  /// Вычитывает необработанные входящие байты без блокировки (для перехвата +CMTI, RING и т.д.).
  void pollUnsolicited() {
    if (!isOpen || _busy) return;
    final errs = calloc<Uint32>();
    final stat = calloc<COMSTAT>();
    int queued = 0;
    try {
      final ok = _clearCommError(_handle, errs, stat);
      if (ok == 0) {
        _handleDisconnect('USB-порт потерян при фоновом чтении');
        return;
      }
      queued = stat.ref.cbInQue;
    } finally {
      calloc.free(errs);
      calloc.free(stat);
    }

    if (queued > 0) {
      final data = readAvailable(maxBytes: queued > 4096 ? 4096 : queued);
      if (data.isNotEmpty) {
        final text = latin1.decode(data, allowInvalid: true);
        _dispatchUnsolicitedLines(text);
      }
    }
  }

  void _dispatchUnsolicitedLines(String raw) {
    final cb = onUnsolicitedLine;
    if (cb == null) return;
    for (final line in raw.split(RegExp(r'[\r\n]+'))) {
      final clean = line.trim();
      if (clean.isEmpty) continue;
      if (clean.startsWith('+CMTI:') ||
          clean.startsWith('+CDS:') ||
          clean.startsWith('+CLIP:') ||
          clean == 'RING' ||
          clean.startsWith('^CEND:') ||
          clean.startsWith('^CONN:')) {
        cb(clean);
      }
    }
  }

  void _handleDisconnect(String reason) {
    if (!isOpen) return;
    close();
    onUnexpectedDisconnect?.call(reason);
  }

  void writeBytes(Uint8List bytes) {
    if (!isOpen) throw StateError('Порт не открыт');
    final buf = calloc<Uint8>(bytes.length);
    final written = calloc<Uint32>();
    try {
      buf.asTypedList(bytes.length).setAll(0, bytes);
      final ok = _writeFile(_handle, buf, bytes.length, written, nullptr);
      if (ok == 0) {
        final code = _getLastError();
        if (code == 31 || code == 22 || code == 1167 || code == 5 || code == 6) {
          _handleDisconnect('Порт отключён при записи (Win32 код $code)');
        }
        throw StateError('Ошибка записи в COM-порт (код $code)');
      }
    } finally {
      calloc.free(buf);
      calloc.free(written);
    }
  }

  Uint8List readAvailable({int maxBytes = 4096}) {
    if (!isOpen) return Uint8List(0);
    final buf = calloc<Uint8>(maxBytes);
    final readCount = calloc<Uint32>();
    try {
      final ok = _readFile(_handle, buf, maxBytes, readCount, nullptr);
      if (ok == 0) {
        final code = _getLastError();
        if (code == 31 || code == 22 || code == 1167 || code == 5 || code == 6) {
          _handleDisconnect('Порт отключён при чтении (Win32 код $code)');
        }
        return Uint8List(0);
      }
      if (readCount.value == 0) return Uint8List(0);
      return Uint8List.fromList(buf.asTypedList(readCount.value));
    } finally {
      calloc.free(buf);
      calloc.free(readCount);
    }
  }

  Future<String> sendCommand(
    String command, {
    Duration timeout = const Duration(seconds: 3),
    String? expectToken,
    bool waitForTokenLineEnd = false,
  }) async {
    if (!isOpen) throw StateError('Сначала подключитесь к COM-порту модема.');
    while (_busy) {
      await Future.delayed(const Duration(milliseconds: 20));
    }
    _busy = true;
    try {
      // Сохраняем любые ожидающие URC до очистки буфера
      final pre = readAvailable(maxBytes: 2048);
      if (pre.isNotEmpty) {
        _dispatchUnsolicitedLines(latin1.decode(pre, allowInvalid: true));
      }

      final payload = utf8.encode('$command\r');
      writeBytes(Uint8List.fromList(payload));

      final buffer = StringBuffer();
      final deadline = DateTime.now().add(timeout);

      while (DateTime.now().isBefore(deadline)) {
        if (!isOpen) break;
        final chunk = readAvailable();
        if (chunk.isNotEmpty) {
          final decodedChunk = latin1.decode(chunk, allowInvalid: true);
          buffer.write(decodedChunk);
          _dispatchUnsolicitedLines(decodedChunk);
          final text = buffer.toString();

          if (text.contains('\r\nERROR\r\n') ||
              text.trimRight().endsWith('\nERROR') ||
              text.trim() == 'ERROR' ||
              text.contains('+CMS ERROR') ||
              text.contains('+CME ERROR')) {
            return text;
          }

          if (expectToken != null) {
            final idx = text.indexOf(expectToken);
            if (idx != -1) {
              if (!waitForTokenLineEnd) return text;
              final after = text.substring(idx);
              if (after.contains('\n') || after.contains('\r')) {
                await Future.delayed(const Duration(milliseconds: 120));
                final tail = readAvailable();
                if (tail.isNotEmpty) {
                  buffer.write(latin1.decode(tail, allowInvalid: true));
                }
                return buffer.toString();
              }
            }
          } else {
            if (text.contains('\r\nOK\r\n') ||
                text.trimRight().endsWith('OK')) {
              return text;
            }
          }
        }
        await Future.delayed(const Duration(milliseconds: 30));
      }
      return buffer.toString();
    } finally {
      _busy = false;
    }
  }

  Future<String> sendRawWithCtrlZ(
    String body, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (!isOpen) throw StateError('Порт не открыт');
    final bytes = <int>[...utf8.encode(body), 0x1A];
    writeBytes(Uint8List.fromList(bytes));

    final buffer = StringBuffer();
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (!isOpen) break;
      final chunk = readAvailable();
      if (chunk.isNotEmpty) {
        buffer.write(latin1.decode(chunk, allowInvalid: true));
        final text = buffer.toString();
        if (text.contains('OK') || text.contains('ERROR')) {
          return text;
        }
      }
      await Future.delayed(const Duration(milliseconds: 45));
    }
    return buffer.toString();
  }
}
