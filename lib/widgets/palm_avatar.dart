// lib/widgets/palm_avatar.dart
// ─────────────────────────────────────────────────────────────────────────────
// SOV Network — Palm-Derived Generative Avatar Engine
//
// Generates a rich, visually distinct 2D avatar driven by the citizen's
// palm-derived name.  No AI API calls — everything is deterministic
// client-side geometry + color.  Snap-safe.
//
// HOW IT WORKS:
//   1. Parse adjective + noun from the palm name (e.g. "Iron" + "Hawk")
//   2. Map noun  → one of 6 visual archetypes (Wings/Flow/Fire/Mountain/Force/Edge)
//   3. Map adjective → one of 4 colour palettes (Cool/Warm/Ethereal/Vivid)
//   4. Use SHA-256 of (palmName + sovereignId) for fine entropy within archetype
//   5. Render 5 layered passes: gradient bg → archetype shape → texture ring →
//      inner accent → outer glow
//
// RESULT: 1,024 name combinations × SHA-256 entropy = millions of visually
//         unique avatars.  Same palm → same avatar, always.
//
// APP SIZE IMPACT: 0 KB (zero new packages — pure CustomPainter + dart:math)
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import '../sov_node_sdk/palm_name_engine.dart';

// ── Public widget ─────────────────────────────────────────────────────────────

/// Renders a deterministic generative avatar driven by the citizen's palm name.
///
/// Usage:
///   PalmAvatar(palmName: 'IronHawk',  sovereignId: sovId, size: 72)
///   PalmAvatar(palmName: 'WildTide',  sovereignId: sovId, size: 48, circular: true)
///   PalmAvatar.placeholder(size: 48)  // anonymous / not-yet-loaded
class PalmAvatar extends StatelessWidget {
  final String palmName;
  final String sovereignId;
  final double size;

  /// When true the avatar is clipped to a circle; otherwise rounded rect.
  final bool circular;

  const PalmAvatar({
    super.key,
    required this.palmName,
    required this.sovereignId,
    this.size = 48,
    this.circular = false,
  });

  /// Placeholder shown while the palm name is loading.
  factory PalmAvatar.placeholder({double size = 48, bool circular = false}) =>
      PalmAvatar(
        palmName: '',
        sovereignId: '',
        size: size,
        circular: circular,
      );

  @override
  Widget build(BuildContext context) {
    final radius = circular ? size / 2 : size * 0.22;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: CustomPaint(
        size: Size(size, size),
        painter: _PalmAvatarPainter(palmName, sovereignId),
      ),
    );
  }
}

// ── Archetype & palette enums ────────────────────────────────────────────────

enum _Archetype { wings, flow, fire, mountain, force, edge }
enum _Palette   { cool, warm, ethereal, vivid }

// ── Noun → archetype map ─────────────────────────────────────────────────────
const _nounArchetype = <String, _Archetype>{
  // Wings — arcing curves, flight-inspired
  'Hawk':  _Archetype.wings, 'Crow':  _Archetype.wings, 'Heron': _Archetype.wings,
  'Kite':  _Archetype.wings, 'Drake': _Archetype.wings,
  // Flow — wave/water/organic curves
  'Tide':  _Archetype.flow,  'River': _Archetype.flow,  'Shore': _Archetype.flow,
  'Veil':  _Archetype.flow,  'Mist':  _Archetype.flow,  'Reed':  _Archetype.flow,
  'Fern':  _Archetype.flow,  'Coil':  _Archetype.flow,
  // Fire — upward spikes and triangles
  'Flame': _Archetype.fire,  'Ember': _Archetype.fire,  'Forge': _Archetype.fire,
  'Ash':   _Archetype.fire,  'Gale':  _Archetype.fire,
  // Mountain — triangular silhouette, layered ridges
  'Ridge': _Archetype.mountain, 'Peak':  _Archetype.mountain, 'Dune': _Archetype.mountain,
  'Vale':  _Archetype.mountain, 'Spire': _Archetype.mountain, 'Crest': _Archetype.mountain,
  'Birch': _Archetype.mountain, 'Prism': _Archetype.mountain,
  // Force — radial vortex, concentric rings
  'Storm': _Archetype.force, 'Rift':  _Archetype.force, 'Thorn': _Archetype.force,
  'Flint': _Archetype.force,
  // Edge — geometric facets, sharp angles
  'Blade': _Archetype.edge,  'Wolf':  _Archetype.edge,  'Hollow': _Archetype.edge,
};

// Fallback archetype for any noun not in the map
_Archetype _archetypeFor(String noun) =>
    _nounArchetype[noun] ?? _Archetype.edge;

