#!/bin/bash
# scenario_exposure.sh — node 1.4.92 address & link exposure fixes (docs/security/ADDRESS_EXPOSURE_1.4.92.md).
# Node 4 claims an address nobody can reach (10.255.255.1 — no route in the namespace), standing in
# for a home node behind NAT: it joins by dialling OUT, so the others only ever see it inbound.
#  1 its address is published NOWHERE: /relay-pool, /relay-pool/latest, both plugins, a citizen's RELAY_LIST
#  2 the mesh link is encrypted: no plaintext frame but PEER_HELLO on the wire
#  3 the plugins never carry the request's Host header
#  4 each joiner's signed list carries its own admission certificate, approved by the other nodes' keys
#  5 public endpoints are rate-limited per IP
# Validity guard: node 4 must really be connected, or check 1 proves nothing.
#   wsl -u root -- bash /opt/sov/tools/test_mesh/scenario_exposure.sh   (MESH_REPO=... for a control)
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd); M="bash $D/mesh.sh"; B=/root/sov-mesh; LIAR=10.255.255.1
NX="ip netns exec sovmesh"
C="$NX env NODE_PATH=/root/sov-build/vendor/node_modules /usr/local/bin/node $D/mesh_client.js"
FAIL=0
pass() { echo "  PASS  $1"; }; fail() { echo "  FAIL  $1 — $(echo "$2" | head -c 300)"; FAIL=1; }
expect()   { if echo "$2" | grep -q -- "$3"; then pass "$1"; else fail "$1" "$2"; fi; }
expect_no(){ if echo "$2" | grep -q -- "$3"; then fail "$1" "$(echo "$2" | grep -o -- ".\{60\}$3.\{20\}" | head -1)"; else pass "$1"; fi; }

$M wipe >/dev/null 2>&1
timeout 150 $M up 1 | tail -1
$C enroll 19401 person-zero --face | grep -o 'SOV-[0-9A-F]*' | head -1 > $B/operator_id
timeout 300 $M up 3 | tail -1
EXTRA_ENV_4="SOV_PUBLIC_HOST=$LIAR" timeout 200 $M up 4 | tail -1
sleep 100

N4=$(grep -o 'Node ID *: *[0-9a-f]*\|node[_ ]id[^0-9a-f]*[0-9a-f]\{16\}' $B/n4/node.log | head -1 | grep -o '[0-9a-f]\{16,\}' | head -1)
CONN=$(grep -c "Peer connected: .*@ $LIAR" $B/n1/node.log $B/n2/node.log $B/n3/node.log | awk -F: '{s+=$2} END {print s+0}')
if [ "$CONN" -gt 0 ]; then pass "validity: node 4 ($LIAR) is connected to the mesh ($CONN handshakes)"; else fail "validity: node 4 connected" "$(tail -5 $B/n4/node.log)"; fi

