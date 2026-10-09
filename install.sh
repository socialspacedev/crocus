#!/bin/bash
#
# Install Crocus into /Applications, building it from source on this Mac.
#
#   ./install.sh
#
# Building it yourself is the point, not a compromise. macOS only quarantines
# software that arrives from a browser, so an app you compile here opens on a
# double-click — no Gatekeeper warning, no trip through System Settings, and no
# paid Apple Developer certificate anywhere in the chain.
#
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Crocus"
DEST="/Applications/${APP_NAME}.app"

say()  { printf '%s\n' "$*"; }
fail() { printf '✗ %s\n' "$*" >&2; exit 1; }

# --- 1. Toolchain -----------------------------------------------------------
# Swift ships with the Xcode Command Line Tools, which are a free download but
# not present on a fresh Mac. Say so plainly rather than failing on `swift`.
if ! command -v swift >/dev/null 2>&1 || ! xcode-select -p >/dev/null 2>&1; then
    say "Crocus needs the Xcode Command Line Tools to build — a free Apple download."
    say ""
    say "  Run this, accept the prompt, let it finish, then run ./install.sh again:"
    say ""
    say "      xcode-select --install"
    say ""
    exit 1
fi

# --- 2. macOS version -------------------------------------------------------
MIN_MAJOR=14
MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$MAJOR" -lt "$MIN_MAJOR" ]; then
    fail "Crocus needs macOS ${MIN_MAJOR} (Sonoma) or newer — this Mac is on $(sw_vers -productVersion)."
fi

# --- 3. Don't overwrite a running copy --------------------------------------
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    say "▶ Crocus is running — quitting it first…"
    osascript -e "tell application \"${APP_NAME}\" to quit" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
        sleep 0.5
    done
    pgrep -x "$APP_NAME" >/dev/null 2>&1 && fail "Couldn't quit Crocus — quit it by hand and try again."
fi

# --- 4. Build ---------------------------------------------------------------
say "▶ Building Crocus (this takes a minute the first time)…"
./build.sh release nolaunch

[ -d "dist/${APP_NAME}.app" ] || fail "Build didn't produce dist/${APP_NAME}.app"

# --- 5. Install -------------------------------------------------------------
say "▶ Installing to ${DEST}…"
if ! rm -rf "$DEST" 2>/dev/null || ! ditto "dist/${APP_NAME}.app" "$DEST" 2>/dev/null; then
    say "  /Applications isn't writable by this account — retrying with sudo."
    sudo rm -rf "$DEST"
    sudo ditto "dist/${APP_NAME}.app" "$DEST"
fi

say ""
say "✓ Crocus is installed. Open it from Applications or Spotlight."
say "  First stop: Settings (⌘,) — set your show name and station."
say ""
