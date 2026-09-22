// lib/main.dart
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io' show Platform, exit, stdout, stderr, ServerSocket, InternetAddress;
import 'package:app_links/app_links.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'screens/splash_screen.dart';
import 'screens/recovery_screen.dart';
import 'screens/main_shell.dart';
import 'screens/send_sov_screen.dart';
import 'screens/sov_login_confirm_screen.dart';
import 'sov_node_sdk/relay_connector.dart';
import 'sov_node_sdk/desktop_tray.dart';
import 'sov_node_sdk/sov_voice_service.dart';
import 'sov_node_sdk/palm_image_engine.dart';
import 'sov_node_sdk/sov_notification_service.dart';
import 'sov_node_sdk/message_key_manager.dart';
import 'widgets/pin_lock_overlay.dart';
import 'widgets/palm_avatar.dart';
import 'sov_cli/cli_runner.dart';

// ─────────────────────────────────────────────────────────────────────────────
// main() reads prefs BEFORE runApp so startLocked is determined synchronously.
// This means _locked is correct on the very first build() call — no async race,
// no flash of home screen before the overlay appears.
//
// CLI MODE: when the first argument is --cli, skip runApp entirely and run the
// headless command-line interface. The same identity, keys, and local database
// are used — no separate import needed.
// ─────────────────────────────────────────────────────────────────────────────
// CLI commands that do no socket I/O (history/contacts/msg --list) finish so
// fast that Dart's graceful `exit()` blocks joining a still-spinning native
// plugin thread (SharedPreferences / sqflite_ffi) and the process never dies.
// Flush output, then force-terminate via the Win32 ExitProcess primitive, which
// skips the CRT atexit/thread-join that hangs. Falls back to exit() elsewhere.
// TerminateProcess(GetCurrentProcess(), code) — the most forceful Win32 exit:
// no CRT atexit, no DLL_PROCESS_DETACH, no thread joins. Guarantees the process
// dies even if a plugin native thread is still spinning.
typedef _TerminateProcessC =
    ffi.Int32 Function(ffi.IntPtr hProcess, ffi.Uint32 uExitCode);
typedef _TerminateProcessDart = int Function(int hProcess, int uExitCode);

Future<void> _cliHardExit(int code) async {
  // Output is already written by print(); flush is best-effort and must not
  // block the terminate, so bound it with a short timeout.
  try { await stdout.flush().timeout(const Duration(milliseconds: 300)); } catch (_) {}
  try { await stderr.flush().timeout(const Duration(milliseconds: 300)); } catch (_) {}
  if (Platform.isWindows) {
    try {
      final k = ffi.DynamicLibrary.open('kernel32.dll');
      final terminate = k
          .lookupFunction<_TerminateProcessC, _TerminateProcessDart>('TerminateProcess');
      terminate(-1, code); // -1 == GetCurrentProcess() pseudo-handle; no return
    } catch (_) {/* fall through to dart exit */}
  }
  exit(code);
}

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // ── CLI mode ───────────────────────────────────────────────────────────────
  // Detected when SovNode.exe is launched with --cli as the first argument.
  // All commands share the wallet already imported via the GUI.
  if (args.isNotEmpty && args[0] == '--cli') {
    // SQLite FFI is needed for contacts/messages DB (same as desktop GUI path)
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // Prime the dart:io I/O event handler. Observed: WebSocket commands exit
    // cleanly while no-socket commands (history/contacts/msg --list) hang on
    // shutdown — initialising the socket subsystem once makes every command
    // exitable. Bind+close a throwaway loopback ServerSocket to force it up.
    try {
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      await s.close();
    } catch (_) {}
    final exitCode = await SovCLI.run(args.sublist(1));
    await _cliHardExit(exitCode);
  }

  // Desktop (Windows/macOS/Linux): the SAME app, restore-only (no palm
  // enrollment), so the mobile-only initializers below are skipped and the
  // sqflite desktop FFI factory is installed. The phone path is unchanged.
  final isDesktop = !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);
  if (isDesktop) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // Close-to-tray: closing the window hides it instead of quitting, so the
    // bundled full node keeps serving in the background (protects the operator
    // uptime streak). Real exit is via the tray "Quit" item.
    await DesktopTray.instance.init();
  }

  if (!isDesktop) {
    // Load YOLOv8 TFLite palm model (mobile only — desktop never enrolls a palm)
    await PalmImageEngine.loadModel();
    // Initialise local notification plugin (Android 13+ permission)
    await SovNotificationService.init();
    // Lock to portrait (mobile only)
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  }

  // S2: Generate X25519 messaging keypair on first run (idempotent; all platforms)
  await MessageKeyManager.initialise();

  // Load the opt-in voice-notification preference (off by default).
  await SovVoiceService.init();

  // Read prefs before runApp so cold-start lock state is synchronous
  final prefs   = await SharedPreferences.getInstance();
  final pinHash = prefs.getString('pin_hash')           ?? '';
  final enrolled = prefs.getBool('enrollment_complete') ?? false;
  final sovId   = prefs.getString('sovereign_id')       ?? '';
  // PIN-disable toggle (king 2026-06-04): when off, never show the PIN lock.
  final pinEnabled = prefs.getBool('pin_enabled')       ?? true;

  // If the process was killed while a file picker / external activity was open,
  // Android recreates us with a fresh cold start.  Without this check we would
  // wrongly show the PIN prompt immediately.  We stored the picker-open
  // timestamp in SharedPreferences and clear it when the picker returns — so
  // if it is set and less than 30 seconds old we know we died in a picker.
  final extActivityTs = prefs.getInt('_ext_activity_ts') ?? 0;
  final nowMs         = DateTime.now().millisecondsSinceEpoch;
  final inPickerWindow = extActivityTs > 0 && (nowMs - extActivityTs) < 30000;
  if (inPickerWindow) {
    // Clear the stale timestamp — the picker is gone, process was killed
    prefs.remove('_ext_activity_ts');
  }

  final startLocked = enrolled && pinHash.isNotEmpty && sovId.isNotEmpty
      && !inPickerWindow && pinEnabled;

  // Connect to relay node at startup (non-fatal if offline)
  RelayConnector.connect().catchError((_) => false);

  runApp(SovereignApp(startLocked: startLocked, initialPinHash: pinHash));
}

