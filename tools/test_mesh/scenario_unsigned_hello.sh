#!/bin/bash
# scenario_unsigned_hello.sh — D36: an UNSIGNED HELLO must not log in as an enrolled citizen nor
# replace their messaging key. On 1.4.91 (control) it does both: the impostor is accepted and the
# node then publishes the IMPOSTOR's key for the victim, so new messages are encrypted to the impostor.
#   wsl -u root -- bash /opt/sov/tools/test_mesh/scenario_unsigned_hello.sh
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd); M="bash $D/mesh.sh"; B=/root/sov-mesh
C="ip netns exec sovmesh env NODE_PATH=/root/sov-build/vendor/node_modules /usr/local/bin/node $D/mesh_client.js"
FAIL=0; expect() { if echo "$2" | grep -q -- "$3"; then echo "  PASS  $1"; else echo "  FAIL  $1 — $(echo "$2" | head -c 240)"; FAIL=1; fi; }
refute() { if echo "$2" | grep -q -- "$3"; then echo "  FAIL  $1 — $(echo "$2" | head -c 240)"; FAIL=1; else echo "  PASS  $1"; fi; }

$M wipe >/dev/null 2>&1
timeout 150 $M up 1 | tail -1
$C enroll 19401 person-zero --face --as op-zero > /dev/null
V=$($C enroll 19401 person-victim --face --as victim | grep -o 'SOV-[0-9A-F]*' | head -1)
echo "  victim $V"
$C listen 19401 victim 8 > /dev/null 2>&1      # the victim logs in (signed) once, publishing their real key
BEFORE=$($C pk 19401 op-zero "$V")
H=$($C hijack 19401 "$V" mallory)
AFTER=$($C pk 19401 op-zero "$V")
AKEY=$(echo "$H" | grep -o '"attacker_xkey":"[0-9a-f]*"' | cut -d'"' -f4)
echo "  hijack: $(echo "$H" | cut -c1-90)"
expect "unsigned HELLO claiming an enrolled citizen is REFUSED" "$H" '"result":"REFUSED"'
refute "the node does NOT now publish the impostor's messaging key" "$AFTER" "$AKEY"
expect "the victim's published key is unchanged" "$AFTER" "$(echo "$BEFORE" | grep -o '"key":"[0-9a-f]*"')"
# The enrolment flow (an ID that is not enrolled yet) must keep working unsigned - but publish no key.
N=SOV-0000FEED0000BEEF
H2=$($C hijack 19401 "$N" newcomer)
K2=$($C pk 19401 op-zero "$N")
expect "unsigned HELLO for a NOT-enrolled id is still accepted (enrolment flow)" "$H2" '"result":"ACCEPTED"'
expect "...and it publishes NO messaging key for that id" "$K2" '"key":null'
$M down >/dev/null 2>&1
[ $FAIL = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
