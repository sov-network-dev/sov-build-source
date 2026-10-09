'use strict';
// ─────────────────────────────────────────────────────────────────────────────
// ALLOCATION ENGINE — SOV Vault / Inheritance Allocations
// ─────────────────────────────────────────────────────────────────────────────
// Citizens create time-locked allocations (SOV Vault) for beneficiaries.
// Funds are held in escrow until the release date, then claimable by the
// beneficiary using a claim key or via a council review (Stage 2).
//
// Message types handled:
//   ALLOCATION_CREATE       — create a new locked allocation
//   ALLOCATION_LIST         — list own allocations
//   ALLOCATION_CANCEL       — cancel a locked allocation
//   ALLOCATION_CLAIM_STAGE1 — direct claim (claim key + release date reached)
//   ALLOCATION_CLAIM_STAGE2 — council claim (family keys + community review)
//   ALLOCATION_COUNCIL_VOTE — council member casts vote
//   ALLOCATION_MY_COUNCILS  — list councils citizen is part of
// ─────────────────────────────────────────────────────────────────────────────

const crypto = require('crypto');
const nacl   = require('tweetnacl');

// 1.4.94 (D53): the message a claimant signs with the keypair derived from their claim key.
function allocClaimString(claimPubkey, claimantId, ts) {
  return `SOV-ALLOC-CLAIM-v1|${String(claimPubkey).toLowerCase()}|${claimantId}|${ts}`;
}

class AllocationEngine {
  constructor(identity, db, peerMesh) {
    this._identity = identity;
    this._db       = db;
    this._peerMesh = peerMesh || null;
    this._gateway  = null;
    this._initSchema();
    if (this._peerMesh && this._peerMesh.on) {
      this._peerMesh.on('ALLOCATION_BROADCAST',        (m) => this._handleAllocBroadcast(m));
      this._peerMesh.on('ALLOCATION_STATUS_BROADCAST', (m) => this._handleAllocStatusBroadcast(m));
    }
  }

  setGateway(gateway) { this._gateway = gateway; }

  // ── Schema initialisation ──────────────────────────────────────────────────

  _initSchema() {
    try {
      this._db._db.exec(`
        CREATE TABLE IF NOT EXISTS sov_allocations (
          id                         TEXT    PRIMARY KEY,
          citizen_sovereign_id       TEXT    NOT NULL,
          beneficiary_name_hash      TEXT    NOT NULL,
          beneficiary_name_encrypted TEXT    NOT NULL,
          amount_seeds               INTEGER NOT NULL,
          release_date               INTEGER NOT NULL,
          personal_note_encrypted    TEXT,
          claim_key_hash             TEXT    NOT NULL,
          family_key_1_hash          TEXT,
          family_key_1_hint          TEXT,
          family_key_2_hash          TEXT,
          family_key_2_hint          TEXT,
          family_key_3_hash          TEXT,
          family_key_3_hint          TEXT,
          public_statement           TEXT,
          publish_after_years        INTEGER DEFAULT 10,
          status                     TEXT    DEFAULT 'locked',
          published_at               INTEGER,
          claimed_by                 TEXT,
          claimed_at                 INTEGER,
          justice_status             TEXT,
          created_at                 INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_alloc_citizen   ON sov_allocations (citizen_sovereign_id);
        CREATE INDEX IF NOT EXISTS idx_alloc_claim_key ON sov_allocations (claim_key_hash);
        CREATE INDEX IF NOT EXISTS idx_alloc_name_hash ON sov_allocations (beneficiary_name_hash);
        CREATE INDEX IF NOT EXISTS idx_alloc_status    ON sov_allocations (status);

        CREATE TABLE IF NOT EXISTS sov_inheritance_escrow (
          sovereign_id TEXT    PRIMARY KEY,
          locked_seeds INTEGER DEFAULT 0,
          updated_at   INTEGER
        );

        CREATE TABLE IF NOT EXISTS sov_justice_councils (
          id                    INTEGER PRIMARY KEY AUTOINCREMENT,
          allocation_id         TEXT    NOT NULL,
          claimant_sovereign_id TEXT    NOT NULL,
          claimant_statement    TEXT,
          council_members       TEXT,
          votes_approve         INTEGER DEFAULT 0,
          votes_reject          INTEGER DEFAULT 0,
          votes_abstain         INTEGER DEFAULT 0,
          status                TEXT    DEFAULT 'active',
          created_at            INTEGER NOT NULL,
          expires_at            INTEGER NOT NULL,
          resolved_at           INTEGER
        );
        CREATE INDEX IF NOT EXISTS idx_councils_alloc ON sov_justice_councils (allocation_id);

        CREATE TABLE IF NOT EXISTS sov_council_votes (
          id                 INTEGER PRIMARY KEY AUTOINCREMENT,
          council_id         INTEGER NOT NULL,
          voter_sovereign_id TEXT    NOT NULL,
          vote               TEXT    NOT NULL,
          voted_at           INTEGER NOT NULL,
          UNIQUE(council_id, voter_sovereign_id)
        );
        CREATE INDEX IF NOT EXISTS idx_council_votes_council ON sov_council_votes (council_id);
      `);
      try { this._db._db.exec('ALTER TABLE sov_allocations ADD COLUMN claim_pubkey TEXT'); } catch (_) { /* exists */ }
      global.sovLog && global.sovLog.info('[Alloc] Schema ready');
    } catch (e) {
      global.sovLog && global.sovLog.error('[Alloc] Schema init error:', e.message);
    }
  }

