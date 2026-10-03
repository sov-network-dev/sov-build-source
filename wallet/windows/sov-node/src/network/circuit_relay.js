// circuit_relay.js — decentralized serving behind hard NAT (Task #26).
//
// Lets a NAT'd node (N) serve citizens through a reachable mesh peer (R), with NO
// external dependency (no external service or VPS). R is a DUMB PIPE: it forwards opaque,
// end-to-end-signed citizen frames between the citizen (C) and N. R never sees keys
// and cannot forge anything — every citizen frame is Ed25519-signed against N's records.
//
// Transport: the existing peer mesh (peerMesh.sendTo/on, all signature-verified).
// Ops (node↔node):
//   RELAY_REGISTER {node_id:N, ttl}      N→R  "front my citizens"
//   RELAY_REGISTER_ACK {ok, relay_id:R}  R→N  accepted
//   RELAY_KEEPALIVE {node_id:N}          N→R  refresh before ttl
//   RELAY_OPEN  {session, target:N}      R→N  a citizen wants N
//   RELAY_DATA  {session, frame}         R↔N  one citizen WS frame (opaque), both ways
//   RELAY_CLOSE {session, reason}        R↔N  citizen session ended
//
// Integration (citizen_gateway): construct, call registerHandlers() once, call
// maybeBridge(ws,msg) at the top of _handleMessage (R-side early-out), and
// relayedEntries() inside _handleRelayListRequest. network_manager calls
// registerWithRelays() when reachabilityMethod==='circuit-relay'.

'use strict';

const REGISTER_TTL_MS   = 10 * 60 * 1000;   // N must keepalive within 10 min
const KEEPALIVE_MS      = 4 * 60 * 1000;    // N pings every 4 min
const MAX_RELAY_CLIENTS = 50;               // R: cap nodes it fronts (governable later)
const MAX_SESSIONS      = 500;              // R+N: cap concurrent bridged sessions

class CircuitRelay {
  /**
   * @param {object} deps
   *   peerMesh  - PeerMesh instance (sendTo/broadcast/on, peerCount)
   *   identity  - node identity (nodeId)
   *   gateway   - citizen gateway; must expose:
   *                 handleVirtualMessage(virtualWs, frameString)  // = _handleMessage
   *                 getGovParam(key, def)                         // optional, for caps
   *   log       - logger (defaults to global.sovLog)
   */
  constructor({ peerMesh, identity, gateway, log }) {
    this._mesh     = peerMesh;
    this._identity = identity;
    this._gateway  = gateway;
    this._log      = log || global.sovLog || console;

    // R-side (I am a relay for others)
    this._clients   = new Map();   // N_nodeId → { ttl }
    this._sessionsR = new Map();   // session → { citizenWs, target:N }

    // N-side (others relay for me)
    this._myRelays   = new Map();  // R_nodeId → connGen we registered against
    this._sessionsN  = new Map();  // session → virtualWs
    this._keepaliveT = null;

    this._seq = 0;
  }

  _newSession(nodeId) { return `${nodeId.slice(0,8)}-${Date.now().toString(36)}-${(this._seq++).toString(36)}`; }

  // ── Wire up all node↔node handlers (call once at gateway init) ──────────────
  registerHandlers() {
    const m = this._mesh;
    m.on('RELAY_REGISTER',     (msg, ws) => this._onRegister(msg, ws));
    m.on('RELAY_REGISTER_ACK', (msg)     => this._onRegisterAck(msg));
    m.on('RELAY_KEEPALIVE',    (msg)     => this._onKeepalive(msg));
    m.on('RELAY_OPEN',         (msg)     => this._onOpen(msg));
    m.on('RELAY_DATA',         (msg)     => this._onData(msg));
    m.on('RELAY_CLOSE',        (msg)     => this._onClose(msg));
    // periodic TTL sweep on R
    setInterval(() => this._sweep(), 60 * 1000).unref?.();
    this._log.info && this._log.info('[CircuitRelay] handlers registered');
  }

