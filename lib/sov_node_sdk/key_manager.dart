import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart' as sov_crypto;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ═══════════════════════════════════════════════════════════════════════════
// KeyManager — Sovereign Identity & Ed25519 Signing
//
// SECURITY ARCHITECTURE:
//   - Ed25519 keypair generated using dart:math Random.secure() entropy
//   - Private key stored in Android Keystore via flutter_secure_storage
//     (hardware-backed on devices with Secure Enclave / StrongBox)
//   - Every outgoing message signed with Ed25519 private key
//   - Relay verifies signature against stored public key before processing
//   - Nonce counter stored securely — prevents replay attacks
//
// WHAT CHANGED FROM ORIGINAL:
//   - Was: HMAC-SHA256 — a keyed hash, not a real digital signature
//   - Now: Real Ed25519 via cryptography package — mathematically unforgeable
//   - Was: timestamp % 256 random — predictable, NOT cryptographically secure
//   - Now: dart:math Random.secure() — cryptographically secure
//   - Added: nonce management for replay protection
//   - Added: signMessage() for full message payload signing
// ═══════════════════════════════════════════════════════════════════════════

// ═══════════════════════════════════════════════════════════════════════════
// Key storage backends.
//
// Everywhere except Linux this is flutter_secure_storage, backed by the OS
// keystore. On Linux that package talks to libsecret, which pops the GNOME
// Keyring unlock dialog — asking the citizen for a password SOV never created
// and cannot tell them. It looks exactly like the app demanding a secret the
// user is supposed to already know. (It never showed up in WSL testing because
// WSLg runs no keyring daemon, so the call ERRORED instead of PROMPTING.)
//
// The fix is not to write the key to a plain file — that would put an
// unencrypted Ed25519 private key on disk, which is strictly worse than an
// annoying prompt. Instead Linux gets a file-backed store that REFUSES to hold
// a plaintext private key at all. The key exists on disk only as the
// Spend-Lock blob: Argon2id(PIN) → AES-GCM. Same protection the keyring was
// supposed to give, from a PIN the citizen actually chose.
// ═══════════════════════════════════════════════════════════════════════════
abstract class _KeyStore {
  Future<String?> read({required String key});
  Future<void> write({required String key, required String value});
  Future<void> delete({required String key});
  Future<void> deleteAll();
}

/// The normal path: OS-backed secure storage.
class _SecureStore implements _KeyStore {
  const _SecureStore(this._s);
  final FlutterSecureStorage _s;

  @override
  Future<String?> read({required String key}) => _s.read(key: key);
  @override
  Future<void> write({required String key, required String value}) =>
      _s.write(key: key, value: value);
  @override
  Future<void> delete({required String key}) => _s.delete(key: key);
  @override
  Future<void> deleteAll() => _s.deleteAll();
}

/// Linux: a JSON file next to the wallet data, permissions 0600.
///
/// It will not store a plaintext private key. Attempting to is a programming
/// error and throws, rather than silently writing a secret to disk — a silent
/// downgrade here would be the worst possible outcome, so it fails loudly.
class _LinuxFileStore implements _KeyStore {
  _LinuxFileStore(this._file, this._forbiddenKey);
  final File _file;
  final String _forbiddenKey;
  Map<String, String>? _cache;

  Future<Map<String, String>> _load() async {
    if (_cache != null) return _cache!;
    try {
      if (await _file.exists()) {
        final raw = jsonDecode(await _file.readAsString());
        _cache = (raw as Map).map((k, v) => MapEntry('$k', '$v'));
      } else {
        _cache = <String, String>{};
      }
    } catch (_) {
      _cache = <String, String>{};
    }
    return _cache!;
  }

  Future<void> _flush() async {
    await _file.parent.create(recursive: true);
    await _file.writeAsString(jsonEncode(_cache ?? {}), flush: true);
    // Owner-only. Best effort: on a filesystem without POSIX modes this is a
    // no-op, and the contents are still only ever ciphertext.
    try {
      await Process.run('chmod', ['600', _file.path]);
    } catch (_) {}
  }

  @override
  Future<String?> read({required String key}) async => (await _load())[key];

  @override
  Future<void> write({required String key, required String value}) async {
    if (key == _forbiddenKey) {
      throw StateError(
        'Refusing to write an unencrypted private key to disk on Linux. '
        'Set a PIN (Spend-Lock) so the key is stored as an Argon2id-encrypted '
        'blob instead.',
      );
    }
    (await _load())[key] = value;
    await _flush();
  }

  @override
  Future<void> delete({required String key}) async {
    (await _load()).remove(key);
    await _flush();
  }

  @override
  Future<void> deleteAll() async {
    _cache = <String, String>{};
    try {
      if (await _file.exists()) await _file.delete();
    } catch (_) {}
  }
}

