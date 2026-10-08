// ─────────────────────────────────────────────────────────────────────────────
// RELAY POOL — Node discovery and bootstrap list management
// ─────────────────────────────────────────────────────────────────────────────
// Every SOV node maintains a relay_pool.json — a signed list of all known
// active node operators with their current IP addresses.
//
// This file is:
//   - Served at HTTP /relay-pool from every running node
//   - Downloaded by new nodes on first boot
//   - Updated continuously as nodes come online and offline
//   - Compiled into new software releases as the bootstrap list
//   - Signed by the network master key so it cannot be forged
//
// Discovery order for a fresh install:
//   1. Local node_registry DB (populated from previous sessions)
//   2. Cached relay_pool.json on disk (from last download)
//   3. Bootstrap seeds — hardcoded in software (VPS IPs initially,
//      replaced by citizen nodes in later versions)
//   4. Community-shared IPs (manual entry in setup wizard)
// ─────────────────────────────────────────────────────────────────────────────

'use strict';

const https   = require('https');
const { bootstrapNodes } = require('./bootstrap');

// ── What this node PUBLISHES as relays (2026-10-02) ─────────────────────────
// bootstrapNodes() answers "whom may I DIAL", and the registry half of it holds
// every node whose address was recently verified REACHABLE. Reachable is not
// admitted: the iMac (699dd020…) answers on its ports while the mesh refuses its
// unrecognised source_root, so it was dialled - harmlessly, it is refused - and
// also PUBLISHED, in /relay-pool/latest, in every platform registration's
// canonical_relay_ips and in the SOV-Link callback pool. Measured live on all
// three nodes. Telling apps and platforms to use a node the network will not
// admit is wrong on its own, and it publishes that machine's home address.
//
// So publishing is filtered to hosts of peers the mesh has ADMITTED - passed the
// HELLO interrogation, source_root check included - and holds an open link to
// right now. Dialling is unchanged. Before the mesh is wired, nothing is
// published: fail closed rather than repeat the leak during boot.
let _advertMesh = null;
// 1.4.92: a host that goes into a published list or a generated plugin must be a plain IP or
// hostname. Never the request's Host header (attacker-chosen text, written verbatim into
// PHP/JS handed to platforms) — the node's own discovered address is used instead.
function _safeHost(h) {
  h = String(h || '').trim().toLowerCase();
  return /^[a-z0-9.-]{1,253}$/.test(h) || /^[0-9a-f:]{2,39}$/.test(h) ? h : '';
}
function _selfHost(network) {
  return _safeHost(process.env.RELAY_IP || (network && network.publicAddress ? String(network.publicAddress).split(':')[0] : ''));
}

