// ═══════════════════════════════════════════════════════════════════════════
// dht_discovery.dart — find the network through infrastructure nobody owns.
//
// WHY THIS EXISTS
// Every other way a client finds SOV depends on something that can be leaned
// on: a mirror someone hosts, a domain a registrar controls, an address handed
// over by a person. The BitTorrent Mainline DHT depends on nobody. We do not
// run it and cannot lose it — a client joins the same global table that torrent
// clients have kept alive for twenty years, and asks it where SOV nodes are.
//
// Take away every mirror, every domain and every provider, and a citizen who
// has never connected before can still find the network.
//
// TWO DELIBERATE RESTRICTIONS
//
//  1. THIS IS A CLIENT, NOT A SERVER. It sends queries and reads the answers.
//     Inbound queries are counted and then dropped on the floor — never
//     answered. That is stronger than refusing storage after the fact: a node
//     that answers nothing cannot be asked to hold anything, so this device can
//     never become a place where strangers park data or fetch files. There is
//     no file-transfer code here of any kind; what travels is an address, a
//     port, and a 20-byte id.
//
//  2. DISCOVERED ADDRESSES ARE DIAL TARGETS, NEVER POOL ENTRIES. The DHT tells
//     us where to knock. A node earns a place in the pool by being connected to
//     and interrogated. Writing these straight into the pool is what produced
//     phantom entries that outlived the peers they claimed to represent.
//
// No third-party package is used. This is dart:io and dart:convert plus the
// sha1 already in the project — deliberately, because a dependency pulled into
// a privacy app is a dependency that can be compromised on our behalf.
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

// ───────────────────────────────────────────────────────────────────────────
// Bencode — the wire format the DHT speaks.
//
// Strings are byte strings, NOT text. Decoding them as UTF-8 corrupts the
// binary fields (node ids, compact addresses, tokens), so they stay as
// List<int> and only the caller decides what is text.
// ───────────────────────────────────────────────────────────────────────────
class _Bencode {
  static List<int> encode(Object? v) {
    final out = <int>[];
    _enc(v, out);
    return out;
  }

  static void _enc(Object? v, List<int> out) {
    if (v is int) {
      out.addAll('i${v}e'.codeUnits);
    } else if (v is List<int>) {
      out..addAll('${v.length}:'.codeUnits)..addAll(v);
    } else if (v is String) {
      final b = v.codeUnits;
      out..addAll('${b.length}:'.codeUnits)..addAll(b);
    } else if (v is List) {
      out.add(0x6C); // 'l'
      for (final e in v) {
        _enc(e, out);
      }
      out.add(0x65); // 'e'
    } else if (v is Map) {
      out.add(0x64); // 'd'
      // Bencode requires keys in lexicographic order.
      final keys = v.keys.map((k) => k.toString()).toList()..sort();
      for (final k in keys) {
        _enc(k, out);
        _enc(v[k], out);
      }
      out.add(0x65); // 'e'
    } else {
      throw ArgumentError('bencode: unsupported ${v.runtimeType}');
    }
  }

  /// Returns int, List<int> (byte string), List, or Map<String, dynamic>.
  /// Null on anything malformed — a hostile or truncated packet must not throw
  /// into the receive loop.
  static Object? decode(List<int> data) {
    try {
      final r = _dec(data, 0);
      return r?.value;
    } catch (_) {
      return null;
    }
  }

  static _Dec? _dec(List<int> d, int i) {
    if (i >= d.length) return null;
    final c = d[i];
    if (c == 0x69) {
      // i<digits>e
      final e = d.indexOf(0x65, i);
      if (e < 0) return null;
      return _Dec(int.parse(String.fromCharCodes(d.sublist(i + 1, e))), e + 1);
    }
    if (c == 0x6C) {
      // list
      final list = <Object?>[];
      var p = i + 1;
      while (p < d.length && d[p] != 0x65) {
        final r = _dec(d, p);
        if (r == null) return null;
        list.add(r.value);
        p = r.next;
      }
      return _Dec(list, p + 1);
    }
    if (c == 0x64) {
      // dict
      final map = <String, dynamic>{};
      var p = i + 1;
      while (p < d.length && d[p] != 0x65) {
        final k = _dec(d, p);
        if (k == null || k.value is! List<int>) return null;
        final v = _dec(d, k.next);
        if (v == null) return null;
        map[String.fromCharCodes(k.value as List<int>)] = v.value;
        p = v.next;
      }
      return _Dec(map, p + 1);
    }
    // byte string: <len>:<bytes>
    final colon = d.indexOf(0x3A, i);
    if (colon < 0) return null;
    final len = int.parse(String.fromCharCodes(d.sublist(i, colon)));
    final start = colon + 1;
    if (start + len > d.length) return null;
    return _Dec(d.sublist(start, start + len), start + len);
  }
}

