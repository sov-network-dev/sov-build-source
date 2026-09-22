// lib/sov_node_sdk/palm_image_engine.dart
// â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
// SVRN Palm Image Engine â€” File-Based Architecture
//
// Model: svrn_model.tflite (YOLOv8 detect, 320Ã—320, INT8, 2-class)
//   Output shape: [1, 6, 2100]
//   Row 0-3: cx, cy, w, h (bounding box)
//   Row 4: cls0 confidence â€” fires HIGH for PHYSICAL LEFT palm
//   Row 5: cls1 confidence â€” fires HIGH for PHYSICAL RIGHT palm
//   isRight = cls1Conf > cls0Conf  (confirmed by device diagnostic video)
//
// Architecture: File-based processing
//   Camera writes small JPEGs to temp storage.
//   AI reads from file â€” no large RAM allocations in isolates.
//   Works on any Android device including 512MB RAM phones.
// â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
import 'dart:io';
import 'dart:math' show max, min, pi, atan2;
import 'dart:ui' show Offset, Rect;
import 'package:image/image.dart' as img;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

// â”€â”€ DATA CLASSES â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

class EngineCapture {
  final Uint8List  skeletonImage;
  final Uint8List? rawImage;
  final double     creaseScore;
  final int        creasePixels;
  final double     sharpness;
  final double     brightness;
  final String     qualityNote;

  const EngineCapture({
    required this.skeletonImage, this.rawImage,
    required this.creaseScore,   required this.creasePixels,
    required this.sharpness,     required this.brightness,
    required this.qualityNote,
  });
}

class DetectionResult {
  final double confidence;
  final bool   isRight;
  final double angleRad;
  final double row4; // raw cls0 â€” debug
  final double row5; // raw cls1 â€” debug
  final Rect   boxNorm; // bounding box normalised 0â€“1 in 320Ã—320 model space
  final bool   fromUpright; // detection came from the un-rotated frame (rot 0)
  const DetectionResult({
    required this.confidence, required this.isRight,
    required this.angleRad,   required this.row4, required this.row5,
    required this.boxNorm,    this.fromUpright = true,
  });

  // Chirality margin: how decisively the model picked left vs right (0..~1).
  // A rotated detection or a near-tie makes this small → handedness is a guess,
  // NOT a reason to block the user (see enrollment wrong-hand blocker).
  double get chiralityMargin => (row5 - row4).abs();

  // Trust the left/right call whenever the margin is decisive. `fromUpright` was
  // ALSO required here, which silently disabled wrong-hand rejection in practice:
  // V28 only fires on a roughly upright palm, so _runYolo tries 4 rotations and a
  // rotated pass usually wins on a handheld frame — setting fromUpright = false
  // and discarding a perfectly good verdict. The result was that enrolment
  // accepted the wrong palm (king, live on S23, 2026-08-07).
  //
  // MEASURED before removing it (42 of the king's real palms, the detection
  // pipeline from scripts/sort_and_test_real_palms.py — plain 320 stretch, RGB,
  // NCHW, best of 4 rotations): mirroring a palm — which physically turns a left
  // hand into a right one — flipped the model's call 40/40 (100%), with a mean
  // chirality margin of 0.9167. The winning rotation presents an upright palm to
  // the model, so its handedness is sound no matter which rotation won. A model
  // without real chirality would sit near 50% and near-zero margin.
  //
  // The 0.20 floor stays: it still rejects a genuine near-tie, and real margins
  // (~0.92) clear it by a wide distance.
  bool get handednessReliable => chiralityMargin >= 0.20;
}

class _YoloBox {
  final double x1, y1, x2, y2; // normalised [0,1] in the ORIGINAL (fed) frame
  final double cls0Conf; // row 4 â€” HIGH for physical LEFT palm
  final double cls1Conf; // row 5 â€” HIGH for physical RIGHT palm
  final int    rot;      // winning orientation: 0 = upright, 1..3 = 90Â°*rot

  // CONFIRMED by diagnostic video:
  //   cls1Conf > cls0Conf â†’ physical RIGHT palm
  //   cls0Conf > cls1Conf â†’ physical LEFT palm
  bool   get isRight    => cls1Conf > cls0Conf;
  double get confidence => cls1Conf > cls0Conf ? cls1Conf : cls0Conf;

