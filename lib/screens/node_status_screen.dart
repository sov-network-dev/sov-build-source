import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io' show exit;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../sov_node_sdk/relay_connector.dart';
import '../sov_node_sdk/node_discovery.dart';
import '../sov_node_sdk/node_controller.dart';
import '../sov_node_sdk/update_service.dart';

/// ═══════════════════════════════════════════════════════════════════════════
/// NodeStatusScreen — SOV Node connection status
///
/// Shows:
///   • Which node the citizen is currently connected to
///   • Node ID, nickname, IP address
///   • Uptime, peer count, connected citizens
///   • Operator proof score (if the connected node is registered)
///   • Known node pool from NodeDiscovery
///   • "Run a Node" operator signup prompt
///
/// Accessible from home_screen bottom "SOV Network" chip (replacing old relay
/// info). Tapping a node in the pool shows its stats and optionally reconnects.
/// ═══════════════════════════════════════════════════════════════════════════

class NodeStatusScreen extends StatefulWidget {
  const NodeStatusScreen({super.key});

  @override
  State<NodeStatusScreen> createState() => _NodeStatusScreenState();
}

class _NodeStatusScreenState extends State<NodeStatusScreen> {
  static const _navy = Color(0xFF0A1628);
  static const _gold = Color(0xFFF5C518);
  static const _teal = Color(0xFF00C4B4);

  Map<String, dynamic>? _stats;
  bool   _loading        = true;
  String _errorMsg       = '';
  Timer? _refreshTimer;
  int?   _lastUpdated;

  // Full-node (desktop) controls
  ReachMode _reach = ReachMode.auto;
  final TextEditingController _staticHostCtrl = TextEditingController();
  bool _autostart = NodeController.instance.isAutostartEnabled;
  bool _installingTs = false;                 // Tailscale install in progress
  bool _tsNeedsLogin = false;                 // installed but not signed in
  bool _tsSigningIn  = false;                 // browser sign-in in progress
  String _lastTsUrlOpened = '';               // de-dupe auto-open of the login URL

