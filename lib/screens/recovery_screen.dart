// lib/screens/recovery_screen.dart
// ─────────────────────────────────────────────────────────────────────────────
// WALLET RECOVERY SCREEN
//
// v1 — Seed phrase only recovery paths:
//   A. Palm Scan    — DISABLED: seed phrase only for v1
//                    See SOV_PROJECT_MEMORY.md for re-enablement plan
//   B. Seed Phrase  — BIP39 12-word → derive sovereign_id → query relay
//   C. Guardian     — 2-of-3 guardian co-signature (last resort)
// ─────────────────────────────────────────────────────────────────────────────
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
// DISABLED: palm recovery removed - seed phrase only for v1
// import 'package:camera/camera.dart';
// import 'package:sensors_plus/sensors_plus.dart';
// import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:cryptography/cryptography.dart' as sov_crypto;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../sov_node_sdk/sov_file_intent.dart';
import '../sov_node_sdk/sov_db_path.dart';
import 'package:flutter/services.dart' show Clipboard;
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;
// DISABLED: palm recovery removed - seed phrase only for v1
// import '../sov_node_sdk/palm_image_engine.dart';
// import '../sov_node_sdk/palm_embedder.dart';
import '../sov_node_sdk/contacts_db.dart';
import '../sov_node_sdk/relay_connector.dart';
import '../sov_node_sdk/transaction_store.dart';
import '../sov_node_sdk/wallet_engine.dart';
import '../widgets/linux_pin_setup.dart';
import '../sov_node_sdk/bip39.dart';
import '../sov_node_sdk/key_manager.dart';
import 'main_shell.dart';
import 'permissions_bundle_screen.dart';
import 'pin_setup_screen.dart';

// ── Enums ─────────────────────────────────────────────────────────────────────
enum _Phase {
  methodSelect,
  scanning,       // DISABLED: palm scan removed v1 — never routed
  verifying,      // still used by seed recovery flow
  seedEntry,
  guardianWait,
  tryRightPalm,   // DISABLED: palm scan removed v1 — never routed
  success,
  syncing,        // Post-PIN: wait for relay LEDGER_SYNC_RESPONSE before home
  failed,
}

// ═════════════════════════════════════════════════════════════════════════════
class RecoveryScreen extends StatefulWidget {
  /// [startAtFilePicker] — set to true when routing here after a checkpoint
  /// detected that the process was killed during the file picker activity.
  /// Skips the method-select screen and lands directly at the seed/file step.
  ///
  /// [fileBytes] — raw bytes of a .sov file delivered via Android "Open With"
  /// (cold start or mid-session). When set the screen skips to seedEntry and
  /// immediately parses + validates the file, showing the password form.
  const RecoveryScreen({
    super.key,
    this.startAtFilePicker = false,
    this.fileBytes,
  });
  final bool startAtFilePicker;
  final Uint8List? fileBytes;

  @override
  State<RecoveryScreen> createState() => _RecoveryScreenState();
}

