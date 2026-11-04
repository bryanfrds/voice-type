import Foundation

// Remembering people's voices between meetings in a room: after a meeting you name its
// speakers, their voiceprints are saved on this Mac, and the next meeting uses the names.
// These are the parts that don't touch audio or windows, so they can be tested.

// A named person's voiceprint, the average of every meeting they were named in.
struct SavedVoice: Codable, Equatable {
  let name: String
  let print: [Float]
  let meetings: Int
}

// One speaker of a finished room meeting, as the "Who spoke?" window shows them: their label in
// the note ("Speaker 2", or a name if their voice was known), something they said, and their
// voiceprint. `known` is the saved name their voice matched, if any.
struct MeetingSpeaker: Equatable {
  let label: String
  let said: String
  let print: [Float]
  let known: String?
}

// How alike two voiceprints must be to be the same person. In sherpa-onnx's four test
// recordings, halves of one person's speech scored 0.59 to 0.93 and different people at most
// 0.44, so 0.5 sits in the gap. A whole meeting's print is steadier than those halves.
let sameVoiceprint: Float = 0.5

// How alike two voiceprints are, from -1 to 1 (1 is the same direction). 0 when they can't
// be compared.
func likeness(_ a: [Float], _ b: [Float]) -> Float {
  guard a.count == b.count, !a.isEmpty else { return 0 }
  var dot: Float = 0, aa: Float = 0, bb: Float = 0
  for i in a.indices {
    dot += a[i] * b[i]
    aa += a[i] * a[i]
    bb += b[i] * b[i]
  }
  return aa > 0 && bb > 0 ? dot / (aa.squareRoot() * bb.squareRoot()) : 0
}

// voice-type-voiceprint's output: one line of numbers. Nil when it isn't one.
func voiceprint(fromHelper output: String) -> [Float]? {
  let numbers = output.split(whereSeparator: { $0 == " " || $0.isNewline }).map { Float($0) }
  guard !numbers.isEmpty, numbers.allSatisfy({ $0?.isFinite == true }) else { return nil }
  return numbers.map { $0! }
}

// The saved name for each of one recording's voices (keyed as in `prints`), where one is alike
// enough. The closest pairs are taken first and each name is used once, since two voices in the
// same recording were told apart as different people.
func knownVoices(_ prints: [String: [Float]], saved: [SavedVoice], threshold: Float = sameVoiceprint) -> [String: String] {
  var pairs: [(voice: String, name: String, score: Float)] = []
  for (voice, print) in prints {
    for person in saved {
      let score = likeness(print, person.print)
      if score >= threshold { pairs.append((voice, person.name, score)) }
    }
  }
  // Ties go by voice then name, so the result doesn't depend on dictionary order.
  pairs.sort { ($0.score, $1.voice, $1.name) > ($1.score, $0.voice, $0.name) }
  var found: [String: String] = [:]
  var used: Set<String> = []
  for pair in pairs where found[pair.voice] == nil && !used.contains(pair.name) {
    found[pair.voice] = pair.name
    used.insert(pair.name)
  }
  return found
}

// A print scaled to length 1, so averaging weighs every meeting the same however loud it was.
private func unit(_ print: [Float]) -> [Float] {
  let length = print.reduce(0) { $0 + $1 * $1 }.squareRoot()
  return length > 0 ? print.map { $0 / length } : print
}

// The saved voices after `name` was given to `print`: averaged into that person's print if
// they're saved already (names compare without case, and keep their first spelling), else added.
// A blank name, or a print that can't be averaged with theirs, changes nothing.
func remembering(_ name: String, print: [Float], in saved: [SavedVoice]) -> [SavedVoice] {
  let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !name.isEmpty, !print.isEmpty else { return saved }
  guard let i = saved.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
    return saved + [SavedVoice(name: name, print: unit(print), meetings: 1)]
  }
  let old = saved[i]
  guard old.print.count == print.count else { return saved }
  let n = Float(old.meetings)
  let new = unit(print)
  let mixed = zip(unit(old.print), new).map { ($0 * n + $1) / (n + 1) }
  var result = saved
  result[i] = SavedVoice(name: old.name, print: unit(mixed), meetings: old.meetings + 1)
  return result
}

// The saved voices file's contents, or none when it's missing or can't be read.
func savedVoices(from data: Data?) -> [SavedVoice] {
  data.flatMap { try? JSONDecoder().decode([SavedVoice].self, from: $0) } ?? []
}

// A note with one speaker's label changed to `name`: at the start of their transcript lines
// ("[1:02] Speaker 2: ..."), and, for an automatic "Speaker n" label, wherever else the note
// says it (the summary's action items). A name the note already used is only changed in the
// transcript, since the same word could be part of what someone said.
func renamingSpeaker(in note: String, from label: String, to name: String) -> String {
  let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !name.isEmpty, name != label else { return note }
  let lines = note.components(separatedBy: "\n").map { line -> String in
    guard line.hasPrefix("["), let close = line.range(of: "] ") else { return line }
    let rest = line[close.upperBound...]
    guard rest.hasPrefix(label + ": ") else { return line }
    return String(line[..<close.upperBound]) + name + rest.dropFirst(label.count)
  }
  var renamed = lines.joined(separator: "\n")
  if label.range(of: #"^Speaker \d+$"#, options: .regularExpression) != nil {
    // "Speaker 1" but not "Speaker 12"; the replacement is escaped so "$" in a name stays itself.
    let template = NSRegularExpression.escapedTemplate(for: name)
    renamed = renamed.replacingOccurrences(of: NSRegularExpression.escapedPattern(for: label) + #"(?!\d)"#,
                                           with: template, options: .regularExpression)
  }
  return renamed
}

// A room meeting's labelled segments with known voices given their saved names, and its
// speakers for the "Who spoke?" window, in number order. `numbers` and `prints` are keyed by
// voice as `labellingPart` keys them ("<part>-speaker_00"); each part's voices are matched on
// their own, so after a mic change the same person can be found again. A speaker with no
// voiceprint (too little speech) or nothing said isn't in the window.
func namingSpeakers(_ segments: [Segment], numbers: [String: Int], prints: [String: [Float]],
                    saved: [SavedVoice]) -> (segments: [Segment], speakers: [MeetingSpeaker]) {
  let parts = Dictionary(grouping: prints.keys) { $0.prefix { $0 != "-" } }
  var names: [Int: String] = [:]
  for keys in parts.values {
    let found = knownVoices(Dictionary(uniqueKeysWithValues: keys.map { ($0, prints[$0]!) }), saved: saved)
    for (voice, name) in found { if let number = numbers[voice] { names[number] = name } }
  }
  let renamed = segments.map { segment in
    guard let number = speakerNumber(segment.speaker), let name = names[number] else { return segment }
    return Segment(start: segment.start, speaker: name, text: segment.text, end: segment.end)
  }
  let speakers = numbers.sorted { $0.value < $1.value }.compactMap { voice, number -> MeetingSpeaker? in
    guard let print = prints[voice],
          let said = segments.first(where: { $0.speaker == "Speaker \(number)" })?.text else { return nil }
    return MeetingSpeaker(label: names[number] ?? "Speaker \(number)", said: sample(of: said), print: print, known: names[number])
  }
  return (renamed, speakers)
}

// 3 for "Speaker 3"; nil for anything else.
func speakerNumber(_ label: String) -> Int? {
  label.hasPrefix("Speaker ") ? Int(label.dropFirst(8)) : nil
}

// Something a speaker said, short enough for one row of the window.
func sample(of text: String, limit: Int = 60) -> String {
  preview(text, limit: limit)
}
