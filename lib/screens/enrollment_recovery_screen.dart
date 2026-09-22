// lib/screens/enrollment_recovery_screen.dart
// ─────────────────────────────────────────────────────────────────────────────
// ENROLLMENT RECOVERY SCREEN
//
// Shown when the app detects an interrupted enrollment: the palm was scanned
// and intermediate data was saved, but the relay calls (ENROLLMENT_REGISTER +
// PALM_EMBEDDING_REGISTER) never completed because Android killed the process.
//
// The citizen does NOT exist on the SOV Network yet. This screen retries the
// relay registration using the stored intermediate data.
//
// A citizen only exists on the SOV Network when ALL THREE are confirmed:
//   1. palm_embeddings record on relay
//   2. sov_disc slot with correct balance on relay
//   3. enrollment_complete flag in SharedPreferences
// ─────────────────────────────────────────────────────────────────────────────
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../sov_node_sdk/key_manager.dart';
import '../sov_node_sdk/relay_connector.dart';
import '../widgets/linux_pin_setup.dart';
import '../sov_node_sdk/wallet_engine.dart';
import '../sov_node_sdk/sov_id_v2.dart';
import 'enrollment_screen.dart';
import 'main_shell.dart';

class EnrollmentRecoveryScreen extends StatefulWidget {
  const EnrollmentRecoveryScreen({super.key});

  @override
  State<EnrollmentRecoveryScreen> createState() =>
      _EnrollmentRecoveryScreenState();
}

class _EnrollmentRecoveryScreenState extends State<EnrollmentRecoveryScreen> {
  static const _navy      = Color(0xFF0A1628);
  static const _gold      = Color(0xFFB8960C);
  static const _goldBright = Color(0xFFD4AF37);
  static const _red       = Color(0xFFE53935);

  bool   _loading      = false;
  bool   _succeeded    = false;
  String _statusText   = '';
  String _errorMsg     = '';
  String _sovId        = '';

  @override
  void initState() {
    super.initState();
    _loadSovId();
  }

