import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'key_manager.dart';
import 'sov_db_path.dart';

class WalletEngine {
  static Database? _db;

  // ── Database setup ────────────────────────────────────────
  static Future<Database> get db async {
    if (_db != null) return _db!;
    _db = await _initDb();
    return _db!;
  }

  static Future<Database> _initDb() async {
    final dbPath = await sovDatabasesDir();
    final path = join(dbPath, 'sov_wallet.db');
    return await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE wallet (
            id INTEGER PRIMARY KEY,
            sovereign_id TEXT NOT NULL,
            balance REAL NOT NULL DEFAULT 0,
            last_updated INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE transactions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            tx_hash TEXT NOT NULL,
            from_id TEXT NOT NULL,
            to_id TEXT NOT NULL,
            amount REAL NOT NULL,
            timestamp INTEGER NOT NULL,
            status TEXT NOT NULL DEFAULT 'pending',
            witness_count INTEGER NOT NULL DEFAULT 0,
            signed_payload TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE growth_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            epoch INTEGER NOT NULL,
            citizen_count INTEGER NOT NULL,
            sov_price REAL NOT NULL,
            timestamp INTEGER NOT NULL
          )
        ''');
      },
    );
  }

  // ── Wallet initialisation ─────────────────────────────────
  static Future<void> initialise() async {
    final sovereignId = await KeyManager.getSovereignId();
    if (sovereignId == null) throw Exception('KeyManager not initialised');
    final database = await db;
    final existing = await database.query(
      'wallet',
      where: 'sovereign_id = ?',
      whereArgs: [sovereignId],
    );
    if (existing.isEmpty) {
      await database.insert('wallet', {
        'sovereign_id': sovereignId,
        'balance': 0.0,
        'last_updated': DateTime.now().millisecondsSinceEpoch,
      });
    }
  }

  // ── Balance ───────────────────────────────────────────────
  static Future<double> getBalance() async {
    final sovereignId = await KeyManager.getSovereignId();
    // Before enrollment/recovery the sovereign_id is null; a null whereArg
    // throws in sqflite ("Only num, String and Uint8List are supported").
    if (sovereignId == null || sovereignId.isEmpty) return 0.0;
    final database = await db;
    final result = await database.query(
      'wallet',
      where: 'sovereign_id = ?',
      whereArgs: [sovereignId],
    );
    if (result.isEmpty) return 0.0;
    return (result.first['balance'] as num).toDouble();
  }

  static Future<void> updateBalance(double newBalance) async {
    final sovereignId = await KeyManager.getSovereignId();
    if (sovereignId == null || sovereignId.isEmpty) return;
    final database = await db;
    await database.update(
      'wallet',
      {
        'balance': newBalance,
        'last_updated': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'sovereign_id = ?',
      whereArgs: [sovereignId],
    );
  }

  // ── Send SOV ──────────────────────────────────────────────
  static Future<String> sendSOV({
    required String toId,
    required double amount,
  }) async {
    final fromId = await KeyManager.getSovereignId();
    final balance = await getBalance();
    if (balance < amount) throw Exception('Insufficient balance');

    // Build transaction payload
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final payload = jsonEncode({
      'from': fromId,
      'to': toId,
      'amount': amount,
      'timestamp': timestamp,
    });

    // Sign the payload
    final signature = await KeyManager.signChallenge(payload);
    final txHash = sha256.convert(utf8.encode(payload + signature)).toString();

    final database = await db;
    await database.insert('transactions', {
      'tx_hash': txHash,
      'from_id': fromId!,
      'to_id': toId,
      'amount': amount,
      'timestamp': timestamp,
      'status': 'pending',
      'witness_count': 0,
      'signed_payload': jsonEncode({
        'payload': payload,
        'signature': signature,
      }),
    });

    // Deduct from local balance immediately
    await updateBalance(balance - amount);
    return txHash;
  }

  // ── Receive SOV ───────────────────────────────────────────
  static Future<void> receiveSOV({
    required String txHash,
    required String fromId,
    required double amount,
    required String signedPayload,
  }) async {
    final database = await db;

    // Check for duplicate
    final existing = await database.query(
      'transactions',
      where: 'tx_hash = ?',
      whereArgs: [txHash],
    );
    if (existing.isNotEmpty) return; // already received

    final toId = await KeyManager.getSovereignId();
    await database.insert('transactions', {
      'tx_hash': txHash,
      'from_id': fromId,
      'to_id': toId!,
      'amount': amount,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'status': 'confirmed',
      'witness_count': 1,
      'signed_payload': signedPayload,
    });

    final balance = await getBalance();
    await updateBalance(balance + amount);
  }

  // ── Transaction history ───────────────────────────────────
  static Future<List<Map<String, dynamic>>> getHistory() async {
    final sovereignId = await KeyManager.getSovereignId();
    final database = await db;
    return await database.query(
      'transactions',
      where: 'from_id = ? OR to_id = ?',
      whereArgs: [sovereignId, sovereignId],
      orderBy: 'timestamp DESC',
      limit: 50,
    );
  }

  // ── SOV growth formula ────────────────────────────────────
  // Runs deterministically on every node — no server needed
  static double calculateSOVPrice(int citizenCount) {
    if (citizenCount <= 0) return 0.0;
    // Price grows logarithmically with citizen count
    // At 1,000 citizens: ~$0.001
    // At 1,000,000 citizens: ~$1.00
    // At 500,000,000 citizens: ~$486
    return 0.0001 * (citizenCount / 1000) *
        (1 + (citizenCount / 50000000));
  }

  static Future<void> logGrowthEpoch({
    required int epoch,
    required int citizenCount,
  }) async {
    final database = await db;
    final price = calculateSOVPrice(citizenCount);
    await database.insert('growth_log', {
      'epoch': epoch,
      'citizen_count': citizenCount,
      'sov_price': price,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }

  // ── Pending transactions ──────────────────────────────────
  static Future<List<Map<String, dynamic>>> getPendingTransactions() async {
    final database = await db;
    return await database.query(
      'transactions',
      where: 'status = ?',
      whereArgs: ['pending'],
    );
  }

  static Future<void> confirmTransaction(String txHash) async {
    final database = await db;
    await database.update(
      'transactions',
      {'status': 'confirmed'},
      where: 'tx_hash = ?',
      whereArgs: [txHash],
    );
  }
}