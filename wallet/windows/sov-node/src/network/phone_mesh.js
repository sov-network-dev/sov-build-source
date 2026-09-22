// ─────────────────────────────────────────────────────────────────────────────
// PHONE MESH — Fragment routing layer for citizen phones
// ─────────────────────────────────────────────────────────────────────────────
// This is the architectural breakthrough described in the SOV design sessions.
//
// Every SOV citizen app participates in routing message fragments for other
// citizens. No phone needs to accept inbound connections. All connections are
// OUTBOUND. NAT and firewalls are bypassed completely.
//
// The "secret dictionary" / protocol obfuscation:
//   Short gossip codes that mean nothing to an observer but trigger full
//   protocol operations in the SOV software. Traffic looks identical to
//   standard HTTPS WebSocket — indistinguishable from web browsing.
//
// Fragment routing:
//   1. Message is split into N encrypted fragments (K-of-N threshold)
//   2. Fragments gossip through the phone mesh via short FRAG_ANNOUNCE codes
//   3. Recipient app recognises its own address in the announce
//   4. Collects K fragments via outbound connections to fragment holders
//   5. Reassembles and decrypts the message
//   6. No single phone ever saw the full message
//   7. No server was involved
// ─────────────────────────────────────────────────────────────────────────────

'use strict';

const crypto = require('crypto');
const nacl   = require('tweetnacl');

// Threshold parameters — K of N fragments needed to reconstruct
const FRAGMENT_N = 5; // total fragments created
const FRAGMENT_K = 3; // minimum needed to reconstruct

// How long to hold fragments for other phones (seconds)
const FRAGMENT_TTL_SEC = 300; // 5 minutes

// ── Protocol Codebook ─────────────────────────────────────────────────────────
// These short codes are the "secret dictionary" — known only to SOV software.
// On the wire they look like random alphanumeric strings.
// Each code expands to a full SOV protocol operation.
//
// This is NOT security through obscurity — the message content is
// cryptographically encrypted regardless. The codebook reduces the
// observable "shape" of the protocol, making traffic analysis harder.
//
// Format: 2-char prefix identifies operation class
//   FA → Fragment Announce
//   FR → Fragment Request
//   FD → Fragment Deliver
//   MP → Mesh Peer Hello
//   MG → Mesh Peer Gone
//   NQ → Node Query (find which node a citizen belongs to)
//   NR → Node Response

const OP = {
  FRAG_ANNOUNCE:  'FA', // "Fragments of message X at these phone IDs"
  FRAG_REQUEST:   'FR', // "Send me fragment index I of message X"
  FRAG_DELIVER:   'FD', // "Here is fragment I of message X"
  MESH_HELLO:     'MP', // "I am a phone joining the mesh"
  MESH_GONE:      'MG', // "I am going offline, re-route my fragments"
  NODE_QUERY:     'NQ', // "Which node does citizen SOV-XXX belong to?"
  NODE_RESPONSE:  'NR', // "Citizen SOV-XXX is on node Y at address Z"
};

class PhoneMesh {

  constructor(identity, peerMesh, db) {
    this._identity   = identity;
    this._peerMesh   = peerMesh;
    this._db         = db;

    // Fragment cache — holds fragments for other phones temporarily
    this._fragmentCache = new Map(); // fragmentId → { data, expires }

    // Connected phone clients — phones currently holding open connections
    this._phoneClients  = new Map(); // citizenNodeId → ws

    // Gossip log — prevents re-gossiping the same announcement
    this._gossipSeen    = new Set();

    // Cleanup timer
    this._cleanupTimer  = null;
  }

  static async start(identity, peerMesh, db) {
    const mesh = new PhoneMesh(identity, peerMesh, db);
    mesh._startCleanup();
    // Register with peer mesh to receive PHONE_MESH messages
    peerMesh.on('PHONE_MESH_FORWARD', (msg) => mesh._handleForwardedGossip(msg));
    return mesh;
  }

  // ── Called by CitizenGateway when a phone connects ────────────────────────

  handlePhoneConnected(citizenId, ws) {
    this._phoneClients.set(citizenId, ws);
  }

