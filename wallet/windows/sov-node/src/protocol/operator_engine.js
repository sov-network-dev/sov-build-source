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
const admission = require('./operator_admission');

// NOTE: this file used to carry a hardcoded "master release signing key" as the
// node's single trust root. The constant itself was removed some time ago and only
// its comment survived, still claiming to be "the only hardcoded trust root" while
// describing nothing - MASTER_RELEASE_KEY has no references anywhere in the tree.
// Removed with the founder key on 2026-09-27. There is no hardcoded trust root:
// a release is ratified by source_root agreement between earned nodes, which is
// what this engine's _sourceRootAccepted() decides. See docs/NODE_INTEGRITY_DESIGN.md.

class OperatorEngine {

  // How long a peer may go unseen before its observed streak resets. This tracks the
  // PROOF_OF_SERVICE cadence (hourly, see the constructor) rather than expressing a
  // policy, so it is a constant and not a governance param: three missed proofs is a
  // real outage, one is a hiccup. Governable values need the full 4-part contract in
  // CLAUDE.md §4b — PARAM_MAP, DEFAULTS, _getGovParam and a pre-built poll in the app —
  // and adding a knob here without the poll would be a half-implemented contract.
  static _OBSERVATION_GRACE_MS = 3 * 60 * 60 * 1000;

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
    peerMesh.on('NODE_OPERATOR_SIGNUP',        (msg, ws)         => this._handleOperatorSignup(msg, ws));
    // Both now take the SOCKET: an approval or rejection counts only from the peer that actually
    // sent it (ws._nodeId), never from an id the message claims (D3/D4 in
    // docs/OPERATOR_QUORUM_GAP_2026-10-03.md).
    peerMesh.on('NODE_OPERATOR_APPROVED',      (msg, ws)         => this._handleApproved(msg, ws));
    peerMesh.on('NODE_OPERATOR_REJECTED',      (msg, ws)         => this._handleRejected(msg, ws));
    // fromNodeId is now REQUIRED: source_root is merit, and merit may only be accepted
    // from the node it describes. Existence stays relayable (see _handleRegistryBroadcast).
    peerMesh.on('OPERATOR_REGISTRY_BROADCAST', (msg, ws)         => this._handleRegistryBroadcast(msg, ws));
    peerMesh.on('PROOF_OF_SERVICE',            (msg, ws)         => this._handlePeerProof(msg, ws));

    // A registered node whose certificate is out of date (the declared genesis, which registered
    // alone; or one certified on a smaller network) re-earns it soon after a peer is admitted,
    // not at the next hourly proof - otherwise every newcomer refuses its entry for up to an hour.
    if (typeof peerMesh.onPeerAdmitted === 'function') peerMesh.onPeerAdmitted(() => {
      if (this._recertSoon || !this._isRegistered || this._signupMode) return;
      this._recertSoon = setTimeout(() => {
        this._recertSoon = null;
        try {
          const own = this._db._db.prepare('SELECT admission_cert FROM sov_operator_registry WHERE node_id = ?').get(this._identity.nodeId);
          if (own && !this._signupMode && this._peerMesh.peerCount() > 0 && this._certIsStale(own)) this._startSignup('recert');
        } catch (_) {}
      }, 15 * 1000);
      if (this._recertSoon.unref) this._recertSoon.unref();
    });

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
   *      no operator yet — it serves so citizen #1 can ENROL on it; the founder then
   *      sets OPERATOR_SOVEREIGN_ID and restarts to become a normal registered operator.
   * A JOINING node (bootstrap peers configured) whose operator is not a valid enrolled
   * citizen serves NOTHING — the previous code only LOGGED "will not serve" and never
   * enforced it. Infrastructure is not free and not anonymous: that is the SOV economy.
   */
  isAuthorizedToServe() {
    // A node that declared itself genesis by mistake under an older version holds its own
    // biometric seed, so duplicate detection with the network cannot work. It must not
    // serve until its data directory is cleared and it rejoins (see peer_mesh).
    if (global.sovMistakenGenesis) return false;
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
    // No valid registered operator. Only a DECLARED genesis node (SOV_GENESIS=1) may serve
    // in this state - the first-citizen enrolment window. Every other node is joining an
    // existing network and serves once it is registered. (Until 1.4.82 any node without a
    // bootstrap address counted as "standalone" and served while unregistered.)
    return global.sovExplicitGenesis === true;
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
    // admission_cert: the signed approvals that admitted this node (JSON array), or 'genesis'.
    // Empty on rows that predate it; a node holding its own row without one re-certifies.
    for (const col of ['uptime_streak_start INTEGER NOT NULL DEFAULT 0',
                       'last_uptime_tick INTEGER NOT NULL DEFAULT 0',
                       "source_root TEXT NOT NULL DEFAULT ''",
                       "admission_cert TEXT NOT NULL DEFAULT ''"]) {
      try { this._db._db.exec('ALTER TABLE sov_operator_registry ADD COLUMN ' + col); } catch (_) {}
    }

    // ── Gap 6: OBSERVATIONS. Never replicated, never accepted from a peer. ──────
    // The rule this table exists to enforce: a node may relay what it has been TOLD
    // about EXISTENCE; it may never relay what it has been told about MERIT. Uptime
    // is merit. So each node keeps its own record of who it has itself watched, and
    // the release quorum reads only that.
    //
    // Why a separate table instead of more columns on sov_operator_registry:
    //   - the registry IS replicated (OPERATOR_REGISTRY_BROADCAST). Putting observed
    //     data in a different table makes "replicated vs observed" visible from the
    //     schema, instead of depending on per-column rules a reader has to remember.
    //   - streak_start must be genuinely NULLABLE, so "never observed" is
    //     distinguishable from "observed since the epoch". The registry's
    //     uptime_streak_start is NOT NULL DEFAULT 0, and that default IS the defect:
    //     a gossiped row inherits 0, and `0 <= cutoff` reads as maximally earned.
    //     SQLite cannot drop NOT NULL without rebuilding the table, so the honest
    //     column lives here.
    this._db._db.exec(`
      CREATE TABLE IF NOT EXISTS sov_operator_observation (
        subject_node_id TEXT PRIMARY KEY,   -- who was observed
        operator_id     TEXT NOT NULL,      -- taken from the quorum-gated registry row
        source_root     TEXT,               -- ONLY ever self-reported by the subject
        streak_start    INTEGER,            -- NULL = never observed. No default, on purpose.
        last_seen_at    INTEGER NOT NULL
      );
    `);
  }

