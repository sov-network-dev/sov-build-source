// lib/screens/palm_hash_test_screen.dart
// ─────────────────────────────────────────────────────────────────────────────
// SVRN DIAGNOSTIC SUITE — File-Based Architecture
//
// HOW IT WORKS (designed for any Android phone, 512MB RAM+):
//
// 1. Camera runs at LOW resolution (320×240) — small JPEG, low CPU, no heat.
// 2. Every 800ms the screen takes ONE picture and asks AI: "what is this?"
// 3. AI returns a DetectionResult instantly — confidence, left/right, angle.
// 4. UI reacts to the result: red/yellow/green frame, guidance text.
// 5. When AI says "correct hand, confident" for 2 consecutive checks →
//    collect up to 3 of those good frames → send to processBurst.
// 6. processBurst picks the best frame, runs enhancement, returns hash.
// 7. No large RAM buffers. No concurrent isolates. No camera queue overflow.
//
// Camera is NEVER disposed between steps — restart loop only.
// Watchdog timer recovers from any OS-level isolate kill.
// ─────────────────────────────────────────────────────────────────────────────
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../sov_node_sdk/palm_embedder.dart';
import '../sov_node_sdk/fuzzy_commitment.dart';
import '../sov_node_sdk/relay_connector.dart';
import '../sov_node_sdk/palm_local_store.dart';
import '../sov_node_sdk/palm_image_engine.dart';
import 'palm_gallery_screen.dart';

enum HandType { left, right, unknown }
enum _AppState { init, scanning, processing, result, relayTest, summary, error }
enum _DiagStep { enrollLeft, enrollRight, rescanLeft, sybilTest, relayTest, summary }

class PalmHashTestScreen extends StatefulWidget {
  const PalmHashTestScreen({super.key});
  @override
  State<PalmHashTestScreen> createState() => _PalmHashTestScreenState();
}

class _PalmHashTestScreenState extends State<PalmHashTestScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {

  static const _bg   = Color(0xFF0A1628);
  static const _gold = Color(0xFFD4AF37);
  static const _teal = Color(0xFF00D4AA);

  // ── CAMERA ─────────────────────────────────────────────────────────────────
  CameraController? _cam;
  bool _torchOn = false;

  // ── ANIMATION ──────────────────────────────────────────────────────────────
  late final AnimationController _pulseCtrl;
  late final Animation<double>   _pulseAnim;

  // ── APP STATE ──────────────────────────────────────────────────────────────
  _AppState _appState = _AppState.init;
  _DiagStep _diagStep = _DiagStep.enrollLeft;
  String    _guidance = 'Show your palm';

  // ── SEQUENTIAL SCAN LOOP ───────────────────────────────────────────────────
  bool _loopRunning  = false;
  bool _scanBusy     = false;  // true while takePicture+AI is in flight
  bool _captured     = false;  // true after trigger fires, prevents double-capture

  // ── DETECTION STATE ────────────────────────────────────────────────────────
  HandType _detectedHand = HandType.unknown;
  double   _handAngleRad = 0;
  double   _dbgRow4      = 0;
  double   _dbgRow5      = 0;
  double   _dbgConf      = 0;

  // ── PROGRESS ───────────────────────────────────────────────────────────────
  // Visual bar — smoothed animation only, does NOT control capture trigger
  double _alignmentProgress = 0.0;
  // Hard trigger counter — how many consecutive good frames we have seen
  int    _goodFrames = 0;
  static const _goodFramesNeeded = 2;

  // ── ROLLING BUFFER — controlled small frames only ──────────────────────────
  // Stores Uint8List of frames where AI confirmed correct hand at >= 50%
  // Max 3 frames. Each is a low-res camera JPEG — small, safe.
  final List<Uint8List> _goodFrameBuffer = [];

  // ── SENSORS ────────────────────────────────────────────────────────────────
  StreamSubscription? _accelSub;
  bool _isPhoneStable = false;

  // ── BIOMETRIC DATA ─────────────────────────────────────────────────────────
  List<double>?     _leftEmbedding;
  EnrollmentResult? _leftEnrollment, _rightEnrollment;
  final String _sovId = 'DIAG-${DateTime.now().millisecondsSinceEpoch}';
  final Map<_DiagStep, _StepResult> _results      = {};
  final List<_GalleryImage>         _galleryImages = [];

  // ── RELAY ──────────────────────────────────────────────────────────────────
  String _relayLog     = '';
  bool   _relayTesting = false;

