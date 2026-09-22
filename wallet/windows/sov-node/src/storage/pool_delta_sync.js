// ─────────────────────────────────────────────────────────────────────────────
// POOL DELTA SYNC  (PI-13 — general supply-pool delta propagation across the mesh)
// ─────────────────────────────────────────────────────────────────────────────
// PROBLEM (logged SESSION_PLAN.md ~2026-06-04, the general case of PI-11):
//   sov_supply_pools mutations (deductFromPool / addToPool / refundPool) ran ONLY
//   on the node that handled the originating op. Peers never saw the mutation, so
//   pools diverged across the 4-node mesh (e.g. VPS1 witness_operator
//   distributed=-157505 while peers sat at 0 until a manual reconcile). Pools are
//   NOT in computeMerkleRoot() (sov_disc only), so convergence checks never caught
//   it — but the per-node supply invariant (allocated = remaining + distributed)
//   silently drifted.
//
// DESIGN — propagate the COMPUTED delta, not the operation:
//   * Every local pool mutation records an immutable row in sov_pool_deltas
//     (delta_id = "<origin_node>:<seq>") IN THE SAME TRANSACTION as the pool
//     UPDATE, and emits it to this sink (db.setPoolDeltaSink).
//   * We broadcast it as POOL_DELTA. Peers call db.applyRemotePoolDelta(), which
//     is idempotent: INSERT OR IGNORE on delta_id; the pool UPDATE runs ONLY when
//     the insert actually added a row. Re-delivery / replay is therefore safe.
//   * Peers apply the EXACT numeric delta the origin computed — they do NOT re-run
//     deductFromPool's min(requested, remaining) clamp. This is what makes every
//     node land on identical pool values regardless of local ordering.
//
//   The peer mesh broadcast() is best-effort to currently-connected verified peers
//   (no store-and-forward). A peer that is briefly down misses the live POOL_DELTA.
//   ANTI-ENTROPY closes that gap: each node periodically broadcasts a
//   POOL_DELTA_DIGEST (per origin_node → max seq it holds). A peer that is behind
//   replies with POOL_DELTA_PULL; the holder replays the missing deltas via
//   sendTo(). Because applyRemotePoolDelta() is idempotent, replay never double-
//   applies. This is the durable correctness guarantee; the live broadcast is just
//   the fast path.
//
// LOCKSTEP REQUIREMENT (money code — deploy together or not at all):
//   enrollment_engine._handleEnrollmentBroadcast currently runs a MANUAL
//   deductFromPool('citizen_enrollment', rewardSeeds) on peers (the PI-11 fix).
//   Once db.deductFromPool auto-propagates, that manual line DOUBLE-deducts on
//   peers. The PI-11 manual deduct line MUST be removed in the same deploy. See
//   docs/POOL_DELTA_PROPAGATION.md §"Mandatory simultaneous change".
// ─────────────────────────────────────────────────────────────────────────────

'use strict';

const DIGEST_INTERVAL_MS = 5 * 60 * 1000; // anti-entropy sweep cadence

class PoolDeltaSync {
  // db        — NodeDB (must expose: applyRemotePoolDelta, poolDeltaDigest,
  //             poolDeltasAfter, setPoolDeltaSink, setNodeId)
  // peerMesh  — PeerMesh (broadcast / sendTo / on)
  // identity  — NodeIdentity (nodeId)
  constructor(db, peerMesh, identity) {
    this._db       = db;
    this._mesh     = peerMesh;
    this._identity = identity;
    this._timer    = null;
  }

  start() {
    // Tell the DB who we are so it can stamp origin_node/seq on local deltas,
    // and route every locally-recorded delta straight onto the wire.
    this._db.setNodeId(this._identity.nodeId);
    this._db.setPoolDeltaSink((delta) => {
      // delta already persisted + applied locally by the DB; just publish it.
      this._mesh.broadcast('POOL_DELTA', delta);
    });

    // Inbound live deltas from peers.
    this._mesh.on('POOL_DELTA', (msg) => {
      try {
        this._db.applyRemotePoolDelta(msg);
      } catch (e) {
        global.sovLog.warn(`[POOL] applyRemotePoolDelta failed: ${e.message}`);
      }
    });

    // Anti-entropy: a peer announces what it holds; we pull anything we're missing
    // and (symmetrically) push anything it is missing.
    this._mesh.on('POOL_DELTA_DIGEST', (msg) => this._onDigest(msg));
    this._mesh.on('POOL_DELTA_PULL',   (msg) => this._onPull(msg));

    // Kick one digest shortly after start (let peer handshakes settle), then loop.
    setTimeout(() => this._broadcastDigest(), 20 * 1000);
    this._timer = setInterval(() => this._broadcastDigest(), DIGEST_INTERVAL_MS);
  }

  stop() {
    if (this._timer) clearInterval(this._timer);
    this._timer = null;
  }

  _broadcastDigest() {
    this._mesh.broadcast('POOL_DELTA_DIGEST', {
      from_node: this._identity.nodeId,
      digest:    this._db.poolDeltaDigest(), // { origin_node: maxSeq }
    });
  }

  // A peer told us its high-water marks. For every origin where WE are behind,
  // ask it to replay. For every origin where IT is behind, replay to it.
  _onDigest(msg) {
    if (!msg || msg.from_node === this._identity.nodeId) return;
    const theirs = msg.digest || {};
    const ours   = this._db.poolDeltaDigest();

    // Origins the peer knows about where we are behind (or have none) → pull.
    const want = {};
    for (const [origin, theirMax] of Object.entries(theirs)) {
      const ourMax = ours[origin] || 0;
      if (theirMax > ourMax) want[origin] = ourMax;
    }
    if (Object.keys(want).length > 0) {
      this._mesh.sendTo(msg.from_node, 'POOL_DELTA_PULL', {
        from_node: this._identity.nodeId,
        after:     want, // { origin_node: afterSeq }
      });
    }

    // Origins we know about where the peer is behind → push proactively.
    for (const [origin, ourMax] of Object.entries(ours)) {
      const theirMax = theirs[origin] || 0;
      if (ourMax > theirMax) this._replayTo(msg.from_node, origin, theirMax);
    }
  }

  // A peer asked us to replay deltas it is missing.
  _onPull(msg) {
    if (!msg || !msg.from_node || !msg.after) return;
    for (const [origin, afterSeq] of Object.entries(msg.after)) {
      this._replayTo(msg.from_node, origin, afterSeq);
    }
  }

  _replayTo(nodeId, origin, afterSeq) {
    const rows = this._db.poolDeltasAfter(origin, afterSeq | 0);
    for (const r of rows) {
      this._mesh.sendTo(nodeId, 'POOL_DELTA', {
        delta_id:          r.delta_id,
        origin_node:       r.origin_node,
        seq:               r.seq,
        pool_id:           r.pool_id,
        remaining_delta:   r.remaining_delta,
        distributed_delta: r.distributed_delta,
        reason:            r.reason,
        created_at:        r.created_at,
      });
    }
  }
}

module.exports = { PoolDeltaSync };
