// lib/screens/exchange_screen.dart
// ─────────────────────────────────────────────────────────────────────────────
// Exchange Screen — P2P SOV escrow marketplace
//
// TAB 1: Browse open orders from the relay — fill with one tap
// TAB 2: My Orders — list new order via bottom sheet, view own open orders
// ─────────────────────────────────────────────────────────────────────────────
import 'dart:async';
import 'package:flutter/material.dart';
import '../sov_node_sdk/relay_connector.dart';
import '../sov_node_sdk/draft_manager.dart';
import '../sov_node_sdk/draft_keys.dart';

/// Top-level helper: convert raw `sov_amount` field (seeds integer from relay)
/// into a display-ready "X.XX SOV" string. Accepts int, num, or numeric string.
/// 1 SOV = 1,000,000 seeds. Used by every exchange tile and dialog so the
/// raw seed integer is never shown to citizens.
String fmtSovFromSeeds(dynamic raw) {
  if (raw == null) return '0 SOV';
  num seeds;
  if (raw is num) {
    seeds = raw;
  } else {
    seeds = num.tryParse(raw.toString()) ?? 0;
  }
  final sov = seeds / 1000000;
  if (sov >= 100)  return '${sov.toStringAsFixed(0)} SOV';
  if (sov >= 1)    return '${sov.toStringAsFixed(2)} SOV';
  return '${sov.toStringAsFixed(6)} SOV';
}

class ExchangeScreen extends StatefulWidget {
  final String sovereignId;
  final int    seeds;

  const ExchangeScreen({
    super.key,
    required this.sovereignId,
    required this.seeds,
  });

  @override
  State<ExchangeScreen> createState() => _ExchangeScreenState();
}

