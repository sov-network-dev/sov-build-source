// ─────────────────────────────────────────────────────────────────────────────
// JUSTICE ENGINE — Dispute resolution, jury selection, verdict execution
// ─────────────────────────────────────────────────────────────────────────────
// The SOV justice protocol is peer-operated. Citizens file disputes, pay bonds,
// a jury of enrolled citizens is randomly selected, jurors accept or decline,
// vote, and the verdict is executed automatically.
//
// Two justice tracks:
//   1. Transaction Justice — citizen vs citizen (default)
//   2. Vault Justice       — vault claim disputes (different bond, separate panel)
//
// Jury lifecycle:
//   OPEN → select justice_min_jury_size jurors → push JUSTICE_JUROR_INVITE
//   Juror: ACCEPT (status=accepted) or DECLINE → auto-select replacement
//   60s timer: auto-replace jurors past justice_response_window_hours
//   Any accepted juror: EXPAND_PANEL adds 1 more up to justice_jury_size max
//   JUSTICE_VOTE: at justice_conviction_threshold × accepted jurors → convict
//   Verdict: push JUSTICE_CASE_UPDATE to all parties
//
// Op codes (inbound from phone):
//   DO — DISPUTE_OPEN        DR — DISPUTE_LIST
//   DG — DISPUTE_GET         DV — JUSTICE_VOTE
//   DJ — JUROR_RESPOND       DX — EXPAND_PANEL
// ─────────────────────────────────────────────────────────────────────────────

'use strict';

const crypto = require('crypto');
const ownerAuth = require('./owner_auth');   // 1.4.95: the citizen's signed request travels with their money ops

class JusticeEngine {

  constructor(identity, db, peerMesh) {
    this._identity  = identity;
    this._db        = db;
    this._peerMesh  = peerMesh;
    this._gateway   = null;

    this._initJusticeTables();

    // Register peer mesh handlers
    peerMesh.on('JUSTICE_CASE_BROADCAST',   (msg) => this._handleCaseBroadcast(msg));
    peerMesh.on('JUSTICE_JUROR_FORWARD',    (msg) => this._handleJurorForward(msg));
    peerMesh.on('JUSTICE_VOTE_BROADCAST',   (msg) => this._handleVoteBroadcast(msg));
    peerMesh.on('JUSTICE_VERDICT_BROADCAST',(msg) => this._handleVerdictBroadcast(msg));

    // 60-second juror timeout check
    setInterval(() => this._checkJurorTimeouts(), 60 * 1000);

    global.sovLog.info('      ✓ Justice engine initialised');
  }

  setGateway(gateway) {
    this._gateway = gateway;
  }

  // ── Table initialisation ──────────────────────────────────────────────────

