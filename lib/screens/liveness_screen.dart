// lib/screens/liveness_screen.dart
// ─────────────────────────────────────────────────────────────────────────────
// FACE LIVENESS CHECK — ML Kit + front camera
//
// Uses google_mlkit_face_detection to verify the user is a real person.
// A random challenge (TURN LEFT / TURN RIGHT / SMILE) must be
// completed with 1 passing frame within 20 seconds.
// No auto-pass under any circumstances.
// ─────────────────────────────────────────────────────────────────────────────
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:crypto/crypto.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
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

  // ── Platform ───────────────────────────────────────────────────────────────
  // ML Kit is Android/iOS-only. On desktop (Windows full node) the challenge
  // runs on the cross-platform BlazeFace detector from FaceEngine instead —
  // before this, Windows liveness could never pass at all.
  static final bool _desktop =
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  // ── ML Kit (mobile only — null on desktop) ─────────────────────────────────
  FaceDetector? _detector;

  // ── FACE-LOCK ──────────────────────────────────────────────────────────────
  // The 192-d face embedding computed from the frame that PASSES the challenge.
  // Returned to the enrollment flow (pop result map) and sent to the node for
  // one-human-one-identity dedup. Only the vector — never the image.
  List<double>? _faceEmbedding;

  // Desktop challenge baseline (box centre-x + box height from first detection)
  double? _baseCx, _baseH;

  // ── Challenge state ────────────────────────────────────────────────────────
  late final String _challengeType;   // 'TURN_LEFT' | 'TURN_RIGHT' | 'SMILE'
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
  static const _challenges = [
    {'type': 'TURN_LEFT',  'label': 'TURN LEFT'},
    {'type': 'TURN_RIGHT', 'label': 'TURN RIGHT'},
    {'type': 'SMILE',      'label': 'SMILE'},
  ];
  // Desktop challenges use box geometry (BlazeFace gives no yaw/smile):
  static const _desktopChallenges = [
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

    // Random challenge — desktop uses geometry challenges (no ML Kit there).
    // Use Random.secure(): a plain Random() is clock-seeded, so re-entering
    // enrollment quickly after a failure re-seeds from ~the same millisecond and
    // keeps drawing the SAME challenge (the "always TURN LEFT" the king saw).
    // A secure RNG is well-seeded every time → genuine variety, and it's the
    // right choice for an anti-spoof liveness pick anyway.
    final pool = _desktop ? _desktopChallenges : _challenges;
    final c = pool[Random.secure().nextInt(pool.length)];
    _challengeType  = c['type']!;
    _challengeLabel = c['label']!;

    // ML Kit detector — mobile only (no Windows/desktop implementation)
    if (!_desktop) {
      _detector = FaceDetector(
        options: FaceDetectorOptions(
          enableClassification: true,
          enableTracking:       false,
          performanceMode:      FaceDetectorMode.fast,
        ),
      );
    }

    // FACE-LOCK: embedding model on all platforms; BlazeFace detector on
    // desktop, where it also drives the challenge.
    FaceEngine.loadModels(withDetector: _desktop);

    _initCamera();
  }

  @override
  void dispose() {
    _frameTimer?.cancel();
    _countdownTimer?.cancel();
    _detector?.close();
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

  Future<void> _processFrame() async {
    if (!_scanRunning || _submitting) return;
    if (_cam == null || !_cam!.value.isInitialized) return;

    try {
      final photo = await _cam!.takePicture()
          .timeout(const Duration(seconds: 3));

      bool conditionMet = false;
      ui.Rect? faceBoxNorm;   // normalised 0–1 box of the detected face

      if (_desktop) {
        // ── Desktop path — BlazeFace geometry challenge ────────────────────
        final det = await FaceEngine.detectFace(photo.path);
        if (det == null) {
          try { await File(photo.path).delete(); } catch (_) {}
          if (mounted && _scanRunning) setState(() => _consecutiveFrames = 0);
          return;
        }
        faceBoxNorm = det.box;
        final cx = det.box.left + det.box.width / 2;
        final h  = det.box.height;
        if (_baseCx == null || _baseH == null) {
          // First detection = the baseline the citizen must move away from
          _baseCx = cx; _baseH = h;
        } else if (_challengeType == 'MOVE_SIDE') {
          conditionMet = (cx - _baseCx!).abs() >= 0.10;
        } else if (_challengeType == 'COME_CLOSER') {
          conditionMet = h >= _baseH! * 1.22;
        } else if (_challengeType == 'MOVE_BACK') {
          conditionMet = h <= _baseH! * 0.82;
        }
      } else {
        // ── Mobile path — ML Kit yaw/smile challenge (unchanged) ───────────
        final inputImage = InputImage.fromFilePath(photo.path);
        final faces = await _detector!.processImage(inputImage);

        if (faces.isEmpty) {
          try { await File(photo.path).delete(); } catch (_) {}
          if (mounted && _scanRunning) setState(() => _consecutiveFrames = 0);
          return;
        }

        final face = faces.first;
        final double yaw = face.headEulerAngleY ?? 0;

        if (_challengeType == 'TURN_LEFT') {
          conditionMet = yaw > 15;
        } else if (_challengeType == 'TURN_RIGHT') {
          conditionMet = yaw < -15;
        } else if (_challengeType == 'SMILE') {
          conditionMet = face.smilingProbability != null &&
              face.smilingProbability! > 0.8;
        }

        // ML Kit boundingBox is in pixel coords — FaceEngine normalises
        // pixel-space rects internally (values > 1.5 ⇒ pixels).
        faceBoxNorm = ui.Rect.fromLTRB(
          face.boundingBox.left, face.boundingBox.top,
          face.boundingBox.right, face.boundingBox.bottom,
        );
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
                  if (_challengeType == 'SMILE') ...[
                    const SizedBox(width: 8),
                    const Icon(Icons.sentiment_satisfied_alt_rounded,
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