// ─────────────────────────────────────────────────────────────────────────────
// ROOT APP — wraps MaterialApp with PIN session lock.
//
// Lock strategy:
//   • Cold start  — locked synchronously via startLocked before first frame
//   • Runtime     — locked on paused/hidden if citizen was away > 2 seconds
//
// The 2-second window compensates for Itel S23 (and similar budget Android
// phones with custom skins) that fire AppLifecycleState.paused when the
// notification shade is pulled down, instead of just inactive.
// Stock Android fires inactive for shade; paused means genuinely backgrounded.
// By checking elapsed time we handle both correctly on all devices.
// ─────────────────────────────────────────────────────────────────────────────
class SovereignApp extends StatefulWidget {
  const SovereignApp({
    super.key,
    required this.startLocked,
    required this.initialPinHash,
  });

  final bool   startLocked;
  final String initialPinHash;

  static _SovereignAppState? _instance;

  /// Update the in-memory PIN hash cache after PIN setup or change.
  /// Called by PinSetupScreen immediately after writing pin_hash to prefs.
  static void updatePinCache(String hash) {
    _instance?._cachedPinHash = hash;
  }

  @override
  State<SovereignApp> createState() => _SovereignAppState();
}

class _SovereignAppState extends State<SovereignApp>
    with WidgetsBindingObserver {

  final _navigatorKey = GlobalKey<NavigatorState>();

  // Set synchronously from widget params in initState — no async race.
  bool    _locked = false;
  String? _cachedPinHash;

  // Timestamp recorded when app first loses focus.
  // Used to distinguish genuine backgrounding (> 2s) from notification
  // shade pull-down (< 2s).
  DateTime? _pausedAt;

  // Latch: true once we've recorded _pausedAt this background cycle.
  // Prevents resetting the timestamp on the secondary inactive event
  // some devices fire on the return trip to foreground.
  bool _backgroundTimestampSet = false;

  @override
  void initState() {
    super.initState();
    _locked        = widget.startLocked;
    _cachedPinHash = widget.initialPinHash;
    SovereignApp._instance = this;
    WidgetsBinding.instance.addObserver(this);
    _initDeepLinks();
  }

  // ── Deep link handler (sovreq:// payment requests) ────────────────────────

  final AppLinks _appLinks = AppLinks();

  void _initDeepLinks() {
    // app_links has no platform implementation under `flutter test`, where
    // activating the event stream throws an (async, uncatchable-here)
    // MissingPluginException that fails widget tests. The Flutter test runner
    // sets FLUTTER_TEST=true — skip deep-link wiring there. Real runs proceed.
    if (!kIsWeb && Platform.environment.containsKey('FLUTTER_TEST')) return;

    // App was launched from a cold start via a deep link
    _appLinks.getInitialLink().then((uri) {
      if (uri != null) _handleDeepLink(uri);
    }).catchError((_) {});

    // App was in background / foreground and received a deep link
    try {
      _appLinks.uriLinkStream.listen((uri) {
        _handleDeepLink(uri);
      }, onError: (_) {}, cancelOnError: false);
    } catch (_) {/* plugin unavailable — ignore */}
  }

  // Show a Sovereign ID card bottom sheet — identicon + ID only.
  // No relay fetch, no profile data. Network identity = Sovereign ID.
  void _showSovIdCard(BuildContext ctx, String targetId) {
    showModalBottomSheet<void>(
      context: ctx,
      backgroundColor: const Color(0xFF0D1F3A),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _SovIdCardSheet(sovereignId: targetId),
    );
  }

  Future<void> _handleDeepLink(Uri uri) async {
    // ── sovid:// — view Sovereign ID card ────────────────────────────────
    if (uri.scheme == 'sovid') {
      final targetId = uri.host.toUpperCase();
      if (targetId.isEmpty || !targetId.startsWith('SOV-')) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _navigatorKey.currentContext;
        if (ctx == null) return;
        _showSovIdCard(ctx, targetId);
      });
      return;
    }

    // ── sovlogin:// — SOV Login challenge from external site ─────────────
    // Format: sovlogin://{relay_ip}?s={session_id}&c={challenge}
    if (uri.scheme == 'sovlogin') {
      final sessionId    = uri.queryParameters['s'] ?? '';
      final challenge    = uri.queryParameters['c'] ?? '';
      final clientOrigin = uri.host; // relay IP that issued the challenge
      if (sessionId.isEmpty || challenge.isEmpty) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _navigatorKey.currentContext;
        if (ctx == null) return;
        Navigator.push(
          ctx,
          MaterialPageRoute(
            builder: (_) => SovLoginConfirmScreen(
              sessionId:    sessionId,
              challenge:    challenge,
              clientOrigin: clientOrigin,
            ),
          ),
        );
      });
      return;
    }

    if (uri.scheme != 'sovreq') return;

    // Parse: sovreq://SOV-XXXX?amount=1000000&memo=...&req=REQ-...&expires=...
    final recipientId = uri.host.toUpperCase();
    if (recipientId.isEmpty || !recipientId.startsWith('SOV-')) return;

    final amountSeeds = int.tryParse(uri.queryParameters['amount'] ?? '') ?? 0;
    final memo        = uri.queryParameters['memo'] ?? '';
    final reqId       = uri.queryParameters['req'];

    final amountSov = amountSeeds > 0 ? amountSeeds / 1000000.0 : null;

    // Need the citizen's own sovereign_id to open SendSovScreen
    final prefs  = await SharedPreferences.getInstance();
    final sovId  = prefs.getString('sovereign_id') ?? '';
    if (sovId.isEmpty) return; // not enrolled yet

    final seeds  = await RelayConnector.queryBalance(sovId).catchError((_) => 0);

    // Navigate — wait for first frame so the navigator is ready
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _navigatorKey.currentState?.push(
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => SendSovScreen(
            sovereignId:      sovId,
            seeds:            seeds,
            initialRecipientId: recipientId,
            initialAmount:    amountSov,
            initialMemo:      memo.isEmpty ? null : memo,
            paymentRequestId: reqId,
          ),
          transitionsBuilder: (_, anim, __, child) =>
              FadeTransition(opacity: anim, child: child),
          transitionDuration: const Duration(milliseconds: 250),
        ),
      );
    });
  }

  @override
  void dispose() {
    if (SovereignApp._instance == this) SovereignApp._instance = null;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {

    // inactive fires first on ALL devices when focus is lost.
    // paused fires after on most devices.
    // Some tablets with gesture nav only ever fire inactive — never paused.
    // hidden fires on some foldables/split-screen transitions.
    // We record the background timestamp on the FIRST of any of these.
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused   ||
        state == AppLifecycleState.hidden) {

      // Skip for external activities (palm scan, file picker, etc.)
      if (RelayConnector.enrollmentInProgress ||
          RelayConnector.externalActivityOpen) {
        return;
      }

      // No PIN set — do not lock
      if (_cachedPinHash == null ||
          _cachedPinHash!.isEmpty) {
        return;
      }

      // Record background time only on the FIRST state in this cycle.
      // The latch prevents us overwriting _pausedAt if both inactive
      // and paused fire (which is normal on phones), or if inactive fires
      // again on the return trip (some OEM skins do this).
      if (!_backgroundTimestampSet) {
        _pausedAt = DateTime.now();
        _backgroundTimestampSet = true;
      }
      return;
    }

    if (state == AppLifecycleState.resumed) {

      if (!_backgroundTimestampSet) {
        // Never recorded going to background — nothing to check
        _backgroundTimestampSet = false;
        return;
      }

      final elapsed = _pausedAt == null
          ? 3000
          : DateTime.now().difference(_pausedAt!).inMilliseconds;

      // Reset the latch for the next cycle
      _backgroundTimestampSet = false;
      _pausedAt = null;

      // Citizen-configurable lock policy (Settings → Security):
      //   auto_lock_enabled (bool, default true) — false ⇒ never auto-lock
      //   pin_lockout_ms    (int,  default 10000) — background tolerance
      //
      // Default 10000ms is the previous hardcoded value. Notification shade
      // interaction on phones is ~1-2s, on tablets up to ~8s, so 10s remains
      // the safe baseline for citizens who don't change anything.
      //
      // If the citizen turns auto-lock OFF entirely the lock is skipped — the
      // PinLockOverlay still appears on cold start (until they unlock once)
      // unless they ALSO disable PIN in settings, but background→foreground
      // never relocks.
      final lockPrefs  = await SharedPreferences.getInstance();
      final pinOn      = lockPrefs.getBool('pin_enabled') ?? true;
      final autoLockOn = (lockPrefs.getBool('auto_lock_enabled') ?? true) && pinOn;
      if (!autoLockOn) {
        // Skip the relock entirely
      } else {
        final lockoutMs = (await SharedPreferences.getInstance())
            .getInt('pin_lockout_ms') ?? 10000;
        if (elapsed > lockoutMs) {
          if (mounted && !_locked &&
              _cachedPinHash != null &&
              _cachedPinHash!.isNotEmpty) {
            setState(() => _locked = true);
          }
        }
      }

      // Reconnect relay if not locked
      if (!_locked) {
        RelayConnector.connect().catchError((_) => false);
      }
      // If locked: relay reconnects in _onUnlocked after PIN entry
    }
  }

  // ── Unlock ─────────────────────────────────────────────────────────────────

  /// Called by PinLockOverlay ONLY after correct PIN or palm authentication.
  void _onUnlocked() {
    setState(() => _locked = false);
    _submitLivenessAfterUnlock();
    RelayConnector.connect().catchError((_) => false);
    // Restore the last-open tab after unlock so the citizen lands exactly
    // where they were when the app locked.
    MainShell.restoreLastTab();
  }

  /// Called by PinLockOverlay when citizen taps "Forgot PIN".
  void _onForgotPin() {
    setState(() {
      _locked        = false;
      _cachedPinHash = '';
    });
    SharedPreferences.getInstance().then((prefs) {
      prefs.remove('pin_hash');
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _navigatorKey.currentState?.push(
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => const RecoveryScreen(),
          transitionsBuilder: (_, anim, __, child) =>
              FadeTransition(opacity: anim, child: child),
          transitionDuration: const Duration(milliseconds: 300),
        ),
      );
    });
  }

  /// Submit a silent liveness check after successful unlock.
  /// Fire-and-forget — never throws to caller.
  Future<void> _submitLivenessAfterUnlock() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final sovId = prefs.getString('sovereign_id') ?? '';
      if (sovId.isEmpty) return;

      final proofHash = sha256
          .convert(utf8.encode(
              sovId + DateTime.now().millisecondsSinceEpoch.toString()))
          .toString();

      await RelayConnector.submitLivenessCheck(sovId, proofHash);
      debugPrint('[LIVENESS] Submitted after unlock');
    } catch (e) {
      debugPrint('[LIVENESS] Silent fail: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: 'SOV Node',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFB8960C),
          brightness: Brightness.dark,
          surface: const Color(0xFF0A1628),
        ),
        scaffoldBackgroundColor: const Color(0xFF0A1628),
        useMaterial3: true,
        fontFamily: 'sans-serif',
        // ── NavigationBar Material 3 theming ─────────────────────────────────
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: const Color(0xFF0A1628),
          indicatorColor: const Color(0xFFD4AF37).withAlpha(55),
          surfaceTintColor: Colors.transparent,
          shadowColor: Colors.transparent,
          elevation: 0,
          labelTextStyle: WidgetStateProperty.resolveWith((states) {
            final selected = states.contains(WidgetState.selected);
            return TextStyle(
              color: selected
                  ? const Color(0xFFD4AF37)
                  : Colors.white54,
              fontSize: 10,
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            );
          }),
        ),
      ),
      home: const SplashScreen(),
      // Stack overlay above Navigator — covers everything including the
      // current route. When _locked=true the overlay covers the home screen
      // completely. Home screen renders underneath but is invisible.
      // Cannot be dismissed without correct PIN or palm authentication.
      builder: (context, child) {
        final content = Stack(
          children: [
            child!,
            if (_locked)
              PinLockOverlay(
                onUnlocked: _onUnlocked,
                onForgotPin: _onForgotPin,
              ),
          ],
        );
        // On desktop the phone layouts would stretch edge-to-edge across the
        // wide window. Frame them in a centred phone-width column on a navy
        // gutter, and report that width via MediaQuery so width-based layouts
        // (PIN keypad, grids) pack correctly instead of flinging to the edges.
        return _DesktopFrame(child: content);
      },
    );
  }
}

