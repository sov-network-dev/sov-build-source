import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../sov_node_sdk/relay_connector.dart';

/// Register a Platform — wallet-side external-platform registration.
///
/// A website owner registers their site to use SOV Login directly from inside
/// the wallet: no external IP exposure, no command-line script. The wallet signs
/// the request with the owner's enrolled key and burns the platform-registration
/// fee (default 10 SOV) → operator pool. On success the owner gets a platform_id
/// + callback_secret to paste into their site's SOV Login configuration.
class PlatformRegisterScreen extends StatefulWidget {
  const PlatformRegisterScreen({super.key});

  @override
  State<PlatformRegisterScreen> createState() => _PlatformRegisterScreenState();
}

class _PlatformRegisterScreenState extends State<PlatformRegisterScreen> {
  static const _navy   = Color(0xFF0A1628);
  static const _gold   = Color(0xFFB8960C);
  static const _cardBg = Color(0xFF0D1F3A);
  static const _teal   = Color(0xFF006B5E);

  final _domainCtrl    = TextEditingController();
  final _returnUrlCtrl = TextEditingController();

  // Static, universal "get the app" badge — same markup for every platform,
  // no signing, no relay round-trip. Self-contained (inline styles, no
  // external CSS/JS) so any platform can paste it as-is.
  static const _kAppBadgeSnippet = '''
<div style="margin-top:16px;padding:16px;background:#0D1F3A;border:1px solid rgba(212,175,55,.35);border-radius:14px;display:flex;gap:14px;align-items:center;">
  <img src="https://sov-network.github.io/get-qr.png" width="84" height="84" alt="Scan to get the SOV app" style="border-radius:8px;background:#fff;padding:4px;flex:0 0 auto">
  <div style="color:#fff;font:14px/1.4 -apple-system,Segoe UI,Roboto,sans-serif">
    <div style="color:#D4AF37;font-weight:700;margin-bottom:4px">Don't have the SOV app yet?</div>
    Scan to download it directly — no app store needed.<br>
    <a href="https://sov-network.github.io/get.html" target="_blank" rel="noopener" style="color:#D4AF37">Or tap here on this device &rarr;</a>
  </div>
</div>''';

  bool _submitting = false;
  String _error = '';
  Map<String, dynamic>? _result;   // success payload

  @override
  void dispose() {
    _domainCtrl.dispose();
    _returnUrlCtrl.dispose();
    super.dispose();
  }

  String _friendlyError(String code) {
    switch (code) {
      case 'SOV_LOGIN_NOT_ACTIVATED':
        return 'SOV Login is not active on the network yet. It must be enabled by a governance vote before platforms can register.';
      case 'NOT_ENROLLED':
        return 'Your wallet is not enrolled as a citizen. Enroll first, then register your platform.';
      case 'INSUFFICIENT_BALANCE':
        return 'Not enough SOV to pay the registration fee. Top up and try again.';
      case 'DOMAIN_ALREADY_CLAIMED':
        return 'This domain was already registered by a different citizen.';
      case 'INVALID_DOMAIN':
        return 'Please enter a valid domain (e.g. example.com).';
      case 'INVALID_RETURN_URL':
        return 'The callback URL must start with http:// or https://';
      case 'INVALID_SIGNATURE':
      case 'SIGNING_FAILED':
        return 'Could not sign the request with your wallet key. Try reconnecting.';
      case 'NO_RESPONSE':
        return 'No response from the network. Check your connection and try again.';
      case 'STALE_TIMESTAMP':
        return 'Your device clock is out of sync. Fix the time and try again.';
      default:
        return 'Registration failed: $code';
    }
  }

