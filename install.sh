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
./make-cert.sh
if [ ! -f "$model" ]; then
  mkdir -p "$model_dir"
  curl -fL -o "$model.part" https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin
  mv "$model.part" "$model"
fi
# Tells people apart by voice in meeting notes recorded in a room: sherpa-onnx's speaker
# diarization tool and its two models, each checked against the file that was tested.
sherpa=https://github.com/k2-fsa/sherpa-onnx/releases/download
tmp=
trap 'rm -rf "${tmp:-}"' EXIT
fetch() {  # url, sha256, destination
  [ -f "$3" ] && return
  curl -fL -o "$3.part" "$1"
  echo "$2  $3.part" | shasum -a 256 -c --quiet
  mv "$3.part" "$3"
}
# Its tool is built for Apple silicon only; without it, a room's speakers are all "Room".
if [ "$(uname -m)" = arm64 ] && [ ! -x "$model_dir/sherpa-onnx-offline-speaker-diarization" ]; then
  tmp=$(mktemp -d)
  fetch "$sherpa/v1.13.8/sherpa-onnx-v1.13.8-osx-arm64-static-no-tts.tar.bz2" \
    1038a379fff5365b684e05cbbb9ab3577c1a2f6b1736a4d53a6746860d7eddd4 "$tmp/sherpa.tar.bz2"
  tar xjf "$tmp/sherpa.tar.bz2" -C "$tmp" sherpa-onnx-v1.13.8-osx-arm64-static-no-tts/bin/sherpa-onnx-offline-speaker-diarization
  mv "$tmp/sherpa-onnx-v1.13.8-osx-arm64-static-no-tts/bin/sherpa-onnx-offline-speaker-diarization" "$model_dir/"
  rm -rf "$tmp"
fi
if [ ! -f "$model_dir/speaker-segmentation.onnx" ]; then
  tmp=$(mktemp -d)
  fetch "$sherpa/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2" \
    24615ee884c897d9d2ba09bb4d30da6bb1b15e685065962db5b02e76e4996488 "$tmp/segmentation.tar.bz2"
  tar xjf "$tmp/segmentation.tar.bz2" -C "$tmp" sherpa-onnx-pyannote-segmentation-3-0/model.onnx
  mv "$tmp/sherpa-onnx-pyannote-segmentation-3-0/model.onnx" "$model_dir/speaker-segmentation.onnx"
  rm -rf "$tmp"
fi
fetch "$sherpa/speaker-recongition-models/nemo_en_titanet_small.onnx" \
  ad4a1802485d8b34c722d2a9d04249662f2ece5d28a7a039063ca22f515a789e "$model_dir/nemo_en_titanet_small.onnx"
rm -f "$model_dir/ggml-small.en-tdrz.bin"  # the speaker-change model this replaced

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
