// ─────────────────────────────────────────────────────────────────────────────
// TRANSFER ENGINE — SOV coin transfer protocol
// ─────────────────────────────────────────────────────────────────────────────
// Handles all SOV transfers between citizens.
//
// Since 1.4.90 a transfer is ONE ledger op (protocol/ledger.js, storage/db.js ledgerApply):
//   sender −(amount + fee), recipient +amount, fee → witness_operator pool.
//
//   1. Validate fields; verify the citizen's signature over this transfer.
//   2. Automated-wallet caps, payment-request check.
//   3. Nonce must be the sender's next (anti-replay); balance must cover amount + fee.
//   4. ledger.commitOwnerOp: a MAJORITY of the node set must grant this exact op for
//      (sender, nonce). Every node grants at most one op per slot, so two spends of the
//      same money can never both commit, whichever nodes they reach. Silence is a no.
//   5. The op is applied atomically here, broadcast, and kept; peers apply it atomically
//      (never a credit without its debit) and fetch any op they missed by digest/pull.
//
// Before 1.4.90 a "spend lock" approved on silence and with zero peers, and a relayed
// transfer credited the recipient even when the sender could not be debited — see
// docs/ledger/ for the record. Do not reintroduce either.
// ─────────────────────────────────────────────────────────────────────────────

'use strict';

const crypto = require('crypto');
const { MSG_TYPE } = require('../network/citizen_gateway');

class TransferEngine {

  constructor(identity, db, peerMesh, gatewayRef) {
    this._identity  = identity;
    this._db        = db;
    this._peerMesh  = peerMesh;
    this._gateway   = gatewayRef; // set after gateway starts

    // Register peer message handlers
    peerMesh.on('AUTOMATION_POLICY_SYNC', (msg) => this._handleAutomationPolicySync(msg));

    // Ledger (1.4.90): peers check a transfer op is exactly the citizen's signed transfer
    // before granting its slot or applying it; and each node tells a recipient connected
    // HERE when the op applies here.
    if (db.ledger) {
      db.ledger.setValidator('transfer', (op) => this._validateTransferOp(op));
      db.ledger.onApplied((op, local) => { if (!local && op.kind === 'transfer') this._notifyRecipient(op.transfer); });
    }
  }

  setGateway(gateway) {
    this._gateway = gateway;
  }

  setFinancialEngine(financialEngine) {
    this._financialEngine = financialEngine;
  }

  // ── Main entry point — called by CitizenGateway ───────────────────────────

