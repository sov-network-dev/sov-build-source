#!/bin/bash
# scenario_serving_node.sh — node 1.4.96: the 2026-10-09 outage, re-run on real nodes.
#
# 9 Oct: two demo citizens' DESKTOP nodes were admitted as operators, then went offline. With three
# resolved operators and only one online, no payment could reach an operator majority: every transfer
# answered QUORUM_UNAVAILABLE for ~8 hours. 1.4.96: the desktop app's node runs as a SERVING node
# (SOV_NODE_ROLE=serving) — it serves and relays, but never votes, so its absence cannot stall anything.
#
#   S1  a second citizen's desktop node (node 4, its own operator, serving) joins the 3 server nodes
#   S2  a payment made THROUGH the serving node succeeds (it may originate; it just does not vote)
#   S3  node 4 goes offline -> payments through nodes 1 and 2 STILL succeed      <- the outage case
#   S4  the voting nodes never recorded node 4 as a validator; every node agrees; supply exact
# Control: MESH_REPO=<1.4.95 tree> must FAIL S3 (QUORUM_UNAVAILABLE), reproducing the outage.
#   wsl -u root -- bash /opt/sov/tools/test_mesh/scenario_serving_node.sh
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd); M="bash $D/mesh.sh"; B=/root/sov-mesh
C="ip netns exec sovmesh env NODE_PATH=/root/sov-build/vendor/node_modules /usr/local/bin/node $D/mesh_client.js"
NS="ip netns exec sovmesh"
FAIL=0
pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1"; FAIL=1; }
bal() { $C bal 1940$1 spender xavier | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['spender'],d['xavier'])"; }
inv() { $NS curl -s -m 8 http://127.0.0.1:1900$1/economy/snapshot | python3 -c "
import sys,json
try: print(json.load(sys.stdin)['invariant']['ok'])
except Exception: print('down')"; }
wait_agree() { for i in $(seq 1 30); do [ "$(for n in 1 2 3; do bal $n; done | sort -u | wc -l)" = 1 ] && return 0; sleep 10; done; return 1; }
ok() { echo "$1" | grep -q '"success":true'; }

echo "source under test: ${MESH_REPO:-repo tree}"
$M wipe >/dev/null 2>&1
timeout 150 $M up 1 | tail -1
$C enroll 19401 person-zero --face | grep -o 'SOV-[0-9A-F]*' | head -1 > $B/operator_id
timeout 400 $M up 3 | tail -1
for who in "spender 19401" "xavier 19402" "desk 19401"; do set -- $who
  for i in $(seq 1 40); do R=$($C enroll $2 $1-palm --face --as $1); echo "$R" | grep -q '"success":true' && break; sleep 10; done
  echo "  enrolled $1: $(echo "$R" | head -c 100)"
done
DESK=SOV-$(python3 -c "import hashlib;print(hashlib.sha256(b'id:desk').hexdigest()[:16].upper())")   # = mesh_client identity('desk')
X=SOV-$(python3 -c "import hashlib;print(hashlib.sha256(b'id:xavier').hexdigest()[:16].upper())")
wait_agree || true

echo "=== S1: a second citizen's desktop node joins as SERVING (its own operator)"
export UNTRUSTED=4   # 1.4.97: a citizen's desktop node is not on the fleet's trust list
export EXTRA_ENV_4="OPERATOR_SOVEREIGN_ID=$DESK SOV_NODE_ROLE=serving"
timeout 400 $M up 4 | tail -1
sleep 90                                                     # operator signup + certificate settle
grep -q 'HELLO_ROLE_REQUIRED' $B/n1/node.log $B/n2/node.log $B/n3/node.log && fail "S1: a peer refused node 4's role" || pass "S1: node 4 admitted to the mesh"

echo "=== S2: a payment THROUGH the serving node"
R=$($C tx 19404 spender $X 1); echo "  via node 4: $R"
ok "$R" && pass "S2: a citizen connected to a serving node can pay" || fail "S2: payment through the serving node failed"
R=$($C tx 19401 spender $X 1); echo "  via node 1: $R"
ok "$R" && pass "S2: payment via a voting node works" || fail "S2: payment via node 1 failed"

echo "=== S3: the serving node goes offline (the 9 Oct outage case)"
kill $(cat $B/n4/pid) 2>/dev/null; sleep 30
R=$($C tx 19401 spender $X 1); echo "  via node 1: $R"
ok "$R" && pass "S3: payments continue with the desktop node gone" || fail "S3: payment REFUSED with the desktop node gone ($(echo "$R" | grep -o '"error":"[^"]*"'))"
R=$($C tx 19402 spender $X 1); echo "  via node 2: $R"
ok "$R" && pass "S3: payments continue through another node" || fail "S3: payment via node 2 refused"

echo "=== S4: agreement"
N4=$(cat $B/n4/node_id 2>/dev/null || grep -oE 'Node ID[: ]+[0-9a-f]{16,}' $B/n4/node.log | head -1 | grep -oE '[0-9a-f]{16,}')
wait_agree && pass "S4: nodes 1-3 agree ($(bal 1))" || fail "S4: nodes disagree: $(bal 1) / $(bal 2) / $(bal 3)"
for n in 1 2 3; do [ "$(inv $n)" = True ] && pass "S4: node $n supply invariant exact" || fail "S4: node $n invariant $(inv $n)"; done
$M down >/dev/null 2>&1
[ $FAIL = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
