// ─────────────────────────────────────────────────────────────────────────────
// GROUP ENGINE — SOV Speak multi-citizen encrypted channels
// ─────────────────────────────────────────────────────────────────────────────
// Handles group conversations: creation, membership, cross-node message routing.
//
// Groups are stored on the node where the creator enrolled. Every member's home
// node gets a copy of the group record. Messages are stored on every node that
// has a member online, maximising availability.
//
// Message delivery:
//   When a GROUP_SEND arrives, the engine delivers to all members who are online
//   on THIS node, then forwards to peer nodes for their members.
//
// Cross-node membership:
//   GROUP_MEMBERSHIP_BROADCAST ensures all nodes know who is in the group so they
//   can deliver messages to their connected members.
//
// E2E encryption:
//   Each message is encrypted per-recipient by the SENDING PHONE before transit.
//   The node stores and forwards opaque encrypted envelopes. Each member's
//   envelope uses their own X25519 public key (from PUBLIC_KEY_QUERY).
//   The node sees: message metadata + a map of { recipient_id → encrypted_envelope }.
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
const PARAM_MSG_RETENTION     = 'group_message_retention_days';

const DEFAULT_MAX_MEMBERS     = 50;
const DEFAULT_MSG_RETENTION   = 90;  // days

// Maximum message history returned per request
const HISTORY_PAGE_SIZE = 50;

class GroupEngine {

