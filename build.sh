#!/bin/bash
#
# Build "A Certain Sound" into a double-clickable .app bundle.
#
#   ./build.sh          # fast debug build, then launch
#   ./build.sh release  # optimized build for everyday use
#   ./build.sh release nolaunch
#
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-debug}"
LAUNCH="${2:-launch}"
APP_NAME="Crocus"
APP="dist/${APP_NAME}.app"

echo "▶ Building ($CONFIG)…"
swift build -c "$CONFIG"

BIN=".build/${CONFIG}/ACertainSound"
[ -f "$BIN" ] || { echo "✗ Build product not found at $BIN"; exit 1; }

echo "▶ Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "$BIN" "${APP}/Contents/MacOS/${APP_NAME}"
cp Info.plist "${APP}/Contents/Info.plist"
[ -f AppIcon.icns ] && cp AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"

# Ad-hoc sign so macOS remembers granted permissions across rebuilds.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "✓ Built ${APP}"

if [ "$LAUNCH" = "launch" ]; then
    echo "▶ Launching…"
    open "$APP"
fi
