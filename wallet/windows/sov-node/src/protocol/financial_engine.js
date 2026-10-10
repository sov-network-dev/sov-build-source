// ─────────────────────────────────────────────────────────────────────────────
// FINANCIAL ENGINE — SOV Request, SOV Vault, UBI Issuance, Guardian Recovery
// ─────────────────────────────────────────────────────────────────────────────
// This engine handles all financial operations beyond basic transfers.
//
// Four subsystems:
//
//   1. SOV Request (Payment Requests)
//      Citizens create QR code payment requests with optional amount + memo.
//      The relay marks requests paid and notifies the requester live.
//      Double-payment prevention: tombstones block duplicate fills cross-node.
//
//   2. SOV Vault (Deadman Switch)
//      Citizens lock SOV with a claim key derived from family keywords.
//      Two claim paths: immediate (claim key) or time-delayed (30-day wait).
//      Network reclamation after 15 years of inactivity.
//
//   3. Monetary Issuance — RETIRED 1.4.89. It credited balances with no pool debit, so a vote
//      could have minted past the 50M cap. Claims are refused with ISSUANCE_RETIRED.
//
//   4. Guardian Recovery
//      Citizens nominate trusted contacts as guardians. On device loss,
//      recovery collects guardian approvals and restores the citizen's disc
//      entry with the new device's public key.
// ─────────────────────────────────────────────────────────────────────────────

'use strict';

const crypto = require('crypto');
const nacl   = require('tweetnacl');
const ownerAuth = require('./owner_auth');   // 1.4.95: the citizen's signed request travels with their money ops

// Maximum optimistic concurrency retries for balance operations
const MAX_RETRIES = 3;


class FinancialEngine {

  constructor(identity, db, peerMesh) {
    this._identity = identity;
    this._db       = db;
    this._peerMesh = peerMesh;
    this._gateway  = null;

    this._initFinancialTables();

    // Register peer mesh handlers
    peerMesh.on('PAY_REQ_PAID_BROADCAST',     (msg) => this._handlePayReqPaidBroadcast(msg));
    peerMesh.on('VAULT_BROADCAST',            (msg) => this._handleVaultBroadcast(msg));
    peerMesh.on('VAULT_CLAIM_BROADCAST',      (msg) => this._handleVaultClaimBroadcast(msg));
    peerMesh.on('RECLAMATION_PROPOSED',       (msg) => this._handleReclamationProposed(msg));
    peerMesh.on('ISSUANCE_LOG_BROADCAST',     (msg) => this._handleIssuanceLogBroadcast(msg));
    peerMesh.on('GUARDIAN_INVITE_BROADCAST',  (msg) => this._handleGuardianInviteBroadcast(msg));
    peerMesh.on('GUARDIAN_RECOVERY_BROADCAST',(msg) => this._handleGuardianRecoveryBroadcast(msg));
    peerMesh.on('GUARDIAN_APPROVAL_BROADCAST',(msg) => this._handleGuardianApprovalBroadcast(msg));
    peerMesh.on('GUARDIAN_SET_BROADCAST',     (msg) => this._handleGuardianSetBroadcast(msg));   // 1.4.94 D56
    this._requesters = new Map();   // recovery request_id -> the requesting connection (it has no key yet)

    // Start hourly maintenance
    setTimeout(() => this._runMaintenance(), 15000);
    setInterval(() => this._runMaintenance(), 60 * 60 * 1000);

    global.sovLog.info('      ✓ Financial engine initialised');
  }

  setGateway(gateway) {
    this._gateway = gateway;
  }

  // ── Table initialisation ──────────────────────────────────────────────────

