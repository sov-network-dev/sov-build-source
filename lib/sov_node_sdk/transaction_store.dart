// lib/sov_node_sdk/transaction_store.dart
// ─────────────────────────────────────────────────────────────────────────────
// TransactionStore — local persistent transaction history.
//
// Backed by SharedPreferences (key: 'recent_transactions').
// Stores up to _maxTransactions entries, newest-first.
//
// Each entry is a Map<String, dynamic> with at minimum:
//   tx_id         String   — unique identifier
//   type          String   — 'sent' | 'received' | 'enrollment_reward'
//   amount_seeds  int      — amount in seeds (1 SOV = 1,000,000 seeds)
//   counterparty_id String — recipient/sender/network
//   tx_hash       String   — relay tx hash (may be empty for enrollment)
//   timestamp     int      — Unix milliseconds
//   status        String   — 'confirmed' | 'pending' | 'failed'
//   relay_id      String   — relay that processed it (may be empty)
// ─────────────────────────────────────────────────────────────────────────────
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TransactionStore {
  static const String _key             = 'recent_transactions';
  // 200 entries covers a relay's full 100-tx sync response plus 100 local
  // entries generated while offline.  The relay is the persistent source of
  // truth; this local store is a display cache that is refreshed on connect.
  static const int    _maxTransactions  = 200;

  /// Prepend [tx] to the stored list, trimming to [_maxTransactions].
  /// Safe to call from any async context — serialises via SharedPreferences.
  /// Deduplicates by tx_hash — if a matching hash already exists in the store
  /// the new entry is silently dropped, preventing duplicate banners when both
  /// the live SOV_TRANSFER_RECEIVED push and the HELLO-reconnect push fire.
  static Future<void> save(Map<String, dynamic> tx) async {
    try {
      final prefs  = await SharedPreferences.getInstance();
      final list   = _readList(prefs);
      final txHash = (tx['tx_hash'] as String? ?? '').trim();
      // Dedup: skip if this tx_hash already exists in the store.
      if (txHash.isNotEmpty) {
        final alreadyStored = list.any((e) {
          final h = (e['tx_hash'] as String? ?? '').trim();
          return h.isNotEmpty && h == txHash;
        });
        if (alreadyStored) {
          debugPrint('[TX_STORE] save: duplicate tx_hash $txHash skipped');
          return;
        }
      }
      list.insert(0, tx);
      final trimmed = list.take(_maxTransactions).toList();
      await prefs.setString(_key, jsonEncode(trimmed));
    } catch (e) {
      debugPrint('[TX_STORE] save error: $e');
    }
  }

  /// Synchronous read from a live [SharedPreferences] instance.
  /// Useful when you already have the prefs object in scope.
  static List<Map<String, dynamic>> getAll(SharedPreferences prefs) {
    return _readList(prefs);
  }

  /// Async read — fetches its own SharedPreferences instance.
  static Future<List<Map<String, dynamic>>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return _readList(prefs);
    } catch (e) {
      debugPrint('[TX_STORE] load error: $e');
      return [];
    }
  }

  /// Merge [incoming] transactions (from the relay ledger sync) into the local
  /// store without creating duplicates.
  ///
  /// Deduplication key: `tx_hash` (or `tx_id` as fallback).  Any entry whose
  /// key already exists in the stored list is silently skipped so that locally-
  /// created entries (with hand-crafted IDs) are never overwritten.
  ///
  /// Each map in [incoming] is normalised from relay field names before saving:
  ///   tx_id / tx_hash          → tx_hash + tx_id
  ///   from_sovereign_id/from_id → counterparty_id (for received tx)
  ///   to_sovereign_id / to_id   → counterparty_id (for sent tx)
  ///   amount_seeds / amount(SOV) → amount_seeds
  ///   timestamp (sec or ms)      → timestamp (ms)
  ///
  /// [mySovId] is used to decide whether each transaction is 'sent' or
  /// 'received' when the relay does not include an explicit 'type' field.
  static Future<void> mergeAll(
      List<dynamic> incoming, String mySovId) async {
    if (incoming.isEmpty || mySovId.isEmpty) return;
    try {
      final prefs    = await SharedPreferences.getInstance();
      final existing = _readList(prefs);

      // Build a set of all known tx hashes for O(1) lookup.
      final knownHashes = <String>{
        for (final tx in existing)
          if ((tx['tx_hash'] as String? ?? '').isNotEmpty)
            tx['tx_hash'] as String,
        for (final tx in existing)
          if ((tx['tx_id'] as String? ?? '').isNotEmpty)
            tx['tx_id'] as String,
      };

      final toAdd = <Map<String, dynamic>>[];
      for (final raw in incoming) {
        if (raw is! Map) continue;
        final entry = Map<String, dynamic>.from(raw);

        // ── Normalise ID ───────────────────────────────────────────────────
        final txHash = (entry['tx_hash'] ?? entry['tx_id'] ?? '') as String;
        final txId   = txHash.isNotEmpty
            ? txHash
            : 'relay-${DateTime.now().millisecondsSinceEpoch}';
        if (txHash.isNotEmpty && knownHashes.contains(txHash)) continue;

        // ── Normalise amount ───────────────────────────────────────────────
        int amountSeeds;
        if (entry.containsKey('amount_seeds')) {
          amountSeeds = ((entry['amount_seeds'] as num?) ?? 0).toInt();
        } else {
          // relay may send amount in SOV (fractional)
          final sov = ((entry['amount'] as num?) ?? 0.0).toDouble();
          amountSeeds = (sov * 1000000).round();
        }
        if (amountSeeds <= 0) continue;

        // ── Normalise timestamp ───────────────────────────────────────────
        // relay_db.js stores confirmed_at = Date.now() (milliseconds).
        // Some relay paths use 'timestamp'. Accept both; fall back to now.
        final rawTs = ((entry['confirmed_at'] ??
                        entry['timestamp']    ??
                        0) as num).toInt();
        final tsMs  = (rawTs > 0 && rawTs < 1000000000000)
            ? rawTs * 1000    // seconds → ms (legacy)
            : (rawTs > 0 ? rawTs : DateTime.now().millisecondsSinceEpoch);

        // ── Determine direction ────────────────────────────────────────────
        final fromId = (entry['from_sovereign_id'] ??
                        entry['from_id']           ??
                        '') as String;
        final toId   = (entry['to_sovereign_id'] ??
                        entry['to_id']           ??
                        '') as String;

        final String type;
        final String counterparty;
        if (entry.containsKey('type') &&
            (entry['type'] == 'sent' ||
             entry['type'] == 'received' ||
             entry['type'] == 'enrollment_reward')) {
          type         = entry['type'] as String;
          counterparty = type == 'sent' ? toId : fromId;
        } else {
          type         = fromId == mySovId ? 'sent' : 'received';
          counterparty = type  == 'sent'   ? toId   : fromId;
        }

        final entryMemo = (entry['memo'] as String? ?? '').trim();
        toAdd.add({
          'tx_id':           txId,
          'type':            type,
          'amount_seeds':    amountSeeds,
          'counterparty_id': counterparty,
          'tx_hash':         txHash,
          'timestamp':       tsMs,
          'status':          (entry['status'] as String?) ?? 'confirmed',
          'relay_id':        (entry['relay_id'] as String?) ?? '',
          'answered_by':     '',
          if (entryMemo.isNotEmpty) 'memo': entryMemo,
        });
        knownHashes.add(txHash.isNotEmpty ? txHash : txId);
      }

      if (toAdd.isEmpty) return;

      // Merge: combine new + existing, sort newest-first, cap at max.
      final merged = [...toAdd, ...existing];
      merged.sort((a, b) {
        final ta = (a['timestamp'] as num?)?.toInt() ?? 0;
        final tb = (b['timestamp'] as num?)?.toInt() ?? 0;
        return tb.compareTo(ta);
      });
      final trimmed = merged.take(_maxTransactions).toList();
      await prefs.setString(_key, jsonEncode(trimmed));
      debugPrint('[TX_STORE] mergeAll: +${toAdd.length} relay txs imported');
    } catch (e) {
      debugPrint('[TX_STORE] mergeAll error: $e');
    }
  }

  /// Remove all stored transactions.
  static Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } catch (e) {
      debugPrint('[TX_STORE] clear error: $e');
    }
  }

  // ── Internal ────────────────────────────────────────────────────────────────

  static List<Map<String, dynamic>> _readList(SharedPreferences prefs) {
    try {
      final raw = prefs.getString(_key) ?? '[]';
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } catch (_) {
      return [];
    }
  }
}
