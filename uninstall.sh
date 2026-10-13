#!/bin/bash
# Stops VoiceType and removes the app, its login item and its signing certificate.
# The speech models are kept unless you pass --models.
# Checked before anything is touched: no options, or exactly --models.
case "$#:${1:-}" in
  0: | 1:--models) ;;
  *) echo "usage: ./uninstall.sh [--models]" >&2; exit 2 ;;
esac
cd "$(dirname "$0")" || exit 1
label=com.bryanfrds.voice-type
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null
pkill -x VoiceType 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$label.plist"
rm -rf "$HOME/Applications/VoiceType.app"
# The certificate only ever signs VoiceType, so it goes too. Installing again makes a new one,
# and macOS then asks for VoiceType's permissions again.
./remove-cert.sh || echo "The signing certificate may still be in your login keychain."
if [ "${1:-}" = "--models" ]; then
  rm -rf "$HOME/.local/share/voice-type"
  echo "VoiceType and its speech models removed."
else
  echo "VoiceType removed. The models are still in ~/.local/share/voice-type (run with --models to delete them)."
fi
