// lib/screens/backup_restore_screen.dart — S11: Backup & Restore
// Encrypted local backup: Argon2id KDF + AES-256-GCM authenticated encryption
// File format: plain JSON text (.sovbak) — safe for all Android file sharing
// {"format":"SOVBAK2","kdf":"argon2id","p":1,"m":65536,"t":3,
//  "salt":"<b64>","nonce":"<b64>","data":"<b64 ciphertext+tag>"}
// Bundle (plaintext): JSON { version, sovereign_id, created_at, keys{}, prefs{}, contacts_db_b64 }
// Security: Argon2id(64MB,3 iter) = ~3s/guess on GPU farm → uncrackable with 10+ char password

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as sov_crypto;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../sov_node_sdk/contacts_db.dart';
import '../sov_node_sdk/sov_db_path.dart';
import '../sov_node_sdk/key_manager.dart';
import '../sov_node_sdk/relay_connector.dart';
import '../widgets/linux_pin_setup.dart';
import 'main_shell.dart';

class BackupRestoreScreen extends StatefulWidget {
  final String sovereignId;
  /// When true: launched from the RecoveryScreen on a fresh install.
  /// Hides the "Create Backup" section and navigates to MainShell after restore.
  final bool restoreOnly;
  const BackupRestoreScreen({
    super.key,
    required this.sovereignId,
    this.restoreOnly = false,
  });

  @override
  State<BackupRestoreScreen> createState() => _BackupRestoreScreenState();
}

class _BackupRestoreScreenState extends State<BackupRestoreScreen> {
  static const _navy   = Color(0xFF0A1628);
  static const _gold   = Color(0xFFB8960C);
  static const _cardBg = Color(0xFF0D1F3A);
  static const _teal   = Color(0xFF00BFA5);

