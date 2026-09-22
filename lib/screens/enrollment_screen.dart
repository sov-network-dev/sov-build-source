// lib/screens/enrollment_screen.dart
// ─────────────────────────────────────────────────────────────────────────────
// ENROLLMENT SCREEN
//
// FLOW:
//   Part A — Onboarding       (3 swipeable slides, Skip top-right)
//   Part B — Left Palm Scan   (REAR cam, ResolutionPreset.low — exact params
//                              preserved from palm_hash_test_screen.dart)
//   Part C — Seed Phrase      (12-word BIP39, tap-each-word confirmation)
//   Part D — Right Palm Scan  (same pipeline, same master key)
//   Part E — Face Liveness    (random blink/turn challenge, 10-s window)
//   Part F — PIN Setup        (6-digit, SHA-256 stored)
//   Part G — Registering      (relay calls)
//   Part H — Success          (show SOV + Seeds)
//
// ARCHITECTURE:
//   Camera parameters preserved EXACTLY from palm_hash_test_screen.dart.
//   Visual feedback improved (10 % progress decay vs 30 %; smoother ring).
//   Only disc writes changed — relay stores Seeds; app displays SOV.
// ─────────────────────────────────────────────────────────────────────────────
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random, sqrt;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;
import '../sov_node_sdk/palm_image_engine.dart';
import '../sov_node_sdk/palm_embedder.dart';
import '../sov_node_sdk/pin_manager.dart';
import '../sov_node_sdk/fuzzy_commitment.dart';
import '../sov_node_sdk/palm_local_store.dart';
import '../sov_node_sdk/relay_connector.dart';
import '../sov_node_sdk/transaction_store.dart';
import '../sov_node_sdk/key_manager.dart';
import '../widgets/linux_pin_setup.dart';
import '../sov_node_sdk/sov_checkpoint.dart';
import '../sov_node_sdk/wallet_engine.dart';
import '../sov_node_sdk/bip39.dart';
import '../sov_node_sdk/sov_id_v2.dart';
import '../sov_node_sdk/palm_name_engine.dart';
import 'main_shell.dart';
import 'recovery_screen.dart';
import 'liveness_screen.dart';
import 'pin_setup_screen.dart';

// ── Step enum ─────────────────────────────────────────────────────────────────
// v1 flow: onboarding → liveness → scanLeft → pinSetup → seedPhrase → registering → success
// DISABLED: handSelection removed — left palm only until right-hand model is retrained.
enum _EnrollStep {
  onboarding,
  // handSelection, // DISABLED: right palm requires retraining YOLOv8 model
  liveness,      // Step 1: prove you're human first
  scanLeft,      // Step 2: register biometric
  scanRight,     // DISABLED: single-palm architecture v1
  pinSetup,      // Step 3: secure the app
  seedPhrase,    // Step 4: backup (final step)
  registering,
  success,
  failed,
}

enum _HandType { left, right, unknown }

// ═══════════════════════════════════════════════════════════════════════════════
class EnrollmentScreen extends StatefulWidget {
  const EnrollmentScreen({super.key});

  @override
  State<EnrollmentScreen> createState() => _EnrollmentScreenState();
}

class _EnrollmentScreenState extends State<EnrollmentScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {

  // ── Brand colours ────────────────────────────────────────────────────────────
  static const _navy   = Color(0xFF0A1628);
  static const _gold   = Color(0xFFB8960C);
  static const _teal   = Color(0xFF006B5E);
  static const _cardBg = Color(0xFF0D1F3A);

  // ── Step ─────────────────────────────────────────────────────────────────────
  _EnrollStep _step      = _EnrollStep.onboarding;
  // LEFT is always the default. Citizens who cannot use their left hand
  // double-tap the scan frame to flip the SAME single scan to RIGHT (and
  // back). Permanent accessibility feature (king directive 2026-07-16) —
  // no governance gate. Only ONE palm is ever enrolled per citizen.
  String      _enrollHand = 'LEFT';

  // FACE-LOCK: 192-d face embedding captured by the liveness step. Sent with
  // PALM_EMBEDDING_REGISTER so the node can enforce one HUMAN = one identity
  // across BOTH hands (palm dedup can't link left palm to right palm).
  List<double>? _faceEmbedding;

  // ── Camera (parameters identical to palm_hash_test_screen.dart) ──────────────
  CameraController? _cam;
  bool _torchOn = false;


  // ── Scan loop (mirrors palm_hash_test_screen.dart exactly) ───────────────────
  bool _loopRunning = false;
  bool _scanBusy    = false;
  bool _captured    = false;

  // ── Smooth-scan (live preview stream) state ──────────────────────────────────
  // Detection runs off the camera preview STREAM (smooth, no per-frame takePicture
  // stall). The heavy model is THROTTLED (a few fps, not 30) so it never overheats
  // like the old every-frame stream did. If the stream can't start OR stalls, we
  // auto-fall back to the proven takePicture loop — so it's never worse than today.
  bool   _usingStream        = false;
  int    _lastStreamDetectMs = 0;
  int    _sensorOrientation  = 90;
  Timer? _streamWatchdog;
  String _guidance  = '';

  // ── Palm-scan diagnostic (king, 2026-07-21) ─────────────────────────────────
  // When true, the guidance bar shows the RAW per-frame detector confidence so an
  // on-device test reports a hard number ("sees 0.42") instead of "feels dead".
  // The engine floor is dropped to 0.05 so even weak detections surface here; the
  // actual lock-on still requires >= 0.35. Set false for the polished launch build.
  static const bool _kPalmDebug = false;
  String _lastConf = '';

  _HandType _detectedHand  = _HandType.unknown;
  double    _handAngleRad  = 0;
  double    _alignProgress = 0.0;
  int       _goodFrames    = 0;

  // HANDEDNESS IS ADVISORY ONLY (king, 2026-08-15). It must NEVER block or reset
  // the lock. History: the wrong-hand veto was first set to block after 3 frames,
  // which never fired (capture beat it), then dropped to 1 frame to make it fire —
  // and that 1-frame block is what broke LEFT-palm enrolment. The model's left/
  // right head is orientation-sensitive and FLICKERS on the SAME palm as it tilts:
  // a left palm reads "left" on most frames but "right" on the odd tilted frame.
  // With a 1-frame block that single frame zeroed alignProgress AND _goodFrames, so
  // the left palm flashed green ("locking on"), then vanished on the smallest
  // movement and never locked — while a right palm, which happened to read stably,
  // locked at once (king, live 2026-08-15). Decisive point: the user's hand is not
  // in doubt — they pick it by double-tap, and THAT choice (not the model's guess)
  // is what gets bound into the template (FuzzyCommitment.applyChiralityBinding)
  // and sent to the node (hand_type). So the model's classification can only ever
  // NUDGE, after a SUSTAINED run of mismatched frames that a genuinely wrong hand
  // produces but a flicker never does; it does not gate capture.
  int _wrongHandStreak = 0;
  static const int _kWrongHandFramesToHint = 4;

  // Soft advisory for the low-margin case. `handednessReliable` is false whenever
  // the detection came from a ROTATED pass (fromUpright == false) — most handheld
  // frames, since V28 is orientation-sensitive and we retry 4 rotations. Kept as a
  // SECOND non-blocking hint path so the user is told what the model thinks it sees
  // and how to switch, instead of staring at a dead progress bar.
  int _leansWrongStreak = 0;
  static const int _kLeansWrongFramesToHint = 4;

  // Stall detector — catches EVERY silent-stall cause, not just handedness
  // (bad light, palm too small/large, camera focus). If a palm is on screen but
  // nothing has locked for this long, say something actionable. Reuses the
  // existing _loopStartTime rather than adding a second clock.
  static const Duration _kStallHintAfter = Duration(seconds: 9);

  // DWELL-BASED LOCK (king, 2026-08-15 — "palm feels dead, flashes green then
  // never locks", vs the smooth ML-Kit face scan). The old bar was score >= 0.50
  // for 2 consecutive frames, where score = conf * 0.85 whenever the phone was
  // moving — so a HANDHELD scan actually needed conf >= 0.59, while the green
  // "locking on" gate was only 0.35. A palm reading 0.35–0.59 (the common real-
  // world range; validated on the king's own palms: model detects 78%, mostly
  // mid-confidence) flashed green forever and NEVER accumulated a lock. Replaced
  // with a dwell accumulator that ignores the handheld penalty and tolerates dips:
  //   conf >= _kLockConfFloor  -> build dwell (+ buffer the frame)
  //   0.35 <= conf < floor     -> hold (present but weak; neither build nor lose)
  //   conf < 0.35 (no palm)    -> decay dwell by one (not a hard reset)
  // Lock when dwell reaches _kDwellToLock. Validated against the 54 real palm
  // photos (scripts gate_ab): locks 21/21 detectable palms, 0 false-locks on
  // undetectable ones. Template quality is still enforced AFTER the lock by the
  // 3-shot capture burst + processBurst (creasePixels >= 30), so a slightly lower
  // lock floor cannot degrade the stored template.
  static const double _kLockConfFloor = 0.40;
  static const int    _kDwellToLock   = 3;

  // PRESERVED: max 3 low-res frames rolling buffer
  final List<Uint8List> _goodFrameBuffer = [];

  // ── Accelerometer stability (threshold from palm_hash_test_screen line 159) ───
  StreamSubscription? _accelSub;
  bool _isStable = false;

  // ── Biometric data ───────────────────────────────────────────────────────────
  List<double>?     _leftEmb;
  EnrollmentResult? _leftEnroll;
  // DISABLED: multi-quantization removed for performance (FIX 4)
  // EnrollmentResult? _leftEnroll2;  // 30th-percentile quantization
  // EnrollmentResult? _leftEnroll3;  // 70th-percentile quantization
  // DISABLED: single-palm architecture v1
  // Right palm re-enrollment available via recovery flow
  // List<double>?     _rightEmb;
  // EnrollmentResult? _rightEnroll;
  // EnrollmentResult? _rightEnroll2;
  // EnrollmentResult? _rightEnroll3;

  // ── Seed phrase ──────────────────────────────────────────────────────────────
  List<String> _seedWords   = [];

  // ── Backup tracking ──────────────────────────────────────────────────────────
  bool _backupWroteDown = false;

  // ── Backup password form (inline, on success screen) ─────────────────────────
  bool    _showBackupPasswordForm = false;
  String  _backupPasswordError    = '';
  bool    _backupPasswordSaving   = false;
  final TextEditingController _backupPwdCtrl1 = TextEditingController();
  final TextEditingController _backupPwdCtrl2 = TextEditingController();


  // ── Connection status (shown during ENROLLMENT_REGISTER / PALM_EMBEDDING_REGISTER) ──
  String _connectionStatus = '';

  // ── Liveness ─────────────────────────────────────────────────────────────────
  // DISABLED: inline timer-based liveness replaced by ML Kit LivenessScreen
  // String _livenessChallenge = '';
  // String _livenessType      = '';
  // bool   _livenessCompleted = false;
  // int    _livenessCountdown = 10;
  // Timer? _livenessTimer;

  // ── PIN setup ─────────────────────────────────────────────────────────────────
  String _pinFirst   = '';
  String _pinConfirm = '';
  bool   _pinStageConfirm = false;
  String _pinError        = '';

  // ── Relay / wallet ───────────────────────────────────────────────────────────
  String _sovId              = '';
  String _enrollMcc          = '999'; // V2: device MCC captured at scan time
  int    _slotId    = 0;
  double _mintedSOV = 0.0;
  String _errorMsg  = '';
  String _derivedPalmName = ''; // set after enrollment; displayed on success screen

  // ── Onboarding ───────────────────────────────────────────────────────────────
  late final PageController _pageCtrl;
  int _onboardPage = 0;

  // ── Watchdog ──────────────────────────────────────────────────────────────────
  Timer? _watchdog;

  // ── Scan timing (for thermal throttle) ───────────────────────────────────────
  DateTime? _loopStartTime;