  const _YoloBox({
    required this.x1, required this.y1,
    required this.x2, required this.y2,
    required this.cls0Conf, required this.cls1Conf,
    this.rot = 0,
  });
}

// â”€â”€ ENGINE â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

class PalmImageEngine {
  static Interpreter? _interpreter;

  static Future<void> loadModel() async {
    try {
      _interpreter = await Interpreter.fromAsset('assets/models/svrn_model.tflite');
      debugPrint('svrn_model.tflite loaded (320Ã—320 2-class detection)');
    } catch (e) {
      debugPrint('Failed to load model: $e');
    }
  }

  /// Detects a palm in the given JPEG bytes.
  /// Returns null if no palm found or model not loaded.
  static Future<DetectionResult?> detectPalmFast(Uint8List bytes) async {
    if (_interpreter == null) {
      debugPrint('[PALM] detectPalmFast: model not loaded');
      return null;
    }
    try {
      return await compute(_detectIsolate, {
        'bytes':        bytes,
        'modelAddress': _interpreter!.address,
      });
    } catch (e, st) {
      // NEVER swallow silently — a runtime error here reads as "no palm" forever
      // and makes the scanner look dead with zero diagnostics (king, 2026-07-21).
      debugPrint('[PALM] detectPalmFast ERROR: $e\n$st');
      return null;
    }
  }

  /// Detect a palm directly from a live camera-stream YUV420 frame (Android
  /// preview), reusing the EXACT same _runYolo pipeline as detectPalmFast — only
  /// the frame source differs, so detection behaviour is identical. This is the
  /// smooth-scanner path: no per-frame takePicture stall (which froze the preview
  /// and made lock slow). The CALLER must throttle + steady-gate this so the heavy
  /// model runs only a few times/second, NOT at 30fps — running YOLO on every
  /// stream frame is what overheated low-end phones. rotationDeg rotates the frame
  /// to upright (sensor frames arrive rotated) so the orientation-sensitive model
  /// sees the palm the same way takePicture delivered it.
  static Future<DetectionResult?> detectPalmFromYuv({
    required Uint8List yPlane,
    required Uint8List uPlane,
    required Uint8List vPlane,
    required int width,
    required int height,
    required int yRowStride,
    required int uvRowStride,
    required int uvPixelStride,
    required int rotationDeg,
  }) async {
    if (_interpreter == null) return null;
    try {
      return await compute(_detectYuvIsolate, {
        'y': yPlane, 'u': uPlane, 'v': vPlane,
        'w': width, 'h': height,
        'yStride': yRowStride, 'uvStride': uvRowStride, 'uvPix': uvPixelStride,
        'rot': rotationDeg,
        'modelAddress': _interpreter!.address,
      });
    } catch (e, st) {
      debugPrint('[PALM] detectPalmFromYuv ERROR: $e\n$st');
      return null;
    }
  }

  /// Process a list of file paths (not raw bytes).
  /// Each path points to a small JPEG already saved to temp storage.
  /// This keeps RAM usage minimal â€” we process one file at a time.
  static Future<EngineCapture> processBurst(
    List<Uint8List> frames, {
    required double handAngleRad,
  }) async {
    try {
      return await compute(_burstIsolate, {
        'frames':   frames,
        'angleRad': handAngleRad,
      });
    } catch (e) {
      final blank = img.Image(width: 128, height: 128);
      return EngineCapture(
        skeletonImage: Uint8List.fromList(img.encodeJpg(blank)),
        creaseScore: 0, creasePixels: 0,
        sharpness: 0, brightness: 0,
        qualityNote: 'Engine error: $e',
      );
    }
  }

  /// Save bytes to a small temp JPEG at controlled resolution.
  /// Returns the file path. Used by the screen to save buffer frames.
  static Future<String> saveTempFrame(Uint8List bytes, String name) async {
    final dir  = await getTemporaryDirectory();
    final path = '${dir.path}/svrn_$name.jpg';
    await File(path).writeAsBytes(bytes);
    return path;
  }

