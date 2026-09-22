// lib/sov_node_sdk/bip39.dart
// BIP39 mnemonic generation — thin wrapper around the bip39 package.
// Converts List<int> masterKeyBits (128 bits) to a 12-word mnemonic.
import 'dart:typed_data';
import 'package:bip39/bip39.dart' as bip39_pkg;
import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';

class Bip39 {
  /// Convert 128 masterKeyBits (List<int> of 0/1 values) to a 12-word BIP39 mnemonic.
  /// The same bits always produce the same 12 words — deterministic.
  static List<String> bitsToMnemonic(List<int> bits) {
    assert(bits.length == 128, 'BIP39: expected 128 bits');
    final bytes = Uint8List(16);
    for (var i = 0; i < 128; i++) {
      if (bits[i] == 1) bytes[i ~/ 8] |= (0x80 >> (i % 8));
    }
    final entropyHex = hex.encode(bytes);
    final mnemonic   = bip39_pkg.entropyToMnemonic(entropyHex);
    return mnemonic.trim().split(' ');
  }

  /// Validate a 12-word mnemonic — returns true if all words are valid BIP39.
  static bool validateMnemonic(List<String> words) {
    if (words.length != 12) return false;
    return bip39_pkg.validateMnemonic(words.join(' '));
  }

  /// Derive the master key hash (SHA-256 of the 16 entropy bytes) from a 12-word mnemonic.
  /// This produces the same hash as FuzzyCommitment.enroll() used during enrollment.
  /// Returns '' if the mnemonic is invalid.
  static String mnemonicToMasterKeyHash(List<String> words) {
    try {
      final mnemonic    = words.map((w) => w.trim().toLowerCase()).join(' ');
      final entropyHex  = bip39_pkg.mnemonicToEntropy(mnemonic);
      final entropyBytes = hex.decode(entropyHex);
      return sha256.convert(entropyBytes).toString();
    } catch (_) {
      return '';
    }
  }

  /// Derive the Sovereign ID from a 12-word seed phrase.
  /// Uses the same derivation as enrollment_screen: 'SOV-' + masterKeyHash[0:16].toUpperCase()
  static String mnemonicToSovereignId(List<String> words) {
    final keyHash = mnemonicToMasterKeyHash(words);
    if (keyHash.isEmpty) return '';
    return 'SOV-${keyHash.substring(0, 16).toUpperCase()}';
  }

  /// Validate mnemonic and return entropy bytes. Returns null if invalid.
  static List<int>? mnemonicToEntropyBytes(List<String> words) {
    try {
      final mnemonic   = words.map((w) => w.trim().toLowerCase()).join(' ');
      final entropyHex = bip39_pkg.mnemonicToEntropy(mnemonic);
      return hex.decode(entropyHex);
    } catch (_) {
      return null;
    }
  }

}
