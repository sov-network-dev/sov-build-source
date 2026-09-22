// lib/sov_node_sdk/palm_embedder.dart
// ─────────────────────────────────────────────────────────────────────────────
// PALM FORENSIC DNA — Landmark Alignment + LBP Crease Extraction
//
// THE ROOT CAUSE OF RANGERROR (now fixed):
// img.copyRotate() expands the image to fit the rotated bounding box.
// A 256×256 image rotated 45° becomes 362×362.
// Previous versions cropped from this expanded image, and somewhere
// the expanded dimensions leaked into the LBP pixel array.
//
// THE FIX (one line):
// After copyRotate, immediately resize back to exactly 256×256.
// This forces the coordinate space back to known dimensions before crop.
// The crop of 128×128 from centre of 256×256 is then guaranteed.
//
// PIPELINE:
//   1. Decode JPEG → resize to 256×256  (fixed working space)
//   2. Compute rotation from landmarks
//   3. copyRotate → IMMEDIATELY resize back to 256×256
//   4. Crop 128×128 from centre
//   5. Grayscale + CLAHE (on guaranteed 128×128)
//   6. LBP on 128×128 → always exactly 3776 features
//   7. Geometry features → always exactly 19
//   8. Fuse 3795 → project to 128 → L2 normalise
//
// UNIQUENESS:
// LBP captures the forensic pattern of palm creases — the heart line,
// head line, and life line. These are as unique as fingerprints.
// Same person = same crease pattern = same LBP histogram = same DNA.
// Different person = different creases = different DNA.
// This is what enforces one-person-one-wallet.
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;

// ════════════════════════════════════════════════════════════════════════════
// TOP-LEVEL ISOLATE ENTRY POINT
// ════════════════════════════════════════════════════════════════════════════

