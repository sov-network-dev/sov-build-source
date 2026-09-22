// ─────────────────────────────────────────────────────────────────────────────
// MESSAGE ENGINE — SOV Speak end-to-end encrypted messaging
// ─────────────────────────────────────────────────────────────────────────────
// Handles all direct citizen-to-citizen messaging over the SOV network.
//
// What this engine does:
//   MESSAGE_SEND     → deliver immediately if recipient online, queue if offline
//   MESSAGE_READ     → forward read receipt to original sender (cross-node)
//   MESSAGE_REACT    → store emoji reaction, push update to both participants
//   MESSAGE_UNREACT  → remove reaction, push update
//   PUBLIC_KEY_QUERY → return a citizen's X25519 public key (for E2E encryption)
//   WATCH_ADD        → register watcher; fire CITIZEN_ONLINE if already online
//   WATCH_REMOVE     → deregister watcher
//
// Cross-node flow:
//   If recipient is on a different node, this engine forwards the message via
//   peer_mesh. The peer node delivers it directly. If the peer confirms delivery
//   (MESSAGE_DELIVERY_ACK), the sender gets MESSAGE_SEND_RESULT with status='delivered'.
//   If the peer says the recipient is offline, the message is stored in the peer's
//   pending queue — the peer owns the offline delivery responsibility.
//
// Offline delivery:
//   When a citizen reconnects after being offline, the gateway calls
//   engine.onCitizenReconnected(sovereignId, ws) and we flush their pending queue.
//
// E2E encryption:
//   Content is encrypted by the PHONE before sending. The node never sees
//   plaintext message content — only encrypted envelopes (v2 format) or
//   plain JSON for old app versions (v1 fallback).
//   The node stores/serves X25519 public keys to facilitate ECDH key exchange
//   between phones. The node cannot decrypt any message.
//
// Field name compatibility:
//   Flutter was originally built against the legacy relay, which used different
//   field names. This engine accepts BOTH sets of names:
//     Inbound (Flutter → Node):  message_id, to_sovereign_id, encrypted_payload,
//                                 message_type, sent_at
//     Outbound (Node → Flutter): message_id, from_sovereign_id, encrypted_payload,
//                                 message_type, sent_at
// ─────────────────────────────────────────────────────────────────────────────

'use strict';

const crypto = require('crypto');

// Op codes for message protocol
const MSG_OP = {
  MESSAGE_SEND:          'MS',
  MESSAGE_INCOMING:      'MI',
  MESSAGE_ACK:           'MA',
  MESSAGE_READ:          'MR',
  MESSAGE_READ_RECEIPT:  'RR',
  MESSAGE_REACT:         'MZ',  // Reaction (Z for zero-cost emoji layer)
  MESSAGE_UNREACT:       'MU',
  MESSAGE_REACTION_UPDATE: 'MQ',
  PUBLIC_KEY_QUERY:      'PK',
  PUBLIC_KEY_RESULT:     'KR',
  CITIZEN_ONLINE:        'CO',
  CITIZEN_OFFLINE:       'CF',
  WATCH_ADD:             'WA',
  WATCH_REMOVE:          'WX',
};

// Maximum time to wait for cross-node delivery ACK
const CROSS_NODE_ACK_TIMEOUT_MS = 5000;

// Maximum pending messages stored per offline citizen
const MAX_PENDING_PER_CITIZEN = 500;

class MessageEngine {

  constructor(identity, db, peerMesh) {
    this._identity  = identity;
    this._db        = db;
    this._peerMesh  = peerMesh;
    this._gateway   = null;

    // In-flight cross-node delivery: msg_id → { resolve, timer }
    this._deliveryWaiters = new Map();

    // Ensure message-specific tables exist
    this._initMessageTables();

    // Register peer mesh handlers
    peerMesh.on('MSG_FORWARD',              (msg) => this._handleMsgForward(msg));
    peerMesh.on('MSG_DELIVERY_ACK',         (msg) => this._handleDeliveryAck(msg));
    peerMesh.on('MSG_READ_FORWARD',         (msg) => this._handleReadForward(msg));
    peerMesh.on('MSG_REACTION_BROADCAST',   (msg) => this._handleReactionBroadcast(msg));
    peerMesh.on('CITIZEN_ONLINE_RELAY',     (msg) => this._handleCitizenOnlineRelay(msg));
    peerMesh.on('CITIZEN_OFFLINE_RELAY',    (msg) => this._handleCitizenOfflineRelay(msg));

    global.sovLog.info('      ✓ Message engine initialised');
  }

