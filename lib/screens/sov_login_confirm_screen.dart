// lib/screens/sov_login_confirm_screen.dart
// ─────────────────────────────────────────────────────────────────────────────
// SOV Login Confirmation Screen
// Shown when citizen scans a sovlogin:// QR code from an external website.
// Verifies the session, shows the requesting site, and lets the citizen
// approve or deny the sign-in request.
// ─────────────────────────────────────────────────────────────────────────────
import 'package:flutter/material.dart';
import '../sov_node_sdk/relay_connector.dart';

class SovLoginConfirmScreen extends StatefulWidget {
  final String sessionId;
  final String challenge;
  final String clientOrigin;   // e.g. "203.0.113.10" or site domain hint in QR

  const SovLoginConfirmScreen({
    super.key,
    required this.sessionId,
    required this.challenge,
    required this.clientOrigin,
  });

  @override
  State<SovLoginConfirmScreen> createState() => _SovLoginConfirmScreenState();
}

class _SovLoginConfirmScreenState extends State<SovLoginConfirmScreen> {

  static const _navy   = Color(0xFF0A1628);
  static const _gold   = Color(0xFFB8960C);
  static const _cardBg = Color(0xFF0D1F3A);
  static const _teal   = Color(0xFF006B5E);

  bool _loading = false;
  String _result = '';
  bool _approved = false;

  Future<void> _approve() async {
    setState(() { _loading = true; _result = ''; });
    try {
      final resp = await RelayConnector.respondSovLogin(
        sessionId: widget.sessionId,
        challenge: widget.challenge,
      );
      if (!mounted) return;
      if (resp != null && resp['success'] == true) {
        setState(() { _loading = false; _approved = true; _result = 'Sign-in approved!'; });
      } else {
        final err = resp?['error'] ?? 'Unknown error';
        setState(() { _loading = false; _result = 'Failed: $err'; });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _result = 'Error: $e'; });
    }
  }

  void _deny() => Navigator.pop(context);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _navy,
      appBar: AppBar(
        backgroundColor: _navy,
        foregroundColor: Colors.white,
        title: const Text('SOV Login Request',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _approved ? _buildSuccess() : _buildConfirmCard(),
        ),
      ),
    );
  }

  Widget _buildConfirmCard() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 16),

        // Icon
        Center(
          child: Container(
            width: 72, height: 72,
            decoration: BoxDecoration(
              color: _cardBg,
              borderRadius: BorderRadius.circular(36),
              border: Border.all(color: _gold, width: 2),
            ),
            child: const Icon(Icons.login_rounded, color: Color(0xFFB8960C), size: 36),
          ),
        ),
        const SizedBox(height: 24),

        // Site info card
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _cardBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('A website is requesting sign-in',
                  style: TextStyle(color: Colors.white70, fontSize: 13)),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(Icons.language, color: Colors.white38, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.clientOrigin.isNotEmpty
                          ? widget.clientOrigin
                          : 'Unknown site',
                      style: const TextStyle(
                          color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.fingerprint, color: Colors.white38, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Session: ${widget.sessionId.length > 20 ? "${widget.sessionId.substring(0, 20)}…" : widget.sessionId}',
                      style: const TextStyle(color: Colors.white54, fontSize: 12,
                          fontFamily: 'monospace'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),

        // What this does
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFF0D2B1A),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.greenAccent.withValues(alpha: 0.2)),
          ),
          child: const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.shield_outlined, color: Colors.greenAccent, size: 18),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Approving will sign in to this site using your Sovereign ID. '
                  'Your private key never leaves your device.',
                  style: TextStyle(color: Colors.greenAccent, fontSize: 12, height: 1.5),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // Error display
        if (_result.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(_result,
                style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
          ),

        const Spacer(),

        // Approve button
        SizedBox(
          height: 50,
          child: _loading
              ? const Center(child: CircularProgressIndicator(color: Color(0xFFB8960C)))
              : ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _teal,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  icon: const Icon(Icons.check_circle_outline_rounded),
                  label: const Text('Approve Sign-In',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                  onPressed: _approve,
                ),
        ),
        const SizedBox(height: 12),

        // Deny button
        SizedBox(
          height: 50,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.redAccent,
              side: const BorderSide(color: Colors.redAccent),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            icon: const Icon(Icons.cancel_outlined),
            label: const Text('Deny', style: TextStyle(fontSize: 15)),
            onPressed: _deny,
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _buildSuccess() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 80, height: 80,
            decoration: BoxDecoration(
              color: const Color(0xFF0D2B1A),
              borderRadius: BorderRadius.circular(40),
            ),
            child: const Icon(Icons.check_circle_rounded,
                color: Colors.greenAccent, size: 48),
          ),
          const SizedBox(height: 24),
          const Text('Sign-In Approved',
              style: TextStyle(color: Colors.white, fontSize: 22,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Text(
            widget.clientOrigin.isNotEmpty
                ? 'You are now signed into\n${widget.clientOrigin}'
                : 'You are now signed in',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 15, height: 1.5),
          ),
          const SizedBox(height: 40),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _teal,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
              padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 14),
            ),
            onPressed: () => Navigator.pop(context),
            child: const Text('Done', style: TextStyle(fontSize: 15)),
          ),
        ],
      ),
    );
  }
}
