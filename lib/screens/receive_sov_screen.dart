// lib/screens/receive_sov_screen.dart
// S3 — SOV Request: Receive SOV screen with QR code + payment request creation.
//
// FLOW:
//   Default  — shows citizen's Sovereign ID as a plain QR (any amount accepted)
//   Request  — citizen enters amount + memo → QR encodes sovreq:// deep link
//              with request_id for tracking → relay notifies when paid
//   History  — scrollable list of past requests with status chips

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import '../sov_node_sdk/payment_request_store.dart';
import '../sov_node_sdk/relay_connector.dart';

class ReceiveSovScreen extends StatefulWidget {
  final String sovereignId;

  const ReceiveSovScreen({super.key, required this.sovereignId});

  @override
  State<ReceiveSovScreen> createState() => _ReceiveSovScreenState();
}

class _ReceiveSovScreenState extends State<ReceiveSovScreen>
    with SingleTickerProviderStateMixin {
  static const _navy   = Color(0xFF0A1628);
  static const _gold   = Color(0xFFD4AF37);
  static const _cardBg = Color(0xFF0D1F3A);

  late final TabController _tabs;

  // ── QR state ──────────────────────────────────────────────────────────────
  // When null → show plain address QR. When set → show payment request QR.
  PaymentRequest? _activeRequest;

  // ── Create-request form ───────────────────────────────────────────────────
  final _amountCtrl  = TextEditingController();
  final _memoCtrl    = TextEditingController();
  bool  _creating    = false;
  String _createErr  = '';

  // ── History ───────────────────────────────────────────────────────────────
  List<PaymentRequest> _history = [];

  // ── Paid stream (relay push) ──────────────────────────────────────────────
  bool _justPaid = false;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _loadHistory();

    // Listen for SOV_REQUEST_PAID_NOTIFY from relay
    RelayConnector.paymentRequestPaid.listen((msg) {
      final reqId      = msg['request_id']  as String? ?? '';
      final payerId    = msg['payer_id']    as String? ?? '';
      final amtSeeds   = (msg['amount_seeds'] as num?)?.toInt() ?? 0;
      if (!mounted) return;

      // Mark paid briefly so the history banner can read it, then delete
      PaymentRequestStore.markPaid(reqId, payerId).then((_) async {
        // Switch to paid banner if this was the active QR
        final wasActive = _activeRequest?.requestId == reqId;
        if (wasActive && mounted) {
          setState(() { _justPaid = true; _activeRequest = null; });
        }

        // Delete from list — paid requests live in TX history now
        await PaymentRequestStore.delete(reqId);
        _loadHistory();

        // Show prominent notification banner
        if (!mounted) return;
        final amtStr = amtSeeds > 0
            ? '${(amtSeeds / 1000000).toStringAsFixed(amtSeeds % 1000000 == 0 ? 0 : 6)} SOV received'
            : 'Payment received';
        final shortPayer = payerId.length > 16
            ? '${payerId.substring(0, 10)}…${payerId.substring(payerId.length - 4)}'
            : payerId;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          duration: const Duration(seconds: 5),
          backgroundColor: const Color(0xFF0D3A1A),
          behavior: SnackBarBehavior.floating,
          content: Row(
            children: [
              const Icon(Icons.check_circle_rounded,
                  color: Colors.greenAccent, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(amtStr,
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 13)),
                    Text('From $shortPayer',
                        style: const TextStyle(
                            color: Colors.white60, fontSize: 11)),
                  ],
                ),
              ),
            ],
          ),
        ));
      });
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    _amountCtrl.dispose();
    _memoCtrl.dispose();
    super.dispose();
  }

  // ── Load history ──────────────────────────────────────────────────────────

  Future<void> _loadHistory() async {
    final h = await PaymentRequestStore.load();
    if (mounted) setState(() => _history = h);
  }

  // ── Create a tracked payment request ─────────────────────────────────────

  Future<void> _createRequest() async {
    final amtText = _amountCtrl.text.trim();
    final memo    = _memoCtrl.text.trim();

    double? amtSov;
    int amtSeeds = 0;
    if (amtText.isNotEmpty) {
      amtSov = double.tryParse(amtText);
      if (amtSov == null || amtSov < 0) {
        setState(() => _createErr = 'Enter a valid amount (or leave blank)');
        return;
      }
      amtSeeds = (amtSov * 1000000).round();
    }

    setState(() { _creating = true; _createErr = ''; });

    try {
      // Save locally first
      final req = await PaymentRequestStore.create(
        requesterId: widget.sovereignId,
        amountSeeds: amtSeeds,
        memo:        memo,
      );

      // Register on relay (non-fatal — local record always created)
      await RelayConnector.createPaymentRequest(
        requesterId: widget.sovereignId,
        requestId:   req.requestId,
        amountSeeds: amtSeeds,
        memo:        memo,
        expiresAt:   req.expiresAt,
      ).catchError((_) {});

      if (mounted) {
        setState(() {
          _activeRequest = req;
          _creating      = false;
          _justPaid      = false;
        });
        _amountCtrl.clear();
        _memoCtrl.clear();
        _loadHistory();
        _tabs.animateTo(0); // switch to QR tab
      }
    } catch (e) {
      if (mounted) setState(() { _creating = false; _createErr = e.toString(); });
    }
  }

  // ── Switch to plain address QR ────────────────────────────────────────────

  void _showPlainQr() => setState(() { _activeRequest = null; _justPaid = false; });

  // ── Current QR value ─────────────────────────────────────────────────────

  String get _qrData => _activeRequest != null
      ? _activeRequest!.toLink()
      : 'sovreq://${widget.sovereignId}';

  String get _qrLabel => _activeRequest != null
      ? (_activeRequest!.amountSeeds > 0
          ? '${(_activeRequest!.amountSeeds / 1000000).toStringAsFixed(6)} SOV requested'
          : 'Any amount')
      : 'Any amount';

  // ═════════════════════════════════════════════════════════════════════════
  // BUILD
  // ═════════════════════════════════════════════════════════════════════════

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
          'Receive SOV',
          style: TextStyle(
              color: Color(0xFFD4AF37),
              fontWeight: FontWeight.bold,
              fontSize: 18),
        ),
        bottom: TabBar(
          controller: _tabs,
          labelColor: _gold,
          unselectedLabelColor: Colors.white38,
          indicatorColor: _gold,
          tabs: const [
            Tab(text: 'QR Code'),
            Tab(text: 'New Request'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _buildQrTab(),
          _buildCreateTab(),
        ],
      ),
    );
  }

  // ── QR Tab ────────────────────────────────────────────────────────────────

  Widget _buildQrTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          // ── Paid banner ─────────────────────────────────────────────────
          if (_justPaid) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Colors.greenAccent.withAlpha(20),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.greenAccent.withAlpha(80)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.check_circle_rounded,
                      color: Colors.greenAccent, size: 20),
                  SizedBox(width: 10),
                  Text('Payment received!',
                      style: TextStyle(
                          color: Colors.greenAccent,
                          fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ],

          // ── QR card ─────────────────────────────────────────────────────
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: _cardBg,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: _gold.withAlpha(40)),
            ),
            child: Column(
              children: [
                // Request label
                if (_activeRequest != null) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: _gold.withAlpha(20),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: _gold.withAlpha(60)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.receipt_rounded,
                                color: Color(0xFFD4AF37), size: 13),
                            const SizedBox(width: 5),
                            Text(
                              'Payment Request  ·  $_qrLabel',
                              style: const TextStyle(
                                color: Color(0xFFD4AF37),
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: _showPlainQr,
                        child: const Icon(Icons.close_rounded,
                            color: Colors.white38, size: 16),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_activeRequest!.memo.isNotEmpty)
                    Text(
                      '"${_activeRequest!.memo}"',
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 12),
                    ),
                  const SizedBox(height: 16),
                ],

                // QR code
                QrImageView(
                  data: _qrData,
                  version: QrVersions.auto,
                  size: 220,
                  backgroundColor: Colors.white,
                  eyeStyle: const QrEyeStyle(
                    eyeShape: QrEyeShape.square,
                    color: Color(0xFF0A1628),
                  ),
                  dataModuleStyle: const QrDataModuleStyle(
                    dataModuleShape: QrDataModuleShape.square,
                    color: Color(0xFF0A1628),
                  ),
                ),
                const SizedBox(height: 16),

                // Sovereign ID (truncated + copy)
                GestureDetector(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: widget.sovereignId));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Sovereign ID copied'),
                        backgroundColor: Color(0xFF0D1F3A),
                        behavior: SnackBarBehavior.floating,
                        duration: Duration(seconds: 2),
                      ),
                    );
                  },
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        widget.sovereignId.length > 28
                            ? '${widget.sovereignId.substring(0, 14)}…${widget.sovereignId.substring(widget.sovereignId.length - 8)}'
                            : widget.sovereignId,
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 12,
                          fontFamily: 'monospace',
                        ),
                      ),
                      const SizedBox(width: 5),
                      const Icon(Icons.copy_rounded,
                          color: Colors.white24, size: 12),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // ── Action row ────────────────────────────────────────────────────
          Row(
            children: [
              Expanded(
                child: _ActionButton(
                  icon: Icons.copy_all_rounded,
                  label: 'Copy Link',
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: _qrData));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Payment link copied'),
                        backgroundColor: Color(0xFF0D1F3A),
                        behavior: SnackBarBehavior.floating,
                        duration: Duration(seconds: 2),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _ActionButton(
                  icon: Icons.share_rounded,
                  label: 'Share',
                  onTap: () {
                    final msg = _activeRequest != null &&
                            _activeRequest!.amountSeeds > 0
                        ? 'Pay me ${(_activeRequest!.amountSeeds / 1000000).toStringAsFixed(6)} SOV via SOV Network:\n$_qrData'
                        : 'Send me SOV via SOV Network:\n$_qrData';
                    Share.share(msg);
                  },
                ),
              ),
              if (_activeRequest == null) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: _ActionButton(
                    icon: Icons.receipt_long_rounded,
                    label: 'Request',
                    primary: true,
                    onTap: () => _tabs.animateTo(1),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 24),

          // ── History ───────────────────────────────────────────────────────
          if (_history.isNotEmpty) _buildHistory(),
        ],
      ),
    );
  }

  Widget _buildHistory() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'RECENT REQUESTS',
          style: TextStyle(
              color: Colors.white38, fontSize: 11, letterSpacing: 1.5),
        ),
        const SizedBox(height: 10),
        ..._history.take(10).map(_buildHistoryRow),
      ],
    );
  }

  Widget _buildHistoryRow(PaymentRequest r) {
    Color statusColor;
    String statusLabel;
    switch (r.status) {
      case 'paid':
        statusColor = Colors.greenAccent;
        statusLabel = 'Paid';
        break;
      case 'expired':
        statusColor = Colors.white30;
        statusLabel = 'Expired';
        break;
      default:
        statusColor = const Color(0xFFD4AF37);
        statusLabel = 'Pending';
    }

    final amount = r.amountSeeds > 0
        ? '${(r.amountSeeds / 1000000).toStringAsFixed(r.amountSeeds % 1000000 == 0 ? 0 : 6)} SOV'
        : 'Any amount';

    final ts = DateTime.fromMillisecondsSinceEpoch(r.createdAt);
    final diff = DateTime.now().difference(ts);
    final timeLabel = diff.inMinutes < 60
        ? '${diff.inMinutes}m ago'
        : diff.inHours < 24
            ? '${diff.inHours}h ago'
            : '${diff.inDays}d ago';

    return GestureDetector(
      onTap: r.isPending
          ? () {
              setState(() {
                _activeRequest = r;
                _justPaid      = false;
              });
              _tabs.animateTo(0);
            }
          : null,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: _cardBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withAlpha(10)),
        ),
        child: Row(
          children: [
            Icon(
              r.isPaid
                  ? Icons.check_circle_rounded
                  : r.isExpired
                      ? Icons.cancel_rounded
                      : Icons.hourglass_top_rounded,
              color: statusColor,
              size: 18,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    amount,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600),
                  ),
                  if (r.memo.isNotEmpty)
                    Text(
                      r.memo,
                      style: const TextStyle(
                          color: Colors.white38, fontSize: 11),
                      overflow: TextOverflow.ellipsis,
                    ),
                  Text(timeLabel,
                      style: const TextStyle(
                          color: Colors.white24, fontSize: 10)),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: statusColor.withAlpha(20),
                borderRadius: BorderRadius.circular(5),
                border: Border.all(color: statusColor.withAlpha(60)),
              ),
              child: Text(
                statusLabel,
                style: TextStyle(
                    color: statusColor,
                    fontSize: 10,
                    fontWeight: FontWeight.bold),
              ),
            ),
            // Cancel / dismiss button
            if (r.isPending || r.isExpired) ...[
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => _cancelRequest(r),
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: Colors.white.withAlpha(10),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.close_rounded,
                      color: Colors.white38, size: 14),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ── Cancel / dismiss a request ────────────────────────────────────────────

  Future<void> _cancelRequest(PaymentRequest r) async {
    // If it was the active QR, clear it
    if (_activeRequest?.requestId == r.requestId) {
      setState(() { _activeRequest = null; _justPaid = false; });
    }
    await PaymentRequestStore.delete(r.requestId);
    _loadHistory();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(r.isExpired ? 'Expired request removed' : 'Request cancelled'),
      backgroundColor: const Color(0xFF1A1A2E),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ));
  }

  // ── Create Request Tab ────────────────────────────────────────────────────

  Widget _buildCreateTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Explainer
          Container(
            padding: const EdgeInsets.all(16),
            margin: const EdgeInsets.only(bottom: 20),
            decoration: BoxDecoration(
              color: _gold.withAlpha(10),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _gold.withAlpha(40)),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline_rounded,
                    color: Color(0xFFD4AF37), size: 16),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Create a payment request to share a QR code or link that pre-fills the exact amount and memo for your payer. You\'ll be notified when payment arrives.',
                    style: TextStyle(
                        color: Colors.white54, fontSize: 12, height: 1.5),
                  ),
                ),
              ],
            ),
          ),

          // Amount field (optional)
          const Text('AMOUNT (SOV)',
              style: TextStyle(
                  color: Colors.white38, fontSize: 11, letterSpacing: 1.5)),
          const SizedBox(height: 8),
          TextField(
            controller: _amountCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.bold),
            decoration: InputDecoration(
              hintText: '0.000000  (leave blank for any amount)',
              hintStyle: TextStyle(
                  color: Colors.white.withAlpha(40), fontSize: 14),
              filled: true,
              fillColor: _cardBg,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.white.withAlpha(26)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.white.withAlpha(26)),
              ),
              focusedBorder: const OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(12)),
                borderSide: BorderSide(color: Color(0xFFD4AF37)),
              ),
              suffixText: 'SOV',
              suffixStyle: const TextStyle(
                  color: Color(0xFFD4AF37), fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 20),

          // Memo field (optional)
          const Text('MEMO',
              style: TextStyle(
                  color: Colors.white38, fontSize: 11, letterSpacing: 1.5)),
          const SizedBox(height: 8),
          TextField(
            controller: _memoCtrl,
            maxLength: 80,
            style: const TextStyle(color: Colors.white, fontSize: 14),
            decoration: InputDecoration(
              hintText: 'e.g. Lunch on Friday, Rent May, Invoice #42',
              hintStyle: TextStyle(
                  color: Colors.white.withAlpha(40), fontSize: 13),
              filled: true,
              fillColor: _cardBg,
              counterStyle:
                  const TextStyle(color: Colors.white24, fontSize: 10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.white.withAlpha(26)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.white.withAlpha(26)),
              ),
              focusedBorder: const OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(12)),
                borderSide: BorderSide(color: Color(0xFFD4AF37)),
              ),
            ),
          ),

          // Error
          if (_createErr.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(_createErr,
                style: const TextStyle(
                    color: Colors.redAccent, fontSize: 12)),
          ],
          const SizedBox(height: 28),

          // Create button
          SizedBox(
            width: double.infinity,
            height: 54,
            child: ElevatedButton.icon(
              icon: _creating
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          color: Colors.black, strokeWidth: 2))
                  : const Icon(Icons.qr_code_rounded, size: 20),
              label: Text(
                _creating ? 'Creating…' : 'Generate QR',
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.bold),
              ),
              onPressed: _creating ? null : _createRequest,
              style: ElevatedButton.styleFrom(
                backgroundColor: _gold,
                foregroundColor: Colors.black,
                disabledBackgroundColor: _gold.withAlpha(77),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                elevation: 0,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String   label;
  final VoidCallback onTap;
  final bool primary;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  @override
  Widget build(BuildContext context) {
    const bg      = Color(0xFF0D1F3A);
    const gold    = Color(0xFFD4AF37);
    const primBg  = Color(0xFF1A3A5C);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 46,
        decoration: BoxDecoration(
          color: primary ? primBg : bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: primary ? gold.withAlpha(100) : Colors.white.withAlpha(20)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: primary ? gold : Colors.white60, size: 16),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: primary ? gold : Colors.white60,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
