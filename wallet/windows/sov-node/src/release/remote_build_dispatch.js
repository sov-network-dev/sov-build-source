'use strict';
/**
 * remote_build_dispatch.js — when a node is too small to build locally (see the RAM
 * gate in release_scheduler.js), it asks a GitHub Actions runner to build instead.
 *
 * ⚠️ TWO CLAIMS THAT USED TO BE HERE WERE WRONG. Corrected 2026-08-26; see
 * docs/BUILDER_REGISTRY_DESIGN.md §1.
 *
 *   "nothing here is load-bearing for the network's survival" — not for survival, but
 *   it IS load-bearing for the property that matters to citizens. A node CAN build
 *   offline (tier 3, proven 2026-08-25), but that artifact compiles sqlite3 from
 *   vendored source, producing a native library with zero global prevalence, which
 *   triggers a Google Play Protect warning on install. The GitHub path is what yields
 *   the artifact a citizen installs WITHOUT a scary dialog. One account being able to
 *   block that is exactly the risk this module must stop being.
 *
 *   "trust is the signature, never the builder" — the signature is applied by ONE key
 *   holder over whatever content it is handed. It proves CONTINUITY (that this release
 *   can update the last) and says nothing about whether the content is honest. A
 *   hostile builder does not forge a signature; it gets the key holder to sign its
 *   bytes. Content trust comes from k-of-n agreement on a CONTENT digest — which does
 *   not exist yet.
 *
 * WHAT IS STILL TRUE: this is inert until configured, so it cannot break a live node,
 * and a node with enough RAM can always build locally.
 *
 * ✅ NO LONGER SINGLE-TARGET. `dispatchToMany()` fans out to builders drawn from
 * sov_builder_registry (tier 2), so losing one account costs a deprioritisation rather
 * than the network's ability to ship. The env vars below remain as the BOOTSTRAP
 * builder — how the FIRST builder exists before a registry has anyone in it — never as
 * "the" builder.
 *
 * A builder is a DISPATCH TARGET, not a trusted party: it never holds the signing key
 * (king, 2026-08-26). It returns content; quorum agrees on a digest; the key holder
 * signs only what reached quorum. See ../protocol/builder_registry.js.
 *
 * Fires a `workflow_dispatch` on the release workflow. INERT until configured: with
 * no env set, dispatch() is a no-op returning {ok:false, reason:'not-configured'} so
 * it never breaks a live node. The token/repo are owner-staged (sealed secret).
 *
 * Pure Node `https` — no extra dependency in the snap.
 *
 * Env:
 *   SOV_BUILD_GITHUB_REPO      e.g. sov-network/sov-releases   (owner/repo)
 *   SOV_BUILD_GITHUB_TOKEN     fine-grained PAT with actions:write on that repo
 *   SOV_BUILD_WORKFLOW         workflow file name or id (default "release.yml")
 *   SOV_BUILD_REF              git ref to build (default "main")
 */
const https = require('https');
const { URL } = require('url');

function _req(method, urlStr, headers, body) {
  return new Promise((resolve) => {
    let u;
    try { u = new URL(urlStr); } catch (_) { return resolve({ ok: false, code: 0, err: 'bad url' }); }
    const data = body == null ? null : (typeof body === 'string' ? body : JSON.stringify(body));
    const opts = {
      method,
      hostname: u.hostname,
      port: u.port || 443,
      path: u.pathname + u.search,
      headers: Object.assign(
        { 'User-Agent': 'sov-node', 'Content-Type': 'application/json' },
        data ? { 'Content-Length': Buffer.byteLength(data) } : {},
        headers || {}
      ),
      timeout: 15000,
    };
    const r = https.request(opts, (res) => {
      let b = '';
      res.on('data', (c) => (b += c));
      res.on('end', () => resolve({ ok: res.statusCode >= 200 && res.statusCode < 300, code: res.statusCode, body: b }));
    });
    r.on('error', (e) => resolve({ ok: false, code: 0, err: e.message }));
    r.on('timeout', () => { r.destroy(); resolve({ ok: false, code: 0, err: 'timeout' }); });
    if (data) r.write(data);
    r.end();
  });
}

/**
 * Ask a GitHub runner to build the release. `inputs` (version, pool count, govVersion)
 * are passed to the workflow so the runner bakes the same bootstrap pool + governance
 * state the node would have. Returns {ok, code, reason?}.
 * @param {object} [env] defaults to process.env (injectable for tests)
 * @param {object} [inputs] workflow_dispatch inputs
 */
