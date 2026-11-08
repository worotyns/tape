#!/usr/bin/env bash
#
# Double-click this file in Finder to install TABULA into /Applications.
#
# It is a thin wrapper around scripts/install.sh, for when you would rather not
# open a terminal. After this, TABULA behaves like any other Mac app: launch it
# from Finder, Spotlight or Launchpad.
#
set -euo pipefail

cd "$(dirname "$0")"

echo "TABULA installer"
echo "================"
echo

./scripts/install.sh "$@"

echo
echo "Done. You can close this window."
