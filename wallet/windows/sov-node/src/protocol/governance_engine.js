// ─────────────────────────────────────────────────────────────────────────────
// GOVERNANCE ENGINE — Democratic network governance
// ─────────────────────────────────────────────────────────────────────────────
// Citizens vote on network parameters. Petitions force votes or flip params.
// The governance engine is the legitimate upgrade path for the SOV protocol.
//
// Architecture:
//   - All parameters stored in sov_governance_params (key/value, all strings)
//   - _getGovParam() ALWAYS returns a string — never Number() — callers cast
//   - Binary protocol gates use strict === '1' comparison
//   - Poll close: 60s timer checks expiry → quorum check → winner → activate
//   - Petition 33%: auto-creates poll → citizens vote
//   - Petition 67%: directly flips param, no poll needed (supermajority)
//   - Cross-node sync: every vote/close/activation broadcast to all peers
//
// Op codes (inbound from citizen phone):
//   PC — POLL_CREATE            PV — POLL_VOTE
//   PL — POLL_LIST              PG — POLL_GET
//   EC — PETITION_CREATE        ES — PETITION_SIGN
//   EL — PETITION_LIST          KG — GOV_PARAM_GET
//   KA — GOV_PARAMS_ALL
//   QS — SOV_VALUE_STATUS       QV — SOV_VALUE_SUBMIT (SOV price oracle)
// ─────────────────────────────────────────────────────────────────────────────

'use strict';

const crypto = require('crypto');

// ── PARAM_MAP ────────────────────────────────────────────────────────────────
// Every governable parameter. Maps a "constitution tag" → DB key + range.
// Binary params have min=null (they are 0 or 1 only).
//
// CRITICAL: _activateGovernanceParam() ALWAYS stores strings.
// CRITICAL: _getGovParam() ALWAYS returns strings.
// CRITICAL: Number(row.param_value) is FORBIDDEN — breaks strict === '1' checks.

const PARAM_MAP = {
  // Governance meta
  quorum_threshold:              { key: 'quorum_threshold',             min: 0.01,  max: 0.50  },
  min_poll_duration:             { key: 'min_poll_duration',            min: 60,    max: 10080 },
  max_poll_duration:             { key: 'max_poll_duration',            min: 1440,  max: 518400},
  poll_retention_days:           { key: 'poll_retention_days',          min: 1,     max: 365   },
  re_proposal_cooldown_days:     { key: 're_proposal_cooldown_days',    min: 0,     max: 90    },
  petition_threshold_pct:        { key: 'petition_threshold_pct',       min: 0.01,  max: 0.90  },
  petition_supermajority_pct:    { key: 'petition_supermajority_pct',   min: 0.51,  max: 0.99  },
  // Binary protocol gates
  sov_enclave:                   { key: 'sov_enclave',                  binary: true           },
  sov_login:                     { key: 'sov_login',                    binary: true           },
  // Financial
  tx_fee_rate:                   { key: 'tx_fee_rate',                  min: 0,     max: 0.05  },
  tx_fee_max_sov:                { key: 'tx_fee_max_sov',               min: 0,     max: 100000 },   // per-transfer fee ceiling in SOV (0 = uncapped)
  sov_issuance_rate:             { key: 'sov_issuance_rate',            min: 0,     max: 1000000},
  issuance_epoch_hours:          { key: 'issuance_epoch_hours',         min: 1,     max: 168   },
  issuance_max_backlog_epochs:   { key: 'issuance_max_backlog_epochs',  min: 1,     max: 365   },
  // Exchange
  exchange_network_fee:          { key: 'exchange_network_fee',         min: 0,     max: 0.05  },
  exchange_max_order_sov:        { key: 'exchange_max_order_sov',       min: 1,     max: 10000000},
  // Relay pool
  relay_join_min_stake:          { key: 'relay_join_min_stake',         min: 0,     max: 100000},
  operator_min_uptime_days:      { key: 'operator_min_uptime_days',     min: 1,     max: 365   },
  operator_signup_sample:        { key: 'operator_signup_sample',       min: 1,     max: 21    },   // peers asked to interrogate a joining node
  operator_signup_quorum:        { key: 'operator_signup_quorum',       min: 1,     max: 21    },   // approvals required before it counts as joined
  relay_max_citizens:            { key: 'relay_max_citizens',           min: 100,   max: 10000000},
  // Operator economy (SOV_OPERATOR_ECONOMY_SPEC §8, king-approved 2026-07-19).
  // operator_monthly_payout_pct is RETIRED — it paid 1% of the whole reserve per
  // period (200,000 SOV on a 20M pool) and appears in no blueprint. Values in seeds.
  operator_uptime_reward:        { key: 'operator_uptime_reward',       min: 0,     max: 1000000000 },   // 0–1,000 SOV per relay/period
  operator_tx_reward:            { key: 'operator_tx_reward',           min: 0,     max: 1000000 },      // 0–1 SOV per confirmed tx
  operator_reserve_draw_cap:     { key: 'operator_reserve_draw_cap',    min: 0,     max: 500000000000 }, // 0–500,000 SOV/month
  platform_register_fee:         { key: 'platform_register_fee',        min: 0,     max: 1000  },        // SOV, paid by the PLATFORM OWNER
  platform_fee_period_days:      { key: 'platform_fee_period_days',     min: 30,    max: 3650  },        // registration validity — ANNUAL by king directive 2026-07-19
  // Justice
  dispute_bond_amount:           { key: 'dispute_bond_amount',          min: 0,     max: 10000 },
  justice_jury_size:             { key: 'justice_jury_size',            min: 3,     max: 21    },
  justice_min_jury_size:         { key: 'justice_min_jury_size',        min: 1,     max: 11    },
  justice_response_window_hours: { key: 'justice_response_window_hours',min: 1,     max: 720   },
  justice_conviction_threshold:  { key: 'justice_conviction_threshold', min: 0.51,  max: 0.99  },
  // Guardian recovery
  guardian_approval_threshold:   { key: 'guardian_approval_threshold',  min: 1,     max: 10    },
  guardian_max_count:            { key: 'guardian_max_count',           min: 1,     max: 20    },
  guardian_recovery_window_hours:{ key: 'guardian_recovery_window_hours',min: 12,   max: 720   },
  // Social
  message_retention_days:        { key: 'message_retention_days',       min: 7,     max: 365   },
  academy_article_bond:          { key: 'academy_article_bond',         min: 0,     max: 10000 },
  academy_max_article_size_kb:   { key: 'academy_max_article_size_kb',  min: 5,     max: 10240 },
  academy_upvote_bond:           { key: 'academy_upvote_bond',          min: 0,     max: 1000  },
  // Groups
  group_max_members:             { key: 'group_max_members',            min: 2,     max: 1000  },
  group_message_retention_days:  { key: 'group_message_retention_days', min: 7,     max: 365   },
  // Calls
  // Protocol retention
  tx_retention_days:             { key: 'tx_retention_days',            min: 7,     max: 365   },
  // Login session
  sov_login_session_duration_hours: { key: 'sov_login_session_duration_hours', min: 1, max: 720 },
  sov_login_max_sessions:        { key: 'sov_login_max_sessions',       min: 1,     max: 100   },
  // Release integrity (Layer 2). These were seeded and read by the code but were NOT
  // in this map, so citizens could not vote on them — only someone with node DB access
  // could change them. `release_enforce_mode` decides whether the network REFUSES a node
  // running unrecognised source, which is exactly the kind of switch that must not be an
  // operator-only lever once the founder steps back to being an ordinary citizen.
  release_enforce_mode:          { key: 'release_enforce_mode',   values: ['warn', 'refuse'] },
  release_dispute_threshold:     { key: 'release_dispute_threshold',    min: 1,     max: 21    },
  release_signer_min_uptime_days:{ key: 'release_signer_min_uptime_days', min: 0,   max: 365   },
};

