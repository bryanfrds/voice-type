#!/bin/bash
# Builds build/VoiceType.app.
set -euo pipefail
cd "$(dirname "$0")"
app=build/VoiceType.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp Info.plist "$app/Contents/"
swiftc -O -swift-version 5 -o "$app/Contents/MacOS/VoiceType" Sources/*.swift
codesign --force --sign - "$app"
echo "built $app"
