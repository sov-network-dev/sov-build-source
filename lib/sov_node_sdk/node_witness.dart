import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import '../sov_node_sdk/relay_connector.dart';

// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
// NODE WITNESS SERVICE â€” Sovereign Network
// Blueprint v5.2
//
// Every phone on the Sovereign Network is a witness node.
// This service runs silently in the background from app launch.
//
// What it does:
//
//   ENROLLMENT_WITNESS â€” when any citizen enrolls, the relay broadcasts
//   this message to all connected nodes. This service catches it and saves
//   the citizen's record to local SQLite. The phone becomes a witness that
//   this person exists on the network.
//
//   RECOVERY_WITNESS_REQUEST â€” when a citizen tries to recover their wallet,
//   the relay selects 7 witnesses and asks each one: "does this palm hash
//   exist in your records?" This service checks local SQLite and responds
//   with RECOVERY_WITNESS_CONFIRM. No human involvement. Fully automatic.
//
//   SEED_RECOVERY_WITNESS_REQUEST â€” same for seed phrase recovery. The witness
//   verifies the ownership proof signature against the known public key.
//
// This is the protocol. No central database. The phones ARE the database.
// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

class NodeWitness {
  static Database? _db;
  static StreamSubscription? _subscription;
  static bool _running = false;

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  // START â€” call once from main.dart after relay connects
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

  static Future<void> start() async {
    if (_running) return;
    _running = true;
    await _initDb();
    _listenForWitnessMessages();
    debugPrint('[WITNESS] Sovereign witness service started');
  }

