// ─────────────────────────────────────────────────────────────────────────────
// TRANSFER ENGINE — SOV coin transfer protocol
// ─────────────────────────────────────────────────────────────────────────────
// Handles all SOV transfers between citizens.
//
// Security model — 3 guards that must ALL pass:
//
//   Guard 1 — Nonce chain (anti-replay)
//     Every transfer has a nonce that must be exactly last_nonce + 1.
//     A captured and replayed transaction has a stale nonce → rejected.
//     The nonce is gossiped to all peer nodes on confirmation.
//
//   Guard 2 — Spend lock (anti double-spend)
//     Before processing, node claims a (sender, nonce) lock and asks peers
//     to deny the same lock. If any peer denies → abort.
//     Deterministic tiebreaker (smaller tx_id wins) prevents deadlock.
//
//   Guard 3 — Optimistic concurrency (race condition)
//     Balance UPDATE uses WHERE version = N. If another transfer updated
//     the balance between our read and write, the version changed → retry.
//     Maximum 3 retries before rejecting.
//
// Peer-enforce confirmation rule:
//   When BOTH sender and recipient are connected to THIS node AND at least one
//   peer node is active, the origin node completes the full confirmation
//   (deduct, credit, record tx) but defers notifying both parties until at
//   least one peer sends TX_CONFIRM_ACK — meaning the tx is safely replicated
//   on another node before citizens are told it succeeded.
//   Fallback: if no ACK arrives within PEER_CONFIRM_TIMEOUT_MS (2s), the
//   origin notifies parties anyway so UX is never permanently blocked.
//   This prevents the "both citizens on one node, node crashes before sync"
//   data-loss scenario.
//
// Transfer flow:
//   1. Validate fields, then verify the citizen's signature over this transfer
//   2. Check Guard 1 (nonce)
//   3. Claim spend lock
//   4. Request Guard 2 quorum from peers
//   5. Deduct sender balance (Guard 3 — version gate)
//   6. Credit recipient balance
//   7. Record transaction + update nonce + release lock
//   8. Broadcast TX_CONFIRMED_RELAY to peers (immediately — start sync)
//   9a. If same-node transfer + active peers: defer notifications, wait for
//       TX_CONFIRM_ACK from any peer (2s fallback)
//   9b. Otherwise: notify sender + recipient immediately
//  10. TX_CONFIRM_ACK received → fire deferred notifications
// ─────────────────────────────────────────────────────────────────────────────

'use strict';

const crypto = require('crypto');
const { MSG_TYPE } = require('../network/citizen_gateway');

// Quorum: wait up to 500ms for peer responses before deciding
const QUORUM_TIMEOUT_MS = 500;

// Maximum optimistic concurrency retries
const MAX_VERSION_RETRIES = 3;

// Peer-enforce: wait up to 2s for a peer TX_CONFIRM_ACK before self-notifying
const PEER_CONFIRM_TIMEOUT_MS = 2000;

class TransferEngine {