echo "-- 1. the unreachable (home) address is published nowhere"
for n in 1 2 3; do
  OUT=$($NX curl -s --max-time 10 http://127.0.0.1:$((19000+n))/relay-pool)
  expect    "node $n /relay-pool answers"                 "$OUT" '"signer_pubkey"'
  expect_no "node $n /relay-pool omits $LIAR"             "$OUT" "$LIAR"
  REAL=$(echo "$OUT" | grep -o '"address":"127.0.0.1:[0-9]*"' | sort -u | wc -l)
  if [ "$REAL" = 2 ]; then pass "node $n /relay-pool lists its 2 real peers (dial-back proven)"; else fail "node $n lists its 2 real peers" "found $REAL"; fi
  OUT=$($NX curl -s --max-time 10 http://127.0.0.1:$((19000+n))/relay-pool/latest)
  expect_no "node $n /relay-pool/latest omits $LIAR"      "$OUT" "$LIAR"
  OUT=$($NX curl -s --max-time 10 -H 'Host: evil.example' http://127.0.0.1:$((19000+n))/sdk/sov-plugin.js)
  expect    "node $n plugin.js answers (retired notice)"  "$OUT" 'Retired'
  expect_no "node $n plugin.js omits $LIAR"               "$OUT" "$LIAR"
  expect_no "node $n plugin.js ignores Host header"       "$OUT" 'evil.example'
  OUT=$($NX curl -s --max-time 10 -H 'Host: evil.example' http://127.0.0.1:$((19000+n))/sdk/sov-plugin.php)
  expect_no "node $n plugin.php omits $LIAR"              "$OUT" "$LIAR"
  expect_no "node $n plugin.php ignores Host header"      "$OUT" 'evil.example'
done
OUT=$($C rlist 19401 probe-citizen)
expect    "citizen RELAY_LIST answered"                   "$OUT" '"ips"'
expect_no "citizen RELAY_LIST omits $LIAR"                "$OUT" "$LIAR"

echo "-- 2. the mesh link is encrypted"
CAP=$B/mesh.pcap; rm -f $CAP
$NX timeout 45 tcpdump -i lo -s0 -U -w $CAP 'tcp portrange 19701-19704' >/dev/null 2>&1
TXT=$(tcpdump -r $CAP -A 2>/dev/null)
PLAIN=$(echo "$TXT" | grep -o '"type":"[A-Z_]*"' | grep -v PEER_HELLO | sort | uniq -c | sort -rn | head -5 | tr '\n' ' ')
ENC=$(echo "$TXT" | grep -c '{"e":"')
if [ -z "$PLAIN" ]; then pass "no plaintext mesh frame in 45 s of traffic"; else fail "no plaintext mesh frame" "$PLAIN"; fi
if [ "$ENC" -gt 0 ]; then pass "sealed frames present ($ENC)"; else fail "sealed frames present" "0 — capture empty?"; fi
SEEN=$(echo "$TXT" | grep -c 'NETWORK_SEED\|cancelable\|callback_secret')
if [ "$SEEN" = 0 ]; then pass "no seed / secret field names visible on the wire"; else fail "secret names on the wire" "$SEEN"; fi

echo "-- 4. each joiner proves itself with its own admission certificate"
for n in 2 3; do
  OUT=$($NX env NODE_PATH=/root/sov-build/vendor/node_modules /usr/local/bin/node -e '
const http=require("http"), adm=require("/root/sov-mesh/app/src/protocol/operator_admission.js");
const get=(p)=>new Promise(r=>http.get({host:"127.0.0.1",port:p,path:"/relay-pool",timeout:8000},s=>{let b="";s.on("data",d=>b+=d);s.on("end",()=>r(JSON.parse(b)))}).on("error",()=>r(null)));
(async()=>{ const me=+process.argv[1]; const others=[1,2,3].filter(x=>x!==me);
  const keys=new Set(); for (const o of others){ const e=await get(19000+o); if(e) keys.add(e.signer_pubkey); }
  const e=await get(19000+me); const cert=e&&e.signer_cert; const r={has_cert:Array.isArray(cert)&&cert.length>0};
  if(r.has_cert){ const subj={node_id:e.signer,operator_id:cert[0].operator_id,source_root:cert[0].source_root,signup_ts:cert[0].signup_ts};
    const ok=new Set(cert.filter(a=>adm.verifyApproval(a,subj)&&keys.has(a.approver_pub)).map(a=>a.approver));
    r.valid_by_others=ok.size; const forged=JSON.parse(JSON.stringify(cert)); forged.forEach(a=>a.node_id="00".repeat(32));
    r.forged_refused=!forged.some(a=>adm.verifyApproval(a,{...subj,node_id:"00".repeat(32)})&&false)&&forged.every(a=>!adm.verifyApproval(a,subj)); }
  console.log(JSON.stringify(r)); })();' $n)
  expect "node $n signs its list with a certificate"              "$OUT" '"has_cert":true'
  expect "node $n certificate: >=2 approvals by the other nodes"  "$OUT" '"valid_by_others":[2-9]'
  expect "node $n CONTROL altered certificate refused"            "$OUT" '"forged_refused":true'
done

echo "-- 5. public endpoints are rate-limited"
CODES=$(for i in $(seq 1 75); do $NX curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 http://127.0.0.1:19003/node-info; done | sort | uniq -c | tr '\n' ' ')
expect "first requests served (200)"  "$CODES" ' 200'
expect "excess requests refused (429)" "$CODES" ' 429'

$M down >/dev/null 2>&1
[ $FAIL = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
