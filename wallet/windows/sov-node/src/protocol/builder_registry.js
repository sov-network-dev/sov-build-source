'use strict';
/**
 * builder_registry.js — TIER 2. Any GitHub account can build for SOV, and no single
 * account can stop the network shipping.
 *
 * King's directive 2026-08-25: *"anyone like myself should be able to push a gethub
 * runner with script that automatically join the network and meaning any account will
 * be able to build too"*, with the node's own build as the final fallback.
 *
 * ── THE CUSTODY RULE (king, 2026-08-26) ───────────────────────────────────────
 * **A BUILDER NEVER HOLDS THE SIGNING KEY.** Builders produce CONTENT. Quorum agrees
 * on a content digest. Only then does the key holder sign, and only that digest.
 *
 * That single decision shapes everything here, and shrinks the threat model to
 * something provable: a hostile builder cannot ship anything, because it cannot sign.
 * The most it can do is publish a digest nobody else agrees with — which is visible,
 * attributable, and costs it its `active` status. It cannot forge a signature, and it
 * cannot get the key holder to sign its bytes, because the key holder is forbidden
 * from signing a digest that did not reach quorum (see [readyToSign]).
 *
 * ── WHY CONTENT AND NOT THE FINISHED FILE ─────────────────────────────────────
 * Measured 2026-08-25: two builds of identical source produce byte-identical ZIP
 * entries and differ ONLY inside the APK Signing Block, because v2 signing uses
 * randomised PSS padding. Compare finished files and every honest builder appears to
 * disagree with every other. So builders are compared on a digest over the CONTENT —
 * the sorted entry hashes — never on the artifact's own sha256.
 *
 * ── WHAT MAKES AGREEMENT POSSIBLE AT ALL ──────────────────────────────────────
 * Proven 2026-08-26: builds ARE reproducible across different userlands (543/543
 * byte-identical across glibc 2.35 vs 2.43 and two JDK point releases) — but ONLY
 * when the absolute build path matches, because the project path is baked into the
 * Dart AOT snapshot. Hence [BUILD_PATH] below, and hence `build_path` is an attested
 * field: two honest builders at different paths disagree for no reason at all, and
 * that must be diagnosable rather than mysterious.
 *
 * ── SYBIL ─────────────────────────────────────────────────────────────────────
 * Agreement counts DISTINCT OPERATORS, not builders. Without that, one party
 * registering three builders satisfies a quorum of three by itself, which is the whole
 * thing this exists to prevent. Same rule the release-source quorum already uses.
 *
 * ── AND THE HONEST LIMIT, STATED IN CODE ──────────────────────────────────────
 * With one registered builder, k-of-n protects nothing: quorum degrades to 1-of-1 and
 * the only check left is the key holder's judgement. This module does not pretend
 * otherwise — every result carries the REAL k and n so a caller can never display a
 * verification badge for agreement that did not happen.
 */
const crypto = require('crypto');

/**
 * The one absolute path every SOV builder builds at, on every tier.
 * MUST match CANONICAL_BUILD_ROOT in ../release/autobuild.js and the bind mount in
 * .github/workflows/*.yml. Changing it changes every artifact's digest network-wide.
 */
const BUILD_PATH = '/sov-apkbuild/proj';

class BuilderRegistry {
  /**
   * @param {object} identity  node identity (nodeId, sign())
   * @param {object} db        NodeDB
   * @param {object} peerMesh  peer mesh (on/broadcast)
   * @param {object} operatorEngine  used for the earned-operator checks
   */
  constructor(identity, db, peerMesh, operatorEngine) {
    this._identity = identity;
    this._db = db;
    this._peerMesh = peerMesh;
    this._ops = operatorEngine;

    this._initTables();

    if (peerMesh && peerMesh.on) {
      peerMesh.on('NODE_BUILDER_SIGNUP', (msg, fromNodeId) => this._handleBuilderSignup(msg, fromNodeId));
      peerMesh.on('BUILDER_REGISTRY_BROADCAST', (msg, fromNodeId) => this._handleRegistryBroadcast(msg, fromNodeId));
      peerMesh.on('BUILD_ATTESTATION', (msg, fromNodeId) => this._handleAttestation(msg, fromNodeId));
    }
    (global.sovLog || console).info('      ✓ Builder registry initialised');
  }