class _ExchangeScreenState extends State<ExchangeScreen>
    with SingleTickerProviderStateMixin {

  static const _navy   = Color(0xFF0A1628);
  static const _gold   = Color(0xFFB8960C);
  static const _cardBg = Color(0xFF0D1F3A);
  static const _teal   = Color(0xFF006B5E);

  late final TabController _tabs;

  // ── Browse tab state ────────────────────────────────────────────────────────
  List<Map<String, dynamic>> _orders        = [];
  bool                       _loadingOrders = true;
  String                     _ordersError   = '';

  // ── Push-subscribe subscriptions (live-update layer on top of initial load) ─
  StreamSubscription<Map<String, dynamic>>? _exchangeStateSub;
  StreamSubscription<Map<String, dynamic>>? _exchangeUpdateSub;
  StreamSubscription<void>?                 _relayReconnectSub;

  // ── My Orders tab state — INDEPENDENT from Browse loading ──────────────────
  List<Map<String, dynamic>> _myOrders      = [];
  List<Map<String, dynamic>> _myFilledOrders = [];
  bool                       _loadingMyOrders = false;  // separate from _loadingOrders
  bool                       _loadingFills    = false;

  // ── Order Book tab state (S13) ──────────────────────────────────────────────
  List<Map<String, dynamic>> _orderBookBids  = [];
  List<Map<String, dynamic>> _priceHistory   = [];
  bool                       _loadingBook    = false;

  // ── Exchange order form controllers (class-level for draft persistence) ────
  final _exchangeAmountCtrl = TextEditingController();
  final _exchangeDescCtrl   = TextEditingController();
  final _exchangePaymentCtrl = TextEditingController();

  // Live spendable balance. widget.seeds is only a SNAPSHOT passed at construction;
  // if it is stale/low (e.g. the home balance hadn't loaded yet) every listing
  // would fail the client-side "Insufficient balance" guard. We refresh from the
  // relay on init and use _liveSeeds for the listing validation + sheet header.
  int _liveSeeds = 0;

  @override
  void initState() {
    super.initState();
    _liveSeeds = widget.seeds;
    _refreshLiveBalance();
    _tabs = TabController(length: 3, vsync: this);
    _tabs.addListener(() {
      if (_tabs.index == 1) {
        _loadMyListings();
        _loadMyFilledOrders();
      } else if (_tabs.index == 2) {
        _loadOrderBook();
      }
    });

    // ── EXCHANGE_STATE: relay sends this immediately after EXCHANGE_SUBSCRIBE,
    // and again whenever we resubscribe (pull-to-refresh).  This is the ONLY
    // path that populates _orders — no competing sendAndWait initial load.
    _exchangeStateSub = RelayConnector.exchangeStateStream.listen((msg) {
      if (!mounted) return;
      final raw = msg['orders'] as List? ?? [];
      setState(() {
        _orders        = List<Map<String, dynamic>>.from(raw);
        _loadingOrders = false;
        _ordersError   = '';
      });
    });

    _exchangeUpdateSub = RelayConnector.exchangeUpdateStream.listen((msg) {
      if (!mounted) return;
      final event = msg['event'] as String? ?? '';
      final order = msg['order'] as Map<String, dynamic>?;
      if (order == null) return;
      final orderId = order['order_id'] as String?;
      if (orderId == null) return;
      setState(() {
        if (event == 'new' || event == 'updated') {
          final idx = _orders.indexWhere((o) => o['order_id'] == orderId);
          if (idx >= 0) {
            _orders[idx] = order;
          } else if (event == 'new') {
            _orders.insert(0, order);
          }
        } else if (event == 'removed') {
          _orders.removeWhere((o) => o['order_id'] == orderId);
        }
      });
      if ((order['seller_id'] as String?) == widget.sovereignId ||
          (order['filled_by'] as String?) == widget.sovereignId) {
        _loadMyListings();
        _loadMyFilledOrders();
      }
    });

    // ── Relay reconnect: resubscribe so relay pushes a fresh EXCHANGE_STATE.
    _relayReconnectSub = RelayConnector.relayConnected.listen((_) {
      if (mounted) RelayConnector.subscribeExchange();
    });

    // ── Initial load: subscribe once.  The relay immediately responds with
    // EXCHANGE_STATE (full order list).  subscribeExchange() already has an
    // await-connect() guard so this never fires before HELLO is processed.
    // _loadingOrders starts true; the EXCHANGE_STATE listener clears it.
    RelayConnector.subscribeExchange();
    _loadMyListings();
    _loadMyFilledOrders();

    _loadExchangeDrafts();
    _loadOrderBook();
  }

  Future<void> _loadExchangeDrafts() async {
    final amt  = await DraftManager.load(DraftKeys.exchangeAmount);
    final desc = await DraftManager.load(DraftKeys.exchangeDescription);
    if (!mounted) return;
    if (amt.isNotEmpty)  _exchangeAmountCtrl.text = amt;
    if (desc.isNotEmpty) _exchangeDescCtrl.text   = desc;
  }

  @override
  void dispose() {
    _exchangeStateSub?.cancel();
    _exchangeUpdateSub?.cancel();
    _relayReconnectSub?.cancel();
    RelayConnector.unsubscribeExchange();
    _tabs.dispose();
    _exchangeAmountCtrl.dispose();
    _exchangeDescCtrl.dispose();
    _exchangePaymentCtrl.dispose();
    super.dispose();
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  String _formatBalance(int seeds) {
    double sov = seeds / 1000000;
    if (sov >= 1) return '${sov.toStringAsFixed(2)} SOV';
    return '${sov.toStringAsFixed(6)} SOV';
  }

  Color _reputationColor(num score) {
    if (score >= 80) return const Color(0xFF4CAF50);
    if (score >= 50) return const Color(0xFFFFB300);
    return const Color(0xFFEF5350);
  }

  String _expiresIn(num expiresAt) {
    final diff = expiresAt - DateTime.now().millisecondsSinceEpoch;
    if (diff <= 0) return 'Expired';
    final days = (diff / 86400000).floor();
    if (days >= 1) return '$days day${days == 1 ? '' : 's'}';
    final hours = (diff / 3600000).floor();
    return '$hours hr${hours == 1 ? '' : 's'}';
  }

  // ── Data loading ─────────────────────────────────────────────────────────────

  /// Pull-to-refresh on Browse tab — resubscribe so relay sends a fresh EXCHANGE_STATE.
  void _resubscribeOrders() {
    if (!mounted) return;
    setState(() { _loadingOrders = true; _ordersError = ''; });
    RelayConnector.subscribeExchange();
    // EXCHANGE_STATE listener will set _loadingOrders = false when data arrives.
  }

  /// Load this citizen's own listings — manages its own _loadingMyOrders state.
  Future<void> _loadMyListings() async {
    if (!mounted) return;
    setState(() => _loadingMyOrders = true);
    try {
      if (!RelayConnector.isConnected) await RelayConnector.connect();
      final listings = await RelayConnector.viewMyListings(widget.sovereignId);
      if (!mounted) return;
      setState(() { _myOrders = listings; _loadingMyOrders = false; });
    } catch (_) {
      if (mounted) setState(() { _loadingMyOrders = false; });
    }
  }

  Future<void> _loadMyFilledOrders() async {
    if (!mounted) return;
    setState(() => _loadingFills = true);
    try {
      if (!RelayConnector.isConnected) await RelayConnector.connect();
      final fills = await RelayConnector.viewMyFilledOrders(widget.sovereignId);
      if (!mounted) return;
      setState(() { _myFilledOrders = fills; _loadingFills = false; });
    } catch (_) {
      if (mounted) setState(() => _loadingFills = false);
    }
  }

  // ── Order Book (S13) ─────────────────────────────────────────────────────────

  Future<void> _loadOrderBook() async {
    if (!mounted || _loadingBook) return;
    setState(() => _loadingBook = true);
    try {
      if (!RelayConnector.isConnected) await RelayConnector.connect();
      final bookRes  = await RelayConnector.getOrderBook(limit: 20);
      final histRes  = await RelayConnector.getPriceHistory(limit: 50);
      if (!mounted) return;
      setState(() {
        _orderBookBids = (bookRes?['bids'] as List?)?.cast<Map<String, dynamic>>() ?? [];
        _priceHistory  = (histRes?['fills'] as List?)?.cast<Map<String, dynamic>>() ?? [];
        _loadingBook   = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingBook = false);
    }
  }

  // ── Cancel order ─────────────────────────────────────────────────────────────

  Future<void> _cancelOrder(Map<String, dynamic> order) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Cancel Order',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: const Text(
          'Your escrowed SOV will be refunded immediately.',
          style: TextStyle(color: Colors.white54, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep it', style: TextStyle(color: Colors.white38)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red.shade900, foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Cancel Order', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    final result = await RelayConnector.cancelExchangeOrder(
        order['order_id'] as String, widget.sovereignId);
    if (!mounted) return;

    if (result['success'] == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Order cancelled — SOV refunded'),
          backgroundColor: Color(0xFF006B5E),
          behavior: SnackBarBehavior.floating,
        ),
      );
      _resubscribeOrders();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result['error'] as String? ?? 'Cancel failed'),
          backgroundColor: Colors.red.shade900,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  // ── Edit order bottom sheet ───────────────────────────────────────────────────

  void _showEditOrderSheet(Map<String, dynamic> order) {
    final descCtrl    = TextEditingController(text: (order['asking_description'] ?? order['memo']) as String? ?? '');
    int selectedDays  = 7;
    bool submitting   = false;
    String sheetError = '';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _cardBg,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(
            24, 20, 24, MediaQuery.of(ctx).viewInsets.bottom + 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(child: Container(width: 40, height: 4,
                  decoration: BoxDecoration(color: Colors.white24,
                      borderRadius: BorderRadius.circular(2)))),
              const SizedBox(height: 16),
              const Text('Edit Order',
                  style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text('${fmtSovFromSeeds(order['sov_amount'])} in escrow',
                  style: const TextStyle(color: Color(0xFFB8960C), fontSize: 13)),
              const SizedBox(height: 20),

              const Text('WHAT YOU WANT IN RETURN',
                  style: TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 1.5)),
              const SizedBox(height: 8),
              TextField(
                controller: descCtrl,
                maxLines: 2,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  filled: true, fillColor: _navy,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: Colors.white.withAlpha(26))),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: Colors.white.withAlpha(26))),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: Color(0xFFB8960C))),
                ),
              ),
              const SizedBox(height: 16),

              const Text('EXTEND EXPIRY BY',
                  style: TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 1.5)),
              const SizedBox(height: 8),
              Row(
                children: [1, 7, 14, 30].map((d) {
                  final sel = selectedDays == d;
                  return Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: GestureDetector(
                        onTap: () => setSheet(() => selectedDays = d),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          decoration: BoxDecoration(
                            color: sel ? _gold.withAlpha(26) : _navy,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: sel ? _gold : Colors.white.withAlpha(26))),
                          child: Column(children: [
                            Text('$d', style: TextStyle(
                                color: sel ? _gold : Colors.white,
                                fontSize: 16, fontWeight: FontWeight.bold)),
                            Text(d == 1 ? 'day' : 'days', style: TextStyle(
                                color: sel ? _gold.withAlpha(179) : Colors.white38,
                                fontSize: 10)),
                          ]),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),

              if (sheetError.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(sheetError, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
              ],

              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity, height: 50,
                child: ElevatedButton(
                  onPressed: submitting ? null : () async {
                    final newDesc = descCtrl.text.trim();
                    if (newDesc.isEmpty) {
                      setSheet(() => sheetError = 'Description cannot be empty');
                      return;
                    }
                    setSheet(() { submitting = true; sheetError = ''; });
                    final result = await RelayConnector.editExchangeOrder(
                      order['order_id'] as String, widget.sovereignId,
                      newDescription: newDesc, expiresInDays: selectedDays,
                    );
                    if (result['success'] == true) {
                      descCtrl.dispose();
                      if (ctx.mounted) Navigator.pop(ctx);
                      _resubscribeOrders();
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Order updated'),
                            backgroundColor: Color(0xFF006B5E),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      }
                    } else {
                      setSheet(() {
                        sheetError = result['error'] as String? ?? 'Update failed';
                        submitting = false;
                      });
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _gold,
                    disabledBackgroundColor: _gold.withAlpha(77),
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    elevation: 0,
                  ),
                  child: submitting
                      ? const SizedBox(width: 20, height: 20,
                          child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2.5))
                      : const Text('Save Changes',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Raise dispute ────────────────────────────────────────────────────────────

  Future<void> _raiseDispute(Map<String, dynamic> order) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Raise Dispute',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: const Text(
          'This will lock the escrowed SOV and open a case in the Justice Council. '
          'A panel of citizen jurors will review the evidence and decide the outcome.\n\n'
          'A 10 SOV bond is required to file.',
          style: TextStyle(color: Colors.white54, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white38)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF7B1A1A), foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Raise Dispute', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    final result = await RelayConnector.raiseExchangeDispute(
        order['order_id'] as String, widget.sovereignId);
    if (!mounted) return;

    if (result['success'] == true) {
      final caseId = result['case_id'] as String? ?? '';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(caseId.isNotEmpty
              ? 'Dispute filed — case $caseId assigned to Justice Council'
              : 'Dispute filed — Justice Council will review'),
          backgroundColor: const Color(0xFF7B1A1A),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 5),
        ),
      );
      _resubscribeOrders();
      _loadMyFilledOrders();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result['error'] as String? ?? 'Dispute filing failed'),
          backgroundColor: Colors.red.shade900,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  // ── Request refund ───────────────────────────────────────────────────────────

  Future<void> _requestRefund(Map<String, dynamic> order) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Request Refund',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: const Text(
          'The delivery window has passed. Requesting a refund will return '
          'the escrowed SOV to the seller.',
          style: TextStyle(color: Colors.white54, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white38)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: _teal, foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Request Refund', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    final result = await RelayConnector.requestExchangeRefund(
        order['order_id'] as String, widget.sovereignId);
    if (!mounted) return;

    if (result['success'] == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Refund processed — SOV returned to seller'),
          backgroundColor: Color(0xFF006B5E),
          behavior: SnackBarBehavior.floating,
        ),
      );
      _resubscribeOrders();
      _loadMyFilledOrders();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result['error'] as String? ?? 'Refund failed'),
          backgroundColor: Colors.red.shade900,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  // ── Open trade-specific chat (isolated from SOV Speak) ───────────────────────

  void _openChat(String counterpartyId, {String? orderId, bool isSellerView = false}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ExchangeChatSheet(
        orderId:         orderId ?? 'direct_$counterpartyId',
        mySovId:         widget.sovereignId,
        counterpartyId:  counterpartyId,
        isSellerView:    isSellerView,
      ),
    );
  }

  // ── Seller negotiation inbox: per-buyer threads for one of my orders ─────────
  void _openSellerInbox(String orderId) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _SellerInboxSheet(
        orderId: orderId,
        mySovId: widget.sovereignId,
        onOpenThread: (buyerId) {
          Navigator.pop(context); // close the inbox, open the buyer's thread
          _openChat(buyerId, orderId: orderId, isSellerView: true);
        },
      ),
    );
  }

  // ── Fill order ───────────────────────────────────────────────────────────────

  Future<void> _fillOrder(Map<String, dynamic> order) async {
    final orderId   = order['order_id'] as String?;
    final sovAmount = fmtSovFromSeeds(order['sov_amount']);  // pre-formatted "X.XX SOV"
    final desc      = (order['asking_description'] ?? order['memo']) as String? ?? '';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Fill Order', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('You are agreeing to provide:', style: TextStyle(color: Colors.white.withAlpha(153))),
            const SizedBox(height: 8),
            Text('"$desc"',
                style: const TextStyle(color: Colors.white, fontStyle: FontStyle.italic)),
            const SizedBox(height: 12),
            Text('In exchange for $sovAmount held in escrow.',
                style: const TextStyle(color: Color(0xFFB8960C))),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white38)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: _gold, foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Fill Order', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirmed != true || orderId == null) return;

    final result = await RelayConnector.fillExchangeOrder(orderId, widget.sovereignId);
    if (!mounted) return;

    if (result['success'] == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Order filled — deliver the item to release escrow'),
          backgroundColor: Color(0xFF006B5E),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 4),
        ),
      );
      _resubscribeOrders();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result['error'] as String? ?? 'Fill failed'),
          backgroundColor: Colors.red.shade900,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  // ── List new order bottom sheet ───────────────────────────────────────────────

  /// Pull the live spendable balance from the relay so the listing validation
  /// uses a current value rather than the constructor snapshot. Falls back to
  /// the snapshot if the query fails (never lowers below it on error).
  Future<void> _refreshLiveBalance() async {
    try {
      if (!RelayConnector.isConnected) await RelayConnector.connect();
      final seeds = await RelayConnector.queryBalance(widget.sovereignId);
      if (!mounted) return;
      if (seeds > 0) setState(() => _liveSeeds = seeds);
    } catch (_) { /* keep snapshot on failure */ }
  }

  void _showListOrderSheet({bool serviceMode = false}) {
    // Refresh balance when opening the sheet so the guard uses a current value.
    _refreshLiveBalance();
    // serviceMode (PI-33): reframes this same sheet as "List a Service" and
    // prepends the [SERVICE] convention to the description on submit, so a
    // certified citizen's service offer is just an Exchange listing — escrow,
    // fill, dispute all reuse the live trade flow. No new protocol.
    // Use class-level controllers so drafts survive app backgrounding.
    final amountCtrl = _exchangeAmountCtrl;
    final descCtrl   = _exchangeDescCtrl;
    final paymentCtrl = _exchangePaymentCtrl;
    int selectedDays = 7;
    bool submitting  = false;
    String sheetError = '';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _cardBg,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(
            24, 20, 24, MediaQuery.of(ctx).viewInsets.bottom + 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Handle
              Center(
                child: Container(
                  width: 40, height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const SizedBox(height: 16),
              Text(serviceMode ? 'List a Service' : 'List New Order',
                  style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text('Available: ${_formatBalance(_liveSeeds)}',
                  style: const TextStyle(color: Color(0xFFB8960C), fontSize: 13)),
              const SizedBox(height: 20),

              // Amount
              Text(serviceMode ? 'YOUR PRICE (SOV)' : 'SOV AMOUNT', style: const TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 1.5)),
              const SizedBox(height: 8),
              TextField(
                key: serviceMode ? const ValueKey('serviceAmountField') : null,
                controller: amountCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                onChanged: (v) => DraftManager.save(DraftKeys.exchangeAmount, v),
                decoration: InputDecoration(
                  hintText: '0.00',
                  hintStyle: TextStyle(color: Colors.white.withAlpha(51), fontSize: 18),
                  filled: true,
                  fillColor: _navy,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: Colors.white.withAlpha(26))),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: Colors.white.withAlpha(26))),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: Color(0xFFB8960C))),
                  suffixText: 'SOV',
                  suffixStyle: const TextStyle(color: Color(0xFFB8960C), fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(height: 16),

              // Description
              Text(serviceMode ? 'DESCRIBE YOUR SERVICE' : 'WHAT YOU WANT IN RETURN',
                  style: const TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 1.5)),
              const SizedBox(height: 8),
              TextField(
                key: serviceMode ? const ValueKey('serviceDescField') : null,
                controller: descCtrl,
                maxLines: 2,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                onChanged: (v) => DraftManager.save(DraftKeys.exchangeDescription, v),
                decoration: InputDecoration(
                  hintText: serviceMode
                      ? 'e.g. "Plumbing repair, 1hr · cert: Plumbing"'
                      : 'e.g. "1kg maize flour" or "data bundle 2GB"',
                  hintStyle: TextStyle(color: Colors.white.withAlpha(51), fontSize: 13),
                  filled: true,
                  fillColor: _navy,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: Colors.white.withAlpha(26))),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: Colors.white.withAlpha(26))),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: Color(0xFFB8960C))),
                ),
              ),
              const SizedBox(height: 16),

              // Stage 2: how the seller accepts off-platform fiat payment. Shown
              // to buyers so they know how to pay before negotiating.
              const Text('HOW YOU ACCEPT PAYMENT (optional)',
                  style: TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 1.5)),
              const SizedBox(height: 8),
              TextField(
                controller: paymentCtrl,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'e.g. "Bank transfer, Mobile money, Cash"',
                  hintStyle: TextStyle(color: Colors.white.withAlpha(51), fontSize: 13),
                  filled: true,
                  fillColor: _navy,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: Colors.white.withAlpha(26))),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: Colors.white.withAlpha(26))),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: Color(0xFFB8960C))),
                ),
              ),
              const SizedBox(height: 16),

              // Expiry
              const Text('EXPIRES IN',
                  style: TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 1.5)),
              const SizedBox(height: 8),
              Row(
                children: [1, 7, 14, 30].map((d) {
                  final sel = selectedDays == d;
                  return Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: GestureDetector(
                        onTap: () => setSheet(() => selectedDays = d),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          decoration: BoxDecoration(
                            color: sel ? _gold.withAlpha(26) : _navy,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                                color: sel ? _gold : Colors.white.withAlpha(26))),
                          child: Column(children: [
                            Text('$d', style: TextStyle(
                                color: sel ? _gold : Colors.white,
                                fontSize: 16, fontWeight: FontWeight.bold)),
                            Text(d == 1 ? 'day' : 'days', style: TextStyle(
                                color: sel ? _gold.withAlpha(179) : Colors.white38,
                                fontSize: 10)),
                          ]),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),

              if (sheetError.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(sheetError, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
              ],

              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  key: serviceMode ? const ValueKey('listServiceSubmit') : null,
                  onPressed: submitting ? null : () async {
                    final amt = double.tryParse(amountCtrl.text.trim()) ?? 0;
                    final desc = descCtrl.text.trim();
                    if (amt <= 0) {
                      setSheet(() => sheetError = 'Enter a valid amount');
                      return;
                    }
                    // NOTE: no client-side balance pre-check. The relay is the
                    // authority on spendable balance (_deductBalance →
                    // INSUFFICIENT_BALANCE, surfaced below). A local snapshot
                    // (widget.seeds / _liveSeeds) can be stale or 0 right after
                    // recovery and would WRONGLY block a valid listing — the root
                    // cause of the S7 failures. "Relay owns state" (CLAUDE.md §3).
                    if (desc.isEmpty) {
                      setSheet(() => sheetError = serviceMode
                          ? 'Describe your service' : 'Enter what you want in return');
                      return;
                    }
                    // PI-33: tag a service offer with the [SERVICE] convention so
                    // it renders as a service card across the Exchange. Idempotent —
                    // don't double-prefix if the user already typed it.
                    final sendDesc = (serviceMode &&
                            !desc.trimLeft().toUpperCase().startsWith('[SERVICE]'))
                        ? '[SERVICE] $desc'
                        : desc;
                    setSheet(() { submitting = true; sheetError = ''; });
                    if (!RelayConnector.isConnected) await RelayConnector.connect();
                    final result = await RelayConnector.listExchangeOrder(
                        widget.sovereignId, amt, sendDesc, selectedDays,
                        paymentMethod: paymentCtrl.text.trim());
                    if (result['success'] == true) {
                      // Clear exchange drafts and reset controllers
                      await DraftManager.clearAll(DraftKeys.exchangeAll);
                      amountCtrl.clear();
                      descCtrl.clear();
                      paymentCtrl.clear();
                      if (ctx.mounted) Navigator.pop(ctx);
                      _resubscribeOrders();
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Order listed — awaiting a buyer'),
                            backgroundColor: Color(0xFF006B5E),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                        _tabs.animateTo(1);
                      }
                    } else {
                      setSheet(() {
                        sheetError = result['error'] as String? ?? 'Listing failed';
                        submitting = false;
                      });
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _gold,
                    disabledBackgroundColor: _gold.withAlpha(77),
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    elevation: 0,
                  ),
                  child: submitting
                      ? const SizedBox(width: 20, height: 20,
                          child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2.5))
                      : Text(serviceMode ? 'List Service' : 'List Order',
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── BUILD ─────────────────────────────────────────────────────────────────────

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
        title: const Text('Exchange',
            style: TextStyle(color: Color(0xFFB8960C), fontWeight: FontWeight.bold, fontSize: 18)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Colors.white38),
            onPressed: _resubscribeOrders,
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(72),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── Mini price spark line (24h fills) ───────────────────────────
              if (_priceHistory.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: SizedBox(
                    height: 28,
                    child: CustomPaint(
                      size: const Size(double.infinity, 28),
                      painter: _SparkLinePainter(
                        prices: _priceHistory.map((f) =>
                            (f['price'] as num?)?.toDouble() ?? 0.0).toList().reversed.toList(),
                        color: const Color(0xFFB8960C),
                      ),
                    ),
                  ),
                ),
              TabBar(
                controller: _tabs,
                labelColor: _gold,
                unselectedLabelColor: Colors.white38,
                indicatorColor: _gold,
                indicatorSize: TabBarIndicatorSize.tab,
                tabs: const [
                  Tab(text: 'Browse'),
                  Tab(text: 'My Orders'),
                  Tab(text: 'Order Book'),
                ],
              ),
            ],
          ),
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _BrowseTab(
            orders: _orders,
            loading: _loadingOrders,
            error: _ordersError,
            sovereignId: widget.sovereignId,
            onRefresh: _resubscribeOrders,
            onFill: _fillOrder,
            onChat: _openChat,
            onCancel: _cancelOrder,
            reputationColor: _reputationColor,
            expiresIn: _expiresIn,
          ),
          _MyOrdersTab(
            myOrders: _myOrders,
            myFilledOrders: _myFilledOrders,
            loading: _loadingMyOrders,
            loadingFills: _loadingFills,
            sovereignId: widget.sovereignId,
            onListNew: _showListOrderSheet,
            onListService: () => _showListOrderSheet(serviceMode: true),
            onConfirmDelivery: _confirmDeliveryFlow,
            onEdit: _showEditOrderSheet,
            onCancel: _cancelOrder,
            onRaiseDisputeSeller: _raiseDispute,
            onRaiseDisputeBuyer:  _raiseDispute,
            onRequestRefund:      _requestRefund,
            onChat: (id, {String? orderId}) => _openChat(id, orderId: orderId),
            onInbox: _openSellerInbox,
            expiresIn: _expiresIn,
          ),
          _OrderBookTab(
            bids:    _orderBookBids,
            history: _priceHistory,
            loading: _loadingBook,
            onRefresh: _loadOrderBook,
          ),
        ],
      ),
    );
  }

  // ── Confirm delivery flow (seller taps "Confirm Payment Received") ────────────

  Future<void> _confirmDeliveryFlow(String orderId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Confirm Payment Received',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: const Text(
          'Confirming releases the escrowed SOV to the buyer. '
          'Only confirm once you have received the agreed item or payment.',
          style: TextStyle(color: Colors.white54, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white38)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: _teal, foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Confirm', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final result = await RelayConnector.confirmDelivery(
        orderId, widget.sovereignId, 'SELLER_CONFIRMS_PAYMENT_RECEIVED');
    if (!mounted) return;

    if (result['success'] == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Delivery confirmed — SOV released to buyer'),
          backgroundColor: Color(0xFF006B5E),
          behavior: SnackBarBehavior.floating,
        ),
      );
      _resubscribeOrders();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result['error'] as String? ?? 'Confirmation failed'),
          backgroundColor: Colors.red.shade900,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Browse Tab
