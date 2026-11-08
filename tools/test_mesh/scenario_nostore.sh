#!/bin/bash
# scenario_nostore.sh — "the node does not store messages" (king, 2026-10-03), on real nodes.
#
# Three nodes on the isolated mesh. Alice on node 2, Bob and Carol on node 3.
#  1. Plain text is refused on every channel: direct, group, trade chat.
#  2. Group chat: one envelope per member, end-to-end. A connected member gets it and
#     decrypts it; an offline member is reported back to the sender (whose device keeps it).
#  3. Trade chat: end-to-end; seller offline -> "offline" (buyer's device keeps it);
#     seller online -> delivered and decrypted.
#  4. After all of it, NO node holds a single message: group history, trade chat and
#     queued messages are all zero on all three.
# On the pre-1.4.81 source, step 1 fails (plain text accepted) and step 4 fails (stored).
#   wsl -u root -- bash /opt/sov/tools/test_mesh/scenario_nostore.sh
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd); M="bash $D/mesh.sh"; B=/root/sov-mesh
C="ip netns exec sovmesh env NODE_PATH=/root/sov-build/vendor/node_modules /usr/local/bin/node $D/mesh_client.js"
FAIL=0; expect() { if echo "$2" | grep -q -- "$3"; then echo "  PASS  $1"; else echo "  FAIL  $1 — $(echo "$2" | head -c 300)"; FAIL=1; fi; }

stored() {   # stored <node>: messages a node holds, read from a COPY of its data dir
  local N=$1 T; T=$(mktemp -d); cp -r $B/n$N/data/. $T/
  SOV_DATA_DIR=$T SNAP_COMMON=$T NODE_PATH=/root/sov-build/vendor/node_modules /usr/local/bin/node -e '
global.sovLog={info(){},debug(){},warn(){},error(){},success(){}};
const { NodeDB } = require("/root/sov-mesh/app/src/storage/db.js"); const d = new NodeDB();
const q = (s) => { try { return d._db.prepare(s).get().c; } catch (_) { return -1; } };
console.log(JSON.stringify({ node: '$N',
  group_messages: q("SELECT COUNT(*) c FROM sov_group_messages"),
  trade_messages: q("SELECT COUNT(*) c FROM sov_exchange_messages"),
  queued_messages: q("SELECT COUNT(*) c FROM sov_pending_messages WHERE op IN (\x27MI\x27,\x27GM\x27,\x27GN\x27)") }));
process.exit(0);' 2>/dev/null
  chattr -i $T/db-encryption-key 2>/dev/null; rm -rf $T
}

$M wipe >/dev/null 2>&1
timeout 150 $M up 1 | tail -1
$C enroll 19401 person-zero --face | grep -o 'SOV-[0-9A-F]*' | head -1 > $B/operator_id
timeout 400 $M up 3 | tail -1
for who in "alice 19402" "bob 19403" "carol 19403"; do set -- $who
  for i in $(seq 1 40); do R=$($C enroll $2 $1-palm --face --as $1); echo "$R" | grep -q '"success":true' && break; sleep 10; done
  expect "$1 enrolled" "$R" '"success":true'
  eval "$(echo $1 | tr a-z A-Z)=$(echo "$R" | grep -o 'SOV-[0-9A-F]*' | head -1)"
done
sleep 15   # enrolments replicate

# Everyone says HELLO once so their messaging keys are published and replicate.
for who in "alice 19402" "bob 19403" "carol 19403"; do set -- $who; $C listen $2 $1 3 >/dev/null 2>&1; done
sleep 20

echo "-- plain text is refused on every channel"
$C listen 19403 bob 200 > $B/bob.out 2>&1 &
sleep 8
R=$($C msg 19402 alice "$BOB" "plain hello")
expect "direct message in plain text -> PLAINTEXT_REFUSED" "$R" 'PLAINTEXT_REFUSED'
R=$($C msg 19402 alice "$BOB" "secret hello" --e2e)
expect "direct message, end-to-end -> delivered" "$R" '"success":true'

R=$($C gcreate 19402 alice grp-mesh-0001 "$BOB" "$CAROL")
expect "Alice creates a group with Bob and Carol" "$R" '"success":true'
sleep 15   # membership replicates
R=$($C gsend 19402 alice grp-mesh-0001 "everyone, in clear" --plain)
expect "group message in plain text -> GROUP_PLAINTEXT_REFUSED" "$R" 'GROUP_PLAINTEXT_REFUSED'

echo "-- group chat: per member, end-to-end"
R=$($C gsend 19402 alice grp-mesh-0001 "group secret for Bob and Carol")
expect "Bob (online at node 3) delivered" "$R" "\"delivered\":\[\"$BOB\"\]"
expect "Carol (offline) reported back to the sender's device" "$R" "\"offline\":\[\"$CAROL\"\]"
sleep 3
expect "Bob decrypted the group message" "$(cat $B/bob.out)" 'group secret for Bob and Carol'

echo "-- trade chat: end-to-end, buyer Bob -> seller Alice"
L=$($C list 19402 alice 5 "mesh order"); ORD=$(echo "$L" | grep -o '"order_id":"[^"]*"' | cut -d'"' -f4)
expect "Alice lists an order" "$L" '"success":true'
sleep 15   # the order replicates to node 3
R=$($C xsend 19403 bob "$ORD" "$ALICE" "offer" --plain)
expect "trade chat in plain text -> EXCHANGE_CHAT_PLAINTEXT_REFUSED" "$R" 'EXCHANGE_CHAT_PLAINTEXT_REFUSED'
R=$($C xsend 19403 bob "$ORD" "$ALICE" "I offer 6 GBP")
expect "seller offline -> status offline (the buyer's device keeps it)" "$R" '"status":"offline"'
$C listen 19402 alice 60 > $B/alice.out 2>&1 &
sleep 10
R=$($C xsend 19403 bob "$ORD" "$ALICE" "still 6 GBP?")
expect "seller online at node 2 -> delivered across nodes" "$R" '"status":"delivered"'
sleep 3
expect "Alice decrypted the trade message" "$(cat $B/alice.out)" 'still 6 GBP?'

echo "-- no node holds a message"
for n in 1 2 3; do expect "node $n stores nothing" "$(stored $n)" '"group_messages":0,"trade_messages":0,"queued_messages":0'; done
E=0; for n in 1 2 3; do E=$((E + $(grep -c '\[ERROR\]' $B/n$n/node.log))); done
expect "no ERROR line on any node" "errors=$E" 'errors=0'

pkill -f "mesh_client.js listen" 2>/dev/null
[ $FAIL = 0 ] && echo "ALL PASS" || echo "FAILED"
