#!/bin/bash
# scenario_ghost.sh — node 1.4.93: D45 (discovery port busy at boot -> retried, not silently lost) and
# D46 (a signed login by a NEVER-ENROLLED identity creates no wallet row / key on any node).
#   wsl -u root -- bash /opt/sov/tools/test_mesh/scenario_ghost.sh   (MESH_REPO=... for a control)
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd); M="bash $D/mesh.sh"; B=/root/sov-mesh; NX="ip netns exec sovmesh"
C="$NX env NODE_PATH=/root/sov-build/vendor/node_modules /usr/local/bin/node $D/mesh_client.js"
FAIL=0; expect() { if echo "$2" | grep -q -- "$3"; then echo "  PASS  $1"; else echo "  FAIL  $1 — $(echo "$2" | head -c 250)"; FAIL=1; fi; }
slots() { $NX curl -s --max-time 10 http://127.0.0.1:$1/economy/snapshot | grep -o '"wallet_slot_count":[0-9]*' | cut -d: -f2; }

$M wipe >/dev/null 2>&1
$M exec true >/dev/null 2>&1   # namespace up
# D45: hold node 1's discovery port for 15 s while it boots
$NX /usr/local/bin/node -e 'const s=require("http").createServer((q,r)=>r.end("squatter")).listen(19001);setTimeout(()=>{s.close();process.exit(0)},15000)' &
sleep 1
timeout 150 $M up 1 | tail -1
sleep 25
OUT=$($NX curl -s --max-time 10 http://127.0.0.1:19001/node-info)
expect "D45: discovery server serves after the port frees (no silent loss)" "$OUT" '"node_id"'
expect "D45: the busy port was logged and retried" "$(grep -c 'busy — retry' $B/n1/node.log)" '^[1-9]'

$C enroll 19401 person-zero --face | grep -o 'SOV-[0-9A-F]*' | head -1 > $B/operator_id
timeout 300 $M up 3 | tail -1
sleep 40
BEFORE="$(slots 19001) $(slots 19002) $(slots 19003)"
$C listen 19401 ghost-never-enrolled 5 >/dev/null 2>&1      # a signed login by an identity that never enrolled
sleep 45
AFTER="$(slots 19001) $(slots 19002) $(slots 19003)"
expect "D46: wallet slots unchanged on all 3 after a never-enrolled login ($BEFORE -> $AFTER)" "$([ "$BEFORE" = "$AFTER" ] && echo same)" 'same'
# enrolled citizens are unaffected: a real enrolment still adds exactly one slot everywhere
A=$($C enroll 19402 alice-palm --face --as alice); expect "an enrolled citizen still enrols" "$A" '"success":true'
sleep 40
AFTER2="$(slots 19001) $(slots 19002) $(slots 19003)"
expect "enrolment adds one slot on every node ($AFTER -> $AFTER2)" "$(python3 -c "a='$AFTER'.split();b='$AFTER2'.split();print('ok' if len(a)==3 and all(int(y)==int(x)+1 for x,y in zip(a,b)) else 'no')")" 'ok'
# 1.4.93 D1: every enrolment needs a face; the EN route is retired
expect "D1: enrolment with NO face is refused" "$($C enroll 19402 faceless-person)" 'FACE_REQUIRED'
expect "D1: the retired EN route is refused" "$($C enroll-en 19402)" 'ENROLL_ROUTE_RETIRED'
# 1.4.93 D29: a transfer without a valid signature is refused; a signed one goes through
expect "D29: UNSIGNED transfer refused" "$($C txu 19402 alice SOV-0000000000000000 1)" 'INVALID_SIGNATURE'
expect "D29: SIGNED transfer accepted" "$($C tx 19402 alice "$(cat $B/operator_id)" 1)" '"success":true'

$M down >/dev/null 2>&1
[ $FAIL = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
