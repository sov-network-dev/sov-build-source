'use strict';
// dedup_delegation.js — Phase 2 of docs/SOV_CAPABILITY_TIERED_COMPUTE.md.
//
// A node that cannot hold the biometric set (tier 'light') must still refuse a second enrolment
// by the same human. It asks N peers that advertise tier 'full' to run the palm dedup for it, and
// accepts an answer only when T of them agree, each answer signed by the peer that gave it.
//
// What a witness sees: the CANCELABLE-transformed template (palm_cancelable, keyed by the
// network seed every member holds) — the same form the template is stored and replicated in.
// No raw biometric leaves the requester.
//
// Trust rules, and why:
//   * A result counts only if it arrived on the socket of the peer it was sent to, names that
//     peer as its signer, and verifies under the key that peer proved at PEER_HELLO — and that
//     key hashes to the node id (node ids are sha256(public key)). A result cannot be replayed
//     from another request either: it is bound to the request id and a fresh nonce.
//   * 'unique' needs T no-match votes AND no match vote; 'duplicate' needs T match votes.
//     Anything else — disagreement, abstentions, timeouts — is 'inconclusive', and the caller
//     REFUSES the enrolment (asks the person to retry). One dishonest witness can therefore
//     delay an enrolment, but cannot let a duplicate human in or lock a real one out.
//   * A witness that is light itself, or has no network seed, ABSTAINS rather than answer
//     'no match' from an incomplete set — the same reason the local gate refuses without a seed.
const crypto = require('crypto');
const { NodeIdentity } = require('../security/node_identity');

const DEFAULTS = { n: 3, t: 2, timeoutMs: 8000 };
const MAX_REQUESTS_PER_PEER_PER_MIN = 30;

// The one template-scan routine (cosine against a stored set), shared by every gate so all judge alike.
function scanPalm(rows, probe, threshold) {
  let maxSim = 0, matchedId = null, checked = 0;
  for (const row of rows) {
    let stored;
    try { stored = JSON.parse(row.embedding_json); } catch (_) { continue; }
    if (!Array.isArray(stored) || stored.length !== probe.length) continue;
    checked++;
    let d = 0, na = 0, nb = 0;
    for (let i = 0; i < probe.length; i++) { d += probe[i] * stored[i]; na += probe[i] * probe[i]; nb += stored[i] * stored[i]; }
    const sim = (na && nb) ? d / (Math.sqrt(na) * Math.sqrt(nb)) : 0;
    if (sim > maxSim) maxSim = sim;
    if (sim >= threshold) { matchedId = row.sovereign_id; break; }
  }
  return { matchedId, maxSim, checked };
}

// The two biometric gates. Each kind has its own template length, stored set and threshold;
// the thresholds are read the same way the local gates read them, so local and delegated
// dedup judge identically.
const KINDS = {
  palm: { len: 128, rows: (db) => db.getAllPalmEmbeddings(), threshold: () => parseFloat(process.env.PALM_DEDUP_THRESHOLD || '0.92') },
  face: { len: 192, rows: (db) => db.getAllFaceEmbeddings(), threshold: () => parseFloat(process.env.FACE_DEDUP_THRESHOLD || '0.70') },
};

function validProbe(kind, p) {
  const k = KINDS[kind];
  return !!k && Array.isArray(p) && p.length === k.len && p.every(x => typeof x === 'number' && Number.isFinite(x));
}

// The exact bytes a witness signs. Field order is fixed; nothing optional is left out.
function resultBody(r) {
  return Buffer.from([
    'SOV-DEDUP-RESULT-v1', r.kind, r.req_id, r.nonce, r.verdict, r.matched_sovereign_id || '',
    String(r.checked | 0), r.node_id,
  ].join('|'));
}

class DedupDelegation {
  constructor(identity, db, peerMesh, opts = {}) {
    this._identity = identity;
    this._db       = db;
    this._mesh     = peerMesh;
    this._hasSeed   = opts.hasSeed || (() => require('../security/network_seed').has());
    this._ownTier   = opts.ownTier || (() => { try { return db.computeCapability().tier; } catch (_) { return 'unknown'; } });
    this._pending   = new Map();   // req_id -> { nonce, asked:Set, votes:Map, resolve, timer }
    this._rate      = new Map();   // nodeId -> { minute, count }
    peerMesh.on('DEDUP_REQUEST', (msg, ws) => this._onRequest(msg, ws));
    peerMesh.on('DEDUP_RESULT',  (msg, ws) => this._onResult(msg, ws));
  }

  // Peers worth asking: full tier, disk not critical, most headroom first.
  candidates() {
    return this._mesh.peerCapabilities()
      .filter(p => p.capability && p.capability.tier === 'full' && p.capability.disk_status !== 'critical')
      .sort((a, b) => (a.capability.pressure ?? 1) - (b.capability.pressure ?? 1))
      .map(p => p.nodeId);
  }

