#!/bin/bash
# Stops VoiceType and removes the app, its login item and its signing certificate.
# The speech models are kept unless you pass --models.
label=com.bryanfrds.voice-type
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null
pkill -x VoiceType 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$label.plist"
rm -rf "$HOME/Applications/VoiceType.app"
# The certificate only ever signs VoiceType (make-cert.sh), so it goes too.
if security find-identity 2>/dev/null | grep -q '"VoiceType Local Signing"'; then
  security delete-identity -c "VoiceType Local Signing" && echo "Removed the VoiceType signing certificate."
fi
if [ "${1:-}" = "--models" ]; then
  rm -rf "$HOME/.local/share/voice-type"
  echo "VoiceType and its speech models removed."
else
  echo "VoiceType removed. The models are still in ~/.local/share/voice-type (run with --models to delete them)."
fi
