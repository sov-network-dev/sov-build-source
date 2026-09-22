// lib/screens/send_sov_screen.dart
// Screen 4 — Send SOV  (end-to-end implementation)
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../sov_node_sdk/relay_connector.dart';
import '../sov_node_sdk/transaction_store.dart';
import '../sov_node_sdk/wallet_engine.dart';
import '../sov_node_sdk/draft_manager.dart';
import '../sov_node_sdk/draft_keys.dart';
import '../sov_node_sdk/contacts_db.dart';
import '../sov_node_sdk/payment_request_store.dart';
import '../sov_node_sdk/palm_name_engine.dart';
import 'qr_scanner_screen.dart';

class SendSovScreen extends StatefulWidget {
  final String  sovereignId;
  final int     seeds;
  final int     lockedSeeds;
  /// Pre-fill the recipient field (e.g. launched from Contacts or deep link).
  final String? initialRecipientId;
  /// Pre-fill the amount (in SOV, e.g. 5.0) from a deep link / payment request.
  final double? initialAmount;
  /// Pre-fill the memo from a payment request.
  final String? initialMemo;
  /// If set, this transfer marks a payment request as paid on the relay.
  final String? paymentRequestId;

  const SendSovScreen({
    super.key,
    required this.sovereignId,
    required this.seeds,
    this.lockedSeeds       = 0,
    this.initialRecipientId,
    this.initialAmount,
    this.initialMemo,
    this.paymentRequestId,
  });

  @override
  State<SendSovScreen> createState() => _SendSovScreenState();
}

class _SendSovScreenState extends State<SendSovScreen> {
  static const _navy   = Color(0xFF0A1628);
  static const _gold   = Color(0xFFB8960C);
  static const _cardBg = Color(0xFF0D1F3A);

  final _recipientCtrl = TextEditingController();
  final _amountCtrl    = TextEditingController();
  final _memoCtrl      = TextEditingController();
  final _formKey       = GlobalKey<FormState>();

  bool   _sending       = false;
  String _error         = '';

  // SharedPreferences key for recording payment request IDs the sender has already paid.
  // Prevents the same QR code being scanned and paid a second time on this device.
  static const _usedPayReqKey = 'used_payment_request_ids';

  // Set when form is pre-filled from a sovreq:// scan — marks the payment request paid on relay
  String? _activePaymentRequestId;

  // Confirmation state
  bool   _confirmed     = false;
  String _confirmedTxHash  = '';
  int    _confirmedSeeds   = 0;
  String _confirmedToId    = '';
  String _confirmedBy      = '';

  // Live seeds-equivalent display
  int    _seedsPreview  = 0;

  @override
  void initState() {
    super.initState();
    _amountCtrl.addListener(_onAmountChanged);
    // Pre-fill from contact picker / deep-link / payment request
    if (widget.initialRecipientId != null) {
      _recipientCtrl.text = widget.initialRecipientId!;
    }
    if (widget.initialAmount != null && widget.initialAmount! > 0) {
      _amountCtrl.text = widget.initialAmount!.toStringAsFixed(6);
    }
    if (widget.initialMemo != null && widget.initialMemo!.isNotEmpty) {
      _memoCtrl.text = widget.initialMemo!;
    }
    if (widget.paymentRequestId != null && widget.paymentRequestId!.isNotEmpty) {
      _activePaymentRequestId = widget.paymentRequestId;
    }
    _loadDrafts();
  }

  Future<void> _loadDrafts() async {
    // Only restore recipient draft when NOT launched with a pre-filled ID
    final amount = await DraftManager.load(DraftKeys.sendAmount);
    if (!mounted) return;
    if (widget.initialRecipientId == null) {
      final recipient = await DraftManager.load(DraftKeys.sendRecipientId);
      if (recipient.isNotEmpty) {
        _recipientCtrl.text = recipient;
        _recipientCtrl.selection =
            TextSelection.fromPosition(TextPosition(offset: recipient.length));
      }
    }
    if (amount.isNotEmpty) {
      _amountCtrl.text = amount;
      _amountCtrl.selection =
          TextSelection.fromPosition(TextPosition(offset: amount.length));
    }
  }