  // ── ALLOCATION_CREATE ──────────────────────────────────────────────────────

  async handleCreate(ws, msg) {
    const {
      beneficiary_name_hash, beneficiary_name_encrypted,
      amount_seeds, release_date, claim_pubkey,
      family_key_1_hash, family_key_1_hint,
      family_key_2_hash, family_key_2_hint,
      family_key_3_hash, family_key_3_hint,
      public_statement, publish_after_years,
      personal_note_encrypted,
    } = msg;
    const sovereignId = ws._sovereignId;
    const RESP = 'ALLOCATION_CREATED';
    if (!sovereignId || !beneficiary_name_hash || !beneficiary_name_encrypted ||
        !amount_seeds || !release_date || !claim_pubkey) {
      return this._send(ws, { type: RESP, success: false, error: 'Missing required fields' });
    }
    if (!/^[0-9a-f]{64}$/i.test(claim_pubkey)) {
      return this._send(ws, { type: RESP, success: false, error: 'Invalid claim key' });
    }
    const amt = Math.trunc(Number(amount_seeds));
    if (!(amt > 0)) return this._send(ws, { type: RESP, success: false, error: 'Bad amount' });
    try {
      const disc = this._db.readDisc(sovereignId);
      if (!disc) return this._send(ws, { type: RESP, success: false, error: 'Citizen not found' });
      const allocationId = 'ALLOC-' + crypto.randomBytes(8).toString('hex').toUpperCase();
      const nowSec = Math.floor(Date.now() / 1000);
      // 1.4.94 (D53): the lock is a REAL ledger holding, not a soft counter. The amount leaves the
      // donor's spendable balance now, via an OWNER op (majority-granted, serialised with the donor's
      // own spends), into holding alloc:<id>. Before, balance_seeds was untouched and the donor could
      // still spend the "locked" funds, and the claim took money from the donor's wallet at claim time.
      const locked = await this._db.ledger.commitOwnerOp({
        kind: 'alloc_lock', ref: allocationId, owner: { acct: sovereignId },
        moves: [{ acct: sovereignId, d: -amt }],
        holds: [{ id: 'alloc:' + allocationId, d: amt }],
      });
      if (!locked.ok) {
        return this._send(ws, { type: RESP, success: false,
          error: locked.error === 'LEDGER_INSUFFICIENT' ? 'Insufficient available balance' : locked.error });
      }
      this._db._db.prepare(`
        INSERT INTO sov_allocations
          (id, citizen_sovereign_id, beneficiary_name_hash, beneficiary_name_encrypted,
           amount_seeds, release_date, claim_key_hash, claim_pubkey,
           family_key_1_hash, family_key_1_hint, family_key_2_hash, family_key_2_hint,
           family_key_3_hash, family_key_3_hint,
           public_statement, publish_after_years, personal_note_encrypted, status, created_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
      `).run(
        allocationId, sovereignId, beneficiary_name_hash, beneficiary_name_encrypted,
        amt, release_date, '', claim_pubkey.toLowerCase(),
        family_key_1_hash || null, family_key_1_hint || null,
        family_key_2_hash || null, family_key_2_hint || null,
        family_key_3_hash || null, family_key_3_hint || null,
        public_statement || null, publish_after_years || 10,
        personal_note_encrypted || null, 'locked', nowSec
      );
      this._broadcastAlloc(allocationId);
      global.sovLog && global.sovLog.info(`[Alloc] Created ${allocationId} for ${sovereignId} | ${amt} seeds (holding alloc:${allocationId})`);
      this._send(ws, { type: RESP, success: true, allocation_id: allocationId, timestamp: Date.now() });
    } catch (e) {
      global.sovLog && global.sovLog.error('[Alloc] CREATE error:', e.message);
      this._send(ws, { type: RESP, success: false, error: e.message });
    }
  }

