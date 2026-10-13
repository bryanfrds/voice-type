// Checks for Sources/Text.swift and Sources/Keyboard.swift. Run with tests/run.sh.
import Carbon
import Foundation
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

check("a short dictation is shown whole", preview("Hello there."), "Hello there.")
check("a long one is cut at a word, keeping a word that ends at the cut", preview("Can you check whether the pull request merged and then play it", limit: 30),
      "Can you check whether the pull…")
check("trailing punctuation goes before the …", preview("One, two, three, four, five, six", limit: 17), "One, two, three…")
check("one long word is cut where it must be", preview("Supercalifragilistic", limit: 10), "Supercalif…")
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

if failures > 0 {
  print("\(failures) failed")
  exit(1)
}
print("all passed")
