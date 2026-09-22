// lib/sov_node_sdk/payment_request_store.dart
// Local persistent store for SOV payment requests.
// Uses SharedPreferences (same pattern as TransactionStore) — no extra DB.
//
// Each entry:
//   request_id   — "REQ-{timestamp}-{4 random hex chars}"
//   requester_id — own sovereign_id
//   amount_seeds — 0 means "any amount" (simple address QR)
//   memo         — free text description, may be empty
//   status       — 'pending' | 'paid' | 'expired'
//   created_at   — epoch ms
//   expires_at   — epoch ms (created_at + 30 days)
//   paid_at      — epoch ms or 0
//   payer_id     — sovereign_id of payer, empty until paid
//
// Max 100 entries; oldest are pruned when limit exceeded.

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class PaymentRequest {
  final String requestId;
  final String requesterId;
  final int    amountSeeds;
  final String memo;
        String status;    // mutable for in-place updates
  final int    createdAt;
  final int    expiresAt;
        int    paidAt;
        String payerId;

  PaymentRequest({
    required this.requestId,
    required this.requesterId,
    required this.amountSeeds,
    required this.memo,
    required this.status,
    required this.createdAt,
    required this.expiresAt,
    required this.paidAt,
    required this.payerId,
  });

  factory PaymentRequest.fromMap(Map<String, dynamic> m) => PaymentRequest(
    requestId:   m['request_id']   as String? ?? '',
    requesterId: m['requester_id'] as String? ?? '',
    amountSeeds: (m['amount_seeds'] as num?)?.toInt() ?? 0,
    memo:        m['memo']         as String? ?? '',
    status:      m['status']       as String? ?? 'pending',
    createdAt:   (m['created_at']  as num?)?.toInt() ?? 0,
    expiresAt:   (m['expires_at']  as num?)?.toInt() ?? 0,
    paidAt:      (m['paid_at']     as num?)?.toInt() ?? 0,
    payerId:     m['payer_id']     as String? ?? '',
  );

  Map<String, dynamic> toMap() => {
    'request_id':   requestId,
    'requester_id': requesterId,
    'amount_seeds': amountSeeds,
    'memo':         memo,
    'status':       status,
    'created_at':   createdAt,
    'expires_at':   expiresAt,
    'paid_at':      paidAt,
    'payer_id':     payerId,
  };

  /// Build the deep-link URI string encoded in the QR code.
  String toLink() {
    final base = 'sovreq://$requesterId';
    final params = <String>[];
    if (amountSeeds > 0) params.add('amount=$amountSeeds');
    if (memo.isNotEmpty) params.add('memo=${Uri.encodeComponent(memo)}');
    params.add('req=$requestId');
    params.add('expires=$expiresAt');
    return params.isEmpty ? base : '$base?${params.join('&')}';
  }

  bool get isPending => status == 'pending';
  bool get isPaid    => status == 'paid';
  bool get isExpired {
    if (status == 'expired') return true;
    return DateTime.now().millisecondsSinceEpoch > expiresAt;
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class PaymentRequestStore {
  static const _prefKey  = 'sov_payment_requests';
  static const _maxCount = 100;
  static const _thirtyDaysMs = 30 * 24 * 60 * 60 * 1000;

  // ── Generate a unique request ID ──────────────────────────────────────────
  static String generateId() {
    final ts   = DateTime.now().millisecondsSinceEpoch;
    final rand = (ts * 1337 % 0xFFFF).toRadixString(16).padLeft(4, '0');
    return 'REQ-$ts-$rand';
  }

  // ── Parse a sovreq:// deep link ───────────────────────────────────────────
  static Map<String, String?> parseLink(String link) {
    try {
      final uri = Uri.parse(link);
      if (uri.scheme != 'sovreq') return {};
      // IMPORTANT: Dart's Uri.parse() lowercases the host component per RFC 3986.
      // SOV Sovereign IDs are uppercase (SOV-XXXXXXXX), so we must restore case.
      return {
        'sovereign_id': uri.host.toUpperCase(),   // sov-xxxx → SOV-XXXX
        'amount':       uri.queryParameters['amount'],
        'memo':         uri.queryParameters['memo'],
        'req':          uri.queryParameters['req'],
        'expires':      uri.queryParameters['expires'],
      };
    } catch (_) {
      return {};
    }
  }

  // ── Save a new request ────────────────────────────────────────────────────
  static Future<PaymentRequest> create({
    required String requesterId,
    required int    amountSeeds,
    required String memo,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final req = PaymentRequest(
      requestId:   generateId(),
      requesterId: requesterId,
      amountSeeds: amountSeeds,
      memo:        memo,
      status:      'pending',
      createdAt:   now,
      expiresAt:   now + _thirtyDaysMs,
      paidAt:      0,
      payerId:     '',
    );
    final all = await load();
    all.insert(0, req);
    if (all.length > _maxCount) all.removeRange(_maxCount, all.length);
    await _persist(all);
    return req;
  }

  // ── Mark a request as paid ────────────────────────────────────────────────
  static Future<void> markPaid(String requestId, String payerId) async {
    final all = await load();
    for (final r in all) {
      if (r.requestId == requestId) {
        r.status  = 'paid';
        r.paidAt  = DateTime.now().millisecondsSinceEpoch;
        r.payerId = payerId;
        break;
      }
    }
    await _persist(all);
  }

  // ── Load all requests (newest first) ─────────────────────────────────────
  static Future<List<PaymentRequest>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw   = prefs.getString(_prefKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = (jsonDecode(raw) as List)
          .map((e) => PaymentRequest.fromMap(Map<String, dynamic>.from(e as Map)))
          .toList();
      // Auto-expire stale pending requests
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final r in list) {
        if (r.status == 'pending' && now > r.expiresAt) r.status = 'expired';
      }
      return list;
    } catch (_) {
      return [];
    }
  }

  // ── Delete one request (cancel or dismiss) ───────────────────────────────
  static Future<void> delete(String requestId) async {
    final all = await load();
    all.removeWhere((r) => r.requestId == requestId);
    await _persist(all);
  }

  // ── Delete all paid and expired requests ─────────────────────────────────
  static Future<void> pruneCompleted() async {
    final all = await load();
    all.removeWhere((r) => r.isPaid || r.isExpired);
    await _persist(all);
  }

  // ── Internal ──────────────────────────────────────────────────────────────
  static Future<void> _persist(List<PaymentRequest> list) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, jsonEncode(list.map((r) => r.toMap()).toList()));
  }
}
