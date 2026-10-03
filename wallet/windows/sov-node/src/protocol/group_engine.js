// ─────────────────────────────────────────────────────────────────────────────
// GROUP ENGINE — SOV Speak multi-citizen encrypted channels
// ─────────────────────────────────────────────────────────────────────────────
// Handles group conversations: creation, membership, cross-node message routing.
//
// A node keeps the group RECORD (name, members) so it can route. It NEVER keeps a
// message: no history, no offline queue (king, 2026-10-03 - "the node does not store
// messages"; it is the end-to-end guarantee). Before 1.4.81 every node stored each
// message for 90 days and queued copies for offline members, and the app sent it in
// PLAIN TEXT under a '*' envelope.
//
// Message delivery:
//   GROUP_SEND carries one v2 envelope PER MEMBER (encrypted by the sending phone to
//   that member's key). The node hands each member theirs if they are connected here,
//   forwards to the node their presence names (and waits for its answer), and tells
//   the sender who was delivered and who was not. The SENDER's device keeps the
//   undelivered envelopes and retries when those members come online - exactly as
//   for direct messages.
//
// Cross-node membership:
//   GROUP_MEMBERSHIP_BROADCAST ensures all nodes know who is in the group so they
//   can deliver messages to their connected members.
//
// E2E encryption:
//   Each message is encrypted per-recipient by the SENDING PHONE before transit,
//   with that member's X25519 key (PUBLIC_KEY_QUERY). The node REFUSES anything else:
//   a '*' (everyone-gets-the-same-text) envelope or a non-v2 envelope is answered
//   GROUP_PLAINTEXT_REFUSED. The node sees only { recipient_id -> opaque envelope }.
// ─────────────────────────────────────────────────────────────────────────────

'use strict';

const crypto = require('crypto');

const GROUP_OP = {
  GROUP_CREATE:          'GC',
  GROUP_CREATED:         'GD',
  GROUP_SEND:            'GS',
  GROUP_MESSAGE_INCOMING:'GM',
  GROUP_LIST:            'GL',
  GROUP_LIST_RESULT:     'GR',
  GROUP_HISTORY:         'GH',
  GROUP_HISTORY_RESULT:  'GI',
  GROUP_ADD_MEMBER:      'GA',
  GROUP_LEAVE:           'GV',
  GROUP_INVITE:          'GN',
  GROUP_UPDATE:          'GU',  // membership change notification
};

// Governance param keys
const PARAM_GROUP_MAX_MEMBERS = 'group_max_members';

const DEFAULT_MAX_MEMBERS     = 50;

// How long the sender's node waits for another node to say it delivered.
const GROUP_FORWARD_ACK_MS = 5000;

// A v2 envelope as MessageEncryptor writes it: {"v":2,"nonce":hex,"ct":hex}.
function isV2Envelope(env) {
  if (typeof env !== 'string' || env.length > 262144) return false;
  try { const o = JSON.parse(env); return !!o && o.v === 2 && typeof o.nonce === 'string' && typeof o.ct === 'string'; }
  catch (_) { return false; }
}

class GroupEngine {

  constructor(identity, db, peerMesh) {
    this._identity = identity;
    this._db       = db;
    this._peerMesh = peerMesh;
    this._gateway  = null;

    this._initGroupTables();

    // Register peer mesh handlers
    peerMesh.on('GROUP_MSG_FORWARD',         (msg) => this._handleGroupMsgForward(msg));
    peerMesh.on('GROUP_DELIVERY_ACK',        (msg) => this._handleGroupDeliveryAck(msg));
    this._groupWaiters = new Map();   // `${msg_id}|${node_id}` -> resolve(delivered[])
    peerMesh.on('GROUP_MEMBERSHIP_BROADCAST',(msg) => this._handleMembershipBroadcast(msg));
    peerMesh.on('GROUP_INVITE_FORWARD',      (msg) => this._handleInviteForward(msg));
    peerMesh.on('GROUP_LEAVE_BROADCAST',     (msg) => this._handleLeaveBroadcast(msg));

    global.sovLog.info('      ✓ Group engine initialised');
  }

