#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
swift build -c release
bin=$(swift build -c release --show-bin-path)
app="$PWD/.build/ATK.app"
iconset="$PWD/.build/ATK.iconset"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$iconset"
install -m 0755 "$bin/ATK" "$app/Contents/MacOS/ATK"
install -m 0644 Info.plist "$app/Contents/Info.plist"
swift "$PWD/draw-icon.swift" "$iconset"
iconutil -c icns "$iconset" -o "$app/Contents/Resources/ATK.icns"
codesign --force --sign "${ATK_SIGNING_IDENTITY:--}" "$app"
printf '%s\n' "$app"
