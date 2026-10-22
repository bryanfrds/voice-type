// Checks for the Sources/*.swift files that don't need the running app. Run with tests/run.sh.
import AVFoundation
import Carbon
import Foundation
import Speech
var failures = 0

func check<T: Equatable>(_ name: String, _ got: T, _ want: T) {
  if got == want {
    print("ok   \(name)")
  } else {
    print("FAIL \(name): got \(got), wanted \(want)")
    failures += 1
  }
}

check("Whisper's leading space and newlines go", clean("\n Hello there.\n"), "Hello there.")
check("lines are joined with a space", clean(" First line.\n Second line."), "First line. Second line.")
check("[BLANK_AUDIO] is dropped", clean(" [BLANK_AUDIO]\n"), "")
check("a tag inside a line is dropped, with no double space", clean(" Hi [MUSIC] there"), "Hi there")
check("a line that is all (noise) is dropped", clean(" (wind blowing)\n Okay."), "Okay.")
check("brackets in the middle of speech stay", clean(" Call me (maybe) later"), "Call me (maybe) later")

check("growing text is a revision", startedOver(from: "This is", to: "This is the first"), false)
check("a reworded start is a revision", startedOver(from: "Testing the live words", to: "Test in the live words"), false)
check("much shorter, new first word: started over",
      startedOver(from: "This is the first sentence before a pause", to: "And this"), true)
check("much shorter, same first word: a revision",
      startedOver(from: "This is the first sentence before a pause", to: "This is"), false)
check("nothing before: not started over", startedOver(from: "", to: "Hello"), false)
check("first words compare without case", startedOver(from: "and then we went home today", to: "And"), false)

check("joining two parts", joined("One.", "Two."), "One. Two.")
check("joining onto nothing", joined("", "Two."), "Two.")
check("joining nothing on", joined("One.", ""), "One.")

// Where Cmd + V is on layouts that ship with macOS, looked up without switching to them.
func layout(_ id: String) -> TISInputSource? {
  let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
  return (TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource])?.first
}
for (id, name, want) in [("com.apple.keylayout.US", "U.S.", 9), ("com.apple.keylayout.Dvorak", "Dvorak", 47),
                         ("com.apple.keylayout.DVORAK-QWERTYCMD", "Dvorak - QWERTY ⌘", 9),
                         ("com.apple.keylayout.French", "French", 9), ("com.apple.keylayout.Russian", "Russian", 9)] {
  check("Cmd + V on \(name) is key \(want)", layout(id).flatMap { keyCode(for: "v", layout: $0) }.map(Int.init), want)
}

let turbo = "ggml-large-v3-turbo-q5_0.bin", small = "ggml-small.en.bin"
check("nothing picked: the best downloaded", chooseModel(picked: nil, downloaded: [turbo, small])?.file, turbo)
check("the picked model is used", chooseModel(picked: small, downloaded: [turbo, small])?.file, small)
check("a picked model that was deleted falls back", chooseModel(picked: turbo, downloaded: [small])?.file, small)
check("an unknown pick falls back", chooseModel(picked: "ggml-tiny.bin", downloaded: [turbo, small])?.file, turbo)
check("nothing downloaded: no model", chooseModel(picked: small, downloaded: [])?.file, nil)

func data(_ s: String) -> Data { Data(s.utf8) }
check("the log starts on the line after the cut", newestLines(data("ne three\nfour\nfive\n")), data("four\nfive\n"))
check("a cut just before a line break loses only that break", newestLines(data("\nfour\n")), data("four\n"))
check("a cut that lands on the last line break leaves nothing", newestLines(data("five\n")), data(""))
check("no line break keeps everything", newestLines(data("one long line")), data("one long line"))
check("multi-byte text after the cut stays whole", newestLines(data("é\nnaïve café\n")), data("naïve café\n"))

check("no words: say so", afterTranscribing("", pasteCancelled: false), .sayNothingHeard)
check("no words after Esc: stay quiet", afterTranscribing("", pasteCancelled: true), .nothing)
check("words: paste them", afterTranscribing("Hi.", pasteCancelled: false), .paste)
check("words after Esc: keep, don't paste", afterTranscribing("Hi.", pasteCancelled: true), .keepOnly)

