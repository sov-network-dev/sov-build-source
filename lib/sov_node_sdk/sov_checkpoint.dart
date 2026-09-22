// lib/sov_node_sdk/sov_checkpoint.dart
// ─────────────────────────────────────────────────────────────────────────────
// SovCheckpoint — kernel-persisted encrypted storage for external activity state.
//
// Problem: When the app opens an external activity (file picker, share sheet)
// Android may kill the process on low-RAM devices. SharedPreferences uses
// editor.apply() which schedules an async flush — that thread is killed by
// SIGKILL before it completes. flutter_secure_storage has the same root cause
// (it also calls apply() internally).
//
// Solution: Write a checkpoint via dart:io File.writeAsStringSync(flush: true).
// This passes data directly to the kernel VFS buffer cache, which survives
// user-space SIGKILL. On restart, splash reads the checkpoint and routes
// correctly before any SharedPreferences logic runs.
// ─────────────────────────────────────────────────────────────────────────────
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class SovCheckpoint {

  static const String _appSalt  = 'sov-checkpoint-salt-v1';
  static const String _fileName = '.sov_checkpoint';

  // ── Private helpers ────────────────────────────────────────────────────────

  static Future<File> _checkpointFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  /// AES key = SHA-256(androidId + appSalt).
  /// Falls back to SHA-256(appSalt) on any error (e.g. emulator without ID).
  static Future<Uint8List> _derivedKey() async {
    try {
      final android  = await DeviceInfoPlugin().androidInfo;
      final deviceId = android.id;
      return Uint8List.fromList(
          sha256.convert(utf8.encode(deviceId + _appSalt)).bytes);
    } catch (_) {
      return Uint8List.fromList(
          sha256.convert(utf8.encode(_appSalt)).bytes);
    }
  }

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Write checkpoint before opening any external activity.
  /// Uses dart:io writeAsStringSync(flush:true) — kernel VFS buffer survives SIGKILL.
  static Future<void> write({
    required String type,
    required Map<String, dynamic> data,
  }) async {
    try {
      final payload = jsonEncode({
        'type':      type,
        'data':      data,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });

      final keyBytes  = await _derivedKey();
      final key       = enc.Key(keyBytes);
      final iv        = enc.IV.fromSecureRandom(16);
      final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc));
      final encrypted = encrypter.encrypt(payload, iv: iv);

      // Prepend IV to ciphertext, base64-encode the whole thing
      final stored = base64.encode(
          Uint8List.fromList([...iv.bytes, ...encrypted.bytes]));

      final file = await _checkpointFile();
      // flush: true pushes to kernel VFS buffer — survives user-space SIGKILL
      file.writeAsStringSync(stored, flush: true);

      debugPrint('[CHECKPOINT] Written: $type');
    } catch (e) {
      // Non-fatal — checkpoint failure must never block the user flow
      debugPrint('[CHECKPOINT] Write failed: $e');
    }
  }

  /// Read checkpoint on app startup. Returns null if none exists or is expired.
  static Future<Map<String, dynamic>?> read() async {
    try {
      final file = await _checkpointFile();
      if (!file.existsSync()) return null;

      final stored = file.readAsStringSync();
      if (stored.isEmpty) return null;

      final keyBytes    = await _derivedKey();
      final key         = enc.Key(keyBytes);
      final allBytes    = base64.decode(stored);
      final iv          = enc.IV(Uint8List.fromList(allBytes.sublist(0, 16)));
      final cipherBytes = enc.Encrypted(Uint8List.fromList(allBytes.sublist(16)));
      final payload     = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc))
          .decrypt(cipherBytes, iv: iv);

      final checkpoint = jsonDecode(payload) as Map<String, dynamic>;

      // Expire checkpoints older than 1 hour — no longer relevant
      final timestamp = checkpoint['timestamp'] as int? ?? 0;
      final age       = DateTime.now().millisecondsSinceEpoch - timestamp;
      if (age > 3600000) {
        await clear();
        debugPrint('[CHECKPOINT] Expired, cleared');
        return null;
      }

      debugPrint('[CHECKPOINT] Found: ${checkpoint['type']}');
      return checkpoint;
    } catch (e) {
      debugPrint('[CHECKPOINT] Read failed: $e');
      return null;
    }
  }

  /// Clear checkpoint after successful completion of external activity.
  static Future<void> clear() async {
    try {
      final file = await _checkpointFile();
      if (file.existsSync()) file.deleteSync();
      debugPrint('[CHECKPOINT] Cleared');
    } catch (e) {
      debugPrint('[CHECKPOINT] Clear failed: $e');
    }
  }

  /// Returns true if a checkpoint of the given type currently exists.
  static Future<bool> exists(String type) async {
    final cp = await read();
    return cp != null && cp['type'] == type;
  }
}

// ── Checkpoint type constants ──────────────────────────────────────────────
class CheckpointType {
  static const String recoveryFilePicker = 'recovery_file_picker';
  static const String enrollmentShare    = 'enrollment_share';
}