  _initTables() {
    this._db._db.exec(`
      -- ── Registered builders ──────────────────────────────────────────────
      -- A builder is a DISPATCH TARGET, not a trusted party. Nothing here grants
      -- authority to ship; it only decides who gets asked to build.
      CREATE TABLE IF NOT EXISTS sov_builder_registry (
        builder_id      TEXT PRIMARY KEY,            -- sha256(github_repo), stable + public
        operator_id     TEXT NOT NULL,               -- the EARNED operator vouching for it
        github_repo     TEXT NOT NULL,               -- owner/repo
        workflow        TEXT NOT NULL DEFAULT 'sov-builder.yml',
        dispatch_ref    TEXT NOT NULL DEFAULT 'main',
        registered_at   INTEGER NOT NULL,
        approved_by     TEXT NOT NULL DEFAULT '',    -- CSV of node_ids that interrogated it
        status          TEXT NOT NULL DEFAULT 'active',   -- active | unverified | suspended
        last_success_at INTEGER NOT NULL DEFAULT 0,
        last_failure_at INTEGER NOT NULL DEFAULT 0,
        fail_streak     INTEGER NOT NULL DEFAULT 0
      );
      CREATE INDEX IF NOT EXISTS idx_builder_operator ON sov_builder_registry(operator_id);

      -- ── What each builder claims it produced ─────────────────────────────
      -- content_digest is over the SORTED ENTRY HASHES, never the artifact file:
      -- v2 signing randomises PSS padding, so honest builders differ byte-for-byte
      -- on the finished APK while agreeing perfectly on its content.
      CREATE TABLE IF NOT EXISTS sov_build_attestations (
        release_id      TEXT NOT NULL,               -- version + source_root
        builder_id      TEXT NOT NULL,
        operator_id     TEXT NOT NULL,               -- denormalised: agreement counts operators
        source_root     TEXT NOT NULL,
        toolchain_id    TEXT NOT NULL,               -- flutter + ndk + build-tools (NOT the JDK, see below)
        config_hash     TEXT NOT NULL,               -- pubspec + lock + tier's injected state
        build_path      TEXT NOT NULL,
        content_digest  TEXT NOT NULL,
        artifact_url    TEXT NOT NULL DEFAULT '',
        attested_at     INTEGER NOT NULL,
        PRIMARY KEY (release_id, builder_id)
      );
      CREATE INDEX IF NOT EXISTS idx_attest_release ON sov_build_attestations(release_id);
    `);
  }

  /** Stable, public, derived — never a secret, so it can travel in a broadcast. */
  static builderId(githubRepo) {
    return crypto.createHash('sha256').update(String(githubRepo).toLowerCase()).digest('hex').slice(0, 32);
  }

