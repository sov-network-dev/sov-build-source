#!/bin/bash
# scenario_genesis_cert_log.sh — a joiner meeting a genesis that has not earned its certificate
# yet logs one calm INFO line, not a WARN (1.4.85). Node 1 here has no operator, so it can never
# earn one - the worst case. On the 1.4.84 source the joiner logs
# "Registry entry for … refused — NO_CERTIFICATE" as a WARN instead (control).
#   wsl -u root -- bash /opt/sov/tools/test_mesh/scenario_genesis_cert_log.sh
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd); M="bash $D/mesh.sh"; B=/root/sov-mesh
C="ip netns exec sovmesh env NODE_PATH=/root/sov-build/vendor/node_modules /usr/local/bin/node $D/mesh_client.js"
FAIL=0; expect() { if echo "$2" | grep -q -- "$3"; then echo "  PASS  $1"; else echo "  FAIL  $1"; FAIL=1; fi; }
refute() { if echo "$2" | grep -q -- "$3"; then echo "  FAIL  $1 — $(echo "$2" | grep -- "$3" | head -1 | cut -c1-160)"; FAIL=1; else echo "  PASS  $1"; fi; }

$M wipe >/dev/null 2>&1
timeout 150 $M up 1 | tail -1
for i in $(seq 1 30); do grep -q 'approved by: genesis' $B/n1/node.log && break; sleep 3; done
$C enroll 19401 person-op --face | grep -o 'SOV-[0-9A-F]*' | head -1 > $B/operator_id
timeout 200 $M up 2 | tail -1
for i in $(seq 1 40); do grep -q 'Registered locally\|Registration approved' $B/n2/node.log && break; sleep 3; done
sleep 20
L2=$(cat $B/n2/node.log)
expect "node 2 joined" "$L2" 'Registration approved'
refute "no NO_CERTIFICATE WARN about the genesis" "$L2" 'WARN.*Registry entry for .* refused — NO_CERTIFICATE'
expect "one INFO line says the genesis has not earned it yet" "$L2" 'has not earned its admission certificate yet'
$M down >/dev/null 2>&1
[ $FAIL = 0 ] && echo "ALL PASS" || echo "FAILED"
