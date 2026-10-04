// face_cancelable.js — cancelable-biometric protection for FACE-LOCK dedup.
//
// Same security model as palm_cancelable.js (stored = R·normalize(embedding);
// orthogonal R preserves cosine; network-shared seed; revocable) but with:
//   • DIM = 192 (MobileFaceNet embedding)
//   • its OWN R, derived from the network seed + ':face-v1' — so a compromise
//     of one biometric's R never touches the other's templates
//   • STRICT storage: malformed input returns null (never store raw), unlike
//     palm's legacy raw-passthrough.
//
// Why faces at all: palm dedup cannot link a person's LEFT palm to their RIGHT
// palm — with dual-palm permanent, one human could enroll twice. The liveness
// step already captures the face; the face embedding is the cross-hand anchor
// that keeps ONE HUMAN = ONE IDENTITY true. Pure JS (snap-safe).
'use strict';

const palm = require('./palm_cancelable');

const DIM = 192;

let _cachedR = null, _cachedSeed = null;

// Network-shared face R. Seed extends the palm network seed with a fixed
// face-domain tag; rotating PALM_CANCELABLE_SEED rotates BOTH template sets.
function getR() {
  const seed = require('./network_seed').load() + ':face-v1';
  if (_cachedR && _cachedSeed === seed) return _cachedR;
  _cachedR = palm.generateR(seed, DIM);
  _cachedSeed = seed;
  return _cachedR;
}

// Transform a 192-float embedding (array or JSON string) for storage; returns a
// JSON string of the protected unit vector (6-dp), or null if input is invalid.
function protectForStorage(embedding) {
  try {
    const v = typeof embedding === 'string' ? JSON.parse(embedding) : embedding;
    if (!Array.isArray(v) || v.length !== DIM) return null;
    return JSON.stringify(palm.transform(getR(), v).map(x => Math.round(x * 1e6) / 1e6));
  } catch (_) {
    return null;
  }
}

module.exports = {
  DIM,
  getR,
  protectForStorage,
  transform: palm.transform,   // dimension comes from R (192 here)
  cosine:    palm.cosine,
};
