#!/bin/bash
# scenario_presence.sh — cross-node messaging on the isolated mesh (E2E 2026-10-03, finding P4).
# Alice is connected to node 2, Bob to node 3. A message from Alice must reach Bob through the
# nodes, and once Bob leaves, the same send must report him offline.
# On the pre-fix source the first send returns RECIPIENT_OFFLINE: no node ever learned where Bob was.
#   wsl -u root -- bash /opt/sov/tools/test_mesh/scenario_presence.sh
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd); M="bash $D/mesh.sh"; B=/root/sov-mesh
C="ip netns exec sovmesh env NODE_PATH=/root/sov-build/vendor/node_modules /usr/local/bin/node $D/mesh_client.js"
FAIL=0; expect() { if echo "$2" | grep -q -- "$3"; then echo "  PASS  $1"; else echo "  FAIL  $1 — $2"; FAIL=1; fi; }

$M wipe >/dev/null 2>&1
timeout 150 $M up 1 | tail -1
$C enroll 19401 person-zero --face | grep -o 'SOV-[0-9A-F]*' | head -1 > $B/operator_id
timeout 400 $M up 3 | tail -1
# Joiners serve citizens once admitted; retry enrolment until they do.
for i in $(seq 1 40); do A=$($C enroll 19402 alice-palm --face --as alice); echo "$A" | grep -q '"success":true' && break; sleep 10; done
expect "Alice enrolled through node 2" "$A" '"success":true'
for i in $(seq 1 40); do Bb=$($C enroll 19403 bob-palm --face --as bob); echo "$Bb" | grep -q '"success":true' && break; sleep 10; done
expect "Bob enrolled through node 3" "$Bb" '"success":true'
BOB=$(echo "$Bb" | grep -o 'SOV-[0-9A-F]*' | head -1)
sleep 15   # enrolments replicate
# Messages are end-to-end now (1.4.81 refuses plain text), so each citizen's messaging key
# must reach the other node first: one HELLO each publishes it, then let it replicate.
$C listen 19402 alice 3 >/dev/null 2>&1; $C listen 19403 bob 3 >/dev/null 2>&1; sleep 20

$C listen 19403 bob 60 > $B/bob.out 2>&1 &
sleep 8    # Bob is online at node 3; node 3 tells its peers
R=$($C msg 19402 alice "$BOB" "hello Bob, from Alice via node 2" --e2e)
expect "Alice -> Bob across nodes: delivered" "$R" '"success":true'
sleep 3
expect "Bob actually received it" "$(cat $B/bob.out)" 'hello Bob, from Alice via node 2'

pkill -f "mesh_client.js listen 19403 bob" ; sleep 6   # Bob leaves; node 3 tells its peers
R2=$($C msg 19402 alice "$BOB" "are you there" --e2e)
expect "Bob offline -> the sender is told so (outbox keeps it)" "$R2" 'RECIPIENT_OFFLINE'

# A RESTARTED node must neither trust its own stale rows nor stay ignorant of who is online elsewhere
# (E2E 2026-10-03: VPS1 restarted, kept "IronDusk online HERE", and answered RECIPIENT_OFFLINE).
$C listen 19402 bob 25 > $B/bob2.out 2>&1 &
sleep 8                                            # Bob online at node 2 ...
kill -9 $(cat $B/n2/pid); sleep 3                  # ... and node 2 dies under him (no offline update)
pkill -f "mesh_client.js listen 19402 bob"; sleep 2
$C listen 19403 bob 90 > $B/bob3.out 2>&1 &        # Bob back, at node 3
sleep 8
timeout 200 $M up 3 | tail -1                      # node 2 restarts (stale "Bob@node2" row on disk)
for i in $(seq 1 20); do grep -q '\[9/9\]' $B/n2/node.log && break; sleep 3; done; sleep 12
for i in $(seq 1 6); do R3=$($C msg 19402 alice "$BOB" "after the restart" --e2e); echo "$R3" | grep -q '"success":true' && break; sleep 10; done
expect "after node 2 restarts, Alice (node 2) -> Bob (node 3) is delivered" "$R3" '"success":true'
sleep 3
expect "and Bob received it" "$(cat $B/bob3.out)" 'after the restart'
pkill -f "mesh_client.js listen 19403 bob"

# Exchange terms reach other nodes (E2E 2026-10-03: a buyer on another node saw "").
L=$($C list 19402 alice 5 "Five SOV for a printed copy of the Academy book")
expect "Alice lists 5 SOV on node 2" "$L" '"success":true'
for i in $(seq 1 12); do V=$($C browse 19403 bob); echo "$V" | grep -q "printed copy" && break; sleep 5; done
expect "Bob, on node 3, sees the order WITH its terms" "$V" 'Five SOV for a printed copy of the Academy book'

E=$(grep -hc '\[ERROR\]' $B/n*/node.log | paste -sd+ | bc)
expect "no ERROR line on any node" "errors=$E" 'errors=0$'
[ "$E" = 0 ] || grep -hF "[ERROR]" $B/n*/node.log | head -5 | sed "s/^/    /"
$M down >/dev/null
[ $FAIL = 0 ] && echo "ALL PASS" || { echo "FAILED"; exit 1; }
