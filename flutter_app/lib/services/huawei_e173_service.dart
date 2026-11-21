import '../models/modem_models.dart';
import 'debug_profiler_service.dart';
import 'pdu_codec.dart';
import 'ucs2_codec.dart';
import 'win32_serial.dart';

/// Полный AT-сервис Huawei E173:
/// статус/SIM/регистрация, PDU SMS + отчёт о доставке + диагностика, USSD DCS 15/72,
/// голосовые вызовы (ATD/ATA/ATH/DTMF/CLCC/DDSETEX), контакты SIM (CPBR/CPBW), SYSCFG/U2DIAG.
class HuaweiE173Service {
  final Win32SerialPort serial;
  final void Function(String direction, String line)? onLog;
  final DebugProfilerService? profiler;

  HuaweiE173Service(this.serial, {this.onLog, this.profiler});

  Future<String> exec(
    String cmd, {
    Duration timeout = const Duration(seconds: 3),
    String? expectToken,
    bool waitForTokenLineEnd = false,
  }) async {
    onLog?.call('TX', cmd);
    final prof = profiler;
    final sw = (prof != null && prof.enabled) ? (Stopwatch()..start()) : null;
    final response = await serial.sendCommand(
      cmd,
      timeout: timeout,
      expectToken: expectToken,
      waitForTokenLineEnd: waitForTokenLineEnd,
    );
    if (sw != null) {
      sw.stop();
      final isErr = response.contains('ERROR') || response.trim().isEmpty;
      prof!.recordDuration(
        'at_command',
        sw.elapsedMicroseconds / 1000.0,
        detail: cmd,
        isError: isErr && !cmd.startsWith('AT^CARDLOCK'),
      );
    }
    for (final line in response.split(RegExp(r'[\r\n]+'))) {
      final clean = line.trim();
      if (clean.isNotEmpty && clean != cmd) {
        onLog?.call('RX', clean);
      }
    }
    return response;
  }

  Future<void> initialize() async {
    var probe = await exec('AT', timeout: const Duration(milliseconds: 1200));
    if (!probe.contains('OK')) {
      probe = await exec('AT', timeout: const Duration(milliseconds: 900));
    }
    if (!probe.contains('OK')) {
      throw StateError(
        'Порт ${serial.portName ?? ''} не отвечает на AT-команды. Выберите порт Huawei PC UI Interface.',
      );
    }
    await exec('ATE0', timeout: const Duration(milliseconds: 1500));
    await exec('AT+CMEE=2', timeout: const Duration(milliseconds: 1500));
    await exec('AT+CLIP=1', timeout: const Duration(milliseconds: 1500));
    await exec('AT+CNMI=2,1,0,1,0', timeout: const Duration(milliseconds: 1500));
    await exec('AT+COPS=3,0', timeout: const Duration(milliseconds: 1500));
  }

  /// Быстрая проверка наличия SIM (используется в режиме «SIM не обнаружена» раз в 60 сек).
  Future<bool> checkSimPresent() async {
    final cpinRaw =
        await exec('AT+CPIN?', timeout: const Duration(milliseconds: 1800));
    final lower = cpinRaw.toLowerCase();
    if (lower.contains('sim not inserted') ||
        lower.contains('sim failure') ||
        lower.contains('+cme error: 10') ||
        lower.contains('+cme error: 13')) {
      return false;
    }
    return cpinRaw.contains('READY') ||
        cpinRaw.contains('SIM PIN') ||
        cpinRaw.contains('SIM PUK');
  }

