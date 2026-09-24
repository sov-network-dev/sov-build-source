// lib/screens/settings_screen.dart — Session K complete rewrite
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../sov_node_sdk/key_manager.dart';
import '../sov_node_sdk/relay_connector.dart';
import '../sov_node_sdk/sov_voice_service.dart';
import '../sov_node_sdk/wallet_engine.dart';
import 'backup_restore_screen.dart';
import 'governance_screen.dart';
import 'guardian_screen.dart';
import 'guardian_setup_screen.dart';
import 'inheritance_screen.dart';
import 'pioneer_screen.dart';
import 'node_status_screen.dart';


class SettingsScreen extends StatefulWidget {
  final String sovereignId;
  const SettingsScreen({super.key, required this.sovereignId});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const _navy   = Color(0xFF0A1628);
  static const _gold   = Color(0xFFB8960C);
  static const _cardBg = Color(0xFF0D1F3A);

  String _relayNickname  = 'SOV Relay';
  bool   _autoLiveness   = true;
  String _version        = '1.0.0';
  bool   _syncing        = false;
  bool   _autoLockEnabled = true;
  int    _pinLockoutMs    = 10000; // citizen-configurable; default 10s
  int    _pioneerBadges  = 0;
  bool   _voiceEnabled   = SovVoiceService.enabled; // opt-in voice notifications
  bool   _spendLockOn    = false; // PIN-encrypts the signing key at rest
  bool   _spendLockBusy  = false;
  bool   _hwLockOn       = false; // TPM-seals the signing key at rest (Windows)
  bool   _hwLockBusy     = false;
  bool   _hwAvailable    = false; // a secure element (TPM/CNG) is present

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    PackageInfo? info;
    try { info = await PackageInfo.fromPlatform(); } catch (_) {}

    if (!mounted) return;
    setState(() {
      _relayNickname   = RelayConnector.currentRelayNickname;
      _autoLiveness    = prefs.getBool('auto_liveness')     ?? true;
      _autoLockEnabled = prefs.getBool('auto_lock_enabled') ?? true;
      _pinLockoutMs    = prefs.getInt('pin_lockout_ms')     ?? 10000;
      _version         = info?.version ?? prefs.getString('app_version') ?? '1.0.0';
    });

