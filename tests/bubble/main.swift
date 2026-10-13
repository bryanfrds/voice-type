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
check("hiding first also cancels it", bubble.isShowing)
bubble.hide()

if failures > 0 {
  print("\(failures) failed")
  exit(1)
}
print("all passed")
