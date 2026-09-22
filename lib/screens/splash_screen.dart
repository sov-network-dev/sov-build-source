// lib/screens/splash_screen.dart
// ─────────────────────────────────────────────────────────────────────────────
// SCREEN 1 — Splash Screen
// Navy background, gold SOV symbol, fade-in animation.
// Checks enrollment status and routes accordingly.
// ─────────────────────────────────────────────────────────────────────────────
import 'dart:io' show Platform;
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../sov_node_sdk/sov_checkpoint.dart';
import '../sov_node_sdk/sov_node.dart';
import '../sov_node_sdk/sov_file_intent.dart';
import 'enrollment_screen.dart';
import 'enrollment_recovery_screen.dart';
import 'main_shell.dart';
import 'recovery_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {

  static const _navy    = Color(0xFF0A1628);
  static const _gold    = Color(0xFFB8960C);
  static const _goldBright = Color(0xFFD4AF37);

  late AnimationController _ctrl;
  late Animation<double>   _fade;
  late Animation<double>   _scale;
  late Animation<double>   _ringFade;

  String _statusText  = 'Initialising...';
  bool   _showChoices = false; // shown when unenrolled after routing completes
  bool   _loading     = true;  // true while async routing is in progress

  /// Desktop cannot enrol — the palm scan needs a phone camera + torch, so the
  /// desktop build is recover-and-run-a-node only.
  static final bool _isDesktop =
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  @override
  void initState() {
    super.initState();

    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );

    _fade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl,
          curve: const Interval(0.0, 0.6, curve: Curves.easeIn)),
    );
    _scale = Tween<double>(begin: 0.75, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl,
          curve: const Interval(0.0, 0.7, curve: Curves.easeOutBack)),
    );
    _ringFade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl,
          curve: const Interval(0.4, 1.0, curve: Curves.easeIn)),
    );

    _ctrl.forward();
    _bootAndNavigate();
  }

  Future<void> _bootAndNavigate() async {
    // If this fires during an active enrollment it means Android killed and
    // recreated the process. Log it so we can detect process death in the
    // debug console.
    debugPrint('[SPLASH] _bootAndNavigate called — process may have been recreated');

    // Listen to node boot status for UI feedback
    SOVNode.statusStream?.listen((status) {
      if (mounted) setState(() => _statusText = status.connectionLabel);
    });

    // Boot the node
    await SOVNode.boot();

    // Show splash for at least 2.2s
    await Future.delayed(const Duration(milliseconds: 2200));

    if (!mounted) return;

    await _determineStartRoute();
  }

  /// Determine which screen to navigate to based on enrollment state.
  ///
  /// File-intent check (FIRST — "Open With" cold start):
  ///   fileBytes != null → recovery screen with file bytes pre-loaded
  ///
  /// Checkpoint check (SECOND — survives SIGKILL during external activity):
  ///   recoveryFilePicker → recovery screen (process died during file picker)
  ///   enrollmentShare    → home screen (enrollment was complete, share died)
  ///
  /// Routing cases (after checkpoint):
  ///   A. enroll_pending=true, enrollment_complete=false  → enrollment recovery (interrupted enrollment)
  ///   B. enrollment_complete=true, relay confirms record  → home
  ///   C. enrollment_complete=true, relay no record found  → enrollment recovery (interrupted)
  ///   D. enrollment_complete=true, relay unreachable      → home (offline tolerance)
  ///   E. Neither enrolled nor pending                     → join/restore choices
  Future<void> _determineStartRoute() async {
    // ── File-intent check ─────────────────────────────────────────────────────
    // MUST be first — if the app was launched via "Open With" we route directly
    // to RecoveryScreen with the file bytes, bypassing the file picker entirely.
    // Android-only native "Open With" intent; on desktop/web it doesn't exist,
    // so guard against a MissingPluginException and just continue normally.
    Uint8List? fileBytes;
    try {
      fileBytes = await SovFileIntent.getPendingFile();
    } catch (_) {
      fileBytes = null;
    }
    if (fileBytes != null) {
      debugPrint('[SPLASH] Launched via "Open With" — routing to recovery with file (${fileBytes.length} bytes)');
      if (mounted) _goRecoverWithFile(fileBytes);
      return;
    }

    // ── Checkpoint check ─────────────────────────────────────────────────────
    // MUST be first — checkpoint survived SIGKILL during external activity.
    // SharedPreferences may not have flushed; kernel file write survives.
    final checkpoint = await SovCheckpoint.read();
    if (checkpoint != null) {
      final type = checkpoint['type'] as String;
      final data = checkpoint['data'] as Map<String, dynamic>;
      await SovCheckpoint.clear();

      if (type == CheckpointType.recoveryFilePicker) {
        debugPrint('[SPLASH] Recovery file picker interrupted — routing to recovery (file step)');
        if (mounted) _goRecoverFilePicker();
        return;
      }

      if (type == CheckpointType.enrollmentShare) {
        final sovId = data['sovereign_id'] as String? ?? '';
        debugPrint('[SPLASH] Enrollment share interrupted — routing to home');
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('enrollment_complete', true);
        if (sovId.isNotEmpty) await prefs.setString('sovereign_id', sovId);
        if (mounted) _goHome();
        return;
      }
    }

    // ── Standard routing ─────────────────────────────────────────────────────
    final prefs         = await SharedPreferences.getInstance();
    final sovId         = prefs.getString('sovereign_id') ?? '';
    final enrolled      = prefs.getBool('enrollment_complete') ?? false;
    final enrollPending = prefs.getBool('enroll_pending')      ?? false;
    debugPrint('[SPLASH] _determineStartRoute: enrollment_complete=$enrolled  enroll_pending=$enrollPending  sovereign_id=${sovId.isEmpty ? "EMPTY" : "${sovId.substring(0, sovId.length.clamp(0, 12))}..."}');

    // Case A: Interrupted enrollment — relay calls never completed
    if (enrollPending && !enrolled && sovId.isNotEmpty) {
      debugPrint('[SPLASH] enroll_pending detected — routing to enrollment recovery');
      if (mounted) _goEnrollmentRecovery();
      return;
    }

    // Case B / D: Locally enrolled — go home.
    // NOTE: We do NOT check relay record here for routing decisions.
    // If enrollment_complete=true, the citizen has valid local keys and
    // a confirmed identity. Routing to EnrollmentRecoveryScreen when the
    // relay happens to not know the citizen (e.g. after backup restore,
    // relay replication lag, or connecting to a different relay) would
    // destroy the restored identity — the recovery screen wipes sovereign_id
    // when it finds no pending_palm_embedding. Always go home; the balance
    // will sync once the relay recognises the citizen on reconnect.
    if (enrolled && sovId.isNotEmpty) {
      debugPrint('[SPLASH] enrollment_complete=true → routing to home (no relay gate)');
      if (mounted) _goHome();
      return;
    }

    // Case E: Not enrolled at all — show join/restore choices
    debugPrint('[SPLASH] Case E: not enrolled → showing join/restore choices');
    if (mounted) setState(() { _loading = false; _showChoices = true; });
  }

  void _goHome() => Navigator.pushReplacement(context,
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const MainShell(),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 600),
      ));

  void _goEnrollmentRecovery() => Navigator.pushReplacement(context,
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const EnrollmentRecoveryScreen(),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 500),
      ));

  void _goEnroll() => Navigator.pushReplacement(context,
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const EnrollmentScreen(),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 500),
      ));

  void _goRecover() => Navigator.pushReplacement(context,
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const RecoveryScreen(),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 500),
      ));

  /// Used when the app was cold-started via Android "Open With".
  /// Delivers the file bytes directly to RecoveryScreen — no picker needed.
  void _goRecoverWithFile(Uint8List bytes) => Navigator.pushReplacement(context,
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => RecoveryScreen(fileBytes: bytes),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 500),
      ));

  /// Used when the process was killed during the file picker.
  /// Starts RecoveryScreen at the seed/file step so the citizen can
  /// immediately try selecting their wallet file again.
  void _goRecoverFilePicker() => Navigator.pushReplacement(context,
      PageRouteBuilder(
        pageBuilder: (_, __, ___) =>
            const RecoveryScreen(startAtFilePicker: true),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 500),
      ));

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Show plain navy spinner while routing is in progress.
    // This prevents any flash of join/restore UI before the route is decided.
    if (_loading) {
      return const Scaffold(
        backgroundColor: _navy,
        body: Center(
          child: CircularProgressIndicator(
            color: _goldBright,
            strokeWidth: 2,
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: _navy,
      body: Center(
        child: AnimatedBuilder(
          animation: _ctrl,
          builder: (_, __) => FadeTransition(
            opacity: _fade,
            child: ScaleTransition(
              scale: _scale,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // SOV Symbol — concentric rings + S monogram
                  SizedBox(
                    width: 160,
                    height: 160,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        // Outer ring (fades in last)
                        FadeTransition(
                          opacity: _ringFade,
                          child: Container(
                            width: 160,
                            height: 160,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: _gold.withAlpha(40),
                                width: 1,
                              ),
                            ),
                          ),
                        ),
                        // Middle ring
                        FadeTransition(
                          opacity: _ringFade,
                          child: Container(
                            width: 130,
                            height: 130,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: _gold.withAlpha(70),
                                width: 1.5,
                              ),
                            ),
                          ),
                        ),
                        // Core circle with gradient
                        Container(
                          width: 100,
                          height: 100,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              colors: [
                                _gold.withAlpha(60),
                                _navy,
                              ],
                              stops: const [0.0, 1.0],
                            ),
                            border: Border.all(
                              color: _gold,
                              width: 2,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: _gold.withAlpha(60),
                                blurRadius: 24,
                                spreadRadius: 4,
                              ),
                            ],
                          ),
                          child: Center(
                            child: ClipOval(
                              child: Image.asset(
                                'assets/brand/sov_logo.png',
                                width: 86,
                                height: 86,
                                fit: BoxFit.cover,
                                // Fall back to the lettermark only if the asset
                                // is somehow missing, so the splash never breaks.
                                errorBuilder: (_, __, ___) => const Text(
                                  'S',
                                  style: TextStyle(
                                    color: _goldBright,
                                    fontSize: 48,
                                    fontWeight: FontWeight.bold,
                                    height: 1.0,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 36),

                  // App name
                  const Text(
                    'SOV NODE',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 8,
                    ),
                  ),

                  const SizedBox(height: 8),

                  const Text(
                    'SOV Network',
                    style: TextStyle(
                      color: _gold,
                      fontSize: 13,
                      letterSpacing: 4,
                      fontWeight: FontWeight.w400,
                    ),
                  ),

                  const SizedBox(height: 64),

                  // Progress bar
                  SizedBox(
                    width: 180,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: const LinearProgressIndicator(
                        backgroundColor: Colors.white10,
                        valueColor: AlwaysStoppedAnimation<Color>(_gold),
                        minHeight: 2,
                      ),
                    ),
                  ),

                  const SizedBox(height: 16),

                  Text(
                    _statusText,
                    style: const TextStyle(
                      color: Colors.white30,
                      fontSize: 11,
                      letterSpacing: 1,
                    ),
                  ),

                  // ── Join / Recover buttons (shown when unenrolled) ─────────
                  if (_showChoices) ...[
                    const SizedBox(height: 48),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Column(
                        children: [
                          // Enrollment is phone-only by design: the palm scan needs
                          // a good rear camera and a torch, which desktops do not
                          // reliably have. Offering "Join the Network" here sent
                          // desktop users into a scan that cannot succeed, so on
                          // desktop we show recovery only and say where to enroll.
                          if (!_isDesktop) ...[
                            SizedBox(
                              width: double.infinity,
                              height: 52,
                              child: ElevatedButton.icon(
                                onPressed: _goEnroll,
                                icon: const Icon(Icons.fingerprint_rounded,
                                    size: 22),
                                label: const Text('Join the Network',
                                    style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.bold)),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: _gold,
                                  foregroundColor: Colors.black,
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14)),
                                  elevation: 0,
                                ),
                              ),
                            ),
                            const SizedBox(height: 14),
                          ] else ...[
                            Text(
                              'New to SOV? Enrol on the phone app first — the palm '
                              'scan needs a phone camera and torch. Once enrolled, '
                              'recover your wallet here to use it on this computer '
                              'and to run a full node.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.white.withAlpha(140),
                                fontSize: 12.5,
                                height: 1.45,
                              ),
                            ),
                            const SizedBox(height: 18),
                          ],
                          SizedBox(
                            width: double.infinity,
                            height: 48,
                            child: OutlinedButton.icon(
                              key: const ValueKey('recoverWalletButton'), // flutter_driver target
                              onPressed: _goRecover,
                              icon: const Icon(Icons.restore_rounded,
                                  size: 20),
                              label: const Text('Recover My Wallet',
                                  style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600)),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.white70,
                                side: BorderSide(
                                    color: _gold.withAlpha(80), width: 1),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14)),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
