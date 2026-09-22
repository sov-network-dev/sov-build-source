// lib/sov_node_sdk/palm_local_store.dart
// ─────────────────────────────────────────────────────────────────────────────
// PALM LOCAL STORAGE
//
// Persists dual-palm enrollment data to the phone's local SQLite database.
// This ensures enrollment survives app restarts — the phone IS the database.
//
// TABLES:
//   palm_enrollments — one row per hand per sovereign identity
//     sovereign_id  — the citizen's sovereign ID
//     hand_type     — LEFT or RIGHT
//     embedding     — 128-float DNA vector as JSON
//     helper_data   — BCH fuzzy commitment helper (base64)
//     key_hash      — SHA-256 of master key for verification
//     enrolled_at   — Unix timestamp
//
// USAGE:
//   await PalmLocalStore.init();
//   await PalmLocalStore.saveEnrollment(sovereignId, HandType.left, result);
//   final data = await PalmLocalStore.loadEnrollment(sovereignId, HandType.left);
//   final both = await PalmLocalStore.loadBothHands(sovereignId);
//   await PalmLocalStore.clear(sovereignId); // on reset/logout
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import '../sov_node_sdk/fuzzy_commitment.dart';
import 'sov_db_path.dart';

// ── Hand type helper ──────────────────────────────────────────────────────────
// Re-exported so screens do not need to import two files
enum PalmHandType { left, right }

extension PalmHandTypeExt on PalmHandType {
  String get label => this == PalmHandType.left ? 'LEFT' : 'RIGHT';
}

// ── Stored enrollment data ────────────────────────────────────────────────────
class StoredPalmEnrollment {
  final String       sovereignId;
  final PalmHandType handType;
  final List<double> embedding;
  final String       helperDataBase64;
  final String       masterKeyHash;
  final int          enrolledAt;
  final double       quantizeThreshold;

  const StoredPalmEnrollment({
    required this.sovereignId,
    required this.handType,
    required this.embedding,
    required this.helperDataBase64,
    required this.masterKeyHash,
    required this.enrolledAt,
    this.quantizeThreshold = 0.0,
  });

  /// Reconstruct an EnrollmentResult from stored data
  /// so FuzzyCommitment.recover() can be called directly
  EnrollmentResult toEnrollmentResult() {
    // Decode base64 helper data back to List<int> bits
    final helperBytes = base64Decode(helperDataBase64);
    final helperBits  = <int>[];
    for (int i = 0; i < 255; i++) {
      helperBits.add((helperBytes[i ~/ 8] >> (7 - (i % 8))) & 1);
    }
    return EnrollmentResult(
      masterKeyBits:     [], // never stored — key derived at recovery time
      helperData:        helperBits,
      masterKeyHash:     masterKeyHash,
      quantizeThreshold: quantizeThreshold,
    );
  }

  Map<String, dynamic> toMap() => {
    'sovereign_id':  sovereignId,
    'hand_type':     handType.label,
    'embedding':     jsonEncode(embedding),
    'helper_data':   helperDataBase64,
    'key_hash':      masterKeyHash,
    'enrolled_at':   enrolledAt,
  };

  factory StoredPalmEnrollment.fromMap(Map<String, dynamic> m) =>
      StoredPalmEnrollment(
        sovereignId:      m['sovereign_id'] as String,
        handType:         (m['hand_type'] as String) == 'RIGHT'
                              ? PalmHandType.right : PalmHandType.left,
        embedding:        (jsonDecode(m['embedding'] as String) as List)
                              .map((v) => (v as num).toDouble()).toList(),
        helperDataBase64: m['helper_data'] as String,
        masterKeyHash:    m['key_hash'] as String,
        enrolledAt:       m['enrolled_at'] as int,
        quantizeThreshold: (m['quantize_threshold'] as num?)?.toDouble() ?? 0.0,
      );
}

// ── PalmLocalStore ────────────────────────────────────────────────────────────
class PalmLocalStore {
  static Database? _db;

  /// Close the database singleton so its file can be safely deleted or
  /// overwritten. Mirrors ContactsDb.closeDb() for the same reason.
  static Future<void> closeDb() async {
    await _db?.close();
    _db = null;
  }