Future<Map<String, dynamic>> palmDnaIsolate(Map<String, dynamic> args) async {
  final bytes  = args['bytes']  as Uint8List;
  final imgW   = (args['imgW']  as num).toDouble();
  final imgH   = (args['imgH']  as num).toDouble();
  final wristX = (args['wristX'] as num).toDouble();
  final wristY = (args['wristY'] as num).toDouble();
  final indexX = (args['indexX'] as num).toDouble();
  final indexY = (args['indexY'] as num).toDouble();
  final pinkyX = (args['pinkyX'] as num).toDouble();
  final pinkyY = (args['pinkyY'] as num).toDouble();
  final thumbX = (args['thumbX'] as num).toDouble();
  final thumbY = (args['thumbY'] as num).toDouble();

  // DIAGNOSTIC: wrap entire pipeline to report exact failure point
  final log = StringBuffer();
  log.writeln('START imgW=$imgW imgH=$imgH bytes=${bytes.length}');

  // PROFILING: per-stage wall-clock (µs). Purely additive — never touches the
  // embedding values (those must stay byte-identical for enrolled citizens).
  final timings = <String, int>{};
  final sw = Stopwatch()..start();
  void lap(String k) { timings[k] = sw.elapsedMicroseconds; sw.reset(); }

  try {
    // ── STEP 1: DECODE → RESIZE TO 256×256 ─────────────────────────────────
    final decoded = img.decodeImage(bytes);
    if (decoded == null) throw Exception('STEP1: Image decode returned null');
    log.writeln('STEP1 decoded: ${decoded.width}x${decoded.height}');

    final working = _forceSize(decoded, 384, 384);
    if (working.width != 384 || working.height != 384) {
      throw Exception('STEP1 FAIL: working=${working.width}x${working.height} expected 384x384');
    }
    log.writeln('STEP1 working: ${working.width}x${working.height} OK');
    lap('decode_resize');

  // ── STEP 2+3: SCALE LANDMARKS → WRIST-CENTRED CROP ─────────────────────
  // NO ROTATION — rotation causes jitter from landmark variation
  // The oval constraint ensures consistent hand position
  // We crop a fixed region centred on the wrist landmark instead
  //
  // Wrist is the most stable ML Kit landmark.
  // Fixed crop around wrist = same palm region every scan = high similarity.
  final scaleX = 384.0 / imgW;
  final scaleY = 384.0 / imgH;
  final wx = wristX * scaleX, wy = wristY * scaleY;
  final ix = indexX * scaleX, iy = indexY * scaleY;

  // Palm height = wrist to index distance, use to set crop size
  final palmH = ((iy - wy).abs()).clamp(60.0, 200.0);
  // Wider crop 1.8x palm height — reduces sensitivity to hand position variation
  // Minimum 160px ensures enough palm area captured even for small hands
  final cropSize = (palmH * 1.8).toInt().clamp(160, 300);
  final palmCentreX = ((wx + ix) / 2).toInt();
  final palmCentreY = ((wy + iy) / 2).toInt();
  final cx = (palmCentreX - cropSize ~/ 2).clamp(0, 384 - cropSize);
  final cy = (palmCentreY - cropSize ~/ 2).clamp(0, 384 - cropSize);
  final cw = cropSize.clamp(1, 384 - cx);
  final ch = cropSize.clamp(1, 384 - cy);

  log.writeln('STEP3 wrist=(${wx.toInt()},${wy.toInt()}) cropSize=$cropSize');
  final rawCrop = img.copyCrop(working, x: cx, y: cy, width: cw, height: ch);
  log.writeln('STEP4 rawCrop: ${rawCrop.width}x${rawCrop.height}');
  final cropped = _forceSize(rawCrop, 128, 128);
  if (cropped.width != 128 || cropped.height != 128) {
    throw Exception('STEP4 FAIL: cropped=${cropped.width}x${cropped.height}');
  }
  log.writeln('STEP4 cropped: ${cropped.width}x${cropped.height} OK');

    // ── STEP 5: GREEN CHANNEL + UNSHARP MASK + CLAHE ──────────────────────
    // Green channel gives best palm crease contrast vs grayscale average.
    // Unsharp mask sharpens crease edges BEFORE CLAHE amplifies them.
    // clipLimit 6.0 (up from 4.0) for deeper crease amplification.
    final green    = _extractGreenChannel(cropped);
    final sharp    = _unsharpMask(green);
    final enhanced = _clahe(sharp, clipLimit: 6.0);
    log.writeln('STEP5 enhanced: \${enhanced.width}x\${enhanced.height}');
    if (enhanced.width != 128 || enhanced.height != 128) {
      throw Exception('STEP5 FAIL: enhanced=\${enhanced.width}x\${enhanced.height}');
    }

    lap('enhance');
    // ── STEP 6: LBP ──────────────────────────────────────────────────────
    // Gaussian blur before LBP — removes noise, keeps crease structure
    final blurred = _gaussianBlur(enhanced);
    final lbpFeatures = _lbp(blurred);
    log.writeln('STEP6 lbp: ${lbpFeatures.length} features');
    if (lbpFeatures.length != 3776) {
      throw Exception('STEP6 FAIL: lbp=${lbpFeatures.length} expected 3776');
    }
    lap('gaussian_lbp');

    // ── STEP 7: GEOMETRY ─────────────────────────────────────────────────
    final geoFeatures = _geometry(
        wristX: wristX, wristY: wristY,
        indexX: indexX, indexY: indexY,
        pinkyX: pinkyX, pinkyY: pinkyY,
        thumbX: thumbX, thumbY: thumbY);
    log.writeln('STEP7 geo: ${geoFeatures.length} features');

    // ── STEP 8: FUSE → PROJECT → NORMALISE ───────────────────────────────
    const int featureSize = 3795;
    final fused = <double>[...lbpFeatures, ...geoFeatures];
    log.writeln('STEP8 fused: ${fused.length} features');

    final safe = fused.length == featureSize
        ? fused
        : (fused.length > featureSize
            ? fused.sublist(0, featureSize)
            : [...fused, ...List<double>.filled(featureSize - fused.length, 0.0)]);

    final projected   = _project(safe, featureSize);
    final normalised2 = _l2Normalize(projected);
    log.writeln('STEP8 done: ${normalised2.length} output floats');
    lap('project_normalise');

    // Enhanced 128x128 JPEG is ONLY for the dev diagnostic screen. Skip the encode
    // in the enrollment/auth hot path (wantEnhanced=false) — it was pure waste there.
    final wantEnhanced = args['wantEnhanced'] == true;
    final enhancedBytes = wantEnhanced
        ? img.encodeJpg(enhanced, quality: 90)
        : Uint8List(0);
    lap('encode_jpg');
    timings['total'] = timings.values.fold(0, (a, b) => a + b);

    return {
      'embedding':     normalised2.take(128).toList(),
      'enhancedImage': enhancedBytes,
      'timings':       timings,
    };

  } catch (e, stack) {
    // Rethrow with full diagnostic log prepended
    throw Exception('DIAGNOSTIC LOG:\n$log\nERROR: $e\nSTACK: $stack');
  }
}