class _Dec {
  final Object? value;
  final int next;
  _Dec(this.value, this.next);
}

// ───────────────────────────────────────────────────────────────────────────
// A DHT contact: 20-byte id plus an address.
// ───────────────────────────────────────────────────────────────────────────
class _Contact {
  final Uint8List id;
  final InternetAddress address;
  final int port;
  _Contact(this.id, this.address, this.port);

  String get key => '${address.address}:$port';
}

/// Peer discovery over the public BitTorrent Mainline DHT.
///
/// Usage is deliberately narrow:
///   * [lookup]   — any client may ask where SOV nodes are.
///   * [announce] — ONLY a device actually serving as a full node should call
///                  this. A phone that cannot accept connections must never
///                  advertise itself as somewhere to connect to.
class DhtDiscovery {
  DhtDiscovery._();

  /// The constant every SOV build hashes to reach the same rendezvous point.
  /// Nothing is registered with anyone: every client computes this
  /// independently and arrives at the same 20 bytes.
  static const String networkId = 'sov-network-mainnet-v1';

  static final Uint8List infohash =
      Uint8List.fromList(sha1.convert(networkId.codeUnits).bytes);

  /// Long-running public DHT routers. These are an entry point only — once a
  /// client has spoken to any DHT node it learns others, and the routers stop
  /// mattering. They are not SOV infrastructure and learn nothing about SOV;
  /// to them this is one more client asking about one more infohash.
  static const List<String> _routers = [
    'router.bittorrent.com:6881',
    'dht.transmissionbt.com:6881',
    'router.utorrent.com:6881',
    'dht.libtorrent.org:25401',
  ];

  static final Random _rng = Random.secure();

  /// A fresh identity every run. A stable id would make this device trackable
  /// across sessions by anyone watching the DHT — precisely the correlation
  /// this network exists to avoid. Routing quality is irrelevant to us because
  /// we are a transient client, not a table member.
  static Uint8List _newNodeId() =>
      Uint8List.fromList(List<int>.generate(20, (_) => _rng.nextInt(256)));

  /// Inbound queries seen and ignored. Exposed so the claim "this device serves
  /// nothing" is a measurement rather than an assertion.
  static int inboundQueriesIgnored = 0;

  /// XOR distance, compared big-endian. The DHT is organised by closeness to a
  /// target, so a lookup walks toward the infohash one hop at a time.
  static int _closer(Uint8List a, Uint8List b, Uint8List target) {
    for (var i = 0; i < 20; i++) {
      final da = a[i] ^ target[i];
      final db = b[i] ^ target[i];
      if (da != db) return da - db;
    }
    return 0;
  }

  static List<_Contact> _parseCompactNodes(List<int> raw) {
    final out = <_Contact>[];
    for (var i = 0; i + 26 <= raw.length; i += 26) {
      final id = Uint8List.fromList(raw.sublist(i, i + 20));
      final ip = raw.sublist(i + 20, i + 24);
      final port = (raw[i + 24] << 8) | raw[i + 25];
      if (port == 0) continue;
      out.add(_Contact(
        id,
        InternetAddress('${ip[0]}.${ip[1]}.${ip[2]}.${ip[3]}'),
        port,
      ));
    }
    return out;
  }

  static String? _parseCompactPeer(List<int> raw) {
    if (raw.length != 6) return null;
    final port = (raw[4] << 8) | raw[5];
    if (port == 0) return null;
    return '${raw[0]}.${raw[1]}.${raw[2]}.${raw[3]}:$port';
  }

