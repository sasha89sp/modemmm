import 'dart:ffi';
import 'dart:io';
import 'dart:ui';
import 'package:ffi/ffi.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import '../app_version.dart';
import 'app_paths.dart';

final class _Win32Rect extends Struct {
  @Int32()
  external int left;
  @Int32()
  external int top;
  @Int32()
  external int right;
  @Int32()
  external int bottom;
}

typedef _SystemParametersInfoWNative = Int32 Function(
  Uint32 uiAction,
  Uint32 uiParam,
  Pointer<Void> pvParam,
  Uint32 fWinIni,
);
typedef _SystemParametersInfoWDart = int Function(
  int uiAction,
  int uiParam,
  Pointer<Void> pvParam,
  int fWinIni,
);

/// Управление окном Windows, системным треем и всплывающим мини-окном поверх всех окон
/// для входящих SMS и звонков (даже когда главное окно свёрнуто в трей).
class TrayWindowService with WindowListener, TrayListener {
  static const int _spiGetWorkArea = 0x0030;
  static const Size _defaultMainSize = Size(1280, 820);
  static const Size _defaultMinSize = Size(1024, 680);

  final bool Function() shouldMinimizeToTray;
  final void Function(bool hiddenOrMinimized) onWindowVisibilityChanged;
  final Future<void> Function() onExitRequested;
  void Function(bool miniPopupMode)? onMiniPopupModeChanged;

  bool _windowInitialized = false;
  bool _trayInitialized = false;
  bool _miniPopupMode = false;
  bool _tempAlwaysOnTopForMain = false;
  Rect? _savedMainBounds;

  bool get isMiniPopupMode => _miniPopupMode;

  TrayWindowService({
    required this.shouldMinimizeToTray,
    required this.onWindowVisibilityChanged,
    required this.onExitRequested,
    this.onMiniPopupModeChanged,
  });

  Future<void> initWindow() async {
    if (!Platform.isWindows || _windowInitialized) return;
    _windowInitialized = true;

    try {
      await windowManager.ensureInitialized();
      final options = WindowOptions(
        size: _defaultMainSize,
        minimumSize: _defaultMinSize,
        center: true,
        title: AppVersion.windowTitle,
      );
      await windowManager.waitUntilReadyToShow(options, () async {
        await windowManager.show();
        await windowManager.focus();
      });

      await windowManager.setPreventClose(true);
      windowManager.addListener(this);
    } catch (_) {
      // Продолжаем работу даже при ошибке плагина окна
    }
  }

