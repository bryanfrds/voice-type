// Checks the bubble's self-hiding note in a real (offscreen-capable) panel. Run with tests/run.sh.
import AppKit

var failures = 0
func check(_ name: String, _ ok: Bool) {
  print(ok ? "ok   \(name)" : "FAIL \(name)")
  if !ok { failures += 1 }
}
func wait(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

_ = NSApplication.shared
let bubble = Bubble()

bubble.show("Didn't catch that", dim: true, hidingAfter: 0.2)
check("a note shows", bubble.isShowing)
wait(0.4)
check("a note hides itself", !bubble.isShowing)

bubble.show("Didn't catch that", dim: true, hidingAfter: 0.2)
wait(0.1)
bubble.show("Listening…", dim: true)
wait(0.3)
check("showing something else cancels the note's hide", bubble.isShowing)

bubble.show("Didn't catch that", dim: true, hidingAfter: 0.2)
bubble.hide()
bubble.show("Next words")
wait(0.3)
check("a note hidden early doesn't hide what comes next", bubble.isShowing)
bubble.hide()

check("no panel is made before the bubble first shows", Bubble().panelForTesting == nil)

// A fresh panel each time the bubble appears, so a panel stranded on one Space by sleep is
// never reused; the same panel while it stays up, so it isn't rebuilt mid-sentence.
bubble.show("One")
let first = bubble.panelForTesting
bubble.show("One two")
check("live words keep the same panel", bubble.panelForTesting === first)
bubble.hide()
bubble.show("Again")
check("appearing again gets a new panel", bubble.panelForTesting !== first)
check("the new panel still joins every Space",
      bubble.panelForTesting?.collectionBehavior.contains(.canJoinAllSpaces) == true)
bubble.hide()

// The app empties its autorelease pool after every event; each step here does the same.
weak var old: NSPanel?
let fresh = Bubble()
autoreleasepool { fresh.show("Before"); old = fresh.panelForTesting; fresh.hide() }
wait(0.05)
autoreleasepool { fresh.show("After"); fresh.hide() }
// AppKit lets go of a closed window on its own schedule, so give it up to two seconds,
// draining the pool each turn as the app's event loop would.
for _ in 0..<40 where old != nil { autoreleasepool { wait(0.05) } }
check("an old panel is freed, not leaked", old == nil)

if failures > 0 {
  print("\(failures) failed")
  exit(1)
}
print("all passed")
