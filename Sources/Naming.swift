import AppKit

// "Who spoke?": after a meeting in a room, a small window lists each speaker with something
// they said and a box for their name. Saving remembers the named voices for later meetings
// and puts the names in the note; Skip leaves both alone. `done` runs once either way.
final class SpeakerNaming: NSObject, NSWindowDelegate {
  private let window: NSWindow
  private let speakers: [MeetingSpeaker]
  private let note: URL
  private var fields: [NSTextField] = []
  private var done: (() -> Void)?

  init(speakers: [MeetingSpeaker], note: URL, done: @escaping () -> Void) {
    // Only people not known yet: their "Speaker n" labels are unique in the note, so renaming one
    // can't touch anyone else (a known name can appear on two people after a mic change).
    self.speakers = speakers.filter { $0.known == nil }
    self.note = note
    self.done = done
    window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 200),
                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    super.init()
    window.title = "Who spoke?"
    window.isReleasedWhenClosed = false
    window.level = .floating
    window.delegate = self

    let intro = NSTextField(wrappingLabelWithString:
      "Name the people in this meeting and VoiceType will know their voices next time. Leave a box empty to skip someone.")
    intro.textColor = .secondaryLabelColor
    var rows: [[NSView]] = []
    for speaker in self.speakers {
      let label = NSTextField(labelWithString: speaker.label)
      label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
      let said = NSTextField(labelWithString: "“\(speaker.said)”")
      said.textColor = .secondaryLabelColor
      said.lineBreakMode = .byTruncatingTail
      said.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      let field = NSTextField(string: "")
      field.placeholderString = "Name"
      field.widthAnchor.constraint(equalToConstant: 140).isActive = true
      fields.append(field)
      rows.append([label, said, field])
    }
    let grid = NSGridView(views: rows)
    grid.rowSpacing = 8
    grid.columnSpacing = 12
    grid.column(at: 1).width = 260

    let skip = NSButton(title: "Skip", target: self, action: #selector(skipNames))
    skip.keyEquivalent = "\u{1b}"
    let save = NSButton(title: "Save names", target: self, action: #selector(saveNames))
    save.keyEquivalent = "\r"
    let buttons = NSStackView(views: [NSView(), skip, save])
    buttons.orientation = .horizontal

    let stack = NSStackView(views: [intro, grid, buttons])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 16
    stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
    stack.translatesAutoresizingMaskIntoConstraints = false
    let content = NSView()
    content.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      stack.topAnchor.constraint(equalTo: content.topAnchor),
      stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
      intro.widthAnchor.constraint(equalToConstant: 480),
      buttons.widthAnchor.constraint(equalTo: intro.widthAnchor),
    ])
    window.contentView = content
    // Chained so Tab goes down the name boxes.
    for (field, next) in zip(fields, fields.dropFirst()) { field.nextKeyView = next }
    window.initialFirstResponder = fields.first
  }

  func show() {
    window.center()
    NSApp.activate(ignoringOtherApps: true)  // a menu bar app has to, for typing to reach the box
    window.makeKeyAndOrderFront(nil)
  }

  @objc private func saveNames() {
    var saved = loadSavedVoices()
    var text = (try? String(contentsOf: note, encoding: .utf8)) ?? ""
    var named = 0
    for (speaker, field) in zip(speakers, fields) {
      guard let name = usableName(field.stringValue) else {
        if !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty { log("meeting: skipped a name VoiceType uses itself") }
        continue
      }
      saved = remembering(name, print: speaker.print, in: saved)
      text = renamingSpeaker(in: text, from: speaker.label, to: name)
      named += 1
    }
    if named > 0 {
      storeSavedVoices(saved)
      do { try text.write(to: note, atomically: true, encoding: .utf8) } catch {
        log("meeting: could not put the names in the note: \(error)")
      }
      log("meeting: \(named) speakers named, \(saved.count) voices remembered")
    }
    finish()
  }

  @objc private func skipNames() { finish() }

  func windowWillClose(_ notification: Notification) { finish(closing: false) }

  private func finish(closing: Bool = true) {
    guard let done else { return }
    self.done = nil
    window.delegate = nil
    if closing { window.close() }
    done()
  }
}
