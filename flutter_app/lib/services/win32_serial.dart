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
/// Не требует внешних DLL (libserialport) и гарантирует 100% портативность.
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
  late final _ReadWriteFileDart _readFile;
  late final _ReadWriteFileDart _writeFile;
  late final _CloseHandleDart _closeHandle;
  late final _GetLastErrorDart _getLastError;

  int _handle = _invalidHandleValue;
  String? _portName;
  bool _busy = false;

  bool get isOpen => _handle != _invalidHandleValue;
  String? get portName => _portName;

  Win32SerialPort() {
    if (!Platform.isWindows) {
      throw UnsupportedError('Win32SerialPort работает только в Windows.');
    }
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
    _readFile = _kernel32
        .lookupFunction<_ReadWriteFileNative, _ReadWriteFileDart>('ReadFile');
    _writeFile = _kernel32
        .lookupFunction<_ReadWriteFileNative, _ReadWriteFileDart>('WriteFile');
    _closeHandle = _kernel32
        .lookupFunction<_CloseHandleNative, _CloseHandleDart>('CloseHandle');
    _getLastError = _kernel32
        .lookupFunction<_GetLastErrorNative, _GetLastErrorDart>('GetLastError');
  }

  /// Поиск доступных COM-портов с определением интерфейсов Huawei E173 (VID_12D1).
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
          final isPcUi = isHuawei &&
              (lower.contains('pc ui') || lower.contains('application'));

          results.add(ComPortInfo(
            port: port,
            description: name,
            deviceId: deviceId,
            isHuaweiPcUi: isPcUi,
          ));
        }
      }
    } catch (_) {
      final reg = await Process.run(
        'reg',
        ['query', r'HKLM\HARDWARE\DEVICEMAP\SERIALCOMM'],
      );
      final matches = RegExp(r'COM\d+').allMatches(reg.stdout.toString());
      for (final m in matches) {
        final p = m.group(0)!;
        if (!results.any((e) => e.port == p)) {
          results.add(ComPortInfo(
            port: p,
            description: 'Последовательный порт $p',
            deviceId: '',
            isHuaweiPcUi: false,
          ));
        }
      }
    }

    results.sort((a, b) {
      if (a.isHuaweiPcUi != b.isHuaweiPcUi) {
        return a.isHuaweiPcUi ? -1 : 1;
      }
      return a.port.compareTo(b.port);
    });
    return results;
  }

  void open(String port, {int baudRate = 115200}) {
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
          'Не удалось открыть $port (код Win32: ${_getLastError()}). Проверьте, не занят ли порт.',
        );
      }
      _handle = h;
      _portName = port;

      final dcb = calloc<DCB>();
      final timeouts = calloc<COMMTIMEOUTS>();
      try {
        dcb.ref.dcbLength = sizeOf<DCB>();
        if (_getCommState(_handle, dcb) == 0) {
          throw StateError('Ошибка GetCommState: ${_getLastError()}');
        }
        dcb.ref.baudRate = baudRate;
        dcb.ref.byteSize = 8;
        dcb.ref.parity = 0; // NOPARITY
        dcb.ref.stopBits = 0; // ONESTOPBIT
        // fBinary=1, fDtrControl=ENABLE (1), fRtsControl=ENABLE (1)
        dcb.ref.flags = 0x00001011;

        if (_setCommState(_handle, dcb) == 0) {
          throw StateError('Ошибка SetCommState: ${_getLastError()}');
        }

        timeouts.ref.readIntervalTimeout = 30;
        timeouts.ref.readTotalTimeoutMultiplier = 10;
        timeouts.ref.readTotalTimeoutConstant = 150;
        timeouts.ref.writeTotalTimeoutMultiplier = 10;
        timeouts.ref.writeTotalTimeoutConstant = 500;
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

  void writeBytes(Uint8List bytes) {
    if (!isOpen) throw StateError('Порт не открыт');
    final buf = calloc<Uint8>(bytes.length);
    final written = calloc<Uint32>();
    try {
      buf.asTypedList(bytes.length).setAll(0, bytes);
      final ok = _writeFile(_handle, buf, bytes.length, written, nullptr);
      if (ok == 0) {
        throw StateError('Ошибка записи в COM-порт: ${_getLastError()}');
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
      if (ok == 0 || readCount.value == 0) {
        return Uint8List(0);
      }
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
  }) async {
    if (!isOpen) throw StateError('Сначала подключитесь к COM-порту модема.');
    while (_busy) {
      await Future.delayed(const Duration(milliseconds: 25));
    }
    _busy = true;
    try {
      _purgeComm(_handle, _purgeRxClear);
      final payload = utf8.encode('$command\r');
      writeBytes(Uint8List.fromList(payload));

      final buffer = StringBuffer();
      final deadline = DateTime.now().add(timeout);

      while (DateTime.now().isBefore(deadline)) {
        final chunk = readAvailable();
        if (chunk.isNotEmpty) {
          buffer.write(latin1.decode(chunk, allowInvalid: true));
          final text = buffer.toString();
          if (expectToken != null && text.contains(expectToken)) {
            return text;
          }
          if (text.contains('\r\nOK\r\n') ||
              text.trimRight().endsWith('OK') ||
              text.contains('\r\nERROR\r\n') ||
              text.contains('+CMS ERROR') ||
              text.contains('+CME ERROR')) {
            return text;
          }
        }
        await Future.delayed(const Duration(milliseconds: 35));
      }
      return buffer.toString();
    } finally {
      _busy = false;
    }
  }

  Future<String> sendRawWithCtrlZ(
    String body, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (!isOpen) throw StateError('Порт не открыт');
    final bytes = <int>[...utf8.encode(body), 0x1A];
    writeBytes(Uint8List.fromList(bytes));

    final buffer = StringBuffer();
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final chunk = readAvailable();
      if (chunk.isNotEmpty) {
        buffer.write(latin1.decode(chunk, allowInvalid: true));
        final text = buffer.toString();
        if (text.contains('OK') || text.contains('ERROR')) {
          return text;
        }
      }
      await Future.delayed(const Duration(milliseconds: 50));
    }
    return buffer.toString();
  }
}
