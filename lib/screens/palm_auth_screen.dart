// lib/screens/palm_auth_screen.dart
// ─────────────────────────────────────────────────────────────────────────────
// PALM AUTH SCREEN — Biometric session unlock
//
// Authentication mode (NOT enrollment):
//   • No BCH fuzzy commitment needed
//   • Captures 2 consecutive good frames → embedding → cosine similarity
//   • If similarity > 0.75 → pops with true
//   • If below threshold → shows error, user can try PIN instead
//
// Camera params PRESERVED from palm_hash_test_screen.dart:
//   ResolutionPreset.low, rear camera, 300ms loop, 0.50 threshold,
//   2 consecutive good frames, buffer max 3
// ─────────────────────────────────────────────────────────────────────────────
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../sov_node_sdk/palm_image_engine.dart';
import '../sov_node_sdk/palm_embedder.dart';

class PalmAuthScreen extends StatefulWidget {
  const PalmAuthScreen({super.key});

  @override
  State<PalmAuthScreen> createState() => _PalmAuthScreenState();
}

class _PalmAuthScreenState extends State<PalmAuthScreen> {
  static const Color _navy = Color(0xFF0A1628);
  static const Color _gold = Color(0xFFB8960C);

  // ── PRESERVED camera params ──────────────────────────────────────────────────
  static const double _kConfThreshold = 0.50;
  static const int    _kGoodFrames    = 2;
  static const int    _kBufMax        = 3;
  static const double _kMatchThresh   = 0.75;

  CameraController?         _cam;
  bool                      _loopRunning  = false;
  bool                      _scanBusy     = false;
  bool                      _captured     = false;
  bool                      _isStable     = true;
  double                    _handAngleRad = 0;
  int                       _goodFrames   = 0;
  final List<Uint8List>     _goodFrameBuffer = [];
  StreamSubscription<dynamic>? _accelSub;
  Timer?                    _watchdog;