  // ════════════════════════════════════════════════════════════════════════
  // N-SIDE — register with reachable relays so citizens can find me
  // ════════════════════════════════════════════════════════════════════════
  /** Called by network_manager when this node is NOT directly reachable.
   *  Asks up to `want` reachable, verified peers to front our citizen traffic. */
  registerWithRelays(want = 3) {
    const mesh = this._mesh;
    const verified = (mesh.verifiedPeers ? mesh.verifiedPeers() : [])
      .filter(p => p && p.node_id && p.node_id !== this._identity.nodeId);
    const byId = new Map(verified.map(p => [p.node_id, p]));
    // Prune relays whose mesh peer is gone — they no longer front us, so they
    // must not count toward `want` (else a dead relay pins us below target and a
    // replacement is never sought). This is what lets the node SELF-HEAL when a
    // relay dies, instead of staying pinned to whoever answered first at boot —
    // the real "no single relay is a point of failure" property. Called on a
    // timer, so it re-scans continuously.
    //
    // ALSO drop a relay that RECONNECTED since we registered. A relay restart
    // keeps its node_id (persistent identity) but wipes its client table, so it
    // silently stops fronting us while we still believe we hold it — the prune
    // above never fires (the peer came right back). We detect the restart by its
    // connection generation (bumped on every (re)handshake in peer_mesh): a
    // changed connGen means "new socket, empty client table", so we drop it here
    // and the top-up below re-registers within one cycle. This is what makes a
    // relay restart self-heal with NO home-node restart.
    for (const r of Array.from(this._myRelays.keys())) {
      const peer = byId.get(r);
      if (!peer) { this._myRelays.delete(r); continue; }
      if ((peer.connGen || 0) !== this._myRelays.get(r)) this._myRelays.delete(r);
    }
    // Only ask peers that actually run the relay R-side — a peer on an older
    // build (e.g. a snap without circuit_relay.js) silently DROPS RELAY_REGISTER.
    // Peers advertise the capability in PEER_HELLO.
    const capable = verified.filter(p => p.circuitRelay === true);
    if (capable.length === 0) {
      this._log.info && this._log.info(
        `[CircuitRelay] no relay-capable peers yet (${verified.length} verified) — will retry`);
      return this._myRelays.size;
    }
    // Top up to `want`: register ONLY with capable peers we are not already
    // registered with. Idempotent and cheap — a re-scan that already holds `want`
    // relays sends nothing; a re-scan after a relay dropped registers a fresh one.
    const need = want - this._myRelays.size;
    let sent = 0;
    if (need > 0) {
      for (const p of capable) {
        if (sent >= need) break;
        if (this._myRelays.has(p.node_id)) continue;
        if (mesh.sendTo(p.node_id, 'RELAY_REGISTER', { node_id: this._identity.nodeId, ttl: REGISTER_TTL_MS })) sent++;
      }
    }
    // keepalive loop (idempotent)
    if (!this._keepaliveT) {
      this._keepaliveT = setInterval(() => {
        for (const r of this._myRelays.keys()) {
          this._mesh.sendTo(r, 'RELAY_KEEPALIVE', { node_id: this._identity.nodeId });
        }
      }, KEEPALIVE_MS);
      this._keepaliveT.unref?.();
    }
    if (sent) this._log.info && this._log.info(
      `[CircuitRelay] sent RELAY_REGISTER to ${sent} new relay(s) — target ${want}, now holding ${this._myRelays.size}`);
    return this._myRelays.size;
  }

