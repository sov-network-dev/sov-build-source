// lib/screens/profile_screen.dart
// ─────────────────────────────────────────────────────────────────────────────
// Profile Tab — Citizen identity, settings, recovery.
//
// Privacy model (locked):
//   Identity on the SOV network = Sovereign ID only.
//   The avatar is a deterministic identicon generated from the Sovereign ID —
//   unique, immutable, generated locally, never uploaded to any relay.
//   Citizens do not choose display names or aliases. The network assigned the
//   Sovereign ID at enrollment and that is the full network identity.
// ─────────────────────────────────────────────────────────────────────────────
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../main.dart';
import '../sov_node_sdk/relay_connector.dart';
import '../widgets/palm_avatar.dart';
import 'pin_setup_screen.dart';
import 'guardian_setup_screen.dart';
import 'liveness_screen.dart';
import 'pioneer_screen.dart';
import 'relay_pool_screen.dart';
import '../sov_node_sdk/sov_currency.dart';
import '../sov_node_sdk/sov_voice_service.dart';
import 'backup_restore_screen.dart';
import 'connect_external_site_screen.dart';
import 'platform_register_screen.dart';
import 'blueprint_viewer_screen.dart';
import 'wallet_reset_screen.dart';

class ProfileScreen extends StatefulWidget {
  final String sovereignId;
  const ProfileScreen({super.key, required this.sovereignId});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  static const _navy   = Color(0xFF0A1628);
  static const _gold   = Color(0xFFD4AF37);
  static const _cardBg = Color(0xFF0D1F3A);

  String _version        = '';
  String _palmName       = '';
  bool   _autoLock       = true;
  bool   _pinEnabled     = true;   // PIN function on/off (king 2026-06-04)
  int    _autoLockMs     = 10000;  // auto-lock delay (pin_lockout_ms) — duration selector
  bool   _autoLiveness   = true;
  bool   _readReceipts   = true;
  bool   _voiceEnabled   = SovVoiceService.enabled; // opt-in spoken alerts
  String _currencyCode   = 'USD';

  // Auto-lock duration options (label → ms). 'Never' disables auto-lock entirely.
  static const Map<String, int> _autoLockOptions = {
    'Immediately': 0,
    '10 seconds':  10000,
    '30 seconds':  30000,
    '1 minute':    60000,
    '5 minutes':   300000,
    'Never':       -1,
  };

