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
//   3. Monetary Issuance (Universal Basic Income)
//      When governance activates sov_issuance_rate > 0, every enrolled citizen
//      can claim N SOV seeds per epoch. Pull-based: citizen triggers claim.
//      Cross-node dedup via sov_issuance_log (INSERT OR IGNORE pattern).
//
//   4. Guardian Recovery
//      Citizens nominate trusted contacts as guardians. On device loss,
//      recovery collects guardian approvals and restores the citizen's disc
//      entry with the new device's public key.
// ─────────────────────────────────────────────────────────────────────────────

'use strict';

const crypto = require('crypto');

// Maximum optimistic concurrency retries for balance operations
const MAX_RETRIES = 3;

// Issuance epoch precision: one epoch = issuance_epoch_hours of wall time
function _epochId(epochHours) {
  const ms = epochHours * 60 * 60 * 1000;
  return String(Math.floor(Date.now() / ms));
}

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
      ['sov_issuance_rate',            '0'],
      ['issuance_epoch_hours',         '24'],
      ['issuance_max_backlog_epochs',  '7'],
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

  handleVaultLock(ws, msg) {
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

    // SECURITY FIX (C1, 2026-08-05): the locked amount must leave BOTH balance and
    // spendable — the money moves out of the wallet and into the vault. The old code
    // deducted only spendable and left balance intact, so a later claim (which credits
    // balance+spendable) minted the amount a second time. Lock+claim-your-own-vault was
    // a free, uncapped self-mint. A vault is a TRANSFER, not a reservation.
    for (let attempt = 0; attempt < MAX_RETRIES; attempt++) {
      const current = this._db.readDisc(owner_id);
      if (!current || current.spendable_seeds < amount_seeds || current.balance_seeds < amount_seeds) break;

      const ok = this._db.writeDiscGuarded(
        owner_id,
        current.balance_seeds   - amount_seeds,      // balance reduced (money leaves wallet)
        current.spendable_seeds - amount_seeds,      // spendable reduced
        current.version
      );
      if (!ok) continue;  // Version race — retry

      // Create vault record
      const now = Date.now();
      // Reclamation grace period — king 2026-06-04: 20 years (was 15). Governable
      // via the vault_reclaim_years param (§4b); falls back to 20 if unseeded.
      let reclaimYears = 20;
      try { reclaimYears = parseInt(this._db.getGovParam('vault_reclaim_years', '20')) || 20; } catch (_) {}
      const RECLAIM_MS = reclaimYears * 365.25 * 24 * 60 * 60 * 1000;
      try {
        this._db._db.prepare(`
          INSERT OR IGNORE INTO sov_vaults
            (vault_id, owner_id, amount_seeds, claim_key_hash, status, locked_at, reclaim_at)
          VALUES (?, ?, ?, ?, 'locked', ?, ?)
        `).run(vault_id, owner_id, amount_seeds, claim_key_hash, now, now + RECLAIM_MS);
      } catch (_) {
        // vault_id already exists — revert BOTH balance and spendable (C1 fix)
        this._db.writeDiscGuarded(owner_id, current.balance_seeds + amount_seeds, current.spendable_seeds + amount_seeds, current.version + 1);
        this._send(ws, 'VLC', { success: false, error: 'VAULT_ID_EXISTS' });
        return;
      }

      // Broadcast vault creation to peers
      this._peerMesh.broadcast('VAULT_BROADCAST', {
        vault_id, owner_id, amount_seeds, claim_key_hash,
        locked_at: now, reclaim_at: now + RECLAIM_MS,
        origin_node: this._identity.nodeId,
      });

      this._send(ws, 'VLC', { success: true, vault_id, amount_seeds, ts: now });
      return;
    }

    this._send(ws, 'VLC', { success: false, error: 'BALANCE_UPDATE_FAILED' });
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
    // Reversible-stewardship RESTORE (king 2026-06-04): if this vault was stewarded to
    // the operator pool during reclamation, its funds live in the pool — pull them back
    // BEFORE crediting the claimant. A claim (returning owner OR verified heir) ALWAYS
    // outranks the stewardship, so no honest fund is ever permanently lost.
    try {
      const led = this._db._db.prepare(
        "SELECT * FROM sov_reclamation_ledger WHERE vault_id = ? AND restorable = 1"
      ).get(vault.vault_id);
      if (led) {
        if (this._db.drawFromPool) this._db.drawFromPool(led.stewarded_to || 'witness_operator', led.amount_seeds);
        else if (this._db.deductFromPool) this._db.deductFromPool(led.stewarded_to || 'witness_operator', led.amount_seeds);
        this._db._db.prepare(
          "UPDATE sov_reclamation_ledger SET restorable = 0, restored_at = ?, restored_to = ? WHERE vault_id = ?"
        ).run(now, claimantId, vault.vault_id);
        global.sovLog.info(`      [FINANCE] Vault ${vault.vault_id} RESTORED from ${led.stewarded_to} pool to ${claimantId} — stewardship reversed (no fund lost).`);
      }
    } catch (e) { global.sovLog.warn('[FINANCE] steward-restore: ' + e.message); }

    // Mark vault as claimed
    this._db._db.prepare(
      "UPDATE sov_vaults SET status = 'claimed' WHERE vault_id = ?"
    ).run(vault.vault_id);

    // Credit claimant's balance
    for (let attempt = 0; attempt < MAX_RETRIES; attempt++) {
      const current = this._db.readDisc(claimantId);
      if (!current) {
        this._db.ensureDiscEntry(claimantId);
        continue;
      }
      const ok = this._db.writeDiscGuarded(
        claimantId,
        current.balance_seeds   + vault.amount_seeds,
        current.spendable_seeds + vault.amount_seeds,
        current.version
      );
      if (ok) {
        if (this._gateway) {
          this._gateway.push(claimantId, 'VCR', {  // VAULT_CLAIM_RESULT
            success:      true,
            vault_id:     vault.vault_id,
            claim_id:     claimId,
            amount_seeds: vault.amount_seeds,
            ts:           now,
          });
        }
        // Notify peers
        this._peerMesh.broadcast('VAULT_CLAIM_BROADCAST', {
          vault_id:    vault.vault_id,
          claimant_id: claimantId,
          amount_seeds: vault.amount_seeds,
          origin_node: this._identity.nodeId,
        });
        return;
      }
    }
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

  _handleVaultClaimBroadcast(msg) {
    const { vault_id, claimant_id, origin_node } = msg;
    if (!vault_id || origin_node === this._identity.nodeId) return;

    this._db._db.prepare(
      "UPDATE sov_vaults SET status = 'claimed' WHERE vault_id = ? AND status = 'locked'"
    ).run(vault_id);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  SUBSYSTEM 3 — MONETARY ISSUANCE (UBI)
  // ═══════════════════════════════════════════════════════════════════════════

  // Called when a citizen HELLOs — check if they have unclaimed epochs
  checkIssuanceOnHello(sovereignId, ws) {
    const issuanceRate = parseInt(this._db.getGovParam('sov_issuance_rate', '0'));
    if (issuanceRate <= 0) return;  // Issuance not active

    const epochHours  = parseInt(this._db.getGovParam('issuance_epoch_hours', '24'));
    const maxBacklog  = parseInt(this._db.getGovParam('issuance_max_backlog_epochs', '7'));

    const currentEpochId = _epochId(epochHours);
    const currentEpoch   = parseInt(currentEpochId);

    // Find unclaimed epochs (up to maxBacklog)
    const unclaimedEpochs = [];
    for (let i = 0; i < maxBacklog; i++) {
      const epochId = String(currentEpoch - i);
      const claimed = this._db._db.prepare(
        'SELECT 1 FROM sov_issuance_log WHERE epoch_id = ? AND citizen_id = ?'
      ).get(epochId, sovereignId);
      if (!claimed) unclaimedEpochs.push(epochId);
    }

    if (unclaimedEpochs.length > 0) {
      const totalSeeds = unclaimedEpochs.length * issuanceRate;
      if (ws && ws.readyState === 1) {
        ws.send(JSON.stringify({
          op:           'IA',  // ISSUANCE_AVAILABLE
          epoch_ids:    unclaimedEpochs,
          amount_seeds: totalSeeds,
          ts:           Date.now(),
        }));
      }
    }
  }

  handleIssuanceClaim(ws, msg) {
    const { epoch_ids } = msg;
    const citizen_id   = ws._sovereignId;

    if (!Array.isArray(epoch_ids) || epoch_ids.length === 0) {
      this._send(ws, 'ICR', { success: false, error: 'MISSING_EPOCH_IDS' });
      return;
    }

    const issuanceRate = parseInt(this._db.getGovParam('sov_issuance_rate', '0'));
    if (issuanceRate <= 0) {
      this._send(ws, 'ICR', { success: false, error: 'ISSUANCE_NOT_ACTIVE' });
      return;
    }

    const maxBacklog = parseInt(this._db.getGovParam('issuance_max_backlog_epochs', '7'));
    const epochHours = parseInt(this._db.getGovParam('issuance_epoch_hours', '24'));
    const now        = Date.now();
    const currentEpoch = parseInt(_epochId(epochHours));

    let totalCredited = 0;
    const credited_epochs = [];

    for (const epochId of epoch_ids.slice(0, maxBacklog)) {
      const epochNum = parseInt(epochId);
      // Reject future epochs and epochs beyond backlog
      if (epochNum > currentEpoch) continue;
      if (currentEpoch - epochNum >= maxBacklog) continue;

      try {
        this._db._db.prepare(`
          INSERT OR IGNORE INTO sov_issuance_log
            (epoch_id, citizen_id, amount_seeds, issued_at)
          VALUES (?, ?, ?, ?)
        `).run(epochId, citizen_id, issuanceRate, now);

        if (this._db._db.prepare('SELECT changes() as c').get().c === 1) {
          // Actually inserted (not duplicate)
          totalCredited += issuanceRate;
          credited_epochs.push(epochId);
        }
      } catch (_) {}
    }

    if (totalCredited > 0) {
      // Credit balance with optimistic concurrency
      for (let attempt = 0; attempt < MAX_RETRIES; attempt++) {
        const current = this._db.readDisc(citizen_id);
        if (!current) break;
        const ok = this._db.writeDiscGuarded(
          citizen_id,
          current.balance_seeds   + totalCredited,
          current.spendable_seeds + totalCredited,
          current.version
        );
        if (ok) break;
      }

      // Send live balance update
      if (this._gateway) {
        this._gateway.push(citizen_id, 'SV', {  // SOV_TRANSFER_RECEIVED
          from_id:      'SOV-NETWORK',
          amount_seeds: totalCredited,
          memo:         `SOV issuance — ${credited_epochs.length} epoch(s)`,
          ts:           now,
        });
      }

      // Broadcast to peers for dedup
      this._peerMesh.broadcast('ISSUANCE_LOG_BROADCAST', {
        citizen_id,
        epoch_ids:    credited_epochs,
        amount_seeds: issuanceRate,
        origin_node:  this._identity.nodeId,
      });
    }

    this._send(ws, 'ICR', {
      success:          true,
      credited_seeds:   totalCredited,
      credited_epochs,
      ts:               now,
    });
  }

  _handleIssuanceLogBroadcast(msg) {
    const { citizen_id, epoch_ids, amount_seeds, origin_node } = msg;
    if (!citizen_id || !Array.isArray(epoch_ids)) return;
    if (origin_node === this._identity.nodeId) return;

    const now = Date.now();
    for (const epochId of epoch_ids) {
      try {
        this._db._db.prepare(`
          INSERT OR IGNORE INTO sov_issuance_log
            (epoch_id, citizen_id, amount_seeds, issued_at)
          VALUES (?, ?, ?, ?)
        `).run(epochId, citizen_id, amount_seeds || 0, now);
      } catch (_) {}
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  SUBSYSTEM 4 — GUARDIAN RECOVERY
  // ═══════════════════════════════════════════════════════════════════════════

  handleGuardianAdd(ws, msg) {
    const { guardian_id } = msg;
    const citizen_id      = ws._sovereignId;

    if (!guardian_id) {
      this._send(ws, 'GAR', { success: false, error: 'MISSING_GUARDIAN_ID' });
      return;
    }

    const maxCount = parseInt(this._db.getGovParam('guardian_max_count', '5'));
    const current  = this._db._db.prepare(
      'SELECT COUNT(*) as c FROM sov_guardians WHERE citizen_id = ?'
    ).get(citizen_id).c;

    if (current >= maxCount) {
      this._send(ws, 'GAR', { success: false, error: 'GUARDIAN_LIMIT_REACHED' });
      return;
    }

    this._db._db.prepare(`
      INSERT OR IGNORE INTO sov_guardians (citizen_id, guardian_id, added_at)
      VALUES (?, ?, ?)
    `).run(citizen_id, guardian_id, Date.now());

    // Notify the guardian if online
    const now = Date.now();
    if (this._gateway) {
      this._gateway.push(guardian_id, 'GIN', {  // GUARDIAN_INVITE
        citizen_id, ts: now,
      });
    }

    // Broadcast to peers so they can deliver the invite cross-node
    this._peerMesh.broadcast('GUARDIAN_INVITE_BROADCAST', {
      citizen_id, guardian_id, ts: now,
      origin_node: this._identity.nodeId,
    });

    this._send(ws, 'GAR', { success: true, guardian_id, ts: now });
  }

  handleGuardianRemove(ws, msg) {
    const { guardian_id } = msg;
    const citizen_id      = ws._sovereignId;

    if (!guardian_id) return;
    this._db._db.prepare(
      'DELETE FROM sov_guardians WHERE citizen_id = ? AND guardian_id = ?'
    ).run(citizen_id, guardian_id);

    this._send(ws, 'GRR', { success: true, guardian_id, ts: Date.now() });
  }

  handleGuardianList(ws, msg) {
    const citizen_id = ws._sovereignId;
    const rows = this._db._db.prepare(
      'SELECT guardian_id, added_at FROM sov_guardians WHERE citizen_id = ? ORDER BY added_at ASC'
    ).all(citizen_id);

    this._send(ws, 'GRL', { guardians: rows, ts: Date.now() });
  }

  handleRecoveryRequest(ws, msg) {
    const { request_id, citizen_id, new_pub_key } = msg;

    if (!request_id || !citizen_id || !new_pub_key) {
      this._send(ws, 'GRC', { success: false, error: 'MISSING_FIELDS' });
      return;
    }

    if (!/^[0-9a-f]{64}$/i.test(new_pub_key)) {
      this._send(ws, 'GRC', { success: false, error: 'INVALID_PUBLIC_KEY' });
      return;
    }

    const now       = Date.now();
    const windowHrs = parseInt(this._db.getGovParam('guardian_recovery_window_hours', '72'));
    const expiresAt = now + windowHrs * 60 * 60 * 1000;

    try {
      this._db._db.prepare(`
        INSERT OR IGNORE INTO sov_recovery_requests
          (request_id, citizen_id, new_pub_key, status, created_at, expires_at)
        VALUES (?, ?, ?, 'pending', ?, ?)
      `).run(request_id, citizen_id, new_pub_key, now, expiresAt);
    } catch (_) {
      this._send(ws, 'GRC', { success: false, error: 'REQUEST_EXISTS' });
      return;
    }

    // Find all guardians and push GUARDIAN_APPROVAL_REQUEST to them
    const guardians = this._db._db.prepare(
      'SELECT guardian_id FROM sov_guardians WHERE citizen_id = ?'
    ).all(citizen_id);

    const approvalPayload = { request_id, citizen_id, expires_at: expiresAt, ts: now };

    for (const { guardian_id } of guardians) {
      if (this._gateway) {
        this._gateway.push(guardian_id, 'GAP', approvalPayload);  // GUARDIAN_APPROVAL_REQUEST
      }
    }

    // Broadcast to peers for cross-node guardian notification
    this._peerMesh.broadcast('GUARDIAN_RECOVERY_BROADCAST', {
      request_id, citizen_id,
      guardian_ids: guardians.map(r => r.guardian_id),
      expires_at:   expiresAt,
      origin_node:  this._identity.nodeId,
    });

    this._send(ws, 'GRC', {
      success:    true,
      request_id,
      citizen_id,
      guardian_count: guardians.length,
      expires_at: expiresAt,
      ts:         now,
    });
  }

  handleGuardianApprove(ws, msg) {
    const { request_id } = msg;
    const guardian_id    = ws._sovereignId;

    if (!request_id) return;

    const req = this._db._db.prepare(
      'SELECT * FROM sov_recovery_requests WHERE request_id = ? AND status = ?'
    ).get(request_id, 'pending');

    if (!req) {
      this._send(ws, 'GAA', { success: false, error: 'REQUEST_NOT_FOUND' });
      return;
    }

    if (req.expires_at < Date.now()) {
      this._send(ws, 'GAA', { success: false, error: 'REQUEST_EXPIRED' });
      return;
    }

    // Verify this citizen is actually a guardian
    const isGuardian = this._db._db.prepare(
      'SELECT 1 FROM sov_guardians WHERE citizen_id = ? AND guardian_id = ?'
    ).get(req.citizen_id, guardian_id);

    if (!isGuardian) {
      this._send(ws, 'GAA', { success: false, error: 'NOT_A_GUARDIAN' });
      return;
    }

    // Add approval
    let approvals;
    try { approvals = JSON.parse(req.approvals); } catch (_) { approvals = []; }
    if (approvals.includes(guardian_id)) {
      this._send(ws, 'GAA', { success: false, error: 'ALREADY_APPROVED' });
      return;
    }
    approvals.push(guardian_id);

    this._db._db.prepare(
      'UPDATE sov_recovery_requests SET approvals = ? WHERE request_id = ?'
    ).run(JSON.stringify(approvals), request_id);

    const threshold = parseInt(this._db.getGovParam('guardian_approval_threshold', '2'));

    if (approvals.length >= threshold) {
      // Threshold met — execute recovery
      this._executeGuardianRecovery(req, approvals);
    }

    // Broadcast approval to peers
    this._peerMesh.broadcast('GUARDIAN_APPROVAL_BROADCAST', {
      request_id, guardian_id, approvals,
      origin_node: this._identity.nodeId,
    });

    this._send(ws, 'GAA', {
      success:      true,
      request_id,
      approvals:    approvals.length,
      threshold,
      threshold_met: approvals.length >= threshold,
      ts:           Date.now(),
    });
  }

  handleGuardianReject(ws, msg) {
    const { request_id } = msg;
    const guardian_id    = ws._sovereignId;

    if (!request_id) return;

    const req = this._db._db.prepare(
      "SELECT citizen_id FROM sov_recovery_requests WHERE request_id = ? AND status = 'pending'"
    ).get(request_id);

    if (!req) return;

    // Notify recovering citizen of rejection
    if (this._gateway) {
      this._gateway.push(req.citizen_id, 'GRJ', {  // GUARDIAN_REJECTION
        request_id, rejected_by: guardian_id, ts: Date.now(),
      });
    }

    this._send(ws, 'GRJ', { success: true, request_id, ts: Date.now() });
  }

  _executeGuardianRecovery(req, approvals) {
    const now = Date.now();

    // Update disc entry with new public key
    this._db._db.prepare(
      'UPDATE sov_enrollments SET public_key_hex = ? WHERE sovereign_id = ?'
    ).run(req.new_pub_key, req.citizen_id);

    // Mark request approved
    this._db._db.prepare(
      "UPDATE sov_recovery_requests SET status = 'approved' WHERE request_id = ?"
    ).run(req.request_id);

    // Notify recovering citizen
    if (this._gateway) {
      this._gateway.push(req.citizen_id, 'GCO', {  // GUARDIAN_RECOVERY_COMPLETE
        request_id:  req.request_id,
        new_pub_key: req.new_pub_key,
        approved_by: approvals,
        ts:          now,
      });
    }

    global.sovLog.info(
      `      [FINANCE] Guardian recovery completed for ${req.citizen_id} — ${approvals.length} approvals`
    );
  }

  _handleGuardianInviteBroadcast(msg) {
    const { citizen_id, guardian_id, origin_node } = msg;
    if (!citizen_id || !guardian_id || origin_node === this._identity.nodeId) return;

    // Push invite to guardian if they are on this node
    if (this._gateway) {
      this._gateway.push(guardian_id, 'GIN', { citizen_id, ts: Date.now() });
    }
  }

  _handleGuardianRecoveryBroadcast(msg) {
    const { request_id, citizen_id, guardian_ids, expires_at, origin_node } = msg;
    if (!request_id || origin_node === this._identity.nodeId) return;

    // Push approval request to any guardians online on this node
    if (this._gateway && Array.isArray(guardian_ids)) {
      const payload = { request_id, citizen_id, expires_at, ts: Date.now() };
      for (const gid of guardian_ids) {
        this._gateway.push(gid, 'GAP', payload);
      }
    }
  }

  _handleGuardianApprovalBroadcast(msg) {
    const { request_id, guardian_id, approvals, origin_node } = msg;
    if (!request_id || origin_node === this._identity.nodeId) return;

    const req = this._db._db.prepare(
      "SELECT * FROM sov_recovery_requests WHERE request_id = ? AND status = 'pending'"
    ).get(request_id);
    if (!req) return;

    // Sync approvals list
    this._db._db.prepare(
      'UPDATE sov_recovery_requests SET approvals = ? WHERE request_id = ?'
    ).run(JSON.stringify(approvals || [guardian_id]), request_id);

    const threshold = parseInt(this._db.getGovParam('guardian_approval_threshold', '2'));
    if (Array.isArray(approvals) && approvals.length >= threshold) {
      this._executeGuardianRecovery(req, approvals);
    }
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
        if (this._db.addToPool) this._db.addToPool('witness_operator', vault.amount_seeds);
        else if (this._db.refundPool) this._db.refundPool('witness_operator', vault.amount_seeds);
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
    };
  }

  _send(ws, op, payload) {
    if (!ws || ws.readyState !== 1) return;
    const type = (payload && payload.type) || FinancialEngine._RESULT_TYPE[op] || op;
    ws.send(JSON.stringify({ op, type, ...payload }));
  }
}

module.exports = { FinancialEngine };
