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
const cert   = require('./ledger_cert');
const { isFrozenHistory } = require('./ledger_frozen');
const ownerAuth = require('./owner_auth');

// 1.4.95: an owner op of a citizen-requested kind committed from this moment on must carry the citizen's
// signed request when a node APPLIES it. Earlier ops were granted under the old rule and stay valid by
// their majority certificate (every grant given after the upgrade already required the request).
const AUTH_REQUIRED_FROM = Date.parse('2026-10-10T06:00:00Z');

// Kinds that were allowed to break the zero-sum rule for the 1.4.90 upgrade. From 1.4.94 a peer's op
// of these kinds is accepted ONLY if it is part of the frozen pre-1.4.94 history (D60): otherwise a
// dishonest node could create SOV on every other node by announcing a made-up "baseline".
const LEGACY_KINDS = new Set(['baseline', 'escrow_adopt', 'holding_adopt']);

// D57: every op kind the node knows. A peer's op of any OTHER kind is refused outright — a future or
// rogue kind cannot slip money through on an old node that does not understand it. Owner ops are further
// checked by their certificate (D61/D62); the system-op kinds here still apply on the origin's say-so
// until per-kind re-derivation lands (SOV_LEDGER_V2_DESIGN §5.2), which matters once a second operator runs.
const KNOWN_KINDS = new Set([
  'transfer', 'baseline', 'escrow_adopt', 'holding_adopt',
  'escrow_list', 'escrow_confirm', 'escrow_refund', 'escrow_cancel', 'escrow_expire', 'escrow_list_undo',
  'vault_lock', 'vault_claim', 'vault_steward', 'dispute_bond', 'verdict', 'platform_fee',
  'enroll_grant', 'operator_payout', 'alloc_lock', 'alloc_cancel', 'alloc_claim', 'alloc_council',
  'academy_article_bond', 'academy_upvote_bond',
]);

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

  // ── 1.4.95: the citizen's own signed request (owner_auth.js) ─────────────────
  /** 'reject' refuses an op whose request does not check out; anything else only logs. Same switch as
   *  transfer signatures — one rule for every way a citizen's own money moves. */
  _authMode() {
    try {
      const r = this._db._db.prepare("SELECT param_value FROM sov_governance_params WHERE param_key = 'tx_signature_enforce'").get();
      return r && r.param_value != null ? String(r.param_value) : 'reject';
    } catch (_) { return 'reject'; }
  }

  _authParam(key, fallback) {
    try {
      const r = this._db._db.prepare('SELECT param_value FROM sov_governance_params WHERE param_key = ?').get(key);
      return r && r.param_value != null ? String(r.param_value) : fallback;
    } catch (_) { return fallback; }
  }

  /** Why the citizen did not ask for exactly this op (null = they did, or the kind needs no request). */
  _authCheck(op, now, atApply = false) {
    if (!op.owner || !ownerAuth.RULES[op.kind]) return null;
    const why = ownerAuth.check(op, {
      now, atApply,
      param: (k, f) => this._authParam(k, f),
      pubKeyOf: (acct) => {
        const e = this._db.getEnrollment ? this._db.getEnrollment(acct) : null;
        return e && e.public_key_hex ? e.public_key_hex : null;
      },
    });
    if (!why) return null;
    const mode = this._authMode();
    global.sovLog.warn(`[LEDGER] owner-auth ${op.op_id} (${op.kind}) for ${String(op.owner.acct).slice(0, 16)}: ${why} mode=${mode}`);
    return mode === 'reject' ? why : null;
  }

  /** 1.4.95 (D70): set by transfer_engine — the account's automated-wallet policy, resolved. */
  setPolicyResolver(fn) { this._policyOf = fn; }

  /**
   * 1.4.95 (D70): a citizen's automated-wallet limits bind EVERY way their own SOV moves, and every node
   * enforces them before granting — not only the connected node, and not only for transfers.
   *   per_tx_cap  the op's debit (amount + fee) may not exceed it
   *   daily_cap   the last 24 h of owner debits, read from the REPLICATED ledger, plus this one
   *   allowlist   a transfer must go to a listed account; any other money op is refused while an
   *               allowlist is set — a vault, a listing or a fee would otherwise route SOV past it
   * A verdict is not the owner's own spend and is not limited here.
   */
  _policyCheck(op) {
    if (!op.owner || op.kind === 'verdict' || !this._policyOf) return null;
    let pol = null; try { pol = this._policyOf(op.owner.acct); } catch (_) { pol = null; }
    if (!pol || !pol.enabled) return null;
    const acct = op.owner.acct;
    const debit = (op.moves || []).reduce((s, m) => s + (m.acct === acct && m.d < 0 ? -m.d : 0), 0);
    // For a transfer the cap is on the amount SENT (the fee is the network's, and the wallet's own
    // early check compares the amount) — so a payment exactly at the cap is not refused by peers only.
    const amount = op.kind === 'transfer' && op.transfer ? Math.trunc(Number(op.transfer.amount_seeds) || 0) : debit;
    const allow = Array.isArray(pol.allowlist) ? pol.allowlist : [];
    if (allow.length > 0) {
      if (op.kind !== 'transfer') return 'AUTOMATION_TRANSFERS_ONLY';
      const to = op.transfer && op.transfer.to_id;
      if (!to || !allow.includes(to)) return 'DEST_NOT_ALLOWLISTED';
    }
    if (pol.per_tx_cap > 0 && amount > pol.per_tx_cap) return 'OVER_PER_TX_CAP';
    if (pol.daily_cap > 0 && this._db.ledgerOwnerDebit24h &&
        this._db.ledgerOwnerDebit24h(acct, op.op_id) + amount > pol.daily_cap) return 'OVER_DAILY_CAP';
    return null;
  }

  /** One signed request moves money once: its op id may not be committed, or granted, on another slot. */
  _authReplay(op) {
    if (!op.auth) return null;
    const { acct, nonce } = op.owner;
    if (this._db.ledgerHasOp(op.op_id)) {
      const s = this._db.ledgerSlot(acct, nonce);
      if (!s || s.op_id !== op.op_id) return 'AUTH_REQUEST_ALREADY_USED';
    }
    const other = this._db._db.prepare(
      'SELECT 1 FROM sov_spend_votes WHERE op_id = ? AND released = 0 AND NOT (from_id = ? AND nonce = ?) LIMIT 1'
    ).get(op.op_id, acct, nonce);
    return other ? 'AUTH_REQUEST_ALREADY_USED' : null;
  }

  start() {
    const m = this._mesh;
    m.on('LEDGER_VOTE_REQUEST', (msg) => this._onVoteRequest(msg));
    m.on('LEDGER_VOTE_REPLY',   (msg, ws) => this._onVoteReply(msg, ws));
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
    // 1.4.95: an op that carries the citizen's signed request takes its id FROM that request.
    op.op_id = op.auth ? ownerAuth.opIdFor(op.auth)
                       : (op.op_id || `op-${this.nodeId.slice(0, 8)}-${crypto.randomBytes(8).toString('hex')}`);
    if (this._db.ledgerIsAborted(op.op_id)) return { ok: false, error: 'OP_ABORTED', expected_nonce: nonce };
    const authWhy = this._authCheck(op, Date.now()) || this._authReplay(op) || this._policyCheck(op);
    if (authWhy) return { ok: false, error: authWhy };

    const q = await this._gatherMajority(op);
    if (!q.ok) {
      this._abort(op);
      return { ok: false, error: q.error, expected_nonce: q.expected_nonce };
    }
    // 1.4.94: the signed grants travel with the op, so every node can re-check the majority itself.
    op.cert = { vset: q.vset, grants: q.grants };
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

  /** The validator set this node counts right now: itself, every validator seen in the last 14 days, live peers. */
  _currentVset() {
    const ids = new Set([this.nodeId]);
    try { for (const v of this._db.validatorsActiveAt(Date.now() + 61 * 1000, this.nodeId)) ids.add(v); } catch (_) {}
    for (const p of this._mesh.activePeers()) {
      if (p.ws && p.ws._peerRole === 'serving') continue;          // 1.4.96: serving nodes never vote
      const id = p.ws && p.ws._nodeId; if (id) ids.add(String(id).toLowerCase());
    }
    return [...ids];                       // always contains this node: the origin is in its own certificate
  }

  /** 1.4.96: is THIS node a voting validator (server) or a serving node (desktop app)? */
  _selfVoting() { return global.sovNodeRole !== 'serving'; }

  _opOf(nodeId) { return (this._db.operatorOfNode ? this._db.operatorOfNode(nodeId) : '') || ('node:' + nodeId); }

  _gatherMajority(op) {
    const { acct, nonce } = op.owner;
    const self = this._db.ledgerVote(acct, nonce, op.op_id, this.nodeId);
    if (!self.granted) return Promise.resolve({ ok: false, error: self.reason, expected_nonce: (self.committed_nonce | 0) + 1 });
    const selfGrant = cert.signGrant(this._identity, op);

    const vset = this._currentVset();
    // 1.4.96: the majority is over VOTING validators only. A serving origin is still in the certificate
    // (it must be — it is the origin) but its own grant does not count and it does not shrink the bar.
    const selfVoting = this._selfVoting();
    const voting = selfVoting ? vset : vset.filter(v => v !== this.nodeId);
    const votingSet = new Set(voting);
    const N = voting.length;
    const need = Math.floor(N / 2) + 1;
    // D62: a majority of OPERATORS as well as of nodes — one person's many nodes are one weight.
    // Only operators the registry has actually resolved count; a not-yet-propagated peer (a 'node:'
    // placeholder) does not inflate the requirement. With fewer than 2 resolved operators (the
    // single-operator bootstrap) there is no operator constraint — node-majority is the model until a
    // second independent operator exists (SOV_LEDGER_V2_DESIGN §5).
    const resolvedOp = (v) => { const o = this._opOf(v).toUpperCase(); return o.startsWith('NODE:') ? null : o; };
    const vsetOps = new Set(voting.map(resolvedOp).filter(Boolean));
    const needOps = vsetOps.size >= 2 ? Math.floor(vsetOps.size / 2) + 1 : 0;
    const live = this._mesh.activePeers().filter(p => !(p.ws && p.ws._peerRole === 'serving')).length;
    if (N === 0) return Promise.resolve({ ok: false, error: 'QUORUM_UNAVAILABLE' });   // serving node, no voting peer
    if (selfVoting && need <= 1) {
      if (this._mesh.everHadVerifiedPeer && this._mesh.everHadVerifiedPeer()) {
        return Promise.resolve({ ok: false, error: 'QUORUM_UNAVAILABLE' });
      }
      return Promise.resolve({ ok: true, vset, grants: [selfGrant] });     // never had a second node
    }
    if ((selfVoting ? 1 : 0) + live < need) return Promise.resolve({ ok: false, error: 'QUORUM_UNAVAILABLE' });

    return new Promise((resolve) => {
      const grants = new Map(selfVoting ? [[this.nodeId, selfGrant]] : []);
      const denies = [];
      let done = false;
      const enough = () => {
        if (grants.size < need) return false;
        if (needOps === 0) return true;
        return new Set([...grants.keys()].map(resolvedOp).filter(Boolean)).size >= needOps;
      };
      const finish = (res) => {
        if (done) return; done = true;
        clearTimeout(timer); this._waiters.delete(op.op_id);
        resolve(res);
      };
      const ok = () => ({ ok: true, vset, grants: [...grants.values()] });
      const timer = setTimeout(() => finish(enough() ? ok()
        : { ok: false, error: denies.length ? 'QUORUM_DENIED:' + denies.join(',') : 'QUORUM_UNAVAILABLE' }), VOTE_TIMEOUT_MS);
      this._waiters.set(op.op_id, {
        op,
        onReply: (msg) => {
          if (!votingSet.has(String(msg.voter).toLowerCase())) return;   // 1.4.96: only voting validators count
          if (msg.granted) grants.set(msg.voter, msg.grant);
          else denies.push(msg.reason || 'DENIED');
          if (enough()) return finish(ok());
          if (N - denies.length < need) {   // the undecided can no longer make a majority
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
    // 1.4.94: the request must describe the op it asks about — a grant is a signature over that content.
    if (!op || op.op_id !== op_id || !op.owner || op.owner.acct !== from_id || op.owner.nonce !== nonce) return;
    if (!KNOWN_KINDS.has(op.kind)) return;                              // D57: never grant a slot to an unknown kind
    let r;
    const v = this._validators.get(op.kind);
    // 1.4.95: grant only what the citizen signed for — checked HERE, not taken from the origin's word.
    const why = this._authCheck(op, Date.now()) || this._authReplay(op) || this._policyCheck(op) || (v ? v(op) : null);
    if (why) r = { granted: false, reason: why };
    else r = this._db.ledgerVote(from_id, nonce, op_id, origin_node);
    this._mesh.sendTo(origin_node, 'LEDGER_VOTE_REPLY', {
      op_id, voter: this.nodeId, granted: !!r.granted, reason: r.reason || null, committed_nonce: r.committed_nonce,
      grant: r.granted ? cert.signGrant(this._identity, op) : null,
    });
    if (!r.granted && r.reason === 'NONCE_BEHIND') this._sendDigest(origin_node);   // we are behind: catch up
  }

  _onVoteReply(msg, ws) {
    const w = msg && this._waiters.get(msg.op_id);
    if (!w) return;
    // D61: a reply counts only for the node on the authenticated link it arrived on — before 1.4.94
    // the `voter` field was taken from the message body, so one peer could pose as many voters.
    const linkId = ws && ws._nodeId ? String(ws._nodeId).toLowerCase() : null;
    if (!linkId || String(msg.voter).toLowerCase() !== linkId) {
      global.sovLog.warn(`[LEDGER] vote reply for ${msg.op_id} claims voter ${String(msg.voter).slice(0, 12)} but came from ${String(linkId).slice(0, 12)} — ignored`);
      return;
    }
    if (msg.granted) {
      const g = msg.grant;
      const known = this._mesh.peerPublicKey ? this._mesh.peerPublicKey(linkId) : null;
      if (!g || String(g.voter).toLowerCase() !== linkId || !known || String(known).toLowerCase() !== String(g.pub).toLowerCase()
          || !cert.grantValid(w.op, g)) {
        global.sovLog.warn(`[LEDGER] unsigned or invalid grant for ${msg.op_id} from ${linkId.slice(0, 12)} — ignored`);
        return;
      }
      w.onReply({ granted: true, voter: linkId, grant: g });
    } else {
      w.onReply({ granted: false, voter: linkId, reason: msg.reason });
    }
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

  /** 1.4.94: why a peer's op must not be applied (null = it may be). */
  _trustCheck(op) {
    if (!KNOWN_KINDS.has(op.kind)) return 'UNKNOWN_OP_KIND';           // D57: a kind this node does not understand
    if (isFrozenHistory(op)) return null;                              // pre-1.4.94 history, fingerprinted
    if (LEGACY_KINDS.has(op.kind)) return 'LEGACY_OP_NOT_IN_HISTORY';  // D60: no new baselines / adoptions
    if (op.owner) {
      return cert.verifyCertificate(op, {
        selfId: this.nodeId,
        selfPub: Buffer.from(this._identity.publicKey).toString('hex'),
        knownPub: (n) => (this._db.validatorPub ? this._db.validatorPub(n) : null)
                         || (this._mesh.peerPublicKey ? this._mesh.peerPublicKey(n) : null),
        activeAt: (ts) => (this._db.validatorsActiveAt ? this._db.validatorsActiveAt(ts, this.nodeId) : []),
        selfActiveSince: this._db.selfValidatorSince ? this._db.selfValidatorSince() : 0,
        operatorOf: (n) => this._opOf(n),
        // 1.4.96: a VOTING validator is one this node recorded as such (serving nodes are never
        // recorded), or this node itself when it votes. Only these count toward the majority.
        isVoting: (n) => (n === this.nodeId ? this._selfVoting() : !!(this._db.validatorPub && this._db.validatorPub(n))),
      });
    }
    return null;
  }

  _applyRemote(op) {
    const trust = this._trustCheck(op);
    if (trust) {
      global.sovLog.error(`[LEDGER] refused op ${op.op_id} (${op.kind}) from ${String(op.origin_node).slice(0, 12)}: ${trust}`);
      return 'refused';
    }
    const v = this._validators.get(op.kind);
    // 1.4.95: the citizen's signed request, checked against the time the op was committed (an op
    // replayed from history days later is judged as of its own commit, not as of today).
    const authNeeded = !isFrozenHistory(op) && (op.auth || Number(op.committed_at) >= AUTH_REQUIRED_FROM);
    const why = (authNeeded ? this._authCheck(op, Number(op.committed_at) || Date.now(), true) : null) || (v ? v(op) : null);
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