  Map<String, bool> _certs = {
    'RE': false,
    'EA': false,
    'PS': false,
  };

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    _loadCerts();
    _loadVersion();
    _loadPalmName();
  }

  Future<void> _loadPalmName() async {
    final name = await RelayConnector.getPalmName();
    if (mounted) setState(() => _palmName = name);
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        // FIX: the lock logic in main.dart reads 'auto_lock_enabled' + 'pin_lockout_ms';
        // the old toggle wrote 'auto_lock' (a dead key) so it never took effect.
        _autoLock      = prefs.getBool('auto_lock_enabled')      ?? true;
        _autoLockMs    = prefs.getInt('pin_lockout_ms')          ?? 10000;
        _pinEnabled    = prefs.getBool('pin_enabled')            ?? true;
        _autoLiveness  = prefs.getBool('auto_liveness')          ?? true;
        _readReceipts  = prefs.getBool('read_receipts_enabled')  ?? true;
        _voiceEnabled  = SovVoiceService.enabled;
        _currencyCode  = prefs.getString(SovCurrency.prefKey)   ??
                         SovCurrency.autoDetect();
      });
    }
  }

  Future<void> _setCurrency(String code) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(SovCurrency.prefKey, code);
    if (mounted) setState(() => _currencyCode = code);
  }

  Future<void> _showCurrencyPicker() async {
    final currencies = SovCurrency.allCurrencies;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: _cardBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Column(
        children: [
          const SizedBox(height: 12),
          Container(
            width: 40, height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 16),
          const Text('Display Currency',
              style: TextStyle(color: Colors.white,
                  fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Expanded(
            child: ListView.builder(
              itemCount: currencies.length,
              itemBuilder: (_, i) {
                final c      = currencies[i];
                final isSelected = c['code'] == _currencyCode;
                return ListTile(
                  leading: Text(c['symbol']!,
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 18)),
                  title: Text('${c['code']} — ${c['name']}',
                      style: TextStyle(
                          color: isSelected ? _gold : Colors.white70,
                          fontWeight: isSelected
                              ? FontWeight.w600 : FontWeight.normal)),
                  trailing: isSelected
                      ? const Icon(Icons.check_rounded,
                          color: Color(0xFFD4AF37), size: 18)
                      : null,
                  onTap: () {
                    _setCurrency(c['code']!);
                    Navigator.pop(ctx);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _loadCerts() async {
    if (widget.sovereignId.isEmpty) return;
    try {
      final resp = await RelayConnector.pioneerGetStatus(widget.sovereignId);
      if (resp['success'] == true && mounted) {
        final m =
            (resp['certifications'] as Map?)?.cast<String, dynamic>() ?? {};
        setState(() {
          _certs = {
            'RE': m['relay_engineer']      == true,
            'EA': m['enrollment_agent']    == true,
            'PS': m['protocol_specialist'] == true,
          };
        });
      }
    } catch (_) {}
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _version = info.version);
    } catch (_) {}
  }

  Future<void> _setAutoLock(bool val) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_lock_enabled', val);   // FIX: key main.dart actually reads
    if (mounted) setState(() => _autoLock = val);
  }

  /// PIN-disable toggle (king 2026-06-04). When off, the app never shows the PIN
  /// lock (cold start or resume). main.dart's lock gate + PinLockOverlay honour
  /// 'pin_enabled'. Disabling also implies no auto-lock relock.
  Future<void> _setPinEnabled(bool val) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('pin_enabled', val);
    if (mounted) setState(() => _pinEnabled = val);
  }

  /// Auto-lock duration selector (king 2026-06-04). Writes pin_lockout_ms (read by
  /// main.dart). ms == -1 ⇒ 'Never' ⇒ also clears auto_lock_enabled.
  Future<void> _setAutoLockMs(int ms) async {
    final prefs = await SharedPreferences.getInstance();
    if (ms < 0) {
      await prefs.setBool('auto_lock_enabled', false);
      if (mounted) setState(() { _autoLock = false; _autoLockMs = ms; });
    } else {
      await prefs.setBool('auto_lock_enabled', true);
      await prefs.setInt('pin_lockout_ms', ms);
      if (mounted) setState(() { _autoLock = true; _autoLockMs = ms; });
    }
  }

  String _autoLockLabel() {
    for (final e in _autoLockOptions.entries) {
      if (e.value == _autoLockMs) return e.key;
    }
    return '${(_autoLockMs / 1000).round()} seconds';
  }

  void _showAutoLockPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: _cardBg,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Auto-lock after',
                  style: TextStyle(color: Colors.white, fontSize: 16,
                      fontWeight: FontWeight.bold)),
            ),
            ..._autoLockOptions.entries.map((e) => ListTile(
                  title: Text(e.key,
                      style: const TextStyle(color: Colors.white70)),
                  trailing: (e.value == _autoLockMs)
                      ? const Icon(Icons.check_rounded, color: _gold)
                      : null,
                  onTap: () { _setAutoLockMs(e.value); Navigator.pop(ctx); },
                )),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _setAutoLiveness(bool val) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_liveness', val);
    if (mounted) setState(() => _autoLiveness = val);
  }

  Future<void> _setReadReceipts(bool val) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('read_receipts_enabled', val);
    if (mounted) setState(() => _readReceipts = val);
  }

  /// Opt-in spoken alerts (default off). Enabling plays a short preview so the
  /// citizen hears the voice immediately. Works on every platform.
  Future<void> _setVoiceEnabled(bool val) async {
    await SovVoiceService.setEnabled(val); // persists + previews on ON
    if (mounted) setState(() => _voiceEnabled = val);
  }

  Future<void> _syncNow() async {
    try {
      if (!RelayConnector.isConnected) await RelayConnector.connect();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Sync complete'),
          backgroundColor: Color(0xFF0D1F3A),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Sync failed — check network'),
          backgroundColor: Color(0xFF0D1F3A),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const ValueKey('profileScreenScaffold'),
      backgroundColor: _navy,
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: _buildIdentityHeader()),
            SliverToBoxAdapter(
              child: _buildSection('SECURITY', [
                _buildRow(
                  icon:    Icons.lock_rounded,
                  title:   'Change PIN',
                  sub:     'Update your 6-digit unlock PIN',
                  onTap:   () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => PinSetupScreen(
                        title:    'Change PIN',
                        subtitle: 'Set a new 6-digit PIN for this wallet.',
                        onPinSet: (hash) async {
                          final prefs =
                              await SharedPreferences.getInstance();
                          await prefs.setString('pin_hash', hash);
                          SovereignApp.updatePinCache(hash);
                        },
                      ),
                    ),
                  ),
                ),
                _buildToggleRow(
                  icon:    Icons.password_rounded,
                  title:   'Require PIN',
                  sub:     _pinEnabled
                      ? 'App is protected by a PIN'
                      : 'PIN disabled — app opens without a PIN',
                  value:   _pinEnabled,
                  onChanged: _setPinEnabled,
                ),
                _buildToggleRow(
                  icon:    Icons.lock_clock_outlined,
                  title:   'Auto-lock',
                  sub:     'Lock app when you switch away',
                  value:   _autoLock,
                  onChanged: _setAutoLock,
                ),
                // Auto-lock duration selector (king 2026-06-04). Only relevant
                // when PIN + auto-lock are on.
                if (_pinEnabled && _autoLock)
                  _buildRow(
                    icon:    Icons.timer_outlined,
                    title:   'Auto-lock after',
                    sub:     _autoLockLabel(),
                    onTap:   _showAutoLockPicker,
                  ),
                _buildToggleRow(
                  icon:    Icons.done_all_rounded,
                  title:   'Read receipts',
                  sub:     'Let contacts know you have read their messages',
                  value:   _readReceipts,
                  onChanged: _setReadReceipts,
                ),
                _buildRow(
                  icon:    Icons.favorite_outline_rounded,
                  title:   'Proof of Life',
                  sub:     'Confirm you are active so your vaults stay locked to you. Logging in refreshes this automatically.',
                  onTap:   () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => LivenessScreen(
                          sovereignId: widget.sovereignId),
                    ),
                  ),
                ),
                _buildToggleRow(
                  icon:    Icons.face_outlined,
                  title:   'Liveness reminders',
                  sub:     'Remind me when liveness is due',
                  value:   _autoLiveness,
                  onChanged: _setAutoLiveness,
                ),
                _buildRow(
                  icon:    Icons.verified_user_outlined,
                  title:   'Verify My SOV ID with External Site',
                  sub:     'One-time proof of identity to a SOV-enabled website. SOV does not share your data afterwards.',
                  onTap:   () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const ConnectExternalSiteScreen(),
                    ),
                  ),
                ),
                _buildRow(
                  icon:    Icons.dns_outlined,
                  title:   'Register a Platform',
                  sub:     'Own a website? Let people sign in with their SOV ID. Registered from your wallet — no server setup.',
                  onTap:   () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const PlatformRegisterScreen(),
                    ),
                  ),
                ),
              ]),
            ),
            SliverToBoxAdapter(
              child: _buildSection('NOTIFICATIONS', [
                _buildToggleRow(
                  icon:    _voiceEnabled
                      ? Icons.record_voice_over_rounded
                      : Icons.voice_over_off_rounded,
                  title:   'Voice notifications',
                  sub:     _voiceEnabled
                      ? 'Spoken alerts for messages, transfers and more — even when locked'
                      : 'Hear a spoken alert when something happens. Off by default.',
                  value:   _voiceEnabled,
                  onChanged: _setVoiceEnabled,
                ),
              ]),
            ),
            SliverToBoxAdapter(
              child: _buildSection('RECOVERY', [
                _buildRow(
                  icon:    Icons.shield_outlined,
                  title:   'Guardian Setup',
                  sub:     'Nominate 3 trusted citizens',
                  onTap:   () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => GuardianSetupScreen(
                          sovereignId: widget.sovereignId),
                    ),
                  ),
                ),
                _buildRow(
                  icon:    Icons.shield_moon_outlined,
                  iconColor: _gold,
                  title:   'Backup & Restore',
                  sub:     'Full encrypted backup — keys, contacts, wallet',
                  onTap:   () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => BackupRestoreScreen(
                          sovereignId: widget.sovereignId),
                    ),
                  ),
                ),
                _buildRow(
                  icon:    Icons.article_outlined,
                  title:   'Seed Phrase',
                  sub:     'View your 12-word recovery phrase',
                  onTap:   _showSeedReminder,
                ),
              ]),
            ),
            SliverToBoxAdapter(
              child: _buildSection('DANGER ZONE', [
                _buildRow(
                  icon:      Icons.delete_forever_outlined,
                  iconColor: Colors.redAccent,
                  title:     'Remove Wallet From This Device',
                  sub:       'Erase your wallet from this device before selling, '
                             'giving it away, or starting over. Your seed phrase is '
                             'the only way back — save it first.',
                  onTap:     () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => WalletResetScreen(
                          sovereignId: widget.sovereignId),
                    ),
                  ),
                ),
              ]),
            ),
            SliverToBoxAdapter(
              child: _buildSection('ACADEMY', [
                _buildRow(
                  icon:    Icons.school_outlined,
                  title:   'Certifications',
                  sub:     _certsSubtitle,
                  onTap:   () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          PioneerScreen(sovereignId: widget.sovereignId),
                    ),
                  ).then((_) => _loadCerts()),
                  trailing: _certBadges(),
                ),
              ]),
            ),
            SliverToBoxAdapter(
              child: _buildSection('DISPLAY', [
                _buildRow(
                  icon:  Icons.currency_exchange_rounded,
                  title: 'Display Currency',
                  sub:   '$_currencyCode — ${SovCurrency.nameFor(_currencyCode)}',
                  onTap: _showCurrencyPicker,
                ),
              ]),
            ),
            SliverToBoxAdapter(
              child: _buildSection('NETWORK', [
                _buildRow(
                  icon:    Icons.lan_outlined,
                  title:   'Relay Pool',
                  sub:     'View connected relays and their status',
                  onTap:   () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const RelayPoolScreen(),
                    ),
                  ),
                ),
                _buildRow(
                  icon:    Icons.sync_rounded,
                  title:   'Sync Now',
                  sub:     'Reconnect and refresh the ledger',
                  onTap:   _syncNow,
                ),
              ]),
            ),
            SliverToBoxAdapter(
              child: _buildSection('ABOUT', [
                _buildRow(
                  icon:    Icons.info_outline_rounded,
                  title:   'Version',
                  sub:     _version.isEmpty ? 'Loading…' : _version,
                  onTap:   null,
                ),
                _buildRow(
                  icon:    Icons.menu_book_outlined,
                  title:   'SOV Network Blueprint',
                  sub:     'How the protocol works — in plain language',
                  onTap:   () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const BlueprintViewerScreen(),
                    ),
                  ),
                ),
              ]),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 48)),
          ],
        ),
      ),
    );
  }

  // ── IDENTITY HEADER ────────────────────────────────────────────────────────
  // Privacy-first: shows deterministic identicon + Sovereign ID only.
  // No names, no bios, no uploaded avatars.
  // The Sovereign ID IS the citizen's identity on the SOV network.

  Widget _buildIdentityHeader() {
    final anyBadge = _certs.values.any((v) => v);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Palm-derived generative avatar — unique to this citizen's palm
              PalmAvatar(
                palmName:    _palmName.isNotEmpty ? _palmName : RelayConnector.getPalmNameSync(),
                sovereignId: widget.sovereignId,
                size:        72,
                circular:    false,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Tap-to-copy Sovereign ID
                    GestureDetector(
                      onTap: () {
                        Clipboard.setData(
                            ClipboardData(text: widget.sovereignId));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Sovereign ID copied'),
                            backgroundColor: Color(0xFF0D1F3A),
                            behavior: SnackBarBehavior.floating,
                            duration: Duration(seconds: 2),
                          ),
                        );
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: _cardBg,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: Colors.white.withAlpha(15)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                widget.sovereignId,
                                style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 13,
                                    fontFamily: 'monospace',
                                    fontWeight: FontWeight.w600),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 6),
                            const Icon(Icons.copy_all_rounded,
                                color: Colors.white24, size: 13),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'SOV Network Citizen',
                      style: TextStyle(
                          color: Colors.white38,
                          fontSize: 11,
                          letterSpacing: 0.5),
                    ),
                  ],
                ),
              ),
            ],
          ),
          // Badge chips (certifications only)
          if (anyBadge) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                if (_certs['RE'] == true) _chipBadge('[RE]'),
                if (_certs['EA'] == true) _chipBadge('[EA]'),
                if (_certs['PS'] == true) _chipBadge('[PS]'),
              ],
            ),
          ],
          const SizedBox(height: 20),
          Divider(color: Colors.white.withAlpha(12)),
        ],
      ),
    );
  }

  Widget _chipBadge(String label) {
    return Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: _gold.withAlpha(25),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: _gold.withAlpha(100)),
      ),
      child: Text(
        label,
        style: const TextStyle(
            color: Color(0xFFD4AF37),
            fontSize: 10,
            fontWeight: FontWeight.bold,
            fontFamily: 'monospace'),
      ),
    );
  }

  // ── SECTIONS ───────────────────────────────────────────────────────────────

  Widget _buildSection(String title, List<Widget> rows) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Color(0xFFD4AF37),
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.4,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: _cardBg,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withAlpha(10)),
            ),
            child: Column(
              children: rows
                  .asMap()
                  .entries
                  .map((e) => Column(
                        children: [
                          e.value,
                          if (e.key < rows.length - 1)
                            Divider(
                                height: 1,
                                color: Colors.white.withAlpha(10),
                                indent: 56),
                        ],
                      ))
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRow({
    required IconData  icon,
    required String    title,
    required String    sub,
    VoidCallback?      onTap,
    Widget?            trailing,
    Color?             iconColor,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 36, height: 36,
              decoration: BoxDecoration(
                color: Colors.white.withAlpha(8),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon,
                  color: iconColor ?? Colors.white54, size: 18),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w500)),
                  const SizedBox(height: 2),
                  Text(sub,
                      style: const TextStyle(
                          color: Colors.white38, fontSize: 12)),
                ],
              ),
            ),
            if (trailing != null)
              trailing
            else if (onTap != null)
              const Icon(Icons.chevron_right_rounded,
                  color: Colors.white24, size: 18),
          ],
        ),
      ),
    );
  }

  Widget _buildToggleRow({
    required IconData  icon,
    required String    title,
    required String    sub,
    required bool      value,
    required void Function(bool) onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              color: Colors.white.withAlpha(8),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: Colors.white54, size: 18),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w500)),
                const SizedBox(height: 2),
                Text(sub,
                    style: const TextStyle(
                        color: Colors.white38, fontSize: 12)),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            thumbColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.selected)) return const Color(0xFFD4AF37);
              return Colors.white38;
            }),
            trackColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.selected)) return const Color(0xFFD4AF37).withAlpha(55);
              return Colors.white.withAlpha(20);
            }),
          ),
        ],
      ),
    );
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  String get _certsSubtitle {
    final earned = _certs.values.where((v) => v).length;
    if (earned == 0) return 'No certifications yet — start learning';
    return '$earned of 3 certifications earned';
  }

  Widget? _certBadges() {
    final any = _certs.values.any((v) => v);
    if (!any) return null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_certs['RE'] == true) _chipBadge('[RE]'),
        if (_certs['EA'] == true) _chipBadge('[EA]'),
        if (_certs['PS'] == true) _chipBadge('[PS]'),
      ],
    );
  }

  void _showSeedReminder() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _cardBg,
        title: const Text('Seed Phrase',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: const Text(
          'Your 12-word seed phrase is the master key to your wallet. '
          'It is stored only on this device. Write it down and keep it safe — '
          'no one else has a copy and it cannot be recovered if lost.',
          style: TextStyle(color: Colors.white60, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Understood',
                style: TextStyle(color: Color(0xFFD4AF37))),
          ),
        ],
      ),
    );
  }
}