  // N-side: we have become directly reachable, so we no longer need anyone to
  // front us. Stop keepaliving and forget our relays — each relay drops us from
  // its client table when our TTL lapses (no explicit un-register op needed).
  // Fixes VPS1 self-registering as a relay CLIENT at boot: it briefly reported
  // 'circuit-relay' before the inbound reach-proof flipped it to direct, fired
  // registerWithRelays(), and then never let go.
  stopRegistering() {
    if (this._keepaliveT) { clearInterval(this._keepaliveT); this._keepaliveT = null; }
    if (this._myRelays.size) {
      this._log.info && this._log.info(
        `[CircuitRelay] directly reachable now — releasing ${this._myRelays.size} relay registration(s)`);
      this._myRelays.clear();
    }
  }

  _onRegisterAck(msg) {
    if (!msg || !msg.ok || !msg.relay_id) return;
    const isNew = !this._myRelays.has(msg.relay_id);
    // Record the relay's CURRENT connection generation, so that if it later
    // restarts (same node_id, new socket → higher connGen) the next maintain
    // cycle sees the mismatch and re-registers. Look it up from the live peer set.
    let connGen = 0;
    const vp = this._mesh.verifiedPeers ? this._mesh.verifiedPeers() : [];
    const peer = vp.find(p => p.node_id === msg.relay_id);
    if (peer) connGen = peer.connGen || 0;
    this._myRelays.set(msg.relay_id, connGen);
    if (isNew) this._log.info && this._log.info(`[CircuitRelay] relay confirmed: ${String(msg.relay_id).slice(0,12)} (now ${this._myRelays.size} relay[s])`);
  }

  // N receives a citizen session opened on a relay R
  _onOpen(msg) {
    if (!msg || !msg.session || !msg.node_id) return;          // node_id = R (peer that sent it)
    if (this._sessionsN.size >= MAX_SESSIONS) return;
    const R = msg.node_id, session = msg.session;
    // Virtual socket: looks like a citizen WS to the gateway, but writes go back to R.
    const self = this;
    const virtualWs = {
      _isRelayVirtual: true, _relay: R, _session: session,
      readyState: 1,            // OPEN (ws.OPEN === 1)
      send(data) {
        try { self._mesh.sendTo(R, 'RELAY_DATA', { session, frame: typeof data === 'string' ? data : data.toString(), node_id: self._identity.nodeId }); }
        catch (_) {}
      },
      close() {
        try { self._mesh.sendTo(R, 'RELAY_CLOSE', { session, reason: 'node_closed', node_id: self._identity.nodeId }); } catch (_) {}
        self._sessionsN.delete(session);
      },
      // The gateway treats every citizen socket as a real ws — its ping loop calls
      // ws.ping()/ws.terminate(). A bridged citizen is a virtual socket, so those
      // must exist or the heartbeat throws and takes the whole node down (observed
      // 2026-08-04: `ws.ping is not a function` crashed a home node minutes after a
      // circuit-relay citizen connected). ping is a no-op — the R↔N mesh hop already
      // keeps the bridge alive; terminate just tears the session down like close.
      ping() {},
      terminate() { try { this.close(); } catch (_) {} },
      on() {},                  // gateway attaches ws.on('message'/'close'); we drive it manually
    };
    this._sessionsN.set(session, virtualWs);
  }

  // A data frame arrived. R-side: write to the citizen socket. N-side: feed to gateway.
  _onData(msg) {
    if (!msg || !msg.session || msg.frame == null) return;
    // R-side: is this a reply from N for a citizen we bridge?
    const rs = this._sessionsR.get(msg.session);
    if (rs) {
      try { if (rs.citizenWs.readyState === 1) rs.citizenWs.send(msg.frame); } catch (_) {}
      return;
    }
    // N-side: a citizen frame to process locally via the virtual session.
    const vws = this._sessionsN.get(msg.session);
    if (vws) {
      try { this._gateway.handleVirtualMessage(vws, msg.frame); } catch (e) {
        this._log.warn && this._log.warn(`[CircuitRelay] virtual handle error: ${e.message}`);
      }
    }
  }

  _onClose(msg) {
    if (!msg || !msg.session) return;
    const rs = this._sessionsR.get(msg.session);
    if (rs) { try { rs.citizenWs.close(); } catch (_) {} this._sessionsR.delete(msg.session); return; }
    const vws = this._sessionsN.get(msg.session);
    if (vws) { this._sessionsN.delete(msg.session); }
  }

