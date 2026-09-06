#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/ForbiddenTrackpad.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"

if [[ -f "$ROOT/Assets/AppIconSource.png" ]]; then
  swift "$ROOT/Scripts/make_iconset_from_png.swift" "$ROOT/Assets/AppIconSource.png" "$ROOT/build/AppIcon.iconset"
else
  swift "$ROOT/Scripts/make_app_icon.swift" "$ROOT/build/AppIcon.iconset"
fi
iconutil -c icns "$ROOT/build/AppIcon.iconset" -o "$RESOURCES/AppIcon.icns"

clang \
  -fobjc-arc \
  -target arm64-apple-macos13 \
  -framework Cocoa \
  -framework IOBluetooth \
  "$ROOT/Sources/ForbiddenTrackpadObjC/main.m" \
  -o "$MACOS/ForbiddenTrackpad"

cp "$ROOT/Info.plist" "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"
chmod +x "$MACOS/ForbiddenTrackpad"
codesign --force --deep --sign - "$APP" >/dev/null

echo "$APP"
