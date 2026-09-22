import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../sov_node_sdk/key_manager.dart';
import '../sov_node_sdk/relay_connector.dart';

enum PinScreenMode { setup, verify }

class PinScreen extends StatefulWidget {
  const PinScreen({
    super.key,
    required this.mode,
    required this.onSuccess,
    this.onSkip,
    this.onForgot,
    this.title,
    this.subtitle,
  });

  final PinScreenMode mode;
  final VoidCallback onSuccess;
  final VoidCallback? onSkip;
  final VoidCallback? onForgot;
  final String? title;
  final String? subtitle;

  @override
  State<PinScreen> createState() => _PinScreenState();
}

class _PinScreenState extends State<PinScreen> {
  static const int _pinLength = 6;
  static const int _maxAttempts = 5;
  static const int _lockoutSeconds = 30;
  static const String _pinHashKey = 'pin_hash';

  static const Color _navy = Color(0xFF0A1628);
  static const Color _gold = Color(0xFFB8960C);
  static const Color _white = Colors.white;

  // Setup flow state
  bool _isConfirmStep = false;
  String _firstPin = '';

  // Current input
  String _currentPin = '';

  // Verification state
  int _wrongAttempts = 0;
  bool _isLockedOut = false;
  int _lockoutCountdown = _lockoutSeconds;
  Timer? _lockoutTimer;

  // Error message
  String? _errorMessage;

  @override
  void dispose() {
    _lockoutTimer?.cancel();
    super.dispose();
  }

