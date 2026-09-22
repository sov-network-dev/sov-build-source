// lib/screens/inheritance_screen.dart
// Screen — SOV Vault (Allocation System)
//
// Tab 1 — My Vaults       : list of locked allocations with cancel option
// Tab 2 — Claim a Vault   : stage-1 (claim key) + stage-2 (family keys) paths
// Tab 3 — Justice Council : active councils where user is a member or claimant
//
// All crypto is client-side via InheritanceCrypto.
// All relay calls are via RelayConnector inheritance methods.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../sov_node_sdk/relay_connector.dart';
import '../sov_node_sdk/inheritance_crypto.dart';
import '../sov_node_sdk/draft_manager.dart';
import '../sov_node_sdk/draft_keys.dart';

class InheritanceScreen extends StatefulWidget {
  final String sovereignId;
  final int    seeds;
  const InheritanceScreen({
    super.key,
    required this.sovereignId,
    required this.seeds,
  });

  @override
  State<InheritanceScreen> createState() => _InheritanceScreenState();
}

class _InheritanceScreenState extends State<InheritanceScreen>
    with SingleTickerProviderStateMixin {

  // ── Brand colours ────────────────────────────────────────────────────────────
  static const _navy   = Color(0xFF0A1628);
  static const _gold   = Color(0xFFB8960C);
  static const _cardBg = Color(0xFF0D1F3A);
  static const _teal   = Color(0xFF006B5E);

  late final TabController _tabs;

  // Tab 1 — Allocations
  List<Map<String, dynamic>> _allocations   = [];
  int                        _lockedSeeds   = 0;
  bool                       _allocLoading  = true;

  // Tab 2 — Claim
  bool                       _claimLoading  = false;
  String                     _claimError    = '';
  String                     _claimSuccess  = '';

  // Tab 3 — Councils
  List<Map<String, dynamic>> _councils      = [];
  bool                       _councilLoading = true;

  // ── Lifecycle ────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    _tabs.addListener(() {
      if (!_tabs.indexIsChanging) _onTabChange(_tabs.index);
    });
    _loadAllocations();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _onTabChange(int idx) {
    if (idx == 0) _loadAllocations();
    if (idx == 2) _loadCouncils();
  }

  // ── Data loaders ─────────────────────────────────────────────────────────────

  Future<void> _loadAllocations() async {
    setState(() => _allocLoading = true);
    try {
      if (!RelayConnector.isConnected) await RelayConnector.connect();
      final result = await RelayConnector.fetchAllocationList(widget.sovereignId);
      if (!mounted) return;
      setState(() {
        _allocations = (result['allocations'] as List?)
                ?.cast<Map<String, dynamic>>() ?? [];
        _lockedSeeds = (result['total_locked_seeds'] as num?)?.toInt() ?? 0;
        _allocLoading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _allocLoading = false; });
    }
  }

  Future<void> _loadCouncils() async {
    setState(() => _councilLoading = true);
    try {
      if (!RelayConnector.isConnected) await RelayConnector.connect();
      final list = await RelayConnector.fetchMyCouncils(widget.sovereignId);
      if (!mounted) return;
      setState(() { _councils = list; _councilLoading = false; });
    } catch (e) {
      if (mounted) setState(() { _councilLoading = false; });
    }
  }

  // ── Cancel allocation ─────────────────────────────────────────────────────────

  Future<void> _cancelAllocation(String allocationId) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _cardBg,
        title: const Text('Cancel Vault',
            style: TextStyle(color: Colors.white)),
        content: const Text(
            'Cancel this vault? Seeds will be unlocked and returned to your available balance.',
            style: TextStyle(color: Colors.white54)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep', style: TextStyle(color: Colors.white54))),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Cancel Vault',
                  style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      if (!RelayConnector.isConnected) await RelayConnector.connect();
      final resp = await RelayConnector.cancelAllocation(
          widget.sovereignId, allocationId);
      if (!mounted) return;
      if (resp['success'] == true) {
        await _loadAllocations();
        _showSnack('Vault cancelled — seeds unlocked', isError: false);
      } else {
        _showSnack(resp['error'] as String? ?? 'Cancel failed', isError: true);
      }
    } catch (e) {
      if (mounted) _showSnack(e.toString(), isError: true);
    }
  }

  // ── Stage-1 claim (claim key) ─────────────────────────────────────────────────

  Future<void> _doClaimStage1(String claimKey) async {
    setState(() { _claimLoading = true; _claimError = ''; _claimSuccess = ''; });
    try {
      if (!RelayConnector.isConnected) await RelayConnector.connect();
      final hash = InheritanceCrypto.hashClaimKey(claimKey);
      final resp = await RelayConnector.claimStage1(widget.sovereignId, hash);
      if (!mounted) return;
      if (resp['success'] == true) {
        setState(() {
          _claimSuccess = 'Claim approved! Funds transferred to your balance.';
          _claimLoading = false;
        });
        _loadAllocations();
      } else {
        setState(() {
          _claimError   = resp['error'] as String? ?? 'Claim failed';
          _claimLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() { _claimError = e.toString(); _claimLoading = false; });
    }
  }

  // ── Stage-2 claim (family keys + council) ────────────────────────────────────

  Future<void> _doClaimStage2(
      String allocationId,
      List<String> familyKeys,
      String statement) async {
    setState(() { _claimLoading = true; _claimError = ''; _claimSuccess = ''; });
    try {
      if (!RelayConnector.isConnected) await RelayConnector.connect();
      final hashes = familyKeys
          .where((k) => k.trim().isNotEmpty)
          .map(InheritanceCrypto.hashFamilyKey)
          .toList();
      final resp = await RelayConnector.claimStage2(
          widget.sovereignId, allocationId, hashes, statement);
      if (!mounted) return;
      if (resp['success'] == true) {
        setState(() {
          _claimSuccess =
              'Justice council formed — ${resp['council_size'] ?? '?'} members assigned. '
              'You will be notified when a 2/3 majority votes.';
          _claimLoading = false;
        });
        _loadCouncils();
        _tabs.animateTo(2);
      } else {
        setState(() {
          _claimError   = resp['error'] as String? ?? 'Stage-2 claim failed';
          _claimLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() { _claimError = e.toString(); _claimLoading = false; });
    }
  }

  // ── Council vote ──────────────────────────────────────────────────────────────

  Future<void> _castVote(int councilId, String vote) async {
    try {
      if (!RelayConnector.isConnected) await RelayConnector.connect();
      final resp = await RelayConnector.castCouncilVote(
          widget.sovereignId, councilId, vote);
      if (!mounted) return;
      if (resp['success'] == true) {
        _showSnack('Vote recorded', isError: false);
        _loadCouncils();
      } else {
        _showSnack(resp['error'] as String? ?? 'Vote failed', isError: true);
      }
    } catch (e) {
      if (mounted) _showSnack(e.toString(), isError: true);
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────────

  void _showSnack(String msg, {required bool isError}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: isError ? Colors.red.shade800 : _teal,
      behavior: SnackBarBehavior.floating,
    ));
  }

  String _formatSov(int seeds) {
    final sov = seeds / 1000000;
    return sov >= 1
        ? '${sov.toStringAsFixed(2)} SOV'
        : '${sov.toStringAsFixed(6)} SOV';
  }

  String _statusLabel(String? s) {
    switch (s) {
      case 'locked':    return 'Locked';
      case 'published': return 'Published';
      case 'claimed':   return 'Claimed';
      case 'cancelled': return 'Cancelled';
      default:          return s ?? '—';
    }
  }

  Color _statusColor(String? s) {
    switch (s) {
      case 'locked':    return _gold;
      case 'published': return Colors.blueAccent;
      case 'claimed':   return Colors.green;
      case 'cancelled': return Colors.white38;
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
        title: const Text('SOV Vault',
            style: TextStyle(
                color: Color(0xFFB8960C),
                fontWeight: FontWeight.bold,
                fontSize: 18)),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_rounded, color: Color(0xFFB8960C)),
            tooltip: 'New Vault',
            onPressed: () => _showAddAllocationSheet(),
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          labelColor: _gold,
          unselectedLabelColor: Colors.white38,
          indicatorColor: _gold,
          indicatorWeight: 2,
          labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          tabs: const [
            Tab(text: 'My Vaults'),
            Tab(text: 'Claim a Vault'),
            Tab(text: 'Justice Council'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _buildAllocationsTab(),
          _buildClaimTab(),
          _buildCouncilTab(),
        ],
      ),
    );
  }

  // ── TAB 1 — My Vaults ───────────────────────────────────────────────────────

  Widget _buildAllocationsTab() {
    if (_allocLoading) {
      return const Center(
          child: CircularProgressIndicator(color: Color(0xFFB8960C)));
    }

    final available = widget.seeds - _lockedSeeds;

    return RefreshIndicator(
      onRefresh: _loadAllocations,
      color: _gold,
      backgroundColor: _cardBg,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // Summary row
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _cardBg,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _gold.withAlpha(40)),
            ),
            child: Row(children: [
              Expanded(child: _summaryCell('Available',
                  _formatSov(available < 0 ? 0 : available),
                  Colors.greenAccent)),
              Container(width: 1, height: 36,
                  color: Colors.white12),
              Expanded(child: _summaryCell('In Vault',
                  _formatSov(_lockedSeeds), _gold)),
              Container(width: 1, height: 36,
                  color: Colors.white12),
              Expanded(child: _summaryCell('Total',
                  _formatSov(widget.seeds), Colors.white60)),
            ]),
          ),
          const SizedBox(height: 16),

          // ── Will / Vault protocol awareness + proof-of-life reassurance ──────
          _buildWillAwarenessCard(),
          const SizedBox(height: 20),

          if (_allocations.isEmpty)
            Center(
              child: Column(children: [
                const SizedBox(height: 40),
                const Icon(Icons.lock_outline_rounded,
                    color: Colors.white24, size: 48),
                const SizedBox(height: 12),
                const Text('No vaults yet',
                    style: TextStyle(color: Colors.white38, fontSize: 15)),
                const SizedBox(height: 8),
                const Text('Tap + to create your first vault',
                    style: TextStyle(color: Colors.white24, fontSize: 12)),
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  onPressed: _showAddAllocationSheet,
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Create New Vault'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _gold,
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ]),
            )
          else
            ...(_allocations.where((a) {
              // TASK 2B: hide cancelled vaults older than 7 days
              if (a['status'] == 'cancelled') {
                final createdAt = (a['created_at'] as num?)?.toInt() ?? 0;
                // Use cancelled_at if available, fall back to created_at
                final cancelledAt = (a['cancelled_at'] as num?)?.toInt() ?? createdAt;
                if (cancelledAt > 0) {
                  final ageDays = (DateTime.now().millisecondsSinceEpoch ~/ 1000
                      - cancelledAt) ~/ 86400;
                  if (ageDays > 7) return false;
                }
              }
              return true;
            }).map((a) => _buildAllocationCard(a))),
        ],
      ),
    );
  }

  // ── Will / Vault protocol explainer + "your funds are safe" reassurance ──────
  // The SOV network is built so an active citizen can NEVER lose funds, and a
  // departed citizen's funds can always be found + claimed by their family.
  Widget _buildWillAwarenessCard() {
    // Being connected and logged in IS proof-of-life: the relay refreshes
    // liveness_ts on every HELLO / LIVENESS_CHECK. While you keep logging in,
    // your vaults stay locked to you and are untouchable by anyone.
    final alive = RelayConnector.isConnected;
    final proof = alive ? 'today (you are logged in)' : 'reconnect to refresh';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _teal.withAlpha(28),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _teal.withAlpha(90)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(children: [
            Icon(Icons.shield_moon_rounded, color: Color(0xFF3FD9C2), size: 20),
            SizedBox(width: 8),
            Expanded(child: Text('Your funds can never be lost',
                style: TextStyle(color: Colors.white,
                    fontSize: 14.5, fontWeight: FontWeight.bold))),
          ]),
          const SizedBox(height: 10),
          const Text(
            'Lock SOV for your family with a claim key and private clues only '
            'they would know. While you stay active your vaults are untouchable. '
            'If you are gone for 20 years with no proof-of-life, the network '
            'broadcasts your vaults so your family can search by name and claim '
            'them with the clues. Return any time and your funds are instantly '
            'yours again — even if they were stewarded, they are restored in full.',
            style: TextStyle(color: Colors.white70, fontSize: 12.5, height: 1.45),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: Colors.black.withAlpha(60),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(children: [
              Icon(alive ? Icons.favorite_rounded : Icons.sync_problem_rounded,
                  color: alive ? Colors.greenAccent : Colors.orangeAccent,
                  size: 16),
              const SizedBox(width: 8),
              Expanded(child: Text('Last proof-of-life: $proof',
                  style: const TextStyle(color: Colors.white60, fontSize: 12))),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _summaryCell(String label, String value, Color color) {
    return Column(children: [
      Text(value,
          style: TextStyle(
              color: color, fontSize: 13, fontWeight: FontWeight.bold)),
      const SizedBox(height: 4),
      Text(label,
          style: const TextStyle(color: Colors.white38, fontSize: 10)),
    ]);
  }

  Widget _buildAllocationCard(Map<String, dynamic> alloc) {
    final id          = alloc['id']          as String? ?? '';
    final amount      = (alloc['amount_seeds'] as num?)?.toInt() ?? 0;
    final status      = alloc['status']      as String?;
    final releaseDate = (alloc['release_date'] as num?)?.toInt() ?? 0;
    final note        = alloc['public_statement'] as String?;

    final releaseStr = releaseDate > 0
        ? DateTime.fromMillisecondsSinceEpoch(releaseDate * 1000)
            .toString()
            .substring(0, 10)
        : '—';

    final canCancel = status == 'locked';

    // TASK 2B: muted style for recently-cancelled (grace-period) vaults
    final isRecentlyCancelled = status == 'cancelled';

    return Opacity(
      opacity: isRecentlyCancelled ? 0.45 : 1.0,
      child: Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withAlpha(20)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: _statusColor(status).withAlpha(30),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _statusColor(status).withAlpha(80)),
            ),
            child: Text(_statusLabel(status),
                style: TextStyle(
                    color: _statusColor(status),
                    fontSize: 11,
                    fontWeight: FontWeight.bold)),
          ),
          const Spacer(),
          Text(_formatSov(amount),
              style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 15)),
        ]),
        const SizedBox(height: 10),
        _infoRow(Icons.calendar_today_outlined,
            'Releases: $releaseStr', Colors.white54),
        if (note != null && note.isNotEmpty) ...[
          const SizedBox(height: 6),
          _infoRow(Icons.notes_rounded, note, Colors.white38),
        ],
        const SizedBox(height: 4),
        _infoRow(Icons.fingerprint_rounded,
            '${id.substring(0, 8)}…', Colors.white24),
        if (canCancel) ...[
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => _cancelAllocation(id),
              icon: const Icon(Icons.cancel_outlined,
                  color: Colors.redAccent, size: 16),
              label: const Text('Cancel',
                  style: TextStyle(color: Colors.redAccent, fontSize: 12)),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 6),
              ),
            ),
          ),
        ],
      ]),
    ),
    );
  }

  Widget _infoRow(IconData icon, String text, Color color) {
    return Row(children: [
      Icon(icon, color: color, size: 13),
      const SizedBox(width: 6),
      Flexible(child: Text(text, style: TextStyle(color: color, fontSize: 12))),
    ]);
  }

  // ── TAB 2 — Claim a Vault ────────────────────────────────────────────────────

  Widget _buildClaimTab() {
    final kb = MediaQuery.viewInsetsOf(context).bottom;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + kb),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Explainer card
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _teal.withAlpha(26),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _teal.withAlpha(70)),
          ),
          child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('How to claim a vault',
                    style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 14)),
                SizedBox(height: 8),
                Text(
                  'Stage 1 — Use the claim key given to you by the vault owner. '
                  'Instant transfer on correct key.\n\n'
                  'Stage 2 — If the claim key is lost, provide up to 3 family '
                  'verification phrases. A justice council of enrolled citizens '
                  'votes on your claim over 7 days.',
                  style: TextStyle(
                      color: Colors.white54, fontSize: 13, height: 1.5),
                ),
              ]),
        ),
        const SizedBox(height: 24),

        // Result banners
        if (_claimSuccess.isNotEmpty) ...[
          _resultBanner(_claimSuccess, isError: false),
          const SizedBox(height: 16),
        ],
        if (_claimError.isNotEmpty) ...[
          _resultBanner(_claimError, isError: true),
          const SizedBox(height: 16),
        ],

        // Stage 1 section
        _sectionHeader('STAGE 1 — CLAIM KEY'),
        const SizedBox(height: 12),
        _ClaimStage1Form(
          loading: _claimLoading,
          onSubmit: (claimKey) => _doClaimStage1(claimKey),
        ),
        const SizedBox(height: 28),

        // Stage 2 section
        _sectionHeader('STAGE 2 — FAMILY KEY PATH'),
        const SizedBox(height: 12),
        _ClaimStage2Form(
          loading: _claimLoading,
          onSubmit: (allocId, familyKeys, statement) =>
              _doClaimStage2(allocId, familyKeys, statement),
        ),
      ]),
    );
  }

  Widget _resultBanner(String msg, {required bool isError}) {
    final color = isError ? Colors.red : _teal;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withAlpha(80)),
      ),
      child: Text(msg,
          style: TextStyle(
              color: isError ? Colors.redAccent : Colors.white,
              fontSize: 13)),
    );
  }

  Widget _sectionHeader(String text) => Text(text,
      style: const TextStyle(
          color: Colors.white38, fontSize: 11, letterSpacing: 1.5));

  // ── TAB 3 — Justice Council ──────────────────────────────────────────────────

  Widget _buildCouncilTab() {
    if (_councilLoading) {
      return const Center(
          child: CircularProgressIndicator(color: Color(0xFFB8960C)));
    }

    return RefreshIndicator(
      onRefresh: _loadCouncils,
      color: _gold,
      backgroundColor: _cardBg,
      child: _councils.isEmpty
          ? ListView(padding: const EdgeInsets.all(20), children: const [
              SizedBox(height: 40),
              Center(
                child: Column(children: [
                  Icon(Icons.gavel_rounded, color: Colors.white24, size: 48),
                  SizedBox(height: 12),
                  Text('No active councils',
                      style: TextStyle(
                          color: Colors.white38, fontSize: 15)),
                  SizedBox(height: 8),
                  Text('Justice councils appear here when you are '
                      'a member or have an active claim.',
                      style: TextStyle(
                          color: Colors.white24,
                          fontSize: 12,
                          height: 1.5),
                      textAlign: TextAlign.center),
                ]),
              ),
            ])
          : ListView.builder(
              padding: const EdgeInsets.all(20),
              itemCount: _councils.length,
              itemBuilder: (_, i) => _buildCouncilCard(_councils[i]),
            ),
    );
  }

  Widget _buildCouncilCard(Map<String, dynamic> council) {
    final id         = (council['id'] as num?)?.toInt() ?? 0;
    final status     = council['status'] as String? ?? 'active';
    final approve    = (council['votes_approve'] as num?)?.toInt() ?? 0;
    final reject     = (council['votes_reject']  as num?)?.toInt() ?? 0;
    final abstain    = (council['votes_abstain'] as num?)?.toInt() ?? 0;
    final total      = approve + reject + abstain;
    final expiresAt  = (council['expires_at'] as num?)?.toInt() ?? 0;
    final isMember   = council['is_member'] == true;
    final hasVoted   = council['has_voted']  == true;
    final statement  = council['claimant_statement'] as String? ?? '';
    final claimant   = council['claimant_sovereign_id'] as String? ?? '';
    // ignore: unused_local_variable
    final allocationId = council['allocation_id'] as String? ?? '';

    final expiresStr = expiresAt > 0
        ? DateTime.fromMillisecondsSinceEpoch(expiresAt * 1000)
            .toString()
            .substring(0, 10)
        : '—';

    final isActive = status == 'active';

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: isActive ? _gold.withAlpha(50) : Colors.white.withAlpha(20)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: isActive
                  ? _gold.withAlpha(28)
                  : Colors.white.withAlpha(12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              isActive ? 'Active' : status.toUpperCase(),
              style: TextStyle(
                  color: isActive ? _gold : Colors.white38,
                  fontSize: 11,
                  fontWeight: FontWeight.bold),
            ),
          ),
          const Spacer(),
          Text('Council #$id',
              style: const TextStyle(color: Colors.white38, fontSize: 12)),
        ]),
        const SizedBox(height: 12),

        _infoRow(Icons.person_outline_rounded,
            'Claimant: ${claimant.length > 20 ? "${claimant.substring(0, 14)}…" : claimant}',
            Colors.white60),
        const SizedBox(height: 6),
        _infoRow(Icons.access_time_rounded, 'Expires: $expiresStr',
            Colors.white54),
        if (statement.isNotEmpty) ...[
          const SizedBox(height: 6),
          _infoRow(Icons.comment_outlined, statement, Colors.white38),
        ],
        const SizedBox(height: 12),

        _VoteTallyBar(approve: approve, reject: reject, abstain: abstain),
        const SizedBox(height: 4),
        Text('$total vote${total == 1 ? '' : 's'} cast',
            style: const TextStyle(color: Colors.white38, fontSize: 11)),

        if (isActive && isMember && !hasVoted) ...[
          const SizedBox(height: 14),
          Row(children: [
            _voteButton('Approve', Colors.green, () => _castVote(id, 'approve')),
            const SizedBox(width: 8),
            _voteButton('Reject', Colors.redAccent, () => _castVote(id, 'reject')),
            const SizedBox(width: 8),
            _voteButton('Abstain', Colors.white38, () => _castVote(id, 'abstain')),
          ]),
        ] else if (hasVoted) ...[
          const SizedBox(height: 10),
          const Text('✓ You have voted',
              style: TextStyle(color: Colors.white38, fontSize: 12)),
        ],
      ]),
    );
  }

  Widget _voteButton(String label, Color color, VoidCallback onTap) {
    return Expanded(
      child: OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          foregroundColor: color,
          side: BorderSide(color: color.withAlpha(120)),
          padding: const EdgeInsets.symmetric(vertical: 8),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10)),
        ),
        child: Text(label,
            style: TextStyle(
                color: color, fontSize: 12, fontWeight: FontWeight.bold)),
      ),
    );
  }

  // ── Add Vault Bottom Sheet ────────────────────────────────────────────────────

  void _showAddAllocationSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _navy,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => _AddAllocationSheet(
        sovereignId:    widget.sovereignId,
        availableSeeds: widget.seeds - _lockedSeeds,
        onCreated: () { _loadAllocations(); Navigator.pop(context); },
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Vote Tally Bar widget
// ═══════════════════════════════════════════════════════════════════════════════

class _VoteTallyBar extends StatelessWidget {
  final int approve;
  final int reject;
  final int abstain;

  const _VoteTallyBar({
    required this.approve,
    required this.reject,
    required this.abstain,
  });

  @override
  Widget build(BuildContext context) {
    final total = approve + reject + abstain;
    if (total == 0) {
      return Container(
        height: 6,
        decoration: BoxDecoration(
          color: Colors.white12,
          borderRadius: BorderRadius.circular(3),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: SizedBox(
        height: 6,
        child: Row(children: [
          Flexible(
              flex: approve,
              child: Container(color: Colors.green)),
          Flexible(
              flex: reject,
              child: Container(color: Colors.redAccent)),
          Flexible(
              flex: abstain,
              child: Container(color: Colors.white24)),
        ]),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Stage-1 Claim Form — claim key only, sovereign ID read from state
// ═══════════════════════════════════════════════════════════════════════════════

class _ClaimStage1Form extends StatefulWidget {
  final bool loading;
  final Future<void> Function(String claimKey) onSubmit;

  const _ClaimStage1Form({required this.loading, required this.onSubmit});

  @override
  State<_ClaimStage1Form> createState() => _ClaimStage1FormState();
}

class _ClaimStage1FormState extends State<_ClaimStage1Form> {
  final _keyCtrl  = TextEditingController();
  final _formKey  = GlobalKey<FormState>();
  bool  _obscure  = true;

  @override
  void dispose() {
    _keyCtrl.dispose();
    super.dispose();
  }

  static const _cardBg = Color(0xFF0D1F3A);
  static const _gold   = Color(0xFFB8960C);

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      child: Column(children: [
        TextFormField(
          controller: _keyCtrl,
          obscureText: _obscure,
          style: const TextStyle(color: Colors.white, fontSize: 13),
          decoration: InputDecoration(
            hintText: 'Claim key (SOVW-XXXX-XXXX-XXXX)',
            hintStyle: TextStyle(color: Colors.white.withAlpha(51)),
            filled: true,
            fillColor: _cardBg,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: Colors.white.withAlpha(26))),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: Colors.white.withAlpha(26))),
            focusedBorder: const OutlineInputBorder(
              borderRadius: BorderRadius.all(Radius.circular(12)),
              borderSide: BorderSide(color: Color(0xFFB8960C))),
            suffixIcon: IconButton(
              icon: Icon(
                _obscure ? Icons.visibility_off_outlined
                         : Icons.visibility_outlined,
                color: Colors.white38),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
          validator: (v) {
            if (v == null || v.trim().isEmpty) return 'Enter your claim key';
            if (!InheritanceCrypto.validateClaimKeyFormat(v.trim())) {
              return 'Key must be SOVW-XXXX-XXXX-XXXX format';
            }
            return null;
          },
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          height: 48,
          child: ElevatedButton(
            onPressed: widget.loading ? null : () {
              if (!_formKey.currentState!.validate()) return;
              widget.onSubmit(_keyCtrl.text.trim());
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: _gold,
              disabledBackgroundColor: _gold.withAlpha(60),
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            child: widget.loading
                ? const SizedBox(
                    width: 20, height: 20,
                    child: CircularProgressIndicator(
                        color: Colors.black, strokeWidth: 2))
                : const Text('Claim Now',
                    style: TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 15)),
          ),
        ),
      ]),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Stage-2 Claim Form — name search → results → family keyword + statement
// ═══════════════════════════════════════════════════════════════════════════════

class _ClaimStage2Form extends StatefulWidget {
  final bool loading;
  final Future<void> Function(
      String allocId, List<String> familyKeys, String statement) onSubmit;

  const _ClaimStage2Form({required this.loading, required this.onSubmit});

  @override
  State<_ClaimStage2Form> createState() => _ClaimStage2FormState();
}

class _ClaimStage2FormState extends State<_ClaimStage2Form> {
  static const _cardBg = Color(0xFF0D1F3A);
  static const _teal   = Color(0xFF006B5E);

  // Step 1: name search
  final _nameCtrl  = TextEditingController();
  bool  _searching = false;
  List<Map<String, dynamic>> _results = [];
  String _searchError = '';

  // Step 2: selected allocation
  Map<String, dynamic>? _selected;

  // Step 3: family key + statement
  final _fk1Ctrl  = TextEditingController();
  final _fk2Ctrl  = TextEditingController();
  final _fk3Ctrl  = TextEditingController();
  final _stmtCtrl = TextEditingController();
  final _formKey  = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _loadDrafts();
  }

  Future<void> _loadDrafts() async {
    final fk1  = await DraftManager.load(DraftKeys.claimFamilyKeyword);
    final fk2  = await DraftManager.load(DraftKeys.claimFamilyKeyword2);
    final fk3  = await DraftManager.load(DraftKeys.claimFamilyKeyword3);
    final stmt = await DraftManager.load(DraftKeys.claimStatement);
    if (!mounted) return;
    if (fk1.isNotEmpty)  _fk1Ctrl.text  = fk1;
    if (fk2.isNotEmpty)  _fk2Ctrl.text  = fk2;
    if (fk3.isNotEmpty)  _fk3Ctrl.text  = fk3;
    if (stmt.isNotEmpty) _stmtCtrl.text = stmt;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _fk1Ctrl.dispose();
    _fk2Ctrl.dispose();
    _fk3Ctrl.dispose();
    _stmtCtrl.dispose();
    super.dispose();
  }

  Future<void> _doSearch() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;
    setState(() { _searching = true; _searchError = ''; _results = []; _selected = null; });
    try {
      if (!RelayConnector.isConnected) await RelayConnector.connect();
      // Hash the name for privacy — relay stores name_hash not plain name
      final nameHash = InheritanceCrypto.hashFamilyKey(name);
      final list = await RelayConnector.searchUnclaimed(nameHash);
      if (!mounted) return;
      setState(() {
        _results = list;
        _searching = false;
        if (list.isEmpty) _searchError = 'No unclaimed vaults found for that name';
      });
    } catch (e) {
      if (mounted) setState(() { _searching = false; _searchError = e.toString(); });
    }
  }

  String _formatSovSeeds(dynamic seeds) {
    final s = (seeds as num?)?.toInt() ?? 0;
    final sov = s / 1000000;
    return sov >= 1 ? '${sov.toStringAsFixed(2)} SOV' : '$s seeds';
  }

  InputDecoration _dec(String hint) => InputDecoration(
    hintText: hint,
    hintStyle: TextStyle(color: Colors.white.withAlpha(51)),
    filled: true,
    fillColor: _cardBg,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: Colors.white.withAlpha(26))),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: Colors.white.withAlpha(26))),
    focusedBorder: const OutlineInputBorder(
      borderRadius: BorderRadius.all(Radius.circular(12)),
      borderSide: BorderSide(color: _teal)),
  );

  @override
  Widget build(BuildContext context) {
    // ── Step 3: family key entry after allocation selected ─────────────────
    if (_selected != null) {
      final note = _selected!['public_statement'] as String? ?? '';
      final amount = _formatSovSeeds(_selected!['amount_seeds']);
      return Form(
        key: _formKey,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Selected vault card
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _teal.withAlpha(26),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _teal.withAlpha(70)),
            ),
            child: Row(children: [
              const Icon(Icons.lock_open_rounded, color: Color(0xFF006B5E), size: 18),
              const SizedBox(width: 10),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(amount,
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold)),
                  if (note.isNotEmpty)
                    Text(note, style: const TextStyle(
                        color: Colors.white54, fontSize: 12)),
                ],
              )),
              TextButton(
                onPressed: () => setState(() { _selected = null; }),
                style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(44, 28)),
                child: const Text('Change',
                    style: TextStyle(color: Colors.white38, fontSize: 11)),
              ),
            ]),
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _fk1Ctrl,
            obscureText: true,
            style: const TextStyle(color: Colors.white),
            onChanged: (v) =>
                DraftManager.save(DraftKeys.claimFamilyKeyword, v),
            decoration: _dec('Family verification phrase 1'),
            validator: (v) => (v == null || v.trim().isEmpty)
                ? 'Enter at least one family phrase' : null,
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _fk2Ctrl,
            obscureText: true,
            style: const TextStyle(color: Colors.white),
            onChanged: (v) =>
                DraftManager.save(DraftKeys.claimFamilyKeyword2, v),
            decoration: _dec('Family verification phrase 2 (optional)'),
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _fk3Ctrl,
            obscureText: true,
            style: const TextStyle(color: Colors.white),
            onChanged: (v) =>
                DraftManager.save(DraftKeys.claimFamilyKeyword3, v),
            decoration: _dec('Family verification phrase 3 (optional)'),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _stmtCtrl,
            maxLines: 3,
            style: const TextStyle(color: Colors.white, fontSize: 13),
            onChanged: (v) =>
                DraftManager.save(DraftKeys.claimStatement, v),
            decoration: _dec('Your statement to the justice council'),
            validator: (v) => (v == null || v.trim().isEmpty)
                ? 'Enter a statement' : null,
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton(
              onPressed: widget.loading ? null : () {
                if (!_formKey.currentState!.validate()) return;
                // Clear claim drafts — data captured, passing to handler
                DraftManager.clearAll(DraftKeys.claimAll);
                final allocId = _selected!['id'] as String? ?? '';
                widget.onSubmit(
                  allocId,
                  [_fk1Ctrl.text.trim(), _fk2Ctrl.text.trim(),
                   _fk3Ctrl.text.trim()],
                  _stmtCtrl.text.trim(),
                );
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: _teal,
                disabledBackgroundColor: _teal.withAlpha(60),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: widget.loading
                  ? const SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2))
                  : const Text('Request Council Review',
                      style: TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15)),
            ),
          ),
        ]),
      );
    }

    // ── Step 1 + 2: name search + results ──────────────────────────────────
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // Name search row
      Row(children: [
        Expanded(
          child: TextField(
            controller: _nameCtrl,
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: _dec('Beneficiary name to search'),
            onSubmitted: (_) => _doSearch(),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          height: 52,
          child: ElevatedButton(
            onPressed: _searching ? null : _doSearch,
            style: ElevatedButton.styleFrom(
              backgroundColor: _teal,
              disabledBackgroundColor: _teal.withAlpha(60),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(horizontal: 16),
            ),
            child: _searching
                ? const SizedBox(
                    width: 18, height: 18,
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 2))
                : const Icon(Icons.search_rounded, size: 22),
          ),
        ),
      ]),
      if (_searchError.isNotEmpty) ...[
        const SizedBox(height: 10),
        Text(_searchError,
            style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
      ],
      if (_results.isNotEmpty) ...[
        const SizedBox(height: 14),
        const Text('Select a vault to claim:',
            style: TextStyle(color: Colors.white54, fontSize: 12,
                letterSpacing: 0.5)),
        const SizedBox(height: 8),
        ...(_results.map((alloc) {
          final amount = _formatSovSeeds(alloc['amount_seeds']);
          final note   = alloc['public_statement'] as String? ?? '';
          return GestureDetector(
            onTap: () => setState(() => _selected = alloc),
            child: Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: _cardBg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withAlpha(26)),
              ),
              child: Row(children: [
                const Icon(Icons.lock_outline_rounded,
                    color: Colors.white38, size: 18),
                const SizedBox(width: 12),
                Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(amount,
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 13)),
                    if (note.isNotEmpty)
                      Text(note,
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 12)),
                  ],
                )),
                const Icon(Icons.chevron_right_rounded,
                    color: Colors.white24, size: 20),
              ]),
            ),
          );
        })),
      ],
    ]);
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Add Vault Bottom Sheet
// ═══════════════════════════════════════════════════════════════════════════════

