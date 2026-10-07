// ─────────────────────────────────────────────────────────────────────────────
// LEDGER — every balance change as a replicated op (node 1.4.90)
// ─────────────────────────────────────────────────────────────────────────────
// docs/ledger/LEDGER_SAFETY_1.4.90_PLAN.md. Storage + atomic apply live in
// storage/db.js (ledgerApply). This module is the network side:
//
//   commitOwnerOp(op)   a citizen spends THEIR OWN funds (transfer, exchange listing,
//                       vault lock, bond, platform fee). The (account, nonce) slot is
//                       granted by a MAJORITY of the node set before anything moves.
//                       Every node grants at most one op per slot, so two spends of the
//                       same money can never both commit — whichever node each one hit.
//   commitSystemOp(op)  a move decided by the single node that owns the object
//                       (escrow release, verdict, pool grant). No slot; atomic and
//                       exactly-once everywhere, like every op.
//
// Every committed op is broadcast (LEDGER_OP) and kept for ever. A node that missed one
// gets it from the per-origin digest/pull (same pattern as storage/pool_delta_sync.js),
// on peer admission and every DIGEST_INTERVAL_MS. Ops that cannot apply yet (a missing
// earlier op, or a credit still on its way) are HELD and retried — never half-applied.
//
// SILENCE IS A NO. A slot needs positive grants from a majority; a node that once had
// peers and now sees none refuses to commit owner ops (a home node back after weeks
// offline). A network that has never had a second node may commit alone (genesis, tests).
// ─────────────────────────────────────────────────────────────────────────────

'use strict';

const crypto = require('crypto');

const VOTE_TIMEOUT_MS    = 3000;
const DIGEST_INTERVAL_MS = 60 * 1000;
const ABORT_RESEND_MS    = 24 * 3600 * 1000;

class Ledger {
  constructor(db, identity, peerMesh) {
    this._db = db;
    this._identity = identity;
    this._mesh = peerMesh;
    this._waiters = new Map();          // op_id -> { onReply }
    this._validators = new Map();       // kind -> fn(op) -> null | reason   (peer-side checks)
    this._appliedCbs = [];              // fn(op, localOrigin)
    this._timer = null;
  }

  get nodeId() { return this._identity.nodeId; }

  /** A peer-side check for one kind of op (e.g. the citizen's signature on a transfer). */
  setValidator(kind, fn) { this._validators.set(kind, fn); }

  /** Called after any op is applied on this node (origin or replica). */
  onApplied(fn) { this._appliedCbs.push(fn); }

  start() {
    const m = this._mesh;
    m.on('LEDGER_VOTE_REQUEST', (msg) => this._onVoteRequest(msg));
    m.on('LEDGER_VOTE_REPLY',   (msg) => this._onVoteReply(msg));
    m.on('LEDGER_VOTE_RELEASE', (msg) => this._onVoteRelease(msg));
    m.on('LEDGER_OP',           (msg) => this._onOp(msg));
    m.on('LEDGER_DIGEST',       (msg) => this._onDigest(msg));
    m.on('LEDGER_PULL',         (msg) => this._onPull(msg));
    if (m.onPeerAdmitted) m.onPeerAdmitted((nodeId) => this._sendDigest(nodeId));

    // Baseline (once, at this node's first 1.4.90 start): every pre-existing balance becomes an op
    // that later joiners can pull. Nothing here changes; see db.ledgerRecordBaseline.
    try {
      const n = this._db.ledgerRecordBaseline(this.nodeId);
      if (n > 0) global.sovLog.info(`[LEDGER] baseline recorded for ${n} account(s)`);
    } catch (e) { global.sovLog.error(`[LEDGER] baseline failed: ${e.message}`); }

    // Boot recovery: grants this node gave ITSELF for ops it never committed (it crashed
    // mid-op) are aborted, and the abort is announced so peers release their grants to us.
    for (const v of this._db.ledgerOwnUncommittedVotes(this.nodeId)) {
      this._db.ledgerAbort(v.from_id, v.nonce, v.op_id, this.nodeId);
      global.sovLog.warn(`[LEDGER] boot: aborted uncommitted op ${v.op_id} (${v.from_id.slice(0, 12)}#${v.nonce})`);
    }
    // Pre-1.4.90 vaults and dispute bonds hold money that sits in no account (the owner was
    // debited, nothing was credited). Give each its holding once, after the engines have made
    // their tables. (Exchange escrow is adopted by the exchange engine itself.)
    setTimeout(() => this._adoptLegacyHoldings(), 12 * 1000).unref?.();
    this._timer = setInterval(() => this._tick(), DIGEST_INTERVAL_MS);
    if (this._timer.unref) this._timer.unref();
    setTimeout(() => this._tick(), 15 * 1000).unref?.();
  }

