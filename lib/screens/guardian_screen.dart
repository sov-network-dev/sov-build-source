// lib/screens/guardian_screen.dart
// S10 — SOV Guardian Recovery
// Manage guardian list + initiate/approve/reject recovery requests.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../sov_node_sdk/relay_connector.dart';
import '../sov_node_sdk/key_manager.dart';

class GuardianScreen extends StatefulWidget {
  const GuardianScreen({super.key});

  @override
  State<GuardianScreen> createState() => _GuardianScreenState();
}

class _GuardianScreenState extends State<GuardianScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;

  String _sovereignId = '';
  bool   _hasEnrolledKey = false;

  // My Guardians tab
  List<Map<String, dynamic>> _guardians = [];
  bool _loadingGuardians = true;

  // Incoming requests tab (GUARDIAN_APPROVAL_REQUEST events pending in-memory)
  final List<Map<String, dynamic>> _pendingApprovals = [];

  // Recovery tab
  final _recoveryIdCtrl  = TextEditingController();
  bool _initiating       = false;
  String _recoveryStatus = '';

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    _init();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _recoveryIdCtrl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    final id    = prefs.getString('sovereign_id') ?? '';
    // Check if private key exists
    String? privKey;
    try {
      privKey = await KeyManager.getPublicKey(); // presence of public key = device is initialised
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _sovereignId   = id;
      _hasEnrolledKey = (privKey != null && privKey.isNotEmpty);
    });
    if (id.isNotEmpty) await _loadGuardians();
  }

  Future<void> _loadGuardians() async {
    if (_sovereignId.isEmpty) return;
    setState(() => _loadingGuardians = true);
    try {
      final list = await RelayConnector.listGuardians(_sovereignId);
      if (!mounted) return;
      setState(() {
        _guardians       = list;
        _loadingGuardians = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingGuardians = false);
    }
  }

  Future<void> _addGuardian(String guardianId) async {
    if (_sovereignId.isEmpty || guardianId.isEmpty) return;
    final res = await RelayConnector.addGuardian(
      citizenId:  _sovereignId,
      guardianId: guardianId.toUpperCase().trim(),
    );
    if (!mounted) return;
    if (res != null && res['success'] == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Guardian added — they have been notified'),
          backgroundColor: Color(0xFF4CAF50),
        ),
      );
      await _loadGuardians();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(res?['error'] ?? 'Failed to add guardian'),
          backgroundColor: Colors.red[700],
        ),
      );
    }
  }

  Future<void> _removeGuardian(String guardianId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF0D1F3A),
        title: const Text('Remove Guardian', style: TextStyle(color: Color(0xFFD4AF37))),
        content: Text(
          'Remove $guardianId from your guardian list?\n\nThey will no longer be able to approve recovery requests.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel', style: TextStyle(color: Colors.white38))),
          TextButton(onPressed: () => Navigator.pop(context, true),
              child: const Text('Remove', style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
    if (confirmed != true) return;
    final res = await RelayConnector.removeGuardian(
        citizenId: _sovereignId, guardianId: guardianId);
    if (!mounted) return;
    if (res != null && res['success'] == true) {
      await _loadGuardians();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Guardian removed'), backgroundColor: Color(0xFF4CAF50)));
    }
  }

  Future<void> _approveRequest(Map<String, dynamic> req) async {
    final res = await RelayConnector.approveGuardianRecovery(
      requestId:  req['request_id'] as String,
      guardianId: _sovereignId,
    );
    if (!mounted) return;
    if (res != null && res['success'] == true) {
      setState(() => _pendingApprovals.remove(req));
      final approved = res['approved'] == true;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(approved
            ? 'Recovery approved — citizen has been notified'
            : 'Approval recorded (${res['approvals_count']}/${res['threshold']} required)'),
        backgroundColor: approved ? const Color(0xFF4CAF50) : const Color(0xFFD4AF37),
      ));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(res?['error'] ?? 'Failed to approve'),
        backgroundColor: Colors.red[700],
      ));
    }
  }

  Future<void> _rejectRequest(Map<String, dynamic> req) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF0D1F3A),
        title: const Text('Reject Recovery', style: TextStyle(color: Colors.redAccent)),
        content: Text(
          'Reject recovery request from ${req['citizen_id']}?\n\n'
          'Only reject if you did not initiate this or suspect it is fraudulent.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel', style: TextStyle(color: Colors.white38))),
          TextButton(onPressed: () => Navigator.pop(context, true),
              child: const Text('Reject', style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
    if (confirmed != true) return;
    final res = await RelayConnector.rejectGuardianRecovery(
      requestId:  req['request_id'] as String,
      guardianId: _sovereignId,
    );
    if (!mounted) return;
    if (res != null && res['success'] == true) {
      setState(() => _pendingApprovals.remove(req));
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Recovery request rejected'), backgroundColor: Color(0xFF4CAF50)));
    }
  }

  Future<void> _initiateRecovery() async {
    final targetId = _recoveryIdCtrl.text.trim().toUpperCase();
    if (!targetId.startsWith('SOV-')) {
      setState(() => _recoveryStatus = 'Enter a valid Sovereign ID (SOV-XXXX…)');
      return;
    }
    setState(() { _initiating = true; _recoveryStatus = ''; });
    try {
      // Get this device's new public key
      final newPubKey = await KeyManager.getPublicKey();
      if (newPubKey == null || newPubKey.isEmpty) {
        setState(() { _initiating = false; _recoveryStatus = 'No key found on this device'; });
        return;
      }
      final requestId = '${targetId}_${DateTime.now().millisecondsSinceEpoch}';
      final res = await RelayConnector.initiateGuardianRecovery(
        citizenId:     targetId,
        newPubKeyHex:  newPubKey,
        requestId:     requestId,
      );
      if (!mounted) return;
      if (res != null && res['success'] == true) {
        final count = res['guardian_count'] ?? 0;
        setState(() {
          _initiating     = false;
          _recoveryStatus = 'Recovery request sent to $count guardian(s). '
              'Ask them to open their SOV app and approve your request.';
        });
      } else {
        setState(() {
          _initiating     = false;
          _recoveryStatus = res?['error'] ?? 'Recovery initiation failed';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() { _initiating = false; _recoveryStatus = e.toString(); });
    }
  }

  void _showAddGuardianSheet() {
    final ctrl = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0D1F3A),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
              left: 20, right: 20, top: 20,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Add Guardian',
                  style: TextStyle(color: Color(0xFFD4AF37), fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              const Text(
                'Enter the Sovereign ID of the citizen you trust to approve recovery requests. '
                'They must be an enrolled citizen.',
                style: TextStyle(color: Colors.white54, fontSize: 13),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: ctrl,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'SOV-XXXXXXXXXXXX',
                  hintStyle: const TextStyle(color: Colors.white24),
                  filled: true, fillColor: const Color(0xFF0A1628),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: Color(0xFFD4AF37))),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: Color(0xFFD4AF37))),
                  prefixIcon: const Icon(Icons.shield_outlined, color: Color(0xFFD4AF37)),
                ),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9\-]'))],
                textCapitalization: TextCapitalization.characters,
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFD4AF37),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: () {
                    Navigator.pop(ctx);
                    _addGuardian(ctrl.text);
                  },
                  child: const Text('Add Guardian', style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A1628),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A1628),
        elevation: 0,
        title: const Text('Guardians',
            style: TextStyle(color: Color(0xFFD4AF37), fontWeight: FontWeight.w700, fontSize: 18)),
        iconTheme: const IconThemeData(color: Color(0xFFD4AF37)),
        bottom: TabBar(
          controller: _tabs,
          labelColor: const Color(0xFFD4AF37),
          unselectedLabelColor: Colors.white38,
          indicatorColor: const Color(0xFFD4AF37),
          tabs: [
            const Tab(text: 'MY GUARDIANS'),
            Tab(
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Text('REQUESTS'),
                if (_pendingApprovals.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFFD4AF37),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text('${_pendingApprovals.length}',
                        style: const TextStyle(color: Colors.black, fontSize: 11, fontWeight: FontWeight.w700)),
                  ),
                ],
              ]),
            ),
            const Tab(text: 'RECOVERY'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _buildGuardiansTab(),
          _buildRequestsTab(),
          _buildRecoveryTab(),
        ],
      ),
    );
  }

  // ── Tab 1: My Guardians ──────────────────────────────────────────────────

  Widget _buildGuardiansTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _infoCard(
            icon: Icons.shield_rounded,
            color: const Color(0xFFD4AF37),
            text: 'Guardians are trusted citizens who can approve your account recovery if you lose your device. '
                'They cannot access your funds — they only confirm your identity.',
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('GUARDIANS',
                  style: TextStyle(color: Colors.white38, fontSize: 10,
                      fontWeight: FontWeight.w700, letterSpacing: 1.2)),
              IconButton(
                icon: const Icon(Icons.refresh_rounded, color: Color(0xFFD4AF37), size: 20),
                onPressed: _loadGuardians,
                tooltip: 'Refresh',
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_loadingGuardians)
            const Center(child: Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(color: Color(0xFFD4AF37)),
            ))
          else if (_guardians.isEmpty)
            _emptyState(
              icon: Icons.shield_outlined,
              message: 'No guardians yet',
              subMessage: 'Add trusted citizens who can help you recover your account.',
            )
          else
            ...(_guardians.map(_buildGuardianCard).toList()),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _sovereignId.isEmpty ? null : _showAddGuardianSheet,
              icon: const Icon(Icons.person_add_rounded, color: Color(0xFFD4AF37)),
              label: const Text('Add Guardian', style: TextStyle(color: Color(0xFFD4AF37))),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Color(0xFFD4AF37)),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGuardianCard(Map<String, dynamic> g) {
    final guardianId = g['guardian_id'] as String;
    final addedAt    = g['added_at'] as int? ?? 0;
    final dt         = DateTime.fromMillisecondsSinceEpoch(addedAt);
    final dateStr    = '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF0D1F3A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withAlpha(15)),
      ),
      child: Row(
        children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
              color: const Color(0xFFD4AF37).withAlpha(30),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.shield_rounded, color: Color(0xFFD4AF37), size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(guardianId,
                    style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text('Added $dateStr',
                    style: const TextStyle(color: Colors.white38, fontSize: 11)),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy_rounded, color: Colors.white24, size: 18),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: guardianId));
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Copied'), duration: Duration(seconds: 1)));
            },
            tooltip: 'Copy ID',
          ),
          IconButton(
            icon: const Icon(Icons.remove_circle_outline_rounded, color: Colors.redAccent, size: 20),
            onPressed: () => _removeGuardian(guardianId),
            tooltip: 'Remove',
          ),
        ],
      ),
    );
  }

  // ── Tab 2: Incoming Requests ──────────────────────────────────────────────

  Widget _buildRequestsTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _infoCard(
            icon: Icons.verified_user_rounded,
            color: const Color(0xFF64B5F6),
            text: 'When a citizen you are guarding needs account recovery, their request appears here. '
                'Only approve if you personally know the person and they have confirmed the request with you.',
          ),
          const SizedBox(height: 20),
          const Text('PENDING APPROVAL',
              style: TextStyle(color: Colors.white38, fontSize: 10,
                  fontWeight: FontWeight.w700, letterSpacing: 1.2)),
          const SizedBox(height: 8),
          if (_pendingApprovals.isEmpty)
            _emptyState(
              icon: Icons.verified_user_outlined,
              message: 'No pending requests',
              subMessage: 'When a citizen you guard needs recovery, it appears here.',
            )
          else
            ...(_pendingApprovals.map(_buildApprovalCard).toList()),
        ],
      ),
    );
  }

  Widget _buildApprovalCard(Map<String, dynamic> req) {
    final citizenId  = req['citizen_id'] as String? ?? '—';
    final expiresAt  = req['expires_at'] as int? ?? 0;
    final requestId  = req['request_id'] as String? ?? '';
    final hoursLeft  = ((expiresAt - DateTime.now().millisecondsSinceEpoch) / 3600000).floor();
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF0D1F3A),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFD4AF37).withAlpha(80)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.warning_amber_rounded, color: Color(0xFFD4AF37), size: 20),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('Recovery Request',
                    style: TextStyle(color: Color(0xFFD4AF37), fontWeight: FontWeight.w700, fontSize: 15)),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: hoursLeft > 12
                      ? const Color(0xFF4CAF50).withAlpha(40)
                      : Colors.red.withAlpha(40),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  hoursLeft > 0 ? '${hoursLeft}h left' : 'Expired',
                  style: TextStyle(
                    color: hoursLeft > 12 ? const Color(0xFF4CAF50) : Colors.redAccent,
                    fontSize: 11, fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _detailRow('Citizen', citizenId),
          _detailRow('Request ID', requestId.length > 20 ? '${requestId.substring(0, 20)}…' : requestId),
          const SizedBox(height: 14),
          const Text(
            '⚠️ Only approve if this person has personally confirmed the recovery with you.',
            style: TextStyle(color: Colors.white54, fontSize: 11),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _rejectRequest(req),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.redAccent),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Text('Reject', style: TextStyle(color: Colors.redAccent)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton(
                  onPressed: () => _approveRequest(req),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF4CAF50),
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Text('Approve', style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Tab 3: Recovery (fresh install) ──────────────────────────────────────

  Widget _buildRecoveryTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_hasEnrolledKey)
            _infoCard(
              icon: Icons.check_circle_rounded,
              color: const Color(0xFF4CAF50),
              text: 'Your account is active on this device. Recovery is only needed if you '
                  'install SOV on a new device after losing your original.',
            )
          else
            _infoCard(
              icon: Icons.lock_open_rounded,
              color: const Color(0xFFD4AF37),
              text: 'No account found on this device. Enter your Sovereign ID below to request '
                  'recovery. Your guardians will need to approve.',
            ),
          const SizedBox(height: 24),
          const Text('INITIATE RECOVERY',
              style: TextStyle(color: Colors.white38, fontSize: 10,
                  fontWeight: FontWeight.w700, letterSpacing: 1.2)),
          const SizedBox(height: 10),
          const Text(
            'Enter your Sovereign ID. This device\'s key will be sent to your guardians for approval. '
            'Once the required number approve, your account is restored on this device.',
            style: TextStyle(color: Colors.white54, fontSize: 13),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _recoveryIdCtrl,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'SOV-XXXXXXXXXXXX',
              hintStyle: const TextStyle(color: Colors.white24),
              labelText: 'Your Sovereign ID',
              labelStyle: const TextStyle(color: Colors.white54),
              filled: true, fillColor: const Color(0xFF0D1F3A),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Color(0xFF1A3A5C))),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Color(0xFFD4AF37))),
              prefixIcon: const Icon(Icons.fingerprint_rounded, color: Color(0xFFD4AF37)),
            ),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9\-]'))],
            textCapitalization: TextCapitalization.characters,
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _initiating ? null : _initiateRecovery,
              icon: _initiating
                  ? const SizedBox(width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                  : const Icon(Icons.send_rounded),
              label: Text(_initiating ? 'Sending…' : 'Request Recovery'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFD4AF37),
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
          if (_recoveryStatus.isNotEmpty) ...[
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: _recoveryStatus.startsWith('Recovery request sent')
                    ? const Color(0xFF4CAF50).withAlpha(30)
                    : Colors.red.withAlpha(30),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: _recoveryStatus.startsWith('Recovery request sent')
                      ? const Color(0xFF4CAF50)
                      : Colors.redAccent,
                ),
              ),
              child: Text(
                _recoveryStatus,
                style: TextStyle(
                  color: _recoveryStatus.startsWith('Recovery request sent')
                      ? const Color(0xFF4CAF50)
                      : Colors.redAccent,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── Shared helpers ─────────────────────────────────────────────────────────

  Widget _infoCard({required IconData icon, required Color color, required String text}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withAlpha(20),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withAlpha(60)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(color: Colors.white70, fontSize: 12))),
        ],
      ),
    );
  }

  Widget _emptyState({required IconData icon, required String message, required String subMessage}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Column(
          children: [
            Icon(icon, color: Colors.white12, size: 48),
            const SizedBox(height: 14),
            Text(message, style: const TextStyle(color: Colors.white38, fontSize: 15)),
            const SizedBox(height: 6),
            Text(subMessage,
                style: const TextStyle(color: Colors.white24, fontSize: 12),
                textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          SizedBox(width: 80,
              child: Text('$label:', style: const TextStyle(color: Colors.white38, fontSize: 12))),
          Expanded(child: Text(value, style: const TextStyle(color: Colors.white70, fontSize: 12))),
        ],
      ),
    );
  }
}