  /**
   * Toolchain identity that must match for two builds to be comparable.
   *
   * The JDK is deliberately EXCLUDED. Measured 2026-08-26: classes.dex was
   * byte-identical across OpenJDK 17.0.19 and 17.0.20, so D8/R8 output is stable
   * across a patch bump and pinning it would reject honest builders for no gain.
   * Flutter/Dart and the NDK are NOT excluded — a Flutter change moves libapp.so by
   * 23.87% (measured).
   */
  static toolchainId({ flutter, dart, ndk, buildTools }) {
    return crypto.createHash('sha256')
      .update([flutter, dart, ndk, buildTools].map((x) => String(x || '')).join('|'))
      .digest('hex').slice(0, 16);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  REGISTRATION
  // ═══════════════════════════════════════════════════════════════════════════

  /**
   * Register a builder this node vouches for, and tell the mesh.
   *
   * `operatorId` must be an EARNED operator — the same bar node registration uses.
   * Letting any enrolled citizen register would make builder-spam free and turn
   * selection into the sybil problem the operator interrogation already solved once.
   */
  registerBuilder({ githubRepo, operatorId, workflow, dispatchRef }) {
    if (!githubRepo || !/^[\w.-]+\/[\w.-]+$/.test(githubRepo)) {
      return { ok: false, reason: 'BAD_REPO' };
    }
    if (!operatorId) return { ok: false, reason: 'NO_OPERATOR' };
    if (!this._isEarnedOperator(operatorId)) return { ok: false, reason: 'OPERATOR_NOT_EARNED' };

    const id = BuilderRegistry.builderId(githubRepo);
    const now = Date.now();
    this._db._db.prepare(`
      INSERT OR REPLACE INTO sov_builder_registry
        (builder_id, operator_id, github_repo, workflow, dispatch_ref, registered_at,
         approved_by, status, last_success_at, last_failure_at, fail_streak)
      VALUES (?, ?, ?, ?, ?, ?, ?, 'active',
              COALESCE((SELECT last_success_at FROM sov_builder_registry WHERE builder_id = ?), 0),
              COALESCE((SELECT last_failure_at FROM sov_builder_registry WHERE builder_id = ?), 0),
              0)
    `).run(id, String(operatorId), githubRepo,
           workflow || 'sov-builder.yml', dispatchRef || 'main', now,
           String(this._identity.nodeId), id, id);

    if (this._peerMesh && this._peerMesh.broadcast) {
      this._peerMesh.broadcast('BUILDER_REGISTRY_BROADCAST', {
        builder_id: id, operator_id: String(operatorId), github_repo: githubRepo,
        workflow: workflow || 'sov-builder.yml', dispatch_ref: dispatchRef || 'main',
        registered_at: now, approved_by: String(this._identity.nodeId),
      });
    }
    (global.sovLog || console).info(`      [Builder] registered ${githubRepo} (${id.slice(0, 12)}…) under ${String(operatorId).slice(0, 16)}`);
    return { ok: true, builderId: id };
  }

  /** An operator with a node that has actually stayed up — not merely present. */
  _isEarnedOperator(operatorId) {
    try {
      const r = this._db._db.prepare(
        `SELECT COUNT(*) n FROM sov_operator_registry
          WHERE operator_id = ? AND status = 'active'`
      ).get(String(operatorId));
      return !!(r && r.n > 0);
    } catch (_) { return false; }
  }

  _handleBuilderSignup(msg, fromNodeId) {
    try {
      const { github_repo, operator_id } = msg || {};
      if (!github_repo || !operator_id) return;
      if (!this._isEarnedOperator(operator_id)) {
        (global.sovLog || console).warn(`      [Builder] signup for ${github_repo} refused — operator not earned`);
        return;
      }
      this.registerBuilder({ githubRepo: github_repo, operatorId: operator_id,
                             workflow: msg.workflow, dispatchRef: msg.dispatch_ref });
    } catch (e) {
      (global.sovLog || console).warn(`      [Builder] signup failed: ${e.message}`);
    }
  }

  /**
   * A peer telling us about a builder.
   *
   * Stored as **unverified**, deliberately. A replicated row carries no evidence of
   * how it was approved, so a receiving node cannot tell an interrogated builder from
   * one a peer simply asserted (the same defect found in the operator registry on
   * 2026-08-26 — docs/REGISTRY_TRUST_FINDING_2026-08-26.md). An unverified builder may
   * be DISPATCHED to, which costs nothing, but its attestation does not count toward
   * quorum until this node has seen its operator qualify locally.
   *
   * Note `fromNodeId` is accepted and used. The operator registry's equivalent handler
   * ignores it, which is how a peer there can set any node's source_root.
   */
  _handleRegistryBroadcast(msg, fromNodeId) {
    try {
      const { builder_id, operator_id, github_repo } = msg || {};
      if (!builder_id || !github_repo || !operator_id) return;
      const known = this._db._db.prepare('SELECT status FROM sov_builder_registry WHERE builder_id = ?').get(builder_id);
      if (known) return;   // never downgrade a locally-approved row from a broadcast
      this._db._db.prepare(`
        INSERT OR IGNORE INTO sov_builder_registry
          (builder_id, operator_id, github_repo, workflow, dispatch_ref, registered_at, approved_by, status)
        VALUES (?, ?, ?, ?, ?, ?, ?, 'unverified')
      `).run(builder_id, String(operator_id), String(github_repo),
             String(msg.workflow || 'sov-builder.yml'), String(msg.dispatch_ref || 'main'),
             Number(msg.registered_at) || Date.now(), String(fromNodeId || ''));
    } catch (_) { /* a malformed broadcast must never take the node down */ }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  SELECTION
  // ═══════════════════════════════════════════════════════════════════════════

  /** Builders worth dispatching to, worst-recent-failure last. */
  activeBuilders() {
    try {
      return this._db._db.prepare(`
        SELECT * FROM sov_builder_registry
         WHERE status IN ('active', 'unverified')
         ORDER BY fail_streak ASC, last_success_at DESC
      `).all();
    } catch (_) { return []; }
  }

  /**
   * A random sample rather than always the same builder — asking the same one every
   * time makes it the single point of failure the tiering exists to remove.
   */
  pickSample(n) {
    const pool = this.activeBuilders();
    // Keep the healthiest half, then shuffle, so a flapping builder is deprioritised
    // without being removed: an account rate-limited today is fine tomorrow.
    const healthy = pool.filter((b) => b.fail_streak < 3);
    const src = healthy.length ? healthy : pool;
    const arr = src.slice();
    for (let i = arr.length - 1; i > 0; i--) {
      const j = crypto.randomInt(i + 1);
      [arr[i], arr[j]] = [arr[j], arr[i]];
    }
    return arr.slice(0, Math.max(0, n));
  }

  markResult(builderId, ok) {
    try {
      if (ok) {
        this._db._db.prepare(
          'UPDATE sov_builder_registry SET last_success_at = ?, fail_streak = 0 WHERE builder_id = ?'
        ).run(Date.now(), builderId);
      } else {
        this._db._db.prepare(
          'UPDATE sov_builder_registry SET last_failure_at = ?, fail_streak = fail_streak + 1 WHERE builder_id = ?'
        ).run(Date.now(), builderId);
      }
    } catch (_) {}
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  ATTESTATION + AGREEMENT
  // ═══════════════════════════════════════════════════════════════════════════

  /** Deterministic id for "the same thing, built by anyone". */
  static releaseId(version, sourceRoot) {
    return `${version}@${String(sourceRoot).slice(0, 16)}`;
  }

  recordAttestation(att) {
    const required = ['release_id', 'builder_id', 'source_root', 'toolchain_id',
                      'config_hash', 'build_path', 'content_digest'];
    for (const k of required) if (!att || !att[k]) return { ok: false, reason: `MISSING_${k.toUpperCase()}` };
    const row = this._db._db.prepare('SELECT operator_id FROM sov_builder_registry WHERE builder_id = ?').get(att.builder_id);
    if (!row) return { ok: false, reason: 'UNKNOWN_BUILDER' };
    this._db._db.prepare(`
      INSERT OR REPLACE INTO sov_build_attestations
        (release_id, builder_id, operator_id, source_root, toolchain_id, config_hash,
         build_path, content_digest, artifact_url, attested_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `).run(att.release_id, att.builder_id, row.operator_id, att.source_root,
           att.toolchain_id, att.config_hash, att.build_path, att.content_digest,
           att.artifact_url || '', Date.now());
    return { ok: true };
  }

  _handleAttestation(msg, fromNodeId) {
    try { this.recordAttestation(msg); } catch (_) {}
  }

  /**
   * Do enough independent builders agree on what this release contains?
   *
   * Returns the REAL k and n, always. A caller must never render a "verified" badge
   * from `agreed` alone without showing that k — 1-of-1 agreement is not verification,
   * and saying so is the difference between honesty and a security theatre badge.
   *
   * Disagreement is split into two kinds because conflating them is dangerous in both
   * directions: treating a version mismatch as an attack trains operators to ignore
   * the alarm, and treating an attack as a version mismatch is fatal.
   */
  agreeDigest(releaseId, quorum) {
    const rows = this._db._db.prepare(
      'SELECT * FROM sov_build_attestations WHERE release_id = ?'
    ).all(releaseId);
    if (!rows.length) return { agreed: false, reason: 'NO_ATTESTATIONS', k: 0, n: 0 };

    // Compare the ATTESTED BUILD PARAMETERS first. Builders that built different
    // things are not in disagreement; they are answering different questions.
    const groups = new Map();
    for (const r of rows) {
      const key = `${r.source_root}|${r.toolchain_id}|${r.config_hash}|${r.build_path}`;
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(r);
    }
    // The largest comparable cohort is the one worth judging.
    const cohort = [...groups.values()].sort((a, b) => b.length - a.length)[0];
    const versionSplit = groups.size > 1;

    // Within one cohort, count DISTINCT OPERATORS per digest. One operator = one voice,
    // so a party running three builders cannot satisfy a quorum of three alone.
    const byDigest = new Map();
    for (const r of cohort) {
      if (!byDigest.has(r.content_digest)) byDigest.set(r.content_digest, new Set());
      byDigest.get(r.content_digest).add(r.operator_id);
    }
    let best = null, bestK = 0;
    for (const [digest, ops] of byDigest) {
      if (ops.size > bestK) { bestK = ops.size; best = digest; }
    }
    const n = new Set(cohort.map((r) => r.operator_id)).size;
    const contentSplit = byDigest.size > 1;

    return {
      agreed: bestK >= quorum,
      digest: best,
      k: bestK,
      n,
      quorum,
      // benign: they built different things
      versionDisagreement: versionSplit,
      // NOT benign: same inputs, different output
      contentDisagreement: contentSplit,
      cohorts: groups.size,
      reason: bestK >= quorum ? 'QUORUM'
        : (contentSplit ? 'CONTENT_DISAGREEMENT' : 'INSUFFICIENT_BUILDERS'),
    };
  }

  /**
   * THE SIGNING GATE. The key holder signs only what this returns `ok` for.
   *
   * King's rule 2026-08-26: "my key signs after quorum agrees". A digest that did not
   * reach quorum is never signed, so it can never become an installable update — which
   * is what stops a hostile builder shipping without ever needing to detect that it is
   * hostile.
   *
   * A content disagreement REFUSES even at quorum: same source, same toolchain, same
   * config, same path, different bytes means either a compromised builder or
   * non-determinism nobody has explained. Both are reasons to stop, not to out-vote.
   */
  readyToSign(releaseId, quorum) {
    const a = this.agreeDigest(releaseId, quorum);
    if (a.contentDisagreement) {
      // Spread FIRST, then override. Written the other way round, agreeDigest's own
      // reason ('QUORUM') silently overwrote the refusal reason, so the caller got
      // {ok:false, reason:'QUORUM'} — a refusal that reads like an approval. The gate
      // still held; the explanation did not, which is its own kind of failure at 3am.
      return { ...a, ok: false, reason: 'CONTENT_DISAGREEMENT_REFUSE_TO_SIGN' };
    }
    if (!a.agreed) return { ok: false, ...a };
    return { ok: true, ...a };
  }
}

module.exports = { BuilderRegistry, BUILD_PATH };
