import Foundation

// Text handling kept free of AppKit and audio so tests/run.sh can check it on its own.

// Whisper marks silence and noise as [BLANK_AUDIO] or (wind blowing); those aren't words.
func clean(_ raw: String) -> String {
  raw.components(separatedBy: .newlines)
    .map { $0.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
             .replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
             .trimmingCharacters(in: .whitespaces) }
    .filter { !$0.isEmpty && !($0.hasPrefix("(") && $0.hasSuffix(")")) }
    .joined(separator: " ")
}

// Whether a live result is a fresh start rather than a revision of the last one: much
// shorter, and starting with a different word.
func startedOver(from old: String, to new: String) -> Bool {
  guard !old.isEmpty, new.count < old.count / 2 else { return false }
  return old.split(separator: " ").first?.lowercased() != new.split(separator: " ").first?.lowercased()
}

func joined(_ a: String, _ b: String) -> String {
  a.isEmpty ? b : b.isEmpty ? a : a + " " + b
}

// The end of a log, from just after its first line break, so it starts on a whole line.
// With no line break at all it is kept as it is.
func newestLines(_ tail: Data) -> Data {
  guard let cut = tail.firstIndex(of: UInt8(ascii: "\n")) else { return tail }
  return Data(tail[(cut + 1)...])
}
