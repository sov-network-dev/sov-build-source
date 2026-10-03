// lib/sov_node_sdk/qr_decoder.dart
// ─────────────────────────────────────────────────────────────────────────────
// QR DECODING — pure Dart, no native code, no Google Play Services.
//
// WHY THIS EXISTS. The app used to decode QR codes through mobile_scanner,
// which pulls com.google.mlkit:barcode-scanning on Android. That is proprietary
// Google Play Services, and F-Droid will not build an app that carries one —
// F-Droid being the one Android channel that asks no operator for a government
// ID, which is the whole reason for shipping there. This replaces it with
// zxing2, a pure-Dart Apache-2.0 port of ZXing, fed by the `camera` plugin the
// app already depends on for palm capture.
//
// Nothing here touches the network, and no image is written to disk.
// ─────────────────────────────────────────────────────────────────────────────
import 'dart:io' show File;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';

/// A crop of an 8-bit luminance plane, read in place.
///
/// zxing2 ships a PlanarYUVLuminanceSource that does this, but does not export
/// it — and importing another package's `src/` is a dependency that breaks
/// silently on upgrade. This is the same idea in twenty lines against the
/// public `LuminanceSource` interface: no copy of the frame is made, the stride
/// is honoured, and the crop is applied by offset arithmetic.
class _CroppedPlane extends LuminanceSource {
  final Int8List _plane;
  final int _stride;
  final int _left;
  final int _top;

  _CroppedPlane(this._plane, this._stride, this._left, this._top,
      int width, int height)
      : super(width, height);

  @override
  Int8List getRow(int y, Int8List? row) {
    final out = (row == null || row.length < width) ? Int8List(width) : row;
    final offset = (y + _top) * _stride + _left;
    out.setRange(0, width, _plane, offset);
    return out;
  }

  @override
  Int8List getMatrix() {
    final out = Int8List(width * height);
    for (int y = 0; y < height; y++) {
      out.setRange(y * width, (y + 1) * width, _plane,
          (y + _top) * _stride + _left);
    }
    return out;
  }
}

class QrDecoder {
  /// Decode a QR code from a camera frame's LUMINANCE plane.
  ///
  /// [rowStride] is the plane's bytes per row, which is often WIDER than
  /// [width] — the camera pads rows, and reading the plane as though it were
  /// tightly packed shears the image and decodes nothing at all.
  ///
  /// Only the centre square is searched, matching the viewfinder cut-out the
  /// citizen is aiming with. That is not only faster: it also stops a second
  /// QR code elsewhere in shot from being read instead of the one they aimed
  /// at — which on this screen would mean paying the wrong address.
  static String? decodeLuminance(
    Uint8List luma, {
    required int width,
    required int height,
    required int rowStride,
    double cropFraction = 0.7,
  }) {
    try {
      final side = (math.min(width, height) * cropFraction).round();
      if (side < 32) return null;
      final left = ((width - side) / 2).round();
      final top = ((height - side) / 2).round();
      if (left + side > rowStride || top + side > height) return null;

      return _read(_CroppedPlane(
        luma.buffer.asInt8List(luma.offsetInBytes, luma.lengthInBytes),
        rowStride, left, top, side, side,
      ));
    } catch (_) {
      // A malformed frame is ordinary — the next one arrives in milliseconds.
      return null;
    }
  }

  /// Decode a QR code from packed BGRA8888, the iOS camera stream format.
  /// Converted to luminance here rather than asking the binarizer to walk
  /// 4-byte pixels: the same arithmetic, done once instead of per read.
  static String? decodeBgra(
    Uint8List bgra, {
    required int width,
    required int height,
    required int rowStride,
  }) {
    try {
      final luma = Uint8List(width * height);
      for (int y = 0; y < height; y++) {
        int si = y * rowStride;
        int di = y * width;
        for (int x = 0; x < width; x++, si += 4, di++) {
          // Rec. 601 luma in integer form.
          final b = bgra[si], g = bgra[si + 1], r = bgra[si + 2];
          luma[di] = ((66 * r + 129 * g + 25 * b + 128) >> 8) + 16;
        }
      }
      return decodeLuminance(luma,
          width: width, height: height, rowStride: width);
    } catch (_) {
      return null;
    }
  }

  /// Decode a QR code from an image FILE — the gallery path, for a code that
  /// arrived as a screenshot or a photo rather than on someone's screen.
  ///
  /// Runs on a background isolate: a full-resolution photo takes long enough
  /// to decode that doing it on the UI thread visibly freezes the screen.
  static Future<String?> decodeImageFile(String path) =>
      compute(_decodeFileSync, path);

  static String? _decodeFileSync(String path) {
    try {
      final decoded = img.decodeImage(File(path).readAsBytesSync());
      if (decoded == null) return null;

      // Large photos are downscaled first. A QR code that fills a 4000px photo
      // is still perfectly readable at 1600px, and the binarizer's cost grows
      // with the pixel count.
      final image = (decoded.width > 1600 || decoded.height > 1600)
          ? img.copyResize(decoded,
              width: decoded.width >= decoded.height ? 1600 : null,
              height: decoded.height > decoded.width ? 1600 : null)
          : decoded;

      // The whole image, not a centre crop: the citizen chose this file
      // deliberately, and the code may sit anywhere in a screenshot.
      final luma = Uint8List(image.width * image.height);
      int i = 0;
      for (int y = 0; y < image.height; y++) {
        for (int x = 0; x < image.width; x++) {
          final p = image.getPixel(x, y);
          luma[i++] = ((66 * p.r.toInt() +
                      129 * p.g.toInt() +
                      25 * p.b.toInt() +
                      128) >>
                  8) +
              16;
        }
      }
      return _read(_CroppedPlane(
        luma.buffer.asInt8List(),
        image.width, 0, 0, image.width, image.height,
      ));
    } catch (_) {
      return null;
    }
  }

  static String? _read(LuminanceSource source) {
    final reader = QRCodeReader();
    // Two passes. The hybrid binarizer reads a photographed code under uneven
    // light better; the global-histogram one succeeds on the flat, evenly lit
    // case — a code on another phone's screen — where hybrid sometimes fails.
    // Trying both costs milliseconds and widens what actually scans.
    for (final binarizer in <Binarizer>[
      HybridBinarizer(source),
      GlobalHistogramBinarizer(source),
    ]) {
      try {
        final text = reader.decode(BinaryBitmap(binarizer)).text;
        if (text.isNotEmpty) return text;
      } catch (_) {
        // NotFound / Checksum / Format — try the next binarizer.
      }
    }
    return null;
  }
}
