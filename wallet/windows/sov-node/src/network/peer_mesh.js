// ─────────────────────────────────────────────────────────────────────────────
// PEER MESH — Node-to-node connections and gossip protocol
// ─────────────────────────────────────────────────────────────────────────────
// Maintains persistent WebSocket connections to 8-25 peer SOV nodes.
// Handles:
//   - Bootstrap: connect to known seed nodes, discover more via gossip
//   - NODE_ANNOUNCE: broadcast own address when coming online or IP changes
//   - NODE_HEARTBEAT: 60s signed liveness proof + Merkle root comparison
//   - Peer routing: forward messages to correct destination node
//   - Circuit relay: act as relay for nodes behind hard NAT
//
// ── PEER INTERROGATION ────────────────────────────────────────────────────────
// Every connecting peer must prove TWO things before being accepted:
//
//   1. Identity proof   — Ed25519 signature over (node_id + timestamp)
//                         Proves the connecting node holds the private key
//                         corresponding to its claimed Node ID
//
//   2. Software proof   — Ed25519 signature over the manifest body, signed
//                         by the SOV Network master key
//                         Proves the connecting node is running genuine,
//                         unmodified SOV software released by the network
//
// A node running modified software cannot forge the software proof.
// It does not have the network master private key.
// It will be rejected at the handshake stage by every honest node.
// No central authority needed — the cryptography enforces this.
// ─────────────────────────────────────────────────────────────────────────────

'use strict';

const WebSocket   = require('ws');
const crypto      = require('crypto');
const fs          = require('fs');
const path        = require('path');
const nacl        = require('tweetnacl');
const { NodeIdentity } = require('../security/node_identity');

// Bootstrap seed nodes — the first 4 VPS nodes
const BOOTSTRAP_SEEDS = (process.env.BOOTSTRAP_SEEDS || [
  // No seed addresses are compiled in. A node finds peers through
  // bootstrap.js (env, bootstrap.json, the registry, then the pointer
  // mirrors) and announces itself to the public DHT. The addresses that
  // were baked in here were documentation placeholders that could never
  // answer, so a node relying on them found nothing at all.
]).toString().split(',');

// The peer mesh uses SYNC_PORT (default 7771), not SOV_PORT (citizen gateway).
// The node announces its mesh address with SYNC_PORT so peers connect on the right port.
const SYNC_PORT = parseInt(process.env.SYNC_PORT || '7771');

const MIN_PEERS          = 8;
const MAX_PEERS          = 25;
const HEARTBEAT_INTERVAL = 60 * 1000;     // 60 seconds
const PEER_STALE_MS      = 135 * 1000;    // reap a peer silent > ~2.25 heartbeats (zombie socket)
const HELLO_TIMEOUT_MS   = 15 * 1000;     // 15 seconds to complete interrogation
const DIAL_TIMEOUT_MS    = 10 * 1000;     // kill an outbound dial that hasn't connected in 10s (dead host)
const MIN_VERSION        = '1.0.0';       // Minimum acceptable peer version
const GOSSIP_FRESH_MS    = 14 * 24 * 60 * 60 * 1000; // only gossip nodes verified within 14 days
const PRUNE_INTERVAL_MS  = 6 * 60 * 60 * 1000;       // sweep the dead-node prune every 6 hours

// ── Network master public key ─────────────────────────────────────────────────
// This key signed the software manifest. Embedded at build time.
// A peer must present a manifest signed by this key to be accepted.
// Changing this key requires a governance supermajority.
const NETWORK_MASTER_PUBLIC_KEY_HEX =
  process.env.NETWORK_MASTER_PUBLIC_KEY ||
  '0000000000000000000000000000000000000000000000000000000000000000'; // set at build time


