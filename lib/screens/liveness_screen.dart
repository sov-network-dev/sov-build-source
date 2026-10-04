// lib/screens/liveness_screen.dart
// ─────────────────────────────────────────────────────────────────────────────
// FACE LIVENESS CHECK — bundled BlazeFace detector + front camera
//
// Uses the BlazeFace TFLite model that already ships in the app to verify the
// user is a real person. A random challenge (turn / move / closer / back) must
// be completed with 1 passing frame within 20 seconds.
//
// ML Kit was removed 2026-09-30. google_mlkit_face_detection is a proprietary
// Google Play Services dependency, and F-Droid refuses to build anything that
// carries one — F-Droid being the one Android channel that asks no operator for
// a government ID. blazeface_short.tflite is already declared in pubspec assets
// and already ships in the APK, so this DROPS a dependency rather than adding
// one.
//
// ⚠️ BUT DO NOT READ THAT AS "PROVEN". The BlazeFace branch here was written for
// desktop and has never executed: pubspec.lock resolves camera_android,
// camera_avfoundation and camera_web and NO camera_windows/linux, so
// availableCameras() has no implementation on desktop and this screen could
// never obtain a frame there. The desktop app is restore-only in any case
// (main.dart: "restore-only (no palm enrollment)"). So what was a dead branch is
// now the ONLY liveness path on mobile, and it needs a real-device pass before
// release — see _yawPositiveMeansLeft below.
// No auto-pass under any circumstances.
// ─────────────────────────────────────────────────────────────────────────────
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../sov_node_sdk/face_engine.dart';
import '../sov_node_sdk/relay_connector.dart';

class LivenessScreen extends StatefulWidget {
  final String sovereignId;
  const LivenessScreen({
    super.key,
    required this.sovereignId,
  });

  @override
  State<LivenessScreen> createState() => _LivenessScreenState();
}

class _LivenessScreenState extends State<LivenessScreen> {

  static const _navy   = Color(0xFF0A1628);
  static const _gold   = Color(0xFFB8960C);
  static const _cardBg = Color(0xFF0D1F3A);

  // ── Camera ─────────────────────────────────────────────────────────────────
  CameraController? _cam;
  bool _cameraReady = false;

  // ── Yaw sign convention ────────────────────────────────────────────────────
  // FaceDetection.yawRatio is positive when the nose sits toward the LEFT of
  // the IMAGE. Which physical turn that corresponds to is DERIVED, not guessed,
  // from the ML Kit implementation this replaced — which the king passed on a
  // real phone during demo-citizen enrolment, so it is field evidence:
  //
  //   1. The shipped, working code required `headEulerAngleY > 15` for
  //      TURN_LEFT (see backups/liveness_screen.dart.bak_fdroid_20260930).
  //   2. ML Kit defines that value: "Positive euler y is when the face turns
  //      toward the right side of the image that is being processed."
  //   3. So a successful TURN LEFT put the face toward the IMAGE's RIGHT, which
  //      moves the nose right of the eye midpoint — a NEGATIVE yawRatio.
  //
  // Hence false. This holds because both readers see the same frame the same
  // way up: ML Kit applied EXIF orientation, and FaceEngine now does too via
  // _decodeUpright(). If that ever diverges, this derivation breaks with it.
  //
  // Still worth one device confirmation, since it is a derivation rather than a
  // measurement — but if TURN LEFT only passes when you turn right, this single
  // constant is the whole fix and nothing else depends on the convention.
  static const bool _yawPositiveMeansLeft = false;

  // How far the nose must travel from its own starting position, measured in
  // interocular widths so distance from the camera cancels out. ~0.12 is about
  // a 22° turn, a little stricter than the 15° ML Kit was asked for.
  static const double _kTurnRatio = 0.12;

  // ── FACE-LOCK ──────────────────────────────────────────────────────────────
  // The 192-d face embedding computed from the frame that PASSES the challenge.
  // Returned to the enrollment flow (pop result map) and sent to the node for
  // one-human-one-identity dedup. Only the vector — never the image.
  List<double>? _faceEmbedding;

  // Challenge baseline, taken from the FIRST detection: box centre-x, box
  // height, and resting yaw. Every challenge is judged as movement away from
  // this, never as an absolute pose — which is what makes it work across faces
  // that are not symmetric and cameras that are not square on.
  double? _baseCx, _baseH, _baseYaw;

  // ── Challenge state ────────────────────────────────────────────────────────
  late final String _challengeType;   // see _challenges below
  late final String _challengeLabel;  // display text
  int  _consecutiveFrames = 0;

  // ── Scan state ─────────────────────────────────────────────────────────────
  bool   _scanRunning  = false;
  bool   _submitting   = false;
  bool   _timedOut     = false;
  int    _secondsLeft  = 20;
  String _error        = '';