  setGateway(gateway) {
    this._gateway = gateway;
  }

  // ── Table initialisation ──────────────────────────────────────────────────

  _initGroupTables() {
    this._db._db.exec(`
      CREATE TABLE IF NOT EXISTS sov_groups (
        group_id      TEXT PRIMARY KEY,
        name          TEXT NOT NULL,
        created_by    TEXT NOT NULL,
        created_at    INTEGER NOT NULL,
        member_count  INTEGER NOT NULL DEFAULT 1
      );

      CREATE TABLE IF NOT EXISTS sov_group_members (
        group_id      TEXT NOT NULL,
        member_id     TEXT NOT NULL,
        joined_at     INTEGER NOT NULL,
        role          TEXT NOT NULL DEFAULT 'member',   -- 'admin' | 'member'
        PRIMARY KEY (group_id, member_id)
      );
      CREATE INDEX IF NOT EXISTS idx_grp_member ON sov_group_members(member_id);

      CREATE TABLE IF NOT EXISTS sov_group_messages (
        msg_id        TEXT PRIMARY KEY,
        group_id      TEXT NOT NULL,
        sender_id     TEXT NOT NULL,
        envelopes     TEXT NOT NULL,   -- JSON: { recipient_id: encrypted_envelope }
        media_type    TEXT NOT NULL DEFAULT 'text',
        created_at    INTEGER NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_grp_msg ON sov_group_messages(group_id, created_at);
    `);

    // The node does not store messages. Clear anything an earlier version kept: group
    // history, and queued direct/group messages and invites ('MI', 'GM', 'GN').
    try {
      const h = this._db._db.prepare('DELETE FROM sov_group_messages').run().changes;
      const q = this._db._db.prepare("DELETE FROM sov_pending_messages WHERE op IN ('MI','GM','GN')").run().changes;
      if (h || q) global.sovLog.info(`      Group engine: removed ${h} stored group message(s) and ${q} queued message(s) - nodes keep no messages`);
    } catch (_) {}

    // Seed governance defaults for group params
    const db = this._db;
    if (!db.getGovParam(PARAM_GROUP_MAX_MEMBERS)) {
      db.setGovParam(PARAM_GROUP_MAX_MEMBERS, String(DEFAULT_MAX_MEMBERS));
    }
  }

  // ── GROUP_CREATE ──────────────────────────────────────────────────────────