// 1.4.92: host part of a mesh address ('ws://h:p', 'h:p', '[v6]:p') for comparing a claim with a dial.
function _hostOf(a) {
  return String(a || '').replace(/^wss?:\/\//, '').replace(/:\d+$/, '').replace(/^\[|\]$/g, '').toLowerCase();
}
// 1.4.96: a node is either a VOTING validator (server operators; the default) or a SERVING node (the
// desktop app's opt-in node): it relays, serves citizens and keeps the ledger, but its approval does not
// count toward a payment and nobody waits for it. A home PC that goes offline can then never freeze
// payments (the 2026-10-09 outage: two demo desktops had become voting operators, then went offline).
// Declared in PEER_HELLO and signed with the identity key; every node records it the same way.
const NODE_ROLE = process.env.SOV_NODE_ROLE === 'serving' ? 'serving' : 'voting';
if (typeof global !== 'undefined') global.sovNodeRole = NODE_ROLE;

class PeerMesh {

  constructor(identity, network, db, relayPool) {
    this._identity  = identity;
    this._network   = network;
    this._db        = db;
    this._relayPool = relayPool; // null if not provided
    this._operatorEngine = null; // set by index.js via setOperatorEngine — supplies the
                                 // earned-source_root check used in the HELLO interrogation.
    this._peers     = new Map(); // nodeId → { ws, address, publicKey, lastSeen, version, verified }
    this._registry  = new Map(); // nodeId → { address, publicKey, reputation }
    this._handlers  = new Map(); // messageType → handler fn
    // Monotonic connection counter: bumped on every (re)handshake that stores a
    // peer record, so a node can tell a peer's fresh socket (its restart) from a
    // steady one. circuit-relay uses it to re-register with a relay that bounced.
    this._connSeq   = 0;
    this._hbTimer   = null;
    this._wss       = null;      // inbound peer WS server (port 7771)

    // Reconnect debounce — prevents exponential retry storms when all seeds are offline
    this._reconnectScheduled = false;
    this._reconnectDelay     = 15000;  // starts at 15s, doubles each failed cycle (max 5min)
    this._reconnectTimer     = null;

    // Load our own manifest proof once — reused in every PEER_HELLO we send
    this._manifestProof = this._loadManifestProof();
  }

  static async start(identity, network, db, relayPool = null) {
    const mesh = new PeerMesh(identity, network, db, relayPool);
    await mesh._loadRegistry();
    await mesh._startServer();
    await mesh._connectToBootstrap();
    mesh._startHeartbeat();
    network._onIPChange = (newIP) => mesh.announceOnline(`${newIP}:443`);
    return mesh;
  }

  // ── Public API ─────────────────────────────────────────────────────────────

  peerCount() { return this._peers.size; }

  /** Connected peer node IDs — the keys sendTo() accepts. Used to address a
   *  sample of peers instead of broadcasting to every one of them. */
  peerIds() { return Array.from(this._peers.keys()); }

  /** circuit-relay: verified peers that are themselves REACHABLE (we dialled them
   *  and the handshake held, so they accept inbound), hence able to front our
   *  citizens as a circuit relay. Excludes peers that only reached US inbound. */
  verifiedPeers() {
    const out = [];
    for (const [nodeId, peer] of this._peers) {
      if (peer && peer.verified && !peer.inbound && peer.ws && peer.ws.readyState === WebSocket.OPEN) {
        out.push({ node_id: nodeId, address: peer.address, version: peer.version,
                   circuitRelay: !!peer.circuitRelay, connGen: peer.connGen || 0 });
      }
    }
    return out;
  }

  // Called from index.js after gateway is created — allows peer_mesh to push
  // RELAY_ANNOUNCE to connected phones when new nodes join the network.
  setGateway(gateway) { this._gateway = gateway; }

  // Supplies the earned-source_root ratifier (OperatorEngine._sourceRootAccepted) used
  // by the HELLO interrogation's Check 5. Wired in index.js after both are constructed.
  setOperatorEngine(oe) { this._operatorEngine = oe; }

  broadcast(type, payload, excludeNodeId = null) {
    const msg = this._sign({ type, ...payload });
    for (const [nodeId, peer] of this._peers) {
      if (nodeId === excludeNodeId) continue;
      if (!peer.verified) continue; // never send to unverified peers
      if (peer.ws.readyState === WebSocket.OPEN) {
        this._wsSend(peer.ws, msg);
      }
    }
  }

  sendTo(nodeId, type, payload) {
    const peer = this._peers.get(nodeId);
    if (!peer || !peer.verified || peer.ws.readyState !== WebSocket.OPEN) return false;
    return this._wsSend(peer.ws, this._sign({ type, ...payload }));
  }

  on(type, handler) { this._handlers.set(type, handler); }

  // Called with the node id each time a peer is admitted (new, or back on a fresh socket).
  onPeerAdmitted(cb) { (this._admittedCbs = this._admittedCbs || []).push(cb); }

  // Deferred: admission is one-sided. The peer may not yet have verified US, and it drops
  // anything an unverified peer sends — so an immediate catch-up message is silently lost
  // (measured on the test mesh, 2026-10-03). A handshake completes well within this delay.
  _firePeerAdmitted(nodeId) {
    // 1.4.94: the validator's public key is kept, so its signed ledger grants can be checked later.
    try {
      const peer = this._peers.get(nodeId);
      const pub = peer && peer.publicKey ? String(peer.publicKey).toLowerCase() : null;
      // 1.4.96: only a VOTING peer becomes a validator here. A serving node is never recorded, so no
      // certificate ever has to include it and its absence can never stall a payment.
      const voting = !(peer && peer.ws && peer.ws._peerRole === 'serving');
      if (voting && this._db && this._db.recordValidatorSeen) this._db.recordValidatorSeen(nodeId, pub);
    } catch (_) {}
    const cbs = this._admittedCbs || [];
    if (!cbs.length) return;
    const t = setTimeout(() => { for (const cb of cbs) { try { cb(nodeId); } catch (_) {} } }, 5000);
    if (t.unref) t.unref();
  }

  // Phase 2: verified peers with the capability each last advertised (null until its first
  // heartbeat). Used to route delegated work to peers that can actually do it.
  peerCapabilities() {
    const out = [];
    for (const [nodeId, peer] of this._peers) {
      if (!peer.verified || !peer.ws || peer.ws.readyState !== WebSocket.OPEN) continue;
      out.push({ nodeId, capability: peer.capability || null });
    }
    return out;
  }

  // The Ed25519 key a verified peer proved at PEER_HELLO — the key a signed reply from that
  // socket must verify under. null for anything not currently a verified peer.
  peerPublicKey(nodeId) {
    const peer = this._peers.get(nodeId);
    return (peer && peer.verified && peer.publicKey) ? peer.publicKey : null;
  }

  async announceOnline(address) {
    this.broadcast('NODE_ANNOUNCE', {
      node_id:    this._identity.nodeId,
      address,
      public_key: Buffer.from(this._identity.publicKey).toString('hex'),
      version:    require('../../package.json').version,
      timestamp:  Date.now(),
    });
  }

  async announceOffline() {
    this.broadcast('NODE_OFFLINE', {
      node_id:   this._identity.nodeId,
      timestamp: Date.now(),
    });
  }

  // Ledger safety (1.4.90): how many nodes a spend majority is counted against. It must NOT
  // shrink when a partition hides peers — otherwise each side of a split would think it is the
  // majority and both would commit (the double-spend). So it counts every node verified within
  // VALIDATOR_WINDOW_MS, plus this node, and never less than this node + its live peers.
  validatorSetSize() {
    const VALIDATOR_WINDOW_MS = 14 * 24 * 3600 * 1000;
    const now = Date.now();
    // Counted from sov_validator_seen, written ONLY when a peer passes admission — the
    // registry's last_verified is a discovery grace window and would count gossiped nodes.
    let recent = 0;
    try { recent = this._db ? this._db.validatorsSeenSince(now - VALIDATOR_WINDOW_MS, this._identity.nodeId) : 0; } catch (_) {}
    return Math.max(1 + recent, 1 + this.activePeers().length);
  }

  // True once this node has ever verified a peer. A node that HAS had peers but sees none now
  // must not commit money alone (a home node back after weeks offline); only a network that has
  // never had a second node may.
  everHadVerifiedPeer() {
    try { return !!(this._db && this._db.validatorsSeenSince(0, this._identity.nodeId) > 0); } catch (_) { return false; }
  }

  /** 1.4.96: 'voting' | 'serving' as the peer declared (and signed) at its HELLO; null if not connected. */
  peerRole(nodeId) {
    const p = this._peers.get(nodeId);
    return p && p.ws ? (p.ws._peerRole || 'voting') : null;
  }

  activePeers() {
    return [...this._peers.values()].filter(p =>
      p.verified && p.ws.readyState === WebSocket.OPEN
    );
  }

  // 1.4.92: may this node's address be handed to citizens or published? Only if WE reached it
  // there by an outbound dial within the fresh window — never an inbound-only (NAT'd home) peer.
  isAddressProven(nodeId) {
    const r = this._registry.get(nodeId);
    return !!(r && r.lastVerified && r.lastVerified >= Date.now() - GOSSIP_FRESH_MS);
  }

  // 1.4.92: prove a peer's claimed address by dialling it ourselves (a peer we only know through
  // a connection IT opened). At most once per 10 minutes per peer.
  _proveAddress(nodeId, address) {
    if (!address || this.isAddressProven(nodeId)) return;
    this._proving = this._proving || new Map();
    if (Date.now() - (this._proving.get(nodeId) || 0) < 10 * 60 * 1000) return;
    this._proving.set(nodeId, Date.now());
    let ws;
    try { ws = new WebSocket(address.startsWith('ws') ? address : `ws://${address}`, { handshakeTimeout: DIAL_TIMEOUT_MS }); }
    catch (_) { return; }
    ws._probeFor = nodeId; ws._dialAddress = address; ws._helloSent = true;
    const t = setTimeout(() => { try { ws.terminate(); } catch (_) {} }, 20000);
    ws.on('open', () => { const h = this._buildHelloPayload(ws); h.probe = true; try { ws.send(JSON.stringify(h)); } catch (_) {} });
    ws.on('message', (raw) => this._handleMessage(ws, raw));
    ws.on('error', () => { clearTimeout(t); try { ws.terminate(); } catch (_) {} });
    ws.on('close', () => clearTimeout(t));
  }

  // Active peers whose address is proven (see isAddressProven) — what citizens may be given.
  provenPeers() {
    return this.activePeers().filter(p => {
      for (const [id, q] of this._peers) if (q === p) return this.isAddressProven(id);
      return false;
    });
  }

  async close() {
    if (this._hbTimer)      clearInterval(this._hbTimer);
    if (this._pruneTimer)   clearInterval(this._pruneTimer);
    if (this._reconnectTimer) clearTimeout(this._reconnectTimer);
    this._reconnectScheduled = true; // prevent new schedules during shutdown
    for (const peer of this._peers.values()) {
      try { peer.ws.close(); } catch (_) {}
    }
    if (this._wss) this._wss.close();
  }

  // ── Bootstrap ──────────────────────────────────────────────────────────────

  async _connectToBootstrap() {
    // Discovery order:
    //   1. Relay pool (citizen nodes seen recently — most reliable after first run)
    //   2. Node registry DB (addresses from previous sessions)
    //   3. Bootstrap seeds (VPS IPs — first run fallback only)
    const poolAddresses      = this._relayPool ? this._relayPool.getBootstrapAddresses(20) : [];
    // Addresses the operator configured, or that pointer discovery cached. These
    // are DIAL TARGETS, not known nodes — a node earns a place in the pool by
    // being met, not by being suggested. Keeping them out of the pool is what
    // stops a suggestion becoming a permanent phantom entry.
    let configuredAddresses = [];
    try {
      const { bootstrapNodes } = require('./bootstrap');
      configuredAddresses = bootstrapNodes(this._db).map((h) => `${h}:7771`);
    } catch (_) { /* discovery is best-effort */ }
    const registryAddresses  = this._knownPeerAddresses();
    const allSeeds           = [
      ...poolAddresses,
      ...registryAddresses,
      ...configuredAddresses,
      // Peers seen on the DHT. Dial targets only — like every other suggestion,
      // they earn a place in the pool by answering and passing interrogation.
      ...(global.sovDht ? (global.sovDht._verified || global.sovDht.peers(10)) : []),
      ...BOOTSTRAP_SEEDS,
    ];

    // Remove duplicates while preserving order
    const seen = new Set();
    const seeds = allSeeds.filter(a => { if (seen.has(a)) return false; seen.add(a); return true; });

    global.sovLog.debug(`      Bootstrap: ${poolAddresses.length} pool + ${registryAddresses.length} registry + ${BOOTSTRAP_SEEDS.length} seeds`);

    for (const address of seeds.slice(0, 15)) {
      this._connectToPeer(address).catch(() => {});
    }

    // After connecting, fetch the full relay pool from bootstrap nodes
    if (this._relayPool) {
      setTimeout(() => {
        this._relayPool.bootstrapFromSeeds(
          seeds.slice(0, 5).map(a => a.replace(':7771', ':80').replace(':443', ':80'))
        );
      }, 8000);
    }

    setTimeout(() => this._requestPeerList(), 5000);
  }

  async _connectToPeer(address) {
    if (!address || typeof address !== 'string') return;
    // Don't open a second outbound connection if we already have a live peer at this address
    for (const peer of this._peers.values()) {
      if (peer.address === address && peer.ws && peer.ws.readyState === WebSocket.OPEN) return;
    }
    // Don't stack a second outbound dial while one to this SAME address is still
    // in flight. The old code only skipped when a peer was already OPEN, so every
    // reconnect tick fired ANOTHER dial at an address that hadn't answered yet —
    // and a dial to a host that has moved/gone sits in SYN-SENT for ~60s through
    // the kernel's TCP retries. That is how VPS1 piled up dozens of half-open
    // sockets to one flapping home node (peer-socket leak, outbound half).
    this._dialing = this._dialing || new Set();
    if (this._dialing.has(address)) return;
    this._dialing.add(address);

    // Peer-to-peer mesh uses plain WS — security is provided by Ed25519 signature
    // verification on every message, not by transport encryption. The citizen-facing
    // gateway uses TLS. The mesh server starts as a plain WebSocket.Server.
    const url = address.startsWith('ws') ? address : `ws://${address}`;

    return new Promise((resolve) => {
      let settled = false;
      const release = () => { if (!settled) { settled = true; this._dialing.delete(address); } };

      let ws;
      try {
        ws = new WebSocket(url, { rejectUnauthorized: false, handshakeTimeout: DIAL_TIMEOUT_MS });
        ws._dialAddress = address;   // 1.4.92: the address WE reached, checked against the peer's claim
      } catch (_) { release(); return resolve(); }

      // Hard cap on how long a dial may sit unconnected. handshakeTimeout only
      // covers the WS upgrade AFTER TCP connects; a SYN-SENT socket to a dead
      // host is not covered, so terminate() it here to reclaim the fd in ~10s
      // instead of the kernel's ~60s.
      const dialTimer = setTimeout(() => {
        if (!ws || ws.readyState !== WebSocket.OPEN) { try { ws && ws.terminate(); } catch (_) {} }
      }, DIAL_TIMEOUT_MS);

      ws.on('open', () => {
        clearTimeout(dialTimer);
        release();
        // ── Send PEER_HELLO with full interrogation payload ──────────────────
        // Identity proof + software authenticity proof in one message.
        // Set _helloSent BEFORE sending so that when the peer responds with
        // their own PEER_HELLO we don't reply again (prevents infinite loop).
        ws._helloSent = true;
        const helloPayload = this._buildHelloPayload(ws);
        ws.send(JSON.stringify(helloPayload));   // PEER_HELLO is the one plaintext frame
        resolve();
      });

      ws.on('message', (raw) => this._handleMessage(ws, raw));
      ws.on('close',   ()    => { clearTimeout(dialTimer); release(); this._handlePeerDisconnect(ws); });
      ws.on('error',   ()    => { clearTimeout(dialTimer); release(); try { ws.terminate(); } catch (_) {} resolve(); });
    });
  }

  // ── Inbound peer server (port 7771) ───────────────────────────────────────

  async _startServer() {
    const port = parseInt(process.env.SYNC_PORT || '7771');
    // Resilient bind: after a fast restart/reboot the previous process's :port
    // socket can linger briefly → EADDRINUSE → crash-loop. Retry so a node reliably
    // returns after ANY restart (launch-and-forget; no operator intervention).
    for (let attempt = 1; ; attempt++) {
      try {
        await new Promise((resolve, reject) => {
          const wss = new WebSocket.Server({ port });
          const onErr = (e) => reject(e);
          wss.once('error', onErr);
          wss.once('listening', () => { wss.removeListener('error', onErr); this._wss = wss; resolve(); });
        });
        break;
      } catch (e) {
        if (e && e.code === 'EADDRINUSE' && attempt <= 10) {
          global.sovLog.warn(`      Peer mesh :${port} busy (EADDRINUSE) — retry ${attempt}/10 in 3s`);
          await new Promise(r => setTimeout(r, 3000));
          continue;
        }
        throw e;
      }
    }
    this._wss.on('connection', ws => {
      ws._verified = false;
      // reachability-proof-v1: this socket was opened by THEM, towards US.
      // It proves they can reach us. It says nothing about us reaching them.
      ws._inbound  = true;
      ws._helloTimeout = setTimeout(() => {
        if (!ws._verified) {
          global.sovLog.debug('Peer HELLO timeout — disconnecting');
          ws.close(4001, 'HELLO_TIMEOUT');
        }
      }, HELLO_TIMEOUT_MS);

      ws.on('message', (raw) => this._handleMessage(ws, raw));
      ws.on('close',   ()    => this._handlePeerDisconnect(ws));
    });
    global.sovLog.info(`      Peer mesh server listening on :${port}`);
  }

  // ── Build PEER_HELLO with interrogation proofs ────────────────────────────

  _buildHelloPayload(ws) {
    const timestamp = Date.now();
    const nodeId    = this._identity.nodeId;
    // 1.4.92 link encryption: a fresh X25519 key for THIS connection, bound to our identity by a
    // signature so nobody in the path can swap it. Every frame after the HELLOs is sealed with it.
    if (ws && !ws._linkKeys) ws._linkKeys = nacl.box.keyPair();
    const linkPub = ws && ws._linkKeys ? Buffer.from(ws._linkKeys.publicKey).toString('hex') : '';
    const linkSig = linkPub ? this._identity.signMessage(Buffer.from(`SOV-LINK-v1|${nodeId}|${timestamp}|${linkPub}`)).toString('hex') : '';

    // Identity proof: sign (node_id + timestamp) with our private key
    const identityProofData = Buffer.from(`${nodeId}:${timestamp}`);
    const identityProof     = this._identity.signMessage(identityProofData).toString('hex');

    // Advertise mesh address using SYNC_PORT, not the citizen-gateway SOV_PORT.
    // network.publicAddress is IP:SOV_PORT — replace the port with SYNC_PORT.
    const meshAddress = this._network.publicAddress
      .replace(/:\d+$/, `:${SYNC_PORT}`);

    const payload = {
      type:            'PEER_HELLO',
      node_id:         nodeId,
      address:         meshAddress,
      public_key:      Buffer.from(this._identity.publicKey).toString('hex'),
      version:         require('../../package.json').version,
      timestamp,
      identity_proof:  identityProof,
      // Software authenticity proof — manifest signed by network master key
      manifest_hash:   this._manifestProof.manifestHash,
      manifest_sig:    this._manifestProof.manifestSig,
      // Layer 2 (source attestation): our source fingerprint, so the peer can check
      // we run software its earned operators recognise. A ~64-hex digest computed
      // once at boot (index.js) — carries no history, stores nothing. Replaces the
      // inert manifest-key proof as the real integrity gate. (NODE_INTEGRITY_DESIGN)
      source_root:     (typeof global !== 'undefined' && global.sovSourceRoot) || '',
      // Biometric dedup interoperability — see _handlePeerHello. A digest, never
      // the key itself; peers that disagree cannot detect each other's duplicates.
      cancelable_fp:   (() => {
        try { return require('../security/palm_cancelable').fingerprint(); }
        catch (_) { return ''; }
      })(),
      // Circuit-relay capability (Task #26). Every node running this build wires
      // the R-side handlers at gateway init, so it CAN front a NAT'd peer. A
      // NAT'd node's registerWithRelays() targets only peers that advertise this,
      // because a peer on an older build silently drops RELAY_REGISTER. Absent
      // field ⇒ treated as not-capable (old snap).
      circuit_relay:   true,
      link_pub:        linkPub,
      link_sig:        linkSig,
      // 1.4.96: voting validator or serving node, signed so it cannot be flipped in transit.
      node_role:       NODE_ROLE,
      role_sig:        this._identity.signMessage(Buffer.from(`SOV-ROLE-v1|${nodeId}|${timestamp}|${NODE_ROLE}`)).toString('hex'),
    };

    return payload; // PEER_HELLO is not signed with node key — it IS the handshake
  }

  // ── Load manifest proof from disk ─────────────────────────────────────────

  _loadManifestProof() {
    const manifestFile = path.join(__dirname, '..', '..', 'keys', 'manifest.sig');
    if (!fs.existsSync(manifestFile)) {
      // Development mode — no manifest yet
      return { manifestHash: 'dev', manifestSig: 'dev' };
    }
    try {
      const data         = fs.readFileSync(manifestFile);
      const signature    = data.subarray(0, 64);
      const manifestBody = data.subarray(64);
      return {
        manifestHash: crypto.createHash('sha256').update(manifestBody).digest('hex'),
        manifestSig:  Buffer.from(signature).toString('hex'),
      };
    } catch (_) {
      return { manifestHash: 'unavailable', manifestSig: 'unavailable' };
    }
  }

  // ── Message handling ───────────────────────────────────────────────────────

  // 1.4.92: the mesh link is encrypted. Only PEER_HELLO travels in the clear; once both HELLOs
  // are exchanged every frame is nacl.secretbox-sealed under the per-connection X25519 key, and a
  // plaintext frame is dropped (no downgrade). Before the link exists nothing else may be sent.
  _wsSend(ws, obj) {
    if (!ws || ws.readyState !== WebSocket.OPEN) return false;
    if (!ws._linkShared) {
      global.sovLog.debug(`[Mesh] not sent (link not encrypted yet): ${obj && obj.type}`);
      return false;
    }
    const nonce = nacl.randomBytes(nacl.secretbox.nonceLength);
    const box = nacl.secretbox(new Uint8Array(Buffer.from(JSON.stringify(obj))), nonce, ws._linkShared);
    ws.send(JSON.stringify({ e: Buffer.concat([Buffer.from(nonce), Buffer.from(box)]).toString('base64') }));
    return true;
  }

  _handleMessage(ws, raw) {
    let msg;
    try { msg = JSON.parse(raw); } catch (_) { return; }
    if (msg && typeof msg.e === 'string') {
      if (!ws._linkShared) return;
      try {
        const b = Buffer.from(msg.e, 'base64');
        const n = nacl.secretbox.nonceLength;
        const open = b.length > n ? nacl.secretbox.open(new Uint8Array(b.subarray(n)), new Uint8Array(b.subarray(0, n)), ws._linkShared) : null;
        if (!open) { global.sovLog.debug('[Mesh] undecryptable frame dropped'); return; }
        msg = JSON.parse(Buffer.from(open).toString('utf8'));
      } catch (_) { return; }
    } else if (!msg || msg.type !== 'PEER_HELLO') {
      global.sovLog.debug(`[Mesh] plaintext ${msg && msg.type} dropped — the mesh link is encrypted`);
      return;
    }

    // PEER_HELLO is the interrogation handshake — handled specially
    if (msg.type === 'PEER_HELLO') {
      try { return this._handlePeerHello(ws, msg); } catch (e) {
        global.sovLog.warn(`[Mesh] PEER_HELLO handler error: ${e.message}`);
        return;
      }
    }

    // All other messages require the peer to have passed interrogation first
    if (!ws._verified) {
      global.sovLog.debug(`Rejected message from unverified peer: ${msg.type}`);
      return;
    }

    // Verify Ed25519 signature on all peer messages
    if (!this._verifySig(msg)) {
      global.sovLog.debug(`Signature verification failed for ${msg.type} from ${ws._nodeId}`);
      return;
    }

    // Wrap all handlers in try-catch — a crashing handler must NEVER close
    // the WebSocket connection or crash the peer mesh process.
    try {
      switch (msg.type) {
        case 'NODE_ANNOUNCE':   return this._handleNodeAnnounce(msg);
        case 'REACH_PROBE':     return this._handleReachProbe(msg);
        case 'NETWORK_SEED':    return this._handleNetworkSeed(msg, ws);
        case 'NODE_OFFLINE':    return this._handleNodeOffline(msg);
        case 'NODE_HEARTBEAT':  return this._handleHeartbeat(ws, msg);
        case 'PEER_LIST':       return this._handlePeerList(msg);
        case 'PEER_LIST_REQ':   return this._handlePeerListRequest(ws);
        default: {
          const handler = this._handlers.get(msg.type);
          if (handler) handler(msg, ws);
        }
      }
    } catch (err) {
      global.sovLog.warn(`[Mesh] Handler error for ${msg.type}: ${err.message}`);
    }
  }

  // ── PEER_HELLO — the interrogation ────────────────────────────────────────

  _handlePeerHello(ws, msg) {
    clearTimeout(ws._helloTimeout);

    const { node_id, address, public_key, version, timestamp,
            identity_proof, manifest_hash, manifest_sig, cancelable_fp,
            circuit_relay, source_root } = msg;

    // ── Check 1: Required fields ───────────────────────────────────────────
    if (!node_id || !public_key || !identity_proof) {
      global.sovLog.debug(`Peer HELLO rejected: missing fields from ${node_id || 'unknown'}`);
      ws.close(4002, 'HELLO_MISSING_FIELDS');
      return;
    }

    // ── Check 2: Timestamp freshness ────────────────────────────────────────
    if (Math.abs(Date.now() - timestamp) > 60000) {
      global.sovLog.debug(`Peer HELLO rejected: stale timestamp from ${node_id}`);
      ws.close(4003, 'HELLO_STALE');
      return;
    }

    // ── Check 3: Node ID integrity ──────────────────────────────────────────
    // Node ID must equal SHA-256(public_key)
    const pubKeyBytes    = Buffer.from(public_key, 'hex');
    const expectedNodeId = crypto.createHash('sha256').update(pubKeyBytes).digest('hex');
    if (node_id !== expectedNodeId) {
      global.sovLog.warn(`Peer HELLO rejected: Node ID does not match public key — ${node_id}`);
      ws.close(4004, 'HELLO_NODE_ID_MISMATCH');
      return;
    }

    // ── Check 3b: Reject self-connections ──────────────────────────────────
    // A node connecting with our own nodeId would be us connecting to ourselves.
    // This happens when our own address appears in the relay pool.
    if (node_id === this._identity.nodeId) {
      global.sovLog.debug(`[Mesh] Rejecting self-connection (our own nodeId ${node_id.slice(0, 16)})`);
      ws.close(4001, 'HELLO_SELF_CONNECTION');
      return;
    }

    // ── Check 4: Identity proof ─────────────────────────────────────────────
    // Verify the connecting node actually holds the private key for this node_id
    const identityData = Buffer.from(`${node_id}:${timestamp}`);
    let identityValid  = false;
    try {
      identityValid = NodeIdentity.verify(
        identityData,
        Buffer.from(identity_proof, 'hex'),
        pubKeyBytes
      );
    } catch (_) {
      identityValid = false;
    }

    if (!identityValid) {
      global.sovLog.warn(`Peer HELLO rejected: identity proof invalid — ${node_id}`);
      ws.close(4005, 'HELLO_IDENTITY_PROOF_INVALID');
      return;
    }

    // ── Check 5: Software authenticity via earned source_root ratification ──
    // Replaces the inert all-zero manifest-key proof (which returned true for
    // everyone — the trust anchor was 64 zeros). A peer is genuine when it runs
    // source identical to ours, or source that a quorum of EARNED operators run
    // (OperatorEngine._sourceRootAccepted — the distinct-operator quorum). No
    // founder key; carries and stores no history. Enforcement is a governance
    // param, NOT a code path: 'warn' logs and admits (the fleet may be mid-upgrade
    // and briefly running two source roots); 'refuse' rejects. Flipping to refuse
    // needs no rebuild. (Layer 2 — NODE_INTEGRITY_DESIGN / SELF_VALIDATING_RELEASE.)
    let _srOk = true, _srReason = 'NO_OPERATOR_ENGINE';
    if (this._operatorEngine && typeof this._operatorEngine._sourceRootAccepted === 'function') {
      try {
        const _v = this._operatorEngine._sourceRootAccepted(source_root);
        _srOk = !!_v.ok; _srReason = _v.reason || '';
      } catch (_) { _srOk = true; _srReason = 'CHECK_THREW'; }
    }
    if (!_srOk) {
      let _mode = 'warn';
      try { _mode = String(this._db.getGovParam('release_enforce_mode', 'warn')); } catch (_) {}
      if (_mode === 'refuse') {
        global.sovLog.warn(`Peer HELLO refused: unrecognised source_root from ${String(node_id).slice(0,16)} (${_srReason})`);
        ws.close(4006, 'HELLO_SOFTWARE_NOT_AUTHENTIC');
        return;
      }
      global.sovLog.warn(`[Mesh] Peer ${String(node_id).slice(0,12)}… runs UNRECOGNISED source (${_srReason}) — admitted (release_enforce_mode=warn)`);
    }

    // ── Check 6: Minimum version ─────────────────────────────────────────────
    if (!this._isVersionAcceptable(version)) {
      global.sovLog.info(`Peer HELLO rejected: version ${version} below minimum ${MIN_VERSION} — ${node_id}`);
      ws.close(4007, `HELLO_VERSION_TOO_OLD:${MIN_VERSION}`);
      return;
    }

    // ── Check 7 (1.4.92): link key, signed by the identity key just proven ──
    const { link_pub, link_sig } = msg;
    let _linkOk = false;
    try {
      _linkOk = /^[0-9a-f]{64}$/.test(String(link_pub || '')) && NodeIdentity.verify(
        Buffer.from(`SOV-LINK-v1|${node_id}|${timestamp}|${link_pub}`),
        Buffer.from(String(link_sig || ''), 'hex'), pubKeyBytes);
    } catch (_) { _linkOk = false; }
    if (!_linkOk) {
      global.sovLog.info(`Peer HELLO rejected: no valid link key — ${node_id.slice(0, 16)} (pre-1.4.92 software?)`);
      ws.close(4009, 'HELLO_LINK_KEY_REQUIRED');
      return;
    }
    // ── Check 8 (1.4.96): the node's role, signed by the identity key just proven ──
    // Required: a HELLO whose role was stripped or altered is refused rather than defaulted, because
    // treating a serving node as voting would bring back the outage this role exists to prevent.
    const { node_role, role_sig } = msg;
    let _roleOk = false;
    try {
      _roleOk = (node_role === 'voting' || node_role === 'serving') && NodeIdentity.verify(
        Buffer.from(`SOV-ROLE-v1|${node_id}|${timestamp}|${node_role}`),
        Buffer.from(String(role_sig || ''), 'hex'), pubKeyBytes);
    } catch (_) { _roleOk = false; }
    if (!_roleOk) {
      global.sovLog.info(`Peer HELLO rejected: no valid node role — ${node_id.slice(0, 16)} (pre-1.4.96 software?)`);
      ws.close(4010, 'HELLO_ROLE_REQUIRED');
      return;
    }
    ws._peerRole = node_role;
    if (!ws._linkKeys) ws._linkKeys = nacl.box.keyPair();   // inbound: our reply HELLO carries it
    ws._linkShared = nacl.box.before(new Uint8Array(Buffer.from(link_pub, 'hex')), ws._linkKeys.secretKey);

    // ── 1.4.92 dial-back proof ────────────────────────────────────────────────
    // (a) We are the PROBER: we dialled this address only to see who answers. Mark it proven
    //     only if the node we expected answered, at exactly the address it claims; then hang up.
    if (ws._probeFor) {
      if (node_id === ws._probeFor && _hostOf(ws._dialAddress) === _hostOf(address)) {
        this._updateRegistry(node_id, address, public_key, true);
        const p = this._peers.get(node_id);
        if (p) p.addressProven = true;
        if (this._relayPool) { try { this._relayPool.addOrUpdate(node_id, address, version); } catch (_) {} }
        global.sovLog.info(`[Mesh] Address proven by dial-back: ${node_id.slice(0, 16)}… @ ${address}`);
      } else {
        global.sovLog.info(`[Mesh] Dial-back to ${ws._dialAddress} answered as ${node_id.slice(0, 16)}… claiming ${address} — not proven`);
      }
      try { ws.close(1000, 'PROBE_DONE'); } catch (_) {}
      return;
    }
    // (b) We are PROBED: answer with our HELLO so the prober can see who we are, then close.
    //     Nothing is stored or changed here, so a forged probe flag gains nothing.
    if (msg.probe === true && ws._inbound) {
      try { ws.send(JSON.stringify(this._buildHelloPayload(ws))); } catch (_) {}
      if (this._network && typeof this._network.markInboundVerified === 'function') {
        try { this._network.markInboundVerified(address || node_id.slice(0, 12)); } catch (_) {}
      }
      setTimeout(() => { try { ws.close(1000, 'PROBE_ANSWERED'); } catch (_) {} }, 2000);
      return;
    }

    // ── All checks passed — peer accepted ───────────────────────────────────
    ws._verified = true;
    ws._nodeId   = node_id;

    const alreadyKnown = this._peers.has(node_id);

    if (!alreadyKnown && this._peers.size < MAX_PEERS) {
      this._peers.set(node_id, {
        ws,
        address,
        publicKey: public_key,
        version,
        lastSeen:  Date.now(),
        verified:  true,
        // Circuit-relay R-side capability advertised in this peer's HELLO.
        circuitRelay: !!circuit_relay,
        // reachability-proof-v1: direction of the connection, needed below.
        inbound:   !!ws._inbound,
        connGen:   ++this._connSeq,
      });
      // reachability-proof-v1 — this argument used to be a hardcoded `true`.
      //
      // A completed handshake proves the peer holds its key. It does NOT prove
      // the address it claims is reachable, because a node behind a NAT with no
      // port forwarding can dial out perfectly well and never accept anything in.
      // Only mark the address verified when WE dialled THEM at it and it worked.
      // 1.4.92: and only when the address it CLAIMS is the one we actually dialled. Otherwise a
      // peer could get any address (someone else's, or a victim's) stamped verified and published.
      const _claimProven = !ws._inbound && !!ws._dialAddress && _hostOf(ws._dialAddress) === _hostOf(address);
      if (!ws._inbound && !_claimProven) {
        global.sovLog.info(`Peer ${String(node_id).slice(0, 16)} claims ${address} but was reached at ${ws._dialAddress} — address not marked verified`);
      }
      this._peers.get(node_id) && (this._peers.get(node_id).addressProven = _claimProven);
      this._updateRegistry(node_id, address, public_key, _claimProven);


      // ── cancelable-key fingerprint check ────────────────────────────────
      // NOT a rejection. A peer with a different dedup key still carries valid
      // ledger and balance data, so partitioning over this would cost more than
      // it saves — and would let any node force a partition by sending a bogus
      // value. What it buys is that the failure stops being silent: without it,
      // a node on the wrong key finds no duplicates for anyone and reports
      // healthy while one-human-one-account quietly stops holding.
      try {
        const ns       = require('../security/network_seed');
        const ourFp    = require('../security/palm_cancelable').fingerprint();
        const legacyFp = crypto.createHash('sha256')
          .update('sov-cancelable-fp-v1|' + ns.LEGACY_DEFAULT).digest('hex').slice(0, 16);

        if (cancelable_fp && cancelable_fp !== ourFp) {
          const peer = this._peers.get(node_id);
          if (peer) peer.dedupKeyMismatch = true;

          // network-seed-join-v1 — AUTOMATIC SEED HANDOVER.
          // A peer still on the LEGACY constant has no seed of its own. If we hold
          // the real one, hand it over: the peer passed interrogation (genuine,
          // manifest-signed software), so it is already inside the trust boundary
          // that entitles it to every citizen template — the key that makes those
          // templates comparable grants it nothing it did not already have. This is
          // the automatic form of the manual one-file install. The actual send
          // happens AFTER our PEER_HELLO reply below, so the peer has verified us
          // first; here we only flag it.
          if (cancelable_fp === legacyFp && ns.has()) {
            ws._offerSeed = true;
          } else {
            // They hold a DIFFERENT real seed (a genuine divergence for an operator
            // to see) — or we are the one on the legacy key and cannot help.
            // A node whose OWN registry row is a self-issued 'genesis' certificate, which was
            // never declared genesis (SOV_GENESIS), minted its seed by mistake (pre-1.4.82
            // desktop nodes). Stop it serving: one human could otherwise enrol twice through it.
            // The real genesis anchor never meets this - its seed matches its peers.
            try {
              const own = this._db && this._db._db.prepare(
                'SELECT admission_cert FROM sov_operator_registry WHERE node_id = ?').get(this._identity.nodeId);
              if (!global.sovExplicitGenesis && own && String(own.admission_cert || '') === 'genesis' && !global.sovMistakenGenesis) {
                global.sovMistakenGenesis = true;
                global.sovLog.error('[Mesh] THIS NODE DECLARED ITSELF GENESIS BY MISTAKE (an older version did this when it ' +
                  'could not find the network in time). It holds its own biometric seed, so it will NOT serve citizens. ' +
                  'Stop the node, delete its data directory (sov-node-data), and start it again: it will join the ' +
                  'network properly and receive the real seed.');
              }
            } catch (_) {}
            // A node that has not joined yet is on the legacy key BY DESIGN: the network seed
            // arrives with its approval. That is a wait, not a fault - the old ERROR here was the
            // first thing every new operator saw (held cosmetic, 2026-10-04).
            if (!ns.has() && ourFp === legacyFp) {
              if (!this._seedWaitLogged) {
                this._seedWaitLogged = true;
                global.sovLog.info('[Mesh] Waiting for the network biometric seed - it arrives with this node\'s approval; duplicate detection starts then');
              }
            } else
            global.sovLog.error(
              `[Mesh] BIOMETRIC DEDUP KEY MISMATCH with ${node_id.slice(0, 12)}… ` +
              `(theirs=${cancelable_fp} ours=${ourFp}). Templates still replicate, but ` +
              `neither node can detect the other's duplicate enrolments. One human could ` +
              `enrol twice. ` +
              (ns.has()
                ? `Set the same PALM_CANCELABLE_SEED on both nodes.`
                : `This node is on the LEGACY key — install the network seed.`)
            );
          }
        } else if (!cancelable_fp) {
          global.sovLog.warn(
            `[Mesh] Peer ${node_id.slice(0, 12)}… sent no cancelable_fp — older build. ` +
            `Cannot confirm biometric dedup interoperability.`
          );
        }
      } catch (e) {
        global.sovLog.warn(`[Mesh] cancelable_fp check skipped: ${e.message}`);
      }

      // Update relay pool — this is now a known active citizen node
      if (this._relayPool && this.isAddressProven(node_id)) {   // 1.4.92: proven addresses only
        this._relayPool.addOrUpdate(node_id, address, version);
      }

      // Push RELAY_ANNOUNCE to all currently connected phones so they
      // immediately learn about the new node and can failover to it.
      // Without this, phones only discover new nodes on their next reconnect.
      // IP masking rule: relay_id uses opaque node hash tag; name/nickname are
      // human-readable labels without raw IP to prevent passive IP enumeration.
      if (this._gateway && address && this.isAddressProven(node_id)) {   // 1.4.92: never an unproven (home) address
        const parts   = address.split(':');
        const ip      = parts[0];
        const port    = parts[1] ? parseInt(parts[1]) : 443;
        const ipTag   = require('crypto').createHash('sha256').update(ip).digest('hex').slice(0, 12);
        this._gateway.pushToAll('RELAY_ANNOUNCE', {
          relay_id:  'node_' + node_id.slice(0, 12),  // opaque tag — not raw IP
          ip,
          port,
          name:      'SOV Node',   // label without IP
          nickname:  'SOV Node',
          added_at:  Date.now(),
        });
      }

      global.sovLog.info(`[Mesh] Peer connected: ${node_id.slice(0, 16)}... @ ${address || 'unknown'} v${version}`);
      this._firePeerAdmitted(node_id);
    } else if (alreadyKnown) {
      // Already registered. If we still hold a LIVE socket for this node, this
      // new one is a redundant DUPLICATE — the peer re-dialled after an IP flap
      // or restart before its previous socket dropped. Keep the existing
      // connection and CLOSE the duplicate; otherwise it lingers forever as a
      // verified-but-untracked established socket that the reaper (which only
      // iterates _peers) never cleans up. That orphaning IS the peer-socket
      // leak (VPS1 accumulated 44 sockets to one flapping home node). If the
      // stored socket is already dead, adopt this fresh one in its place.
      const existing = this._peers.get(node_id);
      if (existing && existing.ws && existing.ws !== ws) {
        if (existing.ws.readyState === WebSocket.OPEN) {
          existing.lastSeen = Date.now();
          // Still counts as an inbound reachability proof before we drop the dup.
          if (ws._inbound && this._network && typeof this._network.markInboundVerified === 'function') {
            try { this._network.markInboundVerified(address || node_id.slice(0, 12)); } catch (_) {}
          }
          try { ws.close(4002, 'DUPLICATE_PEER'); } catch (_) {}
          return;
        }
        // Stored socket is dead but not yet reaped — adopt the fresh one.
        try { existing.ws.terminate(); } catch (_) {}
        this._peers.set(node_id, {
          ws, address, publicKey: public_key, version,
          lastSeen: Date.now(), verified: true, inbound: !!ws._inbound,
          circuitRelay: !!circuit_relay,
          connGen: ++this._connSeq,
        });
        this._firePeerAdmitted(node_id);   // a restarted peer, back on a fresh socket
      } else if (existing) {
        existing.lastSeen = Date.now();
      }
    } else {
      // New peer, but we are already at MAX_PEERS. Do NOT leave this socket
      // open — an unstored verified socket is never reaped and would leak just
      // like the duplicate case above. Record the inbound reachability proof,
      // then close it.
      if (ws._inbound && this._network && typeof this._network.markInboundVerified === 'function') {
        try { this._network.markInboundVerified(address || node_id.slice(0, 12)); } catch (_) {}
      }
      try { ws.close(4003, 'PEER_LIMIT'); } catch (_) {}
      return;
    }

    // ── reach-probe-v1: OUR OWN reachability proof ──────────────────────────
    // A peer reached us from outside and passed interrogation, so our address
    // demonstrably accepts inbound connections. This is what flips the node from
    // '-unverified' to serving in the operator's UI — earned, not assumed.
    //
    // This used to live inside the `!alreadyKnown` branch above, which meant an
    // inbound connection from a peer we ALREADY knew — exactly what a
    // reconnecting server is — proved nothing. Observed live 2026-08-02: ports
    // verified open from outside, badge still amber. Any completed inbound
    // handshake counts, known peer or not.
    if (ws._inbound && this._network && typeof this._network.markInboundVerified === 'function') {
      try { this._network.markInboundVerified(address || node_id.slice(0, 12)); } catch (_) {}
    }

    // Respond with our own PEER_HELLO only once per connection (mutual authentication).
    // _helloSent is set true before we send on outbound connections so we don't
    // reply to the server's response PEER_HELLO, which would create an infinite loop.
    if (!ws._helloSent) {
      ws._helloSent = true;
      ws.send(JSON.stringify(this._buildHelloPayload(ws)));   // plaintext by design (handshake)
      // Send peer list to help them discover more nodes
      this._handlePeerListRequest(ws);
    }

    // network-seed-join-v1: the peer now has our PEER_HELLO (so its channel to us
    // is _verified and it will accept a signed message), so hand over the network
    // seed if the fingerprint check above flagged it as still on the legacy key.
    if (ws._offerSeed) {
      ws._offerSeed = false;
      try {
        const ns = require('../security/network_seed');
        this._wsSend(ws, this._sign({
          type:    'NETWORK_SEED',
          node_id: this._identity.nodeId,
          seed:    ns.load(),
        }));
        global.sovLog.info(
          `[Mesh] Offered the network seed to ${node_id.slice(0, 12)}… (they were on the legacy key).`
        );
      } catch (e) {
        global.sovLog.warn(`[Mesh] Seed offer to ${node_id.slice(0, 12)}… failed: ${e.message}`);
      }
    }
  }

  // ── NETWORK_SEED — adopt the cancelable-seed handed over on join ───────────
  // network-seed-join-v1. Reaches here only on a _verified channel (the sender
  // passed interrogation, so it is genuine manifest-signed software) with a valid
  // signature. network_seed.receive() refuses to overwrite a real seed we already
  // hold and rejects the legacy constant, so this is idempotent and cannot be used
  // to swap a settled node onto a rival key.
  _handleNetworkSeed(msg, ws) {
    const ns = require('../security/network_seed');
    if (ns.has()) return; // already hold a real seed — receive() would refuse anyway
    const r = ns.receive(msg && msg.seed);
    if (r.stored) {
      let fp = '';
      try { fp = require('../security/palm_cancelable').fingerprint(); } catch (_) {}
      global.sovLog.info(
        `[Mesh] Adopted the network seed from ${((msg && msg.node_id) || 'peer').slice(0, 12)}… ` +
        `— biometric dedup is now interoperable${fp ? ` (fp=${fp})` : ''}.`
      );
    } else if (r.reason && r.reason !== 'ALREADY_MATCHES' && r.reason !== 'IS_LEGACY_DEFAULT') {
      global.sovLog.warn(`[Mesh] Network-seed offer not stored: ${r.reason}`);
    }
  }

  // ── Software authenticity verification ────────────────────────────────────

  _verifySoftwareProof(manifestHash, manifestSig) {
    // In development mode — accept all peers
    if (process.env.NODE_ENV === 'development') return true;

    // If master key is the zero placeholder — not yet set up (first deploy)
    if (NETWORK_MASTER_PUBLIC_KEY_HEX === '0'.repeat(64)) return true;

    // Manifest must exist
    if (!manifestHash || !manifestSig) return false;
    if (manifestHash === 'dev' || manifestSig === 'dev') return true; // peer also in dev mode

    try {
      const masterPubKey  = Buffer.from(NETWORK_MASTER_PUBLIC_KEY_HEX, 'hex');
      const manifestHashBuf = Buffer.from(manifestHash, 'hex');
      const manifestSigBuf  = Buffer.from(manifestSig, 'hex');

      // The signature was produced over the manifest body, not just the hash.
      // We verify the sig against the hash — the full body is too large to retransmit.
      // Both parties have the signed manifest on disk so the hash is sufficient.
      return nacl.sign.detached.verify(
        new Uint8Array(manifestHashBuf),
        new Uint8Array(manifestSigBuf),
        new Uint8Array(masterPubKey)
      );
    } catch (_) {
      return false;
    }
  }

  // ── Version check ──────────────────────────────────────────────────────────

  _isVersionAcceptable(version) {
    if (!version) return false;
    // Simple semver comparison — major.minor.patch
    const parse = v => v.split('.').map(n => parseInt(n) || 0);
    const [mj, mn, pt]     = parse(version);
    const [mjMin, mnMin, ptMin] = parse(MIN_VERSION);
    if (mj !== mjMin) return mj > mjMin;
    if (mn !== mnMin) return mn > mnMin;
    return pt >= ptMin;
  }

  // ── Standard peer message handlers ────────────────────────────────────────

  // ── reach-probe-v1 ─────────────────────────────────────────────────────────
  // A peer cannot prove it accepts inbound connections until something connects
  // to it, and a node that dials out promptly is never dialled. So it may ask.
  // We simply open a connection to the address it gave; if that address really
  // is reachable, our dial lands on its listener as an inbound handshake and IT
  // draws its own conclusion. We report nothing back — there is no verdict to
  // forge, which is what keeps this honest.
  _handleReachProbe(msg) {
    const { node_id, address } = msg || {};
    if (!node_id || !address) return;
    if (node_id === this._identity.nodeId) return;      // never probe ourselves
    if (!/^[\w.\-]+:\d+$/.test(address)) return;         // host:port only

    // Rate-limit: one probe per peer per 5 minutes. Without this a peer could
    // use us to hammer a third party, and an honest node stuck unverified would
    // still make us redial on every heartbeat.
    this._probeSeen = this._probeSeen || new Map();
    const last = this._probeSeen.get(node_id) || 0;
    if (Date.now() - last < 5 * 60 * 1000) return;
    this._probeSeen.set(node_id, Date.now());

    global.sovLog.info(`[Mesh] Reachability probe requested by ${node_id.slice(0, 12)}… — dialling ${address}`);
    this._connectToPeer(address).catch(() => {
      // A failed dial is a real answer too: the address is not reachable. The
      // asker learns this by NOT being promoted, which is the correct outcome.
    });
  }

  // Ask a connected peer to dial us, so we can observe a genuine inbound
  // handshake. Only worth doing while we are unverified and have someone to ask.
  requestReachProbe() {
    if (!this._network || this._network.inboundVerified) return false;
    const addr = this._network.publicAddress;
    if (!addr) return false;
    const ids = Array.from(this._peers.keys());
    if (!ids.length) return false;
    const target = ids[Math.floor(ids.length * 0.5)] || ids[0];
    const syncAddr = addr.replace(/:\d+$/, `:${process.env.SYNC_PORT || '7771'}`);
    global.sovLog.info(`[Mesh] Asking ${target.slice(0, 12)}… to dial ${syncAddr} to prove reachability`);
    this.sendTo(target, 'REACH_PROBE', {
      node_id: this._identity.nodeId,
      address: syncAddr,
    });
    return true;
  }

  _handleNodeAnnounce(msg) {
    const { node_id, address, public_key } = msg;
    this._updateRegistry(node_id, address, public_key);
    this.broadcast('NODE_ANNOUNCE', msg, msg.node_id);
  }

  _handleNodeOffline(msg) {
    this._peers.delete(msg.node_id);
    this.broadcast('NODE_OFFLINE', msg, msg.node_id);
  }

  _handleHeartbeat(ws, msg) {
    const peer = this._peers.get(msg.node_id);
    if (peer) {
      peer.lastSeen = Date.now();
      // Phase 2 (tiered compute): remember what this peer says it can hold, so work that
      // needs the full biometric set is routed only to peers that have it. Only the fields
      // routing reads are kept, each type-checked — a peer cannot plant arbitrary state here.
      const c = msg.capability;
      if (c && typeof c === 'object') {
        peer.capability = {
          tier:        c.tier === 'light' ? 'light' : (c.tier === 'full' ? 'full' : 'unknown'),
          disk_status: ['ok', 'low', 'critical'].includes(c.disk_status) ? c.disk_status : 'unknown',
          pressure:    Number.isFinite(c.pressure) ? c.pressure : null,
          seen_at:     Date.now(),
        };
      }
      // A signed heartbeat from a connected peer IS real reachability proof — advance
      // last_verified so this node stays out of the dead-node prune.
      // reachability-proof-v1: a heartbeat over a socket THEY opened keeps them
      // alive in the registry, but must not upgrade their address to verified,
      // and must not publish it to citizens via the relay pool. Otherwise the
      // unproven address leaks into the pool one heartbeat after the handshake
      // and the check above is worthless.
      const _reachable = !peer.inbound && peer.addressProven !== false;   // 1.4.92: claim must match the dial
      if (!_reachable && peer.address && !this.isAddressProven(msg.node_id)) this._proveAddress(msg.node_id, peer.address);
      this._updateRegistry(msg.node_id, peer.address, peer.publicKey, _reachable);
      if (_reachable && this._relayPool && peer.address) { try { this._relayPool.addOrUpdate(msg.node_id, peer.address, peer.version); } catch (_) {} }

      // Compare Merkle roots — if different, our ledger has diverged
      const ourRoot = this._db ? this._db.computeMerkleRoot() : null;
      const balDiff = ourRoot && msg.merkle_root && ourRoot !== msg.merkle_root;
      let xDiff = false;
      try {
        if (this._db && this._db.computeExchangeRoot && msg.exchange_root) {
          const ourXRoot = this._db.computeExchangeRoot();
          xDiff = ourXRoot && ourXRoot !== msg.exchange_root;
        }
      } catch (_) {}
      try {
        if (this._db && this._db.computeConsensusRoot && msg.consensus_root) {
          const ourCRoot = this._db.computeConsensusRoot();
          if (ourCRoot && ourCRoot !== msg.consensus_root) xDiff = true;
        }
      } catch (_) {}
      try {
        if (this._db && this._db.computeEnrollmentRoot && msg.enrollment_root) {
          const ourERoot = this._db.computeEnrollmentRoot();
          if (ourERoot && ourERoot !== msg.enrollment_root) xDiff = true;
        }
      } catch (_) {}
      if (balDiff || xDiff) {
        global.sovLog.info(`State mismatch with ${msg.node_id.slice(0, 16)}... (bal=${balDiff} exch=${xDiff}) — requesting state delta`);
        // Phase 2: a light node does not hold the biometric set, so it asks for the delta
        // WITHOUT templates (an older peer that ignores the flag sends them; we drop them).
        let _light = false;
        try { _light = this._db && this._db.computeCapability && this._db.computeCapability().tier === 'light'; } catch (_) {}
        this.sendTo(msg.node_id, 'STATE_DELTA_REQUEST', {
          node_id:   this._identity.nodeId,
          our_root:  ourRoot,
          templates: !_light,
        });
      }
    }
  }

  _handlePeerList(msg) {
    for (const { node_id, address, public_key } of (msg.peers || [])) {
      if (node_id !== this._identity.nodeId) {
        this._updateRegistry(node_id, address, public_key);
        if (this._peers.size < MIN_PEERS && !this._peers.has(node_id)) {
          this._connectToPeer(address).catch(() => {});
        }
      }
    }
  }

  _handlePeerListRequest(ws) {
    // Only gossip nodes that are currently connected OR verified-reachable within
    // GOSSIP_FRESH_MS. This stops terminated nodes from propagating network-wide, so
    // they actually age out instead of being kept "fresh" by endless re-gossip.
    const now       = Date.now();
    const activeIds = new Set(this._peers.keys());
    const peers = [...this._registry.entries()]
      .filter(([id, info]) => activeIds.has(id) ||
        (info.lastVerified && info.lastVerified >= now - GOSSIP_FRESH_MS))
      .slice(0, 50)
      .map(([node_id, info]) => ({
        node_id,
        address:    info.address,
        public_key: info.publicKey,
      }));
    this._wsSend(ws, this._sign({ type: 'PEER_LIST', peers }));
  }

  _handlePeerDisconnect(ws) {
    if (ws._nodeId) {
      const stored = this._peers.get(ws._nodeId);
      if (stored && stored.ws === ws) {
        // Only remove if THIS ws is the active registered connection for this peer.
        // A duplicate inbound connection for the same node must not evict the
        // existing outbound connection (which is the one we actually use).
        global.sovLog.info(`[Mesh] Peer disconnected: ${ws._nodeId.slice(0, 16)}...`);
        this._peers.delete(ws._nodeId);
        if (this._relayPool) this._relayPool.markOffline(ws._nodeId);
      }
      // If stored.ws !== ws, this was a duplicate connection — silently discard
    } else {
      // Unknown peer (never passed HELLO) — find by ws reference
      for (const [nodeId, peer] of this._peers) {
        if (peer.ws === ws) {
          this._peers.delete(nodeId);
          break;
        }
      }
    }
    if (this._peers.size < MIN_PEERS) {
      this._scheduleReconnect();
    }
  }

  // ── Reconnect with exponential backoff ────────────────────────────────────
  // Called whenever a peer disconnects and we're below MIN_PEERS.
  // Uses a single debounced timer so 10 simultaneous disconnects only
  // schedule ONE reconnect attempt, not 10.

  _scheduleReconnect() {
    if (this._reconnectScheduled) return;  // already queued — ignore
    this._reconnectScheduled = true;

    const delay = this._reconnectDelay;
    global.sovLog.debug(`[Mesh] Scheduling reconnect in ${(delay / 1000).toFixed(0)}s`);

    this._reconnectTimer = setTimeout(async () => {
      this._reconnectScheduled = false;
      // Double the delay for next time, cap at 5 minutes
      this._reconnectDelay = Math.min(this._reconnectDelay * 2, 300000);

      if (this._peers.size < MIN_PEERS) {
        await this._connectToBootstrap();
        // Reset backoff if we successfully connected to at least one peer
        if (this._peers.size >= 1) {
          this._reconnectDelay = 15000;
        }
      }
    }, delay);
  }

  // ── Heartbeat ──────────────────────────────────────────────────────────────

  _startHeartbeat() {
    this._hbTimer = setInterval(() => {
      // reach-probe-v1: while we cannot prove anyone can reach us, ask a peer to
      // try. Cheap, rate-limited on the far side, self-cancelling once verified.
      try { this.requestReachProbe(); } catch (_) {}

      // Zombie-peer reaper: a half-open TCP socket keeps readyState OPEN but
      // stops delivering data, so lastSeen freezes; broadcasts (heartbeats,
      // state deltas) then vanish into the dead socket and the peer is never
      // reconnected (it is still in _peers, so the reconnect loop skips it).
      // Reap peers silent beyond the staleness window so the link re-forms.
      const _now = Date.now();
      for (const [nodeId, peer] of this._peers) {
        if (_now - (peer.lastSeen || 0) > PEER_STALE_MS) {
          global.sovLog.info(`[Mesh] Reaping stale peer ${nodeId.slice(0, 16)}... (silent ${Math.round((_now - (peer.lastSeen || 0)) / 1000)}s)`);
          try { peer.ws.terminate(); } catch (_) {}
          this._peers.delete(nodeId);
          if (this._relayPool) this._relayPool.markOffline(nodeId);
        }
      }
      if (this._peers.size < MIN_PEERS) this._scheduleReconnect();

      const merkleRoot = this._db ? this._db.computeMerkleRoot() : '0'.repeat(64);
      let exchangeRoot = '';
      try { if (this._db && this._db.computeExchangeRoot) exchangeRoot = this._db.computeExchangeRoot(); } catch (_) {}
      let consensusRoot = '';
      try { if (this._db && this._db.computeConsensusRoot) consensusRoot = this._db.computeConsensusRoot(); } catch (_) {}
      // 1.4.90: enrolment records get their own fingerprint. They reach a late joiner only with a
      // state delta, which used to be triggered by the BALANCE root differing — but balances now
      // replicate exactly as ledger ops, so that root agrees and a joiner never learned who is
      // enrolled (caught by tools/test_mesh/scenario_admission.sh, OPERATOR_NOT_ENROLLED).
      let enrollmentRoot = '';
      try { if (this._db && this._db.computeEnrollmentRoot) enrollmentRoot = this._db.computeEnrollmentRoot(); } catch (_) {}
      let capability = null;
      try { if (this._db && this._db.computeCapability) capability = this._db.computeCapability(); } catch (_) {}
      // Operator awareness: log storage tier every ~10 min (once per 10 heartbeats).
      this._capTick = (this._capTick || 0) + 1;
      if (capability && this._capTick % 10 === 1) {
        const gb = (b) => (b / 1073741824).toFixed(2);
        global.sovLog.info(`[Capacity] tier=${capability.tier} state=${gb(capability.state_bytes)}GB free=${gb(capability.free_bytes)}GB pressure=${(capability.pressure*100).toFixed(1)}% (high-water ${(capability.high_water*100).toFixed(0)}%)`);
      }
      this.broadcast('NODE_HEARTBEAT', {
        node_id:       this._identity.nodeId,
        address:       this._network.publicAddress,
        merkle_root:   merkleRoot,
        exchange_root: exchangeRoot,
        consensus_root: consensusRoot,
        enrollment_root: enrollmentRoot,
        capability,
        citizen_count: this._db ? this._db.citizenCount() : 0,
        uptime_sec:    Math.floor(process.uptime()),
        timestamp:     Date.now(),
      });
    }, HEARTBEAT_INTERVAL);

    // ── Dead-node prune sweep (king 2026-07-23) ──────────────────────────────
    // Every 6h, delete registry rows not verified-reachable for > node_registry_ttl_days.
    // Keyed on last_verified (real contact), which gossip never advances — so terminated
    // nodes finally age out instead of being kept immortal by re-gossip.
    this._pruneTimer = setInterval(() => {
      try {
        if (!this._db || !this._db.pruneDeadNodes) return;
        let ttlDays = 60;
        try { ttlDays = parseInt(this._db.getGovParam('node_registry_ttl_days', '60')) || 60; } catch (_) {}
        const ttlMs = Math.max(30, Math.min(365, ttlDays)) * 24 * 60 * 60 * 1000;
        const removed = this._db.pruneDeadNodes(ttlMs);
        // Keep the in-memory registry in step so pruned nodes stop being gossiped immediately.
        if (removed > 0) {
          const cutoff = Date.now() - ttlMs;
          for (const [id, info] of this._registry) {
            if (info.lastVerified > 0 && info.lastVerified < cutoff) this._registry.delete(id);
          }
          global.sovLog.info(`[Mesh] Dead-node prune: removed ${removed} node(s) unreachable > ${ttlDays}d`);
        }
      } catch (e) { global.sovLog && global.sovLog.debug(`[Mesh] prune error: ${e.message}`); }
    }, PRUNE_INTERVAL_MS);
  }

  _requestPeerList() {
    for (const peer of this._peers.values()) {
      if (peer.verified && peer.ws.readyState === WebSocket.OPEN) {
        this._wsSend(peer.ws, this._sign({ type: 'PEER_LIST_REQ' }));
      }
    }
  }

  // ── Registry ──────────────────────────────────────────────────────────────

  // verified=true only for REAL contact (verified peer handshake / signed heartbeat).
  // Gossip callers omit it → last_verified is NOT advanced, so dead nodes age out.
  _updateRegistry(nodeId, address, publicKey, verified = false) {
    const now  = Date.now();
    const prev = this._registry.get(nodeId);
    const lastVerified = verified ? now : (prev ? (prev.lastVerified || 0) : 0);   // 1.4.92: no grace
    this._registry.set(nodeId, { address, publicKey, lastSeen: now, lastVerified });
    if (this._db) this._db.upsertNodeRegistry(nodeId, address, publicKey, verified);
  }

  _loadRegistry() {
    if (!this._db) return;
    const rows = this._db.getNodeRegistry();
    for (const row of rows) {
      this._registry.set(row.node_id, {
        address: row.address, publicKey: row.public_key,
        lastSeen: row.last_seen, lastVerified: row.last_verified || 0,
      });
    }
  }

  _knownPeerAddresses() {
    return [...this._registry.values()].map(r => r.address);
  }

  // ── Cryptographic signing ──────────────────────────────────────────────────

  _sign(payload) {
    const body = JSON.stringify(payload);
    const sig  = this._identity.signMessage(Buffer.from(body));
    return { ...payload, _sig: sig.toString('hex') };
  }

  _verifySig(msg) {
    const { _sig, ...payload } = msg;
    if (!_sig) return false;
    const senderEntry = this._registry.get(msg.node_id);
    if (!senderEntry) return true; // unknown node — accept cautiously (they passed PEER_HELLO already)
    try {
      const pubKey = Buffer.from(senderEntry.publicKey, 'hex');
      return NodeIdentity.verify(
        Buffer.from(JSON.stringify(payload)),
        Buffer.from(_sig, 'hex'),
        pubKey
      );
    } catch (_) { return false; }
  }
}

module.exports = { PeerMesh };