  _initJusticeTables() {
    this._db._db.exec(`

      CREATE TABLE IF NOT EXISTS sov_disputes (
        case_id       TEXT PRIMARY KEY,
        plaintiff_id  TEXT NOT NULL,
        defendant_id  TEXT NOT NULL,
        evidence_hash TEXT NOT NULL DEFAULT '',   -- SHA-256 of off-chain evidence
        amount_seeds  INTEGER NOT NULL DEFAULT 0, -- disputed amount (0 if not financial)
        bond_held     INTEGER NOT NULL DEFAULT 0, -- seeds held from plaintiff bond
        status        TEXT NOT NULL DEFAULT 'open',
        -- open | jury_selection | active | convicted | dismissed | appealed
        verdict       TEXT NOT NULL DEFAULT '',   -- 'convicted' | 'dismissed' | ''
        created_at    INTEGER NOT NULL,
        closed_at     INTEGER NOT NULL DEFAULT 0,
        track         TEXT NOT NULL DEFAULT 'transaction',  -- transaction | vault
        memo          TEXT NOT NULL DEFAULT '',
        -- Restitution the defendant could not cover. A defendant with nothing to
        -- take cannot be made to pay: SOV mints nothing to settle a dispute, so the
        -- shortfall is RECORDED here instead of credited from thin air. Reading a
        -- non-zero value means the verdict was for the plaintiff and the money was
        -- not there.
        restitution_unpaid_seeds INTEGER NOT NULL DEFAULT 0
      );
      CREATE INDEX IF NOT EXISTS idx_dispute_plaintiff ON sov_disputes(plaintiff_id);
      CREATE INDEX IF NOT EXISTS idx_dispute_defendant ON sov_disputes(defendant_id);
      CREATE INDEX IF NOT EXISTS idx_dispute_status    ON sov_disputes(status);

      CREATE TABLE IF NOT EXISTS sov_case_jurors (
        case_id       TEXT NOT NULL,
        juror_id      TEXT NOT NULL,
        status        TEXT NOT NULL DEFAULT 'invited',
        -- invited | accepted | declined | replaced | voted
        invited_at    INTEGER NOT NULL,
        responded_at  INTEGER NOT NULL DEFAULT 0,
        replaced_by   TEXT NOT NULL DEFAULT '',
        vote          TEXT NOT NULL DEFAULT '',   -- conviction | dismissal
        voted_at      INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (case_id, juror_id)
      );
      CREATE INDEX IF NOT EXISTS idx_juror_case   ON sov_case_jurors(case_id);
      CREATE INDEX IF NOT EXISTS idx_juror_citizen ON sov_case_jurors(juror_id);

    `);

    // Seed justice governance defaults
    const govDefaults = [
      ['dispute_bond_amount',           '10'],
      ['justice_jury_size',             '7'],
      ['justice_min_jury_size',         '3'],
      ['justice_response_window_hours', '48'],
      ['justice_conviction_threshold',  '0.67'],
    ];
    for (const [key, val] of govDefaults) {
      this._db._db.prepare(`
        INSERT OR IGNORE INTO sov_governance_params (param_key, param_value, activated_at)
        VALUES (?, ?, 0)
      `).run(key, val);
    }

    // ── Migration ────────────────────────────────────────────────────────────
    // CREATE TABLE IF NOT EXISTS is a no-op on a table that already exists, and
    // every node in the fleet already has sov_disputes — so a new column reaches
    // them only through ALTER. Without this the restitution-shortfall UPDATE
    // throws on a live node, the catch swallows it, and the one record that says
    // "the money was not there" is silently never written.
    try {
      this._db._db.exec(
        'ALTER TABLE sov_disputes ADD COLUMN restitution_unpaid_seeds INTEGER NOT NULL DEFAULT 0');
      global.sovLog.info('[JUSTICE] migrated sov_disputes: + restitution_unpaid_seeds');
    } catch (_) { /* already present — the normal case after the first boot */ }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  DISPUTE OPEN
  // ═══════════════════════════════════════════════════════════════════════════

  async handleDisputeOpen(ws, msg) {
    const { case_id, defendant_id, evidence_hash, amount_seeds, memo, track } = msg;
    const plaintiff_id = ws._sovereignId;

    if (ws._legacyMode) { this._send(ws, 'DD', { type: 'JUSTICE_DISPUTE_OPENED', success: false, error: 'SIGNATURE_REQUIRED' }); return; }

    if (!case_id || !defendant_id) {
      this._send(ws, 'DD', { type: 'JUSTICE_DISPUTE_OPENED', success: false, error: 'MISSING_FIELDS' });
      return;
    }

    if (plaintiff_id === defendant_id) {
      this._send(ws, 'DD', { type: 'JUSTICE_DISPUTE_OPENED', success: false, error: 'CANNOT_DISPUTE_SELF' });
      return;
    }

    if (this._db._db.prepare('SELECT 1 FROM sov_disputes WHERE case_id = ?').get(case_id)) {
      this._send(ws, 'DD', { type: 'JUSTICE_DISPUTE_OPENED', success: false, error: 'CASE_ID_EXISTS' });
      return;
    }
    // 1.4.90: the bond is an OWNER op — plaintiff -> this case's bond holding, granted by a
    // majority of nodes on the plaintiff's slot and applied on every node (peers used to keep
    // the plaintiff's balance untouched).
    const bondSeeds = parseInt(this._getGovParam('dispute_bond_amount', '10')) * 1_000_000;
    if (bondSeeds > 0) {
      const res = await this._db.ledger.commitOwnerOp({
        kind: 'dispute_bond', ref: case_id, owner: { acct: plaintiff_id },
        auth: ownerAuth.fromAppRequest(msg),   // 1.4.95: every node checks the citizen's own signed request
        moves: [{ acct: plaintiff_id, d: -bondSeeds }],
        holds: [{ id: 'bond:' + case_id, d: bondSeeds }],
      });
      if (!res.ok) {
        this._send(ws, 'DD', { type: 'JUSTICE_DISPUTE_OPENED', success: false,
          error: res.error === 'LEDGER_INSUFFICIENT' ? 'INSUFFICIENT_BALANCE_FOR_BOND' : res.error });
        return;
      }
    }

    const now = Date.now();
    try {
      this._db._db.prepare(`
        INSERT OR IGNORE INTO sov_disputes
          (case_id, plaintiff_id, defendant_id, evidence_hash, amount_seeds, bond_held, status, created_at, track, memo)
        VALUES (?, ?, ?, ?, ?, ?, 'jury_selection', ?, ?, ?)
      `).run(
        case_id, plaintiff_id, defendant_id,
        evidence_hash || '', amount_seeds || 0, bondSeeds,
        now, track || 'transaction', memo || ''
      );
    } catch (_) {
      this._send(ws, 'DD', { type: 'JUSTICE_DISPUTE_OPENED', success: false, error: 'CASE_ID_EXISTS' });
      return;
    }

    // Select initial jury
    const minJurors = parseInt(this._getGovParam('justice_min_jury_size', '3'));
    const jurorIds  = this._selectJurors(case_id, plaintiff_id, defendant_id, minJurors);

    this._send(ws, 'DD', { type: 'JUSTICE_DISPUTE_OPENED',
      success: true,
      case_id,
      plaintiff_id,
      defendant_id,
      juror_count: jurorIds.length,
      bond_held:   bondSeeds,
      ts:          now,
    });

    // Broadcast new case to peer nodes
    const caseRow = this._db._db.prepare('SELECT * FROM sov_disputes WHERE case_id = ?').get(case_id);
    this._peerMesh.broadcast('JUSTICE_CASE_BROADCAST', {
      dispute: caseRow, node_id: this._identity.nodeId,
    });

    global.sovLog.info(`Dispute opened: ${case_id} by ${plaintiff_id} vs ${defendant_id}`);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  DISPUTE LIST / GET
  // ═══════════════════════════════════════════════════════════════════════════

  handleDisputeList(ws, msg) {
    const { role, status, limit } = msg;
    const citizen_id = ws._sovereignId;

    let rows;
    if (role === 'juror') {
      rows = this._db._db.prepare(`
        SELECT d.* FROM sov_disputes d
        JOIN sov_case_jurors j ON j.case_id = d.case_id
        WHERE j.juror_id = ? AND j.status IN ('invited','accepted')
        ORDER BY d.created_at DESC LIMIT ?
      `).all(citizen_id, Math.min(limit || 20, 100));
    } else {
      rows = this._db._db.prepare(`
        SELECT * FROM sov_disputes
        WHERE (plaintiff_id = ? OR defendant_id = ?)
        ${status ? 'AND status = ?' : ''}
        ORDER BY created_at DESC LIMIT ?
      `).all(...(status ? [citizen_id, citizen_id, status] : [citizen_id, citizen_id]), Math.min(limit || 20, 100));
    }

    // Role-based response type so the app's My Cases (own disputes) and juror
    // invitations tabs use DISTINCT responseTypes — both route here via op DR but
    // must not collide when fired concurrently from initState. Return both `cases`
    // and `disputes` keys (the two screens read different keys).
    const respType = (role === 'juror') ? 'JUSTICE_LIST_OPEN_RESULT' : 'JUSTICE_MY_CASES_RESULT';
    this._send(ws, 'DL', { type: respType, success: true, cases: rows, disputes: rows, ts: Date.now() });
  }

  handleDisputeGet(ws, msg) {
    const { case_id } = msg;
    if (!case_id) return;

    const dispute = this._db._db.prepare('SELECT * FROM sov_disputes WHERE case_id = ?').get(case_id);
    if (!dispute) {
      this._send(ws, 'DG', { type: 'JUSTICE_DISPUTE_GET', success: false, error: 'CASE_NOT_FOUND' });
      return;
    }

    // Include juror list (sanitised — no vote until verdict)
    const citizen_id = ws._sovereignId;
    const isParty    = (dispute.plaintiff_id === citizen_id || dispute.defendant_id === citizen_id);
    const jurors     = this._db._db.prepare('SELECT * FROM sov_case_jurors WHERE case_id = ?').all(case_id);

    this._send(ws, 'DG', { type: 'JUSTICE_DISPUTE_GET',
      success: true,
      dispute,
      jurors:  isParty ? jurors : jurors.map(j => ({ ...j, vote: '' })),
    });
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  JUROR RESPOND (accept / decline)
  // ═══════════════════════════════════════════════════════════════════════════

  handleJurorRespond(ws, msg) {
    const { case_id, decision } = msg;  // decision: 'accept' | 'decline'
    const juror_id = ws._sovereignId;

    if (ws._legacyMode) { this._send(ws, 'DJ', { type: 'JUSTICE_JUROR_RESPONSE_RESULT', success: false, error: 'SIGNATURE_REQUIRED' }); return; }

    if (!case_id || !decision) {
      this._send(ws, 'DJ', { type: 'JUSTICE_JUROR_RESPONSE_RESULT', success: false, error: 'MISSING_FIELDS' });
      return;
    }

    const row = this._db._db.prepare(`
      SELECT * FROM sov_case_jurors WHERE case_id = ? AND juror_id = ? AND status = 'invited'
    `).get(case_id, juror_id);

    if (!row) {
      this._send(ws, 'DJ', { type: 'JUSTICE_JUROR_RESPONSE_RESULT', success: false, error: 'NOT_INVITED_OR_ALREADY_RESPONDED' });
      return;
    }

    const now = Date.now();
    if (decision === 'accept') {
      this._db._db.prepare(`
        UPDATE sov_case_jurors SET status = 'accepted', responded_at = ? WHERE case_id = ? AND juror_id = ?
      `).run(now, case_id, juror_id);
      this._send(ws, 'DJ', { type: 'JUSTICE_JUROR_RESPONSE_RESULT', success: true, decision: 'accepted', case_id });
    } else {
      // Declined — replace immediately
      this._db._db.prepare(`
        UPDATE sov_case_jurors SET status = 'declined', responded_at = ? WHERE case_id = ? AND juror_id = ?
      `).run(now, case_id, juror_id);
      this._selectJurors(case_id, null, null, 1);
      this._send(ws, 'DJ', { type: 'JUSTICE_JUROR_RESPONSE_RESULT', success: true, decision: 'declined', case_id });
    }

    // Notify parties via case update
    this._broadcastCaseUpdate(case_id, 'JUROR_RESPONSE');
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  EXPAND PANEL (accepted juror adds one more)
  // ═══════════════════════════════════════════════════════════════════════════

  handleExpandPanel(ws, msg) {
    const { case_id } = msg;
    const juror_id    = ws._sovereignId;

    if (ws._legacyMode) { this._send(ws, 'DX', { type: 'JUSTICE_EXPAND_PANEL_RESULT', success: false, error: 'SIGNATURE_REQUIRED' }); return; }

    if (!case_id) return;

    const dispute = this._db._db.prepare('SELECT * FROM sov_disputes WHERE case_id = ?').get(case_id);
    if (!dispute || dispute.status === 'convicted' || dispute.status === 'dismissed') {
      this._send(ws, 'DX', { type: 'JUSTICE_EXPAND_PANEL_RESULT', success: false, error: 'CASE_NOT_ACTIVE' });
      return;
    }

    // Verify requester is an accepted juror
    const jurorRow = this._db._db.prepare(`
      SELECT * FROM sov_case_jurors WHERE case_id = ? AND juror_id = ? AND status = 'accepted'
    `).get(case_id, juror_id);
    if (!jurorRow) {
      this._send(ws, 'DX', { type: 'JUSTICE_EXPAND_PANEL_RESULT', success: false, error: 'NOT_AN_ACCEPTED_JUROR' });
      return;
    }

    // Check max panel size
    const maxJurors = parseInt(this._getGovParam('justice_jury_size', '7'));
    const current   = this._db._db.prepare(`
      SELECT COUNT(*) AS cnt FROM sov_case_jurors WHERE case_id = ? AND status NOT IN ('declined','replaced')
    `).get(case_id);

    if (current.cnt >= maxJurors) {
      this._send(ws, 'DX', { type: 'JUSTICE_EXPAND_PANEL_RESULT', success: false, error: 'PANEL_AT_MAXIMUM' });
      return;
    }

    const added = this._selectJurors(case_id, dispute.plaintiff_id, dispute.defendant_id, 1);
    this._send(ws, 'DX', { type: 'JUSTICE_EXPAND_PANEL_RESULT', success: true, case_id, added_jurors: added.length });
    this._broadcastCaseUpdate(case_id, 'PANEL_EXPANDED');
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  CAST VOTE
  // ═══════════════════════════════════════════════════════════════════════════

  handleJusticeVote(ws, msg) {
    const { case_id, vote } = msg;  // vote: 'conviction' | 'dismissal'
    const juror_id = ws._sovereignId;

    if (ws._legacyMode) { this._send(ws, 'DV', { type: 'JUSTICE_VOTE_RECORDED', success: false, error: 'SIGNATURE_REQUIRED' }); return; }

    if (!case_id || !vote || !['conviction', 'dismissal'].includes(vote)) {
      this._send(ws, 'DV', { type: 'JUSTICE_VOTE_RECORDED', success: false, error: 'INVALID_VOTE' });
      return;
    }

    const jurorRow = this._db._db.prepare(`
      SELECT * FROM sov_case_jurors WHERE case_id = ? AND juror_id = ? AND status = 'accepted'
    `).get(case_id, juror_id);

    if (!jurorRow) {
      this._send(ws, 'DV', { type: 'JUSTICE_VOTE_RECORDED', success: false, error: 'NOT_AN_ACCEPTED_JUROR' });
      return;
    }
    if (jurorRow.vote) {
      this._send(ws, 'DV', { type: 'JUSTICE_VOTE_RECORDED', success: false, error: 'ALREADY_VOTED' });
      return;
    }

    const now = Date.now();
    this._db._db.prepare(`
      UPDATE sov_case_jurors SET status = 'voted', vote = ?, voted_at = ? WHERE case_id = ? AND juror_id = ?
    `).run(vote, now, case_id, juror_id);

    this._send(ws, 'DV', { type: 'JUSTICE_VOTE_RECORDED', success: true, case_id, vote_recorded: vote });

    // Broadcast vote to peers
    this._peerMesh.broadcast('JUSTICE_VOTE_BROADCAST', {
      case_id, juror_id, vote, voted_at: now, node_id: this._identity.nodeId,
    });

    // Check if we have reached a verdict
    this._checkForVerdict(case_id);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  VERDICT CHECK
  // ═══════════════════════════════════════════════════════════════════════════

  _checkForVerdict(caseId) {
    const dispute = this._db._db.prepare('SELECT * FROM sov_disputes WHERE case_id = ?').get(caseId);
    if (!dispute || ['convicted', 'dismissed'].includes(dispute.status)) return;

    const jurors   = this._db._db.prepare(`
      SELECT * FROM sov_case_jurors WHERE case_id = ? AND status IN ('accepted','voted')
    `).all(caseId);

    const acceptedCount   = jurors.length;
    if (acceptedCount === 0) return;

    const convictionVotes = jurors.filter(j => j.vote === 'conviction').length;
    const dismissalVotes  = jurors.filter(j => j.vote === 'dismissal').length;
    const totalVoted      = convictionVotes + dismissalVotes;

    const threshold  = parseFloat(this._getGovParam('justice_conviction_threshold', '0.67'));
    const needed     = Math.ceil(acceptedCount * threshold);

    // Need at least all jurors to have voted before applying threshold
    // (otherwise partial tallies could trigger early verdict)
    if (totalVoted < acceptedCount) return;

    let verdict = null;
    if (convictionVotes >= needed)  verdict = 'convicted';
    else if (dismissalVotes > 0)    verdict = 'dismissed';
    else return;

    this._executeVerdict(caseId, verdict);
  }

  _executeVerdict(caseId, verdict) {
    const dispute = this._db._db.prepare('SELECT * FROM sov_disputes WHERE case_id = ?').get(caseId);
    if (!dispute) return;

    const now = Date.now();
    this._db._db.prepare(`
      UPDATE sov_disputes SET status = ?, verdict = ?, closed_at = ? WHERE case_id = ?
    `).run(verdict, verdict, now, caseId);

    // ── Money. Convicted = the defendant is guilty = THE PLAINTIFF WON. ───────
    // These two branches used to be the wrong way round: a conviction paid half
    // the WINNER's bond to the person they had just beaten, and a dismissal handed
    // the bond back, so filing a baseless claim was free and winning a real one
    // cost you. `amount_seeds` — the disputed sum, captured when the case is filed
    // and replicated to every peer — was never read at all, so no dispute in the
    // network's history had ever moved the money it was about.
    //
    // NOTHING HERE IS MINTED. Every credit is matched by a debit: the bond was
    // deducted at filing so returning it balances that, and restitution and juror
    // fees are taken from a real balance and only to the extent it holds them. The
    // 50,000,000 invariant therefore cannot move, and a botched change halts
    // instead of quietly inflating.
    // 1.4.90: the whole verdict is ONE ledger op per case (deterministic id): applied atomically
    // and exactly once on every node. Nodes other than this one used to see none of it.
    const jurorFee = parseInt(this._getGovParam('justice_juror_reward', '500000'), 10) || 0;
    const jurors   = this._db._db.prepare(
      "SELECT juror_id FROM sov_case_jurors WHERE case_id = ? AND status = 'voted'"
    ).all(caseId);
    let   unpaid   = 0;
    const bond     = Math.max(0, parseInt(dispute.bond_held || 0, 10));
    const bondHeld = this._db.holdingBalance('bond:' + caseId) >= bond ? bond : 0;   // legacy cases: adopted at boot
    const moves = [], holds = [];
    let debitsDefendant = false;

    if (verdict === 'convicted') {
      // Return the bond, move the disputed amount, and charge the guilty party for the jury's time.
      if (bondHeld > 0) { holds.push({ id: 'bond:' + caseId, d: -bondHeld }); moves.push({ acct: dispute.plaintiff_id, d: bondHeld }); }
      const owed = Math.max(0, parseInt(dispute.amount_seeds || 0, 10));
      const disc = this._db.readDisc(dispute.defendant_id);
      let available = (disc && disc.spendable_seeds) || 0;
      const take = Math.min(owed, available);
      if (take > 0) { moves.push({ acct: dispute.defendant_id, d: -take }, { acct: dispute.plaintiff_id, d: take }); available -= take; debitsDefendant = true; }
      unpaid = owed - take;
      let feesPaid = 0;
      for (const j of jurors) {
        if (!jurorFee || available < jurorFee) break;          // a jury is paid for work done, never from nothing
        moves.push({ acct: dispute.defendant_id, d: -jurorFee }, { acct: j.juror_id, d: jurorFee });
        available -= jurorFee; feesPaid += jurorFee; debitsDefendant = true;
      }
      if (feesPaid > 0) global.sovLog.info(`[JUSTICE] case ${caseId}: ${feesPaid} seeds paid in juror fees`);

    } else if (verdict === 'dismissed') {
      // The claim was thrown out. The bond is FORFEIT: the jury is paid out of it first, and the
      // remainder compensates the defendant for having been dragged through a case they won.
      const pot      = bondHeld;
      const perJuror = jurors.length > 0 ? Math.min(jurorFee, Math.floor(pot / jurors.length)) : 0;
      let handedOut = 0;
      if (pot > 0) holds.push({ id: 'bond:' + caseId, d: -pot });
      for (const j of jurors) { if (perJuror > 0) { moves.push({ acct: j.juror_id, d: perJuror }); handedOut += perJuror; } }
      if (pot - handedOut > 0) moves.push({ acct: dispute.defendant_id, d: pot - handedOut });
      if (handedOut > 0) global.sovLog.info(`[JUSTICE] case ${caseId}: ${handedOut} seeds of forfeited bond paid to ${jurors.length} juror(s)`);
    }

    if (moves.length || holds.length) {
      const op = { op_id: `verdict:${caseId}`, kind: 'verdict', ref: caseId, moves, holds };
      // Taking money from the defendant's wallet takes the defendant's slot, like any spend of it.
      const done = debitsDefendant
        ? this._db.ledger.commitOwnerOp({ ...op, owner: { acct: dispute.defendant_id } })
        : Promise.resolve(this._db.ledger.commitSystemOp(op));
      done.then((r) => {
        if (!r.ok) global.sovLog.error(`[JUSTICE] case ${caseId}: verdict money NOT moved: ${r.error}`);
      });
    }

    if (unpaid > 0) {
      // A defendant who cannot pay is a fact about the case, not a licence to
      // credit a plaintiff from nothing. The row replicates to every peer.
      try {
        this._db._db.prepare(
          'UPDATE sov_disputes SET restitution_unpaid_seeds = ? WHERE case_id = ?'
        ).run(unpaid, caseId);
      } catch (_) { /* pre-migration node: column absent, the warning below still lands */ }
      global.sovLog.warn(
        `[JUSTICE] case ${caseId}: restitution short by ${unpaid} seeds — the defendant could not cover it`);
    }

    // Notify all parties
    const payload = {
      case_id:   caseId,
      event:     'VERDICT',
      verdict,
      closed_at: now,
    };
    this._notifyParties(dispute, payload);

    // Broadcast to peers
    this._peerMesh.broadcast('JUSTICE_VERDICT_BROADCAST', {
      case_id: caseId, verdict, closed_at: now, node_id: this._identity.nodeId,
    });

    global.sovLog.info(`Justice verdict: case ${caseId} → ${verdict}`);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  JUROR TIMEOUT CHECKER — runs every 60 seconds
  // ═══════════════════════════════════════════════════════════════════════════

  _checkJurorTimeouts() {
    const windowHours  = parseFloat(this._getGovParam('justice_response_window_hours', '48'));
    const windowMs     = windowHours * 60 * 60 * 1000;
    const cutoff       = Date.now() - windowMs;

    // Find jurors who were invited but have not responded within the window
    const stale = this._db._db.prepare(`
      SELECT j.*, d.plaintiff_id, d.defendant_id
      FROM sov_case_jurors j
      JOIN sov_disputes d ON d.case_id = j.case_id
      WHERE j.status = 'invited' AND j.invited_at < ?
    `).all(cutoff);

    for (const juror of stale) {
      // Mark as replaced
      this._db._db.prepare(`
        UPDATE sov_case_jurors SET status = 'replaced', responded_at = ? WHERE case_id = ? AND juror_id = ?
      `).run(Date.now(), juror.case_id, juror.juror_id);

      // Select replacement
      this._selectJurors(juror.case_id, juror.plaintiff_id, juror.defendant_id, 1);
      this._broadcastCaseUpdate(juror.case_id, 'JUROR_REPLACED');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  PEER MESH HANDLERS
  // ═══════════════════════════════════════════════════════════════════════════

  _handleCaseBroadcast(msg) {
    const { dispute, node_id } = msg;
    if (node_id === this._identity.nodeId || !dispute) return;
    try {
      this._db._db.prepare(`
        INSERT OR IGNORE INTO sov_disputes
          (case_id, plaintiff_id, defendant_id, evidence_hash, amount_seeds, bond_held,
           status, created_at, track, memo, restitution_unpaid_seeds)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      `).run(
        dispute.case_id, dispute.plaintiff_id, dispute.defendant_id,
        dispute.evidence_hash || '', dispute.amount_seeds || 0, dispute.bond_held || 0,
        dispute.status || 'jury_selection', dispute.created_at, dispute.track || 'transaction',
        dispute.memo || '', dispute.restitution_unpaid_seeds || 0
      );
    } catch (_) {}
  }

  _handleJurorForward(msg) {
    // Peer is forwarding a JUSTICE_JUROR_INVITE to a citizen on our node
    const { juror_id, case_id, payload } = msg;
    if (!juror_id || !this._gateway) return;
    this._gateway.push(juror_id, 'JI', payload || { case_id });
  }

  _handleVoteBroadcast(msg) {
    const { case_id, juror_id, vote, voted_at, node_id } = msg;
    if (node_id === this._identity.nodeId || !case_id || !juror_id) return;
    this._db._db.prepare(`
      UPDATE sov_case_jurors SET status = 'voted', vote = ?, voted_at = ?
      WHERE case_id = ? AND juror_id = ? AND status = 'accepted'
    `).run(vote, voted_at || Date.now(), case_id, juror_id);
  }

  _handleVerdictBroadcast(msg) {
    const { case_id, verdict, closed_at, node_id } = msg;
    if (node_id === this._identity.nodeId || !case_id) return;
    this._db._db.prepare(`
      UPDATE sov_disputes SET status = ?, verdict = ?, closed_at = ?
      WHERE case_id = ? AND status NOT IN ('convicted','dismissed')
    `).run(verdict, verdict, closed_at || Date.now(), case_id);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  HELPERS
  // ═══════════════════════════════════════════════════════════════════════════

  // Select N jurors from enrolled citizens (excluding parties + existing jurors)
  _selectJurors(caseId, plaintiffId, defendantId, count) {
    // Get existing juror_ids for this case
    const existing = this._db._db.prepare(
      'SELECT juror_id FROM sov_case_jurors WHERE case_id = ?'
    ).all(caseId).map(r => r.juror_id);

    const exclude = new Set([...(plaintiffId ? [plaintiffId] : []), ...(defendantId ? [defendantId] : []), ...existing]);

    // Pick random enrolled citizens using cryptographically secure shuffle (V10 fix)
    const allEligible = this._db._db.prepare(`
      SELECT sovereign_id FROM sov_enrollments
      WHERE sovereign_id NOT IN (${[...exclude].map(() => '?').join(',') || "''"})
    `).all(...(exclude.size > 0 ? [...exclude] : ['']));

    // Fisher-Yates shuffle with crypto.randomBytes() — replaces ORDER BY RANDOM() (SQLite PRNG is not CSPRNG)
    for (let i = allEligible.length - 1; i > 0; i--) {
      const j = crypto.randomBytes(4).readUInt32BE(0) % (i + 1);
      [allEligible[i], allEligible[j]] = [allEligible[j], allEligible[i]];
    }
    const candidates = allEligible.slice(0, count);

    const now     = Date.now();
    const invited = [];
    for (const c of candidates) {
      try {
        this._db._db.prepare(`
          INSERT OR IGNORE INTO sov_case_jurors (case_id, juror_id, status, invited_at)
          VALUES (?, ?, 'invited', ?)
        `).run(caseId, c.sovereign_id, now);

        invited.push(c.sovereign_id);

        // Push invite to juror (if on this node, otherwise forward via peer mesh)
        const invitePayload = { case_id: caseId, ts: now };
        const delivered     = this._gateway && this._gateway.push(c.sovereign_id, 'JI', invitePayload);
        if (!delivered) {
          const presence = this._db.getCitizenPresence(c.sovereign_id);
          if (presence && presence.node_id !== this._identity.nodeId) {
            this._peerMesh.sendTo(presence.node_id, 'JUSTICE_JUROR_FORWARD', {
              juror_id: c.sovereign_id, case_id: caseId, payload: invitePayload,
            });
          }
        }
      } catch (_) {}
    }
    return invited;
  }

  // 1.4.90: no direct balance helpers here — every money move in a case is a ledger op
  // (protocol/ledger.js), so a verdict cannot change one node's ledger and not the others.

  _notifyParties(dispute, payload) {
    if (!this._gateway) return;
    this._gateway.push(dispute.plaintiff_id, 'JU', payload);
    this._gateway.push(dispute.defendant_id, 'JU', payload);

    // Notify all jurors
    const jurors = this._db._db.prepare(`
      SELECT juror_id FROM sov_case_jurors WHERE case_id = ? AND status IN ('accepted','voted')
    `).all(dispute.case_id);
    for (const j of jurors) {
      this._gateway.push(j.juror_id, 'JU', payload);
    }
  }

  _broadcastCaseUpdate(caseId, event) {
    const dispute = this._db._db.prepare('SELECT * FROM sov_disputes WHERE case_id = ?').get(caseId);
    if (!dispute) return;
    this._notifyParties(dispute, { case_id: caseId, event, ts: Date.now() });
  }

  _getGovParam(key, fallback = '0') {
    const row = this._db._db.prepare(
      'SELECT param_value FROM sov_governance_params WHERE param_key = ?'
    ).get(key);
    return row ? row.param_value.toString() : fallback.toString();
  }

  _send(ws, op, payload) {
    if (!ws || ws.readyState !== 1) return;
    ws.send(JSON.stringify({ op, ...payload }));
  }
}

module.exports = { JusticeEngine };