// Full set of default values for all params — seeded if not already present
const PARAM_DEFAULTS = [
  ['quorum_threshold',              '0.10'],
  ['min_poll_duration',             '1440'],
  ['max_poll_duration',             '10080'],
  ['poll_retention_days',           '30'],
  ['re_proposal_cooldown_days',     '7'],
  ['petition_threshold_pct',        '0.33'],
  ['petition_supermajority_pct',    '0.67'],
  ['governance_version',            '0'],
  ['sov_enclave',                   '1'],
  ['sov_login',                     '1'],
  ['tx_fee_rate',                   '0.001'],   // 0.1% (king 2026-07-19)
  ['tx_fee_max_sov',                '1'],       // hard cap 1 SOV per transfer
  ['sov_issuance_rate',             '0'],
  ['issuance_epoch_hours',          '24'],
  ['issuance_max_backlog_epochs',   '7'],
  ['exchange_network_fee',          '0.01'],
  ['exchange_max_order_sov',        '10000'],
  ['relay_join_min_stake',          '0'],   // king's design: no join stake (param kept but unused)
  ['operator_min_uptime_days',      '21'],  // continuous days required to earn the monthly payout
  ['operator_signup_sample',        '5'],
  ['tx_signature_enforce',          'log'],   // 'log' until real traffic proves the payload hash agrees, then 'reject'   // ask 5 peers, not the whole network — cost stays flat as the network grows
  ['operator_signup_quorum',        '3'],   // 3 must agree, so one dishonest interrogator cannot admit a node
  ['operator_uptime_reward',        '20000000'],    // 20 SOV per qualifying relay per 30-day period
  ['operator_tx_reward',            '0'],           // seeds per confirmed tx (launches at 0)
  ['operator_reserve_draw_cap',     '50000000000'], // 50,000 SOV/month max reserve draw
  ['platform_register_fee',         '10'],          // SOV paid by a platform owner to integrate SOV Login
  ['platform_fee_period_days',      '365'],         // annual renewal (king directive 2026-07-19)
  ['relay_max_citizens',            '100000'],
  ['dispute_bond_amount',           '10'],
  ['justice_jury_size',             '7'],
  ['justice_min_jury_size',         '3'],
  ['justice_response_window_hours', '48'],
  ['justice_conviction_threshold',  '0.67'],
  ['guardian_approval_threshold',   '2'],
  ['guardian_max_count',            '5'],
  ['guardian_recovery_window_hours','72'],
  ['message_retention_days',        '90'],
  ['academy_article_bond',          '5'],
  ['academy_max_article_size_kb',   '50'],
  ['academy_upvote_bond',           '1'],
  ['group_max_members',             '50'],
  ['group_message_retention_days',  '90'],
  ['tx_retention_days',             '90'],
  ['sov_login_session_duration_hours', '24'],
  ['sov_login_max_sessions',        '5'],
];

class GovernanceEngine {

  constructor(identity, db, peerMesh) {
    this._identity = identity;
    this._db       = db;
    this._peerMesh = peerMesh;
    this._gateway  = null;

    this._initGovernanceTables();
    this._seedDefaults();

    // Register peer mesh handlers
    peerMesh.on('POLL_CREATE_BROADCAST',        (msg) => this._handlePollCreateBroadcast(msg));
    peerMesh.on('POLL_VOTE_BROADCAST',          (msg) => this._handlePollVoteBroadcast(msg));
    peerMesh.on('POLL_CLOSE_BROADCAST',         (msg) => this._handlePollCloseBroadcast(msg));
    peerMesh.on('GOVERNANCE_PARAM_ACTIVATED',   (msg) => this._handleParamActivatedBroadcast(msg));
    peerMesh.on('PETITION_BROADCAST',           (msg) => this._handlePetitionBroadcast(msg));
    peerMesh.on('PETITION_SIG_BROADCAST',       (msg) => this._handlePetitionSigBroadcast(msg));
    peerMesh.on('GOVERNANCE_STATE_REQUEST',     (msg) => this._handleStateRequest(msg));
    peerMesh.on('GOVERNANCE_STATE_RESPONSE',    (msg) => this._handleStateResponse(msg));

    // 60-second poll close check
    setInterval(() => this._checkAndCloseExpiredPolls(), 60 * 1000);

    // Hourly cleanup
    setTimeout(() => this._cleanupOldPolls(), 30 * 1000);   // 30s startup delay
    setInterval(() => this._cleanupOldPolls(), 60 * 60 * 1000);

    // Request governance state from peers on startup (15-second delay)
    setTimeout(() => {
      peerMesh.broadcast('GOVERNANCE_STATE_REQUEST', { node_id: identity.nodeId });
    }, 15000);
    // Periodic re-pull so a param activated while this node was up converges without a restart.
    setInterval(() => { try { peerMesh.broadcast('GOVERNANCE_STATE_REQUEST', { node_id: identity.nodeId }); } catch (_) {} }, 5 * 60 * 1000);

    global.sovLog.info('      ✓ Governance engine initialised');
  }

  setGateway(gateway) {
    this._gateway = gateway;
  }

  // ── Table initialisation ──────────────────────────────────────────────────

