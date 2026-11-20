import 'dart:convert';
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
    this.baudRate = 115200,
    this.autoConnect = true,
    this.apn = 'internet',
    this.dialNumber = '*99#',
    this.rasUsername = '',
    this.rasPassword = '',
    List<UssdShortcut>? ussdShortcuts,
  }) : ussdShortcuts = ussdShortcuts ?? defaultShortcuts;

  static List<UssdShortcut> get defaultShortcuts => const [
        UssdShortcut(label: 'Баланс', code: '*100#'),
        UssdShortcut(label: 'Баланс (Билайн)', code: '*102#'),
        UssdShortcut(label: 'Остаток трафика', code: '*105#'),
        UssdShortcut(label: 'Мой номер', code: '*205#'),
      ];

  static String get baseDirectory =>
      File(Platform.resolvedExecutable).parent.path;

  static File get configFile =>
      File('$baseDirectory${Platform.pathSeparator}config.json');

  static Future<PortableConfig> load() async {
    try {
      final file = configFile;
      if (await file.exists()) {
        final raw =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        final shortcutsRaw = raw['ussdShortcuts'] as List<dynamic>?;
        return PortableConfig(
          lastPort: raw['lastPort']?.toString() ?? '',
          baudRate: (raw['baudRate'] as num?)?.toInt() ?? 115200,
          autoConnect: raw['autoConnect'] as bool? ?? true,
          apn: raw['apn']?.toString() ?? 'internet',
          dialNumber: raw['dialNumber']?.toString() ?? '*99#',
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
