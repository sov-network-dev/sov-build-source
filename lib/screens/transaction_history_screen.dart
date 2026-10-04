// lib/screens/transaction_history_screen.dart
// ─────────────────────────────────────────────────────────────────────────────
// TRANSACTION HISTORY SCREEN
//
// Shows all transactions stored in TransactionStore (SharedPreferences).
// Data is local-only — no relay fetch.
// Pull-to-refresh re-reads from SharedPreferences.
// Tap any row to open a bottom sheet with full detail + copy buttons.
// ─────────────────────────────────────────────────────────────────────────────
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../sov_node_sdk/transaction_store.dart';

class TransactionHistoryScreen extends StatefulWidget {
  const TransactionHistoryScreen({super.key});

  @override
  State<TransactionHistoryScreen> createState() =>
      _TransactionHistoryScreenState();
}

class _TransactionHistoryScreenState extends State<TransactionHistoryScreen> {
  static const _navy   = Color(0xFF0A1628);
  static const _gold   = Color(0xFFB8960C);
  static const _cardBg = Color(0xFF0D1F3A);

  List<Map<String, dynamic>> _txs     = [];
  bool                       _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final list = await TransactionStore.load();
    if (mounted) setState(() { _txs = list; _loading = false; });
  }

  // ── helpers ─────────────────────────────────────────────────────────────────

  String _relativeTime(int ms) {
    final diff = DateTime.now()
        .difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (diff.inSeconds < 60)  return 'just now';
    if (diff.inMinutes == 1)  return '1 minute ago';
    if (diff.inMinutes < 60)  return '${diff.inMinutes} minutes ago';
    if (diff.inHours == 1)    return '1 hour ago';
    if (diff.inHours < 24)    return '${diff.inHours} hours ago';
    if (diff.inDays == 1)     return 'yesterday';
    if (diff.inDays < 30)     return '${diff.inDays} days ago';
    return _exactDate(ms);
  }

  String _exactDate(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${dt.year}-${_pad(dt.month)}-${_pad(dt.day)} '
        '${_pad(dt.hour)}:${_pad(dt.minute)}:${_pad(dt.second)}';
  }

  String _pad(int n) => n.toString().padLeft(2, '0');

  String _formatSov(int seeds) {
    final sov = seeds / 1000000;
    return sov >= 1
        ? '${sov.toStringAsFixed(2)} SOV'
        : '${sov.toStringAsFixed(6)} SOV';
  }

  String _formatSeeds(int seeds) {
    final s = seeds.abs().toString();
    final buf = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return '${buf.toString()} Seeds';
  }

  String _truncate(String s, int maxLen) {
    if (s.length <= maxLen) return s;
    return '${s.substring(0, maxLen ~/ 2)}…${s.substring(s.length - maxLen ~/ 2)}';
  }

  // Friendly name for a counterparty. System/pool accounts (operator payouts,
  // routed fees) carry synthetic SOV-POOL-* / SOV-SYSTEM-* IDs — show a readable
  // source/destination instead of a truncated raw string, so every in/out entry
  // makes its origin clear. Real citizen IDs fall through to the truncated form.
  String _counterpartyLabel(String id) {
    switch (id) {
      case 'SOV-POOL-WITNESS-OPERATOR': return 'Network Operator Pool';
      case 'SOV-POOL-CITIZEN-ENROLLMENT': return 'Enrollment Pool';
      case 'SOV-POOL-COMMUNITY-CONTRIBUTORS': return 'Community Pool';
      case 'SOV-EXCHANGE-ESCROW': return 'SOV Exchange';
      case 'SOV-SHIELD': return 'SOV Exchange';
      case 'SOV-SYSTEM': return 'SOV Network';
    }
    if (id.startsWith('SOV-POOL-')) return 'Network Pool';
    return _truncate(id, 20);
  }

  // Whether this counterparty is a system/pool account (shown non-monospace).
  bool _isSystemAccount(String id) =>
      id.startsWith('SOV-POOL-') || id.startsWith('SOV-SYSTEM') ||
      id.startsWith('SOV-EXCHANGE') || id == 'SOV-SHIELD';

  // ── per-type colour / icon / label ──────────────────────────────────────────

  IconData _icon(String type) {
    switch (type) {
      case 'sent':             return Icons.arrow_upward_rounded;
      case 'received':         return Icons.arrow_downward_rounded;
      case 'enrollment_reward': return Icons.star_rounded;
      default:                 return Icons.swap_horiz_rounded;
    }
  }

  Color _accentColor(String type) {
    switch (type) {
      case 'sent':             return const Color(0xFFFF6B6B);   // coral-red
      case 'received':         return Colors.greenAccent;
      case 'enrollment_reward': return _gold;
      default:                 return Colors.white54;
    }
  }

  String _typeLabel(String type) {
    switch (type) {
      case 'sent':             return 'Sent';
      case 'received':         return 'Received';
      case 'enrollment_reward': return 'Enrollment Reward';
      default:                 return type;
    }
  }

  // Title for a transaction. Pool/system counterparties get a descriptive name
  // (Operator Payout, Platform Fee, …) so the history always states WHY funds
  // moved and to/from WHERE — not a bare "Sent"/"Received". Falls back to the
  // plain direction label for ordinary citizen-to-citizen transfers.
  String _txTitle(Map<String, dynamic> tx) {
    final type = tx['type'] as String? ?? '';
    final cp   = tx['counterparty_id'] as String? ?? '';
    final memo = (tx['memo'] as String? ?? '').toLowerCase();
    // Exchange money movements (memo-driven, works from either party's side).
    if (memo.contains('exchange')) {
      if (memo.contains('network fee')) return 'Exchange Fee';
      if (memo.contains('purchase')) return 'Exchange Purchase';
      if (memo.contains('escrowed') || memo.contains('listing')) return 'Exchange Listing';
      final refund = memo.contains('refund') || memo.contains('cancelled') ||
                     memo.contains('expired') || memo.contains('returned');
      if (refund) return 'Exchange Refund';
      return type == 'received' ? 'Exchange Credit' : 'Exchange Debit';
    }
    if (cp == 'SOV-POOL-WITNESS-OPERATOR') {
      if (type == 'received') return 'Operator Payout';
      if (memo.contains('reversal'))       return 'Payout Reversal';
      if (memo.contains('platform'))       return 'Platform Fee';
      return 'Network Fee';
    }
    if (_isSystemAccount(cp)) {
      return type == 'received' ? 'Network Reward' : 'Network Fee';
    }
    return _typeLabel(type);
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'confirmed': return Colors.greenAccent;
      case 'pending':   return Colors.orange;
      case 'failed':    return Colors.redAccent;
      default:          return Colors.white38;
    }
  }

  // ── Build ────────────────────────────────────────────────────────────────────

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
        title: const Text(
          'Transaction History',
          style: TextStyle(
              color: Color(0xFFB8960C),
              fontWeight: FontWeight.bold,
              fontSize: 18),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Colors.white38),
            onPressed: _load,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        color: _gold,
        backgroundColor: _cardBg,
        child: _loading
            ? const Center(
                child: CircularProgressIndicator(
                    color: Color(0xFFB8960C), strokeWidth: 1.5))
            : _txs.isEmpty
                ? _buildEmpty()
                : _buildList(),
      ),
    );
  }

  Widget _buildList() {
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      itemCount: _txs.length,
      itemBuilder: (_, i) => _buildCard(_txs[i]),
    );
  }

  Widget _buildCard(Map<String, dynamic> tx) {
    final type          = tx['type']           as String? ?? 'unknown';
    final amountSeeds   = (tx['amount_seeds']  as num?)?.toInt()  ?? 0;
    final counterparty  = tx['counterparty_id'] as String? ?? '';
    final timestamp     = (tx['timestamp']     as num?)?.toInt()  ?? 0;
    final status        = tx['status']         as String? ?? 'confirmed';

    final accent        = _accentColor(type);
    final isSystem      = _isSystemAccount(counterparty);
    final short         = _counterpartyLabel(counterparty);

    return GestureDetector(
      onTap: () => _showDetail(tx),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: _cardBg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withAlpha(12)),
        ),
        child: Row(
          children: [
            // Direction icon
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: accent.withAlpha(20),
                border: Border.all(color: accent.withAlpha(60)),
              ),
              child: Icon(_icon(type), color: accent, size: 20),
            ),
            const SizedBox(width: 12),

            // Middle: type + counterparty + time
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _txTitle(tx),
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 13),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    short.isEmpty ? '—' : short,
                    style: TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
                        fontFamily: isSystem ? null : 'monospace'),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _relativeTime(timestamp),
                    style: const TextStyle(color: Colors.white24, fontSize: 10),
                  ),
                ],
              ),
            ),

            // Right: amount + status dot
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  _formatSov(amountSeeds),
                  style: TextStyle(
                      color: accent,
                      fontWeight: FontWeight.bold,
                      fontSize: 13),
                ),
                const SizedBox(height: 2),
                Text(
                  _formatSeeds(amountSeeds),
                  style: const TextStyle(
                      color: Colors.white38, fontSize: 10),
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _statusColor(status),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      status,
                      style: TextStyle(
                          color: _statusColor(status),
                          fontSize: 10,
                          fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(32),
      children: [
        Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.receipt_long_outlined,
                  color: Colors.white.withAlpha(50), size: 52),
              const SizedBox(height: 16),
              const Text(
                'No transactions yet',
                style: TextStyle(color: Colors.white60, fontSize: 15),
              ),
              const SizedBox(height: 8),
              const Text(
                'Send SOV or enroll to see your history',
                style: TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── Bottom sheet detail ──────────────────────────────────────────────────────

  void _showDetail(Map<String, dynamic> tx) {
    final type         = tx['type']            as String? ?? 'unknown';
    final amountSeeds  = (tx['amount_seeds']   as num?)?.toInt()  ?? 0;
    final counterparty = tx['counterparty_id'] as String? ?? '';
    final txHash       = tx['tx_hash']         as String? ?? '';
    final txId         = tx['tx_id']           as String? ?? '';
    final timestamp    = (tx['timestamp']      as num?)?.toInt()  ?? 0;
    final status       = tx['status']          as String? ?? 'confirmed';
    final relayId      = tx['relay_id']        as String? ?? '';
    final answeredBy   = tx['answered_by']     as String? ?? '';
    final memo         = tx['memo']            as String? ?? '';

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0D1F3A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      isScrollControlled: true,
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag handle
            Container(
              width: 40, height: 4,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),

            // Header
            Row(
              children: [
                Container(
                  width: 44, height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _accentColor(type).withAlpha(20),
                    border: Border.all(
                        color: _accentColor(type).withAlpha(60)),
                  ),
                  child: Icon(_icon(type),
                      color: _accentColor(type), size: 22),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _txTitle(tx),
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 16),
                    ),
                    Text(
                      _exactDate(timestamp),
                      style: const TextStyle(
                          color: Colors.white38, fontSize: 11),
                    ),
                  ],
                ),
              ],
            ),

            const SizedBox(height: 20),
            Divider(height: 1, color: Colors.white.withAlpha(15)),
            const SizedBox(height: 16),

            // Amount
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  _formatSov(amountSeeds),
                  style: TextStyle(
                      color: _accentColor(type),
                      fontSize: 28,
                      fontWeight: FontWeight.bold),
                ),
                const SizedBox(width: 8),
                Text(
                  _formatSeeds(amountSeeds),
                  style: const TextStyle(
                      color: Colors.white38, fontSize: 12),
                ),
              ],
            ),

            const SizedBox(height: 20),

            // Detail rows
            _detailSheetRow(
              label: 'Status',
              valueWidget: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 7, height: 7,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _statusColor(status),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(status,
                      style: TextStyle(
                          color: _statusColor(status),
                          fontSize: 12,
                          fontWeight: FontWeight.w600)),
                ],
              ),
            ),
            const SizedBox(height: 10),

            if (counterparty.isNotEmpty)
              _isSystemAccount(counterparty)
                  // System/pool source or destination — show the friendly name.
                  ? _detailSheetRow(
                      label: type == 'sent' ? 'To' : 'Source',
                      valueWidget: Text(
                        _counterpartyLabel(counterparty),
                        style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                            fontWeight: FontWeight.w600),
                      ),
                    )
                  : _detailSheetRowCopyable(
                      label: type == 'sent' ? 'Recipient ID' : 'From',
                      value: counterparty),

            if (memo.isNotEmpty) ...[
              const SizedBox(height: 10),
              _detailSheetRowCopyable(label: 'Memo', value: memo),
            ],

            if (txHash.isNotEmpty) ...[
              const SizedBox(height: 10),
              _detailSheetRowCopyable(label: 'TX Hash', value: txHash),
            ],

            if (txId.isNotEmpty && txId != txHash) ...[
              const SizedBox(height: 10),
              _detailSheetRowCopyable(label: 'TX ID', value: txId),
            ],

            if (relayId.isNotEmpty) ...[
              const SizedBox(height: 10),
              _detailSheetRow(
                label: 'Relay',
                valueWidget: Text(
                  _truncate(relayId, 28),
                  style: const TextStyle(
                      color: Colors.white60,
                      fontSize: 12,
                      fontFamily: 'monospace'),
                ),
              ),
            ],

            if (answeredBy.isNotEmpty) ...[
              const SizedBox(height: 10),
              _detailSheetRow(
                label: 'Confirmed by',
                valueWidget: Text(
                  _truncate(answeredBy, 28),
                  style: const TextStyle(
                      color: Colors.white60,
                      fontSize: 12,
                      fontFamily: 'monospace'),
                ),
              ),
            ],

            const SizedBox(height: 24),

            // Close
            SizedBox(
              width: double.infinity,
              height: 50,
              child: OutlinedButton(
                onPressed: () => Navigator.pop(context),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _gold,
                  side: BorderSide(color: _gold.withAlpha(80)),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                child: const Text('Close',
                    style: TextStyle(fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _detailSheetRow({
    required String label,
    required Widget valueWidget,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 100,
          child: Text(label,
              style: const TextStyle(color: Colors.white38, fontSize: 12)),
        ),
        Expanded(child: valueWidget),
      ],
    );
  }

  Widget _detailSheetRowCopyable({
    required String label,
    required String value,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 100,
          child: Text(label,
              style: const TextStyle(color: Colors.white38, fontSize: 12)),
        ),
        Expanded(
          child: GestureDetector(
            onTap: () {
              Clipboard.setData(ClipboardData(text: value));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('$label copied'),
                  duration: const Duration(seconds: 2),
                  backgroundColor: _cardBg,
                ),
              );
            },
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    value,
                    style: const TextStyle(
                        color: Colors.white60,
                        fontSize: 12,
                        fontFamily: 'monospace'),
                  ),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.copy_rounded,
                    size: 14, color: Colors.white24),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