  /// Ask the DHT which addresses are serving SOV.
  ///
  /// Returns `host:port` strings. These are DIAL TARGETS: somewhere to try
  /// connecting. They are not nodes, are not trusted, and must not be written
  /// into the pool — a node joins the pool by being reached and interrogated,
  /// and anything found here still has to pass every normal check.
  ///
  /// Never throws. A device with UDP blocked, no network, or a hostile middlebox
  /// gets an empty list and the caller falls back to the other discovery paths.
  /// The port a SOV node serves its peer mesh on, and therefore the port it
  /// announces. It doubles as the first filter on DHT results — see [lookup].
  static const int meshPort = 7771;

  static Future<List<String>> lookup({
    Duration timeout = const Duration(seconds: 20),
    int wantPeers = 10,
    bool sovOnly = true,
  }) async {
    final raw = await _run(
        timeout: timeout, wantPeers: wantPeers, announcePort: null,
        // Return the instant a SOV node (:meshPort) is found — an obscure
        // infohash with one genesis never reaches wantPeers, so waiting for the
        // full timeout made discovery too slow and enrolment timed out first.
        stopOnMeshPeers: sovOnly ? 1 : 0);
    if (!sovOnly) return raw;

    // ── Filter 1: the announced port ────────────────────────────────────────
    // Anyone can announce on an infohash, and some do — DHT crawlers and
    // scrapers announce across many infohashes to map the network. A real run
    // returned three SOV nodes on :7771 alongside peers on :24619, :6881,
    // :31890 and :23326, none of which were SOV.
    //
    // A SOV node always announces the mesh port. Everything else is noise, and
    // dropping it here costs nothing — no connection is attempted, no packet is
    // sent, and the caller never wastes a round-trip proving what the port
    // already said. What survives this is still only a DIAL TARGET; being on
    // the right port is a hint, not proof, and the caller must still verify.
    final kept = raw.where((t) {
      final parts = t.split(':');
      return parts.length == 2 && int.tryParse(parts[1]) == meshPort;
    }).toList();

    debugPrint('[DHT] ${raw.length} announced, ${kept.length} on the SOV mesh '
        'port — ${raw.length - kept.length} discarded before dialling');
    return kept;
  }

  /// Publish that this device is serving SOV on [port], and return whatever
  /// peers were found on the way.
  ///
  /// ONLY for a device genuinely accepting connections as a full node. The
  /// announce is what makes a machine findable when every mirror is gone, so a
  /// Windows or Linux operator's node stays reachable to a brand-new client
  /// even if nothing else about SOV is still standing.
  static Future<List<String>> announce(
    int port, {
    Duration timeout = const Duration(seconds: 25),
  }) async {
    return _run(timeout: timeout, wantPeers: 20, announcePort: port);
  }