  String _hashPin(String pin) {
    final bytes = utf8.encode(pin);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  Future<void> _storePinHash(String hash) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pinHashKey, hash);
  }

  Future<String?> _loadPinHash() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_pinHashKey);
  }

  void _onDigitPressed(String digit) {
    if (_isLockedOut) return;
    if (_currentPin.length >= _pinLength) return;

    setState(() {
      _currentPin += digit;
      _errorMessage = null;
    });

    if (_currentPin.length == _pinLength) {
      _onPinComplete();
    }
  }

  void _onBackspace() {
    if (_isLockedOut) return;
    if (_currentPin.isEmpty) return;

    setState(() {
      _currentPin = _currentPin.substring(0, _currentPin.length - 1);
      _errorMessage = null;
    });
  }

  void _onConfirm() {
    if (_isLockedOut) return;
    if (_currentPin.length == _pinLength) {
      _onPinComplete();
    }
  }

  Future<void> _onPinComplete() async {
    if (widget.mode == PinScreenMode.setup) {
      await _handleSetup();
    } else {
      await _handleVerify();
    }
  }

  Future<void> _handleSetup() async {
    if (!_isConfirmStep) {
      // First entry — move to confirm step
      setState(() {
        _firstPin = _currentPin;
        _currentPin = '';
        _isConfirmStep = true;
        _errorMessage = null;
      });
    } else {
      // Confirm step
      if (_currentPin == _firstPin) {
        final hash = _hashPin(_currentPin);
        await _storePinHash(hash);
        widget.onSuccess();
      } else {
        setState(() {
          _errorMessage = 'PINs do not match. Please try again.';
          _currentPin = '';
          _firstPin = '';
          _isConfirmStep = false;
        });
      }
    }
  }

  Future<void> _handleVerify() async {
    final storedHash = await _loadPinHash();
    final enteredHash = _hashPin(_currentPin);

    if (storedHash != null && enteredHash == storedHash) {
      _wrongAttempts = 0;
      // Spend-Lock: decrypt the key into memory for this session so the app can
      // sign (HELLO, transfers, messages). No-op when Spend-Lock is off. Then kick
      // a reconnect so HELLO re-signs now that the key is available.
      if (await KeyManager.isSpendLockEnabled()) {
        await KeyManager.unlockSession(_currentPin, ttl: const Duration(hours: 12));
        RelayConnector.connect().catchError((_) => false);
      }
      // Hardware-Lock: unseal the key from the TPM for this session (no PIN — the
      // machine is the key). No-op when Hardware-Lock is off.
      if (await KeyManager.isHardwareLockEnabled()) {
        await KeyManager.unlockHardwareSession(ttl: const Duration(hours: 12));
        RelayConnector.connect().catchError((_) => false);
      }
      widget.onSuccess();
    } else {
      _wrongAttempts++;
      if (_wrongAttempts >= _maxAttempts) {
        _startLockout();
      } else {
        final remaining = _maxAttempts - _wrongAttempts;
        setState(() {
          _errorMessage =
              'Incorrect PIN. $remaining attempt${remaining == 1 ? '' : 's'} remaining.';
          _currentPin = '';
        });
      }
    }
  }

  void _startLockout() {
    setState(() {
      _isLockedOut = true;
      _lockoutCountdown = _lockoutSeconds;
      _currentPin = '';
      _errorMessage = null;
    });

    _lockoutTimer?.cancel();
    _lockoutTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        _lockoutCountdown--;
      });

      if (_lockoutCountdown <= 0) {
        timer.cancel();
        setState(() {
          _isLockedOut = false;
          _wrongAttempts = 0;
          _lockoutCountdown = _lockoutSeconds;
          _errorMessage = null;
        });
      }
    });
  }

  String get _displayTitle {
    if (widget.title != null) return widget.title!;
    if (widget.mode == PinScreenMode.setup) {
      return _isConfirmStep ? 'Confirm PIN' : 'Set PIN';
    }
    return 'Enter PIN';
  }

  String get _displaySubtitle {
    if (widget.subtitle != null) return widget.subtitle!;
    if (widget.mode == PinScreenMode.setup) {
      return _isConfirmStep
          ? 'Re-enter your 6-digit PIN to confirm'
          : 'Choose a 6-digit PIN to secure your account';
    }
    return 'Enter your 6-digit PIN';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _navy,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _buildTitleSection(),
                  const SizedBox(height: 40),
                  _buildDotIndicators(),
                  const SizedBox(height: 24),
                  _buildStatusArea(),
                ],
              ),
            ),
            _buildNumpad(),
            _buildBottomLinks(),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          // Gold logo accent
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: _gold,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.lock_outline, color: _navy, size: 20),
          ),
          const SizedBox(width: 10),
          const Text(
            'SOV',
            style: TextStyle(
              color: _gold,
              fontSize: 18,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTitleSection() {
    return Column(
      children: [
        Text(
          _displayTitle,
          style: const TextStyle(
            color: _white,
            fontSize: 26,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.3,
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            _displaySubtitle,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _white.withValues(alpha: 0.6),
              fontSize: 14,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDotIndicators() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(_pinLength, (index) {
        final filled = index < _currentPin.length;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: const EdgeInsets.symmetric(horizontal: 8),
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: filled ? _gold : Colors.transparent,
            border: Border.all(
              color: filled ? _gold : _white.withValues(alpha: 0.4),
              width: 2,
            ),
          ),
        );
      }),
    );
  }

  Widget _buildStatusArea() {
    if (_isLockedOut) {
      return Column(
        children: [
          const Icon(Icons.lock_clock, color: _gold, size: 32),
          const SizedBox(height: 12),
          const Text(
            'Too many attempts. Try again in',
            style: TextStyle(color: Colors.white70, fontSize: 14),
          ),
          const SizedBox(height: 4),
          Text(
            '$_lockoutCountdown seconds',
            style: const TextStyle(
              color: _gold,
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      );
    }

    if (_errorMessage != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Text(
          _errorMessage!,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Color(0xFFE57373),
            fontSize: 13,
            height: 1.4,
          ),
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
          _buildNumpadRow(['1', '2', '3']),
          const SizedBox(height: 12),
          _buildNumpadRow(['4', '5', '6']),
          const SizedBox(height: 12),
          _buildNumpadRow(['7', '8', '9']),
          const SizedBox(height: 12),
          _buildSpecialRow(),
        ],
      ),
    );
  }

  Widget _buildNumpadRow(List<String> digits) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: digits.map((d) => _buildDigitButton(d)).toList(),
    );
  }

  Widget _buildSpecialRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _buildActionButton(
          child: const Icon(Icons.backspace_outlined, color: _white, size: 22),
          onTap: _isLockedOut ? null : _onBackspace,
        ),
        _buildDigitButton('0'),
        _buildActionButton(
          child: const Icon(Icons.check_circle_outline, color: _gold, size: 26),
          onTap: _isLockedOut ? null : _onConfirm,
        ),
      ],
    );
  }

  Widget _buildDigitButton(String digit) {
    return _buildActionButton(
      child: Text(
        digit,
        style: const TextStyle(
          color: _white,
          fontSize: 22,
          fontWeight: FontWeight.w500,
        ),
      ),
      onTap: _isLockedOut ? null : () => _onDigitPressed(digit),
    );
  }

  Widget _buildActionButton({
    required Widget child,
    VoidCallback? onTap,
  }) {
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
            color: _white.withValues(alpha: 0.07),
            border: Border.all(
              color: _white.withValues(alpha: 0.12),
              width: 1,
            ),
          ),
          alignment: Alignment.center,
          child: child,
        ),
      ),
    );
  }

  Widget _buildBottomLinks() {
    final List<Widget> links = [];

    if (widget.mode == PinScreenMode.setup && widget.onSkip != null) {
      links.add(
        TextButton(
          onPressed: widget.onSkip,
          child: Text(
            'Skip for now',
            style: TextStyle(
              color: _white.withValues(alpha: 0.5),
              fontSize: 14,
              decoration: TextDecoration.underline,
              decorationColor: _white.withValues(alpha: 0.3),
            ),
          ),
        ),
      );
    }

    if (widget.mode == PinScreenMode.verify && widget.onForgot != null) {
      links.add(
        TextButton(
          onPressed: widget.onForgot,
          child: Text(
            'Forgot PIN?',
            style: TextStyle(
              color: _gold.withValues(alpha: 0.85),
              fontSize: 14,
              decoration: TextDecoration.underline,
              decorationColor: _gold.withValues(alpha: 0.5),
            ),
          ),
        ),
      );
    }

    if (links.isEmpty) return const SizedBox(height: 16);

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: links,
      ),
    );
  }
}