  // ════════════════════════════════════════════════════════════════════════
  // R-SIDE — I am a relay fronting NAT'd nodes
  // ════════════════════════════════════════════════════════════════════════
  _onRegister(msg, ws) {
    if (!msg || !msg.node_id) return;
    if (this._clients.size >= MAX_RELAY_CLIENTS && !this._clients.has(msg.node_id)) return;
    this._clients.set(msg.node_id, { ttl: Date.now() + (msg.ttl || REGISTER_TTL_MS) });
    this._mesh.sendTo(msg.node_id, 'RELAY_REGISTER_ACK', { ok: true, relay_id: this._identity.nodeId, node_id: this._identity.nodeId });
    this._log.info && this._log.info(`[CircuitRelay] now fronting node ${String(msg.node_id).slice(0,12)} (${this._clients.size} client[s])`);
  }

  _onKeepalive(msg) {
    if (!msg || !msg.node_id) return;
    const c = this._clients.get(msg.node_id);
    if (c) c.ttl = Date.now() + REGISTER_TTL_MS;
  }

  _sweep() {
    const now = Date.now();
    for (const [n, c] of this._clients) if (c.ttl < now) {
      this._clients.delete(n);
      this._log.info && this._log.info(`[CircuitRelay] dropped stale client ${String(n).slice(0,12)}`);
    }
  }

  /** R-side early-out for the gateway's _handleMessage. If this citizen frame is
   *  addressed to a node we relay (msg.target_node_id), bridge it to that node and
   *  return true (caller must `return`). Otherwise return false (handle locally). */
  maybeBridge(ws, msg) {
    const target = msg && msg.target_node_id;
    if (!target || target === this._identity.nodeId) return false;   // for us → local
    if (!this._clients.has(target)) return false;                    // we don't front it → local (best effort)
    // Find or create the session for this citizen socket ↔ target node.
    let session = ws._relaySession;
    if (!session) {
      if (this._sessionsR.size >= MAX_SESSIONS) return false;
      session = this._newSession(target);
      ws._relaySession = session;
      this._sessionsR.set(session, { citizenWs: ws, target });
      this._mesh.sendTo(target, 'RELAY_OPEN', { session, target, node_id: this._identity.nodeId });
      // tear down the bridge if the citizen disconnects
      try { ws.on('close', () => { this._mesh.sendTo(target, 'RELAY_CLOSE', { session, reason: 'citizen_closed', node_id: this._identity.nodeId }); this._sessionsR.delete(session); }); } catch (_) {}
      this._log.info && this._log.info(`[CircuitRelay] bridging citizen → ${String(target).slice(0,12)} (session ${session})`);
    }
    // Forward the raw citizen frame to N.
    const frame = typeof msg === 'string' ? msg : JSON.stringify(msg);
    this._mesh.sendTo(target, 'RELAY_DATA', { session, frame, node_id: this._identity.nodeId });
    return true;
  }

  /** R-side: extra RELAY_LIST entries advertising the NAT'd nodes we front, so
   *  phones learn to reach node N "via" us. */
  relayedEntries() {
    const out = [];
    const myIp = (this._mesh._network && this._mesh._network.publicAddress)
      ? String(this._mesh._network.publicAddress).split(':')[0] : '';
    for (const n of this._clients.keys()) {
      out.push({
        relay_id: 'node_' + n.slice(0, 12),
        ip: myIp, port: 443,            // citizens connect to ME (R) on 443
        via: 'node_' + this._identity.nodeId.slice(0, 12),
        target_node_id: n,              // and signal this target in HELLO
        relayed: true,
        name: 'Relayed node ' + n.slice(0, 8),
        added_at: Date.now(),
      });
    }
    return out;
  }
}

module.exports = { CircuitRelay };