// ══════════════════════════════════════════════════════════════════════════════

class _BrowseTab extends StatelessWidget {
  final List<Map<String, dynamic>> orders;
  final bool    loading;
  final String  error;
  final String  sovereignId;
  final VoidCallback onRefresh;
  final Future<void> Function(Map<String, dynamic>) onFill;
  final void Function(String sellerId, {String? orderId}) onChat;
  final Future<void> Function(Map<String, dynamic>) onCancel;
  final Color Function(num) reputationColor;
  final String Function(num) expiresIn;

  static const _gold   = Color(0xFFB8960C);
  static const _cardBg = Color(0xFF0D1F3A);

  const _BrowseTab({
    required this.orders,
    required this.loading,
    required this.error,
    required this.sovereignId,
    required this.onRefresh,
    required this.onFill,
    required this.onChat,
    required this.onCancel,
    required this.reputationColor,
    required this.expiresIn,
  });

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFFB8960C), strokeWidth: 2.5),
      );
    }

    if (error.isNotEmpty) {
      return Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.cloud_off_rounded, color: Colors.white24, size: 48),
          const SizedBox(height: 16),
          Text(error, style: const TextStyle(color: Colors.white38, fontSize: 13),
              textAlign: TextAlign.center),
          const SizedBox(height: 16),
          TextButton(onPressed: onRefresh,
              child: const Text('Retry', style: TextStyle(color: Color(0xFFB8960C)))),
        ]),
      );
    }

    // Show ALL open orders — own orders shown with "Your Listing" badge (no Fill button)
    if (orders.isEmpty) {
      return Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.store_outlined, color: Colors.white24, size: 48),
          const SizedBox(height: 16),
          const Text('No open orders', style: TextStyle(color: Colors.white38, fontSize: 14)),
          const SizedBox(height: 8),
          const Text('Be the first to list an order in the My Orders tab.',
              style: TextStyle(color: Colors.white24, fontSize: 12),
              textAlign: TextAlign.center),
          const SizedBox(height: 16),
          TextButton(onPressed: onRefresh,
              child: const Text('Refresh', style: TextStyle(color: Color(0xFFB8960C)))),
        ]),
      );
    }

    return RefreshIndicator(
      onRefresh: () async => onRefresh(),
      color: _gold,
      backgroundColor: _cardBg,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        itemCount: orders.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (_, i) {
          final isOwn    = orders[i]['seller_id'] == sovereignId;
          final sellerId = orders[i]['seller_id'] as String? ?? '';
          final status   = orders[i]['status'] as String? ?? 'open';
          return _OrderCard(
            order: orders[i],
            isOwnOrder: isOwn,
            onFill: isOwn ? null : () => onFill(orders[i]),
            // Always pass orderId so buyer+seller share the same conversation thread
            onChat: isOwn ? null : (sellerId.isNotEmpty
                ? () => onChat(sellerId, orderId: orders[i]['order_id'] as String?)
                : null),
            // Browse-tab Cancel — only the owner of an OPEN (unfilled) order can cancel
            onCancel: (isOwn && status == 'open') ? () => onCancel(orders[i]) : null,
            reputationColor: reputationColor,
            expiresIn: expiresIn,
          );
        },
      ),
    );
  }
}