  static Future<List<String>> _run({
    required Duration timeout,
    required int wantPeers,
    required int? announcePort,
    int stopOnMeshPeers = 0,
  }) async {
    RawDatagramSocket? sock;
    final peers = <String>{};
    var meshPeerCount = 0;
    try {
      sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    } catch (e) {
      debugPrint('[DHT] cannot open UDP socket ($e) — other discovery paths still apply');
      return [];
    }

    final nodeId = _newNodeId();
    final seen = <String>{};           // contacts already queried
    final pending = <_Contact>[];      // still to query, closest first
    final tokens = <String, List<int>>{};  // contact key -> announce token
    final tokenContacts = <String, _Contact>{};
    var txCounter = 0;
    final done = Completer<void>();

    Uint8List nextTx() {
      txCounter = (txCounter + 1) & 0xFFFF;
      return Uint8List.fromList([(txCounter >> 8) & 0xFF, txCounter & 0xFF]);
    }

    void send(Map<String, dynamic> msg, InternetAddress addr, int port) {
      try {
        sock!.send(_Bencode.encode(msg), addr, port);
      } catch (_) {
        // A single unsendable packet is not a failure of discovery.
      }
    }

    void sendGetPeers(_Contact c) {
      send({
        't': nextTx(),
        'y': 'q',
        'q': 'get_peers',
        'a': {'id': nodeId, 'info_hash': infohash},
      }, c.address, c.port);
    }

    // ── Receive loop ────────────────────────────────────────────────────────
    final sub = sock.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = sock!.receive();
      if (dg == null) return;

      final msg = _Bencode.decode(dg.data);
      if (msg is! Map) return;

      // We are a client. Anything asking us to DO something is counted and
      // dropped — never answered. This is what keeps the device from ever
      // holding or serving other people's data.
      final y = msg['y'];
      final yStr = y is List<int> ? String.fromCharCodes(y) : '';
      if (yStr == 'q') {
        inboundQueriesIgnored++;
        return;
      }
      if (yStr != 'r') return; // errors and anything unrecognised: ignore

      final r = msg['r'];
      if (r is! Map) return;

      // Peers serving our infohash — the thing we actually came for.
      final values = r['values'];
      if (values is List) {
        for (final v in values) {
          if (v is List<int>) {
            final p = _parseCompactPeer(v);
            if (p != null && peers.add(p) && p.endsWith(':$meshPort')) {
              meshPeerCount++;
            }
          }
        }
      }

      // A token lets us announce to this contact later.
      final tok = r['token'];
      final rid = r['id'];
      if (tok is List<int> && rid is List<int> && rid.length == 20) {
        final c = _Contact(
            Uint8List.fromList(rid), dg.address, dg.port);
        tokens[c.key] = tok;
        tokenContacts[c.key] = c;
      }

      // Closer contacts to continue the walk toward the infohash.
      final nodes = r['nodes'];
      if (nodes is List<int>) {
        for (final c in _parseCompactNodes(nodes)) {
          if (seen.contains(c.key)) continue;
          pending.add(c);
        }
        pending.sort((a, b) => _closer(a.id, b.id, infohash));
      }

      if (announcePort == null &&
          (peers.length >= wantPeers ||
           (stopOnMeshPeers > 0 && meshPeerCount >= stopOnMeshPeers))) {
        if (!done.isCompleted) done.complete();
      }
    }, onError: (_) {});

    // ── Seed the walk from the public routers ───────────────────────────────
    for (final r in _routers) {
      final parts = r.split(':');
      try {
        final addrs = await InternetAddress.lookup(parts[0])
            .timeout(const Duration(seconds: 5), onTimeout: () => const []);
        for (final a in addrs.where((a) => a.type == InternetAddressType.IPv4)) {
          send({
            't': nextTx(),
            'y': 'q',
            'q': 'get_peers',
            'a': {'id': nodeId, 'info_hash': infohash},
          }, a, int.parse(parts[1]));
          break; // one address per router is enough
        }
      } catch (_) {
        // A dead router is expected and harmless; the others carry the lookup.
      }
    }

    // ── Walk toward the infohash until we run dry or time out ───────────────
    final deadline = DateTime.now().add(timeout);
    final ticker = Timer.periodic(const Duration(milliseconds: 250), (t) {
      if (DateTime.now().isAfter(deadline)) {
        if (!done.isCompleted) done.complete();
        return;
      }
      // Query a few of the closest unvisited contacts each tick.
      var sent = 0;
      while (pending.isNotEmpty && sent < 6) {
        final c = pending.removeAt(0);
        if (!seen.add(c.key)) continue;
        sendGetPeers(c);
        sent++;
      }
    });

    await done.future;
    ticker.cancel();

    // ── Announce, if this device is genuinely serving ───────────────────────
    if (announcePort != null && tokens.isNotEmpty) {
      // Announce to the contacts closest to the infohash — those are the ones
      // a future lookup will reach first.
      final targets = tokenContacts.values.toList()
        ..sort((a, b) => _closer(a.id, b.id, infohash));
      var count = 0;
      for (final c in targets) {
        final tok = tokens[c.key];
        if (tok == null) continue;
        send({
          't': nextTx(),
          'y': 'q',
          'q': 'announce_peer',
          'a': {
            'id': nodeId,
            'info_hash': infohash,
            'port': announcePort,
            'token': tok,
            'implied_port': 0,
          },
        }, c.address, c.port);
        if (++count >= 8) break;
      }
      // Give the announces a moment to leave before the socket closes.
      await Future.delayed(const Duration(milliseconds: 600));
      debugPrint('[DHT] announced port $announcePort to $count contact(s)');
    }

    await sub.cancel();
    sock.close();

    final found = peers.toList();
    debugPrint('[DHT] lookup finished — ${found.length} dial target(s), '
        '$inboundQueriesIgnored inbound quer(ies) ignored');
    return found;
  }
}
