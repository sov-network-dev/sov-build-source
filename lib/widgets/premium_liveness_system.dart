// lib/widgets/premium_liveness_system.dart  v2.0 — FINAL
// ─────────────────────────────────────────────────────────────────────────────
// PREMIUM GHOST HAND LIVENESS TRAINER
//
// - Animated skeleton hand fills screen like engineer's pan_tool_outlined
// - Only ONE instruction text (no duplicate subtext)
// - Progress ring scales with screen size
// - Movement meter reads 0-100% live
// - GHOST / YOU status dots
// - Screen owns ALL detection — widget is pure UI
// - updateGestureProgress(progress, phase1Done) called by screen each frame
// ─────────────────────────────────────────────────────────────────────────────

import 'package:flutter/material.dart';
import 'dart:math' show pi, pow;
import 'dart:ui' show lerpDouble;

enum LivenessGesture {
  indexUpDown,
  thumbLeftRight,
  pinkyCurl,
  spreadClose,
}

class PremiumLivenessSystem extends StatefulWidget {
  final LivenessGesture gesture;
  final Function(double progress) onProgressUpdate;
  final VoidCallback onSuccess;
  final VoidCallback onFailure;
  final int maxAttempts;
  final int timeoutSeconds;

  const PremiumLivenessSystem({
    super.key,
    required this.gesture,
    required this.onProgressUpdate,
    required this.onSuccess,
    required this.onFailure,
    this.maxAttempts   = 5,
    this.timeoutSeconds = 60,
  });

  @override
  State<PremiumLivenessSystem> createState() => PremiumLivenessSystemState();
}

