#!/usr/bin/env bash
# scripts/embed_macos_node.sh
# Embeds the bundled full-node payload (Node.js runtime + sov-node + native
# modules rebuilt for macOS) into a built "SOV Node.app". Run AFTER
# `flutter build macos --release` — on a macOS host or the macOS CI runner.
#
# Why a post-build script instead of an Xcode "Copy Files" phase: editing
# project.pbxproj by hand is fragile; a deterministic copy step is robust and
# verifiable. NodeController._locate() on macOS looks in
# <App>.app/Contents/Resources, which is where this places node/ + sov-node/.
#
# Usage:  scripts/embed_macos_node.sh [path/to/SOV Node.app]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO_ROOT/wallet/windows/sov-node"          # platform-independent src + package.json

# Locate the built .app if not given.
APP="${1:-}"
if [ -z "$APP" ]; then
  APP="$(find "$REPO_ROOT/build/macos" -maxdepth 4 -name '*.app' -path '*Release*' 2>/dev/null | head -1)"
fi
[ -n "$APP" ] && [ -d "$APP" ] || { echo "::error::no .app found (pass it as arg 1)"; exit 1; }
RES="$APP/Contents/Resources"
echo "App:       $APP"
echo "Resources: $RES"

# 1) Rebuild sov-node's native deps (better-sqlite3-multiple-ciphers) for macOS.
echo "[1/4] npm ci (rebuild native better-sqlite3 for darwin)…"
( cd "$SRC" && rm -rf node_modules && ( npm ci --omit=dev || npm install --omit=dev ) )

# 2) Copy sov-node (src + package.json + macOS node_modules) into Resources.
echo "[2/4] copying sov-node payload…"
rm -rf "$RES/sov-node"
mkdir -p "$RES/sov-node"
cp -R "$SRC/src" "$SRC/package.json" "$SRC/node_modules" "$RES/sov-node/"

# 3) Bundle a macOS node runtime so the app is self-contained.
echo "[3/4] bundling macOS node runtime…"
mkdir -p "$RES/node"
NODE_BIN="$(command -v node || true)"
[ -n "$NODE_BIN" ] || { echo "::error::node not on PATH on the build host"; exit 1; }
cp "$NODE_BIN" "$RES/node/node"
chmod +x "$RES/node/node"

# 4) Smoke test: the encrypted-disc native module must load under the bundled node.
echo "[4/4] smoke test (native AES disc under bundled node)…"
"$RES/node/node" -e "const D=require('$RES/sov-node/node_modules/better-sqlite3-multiple-ciphers');const db=new D(':memory:');db.pragma(\"cipher='sqlcipher'\");db.exec('CREATE TABLE t(x)');console.log('macOS native AES disc OK');"

echo "✓ macOS node payload embedded into $RES (node/ + sov-node/)"
