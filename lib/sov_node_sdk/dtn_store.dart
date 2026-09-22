import 'dart:async';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'key_manager.dart';
import 'relay_connector.dart';
import 'wallet_engine.dart';
import 'sov_db_path.dart';

/// Delay-Tolerant Networking (DTN) Store
/// When a node has no internet, mesh, or bluetooth connection,
/// transactions are signed, stored locally, and automatically
/// forwarded the moment any connection becomes available.
/// This ensures SOV works in zero-connectivity environments —
/// remote villages, conflict zones, underground locations.

enum DTNPacketStatus {
  pending,    // Stored, waiting for connection
  carrying,   // Being carried by another node
  delivered,  // Successfully forwarded to network
  expired,    // TTL exceeded — transaction cancelled
}

class DTNPacket {
  final String packetId;
  final String txHash;
  final String fromId;
  final String toId;
  final double amount;
  final String signedPayload;
  final int createdAt;
  final int expiresAt;
  final int hopCount;
  final int maxHops;
  DTNPacketStatus status;

  DTNPacket({
    required this.packetId,
    required this.txHash,
    required this.fromId,
    required this.toId,
    required this.amount,
    required this.signedPayload,
    required this.createdAt,
    required this.expiresAt,
    required this.hopCount,
    required this.maxHops,
    required this.status,
  });

  factory DTNPacket.fromMap(Map<String, dynamic> map) {
    return DTNPacket(
      packetId: map['packet_id'] as String,
      txHash: map['tx_hash'] as String,
      fromId: map['from_id'] as String,
      toId: map['to_id'] as String,
      amount: (map['amount'] as num).toDouble(),
      signedPayload: map['signed_payload'] as String,
      createdAt: map['created_at'] as int,
      expiresAt: map['expires_at'] as int,
      hopCount: map['hop_count'] as int,
      maxHops: map['max_hops'] as int,
      status: DTNPacketStatus.values.firstWhere(
            (s) => s.name == map['status'],
        orElse: () => DTNPacketStatus.pending,
      ),
    );
  }

  Map<String, dynamic> toMap() => {
    'packet_id': packetId,
    'tx_hash': txHash,
    'from_id': fromId,
    'to_id': toId,
    'amount': amount,
    'signed_payload': signedPayload,
    'created_at': createdAt,
    'expires_at': expiresAt,
    'hop_count': hopCount,
    'max_hops': maxHops,
    'status': status.name,
  };

  bool get isExpired =>
      DateTime.now().millisecondsSinceEpoch > expiresAt;

  bool get canHop => hopCount < maxHops;
}

class DTNStore {
  static Database? _db;
  static Timer? _forwardTimer;
  static bool _isForwarding = false;

  // DTN packets expire after 72 hours by default
  static const _defaultTTLHours = 72;
  // Maximum hops a packet can take through peer nodes
  static const _defaultMaxHops = 10;

  // ── Database ──────────────────────────────────────────────
  static Future<Database> get db async {
    if (_db != null) return _db!;
    _db = await _initDb();
    return _db!;
  }