class PremiumLivenessSystemState extends State<PremiumLivenessSystem>
    with TickerProviderStateMixin {

  late final AnimationController _ghostCtrl;
  late final AnimationController _pulseCtrl;
  late final AnimationController _matchCtrl;

  double _gestureProgress  = 0.0;
  bool   _phaseOneComplete = false;
  bool   _isMatching       = false;

  @override
  void initState() {
    super.initState();
    _ghostCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 2000))
      ..repeat();
    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1500))
      ..repeat(reverse: true);
    _matchCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 300));
  }

  @override
  void dispose() {
    _ghostCtrl.dispose();
    _pulseCtrl.dispose();
    _matchCtrl.dispose();
    super.dispose();
  }

  // Called by screen's detection loop each frame
  void updateGestureProgress(double progress, bool phase1Done) {
    if (!mounted) return;
    setState(() {
      _gestureProgress  = progress.clamp(0.0, 1.0);
      _phaseOneComplete = phase1Done;
      _isMatching       = progress > 0.25;
    });
    if (_isMatching) { _matchCtrl.forward(); }
    else             { _matchCtrl.reverse(); }
    widget.onProgressUpdate(_gestureProgress);
  }

  // ── SINGLE instruction text — phase-aware, no duplicate ───────────────────
  String get _instructionText {
    if (!_phaseOneComplete) {
      switch (widget.gesture) {
        case LivenessGesture.indexUpDown:    return 'Raise your index finger UP ↑';
        case LivenessGesture.thumbLeftRight: return 'Move your thumb to the SIDE ←';
        case LivenessGesture.pinkyCurl:      return 'Curl your pinky finger IN ↙';
        case LivenessGesture.spreadClose:    return 'SPREAD your fingers wide ↔';
      }
    } else {
      switch (widget.gesture) {
        case LivenessGesture.indexUpDown:    return 'Now bring it back DOWN ↓';
        case LivenessGesture.thumbLeftRight: return 'Now bring it BACK →';
        case LivenessGesture.pinkyCurl:      return 'Now OPEN your pinky ↗';
        case LivenessGesture.spreadClose:    return 'Now CLOSE your fingers ✊';
      }
    }
  }

  String get _titleText {
    switch (widget.gesture) {
      case LivenessGesture.indexUpDown:    return 'MOVE INDEX FINGER';
      case LivenessGesture.thumbLeftRight: return 'MOVE YOUR THUMB';
      case LivenessGesture.pinkyCurl:      return 'CURL YOUR PINKY';
      case LivenessGesture.spreadClose:    return 'SPREAD YOUR FINGERS';
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final sw   = size.width;
    final sh   = size.height;

    return Stack(
      fit: StackFit.expand,
      children: [
        // Radial gradient — camera visible behind
        Container(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(0, -0.15),
              radius: 0.9,
              colors: [
                Colors.black.withValues(alpha: 0.20),
                Colors.black.withValues(alpha: 0.78),
              ],
            ),
          ),
        ),

        // Ghost hand + ring — fills top 62% of screen like engineer's icon
        Positioned(
          top: sh * 0.08,
          left: 0, right: 0,
          height: sh * 0.55,
          child: AnimatedBuilder(
            animation: Listenable.merge([_ghostCtrl, _pulseCtrl, _matchCtrl]),
            builder: (_, __) {
              final color = _isMatching
                  ? Color.lerp(const Color(0xFF4ECDC4), Colors.greenAccent,
                      _matchCtrl.value)!
                  : const Color(0xFFD4AF37);

              return Stack(alignment: Alignment.center, children: [

                // Progress ring — scales with screen width
                SizedBox(
                  width:  sw * 0.78,
                  height: sw * 0.78,
                  child: CustomPaint(
                    painter: ProgressRingPainter(
                      progress:   _gestureProgress,
                      color:      color,
                      pulseValue: _pulseCtrl.value,
                    ),
                  ),
                ),

                // Ghost hand skeleton — same size as engineer sh*0.45
                SizedBox(
                  width:  sw * 0.72,
                  height: sh * 0.50,
                  child: CustomPaint(
                    painter: PremiumGhostHandPainter(
                      gesture:          widget.gesture,
                      animationValue:   _ghostCtrl.value,
                      phaseOneComplete: _phaseOneComplete,
                      isMatching:       _isMatching,
                      matchIntensity:   _matchCtrl.value,
                    ),
                  ),
                ),

                // MATCHING badge — top of hand area
                if (_isMatching)
                  Positioned(
                    top: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 5),
                      decoration: BoxDecoration(
                        color: Colors.greenAccent.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: Colors.greenAccent)),
                      child: const Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.check_circle,
                            color: Colors.greenAccent, size: 13),
                        SizedBox(width: 5),
                        Text('MATCHING', style: TextStyle(
                            color: Colors.greenAccent, fontSize: 11,
                            fontWeight: FontWeight.bold, letterSpacing: 1)),
                      ]),
                    ),
                  ),

                // "FOLLOW THE GHOST HAND" hint
                const Positioned(
                  bottom: 4,
                  child: Text('FOLLOW THE GHOST HAND',
                      style: TextStyle(color: Colors.white30, fontSize: 9,
                          letterSpacing: 2, fontWeight: FontWeight.w600)),
                ),
              ]);
            },
          ),
        ),

        // Feedback panel — bottom 32%
        Positioned(
          bottom: sh * 0.04,
          left: 16, right: 16,
          child: AnimatedBuilder(
            animation: Listenable.merge([_pulseCtrl, _matchCtrl]),
            builder: (_, __) {
              final color = _isMatching
                  ? Color.lerp(const Color(0xFF4ECDC4), Colors.greenAccent,
                      _matchCtrl.value)!
                  : const Color(0xFFD4AF37);

              return Container(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.72),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                      color: color.withValues(alpha: _isMatching ? 0.55 : 0.25)),
                  boxShadow: _isMatching ? [BoxShadow(
                      color: Colors.greenAccent.withValues(alpha: 0.10),
                      blurRadius: 18, spreadRadius: 3)] : [],
                ),
                child: Column(mainAxisSize: MainAxisSize.min, children: [

                  // Title — gesture name
                  Text(_titleText,
                      style: TextStyle(color: color, fontSize: 13,
                          fontWeight: FontWeight.w800, letterSpacing: 1.8),
                      textAlign: TextAlign.center),

                  const SizedBox(height: 10),

                  // Progress bar — THE movement meter
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: _gestureProgress,
                      minHeight: 10,
                      backgroundColor: Colors.white.withValues(alpha: 0.10),
                      valueColor: AlwaysStoppedAnimation(color),
                    ),
                  ),

                  const SizedBox(height: 8),

                  // Percentage + GHOST/YOU dots on same row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(children: [
                        _dot('GHOST', true,  color),
                        const SizedBox(width: 6),
                        Icon(Icons.sync_alt,
                            color: _isMatching
                                ? Colors.greenAccent : Colors.white24,
                            size: 13),
                        const SizedBox(width: 6),
                        _dot('YOU', _gestureProgress > 0.08, color),
                      ]),
                      Text('${(_gestureProgress * 100).toInt()}%',
                          style: TextStyle(color: color,
                              fontSize: 20, fontWeight: FontWeight.bold)),
                    ],
                  ),

                  const SizedBox(height: 10),

                  // Single instruction text — phase-aware, NO duplicate
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(12)),
                    child: Text(_instructionText,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: color,
                            fontSize: 13, fontWeight: FontWeight.w600)),
                  ),
                ]),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _dot(String label, bool active, Color activeColor) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 8, height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active ? activeColor : Colors.redAccent,
              boxShadow: active ? [BoxShadow(
                  color: activeColor.withValues(alpha: 0.5), blurRadius: 6)] : null,
            )),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(
            color: active ? Colors.white : Colors.white38,
            fontSize: 9, fontWeight: FontWeight.w600)),
      ]);
}