async function dispatch(env, inputs) {
  env = env || process.env;
  inputs = inputs || {};
  const repo = env.SOV_BUILD_GITHUB_REPO, token = env.SOV_BUILD_GITHUB_TOKEN;
  if (!repo || !token) return { ok: false, reason: 'not-configured' };
  const workflow = env.SOV_BUILD_WORKFLOW || 'release.yml';
  const ref = env.SOV_BUILD_REF || 'main';
  const api = `https://api.github.com/repos/${repo}/actions/workflows/${encodeURIComponent(workflow)}/dispatches`;
  const auth = { Authorization: `Bearer ${token}`, Accept: 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28' };
  // workflow_dispatch inputs must be strings.
  const wfInputs = {};
  for (const [k, v] of Object.entries(inputs)) if (v != null) wfInputs[k] = String(typeof v === 'object' ? (v.count != null ? v.count : JSON.stringify(v)) : v);
  const res = await _req('POST', api, auth, { ref, inputs: wfInputs });
  // 204 No Content = accepted.
  return { ok: res.ok, code: res.code, reason: res.ok ? undefined : (res.err || `http ${res.code}`) };
}

/**
 * Dispatch to ONE registry builder. Same mechanics as dispatch(), but the target comes
 * from the registry rather than from this node's environment.
 *
 * TOKEN NOTE: a node cannot hold a write token for someone else's repo, and should not
 * want to. A third-party builder authorises SOV by installing the workflow and enabling
 * `repository_dispatch`, and supplies its own token via its own secrets. Where a node
 * has no token for that repo, dispatch falls back to the PUBLIC route: the builder polls
 * (schedule:) and picks the release up itself. Both paths land in the same workflow.
 */
async function dispatchTo(builder, inputs, env) {
  env = env || process.env;
  inputs = inputs || {};
  if (!builder || !builder.github_repo) return { ok: false, reason: 'no-builder' };
  // A token for THIS builder if the operator staged one; otherwise the bootstrap token
  // only when the repo matches the bootstrap repo.
  const perBuilder = env[`SOV_BUILD_TOKEN_${String(builder.builder_id || '').slice(0, 12).toUpperCase()}`];
  const token = perBuilder
    || (builder.github_repo === env.SOV_BUILD_GITHUB_REPO ? env.SOV_BUILD_GITHUB_TOKEN : null);
  if (!token) return { ok: false, reason: 'no-token-for-builder', builderId: builder.builder_id };

  const workflow = builder.workflow || env.SOV_BUILD_WORKFLOW || 'sov-builder.yml';
  const ref = builder.dispatch_ref || env.SOV_BUILD_REF || 'main';
  const api = `https://api.github.com/repos/${builder.github_repo}/actions/workflows/${encodeURIComponent(workflow)}/dispatches`;
  const auth = {
    Authorization: `Bearer ${token}`,
    Accept: 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
  };
  const wfInputs = {};
  for (const [k, v] of Object.entries(inputs)) {
    if (v != null) wfInputs[k] = String(typeof v === 'object' ? (v.count != null ? v.count : JSON.stringify(v)) : v);
  }
  const res = await _req('POST', api, auth, { ref, inputs: wfInputs });
  return {
    ok: res.ok, code: res.code, builderId: builder.builder_id, repo: builder.github_repo,
    reason: res.ok ? undefined : (res.err || `http ${res.code}`),
  };
}

/**
 * Ask a SAMPLE of registered builders to build the same release.
 *
 * Sample, not all: the point is independent answers to compare, and asking everyone
 * every time turns a redundancy mechanism into a thundering herd. Mirrors the operator
 * interrogation's sample/quorum precedent so the protocol has ONE mental model.
 *
 * Returns what was dispatched and what failed. It does NOT wait for builds — results
 * arrive later as attestations over the mesh.
 *
 * @param {object} registry  BuilderRegistry
 * @param {object} inputs    workflow_dispatch inputs (version, sourceRoot, …)
 * @param {object} [opts]    { sample = 5 }
 */
async function dispatchToMany(registry, inputs, opts, env) {
  opts = opts || {};
  const sample = Math.max(1, opts.sample || 5);
  const targets = registry.pickSample(sample);
  if (!targets.length) {
    // Not an error. It is the condition that hands the release to tier 3.
    return { ok: false, reason: 'no-registered-builders', dispatched: [], failed: [], fallbackToTier3: true };
  }
  const dispatched = [], failed = [];
  for (const b of targets) {
    const r = await dispatchTo(b, inputs, env);
    if (r.ok) { dispatched.push(r); registry.markResult(b.builder_id, true); }
    else { failed.push(r); registry.markResult(b.builder_id, false); }
  }
  // EVERY builder failing is the same situation as having none: fall through to the
  // node's own build rather than leaving the release stuck waiting for a quorum that
  // can never form.
  const fallbackToTier3 = dispatched.length === 0;
  if (fallbackToTier3) {
    (global.sovLog || console).warn(
      `[Builders] all ${targets.length} dispatch(es) failed — falling through to tier 3 (local build). ` +
      failed.map((f) => `${f.repo || f.builderId}: ${f.reason}`).join('; ')
    );
  }
  return { ok: dispatched.length > 0, dispatched, failed, fallbackToTier3, sampled: targets.length };
}

module.exports = { dispatch, dispatchTo, dispatchToMany };
