// lib/screens/sov_link_screen.dart
// â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
// SOV Speak â€” Message Thread Screen
//
// ARCHITECTURE: Thread view only.
//   This screen renders ONE conversation thread.
//   MessagesScreen owns the conversation list and navigation.
//   main_shell saves every incoming message to the local SQLite DB.
//   This screen only appends incoming messages to the in-memory display list â€”
//   it NEVER writes to the DB for incoming messages (main_shell already did).
//
// ENCRYPTION STATUS: NOT YET IMPLEMENTED
//   encrypted_payload field currently contains plain JSON.
//   True E2E encryption is designed and ready to implement in the next session.
//   See E2E investigation report for the full implementation plan.
//
// UNKNOWN SENDERS: Accepted
//   Any citizen can send messages.
//   The relay routes by Sovereign ID.
//   Blocking is the only filter â€” use the â‹® menu to block/unblock.
//
// NAVIGATION
//   Pushed by MessagesScreen._openThread(participantId).
//   Back button â†’ Navigator.pop â†’ MessagesScreen refreshes its list.
// â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import '../sov_node_sdk/relay_connector.dart';
import '../sov_node_sdk/contacts_db.dart';
import '../sov_node_sdk/conversation_utils.dart';
import '../sov_node_sdk/outbox_manager.dart';
import '../sov_node_sdk/draft_manager.dart';
import '../sov_node_sdk/draft_keys.dart';
import '../sov_node_sdk/media_handler.dart';
import '../sov_node_sdk/message_events.dart';
import '../sov_node_sdk/message_key_manager.dart';
import '../sov_node_sdk/message_encryptor.dart';
import '../sov_node_sdk/palm_name_engine.dart';
import '../widgets/voice_recorder_widget.dart';
import '../widgets/audio_player_widget.dart';
import 'send_sov_screen.dart';
// call_screen import removed 2026-05-20 — calls decommissioned