class _AddAllocationSheet extends StatefulWidget {
  final String sovereignId;
  final int    availableSeeds;
  final VoidCallback onCreated;

  const _AddAllocationSheet({
    required this.sovereignId,
    required this.availableSeeds,
    required this.onCreated,
  });

  @override
  State<_AddAllocationSheet> createState() => _AddAllocationSheetState();
}

class _AddAllocationSheetState extends State<_AddAllocationSheet> {
  static const _gold   = Color(0xFFB8960C);
  static const _cardBg = Color(0xFF0D1F3A);

  final _formKey      = GlobalKey<FormState>();
  final _nameCtrl     = TextEditingController();
  final _amountCtrl   = TextEditingController();
  final _noteCtrl     = TextEditingController();
  final _stmtCtrl     = TextEditingController();
  final _fk1Ctrl      = TextEditingController();
  final _fk1HintCtrl  = TextEditingController();
  final _fk2Ctrl      = TextEditingController();
  final _fk2HintCtrl  = TextEditingController();
  final _fk3Ctrl      = TextEditingController();
  final _fk3HintCtrl  = TextEditingController();

  int       _releaseYears      = 5;
  DateTime? _customReleaseDate;
  bool      _submitting        = false;
  String    _error             = '';

  @override
  void initState() {
    super.initState();
    _loadDrafts();
    // Family-key controllers are passed into _FamilyKeySection — attach
    // listeners here so we don't have to modify that widget.
    _fk1Ctrl.addListener(
        () => DraftManager.save(DraftKeys.vaultFamilyKey1, _fk1Ctrl.text));
    _fk1HintCtrl.addListener(
        () => DraftManager.save(DraftKeys.vaultFamilyKey1Hint, _fk1HintCtrl.text));
    _fk2Ctrl.addListener(
        () => DraftManager.save(DraftKeys.vaultFamilyKey2, _fk2Ctrl.text));
    _fk2HintCtrl.addListener(
        () => DraftManager.save(DraftKeys.vaultFamilyKey2Hint, _fk2HintCtrl.text));
    _fk3Ctrl.addListener(
        () => DraftManager.save(DraftKeys.vaultFamilyKey3, _fk3Ctrl.text));
    _fk3HintCtrl.addListener(
        () => DraftManager.save(DraftKeys.vaultFamilyKey3Hint, _fk3HintCtrl.text));
  }

