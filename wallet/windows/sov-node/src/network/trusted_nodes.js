'use strict';
// trusted_nodes.js — node 1.4.97 (audit D79/D81/D85): which peers may hand this node state that no
// citizen signed.
//
// Until 1.4.97 every peer that passed the PEER_HELLO interrogation was trusted with everything: its
// STATE_DELTA rows (citizens, guardians, disputes, vaults, platforms, group members…), its unsigned
// broadcasts, and the system money ops it originated (verdicts, payouts, grants, claims). Admission
// proves only that a node runs the published source under SOME enrolled operator id — the operator
// does not sign anything, so any machine running the open source could join and inject. The
// consensus audit (docs/security/CONSENSUS_REPLICATION_AUDIT_2026-10-14.md) lists what that allowed.
//
// The interim rule: a peer is TRUSTED only if its authenticated node id (sha256 of the key it proved
// at PEER_HELLO — it cannot be claimed) is on this node's list. Everything a citizen SIGNED (transfers
// and every other owner money op, votes, petitions, disputes, juror votes, messaging keys) is still
// accepted from ANY peer, because each node verifies the citizen's signature itself. What is
// refused from an untrusted peer is only what rests on that peer's word.
//
// The list, first match wins:
//   1. SOV_TRUSTED_NODES  — comma-separated node ids (env)
//   2. <SOV_DATA_DIR>/trusted_nodes.json — a JSON array of node ids (re-read when it changes)
//   3. DEFAULT_TRUSTED — the three network servers running at 1.4.97.
// A node id that is THIS node is always trusted. This is a transitional measure: it goes away as
// each replicated table gets its own per-row proof (the audit's per-table plan).

const fs = require('fs');
const path = require('path');
const os = require('os');

const DEFAULT_TRUSTED = [
  '374aaebb13df31a7c3a49f05e90e8375d688df84cd73380159e42d69c662764b',
  '51f31ad928e9fe69b0a2a90ab8a87042e8de45a2e5ae2124dd6f072a9437fc6b',
  '0c3b6ddd167a0c6c90421cdb851a77cc7a568ef6d429bc5eee2c0b30823faeb5',
];

const ID_RE = /^[0-9a-f]{64}$/;
let _cache = null, _cacheKey = '', _checkedAt = 0;

function _file() {
  const dir = process.env.SOV_DATA_DIR || path.join(os.homedir(), '.sov-node');
  return path.join(dir, 'trusted_nodes.json');
}

function _clean(list) {
  return new Set((list || []).map(x => String(x).trim().toLowerCase()).filter(x => ID_RE.test(x)));
}

/** The trusted set and where it came from. */
function list() {
  const env = process.env.SOV_TRUSTED_NODES;
  if (env && env.trim()) {
    if (_cacheKey !== 'env:' + env) { _cache = _clean(env.split(',')); _cacheKey = 'env:' + env; }
    return { ids: _cache, source: 'env' };
  }
  const now = Date.now();
  if (_cache && _cacheKey.startsWith('file:') && now - _checkedAt < 2 * 1000) return { ids: _cache, source: 'file' };
  if (_cache && _cacheKey === 'default' && now - _checkedAt < 2 * 1000) return { ids: _cache, source: 'default' };
  _checkedAt = now;
  try {
    const f = _file();
    const st = fs.statSync(f);
    const key = `file:${st.mtimeMs}:${st.size}`;
    if (_cacheKey !== key) {
      const arr = JSON.parse(fs.readFileSync(f, 'utf8'));
      if (!Array.isArray(arr)) throw new Error('not an array');
      _cache = _clean(arr); _cacheKey = key;
    }
    return { ids: _cache, source: 'file' };
  } catch (e) {
    if (e && e.code !== 'ENOENT' && global.sovLog) global.sovLog.warn(`[Trust] ${_file()} unreadable (${e.message}) — using the built-in list`);
  }
  if (_cacheKey !== 'default') { _cache = _clean(DEFAULT_TRUSTED); _cacheKey = 'default'; }
  return { ids: _cache, source: 'default' };
}

let _selfId = null;
function setSelf(nodeId) { _selfId = nodeId ? String(nodeId).toLowerCase() : null; }

/** Is this authenticated node id trusted with unsigned state? */
function isTrusted(nodeId) {
  if (!nodeId) return false;
  const id = String(nodeId).toLowerCase();
  if (_selfId && id === _selfId) return true;
  return list().ids.has(id);
}

// One warning per peer per message type per hour, so a refusing node does not flood its log.
const _warned = new Map();
function refuse(what, nodeId) {
  const k = `${what}|${nodeId}`;
  const now = Date.now();
  if ((_warned.get(k) || 0) > now - 60 * 60 * 1000) return;
  _warned.set(k, now);
  if (_warned.size > 5000) _warned.clear();
  if (global.sovLog) global.sovLog.warn(`[Trust] ${what} from ${String(nodeId || '?').slice(0, 12)} ignored — not a trusted node (unsigned state is taken only from trusted nodes)`);
}

/** Reset caches (tests). */
function _reset() { _cache = null; _cacheKey = ''; _checkedAt = 0; _warned.clear(); }

module.exports = { DEFAULT_TRUSTED, list, isTrusted, setSelf, refuse, _reset };
