#!/bin/bash
# SOV Network Relay Node — startup script for snap
set -e

DATA_DIR="${SNAP_DATA:-/var/snap/sov-relay/current}"
mkdir -p "$DATA_DIR"

# Bootstrap .env on first run
if [ ! -f "$DATA_DIR/.env" ]; then
    echo "[sov-relay] First run: initialising .env from template"
    cp "$SNAP/snap.env.template" "$DATA_DIR/.env"
fi

# Load environment from .env
set -a
# shellcheck source=/dev/null
source "$DATA_DIR/.env" 2>/dev/null || true
set +a

# Not set up yet? Say so and stop CLEANLY (exit 0) instead of letting the node refuse
# with exit 1. `snap install` starts this daemon at once, before the operator has run
# setup; exiting 1 made systemd restart it five times in a few seconds and then lock
# it out ("Start request repeated too quickly"), so the `snap restart` that setup tells
# the operator to run failed if it came within ~10 s. Found on a real install for the
# operator tutorial, 2026-10-04. Only a FRESH node (no database yet) is held here; an
# existing node is never stopped by this check.
if [ -z "${OPERATOR_SOVEREIGN_ID:-}" ] && [ "${SOV_GENESIS:-}" != "1" ] && [ ! -f "$DATA_DIR/node.db" ]; then
    echo "[sov-relay] Not set up yet: this node needs its operator's SOV ID before it can join."
    echo "[sov-relay] Run:  sudo snap run sov-relay.setup    then:  sudo snap restart sov-relay"
    exit 0
fi

# Version comes from the snap itself, never a hand-maintained constant.
# snapd sets SNAP_VERSION to the installed revision's version, so the banner
# cannot drift the way a hardcoded value did (it once read 1.2.9 while 1.3.2
# was running, leaving operators with no way to tell what they had).
export SOV_RELAY_VERSION="${SNAP_VERSION:-dev}"

# Always override data dir to the snap-managed writable location
export SOV_DATA_DIR="$DATA_DIR"

# Change to snap read-only root (source lives here)
cd "$SNAP"

exec "$SNAP/bin/node" src/index.js
