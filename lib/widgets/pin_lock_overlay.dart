// lib/widgets/pin_lock_overlay.dart
// ─────────────────────────────────────────────────────────────────────────────
// PIN LOCK OVERLAY — Full-screen session lock widget
//
// Shown as a Stack overlay ABOVE MaterialApp when the app resumes after the
// grace period has elapsed. Cannot be dismissed without correct PIN or palm.
//
// Security model (SESSION LOCK ONLY — not wallet recovery):
//   • Wrong PIN × 3  → 30-second lockout
//   • Wrong PIN × 10 → onForgotPin() called (navigate to recovery)
//   • "Use Palm" → PalmAuthScreen pushed modally
// ─────────────────────────────────────────────────────────────────────────────
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screens/palm_auth_screen.dart';
import '../sov_node_sdk/pin_manager.dart';

class PinLockOverlay extends StatefulWidget {
  final VoidCallback onUnlocked;
  final VoidCallback onForgotPin;

  const PinLockOverlay({
    super.key,
    required this.onUnlocked,
    required this.onForgotPin,
  });

  @override
  State<PinLockOverlay> createState() => _PinLockOverlayState();
}

class _PinLockOverlayState extends State<PinLockOverlay> {
  static const int _pinLength    = 6;
  static const int _lockoutAfter = 3;   // wrong PINs per window before lockout
  static const int _lockoutSecs  = 30;
  static const int _maxTotal     = 10;  // total wrong before forcing recovery

  static const Color _navy = Color(0xFF0A1628);
  static const Color _gold = Color(0xFFB8960C);

