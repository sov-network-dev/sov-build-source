'use strict';
/**
 * Witness Signer Engine — PI-37 Failsafe Bootstrap.
 *
 * The protocol signs its own releases. There is no founder key past genesis and no
 * standing committee: the network elects N witness signers, any `threshold` of whom
 * can co-sign a release, and it re-elects them automatically if they ever go silent.
 *
 * This module owns the two triggers and the election that follows them. It does not
 * produce signatures — `release/release_signer.js` already implements the envelope
 * and threshold verification. What was missing was anything to decide WHO the
 * trusted signers are; that is what `activeSignerPubkeys()` answers.
 *
 * Trigger 1 (normal transition):  citizens >= phase2_min_citizens
 *                             AND operators >= phase2_min_operators
 * Trigger 2 (emergency):          no signed release for phase2_emergency_inactivity_days
 *                             AND citizens >= phase2_emergency_min_citizens
 *
 * Trigger 2 is deliberately recursive: it fires whenever releases go stale, whether
 * that is because the genesis anchor went quiet or because an elected signer set
 * did. The same mechanism therefore recovers from every "everyone disappeared"
 * case without anyone having to intervene.
 *
 * Below phase2_emergency_min_citizens the network intentionally freezes at its last
 * signed release rather than let a handful of accounts seize the signing power.
 * That trade is the king's design decision, documented in PI-37.
 */

const DAY_MS = 24 * 60 * 60 * 1000;

class WitnessEngine {
  /**
   * @param db          NodeDB instance (uses db._db for raw SQL, same as sibling engines)
   * @param getGovParam fn(key, fallback) -> string   (governance params are ALWAYS strings)
   */
  constructor(db, getGovParam) {
    this._db = db;
    this._getGovParam = getGovParam;
    this._initTables();
  }

  _initTables() {
    const d = this._db._db;
    d.exec(`
      CREATE TABLE IF NOT EXISTS sov_witness_elections (
        election_id   TEXT PRIMARY KEY,
        trigger_type  TEXT NOT NULL,          -- 'normal' | 'emergency'
        opened_at     INTEGER NOT NULL,
        closes_at     INTEGER NOT NULL,
        closed_at     INTEGER,
        status        TEXT NOT NULL DEFAULT 'open',   -- open | closed | void
        quorum_pct    REAL NOT NULL,
        eligible_at_open INTEGER NOT NULL      -- enrolled citizens when opened (quorum base)
      );
      CREATE TABLE IF NOT EXISTS sov_witness_votes (
        election_id   TEXT NOT NULL,
        voter_id      TEXT NOT NULL,
        candidate_id  TEXT NOT NULL,
        voted_at      INTEGER NOT NULL,
        PRIMARY KEY (election_id, voter_id)     -- one citizen, one vote
      );
      CREATE TABLE IF NOT EXISTS sov_witness_signers (
        signer_id     TEXT PRIMARY KEY,         -- Sovereign ID of the elected citizen
        pubkey_hex    TEXT NOT NULL,
        election_id   TEXT NOT NULL,
        elected_at    INTEGER NOT NULL,
        term_ends_at  INTEGER NOT NULL,
        status        TEXT NOT NULL DEFAULT 'active'  -- active | retired | removed
      );
      CREATE TABLE IF NOT EXISTS sov_release_log (
        manifest_hash TEXT PRIMARY KEY,
        signed_at     INTEGER NOT NULL,
        signer_count  INTEGER NOT NULL
      );
    `);
  }

  // ── Governance-param helpers (params are strings — never trust them as numbers) ──
  _num(key, fallback) {
    const v = this._getGovParam(key, String(fallback));
    const n = Number(v);
    return Number.isFinite(n) ? n : Number(fallback);
  }

  signerCount()     { return this._num('witness_signer_count', 5); }
  threshold()       { return this._num('witness_signer_threshold', 3); }
  termDays()        { return this._num('witness_signer_term_days', 365); }

  // ── Facts the triggers depend on ──────────────────────────────────────────
  /** Epoch ms of the most recent signed release, or null if none was ever signed. */
  lastSignedReleaseAt() {
    const r = this._db._db
      .prepare('SELECT MAX(signed_at) AS t FROM sov_release_log').get();
    return r && r.t ? Number(r.t) : null;
  }

