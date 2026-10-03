// lib/screens/palm_gallery_screen.dart
// ─────────────────────────────────────────────────────────────────────────────
// PALM IMAGE GALLERY
//
// Full quality viewer for all processed palm images.
// Pinch to zoom, swipe between images.
// Each image is the exact 128×128 enhanced image the algorithm used.
// Use this to study crease clarity and diagnose why similarity scores vary.
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:typed_data';
import 'package:flutter/material.dart';

class _GalleryItem {
  final String    label;
  final Uint8List bytes;
  final DateTime  time;
  const _GalleryItem({required this.label, required this.bytes, required this.time});
}

// Accept any object that has label, bytes, time fields
class PalmGalleryScreen extends StatefulWidget {
  final String       stepTitle;
  final List<dynamic> images; // List of _GalleryImage from screen

  const PalmGalleryScreen({
    super.key,
    required this.stepTitle,
    required this.images,
  });

  @override
  State<PalmGalleryScreen> createState() => _PalmGalleryScreenState();
}

class _PalmGalleryScreenState extends State<PalmGalleryScreen> {
  int _current = 0;

  static const _bg   = Color(0xFF0A1628);
  static const _gold = Color(0xFFD4AF37);
  static const _teal = Color(0xFF4ECDC4);

  List<_GalleryItem> get _items => widget.images
      .map((e) => _GalleryItem(
            label: e.label as String,
            bytes: e.bytes as Uint8List,
            time:  e.time  as DateTime,
          ))
      .toList();

  @override
  Widget build(BuildContext context) {
    final items = _items;
    if (items.isEmpty) {
      return Scaffold(
        backgroundColor: _bg,
        appBar: AppBar(
          backgroundColor: Colors.black,
          title: const Text('Palm Gallery',
              style: TextStyle(color: _gold, fontWeight: FontWeight.bold)),
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        body: const Center(
          child: Text('No images captured yet',
              style: TextStyle(color: Colors.white54, fontSize: 16)),
        ),
      );
    }

    final item = items[_current];

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context)),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(item.label,
                style: const TextStyle(color: _gold, fontSize: 14,
                    fontWeight: FontWeight.bold)),
            Text(
              '${item.time.hour.toString().padLeft(2,"0")}:${item.time.minute.toString().padLeft(2,"0")}:${item.time.second.toString().padLeft(2,"0")}',
              style: const TextStyle(color: Colors.white38, fontSize: 11)),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(child: Text(
              '${_current + 1} / ${items.length}',
              style: const TextStyle(color: Colors.white54, fontSize: 13))),
          ),
        ],
      ),

      body: Column(children: [

        // Full-screen image with pinch-to-zoom
        Expanded(
          child: InteractiveViewer(
            minScale: 0.5,
            maxScale: 8.0,
            child: Center(
              child: Hero(
                tag: 'palm_image_$_current',
                child: Image.memory(
                  item.bytes,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.none, // pixel-perfect, no blurring
                  gaplessPlayback: true,
                ),
              ),
            ),
          ),
        ),

        // Info panel
        Container(
          color: const Color(0xFF0A1628),
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            // Image label
            Text(item.label,
                textAlign: TextAlign.center,
                style: const TextStyle(color: _teal, fontSize: 14,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(
              'Pinch to zoom in/out • Drag to pan',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.35),
                  fontSize: 11),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),

            // Navigation row
            if (items.length > 1)
              Row(children: [
                // Previous
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _current > 0
                        ? () => setState(() => _current--)
                        : null,
                    icon: const Icon(Icons.chevron_left, size: 20),
                    label: const Text('Prev'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1A3A4A),
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: Colors.white12,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8))),
                  ),
                ),
                const SizedBox(width: 12),

                // Dot indicators
                ...List.generate(items.length.clamp(0, 8), (i) =>
                  GestureDetector(
                    onTap: () => setState(() => _current = i),
                    child: Container(
                      width: 8, height: 8,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i == _current
                            ? _gold : Colors.white24)),
                  )),

                const SizedBox(width: 12),

                // Next
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _current < items.length - 1
                        ? () => setState(() => _current++)
                        : null,
                    icon: const Icon(Icons.chevron_right, size: 20),
                    label: const Text('Next'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _gold,
                      foregroundColor: Colors.black,
                      disabledBackgroundColor: Colors.white12,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8))),
                  ),
                ),
              ]),
          ]),
        ),
      ]),
    );
  }
}