  constructor(identity, db, peerMesh) {
    this._identity = identity;
    this._db       = db;
    this._peerMesh = peerMesh;
    this._gateway  = null;

    this._initGroupTables();

    // Register peer mesh handlers
    peerMesh.on('GROUP_MSG_FORWARD',         (msg) => this._handleGroupMsgForward(msg));
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

    // Seed governance defaults for group params
    const db = this._db;
    if (!db.getGovParam(PARAM_GROUP_MAX_MEMBERS)) {
      db.setGovParam(PARAM_GROUP_MAX_MEMBERS, String(DEFAULT_MAX_MEMBERS));
    }
    if (!db.getGovParam(PARAM_MSG_RETENTION)) {
      db.setGovParam(PARAM_MSG_RETENTION, String(DEFAULT_MSG_RETENTION));
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
      } else {
        // Queue invite for offline member
        this._db.queuePendingMessage(memberId, GROUP_OP.GROUP_INVITE, {
          group_id, group_name: name,
          invited_by: creator_id,
          member_count: allMembers.length,
          ts: now,
        });
      }
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

  handleGroupSend(ws, msg) {
    const { msg_id, group_id, envelopes, media_type, timestamp } = msg;
    const sender_id = ws._sovereignId;

    if (ws._legacyMode) { this._send(ws, 'MA', { msg_id, status: 'error', error: 'SIGNATURE_REQUIRED' }); return; }

    if (!msg_id || !group_id || !envelopes) {
      this._send(ws, 'MA', { msg_id, status: 'error', error: 'MISSING_FIELDS' });
      return;
    }

    // Verify sender is a member of this group
    const membership = this._db._db.prepare(
      'SELECT 1 FROM sov_group_members WHERE group_id = ? AND member_id = ?'
    ).get(group_id, sender_id);
    if (!membership) {
      this._send(ws, 'MA', { msg_id, status: 'error', error: 'NOT_A_MEMBER' });
      return;
    }

    const now     = timestamp || Date.now();
    const envJson = typeof envelopes === 'string' ? envelopes : JSON.stringify(envelopes);

    // Store message
    try {
      this._db._db.prepare(`
        INSERT OR IGNORE INTO sov_group_messages
          (msg_id, group_id, sender_id, envelopes, media_type, created_at)
        VALUES (?, ?, ?, ?, ?, ?)
      `).run(msg_id, group_id, sender_id, envJson, media_type || 'text', now);
    } catch (_) {}

    // ACK sender
    this._send(ws, 'MA', { msg_id, status: 'sent', ts: now });

    // Get all group members
    const members = this._db._db.prepare(
      'SELECT member_id FROM sov_group_members WHERE group_id = ?'
    ).all(group_id).map(r => r.member_id);

    const envObj = typeof envelopes === 'string' ? JSON.parse(envelopes) : envelopes;

    // Track members actually delivered to on THIS node.
    // Offline-queued members are NOT added so peer nodes can attempt delivery for them.
    const locallyDelivered = new Set([sender_id]);

    // Deliver to each member who is online on this node (except sender)
    for (const memberId of members) {
      if (memberId === sender_id) continue;
      const conn = this._gateway && this._gateway.getConnection(memberId);
      if (conn) {
        this._send(conn, GROUP_OP.GROUP_MESSAGE_INCOMING, {
          msg_id,
          group_id,
          sender_id,
          content:    envObj[memberId] || envObj['*'] || '',
          media_type: media_type || 'text',
          ts:         now,
        });
        locallyDelivered.add(memberId);  // delivered here — peer nodes skip this member
      } else {
        // Queue for offline member on THIS node.
        // NOT added to locallyDelivered — peer nodes should also attempt delivery.
        this._db.queuePendingMessage(memberId, GROUP_OP.GROUP_MESSAGE_INCOMING, {
          msg_id, group_id, sender_id,
          content:    envObj[memberId] || envObj['*'] || '',
          media_type: media_type || 'text',
          ts:         now,
        });
      }
    }

    // Forward to peer nodes for members not yet handled (not in locallyDelivered)
    this._peerMesh.broadcast('GROUP_MSG_FORWARD', {
      msg_id,
      group_id,
      sender_id,
      envelopes:  envJson,
      media_type: media_type || 'text',
      ts:         now,
      origin_node: this._identity.nodeId,
      local_members: [...locallyDelivered],  // only online-delivered members + sender
    });
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

    this._send(ws, GROUP_OP.GROUP_LIST_RESULT, { groups, ts: Date.now() });
  }

  // ── GROUP_HISTORY ─────────────────────────────────────────────────────────

  handleGroupHistory(ws, msg) {
    const { group_id, before_ts, limit } = msg;
    const requester_id = ws._sovereignId;

    if (!group_id) return;

    // Verify membership
    const member = this._db._db.prepare(
      'SELECT 1 FROM sov_group_members WHERE group_id = ? AND member_id = ?'
    ).get(group_id, requester_id);
    if (!member) {
      this._send(ws, GROUP_OP.GROUP_HISTORY_RESULT, {
        group_id, messages: [], error: 'NOT_A_MEMBER',
      });
      return;
    }

    const pageSize = Math.min(parseInt(limit) || HISTORY_PAGE_SIZE, 200);
    const cutoff   = before_ts || Date.now();

    const messages = this._db._db.prepare(`
      SELECT msg_id, sender_id, envelopes, media_type, created_at
      FROM sov_group_messages
      WHERE group_id = ? AND created_at < ?
      ORDER BY created_at DESC
      LIMIT ?
    `).all(group_id, cutoff, pageSize);

    // Return only the envelope for the requesting member
    const filtered = messages.map(m => ({
      msg_id:     m.msg_id,
      sender_id:  m.sender_id,
      content:    this._extractEnvelope(m.envelopes, requester_id),
      media_type: m.media_type,
      ts:         m.created_at,
    }));

    this._send(ws, GROUP_OP.GROUP_HISTORY_RESULT, {
      group_id, messages: filtered, ts: Date.now(),
    });
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
    if (conn) {
      this._send(conn, GROUP_OP.GROUP_INVITE, invitePayload);
    } else {
      this._db.queuePendingMessage(new_member_id, GROUP_OP.GROUP_INVITE, invitePayload);
    }

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
    const { msg_id, group_id, sender_id, envelopes, media_type, ts, local_members } = msg;
    if (!msg_id || !group_id) return;

    const envObj       = typeof envelopes === 'string' ? JSON.parse(envelopes) : (envelopes || {});
    const skipMembers  = new Set(local_members || []);

    // Find members on THIS node that are not in the local_members list
    const myMembers = this._db._db.prepare(
      'SELECT member_id FROM sov_group_members WHERE group_id = ?'
    ).all(group_id).map(r => r.member_id).filter(id => !skipMembers.has(id));

    for (const memberId of myMembers) {
      if (memberId === sender_id) continue;
      const conn = this._gateway && this._gateway.getConnection(memberId);
      const content = envObj[memberId] || envObj['*'] || '';
      if (conn) {
        this._send(conn, GROUP_OP.GROUP_MESSAGE_INCOMING, {
          msg_id, group_id, sender_id, content,
          media_type: media_type || 'text', ts: ts || Date.now(),
        });
      } else {
        this._db.queuePendingMessage(memberId, GROUP_OP.GROUP_MESSAGE_INCOMING, {
          msg_id, group_id, sender_id, content,
          media_type: media_type || 'text', ts: ts || Date.now(),
        });
      }
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
      if (conn) {
        this._send(conn, GROUP_OP.GROUP_INVITE, payload);
      } else {
        this._db.queuePendingMessage(memberId, GROUP_OP.GROUP_INVITE, payload);
      }
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

  _extractEnvelope(envelopesJson, memberId) {
    try {
      const obj = typeof envelopesJson === 'string' ? JSON.parse(envelopesJson) : envelopesJson;
      return obj[memberId] || obj['*'] || '';
    } catch (_) {
      return '';
    }
  }

  _send(ws, op, payload) {
    if (!ws || ws.readyState !== 1) return;
    ws.send(JSON.stringify({ op, ...payload }));
  }
}

module.exports = { GroupEngine, GROUP_OP };