  async handleTransfer(ws, msg, gateway) {
    // Accept both legacy field names (from_sovereign_id/to_sovereign_id)
    // and new field names (from_id/to_id) — Flutter app uses legacy names
    const tx_id              = msg.tx_id;
    const from_id            = msg.from_id            || msg.from_sovereign_id || ws._sovereignId;
    const to_id              = msg.to_id              || msg.to_sovereign_id;
    const amount_seeds       = msg.amount_seeds;
    const memo               = msg.memo;
    const tx_nonce           = msg.tx_nonce           || msg.nonce;
    const signature          = msg.signature;
    const timestamp          = msg.timestamp;
    const payment_request_id = msg.payment_request_id;

    // ── Basic validation ─────────────────────────────────────────────────────
    if (!tx_id || !from_id || !to_id || !amount_seeds || !tx_nonce) {
      gateway.push(ws._sovereignId, MSG_TYPE.SOV_TRANSFER_RESULT, {
        tx_id, success: false, error: 'MISSING_FIELDS',
      });
      return;
    }

    if (from_id !== ws._sovereignId) {
      gateway.push(ws._sovereignId, MSG_TYPE.SOV_TRANSFER_RESULT, {
        tx_id, success: false, error: 'SENDER_MISMATCH',
      });
      return;
    }

    // SECURITY FIX: Reject transfers from unsigned (legacy) connections.
    // Without Ed25519 proof of sovereign_id ownership any caller can claim
    // another citizen's ID and pass the SENDER_MISMATCH check above.
    // Legacy mode is kept only for non-financial read operations.
    if (ws._legacyMode) {
      gateway.push(ws._sovereignId, MSG_TYPE.SOV_TRANSFER_RESULT, {
        tx_id, success: false, error: 'SIGNATURE_REQUIRED',
        message: 'SOV transfers require a signed HELLO. Please update the SOV app.',
      });
      return;
    }

    // ── Per-transaction signature ────────────────────────────────────────────
    // The signed HELLO above proves this connection belongs to the citizen. It
    // does NOT prove the citizen authorised THIS payment — the node could have
    // composed it after they connected. Verifying the envelope signature binds
    // their key to this amount, recipient and nonce, and gives peers something
    // they can check for themselves instead of trusting whoever relayed it.
    const sigCheck = this._verifyTransferSignature(ws, msg);
    const sigMode  = this._getGovParam
      // Secure by default for a node with NO governance row. A node that HAS the row uses it,
      // and the live fleet's row read 'log' (measured 2026-09-30 and 2026-10-08).
      ? String(this._getGovParam('tx_signature_enforce', 'reject'))
      : 'log';

    if (!sigCheck.valid) {
      global.sovLog.warn(
        `[TX-SIG] ${sigCheck.checked ? 'INVALID' : 'UNVERIFIED'} tx=${String(tx_id).slice(0, 16)} ` +
        `from=${String(from_id).slice(0, 16)} reason=${sigCheck.reason} mode=${sigMode}`);
      if (sigMode === 'reject') {
        gateway.push(ws._sovereignId, MSG_TYPE.SOV_TRANSFER_RESULT, {
          tx_id, success: false, error: 'INVALID_SIGNATURE',
        });
        return;
      }
    } else {
      global.sovLog.info(`[TX-SIG] verified tx=${String(tx_id).slice(0, 16)}`);
    }

    if (amount_seeds <= 0 || !Number.isInteger(amount_seeds)) {
      gateway.push(ws._sovereignId, MSG_TYPE.SOV_TRANSFER_RESULT, {
        tx_id, success: false, error: 'INVALID_AMOUNT',
      });
      return;
    }

    // Verify timestamp freshness (within 60 seconds)
    if (Math.abs(Date.now() - (timestamp || 0)) > 60000) {
      gateway.push(ws._sovereignId, MSG_TYPE.SOV_TRANSFER_RESULT, {
        tx_id, success: false, error: 'STALE_TIMESTAMP',
      });
      return;
    }

    // ── Guard 0: Automated-wallet spend policy (network-enforced) ─────────────
    // If the sender registered an automated-wallet policy, the NODE enforces
    // its caps + allowlist here — before any funds move — so a compromised PC
    // that holds the signing key still cannot exceed the citizen's own limits.
    // This runs on every node, so the attacker cannot pick a node that skips it.
    const autoPol = this._resolveAutomationPolicy(from_id);
    if (autoPol && autoPol.enabled) {
      if (autoPol.allowlist.length > 0 && !autoPol.allowlist.includes(to_id)) {
        gateway.push(ws._sovereignId, MSG_TYPE.SOV_TRANSFER_RESULT, {
          tx_id, success: false, error: 'DEST_NOT_ALLOWLISTED',
          message: 'Automated wallet: recipient is not on your allowlist.',
        });
        return;
      }
      if (autoPol.per_tx_cap > 0 && amount_seeds > autoPol.per_tx_cap) {
        gateway.push(ws._sovereignId, MSG_TYPE.SOV_TRANSFER_RESULT, {
          tx_id, success: false, error: 'OVER_PER_TX_CAP',
          per_tx_cap_seeds: autoPol.per_tx_cap,
        });
        return;
      }
      if (autoPol.daily_cap > 0) {
        const spent24h = this._db.sumAutomationSpend24h(from_id);
        if (spent24h + amount_seeds > autoPol.daily_cap) {
          gateway.push(ws._sovereignId, MSG_TYPE.SOV_TRANSFER_RESULT, {
            tx_id, success: false, error: 'OVER_DAILY_CAP',
            daily_cap_seeds: autoPol.daily_cap,
            spent_24h_seeds: spent24h,
          });
          return;
        }
      }
    }

    // ── Payment request pre-flight check ─────────────────────────────────────
    // If this transfer fulfils a payment request, verify it is still valid
    // (not already paid, not cancelled, not expired) before locking funds.
    if (payment_request_id && this._financialEngine) {
      const valid = this._financialEngine.isPaymentRequestValid(payment_request_id);
      if (valid === false) {
        gateway.push(ws._sovereignId, MSG_TYPE.SOV_TRANSFER_RESULT, {
          tx_id, success: false, error: 'PAYMENT_REQUEST_ALREADY_PAID',
        });
        return;
      }
    }

    // ── Ledger op (1.4.90) — docs/ledger/LEDGER_SAFETY_1.4.90_PLAN.md ─────────
    // The whole transfer is ONE op: sender −(amount+fee), recipient +amount, fee →
    // operator pool. It commits only after a MAJORITY of nodes granted this exact op
    // for (sender, nonce); every node grants at most one op per slot, so two spends of
    // the same money cannot both commit, whichever nodes they were sent to. Peers apply
    // the op atomically (no credit without its debit) and fetch any op they missed.
    const senderDisc = this._db.readDisc(from_id);
    if (!senderDisc) {
      gateway.push(ws._sovereignId, MSG_TYPE.SOV_TRANSFER_RESULT, {
        tx_id, success: false, error: 'SENDER_NOT_ENROLLED',
      });
      return;
    }
    const expectedNonce = senderDisc.nonce + 1;
    if (tx_nonce !== expectedNonce) {
      gateway.push(ws._sovereignId, MSG_TYPE.SOV_TRANSFER_RESULT, {
        tx_id, success: false,
        error:          tx_nonce < expectedNonce ? 'NONCE_ALREADY_USED' : 'NONCE_FUTURE',
        expected_nonce: expectedNonce,
      });
      return;
    }

    // Fee = min(amount × tx_fee_rate, tx_fee_max_sov) — both citizen-votable; cap 0 = uncapped.
    const feeRate     = parseFloat(this._db.getGovParam('tx_fee_rate', '0.001'));
    let   feeSeeds    = Math.ceil(amount_seeds * feeRate);
    const feeMaxSov   = parseFloat(this._db.getGovParam('tx_fee_max_sov', '1'));
    const feeCapSeeds = Math.floor(feeMaxSov * 1_000_000);
    if (feeCapSeeds > 0 && feeSeeds > feeCapSeeds) feeSeeds = feeCapSeeds;
    const totalCost   = amount_seeds + feeSeeds;

    if (senderDisc.spendable_seeds < totalCost) {
      gateway.push(ws._sovereignId, MSG_TYPE.SOV_TRANSFER_RESULT, {
        tx_id, success: false, error: 'INSUFFICIENT_BALANCE',
        balance_seeds: senderDisc.spendable_seeds, required_seeds: totalCost,
      });
      return;
    }

    const txHash = crypto.createHash('sha256')
      .update(`${tx_id}:${from_id}:${to_id}:${amount_seeds}:${tx_nonce}:${timestamp}`)
      .digest('hex');
    const confirmedAt = Date.now();

    const res = await this._db.ledger.commitOwnerOp({
      kind:    'transfer',
      op_id:   `tx:${from_id}:${tx_id}`,          // scoped per sender: another citizen's tx_id can't collide
      owner:   { acct: from_id, nonce: tx_nonce },
      moves:   [{ acct: from_id, d: -totalCost }, { acct: to_id, d: amount_seeds }],
      pools:   feeSeeds > 0 ? [{ pool: 'witness_operator', d: feeSeeds }] : [],
      tx_record: { tx_id, tx_hash: txHash, from_id, to_id, amount_seeds, memo: memo || '',
                   confirmed_at: confirmedAt, created_at: timestamp || confirmedAt },
      transfer: { tx_id, tx_hash: txHash, from_id, to_id, amount_seeds, fee_seeds: feeSeeds,
                  memo: memo || '', confirmed_at: confirmedAt },
      signed_tx: msg,
    });
    if (!res.ok) {
      gateway.push(ws._sovereignId, MSG_TYPE.SOV_TRANSFER_RESULT, {
        tx_id, success: false, error: res.error,
        ...(res.expected_nonce != null ? { expected_nonce: res.expected_nonce } : {}),
      });
      return;
    }

    // Record automated-wallet spend for the rolling 24h daily-cap window.
    if (autoPol && autoPol.enabled) {
      try { this._db.recordAutomationSpend(from_id, amount_seeds); } catch (_) {}
    }
    if (payment_request_id && this._financialEngine) {
      this._financialEngine.markPaymentRequestPaid(payment_request_id, from_id);
    }

    const newSenderDisc = this._db.readDisc(from_id);
    gateway.push(from_id, MSG_TYPE.SOV_TRANSFER_RESULT, {
      tx_id, tx_hash: txHash, success: true, confirmed_at: confirmedAt,
      fee_seeds: feeSeeds, new_balance_sender: newSenderDisc ? newSenderDisc.balance_seeds : 0,
    });
    this._notifyRecipient(res.op.transfer);
  }