  String  _pin         = '';
  int     _wrongTotal  = 0;   // cumulative across all lockout windows
  int     _wrongWindow = 0;   // attempts in the current window (resets on lockout)
  bool    _lockedOut   = false;
  int     _countdown   = _lockoutSecs;
  Timer?  _timer;
  String? _errorMsg;
  String  _sovId       = '';
  bool    _hasPalmEmb  = false;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    HardwareKeyboard.instance.addHandler(_onHwKey);
  }

  @override
  void dispose() {
    _timer?.cancel();
    HardwareKeyboard.instance.removeHandler(_onHwKey);
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _sovId      = prefs.getString('sovereign_id') ?? '';
      _hasPalmEmb = (prefs.getString('palm_embedding') ?? '').isNotEmpty;
    });
  }

  String get _truncatedId {
    if (_sovId.isEmpty) return '';
    // Show first 10 chars: e.g. "SOV-A3234F…"
    return _sovId.length > 10
        ? '${_sovId.substring(0, 10)}…'
        : _sovId;
  }

  // ── PIN input ────────────────────────────────────────────────────────────────

  void _onDigit(String d) {
    if (_lockedOut || _pin.length >= _pinLength) return;
    setState(() {
      _pin     += d;
      _errorMsg = null;
    });
    if (_pin.length == _pinLength) _verify();
  }

  void _onBackspace() {
    if (_lockedOut || _pin.isEmpty) return;
    setState(() {
      _pin      = _pin.substring(0, _pin.length - 1);
      _errorMsg = null;
    });
  }

  // Desktop: unlock with the PHYSICAL keyboard. Global HardwareKeyboard handler
  // (focus-independent — the keypad buttons can't steal it).
  bool _onHwKey(KeyEvent e) {
    if (e is! KeyDownEvent || _lockedOut) return false;
    if (e.logicalKey == LogicalKeyboardKey.backspace ||
        e.logicalKey == LogicalKeyboardKey.delete) {
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

  Future<void> _verify() async {
    final prefs      = await SharedPreferences.getInstance();
    final storedHash = prefs.getString('pin_hash') ?? '';
    // Verify via PinManager: sha256(pin + deviceId + sovereignId + salt)
    // Device-tied — must match PinSetupScreen exactly.
    final matched = await PinManager.verifyPin(_pin, storedHash, _sovId);

    if (matched) {
      _timer?.cancel();
      widget.onUnlocked();
      return;
    }

    _wrongTotal++;
    _wrongWindow++;

    if (_wrongTotal >= _maxTotal) {
      // 10 total failures — force recovery
      if (mounted) {
        setState(() {
          _errorMsg = 'Too many failed attempts.\nRestore your wallet to regain access.';
          _pin      = '';
        });
      }
      await Future.delayed(const Duration(milliseconds: 1200));
      widget.onForgotPin();
      return;
    }

    if (_wrongWindow >= _lockoutAfter) {
      _startLockout();
    } else {
      final rem = _lockoutAfter - _wrongWindow;
      setState(() {
        _pin      = '';
        _errorMsg = 'Wrong PIN. $rem attempt${rem == 1 ? '' : 's'} before lockout.';
      });
    }
  }

  void _startLockout() {
    setState(() {
      _lockedOut   = true;
      _countdown   = _lockoutSecs;
      _pin         = '';
      _errorMsg    = null;
      _wrongWindow = 0;
    });
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      setState(() => _countdown--);
      if (_countdown <= 0) {
        t.cancel();
        if (mounted) setState(() => _lockedOut = false);
      }
    });
  }

  // ── Palm authentication ──────────────────────────────────────────────────────

  Future<void> _onUsePalm() async {
    final matched = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const PalmAuthScreen()),
    );
    if (matched == true && mounted) {
      widget.onUnlocked();
    }
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Material(
      color: _navy,
      child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 48),
            _buildLogo(),
            const SizedBox(height: 16),
            if (_truncatedId.isNotEmpty) ...[
              Text(
                _truncatedId,
                style: const TextStyle(
                  color: Colors.white38,
                  fontSize: 13,
                  fontFamily: 'monospace',
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 8),
            ],
            const Text(
              'Enter PIN to unlock',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 32),
            _buildDots(),
            const SizedBox(height: 20),
            _buildStatus(),
            const Spacer(),
            _buildNumpad(),
            const SizedBox(height: 16),
            if (_hasPalmEmb) _buildPalmButton(),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _buildLogo() {
    return Container(
      width: 60,
      height: 60,
      decoration: BoxDecoration(
        color: _gold,
        borderRadius: BorderRadius.circular(16),
      ),
      child: const Icon(Icons.lock_outline_rounded, color: _navy, size: 32),
    );
  }

  Widget _buildDots() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(_pinLength, (i) {
        final filled = i < _pin.length;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: const EdgeInsets.symmetric(horizontal: 8),
          width: 16,
          height: 16,
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
    );
  }

  Widget _buildStatus() {
    if (_lockedOut) {
      return Column(
        children: [
          const Icon(Icons.lock_clock, color: _gold, size: 28),
          const SizedBox(height: 8),
          const Text(
            'Too many attempts. Try again in',
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
          Text(
            '$_countdown seconds',
            style: const TextStyle(
              color: _gold,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      );
    }
    if (_errorMsg != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Text(
          _errorMsg!,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Color(0xFFE57373), fontSize: 13, height: 1.4),
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
                onTap: _lockedOut ? null : _onBackspace,
              ),
              _numBtn(
                child: const Text('0',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w500)),
                onTap: _lockedOut ? null : () => _onDigit('0'),
              ),
              _numBtn(
                child: const Icon(Icons.check_circle_outline,
                    color: _gold, size: 26),
                onTap: _lockedOut
                    ? null
                    : () {
                        if (_pin.length == _pinLength) _verify();
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
                child: Text(d,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w500)),
                onTap: _lockedOut ? null : () => _onDigit(d),
              ))
          .toList(),
    );
  }

  Widget _numBtn({required Widget child, VoidCallback? onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedOpacity(
        opacity: onTap == null ? 0.3 : 1.0,
        duration: const Duration(milliseconds: 150),
        child: Container(
          width: 72,
          height: 72,
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

  Widget _buildPalmButton() {
    return TextButton.icon(
      onPressed: _lockedOut ? null : _onUsePalm,
      icon: const Icon(Icons.back_hand_outlined, size: 18),
      label: const Text('Use Palm'),
      style: TextButton.styleFrom(
        foregroundColor: _gold,
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    );
  }
}