  _initFinancialTables() {
    this._db._db.exec(`

      -- ── SOV Payment Requests ──────────────────────────────────────────────
      CREATE TABLE IF NOT EXISTS sov_payment_requests (
        request_id    TEXT PRIMARY KEY,
        requester_id  TEXT NOT NULL,
        amount_seeds  INTEGER NOT NULL DEFAULT 0,
        memo          TEXT NOT NULL DEFAULT '',
        status        TEXT NOT NULL DEFAULT 'pending',  -- pending|paid|expired|cancelled
        created_at    INTEGER NOT NULL,
        expires_at    INTEGER NOT NULL,
        paid_at       INTEGER NOT NULL DEFAULT 0,
        payer_id      TEXT NOT NULL DEFAULT ''
      );
      CREATE INDEX IF NOT EXISTS idx_payreq_requester
        ON sov_payment_requests(requester_id, status);

      -- ── SOV Vault ─────────────────────────────────────────────────────────
      CREATE TABLE IF NOT EXISTS sov_vaults (
        vault_id       TEXT PRIMARY KEY,
        owner_id       TEXT NOT NULL,
        amount_seeds   INTEGER NOT NULL,
        claim_key_hash TEXT NOT NULL,      -- SHA-256(family keywords) — never the keywords themselves
        status         TEXT NOT NULL DEFAULT 'locked',  -- locked|claimed|reclaimed
        locked_at      INTEGER NOT NULL,
        claim_deadline INTEGER NOT NULL DEFAULT 0,  -- 0 = no deadline; >0 = epoch ms for Stage 1 claim
        reclaim_at     INTEGER NOT NULL             -- network reclamation epoch ms (vault_reclaim_years gov param, default 20)
      );
      CREATE INDEX IF NOT EXISTS idx_vault_owner ON sov_vaults(owner_id);

      CREATE TABLE IF NOT EXISTS sov_vault_claims (
        claim_id       TEXT PRIMARY KEY,
        vault_id       TEXT NOT NULL,
        claimant_id    TEXT NOT NULL,
        claim_stage    INTEGER NOT NULL,    -- 1 = time-delayed, 2 = immediate with key
        status         TEXT NOT NULL DEFAULT 'pending',  -- pending|approved|rejected|expired
        submitted_at   INTEGER NOT NULL,
        resolves_at    INTEGER NOT NULL,    -- Stage 1: submitted_at + 30 days
        evidence_hash  TEXT NOT NULL DEFAULT ''
      );

      -- ── Monetary Issuance Log ─────────────────────────────────────────────
      CREATE TABLE IF NOT EXISTS sov_issuance_log (
        epoch_id      TEXT NOT NULL,
        citizen_id    TEXT NOT NULL,
        amount_seeds  INTEGER NOT NULL,
        issued_at     INTEGER NOT NULL,
        PRIMARY KEY (epoch_id, citizen_id)
      );

      -- ── Guardian Recovery ─────────────────────────────────────────────────
      CREATE TABLE IF NOT EXISTS sov_guardians (
        citizen_id    TEXT NOT NULL,
        guardian_id   TEXT NOT NULL,
        added_at      INTEGER NOT NULL,
        PRIMARY KEY (citizen_id, guardian_id)
      );
      CREATE INDEX IF NOT EXISTS idx_guardian_id ON sov_guardians(guardian_id);

      CREATE TABLE IF NOT EXISTS sov_recovery_requests (
        request_id    TEXT PRIMARY KEY,
        citizen_id    TEXT NOT NULL,
        new_pub_key   TEXT NOT NULL,
        status        TEXT NOT NULL DEFAULT 'pending',  -- pending|approved|rejected|expired
        created_at    INTEGER NOT NULL,
        expires_at    INTEGER NOT NULL,
        approvals     TEXT NOT NULL DEFAULT '[]'        -- JSON array of approving guardian_ids
      );

      -- ── Reversible-Stewardship Reclamation Ledger (king 2026-06-04) ────────
      -- When a vault unclaimed past the 20yr grace (owner inactive) is STEWARDED into
      -- the operator pool, this records the liability: the funds are RESTORABLE to the
      -- owner OR a verified heir forever. A claim always reverses the stewardship.
      CREATE TABLE IF NOT EXISTS sov_reclamation_ledger (
        vault_id      TEXT PRIMARY KEY,
        owner_id      TEXT NOT NULL,
        amount_seeds  INTEGER NOT NULL,
        stewarded_to  TEXT NOT NULL DEFAULT 'witness_operator',
        restorable    INTEGER NOT NULL DEFAULT 1,   -- 1 = still owed back; 0 = restored
        stewarded_at  INTEGER NOT NULL,
        restored_at   INTEGER,
        restored_to   TEXT
      );

    `);

    // Seed governance defaults for financial params
    const govDefaults = [
      ['guardian_approval_threshold',  '2'],
      ['guardian_max_count',           '5'],
      ['guardian_recovery_window_hours','72'],
      ['vault_reclaim_years',          '20'],   // king 2026-06-04: 20-yr grace (was 15)
      // Reclamation disposition (governable §4b): 'steward_operator_pool' = reversible
      // stewardship (default, king-agreed — NEVER burn); 'keep_idle' = hold locked.
      ['reclamation_disposition',      'steward_operator_pool'],
    ];
    for (const [key, val] of govDefaults) {
      this._db._db.prepare(`
        INSERT OR IGNORE INTO sov_governance_params (param_key, param_value, activated_at)
        VALUES (?, ?, 0)
      `).run(key, val);
    }
    // 1.4.94 (D56): signed, replicated guardian appointments; recovery requests remember the key they replace.
    for (const sql of [
      "ALTER TABLE sov_guardians ADD COLUMN status TEXT NOT NULL DEFAULT 'active'",
      'ALTER TABLE sov_guardians ADD COLUMN ts INTEGER NOT NULL DEFAULT 0',
      'ALTER TABLE sov_guardians ADD COLUMN sig TEXT',
      'ALTER TABLE sov_recovery_requests ADD COLUMN old_pub_key TEXT',
    ]) { try { this._db._db.exec(sql); } catch (_) { /* already there */ } }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  SUBSYSTEM 1 — SOV REQUEST (Payment Requests)
  // ═══════════════════════════════════════════════════════════════════════════

  handleRequestCreate(ws, msg) {
    const { request_id, amount_seeds, memo, expires_in_hours } = msg;
    const requester_id = ws._sovereignId;

    if (!request_id) {
      this._send(ws, 'RPC', { success: false, error: 'MISSING_REQUEST_ID' });
      return;
    }

    if (!/^[a-zA-Z0-9_\-]{8,64}$/.test(request_id)) {
      this._send(ws, 'RPC', { success: false, error: 'INVALID_REQUEST_ID' });
      return;
    }

    // Default expiry: 24 hours. Maximum: 30 days.
    const expiryHours = Math.min(parseInt(expires_in_hours) || 24, 24 * 30);
    const now         = Date.now();
    const expiresAt   = now + expiryHours * 60 * 60 * 1000;

    try {
      this._db._db.prepare(`
        INSERT OR IGNORE INTO sov_payment_requests
          (request_id, requester_id, amount_seeds, memo, status, created_at, expires_at)
        VALUES (?, ?, ?, ?, 'pending', ?, ?)
      `).run(request_id, requester_id, amount_seeds || 0, memo || '', now, expiresAt);
    } catch (_) {}

    this._send(ws, 'RPC', {
      success:    true,
      request_id,
      requester_id,
      amount_seeds: amount_seeds || 0,
      memo:       memo || '',
      expires_at: expiresAt,
      // Deep link — phone app uses this for QR code generation
      link:       `sovreq://${requester_id}?req=${request_id}${amount_seeds ? '&amount=' + (amount_seeds / 1e6).toFixed(6) : ''}${memo ? '&memo=' + encodeURIComponent(memo) : ''}`,
      ts:         now,
    });
  }

  handleRequestList(ws, msg) {
    const requester_id = ws._sovereignId;
    const rows = this._db._db.prepare(`
      SELECT * FROM sov_payment_requests
      WHERE requester_id = ? AND expires_at > ? AND status != 'cancelled'
      ORDER BY created_at DESC
      LIMIT 50
    `).all(requester_id, Date.now());

    this._send(ws, 'RPL', { requests: rows, ts: Date.now() });
  }

  handleRequestCancel(ws, msg) {
    const { request_id } = msg;
    const requester_id   = ws._sovereignId;
    if (!request_id) return;

    this._db._db.prepare(`
      UPDATE sov_payment_requests
      SET status = 'cancelled'
      WHERE request_id = ? AND requester_id = ? AND status = 'pending'
    `).run(request_id, requester_id);

    this._send(ws, 'RPN', { success: true, request_id, ts: Date.now() });
  }

  // Called by TransferEngine when a transfer includes a payment_request_id
  markPaymentRequestPaid(requestId, payerId) {
    const result = this._db._db.prepare(`
      UPDATE sov_payment_requests
      SET status = 'paid', paid_at = ?, payer_id = ?
      WHERE request_id = ? AND status = 'pending'
    `).run(Date.now(), payerId, requestId);

    if (result.changes === 0) return false;  // Already paid or not found

    // Get the requester to notify them
    const row = this._db._db.prepare(
      'SELECT requester_id, amount_seeds, memo FROM sov_payment_requests WHERE request_id = ?'
    ).get(requestId);

    if (row && this._gateway) {
      // Notify requester if online
      this._gateway.push(row.requester_id, 'RPN', {  // SOV_REQUEST_PAID_NOTIFY
        request_id: requestId,
        payer_id:   payerId,
        amount_seeds: row.amount_seeds,
        memo:       row.memo,
        ts:         Date.now(),
      });
    }

    // Broadcast to peer nodes so they can mark it paid too (prevents double-payment)
    this._peerMesh.broadcast('PAY_REQ_PAID_BROADCAST', {
      request_id: requestId,
      payer_id:   payerId,
      origin_node: this._identity.nodeId,
    });

    return true;
  }

  // Is this payment request still valid (for pre-send check by TransferEngine)?
  isPaymentRequestValid(requestId) {
    const row = this._db._db.prepare(`
      SELECT status, expires_at FROM sov_payment_requests WHERE request_id = ?
    `).get(requestId);

    if (!row) return null;          // Not found on this node — allow (may be cross-node)
    if (row.status !== 'pending') return false;  // Already paid/cancelled/expired
    if (row.expires_at < Date.now()) return false;  // Expired
    return true;
  }

  _handlePayReqPaidBroadcast(msg) {
    const { request_id, payer_id, origin_node } = msg;
    if (!request_id || origin_node === this._identity.nodeId) return;

    // Mark paid on this node (INSERT tombstone if we don't have the original request)
    const row = this._db._db.prepare(
      'SELECT requester_id FROM sov_payment_requests WHERE request_id = ?'
    ).get(request_id);

    if (row) {
      this._db._db.prepare(`
        UPDATE sov_payment_requests SET status = 'paid', paid_at = ?, payer_id = ?
        WHERE request_id = ? AND status = 'pending'
      `).run(Date.now(), payer_id || '', request_id);

      // Notify requester if they're online here
      if (this._gateway) {
        this._gateway.push(row.requester_id, 'RPN', {
          request_id, payer_id, ts: Date.now(),
        });
      }
    } else {
      // Tombstone — prevents a payment on this node using this request ID
      const now = Date.now();
      try {
        this._db._db.prepare(`
          INSERT OR IGNORE INTO sov_payment_requests
            (request_id, requester_id, amount_seeds, memo, status, created_at, expires_at, paid_at, payer_id)
          VALUES (?, 'TOMBSTONE', 0, '', 'paid', ?, ?, ?, ?)
        `).run(request_id, now, now + 30 * 24 * 60 * 60 * 1000, now, payer_id || '');
      } catch (_) {}
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  SUBSYSTEM 2 — SOV VAULT (Deadman Switch)
  // ═══════════════════════════════════════════════════════════════════════════

  async handleVaultLock(ws, msg) {
    const { vault_id, amount_seeds, claim_key_hash } = msg;
    const owner_id = ws._sovereignId;

    if (!vault_id || !amount_seeds || !claim_key_hash) {
      this._send(ws, 'VLC', { success: false, error: 'MISSING_FIELDS' });
      return;
    }

    if (!/^[0-9a-f]{64}$/i.test(claim_key_hash)) {
      this._send(ws, 'VLC', { success: false, error: 'INVALID_CLAIM_KEY_HASH' });
      return;
    }

    // Verify owner has enough spendable balance
    const disc = this._db.readDisc(owner_id);
    if (!disc || disc.spendable_seeds < amount_seeds) {
      this._send(ws, 'VLC', { success: false, error: 'INSUFFICIENT_BALANCE' });
      return;
    }

    if (this._db._db.prepare('SELECT 1 FROM sov_vaults WHERE vault_id = ?').get(vault_id)) {
      this._send(ws, 'VLC', { success: false, error: 'VAULT_ID_EXISTS' });
      return;
    }
    // 1.4.90: locking is an OWNER op — the SOV moves from the wallet into this vault's holding
    // only after a majority of nodes granted the owner's next slot (no double-spend against a
    // transfer), applied atomically on every node. Before, peers never debited the owner at all.
    const res = await this._db.ledger.commitOwnerOp({
      kind: 'vault_lock', ref: vault_id, owner: { acct: owner_id },
      auth: ownerAuth.fromAppRequest(msg),     // 1.4.95: every node checks the citizen's own signed request
      moves: [{ acct: owner_id, d: -amount_seeds }],
      holds: [{ id: 'vault:' + vault_id, d: amount_seeds }],
    });
    if (!res.ok) {
      this._send(ws, 'VLC', { success: false, error: res.error === 'LEDGER_INSUFFICIENT' ? 'INSUFFICIENT_BALANCE' : res.error });
      return;
    }
    const now = Date.now();
    // Reclamation grace period — king 2026-06-04: 20 years (was 15). Governable
    // via the vault_reclaim_years param (§4b); falls back to 20 if unseeded.
    let reclaimYears = 20;
    try { reclaimYears = parseInt(this._db.getGovParam('vault_reclaim_years', '20')) || 20; } catch (_) {}
    const RECLAIM_MS = reclaimYears * 365.25 * 24 * 60 * 60 * 1000;
    this._db._db.prepare(`
      INSERT OR IGNORE INTO sov_vaults
        (vault_id, owner_id, amount_seeds, claim_key_hash, status, locked_at, reclaim_at)
      VALUES (?, ?, ?, ?, 'locked', ?, ?)
    `).run(vault_id, owner_id, amount_seeds, claim_key_hash, now, now + RECLAIM_MS);
    this._peerMesh.broadcast('VAULT_BROADCAST', {
      vault_id, owner_id, amount_seeds, claim_key_hash,
      locked_at: now, reclaim_at: now + RECLAIM_MS,
      origin_node: this._identity.nodeId,
    });
    this._send(ws, 'VLC', { success: true, vault_id, amount_seeds, ts: now });
  }

  handleVaultClaimInit(ws, msg) {
    const { vault_id, claim_stage, claim_key_hash, evidence_hash } = msg;
    const claimant_id = ws._sovereignId;

    if (!vault_id || !claim_stage) {
      this._send(ws, 'VCI', { success: false, error: 'MISSING_FIELDS' });
      return;
    }

    const vault = this._db._db.prepare(
      'SELECT * FROM sov_vaults WHERE vault_id = ?'
    ).get(vault_id);

    if (!vault) {
      this._send(ws, 'VCI', { success: false, error: 'VAULT_NOT_FOUND' });
      return;
    }

    // 'stewarded' vaults are STILL claimable — a verified heir (or the returning
    // owner) reverses the stewardship and gets the funds back from the operator pool.
    if (vault.status !== 'locked' && vault.status !== 'stewarded') {
      this._send(ws, 'VCI', { success: false, error: `VAULT_STATUS_${vault.status.toUpperCase()}` });
      return;
    }

    const now        = Date.now();
    const claim_id   = `${vault_id}:${claimant_id}:${now}`;

    if (claim_stage === 2) {
      // Stage 2: immediate claim with claim key
      // Verify the claim key hash matches
      if (!claim_key_hash || claim_key_hash.toLowerCase() !== vault.claim_key_hash.toLowerCase()) {
        this._send(ws, 'VCI', { success: false, error: 'INVALID_CLAIM_KEY' });
        return;
      }

      // Immediately credit the vault amount to the claimant
      this._executeVaultClaim(vault, claimant_id, claim_id, now);
      return;
    }

    // Stage 1: time-delayed claim (no key required — anyone with relationship can claim)
    // Creates a 30-day waiting period. Owner can dispute within 30 days.
    const THIRTY_DAYS_MS = 30 * 24 * 60 * 60 * 1000;
    const resolves_at    = now + THIRTY_DAYS_MS;

    try {
      this._db._db.prepare(`
        INSERT INTO sov_vault_claims
          (claim_id, vault_id, claimant_id, claim_stage, status, submitted_at, resolves_at, evidence_hash)
        VALUES (?, ?, ?, 1, 'pending', ?, ?, ?)
      `).run(claim_id, vault_id, claimant_id, now, resolves_at, evidence_hash || '');
    } catch (_) {
      this._send(ws, 'VCI', { success: false, error: 'CLAIM_ALREADY_EXISTS' });
      return;
    }

    // Update vault claim_deadline so owner can see it
    this._db._db.prepare(
      'UPDATE sov_vaults SET claim_deadline = ? WHERE vault_id = ?'
    ).run(resolves_at, vault_id);

    // Notify vault owner if online
    if (this._gateway && vault.owner_id !== claimant_id) {
      this._gateway.push(vault.owner_id, 'VCI', {
        type:         'VAULT_CLAIM_INITIATED',
        vault_id,
        claimant_id,
        claim_stage:  1,
        resolves_at,
        ts:           now,
      });
    }

    this._send(ws, 'VCI', {
      success:     true,
      claim_id,
      vault_id,
      claim_stage: 1,
      resolves_at,
      ts:          now,
    });
  }

  _executeVaultClaim(vault, claimantId, claimId, now) {
    // 1.4.90: the claim is ONE ledger op, at most once per vault (deterministic id). The money
    // comes from the vault's holding — or, if the vault was stewarded after its grace period,
    // back out of the operator pool (stewardship is reversible: no honest fund is ever lost).
    let led = null;
    try { led = this._db._db.prepare("SELECT * FROM sov_reclamation_ledger WHERE vault_id = ? AND restorable = 1").get(vault.vault_id); } catch (_) {}
    const src = led ? { pools: [{ pool: led.stewarded_to || 'witness_operator', d: -vault.amount_seeds }] }
                    : { holds: [{ id: 'vault:' + vault.vault_id, d: -vault.amount_seeds }] };
    const r = this._db.ledger.commitSystemOp({
      op_id: `vault-claim:${vault.vault_id}`, kind: 'vault_claim', ref: vault.vault_id,
      moves: [{ acct: claimantId, d: vault.amount_seeds }], ...src,
    });
    if (!r.ok) {
      global.sovLog.error(`[FINANCE] vault ${vault.vault_id} claim not paid: ${r.error}`);
      if (this._gateway) this._gateway.push(claimantId, 'VCR', { success: false, vault_id: vault.vault_id, claim_id: claimId, error: r.error, ts: now });
      return;
    }
    if (led) {
      this._db._db.prepare("UPDATE sov_reclamation_ledger SET restorable = 0, restored_at = ?, restored_to = ? WHERE vault_id = ?")
        .run(now, claimantId, vault.vault_id);
      global.sovLog.info(`      [FINANCE] Vault ${vault.vault_id} RESTORED from ${led.stewarded_to} pool to ${claimantId}.`);
    }
    this._db._db.prepare("UPDATE sov_vaults SET status = 'claimed' WHERE vault_id = ?").run(vault.vault_id);
    if (this._gateway) {
      this._gateway.push(claimantId, 'VCR', {  // VAULT_CLAIM_RESULT
        success: true, vault_id: vault.vault_id, claim_id: claimId, amount_seeds: vault.amount_seeds, ts: now,
      });
    }
    this._peerMesh.broadcast('VAULT_CLAIM_BROADCAST', {
      vault_id: vault.vault_id, claimant_id: claimantId, amount_seeds: vault.amount_seeds,
      origin_node: this._identity.nodeId,
    });
  }

  _handleVaultBroadcast(msg) {
    const { vault_id, owner_id, amount_seeds, claim_key_hash, locked_at, reclaim_at, origin_node } = msg;
    if (!vault_id || origin_node === this._identity.nodeId) return;

    try {
      this._db._db.prepare(`
        INSERT OR IGNORE INTO sov_vaults
          (vault_id, owner_id, amount_seeds, claim_key_hash, status, locked_at, reclaim_at)
        VALUES (?, ?, ?, ?, 'locked', ?, ?)
      `).run(vault_id, owner_id, amount_seeds, claim_key_hash, locked_at, reclaim_at);
    } catch (_) {}
  }

  _handleVaultClaimBroadcast(msg, attempt = 0) {
    const { vault_id, origin_node } = msg;
    if (!vault_id || origin_node === this._identity.nodeId) return;
    // 1.4.94 (D58): a peer's word is not evidence. Before, this unsigned message alone marked the vault
    // 'claimed' on every node, freezing it with the money still in its holding. Now the vault is marked
    // claimed only once THIS node holds the once-only ledger op that actually paid it out.
    const paid = this._db._db.prepare('SELECT 1 FROM sov_ledger_ops WHERE op_id = ?').get('vault-claim:' + vault_id);
    if (paid) {
      this._db._db.prepare(
        "UPDATE sov_vaults SET status = 'claimed' WHERE vault_id = ? AND status IN ('locked', 'stewarded')"
      ).run(vault_id);
      return;
    }
    // The op may simply not have arrived yet — look again a few times, then drop it.
    if (attempt < 4) setTimeout(() => this._handleVaultClaimBroadcast(msg, attempt + 1), 30000 * (attempt + 1)).unref?.();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  SUBSYSTEM 3 — MONETARY ISSUANCE (UBI)
  // ═══════════════════════════════════════════════════════════════════════════

  // RETIRED 1.4.89 (king, 2026-10-06). Issuance credited every claimant's balance with NOTHING
  // debited from any pool: a citizen vote raising sov_issuance_rate above 0 would have MINTED new
  // SOV past the fixed 50,000,000 (audit 2026-08-05, M6). The cap is the promise, so the mint is
  // gone rather than gated - the same treatment as the referral and pioneer payouts in 1.4.72.
  // The three issuance params are no longer seeded or votable; existing rows stay, inert.
  // ISSUANCE_CLAIM ('IC') stays registered so an older app gets a clear refusal, not silence.
  checkIssuanceOnHello(_sovereignId, _ws) {
    // Nothing is ever available: never push ISSUANCE_AVAILABLE.
  }

  handleIssuanceClaim(ws, _msg) {
    this._send(ws, 'ICR', { success: false, error: 'ISSUANCE_RETIRED' });
  }

  _handleIssuanceLogBroadcast(_msg) {
    // No node issues anything any more, so there is nothing to record.
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  SUBSYSTEM 4 — GUARDIAN RECOVERY
  // ═══════════════════════════════════════════════════════════════════════════
  //
  // 1.4.94 (D56, D59). Two kinds of evidence, both signed, so EVERY node can check them itself:
  //   appointment: the CITIZEN signs  SOV-GUARDIAN-SET-v1|citizen|guardian|add|remove|ts
  //   approval:    the GUARDIAN signs SOV-GUARDIAN-APPROVE-v2|request|citizen|old_pub_key|new_pub_key|guardian|ts
  // old_pub_key is the citizen's key when the request was opened: once a recovery executes, every earlier
  // approval names a key that is no longer current and can never be replayed (Gemini review 2026-10-08).
  // A node re-keys a citizen only when IT has verified >= guardian_approval_threshold distinct signed
  // approvals from guardians whose appointment it holds. Before 1.4.94 a peer's unsigned list of ids
  // was taken as given, so one dishonest node could re-key anyone with an open request.

  static guardianSetString(citizenId, guardianId, action, ts) {
    return `SOV-GUARDIAN-SET-v1|${citizenId}|${guardianId}|${action}|${ts}`;
  }

  static guardianApproveString(requestId, citizenId, oldPubKey, newPubKey, guardianId, ts) {
    return `SOV-GUARDIAN-APPROVE-v2|${requestId}|${citizenId}|${String(oldPubKey).toLowerCase()}|${String(newPubKey).toLowerCase()}|${guardianId}|${ts}`;
  }

  _enrolledKey(sovereignId) {
    try {
      const r = this._db._db.prepare('SELECT public_key_hex FROM sov_enrollments WHERE sovereign_id = ?').get(sovereignId);
      return r && /^[0-9a-f]{64}$/i.test(r.public_key_hex || '') ? r.public_key_hex.toLowerCase() : null;
    } catch (_) { return null; }
  }

  _verifyBy(sovereignId, text, sigHex) {
    const pub = this._enrolledKey(sovereignId);
    if (!pub || !/^[0-9a-f]{128}$/i.test(sigHex || '')) return false;
    try {
      return nacl.sign.detached.verify(Buffer.from(text, 'utf8'), Buffer.from(sigHex, 'hex'), Buffer.from(pub, 'hex'));
    } catch (_) { return false; }
  }

  _isGuardian(citizenId, guardianId) {
    return !!this._db._db.prepare(
      "SELECT 1 FROM sov_guardians WHERE citizen_id = ? AND guardian_id = ? AND status = 'active'"
    ).get(citizenId, guardianId);
  }

  /** Apply a signed appointment change (local or from a peer). Newer ts wins; replays are ignored. */
  _applyGuardianSet({ citizen_id, guardian_id, action, ts, sig }) {
    if (!citizen_id || !guardian_id || citizen_id === guardian_id) return 'MISSING_FIELDS';
    if (action !== 'add' && action !== 'remove') return 'BAD_ACTION';
    ts = Number(ts);
    if (!Number.isFinite(ts) || ts <= 0 || ts > Date.now() + 5 * 60 * 1000) return 'BAD_TIMESTAMP';
    if (!this._verifyBy(citizen_id, FinancialEngine.guardianSetString(citizen_id, guardian_id, action, ts), sig)) {
      return 'INVALID_SIGNATURE';
    }
    const cur = this._db._db.prepare('SELECT ts FROM sov_guardians WHERE citizen_id = ? AND guardian_id = ?').get(citizen_id, guardian_id);
    if (cur && Number(cur.ts || 0) >= ts) return 'STALE';
    if (action === 'add') {
      const maxCount = parseInt(this._db.getGovParam('guardian_max_count', '5'));
      const n = this._db._db.prepare("SELECT COUNT(*) AS c FROM sov_guardians WHERE citizen_id = ? AND status = 'active' AND guardian_id != ?")
        .get(citizen_id, guardian_id).c;
      if (n >= maxCount) return 'GUARDIAN_LIMIT_REACHED';
    }
    this._db._db.prepare(`
      INSERT INTO sov_guardians (citizen_id, guardian_id, added_at, status, ts, sig) VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(citizen_id, guardian_id) DO UPDATE SET status = excluded.status, ts = excluded.ts, sig = excluded.sig
    `).run(citizen_id, guardian_id, ts, action === 'add' ? 'active' : 'removed', ts, sig);
    return 'OK';
  }

  handleGuardianAdd(ws, msg)    { this._guardianSet(ws, msg, 'add', 'GAR'); }
  handleGuardianRemove(ws, msg) { this._guardianSet(ws, msg, 'remove', 'GRR'); }

  _guardianSet(ws, msg, action, op) {
    const citizen_id = ws._sovereignId;
    const { guardian_id, ts, sig } = msg;
    if (!guardian_id) { this._send(ws, op, { success: false, error: 'MISSING_GUARDIAN_ID' }); return; }
    if (!sig || !ts) { this._send(ws, op, { success: false, error: 'SIGNATURE_REQUIRED' }); return; }
    if (action === 'add' && !this._enrolledKey(guardian_id)) {
      this._send(ws, op, { success: false, error: 'GUARDIAN_NOT_ENROLLED' }); return;
    }
    const r = this._applyGuardianSet({ citizen_id, guardian_id, action, ts, sig });
    if (r !== 'OK') { this._send(ws, op, { success: false, error: r }); return; }
    this._peerMesh.broadcast('GUARDIAN_SET_BROADCAST', {
      citizen_id, guardian_id, action, ts: Number(ts), sig, origin_node: this._identity.nodeId,
    });
    if (action === 'add' && this._gateway) this._gateway.push(guardian_id, 'GIN', { citizen_id, ts: Date.now() });
    this._send(ws, op, { success: true, guardian_id, ts: Date.now() });
  }

  _handleGuardianSetBroadcast(msg) {
    if (!msg || msg.origin_node === this._identity.nodeId) return;
    const r = this._applyGuardianSet(msg);
    if (r === 'OK' && msg.action === 'add' && this._gateway) {
      this._gateway.push(msg.guardian_id, 'GIN', { citizen_id: msg.citizen_id, ts: Date.now() });
    }
  }

  handleGuardianList(ws, msg) {
    const citizen_id = ws._sovereignId;
    const rows = this._db._db.prepare(
      "SELECT guardian_id, added_at FROM sov_guardians WHERE citizen_id = ? AND status = 'active' ORDER BY added_at ASC"
    ).all(citizen_id);
    this._send(ws, 'GRL', { guardians: rows, ts: Date.now() });
  }

  /** Store a recovery request (from the requesting device or a peer). Anyone may OPEN one — the
   *  guardians decide. Returns the row. */
  _storeRecoveryRequest({ request_id, citizen_id, old_pub_key, new_pub_key, created_at, expires_at }) {
    const cur = this._enrolledKey(citizen_id);
    if (!cur || (old_pub_key && String(old_pub_key).toLowerCase() !== cur)) return null;   // stale: key already changed
    this._db._db.prepare(`
      INSERT OR IGNORE INTO sov_recovery_requests (request_id, citizen_id, old_pub_key, new_pub_key, status, created_at, expires_at)
      VALUES (?, ?, ?, ?, 'pending', ?, ?)
    `).run(request_id, citizen_id, cur, String(new_pub_key).toLowerCase(), created_at, expires_at);
    return this._db._db.prepare('SELECT * FROM sov_recovery_requests WHERE request_id = ?').get(request_id);
  }

  handleRecoveryRequest(ws, msg) {
    const request_id  = msg.request_id;
    const citizen_id  = msg.citizen_id;
    const new_pub_key = msg.new_pub_key || msg.new_pub_key_hex;   // D59: the app sent new_pub_key_hex
    if (!request_id || !citizen_id || !new_pub_key) {
      this._send(ws, 'GRC', { success: false, error: 'MISSING_FIELDS' });
      return;
    }
    if (!/^[0-9a-f]{64}$/i.test(new_pub_key)) {
      this._send(ws, 'GRC', { success: false, error: 'INVALID_PUBLIC_KEY' });
      return;
    }
    if (!this._enrolledKey(citizen_id)) {
      this._send(ws, 'GRC', { success: false, error: 'CITIZEN_NOT_ENROLLED' });
      return;
    }
    const guardians = this._db._db.prepare(
      "SELECT guardian_id FROM sov_guardians WHERE citizen_id = ? AND status = 'active'"
    ).all(citizen_id).map(r => r.guardian_id);
    if (!guardians.length) {
      this._send(ws, 'GRC', { success: false, error: 'NO_GUARDIANS' });
      return;
    }
    const now       = Date.now();
    const windowHrs = parseInt(this._db.getGovParam('guardian_recovery_window_hours', '72'));
    const expiresAt = now + windowHrs * 60 * 60 * 1000;
    if (this._db._db.prepare('SELECT 1 FROM sov_recovery_requests WHERE request_id = ?').get(request_id)) {
      this._send(ws, 'GRC', { success: false, error: 'REQUEST_EXISTS' });
      return;
    }
    this._storeRecoveryRequest({ request_id, citizen_id, new_pub_key, created_at: now, expires_at: expiresAt });
    this._requesters.set(request_id, ws);   // progress goes back to THIS connection (it has no key yet)

    const oldKey = this._enrolledKey(citizen_id);
    const approvalPayload = { request_id, citizen_id, old_pub_key: oldKey, new_pub_key: new_pub_key.toLowerCase(), expires_at: expiresAt, ts: now };
    for (const gid of guardians) {
      if (this._gateway) this._gateway.push(gid, 'GAP', approvalPayload);   // GUARDIAN_APPROVAL_REQUEST
    }
    // The citizen's own devices hear about it too — a request they did not make is an attack warning.
    if (this._gateway) this._gateway.push(citizen_id, 'GAP', Object.assign({ about_you: true }, approvalPayload));
    this._peerMesh.broadcast('GUARDIAN_RECOVERY_BROADCAST', {
      request_id, citizen_id, old_pub_key: oldKey, new_pub_key: new_pub_key.toLowerCase(), created_at: now, expires_at: expiresAt,
      guardian_ids: guardians, origin_node: this._identity.nodeId,
    });
    this._send(ws, 'GRC', {
      success: true, request_id, citizen_id, guardian_count: guardians.length,
      threshold: parseInt(this._db.getGovParam('guardian_approval_threshold', '2')), expires_at: expiresAt, ts: now,
    });
  }

  /** Verified approvals of a request, distinct guardians only. */
  _verifiedApprovals(req) {
    let list;
    try { list = JSON.parse(req.approvals || '[]'); } catch (_) { list = []; }
    const seen = new Map();
    for (const a of list) {
      if (!a || typeof a !== 'object' || seen.has(a.guardian_id)) continue;   // pre-1.4.94 bare ids never count
      if (!this._isGuardian(req.citizen_id, a.guardian_id)) continue;
      const text = FinancialEngine.guardianApproveString(req.request_id, req.citizen_id, req.old_pub_key, req.new_pub_key, a.guardian_id, a.ts);
      if (this._verifyBy(a.guardian_id, text, a.sig)) seen.set(a.guardian_id, { guardian_id: a.guardian_id, ts: a.ts, sig: a.sig });
    }
    return [...seen.values()];
  }

  /** Add one signed approval to a request; re-key if the threshold is met. Returns a status. */
  _addApproval(req, approval) {
    if (!req || req.status !== 'pending') return 'REQUEST_NOT_FOUND';
    if (req.expires_at < Date.now()) return 'REQUEST_EXPIRED';
    if (!approval || !this._isGuardian(req.citizen_id, approval.guardian_id)) return 'NOT_A_GUARDIAN';
    const text = FinancialEngine.guardianApproveString(req.request_id, req.citizen_id, req.old_pub_key, req.new_pub_key, approval.guardian_id, approval.ts);
    if (!this._verifyBy(approval.guardian_id, text, approval.sig)) return 'INVALID_SIGNATURE';
    const have = this._verifiedApprovals(req);
    if (have.some(a => a.guardian_id === approval.guardian_id)) return 'ALREADY_APPROVED';
    have.push({ guardian_id: approval.guardian_id, ts: approval.ts, sig: approval.sig });
    this._db._db.prepare('UPDATE sov_recovery_requests SET approvals = ? WHERE request_id = ?')
      .run(JSON.stringify(have), req.request_id);
    const threshold = parseInt(this._db.getGovParam('guardian_approval_threshold', '2'));
    this._pushRequesterUpdate(req.request_id, { approvals_received: have.length, threshold });
    if (have.length >= threshold) this._executeGuardianRecovery(req, have.map(a => a.guardian_id));
    return 'OK';
  }

  handleGuardianApprove(ws, msg) {
    const { request_id, ts, sig } = msg;
    const guardian_id = ws._sovereignId;
    if (!request_id) return;
    if (!sig || !ts) { this._send(ws, 'GAA', { success: false, error: 'SIGNATURE_REQUIRED' }); return; }
    const req = this._db._db.prepare('SELECT * FROM sov_recovery_requests WHERE request_id = ?').get(request_id);
    const approval = { guardian_id, ts: Number(ts), sig };
    const r = this._addApproval(req, approval);
    if (r !== 'OK') { this._send(ws, 'GAA', { success: false, error: r }); return; }
    this._peerMesh.broadcast('GUARDIAN_APPROVAL_BROADCAST', {
      request_id, approval,
      request: { citizen_id: req.citizen_id, old_pub_key: req.old_pub_key, new_pub_key: req.new_pub_key, created_at: req.created_at, expires_at: req.expires_at },
      origin_node: this._identity.nodeId,
    });
    const threshold = parseInt(this._db.getGovParam('guardian_approval_threshold', '2'));
    const n = this._verifiedApprovals(this._db._db.prepare('SELECT * FROM sov_recovery_requests WHERE request_id = ?').get(request_id)).length;
    this._send(ws, 'GAA', { success: true, request_id, approvals: n, threshold, threshold_met: n >= threshold, ts: Date.now() });
  }

  handleGuardianReject(ws, msg) {
    const { request_id } = msg;
    const guardian_id    = ws._sovereignId;
    if (!request_id) return;
    const req = this._db._db.prepare(
      "SELECT citizen_id FROM sov_recovery_requests WHERE request_id = ? AND status = 'pending'"
    ).get(request_id);
    if (!req || !this._isGuardian(req.citizen_id, guardian_id)) return;
    if (this._gateway) {
      this._gateway.push(req.citizen_id, 'GRJ', { request_id, rejected_by: guardian_id, ts: Date.now() });
    }
    this._pushRequesterUpdate(request_id, { rejected_by: guardian_id });
    this._send(ws, 'GRJ', { success: true, request_id, ts: Date.now() });
  }

  _pushRequesterUpdate(requestId, extra) {
    const ws = this._requesters.get(requestId);
    if (ws && ws.readyState === 1) {
      this._send(ws, 'GAU', Object.assign({ request_id: requestId, ts: Date.now() }, extra));   // GUARDIAN_APPROVAL_UPDATE
    }
  }

  _executeGuardianRecovery(req, approvedBy) {
    const now = Date.now();
    if (this._enrolledKey(req.citizen_id) !== String(req.old_pub_key || '').toLowerCase()) {
      this._db._db.prepare("UPDATE sov_recovery_requests SET status = 'stale' WHERE request_id = ?").run(req.request_id);
      return;   // the key it would replace is no longer current — never revert to an older key
    }
    const done = this._db._db.prepare(
      "UPDATE sov_recovery_requests SET status = 'approved' WHERE request_id = ? AND status = 'pending'"
    ).run(req.request_id);
    if (!done.changes) return;   // already executed
    this._db._db.prepare('UPDATE sov_enrollments SET public_key_hex = ? WHERE sovereign_id = ?')
      .run(req.new_pub_key, req.citizen_id);
    if (this._gateway) {
      this._gateway.push(req.citizen_id, 'GCO', {  // GUARDIAN_RECOVERY_COMPLETE
        request_id: req.request_id, new_pub_key: req.new_pub_key, approved_by: approvedBy, ts: now,
      });
    }
    this._pushRequesterUpdate(req.request_id, { approvals_received: approvedBy.length, complete: true });
    global.sovLog.info(`      [FINANCE] Guardian recovery completed for ${req.citizen_id} — ${approvedBy.length} signed approvals`);
  }

  _handleGuardianInviteBroadcast(msg) {
    // Pre-1.4.94 peers announce an appointment unsigned: deliver the invite, record nothing.
    const { citizen_id, guardian_id, origin_node } = msg;
    if (!citizen_id || !guardian_id || origin_node === this._identity.nodeId) return;
    if (this._gateway) this._gateway.push(guardian_id, 'GIN', { citizen_id, ts: Date.now() });
  }

  _handleGuardianRecoveryBroadcast(msg) {
    const { request_id, citizen_id, old_pub_key, new_pub_key, created_at, expires_at, origin_node } = msg;
    if (!request_id || origin_node === this._identity.nodeId) return;
    if (!citizen_id || !/^[0-9a-f]{64}$/i.test(new_pub_key || '') || !/^[0-9a-f]{64}$/i.test(old_pub_key || '')) return;
    if (!(Number(expires_at) > Date.now()) || Number(expires_at) - Date.now() > 31 * 24 * 3600 * 1000) return;
    if (!this._storeRecoveryRequest({ request_id, citizen_id, old_pub_key, new_pub_key, created_at: Number(created_at) || Date.now(), expires_at: Number(expires_at) })) return;
    if (this._gateway) {
      const guardians = this._db._db.prepare(
        "SELECT guardian_id FROM sov_guardians WHERE citizen_id = ? AND status = 'active'"
      ).all(citizen_id);
      const payload = { request_id, citizen_id, old_pub_key: old_pub_key.toLowerCase(), new_pub_key: new_pub_key.toLowerCase(), expires_at, ts: Date.now() };
      for (const { guardian_id } of guardians) this._gateway.push(guardian_id, 'GAP', payload);
      this._gateway.push(citizen_id, 'GAP', Object.assign({ about_you: true }, payload));
    }
  }

  _handleGuardianApprovalBroadcast(msg) {
    const { request_id, approval, request, origin_node } = msg;
    if (!request_id || origin_node === this._identity.nodeId || !approval) return;   // bare id lists are ignored
    let req = this._db._db.prepare('SELECT * FROM sov_recovery_requests WHERE request_id = ?').get(request_id);
    if (!req && request && /^[0-9a-f]{64}$/i.test(request.new_pub_key || '') && /^[0-9a-f]{64}$/i.test(request.old_pub_key || '')
        && Number(request.expires_at) > Date.now() && Number(request.expires_at) - Date.now() <= 31 * 24 * 3600 * 1000) {
      req = this._storeRecoveryRequest(Object.assign({ request_id }, request));
    }
    this._addApproval(req, { guardian_id: approval.guardian_id, ts: Number(approval.ts), sig: approval.sig });
  }


  // ── Maintenance ───────────────────────────────────────────────────────────

  _runMaintenance() {
    const now = Date.now();

    // Expire stale payment requests
    this._db._db.prepare(`
      UPDATE sov_payment_requests SET status = 'expired'
      WHERE status = 'pending' AND expires_at < ?
    `).run(now);

    // Delete old paid/expired/cancelled requests (keep 30 days after resolution)
    const CLEANUP_MS = 30 * 24 * 60 * 60 * 1000;
    this._db._db.prepare(`
      DELETE FROM sov_payment_requests
      WHERE status != 'pending' AND expires_at < ?
    `).run(now - CLEANUP_MS);

    // Expire stale recovery requests
    this._db._db.prepare(`
      UPDATE sov_recovery_requests SET status = 'expired'
      WHERE status = 'pending' AND expires_at < ?
    `).run(now);

    // ── Reversible-Stewardship Reclamation (king 2026-06-04) ──────────────────
    // A vault is reclaimed ONLY when (a) reclaim_at (vault_reclaim_years, 20yr) has
    // passed AND (b) the OWNER has shown NO liveness across that grace — a returning
    // or active owner is NEVER touched (owner login = liveness, which resets this).
    // Disposition is governable: 'steward_operator_pool' (default — REVERSIBLE, never
    // burned) moves the idle funds into the witness_operator pool + records a restorable
    // liability; a later claim by the owner OR a verified heir restores them. 'keep_idle'
    // just holds + broadcasts so family can still find it via the search protocol.
    const reclaimYears  = parseInt(this._db.getGovParam('vault_reclaim_years', '20')) || 20;
    const graceMs       = reclaimYears * 365.25 * 24 * 60 * 60 * 1000;
    const livenessFloor = Math.floor((now - graceMs) / 1000);  // epoch SECONDS (matches liveness_ts)
    const disposition   = this._db.getGovParam('reclamation_disposition', 'steward_operator_pool');

    const reclaimable = this._db._db.prepare(`
      SELECT v.* FROM sov_vaults v
      LEFT JOIN sov_disc d ON d.sovereign_id = v.owner_id
      WHERE v.status = 'locked' AND v.reclaim_at < ?
        AND COALESCE(d.liveness_ts, 0) < ?
    `).all(now, livenessFloor);

    for (const vault of reclaimable) {
      // Always broadcast that this vault reached the grace (so the network + family search
      // know it is now openly claimable). Public locator only — never any key.
      this._peerMesh.broadcast('RECLAMATION_PROPOSED', {
        vault_id: vault.vault_id, owner_id: vault.owner_id,
        amount_seeds: vault.amount_seeds, disposition,
        node_id: this._identity.nodeId,
      });

      if (disposition === 'keep_idle') {
        // Governance chose to hold idle — leave 'locked' so the owner/heir can still
        // claim directly; re-checked each maintenance cycle. No fund movement.
        continue;
      }
      this._stewardVault(vault, now, reclaimYears);
    }
  }

  // Idempotent reversible-steward of one vault into the operator pool. The ledger PK
  // (vault_id) gates the pool credit to EXACTLY ONCE per node, so neither the local
  // maintenance pass nor a peer RECLAMATION_PROPOSED can double-credit. Called from
  // both _runMaintenance and _handleReclamationProposed → all nodes converge.
  _stewardVault(vault, now, reclaimYears) {
    try {
      const r = this._db._db.prepare(`
        INSERT OR IGNORE INTO sov_reclamation_ledger
          (vault_id, owner_id, amount_seeds, stewarded_to, restorable, stewarded_at)
        VALUES (?, ?, ?, 'witness_operator', 1, ?)
      `).run(vault.vault_id, vault.owner_id, vault.amount_seeds, now);
      if (r.changes > 0) {
        this._db._db.prepare("UPDATE sov_vaults SET status = 'stewarded' WHERE vault_id = ? AND status = 'locked'").run(vault.vault_id);
        // 1.4.90: vault holding -> operator pool as ONE op with a deterministic id, so the pool is
        // credited once network-wide however many nodes reach this (it was once per node).
        const r2 = this._db.ledger && this._db.ledger.commitSystemOp({
          op_id: `vault-steward:${vault.vault_id}`, kind: 'vault_steward', ref: vault.vault_id,
          holds: [{ id: 'vault:' + vault.vault_id, d: -vault.amount_seeds }],
          pools: [{ pool: 'witness_operator', d: vault.amount_seeds }],
        });
        if (r2 && !r2.ok && r2.error !== 'LEDGER_DUPLICATE') global.sovLog.error(`[FINANCE] steward ${vault.vault_id}: ${r2.error}`);
        global.sovLog.info(
          `      [FINANCE] Vault ${vault.vault_id} STEWARDED (reversible) to witness_operator after the ${reclaimYears || '20'}yr grace — ${vault.amount_seeds} seeds; restorable to owner/heir forever.`
        );
      }
    } catch (e) { global.sovLog.warn('[FINANCE] _stewardVault: ' + e.message); }
  }

  // Peer reached the grace + decided to steward a vault — converge our copy (idempotent).
  _handleReclamationProposed(msg) {
    if (!msg || !msg.vault_id || msg.node_id === this._identity.nodeId) return;
    if (msg.disposition === 'keep_idle') return;  // nothing to move
    const vault = this._db._db.prepare('SELECT * FROM sov_vaults WHERE vault_id = ?').get(msg.vault_id);
    if (vault && (vault.status === 'locked' || vault.status === 'stewarded')) {
      this._stewardVault(vault, Date.now(), null);
    }
  }

  // ── Send helper ───────────────────────────────────────────────────────────

  static get _RESULT_TYPE() {
    return {
      'RPC': 'SOV_REQUEST_CREATED',
      'RPL': 'SOV_REQUEST_LIST_RESULT',
      'RPN': 'PAY_REQ_NOTIFY',
      'VLC': 'VAULT_LOCK_RESULT',
      'VCI': 'VAULT_CLAIM_RESULT',
      'ICR': 'ISSUANCE_CLAIM_RESULT',
      'GAR': 'GUARDIAN_ADD_RESULT',
      'GRR': 'GUARDIAN_REMOVE_RESULT',
      'GRL': 'GUARDIAN_LIST_RESULT',
      'GRC': 'GUARDIAN_RECOVERY_INIT_RESULT',
      'GAA': 'GUARDIAN_APPROVE_RESULT',
      'GRJ': 'GUARDIAN_REJECT_RESULT',
      'GAU': 'GUARDIAN_APPROVAL_UPDATE',   // 1.4.94 (D59): progress to the recovering device
    };
  }

  _send(ws, op, payload) {
    if (!ws || ws.readyState !== 1) return;
    const type = (payload && payload.type) || FinancialEngine._RESULT_TYPE[op] || op;
    ws.send(JSON.stringify({ op, type, ...payload }));
  }
}

module.exports = { FinancialEngine };