  // 1.4.94 (D53): send an allocation's metadata to peers so every node holds it (money rides the ledger).
  _broadcastAlloc(allocationId) {
    if (!this._peerMesh || !this._peerMesh.broadcast) return;
    const a = this._db._db.prepare('SELECT * FROM sov_allocations WHERE id = ?').get(allocationId);
    if (!a) return;
    this._peerMesh.broadcast('ALLOCATION_BROADCAST', { alloc: a, origin_node: this._identity.nodeId });
  }

  _broadcastAllocStatus(allocationId) {
    if (!this._peerMesh || !this._peerMesh.broadcast) return;
    const a = this._db._db.prepare('SELECT status, claimed_by, claimed_at, justice_status FROM sov_allocations WHERE id = ?').get(allocationId);
    if (!a) return;
    this._peerMesh.broadcast('ALLOCATION_STATUS_BROADCAST',
      { allocation_id: allocationId, status: a.status, claimed_by: a.claimed_by, claimed_at: a.claimed_at, justice_status: a.justice_status, origin_node: this._identity.nodeId });
  }

  _handleAllocBroadcast(msg) {
    if (!msg || !msg.alloc || msg.origin_node === this._identity.nodeId) return;
    const a = msg.alloc;
    if (!a.id || !a.citizen_sovereign_id) return;
    try {
      // Metadata only; INSERT OR IGNORE so a status we already advanced is not reverted. The money is
      // applied by the ledger op that rides separately — nothing here touches a balance or a holding.
      this._db._db.prepare(`
        INSERT OR IGNORE INTO sov_allocations
          (id, citizen_sovereign_id, beneficiary_name_hash, beneficiary_name_encrypted, amount_seeds,
           release_date, claim_key_hash, claim_pubkey, family_key_1_hash, family_key_1_hint,
           family_key_2_hash, family_key_2_hint, family_key_3_hash, family_key_3_hint,
           public_statement, publish_after_years, personal_note_encrypted, status, created_at)
        VALUES (@id,@citizen_sovereign_id,@beneficiary_name_hash,@beneficiary_name_encrypted,@amount_seeds,
           @release_date,@claim_key_hash,@claim_pubkey,@family_key_1_hash,@family_key_1_hint,
           @family_key_2_hash,@family_key_2_hint,@family_key_3_hash,@family_key_3_hint,
           @public_statement,@publish_after_years,@personal_note_encrypted,@status,@created_at)
      `).run({
        id: a.id, citizen_sovereign_id: a.citizen_sovereign_id,
        beneficiary_name_hash: a.beneficiary_name_hash || '', beneficiary_name_encrypted: a.beneficiary_name_encrypted || '',
        amount_seeds: Math.trunc(Number(a.amount_seeds) || 0), release_date: Math.trunc(Number(a.release_date) || 0),
        claim_key_hash: a.claim_key_hash || '', claim_pubkey: a.claim_pubkey || null,
        family_key_1_hash: a.family_key_1_hash || null, family_key_1_hint: a.family_key_1_hint || null,
        family_key_2_hash: a.family_key_2_hash || null, family_key_2_hint: a.family_key_2_hint || null,
        family_key_3_hash: a.family_key_3_hash || null, family_key_3_hint: a.family_key_3_hint || null,
        public_statement: a.public_statement || null, publish_after_years: Math.trunc(Number(a.publish_after_years) || 10),
        personal_note_encrypted: a.personal_note_encrypted || null, status: a.status || 'locked',
        created_at: Math.trunc(Number(a.created_at) || Math.floor(Date.now() / 1000)),
      });
    } catch (e) { global.sovLog && global.sovLog.warn('[Alloc] broadcast apply: ' + e.message); }
  }

