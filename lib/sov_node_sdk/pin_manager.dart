// lib/sov_node_sdk/pin_manager.dart
// ─────────────────────────────────────────────────────────────────────────────
// PIN MANAGER — Device-tied PIN hashing
//
// Hash derivation: sha256(pin + deviceId + sovereignId + 'SOV-PIN-V1')
//
// Binding the hash to the device's android.id means:
//   • A PIN hash extracted from one device cannot unlock a different device
//   • A citizen cannot reuse their PIN hash from a backup on another phone
//
// The salt 'SOV-PIN-V1' versions the scheme; increment to 'SOV-PIN-V2' if
// the derivation algorithm ever changes (triggers a re-enrollment prompt).
//
// All callers MUST use PinManager.hashPin() / PinManager.verifyPin() exclusively.
// Direct sha256(pin + sovId) is deprecated — never call it from new code.
// ─────────────────────────────────────────────────────────────────────────────
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

class PinManager {
  static const String _salt = 'SOV-PIN-V1';

  // Cache device ID so we only call the platform channel once per session.
  static String? _cachedDeviceId;

  static Future<String> _getDeviceId() async {
    if (_cachedDeviceId != null) return _cachedDeviceId!;
    try {
      final info = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final android = await info.androidInfo;
        _cachedDeviceId = android.id;
        return _cachedDeviceId!;
      }
      // iOS / other platforms — extend here as needed.
      _cachedDeviceId = 'unknown-platform';
      return _cachedDeviceId!;
    } catch (e) {
      debugPrint('[PIN] Device ID error: $e');
      _cachedDeviceId = 'fallback-device-id';
      return _cachedDeviceId!;
    }
  }

  /// Derive the PIN hash: sha256(pin + deviceId + sovereignId + salt).
  /// Both [PinSetupScreen] and [PinLockOverlay] MUST call this method so
  /// the hash they store and the hash they check are identical.
  static Future<String> hashPin(String pin, String sovereignId) async {
    final deviceId = await _getDeviceId();
    final input    = pin + deviceId + sovereignId + _salt;
    return sha256.convert(utf8.encode(input)).toString();
  }

  /// Returns true if [enteredPin] matches [storedHash] for [sovereignId]
  /// on this device.  Returns false if [storedHash] is empty.
  static Future<bool> verifyPin(
      String enteredPin, String storedHash, String sovereignId) async {
    if (storedHash.isEmpty) return false;
    final computed = await hashPin(enteredPin, sovereignId);
    return computed == storedHash;
  }
}
