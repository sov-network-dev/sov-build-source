'use strict';
/**
 * release_coordinator.js — lets ANY node build + publish app updates without a
 * single point of failure, while the mesh stays in agreement on the current
 * version (king's architecture, 2026-06-10).
 *
 * No dedicated builder. Every node carries the toolchain (bundled in the snap) and
 * may publish. Consensus + anti-conflict come from TWO things:
 *
 *   1. VERSION CONSENSUS — the latest validly **threshold-signed** Distribution
 *      Manifest is gossiped across the mesh (RELEASE_MANIFEST_BROADCAST). A node
 *      only builds/publishes when its bundled source version is NEWER than the
 *      highest threshold-signed version the mesh already knows. So nodes don't
 *      stampede the same version, and a stale/rogue node can't regress it.
 *
 *   2. THRESHOLD SIGNATURE — a manifest is only "published" once >= threshold
 *      witness-signers have co-signed it (release_signer envelope). One node can
 *      START a release (build + first signature + broadcast for co-signing) but
 *      cannot finalize alone — so any node can initiate, no node can forge.
 *
 * The actual binaries live on an EXTERNAL download host (a governance param,
 * `app_download_host`) — never a node IP (no-IP policy). The manifest's per-platform
 * URLs are built from that host; that link is the canonical download for the snap,
 * the apk, and the windows app.
 */
const crypto = require('crypto');
const { verifyManifest } = require('./release_signer');

/**
 * Fingerprint the live relay pool. The PRIMARY reason to republish an app is that the
 * bootstrap pool baked into the download has gone stale as the network grows — so a
 * fresh download must carry the CURRENT pool, and a citizen on a recent download still
 * reaches live relays even if the genesis node has died. We fingerprint the pool so
 * nodes agree on whether the published download already reflects it.
 * @param nodes array of {node_id|id, endpoint|address} (any stable identity fields)
 * @returns {count, hash}  hash = sha256 over the SORTED node identities (order-stable)
 */
function poolFingerprint(nodes) {
  const ids = (nodes || [])
    .map((n) => String((n && (n.node_id || n.id || n.endpoint || n.address)) || '').trim().toLowerCase())
    .filter(Boolean)
    .sort();
  const hash = crypto.createHash('sha256').update(ids.join('|')).digest('hex');
  return { count: ids.length, hash };
}

// Compare dotted numeric versions: 1 if a>b, -1 if a<b, 0 if equal.
function cmpVersion(a, b) {
  const pa = String(a || '0').split('.').map((n) => parseInt(n, 10) || 0);
  const pb = String(b || '0').split('.').map((n) => parseInt(n, 10) || 0);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const x = pa[i] || 0, y = pb[i] || 0;
    if (x > y) return 1;
    if (x < y) return -1;
  }
  return 0;
}

class ReleaseCoordinator {
  /**
   * @param o.trustKeys   network trust keys (>= threshold must have signed to count)
   * @param o.threshold   min co-signatures for a manifest to be "published"
   * @param o.getGovParam (key, fallback) => string  — reads governance params
   */
  constructor(o) {
    this.trustKeys = o.trustKeys || [];
    this.threshold = o.threshold || 1;
    this.getGovParam = o.getGovParam || (() => '');
    this.latest = null;          // highest fully-signed manifest the mesh knows
    this.pending = new Map();     // version -> manifest still collecting signatures
  }

  /** The external host every node points users to (governance-set; never a node IP). */
  downloadHost() {
    const h = this.getGovParam('app_download_host', '');
    return h && !/^https?:\/\/\d+\.\d+\.\d+\.\d+/.test(h) ? h.replace(/\/?$/, '/') : '';
  }
  baseUrls() {
    const h = this.downloadHost();
    return { windows: h, macos: h, linux: h, android: h, snap: h };
  }