  static Future<void> init() async {
    if (_db != null) return;
    final dbPath = p.join(await sovDatabasesDir(), 'sov_node.db');
    _db = await openDatabase(
      dbPath,
      version: 2, // bump version to add palm_enrollments
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  static Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS palm_enrollments (
        id                 INTEGER PRIMARY KEY AUTOINCREMENT,
        sovereign_id       TEXT NOT NULL,
        hand_type          TEXT NOT NULL DEFAULT 'LEFT',
        embedding          TEXT NOT NULL,
        helper_data        TEXT NOT NULL,
        key_hash           TEXT NOT NULL,
        enrolled_at        INTEGER NOT NULL,
        quantize_threshold REAL NOT NULL DEFAULT 0.0,
        UNIQUE(sovereign_id, hand_type)
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_palm_sov
        ON palm_enrollments (sovereign_id)
    ''');
  }

  static Future<void> _onUpgrade(Database db, int oldV, int newV) async {
    if (oldV < 2) {
      // Add palm_enrollments table if upgrading from v1.
      // NOTE: CREATE TABLE IF NOT EXISTS won't add new columns to an existing
      // table. We handle each column explicitly via ALTER TABLE below.
      await db.execute('''
        CREATE TABLE IF NOT EXISTS palm_enrollments (
          id                 INTEGER PRIMARY KEY AUTOINCREMENT,
          sovereign_id       TEXT NOT NULL,
          hand_type          TEXT NOT NULL DEFAULT 'LEFT',
          embedding          TEXT NOT NULL,
          helper_data        TEXT NOT NULL,
          key_hash           TEXT NOT NULL,
          enrolled_at        INTEGER NOT NULL,
          quantize_threshold REAL NOT NULL DEFAULT 0.0,
          UNIQUE(sovereign_id, hand_type)
        )
      ''');
      await db.execute('''
        CREATE INDEX IF NOT EXISTS idx_palm_sov
          ON palm_enrollments (sovereign_id)
      ''');
    }
    // Always ensure quantize_threshold column exists (safe on any version).
    // Devices that had the table created without the column during an earlier
    // upgrade get it added here. Throws are caught below in case column exists.
    try {
      await db.execute(
        'ALTER TABLE palm_enrollments ADD COLUMN quantize_threshold REAL NOT NULL DEFAULT 0.0'
      );
    } catch (_) {
      // Column already exists — ignore.
    }
  }

  // ── SAVE ───────────────────────────────────────────────────────────────────
  /// Save or update a palm enrollment for one hand.
  /// Uses INSERT OR REPLACE — safe to call multiple times.
  static Future<bool> saveEnrollment(
    String sovereignId,
    PalmHandType handType,
    List<double> embedding,
    EnrollmentResult result,
  ) async {
    await init();
    try {
      await _db!.insert(
        'palm_enrollments',
        {
          'sovereign_id':        sovereignId,
          'hand_type':           handType.label,
          'embedding':           jsonEncode(embedding),
          'helper_data':         result.helperDataBase64,
          'key_hash':            result.masterKeyHash,
          'enrolled_at':         DateTime.now().millisecondsSinceEpoch ~/ 1000,
          'quantize_threshold':  result.quantizeThreshold,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      return true;
    } catch (e) {
      return false;
    }
  }

  // ── LOAD ONE HAND ──────────────────────────────────────────────────────────
  static Future<StoredPalmEnrollment?> loadEnrollment(
    String sovereignId,
    PalmHandType handType,
  ) async {
    await init();
    try {
      final rows = await _db!.query(
        'palm_enrollments',
        where: 'sovereign_id = ? AND hand_type = ?',
        whereArgs: [sovereignId, handType.label],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      return StoredPalmEnrollment.fromMap(rows.first);
    } catch (e) {
      return null;
    }
  }

  // ── LOAD BOTH HANDS ────────────────────────────────────────────────────────
  static Future<Map<PalmHandType, StoredPalmEnrollment>> loadBothHands(
    String sovereignId,
  ) async {
    await init();
    final result = <PalmHandType, StoredPalmEnrollment>{};
    try {
      final rows = await _db!.query(
        'palm_enrollments',
        where: 'sovereign_id = ?',
        whereArgs: [sovereignId],
      );
      for (final row in rows) {
        final e = StoredPalmEnrollment.fromMap(row);
        result[e.handType] = e;
      }
    } catch (e) {
      // Return whatever was loaded
    }
    return result;
  }

  // ── CHECK ENROLLMENT STATUS ────────────────────────────────────────────────
  static Future<bool> isEnrolled(String sovereignId) async {
    await init();
    try {
      final rows = await _db!.query(
        'palm_enrollments',
        where: 'sovereign_id = ?',
        whereArgs: [sovereignId],
        limit: 1,
      );
      return rows.isNotEmpty;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> isBothHandsEnrolled(String sovereignId) async {
    await init();
    try {
      final rows = await _db!.query(
        'palm_enrollments',
        where: 'sovereign_id = ?',
        whereArgs: [sovereignId],
      );
      return rows.length >= 2;
    } catch (e) {
      return false;
    }
  }

  // ── CLEAR ──────────────────────────────────────────────────────────────────
  /// Remove all palm enrollments for a sovereign ID.
  /// Called on logout or full reset.
  static Future<void> clear(String sovereignId) async {
    await init();
    try {
      await _db!.delete(
        'palm_enrollments',
        where: 'sovereign_id = ?',
        whereArgs: [sovereignId],
      );
    } catch (e) {
      // Non-fatal
    }
  }

  /// Wipe ALL palm enrollments — for dev/testing only
  static Future<void> clearAll() async {
    await init();
    await _db!.delete('palm_enrollments');
  }

  // ── GET EMBEDDING LIST for local duplicate check ────────────────────────────
  static Future<List<Map<String, dynamic>>> getAllEmbeddings() async {
    await init();
    try {
      return await _db!.query(
        'palm_enrollments',
        columns: ['sovereign_id', 'hand_type', 'embedding'],
      );
    } catch (e) {
      return [];
    }
  }
}
