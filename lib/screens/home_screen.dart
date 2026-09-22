// lib/screens/home_screen.dart
// ─────────────────────────────────────────────────────────────────────────────
// SESSION N1 — HomeTab
//
// Primary home tab inside MainShell's IndexedStack.
// Receives sovereignId, seeds, onSeedsChanged from MainShell.
//
// LAYOUT:
//   Header           — relay status pill + refresh spinner
//   Balance Card     — human nickname · truncated SovID · balance · escrow row
//                      · pioneer badge chips [RE] [EA] [PS]
//   Send SOV Button  — large gold call-to-action
//   Liveness Pill    — green <25d · amber 25–28d · red overdue
//   Recent Txs       — last 5 transactions
// ─────────────────────────────────────────────────────────────────────────────
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import '../sov_node_sdk/wallet_engine.dart';
import '../sov_node_sdk/relay_connector.dart';
import '../sov_node_sdk/transaction_store.dart';
import '../sov_node_sdk/message_events.dart';
import '../sov_node_sdk/sov_currency.dart';
import 'send_sov_screen.dart';
import 'receive_sov_screen.dart';
import 'exchange_screen.dart';
import 'transaction_history_screen.dart';
import 'liveness_screen.dart';
import 'node_status_screen.dart';
import 'economy_snapshot_screen.dart';

class HomeTab extends StatefulWidget {
  final String sovereignId;
  final int seeds;
  final void Function(int) onSeedsChanged;

  const HomeTab({
    super.key,
    required this.sovereignId,
    required this.seeds,
    required this.onSeedsChanged,
  });

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> with WidgetsBindingObserver {
  static const _navy   = Color(0xFF0A1628);
  static const _gold   = Color(0xFFD4AF37);
  static const _cardBg = Color(0xFF0D1F3A);

  bool   _refreshing     = false;
  int    _lockedSeeds    = 0;          // SOV Vault allocations
  int    _exchangeEscrowSeeds = 0;     // active exchange listings (SOV Shield)
  int?   _lastLiveness;
  bool   _balanceVisible = true;
  String _currencyCode   = 'USD';
  double _sovUsdRate     = 0.0;
  String _palmName       = '';   // palm-derived deterministic citizen name

  static const String _balancePrefKey = 'balance_visible_preference';

  Map<String, bool> _certs = {
    'RE': false,
    'EA': false,
    'PS': false,
  };

  List<Map<String, dynamic>> _recentTxs = [];

  // Exchange notification badge — increments on new fills / chat messages.
  int _exchangeUnread = 0;

  // Listens for relay sync / received-transfer events so Recent Transactions
  // reloads without requiring the user to pull-to-refresh.
  StreamSubscription<void>?                 _txSub;
  StreamSubscription<Map<String, dynamic>>? _xchgSub;

  // ═══════════════════════════════════════════════════════════════════════════
  // LIFECYCLE
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadBalancePreference();
    _loadData();
    // Reload when TransactionStore is written from outside this widget
    // (relay ledger sync on connect/restore, or received SOV transfer).
    _txSub = MessageEvents.onTransactionsChanged.listen((_) {
      if (mounted) _loadRecentTxs();
    });
    // Exchange notification badge — fires when an order is filled or a
    // trade-chat message arrives while the Exchange screen is not open.
    _xchgSub = RelayConnector.incomingMessages.listen((msg) {
      if (!mounted) return;
      final type = msg['type'] as String? ?? '';
      // New exchange chat message
      if (type == 'MESSAGE_INCOMING') {
        try {
          final payload = msg['encrypted_payload'] as String? ?? '';
          if (payload.contains('exchange_order_id')) {
            setState(() => _exchangeUnread++);
          }
        } catch (_) {}
        return;
      }
      // Order filled notification
      if (type == 'EXCHANGE_ORDER_FILLED' ||
          type == 'EXCHANGE_STATUS_BROADCAST') {
        setState(() => _exchangeUnread++);
      }
      // SOV Shield escrow events — refresh locked-balance display so the
      // citizen instantly sees SOV move between spendable and locked.
      if (type == 'EXCHANGE_ESCROW_LOCKED' ||
          type == 'EXCHANGE_ORDER_FILLED_NOTIFY' ||
          type == 'EXCHANGE_STATUS_BROADCAST') {
        _loadLockedSeeds();
      }
    });
  }

