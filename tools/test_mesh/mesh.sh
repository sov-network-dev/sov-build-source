#!/bin/bash
# mesh.sh — an ISOLATED multi-node SOV test mesh, for proving protocol changes before the live fleet.
#
# Built 2026-10-03 for Phase 2 of docs/SOV_CAPABILITY_TIERED_COMPUTE.md, which says delegated dedup
# "must be built and proven on isolated nodes before touching the live fleet". Until now no harness
# ran several real node processes; changes were proven in-process with fake meshes, or live.
#
# ISOLATION IS PHYSICAL, NOT CONFIGURED. Every node runs inside the Linux network namespace
# `sovmesh`, whose only interface is loopback. Whatever a node's config, DHT code, pointer mirrors
# or bootstrap list says, it has no route to the live fleet, the DHT, DNS or any mirror — verified
# at `up` time and refused if not. The nodes reach each other on 127.0.0.1.
#
# Runs in WSL as root:   wsl -u root -- bash /opt/sov/tools/test_mesh/mesh.sh <cmd>
#   up <N> [light-node-numbers...]   build the app copy, start N nodes (node 1 = genesis);
#                                    listed nodes are forced to the LIGHT tier
#   down                             stop every node and remove the namespace (data kept)
#   wipe                             down + delete all node data
#   status                           per node: pid, alive, boot step, peers
#   exec <cmd...>                    run a command inside the namespace (e.g. the mesh client)
#   app                              (re)sync the app copy only
#
# The node source is taken from the REPO tree (wallet/windows/sov-node/src), i.e. what you are
# about to ship, with the snap's own runtime (node 20.20.0) and vendored native modules.
set -uo pipefail
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

NS=sovmesh
BASE=/root/sov-mesh
APP=$BASE/app
REPO=${MESH_REPO:-/opt/sov/wallet/windows/sov-node}   # MESH_REPO: run a control on other source
VENDOR=/root/sov-build/vendor/node_modules
NODE=/usr/local/bin/node
SEED_FILE=$BASE/cancelable-seed          # one biometric-transform seed for the whole test mesh
port() { echo $(( $1 + $2 )); }          # base + node number
SOV_BASE=19400; SYNC_BASE=19700; DISC_BASE=19000; DASH_BASE=19100

ns_up() {
  ip netns list | grep -qw $NS || { ip netns add $NS && ip netns exec $NS ip link set lo up; }
  # Refuse to run anything unless the namespace really is cut off.
  local ifs; ifs=$(ip netns exec $NS ip -o link | awk -F': ' '{print $2}' | tr '\n' ' ')
  [ "$ifs" = "lo " ] || { echo "REFUSING: namespace $NS has interfaces [$ifs], expected only lo"; exit 1; }
  if ip netns exec $NS timeout 3 bash -c 'echo > /dev/tcp/192.0.2.1/7771' 2>/dev/null; then
    echo "REFUSING: namespace $NS can reach the live fleet"; exit 1; fi
  echo "namespace $NS: loopback only, live fleet unreachable — OK"
}

app_sync() {
  mkdir -p $APP
  rsync -a --delete --exclude='*.bak*' $REPO/src/ $APP/src/
  cp $REPO/package.json $APP/package.json 2>/dev/null || true
  ln -sfn $VENDOR $APP/node_modules
  ROOT=$($NODE -e 'const m=require(process.argv[1]+"/src/release/source_root.js");const r=m.sourceRoot(process.argv[1],{include:["src"]});console.log(r.root.slice(0,16)+" / "+(r.fileCount??r.files??r.count))' $APP)
  echo "app copy: $APP  (source root $ROOT)"
}

node_env() {  # $1 = node number, $2 = light?(0/1)
  local i=$1
  echo SOV_DATA_DIR=$BASE/n$i/data SNAP_COMMON=$BASE/n$i/data \
       SOV_PORT=$(port $SOV_BASE $i) SYNC_PORT=$(port $SYNC_BASE $i) \
       DISCOVERY_PORT=$(port $DISC_BASE $i) DASHBOARD_PORT=$(port $DASH_BASE $i) \
       SOV_PUBLIC_HOST=127.0.0.1 SOV_NO_TLS=1 SOV_NO_TRAY=1 NODE_ENV=development \
       SOV_DHT_NETWORK=sov-test-mesh PALM_CANCELABLE_SEED=$(cat $SEED_FILE) \
       SOV_STORAGE_HIGH_WATER=$([ "$2" = 1 ] && echo 0 || echo 0.85)
}