  /// Delete a temp frame file after processing.
  static Future<void> deleteTempFrame(String path) async {
    try { await File(path).delete(); } catch (_) {}
  }

  /// Extracts palm crease skeleton points from a raw image frame.
  ///
  /// Pipeline: green channel â†’ CLAHE â†’ adaptive threshold (blockSize=21, C=8)
  /// â†’ morphological opening (3Ã—3) â†’ sample â‰¤200 darkest crease pixels.
  ///
  /// Returns normalised (0â€“1) Offset positions for use as a Palm DNA visual
  /// overlay.  Runs in a background isolate â€” safe to call from the UI thread.
  static Future<List<Offset>> extractCreasePoints(img.Image image) async {
    final bytes = Uint8List.fromList(img.encodeJpg(image, quality: 95));
    final raw   = await compute(_extractCreaseIsolate, bytes);
    final pts   = <Offset>[];
    for (int i = 0; i + 1 < raw.length; i += 2) {
      pts.add(Offset(raw[i], raw[i + 1]));
    }
    return pts;
  }
}

// â”€â”€ DETECTION ISOLATE â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

DetectionResult? _detectIsolate(Map<String, dynamic> args) {
  final bytes     = args['bytes'] as Uint8List;
  final modelAddr = args['modelAddress'] as int;

  Interpreter? interp;
  if (modelAddr != 0) {
    try { interp = Interpreter.fromAddress(modelAddr); } catch (_) {}
  }
  if (interp == null) return null;

  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;

  final box = _runYolo(decoded, interp);
  if (box == null) return null;

  // Angle from bounding box centre â€” wrist at bottom, fingers at top
  final cy = (box.y1 + box.y2) / 2;
  final angleRad = atan2(box.y1 - cy, 0.0); // points upward

  return DetectionResult(
    confidence:  box.confidence,
    isRight:     box.isRight,
    angleRad:    angleRad,
    row4:        box.cls0Conf,
    row5:        box.cls1Conf,
    fromUpright: box.rot == 0,
    boxNorm:    Rect.fromLTRB(
      box.x1.clamp(0.0, 1.0),
      box.y1.clamp(0.0, 1.0),
      box.x2.clamp(0.0, 1.0),
      box.y2.clamp(0.0, 1.0),
    ),
  );
}

// â”€â”€ BURST ISOLATE â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

DetectionResult? _detectYuvIsolate(Map<String, dynamic> args) {
  final modelAddr = args['modelAddress'] as int;
  Interpreter? interp;
  if (modelAddr != 0) {
    try { interp = Interpreter.fromAddress(modelAddr); } catch (_) {}
  }
  if (interp == null) return null;

  final w = args['w'] as int;
  final h = args['h'] as int;
  final y = args['y'] as Uint8List;
  final u = args['u'] as Uint8List;
  final v = args['v'] as Uint8List;
  final yStride  = args['yStride'] as int;
  final uvStride = args['uvStride'] as int;
  final uvPix    = args['uvPix'] as int;
  final rot      = args['rot'] as int;

  // YUV420 -> RGB (BT.601, integer math). ~76k px at 320x240; runs in the
  // compute() isolate, so the UI thread never blocks on it.
  final rgb = Uint8List(w * h * 3);
  int o = 0;
  for (int j = 0; j < h; j++) {
    final yBase  = j * yStride;
    final uvBase = (j >> 1) * uvStride;
    for (int i = 0; i < w; i++) {
      final yv = y[yBase + i] & 0xff;
      final uvIdx = uvBase + (i >> 1) * uvPix;
      final uu = (u[uvIdx] & 0xff) - 128;
      final vv = (v[uvIdx] & 0xff) - 128;
      int r = yv + ((1436 * vv) >> 10);
      int g = yv - ((352 * uu + 731 * vv) >> 10);
      int b = yv + ((1815 * uu) >> 10);
      rgb[o++] = r < 0 ? 0 : (r > 255 ? 255 : r);
      rgb[o++] = g < 0 ? 0 : (g > 255 ? 255 : g);
      rgb[o++] = b < 0 ? 0 : (b > 255 ? 255 : b);
    }
  }

  img.Image image = img.Image.fromBytes(
    width: w, height: h, bytes: rgb.buffer,
    numChannels: 3, order: img.ChannelOrder.rgb);
  if (rot != 0) image = img.copyRotate(image, angle: rot.toDouble());

  final box = _runYolo(image, interp);
  if (box == null) return null;
  final cy = (box.y1 + box.y2) / 2;
  final angleRad = atan2(box.y1 - cy, 0.0);
  return DetectionResult(
    confidence:  box.confidence,
    isRight:     box.isRight,
    angleRad:    angleRad,
    row4:        box.cls0Conf,
    row5:        box.cls1Conf,
    fromUpright: box.rot == 0,
    boxNorm: Rect.fromLTRB(
      box.x1.clamp(0.0, 1.0), box.y1.clamp(0.0, 1.0),
      box.x2.clamp(0.0, 1.0), box.y2.clamp(0.0, 1.0)),
  );
}