  _initGovernanceTables() {
    this._db._db.exec(`

      CREATE TABLE IF NOT EXISTS sov_polls (
        poll_id       TEXT PRIMARY KEY,
        tag           TEXT NOT NULL,               -- constitution tag (maps to param_key)
        title         TEXT NOT NULL,
        description   TEXT NOT NULL DEFAULT '',
        options       TEXT NOT NULL,               -- JSON array of option strings
        created_by    TEXT NOT NULL,
        created_at    INTEGER NOT NULL,
        closes_at     INTEGER NOT NULL,
        closed_at     INTEGER NOT NULL DEFAULT 0,
        status        TEXT NOT NULL DEFAULT 'open', -- open | closed | expired
        direction     TEXT NOT NULL DEFAULT 'activate', -- activate | deactivate
        tally         TEXT NOT NULL DEFAULT '{}',  -- JSON { option: count }
        quorum_required INTEGER NOT NULL DEFAULT 0 -- enrolled citizens needed
      );
      CREATE INDEX IF NOT EXISTS idx_poll_status ON sov_polls(status);
      CREATE INDEX IF NOT EXISTS idx_poll_tag    ON sov_polls(tag);

      CREATE TABLE IF NOT EXISTS sov_poll_votes (
        poll_id       TEXT NOT NULL,
        voter_id      TEXT NOT NULL,
        option_text   TEXT NOT NULL,               -- the option string they chose
        voted_at      INTEGER NOT NULL,
        PRIMARY KEY (poll_id, voter_id)
      );
      CREATE INDEX IF NOT EXISTS idx_vote_poll ON sov_poll_votes(poll_id);

      CREATE TABLE IF NOT EXISTS sov_governance_params (
        param_key     TEXT PRIMARY KEY,
        param_value   TEXT NOT NULL,
        activated_at  INTEGER NOT NULL DEFAULT 0
      );

      CREATE TABLE IF NOT EXISTS sov_petitions (
        petition_id     TEXT PRIMARY KEY,
        param_key       TEXT NOT NULL,
        direction       TEXT NOT NULL DEFAULT 'activate',
        title           TEXT NOT NULL,
        description     TEXT NOT NULL DEFAULT '',
        created_by      TEXT NOT NULL,
        created_at      INTEGER NOT NULL,
        expires_at      INTEGER NOT NULL,
        status          TEXT NOT NULL DEFAULT 'open',
        signature_count INTEGER NOT NULL DEFAULT 0
      );

      CREATE TABLE IF NOT EXISTS sov_petition_signatures (
        petition_id   TEXT NOT NULL,
        signer_id     TEXT NOT NULL,
        signed_at     INTEGER NOT NULL,
        PRIMARY KEY (petition_id, signer_id)
      );
      CREATE INDEX IF NOT EXISTS idx_pet_sig ON sov_petition_signatures(petition_id);

      -- SOV Value Oracle: citizen price proposals + computed supply rate
      CREATE TABLE IF NOT EXISTS sov_value_proposals (
        sovereign_id  TEXT    NOT NULL,
        proposed_usd  REAL    NOT NULL,
        epoch         INTEGER NOT NULL,
        submitted_at  INTEGER NOT NULL,
        PRIMARY KEY (sovereign_id, epoch)
      );

      CREATE TABLE IF NOT EXISTS sov_supply (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        sov_usd_rate REAL    NOT NULL,
        vote_count   INTEGER NOT NULL DEFAULT 0,
        epoch        INTEGER NOT NULL,
        computed_at  INTEGER NOT NULL
      );

    `);
  }

  _seedDefaults() {
    const insert = this._db._db.prepare(`
      INSERT OR IGNORE INTO sov_governance_params (param_key, param_value, activated_at)
      VALUES (?, ?, 0)
    `);
    for (const [key, val] of PARAM_DEFAULTS) {
      insert.run(key, val);
    }
  }

  // ── Public helper — read a governance param (always returns string) ────────
  // CRITICAL: never call Number() on the return value for binary gate checks.