  Future<void> initTray() async {
    if (!Platform.isWindows || _trayInitialized) return;
    _trayInitialized = true;

    try {
      final iconPath = AppPaths.trayIconFile;
      if (File(iconPath).existsSync()) {
        await trayManager.setIcon(iconPath);
      } else {
        await trayManager.setIcon('assets/app_icon.ico');
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

  /// Показывает уведомление поверх всех окон Windows:
  /// - если главное окно скрыто в трее или свёрнуто — трансформирует окно в компактное
  ///   всплывающее окно в правом нижнем углу поверх всех программ (`alwaysOnTop`);
  /// - если главное окно уже открыто — временно выводит его поверх всех окон,
  ///   чтобы встроенная всплывающая карточка была гарантированно видна поверх браузера и др.
  Future<void> presentNotificationPopup({required bool isCall}) async {
    if (!Platform.isWindows) return;
    try {
      final visible = await windowManager.isVisible();
      final minimized = await windowManager.isMinimized();

      if (!visible || minimized || _miniPopupMode) {
        if (!_miniPopupMode) {
          if (visible && !minimized) {
            _savedMainBounds = await windowManager.getBounds();
          }
          _miniPopupMode = true;
          onMiniPopupModeChanged?.call(true);
        }

        final popupW = 430.0;
        final popupH = isCall ? 235.0 : 215.0;
        final workArea = _getLogicalWorkArea();
        final maxLeft =
            workArea.right - popupW > 16.0 ? workArea.right - popupW : 16.0;
        final maxTop =
            workArea.bottom - popupH > 16.0 ? workArea.bottom - popupH : 16.0;
        final left = (workArea.right - popupW - 18).clamp(16.0, maxLeft).toDouble();
        final top = (workArea.bottom - popupH - 18).clamp(16.0, maxTop).toDouble();

        if (minimized) {
          await windowManager.restore();
        }
        await windowManager.setMinimumSize(const Size(360, 170));
        await windowManager.setSkipTaskbar(true);
        await windowManager.setAlwaysOnTop(true);
        await windowManager.setBounds(Rect.fromLTWH(left, top, popupW, popupH));
        await windowManager.show();
      } else {
        // Главное окно уже на экране, но может быть перекрыто другими окнами Windows
        _tempAlwaysOnTopForMain = true;
        await windowManager.setAlwaysOnTop(true);
        await windowManager.show();
      }
    } catch (_) {
      // Безопасное продолжение работы при ошибке window_manager
    }
  }

  /// Закрывает режим всплывающего окна поверх всех окон.
  /// Если [restoreFullWindow] == true — разворачивает полное окно программы.
  /// Если [restoreFullWindow] == false и окно было открыто только как мини-попап — снова прячет в трей.
  Future<void> dismissNotificationPopup({bool restoreFullWindow = false}) async {
    if (!Platform.isWindows) return;
    try {
      if (_miniPopupMode) {
        _miniPopupMode = false;
        onMiniPopupModeChanged?.call(false);

        await windowManager.setAlwaysOnTop(false);
        await windowManager.setSkipTaskbar(false);
        await windowManager.setMinimumSize(_defaultMinSize);

        final targetBounds = _savedMainBounds;
        if (restoreFullWindow) {
          if (targetBounds != null &&
              targetBounds.width >= _defaultMinSize.width &&
              targetBounds.height >= _defaultMinSize.height) {
            await windowManager.setBounds(targetBounds);
          } else {
            await windowManager.setSize(_defaultMainSize);
            await windowManager.center();
          }
          await windowManager.show();
          await windowManager.focus();
          onWindowVisibilityChanged(false);
        } else {
          await windowManager.hide();
          if (targetBounds != null &&
              targetBounds.width >= _defaultMinSize.width &&
              targetBounds.height >= _defaultMinSize.height) {
            await windowManager.setBounds(targetBounds);
          } else {
            await windowManager.setSize(_defaultMainSize);
          }
          onWindowVisibilityChanged(true);
        }
      } else if (_tempAlwaysOnTopForMain) {
        _tempAlwaysOnTopForMain = false;
        await windowManager.setAlwaysOnTop(false);
        if (restoreFullWindow) {
          await windowManager.focus();
        }
      }
    } catch (_) {}
  }

  Rect _getLogicalWorkArea() {
    double dpr = 1.0;
    try {
      final views = PlatformDispatcher.instance.views;
      if (views.isNotEmpty && views.first.devicePixelRatio > 0) {
        dpr = views.first.devicePixelRatio;
      }
    } catch (_) {}

    if (Platform.isWindows) {
      final rectPtr = calloc<_Win32Rect>();
      try {
        final user32 = DynamicLibrary.open('user32.dll');
        final spi = user32.lookupFunction<_SystemParametersInfoWNative,
            _SystemParametersInfoWDart>('SystemParametersInfoW');
        final ok = spi(_spiGetWorkArea, 0, rectPtr.cast<Void>(), 0);
        if (ok != 0) {
          return Rect.fromLTRB(
            rectPtr.ref.left / dpr,
            rectPtr.ref.top / dpr,
            rectPtr.ref.right / dpr,
            rectPtr.ref.bottom / dpr,
          );
        }
      } catch (_) {
      } finally {
        calloc.free(rectPtr);
      }
    }
    return const Rect.fromLTWH(0, 0, 1366, 728);
  }

  Future<void> showWindow() async {
    if (!Platform.isWindows) return;
    if (_miniPopupMode) {
      await dismissNotificationPopup(restoreFullWindow: true);
      return;
    }
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
    if (_miniPopupMode) {
      await dismissNotificationPopup(restoreFullWindow: false);
      return;
    }
    if (shouldMinimizeToTray()) {
      try {
        _savedMainBounds = await windowManager.getBounds();
      } catch (_) {}
      await windowManager.hide();
      onWindowVisibilityChanged(true);
    } else {
      await destroyAndExit();
    }
  }

  @override
  void onWindowMinimize() {
    if (!_miniPopupMode) {
      onWindowVisibilityChanged(true);
    }
  }

  @override
  void onWindowRestore() {
    if (!_miniPopupMode) {
      onWindowVisibilityChanged(false);
    }
  }

  @override
  void onWindowFocus() {
    if (!_miniPopupMode) {
      onWindowVisibilityChanged(false);
    }
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
