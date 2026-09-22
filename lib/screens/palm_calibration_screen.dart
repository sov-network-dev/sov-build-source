// lib/screens/palm_calibration_screen.dart
// Shows calibration data collected silently during the session.
// Tells you exactly what distance, lighting, and stability to target.

import 'package:flutter/material.dart';
import '../sov_node_sdk/palm_image_engine.dart';

class PalmCalibrationScreen extends StatelessWidget {
  final CalibrationReport report;
  const PalmCalibrationScreen({super.key, required this.report});

  static const _bg   = Color(0xFF0A1628);
  static const _gold = Color(0xFFD4AF37);

  @override
  Widget build(BuildContext context) {
    final successRate = report.totalFrames > 0
        ? (report.goodFrames / report.totalFrames * 100).toInt() : 0;

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Calibration Report',
            style: TextStyle(color: _gold, fontWeight: FontWeight.bold)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(children: [

          // Header
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF0D1F35),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _gold.withValues(alpha: 0.3))),
            child: Column(children: [
              const Text('SESSION CALIBRATION DATA',
                  style: TextStyle(color: _gold, fontSize: 14,
                      fontWeight: FontWeight.w900, letterSpacing: 1.5)),
              const SizedBox(height: 4),
              Text('$successRate% of frames were good quality',
                  style: TextStyle(
                    color: successRate >= 50 ? Colors.greenAccent : Colors.redAccent,
                    fontSize: 13, fontWeight: FontWeight.bold)),
            ]),
          ),

          const SizedBox(height: 16),

          // Metrics
          _metric('Frames Analysed', '${report.totalFrames}',
              '${report.goodFrames} good quality', Colors.white70),
          _metric('Avg Hand Size',
              '${report.avgHandSizePx.toStringAsFixed(1)}px',
              report.avgHandSizePx >= 120
                  ? 'Good distance ✓'
                  : 'Move hand ${(120-report.avgHandSizePx).toInt()}px closer',
              report.avgHandSizePx >= 120 ? Colors.greenAccent : Colors.amberAccent),
          _metric('Avg Sharpness',
              '${(report.avgSharpness * 100).toInt()}%',
              report.avgSharpness >= 0.15 ? 'Good sharpness ✓' : 'Hold phone steadier',
              report.avgSharpness >= 0.15 ? Colors.greenAccent : Colors.amberAccent),
          _metric('Avg Brightness',
              '${(report.avgBrightness * 100).toInt()}%',
              report.avgBrightness >= 0.20 && report.avgBrightness <= 0.80
                  ? 'Good lighting ✓'
                  : report.avgBrightness < 0.20 ? 'Too dark — use torch'
                  : 'Too bright — reduce glare',
              report.avgBrightness >= 0.20 && report.avgBrightness <= 0.80
                  ? Colors.greenAccent : Colors.amberAccent),
          _metric('Avg Alignment Score',
              '${(report.avgAlignmentScore * 100).toInt()}%',
              report.avgAlignmentScore >= 0.70 ? 'Excellent ✓' : 'Adjust position',
              report.avgAlignmentScore >= 0.70 ? Colors.greenAccent : Colors.amberAccent),

          const SizedBox(height: 20),

          // Recommendation
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF0D2A1A),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.greenAccent.withValues(alpha: 0.3))),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('RECOMMENDATIONS FOR NEXT SESSION',
                    style: TextStyle(color: Colors.greenAccent, fontSize: 12,
                        fontWeight: FontWeight.w800, letterSpacing: 1)),
                const SizedBox(height: 10),
                Text(report.recommendation,
                    style: const TextStyle(color: Colors.white70,
                        fontSize: 13, height: 1.6)),
              ],
            ),
          ),

          const SizedBox(height: 20),

          ElevatedButton.icon(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.arrow_back, size: 18),
            label: const Text('Back to Results'),
            style: ElevatedButton.styleFrom(
              backgroundColor: _gold, foregroundColor: Colors.black,
              minimumSize: const Size(double.infinity, 50),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
          ),
        ]),
      ),
    );
  }

  Widget _metric(String label, String value, String note, Color noteColor) =>
    Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF0D1F35),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12)),
      child: Row(children: [
        Expanded(child: Text(label,
            style: const TextStyle(color: Colors.white54,
                fontSize: 12, fontWeight: FontWeight.w600))),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(value, style: const TextStyle(color: Colors.white,
              fontSize: 16, fontWeight: FontWeight.bold)),
          Text(note, style: TextStyle(color: noteColor, fontSize: 10)),
        ]),
      ]),
    );
}
