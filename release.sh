#!/bin/bash
#
# Cut a release: build Crocus, sign it, and package it as a DMG for download.
#
#   ./release.sh
#
# Signing and notarisation are optional and read from the environment, so this
# produces a working DMG whether or not there's a paid Apple Developer account
# behind it:
#
#   CROCUS_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#   CROCUS_NOTARY_PROFILE="crocus"   # from: xcrun notarytool store-credentials
#
# With neither set it ad-hoc signs, which is fine — it just means anyone who
# downloads the DMG has to clear Gatekeeper by hand the first time. The script
# says so at the end rather than leaving you to find out from a user.
#
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Crocus"
APP="dist/${APP_NAME}.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
DMG="dist/${APP_NAME}-${VERSION}.dmg"
STAGE="dist/dmg-staging"

IDENTITY="${CROCUS_SIGN_IDENTITY:-}"
NOTARY="${CROCUS_NOTARY_PROFILE:-}"

say() { printf '%s\n' "$*"; }

# --- 1. Build ---------------------------------------------------------------
say "▶ Building ${APP_NAME} ${VERSION}…"
./build.sh release nolaunch

# --- 2. Sign ----------------------------------------------------------------
# --options runtime (hardened runtime) and --timestamp are both *required* by
# notarisation, so they go on whenever there's a real identity to sign with.
if [ -n "$IDENTITY" ]; then
    say "▶ Signing with: ${IDENTITY}"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
else
    say "▶ No CROCUS_SIGN_IDENTITY set — ad-hoc signing."
    codesign --force --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"

# --- 3. Disk image ----------------------------------------------------------
# A staging folder with the app beside an /Applications symlink: the drag-to-
# install layout every Mac user already knows.
say "▶ Building ${DMG}…"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "${STAGE}/${APP_NAME}.app"
ln -s /Applications "${STAGE}/Applications"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGE" \
               -ov -format UDZO "$DMG"
rm -rf "$STAGE"

# --- 4. Sign the image too --------------------------------------------------
if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" "$DMG"
fi

# --- 5. Notarise ------------------------------------------------------------
# Stapling matters: it attaches the ticket to the DMG so it validates on a Mac
# that's offline, or behind a firewall, on first launch.
if [ -n "$NOTARY" ] && [ -n "$IDENTITY" ]; then
    say "▶ Notarising (this takes a few minutes)…"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
elif [ -n "$NOTARY" ]; then
    say "⚠ CROCUS_NOTARY_PROFILE is set but CROCUS_SIGN_IDENTITY isn't —"
    say "  notarisation needs a Developer ID signature. Skipping."
fi

# --- 6. What will a downloader actually see? --------------------------------
say ""
say "✓ ${DMG}  ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
say ""
if [ -n "$NOTARY" ] && [ -n "$IDENTITY" ]; then
    say "  Signed and notarised — it will open on a double-click."
elif [ -n "$IDENTITY" ]; then
    say "  Signed but not notarised. macOS will still warn on download;"
    say "  set CROCUS_NOTARY_PROFILE to finish the job."
else
    say "  Ad-hoc signed. Anyone downloading this will need to clear Gatekeeper"
    say "  once: open it, get refused, then System Settings ▸ Privacy & Security"
    say "  ▸ Open Anyway. Worth saying so on the download page."
    say ""
    say "  Building from source with ./install.sh avoids that entirely."
fi
say ""