class _OrderCard extends StatelessWidget {
  final Map<String, dynamic> order;
  final bool          isOwnOrder;
  final VoidCallback? onFill;     // null for own orders
  final VoidCallback? onChat;     // null for own orders
  final VoidCallback? onCancel;   // non-null only when own + open
  final Color Function(num) reputationColor;
  final String Function(num) expiresIn;

  static const _cardBg = Color(0xFF0D1F3A);
  static const _gold   = Color(0xFFB8960C);

  const _OrderCard({
    required this.order,
    required this.isOwnOrder,
    required this.onFill,
    required this.onChat,
    this.onCancel,
    required this.reputationColor,
    required this.expiresIn,
  });

  @override
  Widget build(BuildContext context) {
    final sovAmount    = fmtSovFromSeeds(order['sov_amount']);
    final rawDesc      = (order['asking_description'] ?? order['memo']) as String? ?? '';
    // PI-33 cert-institution: a "service offer" is just an Exchange listing whose
    // description begins with the [SERVICE] convention. Render it as a service
    // card (SERVICE chip + "Hire" action) — no new protocol, pure UI framing over
    // the existing listing/fill/escrow flow.
    final isService    = rawDesc.trimLeft().toUpperCase().startsWith('[SERVICE]');
    final desc         = isService
        ? rawDesc.trimLeft().substring(rawDesc.trimLeft().indexOf(']') + 1).trim()
        : rawDesc;
    final sellerId     = order['seller_id'] as String? ?? '';
    final paymentMethod = (order['payment_method'] as String? ?? '').trim();
    final repScore     = (order['seller_reputation_score'] as num?) ?? 0;
    final expiresAt    = (order['expires_at'] as num?) ?? 0;
    final sourceRelay  = order['source_relay_id'] as String?;
    final isCrossRelay = sourceRelay != null && sourceRelay.isNotEmpty;

    final repColor = reputationColor(repScore);
    final expiry   = expiresIn(expiresAt);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isOwnOrder
              ? _gold.withAlpha(40)
              : Colors.white.withAlpha(13),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: SOV amount + reputation / own-listing badge
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(sovAmount,
                  style: const TextStyle(
                    color: Color(0xFFB8960C),
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                    letterSpacing: -0.5,
                  )),
              if (isOwnOrder)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: _gold.withAlpha(26),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: _gold.withAlpha(77)),
                  ),
                  child: const Text('Your Listing',
                      style: TextStyle(
                          color: Color(0xFFB8960C),
                          fontSize: 11,
                          fontWeight: FontWeight.bold)),
                )
              else
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: repColor.withAlpha(26),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: repColor.withAlpha(77)),
                  ),
                  child: Text('Rep ${repScore.toStringAsFixed(0)}',
                      style: TextStyle(
                          color: repColor,
                          fontSize: 11,
                          fontWeight: FontWeight.bold)),
                ),
            ],
          ),
          const SizedBox(height: 10),
          // Service chip (PI-33) — marks a certified-citizen service offer
          if (isService) ...[
            Container(
              key: const ValueKey('serviceChip'),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFF006B5E).withAlpha(40),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFF006B5E).withAlpha(120)),
              ),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.workspace_premium_rounded, size: 12, color: Color(0xFF4DB6AC)),
                SizedBox(width: 4),
                Text('SERVICE',
                    style: TextStyle(color: Color(0xFF4DB6AC), fontSize: 10,
                        fontWeight: FontWeight.bold, letterSpacing: 1)),
              ]),
            ),
            const SizedBox(height: 8),
          ],
          // Description
          Text(desc, style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.4)),
          if (paymentMethod.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(children: [
              const Icon(Icons.payments_outlined, color: Color(0xFF34C6A8), size: 14),
              const SizedBox(width: 6),
              Expanded(child: Text('Accepts: $paymentMethod',
                  style: const TextStyle(color: Color(0xFF34C6A8), fontSize: 12, fontWeight: FontWeight.w600),
                  maxLines: 1, overflow: TextOverflow.ellipsis)),
            ]),
          ],
          const SizedBox(height: 10),
          // Footer: seller ID + expiry + (cross-relay badge) + fill button
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isOwnOrder
                          ? 'Your order'
                          : (sellerId.length > 24
                              ? '${sellerId.substring(0, 14)}...${sellerId.substring(sellerId.length - 6)}'
                              : sellerId),
                      style: TextStyle(
                          color: isOwnOrder ? _gold.withAlpha(179) : Colors.white38,
                          fontSize: 11,
                          fontFamily: 'monospace'),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Text('Expires in $expiry',
                            style: const TextStyle(color: Colors.white24, fontSize: 11)),
                        if (isCrossRelay) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFF006B5E).withAlpha(40),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: const Color(0xFF006B5E).withAlpha(100)),
                            ),
                            child: Text(
                              '↗ ${_shortRelayId(sourceRelay)}',
                              style: const TextStyle(
                                  color: Color(0xFF4DB6AC), fontSize: 10,
                                  fontFamily: 'monospace'),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              if (!isOwnOrder) ...[
                if (onChat != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.chat_bubble_outline_rounded, size: 14),
                      label: const Text('Chat', style: TextStyle(fontSize: 12)),
                      onPressed: onChat,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _gold,
                        side: BorderSide(color: _gold.withAlpha(120)),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                ElevatedButton(
                  onPressed: onFill,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _gold,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    elevation: 0,
                  ),
                  child: Text(isService ? 'Hire' : 'Fill Order',
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                ),
              ],
              // Browse-tab Cancel — visible only on own OPEN listings (nobody filled it yet).
              // Releases the escrowed SOV back to the seller's spendable balance.
              if (isOwnOrder && onCancel != null)
                OutlinedButton.icon(
                  icon: const Icon(Icons.delete_outline_rounded, size: 14),
                  label: const Text('Cancel', style: TextStyle(fontSize: 12)),
                  onPressed: onCancel,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFEF5350),
                    side: const BorderSide(color: Color(0x66EF5350)),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  static String _shortRelayId(String? id) {
    if (id == null || id.isEmpty) return '';
    if (id.length <= 14) return id;
    return '${id.substring(0, 10)}…';
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// My Orders Tab
// ══════════════════════════════════════════════════════════════════════════════

class _MyOrdersTab extends StatelessWidget {
  final List<Map<String, dynamic>> myOrders;
  final List<Map<String, dynamic>> myFilledOrders;
  final bool         loading;
  final bool         loadingFills;
  final String       sovereignId;
  final VoidCallback onListNew;
  final VoidCallback onListService;
  final Future<void> Function(String orderId) onConfirmDelivery;
  final void Function(Map<String, dynamic>) onEdit;
  final Future<void> Function(Map<String, dynamic>) onCancel;
  final Future<void> Function(Map<String, dynamic>) onRaiseDisputeSeller;
  final Future<void> Function(Map<String, dynamic>) onRaiseDisputeBuyer;
  final Future<void> Function(Map<String, dynamic>) onRequestRefund;
  final void Function(String counterpartyId, {String? orderId}) onChat;
  final void Function(String orderId) onInbox;
  final String Function(num) expiresIn;

  static const _gold   = Color(0xFFB8960C);
  static const _cardBg = Color(0xFF0D1F3A);

  const _MyOrdersTab({
    required this.myOrders,
    required this.myFilledOrders,
    required this.loading,
    required this.loadingFills,
    required this.sovereignId,
    required this.onListNew,
    required this.onListService,
    required this.onConfirmDelivery,
    required this.onEdit,
    required this.onCancel,
    required this.onRaiseDisputeSeller,
    required this.onRaiseDisputeBuyer,
    required this.onRequestRefund,
    required this.onChat,
    required this.onInbox,
    required this.expiresIn,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      key: const ValueKey('myOrdersList'),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        // List new order button
        SizedBox(
          width: double.infinity,
          height: 50,
          child: ElevatedButton.icon(
            icon: const Icon(Icons.add_rounded, size: 20),
            label: const Text('List New Order',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            onPressed: onListNew,
            style: ElevatedButton.styleFrom(
              backgroundColor: _gold,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              elevation: 0,
            ),
          ),
        ),
        const SizedBox(height: 10),
        // List a Service (PI-33) — certified citizens offer paid services;
        // composes the same listing/escrow flow with the [SERVICE] convention.
        SizedBox(
          width: double.infinity,
          height: 48,
          child: OutlinedButton.icon(
            key: const ValueKey('listServiceButton'),
            icon: const Icon(Icons.workspace_premium_rounded, size: 18),
            label: const Text('List a Service',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
            onPressed: onListService,
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF4DB6AC),
              side: const BorderSide(color: Color(0xFF006B5E)),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
        const SizedBox(height: 24),

        // ── My Listings (as seller) ─────────────────────────────────────────
        const Text('MY LISTINGS',
            style: TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 1.5)),
        const SizedBox(height: 10),

        if (loading) ...[
          const Center(child: CircularProgressIndicator(
              color: Color(0xFFB8960C), strokeWidth: 2.5)),
        ] else if (myOrders.isEmpty) ...[
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _cardBg, borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withAlpha(10)),
            ),
            child: const Center(
              child: Text('No active listings — tap "List New Order" above.',
                  style: TextStyle(color: Colors.white38, fontSize: 13),
                  textAlign: TextAlign.center),
            ),
          ),
        ] else ...[
          ...myOrders.map((order) {
            return _MyOrderCard(
              order: order,
              onConfirmDelivery: () => onConfirmDelivery(order['order_id'] as String),
              onEdit: order['status'] == 'open' ? () => onEdit(order) : null,
              onCancel: order['status'] == 'open' ? () => onCancel(order) : null,
              onRaiseDispute: order['status'] == 'filled' ? () => onRaiseDisputeSeller(order) : null,
              // Seller opens the NEGOTIATION INBOX — the per-buyer threads for
              // this order (Stage 2). Tapping a buyer opens that buyer's thread.
              onChat: () => onInbox(order['order_id'] as String),
              expiresIn: expiresIn,
            );
          }),
        ],

        // ── Orders I'm Filling (as buyer) ────────────────────────────────────
        const SizedBox(height: 28),
        const Text('ORDERS I\'M FILLING',
            style: TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 1.5)),
        const SizedBox(height: 10),

        if (loadingFills) ...[
          const Center(child: CircularProgressIndicator(
              color: Color(0xFFB8960C), strokeWidth: 2.5)),
        ] else if (myFilledOrders.isEmpty) ...[
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _cardBg, borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withAlpha(10)),
            ),
            child: const Center(
              child: Text('You haven\'t filled any orders yet.',
                  style: TextStyle(color: Colors.white38, fontSize: 13),
                  textAlign: TextAlign.center),
            ),
          ),
        ] else ...[
          ...myFilledOrders.map((order) {
            final sellerId = order['seller_id'] as String? ?? '';
            final deadline = (order['expires_at'] as num?) ?? 0;
            final pastDeadline = deadline > 0 &&
                deadline < DateTime.now().millisecondsSinceEpoch;
            return _FilledOrderCard(
              order: order,
              onRaiseDispute: order['status'] == 'filled'
                  ? () => onRaiseDisputeBuyer(order) : null,
              onRequestRefund: (order['status'] == 'filled' && pastDeadline)
                  ? () => onRequestRefund(order) : null,
              onChat: (order['status'] == 'filled' && sellerId.isNotEmpty)
                  ? () => onChat(sellerId, orderId: order['order_id'] as String?) : null,
              expiresIn: expiresIn,
            );
          }),
        ],
      ],
    );
  }
}

