// lib/sov_node_sdk/sov_file_intent.dart
// â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
// SovFileIntent â€” Android "Open With" file delivery bridge.
//
// Architecture: PULL (not push).
//
// MainActivity reads the file URI bytes the instant onCreate/onNewIntent fires,
// stores them in a native ByteArray, and then neutralizes the Intent so Android
// cannot re-deliver stale data on configuration changes.
//
// Dart polls by calling getPendingFile() at two points:
//   1. During splash routing (cold start via "Open With")
//   2. In didChangeAppLifecycleState(resumed) in main.dart (mid-session)
//
// This guarantees the Flutter engine is fully awake before we attempt to
// read from the channel â€” solving the onNewIntent timing race completely.
// â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class SovFileIntent {

  static const _channel = MethodChannel('network.sov.node/file_intent');

  /// Ask MainActivity to open the native system file picker.
  ///
  /// Unlike the Flutter file_picker plugin, this uses startActivityForResult
  /// so the result is delivered to onActivityResult â€” a native Android protocol
  /// that survives process death. When the user selects a file, MainActivity
  /// caches the bytes in pendingFileBytes. Dart pulls them on the next resume
  /// via getPendingFile() (called by main.dart's lifecycle observer).
  static Future<void> openFilePicker() async {
    try {
      await _channel.invokeMethod<void>('openFilePicker');
    } catch (e) {
      debugPrint('[FILE_INTENT] openFilePicker error: $e');
    }
  }

  /// Pull the file bytes that MainActivity cached from the "Open With" intent
  /// or the native file picker result.
  /// Returns null if nothing is pending.
  /// One-shot: MainActivity clears its cache after this call.
  static Future<Uint8List?> getPendingFile() async {
    try {
      final result = await _channel.invokeMethod<dynamic>('getPendingFile');
      if (result == null) return null;
      if (result is Uint8List) return result;
      // Android may deliver as List<int> â€” normalise
      if (result is List) return Uint8List.fromList(result.cast<int>());
      debugPrint('[FILE_INTENT] getPendingFile unexpected type: ${result.runtimeType}');
      return null;
    } catch (e) {
      debugPrint('[FILE_INTENT] getPendingFile error: $e');
      return null;
    }
  }
}