EngineCapture _burstIsolate(Map<String, dynamic> args) {
  final frames   = (args['frames'] as List).cast<Uint8List>();
  final angleRad = (args['angleRad'] as num).toDouble();

  EngineCapture? best;
  int bestCrease = -1;

  for (final frameBytes in frames) {
    try {
      final result = _processFrame(frameBytes, angleRad: angleRad);
      if (result.creasePixels > bestCrease) {
        bestCrease = result.creasePixels;
        best       = result;
      }
    } catch (_) {}
  }

  if (best != null) return best;

  final blank = img.Image(width: 128, height: 128);
  return EngineCapture(
    skeletonImage: Uint8List.fromList(img.encodeJpg(blank)),
    creaseScore: 0, creasePixels: 0,
    sharpness: 0, brightness: 0,
    qualityNote: 'No valid frames',
  );
}

// â”€â”€ YOLO INFERENCE â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

// Orientation-robust wrapper. Model is V28 — the correct LAUNCH model: it was
// trained on REAL palms (detects 78% of the king's real photos and correctly
// IGNORES AI-generated palms — 0.00 on the synthetic reference set), whereas the
// old V27 was trained on synthetic/AI data (0.91 on AI palms, only 41% on real
// hands). V28 is a standard YOLOv8 export with NO rotation augmentation, so it is
// orientation-sensitive: it needs the palm roughly upright (upright-only can read
// ~0 on a sideways frame). The live camera frame can arrive rotated, so we try the
// 4 cardinal orientations and keep the strongest detection — this is what makes
// V28 actually fire on a live frame. Chirality (left/right) is rotation-invariant,
// so it stays correct. Short-circuits on a solid hit to keep the live loop fast.
_YoloBox? _runYolo(img.Image frame, Interpreter interpreter) {
  _YoloBox? best;
  double bestConf = 0.0;
  int bestRot = 0;
  for (int rot = 0; rot < 4; rot++) {
    final f = rot == 0 ? frame : img.copyRotate(frame, angle: rot * 90.0);
    final box = _runYoloSingle(f, interpreter);
    if (box != null && box.confidence > bestConf) {
      bestConf = box.confidence;
      best = box;
      bestRot = rot;
      // Stop as soon as we have a solid hit in ANY orientation. Lowered 0.80 ->
      // 0.45 (king, 2026-07-21): an upright palm now short-circuits after the
      // first orientation instead of grinding through all 4 rotations every
      // frame, so the live loop stays fast/responsive.
      if (bestConf > 0.45) break;
    }
  }
  if (best == null) return null;
  if (bestRot == 0) return best; // upright: rot defaults to 0 → handedness trusted
  // A rotated orientation won: the palm is present but its box is in rotated
  // space. The alignment UX keys off confidence + chirality (not the exact box),
  // so return a centred box to keep the overlay sane while detection works.
  // Carry rot != 0 for diagnostics (the enrolment readout shows it as "↻"). It is
  // NOT a reason to distrust handedness — measured 100% mirror-swap at a 0.9167
  // mean margin on the winning rotation; see handednessReliable above.
  return _YoloBox(
    x1: 0.2, y1: 0.2, x2: 0.8, y2: 0.8, // normalised centred box (overlay only)
    cls0Conf: best.cls0Conf, cls1Conf: best.cls1Conf,
    rot: bestRot,
  );
}