  stop() { if (this._timer) clearInterval(this._timer); }

  // ── Commit ────────────────────────────────────────────────────────────────

  /**
   * @param op { kind, owner: { acct, nonce? }, moves, holds?, pools?, op_id?, ref?, tx_record?, meta? }
   * @returns { ok, op } | { ok:false, error, expected_nonce? }
   */
  async commitOwnerOp(op) {
    const acct = op.owner.acct;
    const disc = this._db.readDisc(acct);
    if (!disc) return { ok: false, error: 'UNKNOWN_ACCOUNT' };
    const nonce = op.owner.nonce != null ? op.owner.nonce : disc.nonce + 1;
    if (nonce !== disc.nonce + 1) {
      return { ok: false, error: nonce <= disc.nonce ? 'NONCE_ALREADY_USED' : 'NONCE_FUTURE', expected_nonce: disc.nonce + 1 };
    }
    op.owner = { acct, nonce };
    op.op_id = op.op_id || `op-${this.nodeId.slice(0, 8)}-${crypto.randomBytes(8).toString('hex')}`;
    if (this._db.ledgerIsAborted(op.op_id)) return { ok: false, error: 'OP_ABORTED', expected_nonce: nonce };

    const q = await this._gatherMajority(op);
    if (!q.ok) {
      this._abort(op);
      return { ok: false, error: q.error, expected_nonce: q.expected_nonce };
    }
    return this._commitLocal(op, true);
  }

  /** A move decided by this node alone (it owns the object). */
  commitSystemOp(op) {
    op.op_id = op.op_id || `sys-${this.nodeId.slice(0, 8)}-${crypto.randomBytes(8).toString('hex')}`;
    return this._commitLocal(op, false);
  }

  _commitLocal(op, isOwnerOp) {
    op.origin_node = this.nodeId;
    op.seq = this._db.ledgerNextSeq(this.nodeId);
    op.committed_at = Date.now();
    const r = this._db.ledgerApply(op, true);
    if (r !== 'applied') {
      if (isOwnerOp) this._abort(op);
      global.sovLog.warn(`[LEDGER] commit ${op.op_id} (${op.kind}) refused locally: ${r}`);
      return { ok: false, error: 'LEDGER_' + r.toUpperCase() };
    }
    this._mesh.broadcast('LEDGER_OP', { op });
    this._fireApplied(op, true);
    return { ok: true, op };
  }

  _abort(op) {
    if (!op.owner) return;
    if (this._db.ledgerAbort(op.owner.acct, op.owner.nonce, op.op_id, this.nodeId)) {
      this._mesh.broadcast('LEDGER_VOTE_RELEASE',
        { from_id: op.owner.acct, nonce: op.owner.nonce, op_id: op.op_id, origin_node: this.nodeId });
    }
  }

