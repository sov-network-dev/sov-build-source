#!/bin/bash
# scenario_allocation.sh — node 1.4.94 D53: the user-facing "SOV Vault" (allocations) is now a REAL ledger
# holding, replicated to every node, claimed only by a SIGNATURE from the claim key (never the broadcast hash).
# Built-in negative controls: the locked funds cannot be spent by the donor; the allocation cannot be claimed
# with the public claim key alone; a second claim is refused.
#   wsl -u root -- bash /opt/sov/tools/test_mesh/scenario_allocation.sh
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd); M="bash $D/mesh.sh"; B=/root/sov-mesh
NS="ip netns exec sovmesh"
C="$NS env NODE_PATH=/root/sov-build/vendor/node_modules /usr/local/bin/node $D/mesh_client.js"
FAIL=0
pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1"; FAIL=1; }
bal() { $C bal 1940$1 "$2" | python3 -c "import sys,json;print(json.load(sys.stdin).get('$2'))"; }
supply() { $NS curl -s -m 8 http://127.0.0.1:1900$1/economy/snapshot | python3 -c "import sys,json;d=json.load(sys.stdin);i=d['invariant'];print(i.get('grand_total_seeds'),i['ok'])"; }
jget() { python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('$1',''))"; }

echo "source under test: ${MESH_REPO:-repo tree}"
$M wipe >/dev/null 2>&1
timeout 150 $M up 1 | tail -1
$C enroll 19401 person-zero --face | grep -o 'SOV-[0-9A-F]*' | head -1 > $B/operator_id
timeout 400 $M up 3 | tail -1
for who in "donor 19401" "heir 19402"; do set -- $who
  for i in $(seq 1 40); do R=$($C enroll $2 $1-palm --face --as $1); echo "$R" | grep -q '"success":true' && break; sleep 10; done
  echo "  enrolled $1: $(echo "$R" | head -c 90)"; eval "${1}_id=$(echo "$R" | grep -o 'SOV-[0-9A-F]*' | head -1)"
done
sleep 20
SUP0=$(supply 1)
D0=$(bal 1 donor); echo "  donor start balance: $D0 seeds"
[ "$D0" = "1000000000" ] && pass "donor funded (1000 SOV)" || fail "donor not funded ($D0)"

# ── CREATE: lock 600 SOV to a claim key ───────────────────────────────────────
CK="river-stone-lantern-7"
CREATE=$($C alloc-create 19401 donor 600 "$CK")
AID=$(echo "$CREATE" | jget allocation_id)
echo "  create: $CREATE"
[ -n "$AID" ] && [ "$(echo "$CREATE" | jget success)" = "True" ] && pass "allocation created ($AID)" || { fail "create failed"; AID=none; }

sleep 8
# ── LOCK IS REAL: 600 SOV left the donor's spendable balance ──────────────────
D1=$(bal 1 donor)
[ "$D1" = "400000000" ] && pass "donor spendable dropped by the locked 600 SOV ($D0 -> $D1)" || fail "lock did not move money ($D0 -> $D1)"
# the donor CANNOT spend the locked funds: a 500 SOV transfer must be refused (only 400 spendable)
SPEND=$($C tx 19401 donor "$heir_id" 500 2>/dev/null | jget error)
echo "$SPEND" | grep -qiE "insufficient|LEDGER_INSUFFICIENT" && pass "donor cannot spend the locked funds (500 SOV refused: $SPEND)" || fail "donor spent locked funds (control for the old soft-counter bug): $SPEND"

# ── REPLICATED: the allocation exists on all three nodes ──────────────────────
for n in 1 2 3; do
  ST=$($C alloc-list 1940$n donor | python3 -c "import sys,json;d=json.load(sys.stdin);a=[x for x in d.get('allocations',[]) if x.get('id')=='$AID'];print(a[0]['status'] if a else 'MISSING')" 2>/dev/null)
  [ "$ST" = "locked" ] && pass "node $n holds the allocation (status locked)" || fail "node $n does not hold the allocation ($ST)"
done

# ── CLAIM NEEDS THE KEY: the public claim key alone cannot claim ──────────────
CPUB=$($C alloc-claim 19402 heir "$AID" "$CK" --pubkeyonly | jget error)
echo "$CPUB" | grep -qi "invalid claim key" && pass "claim with the public key alone is refused ($CPUB)" || fail "claim succeeded without the claim key: $CPUB"

# ── CLAIM WITH THE REAL KEY: paid from the holding ────────────────────────────
H0=$(bal 1 heir)
CLAIM=$($C alloc-claim 19402 heir "$AID" "$CK")
echo "  claim: $CLAIM"
[ "$(echo "$CLAIM" | jget success)" = "True" ] && pass "claim with the real key succeeds" || fail "claim with the real key failed: $CLAIM"
sleep 10
H1=$(bal 1 heir)
[ "$H1" = "$((H0 + 600000000))" ] && pass "heir received 600 SOV ($H0 -> $H1)" || fail "heir balance wrong ($H0 -> $H1)"

# ── CLAIM ONCE: a second claim is refused and pays nothing more ───────────────
HB=$(bal 1 heir)
AGAIN=$($C alloc-claim 19402 heir "$AID" "$CK" | jget error)
sleep 6
HC=$(bal 1 heir)
if [ -n "$AGAIN" ] && [ "$HC" = "$HB" ]; then pass "a second claim is refused, no second payment ($AGAIN; heir $HB -> $HC)"
else fail "double claim paid again ($AGAIN; heir $HB -> $HC)"; fi

# ── CANCEL returns the holding to the donor ───────────────────────────────────
D2=$(bal 1 donor)
C2=$($C alloc-create 19401 donor 200 "another-key-9" | jget allocation_id)
sleep 6
$C alloc-cancel 19401 donor "$C2" >/dev/null
sleep 8
D3=$(bal 1 donor)
[ "$D3" = "$D2" ] && pass "cancel returned the locked 200 SOV to the donor ($D2 -> lock -> $D3)" || fail "cancel did not restore the donor ($D2 -> $D3)"

# ── SUPPLY invariant exact on every node throughout ───────────────────────────
for n in 1 2 3; do S=$(supply $n); echo "$S" | grep -q "50000000000000 True" && pass "node $n supply exact + ok ($S)" || fail "node $n supply off ($S)"; done

$M down >/dev/null 2>&1
[ $FAIL = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
