#!/usr/bin/env bash
#
# Build TAPE and install it as a normal Mac app.
#
#   ./scripts/install.sh                 build + install to /Applications + launch
#   ./scripts/install.sh --user          install to ~/Applications instead
#   ./scripts/install.sh --dmg           also produce dist/TAPE-0.1.dmg
#   ./scripts/install.sh --login         also start TAPE at login
#   ./scripts/install.sh --no-launch     install without launching
#   ./scripts/install.sh --uninstall     remove the app and the login item
#
# The archive in ~/Documents/TAPE is never touched, by install or uninstall.
#
set -euo pipefail

cd "$(dirname "$0")/.."

BUNDLE_ID="local.tape.recorder"
APP_NAME="Tape.app"
AGENT="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"

DEST="/Applications"
CONFIG="release"
MAKE_DMG=0
LOGIN_ITEM=0
LAUNCH=1
UNINSTALL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dest) DEST="${2:?--dest needs a path}"; shift 2 ;;
    --user) DEST="$HOME/Applications"; shift ;;
    --debug) CONFIG=debug; shift ;;
    --dmg) MAKE_DMG=1; shift ;;
    --login) LOGIN_ITEM=1; shift ;;
    --no-launch) LAUNCH=0; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

TARGET="$DEST/$APP_NAME"

stop_running() {
  if pgrep -f "$TARGET/Contents/MacOS/Tape" >/dev/null 2>&1; then
    echo "stopping the running copy…"
    pkill -f "$TARGET/Contents/MacOS/Tape" || true
    sleep 1
  fi
}

remove_login_item() {
  if [ -f "$AGENT" ]; then
    launchctl bootout "gui/$(id -u)" "$AGENT" >/dev/null 2>&1 \
      || launchctl unload "$AGENT" >/dev/null 2>&1 || true
    rm -f "$AGENT"
    echo "removed login item"
  fi
}

if [ "$UNINSTALL" = "1" ]; then
  stop_running
  remove_login_item
  if [ -d "$TARGET" ]; then
    rm -rf "$TARGET"
    echo "removed $TARGET"
  else
    echo "nothing installed at $TARGET"
  fi
  echo
  echo "your recordings are untouched — they live in ~/Documents/TAPE"
  echo "(or wherever you pointed the app), and nothing here deletes them."
  exit 0
fi

# ---- build ----------------------------------------------------------------

APP="$(./scripts/make-app.sh "$CONFIG")"
echo "built $APP"

# ---- install --------------------------------------------------------------

if [ ! -d "$DEST" ]; then
  mkdir -p "$DEST" || { echo "cannot create $DEST; try --user" >&2; exit 1; }
fi
if [ ! -w "$DEST" ]; then
  echo "$DEST is not writable. Re-run with --user to install into ~/Applications." >&2
  exit 1
fi

stop_running

# Replacing an ad-hoc signed app changes its cdhash, and macOS keys microphone
# permission off that. Warn before silently costing the user another TCC prompt.
if [ "${TAPE_SIGN_IDENTITY:--}" = "-" ] && [ -d "$TARGET" ]; then
  old_hash="$(codesign -dvvv "$TARGET" 2>&1 | sed -n 's/^CDHash=//p' | head -1)"
  new_hash="$(codesign -dvvv "$APP" 2>&1 | sed -n 's/^CDHash=//p' | head -1)"
  if [ -n "$old_hash" ] && [ "$old_hash" != "$new_hash" ]; then
    echo
    echo "note: this update changes the app's ad-hoc signature, so macOS will"
    echo "      ask for microphone access again the next time you record."
    echo "      To stop that happening on every update, sign with a stable identity:"
    echo
    echo "        TAPE_SIGN_IDENTITY=\"TAPE Dev\" ./scripts/install.sh"
    echo
    echo "      (Keychain Access › Certificate Assistant › Create a Certificate:"
    echo "       name 'TAPE Dev', Identity Type 'Self Signed Root',"
    echo "       Certificate Type 'Code Signing'.)"
    echo
  fi
fi

rm -rf "$TARGET"
cp -R "$APP" "$TARGET"

# Harmless for a locally built app, and it saves a support round-trip if the
# bundle is ever moved through a zip or a download.
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true

# Spotlight and the icon caches both key off the bundle path and its
# modification time, so a replaced app can keep showing the previous name,
# kind or icon in Spotlight, Finder and Get Info until something pokes them.
# Poke them, cheaply: reimport this one bundle and let IconServices redraw it.
# The sledgehammer — `sudo mdutil -E /` — erases the whole volume's index and
# spends hours rebuilding it, which fixes nothing that this does not.
mdimport "$TARGET" 2>/dev/null || true
touch "$TARGET"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -f "$TARGET" >/dev/null 2>&1 || true
fi
pkill -u "$(id -u)" iconservicesagent 2>/dev/null || true

echo "installed $TARGET"

# ---- optional login item --------------------------------------------------

if [ "$LOGIN_ITEM" = "1" ]; then
  mkdir -p "$(dirname "$AGENT")"
  cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$BUNDLE_ID</string>
	<key>ProgramArguments</key>
	<array>
		<string>$TARGET/Contents/MacOS/Tape</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<false/>
	<key>ProcessType</key>
	<string>Interactive</string>
</dict>
</plist>
PLIST
  launchctl bootout "gui/$(id -u)" "$AGENT" >/dev/null 2>&1 || true
  if launchctl bootstrap "gui/$(id -u)" "$AGENT" 2>/dev/null \
     || launchctl load -w "$AGENT" 2>/dev/null; then
    echo "TAPE will start at login"
  else
    echo "warning: could not register the login item; add it in" >&2
    echo "System Settings › General › Login Items instead" >&2
  fi
fi

# ---- optional disk image --------------------------------------------------

# ---- optional disk image --------------------------------------------------

# Packing lives in its own script because it must work without installing
# anything: `install.sh` copies into /Applications, which a CI runner cannot and
# should not do, and the release workflow has to produce the same disk image.

if [ "$MAKE_DMG" = "1" ]; then
  ./scripts/make-dmg.sh "$CONFIG"
  echo
  echo "note: an unsigned app that arrives *downloaded* will be blocked by"
  echo "Gatekeeper. Locally built copies carry no quarantine flag and just run."
fi

# ---- launch ---------------------------------------------------------------

if [ "$LAUNCH" = "1" ]; then
  open "$TARGET"
  echo "launched — the dot is in your menu bar"
  echo "(quit it from its own menu; it has no Dock icon)"
fi