_YoloBox? _runYoloSingle(img.Image frame, Interpreter interpreter) {
  // LETTERBOX to 320×320 (aspect-preserving resize + gray padding) — this MATCHES
  // the YOLOv8 training/export preprocessing (tools/training/svrn_v28_retrain.py,
  // imgsz=320). A plain stretch distorts a portrait camera frame and measurably
  // hurts detection (live-sim: stretch 83% vs letterbox 89% on the king's palms).
  final fw = frame.width, fh = frame.height;
  final lbScale = 320.0 / (fw > fh ? fw : fh);
  final nw = (fw * lbScale).round().clamp(1, 320);
  final nh = (fh * lbScale).round().clamp(1, 320);
  final padX = ((320 - nw) / 2).round();
  final padY = ((320 - nh) / 2).round();
  final scaled  = img.copyResize(frame, width: nw, height: nh);
  final resized = img.Image(width: 320, height: 320);
  img.fill(resized, color: img.ColorRgb8(114, 114, 114)); // YOLOv8 pad grey
  img.compositeImage(resized, scaled, dstX: padX, dstY: padY);

  // Model input layout differs by export path: V27 = NHWC [1,320,320,3],
  // V28 = NCHW [1,3,320,320]. Detect from the tensor shape at runtime.
  final inShape = interpreter.getInputTensor(0).shape;
  final isNchw  = inShape.length == 4 && inShape[1] == 3;

  // PERF: read the whole 320×320 RGB buffer ONCE instead of 307,200 getPixel()
  // calls. `getBytes(rgb)` yields R,G,B row-major, so px[(y*320+x)*3 + c] equals
  // the old getPixel(x,y).r/.g/.b exactly — the model gets byte-identical input,
  // detection is unchanged; only the per-pixel method-call overhead is gone.
  final px = resized.getBytes(order: img.ChannelOrder.rgb);
  final Object input = isNchw
      ? List.generate(1, (_) =>
          List.generate(3, (c) =>
              List.generate(320, (y) =>
                  List.generate(320, (x) => px[(y * 320 + x) * 3 + c] / 255.0))))
      : List.generate(1, (_) =>
          List.generate(320, (y) =>
              List.generate(320, (x) {
                final o = (y * 320 + x) * 3;
                return [px[o] / 255.0, px[o + 1] / 255.0, px[o + 2] / 255.0];
              })));

  final shape  = interpreter.getOutputTensor(0).shape;
  final output = List.generate(shape[0], (_) =>
      List.generate(shape[1], (_) => List.filled(shape[2], 0.0)));

  interpreter.run(input, output);

  _YoloBox? best;
  // Detection floor dropped to 0.05 (king, 2026-07-21) so the engine RETURNS even
  // weak detections — the enrollment screen shows this raw confidence for on-device
  // diagnosis and applies the real 0.35 lock gate itself. V28 is bimodal (a real
  // palm reads ~0.9), so this floor only affects what the debug readout can show.
  double bestConf = 0.05;
  final numAnchors = shape[2];

  for (int i = 0; i < numAnchors; i++) {
    final c0 = output[0][4][i]; // cls0 â€” fires for LEFT palm
    final c1 = output[0][5][i]; // cls1 â€” fires for RIGHT palm
    final peak = c0 > c1 ? c0 : c1;

    if (peak > bestConf) {
      bestConf = peak;
      final cx = output[0][0][i], cy = output[0][1][i];
      final bw = output[0][2][i], bh = output[0][3][i];
      // Export paths differ: some emit pixel coords (0â€“320), others
      // normalised (0â€“1). Callers expect pixels â€” upscale if normalised.
      final scale = (cx <= 2.0 && cy <= 2.0 && bw <= 2.0 && bh <= 2.0) ? 320.0 : 1.0;
      best = _YoloBox(
        x1: (cx - bw / 2) * scale, y1: (cy - bh / 2) * scale,
        x2: (cx + bw / 2) * scale, y2: (cy + bh / 2) * scale,
        cls0Conf: c0, cls1Conf: c1,
      );
    }
  }
  if (best == null) return null;
  // Undo the letterbox: map the box from 320×320 padded space back to the
  // ORIGINAL frame, normalised to [0,1] (remove pad, divide by the scaled size).
  double nx(double x) => ((x - padX) / nw).clamp(0.0, 1.0);
  double ny(double y) => ((y - padY) / nh).clamp(0.0, 1.0);
  return _YoloBox(
    x1: nx(best.x1), y1: ny(best.y1), x2: nx(best.x2), y2: ny(best.y2),
    cls0Conf: best.cls0Conf, cls1Conf: best.cls1Conf,
  );
}

