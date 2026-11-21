import 'dart:convert';
import 'dart:io';
import '../services/app_paths.dart';

class ExcelColumnSpec {
  final String key;
  String header;
  bool enabled;

  ExcelColumnSpec({
    required this.key,
    required this.header,
    this.enabled = true,
  });

  ExcelColumnSpec copyWith({String? header, bool? enabled}) => ExcelColumnSpec(
        key: key,
        header: header ?? this.header,
        enabled: enabled ?? this.enabled,
      );

  Map<String, dynamic> toJson() => {
        'key': key,
        'header': header,
        'enabled': enabled,
      };

  factory ExcelColumnSpec.fromJson(Map<String, dynamic> json) =>
      ExcelColumnSpec(
        key: json['key']?.toString() ?? '',
        header: json['header']?.toString() ?? '',
        enabled: json['enabled'] as bool? ?? true,
      );

  static List<ExcelColumnSpec> defaults() => [
        ExcelColumnSpec(key: 'startedAt', header: 'Дата и время'),
        ExcelColumnSpec(key: 'scenarioName', header: 'Сценарий'),
        ExcelColumnSpec(key: 'operatorName', header: 'Оператор'),
        ExcelColumnSpec(key: 'phoneNumber', header: 'Номер SIM'),
        ExcelColumnSpec(key: 'imei', header: 'IMEI'),
        ExcelColumnSpec(key: 'imsi', header: 'IMSI'),
        ExcelColumnSpec(key: 'firstBalance', header: 'Первый баланс'),
        ExcelColumnSpec(key: 'lastBalance', header: 'Последний баланс'),
        ExcelColumnSpec(key: 'balanceDiff', header: 'Разница'),
        ExcelColumnSpec(key: 'balanceMatchStatus', header: 'Сверка баланса'),
        ExcelColumnSpec(key: 'status', header: 'Итог'),
        ExcelColumnSpec(key: 'durationSec', header: 'Длительность (с)'),
        ExcelColumnSpec(key: 'errorText', header: 'Ошибки'),
        ExcelColumnSpec(key: 'stepSummary', header: 'Ответы шагов'),
      ];
}

class ExcelPreset {
  final String name;
  final List<ExcelColumnSpec> columns;

  ExcelPreset({required this.name, required this.columns});

  Map<String, dynamic> toJson() => {
        'name': name,
        'columns': columns.map((c) => c.toJson()).toList(),
      };

