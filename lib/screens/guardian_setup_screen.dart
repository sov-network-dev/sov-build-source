// lib/screens/guardian_setup_screen.dart
// Screen 6 — Guardian Setup (optional, skippable)
//
// Per-field relay disc validation:
//   Each guardian ID is queried against the relay (SOV_BALANCE_QUERY) as the
//   citizen types, with 800 ms debounce. A green checkmark appears when the
//   relay confirms the ID is an enrolled citizen. The Submit button requires
//   all three fields to pass validation before the relay nomination is sent.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../sov_node_sdk/relay_connector.dart';
import '../sov_node_sdk/draft_manager.dart';
import '../sov_node_sdk/draft_keys.dart';

enum _VerifyState { idle, loading, ok, fail }

class GuardianSetupScreen extends StatefulWidget {
  final String sovereignId;
  const GuardianSetupScreen({super.key, required this.sovereignId});

  @override
  State<GuardianSetupScreen> createState() => _GuardianSetupScreenState();
}

class _GuardianSetupScreenState extends State<GuardianSetupScreen> {
  static const _navy   = Color(0xFF0A1628);
  static const _gold   = Color(0xFFB8960C);
  static const _cardBg = Color(0xFF0D1F3A);
  static const _teal   = Color(0xFF006B5E);

  final _g1      = TextEditingController();
  final _g2      = TextEditingController();
  final _g3      = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  // Per-field disc verification state
  _VerifyState _v1 = _VerifyState.idle;
  _VerifyState _v2 = _VerifyState.idle;
  _VerifyState _v3 = _VerifyState.idle;

  // Debounce timers — cancelled on each keystroke, fired 800 ms after last key
  Timer? _t1;
  Timer? _t2;
  Timer? _t3;

