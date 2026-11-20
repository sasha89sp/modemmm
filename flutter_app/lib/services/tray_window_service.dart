import 'dart:io';
import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import '../app_version.dart';
import 'app_paths.dart';

/// Управление окном Windows и системным треем:
/// сворачивание в трей при закрытии, восстановление по клику/меню, отслеживание скрытого состояния.
class TrayWindowService with WindowListener, TrayListener {
  final bool Function() shouldMinimizeToTray;
  final void Function(bool hiddenOrMinimized) onWindowVisibilityChanged;
  final Future<void> Function() onExitRequested;

  bool _initialized = false;

  TrayWindowService({
    required this.shouldMinimizeToTray,
    required this.onWindowVisibilityChanged,
    required this.onExitRequested,
  });

  Future<void> init() async {
    if (!Platform.isWindows || _initialized) return;
    _initialized = true;

    await windowManager.ensureInitialized();
    const options = WindowOptions(
      size: Size(1280, 820),
      minimumSize: Size(1024, 680),
      center: true,
      title: '${AppVersion.appName} v${AppVersion.version}',
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });

    await windowManager.setPreventClose(true);
    windowManager.addListener(this);

    try {
      final iconPath = AppPaths.trayIconFile;
      if (File(iconPath).existsSync()) {
        await trayManager.setIcon(iconPath);
      }
      await trayManager.setToolTip(AppVersion.windowTitle);
      await trayManager.setContextMenu(Menu(
        items: [
          MenuItem(key: 'show', label: 'Показать окно'),
          MenuItem.separator(),
          MenuItem(key: 'exit', label: 'Выход'),
        ],
      ));
      trayManager.addListener(this);
    } catch (_) {
      // Если иконка трея недоступна, приложение продолжит работу с обычным окном
    }
  }

  Future<void> showWindow() async {
    if (!Platform.isWindows) return;
    await windowManager.show();
    await windowManager.restore();
    await windowManager.focus();
    onWindowVisibilityChanged(false);
  }

  Future<void> destroyAndExit() async {
    await onExitRequested();
    if (Platform.isWindows) {
      trayManager.removeListener(this);
      windowManager.removeListener(this);
      try {
        await trayManager.destroy();
      } catch (_) {}
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    }
  }

  @override
  void onWindowClose() async {
    if (shouldMinimizeToTray()) {
      await windowManager.hide();
      onWindowVisibilityChanged(true);
    } else {
      await destroyAndExit();
    }
  }

  @override
  void onWindowMinimize() {
    onWindowVisibilityChanged(true);
  }

  @override
  void onWindowRestore() {
    onWindowVisibilityChanged(false);
  }

  @override
  void onWindowFocus() {
    onWindowVisibilityChanged(false);
  }

  @override
  void onTrayIconMouseDown() {
    showWindow();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (menuItem.key == 'show') {
      showWindow();
    } else if (menuItem.key == 'exit') {
      destroyAndExit();
    }
  }
}
