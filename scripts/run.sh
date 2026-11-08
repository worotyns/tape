#!/usr/bin/env bash
#
# Build TAPE and launch it straight from the build directory. For a normal
# installed app use ./scripts/install.sh instead.
#
#   ./scripts/run.sh            build release, launch
#   ./scripts/run.sh --debug    same, debug build
#   ./scripts/run.sh --log      run in the foreground so you can read stderr
#   ./scripts/run.sh --no-open  just build the bundle, do not launch
#
# The .app bundle is not optional: TCC reads NSMicrophoneUsageDescription from
# Info.plist, so a bare `swift run` executable is denied microphone access with
# no prompt at all.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG=release
DO_OPEN=1
FOREGROUND=0
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG=debug ;;
    --log) FOREGROUND=1 ;;
    --no-open) DO_OPEN=0 ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

APP="$(./scripts/make-app.sh "$CONFIG")"
echo "built $APP"

if [ "$FOREGROUND" = "1" ]; then
  exec "$APP/Contents/MacOS/Tape"
fi
if [ "$DO_OPEN" = "1" ]; then
  open "$APP"
  echo "launched — look for the dot in the menu bar"
fi