  Future<ModemSnapshot> pollSnapshot({
    required ModemSnapshot current,
    bool fetchStaticInfo = false,
  }) async {
    var manufacturer = current.manufacturer;
    var model = current.model;
    var revision = current.revision;
    var imei = current.imei;
    var cardLockStatus = current.cardLockStatus;

    if (fetchStaticInfo || imei == '—') {
      final ati = await exec('ATI', timeout: const Duration(milliseconds: 1800));
      manufacturer = _extractLineValue(ati, 'Manufacturer:') ?? manufacturer;
      model = _extractLineValue(ati, 'Model:') ?? model;
      revision = _extractLineValue(ati, 'Revision:') ?? revision;
      imei = _extractLineValue(ati, 'IMEI:') ?? imei;
      final cardlockRaw = await exec(
        'AT^CARDLOCK?',
        timeout: const Duration(milliseconds: 1500),
      );
      cardLockStatus = _parseCardLock(cardlockRaw);
    }

    final cpinRaw =
        await exec('AT+CPIN?', timeout: const Duration(milliseconds: 2200));
    final lowerCpin = cpinRaw.toLowerCase();

    // Если модем временно не успел ответить на AT+CPIN? (например, занят звонком/сетью),
    // НЕ сбрасываем состояние в «SIM не обнаружена», а сохраняем предыдущий снимок.
    if (cpinRaw.trim().isEmpty && current.connected && !current.simMissing) {
      return current.copyWith(
        connected: serial.isOpen,
        port: serial.portName ?? current.port,
        manufacturer: manufacturer,
        model: model,
        revision: revision,
        imei: imei,
        cardLockStatus: cardLockStatus,
      );
    }

    var simStatus = current.simStatus;
    var simMissing = false;
    if (cpinRaw.contains('READY')) {
      simStatus = 'SIM готова';
    } else if (cpinRaw.contains('SIM PIN')) {
      simStatus = 'Требуется PIN';
    } else if (cpinRaw.contains('SIM PUK')) {
      simStatus = 'Требуется PUK';
    } else if (lowerCpin.contains('not inserted') ||
        lowerCpin.contains('sim failure') ||
        lowerCpin.contains('+cme error: 10') ||
        lowerCpin.contains('+cme error: 13') ||
        lowerCpin.contains('+cme error: 15')) {
      simStatus = 'SIM не обнаружена';
      simMissing = true;
    } else if (cpinRaw.trim().isEmpty) {
      simStatus = 'Нет ответа от SIM';
      simMissing = true;
    }

    // При отсутствии SIM отключаем запросы к SIM/сети
    if (simMissing) {
      return ModemSnapshot(
        connected: serial.isOpen,
        port: serial.portName ?? '',
        manufacturer: manufacturer,
        model: model,
        revision: revision,
        imei: imei,
        imsi: '—',
        simStatus: simStatus,
        simMissing: true,
        operatorName: 'Нет SIM',
        regStatus: 'SIM не обнаружена',
        isRegistered: false,
        rssi: 99,
        dbm: null,
        signalPercent: 0,
        networkType: 'Нет сети',
        cardLockStatus: cardLockStatus,
      );
    }

    final imsiRaw = (fetchStaticInfo || current.imsi == '—')
        ? await exec('AT+CIMI', timeout: const Duration(milliseconds: 1800))
        : '';
    final imsi = imsiRaw.isNotEmpty
        ? (RegExp(r'\d{14,16}').firstMatch(imsiRaw)?.group(0) ?? current.imsi)
        : current.imsi;

    final csqRaw =
        await exec('AT+CSQ', timeout: const Duration(milliseconds: 1500));
    final cregRaw =
        await exec('AT+CREG?', timeout: const Duration(milliseconds: 1500));
    final copsRaw =
        await exec('AT+COPS?', timeout: const Duration(milliseconds: 1800));
    final sysinfoRaw =
        await exec('AT^SYSINFO', timeout: const Duration(milliseconds: 1500));

    int rssi = current.rssi;
    final csqMatch = RegExp(r'\+CSQ:\s*(\d+),').firstMatch(csqRaw);
    if (csqMatch != null) {
      rssi = int.tryParse(csqMatch.group(1)!) ?? 99;
    }
    final dbm = (rssi >= 0 && rssi <= 31) ? (-113 + rssi * 2) : null;
    final signalPercent = (rssi >= 0 && rssi <= 31)
        ? ((rssi / 31.0) * 100).round().clamp(0, 100).toInt()
        : 0;

    final regParsed = _parseCreg(cregRaw);
    var operatorName = current.operatorName;
    final copsMatch =
        RegExp(r'\+COPS:\s*\d+,\d+,"([^"]+)"').firstMatch(copsRaw);
    if (copsMatch != null) {
      operatorName = _resolveOperatorName(Ucs2Codec.decodeSmart(copsMatch.group(1)!));
    } else if (!regParsed.$2) {
      operatorName = 'Нет регистрации';
    }

    final networkType = _parseSysInfo(sysinfoRaw);

    return ModemSnapshot(
      connected: serial.isOpen,
      port: serial.portName ?? '',
      manufacturer: manufacturer,
      model: model,
      revision: revision,
      imei: imei,
      imsi: imsi,
      simStatus: simStatus,
      simMissing: false,
      operatorName: operatorName,
      regStatus: regParsed.$1,
      isRegistered: regParsed.$2,
      rssi: rssi,
      dbm: dbm,
      signalPercent: signalPercent,
      networkType: networkType,
      cardLockStatus: cardLockStatus,
    );
  }

