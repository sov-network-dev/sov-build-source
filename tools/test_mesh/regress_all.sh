#!/bin/bash
# regress_all.sh [wait-for-log]: run EVERY mesh scenario on the repo tree, one after another,
# each to docs/ledger/RUN_regress_<name>.log, then print a one-line verdict per scenario.
# If a log path is given, first wait until that run has finished (the mesh is shared).
D=$(cd "$(dirname "$0")" && pwd); OUT=/opt/sov/docs/ledger
if [ -n "${1:-}" ]; then until tr -d '\r' < "$1" 2>/dev/null | grep -qE "ALL PASS|SOME FAILED"; do sleep 20; done; fi
for s in admission nostore presence delegation genesis_cert_log nogenesis doublespend ledger_paths unsigned_hello discovery exposure ghost allocation owner_auth serving_node governance; do
  f="$D/scenario_$s.sh"; [ -f "$f" ] || continue
  timeout 2700 bash "$f" > "$OUT/RUN_regress_$s.log" 2>&1
  v=$(tr -d '\r' < "$OUT/RUN_regress_$s.log" | grep -E "ALL PASS|SOME FAILED|^FAILED|FAIL" | tail -1)
  echo "$s: ${v:-no verdict line (read the log)}"
done
echo "REGRESSION DONE"
