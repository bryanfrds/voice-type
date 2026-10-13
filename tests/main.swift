// Checks for Sources/Text.swift. Run with tests/run.sh.
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

if failures > 0 {
  print("\(failures) failed")
  exit(1)
}
print("all passed")
