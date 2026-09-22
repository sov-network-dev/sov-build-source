// lib/sov_node_sdk/desktop_tray.dart
// ─────────────────────────────────────────────────────────────────────────────
// Desktop close-to-tray (Windows/macOS/Linux). Closing the window HIDES it to the
// system tray instead of quitting — so the bundled full node keeps serving and the
// 21-day operator uptime streak survives an accidental close. The app only really
// exits via the tray "Quit" item (which stops the node first).
// ─────────────────────────────────────────────────────────────────────────────
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'node_controller.dart';

class DesktopTray with WindowListener, TrayListener {
  DesktopTray._();
  static final DesktopTray instance = DesktopTray._();

  static bool get _isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  bool _initialised = false;
  bool _reallyQuitting = false;

  /// Call once from main() after WidgetsFlutterBinding.ensureInitialized().
  Future<void> init() async {
    if (!_isDesktop || _initialised) return;
    _initialised = true;

    await windowManager.ensureInitialized();
    // Intercept the window-close button so we can hide-to-tray instead of quit.
    await windowManager.setPreventClose(true);
    windowManager.addListener(this);

    try {
      await trayManager.setIcon('assets/tray_icon.ico');
      await trayManager.setToolTip('SOV Node');
      await _rebuildMenu();
      trayManager.addListener(this);
    } catch (e) {
      debugPrint('[tray] setup failed (continuing without tray): $e');
    }
  }

  Future<void> _rebuildMenu() async {
    final running = NodeController.instance.isRunning;
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'show', label: 'Open SOV Node'),
      MenuItem.separator(),
      MenuItem(
        key: 'node',
        label: running ? '● Full node: serving' : '○ Full node: off',
        disabled: true,
      ),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: 'Quit (stops your node)'),
    ]));
  }

  Future<void> _showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  /// Stop the node, then truly terminate the process.
  Future<void> _quit() async {
    _reallyQuitting = true;
    try { await NodeController.instance.stop(); } catch (_) {}
    try { await trayManager.destroy(); } catch (_) {}
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  // ── WindowListener ──────────────────────────────────────────────────────────
  @override
  void onWindowClose() async {
    if (_reallyQuitting) return;
    // Hide to tray instead of quitting. The Flutter process (and the node child)
    // keep running in the background.
    await windowManager.hide();
    await _rebuildMenu(); // reflect current node state in the tray tooltip/menu
  }

  // ── TrayListener ────────────────────────────────────────────────────────────
  @override
  void onTrayIconMouseDown() => _showWindow();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        _showWindow();
        break;
      case 'quit':
        _quit();
        break;
    }
  }
}