check("a short dictation is shown whole", preview("Hello there."), "Hello there.")
check("a long one is cut at a word, keeping a word that ends at the cut", preview("Can you check whether the pull request merged and then play it", limit: 30),
      "Can you check whether the pull…")
check("trailing punctuation goes before the …", preview("One, two, three, four, five, six", limit: 17), "One, two, three…")
check("one long word is cut where it must be", preview("Supercalifragilistic", limit: 10), "Supercalif…")
check("a cut just before a comma keeps the word", preview("Hello world, again", limit: 11), "Hello world…")
check("a cut just before a full stop keeps the word", preview("Done here. Next", limit: 9), "Done here…")
check("an apostrophe inside a word isn't a word end", preview("I don't know what", limit: 5), "I…")
check("a hyphen inside a word isn't a word end", preview("a well-known fact", limit: 6), "a…")
check("a full stop inside a number isn't a word end", preview("pi is 3.14 roughly", limit: 7), "pi is…")
check("a cut mid-word still backs up", preview("Hello wonderful world", limit: 9), "Hello…")
check("a cut between two words keeps the last one", preview("Hello world, again", limit: 12), "Hello world…")
check("an opening quote is kept", preview("\"Quoted\" words here and more", limit: 15), "\"Quoted\" words…")
check("all punctuation before the cut shows the uncut start", preview("... ... more words", limit: 5), "... .…")

let aKey: Int64 = 0
check("any key while recording cancels it", reaction(to: aKey, in: .recording), .cancelRecording)
check("Esc while recording cancels it too", reaction(to: escapeKey, in: .recording), .cancelRecording)
check("a click while recording cancels it", reaction(to: nil, in: .recording), .cancelRecording)
check("Esc while transcribing cancels the paste", reaction(to: escapeKey, in: .transcribing), .cancelPaste)
check("another key while transcribing is ignored", reaction(to: aKey, in: .transcribing), .ignore)
check("a click while transcribing is ignored", reaction(to: nil, in: .transcribing), .ignore)
check("Esc when idle is ignored", reaction(to: escapeKey, in: .idle), .ignore)

check("all allowed: no warning", permissionWarning(mic: .authorized, speech: .authorized), nil)
check("not asked yet: no warning", permissionWarning(mic: .notDetermined, speech: .notDetermined), nil)
check("mic off blocks recording", permissionWarning(mic: .denied, speech: .authorized)?.blocksRecording, true)
check("mic off points at the Microphone page", permissionWarning(mic: .denied, speech: .denied)?.pane, "Privacy_Microphone")
check("speech off still records", permissionWarning(mic: .authorized, speech: .denied)?.blocksRecording, false)
check("speech off points at its page", permissionWarning(mic: .authorized, speech: .restricted)?.pane,
      "Privacy_SpeechRecognition")

// Two screens like Bryan's: a 1920x1080 main monitor, and the laptop to its lower left.
let monitor = CGRect(x: 0, y: 0, width: 1920, height: 1080)
let laptop = CGRect(x: -1710, y: -596, width: 1710, height: 1107)
let laptopWindow = CGRect(x: -1500, y: -400, width: 800, height: 600)
check("the bubble goes where you're typing, not where the mouse is",
      screenIndex(window: laptopWindow, mouse: CGPoint(x: 800, y: 900), screens: [monitor, laptop]), 1)
check("with no focused window it follows the mouse",
      screenIndex(window: nil, mouse: CGPoint(x: -100, y: 0), screens: [monitor, laptop]), 1)
check("a window off every screen falls back to the mouse",
      screenIndex(window: CGRect(x: 5000, y: 5000, width: 10, height: 10), mouse: CGPoint(x: 10, y: 10),
                  screens: [monitor, laptop]), 0)
check("nothing anywhere falls back to the first screen",
      screenIndex(window: nil, mouse: CGPoint(x: 9999, y: 9999), screens: [monitor, laptop]), 0)