// ════════════════════════════════════════════════════════════════════════════
// ── GREEN CHANNEL EXTRACTION ─────────────────────────────────────────────
// Extracts green channel only — best contrast for palm creases.
// Palm creases are darker shadows; green channel maximises this contrast
// compared to averaging R+G+B (standard grayscale).
// ── PERF HELPERS (byte-identical to getPixel/setPixel) ──────────────────────
// _chan: flat row-major channel buffer (0=R,1=G,2=B). getBytes(rgb) is proven
// byte-identical to getPixel().r/.g/.b (see embed_golden_test.dart).
Uint8List _chan(img.Image src, int ch) {
  final b = src.getBytes(order: img.ChannelOrder.rgb);
  final n = src.width * src.height;
  final out = Uint8List(n);
  for (int i = 0; i < n; i++) { out[i] = b[i * 3 + ch]; }
  return out;
}
// _grayImage: build an image with r=g=b=v[i] — identical to per-pixel
// setPixel(ColorRgb8(v,v,v)). The golden guard verifies the round-trip.
img.Image _grayImage(int w, int h, List<int> v) {
  final buf = Uint8List(w * h * 3);
  for (int i = 0; i < w * h; i++) {
    final g = v[i]; final o = i * 3;
    buf[o] = g; buf[o + 1] = g; buf[o + 2] = g;
  }
  return img.Image.fromBytes(
      width: w, height: h, bytes: buf.buffer, numChannels: 3,
      order: img.ChannelOrder.rgb);
}

img.Image _extractGreenChannel(img.Image src) {
  final gch = _chan(src, 1); // green, byte-identical to getPixel().g
  final v = List<int>.filled(gch.length, 0);
  for (int i = 0; i < gch.length; i++) { v[i] = gch[i].clamp(0, 255); }
  return _grayImage(src.width, src.height, v);
}

// ── UNSHARP MASK ──────────────────────────────────────────────────────────
// Sharpens crease edges BEFORE CLAHE so CLAHE amplifies sharp edges.
// Formula: output = original + strength * (original - blurred)
// strength=1.8 makes thin crease lines visually pop like skeleton lines.
img.Image _unsharpMask(img.Image src) {
  final blurred = _gaussianBlur(src);
  final o = _chan(src, 0);
  final b = _chan(blurred, 0);
  const strength = 1.8;
  final out = List<int>.filled(o.length, 0);
  for (int i = 0; i < o.length; i++) {
    final orig = o[i], blur = b[i];
    out[i] = (orig + strength * (orig - blur)).round().clamp(0, 255);
  }
  return _grayImage(src.width, src.height, out);
}

// CLAHE — operates on exactly 128×128 input
// Uses const dimensions throughout — no dynamic sizing
// ════════════════════════════════════════════════════════════════════════════
// ── GUARANTEED RESIZE ────────────────────────────────────────────────────
// img.copyResize can return +1 pixel due to float rounding in box filter.
// This function creates an exact-size image by copying pixels manually.
// GUARANTEED to return exactly targetW x targetH.
img.Image _forceSize(img.Image src, int targetW, int targetH) {
  // First use copyResize to get close
  final resized = img.copyResize(src,
      width: targetW, height: targetH,
      interpolation: img.Interpolation.linear);
  // If already exact, return directly
  if (resized.width == targetW && resized.height == targetH) return resized;
  // Otherwise copy pixels into guaranteed-size canvas
  final canvas = img.Image(width: targetW, height: targetH);
  for (int y = 0; y < targetH; y++) {
    for (int x = 0; x < targetW; x++) {
      final sx = x.clamp(0, resized.width  - 1);
      final sy = y.clamp(0, resized.height - 1);
      canvas.setPixel(x, y, resized.getPixel(sx, sy));
    }
  }
  return canvas;
}