// ══════════════════════════════════════════════════════════════════════════════
// PREMIUM GHOST HAND PAINTER
// Bones + joints + glow on active finger. Fills the canvas fully.
// ══════════════════════════════════════════════════════════════════════════════

class PremiumGhostHandPainter extends CustomPainter {
  final LivenessGesture gesture;
  final double animationValue;
  final bool   phaseOneComplete;
  final bool   isMatching;
  final double matchIntensity;

  const PremiumGhostHandPainter({
    required this.gesture,
    required this.animationValue,
    this.phaseOneComplete = false,
    this.isMatching       = false,
    this.matchIntensity   = 0.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(size.width / 2, size.height * 0.58);
    // Scale to fill canvas — same visual weight as engineer's sh*0.45 icon
    canvas.scale(size.width / 155.0);

    final base = isMatching
        ? Color.lerp(Colors.white, Colors.greenAccent, matchIntensity)!
        : Colors.white;
    final accent = isMatching ? Colors.greenAccent : const Color(0xFF4ECDC4);

    _drawHand(canvas, base, accent);
    canvas.restore();
  }

  void _drawHand(Canvas canvas, Color base, Color accent) {
    // Palm fill
    canvas.drawPath(
      Path()
        ..moveTo(-36, 16) ..lineTo(-32, -16) ..lineTo(32, -16)
        ..lineTo(36, 16)  ..lineTo(16, 46)   ..lineTo(-16, 46)
        ..close(),
      Paint()..color = base.withValues(alpha: 0.07)..style = PaintingStyle.fill);

    final fingers = _fingerPoses();
    for (int i = 0; i < fingers.length; i++) {
      _drawFinger(canvas, fingers[i][0], fingers[i][1], fingers[i][2],
          _isActive(i) ? accent : base.withValues(alpha: 0.42), _isActive(i));
    }

    // Wrist
    final w = Paint()..color = base.withValues(alpha: 0.28)..strokeWidth = 2.2
        ..style = PaintingStyle.stroke..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(-20, 46), const Offset(-24, 72), w);
    canvas.drawLine(const Offset(20, 46),  const Offset(24, 72),  w);
  }

  List<List<Offset>> _fingerPoses() {
    final raw = phaseOneComplete
        ? 1.0 - (animationValue * 2 - 1.0).clamp(0.0, 1.0)
        : (animationValue * 2.0).clamp(0.0, 1.0);
    final t = _easeOutBack(raw);

    const bI = Offset(-24, -16);
    const bM = Offset(-8,  -21);
    const bR = Offset(8,   -18);
    const bP = Offset(24,  -12);
    const bT = Offset(-40,  6);

    switch (gesture) {
      case LivenessGesture.indexUpDown:
        final iy = lerpDouble(-16 - 14, -16 - 50, t)!;
        return [
          [bI, Offset(-24, iy + 24), Offset(-24, iy)],
          _n(bM, 50), _n(bR, 45), _n(bP, 36), _th(bT),
        ];

      case LivenessGesture.thumbLeftRight:
        final tx = lerpDouble(-40.0, -40 - 38, t)!;
        return [
          _n(bI, 48), _n(bM, 50), _n(bR, 45), _n(bP, 36),
          [bT, Offset(bT.dx + (tx - bT.dx) * 0.5, bT.dy - 7),
               Offset(tx, bT.dy - 20)],
        ];

      case LivenessGesture.pinkyCurl:
        final cx = lerpDouble(24.0, 10.0, t)!;
        final cy = lerpDouble(-12.0 - 34, -12.0 - 8, t)!;
        return [
          _n(bI, 48), _n(bM, 50), _n(bR, 45),
          [bP, Offset(cx, cy + 15), Offset(cx - 3, cy)],
          _th(bT),
        ];

      case LivenessGesture.spreadClose:
        final s = lerpDouble(1.0, 1.42, t)!;
        return [
          _sp(bI, 48, s), _sp(bM, 50, s * 0.92),
          _sp(bR, 45, s * 0.92), _sp(bP, 36, s), _th(bT),
        ];
    }
  }

