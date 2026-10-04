'use strict';
/**
 * Distribution-Manifest signer + verifier (king's model: no founder; the network's
 * own signers attest releases, clients verify before self-updating).
 *
 * Production signing = witness-signer FROST THRESHOLD (PI-37): N elected signers,
 * >= threshold must co-sign; no single key can ship. This module implements the
 * MULTI-SIGNATURE envelope + threshold verification that the FROST signers drop
 * into. The interim/dev signer below uses plain Ed25519 (Node built-in crypto, same
 * primitive the wallet uses) so the pipeline is testable today; swapping in the
 * FROST aggregate signature changes only how each `sigs[]` entry is produced — the
 * envelope + `verifyManifest` threshold check are unchanged.
 *
 * Canonical bytes signed = JSON of the manifest with its `sigs` field removed, keys
 * in insertion order (stable because we build it ourselves). Each signer signs the
 * SAME canonical bytes; verification recomputes them and counts valid signatures.
 */
const crypto = require('crypto');

const PKCS8_SEED_PREFIX = Buffer.from('302e020100300506032b657004220420', 'hex');
function _privFromSeed(seedHex) {
  return crypto.createPrivateKey({ key: Buffer.concat([PKCS8_SEED_PREFIX, Buffer.from(seedHex, 'hex')]), format: 'der', type: 'pkcs8' });
}
function _pubFromSeed(seedHex) {
  const der = crypto.createPublicKey(_privFromSeed(seedHex)).export({ format: 'der', type: 'spki' });
  return der.slice(der.length - 32).toString('hex');
}
const SPKI_PUB_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');
function _pubKeyObj(pubHex) {
  return crypto.createPublicKey({ key: Buffer.concat([SPKI_PUB_PREFIX, Buffer.from(pubHex, 'hex')]), format: 'der', type: 'spki' });
}

// Canonical bytes = manifest minus `sigs`, stable JSON.
function canonicalBytes(manifest) {
  const { sigs, ...rest } = manifest;   // exclude signatures from what is signed
  return Buffer.from(JSON.stringify(rest), 'utf8');
}

/**
 * Add one Ed25519 signature from a release/witness signer (by 32-byte seed hex).
 * Idempotent per signer pubkey. Returns the manifest with the signature appended.
 */
function addSignature(manifest, signerSeedHex) {
  const pub = _pubFromSeed(signerSeedHex);
  const sig = crypto.sign(null, canonicalBytes(manifest), _privFromSeed(signerSeedHex)).toString('hex');
  const sigs = (manifest.sigs || []).filter((s) => s.signer !== pub);
  sigs.push({ alg: 'ed25519', signer: pub, signature: sig });
  return { ...manifest, sigs };
}

/**
 * Add one signature already produced by a threshold ceremony (witness_frost.js) —
 * a single Ed25519 signature over `canonicalBytes(manifest)` that `threshold`
 * signers cooperated to produce, under a group public key no one of them holds
 * alone. Structurally identical to a plain `addSignature()` entry on purpose:
 * this is the "only how each sigs[] entry is produced" change the module
 * docstring describes — `verifyManifest` below needs no changes to check it.
 */
function addThresholdSignature(manifest, groupPubkeyHex, signatureBuf) {
  const pub = groupPubkeyHex.toLowerCase();
  const sigs = (manifest.sigs || []).filter((s) => s.signer !== pub);
  sigs.push({ alg: 'ed25519', signer: pub, signature: Buffer.from(signatureBuf).toString('hex') });
  return { ...manifest, sigs };
}

/**
 * Verify a signed manifest: count valid signatures from `trustedPubkeys` and
 * require >= `threshold`. This is the check every client runs before self-updating.
 * @returns {{ok:boolean, valid:number, threshold:number, signers:string[]}}
 */
function verifyManifest(manifest, trustedPubkeys, threshold = 1) {
  const trusted = new Set((trustedPubkeys || []).map((k) => k.toLowerCase()));
  const bytes = canonicalBytes(manifest);
  const goodSigners = [];
  for (const s of (manifest.sigs || [])) {
    if (s.alg !== 'ed25519') continue;
    if (!trusted.has((s.signer || '').toLowerCase())) continue;
    try {
      if (crypto.verify(null, bytes, _pubKeyObj(s.signer), Buffer.from(s.signature, 'hex'))) {
        if (!goodSigners.includes(s.signer)) goodSigners.push(s.signer);
      }
    } catch (_) { /* bad sig → skip */ }
  }
  return { ok: goodSigners.length >= threshold, valid: goodSigners.length, threshold, signers: goodSigners };
}

module.exports = { addSignature, addThresholdSignature, verifyManifest, canonicalBytes, _pubFromSeed };
