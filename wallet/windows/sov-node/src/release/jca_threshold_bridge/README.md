# JCA threshold-signing bridge for Android APK signing (gap 1)

**Status: mechanism proven end-to-end against the real, unmodified `apksigner` tool.
Not yet wired to real key material or a real multi-machine ceremony.**

## What this closes

`witness_frost.js` (../protocol/witness_frost.js) proved threshold signing works
for the release-manifest trust layer, using FROST-Ed25519. It cannot become the
Android APK signing certificate: Android's APK Signature Scheme v2/v3/v4 only
accepts RSA or genuine ECDSA, never Ed25519, and FROST run over P-256 produces a
Schnorr signature (verified empirically: 65-byte raw `R‖z`), which is a different
signature equation than ECDSA and is rejected by Android's verifier regardless of
curve. The current `sov` release key is RSA-4096, so this targets RSA.

There is no widely-audited JS library for genuine threshold RSA (unlike FROST for
Schnorr, which `@noble/curves` implements to RFC 9591). Rather than hand-implement
unaudited threshold-RSA math, this uses **Shamir-shared RSA** (`threshold_rsa_ceremony.js`,
via `shamir-secret-sharing` — independently audited by Cure53 and Zellic): a
threshold of custodians' shares reconstruct the RSA private key for the duration
of one signing ceremony, then it is discarded. This is honestly weaker than true
FROST in one way — the key IS momentarily whole in the process that runs the
ceremony — but it is real, auditable, and buildable today.

## What was actually proven (2026-08-29)

1. A fresh throwaway RSA-4096 key (never the real `sov-release.jks` key — that was
   never read or touched by this work) was split 3-of-5 via Shamir, then the whole
   key was deleted, leaving only 5 share files.
