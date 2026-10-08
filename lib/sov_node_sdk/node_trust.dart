// node_trust.dart — which SOV nodes this app believes (v1.2.27, with node 1.4.92).
//
// A node list can reach the app from places anyone can write to: the public DHT, a mirror on someone
// else's host, a node the app happens to be connected to. Until 1.2.27 the app checked only the SHAPE
// of a list, and if nothing passed it dialled every DHT host anyway. Now a node is believed only if it
// proves itself:
//
//   1. its /relay-pool is signed, the signature verifies over the exact bytes (payload_json), and the
//      signing key hashes to the node id it claims; and
//   2. that key is TRUSTED: built into this app, learned earlier, or vouched for by the node's own
//      admission certificate — approvals signed by at least two nodes this app already trusts (one,
//      while it only knows one). A certificate checks OFFLINE, so a fresh install that can reach only
//      a brand-new node still recognises it, even if every built-in node is blocked or gone.
//
// One node vouching for others is NOT enough (a compromised node could list anything): every listed
// address is fetched and must prove itself the same way. Nothing here is an address — only public keys,
// which every node already publishes.
import 'dart:convert';

import 'package:crypto/crypto.dart' as pc;
import 'package:cryptography/cryptography.dart' as cg;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NodeTrust {
  /// Public keys of the nodes running when this build was made. Refreshed every app release.
  static const Set<String> builtIn = {
    'a46b4573b904ec6d836016c26d12a1b1129ff633bd67b11af6c2e6241673397a',
    '51471e3c65ce542ecc54dc9698748cc51190a48f2ed48c9398c1d8318ebf7ea3',
    '77fc62510e6bc4f0dce761ef7f4aed064c1c4dbc2dc892e62b3f405ba51b2382',
  };

  static const _prefsKey = 'sov_trusted_node_keys_v1';
  static const _maxLearned = 500;
  static final Set<String> _learned = {};
  static bool _loaded = false;
  static final _hex64 = RegExp(r'^[0-9a-f]{64}$');
  static final _hex128 = RegExp(r'^[0-9a-f]{128}$');

  static Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      _learned.addAll((p.getStringList(_prefsKey) ?? const []).where(_hex64.hasMatch));
    } catch (_) {}
  }

  static Future<void> _learn(String pub) async {
    if (_anchors.contains(pub) || !_learned.add(pub)) return;
    try {
      final p = await SharedPreferences.getInstance();
      final list = _learned.toList();
      await p.setStringList(_prefsKey, list.length > _maxLearned ? list.sublist(list.length - _maxLearned) : list);
    } catch (_) {}
  }

  static Set<String> _anchors = builtIn;
  static bool _trusted(String pub) => _anchors.contains(pub) || _learned.contains(pub);
  static int get _trustedCount => _anchors.length + _learned.length;

  static String _sha256Hex(List<int> b) => pc.sha256.convert(b).toString();

  static Uint8List _unhex(String h) {
    final out = Uint8List(h.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  static Future<bool> _verify(List<int> body, String sigHex, String pubHex) async {
    if (!_hex128.hasMatch(sigHex) || !_hex64.hasMatch(pubHex)) return false;
    try {
      return await cg.Ed25519().verify(body,
          signature: cg.Signature(_unhex(sigHex),
              publicKey: cg.SimplePublicKey(_unhex(pubHex), type: cg.KeyPairType.ed25519)));
    } catch (_) {
      return false;
    }
  }

  /// The exact bytes an approver signs — must match protocol/operator_admission.js approvalBody().
  static List<int> _approvalBody(Map a) => utf8.encode([
        'SOV-OPAPPROVAL-v1', '${a['node_id']}', '${a['operator_id'] ?? ''}'.trim().toUpperCase(),
        '${a['source_root'] ?? ''}', '${a['signup_ts']}', '${a['approver']}', '${a['ts']}',
      ].join('|'));

  /// How many DISTINCT trusted nodes validly approved [nodeId] in [cert].
  static Future<int> _validApprovals(dynamic cert, String nodeId) async {
    if (cert is! List || cert.isEmpty || cert.length > 64) return 0;
    final first = cert.first;
    if (first is! Map) return 0;
    final seen = <String>{};
    for (final a in cert) {
      if (a is! Map) continue;
      final approver = '${a['approver'] ?? ''}', pub = '${a['approver_pub'] ?? ''}';
      if (a['node_id'] != nodeId || approver == nodeId || seen.contains(approver)) continue;
      // Every approval must be for the same signup as the first.
      if ('${a['operator_id']}'.toUpperCase() != '${first['operator_id']}'.toUpperCase() ||
          '${a['source_root']}' != '${first['source_root']}' || '${a['signup_ts']}' != '${first['signup_ts']}') {
        continue;
      }
      if (!_hex64.hasMatch(pub) || !_trusted(pub) || _sha256Hex(_unhex(pub)) != approver) continue;
      if (await _verify(_approvalBody(a), '${a['sig'] ?? ''}', pub)) seen.add(approver);
    }
    return seen.length;
  }

  /// Verifies a /relay-pool envelope. Returns the signer's public key if the list is genuine AND the
  /// signer is trusted (possibly just now, by its certificate); otherwise null.
  static Future<String?> verifyEnvelope(Map<String, dynamic> e) async {
    await _load();
    final pub = '${e['signer_pubkey'] ?? ''}'.toLowerCase();
    final signer = '${e['signer'] ?? ''}'.toLowerCase();
    final body = e['payload_json'];
    if (!_hex64.hasMatch(pub) || body is! String) return null;
    if (_sha256Hex(_unhex(pub)) != signer) return null;
    if (!await _verify(utf8.encode(body), '${e['sig'] ?? ''}'.toLowerCase(), pub)) return null;
    if (_trusted(pub)) return pub;
    final need = _trustedCount >= 2 ? 2 : 1;
    if (await _validApprovals(e['signer_cert'], signer) >= need) {
      await _learn(pub);
      debugPrint('[NodeTrust] learned node ${signer.substring(0, 12)} from its admission certificate');
      return pub;
    }
    return null;
  }

  @visibleForTesting
  static void resetForTest({Set<String>? anchors}) {
    _learned.clear();
    _loaded = true;
    _anchors = anchors ?? builtIn;
  }

  @visibleForTesting
  static bool isLearned(String pub) => _learned.contains(pub);
}
