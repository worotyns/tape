#!/usr/bin/env bash
#
# Build Tape.app and pack it into a drag-to-Applications disk image.
# Prints the .dmg path on stdout; all build noise goes to stderr, so callers
# can do DMG="$(make-dmg.sh)".
#
#   ./scripts/make-dmg.sh [debug|release] [output-dir]
#
# Deliberately does not install anything: it is used by `install.sh --dmg` and
# by .github/workflows/release.yml, so the disk image a release ships is
# byte-for-byte the one you get locally (modulo the ad-hoc signature, which is
# per-build).
#
# TAPE_VERSION / TAPE_BUILD are passed through to make-app.sh, which stamps
# them into the bundle — a release artifact should say what it is.
#
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
OUT_DIR="${2:-$PWD/dist}"

APP="$(./scripts/make-app.sh "$CONFIG")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$OUT_DIR" "$STAGE"
DMG="$OUT_DIR/Tape-$VERSION.dmg"

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# The mounted disk wears the app icon, so the window is recognisable before you
# read a word. The volume's custom-icon bit can only be set by SetFile, which
# ships with the Xcode command line tools.
if [ -f "$APP/Contents/Resources/AppIcon.icns" ] && command -v SetFile >/dev/null 2>&1; then
  cp "$APP/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
  SetFile -a C "$STAGE"
fi

# hdiutil prints a deprecation warning on the newest macOS (`diskutil image` is
# the replacement), but the release runner is macOS 15, where hdiutil is still
# the portable choice.
rm -f "$DMG"
hdiutil create -volname "TAPE" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo "$DMG"