class KeyManager {
  // ── Encrypted storage (hardware-backed Android Keystore) ─────────────────
  static const _encryptedStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  // ── Plain storage fallback (used when Keystore is unavailable) ───────────
  static const _plainStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: false),
  );

  // Active storage. On Linux this MUST be the file store from the VERY FIRST
  // access — before initialise()/_resolveStorage() has necessarily run — because
  // any getter (getSovereignId / getPublicKey / _getPrivateKey) touching a default
  // _SecureStore would call libsecret and pop the "Unlock Login Keyring" dialog at
  // boot (the splash reads a key to decide enrollment-vs-main before initialise).
  // So the default is computed per-platform, not a const secure store.
  static _KeyStore _storage = _defaultStore();

  static _KeyStore _defaultStore() {
    if (Platform.isLinux) {
      final dir = Platform.environment['SOV_DATA_DIR'] ??
          '${Platform.environment['HOME'] ?? '.'}/.sov-node';
      return _LinuxFileStore(File('$dir/keys.json'), _privateKeyK);
    }
    return const _SecureStore(_encryptedStorage);
  }

  /// True when the private key can only be persisted PIN-encrypted (Linux).
  /// The wallet UI must collect a PIN before the key can be written at all.
  static bool get requiresPinToPersist => Platform.isLinux;

  /// A freshly generated or restored key held in memory because Linux will not
  /// accept it on disk until a PIN exists. Cleared once Spend-Lock stores it.
  static String? _pendingPrivateKeyHex;

  /// True when a key is waiting for a PIN before it can be saved. The UI must
  /// prompt, then call [enableSpendLock] — otherwise the wallet is memory-only
  /// and will be gone at next launch.
  static bool get hasUnsavedKey => _pendingPrivateKeyHex != null;

  static const _privateKeyK  = 'sov_private_key_v2';
  static const _publicKeyK   = 'sov_public_key_v2';
  static const _sovereignIdK = 'sov_sovereign_id_v2';
  static const _nonceK       = 'sov_nonce_v2';

  // ── Spend-Lock (2026-07-24) ────────────────────────────────────────────────
  // When Spend-Lock is ON, the private key is NOT stored in the clear — only a
  // PIN-encrypted blob (_encPrivateKeyK) is kept, so a machine-level attacker who
  // reads secure storage gets ciphertext they can't use without the PIN. The
  // decrypted key lives in memory only for a bounded SESSION (unlockSession),
  // exactly like Bitcoin Core's `walletpassphrase <pass> <timeout>` — so automation
  // unlocks once and does not re-prompt per transfer.
  static const _encPrivateKeyK = 'sov_enc_privkey_v1'; // "saltHex:nonceHex:cipher+macHex"
  static const _spendLockPref  = 'spend_lock_enabled';
  // Argon2id (memory-hard) — resists GPU/ASIC brute force far better than PBKDF2,
  // which matters because a PIN is short. OWASP "interactive" params (~0.4s here).
  static const int _argonMemKiB      = 19456; // 19 MiB per guess
  static const int _argonIterations  = 2;
  static const int _argonParallelism = 1;
  static String?   _sessionKeyHex;                     // decrypted key, in memory only
  static DateTime? _sessionExpiry;

  static final _algorithm = sov_crypto.Ed25519();

  // ══════════════════════════════════════════════════════════════════════════
  // _resolveStorage — choose encrypted if available, fall back to plain.
  // Some devices (missing hardware Keystore, locked bootloader, or certain
  // Android OS versions) throw PlatformException when EncryptedSharedPrefs
  // are first accessed. Gracefully degrade to plain secure storage so
  // enrollment is never blocked by a Keystore capability check.
  // ══════════════════════════════════════════════════════════════════════════
  static Future<void> _resolveStorage() async {
    // Linux never touches libsecret. See the note above _KeyStore: the keyring
    // prompt asks for a password SOV never set, and the citizen has no way to
    // know it. A file store that refuses plaintext keys is both quieter and,
    // with Spend-Lock, no weaker.
    if (Platform.isLinux) {
      if (_storage is _LinuxFileStore) return;
      final dir = Platform.environment['SOV_DATA_DIR'] ??
          '${Platform.environment['HOME'] ?? '.'}/.sov-node';
      _storage = _LinuxFileStore(File('$dir/keys.json'), _privateKeyK);
      return;
    }
    try {
      await _encryptedStorage.read(key: _privateKeyK);
      _storage = const _SecureStore(_encryptedStorage); // encrypted works → keep it
    } catch (_) {
      // Keystore unavailable — migrate any existing key to plain storage,
      // then use plain storage for the remainder of this session.
      try {
        final existing = await _plainStorage.read(key: _privateKeyK);
        if (existing == null) {
          // No migrated key yet — nothing to copy; generate fresh below.
        }
      } catch (_) {/* ignore */}
      _storage = const _SecureStore(_plainStorage);
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // INITIALISE — idempotent, safe to call multiple times
  // ══════════════════════════════════════════════════════════════════════════
  static Future<void> initialise() async {
    await _resolveStorage();
    final existing = await _storage.read(key: _privateKeyK);
    if (existing != null) return;
    await _generateAndStore();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // KEY GENERATION — Ed25519 via cryptography package
  // ══════════════════════════════════════════════════════════════════════════
  static Future<void> _generateAndStore() async {
    // Generate keypair using cryptography package
    final keyPair = await _algorithm.newKeyPair();

    // Extract private key seed bytes
    final privateKeyBytes = await keyPair.extractPrivateKeyBytes();
    final privateKeyHex   = _bytesToHex(Uint8List.fromList(privateKeyBytes));

    // Extract public key bytes
    final publicKey      = await keyPair.extractPublicKey();
    final publicKeyBytes = publicKey.bytes;
    final publicKeyHex   = _bytesToHex(Uint8List.fromList(publicKeyBytes));

    // Sovereign ID = AS-YYYY-XXXXXX where XXXXXX = first 3 bytes of public key hex
    final year        = DateTime.now().year;
    final idSuffix    = publicKeyHex.substring(0, 6).toUpperCase();
    final sovereignId = 'AS-$year-$idSuffix';

    // Public material is safe to persist anywhere; the secret is not.
    await _storage.write(key: _publicKeyK,   value: publicKeyHex);
    await _storage.write(key: _sovereignIdK, value: sovereignId);
    await _storage.write(key: _nonceK,       value: '0');
    await _persistPrivateKey(privateKeyHex);
  }

  // ══════════════════════════════════════════════════════════════════════════
  // PERSIST THE PRIVATE KEY — the single place that decides where a secret lands.
  //
  // Everywhere except Linux it goes into OS-backed secure storage, as before.
  // On Linux there is nowhere safe to put it in the clear, so it is held in
  // memory and [hasUnsavedKey] becomes true: the UI must collect a PIN and call
  // enableSpendLock(), which writes it as an Argon2id-encrypted blob.
  //
  // Until that happens the wallet works for this session but is NOT on disk.
  // That is the honest state, and far better than a private key quietly written
  // in plain text because a prompt was inconvenient.
  // ══════════════════════════════════════════════════════════════════════════
  /// The private key, for writing an ENCRYPTED backup bundle and nothing else.
  ///
  /// This exists because the backup screen used to read secure storage
  /// directly, which no longer finds anything on Linux — the key is either a
  /// PIN-encrypted blob or held in memory. Reading straight from storage there
  /// would produce a backup with no key in it: a file that looks like a backup,
  /// restores cleanly, and leaves the citizen with no wallet.
  ///
  /// Returns null when the wallet is locked, so the caller must unlock first
  /// rather than write an empty bundle.
  static Future<String?> exportPrivateKeyForBackup() => _getPrivateKey();

  static Future<void> _persistPrivateKey(String privateKeyHex) async {
    if (requiresPinToPersist) {
      _pendingPrivateKeyHex = privateKeyHex;
      return;
    }
    await _storage.write(key: _privateKeyK, value: privateKeyHex);
  }

  // ══════════════════════════════════════════════════════════════════════════
  // GETTERS
  // ══════════════════════════════════════════════════════════════════════════
  static Future<String?> getPublicKey()   async =>
      _storage.read(key: _publicKeyK);

  static Future<String?> getSovereignId() async =>
      _storage.read(key: _sovereignIdK);

  static Future<String?> _getPrivateKey() async {
    // FAIL CLOSED when EITHER lock is ON: the key is available ONLY via an unlocked
    // in-memory session — Spend-Lock (PIN → Argon2id) or Hardware-Lock (TPM unseal).
    // We must NOT fall back to a plaintext copy even if one lingers (e.g. a delete
    // that didn't persist) — otherwise a locked wallet could still sign.
    if (await isSpendLockEnabled() || await isHardwareLockEnabled()) {
      return isSessionUnlocked ? _sessionKeyHex : null;
    }
    // Legacy / lock-off wallets keep the key in the clear — return it.
    // On Linux there is no plaintext on disk by design, so a key that has not
    // been PIN-saved yet lives only in memory for this session.
    if (_pendingPrivateKeyHex != null) return _pendingPrivateKeyHex;
    return _storage.read(key: _privateKeyK);
  }

  // ══════════════════════════════════════════════════════════════════════════
  // SPEND-LOCK — PIN-encrypted key at rest + bounded in-memory session
  // ══════════════════════════════════════════════════════════════════════════
  static bool get isSessionUnlocked =>
      _sessionKeyHex != null &&
      _sessionExpiry != null &&
      DateTime.now().isBefore(_sessionExpiry!);

  static Future<bool> isSpendLockEnabled() async =>
      (await SharedPreferences.getInstance()).getBool(_spendLockPref) ?? false;

  static List<int> _randomBytes(int n) {
    final r = math.Random.secure();
    return List<int>.generate(n, (_) => r.nextInt(256));
  }

  static Future<List<int>> _deriveKey(String pin, List<int> salt) async {
    final argon = sov_crypto.Argon2id(
      memory: _argonMemKiB,
      parallelism: _argonParallelism,
      iterations: _argonIterations,
      hashLength: 32,
    );
    final sk = await argon.deriveKey(
      secretKey: sov_crypto.SecretKey(utf8.encode(pin)),
      nonce: salt,
    );
    return sk.extractBytes();
  }

  static Future<String> _encryptPriv(String privHex, String pin) async {
    final salt  = _randomBytes(16);
    final aes   = sov_crypto.AesGcm.with256bits();
    final key   = sov_crypto.SecretKey(await _deriveKey(pin, salt));
    final nonce = aes.newNonce();
    final box   = await aes.encrypt(utf8.encode(privHex), secretKey: key, nonce: nonce);
    final ctMac = <int>[...box.cipherText, ...box.mac.bytes];
    return '${_bytesToHex(Uint8List.fromList(salt))}:'
           '${_bytesToHex(Uint8List.fromList(nonce))}:'
           '${_bytesToHex(Uint8List.fromList(ctMac))}';
  }

  /// Returns the decrypted private key hex, or null on wrong PIN (MAC fails).
  static Future<String?> _decryptPriv(String blob, String pin) async {
    try {
      final parts = blob.split(':');
      if (parts.length != 3) return null;
      final salt  = _hexToBytes(parts[0]);
      final nonce = _hexToBytes(parts[1]);
      final ctMac = _hexToBytes(parts[2]);
      final ct    = ctMac.sublist(0, ctMac.length - 16);
      final mac   = sov_crypto.Mac(ctMac.sublist(ctMac.length - 16));
      final aes   = sov_crypto.AesGcm.with256bits();
      final key   = sov_crypto.SecretKey(await _deriveKey(pin, salt));
      final clear = await aes.decrypt(
          sov_crypto.SecretBox(ct, nonce: nonce, mac: mac), secretKey: key);
      return utf8.decode(clear);
    } catch (_) {
      return null; // wrong PIN / corrupt blob
    }
  }

  /// Turn Spend-Lock ON: encrypt the current key with [pin], delete the plaintext.
  /// The seed phrase still restores the wallet, so this is safe. No-op if already on.
  static Future<bool> enableSpendLock(String pin) async {
    if (pin.isEmpty) return false;
    // On Linux the key was never written to disk, so the in-memory copy is the
    // only source — this call is what finally persists the wallet there.
    final priv = _pendingPrivateKeyHex ?? await _storage.read(key: _privateKeyK);
    if (priv == null) {
      // Already locked (no plaintext) — treat as success only if a blob exists.
      final blob = await _storage.read(key: _encPrivateKeyK);
      return blob != null;
    }
    final blob = await _encryptPriv(priv, pin);
    // Verify we can decrypt it back BEFORE deleting the plaintext (never brick a wallet).
    final check = await _decryptPriv(blob, pin);
    if (check != priv) return false;
    await _storage.write(key: _encPrivateKeyK, value: blob);
    // Only meaningful off-Linux; on Linux there was never a plaintext entry.
    await _storage.delete(key: _privateKeyK);
    await (await SharedPreferences.getInstance()).setBool(_spendLockPref, true);
    // The key is safely on disk as ciphertext now, so drop the memory-only copy.
    _pendingPrivateKeyHex = null;
    return true;
  }

  /// Turn Spend-Lock OFF: decrypt with [pin], restore the plaintext key.
  static Future<bool> disableSpendLock(String pin) async {
    // Turning Spend-Lock off means keeping the key in the clear, and on Linux
    // there is no safe place for that — the store would refuse the write and
    // the wallet would be left with neither a blob nor a key. Refuse up front
    // instead of failing halfway through.
    if (requiresPinToPersist) return false;
    final blob = await _storage.read(key: _encPrivateKeyK);
    if (blob == null) {
      await (await SharedPreferences.getInstance()).setBool(_spendLockPref, false);
      return true;
    }
    final priv = await _decryptPriv(blob, pin);
    if (priv == null) return false; // wrong PIN
    await _storage.write(key: _privateKeyK, value: priv);
    await _storage.delete(key: _encPrivateKeyK);
    await (await SharedPreferences.getInstance()).setBool(_spendLockPref, false);
    lockSession();
    return true;
  }

  /// Unlock the wallet for a bounded window (Bitcoin `walletpassphrase` model).
  /// Automation calls this ONCE; signing then works with no per-transfer PIN.
  static Future<bool> unlockSession(String pin,
      {Duration ttl = const Duration(minutes: 15)}) async {
    final blob = await _storage.read(key: _encPrivateKeyK);
    if (blob == null) {
      // No encrypted blob. Only "unlocked" if Spend-Lock is actually OFF; if it's
      // ON but the blob is missing/unreadable, FAIL CLOSED (never treat as unlocked).
      return !(await isSpendLockEnabled());
    }
    final priv = await _decryptPriv(blob, pin);
    if (priv == null) return false; // wrong PIN — MAC failed
    _sessionKeyHex = priv;
    _sessionExpiry = DateTime.now().add(ttl);
    return true;
  }

  static void lockSession() {
    _sessionKeyHex = null;
    _sessionExpiry = null;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // HARDWARE-LOCK (Tier A) — TPM-sealed key at rest (Windows)
  // The Ed25519 seed is sealed with a NON-EXPORTABLE key held in the TPM
  // ("Microsoft Platform Crypto Provider"). A copied blob is useless on any
  // other machine — only THIS TPM can unseal it. Stronger than DPAPI/Spend-Lock
  // (hardware root of trust, no PIN to brute-force). Opt-in, default OFF.
  // Recovery: the SEED PHRASE always restores the wallet — TPM sealing is a
  // local at-rest hardening, never the root of custody, so a dead TPM ≠ lost funds.
  // ══════════════════════════════════════════════════════════════════════════
  static const _hwSealedKeyK = 'sov_hw_sealed_v1';   // "HWSEALv1:<base64 RSA-OAEP blob>"
  static const _hwLockPref   = 'hardware_lock_enabled';
  static const _hwHelloPref  = 'hardware_lock_hello';   // A2: per-unlock Windows Hello
  // TPM keys: 'SOV_Wallet_TPM_v1' (plain) / 'SOV_Wallet_TPM_Hello_v1' (Hello-gated).

  static Future<bool> isHardwareLockEnabled() async =>
      (await SharedPreferences.getInstance()).getBool(_hwLockPref) ?? false;

  /// A2: whether the sealed key is guarded by a per-unlock Windows Hello prompt.
  static Future<bool> isHardwareLockHello() async =>
      (await SharedPreferences.getInstance()).getBool(_hwHelloPref) ?? false;

  // macOS Secure Enclave bridge (native handler in MainFlutterWindow.swift).
  static const MethodChannel _seChannel =
      MethodChannel('network.sov.node/secure_enclave');

  /// True only if this platform has a working secure element for sealing —
  /// Windows TPM (CNG) or macOS Secure Enclave.
  static Future<bool> isHardwareLockAvailable() async {
    if (Platform.isWindows) {
      final r = await _psRun(_kTpmProbePs);
      return r.$1 == 0 && r.$2.startsWith('OK');
    }
    if (Platform.isMacOS) {
      try {
        final r = await _seChannel.invokeMethod<String>('probe');
        return (r ?? '').startsWith('OK');
      } catch (_) { return false; }
    }
    return false;
  }

  /// The element backing the key: "Microsoft Platform Crypto Provider" (TPM),
  /// "...Software Key Storage Provider" (Windows fallback), or "Secure Enclave".
  static Future<String> hardwareBackingProvider() async {
    if (Platform.isWindows) {
      final r = await _psRun(_kTpmProbePs);
      if (r.$1 != 0 || !r.$2.startsWith('OK')) return 'none';
      return r.$2.substring(3).trim();
    }
    if (Platform.isMacOS) {
      try {
        final r = await _seChannel.invokeMethod<String>('probe');
        if ((r ?? '').startsWith('OK')) return r!.substring(3).trim();
      } catch (_) {}
      return 'none';
    }
    return 'none';
  }

  /// Turn Hardware-Lock ON: seal the current seed with the TPM, delete the
  /// plaintext. Verifies unseal round-trips BEFORE deleting — never bricks a wallet.
  /// [requireHello] (A2): seal with a CngUIPolicy key so unsealing prompts for
  /// Windows Hello every session. That path is INTERACTIVE — enable it from the
  /// GUI (or an interactive terminal) so the initial verify prompt can be answered.
  static Future<bool> enableHardwareLock({bool requireHello = false}) async {
    if (!Platform.isWindows && !Platform.isMacOS) return false;
    if (await isSpendLockEnabled()) return false; // mutually exclusive — disable Spend-Lock first
    final seed = await _storage.read(key: _privateKeyK);
    if (seed == null) {
      return (await _storage.read(key: _hwSealedKeyK)) != null; // already sealed
    }
    final sealed = await _hwSeal(seed, hello: requireHello);
    if (sealed == null) return false;
    if (await _hwUnseal(sealed, hello: requireHello) != seed) return false; // verify round-trip
    await _storage.write(key: _hwSealedKeyK, value: 'HWSEALv1:$sealed');
    await _storage.delete(key: _privateKeyK);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_hwLockPref, true);
    await prefs.setBool(_hwHelloPref, requireHello);
    return true;
  }

  /// Turn Hardware-Lock OFF: unseal via the TPM, restore the plaintext seed.
  static Future<bool> disableHardwareLock() async {
    final blob = await _storage.read(key: _hwSealedKeyK);
    if (blob == null) {
      await (await SharedPreferences.getInstance()).setBool(_hwLockPref, false);
      return true;
    }
    final seed = await _hwUnseal(_stripHwPrefix(blob), hello: await isHardwareLockHello());
    if (seed == null) return false; // element unavailable / wrong machine — keep sealed
    await _storage.write(key: _privateKeyK, value: seed);
    await _storage.delete(key: _hwSealedKeyK);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_hwLockPref, false);
    await prefs.setBool(_hwHelloPref, false);
    lockSession();
    return true;
  }

  /// Unseal the wallet for a bounded window (same session model as Spend-Lock).
  /// Automation/GUI calls this ONCE; signing then works with no per-op prompt.
  /// FAIL CLOSED: a missing/undecryptable blob never yields an unlocked session.
  static Future<bool> unlockHardwareSession(
      {Duration ttl = const Duration(hours: 12)}) async {
    final blob = await _storage.read(key: _hwSealedKeyK);
    if (blob == null) return !(await isHardwareLockEnabled());
    final seed = await _hwUnseal(_stripHwPrefix(blob), hello: await isHardwareLockHello());
    if (seed == null) return false; // element refused / prompt cancelled / wrong machine
    _sessionKeyHex = seed;
    _sessionExpiry = DateTime.now().add(ttl);
    return true;
  }

  static String _stripHwPrefix(String v) =>
      v.startsWith('HWSEALv1:') ? v.substring('HWSEALv1:'.length) : v;

  // ── Platform-dispatching seal/unseal (Windows TPM / macOS Secure Enclave) ───
  static Future<String?> _hwSeal(String seedHex, {bool hello = false}) async {
    if (Platform.isWindows) return _tpmSeal(seedHex, hello: hello);
    if (Platform.isMacOS) {
      try {
        return await _seChannel.invokeMethod<String>('seal', {'seedHex': seedHex, 'hello': hello});
      } catch (_) { return null; }
    }
    return null;
  }

  static Future<String?> _hwUnseal(String blobB64, {bool hello = false}) async {
    if (Platform.isWindows) return _tpmUnseal(blobB64, hello: hello);
    if (Platform.isMacOS) {
      try {
        final r = await _seChannel.invokeMethod<String>('unseal', {'blob': blobB64, 'hello': hello});
        if (r != null && RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(r)) return r.toLowerCase();
        return null;
      } catch (_) { return null; }
    }
    return null;
  }

  // ── TPM helpers (Windows CNG via PowerShell — no native plugin needed) ──────
  // [hello]=true uses a key created with CngUIPolicy(ProtectKey) so the OS demands
  // Windows Hello on EVERY unseal (A2 — per-unlock biometric). Those ops are
  // INTERACTIVE and get a long, timeout-guarded window so a missing prompt fails
  // SAFE (nothing changes) rather than hanging the wallet.
  static Future<String?> _tpmSeal(String seedHex, {bool hello = false}) async {
    final r = await _psRun(_tpmScript('seal', hello), input: seedHex,
        interactive: hello,
        timeout: Duration(seconds: hello ? 120 : 25));
    if (r.$1 != 0 || r.$2.isEmpty) return null;
    return r.$2;
  }

  static Future<String?> _tpmUnseal(String blobB64, {bool hello = false}) async {
    final r = await _psRun(_tpmScript('unseal', hello), input: blobB64,
        interactive: hello,
        timeout: Duration(seconds: hello ? 120 : 25));
    if (r.$1 != 0 || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(r.$2)) return null;
    return r.$2.toLowerCase();
  }

  /// Run a PowerShell script (base64 UTF16-LE encoded, so no quoting issues),
  /// optionally piping [input] over STDIN. Returns (exitCode, stdout, stderr).
  static Future<(int, String, String)> _psRun(String script,
      {String? input,
       Duration timeout = const Duration(seconds: 25),
       bool interactive = false}) async {
    // -NonInteractive is dropped for Hello ops so the Windows credential prompt
    // can surface. Every call is timeout-guarded: if a prompt never appears the
    // process is killed and we return -1 (fail-safe), never an infinite hang.
    final args = <String>['-NoProfile'];
    if (!interactive) args.add('-NonInteractive');
    args.addAll(['-EncodedCommand', _psEncode(script)]);
    final proc = await Process.start('powershell', args);
    if (input != null) proc.stdin.write(input);
    await proc.stdin.close();
    final outF = proc.stdout.transform(const Utf8Decoder(allowMalformed: true)).join();
    final errF = proc.stderr.transform(const Utf8Decoder(allowMalformed: true)).join();
    final code = await proc.exitCode
        .timeout(timeout, onTimeout: () { proc.kill(); return -1; });
    final out = await outF;
    final err = await errF;
    return (code, out.trim(), err.trim());
  }

  static String _psEncode(String script) {
    final bytes = <int>[];
    for (final u in script.codeUnits) { bytes.add(u & 0xff); bytes.add((u >> 8) & 0xff); }
    return base64.encode(bytes);
  }

  // PowerShell that opens/creates the SOV TPM key and prints "OK <provider>".
  static const String _kTpmProbePs = r'''
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Security
$name='SOV_Wallet_TPM_v1'
$provs=@('Microsoft Platform Crypto Provider','Microsoft Software Key Storage Provider')
foreach($pn in $provs){
  try{
    $prov=New-Object System.Security.Cryptography.CngProvider($pn)
    if([System.Security.Cryptography.CngKey]::Exists($name,$prov)){ Write-Output ('OK '+$pn); exit 0 }
    $cp=New-Object System.Security.Cryptography.CngKeyCreationParameters
    $cp.Provider=$prov
    $cp.ExportPolicy=[System.Security.Cryptography.CngExportPolicies]::None
    $cp.Parameters.Add((New-Object System.Security.Cryptography.CngProperty('Length',[BitConverter]::GetBytes([int]2048),[System.Security.Cryptography.CngPropertyOptions]::None)))
    $k=[System.Security.Cryptography.CngKey]::Create([System.Security.Cryptography.CngAlgorithm]::Rsa,$name,$cp)
    Write-Output ('OK '+$pn); exit 0
  } catch {}
}
Write-Output 'NO'; exit 1
''';

  // Build the seal/unseal PowerShell for either the plain key (SOV_Wallet_TPM_v1)
  // or the Hello-gated key (SOV_Wallet_TPM_Hello_v1, created with a CngUIPolicy
  // ProtectKey so the TPM demands Windows Hello on every private-key use).
  static String _tpmScript(String op, bool hello) {
    final name = hello ? 'SOV_Wallet_TPM_Hello_v1' : 'SOV_Wallet_TPM_v1';
    final uiPolicy = hello
        ? r"$cp.UIPolicy=New-Object System.Security.Cryptography.CngUIPolicy([System.Security.Cryptography.CngUIProtectionLevels]::ProtectKey,'SOV Wallet','Approve SOV wallet unlock');"
        : '';
    if (op == 'seal') {
      return '''
\$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Security
\$name='$name'
\$provs=@('Microsoft Platform Crypto Provider','Microsoft Software Key Storage Provider')
\$k=\$null
foreach(\$pn in \$provs){
  try{
    \$prov=New-Object System.Security.Cryptography.CngProvider(\$pn)
    if([System.Security.Cryptography.CngKey]::Exists(\$name,\$prov)){ \$k=[System.Security.Cryptography.CngKey]::Open(\$name,\$prov); break }
    \$cp=New-Object System.Security.Cryptography.CngKeyCreationParameters
    \$cp.Provider=\$prov
    \$cp.ExportPolicy=[System.Security.Cryptography.CngExportPolicies]::None
    $uiPolicy
    \$cp.Parameters.Add((New-Object System.Security.Cryptography.CngProperty('Length',[BitConverter]::GetBytes([int]2048),[System.Security.Cryptography.CngPropertyOptions]::None)))
    \$k=[System.Security.Cryptography.CngKey]::Create([System.Security.Cryptography.CngAlgorithm]::Rsa,\$name,\$cp); break
  } catch {}
}
if(\$k -eq \$null){ Write-Error 'no provider'; exit 1 }
\$hex=[Console]::In.ReadToEnd().Trim()
\$seed=New-Object byte[] (\$hex.Length/2)
for(\$i=0;\$i -lt \$seed.Length;\$i++){ \$seed[\$i]=[Convert]::ToByte(\$hex.Substring(\$i*2,2),16) }
\$rsa=New-Object System.Security.Cryptography.RSACng(\$k)
\$blob=\$rsa.Encrypt(\$seed,[System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA256)
[Convert]::ToBase64String(\$blob)
''';
    }
    // unseal
    return '''
\$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Security
\$name='$name'
\$provs=@('Microsoft Platform Crypto Provider','Microsoft Software Key Storage Provider')
\$k=\$null
foreach(\$pn in \$provs){
  try{ \$prov=New-Object System.Security.Cryptography.CngProvider(\$pn)
    if([System.Security.Cryptography.CngKey]::Exists(\$name,\$prov)){ \$k=[System.Security.Cryptography.CngKey]::Open(\$name,\$prov); break } }catch{}
}
if(\$k -eq \$null){ Write-Error 'no key'; exit 1 }
\$b64=[Console]::In.ReadToEnd().Trim()
\$blob=[Convert]::FromBase64String(\$b64)
\$rsa=New-Object System.Security.Cryptography.RSACng(\$k)
\$seed=\$rsa.Decrypt(\$blob,[System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA256)
(\$seed | ForEach-Object { \$_.ToString('x2') }) -join ''
''';
  }

  // ══════════════════════════════════════════════════════════════════════════
  // NONCE — monotonically increasing counter for replay protection
  // ══════════════════════════════════════════════════════════════════════════
  static Future<int> _nextNonce() async {
    final raw   = await _storage.read(key: _nonceK) ?? '0';
    final nonce = int.parse(raw) + 1;
    await _storage.write(key: _nonceK, value: nonce.toString());
    return nonce;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // SIGN MESSAGE — called by RelayConnector.send() for every outgoing message
  //
  // Signs: SHA-256(sovereign_id + nonce + timestamp + type + payload_hash)
  // Returns: { nonce, signature_hex }
  // ══════════════════════════════════════════════════════════════════════════
  static Future<Map<String, dynamic>> signMessage(
      Map<String, dynamic> message) async {
    final privateKeyHex = await _getPrivateKey();
    final sovereignId   = await getSovereignId();
    if (privateKeyHex == null || sovereignId == null) {
      throw Exception('KeyManager not initialised');
    }

    final nonce     = await _nextNonce();
    final timestamp = message['timestamp'] as int? ??
        DateTime.now().millisecondsSinceEpoch;
    final type      = message['type'] as String? ?? '';

    // Build canonical signing input
    final payloadHash = sha256
        .convert(utf8.encode(jsonEncode(message)))
        .toString();
    final signingInput =
        '$sovereignId|$nonce|$timestamp|$type|$payloadHash';

    final signature = await _sign(privateKeyHex, signingInput);

    return {
      'nonce':     nonce,
      'signature': signature,
    };
  }

  // ══════════════════════════════════════════════════════════════════════════
  // SIGN CHALLENGE — for auth challenge-response
  // ══════════════════════════════════════════════════════════════════════════
  static Future<String> signChallenge(String challenge) async {
    final privateKeyHex = await _getPrivateKey();
    if (privateKeyHex == null) throw Exception('Node not initialised');
    return _sign(privateKeyHex, challenge);
  }

  // ══════════════════════════════════════════════════════════════════════════
  // INTERNAL SIGN — Ed25519 sign any string with private key
  // ══════════════════════════════════════════════════════════════════════════
  static Future<String> _sign(
      String privateKeyHex, String message) async {
    final seedBytes = _hexToBytes(privateKeyHex);
    final keyPair   = await _algorithm.newKeyPairFromSeed(seedBytes);
    final signature = await _algorithm.sign(
      utf8.encode(message),
      keyPair: keyPair,
    );
    return _bytesToHex(Uint8List.fromList(signature.bytes));
  }

  // ══════════════════════════════════════════════════════════════════════════
  // VERIFY SIGNATURE — used by NodeWitness to verify incoming messages
  // ══════════════════════════════════════════════════════════════════════════
  static Future<bool> verifySignature({
    required String publicKeyHex,
    required String message,
    required String signatureHex,
  }) async {
    try {
      final pubKeyBytes = _hexToBytes(publicKeyHex);
      final sigBytes    = _hexToBytes(signatureHex);
      final msgBytes    = utf8.encode(message);

      final publicKey = sov_crypto.SimplePublicKey(
        pubKeyBytes,
        type: sov_crypto.KeyPairType.ed25519,
      );
      final signature = sov_crypto.Signature(
        sigBytes,
        publicKey: publicKey,
      );
      return await _algorithm.verify(msgBytes, signature: signature);
    } catch (_) {
      return false;
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // STORE RESTORED KEYS — called by 12-word seed recovery
  // Derives the Ed25519 public key from the provided seed hex, then writes
  // all four secure-storage values so the wallet can sign transactions.
  // privateKeyHex: 64-char hex of the 32-byte Ed25519 seed
  // sovereignId:   'SOV-XXXX' as derived from the BIP39 mnemonic
  // ══════════════════════════════════════════════════════════════════════════
  static Future<void> storeRestoredKeys({
    required String privateKeyHex,
    required String sovereignId,
  }) async {
    await _resolveStorage();
    final seedBytes = _hexToBytes(privateKeyHex);
    final keyPair   = await _algorithm.newKeyPairFromSeed(seedBytes);
    final publicKey = await keyPair.extractPublicKey();
    final publicKeyHex = _bytesToHex(Uint8List.fromList(publicKey.bytes));

    // Public material is safe to persist anywhere; the secret is not.
    await _storage.write(key: _publicKeyK,   value: publicKeyHex);
    await _storage.write(key: _sovereignIdK, value: sovereignId);
    await _storage.write(key: _nonceK,       value: '0');
    await _persistPrivateKey(privateKeyHex);
  }

  // ══════════════════════════════════════════════════════════════════════════
  // KEY ROTATION — called during wallet recovery
  // ══════════════════════════════════════════════════════════════════════════
  static Future<void> rotateKeys() async {
    await _storage.delete(key: _privateKeyK);
    await _storage.delete(key: _publicKeyK);
    await _storage.write(key: _nonceK, value: '0');
    await _generateAndStore();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // WIPE — full reset. Covers every secure-storage key this class writes,
  // including Spend-Lock and Hardware-Lock, so a device reset never leaves a
  // stray encrypted/sealed blob behind that could resurrect the old identity.
  // ══════════════════════════════════════════════════════════════════════════
  static Future<void> wipeKeys() async {
    await _storage.delete(key: _privateKeyK);
    await _storage.delete(key: _publicKeyK);
    await _storage.delete(key: _sovereignIdK);
    await _storage.delete(key: _nonceK);
    await _storage.delete(key: _encPrivateKeyK);
    await _storage.delete(key: _hwSealedKeyK);
    _sessionKeyHex = null;
    _sessionExpiry = null;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // UTILITIES
  // ══════════════════════════════════════════════════════════════════════════
  static String _bytesToHex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List _hexToBytes(String hex) {
    final result = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < hex.length; i += 2) {
      result[i ~/ 2] = int.parse(hex.substring(i, i + 2), radix: 16);
    }
    return result;
  }
}
