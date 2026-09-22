// ─────────────────────────────────────────────────────────────────────────────
// OPERATOR ENGINE — Node registration, proof-of-service earnings, dashboard
// ─────────────────────────────────────────────────────────────────────────────
// When a citizen's computer boots the SOV Node, this engine handles formal
// entry into the operator network.
//
// Three subsystems:
//
//   1. Operator Registration — "the interrogation signup"
//      New nodes advertise themselves to bootstrap seeds. Existing nodes verify
//      the software is authentic, the operator is enrolled, the stake is posted,
//      the node is novel. On pass: node added to sov_operator_registry.
//
//   2. Proof of Service — hourly scoring + earnings
//      Every hour, a node computes a score based on citizens served, uptime,
//      and peer count. Broadcasts to peers. Citizens vote via governance to
//      set how many seeds each score point earns.
//
//   3. Self-registration — this node registers with the network on boot
//      After peer_mesh is established, this node sends NODE_OPERATOR_SIGNUP
//      to all known bootstrap seeds.
//
// Peer mesh message types handled:
//   NODE_OPERATOR_SIGNUP         ← inbound from new node wanting to register
//   NODE_OPERATOR_APPROVED       ← received when this node is approved by peers
//   NODE_OPERATOR_REJECTED       ← received when this node is rejected
//   OPERATOR_REGISTRY_BROADCAST  ← cross-node registry sync
//   PROOF_OF_SERVICE             ← received from peer nodes
//   PROOF_OF_SERVICE_ACK         ← acknowledgment of our own proof
//
// Phone op codes (phone → node): none — operator protocol is node-to-node
//
// Governance params consumed:
//   relay_join_min_stake          Minimum SOV seeds staked to join
//   relay_max_citizens            Maximum citizens this node can serve
//   proof_of_service_reward_seeds Seeds earned per proof_of_service score unit
//   max_nodes_per_operator        Max nodes one citizen may operate
// ─────────────────────────────────────────────────────────────────────────────

'use strict';

const crypto = require('crypto');

// Release trust — there is NO founder key and no hardcoded signing key here.
// A release is legitimate when the earned nodes actually running the network agree
// on the source_root it was built from (source_root attestation between operators),
// not because any single keyholder signed it. See docs/NODE_INTEGRITY_DESIGN.md.

class OperatorEngine {

  constructor(identity, db, peerMesh) {
    this._identity = identity;
    this._db       = db;
    this._peerMesh = peerMesh;
    this._gateway  = null;

    // Track when this node was started (for uptime calculation)
    this._startedAt         = Date.now();
    this._citizensServedHr  = 0;  // reset every hour by _computeProofOfService
    this._isRegistered      = false;
    this._registrationTimer = null;

    this._initOperatorTables();

    // Register peer mesh handlers
    peerMesh.on('NODE_OPERATOR_SIGNUP',        (msg, fromNodeId) => this._handleOperatorSignup(msg, fromNodeId));
    peerMesh.on('NODE_OPERATOR_APPROVED',      (msg)             => this._handleApproved(msg));
    peerMesh.on('NODE_OPERATOR_REJECTED',      (msg)             => this._handleRejected(msg));
    peerMesh.on('OPERATOR_REGISTRY_BROADCAST', (msg)             => this._handleRegistryBroadcast(msg));
    peerMesh.on('PROOF_OF_SERVICE',            (msg, fromNodeId) => this._handlePeerProof(msg, fromNodeId));

    // Try to register this node after peers are established (30s boot delay)
    setTimeout(() => this._attemptSelfRegistration(), 30 * 1000);

    // Hourly: compute and broadcast proof of service
    setTimeout(() => {
      this._computeProofOfService();
      setInterval(() => this._computeProofOfService(), 60 * 60 * 1000);
    }, 60 * 60 * 1000);  // first proof after 1 hour of operation

    global.sovLog.info('      ✓ Operator engine initialised');
  }

  setGateway(gateway) {
    this._gateway = gateway;
  }

  /**
   * OPERATOR ENFORCEMENT (king 2026-08-14). A node may serve citizens ONLY if it
   * is a legitimate operator. Two ways to qualify:
   *   1. A registered, ACTIVE operator whose sovereign id is an ENROLLED citizen.
   *   2. A genesis/standalone bootstrap node (no SOV_BOOTSTRAP_NODES configured) with
   *      no operator yet — it serves so citizen #1 can ENROL on it; the first operator then
   *      sets OPERATOR_SOVEREIGN_ID and restarts to become a normal registered operator.
   * A JOINING node (bootstrap peers configured) whose operator is not a valid enrolled
   * citizen serves NOTHING — the previous code only LOGGED "will not serve" and never
   * enforced it. Infrastructure is not free and not anonymous: that is the SOV economy.
   */
  isAuthorizedToServe() {
    const opId = String((this._identity && this._identity.operatorSovereignId) || '').trim();
    if (opId) {
      try {
        if (this._db.getEnrollment && this._db.getEnrollment(opId)) {
          const row = this._db._db.prepare(
            "SELECT 1 FROM sov_operator_registry WHERE node_id = ? AND operator_id = ? AND status = 'active'"
          ).get(String(this._identity.nodeId), opId);
          if (row) return true;                 // valid, registered, enrolled operator
        }
      } catch (_) { /* fall through to the bootstrap check */ }
    }
    // No valid registered operator. Only a genesis/standalone node — nothing to
    // bootstrap from — may serve in this state (the first-citizen enrolment window).
    // A node with bootstrap peers is JOINING an existing network and must have a
    // valid operator first.
    return String(process.env.SOV_BOOTSTRAP_NODES || '').trim() === '';
  }

  // ── Table initialisation ──────────────────────────────────────────────────

