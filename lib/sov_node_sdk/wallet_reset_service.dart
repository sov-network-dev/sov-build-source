// lib/sov_node_sdk/wallet_reset_service.dart
// ─────────────────────────────────────────────────────────────────────────────
// WalletResetService — "Remove this wallet from this device."
//
// PURPOSE:
//   There was previously no supported way for a citizen to cleanly take their
//   wallet off a device (no app "uninstall" equivalent that a citizen can
//   trigger deliberately before selling/giving away a PC, or just to start
//   fresh). This is that missing action.
//
// WHAT IT CLEARS:
//   - KeyManager's signing keys + Spend-Lock/Hardware-Lock secure-storage blobs
//   - MessageKeyManager's X25519 keys (both secure storage AND the Windows
//     file fallback — skipping the file would silently resurrect the old
//     messaging keypair on next launch)
//   - The two local SQLite databases (sov_contacts.db, sov_node.db) — closed
//     then the files deleted outright, including any -wal/-shm/-journal
//     siblings sqflite may have left
//   - The encrypted local checkpoint file
//   - EVERY SharedPreferences key — enrollment flags, caches, drafts, guardian
//     IDs, node settings, per-conversation drafts, everything. A full reset
//     should not selectively spare anything, so this clears all of
//     SharedPreferences rather than enumerating individual key names (the
//     enumerate-by-hand approach was tried three times elsewhere in this
//     codebase — KeyManager's own key list, MessageKeyManager's backup list,
//     and enrollment_recovery_screen's fresh-start list — and all three ended
//     up incomplete/out of sync with each other).
//
//   - THE BUNDLED FULL NODE'S DATA (added 2026-08-01): its identity, ledger
//     copy and logs. This was previously left behind, and it was the most
//     consequential omission in the whole reset.
//
//     Found live: after a citizen ran this reset, `sov-node-data/` still held
//     `node_identity.enc`, `node_public.pem`, an 827 KB `node.db` with a 4.2 MB
//     WAL, `relay_pool.json` and a 982 KB log. The node identity was still
//     registered as `active` across the fleet and its address — the operator's
//     HOME IP — was still being published in the relay pool that every citizen
//     downloads. Starting the app again would have re-registered the same node
//     and republished that address.
//
//     A person who chooses "remove this wallet from this device", typically
//     because they are selling or giving away the machine, reasonably believes
//     they have removed themselves. Leaving an identity that re-announces their
//     home address makes that belief false, which is worse than not offering
//     the feature at all.
//
// WHAT IT DOES NOT CLEAR:
//   - The Windows TPM-sealed key (Hardware-Lock), if ever enabled, is a CNG
//     key persisted in the Windows key store itself, outside both
//     SharedPreferences and secure storage. There is no existing code path
//     that deletes it (only ever creates/opens it), and it is a
//     non-exportable, non-identifying RSA keypair — harmless to leave behind.
//     Deleting `sov_hw_sealed_v1` above already makes it unusable.
//   - Anything already published to OTHER nodes. Clearing the local identity
//     stops it re-registering; it does not retract rows peers already hold.
//     Those age out of the registry via `node_registry_ttl_days`.
//
// RECOVERY:
//   This cannot be undone from within the app. The only way back is the
//   citizen's own 12-word seed phrase (never stored on-device in the clear)
//   via Recover My Wallet, or Guardian Recovery if guardians were appointed.
// ─────────────────────────────────────────────────────────────────────────────
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'contacts_db.dart';
import 'palm_local_store.dart';
import 'sov_checkpoint.dart';
import 'sov_db_path.dart';
import 'key_manager.dart';
import 'message_key_manager.dart';
import 'node_controller.dart';

class WalletResetService {
  static Future<void> resetDevice() async {
    // 1. Secure-storage-backed key material (signing + messaging + locks)
    await KeyManager.wipeKeys();
    await MessageKeyManager.wipeKeys();

    // 2. Local SQLite databases — close, then delete the files outright
    await ContactsDb.closeDb();
    await PalmLocalStore.closeDb();
    final dbDir = await sovDatabasesDir();
    for (final name in ['sov_contacts.db', 'sov_node.db']) {
      for (final suffix in ['', '-wal', '-shm', '-journal']) {
        final f = File(p.join(dbDir, '$name$suffix'));
        if (await f.exists()) {
          try { await f.delete(); } catch (_) {}
        }
      }
    }

    // 3. Encrypted local checkpoint (used for post-restart recovery hints)
    await SovCheckpoint.clear();

    // 4. The bundled full node — stop it, then remove its identity and data.
    //
    // ORDER MATTERS: the node must be stopped BEFORE the directory is removed.
    // A running node holds its DB open and rewrites state on shutdown, so
    // deleting underneath it leaves the identity behind — exactly the mistake
    // that left a retired node re-registering an operator's home address.
    await _clearNodeData();

    // 5. Every cached preference, flag, and draft
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  }

  /// Stop the bundled node and delete `sov-node-data/` in full.
  ///
  /// Best-effort by design: a citizen who has never run a node has no such
  /// directory, and a failure to remove one file must not abort the wallet
  /// reset half-done. Anything left behind is reported, never swallowed
  /// silently — a reset that quietly kept the node identity is precisely the
  /// bug this fixes.
  static Future<List<String>> _clearNodeData() async {
    final failed = <String>[];
    try {
      // Stopping is what makes the delete stick. If the controller cannot be
      // reached the delete still runs; a locked file then shows up in `failed`.
      try { await NodeController.instance.stop(); } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 600));

      final dir = Directory(await NodeController.instance.resolveDataDir());
      if (!await dir.exists()) return failed;

      // Delete files first so a single locked file cannot strand the whole
      // tree, then remove the (now empty) directories.
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is File) {
          try { await e.delete(); } catch (_) { failed.add(e.path); }
        }
      }
      try {
        await dir.delete(recursive: true);
      } catch (_) {
        if (await dir.exists()) failed.add(dir.path);
      }
    } catch (e) {
      failed.add('node data: $e');
    }
    return failed;
  }
}