  constructor(identity, db, peerMesh, gatewayRef) {
    this._identity  = identity;
    this._db        = db;
    this._peerMesh  = peerMesh;
    this._gateway   = gatewayRef; // set after gateway starts

    // Pending spend lock quorum responses
    this._lockWaiters = new Map(); // tx_id → { resolve, deny, timer }

    // Deferred notification map — same-node transfers waiting for peer ACK
    // tx_hash → { notifySender, notifyRecipient, timer }
    this._pendingNotifications = new Map();

    // Register peer message handlers
    peerMesh.on('SPEND_LOCK_CLAIM',  (msg) => this._handlePeerLockClaim(msg));
    peerMesh.on('SPEND_LOCK_DENY',   (msg) => this._handlePeerLockDeny(msg));
    peerMesh.on('SPEND_LOCK_GRANT',  (msg) => this._handlePeerLockGrant(msg));
    peerMesh.on('TX_CONFIRMED_RELAY',(msg) => this._handleTxConfirmedRelay(msg));
    peerMesh.on('TX_CONFIRM_ACK',    (msg) => this._handleTxConfirmAck(msg));
    peerMesh.on('NONCE_UPDATE',      (msg) => this._handleNonceUpdate(msg));
    peerMesh.on('AUTOMATION_POLICY_SYNC', (msg) => this._handleAutomationPolicySync(msg));
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
      ? String(this._getGovParam('tx_signature_enforce', 'reject'))  // C5 fix 2026-08-05: secure-by-default (prod gov already 'reject'); fresh nodes now enforce too
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

    // ── Guard 1: Nonce chain ──────────────────────────────────────────────────
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

    // ── Guard 2: Spend lock quorum ─────────────────────────────────────────
    const lockAcquired = this._db.acquireSpendLock(from_id, tx_nonce, tx_id);
    if (!lockAcquired) {
      gateway.push(ws._sovereignId, MSG_TYPE.SOV_TRANSFER_RESULT, {
        tx_id, success: false, error: 'SPEND_LOCK_HELD',
      });
      return;
    }

    // Ask peers to grant the lock (or deny if they already have it)
    const quorumGranted = await this._requestSpendLockQuorum(tx_id, from_id, tx_nonce);
    if (!quorumGranted) {
      this._db.releaseSpendLock(from_id, tx_nonce);
      gateway.push(ws._sovereignId, MSG_TYPE.SOV_TRANSFER_RESULT, {
        tx_id, success: false, error: 'SPEND_LOCK_DENIED_BY_PEER',
      });
      return;
    }

    // ── Transfer fee (SOV_OPERATOR_ECONOMY_SPEC — king-approved 2026-07-19) ──
    // fee = min(amount × tx_fee_rate, tx_fee_max_sov). The rate is a % (0.1%
    // default) so small everyday payments cost fractions of a cent — cheaper
    // than Bitcoin at every size; the CAP guarantees no transfer ever costs
    // more than tx_fee_max_sov (1 SOV default) so large settlements stay viable.
    // Both are governance parameters — citizens can vote either (including to 0).
    // Cap 0 = uncapped (pure percentage).
    const feeRate    = parseFloat(this._db.getGovParam('tx_fee_rate', '0.001'));
    let   feeSeeeds  = Math.ceil(amount_seeds * feeRate);
    const feeMaxSov  = parseFloat(this._db.getGovParam('tx_fee_max_sov', '1'));
    const feeCapSeeds = Math.floor(feeMaxSov * 1_000_000);
    if (feeCapSeeds > 0 && feeSeeeds > feeCapSeeds) feeSeeeds = feeCapSeeds;
    const totalCost  = amount_seeds + feeSeeeds;

    if (senderDisc.spendable_seeds < totalCost) {
      this._db.releaseSpendLock(from_id, tx_nonce);
      gateway.push(ws._sovereignId, MSG_TYPE.SOV_TRANSFER_RESULT, {
        tx_id, success: false, error: 'INSUFFICIENT_BALANCE',
        balance_seeds:    senderDisc.spendable_seeds,
        required_seeds:   totalCost,
      });
      return;
    }

    // ── Guard 3: Optimistic concurrency deduction ──────────────────────────
    let deducted = false;
    for (let attempt = 0; attempt < MAX_VERSION_RETRIES; attempt++) {
      const fresh = this._db.readDisc(from_id);
      if (!fresh || fresh.spendable_seeds < totalCost) break;

      deducted = this._db.writeDiscGuarded(
        from_id,
        fresh.balance_seeds - totalCost,
        fresh.spendable_seeds - totalCost,
        fresh.version
      );
      if (deducted) break;
      // Version changed — another tx updated balance concurrently; retry
    }

    if (!deducted) {
      this._db.releaseSpendLock(from_id, tx_nonce);
      gateway.push(ws._sovereignId, MSG_TYPE.SOV_TRANSFER_RESULT, {
        tx_id, success: false, error: 'CONCURRENT_MODIFICATION',
      });
      return;
    }

    // ── Credit recipient ──────────────────────────────────────────────────
    this._db.ensureDiscEntry(to_id);
    let credited = false;
    for (let attempt = 0; attempt < MAX_VERSION_RETRIES; attempt++) {
      const recipDisc = this._db.readDisc(to_id);
      credited = this._db.writeDiscGuarded(
        to_id,
        recipDisc.balance_seeds + amount_seeds,
        recipDisc.spendable_seeds + amount_seeds,
        recipDisc.version
      );
      if (credited) break;
    }

    // ── Route transaction fee → witness_operator pool (Blueprint v14.0) ───
    // Fee was deducted from sender (above). Now credit it into the operator
    // pool so the pool grows with network activity instead of just sitting
    // at the 10M genesis allocation. This is how operators sustain themselves
    // beyond the initial pool: every transfer contributes to ongoing income.
    //
    // The pool itself does NOT distribute to operators automatically yet —
    // that mechanism is a v1.3 governance proposal (per-tx + uptime split).
    // For now, the pool simply accumulates fees + initial allocation as a
    // reserve waiting to be governance-distributed.
    //
    if (feeSeeeds > 0 && credited) {
      // Fail CLOSED: a fee that cannot reach the pool is recorded as owed, never
      // burned. The old catch swallowed the error and the seeds disappeared,
      // which made "collected fees == pool credits" impossible to audit.
      if (this._db.addToPoolOrRecord) {
        this._db.addToPoolOrRecord('witness_operator', feeSeeeds,
          { source: 'transfer', ref: tx_id || null });
      } else if (this._db.addToPool) {
        this._db.addToPool('witness_operator', feeSeeeds);
      }
    }

    if (!credited) {
      // This should be rare — rollback the deduction
      const fresh = this._db.readDisc(from_id);
      for (let attempt = 0; attempt < MAX_VERSION_RETRIES; attempt++) {
        const ok = this._db.writeDiscGuarded(
          from_id,
          fresh.balance_seeds + totalCost,
          fresh.spendable_seeds + totalCost,
          fresh.version
        );
        if (ok) break;
      }
      this._db.releaseSpendLock(from_id, tx_nonce);
      gateway.push(ws._sovereignId, MSG_TYPE.SOV_TRANSFER_RESULT, {
        tx_id, success: false, error: 'CREDIT_FAILED',
      });
      return;
    }

    // ── Compute transaction hash ───────────────────────────────────────────
    const txHash = crypto.createHash('sha256')
      .update(`${tx_id}:${from_id}:${to_id}:${amount_seeds}:${tx_nonce}:${timestamp}`)
      .digest('hex');
    const confirmedAt = Date.now();

    // ── Record confirmed transaction ───────────────────────────────────────
    this._db.insertTransaction({
      tx_id, tx_hash: txHash, from_id, to_id, amount_seeds,
      memo: memo || '', status: 'confirmed', confirmed_at: confirmedAt,
      created_at: timestamp || confirmedAt,
    });

    // Record automated-wallet spend for the rolling 24h daily-cap window.
    if (autoPol && autoPol.enabled) {
      try { this._db.recordAutomationSpend(from_id, amount_seeds); } catch (_) {}
    }

    // Update sender nonce
    this._db._db.prepare(
      'UPDATE sov_disc SET nonce = ? WHERE sovereign_id = ?'
    ).run(tx_nonce, from_id);

    // Release spend lock
    this._db.releaseSpendLock(from_id, tx_nonce);

    // ── Notify parties ─────────────────────────────────────────────────────

    // Read sender's new balance to return it in the response
    const newSenderDisc = this._db.readDisc(from_id);
    const newBalanceSender = newSenderDisc ? newSenderDisc.balance_seeds : 0;

    // Build notification closures so we can fire them now or defer them
    const notifySender = () => {
      gateway.push(from_id, MSG_TYPE.SOV_TRANSFER_RESULT, {
        tx_id,
        tx_hash:            txHash,
        success:            true,
        confirmed_at:       confirmedAt,
        fee_seeds:          feeSeeeds,
        new_balance_sender: newBalanceSender,
      });
    };

    // IMPORTANT: 'amount' (float SOV) is required by Flutter's _handleTransferReceived.
    // Flutter reads msg['amount'], converts to seeds, and guards against amountSeeds <= 0.
    // Without the 'amount' field the guard exits silently and the recipient sees nothing.
    const notifyRecipient = () => {
      const recipientNotified = gateway.push(to_id, MSG_TYPE.SOV_TRANSFER_RECEIVED, {
        tx_id,
        tx_hash:       txHash,
        from_id,
        amount:        amount_seeds / 1_000_000,   // float SOV — Flutter primary field
        amount_seeds,                               // seeds — for precision / backward compat
        memo:          memo || '',
        confirmed_at:  confirmedAt,
      });

      // If recipient is on a different node, forward via peer mesh
      if (!recipientNotified) {
        const presence = this._db.getCitizenPresence(to_id);
        if (presence && presence.node_id !== this._identity.nodeId) {
          this._peerMesh.sendTo(presence.node_id, 'CITIZEN_MESSAGE_FORWARD', {
            to: to_id,
            type: MSG_TYPE.SOV_TRANSFER_RECEIVED,
            payload: {
              tx_id, tx_hash: txHash, from_id,
              amount:      amount_seeds / 1_000_000,
              amount_seeds,
              memo: memo || '', confirmed_at: confirmedAt,
            },
          });
        } else {
          // Recipient offline — queue
          this._db.queuePendingMessage(to_id, MSG_TYPE.SOV_TRANSFER_RECEIVED, {
            tx_id, tx_hash: txHash, from_id,
            amount:      amount_seeds / 1_000_000,
            amount_seeds,
            memo: memo || '', confirmed_at: confirmedAt,
          });
        }
      }
    };

    // ── Mark payment request paid (if this transfer fulfilled one) ────────
    if (payment_request_id && this._financialEngine) {
      this._financialEngine.markPaymentRequestPaid(payment_request_id, from_id);
    }

    // ── Broadcast confirmed tx to peers FIRST (start replication immediately) ─
    // C5b fix: carry the citizen's original SIGNED transfer envelope so every peer
    // can independently verify the signature against the sender's enrolled key
    // before applying balance changes (see _handleTxConfirmedRelay).
    this._peerMesh.broadcast('TX_CONFIRMED_RELAY', {
      tx_id, tx_hash: txHash, from_id, to_id, amount_seeds, fee_seeds: feeSeeeds,
      memo: memo || '', confirmed_at: confirmedAt, nonce: tx_nonce,
      signed_tx: msg,
    });

    // Broadcast nonce update so peers reject replays
    this._peerMesh.broadcast('NONCE_UPDATE', {
      sovereign_id: from_id, nonce: tx_nonce, tx_id,
    });

    // ── Peer-enforce confirmation rule ─────────────────────────────────────
    // When BOTH citizens are connected to THIS node AND peers exist, defer
    // notifying parties until at least one peer ACKs the sync. This ensures
    // the tx is on at least 2 nodes before citizens are told it succeeded.
    // Fallback timer fires after PEER_CONFIRM_TIMEOUT_MS regardless.
    //
    // When either citizen is NOT on this node (or no peers), notify immediately
    // — they won't get the notification any other way.
    const bothLocal   = gateway.isConnected(from_id) && gateway.isConnected(to_id);
    const hasPeers    = this._peerMesh.activePeers().length > 0;
    const peerEnforce = bothLocal && hasPeers;

    if (peerEnforce) {
      // Defer — wait for a peer TX_CONFIRM_ACK (or 2s fallback)
      global.sovLog && global.sovLog.debug(
        `[TRANSFER] peer-enforce active for ${txHash.slice(0,12)} — awaiting peer ACK`
      );
      const timer = setTimeout(() => {
        if (this._pendingNotifications.has(txHash)) {
          this._pendingNotifications.delete(txHash);
          global.sovLog && global.sovLog.debug(
            `[TRANSFER] peer-enforce fallback fired for ${txHash.slice(0,12)} — notifying parties`
          );
          notifySender();
          notifyRecipient();
        }
      }, PEER_CONFIRM_TIMEOUT_MS);

      this._pendingNotifications.set(txHash, { notifySender, notifyRecipient, timer });
    } else {
      // Notify immediately — cross-node transfer or isolated node
      notifySender();
      notifyRecipient();
    }
  }

