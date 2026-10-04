'use strict';
/**
 * Threshold release signing (PI-37) — the FROST layer `release_signer.js` already
 * documents as the production replacement for a founder-held keystore.
 *
 * What this gives the network that a founder keystore cannot: the release-signing
 * private key is never assembled in full, anywhere, by anyone — not by a single
 * witness signer, not by any subset below `threshold`, and not by all signers
 * colluding after the fact. It is generated once via a distributed key-generation
 * (DKG) ceremony (RFC 9591 FROST-Ed25519, via @noble/curves — audited, widely used,
 * zero-dependency), after which each signer holds only a share. Producing a
 * signature requires `threshold` signers to run an interactive two-round protocol
 * that outputs one Ed25519 signature — standard, RFC 8032-compliant, verifiable by
 * ordinary Ed25519 verification. No new verification code is needed anywhere in the
 * network: `release_signer.js:verifyManifest()` already checks exactly this shape.
 *
 * This module owns the DKG ceremony and the two-round signing session. It does not
 * decide WHO the signers are (that is `witness_engine.js`'s election) or wire the
 * peer-mesh transport that carries these messages between nodes (not yet built —
 * see the module-level TODO at the bottom). It is deliberately transport-agnostic:
 * every function here takes and returns plain, JSON-serialisable objects so it can
 * be driven by a test in a single process today and by real peer-mesh messages
 * later, without changing this file.
 */
const { ed25519_FROST: F } = require('@noble/curves/ed25519.js');

/**
 * Round 1 of DKG: this signer generates its own secret polynomial and a public
 * commitment + proof of knowledge. The commitment is safe to broadcast; `secret`
 * (specifically `secret.coefficients`) must never leave this signer's process.
 */
function dkgRound1(signerId, threshold, count, rng) {
  const { public: pub, secret } = F.DKG.round1(signerId, { min: threshold, max: count }, undefined, rng);
  return { public: pub, secret };
}

/**
 * Round 2 of DKG: given every OTHER signer's round-1 public package, compute one
 * share per other signer. In production each `res[otherId]` is sent ONLY to
 * `otherId`, over an authenticated channel — never broadcast, unlike round 1.
 */
function dkgRound2(round1Secret, othersRound1Public) {
  return F.DKG.round2(round1Secret, othersRound1Public);
}

/**
 * Round 3 of DKG: combine this signer's own contribution with the round-2 shares
 * addressed to it (one from each other signer) into its final, permanent signing
 * share plus the group's public key material. Every signer that completes this
 * step correctly arrives at the identical group public key — verified in
 * `dkg_proof.js`'s CHECK 1 — without ever having seen another signer's full secret.
 */
function dkgRound3(round1Secret, othersRound1Public, round2SharesForMe) {
  const { public: pub, secret } = F.DKG.round3(round1Secret, othersRound1Public, round2SharesForMe);
  return { public: pub, secret };
}

/** The permanent group signing identity — this becomes the release trust anchor. */
function groupPubkeyHex(dkgPublic) {
  return Buffer.from(dkgPublic.commitments[0]).toString('hex');
}

/**
 * Threshold-sign `msgBytes` (the same `canonicalBytes(manifest)` release_signer.js
 * already computes) using exactly `participants.length` signers, which MUST be
 * >= threshold. Each entry in `participants` is one signer's `{secret, public}`
 * from `dkgRound3`. Returns a plain Ed25519 signature — no FROST-specific object,
 * no new verification code required anywhere downstream.
 *
 * This function runs the full two-round signing protocol in-process for clarity;
 * in production round 1 (commit) happens on each signer's own machine and only the
 * public commitments cross the wire before round 2 (signShare) runs.
 */
function thresholdSign(participants, msgBytes, rng) {
  const commits = participants.map((p) => ({ p, c: F.commit(p.secret, rng) }));
  const commitmentList = commits.map(({ c }) => c.commitments);
  const sigShares = {};
  for (const { p, c } of commits) {
    sigShares[p.secret.identifier] = F.signShare(p.secret, p.public, c.nonces, commitmentList, msgBytes);
  }
  const sig = F.aggregate(participants[0].public, commitmentList, msgBytes, sigShares);
  return Buffer.from(sig);
}

/** Verify with the FROST library's own check — used in tests; production code
 * should prefer release_signer.js's verifyManifest(), which is plain Node
 * crypto.verify() and needs no FROST import at all. */
function verify(sig, msgBytes, groupPub) {
  return F.verify(sig, msgBytes, groupPub.commitments[0]);
}

/** Derive a stable signer identifier from any string (e.g. a Sovereign ID). */
function deriveIdentifier(s) {
  return F.Identifier.derive(s);
}

module.exports = { dkgRound1, dkgRound2, dkgRound3, groupPubkeyHex, thresholdSign, verify, deriveIdentifier };

/*
 * NOT YET BUILT — the remaining gap between this proof and production:
 *
 * 1. Peer-mesh transport for the three DKG rounds and the two signing rounds
 *    (this module is transport-agnostic by design; the wiring is not written).
 * 2. `witness_engine.js` currently seats signers with an INDEPENDENT keypair each
 *    (multisig-of-N, for the release MANIFEST). Running DKG instead at election
 *    time — so the committee shares ONE group key rather than N separate keys —
 *    is a design change to that election flow, not just an addition alongside it.
 * 3. Re-election handling: today's witness committee replaces its whole signer
 *    set at every election (witness_engine.js:242). A DKG-based group key would
 *    need a resharing/re-DKG step at re-election that preserves the SAME group
 *    public key (Android needs one stable signing identity for the app's whole
 *    life) while rotating who holds shares of it — proactive secret sharing, a
 *    harder protocol than the initial DKG proven here.
 * 4. Injecting a FROST-produced signature into the actual Android APK Signing
 *    Block (v2/v3) is a SEPARATE problem from release-manifest signing (proven
 *    working here) and has not been attempted. `apksigner` assumes a local
 *    keystore file; producing the same on-disk signing block from an externally
 *    computed signature needs its own investigation before this can replace the
 *    `sov` Android code-signing key (gap 1), as opposed to the release manifest
 *    trust anchor (which release_signer.js already fully supports today).
 * 5. Cryptographic review. This wraps an audited primitive (@noble/curves,
 *    RFC 9591) rather than implementing threshold math by hand — but the
 *    orchestration above (which bytes get sent to whom, when) is new code and
 *    should get a second pair of eyes before any real key material is ever
 *    generated with it.
 */
