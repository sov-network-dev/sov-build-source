// ─────────────────────────────────────────────────────────────────────────────
// CALLS ENGINE — LiveKit voice/video call signalling + token issuance
// ─────────────────────────────────────────────────────────────────────────────
// The SOV Node issues JWT tokens for LiveKit rooms.
// The LiveKit server (bundled inside the snap) does the actual media routing.
// This engine NEVER sees audio or video data — only room names and tokens.
//
// Call flow:
//   1. Caller sends CALL_INVITE to their node
//   2. Node creates a LiveKit room, mints tokens for both parties
//   3. Node delivers CALL_INCOMING to callee (same node or cross-node via peer_mesh)
//   4. Callee accepts (CALL_ANSWER) — node sends caller their token via CALL_ANSWERED
//   5. Both phones connect to LiveKit using their tokens
//   6. Either party sends CALL_END → node notifies the other party
//
// Cross-node:
//   If callee is on a different node, CALL_INVITE triggers CALL_FORWARD_PEER
//   to the callee's node. That node delivers CALL_INCOMING to the callee.
//   CALL_ANSWER is routed back the same way.
//
// Governance gates:
//   sov_calls       — '0' = calls dormant, '1' = calls active
//   sov_video_calls — '0' = audio only, '1' = video also allowed
//
// Op codes (inbound from phone):
//   CI — CALL_INVITE        CE — CALL_END
//   CA — CALL_ANSWER        CJ — CALL_REJECT
//
// LiveKit configuration (from snap.env):
//   LIVEKIT_API_KEY     — API key for token signing
//   LIVEKIT_API_SECRET  — API secret for token signing
//   LIVEKIT_URL         — ws://127.0.0.1:7880 (local LiveKit server)
// ─────────────────────────────────────────────────────────────────────────────

'use strict';

const crypto = require('crypto');

// LiveKit JWT token generation
// We implement the token signing ourselves to avoid npm dependency.
// LiveKit uses standard HS256 JWTs with a custom grants claim.
// Spec: https://docs.livekit.io/server/generating-tokens/
class LiveKitTokenIssuer {

  constructor(apiKey, apiSecret) {
    this._apiKey    = apiKey;
    this._apiSecret = apiSecret;
  }

  // Generate a token for a participant to join a room
  // grants: { roomJoin, room, canPublish, canSubscribe }
  mint(participantId, roomName, grants = {}) {
    const now    = Math.floor(Date.now() / 1000);
    const expiry = now + (2 * 60 * 60);  // 2 hours

    const header = { alg: 'HS256', typ: 'JWT' };
    const payload = {
      iss: this._apiKey,
      sub: participantId,
      nbf: now,
      exp: expiry,
      video: {
        roomJoin:     true,
        room:         roomName,
        canPublish:   grants.canPublish   !== false,
        canSubscribe: grants.canSubscribe !== false,
      },
    };

    const b64Header  = Buffer.from(JSON.stringify(header)).toString('base64url');
    const b64Payload = Buffer.from(JSON.stringify(payload)).toString('base64url');
    const signing    = `${b64Header}.${b64Payload}`;

    const sig = crypto.createHmac('sha256', this._apiSecret)
      .update(signing)
      .digest('base64url');

    return `${signing}.${sig}`;
  }

  isConfigured() {
    return !!(this._apiKey && this._apiSecret &&
              this._apiKey !== 'sov_api_key' &&
              this._apiSecret !== 'your_generated_secret');
  }
}

class CallsEngine {

