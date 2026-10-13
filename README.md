# VoiceType

Hold **Ctrl + Option**, talk, and let go. Your speech is typed wherever the cursor is.

The speech is turned into text on your Mac by [whisper.cpp](https://github.com/ggml-org/whisper.cpp),
so nothing is uploaded. A short sentence takes about half a second.

## Install

    ./install.sh

This installs whisper.cpp with Homebrew and downloads the English speech model
(about 470 MB) if they're missing. Then it builds `~/Applications/VoiceType.app` and
starts it now and at every login. The first time, macOS asks to let VoiceType use the
microphone and Accessibility (System Settings → Privacy & Security). It needs
Accessibility to see the keys and to paste.

## Use

- **Hold Ctrl + Option** and talk. After a moment the menu bar mic turns red and plays a tick.
- **Let go**, and the mic changes to dots while your speech becomes text. Then the text is pasted with a space after it.
- Holds shorter than a third of a second are ignored. Pressing any other key while
  holding Ctrl + Option cancels, so shortcuts that use those keys still work.
- Your clipboard is put back after each paste.

An orange crossed-out mic means VoiceType is still waiting for Accessibility, or that
whisper.cpp or the model is missing.

## Notes

- Each rebuild is a new app as far as macOS is concerned. After running `install.sh`
  again, you may need to switch VoiceType off and on in Accessibility.
- Set `VOICE_TYPE_MODEL` to use a different whisper.cpp model file.
- Log: `~/Library/Logs/voice-type.log`. To remove VoiceType, run `./uninstall.sh`.