  _handleAllocStatusBroadcast(msg) {
    if (!msg || !msg.allocation_id || msg.origin_node === this._identity.nodeId) return;
    try {
      this._db._db.prepare(
        "UPDATE sov_allocations SET status=?, claimed_by=COALESCE(?,claimed_by), claimed_at=COALESCE(?,claimed_at), justice_status=COALESCE(?,justice_status) WHERE id=? AND status NOT IN ('claimed','cancelled')"
      ).run(msg.status || 'locked', msg.claimed_by || null, msg.claimed_at || null, msg.justice_status || null, msg.allocation_id);
    } catch (_) {}
  }

  // 1.4.94 (D53): release a locked allocation's holding to the claimant. ONE system op, at most once
  // per allocation (deterministic id), applied on every node — the money comes from alloc:<id>, which
  // was funded at create time, so a dead or inactive donor's wallet is never touched.
  _releaseAllocation(alloc, claimantId, kind) {
    return this._db.ledger.commitSystemOp({
      op_id: `alloc-claim:${alloc.id}`, kind, ref: String(alloc.id),
      holds: [{ id: 'alloc:' + alloc.id, d: -alloc.amount_seeds }],
      moves: [{ acct: claimantId, d: alloc.amount_seeds }],
    });
  }

  // ── ALLOCATION_LIST ────────────────────────────────────────────────────────

  handleList(ws, msg) {
    const sovereignId = ws._sovereignId || msg.sovereign_id;
    const RESP = 'ALLOCATION_LIST_RESULT';

    if (!sovereignId) return this._send(ws, { type: RESP, success: false, error: 'Missing sovereign_id' });

    try {
      const allocations = this._db._db.prepare(
        'SELECT * FROM sov_allocations WHERE citizen_sovereign_id = ? ORDER BY created_at DESC'
      ).all(sovereignId);

      const escrowRow = this._db._db.prepare(
        'SELECT locked_seeds FROM sov_inheritance_escrow WHERE sovereign_id = ?'
      ).get(sovereignId);

      this._send(ws, {
        type:               RESP,
        success:            true,
        sovereign_id:       sovereignId,
        allocations,
        total_locked_seeds: escrowRow ? (escrowRow.locked_seeds || 0) : 0,
        timestamp:          Date.now(),
      });
    } catch (e) {
      global.sovLog && global.sovLog.error('[Alloc] LIST error:', e.message);
      this._send(ws, { type: RESP, success: false, error: e.message });
    }
  }

  // ── UNCLAIMED_BROADCAST_SEARCH (king 2026-06-04) ────────────────────────────
  // Public unclaimed-vault search: a descendant/executor hashes a family search
  // term and searches MATURED (past publish_after_years) UNCLAIMED allocations.
  // Returns ONLY public locator info (public_statement + family hints + amount +
  // allocation_id) — NEVER the claim key. Perpetual "family can always find+claim".
  handleUnclaimedSearch(ws, msg) {
    const RESP = 'UNCLAIMED_BROADCAST_RESULT';
    const nameHash = msg.name_hash;
    if (!nameHash) return this._send(ws, { type: RESP, success: false, error: 'Missing name_hash', results: [] });
    const YEAR_MS = 365.25 * 24 * 3600 * 1000;
    const now = Date.now();
    try {
      const rows = this._db._db.prepare(`
        SELECT id AS allocation_id, amount_seeds, release_date, created_at, publish_after_years,
               public_statement, family_key_1_hint, family_key_2_hint, family_key_3_hint, status
        FROM sov_allocations
        WHERE status NOT IN ('claimed','cancelled')
          AND (beneficiary_name_hash = ? OR family_key_1_hash = ? OR family_key_2_hash = ? OR family_key_3_hash = ?)
        ORDER BY created_at ASC LIMIT 50
      `).all(nameHash, nameHash, nameHash, nameHash);
      const matured = rows.filter(r => (r.created_at + (r.publish_after_years || 10) * YEAR_MS) <= now);
      this._send(ws, { type: RESP, success: true, results: matured, count: matured.length });
    } catch (e) {
      global.sovLog && global.sovLog.error('[Alloc] UNCLAIMED_SEARCH error:', e.message);
      this._send(ws, { type: RESP, success: false, error: e.message, results: [] });
    }
  }