  // Tell the recipient, if they are on THIS node (each node does this when the op applies
  // there, so a recipient on another node hears it from their own node).
  _notifyRecipient(t) {
    if (!t || !this._gateway) return;
    // IMPORTANT: 'amount' (float SOV) is required by Flutter's _handleTransferReceived.
    this._gateway.deliverOrQueue(t.to_id, MSG_TYPE.SOV_TRANSFER_RECEIVED, {
      tx_id: t.tx_id, tx_hash: t.tx_hash, from_id: t.from_id,
      amount: t.amount_seeds / 1_000_000, amount_seeds: t.amount_seeds,
      memo: t.memo || '', confirmed_at: t.confirmed_at,
    });
  }

  // Peer-side check of a transfer op before it is granted a slot or applied: the op must
  // be exactly the citizen's signed transfer (from/to/amount/nonce), and in 'reject' mode
  // the signature must verify under the citizen's enrolled key.
  _validateTransferOp(op) {
    const t = op.transfer, env = op.signed_tx;
    if (!t || !op.owner || op.owner.acct !== t.from_id) return 'MALFORMED_TRANSFER_OP';
    const m = op.moves || [];
    if (m.length !== 2 || m[0].acct !== t.from_id || m[1].acct !== t.to_id ||
        m[1].d !== t.amount_seeds || m[0].d !== -(t.amount_seeds + (t.fee_seeds | 0))) return 'TRANSFER_OP_MOVES_MISMATCH';
    const mode = this._getGovParam ? String(this._getGovParam('tx_signature_enforce', 'reject')) : 'reject';
    let ok = false, reason = 'NO_SIGNED_ENVELOPE';
    if (env && typeof env === 'object') {
      const f = env.from_sovereign_id || env.from_id, to = env.to_sovereign_id || env.to_id;
      const n = env.tx_nonce != null ? env.tx_nonce : env.nonce;
      if (f !== t.from_id || to !== t.to_id || Number(env.amount_seeds) !== Number(t.amount_seeds) || Number(n) !== Number(op.owner.nonce)) {
        reason = 'ENVELOPE_FIELD_MISMATCH';
      } else {
        const enr = this._db.getEnrollment(t.from_id);
        if (!enr || !enr.public_key_hex) reason = 'SENDER_NOT_ENROLLED_LOCALLY';
        else { const v = this._verifyTransferSig(t.from_id, enr.public_key_hex, env); ok = v.valid; reason = v.reason; }
      }
    }
    if (!ok) {
      global.sovLog.warn(`[TX-SIG] peer check tx=${String(t.tx_id).slice(0, 16)} reason=${reason} mode=${mode}`);
      if (mode === 'reject') return 'UNVERIFIED_SIGNATURE:' + reason;
    }
    return null;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // AUTOMATED-WALLET SPEND POLICY — network-enforced caps + allowlist
  // A citizen bounds their own automated wallet; the nodes enforce it so a
  // compromised PC that holds the signing key still cannot exceed the limits.
  // Loosening a limit is delayed (cooldown) + alerted; tightening is instant.
  // ══════════════════════════════════════════════════════════════════════════

  // Read policy, first promoting any pending RELAXATION whose cooldown elapsed
  // (lazy — every node promotes deterministically from identical pending data).
  _resolveAutomationPolicy(sovereignId) {
    const pol = this._db.getAutomationPolicyRaw(sovereignId);
    if (!pol) return null;
    if (pol.pending && pol.pending_at && Date.now() >= pol.pending_at) {
      this._db.writeAutomationPolicy(sovereignId, {
        enabled:    pol.pending.enabled,
        per_tx_cap: pol.pending.per_tx_cap,
        daily_cap:  pol.pending.daily_cap,
        allowlist:  pol.pending.allowlist,
        updated_at: pol.pending_at,
      });
      this._db.clearAutomationPending(sovereignId);
      return this._db.getAutomationPolicyRaw(sovereignId);
    }
    return pol;
  }

  // A change loosens protection (→ delayed) if it disables the policy, raises a
  // cap (cap 0 = unlimited = loosest), or adds/empties the allowlist. Anything
  // that only narrows the limits is tightening (→ applied immediately).
  _isRelaxation(cur, next) {
    if (!cur || !cur.enabled) return false; // first activation is never delayed
    if (!next.enabled) return true;          // turning protection OFF
    const ceil = (x) => (x === 0 ? Infinity : x);
    if (ceil(next.per_tx_cap) > ceil(cur.per_tx_cap)) return true;
    if (ceil(next.daily_cap)  > ceil(cur.daily_cap))  return true;
    const curAl = new Set(cur.allowlist || []);
    for (const d of (next.allowlist || [])) if (!curAl.has(d)) return true; // new destination
    if ((cur.allowlist || []).length > 0 && (next.allowlist || []).length === 0) return true; // []=any
    return false;
  }

  /**
   * Recompute the client's envelope signature over this transfer.
   *
   * Returns { checked, valid, reason }. `checked:false` means there was nothing
   * to verify (no signature on the message, or no public key on the session) —
   * that is reported, never silently treated as success.
   *
   * MODE: governed by `tx_signature_enforce`. 'log' (default) records the
   * outcome and lets the transfer through; 'reject' refuses a bad signature.
   * It ships as 'log' deliberately — the payload hash depends on JSON key order
   * and escaping agreeing between the client and this runtime, and that has to
   * be proven against real traffic before it can be allowed to block payments.
   */
  /**
   * Read a governance parameter.
   *
   * This was REFERENCED by the signature check and never defined, so the mode
   * lookup silently fell back to 'log' and a detected forgery was waved through.
   * A missing method on `this` is undefined, not an error — which is exactly how
   * an enforcement switch ends up permanently off without anyone noticing.
   *
   * Always returns a STRING (§4b): binary gates compare with === '1', and
   * Number('1') === '1' is false.
   */
  _getGovParam(key, fallback) {
    try {
      const row = this._db._db
        .prepare('SELECT param_value FROM sov_governance_params WHERE param_key = ?')
        .get(key);
      return row && row.param_value != null ? String(row.param_value) : String(fallback);
    } catch (_) {
      return String(fallback);
    }
  }

  _verifyTransferSignature(ws, msg) {
    // Session path: verify against the key the citizen presented on this connection.
    return this._verifyTransferSig(ws._sovereignId || msg.from_sovereign_id || '', ws._publicKey, msg);
  }

  // Standalone per-transaction signature check against an EXPLICIT sovereign id + key.
  // C5b fix (2026-08-05): the peer-relay path uses this to verify a relayed transfer
  // against the sender's ENROLLED key before applying any balance change, so a
  // malicious node can no longer forge TX_CONFIRMED_RELAY and have peers apply it.
  _verifyTransferSig(sovereignId, pubKeyHex, msg) {
    const signature = msg.signature;
    const nonce     = msg.nonce;
    const timestamp = msg.timestamp;
    const type      = msg.type || '';

    if (!signature)     return { checked: false, valid: false, reason: 'NO_SIGNATURE_ON_MESSAGE' };
    if (!pubKeyHex)     return { checked: false, valid: false, reason: 'NO_PUBLIC_KEY' };
    if (nonce == null)  return { checked: false, valid: false, reason: 'NO_NONCE' };
    if (!timestamp)     return { checked: false, valid: false, reason: 'NO_TIMESTAMP' };

    try {
      const crypto = require('crypto');
      // The two clients hash different shapes, so each is tried in turn.
      // Everything else — including the 2-char `op` the dictionary layer adds —
      // was already on the message when it was signed.
      const { NodeIdentity } = require('../security/node_identity');
      const pubKey      = Buffer.from(String(pubKeyHex), 'hex');
      const sigBytes    = Buffer.from(String(signature), 'hex');

      // Candidate shapes, in the form each client hashed them.
      const candidates = [];

      // 1. CLI: no `nonce` key existed when the payload was hashed.
      const cli = Object.assign({}, msg);
      delete cli.nonce;
      delete cli.signature;
      candidates.push(['cli', cli]);

      // 2. Phone: `nonce` was present and held the TRANSFER nonce; the signing
      //    counter overwrote it only afterwards.
      if (msg.tx_nonce != null) {
        const phone = Object.assign({}, msg);
        delete phone.signature;
        phone.nonce = msg.tx_nonce;
        candidates.push(['phone', phone]);
      }

      for (const [shape, obj] of candidates) {
        const payloadHash = crypto.createHash('sha256')
          .update(JSON.stringify(obj), 'utf8').digest('hex');
        const signingInput = `${sovereignId}|${nonce}|${timestamp}|${type}|${payloadHash}`;
        let ok = false;
        try {
          ok = NodeIdentity.verify(Buffer.from(signingInput, 'utf8'), sigBytes, pubKey);
        } catch (_) { ok = false; }
        if (ok) return { checked: true, valid: true, reason: 'OK:' + shape };
      }

      return { checked: true, valid: false, reason: 'SIGNATURE_MISMATCH' };

    } catch (err) {
      return { checked: false, valid: false, reason: 'VERIFY_ERROR: ' + (err && err.message) };
    }
  }

  _sanitizePolicyInput(msg) {
    return {
      enabled:    msg.enabled === true || msg.enabled === 1,
      per_tx_cap: Math.max(0, Math.floor(Number(msg.per_tx_cap) || 0)),
      daily_cap:  Math.max(0, Math.floor(Number(msg.daily_cap)  || 0)),
      allowlist:  Array.isArray(msg.allowlist)
        ? [...new Set(msg.allowlist.filter((x) => typeof x === 'string' && x.length > 0))]
        : [],
    };
  }

  handleAutomationPolicySet(ws, msg, gateway) {
    if (ws._legacyMode) {
      gateway.push(ws._sovereignId, MSG_TYPE.AUTOMATION_POLICY_STATE, {
        success: false, error: 'SIGNATURE_REQUIRED',
        message: 'Automated-wallet policy changes require a signed connection.',
      });
      return;
    }
    const id   = ws._sovereignId;
    const next = this._sanitizePolicyInput(msg);
    const cur  = this._resolveAutomationPolicy(id);
    const curNorm = cur || { enabled: false, per_tx_cap: 0, daily_cap: 0, allowlist: [] };

    // Ensure a row exists so a pending relaxation can attach to it.
    if (!cur) this._db.writeAutomationPolicy(id, { ...curNorm, updated_at: Date.now() });

    if (this._isRelaxation(curNorm, next)) {
      const cooldownH = Math.max(0, parseInt(this._db.getGovParam('automation_relax_cooldown_hours', '48')) || 0);
      const at = Date.now() + cooldownH * 3600000;
      this._db.setAutomationPending(id, next, at);
      this._broadcastAutomationPolicy(id);
      gateway.push(id, MSG_TYPE.AUTOMATION_POLICY_STATE, {
        success: true, applied: false, pending: next, pending_at: at,
        cooldown_hours: cooldownH,
        message: 'Loosening an automated-wallet limit is delayed for safety. '
               + 'It takes effect after the cooldown unless you cancel it from any device.',
      });
    } else {
      this._db.writeAutomationPolicy(id, { ...next, updated_at: Date.now() });
      this._db.clearAutomationPending(id); // a tighten also cancels any pending relaxation
      this._broadcastAutomationPolicy(id);
      gateway.push(id, MSG_TYPE.AUTOMATION_POLICY_STATE, {
        success: true, applied: true, policy: this._db.getAutomationPolicyRaw(id),
      });
    }
  }

  handleAutomationPolicyGet(ws, msg, gateway) {
    const id  = ws._sovereignId;
    const pol = this._resolveAutomationPolicy(id);
    gateway.push(id, MSG_TYPE.AUTOMATION_POLICY_STATE, {
      success: true,
      policy: pol || { enabled: false, per_tx_cap: 0, daily_cap: 0, allowlist: [], pending: null, pending_at: null },
      spent_24h_seeds: (pol && pol.enabled) ? this._db.sumAutomationSpend24h(id) : 0,
      cooldown_hours: parseInt(this._db.getGovParam('automation_relax_cooldown_hours', '48')) || 0,
    });
  }

  handleAutomationPolicyCancel(ws, msg, gateway) {
    if (ws._legacyMode) {
      gateway.push(ws._sovereignId, MSG_TYPE.AUTOMATION_POLICY_STATE, {
        success: false, error: 'SIGNATURE_REQUIRED',
      });
      return;
    }
    const id  = ws._sovereignId;
    this._db.clearAutomationPending(id);
    const pol = this._db.getAutomationPolicyRaw(id);
    if (pol) this._db.writeAutomationPolicy(id, { ...pol, updated_at: Date.now() }); // bump so peers drop pending
    this._broadcastAutomationPolicy(id);
    gateway.push(id, MSG_TYPE.AUTOMATION_POLICY_STATE, {
      success: true, applied: true, cancelled: true,
      policy: this._db.getAutomationPolicyRaw(id),
    });
  }

  _broadcastAutomationPolicy(sovereignId) {
    try {
      const pol = this._db.getAutomationPolicyRaw(sovereignId);
      if (!pol) return;
      this._peerMesh.broadcast('AUTOMATION_POLICY_SYNC', {
        sovereign_id: sovereignId,
        enabled: pol.enabled, per_tx_cap: pol.per_tx_cap, daily_cap: pol.daily_cap,
        allowlist: pol.allowlist, pending: pol.pending, pending_at: pol.pending_at,
        updated_at: pol.updated_at,
      });
    } catch (_) {}
  }

  _handleAutomationPolicySync(msg) {
    const id = msg && msg.sovereign_id;
    if (!id) return;
    // Last-writer-wins to avoid a stale broadcast clobbering a newer local change.
    const cur = this._db.getAutomationPolicyRaw(id);
    if (cur && (cur.updated_at || 0) > (msg.updated_at || 0)) return;
    this._db.writeAutomationPolicy(id, {
      enabled: msg.enabled, per_tx_cap: msg.per_tx_cap, daily_cap: msg.daily_cap,
      allowlist: msg.allowlist, updated_at: msg.updated_at || Date.now(),
    });
    if (msg.pending) this._db.setAutomationPending(id, msg.pending, msg.pending_at);
    else this._db.clearAutomationPending(id);
  }
}

module.exports = { TransferEngine };