// â”€â”€ FRAME PROCESSOR â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

EngineCapture _processFrame(Uint8List bytes, {required double angleRad}) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) throw Exception('Could not decode frame');
  final w = decoded.width, h = decoded.height;

  // Centre crop â€” 70% of smaller dimension
  final minDim  = min(w, h);
  final genSize = (minDim * 0.70).toInt();
  final genX    = (w / 2 - genSize / 2).toInt();
  final genY    = (h / 2 - genSize / 2).toInt();
  final cropped = img.copyCrop(decoded,
      x: genX, y: genY, width: genSize, height: genSize);

  // Rotate upright
  final rotDeg  = -90.0 - (angleRad * 180.0 / pi);
  final rotated = img.copyRotate(cropped,
      angle: rotDeg, interpolation: img.Interpolation.linear);

  // Inner 75% crop to remove rotation corners
  final strictSize = (min(rotated.width, rotated.height) * 0.75).toInt();
  final fx = (rotated.width  / 2 - strictSize / 2).toInt();
  final fy = (rotated.height / 2 - strictSize / 2).toInt();
  final canonical = img.copyCrop(rotated,
      x: fx, y: fy, width: strictSize, height: strictSize);

  // Resize to 128Ã—128
  final raw128 = img.copyResize(canonical,
      width: 128, height: 128, interpolation: img.Interpolation.cubic);

  final sharpness  = _sharpness(raw128);
  final brightness = _brightness(raw128);
  final rawJpeg    = Uint8List.fromList(img.encodeJpg(raw128, quality: 90));

  // Enhancement pipeline: green channel â†’ unsharp mask â†’ CLAHE
  // DISABLED: _localNormalize() removed (FIX 4) â€” O(n*r^2) per pixel adds
  // ~150-300ms per frame on mid-range phones, causing scan lag regression.
  // Re-enable if matching quality degrades in varied lighting conditions.
  final green    = _green(raw128);
  final sharp    = _unsharp(green);
  final clahe    = _clahe(sharp);
  final enhanced = clahe; // was: _localNormalize(clahe)

  int creaseCount = 0;
  for (int y = 0; y < enhanced.height; y++) {
    for (int x = 0; x < enhanced.width; x++) {
      if (enhanced.getPixel(x, y).r < 80) creaseCount++;
    }
  }

  return EngineCapture(
    skeletonImage: Uint8List.fromList(img.encodeJpg(enhanced, quality: 95)),
    rawImage:      rawJpeg,
    creaseScore:   (creaseCount / 800.0).clamp(0.0, 1.0),
    creasePixels:  creaseCount,
    sharpness:     sharpness,
    brightness:    brightness,
    qualityNote:   'Sharp: ${(sharpness*100).toInt()}% | '
        'Bright: ${(brightness*100).toInt()}% | Creases: $creaseCount px',
  );
}

// â”€â”€ IMAGE PRIMITIVES â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

img.Image _green(img.Image src) {
  final out = img.Image(width: src.width, height: src.height);
  for (int y = 0; y < src.height; y++) {
    for (int x = 0; x < src.width; x++) {
      final g = src.getPixel(x, y).g.toInt().clamp(0, 255);
      out.setPixel(x, y, img.ColorRgb8(g, g, g));
    }
  }
  return out;
}