class _MyOrderCard extends StatelessWidget {
  final Map<String, dynamic> order;
  final VoidCallback     onConfirmDelivery;
  final VoidCallback?    onEdit;          // null when status != 'open'
  final VoidCallback?    onCancel;        // null when status != 'open'
  final VoidCallback?    onRaiseDispute;  // null when status != 'filled'
  final VoidCallback?    onChat;          // null when no buyer yet
  final String Function(num) expiresIn;

  static const _gold   = Color(0xFFB8960C);
  static const _cardBg = Color(0xFF0D1F3A);
  static const _teal   = Color(0xFF006B5E);

  const _MyOrderCard({
    required this.order,
    required this.onConfirmDelivery,
    required this.onEdit,
    required this.onCancel,
    required this.onRaiseDispute,
    required this.onChat,
    required this.expiresIn,
  });

  @override
  Widget build(BuildContext context) {
    final sovAmount = fmtSovFromSeeds(order['sov_amount']);
    final rawDesc   = (order['asking_description'] ?? order['memo']) as String? ?? '';
    // PI-33: a seller's own service listing also shows the SERVICE tag (parity
    // with the Browse-tab _OrderCard).
    final isService = rawDesc.trimLeft().toUpperCase().startsWith('[SERVICE]');
    final desc      = isService
        ? rawDesc.trimLeft().substring(rawDesc.trimLeft().indexOf(']') + 1).trim()
        : rawDesc;
    final status    = order['status'] as String? ?? 'open';
    final expiresAt = (order['expires_at'] as num?) ?? 0;

    Color statusColor;
    String statusLabel;
    switch (status) {
      case 'open':
        statusColor = Colors.white54;
        statusLabel = 'Open';
        break;
      case 'filled':
        statusColor = const Color(0xFFFFB300);
        statusLabel = 'Filled — awaiting delivery';
        break;
      case 'completed':
        statusColor = const Color(0xFF4CAF50);
        statusLabel = 'Completed';
        break;
      case 'expired':
        statusColor = Colors.white24;
        statusLabel = 'Expired';
        break;
      case 'cancelled':
        statusColor = Colors.white24;
        statusLabel = 'Cancelled';
        break;
      default:
        statusColor = Colors.white38;
        statusLabel = status;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withAlpha(13)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(sovAmount,
                  style: const TextStyle(
                      color: Color(0xFFB8960C), fontSize: 22, fontWeight: FontWeight.bold)),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: statusColor.withAlpha(26),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(statusLabel,
                    style: TextStyle(color: statusColor, fontSize: 11, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (isService) ...[
            Container(
              key: const ValueKey('serviceChip'),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFF006B5E).withAlpha(40),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFF006B5E).withAlpha(120)),
              ),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.workspace_premium_rounded, size: 12, color: Color(0xFF4DB6AC)),
                SizedBox(width: 4),
                Text('SERVICE',
                    style: TextStyle(color: Color(0xFF4DB6AC), fontSize: 10,
                        fontWeight: FontWeight.bold, letterSpacing: 1)),
              ]),
            ),
            const SizedBox(height: 6),
          ],
          Text('"$desc"',
              style: const TextStyle(color: Colors.white70, fontSize: 13, fontStyle: FontStyle.italic)),
          const SizedBox(height: 6),
          Text('Expires in ${expiresIn(expiresAt)}',
              style: const TextStyle(color: Colors.white24, fontSize: 11)),

          // Edit / Cancel row — only for open orders
          if (onEdit != null || onCancel != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                if (onEdit != null)
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.edit_outlined, size: 15),
                      label: const Text('Edit', style: TextStyle(fontSize: 13)),
                      onPressed: onEdit,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _gold,
                        side: BorderSide(color: _gold.withAlpha(120)),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                if (onEdit != null && onCancel != null) const SizedBox(width: 8),
                if (onCancel != null)
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.cancel_outlined, size: 15),
                      label: const Text('Cancel', style: TextStyle(fontSize: 13)),
                      onPressed: onCancel,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red.shade400,
                        side: BorderSide(color: Colors.red.shade900),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
              ],
            ),
          ],

          // Confirm delivery + dispute + chat — only for filled orders
          // Chat button — always visible; label changes by status
          const SizedBox(height: 10),
          Row(
            children: [
              if (onChat != null)
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.chat_bubble_outline_rounded, size: 14),
                    label: Text(
                      status == 'filled' ? 'Chat with Buyer' : 'Inquiries',
                      style: const TextStyle(fontSize: 12),
                    ),
                    onPressed: onChat,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _gold,
                      side: BorderSide(color: _gold.withAlpha(120)),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
            ],
          ),
          if (status == 'filled') ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: onConfirmDelivery,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _teal,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  elevation: 0,
                ),
                child: const Text('Confirm Payment Received',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                if (onRaiseDispute != null)
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.gavel_rounded, size: 14),
                      label: const Text('Dispute', style: TextStyle(fontSize: 12)),
                      onPressed: onRaiseDispute,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red.shade400,
                        side: BorderSide(color: Colors.red.shade900),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// ── Card for orders the citizen has filled as a buyer ──────────────────────────

class _FilledOrderCard extends StatelessWidget {
  final Map<String, dynamic> order;
  final VoidCallback? onRaiseDispute;  // null if not filled
  final VoidCallback? onRequestRefund; // null if delivery window still open
  final VoidCallback? onChat;          // null if seller unavailable
  final String Function(num) expiresIn;

  static const _cardBg = Color(0xFF0D1F3A);
  static const _gold   = Color(0xFFB8960C);
  static const _teal   = Color(0xFF006B5E);

  const _FilledOrderCard({
    required this.order,
    required this.onRaiseDispute,
    required this.onRequestRefund,
    required this.onChat,
    required this.expiresIn,
  });