  Future<void> _installTailscale() async {
    setState(() => _installingTs = true);
    final nc = NodeController.instance;
    try {
      await nc.installTailscale();
      // installed — now check whether they still need to sign in
      final loggedIn = await nc.isTailscaleLoggedIn();
      if (mounted) setState(() => _tsNeedsLogin = !loggedIn);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _installingTs = false);
    }
  }

  Future<void> _tailscaleSignIn() async {
    setState(() => _tsSigningIn = true);
    final nc = NodeController.instance;
    try {
      await nc.tailscaleUp();       // starts `up`, surfaces the login URL, polls to done
      if (mounted) setState(() { _tsNeedsLogin = false; _lastTsUrlOpened = ''; });
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Tailscale connected — you can start the node now.')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _tsSigningIn = false);
    }
  }

  // Auto-update (desktop self-update)
  bool   _checkingUpdate  = false;
  String _updateMsg       = '';
  double _downloadProgress = 0.0;
  bool   _downloading     = false;
  UpdateArtifact? _pendingArtifact;

  @override
  void initState() {
    super.initState();
    _loadStats();
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) => _loadStats());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadStats() async {
    if (!mounted) return;
    // Only clear the error while we still have nothing to show — on a refresh
    // that already has data we keep the last-known stats visible.
    setState(() { _loading = true; if (_stats == null) _errorMsg = ''; });
    try {
      // getNodeStats() returns null (it does NOT throw) when the socket is
      // momentarily not ready or the 10 s reply window is missed. On desktop
      // there is more reconnect churn (primary + up to 3 pool sockets + zombie
      // detection), so a single tick can miss. Retry a few times before giving
      // up so a transient miss never renders every card as a blank "—".
      Map<String, dynamic>? result;
      for (var attempt = 0; attempt < 3; attempt++) {
        result = await RelayConnector.getNodeStats();
        if (result != null && result.isNotEmpty) break;
        if (!mounted) return;
        await Future.delayed(const Duration(milliseconds: 1200));
      }
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (result != null && result.isNotEmpty) {
          _stats       = result;
          _errorMsg    = '';
          _lastUpdated = DateTime.now().millisecondsSinceEpoch;
        } else if (_stats == null) {
          // Never reached the node this session — show a clear connecting /
          // retry state instead of a silent grid full of dashes.
          //
          // A refused device is NOT "connecting". The nodes are healthy and
          // reachable; they have declined this device's key. Saying
          // "connecting…" there would leave the citizen waiting forever for
          // something that is never going to happen, so the real reason and the
          // actual remedy are shown instead.
          if (RelayConnector.hasCredentialError) {
            _errorMsg = 'This device is not holding the key enrolled for your '
                'Sovereign ID, so the network will not accept it. Restore your '
                'wallet from your 12-word seed phrase to re-derive the correct '
                'key.';
          } else {
            _errorMsg = RelayConnector.isConnected
                ? 'Loading network statistics…'
                : 'Connecting to a node…';
          }
        }
        // else: keep the last-known stats on screen (a refresh miss shouldn't
        // wipe good data back to blanks).
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading  = false;
        if (_stats == null) _errorMsg = 'Could not reach node';
      });
    }
  }

  // ── Formatting helpers ───────────────────────────────────────────────────

  String _fmtUptime(int? uptimeSec) {
    if (uptimeSec == null) return '—';
    final h = uptimeSec ~/ 3600;
    final m = (uptimeSec % 3600) ~/ 60;
    if (h > 0) return '${h}h ${m}m';
    return '${m}m';
  }

  String _fmtSeeds(dynamic seeds) {
    if (seeds == null) return '—';
    // Values arrive in SEEDS; SOV = seeds / SEEDS_PER_SOV (1,000,000). This
    // conversion was previously missing here, inflating every SOV figure by 1e6×
    // (e.g. 4.8e9 seeds = 4,800 SOV was shown as "4.8B SOV"). Matches the
    // seeds→SOV convention used app-wide (economy/exchange/home/governance).
    final sov = (seeds as num).toDouble() / 1000000.0;
    if (sov >= 1000000000) return '${(sov / 1000000000).toStringAsFixed(2)}B SOV';
    if (sov >= 1000000)    return '${(sov / 1000000).toStringAsFixed(2)}M SOV';
    if (sov >= 1000)       return '${(sov / 1000).toStringAsFixed(2)}K SOV';
    if (sov >= 1)          return '${sov.toStringAsFixed(2)} SOV';
    if (sov > 0)           return '${sov.toStringAsFixed(4)} SOV';
    return '0 SOV';
  }

  String _fmtCount(dynamic n) {
    if (n == null) return '—';
    final v = (n as num).toInt();
    if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
    if (v >= 1000)    return '${(v / 1000).toStringAsFixed(1)}K';
    return '$v';
  }

  String _timeAgo(int? tsMs) {
    if (tsMs == null) return '';
    final sec = (DateTime.now().millisecondsSinceEpoch - tsMs) ~/ 1000;
    if (sec < 5) return 'just now';
    if (sec < 60) return '${sec}s ago';
    return '${sec ~/ 60}m ago';
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Always derive the display name from the relay-pool relay ID so this screen
    // shows the SAME name as the Relay Pool screen for the connected node.
    // _stats['node_id'] is the peer-mesh internal ID which hashes to a different
    // name — do not use it for display.
    final nodeId       = RelayConnector.currentNodeId;
    final nodeNickname = RelayConnector.currentRelayNickname;
    final nodeAddress  = RelayConnector.currentNodeAddress;
    final isConnected  = RelayConnector.isConnected;

    return Scaffold(
      key: const ValueKey('nodeStatusScaffold'),
      backgroundColor: _navy,
      appBar: AppBar(
        backgroundColor: _navy,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          'Node Status',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white70),
            tooltip: 'Refresh',
            onPressed: _loadStats,
          ),
        ],
      ),
      body: _loading && _stats == null
          ? const Center(child: CircularProgressIndicator(color: Color(0xFFF5C518)))
          : _errorMsg.isNotEmpty && _stats == null
              ? _buildError()
              : _buildBody(nodeId, nodeNickname, nodeAddress, isConnected),
    );
  }

  Widget _buildError() => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.cloud_off, color: Colors.white38, size: 48),
        const SizedBox(height: 12),
        Text(_errorMsg, style: const TextStyle(color: Colors.white54)),
        const SizedBox(height: 16),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFF5C518), foregroundColor: Colors.black),
          onPressed: _loadStats,
          child: const Text('Retry'),
        ),
      ],
    ),
  );

  Widget _buildBody(String nodeId, String nodeNickname, String nodeAddress, bool isConnected) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildConnectionCard(nodeId, nodeNickname, nodeAddress, isConnected),
          const SizedBox(height: 16),
          _buildStatsGrid(),
          const SizedBox(height: 16),
          if ((_stats?['is_registered'] as bool?) == true)
            _buildOperatorCard(),
          const SizedBox(height: 16),
          _buildNodePool(),
          const SizedBox(height: 16),
          _buildRunANodeCard(),
          // Cross-platform: SOV ships by sideload/direct download (no app store),
          // so EVERY platform needs the in-app update check. Verify+download work
          // everywhere; on desktop apply launches the installer, on mobile it saves
          // the verified file + instructs the user to open it (Android installer).
          const SizedBox(height: 16),
          _buildUpdateCard(),
          const SizedBox(height: 8),
          if (_lastUpdated != null)
            Center(
              child: Text(
                'Updated ${_timeAgo(_lastUpdated)}',
                style: const TextStyle(color: Colors.white30, fontSize: 11),
              ),
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  // ── Connected node card ──────────────────────────────────────────────────

  Widget _buildConnectionCard(
    String nodeId, String nodeNickname, String nodeAddress, bool isConnected,
  ) {
    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF1A2744), Color(0xFF0F1E3A)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isConnected ? _teal.withValues(alpha: 0.4) : Colors.white12,
        ),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: isConnected ? _teal : Colors.red.shade400,
                  shape: BoxShape.circle,
                  boxShadow: isConnected ? [BoxShadow(color: _teal.withValues(alpha: 0.5), blurRadius: 6)] : [],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                isConnected ? 'Connected' : 'Offline',
                style: TextStyle(
                  color: isConnected ? _teal : Colors.red.shade400,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              _chip(
                RelayConnector.connectionType.toUpperCase(),
                color: Colors.white24,
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            nodeNickname,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 6),
          if (nodeId.isNotEmpty) ...[
            GestureDetector(
              onTap: () {
                Clipboard.setData(ClipboardData(text: nodeId));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Node ID copied'), duration: Duration(seconds: 2)),
                );
              },
              child: Row(
                children: [
                  Text(
                    '${nodeId.substring(0, nodeId.length > 20 ? 20 : nodeId.length)}…',
                    style: const TextStyle(color: Colors.white54, fontSize: 12, fontFamily: 'monospace'),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.copy, color: Colors.white30, size: 13),
                ],
              ),
            ),
            const SizedBox(height: 4),
          ],
        ],
      ),
    );
  }

  // ── Stats grid ───────────────────────────────────────────────────────────

  Widget _buildStatsGrid() {
    final enrolled   = _stats?['enrolled_citizens'];
    final connected  = _stats?['connected_citizens'] ?? _stats?['active_citizens'];
    final peers      = _stats?['peer_count'];
    final activeRel  = _stats?['active_relays'];
    final uptime     = _stats?['uptime_sec'];
    final totalSOV   = _stats?['total_sov_seeds'];
    final txCount    = _stats?['transfers_24h'];
    final txVolume   = _stats?['volume_seeds_24h'];
    final openPolls  = _stats?['open_polls'];
    final openCases  = _stats?['open_disputes'];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Network Statistics',
          style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 10),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 1.9,
          children: [
            _statCard('Citizens', _fmtCount(enrolled), Icons.people_outline),
            _statCard('Connected Now', _fmtCount(connected), Icons.wifi),
            _statCard('Peer Nodes', _fmtCount(peers ?? (activeRel != null ? (activeRel as int) - 1 : null)), Icons.hub_outlined),
            _statCard('Node Uptime', _fmtUptime(uptime as int?), Icons.timer_outlined),
            _statCard('SOV in Circulation', _fmtSeeds(totalSOV), Icons.monetization_on_outlined),
            _statCard('Transfers (24h)', _fmtCount(txCount), Icons.swap_horiz),
            _statCard('Volume (24h)', _fmtSeeds(txVolume), Icons.trending_up),
            _statCard('Open Polls', _fmtCount(openPolls), Icons.how_to_vote_outlined),
            _statCard('Open Cases', _fmtCount(openCases), Icons.gavel_outlined),
          ],
        ),
      ],
    );
  }

  Widget _statCard(String label, String value, IconData icon) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1A2744),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: _gold, size: 16),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(color: Colors.white54, fontSize: 11),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  // ── Operator card (shown when node is registered) ───────────────────────

  Widget _buildOperatorCard() {
    final score      = (_stats?['proof_score']      as num?)?.toDouble() ?? 0.0;
    final operatorId = _stats?['operator_id']       as String? ?? '—';
    // Live nodes in the network right now (verified peers + self) — matches the
    // "Known Nodes" list and the Peer Nodes stat, so the three no longer contradict.
    final liveNodes  = _stats?['live_nodes']        as int? ??
                       _stats?['network_nodes']     as int? ??
                       _stats?['registered_nodes']  as int? ?? 0;
    // Operators who have ever registered (accounting metric — NOT a live node count).
    final operatorsReg = _stats?['operators_registered'] as int?;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1A3318),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.green.shade800),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.verified, color: Colors.greenAccent, size: 18),
              const SizedBox(width: 8),
              const Text(
                'Operator Node',
                style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              _chip('REGISTERED', color: Colors.green.shade900, textColor: Colors.greenAccent),
            ],
          ),
          const SizedBox(height: 12),
          _infoRow('Operator ID', operatorId.length > 20
              ? '${operatorId.substring(0, 20)}…' : operatorId),
          _infoRow('Proof Score', score.toStringAsFixed(2)),
          _infoRow('Live nodes', '$liveNodes serving now'),
          if (operatorsReg != null)
            _infoRow('Operators', '$operatorsReg registered'),
        ],
      ),
    );
  }

  // ── Known node pool ──────────────────────────────────────────────────────

  Widget _buildNodePool() {
    final nodes = NodeDiscovery.all;
    if (nodes.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              'Known Nodes',
              style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            Text(
              '${nodes.length} nodes',
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ...nodes.take(8).map((node) => _buildNodeRow(node)),
        if (nodes.length > 8)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '+ ${nodes.length - 8} more nodes',
              style: const TextStyle(color: Colors.white30, fontSize: 11),
            ),
          ),
      ],
    );
  }

  Widget _buildNodeRow(SovNodeEntry node) {
    final isActive  = node.address == RelayConnector.currentNodeAddress;
    // Use canonical relay_id (from relay_pool.json) for nickname so this screen
    // always shows the same name as the Relay Pool screen and Network Dashboard.
    final canonicalId = RelayConnector.canonicalRelayIdForIp(node.ip);
    final effectiveId = canonicalId.isNotEmpty
        ? canonicalId
        : (node.nodeId.isNotEmpty ? node.nodeId : node.ip);
    final nickname  = node.nickname.isNotEmpty
        ? node.nickname
        : RelayConnector.getNickname(effectiveId);

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: isActive ? const Color(0xFF0F2A44) : const Color(0xFF131D30),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isActive ? _teal.withValues(alpha: 0.4) : Colors.white10,
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: isActive ? _teal : (node.failCount > 2 ? Colors.red.shade400 : Colors.white24),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  nickname,
                  style: TextStyle(
                    color: isActive ? Colors.white : Colors.white70,
                    fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          if (isActive)
            _chip('CONNECTED', color: _teal.withValues(alpha: 0.15), textColor: _teal)
          else if (node.failCount > 2)
            _chip('FAILING', color: Colors.red.shade900, textColor: Colors.red.shade300),
        ],
      ),
    );
  }

  // ── "Run a Node" CTA ────────────────────────────────────────────────────

  Future<void> _toggleFullNode(bool on) async {
    final nc = NodeController.instance;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (on) {
        final sovId = prefs.getString('sovereign_id') ?? '';
        // Remember the operator's choice so the node auto-starts in this mode on
        // the next launch (intelligent auto-start).
        await prefs.setBool('node_auto_run', true);
        await prefs.setInt('node_reach_mode', _reach.index);
        await prefs.setString('node_static_host', _staticHostCtrl.text.trim());
        await nc.start(
          sovereignId: sovId,
          dataDir: await nc.resolveDataDir(),
          reach: _reach,
          staticHostValue: _staticHostCtrl.text.trim(),
        );
      } else {
        // An explicit stop turns OFF auto-run — the operator chose not to serve.
        await prefs.setBool('node_auto_run', false);
        await nc.stop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Node: $e')));
      }
    }
  }

  Future<void> _toggleAutostart(bool on) async {
    final nc = NodeController.instance;
    try {
      if (on) {
        await nc.enableAutostart();
      } else {
        await nc.disableAutostart();
      }
      if (mounted) setState(() => _autostart = nc.isAutostartEnabled);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Auto-start: $e')));
    }
  }

  String _reachLabel(ReachMode m) => switch (m) {
        ReachMode.auto => 'Automatic (router / circuit-relay)',
        ReachMode.tailscale => 'Tailscale Funnel (free, no port-forward)',
        ReachMode.staticHost => 'Static IP / port-forward',
      };

  // ── Auto-update (desktop) ──────────────────────────────────────────────────
  Future<void> _checkForUpdate() async {
    setState(() {
      _checkingUpdate = true;
      _updateMsg = 'Checking for a signed release…';
      _pendingArtifact = null;
    });
    try {
      final info = await PackageInfo.fromPlatform();
      final current = info.version; // e.g. "1.0.0"
      final manifest = await UpdateService.fetchVerifiedManifest();
      if (manifest == null) {
        setState(() => _updateMsg =
            'No verified release found (no reachable, signed manifest).');
        return;
      }
      final r = await UpdateService.checkForUpdate(manifest, current);
      if (!r.update) {
        setState(() => _updateMsg = r.reason == 'already current'
            ? 'You are on the latest version ($current).'
            : 'No update: ${r.reason}');
        return;
      }
      setState(() {
        _pendingArtifact = r.artifact;
        _updateMsg =
            'Update ${r.version} available (${_fmtBytes(r.artifact!.sizeBytes)}), '
            'signature verified (${r.validSigs}/${r.threshold}).';
      });
    } catch (e) {
      setState(() => _updateMsg = 'Update check failed: $e');
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }

  Future<void> _downloadAndApply() async {
    final art = _pendingArtifact;
    if (art == null) return;
    setState(() {
      _downloading = true;
      _downloadProgress = 0;
      _updateMsg = 'Downloading & verifying ${art.version}…';
    });
    try {
      final path = await UpdateService.downloadVerifiedArtifact(
        art,
        onProgress: (p) {
          if (mounted) setState(() => _downloadProgress = p);
        },
      );
      if (path == null) {
        setState(() => _updateMsg =
            'Download failed or SHA-256 did not match the signed manifest — refused.');
        return;
      }
      // The desktop artifacts are PORTABLE archives (Windows .zip holding SovNode.exe,
      // macOS .tar.gz holding the .app, Linux .AppImage), not installers. Opening one
      // hands it to Explorer / Archive Utility; quitting the app at that point (what
      // v1.2.0 did) just left the user with an archive window and no app. So: open it,
      // say exactly what to do, and keep running. Only a real installer (.exe/.msi/.pkg)
      // gets the launch-then-exit path.
      final lower = path.toLowerCase();
      final isInstaller = lower.endsWith('.exe') || lower.endsWith('.msi') || lower.endsWith('.pkg');
      if (!isInstaller) {
        final opened = await UpdateService.launchInstaller(path);
        setState(() => _updateMsg = (opened
                ? 'Verified ${art.version} downloaded and opened:\n'
                : 'Verified ${art.version} saved to:\n') +
            '$path\n'
            'It is a portable build: run the SovNode inside it in place of this one. '
            'Your wallet and data stay where they are.');
        return;
      }
      setState(() => _updateMsg = 'Verified. Launching installer…');
      final launched = await UpdateService.launchInstaller(path);
      if (!launched) {
        setState(() => _updateMsg =
            'Verified download saved to:\n$path\nOpen it to finish updating.');
        return;
      }
      // Give the detached installer a moment to take over, then exit so the
      // running bundle can be replaced.
      await Future.delayed(const Duration(milliseconds: 800));
      exit(0);
    } catch (e) {
      setState(() => _updateMsg = 'Update failed: $e');
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  String _fmtBytes(int b) {
    if (b <= 0) return 'unknown size';
    const u = ['B', 'KB', 'MB', 'GB'];
    var v = b.toDouble();
    var i = 0;
    while (v >= 1024 && i < u.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${u[i]}';
  }

  Widget _buildUpdateCard() {
    final hasUpdate = _pendingArtifact != null;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(10),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.system_update_alt_rounded, color: _teal, size: 20),
              SizedBox(width: 8),
              Text('Software Updates',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Updates are signed by the network and verified on-device before '
            'they apply — a poisoned mirror cannot ship code to you.',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
          if (_updateMsg.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(_updateMsg,
                style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
          ],
          if (_downloading) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: _downloadProgress > 0 ? _downloadProgress : null,
              backgroundColor: Colors.white12,
              valueColor: const AlwaysStoppedAnimation(_teal),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed:
                      (_checkingUpdate || _downloading) ? null : _checkForUpdate,
                  icon: _checkingUpdate
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: _teal))
                      : const Icon(Icons.search_rounded, size: 16),
                  label: const Text('Check for updates'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white24),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
              if (hasUpdate) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _downloading ? null : _downloadAndApply,
                    icon: const Icon(Icons.download_rounded, size: 16),
                    label: Text('Update to ${_pendingArtifact!.version}'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _teal,
                      foregroundColor: _navy,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  // Live operator panel shown while the bundled node is running: uptime (matters
  // for the 21-day streak), the ports it serves, and a link to the local dashboard.
  Widget _buildNodeLiveStatus(NodeController nc) {
    return StreamBuilder<int>(
      stream: Stream<int>.periodic(const Duration(seconds: 1), (i) => i),
      builder: (_, __) {
        final up = nc.uptime;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // "Running" and "serving citizens" are different things, and this
            // line used to claim the second while only knowing the first. A node
            // behind a router that drops inbound connections is up, syncing and
            // completely unreachable — the operator deserves to be told that
            // rather than shown a green badge that means nothing.
            ValueListenableBuilder<bool>(
              valueListenable: NodeController.instance.reachVerified,
              builder: (_, verified, __) {
                // Reachability has THREE honest outcomes, not two. A node can be
                // reached DIRECTLY (an inbound peer proof), reached INDIRECTLY by
                // design (a Tailscale Funnel tunnel, or a circuit relay through
                // other nodes — neither of which can or should port-forward), or
                // not reached AT ALL. The old copy only knew verified-vs-not, so a
                // NAT'd relay/Funnel node was told "not reachable — forward ports
                // 443/7771", which both contradicts the "Route: Circuit relay"
                // line below it and is impossible on a hotspot. The 1s periodic
                // rebuild above keeps this in step with reachMethod changes.
                final method   = NodeController.instance.reachMethod.value;
                final isTunnel = method == 'tailscale-funnel' || method == 'plugin-ingress';
                final isRelay  = method == 'circuit-relay';
                final starting = !verified && !isTunnel && !isRelay &&
                    up != null && up.inSeconds < 45;

                final Color color;
                final IconData icon;
                final String label;
                String? note;
                // One truth, stated securely: the node is either serving or on its
                // way to serving. We deliberately DO NOT advertise the public
                // address, the open ports, or that "the ledger is here" — those
                // are a map for an attacker, and the protocol needs none of them
                // shown to do its job. Reachability is the protocol's work, not a
                // chore we hand the operator (no "forward ports").
                if (verified || isTunnel || isRelay) {
                  color = _teal;
                  icon  = verified ? Icons.bolt_rounded
                        : (isTunnel ? Icons.cloud_done_rounded : Icons.hub_rounded);
                  label = 'Serving citizens • uptime ${_fmtUptimeDur(up)}';
                  if (isRelay) {
                    note = 'The network routes citizens to this node through the mesh — '
                        'no port-forward, no external service, nothing exposed. The '
                        'protocol handles reachability for you.';
                  }
                } else if (starting) {
                  color = Colors.white54;
                  icon  = Icons.hourglass_top_rounded;
                  label = 'Starting • joining the mesh…';
                } else {
                  // Transient: detection hasn't settled. With auto-fallback the node
                  // serves through the mesh on its own if no direct route is found —
                  // so this is "getting ready", never a dead end and never a chore.
                  color = const Color(0xFFF5C518);
                  icon  = Icons.autorenew_rounded;
                  label = 'Joining the mesh • uptime ${_fmtUptimeDur(up)}';
                  note  = 'Working out how the network will route citizens to this node. '
                      'If no direct route is available it serves through the mesh '
                      'automatically — nothing for you to configure or expose.';
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(icon, color: color, size: 16),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(label,
                            style: TextStyle(
                                color: color, fontSize: 12.5, fontWeight: FontWeight.w600)),
                      ),
                    ]),
                    if (note != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(note,
                          style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.55), fontSize: 11, height: 1.35),
                        ),
                      ),
                  ],
                );
              },
            ),
            const SizedBox(height: 8),
            // WHICH route citizens would actually arrive by. The node picks one
            // of several at boot and they are not equivalent — a port mapping is
            // a direct path, a circuit relay depends on other people's nodes,
            // and Funnel is a tunnel out through Tailscale. The operator could
            // not previously tell which they had, so "not reachable" gave them
            // no clue what to change.
            ValueListenableBuilder<String>(
              valueListenable: NodeController.instance.reachMethod,
              builder: (_, method, __) {
                if (method.isEmpty) return const SizedBox.shrink();
                // EVERY method the node can report. The first version of this
                // covered five cases and two of them ('static', 'static-host')
                // do not exist in the node at all — I wrote them from memory
                // instead of reading network_manager.js. Three real ones
                // (direct-upnp, operator-configured, forced) fell through to a
                // raw internal string. Keep this list in step with the
                // `reachabilityMethod:` assignments in network_manager.js.
                // Route wording is deliberately generic — it names HOW citizens
                // arrive without printing the operator's public address, ports, or
                // any internal method string that could help someone target them.
                final label = switch (method) {
                  'direct-inbound' || 'direct-nat' || 'direct' =>
                    'Direct — reachable from the internet',
                  'direct-portmap' || 'direct-upnp' =>
                    'Direct — your router opened the port (UPnP)',
                  'tailscale-funnel' || 'plugin-ingress' => 'Tunnel — via Tailscale',
                  'operator-configured' => 'Direct — a host you configured',
                  'forced' => 'Direct',
                  'circuit-relay' => 'Through the mesh — the network routes citizens to you',
                  _ => 'Through the mesh',
                };
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(Icons.route_rounded,
                        size: 14, color: Colors.white.withValues(alpha: 0.45)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text('Route: $label',
                          style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.6), fontSize: 11.5)),
                    ),
                  ]),
                );
              },
            ),
            // Identify this node the way the whole network already does — by its
            // DETERMINISTIC NAME, never its IP. An address on screen is a target
            // for an attacker and leaks where the machine lives; the name is
            // unique, memorable, and reveals nothing. Same naming the Known Nodes
            // list uses. We deliberately no longer print the public/local IP or
            // the open ports — the protocol needs none of it shown to do its job.
            ValueListenableBuilder<String>(
              valueListenable: NodeController.instance.nodeId,
              builder: (_, nid, __) {
                if (nid.isEmpty) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(children: [
                    Icon(Icons.badge_outlined,
                        size: 14, color: Colors.white.withValues(alpha: 0.45)),
                    const SizedBox(width: 6),
                    Text('This node: ${RelayConnector.getNickname(nid)}',
                        style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.6), fontSize: 11.5)),
                  ]),
                );
              },
            ),
            const SizedBox(height: 4),
            Text('Operator dashboard: http://127.0.0.1:8080/dashboard',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 11)),
          ],
        );
      },
    );
  }

  String _fmtUptimeDur(Duration? d) {
    if (d == null) return '—';
    final days = d.inDays;
    final h = d.inHours % 24;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    if (days > 0) return '${days}d ${h}h ${m}m';
    if (h > 0) return '${h}h ${m}m ${s}s';
    if (m > 0) return '${m}m ${s}s';
    return '${s}s';
  }

  // Desktop: a real ON/OFF toggle for the bundled full node (the phone shows the
  // "download the node software" card instead, since it can't run a node).
  Widget _buildFullNodeCard() {
    final nc = NodeController.instance;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [_gold.withValues(alpha: 0.15), _gold.withValues(alpha: 0.05)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _gold.withValues(alpha: 0.3)),
      ),
      padding: const EdgeInsets.all(18),
      child: ValueListenableBuilder<bool>(
        valueListenable: nc.running,
        builder: (_, running, __) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.dns_outlined, color: _gold, size: 22),
              const SizedBox(width: 10),
              const Expanded(
                child: Text('Full Node',
                    style: TextStyle(color: Color(0xFFF5C518), fontSize: 16, fontWeight: FontWeight.bold)),
              ),
              Switch(
                value: running,
                activeColor: _gold,
                onChanged: nc.isAvailable ? _toggleFullNode : null,
              ),
            ]),
            const SizedBox(height: 8),
            Text(
              running
                  ? 'This computer is serving the SOV network. Keep it on continuously (≥21 days) to earn the monthly operator payout — credited to your wallet.'
                  : nc.isAvailable
                      ? 'Turn ON to run a full SOV node here — join the mesh, serve citizens (circuit-relay if behind NAT), and earn the operator payout. Sealed to your wallet.'
                      : 'The bundled node is not present in this dev build; it ships with the installed app.',
              style: const TextStyle(color: Colors.white60, fontSize: 13, height: 1.5),
            ),
            if (!running && nc.isAvailable) ...[
              const SizedBox(height: 12),
              const Text('How citizens reach this node',
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
              const SizedBox(height: 4),
              DropdownButton<ReachMode>(
                value: _reach,
                isExpanded: true,
                dropdownColor: _navy,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                onChanged: (m) => setState(() => _reach = m ?? ReachMode.auto),
                items: ReachMode.values
                    .map((m) => DropdownMenuItem(value: m, child: Text(_reachLabel(m))))
                    .toList(),
              ),
              if (_reach == ReachMode.staticHost)
                TextField(
                  controller: _staticHostCtrl,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: const InputDecoration(
                    hintText: 'public host or IP[:port], e.g. 203.0.113.5:443',
                    hintStyle: TextStyle(color: Colors.white30, fontSize: 12),
                  ),
                ),
              // Assisted Tailscale setup — only when Tailscale reach is chosen and
              // Tailscale isn't installed yet. One tap installs it (winget/MSI),
              // then guides the operator's own one-time browser sign-in. No
              // hunting on tailscale.com; the operator stays on their own tailnet.
              if (_reach == ReachMode.tailscale && !nc.isTailscaleInstalled)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Tailscale gives your home node a free public address with no '
                        'router setup. It is not installed yet — tap to install it '
                        '(you will approve one Windows prompt), then sign in to your '
                        'own Tailscale account once.',
                        style: TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                      const SizedBox(height: 6),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                            backgroundColor: _gold, foregroundColor: Colors.black),
                        icon: _installingTs
                            ? const SizedBox(width: 14, height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                            : const Icon(Icons.download_rounded, size: 16),
                        label: Text(_installingTs ? 'Installing…' : 'Install Tailscale'),
                        onPressed: _installingTs ? null : _installTailscale,
                      ),
                    ],
                  ),
                ),
              // "Sign in to Tailscale" — installed but not logged in yet. Tailscale
              // auth is ALWAYS a browser session (SSO to the operator's own
              // Google/Microsoft/GitHub/email — no in-app password). We start
              // `tailscale up`, auto-open the login URL it returns, and detect
              // completion. The operator just approves in their browser.
              if (_reach == ReachMode.tailscale && nc.isTailscaleInstalled && _tsNeedsLogin) ...[
                // Auto-open the login URL the moment `tailscale up` emits it.
                ValueListenableBuilder<String>(
                  valueListenable: nc.tailscaleLoginUrl,
                  builder: (_, url, __) {
                    if (url.isNotEmpty && url != _lastTsUrlOpened) {
                      _lastTsUrlOpened = url;
                      WidgetsBinding.instance.addPostFrameCallback((_) =>
                          launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication));
                    }
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(
                          _tsSigningIn
                              ? 'A browser tab is opening for you to sign in to your own '
                                'Tailscale account. Approve adding this device, then come '
                                'back — the node continues automatically.'
                              : 'Sign in to Tailscale with your own account (Google, '
                                'Microsoft, GitHub, or email). It opens in your browser — '
                                'SOV never sees your login.',
                          style: const TextStyle(color: Colors.white70, fontSize: 12),
                        ),
                        const SizedBox(height: 6),
                        Row(children: [
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                                backgroundColor: _gold, foregroundColor: Colors.black),
                            icon: _tsSigningIn
                                ? const SizedBox(width: 14, height: 14,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                                : const Icon(Icons.login_rounded, size: 16),
                            label: Text(_tsSigningIn ? 'Waiting for sign-in…' : 'Sign in to Tailscale'),
                            onPressed: _tsSigningIn ? null : _tailscaleSignIn,
                          ),
                          if (url.isNotEmpty) ...[
                            const SizedBox(width: 8),
                            TextButton.icon(
                              icon: const Icon(Icons.open_in_new, size: 14, color: _gold),
                              label: const Text('Open Tailscale sign-in',
                                  style: TextStyle(color: _gold, fontSize: 12)),
                              onPressed: () => launchUrl(Uri.parse(url),
                                  mode: LaunchMode.externalApplication),
                            ),
                          ],
                        ]),
                      ]),
                    );
                  },
                ),
              ],
              // One-click "Enable Tailscale Funnel" — appears only when Tailscale
              // told us Funnel isn't turned on yet. Saves the operator from any
              // ACL/JSON editing: tap → approve in browser → toggle the node on.
              ValueListenableBuilder<String>(
                valueListenable: nc.setupActionUrl,
                builder: (_, url, __) => url.isEmpty
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'One more step: Tailscale needs a single click to turn on '
                              'Funnel (free). Tap below, approve in your browser, then '
                              'switch the node ON again.',
                              style: TextStyle(color: Colors.white70, fontSize: 12),
                            ),
                            const SizedBox(height: 6),
                            ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                  backgroundColor: _gold,
                                  foregroundColor: Colors.black),
                              icon: const Icon(Icons.open_in_new, size: 16),
                              label: const Text('Enable Tailscale Funnel'),
                              onPressed: () => launchUrl(Uri.parse(url),
                                  mode: LaunchMode.externalApplication),
                            ),
                          ],
                        ),
                      ),
              ),
              Row(children: [
                Checkbox(
                    value: _autostart,
                    activeColor: _gold,
                    onChanged: (v) => _toggleAutostart(v ?? false)),
                const Expanded(
                    child: Text('Start on login (keep the 21-day uptime streak)',
                        style: TextStyle(color: Colors.white60, fontSize: 12))),
              ]),
            ],
            if (running) ...[
              const SizedBox(height: 12),
              _buildNodeLiveStatus(nc),
              ValueListenableBuilder<String>(
                valueListenable: nc.publicHost,
                builder: (_, host, __) => host.isEmpty
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text('Reachable at: $host',
                            style: const TextStyle(color: _teal, fontSize: 12)),
                      ),
              ),
              const SizedBox(height: 10),
              ValueListenableBuilder<String>(
                valueListenable: nc.lastLine,
                builder: (_, line, __) => Text(
                  line.isEmpty ? 'starting…' : line,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white38, fontSize: 11, fontFamily: 'monospace'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildRunANodeCard() {
    if (NodeController.isDesktopPlatform) return _buildFullNodeCard();
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [_gold.withValues(alpha: 0.15), _gold.withValues(alpha: 0.05)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _gold.withValues(alpha: 0.3)),
      ),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.dns_outlined, color: _gold, size: 22),
              SizedBox(width: 10),
              Text(
                'Run a SOV Node',
                style: TextStyle(
                  color: Color(0xFFF5C518),
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            'Turn your computer into a sovereign citizen node. '
            'Earn SOV for every citizen you serve. '
            'Download the SOV Node software from sov-node.network.',
            style: TextStyle(color: Colors.white60, fontSize: 13, height: 1.5),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _actionButton(
                'Learn More',
                Icons.open_in_new,
                () {
                  // Future: open SOV Academy article about running a node
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Visit sov-node.network to download')),
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Small helpers ────────────────────────────────────────────────────────

  Widget _infoRow(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        SizedBox(
          width: 120,
          child: Text(label, style: const TextStyle(color: Colors.white54, fontSize: 12)),
        ),
        Expanded(
          child: Text(value, style: const TextStyle(color: Colors.white, fontSize: 12)),
        ),
      ],
    ),
  );

  Widget _chip(String text, {Color? color, Color? textColor}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: color ?? Colors.white10,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      text,
      style: TextStyle(
        color: textColor ?? Colors.white70,
        fontSize: 10,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  Widget _actionButton(String label, IconData icon, VoidCallback onTap) =>
    GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: _gold,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 13)),
            const SizedBox(width: 6),
            Icon(icon, color: Colors.black, size: 14),
          ],
        ),
      ),
    );
}
