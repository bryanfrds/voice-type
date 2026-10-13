#!/bin/bash
# Stops VoiceType and removes the app and its login item. The speech model is kept.
label=com.bryanfrds.voice-type
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null
pkill -x VoiceType 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$label.plist"
rm -rf "$HOME/Applications/VoiceType.app"
echo "VoiceType removed. The model is still in ~/.local/share/voice-type."