  String  _guidance    = 'Place your LEFT palm to unlock';
  bool    _processing  = false;
  String? _resultState; // null|'matched'|'no_match'|'error'
  String? _storedEmbJson;
  // Which hand the citizen enrolled with ('LEFT' unless they flipped during a
  // dual-palm enrollment). Auth always asks for THE enrolled hand — never both.
  String  _enrolledHand = 'LEFT';

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _loadStoredEmbedding();
    _initCamera();
  }

  @override
  void dispose() {
    _loopRunning = false;
    _watchdog?.cancel();
    _accelSub?.cancel();
    _cam?.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  // ── Load stored embedding ────────────────────────────────────────────────────

  Future<void> _loadStoredEmbedding() async {
    final prefs = await SharedPreferences.getInstance();
    _storedEmbJson = prefs.getString('palm_embedding');
    if (_storedEmbJson == null || _storedEmbJson!.isEmpty) {
      debugPrint('[PALM_AUTH] No stored palm_embedding in prefs');
    }
    // Ask for whichever hand was enrolled (dual-palm citizens enrolled RIGHT)
    final hand = prefs.getString('enrolled_hand');
    if (hand == 'RIGHT' && mounted) {
      setState(() {
        _enrolledHand = 'RIGHT';
        _guidance     = 'Place your RIGHT palm to unlock';
      });
    }
  }

  // ── Camera init ─────────────────────────────────────────────────────────────

  Future<void> _initCamera() async {
    await Future.delayed(const Duration(milliseconds: 200));
    try {
      final cams = await availableCameras();
      // PRESERVED: rear camera, fallback to first
      final back = cams.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cams.first,
      );
      // PRESERVED: ResolutionPreset.low, jpeg, no audio
      _cam = CameraController(
        back,
        ResolutionPreset.low,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await _cam!.initialize();
      _cam!.addListener(() { if (mounted) setState(() {}); });

      try { await _cam!.setFocusMode(FocusMode.auto); } catch (_) {}
      try {
        final minZoom = await _cam!.getMinZoomLevel();
        final maxZoom = await _cam!.getMaxZoomLevel();
        await _cam!.setZoomLevel(1.5.clamp(minZoom, maxZoom));
      } catch (_) {}
      try { await _cam!.setFlashMode(FlashMode.torch); } catch (_) {}

      // Stability = total acceleration MAGNITUDE near gravity, in ANY orientation.
      // The old check assumed gravity on the z-axis (phone flat); a palm scan holds
      // the phone upright (z ~= 0), so it was never "stable" and the scan hung.
      // Compare squared magnitude to g^2 with the equivalent +/-1.5 tolerance
      // (|m-9.8|<1.5  <=>  m in (8.3,11.3)  <=>  m^2 in (68.89,127.69)) — no sqrt/import.
      _accelSub = accelerometerEventStream().listen(
        (e) {
          final m2 = e.x * e.x + e.y * e.y + e.z * e.z;
          _isStable = m2 > 68.89 && m2 < 127.69;
        },
        onError: (_) { _isStable = true; },
      );

      if (mounted) setState(() {});
      _startScanLoop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _resultState = 'error';
          _guidance    = 'Camera error — use PIN';
        });
      }
    }
  }

  // ── Scan loop — PRESERVED from palm_hash_test_screen.dart ──────────────────

  void _startScanLoop() {
    if (_loopRunning) return;
    _loopRunning = true;
    _captured    = false;
    _goodFrames  = 0;
    _goodFrameBuffer.clear();
    _runLoop();
  }

  Future<void> _runLoop() async {
    while (_loopRunning && mounted) {
      if (!_scanBusy && !_captured) await _scanOneFrame();
      // PRESERVED: 300ms interval
      await Future.delayed(const Duration(milliseconds: 300));
    }
  }

  Future<void> _scanOneFrame() async {
    if (_cam == null || !_cam!.value.isInitialized) return;
    _scanBusy = true;
    try {
      // PRESERVED: 3-second takePicture timeout
      final photo = await _cam!.takePicture()
          .timeout(const Duration(seconds: 3));
      final bytes = await photo.readAsBytes();
      final det   = await PalmImageEngine.detectPalmFast(bytes);

      // PRESERVED: confidence threshold 0.50
      if (det == null || det.confidence < _kConfThreshold) {
        if (mounted) {
          setState(() {
            _guidance   = 'Place your $_enrolledHand palm to unlock';
            _goodFrames = 0;
          });
        }
        return;
      }

      _handAngleRad = det.angleRad;
      // PRESERVED: stability penalty 0.85
      final score = _isStable ? det.confidence : det.confidence * 0.85;

      if (mounted) setState(() => _guidance = 'Hold still…');

      // PRESERVED: rolling buffer max 3, 2 consecutive good frames
      if (score >= _kConfThreshold) {
        if (_goodFrameBuffer.length >= _kBufMax) _goodFrameBuffer.removeAt(0);
        _goodFrameBuffer.add(bytes);
        _goodFrames++;
        if (_goodFrames >= _kGoodFrames && !_captured) {
          _captured    = true;
          _loopRunning = false;
          _triggerCapture();
        }
      } else {
        _goodFrames = 0;
      }
    } on TimeoutException {
      // Safe — loop retries
    } catch (_) {
      // Any frame error — safe to ignore
    } finally {
      _scanBusy = false;
    }
  }

  // ── Process + compare ───────────────────────────────────────────────────────

  Future<void> _triggerCapture() async {
    if (mounted) {
      setState(() {
        _processing = true;
        _guidance   = 'Scanning palm…';
      });
    }

    _watchdog?.cancel();
    _watchdog = Timer(const Duration(seconds: 30), () {
      if (mounted) {
        setState(() {
          _resultState = 'error';
          _guidance    = 'Timed out — use PIN';
          _processing  = false;
        });
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
        if (mounted) {
          setState(() {
            _resultState = 'no_match';
            _guidance    = 'Image too blurry — try again';
            _processing  = false;
          });
        }
        return;
      }

      // PRESERVED: exact embedInIsolate parameters from palm_hash_test_screen
      final palmResult = await PalmEmbedder.embedInIsolate(
        jpegBytes: engineResult.skeletonImage,
        imgW: 128, imgH: 128,
        wristX: 64,  wristY: 110,
        indexX: 64,  indexY: 20,
        pinkyX: 100, pinkyY: 30,
        thumbX: 25,  thumbY: 50,
      ).timeout(const Duration(seconds: 15));
      _watchdog?.cancel();

      // Load stored embedding (re-check in case prefs loaded after initState)
      if (_storedEmbJson == null || _storedEmbJson!.isEmpty) {
        final prefs = await SharedPreferences.getInstance();
        _storedEmbJson = prefs.getString('palm_embedding');
      }

      if (_storedEmbJson == null || _storedEmbJson!.isEmpty) {
        if (mounted) {
          setState(() {
            _resultState = 'error';
            _guidance    = 'No stored palm — use PIN';
            _processing  = false;
          });
        }
        return;
      }

      final stored = (jsonDecode(_storedEmbJson!) as List).cast<double>();
      final sim    = PalmEmbedder.cosineSimilarity(palmResult.embedding, stored);
      debugPrint('[PALM_AUTH] cosine similarity: ${sim.toStringAsFixed(4)}  '
          'threshold: $_kMatchThresh');

      if (sim >= _kMatchThresh) {
        if (mounted) {
          setState(() {
            _resultState = 'matched';
            _guidance    = 'Palm recognised ✓';
            _processing  = false;
          });
        }
        await Future.delayed(const Duration(milliseconds: 600));
        if (mounted) Navigator.pop(context, true);
      } else {
        if (mounted) {
          setState(() {
            _resultState = 'no_match';
            _guidance    = 'Palm not recognised. Try PIN.';
            _processing  = false;
          });
        }
      }
    } on TimeoutException {
      _watchdog?.cancel();
      if (mounted) {
        setState(() {
          _resultState = 'error';
          _guidance    = 'Timed out — use PIN';
          _processing  = false;
        });
      }
    } catch (e) {
      _watchdog?.cancel();
      debugPrint('[PALM_AUTH] Error: $e');
      if (mounted) {
        setState(() {
          _resultState = 'error';
          _guidance    = 'Error — use PIN';
          _processing  = false;
        });
      }
    }
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _navy,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(child: _buildBody()),
            _buildGuidanceBar(),
            const SizedBox(height: 12),
            _buildUsePinButton(),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              color: _gold, borderRadius: BorderRadius.circular(8)),
            child: const Icon(Icons.lock_outline, color: _navy, size: 20),
          ),
          const SizedBox(width: 10),
          const Text(
            'Palm Unlock',
            style: TextStyle(
                color: _gold, fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white38),
            onPressed: () => Navigator.pop(context, false),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_resultState == 'matched') {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.check_circle_rounded,
                color: Colors.greenAccent, size: 72),
            SizedBox(height: 16),
            Text(
              'Palm recognised',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold),
            ),
          ],
        ),
      );
    }

    if (_cam == null || !_cam!.value.isInitialized) {
      return const Center(
        child: CircularProgressIndicator(
            color: Color(0xFFB8960C), strokeWidth: 1.5),
      );
    }

    final size = _cam!.value.previewSize;
    return Stack(
      fit: StackFit.expand,
      children: [
        Center(
          child: SizedBox(
            width:  size?.height ?? 300,
            height: size?.width  ?? 400,
            child:  CameraPreview(_cam!),
          ),
        ),
        IgnorePointer(
          child: CustomPaint(
            painter: _OvalOverlayPainter(
              matched: _resultState == 'matched',
              noMatch: _resultState == 'no_match',
            ),
          ),
        ),
        if (_processing)
          const Center(
            child: CircularProgressIndicator(
                color: Color(0xFFB8960C), strokeWidth: 2),
          ),
      ],
    );
  }

  Widget _buildGuidanceBar() {
    final Color textColor;
    if (_resultState == 'matched') {
      textColor = Colors.greenAccent;
    } else if (_resultState == 'no_match' || _resultState == 'error') {
      textColor = const Color(0xFFE57373);
    } else {
      textColor = Colors.white70;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white.withAlpha(12),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          _guidance,
          textAlign: TextAlign.center,
          style: TextStyle(color: textColor, fontSize: 14),
        ),
      ),
    );
  }

  Widget _buildUsePinButton() {
    return TextButton(
      onPressed: () => Navigator.pop(context, false),
      child: const Text(
        'Use PIN instead',
        style: TextStyle(
          color: Color(0xFFB8960C),
          fontSize: 14,
          decoration: TextDecoration.underline,
          decorationColor: Color(0xFFB8960C),
        ),
      ),
    );
  }
}

// ── Oval overlay painter ──────────────────────────────────────────────────────

class _OvalOverlayPainter extends CustomPainter {
  final bool matched;
  final bool noMatch;

  const _OvalOverlayPainter({required this.matched, required this.noMatch});

  @override
  void paint(Canvas canvas, Size size) {
    final borderColor = matched
        ? Colors.greenAccent
        : noMatch
            ? Colors.redAccent
            : const Color(0xFFB8960C);

    final ovalRect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width:  size.width  * 0.72,
      height: size.height * 0.62,
    );

    // Dark vignette outside oval
    final outside = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addOval(ovalRect)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(outside, Paint()..color = Colors.black.withAlpha(100));

    // Oval border
    canvas.drawOval(
      ovalRect,
      Paint()
        ..color       = borderColor.withAlpha(180)
        ..style       = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
  }

  @override
  bool shouldRepaint(_OvalOverlayPainter old) =>
      old.matched != matched || old.noMatch != noMatch;
}