  factory ExcelPreset.fromJson(Map<String, dynamic> json) => ExcelPreset(
        name: json['name']?.toString() ?? 'Пресет',
        columns: ((json['columns'] as List<dynamic>?) ?? [])
            .map((e) => ExcelColumnSpec.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class SavedUssdCommand {
  final String id;
  final String label;
  final String code;
  final int dcs; // 15 или 72

  const SavedUssdCommand({
    required this.id,
    required this.label,
    required this.code,
    this.dcs = 15,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'code': code,
        'dcs': dcs,
      };

  factory SavedUssdCommand.fromJson(Map<String, dynamic> json) =>
      SavedUssdCommand(
        id: json['id']?.toString() ??
            DateTime.now().microsecondsSinceEpoch.toString(),
        label: json['label']?.toString() ?? '',
        code: json['code']?.toString() ?? '',
        dcs: (json['dcs'] as num?)?.toInt() ?? 15,
      );
}

class AppSettings {
  String preferredPort;
  int baudRate;
  bool autoConnect;
  String preferredVoicePort;

  // Сеть / RAS
  String apn;
  String dialNumber;
  String rasUsername;
  String rasPassword;

  // SMS и оповещения
  bool autoFetchSms;
  int smsPollIntervalSec;
  bool deleteSmsFromModemAfterSave;
  bool requestSmsDeliveryReport;
  bool smsSoundEnabled;
  double smsSoundVolume; // 0.0 .. 1.0
  bool smsPopupEnabled;

  // Входящие звонки и оповещения
  bool callRingtoneEnabled;
  double callRingtoneVolume; // 0.0 .. 1.0
  bool callPopupEnabled;

  // Отладка и профилировщик производительности (выключена по умолчанию)
  bool debugProfilerEnabled;

  // Оптимизация и трей
  bool minimizeToTrayOnClose;
  int activePollSec;
  int idlePollSec;
  int hiddenPollSec;

  // USSD сохранённые команды
  List<SavedUssdCommand> savedUssd;

  // Excel колонки и пресеты
  List<ExcelColumnSpec> excelColumns;
  List<ExcelPreset> excelPresets;

  AppSettings({
    this.preferredPort = '',
    this.baudRate = 115200,
    this.autoConnect = true,
    this.preferredVoicePort = '',
    this.apn = 'internet',
    this.dialNumber = '*99#',
    this.rasUsername = '',
    this.rasPassword = '',
    this.autoFetchSms = true,
    this.smsPollIntervalSec = 25,
    this.deleteSmsFromModemAfterSave = false,
    this.requestSmsDeliveryReport = false,
    this.smsSoundEnabled = true,
    this.smsSoundVolume = 0.8,
    this.smsPopupEnabled = true,
    this.callRingtoneEnabled = true,
    this.callRingtoneVolume = 0.85,
    this.callPopupEnabled = true,
    this.debugProfilerEnabled = false,
    this.minimizeToTrayOnClose = true,
    this.activePollSec = 6,
    this.idlePollSec = 20,
    this.hiddenPollSec = 45,
    List<SavedUssdCommand>? savedUssd,
    List<ExcelColumnSpec>? excelColumns,
    List<ExcelPreset>? excelPresets,
  })  : savedUssd = savedUssd ?? defaultUssd(),
        excelColumns = excelColumns ?? ExcelColumnSpec.defaults(),
        excelPresets = excelPresets ?? [];

  static List<SavedUssdCommand> defaultUssd() => const [
        SavedUssdCommand(id: 'u1', label: 'Баланс (*100#)', code: '*100#', dcs: 15),
        SavedUssdCommand(id: 'u2', label: 'Баланс Билайн (*102#)', code: '*102#', dcs: 15),
        SavedUssdCommand(id: 'u3', label: 'Остаток трафика (*105#)', code: '*105#', dcs: 15),
        SavedUssdCommand(id: 'u4', label: 'Мой номер МегаФон (*205#)', code: '*205#', dcs: 15),
        SavedUssdCommand(id: 'u5', label: 'Мой номер МТС (*111*0887#)', code: '*111*0887#', dcs: 15),
        SavedUssdCommand(id: 'u6', label: 'Мой номер Tele2 (*201#)', code: '*201#', dcs: 15),
      ];

  static Future<AppSettings> load() async {
    await AppPaths.ensureDirectories();
    final file = File(AppPaths.settingsFile);
    if (!await file.exists()) {
      final def = AppSettings();
      await def.save();
      return def;
    }
    try {
      final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final savedUssdRaw = raw['savedUssd'] as List<dynamic>?;
      final excelColsRaw = raw['excelColumns'] as List<dynamic>?;
      final excelPresetsRaw = raw['excelPresets'] as List<dynamic>?;

      return AppSettings(
        preferredPort: raw['preferredPort']?.toString() ?? '',
        baudRate: (raw['baudRate'] as num?)?.toInt() ?? 115200,
        autoConnect: raw['autoConnect'] as bool? ?? true,
        preferredVoicePort: raw['preferredVoicePort']?.toString() ?? '',
        apn: raw['apn']?.toString() ?? 'internet',
        dialNumber: raw['dialNumber']?.toString() ?? '*99#',
        rasUsername: raw['rasUsername']?.toString() ?? '',
        rasPassword: raw['rasPassword']?.toString() ?? '',
        autoFetchSms: raw['autoFetchSms'] as bool? ?? true,
        smsPollIntervalSec: (raw['smsPollIntervalSec'] as num?)?.toInt() ?? 25,
        deleteSmsFromModemAfterSave:
            raw['deleteSmsFromModemAfterSave'] as bool? ?? false,
        requestSmsDeliveryReport:
            raw['requestSmsDeliveryReport'] as bool? ?? false,
        smsSoundEnabled: raw['smsSoundEnabled'] as bool? ?? true,
        smsSoundVolume:
            ((raw['smsSoundVolume'] as num?)?.toDouble() ?? 0.8)
                .clamp(0.0, 1.0)
                .toDouble(),
        smsPopupEnabled: raw['smsPopupEnabled'] as bool? ?? true,
        callRingtoneEnabled: raw['callRingtoneEnabled'] as bool? ?? true,
        callRingtoneVolume:
            ((raw['callRingtoneVolume'] as num?)?.toDouble() ?? 0.85)
                .clamp(0.0, 1.0)
                .toDouble(),
        callPopupEnabled: raw['callPopupEnabled'] as bool? ?? true,
        debugProfilerEnabled: raw['debugProfilerEnabled'] as bool? ?? false,
        minimizeToTrayOnClose: raw['minimizeToTrayOnClose'] as bool? ?? true,
        activePollSec: (raw['activePollSec'] as num?)?.toInt() ?? 6,
        idlePollSec: (raw['idlePollSec'] as num?)?.toInt() ?? 20,
        hiddenPollSec: (raw['hiddenPollSec'] as num?)?.toInt() ?? 45,
        savedUssd: savedUssdRaw != null
            ? savedUssdRaw
                .map((e) => SavedUssdCommand.fromJson(e as Map<String, dynamic>))
                .toList()
            : defaultUssd(),
        excelColumns: excelColsRaw != null && excelColsRaw.isNotEmpty
            ? excelColsRaw
                .map((e) => ExcelColumnSpec.fromJson(e as Map<String, dynamic>))
                .toList()
            : ExcelColumnSpec.defaults(),
        excelPresets: excelPresetsRaw != null
            ? excelPresetsRaw
                .map((e) => ExcelPreset.fromJson(e as Map<String, dynamic>))
                .toList()
            : [],
      );
    } catch (_) {
      return AppSettings();
    }
  }

  Future<void> save() async {
    await AppPaths.ensureDirectories();
    final file = File(AppPaths.settingsFile);
    final payload = {
      'preferredPort': preferredPort,
      'baudRate': baudRate,
      'autoConnect': autoConnect,
      'preferredVoicePort': preferredVoicePort,
      'apn': apn,
      'dialNumber': dialNumber,
      'rasUsername': rasUsername,
      'rasPassword': rasPassword,
      'autoFetchSms': autoFetchSms,
      'smsPollIntervalSec': smsPollIntervalSec,
      'deleteSmsFromModemAfterSave': deleteSmsFromModemAfterSave,
      'requestSmsDeliveryReport': requestSmsDeliveryReport,
      'smsSoundEnabled': smsSoundEnabled,
      'smsSoundVolume': smsSoundVolume,
      'smsPopupEnabled': smsPopupEnabled,
      'callRingtoneEnabled': callRingtoneEnabled,
      'callRingtoneVolume': callRingtoneVolume,
      'callPopupEnabled': callPopupEnabled,
      'debugProfilerEnabled': debugProfilerEnabled,
      'minimizeToTrayOnClose': minimizeToTrayOnClose,
      'activePollSec': activePollSec,
      'idlePollSec': idlePollSec,
      'hiddenPollSec': hiddenPollSec,
      'savedUssd': savedUssd.map((e) => e.toJson()).toList(),
      'excelColumns': excelColumns.map((e) => e.toJson()).toList(),
      'excelPresets': excelPresets.map((e) => e.toJson()).toList(),
    };
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(payload));
  }
}
