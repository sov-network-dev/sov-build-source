// lib/sov_node_sdk/outbox_manager.dart
// ─────────────────────────────────────────────────────────────────────────────
// Manages the local message outbox for offline recipients.
//
// When a MESSAGE_SEND returns RECIPIENT_OFFLINE:
//   1. Message is stored in ContactsDb.outbox (never on relay)
//   2. WATCH_ADD is sent to the relay — relay watches for the recipient
//   3. When relay sends CITIZEN_ONLINE, we retry the outbox
//   4. On delivery, WATCH_REMOVE cleans up the relay watch entry
//
// The relay stores ONLY a watch-list entry (which sovereign_id to watch for,
// and which relay to notify). No message content ever touches the relay.
// ─────────────────────────────────────────────────────────────────────────────
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'contacts_db.dart';
import 'relay_connector.dart';
import 'message_encryptor.dart';
import 'message_key_manager.dart';

class OutboxManager {
  static final Set<String> _watchedRecipients = {};

  // Stream that fires with a sovereignId whenever they come online.
  // SovLinkScreen listens to this to auto-retry outbox and refresh status.
  static final _onlineController =
      StreamController<String>.broadcast();
  static Stream<String> get citizenOnlineStream =>
      _onlineController.stream;

  // ── Called by RelayConnector when CITIZEN_ONLINE arrives ──────────────────

  static Future<void> onCitizenOnline(String sovereignId) async {
    debugPrint('[OUTBOX] $sovereignId came online — retrying outbox…');
    _watchedRecipients.remove(sovereignId);
    _onlineController.add(sovereignId);

    final queued =
        await ContactsDb.getOutboxForRecipient(sovereignId);
    for (final msg in queued) {
      await _retryMessage(msg);
    }
  }

  // Prefix used when a message was queued before the recipient had a key.
  // The content after the prefix is the plaintext to be encrypted at send time.
  static const _awaitingKeyPrefix = '__AWAITING_KEY__:';

  static Future<void> _retryMessage(
      Map<String, dynamic> msg) async {
    try {
      if (!RelayConnector.isConnected) await RelayConnector.connect();

      final toId     = msg['to_sovereign_id'] as String;
      String payload = msg['encrypted_content'] as String? ?? '';

      // Message was queued before recipient had an E2E key — try to encrypt now.
      if (payload.startsWith(_awaitingKeyPrefix)) {
        final plaintext   = payload.substring(_awaitingKeyPrefix.length);
        final recipientKey = await RelayConnector.lookupMessagingKey(toId);
        if (recipientKey == null || recipientKey.isEmpty) {
          // Still no key — re-watch and wait another cycle
          await _addWatch(toId);
          return;
        }
        final myPrivBytes = await MessageKeyManager.getPrivateKeyBytes();
        if (myPrivBytes == null) return;
        final encrypted = await MessageEncryptor.encrypt(
          plaintext: plaintext, recipientPubKeyHex: recipientKey,
          myPrivKeyBytes: myPrivBytes,
        );
        if (encrypted == null) return;
        payload = encrypted;
        // Persist the now-encrypted content so future retries don't need plaintext
        await ContactsDb.updateOutboxContent(msg['id'] as String, payload);
        // Clean up plaintext from SharedPrefs if we stored it there as a safety copy
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('pending_pt_${msg["id"]}');
      }

      final result = await RelayConnector.sendAndWait(
        request: {
          'type':              'MESSAGE_SEND',
          'to_sovereign_id':   toId,
          'encrypted_payload': payload,
          'message_type':      msg['content_type'],
          'message_id':        msg['id'],
        },
        responseType: 'MESSAGE_SEND_RESULT',
        timeout: const Duration(seconds: 10),
        matchField: 'message_id',
        matchValue: msg['id'] as String,
      );

      if (result?['success'] == true) {
        final now = DateTime.now().millisecondsSinceEpoch;
        await ContactsDb.markOutboxDelivered(msg['id'] as String);
        await ContactsDb.updateMessageStatus(
          msg['id'] as String,
          'delivered',
          deliveredAt: now,
        );
        // Remove relay watch now delivered
        RelayConnector.sendRaw({
          'type':                 'WATCH_REMOVE',
          'watching_sovereign_id': msg['to_sovereign_id'],
        });
        // Re-emit the online event so SovLinkScreen._onCitizenOnline triggers
        // _loadThread() AFTER the status is updated in the DB.  Without this the
        // thread reload that fired at the start of onCitizenOnline reads the old
        // 'offline' status because the retry hadn't completed yet.
        _onlineController.add(msg['to_sovereign_id'] as String);
        debugPrint('[OUTBOX] Delivered ${msg["id"]}');
      } else {
        // Still offline — re-watch
        await _addWatch(msg['to_sovereign_id'] as String);
      }
    } catch (e) {
      debugPrint('[OUTBOX] Retry error: $e');
    }
  }

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Queue a message locally and ask the relay to watch for the recipient.
  /// Queue a message when the recipient has no E2E key yet.
  /// Stores plaintext with a prefix marker; encrypts + sends on CITIZEN_ONLINE
  /// once the recipient has registered their key by opening the app.
  static Future<void> queueAwaitingKey({
    required String messageId,
    required String toSovereignId,
    required String plaintext,
    required String contentType,
  }) async {
    await ContactsDb.addToOutbox(
      messageId:        messageId,
      toSovereignId:    toSovereignId,
      encryptedContent: '$_awaitingKeyPrefix$plaintext',
      contentType:      contentType,
    );
    await _addWatch(toSovereignId);
    debugPrint('[OUTBOX] Queued $messageId awaiting E2E key from $toSovereignId');
  }