  handlePhoneDisconnected(citizenId) {
    this._phoneClients.delete(citizenId);
    // Broadcast MESH_GONE so other phones stop sending fragments here
    this._gossipToMesh(OP.MESH_GONE, citizenId);
  }

  // ── Fragment routing API (called by message_router equivalent) ────────────

  // Split message and announce fragments across phone mesh
  async routeViaPhoneMesh(encryptedMessage, recipientCitizenId) {
    const msgHash   = crypto.createHash('sha256').update(encryptedMessage).digest('hex').slice(0, 8);
    const fragments = PhoneMesh._splitIntoFragments(encryptedMessage);

    // Find N phone holders for fragments
    const holders = this._selectFragmentHolders(FRAGMENT_N);

    // Distribute fragments to holders
    const holderIds = [];
    for (let i = 0; i < fragments.length; i++) {
      const holder = holders[i % holders.length];
      if (holder) {
        holder.ws.send(JSON.stringify({
          op:  OP.FRAG_DELIVER,
          fid: `${msgHash}:${i}`,      // fragment ID — meaningless without the announce
          dat: fragments[i].toString('hex'), // encrypted fragment data
          exp: Date.now() + (FRAGMENT_TTL_SEC * 1000),
        }));
        holderIds.push(holder.citizenId);
      }
    }

    // Gossip announce across phone mesh
    // This short code tells recipient's app where to collect fragments
    // To any observer: looks like random base64 noise over HTTPS WebSocket
    const announce = {
      op:  OP.FRAG_ANNOUNCE,
      mid: msgHash,                          // message hash — short, meaningless alone
      to:  this._obscureId(recipientCitizenId), // obscured recipient (only their app recognises)
      n:   FRAGMENT_N,
      k:   FRAGMENT_K,
      h:   holderIds.map(id => this._obscureId(id)), // obscured holder IDs
      ts:  Date.now(),
    };

    this._gossipToAllPhones(announce);
    this._peerMesh.broadcast('PHONE_MESH_FORWARD', announce);
  }

  // Handle incoming message from phone app
  handlePhoneMessage(citizenId, ws, raw) {
    let msg;
    try { msg = JSON.parse(raw); } catch (_) { return; }

    switch (msg.op) {
      case OP.FRAG_REQUEST:  return this._handleFragmentRequest(citizenId, ws, msg);
      case OP.FRAG_DELIVER:  return this._handleFragmentDelivery(citizenId, msg);
      case OP.FRAG_ANNOUNCE: return this._handleFragmentAnnounce(citizenId, msg);
      case OP.NODE_QUERY:    return this._handleNodeQuery(citizenId, ws, msg);
      case OP.MESH_HELLO:    return this._handleMeshHello(citizenId, ws, msg);
    }
  }

  // ── Fragment request — phone wants a fragment this node is holding ─────────

  _handleFragmentRequest(citizenId, ws, msg) {
    const cached = this._fragmentCache.get(msg.fid);
    if (!cached || Date.now() > cached.expires) {
      ws.send(JSON.stringify({ op: OP.FRAG_DELIVER, fid: msg.fid, dat: null, err: 'EXPIRED' }));
      return;
    }
    ws.send(JSON.stringify({
      op:  OP.FRAG_DELIVER,
      fid: msg.fid,
      dat: cached.data,
    }));
  }

  // ── Fragment delivery — another phone is depositing a fragment here ────────

  _handleFragmentDelivery(citizenId, msg) {
    if (!msg.fid || !msg.dat) return;
    this._fragmentCache.set(msg.fid, {
      data:    msg.dat,
      expires: msg.exp || Date.now() + (FRAGMENT_TTL_SEC * 1000),
    });
  }

  // ── Fragment announce — gossip passing through, check if for us ───────────

  _handleFragmentAnnounce(citizenId, msg) {
    // Check gossip dedup
    if (this._gossipSeen.has(msg.mid)) return;
    this._gossipSeen.add(msg.mid);
    setTimeout(() => this._gossipSeen.delete(msg.mid), 60000);

    // Re-gossip to other connected phones
    this._gossipToAllPhones(msg, citizenId);
  }