img.Image _unsharp(img.Image src) {
  final blurred = _blur3(src);
  final out     = img.Image(width: src.width, height: src.height);
  for (int y = 0; y < src.height; y++) {
    for (int x = 0; x < src.width; x++) {
      final o = src.getPixel(x, y).r.toInt();
      final b = blurred.getPixel(x, y).r.toInt();
      final v = (o + 1.8 * (o - b)).round().clamp(0, 255);
      out.setPixel(x, y, img.ColorRgb8(v, v, v));
    }
  }
  return out;
}

img.Image _clahe(img.Image input) {
  final w = input.width, h = input.height, n = w * h;
  final hist = List<int>.filled(256, 0);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      hist[input.getPixel(x, y).r.toInt()]++;
    }
  }
  final cdf = List<int>.filled(256, 0);
  cdf[0] = hist[0];
  for (int i = 1; i < 256; i++) { cdf[i] = cdf[i - 1] + hist[i]; }
  final cdfMin = cdf.firstWhere((v) => v > 0, orElse: () => 1);
  final out = img.Image(width: w, height: h);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final v  = input.getPixel(x, y).r.toInt();
      final eq = ((cdf[v] - cdfMin) * 255 ~/ max(1, n - cdfMin)).clamp(0, 255);
      out.setPixel(x, y, img.ColorRgb8(eq, eq, eq));
    }
  }
  return out;
}

img.Image _blur3(img.Image src) {
  const k = [1, 2, 1, 2, 4, 2, 1, 2, 1];
  final w = src.width, h = src.height;
  final out = img.Image(width: w, height: h);
  for (int y = 1; y < h - 1; y++) {
    for (int x = 1; x < w - 1; x++) {
      int v = 0, ki = 0;
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          v += src.getPixel(x + dx, y + dy).r.toInt() * k[ki++];
        }
      }
      out.setPixel(x, y, img.ColorRgb8((v ~/ 16).clamp(0, 255), 0, 0));
    }
  }
  return out;
}

double _sharpness(img.Image src) {
  final w = src.width, h = src.height;
  double sum = 0, sumSq = 0; int n = 0;
  for (int y = 1; y < h - 1; y++) {
    for (int x = 1; x < w - 1; x++) {
      final c   = src.getPixel(x, y).r.toDouble();
      final lap = (4*c - src.getPixel(x,y-1).r.toDouble()
          - src.getPixel(x,y+1).r.toDouble()
          - src.getPixel(x-1,y).r.toDouble()
          - src.getPixel(x+1,y).r.toDouble()).abs();
      sum += lap; sumSq += lap*lap; n++;
    }
  }
  if (n == 0) return 0;
  final mean = sum / n;
  return ((sumSq / n - mean * mean) / 5000.0).clamp(0.0, 1.0);
}

double _brightness(img.Image src) {
  double sum = 0;
  final n = src.width * src.height;
  for (int y = 0; y < src.height; y++) {
    for (int x = 0; x < src.width; x++) {
      sum += src.getPixel(x, y).r.toInt();
    }
  }
  return (sum / n / 255.0).clamp(0.0, 1.0);
}

// â”€â”€ CREASE EXTRACTION PRIMITIVES â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

/// Adaptive threshold using summed-area table â€” O(1) per pixel after O(N) setup.
/// Pixels darker than (local_mean âˆ’ c) are set to 0 (crease), rest to 255.
img.Image _adaptiveThreshold(img.Image src, {int blockSize = 21, int c = 8}) {
  final w = src.width, h = src.height;
  // Build integral image (SAT) with one extra row/col of padding
  final sat = List<int>.filled((w + 1) * (h + 1), 0);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      sat[(y + 1) * (w + 1) + (x + 1)] =
          src.getPixel(x, y).r.toInt()
          + sat[y       * (w + 1) + (x + 1)]
          + sat[(y + 1) * (w + 1) + x]
          - sat[y       * (w + 1) + x];
    }
  }
  final half = blockSize ~/ 2;
  final out  = img.Image(width: w, height: h);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final y0 = max(0, y - half), y1 = min(h - 1, y + half);
      final x0 = max(0, x - half), x1 = min(w - 1, x + half);
      final area = (y1 - y0 + 1) * (x1 - x0 + 1);
      final sum  = sat[(y1 + 1) * (w + 1) + (x1 + 1)]
                 - sat[y0       * (w + 1) + (x1 + 1)]
                 - sat[(y1 + 1) * (w + 1) + x0]
                 + sat[y0       * (w + 1) + x0];
      final mean  = sum / area;
      final pixel = src.getPixel(x, y).r.toInt();
      final v     = pixel < (mean - c) ? 0 : 255;
      out.setPixel(x, y, img.ColorRgb8(v, v, v));
    }
  }
  return out;
}

