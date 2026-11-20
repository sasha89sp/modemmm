import 'package:flutter/material.dart';
import 'app_version.dart';
import 'services/modem_controller.dart';
import 'services/tray_window_service.dart';
import 'ui/main_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final controller = ModemController();
  final trayService = TrayWindowService(
    shouldMinimizeToTray: () => controller.settings.minimizeToTrayOnClose,
    onWindowVisibilityChanged: controller.setWindowHidden,
    onExitRequested: controller.shutdown,
  );

  await trayService.init();
  await controller.init();

  runApp(HuaweiE173App(controller: controller, trayService: trayService));
}

class HuaweiE173App extends StatelessWidget {
  final ModemController controller;
  final TrayWindowService trayService;

  const HuaweiE173App({
    super.key,
    required this.controller,
    required this.trayService,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppVersion.windowTitle,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1D4ED8),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF8FAFC),
      ),
      home: MainShell(controller: controller, trayService: trayService),
    );
  }
}