  @override
  void dispose() {
    _txSub?.cancel();
    _xchgSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        !RelayConnector.enrollmentInProgress) {
      _refreshBalance();
      _loadRecentTxs();
    }
  }

  // ─── Balance preference ───────────────────────────────────────────────────

  Future<void> _loadBalancePreference() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _balanceVisible = prefs.getBool(_balancePrefKey) ?? true;
        _currencyCode   = prefs.getString(SovCurrency.prefKey) ??
                          SovCurrency.autoDetect();
        _sovUsdRate     = prefs.getDouble('sov_usd_rate') ?? 0.0;
      });
    }
  }

  Future<void> _toggleBalance() async {
    final next = !_balanceVisible;
    setState(() => _balanceVisible = next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_balancePrefKey, next);
  }

  // ─── Initial data load ────────────────────────────────────────────────────

  Future<void> _loadData() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() => _lastLiveness = prefs.getInt('last_liveness_check'));
    }
    await Future.wait([
      _loadRecentTxs(),
      _loadLockedSeeds(),
      _loadCerts(),
      _refreshBalance(),
      _loadPalmName(),
    ]);
  }

  Future<void> _loadPalmName() async {
    final name = await RelayConnector.getPalmName();
    if (mounted) setState(() => _palmName = name);
  }

  Future<void> _refreshBalance() async {
    if (widget.sovereignId.isEmpty || _refreshing) return;
    if (mounted) setState(() => _refreshing = true);
    try {
      final b = await RelayConnector.queryBalance(widget.sovereignId);
      if (b > 0 && mounted) {
        await WalletEngine.updateBalance(b.toDouble());
        widget.onSeedsChanged(b);
      }
    } catch (_) {}
    if (mounted) setState(() => _refreshing = false);
  }

  Future<void> _loadRecentTxs() async {
    final all = await TransactionStore.load();
    if (mounted) setState(() => _recentTxs = all.take(5).toList());
  }

  Future<void> _loadLockedSeeds() async {
    if (widget.sovereignId.isEmpty) return;
    try {
      final result =
          await RelayConnector.fetchAllocationList(widget.sovereignId);
      final locked = (result['total_locked_seeds'] as num?)?.toInt() ?? 0;
      if (mounted) setState(() => _lockedSeeds = locked);
    } catch (_) {}
    // Exchange escrow — sum of sov_amount across all of my open/filled
    // exchange listings. Protocol Book §13 + line 549: locked SOV must be
    // visible separately from spendable. SOV Shield holds these funds.
    try {
      final listings =
          await RelayConnector.viewMyListings(widget.sovereignId);
      int exch = 0;
      for (final order in listings) {
        final status = order['status'] as String? ?? '';
        // Only orders whose SOV is still held in escrow count toward locked.
        // 'open' = listed and waiting for a buyer. 'filled' = buyer claimed,
        // SOV still escrowed until delivery confirmed. 'disputed' = justice
        // pending. All three keep SOV locked.
        if (status == 'open' || status == 'filled' || status == 'disputed') {
          final sovAmt = (order['sov_amount'] as num?)?.toDouble() ?? 0.0;
          exch += (sovAmt * 1000000).round();
        }
      }
      if (mounted) setState(() => _exchangeEscrowSeeds = exch);
    } catch (_) {}
  }

  Future<void> _loadCerts() async {
    if (widget.sovereignId.isEmpty) return;
    try {
      final resp =
          await RelayConnector.pioneerGetStatus(widget.sovereignId);
      if (resp['success'] == true && mounted) {
        final m =
            (resp['certifications'] as Map?)?.cast<String, dynamic>() ?? {};
        setState(() {
          _certs = {
            'RE': m['relay_engineer']      == true,
            'EA': m['enrollment_agent']    == true,
            'PS': m['protocol_specialist'] == true,
          };
        });
      }
    } catch (_) {}
  }

  // ─── Liveness helpers ─────────────────────────────────────────────────────

  int get _livenessDaysAgo {
    if (_lastLiveness == null) return -1;
    final ms = DateTime.now().millisecondsSinceEpoch - _lastLiveness!;
    return (ms / (24 * 60 * 60 * 1000)).floor();
  }

  Color get _livenessPillColor {
    final d = _livenessDaysAgo;
    if (d < 0)  return Colors.white30;
    if (d < 25) return Colors.greenAccent;
    if (d < 29) return Colors.amber;
    return Colors.redAccent;
  }

  String get _livenessPillLabel {
    final d = _livenessDaysAgo;
    if (d < 0)  return 'Liveness not set up';
    if (d < 25) return 'Liveness verified ${d}d ago';
    if (d < 29) return 'Liveness due soon — ${d}d ago';
    return 'Liveness overdue — verify now';
  }

  // ─── Formatters ───────────────────────────────────────────────────────────

  String _formatBalance(int seeds) {
    final sov = seeds / 1000000;
    final val = sov >= 1
        ? sov.toStringAsFixed(2)
        : sov.toStringAsFixed(6);
    return '${SovCurrency.symbol} $val';
  }

  String _formatSeeds(int seeds) =>
      seeds < 1000000 ? '$seeds Seeds' : '';

  /// Local currency estimate, e.g. "≈ ₦ 1,550.00"
  String get _localCurrencyRow {
    if (_sovUsdRate <= 0 || !_balanceVisible) return '';
    final sov = widget.seeds / 1000000.0;
    return SovCurrency.localValue(sov, _sovUsdRate, _currencyCode);
  }

  String get _truncatedSovId {
    final id = widget.sovereignId;
    if (id.length <= 18) return id;
    return '${id.substring(0, 12)}…${id.substring(id.length - 6)}';
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // BUILD
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _navy,
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _refreshBalance,
          color: _gold,
          backgroundColor: _cardBg,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(child: _buildHeader()),
              SliverToBoxAdapter(child: _buildBalanceCard()),
              SliverToBoxAdapter(child: _buildSendButton()),
              SliverToBoxAdapter(child: _buildNetworkChip()),
              SliverToBoxAdapter(child: _buildEconomyChip()),
              SliverToBoxAdapter(child: _buildLivenessPill()),
              if (_recentTxs.isNotEmpty)
                SliverToBoxAdapter(child: _buildRecentTransactions()),
              const SliverToBoxAdapter(child: SizedBox(height: 48)),
            ],
          ),
        ),
      ),
    );
  }

  // ── HEADER ─────────────────────────────────────────────────────────────────

  Widget _buildHeader() {
    final connected = RelayConnector.isConnected;
    final ctype     = RelayConnector.connectionType;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: (connected ? Colors.greenAccent : Colors.redAccent)
                  .withAlpha(18),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: (connected ? Colors.greenAccent : Colors.redAccent)
                    .withAlpha(60),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6, height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: connected
                        ? (ctype == 'native'
                            ? Colors.greenAccent
                            : Colors.orange)
                        : Colors.redAccent,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  connected
                      ? (ctype == 'native'
                          ? 'SOV Network'
                          : 'SOV Network · WSS')
                      : 'Offline',
                  style: TextStyle(
                    color: connected ? Colors.greenAccent : Colors.redAccent,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          if (_refreshing)
            const SizedBox(
              width: 18, height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 1.5, color: Color(0xFFD4AF37)),
            ),
        ],
      ),
    );
  }

  // ── BALANCE CARD ───────────────────────────────────────────────────────────

  Widget _buildBalanceCard() {
    // Use palm-derived name when available; fall back to relay nickname
    final nickname = _palmName.isNotEmpty
        ? _palmName
        : (widget.sovereignId.isNotEmpty
            ? RelayConnector.getNickname(widget.sovereignId)
            : '—');
    final anyBadge = _certs.values.any((v) => v);

    return Padding(
      key: const ValueKey('homeScreenBalanceCard'), // Added for integration testing
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF0E2245), Color(0xFF08152E)],
          ),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: _gold.withAlpha(40), width: 1),
          boxShadow: [
            BoxShadow(
              color: _gold.withAlpha(18),
              blurRadius: 28,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Human nickname + eye toggle
            Row(
              children: [
                Expanded(
                  child: Text(
                    nickname,
                    style: const TextStyle(
                      color: Color(0xFFD4AF37),
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: _toggleBalance,
                  child: Icon(
                    _balanceVisible
                        ? Icons.visibility_rounded
                        : Icons.visibility_off_rounded,
                    color: Colors.white38,
                    size: 20,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // Truncated SovID — tap to copy
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
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _truncatedSovId,
                    style: const TextStyle(
                      color: Colors.white38,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.copy_all_rounded,
                      color: Colors.white24, size: 12),
                ],
              ),
            ),
            const SizedBox(height: 20),
            // Balance
            Text(
              _balanceVisible
                  ? _formatBalance(widget.seeds)
                  : '${SovCurrency.symbol} •••••••',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 36,
                fontWeight: FontWeight.bold,
                letterSpacing: -1,
                height: 1.1,
              ),
            ),
            if (_balanceVisible && _formatSeeds(widget.seeds).isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  _formatSeeds(widget.seeds),
                  style: const TextStyle(
                    color: Color(0xFFD4AF37),
                    fontSize: 12,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            // Local currency equivalent (only when rate known)
            if (_localCurrencyRow.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                  _localCurrencyRow,
                  style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 12,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
            // Locked balance pills — Vault (gold) + SOV Shield (teal).
            // Per Protocol Book §13 line 549: locked SOV is shown separately
            // from spendable. Both rows hidden when zero.
            if (_balanceVisible && _lockedSeeds > 0) ...[
              const SizedBox(height: 12),
              _LockedPill(
                seeds: _lockedSeeds,
                label: 'in SOV Vault',
                tint: _gold,
                icon: Icons.lock_outline_rounded,
              ),
            ],
            if (_balanceVisible && _exchangeEscrowSeeds > 0) ...[
              const SizedBox(height: 8),
              _LockedPill(
                seeds: _exchangeEscrowSeeds,
                label: 'in SOV Shield (exchange)',
                tint: const Color(0xFF00D4AA),
                icon: Icons.shield_outlined,
              ),
            ],
            // Pioneer badge chips
            if (anyBadge) ...[
              const SizedBox(height: 14),
              Row(
                children: [
                  if (_certs['RE'] == true) const _BadgeChip(label: '[RE]'),
                  if (_certs['EA'] == true) const _BadgeChip(label: '[EA]'),
                  if (_certs['PS'] == true) const _BadgeChip(label: '[PS]'),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ── ACTION BUTTONS (Send + Receive + Exchange) ───────────────────────────

  Widget _buildSendButton() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
      child: Column(
        children: [
          // ── Row 1: Send SOV + Receive SOV ─────────────────────────────────
          Row(
            children: [
              // Send SOV
              Expanded(
                child: SizedBox(
                  height: 54,
                  child: ElevatedButton.icon(
                    key: const ValueKey('homeSendButton'), // flutter_driver
                    icon: const Icon(Icons.arrow_upward_rounded, size: 20),
                    label: const Text(
                      'Send SOV',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.bold),
                    ),
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => SendSovScreen(
                          sovereignId: widget.sovereignId,
                          seeds:       widget.seeds,
                          lockedSeeds: _lockedSeeds,
                        ),
                      ),
                    ).then((_) {
                      _refreshBalance();
                      _loadRecentTxs();
                    }),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _gold,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                      elevation: 0,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              // Receive SOV
              Expanded(
                child: SizedBox(
                  height: 54,
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.arrow_downward_rounded, size: 20),
                    label: const Text(
                      'Receive',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.bold),
                    ),
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ReceiveSovScreen(
                          sovereignId: widget.sovereignId,
                        ),
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0E2D1A),
                      foregroundColor: Colors.greenAccent,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: BorderSide(
                              color: Colors.greenAccent.withAlpha(60))),
                      elevation: 0,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // ── Row 2: Exchange (full width) ───────────────────────────────────
          Badge(
            isLabelVisible: _exchangeUnread > 0,
            label: Text('$_exchangeUnread'),
            backgroundColor: const Color(0xFFD4AF37),
            textColor: Colors.black,
            child: SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                key: const ValueKey('openExchange'),
                icon: const Icon(Icons.swap_horiz_rounded, size: 20),
                label: const Text(
                  'Exchange',
                  style: TextStyle(
                      fontSize: 15, fontWeight: FontWeight.bold),
                ),
                onPressed: () {
                  setState(() => _exchangeUnread = 0);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ExchangeScreen(
                        sovereignId: widget.sovereignId,
                        seeds:       widget.seeds,
                      ),
                    ),
                  );
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1A3A5C),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                  elevation: 0,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── NETWORK CHIP ─────────────────────────────────────────────────────────────

  Widget _buildNetworkChip() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
      child: GestureDetector(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const NodeStatusScreen()),
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFF0D1F3A),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white.withAlpha(12)),
          ),
          child: Row(
            children: [
              Container(
                width: 7, height: 7,
                decoration: const BoxDecoration(
                  color: Color(0xFF4CAF50), shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              const Text(
                'SOV Network',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
              const Spacer(),
              const Text(
                'View Dashboard →',
                style: TextStyle(
                  color: Color(0xFFD4AF37), fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── ECONOMY CHIP — live transparency view of the 50M ────────────────────────

  Widget _buildEconomyChip() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
      child: GestureDetector(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const EconomySnapshotScreen()),
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFF0D1F3A),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white.withAlpha(12)),
          ),
          child: Row(
            children: [
              const Icon(Icons.account_balance_outlined,
                  color: Color(0xFFC9A84C), size: 16),
              const SizedBox(width: 8),
              const Text(
                'SOV Economy — live',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
              const Spacer(),
              const Text(
                'Where the 50M is →',
                style: TextStyle(
                  color: Color(0xFFD4AF37), fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── LIVENESS PILL ──────────────────────────────────────────────────────────

  Widget _buildLivenessPill() {
    final pillColor = _livenessPillColor;
    final label     = _livenessPillLabel;
    final overdue   = _livenessDaysAgo >= 29;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
      child: GestureDetector(
        onTap: overdue
            ? () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        LivenessScreen(sovereignId: widget.sovereignId),
                  ),
                ).then((_) async {
                  final prefs = await SharedPreferences.getInstance();
                  if (mounted) {
                    setState(() => _lastLiveness =
                        prefs.getInt('last_liveness_check'));
                  }
                })
            : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: pillColor.withAlpha(14),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: pillColor.withAlpha(60)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 7, height: 7,
                decoration: BoxDecoration(
                    shape: BoxShape.circle, color: pillColor),
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: pillColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (overdue) ...[
                const SizedBox(width: 6),
                Icon(Icons.chevron_right_rounded, color: pillColor, size: 16),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ── RECENT TRANSACTIONS ────────────────────────────────────────────────────

  Widget _buildRecentTransactions() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Recent Transactions',
                style: TextStyle(
                    color: Colors.white60,
                    fontSize: 13,
                    fontWeight: FontWeight.w600),
              ),
              GestureDetector(
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const TransactionHistoryScreen()),
                ).then((_) => _loadRecentTxs()),
                child: const Text(
                  'View All',
                  style: TextStyle(
                      color: Color(0xFFD4AF37),
                      fontSize: 12,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ..._recentTxs.map(_buildMiniTxCard),
        ],
      ),
    );
  }

  Widget _buildMiniTxCard(Map<String, dynamic> tx) {
    final type         = tx['type']            as String? ?? 'unknown';
    final amountSeeds  = (tx['amount_seeds']   as num?)?.toInt() ?? 0;
    final counterparty = tx['counterparty_id'] as String? ?? '';
    final timestamp    = (tx['timestamp']      as num?)?.toInt() ?? 0;

    Color accent;
    IconData icon;
    switch (type) {
      case 'sent':
        accent = Colors.redAccent;
        icon   = Icons.arrow_upward_rounded;
        break;
      case 'received':
        accent = Colors.greenAccent;
        icon   = Icons.arrow_downward_rounded;
        break;
      case 'enrollment_reward':
        accent = _gold;
        icon   = Icons.star_rounded;
        break;
      default:
        accent = Colors.white54;
        icon   = Icons.swap_horiz_rounded;
    }

    final sov    = amountSeeds / 1000000;
    final sovStr = sov >= 1
        ? '${sov.toStringAsFixed(2)} SOV'
        : '${sov.toStringAsFixed(6)} SOV';

    String timeLabel = '';
    if (timestamp > 0) {
      final diff = DateTime.now()
          .difference(DateTime.fromMillisecondsSinceEpoch(timestamp));
      if (diff.inSeconds < 60)      { timeLabel = 'just now'; }
      else if (diff.inMinutes < 60) { timeLabel = '${diff.inMinutes}m ago'; }
      else if (diff.inHours < 24)   { timeLabel = '${diff.inHours}h ago'; }
      else                          { timeLabel = '${diff.inDays}d ago'; }
    }

    final short = counterparty.length > 22
        ? '${counterparty.substring(0, 11)}…${counterparty.substring(counterparty.length - 8)}'
        : counterparty;

    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const TransactionHistoryScreen()),
      ).then((_) => _loadRecentTxs()),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: _cardBg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withAlpha(10)),
        ),
        child: Row(
          children: [
            Container(
              width: 34, height: 34,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: accent.withAlpha(20),
                border: Border.all(color: accent.withAlpha(50)),
              ),
              child: Icon(icon, color: accent, size: 16),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    short.isEmpty ? _txTypeLabel(type) : short,
                    style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        fontFamily: 'monospace'),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (timeLabel.isNotEmpty)
                    Text(timeLabel,
                        style: const TextStyle(
                            color: Colors.white24, fontSize: 10)),
                ],
              ),
            ),
            Text(
              sovStr,
              style: TextStyle(
                  color: accent,
                  fontSize: 12,
                  fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }

  String _txTypeLabel(String type) {
    switch (type) {
      case 'sent':              return 'Sent';
      case 'received':          return 'Received';
      case 'enrollment_reward': return 'Enrollment Reward';
      default:                  return type;
    }
  }
}

// ── Small reusable widgets ─────────────────────────────────────────────────

class _BadgeChip extends StatelessWidget {
  final String label;
  const _BadgeChip({required this.label});

  @override
  Widget build(BuildContext context) {
    const gold = Color(0xFFD4AF37);
    return Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: gold.withAlpha(25),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: gold.withAlpha(100)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: gold,
          fontSize: 10,
          fontWeight: FontWeight.bold,
          fontFamily: 'monospace',
        ),
      ),
    );
  }
}

// ── Locked-balance pill ─────────────────────────────────────────────────────
// Reusable colour-tinted pill that shows how many SOV are locked and where.
// Used twice on the home screen — once for SOV Vault allocations (gold)
// and once for active exchange escrow (teal, SOV Shield).
class _LockedPill extends StatelessWidget {
  final int      seeds;
  final String   label;
  final Color    tint;
  final IconData icon;

  const _LockedPill({
    required this.seeds,
    required this.label,
    required this.tint,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final sov = seeds / 1000000;
    final text = sov >= 1
        ? '${sov.toStringAsFixed(2)} SOV $label'
        : '${sov.toStringAsFixed(6)} SOV $label';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: tint.withAlpha(18),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: tint.withAlpha(55)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: tint, size: 12),
          const SizedBox(width: 5),
          Text(
            text,
            style: TextStyle(
              color: tint, fontSize: 11, fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
