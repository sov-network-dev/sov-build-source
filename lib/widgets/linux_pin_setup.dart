import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../sov_node_sdk/key_manager.dart';

/// On Linux a newly enrolled or restored wallet key is held in memory only
/// (`KeyManager.requiresPinToPersist` is true and there is nowhere safe to write
/// a plaintext key). It is persisted ONLY as a PIN-encrypted Spend-Lock blob.
///
/// This collects a PIN and calls [KeyManager.enableSpendLock], blocking until it
/// succeeds, so the wallet is actually saved to disk before the app proceeds.
/// Without it, a restored wallet works for the session and is gone at next
/// launch. It is a no-op on every other platform and when there is no unsaved
/// key, so it is safe to call unconditionally at the end of enroll/restore.
Future<void> ensureKeyPersistedOnLinux(BuildContext context) async {
  if (!KeyManager.requiresPinToPersist || !KeyManager.hasUnsavedKey) return;

  // Loop until the key is safely encrypted to disk. The dialog cannot be
  // dismissed without setting a PIN — leaving here with an unsaved key would
  // silently lose the wallet at next launch.
  while (KeyManager.hasUnsavedKey) {
    if (!context.mounted) return;
    final pin = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _SetPinDialog(),
    );
    if (pin == null) continue; // dismissed defensively — re-prompt
    final ok = await KeyManager.enableSpendLock(pin);
    if (ok) return;
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Could not save wallet'),
        content: const Text(
            'Saving your wallet failed. Please try setting the PIN again.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(),
            child: const Text('Try again'),
          ),
        ],
      ),
    );
  }
}

class _SetPinDialog extends StatefulWidget {
  const _SetPinDialog();
  @override
  State<_SetPinDialog> createState() => _SetPinDialogState();
}

class _SetPinDialogState extends State<_SetPinDialog> {
  final _pin = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _pin.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _submit() {
    final p = _pin.text.trim();
    if (p.length < 4) {
      setState(() => _error = 'PIN must be at least 4 digits.');
      return;
    }
    if (p != _confirm.text.trim()) {
      setState(() => _error = 'The PINs do not match.');
      return;
    }
    Navigator.of(context).pop(p);
  }

  // SOV brand palette (matches lib/main.dart ThemeData): crisp gold accent on a
  // dark navy surface. Used explicitly here so the dialog reads as intentional
  // SOV chrome rather than the muted seed-derived colours of the ambient scheme.
  static const _gold    = Color(0xFFD4AF37);
  static const _navy    = Color(0xFF0A1628);
  static const _surface = Color(0xFF12233D);
  static const _danger  = Color(0xFFFF6B6B);

  InputDecoration _pinDecoration(
      {required String label, String? helper, required IconData icon}) {
    return InputDecoration(
      labelText: label,
      helperText: helper,
      helperStyle: const TextStyle(color: Colors.white38),
      labelStyle: const TextStyle(color: Colors.white70),
      floatingLabelStyle: const TextStyle(color: _gold),
      prefixIcon: Icon(icon, color: _gold),
      filled: true,
      fillColor: Colors.black.withValues(alpha: 0.25),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.18)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: _gold, width: 1.6),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false, // must set a PIN — cannot back out and lose the wallet
      child: AlertDialog(
        backgroundColor: _surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: _gold.withValues(alpha: 0.35)),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: _gold.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.lock_outline, size: 20, color: _gold),
            ),
            const SizedBox(width: 12),
            const Text('Set a wallet PIN',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
          ],
        ),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Choose a PIN to protect this wallet on this device. It encrypts '
                'your key at rest and unlocks spending — and it is what saves the '
                'wallet here. Your recovery phrase still restores it if you forget.',
                style: TextStyle(color: Colors.white70, height: 1.35),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _pin,
                obscureText: true,
                autofocus: true,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: const TextStyle(color: Colors.white, letterSpacing: 4),
                cursorColor: _gold,
                decoration: _pinDecoration(
                    label: 'PIN', helper: '4 or more digits', icon: Icons.pin_outlined),
                // Clear a stale error as soon as the citizen starts correcting it.
                onChanged: (_) { if (_error != null) setState(() => _error = null); },
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _confirm,
                obscureText: true,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: const TextStyle(color: Colors.white, letterSpacing: 4),
                cursorColor: _gold,
                decoration: _pinDecoration(
                    label: 'Confirm PIN', icon: Icons.check_circle_outline),
                onChanged: (_) { if (_error != null) setState(() => _error = null); },
                onSubmitted: (_) => _submit(),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline, size: 16, color: _danger),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(_error!,
                            style: const TextStyle(color: _danger, fontSize: 13)),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [
          ElevatedButton.icon(
            onPressed: _submit,
            style: ElevatedButton.styleFrom(
              backgroundColor: _gold,
              foregroundColor: _navy,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            icon: const Icon(Icons.shield_outlined, size: 18),
            label: const Text('Save wallet',
                style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}