  // Encrypted secure storage (matches KeyManager)
  static const _encStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  // Fallback plain secure storage (matches KeyManager fallback)
  static const _plainStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: false),
  );

  // All secure storage keys — must match KeyManager + MessageKeyManager constants
  static const _secureKeys = [
    'sov_private_key_v2',       // Ed25519 signing private key
    'sov_public_key_v2',        // Ed25519 signing public key
    'sov_sovereign_id_v2',      // Sovereign ID (source of truth)
    'sov_nonce_v2',             // Replay-prevention nonce counter
    'sov_msg_private_key_v1',   // X25519 messaging private key (E2E)
    'sov_msg_public_key_v1',    // X25519 messaging public key (E2E)
  ];

  // SharedPreferences keys to skip on restore (session state, not identity)
  static const _skipPrefsOnRestore = {
    '_ext_activity_ts',
    'pending_db_restore',
    'pending_db_restore_path',
  };

  static const _magic = 'SOVBAK2';

  bool _creatingBackup  = false;
  bool _restoringBackup = false;

  // ── Helpers ───────────────────────────────────────────────────────────────

  void _snack(String msg, {Color bg = const Color(0xFF0D1F3A)}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: bg,
      behavior: SnackBarBehavior.floating,
    ));
  }

  InputDecoration _inputDeco(String hint) => InputDecoration(
    hintText: hint,
    hintStyle: const TextStyle(color: Colors.white38),
    filled: true,
    fillColor: const Color(0xFF0A1628),
    border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Colors.white12)),
    enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Colors.white12)),
    focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: _gold)),
  );

  // ── Cryptography ──────────────────────────────────────────────────────────

  static List<int> _randomBytes(int count) =>
      List<int>.generate(count, (_) => Random.secure().nextInt(256));

  // ── Argon2id key derivation ───────────────────────────────────────────────
  // memory=65536 KB (64 MB) — each password guess requires 64 MB of RAM.
  // Parallelism=1 prevents GPU parallelism. iterations=3 follows RFC 9106.
  // A GPU farm can try ~2 guesses/second — a 10-char password takes
  // millions of years to crack.
  static Future<sov_crypto.SecretKey> _deriveKey(
      String password, List<int> salt, {int p = 1, int m = 65536, int t = 3}) {
    return sov_crypto.Argon2id(
      parallelism: p,
      memory:      m,
      iterations:  t,
      hashLength:  32,   // 256-bit AES key
    ).deriveKey(
      secretKey: sov_crypto.SecretKey(utf8.encode(password)),
      nonce:     salt,
    );
  }

  // ── Encrypt → JSON string (text-safe, works on all Android file sharing) ─
  // Returns: JSON { format, kdf, p, m, t, salt, nonce, data }
  // data = base64(ciphertext + 16-byte GCM auth tag)
  static Future<String> _encrypt(List<int> plaintext, String password) async {
    const p = 1, m = 65536, t = 3;
    final salt  = _randomBytes(16);
    final nonce = _randomBytes(12);
    final key   = await _deriveKey(password, salt, p: p, m: m, t: t);
    final box   = await sov_crypto.AesGcm.with256bits()
        .encrypt(plaintext, secretKey: key, nonce: nonce);
    // Store ciphertext + GCM tag together as single base64 blob
    final data  = Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
    return jsonEncode({
      'format': _magic,       // 'SOVBAK2'
      'kdf':    'argon2id',
      'p':      p,
      'm':      m,
      't':      t,
      'salt':   base64.encode(salt),
      'nonce':  base64.encode(nonce),
      'data':   base64.encode(data),
    });
  }

  // ── Decrypt JSON string → plaintext bytes ─────────────────────────────────
  // Throws SecretBoxAuthenticationError on wrong password.
  // Throws FormatException on corrupt / wrong file type.
  // Reads p/m/t from the file so future parameter upgrades stay readable.
  static Future<Uint8List> _decrypt(String jsonStr, String password) async {
    Map<String, dynamic> env;
    try {
      env = jsonDecode(jsonStr) as Map<String, dynamic>;
    } catch (_) {
      throw const FormatException('Not a valid SOV backup file');
    }
    if (env['format'] != _magic) {
      throw const FormatException(
          'Unsupported backup format — please use the SOV app to restore');
    }
    final salt    = base64.decode(env['salt']  as String? ?? '');
    final nonce   = base64.decode(env['nonce'] as String? ?? '');
    final rawData = base64.decode(env['data']  as String? ?? '');
    if (rawData.length < 16) throw const FormatException('Corrupt backup data');
    final cipherText = rawData.sublist(0, rawData.length - 16);
    final macBytes   = rawData.sublist(rawData.length - 16);

    // Read parameters stored in the file (future-proof)
    final p = env['p'] as int? ?? 1;
    final m = env['m'] as int? ?? 65536;
    final t = env['t'] as int? ?? 3;

    final key = await _deriveKey(password, salt, p: p, m: m, t: t);
    final decrypted = await sov_crypto.AesGcm.with256bits().decrypt(
      sov_crypto.SecretBox(cipherText,
          nonce: nonce, mac: sov_crypto.Mac(macBytes)),
      secretKey: key,
    );
    return Uint8List.fromList(decrypted);
  }

  // ── Bundle collection ─────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _collectBundle() async {
    // 1. Secure storage — try encrypted then plain fallback for each key
    final keys = <String, String>{};
    for (final k in _secureKeys) {
      String? v;
      // Linux: never read the OS secret store here — flutter_secure_storage would
      // talk to libsecret and pop the GNOME "Unlock Login Keyring" dialog. The key
      // material lives in the on-disk file stores instead; pull it from the
      // managers below. See docs/LINUX_KEYRING_FIX.md.
      if (!Platform.isLinux) {
        try { v = await _encStorage.read(key: k); } catch (_) {}
        if (v == null) {
          try { v = await _plainStorage.read(key: k); } catch (_) {}
        }
      }
      // Fill from the managers when secure storage had nothing — always the case
      // on Linux, and the private key is never in secure storage there. Without
      // this a backup would contain no key: a file that looks like a backup and
      // restores into an empty wallet.
      if (v == null || v.isEmpty) {
        try {
          switch (k) {
            case 'sov_private_key_v2':
              v = await KeyManager.exportPrivateKeyForBackup();
              break;
            case 'sov_public_key_v2':
              v = await KeyManager.getPublicKey();
              break;
            case 'sov_sovereign_id_v2':
              v = await KeyManager.getSovereignId();
              break;
          }
        } catch (_) {}
      }
      if (v != null && v.isNotEmpty) keys[k] = v;
    }

    // 2. All SharedPreferences
    final prefs    = await SharedPreferences.getInstance();
    final prefsMap = <String, dynamic>{};
    for (final k in prefs.getKeys()) {
      prefsMap[k] = prefs.get(k);
    }

    // 3. contacts.db raw bytes → base64
    final dbDir  = await sovDatabasesDir();
    final dbFile = File('$dbDir/sov_contacts.db');
    String dbB64 = '';
    if (await dbFile.exists()) {
      dbB64 = base64.encode(await dbFile.readAsBytes());
    }

    return {
      'version':         1,
      'sovereign_id':    widget.sovereignId,
      'created_at':      DateTime.now().toIso8601String(),
      'keys':            keys,
      'prefs':           prefsMap,
      'contacts_db_b64': dbB64,
    };
  }

  // ── Create backup ─────────────────────────────────────────────────────────

  void _showCreateBackupSheet() {
    final pwd1 = TextEditingController();
    final pwd2 = TextEditingController();
    String? error;
    bool working = false;
    bool obs1 = true, obs2 = true;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _cardBg,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, ss) => Padding(
          padding: EdgeInsets.fromLTRB(
              24, 20, 24, 24 + MediaQuery.of(ctx).viewInsets.bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(child: Container(
                  width: 36, height: 4,
                  decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2)))),
              const SizedBox(height: 20),
              const Text('Create Encrypted Backup',
                  style: TextStyle(color: Colors.white,
                      fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text(
                'Choose a strong password to encrypt the backup. '
                'You will need this password to restore — it cannot be recovered.',
                style: TextStyle(color: Colors.white60, fontSize: 13, height: 1.5),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: pwd1,
                obscureText: obs1,
                style: const TextStyle(color: Colors.white),
                decoration: _inputDeco('Backup password (min 8 chars)').copyWith(
                  suffixIcon: IconButton(
                    icon: Icon(obs1 ? Icons.visibility_off : Icons.visibility,
                        color: Colors.white38, size: 18),
                    onPressed: () => ss(() => obs1 = !obs1),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: pwd2,
                obscureText: obs2,
                style: const TextStyle(color: Colors.white),
                decoration: _inputDeco('Confirm password').copyWith(
                  suffixIcon: IconButton(
                    icon: Icon(obs2 ? Icons.visibility_off : Icons.visibility,
                        color: Colors.white38, size: 18),
                    onPressed: () => ss(() => obs2 = !obs2),
                  ),
                ),
              ),
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(error!, style: const TextStyle(
                    color: Colors.redAccent, fontSize: 12)),
              ],
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _gold,
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: working ? null : () async {
                    final p1 = pwd1.text, p2 = pwd2.text;
                    if (p1.length < 8) {
                      ss(() => error = 'Password must be at least 8 characters');
                      return;
                    }
                    if (p1 != p2) {
                      ss(() => error = 'Passwords do not match');
                      return;
                    }
                    ss(() { error = null; working = true; });
                    final err = await _doCreateBackup(p1);
                    if (!ctx.mounted) return;
                    if (err == null) {
                      Navigator.pop(ctx);
                      _snack('Backup created', bg: _teal);
                    } else {
                      ss(() { error = err; working = false; });
                    }
                  },
                  child: working
                      ? const SizedBox(width: 20, height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.black))
                      : const Text('Create & Share',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<String?> _doCreateBackup(String password) async {
    try {
      setState(() => _creatingBackup = true);
      final bundle      = await _collectBundle();
      final plaintext   = utf8.encode(jsonEncode(bundle));
      // _encrypt returns JSON string — safe for all Android sharing methods
      final encryptedJson = await _encrypt(plaintext, password);

      final dir  = await getTemporaryDirectory();
      final date = DateTime.now().toIso8601String().substring(0, 10);
      final safe = widget.sovereignId.length > 12
          ? widget.sovereignId.substring(4, 12)
          : 'SOV';
      final file = File('${dir.path}/SOV_${safe}_$date.sovbak');
      // Write as UTF-8 text — no binary, no encoding corruption risk
      await file.writeAsString(encryptedJson, encoding: utf8);

      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'SOV Network Backup',
        text: 'Encrypted SOV identity backup — store safely.',
      );
      return null;
    } catch (e) {
      return 'Backup failed: $e';
    } finally {
      if (mounted) setState(() => _creatingBackup = false);
    }
  }

  // ── Restore from backup ───────────────────────────────────────────────────

  void _showRestoreSheet() {
    final pwdCtrl = TextEditingController();
    Uint8List? fileBytes;
    String?   fileName;
    String?   error;
    bool picking = false, working = false, obsP = true;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _cardBg,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, ss) => Padding(
          padding: EdgeInsets.fromLTRB(
              24, 20, 24, 24 + MediaQuery.of(ctx).viewInsets.bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(child: Container(
                  width: 36, height: 4,
                  decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2)))),
              const SizedBox(height: 20),
              const Text('Restore from Backup',
                  style: TextStyle(color: Colors.white,
                      fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              // Warning banner
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.orange.withAlpha(18),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.orange.withAlpha(60)),
                ),
                child: const Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.warning_amber_rounded,
                        color: Colors.orange, size: 16),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'This will replace your current identity and data. '
                        'The app must be restarted after restoring.',
                        style: TextStyle(
                            color: Colors.orange, fontSize: 12, height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // File picker row
              GestureDetector(
                onTap: (picking || working) ? null : () async {
                  ss(() => picking = true);
                  try {
                    RelayConnector.externalActivityOpen = true;
                    final result = await FilePicker.platform.pickFiles(
                      type: FileType.any,
                      withData: true,
                    );
                    RelayConnector.externalActivityOpen = false;
                    if (result != null && result.files.isNotEmpty) {
                      final f = result.files.first;
                      if (f.bytes != null) {
                        ss(() {
                          fileBytes = Uint8List.fromList(f.bytes!);
                          fileName  = f.name;
                          error     = null;
                        });
                      }
                    }
                  } catch (_) {
                    RelayConnector.externalActivityOpen = false;
                  } finally {
                    ss(() => picking = false);
                  }
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0A1628),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: fileBytes != null
                            ? _teal.withAlpha(120)
                            : Colors.white12),
                  ),
                  child: Row(children: [
                    Icon(
                      fileBytes != null
                          ? Icons.check_circle_rounded
                          : Icons.folder_open_rounded,
                      color: fileBytes != null ? _teal : Colors.white38,
                      size: 18,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        picking
                            ? 'Opening…'
                            : (fileName ?? 'Tap to choose .sovbak file'),
                        style: TextStyle(
                          color: fileBytes != null
                              ? Colors.white : Colors.white38,
                          fontSize: 13,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (picking)
                      const SizedBox(width: 16, height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 1.5, color: Colors.white38))
                    else
                      const Icon(Icons.chevron_right_rounded,
                          color: Colors.white24, size: 18),
                  ]),
                ),
              ),
              const SizedBox(height: 10),
              // Password field
              TextField(
                controller: pwdCtrl,
                obscureText: obsP,
                style: const TextStyle(color: Colors.white),
                decoration: _inputDeco('Backup password').copyWith(
                  suffixIcon: IconButton(
                    icon: Icon(obsP ? Icons.visibility_off : Icons.visibility,
                        color: Colors.white38, size: 18),
                    onPressed: () => ss(() => obsP = !obsP),
                  ),
                ),
              ),
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(error!, style: const TextStyle(
                    color: Colors.redAccent, fontSize: 12)),
              ],
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red.shade800,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: (working || fileBytes == null) ? null : () async {
                    final pwd = pwdCtrl.text;
                    if (pwd.isEmpty) {
                      ss(() => error = 'Enter the backup password');
                      return;
                    }
                    ss(() { error = null; working = true; });
                    final err = await _doRestore(fileBytes!, pwd);
                    if (!ctx.mounted) return;
                    if (err == null) {
                      Navigator.pop(ctx);
                      _showRestartDialog();
                    } else {
                      ss(() { error = err; working = false; });
                    }
                  },
                  child: working
                      ? const SizedBox(width: 20, height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Text('Restore Backup',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<String?> _doRestore(Uint8List fileBytes, String password) async {
    try {
      setState(() => _restoringBackup = true);

      // 1. Decode bytes as UTF-8 text, then decrypt JSON envelope
      Uint8List plaintext;
      try {
        final jsonStr = utf8.decode(fileBytes);
        plaintext = await _decrypt(jsonStr, password);
      } on sov_crypto.SecretBoxAuthenticationError {
        return 'Incorrect password or corrupt backup';
      } on FormatException catch (e) {
        return e.message;
      } catch (e) {
        final s = e.toString().toLowerCase();
        if (s.contains('authentication') || s.contains('mac') ||
            s.contains('secretbox')) {
          return 'Incorrect password or corrupt backup';
        }
        return 'Decryption failed: $e';
      }

      // 2. Parse bundle
      final Map<String, dynamic> bundle;
      try {
        bundle = jsonDecode(utf8.decode(plaintext)) as Map<String, dynamic>;
      } catch (_) {
        return 'Backup data is corrupt';
      }
      if ((bundle['version'] as int? ?? 0) != 1) {
        return 'Unsupported backup version';
      }

      // Extract the backed-up Sovereign ID early — used throughout restore
      final bundleSovId = (bundle['sovereign_id'] as String? ?? '').trim();

      // 3. Restore secure storage keys
      final keysMap = bundle['keys'] as Map<String, dynamic>? ?? {};
      // Skipped on Linux: these writes go to libsecret, which would prompt for
      // a keyring password SOV never set AND store the plaintext private key
      // there. KeyManager just below is the only writer on that platform.
      if (!Platform.isLinux) {
        for (final e in keysMap.entries) {
          final v = e.value as String? ?? '';
          if (v.isEmpty) continue;
          // Write to BOTH storages so the key is found regardless of which
          // backend _resolveStorage() picks on next launch (encrypted or plain).
          try { await _encStorage.write(key: e.key, value: v); } catch (_) {}
          try { await _plainStorage.write(key: e.key, value: v); } catch (_) {}
        }
      }

      // 3a. Re-bind the Sovereign ID to the private key via KeyManager.
      //     This overwrites sov_sovereign_id_v2 with the correct SOV-XXXXXXXX
      //     format and re-derives the matching public key from the seed.
      //     Without this, a device that previously called _generateAndStore()
      //     would leave AS-YYYY-XXXXXX in sov_sovereign_id_v2, causing every
      //     signed message to present the wrong identity to the relay.
      final privKeyHex = keysMap['sov_private_key_v2'] as String? ?? '';
      if (bundleSovId.isNotEmpty && privKeyHex.isNotEmpty) {
        await KeyManager.storeRestoredKeys(
          privateKeyHex: privKeyHex,
          sovereignId: bundleSovId,
        );
      }

      // 4. Restore SharedPreferences
      final prefs    = await SharedPreferences.getInstance();
      final prefsMap = bundle['prefs'] as Map<String, dynamic>? ?? {};
      for (final e in prefsMap.entries) {
        if (_skipPrefsOnRestore.contains(e.key)) continue;
        try {
          final v = e.value;
          if (v is bool) {
            await prefs.setBool(e.key, v);
          } else if (v is int) {
            await prefs.setInt(e.key, v);
          } else if (v is double) {
            await prefs.setDouble(e.key, v);
          } else if (v is String) {
            await prefs.setString(e.key, v);
          } else if (v is List) {
            await prefs.setStringList(
                e.key, v.map((x) => x.toString()).toList());
          }
        } catch (_) {/* skip incompatible key */}
      }

      // 4a. Explicitly lock in the identity after prefs restore.
      //     The backed-up prefs snapshot may have been written at any lifecycle
      //     point — we always overwrite these two with the bundle's source-of-
      //     truth value so the app always wakes up with the correct identity.
      if (bundleSovId.isNotEmpty) {
        await prefs.setString('sovereign_id', bundleSovId);
        await prefs.setBool('enrollment_complete', true);
      }

      // 5. Restore contacts.db — close singleton first, then overwrite file
      final dbB64 = bundle['contacts_db_b64'] as String? ?? '';
      if (dbB64.isNotEmpty) {
        await ContactsDb.closeDb();
        final dbDir  = await sovDatabasesDir();
        final dbFile = File('$dbDir/sov_contacts.db');
        await dbFile.writeAsBytes(base64.decode(dbB64), flush: true);
      }

      return null;
    } catch (e) {
      return 'Restore failed: $e';
    } finally {
      if (mounted) setState(() => _restoringBackup = false);
    }
  }

  void _showRestartDialog() {
    if (widget.restoreOnly) {
      // Launched from RecoveryScreen (fresh install) — navigate directly to the
      // app shell instead of asking the user to manually restart. All keys and
      // prefs are already written; MainShell will pick them up immediately.
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          backgroundColor: _cardBg,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Restore Complete',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          content: const Text(
            'Your identity and data have been restored successfully.',
            style: TextStyle(color: Colors.white60, fontSize: 14, height: 1.5),
          ),
          actions: [
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: _gold,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: () async {
                Navigator.pop(ctx); // close dialog
                if (!mounted) return;
                // Linux: the restored key is held in memory only until it is
                // PIN-encrypted — collect a PIN and persist it before entering
                // the wallet, else it is lost at next launch. No-op elsewhere.
                await ensureKeyPersistedOnLinux(context);
                if (!mounted) return;
                // Navigate to MainShell, clearing the entire back stack
                Navigator.of(context).pushAndRemoveUntil(
                  PageRouteBuilder(
                    pageBuilder: (_, __, ___) => const MainShell(),
                    transitionsBuilder: (_, anim, __, child) =>
                        FadeTransition(opacity: anim, child: child),
                    transitionDuration: const Duration(milliseconds: 500),
                  ),
                  (route) => false,
                );
              },
              child: const Text('Open My Wallet',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      );
      return;
    }

    // Normal mode (launched from Settings inside the app) — ask user to restart.
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: _cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Restore Complete',
            style: TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold)),
        content: const Text(
          'Your identity, keys, and data have been restored.\n\n'
          'Please close and reopen the app to finish — your restored '
          'wallet will be active on next launch.',
          style: TextStyle(color: Colors.white60, fontSize: 14, height: 1.5),
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _gold,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () {
              Navigator.pop(ctx);
              if (mounted) Navigator.pop(context);
            },
            child: const Text("OK, I'll restart",
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _navy,
      appBar: AppBar(
        backgroundColor: _navy,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Backup & Restore',
            style: TextStyle(
                color: _gold, fontWeight: FontWeight.bold, fontSize: 18)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
        children: [

          // ── Create backup card (hidden in restoreOnly mode) ────────────
          if (!widget.restoreOnly)
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: _cardBg,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _gold.withAlpha(35)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(children: [
                  Icon(Icons.cloud_upload_outlined, color: _gold, size: 22),
                  SizedBox(width: 10),
                  Text('Create Backup',
                      style: TextStyle(color: Colors.white,
                          fontSize: 16, fontWeight: FontWeight.bold)),
                ]),
                const SizedBox(height: 12),
                const Text(
                  'Creates an encrypted .sovbak file containing your full '
                  'sovereign identity — protected with AES-256-GCM and a '
                  'password-derived key.',
                  style: TextStyle(
                      color: Colors.white60, fontSize: 13, height: 1.5),
                ),
                const SizedBox(height: 10),
                const _BulletRow(text: 'Ed25519 & X25519 identity keys'),
                const _BulletRow(text: 'Contacts & message history'),
                const _BulletRow(text: 'Wallet balance & transaction history'),
                const _BulletRow(text: 'All app settings & preferences'),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _gold,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(vertical: 13),
                    ),
                    icon: _creatingBackup
                        ? const SizedBox(width: 16, height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.black))
                        : const Icon(Icons.lock_outline_rounded, size: 18),
                    label: Text(
                      _creatingBackup ? 'Encrypting…' : 'Create Encrypted Backup',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    onPressed: _creatingBackup ? null : _showCreateBackupSheet,
                  ),
                ),
              ],
            ),
          ),

          if (!widget.restoreOnly) const SizedBox(height: 16),

          // ── Restore card ───────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: _cardBg,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(children: [
                  Icon(Icons.cloud_download_outlined,
                      color: Colors.white54, size: 22),
                  SizedBox(width: 10),
                  Text('Restore from Backup',
                      style: TextStyle(color: Colors.white,
                          fontSize: 16, fontWeight: FontWeight.bold)),
                ]),
                const SizedBox(height: 12),
                const Text(
                  'Restore your identity and data from a .sovbak file. '
                  'All current data on this device will be replaced. '
                  'A restart is required to complete restoration.',
                  style: TextStyle(
                      color: Colors.white60, fontSize: 13, height: 1.5),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white70,
                      side: const BorderSide(color: Colors.white24),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(vertical: 13),
                    ),
                    icon: _restoringBackup
                        ? const SizedBox(width: 16, height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white54))
                        : const Icon(Icons.restore_rounded, size: 18),
                    label: Text(
                      _restoringBackup ? 'Restoring…' : 'Restore from File',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    onPressed: _restoringBackup ? null : _showRestoreSheet,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // ── Security note ──────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.blue.withAlpha(14),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.blue.withAlpha(40)),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline_rounded,
                    color: Colors.blueAccent, size: 16),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Backups are encrypted with AES-256-GCM using a key '
                    'derived from your password via PBKDF2-SHA256 '
                    '(600,000 iterations). Without the correct password '
                    'the file is unreadable — store both in a secure location.',
                    style: TextStyle(
                        color: Colors.white54, fontSize: 12, height: 1.5),
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

// ── Bullet list row ───────────────────────────────────────────────────────────

class _BulletRow extends StatelessWidget {
  final String text;
  const _BulletRow({required this.text});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('  • ',
            style: TextStyle(color: Color(0xFF00BFA5), fontSize: 12)),
        Expanded(
          child: Text(text,
              style: const TextStyle(color: Colors.white60, fontSize: 12)),
        ),
      ],
    ),
  );
}
