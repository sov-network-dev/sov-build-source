// palm_cancelable.js — cancelable-biometric protection for palm dedup.
//
// Closes the Tier-4 gap while honoring SOV's law (full replication on every node,
// light-speed sync, no single point of failure, no chain bloat):
//
//   stored = R · normalize(embedding)        (R = secret orthogonal 128x128 matrix)
//
// • SAME SIZE as the raw embedding (~0.5 KB) -> replicates to every node + syncs
//   like sov_disc; no Bitcoin-style bloat.
// • Cosine is INVARIANT under an orthogonal R:  cos(R·a, R·b) = cos(a, b).
//   So the 1:N duplicate check is identical (same 0.92 threshold) and works on ANY
//   node -> supports client node-rotation, no single point of authority.
// • R is derived from a NETWORK secret seed held as a witness-signer THRESHOLD key
//   (no single node can invert) and is REVOCABLE: rotate the seed -> re-transform ->
//   any stolen set dies.
// • A stolen node DB alone yields scrambled, non-raw unit vectors -> useless without R.
//
// Pure JS (snap-safe, no native build, no external trust).
'use strict';
const crypto = require('crypto');

const DIM = 128;

function _seededGaussians(seed, count) {
  const out = []; let ctr = 0;
  const u = () => {
    const h = crypto.createHash('sha256').update(seed + ':' + (ctr++)).digest();
    return (h.readUInt32BE(0) + 0.5) / 4294967296; // (0,1)
  };
  while (out.length < count) {                       // Box-Muller -> N(0,1)
    const u1 = u(), u2 = u();
    const r = Math.sqrt(-2 * Math.log(u1 || 1e-12));
    out.push(r * Math.cos(2 * Math.PI * u2));
    out.push(r * Math.sin(2 * Math.PI * u2));
  }
  return out.slice(0, count);
}

// Deterministic orthogonal matrix from a secret seed (same seed -> same R on every
// node). Gram-Schmidt on a seeded random matrix => orthonormal rows.
function generateR(seed, dim = DIM) {
  const rows = [];
  for (let i = 0; i < dim; i++) rows.push(_seededGaussians(seed + ':r' + i, dim));
  const Q = [];
  for (let i = 0; i < dim; i++) {
    const v = rows[i].slice();
    for (let j = 0; j < i; j++) {
      const q = Q[j]; let d = 0;
      for (let k = 0; k < dim; k++) d += v[k] * q[k];
      for (let k = 0; k < dim; k++) v[k] -= d * q[k];
    }
    let n = 0; for (let k = 0; k < dim; k++) n += v[k] * v[k]; n = Math.sqrt(n) || 1;
    Q.push(v.map(x => x / n));
  }
  return Q;
}

function _normalize(vec) {
  let n = 0; for (const x of vec) n += x * x; n = Math.sqrt(n) || 1;
  return vec.map(x => x / n);
}

// Protect an embedding for storage: R · normalize(embedding). Output is a unit
// vector the same length as the input (orthogonal R preserves the norm).
function transform(R, vec) {
  const u = _normalize(vec), dim = R.length, out = new Array(dim);
  for (let i = 0; i < dim; i++) { let s = 0; const Ri = R[i]; for (let k = 0; k < dim; k++) s += Ri[k] * u[k]; out[i] = s; }
  return out;
}

// Cosine between two ALREADY-transformed (unit) vectors == cosine of the originals.
function cosine(a, b) { let s = 0; for (let i = 0; i < a.length; i++) s += a[i] * b[i]; return s; }

// One-human-one-wallet check against stored transformed templates. The new
// embedding is transformed with the same R, then compared. Identical decision to
// the old plaintext cosine.
function isDuplicate(newVec, R, storedTransformedList, threshold = 0.92) {
  const t = transform(R, newVec);
  let maxSim = -1;
  for (const stored of storedTransformedList) {
    const s = cosine(t, stored);
    if (s > maxSim) maxSim = s;
    if (maxSim > threshold) break;
  }
  return { duplicate: maxSim > threshold, maxSim };
}

// ── Network R singleton ──────────────────────────────────────────────────────
// Same R on every node (so transformed templates are comparable mesh-wide). The
// seed is the network secret — in production a witness-signer THRESHOLD secret;
// here it comes from PALM_CANCELABLE_SEED. R is cached (Gram-Schmidt runs once).
let _cachedR = null, _cachedSeed = null;
function getR() {
  // network-seed-join-v1: the seed now comes from the shared resolver, which
  // prefers an explicit env override, then the seed minted at genesis or handed
  // over when this node was approved, and only then the legacy constant.
  const seed = require('./network_seed').load();
  if (_cachedR && _cachedSeed === seed) return _cachedR;
  _cachedR = generateR(seed); _cachedSeed = seed;
  return _cachedR;
}

// Transform a 128-float embedding (array or JSON string) for storage; returns a
// JSON string of the protected unit vector (6-dp). Invalid input passes through.
function protectForStorage(embedding) {
  try {
    const v = typeof embedding === 'string' ? JSON.parse(embedding) : embedding;
    if (!Array.isArray(v) || v.length !== DIM) return typeof embedding === 'string' ? embedding : JSON.stringify(embedding);
    return JSON.stringify(transform(getR(), v).map(x => Math.round(x * 1e6) / 1e6));
  } catch (_) {
    return typeof embedding === 'string' ? embedding : JSON.stringify(embedding);
  }
}

// ── cancelable-key fingerprint ───────────────────────────────────────────────
// A short digest of the seed, safe to put on the wire so peers can tell whether
// they share a key WITHOUT either of them revealing it. The seed is 256-bit
// random, so this digest gives an observer nothing.
//
// This exists because a key mismatch is otherwise SILENT: stored templates
// replicate between nodes, but each node transforms its own duplicate-check
// query with its own key, so a mismatched node compares two different spaces,
// finds no match for anybody, and lets the same human enrol twice.
function fingerprint() {
  const seed = require('./network_seed').load();
  return require('crypto')
    .createHash('sha256')
    .update('sov-cancelable-fp-v1|' + seed)
    .digest('hex')
    .slice(0, 16);
}

module.exports = { DIM, generateR, transform, cosine, isDuplicate, getR, protectForStorage, fingerprint };