  // ── Timers ─────────────────────────────────────────────────────────────────
  Timer? _frameTimer;
  Timer? _countdownTimer;

  // ── Challenge definitions ──────────────────────────────────────────────────
  // ONE pool for every platform now that BlazeFace drives all of them, so a
  // phone and a desktop are held to the same test. SMILE is gone: a detector
  // reports where a face is, not what it is doing, and an expression cannot be
  // recovered from keypoints. The head turn survives on keypoint geometry, and
  // mobile gains the three movement challenges it never had — five to draw
  // from instead of three.
  static const _challenges = [
    {'type': 'TURN_LEFT',   'label': 'TURN LEFT'},
    {'type': 'TURN_RIGHT',  'label': 'TURN RIGHT'},
    {'type': 'MOVE_SIDE',   'label': 'MOVE SIDEWAYS'},
    {'type': 'COME_CLOSER', 'label': 'COME CLOSER'},
    {'type': 'MOVE_BACK',   'label': 'MOVE BACK'},
  ];

  // ═══════════════════════════════════════════════════════════════════════════
  // LIFECYCLE
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  void initState() {
    super.initState();

    // Use Random.secure(): a plain Random() is clock-seeded, so re-entering
    // enrollment quickly after a failure re-seeds from ~the same millisecond and
    // keeps drawing the SAME challenge (the "always TURN LEFT" the king saw).
    // A secure RNG is well-seeded every time → genuine variety, and it's the
    // right choice for an anti-spoof liveness pick anyway.
    final c = _challenges[Random.secure().nextInt(_challenges.length)];
    _challengeType  = c['type']!;
    _challengeLabel = c['label']!;

    // FACE-LOCK: the embedding model, and now the BlazeFace detector too, on
    // every platform — it drives the challenge everywhere, which is what let
    // ML Kit go.
    FaceEngine.loadModels(withDetector: true);

    _initCamera();
  }

  @override
  void dispose() {
    _frameTimer?.cancel();
    _countdownTimer?.cancel();
    _cam?.dispose(); // safe — _completeLiveness() sets _cam = null before pop
    super.dispose();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // CAMERA INIT
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _initCamera() async {
    try {
      final cams = await availableCameras();
      final front = cams.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cams.first,
      );
      _cam = CameraController(
        front,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await _cam!.initialize();
      if (!mounted) return;
      setState(() => _cameraReady = true);
      _startScan();
    } catch (e) {
      if (mounted) setState(() => _error = 'Camera failed to start: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // SCAN LOOP
  // ═══════════════════════════════════════════════════════════════════════════

  void _startScan() {
    _frameTimer?.cancel();
    _countdownTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _scanRunning       = true;
      _consecutiveFrames = 0;
      _secondsLeft       = 20;
      _timedOut          = false;
      _error             = '';
    });

    // Process a frame every 400 ms
    _frameTimer = Timer.periodic(
      const Duration(milliseconds: 400),
      (_) => _processFrame(),
    );

    // 20-second countdown
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      setState(() {
        if (_secondsLeft > 0) _secondsLeft--;
        if (_secondsLeft == 0) {
          t.cancel();
          _frameTimer?.cancel();
          _scanRunning = false;
          _timedOut    = true;
        }
      });
    });
  }

  bool get _isTurn =>
      _challengeType == 'TURN_LEFT' || _challengeType == 'TURN_RIGHT';