  // ── Smart reticle overlay ─────────────────────────────────────────────────────
  Rect?  _liveBox;
  bool   _liveDetected     = false;
  bool   _liveCorrectHand  = false;
  late final AnimationController _reticlePulseCtrl;

  // ═══════════════════════════════════════════════════════════════════════════════
  // LIFECYCLE
  // ═══════════════════════════════════════════════════════════════════════════════

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WakelockPlus.enable();

    _pageCtrl = PageController();

    _reticlePulseCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1200))
      ..repeat(reverse: true);

    // Check for existing enrollment after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkExisting());
  }

  @override
  void dispose() {
    // Always clear enrollment guard on screen exit — if the user backs out
    // after palm scan but before relay registration completes, the flag would
    // otherwise stay true, permanently preventing lifecycle disconnect/reconnect.
    RelayConnector.enrollmentInProgress = false;
    WakelockPlus.disable();
    WidgetsBinding.instance.removeObserver(this);
    _stopLoop();
    _streamWatchdog?.cancel();
    if (_usingStream) {
      try { _cam?.stopImageStream(); } catch (_) {}
      _usingStream = false;
    }
    _watchdog?.cancel();
    // _livenessTimer?.cancel(); // DISABLED: inline liveness removed
    _accelSub?.cancel();
    _reticlePulseCtrl.dispose();
    _pageCtrl.dispose();
    _backupPwdCtrl1.dispose();
    _backupPwdCtrl2.dispose();
    try { _cam?.setFlashMode(FlashMode.off); } catch (_) {}
    _cam?.dispose();
    super.dispose();
  }

  // ── Check for existing sovereign ID ──────────────────────────────────────────

  Future<void> _checkExisting() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString('sovereign_id');
    if (!mounted || existing == null || existing.isEmpty) return;

    final choice = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: _cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Wallet Already Registered',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: Text(
          'A wallet is already registered on this device.\n\n'
          'ID: ${existing.substring(0, existing.length.clamp(0, 28))}...',
          style: const TextStyle(color: Colors.white54, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'restore'),
            child: const Text('Restore My Wallet',
                style: TextStyle(color: Color(0xFF006B5E))),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, 'fresh'),
            style: ElevatedButton.styleFrom(
              backgroundColor: _gold, foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Start Fresh',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (!mounted) return;
    if (choice == 'restore') {
      // Navigate back — recovery flow handled by splash/home screen routing
      Navigator.pop(context);
    } else if (choice == 'fresh') {
      await _clearAndStartFresh(prefs);
    }
  }

  Future<void> _clearAndStartFresh(SharedPreferences prefs) async {
    await prefs.clear();
    // Duplicate check happens after first palm scan in _handlePalmCaptured
  }

  // ═══════════════════════════════════════════════════════════════════════════════
  // CAMERA INIT
  // Parameters PRESERVED exactly from palm_hash_test_screen.dart lines 140–168
  // ═══════════════════════════════════════════════════════════════════════════════

  Future<void> _initCamera() async {
    // Dispose any existing controller before re-initialising.
    // This guards against the liveness→palm transition where a stale
    // controller reference could conflict with the new rear camera session.
    if (_cam != null) {
      try { if (_cam!.value.isInitialized) await _cam!.setFlashMode(FlashMode.off); } catch (_) {}
      try { await _cam!.dispose(); } catch (_) {}
      _cam = null;
      await Future.delayed(const Duration(milliseconds: 300));
    }

    try {
      final cams = await availableCameras();
      // PRESERVED: rear camera, fallback to first
      final back = cams.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cams.first,
      );
      // ResolutionPreset.low (320×240). yuv420 enables the live-preview detection
      // STREAM (smooth path). takePicture still returns a JPEG for the template
      // burst, so processBurst is unchanged. sensorOrientation rotates stream
      // frames to upright for the orientation-sensitive V28 model.
      _sensorOrientation = back.sensorOrientation;
      _cam = CameraController(
        back,
        ResolutionPreset.low,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await _cam!.initialize();

      // Rebuild whenever camera value changes (handles isInitialized transitions)
      _cam!.addListener(() { if (mounted) setState(() {}); });

      // Focus + zoom
      try { await _cam!.setFocusMode(FocusMode.auto); } catch (_) {}
      try {
        final minZoom = await _cam!.getMinZoomLevel();
        final maxZoom = await _cam!.getMaxZoomLevel();
        await _cam!.setZoomLevel(1.5.clamp(minZoom, maxZoom));
      } catch (_) {}

      // Torch starts OFF — enabled when scan loop starts to reduce heat
      await _setTorch(false);

      // Stability = total acceleration MAGNITUDE near gravity (g ~= 9.8), in ANY
      // orientation. The old check `|x|+|y|+|z-9.8| < 1.5` assumed gravity on the
      // z-axis (phone lying flat). Palm scanning holds the phone UPRIGHT (z ~= 0), so
      // |z-9.8| ~= 9.8, the sum was never < 1.5, `_isStable` was stuck false, every
      // frame took the x0.85 penalty, and the 2-good-frame capture gate never fired —
      // enrolment froze forever at "Hold steady". Magnitude is orientation-agnostic.
      _accelSub = accelerometerEventStream().listen(
        (e) { _isStable = (sqrt(e.x * e.x + e.y * e.y + e.z * e.z) - 9.8).abs() < 1.5; },
        onError: (_) { _isStable = true; },
      );

      if (mounted) setState(() {});
      _startScanLoop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _step    = _EnrollStep.failed;
          _errorMsg = 'Camera failed to start: $e';
        });

      }
    }
  }

  Future<void> _setTorch(bool on) async {
    if (_cam == null) return;
    if (!(_cam!.value.isInitialized)) return;
    try {
      await _cam!.setFlashMode(on ? FlashMode.torch : FlashMode.off);
      if (mounted) setState(() => _torchOn = on);
    } catch (e) {
      debugPrint('Flash mode error (ignored): $e');
    }
  }

  Future<void> _toggleTorch() async {
    await _setTorch(!_torchOn);
  }

  // ═══════════════════════════════════════════════════════════════════════════════
  // SCAN LOOP
  // Preserved from palm_hash_test_screen.dart — 300 ms between frames
  // ═══════════════════════════════════════════════════════════════════════════════

  void _startScanLoop() {
    if (_loopRunning) return; // GUARD: prevents stacked coroutines
    _loopRunning   = true;
    _loopStartTime = DateTime.now();
    _captured      = false;
    _goodFrames    = 0;
    _goodFrameBuffer.clear();
    _alignProgress = 0;
    _detectedHand  = _HandType.unknown;
    // Enable torch when active scanning begins
    _setTorch(true);
    _startDetectionStream();
  }

  // Smooth path: detect off the live preview STREAM (no per-frame takePicture
  // stall). Auto-falls back to the takePicture loop if the stream can't start OR
  // stalls (no palm found in 12s — e.g. a device-specific orientation quirk), so
  // this is never worse than the old behaviour.
  void _startDetectionStream() {
    if (_usingStream) {
      try { _cam?.stopImageStream(); } catch (_) {}
      _usingStream = false;
    }
    _lastStreamDetectMs = 0;
    if (_cam == null || !_cam!.value.isInitialized) { _runLoop(); return; }
    try {
      _cam!.startImageStream(_onStreamFrame);
      _usingStream = true;
      _streamWatchdog?.cancel();
      _streamWatchdog = Timer(const Duration(seconds: 12), () {
        if (_loopRunning && !_captured && _goodFrames == 0) {
          debugPrint('[SCAN] stream stalled 12s — falling back to takePicture loop');
          _fallbackToPolling();
        }
      });
    } catch (e) {
      debugPrint('[SCAN] startImageStream failed ($e) — using takePicture loop');
      _fallbackToPolling();
    }
  }

  Future<void> _fallbackToPolling() async {
    _streamWatchdog?.cancel();
    if (_usingStream) {
      try { await _cam?.stopImageStream(); } catch (_) {}
      _usingStream = false;
    }
    if (_loopRunning && !_captured) _runLoop();
  }

  void _stopLoop() { _loopRunning = false; }

  // ── Live-preview stream frame → throttled detection ──────────────────────────
  Future<void> _onStreamFrame(CameraImage image) async {
    if (!_loopRunning || _captured || _scanBusy || !_usingStream) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final elapsedS = _loopStartTime == null
        ? 0 : DateTime.now().difference(_loopStartTime!).inSeconds;
    // Throttle the heavy model to ~6fps (400ms/thermal back-off after 30s). The
    // PREVIEW stays 30fps/smooth — only the detector is rate-limited, so it tracks
    // smoothly without the every-frame-YOLO heat that cooked low-end phones.
    final minGap = elapsedS > 30 ? 400 : 160;
    if (now - _lastStreamDetectMs < minGap) return;
    if (image.planes.length < 3) return;
    _lastStreamDetectMs = now;
    _scanBusy = true;
    try {
      final det = await PalmImageEngine.detectPalmFromYuv(
        yPlane:        image.planes[0].bytes,
        uPlane:        image.planes[1].bytes,
        vPlane:        image.planes[2].bytes,
        width:         image.width,
        height:        image.height,
        yRowStride:    image.planes[0].bytesPerRow,
        uvRowStride:   image.planes[1].bytesPerRow,
        uvPixelStride: image.planes[1].bytesPerPixel ?? 1,
        rotationDeg:   _sensorOrientation,
      );
      _handleStreamDetection(det);
    } catch (_) {
      // transient frame error — the next frame retries
    } finally {
      _scanBusy = false;
    }
  }

  // EXACT mirror of _scanOneFrame's gate (no-palm, wrong-hand veto, score, lock),
  // but fed by a stream frame. On lock it stops the stream and takes a short
  // takePicture burst for the template — the proven processBurst path, unchanged.
  void _handleStreamDetection(DetectionResult? det) {
    if (!mounted || _captured) return;
    _lastConf = det == null
        ? 'no palm'
        : '${det.confidence.toStringAsFixed(2)} ${det.isRight ? "R" : "L"}'
          '${det.fromUpright ? "" : "↻"}';

    if (det == null || det.confidence < 0.35) {
      setState(() {
        _alignProgress = (_alignProgress * 0.85).clamp(0.0, 1.0);
        _guidance      = 'Fill the oval with your $_enrollHand palm';
        _detectedHand    = _HandType.unknown;
        _liveDetected    = false;
        _liveBox         = null;
        _liveCorrectHand = false;
        _wrongHandStreak = 0;
        _leansWrongStreak = 0;
        // Decay dwell by one on a no-palm frame (not a hard reset) — a brief
        // flicker or a hand passing out of frame must not wipe accumulated progress.
        _goodFrames = (_goodFrames - 1).clamp(0, _kDwellToLock);
      });
      return;
    }

    _handAngleRad = det.angleRad;
    _detectedHand = det.isRight ? _HandType.right : _HandType.left;
    final targetHand = _enrollHand == 'RIGHT' ? _HandType.right : _HandType.left;
    // ADVISORY ONLY — never blocks (see _kWrongHandFramesToHint comment). A
    // mismatch only accumulates; a genuinely wrong hand mismatches every frame and
    // builds a streak, while the chirality FLICKER on a correct palm resets to 0 on
    // the next matching frame and so never nudges — and, crucially, never resets the
    // lock. The user's double-tap choice is authoritative.
    final handMismatch = _detectedHand != targetHand;
    _wrongHandStreak = (handMismatch && det.handednessReliable)
        ? _wrongHandStreak + 1 : 0;
    _leansWrongStreak = (handMismatch && !det.handednessReliable)
        ? _leansWrongStreak + 1 : 0;

    final score = _isStable ? det.confidence : det.confidence * 0.85;
    setState(() {
      _alignProgress =
          (_alignProgress + (score - _alignProgress) * 0.4).clamp(0.0, 1.0);
      final other = _detectedHand == _HandType.right ? 'RIGHT' : 'LEFT';
      final stalled = _loopStartTime != null &&
          DateTime.now().difference(_loopStartTime!) > _kStallHintAfter &&
          _goodFrames == 0;
      if (_wrongHandStreak >= _kWrongHandFramesToHint ||
          _leansWrongStreak >= _kLeansWrongFramesToHint) {
        _guidance = 'That looks like your $other palm — double-tap to switch, '
                    'or show your $_enrollHand';
      } else if (stalled) {
        _guidance = 'Not locking on — check it is your $_enrollHand palm '
                    '(double-tap to switch), and try brighter light';
      } else {
        _guidance = _isStable ? 'Hold still — locking on...' : 'Hold phone steady';
      }
      _liveDetected    = true;
      _liveBox         = det.boxNorm;
      _liveCorrectHand = true;
    });

    // Dwell lock (see _kDwellToLock). Raw confidence, NO handheld penalty — the
    // ×0.85 penalty is what pushed the effective bar to 0.59 and hung the scan.
    if (det.confidence >= _kLockConfFloor) {
      _goodFrames++;
      if (_goodFrames >= _kDwellToLock && !_captured) {
        _captured = true;
        _lockAndCapture();
      }
    }
    // 0.35 <= conf < floor: present but weak — hold dwell (no build, no reset).
  }

  // Lock reached on the stream → stop stream, grab a short takePicture burst for
  // the template (proven path), then hand off to _triggerCapture unchanged.
  Future<void> _lockAndCapture() async {
    _streamWatchdog?.cancel();
    _loopRunning = false;
    if (_usingStream) {
      try { await _cam?.stopImageStream(); } catch (_) {}
      _usingStream = false;
    }
    _goodFrameBuffer.clear();
    for (int i = 0; i < 3; i++) {
      try {
        final photo = await _cam!.takePicture().timeout(const Duration(seconds: 3));
        _goodFrameBuffer.add(await photo.readAsBytes());
      } catch (_) {}
    }
    if (_goodFrameBuffer.isEmpty) { _resetForNextScan(); return; }
    _triggerCapture();
  }

  Future<void> _runLoop() async {
    while (_loopRunning && mounted) {
      if (!_scanBusy && !_captured) await _scanOneFrame();
      // Throttle to 500ms after 30s of continuous scanning to reduce heat
      final elapsed  = DateTime.now().difference(_loopStartTime ?? DateTime.now()).inSeconds;
      final interval = elapsed > 30 ? 500 : 300;
      await Future.delayed(Duration(milliseconds: interval));
    }
  }

  void _resetForNextScan() {
    _stopLoop();
    _scanBusy              = false;
    _captured              = false;
    _goodFrames            = 0;
    _goodFrameBuffer.clear();
    _alignProgress         = 0;
    _detectedHand          = _HandType.unknown;
    _liveBox         = null;
    _liveDetected    = false;
    _liveCorrectHand = false;
    _startScanLoop();
  }

  // ── Single frame capture + AI ─────────────────────────────────────────────────
  // PRESERVED: all detection logic from palm_hash_test_screen.dart lines 224–312

  Future<void> _scanOneFrame() async {
    if (_cam == null || !_cam!.value.isInitialized) return;
    _scanBusy = true;
    try {
      // PRESERVED: 3-second takePicture timeout
      final photo = await _cam!.takePicture()
          .timeout(const Duration(seconds: 3));
      final bytes = await photo.readAsBytes();

      // PROFILING: total per-frame detection cost (letterbox + 307k-pixel input
      // marshal + 1–4× YOLO). Filter logcat: `PALM_PROFILE`.
      final detSw = Stopwatch()..start();
      final det = await PalmImageEngine.detectPalmFast(bytes);
      debugPrint('PALM_PROFILE detect(ms): ${detSw.elapsedMilliseconds}  peak=${det?.confidence.toStringAsFixed(2) ?? "-"}');
      // Diagnostic: record what the model actually sees this frame — raw peak,
      // hand (L/R), and ↻ if the detection came from a ROTATED frame (meaning the
      // handedness is an unreliable guess). 'no palm' = nothing above the 0.05 floor.
      _lastConf = det == null
          ? 'no palm'
          : '${det.confidence.toStringAsFixed(2)} ${det.isRight ? "R" : "L"}'
            '${det.fromUpright ? "" : "↻"}';

      // Live-detect lock gate at 0.35. V28 is bimodal (a real palm reads ~0.9),
      // so a real hand clears this easily; anything below is treated as no palm.
      if (det == null || det.confidence < 0.35) {
        if (mounted) {
          setState(() {
            // 15% decay per bad frame — recovers from a single shake without full restart
            _alignProgress = (_alignProgress * 0.85).clamp(0.0, 1.0);
            _guidance      = 'Fill the oval with your $_enrollHand palm';
            _detectedHand    = _HandType.unknown;
            _liveDetected    = false;
            _liveBox         = null;
            _liveCorrectHand = false;
            _wrongHandStreak = 0;
            _leansWrongStreak = 0;
            // Decay dwell by one on a no-palm frame (not a hard reset) — mirrors
            // _handleStreamDetection; a brief flicker must not wipe progress.
            _goodFrames = (_goodFrames - 1).clamp(0, _kDwellToLock);
          });
        }
        return;
      }

      _handAngleRad = det.angleRad;
      _detectedHand = det.isRight ? _HandType.right : _HandType.left;

      final targetHand = _enrollHand == 'RIGHT' ? _HandType.right : _HandType.left;

      // HANDEDNESS IS ADVISORY ONLY here too — mirrors _handleStreamDetection.
      // It must never block or reset the lock: the model's left/right head flickers
      // on a correct palm as it tilts, and the user's double-tap choice (bound into
      // the template + sent as hand_type) is authoritative. A mismatch only builds a
      // streak to drive a NON-BLOCKING nudge; a flicker resets to 0 and never nudges.
      final handMismatch = _detectedHand != targetHand;
      _wrongHandStreak = (handMismatch && det.handednessReliable)
          ? _wrongHandStreak + 1 : 0;
      _leansWrongStreak = (handMismatch && !det.handednessReliable)
          ? _leansWrongStreak + 1 : 0;

      // PRESERVED: stability penalty 0.85
      final score = _isStable ? det.confidence : det.confidence * 0.85;

      if (mounted) {
        setState(() {
          // PRESERVED: smoothing factor 0.4
          _alignProgress =
              (_alignProgress + (score - _alignProgress) * 0.4).clamp(0.0, 1.0);
          // Priority: wrong-hand advice beats generic steadiness advice, and a
          // stall hint beats both — a user who has held still for 9s and seen
          // nothing happen needs a reason, not another "hold still".
          final other = _detectedHand == _HandType.right ? 'RIGHT' : 'LEFT';
          final stalled = _loopStartTime != null &&
              DateTime.now().difference(_loopStartTime!) > _kStallHintAfter &&
              _goodFrames == 0;
          if (_wrongHandStreak >= _kWrongHandFramesToHint ||
              _leansWrongStreak >= _kLeansWrongFramesToHint) {
            _guidance = 'That looks like your $other palm — double-tap to switch, '
                        'or show your $_enrollHand';
          } else if (stalled) {
            _guidance = 'Not locking on — check it is your $_enrollHand palm '
                        '(double-tap to switch), and try brighter light';
          } else {
            _guidance = _isStable ? 'Hold still — locking on...' : 'Hold phone steady';
          }
          _liveDetected    = true;
          _liveBox         = det.boxNorm;
          _liveCorrectHand = true;
        });
      }

      // Dwell lock (mirrors _handleStreamDetection). Raw confidence, no handheld
      // penalty. A clearly-present frame buffers its bytes + builds dwell; a weak
      // present frame (0.35–floor) holds; a no-palm frame decays it above.
      if (det.confidence >= _kLockConfFloor) {
        if (_goodFrameBuffer.length >= 3) _goodFrameBuffer.removeAt(0);
        _goodFrameBuffer.add(bytes);
        _goodFrames++;
        if (_goodFrames >= _kDwellToLock && !_captured) {
          _captured = true;
          _stopLoop();
          _triggerCapture();
        }
      }
      // 0.35 <= conf < floor: present but weak — hold dwell (no build, no reset).
    } on TimeoutException {
      // Safe — loop retries
    } catch (_) {
      // Any frame error — safe to ignore
    } finally {
      _scanBusy = false;
    }
  }

  // ── Capture and process ───────────────────────────────────────────────────────
  // PRESERVED from palm_hash_test_screen.dart lines 316–377

  Future<void> _triggerCapture() async {
    await _setTorch(false);
    if (mounted) setState(() => _guidance = 'Extracting palm DNA...');

    if (_goodFrameBuffer.isEmpty) { _resetForNextScan(); return; }

    // PRESERVED: 30-second watchdog
    _watchdog?.cancel();
    _watchdog = Timer(const Duration(seconds: 30), () {
      if (mounted) {
        _showSnack('Processing timed out — please try again');
        _resetForNextScan();
      }
    });

    try {
      // PRESERVED: processBurst with 25-second timeout
      final engineResult = await PalmImageEngine.processBurst(
        _goodFrameBuffer,
        handAngleRad: _handAngleRad,
      ).timeout(const Duration(seconds: 25));
      _watchdog?.cancel();

      // PRESERVED: minimum 30 crease pixels quality gate
      if (engineResult.creasePixels < 30) {
        _showSnack('Image too blurry — hold palm closer');
        _resetForNextScan();
        return;
      }

      // PRESERVED: exact embedInIsolate parameters from test screen lines 354–361
      final palmResult = await PalmEmbedder.embedInIsolate(
        jpegBytes: engineResult.skeletonImage,
        imgW: 128, imgH: 128,
        wristX: 64,  wristY: 110,
        indexX: 64,  indexY: 20,
        pinkyX: 100, pinkyY: 30,
        thumbX: 25,  thumbY: 50,
      ).timeout(const Duration(seconds: 15));
      _watchdog?.cancel();

      // PROFILING: per-stage embedding timings in logcat (µs). Filter: `PALM_PROFILE`.
      if (palmResult.timings != null) {
        final t = palmResult.timings!;
        final ms = t.map((k, v) => MapEntry(k, (v / 1000).toStringAsFixed(1)));
        debugPrint('PALM_PROFILE embed(ms): $ms');
      }

      await _handlePalmCaptured(palmResult.embedding);
    } on TimeoutException {
      _watchdog?.cancel();
      _showSnack('Processing timed out — please try again');
      _resetForNextScan();
    } catch (e) {
      _watchdog?.cancel();
      _showSnack('Error — please try again');
      _resetForNextScan();
    }
  }

  // ── Palm captured → advance flow ──────────────────────────────────────────────

  Future<void> _handlePalmCaptured(List<double> emb) async {
    if (_step == _EnrollStep.scanLeft) {
      _leftEmb = emb;

      // Compute 50th-percentile threshold from reliable dims only
      final reliableValsL = FuzzyCommitment.reliableDims
          .map((i) => emb[i]).toList()..sort();
      final thresh50L = reliableValsL[(reliableValsL.length * 0.5).floor()];

      _leftEnroll = FuzzyCommitment.enroll(emb, thresholdOverride: thresh50L);

      // Derive V2 Sovereign ID — embed device MCC at positions 2–4
      _enrollMcc = await SovIdV2.getDeviceMcc();
      _sovId     = SovIdV2.generate(_leftEnroll!.masterKeyHash, _enrollMcc);

      // Apply chirality binding using the user-chosen hand
      FuzzyCommitment.applyChiralityBinding(_leftEnroll!, _enrollHand, _sovId);

      // DISABLED: multi-quantization removed for performance (FIX 4)
      // _leftEnroll2 and _leftEnroll3 removed — relay slots filled with primary

      // Duplicate check — before committing to enrollment
      if (RelayConnector.isConnected || await _tryConnect()) {
        final embJson = jsonEncode(
            emb.map((v) => double.parse(v.toStringAsFixed(4))).toList());
        final dupResp = await RelayConnector.sendAndWait(
          request: {'type': 'PALM_DUPLICATE_CHECK', 'embedding': embJson},
          responseType: 'PALM_DUPLICATE_RESULT',
          timeout: const Duration(seconds: 20),
        );
        if (dupResp != null && dupResp['duplicate'] == true) {
          if (mounted) {
            setState(() {
              _step    = _EnrollStep.failed;
              _errorMsg = 'This palm is already registered. '
                  'Use wallet recovery instead.';
            });

          }
          return;
        }
      }

      // Store temp enrollment — non-fatal: if local SQLite store fails
      // (e.g. first-run schema migration race) enrollment still proceeds
      // because the relay holds the authoritative copy.
      try {
        final tempId = 'ENROLL-TEMP-${DateTime.now().millisecondsSinceEpoch}';
        await PalmLocalStore.saveEnrollment(
            tempId, PalmHandType.left, emb, _leftEnroll!);
      } catch (_) {
        // Local storage failure is non-fatal — continue enrollment.
      }

      // Generate 12-word BIP39 seed phrase from master key
      _seedWords   = Bip39.bitsToMnemonic(_leftEnroll!.masterKeyBits);

      // Lock relay connection from here until enrollment completes.
      // Blocks ALL lifecycle events (paused, inactive, resumed) in main.dart
      // so that the share sheet opening/closing cannot disconnect the relay,
      // trigger reconnect, or show the PIN overlay.
      RelayConnector.enrollmentInProgress = true;
      debugPrint('[ENROLL] enrollmentInProgress=true (palm captured, entering PIN step)');

      // v1 flow: palm done → PIN setup next
      if (mounted) setState(() => _step = _EnrollStep.pinSetup);

    } // end if (scanLeft)
    // DISABLED: single-palm architecture v1
    // Right palm re-enrollment available via recovery flow
    //
    // else if (_step == _EnrollStep.scanRight) {
    //   ... right palm duplicate check, enrollment, and chirality binding ...
    //   if (mounted) setState(() => _step = _EnrollStep.liveness);
    //   _startLiveness();
    // }
  }

  Future<bool> _tryConnect() async {
    try {
      await RelayConnector.connect();
      await Future.delayed(const Duration(seconds: 2));
      return RelayConnector.isConnected;
    } catch (_) { return false; }
  }

  // ═══════════════════════════════════════════════════════════════════════════════
  // PART E — FACE LIVENESS (ML Kit — via LivenessScreen)
  // ═══════════════════════════════════════════════════════════════════════════════

  void _startLiveness() {
    // Navigate to LivenessScreen. We await the push so this continues only
    // after the full pop animation completes — at that point the liveness
    // screen is fully gone, no inherited-widget dependency conflicts.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      // Result: Map {'proof': String, 'face': List<double>?} (FACE-LOCK) —
      // a bare String is tolerated for backward safety.
      final result = await Navigator.push<Object?>(
        context,
        MaterialPageRoute(
          builder: (_) => LivenessScreen(sovereignId: _sovId),
        ),
      );
      if (!mounted) return;
      String? proofHash;
      if (result is Map) {
        proofHash = result['proof'] as String?;
        final face = result['face'];
        _faceEmbedding = face is List
            ? face.map((e) => (e as num).toDouble()).toList()
            : null;
        debugPrint('[ENROLL] Liveness face embedding: '
            '${_faceEmbedding == null ? "NONE" : "${_faceEmbedding!.length}-d"}');
      } else if (result is String) {
        proofHash = result;
      }
      if (proofHash != null && proofHash.isNotEmpty) {
        await _onLivenessPassed(proofHash);
      } else {
        // User dismissed — rebuild to show retry UI.
        setState(() {});
      }
    });
  }

  Future<void> _onLivenessPassed(String proofHash) async {
    // No extra delay needed — Navigator.push already waited for the full
    // pop animation to finish before we got here.
    if (!mounted) return;
    setState(() {
      _step     = _EnrollStep.scanLeft;
      _guidance = 'Fill the oval with your $_enrollHand palm';
    });
    await _initCamera();
  }

  // ═══════════════════════════════════════════════════════════════════════════════
  // PART F — PIN SETUP
  // ═══════════════════════════════════════════════════════════════════════════════

  void _onPinDigit(String d) {
    setState(() {
      _pinError = '';
      if (_pinStageConfirm) {
        if (_pinConfirm.length < 6) _pinConfirm += d;
      } else {
        if (_pinFirst.length < 6) _pinFirst += d;
      }
    });
    // Auto-submit when 6 digits reached
    if (!_pinStageConfirm && _pinFirst.length == 6) {
      Future.delayed(const Duration(milliseconds: 200), _onPinFirstComplete);
    } else if (_pinStageConfirm && _pinConfirm.length == 6) {
      Future.delayed(const Duration(milliseconds: 200), _onPinConfirmComplete);
    }
  }

  void _onPinBackspace() {
    setState(() {
      _pinError = '';
      if (_pinStageConfirm) {
        if (_pinConfirm.isNotEmpty) _pinConfirm = _pinConfirm.substring(0, _pinConfirm.length - 1);
      } else {
        if (_pinFirst.isNotEmpty) _pinFirst = _pinFirst.substring(0, _pinFirst.length - 1);
      }
    });
  }

  void _onPinFirstComplete() {
    setState(() { _pinStageConfirm = true; _pinConfirm = ''; });
  }

  Future<void> _onPinConfirmComplete() async {
    if (_pinFirst != _pinConfirm) {
      setState(() {
        _pinError        = 'PINs do not match — try again';
        _pinFirst        = '';
        _pinConfirm      = '';
        _pinStageConfirm = false;
      });
      return;
    }
    // Store device-tied hash via PinManager: sha256(pin + deviceId + sovereignId + salt)
    // Must match PinSetupScreen and pin_lock_overlay.dart exactly.
    final prefs = await SharedPreferences.getInstance();
    final hash  = await PinManager.hashPin(_pinFirst, _sovId);
    await prefs.setString('pin_hash', hash);

    // Write process-death protection flags BEFORE showing seed phrase screen.
    await _writeProtectionFlags(prefs);

    // v1 flow: PIN done → seed phrase backup (final step)
    if (mounted) setState(() => _step = _EnrollStep.seedPhrase);
  }

  /// Writes all intermediate enrollment data to SharedPreferences so that if
  /// Android kills the process during the seed phrase screen or share sheet,
  /// the splash screen detects enroll_pending=true + sovereign_id and routes
  /// to EnrollmentRecoveryScreen instead of the join/restore screen.
  ///
  /// Safe to call multiple times — subsequent calls overwrite with same values.
  Future<void> _writeProtectionFlags([SharedPreferences? existingPrefs]) async {
    try {
      final prefs  = existingPrefs ?? await SharedPreferences.getInstance();
      final embJson = jsonEncode(
          _leftEmb!.map((v) => double.parse(v.toStringAsFixed(4))).toList());
      // Public key requires KeyManager — initialise in case it hasn't been yet.
      await KeyManager.initialise();
      final publicKey = await KeyManager.getPublicKey();
      await Future.wait([
        prefs.setBool(  'enroll_pending',         true),
        prefs.setString('sovereign_id',           _sovId),
        prefs.setString('pending_public_key',     publicKey ?? ''),
        prefs.setString('pending_palm_embedding', embJson),
        prefs.setString('pending_helper_data',    _leftEnroll!.helperDataBase64),
        prefs.setString('pending_key_hash',       _leftEnroll!.masterKeyHash),
        prefs.setString('pending_hand_type',      _enrollHand),
        prefs.setDouble('pending_threshold',      _leftEnroll!.quantizeThreshold),
      ]);
      debugPrint('[ENROLL] Protection flags written at PIN step — sovId=$_sovId');
    } catch (e) {
      // Non-fatal — enrollment proceeds; worst-case, process-death recovery
      // falls back to EnrollmentRecoveryScreen showing "Incomplete data" error.
      debugPrint('[ENROLL] Protection flags write failed (non-fatal): $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════════
  // RELAY ENROLLMENT
  // ═══════════════════════════════════════════════════════════════════════════════

  Future<void> _registerWithRelay() async {
    // Guard: prevent lifecycle observer from disconnecting relay mid-enrollment.
    // Each relay has its own isolated DB — if the phone reconnects to a different
    // relay after ENROLLMENT_REGISTER was sent to the first, PALM_EMBEDDING_REGISTER
    // will fail with "Palm storage failed" on the new relay.
    RelayConnector.enrollmentInProgress = true;
    try {
      debugPrint('[ENROLL] === _registerWithRelay START ===');

      // Initialise secure key storage — gracefully falls back from
      // hardware-backed EncryptedSharedPreferences to plain secure storage
      // if the Android Keystore is unavailable on this device.
      debugPrint('[ENROLL] Step 0: KeyManager.initialise()');
      try {
        await KeyManager.initialise();
        debugPrint('[ENROLL] Step 0: KeyManager OK');
      } catch (e) {
        debugPrint('[ENROLL] Step 0 FAILED: $e');
        throw Exception(
          'Secure key storage unavailable on this device. '
          'Please ensure your device has a screen lock set up and try again. '
          '(${e.toString().replaceFirst('Exception: ', '')})',
        );
      }

      debugPrint('[ENROLL] Step 1: Derive sovId');
      final keyHash = _leftEnroll!.masterKeyHash;
      // Re-derive V2 ID using stored MCC (must match chirality binding)
      _sovId = SovIdV2.generate(keyHash, _enrollMcc);
      debugPrint('[ENROLL] sovId=$_sovId  mcc=$_enrollMcc  keyHash=${keyHash.substring(0,8)}...');

      // ── KEY-TO-KINGDOM BINDING ────────────────────────────────────────────
      // Replace the ephemeral random Ed25519 key created at app launch with a
      // key deterministically derived from the palm master hash.
      //
      // WHY: masterKeyHash = SHA-256(palmBCHbits).  The BIP39 seed phrase is
      // also derived from palmBCHbits.  So:
      //   palm scan   → masterKeyHash → Ed25519 keypair (this step)
      //   seed phrase → masterKeyHash → Ed25519 keypair (recovery step)
      //   BOTH PATHS PRODUCE THE SAME KEYPAIR — perfect reproducibility.
      //
      // Must happen BEFORE Step 3 (getPublicKey) and before ENROLLMENT_REGISTER
      // so the relay stores the deterministic public key, not the ephemeral one.
      debugPrint('[ENROLL] Step 1b: storeRestoredKeys → deterministic Ed25519 from palm');
      await KeyManager.storeRestoredKeys(
        privateKeyHex: keyHash,
        sovereignId:   _sovId,
      );
      debugPrint('[ENROLL] Step 1b: key binding complete');
      // ─────────────────────────────────────────────────────────────────────

      debugPrint('[ENROLL] Step 2: Build embJson');
      final embJson = jsonEncode(
          _leftEmb!.map((v) => double.parse(v.toStringAsFixed(4))).toList());
      debugPrint('[ENROLL] embJson length=${embJson.length}');

      debugPrint('[ENROLL] Step 3: KeyManager.getPublicKey()');
      final publicKey = await KeyManager.getPublicKey();
      debugPrint('[ENROLL] publicKey=${publicKey == null ? "NULL!" : "${publicKey.substring(0, 8)}..."}');

      // ── INTERMEDIATE DATA WRITE ──────────────────────────────────────────────
      // Store all enrollment data needed for recovery BEFORE relay calls.
      // If Android kills the process during relay registration, the splash
      // screen will detect enroll_pending=true and route to
      // EnrollmentRecoveryScreen, which retries ENROLLMENT_REGISTER +
      // PALM_EMBEDDING_REGISTER using this stored data.
      // NOTE: enrollment_complete is NOT written here — it is written only
      // after PALM_EMBEDDING_RESULT returns success:true (Step 7).
      try {
        final pendingPrefs = await SharedPreferences.getInstance();
        await Future.wait([
          pendingPrefs.setBool(  'enroll_pending',          true),
          pendingPrefs.setString('sovereign_id',            _sovId),
          pendingPrefs.setString('pending_public_key',      publicKey ?? ''),
          pendingPrefs.setString('pending_palm_embedding',  embJson),
          pendingPrefs.setString('pending_helper_data',     _leftEnroll!.helperDataBase64),
          pendingPrefs.setString('pending_key_hash',        _leftEnroll!.masterKeyHash),
          pendingPrefs.setString('pending_hand_type',       _enrollHand),
          pendingPrefs.setDouble('pending_threshold',       _leftEnroll!.quantizeThreshold),
        ]);
        debugPrint('[ENROLL] Intermediate write OK: enroll_pending=true  sovId=$_sovId');
      } catch (e) {
        debugPrint('[ENROLL] Intermediate write failed (non-fatal): $e');
        // Non-fatal — relay calls proceed; on failure user sees error screen
      }
      // ────────────────────────────────────────────────────────────────────────

      debugPrint('[ENROLL] Step 4: relay connection — isConnected=${RelayConnector.isConnected}');
      if (!RelayConnector.isConnected) {
        debugPrint('[ENROLL] Step 4: not connected — calling connect()');
        await RelayConnector.connect();
        // A fresh/cleared client must DISCOVER the genesis first (mirrors →
        // bootstrap → DHT); the DHT lookup alone takes several seconds. The old
        // fixed 3s wait fired "cannot reach relay" while discovery was still
        // finding the node. Poll until actually connected, up to a real budget.
        final connectDeadline = DateTime.now().add(const Duration(seconds: 30));
        while (!RelayConnector.isConnected &&
            DateTime.now().isBefore(connectDeadline)) {
          await Future.delayed(const Duration(milliseconds: 500));
        }
        debugPrint('[ENROLL] Step 4: after reconnect — isConnected=${RelayConnector.isConnected}');
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

      // Step 5: ENROLLMENT_REGISTER
      debugPrint('[ENROLL] Step 5: ENROLLMENT_REGISTER → ENROLLMENT_ACK');
      if (mounted) setState(() => _connectionStatus = 'Registering with SOV Network...');
      final enrollResp = await RelayConnector.sendWithResilience(
        {
          'type':         'ENROLLMENT_REGISTER',
          'sovereign_id': _sovId,
          'public_key':   publicKey,
        },
        'ENROLLMENT_ACK',
        maxRetries: 3,
        timeout: const Duration(seconds: 15),
        onStatusUpdate: (status) {
          if (mounted) setState(() => _connectionStatus = status);
        },
      );
      debugPrint('[ENROLL] Step 5 response: ${enrollResp == null ? "NULL (timeout?)" : enrollResp.toString()}');
      if (enrollResp == null || enrollResp['success'] != true) {
        throw Exception(enrollResp?['error'] ?? 'Enrollment registration failed — no ACK');
      }

      // Step 6: LEFT palm — PALM_EMBEDDING_REGISTER
      // DISABLED: multi-quantization removed (FIX 4) — all 3 slots use primary
      debugPrint('[ENROLL] Step 6: PALM_EMBEDDING_REGISTER → PALM_EMBEDDING_RESULT');
      debugPrint('[ENROLL]   helper_data length=${_leftEnroll!.helperDataBase64.length}');
      debugPrint('[ENROLL]   threshold=${_leftEnroll!.quantizeThreshold}');
      debugPrint('[ENROLL]   hand_type=$_enrollHand');
      if (mounted) setState(() => _connectionStatus = 'Storing biometric on SOV Network...');
      // Derive palm name BEFORE sending PALM_EMBEDDING_REGISTER so we can
      // include it in the payload — the relay stores it alongside the embedding.
      final preRegPalmName = PalmNameEngine.deriveName(_leftEmb!, sovereignId: _sovId);

      final palmResp = await RelayConnector.sendWithResilience(
        {
          'type':               'PALM_EMBEDDING_REGISTER',
          'sovereign_id':       _sovId,
          'embedding':          embJson,
          'helper_data':        _leftEnroll!.helperDataBase64,
          'helper_data_2':      _leftEnroll!.helperDataBase64, // primary (multi-quant disabled)
          'helper_data_3':      _leftEnroll!.helperDataBase64, // primary (multi-quant disabled)
          'threshold':          _leftEnroll!.quantizeThreshold,
          'threshold_2':        _leftEnroll!.quantizeThreshold,
          'threshold_3':        _leftEnroll!.quantizeThreshold,
          'key_hash':           _leftEnroll!.masterKeyHash,
          'hand_type':          _enrollHand,
          // FACE-LOCK: liveness face embedding (192-d) — node-side one-human-
          // one-identity dedup across both hands. Null = omitted (old-client
          // behaviour; node allows unless FACE_REQUIRED=1).
          if (_faceEmbedding != null) 'face_embedding': _faceEmbedding,
          // [PALM-NAME] Send palm name with registration so relay stores it immediately
          'palm_name':          preRegPalmName,
        },
        'PALM_EMBEDDING_RESULT',
        maxRetries: 3,
        timeout: const Duration(seconds: 20),
        onStatusUpdate: (status) {
          if (mounted) setState(() => _connectionStatus = status);
        },
      );
      if (mounted) setState(() => _connectionStatus = '');
      debugPrint('[ENROLL] Step 6 response: ${palmResp == null ? "NULL (timeout?)" : palmResp.toString()}');
      if (palmResp == null) {
        throw Exception('Palm registration timed out — relay did not respond. Check connection.');
      }
      if (palmResp['success'] != true) {
        final errCode = (palmResp['error'] ?? '').toString();
        if (errCode == 'FACE_ALREADY_ENROLLED') {
          throw Exception(
              'This face already has a SOV identity. One human, one identity — '
              'use "Recover Wallet" with your seed phrase instead of enrolling again.');
        }
        throw Exception('RELAY ERROR: ${errCode.isEmpty ? 'Palm registration failed' : errCode}');
      }

      // DISABLED: single-palm architecture v1
      // Right palm re-enrollment available via recovery flow
      // Step 2b (disabled): RIGHT palm PALM_EMBEDDING_REGISTER

      _slotId    = (palmResp['slot_id']       as num?)?.toInt()    ?? 0;
      _mintedSOV = (palmResp['enrollment_sov'] as num?)?.toDouble() ?? 1000.0;
      debugPrint('[ENROLL] Step 6 SUCCESS: slot_id=$_slotId  enrollment_sov=$_mintedSOV');

      // Step 7: Persist to SharedPreferences — left palm only
      debugPrint('[ENROLL] Step 7: SharedPreferences.getInstance()');
      final prefs       = await SharedPreferences.getInstance();
      final countryName = SovIdV2.getCountryName(_sovId);

      // Derive deterministic palm name from the enrollment embedding.
      // Uses 3 axis slices of the 128-dim embedding → SHA-256 → vocabulary lookup.
      // Same palm always produces the same name; zero app size impact (2 KB strings).
      final palmName = PalmNameEngine.deriveName(_leftEmb!, sovereignId: _sovId);
      debugPrint('[ENROLL] Palm name derived: $palmName');
      if (mounted) setState(() => _derivedPalmName = palmName);
      // Warm the relay connector cache so home screen gets the name immediately
      RelayConnector.invalidatePalmNameCache();

      debugPrint('[ENROLL] Step 7: writing prefs keys');
      try {
        await Future.wait([
          prefs.setString('sovereign_id',       _sovId),
          prefs.setString('citizen_country',    countryName),
          prefs.setInt(   'slot_id',            _slotId),
          prefs.setBool(  'enrollment_complete', true),
          prefs.setInt(   'enrolled_at',        DateTime.now().millisecondsSinceEpoch),
          prefs.setString('left_helper_data',   _leftEnroll!.helperDataBase64),
          prefs.setString('left_key_hash',      _leftEnroll!.masterKeyHash),
          prefs.setString('enrolled_hand',      _enrollHand),
          // Store palm embedding for session-lock palm authentication
          prefs.setString('palm_embedding',     jsonEncode(_leftEmb)),
          // Palm-derived deterministic nickname — shown on home screen + groups
          prefs.setString('palm_name',          palmName),
          // Clear intermediate pending data — enrollment is now complete
          prefs.remove('enroll_pending'),
          prefs.remove('pending_public_key'),
          prefs.remove('pending_palm_embedding'),
          prefs.remove('pending_helper_data'),
          prefs.remove('pending_key_hash'),
          prefs.remove('pending_hand_type'),
          prefs.remove('pending_threshold'),
          // DISABLED: right palm not enrolled in v1
          // prefs.setString('right_helper_data',  _rightEnroll!.helperDataBase64),
          // prefs.setString('right_key_hash',     _rightEnroll!.masterKeyHash),
        ]);
        debugPrint('[ENROLL] Step 7: SharedPreferences OK');
      } catch (e, st) {
        debugPrint('[ENROLL] Step 7 FAILED: $e');
        debugPrint('[ENROLL] STACK: $st');
        rethrow;
      }

      // Step 8: Store balance as Seeds (1 SOV = 1,000,000 Seeds).
      // _mintedSOV is the SOV value (e.g. 1000); multiply to get Seeds.
      debugPrint('[ENROLL] Step 8: WalletEngine.initialise() + updateBalance(${_mintedSOV * 1000000})');
      try {
        await WalletEngine.initialise();   // creates wallet row — UPDATE needs a target
        await WalletEngine.updateBalance(_mintedSOV * 1000000);
        debugPrint('[ENROLL] Step 8: WalletEngine OK');
      } catch (e, st) {
        debugPrint('[ENROLL] Step 8 FAILED: $e');
        debugPrint('[ENROLL] STACK: $st');
        // Non-fatal — balance will sync on next app open
        debugPrint('[ENROLL] Step 8: balance update failed (non-fatal) — continuing');
      }

      // Step 9: Record enrollment reward in transaction history.
      try {
        final enrollMs = DateTime.now().millisecondsSinceEpoch;
        await TransactionStore.save({
          'tx_id':           'enrollment-$enrollMs',
          'type':            'enrollment_reward',
          'amount_seeds':    (_mintedSOV * 1000000).round(),
          'counterparty_id': 'SOV Network',
          'from_id':         'SOV Network',
          'tx_hash':         '',
          'timestamp':       enrollMs,
          'status':          'confirmed',
          'relay_id':        RelayConnector.currentRelayId,
          'answered_by':     '',
        });
        debugPrint('[ENROLL] Step 9: enrollment reward saved to TransactionStore');
      } catch (e) {
        debugPrint('[ENROLL] Step 9: TransactionStore save failed (non-fatal): $e');
      }

      debugPrint('[ENROLL] === ENROLLMENT COMPLETE ===');
      RelayConnector.enrollmentInProgress = false;
      debugPrint('[ENROLL] enrollmentInProgress=false (relay confirmed success)');
      if (mounted) { setState(() => _step = _EnrollStep.success); }
    } catch (e, stackTrace) {
      debugPrint('[ENROLL] === ENROLLMENT FAILED ===');
      debugPrint('[ENROLL] ERROR: $e');
      debugPrint('[ENROLL] STACK: $stackTrace');
      RelayConnector.enrollmentInProgress = false;
      debugPrint('[ENROLL] enrollmentInProgress=false (enrollment failed)');
      if (mounted) {
        setState(() {
          _connectionStatus = '';
          _step             = _EnrollStep.failed;
          _errorMsg         = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════════
  // UI HELPERS
  // ═══════════════════════════════════════════════════════════════════════════════

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(color: Colors.white)),
      backgroundColor: _cardBg,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 3),
    ));
  }

  // ═══════════════════════════════════════════════════════════════════════════════
  // BUILD
  // ═══════════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _navy,
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    switch (_step) {
      case _EnrollStep.onboarding:  return _buildOnboarding();
      // case _EnrollStep.handSelection: return _buildHandSelection(); // DISABLED
      case _EnrollStep.scanLeft:
      case _EnrollStep.scanRight:   return _buildScanScreen();
      case _EnrollStep.seedPhrase:  return _buildSeedPhrase();
      case _EnrollStep.liveness:    return _buildLiveness();
      case _EnrollStep.pinSetup:    return _buildPinSetup();
      case _EnrollStep.registering: return _buildRegistering();
      case _EnrollStep.success:     return _buildSuccess();
      case _EnrollStep.failed:      return _buildFailed();
    }
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // PART A — ONBOARDING
  // ─────────────────────────────────────────────────────────────────────────────

  static const _slides = [
    _Slide(
      icon: Icons.fingerprint,
      title: 'Your Palm Is Your Key',
      body: 'Your palm\'s unique crease pattern is your unbreakable '
            'digital identity. No passwords. No usernames. Just you.',
    ),
    _Slide(
      icon: Icons.account_balance_wallet_outlined,
      title: '1,000 SOV Waiting',
      body: 'As a founding citizen you receive 1,000 SOV '
            '(1,000,000,000 Seeds) instantly upon enrollment. '
            'No bank. No application. Yours forever.',
    ),
    _Slide(
      icon: Icons.lock_outlined,
      title: 'You Own It All',
      body: 'No company controls your wallet. Your master key never '
            'leaves your device. The Sovereign Network is yours.',
    ),
  ];

  Widget _buildOnboarding() {
    return Column(
      children: [
        // Skip button
        Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(0, 16, 20, 0),
            child: TextButton(
              onPressed: _startEnrollment,
              child: const Text('Skip',
                  style: TextStyle(color: Colors.white38, fontSize: 14)),
            ),
          ),
        ),
        // Slides
        Expanded(
          child: PageView.builder(
            controller: _pageCtrl,
            itemCount: _slides.length,
            onPageChanged: (i) => setState(() => _onboardPage = i),
            itemBuilder: (_, i) => _buildSlide(_slides[i]),
          ),
        ),
        // Dots + Next button
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
          child: Column(
            children: [
              // Dots
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(3, (i) => AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width:  _onboardPage == i ? 20 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                    color: _onboardPage == i ? _gold : Colors.white24,
                  ),
                )),
              ),
              const SizedBox(height: 24),
              // Referral field removed — network-referral reward decommissioned
              // (PI-33). Certified citizens charge clients directly for services
              // via their qualification; the network no longer pays referrals.
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: () {
                    if (_onboardPage < 2) {
                      _pageCtrl.nextPage(
                          duration: const Duration(milliseconds: 350),
                          curve: Curves.easeInOut);
                    } else {
                      _startEnrollment();
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _gold,
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                    elevation: 0,
                  ),
                  child: Text(
                    _onboardPage < 2 ? 'Next' : 'Begin Enrollment',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSlide(_Slide s) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 36),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 96, height: 96,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _gold.withAlpha(20),
              border: Border.all(color: _gold.withAlpha(60)),
            ),
            child: Icon(s.icon, color: _gold, size: 48),
          ),
          const SizedBox(height: 36),
          Text(s.title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                  height: 1.2)),
          const SizedBox(height: 20),
          Text(s.body,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 15,
                  height: 1.6)),
        ],
      ),
    );
  }

  void _startEnrollment() {
    // LEFT is the default for every enrollment. The V28 model detects both
    // hands; citizens who cannot use their left hand double-tap the scan
    // frame to flip the same single scan to RIGHT.
    _enrollHand = 'LEFT';
    setState(() => _step = _EnrollStep.liveness);
    _startLiveness();
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // PART B / D — PALM SCAN
  // ─────────────────────────────────────────────────────────────────────────────

  Widget _buildScanScreen() {
    return Column(
      children: [
        // Step bar
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
          child: _buildStepBar(),
        ),
        // Camera + overlay (NO guidance bar inside — avoids ClipRRect corner clipping)
        // Double-tap anywhere on the scan frame flips the SAME single scan
        // between LEFT and RIGHT — permanent accessibility feature for
        // citizens who cannot use their left hand. Never a two-scan flow.
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onDoubleTap: _flipEnrollHand,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(26),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _buildCameraPreview(),
                    AnimatedBuilder(
                      animation: _reticlePulseCtrl,
                      builder: (_, __) => CustomPaint(
                        painter: SmartReticlePainter(
                          boxNorm:     _liveBox,
                          detected:    _liveDetected,
                          correctHand: _liveCorrectHand,
                          pulseValue:  _reticlePulseCtrl.value,
                        ),
                      ),
                    ),
                    Positioned(
                      top: 14, right: 14,
                      child: _buildTorchBtn(),
                    ),
                    // FIX 3: guidance bar REMOVED from inside ClipRRect —
                    // moved below camera to prevent 26px rounded-corner text clipping
                  ],
                ),
              ),
            ),
          ),
        ),

        // Guidance bar — OUTSIDE ClipRRect, no corner clipping
        _buildGuidanceBar(),

        Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Mirror the hand glyph when enrolling RIGHT so the guide
                  // matches what the citizen sees — one flipped scan, no 2nd step
                  Transform.flip(
                    flipX: _enrollHand == 'RIGHT',
                    child: const Icon(
                      Icons.back_hand_outlined,
                      color: _gold, size: 24,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    _enrollHand == 'LEFT'
                        ? 'Left Palm — fingers together, steady'
                        : 'Right Palm — fingers together, steady',
                    style: const TextStyle(
                        color: Colors.white, fontSize: 14,
                        fontWeight: FontWeight.w500),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                _enrollHand == 'LEFT'
                    ? 'Can\'t use your left hand? Double-tap the scan to switch to your RIGHT palm.'
                    : 'Double-tap the scan to switch back to your LEFT palm.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.white54, fontSize: 12, height: 1.4),
              ),
              const SizedBox(height: 2),
              const Text(
                'Only ONE palm is enrolled — it becomes your permanent palm identity.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: Colors.white38, fontSize: 11, height: 1.4),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCameraPreview() {
    if (_cam == null || !_cam!.value.isInitialized) {
      return Container(
        color: _cardBg,
        child: const Center(
          child: CircularProgressIndicator(color: Color(0xFFB8960C)),
        ),
      );
    }
    final size = _cam!.value.previewSize;
    return OverflowBox(
      alignment: Alignment.center,
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width:  size?.height ?? 300,
          height: size?.width  ?? 400,
          child:  CameraPreview(_cam!),
        ),
      ),
    );
  }

  Widget _buildTorchBtn() => GestureDetector(
    onTap: _toggleTorch,
    child: Container(
      width: 40, height: 40,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.black45,
        border: Border.all(color: Colors.white24),
      ),
      child: Icon(
        _torchOn ? Icons.flashlight_on_rounded : Icons.flashlight_off_rounded,
        color: _torchOn ? _gold : Colors.white54, size: 20,
      ),
    ),
  );

  // Hand flip — double-tap handler on the scan frame. Spins the SAME single
  // scan between LEFT and RIGHT (permanent accessibility feature — LEFT stays
  // the default every enrollment). Resets scan progress on toggle so buffered
  // frames of one hand can never bleed into the other.
  void _flipEnrollHand() {
    if (_captured) return;   // never mid-capture
    setState(() {
      _enrollHand    = _enrollHand == 'LEFT' ? 'RIGHT' : 'LEFT';
      _alignProgress = 0;
      _goodFrames    = 0;
      _goodFrameBuffer.clear();
      _detectedHand    = _HandType.unknown;
      _liveBox         = null;
      _liveDetected    = false;
      _liveCorrectHand = false;
      _guidance = 'Fill the oval with your $_enrollHand palm';
    });
  }

  Widget _buildGuidanceBar() {
    return Container(
      width: double.infinity,
      color: Colors.black54,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: Text(
          _kPalmDebug && _lastConf.isNotEmpty ? '$_guidance   ·  sees $_lastConf' : _guidance,
          key: ValueKey<String>(_kPalmDebug ? '$_guidance$_lastConf' : _guidance),
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: _alignProgress > 0.7
                ? const Color(0xFF00FF9D)
                : Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
          ),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // PART C — SEED PHRASE
  // ─────────────────────────────────────────────────────────────────────────────

  // ── Wallet file backup (direct save to documents dir — no share sheet) ───────
  // Saves a .sov JSON file directly to the app documents directory.
  /// Saves a .sov JSON file directly to the app private documents directory.
  /// No share sheet — completely silent during enrollment.
  /// Called by the "Save Wallet Backup" button on the success screen.
  /// Opens the inline password form — actual encryption + share happens in
  /// _onBackupPasswordConfirm() after the citizen sets a password.
  void _shareWalletBackup() {
    if (mounted) {
      setState(() {
        _showBackupPasswordForm = true;
        _backupPasswordError    = '';
      });
    }
  }

  /// Called by the Confirm button on the inline backup password form.
  /// Validates the password, encrypts the wallet, saves and opens share sheet.
  Future<void> _onBackupPasswordConfirm() async {
    final p1 = _backupPwdCtrl1.text;
    final p2 = _backupPwdCtrl2.text;

    if (p1.isEmpty) {
      if (mounted) setState(() => _backupPasswordError = 'Please enter a password.');
      return;
    }
    if (p1.length < 6) {
      if (mounted) { setState(() =>
          _backupPasswordError = 'Password must be at least 6 characters.'); }
      return;
    }
    if (p1 != p2) {
      if (mounted) setState(() => _backupPasswordError = 'Passwords do not match.');
      return;
    }

    if (mounted) setState(() { _backupPasswordSaving = true; _backupPasswordError = ''; });

    try {
      final path = await _saveEncryptedWalletBackup(p1);
      if (path == null) throw Exception('File encryption failed');

      if (mounted) {
        setState(() {
          _showBackupPasswordForm = false;
          _backupPasswordSaving   = false;
          _backupPwdCtrl1.clear();
          _backupPwdCtrl2.clear();
          _backupPasswordError    = '';
        });
      }

      // Write checkpoint BEFORE opening share sheet.
      // If Android kills the process during the share sheet, splash reads this
      // checkpoint on restart, confirms enrollment_complete, and routes home.
      await SovCheckpoint.write(
        type: CheckpointType.enrollmentShare,
        data: {
          'sovereign_id':       _sovId,
          'enrollment_complete': true,
        },
      );

      // externalActivityOpen prevents session-lock overlay from triggering
      // when the share sheet closes and the app returns to foreground.
      // enrollmentInProgress already guards this, but belt-and-suspenders.
      RelayConnector.externalActivityOpen = true;
      try {
        await Share.shareXFiles(
          [XFile(path, mimeType: 'application/json')],
          subject: 'SOV Wallet Backup',
        );
      } finally {
        RelayConnector.externalActivityOpen = false;
      }

      await SovCheckpoint.clear(); // Share sheet closed normally
    } catch (e) {
      debugPrint('[BACKUP] Encrypted share failed: $e');
      if (mounted) {
        setState(() {
          _backupPasswordSaving = false;
          _backupPasswordError  = 'Could not create backup. Please try again.';
        });
      }
    }
  }

  /// Encrypts the wallet data with AES-256-CBC using the given password.
  /// Returns the saved file path on success, null on failure.
  /// Format: { version, encrypted, salt, data (base64 IV+ciphertext), created, network }
  Future<String?> _saveEncryptedWalletBackup(String password) async {
    try {
      final sovId = _sovId.isNotEmpty ? _sovId : '';

      // Build plaintext wallet JSON
      final plaintext = jsonEncode({
        'sovereign_id': sovId,
        'seed_phrase':  _seedWords.join(' '),
        'public_key':   '',
        'hand_type':    'LEFT',
        'mcc':          _enrollMcc,
      });

      // Generate random 16-byte salt
      final rng = Random.secure();
      final saltBytes = List<int>.generate(16, (_) => rng.nextInt(256));
      final saltHex   = saltBytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();

      // Derive 32-byte key: SHA-256(password + saltHex)
      final keyBytes = sha256.convert(utf8.encode(password + saltHex)).bytes;
      final key      = enc.Key(Uint8List.fromList(keyBytes));

      // Generate random 16-byte IV
      final ivBytes = List<int>.generate(16, (_) => rng.nextInt(256));
      final iv      = enc.IV(Uint8List.fromList(ivBytes));

      // Encrypt with AES-256-CBC
      final encrypter  = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc));
      final encrypted  = encrypter.encrypt(plaintext, iv: iv);

      // Combine IV + ciphertext → base64
      final combined = Uint8List(16 + encrypted.bytes.length);
      combined.setRange(0, 16, ivBytes);
      combined.setRange(16, combined.length, encrypted.bytes);
      final dataBase64 = base64.encode(combined);

      // Build encrypted file JSON
      final walletData = jsonEncode({
        'version':   2,
        'encrypted': true,
        'salt':      saltHex,
        'data':      dataBase64,
        'created':   DateTime.now().toIso8601String(),
        'network':   'SOV Network v1',
      });

      final dir      = await getApplicationDocumentsDirectory();
      final safeName = sovId.length > 12
          ? sovId.substring(4, 12)
          : sovId.replaceAll(':', '_').replaceAll(' ', '_');
      final fileName = 'SOV_Wallet_${safeName}_enc.sov';
      final file     = File('${dir.path}/$fileName');
      await file.writeAsString(walletData);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('wallet_backup_path', file.path);

      debugPrint('[BACKUP] Encrypted backup saved: ${file.path}');
      return file.path;
    } catch (e) {
      debugPrint('[BACKUP] Encrypted save failed: $e');
      return null;
    }
  }

  Widget _buildSeedPhrase() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Step bar
          Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: _buildStepBar(),
          ),

          // Warning banner
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF5A0000).withAlpha(60),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.red.withAlpha(80)),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 22),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'This is the only time you will see these words. Back them up now.',
                    style: TextStyle(
                        color: Colors.orange,
                        fontSize: 13,
                        fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // ── SECTION 1: Word grid ─────────────────────────────────────────────
          const Text('YOUR RECOVERY PHRASE',
              style: TextStyle(
                  color: Colors.white38, fontSize: 11, letterSpacing: 1.5)),
          const SizedBox(height: 12),

          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              childAspectRatio: 2.4,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            itemCount: 12,
            itemBuilder: (_, i) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: _cardBg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _gold.withAlpha(100)),
              ),
              child: Row(
                children: [
                  Text('${i + 1}',
                      style: const TextStyle(
                          color: Color(0xFFB8960C),
                          fontSize: 10,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _seedWords.length > i ? _seedWords[i] : '...',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 28),

          // ── Write-down checkbox ──────────────────────────────────────────────
          _buildBackupCard(
            icon: Icons.edit_rounded,
            title: 'Write It Down',
            description:
                'Most secure. Write these 12 words on paper and store safely.',
            badge: 'Recommended',
            badgeColor: Colors.greenAccent,
            confirmed: _backupWroteDown,
            actionWidget: _backupWroteDown
                ? const Row(
                    children: [
                      Icon(Icons.check_circle_rounded,
                          color: Colors.greenAccent, size: 18),
                      SizedBox(width: 8),
                      Text('Written down',
                          style: TextStyle(
                              color: Colors.greenAccent, fontSize: 13)),
                    ],
                  )
                : GestureDetector(
                    onTap: () => setState(() => _backupWroteDown = true),
                    child: Row(
                      children: [
                        Container(
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.transparent,
                            border: Border.all(color: Colors.white38),
                          ),
                        ),
                        const SizedBox(width: 10),
                        const Text(
                          'I have written down all 12 words',
                          style: TextStyle(
                              color: Colors.white70, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
          ),
          const SizedBox(height: 20),

          // Custodianship note
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.blue.withAlpha(15),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.blue.withAlpha(40)),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline_rounded,
                    color: Colors.lightBlue, size: 18),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Your wallet key is derived from your palm scan and lives '
                    'only on your device. The SOV Network never stores your '
                    'seed phrase or private key. You are the sole custodian.',
                    style: TextStyle(
                        color: Colors.lightBlue, fontSize: 12, height: 1.5),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),

          // Continue button — seed phrase is the FINAL step (v1 flow)
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: _backupWroteDown
                  ? () async {
                      setState(() => _step = _EnrollStep.registering);
                      await _registerWithRelay();
                    }
                  : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: _gold,
                disabledBackgroundColor: _gold.withAlpha(60),
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                elevation: 0,
              ),
              child: Text(
                _backupWroteDown
                    ? 'I Have Backed Up My Seed Phrase'
                    : 'Confirm you have written down your seed phrase',
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBackupCard({
    required IconData icon,
    required String title,
    required String description,
    required bool confirmed,
    String? badge,
    Color? badgeColor,
    required Widget actionWidget,
  }) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: confirmed ? Colors.green.withAlpha(20) : _cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: confirmed
              ? Colors.greenAccent.withAlpha(150)
              : Colors.white.withAlpha(26),
          width: confirmed ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: confirmed
                      ? Colors.greenAccent.withAlpha(30)
                      : _gold.withAlpha(20),
                ),
                child: Icon(
                  confirmed ? Icons.check_circle_rounded : icon,
                  color: confirmed ? Colors.greenAccent : _gold,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Row(
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: confirmed ? Colors.greenAccent : Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (badge != null) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color:
                              (badgeColor ?? Colors.greenAccent).withAlpha(30),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          badge,
                          style: TextStyle(
                            color: badgeColor ?? Colors.greenAccent,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(description,
              style: const TextStyle(
                  color: Colors.white54, fontSize: 13, height: 1.4)),
          const SizedBox(height: 12),
          actionWidget,
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // PART D2 — HAND SELECTION
  // DISABLED: Right palm detection requires retraining YOLOv8 model with a
  // clean right-palm dataset. Re-enable when model is retrained.
  // To re-enable: restore handSelection to _EnrollStep, update _startEnrollment(),
  // add case to _buildBody(), and uncomment the widgets below.
  // ─────────────────────────────────────────────────────────────────────────────

  // Widget _buildHandSelection() {
  //   return SafeArea(
  //     child: SingleChildScrollView(
  //       padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
  //       child: Column(
  //         crossAxisAlignment: CrossAxisAlignment.start,
  //         children: [
  //           const Text('Choose Your Scanning Hand', ...),
  //           // Card 1 — Left Hand
  //           _buildHandCard(hand: 'LEFT', title: 'Left Hand', ...),
  //           const SizedBox(height: 16),
  //           // Card 2 — Right Hand
  //           // DISABLED: Right palm detection requires retraining
  //           // YOLOv8 model with clean right-palm dataset.
  //           // Re-enable when model is retrained.
  //           // _buildHandCard(hand: 'RIGHT', title: 'Right Hand', ...),
  //         ],
  //       ),
  //     ),
  //   );
  // }

  // Widget _buildHandCard({ required String hand, required String title,
  //   required String subtitle, required bool recommended }) { ... }

  // ─────────────────────────────────────────────────────────────────────────────
  // PART E — FACE LIVENESS
  // ─────────────────────────────────────────────────────────────────────────────

  Widget _buildLiveness() {
    // ML Kit LivenessScreen is launched via Navigator.push in _startLiveness().
    // This widget is shown briefly while the push is scheduled (addPostFrameCallback).
    // If the user dismissed LivenessScreen without passing, show a Retry prompt.
    return Column(
      children: [
        // Step bar — liveness tab is active (step index 2)
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
          child: _buildStepBar(),
        ),
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(36),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 90, height: 90,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _cardBg,
                      border: Border.all(color: _gold.withAlpha(60)),
                    ),
                    child: const Icon(Icons.face_outlined, color: Color(0xFFB8960C), size: 44),
                  ),
                  const SizedBox(height: 32),
                  const Text('Prove You Are Human',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 14),
                  const Text(
                    'Complete a quick face challenge to confirm you are a real person before registering your palm.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white54, fontSize: 15, height: 1.5),
                  ),
                  const SizedBox(height: 32),
                  ElevatedButton.icon(
                    onPressed: _startLiveness,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Start Liveness Check',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _gold,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // PART F — PIN SETUP
  // ─────────────────────────────────────────────────────────────────────────────

  Widget _buildPinSetup() {
    final currentPin = _pinStageConfirm ? _pinConfirm : _pinFirst;
    return Column(
      children: [
        const SizedBox(height: 48),
        const Icon(Icons.lock_outline_rounded, color: Color(0xFFB8960C), size: 48),
        const SizedBox(height: 24),
        Text(
          _pinStageConfirm ? 'Confirm Your PIN' : 'Create a 6-Digit PIN',
          style: const TextStyle(
              color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Text(
          _pinStageConfirm
              ? 'Enter your PIN again to confirm'
              : 'This PIN protects your wallet on this device',
          style: const TextStyle(color: Colors.white38, fontSize: 13),
        ),
        const SizedBox(height: 32),

        // 6 dot indicators
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(6, (i) => AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            margin: const EdgeInsets.symmetric(horizontal: 8),
            width: 16, height: 16,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: i < currentPin.length ? _gold : Colors.transparent,
              border: Border.all(
                color: i < currentPin.length ? _gold : Colors.white38,
                width: 2,
              ),
            ),
          )),
        ),

        if (_pinError.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(_pinError,
              style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
        ],

        const SizedBox(height: 40),

        // Number pad
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final row in [
                  ['1', '2', '3'],
                  ['4', '5', '6'],
                  ['7', '8', '9'],
                  ['', '0', 'del'],
                ])
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: row.map((k) => _pinKey(k)).toList(),
                    ),
                  ),
              ],
            ),
          ),
        ),

        // Skip link
        Padding(
          padding: const EdgeInsets.only(bottom: 24),
          child: TextButton(
            onPressed: () async {
              // Write process-death protection flags even when PIN is skipped.
              await _writeProtectionFlags();
              // v1 flow: skip PIN → go to seed phrase backup
              if (mounted) setState(() => _step = _EnrollStep.seedPhrase);
            },
            child: const Text('Skip PIN — Set up later',
                style: TextStyle(color: Colors.white24, fontSize: 12)),
          ),
        ),
      ],
    );
  }

  Widget _pinKey(String k) {
    if (k.isEmpty) return const SizedBox(width: 72, height: 72);
    return GestureDetector(
      onTap: () => k == 'del' ? _onPinBackspace() : _onPinDigit(k),
      child: Container(
        width: 72, height: 72,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _cardBg,
          border: Border.all(color: Colors.white.withAlpha(20)),
        ),
        child: Center(
          child: k == 'del'
              ? const Icon(Icons.backspace_outlined,
                  color: Colors.white54, size: 22)
              : Text(k,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w500)),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // REGISTERING
  // ─────────────────────────────────────────────────────────────────────────────

  Widget _buildRegistering() => Center(
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
              child: const Center(child: CircularProgressIndicator(
                  color: Color(0xFFB8960C), strokeWidth: 2.5)),
            ),
          ]),
          const SizedBox(height: 36),
          const Text('Registering Identity',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          // Dynamic status message updated by sendWithResilience callbacks
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: Text(
              _connectionStatus.isNotEmpty
                  ? _connectionStatus
                  : 'Connecting to the Sovereign Network...',
              key: ValueKey<String>(_connectionStatus),
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: Colors.white54, fontSize: 14, height: 1.5),
            ),
          ),
          // Reconnect attempt indicator — only shown when status mentions 'attempt'
          if (_connectionStatus.contains('attempt') ||
              _connectionStatus.contains('Reconnecting')) ...[
            const SizedBox(height: 20),
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 24),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withAlpha(13),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 14, height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 1.5, color: Color(0xFFB8960C)),
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      _connectionStatus,
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    ),
  );

  // ─────────────────────────────────────────────────────────────────────────────
  // PART G — SUCCESS
  // ─────────────────────────────────────────────────────────────────────────────

  Widget _buildSuccess() {
    final sovStr   = _mintedSOV.toStringAsFixed(0);
    final seedsStr = '${(_mintedSOV * 1000000).toStringAsFixed(0)} Seeds';
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 48, 28, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Gold check
          Container(
            width: 104, height: 104,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFFB8960C), Color(0xFFD4AF37)],
              ),
              boxShadow: [
                BoxShadow(
                    color: const Color(0xFFB8960C).withAlpha(80),
                    blurRadius: 32, spreadRadius: 4),
              ],
            ),
            child: const Icon(Icons.check_rounded,
                color: Colors.white, size: 56),
          ),
          const SizedBox(height: 28),
          Text(
            _derivedPalmName.isNotEmpty
                ? 'Welcome, $_derivedPalmName'
                : 'Welcome, Citizen',
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(
            _derivedPalmName.isNotEmpty
                ? 'Your citizen name is $_derivedPalmName.\nThis is how the network knows you.'
                : 'Your identity is secured biometrically.\nNo passwords. No accounts. Just you.',
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: Colors.white54, fontSize: 13, height: 1.6),
          ),
          const SizedBox(height: 36),

          // SOV card
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 24),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  const Color(0xFFB8960C).withAlpha(35),
                  const Color(0xFFB8960C).withAlpha(12),
                ],
              ),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(
                  color: const Color(0xFFB8960C).withAlpha(70)),
            ),
            child: Column(
              children: [
                Text(
                  '$sovStr SOV',
                  style: const TextStyle(
                    color: Color(0xFFB8960C),
                    fontSize: 52,
                    fontWeight: FontWeight.bold,
                    letterSpacing: -1,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  seedsStr,
                  style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // IDs
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: _cardBg,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withAlpha(26)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _infoRow(label: 'Sovereign ID', value: _sovId),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // ── Wallet backup banner ─────────────────────────────────────────────
          // Always shown — enrollment_complete=true is already written.
          // Process death during share restarts to HomeScreen, not join/restore.
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 0, vertical: 8),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFFD4AF37).withAlpha(38),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: const Color(0xFFD4AF37).withAlpha(102)),
            ),
            child: Column(
              children: [
                const Row(
                  children: [
                    Icon(Icons.shield_outlined,
                        color: Color(0xFFD4AF37), size: 20),
                    SizedBox(width: 8),
                    Text(
                      'Back up your wallet',
                      style: TextStyle(
                        color: Color(0xFFD4AF37),
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'Save your wallet file to Google Drive '
                  'or another safe location. Without this '
                  'backup you cannot recover your wallet '
                  'if you lose your phone.',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 12),

                // ── Button or inline password form ─────────────────────────
                if (!_showBackupPasswordForm) ...[
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _shareWalletBackup,
                      icon: const Icon(Icons.share,
                          color: Color(0xFFD4AF37), size: 16),
                      label: const Text(
                        'Save Wallet Backup',
                        style: TextStyle(
                          color: Color(0xFFD4AF37),
                          fontSize: 14,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Color(0x80D4AF37)),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                  ),
                ] else ...[
                  // Inline password form
                  const Text(
                    'Protect your backup file',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Enter a password to encrypt your wallet file. '
                    'You will need this password to restore your wallet.',
                    style: TextStyle(
                        color: Colors.white54, fontSize: 12, height: 1.4),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _backupPwdCtrl1,
                    obscureText: true,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: InputDecoration(
                      labelText: 'Password',
                      labelStyle: const TextStyle(color: Colors.white54, fontSize: 12),
                      filled: true,
                      fillColor: const Color(0xFF0A1628),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8)),
                      enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(
                              color: Colors.white.withAlpha(40))),
                      focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide:
                              const BorderSide(color: Color(0xFFB8960C))),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _backupPwdCtrl2,
                    obscureText: true,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: InputDecoration(
                      labelText: 'Confirm password',
                      labelStyle: const TextStyle(color: Colors.white54, fontSize: 12),
                      filled: true,
                      fillColor: const Color(0xFF0A1628),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8)),
                      enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(
                              color: Colors.white.withAlpha(40))),
                      focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide:
                              const BorderSide(color: Color(0xFFB8960C))),
                    ),
                    onSubmitted: (_) => _onBackupPasswordConfirm(),
                  ),
                  if (_backupPasswordError.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      _backupPasswordError,
                      style: const TextStyle(
                          color: Colors.redAccent, fontSize: 12),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => setState(() {
                            _showBackupPasswordForm = false;
                            _backupPasswordError    = '';
                            _backupPwdCtrl1.clear();
                            _backupPwdCtrl2.clear();
                          }),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white54,
                            side: BorderSide(
                                color: Colors.white.withAlpha(40)),
                            padding:
                                const EdgeInsets.symmetric(vertical: 10),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8)),
                          ),
                          child: const Text('Cancel'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _backupPasswordSaving
                            ? const Center(
                                child: SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(
                                    color: Color(0xFFD4AF37),
                                    strokeWidth: 2,
                                  ),
                                ),
                              )
                            : ElevatedButton(
                                onPressed: _onBackupPasswordConfirm,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFFB8960C),
                                  foregroundColor: Colors.black,
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 10),
                                  shape: RoundedRectangleBorder(
                                      borderRadius:
                                          BorderRadius.circular(8)),
                                  elevation: 0,
                                ),
                                child: const Text('Confirm',
                                    style: TextStyle(
                                        fontWeight: FontWeight.bold)),
                              ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),

          SizedBox(
            width: double.infinity,
            height: 58,
            child: ElevatedButton(
              onPressed: () async {
                // Belt-and-suspenders: ensure PIN is set before home screen.
                // In normal enrollment flow, PIN was set at pinSetup step.
                // This guard fires only if something went wrong earlier.
                final prefs   = await SharedPreferences.getInstance();
                final pinHash = prefs.getString('pin_hash') ?? '';
                if (pinHash.isEmpty && mounted) {
                  final pinSet = await Navigator.push<bool>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => PinSetupScreen(
                        onPinSet: (hash) async =>
                            prefs.setString('pin_hash', hash),
                      ),
                    ),
                  );
                  if (pinSet != true) return;
                }
                if (!mounted) return;
                // Linux: persist the newly enrolled key behind a PIN (Spend-Lock)
                // before entering the wallet. The app-lock PIN set above does NOT
                // encrypt the key; without this the wallet is held in memory only
                // on Linux and lost at next launch. No-op on other platforms.
                await ensureKeyPersistedOnLinux(context);
                if (!mounted) return;
                Navigator.pushReplacement(
                  context,
                  PageRouteBuilder(
                    pageBuilder:  (_, __, ___) => const MainShell(),
                    transitionsBuilder: (_, anim, __, child) =>
                        FadeTransition(opacity: anim, child: child),
                    transitionDuration: const Duration(milliseconds: 500),
                  ),
                );
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFB8960C),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18)),
                elevation: 0,
              ),
              child: const Text('Your Wallet Is Ready',
                  style: TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoRow({
    required String label,
    required String value,
    Color? valueColor,
  }) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  color: Colors.white38, fontSize: 11, letterSpacing: 0.5)),
          const SizedBox(height: 4),
          Text(value,
              style: TextStyle(
                color: valueColor ?? Colors.white,
                fontSize: 13,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w500,
              )),
        ],
      );

  // ─────────────────────────────────────────────────────────────────────────────
  // FAILED
  // ─────────────────────────────────────────────────────────────────────────────

  Widget _buildFailed() => Center(
    child: Padding(
      padding: const EdgeInsets.all(36),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
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
          const SizedBox(height: 28),
          const Text('Enrollment Failed',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Text(
            _errorMsg,
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: Colors.white54, fontSize: 14, height: 1.5),
          ),
          const SizedBox(height: 36),
          // If palm already registered → send user to recovery.
          // For any other error → offer Try Again.
          if (_errorMsg.contains('already registered')) ...[
            SizedBox(
              width: double.infinity,
              height: 54,
              child: ElevatedButton.icon(
                onPressed: () {
                  _stopLoop();
                  _cam?.dispose();
                  _cam = null;
                  Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(builder: (_) => const RecoveryScreen()),
                  );
                },
                icon: const Icon(Icons.restore_rounded),
                label: const Text('Recover My Wallet',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFB8960C),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                ),
              ),
            ),
          ] else ...[
            SizedBox(
              width: double.infinity,
              height: 54,
              child: ElevatedButton(
                onPressed: () {
                  setState(() {
                    _step     = _EnrollStep.onboarding;
                    _errorMsg = '';
                    _leftEmb    = null;
                    _leftEnroll  = null;
                    _pinFirst    = '';
                    _pinConfirm  = '';
                    _pinStageConfirm = false;
                    _onboardPage = 0;
                  });
                  _stopLoop();
                  _cam?.dispose();
                  _cam = null;
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFB8960C),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                ),
                child: const Text('Try Again',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ],
      ),
    ),
  );

  // ─────────────────────────────────────────────────────────────────────────────
  // STEP BAR
  // ─────────────────────────────────────────────────────────────────────────────

  List<_StepInfo> _buildSteps() {
    // v1 flow: Liveness → Palm Scan → Create PIN → Backup Words
    // scanRight is disabled in v1 (single-palm architecture)
    final current = _step == _EnrollStep.liveness   ? 0
                  : _step == _EnrollStep.scanLeft    ? 1
                  : _step == _EnrollStep.pinSetup    ? 2
                  : _step == _EnrollStep.seedPhrase  ? 3
                  : 4;
    return [
      _StepInfo(label: 'Liveness',     isActive: current == 0, isDone: current > 0),
      _StepInfo(label: 'Palm Scan',    isActive: current == 1, isDone: current > 1),
      _StepInfo(label: 'Create PIN',   isActive: current == 2, isDone: current > 2),
      _StepInfo(label: 'Backup Words', isActive: current == 3, isDone: current > 3),
    ];
  }

  Widget _buildStepBar() {
    return Row(
      children: _buildSteps().map((step) => Expanded(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: step.isActive ? _gold
                     : step.isDone   ? _teal
                     : Colors.white24,
                width: step.isActive ? 3 : 1.5,
              ),
            ),
          ),
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            step.label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: step.isActive ? _gold
                   : step.isDone   ? _teal
                   : Colors.white38,
              fontSize: 11,
              fontWeight: step.isActive ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ),
      )).toList(),
    );
  }
}