  // kind = 'palm' | 'face'; probe = that kind's CANCELABLE-transformed template. Resolves to
  // { verdict: 'unique'|'duplicate'|'inconclusive', matched_sovereign_id, votes, asked, reason }.
  delegate(kind, probe, opts = {}) {
    const n = opts.n || DEFAULTS.n, t = opts.t || DEFAULTS.t, timeoutMs = opts.timeoutMs || DEFAULTS.timeoutMs;
    if (!validProbe(kind, probe)) return Promise.resolve({ verdict: 'inconclusive', reason: 'BAD_PROBE', votes: [], asked: [] });
    const peers = this.candidates().slice(0, n);
    if (peers.length < t) {
      return Promise.resolve({ verdict: 'inconclusive', reason: 'NOT_ENOUGH_WITNESSES', votes: [], asked: peers });
    }
    const req_id = crypto.randomBytes(16).toString('hex');
    const nonce  = crypto.randomBytes(16).toString('hex');
    return new Promise((resolve) => {
      const p = { kind, nonce, asked: new Set(), votes: new Map(), t, resolve, timer: null };
      this._pending.set(req_id, p);
      for (const nodeId of peers) {
        if (this._mesh.sendTo(nodeId, 'DEDUP_REQUEST', { node_id: this._identity.nodeId, kind, req_id, nonce, probe })) p.asked.add(nodeId);
      }
      p.timer = setTimeout(() => this._finish(req_id, 'TIMEOUT'), timeoutMs);
      if (p.asked.size < t) this._finish(req_id, 'SEND_FAILED');
    });
  }

  _finish(req_id, reason) {
    const p = this._pending.get(req_id);
    if (!p) return;
    clearTimeout(p.timer);
    this._pending.delete(req_id);
    const votes = [...p.votes.values()];
    const match = votes.filter(v => v.verdict === 'match');
    const clear = votes.filter(v => v.verdict === 'no_match');
    let verdict = 'inconclusive', matched = null;
    if (match.length >= p.t && clear.length === 0) {
      const ids = new Set(match.map(v => v.matched_sovereign_id));
      if (ids.size === 1) { verdict = 'duplicate'; matched = match[0].matched_sovereign_id; }
      else reason = 'WITNESSES_NAME_DIFFERENT_CITIZENS';
    } else if (clear.length >= p.t && match.length === 0) {
      verdict = 'unique';
    } else if (match.length && clear.length) {
      reason = 'WITNESSES_DISAGREE';
    }
    p.resolve({ verdict, matched_sovereign_id: matched, votes, asked: [...p.asked], reason: verdict === 'inconclusive' ? reason : undefined });
  }

  _maybeDone(req_id) {
    const p = this._pending.get(req_id);
    if (!p) return;
    const votes = [...p.votes.values()];
    const match = votes.filter(v => v.verdict === 'match').length;
    const clear = votes.filter(v => v.verdict === 'no_match').length;
    // Finish early only when the outcome can no longer change.
    if (p.votes.size === p.asked.size) return this._finish(req_id, 'ALL_ANSWERED');
    if (match > 0 && clear > 0) return this._finish(req_id, 'WITNESSES_DISAGREE');
  }

  // ── witness side ────────────────────────────────────────────────────────────
  _onRequest(msg, ws) {
    const from = ws && ws._nodeId;
    if (!from || typeof msg.req_id !== 'string' || typeof msg.nonce !== 'string' ||
        msg.req_id.length > 64 || msg.nonce.length > 64) return;
    const now = Math.floor(Date.now() / 60000), r = this._rate.get(from) || { minute: now, count: 0 };
    if (r.minute !== now) { r.minute = now; r.count = 0; }
    if (++r.count > MAX_REQUESTS_PER_PEER_PER_MIN) { this._rate.set(from, r); return; }
    this._rate.set(from, r);

    let verdict, matched = null, checked = 0;
    const kind = KINDS[msg.kind] ? msg.kind : null;
    if (!kind) return;
    if (!validProbe(kind, msg.probe)) verdict = 'abstain';
    else if (this._ownTier() !== 'full' || !this._hasSeed()) verdict = 'abstain';
    else {
      const s = scanPalm(KINDS[kind].rows(this._db), msg.probe, KINDS[kind].threshold());
      checked = s.checked; matched = s.matchedId; verdict = matched ? 'match' : 'no_match';
    }
    const res = { kind, req_id: msg.req_id, nonce: msg.nonce, verdict, matched_sovereign_id: matched, checked, node_id: this._identity.nodeId };
    res.att = this._identity.signMessage(resultBody(res)).toString('hex');
    this._mesh.sendTo(from, 'DEDUP_RESULT', res);
  }

  // ── requester side ──────────────────────────────────────────────────────────
  _onResult(msg, ws) {
    const p = this._pending.get(msg.req_id);
    const from = ws && ws._nodeId;
    if (!p || !from || !p.asked.has(from) || p.votes.has(from)) return;
    if (msg.nonce !== p.nonce || msg.node_id !== from || msg.kind !== p.kind) return;
    if (!['match', 'no_match', 'abstain'].includes(msg.verdict)) return;
    if (msg.verdict === 'match' && typeof msg.matched_sovereign_id !== 'string') return;
    const keyHex = this._mesh.peerPublicKey(from);
    if (!keyHex || typeof msg.att !== 'string') return;
    const key = Buffer.from(keyHex, 'hex');
    if (crypto.createHash('sha256').update(key).digest('hex') !== from) return;
    let ok = false;
    try { ok = NodeIdentity.verify(resultBody(msg), Buffer.from(msg.att, 'hex'), key); } catch (_) { ok = false; }
    if (!ok) return;
    p.votes.set(from, { node_id: from, verdict: msg.verdict, matched_sovereign_id: msg.matched_sovereign_id || null, checked: msg.checked | 0 });
    this._maybeDone(msg.req_id);
  }
}

module.exports = { DedupDelegation, scanPalm, resultBody, validProbe, KINDS, DEFAULTS };