  Future<void> _submit() async {
    final domain    = _domainCtrl.text.trim();
    final returnUrl = _returnUrlCtrl.text.trim();
    if (domain.isEmpty || returnUrl.isEmpty) {
      setState(() => _error = 'Enter both your domain and the callback URL.');
      return;
    }
    // Fee confirmation — the owner explicitly confirms the 10 SOV burn.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _cardBg,
        title: const Text('Confirm registration',
            style: TextStyle(color: _gold, fontWeight: FontWeight.bold)),
        content: Text(
          'Registering "$domain" will deduct 10 SOV from your wallet (a one-time '
          'network fee paid to the operator pool).\n\nOn confirm, the network builds '
          'your ready-to-install SDK and gives you a download — you just drop it into '
          'your website.',
          style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel', style: TextStyle(color: Colors.white54))),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: _gold, foregroundColor: Colors.black),
            child: const Text('Confirm — deduct 10 SOV'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() { _submitting = true; _error = ''; _result = null; });
    try {
      if (!RelayConnector.isConnected) await RelayConnector.connect();
      final res = await RelayConnector.registerPlatform(
        domain: domain, returnUrl: returnUrl,
      );
      if (!mounted) return;
      if (res['success'] == true) {
        setState(() { _result = res; _submitting = false; });
      } else {
        setState(() {
          _error = _friendlyError((res['error'] ?? 'UNKNOWN').toString());
          _submitting = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = 'Registration failed: $e'; _submitting = false; });
    }
  }

  void _copy(String label, String value) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$label copied'), duration: const Duration(seconds: 2)),
    );
  }