    // Load pioneer badge count async
    _loadPioneerBadges();
    // Load Spend-Lock state async
    KeyManager.isSpendLockEnabled().then((on) {
      if (mounted) setState(() => _spendLockOn = on);
    });
    // Load Hardware-Lock state + availability async
    KeyManager.isHardwareLockEnabled().then((on) {
      if (mounted) setState(() => _hwLockOn = on);
    });
    KeyManager.isHardwareLockAvailable().then((ok) {
      if (mounted) setState(() => _hwAvailable = ok);
    });
  }

  // ── Hardware-Lock enable/disable (TPM seal) ────────────────────────────────
  Future<void> _toggleHardwareLock(bool enable) async {
    if (enable && _spendLockOn) {
      _snack('Turn off Spend-Lock first — the two locks are mutually exclusive.');
      return;
    }
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _cardBg,
        title: Text(enable ? 'Seal key in the TPM?' : 'Remove Hardware Lock?',
            style: const TextStyle(color: Colors.white, fontSize: 16)),
        content: Text(
          enable
              ? 'Your signing key will be sealed inside this computer’s secure chip '
                '(TPM). A copy of your wallet becomes useless on any other machine. '
                'Optionally require Windows Hello every time it unlocks (approve a '
                'prompt now to set that up).\n\n'
                'Your seed phrase still restores the wallet — make sure it is backed up.'
              : 'Your key will be moved back to normal secure storage on this device.',
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
        actions: enable
            ? [
                TextButton(onPressed: () => Navigator.pop(ctx, 'cancel'),
                    child: const Text('Cancel', style: TextStyle(color: Colors.white54))),
                TextButton(onPressed: () => Navigator.pop(ctx, 'plain'),
                    child: const Text('Seal (TPM)',
                        style: TextStyle(color: Color(0xFFB8960C), fontWeight: FontWeight.bold))),
                TextButton(onPressed: () => Navigator.pop(ctx, 'hello'),
                    child: const Text('Seal + Hello',
                        style: TextStyle(color: Color(0xFFB8960C), fontWeight: FontWeight.bold))),
              ]
            : [
                TextButton(onPressed: () => Navigator.pop(ctx, 'cancel'),
                    child: const Text('Cancel', style: TextStyle(color: Colors.white54))),
                TextButton(onPressed: () => Navigator.pop(ctx, 'remove'),
                    child: const Text('Remove',
                        style: TextStyle(color: Color(0xFFB8960C), fontWeight: FontWeight.bold))),
              ],
      ),
    );
    if (choice == null || choice == 'cancel') return;
    setState(() => _hwLockBusy = true);
    bool done;
    if (enable) {
      final hello = choice == 'hello';
      done = await KeyManager.enableHardwareLock(requireHello: hello);
      if (done) {
        // Unseal a session so signing keeps working right now.
        await KeyManager.unlockHardwareSession(ttl: const Duration(hours: 12));
      }
    } else {
      done = await KeyManager.disableHardwareLock();
    }
    if (!mounted) return;
    setState(() {
      _hwLockBusy = false;
      if (done) _hwLockOn = enable;
    });
    _snack(done
        ? (enable
            ? (choice == 'hello'
                ? 'Hardware Lock ON — sealed in the TPM, Windows Hello required each unlock.'
                : 'Hardware Lock ON — key sealed in the TPM.')
            : 'Hardware Lock removed.')
        : (enable
            ? 'Could not seal the key (TPM refused or prompt cancelled — nothing changed).'
            : 'TPM could not unseal on this machine — still locked.'));
  }

  Future<void> _loadPioneerBadges() async {
    try {
      final resp = await RelayConnector.sendAndWait(
        request: {'type': 'PIONEER_GET_STATUS', 'sovereign_id': widget.sovereignId},
        responseType: 'PIONEER_STATUS_RESULT',
        timeout: const Duration(seconds: 6),
      );
      if (resp != null && resp['success'] == true && mounted) {
        final certs = resp['certifications'] as Map? ?? {};
        setState(() => _pioneerBadges = certs.length);
      }
    } catch (_) {}
  }

  // ── UI helpers ────────────────────────────────────────────────────────────

  Widget _section(String title) => Padding(
    padding: const EdgeInsets.fromLTRB(0, 24, 0, 8),
    child: Text(title,
        style: const TextStyle(
          color: Color(0xFFB8960C),
          fontSize: 11,
          fontWeight: FontWeight.bold,
          letterSpacing: 2,
        )),
  );

  Widget _row({
    required IconData icon,
    required String   title,
    String?           subtitle,
    Widget?           trailing,
    VoidCallback?     onTap,
    Color?            iconColor,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 2),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: _cardBg,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(children: [
          Icon(icon, color: iconColor ?? Colors.white38, size: 20),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(color: Colors.white, fontSize: 14)),
                if (subtitle != null)
                  Text(subtitle, style: const TextStyle(color: Colors.white38, fontSize: 12)),
              ],
            ),
          ),
          if (trailing != null) trailing
          else if (onTap != null)
            const Icon(Icons.chevron_right_rounded, color: Colors.white24, size: 20),
        ]),
      ),
    );
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: _cardBg,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ));
  }

  // ── Sync Balance ──────────────────────────────────────────────────────────

  Future<void> _syncBalance() async {
    setState(() => _syncing = true);
    try {
      if (!RelayConnector.isConnected) {
        await RelayConnector.connect();
        await Future.delayed(const Duration(seconds: 2));
      }
      final balance = await RelayConnector.queryBalance(widget.sovereignId);
      if (balance > 0) await WalletEngine.updateBalance(balance.toDouble());
      _snack(balance > 0 ? 'Balance synced: $balance Seeds' : 'Sync complete — no change');
    } catch (_) {
      _snack('Sync failed — relay unreachable');
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  // ── Fix 1: Palm Re-registration ───────────────────────────────────────────

  void _showPalmReRegDialog() {
    showModalBottomSheet(
      context: context,
      backgroundColor: _cardBg,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                  width: 36, height: 4,
                  decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2))),
            ),
            const SizedBox(height: 20),
            const Text('Palm Re-registration',
                style: TextStyle(color: Colors.white,
                    fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            const Text(
              'Your palm biometric secures access to your Sovereign wallet. '
              'Re-registration updates the local biometric record on this device only — '
              'it does not change your identity on the network.\n\n'
              'To re-register, use the Recovery screen and select '
              '"Recover with Palm". Your existing Sovereign ID and balance '
              'will be preserved.',
              style: TextStyle(color: Colors.white60, fontSize: 13, height: 1.5),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _gold,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: () => Navigator.pop(context),
                child: const Text('Got it',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Fix 6: PIN Change ─────────────────────────────────────────────────────

  void _showPinChangeSheet() {
    final currentCtrl = TextEditingController();
    final newCtrl     = TextEditingController();
    final confirmCtrl = TextEditingController();
    String? error;
    bool saving = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _cardBg,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Padding(
          padding: EdgeInsets.fromLTRB(
              24, 20, 24,
              24 + MediaQuery.of(ctx).viewInsets.bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                    width: 36, height: 4,
                    decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2))),
              ),
              const SizedBox(height: 20),
              const Text('Change PIN',
                  style: TextStyle(color: Colors.white,
                      fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              _pinField(currentCtrl, 'Current PIN', ctx),
              const SizedBox(height: 10),
              _pinField(newCtrl, 'New PIN (6 digits)', ctx),
              const SizedBox(height: 10),
              _pinField(confirmCtrl, 'Confirm New PIN', ctx),
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(error!, style: const TextStyle(
                    color: Colors.redAccent, fontSize: 12)),
              ],
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _gold,
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: saving ? null : () async {
                    setS(() { error = null; saving = true; });
                    final result = await _doChangePIN(
                      currentCtrl.text, newCtrl.text, confirmCtrl.text);
                    if (result == null) {
                      if (ctx.mounted) Navigator.pop(ctx);
                      _snack('PIN updated successfully');
                    } else {
                      setS(() { error = result; saving = false; });
                    }
                  },
                  child: saving
                      ? const SizedBox(
                          width: 20, height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.black))
                      : const Text('Update PIN',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pinField(TextEditingController ctrl, String hint, BuildContext ctx) =>
      TextField(
        controller: ctrl,
        obscureText: true,
        keyboardType: TextInputType.number,
        maxLength: 6,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        style: const TextStyle(color: Colors.white, letterSpacing: 6),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(color: Colors.white38, letterSpacing: 0),
          counterText: '',
          filled: true,
          fillColor: const Color(0xFF0A1628),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Colors.white12)),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Colors.white12)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFFB8960C))),
        ),
      );

  Future<String?> _doChangePIN(String current, String newPin, String confirm) async {
    if (current.length != 6) return 'Current PIN must be 6 digits';
    if (newPin.length  != 6) return 'New PIN must be 6 digits';
    if (newPin != confirm)   return 'New PINs do not match';

    final prefs       = await SharedPreferences.getInstance();
    final storedHash  = prefs.getString('pin_hash') ?? '';
    final currentHash = sha256.convert(utf8.encode(current)).toString();

    if (currentHash != storedHash) return 'Incorrect current PIN';

    final newHash = sha256.convert(utf8.encode(newPin)).toString();
    await prefs.setString('pin_hash', newHash);
    return null; // success
  }

  // ── Spend-Lock enable/disable ──────────────────────────────────────────────
  void _showSpendLockSheet({required bool enable}) {
    final pinCtrl = TextEditingController();
    String? error;
    bool working = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _cardBg,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Padding(
          padding: EdgeInsets.fromLTRB(
              24, 20, 24, 24 + MediaQuery.of(ctx).viewInsets.bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                    width: 36, height: 4,
                    decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2))),
              ),
              const SizedBox(height: 20),
              Row(children: [
                Icon(enable ? Icons.enhanced_encryption_outlined
                            : Icons.lock_open_outlined,
                    color: _gold, size: 22),
                const SizedBox(width: 10),
                Text(enable ? 'Turn on Spend-Lock' : 'Turn off Spend-Lock',
                    style: const TextStyle(color: Colors.white,
                        fontSize: 18, fontWeight: FontWeight.bold)),
              ]),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                    color: const Color(0xFF0A1628),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.white10)),
                child: Text(
                  enable
                    ? 'Your signing key will be encrypted with your PIN (Argon2id + '
                      'AES-256). After this, every transfer — in the app OR the CLI — '
                      'needs your PIN. If your PC is hacked, the thief gets only '
                      'ciphertext they cannot spend.\n\nYour seed phrase still restores '
                      'the wallet, so this is safe.'
                    : 'This decrypts your signing key back to normal storage. Spends '
                      'will no longer require your PIN. Only do this if you understand '
                      'the wallet becomes drainable by anything running on this device.',
                  style: const TextStyle(color: Colors.white54, fontSize: 12, height: 1.4),
                ),
              ),
              const SizedBox(height: 16),
              _pinField(pinCtrl, 'Enter your 6-digit PIN', ctx),
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(error!, style: const TextStyle(
                    color: Colors.redAccent, fontSize: 12)),
              ],
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _gold,
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: working ? null : () async {
                    if (pinCtrl.text.length != 6) {
                      setS(() => error = 'PIN must be 6 digits');
                      return;
                    }
                    setS(() { error = null; working = true; });
                    setState(() => _spendLockBusy = true);
                    bool ok;
                    try {
                      ok = enable
                          ? await KeyManager.enableSpendLock(pinCtrl.text)
                          : await KeyManager.disableSpendLock(pinCtrl.text);
                    } catch (_) {
                      ok = false;
                    }
                    if (!mounted) return;
                    setState(() {
                      _spendLockBusy = false;
                      if (ok) _spendLockOn = enable;
                    });
                    if (ok) {
                      // When enabling, unlock this session so the current app
                      // instance keeps signing without an immediate re-prompt.
                      if (enable) {
                        await KeyManager.unlockSession(pinCtrl.text,
                            ttl: const Duration(hours: 12));
                      }
                      if (ctx.mounted) Navigator.pop(ctx);
                      _snack(enable ? 'Spend-Lock is ON' : 'Spend-Lock is OFF');
                    } else {
                      setS(() { error = 'Incorrect PIN'; working = false; });
                    }
                  },
                  child: working
                      ? const SizedBox(
                          width: 20, height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.black))
                      : Text(enable ? 'Encrypt & turn on' : 'Decrypt & turn off',
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  InputDecoration _inputDeco(String hint) => InputDecoration(
    hintText: hint,
    hintStyle: const TextStyle(color: Colors.white38),
    filled: true,
    fillColor: const Color(0xFF0A1628),
    border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Colors.white12)),
    enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Colors.white12)),
    focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0xFFB8960C))),
  );

  // ── Fix 9: Certification Lookup ─────────────────────────────────────────

  void _showPioneerLookup() {
    final ctrl    = TextEditingController();
    Map<String, dynamic>? result;
    bool loading  = false;
    String? error;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _cardBg,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Padding(
          padding: EdgeInsets.fromLTRB(
              24, 20, 24,
              24 + MediaQuery.of(ctx).viewInsets.bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                    width: 36, height: 4,
                    decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2))),
              ),
              const SizedBox(height: 20),
              const Text('Certification Lookup',
                  style: TextStyle(color: Colors.white,
                      fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 14),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: ctrl,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: _inputDeco('SOV-XXXXXXXXXXXX'),
                  ),
                ),
                const SizedBox(width: 10),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _gold,
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 18, vertical: 14),
                  ),
                  onPressed: loading ? null : () async {
                    final id = ctrl.text.trim();
                    if (id.isEmpty) return;
                    setS(() { loading = true; error = null; result = null; });
                    try {
                      final resp = await RelayConnector.sendAndWait(
                        request: {'type': 'PIONEER_GET_STATUS', 'sovereign_id': id},
                        responseType: 'PIONEER_STATUS_RESULT',
                        timeout: const Duration(seconds: 8),
                      );
                      if (resp != null && resp['success'] == true) {
                        setS(() { result = resp; loading = false; });
                      } else {
                        setS(() {
                          error = resp?['error'] ?? 'Not found';
                          loading = false;
                        });
                      }
                    } catch (_) {
                      setS(() { error = 'Relay unreachable'; loading = false; });
                    }
                  },
                  child: loading
                      ? const SizedBox(width: 18, height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.black))
                      : const Text('Lookup',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ]),
              if (error != null) ...[
                const SizedBox(height: 10),
                Text(error!, style: const TextStyle(
                    color: Colors.redAccent, fontSize: 12)),
              ],
              if (result != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0A1628),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _gold.withAlpha(40)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _lookupRow('Certified', result!['is_pioneer'] == true ? 'Yes' : 'No'),
                      _lookupRow('Rank',   result!['rank'] ?? '—'),
                      ...(result!['certifications'] as Map? ?? {})
                          .entries
                          .map((e) => _lookupRow('Badge', '${e.key}  ✓')),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _lookupRow(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(children: [
      SizedBox(
        width: 80,
        child: Text(label,
            style: const TextStyle(color: Colors.white38, fontSize: 12)),
      ),
      Expanded(
        child: Text(value,
            style: const TextStyle(color: Colors.white, fontSize: 13,
                fontWeight: FontWeight.w600)),
      ),
    ]),
  );

  // ── Build ──────────────────────────────────────────────────────────────────

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
        title: const Text('Settings',
            style: TextStyle(color: Color(0xFFB8960C),
                fontWeight: FontWeight.bold, fontSize: 18)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [

          // ── Identity ────────────────────────────────────────────────────
          _section('IDENTITY'),
          _row(
            icon: Icons.fingerprint_rounded,
            title: 'Sovereign ID',
            subtitle: widget.sovereignId.length > 30
                ? '${widget.sovereignId.substring(0, 18)}…${widget.sovereignId.substring(widget.sovereignId.length - 8)}'
                : widget.sovereignId,
            trailing: IconButton(
              icon: const Icon(Icons.copy_rounded, color: Colors.white24, size: 18),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: widget.sovereignId));
                _snack('Sovereign ID copied');
              },
            ),
          ),

          // ── Security ────────────────────────────────────────────────────
          _section('SECURITY'),
          _row(
            icon: Icons.shield_outlined,
            title: 'Palm Re-registration',
            subtitle: 'Update biometric if palm changes',
            onTap: _showPalmReRegDialog,
          ),
          _row(
            icon: Icons.pin_outlined,
            title: 'Change PIN',
            subtitle: 'Update your 6-digit access PIN',
            onTap: _showPinChangeSheet,
          ),
          _row(
            icon: Icons.lock_outline_rounded,
            title: 'Auto-lock on return',
            subtitle: _autoLockEnabled
                ? 'After ${_formatLockout(_pinLockoutMs)} in background'
                : 'Off — app stays unlocked between sessions',
            trailing: Switch(
              value: _autoLockEnabled,
              activeThumbColor: _gold,
              activeTrackColor: _gold,
              onChanged: (v) async {
                if (!v) {
                  // Warn before turning OFF — this is a real security
                  // reduction: anyone with the phone unlocked can use the app.
                  final ok = await _confirmDisableAutoLock();
                  if (!ok) return;
                }
                setState(() => _autoLockEnabled = v);
                final prefs = await SharedPreferences.getInstance();
                await prefs.setBool('auto_lock_enabled', v);
              },
            ),
          ),
          if (_autoLockEnabled)
            _row(
              icon: Icons.timer_outlined,
              title: 'Lock after',
              subtitle: _formatLockout(_pinLockoutMs),
              onTap: _showLockoutPicker,
            ),
          _row(
            icon: Icons.enhanced_encryption_outlined,
            iconColor: _spendLockOn ? _gold : Colors.white38,
            title: 'Spend-Lock',
            subtitle: _spendLockOn
                ? 'ON — signing key encrypted with your PIN'
                : 'Encrypt your signing key with your PIN',
            trailing: _spendLockBusy
                ? const SizedBox(
                    width: 20, height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: _gold))
                : Switch(
                    value: _spendLockOn,
                    activeThumbColor: _gold,
                    activeTrackColor: _gold,
                    onChanged: (v) => _showSpendLockSheet(enable: v),
                  ),
          ),
          if (_hwAvailable)
            _row(
              icon: Icons.memory_rounded,
              iconColor: _hwLockOn ? _gold : Colors.white38,
              title: 'Hardware Lock (TPM)',
              subtitle: _hwLockOn
                  ? 'ON — signing key sealed in this PC’s secure chip'
                  : 'Seal your key in the TPM — useless if copied off this PC',
              trailing: _hwLockBusy
                  ? const SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: _gold))
                  : Switch(
                      value: _hwLockOn,
                      activeThumbColor: _gold,
                      activeTrackColor: _gold,
                      onChanged: (v) => _toggleHardwareLock(v),
                    ),
            ),
          _row(
            icon: Icons.timer_outlined,
            title: 'Auto Liveness Reminder',
            subtitle: 'Alert when biometric check is overdue',
            trailing: Switch(
              value: _autoLiveness,
              activeThumbColor: _gold,
              activeTrackColor: _gold,
              onChanged: (v) async {
                setState(() => _autoLiveness = v);
                final prefs = await SharedPreferences.getInstance();
                await prefs.setBool('auto_liveness', v);
              },
            ),
          ),

          // ── Notifications ───────────────────────────────────────────────
          _section('NOTIFICATIONS'),
          _row(
            icon: Icons.record_voice_over_rounded,
            title: 'Voice notifications',
            subtitle: _voiceEnabled
                ? 'Speaks new messages, exchange orders, payments…'
                : 'Off — turn on to hear spoken alerts',
            iconColor: _voiceEnabled ? _gold : Colors.white38,
            trailing: Switch(
              value: _voiceEnabled,
              activeThumbColor: _gold,
              activeTrackColor: _gold,
              onChanged: (v) async {
                setState(() => _voiceEnabled = v);
                await SovVoiceService.setEnabled(v); // persists + previews on ON
              },
            ),
          ),

          // ── Network ─────────────────────────────────────────────────────
          _section('NETWORK'),
          _row(
            icon: Icons.cell_tower_rounded,
            title: 'Connected Relay',
            subtitle: _relayNickname,
          ),
          _row(
            icon: Icons.sync_rounded,
            title: 'Sync Now',
            trailing: _syncing
                ? const SizedBox(
                    width: 18, height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 1.5, color: Color(0xFFB8960C)))
                : null,
            onTap: _syncing ? null : _syncBalance,
          ),
          _row(
            icon: Icons.hub_outlined,
            title: 'Node Status',
            subtitle: RelayConnector.isConnected
                ? 'Connected · $_relayNickname'
                : 'Offline',
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const NodeStatusScreen())),
          ),
          _row(
            icon: Icons.dns_rounded,
            title: 'Run a SOV Node',
            subtitle: 'Become a relay operator — earn proof-of-service rewards',
            iconColor: _gold,
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const NodeStatusScreen())),
          ),

          // ── Recovery ────────────────────────────────────────────────────
          _section('RECOVERY'),
          _row(
            icon: Icons.shield_moon_outlined,
            title: 'Backup & Restore',
            subtitle: 'Full encrypted backup — keys, contacts, wallet',
            iconColor: _gold,
            onTap: () => Navigator.push(context,
                MaterialPageRoute(
                    builder: (_) =>
                        BackupRestoreScreen(sovereignId: widget.sovereignId))),
          ),
          _row(
            icon: Icons.shield_rounded,
            title: 'Guardians',
            subtitle: 'Manage trusted guardians for account recovery',
            iconColor: const Color(0xFFD4AF37),
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const GuardianScreen())),
          ),
          _row(
            icon: Icons.group_outlined,
            title: 'Guardian Setup (Legacy)',
            subtitle: 'Original 3-guardian nomination',
            onTap: () => Navigator.push(context,
                MaterialPageRoute(
                    builder: (_) =>
                        GuardianSetupScreen(sovereignId: widget.sovereignId))),
          ),
          _row(
            icon: Icons.account_balance_wallet_outlined,
            title: 'SOV Vault',
            subtitle: 'SOV protection vault for your beneficiaries',
            onTap: () => Navigator.push(context,
                MaterialPageRoute(
                    builder: (_) =>
                        InheritanceScreen(sovereignId: widget.sovereignId, seeds: 0))),
          ),

          // ── Certification ────────────────────────────────────────────────
          _section('CERTIFICATION'),
          _row(
            icon: Icons.military_tech_rounded,
            title: 'Certifications',
            subtitle: _pioneerBadges > 0
                ? '$_pioneerBadges badge${_pioneerBadges == 1 ? '' : 's'} earned'
                : 'Earn badges by passing assessments',
            iconColor: const Color(0xFFD4AF37),
            onTap: () => Navigator.push(context,
                MaterialPageRoute(
                    builder: (_) => PioneerScreen(sovereignId: widget.sovereignId))),
          ),
          _row(
            icon: Icons.search_rounded,
            title: 'Certification Lookup',
            subtitle: 'View another citizen\'s badges',
            onTap: _showPioneerLookup,
          ),

          // ── Governance ──────────────────────────────────────────────────
          _section('GOVERNANCE'),
          _row(
            icon: Icons.how_to_vote_rounded,
            title: 'Network Governance',
            subtitle: 'Active polls & community votes',
            onTap: () => Navigator.push(context,
                MaterialPageRoute(
                    builder: (_) =>
                        GovernanceScreen(sovereignId: widget.sovereignId))),
          ),

          // ── About ───────────────────────────────────────────────────────
          _section('ABOUT'),
          _row(
            icon: Icons.info_outline_rounded,
            title: 'Version',
            subtitle: _version,
          ),
          _row(
            icon: Icons.article_outlined,
            title: 'SOV Network Blueprint',
            subtitle: 'v14.0',
            onTap: () => showAboutDialog(
              context: context,
              applicationName: 'SOV',
              applicationVersion: _version,
              applicationLegalese:
                  'SOV Network Master Blueprint v14.0\n\n'
                  'A decentralised biometric-anchored sovereign identity '
                  'and value-transfer network.\n\n'
                  'Network: sovereign-mainnet-1',
            ),
          ),
        ],
      ),
    );
  }

  // ── PIN lock helpers ───────────────────────────────────────────────────────

  String _formatLockout(int ms) {
    if (ms <= 0)       return 'Immediately';
    if (ms < 60000)    return '${(ms / 1000).round()} seconds';
    if (ms < 3600000)  return '${(ms / 60000).round()} minutes';
    return '${(ms / 3600000).round()} hours';
  }

  /// Show a confirmation dialog before disabling auto-lock entirely. Returns
  /// true if the citizen explicitly confirmed the security trade-off.
  Future<bool> _confirmDisableAutoLock() async {
    final result = await showDialog<bool>(
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
            Icon(Icons.warning_amber_rounded, color: Colors.orangeAccent),
            SizedBox(width: 10),
            Expanded(
              child: Text('Turn off auto-lock?',
                  style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
        content: const Text(
          'Anyone holding your phone will be able to use SOV without entering '
          'your PIN. The PIN will still be required when you cold-start the '
          'app, but never when you switch back from another app.\n\n'
          'You can re-enable this at any time.',
          style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel',
                style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orangeAccent,
              foregroundColor: Colors.black,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Turn off',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    return result == true;
  }

  /// Choose how long the app can stay backgrounded before the PIN re-locks it.
  void _showLockoutPicker() {
    const options = <int>[
      0,        // Immediately
      10000,    // 10 seconds (current default)
      30000,    // 30 seconds
      60000,    // 1 minute
      300000,   // 5 minutes
      900000,   // 15 minutes
    ];
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _cardBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 18, bottom: 10),
                child: Text('Lock after…',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    )),
              ),
              ...options.map((ms) {
                final selected = ms == _pinLockoutMs;
                return ListTile(
                  leading: Icon(
                    selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    color: selected ? _gold : Colors.white38,
                  ),
                  title: Text(
                    _formatLockout(ms),
                    style: TextStyle(
                      color: selected ? _gold : Colors.white,
                      fontWeight:
                          selected ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  onTap: () async {
                    setState(() => _pinLockoutMs = ms);
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setInt('pin_lockout_ms', ms);
                    if (ctx.mounted) Navigator.of(ctx).pop();
                  },
                );
              }),
              const SizedBox(height: 14),
            ],
          ),
        );
      },
    );
  }
}
