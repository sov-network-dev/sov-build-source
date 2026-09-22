'use strict';
/**
 * Bootstrap addresses — deliberately NOT in the source.
 *
 * A published list of the nodes that run the network is a target list: blocking
 * three addresses printed in a public repo is far cheaper than attacking the
 * protocol, and it stops every new install from ever finding the mesh.
 *
 * Encrypting the list does not help. The node has to read it to use it, so the
 * key ships with it — the same reason an embedded signing key is not a secret.
 *
 * So the real list lives outside the source, and a node will take it from
 * whichever of these it finds first:
 *
 *   1. SOV_BOOTSTRAP_NODES in the operator's own .env  (comma-separated)
 *   2. bootstrap.json in the data directory            (written at install)
 *   3. peers already learned by gossip                 (sov_node_registry)
 *   4. nothing — and it says so, loudly
 *
 * One reachable peer is enough; gossip supplies the rest. The aim is many
 * independent ways to learn ONE address, not a hidden list.
 */
const fs = require('fs');
const path = require('path');

/** Documentation addresses (RFC 5737). They route nowhere and are examples only. */
const EXAMPLE_ONLY = ['203.0.113.10', '203.0.113.11', '203.0.113.12'];

function fromEnv() {
  const raw = process.env.SOV_BOOTSTRAP_NODES || '';
  return raw.split(',').map((s) => s.trim()).filter(Boolean);
}

function fromFile() {
  try {
    const dir = process.env.SOV_DATA_DIR ||
      path.join(process.env.SNAP_COMMON || process.env.HOME || '.', '.sov-node');
    const p = path.join(dir, 'bootstrap.json');
    if (!fs.existsSync(p)) return [];
    const j = JSON.parse(fs.readFileSync(p, 'utf8'));
    const list = Array.isArray(j) ? j : (j.nodes || j.bootstrap || []);
    return list.map((x) => (typeof x === 'string' ? x : x.ip || x.address)).filter(Boolean);
  } catch (_) { return []; }
}

function fromRegistry(db) {
  try {
    if (!db || !db._db) return [];
    return db._db.prepare(
      "SELECT address FROM sov_node_registry WHERE address != '' ORDER BY last_seen DESC LIMIT 20"
    ).all().map((r) => String(r.address).split(':')[0]).filter(Boolean);
  } catch (_) { return []; }
}

/** Host strings only, de-duplicated, best source first. */
function bootstrapNodes(db) {
  const seen = new Set();
  const out = [];
  for (const src of [fromEnv(), fromFile(), fromRegistry(db)]) {
    for (const h of src) {
      const host = String(h).replace(/^\w+:\/\//, '').split('/')[0].split(':')[0];
      if (host && !seen.has(host)) { seen.add(host); out.push(host); }
    }
  }
  if (out.length === 0 && global.sovLog && global.sovLog.warn) {
    global.sovLog.warn(
      '      ! No bootstrap address configured — will ask the pointer mirrors.');
  }
  return out;
}


/**
 * Independently-hosted copies of the current pool.
 *
 * These are the SAME files the client app reads. They host a small JSON list and
 * nothing else — no node ever connects to them, and they never learn anything
 * about the network beyond what the publisher put there. Losing all of them costs
 * discovery convenience, not the network: nodes that already know each other keep
 * gossiping, and an operator can still be handed one address directly.
 */
const POINTER_URLS = [
  'https://raw.githubusercontent.com/sov-network/relay-releases/main/relay_pool.json',
  'https://sov-pointer.sovnetworkdev.workers.dev/relay-pool.json',
];

/** Fetch one pointer. Resolves to [] on any problem — never throws into boot. */
function fetchPointer(url, timeoutMs = 8000) {
  return new Promise((resolve) => {
    let done = false;
    const finish = (v) => { if (!done) { done = true; resolve(v); } };
    try {
      const https = require('https');
      const req = https.get(url, { timeout: timeoutMs }, (res) => {
        if (res.statusCode !== 200) { res.resume(); return finish([]); }
        let body = '';
        res.setEncoding('utf8');
        res.on('data', (c) => { body += c; if (body.length > 512000) req.destroy(); });
        res.on('end', () => {
          try {
            const j = JSON.parse(body);
            const nodes = (j.nodes || j.payload?.nodes || []);
            finish(nodes.map((n) => String(n.address || '').split(':')[0]).filter(Boolean));
          } catch (_) { finish([]); }
        });
      });
      req.on('error', () => finish([]));
      req.on('timeout', () => { try { req.destroy(); } catch (_) {} finish([]); });
    } catch (_) { finish([]); }
    setTimeout(() => finish([]), timeoutMs + 1000);
  });
}

/**
 * Ask the pointer mirrors where the network is, and remember the answer.
 *
 * Only called when nothing local knows an address — a fresh install, or a machine
 * whose only known peer has gone. The result is written to bootstrap.json so the
 * next boot needs no network at all, and so a mirror outage cannot strand a node
 * that has already been told once.
 */
async function discoverFromPointers() {
  const found = [];
  for (const url of POINTER_URLS) {
    const hosts = await fetchPointer(url);
    for (const h of hosts) if (!found.includes(h)) found.push(h);
    if (found.length) break;               // first mirror that answers is enough
  }
  if (!found.length) return [];

  try {
    const dir = process.env.SOV_DATA_DIR ||
      path.join(process.env.SNAP_COMMON || process.env.HOME || '.', '.sov-node');
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, 'bootstrap.json'),
      JSON.stringify({ nodes: found, learned_at: Date.now() }, null, 2));
  } catch (_) { /* discovery still worked even if we could not cache it */ }

  if (global.sovLog && global.sovLog.info) {
    global.sovLog.info(`      Discovered ${found.length} node(s) via the pointer mirrors`);
  }
  return found;
}

module.exports = { bootstrapNodes, discoverFromPointers, EXAMPLE_ONLY };