  handleGroupCreate(ws, msg) {
    const { group_id, name, member_ids } = msg;
    const creator_id = ws._sovereignId;

    if (ws._legacyMode) { this._send(ws, GROUP_OP.GROUP_CREATED, { success: false, error: 'SIGNATURE_REQUIRED' }); return; }

    if (!group_id || !name || !Array.isArray(member_ids)) {
      this._send(ws, GROUP_OP.GROUP_CREATED, {
        success: false, error: 'MISSING_FIELDS',
      });
      return;
    }

    if (!/^[a-zA-Z0-9_\-]{8,64}$/.test(group_id)) {
      this._send(ws, GROUP_OP.GROUP_CREATED, {
        success: false, error: 'INVALID_GROUP_ID',
      });
      return;
    }

    const maxMembers = parseInt(
      this._db.getGovParam(PARAM_GROUP_MAX_MEMBERS) || String(DEFAULT_MAX_MEMBERS)
    );

    // Deduplicate and enforce max
    const allMembers = [...new Set([creator_id, ...member_ids])].slice(0, maxMembers);

    // Check if group already exists
    const existing = this._db._db.prepare(
      'SELECT group_id FROM sov_groups WHERE group_id = ?'
    ).get(group_id);
    if (existing) {
      this._send(ws, GROUP_OP.GROUP_CREATED, {
        success: false, error: 'GROUP_ALREADY_EXISTS',
      });
      return;
    }

    const now = Date.now();

    // Create group + membership in a transaction
    const createGroup = this._db._db.transaction(() => {
      this._db._db.prepare(`
        INSERT INTO sov_groups (group_id, name, created_by, created_at, member_count)
        VALUES (?, ?, ?, ?, ?)
      `).run(group_id, name.slice(0, 64), creator_id, now, allMembers.length);

      const insertMember = this._db._db.prepare(`
        INSERT OR IGNORE INTO sov_group_members (group_id, member_id, joined_at, role)
        VALUES (?, ?, ?, ?)
      `);
      for (const memberId of allMembers) {
        insertMember.run(group_id, memberId, now, memberId === creator_id ? 'admin' : 'member');
      }
    });
    createGroup();

    // Respond to creator
    this._send(ws, GROUP_OP.GROUP_CREATED, {
      success:  true,
      group_id,
      name,
      members:  allMembers,
      ts:       now,
    });

    // Push GROUP_INVITE to all non-creator members who are online here
    for (const memberId of allMembers) {
      if (memberId === creator_id) continue;
      const conn = this._gateway && this._gateway.getConnection(memberId);
      if (conn) {
        this._send(conn, GROUP_OP.GROUP_INVITE, {
          group_id,
          group_name:  name,
          invited_by:  creator_id,
          member_count: allMembers.length,
          ts:          now,
        });
      }
      // Not connected: nothing is kept for them. Their GROUP_LIST shows the group the
      // next time they open their messages.
    }

    // Broadcast group membership to peer nodes
    this._peerMesh.broadcast('GROUP_MEMBERSHIP_BROADCAST', {
      group_id,
      name,
      created_by:   creator_id,
      created_at:   now,
      members:      allMembers.map(id => ({
        member_id: id,
        role:      id === creator_id ? 'admin' : 'member',
        joined_at: now,
      })),
      origin_node:  this._identity.nodeId,
    });

    // Forward invites to peer nodes for members enrolled there
    this._peerMesh.broadcast('GROUP_INVITE_FORWARD', {
      group_id,
      group_name:   name,
      invited_by:   creator_id,
      member_ids:   allMembers.filter(id => id !== creator_id),
      member_count: allMembers.length,
      ts:           now,
    });
  }

  // ── GROUP_SEND ────────────────────────────────────────────────────────────

  async handleGroupSend(ws, msg) {
    const { msg_id, group_id, envelopes, media_type, timestamp } = msg;
    const sender_id = ws._sovereignId;
    const reply = (p) => this._send(ws, 'MA', { msg_id, ...p });

    if (ws._legacyMode) { reply({ status: 'error', error: 'SIGNATURE_REQUIRED' }); return; }
    if (!msg_id || !group_id || !envelopes) { reply({ status: 'error', error: 'MISSING_FIELDS' }); return; }

    const membership = this._db._db.prepare(
      'SELECT 1 FROM sov_group_members WHERE group_id = ? AND member_id = ?'
    ).get(group_id, sender_id);
    if (!membership) { reply({ status: 'error', error: 'NOT_A_MEMBER' }); return; }

    let envObj;
    try { envObj = typeof envelopes === 'string' ? JSON.parse(envelopes) : envelopes; } catch (_) { envObj = null; }
    if (!envObj || typeof envObj !== 'object' || Array.isArray(envObj)) {
      reply({ status: 'error', error: 'MISSING_FIELDS' }); return;
    }
    // End-to-end or nothing: one envelope per member, each a v2 ciphertext.
    if (Object.prototype.hasOwnProperty.call(envObj, '*') || !Object.values(envObj).every(isV2Envelope)) {
      reply({ status: 'error', error: 'GROUP_PLAINTEXT_REFUSED' }); return;
    }

    const now = timestamp || Date.now();
    const members = this._db._db.prepare(
      'SELECT member_id FROM sov_group_members WHERE group_id = ?'
    ).all(group_id).map(r => r.member_id).filter(id => id !== sender_id);
    const memberSet = new Set(members);

    const delivered = [], offline = [];
    const noEnvelope = members.filter(id => !envObj[id]);          // the sender had no key for them
    const byNode = new Map();                                       // node_id -> [member]
    for (const memberId of Object.keys(envObj)) {
      if (!memberSet.has(memberId)) continue;                       // not in this group: ignored
      const conn = this._gateway && this._gateway.getConnection(memberId);
      if (conn) {
        this._send(conn, GROUP_OP.GROUP_MESSAGE_INCOMING, {
          msg_id, group_id, sender_id, content: envObj[memberId], media_type: media_type || 'text', ts: now,
        });
        delivered.push(memberId);
        continue;
      }
      const presence = this._db.getCitizenPresence && this._db.getCitizenPresence(memberId);
      if (presence && presence.status === 'online' && presence.node_id && presence.node_id !== this._identity.nodeId) {
        if (!byNode.has(presence.node_id)) byNode.set(presence.node_id, []);
        byNode.get(presence.node_id).push(memberId);
      } else {
        offline.push(memberId);
      }
    }

    // Forward each remote node ONLY its members' envelopes, and wait for its answer.
    await Promise.all([...byNode.entries()].map(async ([nodeId, ids]) => {
      const got = await this._forwardGroup(nodeId, { msg_id, group_id, sender_id, media_type, ts: now,
        envelopes: Object.fromEntries(ids.map(id => [id, envObj[id]])) });
      const ok = new Set(got);
      for (const id of ids) (ok.has(id) ? delivered : offline).push(id);
    }));

    reply({
      success: true,
      status: offline.length || noEnvelope.length ? (delivered.length ? 'partial' : 'offline') : 'delivered',
      delivered, offline, no_envelope: noEnvelope, ts: now,
    });
  }