  /**
   * Record that THIS node has itself seen `subjectNodeId` alive, right now.
   *
   * Nothing here is taken from a message body: the caller must already have
   * established that the subject spoke for itself. A subject cannot lengthen its own
   * streak and a third party cannot lengthen it either — the only way to look earned
   * is to actually stay up, visibly, for the window, which is the property the
   * integrity model rests on (docs/NODE_INTEGRITY_DESIGN.md).
   *
   * A gap longer than the grace window resets the streak, per the king's design that
   * a break in service starts the count again.
   */
  _observePeerAlive(subjectNodeId) {
    if (!subjectNodeId || subjectNodeId === this._identity.nodeId) return;
    try {
      // operator_id comes from the registry, whose EXISTENCE rows are quorum-gated by
      // the signup interrogation. An unregistered node is not observed at all.
      // source_root is taken from the registry too, and that is sound ONLY because the
      // registry column is now written exclusively from self-reported broadcasts (see
      // _handleRegistryBroadcast). Without that gate this would be laundering a relayed
      // claim into an observation. Needed because the ordering is not guaranteed: a node
      // re-announces its own root ~30s after boot, which can arrive before this node has
      // ever observed it, and an UPDATE against a row that does not exist yet is silent.
      const reg = this._db._db.prepare(
        "SELECT operator_id, source_root FROM sov_operator_registry WHERE node_id = ? AND status = 'active'"
      ).get(subjectNodeId);
      const opId = reg && reg.operator_id ? String(reg.operator_id) : '';
      const opRoot = reg && reg.source_root ? String(reg.source_root) : null;
      if (!opId) return;

      const now = Date.now();
      const prev = this._db._db.prepare(
        'SELECT streak_start, last_seen_at FROM sov_operator_observation WHERE subject_node_id = ?'
      ).get(subjectNodeId);

      if (!prev) {
        this._db._db.prepare(
          'INSERT INTO sov_operator_observation (subject_node_id, operator_id, source_root, streak_start, last_seen_at) VALUES (?, ?, ?, ?, ?)'
        ).run(subjectNodeId, opId, opRoot, now, now);
        return;
      }
      const broke = !prev.streak_start || (now - prev.last_seen_at) > OperatorEngine._OBSERVATION_GRACE_MS;
      this._db._db.prepare(
        'UPDATE sov_operator_observation SET operator_id = ?, source_root = COALESCE(?, source_root), streak_start = ?, last_seen_at = ? WHERE subject_node_id = ?'
      ).run(opId, opRoot, broke ? now : prev.streak_start, now, subjectNodeId);
      if (broke) {
        global.sovLog.info('[Operator] observation streak reset for ' + String(subjectNodeId).slice(0, 12)
          + ' (unseen for ' + Math.round((now - prev.last_seen_at) / 60000) + ' min)');
      }
    } catch (err) {
      global.sovLog.warn('[Operator] _observePeerAlive failed: ' + err.message);
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

      // Admission certificate. Rows from before certificates (every node registered up to
      // 1.4.77) have none, and a certificate binds the operator it was issued for — so a
      // missing or out-of-date one is re-earned through the same signed signup. The node
      // keeps serving throughout: its OWN row is untouched; only what peers will accept
      // about it changes.
      if (this._peerMesh.peerCount() > 0 && this._certIsStale(existing)) {
        this._startSignup('recert');
      }
      return;
    }

    // No peers yet. Only a DECLARED genesis (SOV_GENESIS=1) may register alone and mint the
    // network's biometric seed. Any other node is joining a network that already exists: it
    // keeps looking and joins through signed approval, which also hands it the real seed.
    // (Until 1.4.82 any node with no peers at +30 s did this - a desktop node declared itself
    // genesis, minted its own seed, and broke duplicate detection with the fleet.)
    if (this._peerMesh.peerCount() === 0 && !global.sovExplicitGenesis) {
      global.sovLog.info('[Operator] No peers yet - still looking for the network; will try to join again in 60 s (this node is not genesis)');
      if (!this._joinRetry) {
        this._joinRetry = setTimeout(() => { this._joinRetry = null; this._attemptSelfRegistration(); }, 60 * 1000);
        if (this._joinRetry.unref) this._joinRetry.unref();
      }
      return;
    }
    if (this._peerMesh.peerCount() === 0) {
      global.sovLog.info('[Operator] No peers found — registering as the DECLARED genesis node (SOV_GENESIS=1)');
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
      // 'genesis' is a certificate nobody else accepts: once this node has peers it re-certifies
      // like everyone else (see the already-registered branch above).
      this._registerLocally(this._buildSignup(), 'genesis', 'genesis');
      return;
    }

    this._startSignup('join');
  }

  /** This node's Ed25519 public key as hex (the identity holds raw bytes). */
  _pubHex() {
    try { return Buffer.from(this._identity.publicKey).toString('hex'); } catch (_) { return ''; }
  }

  /** A signed signup. node_id is sha256(public_key), and the signature covers exactly this body. */
  _buildSignup() {
    const signup = {
      node_id:              this._identity.nodeId,
      public_key:           this._pubHex(),   // hex — it used to go out as raw bytes
      operator_sovereign_id: String(this._identity.operatorSovereignId || '').trim().toUpperCase(),
      manifest_hash:        '',
      // What source this node is actually running. Peers compare it against the
      // roots that EARNED nodes run — this is the integrity anchor, in place of a
      // founder signature. See docs/NODE_INTEGRITY_DESIGN.md Layer 2.
      source_root:          this._localSourceRoot(),
      stake_seeds:          0,   // King's design: NO join stake — operators earn by proven uptime, not an entry fee.
      hardware_class:       this._detectHardwareClass(),
      timestamp:            Date.now(),
    };
    // The old signature signed `identity.sign(<string>)`, which reaches nacl as an EMPTY array —
    // it proved nothing, and nobody checked it. This one signs the signup itself, and is checked.
    signup.signature = this._identity.signMessage(admission.signupBody(signup)).toString('hex');
    return signup;
  }