// â”€â”€ Secure random ID generator (replaces uuid dependency) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
String _generateId() {
  final rng   = Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

// â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

class SovLinkScreen extends StatefulWidget {
  final String mySovId;
  final String participantId;

  const SovLinkScreen({
    super.key,
    required this.mySovId,
    required this.participantId,
  });

  /// Set to the participantId of the currently open conversation thread.
  /// Cleared to null when the screen is disposed (thread is closed).
  /// MessagesScreen checks this to avoid incrementing unread count for a
  /// conversation the citizen is actively reading.
  static String? activeConversationId;

  @override
  State<SovLinkScreen> createState() => _SovLinkScreenState();
}

class _SovLinkScreenState extends State<SovLinkScreen> {
  static const _navy   = Color(0xFF0A1628);
  static const _gold   = Color(0xFFD4AF37);
  static const _cardBg = Color(0xFF0D1F3A);
  static const _teal   = Color(0xFF006B5E);

  // Thread state
  List<LocalMessage> _threadMessages = [];
  bool               _threadLoading  = true;
  final _scrollController = ScrollController();

  // Compose
  final _composeCtrl  = TextEditingController();
  final _composeFocus = FocusNode();
  bool  _sending      = false;

  // Media / voice UI
  bool _showingVoiceRecorder = false;
  bool _showAttachmentMenu   = false;

  // Blocking
  bool _isRecipientBlocked = false;

  // Contacts cache (for display name)
  Contact? _contact;

  // Relay-fetched palm name for the conversation partner.
  // Loaded asynchronously in _initThread; may be empty until fetch completes.
  String _participantPalmName = '';

  // Stream subscriptions
  StreamSubscription<Map<String, dynamic>>? _incomingSub;
  StreamSubscription<Map<String, dynamic>>? _readReceiptSub;
  StreamSubscription<Map<String, dynamic>>? _reactionSub;   // [S9]
  StreamSubscription<String>?              _onlineSub;

  // â”€â”€ Lifecycle â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  @override
  void initState() {
    super.initState();
    SovLinkScreen.activeConversationId = widget.participantId;
    _setupListeners();
    _initThread();
    OutboxManager.retryAll();
    // Keyboard-open scroll: when compose bar gets focus, scroll to the newest
    // message so it isn't hidden under the keyboard.
    _composeFocus.addListener(() {
      if (_composeFocus.hasFocus && mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) {
            _scrollController.animateTo(
              _scrollController.position.maxScrollExtent,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
            );
          }
        });
      }
    });
  }

  @override
  void dispose() {
    // Save any in-progress draft before the screen closes.
    DraftManager.save(
        DraftKeys.sovSpeak(widget.participantId), _composeCtrl.text);
    SovLinkScreen.activeConversationId = null;
    _incomingSub?.cancel();
    _readReceiptSub?.cancel();
    _reactionSub?.cancel();
    _onlineSub?.cancel();
    _composeCtrl.dispose();
    _composeFocus.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // â”€â”€ Initialise thread â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Future<void> _initThread() async {
    // Clear unread for this conversation so the badge resets immediately.
    await ContactsDb.clearUnread(_conversationId());
    final blocked = await ContactsDb.isContactBlocked(widget.participantId);
    final contact = await ContactsDb.getContact(widget.participantId);
    if (mounted) {
      setState(() {
        _isRecipientBlocked = blocked;
        _contact            = contact;
      });
    }
    // Fetch participant's palm name from relay (background, updates app bar).
    RelayConnector.prefetchPalmName(widget.participantId, onResolved: () {
      if (mounted) { setState(() {
        _participantPalmName =
            RelayConnector.cachedPalmNameFor(widget.participantId);
      }); }
    });
    await _loadThread();
    // Restore draft if citizen was composing before.
    final draft = await DraftManager.load(DraftKeys.sovSpeak(widget.participantId));
    if (draft.isNotEmpty && mounted) {
      setState(() => _composeCtrl.text = draft);
    }
  }

  Future<void> _loadThread() async {
    final msgs = await ContactsDb.getMessages(_conversationId());
    if (mounted) {
      setState(() { _threadMessages = msgs; _threadLoading = false; });
      // Scroll to bottom after frame renders.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        }
      });
    }
  }

  // â”€â”€ Stream listeners â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  void _setupListeners() {
    _incomingSub    = RelayConnector.incomingMessages.listen(_onIncoming);
    _readReceiptSub = RelayConnector.readReceipts.listen(_onReadReceipt);
    _reactionSub    = RelayConnector.reactionUpdates.listen(_onReactionUpdate); // [S9]
    _onlineSub      = OutboxManager.citizenOnlineStream.listen(_onCitizenOnline);
  }

  void _onIncoming(Map<String, dynamic> msg) {
    if (msg['type'] == 'MESSAGE_INCOMING') _handleIncomingMessage(msg);
  }

  /// Handle MESSAGE_INCOMING for THIS conversation only.
  /// Appends to the in-memory display list â€” does NOT write to DB.
  /// main_shell already persisted the message.
  Future<void> _handleIncomingMessage(Map<String, dynamic> msg) async {
    final messageId        = msg['message_id']        as String? ?? _generateId();
    final encryptedPayload = msg['encrypted_payload']  as String? ?? '';
    final messageType      = msg['message_type']      as String? ?? 'text';
    final sentAt           = (msg['sent_at'] as num?)?.toInt() ??
                             DateTime.now().millisecondsSinceEpoch;

    String  fromId        = '';
    String? displayText;
    String  effectiveType = messageType;

    // â”€â”€ S2: Attempt E2E decryption for v2 envelopes â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // v2: {"v":2,"nonce":"...","ct":"..."} â€” AES-256-GCM, X25519 ECDH
    // v1: {"v":1,"from":"...","text":"..."} or {"from":"...","text":"..."} â€” plain JSON
    String workingPayload = encryptedPayload;
    if (MessageEncryptor.isEncryptedEnvelope(encryptedPayload)) {
      final senderKey   = await RelayConnector.lookupMessagingKey(
          msg['from_sovereign_id'] as String? ?? '');
      final myPrivBytes = await MessageKeyManager.getPrivateKeyBytes();
      if (senderKey != null && myPrivBytes != null) {
        final decrypted = await MessageEncryptor.decryptEnvelope(
          envelope:       encryptedPayload,
          senderPubKeyHex: senderKey,
          myPrivKeyBytes:  myPrivBytes,
        );
        if (decrypted != null) {
          // Re-wrap as v1 so the rest of the parsing code works unchanged
          workingPayload = jsonEncode({
            'v': 1, 'from': msg['from_sovereign_id'] ?? '', 'text': decrypted,
          });
        }
        // If decryption fails (wrong key, tampered), workingPayload stays as v2
        // and we display null text below â€” better than showing garbled data
      }
    }

    // If the payload is STILL an encrypted v2 envelope here, decryption did not
    // succeed (the sender's messaging key was not available yet — typically the
    // very first message before their key propagates). NEVER render the raw
    // ciphertext: leave displayText null (a "🔒 Encrypted — syncing…" placeholder
    // is shown) and re-decrypt once the key syncs. fromId MUST come from the
    // transport, not the still-encrypted payload, or the participant filter below
    // would drop the message entirely.
    final bool stillEncrypted =
        MessageEncryptor.isEncryptedEnvelope(encryptedPayload) &&
        workingPayload == encryptedPayload;
    if (stillEncrypted) {
      fromId        = msg['from_sovereign_id'] as String? ?? '';
      effectiveType = 'text';
      displayText   = null;
    } else {
    try {
      final env = jsonDecode(workingPayload) as Map<String, dynamic>;
      fromId = env['from'] as String? ?? '';

      if (messageType == 'text' || messageType.isEmpty) {
        effectiveType = 'text';
        displayText   = env['text'] as String? ?? workingPayload;
      } else {
        effectiveType = env['contentType'] as String? ?? messageType;
        final data    = env['data'] as String?;
        if (data != null) {
          try {
            final mime  = env['mimeType'] as String? ?? '';
            final ext   = MediaHandler.extensionForMime(mime);
            final saved = await MediaHandler.saveReceivedMedia(
                data, '$messageId$ext');
            displayText = saved.path;
          } catch (e) {
            debugPrint('[SOVLINK] Failed to save received media: $e');
            displayText = null;
          }
        }
      }
    } catch (_) {
      // Not our encrypted format and not valid JSON — show a safe placeholder,
      // never raw bytes.
      displayText = MessageEncryptor.isEncryptedEnvelope(encryptedPayload)
          ? null
          : encryptedPayload;
    }
    }

    // Only handle messages for THIS conversation.
    if (fromId != widget.participantId) return;

    // Drop messages from blocked contacts.
    if (await ContactsDb.isContactBlocked(fromId)) return;

    final localMsg = LocalMessage(
      id:               messageId,
      conversationId:   _conversationId(),
      fromSovereignId:  fromId,
      toSovereignId:    widget.mySovId,
      contentType:      effectiveType,
      encryptedContent: encryptedPayload,
      decryptedContent: displayText,
      status:           'delivered',
      sentAt:           sentAt,
      deliveredAt:      DateTime.now().millisecondsSinceEpoch,
    );

    if (mounted) {
      setState(() => _threadMessages = [..._threadMessages, localMsg]);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      });
    }

    // First-message case: decryption hadn't resolved because the sender's
    // messaging key wasn't synced yet. Re-attempt in the background so the
    // "🔒 syncing…" placeholder becomes the real text.
    if (stillEncrypted) {
      _retryDecrypt(messageId, encryptedPayload, fromId);
    }

    // Send read receipt.
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('read_receipts_enabled') ?? true) {
      RelayConnector.sendRaw({
        'type':              'MESSAGE_READ',
        'from_sovereign_id': fromId,
        'message_id':        messageId,
        'read_at':           DateTime.now().millisecondsSinceEpoch,
      });
    }
  }

  /// Re-attempt decryption of a message whose first delivery arrived before the
  /// sender's messaging key was available. Retries a few times with backoff; on
  /// success, updates the stored row and the visible bubble in place.
  Future<void> _retryDecrypt(
      String messageId, String encryptedPayload, String senderId) async {
    for (int attempt = 1; attempt <= 4; attempt++) {
      await Future.delayed(Duration(seconds: attempt * 2));
      if (!mounted) return;
      final senderKey = await RelayConnector.lookupMessagingKey(senderId);
      final myPriv    = await MessageKeyManager.getPrivateKeyBytes();
      if (senderKey == null || myPriv == null) continue;
      final decrypted = await MessageEncryptor.decryptEnvelope(
        envelope:        encryptedPayload,
        senderPubKeyHex: senderKey,
        myPrivKeyBytes:  myPriv,
      );
      if (decrypted == null) continue;
      await ContactsDb.updateMessageDecrypted(messageId, decrypted);
      if (!mounted) return;
      setState(() {
        final i = _threadMessages.indexWhere((m) => m.id == messageId);
        if (i >= 0) _threadMessages[i].decryptedContent = decrypted;
      });
      return;
    }
  }

  void _onReadReceipt(Map<String, dynamic> msg) {
    final messageId = msg['message_id'] as String? ?? '';
    final readAt    = (msg['read_at'] as num?)?.toInt() ??
                      DateTime.now().millisecondsSinceEpoch;
    if (mounted) {
      setState(() {
        for (final m in _threadMessages) {
          // Only mark OUR sent messages as read â€” never incoming messages.
          // A read receipt means the OTHER person read a message WE sent.
          if (m.id == messageId && m.fromSovereignId == widget.mySovId) {
            m.status  = 'read';
            m.readAt  = readAt;
            // Persist to DB only for our own sent messages.
            ContactsDb.updateMessageStatus(messageId, 'read', readAt: readAt);
          }
        }
      });
    }
  }

  void _onCitizenOnline(String sovereignId) {
    if (!mounted) return;
    if (sovereignId == widget.participantId) _loadThread();
  }

  // [S9] Live reaction update â€” patch in-place without full reload
  void _onReactionUpdate(Map<String, dynamic> msg) {
    if (!mounted) return;
    final messageId = msg['message_id'] as String? ?? '';
    final raw       = msg['reactions']  as Map<String, dynamic>? ?? {};
    final reactions = raw.map(
      (k, v) => MapEntry(k, List<String>.from(v as List)));
    setState(() {
      for (final m in _threadMessages) {
        if (m.id == messageId) {
          m.reactions = reactions;
          break;
        }
      }
    });
    // Persist to local DB so reactions survive screen re-opens
    ContactsDb.updateMessageReactions(messageId, reactions);
  }

  // â”€â”€ Conversation ID â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  /// Canonical conversation ID â€” always matches what main_shell produces.
  String _conversationId() =>
      ConversationUtils.conversationId(widget.mySovId, widget.participantId);

  // â”€â”€ Display name helpers â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  String get _displayName {
    // 1. Relay-fetched palm name (e.g. "Shoreshaw") â€” best identifier
    if (_participantPalmName.isNotEmpty) return _participantPalmName;
    // 2. Cross-screen cache â€” available if another screen already fetched it
    final cached = RelayConnector.cachedPalmNameFor(widget.participantId);
    if (cached.isNotEmpty) return cached;
    // 3. Local address book: custom_label â†’ nickname (palm-derived) â†’ SOV-ID fallback
    if (_contact != null) return _contact!.displayName;
    // 4. Derive palm name from sovereign ID as last resort â€” consistent with
    //    contact list naming (same PalmNameEngine algorithm, no relay call needed).
    final fallback = PalmNameEngine.deriveName([], sovereignId: widget.participantId);
    if (fallback.isNotEmpty) return fallback;
    return _truncateId(widget.participantId);
  }

  String _truncateId(String id) {
    if (id.length <= 18) return id;
    return '${id.substring(0, 12)}\u2026${id.substring(id.length - 6)}';
  }

  String _relativeTime(int? ms) {
    if (ms == null) return '';
    final diff = DateTime.now()
        .difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours   < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  // [S9] Tick icon widget replacing plain status text
  Widget _buildStatusTick(String status) {
    switch (status) {
      case 'sending':
        return const Icon(Icons.access_time_rounded, size: 11, color: Colors.white30);
      case 'relayed':
      case 'sent':
        return const Icon(Icons.done, size: 11, color: Colors.white54);
      case 'delivered':
        return Icon(Icons.done_all, size: 11,
            color: Colors.white.withAlpha(140));
      case 'read':
        return const Icon(Icons.done_all, size: 11, color: _teal);
      case 'offline':
        return const Icon(Icons.schedule_rounded, size: 11,
            color: Colors.orangeAccent);
      case 'queued':
        return const Icon(Icons.schedule_rounded, size: 11, color: Colors.amber);
      case 'failed':
        return const Icon(Icons.error_outline, size: 11,
            color: Colors.redAccent);
      default:
        return const SizedBox.shrink();
    }
  }

  // [S9] Show emoji picker overlay on long-press
  void _showEmojiPicker(LocalMessage msg) {
    const emojis = ['ðŸ‘', 'â¤ï¸', 'ðŸ˜‚', 'ðŸ˜®', 'ðŸ˜¢', 'ðŸ”¥'];
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0D1F3A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: emojis.map((emoji) {
              final myId   = widget.mySovId;
              final hasIt  = msg.reactions[emoji]?.contains(myId) ?? false;
              return GestureDetector(
                onTap: () async {
                  Navigator.pop(context);
                  if (hasIt) {
                    await RelayConnector.unreactToMessage(
                      messageId:        msg.id,
                      otherSovereignId: widget.participantId,
                      emoji:            emoji,
                    );
                  } else {
                    await RelayConnector.reactToMessage(
                      messageId:        msg.id,
                      otherSovereignId: widget.participantId,
                      emoji:            emoji,
                      conversationId:   _conversationId(),
                    );
                  }
                },
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: hasIt
                        ? _teal.withAlpha(60)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(emoji,
                      style: const TextStyle(fontSize: 28)),
                ),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  // [S9] Reaction bar displayed below each bubble
  Widget _buildReactionBar(LocalMessage msg) {
    if (msg.reactions.isEmpty) return const SizedBox.shrink();
    final myId = widget.mySovId;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Wrap(
        spacing: 4,
        children: msg.reactions.entries.map((e) {
          final emoji   = e.key;
          final count   = e.value.length;
          final isMine  = e.value.contains(myId);
          return GestureDetector(
            onTap: () async {
              if (isMine) {
                await RelayConnector.unreactToMessage(
                  messageId:        msg.id,
                  otherSovereignId: widget.participantId,
                  emoji:            emoji,
                );
              } else {
                await RelayConnector.reactToMessage(
                  messageId:        msg.id,
                  otherSovereignId: widget.participantId,
                  emoji:            emoji,
                  conversationId:   _conversationId(),
                );
              }
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: isMine
                    ? _teal.withAlpha(70)
                    : Colors.white.withAlpha(15),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isMine
                      ? _teal.withAlpha(120)
                      : Colors.white.withAlpha(20),
                  width: 0.5,
                ),
              ),
              child: Text(
                count > 1 ? '$emoji $count' : emoji,
                style: const TextStyle(fontSize: 13),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  // â”€â”€ Text send â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Future<void> _send() async {
    final text = _composeCtrl.text.trim();
    if (text.isEmpty || _sending) return;

    if (_isRecipientBlocked) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('You have blocked this contact. Unblock them to send messages.'),
        backgroundColor: Color(0xFF7B1A1A),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }

    // Auto-add the recipient to local contacts on first outbound message —
    // sender side counterpart to the auto-add in main_shell's MESSAGE_INCOMING
    // handler. Idempotent. See SOV_Network_Protocol_Book_v1.0 §17 line 741.
    try { await ContactsDb.ensureContact(widget.participantId); } catch (_) {}

    setState(() => _sending = true);
    _composeCtrl.clear();
    await DraftManager.clear(DraftKeys.sovSpeak(widget.participantId));

    final messageId = _generateId();
    final now       = DateTime.now().millisecondsSinceEpoch;
    final convId    = _conversationId();

    // ── E2E encrypted send (v2 mandatory, 2026-05-21 hardening) ─────────────
    // Builds a v2 AES-256-GCM envelope using X25519 ECDH. The relay forwards
    // the opaque ciphertext but cannot read it — only the recipient's private
    // X25519 key can decrypt.
    //
    // v1 plaintext fallback REMOVED. If the recipient has no messaging key
    // on record (only happens for citizens enrolled before May 2026 who
    // haven't reopened the app once since the key registration shipped) we
    // ABORT the send and surface a clear error. This makes message E2E a
    // network-wide invariant rather than a best-effort property.
    String envelope;
    String displayText = text;
    {
      final recipientKey = await RelayConnector.lookupMessagingKey(
          widget.participantId);
      final myPrivBytes  = await MessageKeyManager.getPrivateKeyBytes();

      if (recipientKey == null || recipientKey.isEmpty) {
        // Recipient hasn't registered an E2E key yet (enrolled before key
        // registration shipped, or hasn't opened the app since).
        // Queue the plaintext locally — OutboxManager will encrypt + send
        // automatically the moment they open the app and register their key.
        final convId = _conversationId();
        final now = DateTime.now().millisecondsSinceEpoch;
        final localMsg = LocalMessage(
          id:               messageId,
          conversationId:   convId,
          fromSovereignId:  widget.mySovId,
          toSovereignId:    widget.participantId,
          contentType:      'text',
          encryptedContent: text,
          decryptedContent: text,
          status:           'queued',
          sentAt:           now,
        );
        await ContactsDb.saveMessage(localMsg);
        await ContactsDb.upsertConversation(
          id: convId, participantId: widget.participantId,
          preview: text, lastMessageAt: now,
        );
        await OutboxManager.queueAwaitingKey(
          messageId:     messageId,
          toSovereignId: widget.participantId,
          plaintext:     text,
          contentType:   'text',
        );
        MessageEvents.notifyConversationChanged();
        if (mounted) {
          setState(() {
            _sending = false;
            _threadMessages = [..._threadMessages, localMsg];
          });
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
              'Queued — will be encrypted and sent when they open the SOV app.',
            ),
            duration: Duration(seconds: 4),
            backgroundColor: Color(0xFF1A4A2A),
          ));
        }
        return;
      }
      if (myPrivBytes == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Your encryption key is not initialised. Restart the app.'),
            duration: Duration(seconds: 4),
          ));
        }
        setState(() => _sending = false);
        return;
      }

      final encrypted = await MessageEncryptor.encrypt(
        plaintext:         text,
        recipientPubKeyHex: recipientKey,
        myPrivKeyBytes:    myPrivBytes,
      );
      if (encrypted == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Encryption failed. Message not sent.'),
            duration: Duration(seconds: 4),
          ));
        }
        setState(() => _sending = false);
        return;
      }
      envelope    = encrypted;
      displayText = text; // keep plaintext locally for our own display
    }

    final localMsg = LocalMessage(
      id:               messageId,
      conversationId:   convId,
      fromSovereignId:  widget.mySovId,
      toSovereignId:    widget.participantId,
      contentType:      'text',
      encryptedContent: envelope,
      decryptedContent: displayText,
      status:           'sending',
      sentAt:           now,
    );
    await ContactsDb.saveMessage(localMsg);
    await ContactsDb.recordInteraction(
      sovereignId: widget.participantId,
      nickname:    PalmNameEngine.deriveName([], sovereignId: widget.participantId),
    );
    // Ensure the conversation row exists on the SENDER's side immediately.
    // Without this, the conversation never appears in the sender's list
    // until they receive a reply (which is when main_shell creates the row).
    await ContactsDb.upsertConversation(
      id:            convId,
      participantId: widget.participantId,
      preview:       text,
      lastMessageAt: now,
    );
    // Notify MessagesScreen so it refreshes the conversation list right away.
    MessageEvents.notifyConversationChanged();
    if (mounted) setState(() => _threadMessages = [..._threadMessages, localMsg]);

    await _dispatchToRelay(
      messageId:   messageId,
      envelope:    envelope,
      contentType: 'text',
    );

    if (mounted) setState(() => _sending = false);
  }

  // â”€â”€ Media send â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Future<void> _sendMedia(MediaResult media) async {
    final sizeLabel = MediaHandler.formatSize(media.sizeBytes);

    if (!MediaHandler.isRelayRoutable(media.sizeBytes)) {
      if (!mounted) return;
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: _navy,
          title: const Text('Large File',
              style: TextStyle(color: _gold, fontWeight: FontWeight.bold)),
          content: Text(
            'This file is $sizeLabel. '
            'Files over 25 MB are stored locally and sent directly to the '
            'recipient when they come online.',
            style: const TextStyle(color: Colors.white70, height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel',
                  style: TextStyle(color: Colors.white54)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                  backgroundColor: _gold, foregroundColor: Colors.black),
              child: const Text('Send Anyway',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      );
      if (proceed != true) return;
    }

    await _sendMessageContent(
      messageId:       _generateId(),
      contentType:     media.contentType,
      localFilePath:   media.file.path,
      mimeType:        media.mimeType,
      sizeBytes:       media.sizeBytes,
      thumbnailBase64: media.thumbnailBase64,
    );
  }

  Future<void> _sendMessageContent({
    required String messageId,
    required String contentType,
    required String localFilePath,
    String? mimeType,
    int sizeBytes = 0,
    String? thumbnailBase64,
  }) async {
    if (_isRecipientBlocked) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('You have blocked this contact. Unblock them to send messages.'),
          backgroundColor: Color(0xFF7B1A1A),
          behavior: SnackBarBehavior.floating,
        ));
      }
      return;
    }

    setState(() => _sending = true);

    // try/finally guarantees _sending is always reset â€” even if a DB call
    // throws mid-flight or the async lambda's Future was discarded by the
    // VoidCallback caller higher up the stack.
    try {
      final now    = DateTime.now().millisecondsSinceEpoch;
      final convId = _conversationId();

      final isRoutable = MediaHandler.isRelayRoutable(sizeBytes);
      String relayBase64 = '';
      if (isRoutable) {
        try {
          relayBase64 = await MediaHandler.fileToBase64(File(localFilePath));
        } catch (e) {
          debugPrint('[SOVLINK] Media encode error: $e');
        }

        // Guard: if encoding failed for a routable file we must NOT send a
        // data-less message.  Show an error and bail â€” do not add a broken
        // message to the thread.
        if (relayBase64.isEmpty) {
          debugPrint('[SOVLINK] relayBase64 empty after encode â€” aborting send');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text(
                  'Could not read media file. Please try again.'),
              backgroundColor: Color(0xFF7B1A1A),
              behavior: SnackBarBehavior.floating,
            ));
          }
          return;
        }
      }

      final envelopeMap = <String, dynamic>{
        'from':        widget.mySovId,
        'contentType': contentType,
        if (mimeType != null) 'mimeType': mimeType,
        'sizeBytes':   sizeBytes,
        if (relayBase64.isNotEmpty) 'data': relayBase64,
        if (thumbnailBase64 != null) 'thumbnail': thumbnailBase64,
      };
      final envelope = jsonEncode(envelopeMap);

      final localMsg = LocalMessage(
        id:               messageId,
        conversationId:   convId,
        fromSovereignId:  widget.mySovId,
        toSovereignId:    widget.participantId,
        contentType:      contentType,
        encryptedContent: envelope,
        decryptedContent: localFilePath,
        status:           'sending',
        sentAt:           now,
      );
      await ContactsDb.saveMessage(localMsg);
      await ContactsDb.recordInteraction(
        sovereignId: widget.participantId,
        nickname:    PalmNameEngine.deriveName([], sovereignId: widget.participantId),
      );
      await ContactsDb.upsertConversation(
        id:            convId,
        participantId: widget.participantId,
        preview:       '[$contentType]',
        lastMessageAt: now,
      );
      MessageEvents.notifyConversationChanged();
      if (mounted) setState(() => _threadMessages = [..._threadMessages, localMsg]);

      if (!isRoutable) {
        await ContactsDb.updateMessageStatus(messageId, 'queued');
        if (mounted) {
          setState(() {
            for (final m in _threadMessages) {
              if (m.id == messageId) m.status = 'queued';
            }
          });
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Large file queued — will be sent when recipient is online.'),
            backgroundColor: _cardBg,
            behavior: SnackBarBehavior.floating,
          ));
        }
        return;
      }

      await _dispatchToRelay(
        messageId:   messageId,
        envelope:    envelope,
        contentType: contentType,
        timeoutSecs: 30,
      );
    } finally {
      // Always reset the spinner â€” no matter which path returns or throws.
      if (mounted) setState(() => _sending = false);
    }
  }

  // â”€â”€ Relay dispatch â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Future<void> _dispatchToRelay({
    required String messageId,
    required String envelope,
    required String contentType,
    int timeoutSecs = 10,
    bool isRetry = false,
  }) async {
    try {
      if (!RelayConnector.isConnected) await RelayConnector.connect();

      final result = await RelayConnector.sendAndWait(
        request: {
          'type':              'MESSAGE_SEND',
          'to_sovereign_id':   widget.participantId,
          'encrypted_payload': envelope,
          'message_type':      contentType,
          'message_id':        messageId,
        },
        responseType: 'MESSAGE_SEND_RESULT',
        timeout:      Duration(seconds: timeoutSecs),
        matchField:   'message_id',
        matchValue:   messageId,
      );

      if (result?['success'] == true) {
        // â”€â”€ Relay confirmed the send. Two possible statuses: â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
        //
        // 'delivered' â€” Physical socket.send() succeeded on the destination relay
        //               (E2E ack confirmed). This is the only status that means
        //               the recipient's device actually received the message bytes.
        //
        // 'forwarded' â€” Legacy/fallback: relay forwarded without waiting for ack
        //               (only on old relay nodes or if direct peer link is down).
        //               We show 'Relayed' and queue in outbox for safety.
        final relayStatus      = result?['status'] as String? ?? '';
        final isDirectDelivery = relayStatus == 'delivered';
        final isForwarded      = relayStatus == 'forwarded';

        final newStatus   = isDirectDelivery ? 'delivered' : 'relayed';
        final deliveredAt = isDirectDelivery
            ? DateTime.now().millisecondsSinceEpoch
            : null;

        await ContactsDb.updateMessageStatus(messageId, newStatus,
            deliveredAt: deliveredAt);
        if (mounted) {
          setState(() {
            for (final m in _threadMessages) {
              if (m.id == messageId) {
                m.status = newStatus;
                if (deliveredAt != null) m.deliveredAt = deliveredAt;
              }
            }
          });
        }

        // Legacy 'forwarded' path: queue in outbox so CITIZEN_ONLINE retry
        // fires if delivery was not actually confirmed by the destination relay.
        if (isForwarded) {
          await OutboxManager.queueMessage(
            messageId:        messageId,
            toSovereignId:    widget.participantId,
            encryptedContent: envelope,
            contentType:      contentType,
          );
        }
      } else if (result?['error'] == 'RECIPIENT_OFFLINE' ||
                 result?['error'] == 'DELIVERY_FAILED'   ||
                 result?['reason'] == 'offline'           ||
                 result?['reason'] == 'no_receipt') {
        // â”€â”€ Relay confirmed the recipient's socket was not open at delivery time â”€
        //
        // RECIPIENT_OFFLINE = sov_presence check: no active socket.
        // DELIVERY_FAILED   = socket existed but send() threw (stale entry).
        // reason='offline'  = E2E ack from destination relay: physical socket
        //                     was missing or readyState â‰  OPEN at the exact
        //                     millisecond the destination relay attempted delivery.
        //
        // All three mean the same thing: the recipient did NOT receive this
        // message. We show 'Offline' and queue it for automatic retry when
        // they reconnect.
        await ContactsDb.updateMessageStatus(messageId, 'offline');
        await OutboxManager.queueMessage(
          messageId:        messageId,
          toSovereignId:    widget.participantId,
          encryptedContent: envelope,
          contentType:      contentType,
        );
        if (mounted) {
          setState(() {
            for (final m in _threadMessages) {
              if (m.id == messageId) m.status = 'offline';
            }
          });
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
              'Recipient is offline. Your message will be delivered automatically '
              'when they reconnect. For urgent matters, contact them directly.',
            ),
            backgroundColor: Color(0xFF7B3A00),
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 5),
          ));
        }
      } else if (result == null) {
        // â”€â”€ Timeout â€” no response from relay. â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
        // We don't know what happened.  Queue locally and retry on reconnect.
        await ContactsDb.updateMessageStatus(messageId, 'queued');
        await OutboxManager.queueMessage(
          messageId:        messageId,
          toSovereignId:    widget.participantId,
          encryptedContent: envelope,
          contentType:      contentType,
        );
        if (mounted) {
          setState(() {
            for (final m in _threadMessages) {
              if (m.id == messageId) m.status = 'queued';
            }
          });
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
              'No relay response. Message queued — will retry automatically.',
            ),
            backgroundColor: _cardBg,
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 4),
          ));
        }
      } else if ((result['error'] == 'SIGNATURE_REQUIRED') && !isRetry) {
        // â”€â”€ Session fell into legacy mode (unsigned/late HELLO). â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
        // The node rejects MESSAGE_SEND with SIGNATURE_REQUIRED for the whole life
        // of a legacy session. Force a fresh, signed handshake and retry the send
        // ONCE before giving up (bounded by isRetry so we can't loop). The HELLO
        // signing/republish fixes in relay_connector make the reconnect deterministic.
        debugPrint('[SOVLINK] SIGNATURE_REQUIRED â€” reconnecting with a signed HELLO and retrying send');
        try { RelayConnector.disconnect(); } catch (_) {}
        await Future.delayed(const Duration(milliseconds: 300));
        try { await RelayConnector.connect(); } catch (_) {}
        await Future.delayed(const Duration(milliseconds: 500));
        await _dispatchToRelay(
          messageId:   messageId,
          envelope:    envelope,
          contentType: contentType,
          timeoutSecs: timeoutSecs,
          isRetry:     true,
        );
        return;
      } else {
        // Permanent failure â€” wrong sovereign ID, relay rejected, etc.
        await ContactsDb.updateMessageStatus(messageId, 'failed');
        if (mounted) {
          setState(() {
            for (final m in _threadMessages) {
              if (m.id == messageId) m.status = 'failed';
            }
          });
        }
      }
    } catch (e) {
      await ContactsDb.updateMessageStatus(messageId, 'failed');
      if (mounted) {
        setState(() {
          for (final m in _threadMessages) {
            if (m.id == messageId) m.status = 'failed';
          }
        });
      }
    }
  }

  // â”€â”€ Attachment menu â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  void _showAttachmentOptions() {
    setState(() => _showAttachmentMenu = true);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _navy,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
                width: 40, height: 4,
                decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 12),
            _attachOption(Icons.camera_alt_outlined, 'Camera', () async {
              // Set flag BEFORE pop â€” bottom-sheet dismiss fires 'inactive'
              // on some OEM skins, which would set _pausedAt before the picker
              // even opens, causing a false PIN lock after > 2s in the camera.
              RelayConnector.externalActivityOpen = true;
              Navigator.pop(ctx);
              MediaResult? m;
              try { m = await MediaHandler.pickImage(camera: true); }
              finally { RelayConnector.externalActivityOpen = false; }
              if (m != null && mounted) await _sendMedia(m);
            }),
            _attachOption(Icons.image_outlined, 'Photo from Gallery', () async {
              RelayConnector.externalActivityOpen = true;
              Navigator.pop(ctx);
              MediaResult? m;
              try { m = await MediaHandler.pickImage(); }
              finally { RelayConnector.externalActivityOpen = false; }
              if (m != null && mounted) await _sendMedia(m);
            }),
            _attachOption(Icons.videocam_outlined, 'Video', () async {
              RelayConnector.externalActivityOpen = true;
              Navigator.pop(ctx);
              MediaResult? m;
              try { m = await MediaHandler.pickVideo(); }
              finally { RelayConnector.externalActivityOpen = false; }
              if (m != null && mounted) await _sendMedia(m);
            }),
            _attachOption(Icons.attach_file_outlined, 'File', () async {
              RelayConnector.externalActivityOpen = true;
              Navigator.pop(ctx);
              MediaResult? m;
              try { m = await MediaHandler.pickFile(); }
              finally { RelayConnector.externalActivityOpen = false; }
              if (m != null && mounted) await _sendMedia(m);
            }),
            const SizedBox(height: 16),
          ],
        ),
      ),
    ).whenComplete(() {
      if (mounted) setState(() => _showAttachmentMenu = false);
    });
  }

  Widget _attachOption(IconData icon, String label, Future<void> Function() onTap) {
    return ListTile(
      leading: Icon(icon, color: _gold),
      title: Text(label, style: const TextStyle(color: Colors.white)),
      // Wrap in a void closure so ListTile.onTap (GestureTapCallback) is
      // satisfied, but we still catch any async error and reset _sending.
      onTap: () {
        onTap().catchError((Object e) {
          debugPrint('[SOVLINK] Attach error: $e');
          if (mounted) setState(() => _sending = false);
        });
      },
    );
  }

  // â”€â”€ Full-screen media viewers â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  void _openFullImage(String filePath) {
    Navigator.push(context, MaterialPageRoute(
        builder: (_) => _FullImageViewer(filePath: filePath)));
  }

  void _openVideo(LocalMessage msg) {
    final path = msg.decryptedContent;
    if (path == null || path.isEmpty) return;
    Navigator.push(context, MaterialPageRoute(
        builder: (_) => _VideoPlayerScreen(filePath: path)));
  }

  // â”€â”€ Block / Unblock / Clear â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Future<void> _blockContact() async {
    final existing = await ContactsDb.getContact(widget.participantId);
    if (existing == null) {
      await ContactsDb.recordInteraction(
        sovereignId: widget.participantId,
        nickname:    PalmNameEngine.deriveName([], sovereignId: widget.participantId),
      );
    }
    await ContactsDb.blockContact(widget.participantId);
    if (mounted) {
      setState(() => _isRecipientBlocked = true);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('$_displayName has been blocked.'),
        backgroundColor: const Color(0xFF7B1A1A),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  Future<void> _unblockContact() async {
    await ContactsDb.unblockContact(widget.participantId);
    if (mounted) {
      setState(() => _isRecipientBlocked = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('$_displayName has been unblocked.'),
        backgroundColor: _teal,
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  Future<void> _clearConversation() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _navy,
        title: const Text('Clear Conversation',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: const Text(
          'All messages in this conversation will be permanently deleted from this device.',
          style: TextStyle(color: Colors.white70, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
            child: const Text('Delete', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final database = await ContactsDb.db;
    final convId   = _conversationId();
    await database.delete('messages',
        where: 'conversation_id = ?', whereArgs: [convId]);
    await database.delete('conversations',
        where: 'id = ?', whereArgs: [convId]);
    if (mounted) {
      setState(() => _threadMessages = []);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Conversation cleared.'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  // â”€â”€ Build â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _navy,
      // resizeToAvoidBottomInset=false: we manage keyboard inset manually via
      // viewInsets.bottom in _buildComposeBar. Without this, Flutter shrinks the
      // scaffold body AND the compose bar adds viewInsets again â€” double-counting
      // on small phones collapses the message list to almost nothing.
      resizeToAvoidBottomInset: false,
      appBar: _buildAppBar(),
      body: _threadLoading
          ? const Center(child: CircularProgressIndicator(color: _gold))
          : _buildThread(),
    );
  }

  // â”€â”€ AppBar â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  AppBar _buildAppBar() => AppBar(
        backgroundColor: _navy,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_displayName,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold)),
            Text(_truncateId(widget.participantId),
                style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 10,
                    fontFamily: 'monospace')),
          ],
        ),
        actions: [
          // Voice call entrypoint removed 2026-05-20 — feature decommissioned
          // pending re-architecture (see CLAUDE.md §-2). Phone icon hidden so
          // citizens don't see a button that doesn't work.
          // â”€â”€ In-thread SOV Send shortcut â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
          IconButton(
            icon: const Icon(Icons.account_balance_wallet_rounded,
                color: Color(0xFFD4AF37), size: 22),
            tooltip: 'Send SOV',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => SendSovScreen(
                  sovereignId:       widget.mySovId,
                  seeds:             0, // HomeTab owns the live balance
                  lockedSeeds:       0,
                  initialRecipientId: widget.participantId,
                ),
              ),
            ),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Colors.white70),
            color: const Color(0xFF0D1F3A),
            onSelected: (value) async {
              switch (value) {
                case 'copy_id':
                  await Clipboard.setData(
                      ClipboardData(text: widget.participantId));
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Sovereign ID copied'),
                        behavior: SnackBarBehavior.floating,
                        duration: Duration(seconds: 2),
                      ),
                    );
                  }
                  break;
                case 'block':
                  await _blockContact();
                  break;
                case 'unblock':
                  await _unblockContact();
                  break;
                case 'clear':
                  await _clearConversation();
                  break;
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'copy_id',
                child: Row(children: [
                  Icon(Icons.copy_rounded, color: Colors.white70, size: 18),
                  SizedBox(width: 10),
                  Text('Copy ID', style: TextStyle(color: Colors.white)),
                ]),
              ),
              PopupMenuItem(
                value: _isRecipientBlocked ? 'unblock' : 'block',
                child: Row(children: [
                  Icon(
                    _isRecipientBlocked
                        ? Icons.lock_open_rounded
                        : Icons.block_rounded,
                    color: _isRecipientBlocked
                        ? Colors.greenAccent
                        : Colors.redAccent,
                    size: 18,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    _isRecipientBlocked ? 'Unblock' : 'Block',
                    style: TextStyle(
                      color: _isRecipientBlocked
                          ? Colors.greenAccent
                          : Colors.redAccent,
                    ),
                  ),
                ]),
              ),
              const PopupMenuItem(
                value: 'clear',
                child: Row(children: [
                  Icon(Icons.delete_sweep_rounded, color: Colors.orange, size: 18),
                  SizedBox(width: 10),
                  Text('Clear conversation',
                      style: TextStyle(color: Colors.orange)),
                ]),
              ),
            ],
          ),
        ],
      );

  // â”€â”€ Thread â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Widget _buildThread() {
    return Column(
      children: [
        if (_isRecipientBlocked)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: const Color(0xFF7B1A1A),
            child: Row(
              children: [
                const Icon(Icons.block_rounded, color: Colors.white70, size: 16),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'This contact is blocked. Unblock from the menu to send messages.',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
                TextButton(
                  onPressed: _unblockContact,
                  style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(0, 0),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                  child: const Text('Unblock',
                      style: TextStyle(
                          color: _gold, fontSize: 12, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
        Expanded(
          child: _threadMessages.isEmpty
              ? _buildThreadEmpty()
              : ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                  itemCount: _threadMessages.length,
                  itemBuilder: (_, i) => _buildBubble(_threadMessages[i]),
                ),
        ),
        _buildComposeBar(),
      ],
    );
  }

  Widget _buildThreadEmpty() {
    return Center(
      child: Text(
        'Say hello to $_displayName',
        style: const TextStyle(color: Colors.white38, fontSize: 13),
      ),
    );
  }

  // â”€â”€ Message content renderer â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Widget _buildMessageContent(LocalMessage msg) {
    final isMe      = msg.fromSovereignId == widget.mySovId;
    final textColor = isMe ? _gold : Colors.white;

    switch (msg.contentType) {

      case 'image':
        final path = msg.decryptedContent;
        if (path != null && File(path).existsSync()) {
          return GestureDetector(
            onTap: () => _openFullImage(path),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.file(
                File(path),
                width: 200, height: 200,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _mediaErrorBox('Image unavailable'),
              ),
            ),
          );
        }
        try {
          final env  = jsonDecode(msg.encryptedContent) as Map<String, dynamic>;
          final data = env['data'] as String?;
          if (data != null) {
            final bytes = base64Decode(data);
            return GestureDetector(
              // Tap to open full-screen zoomable viewer (same UX as file-path branch)
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => _FullImageViewerMemory(bytes: bytes),
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.memory(
                  bytes,
                  width: 200, height: 200,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _mediaErrorBox('Image unavailable'),
                ),
              ),
            );
          }
        } catch (_) {}
        return _mediaErrorBox('Image unavailable');

      case 'voice':
      case 'audio':
        final path = msg.decryptedContent;
        return AudioPlayerWidget(
          filePath:   (path != null && File(path).existsSync()) ? path : null,
          durationMs: null,
          isOwn:      isMe,
        );

      case 'video':
        return GestureDetector(
          onTap: () => _openVideo(msg),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 200, height: 150,
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.videocam,
                    color: Colors.white38, size: 48),
              ),
              const Icon(Icons.play_circle_filled, color: _gold, size: 52),
            ],
          ),
        );

      case 'file':
        final filename = msg.decryptedContent != null
            ? msg.decryptedContent!.split('/').last
            : 'File';
        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF1A3A5C),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.insert_drive_file, color: _gold, size: 24),
              const SizedBox(width: 8),
              Flexible(
                child: Text(filename,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    maxLines: 2, overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
        );

      default: // 'text' and anything unknown
        final raw = msg.decryptedContent ?? msg.encryptedContent;
        // Never show a raw encrypted envelope as message text — if decryption
        // hasn't resolved yet (or an older message was stored un-decrypted),
        // show a placeholder while the re-decrypt pass runs.
        final isCipher = MessageEncryptor.isEncryptedEnvelope(raw);
        return Text(
          isCipher ? '🔒 Encrypted — syncing…' : raw,
          style: TextStyle(
            color: isCipher ? textColor.withOpacity(0.6) : textColor,
            fontSize: 14, height: 1.4,
            fontStyle: isCipher ? FontStyle.italic : FontStyle.normal,
          ),
        );
    }
  }

  Widget _mediaErrorBox(String label) {
    return Container(
      width: 200, height: 80,
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(8),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Center(
        child: Text(label,
            style: const TextStyle(color: Colors.white38, fontSize: 12)),
      ),
    );
  }

  // â”€â”€ Chat bubble â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Widget _buildBubble(LocalMessage msg) {
    final isMe      = msg.fromSovereignId == widget.mySovId;
    final isMedia   = msg.contentType != 'text';
    final timeLabel = _relativeTime(msg.sentAt);

    return Padding(
      padding: EdgeInsets.only(
          bottom: 8,
          left:   isMe ? 48 : 0,
          right:  isMe ? 0  : 48),
      child: Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Column(
          crossAxisAlignment:
              isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            // [S9] Long-press opens emoji picker
            GestureDetector(
              onLongPress: () => _showEmojiPicker(msg),
              child: Container(
                padding: isMedia
                    ? const EdgeInsets.all(4)
                    : const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: isMe ? _gold.withAlpha(30) : _cardBg,
                  borderRadius: BorderRadius.only(
                    topLeft:     const Radius.circular(16),
                    topRight:    const Radius.circular(16),
                    bottomLeft:  Radius.circular(isMe ? 16 : 4),
                    bottomRight: Radius.circular(isMe ? 4  : 16),
                  ),
                  border: Border.all(
                    color: isMe
                        ? _gold.withAlpha(60)
                        : Colors.white.withAlpha(10),
                  ),
                ),
                child: _buildMessageContent(msg),
              ),
            ),
            const SizedBox(height: 3),
            // Time + tick status row
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(timeLabel,
                    style: const TextStyle(
                        color: Colors.white24, fontSize: 10)),
                if (isMe) ...[
                  const SizedBox(width: 4),
                  _buildStatusTick(msg.status), // [S9] tick icons
                ],
              ],
            ),
            // [S9] Reaction chips
            _buildReactionBar(msg),
          ],
        ),
      ),
    );
  }

  // â”€â”€ Compose bar â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Widget _buildComposeBar() {
    if (_showingVoiceRecorder) {
      return Container(
        decoration: BoxDecoration(
          color: _cardBg,
          border: Border(top: BorderSide(color: Colors.white.withAlpha(10))),
        ),
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: VoiceRecorderWidget(
          onRecordingComplete: (file, duration) async {
            if (mounted) setState(() => _showingVoiceRecorder = false);
            final sizeBytes = await file.length();
            final media = MediaResult(
              file:        file,
              contentType: 'voice',
              mimeType:    'audio/aac',
              sizeBytes:   sizeBytes,
              durationMs:  duration,
            );
            if (mounted) await _sendMedia(media);
          },
          onCancel: () {
            if (mounted) setState(() => _showingVoiceRecorder = false);
          },
        ),
      );
    }

    return Container(
      padding: EdgeInsets.only(
        left: 4, right: 8, top: 8,
        bottom: MediaQuery.of(context).viewInsets.bottom + 12,
      ),
      decoration: BoxDecoration(
        color: _cardBg,
        border: Border(top: BorderSide(color: Colors.white.withAlpha(10))),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          IconButton(
            icon: Icon(
              Icons.attach_file,
              color: _showAttachmentMenu ? _gold : Colors.white54,
              size: 22,
            ),
            tooltip: 'Attach file',
            onPressed: _showAttachmentOptions,
          ),
          Expanded(
            child: TextField(
              controller: _composeCtrl,
              focusNode:  _composeFocus,
              maxLines:   4,
              minLines:   1,
              textCapitalization: TextCapitalization.sentences,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(
                hintText:  'Message\u2026',
                hintStyle: const TextStyle(
                    color: Colors.white38, fontSize: 14),
                filled:    true,
                fillColor: _navy,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 10),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide.none),
              ),
              onChanged: (v) {
                DraftManager.save(
                    DraftKeys.sovSpeak(widget.participantId), v);
              },
            ),
          ),
          const SizedBox(width: 4),
          GestureDetector(
            onLongPress: () {
              if (mounted) setState(() => _showingVoiceRecorder = true);
            },
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              child: Icon(Icons.mic_outlined,
                  color: Colors.white54, size: 24),
            ),
          ),
          const SizedBox(width: 4),
          _sending
              ? const SizedBox(
                  width: 44, height: 44,
                  child: CircularProgressIndicator(
                      color: _gold, strokeWidth: 2))
              : GestureDetector(
                  onTap: _send,
                  child: Container(
                    width: 44, height: 44,
                    decoration: const BoxDecoration(
                        color: _gold, shape: BoxShape.circle),
                    child: const Icon(Icons.send_rounded,
                        color: Colors.black, size: 20),
                  ),
                ),
        ],
      ),
    );
  }
}