2. A custom `java.security.Provider` (`SovBridgeProvider` + `SovKeyStoreSpi` +
   `SovRsaSignature`) was registered with real, unmodified `apksigner`, using the
   documented external/HSM-provider pattern (`--provider-class`, `--ks-type` — the
   same mechanism real PKCS#11/cloud-KMS integrations use with apksigner).
3. `apksigner sign` called our provider's `Signature.SHA384withRSA` /
   `SHA512withRSA` engines. Each call shells out to `ceremony_sign_cli.js`, which
   reconstructs the key from 3 of the 5 share files, signs, and destroys the
   reconstructed key — all inside one `engineSign()` call.
4. Real, unmodified `apksigner verify --print-certs` on the result:
   ```
   Verified using v2 scheme (APK Signature Scheme v2): true
   Verified using v3 scheme (APK Signature Scheme v3): true
   ```
   This is the actual Android verification path — not a reimplementation of it.

## Network-distributed ceremony (2026-08-29 update) — also proven

The single-process proof above has been extended: `share_holder_service.js` (one
per custodian, holds ONE share, serves it only to an authenticated coordinator)
+ `ceremony_coordinator.js` (fetches `threshold` shares over HTTP instead of
reading local files). Ran 5 of these as genuinely separate OS processes on
different ports (a stand-in for different machines), pointed the Java bridge at
the coordinator via `-Dsov.holdersConfig=<path>` instead of `-Dsov.sharesDir=<path>`
(the Java side picks the mode based on which system property is set — see
`SovRsaSignature.engineSign()`), and re-ran the full apksigner sign+verify proof:
**same result, `v2: true` / `v3: true`**, with only 3 of the 5 holder processes
ever contacted (confirmed in their logs) and the auth guard verified to actually
refuse an unauthenticated or wrong-token request (403).

This proves shares can live on genuinely separate processes with none of them
holding more than one share at rest. It does NOT change the one property that
was already disclosed as weaker-than-true-FROST: the coordinator process still
reconstructs the whole key briefly, in memory, once per signing.

## What is NOT yet proven / built

- **Real machines, real auth.** The "network-distributed" proof above still ran
  on one physical machine (separate processes, same box) with a bearer-token
  stand-in for auth. Real deployment needs actual separate hardware and mutual
  TLS — both explicitly flagged as not-yet-done in `share_holder_service.js`'s
  own header comment.
- **Trusted-dealer split, not distributed keygen.** The RSA key was generated
  whole, then split. A real deployment should treat that generation+split step as
  its own carefully-witnessed ceremony (ideally on an air-gapped machine, key
  material wiped immediately after splitting) rather than pretend it is
  equivalent to genuine multi-party keygen, which it is not.
- **No integration with `witness_engine.js`'s election.** Nothing decides who
  holds the 5 shares or how they rotate.
- **New code, not yet reviewed.** `SovKeyStoreSpi`/`SovRsaSignature` are ~150
  lines of new JCA plumbing. Low risk (they never see real key material, only an
  opaque handle), but a second pair of eyes before this touches the real
  `sov-release.jks` identity is worth it precisely because it's signing
  infrastructure.

## Reproducing the proof

Requires: JDK 17+ (`javac`/`java`), Android SDK build-tools (`apksigner`), Node
with this package's `node_modules` installed.

```
javac -d classes java/com/sov/frostbridge/*.java

# generate a THROWAWAY test key/cert, split it, delete the whole key —
# see the session notes for the exact keytool/openssl/do_split.js sequence;
# never do this against sov-release.jks without a deliberate, witnessed ceremony

java -Dsov.alias=<alias> -Dsov.cert=<cert.pem> -Dsov.sharesDir=<shares/> \
     -Dsov.nodeExe=<node.exe> -Dsov.signScript=ceremony_sign_cli.js -Dsov.threshold=3 \
     -cp "<apksigner.jar>;classes" com.android.apksigner.ApkSignerTool sign \
     --provider-class com.sov.frostbridge.SovBridgeProvider --provider-pos 1 \
     --ks NONE --ks-type SOVBRIDGE --ks-key-alias <alias> --ks-pass pass:x --key-pass pass:x \
     --v1-signing-enabled false --v2-signing-enabled true --v3-signing-enabled true \
     --out signed.apk unsigned.apk

apksigner verify --print-certs signed.apk
```

### Network-distributed mode (5 separate processes instead of local files)

```
# one holders.json listing each share-holder's URL + bearer token, e.g.:
# [{"id":"holder-0","url":"http://127.0.0.1:4001/share","token":"tok0"}, ...]

# start one share_holder_service.js PER SHARE, each on its own port —
# in production each of these runs on a different custodian's machine:
node share_holder_service.js --port 4001 --shareFile shares/share_0.bin --token tok0 --holderId holder-0 &
node share_holder_service.js --port 4002 --shareFile shares/share_1.bin --token tok1 --holderId holder-1 &
node share_holder_service.js --port 4003 --shareFile shares/share_2.bin --token tok2 --holderId holder-2 &

# same apksigner invocation as above, but swap sov.sharesDir for sov.holdersConfig
# and point sov.signScript at ceremony_coordinator.js instead of ceremony_sign_cli.js:
java -Dsov.alias=<alias> -Dsov.cert=<cert.pem> \
     -Dsov.holdersConfig=holders.json \
     -Dsov.nodeExe=<node.exe> -Dsov.signScript=ceremony_coordinator.js -Dsov.threshold=3 \
     -cp "<apksigner.jar>;classes" com.android.apksigner.ApkSignerTool sign \
     --provider-class com.sov.frostbridge.SovBridgeProvider --provider-pos 1 \
     --ks NONE --ks-type SOVBRIDGE --ks-key-alias <alias> --ks-pass pass:x --key-pass pass:x \
     --v1-signing-enabled false --v2-signing-enabled true --v3-signing-enabled true \
     --out signed.apk unsigned.apk

apksigner verify --print-certs signed.apk   # same result: v2 true, v3 true
```