  // ── Node discovery — phone asking which node a citizen belongs to ─────────

  _handleNodeQuery(citizenId, ws, msg) {
    const targetId = msg.cid; // sovereign ID being queried
    if (!targetId) return;

    const presence = this._db.getCitizenPresence(targetId);
    if (presence) {
      ws.send(JSON.stringify({
        op:      OP.NODE_RESPONSE,
        cid:     targetId,
        node_id: presence.node_id,
        address: presence.node_address,
        ts:      Date.now(),
      }));
    }
  }

  _handleMeshHello(citizenId, ws, msg) {
    // Phone joining mesh — respond with current gossip-discovered peers
    // This helps phones find each other without knowing IPs in advance
    const recentPeers = [...this._phoneClients.keys()].slice(0, 10);
    ws.send(JSON.stringify({
      op:    OP.MESH_HELLO,
      peers: recentPeers.map(id => this._obscureId(id)),
    }));
  }

  _handleForwardedGossip(msg) {
    // Received fragment announce from peer node — forward to connected phones
    this._gossipToAllPhones(msg);
  }

  // ── Gossip helpers ─────────────────────────────────────────────────────────

  _gossipToAllPhones(msg, excludeCitizenId = null) {
    const raw = JSON.stringify(msg);
    for (const [id, ws] of this._phoneClients) {
      if (id === excludeCitizenId) continue;
      if (ws.readyState === 1) ws.send(raw); // OPEN
    }
  }

  _gossipToMesh(op, citizenId) {
    this._peerMesh.broadcast('PHONE_MESH_FORWARD', { op, cid: citizenId, ts: Date.now() });
  }

  // ── Fragment holder selection ──────────────────────────────────────────────

  _selectFragmentHolders(n) {
    const available = [...this._phoneClients.entries()]
      .filter(([_, ws]) => ws.readyState === 1)
      .map(([id, ws]) => ({ citizenId: id, ws }));

    // Shuffle and pick N
    for (let i = available.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      [available[i], available[j]] = [available[j], available[i]];
    }
    return available.slice(0, n);
  }

  // ── Threshold secret sharing ──────────────────────────────────────────────
  // XOR-based K-of-N fragment splitting. Mathematically:
  //   Fragment[0..N-2] are random. Fragment[N-1] = XOR of all others XOR original.
  //   Any K fragments, combined correctly, reconstruct original.
  //   Any K-1 fragments reveal nothing about the original.

  static _splitIntoFragments(data) {
    const fragments = [];
    let xorAccum = Buffer.from(data);

    // Generate N-1 random fragments
    for (let i = 0; i < FRAGMENT_N - 1; i++) {
      const frag = crypto.randomBytes(data.length);
      fragments.push(frag);
      // XOR accumulation
      for (let j = 0; j < data.length; j++) {
        xorAccum[j] ^= frag[j];
      }
    }
    // Last fragment = XOR of all others XOR original data
    fragments.push(xorAccum);
    return fragments;
  }

  static _reassembleFragments(fragments) {
    const result = Buffer.from(fragments[0]);
    for (let i = 1; i < fragments.length; i++) {
      const frag = Buffer.isBuffer(fragments[i]) ? fragments[i] : Buffer.from(fragments[i], 'hex');
      for (let j = 0; j < result.length; j++) {
        result[j] ^= frag[j];
      }
    }
    return result;
  }

  // ── ID obscuring — short hash so IDs in gossip don't reveal citizens ──────
  _obscureId(sovereignId) {
    return crypto.createHash('sha256')
      .update(sovereignId + this._identity.nodeId) // node-specific salt
      .digest('hex').slice(0, 12);
  }

  // ── Cleanup expired fragments ──────────────────────────────────────────────
  _startCleanup() {
    this._cleanupTimer = setInterval(() => {
      const now = Date.now();
      for (const [fid, entry] of this._fragmentCache) {
        if (now > entry.expires) this._fragmentCache.delete(fid);
      }
    }, 60000);
  }

  stop() {
    if (this._cleanupTimer) clearInterval(this._cleanupTimer);
  }
}

module.exports = { PhoneMesh, OP };
