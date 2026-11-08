#!/usr/bin/env bash
#
# Double-click this file in Finder to install TAPE into /Applications.
#
# It is a thin wrapper around scripts/install.sh, for when you would rather not
# open a terminal. After this, TAPE behaves like any other Mac app: launch it
# from Finder, Spotlight or Launchpad.
#
set -euo pipefail

cd "$(dirname "$0")"

echo "TAPE installer"
echo "================"
echo

./scripts/install.sh "$@"

echo
echo "Done. You can close this window."
