// permissions_bundle_screen.dart
//
// Shared permission-request slide shown to every citizen, whether they
// reached this point via fresh enrollment or via wallet recovery. Bundles
// the four runtime-required Android permissions into a single moment so
// citizens don't get hit with permission dialogs scattered through the
// app at first-use of each feature.
//
// Per CLAUDE.md §17 — Tier 3 (phone-native, OS state, no relay involvement).
// Per SOV_Network_Protocol_Book_v1.0 §17 line 186 — onboarding_screen.dart
// (Step 1) covers "network intro, consent" — this screen is the consent
// half of that step.
//
// Android cannot truly auto-grant permissions silently. Each
// Permission.x.request() shows the OS system dialog and the citizen must
// tap Allow/Deny. This screen funnels all of them into one bursting flow
// so the dialogs feel expected rather than scattered surprises.
//
// Routing:
//   - Enrollment path: OnboardingScreen → PermissionsBundleScreen → EnrollmentScreen
//   - Recovery path:   recovery completion → PermissionsBundleScreen → MainShell
// The caller passes an onComplete callback (typically a Navigator.pushReplacement
// to whatever screen should come next).

import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import '../sov_node_sdk/relay_connector.dart';

class PermissionsBundleScreen extends StatefulWidget {
  /// Called once the citizen has either granted or skipped permissions.
  /// Typically navigates the next screen (EnrollmentScreen or MainShell).
  final VoidCallback onComplete;

  const PermissionsBundleScreen({super.key, required this.onComplete});

  @override
  State<PermissionsBundleScreen> createState() => _PermissionsBundleScreenState();
}

class _PermissionsBundleScreenState extends State<PermissionsBundleScreen> {
  bool _requesting = false;
  bool _showSettingsHint = false;

  @override
  void initState() {
    super.initState();
    // Desktop (Windows/macOS/Linux): these are mobile runtime permissions. Windows
    // grants camera/mic on first USE and uses native toasts — this pre-prompt screen
    // is irrelevant, so skip it straight to the next step.
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onComplete();
      });
    }
  }

  static const _bg     = Color(0xFF0A0A1A);
  static const _teal   = Color(0xFF00D4AA);
  static const _white  = Colors.white;
  static const _white60 = Colors.white60;

  Future<void> _requestAll() async {
    if (_requesting) return;
    setState(() {
      _requesting = true;
      _showSettingsHint = false;
    });
    RelayConnector.externalActivityOpen = true;
    bool anyPermanentlyDenied = false;
    try {
      // Request in sequence — Android only shows one dialog at a time.
      // Each call is a no-op if the permission was previously granted.
      final mic    = await Permission.microphone.request();
      final cam    = await Permission.camera.request();
      // Notifications — Android 13+. On older versions request() returns
      // granted without prompting.
      final notif  = await Permission.notification.request();
      // Photos / storage — newer Android uses photos, older uses storage.
      // permission_handler maps to the right one internally.
      final photos = await Permission.photos.request();

      if (mic.isPermanentlyDenied || cam.isPermanentlyDenied ||
          notif.isPermanentlyDenied || photos.isPermanentlyDenied) {
        anyPermanentlyDenied = true;
      }
    } catch (e) {
      debugPrint('[PermissionsBundle] request error: $e');
    } finally {
      RelayConnector.externalActivityOpen = false;
    }

    if (!mounted) return;
    if (anyPermanentlyDenied) {
      // Some permissions were denied with "Don't ask again". The only way
      // for the citizen to enable them is in system Settings. Show a hint
      // with an Open Settings button instead of just proceeding silently.
      setState(() {
        _requesting = false;
        _showSettingsHint = true;
      });
      return;
    }
    // All decided (granted or not). Move on either way — the inline
    // safety-net requests in feature screens (e.g. call_screen.dart) will
    // re-prompt for any feature that needs a denied permission.
    widget.onComplete();
  }

  void _skip() {
    if (_requesting) return;
    // Even on skip, fire the requests once — if citizens are going to use
    // the app at all, they'll need these. If they tap Deny on the dialogs,
    // the app degrades feature-by-feature. If they tap Allow, perfect.
    _requestAll();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
          child: Column(
            children: [
              const Spacer(flex: 1),
              const Icon(Icons.shield_outlined, color: _teal, size: 56),
              const SizedBox(height: 24),
              const Text(
                'Allow SOV to use these',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Set up everything once so the app works smoothly.',
                textAlign: TextAlign.center,
                style: TextStyle(color: _white60, fontSize: 14, height: 1.5),
              ),
              const SizedBox(height: 32),
              const _PermissionRow(
                icon: Icons.mic_outlined,
                title: 'Microphone',
                body: 'Voice notes, voice calls, video calls.',
              ),
              const _PermissionRow(
                icon: Icons.camera_alt_outlined,
                title: 'Camera',
                body: 'Palm scan, QR codes, video calls.',
              ),
              const _PermissionRow(
                icon: Icons.notifications_outlined,
                title: 'Notifications',
                body: 'Incoming calls, messages, payments.',
              ),
              const _PermissionRow(
                icon: Icons.photo_library_outlined,
                title: 'Photos',
                body: 'Attach images, scan QR from gallery.',
              ),
              const SizedBox(height: 24),
              const Text(
                'SOV never sends this data to anyone. '
                'It is only used on your phone.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white38, fontSize: 12, height: 1.5),
              ),
              const Spacer(flex: 2),
              if (_showSettingsHint) ...[
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    'Some permissions were blocked. Open system Settings to '
                    'enable them, or continue and turn them on later.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.orangeAccent,
                      fontSize: 13,
                      height: 1.4,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: _teal),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: () async {
                          RelayConnector.externalActivityOpen = true;
                          await openAppSettings();
                          if (mounted) RelayConnector.externalActivityOpen = false;
                        },
                        child: const Text(
                          'Open Settings',
                          style: TextStyle(color: _teal),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _teal,
                          foregroundColor: _bg,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: widget.onComplete,
                        child: const Text(
                          'Continue',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ],
                ),
              ] else ...[
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _teal,
                      foregroundColor: _bg,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    onPressed: _requesting ? null : _requestAll,
                    child: _requesting
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              valueColor: AlwaysStoppedAnimation<Color>(_bg),
                            ),
                          )
                        : const Text(
                            'Allow All & Continue',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                  ),
                ),
                const SizedBox(height: 10),
                TextButton(
                  onPressed: _requesting ? null : _skip,
                  child: const Text(
                    'Skip for now',
                    style: TextStyle(color: Colors.white38, fontSize: 13),
                  ),
                ),
              ],
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

class _PermissionRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;

  const _PermissionRow({
    required this.icon,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: _PermissionsBundleScreenState._teal, size: 28),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: const TextStyle(
                    color: Colors.white60,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