# 1.4.97: nodes take unsigned state only from TRUSTED nodes (src/network/trusted_nodes.js). The mesh
# plays the fleet: every mesh node trusts every other mesh node, except those listed in UNTRUSTED="4 5"
# (a stranger's node, e.g. the desktop-node case). Ids come from each node's node_public.pem.
write_trust() {
  local ids="" d i
  for d in $BASE/n*; do [ -s $d/data/node_public.pem ] || continue; i=${d##*n}
    [[ " ${UNTRUSTED:-} " == *" $i "* ]] && continue
    ids="$ids\"$($NODE -e 'const c=require("crypto");process.stdout.write(c.createHash("sha256").update(Buffer.from(require("fs").readFileSync(process.argv[1],"utf8").trim(),"hex")).digest("hex"))' $d/data/node_public.pem)\","; done
  for d in $BASE/n*; do mkdir -p $d/data; echo "[${ids%,}]" > $d/data/trusted_nodes.json; done
}

start_node() {  # $1 number, $2 light, $3 extra env
  local i=$1 d=$BASE/n$1
  mkdir -p $d/data
  : > $d/node.log   # truncate BEFORE launch, or the boot check can match the previous run's [9/9]
  # setsid: the node must outlive this wsl session (WSL kills a session's process group on exit;
  # keep a separate `wsl -- sleep infinity` open too, or the whole distro idles down).
  # `ip netns exec` forks, so $! is not the node — the node writes its own pid via exec.
  # The WHOLE subshell is redirected and exec'd through, so nothing is left holding this
  # script's stdout: a lingering bash on that pipe kept `mesh.sh up | tail` from ever seeing
  # EOF, and `timeout` cannot reach a grandchild.
  write_trust
  ( cd $APP && exec setsid ip netns exec $NS env $(node_env $i $2) $3 \
      bash -c "echo \$\$ > $d/pid; exec $NODE src/index.js" ) >> $d/node.log 2>&1 < /dev/null &
  sleep 1
  local wrote=''
  for t in $(seq 1 90); do [ -z "$wrote" ] && [ -s $d/data/node_public.pem ] && { write_trust; wrote=1; }   # 1.4.97: trusted before it peers
    grep -q '\[9/9\]' $d/node.log 2>/dev/null && { write_trust; echo "  node $i up (pid $(cat $d/pid), tier $([ "$2" = 1 ] && echo LIGHT || echo full), wss :$(port $SOV_BASE $i), mesh :$(port $SYNC_BASE $i))"; return 0; }
    kill -0 $(cat $d/pid) 2>/dev/null || { echo "  node $i DIED during boot — tail:"; tail -15 $d/node.log; return 1; }; sleep 1; done
  echo "  node $i did not reach [9/9] in 90 s — tail:"; tail -15 $d/node.log; return 1
}

cmd=${1:-status}; shift || true
case "$cmd" in
  app) app_sync ;;
  up)
    N=${1:-3}; shift || true; LIGHT=" $* "
    ns_up; app_sync; mkdir -p $BASE
    [ -s $SEED_FILE ] || $NODE -e 'console.log(require("crypto").randomBytes(32).toString("hex"))' > $SEED_FILE
    if [ -f $BASE/n1/pid ] && kill -0 $(cat $BASE/n1/pid) 2>/dev/null; then echo "  node 1 already running"
    else echo "starting genesis node 1"; start_node 1 $([[ "$LIGHT" == *" 1 "* ]] && echo 1 || echo 0) "SOV_GENESIS=1" || exit 1; fi   # 1.4.82: genesis is declared
    OP=$(cat $BASE/operator_id 2>/dev/null || true)
    if [ "$N" -gt 1 ] && [ -z "$OP" ]; then
      echo "  joiners need an ENROLLED operator: enrol one on node 1 first:"
      echo "    mesh.sh exec node $(dirname $0)/mesh_client.js enroll 19401 operator --face && rerun 'mesh.sh up $N $*'"
      exit 0
    fi
    for i in $(seq 2 $N); do
      [ -f $BASE/n$i/pid ] && kill -0 $(cat $BASE/n$i/pid) 2>/dev/null && { echo "  node $i already running"; continue; }
      start_node $i $([[ "$LIGHT" == *" $i "* ]] && echo 1 || echo 0) \
        "$([ "${NOBOOT:-0}" = 1 ] || echo "SOV_BOOTSTRAP_NODES=127.0.0.1 BOOTSTRAP_SEEDS=127.0.0.1:$(port $SYNC_BASE 1)") OPERATOR_SOVEREIGN_ID=$OP $(eval echo \${EXTRA_ENV_$i:-})" || exit 1   # NOBOOT=1: a joiner told nothing (the desktop-node case)
    done ;;
  status)
    for d in $BASE/n*; do [ -d "$d" ] || continue; i=${d##*n}; p=$(cat $d/pid 2>/dev/null)
      alive=$(kill -0 "$p" 2>/dev/null && echo alive || echo DEAD)
      echo "node $i pid $p $alive | boot $(grep -o '\[[0-9]/9\]' $d/node.log | tail -1) | errors $(grep -c '\[ERROR\]' $d/node.log) | $(grep -oE 'peers?[=: ]+[0-9]+' $d/node.log | tail -1)"; done ;;
  exec) ns_up >/dev/null; cd "$(dirname "$0")" && ip netns exec $NS "$@" ;;
  down)
    for d in $BASE/n*; do [ -f $d/pid ] && kill $(cat $d/pid) 2>/dev/null; done; sleep 2
    for d in $BASE/n*; do [ -f $d/pid ] && kill -9 $(cat $d/pid) 2>/dev/null; rm -f $d/pid; done
    ip netns del $NS 2>/dev/null; echo "mesh down (data kept in $BASE)" ;;
  wipe) "$0" down; rm -rf $BASE/n* $BASE/operator_id $SEED_FILE; echo "mesh data wiped" ;;
  *) echo "usage: mesh.sh up <N> [light...] | down | wipe | status | exec <cmd...> | app"; exit 2 ;;
esac