class _RecoveryScreenState extends State<RecoveryScreen>
    with WidgetsBindingObserver {

  // ── Brand colours ──────────────────────────────────────────────────────────
  static const _navy   = Color(0xFF0A1628);
  static const _gold   = Color(0xFFB8960C);
  static const _cardBg = Color(0xFF0D1F3A);

  // ── Phase ──────────────────────────────────────────────────────────────────
  _Phase _phase = _Phase.methodSelect;

  // ── Restore sync ───────────────────────────────────────────────────────────
  String _syncStatus = 'Connecting to SOV Network…';

  // ── Camera — DISABLED: palm recovery removed v1 ───────────────────────────
  // DISABLED: palm recovery removed - seed phrase only for v1
  // CameraController? _cam;
  // bool _torchOn = false;

  // ── Scan loop — DISABLED: palm recovery removed v1 ───────────────────────
  // bool _loopRunning = false;
  // bool _scanBusy    = false;
  // bool _captured    = false;
  String _guidance  = ''; // kept — used by _buildVerifying() in seed recovery

  // double _alignProgress = 0.0;
  // int    _goodFrames    = 0;
  // static const _kGoodFramesNeeded = 2;
  // final List<Uint8List> _goodFrameBuffer = [];
  // double _handAngleRad = 0;

  // ── Accelerometer — DISABLED: palm recovery removed v1 ────────────────────
  // StreamSubscription? _accelSub;
  // bool _isStable = false;

  // ── Watchdog — DISABLED ────────────────────────────────────────────────────
  // Timer? _watchdog;
  // DateTime? _loopStartTime;

  // ── Smart reticle — DISABLED ──────────────────────────────────────────────
  // Rect?  _liveBox;
  // bool   _liveDetected    = false;

  // ── Recovery result ────────────────────────────────────────────────────────
  String _recoveredSovId  = '';
  double _recoveredBalance = 0;
  String _errorMsg         = '';

  // ── Palm attempt tracking — DISABLED: palm recovery removed v1 ───────────
  // bool   _scanningRightPalm = false;
  // String _leftSovId         = '';

  // ── Seed phrase ────────────────────────────────────────────────────────────
  final List<TextEditingController> _seedCtrl =
      List.generate(12, (_) => TextEditingController());
  String _seedError = '';

  // ── Seed recovery sub-mode ──────────────────────────────────────────────────
  // null = card select, 'type' = manual entry
  String? _seedRecoveryMode;

  // ── Wallet file recovery ────────────────────────────────────────────────────
  Map<String, dynamic>?    _selectedFileData;
  bool                     _showPasswordEntry = false;
  String                   _decryptPassword   = '';
  String?                  _recoveryError;
  bool                     _recovering        = false;
  String                   _recoveryStatus    = '';
  // True while the native file picker is open (fire intent → app resume).
  // Keeps externalActivityOpen=true so the PIN lock overlay is suppressed.
  bool                     _pickerOpen        = false;

  // ── Guardian ───────────────────────────────────────────────────────────────
  String _guardianSessionId = '';
  int    _guardianApprovals = 0;
  Timer? _guardianPollTimer;
  StreamSubscription? _relaySub;

  // ═══════════════════════════════════════════════════════════════════════════
  // LIFECYCLE
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // DISABLED: palm recovery removed - reticle pulse controller not needed
    // _reticlePulseCtrl = AnimationController(...)

    // "Open With" cold start or mid-session: file bytes delivered by Android.
    // Parse the file immediately and show the password form.
    if (widget.fileBytes != null) {
      _phase = _Phase.seedEntry;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _processIncomingFile(widget.fileBytes!);
      });
    }
    // If the process was killed during the file picker, land directly at the
    // wallet-file section and tell the citizen what happened.
    else if (widget.startAtFilePicker) {
      _phase = _Phase.seedEntry;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showSnack(
          'File selection was interrupted — please select your wallet file again.',
        );
      });
    }
  }

  @override
  void dispose() {
    // WakelockPlus.disable(); // DISABLED: palm recovery removed
    WidgetsBinding.instance.removeObserver(this);
    // _stopLoop();           // DISABLED: palm recovery removed
    // _watchdog?.cancel();   // DISABLED: palm recovery removed
    // _accelSub?.cancel();   // DISABLED: palm recovery removed
    _guardianPollTimer?.cancel();
    _relaySub?.cancel();
    // _reticlePulseCtrl.dispose(); // DISABLED
    // try { _cam?.setFlashMode(FlashMode.off); } catch (_) {} // DISABLED
    // _cam?.dispose();       // DISABLED
    for (final c in _seedCtrl) { c.dispose(); }
    super.dispose();
  }

  /// Called when the app returns to the foreground.
  /// If the native file picker delivered bytes (cached in MainActivity via
  /// onActivityResult) pull them here and process them — this is the missing
  /// link that connects the picker result back to the recovery UI.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    _pullPendingFile();
  }

  Future<void> _pullPendingFile() async {
    // Always clear the picker-open guard so the PIN lock works normally
    // from this resume onward even if no file was selected.
    if (_pickerOpen) {
      _pickerOpen = false;
      RelayConnector.externalActivityOpen = false;
    }

    final bytes = await SovFileIntent.getPendingFile();
    if (bytes == null || bytes.isEmpty) return;
    if (!mounted) return;
    // Ensure we are on the seed/file step before processing.
    if (_phase != _Phase.seedEntry) {
      setState(() => _phase = _Phase.seedEntry);
    }
    _processIncomingFile(bytes);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // CAMERA / PALM SCAN — DISABLED: palm recovery removed v1
  // See SOV_PROJECT_MEMORY.md for re-enablement plan
  // ═══════════════════════════════════════════════════════════════════════════

  // DISABLED: palm recovery removed - seed phrase only for v1
  // Future<void> _initCamera() async { ... }
  // void _startScanLoop() { ... }
  // void _stopLoop() { ... }
  // Future<void> _runLoop() async { ... }
  // Future<void> _scanOneFrame() async { ... }
  // Future<void> _triggerCapture() async { ... }
  // void _resetAndRetry() { ... }

  // ═══════════════════════════════════════════════════════════════════════════
  // PATH A — PALM RECOVERY — DISABLED: seed phrase only for v1
  // See SOV_PROJECT_MEMORY.md for re-enablement plan
  // ═══════════════════════════════════════════════════════════════════════════

  // DISABLED: palm recovery removed - seed phrase only for v1
  // Future<void> _recoverViaPalm(List<double> embedding) async { ... }
  // void _onPalmFailed(String handType) { ... }
  // void _startRightPalmScan() { ... }

  // ═══════════════════════════════════════════════════════════════════════════
  // PATH B — SEED PHRASE RECOVERY
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _recoverViaSeed() async {
    final words = _seedCtrl.map((c) => c.text.trim().toLowerCase()).toList();

    if (!Bip39.validateMnemonic(words)) {
      if (mounted) setState(() => _seedError = 'Invalid seed phrase — check your words.');
      return;
    }

    if (mounted) setState(() { _seedError = ''; _phase = _Phase.verifying; _guidance = 'Deriving identity…'; });

    try {
      final sovId = Bip39.mnemonicToSovereignId(words);
      if (sovId.isEmpty) {
        throw Exception('Could not derive Sovereign ID from seed phrase.');
      }

      // Derive Ed25519 signing key from BIP39 entropy:
      //   entropy_bytes = 16-byte BIP39 entropy
      //   ed25519_seed  = sha256(entropy_bytes)   [32 bytes — valid Ed25519 seed]
      // This mirrors the original v1 derivation where masterKeyHash IS sha256(entropy).
      final entropyBytes = Bip39.mnemonicToEntropyBytes(words);
      if (entropyBytes != null) {
        final seedBytes   = sha256.convert(entropyBytes).bytes;
        final seedHex     = seedBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
        await KeyManager.storeRestoredKeys(privateKeyHex: seedHex, sovereignId: sovId);
        debugPrint('[RECOVERY] Ed25519 seed stored for $sovId');
      }

      // Force a fresh connection so HELLO is sent with the restored identity.
      // RelayConnector.connect() is a no-op when already connected (it was
      // connected during boot with the pre-restore AS-YYYY identity).
      if (mounted) setState(() => _guidance = 'Connecting to relay…');
      // Pause auto-reconnect/node-switching so it cannot swap the socket
      // mid-query and drop the in-flight SOV_BALANCE_RESULT. We drive our own
      // connect() retries below; re-enabled before _finaliseRecovery.
      RelayConnector.suppressReconnect = true;
      await RelayConnector.disconnect();

      // ── Resilient connect + balance query ──────────────────────────────────
      // The recovery query otherwise races the relay pool's connect time and
      // RelayConnector's auto-reconnect: connect() can return before the socket
      // is actually up (pool size 0), so a single 10s query intermittently
      // times out. Retry up to 3 times, waiting for isConnected before each
      // attempt and giving HELLO_ACK a moment to land so auto-reconnect doesn't
      // drop the in-flight request.
      Map<String, dynamic>? resp;
      for (int attempt = 1; attempt <= 3 && resp == null; attempt++) {
        if (!RelayConnector.isConnected) {
          await RelayConnector.connect();
          // Wait up to 20s for the connection to come up.
          for (int w = 0; w < 20 && !RelayConnector.isConnected; w++) {
            await Future.delayed(const Duration(seconds: 1));
          }
        }
        if (!RelayConnector.isConnected) continue;
        // Settle so HELLO/HELLO_ACK lands before the query.
        await Future.delayed(const Duration(seconds: 2));
        if (mounted) {
          setState(() => _guidance = attempt == 1
              ? 'Querying network…'
              : 'Querying network… (retry $attempt)');
        }
        resp = await RelayConnector.sendAndWait(
          request: {
            'type':         'SOV_BALANCE_QUERY',
            'sovereign_id': sovId,
          },
          responseType: 'SOV_BALANCE_RESULT',
          timeout: const Duration(seconds: 15),
        );
      }

      int seeds = 0;
      if (resp == null) {
        // Cannot verify enrollment without relay — block to prevent ghost wallets.
        throw Exception(
            'Cannot reach the SOV Network. Please check your internet connection and try again.\n\n'
            'Seed phrase recovery requires a live network connection to verify your enrollment.');
      }

      // sov-node returns success:false + error:'NOT_ENROLLED' for unknown citizens.
      // Old buggy check (seeds == null) failed because sov-node returns seeds:0 (int),
      // which is NOT null, so unenrolled citizens slipped through with 0 balance.
      final notEnrolled = resp['success'] == false ||
          resp['error'] == 'NOT_ENROLLED' ||
          (resp['seeds'] == null && resp['balance_seeds'] == null &&
              resp['balance'] == null);
      if (notEnrolled) {
        throw Exception(
            'Wallet not found on the SOV Network.\n\n'
            'This seed phrase does not match any enrolled citizen. '
            'Check that you entered all 12 words correctly.');
      }

      seeds = (resp['seeds'] as num?)?.toInt()
          ?? (resp['balance_seeds'] as num?)?.toInt()
          ?? (resp['balance'] as num?)?.toInt()
          ?? 0;
      debugPrint('[RECOVERY] Relay confirmed enrolled: seeds=$seeds');

      // Balance confirmed — allow normal reconnect behaviour again for sync.
      RelayConnector.suppressReconnect = false;
      await _finaliseRecovery(sovId, seeds.toDouble());
    } catch (e) {
      RelayConnector.suppressReconnect = false;
      if (mounted) {
        setState(() {
          _phase    = _Phase.failed;
          _errorMsg = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // PATH C — GUARDIAN RECOVERY
  // ═══════════════════════════════════════════════════════════════════════════

  void _startGuardianRecovery() {
    final rng = Random.secure();
    final bytes = List<int>.generate(8, (_) => rng.nextInt(256));
    final sessionId = bytes.map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join().toUpperCase();
    _guardianSessionId = 'RECOVERY-$sessionId';

    setState(() { _phase = _Phase.guardianWait; _guardianApprovals = 0; });

    // Send request to relay
    RelayConnector.send({
      'type':                'GUARDIAN_RECOVERY_REQUEST',
      'recovery_session_id': _guardianSessionId,
    });

    // Listen for approval updates
    _relaySub = RelayConnector.messageStream?.listen((msg) {
      if (msg['type'] == 'GUARDIAN_APPROVAL_UPDATE') {
        final count = (msg['approvals_received'] as num?)?.toInt() ?? 0;
        if (mounted) { setState(() => _guardianApprovals = count); }
        if (count >= 2) {
          _relaySub?.cancel();
          _guardianPollTimer?.cancel();
          // Guardian recovery approved — user needs to set up new palm
          // For now: navigate to enrollment for fresh start
          if (mounted) {
            showDialog<void>(
              context: context,
              barrierDismissible: false,
              builder: (_) => AlertDialog(
                backgroundColor: _cardBg,
                title: const Text('Guardians Approved',
                    style: TextStyle(color: Colors.white)),
                content: const Text(
                  '2 of your guardians have approved recovery.\n\n'
                  'You can now set up a new palm registration.',
                  style: TextStyle(color: Colors.white54, height: 1.5),
                ),
                actions: [
                  ElevatedButton(
                    onPressed: () => Navigator.of(context)
                        ..pop()
                        ..pop(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _gold,
                      foregroundColor: Colors.black,
                    ),
                    child: const Text('Continue'),
                  ),
                ],
              ),
            );
          }
        }
      }
    });

    // Poll every 10 seconds
    _guardianPollTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      RelayConnector.send({
        'type':                'GUARDIAN_RECOVERY_STATUS',
        'recovery_session_id': _guardianSessionId,
      });
    });
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // FINALISE RECOVERY — store in prefs and navigate home
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _finaliseRecovery(String sovId, double seeds) async {
    _recoveredSovId     = sovId;
    _recoveredBalance   = seeds;

    final prefs = await SharedPreferences.getInstance();
    await Future.wait([
      prefs.setString('sovereign_id',       sovId),
      prefs.setBool(  'enrollment_complete', true),
      prefs.setInt(   'enrolled_at',        DateTime.now().millisecondsSinceEpoch),
    ]);
    debugPrint('[RECOVERY] Recovery complete — prefs written');
    await WalletEngine.initialise();   // create wallet row for restored citizen
    await WalletEngine.updateBalance(seeds);

    if (mounted) { setState(() => _phase = _Phase.success); }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MANDATORY PIN SETUP + HOME NAVIGATION
  // Clears any previous-device PIN, forces new PIN setup, then navigates home.
  // Called before every HomeScreen navigation after a successful recovery.
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _enforcePinAndGoHome(
      SharedPreferences prefs, String sovId) async {
    // Clear PIN and palm embedding from the previous device — they are
    // device-local security values and must not carry over to a new install.
    await Future.wait([
      prefs.remove('pin_hash'),
      prefs.remove('palm_embedding'),
    ]);

    if (!mounted) return;

    final pinSet = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => PinSetupScreen(
          title:    'Secure Your Restored Wallet',
          subtitle: 'Set a PIN to protect your wallet on this device.',
          onPinSet: (hash) async => prefs.setString('pin_hash', hash),
        ),
      ),
    );
    if (pinSet != true || !mounted) return;

    // SYNC STEP — show syncing screen, wait for ledger data before home
    setState(() {
      _phase      = _Phase.syncing;
      _syncStatus = 'Connecting to SOV Network…';
    });
    await _runRestoreSync(prefs, sovId);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // RESTORE SYNC — Request ledger data and wait before navigating home.
  // Ensures the restored wallet shows balance + transaction history immediately.
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _runRestoreSync(SharedPreferences prefs, String sovId) async {
    try {
      // Ensure relay connection is alive
      if (!RelayConnector.isConnected) {
        if (mounted) setState(() => _syncStatus = 'Reconnecting to relay…');
        await RelayConnector.connect();
      }

      if (mounted) setState(() => _syncStatus = 'Requesting transaction history…');

      // sendAndWait sends the request AND waits for the matching response type
      final response = await RelayConnector.sendAndWait(
        request:      {'type': 'LEDGER_SYNC_REQUEST', 'sovereign_id': sovId},
        responseType: 'LEDGER_SYNC_RESPONSE',
        timeout:      const Duration(seconds: 12),
      );

      if (response != null) {
        if (mounted) setState(() => _syncStatus = 'Saving transactions…');

        final txs          = response['transactions'] as List? ?? [];
        // Relay sends balance_seeds (raw integer) AND balance (SOV float).
        // WalletEngine and MainShell._seeds operate in SEEDS (1 SOV = 1,000,000 seeds).
        // Always read balance_seeds first; fall back to converting the SOV float.
        final balanceSeeds = (response['balance_seeds'] as num?)?.toInt()
            ?? (((response['balance'] as num?)?.toDouble() ?? 0.0) * 1000000).round();

        if (txs.isNotEmpty) {
          await TransactionStore.mergeAll(txs, sovId);
        }
        if (balanceSeeds > 0) {
          await WalletEngine.updateBalance(balanceSeeds.toDouble());
          await prefs.setInt('cached_balance_seeds', balanceSeeds);
        }

        // Restore palm name from relay — avoids wrong fallback name on fresh install
        // (fresh install has no palm embedding, so PalmNameEngine would derive a
        //  different name than the original biometric-derived one stored on the relay)
        final palmName = (response['palm_name'] as String?) ?? '';
        if (palmName.isNotEmpty) {
          await prefs.setString('palm_name', palmName);
          RelayConnector.invalidatePalmNameCache();
          debugPrint('[RECOVERY SYNC] Palm name restored: $palmName');
        } else {
          // Relay has no stored palm name — try fetching directly via PALM_NAME_QUERY
          try {
            final fetchedName = await RelayConnector.getPalmNameFromRelay(sovId);
            if (fetchedName.isNotEmpty) {
              await prefs.setString('palm_name', fetchedName);
              RelayConnector.invalidatePalmNameCache();
              debugPrint('[RECOVERY SYNC] Palm name fetched via query: $fetchedName');
            }
          } catch (e) {
            debugPrint('[RECOVERY SYNC] Palm name query skipped: $e');
          }
        }

        // Sync recent transaction history from relay (relay keeps tx_retention_days of records)
        if (mounted) setState(() => _syncStatus = 'Syncing history…');
        await RelayConnector.syncTransactionHistory(sovId);

        // ── Security check: warn if account has no balance AND no enrollment on relay ──
        // balance=0 + no palm name = account never enrolled on any active relay.
        // Prevent silent "successful" restore of a wallet that doesn't exist on the network.
        if (balanceSeeds <= 0 && palmName.isEmpty) {
          await prefs.setString('palm_name', '');
          if (mounted) {
            await showDialog(
              context: context,
              barrierDismissible: false,
              builder: (_) => AlertDialog(
                backgroundColor: const Color(0xFF1A1A2E),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                title: const Text('Account Not Found',
                    style: TextStyle(color: Color(0xFFC9A84C), fontWeight: FontWeight.bold)),
                content: Text(
                  'Your seed phrase is valid and your keys have been restored to this device.\n\n'
                  'However, this Sovereign ID ($sovId) has no history on the network — '
                  'it was either never enrolled or was enrolled on a relay that no longer has records.\n\n'
                  'You will need to re-enroll with your palm scan to activate this account.',
                  style: const TextStyle(color: Colors.white70, height: 1.5),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Understood', style: TextStyle(color: Color(0xFFC9A84C))),
                  ),
                ],
              ),
            );
          }
        }

        if (mounted) setState(() => _syncStatus = 'Sync complete!');
        await Future.delayed(const Duration(milliseconds: 600));
      } else {
        // Timeout — go home anyway, MainShell will retry on connect
        if (mounted) setState(() => _syncStatus = 'Relay timeout — proceeding…');
        await Future.delayed(const Duration(milliseconds: 800));
      }
    } catch (e) {
      debugPrint('[RECOVERY SYNC] Error: $e');
      if (mounted) setState(() => _syncStatus = 'Sync skipped — proceeding…');
      await Future.delayed(const Duration(milliseconds: 600));
    }

    if (!mounted) return;
    // Linux: the restored private key is held in memory only until it is
    // PIN-encrypted (there is nowhere safe to write it in the clear). Collect a
    // PIN and persist it now, blocking until it succeeds — otherwise the wallet
    // works for this session but is lost at next launch. No-op elsewhere.
    await ensureKeyPersistedOnLinux(context);
    if (!mounted) return;
    // Recovered citizens skip the onboarding deck, so route them through
    // the shared permissions bundle screen here. On completion, jump to
    // MainShell with the same fade transition the recovery flow has always
    // used. See lib/screens/permissions_bundle_screen.dart.
    Navigator.of(context).pushAndRemoveUntil(
      PageRouteBuilder(
        pageBuilder: (ctx, __, ___) => PermissionsBundleScreen(
          onComplete: () {
            Navigator.of(ctx).pushAndRemoveUntil(
              PageRouteBuilder(
                pageBuilder: (_, __, ___) => const MainShell(),
                transitionsBuilder: (_, anim, __, child) =>
                    FadeTransition(opacity: anim, child: child),
                transitionDuration: const Duration(milliseconds: 500),
              ),
              (route) => false,
            );
          },
        ),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 500),
      ),
      (route) => false,
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // UI HELPERS
  // ═══════════════════════════════════════════════════════════════════════════

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(color: Colors.white)),
      backgroundColor: _cardBg,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 3),
    ));
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // BUILD
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Intercept the system back button.
      // On sub-phases, navigate back within the screen instead of popping.
      canPop: _phase == _Phase.methodSelect,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return; // already handled by Navigator when canPop=true
        // Sub-phase → go back to method select
        if (mounted) {
          setState(() {
            _phase = _Phase.methodSelect;
            _seedRecoveryMode   = null;
            _selectedFileData   = null;
            _showPasswordEntry  = false;
            _decryptPassword    = '';
            _recoveryError      = null;
            _recoveryStatus     = '';
            _recovering         = false;
            _seedError          = '';
          });
        }
      },
      child: Scaffold(
        backgroundColor: _navy,
        body: SafeArea(child: _buildBody()),
      ),
    );
  }

  Widget _buildBody() {
    switch (_phase) {
      case _Phase.methodSelect:  return _buildMethodSelect();
      // DISABLED: palm recovery removed v1 — redirect to method select
      case _Phase.scanning:
      case _Phase.tryRightPalm:  return _buildMethodSelect();
      case _Phase.verifying:     return _buildVerifying(); // used by seed recovery
      case _Phase.seedEntry:     return _buildSeedEntry();
      case _Phase.guardianWait:  return _buildGuardianWait();
      case _Phase.success:       return _buildSuccess();
      case _Phase.syncing:       return _buildSyncing();
      case _Phase.failed:        return _buildFailed();
    }
  }

  // ── A: Method selection ───────────────────────────────────────────────────

  Widget _buildMethodSelect() {
    return Column(
      children: [
        // Back button
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 12, 16, 0),
          child: Row(
            children: [
              // On desktop the Splash REPLACES itself with this screen, so this is the
              // only route on the stack: a plain pop left an empty Navigator (a black
              // window, seen on Windows v1.2.0, 2026-09-22). Show the arrow only when
              // there is actually somewhere to go back to.
              if (Navigator.canPop(context))
                IconButton(
                  icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                  onPressed: () => Navigator.pop(context),
                ),
            ],
          ),
        ),

        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 40),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Recover My Wallet',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 26,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                const Text(
                  'Choose how you want to prove you own this wallet.',
                  style: TextStyle(
                      color: Colors.white54, fontSize: 14, height: 1.5),
                ),
                const SizedBox(height: 32),

                // DISABLED: palm recovery removed - seed phrase only for v1
                // _methodCard(
                //   icon: Icons.fingerprint_rounded,
                //   title: 'Palm Scan Recovery',
                //   ...
                // ),
                _methodCard(
                  icon: Icons.vpn_key_rounded,
                  title: 'Recovery words or backup file',
                  subtitle:
                      'Enter your 12 recovery words, or choose the .sovbak / .sov '
                      'wallet backup file you saved — the file option is on the next screen.',
                  onTap: () {
                    setState(() {
                      _phase = _Phase.seedEntry;
                    });
                  },
                ),
                const SizedBox(height: 14),

                _methodCard(
                  icon: Icons.group_rounded,
                  title: 'Guardian Recovery',
                  subtitle:
                      'Contact 2 of your 3 guardians. They approve your recovery '
                      'request using their wallets. Use as last resort.',
                  badge: 'Last Resort',
                  badgeColor: Colors.orange,
                  onTap: () {
                    _startGuardianRecovery();
                  },
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _methodCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    String? badge,
    Color? badgeColor,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: _cardBg,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white10),
        ),
        child: Row(
          children: [
            Container(
              width: 52, height: 52,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _gold.withAlpha(18),
                border: Border.all(color: _gold.withAlpha(55)),
              ),
              child: Icon(icon, color: _gold, size: 26),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(title,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w600)),
                      ),
                      if (badge != null) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: (badgeColor ?? Colors.greenAccent)
                                .withAlpha(30),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(badge,
                              style: TextStyle(
                                  color: badgeColor ?? Colors.greenAccent,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(subtitle,
                      style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 12,
                          height: 1.4)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right_rounded,
                color: Colors.white24, size: 20),
          ],
        ),
      ),
    );
  }

  // ── B: Palm scan screen — DISABLED: palm recovery removed v1 ────────────
  // DISABLED: palm recovery removed - seed phrase only for v1
  // Widget _buildScanScreen() { ... }
  // Widget _buildTryRightPalm() { ... }
  // Widget _buildCameraPreview() { ... }
  // Widget _buildTorchBtn() { ... }
  // Widget _buildGuidanceBar() { ... }

  // ── Verifying spinner ──────────────────────────────────────────────────────

  Widget _buildVerifying() => Center(
    child: Padding(
      padding: const EdgeInsets.all(40),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Stack(alignment: Alignment.center, children: [
            Container(
              width: 110, height: 110,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: _gold.withAlpha(40), width: 2),
              ),
            ),
            Container(
              width: 84, height: 84,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _cardBg,
                border: Border.all(color: _gold.withAlpha(80), width: 2),
              ),
              child: const Center(
                  child: CircularProgressIndicator(
                      color: Color(0xFFB8960C), strokeWidth: 2.5)),
            ),
          ]),
          const SizedBox(height: 36),
          const Text('Verifying Identity',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Text(_guidance,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: Colors.white54, fontSize: 14, height: 1.5)),
        ],
      ),
    ),
  );

  // ── C: Seed phrase entry ───────────────────────────────────────────────────

  Widget _buildSeedEntry() {
    if (_seedRecoveryMode == 'type') return _buildSeedTypeEntry();
    return _buildSeedMethodSelect();
  }

  // ── Card selection ─────────────────────────────────────────────────────────

  Widget _buildSeedMethodSelect() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 12, 16, 8),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                onPressed: () => setState(() => _phase = _Phase.methodSelect),
              ),
              const Text('Restore Your Wallet',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold)),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 40),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Choose how you backed up your seed phrase',
                  style: TextStyle(color: Colors.white54, fontSize: 14, height: 1.5),
                ),
                const SizedBox(height: 24),

                // ── Method 1: Type seed words ─────────────────────────────
                _recoverMethodCard(
                  icon: Icons.keyboard_rounded,
                  title: 'Type Your Words',
                  description: 'Enter your 12 recovery words manually',
                  onTap: () {
                    if (mounted) setState(() => _seedRecoveryMode = 'type');
                  },
                ),
                const SizedBox(height: 24),

                // ── Method 2: Wallet file ─────────────────────────────────
                const Text(
                  'Or restore from a wallet backup file',
                  style: TextStyle(color: Colors.white54, fontSize: 13),
                ),
                const SizedBox(height: 12),

                // File picker UI and password form are mutually exclusive.
                // Only one is ever visible at a time.
                if (!_showPasswordEntry) ...[

                  // ── File selection UI ───────────────────────────────────
                  const Text(
                    'Select your SOV wallet backup file. '
                    'You will enter your backup password after selecting.',
                    style: TextStyle(
                      color: Colors.white60,
                      fontSize: 13,
                      height: 1.5,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white.withAlpha(13),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      'Note: On some devices the file manager may briefly '
                      'close this app. If that happens just return here '
                      'and try again.',
                      style: TextStyle(
                        color: Colors.white38,
                        fontSize: 12,
                        height: 1.4,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _selectWalletFile,
                      icon: const Icon(Icons.folder_open_rounded,
                          color: Colors.white),
                      label: const Text(
                        'Open Wallet File',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1A3A5C),
                        padding:
                            const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),

                ] else ...[

                  // ── Password entry — shown INSTEAD of file picker ───────
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.white.withAlpha(13),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                          color: const Color(0xFFD4AF37).withAlpha(102)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(children: [
                          Icon(Icons.lock_outline_rounded,
                              color: Color(0xFFD4AF37), size: 18),
                          SizedBox(width: 8),
                          Text(
                            'Enter backup password',
                            style: TextStyle(
                              color: Color(0xFFD4AF37),
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        ]),
                        const SizedBox(height: 8),
                        const Text(
                          'Enter the password you set when '
                          'you saved your wallet backup.',
                          style: TextStyle(
                            color: Colors.white54,
                            fontSize: 13,
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          obscureText: true,
                          autofocus: true,
                          onChanged: (v) => _decryptPassword = v,
                          style: const TextStyle(color: Colors.white),
                          decoration: InputDecoration(
                            labelText: 'Backup password',
                            labelStyle:
                                const TextStyle(color: Colors.white54),
                            prefixIcon: const Icon(
                              Icons.key_rounded,
                              color: Colors.white38,
                              size: 18,
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderSide: const BorderSide(
                                  color: Colors.white24),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderSide: const BorderSide(
                                  color: Color(0xFFD4AF37)),
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed:
                                _recovering ? null : _decryptAndRestore,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFD4AF37),
                              foregroundColor: Colors.black,
                              padding: const EdgeInsets.symmetric(
                                  vertical: 14),
                              shape: RoundedRectangleBorder(
                                  borderRadius:
                                      BorderRadius.circular(10)),
                            ),
                            child: _recovering
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.black))
                                : const Text(
                                    'Restore Wallet',
                                    style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 16),
                                  ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Center(
                          child: TextButton(
                            onPressed: () => setState(() {
                              _showPasswordEntry = false;
                              _selectedFileData  = null;
                              _decryptPassword   = '';
                              _recoveryError     = null;
                            }),
                            child: const Text(
                              'Choose a different file',
                              style: TextStyle(
                                  color: Colors.white38, fontSize: 13),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                ],

                // ── Error display (always visible) ────────────────────────
                if (_recoveryError != null)
                  Container(
                    margin: const EdgeInsets.only(top: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red.withAlpha(25),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.red.withAlpha(102)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.error_outline_rounded,
                            color: Colors.redAccent, size: 16),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _recoveryError!,
                            style: const TextStyle(
                              color: Colors.redAccent,
                              fontSize: 13,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                // ── Status display ────────────────────────────────────────
                if (_recoveryStatus.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Row(children: [
                      const SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Color(0xFFD4AF37)),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _recoveryStatus,
                          style: const TextStyle(
                            color: Colors.white60,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ]),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _recoverMethodCard({
    required IconData icon,
    required String title,
    required String description,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: _cardBg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withAlpha(26)),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _gold.withAlpha(20),
              ),
              child: Icon(icon, color: _gold, size: 22),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(description,
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 13)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded,
                color: Colors.white38, size: 22),
          ],
        ),
      ),
    );
  }

  // ── Type entry ─────────────────────────────────────────────────────────────

  Widget _buildSeedTypeEntry() {
    final allFilled = _seedCtrl.every((c) => c.text.trim().isNotEmpty);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 12, 16, 8),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                onPressed: () =>
                    setState(() => _seedRecoveryMode = null),
              ),
              const Text('Enter Your 12 Words',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold)),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Paste button
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: _pasteAllWords,
                    icon: const Icon(Icons.content_paste_rounded,
                        size: 16, color: Color(0xFFB8960C)),
                    label: const Text('Paste all words',
                        style: TextStyle(
                            color: Color(0xFFB8960C), fontSize: 13)),
                  ),
                ),
                const SizedBox(height: 4),

                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    childAspectRatio: 3.0,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                  ),
                  itemCount: 12,
                  itemBuilder: (_, i) => _seedField(i),
                ),

                if (_seedError.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Text(_seedError,
                      style: const TextStyle(
                          color: Colors.redAccent, fontSize: 13)),
                ],

                const SizedBox(height: 28),
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton(
                    onPressed: allFilled ? _recoverViaSeed : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _gold,
                      disabledBackgroundColor: _gold.withAlpha(60),
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                      elevation: 0,
                    ),
                    child: const Text('Restore Wallet',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _pasteAllWords() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (data?.text == null) return;
      final raw   = data!.text!.trim().toLowerCase();
      final words = raw.split(RegExp(r'[\s,]+'));
      if (words.length < 12) {
        _showSnack('Clipboard does not contain 12 words');
        return;
      }
      for (var i = 0; i < 12; i++) {
        _seedCtrl[i].text = words[i];
      }
      if (mounted) setState(() {});
    } catch (_) {}
  }

  // ── File selection ────────────────────────────────────────────────────────
  // Opens the file picker; reads and validates the JSON. On success sets
  // _selectedFileData and shows the password field. On failure sets
  // _recoveryError. No protection flags — if the process dies, user taps
  // ── Process file delivered via Android "Open With" ────────────────────────
  // Called from initState (after first frame) when fileBytes is non-null.
  // Decodes the bytes as UTF-8, validates the SOV wallet format, and if OK
  // sets _selectedFileData + _showPasswordEntry so the password form appears
  // immediately. The citizen never had to use the file picker at all.

  void _processIncomingFile(Uint8List bytes) {
    // All supported backup formats are plain JSON text (.sov / .sovbak).
    // Decode as UTF-8 — this works for SOVBAK2 (JSON) and legacy .sov files.
    String content;
    try {
      content = utf8.decode(bytes);
    } catch (_) {
      if (mounted) {
        setState(() => _recoveryError =
            'Could not read the file. '
            'Please make sure it is a .sov or .sovbak SOV backup.');
      }
      return;
    }

    Map<String, dynamic> data;
    try {
      data = jsonDecode(content) as Map<String, dynamic>;
    } catch (_) {
      if (mounted) {
        setState(() => _recoveryError =
            'This file is not a valid SOV backup. '
            'Please open a .sov or .sovbak backup file.');
      }
      return;
    }

    // Accepted formats:
    //   A. Unencrypted .sov:   'network' == 'SOV Network v1'
    //   B. Legacy encrypted:   'format'  == 'AES-256-CBC'
    //   C. SOVBAK2 (current):  'format'  == 'SOVBAK2'  (Argon2id + AES-256-GCM)
    final isUnencrypted = data['network'] == 'SOV Network v1';
    final isLegacyEnc   = data['format'] == 'AES-256-CBC' &&
                          data.containsKey('data') &&
                          data.containsKey('salt');
    final isSovbak2     = data['format'] == 'SOVBAK2';

    if (!isUnencrypted && !isLegacyEnc && !isSovbak2) {
      if (mounted) {
        setState(() => _recoveryError =
            'This file is not a valid SOV backup. '
            'Please open a .sov or .sovbak backup file.');
      }
      return;
    }

    if (mounted) {
      setState(() {
        _selectedFileData  = data;
        _showPasswordEntry = true;
        _recoveryError     = null;
        _decryptPassword   = '';
      });
    }
  }

  // Open Wallet File again (explained upfront in the UI).

  Future<void> _selectWalletFile() async {
    setState(() {
      _recoveryError     = null;
      _showPasswordEntry = false;
      _selectedFileData  = null;
    });

    // Desktop (Windows/macOS/Linux): there is no Android intent — use the
    // cross-platform file_picker, read the bytes directly, and feed the SAME
    // processing path (_processIncomingFile → password form → _decryptAndRestore).
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      try {
        final result = await FilePicker.platform.pickFiles(
          withData: true,
          dialogTitle: 'Select your SOV backup file (.sovbak / .sov)',
        );
        if (result != null && result.files.isNotEmpty &&
            result.files.single.bytes != null) {
          _processIncomingFile(result.files.single.bytes!);
        }
      } catch (e) {
        setState(() => _recoveryError = 'Could not open the file picker: $e');
      }
      return;
    }

    // Launch the native Android file picker via Kotlin's startActivityForResult.
    // Unlike the Flutter file_picker plugin, the result is delivered to
    // onActivityResult — a native OS protocol that survives LMK process death.
    //
    // What happens next:
    //   • User selects a file → MainActivity.onActivityResult caches the bytes
    //   • App returns to foreground → didChangeAppLifecycleState(resumed) fires
    //   • _pullPendingFile() calls SovFileIntent.getPendingFile() and passes
    //     the bytes to _processIncomingFile() which shows the password form.
    //
    // externalActivityOpen prevents the session-lock overlay from triggering
    // while the native file picker is in front of the app.
    // We keep it true here and only clear it inside _pullPendingFile() (called
    // when the app resumes), because the await below resolves immediately after
    // firing the Intent — the picker is still open at that point.
    RelayConnector.externalActivityOpen = true;
    _pickerOpen = true;
    try {
      await SovFileIntent.openFilePicker();
    } catch (_) {
      RelayConnector.externalActivityOpen = false;
      _pickerOpen = false;
    }
    // Do NOT clear externalActivityOpen here — it stays true until the app
    // resumes and _pullPendingFile() runs.
  }

  // ── Decrypt and restore ───────────────────────────────────────────────────

  Future<void> _decryptAndRestore() async {
    final fileData    = _selectedFileData;
    // SOVBAK2 (Argon2id + AES-256-GCM, JSON text format) always needs a password.
    final isSovbak2   = fileData != null && fileData['format'] == 'SOVBAK2';
    // Legacy formats: only require password when the JSON says it's encrypted.
    final fileIsEncrypted = fileData != null &&
        (fileData['format'] == 'AES-256-CBC' ||
         fileData['encrypted'] == true);
    if ((isSovbak2 || fileIsEncrypted) && _decryptPassword.isEmpty) {
      setState(() => _recoveryError =
          'Please enter your backup password.');
      return;
    }

    setState(() {
      _recovering     = true;
      _recoveryError  = null;
      _recoveryStatus = 'Decrypting wallet…';
    });

    try {
      String sovId;

      // ── SOVBAK2 path: Argon2id + AES-256-GCM (JSON text format) ─────────────
      if (isSovbak2) {
        final Map<String, dynamic> bundle;
        try {
          final plainBytes = await _decryptSovbak2(fileData, _decryptPassword);
          bundle = jsonDecode(utf8.decode(plainBytes)) as Map<String, dynamic>;
          if ((bundle['version'] as int? ?? 0) != 1) {
            throw const FormatException('Unsupported backup version');
          }
        } catch (e) {
          if (mounted) {
            setState(() {
              _recovering     = false;
              _recoveryStatus = '';
              _recoveryError  = e is sov_crypto.SecretBoxAuthenticationError ||
                  e.toString().toLowerCase().contains('authentication') ||
                  e.toString().toLowerCase().contains('mac')
                  ? 'Incorrect password. Please check your backup password.'
                  : 'Could not open backup: ${e.toString()}';
            });
          }
          return;
        }

        sovId = (bundle['sovereign_id'] as String? ?? '').trim();

        // 1. Restore secure storage keys (private key + public key + nonce etc.)
        //    This stores the real Ed25519 private key so HELLO works correctly.
        const encStorage   = FlutterSecureStorage(
          aOptions: AndroidOptions(encryptedSharedPreferences: true),
        );
        const plainStorage = FlutterSecureStorage(
          aOptions: AndroidOptions(encryptedSharedPreferences: false),
        );
        const skipPrefsOnRestore = {
          '_ext_activity_ts', 'pending_db_restore', 'pending_db_restore_path',
        };
        final keysMap = bundle['keys'] as Map<String, dynamic>? ?? {};
        // On Linux these writes are skipped entirely. flutter_secure_storage
        // there talks to libsecret, which would (a) pop the GNOME Keyring
        // dialog asking for a password SOV never set, and (b) park the
        // plaintext Ed25519 private key in that keyring — the exact two things
        // the Linux key handling was changed to avoid. KeyManager below is the
        // single writer on that platform, and it stores the key only as an
        // Argon2id-encrypted blob once a PIN exists.
        if (!Platform.isLinux) {
          for (final e in keysMap.entries) {
            final v = e.value as String? ?? '';
            if (v.isEmpty) continue;
            // Write to BOTH storages so the key is found regardless of which
            // backend _resolveStorage() picks on next launch (encrypted or plain).
            // A failure on one side is non-fatal — the other side covers it.
            try { await encStorage.write(key: e.key, value: v); } catch (_) {}
            try { await plainStorage.write(key: e.key, value: v); } catch (_) {}
          }
        }

        // Also call KeyManager.storeRestoredKeys so the relay_connector
        // SharedPrefs path has node_id set correctly.
        final privHex = keysMap['sov_private_key_v2'] as String? ?? '';
        if (privHex.isNotEmpty && sovId.isNotEmpty) {
          try {
            await KeyManager.storeRestoredKeys(
                privateKeyHex: privHex, sovereignId: sovId);
            debugPrint('[RECOVERY] SOVBAK2: keys stored for $sovId');
          } catch (e) {
            debugPrint('[RECOVERY] SOVBAK2: key store warning: $e');
          }
        }

        // 2. Restore SharedPreferences
        final prefs    = await SharedPreferences.getInstance();
        final prefsMap = bundle['prefs'] as Map<String, dynamic>? ?? {};
        for (final e in prefsMap.entries) {
          if (skipPrefsOnRestore.contains(e.key)) continue;
          try {
            final v = e.value;
            if (v is bool)        { await prefs.setBool(e.key, v); }
            else if (v is int)    { await prefs.setInt(e.key, v); }
            else if (v is double) { await prefs.setDouble(e.key, v); }
            else if (v is String) { await prefs.setString(e.key, v); }
            else if (v is List)   { await prefs.setStringList(
                e.key, v.map((x) => x.toString()).toList()); }
          } catch (_) {/* skip incompatible key */}
        }

        // 3. Restore contacts.db binary
        final dbB64 = bundle['contacts_db_b64'] as String? ?? '';
        if (dbB64.isNotEmpty) {
          try {
            await ContactsDb.closeDb();
            final dbDir  = await sovDatabasesDir();
            final dbFile = File('$dbDir/sov_contacts.db');
            await dbFile.writeAsBytes(base64.decode(dbB64), flush: true);
            debugPrint('[RECOVERY] SOVBAK2: contacts.db restored');
          } catch (e) {
            debugPrint('[RECOVERY] SOVBAK2: contacts.db restore warning: $e');
          }
        }

      // ── Legacy JSON path: AES-256-CBC or unencrypted ─────────────────────────
      } else {
        final data = _selectedFileData!;

        // Detect encrypted format: settings_screen exports use format:'AES-256-CBC'
        final isEncrypted = data['format'] == 'AES-256-CBC' ||
                            data['encrypted'] == true;
        if (isEncrypted) {
          Map<String, dynamic> decrypted;
          try {
            decrypted = _decryptWalletFile(data, _decryptPassword);
          } catch (_) {
            if (mounted) {
              setState(() {
                _recovering     = false;
                _recoveryStatus = '';
                _recoveryError  =
                    'Incorrect password. Please check your '
                    'backup password and try again.';
              });
            }
            return;
          }
          sovId = (decrypted['sovereign_id'] as String? ?? '').trim();

          // ── CRITICAL: derive + store Ed25519 keys BEFORE connecting ──────────
          final seedPhraseRaw = (decrypted['seed_phrase'] as String? ?? '').trim();
          if (seedPhraseRaw.isNotEmpty && sovId.isNotEmpty) {
            try {
              final words = seedPhraseRaw.split(' ')
                  .where((w) => w.isNotEmpty)
                  .toList();
              if (Bip39.validateMnemonic(words)) {
                final entropyBytes = Bip39.mnemonicToEntropyBytes(words);
                if (entropyBytes != null) {
                  final seedBytes = sha256.convert(entropyBytes).bytes;
                  final seedHex   = seedBytes
                      .map((b) => b.toRadixString(16).padLeft(2, '0'))
                      .join();
                  await KeyManager.storeRestoredKeys(
                      privateKeyHex: seedHex, sovereignId: sovId);
                  debugPrint('[RECOVERY] Keys stored from backup seed phrase for $sovId');
                }
              }
            } catch (e) {
              debugPrint('[RECOVERY] Key derivation from backup failed: $e');
            }
          }

          // Restore contacts if present in the backup
          if (decrypted['contacts'] != null) {
            try {
              await ContactsDb.importAll({'contacts': decrypted['contacts']});
            } catch (_) {/* non-fatal */}
          }
        } else {
          sovId = (data['sovereign_id'] as String? ?? '').trim();
        }
      }

      if (sovId.isEmpty) {
        if (mounted) {
          setState(() {
            _recovering    = false;
            _recoveryStatus = '';
            _recoveryError  =
                'Wallet file is missing identity data. '
                'Please try your seed phrase instead.';
          });
        }
        return;
      }

      if (mounted) setState(() => _recoveryStatus = 'Connecting to SOV Network…');

      // Force a fresh connection so HELLO is sent with the restored identity.
      // RelayConnector.connect() is a no-op when already connected (it was
      // connected during SOVNode.boot() with the pre-restore AS-YYYY identity).
      // Disconnecting first ensures the new HELLO uses sovereign_id from SharedPrefs
      // which was just updated with the correct SOV-XXXXXXXX from the bundle.
      await RelayConnector.disconnect();
      final connected = await RelayConnector.connect();

      if (!connected) {
        // Offline restore — write prefs, enforce PIN, then go home
        debugPrint('[RECOVERY] Relay offline — restoring locally');
        final prefs = await SharedPreferences.getInstance();
        await Future.wait([
          prefs.setBool(  'enrollment_complete', true),
          prefs.setString('sovereign_id',        sovId),
          prefs.setInt(   'enrolled_at',         DateTime.now().millisecondsSinceEpoch),
        ]);
        await WalletEngine.updateBalance(0);
        await _enforcePinAndGoHome(prefs, sovId);
        return;
      }

      if (mounted) setState(() => _recoveryStatus = 'Verifying identity on SOV Network…');

      // Query relay for current balance.
      // If the relay is reachable and explicitly returns NOT_ENROLLED, block —
      // the citizen must use seed phrase recovery to re-enroll.
      // If the relay is unreachable (null response), proceed offline with seeds=0.
      int seeds = 0;
      final response = await RelayConnector.sendAndWait(
        request: {
          'type':         'SOV_BALANCE_QUERY',
          'sovereign_id': sovId,
        },
        responseType: 'SOV_BALANCE_RESULT',
        timeout: const Duration(seconds: 10),
      );
      if (response == null) {
        // Relay timed out — treat as offline, proceed with seeds=0
        debugPrint('[RECOVERY] File recovery — relay query timed out; proceeding offline');
      } else if (response['success'] == true) {
        seeds = (response['seeds'] as num?)?.toInt()
            ?? (response['balance_seeds'] as num?)?.toInt()
            ?? (response['balance'] as num?)?.toInt()
            ?? 0;
        debugPrint('[RECOVERY] File recovery — relay confirmed: $seeds seeds');
      } else {
        // Relay reachable but does not yet know this citizen.
        // This is expected after a relay wipe or when restoring to a relay
        // that has not yet replicated this citizen's enrollment record.
        // Per V2 Tier 2 blueprint: "Phone cache is a view — can be wiped
        // and rebuilt from relay at any time." Balance is display-only.
        // Proceed with seeds=0 — balance syncs once the relay recognises the citizen.
        debugPrint('[RECOVERY] File recovery — relay returned NOT_ENROLLED for $sovId — proceeding with seeds=0');
      }

      final prefs = await SharedPreferences.getInstance();
      await Future.wait([
        prefs.setBool(  'enrollment_complete',  true),
        prefs.setString('sovereign_id',         sovId),
        prefs.setInt(   'enrolled_at',          DateTime.now().millisecondsSinceEpoch),
        if (seeds > 0)
          prefs.setInt( 'cached_balance_seeds', seeds),
      ]);
      // Initialise wallet row first so updateBalance's UPDATE has a target.
      await WalletEngine.initialise();
      await WalletEngine.updateBalance(seeds.toDouble());

      // Mandatory PIN setup before home screen.
      // Balance will be refreshed automatically via _refreshBalance() in
      // MainShell.initState() once the relay recognises the citizen.
      await _enforcePinAndGoHome(prefs, sovId);
    } catch (_) {
      if (mounted) {
        setState(() {
          _recovering     = false;
          _recoveryStatus = '';
          _recoveryError  =
              'Recovery failed. Please try your seed phrase instead.';
        });
      }
    }
  }

  // ── SOVBAK2 Argon2id + AES-256-GCM decryption ────────────────────────────
  // Matches backup_restore_screen.dart's _decrypt() exactly.
  // Format: JSON envelope with fields: format, kdf, p, m, t, salt, nonce, data
  //   - kdf: 'argon2id'
  //   - p/m/t: Argon2id parallelism/memory/iterations (read from envelope)
  //   - salt: base64-encoded 16-byte salt
  //   - nonce: base64-encoded 12-byte nonce
  //   - data: base64-encoded ciphertext + 16-byte GCM tag
  // Throws sov_crypto.SecretBoxAuthenticationError on wrong password.
  // Throws FormatException on corrupt / wrong file type.

  static Future<Uint8List> _decryptSovbak2(
      Map<String, dynamic> env, String password) async {
    final salt    = base64.decode(env['salt']  as String? ?? '');
    final nonce   = base64.decode(env['nonce'] as String? ?? '');
    final rawData = base64.decode(env['data']  as String? ?? '');
    if (salt.isEmpty || nonce.isEmpty || rawData.length < 16) {
      throw const FormatException('Corrupt SOVBAK2 backup data');
    }
    final cipherText = rawData.sublist(0, rawData.length - 16);
    final macBytes   = rawData.sublist(rawData.length - 16);
    // Read KDF parameters stored in the envelope — allows future upgrades
    final p = env['p'] as int? ?? 1;
    final m = env['m'] as int? ?? 65536;
    final t = env['t'] as int? ?? 3;

    final key = await sov_crypto.Argon2id(
      parallelism: p,
      memory:      m,
      iterations:  t,
      hashLength:  32,
    ).deriveKey(
      secretKey: sov_crypto.SecretKey(utf8.encode(password)),
      nonce:     salt,
    );

    final decrypted = await sov_crypto.AesGcm.with256bits().decrypt(
      sov_crypto.SecretBox(cipherText,
          nonce: nonce, mac: sov_crypto.Mac(macBytes)),
      secretKey: key,
    );
    return Uint8List.fromList(decrypted);
  }

  // ── Synchronous AES-256-CBC wallet file decryption ────────────────────────
  // Accepts the outer file JSON map and password.
  // Returns the decrypted inner JSON map.
  // Throws Exception on wrong password or corrupt data.

  Map<String, dynamic> _decryptWalletFile(
      Map<String, dynamic> data, String password) {
    final saltHex = data['salt'] as String? ?? '';
    final dataB64 = data['data'] as String? ?? '';

    if (saltHex.isEmpty || dataB64.isEmpty) {
      throw Exception('Missing salt or data fields');
    }

    final keyBytes = sha256.convert(utf8.encode(password + saltHex)).bytes;
    final key      = enc.Key(Uint8List.fromList(keyBytes));

    enc.IV iv;
    enc.Encrypted cipherBytes;

    // Settings export stores IV in a separate 'iv' base64 field.
    // Legacy format (if ever used) prepends 16 IV bytes to the cipher blob.
    final ivB64 = data['iv'] as String?;
    if (ivB64 != null && ivB64.isNotEmpty) {
      iv          = enc.IV(base64.decode(ivB64));
      cipherBytes = enc.Encrypted(base64.decode(dataB64));
    } else {
      final allBytes = base64.decode(dataB64);
      iv          = enc.IV(Uint8List.fromList(allBytes.sublist(0, 16)));
      cipherBytes = enc.Encrypted(Uint8List.fromList(allBytes.sublist(16)));
    }

    final plaintext = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc))
        .decrypt(cipherBytes, iv: iv);

    try {
      return jsonDecode(plaintext) as Map<String, dynamic>;
    } catch (_) {
      throw Exception('Incorrect password');
    }
  }

  Widget _seedField(int i) => TextField(
    key: ValueKey('seed_word_$i'), // Added for flutter_driver integration testing
    controller: _seedCtrl[i],
    onChanged: (_) => setState(() {}),
    style: const TextStyle(color: Colors.white, fontSize: 13),
    decoration: InputDecoration(
      prefixText: '${i + 1}. ',
      prefixStyle: const TextStyle(color: Colors.white38, fontSize: 12),
      hintText: 'word',
      hintStyle: TextStyle(color: Colors.white.withAlpha(51), fontSize: 12),
      filled: true,
      fillColor: _cardBg,
      isDense: true,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: Colors.white.withAlpha(26))),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: Colors.white.withAlpha(26))),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFFB8960C))),
    ),
    textInputAction:
        i < 11 ? TextInputAction.next : TextInputAction.done,
  );

  // ── D: Guardian wait ────────────────────────────────────────────────────────

  Widget _buildGuardianWait() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 32),
          Container(
            width: 80, height: 80,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _gold.withAlpha(18),
              border: Border.all(color: _gold.withAlpha(60)),
            ),
            child: const Icon(Icons.group_rounded, color: Color(0xFFB8960C),
                size: 40),
          ),
          const SizedBox(height: 24),
          const Text('Guardian Recovery',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          const Text(
            'Share this Recovery Code with 2 of your 3 guardians. '
            'Ask them to approve your recovery request from their app.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54, fontSize: 14, height: 1.5),
          ),
          const SizedBox(height: 28),

          // Session ID display
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: _cardBg,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _gold.withAlpha(60)),
            ),
            child: Column(
              children: [
                const Text('YOUR RECOVERY CODE',
                    style: TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
                        letterSpacing: 1.5)),
                const SizedBox(height: 12),
                Text(
                  _guardianSessionId,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFFB8960C),
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace',
                    letterSpacing: 2,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),

          // Approval progress
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(3, (i) {
              final approved = i < _guardianApprovals;
              return Container(
                margin: const EdgeInsets.symmetric(horizontal: 8),
                width: 52, height: 52,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: approved
                      ? Colors.greenAccent.withAlpha(25)
                      : _cardBg,
                  border: Border.all(
                    color: approved
                        ? Colors.greenAccent
                        : Colors.white24,
                    width: 2,
                  ),
                ),
                child: Center(
                  child: approved
                      ? const Icon(Icons.check_rounded,
                          color: Colors.greenAccent, size: 22)
                      : Text('G${i + 1}',
                          style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 13,
                              fontWeight: FontWeight.bold)),
                ),
              );
            }),
          ),
          const SizedBox(height: 12),
          Text(
            '$_guardianApprovals of 2 approvals received',
            style: TextStyle(
                color: _guardianApprovals >= 2
                    ? Colors.greenAccent
                    : Colors.white38,
                fontSize: 13),
          ),
          const SizedBox(height: 8),
          const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 16, height: 16,
                child: CircularProgressIndicator(
                    strokeWidth: 1.5, color: Color(0xFFB8960C)),
              ),
              SizedBox(width: 8),
              Text('Waiting for approvals...',
                  style: TextStyle(color: Colors.white38, fontSize: 12)),
            ],
          ),
          const SizedBox(height: 40),
          TextButton(
            onPressed: () {
              _guardianPollTimer?.cancel();
              _relaySub?.cancel();
              setState(() => _phase = _Phase.methodSelect);
            },
            child: const Text('Back to recovery options',
                style: TextStyle(color: Colors.white24, fontSize: 13)),
          ),
        ],
      ),
    );
  }

  // ── Success ────────────────────────────────────────────────────────────────

  Widget _buildSuccess() {
    final sov   = (_recoveredBalance / 1000000).toStringAsFixed(2);
    final seeds = _recoveredBalance.toStringAsFixed(0);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 48, 28, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 100, height: 100,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                colors: [Color(0xFFB8960C), Color(0xFFD4AF37)],
              ),
              boxShadow: [
                BoxShadow(
                    color: const Color(0xFFB8960C).withAlpha(80),
                    blurRadius: 30, spreadRadius: 4),
              ],
            ),
            child: const Icon(Icons.check_rounded,
                color: Colors.white, size: 52),
          ),
          const SizedBox(height: 24),
          const Text('Wallet Restored!',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text('Your Sovereign identity has been recovered.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: Colors.white54, fontSize: 13, height: 1.5)),
          const SizedBox(height: 32),

          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 20),
            decoration: BoxDecoration(
              color: _gold.withAlpha(18),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: _gold.withAlpha(60)),
            ),
            child: Column(
              children: [
                Text('$sov SOV',
                    style: const TextStyle(
                        color: Color(0xFFB8960C),
                        fontSize: 48,
                        fontWeight: FontWeight.bold)),
                Text('$seeds Seeds',
                    style: const TextStyle(
                        color: Colors.white38, fontSize: 13)),
              ],
            ),
          ),
          const SizedBox(height: 20),

          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _cardBg,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('SOVEREIGN ID',
                    style: TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
                        letterSpacing: 1)),
                const SizedBox(height: 6),
                Text(_recoveredSovId,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontFamily: 'monospace')),
              ],
            ),
          ),
          const SizedBox(height: 36),

          SizedBox(
            width: double.infinity, height: 54,
            child: ElevatedButton(
              onPressed: () async {
                final prefs = await SharedPreferences.getInstance();
                await _enforcePinAndGoHome(prefs, _recoveredSovId);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: _gold,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
                elevation: 0,
              ),
              child: const Text('Go to My Wallet',
                  style: TextStyle(
                      fontSize: 17, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }

  // ── Syncing — shown between PIN setup and home screen ─────────────────────

  Widget _buildSyncing() => Center(
    child: Padding(
      padding: const EdgeInsets.all(40),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 72, height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _gold.withAlpha(20),
              border: Border.all(color: _gold.withAlpha(80), width: 2),
            ),
            child: const Icon(Icons.sync_rounded, color: _gold, size: 36),
          ),
          const SizedBox(height: 32),
          const Text(
            'Synchronising Your Wallet',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            _syncStatus,
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white.withAlpha(160), fontSize: 14, height: 1.5),
          ),
          const SizedBox(height: 36),
          const SizedBox(
            width: 36, height: 36,
            child: CircularProgressIndicator(
              color: Color(0xFFB8960C), strokeWidth: 2.5,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Please wait — fetching your balance\nand recent transaction history from the network.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white.withAlpha(80), fontSize: 12, height: 1.5),
          ),
        ],
      ),
    ),
  );

  // ── Failed ─────────────────────────────────────────────────────────────────

  Widget _buildFailed() => SingleChildScrollView(
    padding: const EdgeInsets.all(32),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const SizedBox(height: 32),
        Container(
          width: 80, height: 80,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.red.withAlpha(20),
            border: Border.all(color: Colors.red.withAlpha(80)),
          ),
          child: const Icon(Icons.error_outline_rounded,
              color: Colors.red, size: 40),
        ),
        const SizedBox(height: 24),
        const Text('Recovery Failed',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        Text(
          _errorMsg.isNotEmpty
              ? _errorMsg
              : 'Neither palm was recognised. This may be due to '
                'lighting changes or updates since enrollment.',
          textAlign: TextAlign.center,
          style: const TextStyle(
              color: Colors.white54, fontSize: 14, height: 1.5),
        ),
        const SizedBox(height: 32),
        // Option 1: Try seed phrase
        SizedBox(
          width: double.infinity, height: 52,
          child: ElevatedButton.icon(
            onPressed: () {
              setState(() {
                _errorMsg = '';
                _phase    = _Phase.seedEntry;
              });
            },
            icon: const Icon(Icons.vpn_key_rounded, size: 20),
            label: const Text('Try Seed Phrase',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            style: ElevatedButton.styleFrom(
              backgroundColor: _gold,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
              elevation: 0,
            ),
          ),
        ),
        const SizedBox(height: 12),
        // Option 2: Back to method select
        SizedBox(
          width: double.infinity, height: 48,
          child: OutlinedButton.icon(
            onPressed: () {
              setState(() {
                _errorMsg = '';
                _phase    = _Phase.methodSelect;
              });
            },
            icon: const Icon(Icons.arrow_back_rounded, size: 18),
            label: const Text('Back to Options'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white70,
              side: const BorderSide(color: Colors.white24),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
          ),
        ),
        const SizedBox(height: 12),
        // Option 3: Guardian
        SizedBox(
          width: double.infinity, height: 48,
          child: OutlinedButton.icon(
            onPressed: () {
              // DISABLED: palm vars removed — no camera to stop
              setState(() => _errorMsg = '');
              _startGuardianRecovery();
            },
            icon: const Icon(Icons.group_outlined, size: 18),
            label: const Text('Contact Guardians'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white38,
              side: const BorderSide(color: Colors.white12),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
          ),
        ),
      ],
    ),
  );
}

