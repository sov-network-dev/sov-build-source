#!/usr/bin/env python3
"""
sov-platform-register.py — Official platform registration tool for SOV Login.

Served by every relay node at /sdk/sov-platform-register.py. Per Protocol Book
Chapter 20 + Blueprint Addendum §905: registration is citizen-signed. No admin
key. No corporate office. A real biometrically enrolled SOV citizen signs the
request with their seed phrase and pays the platform_register_fee (default 10
SOV) from their wallet.

Outputs (written to current directory):
  ./platform_x25519_private.key      — keep mode 600, never commit
  ./platform_x25519_public.key       — public, can share
  ./sov_platform_config.json         — platform_id, callback_secret, network_pubkey

Usage:
  python3 sov-platform-register.py

Dependencies (pip install):
  pynacl mnemonic
"""
import sys, os, json, time, hashlib, getpass, urllib.request, urllib.error

try:
    import nacl.signing
    import nacl.public
    import nacl.utils
    from mnemonic import Mnemonic
except ImportError:
    sys.exit("Missing dependencies. Run:  pip install pynacl mnemonic")

def _discover_nodes():
    """Current node addresses, from the published pointer mirrors.

    A fixed list here would be published to every operator who downloads
    this script, and would go stale the moment a node moved. The mirrors
    are plain JSON on independent hosts; whatever they return still has to
    answer for itself.
    """
    import json, urllib.request
    mirrors = [
        "https://raw.githubusercontent.com/sov-network/relay-releases/main/relay_pool.json",
        "https://sov-pointer.sovnetworkdev.workers.dev/relay-pool.json",
    ]
    hosts = []
    for m in mirrors:
        try:
            with urllib.request.urlopen(m, timeout=8) as r:
                j = json.loads(r.read().decode("utf-8"))
        except Exception:
            continue
        for n in (j.get("nodes") or j.get("payload", {}).get("nodes") or []):
            h = str(n.get("address", "")).split(":")[0]
            if h and ("http://" + h) not in hosts:
                hosts.append("http://" + h)
    return hosts

RELAY_POOL = _discover_nodes()


def http_post(url, payload, timeout=15):
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url, data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read().decode("utf-8"))
        except Exception:
            return e.code, {"error": "<unparseable>"}
    except Exception as e:
        return 0, {"error_class": type(e).__name__, "error": str(e)}


def banner(text):
    print()
    print("=" * 70)
    print(f"  {text}")
    print("=" * 70)


def prompt(label, default=None):
    suffix = f" [{default}]" if default else ""
    val = input(f"  {label}{suffix}: ").strip()
    return val or (default or "")


# ─── Welcome ────────────────────────────────────────────────────────────────
banner("SOV PLATFORM REGISTRATION")
print("""
This tool registers a new platform on the SOV Network so it can offer
"Sign in with SOV" to its users.

You will need:
  • Your platform's domain                  (e.g. example.com)
  • A return URL that will receive callbacks (e.g. https://example.com/sov-callback)
  • The 12-word seed phrase of an enrolled SOV citizen with at least 10 SOV
    available in their wallet (this citizen sponsors and pays the one-time
    registration fee — currently 10 SOV, governed by citizen vote)

No GitHub, no API key, no third party. Registration goes directly to the
SOV relay network.
""")

# ─── Collect inputs ─────────────────────────────────────────────────────────
banner("STEP 1 — Platform details")
domain     = prompt("Platform domain (e.g. example.com)")
return_url = prompt("Callback URL (where the relay POSTs SOV_LINK_CREATED)")
if not domain or not return_url:
    sys.exit("ERROR: domain and return_url are required.")
if not return_url.startswith(("http://", "https://")):
    sys.exit("ERROR: return_url must start with http:// or https://")

banner("STEP 2 — Citizen sponsor seed phrase")
print("""
Paste the 12-word seed phrase of the citizen sponsoring this registration.
The phrase stays on YOUR machine. It is used once to derive the signing key,
then discarded. It is never sent to the network.
""")
mnemonic_input = getpass.getpass("  12-word mnemonic (hidden): ").strip()
words = mnemonic_input.split()
if len(words) != 12:
    sys.exit(f"ERROR: expected 12 words, got {len(words)}.")

# Derive Ed25519 signing key from BIP39
m = Mnemonic("english")
try:
    entropy = m.to_entropy(" ".join(words))
except Exception as e:
    sys.exit(f"ERROR: invalid mnemonic — {e}")
seed = hashlib.sha256(entropy).digest()
signing_key = nacl.signing.SigningKey(seed)
master_key_hash = hashlib.sha256(entropy).hexdigest()
sovereign_id = "SOV-" + master_key_hash[:16].upper()
print(f"\n  Citizen sovereign ID derived: {sovereign_id}")

