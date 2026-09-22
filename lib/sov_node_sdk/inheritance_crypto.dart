// lib/sov_node_sdk/inheritance_crypto.dart
// Cryptographic helpers for the Inheritance & Allocation system.
//
// All operations are pure-Dart — no relay calls.
// Claim keys are NEVER sent to the relay; only their sha256 hashes are.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

class InheritanceCrypto {
  // ── Claim-key alphabet: unambiguous uppercase alphanumerics ─────────────────
  static const _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  // ── generateClaimKey ────────────────────────────────────────────────────────
  /// Generates a human-readable claim key: SOVW-XXXX-XXXX-XXXX
  static String generateClaimKey() {
    final rng = Random.secure();
    String block() =>
        List.generate(4, (_) => _alphabet[rng.nextInt(_alphabet.length)]).join();
    return 'SOVW-${block()}-${block()}-${block()}';
  }

  // ── hashClaimKey ────────────────────────────────────────────────────────────
  /// SHA-256 hex of the raw claim key string.  This is what goes to the relay.
  static String hashClaimKey(String claimKey) =>
      sha256.convert(utf8.encode(claimKey.trim())).toString();

  // ── hashBeneficiaryName ─────────────────────────────────────────────────────
  /// Normalise (trim + lowercase) then SHA-256 hash the beneficiary name.
  /// Stored in sov_allocations.beneficiary_name_hash for unclaimed broadcast search.
  static String hashBeneficiaryName(String name) =>
      sha256.convert(utf8.encode(name.trim().toLowerCase())).toString();

  // ── hashFamilyKey ────────────────────────────────────────────────────────────
  /// SHA-256 hash of a family verification key phrase.
  static String hashFamilyKey(String key) =>
      sha256.convert(utf8.encode(key.trim())).toString();

  // ── encryptWithKey ───────────────────────────────────────────────────────────
  /// XOR encrypt [plaintext] with [keyPhrase], then base64-encode the result.
  ///
  /// Key bytes are repeated (modulo) to cover the full plaintext length.
  /// Produces a base64 string safe to store in the DB.
  static String encryptWithKey(String plaintext, String keyPhrase) {
    if (keyPhrase.isEmpty) return base64.encode(utf8.encode(plaintext));
    final textBytes = utf8.encode(plaintext);
    final keyBytes  = utf8.encode(keyPhrase);
    final result    = Uint8List(textBytes.length);
    for (int i = 0; i < textBytes.length; i++) {
      result[i] = textBytes[i] ^ keyBytes[i % keyBytes.length];
    }
    return base64.encode(result);
  }

  // ── decryptWithKey ───────────────────────────────────────────────────────────
  /// Base64-decode, then XOR with [keyPhrase] to recover plaintext.
  /// Returns null if decryption fails (wrong key or corrupt data).
  static String? decryptWithKey(String cipherBase64, String keyPhrase) {
    try {
      final cipherBytes = base64.decode(cipherBase64);
      if (keyPhrase.isEmpty) return utf8.decode(cipherBytes);
      final keyBytes = utf8.encode(keyPhrase);
      final result   = Uint8List(cipherBytes.length);
      for (int i = 0; i < cipherBytes.length; i++) {
        result[i] = cipherBytes[i] ^ keyBytes[i % keyBytes.length];
      }
      return utf8.decode(result);
    } catch (_) {
      return null;
    }
  }

  // ── encryptBeneficiaryName ──────────────────────────────────────────────────
  /// Convenience: encrypt beneficiary name with the claim key so the relay
  /// can't read who is named.
  static String encryptBeneficiaryName(String name, String claimKey) =>
      encryptWithKey(name.trim(), claimKey);

  // ── decryptBeneficiaryName ──────────────────────────────────────────────────
  static String? decryptBeneficiaryName(String cipherBase64, String claimKey) =>
      decryptWithKey(cipherBase64, claimKey);

  // ── encryptPersonalNote ─────────────────────────────────────────────────────
  static String encryptPersonalNote(String note, String claimKey) =>
      encryptWithKey(note, claimKey);

  // ── decryptPersonalNote ─────────────────────────────────────────────────────
  static String? decryptPersonalNote(String cipherBase64, String claimKey) =>
      decryptWithKey(cipherBase64, claimKey);

  // ── releaseYearsToTimestamp ─────────────────────────────────────────────────
  /// Convert a years-from-now value to unix seconds (for relay release_date).
  static int releaseYearsToTimestamp(int years) {
    final now = DateTime.now();
    return DateTime(now.year + years, now.month, now.day)
        .millisecondsSinceEpoch ~/
        1000;
  }

  // ── validateClaimKeyFormat ──────────────────────────────────────────────────
  static bool validateClaimKeyFormat(String key) {
    final clean = key.trim().toUpperCase();
    if (!clean.startsWith('SOVW-')) return false;
    final parts = clean.split('-');
    if (parts.length != 4) return false;
    if (parts[0] != 'SOVW') return false;
    return parts.sublist(1).every((p) => p.length == 4);
  }
}