// ── Adjective → palette map ──────────────────────────────────────────────────
const _adjPalette = <String, _Palette>{
  // Cool — blues, teals, silvers
  'Still': _Palette.cool, 'Frost': _Palette.cool, 'Cold':  _Palette.cool,
  'Clear': _Palette.cool, 'Calm':  _Palette.cool, 'Lone':  _Palette.cool,
  'Silent': _Palette.cool, 'Bare': _Palette.cool, 'Deep':  _Palette.cool,
  // Warm — oranges, reds, coppers
  'Bold':  _Palette.warm, 'Iron':  _Palette.warm, 'Fierce': _Palette.warm,
  'Wild':  _Palette.warm, 'Ember': _Palette.warm, 'Dark':   _Palette.warm,
  'Stark': _Palette.warm, 'Grim':  _Palette.warm,
  // Ethereal — purples, gold, indigo
  'Bright': _Palette.ethereal, 'Dawn':  _Palette.ethereal, 'Dusk':  _Palette.ethereal,
  'Stone':  _Palette.ethereal, 'Ash':   _Palette.ethereal, 'Free':  _Palette.ethereal,
  'Whole':  _Palette.ethereal, 'Tide':  _Palette.ethereal,
  // Vivid — teal/cyan/green/gold
  'Swift': _Palette.vivid, 'Sharp': _Palette.vivid, 'True':  _Palette.vivid,
  'Storm': _Palette.vivid, 'Keen':  _Palette.vivid, 'Dry':   _Palette.vivid,
  'Hollow': _Palette.vivid,
};

_Palette _paletteFor(String adj) => _adjPalette[adj] ?? _Palette.vivid;

// ── Colour definitions per palette ───────────────────────────────────────────
// Returns [bg1, bg2, accent, symbol] for each palette
List<Color> _colorsFor(_Palette p, List<int> entropy) {
  // entropy[0..1] give a ±20 hue variation within the palette's range
  final h = (entropy[0] & 0x1F) - 16;  // -16..+15 offset

  switch (p) {
    case _Palette.cool:
      return [
        _hsl(200 + h, 0.70, 0.18),  // deep ocean bg
        _hsl(215 + h, 0.55, 0.28),  // lighter layer
        _hsl(185 + h, 1.00, 0.65),  // bright cyan accent
        _hsl(200 + h, 0.30, 0.90),  // near-white symbol
      ];
    case _Palette.warm:
      return [
        _hsl( 15 + h, 0.80, 0.16),  // deep rust bg
        _hsl( 30 + h, 0.75, 0.26),  // amber layer
        _hsl( 40 + h, 1.00, 0.65),  // gold accent
        _hsl(  5 + h, 0.30, 0.95),  // cream symbol
      ];
    case _Palette.ethereal:
      return [
        _hsl(270 + h, 0.55, 0.14),  // deep violet bg
        _hsl(290 + h, 0.50, 0.24),  // purple layer
        _hsl(295 + h, 0.90, 0.72),  // magenta/pink accent
        _hsl(255 + h, 0.25, 0.95),  // lavender symbol
      ];
    case _Palette.vivid:
      return [
        _hsl(162 + h, 0.60, 0.12),  // deep teal bg
        _hsl(175 + h, 0.55, 0.22),  // teal layer
        _hsl(150 + h, 1.00, 0.55),  // vivid green accent
        _hsl(160 + h, 0.15, 0.95),  // mint symbol
      ];
  }
}

// HSL → Color helper (s and l in [0,1])
Color _hsl(int h, double s, double l) {
  return HSLColor.fromAHSL(1.0, h.toDouble() % 360, s, l).toColor();
}

// ── Painter ───────────────────────────────────────────────────────────────────

class _PalmAvatarPainter extends CustomPainter {
  final String palmName;
  final String sovereignId;

  _PalmAvatarPainter(this.palmName, this.sovereignId);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;  // square canvas
    final cx = s / 2, cy = s / 2;

    // ── Parse name ────────────────────────────────────────────────────────────
    String adj = '', noun = '';
    if (palmName.isNotEmpty && PalmNameEngine.isValidPalmName(palmName)) {
      for (final a in _adjectives) {
        if (palmName.startsWith(a)) { adj = a; noun = palmName.substring(a.length); break; }
      }
    }
    if (adj.isEmpty || noun.isEmpty) {
      // Placeholder or unrecognised name — render generic teal disc
      _drawPlaceholder(canvas, size);
      return;
    }

    // ── Entropy bytes from SHA-256(palmName + sovereignId) ────────────────────
    final hashBytes = sha256.convert(utf8.encode('$palmName|$sovereignId')).bytes;

