// lib/screens/main_shell.dart
// ─────────────────────────────────────────────────────────────────────────────
// SESSION N1 — Six-Tab Shell
//
// NavigationBar (Material 3) with IndexedStack so every tab keeps its state
// alive when the citizen switches tabs. A citizen composing a message in
// SOV Speak retains their draft when they check their balance on Home.
//
// Tab order: Home | Messages | Vault | Governance | Academy | Profile
// ─────────────────────────────────────────────────────────────────────────────
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../sov_node_sdk/relay_connector.dart';
import '../sov_node_sdk/node_controller.dart';
import '../sov_node_sdk/sov_voice_service.dart';
import '../sov_node_sdk/wallet_engine.dart';
import '../sov_node_sdk/contacts_db.dart';
import '../sov_node_sdk/message_encryptor.dart';
import '../sov_node_sdk/conversation_utils.dart';
import '../sov_node_sdk/transaction_store.dart';
import '../sov_node_sdk/sov_notification_service.dart';
import '../sov_node_sdk/message_events.dart';
import '../sov_node_sdk/outbox_manager.dart';
import 'home_screen.dart';
import 'academy_screen.dart';
import 'inheritance_screen.dart';
import 'governance_screen.dart';
import 'messages_screen.dart';
import 'profile_screen.dart';
import 'sov_link_screen.dart';
import '../sov_node_sdk/palm_name_engine.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  // Static handle so main.dart can call restoreLastTab after PIN unlock.
  static _MainShellState? _instance;

  /// Called by main.dart after correct PIN entry so the last-open tab is
  /// surfaced immediately. Since IndexedStack keeps widgets alive under the
  /// PIN overlay, in-memory tab state is already preserved; this call is
  /// the explicit guarantee for any edge case where state was reset.
  static void restoreLastTab() => _instance?._restoreTabFromPrefs();

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> with WidgetsBindingObserver {
  static const _navy = Color(0xFF0A1628);

  int    _currentIndex = 0;
  String _sovereignId  = '';
  int    _seeds        = 0;
  bool   _ready        = false;
  int    _unreadCount  = 0;

  StreamSubscription<Map<String, dynamic>>? _messageSub;

  @override
  void initState() {
    super.initState();
    MainShell._instance = this;
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void dispose() {
    _messageSub?.cancel();
    if (MainShell._instance == this) MainShell._instance = null;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused  ||
        state == AppLifecycleState.hidden  ||
        state == AppLifecycleState.detached) {
      // Persist current tab so cold-start and PIN-unlock restore correctly.
      _saveTab(_currentIndex);
    }
    if (state == AppLifecycleState.resumed) {
      if (!RelayConnector.enrollmentInProgress) {
        RelayConnector.connect().catchError((_) => false);
      }
    }
  }

  // ── Initialisation ──────────────────────────────────────────────────────────

  Future<void> _init() async {
    final prefs    = await SharedPreferences.getInstance();
    final sovId    = prefs.getString('sovereign_id') ?? '';
    final lastTab  = (prefs.getInt('last_tab_index') ?? 0).clamp(0, 5);
    final localBal = await WalletEngine.getBalance();

    // Warm palm name cache early so HomeScreen shows the name immediately
    // without waiting for its own async load.
    unawaited(RelayConnector.getPalmName());

    // Wire ledger-sync so relay-pushed balances reach the shell.
    // Also import any transactions carried in the response so that a freshly-
    // restored wallet immediately shows history without requiring new activity.
    // Re-register relay watch entries on every (re)connect so outbox messages
    // are retried automatically when their recipient comes online — even if the
    // app reconnected since the watch was first added.
    RelayConnector.onConnected = () { OutboxManager.retryAll(); };

    RelayConnector.onLedgerSync = (relayBalance, transactions) async {
      if (relayBalance > 0) {
        // relayBalance arrives in SOV (float) from LEDGER_SYNC_RESPONSE.
        // WalletEngine and _seeds operate in seeds (1 SOV = 1,000,000 seeds).
        final seeds = (relayBalance * 1000000).round();
        await WalletEngine.updateBalance(seeds.toDouble());
        if (mounted) setState(() => _seeds = seeds);
      }
      // Merge relay transaction history into local store (skips duplicates),
      // then tell HomeTab to reload its Recent Transactions widget.
      if (transactions.isNotEmpty) {
        final id = (await SharedPreferences.getInstance())
            .getString('sovereign_id') ?? '';
        final before = (await TransactionStore.load()).length;
        await TransactionStore.mergeAll(transactions, id);
        final after  = (await TransactionStore.load()).length;
        if (after > before) {
          MessageEvents.notifyTransactionsChanged();
        }
        // Recent history sync: request unsynced txs within relay's tx_retention_days window
        if (id.isNotEmpty) {
          RelayConnector.syncTransactionHistory(id).catchError((_) {});
        }
      }
    };

    // Listen for immediate balance updates after a confirmed transfer.
    // send_sov_screen calls RelayConnector.notifySeedsChanged() after each send
    // so the home balance card refreshes without waiting for the next relay sync.
    RelayConnector.seedsChangedStream.listen((newSeeds) {
      if (mounted && newSeeds > 0) setState(() => _seeds = newSeeds);
    });

    // Wire message stream BEFORE connect() so no MESSAGE_INCOMING events
    // can arrive before the listener exists.
    _wireMessageStream(sovId);

    try {
      await RelayConnector.connect();
    } catch (_) {}
    if (!mounted) return;

    setState(() {
      _sovereignId  = sovId;
      _seeds        = localBal.toInt();
      _currentIndex = lastTab;
      _ready        = true;
    });

    _refreshBalance();

    // Intelligent full-node auto-start (desktop only). A restored wallet means the
    // operator is already a biometrically-verified citizen — no re-scan needed — so
    // if auto-run is on (default) bring the node up on its own in the saved
    // reachability mode. Fire-and-forget; never blocks the UI or throws.
    if (NodeController.isDesktopPlatform && sovId.isNotEmpty) {
      final autoRun    = prefs.getBool('node_auto_run') ?? true;
      final reachIdx   = (prefs.getInt('node_reach_mode') ?? 0)
          .clamp(0, ReachMode.values.length - 1);
      final staticHost = prefs.getString('node_static_host');
      unawaited(NodeController.instance.maybeAutoStart(
        sovereignId: sovId,
        enabled: autoRun,
        preferred: ReachMode.values[reachIdx],
        staticHostValue: staticHost,
      ));
    }

    // Request Android 13+ notification permission now that the app window is live.
    // Called here (after runApp + first frame) so the system dialog can appear.
    SovNotificationService.requestPermission();
  }

  Future<void> _refreshBalance() async {
    if (_sovereignId.isEmpty) return;
    try {
      final b = await RelayConnector.queryBalance(_sovereignId);
      if (b > 0 && mounted) {
        await WalletEngine.updateBalance(b.toDouble());
        if (mounted) setState(() => _seeds = b);
      }
    } catch (_) {}
  }

  // ── Global incoming message handler ────────────────────────────────────────
  // Subscribes at shell level so messages are always persisted to the local DB
  // regardless of which tab or screen is currently visible.
  //
  // SovLinkScreen has its own subscription on the same broadcast stream that
  // handles real-time display when a conversation is open; this listener
  // handles persistence and the overlay banner notification.

  void _wireMessageStream(String mySovId) {
    _messageSub?.cancel();
    _messageSub = RelayConnector.incomingMessages.listen((msg) async {
      final type = msg['type'] as String?;

      // ── Optional spoken notification (opt-in; off by default). Fires even
      //    under the PIN-lock overlay — the event stream runs beneath it. ──────
      switch (type) {
        case 'SOV_TRANSFER_RECEIVED':
          SovVoiceService.play(SovVoice.transferReceived);
          break;
        case 'MESSAGE_INCOMING':
        case 'MESSAGE_DELIVERED':
          SovVoiceService.play(SovVoice.message);
          break;
        case 'GROUP_MESSAGE_INCOMING':
          SovVoiceService.play(SovVoice.groupMessage);
          break;
        case 'ENCLAVE_NEW_POST':
        case 'ENCLAVE_NEW_REPLY':
          SovVoiceService.play(SovVoice.enclave);
          break;
        case 'EXCHANGE_ORDER_FILLED_NOTIFY':
          SovVoiceService.play(SovVoice.exchangeFilled);
          break;
        case 'PAY_REQ_INCOMING':
          SovVoiceService.play(SovVoice.paymentRequest);
          break;
      }

      // ── SOV transfer received (includes SOV Shield escrow releases) ─────────
      if (type == 'SOV_TRANSFER_RECEIVED') {
        await _handleTransferReceived(msg, mySovId);
        return;
      }

      // ── SOV Shield: seller's SOV locked in escrow on list order ──────────
      if (type == 'EXCHANGE_ESCROW_LOCKED') {
        final sovAmt  = (msg['sov_amount'] as num?)?.toDouble() ?? 0.0;
        if (sovAmt > 0 && mounted) {
          final sovStr = sovAmt >= 1
              ? '${sovAmt.toStringAsFixed(2)} SOV'
              : '${sovAmt.toStringAsFixed(6)} SOV';
          _showTransferBanner(
            'SOV Shield',
            '–$sovStr locked',
            'SOV-SHIELD',
            color: const Color(0xFF1A2744),
            icon: Icons.shield_rounded,
          );
        }
        // Refresh the home screen's locked-balance display so the citizen
        // sees the SOV move from spendable to SOV Shield in real time.
        _refreshBalance();
        return;
      }

      // ── SOV Shield: seller notified their order was filled ────────────────
      if (type == 'EXCHANGE_ORDER_FILLED_NOTIFY') {
        final sovAmt = (msg['sov_amount'] as num?)?.toDouble() ?? 0.0;
        final desc   = msg['asking_description'] as String? ?? 'your order';
        if (mounted) {
          final sovStr = sovAmt >= 1
              ? '${sovAmt.toStringAsFixed(2)} SOV'
              : '${sovAmt.toStringAsFixed(6)} SOV';
          _showTransferBanner(
            'SOV Shield',
            '$sovStr ready — deliver: $desc',
            'SOV-SHIELD',
            color: const Color(0xFF1A3322),
            icon: Icons.local_shipping_rounded,
          );
        }
        return;
      }

      // ── Justice Council: jury duty invitation ────────────────────────────
      if (type == 'JUSTICE_JUROR_INVITE') {
        final caseId    = msg['case_id']    as String? ?? '';
        final claimAmt  = (msg['claim_amount'] as num?)?.toDouble() ?? 0.0;
        if (mounted && caseId.isNotEmpty) {
          final sovStr = claimAmt >= 1000000
              ? '${(claimAmt / 1000000).toStringAsFixed(2)} SOV'
              : '${claimAmt.toStringAsFixed(0)} seeds';
          _showTransferBanner(
            'Justice Council',
            'Jury duty — $sovStr case awaits',
            'JUSTICE',
            color: const Color(0xFF1F1A00),
            icon: Icons.gavel_rounded,
          );
        }
        return;
      }

      // ── S10 Guardian: invited as guardian ────────────────────────────────
      if (type == 'GUARDIAN_INVITE') {
        final citizenId = msg['citizen_id'] as String? ?? '';
        if (mounted && citizenId.isNotEmpty) {
          final label = citizenId.length > 18
              ? '${citizenId.substring(0, 10)}…${citizenId.substring(citizenId.length - 4)}'
              : citizenId;
          _showTransferBanner(
            'Guardian Request',
            '$label nominated you as guardian',
            'GUARDIAN',
            color: const Color(0xFF0A1F0A),
            icon: Icons.shield_rounded,
          );
        }
        return;
      }

      // ── S10 Guardian: recovery approval needed ────────────────────────────
      if (type == 'GUARDIAN_APPROVAL_REQUEST') {
        final citizenId = msg['citizen_id'] as String? ?? '';
        if (mounted && citizenId.isNotEmpty) {
          final label = citizenId.length > 18
              ? '${citizenId.substring(0, 10)}…${citizenId.substring(citizenId.length - 4)}'
              : citizenId;
          _showTransferBanner(
            'Guardian Recovery',
            '$label needs your approval to recover account',
            'GUARDIAN',
            color: const Color(0xFF1A1000),
            icon: Icons.lock_open_rounded,
          );
        }
        return;
      }

      // ── S10 Guardian: recovery complete or rejected ───────────────────────
      if (type == 'GUARDIAN_RECOVERY_COMPLETE') {
        if (mounted) {
          _showTransferBanner(
            'Recovery Approved',
            'Your account has been restored on this device',
            'GUARDIAN',
            color: const Color(0xFF0A1F0A),
            icon: Icons.check_circle_rounded,
          );
        }
        return;
      }

      // ── S8 Group Channels: invited to a new group ────────────────────────
      if (type == 'GROUP_INVITE') {
        final groupName = msg['group_name'] as String? ?? 'a group';
        final invitedBy = msg['invited_by']  as String? ?? '';
        if (mounted) {
          final byLabel = invitedBy.length > 18
              ? '${invitedBy.substring(0, 10)}…${invitedBy.substring(invitedBy.length - 4)}'
              : invitedBy;
          _showTransferBanner(
            'Group Invite',
            '$byLabel added you to $groupName',
            'GROUP',
            color: const Color(0xFF0A1A28),
            icon: Icons.group_rounded,
          );
        }
        return;
      }

      // ── S15 Voice/Video Calls: DECOMMISSIONED 2026-05-20 ─────────────────
      // The CALL_* code paths remain in calls_engine.js on the relay side
      // (harmless when no client triggers them) but the Flutter banner and
      // CallScreen are no longer reachable. The banner method and CallScreen
      // now live in backups/retired_call_engine/ — livekit_client was removed
      // from pubspec on 2026-07-31 because the WebRTC plugin aborts the whole
      // process at startup on any machine with no audio device. To re-enable:
      // restore both files, re-add livekit_client, then restore the
      // _showIncomingCallBanner invocation and the phone icon in
      // sov_link_screen.dart, and start LiveKit on VPS1 again.
      if (type == 'CALL_INVITE' || type == 'CALL_ANSWERED' ||
          type == 'CALL_ENDED'  || type == 'CALL_REJECTED') {
        return;
      }

      // ── S12 Monetary Issuance: SOV allocation available ──────────────────
      if (type == 'ISSUANCE_AVAILABLE') {
        final amountSeeds = (msg['amount_seeds'] as num?)?.toInt() ?? 0;
        final epochIds    = (msg['epoch_ids'] as List?)?.cast<String>() ?? [];
        if (mounted && amountSeeds > 0 && epochIds.isNotEmpty) {
          final sovAmt = (amountSeeds / 1000000.0);
          final sovStr = sovAmt == sovAmt.roundToDouble()
              ? '${sovAmt.toInt()} SOV'
              : '${sovAmt.toStringAsFixed(2)} SOV';
          _showIssuanceBanner(sovStr, epochIds);
        }
        return;
      }

      // ── Exchange trade chat notification ─────────────────────────────────
      if (type == 'EXCHANGE_CHAT_INCOMING') {
        final fromId  = msg['from_id']  as String? ?? '';
        final orderId = msg['order_id'] as String? ?? '';
        final content = msg['content']  as String? ?? '';
        if (mounted && fromId.isNotEmpty && fromId != mySovId) {
          // Use truncated Sovereign ID as sender label — privacy model
          final senderLabel = fromId.length > 18
              ? '${fromId.substring(0, 10)}…${fromId.substring(fromId.length - 4)}'
              : fromId;
          final orderShort = orderId.length > 10
              ? orderId.substring(orderId.length - 8)
              : orderId;
          final preview = content.length > 50
              ? '${content.substring(0, 50)}…'
              : content;
          _showExchangeChatBanner(senderLabel, preview, 'Order …$orderShort');
        }
        return;
      }

      // ── SOV Speak message ─────────────────────────────────────────────────
      if (type != 'MESSAGE_INCOMING') return;

      final encryptedPayload = msg['encrypted_payload'] as String? ?? '';
      final messageId        = msg['message_id']        as String? ?? '';
      final contentType      = msg['message_type']      as String? ?? 'text';
      final sentAt           = (msg['sent_at'] as num?)?.toInt()
                               ?? DateTime.now().millisecondsSinceEpoch;

      String fromId      = '';
      String preview     = '';
      String exchangeOId = ''; // non-empty → this is a trade message, not SOV Speak
      // S2: Detect v2 encrypted envelope — use relay top-level fields for fromId.
      // We do NOT attempt decryption here (requires async key lookup which would
      // slow every incoming message). The thread (SovLinkScreen) decrypts inline
      // when the citizen opens the conversation.
      final isEncrypted = MessageEncryptor.isEncryptedEnvelope(encryptedPayload);
      try {
        if (isEncrypted) {
          // v2 envelope — fromId from relay field, preview is placeholder
          fromId  = msg['from_sovereign_id'] as String? ?? '';
          preview = '[Encrypted message]';
        } else {
          final env  = jsonDecode(encryptedPayload) as Map<String, dynamic>;
          fromId      = env['from']              as String? ?? '';
          preview     = env['text']              as String? ?? '';
          exchangeOId = env['exchange_order_id'] as String? ?? '';
        }
      } catch (_) {
        fromId  = msg['from_sovereign_id'] as String? ?? '';
        preview = encryptedPayload;
      }
      // Also check the top-level relay field (set by sendExchangeMessage)
      if (exchangeOId.isEmpty) {
        exchangeOId = msg['exchange_order_id'] as String? ?? '';
      }

      if (fromId.isEmpty || messageId.isEmpty) return;

      // Silently drop messages from blocked contacts
      if (await ContactsDb.isContactBlocked(fromId)) return;

      // Auto-add the sender to local contacts on first interaction. Per
      // SOV_Network_Protocol_Book_v1.0 §17 line 741 — a deterministic
      // adjective+noun nickname is generated from the sovereign_id so the
      // citizen has a memorable label for an otherwise-anonymous SOV-XXXX.
      // Idempotent — only inserts if not already present.
      // Skipped for exchange-trade messages (those use a dedicated chat
      // namespace and don't represent a real social contact).
      if (exchangeOId.isEmpty) {
        try { await ContactsDb.ensureContact(fromId); } catch (_) {}
      }

      // ── Exchange trade message — store under xchg_ namespace, skip SOV Speak ──
      if (exchangeOId.isNotEmpty) {
        final xchgConvId = 'xchg_$exchangeOId';
        try {
          await ContactsDb.saveMessage(LocalMessage(
            id:               messageId,
            conversationId:   xchgConvId,
            fromSovereignId:  fromId,
            toSovereignId:    mySovId,
            contentType:      contentType,
            encryptedContent: encryptedPayload,
            decryptedContent: preview,
            status:           'delivered',
            sentAt:           sentAt,
            deliveredAt:      DateTime.now().millisecondsSinceEpoch,
          ));
        } catch (_) {}
        return; // Do NOT add to SOV Speak conversation list
      }

      // ── Standard SOV Speak message ────────────────────────────────────────────
      // Canonical conversation ID — must match SovLinkScreen._conversationId()
      final convId = ConversationUtils.conversationId(fromId, mySovId);

      // Persist to local DB so SovLinkScreen can load historical messages.
      // ConflictAlgorithm.replace makes duplicate saves from SovLinkScreen safe.
      try {
        // S2: For encrypted messages, store the raw envelope so SovLinkScreen
        // can decrypt it. decryptedContent is null — filled in after decrypt.
        await ContactsDb.saveMessage(LocalMessage(
          id:               messageId,
          conversationId:   convId,
          fromSovereignId:  fromId,
          toSovereignId:    mySovId,
          contentType:      contentType,
          encryptedContent: encryptedPayload,
          decryptedContent: isEncrypted ? null : (contentType == 'text' ? preview : null),
          status:           'delivered',
          sentAt:           sentAt,
          deliveredAt:      DateTime.now().millisecondsSinceEpoch,
        ));
        await ContactsDb.recordInteraction(
          sovereignId: fromId,
          nickname:    PalmNameEngine.deriveName([], sovereignId: fromId),
        );
        // Create (or refresh) the conversation row so MessagesScreen can show it.
        // upsertConversation uses INSERT OR IGNORE so unread_count is never reset.
        final convPreview = isEncrypted
            ? '[Encrypted message]'
            : (contentType == 'text' && preview.isNotEmpty ? preview : '[$contentType]');
        await ContactsDb.upsertConversation(
          id:            convId,
          participantId: fromId,
          preview:       convPreview,
          lastMessageAt: sentAt,
        );
        // Increment unread ONLY when the thread for this conversation is not open.
        if (SovLinkScreen.activeConversationId != fromId) {
          await ContactsDb.incrementUnread(convId);
        }
        // Tell MessagesScreen to reload its conversation list.
        // This covers the case where the message arrives while MessagesScreen
        // is already mounted (e.g. OutboxManager retry after CITIZEN_ONLINE).
        MessageEvents.notifyConversationChanged();
      } catch (_) {}

      if (!mounted) return;

      // Badge — increment when not on Messages tab
      if (_currentIndex != 1) {
        setState(() => _unreadCount++);
      }

      // System dropdown notification + in-app overlay banner
      final senderName = () {
        final nick = PalmNameEngine.deriveName([], sovereignId: fromId);
        return (nick.isNotEmpty && nick != fromId) ? nick : _truncateId(fromId);
      }();
      // S2: encrypted messages show a privacy-preserving banner label
      final bannerText = isEncrypted
          ? '🔒 Encrypted message'
          : (contentType == 'text' && preview.isNotEmpty ? preview : '[$contentType]');

      // System tray notification — appears in the pull-down shade even when app is open
      await SovNotificationService.showMessageReceived(
        senderName: senderName,
        preview:    bannerText,
        fromId:     fromId,
      );

      _showMessageBanner(senderName, bannerText, fromId);
    });
  }

  // ── Received SOV transfer handler ─────────────────────────────────────────
  // Called when the relay pushes SOV_TRANSFER_RECEIVED to this device.
  // Persists the transaction, updates balance, fires a system notification,
  // and shows the in-app overlay banner so the citizen sees it immediately.

  Future<void> _handleTransferReceived(
      Map<String, dynamic> msg, String mySovId) async {
    // sov-node may send 'from_sovereign_id' (legacy relay field) or 'from_id' (new field).
    // Check both so the contact auto-save and transfer processing always work.
    final fromId     = (msg['from_id'] as String? ?? '').isNotEmpty
                       ? msg['from_id']  as String
                       : (msg['from_sovereign_id'] as String? ?? '');
    final amount     = (msg['amount']  as num?)?.toDouble() ?? 0.0;
    final txHash     = msg['tx_hash']  as String? ?? '';
    final memo       = msg['memo']     as String? ?? '';
    final timestamp  = (msg['timestamp'] as num?)?.toInt()
                       ?? DateTime.now().millisecondsSinceEpoch;
    final amountSeeds = (amount * 1000000).round();

    if (fromId.isEmpty || amountSeeds <= 0) return;

    // Auto-save sender as a contact on first received transfer.
    // Skip synthetic senders (SOV-SHIELD = exchange escrow engine).
    if (!fromId.startsWith('SOV-SHIELD')) {
      try {
        await ContactsDb.recordInteraction(
          sovereignId: fromId,
          nickname:    PalmNameEngine.deriveName([], sovereignId: fromId),
        );
      } catch (_) {}
    }

    // ── 0. Dedup guard — prevent duplicate banner when both the live push AND
    //       the HELLO-reconnect pending-tx push fire for the same transaction.
    //       TransactionStore.save() also deduplicates by tx_hash, but we check
    //       here first so the banner is also suppressed for known-stored txs.
    if (txHash.isNotEmpty) {
      try {
        final existing = await TransactionStore.load();
        final alreadyKnown = existing.any((e) {
          final h = (e['tx_hash'] as String? ?? '').trim();
          return h.isNotEmpty && h == txHash;
        });
        if (alreadyKnown) {
          debugPrint('[TX] _handleTransferReceived: dup tx_hash $txHash ignored');
          return;
        }
      } catch (_) {}
    }

    // ── 1. Persist to local transaction history + notify HomeTab ─────────────
    try {
      // [SOV-SHIELD] Preserve source + order_id for exchange escrow transactions
      final txSource  = msg['source']   as String? ?? '';
      final txOrderId = msg['order_id'] as String? ?? '';
      await TransactionStore.save({
        'tx_id':           txHash.isNotEmpty
                           ? txHash
                           : 'rx-${DateTime.now().millisecondsSinceEpoch}',
        'type':            'received',
        'amount_seeds':    amountSeeds,
        'counterparty_id': fromId,   // 'SOV-SHIELD' for escrow releases
        'tx_hash':         txHash,
        'timestamp':       timestamp,
        'status':          'confirmed',
        'relay_id':        RelayConnector.currentRelayId,
        'answered_by':     '',
        if (txSource.isNotEmpty)  'source':   txSource,
        if (txOrderId.isNotEmpty) 'order_id': txOrderId,
        if (memo.isNotEmpty)      'memo':     memo,
      });
      MessageEvents.notifyTransactionsChanged();
    } catch (_) {}

    // ── 2. Refresh balance from relay (non-blocking) ─────────────────────────
    // The relay will shortly push a LEDGER_SYNC; this eager query ensures the
    // home screen balance is current before the citizen taps into it.
    _refreshBalance();

    if (!mounted) return;

    // ── 3. System notification ───────────────────────────────────────────────
    await SovNotificationService.showTransferReceived(
      fromId:      fromId,
      amountSeeds: amountSeeds,
      txHash:      txHash,
    );

    if (!mounted) return;

    // ── 4. In-app overlay banner ─────────────────────────────────────────────
    final sov    = amountSeeds / 1000000;
    final sovStr = sov >= 1
        ? '${sov.toStringAsFixed(2)} SOV'
        : '${sov.toStringAsFixed(6)} SOV';
    // [SOV-SHIELD] Show "SOV Shield" as display name for exchange escrow releases
    final isShield   = fromId == 'SOV-SHIELD';
    final source     = msg['source'] as String? ?? '';
    final senderName = isShield
        ? 'SOV Shield'
        : () {
            final nick = PalmNameEngine.deriveName([], sovereignId: fromId);
            return (nick.isNotEmpty && nick != fromId) ? nick : _truncateId(fromId);
          }();
    final bannerLabel = isShield && source == 'exchange_refund'
        ? '+$sovStr (escrow refunded)'
        : '+$sovStr';
    _showTransferBanner(
      senderName, bannerLabel, fromId,
      color: isShield ? const Color(0xFF0D2E1F) : null,
      icon:  isShield ? Icons.shield_rounded    : null,
    );
  }

  // ── SOV transfer overlay banner ──────────────────────────────────────────
  // Green accent, wallet icon — tapping switches to the Home tab (where
  // the citizen can see their updated balance and transaction history).
  // [SOV-SHIELD] color and icon are overridable for exchange escrow events.
  void _showTransferBanner(String senderName, String amount, String fromId,
      {Color? color, IconData? icon}) {
    if (!mounted) return;
    OverlayEntry? entry;
    entry = OverlayEntry(
      builder: (ctx) => Positioned(
        top:   MediaQuery.of(ctx).viewPadding.top + 8,
        left:  16,
        right: 16,
        child: Material(
          elevation:    8,
          borderRadius: BorderRadius.circular(16),
          color:        color ?? const Color(0xFF0D2B1A),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () {
              entry?.remove();
              if (mounted) setState(() => _currentIndex = 0);
            },
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: const Border(
                  left: BorderSide(color: Color(0xFF4CAF50), width: 4),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    Icon(icon ?? Icons.account_balance_wallet_rounded,
                        color: const Color(0xFF4CAF50), size: 26),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            amount.startsWith('+') || amount.startsWith('–')
                                ? amount
                                : '$amount received',
                            style: const TextStyle(
                                color: Color(0xFF4CAF50),
                                fontWeight: FontWeight.bold,
                                fontSize: 16),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'From $senderName',
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 14),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(entry);
    Future.delayed(const Duration(seconds: 5), () {
      try { entry?.remove(); } catch (_) {}
    });
  }

  // ── SOV Speak message overlay banner ─────────────────────────────────────
  void _showMessageBanner(String senderName, String preview, String fromId) {
    if (!mounted) return;
    OverlayEntry? entry;
    entry = OverlayEntry(
      builder: (ctx) => Positioned(
        top: MediaQuery.of(ctx).viewPadding.top + 8,
        left: 16,
        right: 16,
        child: Material(
          elevation: 8,
          borderRadius: BorderRadius.circular(16),
          color: const Color(0xFF1A3A5C),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () {
              entry?.remove();
              // Switch to Messages tab
              if (mounted) setState(() { _currentIndex = 1; _unreadCount = 0; });
            },
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: const Border(
                  left: BorderSide(
                    color: Color(0xFFD4AF37),
                    width: 4,
                  ),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    const Icon(Icons.chat_rounded,
                        color: Color(0xFFD4AF37), size: 26),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(senderName,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16)),
                          const SizedBox(height: 2),
                          Text(preview,
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 14),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(entry);
    Future.delayed(const Duration(seconds: 4), () {
      try { entry?.remove(); } catch (_) {}
    });
  }


  // Exchange trade chat overlay banner
  void _showExchangeChatBanner(String senderName, String preview, String orderLabel) {
    if (!mounted) return;
    OverlayEntry? entry;
    entry = OverlayEntry(
      builder: (ctx) => Positioned(
        top: MediaQuery.of(ctx).viewPadding.top + 8,
        left: 16,
        right: 16,
        child: Material(
          elevation: 8,
          borderRadius: BorderRadius.circular(16),
          color: const Color(0xFF0D2535),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () {
              entry?.remove();
              if (mounted) setState(() => _currentIndex = 0);
            },
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: const Border(
                  left: BorderSide(color: Color(0xFF00BCD4), width: 4),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    const Icon(Icons.swap_horiz_rounded,
                        color: Color(0xFF00BCD4), size: 26),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'Trade message from $senderName',
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(orderLabel,
                                  style: const TextStyle(
                                      color: Color(0xFF00BCD4),
                                      fontSize: 11,
                                      fontFamily: 'monospace')),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(preview,
                              style: const TextStyle(
                                  color: Colors.white60, fontSize: 13),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(entry);
    Future.delayed(const Duration(seconds: 5), () {
      try { entry?.remove(); } catch (_) {}
    });
  }

  // ── S12 Issuance banner ──────────────────────────────────────────────────
  void _showIssuanceBanner(String sovStr, List<String> epochIds) {
    if (!mounted) return;
    OverlayEntry? entry;
    entry = OverlayEntry(
      builder: (ctx) => Positioned(
        top: MediaQuery.of(ctx).viewPadding.top + 8,
        left: 16,
        right: 16,
        child: Material(
          elevation: 8,
          borderRadius: BorderRadius.circular(16),
          color: const Color(0xFF1A1200),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () async {
              entry?.remove();
              final res = await RelayConnector.claimIssuance(epochIds);
              if (mounted) {
                final claimed = (res?['amount_seeds'] as num?)?.toInt() ?? 0;
                if (claimed > 0) {
                  final sov = claimed / 1000000.0;
                  final str = sov == sov.roundToDouble()
                      ? '${sov.toInt()} SOV'
                      : '${sov.toStringAsFixed(2)} SOV';
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text('$str claimed from SOV Network'),
                    backgroundColor: const Color(0xFF4CAF50),
                    duration: const Duration(seconds: 3),
                  ));
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(res?['error'] ?? 'Claim failed'),
                    backgroundColor: Colors.red[700],
                  ));
                }
              }
            },
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: const Border(left: BorderSide(color: Color(0xFFD4AF37), width: 4)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  const Icon(Icons.account_balance_rounded, color: Color(0xFFD4AF37), size: 26),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('SOV Allocation Ready',
                            style: TextStyle(color: Color(0xFFD4AF37), fontWeight: FontWeight.bold, fontSize: 14)),
                        const SizedBox(height: 2),
                        Text('$sovStr waiting — tap to claim',
                            style: const TextStyle(color: Colors.white70, fontSize: 13)),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right_rounded, color: Color(0xFFD4AF37)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(entry);
    Future.delayed(const Duration(seconds: 10), () {
      try { entry?.remove(); } catch (_) {}
    });
  }

  String _truncateId(String id) {
    if (id.length <= 18) return id;
    return '${id.substring(0, 12)}\u2026${id.substring(id.length - 6)}';
  }


  // ── Tab persistence ─────────────────────────────────────────────────────────

  Future<void> _saveTab(int index) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('last_tab_index', index);
  }

  Future<void> _restoreTabFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final last  = (prefs.getInt('last_tab_index') ?? 0).clamp(0, 5);
    if (mounted) setState(() => _currentIndex = last);
  }

  void _onTabChanged(int index) {
    setState(() {
      _currentIndex = index;
      if (index == 1) _unreadCount = 0; // clear badge when Messages tab opened
    });
    _saveTab(index);
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(
        backgroundColor: Color(0xFF0A1628),
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFFD4AF37)),
        ),
      );
    }

    final tabs = <Widget>[
      HomeTab(
        sovereignId: _sovereignId,
        seeds: _seeds,
        onSeedsChanged: (s) => setState(() => _seeds = s),
      ),
      MessagesScreen(sovereignId: _sovereignId),
      InheritanceScreen(sovereignId: _sovereignId, seeds: _seeds),
      GovernanceScreen(sovereignId: _sovereignId),
      AcademyScreen(sovereignId: _sovereignId),
      ProfileScreen(sovereignId: _sovereignId),
    ];

    return Scaffold(
      backgroundColor: _navy,
      body: IndexedStack(
        index: _currentIndex,
        children: tabs,
      ),
      bottomNavigationBar: NavigationBar(
        backgroundColor: _navy,
        indicatorColor: const Color(0xFFD4AF37).withAlpha(55),
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        selectedIndex: _currentIndex,
        onDestinationSelected: _onTabChanged,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        destinations: [
          const NavigationDestination(
            icon:         Icon(Icons.account_balance_wallet_outlined, color: Colors.white54),
            selectedIcon: Icon(Icons.account_balance_wallet,          color: Color(0xFFD4AF37)),
            label:        'Home',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: _unreadCount > 0,
              label: Text('$_unreadCount'),
              child: const Icon(Icons.forum_outlined, color: Colors.white54),
            ),
            selectedIcon: Badge(
              isLabelVisible: _unreadCount > 0,
              label: Text('$_unreadCount'),
              child: const Icon(Icons.forum, color: Color(0xFFD4AF37)),
            ),
            label: 'Messages',
          ),
          const NavigationDestination(
            icon:         Icon(Icons.lock_outline, color: Colors.white54),
            selectedIcon: Icon(Icons.lock,         color: Color(0xFFD4AF37)),
            label:        'Vault',
          ),
          const NavigationDestination(
            icon:         Icon(Icons.how_to_vote_outlined, color: Colors.white54),
            selectedIcon: Icon(Icons.how_to_vote,          color: Color(0xFFD4AF37)),
            label:        'Governance',
          ),
          const NavigationDestination(
            icon:         Icon(Icons.school_outlined, color: Colors.white54),
            selectedIcon: Icon(Icons.school,          color: Color(0xFFD4AF37)),
            label:        'Academy',
          ),
          const NavigationDestination(
            icon:         Icon(Icons.person_outline, color: Colors.white54),
            selectedIcon: Icon(Icons.person,         color: Color(0xFFD4AF37)),
            label:        'Profile',
          ),
        ],
      ),
    );
  }
}
