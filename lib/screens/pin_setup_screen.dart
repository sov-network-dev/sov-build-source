// lib/screens/pin_setup_screen.dart
// ─────────────────────────────────────────────────────────────────────────────
// PIN SETUP SCREEN — Mandatory two-step PIN creation
//
// Used in:
//   • Fresh enrollment — after relay confirms success
//   • File wallet restore — before navigating to HomeScreen
//   • Seed phrase restore — before navigating to HomeScreen
//
// The screen CANNOT be skipped. Back in step 2 returns to step 1, not exit.
//
// Hash derivation: sha256(pin + sovereignId)
// This binds the PIN hash to this specific wallet identity.
// Must match pin_lock_overlay.dart exactly.
// ─────────────────────────────────────────────────────────────────────────────
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart';
import '../sov_node_sdk/pin_manager.dart';

class PinSetupScreen extends StatefulWidget {
  final String title;
  final String subtitle;

  /// Called with the computed sha256(pin + sovId) hash once both steps match.
  /// The caller is responsible for persisting 'pin_hash' to SharedPreferences.
  final Future<void> Function(String hash) onPinSet;

  const PinSetupScreen({
    super.key,
    this.title    = 'Secure Your Wallet',
    this.subtitle = 'Set a PIN to protect your wallet on this device.',
    required this.onPinSet,
  });

  @override
  State<PinSetupScreen> createState() => _PinSetupScreenState();
}

class _PinSetupScreenState extends State<PinSetupScreen> {
  static const int _pinLength = 6;

  static const Color _navy = Color(0xFF0A1628);
  static const Color _gold = Color(0xFFB8960C);

  bool   _step2     = false; // false = step 1 (enter), true = step 2 (confirm)
  String _firstPin  = '';
  String _pin       = '';
  String? _errorMsg;
  bool   _saving    = false;

  // ── Validation ───────────────────────────────────────────────────────────────

  /// Returns an error string if the PIN fails requirements, null if valid.
  static String? _validate(String pin) {
    if (pin.length < _pinLength) return 'PIN must be $_pinLength digits';

    // All same digit — e.g. 111111
    if (pin.split('').every((c) => c == pin[0])) {
      return 'PIN cannot be all the same digit';
    }

    // Sequential ascending — e.g. 123456
    bool asc = true;
    bool dsc = true;
    for (int i = 1; i < pin.length; i++) {
      final prev = int.parse(pin[i - 1]);
      final cur  = int.parse(pin[i]);
      if (cur != prev + 1) asc = false;
      if (cur != prev - 1) dsc = false;
    }
    if (asc) return 'PIN cannot be a sequential number (e.g. 123456)';
    if (dsc) return 'PIN cannot be a sequential number (e.g. 654321)';

    return null;
  }

  // ── Input ────────────────────────────────────────────────────────────────────