  /// Queue a message locally and ask the relay to watch for the recipient.
  static Future<void> queueMessage({
    required String messageId,
    required String toSovereignId,
    required String encryptedContent,
    required String contentType,
  }) async {
    await ContactsDb.addToOutbox(
      messageId:        messageId,
      toSovereignId:    toSovereignId,
      encryptedContent: encryptedContent,
      contentType:      contentType,
    );
    await _addWatch(toSovereignId);
    debugPrint('[OUTBOX] Queued $messageId for $toSovereignId');
  }

  static Future<void> _addWatch(String sovereignId) async {
    if (_watchedRecipients.contains(sovereignId)) return;
    _watchedRecipients.add(sovereignId);
    try {
      if (!RelayConnector.isConnected) await RelayConnector.connect();
      // Include our own sovereign_id in the payload so the relay can persist it
      // as watcher_sovereign_id even if ws._sovereignId is not yet set (race
      // between onConnected firing and relay processing the HELLO message).
      // Without this the watch entry is stored with NULL watcher and the
      // DB-backed CITIZEN_ONLINE query never matches it.
      final prefs   = await SharedPreferences.getInstance();
      final mySovId = prefs.getString('sovereign_id') ?? '';
      RelayConnector.sendRaw({
        'type':                  'WATCH_ADD',
        'watching_sovereign_id': sovereignId,
        if (mySovId.isNotEmpty) 'watcher_sovereign_id': mySovId,
      });
    } catch (e) {
      debugPrint('[OUTBOX] Watch add error: $e');
    }
  }

  /// Retry all pending outbox messages on reconnect.
  static Future<void> retryAll() async {
    final all = await ContactsDb.getAllOutboxQueued();
    final byRecipient = <String, List<Map<String, dynamic>>>{};
    for (final msg in all) {
      final to = msg['to_sovereign_id'] as String;
      byRecipient.putIfAbsent(to, () => []).add(msg);
    }
    for (final entry in byRecipient.entries) {
      await _addWatch(entry.key);
    }
  }

  static void dispose() {
    _watchedRecipients.clear();
    // Don't close the broadcast controller — it's a static singleton
  }
}