  // ── WATCHDOG ───────────────────────────────────────────────────────────────
  Timer? _watchdog;

  // ── LIFECYCLE ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WakelockPlus.enable();
    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 800))
      ..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.6, end: 1.0).animate(
        CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));
    _initCamera();
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    WidgetsBinding.instance.removeObserver(this);
    _stopLoop();
    _watchdog?.cancel();
    _accelSub?.cancel();
    _pulseCtrl.dispose();
    if (_cam != null) {
      try { _cam!.setFlashMode(FlashMode.off); } catch (_) {}
      try { _cam!.dispose(); } catch (_) {}
    }
    super.dispose();
  }

  // ── CAMERA INIT (called ONCE at app start, then never again) ───────────────

  Future<void> _initCamera() async {
    _setAppState(_AppState.init, 'Starting camera...');
    try {
      final cams = await availableCameras();
      final back = cams.firstWhere(
          (c) => c.lensDirection == CameraLensDirection.back,
          orElse: () => cams.first);

      _cam = CameraController(
        back,
        ResolutionPreset.low, // 320×240 — small, low heat, low RAM usage
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await _cam!.initialize();

      try {
        await _cam!.setFlashMode(FlashMode.torch);
        if (mounted) setState(() => _torchOn = true);
      } catch (_) {}

      _accelSub = accelerometerEventStream().listen(
        (e) { _isPhoneStable = (e.x.abs() + e.y.abs() + (e.z - 9.8).abs()) < 1.5; },
        onError: (_) { _isPhoneStable = true; },
      );

      if (mounted) setState(() {});
      _startScanLoop();
    } catch (e) {
      _setAppState(_AppState.error, 'Camera failed: $e');
    }
  }

  Future<void> _toggleTorch() async {
    if (_cam == null || !_cam!.value.isInitialized) return;
    try {
      await _cam!.setFlashMode(_torchOn ? FlashMode.off : FlashMode.torch);
      setState(() => _torchOn = !_torchOn);
    } catch (_) {}
  }

  // ── SEQUENTIAL SCAN LOOP ───────────────────────────────────────────────────
  // One frame at a time. Camera hardware is never asked for the next frame
  // until the previous takePicture + AI inference is fully complete.

  void _startScanLoop() {
    if (_loopRunning) return;
    _loopRunning = true;
    _captured    = false;
    _goodFrames  = 0;
    _goodFrameBuffer.clear();
    _alignmentProgress = 0;
    _detectedHand      = HandType.unknown;
    if (mounted) setState(() { _appState = _AppState.scanning; });
    _runLoop();
  }

  Future<void> _runLoop() async {
    while (_loopRunning && mounted) {
      if (_appState == _AppState.scanning && !_scanBusy && !_captured) {
        await _scanOneFrame();
      }
      // 300ms pause between frames — hardware breathing room
      await Future.delayed(const Duration(milliseconds: 300));
    }
  }

  void _stopLoop() {
    _loopRunning = false;
  }

  /// Reset state for a new step — camera stays alive.
  void _resetForNextStep() {
    _stopLoop();
    _scanBusy          = false;
    _captured          = false;
    _goodFrames        = 0;
    _goodFrameBuffer.clear();
    _alignmentProgress = 0;
    _detectedHand      = HandType.unknown;
    _dbgRow4 = _dbgRow5 = _dbgConf = 0;
    try { _cam?.setFlashMode(FlashMode.torch); setState(() => _torchOn = true); } catch (_) {}
    _startScanLoop();
  }

  // ── SINGLE FRAME SCAN ─────────────────────────────────────────────────────

  Future<void> _scanOneFrame() async {
    if (_cam == null || !_cam!.value.isInitialized) return;
    _scanBusy = true;

    try {
      // Take one small picture (320×240 at low preset)
      final photo = await _cam!.takePicture()
          .timeout(const Duration(seconds: 3));
      final bytes = await photo.readAsBytes();

      // Ask AI: what is in this frame?
      final detection = await PalmImageEngine.detectPalmFast(bytes);

      if (detection == null || detection.confidence < 0.50) {
        // Nothing recognised — decay the bar slowly
        if (mounted) { setState(() {
          _alignmentProgress = (_alignmentProgress * 0.7).clamp(0.0, 1.0);
          _guidance          = 'Show your palm';
          _detectedHand      = HandType.unknown;
          _goodFrames        = 0;
          _dbgRow4 = _dbgRow5 = _dbgConf = 0;
        }); }
        return;
      }

      // Update debug display
      _dbgRow4 = detection.row4;
      _dbgRow5 = detection.row5;
      _dbgConf = detection.confidence;
      _handAngleRad = detection.angleRad;
      _detectedHand = detection.isRight ? HandType.right : HandType.left;

      final targetHand = (_diagStep == _DiagStep.enrollRight ||
              _diagStep == _DiagStep.sybilTest)
          ? HandType.right : HandType.left;

      // Wrong hand detected — show guidance
      if (_detectedHand != targetHand) {
        if (mounted) { setState(() {
          _alignmentProgress = 0;
          _goodFrames        = 0;
          _guidance = _detectedHand == HandType.right
              ? '✋ Wrong hand! Show LEFT palm'
              : '🤚 Wrong hand! Show RIGHT palm';
        }); }
        return;
      }

      // Correct hand — apply stability factor
      final score = _isPhoneStable
          ? detection.confidence
          : detection.confidence * 0.85;

      if (mounted) { setState(() {
        // Smooth visual bar animation (does NOT control capture)
        _alignmentProgress =
            (_alignmentProgress + (score - _alignmentProgress) * 0.4)
                .clamp(0.0, 1.0);
        _guidance = _isPhoneStable
            ? 'Hold still — locking...'
            : 'Hold phone steady';
      }); }

      // Store this frame in good buffer — max 3 frames
      if (score >= 0.50) {
        if (_goodFrameBuffer.length >= 3) _goodFrameBuffer.removeAt(0);
        _goodFrameBuffer.add(bytes);
      }

      // HARD TRIGGER: correct hand, confident, stable, for N consecutive frames
      if (score >= 0.50) {
        _goodFrames++;
        if (_goodFrames >= _goodFramesNeeded && !_captured) {
          _captured = true;
          _stopLoop();
          _triggerCapture();
        }
      } else {
        _goodFrames = 0;
      }

    } on TimeoutException {
      // Camera timed out — safe to ignore, loop will try next frame
    } catch (_) {
      // Any other error — ignore, loop continues
    } finally {
      _scanBusy = false;
    }
  }

  // ── CAPTURE AND PROCESS ───────────────────────────────────────────────────

  Future<void> _triggerCapture() async {
    _setAppState(_AppState.processing, 'Extracting palm DNA...');

    // Torch off during heavy processing
    try { await _cam?.setFlashMode(FlashMode.off); setState(() => _torchOn = false); } catch (_) {}

    if (_goodFrameBuffer.isEmpty) {
      _showSnackbar('No frames captured — try again');
      _resetForNextStep();
      return;
    }

    // Start watchdog — recovers even if Android kills the isolate at OS level
    _watchdog?.cancel();
    _watchdog = Timer(const Duration(seconds: 30), () {
      if (mounted &&
          (_appState == _AppState.processing)) {
        _captured = false;
        _showSnackbar('Processing timed out — please try again');
        _resetForNextStep();
      }
    });

    try {
      final engineResult = await PalmImageEngine.processBurst(
        _goodFrameBuffer,
        handAngleRad: _handAngleRad,
      ).timeout(const Duration(seconds: 25));

      _watchdog?.cancel();

      if (engineResult.creasePixels < 30) {
        _captured = false;
        _showSnackbar('Image too blurry — hold closer and try again');
        _resetForNextStep();
        return;
      }

      final palmResult = await PalmEmbedder.embedInIsolate(
        jpegBytes: engineResult.skeletonImage,
        imgW: 128, imgH: 128,
        wristX: 64,  wristY: 110,
        indexX: 64,  indexY: 20,
        pinkyX: 100, pinkyY: 30,
        thumbX: 25,  thumbY: 50,
        wantEnhanced: true,   // dev screen displays the enhanced 128x128 image
      ).timeout(const Duration(seconds: 15));

      _watchdog?.cancel();
      await _handleStep(palmResult.embedding, engineResult.skeletonImage);

    } on TimeoutException {
      _watchdog?.cancel();
      _captured = false;
      _showSnackbar('Processing timed out — please try again');
      _resetForNextStep();
    } catch (e) {
      _watchdog?.cancel();
      _captured = false;
      _showSnackbar('Error — please try again');
      _resetForNextStep();
    }
  }

  void _showSnackbar(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(
          color: Colors.white, fontWeight: FontWeight.bold)),
      backgroundColor: const Color(0xFF1A2A4A),
      duration: const Duration(seconds: 3),
      behavior: SnackBarBehavior.floating,
    ));
  }

  // ── STEP HANDLER ──────────────────────────────────────────────────────────

  Future<void> _handleStep(List<double> emb, Uint8List enhImg) async {
    _galleryImages.insert(0, _GalleryImage(
        label: _stepLabel, bytes: enhImg, time: DateTime.now()));
    final shortDna = '[${emb.take(3).map((v) => v.toStringAsFixed(3)).join(", ")}...]';
    final normStr  = emb.fold(0.0, (s, v) => s + v * v).toStringAsFixed(4);

    switch (_diagStep) {
      case _DiagStep.enrollLeft:
        _leftEmbedding  = emb;
        _leftEnrollment = FuzzyCommitment.enroll(emb);
        await PalmLocalStore.saveEnrollment(
            _sovId, PalmHandType.left, emb, _leftEnrollment!);
        _results[_DiagStep.enrollLeft] = _StepResult(
            title: 'Step 1 — Left Palm Enrolled', passed: true,
            enhancedImage: enhImg,
            detail: 'Key: ${_leftEnrollment!.masterKeyHash.substring(0, 16)}...\n'
                'DNA: $shortDna  Norm: $normStr');
        break;

      case _DiagStep.enrollRight:
        _rightEnrollment = FuzzyCommitment.enroll(emb,
            existingMasterKey: _leftEnrollment!.masterKeyBits);
        await PalmLocalStore.saveEnrollment(
            _sovId, PalmHandType.right, emb, _rightEnrollment!);
        _results[_DiagStep.enrollRight] = _StepResult(
            title: 'Step 2 — Right Palm Enrolled', passed: true,
            enhancedImage: enhImg,
            detail: 'Same master key: '
                '${_leftEnrollment!.masterKeyHash == _rightEnrollment!.masterKeyHash}\n'
                'DNA: $shortDna  Norm: $normStr');
        break;

      case _DiagStep.rescanLeft:
        final sim = PalmEmbedder.cosineSimilarity(_leftEmbedding!, emb);
        final rec = FuzzyCommitment.recover(
            newEmbedding:      emb,
            helperDataBase64:  _leftEnrollment!.helperDataBase64,
            expectedKeyHash:   _leftEnrollment!.masterKeyHash,
            quantizeThreshold: _leftEnrollment!.quantizeThreshold);
        _results[_DiagStep.rescanLeft] = _StepResult(
            title: 'Step 3 — Recovery Test', passed: rec != null,
            enhancedImage: enhImg,
            detail: 'Similarity: ${(sim * 100).toStringAsFixed(1)}%\n'
                'BCH Recovery: ${rec != null ? "✓ SUCCESS" : "✗ FAILED"}');
        break;

      case _DiagStep.sybilTest:
        final sim = PalmEmbedder.cosineSimilarity(_leftEmbedding!, emb);
        final rec = FuzzyCommitment.recover(
            newEmbedding:      emb,
            helperDataBase64:  _leftEnrollment!.helperDataBase64,
            expectedKeyHash:   _leftEnrollment!.masterKeyHash,
            quantizeThreshold: _leftEnrollment!.quantizeThreshold);
        _results[_DiagStep.sybilTest] = _StepResult(
            title: 'Step 4 — Sybil Resistance', passed: rec == null,
            enhancedImage: enhImg,
            detail: 'Right vs Left — Sim: ${(sim * 100).toStringAsFixed(1)}%\n'
                'Cross-hand recovery: ${rec == null ? "✓ BLOCKED" : "✗ RISK"}');
        break;

      default: break;
    }
    if (mounted) setState(() => _appState = _AppState.result);
  }

  // ── RELAY TEST ─────────────────────────────────────────────────────────────

  Future<void> _runRelayTest() async {
    if (_leftEnrollment == null) return;
    setState(() {
      _relayTesting = true; _relayLog = 'Connecting...';
      _appState = _AppState.relayTest;
    });
    final buf    = StringBuffer();
    bool allPass = true;

    final embJson = jsonEncode(
        _leftEmbedding!.map((v) => double.parse(v.toStringAsFixed(4))).toList());
    try {
      try { await RelayConnector.disconnect(); } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 800));
      await RelayConnector.connect();
      await Future.delayed(const Duration(seconds: 3));

      if (!RelayConnector.isConnected) {
        buf.writeln('✗ Not connected'); allPass = false;
      } else {
        buf.writeln('TEST 1: Duplicate check (before)');
        final d1 = await RelayConnector.sendAndWait(
            request: {'type': 'PALM_DUPLICATE_CHECK', 'embedding': embJson},
            responseType: 'PALM_DUPLICATE_RESULT',
            timeout: const Duration(seconds: 20));
        final t1 = d1 != null && d1['duplicate'] != true;
        buf.writeln(t1
            ? '  ✓ Unique (${((d1['similarity'] ?? 0) * 100).toStringAsFixed(1)}%)'
            : '  ✗ Failed');
        if (!t1) allPass = false;

        await Future.delayed(const Duration(milliseconds: 500));
        buf.writeln('\nTEST 2: Register left palm');
        final r2 = await RelayConnector.sendAndWait(
            request: {
              'type': 'PALM_EMBEDDING_REGISTER', 'sovereign_id': _sovId,
              'embedding': embJson, 'helper_data': _leftEnrollment!.helperDataBase64,
              'key_hash': _leftEnrollment!.masterKeyHash, 'hand_type': 'LEFT',
            },
            responseType: 'PALM_EMBEDDING_RESULT',
            timeout: const Duration(seconds: 15));
        final t2 = r2?['success'] == true;
        buf.writeln(t2 ? '  ✓ Stored' : '  ✗ ${r2?["error"] ?? "null"}');
        if (!t2) allPass = false;

        await Future.delayed(const Duration(milliseconds: 500));
        buf.writeln('\nTEST 3: Duplicate check (after)');
        final d2 = await RelayConnector.sendAndWait(
            request: {'type': 'PALM_DUPLICATE_CHECK', 'embedding': embJson},
            responseType: 'PALM_DUPLICATE_RESULT',
            timeout: const Duration(seconds: 20));
        final t3 = d2?['duplicate'] == true;
        buf.writeln(t3
            ? '  ✓ Detected (${((d2!['similarity'] ?? 0) * 100).toStringAsFixed(1)}%)'
            : '  ✗ Not detected');
        if (!t3) allPass = false;

        await Future.delayed(const Duration(milliseconds: 500));
        buf.writeln('\nTEST 4: BCH recovery from relay');
        final h = await RelayConnector.sendAndWait(
            request: {'type': 'PALM_HELPER_FETCH',
              'sovereign_id': _sovId, 'hand_type': 'LEFT'},
            responseType: 'PALM_HELPER_RESULT',
            timeout: const Duration(seconds: 15));
        if (h?['found'] == true) {
          final rec = FuzzyCommitment.recover(
              newEmbedding: _leftEmbedding!,
              helperDataBase64: h!['helper_data'],
              expectedKeyHash: h['key_hash']);
          buf.writeln(rec != null ? '  ✓ RECOVERY SUCCESS' : '  ✗ BCH failed');
          if (rec == null) allPass = false;
        } else {
          buf.writeln('  ✗ ${h?["error"] ?? "null"}'); allPass = false;
        }
      }
    } catch (e) { buf.writeln('ERROR: $e'); allPass = false; }

    _results[_DiagStep.relayTest] = _StepResult(
        title: 'Step 5 — Relay Tests', passed: allPass, detail: buf.toString());
    if (mounted) { setState(() {
      _relayLog = buf.toString(); _relayTesting = false;
      _appState = _AppState.result;
    }); }
  }

  // ── NAVIGATION ─────────────────────────────────────────────────────────────

  void _nextStep() {
    switch (_diagStep) {
      case _DiagStep.enrollLeft:
        setState(() => _diagStep = _DiagStep.enrollRight);
        _resetForNextStep();
        break;
      case _DiagStep.enrollRight:
        setState(() => _diagStep = _DiagStep.rescanLeft);
        _resetForNextStep();
        break;
      case _DiagStep.rescanLeft:
        setState(() => _diagStep = _DiagStep.sybilTest);
        _resetForNextStep();
        break;
      case _DiagStep.sybilTest:
        setState(() => _diagStep = _DiagStep.relayTest);
        _runRelayTest();
        break;
      case _DiagStep.relayTest:
        setState(() { _diagStep = _DiagStep.summary; _appState = _AppState.summary; });
        break;
      case _DiagStep.summary:
        _fullReset();
        break;
    }
  }

  void _fullReset() {
    PalmLocalStore.clear(_sovId);
    _stopLoop();
    setState(() {
      _diagStep = _DiagStep.enrollLeft;
      _leftEmbedding = null; _leftEnrollment  = null;
      _rightEnrollment = null;
      _results.clear(); _relayLog = '';
    });
    _resetForNextStep();
  }

  void _retryCapture() {
    _captured = false;
    _resetForNextStep();
  }

  void _setAppState(_AppState s, String msg) {
    if (!mounted) return;
    setState(() { _appState = s; _guidance = msg; });
  }

  // ── STRING HELPERS ─────────────────────────────────────────────────────────

  String get _stepLabel {
    switch (_diagStep) {
      case _DiagStep.enrollLeft:  return 'STEP 1 / 6 — ENROLL LEFT PALM';
      case _DiagStep.enrollRight: return 'STEP 2 / 6 — ENROLL RIGHT PALM';
      case _DiagStep.rescanLeft:  return 'STEP 3 / 6 — RECOVERY TEST';
      case _DiagStep.sybilTest:   return 'STEP 4 / 6 — SYBIL RESISTANCE';
      case _DiagStep.relayTest:   return 'STEP 5 / 6 — RELAY TEST';
      case _DiagStep.summary:     return 'STEP 6 / 6 — SUMMARY';
    }
  }

  String get _nextLabel {
    switch (_diagStep) {
      case _DiagStep.enrollLeft:  return 'CONTINUE — Enroll Right Palm →';
      case _DiagStep.enrollRight: return 'CONTINUE — Test Recovery →';
      case _DiagStep.rescanLeft:  return 'CONTINUE — Sybil Resistance →';
      case _DiagStep.sybilTest:   return 'CONTINUE — Run Relay Tests →';
      case _DiagStep.relayTest:   return 'CONTINUE — View Summary →';
      case _DiagStep.summary:     return 'Run Full Test Again';
    }
  }

  String get _targetSide =>
      (_diagStep == _DiagStep.enrollRight || _diagStep == _DiagStep.sybilTest)
          ? 'RIGHT' : 'LEFT';

  bool get _wrongHand =>
      _detectedHand != HandType.unknown &&
      _detectedHand != (_targetSide == 'RIGHT' ? HandType.right : HandType.left);

  Widget _badge(String label, Color color, IconData icon, {VoidCallback? onTap}) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.only(left: 6),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: color.withValues(alpha: 0.3))),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(fontSize: 11, color: color,
                fontWeight: FontWeight.bold)),
          ]),
        ),
      );

  void _openGallery(_DiagStep step) {
    final r = _results[step];
    if (r?.enhancedImage == null) return;
    Navigator.push(context, MaterialPageRoute(
        builder: (_) => PalmGalleryScreen(
            stepTitle: r!.title, images: _galleryImages)));
  }

  // ── BUILD ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final sw = MediaQuery.of(context).size.width;
    final sh = MediaQuery.of(context).size.height;
    final frameColor = _wrongHand ? Colors.redAccent
        : _alignmentProgress > 0.7 ? Colors.greenAccent
        : _alignmentProgress > 0.3 ? Colors.amberAccent
        : Colors.redAccent;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [

        // Camera preview
        if (_cam != null && _cam!.value.isInitialized)
          Positioned.fill(
            child: FittedBox(fit: BoxFit.cover,
              child: SizedBox(
                  width:  _cam!.value.previewSize?.height ?? sw,
                  height: _cam!.value.previewSize?.width  ?? sh,
                  child:  CameraPreview(_cam!))),
          ),

        // Step header
        Positioned(top: 0, left: 0, right: 0,
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 50, 16, 14),
            color: Colors.black45,
            child: Row(children: [
              const Icon(Icons.fingerprint, color: _gold, size: 20),
              const SizedBox(width: 8),
              Expanded(child: Text(_stepLabel,
                  key: ValueKey(_diagStep),
                  style: const TextStyle(color: Colors.white,
                      fontWeight: FontWeight.bold, fontSize: 12))),
              _badge(_torchOn ? 'TORCH' : 'OFF',
                  _torchOn ? Colors.greenAccent : Colors.white38,
                  Icons.flashlight_on, onTap: _toggleTorch),
              _badge(_targetSide, _gold, Icons.back_hand),
              if (_detectedHand != HandType.unknown)
                _badge(_detectedHand == HandType.right ? '✋ R' : '🤚 L',
                    _wrongHand ? Colors.redAccent : Colors.greenAccent,
                    Icons.back_hand),
            ]),
          ),
        ),

        // Scanning HUD
        if (_appState == _AppState.scanning) ...[
          Positioned.fill(child: Container(color: Colors.black.withValues(alpha: 0.45))),

          Center(
            child: Container(
              width: sw * 0.85, height: sh * 0.55,
              decoration: BoxDecoration(
                  border: Border.all(
                      color: frameColor.withValues(alpha:
                          _alignmentProgress > 0.6 ? _pulseAnim.value : 1.0),
                      width: 4),
                  borderRadius: BorderRadius.circular(40)),
              child: Stack(alignment: Alignment.center, children: [
                Opacity(opacity: 0.20,
                  child: Transform.translate(offset: const Offset(0, 80),
                    child: Transform.scale(
                      scaleX: _targetSide == 'RIGHT' ? -1 : 1,
                      child: const Icon(Icons.pan_tool_outlined,
                          size: 300, color: Colors.white)))),
                // Wrong hand warning inside frame
                if (_wrongHand)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 14),
                    decoration: BoxDecoration(
                        color: Colors.red.withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(16)),
                    child: Text(_guidance,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white,
                            fontSize: 18, fontWeight: FontWeight.w900)),
                  ),
              ]),
            ),
          ),

          // Guidance pill
          if (!_wrongHand)
            Positioned(bottom: sh * 0.18, left: 20, right: 20,
              child: Center(child: AnimatedBuilder(
                animation: _pulseAnim,
                builder: (_, __) => Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 24, vertical: 12),
                  decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: frameColor.withValues(alpha:0.5))),
                  child: Text(_guidance, textAlign: TextAlign.center,
                      style: TextStyle(color: frameColor, fontSize: 17,
                          fontWeight: FontWeight.bold)),
                ),
              )),
            ),

          // Progress + debug bar at bottom
          Positioned(bottom: 0, left: 0, right: 0,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              // Debug panel — raw AI numbers
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                color: Colors.black87,
                child: Text(
                  'RAW → Row4(cls0): ${_dbgRow4.toStringAsFixed(2)} | '
                  'Row5(cls1): ${_dbgRow5.toStringAsFixed(2)} | '
                  'Conf: ${_dbgConf.toStringAsFixed(2)} | '
                  '${_detectedHand == HandType.unknown ? "---" : _detectedHand == HandType.right ? "RIGHT ✋" : "LEFT 🤚"}',
                  style: const TextStyle(color: Colors.greenAccent,
                      fontSize: 10, fontFamily: 'monospace'),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('AI CONFIDENCE LOCK', style: TextStyle(
                        color: Colors.white38, fontSize: 10, letterSpacing: 1)),
                    Text('${(_alignmentProgress * 100).toInt()}%',
                        style: TextStyle(color: frameColor, fontSize: 11,
                            fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
              AnimatedBuilder(animation: _pulseAnim,
                builder: (_, __) => LinearProgressIndicator(
                  value: _alignmentProgress, minHeight: 6,
                  backgroundColor: Colors.white12,
                  valueColor: AlwaysStoppedAnimation<Color>(frameColor),
                ),
              ),
              const SizedBox(height: 28),
            ]),
          ),
        ],

        // Processing spinner
        if (_appState == _AppState.processing || _appState == _AppState.relayTest)
          Positioned.fill(child: Container(color: Colors.black87,
            child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
              const CircularProgressIndicator(color: _teal),
              const SizedBox(height: 24),
              Text(_relayTesting ? 'Running relay tests...' : _guidance,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 18)),
            ])),
          )),

        // Error screen
        if (_appState == _AppState.error)
          Positioned.fill(child: Container(color: _bg.withValues(alpha: 0.95),
            child: Column(children: [
              const SizedBox(height: 80),
              const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
              const SizedBox(height: 16),
              Expanded(child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: SelectableText(_guidance, style: const TextStyle(
                      color: Colors.greenAccent, fontSize: 12,
                      fontFamily: 'monospace')))),
              Padding(padding: const EdgeInsets.all(24),
                child: ElevatedButton.icon(
                  onPressed: _retryCapture,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                  style: ElevatedButton.styleFrom(backgroundColor: _gold,
                      foregroundColor: Colors.black,
                      minimumSize: const Size(double.infinity, 50)),
                )),
            ]),
          )),

        // Result panel
        if (_appState == _AppState.result)
          Align(alignment: Alignment.bottomCenter,
            child: Container(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 36),
              decoration: const BoxDecoration(color: _bg,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (_results[_diagStep] != null) ...[
                  Row(children: [
                    Icon(_results[_diagStep]!.passed
                        ? Icons.check_circle : Icons.cancel,
                        color: _results[_diagStep]!.passed
                            ? Colors.greenAccent : Colors.redAccent, size: 22),
                    const SizedBox(width: 10),
                    Expanded(child: Text(_results[_diagStep]!.title,
                        style: TextStyle(
                            color: _results[_diagStep]!.passed
                                ? Colors.greenAccent : Colors.redAccent,
                            fontSize: 16, fontWeight: FontWeight.bold))),
                  ]),
                  const SizedBox(height: 10),
                  Text(_results[_diagStep]!.detail,
                      style: const TextStyle(color: Colors.white70,
                          fontSize: 13, height: 1.5)),
                ],
                if (_diagStep == _DiagStep.relayTest && _relayLog.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Container(width: double.infinity, padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: const Color(0xFF0D1F35),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.white12)),
                    child: Text(_relayLog, style: const TextStyle(
                        color: Colors.white70, fontSize: 10,
                        fontFamily: 'monospace'))),
                ],
                const SizedBox(height: 20),
                ElevatedButton(onPressed: _nextStep,
                  style: ElevatedButton.styleFrom(backgroundColor: _gold,
                      minimumSize: const Size(double.infinity, 56),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12))),
                  child: Text(_nextLabel, style: const TextStyle(
                      color: Colors.black, fontWeight: FontWeight.bold,
                      fontSize: 15)),
                ),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(child: TextButton.icon(
                      onPressed: _retryCapture,
                      icon: const Icon(Icons.refresh,
                          color: Colors.white38, size: 16),
                      label: const Text('Retry Scan',
                          style: TextStyle(color: Colors.white38)))),
                  if (_results[_diagStep]?.enhancedImage != null)
                    Expanded(child: TextButton.icon(
                        onPressed: () => _openGallery(_diagStep),
                        icon: const Icon(Icons.photo_library,
                            color: _teal, size: 16),
                        label: const Text('View Gallery',
                            style: TextStyle(color: _teal)))),
                ]),
              ]),
            ),
          ),

        // Summary
        if (_appState == _AppState.summary)
          Positioned.fill(child: Container(color: _bg,
            padding: const EdgeInsets.all(20),
            child: Column(children: [
              const SizedBox(height: 60),
              const Text('DIAGNOSTIC SUMMARY', style: TextStyle(color: _gold,
                  fontSize: 20, fontWeight: FontWeight.w900, letterSpacing: 2)),
              const SizedBox(height: 6),
              Text(_results.values.every((r) => r.passed)
                  ? 'ALL TESTS PASSED ✓' : 'SOME TESTS FAILED',
                  style: TextStyle(
                      color: _results.values.every((r) => r.passed)
                          ? Colors.greenAccent : Colors.redAccent,
                      fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 20),
              Expanded(child: ListView(
                children: _results.entries
                    .where((e) => e.key != _DiagStep.summary)
                    .map((e) => Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                          color: e.value.passed
                              ? const Color(0xFF0D2A1A) : const Color(0xFF2A0D0D),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: e.value.passed
                              ? Colors.greenAccent.withValues(alpha: 0.4)
                              : Colors.redAccent.withValues(alpha: 0.4))),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              Icon(e.value.passed
                                  ? Icons.check_circle : Icons.cancel,
                                  color: e.value.passed
                                      ? Colors.greenAccent : Colors.redAccent,
                                  size: 16),
                              const SizedBox(width: 8),
                              Text(e.value.title, style: TextStyle(
                                  color: e.value.passed
                                      ? Colors.greenAccent : Colors.redAccent,
                                  fontSize: 12, fontWeight: FontWeight.bold)),
                            ]),
                            const SizedBox(height: 6),
                            Text(e.value.detail, style: const TextStyle(
                                color: Colors.white54, fontSize: 10)),
                          ]),
                    )).toList(),
              )),
              ElevatedButton.icon(onPressed: _fullReset,
                  icon: const Icon(Icons.refresh, size: 20),
                  label: const Text('Run Full Test Again'),
                  style: ElevatedButton.styleFrom(backgroundColor: _gold,
                      foregroundColor: Colors.black,
                      minimumSize: const Size(double.infinity, 52),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)))),
            ]),
          )),

        // Close
        Positioned(top: 52, left: 12,
          child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white70, size: 22),
              onPressed: () => Navigator.pop(context))),

      ]),
    );
  }
}

class _GalleryImage {
  final String label; final Uint8List bytes; final DateTime time;
  const _GalleryImage({required this.label, required this.bytes, required this.time});
}

class _StepResult {
  final String title, detail; final bool passed; final Uint8List? enhancedImage;
  const _StepResult({required this.title, required this.detail,
      required this.passed, this.enhancedImage});
}