img.Image _clahe(img.Image input, {int tileSize = 16, double clipLimit = 3.0}) {
  // Force 128×128 as absolute first operation inside CLAHE
  final grey = (input.width == 128 && input.height == 128)
      ? input
      : _forceSize(input, 128, 128);

  const int w = 128, h = 128;
  final pixels = List<int>.filled(w * h, 0);

  final gbuf = _chan(grey, 0); // row-major red, == grey.getPixel(x,y).r.toInt()
  for (int i = 0; i < w * h; i++) { pixels[i] = gbuf[i]; }

  final tilesX = w ~/ tileSize; // 8
  final tilesY = h ~/ tileSize; // 8
  final luts   = <List<int>>[];

  for (int ty = 0; ty < tilesY; ty++) {
    for (int tx = 0; tx < tilesX; tx++) {
      final x0 = tx * tileSize, y0 = ty * tileSize;
      final x1 = x0 + tileSize,  y1 = y0 + tileSize;
      final hist = List<int>.filled(256, 0);

      for (int y = y0; y < y1; y++) {
        for (int x = x0; x < x1; x++) {
          hist[pixels[y * w + x]]++;
        }
      }

      final tilePixels = tileSize * tileSize;
      final limit = max(1, (clipLimit * tilePixels / 256).round());
      int excess = 0;
      for (int i = 0; i < 256; i++) {
        if (hist[i] > limit) { excess += hist[i] - limit; hist[i] = limit; }
      }
      final add = excess ~/ 256;
      for (int i = 0; i < 256; i++) { hist[i] += add; }

      final lut = List<int>.filled(256, 0);
      int cdf = 0, cdfMin = -1;
      for (int i = 0; i < 256; i++) {
        cdf += hist[i];
        if (cdfMin == -1 && hist[i] > 0) cdfMin = cdf;
        lut[i] = ((cdf - cdfMin) * 255 ~/ max(1, tilePixels - cdfMin))
            .clamp(0, 255);
      }
      luts.add(lut);
    }
  }

  final outVals = List<int>.filled(w * h, 0);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final src = pixels[y * w + x];
      final tx  = (x / tileSize - 0.5).clamp(0.0, tilesX - 1.0);
      final ty  = (y / tileSize - 0.5).clamp(0.0, tilesY - 1.0);
      final tx0 = tx.floor().clamp(0, tilesX - 1);
      final ty0 = ty.floor().clamp(0, tilesY - 1);
      final tx1 = min(tx0 + 1, tilesX - 1);
      final ty1 = min(ty0 + 1, tilesY - 1);
      final fx  = tx - tx0, fy = ty - ty0;
      final v00 = luts[ty0 * tilesX + tx0][src];
      final v10 = luts[ty0 * tilesX + tx1][src];
      final v01 = luts[ty1 * tilesX + tx0][src];
      final v11 = luts[ty1 * tilesX + tx1][src];
      final val = ((v00*(1-fx)+v10*fx)*(1-fy)+(v01*(1-fx)+v11*fx)*fy)
          .round().clamp(0, 255);
      outVals[y * w + x] = val;
    }
  }
  return _grayImage(w, h, outVals);
}

// ════════════════════════════════════════════════════════════════════════════
// LBP — Local Binary Pattern
// Input MUST be 128×128. Uses only const dimensions — no dynamic sizing.
// Output: exactly 64 × 59 = 3776 floats — always
// ════════════════════════════════════════════════════════════════════════════
const List<int> _lbpLUT = [
  0, 1, 2, 3, 4, 58, 5, 6, 7, 58, 58, 58, 8, 58, 9, 10,
  11, 58, 58, 58, 58, 58, 58, 58, 12, 58, 58, 58, 13, 58, 14, 15,
  16, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58,
  17, 58, 58, 58, 58, 58, 58, 58, 18, 58, 58, 58, 19, 58, 20, 21,
  22, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58,
  58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58,
  23, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58,
  24, 58, 58, 58, 58, 58, 58, 58, 25, 58, 58, 58, 26, 58, 27, 28,
  29, 30, 58, 31, 58, 58, 58, 32, 58, 58, 58, 58, 58, 58, 58, 33,
  58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 34,
  58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58,
  58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 35,
  36, 37, 58, 38, 58, 58, 58, 39, 58, 58, 58, 58, 58, 58, 58, 40,
  58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 41,
  42, 43, 58, 44, 58, 58, 58, 45, 58, 58, 58, 58, 58, 58, 58, 46,
  47, 48, 58, 49, 58, 58, 58, 50, 51, 52, 58, 53, 54, 55, 56, 57,
];

