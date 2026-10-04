#!/usr/bin/env bash
# scripts/make_appimage.sh
# Packs the built Flutter Linux bundle (with the embedded full node) into ONE
# portable SovNode-x86_64.AppImage — the Linux equivalent of our Windows
# load-in-place portable. AppImage IS this pattern: a self-mounting single file
# that runs in place, no install, no root, no package manager.
#
# Run AFTER `flutter build linux --release` + `scripts/embed_linux_node.sh`,
# on a Linux host or the Linux CI runner.
#
# Usage:  scripts/make_appimage.sh [version]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-1.0.0}"
BIN="sov_node"
APPID="network.sov.node"
DIST="$REPO_ROOT/dist"
mkdir -p "$DIST"

BUNDLE="$(find "$REPO_ROOT/build/linux" -maxdepth 4 -type d -name bundle -path '*release*' 2>/dev/null | head -1)"
[ -n "$BUNDLE" ] && [ -d "$BUNDLE" ] || { echo "::error::no Linux release bundle found"; exit 1; }
echo "Bundle: $BUNDLE"

# ── Build the AppDir ───────────────────────────────────────────────────────────
APPDIR="$(mktemp -d)/SovNode.AppDir"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/share/applications" "$APPDIR/usr/share/icons/hicolor/256x256/apps"

# The whole Flutter bundle (exe + lib/ + data/ + node/ + sov-node/) → usr/bin
cp -R "$BUNDLE/." "$APPDIR/usr/bin/"

# Icon (PNG). Prefer the brand icon; fall back to the Flutter linux icon if present.
ICON_SRC=""
for c in "$REPO_ROOT/sov-icon-v1-transparent.png" "$REPO_ROOT/assets/tray_icon.png" \
         "$REPO_ROOT/linux/runner/resources/app_icon.png"; do
  [ -f "$c" ] && { ICON_SRC="$c"; break; }
done
if [ -n "$ICON_SRC" ]; then
  cp "$ICON_SRC" "$APPDIR/usr/share/icons/hicolor/256x256/apps/$APPID.png"
  cp "$ICON_SRC" "$APPDIR/$APPID.png"
else
  # 1x1 placeholder so appimagetool doesn't fail on a missing icon
  printf '\x89PNG\r\n\x1a\n' > "$APPDIR/$APPID.png"
fi

# .desktop entry
cat > "$APPDIR/usr/share/applications/$APPID.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=SOV Node
Exec=$BIN
Icon=$APPID
Categories=Network;Finance;
Terminal=false
EOF
cp "$APPDIR/usr/share/applications/$APPID.desktop" "$APPDIR/$APPID.desktop"

# AppRun: set lib path + working dir, then exec the Flutter binary in place.
cat > "$APPDIR/AppRun" <<EOF
#!/bin/bash
HERE="\$(dirname "\$(readlink -f "\$0")")"
cd "\$HERE/usr/bin"
export LD_LIBRARY_PATH="\$HERE/usr/bin/lib:\$LD_LIBRARY_PATH"
exec "\$HERE/usr/bin/$BIN" "\$@"
EOF
chmod +x "$APPDIR/AppRun"

# ── Fetch appimagetool (no FUSE in CI → extract-and-run) ───────────────────────
TOOL="$(mktemp -d)/appimagetool"
echo "fetching appimagetool…"
curl -fsSL -o "$TOOL" \
  "https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage"
chmod +x "$TOOL"

OUT="$DIST/SovNode-${VERSION}-x86_64.AppImage"
echo "packing → $OUT"
ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$TOOL" "$APPDIR" "$OUT"

ls -la "$OUT"
echo "✓ Linux portable AppImage built: $OUT (load-in-place, no install)"
