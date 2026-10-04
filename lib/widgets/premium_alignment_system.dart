// lib/widgets/premium_alignment_system.dart
// ─────────────────────────────────────────────────────────────────────────────
// PREMIUM PALM ALIGNMENT — LIVE TARGET MATCHING
//
// Military HUD corner brackets frame.
// Four live factor chips: Position, Rotation, Stability, Distance.
// Progress bar + percentage. Guidance text updates in real time.
// ─────────────────────────────────────────────────────────────────────────────

import 'package:flutter/material.dart';

enum AlignmentFactor { position, rotation, stability, distance }

class PremiumAlignmentSystem extends StatefulWidget {
  final Function(double progress, Map<AlignmentFactor, bool> checks)
      onProgressUpdate;
  final Future<void> Function() onAligned;
  final double requiredProgress;

  const PremiumAlignmentSystem({
    super.key,
    required this.onProgressUpdate,
    required this.onAligned,
    this.requiredProgress = 0.95,
  });

  @override
  State<PremiumAlignmentSystem> createState() =>
      PremiumAlignmentSystemState();
}

class PremiumAlignmentSystemState extends State<PremiumAlignmentSystem>
    with TickerProviderStateMixin {

  late final AnimationController _pulseController;
  late final AnimationController _successController;

  double _alignmentProgress = 0.0;
  Map<AlignmentFactor, double> _factorScores = {
    AlignmentFactor.position:  0.0,
    AlignmentFactor.rotation:  0.0,
    AlignmentFactor.stability: 0.0,
    AlignmentFactor.distance:  0.0,
  };
  bool   _isAligned    = false;
  bool   _snapTriggered = false;
  String _guidanceText = 'Position your palm in the frame';

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    _successController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _successController.dispose();
    super.dispose();
  }

  /// Called by parent screen each detection frame
  void updateAlignment({
    required double positionScore,
    required double rotationScore,
    required double stabilityScore,
    required double distanceScore,
  }) {
    if (!mounted || _snapTriggered) return;
    setState(() {
      _factorScores = {
        AlignmentFactor.position:  positionScore,
        AlignmentFactor.rotation:  rotationScore,
        AlignmentFactor.stability: stabilityScore,
        AlignmentFactor.distance:  distanceScore,
      };
      _alignmentProgress = (
        positionScore  * 0.30 +
        rotationScore  * 0.25 +
        stabilityScore * 0.25 +
        distanceScore  * 0.20
      ).clamp(0.0, 1.0);

      _isAligned = _alignmentProgress >= widget.requiredProgress;

      if (_isAligned) {
        _successController.forward();
        _guidanceText = 'Hold steady...';
      } else {
        _successController.reverse();
        _guidanceText = _calcGuidance();
      }
    });

    widget.onProgressUpdate(
      _alignmentProgress,
      _factorScores.map((k, v) => MapEntry(k, v > 0.7)),
    );

    if (_alignmentProgress >= 1.0 && !_snapTriggered) {
      _snapTriggered = true;
      widget.onAligned();
    }
  }

  String _calcGuidance() {
    final low = _factorScores.entries
        .reduce((a, b) => a.value < b.value ? a : b);
    switch (low.key) {
      case AlignmentFactor.position:  return 'Centre your palm in the frame';
      case AlignmentFactor.rotation:  return 'Straighten your hand upright';
      case AlignmentFactor.stability: return 'Hold your hand steady';
      case AlignmentFactor.distance:
        return low.value < 0.5 ? 'Move hand closer' : 'Move hand back slightly';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Target frame with live colour feedback
        AnimatedBuilder(
          animation: Listenable.merge([_pulseController, _successController]),
          builder: (_, __) => CustomPaint(
            painter: PremiumTargetFramePainter(
              progress:     _alignmentProgress,
              isAligned:    _isAligned,
              pulseValue:   _pulseController.value,
              successValue: _successController.value,
            ),
          ),
        ),

        // Ghost palm icon — fades in as alignment improves
        Center(
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 400),
            opacity: _alignmentProgress > 0.4
                ? (0.2 + _alignmentProgress * 0.5).clamp(0.0, 0.85)
                : 0,
            child: AnimatedBuilder(
              animation: _successController,
              builder: (_, __) => Transform.scale(
                scale: 1.0 + _successController.value * 0.08,
                child: Icon(
                  Icons.pan_tool_outlined,
                  size: MediaQuery.of(context).size.height * 0.32,
                  color: _isAligned
                      ? Colors.greenAccent
                      : const Color(0xFF4ECDC4),
                ),
              ),
            ),
          ),
        ),

        // Bottom feedback panel
        Positioned(
          bottom: 20,
          left: 16, right: 16,
          child: _buildFeedbackPanel(),
        ),
      ],
    );
  }

  Widget _buildFeedbackPanel() {
    return AnimatedBuilder(
      animation: Listenable.merge([_pulseController, _successController]),
      builder: (_, __) {
        final color = _isAligned ? Colors.greenAccent : const Color(0xFFD4AF37);
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.82),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
                color: color.withValues(alpha: _isAligned ? 0.55 : 0.2)),
            boxShadow: _isAligned
                ? [BoxShadow(
                    color: Colors.greenAccent.withValues(alpha: 0.18),
                    blurRadius: 24, spreadRadius: 4)]
                : [],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Progress bar + percentage
              Row(children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: _alignmentProgress,
                      minHeight: 10,
                      backgroundColor: Colors.white.withValues(alpha: 0.1),
                      valueColor: AlwaysStoppedAnimation(color),
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Text(
                  '${(_alignmentProgress * 100).toInt()}%',
                  style: TextStyle(
                      color: color,
                      fontSize: 22,
                      fontWeight: FontWeight.bold),
                ),
              ]),

              const SizedBox(height: 12),

              // Four factor chips
              Row(children: [
                Expanded(child: _factorChip(
                    'Position', _factorScores[AlignmentFactor.position]!)),
                const SizedBox(width: 6),
                Expanded(child: _factorChip(
                    'Rotation', _factorScores[AlignmentFactor.rotation]!)),
              ]),
              const SizedBox(height: 6),
              Row(children: [
                Expanded(child: _factorChip(
                    'Stability', _factorScores[AlignmentFactor.stability]!)),
                const SizedBox(width: 6),
                Expanded(child: _factorChip(
                    'Distance', _factorScores[AlignmentFactor.distance]!)),
              ]),

              const SizedBox(height: 12),

              // Guidance text
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: _isAligned
                      ? Colors.greenAccent.withValues(alpha: 0.12)
                      : const Color(0xFF1A3A4A),
                  borderRadius: BorderRadius.circular(10)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _isAligned
                          ? Icons.check_circle : Icons.info_outline,
                      color: _isAligned
                          ? Colors.greenAccent : const Color(0xFF4ECDC4),
                      size: 16),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        _guidanceText,
                        style: TextStyle(
                          color: _isAligned
                              ? Colors.greenAccent : Colors.white70,
                          fontSize: 12,
                          fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _factorChip(String label, double score) {
    final excellent = score > 0.9;
    final good      = score > 0.7;
    final chipColor = excellent
        ? Colors.greenAccent
        : good ? const Color(0xFF4ECDC4) : Colors.white38;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: excellent
            ? Colors.greenAccent.withValues(alpha: 0.12)
            : good ? const Color(0xFF1A3A4A) : Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: chipColor.withValues(alpha: 0.35))),
      child: Row(children: [
        Icon(
          excellent ? Icons.check_circle
            : good ? Icons.check : Icons.circle_outlined,
          color: chipColor, size: 13),
        const SizedBox(width: 5),
        Expanded(
          child: Text(label,
              style: TextStyle(
                  color: chipColor, fontSize: 10,
                  fontWeight: FontWeight.w700)),
        ),
        Text('${(score * 100).toInt()}%',
            style: TextStyle(
                color: chipColor.withValues(alpha: 0.8),
                fontSize: 9, fontWeight: FontWeight.bold)),
      ]),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// PREMIUM TARGET FRAME PAINTER