// ── Step info data class ──────────────────────────────────────────────────────
class _StepInfo {
  final String label;
  final bool isActive;
  final bool isDone;
  const _StepInfo({required this.label, required this.isActive, required this.isDone});
}

// ── Slide data class ──────────────────────────────────────────────────────────
class _Slide {
  final IconData icon;
  final String   title;
  final String   body;
  const _Slide({required this.icon, required this.title, required this.body});
}

// ═══════════════════════════════════════════════════════════════════════════════
// SMART RETICLE PAINTER
// Tracks the YOLO bounding box with corner brackets.
// ═══════════════════════════════════════════════════════════════════════════════
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

    // "HOLD STEADY" text removed — was drawn at bottom + 8 inside ClipRRect,
    // causing it to be clipped at rounded corners ("TEADY" bug).
    // The guidance bar outside ClipRRect handles this feedback instead.

    // Dashed edge guides connecting corner brackets
    if (correctHand) {
      final dashPaint = Paint()
        ..color = const Color(0xFF00FF9D).withValues(alpha: 0.4)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;
      _drawDashedLine(canvas, Offset(left + armW, top),    Offset(right - armW, top),    dashPaint);
      _drawDashedLine(canvas, Offset(left + armW, bottom), Offset(right - armW, bottom), dashPaint);
      _drawDashedLine(canvas, Offset(left, top + armH),    Offset(left, bottom - armH),  dashPaint);
      _drawDashedLine(canvas, Offset(right, top + armH),   Offset(right, bottom - armH), dashPaint);
    }
  }

  void _drawDashedLine(Canvas canvas, Offset start, Offset end, Paint paint) {
    const dashLength = 8.0;
    const gapLength  = 5.0;
    final total     = (end - start).distance;
    final direction = (end - start) / total;
    double drawn  = 0;
    bool   drawing = true;
    Offset current = start;
    while (drawn < total) {
      final segment = drawing ? dashLength : gapLength;
      final next    = drawn + segment;
      if (drawing) {
        canvas.drawLine(current, start + direction * next.clamp(0, total), paint);
      }
      current = start + direction * next.clamp(0, total);
      drawn   = next;
      drawing = !drawing;
    }
  }

  @override
  bool shouldRepaint(SmartReticlePainter old) =>
    old.boxNorm != boxNorm || old.detected != detected ||
    old.correctHand != correctHand || old.pulseValue != pulseValue;
}

