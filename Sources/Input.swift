// What VoiceType is doing, and how it answers a key or click that isn't Ctrl + Option.
enum State { case idle, recording, transcribing }

let escapeKey: Int64 = 53  // the same on every layout

enum InputReaction: Equatable { case ignore, cancelRecording, cancelPaste }

// A key or click while Ctrl + Option is held means a shortcut, not talking. Esc after letting
// go, while the speech is still being turned into text, means "don't paste". `key` is nil for
// a click.
func reaction(to key: Int64?, in state: State) -> InputReaction {
  switch state {
  case .recording: return .cancelRecording
  case .transcribing where key == escapeKey: return .cancelPaste
  default: return .ignore
  }
}

enum Finish: Equatable { case sayNothingHeard, paste, keepOnly, nothing }

// What to do once Whisper is done. After Esc the text is kept for the menu but not pasted, and
// no "Didn't catch that" note brings back the bubble the user just dismissed.
func afterTranscribing(_ text: String, pasteCancelled: Bool) -> Finish {
  if text.isEmpty { return pasteCancelled ? .nothing : .sayNothingHeard }
  return pasteCancelled ? .keepOnly : .paste
}
