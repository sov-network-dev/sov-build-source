#!/bin/bash
# scenario_delegation.sh — Phase 2 proof on the isolated mesh: a LIGHT node enrols only through
# signed, threshold-agreed answers from full peers, and fails closed when it cannot get them.
# First run 2026-10-03: D enrolled (unique 3/3), E refused by face (duplicate 3/3), F refused by
# palm naming the right citizen (duplicate 3/3), G refused DEDUP_UNAVAILABLE with 2 witnesses down.
#
#   wsl -u root -- bash /opt/sov/tools/test_mesh/scenario_delegation.sh
# Needs: a wiped mesh; it builds 1 genesis + 2 full + 1 light node itself. Exits 0 only if all pass.
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd); M="bash $D/mesh.sh"; B=/root/sov-mesh
C="ip netns exec sovmesh env NODE_PATH=/root/sov-build/vendor/node_modules /usr/local/bin/node $D/mesh_client.js"
FAIL=0; expect() { if echo "$2" | grep -q "$3"; then echo "  PASS  $1"; else echo "  FAIL  $1 — $2"; FAIL=1; fi; }

$M wipe >/dev/null 2>&1
timeout 150 $M up 1 | tail -1
R=$($C enroll 19401 person-zero --face); expect "genesis citizen enrolled on node 1" "$R" '"success":true'
echo "$R" | grep -o 'SOV-[0-9A-F]*' | head -1 > $B/operator_id
timeout 400 $M up 4 4 | tail -3
# A joiner may refuse citizens (closes the socket) until its operator signup settles, and has
# no witnesses until its peers' first heartbeats arrive — so the first attempt retries on both.
for i in $(seq 1 36); do R=$($C enroll 19404 new-person --face); echo "$R" | grep -qE 'DEDUP_UNAVAILABLE|CLOSED' || break; sleep 10; done
expect "D new person on the light node -> enrolled" "$R" '"success":true'
# The light node asks every full peer whose heartbeat it has; the third peer's first heartbeat can land a
# moment after the enrolment, so 2/2 and 3/3 are both correct (measured 2026-10-10: the same source gave
# each on different runs). The safety rule is threshold T=2 with NO dissent — that is what is checked.
expect "D was decided by delegation (>= 2 signed answers, all unique)" "$(grep 'palm dedup delegated' $B/n4/node.log | tail -1)" 'unique — \(2/2\|3/3\) signed'
expect "E enrolled person (face) -> refused" "$($C enroll 19404 person-zero --face)" 'FACE_ALREADY_ENROLLED'
expect "F enrolled palm, NEW face -> refused by palm" "$($C enroll 19404 person-zero --face --face-seed someone-else)" 'PALM_ALREADY_ENROLLED'
# Storage: after anti-entropy, a full node holds every template; the light node holds only the
# ones it enrolled itself (it asks for deltas without templates and drops any that arrive).
for i in $(seq 1 30); do F2=$(bash $D/count_templates.sh 2); echo "$F2" | grep -q '"palm":2' && break; sleep 10; done
L4=$(bash $D/count_templates.sh 4)
expect "full node 2 synced both citizens' templates" "$F2" '"enrolments":2,"palm":2,"face":2'
expect "light node 4 holds both enrolments but only its own templates" "$L4" '"enrolments":2,"palm":1,"face":1'
kill $(cat $B/n2/pid) $(cat $B/n3/pid); sleep 3
expect "G two witnesses down -> refused, fails closed" "$($C enroll 19404 another-person --face)" 'DEDUP_UNAVAILABLE'
$M down >/dev/null
[ $FAIL = 0 ] && echo "ALL PASS" || { echo "FAILED"; exit 1; }
