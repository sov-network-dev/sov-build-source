#!/bin/bash
# Interactive first-run setup for a SOV node operator.
#
# Runs in the operator's own terminal (unlike the daemon, which has none), so it
# can ask, check the answer on the spot, and say what it did.
set -u

DATA="${SNAP_DATA:-/var/snap/sov-relay/current}"
ENVF="$DATA/.env"
TEMPLATE="${SNAP:-/snap/sov-relay/current}/snap.env.template"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
warn() { printf '\033[33m%s\033[0m\n' "$1"; }
ok()   { printf '\033[32m%s\033[0m\n' "$1"; }
err()  { printf '\033[31m%s\033[0m\n' "$1"; }

echo
bold "SOV Node — operator setup"
echo  "------------------------------------------------------------"
echo

if [ ! -f "$ENVF" ]; then
  if [ -f "$TEMPLATE" ]; then
    cp "$TEMPLATE" "$ENVF" && echo "Created $ENVF from the template."
  else
    touch "$ENVF"
  fi
fi

# ── 1. Sovereign ID ─────────────────────────────────────────────────────────
current_id="$(grep -E '^OPERATOR_SOVEREIGN_ID=' "$ENVF" 2>/dev/null | tail -1 | cut -d= -f2-)"
if [ -n "$current_id" ]; then
  echo "Current operator ID: $current_id"
  printf "Keep it? [Y/n] "; read -r keep
  case "${keep:-Y}" in [Nn]*) current_id="" ;; esac
fi

while [ -z "$current_id" ]; do
  echo
  echo "Your Sovereign ID is the wallet the network pays for your proof of service."
  echo "Enrol on the SOV phone app, then copy it from Profile."
  echo "Form: SOV- followed by 16 hex characters."
  printf "Sovereign ID: "; read -r entered
  entered="$(echo "$entered" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"
  if echo "$entered" | grep -qE '^SOV-[0-9A-F]{16}$'; then
    current_id="$entered"; ok "  Looks right."
  else
    err "  That is not a Sovereign ID. Expected SOV- then 16 hex characters,"
    err "  for example SOV-1A2B3C4D5E6F7A8B. Copy it exactly from Profile."
  fi
done

# ── 2. Bootstrap addresses ──────────────────────────────────────────────────
current_boot="$(grep -E '^SOV_BOOTSTRAP_NODES=' "$ENVF" 2>/dev/null | tail -1 | cut -d= -f2-)"
echo
# No address is needed: node addresses are never published, and a node given none finds the
# network through the public DHT (verified 2026-10-04). An address is still accepted - e.g. an
# operator inviting you to their own node - and is simply tried first.
echo "No network address is needed: just press Enter and the node finds the network by itself."
echo "If another operator gave you their node's address, you can enter it to connect faster."
if [ -n "$current_boot" ]; then
  echo "Currently: $current_boot"
  printf "Keep it? [Y/n] "; read -r kb
  case "${kb:-Y}" in [Nn]*) current_boot="" ;; esac
fi
if [ -z "$current_boot" ]; then
  printf "Network address (optional, press Enter to skip): "; read -r entered_boot
  current_boot="$(echo "$entered_boot" | tr -d '[:space:]')"
fi

# ── 3. Write it back ────────────────────────────────────────────────────────
set_kv() {
  local k="$1" v="$2"
  grep -v -E "^${k}=" "$ENVF" > "${ENVF}.new" 2>/dev/null || true
  echo "${k}=${v}" >> "${ENVF}.new"
  mv "${ENVF}.new" "$ENVF"
}
set_kv OPERATOR_SOVEREIGN_ID "$current_id"
[ -n "$current_boot" ] && set_kv SOV_BOOTSTRAP_NODES "$current_boot"

