#!/usr/bin/env bash
# scripts/embed_linux_node.sh
# Embeds the bundled full-node payload (Node.js runtime + sov-node + native
# modules rebuilt for Linux) into the built Flutter Linux bundle. Run AFTER
# `flutter build linux --release` — on a Linux host or the Linux CI runner.
#
# NodeController._locate() on Linux looks in <bundle>/lib (see node_controller.dart
# roots: p.join(exeDir,'lib')), so node/ + sov-node/ are placed there.
#
# Usage:  scripts/embed_linux_node.sh [path/to/bundle]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO_ROOT/wallet/windows/sov-node"          # platform-independent src + package.json

BUNDLE="${1:-}"
if [ -z "$BUNDLE" ]; then
  BUNDLE="$(find "$REPO_ROOT/build/linux" -maxdepth 4 -type d -name bundle -path '*release*' 2>/dev/null | head -1)"
fi
[ -n "$BUNDLE" ] && [ -d "$BUNDLE" ] || { echo "::error::no Linux bundle found (pass it as arg 1)"; exit 1; }
LIB="$BUNDLE/lib"
echo "Bundle: $BUNDLE"
echo "Lib:    $LIB"

# 1) Rebuild sov-node native deps (better-sqlite3-multiple-ciphers) for Linux.
echo "[1/4] npm ci (rebuild native better-sqlite3 for linux)…"
( cd "$SRC" && rm -rf node_modules && ( npm ci --omit=dev || npm install --omit=dev ) )

# 2) Copy sov-node (src + package.json + Linux node_modules) into lib/.
echo "[2/4] copying sov-node payload…"
rm -rf "$LIB/sov-node"
mkdir -p "$LIB/sov-node"
# src/ is copied with the SAME exclusions source_root.js isExcludedFile() applies, so the
# bundle ships exactly the files the fingerprint covers. Measured 2026-09-26: a plain `cp -R`
# shipped 392 files where the root hashes 60 - 332 `.bak_*` files, 20 MB of old code, to every
# Linux citizen, while windows/CMakeLists.txt had excluded them all along. Keep these two
# lists in step with source_root.js; a file that ships but is not hashed is a file nobody
# verifies.
if command -v rsync >/dev/null 2>&1; then
  rsync -a \
    --exclude '*.bak*' --exclude '*.broken*' --exclude '*.orig*' --exclude '*.rej*' \
    --exclude '*~' --exclude '*.tmp' --exclude '*.log' \
    --exclude '*.db' --exclude '*.db-wal' --exclude '*.db-shm' \
    --exclude '*.pyc' --exclude '*.snap' --exclude '.DS_Store' \
    --exclude '__pycache__' --exclude '.pytest_cache' \
    "$SRC/src/" "$LIB/sov-node/src/"
else
  cp -R "$SRC/src" "$LIB/sov-node/src"
  find "$LIB/sov-node/src" -type f \( -name '*.bak*' -o -name '*.broken*' -o -name '*.orig*' \
    -o -name '*.rej*' -o -name '*~' -o -name '*.tmp' -o -name '*.log' -o -name '*.db' \
    -o -name '*.db-wal' -o -name '*.db-shm' -o -name '*.pyc' -o -name '*.snap' \
    -o -name '.DS_Store' \) -delete
  find "$LIB/sov-node/src" -type d \( -name '__pycache__' -o -name '.pytest_cache' \) -prune -exec rm -rf {} + 2>/dev/null || true
fi
cp -R "$SRC/package.json" "$SRC/node_modules" "$LIB/sov-node/"

# 3) Bundle a Linux node runtime so the app is self-contained.
echo "[3/4] bundling linux node runtime…"
mkdir -p "$LIB/node"
NODE_BIN="$(command -v node || true)"
[ -n "$NODE_BIN" ] || { echo "::error::node not on PATH on the build host"; exit 1; }
cp "$NODE_BIN" "$LIB/node/node"
chmod +x "$LIB/node/node"

# 4) Smoke test: the encrypted-disc native module must load under the bundled node.
echo "[4/4] smoke test (native AES disc under bundled node)…"
"$LIB/node/node" -e "const D=require('$LIB/sov-node/node_modules/better-sqlite3-multiple-ciphers');const db=new D(':memory:');db.pragma(\"cipher='sqlcipher'\");db.exec('CREATE TABLE t(x)');console.log('linux native AES disc OK');"

echo "✓ Linux node payload embedded into $LIB (node/ + sov-node/)"
