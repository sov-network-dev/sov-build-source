#!/bin/bash
# scenario_governance.sh — node 1.4.97 governance trust model (audit D76, D79, D82, D85) on 3 REAL nodes.
# Honest flows must still work across nodes, every relayed item must carry the citizen's signed request:
#   G1  alice proposes a poll on node 1 -> nodes 2 and 3 hold it, with the creator's signed request
#   G2  bob votes on node 2 -> the vote is counted on nodes 1, 2 and 3 (each re-verifies bob's signature)
#   G3  alice votes on node 3 -> 2 votes on every node
#   G4  a key that never enrolled opens a session and votes -> refused (D76)
#   G5  alice opens a petition on node 1, bob signs on node 2 -> every node holds it with 1 signature
#   end no governance parameter changed on any node; supply invariant exact
# The DISHONEST-peer half (forged activation, forged poll/vote, early close, raw consensus rows) needs a
# node this mesh does not build: proven by test_gov_trust_1497.js (33/33, each attack passes on 1.4.96).
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd); M="bash $D/mesh.sh"; B=/root/sov-mesh
C="ip netns exec sovmesh env NODE_PATH=/root/sov-build/vendor/node_modules /usr/local/bin/node $D/mesh_client.js"
NS="ip netns exec sovmesh"
FAIL=0
pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1"; FAIL=1; }
inv() { $NS curl -s -m 8 http://127.0.0.1:1900$1/economy/snapshot | python3 -c "
import sys,json
try: print(json.load(sys.stdin)['invariant']['ok'])
except Exception: print('down')"; }
gd() { bash $D/gov_dump.sh "$@"; }
waitfor() { for i in $(seq 1 24); do gd $1 | grep -q "$2" && return 0; sleep 10; done; return 1; }
enroll() { for i in $(seq 1 40); do R=$($C enroll $1 $2 --face --as $3); echo "$R" | grep -q '"success":true' && { echo "  enrolled $3: $(echo "$R" | grep -o 'SOV-[0-9A-F]*' | head -1)"; return 0; }; sleep 10; done; echo "  enrol $3 FAILED: $R"; return 1; }

echo "source under test: ${MESH_REPO:-repo tree}"
$M wipe >/dev/null 2>&1
timeout 150 $M up 1 | tail -1
$C enroll 19401 person-zero --face | grep -o 'SOV-[0-9A-F]*' | head -1 > $B/operator_id
timeout 400 $M up 3 | tail -1
enroll 19401 alice-palm alice; enroll 19402 bob-palm bob
sleep 20
BEFORE=$(gd 1 quorum_threshold tx_fee_rate sov_enclave | grep '^param' | tr '\n' ';')

PID="P-G-$(date +%s)"
echo "=== G1: alice proposes $PID on node 1"
R=$($C xreq 19401 alice POLL_CREATE "{\"poll_id\":\"$PID\",\"tag\":\"quorum_threshold\",\"title\":\"g1\",\"options\":[\"0.05\",\"0.10\"],\"duration_minutes\":60}"); echo "  create: $(echo "$R" | head -c 160)"
echo "$R" | grep -q '"success":true' && pass "G1: poll created" || fail "G1: poll not created"
for n in 2 3; do waitfor $n "poll $PID open votes=0 signed=true" && pass "G1: node $n holds the poll with the creator's signed request" || fail "G1: node $n: $(gd $n | tr '\n' ';')"; done

echo "=== G2: bob votes 0.05 on node 2"
R=$($C xreq 19402 bob POLL_VOTE "{\"poll_id\":\"$PID\",\"option\":\"0.05\"}"); echo "  vote: $(echo "$R" | head -c 160)"
echo "$R" | grep -q '"success":true' && pass "G2: vote recorded on node 2" || fail "G2: vote refused on node 2"
for n in 1 3; do waitfor $n "poll $PID open votes=1" && pass "G2: node $n counts bob's signed vote" || fail "G2: node $n: $(gd $n | tr '\n' ';')"; done

echo "=== G3: alice votes 0.05 on node 3"
R=$($C xreq 19403 alice POLL_VOTE "{\"poll_id\":\"$PID\",\"option\":\"0.05\"}"); echo "  vote: $(echo "$R" | head -c 160)"
for n in 1 2 3; do waitfor $n "poll $PID open votes=2" && pass "G3: node $n counts 2 votes" || fail "G3: node $n: $(gd $n | tr '\n' ';')"; done

echo "=== G4: a key that never enrolled votes"
R=$($C xreq 19402 ghost-never-enrolled POLL_VOTE "{\"poll_id\":\"$PID\",\"option\":\"0.10\"}"); echo "  ghost vote: $(echo "$R" | head -c 200)"
echo "$R" | grep -q '"success":true' && fail "G4: a non-citizen's vote was COUNTED" || pass "G4: non-citizen vote refused"
sleep 15
for n in 1 2 3; do gd $n | grep -q "poll $PID open votes=2" && pass "G4: node $n still counts exactly 2 votes" || fail "G4: node $n: $(gd $n | tr '\n' ';')"; done

PET="PET-G-$(date +%s)"
echo "=== G5: petition $PET (alice, node 1), signed by bob on node 2"
R=$($C xreq 19401 alice PETITION_CREATE "{\"petition_id\":\"$PET\",\"param_key\":\"sov_enclave\",\"direction\":\"deactivate\",\"title\":\"g5\"}"); echo "  petition: $(echo "$R" | head -c 160)"
echo "$R" | grep -q '"success":true' && pass "G5: petition created" || fail "G5: petition not created"
for n in 2 3; do waitfor $n "petition $PET open" && pass "G5: node $n holds the signed petition" || fail "G5: node $n: $(gd $n | tr '\n' ';')"; done
R=$($C xreq 19402 bob PETITION_SIGN "{\"petition_id\":\"$PET\"}"); echo "  sign: $(echo "$R" | head -c 160)"
# 3 citizens enrolled: 1 signature = 33% >= petition_threshold_pct 0.33, so every node triggers the same
# deterministic poll pet-<petition_id> by itself (petition polls are never taken from a peer).
for n in 1 2 3; do waitfor $n "petition $PET [a-z_]* sigs=1" && pass "G5: node $n counts bob's signed signature" || fail "G5: node $n: $(gd $n | tr '\n' ';')"; done
for n in 1 2 3; do waitfor $n "poll pet-$PET open" && pass "G5: node $n triggered the petition poll itself" || fail "G5: node $n: $(gd $n | tr '\n' ';')"; done

echo "=== end"
for n in 1 2 3; do
  NOW=$(gd $n quorum_threshold tx_fee_rate sov_enclave | grep '^param' | tr '\n' ';')
  [ "$NOW" = "$BEFORE" ] && pass "node $n: no parameter changed ($NOW)" || fail "node $n params: $NOW (before $BEFORE)"
  [ "$(inv $n)" = True ] && pass "node $n supply invariant exact" || fail "node $n invariant: $(inv $n)"
done
$M down >/dev/null 2>&1
[ $FAIL = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