  // ── ALLOCATION_CANCEL ──────────────────────────────────────────────────────

  async handleCancel(ws, msg) {
    const { allocation_id } = msg;
    const sovereignId = ws._sovereignId;
    const RESP = 'ALLOCATION_CANCELLED';

    if (!sovereignId || !allocation_id) {
      return this._send(ws, { type: RESP, success: false, error: 'Missing fields' });
    }

    try {
      const alloc = this._db._db.prepare('SELECT * FROM sov_allocations WHERE id = ?').get(allocation_id);
      if (!alloc) return this._send(ws, { type: RESP, success: false, error: 'Allocation not found' });
      if (alloc.citizen_sovereign_id !== sovereignId) {
        return this._send(ws, { type: RESP, success: false, error: 'Not your allocation' });
      }
      if (alloc.status !== 'locked') {
        return this._send(ws, { type: RESP, success: false,
          error: `Cannot cancel allocation with status: ${alloc.status}` });
      }

      // 1.4.94 (D53): return the locked holding to the donor — ONE system op, at most once.
      const back = await this._db.ledger.commitSystemOp({
        op_id: `alloc-cancel:${alloc.id}`, kind: 'alloc_cancel', ref: String(alloc.id),
        holds: [{ id: 'alloc:' + alloc.id, d: -alloc.amount_seeds }],
        moves: [{ acct: sovereignId, d: alloc.amount_seeds }],
      });
      if (!back.ok) return this._send(ws, { type: RESP, success: false, error: back.error });
      this._db._db.prepare("UPDATE sov_allocations SET status='cancelled' WHERE id=?").run(allocation_id);
      this._broadcastAllocStatus(allocation_id);
      global.sovLog && global.sovLog.info(`[Alloc] Cancelled ${allocation_id} | ${alloc.amount_seeds} seeds returned to donor`);
      this._send(ws, { type: RESP, success: true, allocation_id, timestamp: Date.now() });
    } catch (e) {
      global.sovLog && global.sovLog.error('[Alloc] CANCEL error:', e.message);
      this._send(ws, { type: RESP, success: false, error: e.message });
    }
  }

  // ── ALLOCATION_CLAIM_STAGE1 (direct claim — claim key + release date) ──────