  Future<void> _loadDrafts() async {
    final name = await DraftManager.load(DraftKeys.vaultBeneficiaryName);
    final amt  = await DraftManager.load(DraftKeys.vaultAmount);
    final stmt = await DraftManager.load(DraftKeys.vaultPublicStatement);
    final note = await DraftManager.load(DraftKeys.vaultPersonalNote);
    final fk1  = await DraftManager.load(DraftKeys.vaultFamilyKey1);
    final fk1h = await DraftManager.load(DraftKeys.vaultFamilyKey1Hint);
    final fk2  = await DraftManager.load(DraftKeys.vaultFamilyKey2);
    final fk2h = await DraftManager.load(DraftKeys.vaultFamilyKey2Hint);
    final fk3  = await DraftManager.load(DraftKeys.vaultFamilyKey3);
    final fk3h = await DraftManager.load(DraftKeys.vaultFamilyKey3Hint);
    if (!mounted) return;
    if (name.isNotEmpty) _nameCtrl.text     = name;
    if (amt.isNotEmpty)  _amountCtrl.text   = amt;
    if (stmt.isNotEmpty) _stmtCtrl.text     = stmt;
    if (note.isNotEmpty) _noteCtrl.text     = note;
    if (fk1.isNotEmpty)  _fk1Ctrl.text      = fk1;
    if (fk1h.isNotEmpty) _fk1HintCtrl.text  = fk1h;
    if (fk2.isNotEmpty)  _fk2Ctrl.text      = fk2;
    if (fk2h.isNotEmpty) _fk2HintCtrl.text  = fk2h;
    if (fk3.isNotEmpty)  _fk3Ctrl.text      = fk3;
    if (fk3h.isNotEmpty) _fk3HintCtrl.text  = fk3h;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();    _amountCtrl.dispose();
    _noteCtrl.dispose();    _stmtCtrl.dispose();
    _fk1Ctrl.dispose();     _fk1HintCtrl.dispose();
    _fk2Ctrl.dispose();     _fk2HintCtrl.dispose();
    _fk3Ctrl.dispose();     _fk3HintCtrl.dispose();
    super.dispose();
  }