img.Image _morphErode3(img.Image src) {
  final w = src.width, h = src.height;
  final out = img.Image(width: w, height: h);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      int minV = 255;
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          final v = src.getPixel(
              (x + dx).clamp(0, w - 1),
              (y + dy).clamp(0, h - 1)).r.toInt();
          if (v < minV) minV = v;
        }
      }
      out.setPixel(x, y, img.ColorRgb8(minV, minV, minV));
    }
  }
  return out;
}

img.Image _morphDilate3(img.Image src) {
  final w = src.width, h = src.height;
  final out = img.Image(width: w, height: h);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      int maxV = 0;
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          final v = src.getPixel(
              (x + dx).clamp(0, w - 1),
              (y + dy).clamp(0, h - 1)).r.toInt();
          if (v > maxV) maxV = v;
        }
      }
      out.setPixel(x, y, img.ColorRgb8(maxV, maxV, maxV));
    }
  }
  return out;
}

// â”€â”€ CREASE EXTRACTION ISOLATE â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

/// Top-level isolate function.  Returns a flat [x0, y0, x1, y1, â€¦] list of
/// normalised (0â€“1) crease-pixel positions â€” â‰¤200 points (â‰¤400 doubles).
List<double> _extractCreaseIsolate(Uint8List bytes) {
  final src = img.decodeImage(bytes);
  if (src == null) return [];

  final green  = _green(src);
  final clahe  = _clahe(green);
  final binary = _adaptiveThreshold(clahe, blockSize: 21, c: 8);
  // Morphological opening = erode then dilate â€” removes isolated noise speckles
  final opened = _morphDilate3(_morphErode3(binary));

  final w = opened.width, h = opened.height;

  // Collect crease pixels (value == 0 after threshold)
  final List<int> xs = [], ys = [];
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      if (opened.getPixel(x, y).r.toInt() == 0) {
        xs.add(x); ys.add(y);
      }
    }
  }

  // Fallback: use CLAHE values < 60 if morphological result is sparse
  if (xs.length < 50) {
    xs.clear(); ys.clear();
    final scores = <int>[];
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final v = clahe.getPixel(x, y).r.toInt();
        if (v < 60) { xs.add(x); ys.add(y); scores.add(v); }
      }
    }
    // Sort by darkness (smallest value = darkest = most significant crease)
    final idx = List<int>.generate(xs.length, (i) => i)
      ..sort((a, b) => scores[a].compareTo(scores[b]));
    return _sampleCreasePoints(xs, ys, idx, w, h);
  }

  final idx = List<int>.generate(xs.length, (i) => i);
  return _sampleCreasePoints(xs, ys, idx, w, h);
}

List<double> _sampleCreasePoints(
    List<int> xs, List<int> ys, List<int> idx, int w, int h) {
  if (xs.isEmpty) return [];
  final result = <double>[];
  final step   = xs.length > 200 ? xs.length / 200.0 : 1.0;
  for (double i = 0; i < xs.length && result.length < 400; i += step) {
    final j = idx[i.toInt()];
    result.add(xs[j] / (w - 1.0));
    result.add(ys[j] / (h - 1.0));
  }
  return result;
}

// â”€â”€ CalibrationReport â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
/// Aggregated calibration metrics collected silently during a palm-scan session.
class CalibrationReport {
  final int    totalFrames;
  final int    goodFrames;
  final double avgHandSizePx;
  final double avgSharpness;
  final double avgBrightness;
  final double avgAlignmentScore;
  final String recommendation;

  const CalibrationReport({
    required this.totalFrames,
    required this.goodFrames,
    required this.avgHandSizePx,
    required this.avgSharpness,
    required this.avgBrightness,
    required this.avgAlignmentScore,
    required this.recommendation,
  });
}