function advertisedNodes(db) {
  const candidates = (bootstrapNodes(db) || []).filter(Boolean);
  if (!_advertMesh || typeof _advertMesh.activePeers !== 'function') return [];
  const admitted = new Set();
  try {
    for (const p of _advertMesh.activePeers()) {
      const host = String((p && p.address) || '').replace(/^\w+:\/\//, '').split('/')[0].split(':')[0];
      if (host) admitted.add(host);
    }
  } catch (_) { return []; }
  return candidates.filter((h) => admitted.has(h));
}

const http    = require('http');
const fs      = require('fs');
const path    = require('path');
const os      = require('os');
const crypto  = require('crypto');
const nacl    = require('tweetnacl');

/**
 * The node_id that belongs to a bootstrap host, or '' when it cannot be
 * established beyond doubt.
 *
 * [2026-08-14] Added because /relay-pool/latest — the ONE discovery feed that
 * actually carries entries — served `relay_id: 'SOV-NODE-<n>'`, `ip`, and two
 * ports, and nothing else. A consumer that wants to refuse a specific node has
 * only the address to key on, and an address re-leases. relay_id is worse than
 * useless for the job: it is a positional label computed from the loop index,
 * so the SAME string names a different machine the moment the host list
 * reorders, and two nodes serving the same list both call the same address
 * 'SOV-NODE-1'. It is a role label wearing an identity's name.
 *
 * Resolution order, strongest evidence first:
 *   1. ourselves — the identity this process signs with;
 *   2. the live gossip pool — a node we are actually talking to right now;
 *   3. sov_node_registry — a node we have talked to before.
 *
 * Ambiguity returns '' rather than a guess. One address legitimately carries
 * more than one node_id in this ledger (ghost rows: the anchor appears under
 * two ids), and a discovery feed that confidently names the wrong one is worse
 * than a feed that admits it does not know: a reader keying a refusal on the
 * clean id would pass the machine it meant to refuse and believe it had
 * checked. '' is falsy in every consumer, so an unknown host degrades to
 * exactly the address-keyed behaviour that exists today.
 */
function nodeIdForHost(db, relayPool, host, selfIp) {
  const want = String(host || '').replace(/^\w+:\/\//, '').split('/')[0].split(':')[0];
  if (!want) return '';

  // 1. Ourselves.
  try {
    if (selfIp && want === String(selfIp).split(':')[0] &&
        relayPool && relayPool._identity && relayPool._identity.nodeId) {
      return String(relayPool._identity.nodeId);
    }
  } catch (_) {}

  // 2. The live pool. Freshest lastSeen wins, but only if every candidate for
  //    this address agrees on the id — see the ambiguity note above.
  try {
    if (relayPool && relayPool._pool && typeof relayPool._pool.entries === 'function') {
      const hits = [...relayPool._pool.entries()]
        .filter(([, e]) => e && String(e.address || '').split(':')[0] === want)
        .sort((a, b) => (b[1].lastSeen || 0) - (a[1].lastSeen || 0));
      const ids = new Set(hits.map(([id]) => String(id)));
      if (ids.size === 1) return hits[0][0];
      if (ids.size > 1) return '';
    }
  } catch (_) {}

  // 3. The registry we persist. Same one-answer-only rule.
  try {
    if (db && db._db) {
      const rows = db._db.prepare(
        'SELECT node_id, address FROM sov_node_registry WHERE address = ? OR address LIKE ? ORDER BY last_seen DESC LIMIT 8'
      ).all(want, want + ':%');
      const ids = [...new Set(rows.map(r => String(r.node_id)).filter(Boolean))];
      if (ids.length === 1) return ids[0];
    }
  } catch (_) {}

  return '';
}

/**
 * One pool entry, with the id attached when it is known.
 *
 * `relay_id` is kept exactly as it was — removing it would break every reader
 * that already parses this feed — but it is now accompanied by the thing that
 * actually identifies the machine. The key is omitted, not blanked, when the id
 * is unknown, so that no reader can mistake '' for an identity it can compare.
 */
function poolEntryFor(db, relayPool, host, index, selfIp) {
  const entry = { relay_id: 'SOV-NODE-' + (index + 1), ip: host, http_port: 80, ws_port: 443 };
  const nid = nodeIdForHost(db, relayPool, host, selfIp);
  if (nid) entry.node_id = nid;
  return entry;
}

const DATA_DIR   = process.env.SOV_DATA_DIR || path.join(os.homedir(), '.sov-node');
const POOL_FILE  = path.join(DATA_DIR, 'relay_pool.json');
const MAX_POOL   = 2000;  // max entries to keep in local pool
const STALE_MS   = 7 * 24 * 60 * 60 * 1000; // 7 days before dropped from the bootstrap pool
const ALIVE_MS   = 3 * 60 * 1000; // 3 min — citizen-facing "alive right now" window
// Reputation gate (king 2026-07-24): a node must have been continuously present in
// the mesh for at least this long before it is handed CITIZEN traffic. A fresh home
// node joins the mesh + earns immediately, but only starts serving citizens once
// proven — so an unproven/throwaway node can never be the gateway a citizen lands on.
const MIN_SERVE_UPTIME_MS = 30 * 60 * 1000; // 30 minutes

// Network master public key — same key that signs the software manifest
const NETWORK_MASTER_PUBLIC_KEY_HEX =
  process.env.NETWORK_MASTER_PUBLIC_KEY ||
  '0000000000000000000000000000000000000000000000000000000000000000';

class RelayPool {

  constructor(identity, db) {
    this._identity = identity;
    this._db       = db;
    this._pool     = new Map(); // nodeId → { address, lastSeen, version, stakeVerified }
    this._loadFromDisk();
  }

  // ── Serve relay-pool to other nodes ──────────────────────────────────────

  // Called by the HTTP server handler for GET /relay-pool
  /**
   * Where downloadable artifacts live.
   *
   * A snap is mounted READ-ONLY, so anything resolved relative to __dirname sits
   * inside a squashfs the operator cannot write to — which is why a snap-installed
   * node could never serve the software that installs it. SNAP_COMMON is the
   * writable, upgrade-surviving location, so it is checked first, and the
   * source-relative path is kept for nodes run straight from source.
   *
   * FIXED 2026-08-21: this helper existed and said exactly the right thing, but
   * NOTHING that served a binary actually called it - /download/android,
   * /download/windows, /download/linux, /download/linux.sha256 and the .sig path
   * all resolved `__dirname/../../dist/<platform>` directly, i.e. inside the
   * read-only squashfs. On a snap-installed node those five routes could only
   * ever 404, because no process can write into $SNAP. Only two checksum call
   * sites used the helper. It is now platform-aware and every route goes through
   * it, so an operator can drop an artifact in $SNAP_COMMON/dist/<platform>/ and
   * the node serves it. This is what lets a genesis node hand out the APK that a
   * citizen needs in order to enrol on it.
   */
  static _distDir(platform = 'linux') {
    const path = require('path');
    const fs   = require('fs');
    const candidates = [];
    if (process.env.SNAP_COMMON) candidates.push(path.join(process.env.SNAP_COMMON, 'dist', platform));
    if (process.env.SOV_DATA_DIR) candidates.push(path.join(process.env.SOV_DATA_DIR, 'dist', platform));
    candidates.push(path.join(__dirname, '..', '..', 'dist', platform));
    for (const c of candidates) { try { if (fs.existsSync(c)) return c; } catch (_) {} }
    return candidates[candidates.length - 1];
  }

  /**
   * The FLAT directory holding published release artefacts, resolved exactly as `_distDir`
   * resolves a per-platform one: SNAP_COMMON first, because a snap-installed node cannot write
   * inside its own squashfs, then SOV_DATA_DIR, then the source-relative path.
   *
   * Separate from `_distDir` on purpose. That one addresses `dist/<platform>/<fixed name>` and
   * the fixed names (`SovNode.apk`, `sov-node.snap`, `SOV-Node-Setup-<v>.exe`) no longer match
   * what the release machinery actually publishes — and none of them covers macOS at all.
   */
  static _releaseDir() {
    const path = require('path');
    const fs   = require('fs');
    const candidates = [];
    if (process.env.SNAP_COMMON)  candidates.push(path.join(process.env.SNAP_COMMON, 'dist'));
    if (process.env.SOV_DATA_DIR) candidates.push(path.join(process.env.SOV_DATA_DIR, 'dist'));
    candidates.push(path.join(__dirname, '..', '..', 'dist'));
    for (const c of candidates) { try { if (fs.existsSync(c)) return c; } catch (_) {} }
    return candidates[candidates.length - 1];
  }

  // 1.4.92 (discovery hardening): the signed pool lists ONLY peers this node has ADMITTED - passed
  // the HELLO interrogation (source_root included) and linked right now - each with its Ed25519
  // public key, and the envelope carries the signer's own key. Until 1.4.91 it listed every gossiped
  // address and signed with a key it never published, so an app could not verify the signature at
  // all and anything announcing on the DHT could feed a fresh install a list of its choosing. The
  // app now checks: sha256(signer_pubkey) == signer, the signature, and that it trusts the signer.
  // Fail closed: before the mesh is wired the pool is empty.
  _admittedEntries() {
    const out = [];
    try {
      if (!_advertMesh || !_advertMesh._peers) return out;
      for (const [nodeId, p] of _advertMesh._peers.entries()) {
        if (!p || !p.verified || !p.ws || p.ws.readyState !== 1 || !p.publicKey) continue;
        if (typeof _advertMesh.isAddressProven === 'function' && !_advertMesh.isAddressProven(nodeId)) continue;   // 1.4.92
        const pub = Buffer.isBuffer(p.publicKey) ? p.publicKey.toString('hex') : String(p.publicKey);
        if (!/^[0-9a-f]{64}$/.test(pub)) continue;
        out.push({ node_id: nodeId, address: p.address, last_seen: p.lastSeen || Date.now(),
                   version: p.version || '1.0.0', public_key: pub });
      }
    } catch (_) {}
    return out.sort((a, b) => b.last_seen - a.last_seen).slice(0, 500);
  }

  buildPoolResponse() {
    const now   = Date.now();
    const nodes = this._admittedEntries();

    const body = JSON.stringify({
      version:   this._db ? parseInt(this._db.getGovParam('governance_version', '0')) : 0,
      generated: now,
      node_count: nodes.length,
      nodes,
    });

    // Sign the response with our node key so recipients can verify authenticity
    const sig = this._identity.signMessage(Buffer.from(body)).toString('hex');

    return JSON.stringify({
      payload: JSON.parse(body),
      payload_json: body,          // the exact signed bytes: verifiers need not re-encode JSON (1.4.92)
      sig,
      signer: this._identity.nodeId,
      signer_pubkey: Buffer.from(this._identity.publicKey).toString('hex'),
      // 1.4.92: this node's OWN admission certificate (signed approvals from the nodes that admitted
      // it), so an app can decide to trust this signer offline from keys it already trusts — even
      // when every node it knew is unreachable. Self-authenticating; 'genesis' for the first node.
      signer_cert: this._ownCert(),
    });
  }

  _ownCert() {
    try {
      const r = this._db && this._db._db.prepare('SELECT admission_cert FROM sov_operator_registry WHERE node_id = ?')
        .get(this._identity.nodeId);
      const raw = String((r && r.admission_cert) || '');
      if (raw === 'genesis') return 'genesis';
      const c = raw ? JSON.parse(raw) : [];
      return Array.isArray(c) ? c.slice(0, 64) : [];
    } catch (_) { return []; }
  }

  // ── Fetch pool from a remote node ─────────────────────────────────────────

  async fetchFromNode(address) {
    const url = `http://${address}/relay-pool`;
    return new Promise((resolve, reject) => {
      const mod = url.startsWith('https') ? https : http;
      const req = mod.get(url, { timeout: 10000 }, (res) => {
        let data = '';
        res.on('data', chunk => data += chunk);
        res.on('end', () => {
          try {
            const parsed = JSON.parse(data);
            const nodes  = parsed.payload ? parsed.payload.nodes : parsed.nodes;
            if (!Array.isArray(nodes)) { reject(new Error('Invalid pool format')); return; }
            resolve(nodes);
          } catch (err) {
            reject(err);
          }
        });
      });
      req.on('error', reject);
      req.on('timeout', () => { req.destroy(); reject(new Error('Timeout')); });
    });
  }

  // ── Update pool when a peer comes online ─────────────────────────────────

  addOrUpdate(nodeId, address, version) {
    if (!nodeId || !address) return;
    const existing = this._pool.get(nodeId);
    this._pool.set(nodeId, {
      address,
      // firstSeen is the reputation clock — set once, preserved across updates and
      // restarts (persisted to disk). It is this node's OWN observation of how long
      // the peer has been present, so it can't be gamed by a peer lying about itself.
      firstSeen: (existing && existing.firstSeen) ? existing.firstSeen : Date.now(),
      lastSeen: Date.now(),
      version:  version || '1.0.0',
    });
    // Save to disk periodically (not every update — too much I/O)
    if (this._pool.size % 10 === 0) this._saveToDisk();
  }

  // Link the peer mesh so liveness can be read from the true live-peer set
  // (verified peers with an open socket, heartbeat-refreshed, reaped at 135s).
  setMesh(mesh) { this._mesh = mesh; }

  // Addresses that are ALIVE RIGHT NOW — the citizen-facing failover list.
  // Prefers the mesh live-peer set (proven by heartbeat); falls back to a short
  // liveness window if no mesh is wired. Stops dead VPS + ephemeral test IDs from
  // lingering in the citizen node list for a week (the 7-day pool is bootstrap-only).
  getAliveAddresses(count = 50) {
    if (this._mesh && typeof this._mesh.activePeers === 'function') {
      const now = Date.now();
      // Map address -> earliest firstSeen from the persisted pool (survives restarts).
      const firstByAddr = new Map();
      for (const e of this._pool.values()) {
        if (!e.address) continue;
        const f = e.firstSeen || now;
        if (!firstByAddr.has(e.address) || f < firstByAddr.get(e.address)) firstByAddr.set(e.address, f);
      }
      const seen = new Set();
      const cand = [];
      const _peers = typeof this._mesh.provenPeers === 'function' ? this._mesh.provenPeers() : this._mesh.activePeers();   // 1.4.92
      for (const p of _peers) {
        if (!p || !p.address || seen.has(p.address)) continue;
        seen.add(p.address);
        cand.push({ address: p.address, uptime: now - (firstByAddr.get(p.address) || now) });
      }
      // REPUTATION-WEIGHTED (king 2026-07-24): citizens should land on PROVEN nodes.
      // Hold back peers below MIN_SERVE_UPTIME_MS and sort the rest longest-uptime
      // first, so a fresh/throwaway home node is never the gateway a citizen gets.
      // Never return an empty list though — if nothing is proven yet (e.g. right
      // after a fleet restart), fall back to all active peers so the app can connect.
      const proven = cand.filter(c => c.uptime >= MIN_SERVE_UPTIME_MS)
                         .sort((a, b) => b.uptime - a.uptime);
      const ranked = proven.length ? proven : cand.sort((a, b) => b.uptime - a.uptime);
      return ranked.slice(0, count).map(c => c.address);
    }
    const now = Date.now();
    return [...this._pool.entries()]
      .filter(([, e]) => now - e.lastSeen < ALIVE_MS)
      .sort((a, b) => b[1].lastSeen - a[1].lastSeen)
      .slice(0, count)
      .map(([, e]) => e.address);
  }

  markOffline(nodeId) {
    const entry = this._pool.get(nodeId);
    if (entry) {
      // Don't remove — keep address for reconnection attempts
      // Just update last_seen so staleness filter applies after 7 days
      entry.lastSeen = Date.now() - (STALE_MS * 0.9); // mark near-stale
    }
  }

  // ── Get addresses for bootstrap ───────────────────────────────────────────

  getBootstrapAddresses(count = 20) {
    const now     = Date.now();
    const entries = [...this._pool.entries()]
      .filter(([, e]) => now - e.lastSeen < STALE_MS)
      .sort((a, b) => b[1].lastSeen - a[1].lastSeen) // most recently seen first
      .slice(0, count)
      .map(([, e]) => e.address);
    return entries;
  }

  // ── Merge pool data received from peers ──────────────────────────────────

  mergeFromPeer(nodes) {
    if (!Array.isArray(nodes)) return;
    let added = 0;
    for (const node of nodes) {
      if (!node.node_id || !node.address) continue;

      // Reinstalling a node, or a home operator's IP changing, produces a NEW
      // identity at an address we already know. Accepting both leaves a ghost that
      // never dies: pruning it here only lasts until a peer gossips it back, so the
      // published count drifts away from the number of nodes that actually exist.
      //
      // If we already hold a DIFFERENT identity for this address and ours is fresher,
      // the incoming one is a superseded ghost — ignore it.
      const incomingSeen = node.last_seen || Date.now();
      let supersededByFresherIdentity = false;
      for (const [knownId, known] of this._pool.entries()) {
        if (knownId === node.node_id) continue;
        if (known.address !== node.address) continue;
        if ((known.lastSeen || 0) >= incomingSeen) { supersededByFresherIdentity = true; break; }
      }
      if (supersededByFresherIdentity) continue;

      if (!this._pool.has(node.node_id)) {
        this._pool.set(node.node_id, {
          address:  node.address,
          lastSeen: incomingSeen,
          version:  node.version || '1.0.0',
        });
        // A fresher identity at this address retires the older ones we were holding.
        for (const [knownId, known] of [...this._pool.entries()]) {
          if (knownId !== node.node_id && known.address === node.address &&
              (known.lastSeen || 0) < incomingSeen) {
            this._pool.delete(knownId);
          }
        }
        added++;
      }
    }
    if (added > 0) this._saveToDisk();
    return added;
  }

  // ── On first boot — fetch from all bootstrap seeds ────────────────────────

  async bootstrapFromSeeds(bootstrapSeeds) {
    global.sovLog.debug(`      Fetching relay pool from ${bootstrapSeeds.length} bootstrap seeds...`);
    let totalFetched = 0;

    for (const seed of bootstrapSeeds) {
      try {
        const nodes = await this.fetchFromNode(seed);
        const added = this.mergeFromPeer(nodes);
        totalFetched += added || 0;
        global.sovLog.debug(`      ✓ ${seed}: ${nodes.length} nodes (${added} new)`);
      } catch (err) {
        global.sovLog.debug(`      ✗ ${seed}: ${err.message}`);
      }
    }

    if (totalFetched > 0) {
      global.sovLog.info(`      Relay pool: ${this._pool.size} total known nodes`);
    }
    return totalFetched;
  }

  // ── Disk persistence ──────────────────────────────────────────────────────

  _saveToDisk() {
    try {
      const now = Date.now();

      // Prune stale entries before saving
      for (const [nodeId, entry] of this._pool) {
        if (now - entry.lastSeen > STALE_MS) this._pool.delete(nodeId);
      }

      // Limit size
      const entries = [...this._pool.entries()]
        .sort((a, b) => b[1].lastSeen - a[1].lastSeen)
        .slice(0, MAX_POOL);

      const data = Object.fromEntries(entries);
      fs.writeFileSync(POOL_FILE, JSON.stringify(data, null, 2));
    } catch (_) {}
  }

  _loadFromDisk() {
    if (!fs.existsSync(POOL_FILE)) return;
    try {
      const data = JSON.parse(fs.readFileSync(POOL_FILE, 'utf8'));
      for (const [nodeId, entry] of Object.entries(data)) {
        this._pool.set(nodeId, entry);
      }
      global.sovLog.info(`      Relay pool loaded: ${this._pool.size} known nodes from disk`);
    } catch (_) {}
  }

  size() { return this._pool.size; }

  stop() { this._saveToDisk(); }
}

// ─────────────────────────────────────────────────────────────────────────────
// SOV LOGIN SDK — Helper functions for the SOV Auth Portal
// ─────────────────────────────────────────────────────────────────────────────

function _ensureSovLoginSdkTables(db) {
  if (!db) return;
  try {
    db._db.exec(`
      CREATE TABLE IF NOT EXISTS sov_platforms (
        platform_id    TEXT PRIMARY KEY,
        domain         TEXT NOT NULL UNIQUE,
        public_key_hex TEXT NOT NULL DEFAULT '',
        return_url     TEXT NOT NULL DEFAULT '',
        registered_at  INTEGER NOT NULL,
        active         INTEGER NOT NULL DEFAULT 1
      );
      CREATE TABLE IF NOT EXISTS sov_auth_sessions (
        session_id   TEXT PRIMARY KEY,
        platform_id  TEXT NOT NULL,
        return_url   TEXT NOT NULL,
        status       TEXT NOT NULL DEFAULT 'pending',
        sovereign_id TEXT NOT NULL DEFAULT '',
        palm_name    TEXT NOT NULL DEFAULT '',
        created_at   INTEGER NOT NULL,
        expires_at   INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS sov_citizen_links (
        link_id           TEXT PRIMARY KEY,
        sovereign_id      TEXT NOT NULL,
        platform_id       TEXT NOT NULL,
        platform_domain   TEXT NOT NULL,
        password_verifier TEXT NOT NULL,
        binding_sig       TEXT NOT NULL,
        network_sig       TEXT NOT NULL,
        issued_at         INTEGER NOT NULL,
        UNIQUE(sovereign_id, platform_id)
      );
      -- Flow A2 — app-mediated Path A (phishing-proof): citizen never types seed in browser.
      -- Platform → /sov-login/initiate-app → returns pairing_code shown in browser.
      -- Citizen opens SOV app → enters code → /sov-login/check-app → confirms domain →
      -- taps "Yes" → app signs Ed25519 → /sov-login/authorize-app → relay fires SOV_LINK_CREATED.
      CREATE TABLE IF NOT EXISTS sov_app_pairings (
        pairing_code TEXT PRIMARY KEY,         -- 6-digit string, leading zeros preserved
        session_id   TEXT NOT NULL,            -- FK to sov_auth_sessions
        expires_at   INTEGER NOT NULL,         -- created_at + 300_000 ms
        used_at      INTEGER NOT NULL DEFAULT 0
      );
      CREATE INDEX IF NOT EXISTS idx_app_pairings_session ON sov_app_pairings(session_id);
    `);
    // Migration: add flow_type to sov_auth_sessions for legacy rows
    try { db._db.exec("ALTER TABLE sov_auth_sessions ADD COLUMN flow_type TEXT DEFAULT 'browser'"); } catch (_) { /* column already exists */ }
  } catch (e) { /* tables may already exist */ }
  // sovlink-v2: plugin_hash column for fast install_hash lookup
  try { db._db.exec(`ALTER TABLE sov_citizen_links ADD COLUMN plugin_hash TEXT DEFAULT NULL`); } catch(e) { /* column exists */ }
  try { db._db.exec(`CREATE INDEX IF NOT EXISTS idx_scl_plugin_hash ON sov_citizen_links(plugin_hash)`); } catch(e) {}
  // Security hardening 2026-05-20 — per claude-afri review:
  //   • callback_secret: HMAC secret returned to platform at /register;
  //     relay sends X-Sov-Callback-Hmac on every callback for that platform
  //     THAT HOLDS ONE. Corrected 2026-08-14: "every callback" was false —
  //     the sender signs only `if (secret)` and attaches only
  //     `if (callbackHmac)` (see the callback block below), so a row whose
  //     callback_secret is blank produced a callback with NO header at all.
  //     A blank row WAS reachable: /sov-link/generate-plugin upserted a
  //     platform WITHOUT this column (endpoint retired 2026-10-02), and a PLATFORM_BROADCAST used to blank
  //     it. Absent is not "unsigned but honest" — to a receiver that treats a
  //     missing header as nothing-to-check it is indistinguishable from valid.
  //     The callback block below now refuses rather than downgrading.
  //   • sov_login_attempts: per-citizen failed-password tracker for lockout.
  try { db._db.exec(`ALTER TABLE sov_platforms ADD COLUMN callback_secret TEXT DEFAULT ''`); } catch(e) {}
  // Sealed-launch compliance 2026-05-20 — per Addendum §905 (no admin key):
  //   • registered_by_sovereign_id: citizen who first claimed this domain
  //     (only that citizen can re-register / rotate secret)
  //   • x25519_pubkey_hex: platform server's X25519 public key (used to
  //     encrypt callback_secret on every /register so the secret never
  //     travels on the wire in plaintext)
  //   • register_fee_seeds: fee actually deducted at registration (audit)
  try { db._db.exec(`ALTER TABLE sov_platforms ADD COLUMN registered_by_sovereign_id TEXT DEFAULT ''`); } catch(e) {}
  try { db._db.exec(`ALTER TABLE sov_platforms ADD COLUMN x25519_pubkey_hex TEXT DEFAULT ''`); } catch(e) {}
  try { db._db.exec(`ALTER TABLE sov_platforms ADD COLUMN register_fee_seeds INTEGER DEFAULT 0`); } catch(e) {}
  // ANNUAL registration (king 2026-07-19): expires_at = register/renew + platform_fee_period_days.
  // Rows with 0/NULL are LEGACY (pre-annual) — grandfathered until their next renewal.
  try { db._db.exec(`ALTER TABLE sov_platforms ADD COLUMN expires_at INTEGER DEFAULT 0`); } catch(e) {}
  try {
    db._db.exec(`
      CREATE TABLE IF NOT EXISTS sov_login_attempts (
        sovereign_id  TEXT NOT NULL,
        platform_id   TEXT NOT NULL,
        attempt_count INTEGER NOT NULL DEFAULT 0,
        last_attempt  INTEGER NOT NULL DEFAULT 0,
        locked_until  INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (sovereign_id, platform_id)
      )
    `);
  } catch (_) {}
}

function _getSovAesKey(identity) {
  return crypto.createHash('sha256')
    .update('sov-auth-portal-seal-v1|' + identity.nodeId)
    .digest();
}

function _sealAuthToken(data, aesKey) {
  const iv  = crypto.randomBytes(12);
  const cip = crypto.createCipheriv('aes-256-gcm', aesKey, iv);
  const enc = Buffer.concat([cip.update(JSON.stringify(data), 'utf8'), cip.final()]);
  const tag = cip.getAuthTag();
  return Buffer.concat([iv, tag, enc]).toString('base64url');
}

function _unsealAuthToken(token, aesKey) {
  try {
    const buf = Buffer.from(token, 'base64url');
    const iv  = buf.slice(0, 12);
    const tag = buf.slice(12, 28);
    const enc = buf.slice(28);
    const dec = crypto.createDecipheriv('aes-256-gcm', aesKey, iv);
    dec.setAuthTag(tag);
    return JSON.parse(Buffer.concat([dec.update(enc), dec.final()]).toString('utf8'));
  } catch (e) { return null; }
}

// Password verifier: bcrypt (modular-crypt `$2a$` string, self-salted, cost 12).
// Aligned 2026-06-10 with the first integrating platform so it verifies a login
// with NATIVE password_verify($entered, $verifier) — no scrypt re-impl, no plaintext.
const BCRYPT_COST = 12;
function _computePasswordVerifier(password /*, sovereignId, platformDomain */) {
  return require('bcryptjs').hashSync(password, BCRYPT_COST);
}
// bcrypt is self-salted: must compare, never recompute-and-string-equal.
function _verifyPasswordAgainstVerifier(password, verifier) {
  try { return require('bcryptjs').compareSync(password, verifier || ''); }
  catch (_) { return false; }
}

// A real bcrypt hash of a fixed throwaway string, computed once at startup.
// Its ONLY purpose is to cost the same as a genuine comparison, so that
// verify-password takes the same time whether or not the citizen is linked.
// bcryptjs.compareSync returns immediately on an empty/'' verifier, so without
// this the response body could be identical and the CLOCK would still answer
// "does this citizen have an account here?". Generated rather than hardcoded so
// it tracks the cost factor if that is ever raised.
let _DUMMY_PW_VERIFIER = '';
try {
  _DUMMY_PW_VERIFIER = require('bcryptjs').hashSync('sov-oracle-dummy', 12);
} catch (_) { _DUMMY_PW_VERIFIER = ''; }

// ── Sealed-box encryption for /sov-platform/register ──────────────────────────
// Anonymous-sender public-key crypto. The platform supplies its X25519 public
// key at registration time; the relay encrypts the callback_secret to that
// public key using an EPHEMERAL X25519 keypair (anonymous sender). The
// envelope is decryptable only by the platform server holding the matching
// X25519 private key — no other party (including the relay, after the
// ephemeral key is forgotten) can decrypt.
//
// Output JSON envelope:
//   { v: 1, ephemeral_pubkey: <32B hex>, nonce: <24B hex>, ciphertext: <Nbytes hex> }
//
// PHP decryption (libsodium):
//   $env = json_decode(...);
//   $ephemeral = hex2bin($env['ephemeral_pubkey']);
//   $nonce     = hex2bin($env['nonce']);
//   $ct        = hex2bin($env['ciphertext']);
//   $shared    = sodium_crypto_box_beforenm($ephemeral, $platformPrivKey);
//   $plaintext = sodium_crypto_box_open_afternm($ct, $nonce, $shared);
function _sealSecretToPubKey(plaintext, recipientX25519PubKeyHex) {
  const nacl = require('tweetnacl');
  const recipientPub = Buffer.from(recipientX25519PubKeyHex, 'hex');
  if (recipientPub.length !== 32) {
    throw new Error('recipient X25519 public key must be 32 bytes (64 hex)');
  }
  const ephemeral = nacl.box.keyPair();
  const nonce     = nacl.randomBytes(24);
  const ciphertext = nacl.box(
    Buffer.from(plaintext, 'utf8'),
    nonce,
    recipientPub,
    ephemeral.secretKey,
  );
  // Wipe ephemeral private key from memory ASAP (we never need it again)
  ephemeral.secretKey.fill(0);
  return JSON.stringify({
    v: 1,
    ephemeral_pubkey: Buffer.from(ephemeral.publicKey).toString('hex'),
    nonce:            Buffer.from(nonce).toString('hex'),
    ciphertext:       Buffer.from(ciphertext).toString('hex'),
  });
}

// ── Shared platform-registration core ─ used by BOTH the HTTP POST
//    /sov-platform/register endpoint AND the wallet-side WSS PLATFORM_REGISTER
//    op-code. No external IP exposure: a wallet connects OUT over WSS, signs the
//    canonical payload, DEDUCTS platform_register_fee SOV from the owner and
//    CREDITS it to the witness_operator pool. It is not a burn: supply is
//    unchanged, the money moves. Saying "burn" here invited someone to make
//    it one. Returns { status, body }
//    so the caller decides how to transmit (HTTP res or WSS _send).
async function _doPlatformRegister(db, identity, broadcast, input) {
  if (!db) return { status: 503, body: { success: false, error: 'DB_UNAVAILABLE' } };
  _ensureSovLoginSdkTables(db);
  const { domain, return_url, registering_sovereign_id, x25519_pubkey_hex, timestamp, signature } = input || {};
  if (!domain || !return_url || !registering_sovereign_id || !x25519_pubkey_hex || !timestamp || !signature) {
    return { status: 400, body: { success: false, error: 'MISSING_FIELDS' } };
  }
  const now = Date.now();
  if (Math.abs(now - timestamp) > 60000) return { status: 400, body: { success: false, error: 'STALE_TIMESTAMP' } };
  const govLogin = db._db.prepare("SELECT param_value FROM sov_governance_params WHERE param_key = 'sov_login'").get();
  if (!govLogin || govLogin.param_value !== '1') return { status: 200, body: { success: false, error: 'SOV_LOGIN_NOT_ACTIVATED' } };
  const enrollment = db._db.prepare('SELECT public_key_hex FROM sov_enrollments WHERE sovereign_id = ?').get(registering_sovereign_id);
  if (!enrollment || !enrollment.public_key_hex) return { status: 403, body: { success: false, error: 'NOT_ENROLLED' } };
  const cleanDomain = domain.toLowerCase().replace(/^https?:\/\//, '').split('/')[0];
  const canonical = `sov-platform-register-v1|${cleanDomain}|${return_url}|${registering_sovereign_id}|${x25519_pubkey_hex}|${timestamp}`;
  let sigValid = false;
  try {
    sigValid = require('../security/node_identity').NodeIdentity.verify(
      Buffer.from(canonical, 'utf-8'), Buffer.from(signature, 'hex'), Buffer.from(enrollment.public_key_hex, 'hex'));
  } catch (_) { sigValid = false; }
  if (!sigValid) return { status: 403, body: { success: false, error: 'INVALID_SIGNATURE' } };
  if (!/^[0-9a-fA-F]{64}$/.test(x25519_pubkey_hex)) return { status: 400, body: { success: false, error: 'INVALID_X25519_PUBKEY' } };
  const platformId = crypto.createHash('sha256').update(cleanDomain).digest('hex').substring(0, 32);
  const existing = db._db.prepare('SELECT registered_by_sovereign_id, callback_secret FROM sov_platforms WHERE platform_id = ?').get(platformId);
  if (existing && existing.registered_by_sovereign_id && existing.registered_by_sovereign_id !== '' && existing.registered_by_sovereign_id !== registering_sovereign_id) {
    return { status: 409, body: { success: false, error: 'DOMAIN_ALREADY_CLAIMED', message: 'This domain was registered by a different citizen.' } };
  }
  const feeRow = db._db.prepare("SELECT param_value FROM sov_governance_params WHERE param_key = 'platform_register_fee'").get();
  const feeSov = parseFloat((feeRow && feeRow.param_value) ? feeRow.param_value : '10');
  const feeSeeds = Math.round(feeSov * 1000000);
  const priorDisc = db.readDisc(registering_sovereign_id);
  if (!priorDisc) return { status: 403, body: { success: false, error: 'NO_DISC_SLOT' } };
  if (priorDisc.spendable_seeds < feeSeeds) {
    return { status: 402, body: { success: false, error: 'INSUFFICIENT_BALANCE', required_seeds: feeSeeds, have_seeds: priorDisc.spendable_seeds } };
  }
  // 1.4.90: the fee is an OWNER op — owner -> operator pool, granted by a majority of nodes on
  // the owner's slot and applied on every node (peers used to keep the owner's balance untouched).
  if (feeSeeds > 0) {
    const fee = await db.ledger.commitOwnerOp({
      kind: 'platform_fee', ref: platformId, owner: { acct: registering_sovereign_id },
      moves: [{ acct: registering_sovereign_id, d: -feeSeeds }],
      pools: [{ pool: 'witness_operator', d: feeSeeds }],
    });
    if (!fee.ok) {
      return { status: fee.error === 'LEDGER_INSUFFICIENT' ? 402 : 503,
               body: { success: false, error: fee.error === 'LEDGER_INSUFFICIENT' ? 'INSUFFICIENT_BALANCE' : fee.error } };
    }
  }
  // TRANSPARENCY (king 2026-07-19): the fee debit must appear in the payer's
  // payment history with its destination — owner → operator pool.
  const feeTxId = `platfee-${platformId}-${now}`;
  try {
    if (db.insertTransaction) db.insertTransaction({
      tx_id: feeTxId, tx_hash: crypto.createHash('sha256').update(`${feeTxId}:${feeSeeds}`).digest('hex'),
      from_id: registering_sovereign_id, to_id: 'SOV-POOL-WITNESS-OPERATOR', amount_seeds: feeSeeds,
      memo: `SOV Login platform registration (annual) — ${cleanDomain}`,
      status: 'confirmed', confirmed_at: now, created_at: now,
    });
  } catch (_) {}
  // ANNUAL: registration + every renewal (re-calling this endpoint charges again) buys a year.
  const pfpRow = db._db.prepare("SELECT param_value FROM sov_governance_params WHERE param_key = 'platform_fee_period_days'").get();
  const periodDays = parseInt((pfpRow && pfpRow.param_value) ? pfpRow.param_value : '365') || 365;
  const platformExpiresAt = now + periodDays * 86400000;
  const callbackSecret = crypto.randomBytes(32).toString('hex');
  if (existing) {
    db._db.prepare('UPDATE sov_platforms SET return_url = ?, callback_secret = ?, x25519_pubkey_hex = ?, register_fee_seeds = ?, active = 1, expires_at = ? WHERE platform_id = ?').run(return_url, callbackSecret, x25519_pubkey_hex, feeSeeds, platformExpiresAt, platformId);
  } else {
    db._db.prepare('INSERT INTO sov_platforms (platform_id, domain, public_key_hex, return_url, registered_at, callback_secret, registered_by_sovereign_id, x25519_pubkey_hex, register_fee_seeds, active, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?)').run(platformId, cleanDomain, '', return_url, now, callbackSecret, registering_sovereign_id, x25519_pubkey_hex, feeSeeds, platformExpiresAt);
  }
  try {
    if (broadcast) broadcast('PLATFORM_BROADCAST', { platform_id: platformId, domain: cleanDomain, return_url, public_key_hex: '', callback_secret: callbackSecret, registered_by_sovereign_id: registering_sovereign_id, x25519_pubkey_hex, register_fee_seeds: feeSeeds, registered_at: now, expires_at: platformExpiresAt, fee_tx: { tx_id: feeTxId, from_id: registering_sovereign_id, amount_seeds: feeSeeds, memo: `SOV Login platform registration (annual) — ${cleanDomain}` } });
  } catch (_) {}
  const sealedSecret = _sealSecretToPubKey(callbackSecret, x25519_pubkey_hex);
  const networkPubKeyHex = identity && typeof identity.publicKey === 'function' ? identity.publicKey().toString('hex') : (identity && identity.nodeId ? identity.nodeId : '');
  // Operator-configured; the examples are RFC 5737 documentation addresses
  // and are only reached if nothing is configured (which the node logs).
  const canonicalRelayIps = advertisedNodes(db);
  global.sovLog.info(`SOV_PLATFORM_REGISTER: domain=${cleanDomain} by=${registering_sovereign_id} fee=${feeSov}SOV id=${platformId}`);
  return { status: 200, body: { success: true, platform_id: platformId, sealed_callback_secret: sealedSecret, network_pubkey_hex: networkPubKeyHex, canonical_relay_ips: canonicalRelayIps, hmac_algorithm: 'HMAC-SHA256', hmac_header_name: 'X-Sov-Callback-Hmac', sealed_secret_format: 'nacl.box (libsodium crypto_box)', fee_seeds_routed_to_operator_pool: feeSeeds, balance_after_fee_seeds: priorDisc.balance_seeds - feeSeeds } };
}

// (2026-10-03) _getSovlinkV2Key/_buildSovlinkV2File removed: their only caller was the retired
// /sov-link/generate-plugin route, and _buildSovlinkV2File referenced an undefined `db`.

// Parse just the install_hash from the file header (no decryption needed)
function _parseSovlinkV2InstallHash(fileBuf) {
  if (!Buffer.isBuffer(fileBuf) || fileBuf.length < 133) return null;
  if (fileBuf.slice(0, 8).toString('ascii') !== 'SOVLINK2') return null;
  if (fileBuf[8] !== 0x02) return null;
  return fileBuf.slice(73, 105).toString('hex');  // installHash = bytes 73-104
}

// _keysFromMnemonic() and _buildAuthPortalHtml() were removed 2026-10-02 with the retired
// /sov-link/generate-plugin endpoint. The first rebuilt a citizen's keys from their seed ON
// THE NODE; the second rendered a web page with twelve seed-word boxes. Neither had a caller.
// A seed never leaves the device, so neither belongs in node code at all.

// ── HTTP handler — serves /relay-pool and /download endpoints ─────────────────
// This is the HTTP server that runs alongside the WSS gateway.
// Citizens download the snap installer from here.
// Other nodes fetch the relay pool from here.

function createDiscoveryServer(identity, db, relayPool, network) {
  const port   = parseInt(process.env.DISCOVERY_PORT || '80');
  const aesKey = _getSovAesKey(identity); // pre-derive key once

  // peerMesh is wired AFTER server creation (chicken-egg in index.js startup
  // order). server.setPeerMesh(pm) is called once peer mesh is online.
  // Until then, broadcast calls become no-ops and locally-minted state is
  // still queryable on the local node — peers just won't see it.
  let _peerMesh = null;
  // Wallet-side WSS PLATFORM_REGISTER delegates here (citizen_gateway calls it).
  relayPool.platformRegister = (input) => _doPlatformRegister(db, identity, _broadcast, input);
  function _broadcast(type, payload) {
    if (_peerMesh && typeof _peerMesh.broadcast === 'function') {
      try { _peerMesh.broadcast(type, payload); } catch (e) {
        global.sovLog.warn(`[relay_pool] broadcast(${type}) failed: ${e.message}`);
      }
    }
  }

  // Ensure SOV Login SDK tables exist on startup
  if (db) {
    setTimeout(() => { try { _ensureSovLoginSdkTables(db); } catch (e) {} }, 2000);
  }

  // ── SOV Login self-cleaning (Master Blueprint Part 5 — Storage Control) ───
  // Expired pairing codes and expired pending sessions are deleted hourly so
  // the relay never grows unbounded. sov_citizen_links and sov_platforms are
  // PERMANENT — they have no cleanup.
  function _cleanupExpiredSovLoginRows() {
    if (!db) return;
    try {
      _ensureSovLoginSdkTables(db);
      const now = Date.now();
      const r1 = db._db.prepare('DELETE FROM sov_app_pairings WHERE expires_at < ?').run(now);
      // Verified sessions are kept (audit trail). Only delete still-pending or
      // never-completed sessions whose 5-minute window has lapsed.
      const r2 = db._db.prepare("DELETE FROM sov_auth_sessions WHERE expires_at < ? AND status != 'verified'").run(now);
      if ((r1.changes || 0) + (r2.changes || 0) > 0) {
        global.sovLog.debug(`[SOV Login cleanup] pruned ${r1.changes||0} pairings, ${r2.changes||0} stale sessions`);
      }
    } catch (e) {
      global.sovLog.warn(`[SOV Login cleanup] error: ${e.message}`);
    }
  }
  // First run at 60s after boot, then every 60 minutes (same cadence as
  // _cleanupExpiredOrders in exchange_engine.js — matches blueprint convention).
  setTimeout(_cleanupExpiredSovLoginRows, 60 * 1000);
  setInterval(_cleanupExpiredSovLoginRows, 60 * 60 * 1000);

  // 1.4.92: public discovery/login endpoints are rate-limited per source IP (the socket's, never a
  // header) so nobody can scrape or hammer them. 60 requests a minute per IP per endpoint group is
  // far above what an app, a platform or a peer node needs.
  const _RL_WINDOW_MS = 60 * 1000, _RL_MAX = 60;
  const _rl = new Map();
  const _rlGroup = (u) => u === '/relay-pool' || u === '/relay-pool/latest' ? 'pool'
    : u.startsWith('/sdk/') ? 'sdk' : u === '/node-info' ? 'info'
    : u.startsWith('/sov-login/challenge') ? 'login' : null;
  const _rlLimited = (req, u) => {
    const g = _rlGroup(u); if (!g) return false;
    const ip = String((req.socket && req.socket.remoteAddress) || '').replace(/^::ffff:/, '');
    const k = g + '|' + ip, now = Date.now();
    let e = _rl.get(k);
    if (!e || now - e.t > _RL_WINDOW_MS) { e = { t: now, n: 0 }; _rl.set(k, e); }
    e.n++;
    if (_rl.size > 20000) { for (const [kk, v] of _rl) if (now - v.t > _RL_WINDOW_MS) _rl.delete(kk); }
    return e.n > _RL_MAX;
  };

  const server = http.createServer((req, res) => {
    const url = req.url.split('?')[0];
    if (_rlLimited(req, url)) {
      res.writeHead(429, { 'Content-Type': 'application/json', 'Retry-After': '60' });
      res.end(JSON.stringify({ success: false, error: 'RATE_LIMITED' }));
      return;
    }

    // ── GET /relay-pool — return signed list of known nodes ────────────────
    if (url === '/relay-pool') {
      const body = relayPool.buildPoolResponse();
      res.writeHead(200, {
        'Content-Type':  'application/json',
        'Cache-Control': 'public, max-age=60',
      });
      res.end(body);
      return;
    }

    // ── GET /economy/snapshot — live transparency endpoint ─────────────────
    // Returns every accounting location at this instant so any citizen can
    // verify the 50M invariant holds:
    //   sum(pool remaining) + sum(citizen wallets) = 50,000,000 SOV
    //
    // Used by the Flutter "SOV Network Economy" widget to render real-time
    // pool balances and flow. Cached at the HTTP layer 5s to avoid stampedes.
    if (url === '/economy/snapshot') {
      try {
        const pools = db.allPools ? db.allPools() : [];
        const walletRow = db._db.prepare('SELECT COALESCE(SUM(balance_seeds),0) AS s, COUNT(*) AS c FROM sov_disc').get();
        const wallet_total_seeds = walletRow.s || 0;
        // [GHOST-COUNT 2026-08-14] citizen_count must count HUMANS, not wallet slots.
        // sov_disc gains a 0-balance row for any sovereign_id that merely opens a
        // signed session — touchLiveness() → ensureDiscEntry() (db.js:1018) is pure
        // liveness bookkeeping and does not imply an enrollment. Counting sov_disc
        // therefore lets any stranger who connects once inflate the number this
        // PUBLIC transparency endpoint reports forever (proven live on the genesis
        // chain: 1 row in sov_enrollments, 2 in sov_disc, snapshot said 2 citizens).
        // db.citizenCount() counts sov_enrollments — the same figure the enrollment
        // tier gradient trusts. Money still comes from sov_disc: balances live there.
        const citizen_count = (typeof db.citizenCount === 'function')
          ? db.citizenCount()
          : (walletRow.c || 0);
        const pool_total_seeds = pools.reduce((sum, p) => sum + (p.remaining_seeds || 0), 0);
        // 1.4.90: escrow / vault / bond holdings are counted (they used to be in no total — D19),
        // and the check is EXACT: with every balance change a replicated op, the money is either
        // all accounted for or something is wrong.
        const holding_total_seeds = (typeof db.totalHoldings === 'function') ? db.totalHoldings() : 0;
        const grand_total_seeds = wallet_total_seeds + holding_total_seeds + pool_total_seeds;
        const expected_seeds = 50_000_000_000_000;
        const within_cap = (grand_total_seeds === expected_seeds);

        // ── The cap check ALONE cannot fail, and that was the problem ──────────────────────
        // reconcileSupplyPools() sets the enrolment pool's remaining so that
        // wallets + remaining lands exactly on the cap. So `grand_total <= cap` is true BY
        // CONSTRUCTION after every correction — it reported ok:true for 13 days while 60 SOV
        // of a real double-deduction sat absorbed in the enrolment pool's books.
        //
        // Two independent checks are added, and `ok` now requires all three:
        //   * no correction has been applied recently — a silent rewrite is not "ok"
        //   * the operator pool's distributed figure matches the payouts it actually recorded
        // Either would have caught this on the day it happened.
        let corrections = { count: 0, total_seeds: 0, recent_count: 0, recent_seeds: 0, last_at: null, last_delta_seeds: 0 };
        try { if (typeof db.supplyCorrections === 'function') corrections = db.supplyCorrections(); } catch (_) {}

        let operator_distributed = 0, operator_payout_rows = 0;
        try {
          const op = pools.find(p => p.pool_id === 'witness_operator');
          operator_distributed = op ? (op.distributed_seeds || 0) : 0;
          const pr = db._db.prepare('SELECT COALESCE(SUM(amount_seeds),0) s FROM sov_operator_payouts').get();
          operator_payout_rows = pr ? pr.s : 0;
        } catch (_) {}
        const operator_gap = operator_distributed - operator_payout_rows;

        const invariant_ok = within_cap && corrections.recent_count === 0 && operator_gap === 0;

        // ── Fee inflows — every fund that flows INTO a pool, publicly visible ──
        // (king transparency 2026-07-19). Source: sov_pool_inflow, written by
        // addToPool() on every collected fee (transfer / platform / exchange).
        const PERIOD_MS = 30 * 24 * 3600 * 1000;
        const curPeriod = Math.floor(Date.now() / PERIOD_MS);
        let inflowByPool = [], recentInflow = [], allTimeInflow = 0, operatorPaidTotal = 0, operatorPayoutCount = 0;
        try {
          inflowByPool = db._db.prepare('SELECT pool_id, COALESCE(SUM(seeds),0) AS total FROM sov_pool_inflow GROUP BY pool_id').all();
          allTimeInflow = db._db.prepare('SELECT COALESCE(SUM(seeds),0) AS s FROM sov_pool_inflow').get().s || 0;
          recentInflow = db._db.prepare("SELECT period_id, seeds FROM sov_pool_inflow WHERE pool_id = 'witness_operator' ORDER BY period_id DESC LIMIT 12").all();
        } catch (_) {}
        try {
          const payRow = db._db.prepare('SELECT COALESCE(SUM(amount_seeds),0) AS s, COUNT(*) AS c FROM sov_operator_payouts').get();
          operatorPaidTotal = payRow.s || 0; operatorPayoutCount = payRow.c || 0;
        } catch (_) {}

        const payload = {
          // [GHOST-COUNT 2026-08-14] v2 -> v3: the payload shape genuinely changed
          // (new `wallet_slot_count`, and `citizen_count` now means enrolled humans
          // rather than wallet slots), which is what a schema version is for. Both
          // known consumers already call the corrected shape "v3" while gating on
          // the PRESENCE of wallet_slot_count, not on this string
          // (lib/screens/economy_snapshot_screen.dart:160-164, and an integrating
          // platform’s transparency banner) — verified no consumer reads `schema` at
          // all, so
          // the bump aligns the label with the shape and breaks nothing.
          schema: 'sov-economy-snapshot-v4',
          ts: Date.now(),
          supply_cap_seeds: expected_seeds,
          pools: pools.map(p => ({
            pool_id:           p.pool_id,
            allocated_seeds:   p.allocated_seeds,
            remaining_seeds:   p.remaining_seeds,
            distributed_seeds: p.distributed_seeds,
          })),
          inflows: {
            current_period_id:    curPeriod,
            all_time_seeds:       allTimeInflow,
            by_pool:              inflowByPool.map(r => ({ pool_id: r.pool_id, total_seeds: r.total })),
            recent_operator_pool: recentInflow.map(r => ({ period_id: r.period_id, seeds: r.seeds })),
          },
          operator_payouts: {
            total_paid_seeds: operatorPaidTotal,
            payout_count:     operatorPayoutCount,
          },
          wallets: {
            citizen_count:    citizen_count,
            wallet_slot_count: walletRow.c,
            total_seeds:      wallet_total_seeds,
          },
          invariant: {
            grand_total_seeds,
            expected_seeds,
            ok: invariant_ok,
            within_cap,
            // A correction is an accounting rewrite of real money. It is published, never
            // absorbed: `ok` cannot be true while one has happened recently.
            corrections,
            // The operator pool's books against the payouts it actually recorded. This is the
            // check that would have shown 90 SOV distributed against 30 SOV of payouts.
            operator_pool: {
              distributed_seeds: operator_distributed,
              payout_rows_seeds: operator_payout_rows,
              gap_seeds: operator_gap,
            },
            // If false, network has a bug — citizens see this directly
            note: invariant_ok
              ? 'Total network supply within 50M cap; no corrections; operator pool reconciles'
              : (!within_cap ? 'SUPPLY INVARIANT BROKEN — alert governance'
                : corrections.recent_count > 0
                  ? `Books were auto-corrected ${corrections.recent_count}x recently (${(corrections.recent_seeds / 1e6).toFixed(4)} SOV) — the totals balance but something caused it`
                  : `Operator pool distributed ${(operator_distributed / 1e6).toFixed(4)} SOV against ${(operator_payout_rows / 1e6).toFixed(4)} SOV of recorded payouts`),
          },
        };
        res.writeHead(200, {
          'Content-Type':  'application/json',
          'Cache-Control': 'public, max-age=5',
          'Access-Control-Allow-Origin': '*',
        });
        res.end(JSON.stringify(payload));
      } catch (e) {
        res.writeHead(500);
        res.end(JSON.stringify({ success: false, error: e.message }));
      }
      return;
    }

    // ── GET /relay-pool/latest — clean pool JSON for platform plugins ─────────
    // Returns a compact relay pool specifically formatted for the platform plugin
    // and .sovlink files. Includes only port-80 http verify_endpoints.
    if (url === '/relay-pool/latest') {
      const nodeIp = process.env.RELAY_IP || (network && network.publicAddress ? network.publicAddress.split(':')[0] : '');
      // Build pool from known nodes — always include our 4 foundation nodes plus
      // any other nodes seen in the past 7 days
      // Built from the live network rather than a fixed list of "foundation"
      // nodes. A fixed list is wrong twice: it names machines that are meant to
      // be disposable, and it is copied into every .sovlink handed to a platform.
      let foundationHosts = [];
      try { foundationHosts = advertisedNodes(db); } catch (_) {}
      if (!foundationHosts.length && nodeIp) foundationHosts = [nodeIp];
      const foundationNodes = foundationHosts.map((h, i) => poolEntryFor(db, relayPool, h, i, nodeIp));
      // http verify_endpoints: port-80 nodes only (a node that shares :80 with another
      // service exposes this on a high port the public firewall may not allow)
      const verifyEndpoints = foundationNodes
        .filter(n => n.http_port === 80)
        .map(n => `http://${n.ip}/sov-link/verify-password`);

      const poolPayload = {
        version:             13,
        updated_at:          Date.now(),
        served_by:           nodeIp,
        nodes:               foundationNodes,
        verify_endpoints:    verifyEndpoints,
        pool_refresh_url:    `http://${nodeIp}/relay-pool/latest`,
        // THERE IS NO FOUNDER SIGNING KEY. `founder_pubkey_hex` was served here
        // until 2026-09-27 and is gone. It was dead on every side: nothing signed
        // with it, the app had already stopped shipping it (assets/relay_pool.json
        // "_TRUST_NOTE"), /sov-relay.snap.sig answers 404 because no signature is
        // produced, and the node's own manifest anchor is all zeros. Publishing it
        // only invited someone to rebuild a single point of trust around a key that
        // verifies nothing. Payload version 12 -> 13 marks the shape change.
        //
        // What legitimacy actually rests on: the nodes running the network agree on
        // the source it was built from - source_root attestation between EARNED
        // nodes, enforced by release_enforce_mode. See docs/NODE_INTEGRITY_DESIGN.md.
        // `source_root` below is this node's own root, so an operator can ask
        // several independent nodes and compare, which is the check that replaces
        // the signature. It costs nothing: the node already computed it at boot.
        source_root:         (typeof global !== 'undefined' && global.sovSourceRoot) || '',
      };
      res.writeHead(200, {
        'Content-Type':  'application/json',
        'Cache-Control': 'public, max-age=300',  // 5 min cache
        'Access-Control-Allow-Origin': '*',
      });
      res.end(JSON.stringify(poolPayload));
      return;
    }

    // ── GET /node-info — public node information ───────────────────────────
    if (url === '/node-info') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        node_id:   identity.nodeId,
        address:   network.publicAddress,
        version:   require('../../package.json').version,
        citizens:  db ? db.citizenCount() : 0,
        pool_size: relayPool.size(),
        // The root of the source this node is RUNNING. Published because it is the
        // replacement for the retired founder signature: anyone can fetch it from
        // several independent nodes and refuse a build the network does not run.
        // Already computed at boot (index.js) and already sent in every PEER_HELLO,
        // so exposing it costs nothing and reveals nothing - it is a hash of source
        // that is published in full.
        source_root: (typeof global !== 'undefined' && global.sovSourceRoot) || '',
        // Self-maintenance, visible from outside: free space and the disk guard's verdict.
        storage: (() => { try { const d = require('../storage/disk_guard').state();
          return { status: d.status, free_bytes: d.free_bytes, total_bytes: d.total_bytes, checked_at: d.checked_at }; }
          catch (_) { return null; } })(),
        timestamp: Date.now(),
      }));
      return;
    }

    // ── POST /sov-login/challenge — create login challenge for external sites ─
    if (url === '/sov-login/challenge') {
      if (req.method === 'OPTIONS') {
        res.writeHead(204, {
          'Access-Control-Allow-Origin':  '*',
          'Access-Control-Allow-Methods': 'POST, OPTIONS',
          'Access-Control-Allow-Headers': 'Content-Type',
        });
        res.end(); return;
      }
      if (req.method !== 'POST') { res.writeHead(405); res.end('POST required'); return; }
      let body = '';
      req.on('data', c => body += c);
      req.on('end', () => {
        res.setHeader('Content-Type', 'application/json');
        res.setHeader('Access-Control-Allow-Origin', '*');
        try {
          const input    = JSON.parse(body || '{}');
          const sessionId = input.session_id || crypto.randomBytes(16).toString('hex');
          const clientOrigin = input.client_origin || req.headers['origin'] || '';

          if (!db) { res.writeHead(503); res.end(JSON.stringify({ success: false, error: 'DB_UNAVAILABLE' })); return; }

          // Check sov_login governance param
          const govRow = db._db.prepare("SELECT param_value FROM sov_governance_params WHERE param_key = 'sov_login'").get();
          if (!govRow || govRow.param_value !== '1') {
            res.writeHead(200); res.end(JSON.stringify({ success: false, error: 'SOV_LOGIN_NOT_ACTIVATED' })); return;
          }

          const challenge = crypto.randomBytes(32).toString('hex');
          const now       = Date.now();
          const expiresAt = now + 10 * 60 * 1000; // 10 minutes

          db._db.prepare(`
            INSERT OR IGNORE INTO sov_login_sessions
              (session_id, challenge, client_origin, status, created_at, expires_at)
            VALUES (?, ?, ?, 'pending', ?, ?)
          `).run(sessionId, challenge, clientOrigin, now, expiresAt);

          const nodeIp = _selfHost(network) || '127.0.0.1';   // 1.4.92: never the Host header
          const port   = process.env.SOV_PORT || '443';
          const qrPayload = `sovlogin://${nodeIp}:${port}?s=${sessionId}&c=${challenge}`;

          global.sovLog.debug(`SOV_LOGIN_CHALLENGE_HTTP: session=${sessionId.slice(0,8)} origin=${clientOrigin}`);
          res.writeHead(200); res.end(JSON.stringify({
            success: true, session_id: sessionId, challenge, qr_payload: qrPayload,
            // Newcomers with no app: platforms render this as a "New to SOV? Scan to
            // download" QR next to the login QR. It points at the download PAGE/mirror
            // (device-detected get page), NEVER a node IP — the no-IP rule holds.
            download_url: process.env.SOV_DOWNLOAD_PAGE || 'https://sov-network.github.io/get.html',
            expires_at: expiresAt, ts: now,
          }));
        } catch (err) {
          global.sovLog.error(`SOV_LOGIN_CHALLENGE_ERROR: ${err.message}`);
          res.writeHead(500); res.end(JSON.stringify({ success: false, error: 'INTERNAL_ERROR' }));
        }
      });
      return;
    }

    // ── GET /sov-login/verify?session_id=xxx — poll login status ─────────────
    if (url === '/sov-login/verify') {
      res.setHeader('Content-Type', 'application/json');
      res.setHeader('Access-Control-Allow-Origin', '*');
      if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }
      try {
        const qs        = new URLSearchParams(req.url.split('?')[1] || '');
        const sessionId = qs.get('session_id') || '';
        if (!sessionId || !db) { res.writeHead(400); res.end(JSON.stringify({ success: false, error: 'MISSING_SESSION_ID' })); return; }

        const session = db._db.prepare('SELECT * FROM sov_login_sessions WHERE session_id = ?').get(sessionId);
        if (!session) { res.writeHead(200); res.end(JSON.stringify({ status: 'not_found', session_id: sessionId })); return; }

        if (session.status === 'pending' && session.expires_at < Date.now()) {
          db._db.prepare("UPDATE sov_login_sessions SET status = 'expired' WHERE session_id = ?").run(sessionId);
          res.writeHead(200); res.end(JSON.stringify({ status: 'expired', session_id: sessionId })); return;
        }

        res.writeHead(200); res.end(JSON.stringify({
          status:       session.status,
          session_id:   sessionId,
          sovereign_id: session.sovereign_id || null,
          verified_at:  session.verified_at  || null,
        }));
      } catch (err) {
        global.sovLog.error(`SOV_LOGIN_VERIFY_ERROR: ${err.message}`);
        res.writeHead(500); res.end(JSON.stringify({ success: false, error: 'INTERNAL_ERROR' }));
      }
      return;
    }

    // The dead pre-launch /dl/<token>.apk route was removed in 1.4.56 (approved
    // blocker fix) and is deliberately NOT reinstated by this merge: a hardcoded
    // token serving a file out of /tmp. The generic /download/android route below
    // is the supported path — it reads RelayPool._distDir('android') and 404s
    // cleanly until the release builder populates it.

    // ── GET /download/windows — serve Windows installer ───────────────────
    if (url === '/download/windows' || url === '/download') {
      const installerPath = path.join(RelayPool._distDir('windows'),
        `SOV-Node-Setup-${require('../../package.json').version}.exe`);
      if (fs.existsSync(installerPath)) {
        res.writeHead(200, {
          'Content-Type':        'application/octet-stream',
          'Content-Disposition': `attachment; filename="SOV-Node-Setup.exe"`,
          'Content-Length':      fs.statSync(installerPath).size,
        });
        fs.createReadStream(installerPath).pipe(res);
      } else {
        res.writeHead(404);
        res.end('Installer not available on this node');
      }
      return;
    }

    // ── GET /download/linux — serve Linux snap ─────────────────────────────
    if (url === '/download/linux') {
      const snapPath = path.join(RelayPool._distDir('linux'), 'sov-node.snap');
      if (fs.existsSync(snapPath)) {
        res.writeHead(200, {
          'Content-Type':        'application/octet-stream',
          'Content-Disposition': 'attachment; filename="sov-node.snap"',
          'Content-Length':      fs.statSync(snapPath).size,
        });
        fs.createReadStream(snapPath).pipe(res);
      } else {
        res.writeHead(404);
        res.end('Snap not available on this node');
      }
      return;
    }

    // ── GET /download/android — serve the citizen APK (mobile last-resort) ──
    // Pure local-file serve, exactly like windows/linux above: NO IP, no host.
    // A node holds the built APK in dist/android/ and serves it; the newcomer
    // reached this node via the public DHT, so no download source can be blocked.
    if (url === '/download/android' || url === '/download/apk') {
      const apkPath = path.join(RelayPool._distDir('android'), 'SovNode.apk');
      if (fs.existsSync(apkPath)) {
        res.writeHead(200, {
          'Content-Type':        'application/vnd.android.package-archive',
          'Content-Disposition': 'attachment; filename="SovNode.apk"',
          'Content-Length':      fs.statSync(apkPath).size,
        });
        fs.createReadStream(apkPath).pipe(res);
      } else {
        res.writeHead(404);
        res.end('APK not available on this node');
      }
      return;
    }

    // ── GET /download/linux.sha256 — checksum for snap ─────────────────────
    if (url === '/download/linux.sha256') {
      const checksumPath = path.join(RelayPool._distDir('linux'), 'sov-node.snap.sha256');
      if (fs.existsSync(checksumPath)) {
        res.writeHead(200, { 'Content-Type': 'text/plain' });
        res.end(fs.readFileSync(checksumPath));
      } else {
        res.writeHead(404); res.end('');
      }
      return;
    }

    // ── GET /downloads, GET /download/<file> — this node serves the release set ──
    //
    // WHY: distribution had three legs and two were weaker than they looked. GitHub works but
    // is the one thing that can actually be taken down. The IPFS leg ran through a RENTED
    // gateway metered at 10 GB a month — 63 Android downloads — and went over its limit before
    // launch had even started. The BitTorrent leg seeds from nodes whose peer port is closed
    // inbound by the cloud firewall, so only peers they dialled out to were ever served.
    //
    // Port 80 is open on every node and already answering. So the network serves its own
    // software from $SNAP_COMMON/dist, which is writable and survives a snap upgrade. The fixed
    // routes above keep their old filenames; this serves whatever the release machinery really
    // published, macOS included.
    if (url === '/downloads') {
      const files = [];
      try {
        const dir = RelayPool._releaseDir();
        for (const n of fs.readdirSync(dir)) {
          const st = fs.statSync(path.join(dir, n));
          if (st.isFile()) files.push({ name: n, size_bytes: st.size, url: `/download/${n}` });
        }
      } catch (_) { /* no dist dir yet — an empty list is the honest answer, not a 500 */ }
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ count: files.length, files }));
      return;
    }

    if (url.startsWith('/download/')) {
      // A bare filename only. The name is pattern-checked AND the resolved path is re-checked
      // against the release directory afterwards: a name check on its own has been bypassed in
      // too many servers to be trusted alone, and this one serves files to the public.
      const name = decodeURIComponent(url.slice(10)).trim();
      const dir  = RelayPool._releaseDir();
      const file = path.resolve(dir, name);
      if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/.test(name) || name.includes('..') ||
          !file.startsWith(path.resolve(dir) + path.sep)) {
        res.writeHead(400); res.end('bad request'); return;
      }
      let st = null;
      try { st = fs.statSync(file); } catch (_) {}
      if (!st || !st.isFile()) { res.writeHead(404); res.end('not on this node'); return; }
      res.writeHead(200, {
        'Content-Type':        'application/octet-stream',
        'Content-Disposition': `attachment; filename="${name}"`,
        'Content-Length':      st.size,
      });
      fs.createReadStream(file).pipe(res);
      return;
    }

    // ── GET /ipfs/<cid> — content-addressed, served by THIS node ──────────────
    //
    // The replacement for the rented gateway. THE CIDs DO NOT CHANGE: kubo's defaults
    // (cidv1 + raw-leaves + 256 KiB chunks) reproduce them exactly, measured against a
    // published artefact before this was written. So every CID already in the signed manifest,
    // in get.html and in docs/releases/*.json keeps resolving — only the provider changes.
    //
    // This proxies to a LOOPBACK gateway and nothing else: the address is hardcoded to
    // 127.0.0.1, there is no DNS lookup and no redirect is followed. It is the node reading a
    // local process, not the node calling a third party. With no local daemon it answers 503
    // and the client falls back to the other mirrors in the manifest.
    if (/^\/ipfs\/[A-Za-z0-9]{46,120}$/.test(url)) {
      const headers = {};
      if (req.headers && req.headers.range) headers.Range = req.headers.range;
      const upstream = http.request(
        { host: '127.0.0.1', port: 8081, path: url, method: 'GET', headers },
        (up) => {
          const out = { 'Content-Type': up.headers['content-type'] || 'application/octet-stream',
                        'Accept-Ranges': up.headers['accept-ranges'] || 'bytes' };
          if (up.headers['content-length']) out['Content-Length'] = up.headers['content-length'];
          if (up.headers['content-range'])  out['Content-Range']  = up.headers['content-range'];
          res.writeHead(up.statusCode || 502, out);
          up.pipe(res);
        });
      upstream.setTimeout(60000, () => upstream.destroy());
      upstream.on('error', () => {
        if (!res.headersSent) { res.writeHead(503); res.end('no local IPFS gateway on this node'); }
      });
      upstream.end();
      return;
    }

    // ── GET /sov-relay.snap — canonical snap download URL ──────────────────
    if (url === '/sov-relay.snap') {
      const distDir  = RelayPool._distDir();
      const snapPath = path.join(distDir, 'sov-relay.snap');
      const fallback = path.join(distDir, 'sov-node.snap');
      const f = fs.existsSync(snapPath) ? snapPath : (fs.existsSync(fallback) ? fallback : null);
      if (f) {
        res.writeHead(200, {
          'Content-Type':        'application/octet-stream',
          'Content-Disposition': 'attachment; filename="sov-relay.snap"',
          'Content-Length':      fs.statSync(f).size,
        });
        fs.createReadStream(f).pipe(res);
      } else { res.writeHead(404); res.end('Snap not available on this node'); }
      return;
    }

    // ── GET /sov-relay.snap.sha256 — checksum for snap ─────────────────────
    if (url === '/sov-relay.snap.sha256') {
      const cPath = path.join(RelayPool._distDir(), 'sov-relay.snap.sha256');
      if (fs.existsSync(cPath)) { res.writeHead(200, { 'Content-Type': 'text/plain' }); res.end(fs.readFileSync(cPath)); }
      else { res.writeHead(404); res.end('Checksum not available'); }
      return;
    }

    // ── GET /sov-relay.snap.sig — Ed25519 detached signature over the snap
    // SHA256. RETIRED: nothing signs this any more, no node produces the file
    // (it answers 404), and the key it was verified against has been removed
    // from the app and from this file. The route is left in place only so an
    // old client gets a clean 404 rather than a connection error. Verify a build
    // by source_root instead - /node-info, cross-checked across nodes.
    if (url === '/sov-relay.snap.sig') {
      const sPath = path.join(RelayPool._distDir('linux'), 'sov-relay.snap.sig');
      if (fs.existsSync(sPath)) { res.writeHead(200, { 'Content-Type': 'application/json' }); res.end(fs.readFileSync(sPath)); }
      else { res.writeHead(404); res.end('Signature not available'); }
      return;
    }

    // ── Root — basic node status page ──────────────────────────────────────
    if (url === '/' || url === '') {
      // Fingerprint reduction (MESSAGE_TRANSPORT_AUDIT T4): no self-identifying
      // 'SOV Node' page, node ID, version, citizen count, or download links.
      res.writeHead(200, { 'Content-Type': 'text/plain' });
      res.end('OK');
      return;
    }

    // ── POST /sov-platform/register — CITIZEN-SIGNED, SEALED-LAUNCH COMPLIANT ──
    //
    // Per SOV_Blueprint_Addendum_v14.1.docx §905: "No sudo — the relay code has
    // no special admin key, no operator override, no back-door parameter
    // setter. Every change goes through a poll. The sealed Snap makes this
    // tamper-proof after launch."
    //
    // This endpoint replaced the admin_token-gated version on 2026-05-20.
    // It now requires:
    //   1. registering_sovereign_id   — enrolled citizen claiming the platform
    //   2. x25519_pubkey_hex          — platform server's X25519 public key
    //                                   (callback_secret returned encrypted to
    //                                   this key — secret never travels in
    //                                   plaintext)
    //   3. timestamp                  — must be within ±60s of relay clock
    //   4. signature                  — Ed25519 over canonical payload, verified
    //                                   against citizen's enrolled public key
    //
    // Cost: platform_register_fee gov param worth of SOV (default 10 SOV)
    //       is deducted atomically from the citizen's disc on success and
    //       routed to the witness_operator pool (supply-neutral, per v1.2.4
    //       founder design — see the refundPool('witness_operator', feeSeeds)
    //       call below ~L1132). Citizen must have spendable balance.
    //
    // Re-registration: only allowed by the same sovereign_id that first
    // claimed the domain (used to rotate callback_secret without losing the
    // platform's history).
    if (url === '/sov-platform/register') {
      if (req.method === 'OPTIONS') {
        res.writeHead(204, { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Methods': 'POST, OPTIONS', 'Access-Control-Allow-Headers': 'Content-Type' });
        res.end(); return;
      }
      if (req.method !== 'POST') { res.writeHead(405); res.end('POST required'); return; }
      let body = '';
      req.on('data', c => body += c);
      req.on('end', async () => {
        res.setHeader('Content-Type', 'application/json');
        res.setHeader('Access-Control-Allow-Origin', '*');
        try {
          if (!db) { res.writeHead(503); res.end(JSON.stringify({ success: false, error: 'DB_UNAVAILABLE' })); return; }
          _ensureSovLoginSdkTables(db);
          const input = JSON.parse(body || '{}');
          const reg = await _doPlatformRegister(db, identity, _broadcast, input);
          res.writeHead(reg.status);
          res.end(JSON.stringify(reg.body));
          return;
        } catch (err) {
          global.sovLog.error(`SOV_PLATFORM_REGISTER_ERROR: ${err.message}`);
          res.writeHead(500); res.end(JSON.stringify({ success: false, error: 'INTERNAL_ERROR' }));
        }
      });
      return;
    }

    // [REMOVED 2026-05-20] /sov-login/initiate — legacy portal kickoff.
    // Replaced by /sov-login/initiate-app (Flow A2). Citizens never type their
    // 12-word seed phrase into a browser anymore.

    // ─────────────────────────────────────────────────────────────────────────
    // FLOW A2 — App-mediated Path A (PHISHING-PROOF). LIVE 2026-05-19.
    //
    // Replaces the deprecated "type 12 words into a browser portal" flow.
    // The citizen's seed phrase NEVER enters a browser. Instead:
    //   1. Platform calls /sov-login/initiate-app → gets pairing_code (6 digits)
    //   2. Browser displays the code: "Open SOV app, enter 482195"
    //   3. SOV app calls /sov-login/check-app with the code → learns platform_domain
    //   4. App shows "Sign in to example.com? Yes/No" — citizen confirms
    //   5. App signs Ed25519 over canonical payload, calls /sov-login/authorize-app
    //   6. Relay verifies signature + fires SOV_LINK_CREATED to platform's return_url
    //   7. Platform polls /sov-login/poll-app or waits for callback
    //
    // Phishing-proof because:
    //   - Citizen's private key lives in SOV app's secure storage; never typed in a browser
    //   - SOV app validates the relay's identity via bundled Ed25519 public keys
    //   - Pairing code is short-lived (5 min), one-use, bound to platform_domain
    // ─────────────────────────────────────────────────────────────────────────

    // ── POST /sov-login/initiate-app — platform starts an app-flow session ────
    if (url === '/sov-login/initiate-app') {
      if (req.method === 'OPTIONS') { res.writeHead(204, { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Methods': 'POST, OPTIONS', 'Access-Control-Allow-Headers': 'Content-Type' }); res.end(); return; }
      if (req.method !== 'POST') { res.writeHead(405); res.end('POST required'); return; }
      let body = '';
      req.on('data', c => body += c);
      req.on('end', () => {
        res.setHeader('Content-Type', 'application/json');
        res.setHeader('Access-Control-Allow-Origin', '*');
        try {
          if (!db) { res.writeHead(503); res.end(JSON.stringify({ success: false, error: 'DB_UNAVAILABLE' })); return; }
          _ensureSovLoginSdkTables(db);
          const { platform_id, domain, return_url } = JSON.parse(body || '{}');

          // Governance gate
          const govRow = db._db.prepare("SELECT param_value FROM sov_governance_params WHERE param_key = 'sov_login'").get();
          if (!govRow || govRow.param_value !== '1') {
            res.writeHead(200); res.end(JSON.stringify({ success: false, error: 'SOV_LOGIN_NOT_ACTIVATED' })); return;
          }

          // Resolve platform
          let platform = null;
          if (platform_id) platform = db._db.prepare('SELECT * FROM sov_platforms WHERE platform_id = ?').get(platform_id);
          if (!platform && domain) platform = db._db.prepare('SELECT * FROM sov_platforms WHERE domain = ?').get(domain.toLowerCase().replace(/^https?:\/\//, '').split('/')[0]);
          if (!platform) { res.writeHead(404); res.end(JSON.stringify({ success: false, error: 'PLATFORM_NOT_REGISTERED' })); return; }
          // ANNUAL RENEWAL GATE (king 2026-07-19): expired platform cannot start
          // logins until it renews. expires_at 0/NULL = legacy row, grandfathered.
          if (platform.active !== 1 || (platform.expires_at > 0 && platform.expires_at < Date.now())) {
            res.writeHead(403); res.end(JSON.stringify({ success: false, error: 'PLATFORM_EXPIRED', message: 'Platform registration has expired — renew via /sov-platform/register (annual fee).' })); return;
          }

          const sessionId = crypto.randomBytes(24).toString('hex');
          // A caller may restate the registered return_url, never replace it
          // (2026-10-02). Refused loudly rather than silently ignored, so an integrator
          // who sends the wrong URL finds out at once instead of wondering why the
          // callback lands elsewhere. Dispatch also reads only the registration (see
          // the SOV_LINK_CREATED callback), so a session replicated from a peer cannot
          // carry its own URL either.
          if (return_url && return_url !== platform.return_url) {
            res.writeHead(400);
            res.end(JSON.stringify({ success: false, error: 'RETURN_URL_MISMATCH',
              message: 'return_url must match the URL this platform registered; re-register to change it.' }));
            return;
          }
          const callbackUrl = platform.return_url;
          const now = Date.now();
          const expiresAt = now + 300 * 1000; // 5-minute pairing window

          // 6-digit numeric pairing code, leading zeros preserved.
          // Uses crypto.randomBytes for CSPRNG (not Math.random).
          let pairingCode;
          for (let attempts = 0; attempts < 8; attempts++) {
            // Mod 1_000_000 has slight bias on a 32-bit value (max 4_294_967_295) of ~0.023%.
            // Acceptable for short-lived pairing codes; rejection-sampling would be overkill.
            const n = crypto.randomBytes(4).readUInt32BE(0) % 1_000_000;
            pairingCode = String(n).padStart(6, '0');
            // Ensure uniqueness against any other active pairing
            const existing = db._db.prepare('SELECT pairing_code FROM sov_app_pairings WHERE pairing_code = ? AND expires_at > ?').get(pairingCode, now);
            if (!existing) break;
          }

          db._db.prepare('INSERT INTO sov_auth_sessions (session_id, platform_id, return_url, status, created_at, expires_at, flow_type) VALUES (?,?,?,?,?,?,?)')
            .run(sessionId, platform.platform_id, callbackUrl, 'pending', now, expiresAt, 'app');

          db._db.prepare('INSERT INTO sov_app_pairings (pairing_code, session_id, expires_at) VALUES (?,?,?)')
            .run(pairingCode, sessionId, expiresAt);

          // Mesh: replicate to peers so the citizen's SOV app can resolve the
          // pairing code on ANY node, not only the one the platform called.
          _broadcast('PAIRING_BROADCAST', {
            pairing_code: pairingCode,
            session_id:   sessionId,
            expires_at:   expiresAt,
            session: {
              session_id:  sessionId,
              platform_id: platform.platform_id,
              return_url:  callbackUrl,
              status:      'pending',
              created_at:  now,
              expires_at:  expiresAt,
              flow_type:   'app',
            },
          });

          global.sovLog.debug(`SOV_LOGIN_INITIATE_APP: session=${sessionId.slice(0,10)} platform=${platform.domain}`);
          res.writeHead(200);
          res.end(JSON.stringify({
            success: true,
            session_id: sessionId,
            pairing_code: pairingCode,
            expires_at: expiresAt,
            platform_domain: platform.domain,
          }));
        } catch (err) {
          global.sovLog.error(`SOV_LOGIN_INITIATE_APP_ERROR: ${err.message}`);
          res.writeHead(500); res.end(JSON.stringify({ success: false, error: 'INTERNAL_ERROR' }));
        }
      });
      return;
    }

    // ── POST /sov-login/check-app — SOV app fetches session details by code ───
    if (url === '/sov-login/check-app') {
      if (req.method === 'OPTIONS') { res.writeHead(204, { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Methods': 'POST, OPTIONS', 'Access-Control-Allow-Headers': 'Content-Type' }); res.end(); return; }
      if (req.method !== 'POST') { res.writeHead(405); res.end('POST required'); return; }
      let body = '';
      req.on('data', c => body += c);
      req.on('end', () => {
        res.setHeader('Content-Type', 'application/json');
        res.setHeader('Access-Control-Allow-Origin', '*');
        try {
          if (!db) { res.writeHead(503); res.end(JSON.stringify({ success: false, error: 'DB_UNAVAILABLE' })); return; }
          _ensureSovLoginSdkTables(db);
          const { pairing_code } = JSON.parse(body || '{}');
          if (!pairing_code || !/^\d{6}$/.test(pairing_code)) {
            res.writeHead(400); res.end(JSON.stringify({ success: false, error: 'INVALID_PAIRING_CODE_FORMAT' })); return;
          }
          const now = Date.now();
          const pair = db._db.prepare('SELECT * FROM sov_app_pairings WHERE pairing_code = ?').get(pairing_code);
          if (!pair) { res.writeHead(404); res.end(JSON.stringify({ success: false, error: 'PAIRING_CODE_NOT_FOUND' })); return; }
          if (pair.used_at > 0) { res.writeHead(403); res.end(JSON.stringify({ success: false, error: 'PAIRING_CODE_ALREADY_USED' })); return; }
          if (pair.expires_at < now) { res.writeHead(410); res.end(JSON.stringify({ success: false, error: 'PAIRING_CODE_EXPIRED' })); return; }

          const session = db._db.prepare('SELECT * FROM sov_auth_sessions WHERE session_id = ?').get(pair.session_id);
          if (!session) { res.writeHead(404); res.end(JSON.stringify({ success: false, error: 'SESSION_NOT_FOUND' })); return; }
          const platform = db._db.prepare('SELECT domain, return_url FROM sov_platforms WHERE platform_id = ?').get(session.platform_id);
          // check-app is called BEFORE the citizen's app has revealed which
          // sovereign_id will authorize, so we can't yet tell if THIS citizen
          // is already linked. The Flutter app calls a separate query if it
          // needs that signal up-front (see /sov-link/check-linked below).
          res.writeHead(200);
          res.end(JSON.stringify({
            success: true,
            session_id: session.session_id,
            platform_id: session.platform_id,
            platform_domain: platform ? platform.domain : '',
            return_url: platform ? platform.return_url : '', // the registered URL, never one carried on the session
            issued_at: session.created_at,
            expires_at: pair.expires_at,
          }));
        } catch (err) {
          global.sovLog.error(`SOV_LOGIN_CHECK_APP_ERROR: ${err.message}`);
          res.writeHead(500); res.end(JSON.stringify({ success: false, error: 'INTERNAL_ERROR' }));
        }
      });
      return;
    }

    // ── POST /sov-login/authorize-app — citizen confirms in their SOV app ─────
    if (url === '/sov-login/authorize-app') {
      if (req.method === 'OPTIONS') { res.writeHead(204, { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Methods': 'POST, OPTIONS', 'Access-Control-Allow-Headers': 'Content-Type' }); res.end(); return; }
      if (req.method !== 'POST') { res.writeHead(405); res.end('POST required'); return; }
      let body = '';
      req.on('data', c => body += c);
      req.on('end', async () => {
        res.setHeader('Content-Type', 'application/json');
        res.setHeader('Access-Control-Allow-Origin', '*');
        try {
          if (!db) { res.writeHead(503); res.end(JSON.stringify({ success: false, error: 'DB_UNAVAILABLE' })); return; }
          _ensureSovLoginSdkTables(db);
          const { session_id, sovereign_id, signature, timestamp, password: rawPw, password_verifier: pvIn } = JSON.parse(body || '{}');
          if (!session_id || !sovereign_id || !signature || !timestamp) {
            res.writeHead(400); res.end(JSON.stringify({ success: false, error: 'MISSING_FIELDS' })); return;
          }
          const now = Date.now();
          if (Math.abs(now - timestamp) > 60000) {
            res.writeHead(400); res.end(JSON.stringify({ success: false, error: 'STALE_TIMESTAMP' })); return;
          }
          // Optional password: citizen-supplied plain password (sent only to the
          // citizen's bundled trust-anchor relay over the same HTTP channel as
          // the Ed25519-signed authorization). Relay computes scrypt verifier
          // here so Flutter doesn't need a scrypt package. Plain password is
          // held in memory for this one RPC and discarded.
          // 1.4.93 (D2): a site password NEVER travels. The app makes the bcrypt verifier on the device
          // and signs it (sov-link-v2-app); a plain password is refused, so it can be neither read nor
          // swapped on the way. `rawPwClean` now holds the client's VERIFIER, never a password.
          if (typeof rawPw === 'string' && rawPw.length > 0) {
            res.writeHead(400); res.end(JSON.stringify({ success: false, error: 'PASSWORD_PLAINTEXT_REFUSED' })); return;
          }
          let rawPwClean = '';
          if (typeof pvIn === 'string' && pvIn.length > 0) {
            if (!/^\$2[aby]\$1[2-4]\$[./A-Za-z0-9]{53}$/.test(pvIn)) {
              res.writeHead(400); res.end(JSON.stringify({ success: false, error: 'INVALID_PASSWORD_VERIFIER' })); return;
            }
            rawPwClean = pvIn;
          }

          const session = db._db.prepare('SELECT * FROM sov_auth_sessions WHERE session_id = ? AND status = ? AND flow_type = ?').get(session_id, 'pending', 'app');
          if (!session) { res.writeHead(404); res.end(JSON.stringify({ success: false, error: 'SESSION_NOT_FOUND_OR_NOT_PENDING' })); return; }
          if (session.expires_at < now) { res.writeHead(410); res.end(JSON.stringify({ success: false, error: 'SESSION_EXPIRED' })); return; }

          const platform = db._db.prepare('SELECT * FROM sov_platforms WHERE platform_id = ?').get(session.platform_id);
          if (!platform) { res.writeHead(404); res.end(JSON.stringify({ success: false, error: 'PLATFORM_NOT_REGISTERED' })); return; }
          // ANNUAL RENEWAL GATE (king 2026-07-19): expired platform cannot start
          // logins until it renews. expires_at 0/NULL = legacy row, grandfathered.
          if (platform.active !== 1 || (platform.expires_at > 0 && platform.expires_at < Date.now())) {
            res.writeHead(403); res.end(JSON.stringify({ success: false, error: 'PLATFORM_EXPIRED', message: 'Platform registration has expired — renew via /sov-platform/register (annual fee).' })); return;
          }

          // Resolve citizen's enrolled public key from sov_enrollments
          // (sov_disc only stores balances/version, not public keys)
          const enrPub = db._db.prepare('SELECT public_key_hex FROM sov_enrollments WHERE sovereign_id = ?').get(sovereign_id);
          if (!enrPub || !enrPub.public_key_hex) {
            res.writeHead(403); res.end(JSON.stringify({ success: false, error: 'NOT_ENROLLED' })); return;
          }

          // Verify Ed25519 signature over canonical payload
          const canonical = rawPwClean
            ? `sov-link-v2-app:${session_id}:${sovereign_id}:${platform.domain}:${timestamp}:${crypto.createHash('sha256').update(rawPwClean).digest('hex')}`
            : `sov-link-v1-app:${session_id}:${sovereign_id}:${platform.domain}:${timestamp}`;
          let sigValid = false;
          try {
            const pubKeyBytes = Buffer.from(enrPub.public_key_hex, 'hex');
            const sigBytes    = Buffer.from(signature, 'hex');
            const payloadBuf  = Buffer.from(canonical, 'utf-8');
            sigValid = require('../security/node_identity').NodeIdentity.verify(payloadBuf, sigBytes, pubKeyBytes);
          } catch (e) {
            sigValid = false;
          }
          if (!sigValid) {
            res.writeHead(403); res.end(JSON.stringify({ success: false, error: 'INVALID_SIGNATURE' })); return;
          }

          // ─────────────────────────────────────────────────────────────────
          // SEALED-FIRST-VERIFICATION (added 2026-05-20)
          //
          // The very first time a citizen links to a platform, we accept the
          // password and store the scrypt verifier. From then on, the link
          // is "sealed" — re-running Flow A2 must NEVER silently overwrite
          // the verifier (that would let a phisher who tricks the citizen
          // into a second Flow A2 reset their platform password without
          // their knowledge).
          //
          // Three branches:
          //   1. No existing link            → first-time link, accept password
          //   2. Existing link, no password  → idempotent re-confirm, reuse verifier
          //   3. Existing link + new password → REJECT (use explicit reset flow)
          //
          // sov_link/reset-password (future) is the only path that overwrites
          // an existing verifier.
          // ─────────────────────────────────────────────────────────────────
          const existingLink = db._db.prepare(
            'SELECT password_verifier, binding_sig, network_sig, issued_at ' +
            'FROM sov_citizen_links WHERE sovereign_id = ? AND platform_id = ?'
          ).get(sovereign_id, session.platform_id);
          if (existingLink && rawPwClean.length > 0) {
            // Branch 3 — refuse to overwrite a sealed link
            res.writeHead(409); res.end(JSON.stringify({
              success: false,
              error: 'ALREADY_LINKED',
              message: 'This account is already linked to ' + platform.domain +
                       '. To change the password, use Reset Password from the ' +
                       'My Platform Connections screen.',
              issued_at: existingLink.issued_at,
            }));
            return;
          }

          // Mark session verified + look up palm name
          const enrRow = db._db.prepare('SELECT palm_name FROM sov_enrollments WHERE sovereign_id = ?').get(sovereign_id);
          const palmName = (enrRow && enrRow.palm_name) ? enrRow.palm_name : '';
          db._db.prepare("UPDATE sov_auth_sessions SET status = 'verified', sovereign_id = ?, palm_name = ? WHERE session_id = ?")
            .run(sovereign_id, palmName, session_id);
          db._db.prepare('UPDATE sov_app_pairings SET used_at = ? WHERE session_id = ?').run(now, session_id);

          // Mesh: replicate the verified state so any node can serve /poll-app
          _broadcast('PAIRING_STATE_BROADCAST', {
            session_id, used_at: now, status: 'verified',
            sovereign_id, palm_name: palmName,
          });

          // Compute binding artefacts. Three branches per sealed-link policy:
          //  • First link  (existingLink == null)         → compute fresh, INSERT
          //  • Re-confirm  (existingLink && rawPwClean=='') → REUSE existing values
          //                                                    (idempotent — callback
          //                                                     fires with the SAME
          //                                                     verifier, no DB write)
          //  • New password on existing link              → already rejected above
          //                                                  (ALREADY_LINKED 409)
          const platformId = platform.platform_id;
          const platformDomain = platform.domain;
          const isFirstLink = !existingLink;
          let passwordVerifier;
          let bindingSig;
          let networkSig;
          let issuedAt;
          let linkId;
          if (isFirstLink) {
            passwordVerifier = rawPwClean;   // D2: already a bcrypt verifier, made and signed on the device
            const bindingData = `${sovereign_id}|${platformDomain}|${passwordVerifier}`;
            const bindingHash = crypto.createHash('sha256').update(bindingData).digest();
            bindingSig = identity ? identity.sign(bindingHash).toString('hex') : '';
            issuedAt   = now;
            linkId     = crypto.createHash('sha256')
              .update(`${sovereign_id}|${platformDomain}`)
              .digest('hex').substring(0, 32);
            const networkPayload = JSON.stringify({
              link_id: linkId, sovereign_id, platform_domain: platformDomain,
              password_verifier: passwordVerifier, issued_at: issuedAt,
            });
            networkSig = identity ? identity.sign(
              crypto.createHash('sha256').update(networkPayload).digest()
            ).toString('hex') : '';

            // Persist the new link. INSERT only — we have already checked
            // above that no existing link is being overwritten.
            db._db.prepare(`INSERT INTO sov_citizen_links
              (link_id, sovereign_id, platform_id, platform_domain, password_verifier, binding_sig, network_sig, issued_at)
              VALUES (?,?,?,?,?,?,?,?)`)
              .run(linkId, sovereign_id, platformId, platformDomain,
                   passwordVerifier, bindingSig, networkSig, issuedAt);

            // Mesh: replicate to peers
            _broadcast('CITIZEN_LINK_BROADCAST', {
              link_id: linkId, sovereign_id, platform_id: platformId,
              platform_domain: platformDomain, password_verifier: passwordVerifier,
              binding_sig: bindingSig, network_sig: networkSig, issued_at: issuedAt,
            });
          } else {
            // Re-confirm — reuse the sealed values verbatim
            passwordVerifier = existingLink.password_verifier;
            bindingSig       = existingLink.binding_sig;
            networkSig       = existingLink.network_sig;
            issuedAt         = existingLink.issued_at;
            linkId           = crypto.createHash('sha256')
              .update(`${sovereign_id}|${platformDomain}`)
              .digest('hex').substring(0, 32);
            global.sovLog.debug(
              `SOV_LOGIN_AUTHORIZE_APP: re-confirm (sealed) ` +
              `sovereign=${sovereign_id} platform=${platformDomain}`
            );
          }

          // Build relay pool block for callback.
          // [2026-08-14] Was buildPoolResponse(); now bootstrapNodes(db), the
          // third and last site of the same defect (see the two SDK plugin
          // routes). Two things were wrong here, not one:
          //   1. buildPoolResponse admits any peer merely SEEN inside STALE_MS,
          //      including one refused at HELLO — and this block does not just
          //      list those hosts, it OVERWRITES the bootstrapNodes-derived
          //      verify_endpoints computed on the line above it.
          //   2. It read `poolJson.nodes`, but buildPoolResponse returns
          //      { payload: { nodes }, sig, signer } — so `nodes` was ALWAYS
          //      undefined and poolNodes ALWAYS []. The overwrite therefore
          //      replaced good verify_endpoints with an EMPTY array, and every
          //      SOV_LINK_CREATED callback shipped a platform an empty pool.
          //      The wrong-source bug was masked by the wrong-shape bug.
          const cbHosts = (() => {
            try { return advertisedNodes(db); } catch (_) { return []; }
          })();
          const sovlinkPool = {
            version: 11,
            nodes: cbHosts.map((h, i) => poolEntryFor(db, relayPool, h, i,
              process.env.RELAY_IP || (network && network.publicAddress ? network.publicAddress.split(':')[0] : ''))),
            verify_endpoints: cbHosts.map((h) => `http://${h}/sov-link/verify-password`),
            pool_refresh_url: `http://${process.env.RELAY_IP || (network && network.publicAddress ? network.publicAddress.split(':')[0] : '127.0.0.1')}/relay-pool/latest`,
          };

          // Fire SOV_LINK_CREATED callback to platform's return_url
          // ONLY the URL the platform registered (2026-10-02). This used to be
          // session.return_url, which initiate-app took from its caller unchecked and
          // which also arrives from peers inside PAIRING_BROADCAST - so whoever started
          // a login could choose where this payload went, while the citizen's app
          // showed the genuine platform's domain. The payload carries the citizen's
          // password_verifier. The registration is the only source the platform
          // proved, with a citizen's signature and a fee, so it is the only one used.
          const callbackUrl = platform.return_url;
          const cbPayload = JSON.stringify({
            event: 'SOV_LINK_CREATED',
            flow: 'app',
            is_first_link: isFirstLink,     // platform can branch UX
            sovereign_id,
            palm_name: palmName,
            citizen_public_key: enrPub.public_key_hex,
            platform_id: platformId,
            platform_domain: platformDomain,
            password_verifier: passwordVerifier,
            // King's corrected model: SOV Link is a ONE-TIME bootstrap. Verify EVERY
            // later login LOCALLY with password_verify($entered, password_verifier) —
            // never call SOV per login (verify_endpoints are an optional cross-check).
            login_model: 'local-password',
            verifier_scheme: { kdf: 'bcrypt', cost: 12, format: 'modular-crypt',
              verify: 'password_verify($entered, password_verifier)' },
            binding_sig: bindingSig,
            network_sig: networkSig,
            relay_pool: sovlinkPool,
            issued_at: issuedAt,
          });
          // Callback HMAC — interim authenticator until plugin v2.1 enforces
          // full Ed25519 network_sig verification. Both layers are belt+braces.
          // Plugin stores RELAY_CALLBACK_SECRET at /sov-platform/register time;
          // HMAC-SHA256 over the raw JSON body is included as a header.
          // A missing X-Sov-Callback-Hmac must be a FAILURE, never a skip —
          // the same rule this network publishes to integrators in
          // SOV_LOGIN_INTEGRATION_GUIDE §3.6. It binds the sender first: the
          // sender is what produces the missing header. Previously the HMAC was
          // computed `if (secret)` and attached `if (callbackHmac)`, so a blank
          // callback_secret silently downgraded the callback to unauthenticated
          // instead of refusing it. That is not a safe default — the shipped
          // sov-plugin.php never reads this header and skips its only check when
          // a field is absent, so "absent" arrives as "accepted" with an
          // attacker-choosable sovereign_id. `catch` leaves callbackHmac '' and
          // is therefore also a refusal, not a downgrade.
          let callbackHmac = '';
          try {
            const platRow = db._db.prepare(
              'SELECT callback_secret FROM sov_platforms WHERE platform_id = ?'
            ).get(platformId);
            const secret = (platRow && platRow.callback_secret) ? platRow.callback_secret : '';
            if (secret) {
              callbackHmac = crypto.createHmac('sha256', secret).update(cbPayload).digest('hex');
            }
          } catch (e) {
            global.sovLog.warn(`SOV_LINK_CALLBACK_SECRET_LOOKUP_ERROR: platform=${platformDomain} error=${e.message}`);
          }

          let callbackSuccess = false;
          if (callbackUrl && !callbackHmac) {
            // Loud, and deliberately carries no retrieval URL: a warn line is
            // what an operator pastes into a ticket. Name the remedy instead.
            global.sovLog.warn(
              `SOV_LINK_CALLBACK_UNSIGNED_REFUSED: platform=${platformDomain} ` +
              `platform_id=${String(platformId).slice(0, 12)} — this node holds no callback_secret ` +
              `for this platform, so the callback would carry no X-Sov-Callback-Hmac. NOT SENT. ` +
              `The citizen link IS stored; the platform was not notified. Remedy: the platform owner ` +
              `re-registers via /sov-platform/register to seal a fresh callback_secret, then the ` +
              `citizen re-links (the re-confirm branch re-sends a byte-identical callback).`
            );
          } else if (callbackUrl) {
            try {
              const cbUrl = new URL(callbackUrl);
              const lib = cbUrl.protocol === 'https:' ? require('https') : require('http');
              const cbHeaders = {
                'Content-Type':   'application/json',
                'Content-Length': Buffer.byteLength(cbPayload),
              };
              // Unconditional: the branch above already refused the empty case.
              // Left as a bare assignment on purpose — an `if` here would be a
              // second, silent place for the header to go missing.
              cbHeaders['X-Sov-Callback-Hmac'] = callbackHmac;
              const cbReq = lib.request({
                method: 'POST',
                hostname: cbUrl.hostname,
                port: cbUrl.port || (cbUrl.protocol === 'https:' ? 443 : 80),
                path: cbUrl.pathname + cbUrl.search,
                headers: cbHeaders,
                timeout: 8000,
              }, (cbRes) => {
                callbackSuccess = cbRes.statusCode >= 200 && cbRes.statusCode < 300;
                let cbBody = ''; cbRes.on('data', d => cbBody += d); cbRes.on('end', () => {
                  if (callbackSuccess) {
                    global.sovLog.info(`SOV_LINK_CALLBACK_RESULT: platform=${platformDomain} http_status=${cbRes.statusCode} success=true`);
                    return;
                  }
                  // WHO answered? A status code alone cannot tell us. Measured on a
                  // live platform 2026-08-14: the SAME POST to the SAME return_url
                  // returned 403, 503 and 508 within ten minutes — all of them from
                  // the shared host's edge (LiteSpeed / a branded "Resource Limit
                  // Reached" page), none of them from the platform's handler, which
                  // had never run. 503 is also the code the platform's own
                  // fail-closed branch returns. Same number, opposite meaning.
                  // The discriminator is the content type, and it is free: a
                  // platform handler answers application/json, an edge answers
                  // text/html. Do not read a hint below as the platform's until the
                  // body is JSON.
                  // A REFUSED callback used to be logged at debug level only, and
                  // LOG_LEVEL defaults to 'info' (index.js) — so on a normally
                  // configured node a refused link looked exactly like an accepted
                  // one, while the line below still said "callback=fired". The
                  // platform's own status code carries information the operator
                  // needs and must not have to read the platform's logs to get:
                  //   401 — the platform CAN check and rejected our HMAC. The
                  //         callback_secret this node holds for that platform is
                  //         wrong, blank, or was blanked by a peer broadcast.
                  //   503 — the platform CANNOT check anyone right now (its own
                  //         secret is missing). Do NOT rotate and do NOT
                  //         re-register: a fresh secret would be handed to a host
                  //         that cannot store it. Wait for the platform operator.
                  // The JSON ladder below is the RECEIVER's own ordering, supplied
                  // by the platform implementer 2026-08-14 with line citations into
                  // api/auth/sov-link-callback.php: Content-Type: application/json is
                  // set at :27, BEFORE every refusal branch in that file (405 :31,
                  // fail-closed 503 :57, 401 :78, 400s :130/:136, 403 :141, 500s
                  // :230/:326). So the content-type test is not a heuristic on that
                  // platform, it is total: JSON means the handler ran and chose to
                  // refuse; HTML means it never ran.
                  //
                  // The branch that was missing is the CHEAPEST one to act on wrongly.
                  // Their HMAC check sits at :62-80, ahead of every payload check, so
                  // a 400 or 403 is PROOF the callback authenticated — the secret this
                  // node holds is correct. Logged with no hint, a 4xx reads to an
                  // operator as "auth problem" and points them at the one write we
                  // most want them not to make. A refusal that exonerates the secret
                  // should say so, in the same line, or the exoneration is not
                  // operator-visible at all.
                  const cbType = String(cbRes.headers['content-type'] || '').toLowerCase();
                  const fromHandler = cbType.indexOf('json') !== -1;
                  const st = cbRes.statusCode;
                  const hint = !fromHandler
                    ? ` — answered ${cbType || 'no content-type'}, not JSON: this did NOT come from the platform's callback handler, it came from its host/edge (proxy, WAF, or a resource limiter). The platform's code never ran. Nothing on this node is misconfigured — do NOT rotate, re-register, or change the callback_secret. This is the platform's hosting to fix.`
                    : st === 401
                      // NOT the blank-row case. The branch ~90 lines above refuses to
                      // send an unsigned callback at all, so if this request went out
                      // it carried X-Sov-Callback-Hmac. A receiver that distinguishes
                      // absent-header from wrong-header (theirs does, :62-64) is
                      // therefore answering "wrong", never "missing" — this is a key
                      // disagreement between two held secrets, not an empty one here.
                      ? ' — platform ran its HMAC check and rejected our signature. The header WAS sent (an unsigned callback is refused before dispatch), so this is a key disagreement: this node and the platform hold different callback_secrets. Re-registration by the platform owner reseals both sides; rotating blind does not.'
                      : st === 503
                        ? ' — platform cannot verify ANY callback right now (its own secret is missing or blank). This is receiver-side, NOT this node\'s secret. Do NOT rotate or re-register; a fresh secret would be handed to a host that cannot store it. Wait for the platform operator.'
                        : (st === 400 || st === 403)
                          ? ' — the platform\'s HMAC check ALREADY PASSED (its auth gate runs ahead of every payload check); this refusal is about the payload shape or the platform_domain, not about authentication. The callback_secret this node holds is CORRECT — do NOT rotate or re-register it. Fix the callback payload, not the key.'
                          : (st >= 500)
                            ? ' — the platform accepted and authenticated the callback, then failed to store it (its DB or token write). The link is valid on both sides of the wire; this is the one refusal worth retrying, and it needs no key change.'
                            : '';
                  // RECOVERY ADVICE — deliberately does NOT print a retrieval URL.
                  // An earlier draft of this line pasted
                  //   GET /sov-link/<sha256(sovereign_id)[0:32]>/<platform_id>
                  // into the operator log. That route answers with the FULL binding
                  // (password_verifier, binding_sig, network_sig) to an unauthenticated
                  // caller — see the gate on that handler below. A warn-level log line
                  // is copied into tickets, chat and pastebins; emitting a ready-made
                  // disclosure URL there hands the binding to everyone who reads the
                  // incident, and the operator has no reason to suspect it. The safe
                  // recovery needs no URL at all: the re-confirm branch above reuses
                  // the sealed values VERBATIM, so the citizen simply linking again
                  // re-fires a byte-identical callback.
                  global.sovLog.warn(
                    `SOV_LINK_CALLBACK_REFUSED: platform=${platformDomain} http_status=${cbRes.statusCode}` +
                    ` content_type=${cbType || 'none'} body_bytes=${Buffer.byteLength(cbBody)}${hint}` +
                    ` The link row IS stored and replicated — no data was lost. Recovery: the citizen` +
                    ` links again once the platform can receive; the existing link is re-confirmed and an` +
                    ` IDENTICAL callback is re-sent (sealed values are reused verbatim, never regenerated).` +
                    ` Do NOT hand out the .sovlink retrieval route as a workaround — it is unauthenticated.` +
                    ` (GET /sov-login/poll-app returns status only and will NOT carry the binding.)`
                  );
                });
              });
              cbReq.on('error', (e) => {
                callbackSuccess = false;
                global.sovLog.warn(`SOV_LINK_CALLBACK_ERROR: platform=${platformDomain} error=${e.message}`);
              });
              // destroy() alone emits 'close', not always 'error' — an 8s timeout
              // could otherwise pass with no log line at any level.
              cbReq.on('timeout', () => {
                callbackSuccess = false;
                global.sovLog.warn(`SOV_LINK_CALLBACK_TIMEOUT: platform=${platformDomain} after 8000ms — link row stored, callback not confirmed`);
                cbReq.destroy();
              });
              cbReq.write(cbPayload); cbReq.end();
            } catch (_) {}
          }

          // 'dispatched', not 'fired': this line runs SYNCHRONOUSLY, before the
          // platform has answered. The outcome arrives later as
          // SOV_LINK_CALLBACK_RESULT / _REFUSED / _ERROR / _TIMEOUT above. Saying
          // 'fired' here was the whole reason a 401 or 503 left no trace.
          global.sovLog.info(`SOV_LOGIN_AUTHORIZE_APP: sovereign=${sovereign_id} platform=${platformDomain} sig_valid=true callback=${callbackUrl ? 'dispatched (outcome logged separately)' : 'none'}`);
          res.writeHead(200);
          res.end(JSON.stringify({ success: true, status: 'authorized', sovereign_id, palm_name: palmName, platform_domain: platformDomain }));
        } catch (err) {
          global.sovLog.error(`SOV_LOGIN_AUTHORIZE_APP_ERROR: ${err.message}`);
          res.writeHead(500); res.end(JSON.stringify({ success: false, error: 'INTERNAL_ERROR' }));
        }
      });
      return;
    }

    // ── GET /sov-login/poll-app?session_id=X — platform polls for completion ──
    // Note: `url` at this scope was already stripped of query string at line 537
    // (`req.url.split('?')[0]`). Use req.url directly to access the raw path+query.
    if (url === '/sov-login/poll-app') {
      if (req.method !== 'GET') { res.writeHead(405); res.end('GET required'); return; }
      res.setHeader('Content-Type', 'application/json');
      res.setHeader('Access-Control-Allow-Origin', '*');
      try {
        if (!db) { res.writeHead(503); res.end(JSON.stringify({ success: false, error: 'DB_UNAVAILABLE' })); return; }
        _ensureSovLoginSdkTables(db);
        const u = new URL(req.url, 'http://localhost');
        const sessionId = u.searchParams.get('session_id') || '';
        if (!sessionId) { res.writeHead(400); res.end(JSON.stringify({ success: false, error: 'MISSING_SESSION_ID' })); return; }
        const session = db._db.prepare('SELECT status, sovereign_id, palm_name, expires_at FROM sov_auth_sessions WHERE session_id = ?').get(sessionId);
        if (!session) { res.writeHead(404); res.end(JSON.stringify({ success: false, error: 'SESSION_NOT_FOUND' })); return; }
        const now = Date.now();
        let status = session.status;
        if (status === 'pending' && session.expires_at < now) status = 'expired';
        res.writeHead(200);
        res.end(JSON.stringify({
          success: true,
          status,
          sovereign_id: status === 'verified' ? session.sovereign_id : undefined,
          palm_name: status === 'verified' ? session.palm_name : undefined,
        }));
      } catch (err) {
        global.sovLog.error(`SOV_LOGIN_POLL_APP_ERROR: ${err.message}`);
        res.writeHead(500); res.end(JSON.stringify({ success: false, error: 'INTERNAL_ERROR' }));
      }
      return;
    }

    // [REMOVED 2026-05-20] SOV Auth Portal /auth/:token GET/verify/create-password.
    // The seed-phrase entry webpage was the only phishing surface in SOV Login.
    // Replaced by Flow A2 (/sov-login/initiate-app + check-app + authorize-app).

    // ── GET /sov-status/:sovereignId — enrollment status check ────────────────
    if (req.method === 'GET' && /^\/sov-status\/SOV-[0-9A-F]{16}$/.test(url)) {
      res.setHeader('Content-Type', 'application/json');
      res.setHeader('Access-Control-Allow-Origin', '*');
      try {
        if (!db) { res.writeHead(503); res.end(JSON.stringify({ enrolled: false, error: 'DB_UNAVAILABLE' })); return; }
        const sovId = url.slice(12); // strip /sov-status/
        // [GHOST-COUNT 2026-08-14] `enrolled` must come from sov_enrollments, NOT
        // sov_disc. The blueprint contract for this endpoint is "is this citizen
        // still enrolled on the SOV network — not revoked, not banned"
        // (CLAUDE_REFERENCE.md:1831). sov_disc is a WALLET-SLOT table: it gains a
        // 0-balance row for any sovereign_id that merely opens one signed session
        // (touchLiveness → ensureDiscEntry, db.js:1018), and for any transfer
        // RECIPIENT (transfer_engine.js:312/:677). Reading it here turned a wallet
        // slot into an identity assertion: a key that never enrolled answered
        // `enrolled: true` to every platform calling the shipped SDK's getStatus()
        // (the PHP template below at ~:2314). Proven on the genesis chain
        // 2026-08-14: sov_disc COUNT(*)=4 vs citizenCount()=1, so 3 unenrolled ids
        // were being reported as enrolled citizens.
        // Safe against a cross-node false negative: sov_enrollments replicates
        // mesh-wide, full-table, alongside the disc delta (V40 anti-entropy —
        // citizen_gateway.js:430 sends, :545 applies INSERT OR IGNORE), and
        // enrollNewCitizen writes the enrolment + disc rows in ONE transaction
        // (db.js:1050), so enrolment ⊆ disc always. This strictly removes false
        // positives; it can never deny a real citizen.
        const enr   = db._db.prepare('SELECT palm_name FROM sov_enrollments WHERE sovereign_id = ?').get(sovId);
        res.writeHead(200); res.end(JSON.stringify({
          enrolled:  !!enr,
          palm_name: (enr && enr.palm_name) ? enr.palm_name : '',
          node_id:   identity.nodeId.slice(0, 16),
        }));
      } catch (err) {
        res.writeHead(500); res.end(JSON.stringify({ enrolled: false, error: 'INTERNAL_ERROR' }));
      }
      return;
    }

    // ── GET /sov-link/:sovIdHash/:platformIdHash — retrieve .sovlink ───────────
    if (req.method === 'GET' && /^\/sov-link\/[a-f0-9]{32}\/[a-f0-9]{32}$/.test(url)) {
      res.setHeader('Content-Type', 'application/json');
      // NO wildcard CORS on this route. It used to send Access-Control-Allow-Origin:*
      // beside a body containing password_verifier, which let ANY page the citizen
      // visits read their binding from the browser. The only legitimate caller is the
      // platform's own backend, which needs no CORS at all.
      try {
        if (!db) { res.writeHead(503); res.end(JSON.stringify({ success: false, error: 'DB_UNAVAILABLE' })); return; }
        _ensureSovLoginSdkTables(db);
        const [, sovHash, platHash] = url.match(/^\/sov-link\/([a-f0-9]{32})\/([a-f0-9]{32})$/) || [];

        // ── AUTHENTICATE. This handler returns password_verifier, binding_sig and
        // network_sig, and until now asked for NOTHING. Fifty lines below,
        // /sov-link/verify-password had three separate channels closed on
        // 2026-08-01 specifically so that nobody could ask "does this SOV ID hold
        // an account on this platform?" without a credential. This route answered
        // that same question outright — and then handed over the binding — from a
        // plain GET. The oracle fix closed the loud door and left the quiet one
        // open in the same file.
        //
        // network_sig/binding_sig carry no nonce, no session_id and no expiry
        // (see the signing block in /sov-login/authorize-app), so one retrieval
        // yields a node-signed binding that stays valid forever. That is what a
        // plugin doing Ed25519 verification is meant to trust, so leaving this
        // open pre-defeats the plugin hardening rather than merely predating it.
        //
        // The caller that legitimately needs this is the platform, and the
        // platform holds callback_secret. Prove possession over the path instead
        // of transmitting the secret (this endpoint is reachable over plain :80):
        //   X-Sov-Link-Auth: hex(HMAC-SHA256(callback_secret, `${sovHash}|${platHash}`))
        // FAIL CLOSED when no secret is held: a platform with a blank secret can
        // no more authorise a read than it can verify a callback.
        const platRow3 = db._db.prepare(
          'SELECT callback_secret FROM sov_platforms WHERE platform_id = ?'
        ).get(platHash);
        const secret3 = (platRow3 && platRow3.callback_secret) ? platRow3.callback_secret : '';
        if (!secret3) {
          global.sovLog.warn(`SOV_LINK_FETCH_UNVERIFIABLE_REFUSED: platform_id=${platHash} holds no callback_secret`);
          res.writeHead(503); res.end(JSON.stringify({ success: false, error: 'LINK_FETCH_UNAVAILABLE' })); return;
        }
        const rcvMac3 = String((req.headers && req.headers['x-sov-link-auth']) || '');
        const expMac3 = crypto.createHmac('sha256', secret3).update(`${sovHash}|${platHash}`).digest('hex');
        const rcvBuf3 = Buffer.from(rcvMac3, 'utf8');
        const expBuf3 = Buffer.from(expMac3, 'utf8');
        // Length is checked first because timingSafeEqual throws on a mismatch.
        if (rcvMac3 === '' || rcvBuf3.length !== expBuf3.length || !crypto.timingSafeEqual(rcvBuf3, expBuf3)) {
          // A MISSING header is a failure, never a skip — the same fail-open shape
          // that made the generated plugins accept an unsigned callback.
          global.sovLog.warn(`SOV_LINK_FETCH_REJECTED: platform_id=${platHash} X-Sov-Link-Auth ${rcvMac3 === '' ? 'missing' : 'mismatched'}`);
          res.writeHead(401); res.end(JSON.stringify({ success: false, error: 'UNAUTHORIZED' })); return;
        }

        // Find link where sha256(sovereign_id).slice(0,32) matches sovHash and platform_id matches platHash
        const links = db._db.prepare('SELECT * FROM sov_citizen_links WHERE platform_id = ?').all(platHash);
        const link  = links.find(l => crypto.createHash('sha256').update(l.sovereign_id).digest('hex').slice(0, 32) === sovHash);
        if (!link) { res.writeHead(404); res.end(JSON.stringify({ success: false, error: 'LINK_NOT_FOUND' })); return; }
        // Build the relay pool for embedding in the .sovlink file
        // Addresses come from the live network, never from literals. A literal
        // here is copied into every .sovlink handed to a platform, so it is
        // published to third parties and goes stale the moment a node moves —
        // which is exactly how verify_endpoints ended up pointing at
        // documentation addresses that can never answer.
        const nodeIp2 = _selfHost(network);   // 1.4.92: never the Host header
        let sovlinkHosts = [];
        try { sovlinkHosts = advertisedNodes(db); } catch (_) {}
        if (!sovlinkHosts.length && nodeIp2) sovlinkHosts = [nodeIp2];
        const sovlinkRelayPool = {
          version: 11, updated_at: Date.now(), served_by: nodeIp2,
          nodes: sovlinkHosts.map((h, i) => poolEntryFor(db, relayPool, h, i, nodeIp2)),
          verify_endpoints: sovlinkHosts.map(h => 'http://' + h + '/sov-link/verify-password'),
          pool_refresh_url: `http://${nodeIp2}/relay-pool/latest`,
        };
        // Get palm_name if available
        let palmName2 = '';
        try { const enr2 = db._db.prepare('SELECT palm_name FROM sov_enrollments WHERE sovereign_id = ?').get(link.sovereign_id); palmName2 = (enr2 && enr2.palm_name) ? enr2.palm_name : ''; } catch(e) {}
        res.writeHead(200, { 'Content-Disposition': `attachment; filename="${link.sovereign_id}.sovlink"` });
        res.end(JSON.stringify({
          format: 'sovlink-v1', version: 1, issued_at: link.issued_at,
          sovereign_id: link.sovereign_id, palm_name: palmName2,
          platform_domain: link.platform_domain, platform_id: link.platform_id,
          binding: {
            password_verifier: link.password_verifier,
            binding_sig: link.binding_sig,
            network_sig: link.network_sig,
          },
          relay_pool: sovlinkRelayPool,
        }));
      } catch (err) {
        res.writeHead(500); res.end(JSON.stringify({ success: false, error: 'INTERNAL_ERROR' }));
      }
      return;
    }

    // ── POST /sov-link/verify-password — platform verifies citizen password ────
    if (url === '/sov-link/verify-password') {
      if (req.method === 'OPTIONS') {
        res.writeHead(204, { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Methods': 'POST, OPTIONS', 'Access-Control-Allow-Headers': 'Content-Type' });
        res.end(); return;
      }
      if (req.method !== 'POST') { res.writeHead(405); res.end('POST required'); return; }
      let body = '';
      req.on('data', c => body += c);
      req.on('end', () => {
        res.setHeader('Content-Type', 'application/json');
        res.setHeader('Access-Control-Allow-Origin', '*');
        try {
          if (!db) { res.writeHead(503); res.end(JSON.stringify({ success: false })); return; }
          _ensureSovLoginSdkTables(db);
          const { sovereign_id, password, platform_domain } = JSON.parse(body || '{}');
          if (!sovereign_id || !password || !platform_domain) { res.writeHead(400); res.end(JSON.stringify({ success: false, error: 'MISSING_FIELDS' })); return; }
          const platformId = crypto.createHash('sha256').update(platform_domain).digest('hex').slice(0, 32);

          // Per claude-afri review #4: brute-force lockout. Per (sovereign_id,
          // platform_id) tuple:
          //   • 5 failed attempts within rolling 10-min window → lockout 15min
          //   • lockout response: { success:false, error:'TEMPORARILY_LOCKED',
          //                         retry_after_seconds }
          //   • success resets counter
          const now            = Date.now();
          const WINDOW_MS      = 10 * 60 * 1000;   // 10 min
          const LOCKOUT_MS     = 15 * 60 * 1000;   // 15 min
          const MAX_FAILS      = 5;
          const lockRow = db._db.prepare(
            'SELECT attempt_count, last_attempt, locked_until ' +
            'FROM sov_login_attempts WHERE sovereign_id = ? AND platform_id = ?'
          ).get(sovereign_id, platformId);
          if (lockRow && lockRow.locked_until > now) {
            const retry = Math.ceil((lockRow.locked_until - now) / 1000);
            res.writeHead(429);
            res.end(JSON.stringify({
              success: false,
              error: 'TEMPORARILY_LOCKED',
              retry_after_seconds: retry,
            }));
            global.sovLog.warn(`SOV_LINK_VERIFY: LOCKED sovereign=${sovereign_id} platform=${platform_domain} retry=${retry}s`);
            return;
          }

          const link = db._db.prepare('SELECT password_verifier FROM sov_citizen_links WHERE sovereign_id = ? AND platform_id = ?').get(sovereign_id, platformId);
          // ── Account-existence oracle fix (2026-08-01) ────────────────────
          // This endpoint is PUBLIC and UNAUTHENTICATED. It used to answer
          // NOT_LINKED for an unlinked citizen but a bare {success:false} for a
          // linked one with the wrong password — so anyone could ask "does this
          // SOV ID hold an account on this platform?" with no credential at all.
          // Sovereign IDs are quasi-public (contact lists, transfers, the site
          // itself), so that was a working cross-platform correlation channel on
          // a network whose entire promise is that such correlation is not
          // possible.
          //
          // THREE CHANNELS HAD TO CLOSE TOGETHER. Closing one alone just moves
          // the leak somewhere less obvious:
          //   1. BODY    — identical response either way.
          //   2. CLOCK   — bcryptjs returns instantly on an empty verifier, so an
          //                unlinked id answered in ~0ms against ~100ms for a
          //                linked one. We now burn the same work on a dummy hash.
          //   3. LOCKOUT — the unlinked branch returned BEFORE the rate limiter.
          //                Probing six times and watching for TEMPORARILY_LOCKED
          //                would rebuild the oracle even with 1 and 2 fixed, so
          //                unlinked failures are counted like any other failure.
          //
          // Cost: a caller who genuinely has not linked can no longer be told so.
          // That is deliberate — the site shows one generic "SOV ID or password
          // is incorrect" and keeps New Member Setup permanently reachable, which
          // is the same trade every credential form makes.
          //
          // bcrypt self-salted — compare, never recompute-and-string-equal.
          let ok = false;
          if (link) {
            ok = _verifyPasswordAgainstVerifier(password, link.password_verifier);
          } else {
            _verifyPasswordAgainstVerifier(password, _DUMMY_PW_VERIFIER);
          }

          // Update attempts table — successes reset, failures increment.
          if (ok) {
            try {
              db._db.prepare(
                'DELETE FROM sov_login_attempts WHERE sovereign_id = ? AND platform_id = ?'
              ).run(sovereign_id, platformId);
            } catch (_) {}
          } else {
            try {
              // If the previous attempt was outside the rolling window, restart count
              let newCount = 1;
              if (lockRow && (now - lockRow.last_attempt) <= WINDOW_MS) {
                newCount = lockRow.attempt_count + 1;
              }
              const lockUntil = newCount >= MAX_FAILS ? (now + LOCKOUT_MS) : 0;
              db._db.prepare(
                'INSERT INTO sov_login_attempts ' +
                '(sovereign_id, platform_id, attempt_count, last_attempt, locked_until) ' +
                'VALUES (?, ?, ?, ?, ?) ' +
                'ON CONFLICT(sovereign_id, platform_id) DO UPDATE SET ' +
                '  attempt_count = excluded.attempt_count, ' +
                '  last_attempt  = excluded.last_attempt, ' +
                '  locked_until  = excluded.locked_until'
              ).run(sovereign_id, platformId, newCount, now, lockUntil);
              if (lockUntil > 0) {
                global.sovLog.warn(`SOV_LINK_VERIFY: now LOCKING sovereign=${sovereign_id} platform=${platform_domain} for 15min after ${newCount} fails`);
              }
              // Unlinked probes now write rows too, so an attacker spraying
              // random ids could grow this table without bound. Drop anything
              // that is neither inside the rolling window nor currently locked.
              db._db.prepare(
                'DELETE FROM sov_login_attempts WHERE last_attempt < ? AND locked_until < ?'
              ).run(now - WINDOW_MS, now);
            } catch (_) {}
          }

          global.sovLog.debug(`SOV_LINK_VERIFY: sovereign=${sovereign_id} platform=${platform_domain} result=${ok ? 'OK' : 'FAIL'}`);
          res.writeHead(200); res.end(JSON.stringify({ success: ok }));
        } catch (err) {
          res.writeHead(500); res.end(JSON.stringify({ success: false, error: 'INTERNAL_ERROR' }));
        }
      });
      return;
    }

    // ── /sov-link/generate-plugin — RETIRED 2026-10-02 (king's decision) ──────────
    // It took a citizen's 12-word seed in the body of a plain-HTTP POST and rebuilt
    // their keys on the node. A seed is the whole identity and must never leave the
    // device, so the safe version of this endpoint is no endpoint. It was also a
    // second way to create a platform row - with no fee, no signature and a blank
    // callback secret (see the sov_platforms note above). No client used it: not
    // the app, the CLI, the site, the Academy or any known integrator.
    //
    // The body is deliberately NOT read: answering 410 without parsing means a
    // seed someone still sends here is never decoded, held or logged.
    if (url === '/sov-link/generate-plugin') {
      req.resume(); // discard unread
      res.writeHead(410, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ success: false, error: 'ENDPOINT_RETIRED',
        message: 'Never send a seed phrase to any server. SOV Link pairing runs in the SOV app.' }));
      return;
    }

    // ── POST /sov-link/verify-plugin — platform verifies citizen login (sovlink-v2) ──
    // Two-step: (1) lookup platform by install_hash; (2) verify scrypt password
    if (url === '/sov-link/verify-plugin') {
      // 1.4.93 (D4/D5): retired. The old plugins called a removed endpoint and needed a file nothing
      // can produce any more; the registration script asked for the seed phrase; verify-plugin took
      // citizens' passwords in clear. The app's platform registration hands out the working plugin.
      res.writeHead(410, { 'Content-Type': 'text/plain; charset=utf-8', 'Access-Control-Allow-Origin': '*' });
      res.end('Retired with the old plugins. Passwords are verified on the platform\'s own server against the verifier it received.\n');
      return;
    }

    // [REMOVED 2026-05-20] /sov-login/initiate-v2 — built portal URLs for the
    // browser-form phishing flow. Removed alongside /auth/* and /sov-login/initiate.
    // sovlink-v2 binary file consumers now use /sov-link/verify-plugin directly.

    // ── POST /sov-login/resolve — confirm a Sovereign ID and return its palm name ──
    // [2026-08-14] Was "resolve palm name or @alias to sovereign_id". It resolves in
    // ONE direction now: id → name. See the ORACLE CUT note in the else branch.
    if (url === '/sov-login/resolve') {
      if (req.method === 'OPTIONS') {
        res.writeHead(204, { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Methods': 'POST, OPTIONS', 'Access-Control-Allow-Headers': 'Content-Type' });
        res.end(); return;
      }
      if (req.method !== 'POST') { res.writeHead(405); res.end('POST required'); return; }
      let body = '';
      req.on('data', c => body += c);
      req.on('end', () => {
        res.setHeader('Content-Type', 'application/json');
        res.setHeader('Access-Control-Allow-Origin', '*');
        try {
          if (!db) { res.writeHead(503); res.end(JSON.stringify({ success: false })); return; }
          const { query } = JSON.parse(body || '{}');
          if (!query) { res.writeHead(400); res.end(JSON.stringify({ success: false, error: 'MISSING_QUERY' })); return; }
          let result = null;
          if (/^SOV-[0-9A-F]{16}$/i.test(query)) {
            // Direct sovereign ID.
            // [GHOST-COUNT 2026-08-14] Anchored on sov_enrollments, not sov_disc,
            // for the same reason as /sov-status above: a disc row is a wallet slot
            // (one signed session, or being the recipient of a transfer), not proof
            // of citizenship. (When this was written the sibling palm-name branch
            // below already resolved out of sov_enrollments and this branch was the
            // odd one out; that branch has since been cut entirely — see below.)
            const enrById = db._db.prepare('SELECT sovereign_id FROM sov_enrollments WHERE sovereign_id = ?').get(query.toUpperCase());
            if (enrById) result = { sovereign_id: enrById.sovereign_id };
          } else {
            // [ORACLE CUT 2026-08-14] The palm-name → sovereign_id branch is GONE.
            // It published the citizen directory. This POST takes no credential and
            // answers with Access-Control-Allow-Origin: *, and a palm name is drawn
            // from a ~1,024-word dictionary — so ~1,024 requests from any browser
            // tab enumerated every citizen this node had ever enrolled, by name AND
            // by id. The lookup is one-way by design now: id → name is something a
            // caller holding the id could derive anyway; name → id is the oracle.
            //
            // It was also WRONG, not merely leaky. Palm names are not unique and
            // `LIMIT 1` returned an arbitrary one of the colliding rows. Against a
            // 1,024-name dictionary the first collision is expected at ~38 enrolled
            // citizens (birthday bound) — after that the loser of a collision
            // resolves to someone else's sovereign_id and is locked out of every
            // platform that resolves by name. One cut closes both.
            //
            // The refusal is CONSTANT for every non-id query — it must never differ
            // between a name that exists and one that does not, or the oracle is
            // simply back one status code out.
            res.writeHead(400);
            res.end(JSON.stringify({
              success: false,
              error: 'ID_REQUIRED',
              detail: "Name lookup is not available. Pass a Sovereign ID ('SOV-' + 16 hex).",
            }));
            return;
          }
          if (result) {
            // Enrich with palm_name
            try {
              const enr2 = db._db.prepare('SELECT palm_name FROM sov_enrollments WHERE sovereign_id = ?').get(result.sovereign_id);
              if (enr2) result.palm_name = enr2.palm_name;
            } catch (e) {}
            res.writeHead(200); res.end(JSON.stringify({ success: true, ...result }));
          } else {
            res.writeHead(200); res.end(JSON.stringify({ success: false, error: 'NOT_FOUND' }));
          }
        } catch (err) {
          res.writeHead(500); res.end(JSON.stringify({ success: false, error: 'INTERNAL_ERROR' }));
        }
      });
      return;
    }

    // ── GET /sdk/verify-snap.py — citizen tool to verify snap signature ──
    // V2 hardening 2026-05-21: Citizens fetch this before installing the snap
    // and verify the Ed25519 signature against the bundled founder pubkey.
    if (url === '/sdk/verify-snap.py' || url === '/sdk/verify-snap.py.sha256') {
      try {
        const fs = require('fs');
        const path = require('path');
        const isHash = url.endsWith('.sha256');
        const scriptPath = path.join(__dirname, 'sdk', 'verify-snap.py');
        if (!fs.existsSync(scriptPath)) { res.statusCode = 404; res.end('Not Found'); return; }
        const scriptBytes = fs.readFileSync(scriptPath);
        if (isHash) {
          const crypto = require('crypto');
          const sha = crypto.createHash('sha256').update(scriptBytes).digest('hex');
          res.setHeader('Content-Type', 'text/plain; charset=utf-8');
          res.setHeader('Access-Control-Allow-Origin', '*');
          res.end(`${sha}  verify-snap.py\n`);
        } else {
          res.setHeader('Content-Type', 'text/x-python; charset=utf-8');
          res.setHeader('Access-Control-Allow-Origin', '*');
          res.setHeader('Content-Disposition', 'attachment; filename="verify-snap.py"');
          res.end(scriptBytes);
        }
      } catch (e) {
        res.statusCode = 500;
        res.end('Server error reading SDK script');
      }
      return;
    }

    // ── GET /sdk/sov-platform-register.py — citizen-signed platform registration CLI ──
    // Per Protocol Book Ch.20 + Blueprint Addendum §905: registration is citizen-signed,
    // no admin key, no central server. Script lives on disk alongside relay_pool.js so it
    // can be hot-swapped without restarting sov-node. Served from every relay node
    // whose :80 is free (a node co-tenanted with another web service will not serve it).
    if (url === '/sdk/sov-platform-register.py' || url === '/sdk/sov-platform-register.py.sha256') {
      // 1.4.93 (D4/D5): retired. The old plugins called a removed endpoint and needed a file nothing
      // can produce any more; the registration script asked for the seed phrase; verify-plugin took
      // citizens' passwords in clear. The app's platform registration hands out the working plugin.
      res.writeHead(410, { 'Content-Type': 'text/plain; charset=utf-8', 'Access-Control-Allow-Origin': '*' });
      res.end('Retired. Register your platform from the SOV app: it signs the request on your device and gives you a ready-made plugin. Never type your seed phrase anywhere.\n');
      return;
    }

    // ── GET /sdk/sov-plugin.php — serve platform PHP plugin (sovlink-v2) ────────
    if (url === '/sdk/sov-plugin.php') {
      // 1.4.93 (D4/D5): retired. The old plugins called a removed endpoint and needed a file nothing
      // can produce any more; the registration script asked for the seed phrase; verify-plugin took
      // citizens' passwords in clear. The app's platform registration hands out the working plugin.
      res.writeHead(410, { 'Content-Type': 'text/plain; charset=utf-8', 'Access-Control-Allow-Origin': '*' });
      res.end('Retired. Register your platform from the SOV app; it gives you a plugin already set up for your site.\n');
      return;
    }

    // ── GET /sdk/sov-plugin.js — serve platform JavaScript plugin (sovlink-v2) ──
    if (url === '/sdk/sov-plugin.js') {
      // 1.4.93 (D4/D5): retired. The old plugins called a removed endpoint and needed a file nothing
      // can produce any more; the registration script asked for the seed phrase; verify-plugin took
      // citizens' passwords in clear. The app's platform registration hands out the working plugin.
      res.writeHead(410, { 'Content-Type': 'text/plain; charset=utf-8', 'Access-Control-Allow-Origin': '*' });
      res.end('Retired. Register your platform from the SOV app; it gives you a plugin already set up for your site.\n');
      return;
    }

    res.writeHead(404); res.end('');
  });

  server.listen(port, () => {
    global.sovLog.info(`      Discovery server: http://[your-ip]:${port}`);
    global.sovLog.info(`      Node software:     http://[your-ip]:${port}/sov-relay.snap`);
  });

  // 1.4.93 (D45): never fail SILENTLY. On an upgrade the old process can still hold the port for a
  // moment; every other error used to be swallowed and the node ran with no discovery server at all.
  let _bindTries = 0;
  server.on('error', (err) => {
    if (err.code === 'EACCES' && port !== 8080) {
      // Port 80 requires root on Linux — try port 8080
      server.listen(8080, () => {
        global.sovLog.info(`      Discovery server: http://[your-ip]:8080 (port 80 requires root)`);
      });
    } else if (err.code === 'EADDRINUSE' && ++_bindTries <= 30) {
      global.sovLog.warn(`      Discovery server: port ${port} busy — retry ${_bindTries}/30 in 3 s`);
      setTimeout(() => { try { server.listen(port); } catch (_) {} }, 3000);
    } else {
      global.sovLog.error(`      Discovery server FAILED on port ${port}: ${err.code || err.message} — the node list, downloads and plugins are NOT served`);
    }
  });

  // ── peer-mesh wiring (called after peerMesh is up in index.js) ────────────
  server.setPeerMesh = function(peerMesh) {
    _peerMesh = peerMesh;
    _advertMesh = peerMesh; // what advertisedNodes() trusts: admitted peers only
    if (!peerMesh) return;

    // Receive: another node minted a Flow A2 pairing code — store locally
    // so that this node can also resolve `/sov-login/check-app` for it.
    peerMesh.on('PAIRING_BROADCAST', (msg) => {
      try {
        if (!db || !msg || !msg.pairing_code || !msg.session_id) return;
        _ensureSovLoginSdkTables(db);
        // Upsert pairing row
        db._db.prepare(
          'INSERT OR REPLACE INTO sov_app_pairings ' +
          '(pairing_code, session_id, expires_at, used_at) ' +
          'VALUES (?, ?, ?, ?)'
        ).run(msg.pairing_code, msg.session_id, msg.expires_at || 0, msg.used_at || null);
        // Upsert session row so check-app can find it
        if (msg.session) {
          const s = msg.session;
          db._db.prepare(
            'INSERT OR REPLACE INTO sov_auth_sessions ' +
            '(session_id, platform_id, return_url, status, sovereign_id, palm_name, created_at, expires_at, flow_type) ' +
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)'
          ).run(
            s.session_id, s.platform_id, s.return_url || '',
            s.status || 'pending', s.sovereign_id || '', s.palm_name || '',
            s.created_at || Date.now(), s.expires_at || 0, s.flow_type || 'app'
          );
        }
        global.sovLog.debug(`[Mesh] PAIRING_BROADCAST replicated: code=${msg.pairing_code}`);
      } catch (e) {
        global.sovLog.warn(`[Mesh] PAIRING_BROADCAST handler error: ${e.message}`);
      }
    });

    // Receive: another node verified a pairing (used_at set) or completed
    // session (status=verified). Mirror the state so any node can serve
    // /sov-login/poll-app correctly regardless of which node minted it.
    peerMesh.on('PAIRING_STATE_BROADCAST', (msg) => {
      try {
        if (!db || !msg || !msg.session_id) return;
        _ensureSovLoginSdkTables(db);
        if (msg.used_at) {
          db._db.prepare('UPDATE sov_app_pairings SET used_at = ? WHERE session_id = ?')
            .run(msg.used_at, msg.session_id);
        }
        if (msg.status) {
          db._db.prepare(
            'UPDATE sov_auth_sessions SET status = ?, sovereign_id = COALESCE(?, sovereign_id), palm_name = COALESCE(?, palm_name) WHERE session_id = ?'
          ).run(msg.status, msg.sovereign_id || null, msg.palm_name || null, msg.session_id);
        }
        global.sovLog.debug(`[Mesh] PAIRING_STATE_BROADCAST replicated: session=${msg.session_id.slice(0,12)} status=${msg.status||'-'}`);
      } catch (e) {
        global.sovLog.warn(`[Mesh] PAIRING_STATE_BROADCAST handler error: ${e.message}`);
      }
    });

    // Receive: another node accepted a /sov-platform/register call — store
    // the platform row locally so Flow A2 can find it on any node.
    peerMesh.on('PLATFORM_BROADCAST', (msg) => {
      try {
        if (!db || !msg || !msg.platform_id) return;
        _ensureSovLoginSdkTables(db);
        // A peer broadcast is a NOTIFICATION, not a complete row. INSERT OR
        // REPLACE deletes the stored row first, so every field the broadcast
        // omitted was being written back as '' / 0. The `|| ''` defaults made
        // that silent. Consequences, worst first:
        //   • callback_secret blanked -> this node stops sending
        //     X-Sov-Callback-Hmac (the sender only signs `if (secret)`), and a
        //     receiver that fails closed on a missing header answers 401. The
        //     link is refused and nothing on either side says why.
        //   • return_url blanked -> the callback is never fired at all.
        //   • x25519_pubkey_hex blanked -> the sealed-secret re-register path
        //     has no key to seal to.
        // Merge over what is already on disk instead: a field the broadcast does
        // not carry keeps its stored value. Looked up by platform_id ONLY —
        // never by domain, or a domain collision under a different platform_id
        // would copy that platform's callback_secret into this row.
        const _priorPlat = db._db.prepare('SELECT * FROM sov_platforms WHERE platform_id = ?').get(msg.platform_id) || {};
        const _keep = (incoming, stored, empty) => {
          if (incoming !== undefined && incoming !== null && incoming !== empty) return incoming;
          return (stored !== undefined && stored !== null) ? stored : empty;
        };
        db._db.prepare(
          'INSERT OR REPLACE INTO sov_platforms ' +
          '(platform_id, domain, return_url, registered_at, public_key_hex, ' +
          ' callback_secret, registered_by_sovereign_id, x25519_pubkey_hex, ' +
          ' register_fee_seeds, active, expires_at) ' +
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?)'
        ).run(
          msg.platform_id,
          _keep(msg.domain,      _priorPlat.domain,      ''),
          _keep(msg.return_url,  _priorPlat.return_url,  ''),
          msg.registered_at || _priorPlat.registered_at || Date.now(),
          _keep(msg.public_key_hex, _priorPlat.public_key_hex, ''),
          _keep(msg.callback_secret, _priorPlat.callback_secret, ''),
          _keep(msg.registered_by_sovereign_id, _priorPlat.registered_by_sovereign_id, ''),
          _keep(msg.x25519_pubkey_hex, _priorPlat.x25519_pubkey_hex, ''),
          _keep(msg.register_fee_seeds, _priorPlat.register_fee_seeds, 0),
          _keep(msg.expires_at, _priorPlat.expires_at, 0)
        );
        // Replicate the fee's payment-history record (transparency; tx_id dedup).
        if (msg.fee_tx && msg.fee_tx.tx_id && db.insertTransaction) {
          try {
            db.insertTransaction({
              tx_id: msg.fee_tx.tx_id,
              tx_hash: crypto.createHash('sha256').update(`${msg.fee_tx.tx_id}:${msg.fee_tx.amount_seeds}`).digest('hex'),
              from_id: msg.fee_tx.from_id, to_id: 'SOV-POOL-WITNESS-OPERATOR',
              amount_seeds: msg.fee_tx.amount_seeds || 0,
              memo: msg.fee_tx.memo || 'SOV Login platform registration (annual)',
              status: 'confirmed', confirmed_at: Date.now(), created_at: Date.now(),
            });
          } catch (_) {}
        }
        global.sovLog.debug(`[Mesh] PLATFORM_BROADCAST replicated: domain=${msg.domain} by=${msg.registered_by_sovereign_id || 'legacy'}`);
      } catch (e) {
        global.sovLog.warn(`[Mesh] PLATFORM_BROADCAST handler error: ${e.message}`);
      }
    });

    // Receive: a citizen↔platform link was created on another node — mirror
    // so /sov-link/verify-password works on any node post-Flow-A2 link.
    peerMesh.on('CITIZEN_LINK_BROADCAST', (msg) => {
      try {
        if (!db || !msg || !msg.link_id) return;
        _ensureSovLoginSdkTables(db);
        db._db.prepare(
          'INSERT OR REPLACE INTO sov_citizen_links ' +
          '(link_id, sovereign_id, platform_id, platform_domain, password_verifier, binding_sig, network_sig, issued_at) ' +
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?)'
        ).run(
          msg.link_id, msg.sovereign_id, msg.platform_id,
          msg.platform_domain || '', msg.password_verifier || '',
          msg.binding_sig || '', msg.network_sig || '',
          msg.issued_at || Date.now()
        );
        global.sovLog.debug(`[Mesh] CITIZEN_LINK_BROADCAST replicated: sovereign=${msg.sovereign_id} platform=${msg.platform_domain}`);
      } catch (e) {
        global.sovLog.warn(`[Mesh] CITIZEN_LINK_BROADCAST handler error: ${e.message}`);
      }
    });

    global.sovLog.info('      Peer-mesh wired: PAIRING / PLATFORM / CITIZEN_LINK broadcasts active');
  };

  return server;
}

module.exports = { RelayPool, createDiscoveryServer };
