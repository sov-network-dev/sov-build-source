// lib/widgets/voice_recorder_widget.dart
// ─────────────────────────────────────────────────────────────────────────────
// Inline voice-note recorder for SOV Speak.
//
// Starts recording immediately on mount (after requesting microphone
// permission). Replaces the compose bar while active.
// Maximum recording time: 3 minutes. Outputs AAC audio.
// ─────────────────────────────────────────────────────────────────────────────
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import '../sov_node_sdk/relay_connector.dart';

class VoiceRecorderWidget extends StatefulWidget {
  /// Called when the user taps the stop/send button.
  final Future<void> Function(File audioFile, int durationMs) onRecordingComplete;

  /// Called when the user taps the delete/cancel button.
  final VoidCallback onCancel;

  const VoiceRecorderWidget({
    required this.onRecordingComplete,
    required this.onCancel,
    super.key,
  });

  @override
  State<VoiceRecorderWidget> createState() => _VoiceRecorderWidgetState();
}

class _VoiceRecorderWidgetState extends State<VoiceRecorderWidget> {
  static const _navy   = Color(0xFF0A1628);
  static const _gold   = Color(0xFFD4AF37);
  static const _darkBg = Color(0xFF1A3A5C);

  FlutterSoundRecorder? _recorder;
  bool    _stopping     = false;
  bool    _permDenied   = false;
  bool    _unsupported  = false;   // desktop: flutter_sound has no Windows/Linux impl
  int     _seconds      = 0;
  Timer?  _timer;
  String? _filePath;

  static bool get _isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  @override
  void initState() {
    super.initState();
    _initRecorder();
  }

  Future<void> _initRecorder() async {
    // Voice recording (flutter_sound) has no desktop implementation — show a
    // graceful "mobile only" state instead of crashing in openRecorder().
    if (_isDesktop) {
      if (mounted) setState(() => _unsupported = true);
      return;
    }
    // The OS permission dialog triggers AppLifecycleState.inactive on some
    // Android OEM skins, which starts the PIN lock 2-second timer.
    // Flag as external activity so the timer is suppressed while the dialog
    // is shown — same pattern used for image/video picker.
    RelayConnector.externalActivityOpen = true;
    final status = await Permission.microphone.request();
    RelayConnector.externalActivityOpen = false;
    if (status != PermissionStatus.granted) {
      if (mounted) setState(() => _permDenied = true);
      return;
    }

    _recorder = FlutterSoundRecorder();
    await _recorder!.openRecorder();
    await _startRecording();
  }

  Future<void> _startRecording() async {
    final dir = await getTemporaryDirectory();
    _filePath = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.aac';

    await _recorder!.startRecorder(
      toFile: _filePath,
      codec:  Codec.aacADTS,
    );

    if (mounted) setState(() { _seconds = 0; });

    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _seconds++);
      if (_seconds >= 180) _stopRecording(); // 3-minute cap
    });
  }

  Future<void> _stopRecording() async {
    if (_stopping) return;
    _stopping = true;
    _timer?.cancel();

    await _recorder?.stopRecorder();
    if (mounted) setState(() {});

    if (_filePath != null) {
      final file = File(_filePath!);
      if (await file.exists()) {
        await widget.onRecordingComplete(file, _seconds * 1000);
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _recorder?.closeRecorder();
    super.dispose();
  }

  String _formatTime(int s) {
    final m = s ~/ 60;
    final sec = s % 60;
    return '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    if (_unsupported) {
      return Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        color: _navy,
        child: Row(
          children: [
            const Icon(Icons.mic_off_rounded, color: Colors.white38, size: 18),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'Voice messages are available on mobile only',
                style: TextStyle(color: Colors.white54, fontSize: 13),
              ),
            ),
            TextButton(
              onPressed: widget.onCancel,
              child: const Text('Close', style: TextStyle(color: _gold)),
            ),
          ],
        ),
      );
    }
    if (_permDenied) {
      return Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        color: _navy,
        child: Row(
          children: [
            const Expanded(
              child: Text(
                'Microphone permission denied',
                style: TextStyle(color: Colors.redAccent, fontSize: 13),
              ),
            ),
            TextButton(
              onPressed: widget.onCancel,
              child: const Text('Close',
                  style: TextStyle(color: _gold)),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: const BoxDecoration(
        color: _darkBg,
        borderRadius: BorderRadius.only(
          topLeft:  Radius.circular(20),
          topRight: Radius.circular(20),
        ),
      ),
      child: Row(
        children: [
          // Recording indicator
          const Icon(Icons.fiber_manual_record, color: Colors.red, size: 14),
          const SizedBox(width: 6),
          // Timer
          Text(
            _formatTime(_seconds),
            style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 16,
                fontFamily: 'monospace'),
          ),
          const SizedBox(width: 8),
          const Text(
            'Recording…',
            style: TextStyle(color: Colors.white60, fontSize: 13),
          ),
          const Spacer(),
          // Cancel / delete
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
            tooltip: 'Cancel',
            onPressed: () {
              _timer?.cancel();
              _recorder?.stopRecorder();
              widget.onCancel();
            },
          ),
          // Stop and send
          IconButton(
            icon: const Icon(Icons.stop_circle, color: _gold, size: 32),
            tooltip: 'Stop & send',
            onPressed: _stopping ? null : _stopRecording,
          ),
        ],
      ),
    );
  }
}