  List<Offset> _n(Offset b, double len) =>
      [b, Offset(b.dx, b.dy - len * 0.42), Offset(b.dx, b.dy - len)];

  List<Offset> _th(Offset b) =>
      [b, Offset(b.dx + 13, b.dy - 9), Offset(b.dx + 26, b.dy - 22)];

  List<Offset> _sp(Offset b, double len, double s) =>
      [b, Offset(b.dx * s, b.dy - len * 0.42), Offset(b.dx * s, b.dy - len)];

  void _drawFinger(Canvas canvas, Offset base, Offset mid, Offset tip,
      Color color, bool active) {
    if (active) {
      final glow = Paint()
        ..color       = color.withValues(alpha: 0.25)
        ..strokeWidth = 10
        ..strokeCap   = StrokeCap.round
        ..maskFilter  = const MaskFilter.blur(BlurStyle.normal, 6);
      canvas.drawLine(base, mid, glow);
      canvas.drawLine(mid,  tip, glow);
    }
    final bone = Paint()
      ..color       = color.withValues(alpha: active ? 1.0 : 0.52)
      ..strokeWidth = active ? 3.2 : 1.8
      ..strokeCap   = StrokeCap.round;
    canvas.drawLine(base, mid, bone);
    canvas.drawLine(mid,  tip, bone);

    final joint = Paint()..color = color..style = PaintingStyle.fill;
    canvas.drawCircle(base, active ? 4.2 : 2.5, joint);
    canvas.drawCircle(mid,  active ? 3.2 : 2.0, joint);
    canvas.drawCircle(tip,  active ? 5.0 : 3.2, joint);

    if (active) {
      canvas.drawCircle(tip, 8.5, Paint()
        ..color       = color.withValues(alpha: 0.42)
        ..style       = PaintingStyle.stroke
        ..strokeWidth = 1.6);
    }
  }

  bool _isActive(int i) {
    switch (gesture) {
      case LivenessGesture.indexUpDown:    return i == 0;
      case LivenessGesture.thumbLeftRight: return i == 4;
      case LivenessGesture.pinkyCurl:      return i == 3;
      case LivenessGesture.spreadClose:    return true;
    }
  }

  double _easeOutBack(double x) {
    const c1 = 1.70158, c3 = c1 + 1;
    return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2);
  }

  @override
  bool shouldRepaint(PremiumGhostHandPainter o) =>
      o.animationValue   != animationValue   ||
      o.phaseOneComplete != phaseOneComplete ||
      o.isMatching       != isMatching       ||
      o.matchIntensity   != matchIntensity;
}

// ══════════════════════════════════════════════════════════════════════════════
// PROGRESS RING PAINTER — scales with screen
// ══════════════════════════════════════════════════════════════════════════════

class ProgressRingPainter extends CustomPainter {
  final double progress;
  final Color  color;
  final double pulseValue;

  const ProgressRingPainter({
    required this.progress,
    required this.color,
    required this.pulseValue,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2 - 10;

    canvas.drawCircle(c, r, Paint()
      ..color       = Colors.white.withValues(alpha: 0.07)
      ..style       = PaintingStyle.stroke
      ..strokeWidth = 5);

    if (progress <= 0) return;

    canvas.drawArc(Rect.fromCircle(center: c, radius: r),
        -pi / 2, 2 * pi * progress, false,
        Paint()
          ..color       = color.withValues(alpha: 0.25 * pulseValue)
          ..style       = PaintingStyle.stroke
          ..strokeWidth = 13
          ..maskFilter  = const MaskFilter.blur(BlurStyle.normal, 7));

    canvas.drawArc(Rect.fromCircle(center: c, radius: r),
        -pi / 2, 2 * pi * progress, false,
        Paint()
          ..color       = color
          ..style       = PaintingStyle.stroke
          ..strokeWidth = 5
          ..strokeCap   = StrokeCap.round);
  }

  @override
  bool shouldRepaint(ProgressRingPainter o) =>
      o.progress != progress || o.pulseValue != pulseValue;
}