// ═════════════════════════════════════════════════════════════════════════════
// SMART RETICLE PAINTER — DISABLED: palm recovery removed v1
// Kept for reference. Re-enable with palm scan when FIX is complete.
// ═════════════════════════════════════════════════════════════════════════════
class SmartReticlePainter extends CustomPainter {
  final Rect? boxNorm;
  final bool detected;
  final bool correctHand;
  final double pulseValue;

  const SmartReticlePainter({
    required this.boxNorm,
    required this.detected,
    required this.correctHand,
    required this.pulseValue,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (!detected || boxNorm == null) {
      final borderPaint = Paint()
        ..color = Colors.white.withValues(alpha: 0.15 + pulseValue * 0.1)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;
      canvas.drawRect(
        Rect.fromLTWH(8, 8, size.width - 16, size.height - 16),
        borderPaint,
      );
      return;
    }
    final left   = boxNorm!.left   * size.width;
    final top    = boxNorm!.top    * size.height;
    final right  = boxNorm!.right  * size.width;
    final bottom = boxNorm!.bottom * size.height;
    final w = right - left;
    final h = bottom - top;
    final color = correctHand ? Colors.greenAccent : Colors.redAccent;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5.0
      ..strokeCap = StrokeCap.round;
    final armW = w * 0.22;
    final armH = h * 0.22;
    canvas.drawLine(Offset(left, top + armH), Offset(left, top), paint);
    canvas.drawLine(Offset(left, top), Offset(left + armW, top), paint);
    canvas.drawLine(Offset(right - armW, top), Offset(right, top), paint);
    canvas.drawLine(Offset(right, top), Offset(right, top + armH), paint);
    canvas.drawLine(Offset(left, bottom - armH), Offset(left, bottom), paint);
    canvas.drawLine(Offset(left, bottom), Offset(left + armW, bottom), paint);
    canvas.drawLine(Offset(right - armW, bottom), Offset(right, bottom), paint);
    canvas.drawLine(Offset(right, bottom), Offset(right, bottom - armH), paint);
    if (!correctHand) {
      final textPainter = TextPainter(
        text: const TextSpan(text: 'WRONG HAND',
          style: TextStyle(color: Colors.redAccent, fontSize: 14,
            fontWeight: FontWeight.bold, letterSpacing: 2)),
        textDirection: TextDirection.ltr,
      )..layout();
      textPainter.paint(canvas, Offset(left + (w - textPainter.width) / 2, top - 24));
    }
    if (correctHand) {
      final textPainter = TextPainter(
        text: const TextSpan(text: 'HOLD STEADY',
          style: TextStyle(color: Colors.greenAccent, fontSize: 14,
            fontWeight: FontWeight.bold, letterSpacing: 2)),
        textDirection: TextDirection.ltr,
      )..layout();
      textPainter.paint(canvas, Offset(left + (w - textPainter.width) / 2, bottom + 8));
    }
  }

  @override
  bool shouldRepaint(SmartReticlePainter old) =>
    old.boxNorm != boxNorm || old.detected != detected ||
    old.correctHand != correctHand || old.pulseValue != pulseValue;
}

