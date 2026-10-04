// lib/widgets/audio_player_widget.dart
// ─────────────────────────────────────────────────────────────────────────────
// Compact audio player for voice notes and audio files inside chat bubbles.
// Uses audioplayers package for local file playback.
// ─────────────────────────────────────────────────────────────────────────────
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';

class AudioPlayerWidget extends StatefulWidget {
  /// Local filesystem path to the audio file.
  final String? filePath;

  /// Known duration in milliseconds (optional; player will discover it).
  final int? durationMs;

  /// True if this message was sent by the current user (adjusts colours).
  final bool isOwn;

  const AudioPlayerWidget({
    this.filePath,
    this.durationMs,
    required this.isOwn,
    super.key,
  });

  @override
  State<AudioPlayerWidget> createState() => _AudioPlayerWidgetState();
}

class _AudioPlayerWidgetState extends State<AudioPlayerWidget> {
  static const _gold = Color(0xFFD4AF37);

  final AudioPlayer _player = AudioPlayer();
  bool     _isPlaying = false;
  bool     _available = false;
  Duration _position  = Duration.zero;
  Duration _duration  = Duration.zero;

  @override
  void initState() {
    super.initState();

    // Pre-seed duration hint if provided
    if (widget.durationMs != null) {
      _duration = Duration(milliseconds: widget.durationMs!);
    }

    // Check file exists
    if (widget.filePath != null) {
      _available = File(widget.filePath!).existsSync();
    }

    _player.onPlayerStateChanged.listen((state) {
      if (mounted) setState(() => _isPlaying = state == PlayerState.playing);
    });
    _player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _duration = d);
    });
    _player.onPositionChanged.listen((p) {
      if (mounted) setState(() => _position = p);
    });
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() { _isPlaying = false; _position = Duration.zero; });
    });
  }

  Future<void> _togglePlay() async {
    if (!_available || widget.filePath == null) return;
    if (_isPlaying) {
      await _player.pause();
    } else {
      await _player.play(DeviceFileSource(widget.filePath!));
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final bg = widget.isOwn
        ? const Color(0xFF2A4A6C)
        : const Color(0xFF1A3A5C);

    if (!_available) {
      return Container(
        width: 220,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Row(
          children: [
            Icon(Icons.mic_off, color: Colors.white38, size: 24),
            SizedBox(width: 8),
            Text('Audio unavailable',
                style: TextStyle(color: Colors.white38, fontSize: 12)),
          ],
        ),
      );
    }

    final maxMs = _duration.inMilliseconds > 0
        ? _duration.inMilliseconds.toDouble()
        : 1.0;
    final curMs = _position.inMilliseconds
        .toDouble()
        .clamp(0.0, maxMs);

    return Container(
      width: 220,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: _togglePlay,
            child: Icon(
              _isPlaying ? Icons.pause_circle : Icons.play_circle,
              color: _gold,
              size: 36,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    thumbShape:   const RoundSliderThumbShape(enabledThumbRadius: 5),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
                    trackHeight:  2,
                  ),
                  child: Slider(
                    value:         curMs,
                    max:           maxMs,
                    activeColor:   _gold,
                    inactiveColor: Colors.white24,
                    onChanged: (v) async {
                      await _player.seek(Duration(milliseconds: v.toInt()));
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 2),
                  child: Text(
                    '${_fmt(_position)} / ${_fmt(_duration)}',
                    style: const TextStyle(color: Colors.white60, fontSize: 10),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
