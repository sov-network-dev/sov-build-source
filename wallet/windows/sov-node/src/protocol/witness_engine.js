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

// Anti-entropy runs hourly (`db.js _startMaintenance`). Nothing in an election may be
// decided until replicated state has had time to converge, so both the open and the
// close wait this long past their window boundary. Two hours = two full cycles.
const SETTLE_MS = 2 * 60 * 60 * 1000;

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
      CREATE TABLE IF NOT EXISTS sov_witness_candidates (
        election_id   TEXT NOT NULL,
        candidate_id  TEXT NOT NULL,          -- Sovereign ID of a citizen who STOOD
        pubkey_hex    TEXT NOT NULL,          -- captured at nomination, not at seating
        stood_at      INTEGER NOT NULL,
        PRIMARY KEY (election_id, candidate_id)
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
  /**
   * Open an election for the CURRENT period, deterministically.
   *
   * WHY DETERMINISTIC: every node runs this independently. The original derived
   * `election_id` from `Date.now()`, so two nodes opening seconds apart created two
   * DIFFERENT elections and the mesh would seat two cohorts — a permanent fork of the
   * trust anchor, in the one subsystem where disagreement is fatal.
   *
   * Instead the timeline is cut into fixed windows of `durationDays`. Every node
   * computes the same window, hence the same `election_id`, `opened_at` and
   * `closes_at` — so a peer's INSERT collides on the primary key and is ignored
   * rather than forking. No leader election is needed.
   *
   * The SETTLE_MS guard removes the only remaining race: a node ticking just before a
   * window boundary and another just after would compute different windows. Neither
   * opens until the window is SETTLE_MS old, by which point every node's clock agrees
   * which window it is in.
   */
  openElection({ trigger, now = Date.now(), eligibleCitizens, durationDays = 7 }) {
    const existing = this._db._db
      .prepare("SELECT election_id FROM sov_witness_elections WHERE status = 'open'").get();
    if (existing) return { ok: false, reason: 'ELECTION_ALREADY_OPEN', election_id: existing.election_id };

    const periodMs    = Math.max(1, durationDays) * DAY_MS;
    const windowStart = Math.floor(now / periodMs) * periodMs;
    if (now - windowStart < SETTLE_MS) {
      return { ok: false, reason: 'WINDOW_TOO_YOUNG', retry_after: windowStart + SETTLE_MS };
    }
    const id      = 'WE-' + Math.floor(now / periodMs).toString(36).toUpperCase();
    const closesAt = windowStart + periodMs;
    const quorum  = trigger === 'emergency'
      ? this._num('phase2_emergency_quorum_pct', 0.05)
      : this._num('quorum_threshold', 0.10);

    // INSERT OR IGNORE, not INSERT: a peer may already have replicated this exact
    // row. Colliding is the mechanism working, not an error.
    const r = this._db._db.prepare(
      `INSERT OR IGNORE INTO sov_witness_elections
         (election_id, trigger_type, opened_at, closes_at, status, quorum_pct, eligible_at_open)
       VALUES (?, ?, ?, ?, 'open', ?, ?)`
    ).run(id, trigger, windowStart, closesAt, quorum, eligibleCitizens);

    return { ok: true, election_id: id, quorum_pct: quorum, closes_at: closesAt,
             created: r.changes > 0 };
  }

  /**
   * Stand as a candidate. Nomination is EXPLICIT and OPT-IN: without it `castVote`
   * accepted any string, so a citizen could be seated as a signer without ever
   * agreeing, and an unenrolled id could be seated with an empty public key.
   * The pubkey is captured HERE, so seating can never invent one later.
   */
  stand({ electionId, candidateId, now = Date.now() }) {
    const e = this._db._db
      .prepare("SELECT * FROM sov_witness_elections WHERE election_id = ? AND status = 'open'")
      .get(electionId);
    if (!e) return { ok: false, reason: 'NO_OPEN_ELECTION' };
    if (now > e.closes_at) return { ok: false, reason: 'ELECTION_CLOSED' };

    // The key is NOT accepted from the caller. It is read from the enrolment table,
    // which is replicated, so every node resolves the SAME key for the same citizen.
    // Taking it as a parameter meant two nodes could record different keys for one
    // candidate and then seat different signers — a fork of the trust anchor arriving
    // through the nomination door. It also makes "only an enrolled citizen may stand"
    // structural rather than a separate check somebody could forget.
    const row = this._db._db
      .prepare('SELECT public_key_hex FROM sov_enrollments WHERE sovereign_id = ?')
      .get(candidateId);
    const pub = String((row && row.public_key_hex) || '').toLowerCase();
    if (!/^[0-9a-f]{64}$/.test(pub)) return { ok: false, reason: 'NOT_ENROLLED' };

    this._db._db.prepare(
      `INSERT OR IGNORE INTO sov_witness_candidates
         (election_id, candidate_id, pubkey_hex, stood_at) VALUES (?,?,?,?)`
    ).run(electionId, candidateId, pub, now);
    return { ok: true, pubkey_hex: pub };
  }

  /** Candidates who stood in an election. */
  candidates(electionId) {
    return this._db._db.prepare(
      'SELECT candidate_id, pubkey_hex FROM sov_witness_candidates WHERE election_id = ? ORDER BY candidate_id'
    ).all(electionId);
  }

  castVote({ electionId, voterId, candidateId, now = Date.now() }) {
    const e = this._db._db
      .prepare("SELECT * FROM sov_witness_elections WHERE election_id = ? AND status = 'open'")
      .get(electionId);
    if (!e) return { ok: false, reason: 'NO_OPEN_ELECTION' };
    if (now > e.closes_at) return { ok: false, reason: 'ELECTION_CLOSED' };

    // A vote may only name someone who actually stood. Without this the tally could
    // seat a citizen who never consented, or an id with no resolvable key.
    const stood = this._db._db.prepare(
      'SELECT 1 FROM sov_witness_candidates WHERE election_id = ? AND candidate_id = ?'
    ).get(electionId, candidateId);
    if (!stood) return { ok: false, reason: 'NOT_A_CANDIDATE' };

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
  closeElection({ electionId, now = Date.now() }) {
    const e = this._db._db
      .prepare("SELECT * FROM sov_witness_elections WHERE election_id = ?").get(electionId);
    if (!e) return { ok: false, reason: 'NO_SUCH_ELECTION' };
    if (e.status !== 'open') return { ok: false, reason: 'ALREADY_CLOSED' };

    // Do not tally until replicated votes have converged. Closing the instant
    // `closes_at` passes lets a node that is one anti-entropy cycle behind seat a
    // different cohort from its peers — identical rows are the whole point.
    if (now < e.closes_at + SETTLE_MS) {
      return { ok: false, reason: 'SETTLING', tally_after: e.closes_at + SETTLE_MS };
    }

    // EVERY timestamp below is derived from `closes_at`, never from this node's clock,
    // so two nodes closing hours apart still write byte-identical rows. That is what
    // lets these tables ride the ordinary consensus digest without flapping.
    const closedAt = e.closes_at;
    const termEnds = closedAt + this.termDays() * DAY_MS;

    // Only votes for citizens who stood, joined to the key captured at nomination.
    const votes = this._db._db.prepare(
      `SELECT v.candidate_id, c.pubkey_hex, COUNT(*) AS n
         FROM sov_witness_votes v
         JOIN sov_witness_candidates c
           ON c.election_id = v.election_id AND c.candidate_id = v.candidate_id
        WHERE v.election_id = ?
        GROUP BY v.candidate_id, c.pubkey_hex
        ORDER BY n DESC, v.candidate_id ASC`
    ).all(electionId);

    const cast   = votes.reduce((a, v) => a + v.n, 0);
    const needed = Math.ceil(e.eligible_at_open * e.quorum_pct);

    if (cast < needed) {
      this._db._db.prepare(
        "UPDATE sov_witness_elections SET status='void', closed_at=? WHERE election_id=?"
      ).run(closedAt, electionId);
      return { ok: false, reason: 'QUORUM_NOT_MET', cast, needed };
    }

    // A seat with no usable key is worse than an empty seat: it counts towards the
    // signer total while being unable to sign, silently raising the real threshold.
    const winners = votes
      .filter(w => /^[0-9a-f]{64}$/.test(String(w.pubkey_hex || '').toLowerCase()))
      .slice(0, this.signerCount());

    if (winners.length < this.threshold()) {
      this._db._db.prepare(
        "UPDATE sov_witness_elections SET status='void', closed_at=? WHERE election_id=?"
      ).run(closedAt, electionId);
      return { ok: false, reason: 'TOO_FEW_VALID_WINNERS',
               valid: winners.length, threshold: this.threshold() };
    }

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
        ).run(w.candidate_id, String(w.pubkey_hex).toLowerCase(), electionId, closedAt, termEnds);
      }
      d.prepare(
        "UPDATE sov_witness_elections SET status='closed', closed_at=? WHERE election_id=?"
      ).run(closedAt, electionId);
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

  /**
   * Bound the election history so a node that runs for a decade does not carry a
   * decade of ballots. Cheap, indexed deletes; safe to call on every tick.
   *
   * WHAT IS KEPT AND WHY THEY DIFFER:
   *   votes + candidates — a ballot matters until the election is tallied. After
   *     that the RESULT is the record, so these are the only rows that scale with
   *     citizen count (one vote each, every election) and they are pruned hardest.
   *     An audit window is still left so a disputed result can be re-tallied.
   *   elections — one small row each; kept as a long, capped ledger.
   *   signers — the active set is never touched. Retired/removed rows are kept for
   *     two full terms so "who could sign last year" stays answerable.
   *
   * Without this the tables grow monotonically: at one election a week and 10,000
   * citizens that is ~520,000 vote rows a year, for ever. The node is supposed to
   * feel the same on day 3,000 as on day 1.
   */
  pruneHistory({ now = Date.now(), auditDays = 30, keepElections = 200 } = {}) {
    const d = this._db._db;
    const cutoff = now - auditDays * DAY_MS;
    let removed = 0;
    try {
      // Ballots for settled elections, past the audit window.
      const settled = d.prepare(
        "SELECT election_id FROM sov_witness_elections " +
        "WHERE status IN ('closed','void') AND closed_at IS NOT NULL AND closed_at < ?"
      ).all(cutoff).map(r => r.election_id);
      for (const id of settled) {
        removed += d.prepare('DELETE FROM sov_witness_votes WHERE election_id = ?').run(id).changes;
        removed += d.prepare('DELETE FROM sov_witness_candidates WHERE election_id = ?').run(id).changes;
      }
      // Cap the election ledger itself (tiny rows, but not unbounded).
      removed += d.prepare(
        "DELETE FROM sov_witness_elections WHERE status IN ('closed','void') AND election_id NOT IN (" +
        "  SELECT election_id FROM sov_witness_elections ORDER BY opened_at DESC LIMIT ?" +
        ")"
      ).run(keepElections).changes;
      // Retired signers past two terms. ACTIVE rows are never eligible.
      removed += d.prepare(
        "DELETE FROM sov_witness_signers WHERE status != 'active' AND term_ends_at < ?"
      ).run(now - 2 * this.termDays() * DAY_MS).changes;
    } catch (e) {
      if (global.sovLog && global.sovLog.warn) {
        global.sovLog.warn(`[Witness] history prune skipped: ${e.message}`);
      }
    }
    return removed;
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  CITIZEN WIRE SURFACE  (op codes WE / WS / WV / WR)
  //
  //  Until these existed the election was unreachable: `castVote()` had no caller
  //  from the network, so even a correctly opened election could take no votes.
  //  A signer set that citizens cannot elect is not a decentralised trust anchor.
  //
  //  Codes checked against every code already in citizen_gateway (139 distinct) —
  //  only WA/WX were taken in the W family, so WE/WS/WV/WR are free. A collision
  //  here silently routes one feature's traffic into another's handler.
  // ══════════════════════════════════════════════════════════════════════════

  // OP-ONLY, DELIBERATELY. The frame carries the 2-char code and nothing else
  // that names the operation.
  //
  // The gateway's own _send (citizen_gateway.js) ships `{op, type, ...}` — both the
  // code AND the full English name — and SOV_PROTOCOL_DICTIONARY.md Appendix H
  // records that as the one place the V2 dictionary is still "PARTIALLY DEFEATED"
  // (P-13.2): phone->node is opaque because the app strips `type` in _addOpCode,
  // but node->phone still puts "SOV_TRANSFER_RESULT" on the wire for a
  // TLS-terminating proxy to read. Its only justification is backward compatibility
  // with already-installed apps, and these four codes are new — there is no old app
  // to be compatible with. So they ship opaque from the start rather than inheriting
  // a leak that is scheduled for removal.
  //
  // The app resolves the code through `_typeFromOp` in relay_connector.dart, which
  // is where the op -> name mapping is supposed to live. That map has all four.
  // Registering a code in MSG_TYPE and in `_typeFromOp` is what makes it readable —
  // NOT spelling it out on the wire.
  _send(ws, op, payload) {
    if (!ws || ws.readyState !== 1) return;
    ws.send(JSON.stringify({ op, ...payload }));
  }

  /** WE — read the current election, its candidates and the seated signers. */
  handleElectionState(ws, msg) {
    try {
      const now = Date.now();
      const e = this._db._db.prepare(
        "SELECT election_id, trigger_type, opened_at, closes_at, status, quorum_pct, eligible_at_open " +
        "FROM sov_witness_elections ORDER BY opened_at DESC LIMIT 1").get();
      const voterId = ws && ws._sovereignId;
      let already = false, tally = [];
      if (e) {
        if (voterId) {
          already = !!this._db._db.prepare(
            'SELECT 1 FROM sov_witness_votes WHERE election_id = ? AND voter_id = ?'
          ).get(e.election_id, voterId);
        }
        // Running tally is public: a citizen deciding how to vote should be able to
        // see the same picture everyone else can.
        tally = this._db._db.prepare(
          'SELECT candidate_id, COUNT(*) AS votes FROM sov_witness_votes WHERE election_id = ? ' +
          'GROUP BY candidate_id ORDER BY votes DESC, candidate_id ASC').all(e.election_id);
      }
      this._send(ws, 'WE', {
        success:     true,
        phase:       this.phase(now),
        election:    e || null,
        candidates:  e ? this.candidates(e.election_id) : [],
        tally,
        you_voted:   already,
        signer_count: this.signerCount(),
        threshold:   this.threshold(),
        seated:      this.activeSigners(now).map(x => ({ signer_id: x.signer_id, term_ends_at: x.term_ends_at })),
      });
    } catch (err) {
      this._send(ws, 'WE', { success: false, error: 'INTERNAL_ERROR' });
    }
  }

  /** WS — stand as a candidate. Only ever for YOURSELF. */
  handleStand(ws, msg) {
    if (ws && ws._legacyMode) { this._send(ws, 'WS', { success: false, error: 'SIGNATURE_REQUIRED' }); return; }
    const me = ws && ws._sovereignId;
    if (!me) { this._send(ws, 'WS', { success: false, error: 'NOT_AUTHENTICATED' }); return; }
    // candidate_id is deliberately NOT taken from the message. Nominating someone
    // else would seat a signer who never consented, and consent is the whole point
    // of having a nomination step at all.
    const e = this._db._db.prepare(
      "SELECT election_id FROM sov_witness_elections WHERE status = 'open'").get();
    if (!e) { this._send(ws, 'WS', { success: false, error: 'NO_OPEN_ELECTION' }); return; }
    const r = this.stand({ electionId: e.election_id, candidateId: me });
    this._send(ws, 'WS', r.ok
      ? { success: true, election_id: e.election_id }
      : { success: false, error: r.reason });
  }

  /** WV — cast your one vote. */
  handleVote(ws, msg) {
    if (ws && ws._legacyMode) { this._send(ws, 'WV', { success: false, error: 'SIGNATURE_REQUIRED' }); return; }
    const me = ws && ws._sovereignId;
    if (!me) { this._send(ws, 'WV', { success: false, error: 'NOT_AUTHENTICATED' }); return; }
    const candidate = msg && (msg.candidate_id || msg.candidate);
    if (!candidate) { this._send(ws, 'WV', { success: false, error: 'MISSING_FIELDS' }); return; }
    const e = this._db._db.prepare(
      "SELECT election_id FROM sov_witness_elections WHERE status = 'open'").get();
    if (!e) { this._send(ws, 'WV', { success: false, error: 'NO_OPEN_ELECTION' }); return; }
    const r = this.castVote({ electionId: e.election_id, voterId: me, candidateId: candidate });
    this._send(ws, 'WV', r.ok
      ? { success: true, election_id: e.election_id }
      : { success: false, error: r.reason });
  }

  /** WR — the release trust anchor, so any citizen can check who may sign. */
  handleSignerList(ws, msg) {
    const now = Date.now();
    this._send(ws, 'WR', {
      success:   true,
      phase:     this.phase(now),
      threshold: this.threshold(),
      signers:   this.activeSigners(now).map(x => ({
        signer_id: x.signer_id, pubkey_hex: x.pubkey_hex, term_ends_at: x.term_ends_at })),
    });
  }

  /** Record a release the signers actually shipped — this is what Trigger 2 watches. */
  recordSignedRelease({ manifestHash, signerCount, now = Date.now() }) {
    this._db._db.prepare(
      'INSERT OR REPLACE INTO sov_release_log (manifest_hash, signed_at, signer_count) VALUES (?,?,?)'
    ).run(manifestHash, now, signerCount);
  }
}

module.exports = { WitnessEngine, DAY_MS, SETTLE_MS };