// â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
// Full-image viewer
// â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

class _FullImageViewer extends StatelessWidget {
  final String filePath;
  const _FullImageViewer({required this.filePath});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 5.0,
          child: Image.file(
            File(filePath),
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => const Center(
              child: Text('Unable to load image',
                  style: TextStyle(color: Colors.white54)),
            ),
          ),
        ),
      ),
    );
  }
}

// â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
// Full-screen image viewer â€” bytes (base64-decoded received image)
// Used when no local file path is available (recipient side, relay-delivered).
// â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
class _FullImageViewerMemory extends StatelessWidget {
  final Uint8List bytes;
  const _FullImageViewerMemory({required this.bytes});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 5.0,
          child: Image.memory(
            bytes,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => const Center(
              child: Text('Unable to load image',
                  style: TextStyle(color: Colors.white54)),
            ),
          ),
        ),
      ),
    );
  }
}

// â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
// Video player screen
// â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

class _VideoPlayerScreen extends StatefulWidget {
  final String filePath;
  const _VideoPlayerScreen({required this.filePath});

  @override
  State<_VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<_VideoPlayerScreen> {
  late VideoPlayerController _ctrl;
  bool _initialized = false;
  bool _hasError    = false;

  @override
  void initState() {
    super.initState();
    _ctrl = VideoPlayerController.file(File(widget.filePath));
    _ctrl.initialize().then((_) {
      if (mounted) {
        setState(() => _initialized = true);
        _ctrl.play();
      }
    }).catchError((e) {
      if (mounted) setState(() => _hasError = true);
    });
    _ctrl.addListener(() { if (mounted) setState(() {}); });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Center(
        child: _hasError
            ? const Text('Unable to play video',
                style: TextStyle(color: Colors.white54))
            : !_initialized
                ? const CircularProgressIndicator(
                    color: Color(0xFFD4AF37))
                : AspectRatio(
                    aspectRatio: _ctrl.value.aspectRatio,
                    child: VideoPlayer(_ctrl),
                  ),
      ),
      floatingActionButton: _initialized && !_hasError
          ? FloatingActionButton(
              heroTag: null,
              backgroundColor: const Color(0xFFD4AF37),
              foregroundColor: Colors.black,
              onPressed: () {
                _ctrl.value.isPlaying ? _ctrl.pause() : _ctrl.play();
              },
              child: Icon(
                  _ctrl.value.isPlaying ? Icons.pause : Icons.play_arrow),
            )
          : null,
    );
  }
}