  async handleClaimStage1(ws, msg) {
    const { allocation_id, claim_pubkey, claim_sig, claim_ts } = msg;
    const claimantId = ws._sovereignId || msg.claimant_id || msg.claimant_sovereign_id || msg.sovereign_id;
    const RESP = 'ALLOCATION_CLAIMED';

    if ((!allocation_id && !claim_pubkey) || !claim_sig || !claim_ts || !claimantId) {
      return this._send(ws, { type: RESP, success: false, error: 'Missing fields' });
    }

    try {
      // The claimant holds only their claim KEY, not the allocation id — so they present the claim
      // PUBLIC key (derived from it) and the node finds the allocation by it. The signature proves
      // possession of the private claim key; the public key leaks nothing.
      const alloc = allocation_id
        ? this._db._db.prepare('SELECT * FROM sov_allocations WHERE id = ?').get(allocation_id)
        : this._db._db.prepare(
            "SELECT * FROM sov_allocations WHERE claim_pubkey = ? AND status NOT IN ('claimed','cancelled')"
          ).get(String(claim_pubkey).toLowerCase());

      if (!alloc) return this._send(ws, { type: RESP, success: false, error: 'Allocation not found' });
      if (alloc.status === 'claimed')    return this._send(ws, { type: RESP, success: false, error: 'Already claimed' });
      if (alloc.status === 'cancelled')  return this._send(ws, { type: RESP, success: false, error: 'Allocation cancelled' });

      const nowSec = Math.floor(Date.now() / 1000);
      if (alloc.release_date > nowSec) {
        const releaseDate = new Date(alloc.release_date * 1000).toISOString().slice(0, 10);
        return this._send(ws, { type: RESP, success: false,
          error: `Release date not reached. Unlocks: ${releaseDate}` });
      }
      // 1.4.94 (D53): prove the claim KEY with a SIGNATURE, not a hash the broadcast exposes. The
      // claimant signs SOV-ALLOC-CLAIM-v1|id|claimant|ts with the keypair derived from the claim key;
      // the allocation stores only the public key, so knowing the (public) pubkey lets no one claim.
      const ts = Math.trunc(Number(claim_ts));
      if (!alloc.claim_pubkey || !/^[0-9a-f]{64}$/i.test(alloc.claim_pubkey)) {
        return this._send(ws, { type: RESP, success: false, error: 'This allocation cannot be claimed by key' });
      }
      if (!Number.isFinite(ts) || Math.abs(Date.now() - ts) > 5 * 60 * 1000) {
        return this._send(ws, { type: RESP, success: false, error: 'Stale claim' });
      }
      let sigOk = false;
      try {
        sigOk = /^[0-9a-f]{128}$/i.test(claim_sig) && nacl.sign.detached.verify(
          Buffer.from(allocClaimString(alloc.claim_pubkey, claimantId, ts), 'utf8'),
          Buffer.from(claim_sig, 'hex'), Buffer.from(alloc.claim_pubkey, 'hex'));
      } catch (_) { sigOk = false; }
      if (!sigOk) return this._send(ws, { type: RESP, success: false, error: 'Invalid claim key' });

      // 1.4.94 (D53): pay the claimant from the allocation's HOLDING (funded at create time) — ONE
      // system op, at most once per allocation, applied on every node. The donor's wallet is not
      // touched (they may be dead or inactive — the whole point of inheritance).
      const moved = await this._releaseAllocation(alloc, claimantId, 'alloc_claim');
      if (!moved.ok) return this._send(ws, { type: RESP, success: false, error: moved.error });

      this._db._db.prepare(
        "UPDATE sov_allocations SET status='claimed', claimed_by=?, claimed_at=? WHERE id=?"
      ).run(claimantId, nowSec, alloc.id);
      this._broadcastAllocStatus(alloc.id);

      try { this._db.computeMerkleRoot(); } catch (_) {}

      global.sovLog && global.sovLog.info(`[Alloc] Stage1 claimed ${alloc.id} by ${claimantId} | ${alloc.amount_seeds} seeds`);
      this._send(ws, {
        type:          RESP,
        success:       true,
        allocation_id: alloc.id,
        claimed_by:    claimantId,
        amount_seeds:  alloc.amount_seeds,
        timestamp:     Date.now(),
      });
    } catch (e) {
      global.sovLog && global.sovLog.error('[Alloc] CLAIM_STAGE1 error:', e.message);
      this._send(ws, { type: RESP, success: false, error: e.message });
    }
  }

  // ── ALLOCATION_CLAIM_STAGE2 (council claim — family keys + community review) ─