  _forwardGroup(nodeId, payload) {
    return new Promise((resolve) => {
      const key = `${payload.msg_id}|${nodeId}`;
      const timer = setTimeout(() => { this._groupWaiters.delete(key); resolve([]); }, GROUP_FORWARD_ACK_MS);
      this._groupWaiters.set(key, (ids) => { clearTimeout(timer); this._groupWaiters.delete(key); resolve(ids); });
      const fwd = { ...payload, target_node: nodeId, origin_node: this._identity.nodeId,
        // An older node ignores target_node; this keeps it from touching anyone else.
        local_members: [payload.sender_id] };
      if (!this._peerMesh.sendTo || !this._peerMesh.sendTo(nodeId, 'GROUP_MSG_FORWARD', fwd)) {
        this._peerMesh.broadcast('GROUP_MSG_FORWARD', fwd);
      }
    });
  }

  _handleGroupDeliveryAck(msg) {
    const { msg_id, answering_node, delivered, origin_node } = msg;
    if (origin_node && origin_node !== this._identity.nodeId) return;
    const w = this._groupWaiters.get(`${msg_id}|${answering_node}`);
    if (w) w(Array.isArray(delivered) ? delivered.map(String) : []);
  }

  // ── GROUP_LIST ────────────────────────────────────────────────────────────

  handleGroupList(ws, msg) {
    const member_id = ws._sovereignId;

    const groups = this._db._db.prepare(`
      SELECT g.group_id, g.name, g.created_by, g.created_at, g.member_count
      FROM sov_groups g
      JOIN sov_group_members m ON g.group_id = m.group_id
      WHERE m.member_id = ?
      ORDER BY g.created_at DESC
    `).all(member_id);

    // Members are routing data the node already holds; the phone needs them to encrypt
    // one envelope per member.
    const memStmt = this._db._db.prepare('SELECT member_id FROM sov_group_members WHERE group_id = ?');
    for (const g of groups) g.members = memStmt.all(g.group_id).map(r => r.member_id);

    this._send(ws, GROUP_OP.GROUP_LIST_RESULT, { groups, ts: Date.now() });
  }

  // ── GROUP_HISTORY ─────────────────────────────────────────────────────────

  handleGroupHistory(ws, msg) {
    // Nodes keep no messages, so there is no history to give. Group history lives on
    // each member's own device. Answered (empty) so an older app does not hang.
    const { group_id } = msg || {};
    this._send(ws, GROUP_OP.GROUP_HISTORY_RESULT, { group_id, messages: [], ts: Date.now() });
  }

