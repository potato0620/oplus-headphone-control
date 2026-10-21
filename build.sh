#!/bin/sh
set -eu
cd "$(dirname "$0")"
app_dir="$PWD/dist/o+耳机控制.app"
mkdir -p "$app_dir/Contents/Resources" "$app_dir/Contents/MacOS" "$PWD/.module-cache"
xcrun swiftc -swift-version 5 -O -module-cache-path "$PWD/.module-cache" \
  -framework AppKit -framework IOBluetooth -framework QuartzCore Sources/Air2Control.swift \
  -o "$app_dir/Contents/MacOS/Air2Control"
cp Info.plist "$app_dir/Contents/Info.plist"
cp Resources/AppIcon.icns "$app_dir/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier local.air2.sound-control "$app_dir"
printf 'Built: %s\n' "$app_dir"