# ── 3. Host hygiene — the part that keeps the box feeling new ────────────────
# WHY THIS IS HERE. `SOV_NODE_CONSISTENCY_AND_MAINTENANCE_AUDIT.md` §4 lists log
# rotation as satisfied by `pm2-logrotate` (10 MB cap, retain 7, daily). That was
# true when the node ran under pm2. The node now runs as a snap daemon under
# systemd, so pm2-logrotate is not installed and its journal goes to journald —
# which ships with NO size cap. The designed capability was silently lost in the
# pm2 -> snap migration, and nothing replaced it.
#
# Measured 2026-09-26 on the three live nodes before this was added: journald had
# grown to 928 MB, 2.9 GB and 1.5 GB, with 5.4 GB in /var/log on one of them. On a
# 1 GB VPS with a 29 GB disk that is the shape of a slow hang — exactly what
# "launch and forget" is supposed to prevent.
#
# The node cannot fix this from inside: capping journald is host configuration, and
# a confined daemon has no business rewriting /etc. So it belongs here, in the
# operator's own first-run step, where there is a terminal and a sudo prompt.
# Idempotent: safe to re-run, changes nothing if already set.
echo
bold "Host hygiene"
echo "------------------------------------------------------------"

if [ -f /etc/systemd/journald.conf ]; then
  if grep -qE '^\s*SystemMaxUse=' /etc/systemd/journald.conf; then
    ok "journald size cap already set: $(grep -E '^\s*SystemMaxUse=' /etc/systemd/journald.conf | tail -1)"
  else
    echo "journald has no size cap, so logs grow until the disk is full."
    printf "Cap the system journal at 200 MB? [Y/n] "; read -r cap
    case "${cap:-Y}" in
      [Nn]*) warn "Left uncapped. Watch it with: journalctl --disk-usage" ;;
      *)
        if sudo cp /etc/systemd/journald.conf /etc/systemd/journald.conf.bak_sovsetup 2>/dev/null &&
           sudo sed -i 's/^#\?SystemMaxUse=.*/SystemMaxUse=200M/' /etc/systemd/journald.conf &&
           grep -qE '^SystemMaxUse=200M' /etc/systemd/journald.conf; then
          sudo journalctl --vacuum-size=200M >/dev/null 2>&1
          sudo systemctl restart systemd-journald 2>/dev/null
          ok "journald capped at 200 MB and vacuumed (backup: journald.conf.bak_sovsetup)"
        else
          err "Could not set the cap — check /etc/systemd/journald.conf by hand."
        fi
        ;;
    esac
  fi
fi

# Swap presence + swappiness. A 1 GB node with no swap is one memory spike away
# from an OOM kill; a node that swaps eagerly is slow for no reason. This replaces
# the useful half of the old ops/sov_node_harden_memory.sh, whose other half
# configured pm2's max_memory_restart and no longer applies.
SWAP_KB="$(awk '/SwapTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
if [ "${SWAP_KB:-0}" -lt 262144 ]; then
  warn "Swap is $(( ${SWAP_KB:-0} / 1024 )) MB. On a 1 GB node, 1-2 GB of swap"
  warn "prevents an OOM kill during a burst. Add it with:"
  echo  "    sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile"
  echo  "    sudo mkswap /swapfile && sudo swapon /swapfile"
  echo  "    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab"
else
  ok "Swap present: $(( SWAP_KB / 1024 )) MB"
fi
CUR_SW="$(cat /proc/sys/vm/swappiness 2>/dev/null || echo '?')"
if [ "$CUR_SW" != "?" ] && [ "$CUR_SW" -gt 20 ]; then
  echo "vm.swappiness is $CUR_SW (swaps eagerly). 10 is better for a node."
  printf "Set vm.swappiness=10? [Y/n] "; read -r sw
  case "${sw:-Y}" in
    [Nn]*) : ;;
    *) echo 10 | sudo tee /proc/sys/vm/swappiness >/dev/null 2>&1
       grep -q 'vm.swappiness' /etc/sysctl.conf 2>/dev/null || \
         echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf >/dev/null 2>&1
       ok "vm.swappiness=10 (persisted in /etc/sysctl.conf)" ;;
  esac
else
  ok "vm.swappiness=$CUR_SW"
fi

echo
echo "Everything else looks after itself: the node prunes its own history hourly,"
echo "compacts its database (auto_vacuum=INCREMENTAL), reaps dead peers, and"
echo "back-fills any table that drifts from its peers. Nothing here recurs."

chmod 600 "$ENVF" 2>/dev/null || true

echo
ok "Saved to $ENVF"
echo "  operator : $current_id"
[ -n "$current_boot" ] && echo "  network address: $current_boot" || echo "  network address: none - the node finds the network by itself"
echo
echo "Start the node and watch it join:"
echo "  sudo snap restart sov-relay"
echo "  sudo snap logs -f sov-relay.sov-relay"
echo
