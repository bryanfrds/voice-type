import AppKit

// Which screen the bubble goes on: the one holding the window you're typing into, so it
// shows where you're looking even when the mouse is on another monitor.

// Accessibility reports window positions from the top-left of the main screen, y down;
// AppKit measures from its bottom-left, y up. `mainHeight` is the main screen's height.
func appKitRect(fromAccessibility rect: CGRect, mainHeight: CGFloat) -> CGRect {
  CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
}

// The screen holding the middle of `window` (AppKit coordinates), else the one holding the
// mouse, else the first. Returns an index into `screens`, or nil when there are none.
func screenIndex(window: CGRect?, mouse: CGPoint, screens: [CGRect]) -> Int? {
  if let window, let i = screens.firstIndex(where: { $0.contains(CGPoint(x: window.midX, y: window.midY)) }) {
    return i
  }
  return screens.firstIndex(where: { $0.contains(mouse) }) ?? (screens.isEmpty ? nil : 0)
}

// The frame of the focused window of the frontmost app, in AppKit coordinates, or nil if
// Accessibility can't say (no focused window, or the permission is off).
func focusedWindowFrame() -> CGRect? {
  guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
  let element = AXUIElementCreateApplication(app.processIdentifier)
  AXUIElementSetMessagingTimeout(element, 0.25)
  var window: CFTypeRef?
  guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success,
        let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
  let axWindow = window as! AXUIElement
  AXUIElementSetMessagingTimeout(axWindow, 0.25)   // a hung app mustn't freeze VoiceType
  var position = CGPoint.zero, size = CGSize.zero
  guard let p = axValue(axWindow, kAXPositionAttribute), AXValueGetValue(p, .cgPoint, &position),
        let s = axValue(axWindow, kAXSizeAttribute), AXValueGetValue(s, .cgSize, &size) else { return nil }
  guard let mainHeight = NSScreen.screens.first?.frame.height else { return nil }
  return appKitRect(fromAccessibility: CGRect(origin: position, size: size), mainHeight: mainHeight)
}

// An attribute of an Accessibility element that is an AXValue (a point, size...), or nil.
private func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
        let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
  return (value as! AXValue)
}
