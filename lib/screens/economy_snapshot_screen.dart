// economy_snapshot_screen.dart — Live transparency view of the SOV economy.
//
// Shows every accounting location in the network in real time:
//   • 50M supply cap (immutable)
//   • 6 reserve pools (allocated / remaining / distributed)
//   • Citizen wallets aggregate
//   • Live invariant check: (pools + wallets) ≤ 50M
//
// Any citizen can audit the network here. Fetches from any relay node's
// /economy/snapshot HTTP endpoint and auto-refreshes every 10 seconds.

import 'dart:async';
import 'package:flutter/material.dart';
import '../sov_node_sdk/relay_connector.dart';

class EconomySnapshotScreen extends StatefulWidget {
  const EconomySnapshotScreen({super.key});

  @override
  State<EconomySnapshotScreen> createState() => _EconomySnapshotScreenState();
}

class _EconomySnapshotScreenState extends State<EconomySnapshotScreen> {
  static const _gold   = Color(0xFFC9A84C);
  static const _navy   = Color(0xFF0A0E27);
  static const _card   = Color(0xFF111630);
  static const _muted  = Color(0xFF8B92A8);

  Map<String, dynamic>? _snapshot;
  String? _error;
  Timer? _refreshTimer;
  DateTime? _lastFetch;

