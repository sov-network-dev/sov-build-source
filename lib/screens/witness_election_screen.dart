// Witness signer election — the screen where citizens take the signing power.
//
// WHY THIS SCREEN EXISTS. Today one key signs every SOV release, and the manifest
// says so: {"model":"witness-signer-threshold","threshold":1}. Threshold 1 means a
// single holder is the whole quorum. PI-37's answer is that the network elects its
// own signers and that key stops being consulted — and the node side of that has
// existed since June. What was missing was any way for a citizen to take part: the
// election could open and nobody could stand in it or vote.
//
// A signer set that citizens cannot elect is not a decentralised trust anchor, it
// is the same single key with extra steps.
//
// ── On live updates ─────────────────────────────────────────────────────────
// CLAUDE.md §3 makes push-subscribe mandatory for state that changes while a screen
// is open, and a tally does. This screen deliberately does NOT claim a live tally,
// and the reason is simply that no tally push exists to subscribe to: there is no
// witness equivalent of EXCHANGE_ORDER_UPDATE in the node. Registering a listener
// anyway would have looked like a live tally and shown a frozen one. So the numbers
// are refreshed on open, on pull-to-refresh, and immediately after any action you
// take, and the screen says plainly when it last looked.
//
// Two governance pushes were checked before deciding. POLL_COUNT_UPDATE has zero
// emitters anywhere in the node source — nothing sends it. GOVERNANCE_PARAM_ACTIVATED
// (op 'KE') was broken and is FIXED as part of this work — and it is worth being precise
// about what was wrong, because it was NOT an unused push: governance_screen.dart:111
// already subscribed to RelayConnector.govParamActivated to update the live param badge
// without a reload. The whole feature was built. It failed because 'KE' was registered
// in no codebook, so the node's _send resolved its name as `_opToType[op] || op` — the
// code became its own type, the app saw a non-null 'type', skipped _typeFromOp and
// matched nothing. Now registered in MSG_TYPE, LEGACY_TYPE_MAP, _typeFromOp and
// Appendix H, and the connector re-resolves any two-char 'type'.
// Neither push is a tally, so neither changes the decision above.
import 'package:flutter/material.dart';
import '../sov_node_sdk/relay_connector.dart';

const _cardBg = Color(0xFF0D1F3A);
const _teal   = Color(0xFF006B5E);

class WitnessElectionScreen extends StatefulWidget {
  final String sovereignId;
  const WitnessElectionScreen({super.key, required this.sovereignId});

  @override
  State<WitnessElectionScreen> createState() => _WitnessElectionScreenState();
}

class _WitnessElectionScreenState extends State<WitnessElectionScreen> {
  bool _loading = true;
  String? _error;
  DateTime? _lastLooked;