  constructor(identity, db, peerMesh) {
    this._identity = identity;
    this._db       = db;
    this._peerMesh = peerMesh;
    this._gateway  = null;

    // Active call timeouts — enforce max duration
    this._callTimers = new Map();  // call_id → timeout handle

    // LiveKit token issuer
    const apiKey    = process.env.LIVEKIT_API_KEY    || 'sov_api_key';
    const apiSecret = process.env.LIVEKIT_API_SECRET || 'your_generated_secret';
    this._livekit   = new LiveKitTokenIssuer(apiKey, apiSecret);
    this._livekitUrl = process.env.LIVEKIT_URL || 'ws://127.0.0.1:7880';

    this._initCallsTables();

    // Register peer mesh handlers
    peerMesh.on('CALL_FORWARD_PEER',    (msg) => this._handleCallForwardPeer(msg));
    peerMesh.on('CALL_ANSWER_FORWARD',  (msg) => this._handleCallAnswerForward(msg));
    peerMesh.on('CALL_END_FORWARD',     (msg) => this._handleCallEndForward(msg));
    peerMesh.on('CALL_REJECT_FORWARD',  (msg) => this._handleCallRejectForward(msg));

    if (!this._livekit.isConfigured()) {
      global.sovLog.warn('[Calls] LiveKit not configured — set LIVEKIT_API_KEY + LIVEKIT_API_SECRET in snap.env');
      global.sovLog.warn('[Calls] Voice/video calls will fail until LiveKit is configured and sov_calls is activated via governance');
    } else {
      global.sovLog.info('      ✓ Calls engine initialised (LiveKit configured)');
    }
  }

  setGateway(gateway) {
    this._gateway = gateway;
  }

  // ── Table initialisation ──────────────────────────────────────────────────

