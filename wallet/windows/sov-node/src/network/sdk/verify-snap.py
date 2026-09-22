#!/usr/bin/env python3
"""
verify-snap.py — Verify the sov-relay.snap signature against the founder
genesis public key BEFORE installing the snap. Run this on any clean Linux
machine after fetching the snap + its signature from any SOV relay node.

Usage:
  curl -O http://<node-address>/sov-relay.snap
  curl -O http://<node-address>/sov-relay.snap.sha256
  curl -O http://<node-address>/sov-relay.snap.sig
  python3 verify-snap.py

Exits 0 if the snap is genuine, 1 otherwise. Refuse to install on exit 1.

Trust anchor: the founder public key (Ed25519, hex below) is permanent. It
is also embedded inside the SOV Flutter APK at compile time and republished
in every snap. If you have ANY reason to doubt the key below, fetch a fresh
copy from a relay node you trust:
  curl -s http://<node-address>/relay-pool/latest | jq -r .founder_pubkey_hex
"""
import sys, json, hashlib, os

FOUNDER_PUBKEY_HEX = "8157b39197e3ba8caa3596b45e69940827f5a4e77560284362806c37ceb5956b"
SNAP_PATH = "sov-relay.snap"
SIG_PATH  = "sov-relay.snap.sig"

try:
    import nacl.signing
except ImportError:
    sys.exit("Missing dependency. Run:  pip install pynacl")


def fail(msg):
    print(f"  ✗ {msg}")
    print()
    print("  REFUSE TO INSTALL THIS SNAP. Fetch a fresh copy from a different relay node and try again.")
    sys.exit(1)


def ok(msg):
    print(f"  ✓ {msg}")


print()
print("=" * 70)
print("  SOV-RELAY SNAP — GENUINE-BUILD VERIFICATION")
print("=" * 70)
print()

# Step 1 — Confirm the files exist
for p in (SNAP_PATH, SIG_PATH):
    if not os.path.exists(p):
        fail(f"missing required file: {p}")
ok("required files present")

# Step 2 — Compute the snap's actual SHA256
with open(SNAP_PATH, "rb") as f:
    actual_sha256 = hashlib.sha256(f.read()).hexdigest()
ok(f"computed snap SHA256: {actual_sha256}")

# Step 3 — Load the signature bundle
with open(SIG_PATH, "r") as f:
    sig_bundle = json.load(f)

manifest_str = sig_bundle["manifest"]
signature_hex = sig_bundle["signature_hex"]
served_pubkey_hex = sig_bundle["signer_pubkey_hex"]

# Step 4 — Confirm the pubkey in the signature matches the trust anchor
if served_pubkey_hex.lower() != FOUNDER_PUBKEY_HEX.lower():
    fail(f"served pubkey ({served_pubkey_hex}) does NOT match the founder trust anchor ({FOUNDER_PUBKEY_HEX}). "
         "This relay node is serving a signature from a different signer. Could be: "
         "(a) malicious node trying to substitute a fake key, or (b) genuine founder key rotation (rare — would be announced via governance vote). Do not install.")
ok("served pubkey matches the founder trust anchor")

# Step 5 — Parse the manifest and confirm the signed SHA256 matches the snap we have on disk
manifest = json.loads(manifest_str)
signed_sha = manifest["sha256"].lower()
if signed_sha != actual_sha256.lower():
    fail(f"the signature is for a snap with SHA256 {signed_sha} but the snap on disk has SHA256 {actual_sha256}. "
         "The snap file has been tampered with in transit, or you have a different version than the one signed. Do not install.")
ok(f"signed SHA256 matches snap on disk: {signed_sha}")

# Step 6 — Verify the Ed25519 signature
verify_key = nacl.signing.VerifyKey(bytes.fromhex(FOUNDER_PUBKEY_HEX))
try:
    verify_key.verify(manifest_str.encode("utf-8"), bytes.fromhex(signature_hex))
except Exception as e:
    fail(f"signature verification FAILED — {e}. The signature does not match the manifest under the founder key. Do not install.")
ok("Ed25519 signature is valid under the founder public key")

# Step 7 — Final summary
print()
print("=" * 70)
print(f"  VERIFIED: sov-relay.snap version {manifest.get('version', '?')}")
print(f"  Signed at: {manifest.get('signed_at', '?')}")
print(f"  Signer:    {manifest.get('signer', '?')}")
print(f"  Trust anchor (founder pubkey, last 8): ...{FOUNDER_PUBKEY_HEX[-8:]}")
print("=" * 70)
print()
print("  This snap is genuine.  You may now install it:")
print()
print("    sudo snap install --dangerous --devmode sov-relay.snap")
print()
print("  The --dangerous flag here means 'not from the Snap Store', NOT 'unsafe'.")
print("  You have just cryptographically verified the bundle yourself.")
print()
sys.exit(0)