/// Centres the app in a phone-width column on desktop (no-op on mobile/narrow).
class _DesktopFrame extends StatelessWidget {
  final Widget child;
  const _DesktopFrame({required this.child});

  static const double _maxW = 540;
  static bool get _isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  @override
  Widget build(BuildContext context) {
    if (!_isDesktop) return child;
    final mq = MediaQuery.of(context);
    if (mq.size.width <= _maxW) return child; // narrow window → full width
    return ColoredBox(
      color: const Color(0xFF060E1A), // deeper-navy gutter
      child: Center(
        child: Container(
          width: _maxW,
          decoration: BoxDecoration(
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(120),
                blurRadius: 32,
                spreadRadius: 2,
              ),
            ],
            border: Border(
              left: BorderSide(color: Colors.white.withAlpha(12)),
              right: BorderSide(color: Colors.white.withAlpha(12)),
            ),
          ),
          clipBehavior: Clip.hardEdge,
          child: MediaQuery(
            data: mq.copyWith(size: Size(_maxW, mq.size.height)),
            child: child,
          ),
        ),
      ),
    );
  }
}

// ── Sovereign ID Card Sheet — shown on sovid:// deep link ────────────────────
// Privacy model: shows identicon + Sovereign ID only. No relay fetch.
// Network identity = Sovereign ID. No names, no bios, no photos.

