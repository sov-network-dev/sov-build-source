#!/bin/bash
# scenario_nogenesis.sh — a joining node must never declare itself genesis (E2E 2026-10-04).
#
# On 2026-10-04 a desktop node started with no bootstrap address. At +30 s it had no peers, so it
# "registered as bootstrap node", minted its OWN biometric seed and approved itself as genesis;
# when it then found the fleet, every node logged BIOMETRIC DEDUP KEY MISMATCH - duplicate palm
# detection could not work across them. 1.4.82: genesis must be DECLARED (SOV_GENESIS=1).
#
#  1. Node 1, the declared genesis, mints the network seed.
#  2. Node 2 joins told NOTHING about the network (no bootstrap address - the desktop case).
#     It must NOT mint a seed or register itself; it keeps looking.
#  3. It must not serve citizens while unjoined.
#  4. No node logs a dedup-key mismatch.
# On the 1.4.81 source, step 2 fails: node 2 mints its own seed at +30 s.
#   wsl -u root -- bash /opt/sov/tools/test_mesh/scenario_nogenesis.sh
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd); M="bash $D/mesh.sh"; B=/root/sov-mesh
C="ip netns exec sovmesh env NODE_PATH=/root/sov-build/vendor/node_modules /usr/local/bin/node $D/mesh_client.js"
FAIL=0; expect() { if echo "$2" | grep -q -- "$3"; then echo "  PASS  $1"; else echo "  FAIL  $1 — $(echo "$2" | head -c 300)"; FAIL=1; fi; }
refute() { if echo "$2" | grep -q -- "$3"; then echo "  FAIL  $1 — $(echo "$2" | grep -- "$3" | head -2)"; FAIL=1; else echo "  PASS  $1"; fi; }

$M wipe >/dev/null 2>&1
timeout 150 $M up 1 | tail -1
for i in $(seq 1 30); do grep -q 'approved by: genesis' $B/n1/node.log && break; sleep 3; done   # registration runs ~30 s after boot
expect "node 1 (declared genesis) registered as genesis" "$(cat $B/n1/node.log)" 'approved by: genesis'
# NB: this mesh gives every node the same PALM_CANCELABLE_SEED in its environment, so no node ever
# MINTS here and the "did not mint" check below cannot tell versions apart. The registration and
# enrolment checks are the discriminating ones (the 1.4.81 control fails both).
$C enroll 19401 person-zero --face | grep -o 'SOV-[0-9A-F]*' | head -1 > $B/operator_id

NOBOOT=1 timeout 200 $M up 2 | tail -1
sleep 100   # well past the old +30 s self-genesis point, and a retry or two
L2=$(cat $B/n2/node.log)
refute "node 2 did NOT mint its own seed" "$L2" 'minted the network biometric seed'
refute "node 2 did NOT register itself as genesis" "$L2" 'approved by: genesis'
expect "node 2 says it is still looking (not genesis)" "$L2" 'still looking for the network'
R=$($C enroll 19402 nobody-palm --face --as nobody 2>&1)
refute "node 2 does not enrol citizens while unjoined" "$R" '"success":true'
E=0; for n in 1 2; do E=$((E + $(grep -c 'DEDUP KEY MISMATCH' $B/n$n/node.log))); done
expect "no dedup-key mismatch on any node" "mismatch=$E" 'mismatch=0'

$M down >/dev/null 2>&1
[ $FAIL = 0 ] && echo "ALL PASS" || echo "FAILED"