  /** Signers whose term has not expired and who were not removed. */
  activeSigners(now = Date.now()) {
    return this._db._db.prepare(
      `SELECT signer_id, pubkey_hex, term_ends_at FROM sov_witness_signers
        WHERE status = 'active' AND term_ends_at > ?`
    ).all(now);
  }

  /** The trust anchor `release_signer.verifyManifest()` should be given. */
  activeSignerPubkeys(now = Date.now()) {
    return this.activeSigners(now).map(s => s.pubkey_hex);
  }

  /** Phase 1 = still on the genesis anchor. Phase 2 = the network signs for itself. */
  phase(now = Date.now()) {
    return this.activeSigners(now).length >= this.threshold() ? 2 : 1;
  }

  // ── The two triggers ──────────────────────────────────────────────────────
  /**
   * Pure decision function. Takes the world as arguments so it can be tested
   * without a live network, which is what PI-37's verify steps require.
   *
   * @returns {{fire:boolean, trigger:('normal'|'emergency'|null), reason:string}}
   */
  evaluateTriggers({ now, citizenCount, operatorCount, lastReleaseAt, activeSignerCount }) {
    const threshold = this.threshold();

    // An election is pointless while a healthy signer set is already seated.
    if (activeSignerCount >= threshold) {
      // ...unless releases have gone stale, in which case Trigger 2 still applies
      // recursively — this is how the protocol recovers from signers going silent.
      const staleDays = lastReleaseAt == null
        ? Infinity
        : (now - lastReleaseAt) / DAY_MS;
      const inactivityLimit = this._num('phase2_emergency_inactivity_days', 180);
      const emergencyFloor  = this._num('phase2_emergency_min_citizens', 100);
      if (staleDays >= inactivityLimit && citizenCount >= emergencyFloor) {
        return { fire: true, trigger: 'emergency', reason:
          `seated signers have shipped nothing for ${Math.floor(staleDays)}d ` +
          `(limit ${inactivityLimit}d) with ${citizenCount} citizens` };
      }
      return { fire: false, trigger: null, reason: 'signer set seated and releases current' };
    }

    // Trigger 1 — the normal transition off the genesis anchor.
    const minCitizens  = this._num('phase2_min_citizens', 1000);
    const minOperators = this._num('phase2_min_operators', 5);
    if (citizenCount >= minCitizens && operatorCount >= minOperators) {
      return { fire: true, trigger: 'normal', reason:
        `${citizenCount} citizens (>= ${minCitizens}) and ` +
        `${operatorCount} operators (>= ${minOperators})` };
    }

    // Trigger 2 — emergency, for when the anchor goes quiet before Trigger 1 is met.
    const inactivityLimit = this._num('phase2_emergency_inactivity_days', 180);
    const emergencyFloor  = this._num('phase2_emergency_min_citizens', 100);
    const staleDays = lastReleaseAt == null ? Infinity : (now - lastReleaseAt) / DAY_MS;
    if (staleDays >= inactivityLimit && citizenCount >= emergencyFloor) {
      return { fire: true, trigger: 'emergency', reason:
        `no signed release for ${staleDays === Infinity ? 'ever' : Math.floor(staleDays) + 'd'} ` +
        `(limit ${inactivityLimit}d) with ${citizenCount} citizens (>= ${emergencyFloor})` };
    }

    // Neither fired. Below the emergency floor this is the deliberate freeze.
    const why = citizenCount < emergencyFloor
      ? `network too small to elect signers (${citizenCount} < ${emergencyFloor}) — ` +
        'frozen at last signed release by design'
      : `waiting: ${citizenCount}/${minCitizens} citizens, ${operatorCount}/${minOperators} operators`;
    return { fire: false, trigger: null, reason: why };
  }

  // ── Election lifecycle ────────────────────────────────────────────────────
  openElection({ trigger, now = Date.now(), eligibleCitizens, durationDays = 7 }) {
    const existing = this._db._db
      .prepare("SELECT election_id FROM sov_witness_elections WHERE status = 'open'").get();
    if (existing) return { ok: false, reason: 'ELECTION_ALREADY_OPEN', election_id: existing.election_id };

    const id = 'WE-' + now.toString(36).toUpperCase();
    const quorum = trigger === 'emergency'
      ? this._num('phase2_emergency_quorum_pct', 0.05)
      : this._num('quorum_threshold', 0.10);

    this._db._db.prepare(
      `INSERT INTO sov_witness_elections
         (election_id, trigger_type, opened_at, closes_at, status, quorum_pct, eligible_at_open)
       VALUES (?, ?, ?, ?, 'open', ?, ?)`
    ).run(id, trigger, now, now + durationDays * DAY_MS, quorum, eligibleCitizens);

    return { ok: true, election_id: id, quorum_pct: quorum, closes_at: now + durationDays * DAY_MS };
  }

