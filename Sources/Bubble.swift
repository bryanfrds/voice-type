import AppKit

// The floating bubble near the bottom of the screen that shows the words as they're spoken.
final class Bubble {
  private let width: CGFloat = 520
  private let padding: CGFloat = 16
  // Longer speech shows only its end, so the bubble stays at most a few lines tall.
  private let maxCharacters = 180
  private var panel: NSPanel
  private let label = NSTextField(wrappingLabelWithString: "")
  private var hideTimer: Timer?
  private var area: NSRect?   // the visible part of the screen the bubble is on

  init() {
    label.font = .systemFont(ofSize: 15)
    panel = Bubble.makePanel(width: width, label: label)
  }

  // Seen after the Mac sleeps: a panel can lose its place on every Space and stay stuck on
  // one desktop, out of sight. So each time the bubble appears it gets a new panel.
  private static func makePanel(width: CGFloat, label: NSTextField) -> NSPanel {
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 50),
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    panel.isReleasedWhenClosed = false  // Swift owns it; closing must not free it under us
    panel.level = .statusBar
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.ignoresMouseEvents = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

    let box = NSVisualEffectView()
    box.material = .hudWindow
    box.state = .active
    box.blendingMode = .behindWindow
    box.wantsLayer = true
    box.layer?.cornerRadius = 14
    box.layer?.masksToBounds = true
    box.addSubview(label)
    panel.contentView = box
    return panel
  }

  // Dim text means "not words yet": listening, or turning the speech into the final text.
  // With `hidingAfter`, the bubble hides itself after that long, unless something else is
  // shown or it is hidden first.
  func show(_ text: String, dim: Bool = false, hidingAfter delay: TimeInterval? = nil) {
    hideTimer?.invalidate()
    if let delay {
      let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in self?.hide() }
      RunLoop.main.add(timer, forMode: .common)  // keeps counting while the menu is open
      hideTimer = timer
    }
    label.stringValue = text.count > maxCharacters ? "…" + text.suffix(maxCharacters) : text
    label.textColor = dim ? .secondaryLabelColor : .labelColor
    let inner = width - padding * 2
    let height = ceil(label.sizeThatFits(NSSize(width: inner, height: .greatestFiniteMagnitude)).height)
    label.frame = NSRect(x: padding, y: padding, width: inner, height: height)

    // On the screen you're typing on, not wherever the mouse was left. Chosen when the
    // bubble appears and kept while it shows, so live words don't ask Accessibility
    // several times a second or make the bubble jump screens mid-sentence.
    if !panel.isVisible {
      panel.close()
      panel = Bubble.makePanel(width: width, label: label)
      area = nil
    }
    if area == nil {
      let screens = NSScreen.screens
      let screen = screenIndex(window: focusedWindowFrame(), mouse: NSEvent.mouseLocation,
                               screens: screens.map(\.frame)).map { screens[$0] } ?? NSScreen.main
      area = screen?.visibleFrame
    }
    let area = self.area ?? .zero
    panel.setFrame(NSRect(x: area.midX - width / 2, y: area.minY + 60,
                          width: width, height: height + padding * 2), display: true)
    panel.orderFrontRegardless()
  }

  var isShowing: Bool { panel.isVisible }
  var panelForTesting: NSPanel { panel }

  func hide() {
    hideTimer?.invalidate()
    panel.orderOut(nil)
    area = nil
  }
}
