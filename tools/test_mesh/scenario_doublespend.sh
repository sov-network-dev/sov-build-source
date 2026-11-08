#!/bin/bash
# scenario_doublespend.sh — ledger safety (docs/ledger/LEDGER_SAFETY_1.4.90_PLAN.md §7), on REAL nodes.
#
#   case A  connected:  same citizen, same nonce, two nodes, same instant -> at most ONE succeeds
#   case B  partition:  node 3 down, nodes 1 and 2 cut from each other -> both sides are a minority:
#                       BOTH refuse with a quorum reason; after healing a normal payment succeeds
#   case C  late node:  node 3 was down while S paid; it returns and is asked to spend S's OLD
#                       balance at the OLD nonce -> refused; everyone converges
# Each case also checks that every node agrees and that S+X+Y never grew.
# A run where nothing moved because of a client/setup error is INVALID, never a pass (2026-10-08 lesson).
#
# Control: MESH_REPO=<a 1.4.89 node tree> on this same script must FAIL (cases B and C).
#   wsl -u root -- bash /opt/sov/tools/test_mesh/scenario_doublespend.sh
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd); M="bash $D/mesh.sh"; B=/root/sov-mesh
C="ip netns exec sovmesh env NODE_PATH=/root/sov-build/vendor/node_modules /usr/local/bin/node $D/mesh_client.js"
NS="ip netns exec sovmesh"
FAIL=0
pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1"; FAIL=1; }
bal3() { $C bal 1940$1 spender xavier yasmin | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['spender'],d['xavier'],d['yasmin'])"; }
sum3() { $C bal 19401 spender xavier yasmin | python3 -c "import sys,json;d=json.load(sys.stdin);v=[d[k] for k in ('spender','xavier','yasmin')];print(sum(v) if all(isinstance(x,int) for x in v) else 'NA')"; }
view() {
  echo "--- $1"
  for n in 1 2 3; do echo "  node $n: $($C bal 1940$n spender xavier yasmin 2>/dev/null)  | $($NS curl -s -m 8 http://127.0.0.1:1900$n/economy/snapshot | python3 -c "
import sys,json
try:
  d=json.load(sys.stdin);i=d['invariant'];print('total',i.get('grand_total_seeds'),'ok',i['ok'])
except Exception: print('down')")"; done
}
wait_agree() { for i in $(seq 1 30); do [ "$(for n in $1; do bal3 $n; done | sort -u | wc -l)" = 1 ] && return 0; sleep 10; done; return 1; }
agree() { if wait_agree "$2"; then pass "$1: nodes $2 agree ($(bal3 ${2%% *}))"; else fail "$1: nodes $2 disagree: $(for n in $2; do echo -n "[n$n $(bal3 $n)] "; done)"; fi; }
grew() { local now; now=$(sum3); if [ "$now" != NA ] && [ "$now" -le "$2" ]; then pass "$1: S+X+Y did not grow ($2 -> $now)"; else fail "$1: money created ($2 -> $now)"; fi; START=$now; }
invalid() { echo "$1" | grep -q 'BAD_ARGS\|MISSING_FIELDS\|NO_EXPECTED_NONCE\|SENDER_MISMATCH'; }
amt70() { $C bal $1 spender | python3 -c "import sys,json;d=json.load(sys.stdin);print(int(d['spender']*0.7/1e6))"; }   # 70% of S as node $1 sees it
cut_12() { for p in 19701 19702; do $NS iptables -I INPUT -p tcp --dport $p -j DROP; $NS iptables -I INPUT -p tcp --sport $p -j DROP; done; }
heal()   { $NS iptables -F INPUT; }

echo "source under test: ${MESH_REPO:-repo tree}"
$M wipe >/dev/null 2>&1
timeout 150 $M up 1 | tail -1
$C enroll 19401 person-zero --face | grep -o 'SOV-[0-9A-F]*' | head -1 > $B/operator_id
timeout 400 $M up 3 | tail -1
for who in "spender 19401" "xavier 19402" "yasmin 19403"; do set -- $who
  for i in $(seq 1 40); do R=$($C enroll $2 $1-palm --face --as $1); echo "$R" | grep -q '"success":true' && break; sleep 10; done
  echo "  enrolled $1: $(echo "$R" | head -c 120)"; eval "$(echo $1 | cut -c1 | tr a-z A-Z)=$(echo "$R" | grep -o 'SOV-[0-9A-F]*' | head -1)"
done
wait_agree "1 2 3" || true; view "after enrolment"
START=$(sum3); echo "S+X+Y = $START"

echo "=== case A: connected, same nonce, two nodes, same instant"
R=$($C ds 19401 19402 spender $X $Y 700); echo "  $R"
okA=$(echo "$R" | grep -o '"success":true' | wc -l)
if invalid "$R"; then fail "case A INVALID — client/setup error, nothing was tested"; fi
[ "$okA" -le 1 ] && pass "case A: at most one of two conflicting spends succeeded ($okA)" || fail "case A: BOTH conflicting spends succeeded"
[ "$okA" -ge 1 ] && pass "case A: a connected network still pays" || fail "case A: neither spend succeeded on a healthy network"
agree "case A" "1 2 3"; view "case A after sync"; grew "case A" "$START"

echo "=== case B: node 3 down; nodes 1 and 2 cut from each other (each side a minority)"
kill $(cat $B/n3/pid) 2>/dev/null; sleep 5; cut_12; sleep 5
AMT=$(amt70 19401); echo "  each payment = $AMT SOV = 70% of S (affordable once, not twice)"
R=$($C ds 19401 19402 spender $X $Y $AMT); echo "  $R"
OLDNONCE=$(echo "$R" | python3 -c "import sys,json;print(json.load(sys.stdin)['nonce'])")   # the slot node 3 last knew
okB=$(echo "$R" | grep -o '"success":true' | wc -l)
if invalid "$R"; then fail "case B INVALID — client/setup error, nothing was tested"; fi
if [ "$okB" = 0 ] && echo "$R" | grep -q 'QUORUM'; then pass "case B: both minority sides refused with a quorum reason"
else fail "case B: a minority side committed a payment ($okB succeeded)"; fi
heal; sleep 30
R=$($C tx 19401 spender $X 50); echo "  after heal: $R"
echo "$R" | grep -q '"success":true' && pass "case B: after healing, the majority (nodes 1+2 of 3) pays" || fail "case B: no payment after healing"
agree "case B" "1 2"; view "case B after heal (node 3 still down)"; grew "case B" "$START"

echo "=== case C: node 3 returns late; asked to spend S's OLD balance at its OLD nonce"
timeout 200 $M up 3 | tail -1
AMT=$(amt70 19403); echo "  node 3's stale view of S allows $AMT SOV (70%)"
R=$($C tx 19403 spender $Y $AMT $OLDNONCE); echo "  via late node 3 at old nonce $OLDNONCE: $R"
if invalid "$R"; then fail "case C INVALID — client/setup error, nothing was tested"
elif echo "$R" | grep -q '"success":true'; then fail "case C: the late node approved spending money that was already spent"
else pass "case C: the late node refused ($(echo "$R" | grep -o "\"error\":\"[A-Za-z_:,]*\""))"; fi
agree "case C" "1 2 3"; view "case C after sync"; grew "case C" "$START"

echo; [ $FAIL = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
