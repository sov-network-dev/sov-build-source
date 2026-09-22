// lib/screens/governance_screen.dart
// ─────────────────────────────────────────────────────────────────────────────
// Network Governance — 3 tabs:
//   Justice Protocol   — My Cases, Open Disputes, File Dispute (with images)
//   Network Constitution — SOV Value + protocol items with Propose Vote
//   Votes              — Active / Completed filter toggle
// ─────────────────────────────────────────────────────────────────────────────
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../sov_node_sdk/relay_connector.dart';
import '../sov_node_sdk/sov_currency.dart';
import '../sov_node_sdk/draft_keys.dart';
import '../sov_node_sdk/contacts_db.dart';

// ─── Colour constants ─────────────────────────────────────────────────────────
const _navy   = Color(0xFF0A1628);
const _gold   = Color(0xFFB8960C);
const _goldBr = Color(0xFFD4AF37);
const _cardBg = Color(0xFF0D1F3A);
const _teal   = Color(0xFF006B5E);

// ─────────────────────────────────────────────────────────────────────────────

class GovernanceScreen extends StatefulWidget {
  final String sovereignId;
  const GovernanceScreen({super.key, required this.sovereignId});

  @override
  State<GovernanceScreen> createState() => _GovernanceScreenState();
}

class _GovernanceScreenState extends State<GovernanceScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;

  // ── Polls (all loaded together, filtered by toggle) ───────────────────────
  List<Map<String, dynamic>> _activePolls    = [];
  List<Map<String, dynamic>> _completedPolls = [];
  bool  _loadingPolls  = true;
  bool  _showCompleted = false;   // Votes tab toggle
  StreamSubscription<Map<String,dynamic>>? _pollCountSub;
  StreamSubscription<Map<String,dynamic>>? _pollClosedSub;
  StreamSubscription<Map<String,dynamic>>? _govParamSub;

  // ── SOV Value voting ──────────────────────────────────────────────────────
  Map<String, dynamic>? _sovValueStatus;
  bool _loadingSovValue = false;
  final TextEditingController _sovValueCtrl = TextEditingController();

  // ── Justice Protocol ──────────────────────────────────────────────────────
  List<Map<String, dynamic>> _myCases       = [];
  List<Map<String, dynamic>> _openDisputes  = [];
  bool  _loadingJustice   = true;
  bool  _loadingDisputes  = true;
  // Pending jury duty invitations pushed by relay in real time
  final List<Map<String, dynamic>> _pendingInvites = [];
  StreamSubscription<Map<String,dynamic>>? _jurorInviteSub;
  StreamSubscription<Map<String,dynamic>>? _caseUpdateSub;
  bool _respondingToInvite = false;  // loading guard for accept/decline

  // Palm name cache for Justice participants (plaintiff / defendant / jurors).
  final Map<String, String> _justicePalmNames = {};

  // ── File Dispute form ──────────────────────────────────────────────────────
  final TextEditingController _txIdCtrl   = TextEditingController();
  final TextEditingController _descCtrl   = TextEditingController();
  final TextEditingController _hashCtrl   = TextEditingController();
  final List<Uint8List>       _evidenceImages = [];
  bool   _submittingDispute = false;
  String? _disputeResult;   // success or error message shown inline

  // ── Constitution protocol status ──────────────────────────────────────────
  // tag → true if a vote-in-progress poll exists for that protocol
  Map<String, bool>   _protocolVoteActive = {};
  // param_key → current value from sov_governance_params
  Map<String, String> _govParams          = {};
  // Snapshot of what the live network had voted active at release build time
  // (assets/governance_defaults.json). Seeds the UI before the live fetch so a
  // fresh install shows the correct protocol states immediately; live overrides it.
  Map<String, String> _bundledGovDefaults  = {};
  bool _proposingVote = false;   // loading guard for POLL_CREATE

  // ── Petitions ─────────────────────────────────────────────────────────────
  List<Map<String, dynamic>> _petitions       = [];
  bool   _loadingPetitions  = false;
  int    _petitionEnrolled  = 1;
  bool   _submittingPetition = false;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 4, vsync: this);
    _tabs.addListener(_onTabChange);
    _seedBundledGovDefaults(); // show voted-active protocols on first paint, pre-connect
    _loadJusticeCases();
    _loadOpenDisputes();
    _loadPolls();
    _loadSovValueStatus();
    _loadPetitions();
    _loadDisputeDrafts();
    // Live vote-count updates — relay pushes POLL_COUNT_UPDATE after each vote
    _pollCountSub = RelayConnector.pollCountUpdates.listen(_onPollCountUpdate);
    // Poll auto-close — relay pushes POLL_CLOSED when epoch timer fires
    _pollClosedSub = RelayConnector.pollClosed.listen(_onPollClosed);
    // Governance param activated — update badge immediately without reload
    _govParamSub = RelayConnector.govParamActivated.listen((msg) {
      if (!mounted) return;
      final key = msg['param_key'] as String?;
      final val = (msg['new_value'] ?? msg['param_value'] ?? '').toString();
      if (key != null) setState(() => _govParams[key] = val);
    });
    // [JUSTICE-COUNCIL] Jury duty invitation pushed by relay when this citizen
    // is randomly selected as a juror. Show Accept / Decline UI at top of tab.
    _jurorInviteSub = RelayConnector.jurorInviteStream.listen((msg) {
      if (!mounted) return;
      final caseId = msg['case_id'] as String?;
      if (caseId == null) return;
      // Deduplicate — only add if not already in list
      if (_pendingInvites.any((i) => i['case_id'] == caseId)) return;
      setState(() => _pendingInvites.add(msg));
      // Prefetch palm names for plaintiff/defendant in this invite.
      _prefetchJusticeNames([msg]);
    });
    // [JUSTICE-COUNCIL] Case state changes — verdict, panel expanded, juror accepted
    _caseUpdateSub = RelayConnector.justiceCaseUpdateStream.listen((msg) {
      if (!mounted) return;
      final event  = msg['event']   as String?;
      final caseId = msg['case_id'] as String?;
      if (event == 'VERDICT' && caseId != null) {
        // Full reload so verdict renders with correct styling
        _loadJusticeCases();
        // Remove any pending invite for this case (case is now closed)
        setState(() => _pendingInvites.removeWhere((i) => i['case_id'] == caseId));
      } else if (event == 'PANEL_EXPANDED' || event == 'JUROR_ACCEPTED') {
        _loadJusticeCases();
      }
    });
  }

  void _onPollCountUpdate(Map<String,dynamic> msg) {
    final pollId    = msg['poll_id'] as String?;
    final tally     = msg['tally'];
    final total     = msg['total_votes'];
    if (pollId == null || !mounted) return;
    setState(() {
      final idx = _activePolls.indexWhere((p) => p['poll_id'] == pollId);
      if (idx != -1) {
        _activePolls[idx] = Map<String,dynamic>.from(_activePolls[idx])
          ..['tally']       = tally
          ..['total_votes'] = total;
      }
    });
  }

  void _onPollClosed(Map<String,dynamic> msg) {
    if (!mounted) return;
    // Full reload so closed poll moves to completed list with final result
    _loadPolls();
  }

  @override
  void dispose() {
    _pollCountSub?.cancel();
    _pollClosedSub?.cancel();
    _govParamSub?.cancel();
    _jurorInviteSub?.cancel();
    _caseUpdateSub?.cancel();
    _tabs.removeListener(_onTabChange);
    _tabs.dispose();
    _sovValueCtrl.dispose();
    _txIdCtrl.dispose();
    _descCtrl.dispose();
    _hashCtrl.dispose();
    super.dispose();
  }

  void _onTabChange() {
    if (!_tabs.indexIsChanging) return;
    // Reload justice when tab 0 is selected
    if (_tabs.index == 0 && _myCases.isEmpty && !_loadingJustice) {
      _loadJusticeCases();
    }
    // Always refresh polls when the Votes tab (index 2) is selected so a poll
    // just created from the Constitution tab shows up immediately.
    if (_tabs.index == 2) {
      _loadPolls();
    }
  }

  // ── Draft persistence ─────────────────────────────────────────────────────

  Future<void> _loadDisputeDrafts() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      _txIdCtrl.text  = prefs.getString(DraftKeys.justiceDefendantId)  ?? '';
      _descCtrl.text  = prefs.getString(DraftKeys.justiceEvidenceHash) ?? '';
      _hashCtrl.text  = prefs.getString(DraftKeys.justiceClaimAmount)  ?? '';
    }
  }

  Future<void> _saveDisputeDrafts() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(DraftKeys.justiceDefendantId,  _txIdCtrl.text);
    await prefs.setString(DraftKeys.justiceEvidenceHash, _descCtrl.text);
    await prefs.setString(DraftKeys.justiceClaimAmount,  _hashCtrl.text);
  }

  Future<void> _clearDisputeDrafts() async {
    final prefs = await SharedPreferences.getInstance();
    for (final k in DraftKeys.justiceAll) { await prefs.remove(k); }
    _txIdCtrl.clear();
    _descCtrl.clear();
    _hashCtrl.clear();
    if (mounted) setState(() { _evidenceImages.clear(); _disputeResult = null; });
  }

  // ── Contact picker for defendant field ───────────────────────────────────

  Future<void> _pickDefendantFromContacts() async {
    final contacts = await ContactsDb.getContacts();
    if (!mounted) return;
    if (contacts.isEmpty) {
      _snack('No contacts yet — add contacts in SOV Speak first');
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _cardBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        // Local search state inside the bottom sheet
        final searchCtrl = TextEditingController();
        var filtered = List<Contact>.from(contacts);
        return StatefulBuilder(builder: (ctx2, setSheet) {
          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.6,
            maxChildSize: 0.9,
            minChildSize: 0.4,
            builder: (_, scrollCtrl) => Column(children: [
              const SizedBox(height: 8),
              Container(
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 12),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text('Select Defendant',
                    style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 16)),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  controller: searchCtrl,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Search contacts…',
                    hintStyle: const TextStyle(color: Colors.white38),
                    prefixIcon: const Icon(Icons.search, color: Colors.white38, size: 18),
                    filled: true,
                    fillColor: Colors.white.withAlpha(8),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: Colors.white.withAlpha(20)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: Colors.white.withAlpha(20)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: _gold, width: 1.2),
                    ),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                  ),
                  onChanged: (v) => setSheet(() {
                    final q = v.toLowerCase();
                    filtered = contacts.where((c) {
                      return c.nickname.toLowerCase().contains(q) ||
                          c.sovereignId.toLowerCase().contains(q);
                    }).toList();
                  }),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ListView.builder(
                  controller: scrollCtrl,
                  itemCount: filtered.length,
                  itemBuilder: (_, i) {
                    final c = filtered[i];
                    final name = c.nickname.isNotEmpty
                        ? c.nickname
                        : _shortId(c.sovereignId);
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: _teal.withAlpha(40),
                        radius: 20,
                        child: Text(
                          name.isNotEmpty ? name[0].toUpperCase() : '?',
                          style: const TextStyle(
                              color: _gold, fontWeight: FontWeight.bold),
                        ),
                      ),
                      title: Text(name,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w600)),
                      subtitle: Text(
                        _shortId(c.sovereignId),
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 11,
                            fontFamily: 'monospace'),
                      ),
                      onTap: () {
                        _txIdCtrl.text = c.sovereignId;
                        _saveDisputeDrafts();
                        Navigator.pop(ctx);
                      },
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
            ]),
          );
        });
      },
    );
  }

  // ── Justice Council — Jury duty response ─────────────────────────────────

  Future<void> _respondJuryDuty(Map<String,dynamic> invite, String response) async {
    if (_respondingToInvite) return;
    setState(() => _respondingToInvite = true);
    try {
      final resp = await RelayConnector.respondToJuryDuty(
        sovereignId: widget.sovereignId,
        caseId:      invite['case_id'] as String,
        response:    response,
      );
      if (!mounted) return;
      if (resp['success'] == true) {
        setState(() => _pendingInvites.removeWhere(
              (i) => i['case_id'] == invite['case_id']));
        _snack(response == 'accept'
            ? 'Jury duty accepted — you are now a juror.'
            : 'Jury duty declined — a replacement will be selected.');
        await _loadJusticeCases();
      } else {
        _snack(resp['error'] as String? ?? 'Could not respond — try again');
      }
    } catch (_) {
      if (mounted) _snack('Could not reach relay — try again');
    } finally {
      if (mounted) setState(() => _respondingToInvite = false);
    }
  }

  Future<void> _expandPanel(String caseId) async {
    try {
      final resp = await RelayConnector.expandJuryPanel(
        sovereignId: widget.sovereignId,
        caseId:      caseId,
      );
      if (!mounted) return;
      if (resp['success'] == true) {
        final total = resp['total_jurors'];
        final max   = resp['max_jurors'];
        _snack('Panel expanded — $total of $max jurors now selected.');
        await _loadJusticeCases();
      } else {
        _snack(resp['error'] as String? ?? 'Could not expand panel');
      }
    } catch (_) {
      if (mounted) _snack('Could not reach relay — try again');
    }
  }

  // ── Justice loaders ───────────────────────────────────────────────────────

  Future<void> _loadJusticeCases() async {
    if (!mounted) return;
    setState(() => _loadingJustice = true);
    try {
      final resp = await RelayConnector.getJusticeMyCases(widget.sovereignId);
      if (!mounted) return;
      final cases = List<Map<String, dynamic>>.from(resp['cases'] ?? []);
      setState(() { _myCases = cases; _loadingJustice = false; });
      // Prefetch palm names for all participants.
      _prefetchJusticeNames(cases);
    } catch (_) {
      if (mounted) setState(() => _loadingJustice = false);
    }
  }

  Future<void> _loadOpenDisputes() async {
    if (!mounted) return;
    setState(() => _loadingDisputes = true);
    try {
      final resp = await RelayConnector.listOpenDisputes(widget.sovereignId);
      if (!mounted) return;
      final disputes = List<Map<String, dynamic>>.from(resp['disputes'] ?? []);
      setState(() { _openDisputes = disputes; _loadingDisputes = false; });
      // Prefetch palm names for all participants.
      _prefetchJusticeNames(disputes);
    } catch (_) {
      if (mounted) setState(() => _loadingDisputes = false);
    }
  }

  /// Prefetch palm names for all sovereign IDs found inside [items].
  /// Looks for 'plaintiff_id', 'defendant_id', 'from_id', 'to_id'.
  void _prefetchJusticeNames(List<Map<String, dynamic>> items) {
    final ids = <String>{};
    for (final item in items) {
      for (final key in ['plaintiff_id', 'defendant_id', 'from_id', 'to_id']) {
        final v = item[key] as String?;
        if (v != null && v.startsWith('SOV-')) ids.add(v);
      }
    }
    for (final id in ids) {
      RelayConnector.prefetchPalmName(id, onResolved: () {
        if (mounted) { setState(() {
          _justicePalmNames[id] = RelayConnector.cachedPalmNameFor(id);
        }); }
      });
    }
  }

  /// Best display name for a Justice participant: palm name or short ID.
  String _justiceName(String sovereignId) {
    final palm = _justicePalmNames[sovereignId] ??
        RelayConnector.cachedPalmNameFor(sovereignId);
    if (palm.isNotEmpty) return palm;
    return _shortId(sovereignId);
  }

  // ── Polls loader ──────────────────────────────────────────────────────────

  Future<void> _loadPolls() async {
    if (!mounted) return;
    setState(() => _loadingPolls = true);
    try {
      final activeResp = await RelayConnector.sendAndWait(
        request: { 'type': 'POLL_LIST', 'status': 'open',
                   'sovereign_id': widget.sovereignId },
        responseType: 'POLL_LIST_RESULT',
        timeout: const Duration(seconds: 10),
      );
      final completedResp = await RelayConnector.sendAndWait(
        request: { 'type': 'POLL_LIST', 'status': 'closed',
                   'sovereign_id': widget.sovereignId },
        responseType: 'POLL_LIST_RESULT',
        timeout: const Duration(seconds: 10),
      );
      // Fetch current governance params so Constitution tab can show ACTIVE badge.
      // GOV_PARAMS_ALL (op KA) is the citizen-gateway path; params is a map of
      // param_key -> string value. (GOVERNANCE_STATE_REQUEST is a node-to-node
      // peer-mesh message — citizens get no reply to it.)
      final govStateResp = await RelayConnector.sendAndWait(
        request: { 'type': 'GOV_PARAMS_ALL' },
        responseType: 'GOV_PARAMS_ALL',
        timeout: const Duration(seconds: 8),
      );
      if (!mounted) return;

      final active    = activeResp?['success']    == true
          ? List<Map<String, dynamic>>.from(activeResp!['polls'] ?? [])
          : <Map<String, dynamic>>[];
      final completed = completedResp?['success'] == true
          ? List<Map<String, dynamic>>.from(completedResp!['polls'] ?? [])
          : <Map<String, dynamic>>[];

      // Parse governance params (keyed by param_key). Start from the release
      // snapshot so any param the node doesn't return still shows its voted
      // default; live values overlay (and win) on top.
      final Map<String, String> govParams = Map<String, String>.from(_bundledGovDefaults);
      final gp = govStateResp?['params'];
      if (gp is Map) {
        gp.forEach((k, v) => govParams[k.toString()] = (v ?? '').toString());
      }

      // Check which constitution protocols have active polls
      final Map<String, bool> actv = {};
      for (final p in active) {
        final tag = (p['constitution_tag'] ?? '') as String;
        if (tag.isNotEmpty) actv[tag] = true;
      }

      setState(() {
        _activePolls         = active;
        _completedPolls      = completed;
        _govParams           = govParams;
        _protocolVoteActive  = Map.from(actv);
        _loadingPolls        = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingPolls = false);
    }
  }

  // Load the release governance snapshot (what the live network had voted active
  // when this build was cut) and show it immediately, before the live fetch. The
  // live GOVERNANCE_STATE always overrides this once connected, so it can never be
  // stale after connect — it just removes the "everything looks dormant" flash on
  // a fresh, not-yet-connected install.
  Future<void> _seedBundledGovDefaults() async {
    try {
      final raw = await rootBundle.loadString('assets/governance_defaults.json');
      final decoded = jsonDecode(raw);
      final params = decoded is Map ? decoded['params'] : null;
      if (params is Map) {
        final m = <String, String>{};
        params.forEach((k, v) => m[k.toString()] = (v ?? '').toString());
        _bundledGovDefaults = m;
        if (mounted) {
          setState(() {
            // Only fill keys not already known from a live push, so we never
            // clobber a fresher live value with the baked default.
            for (final e in m.entries) {
              _govParams.putIfAbsent(e.key, () => e.value);
            }
          });
        }
      }
    } catch (_) {/* asset missing or malformed — silently fall back to live-only */}
  }

  // ── SOV Value ─────────────────────────────────────────────────────────────

  // ── Petitions loader ─────────────────────────────────────────────────────

  Future<void> _loadPetitions() async {
    if (!mounted) return;
    setState(() => _loadingPetitions = true);
    try {
      final resp = await RelayConnector.sendAndWait(
        request: { 'type': 'PETITION_LIST' },
        responseType: 'PETITION_LIST_RESULT',
        timeout: const Duration(seconds: 10),
      );
      if (!mounted) return;
      setState(() {
        _petitions        = List<Map<String, dynamic>>.from(resp?['petitions'] ?? []);
        _petitionEnrolled = (resp?['enrolled'] as num?)?.toInt() ?? 1;
        _loadingPetitions = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingPetitions = false);
    }
  }

  Future<void> _signPetition(String petitionId) async {
    try {
      final resp = await RelayConnector.sendAndWait(
        request: { 'type': 'PETITION_SIGN', 'petition_id': petitionId },
        responseType: 'PETITION_SIGN_RESULT',
        timeout: const Duration(seconds: 10),
      );
      if (!mounted) return;
      if (resp?['success'] == true) {
        final count   = (resp!['signature_count'] as num?)?.toInt() ?? 0;
        final enrolLocal = (resp['enrolled'] as num?)?.toInt() ?? _petitionEnrolled;
        _snack('Petition signed ✓  ($count / $enrolLocal signatures)');
        _loadPetitions();
      } else {
        _snack(resp?['error'] as String? ?? 'Could not sign petition');
      }
    } catch (_) { _snack('Relay unreachable — try again'); }
  }

  Future<void> _createPetitionSheet({
    required String paramKey,
    required String protocolName,
    required String direction,
  }) async {
    final titleCtrl = TextEditingController();
    final descCtrl  = TextEditingController();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _cardBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(builder: (ctx2, setSheet) {
        return Padding(
          padding: EdgeInsets.only(
            left: 20, right: 20, top: 20,
            bottom: MediaQuery.of(ctx2).viewInsets.bottom + 24,
          ),
          child: Column(mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Header
            Row(children: [
              Icon(
                direction == 'deactivate'
                    ? Icons.remove_circle_outline_rounded
                    : Icons.add_circle_outline_rounded,
                color: direction == 'deactivate'
                    ? Colors.orangeAccent : Colors.greenAccent,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${direction == "deactivate" ? "Deactivate" : "Reactivate"} $protocolName',
                  style: const TextStyle(color: Colors.white,
                      fontWeight: FontWeight.bold, fontSize: 15),
                ),
              ),
            ]),
            const SizedBox(height: 4),
            Text(
              direction == 'deactivate'
                  ? '33% of citizens forces a deactivation vote.\n67% deactivates the protocol directly.'
                  : '33% of citizens forces a reactivation vote.',
              style: const TextStyle(color: Colors.white38,
                  fontSize: 11, height: 1.5),
            ),
            const SizedBox(height: 18),

            _fieldLabel('Petition Title'),
            const SizedBox(height: 6),
            TextField(
              controller: titleCtrl,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: _inputDecor('Briefly describe your concern (min 10 chars)'),
            ),
            const SizedBox(height: 12),

            _fieldLabel('Description (optional)'),
            const SizedBox(height: 6),
            TextField(
              controller: descCtrl,
              maxLines: 3,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: _inputDecor(
                  'Explain why this petition matters to citizens'),
            ),
            const SizedBox(height: 20),

            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () async {
                  if (titleCtrl.text.trim().length < 10) {
                    ScaffoldMessenger.of(ctx2).showSnackBar(const SnackBar(
                      content: Text(
                          'Title must be at least 10 characters'),
                      backgroundColor: _cardBg,
                      behavior: SnackBarBehavior.floating,
                    ));
                    return;
                  }
                  final title = titleCtrl.text.trim();
                  final desc  = descCtrl.text.trim();
                  Navigator.pop(ctx);
                  if (!mounted) return;
                  setState(() => _submittingPetition = true);
                  try {
                    final resp = await RelayConnector.sendAndWait(
                      request: {
                        'type':        'PETITION_CREATE',
                        'param_key':   paramKey,
                        'direction':   direction,
                        'title':       title,
                        'description': desc,
                      },
                      responseType: 'PETITION_RESULT',
                      timeout: const Duration(seconds: 12),
                    );
                    if (!mounted) return;
                    if (resp?['success'] == true) {
                      _snack('Petition created — you are the first signer ✓');
                      await _loadPetitions();
                      _tabs.animateTo(3);   // jump to Petitions tab
                    } else {
                      _snack(resp?['error'] as String? ?? 'Could not create petition');
                    }
                  } catch (_) {
                    _snack('Relay unreachable — try again');
                  } finally {
                    if (mounted) setState(() => _submittingPetition = false);
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: direction == 'deactivate'
                      ? Colors.orangeAccent : const Color(0xFF00C853),
                  foregroundColor: Colors.black,
                  minimumSize: const Size(double.infinity, 50),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                  elevation: 0,
                ),
                child: const Text('Create & Sign Petition',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ]),
        );
      }),
    );
    titleCtrl.dispose();
    descCtrl.dispose();
  }

  // ── SOV Value ─────────────────────────────────────────────────────────────

  Future<void> _loadSovValueStatus() async {
    if (!mounted) return;
    setState(() => _loadingSovValue = true);
    try {
      final resp = await RelayConnector.getSovValueStatus(widget.sovereignId);
      if (!mounted) return;
      setState(() {
        _sovValueStatus  = resp['success'] == true ? resp : null;
        _loadingSovValue = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingSovValue = false);
    }
  }

  Future<void> _submitSovValueProposal() async {
    final raw = double.tryParse(_sovValueCtrl.text.trim());
    if (raw == null || raw <= 0) { _snack('Enter a valid USD value'); return; }
    try {
      final resp = await RelayConnector.submitSovValueProposal(
          sovereignId: widget.sovereignId, proposedUsd: raw);
      if (!mounted) return;
      if (resp['success'] == true) {
        _snack('Proposal submitted ✓');
        _sovValueCtrl.clear();
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(DraftKeys.sovValueProposal);
        _loadSovValueStatus();
      } else {
        _snack(resp['error'] as String? ?? 'Submission failed');
      }
    } catch (_) { _snack('Relay unreachable — try again'); }
  }

  // ── Voting (polls) ────────────────────────────────────────────────────────

  Future<void> _vote(String pollId, String option) async {
    try {
      final resp = await RelayConnector.sendAndWait(
        // Relay handlePollVote expects the option STRING (validates against the
        // poll's option list), not an index — was sending option_index → vote rejected.
        request: { 'type': 'POLL_VOTE', 'sovereign_id': widget.sovereignId,
                   'poll_id': pollId, 'option': option },
        responseType: 'POLL_VOTE_RECORDED',
        timeout: const Duration(seconds: 10),
      );
      if (!mounted) return;
      if (resp != null && resp['success'] == true) {
        _snack('Vote recorded ✓');
        _loadPolls();
      } else {
        _snack(resp?['error'] ?? 'Vote failed');
      }
    } catch (_) { _snack('Relay unreachable — try again'); }
  }

  // ── Constitution — Propose Vote ───────────────────────────────────────────

  Future<void> _proposeVote({
    required String tag,
    required String protocolName,
    required String description,
  }) async {
    if (_proposingVote) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _cardBg,
        title: Text('Propose: $protocolName',
            style: const TextStyle(color: _goldBr, fontWeight: FontWeight.bold,
                fontSize: 15)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(description,
              style: const TextStyle(color: Colors.white60, fontSize: 13,
                  height: 1.5)),
          const SizedBox(height: 12),
          const Text(
            'This will create a governance poll that all citizens can vote on. '
            'The poll runs for 30 days.',
            style: TextStyle(color: Colors.white38, fontSize: 12, height: 1.5),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel', style: TextStyle(color: Colors.white38))),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: _gold, foregroundColor: Colors.black),
            child: const Text('Propose', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _proposingVote = true);
    try {
      final resp = await RelayConnector.sendAndWait(
        request: {
          'type':             'POLL_CREATE',
          'sovereign_id':     widget.sovereignId,
          'poll_id':          'poll_${DateTime.now().millisecondsSinceEpoch}_$tag',
          'tag':              tag,
          'title':            'Activate $protocolName?',
          'description':      '',
          'options':          ['Activate', 'Keep dormant'],
          'duration_minutes': 43200,   // 30 days × 1440 mins/day
          'direction':        'activate',
        },
        responseType: 'POLL_CREATED',
        timeout: const Duration(seconds: 12),
      );
      if (!mounted) return;
      if (resp != null && resp['success'] == true) {
        _snack('Poll created — citizens can now vote ✓');
        _loadPolls();
      } else {
        _snack(resp?['error'] ?? 'Could not create poll');
      }
    } catch (_) {
      _snack('Relay unreachable — try again');
    } finally {
      if (mounted) setState(() => _proposingVote = false);
    }
  }

  // ── Constitution — Propose Numeric Param Change ──────────────────────────

  Future<void> _proposeParamChange({
    required String       paramKey,
    required String       paramName,
    required String       description,
    required List<String> options,   // human-readable option labels (also stored as param values)
  }) async {
    if (_proposingVote) return;
    final currentRaw = _govParams[paramKey];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _cardBg,
        title: Text('Change: $paramName',
            style: const TextStyle(color: _goldBr, fontWeight: FontWeight.bold,
                fontSize: 15)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          if (currentRaw != null && currentRaw.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                const Text('Current value: ',
                    style: TextStyle(color: Colors.white38, fontSize: 12)),
                Text(currentRaw,
                    style: const TextStyle(color: _goldBr,
                        fontWeight: FontWeight.w600, fontSize: 12)),
              ]),
            ),
          Text(description,
              style: const TextStyle(color: Colors.white60, fontSize: 13,
                  height: 1.5)),
          const SizedBox(height: 12),
          Text(
            'Citizens vote on one of ${options.length} options. '
            'The poll runs for 30 days. Winning option becomes the new value.',
            style: const TextStyle(color: Colors.white38, fontSize: 12, height: 1.5),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel', style: TextStyle(color: Colors.white38))),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: _gold, foregroundColor: Colors.black),
            child: const Text('Propose', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _proposingVote = true);
    try {
      final resp = await RelayConnector.sendAndWait(
        request: {
          'type':             'POLL_CREATE',
          'sovereign_id':     widget.sovereignId,
          // Contract fields the relay handlePollCreate requires (was sending the
          // wrong names — constitution_tag/question/duration_epochs — so every
          // poll-create was silently rejected with MISSING_FIELDS).
          'poll_id':          'poll_${DateTime.now().millisecondsSinceEpoch}_$paramKey',
          'tag':              paramKey,
          'title':            'Change $paramName?',
          'description':      '',
          'options':          options,
          'duration_minutes': 43200,   // 30 days × 1440 mins/day
          'direction':        'activate',
        },
        responseType: 'POLL_CREATED',
        timeout: const Duration(seconds: 12),
      );
      if (!mounted) return;
      if (resp != null && resp['success'] == true) {
        _snack('Poll created — citizens can now vote ✓');
        _loadPolls();
      } else {
        _snack(resp?['error'] ?? 'Could not create poll');
      }
    } catch (_) {
      _snack('Relay unreachable — try again');
    } finally {
      if (mounted) setState(() => _proposingVote = false);
    }
  }

  // ── Image evidence picker ─────────────────────────────────────────────────

  Future<void> _pickEvidenceImage() async {
    if (_evidenceImages.length >= 3) {
      _snack('Maximum 3 evidence photos');
      return;
    }
    RelayConnector.externalActivityOpen = true;
    XFile? xfile;
    try {
      xfile = await ImagePicker().pickImage(
        source:       ImageSource.gallery,
        imageQuality: 50,     // compress to keep well under 500 KB
        maxWidth:     1280,
        maxHeight:    1280,
      );
    } finally {
      RelayConnector.externalActivityOpen = false;
    }
    if (xfile == null || !mounted) return;
    final bytes = await xfile.readAsBytes();
    if (bytes.lengthInBytes > 600 * 1024) {
      _snack('Image too large — max 500 KB');
      return;
    }
    setState(() => _evidenceImages.add(bytes));
  }

  // ── File dispute submit ───────────────────────────────────────────────────

  Future<void> _submitDispute() async {
    final txId = _txIdCtrl.text.trim();
    final desc = _descCtrl.text.trim();
    final hash = _hashCtrl.text.trim();

    if (txId.isEmpty) { _snack('Enter a transaction ID'); return; }
    if (desc.length < 50) {
      _snack('Description must be at least 50 characters (${desc.length}/50)');
      return;
    }

    setState(() { _submittingDispute = true; _disputeResult = null; });

    try {
      final images = _evidenceImages.map(base64Encode).toList();

      final resp = await RelayConnector.openJusticeDispute(
        sovereignId:      widget.sovereignId,
        defendantId:      txId,   // reused field — txId is the "defendant / tx to dispute"
        evidenceHash:     hash.isNotEmpty ? hash : desc.substring(0, desc.length.clamp(0, 64)),
        claimAmountSeeds: 0,
        evidenceImages:   images.isNotEmpty ? images : null,
      );

      if (!mounted) return;

      if (resp['success'] == true) {
        await _clearDisputeDrafts();
        setState(() {
          _submittingDispute = false;
          _disputeResult     = 'success';
        });
        _loadJusticeCases();
        _loadOpenDisputes();
      } else {
        setState(() {
          _submittingDispute = false;
          _disputeResult = resp['error'] as String? ?? 'Submission failed';
        });
      }
    } catch (e) {
      if (mounted) { setState(() {
        _submittingDispute = false;
        _disputeResult = 'Could not reach relay — try again';
      }); }
    }
  }

  // ── Justice verdict ───────────────────────────────────────────────────────

  Future<void> _castVerdictDialog(Map<String, dynamic> c) async {
    final caseId = c['case_id'] as String? ?? '';
    String? choice;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _cardBg,
        title: const Text('Cast Verdict',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Select your verdict. This cannot be changed.',
              style: TextStyle(color: Colors.white54, fontSize: 13)),
          const SizedBox(height: 16),
          _VerdictBtn(
            label: 'Uphold Plaintiff',
            sub:   'Transfer claim + return bond to plaintiff',
            color: Colors.greenAccent,
            icon:  Icons.check_circle_outline_rounded,
            onTap: () { choice = 'uphold_plaintiff'; Navigator.pop(ctx); },
          ),
          const SizedBox(height: 8),
          _VerdictBtn(
            label: 'Dismiss',
            sub:   'Burn plaintiff bond (10 SOV), unfreeze defendant',
            color: Colors.redAccent,
            icon:  Icons.cancel_outlined,
            onTap: () { choice = 'dismiss'; Navigator.pop(ctx); },
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel',
                  style: TextStyle(color: Colors.white38))),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    try {
      final resp = await RelayConnector.castJusticeVote(
          sovereignId: widget.sovereignId, caseId: caseId, verdict: choice!);
      if (!mounted) return;
      if (resp['success'] == true) {
        _snack(resp['verdict_reached'] != null
            ? 'Verdict reached: ${_fmtVerdict(resp['verdict_reached'] as String)}'
            : 'Vote recorded ✓');
        _loadJusticeCases();
      } else {
        _snack(resp['error'] as String? ?? 'Vote failed');
      }
    } catch (_) { _snack('Relay error — try again'); }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg), backgroundColor: _cardBg,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 3),
    ));
  }

  String _shortId(String id) => id.length > 20
      ? '${id.substring(0, 10)}…${id.substring(id.length - 6)}'
      : id;

  String _fmtVerdict(String v) {
    if (v == 'uphold_plaintiff') return 'Uphold Plaintiff';
    if (v == 'dismiss')          return 'Dismiss';
    return v;
  }

  String _formatTimeLeft(int mins) {
    if (mins <= 0)       return 'Closing';
    if (mins < 60)       return '${mins}m left';
    if (mins < 1440)     return '${mins ~/ 60}h left';
    return '${mins ~/ 1440}d left';
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // BUILD
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _navy,
      appBar: AppBar(
        backgroundColor: _navy,
        elevation: 0,
        automaticallyImplyLeading: false,
        title: const Text('Network Governance',
            style: TextStyle(color: _goldBr,
                fontWeight: FontWeight.bold, fontSize: 18)),
        bottom: TabBar(
          controller: _tabs,
          indicatorColor: _gold,
          labelColor: _gold,
          unselectedLabelColor: Colors.white38,
          labelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 11),
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: const [
            Tab(icon: Icon(Icons.gavel_rounded, size: 16),       text: 'Justice'),
            Tab(icon: Icon(Icons.menu_book_rounded, size: 16),   text: 'Constitution'),
            Tab(icon: Icon(Icons.how_to_vote_rounded, size: 16), text: 'Votes'),
            Tab(icon: Icon(Icons.draw_rounded, size: 16),        text: 'Petitions'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _buildJusticeTab(),
          _buildConstitutionTab(),
          _buildVotesTab(),
          _buildPetitionsTab(),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // TAB 1 — JUSTICE PROTOCOL
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildJusticeTab() {
    return RefreshIndicator(
      onRefresh: () async { await _loadJusticeCases(); await _loadOpenDisputes(); },
      color: _gold,
      backgroundColor: _cardBg,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 40),
        children: [
          // ── Jury Duty Invitations ─────────────────────────────────────────
          if (_pendingInvites.isNotEmpty) ...[
            Row(children: [
              const Icon(Icons.how_to_vote_rounded, color: _gold, size: 15),
              const SizedBox(width: 8),
              const Text('JURY DUTY',
                  style: TextStyle(color: Colors.white54, fontSize: 11,
                      fontWeight: FontWeight.w700, letterSpacing: 1.0)),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.orangeAccent.withAlpha(40),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.orangeAccent.withAlpha(100)),
                ),
                child: Text('${_pendingInvites.length}',
                    style: const TextStyle(color: Colors.orangeAccent,
                        fontSize: 10, fontWeight: FontWeight.bold)),
              ),
            ]),
            const SizedBox(height: 8),
            ..._pendingInvites.map(_buildJuryInviteCard),
            const SizedBox(height: 20),
          ],

          // ── My Cases ──────────────────────────────────────────────────────
          _sectionHeader(Icons.assignment_rounded, 'My Cases'),
          const SizedBox(height: 8),
          if (_loadingJustice)
            _loadingIndicator()
          else if (_myCases.isEmpty)
            _emptyState(
              'No justice cases yet.',
              'Citizens selected as jurors will see their cases here. '
              'This is how the network protects honest citizens.',
            )
          else
            ..._myCases.map(_buildCaseCard),

          const SizedBox(height: 20),

          // ── Open Disputes ─────────────────────────────────────────────────
          _sectionHeader(Icons.public_rounded, 'Open Disputes'),
          const SizedBox(height: 8),
          if (_loadingDisputes)
            _loadingIndicator()
          else if (_openDisputes.isEmpty)
            _emptyState(
              'No active disputes.',
              'This is a good sign.',
            )
          else
            ..._openDisputes.map(_buildOpenDisputeCard),

          const SizedBox(height: 20),

          // ── File Dispute ───────────────────────────────────────────────────
          _sectionHeader(Icons.edit_document, 'File a Dispute'),
          const SizedBox(height: 8),
          _buildFileDisputeForm(),
        ],
      ),
    );
  }

  Widget _buildCaseCard(Map<String, dynamic> c) {
    final caseId    = c['case_id']    as String? ?? '';
    final role      = c['role']       as String? ?? 'plaintiff';
    final status    = c['status']     as String? ?? 'open';
    final isOpen    = status == 'open';
    final defendant = c['defendant_id'] as String? ?? '';
    final claimAmt  = (c['claim_amount'] as num?)?.toDouble() ?? 0;
    final myVote    = c['my_vote']    as String?;
    final verdict   = c['verdict']   as String?;
    final votesUp   = (c['votes_uphold']  as num?)?.toInt() ?? 0;
    final votesDis  = (c['votes_dismiss'] as num?)?.toInt() ?? 0;
    final totalJur  = (c['total_jurors']  as num?)?.toInt() ?? 0;
    final expiresAt = (c['expires_at'] as num?)?.toInt() ?? 0;

    final amountSOV = (claimAmt / 1000000).toStringAsFixed(2);
    final isJuror   = role == 'juror';
    final canVote   = isOpen && isJuror && myVote == null;

    final nowMs     = DateTime.now().millisecondsSinceEpoch;
    final msLeft    = expiresAt - nowMs;
    final timeLabel = msLeft > 0
        ? _formatTimeLeft(msLeft ~/ 60000)
        : (isOpen ? 'Closing' : 'Closed');

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isOpen ? _teal.withAlpha(70) : Colors.white.withAlpha(10)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.gavel_rounded, color: _teal, size: 14),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Case ${caseId.length > 12 ? caseId.substring(0, 12) : caseId}',
              style: const TextStyle(color: Colors.white,
                  fontWeight: FontWeight.bold, fontSize: 13),
            ),
          ),
          _chip(role == 'plaintiff' ? 'Plaintiff' : 'Juror',
              role == 'plaintiff' ? _goldBr : _teal),
          const SizedBox(width: 6),
          _chip(status.toUpperCase(), isOpen ? _teal : Colors.white38),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          const Icon(Icons.person_outline_rounded, color: Colors.white38, size: 13),
          const SizedBox(width: 5),
          Expanded(
            child: Text('vs ${_justiceName(defendant)}',
                style: const TextStyle(color: Colors.white54, fontSize: 12)),
          ),
          Text('${SovCurrency.symbol} $amountSOV claimed',
              style: const TextStyle(color: _goldBr, fontSize: 12,
                  fontWeight: FontWeight.w600)),
        ]),
        if (isOpen) ...[
          const SizedBox(height: 6),
          Row(children: [
            const Icon(Icons.timer_outlined, color: Colors.white38, size: 12),
            const SizedBox(width: 4),
            Text(timeLabel,
                style: const TextStyle(color: Colors.white38, fontSize: 11)),
          ]),
        ],
        if (totalJur > 0) ...[
          const SizedBox(height: 8),
          Row(children: [
            _tallyChip(Icons.check_circle_outline_rounded,
                Colors.greenAccent, '$votesUp Uphold'),
            const SizedBox(width: 8),
            _tallyChip(Icons.cancel_outlined,
                Colors.redAccent, '$votesDis Dismiss'),
            const Spacer(),
            Text('of $totalJur jurors',
                style: const TextStyle(color: Colors.white38, fontSize: 10)),
          ]),
        ],
        if (verdict != null && verdict.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: (verdict == 'uphold_plaintiff' ? Colors.greenAccent : Colors.redAccent)
                  .withAlpha(20),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: (verdict == 'uphold_plaintiff' ? Colors.greenAccent : Colors.redAccent)
                    .withAlpha(80)),
            ),
            child: Text('VERDICT: ${_fmtVerdict(verdict).toUpperCase()}',
                style: TextStyle(
                  color: verdict == 'uphold_plaintiff'
                      ? Colors.greenAccent : Colors.redAccent,
                  fontSize: 10, fontWeight: FontWeight.bold)),
          ),
        ],
        if (canVote) ...[
          const SizedBox(height: 12),
          const Divider(color: Colors.white12, height: 1),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.check_circle_outline_rounded,
                    size: 14, color: Colors.greenAccent),
                label: const Text('Uphold',
                    style: TextStyle(color: Colors.greenAccent,
                        fontSize: 12, fontWeight: FontWeight.w600)),
                onPressed: () => _castVerdictDialog(c),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.greenAccent, width: 0.8),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.cancel_outlined,
                    size: 14, color: Colors.redAccent),
                label: const Text('Dismiss',
                    style: TextStyle(color: Colors.redAccent,
                        fontSize: 12, fontWeight: FontWeight.w600)),
                onPressed: () => _castVerdictDialog(c),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.redAccent, width: 0.8),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                ),
              ),
            ),
          ]),
        ],
        if (myVote != null) ...[
          const SizedBox(height: 8),
          Row(children: [
            const Icon(Icons.how_to_vote_rounded,
                color: Colors.greenAccent, size: 13),
            const SizedBox(width: 5),
            Text('You voted: ${_fmtVerdict(myVote).toUpperCase()}',
                style: const TextStyle(color: Colors.greenAccent,
                    fontSize: 11, fontWeight: FontWeight.w600)),
          ]),
        ],
        // [JUSTICE-COUNCIL] Expand Panel — accepted jurors can add 1 more juror
        if (isOpen && isJuror && myVote == null && totalJur > 0) ...[
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.person_add_alt_1_rounded,
                  size: 13, color: Colors.orangeAccent),
              label: const Text('Add Juror to Panel',
                  style: TextStyle(color: Colors.orangeAccent,
                      fontSize: 12, fontWeight: FontWeight.w600)),
              onPressed: () => _expandPanel(caseId),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.orangeAccent, width: 0.7),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.symmetric(vertical: 7),
              ),
            ),
          ),
        ],
      ]),
    );
  }

  Widget _buildOpenDisputeCard(Map<String, dynamic> d) {
    final caseId   = d['case_id']     as String? ?? '';
    final fromId   = d['plaintiff_id'] as String? ?? (d['from_id'] as String? ?? '');
    final toId     = d['defendant_id'] as String? ?? (d['to_id']   as String? ?? '');
    final claimAmt = (d['claim_amount'] as num?)?.toDouble() ?? 0;
    final expiresAt = (d['expires_at'] as num?)?.toInt() ?? 0;
    final nowMs    = DateTime.now().millisecondsSinceEpoch;
    final msLeft   = expiresAt - nowMs;
    final amountSOV = (claimAmt / 1000000).toStringAsFixed(2);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withAlpha(12)),
      ),
      child: Row(children: [
        const Icon(Icons.balance_rounded, color: _teal, size: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Case ${caseId.length > 10 ? caseId.substring(0, 10) : caseId}',
                style: const TextStyle(color: Colors.white,
                    fontWeight: FontWeight.w600, fontSize: 12)),
            const SizedBox(height: 2),
            Text('${_justiceName(fromId)} → ${_justiceName(toId)}',
                style: const TextStyle(color: Colors.white38, fontSize: 11)),
          ]),
        ),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('${SovCurrency.symbol} $amountSOV',
              style: const TextStyle(color: _goldBr, fontSize: 12,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(msLeft > 0 ? _formatTimeLeft(msLeft ~/ 60000) : 'Closing',
              style: const TextStyle(color: Colors.white38, fontSize: 10)),
        ]),
      ]),
    );
  }

  // ── Jury duty invitation card ─────────────────────────────────────────────
  Widget _buildJuryInviteCard(Map<String, dynamic> invite) {
    final caseId    = invite['case_id']     as String? ?? '';
    final plaintiff = invite['plaintiff_id'] as String? ?? '';
    final defendant = invite['defendant_id'] as String? ?? '';
    final claimAmt  = (invite['claim_amount'] as num?)?.toDouble() ?? 0;
    final expiresAt = (invite['expires_at']  as num?)?.toInt() ?? 0;
    final windowH   = (invite['response_window_hours'] as num?)?.toInt() ?? 48;
    final amtSOV    = (claimAmt / 1000000).toStringAsFixed(2);
    final msLeft    = expiresAt - DateTime.now().millisecondsSinceEpoch;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.orangeAccent.withAlpha(80)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.gavel_rounded, color: Colors.orangeAccent, size: 14),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Jury Duty — Case ${caseId.length > 10 ? caseId.substring(0,10) : caseId}',
              style: const TextStyle(color: Colors.white,
                  fontWeight: FontWeight.bold, fontSize: 13),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.orangeAccent.withAlpha(30),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text('INVITED',
                style: TextStyle(color: Colors.orangeAccent,
                    fontSize: 10, fontWeight: FontWeight.bold)),
          ),
        ]),
        const SizedBox(height: 8),
        Text('${_justiceName(plaintiff)} vs ${_justiceName(defendant)}',
            style: const TextStyle(color: Colors.white54, fontSize: 12)),
        const SizedBox(height: 4),
        Row(children: [
          const Icon(Icons.monetization_on_outlined, color: _goldBr, size: 12),
          const SizedBox(width: 4),
          Text('${SovCurrency.symbol} $amtSOV at stake',
              style: const TextStyle(color: _goldBr, fontSize: 12,
                  fontWeight: FontWeight.w600)),
          const Spacer(),
          const Icon(Icons.timer_outlined, color: Colors.white38, size: 12),
          const SizedBox(width: 4),
          Text('${windowH}h to respond',
              style: const TextStyle(color: Colors.white38, fontSize: 11)),
        ]),
        if (msLeft > 0) ...[
          const SizedBox(height: 4),
          Text('Case expires in ${_formatTimeLeft(msLeft ~/ 60000)}',
              style: const TextStyle(color: Colors.white38, fontSize: 10)),
        ],
        const SizedBox(height: 12),
        const Divider(color: Colors.white12, height: 1),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: ElevatedButton.icon(
              icon: const Icon(Icons.check_rounded, size: 14),
              label: Text(_respondingToInvite ? '…' : 'Accept',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              onPressed: _respondingToInvite
                  ? null
                  : () => _respondJuryDuty(invite, 'accept'),
              style: ElevatedButton.styleFrom(
                backgroundColor: _teal,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.symmetric(vertical: 10),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.close_rounded, size: 14,
                  color: Colors.white38),
              label: const Text('Decline',
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
              onPressed: _respondingToInvite
                  ? null
                  : () => _respondJuryDuty(invite, 'decline'),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.white24, width: 0.7),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.symmetric(vertical: 10),
              ),
            ),
          ),
        ]),
      ]),
    );
  }

  Widget _buildFileDisputeForm() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withAlpha(12)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Info banner
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: _gold.withAlpha(14),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _gold.withAlpha(40)),
          ),
          child: const Text(
            'A 10 SOV bond is deducted when you file. '
            'Randomly selected jurors review within 72 hours. '
            'Uphold: claim + bond returned. Dismiss: bond burned.',
            style: TextStyle(color: Colors.white54, fontSize: 11, height: 1.5),
          ),
        ),
        const SizedBox(height: 14),

        // Transaction ID — with contact picker button
        _fieldLabel('Transaction ID or Defendant Sovereign ID *'),
        const SizedBox(height: 6),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: _txIdCtrl,
                onChanged: (_) => _saveDisputeDrafts(),
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: _inputDecor('SOV-XXXXXXXXXXXXXXXX or tx hash'),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 48,
              child: ElevatedButton(
                onPressed: _pickDefendantFromContacts,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white.withAlpha(15),
                  foregroundColor: _gold,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: BorderSide(color: _gold.withAlpha(80)),
                  ),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.contacts_outlined, size: 16),
                    SizedBox(width: 4),
                    Text('Contacts',
                        style: TextStyle(fontSize: 11,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),

        // Description
        _fieldLabel('Description * (minimum 50 characters)'),
        const SizedBox(height: 6),
        StatefulBuilder(builder: (_, setLocal) {
          return TextField(
            controller: _descCtrl,
            maxLines: 4,
            onChanged: (_) { _saveDisputeDrafts(); setLocal(() {}); },
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: _inputDecor(
              'Describe the dispute in detail. Include what happened, '
              'when it happened, and the amount involved.',
            ).copyWith(
              helperText: '${_descCtrl.text.length}/50 minimum',
              helperStyle: TextStyle(
                color: _descCtrl.text.length >= 50
                    ? Colors.greenAccent
                    : Colors.white38,
                fontSize: 10,
              ),
            ),
          );
        }),
        const SizedBox(height: 14),

        // Evidence Hash (optional)
        _fieldLabel('Evidence Hash (optional)'),
        const SizedBox(height: 6),
        TextField(
          controller: _hashCtrl,
          onChanged: (_) => _saveDisputeDrafts(),
          style: const TextStyle(color: Colors.white, fontSize: 13),
          decoration: _inputDecor(
              'SHA-256 hash of external evidence file (optional)'),
        ),
        const SizedBox(height: 18),

        // Image evidence
        _fieldLabel('Evidence Photos (optional, max 3)'),
        const SizedBox(height: 8),
        if (_evidenceImages.isNotEmpty)
          SizedBox(
            height: 90,
            child: Row(
              children: _evidenceImages.asMap().entries.map((e) {
                return Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.memory(e.value,
                            width: 80, height: 80, fit: BoxFit.cover),
                      ),
                      Positioned(
                        top: -8,
                        right: -8,
                        child: GestureDetector(
                          onTap: () => setState(
                              () => _evidenceImages.removeAt(e.key)),
                          child: Container(
                            width: 22, height: 22,
                            decoration: BoxDecoration(
                              color: Colors.redAccent,
                              shape: BoxShape.circle,
                              border: Border.all(color: _navy, width: 1.5),
                            ),
                            child: const Icon(Icons.close_rounded,
                                size: 12, color: Colors.white),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
        if (_evidenceImages.length < 3)
          ElevatedButton.icon(
            icon: const Icon(Icons.add_photo_alternate_rounded, size: 16),
            label: Text(_evidenceImages.isEmpty
                ? 'Add Evidence Photo' : 'Add Another Photo'),
            onPressed: _pickEvidenceImage,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white.withAlpha(15),
              foregroundColor: Colors.white70,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: BorderSide(color: Colors.white.withAlpha(30)),
              ),
            ),
          ),
        const SizedBox(height: 20),

        // Result feedback
        if (_disputeResult != null) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: (_disputeResult == 'success'
                      ? Colors.greenAccent : Colors.redAccent)
                  .withAlpha(18),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: (_disputeResult == 'success'
                        ? Colors.greenAccent : Colors.redAccent)
                    .withAlpha(70)),
            ),
            child: Row(children: [
              Icon(
                _disputeResult == 'success'
                    ? Icons.check_circle_outline_rounded
                    : Icons.error_outline_rounded,
                color: _disputeResult == 'success'
                    ? Colors.greenAccent : Colors.redAccent,
                size: 16,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _disputeResult == 'success'
                      ? 'Dispute filed. Jurors have been notified.'
                      : _disputeResult!,
                  style: TextStyle(
                    color: _disputeResult == 'success'
                        ? Colors.greenAccent : Colors.redAccent,
                    fontSize: 12,
                  ),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 14),
        ],

        // Submit button
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            icon: _submittingDispute
                ? const SizedBox(
                    width: 14, height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 1.5, color: Colors.black))
                : const Icon(Icons.gavel_rounded, size: 16),
            label: Text(_submittingDispute ? 'Filing…' : 'File Dispute'),
            onPressed: _submittingDispute ? null : _submitDispute,
            style: ElevatedButton.styleFrom(
              backgroundColor: _gold,
              foregroundColor: Colors.black,
              minimumSize: const Size(double.infinity, 50),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
              elevation: 0,
            ),
          ),
        ),
      ]),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // TAB 2 — NETWORK CONSTITUTION
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildConstitutionTab() {
    return RefreshIndicator(
      onRefresh: () async { await _loadPolls(); await _loadSovValueStatus(); },
      color: _gold,
      backgroundColor: _cardBg,
      child: ListView(
        key: const ValueKey('constitutionList'),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 40),
        children: [
          // SOV Value — featured card at top
          _buildSovValueCard(),
          const SizedBox(height: 16),

          // Protocol items
          _sectionHeader(Icons.pending_actions_rounded,
              'Pending Network Protocols'),
          const SizedBox(height: 4),
          const Text(
            'These protocols are awaiting citizen activation. '
            'Tap PROPOSE VOTE to start a 30-day governance poll.',
            style: TextStyle(color: Colors.white38, fontSize: 11, height: 1.5),
          ),
          const SizedBox(height: 14),

          _buildProtocolItem(
            tag:    'sov_request',
            icon:   Icons.link_rounded,
            title:  'SOV Payment Links',
            desc:   'Generate a payment link with a fixed amount and '
                    'QR code that any citizen can scan to pay instantly.',
          ),
          _buildProtocolItem(
            tag:    'sov_login',
            icon:   Icons.fingerprint_rounded,
            title:  'SOV Login',
            desc:   'Sign in to third-party services using your citizen identity. '
                    'No password, no email — biometric authentication.',
          ),
          _buildProtocolItem(
            tag:         'sov_enclave',
            icon:        Icons.shield_rounded,
            title:       'SOV Enclave',
            desc:        'A citizen-governed public space for open discussion. '
                         'Posts require valid palm identity. No bots, no censors — '
                         'only citizens. Speak freely inside the Enclave.',
            govParamKey: 'sov_enclave',
          ),
          _buildProtocolItem(
            tag:    'privacy_toggle',
            icon:   Icons.visibility_off_rounded,
            title:  'Balance Privacy Mode',
            desc:   'Citizens can choose to hide their balance from other '
                    'citizens while keeping it visible to themselves.',
          ),
          _buildProtocolItem(
            tag:    'relay_staking',
            icon:   Icons.hub_rounded,
            title:  'Relay Staking Rewards',
            desc:   'Relay node operators stake SOV as collateral and earn '
                    'a percentage of transactions they witness.',
          ),
          _buildProtocolItem(
            tag:    'merit_pool',
            icon:   Icons.workspace_premium_rounded,
            title:  'Citizen Merit Pool',
            desc:   'Citizens who contribute to the network earn merit points '
                    'that unlock higher transaction limits and governance weight.',
          ),
          _buildProtocolItem(
            tag:    'sov_escrow_api',
            icon:   Icons.handshake_rounded,
            title:  'Merchant Escrow API',
            desc:   'External merchants can use relay escrow for e-commerce '
                    'payments with automatic dispute resolution.',
          ),
          _buildProtocolItem(
            tag:    'nfc_id',
            icon:   Icons.nfc_rounded,
            title:  'NFC Identity Tap',
            desc:   'Tap two phones together to exchange Sovereign IDs '
                    'instantly without showing QR codes.',
          ),
          _buildProtocolItem(
            tag:    'exchange_network_fee',
            icon:   Icons.percent_rounded,
            title:  'Exchange Network Fee',
            desc:   'Introduce a small network fee (suggested 0.5–2%) on '
                    'completed exchange orders. Fees go into the citizen '
                    'merit pool and relay staking rewards. Citizens vote '
                    'on the fee rate and distribution split.',
          ),
          // Dual Palm Identity: NOT a poll-gated protocol. Made a permanent
          // accessibility feature 2026-07-16 (king directive) — LEFT default,
          // double-tap the enrollment scan to flip to RIGHT. One palm per
          // citizen is enforced by the enrollment engine.

          const SizedBox(height: 20),
          _sectionHeader(Icons.tune_rounded, 'Governance Settings'),
          const SizedBox(height: 4),
          const Text(
            'These parameters control how governance itself works. '
            'Propose a change and citizens vote on the new value.',
            style: TextStyle(color: Colors.white38, fontSize: 11, height: 1.5),
          ),
          const SizedBox(height: 14),

          // ── Release integrity (Layer 2) ────────────────────────────────────
          // These decide how the network polices the software its own operators
          // run. They were readable by the code and seeded on every node, but had
          // no poll and no PARAM_MAP entry — so only someone with node database
          // access could change them. That is an operator-only lever, and the
          // network is meant to answer to its citizens, not to whoever holds a
          // shell. Voting on them is now the only way they move.
          _buildGovParamItem(
            paramKey: 'release_enforce_mode',
            icon:     Icons.verified_user_rounded,
            title:    'Unrecognised Software',
            desc:     'What a node does when another node tries to join running '
                      'software the network does not recognise. "warn" lets it in '
                      'and records it; "refuse" turns it away. Refuse is the real '
                      'protection — but if the network is mid-upgrade it can also '
                      'shut out honest operators who have not updated yet.',
            options:  ['warn', 'refuse'],
            unit:     '',
          ),
          _buildGovParamItem(
            paramKey: 'release_dispute_threshold',
            icon:     Icons.groups_rounded,
            title:    'Software Agreement Threshold',
            desc:     'How many independent operators must already be running a '
                      'version before a newcomer running it is accepted. Higher is '
                      'stricter, but cannot exceed the number of separate operators '
                      'the network actually has.',
            options:  ['1', '2', '3', '5', '7'],
            unit:     ' operators',
          ),
          _buildGovParamItem(
            paramKey: 'release_signer_min_uptime_days',
            icon:     Icons.schedule_rounded,
            title:    'Earned Standing Period',
            desc:     'How many days of continuous uptime a node needs before its '
                      'opinion on which software is legitimate counts. This is what '
                      'stops someone spinning up machines to manufacture agreement.',
            options:  ['0', '1', '7', '21', '90'],
            unit:     ' days',
          ),

          _buildGovParamItem(
            paramKey: 'poll_retention_days',
            icon:     Icons.archive_rounded,
            title:    'Poll Retention',
            desc:     'How long closed governance polls are kept before being '
                      'archived. Shorter keeps the UI clean; longer preserves history.',
            options:  ['7', '14', '30', '60', '90'],
            unit:     ' days',
          ),
          _buildGovParamItem(
            paramKey: 're_proposal_cooldown_days',
            icon:     Icons.timer_off_rounded,
            title:    'Re-proposal Cooldown',
            desc:     'How long citizens must wait before proposing a new poll '
                      'on the same topic after one closes. Prevents spam voting.',
            options:  ['1', '3', '7', '14', '30'],
            unit:     ' days',
          ),
          _buildGovParamItem(
            paramKey: 'petition_threshold_pct',
            icon:     Icons.draw_rounded,
            title:    'Petition Poll Threshold',
            desc:     'Percentage of enrolled citizens that must sign a petition '
                      'to force a governance poll on that topic.',
            options:  ['0.10', '0.20', '0.33', '0.50'],
            unit:     '',
          ),
          _buildGovParamItem(
            paramKey: 'petition_supermajority_pct',
            icon:     Icons.how_to_vote_rounded,
            title:    'Petition Supermajority',
            desc:     'Percentage of enrolled citizens whose signatures directly '
                      'flip a protocol parameter without requiring a poll vote.',
            options:  ['0.51', '0.60', '0.67', '0.75'],
            unit:     '',
          ),
          _buildGovParamItem(
            paramKey: 'quorum_threshold',
            icon:     Icons.people_alt_rounded,
            title:    'Vote Quorum',
            desc:     'Minimum fraction of enrolled citizens who must vote for a '
                      'poll result to be binding and trigger parameter activation.',
            options:  ['0.05', '0.10', '0.15', '0.20', '0.33'],
            unit:     '',
          ),
          // ── Transfer economics (citizen-governed) ──────────────────────────
          _buildGovParamItem(
            paramKey: 'tx_fee_rate',
            icon:     Icons.percent_rounded,
            title:    'Transfer Fee',
            desc:     'Fee charged on each SOV transfer, as a fraction of the '
                      'amount sent. Launched at 0.1% to keep sending cheap. Set to '
                      '0 for free transfers (fees fund network operators).',
            options:  ['0', '0.0005', '0.001', '0.0025', '0.005'],
            unit:     '',
          ),
          _buildGovParamItem(
            paramKey: 'tx_fee_max_sov',
            icon:     Icons.vertical_align_top_rounded,
            title:    'Transfer Fee Cap',
            desc:     'Maximum fee any single transfer can cost, in SOV — so large '
                      'transfers never pay more than this. Set to 0 for no cap '
                      '(pure percentage).',
            options:  ['0', '1', '5', '10', '50'],
            unit:     ' SOV',
          ),
          _buildGovParamItem(
            paramKey: 'min_poll_duration',
            icon:     Icons.hourglass_bottom_rounded,
            title:    'Minimum Poll Duration',
            desc:     'Shortest time a governance poll can run before closing, '
                      'ensuring citizens have time to see and vote.',
            options:  ['720', '1440', '2880', '4320'],
            unit:     ' min',
          ),
          _buildGovParamItem(
            paramKey: 'max_poll_duration',
            icon:     Icons.hourglass_top_rounded,
            title:    'Maximum Poll Duration',
            desc:     'Longest time a governance poll can run. Prevents polls from '
                      'staying open indefinitely.',
            options:  ['2880', '7200', '10080', '20160', '43200'],
            unit:     ' min',
          ),
          _buildGovParamItem(
            paramKey: 'justice_min_jury_size',
            icon:     Icons.gavel_rounded,
            title:    'Starting Jury Size',
            desc:     'Number of jurors automatically selected when a dispute is '
                      'opened. Panel can be expanded by accepted jurors.',
            options:  ['3', '5', '7', '9'],
            unit:     ' jurors',
          ),
          _buildGovParamItem(
            paramKey: 'justice_response_window_hours',
            icon:     Icons.timer_rounded,
            title:    'Jury Response Window',
            desc:     'Hours a selected juror has to accept or decline their '
                      'appointment before being automatically replaced.',
            options:  ['12', '24', '48', '72', '120'],
            unit:     ' hours',
          ),
          _buildGovParamItem(
            paramKey: 'tx_retention_days',
            icon:     Icons.receipt_long_rounded,
            title:    'Transaction Retention',
            desc:     'How long the relay keeps transaction records. '
                      'After this window, old records are automatically pruned. '
                      'Citizens own their full history on their devices.',
            options:  ['7', '14', '30', '60', '90', '180'],
            unit:     ' days',
          ),
          _buildGovParamItem(
            paramKey: 'sov_issuance_rate',
            icon:     Icons.account_balance_rounded,
            title:    'SOV Issuance Rate',
            desc:     'Seeds distributed to every enrolled citizen per epoch. '
                      '0 = no issuance (deflationary). Requires governance vote to activate. '
                      '1 SOV = 1,000,000 seeds.',
            options:  ['0', '100', '500', '1000', '5000'],
            unit:     ' seeds/epoch',
          ),
          _buildGovParamItem(
            paramKey: 'issuance_epoch_hours',
            icon:     Icons.timer_outlined,
            title:    'Issuance Epoch Length',
            desc:     'How many hours constitute one issuance epoch. '
                      'Citizens can claim one allocation per epoch.',
            options:  ['1', '6', '12', '24', '168'],
            unit:     ' hours',
          ),
          _buildGovParamItem(
            paramKey: 'issuance_max_backlog_epochs',
            icon:     Icons.history_rounded,
            title:    'Max Issuance Backlog',
            desc:     'Maximum number of unclaimed epochs a citizen can accumulate. '
                      'Epochs beyond this window are forfeited.',
            options:  ['1', '3', '7', '14', '30'],
            unit:     ' epochs',
          ),
          _buildGovParamItem(
            paramKey: 'academy_article_bond',
            icon:     Icons.school_rounded,
            title:    'Academy Article Bond',
            desc:     'SOV burned when a citizen publishes an article to the '
                      'Academy. Discourages spam while keeping publishing '
                      'accessible to all enrolled citizens.',
            options:  ['1', '5', '10', '25', '50'],
            unit:     ' SOV',
          ),
          _buildGovParamItem(
            paramKey: 'academy_max_article_size_kb',
            icon:     Icons.article_rounded,
            title:    'Max Article Size',
            desc:     'Maximum body size for a single Academy article. '
                      'Larger limits allow richer content but increase relay '
                      'storage requirements.',
            options:  ['10', '25', '50', '100', '200'],
            unit:     ' KB',
          ),
          _buildGovParamItem(
            paramKey: 'academy_upvote_bond',
            icon:     Icons.thumb_up_rounded,
            title:    'Article Upvote Bond',
            desc:     'SOV burned when upvoting an Academy article. '
                      'Set to 0 to allow free upvotes. A small bond '
                      'discourages coordinated vote manipulation.',
            options:  ['0', '1', '2', '5'],
            unit:     ' SOV',
          ),
          _buildGovParamItem(
            paramKey: 'guardian_approval_threshold',
            icon:     Icons.shield_rounded,
            title:    'Guardian Approval Threshold',
            desc:     'Number of guardian approvals required to authorise '
                      'an account recovery. Higher values are more secure '
                      'but harder to recover if guardians are unavailable.',
            options:  ['1', '2', '3', '4', '5'],
            unit:     ' approvals',
          ),
          _buildGovParamItem(
            paramKey: 'guardian_max_count',
            icon:     Icons.people_alt_rounded,
            title:    'Max Guardians Per Citizen',
            desc:     'Maximum number of guardians a citizen can nominate. '
                      'More guardians increase recovery resilience.',
            options:  ['3', '5', '7', '10'],
            unit:     ' guardians',
          ),
          _buildGovParamItem(
            paramKey: 'guardian_recovery_window_hours',
            icon:     Icons.timer_rounded,
            title:    'Recovery Window',
            desc:     'Hours a recovery request stays open for guardians '
                      'to approve before it expires.',
            options:  ['24', '48', '72', '168'],
            unit:     ' hours',
          ),
        ],
      ),
    );
  }

  Widget _buildSovValueCard() {
    final s           = _sovValueStatus;
    final currentRate = (s?['current_usd_rate']  as num?)?.toDouble() ?? 0.0;
    final epoch       = (s?['current_epoch']      as num?)?.toInt() ?? 0;
    final voteCount   = (s?['vote_count']         as num?)?.toInt() ?? 0;
    final myProposal  = (s?['my_proposal']        as num?)?.toDouble();
    final hasProposed = myProposal != null;
    const threshold   = 5000;
    final progress    = (voteCount / threshold).clamp(0.0, 1.0);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _gold.withAlpha(55)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.trending_up_rounded, color: _gold, size: 16),
          const SizedBox(width: 8),
          const Expanded(
            child: Text('SOV Value Voting',
                style: TextStyle(color: _goldBr,
                    fontWeight: FontWeight.bold, fontSize: 13)),
          ),
          if (_loadingSovValue)
            const SizedBox(width: 14, height: 14,
                child: CircularProgressIndicator(
                    strokeWidth: 1.5, color: _gold))
          else if (epoch > 0)
            Text('Epoch $epoch',
                style: const TextStyle(color: Colors.white38, fontSize: 11)),
        ]),
        const SizedBox(height: 10),

        if (currentRate > 0) ...[
          Row(children: [
            const Text('Current rate: ',
                style: TextStyle(color: Colors.white54, fontSize: 12)),
            Text('\$${currentRate.toStringAsFixed(4)} USD',
                style: const TextStyle(color: _goldBr,
                    fontWeight: FontWeight.w600, fontSize: 12)),
          ]),
          const SizedBox(height: 8),
        ],

        Row(children: [
          Text('Progress: $voteCount / $threshold proposals',
              style: const TextStyle(color: Colors.white54, fontSize: 11)),
          const Spacer(),
          Text('${(progress * 100).toStringAsFixed(0)}%',
              style: const TextStyle(color: Colors.white38, fontSize: 11)),
        ]),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 5,
            backgroundColor: Colors.white.withAlpha(12),
            valueColor: AlwaysStoppedAnimation<Color>(
                progress >= 1.0 ? Colors.greenAccent : _gold),
          ),
        ),

        if (s != null) ...[
          const SizedBox(height: 12),
          if (hasProposed)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.greenAccent.withAlpha(15),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.greenAccent.withAlpha(60)),
              ),
              child: Row(children: [
                const Icon(Icons.check_circle_rounded,
                    color: Colors.greenAccent, size: 14),
                const SizedBox(width: 6),
                Text('Your proposal: \$${myProposal.toStringAsFixed(4)} USD',
                    style: const TextStyle(color: Colors.greenAccent, fontSize: 12,
                        fontWeight: FontWeight.w600)),
              ]),
            )
          else ...[
            const Text('Propose a USD value for SOV:',
                style: TextStyle(color: Colors.white38, fontSize: 11)),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _sovValueCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: _inputDecor('e.g. 0.50').copyWith(
                    prefixText: '\$ ',
                    prefixStyle: const TextStyle(color: _goldBr),
                    isDense: true,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              ElevatedButton(
                onPressed: _submitSovValueProposal,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _gold, foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 18, vertical: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                  elevation: 0,
                ),
                child: const Text('Submit',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              ),
            ]),
          ],
        ] else
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'Connect to a relay to participate in SOV value voting.',
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ),
      ]),
    );
  }

  Widget _buildGovParamItem({
    required String       paramKey,
    required IconData     icon,
    required String       title,
    required String       desc,
    required List<String> options,
    String                unit = '',    // suffix like ' days', ' %'
  }) {
    final rawVal     = _govParams[paramKey];
    final voteActive = _protocolVoteActive[paramKey] ?? false;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withAlpha(10)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: _teal.withAlpha(40),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: _teal, size: 18),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Text(title,
                    style: const TextStyle(color: Colors.white,
                        fontWeight: FontWeight.w600, fontSize: 13)),
              ),
              if (rawVal != null && rawVal.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: _teal.withAlpha(40),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: _teal.withAlpha(80)),
                  ),
                  child: Text('$rawVal$unit',
                      style: const TextStyle(
                          color: Color(0xFF4DB6AC),
                          fontSize: 10, fontWeight: FontWeight.bold)),
                ),
            ]),
            const SizedBox(height: 4),
            Text(desc, style: const TextStyle(color: Colors.white54,
                fontSize: 11, height: 1.5)),
            if (voteActive) ...[
              const SizedBox(height: 8),
              const Row(children: [
                Icon(Icons.how_to_vote_rounded,
                    color: _goldBr, size: 12),
                SizedBox(width: 4),
                Text('Governance vote in progress',
                    style: TextStyle(color: _goldBr, fontSize: 11)),
              ]),
            ] else ...[
              const SizedBox(height: 10),
              SizedBox(
                height: 34,
                child: ElevatedButton(
                  key: ValueKey('proposeChange_$paramKey'),
                  onPressed: _proposingVote ? null : () => _proposeParamChange(
                    paramKey:    paramKey,
                    paramName:   title,
                    description: desc,
                    options:     options,
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _teal.withAlpha(200),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                    elevation: 0,
                    textStyle: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 11),
                  ),
                  child: const Text('PROPOSE CHANGE'),
                ),
              ),
            ],
          ]),
        ),
      ]),
    );
  }

  Widget _buildProtocolItem({
    required String   tag,
    required IconData icon,
    required String   title,
    required String   desc,
    String?           govParamKey,  // e.g. 'sov_enclave' — null = no param yet
  }) {
    final isActivated = govParamKey != null && (_govParams[govParamKey] == '1');
    final voteActive  = !isActivated && (_protocolVoteActive[tag] ?? false);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isActivated
            ? const Color(0xFF0D2E1F)   // subtle green tint when active
            : _cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isActivated
              ? const Color(0xFF00C853).withAlpha(60)
              : Colors.white.withAlpha(10),
        ),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon,
            color: isActivated ? const Color(0xFF00C853) : _gold, size: 22),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Text(title,
                    style: const TextStyle(color: Colors.white,
                        fontWeight: FontWeight.bold, fontSize: 13)),
              ),
              if (isActivated)
                _chip('ACTIVE', const Color(0xFF00C853))
              else if (voteActive)
                _chip('VOTE IN PROGRESS', Colors.lightBlueAccent)
              else
                _chip('DORMANT', Colors.white38),
            ]),
            const SizedBox(height: 5),
            Text(desc,
                style: const TextStyle(
                    color: Colors.white54, fontSize: 12, height: 1.5)),
            if (isActivated) ...[
              const SizedBox(height: 10),
              // Citizens can petition to deactivate an active protocol
              SizedBox(
                height: 34,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.draw_rounded, size: 12),
                  label: const Text('PETITION TO DEACTIVATE',
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                  onPressed: _submittingPetition ? null : () => _createPetitionSheet(
                    paramKey:     govParamKey,
                    protocolName: title,
                    direction:    'deactivate',
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.orangeAccent,
                    side: BorderSide(color: Colors.orangeAccent.withAlpha(120)),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ),
            ] else if (!voteActive) ...[
              const SizedBox(height: 10),
              SizedBox(
                height: 34,
                child: ElevatedButton(
                  onPressed: _proposingVote ? null : () => _proposeVote(
                    tag:          tag,
                    protocolName: title,
                    description:  desc,
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _gold.withAlpha(220),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                    elevation: 0,
                    textStyle: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 11),
                  ),
                  child: const Text('PROPOSE VOTE'),
                ),
              ),
            ],
          ]),
        ),
      ]),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // TAB 3 — VOTES
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildVotesTab() {
    final polls = _showCompleted ? _completedPolls : _activePolls;

    return RefreshIndicator(
      onRefresh: _loadPolls,
      color: _gold,
      backgroundColor: _cardBg,
      child: CustomScrollView(
        key: const ValueKey('votesList'),
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          // ── Filter toggle ─────────────────────────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Row(children: [
                Expanded(
                  child: _filterBtn(
                    'Active',
                    !_showCompleted,
                    () => setState(() => _showCompleted = false),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _filterBtn(
                    'Completed',
                    _showCompleted,
                    () => setState(() => _showCompleted = true),
                  ),
                ),
              ]),
            ),
          ),

          // ── Content ───────────────────────────────────────────────────────
          if (_loadingPolls)
            const SliverFillRemaining(
              child: Center(child: CircularProgressIndicator(
                  color: _gold, strokeWidth: 1.5)),
            )
          else if (polls.isEmpty)
            SliverFillRemaining(
              child: _emptyState(
                _showCompleted
                    ? 'No completed votes yet.'
                    : 'No active proposals yet.',
                _showCompleted
                    ? ''
                    : 'Be the first to propose a network change from the Constitution tab.',
              ),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (_, i) => Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: _buildPollCard(polls[i]),
                ),
                childCount: polls.length,
              ),
            ),

          const SliverToBoxAdapter(child: SizedBox(height: 40)),
        ],
      ),
    );
  }

  Widget _buildPollCard(Map<String, dynamic> poll) {
    final question   = poll['question']   as String? ?? 'Untitled poll';
    final options    = List<String>.from(poll['options'] ?? []);
    final voteCounts = List<int>.from(poll['tally'] ?? []);
    final totalVotes = (poll['total_votes'] as num?)?.toInt() ?? 0;
    final myVote     = poll['my_vote'];
    final closeEpoch = (poll['close_epoch'] as num?)?.toInt() ?? 0;
    final isOpen     = poll['status'] != 'closed';
    final nowEpoch   = DateTime.now().millisecondsSinceEpoch ~/ 60000;
    final minsLeft   = closeEpoch - nowEpoch;
    final hasVoted   = myVote != null;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withAlpha(12)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          _chip(isOpen ? 'ACTIVE' : 'CLOSED',
              isOpen ? Colors.greenAccent : Colors.white38),
          const Spacer(),
          if (isOpen)
            Row(children: [
              const Icon(Icons.access_time_rounded,
                  color: Colors.white38, size: 12),
              const SizedBox(width: 4),
              Text(_formatTimeLeft(minsLeft),
                  style: const TextStyle(color: Colors.white38, fontSize: 11)),
            ]),
        ]),
        const SizedBox(height: 12),
        Text(question,
            style: const TextStyle(color: Colors.white,
                fontSize: 15, fontWeight: FontWeight.w600, height: 1.4)),
        const SizedBox(height: 4),
        Builder(builder: (_) {
          final quorumNeeded  = (poll['quorum_needed']  as num?)?.toInt();
          final quorumReached = poll['quorum_reached'] == true;
          return Row(children: [
            Text('$totalVotes vote${totalVotes == 1 ? '' : 's'} cast',
                style: const TextStyle(color: Colors.white38, fontSize: 11)),
            if (quorumNeeded != null) ...[
              const SizedBox(width: 8),
              const Text('·',
                  style: TextStyle(color: Colors.white38, fontSize: 11)),
              const SizedBox(width: 8),
              Icon(quorumReached ? Icons.check_circle_rounded : Icons.pending_rounded,
                  color: quorumReached ? Colors.greenAccent : Colors.white38,
                  size: 11),
              const SizedBox(width: 3),
              Text('quorum $quorumNeeded needed',
                  style: TextStyle(
                      color: quorumReached ? Colors.greenAccent : Colors.white38,
                      fontSize: 11)),
            ],
          ]);
        }),
        const SizedBox(height: 14),

        ...options.asMap().entries.map((entry) {
          final idx      = entry.key;
          final option   = entry.value;
          final count    = idx < voteCounts.length ? voteCounts[idx] : 0;
          final percent  = totalVotes > 0 ? count / totalVotes : 0.0;
          final isMyVote = myVote == idx;
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Text(option,
                      style: TextStyle(
                          color: isMyVote ? _goldBr : Colors.white70,
                          fontSize: 13,
                          fontWeight: isMyVote
                              ? FontWeight.w600 : FontWeight.normal)),
                ),
                if (isMyVote)
                  const Icon(Icons.check_circle_rounded,
                      color: _goldBr, size: 14),
                const SizedBox(width: 6),
                Text('${(percent * 100).toStringAsFixed(0)}%',
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 11)),
              ]),
              const SizedBox(height: 4),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: percent,
                  minHeight: 4,
                  backgroundColor: Colors.white.withAlpha(10),
                  valueColor: AlwaysStoppedAnimation<Color>(
                      isMyVote ? _gold : Colors.white30),
                ),
              ),
              if (isOpen && !hasVoted) ...[
                const SizedBox(height: 6),
                SizedBox(
                  width: double.infinity,
                  height: 36,
                  child: OutlinedButton(
                    key: ValueKey('voteOption_$idx'),
                    onPressed: () => _vote(poll['poll_id'] as String? ?? '', option),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _goldBr,
                      side: BorderSide(color: _gold.withAlpha(120)),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                      padding: EdgeInsets.zero,
                    ),
                    child: Text('Vote for "$option"',
                        style: const TextStyle(fontSize: 12,
                            fontWeight: FontWeight.w600)),
                  ),
                ),
              ],
            ]),
          );
        }),
      ]),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // TAB 4 — PETITIONS
  // ═══════════════════════════════════════════════════════════════════════════

  // Map of tag → { govParamKey, title } for all known governable protocols
  static const _knownProtocols = [
    { 'tag': 'sov_enclave',           'govParamKey': 'sov_enclave',  'title': 'SOV Enclave'           },
    { 'tag': 'sov_request',         'govParamKey': 'sov_request',    'title': 'SOV Payment Links'     },
    { 'tag': 'sov_login',           'govParamKey': 'sov_login',      'title': 'SOV Login'             },
    { 'tag': 'privacy_toggle',      'govParamKey': 'balance_privacy','title': 'Balance Privacy Mode'  },
    { 'tag': 'relay_staking',       'govParamKey': 'relay_staking',  'title': 'Relay Staking Rewards' },
    { 'tag': 'merit_pool',          'govParamKey': 'merit_pool',     'title': 'Citizen Merit Pool'    },
    { 'tag': 'sov_escrow_api',      'govParamKey': 'sov_escrow_api', 'title': 'Merchant Escrow API'   },
    { 'tag': 'nfc_id',              'govParamKey': 'nfc_id',         'title': 'NFC Identity Tap'      },
  ];

  Widget _buildPetitionsTab() {
    // Build list of currently-active protocols (value = '1')
    final activeProtocols = _knownProtocols
        .where((p) => _govParams[p['govParamKey']] == '1')
        .toList();

    return RefreshIndicator(
      onRefresh: () async { await _loadPetitions(); await _loadPolls(); },
      color: _gold,
      backgroundColor: _cardBg,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 40),
        children: [

          // ── Explainer ─────────────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: _gold.withAlpha(15),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: _gold.withAlpha(40)),
            ),
            child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(Icons.info_outline_rounded, color: _gold, size: 15),
                SizedBox(width: 8),
                Text('How Petitions Work',
                    style: TextStyle(color: _goldBr,
                        fontWeight: FontWeight.bold, fontSize: 13)),
              ]),
              SizedBox(height: 8),
              Text(
                '• Any citizen can start a petition to deactivate an active protocol or reactivate a dormant one.\n'
                '• At 33% of enrolled citizens signing → a formal governance poll is automatically created.\n'
                '• At 67% (supermajority) → the parameter is flipped directly without a poll.\n'
                '• Petitions expire after 30 days if thresholds are not met.',
                style: TextStyle(color: Colors.white54, fontSize: 11, height: 1.7),
              ),
            ]),
          ),
          const SizedBox(height: 20),

          // ── Active Protocols — Petition to Deactivate ─────────────────────
          _sectionHeader(Icons.shield_rounded, 'Active Protocols'),
          const SizedBox(height: 4),
          const Text(
            'These protocols are currently active. Start a petition if you believe one should be deactivated.',
            style: TextStyle(color: Colors.white38, fontSize: 11, height: 1.5),
          ),
          const SizedBox(height: 12),

          if (_loadingPolls)
            _loadingIndicator()
          else if (activeProtocols.isEmpty)
            _emptyState(
              'No protocols are active yet.',
              'Protocols activated by governance votes will appear here.',
            )
          else
            ...activeProtocols.map((p) {
              final paramKey = p['govParamKey']!;
              final title    = p['title']!;
              // Check if there's already an open petition to deactivate this
              final existingPetition = _petitions.firstWhere(
                (pet) => pet['param_key'] == paramKey
                    && pet['direction'] == 'deactivate'
                    && pet['status'] == 'open',
                orElse: () => {},
              );
              final hasPetition = existingPetition.isNotEmpty;
              return _buildActivePetitionRow(
                paramKey:       paramKey,
                title:          title,
                hasPetition:    hasPetition,
                petitionId:     existingPetition['petition_id'] as String?,
                sigCount:       (existingPetition['signature_count'] as num?)?.toInt() ?? 0,
              );
            }),

          const SizedBox(height: 24),

          // ── Open Petitions ────────────────────────────────────────────────
          Row(children: [
            Expanded(child: _sectionHeader(Icons.draw_rounded, 'Open Petitions')),
            TextButton.icon(
              icon: const Icon(Icons.refresh_rounded, size: 12, color: _gold),
              label: const Text('Refresh', style: TextStyle(color: _gold, fontSize: 11)),
              onPressed: _loadPetitions,
              style: TextButton.styleFrom(padding: EdgeInsets.zero),
            ),
          ]),
          const SizedBox(height: 8),

          if (_loadingPetitions)
            _loadingIndicator()
          else if (_petitions.isEmpty)
            _emptyState(
              'No open petitions.',
              'Start the first one using an active protocol above.',
            )
          else
            ..._petitions.map(_buildPetitionCard),
        ],
      ),
    );
  }

  Widget _buildActivePetitionRow({
    required String  paramKey,
    required String  title,
    required bool    hasPetition,
    String?          petitionId,
    int              sigCount = 0,
  }) {
    final pct = sigCount / _petitionEnrolled.clamp(1, 999999);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: hasPetition
              ? Colors.orangeAccent.withAlpha(60)
              : Colors.white.withAlpha(10),
        ),
      ),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: const TextStyle(color: Colors.white,
                    fontWeight: FontWeight.w600, fontSize: 13)),
            if (hasPetition) ...[
              const SizedBox(height: 6),
              Row(children: [
                Text('${(pct * 100).toStringAsFixed(0)}%  ($sigCount / $_petitionEnrolled)',
                    style: const TextStyle(color: Colors.orangeAccent, fontSize: 11)),
                const Spacer(),
                Text('Deactivate petition open',
                    style: TextStyle(color: Colors.orangeAccent.withAlpha(180),
                        fontSize: 10)),
              ]),
              const SizedBox(height: 4),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: pct.clamp(0.0, 1.0),
                  minHeight: 4,
                  backgroundColor: Colors.white.withAlpha(12),
                  valueColor: const AlwaysStoppedAnimation<Color>(Colors.orangeAccent),
                ),
              ),
            ],
          ]),
        ),
        const SizedBox(width: 12),
        if (hasPetition && petitionId != null)
          SizedBox(
            height: 34,
            child: OutlinedButton(
              onPressed: () => _signPetition(petitionId),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.orangeAccent,
                side: BorderSide(color: Colors.orangeAccent.withAlpha(120)),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text('Sign', style: TextStyle(fontSize: 11,
                  fontWeight: FontWeight.bold)),
            ),
          )
        else
          SizedBox(
            height: 34,
            child: OutlinedButton(
              onPressed: _submittingPetition ? null : () => _createPetitionSheet(
                paramKey:     paramKey,
                protocolName: title,
                direction:    'deactivate',
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.orangeAccent.withAlpha(200),
                side: BorderSide(color: Colors.white.withAlpha(30)),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text('Start Petition',
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
            ),
          ),
      ]),
    );
  }

  Widget _buildPetitionCard(Map<String, dynamic> petition) {
    final petitionId  = petition['petition_id'] as String? ?? '';
    final paramKey    = petition['param_key']   as String? ?? '';
    final direction   = petition['direction']   as String? ?? 'deactivate';
    final title       = petition['title']       as String? ?? 'Untitled';
    final description = petition['description'] as String?;
    final sigCount    = (petition['signature_count'] as num?)?.toInt() ?? 0;
    final expiresAt   = (petition['expires_at'] as num?)?.toInt() ?? 0;
    final createdBy   = petition['created_by']  as String? ?? '';

    final pct          = sigCount / _petitionEnrolled.clamp(1, 999999);
    const threshold    = 0.33;
    const supermaj     = 0.67;
    final msLeft       = expiresAt - DateTime.now().millisecondsSinceEpoch;
    final daysLeft     = msLeft > 0 ? (msLeft / 86400000).ceil() : 0;
    final isDeactivate = direction == 'deactivate';
    final accentColor  = isDeactivate ? Colors.orangeAccent : const Color(0xFF00C853);

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accentColor.withAlpha(50)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Header row
        Row(children: [
          Icon(
            isDeactivate ? Icons.remove_circle_outline_rounded
                         : Icons.add_circle_outline_rounded,
            color: accentColor, size: 14,
          ),
          const SizedBox(width: 6),
          _chip(
            isDeactivate ? 'DEACTIVATE' : 'REACTIVATE',
            accentColor,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(paramKey,
                style: const TextStyle(color: Colors.white38,
                    fontSize: 10, fontFamily: 'monospace')),
          ),
          if (daysLeft > 0)
            Text('$daysLeft d left',
                style: const TextStyle(color: Colors.white38, fontSize: 10)),
        ]),
        const SizedBox(height: 10),

        // Title
        Text(title,
            style: const TextStyle(color: Colors.white,
                fontWeight: FontWeight.w600, fontSize: 13, height: 1.4)),
        if (description != null && description.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white38,
                  fontSize: 11, height: 1.5)),
        ],
        const SizedBox(height: 12),

        // Progress bar
        Row(children: [
          Text('$sigCount / $_petitionEnrolled enrolled',
              style: const TextStyle(color: Colors.white54, fontSize: 11)),
          const Spacer(),
          Text('${(pct * 100).toStringAsFixed(0)}%',
              style: TextStyle(
                  color: pct >= supermaj ? Colors.greenAccent
                       : pct >= threshold ? accentColor
                       : Colors.white38,
                  fontSize: 11, fontWeight: FontWeight.bold)),
        ]),
        const SizedBox(height: 6),
        Stack(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: pct.clamp(0.0, 1.0),
              minHeight: 6,
              backgroundColor: Colors.white.withAlpha(12),
              valueColor: AlwaysStoppedAnimation<Color>(
                  pct >= supermaj ? Colors.greenAccent
                : pct >= threshold ? accentColor
                : accentColor.withAlpha(150)),
            ),
          ),
          // Threshold marker at 33%
          Positioned(
            left: MediaQuery.of(context).size.width * 0.33 * 0.7,
            top: 0, bottom: 0,
            child: Container(width: 1.5, color: Colors.white24),
          ),
        ]),
        const SizedBox(height: 4),
        const Row(children: [
          Text('33% → poll', style: TextStyle(
              color: Colors.white24, fontSize: 9)),
          Spacer(),
          Text('67% → direct flip', style: TextStyle(
              color: Colors.white24, fontSize: 9)),
        ]),
        const SizedBox(height: 12),

        // Creator + Sign button
        Row(children: [
          const Icon(Icons.person_outline_rounded,
              color: Colors.white24, size: 12),
          const SizedBox(width: 4),
          Text('by ${_shortId(createdBy)}',
              style: const TextStyle(color: Colors.white24, fontSize: 10)),
          const Spacer(),
          SizedBox(
            height: 36,
            child: ElevatedButton(
              onPressed: () => _signPetition(petitionId),
              style: ElevatedButton.styleFrom(
                backgroundColor: accentColor.withAlpha(220),
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(horizontal: 18),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
                elevation: 0,
                textStyle: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 12),
              ),
              child: const Text('Sign Petition'),
            ),
          ),
        ]),
      ]),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // SHARED WIDGETS
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _sectionHeader(IconData icon, String text) {
    return Row(children: [
      Icon(icon, color: _gold, size: 15),
      const SizedBox(width: 8),
      Text(text,
          style: const TextStyle(color: Colors.white54,
              fontSize: 11, fontWeight: FontWeight.w700,
              letterSpacing: 1.0)),
    ]);
  }

  Widget _loadingIndicator() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 20),
      child: Center(child: CircularProgressIndicator(
          color: _gold, strokeWidth: 1.5)),
    );
  }

  Widget _emptyState(String title, String subtitle) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title,
            style: const TextStyle(color: Colors.white60,
                fontSize: 13, fontWeight: FontWeight.w600)),
        if (subtitle.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(subtitle,
              style: const TextStyle(color: Colors.white38,
                  fontSize: 12, height: 1.5)),
        ],
      ]),
    );
  }

  Widget _filterBtn(String label, bool active, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: active ? _gold.withAlpha(220) : Colors.white.withAlpha(10),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Center(
          child: Text(label,
              style: TextStyle(
                color: active ? Colors.black : Colors.white54,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              )),
        ),
      ),
    );
  }

  Widget _chip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withAlpha(25),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withAlpha(80)),
      ),
      child: Text(label,
          style: TextStyle(color: color, fontSize: 9,
              fontWeight: FontWeight.bold)),
    );
  }

  Widget _tallyChip(IconData icon, Color color, String label) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 11, color: color),
      const SizedBox(width: 3),
      Text(label, style: TextStyle(color: color, fontSize: 10,
          fontWeight: FontWeight.w600)),
    ]);
  }

  Widget _fieldLabel(String label) {
    return Text(label,
        style: const TextStyle(color: Colors.white54, fontSize: 11,
            fontWeight: FontWeight.w600));
  }

  InputDecoration _inputDecor(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Colors.white24, fontSize: 12),
      filled: true,
      fillColor: Colors.white.withAlpha(8),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: Colors.white.withAlpha(30)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: Colors.white.withAlpha(20)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: _gold, width: 1.2),
      ),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    );
  }
}

// ─── Verdict button widget ────────────────────────────────────────────────────

class _VerdictBtn extends StatelessWidget {
  final String    label;
  final String    sub;
  final Color     color;
  final IconData  icon;
  final VoidCallback onTap;
  const _VerdictBtn({
    required this.label,
    required this.sub,
    required this.color,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: color.withAlpha(18),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withAlpha(80)),
        ),
        child: Row(children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label,
                  style: TextStyle(color: color, fontWeight: FontWeight.bold,
                      fontSize: 13)),
              const SizedBox(height: 2),
              Text(sub, style: const TextStyle(color: Colors.white38,
                  fontSize: 11)),
            ]),
          ),
        ]),
      ),
    );
  }
}
