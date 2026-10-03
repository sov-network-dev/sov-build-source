// lib/screens/relay_pool_screen.dart
// ─────────────────────────────────────────────────────────────────────────────
// RELAY POOL STATUS SCREEN
//
// Shows all known relay nodes from RelayConnector.getRelayPool().
// The currently connected relay is highlighted with a green border and
// a "Connected" badge showing the transport type (Native or WSS).
// Pull-to-refresh re-fetches the pool.
// ─────────────────────────────────────────────────────────────────────────────
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../sov_node_sdk/relay_connector.dart';

class RelayPoolScreen extends StatefulWidget {
  const RelayPoolScreen({super.key});

  @override
  State<RelayPoolScreen> createState() => _RelayPoolScreenState();
}

class _RelayPoolScreenState extends State<RelayPoolScreen> {
  static const _navy   = Color(0xFF0A1628);
  static const _gold   = Color(0xFFB8960C);
  static const _cardBg = Color(0xFF0D1F3A);

  List<RelayEntry> _relays      = [];
  bool             _loading     = true;
  String?          _error;
  DateTime?        _lastFetch;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    setState(() { _loading = true; _error = null; });
    try {
      final pool = await RelayConnector.getRelayPool();
      if (mounted) {
        setState(() {
          _relays    = pool;
          _loading   = false;
          _lastFetch = DateTime.now();
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() { _error = e.toString(); _loading = false; });
      }
    }
  }

  /// Human-readable "X minutes ago" label for the last-fetch timestamp.
  String _lastUpdatedLabel() {
    if (_lastFetch == null) return '';
    final diff = DateTime.now().difference(_lastFetch!);
    if (diff.inSeconds < 60)  return 'Last updated: just now';
    if (diff.inMinutes == 1)  return 'Last updated: 1 minute ago';
    if (diff.inMinutes < 60)  return 'Last updated: ${diff.inMinutes} minutes ago';
    if (diff.inHours == 1)    return 'Last updated: 1 hour ago';
    return 'Last updated: ${diff.inHours} hours ago';
  }