  @override
  Widget build(BuildContext context) {
    final sovAmount    = fmtSovFromSeeds(order['sov_amount']);
    final desc         = (order['asking_description'] ?? order['memo']) as String? ?? '';
    final status       = order['status'] as String? ?? 'filled';
    final sellerId     = order['seller_id'] as String? ?? '';
    final filledAt     = (order['filled_at'] as num?) ?? 0;
    final sourceRelay  = order['source_relay_id'] as String?;

    Color statusColor;
    String statusLabel;
    switch (status) {
      case 'filled':
        statusColor = const Color(0xFFFFB300);
        statusLabel = 'Deliver item to seller';
        break;
      case 'completed':
        statusColor = const Color(0xFF4CAF50);
        statusLabel = 'Completed — SOV released';
        break;
      case 'refunded':
        statusColor = Colors.white54;
        statusLabel = 'Refunded';
        break;
      default:
        statusColor = Colors.white38;
        statusLabel = status;
    }

    final filledDate = filledAt > 0
        ? DateTime.fromMillisecondsSinceEpoch(filledAt.toInt())
        : null;
    final filledStr  = filledDate != null
        ? '${filledDate.day}/${filledDate.month}/${filledDate.year}'
        : '';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withAlpha(13)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(sovAmount,
                  style: const TextStyle(
                      color: Color(0xFFB8960C), fontSize: 22, fontWeight: FontWeight.bold)),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                    color: statusColor.withAlpha(26), borderRadius: BorderRadius.circular(6)),
                child: Text(statusLabel,
                    style: TextStyle(color: statusColor, fontSize: 11, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text('"$desc"',
              style: const TextStyle(color: Colors.white70, fontSize: 13, fontStyle: FontStyle.italic)),
          const SizedBox(height: 4),
          Row(
            children: [
              Text(
                sellerId.length > 24
                    ? '${sellerId.substring(0, 14)}...${sellerId.substring(sellerId.length - 6)}'
                    : sellerId,
                style: const TextStyle(color: Colors.white38, fontSize: 11, fontFamily: 'monospace'),
              ),
              if (sourceRelay != null && sourceRelay.isNotEmpty) ...[
                const SizedBox(width: 6),
                Text('↗ ${sourceRelay.length > 10 ? sourceRelay.substring(0, 10) : sourceRelay}',
                    style: const TextStyle(color: Color(0xFF4DB6AC), fontSize: 10, fontFamily: 'monospace')),
              ],
            ],
          ),
          if (filledStr.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text('Filled: $filledStr',
                style: const TextStyle(color: Colors.white24, fontSize: 11)),
          ],

          // Action buttons for filled orders (buyer view)
          if (status == 'filled') ...[
            const SizedBox(height: 12),
            // Chat with seller
            if (onChat != null)
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.chat_bubble_outline_rounded, size: 15),
                  label: const Text('Message Seller', style: TextStyle(fontSize: 13)),
                  onPressed: onChat,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _gold,
                    side: BorderSide(color: _gold.withAlpha(120)),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
            if (onRequestRefund != null) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.undo_rounded, size: 15),
                  label: const Text('Request Refund', style: TextStyle(fontSize: 13)),
                  onPressed: onRequestRefund,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _teal,
                    side: const BorderSide(color: Color(0xFF006B5E)),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
            ],
            if (onRaiseDispute != null) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.gavel_rounded, size: 15),
                  label: const Text('Raise Dispute', style: TextStyle(fontSize: 13)),
                  onPressed: onRaiseDispute,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red.shade400,
                    side: BorderSide(color: Colors.red.shade900),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// SELLER NEGOTIATION INBOX (Stage 2 premium)
// The per-buyer threads for one of the seller's orders. Each row = an interested
// buyer with their last message, unread badge, and reputation. Tapping opens that
// buyer's thread. Backed by EXCHANGE_CHAT_THREADS on the relay.
// ════════════════════════════════════════════════════════════════════════════
class _SellerInboxSheet extends StatefulWidget {
  final String orderId;
  final String mySovId;
  final void Function(String buyerId) onOpenThread;
  const _SellerInboxSheet({
    required this.orderId,
    required this.mySovId,
    required this.onOpenThread,
  });
  @override
  State<_SellerInboxSheet> createState() => _SellerInboxSheetState();
}

class _SellerInboxSheetState extends State<_SellerInboxSheet> {
  static const _navy   = Color(0xFF060F1E);
  static const _cardBg = Color(0xFF0D1F3A);
  static const _gold   = Color(0xFFB8960C);
  static const _teal   = Color(0xFF34C6A8);