    // ── Palette + archetype ───────────────────────────────────────────────────
    final palette   = _paletteFor(adj);
    final archetype = _archetypeFor(noun);
    final colors    = _colorsFor(palette, hashBytes);

    final bg1    = colors[0];
    final bg2    = colors[1];
    final accent = colors[2];
    final sym    = colors[3];

    // ── Layer 0: Radial gradient background ───────────────────────────────────
    final bgPaint = Paint()
      ..shader = RadialGradient(
        center: Alignment(
          _frac(hashBytes[4], -0.3, 0.3),
          _frac(hashBytes[5], -0.3, 0.3),
        ),
        radius: 0.85,
        colors: [bg2, bg1],
      ).createShader(Rect.fromLTWH(0, 0, s, s));
    canvas.drawRect(Rect.fromLTWH(0, 0, s, s), bgPaint);

    // ── Layer 1: Secondary gradient band (diagonal) ───────────────────────────
    final angle2 = _frac(hashBytes[6], 0.0, pi * 2);
    final band = Paint()
      ..shader = LinearGradient(
        begin: Alignment(cos(angle2) * 0.8, sin(angle2) * 0.8),
        end:   Alignment(-cos(angle2) * 0.8, -sin(angle2) * 0.8),
        colors: [bg2.withAlpha(0), bg2.withAlpha(100), bg2.withAlpha(0)],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(Rect.fromLTWH(0, 0, s, s));
    canvas.drawRect(Rect.fromLTWH(0, 0, s, s), band);

    // ── Layer 2: Archetype shape ──────────────────────────────────────────────
    _drawArchetype(canvas, size, cx, cy, s, archetype, accent, sym, hashBytes);

    // ── Layer 3: Fine concentric texture rings ────────────────────────────────
    final ringCount = 3 + (hashBytes[20] & 3);  // 3–6 rings
    for (int i = 0; i < ringCount; i++) {
      final r = s * (0.28 + i * 0.085);
      canvas.drawCircle(
        Offset(cx, cy), r,
        Paint()
          ..color = sym.withAlpha(18 + i * 4)
          ..style  = PaintingStyle.stroke
          ..strokeWidth = 0.6,
      );
    }

    // ── Layer 4: Bright accent ring + glow ───────────────────────────────────
    // Outer glow
    canvas.drawCircle(
      Offset(cx, cy), s * 0.42,
      Paint()
        ..color    = accent.withAlpha(35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    // Accent ring
    canvas.drawCircle(
      Offset(cx, cy), s * 0.40,
      Paint()
        ..color       = accent.withAlpha(70)
        ..style       = PaintingStyle.stroke
        ..strokeWidth = s * 0.025,
    );

    // ── Layer 5: Central bright focal dot ─────────────────────────────────────
    canvas.drawCircle(
      Offset(cx, cy), s * 0.10,
      Paint()
        ..color    = accent.withAlpha(180)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.drawCircle(
      Offset(cx, cy), s * 0.065,
      Paint()..color = sym.withAlpha(230),
    );
  }

  // ── Archetype-specific shape rendering ────────────────────────────────────

  void _drawArchetype(
    Canvas canvas, Size size, double cx, double cy, double s,
    _Archetype arch, Color accent, Color sym, List<int> entropy,
  ) {
    switch (arch) {
      case _Archetype.wings:   _drawWings(canvas, cx, cy, s, accent, sym, entropy);    break;
      case _Archetype.flow:    _drawFlow(canvas, cx, cy, s, accent, sym, entropy);     break;
      case _Archetype.fire:    _drawFire(canvas, cx, cy, s, accent, sym, entropy);     break;
      case _Archetype.mountain:_drawMountain(canvas, cx, cy, s, accent, sym, entropy); break;
      case _Archetype.force:   _drawForce(canvas, cx, cy, s, accent, sym, entropy);    break;
      case _Archetype.edge:    _drawEdge(canvas, cx, cy, s, accent, sym, entropy);     break;
    }
  }

  // WINGS — Two sweeping arcs like outstretched wings
  void _drawWings(Canvas c, double cx, double cy, double s,
      Color accent, Color sym, List<int> e) {
    final spread = _frac(e[8], 0.55, 0.72) * s;
    final lift   = _frac(e[9], 0.12, 0.22) * s;
    final ctrl   = _frac(e[10], 0.30, 0.45) * s;

    final paint = Paint()
      ..color       = accent.withAlpha(100)
      ..style       = PaintingStyle.stroke
      ..strokeWidth = s * 0.055
      ..strokeCap   = StrokeCap.round;

    final fillPaint = Paint()
      ..color = accent.withAlpha(35)
      ..style = PaintingStyle.fill;

    // Left wing
    final left = Path()
      ..moveTo(cx, cy)
      ..quadraticBezierTo(cx - ctrl, cy - lift * 1.3, cx - spread, cy + lift * 0.4)
      ..quadraticBezierTo(cx - ctrl * 0.7, cy - lift * 0.3, cx, cy + lift * 0.2)
      ..close();
    c.drawPath(left, fillPaint);
    c.drawPath(left, paint);

    // Right wing (mirror)
    final right = Path()
      ..moveTo(cx, cy)
      ..quadraticBezierTo(cx + ctrl, cy - lift * 1.3, cx + spread, cy + lift * 0.4)
      ..quadraticBezierTo(cx + ctrl * 0.7, cy - lift * 0.3, cx, cy + lift * 0.2)
      ..close();
    c.drawPath(right, fillPaint);
    c.drawPath(right, paint);
  }

  // FLOW — Flowing S-curve with parallel echo lines
  void _drawFlow(Canvas c, double cx, double cy, double s,
      Color accent, Color sym, List<int> e) {
    final amp   = _frac(e[8], 0.22, 0.35) * s;
    final shift = _frac(e[9], -0.08, 0.08) * s;

    final paint = Paint()
      ..style       = PaintingStyle.stroke
      ..strokeWidth = s * 0.04
      ..strokeCap   = StrokeCap.round;

    // Draw 4 parallel wave arcs at decreasing opacity
    for (int i = 0; i < 4; i++) {
      final offset = (i - 1.5) * s * 0.10;
      final alpha  = 120 - i * 22;
      paint.color = accent.withAlpha(alpha);
      final path = Path()
        ..moveTo(cx - s * 0.38, cy + offset + shift)
        ..cubicTo(
          cx - s * 0.12, cy + offset + shift - amp,
          cx + s * 0.12, cy + offset + shift + amp,
          cx + s * 0.38, cy + offset + shift,
        );
      c.drawPath(path, paint);
    }
  }

  // FIRE — Upward-pointing flame spikes
  void _drawFire(Canvas c, double cx, double cy, double s,
      Color accent, Color sym, List<int> e) {
    final h    = _frac(e[8], 0.38, 0.52) * s;
    final w    = _frac(e[9], 0.22, 0.30) * s;
    final lean = _frac(e[10], -0.06, 0.06) * s;

    final fillPaint = Paint()..style = PaintingStyle.fill;
    final edgePaint = Paint()
      ..style       = PaintingStyle.stroke
      ..strokeWidth = s * 0.025
      ..strokeCap   = StrokeCap.round;

    // Draw 3 flame tongues: left, centre, right
    for (int i = -1; i <= 1; i++) {
      final x    = cx + i * w * 0.65;
      final hh   = h * (i == 0 ? 1.0 : 0.72);
      final base = cy + s * 0.22;
      final al   = i == 0 ? 130 : 80;

      final flame = Path()
        ..moveTo(x - w * 0.55 + lean, base)
        ..quadraticBezierTo(x - w * 0.35 + lean, base - hh * 0.55, x + lean * 0.3, base - hh)
        ..quadraticBezierTo(x + w * 0.35 - lean, base - hh * 0.55, x + w * 0.55 - lean, base)
        ..close();

      fillPaint.color = accent.withAlpha(al);
      edgePaint.color = sym.withAlpha(al + 40);
      c.drawPath(flame, fillPaint);
      c.drawPath(flame, edgePaint);
    }
  }

  // MOUNTAIN — Layered triangular silhouette
  void _drawMountain(Canvas c, double cx, double cy, double s,
      Color accent, Color sym, List<int> e) {
    final h    = _frac(e[8], 0.40, 0.55) * s;
    final w    = _frac(e[9], 0.46, 0.58) * s;
    final peak = _frac(e[10], -0.08, 0.08) * s;

    final base = cy + s * 0.22;

    for (int layer = 2; layer >= 0; layer--) {
      final scale = 1.0 - layer * 0.22;
      final yOff  = layer * s * 0.06;
      final al    = 60 + layer * 35;

      final path = Path()
        ..moveTo(cx + peak * (1 - layer * 0.3), base - h * scale + yOff)
        ..lineTo(cx + w * scale * 0.85, base + yOff)
        ..lineTo(cx - w * scale * 0.85, base + yOff)
        ..close();

      c.drawPath(path, Paint()..color = accent.withAlpha(al)..style = PaintingStyle.fill);
      c.drawPath(path,
          Paint()
            ..color       = sym.withAlpha(al + 30)
            ..style       = PaintingStyle.stroke
            ..strokeWidth = s * 0.018);
    }
  }

  // FORCE — Radial spokes / vortex
  void _drawForce(Canvas c, double cx, double cy, double s,
      Color accent, Color sym, List<int> e) {
    final spokeCount = 6 + (e[8] & 3);  // 6–9 spokes
    final outerR     = s * _frac(e[9], 0.32, 0.42);
    final innerR     = s * _frac(e[10], 0.10, 0.18);
    final twist      = _frac(e[11], 0.05, 0.20);

    final spokePaint = Paint()
      ..style       = PaintingStyle.stroke
      ..strokeWidth = s * 0.04
      ..strokeCap   = StrokeCap.round;

    for (int i = 0; i < spokeCount; i++) {
      final angleIn  = (i * 2 * pi / spokeCount);
      final angleOut = angleIn + twist * pi;
      final ix = cx + cos(angleIn)  * innerR;
      final iy = cy + sin(angleIn)  * innerR;
      final ox = cx + cos(angleOut) * outerR;
      final oy = cy + sin(angleOut) * outerR;

      final al = 85 + (i.isEven ? 30 : 0);
      spokePaint.color = accent.withAlpha(al);
      c.drawLine(Offset(ix, iy), Offset(ox, oy), spokePaint);
    }
  }

  // EDGE — Geometric star / crystal facets
  void _drawEdge(Canvas c, double cx, double cy, double s,
      Color accent, Color sym, List<int> e) {
    final pts    = 6 + (e[8] & 2);   // 6 or 8 points
    final outer  = s * _frac(e[9],  0.35, 0.44);
    final inner  = s * _frac(e[10], 0.14, 0.22);
    final rot    = _frac(e[11], 0.0, pi / 6);

    final path = Path();
    for (int i = 0; i < pts * 2; i++) {
      final r      = i.isEven ? outer : inner;
      final angle  = rot + i * pi / pts;
      final x = cx + cos(angle) * r;
      final y = cy + sin(angle) * r;
      if (i == 0) { path.moveTo(x, y); } else { path.lineTo(x, y); }
    }
    path.close();

    c.drawPath(path, Paint()..color = accent.withAlpha(85)..style = PaintingStyle.fill);
    c.drawPath(path,
        Paint()
          ..color       = sym.withAlpha(130)
          ..style       = PaintingStyle.stroke
          ..strokeWidth = s * 0.025);

    // Inner second star at 60% size
    final inner2 = Path();
    for (int i = 0; i < pts * 2; i++) {
      final r     = (i.isEven ? outer : inner) * 0.58;
      final angle = rot + pi / pts + i * pi / pts;
      final x = cx + cos(angle) * r;
      final y = cy + sin(angle) * r;
      if (i == 0) { inner2.moveTo(x, y); } else { inner2.lineTo(x, y); }
    }
    inner2.close();
    c.drawPath(inner2, Paint()..color = accent.withAlpha(50)..style = PaintingStyle.fill);
  }

  // ── Placeholder for unknown / loading names ────────────────────────────────
  void _drawPlaceholder(Canvas canvas, Size size) {
    final s  = size.width;
    final cx = s / 2, cy = s / 2;
    canvas.drawRect(
      Rect.fromLTWH(0, 0, s, s),
      Paint()..color = const Color(0xFF0D1F35),
    );
    canvas.drawCircle(
      Offset(cx, cy), s * 0.38,
      Paint()
        ..color = const Color(0xFF1A3050)
        ..style = PaintingStyle.stroke
        ..strokeWidth = s * 0.03,
    );
    canvas.drawCircle(
      Offset(cx, cy), s * 0.10,
      Paint()..color = const Color(0xFF2A5070),
    );
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  /// Maps an entropy byte to a double in [min, max].
  double _frac(int byte, double min, double max) =>
      min + (byte / 255.0) * (max - min);

  @override
  bool shouldRepaint(_PalmAvatarPainter old) =>
      old.palmName != palmName || old.sovereignId != sovereignId;
}

// ── Adjective list (must match PalmNameEngine._adjectives) ───────────────────
const _adjectives = [
  'Bold',   'Deep',   'Swift',  'Dark',   'Wild',   'Iron',   'Still',  'Bright',
  'Cold',   'Sharp',  'Fierce', 'Calm',   'Lone',   'True',   'Stark',  'Free',
  'Stone',  'Ember',  'Storm',  'Frost',  'Dusk',   'Dawn',   'Ash',    'Tide',
  'Hollow', 'Silent', 'Bare',   'Keen',   'Grim',   'Clear',  'Dry',    'Whole',
];