  // ── Spend lock quorum ─────────────────────────────────────────────────────

  _requestSpendLockQuorum(txId, fromId, nonce) {
    return new Promise((resolve) => {
      const peers     = this._peerMesh.activePeers();
      if (peers.length === 0) {
        // No peers — we are the sole authority
        resolve(true);
        return;
      }

      let granted  = 0;
      let denied   = 0;
      let responded = 0;

      const waiter = {
        resolve: () => resolve(true),
        deny:    () => resolve(false),
        timer:   setTimeout(() => {
          // Timeout — majority not heard from. Accept if no denials.
          this._lockWaiters.delete(txId);
          resolve(denied === 0);
        }, QUORUM_TIMEOUT_MS),
      };
      this._lockWaiters.set(txId, { waiter, denied: () => denied++, granted: () => granted++ });

      this._peerMesh.broadcast('SPEND_LOCK_CLAIM', {
        tx_id: txId,
        from_id: fromId,
        nonce,
        node_id: this._identity.nodeId,
      });
    });
  }

  _handlePeerLockClaim(msg) {
    const { tx_id, from_id, nonce, node_id } = msg;
    // Try to acquire the same lock locally
    const acquired = this._db.acquireSpendLock(from_id, nonce, tx_id);

    if (acquired) {
      this._peerMesh.sendTo(node_id, 'SPEND_LOCK_GRANT', {
        tx_id, granted_by: this._identity.nodeId,
      });
    } else {
      // Tiebreaker — smaller tx_id wins
      const existingLock = this._db._db.prepare(
        'SELECT tx_id FROM sov_spend_locks WHERE lock_key = ?'
      ).get(`${from_id}:${nonce}`);

      if (existingLock && existingLock.tx_id < tx_id) {
        // Our tx takes priority
        this._peerMesh.sendTo(node_id, 'SPEND_LOCK_DENY', {
          tx_id, denied_by: this._identity.nodeId,
        });
      } else {
        // Their tx takes priority — release ours, grant theirs
        this._db.releaseSpendLock(from_id, nonce);
        this._db.acquireSpendLock(from_id, nonce, tx_id);
        this._peerMesh.sendTo(node_id, 'SPEND_LOCK_GRANT', {
          tx_id, granted_by: this._identity.nodeId,
        });
      }
    }
  }