  List<Map<String, dynamic>> _threads = [];
  bool _loading = true;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    final t = await RelayConnector.getExchangeChatThreads(widget.orderId);
    if (!mounted) return;
    setState(() { _threads = t; _loading = false; });
  }

  static String _shortId(String id) =>
      id.length <= 16 ? id : '${id.substring(0, 12)}…${id.substring(id.length - 4)}';

  static String _ago(int ts) {
    if (ts <= 0) return '';
    final d = DateTime.now().millisecondsSinceEpoch - ts;
    if (d < 60000) return 'just now';
    if (d < 3600000) return '${d ~/ 60000}m ago';
    if (d < 86400000) return '${d ~/ 3600000}h ago';
    return '${d ~/ 86400000}d ago';
  }

  @override
  Widget build(BuildContext context) {
    final totalUnread = _threads.fold<int>(0, (s, t) => s + ((t['unread'] as num?)?.toInt() ?? 0));
    return Container(
      height: MediaQuery.of(context).size.height * 0.72,
      decoration: const BoxDecoration(
        color: _navy,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(children: [
        const SizedBox(height: 10),
        Container(width: 40, height: 4, decoration: BoxDecoration(
            color: Colors.white24, borderRadius: BorderRadius.circular(2))),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 12, 8),
          child: Row(children: [
            const Icon(Icons.forum_outlined, color: _gold, size: 20),
            const SizedBox(width: 10),
            const Expanded(child: Text('Negotiation inbox',
                style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold))),
            if (totalUnread > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                decoration: BoxDecoration(color: _teal, borderRadius: BorderRadius.circular(20)),
                child: Text('$totalUnread new',
                    style: const TextStyle(color: Color(0xFF06231E), fontSize: 11, fontWeight: FontWeight.w800)),
              ),
            IconButton(onPressed: _load, icon: const Icon(Icons.refresh_rounded, color: Colors.white54, size: 20)),
          ]),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(18, 0, 18, 6),
          child: Align(alignment: Alignment.centerLeft, child: Text(
            'Buyers negotiating on this order',
            style: TextStyle(color: Colors.white38, fontSize: 12))),
        ),
        const Divider(color: Colors.white10, height: 1),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator(color: _gold, strokeWidth: 2.5))
              : _threads.isEmpty
                  ? _empty()
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: _threads.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 2),
                      itemBuilder: (_, i) => _threadRow(_threads[i]),
                    ),
        ),
      ]),
    );
  }

  Widget _empty() => Center(
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.forum_outlined, color: Colors.white.withAlpha(40), size: 44),
      const SizedBox(height: 12),
      const Text('No buyers yet', style: TextStyle(color: Colors.white54, fontSize: 15, fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      const Padding(padding: EdgeInsets.symmetric(horizontal: 40), child: Text(
        'When a buyer messages you about this order, their thread appears here.',
        textAlign: TextAlign.center, style: TextStyle(color: Colors.white38, fontSize: 13))),
    ]),
  );

  Widget _threadRow(Map<String, dynamic> t) {
    final buyerId = t['buyer_id'] as String? ?? '';
    final unread  = (t['unread'] as num?)?.toInt() ?? 0;
    final rep     = (t['reputation_score'] as num?)?.toDouble() ?? 100;
    final trades  = (t['trades_completed'] as num?)?.toInt() ?? 0;
    final lastMine = t['last_from_me'] == true;
    final last    = (t['last_content'] as String? ?? '');
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => widget.onOpenThread(buyerId),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            color: _cardBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: unread > 0 ? _teal.withAlpha(90) : Colors.white.withAlpha(13)),
          ),
          child: Row(children: [
            CircleAvatar(radius: 20, backgroundColor: _gold.withAlpha(30),
                child: Text(buyerId.length >= 6 ? buyerId.substring(4, 6).toUpperCase() : '?',
                    style: const TextStyle(color: _gold, fontWeight: FontWeight.bold, fontSize: 13))),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(_shortId(buyerId),
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13),
                    overflow: TextOverflow.ellipsis)),
                Text(_ago((t['last_ts'] as num?)?.toInt() ?? 0),
                    style: const TextStyle(color: Colors.white38, fontSize: 11)),
              ]),
              const SizedBox(height: 3),
              Text('${lastMine ? "You: " : ""}$last',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: unread > 0 ? Colors.white : Colors.white54,
                      fontSize: 12.5, fontWeight: unread > 0 ? FontWeight.w600 : FontWeight.normal)),
              const SizedBox(height: 4),
              Row(children: [
                Icon(Icons.verified_user_outlined, size: 11, color: _teal.withAlpha(200)),
                const SizedBox(width: 3),
                Text('Rep ${rep.toStringAsFixed(0)} · $trades trades',
                    style: TextStyle(color: _teal.withAlpha(200), fontSize: 10.5)),
              ]),
            ])),
            if (unread > 0) ...[
              const SizedBox(width: 8),
              Container(
                width: 22, height: 22, alignment: Alignment.center,
                decoration: const BoxDecoration(color: _teal, shape: BoxShape.circle),
                child: Text('$unread',
                    style: const TextStyle(color: Color(0xFF06231E), fontSize: 11, fontWeight: FontWeight.w800)),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// EXCHANGE CHAT SHEET
// Isolated trade messaging scoped to an order — never appears in SOV Speak.
// [XCHG-CHAT] Relay-native: messages stored in sov_exchange_messages on relay,
// fetched via EXCHANGE_CHAT_LIST, pushed live via EXCHANGE_CHAT_INCOMING.
// ════════════════════════════════════════════════════════════════════════════

class _ExchangeChatSheet extends StatefulWidget {
  final String orderId;
  final String mySovId;
  final String counterpartyId;
  // True when the viewer is the SELLER opening a buyer's thread from the inbox.
  // Sellers can make/accept offers but cannot fill; buyers get "Fill at agreed
  // terms". Defaults false (the common buyer-negotiating-a-listing path).
  final bool isSellerView;

  const _ExchangeChatSheet({
    required this.orderId,
    required this.mySovId,
    required this.counterpartyId,
    this.isSellerView = false,
  });

  @override
  State<_ExchangeChatSheet> createState() => _ExchangeChatSheetState();
}

class _ExchangeChatSheetState extends State<_ExchangeChatSheet> {
  static const _navy   = Color(0xFF060F1E);
  static const _cardBg = Color(0xFF0D1F3A);
  static const _gold   = Color(0xFFB8960C);

  final _textCtrl   = TextEditingController();
  final _scrollCtrl = ScrollController();
  // Relay-native: messages come from relay DB, not local ContactsDb.
  List<Map<String, dynamic>> _messages = [];
  bool _sending = false;
  bool _loading = false;
  StreamSubscription<Map<String, dynamic>>? _msgSub;

  @override
  void initState() {
    super.initState();
    _loadMessages();
    // Listen for real-time EXCHANGE_CHAT_INCOMING pushes from relay
    _msgSub = RelayConnector.exchangeChatStream.listen((msg) {
      final incoming = msg['message'] as Map<String, dynamic>?;
      if (incoming == null) return;
      if (incoming['order_id'] != widget.orderId) return;
      if (!mounted) return;
      setState(() {
        // Dedup by msg_id then append
        if (!_messages.any((m) => m['msg_id'] == incoming['msg_id'])) {
          _messages.add(incoming);
        }
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollCtrl.hasClients) {
          _scrollCtrl.animateTo(
            _scrollCtrl.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      });
    });
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    _msgSub?.cancel();
    super.dispose();
  }

  Future<void> _loadMessages() async {
    if (_loading) return;
    if (mounted) setState(() => _loading = true);
    try {
      // Pass the buyer so a seller's view scopes to THIS buyer's thread (the
      // relay ignores buyer_id for a non-seller viewer, so this is safe for both).
      final msgs = await RelayConnector.getExchangeChatMessages(
          widget.orderId,
          buyerId: widget.counterpartyId.isNotEmpty ? widget.counterpartyId : null);
      if (!mounted) return;
      setState(() => _messages = msgs);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollCtrl.hasClients) {
          _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
        }
      });
    } catch (_) {
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Resolve actual counterparty — if counterpartyId was empty (seller opening
  /// their own order before a buyer fills), find the sender from message history.
  String get _resolvedCounterpartyId {
    if (widget.counterpartyId.isNotEmpty) return widget.counterpartyId;
    // Find first message not sent by me — that's the buyer who messaged first
    for (final m in _messages) {
      final fromId = m['from_id'] as String? ?? '';
      if (fromId != widget.mySovId && fromId.isNotEmpty) return fromId;
    }
    return '';
  }

  Future<void> _send() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty) return;
    _textCtrl.clear();
    await _sendContent(text);
  }

  /// Send arbitrary message content (plain text, or an [[OFFER]]/[[ACCEPT]]
  /// marker) through the relay-native trade chat.
  Future<void> _sendContent(String content) async {
    if (content.isEmpty || _sending) return;

    final toId = _resolvedCounterpartyId;
    if (toId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No inquiries yet — wait for a buyer to message first.')),
      );
      return;
    }

    setState(() => _sending = true);

    // Optimistic local insert so sender sees it immediately
    final optimisticId = 'OPT-${DateTime.now().millisecondsSinceEpoch}';
    final optimistic = {
      'msg_id':     optimisticId,
      'order_id':   widget.orderId,
      'from_id':    widget.mySovId,
      'to_id':      toId,
      'content':    content,
      'created_at': DateTime.now().millisecondsSinceEpoch,
      '_pending':   true,
    };
    if (mounted) setState(() => _messages.add(optimistic));

    // Send via relay-native EXCHANGE_CHAT_SEND
    final result = await RelayConnector.sendExchangeChatMessage(
      orderId: widget.orderId,
      fromId:  widget.mySovId,
      toId:    toId,
      content: content,
    );

    if (result['success'] == true) {
      // Replace optimistic entry with confirmed msg_id from relay
      final confirmedId = result['msg_id'] as String? ?? optimisticId;
      if (mounted) {
        setState(() {
          final idx = _messages.indexWhere((m) => m['msg_id'] == optimisticId);
          if (idx >= 0) {
            _messages[idx] = Map<String, dynamic>.from(_messages[idx])
              ..['msg_id']   = confirmedId
              ..remove('_pending');
          }
        });
      }
    } else {
      // Mark as failed
      if (mounted) {
        setState(() {
          final idx = _messages.indexWhere((m) => m['msg_id'] == optimisticId);
          if (idx >= 0) {
            _messages[idx] = Map<String, dynamic>.from(_messages[idx])
              ..['_failed'] = true;
          }
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result['error'] as String? ?? 'Send failed')),
        );
      }
    }

    if (mounted) setState(() => _sending = false);
  }

  // ── Stage 2c: in-chat offers ────────────────────────────────────────────────
  static const _offerTag  = '[[OFFER]]';
  static const _acceptTag = '[[ACCEPT]]';
  static double? _parsePrice(String c, String tag) =>
      c.startsWith(tag) ? double.tryParse(c.substring(tag.length)) : null;

  /// The latest accepted price on this thread (null if none accepted yet).
  double? get _agreedPrice {
    for (final m in _messages.reversed) {
      final p = _parsePrice(m['content'] as String? ?? '', _acceptTag);
      if (p != null) return p;
    }
    return null;
  }

  Future<void> _makeOffer() async {
    final ctrl = TextEditingController();
    final price = await showDialog<double>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: _navy,
        title: const Text('Make an offer', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: TextField(
          controller: ctrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            labelText: 'Price per SOV (your currency)',
            labelStyle: TextStyle(color: Colors.white54),
            hintText: 'e.g. 950',
            hintStyle: TextStyle(color: Colors.white30),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(dctx, double.tryParse(ctrl.text.trim())),
            child: const Text('Send offer', style: TextStyle(color: _gold, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (price != null && price > 0) {
      await _sendContent('$_offerTag${price % 1 == 0 ? price.toInt() : price}');
    }
  }

  Future<void> _acceptOffer(double price) async {
    await _sendContent('$_acceptTag${price % 1 == 0 ? price.toInt() : price}');
  }

  bool _filling = false;
  Future<void> _fillAtAgreed(double price) async {
    if (_filling) return;
    setState(() => _filling = true);
    final res = await RelayConnector.fillExchangeOrder(
        widget.orderId, widget.mySovId, agreedPrice: price);
    if (!mounted) return;
    setState(() => _filling = false);
    if (res['success'] == true) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Filled at the agreed price — arrange the fiat payment with the seller.'),
        backgroundColor: Color(0xFF006B5E), behavior: SnackBarBehavior.floating));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(res['error'] as String? ?? 'Fill failed')));
    }
  }

  static String _priceStr(double p) => p % 1 == 0 ? p.toInt().toString() : p.toString();

  Widget _offerCard(double price, bool mine) {
    final agreed = _agreedPrice == price;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(12),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.72),
        decoration: BoxDecoration(
          color: _gold.withAlpha(28),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _gold.withAlpha(120)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.local_offer_outlined, color: _gold, size: 16),
            const SizedBox(width: 6),
            Flexible(child: Text('${mine ? "Your offer" : "Offer"}: ${_priceStr(price)} / SOV',
                style: const TextStyle(color: _gold, fontWeight: FontWeight.bold, fontSize: 13))),
          ]),
          if (!mine && !agreed) ...[
            const SizedBox(height: 8),
            SizedBox(width: double.infinity, child: ElevatedButton(
              onPressed: () => _acceptOffer(price),
              style: ElevatedButton.styleFrom(
                backgroundColor: _gold, foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
              child: const Text('Accept offer', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
            )),
          ],
          if (agreed) ...[
            const SizedBox(height: 4),
            const Text('✓ Agreed', style: TextStyle(color: Color(0xFF34C6A8), fontSize: 11, fontWeight: FontWeight.w600)),
          ],
        ]),
      ),
    );
  }

  Widget _acceptCard(double price, bool mine) {
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: const Color(0xFF34C6A8).withAlpha(28),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF34C6A8).withAlpha(120)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.handshake_outlined, color: Color(0xFF34C6A8), size: 16),
          const SizedBox(width: 6),
          Flexible(child: Text('Agreed: ${_priceStr(price)} / SOV',
              style: const TextStyle(color: Color(0xFF34C6A8), fontWeight: FontWeight.bold, fontSize: 13))),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Container(
      height: MediaQuery.of(context).size.height * 0.7 + bottom,
      decoration: const BoxDecoration(
        color: _navy,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(children: [
        // Handle bar
        Container(
          width: 40, height: 4,
          margin: const EdgeInsets.only(top: 10, bottom: 8),
          decoration: BoxDecoration(
            color: Colors.white24, borderRadius: BorderRadius.circular(2)),
        ),
        // Header
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(children: [
            const Icon(Icons.swap_horiz_rounded, color: _gold, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Trade Messages',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                Text(
                  'Order ${widget.orderId.substring(0, 8).toUpperCase()}',
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                ),
              ]),
            ),
            const Text('Private to this trade',
                style: TextStyle(color: Colors.white24, fontSize: 10)),
          ]),
        ),
        const Divider(color: Colors.white12, height: 1),
        // Messages
        Expanded(
          child: _loading && _messages.isEmpty
              ? const Center(child: CircularProgressIndicator(color: _gold))
              : _messages.isEmpty
                  ? Center(
                      child: Text(
                        widget.counterpartyId.isEmpty
                            ? 'No inquiries yet.\nBuyers can message you from Browse Orders.'
                            : 'No messages yet.\nSend a message to your trade partner.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white38, fontSize: 13, height: 1.5),
                      ))
                  : ListView.builder(
                      controller: _scrollCtrl,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      itemCount: _messages.length,
                      itemBuilder: (_, i) {
                        final m      = _messages[i];
                        final fromId = m['from_id'] as String? ?? '';
                        final mine   = fromId == widget.mySovId;
                        final text   = m['content'] as String? ?? '';
                        final ts     = (m['created_at'] as num?)?.toInt() ?? 0;
                        final failed = m['_failed'] == true;
                        final pending = m['_pending'] == true;
                        // Stage 2c: render structured offer / accept messages as cards.
                        final offerPrice  = _parsePrice(text, _offerTag);
                        final acceptPrice = _parsePrice(text, _acceptTag);
                        if (offerPrice != null)  return _offerCard(offerPrice, mine);
                        if (acceptPrice != null) return _acceptCard(acceptPrice, mine);
                        return Align(
                          alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                          child: Container(
                            margin: const EdgeInsets.symmetric(vertical: 3),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            constraints: BoxConstraints(
                                maxWidth: MediaQuery.of(context).size.width * 0.72),
                            decoration: BoxDecoration(
                              color: failed
                                  ? Colors.red.withAlpha(60)
                                  : mine ? _gold.withAlpha(200) : _cardBg,
                              borderRadius: BorderRadius.only(
                                topLeft:     const Radius.circular(14),
                                topRight:    const Radius.circular(14),
                                bottomLeft:  Radius.circular(mine ? 14 : 4),
                                bottomRight: Radius.circular(mine ? 4 : 14),
                              ),
                              border: mine ? null : Border.all(color: Colors.white12),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  text,
                                  style: TextStyle(
                                    color: mine ? Colors.black : Colors.white,
                                    fontSize: 13,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      ts > 0 ? _fmtTime(ts) : '…',
                                      style: TextStyle(
                                        color: mine ? Colors.black54 : Colors.white38,
                                        fontSize: 10,
                                      ),
                                    ),
                                    if (pending) ...[
                                      const SizedBox(width: 4),
                                      const SizedBox(width: 8, height: 8,
                                        child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.black45)),
                                    ],
                                    if (failed) ...[
                                      const SizedBox(width: 4),
                                      const Icon(Icons.error_outline, size: 11, color: Colors.red),
                                    ],
                                  ],
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
        ),
        // Stage 2c: buyer's "fill at agreed terms" bar (once a price is agreed).
        if (!widget.isSellerView && _agreedPrice != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            child: SizedBox(width: double.infinity, child: ElevatedButton.icon(
              onPressed: _filling ? null : () => _fillAtAgreed(_agreedPrice!),
              icon: _filling
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF06231E)))
                  : const Icon(Icons.check_circle_outline, size: 18),
              label: Text('Fill at agreed terms (${_priceStr(_agreedPrice!)} / SOV)',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF34C6A8), foregroundColor: const Color(0xFF06231E),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            )),
          ),
        // Compose bar
        Padding(
          padding: EdgeInsets.only(left: 12, right: 12, top: 8,
              bottom: bottom > 0 ? bottom : 16),
          child: Row(children: [
            // Make-offer button — propose a price per SOV.
            GestureDetector(
              onTap: _makeOffer,
              child: Container(
                padding: const EdgeInsets.all(9),
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  color: _gold.withAlpha(30), shape: BoxShape.circle,
                  border: Border.all(color: _gold.withAlpha(120))),
                child: const Icon(Icons.local_offer_outlined, color: _gold, size: 20),
              ),
            ),
            Expanded(
              child: TextField(
                controller: _textCtrl,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Message your trade partner…',
                  hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
                  filled: true,
                  fillColor: _cardBg,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                ),
                onSubmitted: (_) => _send(),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: _send,
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: const BoxDecoration(
                  color: _gold, shape: BoxShape.circle,
                ),
                child: _sending
                    ? const SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.black))
                    : const Icon(Icons.send_rounded, color: Colors.black, size: 18),
              ),
            ),
          ]),
        ),
      ]),
    );
  }

  String _fmtTime(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    if (dt.day == now.day && dt.month == now.month && dt.year == now.year) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return '${dt.day}/${dt.month} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}

// ── S13: Order Book Tab ───────────────────────────────────────────────────────

class _OrderBookTab extends StatelessWidget {
  static const _navy   = Color(0xFF0A1628);
  static const _cardBg = Color(0xFF0D1F3A);
  static const _gold   = Color(0xFFB8960C);

  final List<Map<String, dynamic>> bids;
  final List<Map<String, dynamic>> history;
  final bool    loading;
  final VoidCallback onRefresh;

  const _OrderBookTab({
    required this.bids,
    required this.history,
    required this.loading,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _navy,
      child: loading && bids.isEmpty
          ? const Center(child: CircularProgressIndicator(color: Color(0xFFB8960C)))
          : RefreshIndicator(
              onRefresh: () async => onRefresh(),
              color: _gold,
              backgroundColor: _cardBg,
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  // ── Price chart ─────────────────────────────────────────────
                  if (history.isNotEmpty)
                    SliverToBoxAdapter(child: _buildPriceChart()),

                  // ── Open bids depth ─────────────────────────────────────────
                  SliverToBoxAdapter(child: _buildSectionHeader('OPEN ORDER DEPTH')),
                  if (bids.isEmpty)
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.all(32),
                        child: Center(
                          child: Text('No open orders',
                              style: TextStyle(color: Colors.white38, fontSize: 14)),
                        ),
                      ),
                    )
                  else
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      sliver: SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (ctx, i) => _buildBidRow(bids[i], i),
                          childCount: bids.length,
                        ),
                      ),
                    ),

                  // ── Fill history ────────────────────────────────────────────
                  SliverToBoxAdapter(child: _buildSectionHeader('RECENT FILLS')),
                  if (history.isEmpty)
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.all(32),
                        child: Center(
                          child: Text('No fills yet',
                              style: TextStyle(color: Colors.white38, fontSize: 14)),
                        ),
                      ),
                    )
                  else
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                      sliver: SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (ctx, i) => _buildFillRow(history[i]),
                          childCount: history.length,
                        ),
                      ),
                    ),
                ],
              ),
            ),
    );
  }

  Widget _buildSectionHeader(String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white38,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.5,
        ),
      ),
    );
  }

  Widget _buildPriceChart() {
    final prices = history
        .map((f) => (f['price'] as num?)?.toDouble() ?? 0.0)
        .toList()
        .reversed
        .toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Container(
        height: 80,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: _cardBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withAlpha(10)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '24h PRICE CHART',
              style: TextStyle(color: Colors.white38, fontSize: 9, letterSpacing: 1.2),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: CustomPaint(
                size: const Size(double.infinity, 48),
                painter: _SparkLinePainter(prices: prices, color: _gold),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBidRow(Map<String, dynamic> bid, int index) {
    final price   = (bid['price']    as num?)?.toDouble() ?? 0.0;
    final totalSov= (bid['total_sov']as num?)?.toDouble() ?? 0.0;
    final orders  = (bid['orders']   as num?)?.toInt() ?? 0;

    // Max volume for relative bar width
    final maxVol  = bids.isNotEmpty
        ? bids.map((b) => (b['total_sov'] as num?)?.toDouble() ?? 0.0).reduce((a, b) => a > b ? a : b)
        : 1.0;
    final barPct  = maxVol > 0 ? (totalSov / maxVol).clamp(0.0, 1.0) : 0.0;

    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      child: Stack(
        children: [
          // Depth bar background
          Positioned.fill(
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: barPct,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.greenAccent.withAlpha(18),
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
            ),
          ),
          // Row content
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.greenAccent.withAlpha(20)),
            ),
            child: Row(
              children: [
                Text(
                  '${price.toStringAsFixed(2)} SOV',
                  style: const TextStyle(
                    color: Colors.greenAccent,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'monospace',
                  ),
                ),
                const Spacer(),
                Text(
                  '${totalSov.toStringAsFixed(2)} SOV',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  '$orders order${orders == 1 ? '' : 's'}',
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFillRow(Map<String, dynamic> fill) {
    final price     = (fill['price']      as num?)?.toDouble() ?? 0.0;
    final amtSeeds  = (fill['amount_seeds'] as num?)?.toInt() ?? 0;
    final filledAt  = (fill['filled_at']  as num?)?.toInt() ?? 0;

    final dt      = DateTime.fromMillisecondsSinceEpoch(filledAt);
    final now     = DateTime.now();
    final sameDay = dt.day == now.day && dt.month == now.month;
    final timeStr = sameDay
        ? '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}'
        : '${dt.day}/${dt.month}';

    return Container(
      margin: const EdgeInsets.only(bottom: 3),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Text(
            timeStr,
            style: const TextStyle(color: Colors.white38, fontSize: 10, fontFamily: 'monospace'),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '${price.toStringAsFixed(2)} SOV',
              style: const TextStyle(
                color: _gold, fontSize: 12, fontWeight: FontWeight.w600, fontFamily: 'monospace'),
            ),
          ),
          Text(
            '${(amtSeeds / 1000000).toStringAsFixed(2)} SOV',
            style: const TextStyle(color: Colors.white54, fontSize: 11, fontFamily: 'monospace'),
          ),
        ],
      ),
    );
  }
}

// ── S13: Spark line painter ───────────────────────────────────────────────────

class _SparkLinePainter extends CustomPainter {
  final List<double> prices;
  final Color        color;

  const _SparkLinePainter({required this.prices, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (prices.length < 2) return;

    final minP = prices.reduce((a, b) => a < b ? a : b);
    final maxP = prices.reduce((a, b) => a > b ? a : b);
    final range = (maxP - minP).abs();
    if (range == 0) {
      // Flat line at midpoint
      final y = size.height / 2;
      final paint = Paint()
        ..color = color.withAlpha(180)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
      return;
    }

    final xStep = size.width / (prices.length - 1);

    // Fill gradient under the line
    final fillPath = Path();
    fillPath.moveTo(0, size.height);
    for (int i = 0; i < prices.length; i++) {
      final x = i * xStep;
      final y = size.height - ((prices[i] - minP) / range) * size.height;
      if (i == 0) {
        fillPath.lineTo(x, y);
      } else {
        fillPath.lineTo(x, y);
      }
    }
    fillPath.lineTo(size.width, size.height);
    fillPath.close();

    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [color.withAlpha(50), color.withAlpha(0)],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height))
      ..style = PaintingStyle.fill;
    canvas.drawPath(fillPath, fillPaint);

    // Draw the line
    final linePath = Path();
    for (int i = 0; i < prices.length; i++) {
      final x = i * xStep;
      final y = size.height - ((prices[i] - minP) / range) * size.height;
      if (i == 0) {
        linePath.moveTo(x, y);
      } else {
        linePath.lineTo(x, y);
      }
    }
    final linePaint = Paint()
      ..color = color.withAlpha(200)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(linePath, linePaint);

    // Last price dot
    final lastX = (prices.length - 1) * xStep;
    final lastY = size.height - ((prices.last - minP) / range) * size.height;
    canvas.drawCircle(
      Offset(lastX, lastY),
      3.5,
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_SparkLinePainter old) =>
      old.prices != prices || old.color != color;
}