  _initOperatorTables() {
    this._db._db.exec(`

      -- ── Operator Registry ─────────────────────────────────────────────────
      -- Every approved node in the SOV network
      CREATE TABLE IF NOT EXISTS sov_operator_registry (
        node_id             TEXT PRIMARY KEY,
        operator_id         TEXT NOT NULL,          -- sovereign_id of the operator
        public_key_hex      TEXT NOT NULL,          -- node's Ed25519 public key
        manifest_hash       TEXT NOT NULL DEFAULT '',
        hardware_class      TEXT NOT NULL DEFAULT 'desktop',
        stake_seeds         INTEGER NOT NULL DEFAULT 0,
        registered_at       INTEGER NOT NULL,
        last_seen_at        INTEGER NOT NULL DEFAULT 0,
        proof_score         REAL NOT NULL DEFAULT 0.0,
        total_earnings      INTEGER NOT NULL DEFAULT 0,  -- seeds earned lifetime
        status              TEXT NOT NULL DEFAULT 'active'  -- active | suspended | deregistered
      );
      CREATE INDEX IF NOT EXISTS idx_operator_citizen ON sov_operator_registry(operator_id);

      -- ── Proof of Service Log ───────────────────────────────────────────────
      -- One row per node per epoch; used for earnings calculation
      CREATE TABLE IF NOT EXISTS sov_proof_of_service_log (
        epoch_id            TEXT NOT NULL,          -- 'YYYY-MM-DDTHH' (hourly)
        node_id             TEXT NOT NULL,
        score               REAL NOT NULL DEFAULT 0.0,
        citizens_served     INTEGER NOT NULL DEFAULT 0,
        uptime_sec          INTEGER NOT NULL DEFAULT 0,
        peer_count          INTEGER NOT NULL DEFAULT 0,
        merkle_root         TEXT NOT NULL DEFAULT '',
        earned_seeds        INTEGER NOT NULL DEFAULT 0,
        claimed             INTEGER NOT NULL DEFAULT 0,  -- 1 if earnings pulled
        created_at          INTEGER NOT NULL,
        PRIMARY KEY (epoch_id, node_id)
      );

    `);
    // King's design: continuous-uptime streak columns (added by migration so
    // existing registries gain them). A gap resets the streak; payout needs >=21d.
    // source_root added here too: db.js also ALTERs it in, but on a FRESH DB that
    // runs before this table exists (the ALTER fails silently), so _registerLocally
    // hit "no column named source_root" at genesis. Adding it to this post-CREATE
    // loop guarantees the column on both fresh and existing registries.
    for (const col of ['uptime_streak_start INTEGER NOT NULL DEFAULT 0',
                       'last_uptime_tick INTEGER NOT NULL DEFAULT 0',
                       "source_root TEXT NOT NULL DEFAULT ''"]) {
      try { this._db._db.exec('ALTER TABLE sov_operator_registry ADD COLUMN ' + col); } catch (_) {}
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  SUBSYSTEM 1 — OPERATOR REGISTRATION
  // ═══════════════════════════════════════════════════════════════════════════

  // Called at boot (30s delay) — broadcast our signup to bootstrap peers
  async _attemptSelfRegistration() {
    // Check if this node is already registered (survived a restart)
    const existing = this._db._db.prepare(
      'SELECT node_id, status, operator_id, source_root FROM sov_operator_registry WHERE node_id = ?'
    ).get(this._identity.nodeId);

    if (existing && existing.status === 'active') {
      this._isRegistered = true;
      global.sovLog.info(`[Operator] Already registered as ${this._identity.nodeId.slice(0, 12)}...`);

      // operator_id drift: an operator who sets (or corrects) OPERATOR_SOVEREIGN_ID
      // AFTER first registration was previously stuck with whatever was recorded on
      // day one — usually blank. That silently cost them every payout, because the
      // payout joins on this column, not on the .env. Reconcile it here.
      const mineOp = this._identity.operatorSovereignId || '';
      if (mineOp !== (existing.operator_id || '')) {
        this._db._db.prepare(
          'UPDATE sov_operator_registry SET operator_id = ? WHERE node_id = ?'
        ).run(mineOp, this._identity.nodeId);
        global.sovLog.info('[Operator] operator_id reconciled: ' +
          JSON.stringify(existing.operator_id || '') + ' -> ' + JSON.stringify(mineOp));
      }
      // source_root drift: the registered source_root is written ONCE at signup, but
      // the source a node runs changes on every upgrade. Left stale, the earned-quorum
      // ratification (_sourceRootAccepted, read by peers' Check 5) compares against an
      // out-of-date root, so a peer running the CURRENT agreed source would fail the
      // earned-set path and rely on MATCHES_OURS alone. Reconcile it to what we run now
      // — identical fix shape to the operator_id drift above. (Layer 2 completion.)
      const mineRoot = this._localSourceRoot();
      if (mineRoot && mineRoot !== (existing.source_root || '')) {
        this._db._db.prepare(
          'UPDATE sov_operator_registry SET source_root = ? WHERE node_id = ?'
        ).run(mineRoot, this._identity.nodeId);
        global.sovLog.info('[Operator] source_root reconciled to running source ' +
          mineRoot.slice(0, 16) + ' (was ' + String(existing.source_root || '(none)').slice(0, 16) + ')');
      }
      // Refresh our last_seen timestamp on the network
      this._broadcastRegistryEntry(this._identity.nodeId);
      return;
    }

    const manifestHash = await this._getManifestHash();
    const manifestSig  = await this._signManifest(manifestHash);

    const stakeSeeds = 0; // King's design: NO join stake — operators earn by proven uptime, not an entry fee.

    const signup = {
      node_id:              this._identity.nodeId,
      public_key:           this._identity.publicKey,
      operator_sovereign_id: this._identity.operatorSovereignId || '',
      manifest_hash:        manifestHash,
      manifest_sig:         manifestSig,
      // What source this node is actually running. Peers compare it against the
      // roots that EARNED nodes run — this is the integrity anchor, in place of a
      // single-keyholder signature. See docs/NODE_INTEGRITY_DESIGN.md Layer 2.
      source_root:          this._localSourceRoot(),
      stake_seeds:          stakeSeeds,
      hardware_class:       this._detectHardwareClass(),
      timestamp:            Date.now(),
      signature:            this._identity.sign(this._identity.nodeId + ':' + Date.now()),
    };

    global.sovLog.info(`[Operator] Broadcasting NODE_OPERATOR_SIGNUP to ${this._peerMesh.peerCount()} peers`);

    // If we have no peers yet — register ourselves locally (genesis/bootstrap mode)
    if (this._peerMesh.peerCount() === 0) {
      global.sovLog.info('[Operator] No peers found — registering as bootstrap node');
      // network-seed-join-v1: a first node has nobody to receive the network's
      // biometric seed from, so it mints one — the same reasoning that lets it
      // register itself without a quorum. Every node after this one receives
      // this seed in its approval instead of an operator typing it in.
      try {
        const ns = require('../security/network_seed');
        const r  = ns.generate();
        if (r.created) global.sovLog.info(`[Operator] Genesis: minted the network biometric seed (${ns.fingerprint()})`);
      } catch (e) {
        global.sovLog.warn(`[Operator] Genesis seed mint failed: ${e.message}`);
      }
      this._registerLocally(signup, 'genesis');
      return;
    }

    // Ask a SAMPLE of peers, not every peer.
    //
    // Two things were wrong with broadcasting to all: the message cost grew with
    // the size of the network, and acceptance was first-reply-wins, so a single
    // dishonest peer could admit any node it liked. Sampling fixes the cost and
    // requiring a quorum of that sample fixes the trust — an attacker now has to
    // control most of a randomly chosen set, which does not get easier as the
    // network grows.
    //
    // The interrogation itself costs the network nothing: every node already
    // holds the full enrollment ledger, so "is this operator a real citizen" is a
    // local lookup, never a query out to anyone.
    const sampleSize = parseInt(this._getGovParam('operator_signup_sample', '5'));
    const peers      = this._peerMesh.peerIds ? this._peerMesh.peerIds() : [];
    const sample     = this._pickRandomPeers(peers, sampleSize);

    // Small networks cannot produce a big quorum, and must still be able to grow.
    // Requiring more approvals than there are peers would wedge the network shut.
    const want = parseInt(this._getGovParam('operator_signup_quorum', '3'));
    this._approvals       = new Set();
    this._approvalsNeeded = Math.max(1, Math.min(want, sample.length || peers.length || 1));

    global.sovLog.info(
      `[Operator] Asking ${sample.length || 'all'} peer(s) to interrogate; ` +
      `${this._approvalsNeeded} approval(s) needed`);

    if (sample.length) {
      for (const p of sample) this._peerMesh.sendTo(p, 'NODE_OPERATOR_SIGNUP', signup);
    } else {
      this._peerMesh.broadcast('NODE_OPERATOR_SIGNUP', signup);   // peer list unavailable
    }

    // Set a timeout — if no approval within 2 minutes, retry
    this._registrationTimer = setTimeout(() => {
      if (!this._isRegistered) {
        global.sovLog.warn('[Operator] Registration timed out — retrying in 5 minutes');
        setTimeout(() => this._attemptSelfRegistration(), 5 * 60 * 1000);
      }
    }, 2 * 60 * 1000);
  }

  // Called when a PEER sends NODE_OPERATOR_SIGNUP — we are the interrogating node
  _handleOperatorSignup(msg, fromNodeId) {
    const {
      node_id, public_key, operator_sovereign_id,
      manifest_hash, manifest_sig,
      stake_seeds, hardware_class, timestamp, signature,
    } = msg;

    if (!node_id || !public_key || !timestamp) {
      global.sovLog.debug(`[Operator] Invalid signup from ${fromNodeId} — missing fields`);
      return;
    }

    // ── Check 1: Timestamp freshness (within 5 minutes) ─────────────────────
    if (Math.abs(Date.now() - timestamp) > 5 * 60 * 1000) {
      this._rejectNode(node_id, fromNodeId, 'STALE_TIMESTAMP');
      return;
    }

    // ── Check 1b: Operator identity is REQUIRED ─────────────────────────────
    // Checks 3 and 4 below used to be wrapped in `if (operator_sovereign_id)`,
    // so a node that simply sent no ID skipped both and was registered as
    // 'anonymous'. That is the whole Sybil defence made optional by omission:
    // unlimited nodes, none tied to an enrolled human, none subject to the
    // per-operator cap. An operator ID is not decoration — it is the thing that
    // makes a node accountable to a person, so a signup without one is refused.
    //
    // This runs BEFORE the already-registered check on purpose. Approving on
    // "we have seen this node before" would grandfather in every anonymous node
    // that ever registered, which is exactly the state we are closing.
    const opId = String(operator_sovereign_id || '').trim().toUpperCase();
    if (!opId) {
      this._rejectNode(node_id, fromNodeId, 'OPERATOR_ID_REQUIRED');
      return;
    }
    if (!/^SOV-[0-9A-F]{16}$/.test(opId)) {
      this._rejectNode(node_id, fromNodeId, 'OPERATOR_ID_MALFORMED');
      return;
    }

    // ── Check 2: Node not already registered ────────────────────────────────
    const existing = this._db._db.prepare(
      'SELECT node_id, status FROM sov_operator_registry WHERE node_id = ?'
    ).get(node_id);

    if (existing && existing.status === 'active') {
      // Already known — approve and update last_seen
      this._peerMesh.sendTo(fromNodeId, 'NODE_OPERATOR_APPROVED', {
        node_id,
        approved_by:  this._identity.nodeId,
        timestamp:    Date.now(),
        network_seed: this._networkSeedForApproval(),
      });
      this._db._db.prepare(
        'UPDATE sov_operator_registry SET last_seen_at = ? WHERE node_id = ?'
      ).run(Date.now(), node_id);
      return;
    }

    // ── Check 3: Operator is an enrolled citizen ────────────────────────────
    // Unconditional. A well-formed ID that belongs to nobody is still nobody.
    const enrollment = this._db.getEnrollment(opId);
    if (!enrollment) {
      this._rejectNode(node_id, fromNodeId, 'OPERATOR_NOT_ENROLLED');
      return;
    }

    // ── Check 4: Max nodes per operator ─────────────────────────────────────
    // Unconditional. This cap is the only thing stopping one enrolled human from
    // spinning up enough nodes to outvote the rest of the network.
    const maxNodes = parseInt(this._getGovParam('max_nodes_per_operator', '3'));
    const operatorNodeCount = this._db._db.prepare(
      'SELECT COUNT(*) as cnt FROM sov_operator_registry WHERE operator_id = ? AND status = ? AND node_id != ?'
    ).get(opId, 'active', String(node_id));
    if (operatorNodeCount && operatorNodeCount.cnt >= maxNodes) {
      this._rejectNode(node_id, fromNodeId, 'OPERATOR_NODE_LIMIT_REACHED');
      return;
    }

    // ── Check 5: (REMOVED) No join stake — King's design: an operator is paid
    //    for proven uptime (>= 21 continuous days), never charged to enter.

    // ── Check 6: Software the network recognises ────────────────────────────
    // This replaced a single-key manifest signature. Nobody signs a release into
    // existence; a version becomes legitimate when the operators actually running
    // the network are running it. Nothing here depends on a person being alive.
    const srcCheck = this._sourceRootAccepted(msg.source_root);
    const mode     = String(this._getGovParam('release_enforce_mode', 'warn'));
    if (!srcCheck.ok) {
      global.sovLog.warn(
        `[Operator] source_root ${String(msg.source_root || '(none)').slice(0, 16)} ` +
        `from ${node_id.slice(0, 12)} — ${srcCheck.reason} ` +
        `(earned nodes agreeing: ${srcCheck.agreeing}, mode=${mode})`);
      if (mode === 'refuse') {
        this._rejectNode(node_id, fromNodeId, 'UNRECOGNISED_SOFTWARE');
        return;
      }
    } else {
      global.sovLog.info(
        `[Operator] source_root recognised for ${node_id.slice(0, 12)} (${srcCheck.reason})`);
    }

    // ── ALL CHECKS PASSED — register the node ───────────────────────────────
    global.sovLog.info(`[Operator] Approving node ${node_id.slice(0, 12)}... (operator: ${opId})`);

    try {
      this._db._db.prepare(`
        INSERT OR REPLACE INTO sov_operator_registry
          (node_id, operator_id, public_key_hex, manifest_hash, hardware_class,
           stake_seeds, registered_at, last_seen_at, status, source_root)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'active', ?)
      `).run(
        String(node_id),
        operator_sovereign_id != null ? String(operator_sovereign_id) : '',
        public_key            != null ? String(public_key)            : '',
        manifest_hash         != null ? String(manifest_hash)         : '',
        hardware_class        != null ? String(hardware_class)        : 'desktop',
        stake_seeds           != null ? Number(stake_seeds)           : 0,
        Date.now(),
        Date.now(),
        String(msg && msg.source_root || signup && signup.source_root || ''),
      );
    } catch (err) {
      global.sovLog.warn(`[Operator] _handleOperatorSignup INSERT failed: ${err.message} — node: ${node_id ? String(node_id).slice(0, 12) : 'unknown'}`);
      return;
    }

    // Approve the registering node directly
    this._peerMesh.sendTo(fromNodeId, 'NODE_OPERATOR_APPROVED', {
      node_id,
      approved_by:  this._identity.nodeId,
      timestamp:    Date.now(),
      network_seed: this._networkSeedForApproval(),
    });

    // Broadcast new registry entry to all other peers
    this._broadcastRegistryEntry(node_id);
  }

  // network-seed-join-v1 — hand the network's biometric seed to a node we just
  // admitted. Same trust boundary as the ledger it is about to receive: an
  // approved node already gets every citizen's template, and this key only makes
  // those templates comparable. Returned as '' when we have none ourselves, so a
  // node that never received one cannot pass the legacy constant off as real.
  _networkSeedForApproval() {
    try {
      const ns = require('../security/network_seed');
      return ns.has() ? ns.load() : '';
    } catch (_) { return ''; }
  }

  _handleApproved(msg) {
    const { node_id, approved_by, network_seed } = msg;
    if (node_id !== this._identity.nodeId) return;

    // Take the seed BEFORE the quorum check. Approval may arrive from several
    // peers and only the first carries a seed we do not yet have; receive()
    // refuses to overwrite one we already hold, so a later or forged approval
    // cannot orphan the templates on this node.
    if (network_seed) {
      try {
        const ns = require('../security/network_seed');
        const r  = ns.receive(network_seed);
        if (r.stored) {
          global.sovLog.info(`[Operator] Received the network biometric seed on join (${ns.fingerprint()})`);
        } else if (r.reason === 'REFUSED_WOULD_OVERWRITE') {
          global.sovLog.error(
            `[Operator] A peer sent a DIFFERENT biometric seed than the one this node holds — refused. ` +
            `Duplicate detection between this node and ${String(approved_by).slice(0, 12)}… will not work.`);
        }
      } catch (e) {
        global.sovLog.warn(`[Operator] network seed receive failed: ${e.message}`);
      }
    }

    if (!this._isRegistered) {
      // Count DISTINCT approvers. Without the Set, one peer replying twice would
      // satisfy a quorum of two on its own, which is the same hole reopened.
      this._approvals = this._approvals || new Set();
      this._approvals.add(String(approved_by));
      const need = this._approvalsNeeded || 1;
      if (this._approvals.size < need) {
        global.sovLog.info(
          `[Operator] Approval ${this._approvals.size}/${need} from ${approved_by.slice(0, 12)}...`);
        return;
      }

      this._isRegistered = true;
      if (this._registrationTimer) {
        clearTimeout(this._registrationTimer);
        this._registrationTimer = null;
      }
      global.sovLog.info(`[Operator] ✓ Registration approved by ${this._approvals.size} peer(s)`);

      // Register locally now that we're approved
      this._registerLocally({
        node_id:              this._identity.nodeId,
        public_key:           this._identity.publicKey,
        operator_sovereign_id: this._identity.operatorSovereignId || '',
        manifest_hash:        '',
        hardware_class:       this._detectHardwareClass(),
        stake_seeds:          parseInt(this._getGovParam('relay_join_min_stake', '100')) * 1_000_000,
      }, approved_by);
    }
  }

  _handleRejected(msg) {
    const { node_id, reason } = msg;
    if (node_id !== this._identity.nodeId) return;
    global.sovLog.warn(`[Operator] Registration rejected: ${reason}`);
    global.sovLog.warn('[Operator] ENFORCED: this node is NOT an authorized operator and will'
      + ' now REFUSE citizen connections (OPERATOR_NOT_AUTHORIZED) until resolved.');
    global.sovLog.warn('[Operator] Fix: OPERATOR_SOVEREIGN_ID must be an ENROLLED citizen'
      + ' (enrol on the app first), then restart. Also check snap version / source_root.');
    // The gateway enforces this live via OperatorEngine.isAuthorizedToServe() on every
    // new connection; drop any citizen sockets already accepted in the signup window.
    try { if (this._gateway && typeof this._gateway.closeAllCitizens === 'function') this._gateway.closeAllCitizens('OPERATOR_NOT_AUTHORIZED'); } catch (_) {}
  }

  _handleRegistryBroadcast(msg) {
    try {
      const {
        node_id, operator_id, public_key_hex,
        hardware_class, stake_seeds, registered_at, status, source_root,
      } = msg;

      if (!node_id) return;

      // Normalise every field to a concrete type — better-sqlite3-multiple-ciphers
      // throws "Too few parameter values were provided" if any argument is undefined.
      const p_node_id       = String(node_id);
      const p_operator_id   = operator_id   != null ? String(operator_id)   : '';
      const p_public_key    = public_key_hex != null ? String(public_key_hex): '';
      const p_hw_class      = hardware_class != null ? String(hardware_class): 'desktop';
      const p_stake         = stake_seeds    != null ? Number(stake_seeds)   : 0;
      const p_reg_at        = registered_at  != null ? Number(registered_at) : Date.now();
      const p_status        = status         != null ? String(status)        : 'active';
      const p_source_root   = source_root    != null ? String(source_root)   : '';

      if (!Number.isFinite(p_stake))  { /* stake was NaN/Infinity — use 0 */; }
      if (!Number.isFinite(p_reg_at)) { /* registered_at was bad — skip */; return; }

      // INSERT OR IGNORE — don't overwrite active entries with stale data
      this._db._db.prepare(`
        INSERT OR IGNORE INTO sov_operator_registry
          (node_id, operator_id, public_key_hex, hardware_class, stake_seeds, registered_at, last_seen_at, status, source_root)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      `).run(
        p_node_id,
        p_operator_id,
        p_public_key,
        p_hw_class,
        Number.isFinite(p_stake) ? p_stake : 0,
        p_reg_at,
        Date.now(),
        p_status,
        p_source_root,
      );

      // source_root replication: INSERT OR IGNORE never touches an EXISTING row, so a
      // node that upgraded its source would stay recorded at its old root on every peer,
      // breaking the earned-quorum ratification. Update it explicitly — but only when the
      // broadcast carries a concrete root, so a node that hasn't computed one yet can never
      // clobber a known-good value with an empty string. The node itself is authoritative
      // for its own source_root (it reconciles then broadcasts), so last-write self-corrects.
      if (p_source_root) {
        this._db._db.prepare(
          'UPDATE sov_operator_registry SET source_root = ? WHERE node_id = ? AND source_root != ?'
        ).run(p_source_root, p_node_id, p_source_root);
      }
    } catch (err) {
      global.sovLog.warn(`[Operator] _handleRegistryBroadcast failed: ${err.message} — msg keys: ${Object.keys(msg || {}).join(',')}`);
    }
  }

  /** Random sample without replacement, so the same peers are not always asked. */
  _pickRandomPeers(peers, k) {
    const pool = Array.from(peers || []);
    for (let i = pool.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      [pool[i], pool[j]] = [pool[j], pool[i]];
    }
    return pool.slice(0, Math.max(0, k));
  }

  /** This node's own source fingerprint, or '' if it cannot be computed. */
  _localSourceRoot() {
    try {
      const { sourceRoot } = require('../release/source_root');
      const path = require('path');
      return sourceRoot(path.join(__dirname, '..', '..')).root || '';
    } catch (_) { return ''; }
  }

  /**
   * Is `root` a source fingerprint that the network already runs?
   *
   * Accepted when a quorum of EARNED nodes run it. Earned means the node has met
   * the continuous-uptime bar, so an attacker cannot manufacture agreement by
   * starting machines — they would have to keep them up for the qualifying period
   * first, in public, which is the cost that makes this work.
   *
   * Our own root always counts: a node will not refuse software identical to the
   * software it is itself running.
   */
  _sourceRootAccepted(root) {
    if (!root) return { ok: false, reason: 'NO_SOURCE_ROOT_DECLARED', agreeing: 0 };
    if (root === this._localSourceRoot()) return { ok: true, reason: 'MATCHES_OURS', agreeing: 1 };

    let agreeing = 0;
    try {
      const minDays = parseInt(this._getGovParam('release_signer_min_uptime_days', '1'));
      const cutoff  = Date.now() - minDays * 86400000;
      // Count DISTINCT EARNED OPERATORS (not nodes) that already run this exact source.
      // Three filters, each closing a way to manufacture agreement (A2/A3):
      //   - operator_id != '' : an anonymous row cannot vouch for software. Sybil closure
      //     rejects anonymous signup now, but pre-existing / gossiped anonymous rows must
      //     not count either.
      //   - COUNT(DISTINCT operator_id) : one operator = one voice. Without it, one operator
      //     running up to max_nodes_per_operator (3) nodes on the same source would alone
      //     satisfy a quorum of 2 — the whole point of "earned" is defeated.
      //   - uptime_streak_start <= cutoff : the earned bar. Agreement cannot be spun up by
      //     freshly-started machines; they must have stayed up, in public, for the qualifying
      //     window first. That public cost is what the guarantee rests on.
      const r = this._db._db.prepare(
        `SELECT COUNT(DISTINCT operator_id) AS n FROM sov_operator_registry
          WHERE status = 'active' AND source_root = ?
            AND operator_id IS NOT NULL AND operator_id != ''
            AND uptime_streak_start IS NOT NULL AND uptime_streak_start <= ?`
      ).get(root, cutoff);
      agreeing = r ? r.n : 0;
    } catch (_) { /* column may not exist yet on an older node */ }

    const need = parseInt(this._getGovParam('release_dispute_threshold', '2'));
    return { ok: agreeing >= need, reason: agreeing ? 'EARNED_NODES_AGREE' : 'UNRECOGNISED_SOURCE',
             agreeing };
  }

  _registerLocally(signup, approvedBy) {
    try {
      this._db._db.prepare(`
        INSERT OR REPLACE INTO sov_operator_registry
          (node_id, operator_id, public_key_hex, manifest_hash, hardware_class,
           stake_seeds, registered_at, last_seen_at, status, source_root)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'active', ?)
      `).run(
        String(signup.node_id),
        signup.operator_sovereign_id != null ? String(signup.operator_sovereign_id) : '',
        signup.public_key != null ? String(signup.public_key) : (this._identity.publicKey != null ? String(this._identity.publicKey) : ''),
        signup.manifest_hash != null ? String(signup.manifest_hash) : '',
        signup.hardware_class != null ? String(signup.hardware_class) : 'desktop',
        signup.stake_seeds != null ? Number(signup.stake_seeds) : 0,
        Date.now(),
        Date.now(),
        String((signup && signup.source_root) || ''),
      );
    } catch (err) {
      global.sovLog.warn(`[Operator] _registerLocally INSERT failed: ${err.message}`);
      return;
    }
    global.sovLog.info(`[Operator] Registered locally (approved by: ${approvedBy})`);
  }

  _rejectNode(nodeId, fromNodeId, reason) {
    global.sovLog.debug(`[Operator] Rejecting ${nodeId.slice(0, 12)}: ${reason}`);
    this._peerMesh.sendTo(fromNodeId, 'NODE_OPERATOR_REJECTED', {
      node_id:     nodeId,
      reason,
      rejected_by: this._identity.nodeId,
      timestamp:   Date.now(),
    });
  }

  _broadcastRegistryEntry(nodeId) {
    const row = this._db._db.prepare(
      'SELECT * FROM sov_operator_registry WHERE node_id = ?'
    ).get(nodeId);
    if (!row) return;

    this._peerMesh.broadcast('OPERATOR_REGISTRY_BROADCAST', {
      node_id:       row.node_id,
      operator_id:   row.operator_id,
      public_key_hex: row.public_key_hex,
      hardware_class: row.hardware_class,
      stake_seeds:   row.stake_seeds,
      registered_at: row.registered_at,
      status:        row.status,
      // Layer 2: replicate the running source fingerprint so peers' earned-quorum
      // ratification sees CURRENT roots, not the value frozen at first signup.
      source_root:   row.source_root || '',
    });
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  SUBSYSTEM 2 — PROOF OF SERVICE
  // ═══════════════════════════════════════════════════════════════════════════

  _computeProofOfService() {
    if (!this._isRegistered) return;

    const now          = Date.now();
    const uptimeSec    = Math.floor((now - this._startedAt) / 1000);
    const citizensNow  = this._gateway ? this._gateway.connectedCount() : 0;
    const peerCount    = this._peerMesh.peerCount();
    const epochId      = new Date(now).toISOString().slice(0, 13); // 'YYYY-MM-DDTHH'

    // Proof-of-service score formula:
    //   base = citizens served in hour
    //   uptime factor = min(uptime_sec / 3600, 1.0)   — 1.0 if online full hour
    //   peer factor = min(peer_count / 4, 1.0)         — full score at 4+ peers
    //   score = base × uptime_factor × peer_factor
    const uptimeFactor = Math.min(uptimeSec / 3600, 1.0);
    const peerFactor   = Math.min(peerCount / 4, 1.0);
    const score        = (this._citizensServedHr + citizensNow) * uptimeFactor * peerFactor;

    // Merkle root of current disc state (sampled from DB)
    const merkleRoot = this._db.getNetworkStateHash ? this._db.getNetworkStateHash() : '';

    const rewardRate  = parseInt(this._getGovParam('proof_of_service_reward_seeds', '0'));
    const earnedSeeds = Math.floor(score * rewardRate);

    // King's design: continuous-uptime streak. A gap > 90 min (a missed hourly
    // tick = sleep/shutdown/restart) resets the streak; otherwise it accrues.
    try {
      const GAP_MS = 90 * 60 * 1000;
      const _reg = this._db._db.prepare('SELECT last_uptime_tick, uptime_streak_start FROM sov_operator_registry WHERE node_id = ?').get(this._identity.nodeId);
      let _streakStart = (_reg && _reg.uptime_streak_start) || 0;
      const _lastTick = (_reg && _reg.last_uptime_tick) || 0;
      if (!_streakStart || (_lastTick && (now - _lastTick) > GAP_MS)) _streakStart = now;
      // A node also refreshes its OWN last_seen_at here. Without this it only ever
      // updated peers' rows (in _handlePeerProof), so every node's view of ITSELF
      // went stale — VPS1 read 57 days old while running. Anything treating
      // last_seen_at as liveness (pruning, dashboards) would have judged live nodes dead.
      this._db._db.prepare('UPDATE sov_operator_registry SET last_uptime_tick = ?, uptime_streak_start = ?, last_seen_at = ? WHERE node_id = ?').run(now, _streakStart, now, this._identity.nodeId);
    } catch (_) {}

    const epochExists = this._db._db.prepare(
      'SELECT epoch_id FROM sov_proof_of_service_log WHERE epoch_id = ? AND node_id = ?'
    ).get(epochId, this._identity.nodeId);

    if (!epochExists) {
      this._db._db.prepare(`
        INSERT INTO sov_proof_of_service_log
          (epoch_id, node_id, score, citizens_served, uptime_sec, peer_count,
           merkle_root, earned_seeds, claimed, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?)
      `).run(
        epochId, this._identity.nodeId,
        score, this._citizensServedHr + citizensNow,
        uptimeSec, peerCount, merkleRoot, earnedSeeds, now,
      );
    }

    // Broadcast proof to peers for verification
    const proof = {
      node_id:         this._identity.nodeId,
      epoch_id:        epochId,
      score,
      citizens_served: this._citizensServedHr + citizensNow,
      uptime_sec:      uptimeSec,
      peer_count:      peerCount,
      merkle_root:     merkleRoot,
      earned_seeds:    earnedSeeds,
      timestamp:       now,
    };

    this._peerMesh.broadcast('PROOF_OF_SERVICE', proof);

    // Reset hourly citizen counter
    this._citizensServedHr = 0;

    global.sovLog.info(`[Operator] Proof-of-service: score=${score.toFixed(2)}, citizens=${citizensNow}, peers=${peerCount}, earned=${earnedSeeds} seeds`);
  }

  _handlePeerProof(msg, fromNodeId) {
    const { node_id, epoch_id, score, citizens_served, uptime_sec, peer_count,
            merkle_root, earned_seeds, timestamp } = msg;

    if (!node_id || !epoch_id || score === undefined) return;

    // Verify the proof came from a registered node
    const operator = this._db._db.prepare(
      'SELECT node_id, status FROM sov_operator_registry WHERE node_id = ?'
    ).get(node_id);

    if (!operator || operator.status !== 'active') {
      global.sovLog.debug(`[Operator] Proof from unregistered node ${node_id.slice(0, 12)} ignored`);
      return;
    }

    // Store peer proof (INSERT OR IGNORE — first-seen wins)
    this._db._db.prepare(`
      INSERT OR IGNORE INTO sov_proof_of_service_log
        (epoch_id, node_id, score, citizens_served, uptime_sec, peer_count,
         merkle_root, earned_seeds, claimed, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?)
    `).run(
      epoch_id, node_id,
      score || 0, citizens_served || 0,
      uptime_sec || 0, peer_count || 0,
      merkle_root || '', earned_seeds || 0, Date.now(),
    );

    // Update last_seen for this operator
    this._db._db.prepare(
      'UPDATE sov_operator_registry SET last_seen_at = ?, proof_score = ? WHERE node_id = ?'
    ).run(Date.now(), score, node_id);
  }

  // ── Track connected citizens for proof scoring ────────────────────────────
  // Called by gateway when citizen connects — increments hourly counter
  onCitizenServed() {
    this._citizensServedHr++;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  PUBLIC API — used by other engines + gateway
  // ═══════════════════════════════════════════════════════════════════════════

  isRegistered() {
    return this._isRegistered;
  }

  /// Returns a summary object for display in node_status_screen / dashboard
  getRegistrationInfo() {
    const nodeId = this._identity.nodeId;
    let proofScore     = 0;
    let operatorId     = '';
    let registeredNodes = 0;
    try {
      const row = this._db._db.prepare(
        'SELECT operator_id, proof_score FROM sov_operator_registry WHERE node_id = ? AND status = ?'
      ).get(nodeId, 'active');
      if (row) {
        proofScore  = row.proof_score  || 0;
        operatorId  = row.operator_id  || '';
      }
      const countRow = this._db._db.prepare(
        "SELECT COUNT(*) as cnt FROM sov_operator_registry WHERE status = 'active'"
      ).get();
      registeredNodes = countRow ? countRow.cnt : 0;
    } catch (_) {}
    return {
      isRegistered:    this._isRegistered,
      operatorId,
      proofScore,
      registeredNodes,
    };
  }

  getRegisteredNodeCount() {
    // Count operators that are active AND have ticked within the same 90-minute
    // "currently up" window the payout streak logic uses (a live node refreshes
    // last_seen_at hourly via proof-of-service). Without the freshness guard, a
    // node that flapped its identity across a restart — leaving a stale active
    // row under its OLD node_id plus a fresh one under the new id — double-counts
    // itself. Keying off last_seen_at ages the stale row out of the count
    // automatically (it stops advancing once the old identity is gone).
    const cutoff = Date.now() - 90 * 60 * 1000;
    const row = this._db._db.prepare(
      "SELECT COUNT(*) as cnt FROM sov_operator_registry WHERE status = 'active' AND last_seen_at >= ?"
    ).get(cutoff);
    return row ? row.cnt : 0;
  }

  getOperatorRegistry(limit = 100) {
    return this._db._db.prepare(`
      SELECT node_id, operator_id, hardware_class, stake_seeds,
             registered_at, last_seen_at, proof_score, total_earnings, status
      FROM sov_operator_registry
      WHERE status = 'active'
      ORDER BY proof_score DESC
      LIMIT ?
    `).all(limit);
  }

  getProofHistory(nodeId, limit = 24) {
    return this._db._db.prepare(`
      SELECT epoch_id, score, citizens_served, uptime_sec, peer_count, earned_seeds, claimed
      FROM sov_proof_of_service_log
      WHERE node_id = ?
      ORDER BY epoch_id DESC
      LIMIT ?
    `).all(nodeId || this._identity.nodeId, limit);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  GOVERNANCE PARAM HELPER
  // ═══════════════════════════════════════════════════════════════════════════

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

  // ═══════════════════════════════════════════════════════════════════════════
  //  UTILITIES
  // ═══════════════════════════════════════════════════════════════════════════

  _detectHardwareClass() {
    const os  = require('os');
    const mem = os.totalmem();
    const cpu = os.cpus().length;

    // Raspberry Pi has <= 4 GB RAM; servers have many cores
    if (mem < 4 * 1024 * 1024 * 1024) return 'pi';
    if (cpu >= 8) return 'server';
    return 'desktop';
  }

  async _getManifestHash() {
    // Read the signed manifest from the data directory
    const path     = require('path');
    const fs       = require('fs');
    const dataDir  = process.env.SOV_DATA_DIR || require('os').homedir() + '/.sov-node';
    const manifest = path.join(dataDir, 'manifest.json');

    if (!fs.existsSync(manifest)) return '';

    try {
      const content = fs.readFileSync(manifest, 'utf8');
      return crypto.createHash('sha256').update(content).digest('hex');
    } catch (_) {
      return '';
    }
  }

  async _signManifest(manifestHash) {
    if (!manifestHash) return '';
    try {
      // Sign the manifest hash with this node's identity key
      const sig = this._identity.sign(Buffer.from(manifestHash, 'hex'));
      return Buffer.isBuffer(sig) ? sig.toString('hex') : sig;
    } catch (_) {
      return '';
    }
  }

  // _verifyManifest() and MASTER_PUBLIC_KEY_HEX were REMOVED on 2026-07-31.
  // They verified a release against a single hardcoded key, which the design replaced with
  // earned-node source attestation (_sourceRootAccepted above). The constant was
  // 64 zeros, so the check passed anything — and left in place it read like an
  // unfinished feature whose obvious completion would put a central authority
  // back into a network built to not need one. See docs/NODE_INTEGRITY_DESIGN.md.

  // ─── Monthly operator payout ──────────────────────────────────────────────
  // SPEC: docs/SOV_OPERATOR_ECONOMY_SPEC.md (king-approved 2026-07-19), which
  // implements SOV_Network_Architecture.docx §10.3 "Operator Rewards".
  //
  // Earning basis (§10.3): "per confirmed transaction + uptime" — operators earn
  // for DOING THE WORK, never for merely existing:
  //     entitlement = Σ relays [ tier × (uptime_reward + tx_reward × confirmed_txs) ]
  //
  // Anti-monopoly tier (PROTOCOL-LOCKED, not governance-adjustable):
  //     relay 1 = ×1.00, relay 2 = ×0.25, relay 3 = ×0.25, relay 4+ = ×0.00
  //     (4th+ earns NOTHING — "infrastructure credit only". Max = ×1.50/operator.)
  //
  // Funding order (§3): FEES FIRST, reserve only tops up and only up to
  // operator_reserve_draw_cap. If entitlements exceed the budget everyone is paid
  // PRO-RATA — so the reserve can never be drained no matter how many operators
  // enroll. (A fixed per-relay rate scales linearly with operator count: without
  // the cap, 100k operators would empty a 20M reserve in months.)
  //
  // HISTORY — why this was rewritten: the previous implementation paid
  // `pool.remaining_seeds × operator_monthly_payout_pct` (1%) per period = 200,000
  // SOV on a 20M pool, regardless of whether a single transaction was confirmed.
  // That formula appears in NO blueprint and was never approved; it credited
  // 199,999.84 SOV to one operator in a single period. Retired.
  //
  // Qualification: >= operator_min_uptime_days (21) CONTINUOUS uptime.
  // Dedup: PRIMARY KEY (operator_id, period_id) on sov_operator_payouts.
  // Peer broadcasts replicate the payout to all nodes via INSERT OR IGNORE.
  // Period: 30-day epoch from Unix time. Same period_id on all nodes.
  static get _PAYOUT_TIER_RATES() { return [1.00, 0.25, 0.25]; } // relay 4+ = 0
  static get _PAYOUT_PERIOD_MS()  { return 30 * 24 * 3600 * 1000; }

  _currentPayoutPeriod() {
    return Math.floor(Date.now() / OperatorEngine._PAYOUT_PERIOD_MS);
  }

  /// Tier multiplier for an operator running [relayCount] relays.
  /// 1st ×1.00, 2nd ×0.25, 3rd ×0.25, 4th+ ×0.00 → max ×1.50. Protocol-locked.
  static tierMultiplier(relayCount) {
    const rates = OperatorEngine._PAYOUT_TIER_RATES;
    let m = 0;
    for (let i = 0; i < Math.min(relayCount, rates.length); i++) m += rates[i];
    return m;
  }

  _runMonthlyOperatorPayout() {
    try {
      const periodId = this._currentPayoutPeriod();

      const uptimeReward = parseInt(this._getGovParam('operator_uptime_reward', '20000000'));
      const txReward     = parseInt(this._getGovParam('operator_tx_reward', '0'));
      const drawCap      = parseInt(this._getGovParam('operator_reserve_draw_cap', '50000000000'));
      if (uptimeReward <= 0 && txReward <= 0) return;   // economy switched off by governance

      const pool = this._db.getPool ? this._db.getPool('witness_operator') : null;
      if (!pool) return;

      // ── Group registered nodes by operator ────────────────────────────────
      const nodes = this._db._db.prepare(
        'SELECT node_id, operator_id AS operator_sovereign_id FROM sov_operator_registry WHERE operator_id != \'\' ORDER BY registered_at ASC'
      ).all();
      const byOperator = {};
      for (const n of nodes) {
        const op = n.operator_sovereign_id;
        if (!byOperator[op]) byOperator[op] = [];
        byOperator[op].push(n);
      }

      // ── Pass 1: compute entitlements for qualifying operators ─────────────
      const _minDays = parseInt(this._getGovParam('operator_min_uptime_days', '21'));
      const _minMs   = _minDays * 86400000;
      const _nowQ    = Date.now();
      const entitlements = [];   // { opId, relays, multiplier, seeds }
      let totalEntitled = 0;

      for (const opId of Object.keys(byOperator)) {
        const ops = byOperator[opId];
        // Pay ONLY operators with a node CONTINUOUSLY up for >= 21 days.
        // Sleep/shutdown breaks the streak; a stale tick (>90 min) means down.
        const _streaks = this._db._db.prepare(
          'SELECT uptime_streak_start, last_uptime_tick FROM sov_operator_registry WHERE operator_id = ? AND status = ?'
        ).all(opId, 'active');
        const _qualified = _streaks.some(r =>
          r.uptime_streak_start && (_nowQ - r.uptime_streak_start) >= _minMs &&
          r.last_uptime_tick    && (_nowQ - r.last_uptime_tick) < 90 * 60 * 1000);
        if (!_qualified) continue;

        // Already paid this period? (dedup mirrors the INSERT OR IGNORE below)
        const already = this._db._db.prepare(
          'SELECT 1 FROM sov_operator_payouts WHERE operator_id = ? AND period_id = ?'
        ).get(opId, periodId);
        if (already) continue;

        const multiplier = OperatorEngine.tierMultiplier(ops.length);
        if (multiplier <= 0) continue;

        // "per confirmed transaction + uptime" (§10.3). tx component is 0 at
        // launch; _confirmedTxCount stays 0 until per-node witness counting lands.
        const txCount = txReward > 0 ? this._confirmedTxCount(opId, periodId) : 0;
        const seeds   = Math.floor(multiplier * (uptimeReward + txReward * txCount));
        if (seeds <= 0) continue;

        entitlements.push({ opId, relays: ops.length, multiplier, seeds });
        totalEntitled += seeds;
      }
      if (entitlements.length === 0) return;

      // ── Budget: FEES FIRST, reserve only tops up and only up to the cap ───
      const feeInflow   = this._db.getPoolInflow ? this._db.getPoolInflow('witness_operator', periodId) : 0;
      const reserveDraw = Math.max(0, Math.min(drawCap, pool.remaining_seeds));
      const budget      = feeInflow + reserveDraw;
      if (budget <= 0) {
        global.sovLog.warn('      [PAYOUT] No budget this period (no fee inflow, reserve empty) — skipped');
        return;
      }

      // Pro-rata when entitlements exceed the budget — the reserve can never be
      // drained regardless of how many operators enroll.
      const scale = totalEntitled > budget ? budget / totalEntitled : 1;
      if (scale < 1) {
        global.sovLog.warn(
          `      [PAYOUT] Period ${periodId} OVERSUBSCRIBED — entitled ${(totalEntitled / 1e6).toFixed(2)} SOV ` +
          `vs budget ${(budget / 1e6).toFixed(2)} SOV → pro-rata ×${scale.toFixed(4)}`
        );
      }

      // ── Pass 2: pay ───────────────────────────────────────────────────────
      let totalPaid = 0, paidCount = 0;
      for (const e of entitlements) {
        const amount = Math.floor(e.seeds * scale);
        if (amount <= 0) continue;

        const result = this._db._db.prepare(
          'INSERT OR IGNORE INTO sov_operator_payouts (operator_id, period_id, node_count, amount_seeds, fired_at) VALUES (?, ?, ?, ?, ?)'
        ).run(e.opId, periodId, e.relays, amount, Date.now());
        if (result.changes !== 1) continue;   // a peer beat us to it

        const actualDeducted = this._db.deductFromPool ? this._db.deductFromPool('witness_operator', amount) : 0;
        if (actualDeducted <= 0) continue;

        this._db.creditBalance(e.opId, actualDeducted);
        totalPaid += actualDeducted;
        paidCount++;
        // TRANSPARENCY (king directive 2026-07-19): every fund movement must
        // show its origin/destination in payment history. The payout is a real
        // transaction FROM the operator pool TO the operator — record it so the
        // wallet's history shows exactly where the SOV came from. Deterministic
        // tx_id → INSERT OR IGNORE dedups across all nodes.
        this._recordPayoutTx(e.opId, periodId, e.relays, actualDeducted);
        global.sovLog.info(
          `      [PAYOUT] Operator ${e.opId.substring(0, 16)} period ${periodId} relays=${e.relays} ` +
          `multiplier=${e.multiplier.toFixed(2)} paid=${(actualDeducted / 1e6).toFixed(2)} SOV`
        );
        if (this._peerMesh && this._peerMesh.broadcast) {
          this._peerMesh.broadcast('OPERATOR_PAYOUT_BROADCAST', {
            operator_id:  e.opId,
            period_id:    periodId,
            node_count:   e.relays,
            amount_seeds: actualDeducted,
            fired_at:     Date.now(),
          });
        }
      }

      if (totalPaid > 0) {
        global.sovLog.info(
          `      [PAYOUT] Period ${periodId} complete — ${(totalPaid / 1e6).toFixed(2)} SOV to ${paidCount} operators ` +
          `(fees ${(feeInflow / 1e6).toFixed(2)} + reserve draw ${(Math.max(0, totalPaid - feeInflow) / 1e6).toFixed(2)})`
        );
      }
    } catch (e) {
      global.sovLog.error(`[PAYOUT] error: ${e.message}`);
    }
  }

  /// Confirmed transactions witnessed by [opId]'s nodes in [periodId].
  /// Per-node witness attribution is not yet tracked, so this returns 0 and the
  /// tx component contributes nothing (operator_tx_reward also launches at 0).
  /// Wire this up before governance raises operator_tx_reward above zero.
  _confirmedTxCount(_opId, _periodId) {
    return 0;
  }

  /// Payment-history record for an operator payout. Source is the named pool
  /// account so the wallet shows "from: SOV-POOL-WITNESS-OPERATOR" — never an
  /// unexplained credit. Same deterministic tx_id on every node → dedup free.
  _recordPayoutTx(opId, periodId, relays, amountSeeds) {
    try {
      const crypto = require('crypto');
      const txId   = `oppay-${periodId}-${opId}`;
      const txHash = crypto.createHash('sha256').update(`${txId}:${amountSeeds}`).digest('hex');
      this._db.insertTransaction({
        tx_id:        txId,
        tx_hash:      txHash,
        from_id:      'SOV-POOL-WITNESS-OPERATOR',
        to_id:        opId,
        amount_seeds: amountSeeds,
        memo:         `Operator payout — period ${periodId}, ${relays} relay${relays > 1 ? 's' : ''}, 21-day uptime met`,
        status:       'confirmed',
        confirmed_at: Date.now(),
        created_at:   Date.now(),
      });
    } catch (e) {
      global.sovLog.warn(`      [PAYOUT] tx-history record failed: ${e.message}`);
    }
  }

  // Peer-broadcast receiver — replicates a payout fired by another node
  _handleOperatorPayoutBroadcast(msg) {
    try {
      if (!msg || !msg.operator_id || msg.period_id == null) return;
      const result = this._db._db.prepare(
        'INSERT OR IGNORE INTO sov_operator_payouts (operator_id, period_id, node_count, amount_seeds, fired_at) VALUES (?, ?, ?, ?, ?)'
      ).run(msg.operator_id, msg.period_id, msg.node_count, msg.amount_seeds, msg.fired_at);
      if (result.changes === 1) {
        // We hadn't seen this payout — update our pool + credit operator locally
        if (this._db.deductFromPool) this._db.deductFromPool('witness_operator', msg.amount_seeds);
        this._db.creditBalance(msg.operator_id, msg.amount_seeds);
        // Mirror the payment-history record (same deterministic tx_id → the
        // operator sees the payout with its pool source on EVERY node).
        this._recordPayoutTx(msg.operator_id, msg.period_id, msg.node_count || 1, msg.amount_seeds);
      }
    } catch (_) {}
  }

}

module.exports = { OperatorEngine };
