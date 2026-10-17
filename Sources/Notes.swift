import Foundation

// Meeting notes, the parts that don't touch audio or the network: reading Whisper's
// segments, merging the two sides of a call into one transcript, and the note itself.

// One stretch of speech, in milliseconds from the start of the recording.
struct Segment: Equatable {
  let start: Int
  let speaker: String
  let text: String
}

// The segments in whisper-cli's JSON output (-oj): {"transcription": [{"offsets":
// {"from": ms, "to": ms}, "text": "..."}]}. Blank and noise-only segments are dropped.
// Nil when it can't be read, so a failure is never mistaken for silence. whisper.cpp can
// split a multi-byte character and write invalid UTF-8, so a second try replaces bad bytes.
func segments(fromWhisperJSON data: Data, speaker: String) -> [Segment]? {
  let repaired = Data(String(decoding: data, as: UTF8.self).utf8)
  guard let root = ((try? JSONSerialization.jsonObject(with: data)) ?? (try? JSONSerialization.jsonObject(with: repaired)))
          as? [String: Any],
        let items = root["transcription"] as? [[String: Any]] else { return nil }
  return items.compactMap { item in
    let text = clean(item["text"] as? String ?? "")
    guard !text.isEmpty, let start = (item["offsets"] as? [String: Any])?["from"] as? Int else { return nil }
    return Segment(start: start, speaker: speaker, text: text)
  }
}

// Both sides in time order, with a speaker's consecutive segments joined into one turn.
func transcript(_ sides: [[Segment]]) -> String {
  let ordered = sides.flatMap { $0 }.enumerated()
    .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)
  var turns: [(speaker: String, start: Int, text: String)] = []
  for segment in ordered {
    if let last = turns.last, last.speaker == segment.speaker {
      turns[turns.count - 1].text = joined(last.text, segment.text)
    } else {
      turns.append((segment.speaker, segment.start, segment.text))
    }
  }
  return turns.map { "[\(clock($0.start))] \($0.speaker): \($0.text)" }.joined(separator: "\n")
}

// 754000 ms as "12:34", or "1:02:03" past an hour.
func clock(_ ms: Int) -> String {
  let seconds = ms / 1000
  let (h, m, s) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
  return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

// "2026-10-17 14.30": sorts by date, and has no characters Finder or iCloud dislike.
func noteStem(for date: Date) -> String {
  let format = DateFormatter()
  format.locale = Locale(identifier: "en_US_POSIX")
  format.dateFormat = "yyyy-MM-dd HH.mm"
  return format.string(from: date)
}

let summaryInstructions = """
  You write meeting notes from a transcript. On a call, "You" is the person who recorded the \
  meeting and "Others" is everyone heard through the call. "Room" means one microphone heard \
  everyone in a room, so it can't tell who spoke: name an owner for an action item only when \
  the transcript says who it is, else write "someone". The transcript comes from speech \
  recognition, so fix obvious mishearings from context, and never invent facts, names, dates \
  or numbers that aren't in it.

  Reply in Markdown with exactly these sections, in this order:
  ## Summary
  3 to 6 short bullet points.
  ## Decisions
  Bullet points, or "None".
  ## Action items
  "- [ ] who: what (by when)", leaving out "by when" if no date was said. "None" if there are none.
  ## Open questions
  Bullet points, or "None".
  """

// The DeepSeek chat request for a transcript. DeepSeek takes OpenAI's request format.
func summaryRequest(transcript: String, key: String) -> URLRequest {
  var request = URLRequest(url: URL(string: "https://api.deepseek.com/chat/completions")!)
  request.httpMethod = "POST"
  request.timeoutInterval = 120
  request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
  request.setValue("application/json", forHTTPHeaderField: "Content-Type")
  let body: [String: Any] = [
    "model": "deepseek-chat",
    "temperature": 0.2,
    "messages": [
      ["role": "system", "content": summaryInstructions],
      ["role": "user", "content": transcript],
    ],
  ]
  request.httpBody = try? JSONSerialization.data(withJSONObject: body)
  return request
}

// The reply text from a chat completion, or nil.
func summary(fromReply data: Data) -> String? {
  guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let message = (root["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any],
        let text = message["content"] as? String else { return nil }
  let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
  return trimmed.isEmpty ? nil : trimmed
}

// The finished note: the summary (or why there isn't one), then the full transcript.
func note(date: Date, length ms: Int, summary: String?, missing reason: String?, transcript: String) -> String {
  let format = DateFormatter()
  format.locale = Locale(identifier: "en_US_POSIX")
  format.dateFormat = "EEEE d MMMM yyyy, h:mm a"
  var parts = ["# Meeting, \(format.string(from: date))", "Length: \(clock(ms))"]
  if let summary {
    parts.append(summary)
  } else if let reason {
    parts.append("_No summary: \(reason)_")
  }
  parts.append("## Transcript\n\n" + (transcript.isEmpty ? "_Nothing was heard._" : transcript))
  return parts.joined(separator: "\n\n") + "\n"
}

// DEEPSEEK_API_KEY from the environment, else from ~/.config/voice-type/config
// (KEY=value lines). Nil when neither has one.
func deepSeekKey(environment: [String: String], config: String?) -> String? {
  if let key = environment["DEEPSEEK_API_KEY"], !key.isEmpty { return key }
  for raw in (config ?? "").split(whereSeparator: \.isNewline) {
    var line = raw.trimmingCharacters(in: .whitespaces)
    if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
    let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
    if parts.count == 2, parts[0] == "DEEPSEEK_API_KEY", !parts[1].isEmpty {
      return parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }
  }
  return nil
}