  /** Ingest a manifest gossiped from a peer (or freshly built). Updates `latest` if it
   *  is validly threshold-signed AND newer; tracks partials in `pending`. */
  ingest(manifest) {
    if (!manifest || !manifest.version) return { accepted: false, reason: 'no-version' };
    const v = verifyManifest(manifest, this.trustKeys, this.threshold);
    if (v.ok) {
      // Accept as the new latest if it is a newer code version, OR the SAME version
      // but built later (a pool-refresh republish — same code, fresher bootstrap pool).
      const vc = this.latest ? cmpVersion(manifest.version, this.latest.version) : 1;
      const newer = !this.latest || vc > 0 ||
        (vc === 0 && (manifest.built_at || 0) > (this.latest.built_at || 0));
      if (newer) {
        const prevPool = this.latest && this.latest.pool;
        this.latest = manifest;
        this.pending.delete(manifest.version);
        const poolChanged = !prevPool || (manifest.pool || {}).hash !== prevPool.hash;
        // ── No-IP distribution trigger ────────────────────────────────────────
        // Republish the newly-adopted threshold-signed manifest to the federated
        // POINTER mirrors (GitHub raw / Cloudflare / Render) so the app's
        // `manifestLocations` always fetch the latest signed blob. Fires on BOTH
        // paths — this node just built it, OR received it via
        // RELEASE_MANIFEST_BROADCAST — so whichever node holds the mirror creds
        // keeps them fresh. Fire-and-forget + INERT until pointer-store creds exist
        // in env (no-op, debug-log only). Never blocks or breaks consensus ingest.
        try {
          require('./pointer_store_publish')
            .publish(JSON.stringify(this.latest))
            .catch((e) => { if (global.sovLog) global.sovLog.debug('[pointer_store] publish error: ' + e.message); });
        } catch (_) { /* module missing — must never break ingest */ }
        return { accepted: true, role: 'published', version: manifest.version, poolRefresh: poolChanged, poolCount: (manifest.pool || {}).count };
      }
      return { accepted: false, reason: 'not-newer-or-older-build' };
    }
    // partial (under threshold) — remember the best partial for this version so a
    // node can add its signature and re-broadcast.
    const prev = this.pending.get(manifest.version);
    const better = !prev || (manifest.sigs || []).length > (prev.sigs || []).length;
    if (better) this.pending.set(manifest.version, manifest);
    return { accepted: false, reason: 'collecting-signatures', have: (manifest.sigs || []).length, need: this.threshold };
  }

  /** Should THIS node build + republish now? Any node may initiate when EITHER:
   *   (a) the code version is newer than the mesh's latest published, OR
   *   (b) the LIVE relay pool has changed vs the pool baked into the latest
   *       published download (the growth-driven trigger — keeps new downloads'
   *       bootstrap pool fresh so citizens survive the genesis node dying).
   *  @param bundledVersion this node's source version
   *  @param livePool       poolFingerprint(currentRelayPool) — {count, hash}
   */
  shouldPublish(bundledVersion, livePool) {
    if (!this.latest) return true;                                   // genesis: first publish
    if (cmpVersion(bundledVersion, this.latest.version) > 0) return true;  // code update
    const publishedPool = this.latest.pool || {};
    if (livePool && livePool.hash && livePool.hash !== publishedPool.hash) return true; // pool grew/changed
    // Governance trigger (king, 2026-08-15): a poll that activated/deactivated a feature
    // bumps governance_version. The published download must carry that new default so
    // NEW users get the current feature state — so a govVersion ahead of the published
    // manifest's baked gov_version forces a republish.
    if (this._govAhead()) return true;
    return false;
  }
  /** True if the live governance_version is ahead of the latest published manifest's. */
  _govAhead() {
    const cur = parseInt(this.getGovParam('governance_version', '0'), 10) || 0;
    return cur > ((this.latest && this.latest.gov_version) || 0);
  }
  /** Reason string for logging/telemetry. */
  publishReason(bundledVersion, livePool) {
    if (!this.latest) return 'genesis-first-publish';
    if (cmpVersion(bundledVersion, this.latest.version) > 0) return 'code-update';
    if (livePool && livePool.hash !== (this.latest.pool || {}).hash)
      return `pool-refresh(${(this.latest.pool || {}).count || 0}->${livePool.count})`;
    if (this._govAhead())
      return `governance-change(${(this.latest && this.latest.gov_version) || 0}->${parseInt(this.getGovParam('governance_version', '0'), 10) || 0})`;
    return 'up-to-date';
  }

  /** The manifest a node should co-sign next for `version`, if one is mid-collection. */
  partialFor(version) { return this.pending.get(version) || null; }
  latestPublished() { return this.latest; }
}

module.exports = { ReleaseCoordinator, cmpVersion, poolFingerprint };
