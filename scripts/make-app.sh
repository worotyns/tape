#!/usr/bin/env bash
#
# Build and assemble Tabula.app. Prints the bundle path on stdout; all build
# noise goes to stderr, so callers can do APP="$(make-app.sh)".
#
#   ./scripts/make-app.sh [debug|release]
#
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"

echo "building ($CONFIG)…" >&2
swift build -c "$CONFIG" --product Tabula >&2
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="$PWD/.build/Tabula.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Tabula" "$APP/Contents/MacOS/Tabula"
cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signing is enough to run locally. TCC keys microphone permission off
# the code signature, so every ad-hoc rebuild looks like a brand new app and
# re-prompts (or silently denies). A stable identity stops that — a self-signed
# certificate from Keychain Access, or a free personal-team "Apple Development"
# certificate, both work:
#
#   TABULA_SIGN_IDENTITY="TABULA Dev" ./scripts/install.sh
#
SIGN_IDENTITY="${TABULA_SIGN_IDENTITY:--}"
if codesign --force --sign "$SIGN_IDENTITY" "$APP" >/dev/null 2>&1; then
  echo "signed with: $SIGN_IDENTITY" >&2
else
  echo "warning: codesign failed (identity: $SIGN_IDENTITY); the app still runs" >&2
fi

echo "$APP"
