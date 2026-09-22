// lib/screens/wallet_reset_screen.dart
// ─────────────────────────────────────────────────────────────────────────────
// Remove Wallet From This Device — the citizen-facing confirmation flow for
// WalletResetService.resetDevice() (see that file for exactly what is cleared).
//
// Three gates before anything is deleted, in order:
//   1. Explicit checkbox: "I have saved my seed phrase and understand this
//      cannot be undone."
//   2. Re-enter the PIN (if PIN is enabled) — verified via PinManager,
//      the same hash check used everywhere else in the app.
//   3. Type REMOVE to confirm, then one final native "are you sure" dialog.
// Any one of these failing blocks the action; there is no shortcut path.
// ─────────────────────────────────────────────────────────────────────────────
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../sov_node_sdk/pin_manager.dart';
import '../sov_node_sdk/wallet_reset_service.dart';
import 'splash_screen.dart';

class WalletResetScreen extends StatefulWidget {
  final String sovereignId;
  const WalletResetScreen({super.key, required this.sovereignId});

  @override
  State<WalletResetScreen> createState() => _WalletResetScreenState();
}

class _WalletResetScreenState extends State<WalletResetScreen> {
  static const _navy = Color(0xFF0A1628);
  static const _cardBg = Color(0xFF0D1F3A);

  final _pinController = TextEditingController();
  final _confirmController = TextEditingController();

  bool _seedConfirmed = false;
  bool _pinEnabled = true;
  String _storedPinHash = '';
  bool _resetting = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _loadPinState();
  }

  Future<void> _loadPinState() async {
    final prefs = await SharedPreferences.getInstance();
    final hash = prefs.getString('pin_hash') ?? '';
    if (mounted) {
      setState(() {
        _pinEnabled = (prefs.getBool('pin_enabled') ?? true) && hash.isNotEmpty;
        _storedPinHash = hash;
      });
    }
  }

  @override
  void dispose() {
    _pinController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  bool get _canSubmit =>
      !_resetting &&
      _seedConfirmed &&
      (!_pinEnabled || _pinController.text.length == 6) &&
      _confirmController.text.trim().toUpperCase() == 'REMOVE';

  Future<void> _onSubmit() async {
    setState(() => _error = '');

    if (_pinEnabled) {
      final ok = await PinManager.verifyPin(
          _pinController.text, _storedPinHash, widget.sovereignId);
      if (!ok) {
        setState(() => _error = 'Incorrect PIN.');
        return;
      }
    }
    if (!mounted) return;

    final finalConfirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _cardBg,
        title: const Text('Remove wallet from this device?',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: const Text(
          'This is the last step. Once removed, this device has no way back in '
          'except your 12-word seed phrase or your appointed Guardians. Continue?',
          style: TextStyle(color: Colors.white60, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white60)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove Wallet',
                style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (finalConfirm != true) return;

    setState(() => _resetting = true);
    try {
      await WalletResetService.resetDevice();
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const SplashScreen()),
        (route) => false,
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _resetting = false;
          _error = 'Reset failed: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _navy,
      appBar: AppBar(
        backgroundColor: _navy,
        elevation: 0,
        title: const Text('Remove Wallet From This Device',
            style: TextStyle(color: Colors.white, fontSize: 17)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.red.withAlpha(20),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.redAccent.withAlpha(90)),
              ),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 22),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'This permanently erases your wallet from this device — signing '
                      'keys, messages, contacts, and cached transaction history. There '
                      'is no in-app undo.\n\n'
                      'If you run a node on this computer, it is stopped and its '
                      'identity, ledger copy and logs are removed too. Otherwise this '
                      'machine would keep announcing its address to the network after '
                      'you thought you had left.\n\n'
                      'Your SOV is never lost on the network — but the ONLY way back on '
                      'this or any other device is your 12-word seed phrase, or your '
                      'appointed Guardians if you set them up.',
                      style: TextStyle(color: Colors.white, height: 1.5, fontSize: 13.5),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 22),
            InkWell(
              onTap: () => setState(() => _seedConfirmed = !_seedConfirmed),
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Checkbox(
                      value: _seedConfirmed,
                      onChanged: (v) => setState(() => _seedConfirmed = v ?? false),
                      fillColor: WidgetStateProperty.resolveWith((states) =>
                          states.contains(WidgetState.selected)
                              ? Colors.redAccent
                              : Colors.white38),
                    ),
                    const Expanded(
                      child: Text(
                        'I have saved my 12-word seed phrase and understand this '
                        'cannot be undone.',
                        style: TextStyle(color: Colors.white, fontSize: 13.5),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_pinEnabled) ...[
              const SizedBox(height: 14),
              const Text('Re-enter your PIN',
                  style: TextStyle(color: Colors.white54, fontSize: 12.5)),
              const SizedBox(height: 6),
              TextField(
                controller: _pinController,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 6,
                onChanged: (_) => setState(() {}),
                style: const TextStyle(color: Colors.white, letterSpacing: 6),
                decoration: InputDecoration(
                  counterText: '',
                  filled: true,
                  fillColor: _cardBg,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ],
            const SizedBox(height: 14),
            const Text('Type REMOVE to confirm',
                style: TextStyle(color: Colors.white54, fontSize: 12.5)),
            const SizedBox(height: 6),
            TextField(
              controller: _confirmController,
              textCapitalization: TextCapitalization.characters,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'REMOVE',
                hintStyle: const TextStyle(color: Colors.white24),
                filled: true,
                fillColor: _cardBg,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
            if (_error.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(_error, style: const TextStyle(color: Colors.redAccent, fontSize: 12.5)),
            ],
            const SizedBox(height: 26),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _canSubmit ? _onSubmit : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red.shade800,
                  disabledBackgroundColor: Colors.red.shade800.withAlpha(60),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: _resetting
                    ? const SizedBox(
                        width: 20, height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Remove Wallet From This Device',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