  Future<void> _processFrame() async {
    if (!_scanRunning || _submitting) return;
    if (_cam == null || !_cam!.value.isInitialized) return;

    try {
      final photo = await _cam!.takePicture()
          .timeout(const Duration(seconds: 3));

      bool conditionMet = false;
      ui.Rect? faceBoxNorm;   // normalised 0–1 box of the detected face

      // ── One path, every platform: the bundled BlazeFace detector ────────
      final det = await FaceEngine.detectFace(photo.path);
      if (det == null) {
        try { await File(photo.path).delete(); } catch (_) {}
        if (mounted && _scanRunning) setState(() => _consecutiveFrames = 0);
        return;
      }
      faceBoxNorm = det.box;

      final cx  = det.box.left + det.box.width / 2;
      final h   = det.box.height;
      final yaw = det.yawRatio;   // null when keypoints are unusable

      if (_baseCx == null || _baseH == null) {
        // First detection = the baseline the citizen must move away from.
        // A turn challenge additionally needs a resting yaw, so if the
        // keypoints were not usable on this frame we do not fix the baseline
        // yet — better to spend a frame than to anchor on a bad reading.
        if (_isTurn && yaw == null) {
          try { await File(photo.path).delete(); } catch (_) {}
          return;
        }
        _baseCx = cx; _baseH = h; _baseYaw = yaw;
      } else if (_isTurn) {
        if (yaw != null && _baseYaw != null) {
          // Signed travel of the nose away from where it started.
          final moved = yaw - _baseYaw!;
          final towardImageLeft =
              (_challengeType == 'TURN_LEFT') == _yawPositiveMeansLeft;
          conditionMet =
              towardImageLeft ? moved >= _kTurnRatio : moved <= -_kTurnRatio;
        }
      } else if (_challengeType == 'MOVE_SIDE') {
        conditionMet = (cx - _baseCx!).abs() >= 0.10;
      } else if (_challengeType == 'COME_CLOSER') {
        conditionMet = h >= _baseH! * 1.22;
      } else if (_challengeType == 'MOVE_BACK') {
        conditionMet = h <= _baseH! * 0.82;
      }

      if (!mounted || !_scanRunning) {
        try { await File(photo.path).delete(); } catch (_) {}
        return;
      }

      if (conditionMet) {
        // FACE-LOCK: compute the embedding from THIS passing frame before the
        // temp file is deleted. Best-effort — a null embedding never blocks
        // liveness (the node treats it as an old client).
        try {
          _faceEmbedding = await FaceEngine.embedFromJpeg(
            photo.path, boxNorm: faceBoxNorm,
          );
        } catch (_) { _faceEmbedding = null; }
        try { await File(photo.path).delete(); } catch (_) {}

        final next = _consecutiveFrames + 1;
        if (mounted) setState(() => _consecutiveFrames = next);
        if (next >= 1) {
          _frameTimer?.cancel();
          _countdownTimer?.cancel();
          if (mounted) setState(() { _scanRunning = false; });
          await _submitLiveness();
        }
      } else {
        try { await File(photo.path).delete(); } catch (_) {}
        if (mounted) setState(() => _consecutiveFrames = 0);
      }
    } on TimeoutException {
      // Safe — retry next tick
    } catch (_) {
      // Frame errors are non-fatal
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // SUBMIT
  // ═══════════════════════════════════════════════════════════════════════════

  // Dispose front camera fully before handing control back to enrollment.
  // Called by _submitLiveness() so the rear camera can initialise without
  // a hardware race condition.
  Future<void> _completeLiveness(String proofHash) async {
    if (!mounted) return;

    // Stop camera BEFORE leaving screen
    try {
      if (_cam != null) {
        if (_cam!.value.isStreamingImages) {
          await _cam!.stopImageStream();
        }
        await _cam!.dispose();
        _cam = null;
      }
    } catch (e) {
      debugPrint('Liveness camera dispose: $e');
    }

    // Hardware release delay — allows Android camera HAL to fully close
    await Future.delayed(const Duration(milliseconds: 500));

    if (!mounted) return;

    // Return proofHash + FACE-LOCK embedding via pop result. Old callers that
    // only expect a String result must be updated to handle the Map (home
    // screen's liveness pill ignores the result entirely — safe).
    // The await Navigator.push in enrollment only completes AFTER the full
    // pop animation finishes — so the rear camera initialises in a clean state.
    if (mounted) {
      Navigator.pop(context, <String, dynamic>{
        'proof': proofHash,
        'face':  _faceEmbedding,
      });
    }
  }

  Future<void> _submitLiveness() async {
    if (!mounted) return;
    setState(() { _submitting = true; _error = ''; });

    try {
      final ts    = DateTime.now().millisecondsSinceEpoch;
      // Always compute a local proof hash (used as enrollment receipt)
      final proof = sha256.convert(
        utf8.encode(_challengeType + ts.toString()),
      ).toString();

      // Skip relay call if sovereignId is empty — liveness runs BEFORE palm
      // scan in the v1 enrollment flow, so no sovId is available yet.
      if (widget.sovereignId.isNotEmpty) {
        final relayProof = sha256.convert(
          utf8.encode(widget.sovereignId + _challengeType + ts.toString()),
        ).toString();

        if (!RelayConnector.isConnected) {
          await RelayConnector.connect();
          await Future.delayed(const Duration(seconds: 1));
        }

        await RelayConnector.submitLivenessCheck(widget.sovereignId, relayProof);
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('last_liveness_check', ts);

      if (mounted) {
        setState(() => _submitting = false);
        _frameTimer?.cancel();
        _countdownTimer?.cancel();
        await _completeLiveness(proof);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error      = 'Verification failed — trying again';
      });
      await Future.delayed(const Duration(seconds: 1));
      if (mounted) _startScan();
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // BUILD
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _navy,
      appBar: AppBar(
        backgroundColor: _navy,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded, color: Colors.white54),
          onPressed: () => Navigator.pop(context, false),
        ),
        title: const Text('Proof of Life',
            style: TextStyle(
                color: Color(0xFFB8960C),
                fontWeight: FontWeight.bold,
                fontSize: 18)),
      ),
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    if (_error.isNotEmpty && !_scanRunning && !_timedOut && !_submitting) {
      return _buildErrorView();
    }
    if (!_cameraReady) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFFB8960C)),
      );
    }
    if (_submitting) {
      return _buildSubmitting();
    }
    return _buildScanUI();
  }

  Widget _buildScanUI() {
    final bool faceActive = _consecutiveFrames > 0;
    return Column(
      children: [
        // ── Challenge instruction ──────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
          child: Column(
            children: [
              const Text('CHALLENGE',
                  style: TextStyle(
                      color: Colors.white38, fontSize: 11, letterSpacing: 2)),
              const SizedBox(height: 8),
              // Large gold label + directional arrow
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // TURN LEFT → arrow points LEFT (←), placed on the left of the label.
                  if (_challengeType == 'TURN_LEFT') ...[
                    const Icon(Icons.arrow_back_rounded,
                        color: Color(0xFFB8960C), size: 36),
                    const SizedBox(width: 8),
                  ],
                  Text(
                    _challengeLabel,
                    style: const TextStyle(
                      color: Color(0xFFB8960C),
                      fontSize: 34,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 4,
                    ),
                  ),
                  // TURN RIGHT → arrow points RIGHT (→), placed on the right of the label.
                  if (_challengeType == 'TURN_RIGHT') ...[
                    const SizedBox(width: 8),
                    const Icon(Icons.arrow_forward_rounded,
                        color: Color(0xFFB8960C), size: 36),
                  ],
                  // The movement challenges now appear on mobile too, so they
                  // get an icon each rather than a bare label.
                  if (_challengeType == 'MOVE_SIDE') ...[
                    const SizedBox(width: 8),
                    const Icon(Icons.swap_horiz_rounded,
                        color: Color(0xFFB8960C), size: 36),
                  ],
                  if (_challengeType == 'COME_CLOSER') ...[
                    const SizedBox(width: 8),
                    const Icon(Icons.zoom_in_rounded,
                        color: Color(0xFFB8960C), size: 36),
                  ],
                  if (_challengeType == 'MOVE_BACK') ...[
                    const SizedBox(width: 8),
                    const Icon(Icons.zoom_out_rounded,
                        color: Color(0xFFB8960C), size: 36),
                  ],
                ],
              ),
              const SizedBox(height: 4),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: _timedOut
                    ? const Text("Time's up — tap Retry",
                        key: ValueKey('timeout'),
                        style: TextStyle(color: Colors.redAccent, fontSize: 13))
                    : Text('$_secondsLeft seconds remaining',
                        key: ValueKey(_secondsLeft),
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 12)),
              ),
            ],
          ),
        ),

        // ── Camera preview ─────────────────────────────────────────────────
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 4),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _buildCameraPreview(),

                  // Face-detected border overlay
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: faceActive
                            ? Colors.greenAccent
                            : Colors.white24,
                        width: faceActive ? 3 : 1,
                      ),
                    ),
                  ),

                  // Timeout overlay with Retry button
                  if (_timedOut)
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Center(
                        child: ElevatedButton.icon(
                          onPressed: _startScan,
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text('Retry',
                              style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _gold,
                            foregroundColor: Colors.black,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),

        // ── Progress dots ──────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 12, 32, 24),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(1, (i) => AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                  width: 28, height: 28,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i < _consecutiveFrames
                        ? Colors.greenAccent
                        : Colors.white12,
                    border: Border.all(
                      color: i < _consecutiveFrames
                          ? Colors.greenAccent
                          : Colors.white24,
                    ),
                  ),
                  child: i < _consecutiveFrames
                      ? const Icon(Icons.check,
                          color: Colors.black, size: 16)
                      : null,
                )),
              ),
              const SizedBox(height: 10),
              Text(
                faceActive
                    ? 'Hold position... ($_consecutiveFrames / 1)'
                    : _timedOut
                        ? ''
                        : 'Centre your face and perform the action',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: faceActive ? Colors.greenAccent : Colors.white54,
                  fontSize: 13,
                ),
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
            child: CircularProgressIndicator(color: Color(0xFFB8960C))),
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

  Widget _buildSubmitting() => const Center(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        CircularProgressIndicator(color: Color(0xFFB8960C)),
        SizedBox(height: 24),
        Text('Verifying...',
            style: TextStyle(color: Colors.white54, fontSize: 16)),
      ],
    ),
  );

  Widget _buildErrorView() => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
          const SizedBox(height: 16),
          Text(_error,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, fontSize: 14)),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: _initCamera,
            style: ElevatedButton.styleFrom(
              backgroundColor: _gold,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Try Again',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    ),
  );
}