  int _phase = 1;
  int _threshold = 3;
  int _signerCount = 5;
  Map<String, dynamic>? _election;
  List<Map<String, dynamic>> _candidates = [];
  List<Map<String, dynamic>> _tally = [];
  List<Map<String, dynamic>> _seated = [];
  bool _youVoted = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final resp = await RelayConnector.sendAndWait(
        request: { 'type': 'WITNESS_ELECTION_STATE',
                   'sovereign_id': widget.sovereignId },
        responseType: 'WITNESS_ELECTION_STATE',
        timeout: const Duration(seconds: 10),
      );
      if (!mounted) return;
      if (resp == null || resp['success'] != true) {
        setState(() { _loading = false; _error = 'The node did not answer.'; });
        return;
      }
      setState(() {
        _phase       = (resp['phase'] as num?)?.toInt() ?? 1;
        _threshold   = (resp['threshold'] as num?)?.toInt() ?? 3;
        _signerCount = (resp['signer_count'] as num?)?.toInt() ?? 5;
        _election    = resp['election'] as Map<String, dynamic>?;
        _candidates  = _rows(resp['candidates']);
        _tally       = _rows(resp['tally']);
        _seated      = _rows(resp['seated']);
        _youVoted    = resp['you_voted'] == true;
        _loading     = false;
        _lastLooked  = DateTime.now();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = 'Could not reach a node.'; });
    }
  }

  List<Map<String, dynamic>> _rows(dynamic v) => (v is List)
      ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
      : <Map<String, dynamic>>[];

  int _votesFor(String id) {
    for (final t in _tally) {
      if (t['candidate_id'] == id) return (t['votes'] as num?)?.toInt() ?? 0;
    }
    return 0;
  }

  Future<void> _act(String type, Map<String, dynamic> extra, String responseType) async {
    final resp = await RelayConnector.sendAndWait(
      request: { 'type': type, 'sovereign_id': widget.sovereignId, ...extra },
      responseType: responseType,
      timeout: const Duration(seconds: 10),
    );
    if (!mounted) return;
    final ok = resp != null && resp['success'] == true;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      backgroundColor: _cardBg,
      content: Text(ok ? 'Done.' : _explain(resp?['error']?.toString())),
    ));
    await _load();   // the numbers you just changed, re-read rather than guessed
  }

  /// Turn a protocol reason into something a citizen can act on.
  String _explain(String? code) {
    switch (code) {
      case 'NO_OPEN_ELECTION':  return 'There is no election running right now.';
      case 'ALREADY_VOTED':     return 'You have already voted in this election.';
      case 'NOT_A_CANDIDATE':   return 'That citizen has not stood in this election.';
      case 'NOT_ENROLLED':      return 'Only an enrolled citizen can stand.';
      case 'ELECTION_CLOSED':   return 'This election has closed.';
      case 'NOT_AUTHENTICATED': return 'Reconnect and try again.';
      case null:                return 'That did not go through.';
      default:                  return code;
    }
  }

  bool get _youStood => _candidates.any((c) => c['candidate_id'] == widget.sovereignId);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF071427),
      appBar: AppBar(
        backgroundColor: _cardBg,
        title: const Text('Who signs the network'),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (_error != null) _card(Text(_error!, style: const TextStyle(color: Colors.orangeAccent))),
                  _phaseCard(),
                  const SizedBox(height: 12),
                  _electionCard(),
                  const SizedBox(height: 12),
                  _seatedCard(),
                  if (_lastLooked != null) Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(
                      'Last checked ${_lastLooked!.hour.toString().padLeft(2,'0')}:'
                      '${_lastLooked!.minute.toString().padLeft(2,'0')} — pull down to refresh.',
                      style: const TextStyle(color: Colors.white38, fontSize: 12)),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _card(Widget child) => Container(
    margin: const EdgeInsets.only(bottom: 4),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: _cardBg,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: Colors.white.withAlpha(10)),
    ),
    child: child,
  );

  Widget _phaseCard() => _card(Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(children: [
        Icon(_phase == 2 ? Icons.verified_user_rounded : Icons.key_rounded,
             color: _phase == 2 ? Colors.tealAccent : Colors.orangeAccent),
        const SizedBox(width: 10),
        Text(_phase == 2 ? 'The network signs for itself' : 'Still on the founding key',
             style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
      ]),
      const SizedBox(height: 10),
      Text(
        _phase == 2
          ? 'Releases now need $_threshold of the ${_seated.length} elected signers to agree. '
            'No single person can ship software to this network.'
          : 'Software releases are still signed by the founding key. When the network '
            'is large enough it elects $_signerCount signers of its own, any '
            '$_threshold of whom must agree — and the founding key stops counting. '
            'You vote on the thresholds in Governance.',
        style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.4)),
    ],
  ));

  Widget _electionCard() {
    final e = _election;
    if (e == null || e['status'] != 'open') {
      return _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('No election running',
          style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Text(
          e == null
            ? 'One opens by itself when the network reaches the size citizens have '
              'voted for. Nobody starts it by hand.'
            : 'The last one (${e['election_id']}) is ${e['status']}.',
          style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.4)),
      ]));
    }
    return _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Icon(Icons.how_to_vote_rounded, color: Colors.tealAccent),
        const SizedBox(width: 10),
        Expanded(child: Text('Election open — ${e['election_id']}',
          style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600))),
      ]),
      const SizedBox(height: 6),
      Text('Choosing $_signerCount signers. $_threshold of them must agree on any release.',
        style: const TextStyle(color: Colors.white70, fontSize: 13)),
      const SizedBox(height: 14),
      if (_candidates.isEmpty)
        const Text('Nobody has stood yet.', style: TextStyle(color: Colors.white54, fontSize: 13))
      else
        ..._candidates.map((c) {
          final id = (c['candidate_id'] ?? '').toString();
          final me = id == widget.sovereignId;
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(children: [
              Expanded(child: Text(me ? '$id  (you)' : id,
                style: TextStyle(color: me ? Colors.tealAccent : Colors.white70, fontSize: 13))),
              Text('${_votesFor(id)}', style: const TextStyle(color: Colors.white, fontSize: 13)),
              const SizedBox(width: 12),
              if (!_youVoted)
                TextButton(
                  style: TextButton.styleFrom(backgroundColor: _teal.withAlpha(60)),
                  onPressed: () => _act('WITNESS_VOTE', {'candidate_id': id}, 'WITNESS_VOTE'),
                  child: const Text('Vote', style: TextStyle(color: Colors.white)))
              else
                const Text('—', style: TextStyle(color: Colors.white24)),
            ]),
          );
        }),
      const SizedBox(height: 6),
      if (_youVoted)
        const Text('You have voted. One citizen, one vote.',
          style: TextStyle(color: Colors.tealAccent, fontSize: 12))
      else
        const Text('You have not voted yet.',
          style: TextStyle(color: Colors.white54, fontSize: 12)),
      const Divider(color: Colors.white12, height: 26),
      if (_youStood)
        const Text('You are standing in this election.',
          style: TextStyle(color: Colors.tealAccent, fontSize: 13))
      else
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            style: TextButton.styleFrom(backgroundColor: _teal.withAlpha(60)),
            icon: const Icon(Icons.person_add_alt_rounded, color: Colors.white, size: 18),
            label: const Text('Stand as a signer', style: TextStyle(color: Colors.white)),
            onPressed: () => _act('WITNESS_STAND', const {}, 'WITNESS_STAND'),
          ),
        ),
      const SizedBox(height: 6),
      const Text(
        'Standing only ever nominates you. Nobody can put another citizen forward, '
        'because a signer who never agreed to sign is not a signer.',
        style: TextStyle(color: Colors.white38, fontSize: 11, height: 1.4)),
    ]));
  }

  Widget _seatedCard() => _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    const Text('Signers right now',
      style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
    const SizedBox(height: 10),
    if (_seated.isEmpty)
      const Text('None seated. The founding key is still the trust anchor.',
        style: TextStyle(color: Colors.white54, fontSize: 13))
    else
      ..._seated.map((s) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text('${s['signer_id']}',
          style: const TextStyle(color: Colors.white70, fontSize: 13)))),
  ]));
}
