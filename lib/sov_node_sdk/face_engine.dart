// lib/sov_node_sdk/face_engine.dart
// ─────────────────────────────────────────────────────────────────────────────
// FACE ENGINE — FACE-LOCK (one HUMAN = one identity)
//
// Two pretrained TFLite models, same runtime as the palm engine:
//
//   • blazeface_short.tflite  (229 KB) — face DETECTION. Cross-platform stand-in
//     for ML Kit on desktop (ML Kit is Android/iOS-only; Windows liveness was
//     impossible before this). Input [1,128,128,3] float32, outputs
//     regressors [1,896,16] + scores [1,896,1].
//   • mobilefacenet.tflite    (5 MB)  — face RECOGNITION embedding. Input
//     [1,112,112,3] float32 normalised (p-127.5)/128, output [1,192].
//
// The 192-d L2-normalised embedding rides PALM_EMBEDDING_REGISTER to the node,
// which stores ONLY a cancelable-transformed template (R_face·v) and rejects a
// new enrollment whose face matches an enrolled citizen (FACE_ALREADY_ENROLLED)
// — closing the cross-hand double-enrollment hole that dual palm opened.
// No face image ever leaves the device; only the mathematical vector does.
// ─────────────────────────────────────────────────────────────────────────────
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Rect;
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

class FaceDetection {
  /// Face bounding box, normalised 0–1 in source-image coordinates.
  final Rect box;
  final double score;
  const FaceDetection({required this.box, required this.score});
}

class FaceEngine {
  static Interpreter? _embedder;   // mobilefacenet
  static Interpreter? _detector;   // blazeface (desktop liveness path)

  static Future<void> loadModels({bool withDetector = false}) async {
    try {
      _embedder ??= await Interpreter.fromAsset('assets/models/mobilefacenet.tflite');
      debugPrint('mobilefacenet.tflite loaded (112×112 → 192-d embedding)');
    } catch (e) {
      debugPrint('FaceEngine: failed to load mobilefacenet: $e');
    }
    if (withDetector) {
      try {
        _detector ??= await Interpreter.fromAsset('assets/models/blazeface_short.tflite');
        debugPrint('blazeface_short.tflite loaded (128×128 face detection)');
      } catch (e) {
        debugPrint('FaceEngine: failed to load blazeface: $e');
      }
    }
  }

  static bool get embedderReady => _embedder != null;
  static bool get detectorReady => _detector != null;

  // ── DETECTION (BlazeFace short-range) — desktop liveness path ──────────────

  /// Detect the most confident face in a JPEG file. Returns null if the
  /// detector is not loaded, the file fails to decode, or no face clears
  /// [minScore]. Box is normalised 0–1 in source-image coordinates.
  static Future<FaceDetection?> detectFace(String jpegPath,
      {double minScore = 0.55}) async {
    final det = _detector;
    if (det == null) return null;
    try {
      final bytes   = await File(jpegPath).readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return null;
      return _runBlazeFace(decoded, det, minScore);
    } catch (e) {
      debugPrint('FaceEngine.detectFace: $e');
      return null;
    }
  }

  static FaceDetection? _runBlazeFace(
      img.Image src, Interpreter det, double minScore) {
    // Letterbox to 128×128 (preserve aspect, pad with black) so the box maps
    // back to source coordinates without distortion.
    const N = 128;
    final scale = math.min(N / src.width, N / src.height);
    final rw = (src.width * scale).round(), rh = (src.height * scale).round();
    final resized = img.copyResize(src, width: rw, height: rh);
    final padX = (N - rw) ~/ 2, padY = (N - rh) ~/ 2;

    final input = List.generate(1, (_) =>
        List.generate(N, (y) =>
            List.generate(N, (x) {
              final ix = x - padX, iy = y - padY;
              if (ix < 0 || iy < 0 || ix >= rw || iy >= rh) {
                return [0.0, 0.0, 0.0];
              }
              final p = resized.getPixel(ix, iy);
              // BlazeFace expects [-1, 1]
              return [p.r / 127.5 - 1.0, p.g / 127.5 - 1.0, p.b / 127.5 - 1.0];
            })));

    final regressors = List.generate(1, (_) =>
        List.generate(896, (_) => List.filled(16, 0.0)));
    final scores = List.generate(1, (_) =>
        List.generate(896, (_) => List.filled(1, 0.0)));
    det.runForMultipleInputs([input], {0: regressors, 1: scores});

    // Anchor grid for the short-range model: stride 8 → 16×16 cells × 2
    // anchors (512), then stride 16 → 8×8 cells × 6 anchors (384) = 896.
    // All anchors are 1.0×1.0 boxes centred on the cell; regressor offsets are
    // in 128-pixel units (x_scale = y_scale = w_scale = h_scale = 128).
    int bestI = -1;
    double bestScore = minScore;
    for (int i = 0; i < 896; i++) {
      final raw = scores[0][i][0].clamp(-80.0, 80.0);
      final s = 1.0 / (1.0 + math.exp(-raw));
      if (s > bestScore) { bestScore = s; bestI = i; }
    }
    if (bestI < 0) return null;

    double anchorCx, anchorCy;
    if (bestI < 512) {
      final cell = bestI ~/ 2;
      anchorCx = ((cell % 16) + 0.5) / 16.0;
      anchorCy = ((cell ~/ 16) + 0.5) / 16.0;
    } else {
      final cell = (bestI - 512) ~/ 6;
      anchorCx = ((cell % 8) + 0.5) / 8.0;
      anchorCy = ((cell ~/ 8) + 0.5) / 8.0;
    }
    final r = regressors[0][bestI];
    final cx = anchorCx + r[0] / N, cy = anchorCy + r[1] / N;
    final w  = r[2] / N,            h  = r[3] / N;

    // Map from letterboxed 128-space back to source normalised coords.
    double mapX(double v) => ((v * N - padX) / rw).clamp(0.0, 1.0);
    double mapY(double v) => ((v * N - padY) / rh).clamp(0.0, 1.0);
    final box = Rect.fromLTRB(
      mapX(cx - w / 2), mapY(cy - h / 2),
      mapX(cx + w / 2), mapY(cy + h / 2),
    );
    if (box.width <= 0.01 || box.height <= 0.01) return null;
    return FaceDetection(box: box, score: bestScore);
  }