  handleClaimStage2(ws, msg) {
    const { allocation_id, family_key_hashes, claimant_statement } = msg;
    const claimantId = ws._sovereignId || msg.sovereign_id || msg.claimant_sovereign_id;
    const RESP = 'ALLOCATION_CLAIM_STAGE2_RESULT';

    if (!allocation_id || !claimantId) {
      return this._send(ws, { type: RESP, success: false, error: 'Missing fields' });
    }

    try {
      const alloc = this._db._db.prepare('SELECT * FROM sov_allocations WHERE id = ?').get(allocation_id);
      if (!alloc) return this._send(ws, { type: RESP, success: false, error: 'Allocation not found' });
      if (alloc.status === 'claimed') return this._send(ws, { type: RESP, success: false, error: 'Already claimed' });

      // Verify family keys (at least one must match)
      const hashes = Array.isArray(family_key_hashes) ? family_key_hashes : [];
      const allAllocHashes = [alloc.family_key_1_hash, alloc.family_key_2_hash, alloc.family_key_3_hash].filter(Boolean);
      if (allAllocHashes.length > 0 && !hashes.some(h => allAllocHashes.includes(h))) {
        return this._send(ws, { type: RESP, success: false, error: 'Family key verification failed' });
      }

      // Select council members — enrolled > 2 years ago, active recently
      const nowMs        = Date.now();
      const twoYearsAgo  = nowMs - (2 * 365 * 24 * 3600000);
      const thirtyDaysAgoSec = Math.floor((nowMs - 30 * 24 * 3600000) / 1000);

      let candidates = this._db._db.prepare(`
        SELECT e.sovereign_id FROM sov_enrollments e
        JOIN sov_disc d ON d.sovereign_id = e.sovereign_id
        WHERE e.enrolled_at < ? AND d.liveness_ts > ?
          AND e.sovereign_id != ? AND e.sovereign_id != ?
        ORDER BY RANDOM() LIMIT 9
      `).all(twoYearsAgo, thirtyDaysAgoSec, claimantId, alloc.citizen_sovereign_id);

      let councilMembers = candidates.map(r => r.sovereign_id);

      // Fallback: use any other enrolled citizens if not enough tenured ones
      if (councilMembers.length < 3) {
        const fallback = this._db._db.prepare(`
          SELECT sovereign_id FROM sov_enrollments
          WHERE sovereign_id != ? AND sovereign_id != ?
          ORDER BY RANDOM() LIMIT 9
        `).all(claimantId, alloc.citizen_sovereign_id);
        councilMembers = fallback.map(r => r.sovereign_id).slice(0, 9);
      }

      const nowSec    = Math.floor(nowMs / 1000);
      const expiresAt = nowSec + (7 * 86400); // 7 days

      const result = this._db._db.prepare(`
        INSERT INTO sov_justice_councils
          (allocation_id, claimant_sovereign_id, claimant_statement, council_members, status, created_at, expires_at)
        VALUES (?,?,?,?,?,?,?)
      `).run(
        allocation_id, claimantId, claimant_statement || null,
        JSON.stringify(councilMembers), 'active', nowSec, expiresAt
      );

      this._db._db.prepare(
        "UPDATE sov_allocations SET status='pending_council', justice_status='council_active' WHERE id=?"
      ).run(allocation_id);

      global.sovLog && global.sovLog.info(`[Alloc] Stage2 council ${result.lastInsertRowid} for ${allocation_id} | ${councilMembers.length} members`);
      this._send(ws, {
        type:         RESP,
        success:      true,
        council_id:   result.lastInsertRowid,
        council_size: councilMembers.length,
        expires_at:   expiresAt,
        allocation_id,
        timestamp:    Date.now(),
      });
    } catch (e) {
      global.sovLog && global.sovLog.error('[Alloc] CLAIM_STAGE2 error:', e.message);
      this._send(ws, { type: RESP, success: false, error: e.message });
    }
  }

  // ── ALLOCATION_COUNCIL_VOTE ────────────────────────────────────────────────

  handleCouncilVote(ws, msg) {
    const { council_id, vote } = msg;
    const voterId = ws._sovereignId || msg.sovereign_id;
    const RESP = 'ALLOCATION_COUNCIL_VOTE_RESULT';

    if (!council_id || !voterId || !['approve', 'reject', 'abstain'].includes(vote)) {
      return this._send(ws, { type: RESP, success: false, error: 'Missing/invalid fields' });
    }

    try {
      const council = this._db._db.prepare('SELECT * FROM sov_justice_councils WHERE id=?').get(council_id);
      if (!council) return this._send(ws, { type: RESP, success: false, error: 'Council not found' });
      if (council.status !== 'active') return this._send(ws, { type: RESP, success: false, error: 'Council not active' });

      const nowSec = Math.floor(Date.now() / 1000);
      if (council.expires_at < nowSec) return this._send(ws, { type: RESP, success: false, error: 'Council expired' });

      const members = JSON.parse(council.council_members || '[]');
      if (!members.includes(voterId)) {
        return this._send(ws, { type: RESP, success: false, error: 'Not a council member' });
      }

      try {
        this._db._db.prepare(
          'INSERT INTO sov_council_votes (council_id, voter_sovereign_id, vote, voted_at) VALUES (?,?,?,?)'
        ).run(council_id, voterId, vote, nowSec);
      } catch (e2) {
        if (e2.message && e2.message.includes('UNIQUE')) {
          return this._send(ws, { type: RESP, success: false, error: 'Already voted' });
        }
        throw e2;
      }

      // Update vote tally
      const col = vote === 'approve' ? 'votes_approve' : vote === 'reject' ? 'votes_reject' : 'votes_abstain';
      this._db._db.prepare(`UPDATE sov_justice_councils SET ${col}=${col}+1 WHERE id=?`).run(council_id);

      const updated = this._db._db.prepare('SELECT * FROM sov_justice_councils WHERE id=?').get(council_id);
      const totalVotes = updated.votes_approve + updated.votes_reject + updated.votes_abstain;
      const approvalFraction = members.length > 0 ? updated.votes_approve / members.length : 0;

      if (totalVotes >= 3 && approvalFraction >= (2 / 3)) {
        try { this._executeCouncilApproval(council_id, updated.allocation_id, updated.claimant_sovereign_id); } catch (_) {}
      }

      this._send(ws, { type: RESP, success: true, council_id, vote, timestamp: Date.now() });
    } catch (e) {
      global.sovLog && global.sovLog.error('[Alloc] COUNCIL_VOTE error:', e.message);
      this._send(ws, { type: RESP, success: false, error: e.message });
    }
  }

