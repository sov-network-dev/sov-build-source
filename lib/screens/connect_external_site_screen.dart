// lib/screens/connect_external_site_screen.dart
// ─────────────────────────────────────────────────────────────────────────────
// SOV Login — Flow A2 (App-Mediated Path A)
//
// Phishing-proof external-site login. The citizen NEVER types their seed
// phrase into a website — instead the website shows a 6-digit pairing code,
// the citizen opens this screen, enters the code, the SOV app talks to a
// BUNDLED relay (the trust anchor in assets/relay_pool.json), confirms the
// platform domain with the citizen, and signs an Ed25519 authorization
// locally before submitting.
//
// Why this is unphishable:
//   - Relay URLs are hard-coded in the APK at compile time. A malicious
//     website cannot redirect the SOV app to a fake relay.
//   - The signing key lives in KeyManager's secure storage. It is never
//     transmitted; only Ed25519 signatures over short canonical payloads
//     leave the device.
//   - The pairing code is 6 digits + 90s TTL + one-use + domain-bound.
//     Useless as a stolen credential.
//
// Entry point: Profile tab → SECURITY section → "Connect to External Site"
// ─────────────────────────────────────────────────────────────────────────────
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../sov_node_sdk/relay_connector.dart';

class ConnectExternalSiteScreen extends StatefulWidget {
  const ConnectExternalSiteScreen({super.key});

  @override
  State<ConnectExternalSiteScreen> createState() =>
      _ConnectExternalSiteScreenState();
}

class _ConnectExternalSiteScreenState extends State<ConnectExternalSiteScreen> {
  static const _navy   = Color(0xFF0A1628);
  static const _gold   = Color(0xFFD4AF37);
  static const _cardBg = Color(0xFF0D1F3A);

  // 6 separate digit controllers so the user can see and edit each box.
  final List<TextEditingController> _digitCtrls =
      List.generate(6, (_) => TextEditingController());
  final List<FocusNode> _digitFocus = List.generate(6, (_) => FocusNode());

  bool _checking = false;
  bool _authorizing = false;
  String? _errorMessage;

  @override
  void dispose() {
    for (final c in _digitCtrls) { c.dispose(); }
    for (final f in _digitFocus) { f.dispose(); }
    super.dispose();
  }

  String get _pairingCode =>
      _digitCtrls.map((c) => c.text).join();

  bool get _codeComplete => _pairingCode.length == 6;

  void _onDigitChanged(int index, String value) {
    setState(() => _errorMessage = null);
    if (value.length > 1) {
      // User pasted — distribute across the boxes
      final digits = value.replaceAll(RegExp(r'\D'), '');
      for (int i = 0; i < 6; i++) {
        _digitCtrls[i].text = i < digits.length ? digits[i] : '';
      }
      final next = digits.length.clamp(0, 5);
      _digitFocus[next].requestFocus();
      setState(() {});
      return;
    }
    if (value.isNotEmpty && index < 5) {
      _digitFocus[index + 1].requestFocus();
    } else if (value.isEmpty && index > 0) {
      _digitFocus[index - 1].requestFocus();
    }
    setState(() {});
  }

