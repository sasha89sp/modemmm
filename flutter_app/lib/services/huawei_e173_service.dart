import '../models/modem_models.dart';
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
    for (final line in response.split(RegExp(r'[\r\n]+'))) {
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
    final imsi = RegExp(r'\d{14,16}').firstMatch(imsiRaw)?.group(0) ?? '—';

    var simStatus = 'Нет SIM';
    if (cpinRaw.contains('READY')) {
      simStatus = 'SIM готова';
    } else if (cpinRaw.contains('SIM PIN')) {
      simStatus = 'Требуется PIN';
    } else if (cpinRaw.contains('SIM PUK')) {
      simStatus = 'Требуется PUK';
    }

    int rssi = 99;
    final csqMatch = RegExp(r'\+CSQ:\s*(\d+),').firstMatch(csqRaw);
    if (csqMatch != null) {
      rssi = int.tryParse(csqMatch.group(1)!) ?? 99;
    }
    final dbm = (rssi >= 0 && rssi <= 31) ? (-113 + rssi * 2) : null;

    var operatorName = 'Не зарегистрирован';
    final copsMatch =
        RegExp(r'\+COPS:\s*\d+,\d+,"([^"]+)"').firstMatch(copsRaw);
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
    final raw =
        await exec('AT+CMGL="ALL"', timeout: const Duration(seconds: 6));
    final lines = raw.split(RegExp(r'\r?\n'));
    final items = <SmsMessageItem>[];

    final headerRe = RegExp(
      r'^\+CMGL:\s*(\d+),"([^"]*)","([^"]*)",[^,]*,"([^"]*)"',
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
      'AT+CMGS="$hexPhone"',
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
    final res = await exec('AT+CMGD=$index');
    return res.contains('OK');
  }

  Future<String> sendUssd(String code) async {
    await exec('AT+CSCS="UCS2"');
    final encoded = Ucs2Codec.encodeHex(code.trim());
    final res = await exec(
      'AT+CUSD=1,"$encoded",15',
      timeout: const Duration(seconds: 10),
      expectToken: '+CUSD:',
    );
    final match = RegExp(r'\+CUSD:\s*\d+,"([^"]+)"').firstMatch(res);
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
    final res = await exec('AT^U2DIAG=$mode');
    return res.contains('OK');
  }

  Future<bool> setApn(String apn) async {
    final res = await exec('AT+CGDCONT=1,"IP","$apn"');
    return res.contains('OK');
  }

  Future<bool> unlockCard(String nckCode) async {
    final res = await exec('AT^CARDLOCK="$nckCode"');
    return res.contains('OK');
  }

  Future<void> rebootModem() async {
    await exec('AT+CFUN=1,1');
  }

  String? _extractLineValue(String raw, String prefix) {
    for (final line in raw.split(RegExp(r'\r?\n'))) {
      final trimmed = line.trim();
      if (trimmed.startsWith(prefix)) {
        return trimmed.substring(prefix.length).trim();
      }
    }
    return null;
  }

  String _parseSysInfo(String raw) {
    final m =
        RegExp(r'\^SYSINFO:(\d+),(\d+),(\d+),(\d+),(\d+)').firstMatch(raw);
    if (m == null) return 'Неизвестно';
    final sysMode = int.tryParse(m.group(4)!) ?? 0;
    final subMode = RegExp(r'\^SYSINFO:[^\r\n]*,(\d+)\s*$', multiLine: true)
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
    final m = RegExp(r'\^CARDLOCK:\s*(\d+),(\d+),').firstMatch(raw);
    if (m == null) return 'Не определено';
    final state = m.group(1);
    final attempts = m.group(2);
    if (state == '2') return 'Разблокирован (все SIM)';
    if (state == '1') return 'Заблокирован (осталось попыток: $attempts)';
    return 'Код статуса: $state';
  }
}