  // ── EMBEDDING (MobileFaceNet) ──────────────────────────────────────────────

  /// Compute the 192-d L2-normalised face embedding from a JPEG file.
  /// [boxNorm] is the face box normalised 0–1 in source coordinates (from
  /// ML Kit on mobile or BlazeFace on desktop); if null the full frame is
  /// used. Returns null on any failure — enrollment then proceeds without a
  /// face embedding (the node treats that as an old client).
  static Future<List<double>?> embedFromJpeg(String jpegPath,
      {Rect? boxNorm}) async {
    final emb = _embedder;
    if (emb == null) return null;
    try {
      final bytes   = await File(jpegPath).readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return null;

      // Accept both normalised (0–1) and pixel-space rects: ML Kit hands back
      // pixel coords, BlazeFace normalised ones. Values > 1.5 ⇒ pixels.
      if (boxNorm != null &&
          (boxNorm.right > 1.5 || boxNorm.bottom > 1.5)) {
        boxNorm = Rect.fromLTRB(
          (boxNorm.left   / decoded.width).clamp(0.0, 1.0),
          (boxNorm.top    / decoded.height).clamp(0.0, 1.0),
          (boxNorm.right  / decoded.width).clamp(0.0, 1.0),
          (boxNorm.bottom / decoded.height).clamp(0.0, 1.0),
        );
      }

      // Crop a square around the face with a 25% margin (MobileFaceNet is
      // trained on loosely-aligned crops; exact alignment is not required).
      img.Image crop;
      if (boxNorm != null) {
        final bw = boxNorm.width * decoded.width;
        final bh = boxNorm.height * decoded.height;
        final int side = (math.max(bw, bh) * 1.25)
            .round()
            .clamp(16, math.min(decoded.width, decoded.height))
            .toInt();
        final cx = ((boxNorm.left + boxNorm.width / 2) * decoded.width).round();
        final cy = ((boxNorm.top + boxNorm.height / 2) * decoded.height).round();
        final int x0 = (cx - side ~/ 2).clamp(0, decoded.width - side).toInt();
        final int y0 = (cy - side ~/ 2).clamp(0, decoded.height - side).toInt();
        crop = img.copyCrop(decoded, x: x0, y: y0, width: side, height: side);
      } else {
        crop = decoded;
      }
      final face = img.copyResize(crop, width: 112, height: 112);

      final input = List.generate(1, (_) =>
          List.generate(112, (y) =>
              List.generate(112, (x) {
                final p = face.getPixel(x, y);
                return [(p.r - 127.5) / 128.0,
                        (p.g - 127.5) / 128.0,
                        (p.b - 127.5) / 128.0];
              })));
      final output = List.generate(1, (_) => List.filled(192, 0.0));
      emb.run(input, output);

      // L2-normalise so node-side cosine is a plain dot product.
      final v = output[0];
      double n = 0;
      for (final x in v) { n += x * x; }
      n = math.sqrt(n);
      if (n < 1e-6) return null;
      return v.map((x) => x / n).toList();
    } catch (e) {
      debugPrint('FaceEngine.embedFromJpeg: $e');
      return null;
    }
  }
}