# ─── Generate platform X25519 keypair ──────────────────────────────────────
banner("STEP 3 — Generate platform encryption keys")
platform_priv = nacl.public.PrivateKey.generate()
platform_pub  = platform_priv.public_key
x25519_pubkey_hex = platform_pub.encode().hex()
x25519_privkey_hex = platform_priv.encode().hex()

priv_path = os.path.abspath("./platform_x25519_private.key")
pub_path  = os.path.abspath("./platform_x25519_public.key")
with open(priv_path, "w") as f:
    f.write(x25519_privkey_hex + "\n")
try:
    os.chmod(priv_path, 0o600)
except Exception:
    pass
with open(pub_path, "w") as f:
    f.write(x25519_pubkey_hex + "\n")
print(f"  Private key written:  {priv_path}   (mode 600 — keep safe)")
print(f"  Public  key written:  {pub_path}")

# ─── Sign + send to relay ──────────────────────────────────────────────────
banner("STEP 4 — Sign + register on the SOV network")
timestamp = int(time.time() * 1000)
canonical = (
    f"sov-platform-register-v1|{domain}|{return_url}|"
    f"{sovereign_id}|{x25519_pubkey_hex}|{timestamp}"
)
signature = signing_key.sign(canonical.encode("utf-8")).signature.hex()

payload = {
    "domain":                    domain,
    "return_url":                return_url,
    "registering_sovereign_id":  sovereign_id,
    "x25519_pubkey_hex":         x25519_pubkey_hex,
    "timestamp":                 timestamp,
    "signature":                 signature,
}

resp = None
for relay in RELAY_POOL:
    print(f"  Trying {relay}/sov-platform/register ...")
    code, body = http_post(f"{relay}/sov-platform/register", payload)
    if code == 200 and body.get("success") is True:
        resp = body
        print(f"    HTTP 200  — success")
        break
    err = body.get("error", body.get("error_class", "unknown"))
    print(f"    HTTP {code}  — {err}")

if not resp:
    sys.exit("\nERROR: registration failed on all relay nodes. "
             "Check your citizen has at least 10 SOV available and the domain is not already claimed by a different citizen.")

# Wipe signing key from memory
signing_key = None
seed = None
mnemonic_input = None

# ─── Decrypt sealed callback secret ─────────────────────────────────────────
banner("STEP 5 — Decrypt callback secret")
sealed = json.loads(resp["sealed_callback_secret"])
ephemeral_pub = bytes.fromhex(sealed["ephemeral_pubkey"])
nonce         = bytes.fromhex(sealed["nonce"])
ciphertext    = bytes.fromhex(sealed["ciphertext"])
box = nacl.public.Box(platform_priv, nacl.public.PublicKey(ephemeral_pub))
callback_secret = box.decrypt(ciphertext, nonce).decode("utf-8")
print(f"  callback_secret recovered  ({len(callback_secret)} hex chars)")

# ─── Save config bundle for the platform server ────────────────────────────
banner("STEP 6 — Save platform config")
config = {
    "domain":             domain,
    "return_url":         return_url,
    "platform_id":        resp["platform_id"],
    "sponsoring_citizen": sovereign_id,
    "callback_secret":    callback_secret,
    "network_pubkey_hex": resp["network_pubkey_hex"],
    "canonical_relay_ips": resp.get("canonical_relay_ips", []),
    "x25519_pubkey_hex":  x25519_pubkey_hex,
    "fee_seeds_to_pool": resp.get("fee_seeds_routed_to_operator_pool", 0),  # wire field kept; the fee goes to the operator pool
    "issued_at":          timestamp,
}
cfg_path = os.path.abspath("./sov_platform_config.json")
with open(cfg_path, "w") as f:
    json.dump(config, f, indent=2)
try:
    os.chmod(cfg_path, 0o600)
except Exception:
    pass
print(f"  Config written: {cfg_path}   (mode 600 — keep safe)")

# ─── Final summary ─────────────────────────────────────────────────────────
banner("REGISTRATION COMPLETE")
print(f"""
  Platform domain:    {domain}
  Platform ID:        {resp['platform_id']}
  Sponsored by:       {sovereign_id}
  Fee deducted, credited to operator pool: {resp.get('fee_seeds_routed_to_operator_pool', 0) / 1_000_000} SOV

  Files saved (mode 600 where supported):
    {priv_path}
    {pub_path}
    {cfg_path}

  Next steps:
    1. Install the SOV Login plugin on your server:
       curl -O http://<node-address>/sdk/sov-plugin.php
       (or sov-plugin.js for Node.js)
    2. Point the plugin at sov_platform_config.json
    3. Add a "Sign in with SOV" button to your login page
    4. Enforce the X-Sov-Callback-Hmac header on incoming
       SOV_LINK_CREATED callbacks using the callback_secret

  Full integration guide:
    docs/SOV_LOGIN_INTEGRATION_GUIDE.md   (in the SOV repo)

  Keep platform_x25519_private.key and sov_platform_config.json secret.
  Anyone with these files can impersonate your platform.
""")