check("no screens: nowhere", screenIndex(window: nil, mouse: .zero, screens: []), nil)
check("Accessibility's top-left frame flips to AppKit's bottom-left",
      appKitRect(fromAccessibility: CGRect(x: 100, y: 50, width: 400, height: 300), mainHeight: 1080),
      CGRect(x: 100, y: 730, width: 400, height: 300))

// Meeting notes.
let whisperJSON = Data("""
  {"transcription": [
    {"offsets": {"from": 0, "to": 2000}, "text": " Shall we start?"},
    {"offsets": {"from": 2000, "to": 3000}, "text": " [BLANK_AUDIO]"},
    {"offsets": {"from": 9000, "to": 12000}, "text": " Budget is RM5,000."}
  ]}
  """.utf8)
let you = segments(fromWhisperJSON: whisperJSON, speaker: "You") ?? []
check("Whisper segments are read, noise dropped", you.map(\.text), ["Shall we start?", "Budget is RM5,000."])
check("a segment keeps its start time", you.first?.start, 0)
check("unreadable output is a failure, not silence", segments(fromWhisperJSON: Data("nope".utf8), speaker: "You"), nil)
check("no speech is an empty list, not a failure",
      segments(fromWhisperJSON: Data(#"{"transcription": []}"#.utf8), speaker: "You"), [])
// whisper.cpp can cut a multi-byte character in half, leaving invalid UTF-8 in the JSON.
var broken = Data(#"{"transcription": [{"offsets": {"from": 0, "to": 900}, "text": " 你好 "#.utf8)
broken.append(contentsOf: [0xE4, 0xBD])  // the first two of a character's three bytes
broken.append(contentsOf: Data(#" ok"}]}"#.utf8))
check("invalid UTF-8 from Whisper is repaired, not lost",
      segments(fromWhisperJSON: broken, speaker: "Others")?.first?.text.hasPrefix("你好"), true)
let others = [Segment(start: 3000, speaker: "Others", text: "Yes."), Segment(start: 5000, speaker: "Others", text: "Go ahead.")]
check("both sides merge in time order, a speaker's run joined",
      transcript([you, others]),
      "[0:00] You: Shall we start?\n[0:03] Others: Yes. Go ahead.\n[0:09] You: Budget is RM5,000.")
check("nothing heard: empty transcript", transcript([[], []]), "")

check("a segment keeps its end time", you.first?.end, 2000)

let diarization = """
  OfflineSpeakerDiarizationConfig(segmentation=..., min_duration_on=0.3)
  Started
  progress 100.00%
  0.000 -- 4.500 speaker_01
  4.800 -- 6.200 speaker_00
  6.900 -- 8.300 speaker_01
  9.000 -- 9.000 speaker_02
  Elapsed seconds: 0.735 s
  """
let spans = voiceSpans(fromDiarization: diarization)
check("voice spans are read in ms; settings, progress and empty spans are skipped",
      spans, [VoiceSpan(start: 0, end: 4500, speaker: "speaker_01"), VoiceSpan(start: 4800, end: 6200, speaker: "speaker_00"),
              VoiceSpan(start: 6900, end: 8300, speaker: "speaker_01")])
let room = [Segment(start: 0, speaker: "Room", text: "Okay Houston, we've had a problem.", end: 3800),
            Segment(start: 4700, speaker: "Room", text: "Say again, please.", end: 6300),
            Segment(start: 6900, speaker: "Room", text: "We've had a problem.", end: 8300)]
check("speakers are numbered in the order they first talk, and keep their number",
      labellingSpeakers(room, spans: spans).map(\.speaker), ["Speaker 1", "Speaker 2", "Speaker 1"])
check("a segment takes the voice heard most during it (0.5 s of one, 1.2 s of two)",
      labellingSpeakers([room[0], Segment(start: 4000, speaker: "Room", text: "Mostly two.", end: 6000)], spans: spans)
        .map(\.speaker), ["Speaker 1", "Speaker 2"])
check("a segment no voice overlaps takes the nearest one (0.1 s away, not 0.4 s)",
      labellingSpeakers([room[0], Segment(start: 6300, speaker: "Room", text: "Hm.", end: 6500)], spans: spans)
        .map(\.speaker), ["Speaker 1", "Speaker 2"])
check("with no voices found, the segments stay as they were", labellingSpeakers(room, spans: []), room)
check("numbered speakers each get their own lines in the transcript",
      transcript([labellingSpeakers(room, spans: spans)]),
      "[0:00] Speaker 1: Okay Houston, we've had a problem.\n[0:04] Speaker 2: Say again, please.\n[0:06] Speaker 1: We've had a problem.")
check("minutes and seconds", clock(754_000), "12:34")
check("hours when past an hour", clock(3_723_000), "1:02:03")
var utc = Calendar(identifier: .gregorian)
utc.timeZone = TimeZone(identifier: "UTC")!
let meetingDate = utc.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 14, minute: 30))!
NSTimeZone.default = TimeZone(identifier: "UTC")!
check("the note is named by date and time", noteStem(for: meetingDate), "2026-10-17 14.30")
check("a key in the environment wins", deepSeekKey(environment: ["DEEPSEEK_API_KEY": "env"], config: "DEEPSEEK_API_KEY=file"), "env")
check("a key from the config file, quotes trimmed", deepSeekKey(environment: [:], config: "# notes\nDEEPSEEK_API_KEY = \"sk-1\"\n"), "sk-1")
check("no key anywhere", deepSeekKey(environment: [:], config: nil), nil)
check("Windows line endings don't stick to the key", deepSeekKey(environment: [:], config: "DEEPSEEK_API_KEY=sk-2\r\nOTHER=x\r\n"), "sk-2")
check("an export line works too", deepSeekKey(environment: [:], config: "export DEEPSEEK_API_KEY=sk-3"), "sk-3")
check("the summary instructions explain a room recording", summaryInstructions.contains("\"Room\""), true)
let request = summaryRequest(transcript: "[0:00] You: Hi", key: "sk-1")
check("the request goes to DeepSeek with the key", request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-1")
let sent = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
check("the transcript is the user message", ((sent?["messages"] as? [[String: Any]])?.last?["content"] as? String), "[0:00] You: Hi")
check("the reply text is read", summary(fromReply: Data(#"{"choices":[{"message":{"content":"  ## Summary\n- Hi  "}}]}"#.utf8)), "## Summary\n- Hi")
check("an error reply has no summary", summary(fromReply: Data(#"{"error":{"message":"Insufficient Balance"}}"#.utf8)), nil)
let missing = note(date: meetingDate, length: 61_000, summary: nil, missing: "the DeepSeek balance is empty", transcript: "")
check("a note without a summary says why", missing.contains("_No summary: the DeepSeek balance is empty_"), true)
check("a note with nothing heard says so", missing.contains("_Nothing was heard._"), true)
check("a note gives the length", missing.contains("Length: 1:01"), true)
let full = note(date: meetingDate, length: 61_000, summary: "## Summary\n- Budget agreed", missing: nil,
                transcript: "[0:00] You: Hi")
check("a note with a summary puts it before the transcript",
      (full.range(of: "## Summary")?.lowerBound).map { $0 < full.range(of: "## Transcript")!.lowerBound }, true)
check("a note with a summary has no missing line", full.contains("_No summary"), false)
check("one audio file: no step count", transcribingStep(1, of: 1), "Transcribing meeting…")
check("several files: which one of how many", transcribingStep(2, of: 3), "Transcribing meeting 2 of 3…")

let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("vt-notes-\(getpid())")
let notesFolder = scratch.appendingPathComponent("Meeting Notes")
check("a missing notes folder is made", existingFolder(notesFolder), notesFolder)
check("an existing one is left as it is", existingFolder(notesFolder), notesFolder)
let aFile = scratch.appendingPathComponent("file")
FileManager.default.createFile(atPath: aFile.path, contents: nil)
check("a file in the way gives nil, not a folder", existingFolder(aFile), nil)
try? FileManager.default.removeItem(at: scratch)

if failures > 0 {
  print("\(failures) failed")
  exit(1)
}
print("all passed")