  _adoptLegacyHoldings() {
    const q = (sql) => { try { return this._db._db.prepare(sql).all(); } catch (_) { return []; } };
    const items = [
      ...q("SELECT vault_id AS id, amount_seeds AS amt FROM sov_vaults WHERE status = 'locked'").map(r => ({ h: 'vault:' + r.id, amt: r.amt })),
      ...q("SELECT case_id AS id, bond_held AS amt FROM sov_disputes WHERE bond_held > 0 AND (verdict IS NULL OR verdict = '')").map(r => ({ h: 'bond:' + r.id, amt: r.amt })),
    ];
    for (const it of items) {
      if (!(it.amt > 0) || this._db.holdingBalance(it.h) > 0) continue;
      const r = this.commitSystemOp({ op_id: `adopt:${it.h}`, kind: 'holding_adopt', ref: it.h, holds: [{ id: it.h, d: it.amt }] });
      global.sovLog.warn(`[LEDGER] adopted pre-1.4.90 holding ${it.h} (${it.amt} seeds): ${r.ok ? 'ok' : r.error}`);
    }
  }

  // ── Majority ──────────────────────────────────────────────────────────────

  _gatherMajority(op) {
    const { acct, nonce } = op.owner;
    const self = this._db.ledgerVote(acct, nonce, op.op_id, this.nodeId);
    if (!self.granted) return Promise.resolve({ ok: false, error: self.reason, expected_nonce: (self.committed_nonce | 0) + 1 });

    const N = this._mesh.validatorSetSize ? this._mesh.validatorSetSize() : 1 + this._mesh.activePeers().length;
    const need = Math.floor(N / 2) + 1;
    const live = this._mesh.activePeers().length;
    if (need <= 1) {
      if (this._mesh.everHadVerifiedPeer && this._mesh.everHadVerifiedPeer()) {
        return Promise.resolve({ ok: false, error: 'QUORUM_UNAVAILABLE' });
      }
      return Promise.resolve({ ok: true, grants: [this.nodeId] });     // never had a second node
    }
    if (1 + live < need) return Promise.resolve({ ok: false, error: 'QUORUM_UNAVAILABLE' });

    return new Promise((resolve) => {
      const grants = new Set([this.nodeId]);
      const denies = [];
      let done = false;
      const finish = (res) => {
        if (done) return; done = true;
        clearTimeout(timer); this._waiters.delete(op.op_id);
        resolve(res);
      };
      const timer = setTimeout(() => finish(grants.size >= need ? { ok: true, grants: [...grants] }
        : { ok: false, error: denies.length ? 'QUORUM_DENIED:' + denies.join(',') : 'QUORUM_UNAVAILABLE' }), VOTE_TIMEOUT_MS);
      this._waiters.set(op.op_id, {
        onReply: (msg) => {
          if (msg.granted) grants.add(msg.voter);
          else denies.push(msg.reason || 'DENIED');
          if (grants.size >= need) return finish({ ok: true, grants: [...grants] });
          if (grants.size + Math.max(0, N - 1 - (grants.size - 1) - denies.length) < need) {
            finish({ ok: false, error: 'QUORUM_DENIED:' + denies.join(',') });
          }
        },
      });
      this._mesh.broadcast('LEDGER_VOTE_REQUEST', {
        from_id: acct, nonce, op_id: op.op_id, origin_node: this.nodeId, op,
      });
    });
  }

  _onVoteRequest(msg) {
    const { from_id, nonce, op_id, origin_node, op } = msg || {};
    if (!from_id || !op_id || !origin_node || origin_node === this.nodeId) return;
    let r;
    const v = op && this._validators.get(op.kind);
    const why = v ? v(op) : null;
    if (why) r = { granted: false, reason: why };
    else r = this._db.ledgerVote(from_id, nonce, op_id, origin_node);
    this._mesh.sendTo(origin_node, 'LEDGER_VOTE_REPLY', {
      op_id, voter: this.nodeId, granted: !!r.granted, reason: r.reason || null, committed_nonce: r.committed_nonce,
    });
    if (!r.granted && r.reason === 'NONCE_BEHIND') this._sendDigest(origin_node);   // we are behind: catch up
  }

  _onVoteReply(msg) {
    const w = msg && this._waiters.get(msg.op_id);
    if (w) w.onReply(msg);
  }

  _onVoteRelease(msg) {
    if (!msg || !msg.op_id) return;
    this._db.ledgerRelease(msg.from_id, msg.nonce, msg.op_id, msg.origin_node);
  }