  // ---------------- SMS (PDU + Multipart + Diagnostics) ----------------

  Future<List<AssembledSms>> readAllSmsPdu() async {
    await exec('AT+CMGF=0');
    final raw = await exec('AT+CMGL=4', timeout: const Duration(seconds: 8));
    final lines = raw.split(RegExp(r'\r?\n'));
    final parts = <DecodedPduSms>[];

    final headerRe = RegExp(r'^\+CMGL:\s*(\d+),(\d+),');
    for (var i = 0; i < lines.length; i++) {
      final m = headerRe.firstMatch(lines[i].trim());
      if (m != null && i + 1 < lines.length) {
        final idx = int.tryParse(m.group(1)!) ?? 0;
        final stat = int.tryParse(m.group(2)!) ?? 0;
        final pduLine = lines[i + 1].trim();
        final decoded = PduCodec.decodePdu(
          modemIndex: idx,
          stat: stat,
          pduHex: pduLine,
        );
        if (decoded != null) {
          parts.add(decoded);
        }
      }
    }
    return PduCodec.assembleParts(parts);
  }

  Future<bool> sendSms({
    required String phone,
    required String message,
    bool requestDeliveryReport = false,
  }) async {
    await exec('AT+CMGF=1');
    await exec('AT+CSCS="UCS2"');
    // FO=49 включает Status Report Request (SRR), FO=17 — без отчёта о доставке
    final fo = requestDeliveryReport ? 49 : 17;
    await exec('AT+CSMP=$fo,167,0,8');

    final hexPhone = Ucs2Codec.encodeHex(phone.trim());
    final hexBody = Ucs2Codec.encodeHex(message);

    final prompt = await exec(
      'AT+CMGS="$hexPhone"',
      timeout: const Duration(seconds: 4),
      expectToken: '>',
    );
    if (!prompt.contains('>')) return false;

    onLog?.call('TX', '<UCS2 SMS Payload + Ctrl+Z>');
    final result = await serial.sendRawWithCtrlZ(hexBody);
    onLog?.call('RX', result.trim());
    return result.contains('OK') || result.contains('+CMGS:');
  }

  Future<bool> deleteSmsFromModem(int index) async {
    final res = await exec('AT+CMGD=$index');
    return res.contains('OK');
  }

  Future<(String cnmi, String cpms)> querySmsDiagnostics() async {
    final cnmi = await exec('AT+CNMI?');
    final cpms = await exec('AT+CPMS?');
    final cnmiLine = RegExp(r'\+CNMI:[^\r\n]+').firstMatch(cnmi)?.group(0) ??
        cnmi.trim();
    final cpmsLine = RegExp(r'\+CPMS:[^\r\n]+').firstMatch(cpms)?.group(0) ??
        cpms.trim();
    return (cnmiLine, cpmsLine);
  }