  _initCallsTables() {
    this._db._db.exec(`
      CREATE TABLE IF NOT EXISTS sov_call_sessions (
        call_id       TEXT PRIMARY KEY,
        caller_id     TEXT NOT NULL,
        callee_id     TEXT NOT NULL,
        room_name     TEXT NOT NULL,
        caller_token  TEXT NOT NULL DEFAULT '',   -- stored until caller connects
        callee_token  TEXT NOT NULL DEFAULT '',
        status        TEXT NOT NULL DEFAULT 'ringing', -- ringing | active | ended | missed | rejected
        call_type     TEXT NOT NULL DEFAULT 'audio',   -- audio | video
        started_at    INTEGER NOT NULL,
        answered_at   INTEGER NOT NULL DEFAULT 0,
        ended_at      INTEGER NOT NULL DEFAULT 0
      );
      CREATE INDEX IF NOT EXISTS idx_calls_caller ON sov_call_sessions(caller_id);
      CREATE INDEX IF NOT EXISTS idx_calls_callee ON sov_call_sessions(callee_id);
    `);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  CALL HANDLERS — invoked by citizen_gateway switch
  // ═══════════════════════════════════════════════════════════════════════════

  handleCallInvite(ws, msg) {
    if (!this._checkCallsEnabled(ws)) return;

    const { call_id, callee_id, call_type } = msg;
    const caller_id = ws._sovereignId;

    if (ws._legacyMode) { this._send(ws, 'CIR', { success: false, error: 'SIGNATURE_REQUIRED' }); return; }

    if (!call_id || !callee_id) {
      this._send(ws, 'CIR', { success: false, error: 'MISSING_FIELDS' });
      return;
    }

    // Check video gate if video call
    if (call_type === 'video' && this._getGovParam('sov_video_calls', '0') !== '1') {
      this._send(ws, 'CIR', { success: false, error: 'VIDEO_CALLS_NOT_ACTIVATED' });
      return;
    }

    if (!this._livekit.isConfigured()) {
      this._send(ws, 'CIR', { success: false, error: 'LIVEKIT_NOT_CONFIGURED' });
      return;
    }

    // Can't call yourself
    if (callee_id === caller_id) {
      this._send(ws, 'CIR', { success: false, error: 'CANNOT_CALL_SELF' });
      return;
    }

    // Check for duplicate call
    const existing = this._db._db.prepare(
      "SELECT call_id FROM sov_call_sessions WHERE call_id = ? AND status IN ('ringing','active')"
    ).get(call_id);
    if (existing) {
      this._send(ws, 'CIR', { success: false, error: 'CALL_ALREADY_EXISTS' });
      return;
    }

    // Create LiveKit room name (unique, not guessable)
    const roomName   = `sov-${call_id}`;
    const callerToken = this._livekit.mint(caller_id, roomName, { canPublish: true, canSubscribe: true });
    const calleeToken = this._livekit.mint(callee_id, roomName, { canPublish: true, canSubscribe: true });

    const now = Date.now();
    this._db._db.prepare(`
      INSERT INTO sov_call_sessions
        (call_id, caller_id, callee_id, room_name, caller_token, callee_token,
         status, call_type, started_at)
      VALUES (?, ?, ?, ?, ?, ?, 'ringing', ?, ?)
    `).run(call_id, caller_id, callee_id, roomName, callerToken, calleeToken,
           call_type || 'audio', now);

    // Acknowledge to caller
    this._send(ws, 'CIR', { success: true, call_id, livekit_url: this._livekitUrl });

    // Deliver CALL_INCOMING to callee (same node or cross-node)
    const delivered = this._gateway.push(callee_id, 'CI', {
      call_id,
      caller_id,
      call_type: call_type || 'audio',
      livekit_url: this._livekitUrl,
    });

    if (!delivered) {
      // Forward to callee's node
      const presence = this._db.getCitizenPresence(callee_id);
      if (presence && presence.node_id !== this._identity.nodeId) {
        this._peerMesh.sendTo(presence.node_id, 'CALL_FORWARD_PEER', {
          call_id,
          caller_id,
          callee_id,
          callee_token: calleeToken,
          caller_token: callerToken,
          call_type: call_type || 'audio',
          livekit_url: this._livekitUrl,
          origin_node: this._identity.nodeId,
        });
      } else {
        // Callee offline — store for delivery when they reconnect
        // We still keep the session open for `call_max_duration_minutes`
        global.sovLog.debug(`[Calls] Callee ${callee_id.slice(0,12)} offline — call_id=${call_id}`);
      }
    }

    // Set max-duration timer
    const maxMinutes = parseInt(this._getGovParam('call_max_duration_minutes', '60'));
    const timer = setTimeout(() => {
      this._terminateCall(call_id, 'MAX_DURATION_REACHED');
    }, maxMinutes * 60 * 1000);
    this._callTimers.set(call_id, timer);
  }

  handleCallAnswer(ws, msg) {
    const { call_id } = msg;
    const callee_id   = ws._sovereignId;

    if (ws._legacyMode) { this._send(ws, 'CAR', { success: false, error: 'SIGNATURE_REQUIRED' }); return; }

    const session = this._db._db.prepare(
      "SELECT * FROM sov_call_sessions WHERE call_id = ? AND status = 'ringing'"
    ).get(call_id);

    if (!session) {
      this._send(ws, 'CAR', { success: false, error: 'CALL_NOT_FOUND_OR_NOT_RINGING' });
      return;
    }

    if (session.callee_id !== callee_id) {
      this._send(ws, 'CAR', { success: false, error: 'NOT_THE_CALLEE' });
      return;
    }

    // Mark active
    this._db._db.prepare(
      "UPDATE sov_call_sessions SET status = 'active', answered_at = ? WHERE call_id = ?"
    ).run(Date.now(), call_id);

    // Send callee their token
    this._send(ws, 'CAR', {
      success:     true,
      call_id,
      token:       session.callee_token,
      livekit_url: this._livekitUrl,
    });

    // Send caller their token (they may be on this node or another)
    const callerDelivered = this._gateway.push(session.caller_id, 'CAN', {
      call_id,
      token:       session.caller_token,
      livekit_url: this._livekitUrl,
    });

    if (!callerDelivered) {
      // Caller may be on their origin node — forward via peer_mesh
      const presence = this._db.getCitizenPresence(session.caller_id);
      if (presence && presence.node_id !== this._identity.nodeId) {
        this._peerMesh.sendTo(presence.node_id, 'CALL_ANSWER_FORWARD', {
          call_id,
          caller_id:   session.caller_id,
          caller_token: session.caller_token,
          livekit_url: this._livekitUrl,
        });
      }
    }
  }

  handleCallEnd(ws, msg) {
    const { call_id } = msg;
    const from_id     = ws._sovereignId;

    if (ws._legacyMode) return;  // SIGNATURE_REQUIRED

    const session = this._db._db.prepare(
      "SELECT * FROM sov_call_sessions WHERE call_id = ? AND status IN ('ringing','active')"
    ).get(call_id);

    if (!session) return;  // Already ended

    if (session.caller_id !== from_id && session.callee_id !== from_id) return;

    this._terminateCall(call_id, 'ENDED_BY_PARTICIPANT');
  }

  handleCallReject(ws, msg) {
    const { call_id } = msg;
    const callee_id   = ws._sovereignId;

    if (ws._legacyMode) return;  // SIGNATURE_REQUIRED

    const session = this._db._db.prepare(
      "SELECT * FROM sov_call_sessions WHERE call_id = ? AND status = 'ringing'"
    ).get(call_id);

    if (!session || session.callee_id !== callee_id) return;

    this._db._db.prepare(
      "UPDATE sov_call_sessions SET status = 'rejected', ended_at = ? WHERE call_id = ?"
    ).run(Date.now(), call_id);

    this._clearCallTimer(call_id);

    // Notify caller
    const callerDelivered = this._gateway.push(session.caller_id, 'CRJ', { call_id });

    if (!callerDelivered) {
      const presence = this._db.getCitizenPresence(session.caller_id);
      if (presence && presence.node_id !== this._identity.nodeId) {
        this._peerMesh.sendTo(presence.node_id, 'CALL_REJECT_FORWARD', {
          call_id,
          caller_id: session.caller_id,
        });
      }
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  CROSS-NODE FORWARDING
  // ═══════════════════════════════════════════════════════════════════════════

  // Received from caller's node — deliver CALL_INCOMING to callee on THIS node
  _handleCallForwardPeer(msg) {
    const { call_id, caller_id, callee_id, callee_token, caller_token, call_type, livekit_url, origin_node } = msg;
    if (!call_id || !callee_id) return;

    // Store the session on this node (callee's node) so CALL_ANSWER can find it
    this._db._db.prepare(`
      INSERT OR IGNORE INTO sov_call_sessions
        (call_id, caller_id, callee_id, room_name, callee_token, caller_token,
         status, call_type, started_at)
      VALUES (?, ?, ?, ?, ?, ?, 'ringing', ?, ?)
    `).run(call_id, caller_id, callee_id, `sov-${call_id}`,
           callee_token || '', caller_token || '', call_type || 'audio', Date.now());

    // Deliver to callee if connected here
    this._gateway && this._gateway.push(callee_id, 'CI', {
      call_id,
      caller_id,
      call_type: call_type || 'audio',
      livekit_url,
    });
  }

  // Received from callee's node — deliver caller token to caller on THIS node
  _handleCallAnswerForward(msg) {
    const { call_id, caller_id, caller_token, livekit_url } = msg;
    if (!call_id || !caller_id) return;

    // Mark active on this node too
    this._db._db.prepare(
      "UPDATE sov_call_sessions SET status = 'active', answered_at = ? WHERE call_id = ?"
    ).run(Date.now(), call_id);

    this._gateway && this._gateway.push(caller_id, 'CAN', {
      call_id,
      token:       caller_token,
      livekit_url,
    });
  }

  // Received from peer node — forward CALL_ENDED to local party
  _handleCallEndForward(msg) {
    const { call_id, caller_id, callee_id } = msg;
    this._db._db.prepare(
      "UPDATE sov_call_sessions SET status = 'ended', ended_at = ? WHERE call_id = ?"
    ).run(Date.now(), call_id);
    this._clearCallTimer(call_id);

    // Notify whichever party is on this node
    [caller_id, callee_id].forEach(id => {
      if (id) this._gateway && this._gateway.push(id, 'CEN', { call_id });
    });
  }

  _handleCallRejectForward(msg) {
    const { call_id, caller_id } = msg;
    this._db._db.prepare(
      "UPDATE sov_call_sessions SET status = 'rejected', ended_at = ? WHERE call_id = ?"
    ).run(Date.now(), call_id);
    this._clearCallTimer(call_id);

    this._gateway && this._gateway.push(caller_id, 'CRJ', { call_id });
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  INTERNAL HELPERS
  // ═══════════════════════════════════════════════════════════════════════════

  _terminateCall(callId, reason) {
    const session = this._db._db.prepare(
      "SELECT * FROM sov_call_sessions WHERE call_id = ? AND status IN ('ringing','active')"
    ).get(callId);

    if (!session) return;

    this._db._db.prepare(
      "UPDATE sov_call_sessions SET status = 'ended', ended_at = ? WHERE call_id = ?"
    ).run(Date.now(), callId);

    this._clearCallTimer(callId);

    // Notify both parties
    [session.caller_id, session.callee_id].forEach(id => {
      const delivered = this._gateway && this._gateway.push(id, 'CEN', { call_id: callId, reason });

      if (!delivered) {
        const presence = this._db.getCitizenPresence(id);
        if (presence && presence.node_id !== this._identity.nodeId) {
          this._peerMesh.sendTo(presence.node_id, 'CALL_END_FORWARD', {
            call_id:  callId,
            caller_id: session.caller_id,
            callee_id: session.callee_id,
            reason,
          });
        }
      }
    });

    global.sovLog.debug(`[Calls] Call ${callId.slice(0,12)} terminated: ${reason}`);
  }

  _clearCallTimer(callId) {
    const timer = this._callTimers.get(callId);
    if (timer) {
      clearTimeout(timer);
      this._callTimers.delete(callId);
    }
  }

  // Called by citizen_gateway._handleDisconnect when a citizen's WebSocket
  // closes. Finds every ringing/active call the citizen is part of and
  // terminates them — which delivers CALL_ENDED to the other party (local
  // push or peer-mesh CALL_END_FORWARD).
  //
  // Without this, when one side drops the other side's UI stays stuck on
  // "in call" until LiveKit's own 60–90s participant timeout fires. With
  // it, the other side hears the call end within ~1 s.
  handleCitizenDisconnect(sovereignId) {
    if (!sovereignId) return;
    try {
      const sessions = this._db._db.prepare(
        "SELECT call_id FROM sov_call_sessions " +
        "WHERE (caller_id = ? OR callee_id = ?) " +
        "  AND status IN ('ringing','active')"
      ).all(sovereignId, sovereignId);
      for (const row of sessions) {
        this._terminateCall(row.call_id, 'PEER_DISCONNECTED');
      }
      if (sessions.length > 0) {
        global.sovLog.debug(
          `[Calls] handleCitizenDisconnect ${sovereignId}: ` +
          `terminated ${sessions.length} active call(s)`,
        );
      }
    } catch (e) {
      global.sovLog.warn(`[Calls] handleCitizenDisconnect error: ${e.message}`);
    }
  }

  _checkCallsEnabled(ws) {
    if (this._getGovParam('sov_calls', '0') !== '1') {
      this._send(ws, 'CIR', { success: false, error: 'CALLS_NOT_ACTIVATED' });
      return false;
    }
    return true;
  }

  _getGovParam(key, fallback) {
    try {
      const row = this._db._db.prepare(
        'SELECT param_value FROM sov_governance_params WHERE param_key = ?'
      ).get(key);
      return row ? row.param_value.toString() : fallback;
    } catch (_) {
      return fallback;
    }
  }

  _send(ws, op, payload) {
    if (ws && ws.readyState === 1) {  // OPEN
      try {
        ws.send(JSON.stringify({ op, ...payload }));
      } catch (_) {}
    }
  }
}

module.exports = { CallsEngine };