  // ── Custom date picker ────────────────────────────────────────────────────────

  Future<void> _pickCustomDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now().add(const Duration(days: 365)),
      firstDate: DateTime.now().add(const Duration(days: 1)),
      lastDate: DateTime(2150),
      builder: (context, child) => Theme(
        data: ThemeData.dark().copyWith(
          colorScheme: const ColorScheme.dark(
            primary: Color(0xFFB8960C),
            onPrimary: Colors.black,
            surface: Color(0xFF0D1F3A),
            onSurface: Colors.white,
          ),
        ),
        child: child!,
      ),
    );
    if (picked != null && mounted) {
      setState(() {
        _customReleaseDate = picked;
        _releaseYears = 0;
      });
    }
  }

  String _monthName(int m) {
    const months = [
      'Jan','Feb','Mar','Apr','May','Jun',
      'Jul','Aug','Sep','Oct','Nov','Dec'
    ];
    return months[m - 1];
  }

  // ── Submit ────────────────────────────────────────────────────────────────────

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    final amountSovStr = _amountCtrl.text.trim();
    final amountSov    = double.tryParse(amountSovStr) ?? 0;
    final amountSeeds  = (amountSov * 1000000).round();

    if (amountSeeds <= 0) {
      setState(() => _error = 'Enter a valid amount');
      return;
    }
    if (amountSeeds > widget.availableSeeds) {
      setState(() => _error =
          'Amount exceeds available balance (${(widget.availableSeeds / 1000000).toStringAsFixed(6)} SOV)');
      return;
    }

    // Validate release date
    if (_customReleaseDate == null && _releaseYears == 0) {
      setState(() => _error = 'Choose a release date');
      return;
    }

    setState(() { _submitting = true; _error = ''; });

    try {
      // Generate claim key only now — after validation passes
      final claimKey         = InheritanceCrypto.generateClaimKey();
      final beneficiaryName  = _nameCtrl.text.trim();
      final personalNote     = _noteCtrl.text.trim();

      // Client-side encryption — relay never sees plaintext
      final nameHash         = InheritanceCrypto.hashBeneficiaryName(beneficiaryName);
      final nameEncrypted    = InheritanceCrypto.encryptBeneficiaryName(
          beneficiaryName, claimKey);
      final claimKeyHash     = InheritanceCrypto.hashClaimKey(claimKey);
      final noteEncrypted    = personalNote.isNotEmpty
          ? InheritanceCrypto.encryptPersonalNote(personalNote, claimKey)
          : null;

      // Release date: custom date or preset years
      final int releaseDate;
      if (_customReleaseDate != null) {
        releaseDate = _customReleaseDate!.millisecondsSinceEpoch ~/ 1000;
      } else {
        releaseDate = InheritanceCrypto.releaseYearsToTimestamp(_releaseYears);
      }

      // Family keys (optional)
      final fk1 = _fk1Ctrl.text.trim();
      final fk2 = _fk2Ctrl.text.trim();
      final fk3 = _fk3Ctrl.text.trim();

      final payload = <String, dynamic>{
        'sovereign_id':              widget.sovereignId,
        'beneficiary_name_hash':     nameHash,
        'beneficiary_name_encrypted': nameEncrypted,
        'amount_seeds':              amountSeeds,
        'release_date':              releaseDate,
        'claim_key_hash':            claimKeyHash,
        'public_statement':
            _stmtCtrl.text.trim().isNotEmpty ? _stmtCtrl.text.trim() : null,
        'publish_after_years':       _releaseYears > 0 ? _releaseYears : 10,
        if (personalNote.isNotEmpty) 'personal_note_encrypted': noteEncrypted,
        if (fk1.isNotEmpty) 'family_key_1_hash':
            InheritanceCrypto.hashFamilyKey(fk1),
        if (fk1.isNotEmpty && _fk1HintCtrl.text.trim().isNotEmpty)
          'family_key_1_hint': _fk1HintCtrl.text.trim(),
        if (fk2.isNotEmpty) 'family_key_2_hash':
            InheritanceCrypto.hashFamilyKey(fk2),
        if (fk2.isNotEmpty && _fk2HintCtrl.text.trim().isNotEmpty)
          'family_key_2_hint': _fk2HintCtrl.text.trim(),
        if (fk3.isNotEmpty) 'family_key_3_hash':
            InheritanceCrypto.hashFamilyKey(fk3),
        if (fk3.isNotEmpty && _fk3HintCtrl.text.trim().isNotEmpty)
          'family_key_3_hint': _fk3HintCtrl.text.trim(),
      };

      if (!RelayConnector.isConnected) await RelayConnector.connect();
      final resp = await RelayConnector.submitAllocationCreate(payload);

      if (!mounted) return;
      if (resp['success'] == true) {
        // Show key reveal before closing
        await showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => _KeyRevealDialog(
            claimKey:       claimKey,
            beneficiaryName: beneficiaryName,
          ),
        );
        // Clear all vault drafts — allocation created successfully
        await DraftManager.clearAll(DraftKeys.vaultAll);
        widget.onCreated();
      } else {
        setState(() {
          _error      = resp['error'] as String? ?? 'Failed to create vault';
          _submitting = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _submitting = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.viewInsetsOf(context);
    final maxHeight  = MediaQuery.sizeOf(context).height * 0.92;
    return Container(
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: const BoxDecoration(
        color: Color(0xFF0A1628),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      child: Column(children: [
        // Drag handle
        const SizedBox(height: 12),
        Container(
          width: 40, height: 4,
          decoration: BoxDecoration(
            color: Colors.white24,
            borderRadius: BorderRadius.circular(2))),
        const SizedBox(height: 16),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 24),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('New Vault',
                style: TextStyle(
                    color: Color(0xFFB8960C),
                    fontSize: 18,
                    fontWeight: FontWeight.bold)),
          ),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: SingleChildScrollView(
            // viewInsets.bottom pushes content above the soft keyboard
            padding: EdgeInsets.fromLTRB(24, 0, 24, 40 + viewInsets.bottom),
            child: Form(
              key: _formKey,
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [

                _label('BENEFICIARY NAME'),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _nameCtrl,
                  style: const TextStyle(color: Colors.white),
                  decoration: _dec('Full name of beneficiary'),
                  onChanged: (v) =>
                      DraftManager.save(DraftKeys.vaultBeneficiaryName, v),
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? 'Enter beneficiary name' : null,
                ),
                const SizedBox(height: 16),

                _label('AMOUNT (SOV)'),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _amountCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  style: const TextStyle(color: Colors.white),
                  onChanged: (v) =>
                      DraftManager.save(DraftKeys.vaultAmount, v),
                  decoration: _dec(
                      'Available: ${(widget.availableSeeds / 1000000).toStringAsFixed(6)} SOV'),
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) return 'Enter amount';
                    final d = double.tryParse(v);
                    if (d == null || d <= 0) return 'Invalid amount';
                    return null;
                  },
                ),
                const SizedBox(height: 16),

                _label('RELEASE DATE'),
                const SizedBox(height: 10),

                // ── Custom date selected — show chip with X ─────────────────
                if (_customReleaseDate != null) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: _gold.withAlpha(28),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: _gold),
                    ),
                    child: Row(children: [
                      const Icon(Icons.calendar_today_outlined,
                          color: Color(0xFFB8960C), size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Release: ${_customReleaseDate!.day} '
                          '${_monthName(_customReleaseDate!.month)} '
                          '${_customReleaseDate!.year}',
                          style: const TextStyle(
                              color: Color(0xFFB8960C),
                              fontWeight: FontWeight.bold,
                              fontSize: 14),
                        ),
                      ),
                      GestureDetector(
                        onTap: () => setState(() => _customReleaseDate = null),
                        child: const Icon(Icons.close_rounded,
                            color: Colors.white38, size: 20),
                      ),
                    ]),
                  ),
                ] else ...[
                  // ── Preset buttons + Custom ─────────────────────────────────
                  Row(
                    children: [
                      ...[1, 3, 5, 10, 20].map((y) {
                        final sel = _releaseYears == y;
                        return Expanded(
                          child: Padding(
                            padding: const EdgeInsets.only(right: 5),
                            child: GestureDetector(
                              onTap: () => setState(() => _releaseYears = y),
                              child: Container(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 10),
                                decoration: BoxDecoration(
                                  color: sel
                                      ? _gold.withAlpha(28)
                                      : _cardBg,
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                      color: sel
                                          ? _gold
                                          : Colors.white.withAlpha(26)),
                                ),
                                child: Column(children: [
                                  Text('$y',
                                      style: TextStyle(
                                          color: sel ? _gold : Colors.white,
                                          fontSize: 15,
                                          fontWeight: FontWeight.bold)),
                                  Text(y == 1 ? 'yr' : 'yrs',
                                      style: TextStyle(
                                          color: sel
                                              ? _gold.withAlpha(179)
                                              : Colors.white38,
                                          fontSize: 10)),
                                ]),
                              ),
                            ),
                          ),
                        );
                      }),
                      // Custom date button
                      Expanded(
                        child: GestureDetector(
                          onTap: _pickCustomDate,
                          child: Container(
                            padding:
                                const EdgeInsets.symmetric(vertical: 10),
                            decoration: BoxDecoration(
                              color: _cardBg,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                  color: Colors.white.withAlpha(26)),
                            ),
                            child: const Column(children: [
                              Icon(Icons.calendar_today_outlined,
                                  color: Colors.white38, size: 14),
                              SizedBox(height: 2),
                              Text('Custom',
                                  style: TextStyle(
                                      color: Colors.white38,
                                      fontSize: 9)),
                            ]),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 16),

                _label('PUBLIC STATEMENT (optional)'),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _stmtCtrl,
                  maxLines: 2,
                  style: const TextStyle(color: Colors.white),
                  onChanged: (v) =>
                      DraftManager.save(DraftKeys.vaultPublicStatement, v),
                  decoration: _dec(
                      'Visible on network after release (keep vague)'),
                ),
                const SizedBox(height: 16),

                _label('PERSONAL NOTE (optional, encrypted)'),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _noteCtrl,
                  maxLines: 2,
                  style: const TextStyle(color: Colors.white),
                  onChanged: (v) =>
                      DraftManager.save(DraftKeys.vaultPersonalNote, v),
                  decoration: _dec(
                      'Encrypted with claim key — only beneficiary can read'),
                ),
                const SizedBox(height: 20),

                // Family keys — collapsible
                _FamilyKeySection(
                  fk1Ctrl: _fk1Ctrl, fk1HintCtrl: _fk1HintCtrl,
                  fk2Ctrl: _fk2Ctrl, fk2HintCtrl: _fk2HintCtrl,
                  fk3Ctrl: _fk3Ctrl, fk3HintCtrl: _fk3HintCtrl,
                ),
                const SizedBox(height: 24),

                if (_error.isNotEmpty) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red.withAlpha(26),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: Colors.red.withAlpha(70)),
                    ),
                    child: Text(_error,
                        style: const TextStyle(
                            color: Colors.redAccent, fontSize: 13)),
                  ),
                  const SizedBox(height: 16),
                ],

                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton(
                    onPressed: _submitting ? null : _submit,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _gold,
                      disabledBackgroundColor: _gold.withAlpha(60),
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                    ),
                    child: _submitting
                        ? const SizedBox(
                            width: 22, height: 22,
                            child: CircularProgressIndicator(
                                color: Colors.black, strokeWidth: 2.5))
                        : const Text('Create Vault',
                            style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold)),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _label(String text) => Text(text,
      style: const TextStyle(
          color: Colors.white38, fontSize: 11, letterSpacing: 1.5));

  InputDecoration _dec(String hint) => InputDecoration(
    hintText: hint,
    hintStyle: TextStyle(color: Colors.white.withAlpha(51)),
    filled: true,
    fillColor: _cardBg,
    border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: Colors.white.withAlpha(26))),
    enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: Colors.white.withAlpha(26))),
    focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFB8960C))),
  );
}