  setGateway(gateway) {
    this._gateway = gateway;
  }

  // ── Table initialisation ──────────────────────────────────────────────────

  _initMessageTables() {
    this._db._db.exec(`
      CREATE TABLE IF NOT EXISTS sov_message_reactions (
        reaction_id   TEXT PRIMARY KEY,
        message_id    TEXT NOT NULL,
        reactor_id    TEXT NOT NULL,
        emoji         TEXT NOT NULL,
        created_at    INTEGER NOT NULL,
        UNIQUE (message_id, reactor_id, emoji)
      );
      CREATE INDEX IF NOT EXISTS idx_react_msg ON sov_message_reactions(message_id);
    `);
  }

  // ── MESSAGE_SEND — main send handler ─────────────────────────────────────

  async handleMessageSend(ws, msg) {
    // Accept BOTH Flutter's field names and older internal names:
    //   Flutter sends: message_id, to_sovereign_id, encrypted_payload, message_type, sent_at
    //   Legacy names:  msg_id,     to_id,           content,           media_type,   timestamp
    const msg_id     = msg.msg_id     || msg.message_id;
    const to_id      = msg.to_id      || msg.to_sovereign_id;
    const content    = msg.content    || msg.encrypted_payload;
    const media_type = msg.media_type || msg.message_type;
    const timestamp  = msg.timestamp  || msg.sent_at;

    const from_id = ws._sovereignId;

    if (ws._legacyMode) { this._sendMsgSendResult(ws, msg_id, false, 'SIGNATURE_REQUIRED'); return; }

    // ── Validation ───────────────────────────────────────────────────────
    if (!msg_id || !to_id || content === undefined || content === null) {
      this._sendMsgSendResult(ws, msg_id, false, 'MISSING_FIELDS');
      return;
    }

    if (!/^[a-zA-Z0-9_\-]{8,64}$/.test(msg_id)) {
      this._sendMsgSendResult(ws, msg_id, false, 'INVALID_MSG_ID');
      return;
    }

    // Content size guard — max 256 KB (encrypted envelope + base64 overhead)
    const contentStr = typeof content === 'string' ? content : JSON.stringify(content);
    if (contentStr.length > 262144) {
      this._sendMsgSendResult(ws, msg_id, false, 'MESSAGE_TOO_LARGE');
      return;
    }

    // ── Store message metadata (not content) ─────────────────────────────
    this._db.storeMessageRecord({
      msg_id,
      from:       from_id,
      to:         to_id,
      media_type: media_type || 'text',
      created_at: timestamp  || Date.now(),
    });

    // ── Attempt delivery ─────────────────────────────────────────────────
    const delivered = await this._attemptDelivery(
      from_id, to_id, msg_id, contentStr, media_type, timestamp
    );

    // PURE P2P: the relay never stores offline messages. If the recipient is
    // offline, tell the sender RECIPIENT_OFFLINE so their device outbox holds the
    // message and retries when the recipient's presence broadcasts (CITIZEN_ONLINE
    // via WATCH_ADD / sov_watch_list). No server-side ciphertext is kept. The app
    // then shows the honest "Offline — will deliver" status, never a sent tick.
    if (delivered === 'offline') {
      this._sendMsgSendResult(ws, msg_id, false, 'RECIPIENT_OFFLINE', 'offline');
      return;
    }

    const status = (delivered === 'online' || delivered === 'cross_node_delivered')
      ? 'delivered' : 'forwarded';

    this._sendMsgSendResult(ws, msg_id, true, null, status);
  }

  // Helper: send MESSAGE_SEND_RESULT — the type Flutter's sendAndWait waits for.
  // Flutter reads responseType: 'MESSAGE_SEND_RESULT' and matchField: 'message_id'.
  _sendMsgSendResult(ws, msgId, success, error, status) {
    if (!ws || ws.readyState !== 1) return;
    const payload = {
      op:         MSG_OP.MESSAGE_ACK,
      type:       'MESSAGE_SEND_RESULT',  // Flutter sendAndWait responseType
      message_id: msgId,                  // Flutter matchField
      msg_id:     msgId,                  // backward compat
      success:    success !== false,
      status:     status || (success !== false ? 'delivered' : 'error'),
      ts:         Date.now(),
    };
    if (error) payload.error = error;
    ws.send(JSON.stringify(payload));
  }

