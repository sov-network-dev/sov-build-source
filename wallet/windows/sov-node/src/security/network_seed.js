// network_seed.js
// ─────────────────────────────────────────────────────────────────────────────
// The network's cancelable-biometric seed — obtained by JOINING, not by hand.
//
// THE RULE THIS RESTORES
//   Everything a node needs is born with it: install the software, get
//   interrogated, join, receive the ledger. Putting the seed in a per-node .env
//   made it the one thing a node was NOT born with, and there was no mechanism
//   to give it to a new operator — absent from the setup script and the env
//   template, never sent over the mesh. A fresh node therefore fell back to the
//   old hardcoded constant, ended up on a different key from the network, and
//   silently failed every duplicate check (each node transforms its own query
//   with its own key, so mismatched keys compare two different spaces and find
//   no match for anybody).
//
//   Now: the genesis node GENERATES it, having nobody to receive from — exactly
//   as it already self-registers as bootstrap when it finds no peers. Every node
//   after it RECEIVES it in the approval that admits it to the network, over the
//   already-authenticated channel that hands it the ledger. Same trust boundary:
//   an approved node already receives every citizen's template, so the key that
//   makes those templates comparable grants it nothing it did not already have.
//
// PRECEDENCE (deliberate)
//   1. PALM_CANCELABLE_SEED in the environment — an explicit operator override.
//      Kept first so nodes already carrying the seed in .env are untouched.
//   2. The seed file written by genesis or by join.
//   3. The legacy constant — only reached by a node that is neither, which is
//      now a state that should not occur and is logged when it does.
//
// WHAT THIS IS NOT
//   It is not a threshold key. The seed still exists in full on every approved
//   node, so an operator can still unscramble templates. Splitting it so no
//   single node holds it is PI-37 and remains open. This change fixes
//   DISTRIBUTION, not the shared-secret property itself.
// ─────────────────────────────────────────────────────────────────────────────
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');

const LEGACY_DEFAULT = 'sov-network-cancelable-seed-v1';
const FILENAME = 'network-cancelable-seed';

let _cached = null;

/** Same resolution the DB encryption key uses — snap-managed location first. */
function _seedPath() {
  const snapCommon = process.env.SNAP_COMMON;
  if (snapCommon) return path.join(snapCommon, FILENAME);
  const dataDir = process.env.SOV_DATA_DIR || path.join(os.homedir(), '.sov-node');
  return path.join(dataDir, FILENAME);
}

function _readFile() {
  try {
    const p = _seedPath();
    if (!fs.existsSync(p)) return '';
    const v = fs.readFileSync(p, 'utf8').trim();
    return v.length >= 32 ? v : '';
  } catch (_) {
    return '';
  }
}

function _writeFile(seed) {
  const p = _seedPath();
  fs.mkdirSync(path.dirname(p), { recursive: true });
  // 0600 before anything is written — the DB encryption key beside it is 0600,
  // and a secret that unscrambles biometric templates has no business being
  // more readable than the key protecting the ledger.
  fs.writeFileSync(p, seed, { mode: 0o600 });
  try { fs.chmodSync(p, 0o600); } catch (_) {}
  _cached = null;
  return p;
}

/** The seed this node should use. Never throws. */
function load() {
  if (_cached) return _cached;
  const fromEnv = (process.env.PALM_CANCELABLE_SEED || '').trim();
  if (fromEnv) { _cached = fromEnv; return _cached; }
  const fromFile = _readFile();
  if (fromFile) { _cached = fromFile; return _cached; }
  return LEGACY_DEFAULT;   // not cached — so it picks up a seed the moment one arrives
}

/** True when this node holds a real network seed rather than the legacy constant. */
function has() {
  return load() !== LEGACY_DEFAULT;
}

/** Genesis only: mint the network's seed. Refuses if one already exists. */
function generate() {
  if (has()) return { created: false, reason: 'ALREADY_HAVE_SEED' };
  const seed = crypto.randomBytes(32).toString('hex');
  const p = _writeFile(seed);
  return { created: true, path: p };
}

/**
 * Accept a seed handed over during an approved join.
 *
 * REFUSES to overwrite a seed this node already has. That is the important part:
 * without it, anything able to send an approval message could replace a node's
 * key and orphan every template it holds.
 */
function receive(seed) {
  if (typeof seed !== 'string') return { stored: false, reason: 'NOT_A_STRING' };
  const clean = seed.trim();
  if (clean.length < 32 || clean.length > 512) return { stored: false, reason: 'BAD_LENGTH' };
  if (clean === LEGACY_DEFAULT) return { stored: false, reason: 'IS_LEGACY_DEFAULT' };
  if (has()) {
    return { stored: false, reason: load() === clean ? 'ALREADY_MATCHES' : 'REFUSED_WOULD_OVERWRITE' };
  }
  const p = _writeFile(clean);
  return { stored: true, path: p };
}

/** Short digest, safe on the wire — lets peers compare keys without revealing one. */
function fingerprint() {
  return crypto.createHash('sha256')
    .update('sov-cancelable-fp-v1|' + load())
    .digest('hex')
    .slice(0, 16);
}

module.exports = { load, has, generate, receive, fingerprint, LEGACY_DEFAULT, _seedPath };