// ── Family keys collapsible section ──────────────────────────────────────────

class _FamilyKeySection extends StatefulWidget {
  final TextEditingController fk1Ctrl;
  final TextEditingController fk1HintCtrl;
  final TextEditingController fk2Ctrl;
  final TextEditingController fk2HintCtrl;
  final TextEditingController fk3Ctrl;
  final TextEditingController fk3HintCtrl;

  const _FamilyKeySection({
    required this.fk1Ctrl, required this.fk1HintCtrl,
    required this.fk2Ctrl, required this.fk2HintCtrl,
    required this.fk3Ctrl, required this.fk3HintCtrl,
  });

  @override
  State<_FamilyKeySection> createState() => _FamilyKeySectionState();
}

class _FamilyKeySectionState extends State<_FamilyKeySection> {
  bool _expanded = false;

  static const _cardBg = Color(0xFF0D1F3A);
  static const _teal   = Color(0xFF006B5E);

  InputDecoration _dec(String hint) => InputDecoration(
    hintText: hint,
    hintStyle: TextStyle(color: Colors.white.withAlpha(51)),
    filled: true,
    fillColor: _cardBg,
    isDense: true,
    contentPadding:
        const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: Colors.white.withAlpha(26))),
    enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: Colors.white.withAlpha(26))),
    focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0xFF006B5E))),
  );

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      GestureDetector(
        onTap: () => setState(() => _expanded = !_expanded),
        child: Row(children: [
          const Text('FAMILY VERIFICATION KEYS (optional)',
              style: TextStyle(
                  color: Colors.white38, fontSize: 11, letterSpacing: 1.4)),
          const Spacer(),
          Icon(
            _expanded ? Icons.expand_less : Icons.expand_more,
            color: Colors.white38, size: 18),
        ]),
      ),
      if (_expanded) ...[
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: _teal.withAlpha(15),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _teal.withAlpha(55)),
          ),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
            const Text(
                'Fallback phrases known only to family. Used for Stage-2 justice '
                'council claims. Hints are visible to council members.',
                style: TextStyle(
                    color: Colors.white38, fontSize: 11, height: 1.4)),
            const SizedBox(height: 14),
            _fkRow('Key phrase 1', 'Hint 1',
                widget.fk1Ctrl, widget.fk1HintCtrl),
            const SizedBox(height: 10),
            _fkRow('Key phrase 2', 'Hint 2',
                widget.fk2Ctrl, widget.fk2HintCtrl),
            const SizedBox(height: 10),
            _fkRow('Key phrase 3', 'Hint 3',
                widget.fk3Ctrl, widget.fk3HintCtrl),
          ]),
        ),
      ],
    ]);
  }

  Widget _fkRow(String keyHint, String hintHint,
      TextEditingController keyCtrl, TextEditingController hintCtrl) {
    return Row(children: [
      Expanded(
        flex: 3,
        child: TextFormField(
          controller: keyCtrl,
          obscureText: true,
          style: const TextStyle(color: Colors.white, fontSize: 12),
          decoration: _dec(keyHint),
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        flex: 2,
        child: TextFormField(
          controller: hintCtrl,
          style: const TextStyle(color: Colors.white, fontSize: 12),
          decoration: _dec(hintHint),
        ),
      ),
    ]);
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Key Reveal Dialog — shown once after vault creation
// ═══════════════════════════════════════════════════════════════════════════════

class _KeyRevealDialog extends StatefulWidget {
  final String claimKey;
  final String beneficiaryName;

  const _KeyRevealDialog({
    required this.claimKey,
    required this.beneficiaryName,
  });

  @override
  State<_KeyRevealDialog> createState() => _KeyRevealDialogState();
}

class _KeyRevealDialogState extends State<_KeyRevealDialog> {
  bool _confirmed = false;

  static const _gold  = Color(0xFFB8960C);
  static const _navy  = Color(0xFF0A1628);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: _navy,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: const Text('⚠ Save the Claim Key',
          style: TextStyle(color: Colors.white, fontSize: 16)),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text(
            'This is the ONLY time the claim key is shown. '
            'Write it down and give it to your beneficiary offline.',
            style: TextStyle(
                color: Colors.white54, fontSize: 13, height: 1.5)),
        const SizedBox(height: 16),
        // Key display
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: _gold.withAlpha(18),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _gold.withAlpha(80)),
          ),
          child: Column(children: [
            Text(
              widget.claimKey,
              style: const TextStyle(
                  color: Colors.white,
                  fontFamily: 'monospace',
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 2),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            Text('For: ${widget.beneficiaryName}',
                style: const TextStyle(
                    color: Colors.white38, fontSize: 12)),
          ]),
        ),
        const SizedBox(height: 14),
        Row(children: [
          IconButton(
            icon: const Icon(Icons.copy_rounded, color: Color(0xFFB8960C)),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: widget.claimKey));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                    content: Text('Claim key copied'),
                    duration: Duration(seconds: 2)));
            },
          ),
          const Text('Copy to clipboard',
              style: TextStyle(color: Color(0xFFB8960C), fontSize: 13)),
        ]),
        const SizedBox(height: 12),
        CheckboxListTile(
          value: _confirmed,
          onChanged: (v) => setState(() => _confirmed = v ?? false),
          activeColor: _gold,
          checkColor: Colors.black,
          title: const Text(
              'I have saved this key safely',
              style: TextStyle(color: Colors.white, fontSize: 13)),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
        ),
      ]),
      actions: [
        ElevatedButton(
          onPressed: _confirmed ? () => Navigator.pop(context) : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: _gold,
            disabledBackgroundColor: _gold.withAlpha(60),
            foregroundColor: Colors.black,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
          ),
          child: const Text('I\'ve Saved It',
              style: TextStyle(fontWeight: FontWeight.bold)),
        ),
      ],
    );
  }
}