  static Future<Database> _initDb() async {
    final dbPath = await sovDatabasesDir();
    final path = join(dbPath, 'sov_dtn.db');
    return await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE dtn_packets (
            packet_id TEXT PRIMARY KEY,
            tx_hash TEXT NOT NULL,
            from_id TEXT NOT NULL,
            to_id TEXT NOT NULL,
            amount REAL NOT NULL,
            signed_payload TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            expires_at INTEGER NOT NULL,
            hop_count INTEGER NOT NULL DEFAULT 0,
            max_hops INTEGER NOT NULL DEFAULT 10,
            status TEXT NOT NULL DEFAULT 'pending'
          )
        ''');
        await db.execute('''
          CREATE TABLE dtn_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            packet_id TEXT NOT NULL,
            event TEXT NOT NULL,
            node_id TEXT,
            timestamp INTEGER NOT NULL
          )
        ''');
      },
    );
  }

  // ── Store a new offline transaction ───────────────────────
  static Future<String> storeTransaction({
    required String toId,
    required double amount,
  }) async {
    // Create the transaction in wallet engine first
    final txHash = await WalletEngine.sendSOV(
      toId: toId,
      amount: amount,
    );

    final sovereignId = await KeyManager.getSovereignId();
    final now = DateTime.now().millisecondsSinceEpoch;
    final expires = now + (_defaultTTLHours * 3600 * 1000);
    final packetId = 'DTN-$txHash';

    // Get the signed payload from wallet
    final pending = await WalletEngine.getPendingTransactions();
    final tx = pending.firstWhere(
          (t) => t['tx_hash'] == txHash,
      orElse: () => {},
    );

    final packet = DTNPacket(
      packetId: packetId,
      txHash: txHash,
      fromId: sovereignId!,
      toId: toId,
      amount: amount,
      signedPayload: tx['signed_payload'] as String? ?? '',
      createdAt: now,
      expiresAt: expires,
      hopCount: 0,
      maxHops: _defaultMaxHops,
      status: DTNPacketStatus.pending,
    );

    final database = await db;
    await database.insert('dtn_packets', packet.toMap());

    await _logEvent(
      packetId: packetId,
      event: 'STORED',
      nodeId: sovereignId,
    );

    return packetId;
  }

  // ── Forward all pending packets ───────────────────────────
  static Future<void> forwardPending() async {
    if (_isForwarding) return;
    _isForwarding = true;

    try {
      final packets = await getPendingPackets();

      for (final packet in packets) {
        // Skip expired packets
        if (packet.isExpired) {
          await _markExpired(packet.packetId);
          continue;
        }

        // Try relay first
        if (RelayConnector.isConnected) {
          final sent = await RelayConnector.send({
            'type': 'DTN_PACKET',
            'packet_id': packet.packetId,
            'tx_hash': packet.txHash,
            'from_id': packet.fromId,
            'to_id': packet.toId,
            'amount': packet.amount,
            'signed_payload': packet.signedPayload,
            'hop_count': packet.hopCount,
            'expires_at': packet.expiresAt,
          });

          if (sent) {
            await _markDelivered(packet.packetId);
            await WalletEngine.confirmTransaction(packet.txHash);
            continue;
          }
        }
      }
    } finally {
      _isForwarding = false;
    }
  }

  // ── Receive a packet carried by another node ──────────────
  // This is the SOV Peer Relay Hopping in action —
  // a nearby node carries our packet closer to the destination
  static Future<void> receiveCarriedPacket(
      Map<String, dynamic> data) async {
    final packetId = data['packet_id'] as String;
    final database = await db;

    // Check if we already have this packet
    final existing = await database.query(
      'dtn_packets',
      where: 'packet_id = ?',
      whereArgs: [packetId],
    );
    if (existing.isNotEmpty) return;

    final hopCount = (data['hop_count'] as int) + 1;
    const maxHops = _defaultMaxHops;

    if (hopCount >= maxHops) return; // Too many hops

    final now = DateTime.now().millisecondsSinceEpoch;
    final expiresAt = data['expires_at'] as int;
    if (now > expiresAt) return; // Expired in transit

    // Store the packet to carry forward
    final packet = DTNPacket(
      packetId: packetId,
      txHash: data['tx_hash'] as String,
      fromId: data['from_id'] as String,
      toId: data['to_id'] as String,
      amount: (data['amount'] as num).toDouble(),
      signedPayload: data['signed_payload'] as String,
      createdAt: now,
      expiresAt: expiresAt,
      hopCount: hopCount,
      maxHops: maxHops,
      status: DTNPacketStatus.carrying,
    );

    await database.insert('dtn_packets', packet.toMap());

    final sovereignId = await KeyManager.getSovereignId();
    await _logEvent(
      packetId: packetId,
      event: 'CARRYING',
      nodeId: sovereignId,
    );
  }

  // ── Get all pending packets ───────────────────────────────
  static Future<List<DTNPacket>> getPendingPackets() async {
    final database = await db;
    final results = await database.query(
      'dtn_packets',
      where: 'status = ? OR status = ?',
      whereArgs: ['pending', 'carrying'],
    );
    return results.map((r) => DTNPacket.fromMap(r)).toList();
  }

  // ── Get pending count ─────────────────────────────────────
  static Future<int> getPendingCount() async {
    final packets = await getPendingPackets();
    return packets.where((p) => !p.isExpired).length;
  }

  // ── Start auto-forward timer ──────────────────────────────
  // Checks for connection every 60 seconds and forwards
  static void startAutoForward() {
    _forwardTimer?.cancel();
    _forwardTimer = Timer.periodic(
      const Duration(seconds: 60),
          (_) async {
        if (RelayConnector.isConnected) {
          await forwardPending();
        }
      },
    );
  }

  // ── Stop auto-forward ─────────────────────────────────────
  static void stopAutoForward() {
    _forwardTimer?.cancel();
  }

  // ── Mark delivered ────────────────────────────────────────
  static Future<void> _markDelivered(String packetId) async {
    final database = await db;
    await database.update(
      'dtn_packets',
      {'status': DTNPacketStatus.delivered.name},
      where: 'packet_id = ?',
      whereArgs: [packetId],
    );
    await _logEvent(packetId: packetId, event: 'DELIVERED');
  }

  // ── Mark expired ──────────────────────────────────────────
  static Future<void> _markExpired(String packetId) async {
    final database = await db;
    await database.update(
      'dtn_packets',
      {'status': DTNPacketStatus.expired.name},
      where: 'packet_id = ?',
      whereArgs: [packetId],
    );
    await _logEvent(packetId: packetId, event: 'EXPIRED');
  }

  // ── Log event ─────────────────────────────────────────────
  static Future<void> _logEvent({
    required String packetId,
    required String event,
    String? nodeId,
  }) async {
    final database = await db;
    await database.insert('dtn_log', {
      'packet_id': packetId,
      'event': event,
      'node_id': nodeId,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }

  // ── DTN status summary ────────────────────────────────────
  static Future<Map<String, dynamic>> getStatus() async {
    final database = await db;
    final pending = await database.rawQuery(
      "SELECT COUNT(*) as count FROM dtn_packets WHERE status = 'pending'",
    );
    final carrying = await database.rawQuery(
      "SELECT COUNT(*) as count FROM dtn_packets WHERE status = 'carrying'",
    );
    final delivered = await database.rawQuery(
      "SELECT COUNT(*) as count FROM dtn_packets WHERE status = 'delivered'",
    );
    return {
      'pending': pending.first['count'],
      'carrying': carrying.first['count'],
      'delivered': delivered.first['count'],
    };
  }
}