  /** Does our own row lack a certificate that peers would accept for what we are now? */
  _certIsStale(row) {
    const raw = String((row && row.admission_cert) || '');
    if (!raw || raw === 'genesis') return true;
    try {
      const cert = JSON.parse(raw);
      const mineOp = String(this._identity.operatorSovereignId || '').trim().toUpperCase();
      if (!Array.isArray(cert) || !cert.length || String(cert[0].operator_id || '') !== mineOp) return true;
      // Earned on a smaller network than this one: newcomers would ask for more approvals than
      // it carries, so earn a bigger one (same cap a receiver applies in _certNeed).
      return cert.length < this._certNeed(this._identity.nodeId);
    } catch (_) { return true; }
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
  // mode 'join'   — not yet registered: nothing is written until the quorum's signed approvals arrive.
  // mode 'recert' — already registered (own row kept); collects a certificate peers will accept.
  _startSignup(mode) {
    if (this._registrationTimer) { clearTimeout(this._registrationTimer); this._registrationTimer = null; }
    const signup     = this._buildSignup();
    const sampleSize = parseInt(this._getGovParam('operator_signup_sample', '5'));
    const peers      = this._peerMesh.peerIds ? this._peerMesh.peerIds() : [];
    const sample     = this._pickRandomPeers(peers, sampleSize);
    if (!sample.length) {
      global.sovLog.info('[Operator] No peers to ask — will retry');
      this._registrationTimer = setTimeout(() => this._attemptSelfRegistration(), 5 * 60 * 1000);
      return;
    }
    // Small networks cannot produce a big quorum, and must still be able to grow.
    // Requiring more approvals than there are peers would wedge the network shut.
    const want = parseInt(this._getGovParam('operator_signup_quorum', '3'));
    this._signup          = signup;
    this._signupMode      = mode;
    this._asked           = new Set(sample);
    this._approvals       = new Map();   // approver node id -> signed approval
    this._rejections      = new Set();
    this._approvalsNeeded = Math.max(1, Math.min(want, sample.length));

    global.sovLog.info(
      `[Operator] ${mode === 'recert' ? 'Re-certifying' : 'Signing up'}: asking ${sample.length} peer(s); ` +
      `${this._approvalsNeeded} signed approval(s) needed`);
    for (const p of sample) this._peerMesh.sendTo(p, 'NODE_OPERATOR_SIGNUP', signup);

    // No quorum within 2 minutes — try again in 5 (a fresh sample, a fresh signup).
    this._registrationTimer = setTimeout(() => {
      const done = mode === 'recert' ? !this._signupMode : this._isRegistered;
      if (!done) {
        global.sovLog.warn(`[Operator] ${mode === 'recert' ? 'Re-certification' : 'Registration'} timed out — retrying in 5 minutes`);
        this._registrationTimer = setTimeout(() => this._attemptSelfRegistration(), 5 * 60 * 1000);
      }
    }, 2 * 60 * 1000);
  }

  // Called when a PEER sends NODE_OPERATOR_SIGNUP — we are the interrogating node
  _handleOperatorSignup(msg, ws) {
    // peer_mesh dispatches handler(msg, ws) — the second argument is the SOCKET.
    // Every reply below goes through peerMesh.sendTo(nodeId, ...), which does
    // _peers.get(nodeId) and therefore needs the ID STRING: passing the socket made
    // _peers.get(ws) undefined, sendTo return false, and NODE_OPERATOR_APPROVED /
    // NODE_OPERATOR_REJECTED never reach the joining node. Every node in this fleet
    // registered through the peerCount()===0 genesis path instead, so the failure was
    // invisible — but it blocks a genuinely JOINING operator, which is exactly what a
    // second operator is. ws._nodeId is the authenticated peer id from the signed HELLO.
    const fromNodeId = (ws && ws._nodeId) ? String(ws._nodeId) : '';
    const {
      node_id, public_key, operator_sovereign_id,
      manifest_hash, manifest_sig,
      stake_seeds, hardware_class, timestamp, signature,
    } = msg;

    if (!node_id || !public_key || !timestamp) {
      global.sovLog.debug(`[Operator] Invalid signup from ${fromNodeId} — missing fields`);
      return;
    }

    // ── Check 0: the signup is from the node it names (D5) ──────────────────
    // A node signs up for ITSELF, over its own socket: node_id must be the peer that sent
    // this, must be sha256(public_key), and the signature must verify over this exact signup.
    // Before, any peer could sign up on behalf of any node id, and the "signature" field
    // signed an empty buffer and was never checked.
    if (String(node_id) !== fromNodeId || !admission.verifySignup(msg)) {
      global.sovLog.warn(`[Operator] Signup for ${String(node_id).slice(0, 12)} from ${fromNodeId.slice(0, 12)} refused — not signed by the node it names`);
      this._rejectNode(String(node_id), fromNodeId, 'SIGNUP_NOT_AUTHENTIC');
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

    // ── Check 2: (no shortcut any more) ─────────────────────────────────────
    // A node we already know used to be approved here on sight, skipping Checks 3 and 6. An
    // approval is now a signed statement other nodes rely on, so every check runs every time;
    // a node we know simply passes them.

    // ── Check 3: Operator is an enrolled citizen ────────────────────────────
    // Unconditional. A well-formed ID that belongs to nobody is still nobody.
    const enrollment = this._db.getEnrollment(opId);
    if (!enrollment) {
      this._rejectNode(node_id, fromNodeId, 'OPERATOR_NOT_ENROLLED');
      return;
    }

    // ── Check 4: Relays beyond the paid tier — INFRASTRUCTURE, NOT REFUSED ──
    // This used to REJECT with OPERATOR_NODE_LIMIT_REACHED, on the stated grounds
    // that the cap was "the only thing stopping one enrolled human from spinning up
    // enough nodes to outvote the rest of the network". That rationale does not
    // hold, and refusing here broke the economics the protocol actually specifies:
    //
    //   - Nodes do not vote. A governance vote is one per CITIZEN, enforced
    //     structurally by PRIMARY KEY (poll_id, voter_id) on sov_poll_votes.
    //     Running more machines yields exactly zero extra votes.
    //   - Release ratification is already defended separately, by
    //     COUNT(DISTINCT operator_id) in _sourceRootAccepted — "one operator, one
    //     voice" — so extra nodes cannot manufacture agreement either.
    //   - The reserve is already defended by the payout tiers below.
    //
    // SOV_OPERATOR_ECONOMY_SPEC §2 (king, 2026-07-19) is explicit that the fourth
    // relay and beyond DO exist and simply earn nothing — "infrastructure credit
    // only" — and that spec never mentions max_nodes_per_operator at all. The cap
    // belongs to PAYOUT, where it is already implemented as _PAYOUT_TIER_RATES
    // [1.00, 0.25, 0.25] with relay 4+ at ×0.00. Refusing registration made that
    // ×0.00 tier unreachable: the node it was written for could never exist.
    //
    // So: register it, and say plainly that it serves without earning.
    const maxNodes = parseInt(this._getGovParam('max_nodes_per_operator', '3'));
    const operatorNodeCount = this._db._db.prepare(
      'SELECT COUNT(*) as cnt FROM sov_operator_registry WHERE operator_id = ? AND status = ? AND node_id != ?'
    ).get(opId, 'active', String(node_id));
    if (operatorNodeCount && operatorNodeCount.cnt >= maxNodes) {
      global.sovLog.info(
        `[Operator] ${node_id.slice(0, 12)}… is relay #${operatorNodeCount.cnt + 1} for ${opId} ` +
        `(paid tiers: ${maxNodes}). Registering as INFRASTRUCTURE CREDIT ONLY — ` +
        `it serves the network and earns nothing.`);
    }

    // ── Check 5: (REMOVED) No join stake — King's design: an operator is paid
    //    for proven uptime (>= 21 continuous days), never charged to enter.

    // ── Check 6: Software the network recognises ────────────────────────────
    // This replaced a founder-key manifest signature. Nobody signs a release into
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

    // ── ALL CHECKS PASSED — send a SIGNED approval; write nothing ───────────
    // D1: this used to INSERT an active row here and broadcast it, so one approver admitted a
    // node. Now the approval goes only to the joining node, signed over exactly what was
    // approved; the node is admitted when it holds a quorum of these and presents them
    // (_handleRegistryBroadcast verifies the certificate).
    global.sovLog.info(`[Operator] Approving node ${String(node_id).slice(0, 12)}... (operator: ${opId}) — signed approval`);
    const approval = admission.makeApproval(this._identity, this._pubHex(), {
      node_id: String(node_id), operator_id: opId, source_root: String(msg.source_root || ''), signup_ts: timestamp,
    });
    this._peerMesh.sendTo(fromNodeId, 'NODE_OPERATOR_APPROVED', {
      node_id,
      approved_by:  this._identity.nodeId,
      timestamp:    Date.now(),
      network_seed: this._networkSeedForApproval(),
      approval,
    });
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

  _handleApproved(msg, ws) {
    const fromNodeId = (ws && ws._nodeId) ? String(ws._nodeId) : '';
    const { node_id, approved_by, network_seed, approval } = msg || {};
    if (node_id !== this._identity.nodeId) return;
    // D3: an approval counts only from the socket of a peer we actually asked, and the approver
    // it names must be that peer. Before, approved_by was taken from the message, so one peer
    // could claim three identities and satisfy a quorum of three on its own.
    if (!this._signupMode || !this._asked || !fromNodeId || !this._asked.has(fromNodeId) ||
        String(approved_by) !== fromNodeId) {
      global.sovLog.debug(`[Operator] Approval ignored — not from a peer we asked (${fromNodeId.slice(0, 12)})`);
      return;
    }

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

    // The approval must be signed by that peer over exactly the signup we sent.
    const su = this._signup;
    const subject = { node_id: su.node_id, operator_id: su.operator_sovereign_id, source_root: su.source_root, signup_ts: su.timestamp };
    if (!approval || approval.approver !== fromNodeId || !admission.verifyApproval(approval, subject)) {
      global.sovLog.warn(`[Operator] Approval from ${fromNodeId.slice(0, 12)} refused — not a valid signed approval of our signup`);
      return;
    }
    this._approvals.set(fromNodeId, approval);
    const need = this._approvalsNeeded || 1;
    if (this._approvals.size < need) {
      global.sovLog.info(`[Operator] Approval ${this._approvals.size}/${need} from ${fromNodeId.slice(0, 12)}...`);
      return;
    }

    // Quorum reached: the certificate is the set of signed approvals.
    this._retryDelayMs = 0;
    const cert = JSON.stringify([...this._approvals.values()]);
    const mode = this._signupMode;
    this._signupMode = null;
    if (this._registrationTimer) { clearTimeout(this._registrationTimer); this._registrationTimer = null; }
    if (mode === 'recert') {
      this._db._db.prepare('UPDATE sov_operator_registry SET admission_cert = ? WHERE node_id = ?')
        .run(cert, this._identity.nodeId);
      global.sovLog.info(`[Operator] ✓ Re-certified by ${this._approvals.size} peer(s)`);
    } else {
      this._isRegistered = true;
      global.sovLog.info(`[Operator] ✓ Registration approved by ${this._approvals.size} peer(s)`);
      this._registerLocally(su, [...this._approvals.keys()].map(k => k.slice(0, 12)).join(','), cert);
    }
    // Now — and only now — the network hears about this node, with its certificate.
    this._broadcastRegistryEntry(this._identity.nodeId);
  }

  _handleRejected(msg, ws) {
    const fromNodeId = (ws && ws._nodeId) ? String(ws._nodeId) : '';
    const { node_id, reason, rejected_by } = msg || {};
    if (node_id !== this._identity.nodeId) return;
    // D4: a rejection counts only from a peer we asked, over its own socket, and only matters
    // while we are signing up. One peer's "no" no longer drops our citizens: the attempt fails
    // only when the remaining peers can no longer reach the quorum.
    if (!this._signupMode || !this._asked || !this._asked.has(fromNodeId) || String(rejected_by) !== fromNodeId) {
      global.sovLog.debug(`[Operator] Rejection ignored — not from a peer we asked (${fromNodeId.slice(0, 12)})`);
      return;
    }
    this._rejections.add(fromNodeId);
    const need = this._approvalsNeeded || 1;
    const stillPossible = this._asked.size - this._rejections.size;
    global.sovLog.warn(`[Operator] ${fromNodeId.slice(0, 12)} declined: ${reason} ` +
      `(${this._rejections.size} declined, ${this._approvals.size}/${need} approved, ${stillPossible} could still approve)`);
    if (stillPossible >= need) return;

    const mode = this._signupMode;
    this._signupMode = null;
    // Retry soon: the usual cause is transient — peers that have not yet synced our operator's
    // enrolment (OPERATOR_NOT_ENROLLED). 1 min, doubling to the 5-minute cap the timeout path uses.
    if (this._registrationTimer) { clearTimeout(this._registrationTimer); this._registrationTimer = null; }
    this._retryDelayMs = Math.min(5 * 60 * 1000, (this._retryDelayMs || 30 * 1000) * 2);
    this._registrationTimer = setTimeout(() => this._attemptSelfRegistration(), this._retryDelayMs);
    if (mode === 'recert') {
      global.sovLog.warn(`[Operator] Re-certification failed this round — this node keeps serving on its own registration; retrying in ${Math.round(this._retryDelayMs / 1000)} s.`);
      return;
    }
    global.sovLog.warn('[Operator] Registration refused by the peers asked. This node is NOT an authorized'
      + ' operator and REFUSES citizen connections (OPERATOR_NOT_AUTHORIZED) until a registration succeeds.');
    global.sovLog.warn('[Operator] Fix: OPERATOR_SOVEREIGN_ID must be an ENROLLED citizen'
      + ' (enrol on the app first), then restart. Also check snap version / source_root.'
      + ` Retrying in ${Math.round(this._retryDelayMs / 1000)} s.`);
    // The gateway enforces this live via OperatorEngine.isAuthorizedToServe() on every
    // new connection; drop any citizen sockets already accepted in the signup window.
    try { if (this._gateway && typeof this._gateway.closeAllCitizens === 'function') this._gateway.closeAllCitizens('OPERATOR_NOT_AUTHORIZED'); } catch (_) {}
  }

  _handleRegistryBroadcast(msg, ws) {
    // Same as above: the second argument is the socket. ws._nodeId is the authenticated peer.
    const fromNodeId = (ws && ws._nodeId) ? String(ws._nodeId) : '';
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
      const p_source_root   = source_root    != null ? String(source_root)   : '';

      if (!Number.isFinite(p_stake))  { /* stake was NaN/Infinity — use 0 */; }
      if (!Number.isFinite(p_reg_at)) { /* registered_at was bad — skip */; return; }

      // ── Admission gate (D2) ─────────────────────────────────────────────────────
      // A row we do not hold is created ONLY with an admission certificate: a quorum of signed
      // approvals from nodes we already know. Before, any admitted peer could broadcast a
      // brand-new row — invented node, invented operator — and it was inserted as given.
      // Rows we already hold are never re-created here; their only updates are the
      // subject-only operator_id / source_root corrections below.
      const known = this._db._db.prepare('SELECT node_id, admission_cert FROM sov_operator_registry WHERE node_id = ?').get(p_node_id);
      const certRaw = msg.admission_cert;
      let cert = null;
      try { cert = typeof certRaw === 'string' ? JSON.parse(certRaw) : certRaw; } catch (_) { cert = null; }
      if (!known) {
        const v = admission.verifyCertificate(cert, { node_id: p_node_id, operator_id: p_operator_id },
          (id) => this._isKnownNode(id, p_node_id), this._certNeed(p_node_id));
        if (!v.ok) {
          // A node announcing ITS OWN row with no certificate at all has simply not earned one yet
          // (a genesis that registered alone - _broadcastRegistryEntry sends '' for its 'genesis'
          // marker - or a row from before certificates). Still refused; it re-earns one as soon as
          // it has peers (onPeerAdmitted, above) and the row arrives again, certified. Expected,
          // so an info line, not a warning. (1.4.83 tested for the literal 'genesis', which the
          // broadcaster never sends, so that branch never fired - fixed 1.4.85.)
          if (!certRaw && fromNodeId === p_node_id && v.reason === 'NO_CERTIFICATE') {
            global.sovLog.info(`[Operator] ${p_node_id.slice(0, 12)} has not earned its admission certificate yet - its entry is accepted once it has`);
            return;
          }
          global.sovLog.warn(`[Operator] Registry entry for ${p_node_id.slice(0, 12)} from ${String(fromNodeId || '?').slice(0, 12)} refused — ${v.reason} (${v.valid} valid approval(s), ${this._certNeed(p_node_id)} needed)`);
          return;
        }
        this._db._db.prepare(`
          INSERT OR IGNORE INTO sov_operator_registry
            (node_id, operator_id, public_key_hex, hardware_class, stake_seeds, registered_at, last_seen_at, status, source_root, admission_cert)
          VALUES (?, ?, ?, ?, ?, ?, ?, 'active', ?, ?)
        `).run(
          p_node_id,
          p_operator_id,
          /^[0-9a-f]{64}$/.test(p_public_key) ? p_public_key : '',
          p_hw_class,
          Number.isFinite(p_stake) ? p_stake : 0,
          p_reg_at,
          Date.now(),
          p_source_root,
          JSON.stringify(cert),
        );
        global.sovLog.info(`[Operator] Registry: admitted ${p_node_id.slice(0, 12)} (${v.valid} signed approval(s))`);
        // A newcomer holds only its own row; answer with ours (certified) so it learns the network now
        // rather than at our next hourly announcement. One message per admitted node.
        try { this._broadcastRegistryEntry(this._identity.nodeId); } catch (_) {}
      } else if (Array.isArray(cert)) {
        // Keep the strongest certificate we have seen for this node: a row from before
        // certificates gets its first one, and a smaller one is replaced once the node
        // re-earns a larger one (1.4.78 kept the FIRST copy for ever - held cosmetic, fixed
        // in 1.4.81). Only a certificate that verifies, and only if it has more valid
        // approvals than the stored one.
        const v = admission.verifyCertificate(cert, { node_id: p_node_id, operator_id: p_operator_id },
          (id) => this._isKnownNode(id, p_node_id), this._certNeed(p_node_id));
        if (v.ok) {
          let storedValid = 0;
          if (known.admission_cert) {
            try {
              const sv = admission.verifyCertificate(JSON.parse(known.admission_cert),
                { node_id: p_node_id, operator_id: p_operator_id },
                (id) => this._isKnownNode(id, p_node_id), 0);
              storedValid = sv.valid || 0;
            } catch (_) { storedValid = 0; }
          }
          if (v.valid > storedValid) {
            this._db._db.prepare('UPDATE sov_operator_registry SET admission_cert = ? WHERE node_id = ?')
              .run(JSON.stringify(cert), p_node_id);
          }
        }
      }

      // source_root replication: INSERT OR IGNORE never touches an EXISTING row, so a
      // node that upgraded its source would stay recorded at its old root on every peer,
      // breaking the earned-quorum ratification. Update it explicitly — but only when the
      // broadcast carries a concrete root, so a node that hasn't computed one yet can never
      // clobber a known-good value with an empty string. The node itself is authoritative
      // for its own source_root (it reconciles then broadcasts), so last-write self-corrects.
      // source_root is MERIT, so it is accepted only from the node it describes.
      // The natural guard `msg.node_id === fromNodeId` on the WHOLE handler would break
      // onboarding, because an approver legitimately announces a newly interrogated
      // node's EXISTENCE (see _broadcastRegistryEntry callers). So the split is:
      // existence from any admitted peer, root only from the subject itself.
      const selfReported = Boolean(fromNodeId) && p_node_id === String(fromNodeId);

      // operator_id DRIFT. INSERT OR IGNORE never touches an existing row and nothing else
      // updated this column, so an operator change on a node NEVER reached its peers: the node
      // itself reconciled locally (see _attemptSelfRegistration) and everyone else stayed on the
      // old owner forever. Measured 2026-09-27 — VPS4 switched to a second operator and reported
      // 2 distinct operators while VPS1 and node-5 still saw 1, which makes a second operator
      // invisible to the release quorum and the whole earned-agreement path unreachable.
      //
      // Accepted only from the subject, like source_root, AND only if the claimed id is an
      // enrolled citizen on THIS node's ledger. Signup Check 3 verifies enrolment once at
      // interrogation; without re-checking here a node could later re-point itself at any id
      // and manufacture a distinct voice. The lookup is local, so it costs nothing.
      // Only a CHANGE needs checking. A claim equal to the operator already on record (usually
      // inserted moments ago, with its admission certificate) changes nothing - and a node that is
      // still receiving the citizen records would otherwise warn about a real citizen it simply has
      // not synced yet (seen on a fresh install's first minute, 2026-10-04).
      let recordedOp = null;
      try { const r = this._db._db.prepare('SELECT operator_id FROM sov_operator_registry WHERE node_id = ?').get(p_node_id); recordedOp = r ? String(r.operator_id || '') : null; } catch (_) {}
      if (selfReported && p_operator_id && recordedOp !== null && recordedOp.toUpperCase() !== p_operator_id.toUpperCase()) {
        let enrolled = null;
        try { enrolled = this._db.getEnrollment ? this._db.getEnrollment(p_operator_id.toUpperCase()) : null; } catch (_) {}
        if (enrolled) {
          this._db._db.prepare(
            'UPDATE sov_operator_registry SET operator_id = ? WHERE node_id = ? AND operator_id != ?'
          ).run(p_operator_id, p_node_id, p_operator_id);
          this._db._db.prepare(
            'UPDATE sov_operator_observation SET operator_id = ? WHERE subject_node_id = ? AND operator_id != ?'
          ).run(p_operator_id, p_node_id, p_operator_id);
        } else {
          global.sovLog.warn('[Operator] operator_id claim from ' + p_node_id.slice(0, 12)
            + ' refused \u2014 ' + p_operator_id.slice(0, 20) + ' is not an enrolled citizen here');
        }
      }
      if (p_source_root && selfReported) {
        this._db._db.prepare(
          'UPDATE sov_operator_registry SET source_root = ? WHERE node_id = ? AND source_root != ?'
        ).run(p_source_root, p_node_id, p_source_root);
        // Mirror it onto the observation, which is what the quorum actually reads.
        this._db._db.prepare(
          'UPDATE sov_operator_observation SET source_root = ? WHERE subject_node_id = ?'
        ).run(p_source_root, p_node_id);
      } else if (p_source_root && !selfReported) {
        global.sovLog.debug('[Operator] source_root for ' + p_node_id.slice(0, 12)
          + ' relayed by ' + String(fromNodeId || 'unknown').slice(0, 12) + ' \u2014 existence kept, root ignored');
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
      // Freshness: an operator that was earned once but has gone dark cannot vouch for
      // software now. Two grace windows, so a single missed hourly proof is not a veto.
      const freshCutoff = Date.now() - 2 * OperatorEngine._OBSERVATION_GRACE_MS;
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
      // READS OBSERVATIONS, NOT CLAIMS. Before this, the same predicate ran against
      // sov_operator_registry — which is replicated, and whose uptime_streak_start is
      // NOT NULL DEFAULT 0. A gossiped row therefore arrived with streak 0, `IS NOT NULL`
      // was always true and `0 <= cutoff` was always true, so ANY fabricated row counted
      // as maximally earned. Two invented operator_ids were enough to forge a quorum of
      // two and have arbitrary software admitted under release_enforce_mode=refuse.
      // The register recorded that fabricated rows "carry no streak"; they carried 0.
      //
      // COUNT(DISTINCT operator_id) and the earned cutoff are kept exactly as they were
      // — one operator one voice, and agreement cannot be spun up by fresh machines.
      // What changed is the source of the evidence.
      const r = this._db._db.prepare(
        `SELECT COUNT(DISTINCT operator_id) AS n FROM sov_operator_observation
          WHERE source_root = ?
            AND operator_id IS NOT NULL AND operator_id != ''
            AND streak_start IS NOT NULL AND streak_start <= ?
            AND last_seen_at >= ?`
      ).get(root, cutoff, freshCutoff);
      agreeing = r ? r.n : 0;
    } catch (_) { /* column may not exist yet on an older node */ }

    const need = parseInt(this._getGovParam('release_dispute_threshold', '2'));
    return { ok: agreeing >= need, reason: agreeing ? 'EARNED_NODES_AGREE' : 'UNRECOGNISED_SOURCE',
             agreeing };
  }

  _registerLocally(signup, approvedBy, cert = '') {
    try {
      this._db._db.prepare(`
        INSERT OR REPLACE INTO sov_operator_registry
          (node_id, operator_id, public_key_hex, manifest_hash, hardware_class,
           stake_seeds, registered_at, last_seen_at, status, source_root, admission_cert)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'active', ?, ?)
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
        String(cert || ''),
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
      // The certificate is what lets a node that does not know this one accept the row.
      admission_cert: row.admission_cert && row.admission_cert !== 'genesis' ? row.admission_cert : '',
    });
  }

  /** Approvals a received certificate must carry: the quorum, capped by how many OTHER nodes we
   *  can see — the same cap a joiner applies to itself, so a small network can still grow. */
  _certNeed(subjectNodeId) {
    const want = parseInt(this._getGovParam('operator_signup_quorum', '3'));
    const peers = (this._peerMesh.peerIds ? this._peerMesh.peerIds() : []).filter(p => p !== subjectNodeId);
    return Math.max(1, Math.min(want, peers.length));
  }

  /** An approver counts only if THIS node already knows it: an active registry row, or a peer
   *  that passed our handshake. Freshly generated keys therefore vouch for nothing. */
  _isKnownNode(nodeId, subjectNodeId) {
    if (!nodeId || nodeId === subjectNodeId) return false;
    if (nodeId === this._identity.nodeId) return true;
    try {
      const r = this._db._db.prepare("SELECT 1 FROM sov_operator_registry WHERE node_id = ? AND status = 'active'").get(nodeId);
      if (r) return true;
    } catch (_) {}
    return !!(this._peerMesh.peerPublicKey && this._peerMesh.peerPublicKey(nodeId));
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  SUBSYSTEM 2 — PROOF OF SERVICE
  // ═══════════════════════════════════════════════════════════════════════════

  _computeProofOfService() {
    if (!this._isRegistered) return;
    // Re-announce our (certified) registry row before the proof: peers accept a proof only from a
    // node they hold a row for, and a peer that missed the first announcement learns it here.
    try { this._broadcastRegistryEntry(this._identity.nodeId); } catch (_) {}
    try {
      const own = this._db._db.prepare('SELECT admission_cert FROM sov_operator_registry WHERE node_id = ?').get(this._identity.nodeId);
      if (own && !this._signupMode && this._peerMesh.peerCount() > 0 && this._certIsStale(own)) this._startSignup('recert');
    } catch (_) {}

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

  _handlePeerProof(msg, ws) {
    // peer_mesh dispatches handler(msg, ws) — the second argument is the SOCKET, not an id.
    // The authenticated sender is ws._nodeId, set from the signed HELLO; every message is
    // signature-verified before it reaches here.
    const fromNodeId = (ws && ws._nodeId) ? String(ws._nodeId) : '';
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

    // OBSERVE — but only when the node is speaking about ITSELF. A proof relayed by a
    // third party is hearsay about merit, and accepting it would rebuild exactly the hole
    // this change closes. fromNodeId is undefined on older peers, so treat that as
    // unverified rather than trusted.
    if (fromNodeId && node_id === fromNodeId) {
      this._observePeerAlive(node_id);
    } else if (fromNodeId) {
      global.sovLog.debug('[Operator] proof about ' + String(node_id).slice(0, 12)
        + ' relayed by ' + String(fromNodeId).slice(0, 12) + ' \u2014 recorded, not observed');
    }
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

  /**
   * Bound sov_proof_of_service_log.
   *
   * FOUND 2026-09-26: this table had NO delete anywhere in the tree — only
   * INSERTs. It was the single monotonically growing table in the schema, already
   * 2,255 rows 32 days after genesis with ONE citizen, and it grows per node per
   * hour, so it scales with the fleet as well as with time. On a 1 GB VPS meant to
   * run untended for years that is the shape of a slow hang.
   *
   * Safe to bound tightly: the only reader is getProofHistory(), which takes at
   * most `limit` (default 24) most-recent epochs, and continuous-uptime streaks are
   * tracked in sov_operator_registry columns — NOT by scanning this log. So nothing
   * computes a payout from deep history. 30 days is already far more than any reader
   * asks for, and unclaimed earnings are deliberately excluded from pruning.
   */
  pruneProofOfServiceLog({ now = Date.now(), keepDays = 30 } = {}) {
    try {
      const cutoff = now - keepDays * 24 * 60 * 60 * 1000;
      const n = this._db._db.prepare(
        'DELETE FROM sov_proof_of_service_log WHERE created_at < ? AND claimed = 1'
      ).run(cutoff).changes;
      // Rows with unclaimed earnings are evidence of money owed — keep them
      // regardless of age, but still drop the zero-earning ones so an idle node
      // cannot accumulate for ever.
      const z = this._db._db.prepare(
        'DELETE FROM sov_proof_of_service_log WHERE created_at < ? AND claimed = 0 AND earned_seeds = 0'
      ).run(cutoff).changes;
      if (n + z > 0 && global.sovLog && global.sovLog.info) {
        global.sovLog.info(`[Operator] pruned ${n + z} proof-of-service rows older than ${keepDays}d`);
      }
      return n + z;
    } catch (e) {
      if (global.sovLog && global.sovLog.warn) {
        global.sovLog.warn(`[Operator] proof-of-service prune skipped: ${e.message}`);
      }
      return 0;
    }
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
  // They verified a release against a FOUNDER key, which the design replaced with
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

  /// How many relays THIS NODE HAS OBSERVED running for [opId], plus its own if
  /// it belongs to that operator.
  ///
  /// GAP 7. The multiplier used to be driven by `sov_operator_registry` row count,
  /// and that is replicated, so it was wrong in two directions at once:
  ///
  ///   * DIVERGENCE (the symptom the register recorded): replication is incomplete,
  ///     so the fleet held 3/2/1 rows for the same operator and each node computed
  ///     a different multiplier — 30/25/20 SOV for identical work, decided by which
  ///     node's timer fired.
  ///   * INFLATION: an operator that legitimately qualifies on one real node could
  ///     inject extra EXISTENCE rows under its own operator_id and ride the tier
  ///     from ×1.00 to the ×1.50 cap. The qualification gate still passed on the
  ///     real node; only the COUNT was fabricated.
  ///
  /// Observations cannot be gossiped (`_observePeerAlive` writes only what this node
  /// watched, and a relayed proof is recorded, not observed), so counting them closes
  /// both. Existence still comes from the registry — relaying existence is sound
  /// because signup is quorum-gated; relaying merit never is.
  ///
  /// TWO DELIBERATE CHOICES, stated because they are judgement and not mechanism:
  ///   1. `+ 1` for this node's own relay. `_observePeerAlive` returns early on self
  ///      (:222), so without this every node under-counts its own operator by exactly
  ///      one and pays itself a smaller multiplier than its peers compute for it.
  ///   2. Freshness. A relay observed long ago but now dark is not earning, so it is
  ///      not counted — using the same window the release quorum uses (2 grace
  ///      periods), rather than inventing a second notion of "recent".
  _observedRelayCount(opId) {
    const freshCutoff = Date.now() - 2 * OperatorEngine._OBSERVATION_GRACE_MS;
    let n = 0;
    try {
      const row = this._db._db.prepare(
        'SELECT COUNT(*) AS cnt FROM sov_operator_observation ' +
        'WHERE operator_id = ? AND streak_start IS NOT NULL AND last_seen_at >= ?'
      ).get(String(opId), freshCutoff);
      n = (row && row.cnt) || 0;
    } catch (_) { n = 0; }
    const mine = String((this._identity && this._identity.operatorSovereignId) || '').trim();
    if (mine && mine === String(opId)) n += 1;
    return n;
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

        // GAP 7: the count comes from what this node OBSERVED, never from the
        // replicated registry. `ops` is still how this operator was discovered —
        // existence is quorum-gated and relayable — but it does not decide money.
        const _relays    = this._observedRelayCount(opId);
        const multiplier = OperatorEngine.tierMultiplier(_relays);
        if (multiplier <= 0) {
          if (ops.length > 0) {
            global.sovLog.info(
              `      [PAYOUT] ${String(opId).slice(0, 12)}… has ${ops.length} registry row(s) ` +
              `but ${_relays} observed relay(s) — nothing paid. A row this node never watched ` +
              `does not earn.`);
          }
          continue;
        }
        if (_relays !== ops.length) {
          global.sovLog.warn(
            `      [PAYOUT] ${String(opId).slice(0, 12)}…: ${ops.length} registry row(s) vs ` +
            `${_relays} observed — paying on the observed count.`);
        }

        // "per confirmed transaction + uptime" (§10.3). tx component is 0 at
        // launch; _confirmedTxCount stays 0 until per-node witness counting lands.
        const txCount = txReward > 0 ? this._confirmedTxCount(opId, periodId) : 0;
        const seeds   = Math.floor(multiplier * (uptimeReward + txReward * txCount));
        if (seeds <= 0) continue;

        entitlements.push({ opId, relays: _relays, multiplier, seeds });
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

        // 1.4.90: pool -> operator as ONE ledger op, exactly once per (operator, period),
        // replicated to every node. If it cannot commit, the payout row is removed so the
        // next run can retry — a recorded payout always means a paid one.
        const pool = this._db.getPool ? this._db.getPool('witness_operator') : null;
        const actualDeducted = Math.min(amount, pool ? (pool.remaining_seeds || 0) : 0);
        const paid = actualDeducted > 0 && this._db.ledger && this._db.ledger.commitSystemOp({
          op_id: `payout:${e.opId}:${periodId}`, kind: 'operator_payout', ref: `${e.opId}:${periodId}`,
          moves: [{ acct: e.opId, d: actualDeducted }],
          pools: [{ pool: 'witness_operator', d: -actualDeducted }],
        });
        if (!paid || !paid.ok) {
          this._db._db.prepare('DELETE FROM sov_operator_payouts WHERE operator_id = ? AND period_id = ?').run(e.opId, periodId);
          global.sovLog.error(`      [PAYOUT] ${e.opId.substring(0, 16)} period ${periodId} NOT paid: ${paid ? paid.error : 'pool empty'}`);
          continue;
        }
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

  /**
   * The most this node is willing to see paid to `opId` for `periodId`, derived ONLY from what
   * it has watched itself and the governance params it holds. 0 means "I would not have paid".
   */
  _payoutEntitlementCeiling(opId, periodId) {
    const uptimeReward = parseInt(this._getGovParam('operator_uptime_reward', '20000000'));
    const txReward     = parseInt(this._getGovParam('operator_tx_reward', '0'));
    if (uptimeReward <= 0 && txReward <= 0) return 0;   // economy switched off by governance

    const minMs  = parseInt(this._getGovParam('operator_min_uptime_days', '21')) * 86400000;
    const now    = Date.now();
    const cutoff = now - minMs;
    const fresh  = now - 90 * 60 * 1000;

    // First-hand evidence: the observations gap 6 introduced. A node writes these from peers it
    // has itself seen alive, so they cannot be spun up by anything a peer says about itself.
    let qualified = false;
    try {
      qualified = !!this._db._db.prepare(
        `SELECT 1 FROM sov_operator_observation
          WHERE operator_id = ? AND streak_start IS NOT NULL
            AND streak_start <= ? AND last_seen_at >= ? LIMIT 1`
      ).get(opId, cutoff, fresh);
    } catch (_) { /* older node without the table */ }

    // A node never observes ITSELF (_observePeerAlive skips self), so its own row is the one
    // piece of first-hand evidence the observation table structurally cannot hold. Without this
    // fallback a single-node operator could never be paid by its own node.
    if (!qualified && this._identity && this._identity.nodeId) {
      try {
        const own = this._db._db.prepare(
          'SELECT operator_id, uptime_streak_start s, last_uptime_tick t FROM sov_operator_registry WHERE node_id = ?'
        ).get(this._identity.nodeId);
        qualified = !!(own && own.operator_id === opId &&
                       own.s && own.s <= cutoff && own.t && own.t >= fresh);
      } catch (_) {}
    }
    if (!qualified) return 0;

    let relays = 0;
    try {
      relays = this._db._db.prepare(
        "SELECT COUNT(*) AS n FROM sov_operator_registry WHERE operator_id = ? AND status = 'active'"
      ).get(opId).n;
    } catch (_) {}
    const multiplier = OperatorEngine.tierMultiplier(relays);   // caps at the tier table's length
    if (multiplier <= 0) return 0;

    const txCount = txReward > 0 ? this._confirmedTxCount(opId, periodId) : 0;
    return Math.floor(multiplier * (uptimeReward + txReward * txCount));
  }

  _refusePayout(msg, code) {
    global.sovLog.warn(
      `      [PAYOUT] DISAGREE ${code} — operator ${String(msg.operator_id).substring(0, 16)} ` +
      `period ${msg.period_id} amount ${(Number(msg.amount_seeds) / 1e6).toFixed(2)} SOV. Since 1.4.90 the ` +
      `credit itself arrives as a ledger op from the paying node and IS applied here (one ledger, not ` +
      `per-node opinions); this line records that this node would not have paid it.`
    );
  }

  /**
   * Peer-broadcast receiver — replicates a payout fired by another node.
   *
   * A payout message may tell this node that a payout HAPPENED. It may never tell it that the
   * payout was DESERVED, or HOW MUCH it was worth. Both are re-derived here from this node's own
   * observations and its own governance params, exactly as `_runMonthlyOperatorPayout` derives
   * them before firing. Same rule as the release quorum: a node may relay what it is told about
   * EXISTENCE, never what it is told about MERIT.
   *
   * What this replaces: the receiver credited `msg.amount_seeds` verbatim after checking only
   * that the field was present. Any peer past the HELLO handshake could mint arbitrary SOV to
   * any id with one message, for any period, without owning a node at all. It also credited the
   * message's figure whether or not the pool deduction succeeded, so an empty reserve minted
   * SOV outright. Both are closed below.
   *
   * ⚠️ A node that refuses diverges from one that paid. That is the correct trade: in normal
   * operation every node holds the same voted params and its own observations of the same mesh,
   * so they agree. When they disagree, the disagreement is exactly the signal — it means a peer
   * paid against a bar this node never accepted, and the ledger should not follow it.
   */
  _handleOperatorPayoutBroadcast(msg, ws) {
    try {
      if (!msg || !msg.operator_id || msg.period_id == null) return;

      // The peer_mesh dispatcher hands the handler (msg, ws); the SOCKET carries the identity
      // the handshake authenticated. Anything in the message body is the sender's own claim.
      if (!(ws && ws._nodeId)) return this._refusePayout(msg, 'UNAUTHENTICATED_SENDER');

      // This period or the one just gone. Without this a peer pre-mints every future period.
      const periodId = Number(msg.period_id);
      const current  = this._currentPayoutPeriod();
      if (!Number.isInteger(periodId) || periodId > current || periodId < current - 1)
        return this._refusePayout(msg, 'PERIOD_OUT_OF_RANGE');

      const ceiling = this._payoutEntitlementCeiling(String(msg.operator_id), periodId);
      if (ceiling <= 0) return this._refusePayout(msg, 'NOT_QUALIFIED_HERE');

      // Pro-rata means a legitimate payout can be SMALLER than the entitlement, never larger.
      const amount = Math.floor(Number(msg.amount_seeds));
      if (!Number.isFinite(amount) || amount <= 0) return this._refusePayout(msg, 'BAD_AMOUNT');
      if (amount > ceiling) return this._refusePayout(msg, 'AMOUNT_ABOVE_ENTITLEMENT');

      const result = this._db._db.prepare(
        'INSERT OR IGNORE INTO sov_operator_payouts (operator_id, period_id, node_count, amount_seeds, fired_at) VALUES (?, ?, ?, ?, ?)'
      ).run(msg.operator_id, periodId, msg.node_count, amount, msg.fired_at);
      if (result.changes !== 1) return;   // already recorded

      // ⚠️ DO NOT DEDUCT FROM THE POOL HERE. The origin node's own deductFromPool already
      // emitted a POOL_DELTA that reaches every peer and applies the exact same figure
      // (PI-13, storage/pool_delta_sync.js). Deducting again here charges the reserve once
      // per node while the operator is credited once.
      //
      // This was not theoretical. The delta ledger recorded it twice on the live mesh:
      //   2026-09-15  a 30 SOV payout produced THREE  -30 SOV deltas (3 nodes) = 90 drawn
      //   2026-09-28  a 20 SOV payout produced FOUR   -20 SOV deltas (4 nodes) = 80 drawn
      // 120 SOV left the reserve without reaching any wallet, and the supply invariant stayed
      // green throughout because it only checks remaining + distributed == allocated, which is
      // true by construction however many times you deduct.
      //
      // pool_delta_sync.js's header names this exact hazard as a LOCKSTEP REQUIREMENT and it
      // was honoured for enrollment (enrollment_engine.js:636, "[PI-13] REMOVED") — the payout
      // path was simply missed. Enrollment's deltas are correct: one per enrolment.
      // 1.4.90: no credit here. The payout is a ledger op (payout:<operator>:<period>) that every
      // node applies exactly once with its pool side; this broadcast now only mirrors the record.
      // Mirror the payment-history record (same deterministic tx_id → the
      // operator sees the payout with its pool source on EVERY node).
      this._recordPayoutTx(msg.operator_id, periodId, msg.node_count || 1, amount);
    } catch (_) {}
  }

}

module.exports = { OperatorEngine };