  // ── GROUP_ADD_MEMBER ──────────────────────────────────────────────────────

  handleAddMember(ws, msg) {
    const { group_id, new_member_id } = msg;
    const requester_id = ws._sovereignId;

    if (ws._legacyMode) return;  // SIGNATURE_REQUIRED

    if (!group_id || !new_member_id) return;

    // Must be admin
    const adminRow = this._db._db.prepare(
      "SELECT 1 FROM sov_group_members WHERE group_id = ? AND member_id = ? AND role = 'admin'"
    ).get(group_id, requester_id);
    if (!adminRow) {
      this._send(ws, GROUP_OP.GROUP_UPDATE, {
        group_id, success: false, error: 'NOT_ADMIN',
      });
      return;
    }

    // Check max members governance param
    const maxMembers = parseInt(
      this._db.getGovParam(PARAM_GROUP_MAX_MEMBERS) || String(DEFAULT_MAX_MEMBERS)
    );
    const group = this._db._db.prepare(
      'SELECT member_count FROM sov_groups WHERE group_id = ?'
    ).get(group_id);
    if (!group || group.member_count >= maxMembers) {
      this._send(ws, GROUP_OP.GROUP_UPDATE, {
        group_id, success: false, error: 'GROUP_FULL',
      });
      return;
    }

    const now = Date.now();
    this._db._db.prepare(`
      INSERT OR IGNORE INTO sov_group_members (group_id, member_id, joined_at, role)
      VALUES (?, ?, ?, 'member')
    `).run(group_id, new_member_id, now);

    this._db._db.prepare(
      'UPDATE sov_groups SET member_count = member_count + 1 WHERE group_id = ?'
    ).run(group_id);

    // Invite the new member
    const groupRow = this._db._db.prepare(
      'SELECT name, created_by FROM sov_groups WHERE group_id = ?'
    ).get(group_id);

    const invitePayload = {
      group_id,
      group_name:  groupRow ? groupRow.name : '',
      invited_by:  requester_id,
      member_count: group.member_count + 1,
      ts:          now,
    };

    const conn = this._gateway && this._gateway.getConnection(new_member_id);
    if (conn) this._send(conn, GROUP_OP.GROUP_INVITE, invitePayload);   // else: GROUP_LIST shows it later

    // Broadcast membership update to peers
    this._peerMesh.broadcast('GROUP_MEMBERSHIP_BROADCAST', {
      group_id,
      name:          groupRow ? groupRow.name : '',
      created_by:    groupRow ? groupRow.created_by : '',
      created_at:    now,
      members: [{ member_id: new_member_id, role: 'member', joined_at: now }],
      origin_node:   this._identity.nodeId,
    });

    this._send(ws, GROUP_OP.GROUP_UPDATE, {
      group_id, success: true, action: 'member_added', member_id: new_member_id, ts: now,
    });
  }

  // ── GROUP_LEAVE ───────────────────────────────────────────────────────────

  handleGroupLeave(ws, msg) {
    const { group_id } = msg;
    const member_id    = ws._sovereignId;

    if (ws._legacyMode) return;  // SIGNATURE_REQUIRED

    if (!group_id) return;

    this._db._db.prepare(
      'DELETE FROM sov_group_members WHERE group_id = ? AND member_id = ?'
    ).run(group_id, member_id);

    this._db._db.prepare(
      'UPDATE sov_groups SET member_count = MAX(0, member_count - 1) WHERE group_id = ?'
    ).run(group_id);

    this._send(ws, GROUP_OP.GROUP_UPDATE, {
      group_id, success: true, action: 'left', ts: Date.now(),
    });

    // Broadcast leave to peers
    this._peerMesh.broadcast('GROUP_LEAVE_BROADCAST', {
      group_id, member_id, origin_node: this._identity.nodeId,
    });
  }

  // ── Peer mesh handlers ────────────────────────────────────────────────────