  bool   _submitting = false;
  String _error      = '';
  bool   _done       = false;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _loadExisting();
    _loadDrafts();
  }

  /// Load any in-progress guardian ID drafts typed before app was backgrounded.
  Future<void> _loadDrafts() async {
    final d1 = await DraftManager.load(DraftKeys.guardianId1);
    final d2 = await DraftManager.load(DraftKeys.guardianId2);
    final d3 = await DraftManager.load(DraftKeys.guardianId3);
    if (!mounted) return;
    // Only restore draft if the field doesn't already have a confirmed value
    if (d1.isNotEmpty && _g1.text.isEmpty) {
      _g1.text = d1;
      _g1.selection = TextSelection.fromPosition(TextPosition(offset: d1.length));
    }
    if (d2.isNotEmpty && _g2.text.isEmpty) {
      _g2.text = d2;
      _g2.selection = TextSelection.fromPosition(TextPosition(offset: d2.length));
    }
    if (d3.isNotEmpty && _g3.text.isEmpty) {
      _g3.text = d3;
      _g3.selection = TextSelection.fromPosition(TextPosition(offset: d3.length));
    }
  }

  @override
  void dispose() {
    _g1.dispose(); _g2.dispose(); _g3.dispose();
    _t1?.cancel(); _t2?.cancel(); _t3?.cancel();
    super.dispose();
  }

  Future<void> _loadExisting() async {
    final prefs = await SharedPreferences.getInstance();
    final g1 = prefs.getString('guardian_1_id') ?? '';
    final g2 = prefs.getString('guardian_2_id') ?? '';
    final g3 = prefs.getString('guardian_3_id') ?? '';
    if (!mounted) return;
    setState(() {
      _g1.text = g1;
      _g2.text = g2;
      _g3.text = g3;
      _done = prefs.getBool('guardian_setup_done') ?? false;
    });
    // Immediately verify previously saved IDs
    if (g1.isNotEmpty) _verify(1, g1);
    if (g2.isNotEmpty) _verify(2, g2);
    if (g3.isNotEmpty) _verify(3, g3);
  }

  // ── Per-field validation ───────────────────────────────────────────────────

  void _onChanged(int slot, String value) {
    // Save draft for this slot
    if (slot == 1)      { DraftManager.save(DraftKeys.guardianId1, value); }
    else if (slot == 2) { DraftManager.save(DraftKeys.guardianId2, value); }
    else                { DraftManager.save(DraftKeys.guardianId3, value); }

    // Cancel pending debounce for this slot
    if (slot == 1) { _t1?.cancel(); _t1 = null; }
    else if (slot == 2) { _t2?.cancel(); _t2 = null; }
    else { _t3?.cancel(); _t3 = null; }

    // Reset to idle immediately so stale result doesn't linger
    _setVerify(slot, _VerifyState.idle);

    final id = value.trim().toUpperCase();
    if (id.length < 10) return; // Too short to be valid

    // Arm debounce — fire 800 ms after last keystroke
    final timer = Timer(const Duration(milliseconds: 800), () => _verify(slot, id));
    if (slot == 1)      { _t1 = timer; }
    else if (slot == 2) { _t2 = timer; }
    else                { _t3 = timer; }
  }

  void _setVerify(int slot, _VerifyState s) {
    if (!mounted) return;
    setState(() {
      if (slot == 1)      { _v1 = s; }
      else if (slot == 2) { _v2 = s; }
      else                { _v3 = s; }
    });
  }

  _VerifyState _getVerify(int slot) {
    if (slot == 1) return _v1;
    if (slot == 2) return _v2;
    return _v3;
  }

  /// Query the relay to confirm [id] is an enrolled citizen.
  Future<void> _verify(int slot, String id) async {
    final clean = id.trim().toUpperCase();
    if (!clean.startsWith('SOV-') || clean.length < 10) {
      _setVerify(slot, _VerifyState.idle);
      return;
    }
    // Self-nomination: instant fail
    if (clean == widget.sovereignId) {
      _setVerify(slot, _VerifyState.fail);
      return;
    }
    _setVerify(slot, _VerifyState.loading);
    try {
      if (!RelayConnector.isConnected) await RelayConnector.connect();
      final resp = await RelayConnector.sendAndWait(
        request:      {'type': 'SOV_BALANCE_QUERY', 'sovereign_id': clean},
        responseType: 'SOV_BALANCE_RESULT',
        timeout:      const Duration(seconds: 8),
      );
      if (!mounted) return;
      _setVerify(slot, resp?['success'] == true ? _VerifyState.ok : _VerifyState.fail);
    } catch (_) {
      if (mounted) _setVerify(slot, _VerifyState.fail);
    }
  }

  bool get _allVerified =>
      _v1 == _VerifyState.ok &&
      _v2 == _VerifyState.ok &&
      _v3 == _VerifyState.ok;

  // ── Submit ────────────────────────────────────────────────────────────────

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (!_allVerified) {
      setState(() => _error =
          'All three guardians must be verified enrolled citizens before submitting.');
      return;
    }
    setState(() { _submitting = true; _error = ''; });
    try {
      if (!RelayConnector.isConnected) await RelayConnector.connect();
      // The node has no batch GUARDIAN_NOMINATE handler (that op belonged to the
      // retired legacy relay). sov-node registers guardians one at a time via
      // GUARDIAN_ADD → GUARDIAN_ADD_RESULT, storing to sov_guardians and inviting
      // each guardian. Add all three; the nomination only succeeds if all land.
      final ids = [
        _g1.text.trim().toUpperCase(),
        _g2.text.trim().toUpperCase(),
        _g3.text.trim().toUpperCase(),
      ];
      String? failure;
      for (final gid in ids) {
        final resp = await RelayConnector.addGuardian(
          citizenId: widget.sovereignId,
          guardianId: gid,
        );
        if (resp?['success'] != true) {
          failure = resp?['error'] as String? ?? 'Guardian $gid could not be added';
          break;
        }
      }
      if (failure == null) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('guardian_setup_done', true);
        await prefs.setString('guardian_1_id', ids[0]);
        await prefs.setString('guardian_2_id', ids[1]);
        await prefs.setString('guardian_3_id', ids[2]);
        // Clear guardian drafts — nomination succeeded
        await DraftManager.clearAll(DraftKeys.guardianAll);
        if (mounted) { setState(() { _done = true; _submitting = false; }); }
      } else {
        if (mounted) { setState(() {
          _error = failure ?? 'Guardian nomination failed';
          _submitting = false;
        }); }
      }
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _submitting = false; });
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  /// Suffix icon that reflects per-field verification state.
  Widget _verifyIcon(_VerifyState state) {
    switch (state) {
      case _VerifyState.idle:
        return const SizedBox.shrink();
      case _VerifyState.loading:
        return const SizedBox(
          width: 18, height: 18,
          child: CircularProgressIndicator(
              strokeWidth: 2, color: Color(0xFFB8960C)),
        );
      case _VerifyState.ok:
        return const Icon(Icons.check_circle_rounded,
            color: Color(0xFF4CAF50), size: 22);
      case _VerifyState.fail:
        return const Icon(Icons.cancel_rounded,
            color: Colors.redAccent, size: 22);
    }
  }

  Widget _guardianField(TextEditingController ctrl, String label, int num) {
    final state = _getVerify(num);
    final Color? borderColor = state == _VerifyState.ok
        ? const Color(0xFF4CAF50)
        : state == _VerifyState.fail
            ? Colors.redAccent
            : null;

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  color: Colors.white38, fontSize: 11, letterSpacing: 1.5)),
          const SizedBox(height: 8),
          TextFormField(
            controller: ctrl,
            style: const TextStyle(
                color: Colors.white, fontFamily: 'monospace', fontSize: 13),
            textCapitalization: TextCapitalization.characters,
            onChanged: (v) => _onChanged(num, v),
            decoration: InputDecoration(
              hintText: 'SOV-XXXXXXXXXXXXXXXX',
              hintStyle: TextStyle(color: Colors.white.withAlpha(51)),
              filled:    true,
              fillColor: _cardBg,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                    color: borderColor ?? Colors.white.withAlpha(26))),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                    color: borderColor ?? Colors.white.withAlpha(26))),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                    color: borderColor ?? const Color(0xFFB8960C))),
              prefixIcon: CircleAvatar(
                radius: 14,
                backgroundColor: _gold.withAlpha(26),
                child: Text('$num',
                    style: const TextStyle(
                        color: Color(0xFFB8960C),
                        fontSize: 13,
                        fontWeight: FontWeight.bold)),
              ),
              suffixIcon: Padding(
                padding: const EdgeInsets.only(right: 12),
                child: _verifyIcon(state),
              ),
              suffixIconConstraints:
                  const BoxConstraints(minWidth: 44, minHeight: 44),
            ),
            validator: (v) {
              if (v == null || v.trim().isEmpty) {
                return 'Enter guardian $num Sovereign ID';
              }
              final clean = v.trim().toUpperCase();
              if (clean == widget.sovereignId) return 'Cannot be yourself';
              if (!clean.startsWith('SOV-')) return 'Must start with SOV-';
              return null;
            },
          ),
          // Inline status line below each field
          if (state == _VerifyState.ok)
            const Padding(
              padding: EdgeInsets.only(left: 52, top: 4, bottom: 8),
              child: Text('Enrolled citizen ✓',
                  style: TextStyle(color: Color(0xFF4CAF50), fontSize: 11)),
            )
          else if (state == _VerifyState.fail)
            Padding(
              padding: const EdgeInsets.only(left: 52, top: 4, bottom: 8),
              child: Text(
                ctrl.text.trim().toUpperCase() == widget.sovereignId
                    ? 'Cannot nominate yourself'
                    : 'Not an enrolled citizen',
                style:
                    const TextStyle(color: Colors.redAccent, fontSize: 11),
              ),
            )
          else
            const SizedBox(height: 12),
        ],
      ),
    );
  }

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
        title: const Text('Guardian Setup',
            style: TextStyle(
                color: Color(0xFFB8960C),
                fontWeight: FontWeight.bold,
                fontSize: 18)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Explainer ──────────────────────────────────────────────────
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: _teal.withAlpha(26),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _teal.withAlpha(77)),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('What are Guardians?',
                        style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 14)),
                    SizedBox(height: 8),
                    Text(
                      'Guardians are 3 trusted people who can collectively help recover '
                      'your account if you lose access. They never control your funds — '
                      'they only hold recovery fragments verified by the network.',
                      style: TextStyle(
                          color: Colors.white54, fontSize: 13, height: 1.5),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // ── Already configured banner ───────────────────────────────
              if (_done) ...[
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: _teal.withAlpha(51),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _teal.withAlpha(128)),
                  ),
                  child: const Row(children: [
                    Icon(Icons.check_circle_rounded,
                        color: Color(0xFF4CAF50)),
                    SizedBox(width: 12),
                    Text('Guardians configured',
                        style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold)),
                  ]),
                ),
                const SizedBox(height: 20),
              ],

              // ── Guardian fields ─────────────────────────────────────────
              _guardianField(_g1, 'GUARDIAN 1 SOVEREIGN ID', 1),
              _guardianField(_g2, 'GUARDIAN 2 SOVEREIGN ID', 2),
              _guardianField(_g3, 'GUARDIAN 3 SOVEREIGN ID', 3),

              // ── Verification hint ───────────────────────────────────────
              if (!_allVerified && (_v1 != _VerifyState.idle ||
                  _v2 != _VerifyState.idle || _v3 != _VerifyState.idle)) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Icon(Icons.info_outline,
                        color: Colors.white24, size: 14),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'All three guardians must show ✓ before you can submit.',
                        style: TextStyle(
                            color: Colors.white.withAlpha(80), fontSize: 11),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
              ],

              // ── Error ───────────────────────────────────────────────────
              if (_error.isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.withAlpha(26),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.red.withAlpha(77)),
                  ),
                  child: Text(_error,
                      style: const TextStyle(
                          color: Colors.redAccent, fontSize: 13)),
                ),
              ],

              const SizedBox(height: 24),

              // ── Submit ──────────────────────────────────────────────────
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: (_submitting || !_allVerified) ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _gold,
                    disabledBackgroundColor: _gold.withAlpha(60),
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                    elevation: 0,
                  ),
                  child: _submitting
                      ? const SizedBox(
                          width: 22, height: 22,
                          child: CircularProgressIndicator(
                              color: Colors.black, strokeWidth: 2.5))
                      : Text(
                          _done ? 'Update Guardians' : 'Nominate Guardians',
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ),

              const SizedBox(height: 16),
              Center(
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Skip / Set Up Later',
                      style:
                          TextStyle(color: Colors.white38, fontSize: 14)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
