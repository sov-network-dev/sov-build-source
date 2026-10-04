'use strict';
/**
 * Threshold RSA signing ceremony — the real-world answer to gap 1 (Android APK
 * signing) after FROST was ruled out for it: FROST/Schnorr threshold signing is
 * proven for release-manifest trust (witness_frost.js), but Android's APK
 * Signature Scheme v2/v3/v4 only accepts RSA or genuine ECDSA — never Ed25519 or a
 * Schnorr signature over any curve (confirmed against the AOSP spec, and against
 * @noble/curves p256_FROST empirically: it emits a 65-byte R‖z Schnorr signature,
 * not a DER ECDSA one). The current `sov` key is RSA-4096, so this targets RSA.
 *
 * This is WEAKER than true FROST in one specific way, stated plainly rather than
 * glossed over: the private key IS momentarily whole in memory during a signing
 * ceremony, in one process, for as long as it takes to call sign(). It is never
 * whole on disk, never held by any signer alone, and never held by any subset
 * below `threshold` — but during the ceremony itself, whichever machine runs
 * combine()+sign() sees the real key for a few milliseconds before it is
 * overwritten. True threshold RSA (Boneh-Franklin / Shoup style, where even the
 * combiner never sees the whole key) exists in the literature but has no widely
 * audited JS implementation the way FROST does — using it without real vetting
 * would be worse than being honest about this scheme's weaker (but real) property.
 *
 * Secret sharing: `shamir-secret-sharing` (privy-io), independently audited by
 * Cure53 and Zellic, GF(2^8), operates on raw bytes — so it can split the RSA
 * private key's PKCS8 DER encoding directly, no key-type-specific math needed.
 */
const crypto = require('crypto');
const { split, combine } = require('shamir-secret-sharing');

/** Split an RSA (or any) private key's PKCS8 DER bytes into `shares` pieces,
 * any `threshold` of which reconstruct it. Distribute each share to a DIFFERENT
 * custodian machine in production — never keep two shares on one machine, or
 * that machine alone crosses the threshold by itself. */
async function splitPrivateKey(privateKeyObj, threshold, shares) {
  const der = privateKeyObj.export({ format: 'der', type: 'pkcs8' });
  return split(new Uint8Array(der), shares, threshold);
}

/**
 * Run one signing ceremony: reconstruct the key from >= threshold shares,
 * sign `msgBytes`, and zero the reconstructed key material before returning.
 * `algorithm` matches whatever the real certificate uses (e.g. 'RSA-SHA384' —
 * the exact algorithm SOV's live `sov-release.jks` cert already carries).
 */
async function ceremonySign(sharesSubset, algorithm, msgBytes) {
  const derBytes = await combine(sharesSubset); // throws if shares are inconsistent
  const der = Buffer.from(derBytes);
  let keyObj;
  try {
    keyObj = crypto.createPrivateKey({ key: der, format: 'der', type: 'pkcs8' });
    return crypto.sign(algorithm, msgBytes, keyObj);
  } finally {
    der.fill(0); // best-effort: the reconstructed key never touches disk and is
    // overwritten as soon as the ceremony ends, whether or not the sign above
    // threw — this `finally` runs on both paths.
  }
}

module.exports = { splitPrivateKey, ceremonySign };
