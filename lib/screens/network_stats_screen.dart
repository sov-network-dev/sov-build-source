// lib/screens/network_stats_screen.dart
// S14 — SOV Network Dashboard
// Read-only live stats. Auto-refreshes every 30 seconds.
// No new relay schema — aggregates from existing DB tables.

import 'dart:async';
import 'package:flutter/material.dart';
import '../sov_node_sdk/relay_connector.dart';

class NetworkStatsScreen extends StatefulWidget {
  const NetworkStatsScreen({super.key});

  @override
  State<NetworkStatsScreen> createState() => _NetworkStatsScreenState();
}

class _NetworkStatsScreenState extends State<NetworkStatsScreen> {
  Map<String, dynamic>? _stats;
  bool   _loading  = true;
  String _error    = '';
  Timer? _timer;
  DateTime? _lastUpdated;

  @override
  void initState() {
    super.initState();
    _fetch();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _fetch());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _fetch() async {
    if (!mounted) return;
    setState(() { _loading = true; _error = ''; });
    try {
      final res = await RelayConnector.getNetworkStats();
      if (!mounted) return;
      if (res != null && res['error'] == null) {
        setState(() {
          _stats       = res;
          _lastUpdated = DateTime.now();
          _loading     = false;
        });
      } else {
        setState(() {
          _error   = res?['error'] ?? 'No response from relay';
          _loading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  // ── Formatting helpers ───────────────────────────────────────────────────

  String _fmtSeeds(dynamic seeds) {
    final s = (seeds is int) ? seeds : (seeds is double ? seeds.toInt() : int.tryParse(seeds.toString()) ?? 0);
    final sov = s / 1000000.0;
    if (sov >= 1000000) return '${(sov / 1000000).toStringAsFixed(2)}M SOV';
    if (sov >= 1000)    return '${(sov / 1000).toStringAsFixed(2)}K SOV';
    return '${sov.toStringAsFixed(2)} SOV';
  }

  String _fmtCount(dynamic n) {
    final v = (n is int) ? n : (int.tryParse(n.toString()) ?? 0);
    if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
    if (v >= 1000)    return '${(v / 1000).toStringAsFixed(1)}K';
    return v.toString();
  }

  String _timeAgo() {
    if (_lastUpdated == null) return '';
    final diff = DateTime.now().difference(_lastUpdated!).inSeconds;
    if (diff < 5)  return 'just now';
    if (diff < 60) return '${diff}s ago';
    return '${(diff / 60).floor()}m ago';
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const ValueKey('networkStatsScaffold'),
      backgroundColor: const Color(0xFF0A1628),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A1628),
        elevation: 0,
        title: const Text(
          'SOV Network',
          style: TextStyle(color: Color(0xFFD4AF37), fontWeight: FontWeight.w700, fontSize: 18),
        ),
        iconTheme: const IconThemeData(color: Color(0xFFD4AF37)),
        actions: [
          if (_lastUpdated != null)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Center(
                child: Text(
                  _timeAgo(),
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                ),
              ),
            ),
          IconButton(
            icon: _loading
                ? const SizedBox(
                    width: 18, height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2, color: Color(0xFFD4AF37),
                    ),
                  )
                : const Icon(Icons.refresh_rounded, color: Color(0xFFD4AF37)),
            onPressed: _loading ? null : _fetch,
          ),
        ],
      ),
      body: _error.isNotEmpty && _stats == null
          ? _buildError()
          : _stats == null
              ? const Center(child: CircularProgressIndicator(color: Color(0xFFD4AF37)))
              : _buildStats(),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, color: Colors.white24, size: 48),
            const SizedBox(height: 16),
            const Text('Could not reach relay',
                style: TextStyle(color: Colors.white54, fontSize: 15)),
            const SizedBox(height: 8),
            Text(_error,
                style: const TextStyle(color: Colors.white24, fontSize: 12),
                textAlign: TextAlign.center),
            const SizedBox(height: 24),
            TextButton(
              onPressed: _fetch,
              child: const Text('Retry', style: TextStyle(color: Color(0xFFD4AF37))),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStats() {
    final s         = _stats!;
    final enrolled  = s['enrolled_citizens'] ?? 0;
    final relays    = s['active_relays']     ?? 1;
    final totalSov  = s['total_sov_seeds']   ?? 0;
    final tx24h     = s['transfers_24h']     ?? 0;
    final vol24h    = s['volume_seeds_24h']  ?? 0;
    final polls     = s['open_polls']        ?? 0;
    final disputes  = s['open_disputes']     ?? 0;
    // Always use the actual connected node's nickname (same as Relay Pool screen).
    // The relay_id field returned from the server is the env var ("VPS1", "VPS2" etc.)
    // not the peer-mesh node ID, so getNickname(relayId) would produce a different
    // name. currentRelayNickname uses the real peer-mesh node ID resolved at connect time.
    final relayDisplay = RelayConnector.currentRelayNickname;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Connected relay chip ─────────────────────────────────────────
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF0D1F3A),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFFD4AF37).withAlpha(60)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 7, height: 7,
                    decoration: const BoxDecoration(
                      color: Color(0xFF4CAF50),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Node: $relayDisplay',
                    style: const TextStyle(
                        color: Color(0xFFD4AF37), fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),

          // ── Primary stats grid ───────────────────────────────────────────
          _sectionLabel('CITIZENS & NETWORK'),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: _statCard(
              icon: Icons.people_alt_rounded,
              label: 'Enrolled Citizens',
              value: _fmtCount(enrolled),
              color: const Color(0xFFD4AF37),
            )),
            const SizedBox(width: 10),
            Expanded(child: _statCard(
              icon: Icons.dns_rounded,
              label: 'Active Relays',
              value: relays.toString(),
              color: const Color(0xFF4CAF50),
            )),
          ]),
          const SizedBox(height: 10),

          _sectionLabel('SOV ECONOMY'),
          const SizedBox(height: 10),
          _statCardWide(
            icon: Icons.account_balance_wallet_rounded,
            label: 'Total SOV in Circulation',
            value: _fmtSeeds(totalSov),
            color: const Color(0xFFD4AF37),
            subtitle: '50M SOV maximum supply',
          ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: _statCard(
              icon: Icons.swap_horiz_rounded,
              label: 'Transfers (24h)',
              value: _fmtCount(tx24h),
              color: const Color(0xFF64B5F6),
            )),
            const SizedBox(width: 10),
            Expanded(child: _statCard(
              icon: Icons.show_chart_rounded,
              label: 'Volume (24h)',
              value: _fmtSeeds(vol24h),
              color: const Color(0xFF64B5F6),
            )),
          ]),
          const SizedBox(height: 10),

          _sectionLabel('GOVERNANCE & JUSTICE'),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: _statCard(
              icon: Icons.how_to_vote_rounded,
              label: 'Open Polls',
              value: polls.toString(),
              color: const Color(0xFFBA68C8),
            )),
            const SizedBox(width: 10),
            Expanded(child: _statCard(
              icon: Icons.gavel_rounded,
              label: 'Open Cases',
              value: disputes.toString(),
              color: const Color(0xFFFF8A65),
            )),
          ]),
          const SizedBox(height: 24),

          // ── Footer ───────────────────────────────────────────────────────
          Center(
            child: Text(
              'Auto-refreshes every 30 seconds',
              style: TextStyle(color: Colors.white.withAlpha(40), fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Text(
      text,
      style: const TextStyle(
        color: Colors.white38,
        fontSize: 10,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.2,
      ),
    );
  }

  Widget _statCard({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF0D1F3A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withAlpha(10)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(height: 10),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 22,
              fontWeight: FontWeight.w700,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(color: Colors.white38, fontSize: 11),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _statCardWide({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
    String? subtitle,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF0D1F3A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withAlpha(10)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 32),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: TextStyle(
                    color: color,
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(height: 2),
                Text(label,
                    style: const TextStyle(color: Colors.white54, fontSize: 12)),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: const TextStyle(color: Colors.white24, fontSize: 10)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