  // ---------------- USSD (DCS 15 / 72 + Session Management) ----------------

  Future<void> cancelUssdSession() async {
    await exec('AT+CUSD=2', timeout: const Duration(seconds: 2));
  }

  /// Отправка USSD с выбором DCS (15 = GSM 7-bit PDU / текст, 72 = UCS2).
  Future<String> sendUssd(
    String code, {
    int dcs = 15,
    bool autoFallback = true,
  }) async {
    final cleanCode = code.trim();
    if (cleanCode.isEmpty) return 'Введите USSD-команду.';

    if (cleanCode.startsWith('*') || cleanCode.startsWith('#')) {
      await exec('AT+CUSD=2', timeout: const Duration(seconds: 1));
    }

    String raw = '';
    if (dcs == 72) {
      await exec('AT+CSCS="UCS2"', timeout: const Duration(seconds: 1));
      final encoded = Ucs2Codec.encodeHex(cleanCode);
      raw = await exec(
        'AT+CUSD=1,"$encoded",72',
        timeout: const Duration(seconds: 15),
        expectToken: '+CUSD:',
        waitForTokenLineEnd: true,
      );
    } else {
      await exec('AT+CSCS="GSM"', timeout: const Duration(seconds: 1));
      final pdu = Ucs2Codec.encodeGsm7PackedHex(cleanCode);
      raw = await exec(
        'AT+CUSD=1,"$pdu",15',
        timeout: const Duration(seconds: 15),
        expectToken: '+CUSD:',
        waitForTokenLineEnd: true,
      );

      if (autoFallback &&
          !raw.contains('+CUSD:') &&
          !raw.toLowerCase().contains('no network service') &&
          (raw.contains('ERROR') || raw.trim().isEmpty)) {
        raw = await exec(
          'AT+CUSD=1,"$cleanCode",15',
          timeout: const Duration(seconds: 15),
          expectToken: '+CUSD:',
          waitForTokenLineEnd: true,
        );
      }
    }

    final cusdMatch =
        RegExp(r'\+CUSD:\s*(\d+),"([^"]*)"(?:,\s*(\d+))?', dotAll: true)
            .firstMatch(raw);
    if (cusdMatch != null) {
      final status = cusdMatch.group(1) ?? '0';
      final payload = cusdMatch.group(2) ?? '';
      final respDcs = int.tryParse(cusdMatch.group(3) ?? '');
      final decoded = Ucs2Codec.decodeUssdPayload(payload, respDcs);
      if (status == '1') {
        return '$decoded\n\n[Сессия открыта — можно отправить пункт меню или закрыть AT+CUSD=2]';
      }
      return decoded.isNotEmpty
          ? decoded
          : 'Пустой ответ от оператора (+CUSD: $status).';
    }

    if (raw.toLowerCase().contains('no network service') ||
        raw.contains('+CME ERROR: 30')) {
      final creg = await exec('AT+CREG?');
      final sys = await exec('AT^SYSINFO');
      final csq = await exec('AT+CSQ');
      return '+CME ERROR: no network service (нет регистрации в голосовой сети CS).\n'
          'Переключите модем в 2G GSM или Авто 2G/3G (CS+PS).\n'
          'Диагностика: ${creg.trim()} | ${csq.trim()} | ${sys.trim()}';
    }

    return raw.trim().isEmpty
        ? 'Таймаут ожидания +CUSD (15 сек).'
        : raw.trim();
  }

  Future<void> enableNetworkForUssd({bool only2g = false}) async {
    await exec('AT+CFUN=1');
    if (only2g) {
      await exec('AT^SYSCFG=13,1,3FFFFFFF,1,2');
    } else {
      await exec('AT^SYSCFG=2,0,3FFFFFFF,1,2');
    }
    await exec('AT+COPS=0', timeout: const Duration(seconds: 6));
  }

