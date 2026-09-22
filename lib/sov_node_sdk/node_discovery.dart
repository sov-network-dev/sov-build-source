import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dht_discovery.dart';

/// ═══════════════════════════════════════════════════════════════════════════
/// NodeDiscovery — SOV Node pool management
///
/// Discovers and caches the list of SOV Node addresses for the citizen app.
///
/// DISCOVERY PRIORITY:
///   1. SharedPreferences cache (last successfully connected addresses)
///   2. HTTP fetch from bootstrap node: GET http://[bootstrapIp]/relay-pool
///   3. Bundled fallback addresses in assets/relay_pool.json (see relay_connector)
///
/// The pool is automatically refreshed after a successful connection.
/// If the current node goes offline, `getNextNode()` returns the next
/// candidate from the pool.
///
/// IP-ONLY: No domain names. The SOV Node is sovereign and does not depend
/// on any DNS infrastructure. All addresses are raw IP:port pairs.
/// ═══════════════════════════════════════════════════════════════════════════

class SovNodeEntry {
  final String nodeId;
  final String address;     // raw WSS URL: 'wss://IP:PORT'
  final String ip;
  final int    port;
  final String nickname;
  final int    addedAt;
  int          failCount;   // consecutive connection failures

  SovNodeEntry({
    required this.nodeId,
    required this.address,
    required this.ip,
    required this.port,
    this.nickname  = '',
    required this.addedAt,
    this.failCount = 0,
  });

  factory SovNodeEntry.fromJson(Map<String, dynamic> json) {
    // Accepts several formats:
    //   relay_pool.json:    { "relay_id": "...", "endpoint": "wss://IP:443" }
    //   Older relay format: { "node_id": "...", "address": "wss://IP:PORT" }
    //   sov-node pool:      { "node_id": "...", "address": "IP:7771" }  ← peer mesh addr
    //
    // IMPORTANT: The sov-node peer mesh uses port 7771 internally. The address field
    // from /relay-pool is always "IP:7771" (not a full URL). We MUST always use port 443
    // for citizen WebSocket connections regardless of what port appears in the address.
    final rawEndpoint = (json['endpoint'] as String?) ??
                        (json['address']  as String?) ??
                        (json['url']      as String?) ?? '';
    // Normalise: if address is "IP:PORT" (no scheme), extract the IP
    String ip = '';
    if (rawEndpoint.startsWith('wss://') || rawEndpoint.startsWith('ws://')) {
      final uri = Uri.tryParse(rawEndpoint);
      ip = uri?.host ?? '';
    } else {
      // "IP:PORT" or just "IP" — take everything before the first colon
      ip = rawEndpoint.split(':').first.trim();
    }
    // Always use 443 for citizen WSS — sov-node peer mesh is on 7771
    const int citizenPort = 443;
    final address = ip.isNotEmpty ? 'wss://$ip:$citizenPort' : '';
    return SovNodeEntry(
      nodeId:   (json['relay_id'] as String?) ??
                (json['node_id']  as String?) ??
                (json['id']       as String?) ?? ip,
      address:  address,
      ip:       ip,
      port:     citizenPort,
      nickname: (json['nickname'] as String?) ??
                (json['name']     as String?) ?? '',
      addedAt:  (json['added_at'] as num?)?.toInt() ??
                DateTime.now().millisecondsSinceEpoch,
    );
  }

  Map<String, dynamic> toJson() => {
    'node_id':  nodeId,
    'address':  address,
    'ip':       ip,
    'port':     port,
    'nickname': nickname,
    'added_at': addedAt,
  };

  /// WSS URL for WebSocket connection (same as `address`)
  String get wsUrl => address.isNotEmpty ? address : 'wss://$ip:$port';

  bool get isValid => ip.isNotEmpty && port > 0 && address.isNotEmpty;
}

// ─────────────────────────────────────────────────────────────────────────────

class NodeDiscovery {
  static const _prefsKey          = 'sov_node_pool_v1';
  static const _lastFetchKey      = 'sov_node_pool_last_fetch';
  static const _refreshIntervalMs = 3600000; // 1 hour