  // ── Build ──────────────────────────────────────────────────────────────────

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
        title: const Text('Relay Pool',
            style: TextStyle(
                color: Color(0xFFB8960C),
                fontWeight: FontWeight.bold,
                fontSize: 18)),
        actions: [
          IconButton(
            tooltip: 'Connect to my node',
            icon: const Icon(Icons.dns_rounded, color: Colors.white38),
            onPressed: _showCustomNodeDialog,
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Colors.white38),
            onPressed: _fetch,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _fetch,
        color: _gold,
        backgroundColor: _cardBg,
        child: _loading
            ? const Center(
                child: CircularProgressIndicator(
                    color: Color(0xFFB8960C), strokeWidth: 1.5))
            : _error != null
                ? _buildError()
                : _relays.isEmpty
                    ? _buildEmpty()
                    : _buildList(),
      ),
    );
  }

  /// "Connect to my node" — lets a citizen point the app at their OWN node by
  /// hostname (e.g. a node reachable via the operator's own address / external tunnel
  /// tunnel). Saved to SharedPreferences 'custom_node'; the connector tries it
  /// FIRST on the next connect. Client-side preference only — no protocol change.
  Future<void> _showCustomNodeDialog() async {
    final prefs = await SharedPreferences.getInstance();
    final controller =
        TextEditingController(text: prefs.getString('custom_node') ?? '');
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _cardBg,
        title: const Text('Connect to my node',
            style: TextStyle(color: Color(0xFFB8960C), fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter your node address (host, host:port, or wss://host). '
              'The app will connect to it first.',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'sovnode.example.com',
                hintStyle: const TextStyle(color: Colors.white24),
                enabledBorder: const OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white24)),
                focusedBorder: const OutlineInputBorder(
                    borderSide: BorderSide(color: Color(0xFFB8960C))),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await prefs.remove('custom_node');
              if (ctx.mounted) Navigator.pop(ctx);
              _reconnectAfterCustomNodeChange(null, 'Cleared — using the public pool.');
            },
            child: const Text('Clear', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () async {
              final v = controller.text.trim();
              if (v.isEmpty) {
                await prefs.remove('custom_node');
              } else {
                await prefs.setString('custom_node', v);
              }
              if (ctx.mounted) Navigator.pop(ctx);
              _reconnectAfterCustomNodeChange(
                  v.isEmpty ? null : v, v.isEmpty ? 'Cleared.' : 'Saved. Connecting to $v…');
            },
            child: const Text('Save & connect',
                style: TextStyle(color: Color(0xFFB8960C))),
          ),
        ],
      ),
    );
  }

  Future<void> _reconnectAfterCustomNodeChange(String? host, String msg) async {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
    // Reconnect so the new choice takes effect. Saving → connect straight to the
    // node (raced first); clearing → normal pool connect.
    await RelayConnector.disconnect();
    if (host != null && host.isNotEmpty) {
      final addr = host.contains('://') ? host : 'wss://$host';
      await RelayConnector.connectToNode(addr);
    } else {
      await RelayConnector.connect();
    }
    if (!mounted) return;
    _fetch();
    // Surface the ACTUAL outcome so the user can self-diagnose (no logs needed):
    // did we connect to THEIR node, or fall back to the pool, or fail entirely?
    if (host != null && host.isNotEmpty) {
      final h = ((host.contains('://')
                  ? Uri.tryParse(host)?.host
                  : host.split(':').first) ??
              host)
          .toLowerCase();
      final ep = RelayConnector.currentEndpoint.toLowerCase();
      final onMyNode = RelayConnector.isConnected && ep.contains(h);
      final connected = RelayConnector.isConnected;
      showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          backgroundColor: _cardBg,
          title: Text(
            onMyNode ? 'Connected to your node ✓' : 'Not on your node',
            style: TextStyle(
                color: onMyNode ? const Color(0xFF4CAF50) : Colors.orangeAccent,
                fontSize: 16),
          ),
          content: Text(
            onMyNode
                ? 'You are now connected directly to your node:\n$h'
                : connected
                    ? 'Your node "$h" was unreachable, so the app stayed on the '
                        'network pool:\n$ep\n\nCheck the node is running and the '
                        'address is exactly right (host only, no http://).'
                    : 'Could not connect to "$h" and no pool fallback succeeded. '
                        'Check your internet connection and the node address.',
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('OK', style: TextStyle(color: Color(0xFFB8960C))),
            ),
          ],
        ),
      );
    }
  }

  Widget _buildList() {
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      // +1 for header, +1 for footer timestamp
      itemCount: _relays.length + 2,
      itemBuilder: (_, i) {
        if (i == 0) return _buildSummaryHeader();
        if (i == _relays.length + 1) return _buildLastUpdated();
        return _buildRelayCard(_relays[i - 1]);
      },
    );
  }

  Widget _buildLastUpdated() {
    final label = _lastUpdatedLabel();
    if (label.isEmpty) return const SizedBox(height: 16);
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 16),
      child: Center(
        child: Text(
          label,
          style: const TextStyle(color: Colors.white24, fontSize: 11),
        ),
      ),
    );
  }

  Widget _buildSummaryHeader() {
    final connected = RelayConnector.isConnected;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
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
                  width: 7, height: 7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: connected
                        ? Colors.greenAccent
                        : Colors.redAccent,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  connected ? 'Relay Connected' : 'Relay Offline',
                  style: TextStyle(
                    color: connected
                        ? Colors.greenAccent
                        : Colors.redAccent,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          Text(
            '${_relays.length} node${_relays.length == 1 ? '' : 's'}',
            style: const TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ],
      ),
    );
  }

  static Color _getPingColor(int ms) {
    if (ms < 100) return Colors.greenAccent;
    if (ms < 300) return Colors.amberAccent;
    return Colors.redAccent;
  }

  Widget _buildRelayCard(RelayEntry relay) {
    final connEndpoint = RelayConnector.currentEndpoint;
    final ctype        = RelayConnector.connectionType;
    final pingMs       = RelayConnector.relayPingTimes[relay.relayId];

    // Triple-strategy match — any one hit marks this card as active:
    //   1. Exact URL  — fast path, works in the normal case
    //   2. Relay ID   — reliable when _resolveCurrentRelayId() has run
    //   3. IP host    — fallback for format drift (trailing slash, port diff)
    final connHost = connEndpoint.isNotEmpty
        ? (Uri.tryParse(connEndpoint)?.host ?? '')
        : '';
    final isActive = RelayConnector.isConnected && (
        (connEndpoint.isNotEmpty && relay.wsUrl == connEndpoint) ||
        (RelayConnector.currentRelayId.isNotEmpty &&
            relay.relayId == RelayConnector.currentRelayId) ||
        (connHost.isNotEmpty && relay.ip == connHost)
    );

    // Transport badge text for the connected relay
    final transportLabel = isActive
        ? (ctype == 'native' ? 'Native' : 'WSS')
        : null;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: isActive ? const Color(0xFF0B2210) : _cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isActive
              ? Colors.greenAccent.withAlpha(80)
              : Colors.white.withAlpha(12),
          width: isActive ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Top row: icon + relay ID + badges ────────────────────────────────
          Row(
            children: [
              Container(
                width: 40, height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isActive
                      ? Colors.greenAccent.withAlpha(25)
                      : _gold.withAlpha(15),
                  border: Border.all(
                    color: isActive
                        ? Colors.greenAccent.withAlpha(80)
                        : _gold.withAlpha(45),
                  ),
                ),
                child: Icon(
                  isActive
                      ? Icons.cell_tower_rounded
                      : Icons.cell_tower_outlined,
                  color: isActive ? Colors.greenAccent : _gold.withAlpha(140),
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      relay.displayName,
                      style: TextStyle(
                          color: isActive ? Colors.greenAccent : Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w700),
                    ),
                    Text(
                      relay.relayId,
                      style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 11,
                          fontFamily: 'monospace'),
                    ),
                  ],
                ),
              ),
              // Status + transport badges (stacked)
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _badge(
                    label: isActive ? 'Connected' : 'Peer',
                    color: isActive ? Colors.greenAccent : Colors.white38,
                    bgAlpha: isActive ? 25 : 10,
                    borderAlpha: isActive ? 80 : 20,
                  ),
                  if (transportLabel != null) ...[
                    const SizedBox(height: 4),
                    _badge(
                      label: transportLabel,
                      color: transportLabel == 'Native'
                          ? Colors.greenAccent
                          : Colors.orange,
                      bgAlpha: 12,
                      borderAlpha: 50,
                      fontSize: 10,
                    ),
                  ],
                  if (pingMs != null) ...[
                    const SizedBox(height: 4),
                    _badge(
                      label: '${pingMs}ms',
                      color: _getPingColor(pingMs),
                      bgAlpha: 12,
                      borderAlpha: 50,
                      fontSize: 10,
                    ),
                  ],
                ],
              ),
            ],
          ),

          const SizedBox(height: 14),
          Divider(height: 1, color: Colors.white.withAlpha(10)),
          const SizedBox(height: 12),

          // ── Detail rows ──────────────────────────────────────────────────────
          _detailRow('Node',     relay.displayName),
          const SizedBox(height: 6),
          _detailRow('Relay ID', relay.relayId),
          const SizedBox(height: 6),
          _detailRow('Endpoint', '[Protected]'),
          if (relay.fingerprint.length == 64) ...[
            const SizedBox(height: 6),
            _detailRow(
              'Fingerprint',
              '${relay.fingerprint.substring(0, 12)}…'
              '${relay.fingerprint.substring(relay.fingerprint.length - 12)}',
            ),
          ],
          const SizedBox(height: 6),
          _detailRow(
            'Added',
            _formatDate(DateTime.fromMillisecondsSinceEpoch(relay.addedAt)),
          ),
          if (isActive) ...[
            const SizedBox(height: 6),
            _detailRow(
              'Transport',
              transportLabel == 'Native'
                  ? 'SOV Native TCP (port 7771)'
                  : 'WebSocket TLS (WSS)',
            ),
          ],
          if (pingMs != null) ...[
            const SizedBox(height: 6),
            _detailRow('Ping', '${pingMs}ms'),
          ],
        ],
      ),
    );
  }

  Widget _badge({
    required String label,
    required Color  color,
    required int    bgAlpha,
    required int    borderAlpha,
    double          fontSize = 11,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withAlpha(bgAlpha),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withAlpha(borderAlpha)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 90,
          child: Text(label,
              style: const TextStyle(color: Colors.white38, fontSize: 11)),
        ),
        Expanded(
          child: Text(value,
              style: const TextStyle(
                  color: Colors.white60,
                  fontSize: 11,
                  fontFamily: 'monospace')),
        ),
      ],
    );
  }

  Widget _buildError() {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(32),
      children: [
        Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.signal_wifi_off_rounded,
                  color: Colors.redAccent, size: 48),
              const SizedBox(height: 16),
              const Text('Could not load relay pool',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(_error ?? 'Unknown error',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white38, fontSize: 12)),
              const SizedBox(height: 24),
              OutlinedButton.icon(
                onPressed: _fetch,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Retry'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _gold,
                  side: BorderSide(color: _gold.withAlpha(80)),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ],
          ),
        ),
      ],
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
              Icon(Icons.hub_outlined,
                  color: Colors.white.withAlpha(60), size: 48),
              const SizedBox(height: 16),
              const Text('No relay nodes found',
                  style: TextStyle(color: Colors.white60, fontSize: 15)),
              const SizedBox(height: 8),
              const Text('Pull down to refresh',
                  style: TextStyle(color: Colors.white38, fontSize: 12)),
            ],
          ),
        ),
      ],
    );
  }

  String _formatDate(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }
}
