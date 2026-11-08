#!/bin/bash
# scenario_discovery.sh — the signed discovery pool can be VERIFIED by an app (node 1.4.92).
# Before 1.4.92 /relay-pool carried a signature but not the signer's key (only its hash), listed every
# gossiped address, and an app could only check its shape. Now: signer_pubkey is published, it hashes
# to signer, the signature verifies over the exact payload, and every listed node is an admitted peer
# with a public key that hashes to its node id. Controls: a tampered payload and a wrong key must fail.
#   wsl -u root -- bash /opt/sov/tools/test_mesh/scenario_discovery.sh
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd); M="bash $D/mesh.sh"; B=/root/sov-mesh
C="ip netns exec sovmesh env NODE_PATH=/root/sov-build/vendor/node_modules /usr/local/bin/node $D/mesh_client.js"
FAIL=0; expect() { if echo "$2" | grep -q -- "$3"; then echo "  PASS  $1"; else echo "  FAIL  $1 — $(echo "$2" | head -c 300)"; FAIL=1; fi; }

$M wipe >/dev/null 2>&1
timeout 150 $M up 1 | tail -1
$C enroll 19401 person-zero --face | grep -o 'SOV-[0-9A-F]*' | head -1 > $B/operator_id
timeout 300 $M up 3 | tail -1
sleep 60

for n in 1 2 3; do
  port=$((19000 + n))
  OUT=$(ip netns exec sovmesh env NODE_PATH=/root/sov-build/vendor/node_modules /usr/local/bin/node -e '
const http = require("http"), crypto = require("crypto"), nacl = require("tweetnacl");
http.get({ host: "127.0.0.1", port: +process.argv[1], path: "/relay-pool", timeout: 10000 }, (res) => {
  let b = ""; res.on("data", d => b += d); res.on("end", () => {
    const r = {}; let e; try { e = JSON.parse(b); } catch (_) { console.log(JSON.stringify({ parse: false })); return; }
    const pub = String(e.signer_pubkey || ""); r.has_pubkey = /^[0-9a-f]{64}$/.test(pub);
    const h = (x) => crypto.createHash("sha256").update(Buffer.from(x, "hex")).digest("hex");
    r.pub_hashes_to_signer = r.has_pubkey && h(pub) === e.signer;
    const body = Buffer.from(e.payload_json || JSON.stringify(e.payload));
    r.has_payload_json = typeof e.payload_json === "string" && JSON.stringify(JSON.parse(e.payload_json)) === JSON.stringify(e.payload);
    const ok = (m, k) => { try { return nacl.sign.detached.verify(new Uint8Array(m), new Uint8Array(Buffer.from(e.sig, "hex")), new Uint8Array(Buffer.from(k, "hex"))); } catch (_) { return false; } };
    r.sig_valid = r.has_pubkey && ok(body, pub);
    const t = JSON.parse(JSON.stringify(e.payload)); t.node_count = (t.node_count || 0) + 1;
    r.tampered_refused = !ok(Buffer.from(JSON.stringify(t)), pub);
    r.wrong_key_refused = !ok(body, "11".repeat(32));
    const nodes = e.payload.nodes || []; r.count = nodes.length;
    r.all_keys_match = nodes.length > 0 && nodes.every(x => /^[0-9a-f]{64}$/.test(x.public_key || "") && h(x.public_key) === x.node_id);
    r.no_self = nodes.every(x => x.node_id !== e.signer);
    console.log(JSON.stringify(r));
  });
}).on("error", (er) => console.log(JSON.stringify({ error: er.code })));' $port)
  expect "node $n: signer_pubkey published"                 "$OUT" '"has_pubkey":true'
  expect "node $n: sha256(signer_pubkey) == signer"          "$OUT" '"pub_hashes_to_signer":true'
  expect "node $n: signature verifies over the payload"      "$OUT" '"sig_valid":true'
  expect "node $n: payload_json is the signed payload"        "$OUT" '"has_payload_json":true'
  expect "node $n: CONTROL tampered payload refused"         "$OUT" '"tampered_refused":true'
  expect "node $n: CONTROL wrong key refused"                "$OUT" '"wrong_key_refused":true'
  expect "node $n: lists the 2 admitted peers"               "$OUT" '"count":2'
  expect "node $n: every listed key hashes to its node id"   "$OUT" '"all_keys_match":true'
done
$M down >/dev/null 2>&1
[ $FAIL = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
