#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/ForbiddenTrackpad.app"
DMG="$ROOT/build/ForbiddenTrackpad.dmg"

if [[ ! -d "$APP" ]]; then
  echo "Missing app bundle: $APP" >&2
  echo "Run ./build.sh first." >&2
  exit 1
fi

tmpdir="$(mktemp -d /tmp/forbidden-trackpad-dmg.XXXXXX)"
trap 'rm -rf "$tmpdir"' EXIT

ditto "$APP" "$tmpdir/ForbiddenTrackpad.app"
ln -s /Applications "$tmpdir/Applications"
hdiutil create -volname "Forbidden Trackpad" -srcfolder "$tmpdir" -ov -format UDZO "$DMG"

echo "$DMG"