  @override
  void dispose() {
    _recipientCtrl.dispose();
    _amountCtrl.dispose();
    _memoCtrl.dispose();
    super.dispose();
  }

  void _onAmountChanged() {
    final n = double.tryParse(_amountCtrl.text.trim()) ?? 0;
    final s = (n * 1000000).round();
    if (_seedsPreview != s) setState(() => _seedsPreview = s);
  }

  String _formatBalance(int seeds) {
    final sov = seeds / 1000000;
    if (sov >= 1) return '${sov.toStringAsFixed(2)} SOV';
    return '${sov.toStringAsFixed(6)} SOV';
  }

  String _formatSeeds(int seeds) {
    if (seeds == 0) return '';
    return '${_commas(seeds)} Seeds';
  }

  String _commas(int n) {
    final s = n.abs().toString();
    final buf = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }

  // ── QR scanner ─────────────────────────────────────────────────────────────
  Future<void> _scanQr() async {
    RelayConnector.externalActivityOpen = true;
    final raw = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const QrScannerScreen()),
    );
    RelayConnector.externalActivityOpen = false;

    if (raw == null || !mounted) return;

    if (raw.startsWith('sovreq://')) {
      // Full payment request — parse and fill everything
      final parsed = PaymentRequestStore.parseLink(raw);
      final recipientId = parsed['sovereign_id'] ?? '';
      final amountStr   = parsed['amount'];
      final memo        = parsed['memo']   ?? '';
      final reqId       = parsed['req'];

      if (recipientId.isEmpty || !recipientId.startsWith('SOV-')) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Invalid SOV QR code'),
            backgroundColor: Color(0xFF1A3A5C),
            behavior: SnackBarBehavior.floating,
          ));
        }
        return;
      }

      // ── QR dedup guard: block re-scan of an already-paid payment request ──
      if (reqId != null && reqId.isNotEmpty) {
        try {
          final prefs = await SharedPreferences.getInstance();
          final usedIds = prefs.getStringList(_usedPayReqKey) ?? [];
          if (usedIds.contains(reqId)) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Row(
                  children: [
                    Icon(Icons.check_circle_rounded, color: Color(0xFF4CAF50), size: 16),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'This payment request has already been fulfilled.',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                  ],
                ),
                backgroundColor: Color(0xFF1A3A5C),
                behavior: SnackBarBehavior.floating,
                duration: Duration(seconds: 4),
              ));
            }
            return;
          }
        } catch (_) {}
      }

      setState(() {
        _recipientCtrl.text = recipientId;
        if (amountStr != null) {
          final seeds = int.tryParse(amountStr) ?? 0;
          if (seeds > 0) {
            _amountCtrl.text = (seeds / 1000000).toStringAsFixed(6);
          }
        }
        if (memo.isNotEmpty) _memoCtrl.text = memo;
        _activePaymentRequestId = reqId;
        _error = '';
      });

      // Show a confirmation snackbar
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Row(
            children: [
              const Icon(Icons.qr_code_scanner_rounded,
                  color: Color(0xFFD4AF37), size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  reqId != null ? 'Payment request scanned — form filled' : 'Address scanned',
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
          backgroundColor: const Color(0xFF0D2A4A),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ));
      }

    } else if (raw.startsWith('SOV-')) {
      // Plain Sovereign ID — just fill the recipient
      setState(() {
        _recipientCtrl.text = raw.trim();
        _activePaymentRequestId = null;
        _error = '';
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Sovereign ID scanned'),
          backgroundColor: Color(0xFF0D2A4A),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ));
      }
    }
  }

  // ── Contact picker ─────────────────────────────────────────────────────────
  Future<void> _openContactPicker() async {
    final contacts = await ContactsDb.getContacts();
    if (!mounted) return;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0D1F3A),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      isScrollControlled: true,
      builder: (ctx) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.55,
          maxChildSize: 0.85,
          minChildSize: 0.35,
          builder: (_, scrollCtrl) {
            if (contacts.isEmpty) {
              return const Padding(
                padding: EdgeInsets.all(32),
                child: Center(
                  child: Text(
                    'No contacts yet.\nSend SOV or message someone first.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white54, fontSize: 14),
                  ),
                ),
              );
            }
            return Column(
              children: [
                const SizedBox(height: 12),
                Container(
                    width: 40, height: 4,
                    decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2))),
                const SizedBox(height: 16),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 20),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Select Recipient',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: ListView.builder(
                    controller: scrollCtrl,
                    itemCount: contacts.length,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemBuilder: (_, i) {
                      final c = contacts[i];
                      return ListTile(
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        leading: CircleAvatar(
                          backgroundColor: const Color(0xFFB8960C).withAlpha(40),
                          child: Text(
                            c.displayName.isNotEmpty
                                ? c.displayName[0].toUpperCase()
                                : '?',
                            style: const TextStyle(
                                color: Color(0xFFB8960C),
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                        title: Text(c.displayName,
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600)),
                        subtitle: Text(
                          c.sovereignId.length > 28
                              ? '${c.sovereignId.substring(0, 14)}…${c.sovereignId.substring(c.sovereignId.length - 8)}'
                              : c.sovereignId,
                          style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 11,
                              fontFamily: 'monospace'),
                        ),
                        onTap: () {
                          _recipientCtrl.text = c.sovereignId;
                          DraftManager.save(
                              DraftKeys.sendRecipientId, c.sovereignId);
                          Navigator.pop(ctx);
                        },
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // ── Store transaction locally ───────────────────────────────────────────────
  Future<void> _storeTx({
    required int    amountSeeds,
    required String toId,
    required String txHash,
    required String answeredBy,
  }) async {
    final memo = _memoCtrl.text.trim();
    await TransactionStore.save({
      'tx_id':          txHash.isNotEmpty ? txHash : 'tx-${DateTime.now().millisecondsSinceEpoch}',
      'type':           'sent',
      'amount_seeds':   amountSeeds,
      'counterparty_id': toId,
      'from_id':        widget.sovereignId,
      'tx_hash':        txHash,
      'timestamp':      DateTime.now().millisecondsSinceEpoch,
      'status':         'confirmed',
      'relay_id':       RelayConnector.currentRelayId,
      'answered_by':    answeredBy,
      if (memo.isNotEmpty) 'memo': memo,
    });
  }

  // ── Send ────────────────────────────────────────────────────────────────────
  Future<void> _send() async {
    if (!_formKey.currentState!.validate()) return;

    final toId       = _recipientCtrl.text.trim();
    final sovAmount  = double.tryParse(_amountCtrl.text.trim()) ?? 0;
    final amtSeeds   = (sovAmount * 1000000).round();

    // ── Anti-phishing confirmation (threat-model #4) ─────────────────────────
    // Explicit review of the EXACT amount + recipient (id + palm-derived name)
    // before anything is signed or leaves the wallet. The #1 defence against a
    // swapped/wrong address. Cancel is a pure no-op.
    final recipientName = PalmNameEngine.deriveName([], sovereignId: toId);
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: _cardBg,
        title: const Text('Confirm transfer',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('You are about to send',
                style: TextStyle(color: Colors.white70, fontSize: 13)),
            const SizedBox(height: 6),
            Text('$sovAmount SOV',
                style: const TextStyle(
                    color: _gold, fontSize: 24, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            const Text('to', style: TextStyle(color: Colors.white70, fontSize: 13)),
            if (recipientName.isNotEmpty)
              Text(recipientName,
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w600)),
            SelectableText(toId,
                style: const TextStyle(color: Colors.white60, fontSize: 12)),
            if (_memoCtrl.text.trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Memo: ${_memoCtrl.text.trim()}',
                  style: const TextStyle(color: Colors.white54, fontSize: 12)),
            ],
            const SizedBox(height: 14),
            const Text('Transfers cannot be reversed. Check the recipient carefully.',
                style: TextStyle(color: Color(0xFFE0A030), fontSize: 12)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: _gold),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm & Send',
                style: TextStyle(color: Colors.black)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() { _sending = true; _error = ''; });
    // Pause auto-reconnect so a heartbeat-timeout node switch can't drop the
    // transfer mid-flight (pool→0 race — same class as the recovery fix).
    RelayConnector.suppressReconnect = true;

    try {
      // ── Ensure a stable relay connection before the money ops ──────────────
      if (!RelayConnector.isConnected) await RelayConnector.connect();
      for (int w = 0; w < 20 && !RelayConnector.isConnected; w++) {
        await Future.delayed(const Duration(seconds: 1));
      }

      // ── Query relay for live balance ───────────────────────────────────────
      // Use the relay-authoritative SPENDABLE balance (already net of any locks).
      // The relay's transfer guard checks spendable_seeds (transfer_engine.js),
      // so checking total balance_seeds here let the app attempt a doomed send →
      // INSUFFICIENT_BALANCE even when it displayed plenty.
      final balFull      = await RelayConnector.queryBalanceFull(widget.sovereignId);
      final spendable    = (balFull?['spendable_seeds'] as num?)?.toInt()
                         ?? (balFull?['seeds'] as num?)?.toInt() ?? 0;
      final lockedNow    = (balFull?['locked_seeds'] as num?)?.toInt() ?? widget.lockedSeeds;
      final totalBalance = spendable > 0 ? spendable : (widget.seeds - widget.lockedSeeds);
      final available    = totalBalance;

      if (amtSeeds > available) {
        String errMsg = 'Insufficient spendable balance — you can send ${_formatBalance(available < 0 ? 0 : available)}';
        if (lockedNow > 0) {
          errMsg += '\n${_formatBalance(lockedNow)} is locked in SOV Vault';
        }
        setState(() { _error = errMsg; _sending = false; });
        return;
      }

      // ── Nonce management ───────────────────────────────────────────────────
      final prefs = await SharedPreferences.getInstance();
      final nonce = (prefs.getInt('tx_nonce') ?? 0) + 1;
      await prefs.setInt('tx_nonce', nonce);

      // ── Send to relay ──────────────────────────────────────────────────────
      final result = await RelayConnector.transferSOV(
          widget.sovereignId, toId, amtSeeds, nonce,
          memo:             _memoCtrl.text.trim().isEmpty ? null : _memoCtrl.text.trim(),
          paymentRequestId: _activePaymentRequestId ?? widget.paymentRequestId);

      if (!mounted) return;

      if (result['success'] == true) {
        final txHash = result['tx_hash'] as String? ?? '';
        debugPrint('[SOV-AUDIT] tx.confirmed tx_hash=$txHash to=$toId amount_seeds=$amtSeeds');

        // Update local balance using relay's confirmed sender balance, or deduct
        final newBalance = (result['new_balance_sender'] as num?)?.toInt()
            ?? (totalBalance - amtSeeds);
        await WalletEngine.updateBalance(newBalance.toDouble());
        // Notify MainShell so balance card updates immediately without a relay query
        RelayConnector.notifySeedsChanged(newBalance);

        // Store transaction locally
        await _storeTx(
          amountSeeds: amtSeeds,
          toId:        toId,
          txHash:      txHash,
          answeredBy:  result['answered_by'] as String? ?? '',
        );

        // Auto-save the recipient as a contact with palm-derived name
        await ContactsDb.recordInteraction(
          sovereignId: toId,
          nickname:    PalmNameEngine.deriveName([], sovereignId: toId),
        );

        // ── Mark payment request as locally used — prevents second QR scan ──
        final usedReqId = _activePaymentRequestId ?? widget.paymentRequestId;
        if (usedReqId != null && usedReqId.isNotEmpty) {
          try {
            final prefs = await SharedPreferences.getInstance();
            final usedIds = (prefs.getStringList(_usedPayReqKey) ?? []).toSet();
            usedIds.add(usedReqId);
            // Keep at most 500 entries to avoid unbounded growth
            final trimmed = usedIds.length > 500
                ? usedIds.toList().sublist(usedIds.length - 500)
                : usedIds.toList();
            await prefs.setStringList(_usedPayReqKey, trimmed);
          } catch (_) {}
        }

        if (mounted) {
          // Clear send-form drafts — transfer succeeded
          await DraftManager.clearAll(DraftKeys.sendAll);
          setState(() {
            _sending         = false;
            _confirmed       = true;
            _confirmedTxHash = txHash;
            _confirmedSeeds  = amtSeeds;
            _confirmedToId   = toId;
            _confirmedBy     = result['answered_by'] as String? ?? '';
          });
        }
      } else {
        final errCode = result['error'] as String? ?? 'Transfer failed';
        // ── Nonce self-heal: relay confirmed a higher nonce than we have locally ──
        // This happens after app reinstall (SharedPrefs cleared) or nonce drift.
        // Relay returns last_confirmed_nonce — update local prefs and retry once.
        if (errCode == 'NONCE_ALREADY_CONFIRMED' ||
            errCode == 'NONCE_ALREADY_USED' ||
            errCode == 'NONCE_FUTURE') {
          // sov-node sends 'expected_nonce' = the exact nonce value it wants next.
          // The legacy relay sent 'last_confirmed_nonce' = retry nonce is that + 1.
          // Both cases: reset local prefs to the correct retry nonce and resend once.
          // [SECURITY] Never expose nonce/SSP internals to the citizen — silent self-heal.
          final expectedNonce   = (result['expected_nonce']      as num?)?.toInt();
          final lastConfirmed   = (result['last_confirmed_nonce'] as num?)?.toInt();
          final retryNonce      = expectedNonce ?? (lastConfirmed != null ? lastConfirmed + 1 : null);
          if (retryNonce != null && retryNonce > 0) {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setInt('tx_nonce', retryNonce);
            debugPrint('[NONCE-HEAL] $errCode — relay expects $retryNonce, retrying');
            if (mounted) {
              final retryResult = await RelayConnector.transferSOV(
                  widget.sovereignId, toId, amtSeeds, retryNonce,
                  memo:             _memoCtrl.text.trim().isEmpty ? null : _memoCtrl.text.trim(),
                  paymentRequestId: _activePaymentRequestId ?? widget.paymentRequestId);
              if (!mounted) return;
              if (retryResult['success'] == true) {
                final txHash    = retryResult['tx_hash'] as String? ?? '';
                final newBalance = (retryResult['new_balance_sender'] as num?)?.toInt()
                    ?? (totalBalance - amtSeeds);
                await WalletEngine.updateBalance(newBalance.toDouble());
                RelayConnector.notifySeedsChanged(newBalance);
                await _storeTx(
                  amountSeeds: amtSeeds,
                  toId:        toId,
                  txHash:      txHash,
                  answeredBy:  retryResult['answered_by'] as String? ?? '',
                );
                // Mark payment request as used on retry success too
                final retryUsedReqId = _activePaymentRequestId ?? widget.paymentRequestId;
                if (retryUsedReqId != null && retryUsedReqId.isNotEmpty) {
                  try {
                    final prefs2 = await SharedPreferences.getInstance();
                    final usedIds2 = (prefs2.getStringList(_usedPayReqKey) ?? []).toSet();
                    usedIds2.add(retryUsedReqId);
                    final trimmed2 = usedIds2.length > 500
                        ? usedIds2.toList().sublist(usedIds2.length - 500)
                        : usedIds2.toList();
                    await prefs2.setStringList(_usedPayReqKey, trimmed2);
                  } catch (_) {}
                }
                if (mounted) {
                  await DraftManager.clearAll(DraftKeys.sendAll);
                  setState(() {
                    _sending         = false;
                    _confirmed       = true;
                    _confirmedTxHash = txHash;
                    _confirmedSeeds  = amtSeeds;
                    _confirmedToId   = toId;
                    _confirmedBy     = retryResult['answered_by'] as String? ?? '';
                  });
                }
                return;
              } else {
                final retryErr = retryResult['error'] as String? ?? 'Retry failed';
                if (mounted) setState(() { _error = retryErr; _sending = false; });
                return;
              }
            }
          }
        }
        // ── Payment request already paid (relay rejected duplicate QR scan) ──
        if (errCode == 'PAYMENT_REQUEST_ALREADY_PAID') {
          // Also record locally so future scans on this device are blocked immediately
          final dupReqId = _activePaymentRequestId ?? widget.paymentRequestId;
          if (dupReqId != null && dupReqId.isNotEmpty) {
            try {
              final prefs = await SharedPreferences.getInstance();
              final usedIds = (prefs.getStringList(_usedPayReqKey) ?? []).toSet();
              usedIds.add(dupReqId);
              await prefs.setStringList(_usedPayReqKey, usedIds.toList());
            } catch (_) {}
          }
          if (mounted) { setState(() {
            _error = 'This payment request has already been fulfilled. No SOV was deducted.';
            _sending = false;
          }); }
          return;
        }
        // ── Standard error display ────────────────────────────────────────────
        final errMsg  = errCode == 'RECIPIENT_NOT_FOUND'
            ? 'Recipient is not an enrolled citizen on this network.\nNo SOV has been deducted.'
            : errCode;
        if (mounted) setState(() { _error = errMsg; _sending = false; });
      }
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _sending = false; });
    } finally {
      RelayConnector.suppressReconnect = false;
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // BUILD
  // ══════════════════════════════════════════════════════════════════════════
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
        title: Text(
          _confirmed ? 'Transfer Complete' : 'Send SOV',
          style: const TextStyle(
              color: Color(0xFFB8960C),
              fontWeight: FontWeight.bold,
              fontSize: 18),
        ),
      ),
      body: _confirmed ? _buildConfirmation() : _buildForm(),
    );
  }

  // ── Send form ───────────────────────────────────────────────────────────────
  Widget _buildForm() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [

            // Balance card
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: _cardBg,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: _gold.withAlpha(51)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Available Balance',
                      style: TextStyle(
                          color: Colors.white38, fontSize: 12, letterSpacing: 1)),
                  const SizedBox(height: 8),
                  Text(_formatBalance(widget.seeds - widget.lockedSeeds < 0
                          ? 0 : widget.seeds - widget.lockedSeeds),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                        letterSpacing: -0.5,
                      )),
                  if (widget.lockedSeeds > 0) ...[
                    const SizedBox(height: 6),
                    Text(
                      '${_formatBalance(widget.lockedSeeds)} locked in SOV Vault',
                      style: const TextStyle(
                          color: Color(0xFFB8960C),
                          fontSize: 11,
                          fontWeight: FontWeight.w500),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 28),

            // Recipient
            const Text('RECIPIENT SOVEREIGN ID',
                style: TextStyle(
                    color: Colors.white38, fontSize: 11, letterSpacing: 1.5)),
            const SizedBox(height: 8),
            TextFormField(
              key: const ValueKey('sendRecipientField'), // flutter_driver
              controller: _recipientCtrl,
              style: const TextStyle(
                  color: Colors.white, fontFamily: 'monospace', fontSize: 13),
              onChanged: (v) {
                DraftManager.save(DraftKeys.sendRecipientId, v);
              },
              decoration: InputDecoration(
                hintText: 'SOV-XXXX…',
                hintStyle: TextStyle(color: Colors.white.withAlpha(51)),
                filled: true,
                fillColor: _cardBg,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.white.withAlpha(26)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.white.withAlpha(26)),
                ),
                focusedBorder: const OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(12)),
                  borderSide: BorderSide(color: Color(0xFFB8960C)),
                ),
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // ── Scan QR ──────────────────────────────────────────────
                    IconButton(
                      icon: const Icon(Icons.qr_code_scanner_rounded,
                          color: Colors.white54, size: 20),
                      tooltip: 'Scan QR code',
                      onPressed: _scanQr,
                    ),
                    IconButton(
                      icon: const Icon(Icons.contacts_rounded,
                          color: Colors.white38, size: 18),
                      tooltip: 'Pick from contacts',
                      onPressed: _openContactPicker,
                    ),
                    IconButton(
                      icon: const Icon(Icons.paste_rounded,
                          color: Colors.white38, size: 18),
                      tooltip: 'Paste',
                      onPressed: () async {
                        final data = await Clipboard.getData('text/plain');
                        if (data?.text != null) {
                          _recipientCtrl.text = data!.text!.trim();
                        }
                      },
                    ),
                  ],
                ),
              ),
              validator: (v) {
                final t = v?.trim() ?? '';
                if (t.isEmpty) return 'Enter recipient Sovereign ID';
                if (!t.startsWith('SOV-')) return 'ID must start with SOV-';
                if (t == widget.sovereignId) return 'Cannot send to yourself';
                return null;
              },
            ),
            const SizedBox(height: 20),

            // Amount
            const Text('AMOUNT (SOV)',
                style: TextStyle(
                    color: Colors.white38, fontSize: 11, letterSpacing: 1.5)),
            const SizedBox(height: 8),
            TextFormField(
              key: const ValueKey('sendAmountField'), // flutter_driver
              controller: _amountCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold),
              onChanged: (v) => DraftManager.save(DraftKeys.sendAmount, v),
              decoration: InputDecoration(
                hintText: '0.000000',
                hintStyle: TextStyle(
                    color: Colors.white.withAlpha(51), fontSize: 24),
                filled: true,
                fillColor: _cardBg,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.white.withAlpha(26)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.white.withAlpha(26)),
                ),
                focusedBorder: const OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(12)),
                  borderSide: BorderSide(color: Color(0xFFB8960C)),
                ),
                suffixText: 'SOV',
                suffixStyle: const TextStyle(
                    color: Color(0xFFB8960C), fontWeight: FontWeight.bold),
              ),
              validator: (v) {
                final n = double.tryParse(v ?? '');
                if (n == null || n <= 0) return 'Enter a valid amount';
                final availSeeds = widget.seeds - widget.lockedSeeds;
                if ((n * 1000000).round() > availSeeds) {
                  return 'Exceeds available balance (${_formatBalance(availSeeds < 0 ? 0 : availSeeds)})';
                }
                return null;
              },
            ),

            // Payment request badge (shown when form came from a scan or deep link)
            if (_activePaymentRequestId != null ||
                (widget.paymentRequestId != null &&
                 widget.paymentRequestId!.isNotEmpty)) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFFD4AF37).withAlpha(18),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: const Color(0xFFD4AF37).withAlpha(60)),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.receipt_rounded,
                        color: Color(0xFFD4AF37), size: 13),
                    SizedBox(width: 6),
                    Text(
                      'Paying a tracked request — recipient will be notified',
                      style: TextStyle(
                          color: Color(0xFFD4AF37),
                          fontSize: 11,
                          fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ],

            // Seeds equivalent hint
            if (_seedsPreview > 0) ...[
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Text(
                  '= ${_formatSeeds(_seedsPreview)}',
                  style: const TextStyle(
                      color: Color(0xFFB8960C),
                      fontSize: 12,
                      letterSpacing: 0.3),
                ),
              ),
            ],
            const SizedBox(height: 20),

            // Memo (optional — shown when pre-filled from payment request or typed)
            const Text('MEMO (OPTIONAL)',
                style: TextStyle(
                    color: Colors.white38, fontSize: 11, letterSpacing: 1.5)),
            const SizedBox(height: 8),
            TextFormField(
              controller: _memoCtrl,
              maxLength:  80,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Payment note or reference',
                hintStyle:
                    TextStyle(color: Colors.white.withAlpha(40), fontSize: 13),
                filled: true,
                fillColor: _cardBg,
                counterStyle:
                    const TextStyle(color: Colors.white24, fontSize: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.white.withAlpha(26)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.white.withAlpha(26)),
                ),
                focusedBorder: const OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(12)),
                  borderSide: BorderSide(color: Color(0xFFB8960C)),
                ),
              ),
            ),

            // Error
            if (_error.isNotEmpty) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withAlpha(26),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.withAlpha(77)),
                ),
                child: Text(_error,
                    style: const TextStyle(
                        color: Colors.redAccent, fontSize: 13)),
              ),
            ],

            const SizedBox(height: 32),

            // Send button
            SizedBox(
              width: double.infinity,
              height: 54,
              child: ElevatedButton(
                key: const ValueKey('sendSubmitButton'), // flutter_driver
                onPressed: _sending ? null : _send,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _gold,
                  disabledBackgroundColor: _gold.withAlpha(77),
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                  elevation: 0,
                ),
                child: _sending
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                            color: Colors.black, strokeWidth: 2.5))
                    : const Text('Send SOV',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Confirmation screen ─────────────────────────────────────────────────────
  Widget _buildConfirmation() {
    final shortTx = _confirmedTxHash.length >= 16
        ? _confirmedTxHash.substring(0, 16)
        : _confirmedTxHash;
    final shortTo = _confirmedToId.length > 24
        ? '${_confirmedToId.substring(0, 12)}...${_confirmedToId.substring(_confirmedToId.length - 6)}'
        : _confirmedToId;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [

            // Green checkmark
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.green.withAlpha(30),
                border: Border.all(color: Colors.green.withAlpha(120), width: 2),
              ),
              child: const Icon(Icons.check_rounded,
                  color: Colors.greenAccent, size: 52),
            ),
            const SizedBox(height: 28),

            const Text('Transfer Complete',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 32),

            // Details card
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: _cardBg,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.green.withAlpha(60)),
              ),
              child: Column(
                children: [
                  _detailRow('Amount sent',
                      '${(_confirmedSeeds / 1000000).toStringAsFixed(6)} SOV'),
                  const Divider(color: Colors.white12, height: 24),
                  _detailRow('Seeds', _formatSeeds(_confirmedSeeds)),
                  const Divider(color: Colors.white12, height: 24),
                  _detailRow('To', shortTo),
                  const Divider(color: Colors.white12, height: 24),
                  _detailRow('Transaction', '$shortTx...'),
                  if (_confirmedBy.isNotEmpty) ...[
                    const Divider(color: Colors.white12, height: 24),
                    _detailRow('Confirmed by', _confirmedBy.length > 20
                        ? '${_confirmedBy.substring(0, 20)}...'
                        : _confirmedBy),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 40),

            // Back to home
            SizedBox(
              width: double.infinity,
              height: 54,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(context),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _gold,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                  elevation: 0,
                ),
                child: const Text('Back to Home',
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label,
            style: const TextStyle(color: Colors.white54, fontSize: 13)),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                fontFamily: 'monospace'),
          ),
        ),
      ],
    );
  }
}
