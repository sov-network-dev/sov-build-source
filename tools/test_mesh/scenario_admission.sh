#!/bin/bash
# scenario_admission.sh — operator admission by signed quorum certificate, on the isolated mesh
# (docs/OPERATOR_QUORUM_GAP_2026-10-03.md). Honest paths, end to end, on real node processes:
#   A. fresh network: nodes 2-4 join; every node holds every joiner's row WITH a certificate
#   B. fleet upgrade: certificates wiped while stopped (= rows registered before 1.4.78); on restart
#      each node keeps serving and re-certifies; certificates reach every node
#   C. a newcomer (node 5) joins with a certificate and learns every existing row promptly
#   wsl -u root -- bash /opt/sov/tools/test_mesh/scenario_admission.sh
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd); M="bash $D/mesh.sh"; B=/root/sov-mesh
C="ip netns exec sovmesh env NODE_PATH=/root/sov-build/vendor/node_modules /usr/local/bin/node $D/mesh_client.js"
R="bash $D/registry_dump.sh"
FAIL=0; expect() { if echo "$2" | grep -q -- "$3"; then echo "  PASS  $1"; else echo "  FAIL  $1 — $2"; FAIL=1; fi; }
waitfor() { for i in $(seq 1 "$1"); do eval "$2" && return 0; sleep 15; done; return 1; }
allcert() { for n in $1; do $R $n | grep -q "\"rows\":$2," || return 1; $R $n | grep -q "cert=none\|cert=genesis" && return 1; done; return 0; }

$M wipe >/dev/null 2>&1
timeout 150 $M up 1 | tail -1
$C enroll 19401 person-zero --face | grep -o 'SOV-[0-9A-F]*' | head -1 > $B/operator_id
timeout 400 $M up 4 | tail -1

# A
waitfor 40 'allcert "1 2 3 4" 3'
for n in 1 2 3 4; do expect "A: node $n holds all 3 joiners, each certified" "$($R $n)" '"rows":3,"detail":\["[0-9a-f]*:active:cert=3","[0-9a-f]*:active:cert=3","[0-9a-f]*:active:cert=3"\]'; done

# B — wipe every certificate while stopped: the state of every row registered before 1.4.78
$M down >/dev/null
for n in 1 2 3 4; do SOV_DATA_DIR=$B/n$n/data SNAP_COMMON=$B/n$n/data NODE_PATH=/root/sov-build/vendor/node_modules /usr/local/bin/node -e '
global.sovLog={info(){},debug(){},warn(){},error(){},success(){}};
const { NodeDB } = require("/root/sov-mesh/app/src/storage/db.js"); const d = new NodeDB();
d._db.prepare("UPDATE sov_operator_registry SET admission_cert = ?").run(""); d._db.pragma("wal_checkpoint(TRUNCATE)"); process.exit(0);' 2>/dev/null; done
expect "B: certificates wiped (pre-1.4.78 state)" "$($R 2)" 'cert=none'
timeout 500 $M up 4 | tail -1
expect "B: an upgraded node serves before re-certifying" "$($C enroll 19402 upgrade-person --face)" '"success":true'
waitfor 40 'allcert "1 2 3 4" 3'
for n in 1 2 3 4; do expect "B: node $n holds all 3 rows re-certified" "$($R $n)" '"rows":3,.*cert=3.*cert=3.*cert=3'; done

# C
timeout 300 $M up 5 | tail -1
waitfor 20 'allcert "1 2 3 4 5" 4'
for n in 1 2 3 4; do expect "C: node $n admitted the newcomer" "$($R $n)" '"rows":4,'; done
expect "C: the newcomer learned every existing row" "$($R 5)" '"rows":4,.*cert=3.*cert=3.*cert=3.*cert=3'
expect "C: the newcomer serves citizens" "$($C enroll 19405 node5-person --face)" '"success":true'
E=$(grep -hc '\[ERROR\]' $B/n*/node.log | paste -sd+ | bc)
expect "no ERROR line on any node" "errors=$E" 'errors=0$'
$M down >/dev/null
[ $FAIL = 0 ] && echo "ALL PASS" || { echo "FAILED"; exit 1; }