  // ── Replication ───────────────────────────────────────────────────────────

  _onOp(msg) {
    const op = msg && msg.op;
    if (!op || !op.op_id || !op.origin_node) return;
    if (op.origin_node === this.nodeId) return;
    this._applyRemote(op);
    this._retryHeld();
  }

  _applyRemote(op) {
    const v = this._validators.get(op.kind);
    const why = v ? v(op) : null;
    if (why) {
      global.sovLog.error(`[LEDGER] refused op ${op.op_id} (${op.kind}) from ${String(op.origin_node).slice(0, 12)}: ${why}`);
      return 'refused';
    }
    const r = this._db.ledgerApply(op, false);
    if (r === 'applied') { this._fireApplied(op, false); return r; }
    if (r === 'duplicate' || r === 'stale') return r;
    if (r === 'conflict') {
      global.sovLog.error(`[LEDGER] CONFLICT: op ${op.op_id} for a slot already committed to another op — not applied`);
      return r;
    }
    this._db.ledgerHold(op, r);                // gap | insufficient | unknown_account | error
    if (r === 'gap' || r === 'unknown_account') this._sendDigest(op.origin_node);
    return r;
  }

  _retryHeld() {
    for (let pass = 0; pass < 20; pass++) {
      let progressed = false;
      for (const op of this._db.ledgerHeld()) {
        const r = this._db.ledgerApply(op, false);
        if (r === 'applied') { this._fireApplied(op, false); progressed = true; }
        else if (r === 'duplicate' || r === 'stale' || r === 'conflict') {
          this._db._db.prepare('DELETE FROM sov_ledger_hold WHERE op_id = ?').run(op.op_id);
          if (r === 'conflict') global.sovLog.error(`[LEDGER] CONFLICT on held op ${op.op_id} — dropped`);
        }
      }
      if (!progressed) break;
    }
  }

  _fireApplied(op, local) {
    for (const cb of this._appliedCbs) { try { cb(op, local); } catch (e) { global.sovLog.warn(`[LEDGER] applied-hook: ${e.message}`); } }
  }

  _tick() {
    this._sendDigest(null);
    this._retryHeld();
    // Re-announce recent aborts (a release lost in a partition must still reach every node).
    for (const a of this._db.ledgerRecentAborts(this.nodeId, Date.now() - ABORT_RESEND_MS)) {
      this._mesh.broadcast('LEDGER_VOTE_RELEASE', { from_id: a.from_id, nonce: a.nonce, op_id: a.op_id, origin_node: this.nodeId });
    }
  }

  _sendDigest(nodeId) {
    const payload = { from_node: this.nodeId, digest: this._db.ledgerDigest() };
    if (nodeId) this._mesh.sendTo(nodeId, 'LEDGER_DIGEST', payload);
    else this._mesh.broadcast('LEDGER_DIGEST', payload);
  }

  _onDigest(msg) {
    if (!msg || !msg.from_node || msg.from_node === this.nodeId) return;
    const theirs = msg.digest || {}, ours = this._db.ledgerDigest();
    const want = {};
    for (const [origin, max] of Object.entries(theirs)) if ((ours[origin] || 0) < max) want[origin] = ours[origin] || 0;
    if (Object.keys(want).length) this._mesh.sendTo(msg.from_node, 'LEDGER_PULL', { from_node: this.nodeId, after: want });
    for (const [origin, max] of Object.entries(ours)) if ((theirs[origin] || 0) < max) this._replay(msg.from_node, origin, theirs[origin] || 0);
  }

  _onPull(msg) {
    if (!msg || !msg.from_node || !msg.after) return;
    for (const [origin, after] of Object.entries(msg.after)) this._replay(msg.from_node, origin, after | 0);
  }

  _replay(nodeId, origin, after) {
    for (const op of this._db.ledgerOpsAfter(origin, after)) this._mesh.sendTo(nodeId, 'LEDGER_OP', { op });
  }
}

module.exports = { Ledger };
