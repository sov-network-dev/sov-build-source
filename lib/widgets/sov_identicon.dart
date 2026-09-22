// lib/widgets/sov_identicon.dart
// ─────────────────────────────────────────────────────────────────────────────
// Deterministic 5×5 identicon generated from a Sovereign ID.
//
// Privacy model:
//   • Generated entirely client-side from SHA-256 of the Sovereign ID.
//   • Never uploaded to relay, never stored anywhere.
//   • Every citizen gets a unique, immutable visual identity locked to their ID.
//   • Citizens cannot change it — the network assigned it at enrollment.
//   • No photos, no names, no personal data in the network identity layer.
// ─────────────────────────────────────────────────────────────────────────────
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';

/// Renders a deterministic 5×5 symmetric identicon from a Sovereign ID.
///
/// Usage:
///   SovIdenticon(sovereignId: 'SOV-XXXX', size: 48)
///   SovIdenticon(sovereignId: 'SOV-XXXX', size: 72, borderRadius: 12)
class SovIdenticon extends StatelessWidget {
  final String sovereignId;
  final double size;
  final double borderRadius;

  const SovIdenticon({
    super.key,
    required this.sovereignId,
    this.size = 48,
    this.borderRadius = 8,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: CustomPaint(
        size: Size(size, size),
        painter: _IdenticonPainter(sovereignId),
      ),
    );
  }
}

class _IdenticonPainter extends CustomPainter {
  final String input;

  _IdenticonPainter(this.input);

  @override
  void paint(Canvas canvas, Size size) {
    final hashBytes = sha256.convert(utf8.encode(input)).bytes;

    // Foreground colour from bytes 0–2. Enforce a minimum brightness of 90
    // so identicons are always visible against the dark navy background.
    final r = max(90, hashBytes[0] & 0xFF);
    final g = max(90, hashBytes[1] & 0xFF);
    final b = max(90, hashBytes[2] & 0xFF);
    final fgPaint = Paint()..color = Color.fromARGB(255, r, g, b);
    const bgColor = Color(0xFF0A1628);

    // Draw background
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = bgColor,
    );

    final cellW = size.width / 5;
    final cellH = size.height / 5;
    const padding = 1.0; // 1px gap between cells

    // 5×5 grid mirrored left↔right — only determine left 3 columns (0,1,2).
    // col 3 = mirror of col 1, col 4 = mirror of col 0.
    // Bits are read from hashBytes starting at byte 3 (after the RGB bytes).
    for (int row = 0; row < 5; row++) {
      for (int col = 0; col < 3; col++) {
        final bitIndex = row * 3 + col;
        final byteIndex = 3 + (bitIndex ~/ 8);
        final bitPos = bitIndex % 8;
        final filled = (hashBytes[byteIndex] >> bitPos) & 1;

        if (filled == 1) {
          // Left/centre cell
          canvas.drawRect(
            Rect.fromLTWH(
              col * cellW + padding,
              row * cellH + padding,
              cellW - padding * 2,
              cellH - padding * 2,
            ),
            fgPaint,
          );
          // Mirror cell (skip centre col 2 — already drawn above)
          if (col < 2) {
            canvas.drawRect(
              Rect.fromLTWH(
                (4 - col) * cellW + padding,
                row * cellH + padding,
                cellW - padding * 2,
                cellH - padding * 2,
              ),
              fgPaint,
            );
          }
        }
      }
    }
  }

  @override
  bool shouldRepaint(_IdenticonPainter old) => old.input != input;
}
