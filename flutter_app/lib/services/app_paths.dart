import 'dart:io';
import 'package:path/path.dart' as p;

/// Централизованное управление портативной структурой UserData рядом с .exe.
class AppPaths {
  static String get exeDir => File(Platform.resolvedExecutable).parent.path;
  static String get userDataDir => p.join(exeDir, 'UserData');
  static String get excelDir => p.join(userDataDir, 'Excel');
  static String get soundsDir => p.join(userDataDir, 'Sounds');
  static String get exportsDir => p.join(userDataDir, 'Exports');

  static String get settingsFile => p.join(userDataDir, 'settings.json');
  static String get databaseFile => p.join(userDataDir, 'modem_data.db');
  static String get excelMainFile => p.join(excelDir, 'scenario_results.xlsx');
  static String get phonebookFile => p.join(userDataDir, 'huawei_e173.pbk');

  static String get trayIconFile {
    final bundled = p.join(exeDir, 'data', 'flutter_assets', 'assets', 'app_icon.ico');
    if (File(bundled).existsSync()) return bundled;
    final local = p.join(exeDir, 'app_icon.ico');
    if (File(local).existsSync()) return local;
    return bundled;
  }

  static Future<void> ensureDirectories() async {
    for (final dir in [userDataDir, excelDir, soundsDir, exportsDir]) {
      final d = Directory(dir);
      if (!await d.exists()) {
        await d.create(recursive: true);
      }
    }
  }
}