  Future<void> _loadSovId() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString('sovereign_id') ?? '';
    if (mounted) setState(() => _sovId = id);
  }

  // ── Retry enrollment relay calls ────────────────────────────────────────────
  Future<void> _retryEnrollment() async {
    setState(() {
      _loading    = true;
      _errorMsg   = '';
      _statusText = 'Loading stored enrollment data...';
    });

    try {
      final prefs = await SharedPreferences.getInstance();

      final sovId      = prefs.getString('sovereign_id')            ?? '';
      final embJson    = prefs.getString('pending_palm_embedding')    ?? '';
      final helperData = prefs.getString('pending_helper_data')       ?? '';
      final keyHash    = prefs.getString('pending_key_hash')          ?? '';
      final handType   = prefs.getString('pending_hand_type')         ?? '';
      final threshold  = prefs.getDouble('pending_threshold')         ?? 0.5;

      if (sovId.isEmpty || embJson.isEmpty || helperData.isEmpty || keyHash.isEmpty) {
        throw Exception(
          'Incomplete enrollment data found. '
          'Please start a fresh enrollment.',
        );
      }

      // ── KEY-TO-KINGDOM BINDING ────────────────────────────────────────────
      // The phone died after the palm scan but before (or during) relay calls.
      // Re-derive the deterministic Ed25519 keypair from the stored palm master
      // hash so the correct (reproducible) public key is sent to the relay.
      // If the random ephemeral key is used instead, seed-phrase recovery would
      // derive a different keypair and signature verification would fail.
      setState(() => _statusText = 'Restoring enrollment keys...');
      await KeyManager.storeRestoredKeys(
        privateKeyHex: keyHash,
        sovereignId:   sovId,
      );
      final publicKey = await KeyManager.getPublicKey() ?? '';
      if (publicKey.isEmpty) {
        throw Exception('Key derivation failed — please start a fresh enrollment.');
      }
      debugPrint('[RECOVERY] Keys bound: sovId=$sovId  pk=${publicKey.substring(0, 8)}...');
      // ─────────────────────────────────────────────────────────────────────

      // ── Connect to relay ───────────────────────────────────────────────────
      setState(() => _statusText = 'Connecting to SOV Network...');
      if (!RelayConnector.isConnected) {
        await RelayConnector.connect();
        await Future.delayed(const Duration(seconds: 3));
      }
      if (!RelayConnector.isConnected) {
        throw Exception(
          'Cannot reach the SOV network relay.\n\n'
          'Please check:\n'
          '• Your internet connection is working\n'
          '• You are connected to Wi-Fi or mobile data\n\n'
          'If internet is working, the relay server may be temporarily offline. '
          'Try again in a few minutes.',
        );
      }

      // ── Step 1: ENROLLMENT_REGISTER ────────────────────────────────────────
      setState(() => _statusText = 'Registering with SOV Network...');
      final enrollResp = await RelayConnector.sendWithResilience(
        {
          'type':         'ENROLLMENT_REGISTER',
          'sovereign_id': sovId,
          'public_key':   publicKey,
        },
        'ENROLLMENT_ACK',
        maxRetries: 3,
        timeout: const Duration(seconds: 15),
        onStatusUpdate: (s) {
          if (mounted) setState(() => _statusText = s);
        },
      );
      debugPrint('[RECOVERY] ENROLLMENT_ACK: $enrollResp');
      if (enrollResp == null || enrollResp['success'] != true) {
        throw Exception(enrollResp?['error'] ?? 'Enrollment registration failed — no ACK');
      }

      // ── Step 2: PALM_EMBEDDING_REGISTER ───────────────────────────────────
      setState(() => _statusText = 'Storing biometric on SOV Network...');
      final palmResp = await RelayConnector.sendWithResilience(
        {
          'type':          'PALM_EMBEDDING_REGISTER',
          'sovereign_id':  sovId,
          'embedding':     embJson,
          'helper_data':   helperData,
          'helper_data_2': helperData, // primary (multi-quant disabled)
          'helper_data_3': helperData, // primary (multi-quant disabled)
          'threshold':     threshold,
          'threshold_2':   threshold,
          'threshold_3':   threshold,
          'key_hash':      keyHash,
          'hand_type':     handType,
        },
        'PALM_EMBEDDING_RESULT',
        maxRetries: 3,
        timeout: const Duration(seconds: 20),
        onStatusUpdate: (s) {
          if (mounted) setState(() => _statusText = s);
        },
      );
      debugPrint('[RECOVERY] PALM_EMBEDDING_RESULT: $palmResp');
      if (palmResp == null) {
        throw Exception('Palm registration timed out — relay did not respond.');
      }
      if (palmResp['success'] != true) {
        throw Exception('RELAY ERROR: ${palmResp['error'] ?? 'Palm registration failed'}');
      }

      final slotId    = (palmResp['slot_id']       as num?)?.toInt()    ?? 0;
      final mintedSOV = (palmResp['enrollment_sov'] as num?)?.toDouble() ?? 1000.0;
      final countryName = SovIdV2.getCountryName(sovId);

      // ── Step 3: Persist completed enrollment ──────────────────────────────
      setState(() => _statusText = 'Saving enrollment...');
      await Future.wait([
        prefs.setString('sovereign_id',       sovId),
        prefs.setString('citizen_country',    countryName),
        prefs.setInt(   'slot_id',            slotId),
        prefs.setBool(  'enrollment_complete', true),
        prefs.setInt(   'enrolled_at',        DateTime.now().millisecondsSinceEpoch),
        prefs.setString('left_helper_data',   helperData),
        prefs.setString('left_key_hash',      keyHash),
        prefs.setString('enrolled_hand',      handType),
        // Clear pending intermediate data
        prefs.remove('enroll_pending'),
        prefs.remove('pending_public_key'),
        prefs.remove('pending_palm_embedding'),
        prefs.remove('pending_helper_data'),
        prefs.remove('pending_key_hash'),
        prefs.remove('pending_hand_type'),
        prefs.remove('pending_threshold'),
      ]);

      // Update balance (non-fatal) — initialise creates the wallet row first
      try {
        await WalletEngine.initialise();
        await WalletEngine.updateBalance(mintedSOV * 1000000);
      } catch (e) {
        debugPrint('[RECOVERY] Balance update failed (non-fatal): $e');
      }

      RelayConnector.enrollmentInProgress = false;
      if (mounted) setState(() { _loading = false; _succeeded = true; });
    } catch (e) {
      debugPrint('[RECOVERY] Retry failed: $e');
      RelayConnector.enrollmentInProgress = false;
      if (mounted) {
        setState(() {
          _loading    = false;
          _errorMsg   = e.toString().replaceFirst('Exception: ', '');
          _statusText = '';
        });
      }
    }
  }

  // ── Start fresh — wipe pending data and go to enrollment ──────────────────
  Future<void> _startFresh() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF0D1E35),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Start Fresh?',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: const Text(
          'This will erase the interrupted enrollment and take you back to '
          'the join screen. Your previous palm scan will not be stored on '
          'the network. Are you sure?',
          style: TextStyle(color: Colors.white70, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel', style: TextStyle(color: _gold)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Start Fresh',
                style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    // Wipe all pending and local enrollment data
    final prefs = await SharedPreferences.getInstance();
    await Future.wait([
      prefs.remove('enroll_pending'),
      prefs.remove('sovereign_id'),
      prefs.remove('enrollment_complete'),
      prefs.remove('pending_public_key'),
      prefs.remove('pending_palm_embedding'),
      prefs.remove('pending_helper_data'),
      prefs.remove('pending_key_hash'),
      prefs.remove('pending_hand_type'),
      prefs.remove('pending_threshold'),
      prefs.remove('left_helper_data'),
      prefs.remove('left_key_hash'),
      prefs.remove('enrolled_hand'),
      prefs.remove('slot_id'),
      prefs.remove('enrolled_at'),
      prefs.remove('citizen_country'),
    ]);

    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const EnrollmentScreen(),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 500),
      ),
    );
  }

  // ── Navigate to home after successful recovery ─────────────────────────────
  Future<void> _goHome() async {
    // Linux: persist the restored key behind a PIN before entering the wallet,
    // else it is held in memory only and lost at next launch. No-op elsewhere.
    await ensureKeyPersistedOnLinux(context);
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const MainShell(),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 600),
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _navy,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
          child: _succeeded ? _buildSuccess() : _buildRecovery(),
        ),
      ),
    );
  }

  Widget _buildRecovery() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 20),

        // Warning icon
        Center(
          child: Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _red.withAlpha(30),
              border: Border.all(color: _red.withAlpha(120), width: 1.5),
            ),
            child: const Icon(Icons.warning_amber_rounded, color: _red, size: 40),
          ),
        ),

        const SizedBox(height: 28),

        // Title
        const Center(
          child: Text(
            'Enrollment Interrupted',
            style: TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
        ),

        const SizedBox(height: 16),

        // Explanation
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white.withAlpha(8),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white12),
          ),
          child: const Text(
            'Your palm scan was saved but the network registration did not complete — '
            'the device was interrupted before the relay could confirm your identity.\n\n'
            'You are NOT yet a citizen on the SOV Network. Tap "Complete Enrollment" '
            'to finish the registration using your saved data.',
            style: TextStyle(color: Colors.white70, height: 1.5, fontSize: 13.5),
          ),
        ),

        const SizedBox(height: 16),

        // Sovereign ID chip
        if (_sovId.isNotEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: _gold.withAlpha(20),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _gold.withAlpha(60)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Pending Sovereign ID',
                  style: TextStyle(
                    color: _gold,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _sovId,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),

        // Status / error
        if (_loading) ...[
          const SizedBox(height: 24),
          Center(
            child: Column(
              children: [
                const SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    valueColor: AlwaysStoppedAnimation<Color>(_gold),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  _statusText,
                  textAlign: TextAlign.center,
                  style:
                      const TextStyle(color: Colors.white54, fontSize: 13),
                ),
              ],
            ),
          ),
        ],

        if (_errorMsg.isNotEmpty) ...[
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _red.withAlpha(20),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _red.withAlpha(80)),
            ),
            child: Text(
              _errorMsg,
              style: const TextStyle(color: Colors.redAccent, fontSize: 13, height: 1.4),
            ),
          ),
        ],

        const Spacer(),

        // Complete Enrollment button
        SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton.icon(
            onPressed: _loading ? null : _retryEnrollment,
            icon: _loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.black),
                  )
                : const Icon(Icons.check_circle_outline_rounded, size: 22),
            label: Text(
              _loading ? 'Registering...' : 'Complete Enrollment',
              style: const TextStyle(
                  fontSize: 15, fontWeight: FontWeight.bold),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: _gold,
              foregroundColor: Colors.black,
              disabledBackgroundColor: _gold.withAlpha(100),
              disabledForegroundColor: Colors.black54,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
              elevation: 0,
            ),
          ),
        ),

        const SizedBox(height: 12),

        // Start Fresh button
        SizedBox(
          width: double.infinity,
          height: 48,
          child: OutlinedButton.icon(
            onPressed: _loading ? null : _startFresh,
            icon: const Icon(Icons.refresh_rounded, size: 20),
            label: const Text('Start Fresh',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white54,
              side: const BorderSide(color: Colors.white24, width: 1),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
          ),
        ),

        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildSuccess() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Success icon
        Container(
          width: 96,
          height: 96,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _gold.withAlpha(30),
            border: Border.all(color: _gold.withAlpha(120), width: 2),
            boxShadow: [
              BoxShadow(color: _gold.withAlpha(50), blurRadius: 20, spreadRadius: 4),
            ],
          ),
          child: const Icon(Icons.check_circle_rounded, color: _goldBright, size: 52),
        ),

        const SizedBox(height: 32),

        const Text(
          'Enrollment Complete',
          style: TextStyle(
            color: Colors.white,
            fontSize: 24,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),

        const SizedBox(height: 12),

        const Text(
          'You are now a citizen of the SOV Network.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: _gold,
            fontSize: 14,
            letterSpacing: 0.5,
          ),
        ),

        if (_sovId.isNotEmpty) ...[
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white.withAlpha(8),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white12),
            ),
            child: Text(
              _sovId,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],

        const SizedBox(height: 48),

        SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton(
            onPressed: _goHome,
            style: ElevatedButton.styleFrom(
              backgroundColor: _gold,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
              elevation: 0,
            ),
            child: const Text(
              'Enter SOV Network',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
          ),
        ),
      ],
    );
  }
}
