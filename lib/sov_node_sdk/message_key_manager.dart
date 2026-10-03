// lib/sov_node_sdk/message_key_manager.dart
// ─────────────────────────────────────────────────────────────────────────────
// S2 — SOV Speak E2E Encryption: X25519 Messaging Keypair
//
// PURPOSE:
//   Separate from KeyManager (Ed25519 signing keys).
//   This keypair is used exclusively for ECDH key agreement in SOV Speak.
//   Principle: signing key ≠ encryption key (key-separation best practice).
//
// STORAGE:
//   Private key in flutter_secure_storage (encrypted SharedPreferences on Android).
//   Public key also in secure storage + SharedPreferences for fast HELLO registration.
//   FILE FALLBACK: on platforms where secure storage silently fails (Windows
//   Credential Store issues), keys are stored in {appSupportDir}/sov_msg_keys.json.
//   This ensures the same key is used across restarts rather than generating a
//   fresh keypair every launch (which would cause "no key on file" errors for
//   contacts who cached the old public key).
//
// LIFECYCLE:
//   1. App first run  → generate X25519 keypair → store
//   2. HELLO send     → include messaging_public_key hex in payload
//   3. Message send   → get recipient pub key from relay → ECDH → encrypt
//   4. Message recv   → look up sender pub key → ECDH → decrypt
// ─────────────────────────────────────────────────────────────────────────────
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart' as sov_crypto;
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MessageKeyManager {
  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _fallbackStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: false),
  );

  static const _privKey = 'sov_msg_private_key_v1';
  static const _pubKey  = 'sov_msg_public_key_v1';
  static const _pubPref = 'sov_msg_public_key_hex';

  static FlutterSecureStorage _store = _secureStorage;

  /// False once the platform's secret store has proved unusable.
  ///
  /// On Linux this happens whenever libsecret has no unlocked keyring — a fresh
  /// WSL, a container, a minimal desktop. It is not an error worth stopping for:
  /// the on-disk key file below works on every platform, so we note it and move
  /// on rather than throwing out of initialise().
  // Linux starts UNUSABLE so no _safeRead/_safeWrite can reach libsecret before
  // initialise() runs — a boot-time read would otherwise hit the default
  // _secureStorage (libsecret) and pop the keyring dialog. initialise() also sets
  // this false on Linux; making it the DEFAULT removes the call-ordering hole.
  static bool _secureStoreUsable = !Platform.isLinux;

  /// Read from the secret store, returning null instead of throwing.
  /// The first failure disables further attempts for this process.
  static Future<String?> _safeRead(String key) async {
    if (!_secureStoreUsable) return null;
    try {
      return await _store.read(key: key);
    } catch (e) {
      _secureStoreUsable = false;
      debugPrint('[MsgKey] secret store unusable ($e) — using the key file instead');
      return null;
    }
  }

  /// Write to the secret store, best effort. The key file is always written too,
  /// so losing this is a degradation, never data loss.
  static Future<void> _safeWrite(String key, String value) async {
    if (!_secureStoreUsable) return;
    try {
      await _store.write(key: key, value: value);
    } catch (e) {
      _secureStoreUsable = false;
      debugPrint('[MsgKey] secret store write failed ($e) — using the key file instead');
    }
  }

  // ── Initialise (idempotent) ─────────────────────────────────────────────────

  static Future<void> initialise() async {
    // Probe the encrypted store, then the plain one. On Android these are two
    // genuinely different backends; on Linux and Windows they are the same one,
    // so if the first throws the second almost certainly will too — which is why
    // the result decides whether we use a secret store AT ALL rather than which.
    // Linux: NEVER touch flutter_secure_storage. Its libsecret backend pops a
    // GNOME "Unlock Login Keyring" dialog on a real desktop with a keyring daemon —
    // it does NOT simply throw, as this code once assumed (that only happens on a
    // headless / keyring-less box like WSL). The on-disk key file below works on
    // every platform, so on Linux we skip the secret store entirely. This mirrors
    // KeyManager's _LinuxFileStore decision — see docs/LINUX_KEYRING_FIX.md.
    if (Platform.isLinux) {
      _secureStoreUsable = false;
    } else {
      try {
        await _secureStorage.read(key: _privKey);
        _store = _secureStorage;
      } catch (_) {
        try {
          await _fallbackStorage.read(key: _privKey);
          _store = _fallbackStorage;
        } catch (e) {
          _secureStoreUsable = false;
          debugPrint('[MsgKey] no usable secret store ($e) — the key file will be used');
        }
      }
    }

    final existing = await _safeRead(_privKey);
    if (existing != null) {
      await _cachePubKeyToPrefs();
      return;
    }

    // File fallback — covers Windows where DPAPI/Credential Store silently fails,
    // causing secure storage reads to return null even after a write.
    // If the file exists and is valid, use it (avoids generating a new keypair
    // every launch, which rotates the public key and breaks senders who cached it).
    if (await _loadFromFile()) return;

    await _generateAndStore();
  }

  // ── Generate a fresh X25519 keypair ─────────────────────────────────────────

  static Future<void> _generateAndStore() async {
    final alg     = sov_crypto.X25519();
    final keyPair = await alg.newKeyPair();

    final privBytes = await keyPair.extractPrivateKeyBytes();
    final pubKey    = await keyPair.extractPublicKey();
    final pubBytes  = pubKey.bytes;

    final privHex = _toHex(Uint8List.fromList(privBytes));
    final pubHex  = _toHex(Uint8List.fromList(pubBytes));

    // Write to secure storage (best effort — may silently fail on some platforms)
    try {
      await _safeWrite(_privKey, privHex);
      await _safeWrite(_pubKey,  pubHex);
    } catch (e) {
      debugPrint('[MsgKey] secure storage write failed: $e');
    }

    // Always write to file fallback — guaranteed to work on all platforms
    await _saveToFile(privHex, pubHex);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pubPref, pubHex);
  }

  // ── File-based fallback storage ─────────────────────────────────────────────

  static Future<File?> _keyFile() async {
    try {
      final dir = await getApplicationSupportDirectory();
      return File('${dir.path}/sov_msg_keys.json');
    } catch (_) {
      return null;
    }
  }

  static Future<bool> _loadFromFile() async {
    try {
      final f = await _keyFile();
      if (f == null || !await f.exists()) return false;
      final data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final privHex = data['priv'] as String?;
      final pubHex  = data['pub']  as String?;
      if (privHex == null || pubHex == null) return false;
      if (privHex.length != 64 || pubHex.length != 64) return false;

      // Restore to the secret store (best effort — the file is the source of truth here)
      await _safeWrite(_privKey, privHex);
      await _safeWrite(_pubKey,  pubHex);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_pubPref, pubHex);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _saveToFile(String privHex, String pubHex) async {
    try {
      final f = await _keyFile();
      if (f == null) return;
      await f.writeAsString(jsonEncode({'priv': privHex, 'pub': pubHex}));
    } catch (e) {
      debugPrint('[MsgKey] file write failed: $e');
    }
  }

  // ── WIPE — full reset ───────────────────────────────────────────────────────
  // Clears both secure-storage keys AND the Windows file fallback. Skipping the
  // file fallback would let a "reset" silently resurrect the old messaging
  // keypair on next launch via _loadFromFile().
  static Future<void> wipeKeys() async {
    // Linux: NEVER call the secret-store delete — on a real desktop libsecret's
    // .delete() does not throw, it prompts to unlock the keyring (the very dialog
    // this platform avoids). The messaging keys live only in the on-disk file on
    // Linux, so the file delete below is the whole wipe. See docs/LINUX_KEYRING_FIX.md.
    if (!Platform.isLinux) {
      try { await _secureStorage.delete(key: _privKey); } catch (_) {}
      try { await _secureStorage.delete(key: _pubKey); } catch (_) {}
      try { await _fallbackStorage.delete(key: _privKey); } catch (_) {}
      try { await _fallbackStorage.delete(key: _pubKey); } catch (_) {}
    }
    try {
      final f = await _keyFile();
      if (f != null && await f.exists()) await f.delete();
    } catch (_) {}
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pubPref);
  }

  // ── Public key accessors ────────────────────────────────────────────────────

  /// Returns the local messaging public key hex (fast — from SharedPreferences).
  static Future<String> getPublicKeyHex() async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_pubPref);
    if (cached != null && cached.isNotEmpty) return cached;

    // Try secure storage
    try {
      final stored = await _safeRead(_pubKey) ?? '';
      if (stored.isNotEmpty) {
        await prefs.setString(_pubPref, stored);
        return stored;
      }
    } catch (_) {}

    // Try file fallback
    try {
      final f = await _keyFile();
      if (f != null && await f.exists()) {
        final data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        final pubHex = data['pub'] as String? ?? '';
        if (pubHex.isNotEmpty) {
          await prefs.setString(_pubPref, pubHex);
          return pubHex;
        }
      }
    } catch (_) {}

    return '';
  }

  /// Returns the raw private key bytes for ECDH operations.
  static Future<List<int>?> getPrivateKeyBytes() async {
    // Try secure storage first
    try {
      final hex = await _safeRead(_privKey);
      if (hex != null && hex.isNotEmpty) return _fromHex(hex);
    } catch (_) {}

    // Try file fallback
    try {
      final f = await _keyFile();
      if (f != null && await f.exists()) {
        final data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        final privHex = data['priv'] as String? ?? '';
        if (privHex.isNotEmpty) return _fromHex(privHex);
      }
    } catch (_) {}

    return null;
  }

  /// Returns the raw public key bytes.
  static Future<List<int>?> getPublicKeyBytes() async {
    final hex = await getPublicKeyHex();
    if (hex.isEmpty) return null;
    return _fromHex(hex);
  }

  // ── Cache public key to SharedPreferences ───────────────────────────────────

  static Future<void> _cachePubKeyToPrefs() async {
    final prefs  = await SharedPreferences.getInstance();
    final cached = prefs.getString(_pubPref);
    if (cached != null && cached.isNotEmpty) return;
    try {
      final stored = await _safeRead(_pubKey) ?? '';
      if (stored.isNotEmpty) await prefs.setString(_pubPref, stored);
    } catch (_) {
      // File fallback
      try {
        final f = await _keyFile();
        if (f != null && await f.exists()) {
          final data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
          final pubHex = data['pub'] as String? ?? '';
          if (pubHex.isNotEmpty) await prefs.setString(_pubPref, pubHex);
        }
      } catch (_) {}
    }
  }

  // ── Hex helpers ─────────────────────────────────────────────────────────────

  static String _toHex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static List<int> _fromHex(String hex) {
    final result = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      result.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return result;
  }
}
