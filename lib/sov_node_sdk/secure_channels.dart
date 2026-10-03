// lib/sov_node_sdk/secure_channels.dart
// ─────────────────────────────────────────────────────────────────────────────
// Group chat and exchange trade chat — end-to-end encrypted, kept ONLY on devices.
//
// The rule (king, 2026-10-03): a SOV node never stores a message. Before 1.2.17 /
// node 1.4.81 group chat went out in PLAIN TEXT under a '*' envelope and every node
// kept it 90 days; trade chat went out in plain text and was stored and replicated.
//
// Now, for both:
//   • the SENDING device encrypts one v2 envelope per recipient (X25519 + HKDF +
//     AES-256-GCM — the same MessageEncryptor as direct messages);
//   • the node hands it to recipients who are connected and says who was not;
//   • the sender's device keeps the rest in its outbox and retries when they come
//     online (OutboxManager, channel 'grp:<id>' / 'xchg:<order>');
//   • history, unread counts and the seller's negotiation inbox are built from this
//     device's own copies (ContactsDb), never fetched from a node.
// A recipient who joins a group later does not see earlier messages — there is
// nowhere they could come from.
// ─────────────────────────────────────────────────────────────────────────────
import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'contacts_db.dart';
import 'message_encryptor.dart';
import 'message_key_manager.dart';
import 'outbox_manager.dart';
import 'relay_connector.dart';

class SecureChannels {
  SecureChannels._();

  // Fires a conversation id ('grp_<group>' or 'xchg_<order>_<buyer>') when it changes.
  static final _changes = StreamController<String>.broadcast();
  static Stream<String> get changes => _changes.stream;

  static String groupConv(String groupId) => 'grp_$groupId';
  static String tradeConv(String orderId, String buyerId) => 'xchg_${orderId}_$buyerId';

  static StreamSubscription? _grpSub, _xSub;

  /// Start keeping incoming group and trade messages on this device. Idempotent;
  /// called once from the app shell, so a message is kept even when its screen is
  /// not open (the node will not hold it for later).
  static void start() {
    _grpSub ??= RelayConnector.groupMessageStream.listen((m) => receiveGroup(m));
    _xSub   ??= RelayConnector.exchangeChatStream.listen((m) => receiveTrade(m));
  }

  static Future<String> _me() async =>
      (await SharedPreferences.getInstance()).getString('sovereign_id') ?? '';

