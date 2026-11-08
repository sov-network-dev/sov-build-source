#!/bin/bash
# scenario_ledger_paths.sh — ledger safety beyond plain transfers (docs/ledger/LEDGER_SAFETY_1.4.90_PLAN.md §7).
#
#   X1  seller lists on node 1 (its HOME); buyer FILLS via node 2 and the seller CONFIRMS via node 3
#       -> both work (routed to the home node); buyer gets amount − fee; fee reaches the operator pool
#   X2  two buyers fill the SAME order at the same instant via nodes 2 and 3 -> exactly ONE fills
#   X3  the same citizen LISTS on node 1 and TRANSFERS on node 2 the same 70% at the same instant
#       -> exactly ONE succeeds (a listing and a payment can't spend the same SOV)
#   end every node agrees on every balance, and the supply invariant is exact (ok) on every node
# Control: MESH_REPO=<1.4.89 tree> — expected to fail X1 (cross-node confirm) and X3.
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd); M="bash $D/mesh.sh"; B=/root/sov-mesh
C="ip netns exec sovmesh env NODE_PATH=/root/sov-build/vendor/node_modules /usr/local/bin/node $D/mesh_client.js"
NS="ip netns exec sovmesh"
FAIL=0
pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1"; FAIL=1; }
bal() { $C bal 1940$1 seller buyer1 buyer2 | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['seller'],d['buyer1'],d['buyer2'])"; }
inv() { $NS curl -s -m 8 http://127.0.0.1:1900$1/economy/snapshot | python3 -c "
import sys,json
try:
  d=json.load(sys.stdin);i=d['invariant'];print(i.get('grand_total_seeds'),i['ok'])
except Exception: print('down')"; }
wait_agree() { for i in $(seq 1 30); do [ "$(for n in 1 2 3; do bal $n; done | sort -u | wc -l)" = 1 ] && return 0; sleep 10; done; return 1; }
oid() { python3 -c "import sys,json;print(json.load(sys.stdin).get('order_id',''))"; }

echo "source under test: ${MESH_REPO:-repo tree}"
$M wipe >/dev/null 2>&1
timeout 150 $M up 1 | tail -1
$C enroll 19401 person-zero --face | grep -o 'SOV-[0-9A-F]*' | head -1 > $B/operator_id
timeout 400 $M up 3 | tail -1
for who in "seller 19401" "buyer1 19402" "buyer2 19403"; do set -- $who
  for i in $(seq 1 40); do R=$($C enroll $2 $1-palm --face --as $1); echo "$R" | grep -q '"success":true' && break; sleep 10; done
  echo "  enrolled $1: $(echo "$R" | head -c 100)"
done
BUYER1=SOV-$(python3 -c "import hashlib;print(hashlib.sha256(b'id:buyer1').hexdigest()[:16].upper())")   # = mesh_client identity('buyer1')
wait_agree || true
for n in 1 2 3; do echo "  node $n: $(bal $n) | invariant $(inv $n)"; done

echo "=== X1: list on node 1 (home), fill via node 2, confirm via node 3"
L=$($C xreq 19401 seller EXCHANGE_LIST_ORDER '{"sov_amount":100000000,"memo":"x1","payment_method":"Bank transfer","expires_in_days":1}'); echo "  list: $L"
O1=$(echo "$L" | oid); sleep 8
F=$($C xreq 19402 buyer1 EXCHANGE_FILL_ORDER "{\"order_id\":\"$O1\"}"); echo "  fill via node 2: $F"
echo "$F" | grep -q '"success":true' && pass "X1: fill through a non-home node works" || fail "X1: fill through a non-home node failed"
sleep 5
K=$($C xreq 19403 seller EXCHANGE_CONFIRM "{\"order_id\":\"$O1\"}"); echo "  confirm via node 3: $K"
echo "$K" | grep -q '"success":true' && pass "X1: confirm through a non-home node works" || fail "X1: confirm through a non-home node failed"
wait_agree && pass "X1: nodes agree ($(bal 1))" || fail "X1: nodes disagree: n1 $(bal 1) | n2 $(bal 2) | n3 $(bal 3)"

echo "=== X2: two buyers fill one order at the same instant via nodes 2 and 3"
L=$($C xreq 19401 seller EXCHANGE_LIST_ORDER '{"sov_amount":50000000,"memo":"x2","payment_method":"Bank transfer","expires_in_days":1}')
O2=$(echo "$L" | oid); sleep 8
R2=$( ($C xreq 19402 buyer1 EXCHANGE_FILL_ORDER "{\"order_id\":\"$O2\"}" & $C xreq 19403 buyer2 EXCHANGE_FILL_ORDER "{\"order_id\":\"$O2\"}" & wait) ); echo "$R2" | sed 's/^/  /'
n=$(echo "$R2" | grep -o '"success":true' | wc -l)
[ "$n" = 1 ] && pass "X2: exactly one of two simultaneous fills succeeded" || fail "X2: $n fills succeeded (want exactly 1)"

echo "=== X3: the same citizen lists on node 1 and transfers on node 2 the same 70%, at once"
AMT=$($C bal 19401 seller | python3 -c "import sys,json;print(int(json.load(sys.stdin)['seller']*0.7/1e6))")
R3=$($C race 19401 19402 seller "$BUYER1" $AMT); echo "  $AMT SOV each: $R3"
n=$(echo "$R3" | grep -o '"success":true' | wc -l)
[ "$n" = 1 ] && pass "X3: exactly one of {listing, transfer} spent the money" || fail "X3: $n of {listing, transfer} succeeded (want exactly 1)"

echo "=== end: agreement and the supply invariant on every node"
wait_agree && pass "end: nodes agree ($(bal 1))" || fail "end: nodes disagree: n1 $(bal 1) | n2 $(bal 2) | n3 $(bal 3)"
sleep 20
for n in 1 2 3; do v=$(inv $n); echo "  node $n invariant: $v"
  echo "$v" | grep -q "^50000000000000 True" && pass "end: node $n supply exact (50,000,000 SOV, ok)" || fail "end: node $n supply not exact: $v"; done

echo; [ $FAIL = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