  // ── ALLOCATION_MY_COUNCILS ─────────────────────────────────────────────────

  handleMyCouncils(ws, msg) {
    const sovereignId = ws._sovereignId || msg.sovereign_id;
    const RESP = 'ALLOCATION_MY_COUNCILS_RESULT';

    if (!sovereignId) return this._send(ws, { type: RESP, success: false, error: 'Missing sovereign_id' });

    try {
      const asClaimant = this._db._db.prepare(
        "SELECT *, 'claimant' AS role FROM sov_justice_councils WHERE claimant_sovereign_id=? AND status='active'"
      ).all(sovereignId);

      const allActive = this._db._db.prepare(
        "SELECT * FROM sov_justice_councils WHERE status='active'"
      ).all();

      const asMember = allActive
        .filter(c => {
          const members = JSON.parse(c.council_members || '[]');
          return members.includes(sovereignId) && c.claimant_sovereign_id !== sovereignId;
        })
        .map(c => {
          const voted = this._db._db.prepare(
            'SELECT vote FROM sov_council_votes WHERE council_id=? AND voter_sovereign_id=?'
          ).get(c.id, sovereignId);
          return Object.assign({}, c, { role: 'member', is_member: true, has_voted: !!voted });
        });

      const councils = [
        ...asClaimant.map(c => Object.assign({}, c, { is_member: false, has_voted: false })),
        ...asMember,
      ];

      this._send(ws, { type: RESP, success: true, sovereign_id: sovereignId, councils, timestamp: Date.now() });
    } catch (e) {
      global.sovLog && global.sovLog.error('[Alloc] MY_COUNCILS error:', e.message);
      this._send(ws, { type: RESP, success: false, error: e.message });
    }
  }

  // ── Internal: execute approved council claim ──────────────────────────────

  // donor -> claimant, one op on the donor's slot, at most once per allocation.
  async _executeCouncilApproval(councilId, allocationId, claimantId) {
    const alloc = this._db._db.prepare('SELECT * FROM sov_allocations WHERE id=?').get(allocationId);
    if (!alloc || alloc.status === 'claimed' || alloc.status === 'cancelled') return;

    // 1.4.94 (D53): pay from the allocation's holding (funded at create), never the donor's wallet.
    const moved = await this._releaseAllocation(alloc, claimantId, 'alloc_council');
    if (!moved.ok) { global.sovLog && global.sovLog.error(`[Alloc] council ${councilId}: not paid: ${moved.error}`); return; }

    const nowSec = Math.floor(Date.now() / 1000);
    this._db._db.prepare(
      "UPDATE sov_allocations SET status='claimed', claimed_by=?, claimed_at=?, justice_status='council_approved' WHERE id=?"
    ).run(claimantId, nowSec, allocationId);
    this._broadcastAllocStatus(allocationId);
    this._db._db.prepare(
      "UPDATE sov_justice_councils SET status='approved', resolved_at=? WHERE id=?"
    ).run(nowSec, councilId);

    try { this._db.computeMerkleRoot(); } catch (_) {}
    global.sovLog && global.sovLog.info(`[Alloc] Council ${councilId} approved — ${alloc.amount_seeds} seeds to ${claimantId}`);
  }

  // ── Helper ─────────────────────────────────────────────────────────────────

  _send(ws, payload) {
    if (ws.readyState === 1) ws.send(JSON.stringify(payload));
  }
}

module.exports = { AllocationEngine };
