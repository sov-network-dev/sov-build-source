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

class AllocationEngine {
  constructor(identity, db) {
    this._identity = identity;
    this._db       = db;
    this._gateway  = null;
    this._initSchema();
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
      global.sovLog && global.sovLog.info('[Alloc] Schema ready');
    } catch (e) {
      global.sovLog && global.sovLog.error('[Alloc] Schema init error:', e.message);
    }
  }

  // ── ALLOCATION_CREATE ──────────────────────────────────────────────────────

  handleCreate(ws, msg) {
    const {
      beneficiary_name_hash, beneficiary_name_encrypted,
      amount_seeds, release_date, claim_key_hash,
      family_key_1_hash, family_key_1_hint,
      family_key_2_hash, family_key_2_hint,
      family_key_3_hash, family_key_3_hint,
      public_statement, publish_after_years,
      personal_note_encrypted,
    } = msg;
    const sovereignId = ws._sovereignId;
    const RESP = 'ALLOCATION_CREATED';

    if (!sovereignId || !beneficiary_name_hash || !beneficiary_name_encrypted ||
        !amount_seeds || !release_date || !claim_key_hash) {
      return this._send(ws, { type: RESP, success: false, error: 'Missing required fields' });
    }

    try {
      const disc = this._db.readDisc(sovereignId);
      if (!disc) return this._send(ws, { type: RESP, success: false, error: 'Citizen not found' });

      const escrowRow   = this._db._db.prepare('SELECT locked_seeds FROM sov_inheritance_escrow WHERE sovereign_id = ?').get(sovereignId);
      const alreadyLocked = escrowRow ? (escrowRow.locked_seeds || 0) : 0;
      const available   = disc.balance_seeds - alreadyLocked;

      if (amount_seeds > available) {
        return this._send(ws, { type: RESP, success: false,
          error: `Insufficient available balance. Available: ${available} seeds` });
      }

      const allocationId = 'ALLOC-' + crypto.randomBytes(8).toString('hex').toUpperCase();
      const nowSec = Math.floor(Date.now() / 1000);

      this._db._db.prepare(`
        INSERT INTO sov_allocations
          (id, citizen_sovereign_id, beneficiary_name_hash, beneficiary_name_encrypted,
           amount_seeds, release_date, claim_key_hash,
           family_key_1_hash, family_key_1_hint, family_key_2_hash, family_key_2_hint,
           family_key_3_hash, family_key_3_hint,
           public_statement, publish_after_years, personal_note_encrypted, status, created_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
      `).run(
        allocationId, sovereignId, beneficiary_name_hash, beneficiary_name_encrypted,
        amount_seeds, release_date, claim_key_hash,
        family_key_1_hash || null, family_key_1_hint || null,
        family_key_2_hash || null, family_key_2_hint || null,
        family_key_3_hash || null, family_key_3_hint || null,
        public_statement || null, publish_after_years || 10,
        personal_note_encrypted || null, 'locked', nowSec
      );

      // Update inheritance escrow (upsert)
      this._db._db.prepare(`
        INSERT INTO sov_inheritance_escrow (sovereign_id, locked_seeds, updated_at) VALUES (?,?,?)
        ON CONFLICT(sovereign_id) DO UPDATE SET
          locked_seeds = locked_seeds + excluded.locked_seeds,
          updated_at   = excluded.updated_at
      `).run(sovereignId, amount_seeds, nowSec);

      global.sovLog && global.sovLog.info(`[Alloc] Created ${allocationId} for ${sovereignId} | ${amount_seeds} seeds`);
      this._send(ws, { type: RESP, success: true, allocation_id: allocationId, timestamp: Date.now() });
    } catch (e) {
      global.sovLog && global.sovLog.error('[Alloc] CREATE error:', e.message);
      this._send(ws, { type: RESP, success: false, error: e.message });
    }
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

  handleCancel(ws, msg) {
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

      const nowSec = Math.floor(Date.now() / 1000);
      this._db._db.prepare("UPDATE sov_allocations SET status='cancelled' WHERE id=?").run(allocation_id);
      this._db._db.prepare(
        'UPDATE sov_inheritance_escrow SET locked_seeds=MAX(0,locked_seeds-?), updated_at=? WHERE sovereign_id=?'
      ).run(alloc.amount_seeds, nowSec, sovereignId);

      global.sovLog && global.sovLog.info(`[Alloc] Cancelled ${allocation_id} | ${alloc.amount_seeds} seeds unlocked`);
      this._send(ws, { type: RESP, success: true, allocation_id, timestamp: Date.now() });
    } catch (e) {
      global.sovLog && global.sovLog.error('[Alloc] CANCEL error:', e.message);
      this._send(ws, { type: RESP, success: false, error: e.message });
    }
  }

  // ── ALLOCATION_CLAIM_STAGE1 (direct claim — claim key + release date) ──────

  handleClaimStage1(ws, msg) {
    const { allocation_id, claim_key_hash } = msg;
    const claimantId = ws._sovereignId || msg.claimant_id || msg.claimant_sovereign_id || msg.sovereign_id;
    const RESP = 'ALLOCATION_CLAIMED';

    if (!claim_key_hash || !claimantId) {
      return this._send(ws, { type: RESP, success: false, error: 'Missing fields' });
    }

    try {
      const alloc = allocation_id
        ? this._db._db.prepare('SELECT * FROM sov_allocations WHERE id = ?').get(allocation_id)
        : this._db._db.prepare(
            "SELECT * FROM sov_allocations WHERE claim_key_hash = ? AND status NOT IN ('claimed','cancelled')"
          ).get(claim_key_hash);

      if (!alloc) return this._send(ws, { type: RESP, success: false, error: 'Allocation not found' });
      if (alloc.status === 'claimed')    return this._send(ws, { type: RESP, success: false, error: 'Already claimed' });
      if (alloc.status === 'cancelled')  return this._send(ws, { type: RESP, success: false, error: 'Allocation cancelled' });

      const nowSec = Math.floor(Date.now() / 1000);
      if (alloc.release_date > nowSec) {
        const releaseDate = new Date(alloc.release_date * 1000).toISOString().slice(0, 10);
        return this._send(ws, { type: RESP, success: false,
          error: `Release date not reached. Unlocks: ${releaseDate}` });
      }
      if (alloc.claim_key_hash !== claim_key_hash) {
        return this._send(ws, { type: RESP, success: false, error: 'Invalid claim key' });
      }

      // Transfer funds from donor to claimant
      const donorDisc = this._db.readDisc(alloc.citizen_sovereign_id);
      if (!donorDisc) return this._send(ws, { type: RESP, success: false, error: 'Donor account not found' });
      if (donorDisc.balance_seeds < alloc.amount_seeds) {
        return this._send(ws, { type: RESP, success: false, error: 'Insufficient donor balance' });
      }

      // Deduct from donor (writeDiscGuarded with retry)
      let deducted = false;
      for (let i = 0; i < 3; i++) {
        const fresh = this._db.readDisc(alloc.citizen_sovereign_id);
        if (!fresh || fresh.balance_seeds < alloc.amount_seeds) break;
        const ok = this._db.writeDiscGuarded(
          alloc.citizen_sovereign_id,
          fresh.balance_seeds   - alloc.amount_seeds,
          Math.max(0, fresh.spendable_seeds - alloc.amount_seeds),
          fresh.version
        );
        if (ok) { deducted = true; break; }
      }
      if (!deducted) return this._send(ws, { type: RESP, success: false, error: 'Failed to deduct donor balance' });

      // Credit claimant (ensure disc entry exists)
      this._db.ensureDiscEntry(claimantId);
      this._db.creditBalance(claimantId, alloc.amount_seeds);

      this._db._db.prepare(
        "UPDATE sov_allocations SET status='claimed', claimed_by=?, claimed_at=? WHERE id=?"
      ).run(claimantId, nowSec, alloc.id);
      this._db._db.prepare(
        'UPDATE sov_inheritance_escrow SET locked_seeds=MAX(0,locked_seeds-?), updated_at=? WHERE sovereign_id=?'
      ).run(alloc.amount_seeds, nowSec, alloc.citizen_sovereign_id);

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

  _executeCouncilApproval(councilId, allocationId, claimantId) {
    const alloc = this._db._db.prepare('SELECT * FROM sov_allocations WHERE id=?').get(allocationId);
    if (!alloc || alloc.status === 'claimed') return;

    const donorDisc = this._db.readDisc(alloc.citizen_sovereign_id);
    if (!donorDisc || donorDisc.balance_seeds < alloc.amount_seeds) return;

    let deducted = false;
    for (let i = 0; i < 3; i++) {
      const fresh = this._db.readDisc(alloc.citizen_sovereign_id);
      if (!fresh || fresh.balance_seeds < alloc.amount_seeds) break;
      const ok = this._db.writeDiscGuarded(
        alloc.citizen_sovereign_id,
        fresh.balance_seeds   - alloc.amount_seeds,
        Math.max(0, fresh.spendable_seeds - alloc.amount_seeds),
        fresh.version
      );
      if (ok) { deducted = true; break; }
    }
    if (!deducted) return;

    this._db.ensureDiscEntry(claimantId);
    this._db.creditBalance(claimantId, alloc.amount_seeds);

    const nowSec = Math.floor(Date.now() / 1000);
    this._db._db.prepare(
      "UPDATE sov_allocations SET status='claimed', claimed_by=?, claimed_at=?, justice_status='council_approved' WHERE id=?"
    ).run(claimantId, nowSec, allocationId);
    this._db._db.prepare(
      'UPDATE sov_inheritance_escrow SET locked_seeds=MAX(0,locked_seeds-?), updated_at=? WHERE sovereign_id=?'
    ).run(alloc.amount_seeds, nowSec, alloc.citizen_sovereign_id);
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
