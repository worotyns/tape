#!/usr/bin/env bash
#
# Build and assemble Tape.app. Prints the bundle path on stdout; all build
# noise goes to stderr, so callers can do APP="$(make-app.sh)".
#
#   ./scripts/make-app.sh [debug|release]
#
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"

echo "building ($CONFIG)…" >&2
swift build -c "$CONFIG" --product Tape >&2
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="$PWD/.build/Tape.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Tape" "$APP/Contents/MacOS/Tape"
cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# The icon is drawn, not committed: make-icon.swift renders the menu bar LED at
# 1024 pt into an .icns. Regenerated only when missing or when the drawing
# changed, so an ordinary rebuild does not pay for it.
ICNS="Resources/AppIcon.icns"
if [ ! -f "$ICNS" ] || [ scripts/make-icon.swift -nt "$ICNS" ]; then
  ./scripts/make-icon.swift "$ICNS" >&2
fi
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

# Optional version stamping. A release artifact should say what it is, and the
# tag is the only thing that knows — so the release workflow passes TAPE_VERSION
# from the tag instead of trusting someone to have bumped Info.plist. Only the
# copy inside the bundle is touched, never the repository's Info.plist.
if [ -n "${TAPE_VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $TAPE_VERSION" \
    -c "Set :CFBundleVersion ${TAPE_BUILD:-$TAPE_VERSION}" "$APP/Contents/Info.plist" >/dev/null
  echo "version: $TAPE_VERSION (build ${TAPE_BUILD:-$TAPE_VERSION})" >&2
fi

# Ad-hoc signing is enough to run locally. TCC keys microphone permission off
# the code signature, so every ad-hoc rebuild looks like a brand new app and
# re-prompts (or silently denies). A stable identity stops that — a self-signed
# certificate from Keychain Access, or a free personal-team "Apple Development"
# certificate, both work:
#
#   TAPE_SIGN_IDENTITY="TAPE Dev" ./scripts/install.sh
#
SIGN_IDENTITY="${TAPE_SIGN_IDENTITY:--}"
if codesign --force --sign "$SIGN_IDENTITY" "$APP" >/dev/null 2>&1; then
  echo "signed with: $SIGN_IDENTITY" >&2
else
  echo "warning: codesign failed (identity: $SIGN_IDENTITY); the app still runs" >&2
fi

echo "$APP"