  // Desktop: drive the PIN with the PHYSICAL keyboard. A GLOBAL HardwareKeyboard
  // handler captures digits/backspace regardless of which widget holds focus — the
  // keypad buttons would otherwise steal focus from a focus-scoped KeyboardListener
  // (the bug that made keyboard input silently fail).
  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onHwKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onHwKey);
    super.dispose();
  }

  bool _onHwKey(KeyEvent e) {
    if (e is! KeyDownEvent || _saving) return false;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.backspace || k == LogicalKeyboardKey.delete) {
      _onBackspace();
      return true;
    }
    final ch = e.character;
    if (ch != null && ch.length == 1 &&
        ch.codeUnitAt(0) >= 0x30 && ch.codeUnitAt(0) <= 0x39) {
      _onDigit(ch);
      return true;
    }
    return false;
  }

  void _onDigit(String d) {
    if (_saving) return;
    if (_pin.length >= _pinLength) return;
    setState(() {
      _pin     += d;
      _errorMsg = null;
    });
    if (_pin.length == _pinLength) _onPinComplete();
  }

  void _onBackspace() {
    if (_saving || _pin.isEmpty) return;
    setState(() {
      _pin      = _pin.substring(0, _pin.length - 1);
      _errorMsg = null;
    });
  }

  void _onPinComplete() {
    if (_step2) {
      _confirmPin();
    } else {
      _finishStep1();
    }
  }

  void _finishStep1() {
    final err = _validate(_pin);
    if (err != null) {
      setState(() { _errorMsg = err; _pin = ''; });
      return;
    }
    setState(() {
      _firstPin = _pin;
      _pin      = '';
      _step2    = true;
      _errorMsg = null;
    });
  }

  Future<void> _confirmPin() async {
    if (_pin != _firstPin) {
      setState(() {
        _errorMsg = 'PINs do not match. Try again.';
        _pin      = '';
        _firstPin = '';
        _step2    = false;
      });
      return;
    }

    setState(() => _saving = true);

    try {
      final prefs = await SharedPreferences.getInstance();
      final sovId = prefs.getString('sovereign_id') ?? '';
      // Derive hash via PinManager: sha256(pin + deviceId + sovereignId + salt)
      // Device-tied — must match pin_lock_overlay.dart exactly.
      final hash = await PinManager.hashPin(_pin, sovId);
      await widget.onPinSet(hash);
      // Update the in-memory cache in the root app so the lock trigger
      // has the new hash immediately without waiting for another prefs read.
      SovereignApp.updatePinCache(hash);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving   = false;
          _errorMsg = 'Could not save PIN. Try again.';
          _pin      = '';
        });
      }
    }
  }

  // ── Back handling ─────────────────────────────────────────────────────────────
  // Step 2: back → return to step 1 (NOT exit)
  // Step 1: back → exit screen (cancels PIN setup)

  bool _onWillPop() {
    if (_step2) {
      setState(() {
        _step2    = false;
        _firstPin = '';
        _pin      = '';
        _errorMsg = null;
      });
      return false; // intercept — do NOT pop
    }
    return true; // allow pop in step 1
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_step2,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onWillPop();
      },
      child: Scaffold(
        backgroundColor: _navy,
        // No AppBar in step 2 — no visible back arrow
        appBar: _step2
            ? null
            : AppBar(
                backgroundColor: _navy,
                elevation: 0,
                leading: IconButton(
                  icon: const Icon(Icons.arrow_back_rounded,
                      color: Colors.white54),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
        // KeyboardListener → physical keyboard drives the PIN on desktop.
        // LayoutBuilder + scroll + IntrinsicHeight → no bottom overflow on short
        // windows, while the Spacer still pushes the numpad down on tall ones.
        body: SafeArea(
          child: LayoutBuilder(
              builder: (ctx, constraints) => SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: IntrinsicHeight(
                    child: Column(
                      children: [
                        const SizedBox(height: 32),
                        _buildLogo(),
                        const SizedBox(height: 20),
                        _buildTitles(),
                        const SizedBox(height: 8),
                        _buildStepIndicator(),
                        const SizedBox(height: 28),
                        _buildDots(),
                        const SizedBox(height: 16),
                        _buildStatus(),
                        const Spacer(),
                        _buildNumpad(),
                        const SizedBox(height: 32),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ),
      ),
    );
  }

  Widget _buildLogo() {
    return Container(
      width: 56, height: 56,
      decoration: BoxDecoration(
        color: _gold, borderRadius: BorderRadius.circular(14)),
      child: const Icon(Icons.lock_outline_rounded, color: _navy, size: 30),
    );
  }

  Widget _buildTitles() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        children: [
          Text(
            widget.title,
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            widget.subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Colors.white.withAlpha(150),
                fontSize: 13,
                height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _buildStepIndicator() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _stepDot(active: true,  label: '1'),
        Container(
          width: 32, height: 1,
          color: Colors.white.withAlpha(40),
        ),
        _stepDot(active: _step2, label: '2'),
      ],
    );
  }

  Widget _stepDot({required bool active, required String label}) {
    return Container(
      width: 28, height: 28,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: active ? _gold : Colors.white.withAlpha(20),
        border: Border.all(
          color: active ? _gold : Colors.white.withAlpha(40),
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: TextStyle(
          color: active ? _navy : Colors.white38,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildDots() {
    return Column(
      children: [
        Text(
          _step2 ? 'Confirm your PIN' : 'Enter a new PIN',
          style: const TextStyle(
              color: Colors.white70, fontSize: 14),
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(_pinLength, (i) {
            final filled = i < _pin.length;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              margin: const EdgeInsets.symmetric(horizontal: 8),
              width: 16, height: 16,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: filled ? _gold : Colors.transparent,
                border: Border.all(
                  color: filled ? _gold : Colors.white.withAlpha(100),
                  width: 2,
                ),
              ),
            );
          }),
        ),
      ],
    );
  }

  Widget _buildStatus() {
    if (_saving) {
      return const CircularProgressIndicator(
          color: Color(0xFFB8960C), strokeWidth: 1.5);
    }
    if (_errorMsg != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Text(
          _errorMsg!,
          textAlign: TextAlign.center,
          style: const TextStyle(
              color: Color(0xFFE57373), fontSize: 13, height: 1.4),
        ),
      );
    }
    // Requirement hints — shown in step 1 only
    if (!_step2) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 40),
        child: Text(
          'At least 6 digits · Not all same · Not sequential',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white24, fontSize: 11),
        ),
      );
    }
    return const SizedBox(height: 20);
  }

  Widget _buildNumpad() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          _numRow(['1', '2', '3']),
          const SizedBox(height: 10),
          _numRow(['4', '5', '6']),
          const SizedBox(height: 10),
          _numRow(['7', '8', '9']),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _numBtn(
                child: const Icon(Icons.backspace_outlined,
                    color: Colors.white, size: 22),
                onTap: _saving ? null : _onBackspace,
              ),
              _numBtn(
                key: const ValueKey('pin_0'),
                child: const Text('0',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w500)),
                onTap: _saving ? null : () => _onDigit('0'),
              ),
              _numBtn(
                key: const ValueKey('pin_submit'),
                child: Icon(
                  _step2
                      ? Icons.check_circle_rounded
                      : Icons.arrow_forward_rounded,
                  color: _gold, size: 26,
                ),
                onTap: _saving
                    ? null
                    : () {
                        if (_pin.length == _pinLength) _onPinComplete();
                      },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _numRow(List<String> digits) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: digits
          .map((d) => _numBtn(
                key: ValueKey('pin_$d'),
                child: Text(d,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w500)),
                onTap: _saving ? null : () => _onDigit(d),
              ))
          .toList(),
    );
  }

  Widget _numBtn({required Widget child, VoidCallback? onTap, Key? key}) {
    return GestureDetector(
      key: key, // flutter_driver target
      onTap: onTap,
      child: AnimatedOpacity(
        opacity: onTap == null ? 0.3 : 1.0,
        duration: const Duration(milliseconds: 150),
        child: Container(
          width: 72, height: 72,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withAlpha(18),
            border: Border.all(color: Colors.white.withAlpha(30)),
          ),
          alignment: Alignment.center,
          child: child,
        ),
      ),
    );
  }
}