  InputDecoration _dec(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.white30),
        filled: true,
        fillColor: _cardBg,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: _gold.withAlpha(60)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: _gold.withAlpha(40)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: _gold),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _navy,
      appBar: AppBar(
        backgroundColor: _navy,
        foregroundColor: _gold,
        title: const Text('Register a Platform'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (_result == null) ..._buildForm() else ..._buildResult(),
        ],
      ),
    );
  }

  List<Widget> _buildForm() => [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _teal.withAlpha(28),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _teal.withAlpha(90)),
          ),
          child: const Text(
            'Let people sign in to your website with their SOV ID. Register your '
            'domain here — it is signed by your wallet and costs a one-time fee '
            'in SOV (paid to the network operator pool). No server setup or '
            'external IP is needed: registration happens entirely from your wallet.',
            style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.45),
          ),
        ),
        const SizedBox(height: 24),
        const Text('Your website domain',
            style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        TextField(
          controller: _domainCtrl,
          style: const TextStyle(color: Colors.white),
          keyboardType: TextInputType.url,
          decoration: _dec('example.com'),
        ),
        const SizedBox(height: 20),
        const Text('Callback URL',
            style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        const Text('Where the network sends the signed login result.',
            style: TextStyle(color: Colors.white38, fontSize: 11)),
        const SizedBox(height: 8),
        TextField(
          controller: _returnUrlCtrl,
          style: const TextStyle(color: Colors.white),
          keyboardType: TextInputType.url,
          decoration: _dec('https://example.com/api/auth/sov-link-callback'),
        ),
        const SizedBox(height: 24),
        if (_error.isNotEmpty) ...[
          Text(_error, style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
          const SizedBox(height: 16),
        ],
        SizedBox(
          height: 52,
          child: ElevatedButton(
            onPressed: _submitting ? null : _submit,
            style: ElevatedButton.styleFrom(
              backgroundColor: _gold,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: _submitting
                ? const SizedBox(width: 22, height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                : const Text('Register & Pay Fee',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ),
        ),
      ];

  List<Widget> _buildResult() {
    final r = _result!;
    final platformId     = (r['platform_id'] ?? '').toString();
    final callbackSecret = (r['callback_secret'] ?? '').toString();
    final feeSeeds       = (r['fee_seeds_routed_to_operator_pool'] as num?)?.toInt() ?? 0;
    return [
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.green.withAlpha(28),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.green.withAlpha(110)),
        ),
        child: Row(children: [
          const Icon(Icons.check_circle_rounded, color: Colors.greenAccent, size: 22),
          const SizedBox(width: 10),
          Expanded(child: Text(
            'Platform registered.${feeSeeds > 0 ? ' Fee: ${(feeSeeds / 1000000).toStringAsFixed(0)} SOV.' : ''}',
            style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold))),
        ]),
      ),
      const SizedBox(height: 20),
      // ── Primary action: download the ready-to-install SDK ────────────────────
      if ((r['sdk_zip_base64'] ?? '').toString().isNotEmpty) ...[
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _gold.withAlpha(22),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _gold.withAlpha(110)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Your SDK is ready',
                style: TextStyle(color: _gold, fontSize: 15, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            const Text(
              'We built a plugin with your domain, keys and callback already wired in '
              '— nothing to copy or configure. Download it, then:',
              style: TextStyle(color: Colors.white70, fontSize: 12.5, height: 1.4),
            ),
            const SizedBox(height: 8),
            const Text(
              '1. Unzip it.\n'
              '2. Upload sov-login.php to your web root (where your login page is).\n'
              '3. On your "Sign in with SOV" button: require it + call SovLogin::initiate().\n'
              '4. On your callback page: call SovLogin::handleCallback().',
              style: TextStyle(color: Colors.white60, fontSize: 12, height: 1.5),
            ),
            const SizedBox(height: 14),
            SizedBox(
              height: 50, width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _downloading ? null : _downloadSdk,
                icon: _downloading
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                    : const Icon(Icons.download_rounded),
                label: Text(_downloading ? 'Preparing…' : 'Download your SDK (.zip)',
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _gold, foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 18),
      ],
      // ── Bonus: send visitors who don't have the app yet to get it ────────────
      // Deliberately NOT part of the SOV Login wire protocol — this is a static,
      // universal badge (same URL for every platform), so it needs no signing,
      // no relay round-trip, and no per-platform generation.
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: _cardBg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white12),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Get visitors the app, too',
              style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          const Text(
            'Not every visitor has the SOV app yet. Paste this next to your "Sign in with SOV" '
            'button so they can scan and download it without leaving your site.',
            style: TextStyle(color: Colors.white60, fontSize: 12.5, height: 1.4),
          ),
          const SizedBox(height: 12),
          _secretField('Embed on your site', _kAppBadgeSnippet),
        ]),
      ),
      const SizedBox(height: 18),
      // ── Advanced: manual values (the SDK already contains these) ─────────────
      ExpansionTile(
        tilePadding: EdgeInsets.zero,
        iconColor: _gold, collapsedIconColor: Colors.white38,
        title: const Text('Advanced — manual values',
            style: TextStyle(color: Colors.white54, fontSize: 13)),
        childrenPadding: const EdgeInsets.only(bottom: 8),
        children: [
          const Text(
            'Already baked into your downloaded SDK. Only needed if you integrate by hand. '
            'Keep the callback secret private.',
            style: TextStyle(color: Colors.white38, fontSize: 11.5, height: 1.4),
          ),
          const SizedBox(height: 12),
          _secretField('Platform ID', platformId),
          const SizedBox(height: 12),
          _secretField('Callback Secret', callbackSecret, sensitive: true),
        ],
      ),
      const SizedBox(height: 20),
      SizedBox(
        height: 50,
        child: OutlinedButton(
          onPressed: () => Navigator.of(context).pop(),
          style: OutlinedButton.styleFrom(
            foregroundColor: _gold,
            side: const BorderSide(color: _gold),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: const Text('Done'),
        ),
      ),
    ];
  }

  bool _downloading = false;

  Future<void> _downloadSdk() async {
    final r = _result;
    if (r == null) return;
    final b64 = (r['sdk_zip_base64'] ?? '').toString();
    if (b64.isEmpty) return;
    setState(() => _downloading = true);
    try {
      final bytes = base64Decode(b64);
      final name  = (r['sdk_filename'] ?? 'sov-login-sdk.zip').toString();
      final dir   = await getTemporaryDirectory();
      final file  = File('${dir.path}/$name');
      await file.writeAsBytes(bytes, flush: true);
      if (!mounted) return;
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'application/zip')],
        text: 'Your SOV-Login SDK — unzip and drop sov-login.php into your web root.',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not prepare the SDK: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  Widget _secretField(String label, String value, {bool sensitive = false}) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: (sensitive ? Colors.orangeAccent : _gold).withAlpha(60)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text(label, style: TextStyle(
                color: sensitive ? Colors.orangeAccent : _gold,
                fontSize: 12, fontWeight: FontWeight.bold)),
            const Spacer(),
            InkWell(
              onTap: () => _copy(label, value),
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.copy_rounded, color: Colors.white54, size: 18),
              ),
            ),
          ]),
          const SizedBox(height: 6),
          SelectableText(value.isEmpty ? '—' : value,
              style: const TextStyle(color: Colors.white, fontSize: 13, fontFamily: 'monospace')),
        ],
      ),
    );
  }
}