  // Federated pointer mirror — tried BEFORE the hardcoded IPs below, so a fresh
  // install still finds a CURRENT pool even if any of those IPs have gone stale
  // since this app was built. No relay IP is baked into this URL — it's a
  // neutral, independently-hosted JSON file the app fetches and parses the same
  // way as a bootstrap node's own /relay-pool response.
  // FEDERATED — tried in order until one answers. Each is an INDEPENDENT host
  // serving the same pool JSON, so no single provider (GitHub included) can stop
  // a fresh install from discovering the network. Adding mirrors costs no extra
  // trust: the pool is re-validated the same way regardless of which host served
  // it, exactly as the manifest is signature-checked in update_service.dart.
  static const List<String> _pointerPoolUrls = [
    'https://raw.githubusercontent.com/sov-network/relay-releases/main/relay_pool.json',
    'https://sov-pointer.sovnetworkdev.workers.dev/relay-pool.json',
  ];

  // NO ADDRESSES ARE COMPILED INTO THIS APP. Deliberately, and permanently.
  //
  // This list used to hold the live node IPs. That made every published build a
  // map of the network: anyone who wanted it — a hostile ISP, a regulator, an
  // attacker — could unzip the APK and read exactly which machines to pressure
  // or block. It also made the app useless the day those specific machines went
  // away, which for a network meant to outlive any particular server is the
  // wrong failure mode entirely.
  //
  // What ships instead is the *path* to discovery, never a destination:
  //
  //   1. Cached pool     — nodes this device has actually reached before
  //   2. Pointer mirrors — small JSON files on independent hosts; they publish
  //                        wherever the network currently is, and can be
  //                        updated without shipping a new app
  //   3. The public DHT  — infrastructure nobody owns, cannot be taken down,
  //                        and has no operator to serve an order to
  //
  // At genesis all three are empty or silent, and that is correct: there is
  // nothing to find until the first node exists. The moment it starts, it
  // announces itself to the DHT, and the next app launch finds it there with
  // nothing published, hosted, or typed in by anyone.
  static const List<String> _bootstrapIps = <String>[];

  static List<SovNodeEntry> _pool = [];

  // ── Initialise — load cache + optionally refresh from network ───────────────

  /// Load the cached node pool.  Call once at app start.
  /// Returns the number of entries loaded.
  static Future<int> init() async {
    await _loadCached();
    // Refresh in background if cache is stale (>1 hour old)
    _maybeRefreshBackground();
    return _pool.length;
  }

  /// Force a fresh fetch from the bootstrap nodes.
  /// Updates the in-memory pool and persists the result.
  static Future<List<SovNodeEntry>> refresh() async {
    final entries = await _fetchFromBootstrap();
    if (entries.isNotEmpty) {
      _pool = entries;
      await _saveToCache(entries);
      await _updateLastFetch();
      debugPrint('[NodeDiscovery] Pool refreshed: ${entries.length} nodes');
    }
    return _pool;
  }

  // ── Pool access ─────────────────────────────────────────────────────────────

  /// All known nodes sorted by fail count (most reliable first).
  static List<SovNodeEntry> get all => List.unmodifiable(
    [..._pool]..sort((a, b) => a.failCount.compareTo(b.failCount)),
  );

  /// Number of known nodes.
  static int get count => _pool.length;

  /// Returns the next candidate node to try, excluding `excludeAddress`.
  /// Prefers nodes with fewer connection failures.
  static SovNodeEntry? getNextNode({String? excludeAddress}) {
    final sorted = [..._pool]
      ..sort((a, b) => a.failCount.compareTo(b.failCount));
    for (final entry in sorted) {
      if (entry.isValid && entry.address != excludeAddress) return entry;
    }
    return sorted.firstOrNull;
  }

  /// Record a successful connection — resets fail count for the node.
  static void markSuccess(String address) {
    for (final e in _pool) {
      if (e.address == address) {
        e.failCount = 0;
        return;
      }
    }
  }

  /// Record a failed connection attempt — increments fail count.
  static void markFailure(String address) {
    for (final e in _pool) {
      if (e.address == address) {
        e.failCount++;
        return;
      }
    }
  }

  /// Add a node to the pool if not already present (e.g. from gossip).
  static Future<void> addNode(SovNodeEntry entry) async {
    if (!entry.isValid) return;
    final exists = _pool.any((e) => e.ip == entry.ip && e.port == entry.port);
    if (!exists) {
      _pool.add(entry);
      await _saveToCache(_pool);
    }
  }

