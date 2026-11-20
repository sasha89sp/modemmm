import { OPERATOR_PRESETS } from '../data/presets';
import { GeneratedFile, ProjectConfig } from '../types/project';

function sanitizePackageName(name: string): string {
  const cleaned = name
    .toLowerCase()
    .replace(/[^a-z0-9_]/g, '_')
    .replace(/^[^a-z]+/, '')
    .replace(/_+/g, '_');
  return cleaned.length >= 3 ? cleaned : 'huawei_e173_manager';
}

function escapeDartString(value: string): string {
  return value.replace(/\\/g, '\\\\').replace(/'/g, "\\'").replace(/\$/g, '\\$');
}

export function generateFlutterProject(config: ProjectConfig): GeneratedFile[] {
  const pkg = sanitizePackageName(config.packageName);
  const preset =
    OPERATOR_PRESETS.find((p) => p.id === config.defaultOperatorId) ||
    OPERATOR_PRESETS[0];
  const defaultApn =
    config.defaultOperatorId === 'custom' ? config.customApn : preset.apn;
  const defaultDial =
    config.defaultOperatorId === 'custom'
      ? config.customDialNumber
      : preset.dialNumber;

  const ussdListDart = config.ussdShortcuts
    .map(
      (u) =>
        `    UssdShortcut(label: '${escapeDartString(u.label)}', code: '${escapeDartString(u.code)}'),`
    )
    .join('\n');

  const pubspecYaml = `name: ${pkg}
description: "${config.appTitle.replace(/"/g, '\\"')} — портативная Windows-утилита на Flutter для USB-модема Huawei E173."
publish_to: 'none'
version: ${config.version}

environment:
  sdk: '>=3.4.0 <4.0.0'

dependencies:
  flutter:
    sdk: flutter
  ffi: ^2.1.3

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^4.0.0

flutter:
  uses-material-design: true
`;

  const gitignore = `.dart_tool/
.packages
.pub-cache/
.pub/
build/
windows/flutter/ephemeral/
*.zip
config.json
huawei_e173.pbk
`;

  const releaseStep = config.githubReleaseOnTag
    ? `
      - name: Создать GitHub Release при пуше тега v*
        if: startsWith(github.ref, 'refs/tags/v')
        uses: softprops/action-gh-release@v2
        with:
          files: \${{ env.ARCHIVE_NAME }}
          generate_release_notes: true
`
    : '';

  const launcherStep = config.githubIncludeSfxBatch
    ? `          @'
@echo off
cd /d "%~dp0"
start "" "${pkg}.exe"
'@ | Set-Content -Path "$outDir\\Start_Portable.bat" -Encoding ASCII
`
    : '';

  const workflowYaml = `name: Build Portable Windows (Huawei E173)

on:
  push:
    branches: [ main, master ]
    tags: [ 'v*' ]
  workflow_dispatch:

permissions:
  contents: write

env:
  APP_NAME: ${pkg}
  APP_TITLE: "${config.appTitle.replace(/"/g, '\\"')}"

jobs:
  build-windows-portable:
    runs-on: windows-latest

    steps:
      - name: Загрузить исходный код
        uses: actions/checkout@v4

      - name: Установить Flutter (stable)
        uses: subosito/flutter-action@v2
        with:
          channel: stable
          cache: true

      - name: Сгенерировать нативный Windows Runner (если отсутствует)
        shell: pwsh
        run: |
          if (-not (Test-Path "windows")) {
            Copy-Item "pubspec.yaml" "pubspec.yaml.bak"
            Copy-Item "lib/main.dart" "main.dart.bak"
            flutter create --platforms=windows --project-name \${{ env.APP_NAME }} .
            Move-Item -Force "pubspec.yaml.bak" "pubspec.yaml"
            Move-Item -Force "main.dart.bak" "lib/main.dart"
          }
          if (Test-Path "windows/runner/main.cpp") {
            (Get-Content "windows/runner/main.cpp") -replace 'window\\.Create\\(L"[^"]*"', 'window.Create(L"${config.appTitle.replace(/"/g, '')}"' | Set-Content "windows/runner/main.cpp"
          }

      - name: Установить зависимости Flutter
        run: flutter pub get

      - name: Собрать Release для Windows x64
        run: flutter build windows --release

      - name: Упаковать портативную сборку в ZIP
        shell: pwsh
        run: |
          $outDir = "dist/\${{ env.APP_NAME }}-portable-win64"
          New-Item -ItemType Directory -Force -Path $outDir | Out-Null
          Copy-Item -Recurse -Force "build/windows/x64/runner/Release/*" $outDir
          "PORTABLE_MODE=1" | Set-Content -Path "$outDir/portable.flag" -Encoding UTF8
${launcherStep}          $archive = "\${{ env.APP_NAME }}-portable-win64.zip"
          Compress-Archive -Path "$outDir/*" -DestinationPath $archive -Force
          "ARCHIVE_NAME=$archive" >> $env:GITHUB_ENV

      - name: Загрузить портативный ZIP как артефакт сборки
        uses: actions/upload-artifact@v4
        with:
          name: \${{ env.APP_NAME }}-portable-win64
          path: \${{ env.ARCHIVE_NAME }}
          retention-days: 30
${releaseStep}`;

  const modelsDart = `class ComPortInfo {
  final String port;
  final String description;
  final String deviceId;
  final bool isHuaweiPcUi;

  const ComPortInfo({
    required this.port,
    required this.description,
    required this.deviceId,
    required this.isHuaweiPcUi,
  });

  String get displayLabel =>
      description.isNotEmpty ? '$port — $description' : port;
}

class ModemInfo {
  final String manufacturer;
  final String model;
  final String revision;
  final String imei;
  final String imsi;
  final String simStatus;
  final String operatorName;
  final int rssi;
  final int? dbm;
  final String networkType;
  final String cardLockStatus;

  const ModemInfo({
    this.manufacturer = 'Huawei',
    this.model = 'E173',
    this.revision = '—',
    this.imei = '—',
    this.imsi = '—',
    this.simStatus = 'Неизвестно',
    this.operatorName = 'Поиск сети...',
    this.rssi = 99,
    this.dbm,
    this.networkType = 'Нет сети',
    this.cardLockStatus = '—',
  });

  int get signalBars {
    if (rssi == 99 || rssi <= 1) return 0;
    if (rssi <= 7) return 1;
    if (rssi <= 13) return 2;
    if (rssi <= 19) return 3;
    if (rssi <= 25) return 4;
    return 5;
  }

  ModemInfo copyWith({
    String? manufacturer,
    String? model,
    String? revision,
    String? imei,
    String? imsi,
    String? simStatus,
    String? operatorName,
    int? rssi,
    int? dbm,
    String? networkType,
    String? cardLockStatus,
  }) {
    return ModemInfo(
      manufacturer: manufacturer ?? this.manufacturer,
      model: model ?? this.model,
      revision: revision ?? this.revision,
      imei: imei ?? this.imei,
      imsi: imsi ?? this.imsi,
      simStatus: simStatus ?? this.simStatus,
      operatorName: operatorName ?? this.operatorName,
      rssi: rssi ?? this.rssi,
      dbm: dbm ?? this.dbm,
      networkType: networkType ?? this.networkType,
      cardLockStatus: cardLockStatus ?? this.cardLockStatus,
    );
  }
}

class SmsMessageItem {
  final int index;
  final String status;
  final String sender;
  final String timestamp;
  final String body;

  const SmsMessageItem({
    required this.index,
    required this.status,
    required this.sender,
    required this.timestamp,
    required this.body,
  });
}

class UssdShortcut {
  final String label;
  final String code;

  const UssdShortcut({required this.label, required this.code});

  Map<String, dynamic> toJson() => {'label': label, 'code': code};

  factory UssdShortcut.fromJson(Map<String, dynamic> json) {
    return UssdShortcut(
      label: json['label']?.toString() ?? '',
      code: json['code']?.toString() ?? '',
    );
  }
}
`;

  const portableConfigDart = `import 'dart:convert';
import 'dart:io';
import '../models/modem_models.dart';

/// Хранит настройки в файле config.json рядом с исполняемым .exe (портативный режим).
class PortableConfig {
  String lastPort;
  int baudRate;
  bool autoConnect;
  String apn;
  String dialNumber;
  String rasUsername;
  String rasPassword;
  List<UssdShortcut> ussdShortcuts;

  PortableConfig({
    this.lastPort = '',
    this.baudRate = ${config.defaultBaudRate},
    this.autoConnect = ${config.autoConnectPort},
    this.apn = '${escapeDartString(defaultApn)}',
    this.dialNumber = '${escapeDartString(defaultDial)}',
    this.rasUsername = '${escapeDartString(preset.username)}',
    this.rasPassword = '${escapeDartString(preset.password)}',
    List<UssdShortcut>? ussdShortcuts,
  }) : ussdShortcuts = ussdShortcuts ?? defaultShortcuts;

  static List<UssdShortcut> get defaultShortcuts => const [
${ussdListDart}
      ];

  static String get baseDirectory {
    ${
      config.portableConfigNextToExe
        ? `return File(Platform.resolvedExecutable).parent.path;`
        : `return Directory.current.path;`
    }
  }

  static File get configFile => File('\$baseDirectory\${Platform.pathSeparator}config.json');

  static Future<PortableConfig> load() async {
    try {
      final file = configFile;
      if (await file.exists()) {
        final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        final shortcutsRaw = raw['ussdShortcuts'] as List<dynamic>?;
        return PortableConfig(
          lastPort: raw['lastPort']?.toString() ?? '',
          baudRate: (raw['baudRate'] as num?)?.toInt() ?? ${config.defaultBaudRate},
          autoConnect: raw['autoConnect'] as bool? ?? ${config.autoConnectPort},
          apn: raw['apn']?.toString() ?? '${escapeDartString(defaultApn)}',
          dialNumber: raw['dialNumber']?.toString() ?? '${escapeDartString(defaultDial)}',
          rasUsername: raw['rasUsername']?.toString() ?? '',
          rasPassword: raw['rasPassword']?.toString() ?? '',
          ussdShortcuts: shortcutsRaw != null
              ? shortcutsRaw
                  .map((e) => UssdShortcut.fromJson(e as Map<String, dynamic>))
                  .toList()
              : defaultShortcuts,
        );
      }
    } catch (_) {
      // Возвращаем настройки по умолчанию при повреждении JSON
    }
    return PortableConfig();
  }

  Future<void> save() async {
    final data = {
      'lastPort': lastPort,
      'baudRate': baudRate,
      'autoConnect': autoConnect,
      'apn': apn,
      'dialNumber': dialNumber,
      'rasUsername': rasUsername,
      'rasPassword': rasPassword,
      'ussdShortcuts': ussdShortcuts.map((e) => e.toJson()).toList(),
    };
    await configFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(data),
    );
  }
}
`;

  const ucs2CodecDart = `/// Кодировщик/декодировщик UCS2 Hex для кириллических SMS и USSD модема Huawei E173.
class Ucs2Codec {
  static String encodeHex(String text) {
    final buffer = StringBuffer();
    for (final unit in text.codeUnits) {
      buffer.write(unit.toRadixString(16).toUpperCase().padLeft(4, '0'));
    }
    return buffer.toString();
  }

  static String decodeHex(String input) {
    final clean = input.trim().replaceAll('"', '');
    final isHex = RegExp(r'^[0-9A-Fa-f]+\$').hasMatch(clean);
    if (!isHex || clean.length < 4 || clean.length % 4 != 0) {
      return clean;
    }
    final units = <int>[];
    for (var i = 0; i < clean.length; i += 4) {
      units.add(int.parse(clean.substring(i, i + 4), radix: 16));
    }
    return String.fromCharCodes(units);
  }

  /// Попытка декодировать ответ USSD (UCS2 Hex или обычный ASCII/GSM текст).
  static String decodeSmart(String raw) {
    final trimmed = raw.trim().replaceAll('"', '');
    if (trimmed.isEmpty) return '';
    final hexOnly = RegExp(r'^[0-9A-Fa-f]+\$').hasMatch(trimmed);
    if (hexOnly && trimmed.length % 4 == 0) {
      final decoded = decodeHex(trimmed);
      if (decoded.trim().isNotEmpty) return decoded;
    }
    return trimmed;
  }
}
`;

  const win32SerialDart = `import 'dart:async';
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

typedef _GetSetCommStateNative = Int32 Function(IntPtr hFile, Pointer<DCB> lpDCB);
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
    _createFileW = _kernel32.lookupFunction<_CreateFileWNative, _CreateFileWDart>('CreateFileW');
    _getCommState = _kernel32.lookupFunction<_GetSetCommStateNative, _GetSetCommStateDart>('GetCommState');
    _setCommState = _kernel32.lookupFunction<_GetSetCommStateNative, _GetSetCommStateDart>('SetCommState');
    _setCommTimeouts = _kernel32.lookupFunction<_SetCommTimeoutsNative, _SetCommTimeoutsDart>('SetCommTimeouts');
    _purgeComm = _kernel32.lookupFunction<_PurgeCommNative, _PurgeCommDart>('PurgeComm');
    _readFile = _kernel32.lookupFunction<_ReadWriteFileNative, _ReadWriteFileDart>('ReadFile');
    _writeFile = _kernel32.lookupFunction<_ReadWriteFileNative, _ReadWriteFileDart>('WriteFile');
    _closeHandle = _kernel32.lookupFunction<_CloseHandleNative, _CloseHandleDart>('CloseHandle');
    _getLastError = _kernel32.lookupFunction<_GetLastErrorNative, _GetLastErrorDart>('GetLastError');
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
          r"Get-CimInstance Win32_PnPEntity | Where-Object { \$_.Name -match '\\(COM\\d+\\)' } | Select-Object Name, DeviceID | ConvertTo-Json -Compress",
        ],
      );

      final out = (proc.stdout as String).trim();
      if (out.isNotEmpty) {
        final decoded = jsonDecode(out);
        final list = decoded is List ? decoded : [decoded];
        final comRegex = RegExp(r'\\((COM\\d+)\\)');

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
      // Резервный поиск через реестр Windows
      final reg = await Process.run(
        'reg',
        ['query', r'HKLM\\HARDWARE\\DEVICEMAP\\SERIALCOMM'],
      );
      final matches = RegExp(r'COM\\d+').allMatches(reg.stdout.toString());
      for (final m in matches) {
        final p = m.group(0)!;
        if (!results.any((e) => e.port == p)) {
          results.add(ComPortInfo(
            port: p,
            description: 'Последовательный порт \$p',
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

  void open(String port, {int baudRate = ${config.defaultBaudRate}}) {
    close();
    final path = '\\\\\\\\.\\\\\${port.trim().toUpperCase()}';
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
          'Не удалось открыть $port (код Win32: \${_getLastError()}). Проверьте, не занят ли порт.',
        );
      }
      _handle = h;
      _portName = port;

      final dcb = calloc<DCB>();
      final timeouts = calloc<COMMTIMEOUTS>();
      try {
        dcb.ref.dcbLength = sizeOf<DCB>();
        if (_getCommState(_handle, dcb) == 0) {
          throw StateError('Ошибка GetCommState: \${_getLastError()}');
        }
        dcb.ref.baudRate = baudRate;
        dcb.ref.byteSize = 8;
        dcb.ref.parity = 0; // NOPARITY
        dcb.ref.stopBits = 0; // ONESTOPBIT
        // fBinary=1, fDtrControl=ENABLE (1), fRtsControl=ENABLE (1)
        dcb.ref.flags = 0x00001011;

        if (_setCommState(_handle, dcb) == 0) {
          throw StateError('Ошибка SetCommState: \${_getLastError()}');
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
        throw StateError('Ошибка записи в COM-порт: \${_getLastError()}');
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
      final payload = utf8.encode('\$command\\r');
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
          if (text.contains('\\r\\nOK\\r\\n') ||
              text.trimRight().endsWith('OK') ||
              text.contains('\\r\\nERROR\\r\\n') ||
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
`;

  const huaweiServiceDart = `import '../models/modem_models.dart';
import 'ucs2_codec.dart';
import 'win32_serial.dart';

/// Сервис протокола AT-команд для модема Huawei E173 (3G HSPA).
class HuaweiE173Service {
  final Win32SerialPort serial;
  final void Function(String direction, String line)? onLog;

  HuaweiE173Service(this.serial, {this.onLog});

  Future<String> exec(
    String cmd, {
    Duration timeout = const Duration(seconds: 3),
    String? expectToken,
  }) async {
    onLog?.call('TX', cmd);
    final response = await serial.sendCommand(
      cmd,
      timeout: timeout,
      expectToken: expectToken,
    );
    for (final line in response.split(RegExp(r'[\\r\\n]+'))) {
      final clean = line.trim();
      if (clean.isNotEmpty && clean != cmd) {
        onLog?.call('RX', clean);
      }
    }
    return response;
  }

  Future<void> initialize() async {
    await exec('ATE0');
    await exec('AT+CMEE=2');
  }

  Future<ModemInfo> refreshAll() async {
    final ati = await exec('ATI');
    final imsiRaw = await exec('AT+CIMI');
    final cpinRaw = await exec('AT+CPIN?');
    final csqRaw = await exec('AT+CSQ');
    final copsRaw = await exec('AT+COPS?');
    final sysinfoRaw = await exec('AT^SYSINFO');
    final cardlockRaw = await exec('AT^CARDLOCK?');

    final manufacturer = _extractLineValue(ati, 'Manufacturer:') ?? 'Huawei';
    final model = _extractLineValue(ati, 'Model:') ?? 'E173';
    final revision = _extractLineValue(ati, 'Revision:') ?? '—';
    final imei = _extractLineValue(ati, 'IMEI:') ?? '—';
    final imsi = RegExp(r'\\d{14,16}').firstMatch(imsiRaw)?.group(0) ?? '—';

    var simStatus = 'Нет SIM';
    if (cpinRaw.contains('READY')) {
      simStatus = 'SIM готова';
    } else if (cpinRaw.contains('SIM PIN')) {
      simStatus = 'Требуется PIN';
    } else if (cpinRaw.contains('SIM PUK')) {
      simStatus = 'Требуется PUK';
    }

    int rssi = 99;
    final csqMatch = RegExp(r'\\+CSQ:\\s*(\\d+),').firstMatch(csqRaw);
    if (csqMatch != null) {
      rssi = int.tryParse(csqMatch.group(1)!) ?? 99;
    }
    final dbm = (rssi >= 0 && rssi <= 31) ? (-113 + rssi * 2) : null;

    var operatorName = 'Не зарегистрирован';
    final copsMatch = RegExp(r'\\+COPS:\\s*\\d+,\\d+,"([^"]+)"').firstMatch(copsRaw);
    if (copsMatch != null) {
      operatorName = Ucs2Codec.decodeSmart(copsMatch.group(1)!);
    }

    final networkType = _parseSysInfo(sysinfoRaw);
    final cardLockStatus = _parseCardLock(cardlockRaw);

    return ModemInfo(
      manufacturer: manufacturer,
      model: model,
      revision: revision,
      imei: imei,
      imsi: imsi,
      simStatus: simStatus,
      operatorName: operatorName,
      rssi: rssi,
      dbm: dbm,
      networkType: networkType,
      cardLockStatus: cardLockStatus,
    );
  }

  Future<List<SmsMessageItem>> readAllSms() async {
    await exec('AT+CMGF=1');
    await exec('AT+CSCS="UCS2"');
    final raw = await exec('AT+CMGL="ALL"', timeout: const Duration(seconds: 6));
    final lines = raw.split(RegExp(r'\\r?\\n'));
    final items = <SmsMessageItem>[];

    final headerRe = RegExp(
      r'^\\+CMGL:\\s*(\\d+),"([^"]*)","([^"]*)",[^,]*,"([^"]*)"',
    );

    for (var i = 0; i < lines.length; i++) {
      final m = headerRe.firstMatch(lines[i].trim());
      if (m != null) {
        final index = int.tryParse(m.group(1)!) ?? 0;
        final status = Ucs2Codec.decodeSmart(m.group(2)!);
        final sender = Ucs2Codec.decodeSmart(m.group(3)!);
        final time = m.group(4)!;
        final bodyLine = (i + 1 < lines.length) ? lines[i + 1].trim() : '';
        items.add(SmsMessageItem(
          index: index,
          status: status,
          sender: sender,
          timestamp: time,
          body: Ucs2Codec.decodeSmart(bodyLine),
        ));
      }
    }
    return items.reversed.toList();
  }

  Future<bool> sendSms(String phone, String message) async {
    await exec('AT+CMGF=1');
    await exec('AT+CSCS="UCS2"');
    await exec('AT+CSMP=17,167,0,8');

    final hexPhone = Ucs2Codec.encodeHex(phone.trim());
    final hexBody = Ucs2Codec.encodeHex(message);

    final prompt = await exec(
      'AT+CMGS="\$hexPhone"',
      timeout: const Duration(seconds: 4),
      expectToken: '>',
    );
    if (!prompt.contains('>')) {
      return false;
    }
    onLog?.call('TX', '<UCS2 SMS Payload + Ctrl+Z>');
    final result = await serial.sendRawWithCtrlZ(hexBody);
    onLog?.call('RX', result.trim());
    return result.contains('OK') || result.contains('+CMGS:');
  }

  Future<bool> deleteSms(int index) async {
    final res = await exec('AT+CMGD=\$index');
    return res.contains('OK');
  }

  Future<String> sendUssd(String code) async {
    await exec('AT+CSCS="UCS2"');
    final encoded = Ucs2Codec.encodeHex(code.trim());
    final res = await exec(
      'AT+CUSD=1,"\$encoded",15',
      timeout: const Duration(seconds: 10),
      expectToken: '+CUSD:',
    );
    final match = RegExp(r'\\+CUSD:\\s*\\d+,"([^"]+)"').firstMatch(res);
    if (match != null) {
      return Ucs2Codec.decodeSmart(match.group(1)!);
    }
    return res.trim().isEmpty
        ? 'Нет ответа от сети (проверьте порт PC UI Interface).'
        : res.trim();
  }

  Future<bool> setNetworkMode(String syscfgCommand) async {
    final res = await exec(syscfgCommand);
    return res.contains('OK');
  }

  Future<bool> setU2Diag(int mode) async {
    final res = await exec('AT^U2DIAG=\$mode');
    return res.contains('OK');
  }

  Future<bool> setApn(String apn) async {
    final res = await exec('AT+CGDCONT=1,"IP","\$apn"');
    return res.contains('OK');
  }

  Future<bool> unlockCard(String nckCode) async {
    final res = await exec('AT^CARDLOCK="\$nckCode"');
    return res.contains('OK');
  }

  Future<void> rebootModem() async {
    await exec('AT+CFUN=1,1');
  }

  String? _extractLineValue(String raw, String prefix) {
    for (final line in raw.split(RegExp(r'\\r?\\n'))) {
      final trimmed = line.trim();
      if (trimmed.startsWith(prefix)) {
        return trimmed.substring(prefix.length).trim();
      }
    }
    return null;
  }

  String _parseSysInfo(String raw) {
    final m = RegExp(r'\\^SYSINFO:(\\d+),(\\d+),(\\d+),(\\d+),(\\d+)').firstMatch(raw);
    if (m == null) return 'Неизвестно';
    final sysMode = int.tryParse(m.group(4)!) ?? 0;
    final subMode = RegExp(r'\\^SYSINFO:[^\\r\\n]*,(\\d+)\\s*\$', multiLine: true)
        .firstMatch(raw);
    final sub = subMode != null ? int.tryParse(subMode.group(1)!) ?? 0 : 0;

    if (sysMode == 3) {
      if (sub == 3) return '2G EDGE';
      return '2G GSM / GPRS';
    }
    if (sysMode == 5) {
      if (sub == 5) return '3G HSDPA';
      if (sub == 6) return '3G HSUPA';
      if (sub == 7) return '3G HSPA+';
      return '3G WCDMA';
    }
    return 'Нет сети';
  }

  String _parseCardLock(String raw) {
    final m = RegExp(r'\\^CARDLOCK:\\s*(\\d+),(\\d+),').firstMatch(raw);
    if (m == null) return 'Не определено';
    final state = m.group(1);
    final attempts = m.group(2);
    if (state == '2') return 'Разблокирован (все SIM)';
    if (state == '1') return 'Заблокирован (осталось попыток: \$attempts)';
    return 'Код статуса: \$state';
  }
}
`;

  const rasDialerDart = `import 'dart:io';
import 'portable_config.dart';

/// Управление Dial-Up соединением Windows через встроенную утилиту rasdial.exe
/// с портативной телефонной книгой huawei_e173.pbk рядом с .exe.
class RasDialer {
  static const String entryName = 'Huawei_E173_Portable';

  static File get phonebookFile => File(
        '\${PortableConfig.baseDirectory}\${Platform.pathSeparator}huawei_e173.pbk',
      );

  static Future<void> ensurePhonebook({
    required String dialNumber,
  }) async {
    final content = '''[\$entryName]
Encoding=1
Type=1
AutoLogon=0
UseRasCredentials=0
DialParamsUID=1001
BaseProtocol=1
VpnStrategy=0
ExcludedProtocols=0
LcpExtensions=1
DataEncryption=8
SwCompression=1
NegotiateMultilinkAlways=0
SkipNwcWarning=0
SkipDownLevelDialog=0
SkipDoubleDialDialog=0
DialMode=1
DialPercent=75
DialSeconds=120
HangUpPercent=10
HangUpSeconds=120
OverridePref=15
RedialAttempts=3
RedialSeconds=5
IdleDisconnectSeconds=0
RedialOnLinkFailure=1
PopupOnTopWhenRedialing=1
MEDIA=serial
Port=MODEM
Device=HUAWEI Mobile Connect - 3G Modem
PhoneNumber=\$dialNumber
''';
    await phonebookFile.writeAsString(content);
  }

  static Future<String> connect({
    required String dialNumber,
    String username = '',
    String password = '',
  }) async {
    await ensurePhonebook(dialNumber: dialNumber);
    final args = <String>[
      entryName,
      if (username.isNotEmpty) username,
      if (password.isNotEmpty) password,
      '/PHONEBOOK:\${phonebookFile.path}',
    ];
    final res = await Process.run('rasdial', args);
    final out = '\${res.stdout}\${res.stderr}'.trim();
    return out.isEmpty ? 'Команда подключения отправлена.' : out;
  }

  static Future<String> disconnect() async {
    final res = await Process.run('rasdial', [entryName, '/DISCONNECT']);
    final out = '\${res.stdout}\${res.stderr}'.trim();
    return out.isEmpty ? 'Соединение разорвано.' : out;
  }
}
`;

  const mainDart = `import 'package:flutter/material.dart';
import 'ui/modem_home.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const HuaweiE173App());
}

class HuaweiE173App extends StatelessWidget {
  const HuaweiE173App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '${escapeDartString(config.appTitle)}',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1D4ED8),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF8FAFC),
      ),
      home: const ModemHomePage(),
    );
  }
}
`;

  const modemHomeDart = `import 'dart:async';
import 'package:flutter/material.dart';
import '../models/modem_models.dart';
import '../services/huawei_e173_service.dart';
import '../services/portable_config.dart';
import '../services/ras_dialer.dart';
import '../services/win32_serial.dart';

class ModemHomePage extends StatefulWidget {
  const ModemHomePage({super.key});

  @override
  State<ModemHomePage> createState() => _ModemHomePageState();
}

class _ModemHomePageState extends State<ModemHomePage> {
  final Win32SerialPort _serial = Win32SerialPort();
  late final HuaweiE173Service _modem;

  PortableConfig _config = PortableConfig();
  List<ComPortInfo> _ports = [];
  String? _selectedPort;
  bool _connected = false;
  bool _busy = false;
  int _tabIndex = 0;

  ModemInfo _info = const ModemInfo();
  List<SmsMessageItem> _smsList = [];
  final List<String> _atLogs = [];
  String _ussdResponse = '';
  String _rasStatus = 'Отключено';

  final _smsPhoneCtrl = TextEditingController();
  final _smsBodyCtrl = TextEditingController();
  final _ussdCtrl = TextEditingController(text: '*100#');
  final _atCtrl = TextEditingController(text: 'ATI');
  final _apnCtrl = TextEditingController();
  final _nckCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _modem = HuaweiE173Service(_serial, onLog: _appendLog);
    _bootstrap();
  }

  @override
  void dispose() {
    _serial.close();
    _smsPhoneCtrl.dispose();
    _smsBodyCtrl.dispose();
    _ussdCtrl.dispose();
    _atCtrl.dispose();
    _apnCtrl.dispose();
    _nckCtrl.dispose();
    super.dispose();
  }

  void _appendLog(String dir, String line) {
    final now = TimeOfDay.now();
    final ts = '\${now.hour.toString().padLeft(2, '0')}:\${now.minute.toString().padLeft(2, '0')}';
    setState(() {
      _atLogs.insert(0, '[\$ts] \$dir  \$line');
      if (_atLogs.length > 200) _atLogs.removeLast();
    });
  }

  Future<void> _bootstrap() async {
    _config = await PortableConfig.load();
    _apnCtrl.text = _config.apn;
    await _scanPorts();
    if (_config.autoConnect && _selectedPort != null) {
      await _toggleConnection();
    }
  }

  Future<void> _scanPorts() async {
    final found = await Win32SerialPort.scanPorts();
    setState(() {
      _ports = found;
      if (_config.lastPort.isNotEmpty &&
          found.any((p) => p.port == _config.lastPort)) {
        _selectedPort = _config.lastPort;
      } else if (found.isNotEmpty) {
        _selectedPort = found.first.port;
      } else {
        _selectedPort = null;
      }
    });
  }

  Future<void> _toggleConnection() async {
    if (_connected) {
      _serial.close();
      setState(() => _connected = false);
      _appendLog('INFO', 'COM-порт закрыт');
      return;
    }
    if (_selectedPort == null) {
      _showSnack('Сначала выберите COM-порт (рекомендуется 3G PC UI Interface).');
      return;
    }
    setState(() => _busy = true);
    try {
      _serial.open(_selectedPort!, baudRate: _config.baudRate);
      _config.lastPort = _selectedPort!;
      await _config.save();
      await _modem.initialize();
      final info = await _modem.refreshAll();
      setState(() {
        _connected = true;
        _info = info;
      });
      _showSnack('Подключено к \$_selectedPort (\${info.model})');
    } catch (e) {
      _serial.close();
      _showSnack('Ошибка: \$e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _refreshStatus() async {
    if (!_connected) return;
    setState(() => _busy = true);
    try {
      final info = await _modem.refreshAll();
      setState(() => _info = info);
    } catch (e) {
      _showSnack('Ошибка обновления: \$e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _loadSms() async {
    if (!_connected) return;
    setState(() => _busy = true);
    try {
      final list = await _modem.readAllSms();
      setState(() => _smsList = list);
    } catch (e) {
      _showSnack('Ошибка чтения SMS: \$e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _sendSms() async {
    if (!_connected) return;
    if (_smsPhoneCtrl.text.trim().isEmpty || _smsBodyCtrl.text.trim().isEmpty) {
      _showSnack('Укажите номер получателя и текст сообщения.');
      return;
    }
    setState(() => _busy = true);
    try {
      final ok = await _modem.sendSms(_smsPhoneCtrl.text, _smsBodyCtrl.text);
      _showSnack(ok ? 'SMS успешно отправлено.' : 'Модем отклонил отправку SMS.');
      if (ok) _smsBodyCtrl.clear();
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _sendUssd(String code) async {
    if (!_connected) return;
    setState(() {
      _busy = true;
      _ussdResponse = 'Ожидание ответа сети...';
    });
    try {
      final reply = await _modem.sendUssd(code);
      setState(() => _ussdResponse = reply);
    } catch (e) {
      setState(() => _ussdResponse = 'Ошибка USSD: \$e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _runManualAt() async {
    if (!_connected || _atCtrl.text.trim().isEmpty) return;
    setState(() => _busy = true);
    try {
      await _modem.exec(_atCtrl.text.trim());
    } finally {
      setState(() => _busy = false);
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _tabIndex,
            extended: true,
            minExtendedWidth: 210,
            onDestinationSelected: (idx) {
              setState(() => _tabIndex = idx);
              if (idx == 1 && _connected) _loadSms();
            },
            destinations: const [
              NavigationRailDestination(
                icon: Icon(Icons.router_outlined),
                selectedIcon: Icon(Icons.router),
                label: Text('Обзор и сеть'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.sms_outlined),
                selectedIcon: Icon(Icons.sms),
                label: Text('SMS (Кириллица)'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.dialpad_outlined),
                selectedIcon: Icon(Icons.dialpad),
                label: Text('USSD-запросы'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.tune_outlined),
                selectedIcon: Icon(Icons.tune),
                label: Text('Режимы E173'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.terminal_outlined),
                selectedIcon: Icon(Icons.terminal),
                label: Text('AT-терминал'),
              ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: Column(
              children: [
                _buildTopBar(),
                const Divider(height: 1),
                Expanded(
                  child: IndexedStack(
                    index: _tabIndex,
                    children: [
                      _buildOverviewTab(),
                      _buildSmsTab(),
                      _buildUssdTab(),
                      _buildModesTab(),
                      _buildAtTerminalTab(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              value: _selectedPort,
              decoration: const InputDecoration(
                labelText: 'COM-порт Huawei E173 (PC UI Interface)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: _ports
                  .map((p) => DropdownMenuItem(
                        value: p.port,
                        child: Text(
                          p.isHuaweiPcUi ? '[Рекомендуемый] \${p.displayLabel}' : p.displayLabel,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ))
                  .toList(),
              onChanged: _connected ? null : (v) => setState(() => _selectedPort = v),
            ),
          ),
          const SizedBox(width: 12),
          IconButton.outlined(
            tooltip: 'Обновить список COM-портов',
            onPressed: _connected ? null : _scanPorts,
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: _busy ? null : _toggleConnection,
            icon: Icon(_connected ? Icons.link_off : Icons.usb),
            label: Text(_connected ? 'Отключить' : 'Подключить'),
          ),
        ],
      ),
    );
  }

  Widget _buildOverviewTab() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Состояние модема Huawei E173',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            OutlinedButton.icon(
              onPressed: _connected && !_busy ? _refreshStatus : null,
              icon: const Icon(Icons.sync),
              label: const Text('Опросить модем'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            _metricCard('Оператор', _info.operatorName, _info.networkType),
            _metricCard(
              'Уровень сигнала',
              _info.dbm != null ? '\${_info.dbm} dBm' : 'Нет данных',
              'CSQ: \${_info.rssi} / 31 · Делений: \${_info.signalBars}/5',
            ),
            _metricCard('SIM-карта', _info.simStatus, _info.cardLockStatus),
            _metricCard('Прошивка и IMEI', _info.imei, '\${_info.model} · \${_info.revision}'),
          ],
        ),
${
  config.enableRasDialer
    ? `        const SizedBox(height: 24),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Подключение к интернету (Windows RAS Dial-Up)',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _apnCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Точка доступа APN',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton(
                      onPressed: () async {
                        if (_connected) await _modem.setApn(_apnCtrl.text.trim());
                        _config.apn = _apnCtrl.text.trim();
                        await _config.save();
                        final out = await RasDialer.connect(
                          dialNumber: _config.dialNumber,
                          username: _config.rasUsername,
                          password: _config.rasPassword,
                        );
                        setState(() => _rasStatus = out);
                      },
                      child: const Text('Подключить интернет'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: () async {
                        final out = await RasDialer.disconnect();
                        setState(() => _rasStatus = out);
                      },
                      child: const Text('Разорвать'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text('Статус RAS: \$_rasStatus', style: const TextStyle(color: Colors.black54)),
              ],
            ),
          ),
        ),`
    : ''
}
      ],
    );
  }

  Widget _metricCard(String title, String value, String subtitle) {
    return SizedBox(
      width: 280,
      child: Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: Color(0xFFE2E8F0)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontSize: 12, color: Colors.black54)),
              const SizedBox(height: 6),
              Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(subtitle, style: const TextStyle(fontSize: 12, color: Colors.black54)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSmsTab() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          Row(
            children: [
              SizedBox(
                width: 200,
                child: TextField(
                  controller: _smsPhoneCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Номер (+7...)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _smsBodyCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Текст SMS (автокодирование UCS2)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: _connected && !_busy ? _sendSms : null,
                child: const Text('Отправить'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _connected && !_busy ? _loadSms : null,
                child: const Text('Обновить'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: _smsList.isEmpty
                ? const Center(child: Text('Нажмите «Обновить», чтобы загрузить SMS с модема.'))
                : ListView.separated(
                    itemCount: _smsList.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final msg = _smsList[i];
                      return ListTile(
                        title: Text('\${msg.sender}  ·  \${msg.timestamp}'),
                        subtitle: Text(msg.body),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            await _modem.deleteSms(msg.index);
                            await _loadSms();
                          },
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildUssdTab() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _config.ussdShortcuts
                .map((s) => OutlinedButton(
                      onPressed: _connected && !_busy ? () => _sendUssd(s.code) : null,
                      child: Text('\${s.label} (\${s.code})'),
                    ))
                .toList(),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              SizedBox(
                width: 240,
                child: TextField(
                  controller: _ussdCtrl,
                  decoration: const InputDecoration(
                    labelText: 'USSD-команда',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: _connected && !_busy
                    ? () => _sendUssd(_ussdCtrl.text)
                    : null,
                child: const Text('Отправить USSD'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: SelectableText(
              _ussdResponse.isEmpty ? 'Ответ оператора появится здесь.' : _ussdResponse,
              style: const TextStyle(fontSize: 15),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModesTab() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text('Режим сотовой сети (AT^SYSCFG)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            OutlinedButton(
              onPressed: _connected ? () => _modem.setNetworkMode('AT^SYSCFG=2,2,3FFFFFFF,1,2') : null,
              child: const Text('Авто (2G / 3G)'),
            ),
            OutlinedButton(
              onPressed: _connected ? () => _modem.setNetworkMode('AT^SYSCFG=14,2,3FFFFFFF,1,2') : null,
              child: const Text('Только 3G WCDMA'),
            ),
            OutlinedButton(
              onPressed: _connected ? () => _modem.setNetworkMode('AT^SYSCFG=13,1,3FFFFFFF,1,2') : null,
              child: const Text('Только 2G GSM'),
            ),
          ],
        ),
${
  config.enableU2DiagTools
    ? `        const SizedBox(height: 24),
        const Text('Композитный USB-режим Huawei E173 (AT^U2DIAG)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            OutlinedButton(
              onPressed: _connected ? () => _modem.setU2Diag(0) : null,
              child: const Text('Только модем (AT^U2DIAG=0)'),
            ),
            OutlinedButton(
              onPressed: _connected ? () => _modem.setU2Diag(256) : null,
              child: const Text('Модем + MicroSD (AT^U2DIAG=256)'),
            ),
            OutlinedButton(
              onPressed: _connected ? () => _modem.setU2Diag(255) : null,
              child: const Text('Заводской режим (AT^U2DIAG=255)'),
            ),
          ],
        ),`
    : ''
}
        const SizedBox(height: 24),
        const Text('Разблокировка NCK и перезагрузка', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        Row(
          children: [
            SizedBox(
              width: 240,
              child: TextField(
                controller: _nckCtrl,
                decoration: const InputDecoration(
                  labelText: '8-значный NCK код',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(
              onPressed: _connected
                  ? () async {
                      final ok = await _modem.unlockCard(_nckCtrl.text.trim());
                      _showSnack(ok ? 'Код принят модемом.' : 'Ошибка разблокировки.');
                    }
                  : null,
              child: const Text('Ввести NCK'),
            ),
            const SizedBox(width: 16),
            OutlinedButton(
              onPressed: _connected ? () => _modem.rebootModem() : null,
              child: const Text('Перезагрузить модем (CFUN=1,1)'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildAtTerminalTab() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _atCtrl,
                  onSubmitted: (_) => _runManualAt(),
                  decoration: const InputDecoration(
                    labelText: 'AT-команда (например ATI, AT+CSQ, AT^U2DIAG?)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: _connected && !_busy ? _runManualAt : null,
                child: const Text('Выполнить'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () => setState(() => _atLogs.clear()),
                child: const Text('Очистить'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(8),
              ),
              child: ListView.builder(
                itemCount: _atLogs.length,
                itemBuilder: (_, i) => SelectableText(
                  _atLogs[i],
                  style: const TextStyle(
                    fontFamily: 'Consolas',
                    fontSize: 13,
                    color: Color(0xFFE2E8F0),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
`;

  const readmeMd = `# ${config.appTitle}

Портативная программа для **Windows (x64)** на **Flutter**, предназначенная для работы с USB 3G-модемом **Huawei E173** без установки в систему и без внешних DLL-драйверов последовательного порта.

## Основные возможности
- Автопоиск COM-портов Windows с приоритетным выделением \`HUAWEI Mobile Connect - 3G PC UI Interface\` (\`VID_12D1\`).
- Прямая работа с COM-портом через \`dart:ffi\` и системную библиотеку \`kernel32.dll\` (не требует \`libserialport.dll\`).
- Отображение уровня сигнала (\`AT+CSQ\` → dBm / деления), оператора (\`AT+COPS?\`), типа сети (\`AT^SYSINFO\`), IMEI, IMSI, статуса SIM и блокировки \`AT^CARDLOCK?\`.
- Чтение, отправка и удаление SMS на русском языке (полная поддержка кодировки **UCS2 Hex**).
- Отправка USSD-запросов (\`*100#\`, \`*102#\`, \`*105#\`) с декодированием кириллицы.
- Переключение режимов 2G/3G (\`AT^SYSCFG\`) и композитного USB-режима (\`AT^U2DIAG=0 / 255 / 256\`).
- Портативное хранение \`config.json\` и Dial-Up книги \`huawei_e173.pbk\` прямо в папке с \`.exe\`.

## Автоматическая сборка через GitHub Actions (без установки Flutter на ПК)
1. Создайте новый репозиторий на GitHub и загрузите в него все файлы из этого архива.
2. Перейдите во вкладку **Actions** вашего репозитория и выберите workflow **Build Portable Windows (Huawei E173)**.
3. Нажмите **Run workflow** (или просто выполните \`git push\` в ветку \`main\`).
4. Через 3–5 минут в разделе **Artifacts** появится готовый портативный архив \`${pkg}-portable-win64.zip\`.
5. Распакуйте его в любую папку (или на флешку) и запустите \`${pkg}.exe\`.

### Публикация в GitHub Releases
\`\`\`bash
git tag v1.0.0
git push origin v1.0.0
\`\`\`
После пуша тега \`v*\` GitHub Actions автоматически создаст релиз и прикрепит к нему портативный ZIP-архив.
`;

  return [
    {
      path: '.github/workflows/build-windows-portable.yml',
      language: 'yaml',
      description: 'Сценарий GitHub Actions для сборки портативного Windows x64 ZIP-архива',
      content: workflowYaml,
    },
    {
      path: 'pubspec.yaml',
      language: 'yaml',
      description: 'Конфигурация Flutter-пакета (только Flutter SDK + ffi, без капризных C++ плагинов)',
      content: pubspecYaml,
    },
    {
      path: 'lib/main.dart',
      language: 'dart',
      description: 'Точка входа Windows-приложения на Flutter',
      content: mainDart,
    },
    {
      path: 'lib/services/win32_serial.dart',
      language: 'dart',
      description: 'Прямой Win32 FFI драйвер COM-порта (kernel32.dll) и сканер портов Huawei VID_12D1',
      content: win32SerialDart,
    },
    {
      path: 'lib/services/huawei_e173_service.dart',
      language: 'dart',
      description: 'Движок AT-команд Huawei E173 (CSQ, SYSINFO, SMS, USSD, SYSCFG, U2DIAG, CARDLOCK)',
      content: huaweiServiceDart,
    },
    {
      path: 'lib/services/ucs2_codec.dart',
      language: 'dart',
      description: 'Кодировщик и декодировщик UCS2 Hex для кириллицы в SMS и USSD',
      content: ucs2CodecDart,
    },
    {
      path: 'lib/services/ras_dialer.dart',
      language: 'dart',
      description: 'Портативный Dial-Up менеджер Windows RAS (rasdial.exe + локальный .pbk)',
      content: rasDialerDart,
    },
    {
      path: 'lib/services/portable_config.dart',
      language: 'dart',
      description: 'Хранилище config.json в папке с исполняемым .exe',
      content: portableConfigDart,
    },
    {
      path: 'lib/models/modem_models.dart',
      language: 'dart',
      description: 'Модели данных модема, COM-портов, SMS и USSD',
      content: modelsDart,
    },
    {
      path: 'lib/ui/modem_home.dart',
      language: 'dart',
      description: 'Графический интерфейс Windows-приложения с вкладками и терминалом',
      content: modemHomeDart,
    },
    {
      path: 'README.md',
      language: 'markdown',
      description: 'Инструкция по компиляции и запуску портативной версии',
      content: readmeMd,
    },
    {
      path: '.gitignore',
      language: 'text',
      description: 'Исключения Git для Flutter-репозитория',
      content: gitignore,
    },
  ];
}
