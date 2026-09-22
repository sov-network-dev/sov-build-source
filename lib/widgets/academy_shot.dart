// lib/widgets/academy_shot.dart
//
// Premium presentation of a REAL, compressed app screenshot: a device-style
// frame with a soft gold rim, numbered glowing indicator dots pointing at the
// exact controls a citizen taps, and a matching numbered legend underneath.
// Used by the Academy "Guided Tour" so people see the true app — not an
// abstract diagram — and know exactly what to press.
//
// Markers use RELATIVE coordinates (0..1 of the image box) so they scale on any
// screen size. Screenshots live in assets/academy_shots/ (~15–50 KB each).
import 'package:flutter/material.dart';

/// One numbered indicator on a screenshot. [dx],[dy] are 0..1 fractions of the
/// image box (0,0 = top-left). [label] is the short action shown in the legend.
class ShotMarker {
  final double dx;
  final double dy;
  final String label;
  const ShotMarker(this.dx, this.dy, this.label);
}

class AcademyShot extends StatelessWidget {
  final String asset;       // e.g. 'assets/academy_shots/home.jpg'
  final double aspect;      // image width / height (0.79 main · 0.56 phone · 0.45 enroll)
  final String title;
  final String? subtitle;
  final List<ShotMarker> markers;
  final String? platformNote; // e.g. 'Phone + Desktop'
  final double maxWidth;

  const AcademyShot({
    super.key,
    required this.asset,
    required this.title,
    this.aspect = 0.79,
    this.subtitle,
    this.markers = const [],
    this.platformNote,
    this.maxWidth = 340,
  });

  static const _gold   = Color(0xFFD4AF37);
  static const _goldHi = Color(0xFFF0CD5A);
  static const _green  = Color(0xFF3DDC97);
  static const _ink    = Color(0xFF0B1120);

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 22),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF161F35), Color(0xFF10182B)],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _gold.withValues(alpha: 0.14)),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 18, offset: const Offset(0, 8)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 4, height: 20,
                margin: const EdgeInsets.only(top: 1, right: 10),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                      begin: Alignment.topCenter, end: Alignment.bottomCenter,
                      colors: [_goldHi, _gold]),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Expanded(
                child: Text(title,
                    style: const TextStyle(
                        color: _gold, fontSize: 16.5,
                        fontWeight: FontWeight.w700, letterSpacing: 0.2)),
              ),
              if (platformNote != null) _platformBadge(platformNote!),
            ],
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(left: 14),
              child: Text(subtitle!,
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.62),
                      fontSize: 12.5, height: 1.4)),
            ),
          ],
          const SizedBox(height: 16),
          Center(child: _framedShot()),
          if (markers.isNotEmpty) ...[
            const SizedBox(height: 16),
            Container(
              height: 1,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [
                  _gold.withValues(alpha: 0.0),
                  _gold.withValues(alpha: 0.25),
                  _gold.withValues(alpha: 0.0),
                ]),
              ),
            ),
            ..._legend(),
          ],
        ],
      ),
    );
  }

  Widget _platformBadge(String note) {
    final isDesktop = note.toLowerCase().contains('full node');
    final c = isDesktop ? _green : _gold;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: c.withValues(alpha: 0.45)),
      ),
      child: Text(note,
          style: TextStyle(
              color: c, fontSize: 10.5, fontWeight: FontWeight.w700,
              letterSpacing: 0.3)),
    );
  }

  Widget _framedShot() {
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: LayoutBuilder(
        builder: (ctx, c) {
          final w = c.maxWidth;
          final h = w / aspect;
          return Container(
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft, end: Alignment.bottomRight,
                colors: [
                  _gold.withValues(alpha: 0.55),
                  _ink,
                  _ink,
                  _gold.withValues(alpha: 0.30),
                ],
              ),
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withValues(alpha: 0.55),
                    blurRadius: 22, offset: const Offset(0, 10)),
                BoxShadow(
                    color: _gold.withValues(alpha: 0.06),
                    blurRadius: 30, spreadRadius: 2),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(19),
              child: SizedBox(
                width: w,
                height: h,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: Image.asset(asset, fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(
                              color: _ink,
                              alignment: Alignment.center,
                              child: Text('screenshot',
                                  style: TextStyle(
                                      color: Colors.white.withValues(alpha: 0.3),
                                      fontSize: 11)))),
                    ),
                    for (var i = 0; i < markers.length; i++)
                      Positioned(
                        left: (markers[i].dx * w - 16).clamp(0.0, w - 32),
                        top:  (markers[i].dy * h - 16).clamp(0.0, h - 32),
                        child: _marker(i + 1),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _marker(int n) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
            begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: [_goldHi, _gold]),
        border: Border.all(color: Colors.white.withValues(alpha: 0.9), width: 2),
        boxShadow: [
          BoxShadow(color: _gold.withValues(alpha: 0.75), blurRadius: 12),
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: 6, offset: const Offset(0, 2)),
        ],
      ),
      alignment: Alignment.center,
      child: Text('$n',
          style: const TextStyle(
              color: Color(0xFF1A1405), fontSize: 15.5,
              fontWeight: FontWeight.w800)),
    );
  }

  List<Widget> _legend() {
    return [
      for (var i = 0; i < markers.length; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: 9),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 23,
                height: 23,
                margin: const EdgeInsets.only(top: 1),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const LinearGradient(
                      begin: Alignment.topLeft, end: Alignment.bottomRight,
                      colors: [_goldHi, _gold]),
                  boxShadow: [
                    BoxShadow(color: _gold.withValues(alpha: 0.35), blurRadius: 5),
                  ],
                ),
                alignment: Alignment.center,
                child: Text('${i + 1}',
                    style: const TextStyle(
                        color: Color(0xFF1A1405), fontSize: 12.5,
                        fontWeight: FontWeight.w800)),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Text(markers[i].label,
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.92),
                        fontSize: 13.5, height: 1.38)),
              ),
            ],
          ),
        ),
    ];
  }
}