  Future<void> _onContinue() async {
    if (!_codeComplete) return;
    setState(() {
      _checking = true;
      _errorMessage = null;
    });

    final pairingCode = _pairingCode;
    final result = await RelayConnector.checkAppPairing(pairingCode);

    if (!mounted) return;
    setState(() => _checking = false);

    if (result == null || result['success'] != true) {
      final err = (result?['error'] as String?) ?? 'UNKNOWN_ERROR';
      _showErrorDialog(_errorMessageFor(err));
      return;
    }

    final platformDomain = result['platform_domain'] as String? ?? '';
    final sessionId = result['session_id'] as String? ?? '';
    if (platformDomain.isEmpty || sessionId.isEmpty) {
      _showErrorDialog('Could not read platform details from relay.');
      return;
    }

    // Show confirmation dialog — this is the moment the citizen confirms intent.
    // We display the domain prominently because that IS the trust decision.
    final confirmed = await _showConfirmDialog(platformDomain);
    if (confirmed != true) return;

    // Optional password creation step — lets the citizen log in to the platform
    // later with SOV-XXXX + password (Path B) without opening the SOV app.
    // Skip → app-only login (Flow A2 every time).
    final password = await _showPasswordDialog(platformDomain);
    if (password == null) return; // citizen cancelled (Cancel ≠ Skip)

    // Sign + submit. KeyManager.signChallenge() reads the private key from
    // secure storage, so this only works if the device is unlocked.
    setState(() => _authorizing = true);
    final authResult = await RelayConnector.authorizeAppPairing(
      sessionId: sessionId,
      platformDomain: platformDomain,
      password: password,
    );
    if (!mounted) return;
    setState(() => _authorizing = false);

    if (authResult == null || authResult['success'] != true) {
      final err = (authResult?['error'] as String?) ?? 'UNKNOWN_ERROR';
      _showErrorDialog(_errorMessageFor(err));
      return;
    }

    // Success — pop back to Profile with a snackbar.
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: _gold,
        content: Text(
          'SOV ID verified to $platformDomain',
          style: const TextStyle(color: _navy, fontWeight: FontWeight.bold),
        ),
        duration: const Duration(seconds: 4),
      ),
    );
    Navigator.of(context).pop();
  }

  String _errorMessageFor(String code) {
    switch (code) {
      case 'INVALID_PAIRING_CODE_FORMAT':
        return 'Pairing code must be 6 digits.';
      case 'PAIRING_CODE_NOT_FOUND':
        return 'Invalid code. Make sure you typed it correctly.';
      case 'PAIRING_CODE_EXPIRED':
        return 'This code has expired. Get a fresh one from the website.';
      case 'PAIRING_CODE_ALREADY_USED':
        return 'This code was already used. Get a fresh one.';
      case 'SESSION_NOT_FOUND_OR_NOT_PENDING':
      case 'SESSION_NOT_FOUND':
        return 'This session is no longer active. Start again from the website.';
      case 'SESSION_EXPIRED':
        return 'This session expired. Start again from the website.';
      case 'STALE_TIMESTAMP':
        return 'Device clock is out of sync. Check your device time and try again.';
      case 'INVALID_SIGNATURE':
        return 'Authentication failed. Try restarting the SOV app.';
      case 'NOT_ENROLLED':
        return 'This wallet is not enrolled on the SOV Network.';
      case 'PLATFORM_NOT_REGISTERED':
        return 'The website is not registered as a SOV Login platform.';
      case 'ALREADY_LINKED':
        // Citizen tried Flow A2 with a NEW password on a link that already
        // exists. Relay refuses to overwrite (sealed-first-verification).
        // Do NOT offer a way out on this screen: the link is sealed and the
        // relay refuses to overwrite it, so the only route in is the website.
        return 'You are already linked to this site. Sign in on the website '
               'with your SOV ID and the password you set when you linked.';
      case 'INVALID_PASSWORD_LENGTH':
        return 'Password must be 8 to 256 characters.';
      case 'NETWORK_ERROR':
        return 'Cannot reach the SOV Network. Check your internet connection.';
      case 'DB_UNAVAILABLE':
        return 'The SOV relay is temporarily unavailable. Try again in a moment.';
      default:
        return 'Something went wrong ($code). Try again.';
    }
  }

  void _showErrorDialog(String message) {
    setState(() => _errorMessage = message);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _cardBg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: const Color(0xFFEF5350).withAlpha(60)),
        ),
        title: const Text('Sign-in error', style: TextStyle(color: Colors.white)),
        content: Text(message, style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK', style: TextStyle(color: _gold)),
          ),
        ],
      ),
    );
  }

  Future<bool?> _showConfirmDialog(String platformDomain) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: _cardBg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: _gold.withAlpha(60)),
        ),
        title: const Row(
          children: [
            Icon(Icons.shield_outlined, color: _gold, size: 22),
            SizedBox(width: 10),
            Expanded(
              child: Text('Verify your SOV ID?', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This website is asking you to prove you are a real SOV citizen:',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: _navy,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _gold.withAlpha(80), width: 1),
              ),
              child: Text(
                platformDomain,
                style: const TextStyle(
                  color: _gold,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.2,
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Only continue if you started this on your own.\n\n'
              'The website will know your SOV ID and that your palm was verified. '
              'It will NOT see your wallet, your messages, or any other SOV data.\n\n'
              'If you did not start this, tap Cancel.',
              style: TextStyle(color: Colors.white60, fontSize: 12, height: 1.4),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _gold,
              foregroundColor: _navy,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Yes, Verify Me'),
          ),
        ],
      ),
    );
  }

  /// Returns the chosen password (>= 8 chars), or null if Cancel. Mandatory —
  /// there is no Skip (an empty verifier would leave the site with no way to log
  /// the citizen in afterwards). See SOV_LINK_CORRECTED_MODEL.md.
  Future<String?> _showPasswordDialog(String platformDomain) {
    final pw1 = TextEditingController();
    final pw2 = TextEditingController();
    final errNotifier = ValueNotifier<String?>(null);
    bool obscure1 = true;
    bool obscure2 = true;
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          backgroundColor: _cardBg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: _gold.withAlpha(60)),
          ),
          title: const Row(
            children: [
              Icon(Icons.lock_outline_rounded, color: _gold, size: 22),
              SizedBox(width: 10),
              Expanded(
                child: Text('Set a password',
                    style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Create a password for $platformDomain so you can sign in '
                  'next time without opening the SOV app.',
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: pw1,
                  obscureText: obscure1,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'New password (min 8 chars)',
                    labelStyle: const TextStyle(color: Colors.white60),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: _gold.withAlpha(80)),
                    ),
                    focusedBorder: const OutlineInputBorder(
                      borderSide: BorderSide(color: _gold),
                    ),
                    suffixIcon: IconButton(
                      icon: Icon(
                        obscure1
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                        color: Colors.white54,
                      ),
                      onPressed: () => setSt(() => obscure1 = !obscure1),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: pw2,
                  obscureText: obscure2,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'Confirm password',
                    labelStyle: const TextStyle(color: Colors.white60),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: _gold.withAlpha(80)),
                    ),
                    focusedBorder: const OutlineInputBorder(
                      borderSide: BorderSide(color: _gold),
                    ),
                    suffixIcon: IconButton(
                      icon: Icon(
                        obscure2
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                        color: Colors.white54,
                      ),
                      onPressed: () => setSt(() => obscure2 = !obscure2),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                ValueListenableBuilder<String?>(
                  valueListenable: errNotifier,
                  builder: (_, err, __) => err == null
                      ? const SizedBox.shrink()
                      : Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(err,
                              style: const TextStyle(
                                  color: Colors.redAccent, fontSize: 12)),
                        ),
                ),
                const SizedBox(height: 10),
                // The copy here MUST match the buttons below. It used to say
                // "Tap Skip", which was true before the corrected model removed
                // that button — leaving a citizen told to decline with no way
                // to decline. Keep this line and the actions in step.
                const Text(
                  'This password is ONLY for this site. It is NOT your SOV '
                  'wallet password. The network keeps a one-way check value, '
                  'never the password itself, and uses it to confirm you when '
                  'you sign in.',
                  style:
                      TextStyle(color: Colors.white54, fontSize: 11, height: 1.4),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child:
                  const Text('Cancel', style: TextStyle(color: Colors.white54)),
            ),
            // King's corrected model (SOV_LINK_CORRECTED_MODEL.md): the platform
            // password is MANDATORY — it is what the citizen uses to log in to the
            // website afterwards (wallet-ID + password, verified locally by the
            // site). "Skip" produced an empty verifier → "no password generated",
            // so it is removed. Cancel still aborts the whole link.
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: _gold,
                foregroundColor: _navy,
              ),
              onPressed: () {
                final a = pw1.text;
                final b = pw2.text;
                if (a.length < 8) {
                  errNotifier.value = 'Password must be at least 8 characters.';
                  return;
                }
                if (a != b) {
                  errNotifier.value = 'Passwords do not match.';
                  return;
                }
                Navigator.of(ctx).pop(a);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final busy = _checking || _authorizing;
    return Scaffold(
      backgroundColor: _navy,
      appBar: AppBar(
        backgroundColor: _navy,
        elevation: 0,
        title: const Text('Verify SOV ID',
            style: TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              const Icon(Icons.lock_outline_rounded, color: _gold, size: 56),
              const SizedBox(height: 18),
              const Text(
                'Enter the 6-digit code',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'A website wants to verify that you are a real SOV citizen.\n'
                'Open the website, look for the 6-digit code, and type it below.\n\n'
                'This proves your identity once. SOV does not keep watching you '
                'after this — the website cannot read your wallet, your messages, '
                'or anything else.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.5),
              ),
              const SizedBox(height: 32),

              // Six digit boxes
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: List.generate(6, (i) {
                  return SizedBox(
                    width: 44,
                    height: 56,
                    child: TextField(
                      controller: _digitCtrls[i],
                      focusNode: _digitFocus[i],
                      autofocus: i == 0,
                      enabled: !busy,
                      textAlign: TextAlign.center,
                      keyboardType: TextInputType.number,
                      maxLength: 1,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                      ],
                      style: const TextStyle(
                        color: _gold,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                      decoration: InputDecoration(
                        counterText: '',
                        filled: true,
                        fillColor: _cardBg,
                        contentPadding: EdgeInsets.zero,
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide:
                              BorderSide(color: _gold.withAlpha(80), width: 1),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: _gold, width: 2),
                        ),
                        disabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide:
                              const BorderSide(color: Colors.white24, width: 1),
                        ),
                      ),
                      onChanged: (v) => _onDigitChanged(i, v),
                    ),
                  );
                }),
              ),

              if (_errorMessage != null) ...[
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEF5350).withAlpha(28),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: const Color(0xFFEF5350).withAlpha(80),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline,
                          color: Color(0xFFEF5350), size: 18),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _errorMessage!,
                          style: const TextStyle(
                              color: Color(0xFFEF5350), fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 32),

              SizedBox(
                height: 52,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _gold,
                    foregroundColor: _navy,
                    disabledBackgroundColor: _gold.withAlpha(40),
                    disabledForegroundColor: Colors.white30,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: (busy || !_codeComplete) ? null : _onContinue,
                  child: busy
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5, color: _navy,
                          ),
                        )
                      : const Text('Continue',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ),

              const SizedBox(height: 28),

              // Security explainer card
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: _cardBg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white10, width: 1),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.verified_user_outlined,
                            color: _gold, size: 18),
                        SizedBox(width: 8),
                        Text(
                          'How this protects you',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    SizedBox(height: 10),
                    Text(
                      'Your 12-word seed phrase NEVER leaves this app. '
                      'When you tap Continue, this app talks to your trusted '
                      'SOV relays directly — not to the website. '
                      'You will see the website name in the next step '
                      'before anything is signed.\n\n'
                      'This is a one-time identity check, NOT a permanent link. '
                      'The website cannot read your wallet, messages or any '
                      'other SOV data, and SOV never reports back to it. After '
                      'verification you log in with a normal password — the '
                      'SOV app does not stay attached.',
                      style: TextStyle(
                          color: Colors.white60, fontSize: 12, height: 1.5),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
