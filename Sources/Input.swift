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
