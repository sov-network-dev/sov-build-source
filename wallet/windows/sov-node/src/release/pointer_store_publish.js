'use strict';
/**
 * pointer_store_publish.js — push the threshold-signed pool+manifest blob to the
 * FEDERATED Layer-B pointer store (no single point of failure, no relay IP).
 * See docs/SOV_LAUNCH_ROADMAP_FINAL_20260617.md §4 + docs/SOV_DOWNLOAD_HOSTING.md §B.
 *
 * The blob is tiny (KB), threshold-signed (trust is the signature, never the host),
 * and pushed to N INDEPENDENT free hosts at once. Any host failing is ignored;
 * >=1 success = published. A new app reads the blob from whichever host answers,
 * verifies the signature locally, then bootstraps — so no relay IP is ever exposed
 * and no single host can stop discovery.
 *
 * INERT until configured: if no host env vars are set, publish() is a no-op (so it
 * never breaks a live node). Fill the env on the publishing node(s) at launch — the
 * accounts are owner-staged (sealed secret), per the roadmap §2/§3.
 *
 * Pure Node `https` — no extra dependency in the snap.
 *
 * Env (all optional; set the ones whose accounts exist):
 *   SOV_PTR_GITHUB_REPO    e.g. neutral-org/sov-dist   (commits sov-manifest.json)
 *   SOV_PTR_GITHUB_TOKEN   a fine-grained PAT with contents:write on that repo
 *   SOV_PTR_GITHUB_PATH    default "sov-manifest.json"
 *   SOV_PTR_CFWORKER_URL   https://<worker>.workers.dev/sov-manifest.json
 *   SOV_PTR_CFWORKER_AUTH  bearer token the worker checks before writing KV
 *   SOV_PTR_RENDER_URL     https://<subdomain>/sov-manifest.json  (Render+Upstash)
 *   SOV_PTR_RENDER_AUTH    bearer token the render server checks
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

// GitHub: PUT /repos/{repo}/contents/{path} (create or update a file). Needs the
// current file sha to update — fetch it first; omit on first create.
async function _pushGitHub(env, blobStr) {
  const repo = env.SOV_PTR_GITHUB_REPO, token = env.SOV_PTR_GITHUB_TOKEN;
  if (!repo || !token) return null;
  const path = env.SOV_PTR_GITHUB_PATH || 'sov-manifest.json';
  const api = `https://api.github.com/repos/${repo}/contents/${path}`;
  const auth = { Authorization: `Bearer ${token}`, Accept: 'application/vnd.github+json' };
  let sha;
  const cur = await _req('GET', api, auth, null);
  if (cur.ok) { try { sha = JSON.parse(cur.body).sha; } catch (_) {} }
  const put = await _req('PUT', api, auth, {
    message: 'sov: update distribution manifest',
    content: Buffer.from(blobStr).toString('base64'),
    ...(sha ? { sha } : {}),
  });
  return { host: 'github', ok: put.ok, code: put.code };
}

async function _pushBearer(host, url, authTok, blobStr) {
  if (!url) return null;
  const headers = authTok ? { Authorization: `Bearer ${authTok}` } : {};
  const r = await _req('PUT', url, headers, blobStr);
  return { host, ok: r.ok, code: r.code };
}

/**
 * Publish the signed blob to every configured federated host.
 * @param {string} signedBlobJson  the threshold-signed pool+manifest JSON string
 * @param {object} [env]           defaults to process.env
 * @returns {Promise<{published:boolean, results:Array}>}
 */
async function publish(signedBlobJson, env = process.env) {
  const tasks = [
    _pushGitHub(env, signedBlobJson),
    _pushBearer('cloudflare', env.SOV_PTR_CFWORKER_URL, env.SOV_PTR_CFWORKER_AUTH, signedBlobJson),
    _pushBearer('render', env.SOV_PTR_RENDER_URL, env.SOV_PTR_RENDER_AUTH, signedBlobJson),
  ];
  const results = (await Promise.all(tasks)).filter(Boolean);
  const published = results.some((r) => r.ok);
  if (results.length === 0) {
    // No hosts configured — inert (do not warn loudly; this is the pre-launch state).
    if (global.sovLog) global.sovLog.debug('[pointer_store] no federated hosts configured — skipping publish');
    return { published: false, results: [] };
  }
  if (global.sovLog) {
    const ok = results.filter((r) => r.ok).map((r) => r.host).join(',') || 'none';
    const bad = results.filter((r) => !r.ok).map((r) => `${r.host}:${r.code}`).join(',') || 'none';
    global.sovLog.info(`[pointer_store] published to: ${ok}  failed: ${bad}`);
  }
  return { published, results };
}

module.exports = { publish };