// ── GAUSSIAN BLUR ─────────────────────────────────────────────────────────
// 3x3 Gaussian kernel — removes scan-to-scan pixel noise
// Palm crease lines are low-frequency and survive this blur
// Result: more consistent LBP histograms across scans of same palm
img.Image _gaussianBlur(img.Image src) {
  const int size = 128;
  // Force 128x128
  final input = (src.width == size && src.height == size)
      ? src : img.copyResize(src, width: size, height: size);

  final g = _chan(input, 0); // row-major red, == input.getPixel(x,y).r.toInt()
  final out = List<int>.filled(size * size, 0);

  // 3x3 Gaussian kernel (sigma=1.0)
  const kernel = [
    1, 2, 1,
    2, 4, 2,
    1, 2, 1,
  ];
  for (int y = 0; y < size; y++) {
    for (int x = 0; x < size; x++) {
      int sum = 0;
      int w = 0;
      for (int ky = -1; ky <= 1; ky++) {
        for (int kx = -1; kx <= 1; kx++) {
          final nx = (x + kx).clamp(0, size - 1);
          final ny = (y + ky).clamp(0, size - 1);
          final k  = kernel[(ky+1)*3 + (kx+1)];
          sum += g[ny * size + nx] * k;
          w   += k;
        }
      }
      out[y * size + x] = (sum / w).round().clamp(0, 255);
    }
  }
  return _grayImage(size, size, out);
}

List<double> _lbp(img.Image image) {
  const int imgSize  = 128;
  const int cellSize = 16;
  const int nCells   = imgSize ~/ cellSize; // 8
  const int nBins    = 59;

  // Force 128×128 as first operation — double safety
  final src = (image.width == imgSize && image.height == imgSize)
      ? image
      : _forceSize(image, imgSize, imgSize);

  // Extract greyscale into flat array of FIXED size (row-major red == getPixel().r)
  final gbuf = _chan(src, 0);
  final grey = List<int>.filled(imgSize * imgSize, 0);
  for (int i = 0; i < imgSize * imgSize; i++) { grey[i] = gbuf[i]; }

  const dx = [-1, 0, 1, 1, 1, 0, -1, -1];
  const dy = [-1, -1, -1, 0, 1, 1, 1, 0];

  final result = <double>[];

  for (int cy = 0; cy < nCells; cy++) {
    for (int cx = 0; cx < nCells; cx++) {
      final hist = List<int>.filled(nBins, 0);
      final x0 = cx * cellSize, y0 = cy * cellSize;

      for (int y = y0 + 1; y < y0 + cellSize - 1; y++) {
        for (int x = x0 + 1; x < x0 + cellSize - 1; x++) {
          final centre = grey[y * imgSize + x];
          int lbp = 0;
          for (int n = 0; n < 8; n++) {
            if (grey[(y + dy[n]) * imgSize + (x + dx[n])] >= centre) {
              lbp |= (1 << n);
            }
          }
          hist[_lbpLUT[lbp]]++;
        }
      }

      final total = hist.fold(0, (s, v) => s + v);
      result.addAll(total > 0
          ? hist.map((v) => v / total)
          : List<double>.filled(nBins, 0.0));
    }
  }

  return result; // always 8×8×59 = 3776
}

// ════════════════════════════════════════════════════════════════════════════
// GEOMETRY — 19 fixed features
// ════════════════════════════════════════════════════════════════════════════
List<double> _geometry({
  required double wristX, required double wristY,
  required double indexX, required double indexY,
  required double pinkyX, required double pinkyY,
  required double thumbX, required double thumbY,
}) {
  final ix = indexX-wristX, iy = indexY-wristY;
  final px = pinkyX-wristX, py = pinkyY-wristY;
  final tx = thumbX-wristX, ty = thumbY-wristY;

  final scale = sqrt(ix*ix + iy*iy);
  if (scale < 0.01) return List<double>.filled(19, 0.0);

  final angle = atan2(iy, ix);
  final rot = -pi/2 - angle;
  final c = cos(rot), s = sin(rot);

  List<double> r(double x, double y) => [
    (x/scale)*c - (y/scale)*s,
    (x/scale)*s + (y/scale)*c,
  ];

  final pts = [[0.0,0.0], r(ix,iy), r(px,py), r(tx,ty)];
  final f = <double>[];

  for (int i = 1; i < 4; i++) { f.add(pts[i][0]); f.add(pts[i][1]); }
  for (int i = 0; i < 4; i++) {
    for (int j = i+1; j < 4; j++) {
      final ddx=pts[i][0]-pts[j][0], ddy=pts[i][1]-pts[j][1];
      f.add(sqrt(ddx*ddx+ddy*ddy));
    }
  }
  for (int v = 0; v < 4; v++) {
    double a=0; int cnt=0;
    for (int aa=0; aa<4; aa++) {
      if (aa==v) continue;
      for (int b=aa+1; b<4; b++) {
        if (b==v) continue;
        final ax=pts[aa][0]-pts[v][0], ay=pts[aa][1]-pts[v][1];
        final bx=pts[b][0]-pts[v][0],  by=pts[b][1]-pts[v][1];
        final ma=sqrt(ax*ax+ay*ay), mb=sqrt(bx*bx+by*by);
        if (ma>0.001&&mb>0.001) {
          a+=acos(((ax*bx+ay*by)/(ma*mb)).clamp(-1.0,1.0)); cnt++;
        }
      }
    }
    f.add(cnt>0?a/cnt:0.0);
  }
  for (int i=0; i<3; i++) {
    final ax=pts[i+1][0]-pts[i][0], ay=pts[i+1][1]-pts[i][1];
    final bx=pts[(i+2)%4][0]-pts[i][0], by=pts[(i+2)%4][1]-pts[i][1];
    f.add(ax*by - ay*bx);
  }
  return f; // exactly 19
}