  /// Parse a relay-pool JSON payload and merge into the pool.
  static Future<void> mergePool(Map<String, dynamic> poolJson) async {
    try {
      final list = poolJson['relays'] as List? ?? poolJson['nodes'] as List? ?? [];
      int added = 0;
      for (final item in list) {
        final entry = SovNodeEntry.fromJson(item as Map<String, dynamic>);
        if (!entry.isValid) continue;
        final exists = _pool.any((e) => e.ip == entry.ip && e.port == entry.port);
        if (!exists) {
          _pool.add(entry);
          added++;
        }
      }
      if (added > 0) {
        await _saveToCache(_pool);
        debugPrint('[NodeDiscovery] Merged $added new nodes from pool response');
      }
    } catch (e) {
      debugPrint('[NodeDiscovery] mergePool error: $e');
    }
  }

  // ── Private helpers ─────────────────────────────────────────────────────────

  static Future<void> _loadCached() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw   = prefs.getString(_prefsKey);
      if (raw == null) return;
      final list  = jsonDecode(raw) as List;
      _pool = list
          .map((item) => SovNodeEntry.fromJson(item as Map<String, dynamic>))
          .where((e) => e.isValid)
          .toList();
      debugPrint('[NodeDiscovery] Loaded ${_pool.length} cached nodes');
    } catch (e) {
      debugPrint('[NodeDiscovery] Cache load error: $e');
    }
  }

  static Future<void> _saveToCache(List<SovNodeEntry> entries) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, jsonEncode(entries.map((e) => e.toJson()).toList()));
    } catch (e) {
      debugPrint('[NodeDiscovery] Cache save error: $e');
    }
  }

  static Future<void> _updateLastFetch() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_lastFetchKey, DateTime.now().millisecondsSinceEpoch);
    } catch (e) {
      // ignore: prefs write failure is non-critical
    }
  }

  static void _maybeRefreshBackground() async {
    try {
      final prefs     = await SharedPreferences.getInstance();
      final lastFetch = prefs.getInt(_lastFetchKey) ?? 0;
      final age       = DateTime.now().millisecondsSinceEpoch - lastFetch;
      if (age > _refreshIntervalMs || _pool.isEmpty) {
        refresh(); // fire and forget
      }
    } catch (_) {}
  }

  /// Fetch the node pool. Tries the federated pointer mirror FIRST (no relay IP
  /// baked in); falls back to the hardcoded bootstrap IPs only if that fails.
  static Future<List<SovNodeEntry>> _fetchFromBootstrap() async {
    // Walk every federated pointer mirror before falling back to baked IPs, so a
    // single provider going down (or blocking the user's region) never strands a
    // fresh install.
    // Ask EVERY mirror and merge the answers, rather than trusting whichever
    // replies first.
    //
    // First-answer-wins looked reasonable and was quietly dangerous: mirrors
    // drift. On 2026-07-31 the GitHub copy listed one node while the Worker
    // listed three, and because GitHub is tried first every fresh install came
    // up with a single-node pool. The failure mode is worse than the waste — a
    // stale mirror that still answers is treated as authoritative, so if the one
    // node it names is dead, discovery stops there: no second mirror, no
    // compiled addresses, no DHT. One forgotten file becomes a single point of
    // failure for every new citizen.
    //
    // Merging removes that. A mirror can only ADD nodes; it can never shrink the
    // pool or mask a fresher one. Cost is one extra request on a path that runs
    // when the app has nothing better to do.
    final merged = <String, SovNodeEntry>{};
    for (final url in _pointerPoolUrls) {
      try {
        final entries = await _fetchPoolFromUrl(url);
        if (entries.isEmpty) continue;
        var added = 0;
        for (final e in entries) {
          if (e.ip.isEmpty) continue;
          if (merged.putIfAbsent(e.ip, () => e) == e) added++;
        }
        debugPrint('[NodeDiscovery] Pointer mirror gave ${entries.length} '
            '($added new): $url');
      } catch (e) {
        debugPrint('[NodeDiscovery] Pointer mirror failed ($url): $e');
      }
    }
    if (merged.isNotEmpty) {
      debugPrint('[NodeDiscovery] ${merged.length} node(s) after merging '
          '${_pointerPoolUrls.length} mirrors');
      // A mirror that ANSWERS is not the same as a mirror that is RIGHT. Merging
      // fixed one half of the danger described above (a stale mirror shrinking the
      // pool) and left the other: when every node a mirror names is DEAD this
      // returned them anyway and discovery stopped here — no bootstrap, no DHT.
      // The citizen then has a working app and a working connection and still
      // finds nobody, which is the exact scenario the DHT rung exists to close.
      //
      // Proven live 2026-08-07: with every node down for genesis, the Cloudflare
      // mirror still listed three of them, so a fresh install would have taken
      // that pool and never asked the DHT where the genesis node actually was.
      //
      // So require ONE of them to answer. If none do, the mirrors are stale and
      // we keep falling down the ladder.
      if (await _anyNodeAlive(merged.values)) {
        return merged.values.toList();
      }
      debugPrint('[NodeDiscovery] every mirrored node is unreachable — treating '
          'mirrors as stale and continuing to bootstrap/DHT');
    }
    // Try bootstrap IPs in order (shuffle to distribute load)
    final shuffled = [..._bootstrapIps]..shuffle();
    for (final ip in shuffled) {
      try {
        final entries = await _fetchPoolFrom(ip);
        if (entries.isNotEmpty) {
          debugPrint('[NodeDiscovery] Fetched ${entries.length} nodes from $ip');
          return entries;
        }
      } catch (e) {
        debugPrint('[NodeDiscovery] Bootstrap $ip failed: $e');
      }
    }

    // LAST RESORT — the public BitTorrent DHT.
    //
    // Reached only when every mirror is unreachable AND every address compiled
    // into this build has gone. That is the scenario where a network dies: the
    // citizen has a working app, a working internet connection, and no way left
    // to find anybody.
    //
    // The DHT closes it. It belongs to nobody, cannot be served a takedown, and
    // has outlived twenty years of attempts to shut it down. A node that is
    // running announces itself there; a client that is lost asks there.
    return _discoverViaDht();
  }

  /// Ask the public DHT where the network is, then PROVE each answer.
  ///
  /// Anyone at all can announce on an infohash, so what comes back is a list of
  /// candidates, not of nodes. Each is asked for its pool over HTTP: a genuine
  /// SOV node answers with a parseable pool, and anything else — a torrent
  /// client that happens to share the infohash, or an address someone planted —
  /// simply fails and is dropped. Nothing unverified is ever written to the pool.
  static Future<List<SovNodeEntry>> _discoverViaDht() async {
    try {
      debugPrint('[NodeDiscovery] All mirrors and known addresses failed — '
          'asking the public DHT');
      final targets = await DhtDiscovery.lookup(
        timeout: const Duration(seconds: 20),
        wantPeers: 12,
      );
      if (targets.isEmpty) {
        debugPrint('[NodeDiscovery] DHT returned nothing');
        return [];
      }

      // The DHT carries the peer-mesh port; citizens connect on the standard
      // client port, so only the host is taken forward.
      final hosts = <String>[];
      for (final t in targets) {
        final host = t.split(':').first;
        if (host.isNotEmpty && !hosts.contains(host)) hosts.add(host);
      }
      debugPrint('[NodeDiscovery] DHT gave ${hosts.length} candidate host(s) — verifying: ${hosts.join(", ")}');

      for (final host in hosts.take(6)) {
        // A candidate counts as a SOV node only if it serves a SIGNED pool
        // envelope. _fetchPoolFromDhtCandidate verifies that marker and — unlike
        // a plain _fetchPoolFrom() — treats an EMPTY signed pool as a valid
        // result by returning the responder itself. That empty-pool case is a
        // lone genesis (the only node live never lists itself), which is exactly
        // the network state a fresh app meets at launch. A non-node (torrent peer
        // sharing our infohash, parked domain) fails the marker and returns null.
        final entries = await _fetchPoolFromDhtCandidate(host);
        if (entries == null || entries.isEmpty) continue;
        debugPrint('[NodeDiscovery] DHT candidate $host served a signed pool — '
            '${entries.length} node(s) recovered with no mirror involved');
        return entries;
      }

      // No candidate served a verifiable pool over its HTTP courtesy endpoint.
      // That /relay-pool check is an OPTIMISATION, not the security gate: it lets
      // us learn a node's whole pool in one call and cheaply skip crawlers. But
      // these hosts already cleared the DHT's SOV-mesh-port filter, so they are
      // very likely real nodes whose :80 is firewalled, momentarily unreachable,
      // or — for a lone genesis fronted by a picky proxy — simply not answering
      // the pre-check while its relay port is up. Refusing them here is exactly
      // what left the very first citizen with a working app, a DHT that had
      // FOUND the genesis, and "cannot reach the SOV network relay".
      //
      // So hand them to the connector as DIAL TARGETS on the relay port. The WSS
      // handshake and peer interrogation on :443 are the real gate: anything that
      // is not a node fails to connect and the connector drops it (markFailure →
      // failure-triggered rediscovery). Nothing is trusted by being returned
      // here — it still has to survive connecting, which is the same bar a pool
      // entry has always had to clear.
      final now = DateTime.now().millisecondsSinceEpoch;
      final dialTargets = [
        for (final host in hosts.take(6))
          SovNodeEntry(
            nodeId:  host,
            address: 'wss://$host:443',
            ip:      host,
            port:    443,
            addedAt: now,
          ),
      ];
      if (dialTargets.isNotEmpty) {
        debugPrint('[NodeDiscovery] No DHT candidate served an HTTP pool — handing '
            '${dialTargets.length} mesh-port candidate(s) to the connector as dial targets');
        return dialTargets;
      }
      debugPrint('[NodeDiscovery] No DHT candidate proved to be a SOV node');
      return [];
    } catch (e) {
      debugPrint('[NodeDiscovery] DHT discovery failed: $e');
      return [];
    }
  }

  /// Verify a single DHT candidate and return usable nodes, or `null` if it is
  /// not a SOV node.
  ///
  /// Unlike [_fetchPoolFromUrl] used for a mirror, a genuine node that serves an
  /// EMPTY pool is a valid result here: a lone genesis is the only node alive and
  /// never lists itself, so its `/relay-pool` carries `nodes: []`. Genuineness is
  /// decided solely by the SIGNED envelope ([_looksLikeSovNodeResponse]); once
  /// that passes, the responder's own address is the reachable node, whatever its
  /// pool contained. This is the path that lets the first citizen reach genesis.
  static Future<List<SovNodeEntry>?> _fetchPoolFromDhtCandidate(
      String host) async {
    // A single dropped packet, a momentary 4xx, or a half-open pooled socket
    // must NOT make the first citizen abandon a live genesis — that is precisely
    // the "cannot reach the SOV network relay" failure. When only genesis is up
    // there is no second candidate to fall back to, so the one candidate is
    // probed a few times before it is given up on.
    for (var attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
      final result = await _probeDhtCandidate(host);
      if (result != null && result.isNotEmpty) return result;
    }
    return null;
  }

  static Future<List<SovNodeEntry>?> _probeDhtCandidate(String host) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 6);
    try {
      final request  = await client.getUrl(Uri.parse('http://$host/relay-pool'));
      final response = await request.close().timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) {
        await response.drain<void>();
        return null;
      }
      final body = await response.transform(utf8.decoder).join();
      final data = jsonDecode(body) as Map<String, dynamic>;
      if (!_looksLikeSovNodeResponse(data)) return null;

      final payload = data['payload'] as Map<String, dynamic>?;
      final list = data['relays'] as List?
                ?? data['nodes']  as List?
                ?? payload?['nodes'] as List?
                ?? payload?['relays'] as List?
                ?? [];
      final entries = <SovNodeEntry>[];
      for (final item in list) {
        try {
          final e = SovNodeEntry.fromJson(item as Map<String, dynamic>);
          if (e.isValid) entries.add(e);
        } catch (_) {}
      }
      // The responder is proven reachable and proven a node — more than the
      // (possibly empty) pool it returned. Add it if the pool omitted it.
      if (entries.every((e) => e.ip != host)) {
        entries.add(SovNodeEntry(
          nodeId:  host,
          address: 'wss://$host:443',
          ip:      host,
          port:    443,
          addedAt: DateTime.now().millisecondsSinceEpoch,
        ));
      }
      return entries;
    } catch (_) {
      // Not reachable, not JSON, or not a node. Expected for most candidates.
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// HTTP GET http://[ip]/relay-pool and parse the response.
  /// The SOV Node relay_pool.js HTTP server serves this endpoint.
  /// True if at least one of these nodes actually responds. Decides whether a
  /// pointer mirror's pool is LIVE or merely PRESENT. Probes run in parallel with
  /// a short timeout, so a fully dead mirror costs about 3s rather than N x 3s.
  static Future<bool> _anyNodeAlive(Iterable<SovNodeEntry> nodes) async {
    final probes = nodes.take(6).map((n) async {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 3);
      try {
        final req = await client.getUrl(Uri.parse('http://${n.ip}/relay-pool'));
        final res = await req.close().timeout(const Duration(seconds: 3));
        await res.drain<void>();
        return res.statusCode == 200;
      } catch (_) {
        return false;
      } finally {
        client.close(force: true);
      }
    }).toList();
    for (final alive in await Future.wait(probes)) {
      if (alive) return true;
    }
    return false;
  }

  static Future<List<SovNodeEntry>> _fetchPoolFrom(String ip) async {
    final entries = await _fetchPoolFromUrl('http://$ip/relay-pool');
    // Include the bootstrap IP itself if not already in the list
    if (entries.every((e) => e.ip != ip)) {
      entries.add(SovNodeEntry(
        nodeId:  ip,
        address: 'wss://$ip:443',
        ip:      ip,
        port:    443,
        addedAt: DateTime.now().millisecondsSinceEpoch,
      ));
    }
    return entries;
  }

  /// GET any URL serving the same relay-pool JSON shape — a bootstrap IP's own
  /// /relay-pool endpoint, or the federated pointer-mirror's static JSON file —
  /// and parse it into pool entries.
  /// Does this response actually come from a SOV node?
  ///
  /// Discovery hands us addresses from places anyone can write to — a public
  /// DHT, a mirror on someone else's host. "It returned JSON" is not an answer:
  /// a parked domain, a captive portal, or a crawler's web server will all
  /// return JSON of some kind, and treating that as a node means dialling
  /// strangers and, worse, republishing them to everyone else.
  ///
  /// A genuine node serves a SIGNED envelope, and that is the marker:
  ///
  ///   { "payload": { "version": 1, "nodes": [ { "node_id": <64 hex>,
  ///                                            "address": "<host>:7771" } ] },
  ///     "sig": "<signature over the payload>" }
  ///
  /// Checked here: the envelope shape, a `sig`, and node ids that are real
  /// 64-character hex. None of that can be produced by accident, and none of it
  /// requires trusting the host — it is a cheap structural filter that runs
  /// before anything is added to the pool.
  ///
  /// The pointer mirrors serve a plainer `{"nodes":[...]}` file and are allowed
  /// through without a signature: they are a publishing convenience, not an
  /// authority, and whatever they hand back still has to survive connecting.
  static bool _looksLikeSovNodeResponse(Map<String, dynamic> data) {
    final payload = data['payload'];
    if (payload is! Map) return false;
    if (data['sig'] == null) return false;
    final nodes = payload['nodes'];
    if (nodes is! List) return false;
    final hex64 = RegExp(r'^[0-9a-fA-F]{64}$');
    // A LONE GENESIS node legitimately serves an EMPTY pool: it is the only node
    // alive and never lists itself, so `nodes` is []. That is exactly the state a
    // fresh install meets at launch, so rejecting it here was the reason the first
    // citizen saw "cannot reach the SOV network relay" while the DHT had already
    // found genesis. Genuineness is proven by the SIGNED ENVELOPE, not by the pool
    // contents — a 64-hex `signer` key and a hex `sig` over the payload, neither of
    // which a crawler or parked domain sharing our infohash can produce by
    // accident. So an empty pool from a signed envelope passes; the DHT caller then
    // adds the responder itself as the one reachable node.
    if (nodes.isEmpty) {
      final sig = '${data['sig'] ?? ''}';
      return hex64.hasMatch('${data['signer'] ?? ''}') &&
          sig.length >= 64 && RegExp(r'^[0-9a-fA-F]+$').hasMatch(sig);
    }
    return nodes.any((n) =>
        n is Map && hex64.hasMatch('${n['node_id'] ?? ''}'));
  }

  static Future<List<SovNodeEntry>> _fetchPoolFromUrl(String url,
      {bool requireSovMarker = false}) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 6);
    try {
      final request  = await client.getUrl(Uri.parse(url));
      final response = await request.close().timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return [];
      final body = await response.transform(utf8.decoder).join();
      final data = jsonDecode(body) as Map<String, dynamic>;

      // Anything reached through the DHT must prove it is a node before it is
      // believed. Mirrors are exempt — see _looksLikeSovNodeResponse.
      if (requireSovMarker && !_looksLikeSovNodeResponse(data)) return [];

      // Support all formats:
      //   { "relays": [ { "relay_id", "endpoint" } ] }              ← relay_pool.js format
      //   { "nodes":  [ { "node_id",  "address"  } ] }              ← future SOV Node format
      //   { "payload": { "nodes": [...] } }                          ← sov-node signed format
      final payload = data['payload'] as Map<String, dynamic>?;
      final list = data['relays'] as List?
                ?? data['nodes']  as List?
                ?? payload?['nodes'] as List?
                ?? payload?['relays'] as List?
                ?? [];
      final entries = <SovNodeEntry>[];
      for (final item in list) {
        try {
          final e = SovNodeEntry.fromJson(item as Map<String, dynamic>);
          if (e.isValid) entries.add(e);
        } catch (_) {}
      }
      return entries;
    } finally {
      client.close(force: true);
    }
  }
}