  // ---------------- Voice Calls & DTMF ----------------

  /// Проверяет поддержку голоса в прошивке Huawei E173 (AT^CVOICE?).
  /// ^CVOICE:0,8000,16,20 -> голос включён; ^CVOICE:1 или ERROR -> голос отключён.
  Future<(bool enabled, String raw)> queryVoiceCapability() async {
    final res =
        await exec('AT^CVOICE?', timeout: const Duration(milliseconds: 2000));
    final clean = res
        .split(RegExp(r'[\r\n]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty && e != 'OK')
        .join(' ');
    if (res.contains('^CVOICE:0') || res.contains('^CVOICE: 0')) {
      return (true, clean.isEmpty ? '^CVOICE:0 (Голос включён)' : clean);
    }
    return (
      false,
      clean.isEmpty ? 'Нет ответа на AT^CVOICE?' : clean,
    );
  }

  /// Попытка включить голос в прошивке Huawei E173 (AT^CVOICE=0).
  Future<(bool ok, String raw)> enableVoiceCapability() async {
    final res =
        await exec('AT^CVOICE=0', timeout: const Duration(milliseconds: 2000));
    return (res.contains('OK'), res.trim());
  }

  Future<(bool ok, String detail)> dialVoiceDetailed(String number) async {
    final clean = number.trim();
    if (clean.isEmpty) return (false, 'Пустой номер');
    final res = await exec('ATD$clean;', timeout: const Duration(seconds: 6));
    final upper = res.toUpperCase();
    if (upper.contains('NO CARRIER')) {
      return (false, 'NO CARRIER (линия недоступна или нет регистрации CS)');
    }
    if (upper.contains('BUSY')) {
      return (false, 'BUSY (абонент занят)');
    }
    if (upper.contains('NO DIALTONE') || upper.contains('NO ANSWER')) {
      return (false, res.trim());
    }
    if (upper.contains('ERROR')) {
      return (false, res.trim());
    }
    if (res.contains('OK') || res.contains('^ORIG:')) {
      await exec('AT^DDSETEX=2', timeout: const Duration(milliseconds: 1500));
      return (true, 'OK');
    }
    return (false, res.trim().isEmpty ? 'Таймаут ответа на ATD' : res.trim());
  }

  Future<bool> dialVoice(String number) async {
    final (ok, _) = await dialVoiceDetailed(number);
    return ok;
  }

  Future<bool> answerCall() async {
    final res = await exec('ATA', timeout: const Duration(seconds: 4));
    await exec('AT^DDSETEX=2', timeout: const Duration(milliseconds: 1500));
    return res.contains('OK');
  }

  Future<bool> hangupCall() async {
    final res = await exec('AT+CHUP', timeout: const Duration(seconds: 3));
    if (!res.contains('OK')) {
      final res2 = await exec('ATH', timeout: const Duration(seconds: 3));
      return res2.contains('OK');
    }
    return true;
  }

  Future<bool> enableHuaweiVoiceChannel() async {
    final res =
        await exec('AT^DDSETEX=2', timeout: const Duration(milliseconds: 1800));
    return res.contains('OK');
  }

  Future<bool> sendDtmf(String digits) async {
    final clean = digits.replaceAll(RegExp(r'[^0-9A-Da-d\*#]'), '');
    if (clean.isEmpty) return false;
    for (var i = 0; i < clean.length; i++) {
      final ch = clean[i];
      await exec('AT+VTS="$ch"');
      await Future.delayed(const Duration(milliseconds: 220));
    }
    return true;
  }

  Future<List<ActiveCallInfo>> listActiveCalls() async {
    final raw = await exec('AT+CLCC');
    final list = <ActiveCallInfo>[];
    final re = RegExp(r'\+CLCC:\s*(\d+),(\d+),(\d+),\d+,\d+,"([^"]*)"');
    for (final m in re.allMatches(raw)) {
      list.add(ActiveCallInfo(
        id: int.tryParse(m.group(1)!) ?? 1,
        dir: int.tryParse(m.group(2)!) ?? 0,
        state: int.tryParse(m.group(3)!) ?? 0,
        number: m.group(4) ?? '',
      ));
    }
    return list;
  }

  // ---------------- SIM Contacts (CPBR / CPBW) ----------------

  Future<List<SimContact>> readSimContacts() async {
    await exec('AT+CPBS="SM"');
    await exec('AT+CSCS="UCS2"');
    final raw = await exec('AT+CPBR=1,250', timeout: const Duration(seconds: 8));
    final contacts = <SimContact>[];
    final re = RegExp(r'\+CPBR:\s*(\d+),"([^"]*)",\d+,"([^"]*)"');
    for (final m in re.allMatches(raw)) {
      final idx = int.tryParse(m.group(1)!) ?? 0;
      final phone = Ucs2Codec.decodeSmart(m.group(2) ?? '');
      final name = Ucs2Codec.decodeSmart(m.group(3) ?? '');
      contacts.add(SimContact(index: idx, name: name, phone: phone));
    }
    return contacts;
  }

  Future<bool> writeSimContact({
    int? index,
    required String phone,
    required String name,
  }) async {
    await exec('AT+CPBS="SM"');
    await exec('AT+CSCS="UCS2"');
    final numType = phone.trim().startsWith('+') ? 145 : 129;
    final hexName = Ucs2Codec.encodeHex(name.trim());
    final idxPart = index != null ? '$index' : '';
    final res =
        await exec('AT+CPBW=$idxPart,"${phone.trim()}",$numType,"$hexName"');
    return res.contains('OK');
  }

  Future<bool> deleteSimContact(int index) async {
    await exec('AT+CPBS="SM"');
    final res = await exec('AT+CPBW=$index');
    return res.contains('OK');
  }

  // ---------------- Modes & Admin ----------------

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

  // ---------------- Helpers ----------------

  String? _extractLineValue(String raw, String prefix) {
    for (final line in raw.split(RegExp(r'\r?\n'))) {
      final trimmed = line.trim();
      if (trimmed.startsWith(prefix)) {
        return trimmed.substring(prefix.length).trim();
      }
    }
    return null;
  }

  (String, bool) _parseCreg(String raw) {
    final m = RegExp(r'\+CREG:\s*\d+,(\d+)').firstMatch(raw);
    if (m == null) return ('Неизвестно', false);
    final stat = int.tryParse(m.group(1)!) ?? 0;
    switch (stat) {
      case 1:
        return ('Зарегистрирован (домашняя сеть)', true);
      case 5:
        return ('Зарегистрирован (роуминг)', true);
      case 2:
        return ('Поиск сети...', false);
      case 3:
        return ('Регистрация отклонена', false);
      case 0:
      default:
        return ('Нет регистрации', false);
    }
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

  String _resolveOperatorName(String raw) {
    final clean = raw.trim();
    const mccMnc = {
      '25001': 'МТС (25001)',
      '25002': 'МегаФон (25002)',
      '25011': 'Yota (25011)',
      '25020': 'T2 / Tele2 (25020)',
      '25099': 'Билайн (25099)',
      '25062': 'Тинькофф Мобайл (25062)',
      '25039': 'Ростелеком (25039)',
    };
    return mccMnc[clean] ?? clean;
  }

  String _parseCardLock(String raw) {
    final m = RegExp(r'\^CARDLOCK:\s*(\d+),(\d+),').firstMatch(raw);
    if (m == null) return 'Не определено';
    final state = m.group(1);
    final attempts = m.group(2);
    if (state == '2') return 'Разблокирован (все SIM)';
    if (state == '1') return 'Заблокирован (попыток: $attempts)';
    return 'Статус $state';
  }
}