  _handlePeerLockGrant(msg) {
    const waiterEntry = this._lockWaiters.get(msg.tx_id);
    if (waiterEntry) waiterEntry.granted();
  }

  _handlePeerLockDeny(msg) {
    const waiterEntry = this._lockWaiters.get(msg.tx_id);
    if (waiterEntry) {
      waiterEntry.denied();
      // Immediately resolve false on any denial
      this._lockWaiters.delete(msg.tx_id);
      clearTimeout(waiterEntry.waiter.timer);
      waiterEntry.waiter.deny();
    }
  }

  // ── Cross-node sync ────────────────────────────────────────────────────────

  _handleTxConfirmedRelay(msg) {
    // Peer confirmed a transaction — sync our ledger and notify recipient if connected here.
    //
    // This runs on every peer node that was NOT the confirming node.
    // It must:
    //   1. Apply the balance changes to the local disc copy (all nodes hold ALL balances)
    //   2. Queue SOV_TRANSFER_RECEIVED for the recipient if they're offline here
    //   3. Deliver SOV_TRANSFER_RECEIVED immediately if the recipient is already connected
    //   4. Send TX_CONFIRM_ACK back to origin so it can fire deferred notifications
    //
    const { tx_id, tx_hash, from_id, to_id, amount_seeds, fee_seeds, confirmed_at, nonce } = msg;
    const memo = msg.memo || '';

    // Idempotency check — if we already have this tx, skip balance update
    // (avoids double-crediting when originating node broadcasts back to itself)
    if (this._db.hasTransaction(tx_hash)) {
      this._handleNonceUpdate({ sovereign_id: from_id, nonce });
      // Still ACK — the origin may be waiting for deferred notifications
      this._peerMesh.broadcast('TX_CONFIRM_ACK', { tx_hash });
      return;
    }

    // ── C5b FIX (2026-08-05): verify the citizen's signature on the relayed
    // transfer against their ENROLLED key BEFORE applying any balance change.
    // Without this, any mesh node could broadcast a forged TX_CONFIRMED_RELAY and
    // every peer would debit/credit blindly. The signed envelope must also describe
    // THIS transfer (from/to/amount/nonce) so a valid signature can't be replayed
    // over different fields. In 'reject' mode an unverified relay is refused.
    const _sigMode = this._getGovParam
      ? String(this._getGovParam('tx_signature_enforce', 'reject')) : 'reject';
    const _env = msg.signed_tx;
    let _sigOk = false, _sigReason = 'NO_SIGNED_ENVELOPE';
    if (_env && typeof _env === 'object') {
      const _envFrom  = _env.from_sovereign_id || _env.from_id;
      const _envTo    = _env.to_sovereign_id   || _env.to_id;
      const _envNonce = (_env.tx_nonce != null) ? _env.tx_nonce : _env.nonce;
      const _match = _envFrom === from_id && _envTo === to_id &&
        Number(_env.amount_seeds) === Number(amount_seeds) && Number(_envNonce) === Number(nonce);
      if (!_match) {
        _sigReason = 'ENVELOPE_FIELD_MISMATCH';
      } else {
        const _enr = this._db.getEnrollment(from_id);
        if (!_enr || !_enr.public_key_hex) {
          _sigReason = 'SENDER_NOT_ENROLLED_LOCALLY';
        } else {
          const _v = this._verifyTransferSig(from_id, _enr.public_key_hex, _env);
          _sigOk = _v.valid; _sigReason = _v.reason;
        }
      }
    }
    if (!_sigOk) {
      global.sovLog.warn(
        `[TX-RELAY] unverified relay tx=${String(tx_id).slice(0, 16)} from=${String(from_id).slice(0, 16)} ` +
        `reason=${_sigReason} mode=${_sigMode}`);
      if (_sigMode === 'reject') {
        // Refuse to apply an unverified balance change from a peer. The correct
        // ledger reaches us either from a fixed origin (with signed_tx) or via the
        // normal convergence path — never from an unproven peer assertion.
        return;
      }
    }

    // Insert transaction record
    try {
      this._db.insertTransaction({
        tx_id, tx_hash, from_id, to_id, amount_seeds,
        memo, status: 'confirmed', confirmed_at,
        created_at: confirmed_at,
      });
    } catch (_) {}

    // ── Apply balance changes to our local disc copy ──────────────────────
    // Deduct from sender
    for (let attempt = 0; attempt < MAX_VERSION_RETRIES; attempt++) {
      const fresh = this._db.readDisc(from_id);
      if (!fresh || fresh.balance_seeds < (amount_seeds + (fee_seeds || 0))) break;
      const ok = this._db.writeDiscGuarded(
        from_id,
        fresh.balance_seeds - (amount_seeds + (fee_seeds || 0)),
        Math.max(0, fresh.spendable_seeds - (amount_seeds + (fee_seeds || 0))),
        fresh.version
      );
      if (ok) break;
    }

    // Credit recipient
    this._db.ensureDiscEntry(to_id);
    for (let attempt = 0; attempt < MAX_VERSION_RETRIES; attempt++) {
      const recipDisc = this._db.readDisc(to_id);
      if (!recipDisc) break;
      const ok = this._db.writeDiscGuarded(
        to_id,
        recipDisc.balance_seeds + amount_seeds,
        recipDisc.spendable_seeds + amount_seeds,
        recipDisc.version
      );
      if (ok) break;
    }

    // H2 FIX (2026-08-05): DO NOT re-credit the fee to the pool here. The
    // originating node already ran addToPool('witness_operator', fee) once
    // (handleTransfer), which broadcasts a POOL_DELTA that every peer applies — so
    // the fee is already replicated to this node's pool. The old line below added it
    // a SECOND time on every peer, inflating the operator reserve by ~N× the real
    // fees (measured 0.4 SOV pool growth for a 0.1 SOV fee on 3 nodes) → operator
    // over-payout. Mirrors the PI-13 enrollment-reward de-duplication.
    // (removed) if (fee_seeds > 0 && this._db.addToPool) this._db.addToPool('witness_operator', fee_seeds);

    // ── Notify recipient on this node ─────────────────────────────────────
    const transferPayload = {
      tx_id, tx_hash, from_id,
      amount:      amount_seeds / 1_000_000,   // float SOV — Flutter primary field
      amount_seeds,
      memo, confirmed_at,
    };
    if (this._gateway) {
      // deliverOrQueue: sends immediately if connected, queues for reconnect if offline
      this._gateway.deliverOrQueue(to_id, MSG_TYPE.SOV_TRANSFER_RECEIVED, transferPayload);
    }

    // Update nonce
    this._handleNonceUpdate({ sovereign_id: from_id, nonce });

    // ── ACK back to origin node so it can fire deferred notifications ─────
    // This is the signal the peer-enforce rule waits for: the tx is safely
    // replicated on this node — the origin can now tell both parties.
    this._peerMesh.broadcast('TX_CONFIRM_ACK', { tx_hash });
  }

  // ── Peer-enforce: handle ACK from a peer ──────────────────────────────────

  _handleTxConfirmAck(msg) {
    const { tx_hash } = msg;
    const pending = this._pendingNotifications.get(tx_hash);
    if (!pending) return; // Already fired (fallback timer beat us) or not a deferred tx

    // Cancel the fallback timer and fire notifications now
    clearTimeout(pending.timer);
    this._pendingNotifications.delete(tx_hash);

    global.sovLog && global.sovLog.debug(
      `[TRANSFER] peer ACK received for ${tx_hash.slice(0,12)} — notifying parties`
    );

    pending.notifySender();
    pending.notifyRecipient();
  }

  _handleNonceUpdate(msg) {
    const { sovereign_id, nonce } = msg;
    const disc = this._db.readDisc(sovereign_id);
    if (disc && nonce > disc.nonce) {
      this._db._db.prepare(
        'UPDATE sov_disc SET nonce = ? WHERE sovereign_id = ? AND nonce < ?'
      ).run(nonce, sovereign_id, nonce);
    }
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