  static String _newId(String prefix) {
    final r = Random.secure();
    final hex = List.generate(6, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    return '$prefix-${DateTime.now().millisecondsSinceEpoch}-$hex';
  }

  static Future<String?> _encryptFor(String recipient, String text) async {
    final key  = await RelayConnector.lookupMessagingKey(recipient);
    final priv = await MessageKeyManager.getPrivateKeyBytes();
    if (key == null || key.isEmpty || priv == null) return null;
    return MessageEncryptor.encrypt(plaintext: text, recipientPubKeyHex: key, myPrivKeyBytes: priv);
  }

  static Future<String?> _decryptFrom(String sender, String envelope) async {
    if (!MessageEncryptor.isEncryptedEnvelope(envelope)) return null;   // never show plain text
    final key  = await RelayConnector.lookupMessagingKey(sender);
    final priv = await MessageKeyManager.getPrivateKeyBytes();
    if (key == null || key.isEmpty || priv == null) return null;
    return MessageEncryptor.decryptEnvelope(envelope: envelope, senderPubKeyHex: key, myPrivKeyBytes: priv);
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  GROUP CHAT
  // ══════════════════════════════════════════════════════════════════════════

  /// Members of [groupId] (from the node's group record — routing data, not content).
  static Future<List<String>> groupMembers(String groupId, String me) async {
    final groups = await RelayConnector.listGroups(me);
    for (final g in groups) {
      if (g['group_id'] == groupId) {
        return List<String>.from((g['members'] as List?) ?? const []);
      }
    }
    return const [];
  }

  /// Encrypt [text] for every other member and send it. Returns the stored message,
  /// whose status is 'delivered', 'partial' (some kept for retry), 'queued' (nobody
  /// reachable yet — all kept) or 'failed' (the node refused; see [lastError]).
  static String lastError = '';
  static Future<LocalMessage> sendGroup({required String groupId, required String text}) async {
    final me = await _me();
    final msgId = _newId('GM');
    final now = DateTime.now().millisecondsSinceEpoch;
    final members = (await groupMembers(groupId, me)).where((m) => m != me).toList();

    final envelopes = <String, String>{};
    final noKey = <String>[];
    for (final m in members) {
      final env = await _encryptFor(m, text);
      env == null ? noKey.add(m) : envelopes[m] = env;
    }

    var local = LocalMessage(
      id: msgId, conversationId: groupConv(groupId), fromSovereignId: me, toSovereignId: groupId,
      contentType: 'text', encryptedContent: '', decryptedContent: text, status: 'sending', sentAt: now);
    await ContactsDb.saveChannelMessage(local);
    _changes.add(groupConv(groupId));

    final keep = <String>{...noKey};
    var status = 'queued';
    lastError = '';
    if (envelopes.isNotEmpty) {
      final r = await RelayConnector.sendGroupMessage(msgId: msgId, groupId: groupId, envelopes: envelopes);
      if (r != null && r['status'] == 'error') {
        lastError = (r['error'] ?? 'Send failed').toString();
        status = 'failed';
      } else if (r == null) {
        keep.addAll(envelopes.keys);                              // no answer: keep them all
      } else {
        keep.addAll(List<String>.from(r['offline'] ?? const []));
        keep.addAll(List<String>.from(r['no_envelope'] ?? const []));
        final delivered = List<String>.from(r['delivered'] ?? const []);
        status = keep.isEmpty ? 'delivered' : (delivered.isNotEmpty ? 'partial' : 'queued');
      }
    }
    if (status != 'failed') {
      for (final m in keep) {
        final env = envelopes[m];
        if (env != null) {
          await OutboxManager.queueChannel(
            outboxId: '$msgId@$m', toSovereignId: m, encryptedContent: env, channel: 'grp:$groupId');
        } else {
          await OutboxManager.queueChannelAwaitingKey(
            outboxId: '$msgId@$m', toSovereignId: m, plaintext: text, channel: 'grp:$groupId');
        }
      }
    }
    local = LocalMessage(
      id: msgId, conversationId: groupConv(groupId), fromSovereignId: me, toSovereignId: groupId,
      contentType: 'text', encryptedContent: '', decryptedContent: text, status: status, sentAt: now);
    await ContactsDb.saveChannelMessage(local);
    _changes.add(groupConv(groupId));
    return local;
  }

  static Future<void> receiveGroup(Map<String, dynamic> msg) async {
    try {
      final groupId = msg['group_id'] as String? ?? '';
      final sender  = msg['sender_id'] as String? ?? '';
      final msgId   = msg['msg_id'] as String? ?? '';
      final content = msg['content'] as String? ?? '';
      if (groupId.isEmpty || sender.isEmpty || msgId.isEmpty) return;
      if (!MessageEncryptor.isEncryptedEnvelope(content)) return;   // plain text is never accepted
      if (await ContactsDb.isContactBlocked(sender)) return;
      final me = await _me();
      final text = await _decryptFrom(sender, content);
      await ContactsDb.saveChannelMessage(LocalMessage(
        id: msgId, conversationId: groupConv(groupId), fromSovereignId: sender, toSovereignId: me,
        contentType: (msg['media_type'] as String?) ?? 'text', encryptedContent: content,
        decryptedContent: text, status: 'delivered',
        sentAt: (msg['ts'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch,
        deliveredAt: DateTime.now().millisecondsSinceEpoch));
      _changes.add(groupConv(groupId));
    } catch (e) {
      debugPrint('[CHANNELS] group receive: $e');
    }
  }

  /// This device's copy of the group's messages, oldest first. Messages that arrived
  /// before their sender's key was known are decrypted now if possible.
  static Future<List<LocalMessage>> groupHistory(String groupId) =>
      _history(groupConv(groupId));

  // ══════════════════════════════════════════════════════════════════════════
  //  EXCHANGE TRADE CHAT
  // ══════════════════════════════════════════════════════════════════════════

  /// Send [text] in the (order, buyer) thread to [toId]. [buyerId] is the non-seller
  /// party (the thread key). Same status values as [sendGroup].
  static Future<LocalMessage> sendTrade({
    required String orderId, required String toId, required String buyerId, required String text,
  }) async {
    final me = await _me();
    final msgId = _newId('XC');
    final now = DateTime.now().millisecondsSinceEpoch;
    final conv = tradeConv(orderId, buyerId);
    LocalMessage mk(String status, String env) => LocalMessage(
      id: msgId, conversationId: conv, fromSovereignId: me, toSovereignId: toId, contentType: 'text',
      encryptedContent: env, decryptedContent: text, status: status, sentAt: now);

    await ContactsDb.saveChannelMessage(mk('sending', ''));
    _changes.add(conv);
    lastError = '';

    final env = await _encryptFor(toId, text);
    if (env == null) {
      await OutboxManager.queueChannelAwaitingKey(
        outboxId: '$msgId@$toId', toSovereignId: toId, plaintext: text, channel: 'xchg:$orderId');
      final m = mk('queued', '');
      await ContactsDb.saveChannelMessage(m);
      _changes.add(conv);
      return m;
    }
    final r = await RelayConnector.sendExchangeChatMessage(
      orderId: orderId, fromId: me, toId: toId, content: env, msgId: msgId);
    String status;
    if (r['success'] == true && r['status'] == 'delivered') {
      status = 'delivered';
    } else if (r['success'] == true || r['error'] == 'No response from relay') {
      status = 'queued';
      await OutboxManager.queueChannel(
        outboxId: '$msgId@$toId', toSovereignId: toId, encryptedContent: env, channel: 'xchg:$orderId');
    } else {
      status = 'failed';
      lastError = (r['error'] ?? 'Send failed').toString();
    }
    final m = mk(status, env);
    await ContactsDb.saveChannelMessage(m);
    _changes.add(conv);
    return m;
  }

  static Future<void> receiveTrade(Map<String, dynamic> msg) async {
    try {
      final orderId = msg['order_id'] as String? ?? '';
      final from    = msg['from_id'] as String? ?? '';
      final msgId   = msg['msg_id'] as String? ?? '';
      final content = msg['content'] as String? ?? '';
      if (orderId.isEmpty || from.isEmpty || msgId.isEmpty) return;
      if (!MessageEncryptor.isEncryptedEnvelope(content)) return;   // plain text is never accepted
      if (await ContactsDb.isContactBlocked(from)) return;
      final me = await _me();
      final buyer = (msg['buyer_id'] as String?)?.isNotEmpty == true ? msg['buyer_id'] as String : from;
      final text = await _decryptFrom(from, content);
      await ContactsDb.saveChannelMessage(LocalMessage(
        id: msgId, conversationId: tradeConv(orderId, buyer), fromSovereignId: from, toSovereignId: me,
        contentType: 'text', encryptedContent: content, decryptedContent: text, status: 'delivered',
        sentAt: (msg['ts'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch,
        deliveredAt: DateTime.now().millisecondsSinceEpoch));
      _changes.add(tradeConv(orderId, buyer));
    } catch (e) {
      debugPrint('[CHANNELS] trade receive: $e');
    }
  }

  /// This device's copy of one (order, buyer) thread, oldest first.
  static Future<List<LocalMessage>> tradeThread(String orderId, String buyerId) =>
      _history(tradeConv(orderId, buyerId));

  /// Mark the thread's incoming messages read (drives the unread badges).
  static Future<void> markTradeRead(String orderId, String buyerId) async {
    final me = await _me();
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final m in await ContactsDb.getMessages(tradeConv(orderId, buyerId))) {
      if (m.fromSovereignId != me && m.readAt == null) {
        await ContactsDb.updateMessageStatus(m.id, 'read', readAt: now);
      }
    }
  }

  /// The seller's negotiation inbox for [orderId], built from this device: one row per
  /// buyer with the last message, its time, the count, and how many are unread.
  static Future<List<Map<String, dynamic>>> tradeThreads(String orderId) async {
    final me = await _me();
    final prefix = 'xchg_${orderId}_';
    final byBuyer = <String, List<LocalMessage>>{};
    for (final m in await ContactsDb.getMessagesWithPrefix(prefix)) {
      byBuyer.putIfAbsent(m.conversationId.substring(prefix.length), () => []).add(m);
    }
    final rows = byBuyer.entries.map((e) {
      final msgs = e.value;
      final last = msgs.last;
      return <String, dynamic>{
        'buyer_id': e.key,
        'message_count': msgs.length,
        'last_ts': last.sentAt,
        'unread': msgs.where((m) => m.fromSovereignId != me && m.readAt == null).length,
        'last_content': last.decryptedContent ?? '[encrypted]',
        'last_from_me': last.fromSovereignId == me,
      };
    }).toList()
      ..sort((a, b) => (b['last_ts'] as int).compareTo(a['last_ts'] as int));
    return rows;
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  shared
  // ══════════════════════════════════════════════════════════════════════════

  static Future<List<LocalMessage>> _history(String conv) async {
    final msgs = await ContactsDb.getMessages(conv);
    for (var i = 0; i < msgs.length; i++) {
      final m = msgs[i];
      if (m.decryptedContent == null && MessageEncryptor.isEncryptedEnvelope(m.encryptedContent)) {
        final t = await _decryptFrom(m.fromSovereignId, m.encryptedContent);
        if (t != null) {
          await ContactsDb.updateMessageDecrypted(m.id, t);
          m.decryptedContent = t;
        }
      }
    }
    return msgs;
  }

  /// Called by OutboxManager for a queued 'grp:' / 'xchg:' item. Returns true when the
  /// recipient now has it. [payload] is the envelope (already encrypted to them).
  static Future<bool> resend(Map<String, dynamic> row, String payload) async {
    final channel = row['channel'] as String? ?? '';
    final to = row['to_sovereign_id'] as String;
    final outboxId = row['id'] as String;
    final msgId = outboxId.contains('@') ? outboxId.substring(0, outboxId.lastIndexOf('@')) : outboxId;
    if (channel.startsWith('grp:')) {
      final r = await RelayConnector.sendGroupMessage(
          msgId: msgId, groupId: channel.substring(4), envelopes: {to: payload});
      return r != null && List<String>.from(r['delivered'] ?? const []).contains(to);
    }
    if (channel.startsWith('xchg:')) {
      final me = await _me();
      final r = await RelayConnector.sendExchangeChatMessage(
          orderId: channel.substring(5), fromId: me, toId: to, content: payload, msgId: msgId);
      return r['success'] == true && r['status'] == 'delivered';
    }
    return false;
  }
}