// ════════════════════════════════════════════════════════════════════════════
// PROJECTION + NORMALISE
// ════════════════════════════════════════════════════════════════════════════
List<double>? _projMatrix;

List<double> _project(List<double> features, int n) {
  if (_projMatrix == null || _projMatrix!.length != 128 * n) {
    _projMatrix = _buildMatrix(n, 128, seed: 42);
  }
  final result = List<double>.filled(128, 0.0);
  for (int j = 0; j < 128; j++) {
    double sum = 0.0;
    for (int i = 0; i < n; i++) { sum += features[i] * _projMatrix![j*n+i]; }
    result[j] = sum;
  }
  return result;
}

List<double> _buildMatrix(int rows, int cols, {required int seed}) {
  final m = List<double>.filled(cols * rows, 0.0);
  int state = seed;
  double nr() {
    state = ((state * 1664525) + 1013904223) & 0xFFFFFFFF;
    return (state & 0xFFFFFF) / 16777216.0 + 1e-10;
  }
  double ng() => sqrt(-2.0 * log(nr())) * cos(2.0 * pi * nr());
  final sc = 1.0 / sqrt(rows.toDouble());
  for (int i = 0; i < cols * rows; i++) { m[i] = ng() * sc; }
  return m;
}

List<double> _l2Normalize(List<double> v) {
  final norm = sqrt(v.fold(0.0, (s, x) => s + x*x));
  if (norm < 1e-10) return List<double>.filled(v.length, 0.0);
  return v.map((x) => x/norm).toList();
}

// ════════════════════════════════════════════════════════════════════════════
// PUBLIC API
// ════════════════════════════════════════════════════════════════════════════
class PalmEmbedder {
  static Future<void> load() async {}
  static void dispose() {}
  static bool get isLoaded => true;

  static Future<PalmResult> embedInIsolate({
    required Uint8List jpegBytes,
    required double imgW,
    required double imgH,
    required double wristX, required double wristY,
    required double indexX, required double indexY,
    required double pinkyX, required double pinkyY,
    required double thumbX, required double thumbY,
    bool wantEnhanced = false,   // dev diagnostic screen sets true; hot path leaves false
  }) async {
    final result = await compute(palmDnaIsolate, {
      'bytes':  jpegBytes,
      'imgW':   imgW,   'imgH':   imgH,
      'wristX': wristX, 'wristY': wristY,
      'indexX': indexX, 'indexY': indexY,
      'pinkyX': pinkyX, 'pinkyY': pinkyY,
      'thumbX': thumbX, 'thumbY': thumbY,
      'wantEnhanced': wantEnhanced,
    });
    return PalmResult(
      embedding:     (result['embedding'] as List).cast<double>(),
      enhancedImage: result['enhancedImage'] as Uint8List,
      timings:       (result['timings'] as Map?)?.cast<String, int>(),
    );
  }

  static double cosineSimilarity(List<double> a, List<double> b) {
    double dot = 0, nA = 0, nB = 0;
    for (int i = 0; i < a.length; i++) {
      dot += a[i]*b[i]; nA += a[i]*a[i]; nB += b[i]*b[i];
    }
    if (nA == 0 || nB == 0) return 0;
    return dot / (sqrt(nA) * sqrt(nB));
  }
}

// ── PALM RESULT — embedding + enhanced image for diagnostic display ──────────
class PalmResult {
  final List<double> embedding;
  final Uint8List    enhancedImage;
  final Map<String, int>? timings;   // per-stage µs (profiling); null if unavailable
  const PalmResult({required this.embedding, required this.enhancedImage, this.timings});
}