  @override
  void initState() {
    super.initState();
    _fetch();
    _refreshTimer = Timer.periodic(const Duration(seconds: 10), (_) => _fetch());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _fetch() async {
    final snap = await RelayConnector.getEconomySnapshot();
    if (!mounted) return;
    setState(() {
      if (snap != null) {
        _snapshot = snap;
        _error = null;
        _lastFetch = DateTime.now();
      } else if (_snapshot == null) {
        _error = 'Could not reach any relay node.';
      }
    });
  }

  String _fmtSov(int seeds) {
    final sov = seeds / 1000000.0;
    // Show enough precision that a SMALL deduction stays visible. At 2 decimals
    // of millions, a 30,000,000 pool that had paid out 1,000 SOV showed remaining
    // as "30.00M" — identical to allocated — so a real payout looked like nothing
    // had left the pool. With trailing zeros trimmed, an untouched pool still
    // reads "30M", but 29,999,000 now reads "29.999M".
    if (sov >= 1000000) return '${_trimZeros((sov / 1000000).toStringAsFixed(3))}M';
    if (sov >= 1000)    return '${_trimZeros((sov / 1000).toStringAsFixed(2))}K';
    if (sov >= 1)       return sov.toStringAsFixed(0);
    return sov.toStringAsFixed(4);
  }

  // Drops trailing zeros (and a dangling point) so "30.000" → "30", "29.999"
  // stays, "1.00" → "1".
  String _trimZeros(String s) {
    if (!s.contains('.')) return s;
    s = s.replaceAll(RegExp(r'0+$'), '');
    return s.endsWith('.') ? s.substring(0, s.length - 1) : s;
  }

  String _fmtFullSov(int seeds) {
    final sov = seeds / 1000000.0;
    return sov.toStringAsFixed(sov >= 1 ? 0 : 6) + ' SOV';
  }

  // A tiny-but-real distribution (e.g. 1,000 of 30,000,000 = 0.0033%) used to
  // round to "0.00%", reading as "nothing distributed" right next to a "Paid out
  // 1.0K". Show "<0.01%" whenever something HAS been paid but rounds below the
  // display precision, so the row can never contradict itself.
  String _fmtPct(double pct) {
    final p = pct * 100;
    if (p > 0 && p < 0.01) return '<0.01%';
    return '${p.toStringAsFixed(2)}%';
  }

  String _poolLabel(String id) {
    switch (id) {
      case 'citizen_enrollment':    return 'Citizen Enrollment Rewards';
      case 'witness_operator':      return 'Relay Operator Pool';
      case 'pioneer':               return 'Pioneer Referral Rewards';
      case 'foundation_treasury':   return 'Foundation Treasury';
      case 'community_contributors':return 'Community Contributors';
      // Legacy IDs (pre-fair-launch-refactor) — kept for backwards-compat with any
      // older relay still serving them; display only, no economic effect on a
      // fair-launch network where these pools no longer exist.
      case 'founder_allocation':    return 'Founder Stream (deprecated)';
      case 'early_contributors':    return 'Early Contributors (deprecated)';
      default: return id;
    }
  }

  String _poolNote(String id) {
    switch (id) {
      case 'citizen_enrollment':    return 'Pays each new citizen at enrollment per tier gradient. When empty, governance vote activates continuation rewards.';
      case 'witness_operator':      return 'Funds relay operators. Grows from transfer fees + SOV Link fees + the 10 SOV platform-registration fee. Distributed monthly via governance-set algorithm.';
      case 'pioneer':               return 'Rewards referrals + certifications. Sunsets when governance votes pioneer_rewards_active = 0.';
      case 'foundation_treasury':   return 'Community-governed tranches. Citizens vote on allocation via Allocation Protocol.';
      case 'community_contributors':return 'Genesis cap 0. Citizen governance vote required, ≥10,000 enrolled citizens, allocations from witness_operator surplus only.';
      case 'founder_allocation':    return 'Removed in fair-launch refactor (2026-05-27). No new credits — the protocol no longer creates founder-stream entries. Cap merged into witness_operator pool.';
      case 'early_contributors':    return 'Removed in fair-launch refactor (2026-05-27). Renamed to community_contributors with cap 0; releases require citizen governance vote.';
      default: return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _navy,
      appBar: AppBar(
        backgroundColor: _navy,
        elevation: 0,
        title: const Text('SOV Network Economy',
            style: TextStyle(color: _gold, fontWeight: FontWeight.w600, fontSize: 18)),
        iconTheme: const IconThemeData(color: _gold),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: _gold),
            tooltip: 'Refresh now',
            onPressed: _fetch,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_snapshot == null && _error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.cloud_off_rounded, color: _muted, size: 48),
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: _muted), textAlign: TextAlign.center),
            const SizedBox(height: 16),
            TextButton(onPressed: _fetch, child: const Text('Retry', style: TextStyle(color: _gold))),
          ]),
        ),
      );
    }
    if (_snapshot == null) {
      return const Center(child: CircularProgressIndicator(color: _gold));
    }
    final s = _snapshot!;
    final pools     = (s['pools'] as List?) ?? [];
    final wallets   = s['wallets']   as Map? ?? {};
    final invariant = s['invariant'] as Map? ?? {};
    final cap       = (s['supply_cap_seeds'] as num?)?.toInt() ?? 50000000000000;
    final wTotal    = (wallets['total_seeds'] as num?)?.toInt() ?? 0;

    // [GHOST-COUNT 2026-08-14] Do NOT render `citizen_count` as citizens without
    // checking first. On a node that has not yet been rebuilt it is COUNT(*) over
    // sov_disc — WALLET SLOTS, not humans. sov_disc gains a 0-balance row for any
    // sovereign_id that merely opens a signed session (touchLiveness ->
    // ensureDiscEntry), so it counts strangers who connected once and never
    // enrolled. On the genesis chain that read 2 "citizens" against 1 enrollment.
    //
    // This screen ships BEFORE the node rebuild that fixes it, and the mesh is
    // refreshed one node at a time, so both shapes are live at once and this
    // screen picks whichever node it is connected to. `wallet_slot_count` is the
    // discriminator: it exists only on a corrected node (snapshot schema v3),
    // which is also the only node whose `citizen_count` counts sov_enrollments.
    // When it is absent we show the slot figure under its true name and say the
    // citizen count is unavailable, rather than over-reporting humans ~2:1.
    final slotCount = (wallets['wallet_slot_count'] as num?)?.toInt();
    final corrected = slotCount != null;
    final cCount    = corrected ? ((wallets['citizen_count'] as num?)?.toInt() ?? 0) : null;
    final wSlots    = slotCount ?? (wallets['citizen_count'] as num?)?.toInt() ?? 0;
    final pTotal    = pools.fold<int>(0, (sum, p) => sum + ((p['remaining_seeds'] as num?)?.toInt() ?? 0));
    final grand     = (invariant['grand_total_seeds'] as num?)?.toInt() ?? (wTotal + pTotal);
    final ok        = invariant['ok'] == true;

    return RefreshIndicator(
      onRefresh: _fetch,
      color: _gold,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Header — 50M cap + invariant status ──────────────────────────
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: _card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: ok ? _gold.withOpacity(0.3) : Colors.red.withOpacity(0.5)),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(ok ? Icons.verified_rounded : Icons.warning_amber_rounded,
                    color: ok ? Colors.greenAccent : Colors.redAccent, size: 22),
                const SizedBox(width: 8),
                Text(ok ? 'Network supply within 50M cap' : 'SUPPLY INVARIANT BROKEN',
                    style: TextStyle(color: ok ? Colors.greenAccent : Colors.redAccent,
                        fontWeight: FontWeight.w600)),
              ]),
              const SizedBox(height: 12),
              const Text('Total minted from genesis',
                  style: TextStyle(color: _muted, fontSize: 12)),
              Text('${_fmtFullSov(cap)}',
                  style: const TextStyle(color: _gold, fontSize: 24, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text('In reserve pools',
                  style: TextStyle(color: _muted, fontSize: 12)),
              Text(_fmtFullSov(pTotal),
                  style: const TextStyle(color: Colors.white, fontSize: 16)),
              const Text('In citizen wallets',
                  style: TextStyle(color: _muted, fontSize: 12)),
              Text(_fmtFullSov(wTotal),
                  style: const TextStyle(color: Colors.white, fontSize: 16)),
              Text(
                  cCount != null
                      ? '$cCount citizens · $wSlots wallet slots'
                      : '$wSlots wallet slots · citizen count unavailable from this node',
                  style: const TextStyle(color: _muted, fontSize: 11)),
              const SizedBox(height: 8),
              Container(height: 1, color: _muted.withOpacity(0.2)),
              const SizedBox(height: 8),
              const Text('Live total (pools + wallets)',
                  style: TextStyle(color: _muted, fontSize: 12)),
              Text(_fmtFullSov(grand),
                  style: TextStyle(
                      color: ok ? Colors.white : Colors.redAccent,
                      fontSize: 16,
                      fontWeight: FontWeight.w600)),
              if (_lastFetch != null) ...[
                const SizedBox(height: 8),
                Text('Updated ${_lastFetch!.toLocal().toString().substring(11, 19)}',
                    style: const TextStyle(color: _muted, fontSize: 10)),
              ],
            ]),
          ),
          const SizedBox(height: 16),

          // ── Pool cards ───────────────────────────────────────────────────
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Text('Reserve pools', style: TextStyle(color: _gold, fontSize: 16, fontWeight: FontWeight.w600)),
          ),
          ...pools.map((p) => _poolCard(p as Map<String, dynamic>)),

          // ── Fee revenue (money flowing INTO the pools) — public ledger ─────
          _buildInflowsSection(s),

          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _card.withOpacity(0.5),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _muted.withOpacity(0.2)),
            ),
            child: const Text(
              'The 50,000,000 SOV total supply is fixed forever. Every SOV is either '
              'in a reserve pool or in a citizen wallet. Reserve pools are operated by '
              'the protocol — no person, company, or government can change these '
              'balances. Pools fill from transfer fees and platform registration fees, '
              'and pay out to citizens according to protocol rules. This screen updates '
              'every 10 seconds directly from the relay node you are connected to.',
              style: TextStyle(color: _muted, fontSize: 12, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

  // Fee-revenue section: every fund that flows INTO the pools (transfer fees,
  // platform registration, exchange fees), plus what has been paid out to
  // operators. Makes the sustainability loop visible on the public ledger.
  // Reads snapshot schema v2 (`inflows` + `operator_payouts`); on an older node
  // (v1, no inflows) the section renders nothing.
  Widget _buildInflowsSection(Map<String, dynamic> s) {
    final inflows = s['inflows'] as Map? ?? {};
    final payouts = s['operator_payouts'] as Map? ?? {};
    if (inflows.isEmpty && payouts.isEmpty) return const SizedBox.shrink();

    final allTime  = (inflows['all_time_seeds'] as num?)?.toInt() ?? 0;
    final byPool   = (inflows['by_pool'] as List?) ?? [];
    final paidOut  = (payouts['total_paid_seeds'] as num?)?.toInt() ?? 0;
    final payCount = (payouts['payout_count'] as num?)?.toInt() ?? 0;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 20),
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Text('Fee revenue → operator pool', style: TextStyle(color: _gold, fontSize: 16, fontWeight: FontWeight.w600)),
      ),
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _gold.withOpacity(0.2)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Total fees collected (all time)',
              style: TextStyle(color: _muted, fontSize: 12)),
          Text(_fmtFullSov(allTime),
              style: const TextStyle(color: Colors.greenAccent, fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          const Text('Transfer fees + platform registration + exchange fees — every '
              'fund routed into the operator reward pool.',
              style: TextStyle(color: _muted, fontSize: 11, height: 1.4)),
          if (byPool.isNotEmpty) ...[
            const SizedBox(height: 12),
            ...byPool.map((r) {
              final m = r as Map<String, dynamic>;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Text(_poolLabel(m['pool_id'] as String? ?? '?'),
                      style: const TextStyle(color: Colors.white70, fontSize: 12)),
                  Text(_fmtFullSov((m['total_seeds'] as num?)?.toInt() ?? 0),
                      style: const TextStyle(color: Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.w600)),
                ]),
              );
            }),
          ],
          const SizedBox(height: 12),
          Container(height: 1, color: _muted.withOpacity(0.2)),
          const SizedBox(height: 12),
          const Text('Paid out to operators',
              style: TextStyle(color: _muted, fontSize: 12)),
          Text('${_fmtFullSov(paidOut)}  ($payCount payouts)',
              style: const TextStyle(color: _gold, fontSize: 16, fontWeight: FontWeight.w600)),
        ]),
      ),
    ]);
  }

  Widget _poolCard(Map<String, dynamic> p) {
    final id = p['pool_id'] as String? ?? '?';
    final allocated   = (p['allocated_seeds']   as num?)?.toInt() ?? 0;
    final remaining   = (p['remaining_seeds']   as num?)?.toInt() ?? 0;
    final distributed = (p['distributed_seeds'] as num?)?.toInt() ?? 0;
    final pct = allocated > 0 ? distributed / allocated : 0.0;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _muted.withOpacity(0.15)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(_poolLabel(id),
            style: const TextStyle(color: _gold, fontSize: 15, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Text(_poolNote(id),
            style: const TextStyle(color: _muted, fontSize: 11, height: 1.4)),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Allocated', style: TextStyle(color: _muted, fontSize: 10)),
            Text(_fmtSov(allocated) + ' SOV',
                style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w500)),
          ])),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Remaining', style: TextStyle(color: _muted, fontSize: 10)),
            Text(_fmtSov(remaining) + ' SOV',
                style: const TextStyle(color: _gold, fontSize: 13, fontWeight: FontWeight.w500)),
          ])),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Paid out', style: TextStyle(color: _muted, fontSize: 10)),
            Text(_fmtSov(distributed) + ' SOV',
                style: const TextStyle(color: Colors.greenAccent, fontSize: 13, fontWeight: FontWeight.w500)),
          ])),
        ]),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: pct,
            backgroundColor: _muted.withOpacity(0.15),
            color: _gold,
            minHeight: 6,
          ),
        ),
        const SizedBox(height: 4),
        Text('${_fmtPct(pct)} distributed',
            style: const TextStyle(color: _muted, fontSize: 10)),
      ]),
    );
  }
}