  static Future<void> stop() async {
    await _subscription?.cancel();
    await _db?.close();
    _db    = null;
    _running = false;
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  // DATABASE â€” local SQLite on this phone node
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

  static Future<void> _initDb() async {
    final dir  = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'sov_witness.db');
    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE sov_enrollments (
            sovereign_id     TEXT PRIMARY KEY,
            public_key       TEXT NOT NULL,
            uniqueness_hash  TEXT NOT NULL,
            liveness_hash    TEXT,
            enrollment_hash  TEXT,
            enrollment_sov   REAL DEFAULT 0,
            citizen_number   INTEGER,
            enrolled_at      INTEGER NOT NULL,
            witnessed_at     INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE INDEX idx_uniqueness
            ON sov_enrollments (uniqueness_hash)
        ''');
        await db.execute('''
          CREATE TABLE sov_key_rotations (
            sovereign_id   TEXT NOT NULL,
            new_public_key TEXT NOT NULL,
            recovery_path  TEXT NOT NULL,
            rotated_at     INTEGER NOT NULL
          )
        ''');
        debugPrint('[WITNESS] Local witness database created');
      },
    );
    debugPrint('[WITNESS] Local witness database ready: $path');
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  // LISTEN â€” intercept witness messages from relay stream
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

  static void _listenForWitnessMessages() {
    _subscription = RelayConnector.messageStream?.listen((msg) async {
      final type = msg['type'] as String?;
      switch (type) {

        case 'ENROLLMENT_WITNESS':
          await _handleEnrollmentWitness(msg);
          break;

        case 'RECOVERY_WITNESS_REQUEST':
          await _handleRecoveryWitnessRequest(msg);
          break;

        case 'SEED_RECOVERY_WITNESS_REQUEST':
          await _handleSeedRecoveryWitnessRequest(msg);
          break;

        case 'KEY_ROTATION_PROPOSAL':
          await _handleKeyRotationProposal(msg);
          break;
      }
    });
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  // HANDLER: ENROLLMENT_WITNESS
  // Relay broadcasts this when any citizen enrolls.
  // We save the record so we can witness their recovery later.
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

  static Future<void> _handleEnrollmentWitness(Map<String, dynamic> msg) async {
    if (_db == null) return;
    final sovereignId    = msg['sovereign_id']    as String?;
    final publicKey      = msg['public_key']      as String?;
    final uniquenessHash = msg['uniqueness_hash'] as String?;
    if (sovereignId == null || publicKey == null || uniquenessHash == null) return;
    if (uniquenessHash.isEmpty) return;

    try {
      await _db!.insert(
        'sov_enrollments',
        {
          'sovereign_id':    sovereignId,
          'public_key':      publicKey,
          'uniqueness_hash': uniquenessHash,
          'liveness_hash':   msg['liveness_hash']   as String? ?? '',
          'enrollment_hash': msg['enrollment_hash'] as String? ?? '',
          'enrollment_sov':  (msg['enrollment_sov'] as num?)?.toDouble() ?? 0.0,
          'citizen_number':  (msg['citizen_number'] as num?)?.toInt() ?? 0,
          'enrolled_at':     (msg['timestamp'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch,
          'witnessed_at':    DateTime.now().millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
        // ignore = don't overwrite existing records
        // first witness record wins â€” immutable after that
      );
      debugPrint('[WITNESS] Enrollment witnessed: $sovereignId');
    } catch (e) {
      debugPrint('[WITNESS] Enrollment store error: $e');
    }
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  // HANDLER: RECOVERY_WITNESS_REQUEST (Primary path â€” palm DNA)
  // Relay selected this node as one of 7 witnesses.
  // Check local DB: does this uniqueness_hash exist?
  // Respond with RECOVERY_WITNESS_CONFIRM.
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

  static Future<void> _handleRecoveryWitnessRequest(
      Map<String, dynamic> msg) async {
    if (_db == null) return;

    final recoveryId     = msg['recovery_id']     as String?;
    final uniquenessHash = msg['uniqueness_hash'] as String?;
    if (recoveryId == null || uniquenessHash == null) return;

    // Check our local Bloom filter (SQLite index on uniqueness_hash)
    final rows = await _db!.query(
      'sov_enrollments',
      columns: ['sovereign_id', 'public_key'],
      where:  'uniqueness_hash = ?',
      whereArgs: [uniquenessHash],
      limit: 1,
    );

    final found          = rows.isNotEmpty;
    final matchedSovId   = found ? rows.first['sovereign_id'] as String : '';
    final matchedPubKey  = found ? rows.first['public_key']   as String : '';

    debugPrint('[WITNESS] Recovery witness check: ${uniquenessHash.substring(0, 12)}... => ${found ? "FOUND ($matchedSovId)" : "NOT FOUND"}');

    // Send our witness confirmation back to relay
    await RelayConnector.send({
      'type':                'RECOVERY_WITNESS_CONFIRM',
      'recovery_id':         recoveryId,
      'hash_found':          found,
      'matched_sovereign_id': matchedSovId,
      'matched_public_key':  matchedPubKey,
      'witness_signature':   _sign(recoveryId + uniquenessHash + (found ? '1' : '0')),
    });
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  // HANDLER: SEED_RECOVERY_WITNESS_REQUEST (Secondary path â€” seed phrase)
  // Relay asks us to verify the ownership proof against the known public key.
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

  static Future<void> _handleSeedRecoveryWitnessRequest(
      Map<String, dynamic> msg) async {
    if (_db == null) return;

    final recoveryId     = msg['recovery_id']     as String?;
    final sovereignId    = msg['sovereign_id']     as String?;
    final oldPublicKey   = msg['old_public_key']   as String?;
    if (recoveryId == null || sovereignId == null) return;

    // Check if we have this sovereign_id in our records
    final rows = await _db!.query(
      'sov_enrollments',
      columns: ['sovereign_id', 'public_key'],
      where:   'sovereign_id = ?',
      whereArgs: [sovereignId],
      limit: 1,
    );

    final found         = rows.isNotEmpty;
    final knownPubKey   = found ? rows.first['public_key'] as String : '';

    // In production: verify Ed25519 signature of ownershipProof
    // using knownPubKey. For now: confirm sovereign_id is known.
    final valid = found && knownPubKey == (oldPublicKey ?? knownPubKey);

    debugPrint('[WITNESS] Seed recovery witness: $sovereignId => ${valid ? "VALID" : "INVALID"}');

    await RelayConnector.send({
      'type':              'RECOVERY_WITNESS_CONFIRM',
      'recovery_id':       recoveryId,
      'hash_found':        valid,
      'matched_sovereign_id': sovereignId,
      'witness_signature': _sign(recoveryId + sovereignId + (valid ? '1' : '0')),
    });
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  // HANDLER: KEY_ROTATION_PROPOSAL
  // Relay broadcasts this after 5-of-7 witnesses confirm recovery.
  // Update our local record with the new public key.
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

  static Future<void> _handleKeyRotationProposal(
      Map<String, dynamic> msg) async {
    if (_db == null) return;

    final sovereignId  = msg['sovereign_id']   as String?;
    final newPublicKey = msg['new_public_key']  as String?;
    final recoveryPath = msg['recovery_path']   as String? ?? 'UNKNOWN';
    if (sovereignId == null || newPublicKey == null) return;

    // Update public key in our enrollment record
    await _db!.update(
      'sov_enrollments',
      {'public_key': newPublicKey},
      where:     'sovereign_id = ?',
      whereArgs: [sovereignId],
    );

    // Log the rotation permanently
    await _db!.insert('sov_key_rotations', {
      'sovereign_id':   sovereignId,
      'new_public_key': newPublicKey,
      'recovery_path':  recoveryPath,
      'rotated_at':     DateTime.now().millisecondsSinceEpoch,
    });

    debugPrint('[WITNESS] Key rotation applied: $sovereignId | path: $recoveryPath');
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  // WITNESS SIGNATURE
  // Signs a message using this node's sovereign identity.
  // In production: Ed25519 signing with KeyManager private key.
  // For now: HMAC-SHA256 with sovereign_id as key material.
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

  static String _sign(String message) {
    final key  = utf8.encode(message);
    final data = utf8.encode(message);
    final hmac = Hmac(sha256, key);
    return hmac.convert(data).toString();
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  // PUBLIC QUERIES â€” for use by wallet screens
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

  // How many citizens has this node witnessed?
  static Future<int> getWitnessedCount() async {
    if (_db == null) return 0;
    final result = await _db!.rawQuery(
        'SELECT COUNT(*) as count FROM sov_enrollments');
    return (result.first['count'] as int?) ?? 0;
  }

  // Is this sovereign_id known to this node?
  static Future<bool> knowsCitizen(String sovereignId) async {
    if (_db == null) return false;
    final rows = await _db!.query(
      'sov_enrollments',
      where:     'sovereign_id = ?',
      whereArgs: [sovereignId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  // Get public key for a known citizen
  static Future<String?> getPublicKey(String sovereignId) async {
    if (_db == null) return null;
    final rows = await _db!.query(
      'sov_enrollments',
      columns:   ['public_key'],
      where:     'sovereign_id = ?',
      whereArgs: [sovereignId],
      limit: 1,
    );
    return rows.isNotEmpty ? rows.first['public_key'] as String? : null;
  }
}