  // ── Delivery logic ────────────────────────────────────────────────────────

  async _attemptDelivery(fromId, toId, msgId, contentStr, mediaType, timestamp) {
    // Check if recipient is online ON THIS NODE
    const conn = this._gateway && this._gateway.getConnection(toId);
    if (conn) {
      // Deliver directly — use Flutter's expected field names
      conn.send(JSON.stringify({
        op:                MSG_OP.MESSAGE_INCOMING,
        type:              'MESSAGE_INCOMING',
        message_id:        msgId,           // Flutter: msg['message_id']
        from_sovereign_id: fromId,          // Flutter: msg['from_sovereign_id']
        encrypted_payload: contentStr,      // Flutter: msg['encrypted_payload']
        message_type:      mediaType || 'text', // Flutter: msg['message_type']
        sent_at:           timestamp || Date.now(), // Flutter: msg['sent_at']
      }));
      return 'online';
    }

    // Check if recipient is on another node
    const presence = this._db.getCitizenPresence(toId);
    if (presence && presence.status === 'online' && presence.node_id !== this._identity.nodeId) {
      // Forward to their node
      const result = await this._forwardToNode(
        presence.node_id, fromId, toId, msgId, contentStr, mediaType, timestamp
      );
      if (result === 'delivered') return 'cross_node_delivered';
      // Forward sent but no ACK within timeout — message will be queued on remote
      return 'cross_node_forwarded';
    }

    // Recipient is offline. PURE P2P: do NOT store the message on the relay. The
    // sender's device outbox holds it and retries when the recipient comes online
    // (CITIZEN_ONLINE presence via WATCH_ADD / sov_watch_list). The relay keeps no
    // ciphertext for offline delivery — true peer-to-peer, no server message store.
    return 'offline';
  }

