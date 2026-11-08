#!/bin/bash
# scenario_owner_auth.sh — node 1.4.95 (protocol/owner_auth.js, defect D73): a citizen's money op carries the
# citizen's OWN signed request, and every node checks it before granting and applying.
#
#   A1  seller lists on node 1 -> succeeds; nodes 2 AND 3 hold that escrow_list op with an op id derived from
#       the signature ('req-') and the signed request attached (they could check it themselves)
#   A2  the same listing request sent UNSIGNED -> refused (no node moves SOV on its own word)
#   A3  seller locks an inheritance vault through node 2 -> succeeds; nodes 1 and 3 hold it the same way
#   end every node agrees on every balance and the supply invariant is exact
# Control: MESH_REPO=<1.4.94 tree> — A1/A3 fail (op ids are 'op-', no request attached), A2 succeeds.
# The peer-side REFUSAL of a forged request needs a dishonest node, which this mesh does not build:
# that half is proven by scripts/test_owner_auth.js (27/27, each attack passes the old rule).
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd); M="bash $D/mesh.sh"; B=/root/sov-mesh
C="ip netns exec sovmesh env NODE_PATH=/root/sov-build/vendor/node_modules /usr/local/bin/node $D/mesh_client.js"
NS="ip netns exec sovmesh"
FAIL=0
pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1"; FAIL=1; }
bal() { $C bal 1940$1 seller | python3 -c "import sys,json;print(json.load(sys.stdin)['seller'])"; }
inv() { $NS curl -s -m 8 http://127.0.0.1:1900$1/economy/snapshot | python3 -c "
import sys,json
try: print(json.load(sys.stdin)['invariant']['ok'])
except Exception: print('down')"; }
wait_agree() { for i in $(seq 1 30); do [ "$(for n in 1 2 3; do bal $n; done | sort -u | wc -l)" = 1 ] && return 0; sleep 10; done; return 1; }
holds() { for i in $(seq 1 18); do bash $D/ledger_ops_dump.sh $1 | grep -q "^$2 req- auth:app" && return 0; sleep 10; done; return 1; }

echo "source under test: ${MESH_REPO:-repo tree}"
$M wipe >/dev/null 2>&1
timeout 150 $M up 1 | tail -1
$C enroll 19401 person-zero --face | grep -o 'SOV-[0-9A-F]*' | head -1 > $B/operator_id
timeout 400 $M up 3 | tail -1
for i in $(seq 1 40); do R=$($C enroll 19401 seller-palm --face --as seller); echo "$R" | grep -q '"success":true' && break; sleep 10; done
echo "  enrolled seller: $(echo "$R" | head -c 100)"
wait_agree || true

echo "=== A1: list on node 1; nodes 2 and 3 hold the op with the citizen's signed request"
L=$($C xreq 19401 seller EXCHANGE_LIST_ORDER '{"sov_amount":100000000,"memo":"a1","payment_method":"Bank transfer","expires_in_days":1}'); echo "  list: $L"
echo "$L" | grep -q '"success":true' && pass "A1: signed listing accepted" || fail "A1: signed listing refused"
for n in 2 3; do holds $n escrow_list && pass "A1: node $n holds escrow_list as req- with the signed request"   || fail "A1: node $n: $(bash $D/ledger_ops_dump.sh $n | tr '\n' ';')"; done

echo "=== A2: the same request UNSIGNED"
U=$(MESH_UNSIGNED=1 $C xreq 19401 seller EXCHANGE_LIST_ORDER '{"sov_amount":100000000,"memo":"a2","payment_method":"Bank transfer","expires_in_days":1}'); echo "  unsigned: $U"
echo "$U" | grep -q '"success":true' && fail "A2: an UNSIGNED listing moved SOV" || pass "A2: unsigned listing refused"

echo "=== A3: inheritance vault through node 2"
V=$($C alloc-create 19402 seller 25 SOVW-TEST-AUTH-0001); echo "  vault: $(echo "$V" | head -c 160)"
echo "$V" | grep -q '"success":true' && pass "A3: signed vault lock accepted" || fail "A3: signed vault lock refused"
for n in 1 3; do holds $n alloc_lock && pass "A3: node $n holds alloc_lock as req- with the signed request" || fail "A3: node $n: $(bash $D/ledger_ops_dump.sh $n | tr '\n' ';')"; done

echo "=== end"
wait_agree && pass "every node agrees on the seller's balance ($(bal 1))" || fail "nodes disagree: $(bal 1) / $(bal 2) / $(bal 3)"
for n in 1 2 3; do [ "$(inv $n)" = True ] && pass "node $n supply invariant exact" || fail "node $n invariant: $(inv $n)"; done
$M down >/dev/null 2>&1
[ $FAIL = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