// ══════════════════════════════════════════════════════════════════════════════

class PremiumTargetFramePainter extends CustomPainter {
  final double progress;
  final bool   isAligned;
  final double pulseValue;
  final double successValue;

  const PremiumTargetFramePainter({
    required this.progress,
    required this.isAligned,
    required this.pulseValue,
    required this.successValue,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center    = size.center(Offset.zero);
    final frameW    = size.width  * 0.80;
    final frameH    = size.height * 0.60;
    final rect      = Rect.fromCenter(
        center: center, width: frameW, height: frameH);
    final rrect     = RRect.fromRectAndRadius(
        rect, const Radius.circular(36));

    // Frame colour: red → amber → green as progress increases
    final frameColor = Color.lerp(
      Colors.redAccent,
      Color.lerp(Colors.amberAccent, Colors.greenAccent, progress)!
          .withValues(alpha: isAligned
              ? 0.7 + pulseValue * 0.3 : 0.85),
      progress,
    )!;

    // Outer glow when aligned
    if (isAligned) {
      canvas.drawRRect(rrect, Paint()
        ..color       = Colors.greenAccent.withValues(alpha: 0.18 * pulseValue)
        ..style       = PaintingStyle.stroke
        ..strokeWidth = 22
        ..maskFilter  = const MaskFilter.blur(BlurStyle.normal, 14));
    }

    // Main frame border
    canvas.drawRRect(rrect, Paint()
      ..color       = frameColor
      ..style       = PaintingStyle.stroke
      ..strokeWidth = isAligned ? 4.0 + successValue * 2 : 2.8);

    // Military corner accents
    _drawCorners(canvas, rect, frameColor, progress);

    // Centering crosshair when progress is low
    if (!isAligned && progress < 0.25) {
      _drawCrosshair(canvas, center, frameColor.withValues(alpha: 0.45));
    }
  }

  void _drawCorners(Canvas canvas, Rect rect, Color color, double prog) {
    final len   = 22.0 + prog * 12;
    final paint = Paint()
      ..color       = color.withValues(alpha: 0.85 + prog * 0.15)
      ..strokeWidth = 3.5
      ..strokeCap   = StrokeCap.round;

    final corners = [rect.topLeft, rect.topRight,
                     rect.bottomLeft, rect.bottomRight];
    final dirs = [
      [const Offset(1, 0), const Offset(0, 1)],
      [const Offset(-1, 0), const Offset(0, 1)],
      [const Offset(1, 0), const Offset(0, -1)],
      [const Offset(-1, 0), const Offset(0, -1)],
    ];
    for (int i = 0; i < 4; i++) {
      canvas.drawLine(corners[i], corners[i] + dirs[i][0] * len, paint);
      canvas.drawLine(corners[i], corners[i] + dirs[i][1] * len, paint);
    }
  }

  void _drawCrosshair(Canvas canvas, Offset center, Color color) {
    final paint = Paint()
      ..color       = color
      ..strokeWidth = 1.5
      ..strokeCap   = StrokeCap.round;
    const s = 28.0, g = 9.0;
    canvas.drawLine(center.translate(-s, 0), center.translate(-g, 0), paint);
    canvas.drawLine(center.translate(g, 0),  center.translate(s, 0),  paint);
    canvas.drawLine(center.translate(0, -s), center.translate(0, -g), paint);
    canvas.drawLine(center.translate(0, g),  center.translate(0, s),  paint);
    canvas.drawCircle(center, 3,
        paint..style = PaintingStyle.fill);
  }

  @override
  bool shouldRepaint(PremiumTargetFramePainter o) =>
      o.progress     != progress     ||
      o.isAligned    != isAligned    ||
      o.pulseValue   != pulseValue   ||
      o.successValue != successValue;
}