  castVote({ electionId, voterId, candidateId, now = Date.now() }) {
    const e = this._db._db
      .prepare("SELECT * FROM sov_witness_elections WHERE election_id = ? AND status = 'open'")
      .get(electionId);
    if (!e) return { ok: false, reason: 'NO_OPEN_ELECTION' };
    if (now > e.closes_at) return { ok: false, reason: 'ELECTION_CLOSED' };

    // One citizen, one vote — enforced by the primary key, surfaced as a clear reason.
    try {
      this._db._db.prepare(
        'INSERT INTO sov_witness_votes (election_id, voter_id, candidate_id, voted_at) VALUES (?,?,?,?)'
      ).run(electionId, voterId, candidateId, now);
    } catch (err) {
      return { ok: false, reason: 'ALREADY_VOTED' };
    }
    return { ok: true };
  }

  /**
   * Tally, check quorum, seat the top `witness_signer_count` candidates.
   * Fails closed: if quorum is not met the election is voided and the previous
   * signer set (if any) stays in place — a low-turnout vote must never be able to
   * hand signing power to a handful of accounts.
   */
  closeElection({ electionId, now = Date.now(), pubkeyFor }) {
    const e = this._db._db
      .prepare("SELECT * FROM sov_witness_elections WHERE election_id = ?").get(electionId);
    if (!e) return { ok: false, reason: 'NO_SUCH_ELECTION' };
    if (e.status !== 'open') return { ok: false, reason: 'ALREADY_CLOSED' };

    const votes = this._db._db.prepare(
      `SELECT candidate_id, COUNT(*) AS n FROM sov_witness_votes
        WHERE election_id = ? GROUP BY candidate_id ORDER BY n DESC, candidate_id ASC`
    ).all(electionId);

    const cast = votes.reduce((a, v) => a + v.n, 0);
    const needed = Math.ceil(e.eligible_at_open * e.quorum_pct);

    if (cast < needed) {
      this._db._db.prepare(
        "UPDATE sov_witness_elections SET status='void', closed_at=? WHERE election_id=?"
      ).run(now, electionId);
      return { ok: false, reason: 'QUORUM_NOT_MET', cast, needed };
    }

    const seats = this.signerCount();
    const winners = votes.slice(0, seats);
    const termEnds = now + this.termDays() * DAY_MS;

    const d = this._db._db;
    const seat = d.transaction(() => {
      // Retire the outgoing set first so `activeSigners()` can never briefly
      // report both cohorts at once.
      d.prepare("UPDATE sov_witness_signers SET status='retired' WHERE status='active'").run();
      for (const w of winners) {
        d.prepare(
          `INSERT OR REPLACE INTO sov_witness_signers
             (signer_id, pubkey_hex, election_id, elected_at, term_ends_at, status)
           VALUES (?,?,?,?,?,'active')`
        ).run(w.candidate_id, pubkeyFor(w.candidate_id) || '', electionId, now, termEnds);
      }
      d.prepare(
        "UPDATE sov_witness_elections SET status='closed', closed_at=? WHERE election_id=?"
      ).run(now, electionId);
    });
    seat();

    return {
      ok: true,
      seated: winners.map(w => ({ signer_id: w.candidate_id, votes: w.n })),
      threshold: this.threshold(),
      term_ends_at: termEnds,
      cast, needed,
    };
  }

  /** Governance removing a rogue signer (PI-37 scenario 5). */
  removeSigner(signerId, now = Date.now()) {
    const r = this._db._db.prepare(
      "UPDATE sov_witness_signers SET status='removed' WHERE signer_id=? AND status='active'"
    ).run(signerId);
    return { ok: r.changes > 0, remaining: this.activeSigners(now).length };
  }

  /** Record a release the signers actually shipped — this is what Trigger 2 watches. */
  recordSignedRelease({ manifestHash, signerCount, now = Date.now() }) {
    this._db._db.prepare(
      'INSERT OR REPLACE INTO sov_release_log (manifest_hash, signed_at, signer_count) VALUES (?,?,?)'
    ).run(manifestHash, now, signerCount);
  }
}

module.exports = { WitnessEngine, DAY_MS };
