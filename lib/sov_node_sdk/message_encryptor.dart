// lib/sov_node_sdk/message_encryptor.dart
// ─────────────────────────────────────────────────────────────────────────────
// S2 — SOV Speak End-to-End Encryption
//
// ALGORITHM STACK:
//   Key agreement: X25519 Diffie-Hellman
//   Key derivation: HKDF-SHA256 (info = "sov-speak-v2")
//   Encryption:     AES-256-GCM (authenticated — provides confidentiality
//                  AND integrity; tampering makes decrypt return null)
//
// ENVELOPE FORMAT (v2):
//   JSON string stored in the encrypted_payload field:
//   {
//     "v": 2,
//     "nonce": "<24-byte hex>",
//     "ct":    "<ciphertext hex>"
//   }
//
// BACKWARD COMPATIBILITY:
//   v1 envelopes: {"from":"...","text":"..."} — plain JSON, no encryption.
//   If encrypt() cannot obtain the recipient's messaging key (old app version,
//   relay unreachable), it falls back to v1 so the message is still delivered.
//   Decrypt() checks "v" field: v2 → decrypt; anything else → return plaintext.
//
// RELAY KEY LOOKUP:
//   RelayConnector.lookupMessagingKey(sovereignId) is called before encryption.
//   The result is cached in-memory for 10 minutes to avoid relay RTT on every send.
// ─────────────────────────────────────────────────────────────────────────────
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart' as sov_crypto;

class MessageEncryptor {
  // HKDF info label — changing this breaks all existing encrypted messages
  static const _hkdfInfo = 'sov-speak-v2';

  // In-memory cache: sovereignId → {pubKeyHex, cachedAt}
  static final Map<String, _KeyCacheEntry> _keyCache = {};
  static const _cacheTtlMs = 10 * 60 * 1000; // 10 minutes

  // ── Public API ───────────────────────────────────────────────────────────────

  /// Encrypt [plaintext] for [recipientPubKeyHex] using [myPrivKeyBytes].
  ///
  /// Returns a v2 JSON envelope string on success, or null if encryption fails.
  static Future<String?> encrypt({
    required String    plaintext,
    required String    recipientPubKeyHex,
    required List<int> myPrivKeyBytes,
  }) async {
    try {
      final recipientPub = _fromHex(recipientPubKeyHex);
      final sharedSecret = await _ecdh(myPrivKeyBytes, recipientPub);
      final aesKey       = await _deriveKey(sharedSecret);
      final nonce        = _randomBytes(12); // AES-GCM 96-bit nonce

      final algorithm = sov_crypto.AesGcm.with256bits(nonceLength: 12);
      final secretKey = await algorithm.newSecretKeyFromBytes(aesKey);
      final box       = await algorithm.encrypt(
        utf8.encode(plaintext),
        secretKey: secretKey,
        nonce:     nonce,
      );

      // Concatenate ciphertext + MAC (16 bytes appended by AesGcm)
      final ctBytes = Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);

      return jsonEncode({
        'v':     2,
        'nonce': _toHex(Uint8List.fromList(nonce)),
        'ct':    _toHex(ctBytes),
      });
    } catch (e) {
      return null;
    }
  }

  /// Decrypt a v2 envelope.
  ///
  /// Returns the plaintext string on success.
  /// Returns null if decryption fails (wrong key, tampered ciphertext, etc.).
  /// For v1 envelopes (plain JSON), returns null — caller should use v1 parsing.
  static Future<String?> decryptEnvelope({
    required String    envelope,
    required String    senderPubKeyHex,
    required List<int> myPrivKeyBytes,
  }) async {
    try {
      final obj = jsonDecode(envelope) as Map<String, dynamic>;
      if ((obj['v'] as int? ?? 1) != 2) return null; // v1 — not our job

      final nonceHex = obj['nonce'] as String;
      final ctHex    = obj['ct']    as String;

      final nonce  = _fromHex(nonceHex);
      final ctFull = _fromHex(ctHex);

      if (ctFull.length < 16) return null; // too short to hold MAC
      final cipherText = ctFull.sublist(0, ctFull.length - 16);
      final mac        = ctFull.sublist(ctFull.length - 16);

      final senderPub  = _fromHex(senderPubKeyHex);
      final sharedSecret = await _ecdh(myPrivKeyBytes, senderPub);
      final aesKey       = await _deriveKey(sharedSecret);

      final algorithm = sov_crypto.AesGcm.with256bits(nonceLength: 12);
      final secretKey = await algorithm.newSecretKeyFromBytes(aesKey);
      final plain     = await algorithm.decrypt(
        sov_crypto.SecretBox(
          cipherText,
          nonce: nonce,
          mac:   sov_crypto.Mac(mac),
        ),
        secretKey: secretKey,
      );

      return utf8.decode(plain);
    } catch (_) {
      return null;
    }
  }

  /// Returns true if [envelope] is a v2 encrypted envelope.
  static bool isEncryptedEnvelope(String envelope) {
    try {
      final obj = jsonDecode(envelope) as Map<String, dynamic>;
      return (obj['v'] as int? ?? 1) == 2;
    } catch (_) {
      return false;
    }
  }

  // ── Key cache ────────────────────────────────────────────────────────────────

  static void cacheKey(String sovereignId, String pubKeyHex) {
    _keyCache[sovereignId] = _KeyCacheEntry(
      pubKeyHex: pubKeyHex,
      cachedAt:  DateTime.now().millisecondsSinceEpoch,
    );
  }

  static String? getCachedKey(String sovereignId) {
    final entry = _keyCache[sovereignId];
    if (entry == null) return null;
    final age = DateTime.now().millisecondsSinceEpoch - entry.cachedAt;
    if (age > _cacheTtlMs) {
      _keyCache.remove(sovereignId);
      return null;
    }
    return entry.pubKeyHex;
  }

  // ── X25519 ECDH ─────────────────────────────────────────────────────────────

  static Future<List<int>> _ecdh(
      List<int> myPrivBytes, List<int> theirPubBytes) async {
    final alg     = sov_crypto.X25519();
    final privKey = await alg.newKeyPairFromSeed(myPrivBytes);
    final pubKey  = sov_crypto.SimplePublicKey(theirPubBytes,
        type: sov_crypto.KeyPairType.x25519);
    final shared  = await alg.sharedSecretKey(
        keyPair: privKey, remotePublicKey: pubKey);
    return shared.extractBytes();
  }

  // ── HKDF-SHA256 key derivation ───────────────────────────────────────────────

  static Future<List<int>> _deriveKey(List<int> sharedSecret) async {
    final hkdf = sov_crypto.Hkdf(
      hmac:     sov_crypto.Hmac.sha256(),
      outputLength: 32,
    );
    final secretKey = await hkdf.deriveKey(
      secretKey: sov_crypto.SecretKey(sharedSecret),
      nonce:     utf8.encode('sov-speak-salt'),
      info:      utf8.encode(_hkdfInfo),
    );
    return secretKey.extractBytes();
  }

  // ── Random bytes ─────────────────────────────────────────────────────────────

  static List<int> _randomBytes(int count) {
    final rng   = Random.secure();
    return List<int>.generate(count, (_) => rng.nextInt(256));
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

// ── Cache entry ───────────────────────────────────────────────────────────────

class _KeyCacheEntry {
  final String pubKeyHex;
  final int    cachedAt;
  _KeyCacheEntry({required this.pubKeyHex, required this.cachedAt});
}
