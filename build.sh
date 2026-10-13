#!/bin/bash
# Builds build/VoiceType.app.
set -euo pipefail
cd "$(dirname "$0")"
app=build/VoiceType.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp Info.plist "$app/Contents/"
swiftc -O -swift-version 5 -o "$app/Contents/MacOS/VoiceType" Sources/*.swift
# Signing with the same certificate every time lets macOS keep its permissions across
# rebuilds; ad-hoc signing ("-") makes each build a new app. make-cert.sh creates it.
identity=$(security find-identity 2>/dev/null | awk "/\"VoiceType Local Signing\"/ {print \$2; exit}")
codesign --force --sign "${identity:--}" "$app"
echo "built $app"