  _handleGroupMsgForward(msg) {
    const { msg_id, group_id, sender_id, envelopes, media_type, ts, target_node, origin_node } = msg;
    if (!msg_id || !group_id || !sender_id) return;
    // Only the node the sender's node addressed acts on it. (An untargeted forward comes
    // from an older node; ignoring it loses nothing - the sender's device still holds it.)
    if (!target_node || target_node !== this._identity.nodeId) return;

    let envObj = {};
    try { envObj = typeof envelopes === 'string' ? JSON.parse(envelopes) : (envelopes || {}); } catch (_) {}
    const isMember = this._db._db.prepare('SELECT 1 FROM sov_group_members WHERE group_id = ? AND member_id = ?');
    const delivered = [];
    if (isMember.get(group_id, sender_id)) {
      for (const [memberId, env] of Object.entries(envObj)) {
        if (!isV2Envelope(env) || !isMember.get(group_id, memberId)) continue;
        const conn = this._gateway && this._gateway.getConnection(memberId);
        if (!conn) continue;                     // not here: the sender's device keeps it
        this._send(conn, GROUP_OP.GROUP_MESSAGE_INCOMING, {
          msg_id, group_id, sender_id, content: env, media_type: media_type || 'text', ts: ts || Date.now(),
        });
        delivered.push(memberId);
      }
    }
    const ack = { msg_id, delivered, answering_node: this._identity.nodeId, origin_node };
    if (!this._peerMesh.sendTo || !this._peerMesh.sendTo(origin_node, 'GROUP_DELIVERY_ACK', ack)) {
      this._peerMesh.broadcast('GROUP_DELIVERY_ACK', ack);
    }
  }

  _handleMembershipBroadcast(msg) {
    const { group_id, name, created_by, created_at, members, origin_node } = msg;
    if (!group_id || origin_node === this._identity.nodeId) return;

    // Ensure group record exists
    this._db._db.prepare(`
      INSERT OR IGNORE INTO sov_groups (group_id, name, created_by, created_at, member_count)
      VALUES (?, ?, ?, ?, ?)
    `).run(group_id, name || '', created_by || '', created_at || Date.now(),
          Array.isArray(members) ? members.length : 0);

    // Add new members and keep member_count in sync on this node
    if (Array.isArray(members)) {
      const ins = this._db._db.prepare(`
        INSERT OR IGNORE INTO sov_group_members (group_id, member_id, joined_at, role)
        VALUES (?, ?, ?, ?)
      `);
      const updCount = this._db._db.prepare(
        'UPDATE sov_groups SET member_count = member_count + 1 WHERE group_id = ?'
      );
      for (const m of members) {
        const result = ins.run(group_id, m.member_id, m.joined_at || Date.now(), m.role || 'member');
        if (result.changes > 0) {
          updCount.run(group_id);  // new row inserted — keep count accurate
        }
      }
    }
  }

  _handleInviteForward(msg) {
    const { group_id, group_name, invited_by, member_ids, member_count, ts } = msg;
    if (!group_id || !Array.isArray(member_ids)) return;

    for (const memberId of member_ids) {
      const conn = this._gateway && this._gateway.getConnection(memberId);
      const payload = { group_id, group_name, invited_by, member_count, ts: ts || Date.now() };
      if (conn) this._send(conn, GROUP_OP.GROUP_INVITE, payload);   // else: GROUP_LIST shows it later
    }
  }

  _handleLeaveBroadcast(msg) {
    const { group_id, member_id, origin_node } = msg;
    if (!group_id || !member_id || origin_node === this._identity.nodeId) return;

    this._db._db.prepare(
      'DELETE FROM sov_group_members WHERE group_id = ? AND member_id = ?'
    ).run(group_id, member_id);

    this._db._db.prepare(
      'UPDATE sov_groups SET member_count = MAX(0, member_count - 1) WHERE group_id = ?'
    ).run(group_id);
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  _send(ws, op, payload) {
    if (!ws || ws.readyState !== 1) return;
    ws.send(JSON.stringify({ op, ...payload }));
  }
}

module.exports = { GroupEngine, GROUP_OP };