  async _forwardToNode(nodeId, fromId, toId, msgId, contentStr, mediaType, timestamp) {
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        this._deliveryWaiters.delete(msgId);
        resolve('timeout');
      }, CROSS_NODE_ACK_TIMEOUT_MS);

      this._deliveryWaiters.set(msgId, {
        resolve: (status) => {
          clearTimeout(timer);
          this._deliveryWaiters.delete(msgId);
          resolve(status);
        },
      });

      // Internal peer mesh uses internal field names (msg_id, from_id, etc.)
      // The receiving node's _handleMsgForward translates to Flutter field names on delivery
      this._peerMesh.broadcast('MSG_FORWARD', {
        msg_id,
        from_id:       fromId,
        to_id:         toId,
        content:       contentStr,
        media_type:    mediaType || 'text',
        ts:            timestamp  || Date.now(),
        origin_node:   this._identity.nodeId,
        target_node:   nodeId,
      });
    });
  }

  _queueMessage(sovereignId, payload) {
    // Enforce per-citizen queue cap
    const existing = this._db.getPendingMessages(sovereignId);
    if (existing.length >= MAX_PENDING_PER_CITIZEN) {
      // Drop oldest message to make room — FIFO
      this._db._db.prepare(
        'DELETE FROM sov_pending_messages WHERE sovereign_id = ? ORDER BY id ASC LIMIT 1'
      ).run(sovereignId);
    }
    this._db.queuePendingMessage(sovereignId, MSG_OP.MESSAGE_INCOMING, payload);
  }

  // ── MESSAGE_READ — mark message as read ───────────────────────────────────

  handleMessageRead(ws, msg) {
    // Flutter sends message_id (not msg_id)
    const msg_id    = msg.msg_id || msg.message_id;
    const reader_id = ws._sovereignId;

    if (!msg_id) return;

    const record = this._db.getMessageRecord(msg_id);
    if (!record) return;

    const sender_id = record.from_id;

    // If sender is online on this node — deliver read receipt directly
    const senderConn = this._gateway && this._gateway.getConnection(sender_id);
    if (senderConn) {
      this._sendDirect(senderConn, MSG_OP.MESSAGE_READ_RECEIPT, {
        message_id: msg_id,   // Flutter reads 'message_id'
        msg_id,               // backward compat
        reader_id,
        read_at:    Date.now(),
        ts:         Date.now(),
      });
      return;
    }

    // Sender is on another node — forward the read receipt via peer_mesh
    const senderPresence = this._db.getCitizenPresence(sender_id);
    if (senderPresence && senderPresence.status === 'online') {
      this._peerMesh.broadcast('MSG_READ_FORWARD', {
        msg_id,
        reader_id,
        sender_id,
        ts:         Date.now(),
        origin_node: this._identity.nodeId,
      });
    }
  }

  // ── MESSAGE_REACT / MESSAGE_UNREACT ───────────────────────────────────────

  handleReact(ws, msg) {
    // Flutter sends message_id (not msg_id)
    const msg_id    = msg.msg_id || msg.message_id;
    const emoji     = msg.emoji;
    const reactor_id = ws._sovereignId;

    if (ws._legacyMode) return;  // SIGNATURE_REQUIRED

    if (!msg_id || !emoji) return;

    // Validate emoji — only the 6 supported emoji
    const ALLOWED_EMOJI = ['👍', '❤️', '😂', '😮', '😢', '🔥'];
    if (!ALLOWED_EMOJI.includes(emoji)) return;

    // Store reaction (INSERT OR IGNORE prevents duplicate reactions)
    const reaction_id = `${msg_id}:${reactor_id}:${emoji}`;
    try {
      this._db._db.prepare(`
        INSERT OR IGNORE INTO sov_message_reactions
          (reaction_id, message_id, reactor_id, emoji, created_at)
        VALUES (?, ?, ?, ?, ?)
      `).run(reaction_id, msg_id, reactor_id, emoji, Date.now());
    } catch (_) {}

    this._broadcastReactionUpdate(msg_id, reactor_id);
  }

  handleUnreact(ws, msg) {
    const msg_id    = msg.msg_id || msg.message_id;
    const emoji     = msg.emoji;
    const reactor_id = ws._sovereignId;

    if (!msg_id || !emoji) return;

    const reaction_id = `${msg_id}:${reactor_id}:${emoji}`;
    this._db._db.prepare(
      'DELETE FROM sov_message_reactions WHERE reaction_id = ?'
    ).run(reaction_id);

    this._broadcastReactionUpdate(msg_id, reactor_id);
  }

  _broadcastReactionUpdate(msgId, changedBy) {
    const summary = this._getReactionSummary(msgId);
    const record  = this._db.getMessageRecord(msgId);

    // Flutter reads 'message_id' in _onReactionUpdate
    const payload = { message_id: msgId, msg_id: msgId, reactions: summary, ts: Date.now() };

    // Deliver to both conversation participants if online
    if (record) {
      const connA = this._gateway && this._gateway.getConnection(record.from_id);
      const connB = this._gateway && this._gateway.getConnection(record.to_id);
      if (connA) this._sendDirect(connA, MSG_OP.MESSAGE_REACTION_UPDATE, payload);
      if (connB) this._sendDirect(connB, MSG_OP.MESSAGE_REACTION_UPDATE, payload);
    }

    // Broadcast reaction to peer nodes for cross-node participants
    this._peerMesh.broadcast('MSG_REACTION_BROADCAST', {
      ...payload,
      from_id:     record ? record.from_id : '',
      to_id:       record ? record.to_id   : '',
      reactor_id:  changedBy,
      origin_node: this._identity.nodeId,
    });
  }

  _getReactionSummary(msgId) {
    const rows = this._db._db.prepare(
      'SELECT emoji, reactor_id FROM sov_message_reactions WHERE message_id = ?'
    ).all(msgId);

    const summary = {};
    for (const row of rows) {
      if (!summary[row.emoji]) summary[row.emoji] = [];
      summary[row.emoji].push(row.reactor_id);
    }
    return summary;
  }

  // ── PUBLIC_KEY_QUERY — X25519 key for E2E encryption ─────────────────────

  handlePublicKeyQuery(ws, msg) {
    const { target_id } = msg;
    if (!target_id) return;

    const key = this._db.getMessagingPublicKey(target_id);

    this._pushToSender(ws, MSG_OP.PUBLIC_KEY_RESULT, {
      target_id,
      x25519_public_key_hex: key || null,
      ts: Date.now(),
    });
  }

  // ── Citizen reconnect — flush offline queue ───────────────────────────────

  onCitizenReconnected(sovereignId, ws) {
    const pending = this._db.getPendingMessages(sovereignId);
    if (pending.length === 0) return;

    global.sovLog.debug(`      [MSG] Delivering ${pending.length} queued messages to ${sovereignId}`);

    for (const { op, payload } of pending) {
      if (ws.readyState === 1 /* WebSocket.OPEN */) {
        // Payload was stored using Flutter's expected field names (message_id,
        // from_sovereign_id, encrypted_payload, etc.) so we send as-is.
        ws.send(JSON.stringify({ op, type: 'MESSAGE_INCOMING', ...payload }));
      }
    }

    this._db.clearPendingMessagesExcept(sovereignId, ['SV']); // keep transfer notifs until client ACK (TX_HISTORY_CONFIRMED)

    // Notify watchers on this node that the citizen is back online
    const watchers = this._db.getWatchersFor(sovereignId);
    for (const watcherId of watchers) {
      const watcherConn = this._gateway && this._gateway.getConnection(watcherId);
      if (watcherConn) {
        this._sendDirect(watcherConn, MSG_OP.CITIZEN_ONLINE, { cid: sovereignId, ts: Date.now() });
      }
    }

    // Notify peer nodes
    this._peerMesh.broadcast('CITIZEN_ONLINE_RELAY', {
      sovereign_id: sovereignId,
      node_id:      this._identity.nodeId,
    });
  }

  // ── WATCH_ADD / WATCH_REMOVE ───────────────────────────────────────────────

  handleWatchAdd(ws, msg) {
    const { watching_id, watcher_sovereign_id } = msg;
    const watcherId = watcher_sovereign_id || ws._sovereignId;
    if (!watching_id || !watcherId) return;

    this._db.addWatch(watcherId, watching_id);

    // If the watched citizen is already online on this node — fire immediately
    const conn = this._gateway && this._gateway.getConnection(watching_id);
    if (conn) {
      this._pushToSender(ws, MSG_OP.CITIZEN_ONLINE, { cid: watching_id, ts: Date.now() });
    }
  }

  handleWatchRemove(ws, msg) {
    const { watching_id } = msg;
    const watcherId = ws._sovereignId;
    if (!watching_id || !watcherId) return;
    this._db.removeWatch(watcherId, watching_id);
  }

  // ── Peer mesh handlers ────────────────────────────────────────────────────

  // Another node is forwarding a message to one of our citizens.
  // Internal peer mesh uses {msg_id, from_id, content, media_type, ts}.
  // We translate to Flutter's expected field names on final delivery.
  _handleMsgForward(msg) {
    const { msg_id, from_id, to_id, content, media_type, ts, origin_node } = msg;
    if (!msg_id || !from_id || !to_id) return;

    // V44 fix: verify from_id is enrolled — prevents malicious peer mesh nodes from
    // impersonating any sovereign_id (including admins/high-value citizens) in forwarded messages
    const senderEnrolled = this._db._db.prepare('SELECT 1 FROM sov_enrollments WHERE sovereign_id = ?').get(from_id);
    if (!senderEnrolled) return;

    // Store message metadata
    this._db.storeMessageRecord({
      msg_id, from: from_id, to: to_id,
      media_type: media_type || 'text',
      created_at: ts || Date.now(),
    });

    // Attempt delivery using Flutter's expected field names
    const conn = this._gateway && this._gateway.getConnection(to_id);
    if (conn) {
      conn.send(JSON.stringify({
        op:                MSG_OP.MESSAGE_INCOMING,
        type:              'MESSAGE_INCOMING',
        message_id:        msg_id,           // Flutter: msg['message_id']
        from_sovereign_id: from_id,          // Flutter: msg['from_sovereign_id']
        encrypted_payload: content,          // Flutter: msg['encrypted_payload']
        message_type:      media_type || 'text', // Flutter: msg['message_type']
        sent_at:           ts || Date.now(), // Flutter: msg['sent_at']
      }));
      // ACK back to origin node
      this._peerMesh.broadcast('MSG_DELIVERY_ACK', {
        msg_id,
        status:      'delivered',
        origin_node,
        answering_node: this._identity.nodeId,
      });
    } else {
      // Citizen offline on this node — queue with Flutter's field names
      this._queueMessage(to_id, {
        message_id:        msg_id,
        from_sovereign_id: from_id,
        encrypted_payload: content,
        message_type:      media_type || 'text',
        sent_at:           ts || Date.now(),
      });
      this._peerMesh.broadcast('MSG_DELIVERY_ACK', {
        msg_id,
        status:      'queued',
        origin_node,
        answering_node: this._identity.nodeId,
      });
    }
  }

  // Origin node gets back a delivery ACK for a forwarded message
  _handleDeliveryAck(msg) {
    const { msg_id, status } = msg;
    const waiter = this._deliveryWaiters.get(msg_id);
    if (waiter) waiter.resolve(status);
  }

  // A read receipt was forwarded from another node
  _handleReadForward(msg) {
    const { msg_id, reader_id, sender_id, ts } = msg;
    const conn = this._gateway && this._gateway.getConnection(sender_id);
    if (conn) {
      this._sendDirect(conn, MSG_OP.MESSAGE_READ_RECEIPT, {
        message_id: msg_id,
        msg_id,
        reader_id,
        read_at:    ts,
        ts,
      });
    }
  }

  // Reaction update from another node
  _handleReactionBroadcast(msg) {
    const { msg_id, message_id, reactions, from_id, to_id, origin_node } = msg;
    const actualMsgId = message_id || msg_id;

    // Don't re-process our own broadcasts
    if (origin_node === this._identity.nodeId) return;

    // Deliver reaction update to any online participant
    const payload = { message_id: actualMsgId, msg_id: actualMsgId, reactions, ts: Date.now() };
    const connA   = this._gateway && from_id && this._gateway.getConnection(from_id);
    const connB   = this._gateway && to_id   && this._gateway.getConnection(to_id);
    if (connA) this._sendDirect(connA, MSG_OP.MESSAGE_REACTION_UPDATE, payload);
    if (connB) this._sendDirect(connB, MSG_OP.MESSAGE_REACTION_UPDATE, payload);
  }

  // A citizen came online on another node — notify their watchers here
  _handleCitizenOnlineRelay(msg) {
    const { sovereign_id } = msg;
    if (!sovereign_id) return;

    // Find watchers on THIS node who are watching this citizen
    const watchers = this._db.getWatchersFor(sovereign_id);
    for (const watcherId of watchers) {
      const conn = this._gateway && this._gateway.getConnection(watcherId);
      if (conn) {
        this._sendDirect(conn, MSG_OP.CITIZEN_ONLINE, { cid: sovereign_id, ts: Date.now() });
      }
    }
  }

  // A citizen went offline on another node — notify their watchers here
  _handleCitizenOfflineRelay(msg) {
    const { sovereign_id } = msg;
    if (!sovereign_id) return;

    const watchers = this._db.getWatchersFor(sovereign_id);
    for (const watcherId of watchers) {
      const conn = this._gateway && this._gateway.getConnection(watcherId);
      if (conn) {
        this._sendDirect(conn, MSG_OP.CITIZEN_OFFLINE, { cid: sovereign_id, ts: Date.now() });
      }
    }
  }

  // ── Send helpers ──────────────────────────────────────────────────────────

  _pushToSender(ws, op, payload) {
    if (!ws || ws.readyState !== 1) return;
    const type = MessageEngine._MSG_TYPE_NAME[op] || payload.type || op;
    ws.send(JSON.stringify({ op, type, ...payload }));
  }

  _sendDirect(ws, op, payload) {
    if (!ws || ws.readyState !== 1) return;
    const type = MessageEngine._MSG_TYPE_NAME[op] || payload.type || op;
    ws.send(JSON.stringify({ op, type, ...payload }));
  }

  // Static reverse-lookup: op code → Flutter-expected message type string.
  // Used by _sendDirect and _pushToSender so every outbound message carries
  // both 'op' (2-char wire code) and 'type' (Flutter sendAndWait match key).
  static get _MSG_TYPE_NAME() {
    return {
      'RR': 'MESSAGE_READ_RECEIPT',
      'MQ': 'MESSAGE_REACTION_UPDATE',
      'KR': 'PUBLIC_KEY_RESULT',
      'CO': 'CITIZEN_ONLINE',
      'CF': 'CITIZEN_OFFLINE',
    };
  }
}

module.exports = { MessageEngine, MSG_OP };
