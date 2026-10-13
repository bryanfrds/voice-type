#!/bin/bash
# Installs whisper.cpp and the speech model if missing, builds VoiceType into
# ~/Applications, and starts it now and at every login.
set -euo pipefail
cd "$(dirname "$0")"
model_dir="$HOME/.local/share/voice-type"
model="$model_dir/ggml-small.en.bin"
label=com.bryanfrds.voice-type
agent="$HOME/Library/LaunchAgents/$label.plist"

command -v whisper-cli >/dev/null || brew install whisper-cpp
if [ ! -f "$model" ]; then
  mkdir -p "$model_dir"
  curl -fL -o "$model.part" https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin
  mv "$model.part" "$model"
fi

./build.sh
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/VoiceType.app"
cp -R build/VoiceType.app "$HOME/Applications/"

cat > "$agent" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>/usr/bin/open</string><string>-a</string><string>$HOME/Applications/VoiceType.app</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
pkill -x VoiceType 2>/dev/null || true
# Stopping finishes in the background; starting again too soon fails.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1 || break
  sleep 0.5
done
launchctl bootstrap "gui/$(id -u)" "$agent"
echo "VoiceType is running: look for the mic in the menu bar."
