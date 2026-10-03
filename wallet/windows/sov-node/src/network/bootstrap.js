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

/**
 * Nodes this one has learned by gossip, filtered to the ones worth naming.
 *
 * ── WHAT WAS WRONG (found 2026-09-25) ──
 * This query asked for `status` and `last_seen_at`. `sov_node_registry` has
 * NEITHER — its columns are node_id, address, public_key_hex, last_seen,
 * reputation, last_verified. It therefore threw `no such column: status` on
 * every call, and the bare `catch (_) { return []; }` swallowed it in silence.
 * So this function returned [] for months, on every node.
 *
 * The visible symptom was one level up: with no registry contribution,
 * `/relay-pool/latest` (the "clean pool JSON for platform plugins") fell back to
 * `foundationHosts = [nodeIp]` and advertised only the node answering. A platform
 * integrating SOV-Login therefore learned exactly one address from a network of
 * several, and had no in-protocol way to discover the rest — which is why
 * integrators ended up pinning IPs in their own code. The protocol says any node
 * serves (SOV_LINK_PROTOCOL_TEXTBOOK: "Any node in the network serves it"); this
 * function is what made that untrue in practice.
 *
 * ── WHICH NODES TO NAME ──
 * Not a new policy — the same one the mesh already applies when it decides who to
 * gossip about (`peer_mesh.js _handlePeerListRequest`): a node counts if it was
 * VERIFIED-REACHABLE within GOSSIP_FRESH_MS. "Verified" is load-bearing and is
 * defined in REACHABILITY_PROOF_20260801.md §5: we dialled THEM and the handshake
 * completed, so the address demonstrably accepts inbound. A peer that merely
 * dialled US proves it holds its key and nothing about its reachability, and does
 * not advance last_verified.
 *
 * A pure "recently seen" window would be wrong here: last_seen advances on
 * heartbeats from a node we can never dial, so it would advertise addresses that
 * answer nobody. last_verified is the only column that carries the proof.
 */
const GOSSIP_FRESH_MS = 14 * 24 * 60 * 60 * 1000;  // keep in step with peer_mesh.js

/** Reject anything that cannot be a public node address, whatever the source.
 *  A loopback or private address in this list becomes a loopback address baked
 *  into a platform's plugin, where it silently points at the platform's OWN
 *  server. Observed live: the SDK plugin route was serving 127.0.0.1. */
function isRoutableHost(h) {
  if (!h) return false;
  const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(h);
  if (!m) return true;                                   // a DNS name — allowed
  const [a, b] = [Number(m[1]), Number(m[2])];
  if (a === 0 || a === 127 || a === 10 || a >= 224) return false;  // this/loopback/private/multicast
  if (a === 169 && b === 254) return false;                        // link-local
  if (a === 172 && b >= 16 && b <= 31) return false;               // private
  if (a === 192 && b === 168) return false;                        // private
  if (a === 100 && b >= 64 && b <= 127) return false;              // CGNAT
  return true;
}

function fromRegistry(db) {
  try {
    if (!db || !db._db) return [];
    const cutoff = Date.now() - GOSSIP_FRESH_MS;
    return db._db.prepare(
      "SELECT address FROM sov_node_registry " +
      "WHERE address != '' AND last_verified IS NOT NULL AND last_verified >= ? " +
      "ORDER BY last_verified DESC LIMIT 20"
    ).all(cutoff)
      .map((r) => String(r.address).split(':')[0])
      .filter(isRoutableHost);
  } catch (e) {
    // NEVER swallow this again. The original defect survived months precisely
    // because the failure was invisible: the function returned [] and every
    // caller treated that as "no peers known" rather than "the query is broken".
    if (global.sovLog && global.sovLog.warn) {
      global.sovLog.warn('      ! bootstrap: node registry unreadable (' +
        e.message + ') — continuing without gossiped peers');
    }
    return [];
  }
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