  _getGovParam(key, fallback = '0') {
    const row = this._db._db.prepare(
      'SELECT param_value FROM sov_governance_params WHERE param_key = ?'
    ).get(key);
    return row ? row.param_value.toString() : fallback.toString();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  POLLS
  // ═══════════════════════════════════════════════════════════════════════════

  handlePollCreate(ws, msg) {
    const { poll_id, tag, title, description, options, duration_minutes, direction } = msg;
    const citizen_id = ws._sovereignId;

    if (ws._legacyMode) { this._send(ws, 'PD', { success: false, error: 'SIGNATURE_REQUIRED' }); return; }

    if (!poll_id || !tag || !title || !options || !Array.isArray(options) || options.length < 2) {
      this._send(ws, 'PD', { success: false, error: 'MISSING_FIELDS' });
      return;
    }

    if (options.length > 10) {
      this._send(ws, 'PD', { success: false, error: 'TOO_MANY_OPTIONS' });
      return;
    }

    // Validate tag is known
    if (!PARAM_MAP[tag]) {
      this._send(ws, 'PD', { success: false, error: 'UNKNOWN_TAG' });
      return;
    }

    // Re-proposal cooldown: check when tag last had a closed poll
    const cooldownDays = parseFloat(this._getGovParam('re_proposal_cooldown_days', '7'));
    const cooldownMs   = cooldownDays * 24 * 60 * 60 * 1000;
    const lastClosed   = this._db._db.prepare(`
      SELECT closed_at FROM sov_polls
      WHERE tag = ? AND status = 'closed' AND closed_at > 0
      ORDER BY closed_at DESC LIMIT 1
    `).get(tag);

    if (lastClosed && (Date.now() - lastClosed.closed_at) < cooldownMs) {
      const daysLeft = Math.ceil((cooldownMs - (Date.now() - lastClosed.closed_at)) / 86400000);
      this._send(ws, 'PD', { success: false, error: 'COOLDOWN_ACTIVE', days_remaining: daysLeft });
      return;
    }

    // V44: one open poll per tag — if a propose is repeated (e.g. the app's
    // reconnect-retry re-sends POLL_CREATE), return the EXISTING open poll as a
    // success instead of stacking a duplicate. Duplicate polls for one tag put
    // two identical voteOption_N widgets on screen (ambiguous taps) and split
    // the vote. Idempotent propose.
    const openExisting = this._db._db.prepare(
      "SELECT * FROM sov_polls WHERE tag = ? AND status = 'open'"
    ).get(tag);
    if (openExisting) {
      this._send(ws, 'PD', { type: 'POLL_CREATED', success: true, already_open: true, poll: this._formatPoll(openExisting) });
      return;
    }

    // Validate duration
    const minDuration = parseInt(this._getGovParam('min_poll_duration', '1440'));
    const maxDuration = parseInt(this._getGovParam('max_poll_duration', '10080'));
    const durationMins = Math.min(Math.max(parseInt(duration_minutes) || minDuration, minDuration), maxDuration);
    const now      = Date.now();
    const closesAt = now + durationMins * 60 * 1000;

    // Quorum: need N% of enrolled citizens to vote for binding result
    const quorumPct      = parseFloat(this._getGovParam('quorum_threshold', '0.10'));
    const enrolledCount  = this._enrolledCitizenCount();
    const quorumRequired = Math.ceil(enrolledCount * quorumPct);

    try {
      this._db._db.prepare(`
        INSERT OR IGNORE INTO sov_polls
          (poll_id, tag, title, description, options, created_by, created_at, closes_at, status, direction, tally, quorum_required)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'open', ?, ?, ?)
      `).run(
        poll_id, tag, title, description || '', JSON.stringify(options),
        citizen_id, now, closesAt,
        direction || 'activate',
        JSON.stringify({}),
        quorumRequired
      );
    } catch (e) {
      this._send(ws, 'PD', { success: false, error: 'POLL_ID_EXISTS' });
      return;
    }

    const poll = this._db._db.prepare('SELECT * FROM sov_polls WHERE poll_id = ?').get(poll_id);
    // V41: carry explicit type so the app's sendAndWait('POLL_CREATED') matches —
    // op 'PD' otherwise decodes to PALM_DUPLICATE_CHECK (response-contract collision).
    this._send(ws, 'PD', { type: 'POLL_CREATED', success: true, poll: this._formatPoll(poll) });

    // V39 fix: replicate the poll to peer nodes on creation so every node holds
    // the poll row. Without this, POLL_VOTE_BROADCAST is dropped by peers (no
    // local poll), cross-node citizens get POLL_NOT_FOUND, and an open poll is
    // lost if its host node dies. Peers _handlePollCreateBroadcast → INSERT OR
    // IGNORE. (Petitions already replicate on create; polls were the outlier.)
    this._peerMesh.broadcast('POLL_CREATE_BROADCAST', {
      poll, node_id: this._identity.nodeId,
    });

    global.sovLog.info(`Governance poll created: ${tag} "${title}" by ${citizen_id}`);
  }

  handlePollVote(ws, msg) {
    const { poll_id, option } = msg;
    const voter_id = ws._sovereignId;

    if (ws._legacyMode) { this._send(ws, 'PV', { success: false, error: 'SIGNATURE_REQUIRED' }); return; }

    if (!poll_id || !option) {
      this._send(ws, 'PV', { success: false, error: 'MISSING_FIELDS' });
      return;
    }

    const poll = this._db._db.prepare('SELECT * FROM sov_polls WHERE poll_id = ?').get(poll_id);
    if (!poll) {
      this._send(ws, 'PV', { success: false, error: 'POLL_NOT_FOUND' });
      return;
    }
    if (poll.status !== 'open') {
      this._send(ws, 'PV', { success: false, error: 'POLL_CLOSED' });
      return;
    }
    if (poll.closes_at < Date.now()) {
      this._send(ws, 'PV', { success: false, error: 'POLL_EXPIRED' });
      return;
    }

    const validOptions = JSON.parse(poll.options);
    if (!validOptions.includes(option)) {
      this._send(ws, 'PV', { success: false, error: 'INVALID_OPTION' });
      return;
    }

    // INSERT OR IGNORE — one vote per citizen
    const result = this._db._db.prepare(`
      INSERT OR IGNORE INTO sov_poll_votes (poll_id, voter_id, option_text, voted_at)
      VALUES (?, ?, ?, ?)
    `).run(poll_id, voter_id, option, Date.now());

    if (result.changes === 0) {
      this._send(ws, 'PV', { success: false, error: 'ALREADY_VOTED' });
      return;
    }

    // Update live tally
    const tally = this._getTally(poll_id);
    this._db._db.prepare('UPDATE sov_polls SET tally = ? WHERE poll_id = ?')
      .run(JSON.stringify(tally), poll_id);

    this._send(ws, 'PV', { type: 'POLL_VOTE_RECORDED', success: true, poll_id, tally });

    // Push live tally update to all connected citizens.
    // V43: send tally as an option-aligned List<int> (the card does
    // List<int>.from(poll['tally'])) — a keyed map would throw on rebuild.
    if (this._gateway) {
      const tallyList   = validOptions.map(o => tally[o] || 0);
      const totalVotes  = tallyList.reduce((s, c) => s + c, 0);
      this._gateway.pushToAll('PU', { poll_id, tally: tallyList, total_votes: totalVotes });
    }

    // Broadcast vote to peer nodes
    this._peerMesh.broadcast('POLL_VOTE_BROADCAST', {
      poll_id, voter_id, option, voted_at: Date.now(),
      node_id: this._identity.nodeId,
    });
  }

  handlePollList(ws, msg) {
    const { status, limit } = msg;
    const rows = this._db._db.prepare(`
      SELECT * FROM sov_polls
      WHERE status = ?
      ORDER BY created_at DESC
      LIMIT ?
    `).all(status || 'open', Math.min(limit || 50, 200));

    // V42: carry explicit type + success so the app's sendAndWait('POLL_LIST_RESULT')
    // matches and `activeResp?['success'] == true` passes. Op 'PL' otherwise decodes
    // to the request type 'POLL_LIST' (not '..._RESULT') — the response-contract
    // collision that left the Votes tab perpetually empty (never rendered a poll).
    this._send(ws, 'PL', { type: 'POLL_LIST_RESULT', success: true, polls: rows.map(r => this._formatPoll(r)), ts: Date.now() });
  }

  handlePollGet(ws, msg) {
    const { poll_id } = msg;
    if (!poll_id) return;

    const poll = this._db._db.prepare('SELECT * FROM sov_polls WHERE poll_id = ?').get(poll_id);
    if (!poll) {
      this._send(ws, 'PG', { success: false, error: 'POLL_NOT_FOUND' });
      return;
    }
    this._send(ws, 'PG', { success: true, poll: this._formatPoll(poll) });
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  PETITIONS
  // ═══════════════════════════════════════════════════════════════════════════

  handlePetitionCreate(ws, msg) {
    const { petition_id, param_key, direction, title, description } = msg;
    const citizen_id = ws._sovereignId;

    if (ws._legacyMode) { this._send(ws, 'ED', { type: 'PETITION_RESULT', success: false, error: 'SIGNATURE_REQUIRED' }); return; }

    if (!petition_id || !param_key || !title) {
      this._send(ws, 'ED', { type: 'PETITION_RESULT', success: false, error: 'MISSING_FIELDS' });
      return;
    }

    if (!PARAM_MAP[param_key]) {
      this._send(ws, 'ED', { type: 'PETITION_RESULT', success: false, error: 'UNKNOWN_PARAM' });
      return;
    }

    const now       = Date.now();
    const expiresAt = now + 30 * 24 * 60 * 60 * 1000;  // 30 days

    try {
      this._db._db.prepare(`
        INSERT OR IGNORE INTO sov_petitions
          (petition_id, param_key, direction, title, description, created_by, created_at, expires_at, status, signature_count)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'open', 0)
      `).run(petition_id, param_key, direction || 'activate', title, description || '', citizen_id, now, expiresAt);
    } catch (_) {}

    const pet = this._db._db.prepare('SELECT * FROM sov_petitions WHERE petition_id = ?').get(petition_id);
    // V45: explicit type — op 'ED' has NO app-side mapping, so without this the
    // app's sendAndWait('PETITION_RESULT') never matches → create times out (same
    // response-contract bug class as governance polls V41/V42).
    this._send(ws, 'ED', { type: 'PETITION_RESULT', success: true, petition: pet, enrolled: this._enrolledCitizenCount() });

    // Broadcast to peers
    this._peerMesh.broadcast('PETITION_BROADCAST', { petition: pet, node_id: this._identity.nodeId });
  }

  handlePetitionSign(ws, msg) {
    const { petition_id } = msg;
    const signer_id = ws._sovereignId;

    if (ws._legacyMode) { this._send(ws, 'ES', { type: 'PETITION_SIGN_RESULT', success: false, error: 'SIGNATURE_REQUIRED' }); return; }

    if (!petition_id) return;

    const pet = this._db._db.prepare('SELECT * FROM sov_petitions WHERE petition_id = ?').get(petition_id);
    if (!pet) {
      this._send(ws, 'ES', { type: 'PETITION_SIGN_RESULT', success: false, error: 'PETITION_NOT_FOUND' });
      return;
    }
    if (pet.status !== 'open' || pet.expires_at < Date.now()) {
      this._send(ws, 'ES', { type: 'PETITION_SIGN_RESULT', success: false, error: 'PETITION_CLOSED' });
      return;
    }

    // INSERT OR IGNORE — one signature per citizen
    const result = this._db._db.prepare(`
      INSERT OR IGNORE INTO sov_petition_signatures (petition_id, signer_id, signed_at)
      VALUES (?, ?, ?)
    `).run(petition_id, signer_id, Date.now());

    if (result.changes === 0) {
      this._send(ws, 'ES', { type: 'PETITION_SIGN_RESULT', success: false, error: 'ALREADY_SIGNED' });
      return;
    }

    // Update signature count
    this._db._db.prepare(`
      UPDATE sov_petitions SET signature_count = signature_count + 1 WHERE petition_id = ?
    `).run(petition_id);

    const updated = this._db._db.prepare('SELECT * FROM sov_petitions WHERE petition_id = ?').get(petition_id);
    // V45: explicit type — op 'ES' decodes app-side to 'PETITION_SIGN' (the request
    // type), not 'PETITION_SIGN_RESULT' → without this the sign never confirms.
    this._send(ws, 'ES', { type: 'PETITION_SIGN_RESULT', success: true, petition_id, signature_count: updated.signature_count, enrolled: this._enrolledCitizenCount() });

    // Broadcast signature to peers
    this._peerMesh.broadcast('PETITION_SIG_BROADCAST', {
      petition_id, signer_id, signed_at: Date.now(),
      node_id: this._identity.nodeId,
    });

    // Check thresholds
    this._checkPetitionThresholds(updated);
  }

  handlePetitionList(ws, msg) {
    const rows = this._db._db.prepare(`
      SELECT * FROM sov_petitions WHERE status = 'open' AND expires_at > ?
      ORDER BY created_at DESC LIMIT 50
    `).all(Date.now());

    // V45: explicit type + enrolled — op 'EL' decodes to 'PETITION_LIST' not
    // 'PETITION_LIST_RESULT' → without this the Petitions tab never loads (empty).
    // enrolled drives the signature-threshold display in the app.
    this._send(ws, 'EL', { type: 'PETITION_LIST_RESULT', success: true, petitions: rows, enrolled: this._enrolledCitizenCount(), ts: Date.now() });
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  GOVERNANCE PARAMS
  // ═══════════════════════════════════════════════════════════════════════════

  handleGovParamGet(ws, msg) {
    const { param_key } = msg;
    if (!param_key) return;

    const value = this._getGovParam(param_key, null);
    this._send(ws, 'KR', { param_key, param_value: value, ts: Date.now() });
  }

  handleGovParamsAll(ws, msg) {
    const rows = this._db._db.prepare('SELECT * FROM sov_governance_params').all();
    const params = {};
    for (const row of rows) params[row.param_key] = row.param_value;
    this._send(ws, 'KA', { params, ts: Date.now() });
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  POLL CLOSE TIMER — runs every 60 seconds
  // ═══════════════════════════════════════════════════════════════════════════

  _checkAndCloseExpiredPolls() {
    const now      = Date.now();
    const expiredPolls = this._db._db.prepare(`
      SELECT * FROM sov_polls WHERE status = 'open' AND closes_at <= ?
    `).all(now);

    for (const poll of expiredPolls) {
      this._closePoll(poll);
    }
  }

  _closePoll(poll) {
    const tally          = this._getTally(poll.poll_id);
    const totalVotes     = Object.values(tally).reduce((s, c) => s + c, 0);
    const quorumMet      = totalVotes >= poll.quorum_required;
    const now            = Date.now();

    // Determine winner (highest vote count)
    let winner      = null;
    let maxCount    = 0;
    for (const [opt, count] of Object.entries(tally)) {
      if (count > maxCount) { maxCount = count; winner = opt; }
    }

    this._db._db.prepare(`
      UPDATE sov_polls SET status = 'closed', closed_at = ?, tally = ? WHERE poll_id = ?
    `).run(now, JSON.stringify(tally), poll.poll_id);

    if (quorumMet && winner) {
      this._activateGovernanceParam(poll.tag, winner, poll.direction);
    }

    // Push close event to all connected citizens
    if (this._gateway) {
      this._gateway.pushToAll('PC', {    // POLL_CLOSED
        poll_id:   poll.poll_id,
        tag:       poll.tag,
        winner,
        quorum_met: quorumMet,
        total_votes: totalVotes,
        tally,
        ts:        now,
      });
    }

    // Broadcast close to peers
    this._peerMesh.broadcast('POLL_CLOSE_BROADCAST', {
      poll_id:     poll.poll_id,
      tag:         poll.tag,
      direction:   poll.direction,
      winner,
      quorum_met:  quorumMet,
      total_votes: totalVotes,
      tally,
      closed_at:   now,
      node_id:     this._identity.nodeId,
    });

    global.sovLog.info(`Poll closed: ${poll.tag} winner=${winner || 'none'} quorum=${quorumMet}`);
  }

  // ── Param activation ──────────────────────────────────────────────────────

  _activateGovernanceParam(tag, winningOption, direction) {
    const paramSpec = PARAM_MAP[tag];
    if (!paramSpec) {
      // Silent returns here are dangerous: the poll closes, citizens believe they voted
      // a change through, and nothing happens anywhere. Say so.
      global.sovLog.warn(`[Gov] Poll '${tag}' closed but there is no PARAM_MAP entry — NOTHING was applied.`);
      return;
    }

    let newValue;

    if (paramSpec.values) {
      // Enumerated string param (e.g. release_enforce_mode: warn|refuse). Added because
      // the activator previously handled only `binary` and numeric, so a string option
      // fell through to parseFloat() -> NaN -> silent return: a vote that appeared to
      // succeed and changed nothing. Match case-insensitively, store the canonical form.
      const opt   = String(winningOption == null ? '' : winningOption).trim().toLowerCase();
      const match = paramSpec.values.find(v => v.toLowerCase() === opt);
      if (!match) {
        global.sovLog.warn(
          `[Gov] Poll '${tag}' won with '${winningOption}', which is not one of ` +
          `[${paramSpec.values.join(', ')}] — NOT applied.`);
        return;
      }
      newValue = match;
    } else if (paramSpec.binary) {
      // Binary gate: direction decides 1 or 0
      // Deactivation wins when direction is 'deactivate' and winning option is
      // 'Deactivate', 'Yes', 'Approve', or any variant matching these keywords
      const deactivateWords = ['deactivate', 'no', 'reject', 'keep dormant', 'dormant'];
      const isDeactivation  = direction === 'deactivate' ||
        deactivateWords.some(w => winningOption.toLowerCase().includes(w));
      newValue = isDeactivation ? '0' : '1';
    } else {
      // Numeric/percentage param: winning option IS the new value
      const numVal = parseFloat(winningOption);
      if (isNaN(numVal)) {
        global.sovLog.warn(`[Gov] Poll '${tag}' won with non-numeric '${winningOption}' — NOT applied.`);
        return;
      }

      // Range validation
      if (paramSpec.min !== undefined && numVal < paramSpec.min) {
        global.sovLog.warn(`[Gov] Poll '${tag}' value ${numVal} below min ${paramSpec.min} — NOT applied.`);
        return;
      }
      if (paramSpec.max !== undefined && numVal > paramSpec.max) {
        global.sovLog.warn(`[Gov] Poll '${tag}' value ${numVal} above max ${paramSpec.max} — NOT applied.`);
        return;
      }
      newValue = String(numVal);
    }

    const now = Date.now();
    this._db._db.prepare(`
      INSERT INTO sov_governance_params (param_key, param_value, activated_at)
      VALUES (?, ?, ?)
      ON CONFLICT (param_key) DO UPDATE SET param_value = excluded.param_value, activated_at = excluded.activated_at
    `).run(paramSpec.key, newValue, now);

    // Increment governance_version (meta param tracking all changes)
    const currentVersion = parseInt(this._getGovParam('governance_version', '0'));
    this._db._db.prepare(`
      INSERT INTO sov_governance_params (param_key, param_value, activated_at) VALUES ('governance_version', ?, ?)
      ON CONFLICT (param_key) DO UPDATE SET param_value = excluded.param_value, activated_at = excluded.activated_at
    `).run(String(currentVersion + 1), now);

    // Push to all connected citizens
    if (this._gateway) {
      this._gateway.pushToAll('KE', {   // GOVERNANCE_PARAM_ACTIVATED (push)
        param_key: paramSpec.key, param_value: newValue, activated_at: now,
      });
    }

    // Broadcast to peers
    this._peerMesh.broadcast('GOVERNANCE_PARAM_ACTIVATED', {
      param_key:   paramSpec.key,
      param_value: newValue,
      activated_at: now,
      node_id:     this._identity.nodeId,
    });

    global.sovLog.info(`Governance param activated: ${paramSpec.key} = ${newValue}`);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  PETITION THRESHOLD CHECKS
  // ═══════════════════════════════════════════════════════════════════════════

  _checkPetitionThresholds(petition) {
    // V21 fix: skip petitions already acted upon — prevents re-firing supermajority activation
    if (petition.status !== 'open') return;

    const enrolled        = this._enrolledCitizenCount();
    if (enrolled === 0) return;

    const sigCount        = petition.signature_count;
    const petThreshold    = parseFloat(this._getGovParam('petition_threshold_pct', '0.33'));
    const superMajority   = parseFloat(this._getGovParam('petition_supermajority_pct', '0.67'));
    const sigPct          = sigCount / enrolled;

    if (sigPct >= superMajority) {
      // Supermajority: directly flip the param
      const paramSpec = PARAM_MAP[petition.param_key];
      if (paramSpec) {
        const newValue = petition.direction === 'deactivate' ? '0' : '1';
        if (paramSpec.binary) {
          this._db._db.prepare(`
            INSERT INTO sov_governance_params (param_key, param_value, activated_at) VALUES (?, ?, ?)
            ON CONFLICT (param_key) DO UPDATE SET param_value = excluded.param_value, activated_at = excluded.activated_at
          `).run(paramSpec.key, newValue, Date.now());

          if (this._gateway) {
            this._gateway.pushToAll('KE', { param_key: paramSpec.key, param_value: newValue, activated_at: Date.now() });
          }
          this._peerMesh.broadcast('GOVERNANCE_PARAM_ACTIVATED', {
            param_key: paramSpec.key, param_value: newValue, activated_at: Date.now(),
            node_id: this._identity.nodeId,
          });
        }
      }
      this._db._db.prepare(`UPDATE sov_petitions SET status = 'direct_activation' WHERE petition_id = ?`)
        .run(petition.petition_id);
      global.sovLog.info(`Petition ${petition.petition_id} reached supermajority — direct activation`);
      return;
    }

    if (sigPct >= petThreshold) {
      // Threshold reached: auto-create a governance poll
      const pollId  = `pet-${petition.petition_id}-${Date.now()}`;
      const options = petition.direction === 'deactivate'
        ? ['Deactivate', 'Keep Active']
        : ['Activate', 'Keep Dormant'];

      const minDuration    = parseInt(this._getGovParam('min_poll_duration', '1440'));
      const enrolled_count = this._enrolledCitizenCount();
      const quorumPct      = parseFloat(this._getGovParam('quorum_threshold', '0.10'));
      const now            = Date.now();

      this._db._db.prepare(`
        INSERT OR IGNORE INTO sov_polls
          (poll_id, tag, title, description, options, created_by, created_at, closes_at, status, direction, tally, quorum_required)
        VALUES (?, ?, ?, ?, ?, 'PETITION', ?, ?, 'open', ?, '{}', ?)
      `).run(
        pollId, petition.param_key,
        `[Petition] ${petition.title}`,
        `Forced by citizen petition with ${sigCount} signatures (${(sigPct * 100).toFixed(1)}% of enrolled)`,
        JSON.stringify(options), now,
        now + minDuration * 60 * 1000,
        petition.direction,
        Math.ceil(enrolled_count * quorumPct)
      );

      this._db._db.prepare(`UPDATE sov_petitions SET status = 'poll_triggered' WHERE petition_id = ?`)
        .run(petition.petition_id);

      global.sovLog.info(`Petition ${petition.petition_id} triggered poll ${pollId}`);
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  PEER MESH HANDLERS
  // ═══════════════════════════════════════════════════════════════════════════

  // V39 fix: replicate a peer-created poll locally so this node holds the poll
  // row (enables vote replication, cross-node voting, and independent tally).
  _handlePollCreateBroadcast(msg) {
    const { poll, node_id } = msg;
    if (node_id === this._identity.nodeId || !poll || !poll.poll_id) return;
    // Validate: tag must be a known governable param; options must be valid JSON;
    // closes_at must be a sane future-ish epoch. Guards against malicious peers.
    if (!PARAM_MAP[poll.tag]) return;
    try { JSON.parse(poll.options); } catch (_) { return; }
    if (typeof poll.closes_at !== 'number' || poll.closes_at <= 0) return;
    try {
      this._db._db.prepare(`
        INSERT OR IGNORE INTO sov_polls
          (poll_id, tag, title, description, options, created_by, created_at, closes_at, closed_at, status, direction, tally, quorum_required)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      `).run(
        poll.poll_id, poll.tag, poll.title || '', poll.description || '',
        poll.options, poll.created_by || '', poll.created_at || Date.now(),
        poll.closes_at, poll.closed_at || 0, poll.status || 'open',
        poll.direction || 'activate', poll.tally || '{}', poll.quorum_required || 0
      );
      global.sovLog.info(`Poll replicated from peer: ${poll.tag} (${poll.poll_id})`);
    } catch (_) {}
  }

  _handlePollVoteBroadcast(msg) {
    const { poll_id, voter_id, option, voted_at, node_id } = msg;
    if (node_id === this._identity.nodeId) return;
    if (!poll_id || !voter_id || !option) return;

    // V38 fix: verify voter is actually enrolled — prevents fabricated votes from malicious peers
    const isEnrolled = this._db._db.prepare('SELECT 1 FROM sov_enrollments WHERE sovereign_id = ?').get(voter_id);
    if (!isEnrolled) return;

    // Only insert if poll exists and is open
    const poll = this._db._db.prepare('SELECT * FROM sov_polls WHERE poll_id = ? AND status = ?').get(poll_id, 'open');
    if (!poll) return;

    const result = this._db._db.prepare(`
      INSERT OR IGNORE INTO sov_poll_votes (poll_id, voter_id, option_text, voted_at) VALUES (?, ?, ?, ?)
    `).run(poll_id, voter_id, option, voted_at || Date.now());

    if (result.changes > 0) {
      const tally = this._getTally(poll_id);
      this._db._db.prepare('UPDATE sov_polls SET tally = ? WHERE poll_id = ?')
        .run(JSON.stringify(tally), poll_id);
    }
  }

  _handlePollCloseBroadcast(msg) {
    const { poll_id, closed_at, tally, winner, quorum_met } = msg;
    if (!poll_id) return;

    this._db._db.prepare(`
      UPDATE sov_polls SET status = 'closed', closed_at = ?, tally = ? WHERE poll_id = ? AND status = 'open'
    `).run(closed_at || Date.now(), tally ? JSON.stringify(tally) : '{}', poll_id);
  }

  _handleParamActivatedBroadcast(msg) {
    const { param_key, param_value, activated_at, node_id } = msg;
    if (node_id === this._identity.nodeId) return;
    if (!param_key || param_value === undefined) return;

    this._db._db.prepare(`
      INSERT INTO sov_governance_params (param_key, param_value, activated_at) VALUES (?, ?, ?)
      ON CONFLICT (param_key) DO UPDATE SET param_value = excluded.param_value, activated_at = excluded.activated_at
      WHERE excluded.activated_at >= sov_governance_params.activated_at
    `).run(param_key, param_value.toString(), activated_at || Date.now());

    global.sovLog.info(`Param sync from peer: ${param_key} = ${param_value}`);
  }

  _handlePetitionBroadcast(msg) {
    const { petition, node_id } = msg;
    if (node_id === this._identity.nodeId || !petition) return;

    try {
      this._db._db.prepare(`
        INSERT OR IGNORE INTO sov_petitions
          (petition_id, param_key, direction, title, description, created_by, created_at, expires_at, status, signature_count)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      `).run(
        petition.petition_id, petition.param_key, petition.direction || 'activate',
        petition.title, petition.description || '', petition.created_by,
        petition.created_at, petition.expires_at, petition.status || 'open',
        0   // V36 fix: always insert with 0 — individual SIG_BROADCASTs increment correctly; never trust peer-supplied count
      );
    } catch (_) {}
  }

  _handlePetitionSigBroadcast(msg) {
    const { petition_id, signer_id, signed_at, node_id } = msg;
    if (node_id === this._identity.nodeId || !petition_id || !signer_id) return;

    const result = this._db._db.prepare(`
      INSERT OR IGNORE INTO sov_petition_signatures (petition_id, signer_id, signed_at)
      VALUES (?, ?, ?)
    `).run(petition_id, signer_id, signed_at || Date.now());

    if (result.changes > 0) {
      this._db._db.prepare(`
        UPDATE sov_petitions SET signature_count = signature_count + 1 WHERE petition_id = ?
      `).run(petition_id);

      const updated = this._db._db.prepare('SELECT * FROM sov_petitions WHERE petition_id = ?').get(petition_id);
      if (updated) this._checkPetitionThresholds(updated);
    }
  }

  _handleStateRequest(msg) {
    // A peer is requesting our governance state (typically on startup)
    const { node_id } = msg;
    if (node_id === this._identity.nodeId) return;

    const params     = this._db._db.prepare('SELECT * FROM sov_governance_params').all();
    const openPolls  = this._db._db.prepare(`SELECT * FROM sov_polls WHERE status = 'open'`).all();

    this._peerMesh.broadcast('GOVERNANCE_STATE_RESPONSE', {
      params,
      open_polls: openPolls,
      node_id: this._identity.nodeId,
    });
  }

  _handleStateResponse(msg) {
    // Apply governance state from a peer — only update params with a NEWER activated_at
    const { params, open_polls, node_id } = msg;
    if (node_id === this._identity.nodeId || !params) return;

    const upsert = this._db._db.prepare(`
      INSERT INTO sov_governance_params (param_key, param_value, activated_at) VALUES (?, ?, ?)
      ON CONFLICT (param_key) DO UPDATE SET param_value = excluded.param_value, activated_at = excluded.activated_at
      WHERE excluded.activated_at > sov_governance_params.activated_at
    `);

    for (const row of params) {
      try {
        // V32 fix: validate param bounds via PARAM_MAP before applying — prevents malicious peers
        // from injecting out-of-range governance values via GOVERNANCE_STATE_RESPONSE
        const spec = PARAM_MAP[row.param_key];
        if (spec) {
          if (spec.binary) {
            if (row.param_value !== '0' && row.param_value !== '1') continue;
          } else {
            const val = parseFloat(row.param_value);
            if (isNaN(val) || val < spec.min || val > spec.max) continue;
          }
        }
        upsert.run(row.param_key, row.param_value.toString(), row.activated_at || 0);
      } catch (_) {}
    }

    // V39 fix: also apply open polls a peer sent us (previously open_polls was
    // included in the response payload but silently ignored here). Lets a node
    // that was offline at poll-creation catch up on reconnect.
    if (Array.isArray(open_polls)) {
      const pollUpsert = this._db._db.prepare(`
        INSERT OR IGNORE INTO sov_polls
          (poll_id, tag, title, description, options, created_by, created_at, closes_at, closed_at, status, direction, tally, quorum_required)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      `);
      for (const poll of open_polls) {
        try {
          if (!poll || !poll.poll_id || !PARAM_MAP[poll.tag]) continue;
          JSON.parse(poll.options);
          if (typeof poll.closes_at !== 'number' || poll.closes_at <= 0) continue;
          pollUpsert.run(
            poll.poll_id, poll.tag, poll.title || '', poll.description || '',
            poll.options, poll.created_by || '', poll.created_at || Date.now(),
            poll.closes_at, poll.closed_at || 0, poll.status || 'open',
            poll.direction || 'activate', poll.tally || '{}', poll.quorum_required || 0
          );
        } catch (_) {}
      }
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  MAINTENANCE
  // ═══════════════════════════════════════════════════════════════════════════

  _cleanupOldPolls() {
    const retentionDays = parseInt(this._getGovParam('poll_retention_days', '30'));
    const cutoff        = Date.now() - retentionDays * 24 * 60 * 60 * 1000;

    const deleted = this._db._db.prepare(`
      DELETE FROM sov_polls WHERE status = 'closed' AND closed_at < ? AND closed_at > 0
    `).run(cutoff);

    if (deleted.changes > 0) {
      global.sovLog.debug(`Governance: pruned ${deleted.changes} old closed polls`);
    }

    // Expire open petitions past their expiry date
    this._db._db.prepare(`
      UPDATE sov_petitions SET status = 'expired' WHERE status = 'open' AND expires_at < ?
    `).run(Date.now());
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  HELPERS
  // ═══════════════════════════════════════════════════════════════════════════

  _getTally(pollId) {
    const votes = this._db._db.prepare(`
      SELECT option_text, COUNT(*) AS cnt FROM sov_poll_votes WHERE poll_id = ? GROUP BY option_text
    `).all(pollId);
    const tally = {};
    for (const row of votes) tally[row.option_text] = row.cnt;
    return tally;
  }

  _enrolledCitizenCount() {
    const row = this._db._db.prepare('SELECT COUNT(*) AS cnt FROM sov_enrollments').get();
    return row ? row.cnt : 0;
  }

  _formatPoll(poll) {
    // V43: emit EXACTLY the field shape the Flutter poll card (_buildPollCard)
    // reads. The card does List<int>.from(poll['tally']) and reads question /
    // close_epoch / quorum_needed — the old shape returned tally as an OBJECT
    // (List.from on a Map throws at runtime → the whole card failed to build →
    // voteOption_N never entered the widget tree → Votes tab looked empty even
    // though the poll loaded). Map the stored {optionText: count} tally to an
    // option-aligned List<int>.
    const optionsArr = JSON.parse(poll.options || '[]');
    const tallyMap   = JSON.parse(poll.tally   || '{}');
    const tallyList  = optionsArr.map(o => tallyMap[o] || 0);
    const totalVotes = tallyList.reduce((s, c) => s + c, 0);
    const quorumNeeded = poll.quorum_required != null ? poll.quorum_required : null;
    return {
      ...poll,
      options:          optionsArr,
      tally:            tallyList,            // List<int> aligned to options (card contract)
      tally_map:        tallyMap,             // keep the keyed map for any map consumer
      total_votes:      totalVotes,
      question:         poll.title,           // card reads poll['question']
      close_epoch:      Math.floor((poll.closes_at || 0) / 60000),
      quorum_needed:    quorumNeeded,
      quorum_reached:   quorumNeeded != null && totalVotes >= quorumNeeded,
      current_value:    this._getGovParam(poll.tag),
      constitution_tag: poll.tag,             // app keys the Constitution active-badge on this
    };
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  SOV VALUE ORACLE  (QS / QV)
  // ═══════════════════════════════════════════════════════════════════════════
  // Citizens vote each epoch on the USD value they perceive for 1 SOV.
  // The median of all proposals in the current epoch is computed and stored
  // in sov_supply.  This lets the app display a community-derived price.

  handleSovValueSubmit(ws, msg) {
    const sovereignId = msg.sovereign_id || ws._sovereignId;
    const proposedUsd = parseFloat(msg.proposed_usd);

    if (!sovereignId || isNaN(proposedUsd) || proposedUsd <= 0) {
      return this._send(ws, 'QV', { type: 'SOV_VALUE_SUBMITTED', success: false, error: 'Invalid fields' });
    }

    try {
      // Only enrolled citizens may vote
      const enrolled = this._db._db.prepare(
        'SELECT enrolled_at FROM sov_enrollments WHERE sovereign_id = ?'
      ).get(sovereignId);

      if (!enrolled) {
        return this._send(ws, 'QV', { type: 'SOV_VALUE_SUBMITTED', success: false, error: 'Not enrolled' });
      }

      const epoch  = Math.floor(Date.now() / 60000);   // one epoch per minute
      const MAX_CAP = 50.0;                              // $50 per SOV cap
      const capped  = Math.min(Math.max(proposedUsd, 0.0001), MAX_CAP);

      // INSERT or UPDATE (one proposal per citizen per epoch)
      try {
        this._db._db.prepare(
          'INSERT INTO sov_value_proposals (sovereign_id, proposed_usd, epoch, submitted_at) VALUES (?, ?, ?, ?)'
        ).run(sovereignId, capped, epoch, Date.now());
      } catch (_dup) {
        this._db._db.prepare(
          'UPDATE sov_value_proposals SET proposed_usd = ?, submitted_at = ? WHERE sovereign_id = ? AND epoch = ?'
        ).run(capped, Date.now(), sovereignId, epoch);
      }

      // Recompute median and store in sov_supply
      const proposals = this._db._db.prepare(
        'SELECT proposed_usd FROM sov_value_proposals WHERE epoch = ? ORDER BY proposed_usd'
      ).all(epoch);

      if (proposals.length >= 1) {
        const mid    = Math.floor(proposals.length / 2);
        const median = proposals.length % 2 === 0
          ? (proposals[mid - 1].proposed_usd + proposals[mid].proposed_usd) / 2
          : proposals[mid].proposed_usd;

        this._db._db.prepare(
          'INSERT INTO sov_supply (sov_usd_rate, vote_count, epoch, computed_at) VALUES (?, ?, ?, ?)'
        ).run(median, proposals.length, epoch, Date.now());
      }

      global.sovLog.info(`[Governance] SOV value proposal: ${sovereignId} → $${capped} (epoch ${epoch})`);

      this._send(ws, 'QV', {
        type:         'SOV_VALUE_SUBMITTED',
        success:      true,
        proposed_usd: capped,
        epoch,
        timestamp:    Date.now(),
      });
    } catch (e) {
      global.sovLog.error('[Governance] SOV_VALUE_SUBMIT error:', e.message);
      this._send(ws, 'QV', { type: 'SOV_VALUE_SUBMITTED', success: false, error: e.message });
    }
  }

  handleSovValueStatus(ws, msg) {
    const sovereignId = msg.sovereign_id || ws._sovereignId;

    try {
      const epoch      = Math.floor(Date.now() / 60000);
      const rateRow    = this._db._db.prepare(
        'SELECT sov_usd_rate FROM sov_supply ORDER BY id DESC LIMIT 1'
      ).get();
      const currentRate = (rateRow && rateRow.sov_usd_rate) ? rateRow.sov_usd_rate : 0;

      const voteCount   = this._db._db.prepare(
        'SELECT COUNT(*) as c FROM sov_value_proposals WHERE epoch = ?'
      ).get(epoch);
      const myProp      = sovereignId
        ? this._db._db.prepare(
            'SELECT proposed_usd FROM sov_value_proposals WHERE sovereign_id = ? AND epoch = ?'
          ).get(sovereignId, epoch)
        : null;
      const citizenCount = this._db._db.prepare(
        'SELECT COUNT(*) as c FROM sov_enrollments'
      ).get();

      this._send(ws, 'QS', {
        type:             'SOV_VALUE_STATUS_RESULT',
        success:          true,
        current_usd_rate: currentRate,
        current_epoch:    epoch,
        vote_count:       (voteCount || { c: 0 }).c,
        citizen_count:    (citizenCount || { c: 0 }).c,
        my_proposal:      myProp ? myProp.proposed_usd : null,
        timestamp:        Date.now(),
      });
    } catch (e) {
      global.sovLog.error('[Governance] SOV_VALUE_STATUS error:', e.message);
      this._send(ws, 'QS', { type: 'SOV_VALUE_STATUS_RESULT', success: false, error: e.message });
    }
  }

  // ── Stats summary — used by citizen_gateway._handleNodeStats ─────────────
  getStats() {
    try {
      const open_polls = this._db._db.prepare(
        "SELECT COUNT(*) as cnt FROM sov_polls WHERE status = 'open'"
      ).get().cnt;
      const open_disputes = this._db._db.prepare(
        "SELECT COUNT(*) as cnt FROM sov_disputes WHERE status = 'open'"
      ).get().cnt;
      return { open_polls, open_disputes };
    } catch (_) {
      return { open_polls: 0, open_disputes: 0 };
    }
  }

  _send(ws, op, payload) {
    if (!ws || ws.readyState !== 1) return;
    ws.send(JSON.stringify({ op, ...payload }));
  }
}

module.exports = { GovernanceEngine, PARAM_MAP, PARAM_DEFAULTS };