class _SovIdCardSheet extends StatefulWidget {
  final String sovereignId;
  const _SovIdCardSheet({required this.sovereignId});
  @override
  State<_SovIdCardSheet> createState() => _SovIdCardSheetState();
}

class _SovIdCardSheetState extends State<_SovIdCardSheet> {
  String _palmName = '';

  @override
  void initState() {
    super.initState();
    RelayConnector.getPalmName().then((n) {
      if (mounted) setState(() => _palmName = n);
    });
  }

  @override
  Widget build(BuildContext context) {
    final sovereignId = widget.sovereignId;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag handle
          Container(
            width: 36, height: 4,
            decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(height: 24),
          // Palm-derived generative avatar
          PalmAvatar(
            palmName:    _palmName.isNotEmpty ? _palmName : RelayConnector.getPalmNameSync(),
            sovereignId: sovereignId,
            size:        80,
            circular:    false,
          ),
          const SizedBox(height: 16),
          const Text(
            'SOV Network Citizen',
            style: TextStyle(color: Colors.white38, fontSize: 12,
                letterSpacing: 0.6),
          ),
          const SizedBox(height: 10),
          // Sovereign ID — tap to copy
          GestureDetector(
            onTap: () {
              Clipboard.setData(ClipboardData(text: sovereignId));
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                      content: Text('Sovereign ID copied'),
                      backgroundColor: Color(0xFF0D1F3A),
                      behavior: SnackBarBehavior.floating,
                      duration: Duration(seconds: 2)));
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF0A1628),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white.withAlpha(15)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    sovereignId,
                    style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 14,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.copy_all_rounded,
                      color: Colors.white24, size: 14),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
