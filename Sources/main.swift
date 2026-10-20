// VoiceType: hold Ctrl + Option, talk, let go. The words show in a bubble as you speak; on
// letting go, whisper.cpp turns the speech into text on this Mac and it's pasted wherever the
// cursor is.
import AppKit
import AVFoundation
import Speech

let home = FileManager.default.homeDirectoryForCurrentUser.path
let modelDir = home + "/.local/share/voice-type/"
let modelKey = "model"

func downloadedModels() -> Set<String> {
  Set(models.map(\.file).filter { FileManager.default.fileExists(atPath: modelDir + $0) })
}

// VOICE_TYPE_MODEL, a path to any model file, wins over the menu.
func modelPath() -> String? {
  if let path = ProcessInfo.processInfo.environment["VOICE_TYPE_MODEL"] { return path }
  let picked = UserDefaults.standard.string(forKey: modelKey)
  return chooseModel(picked: picked, downloaded: downloadedModels()).map { modelDir + $0.file }
}
let whisperPath = ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
  .first { FileManager.default.isExecutableFile(atPath: $0) }

// Holds shorter than this are taken as a slip and thrown away.
let minimumHold: TimeInterval = 0.35
// The icon and start sound wait this long, so Ctrl + Option shortcuts don't flash them.
let feedbackDelay: TimeInterval = 0.15
// A recording stops by itself after this long, in case the key release was missed.
let maximumHold: TimeInterval = 120
// whisper-cli is stopped if it takes longer than this.
let transcribeTimeout: TimeInterval = 60
// How long a note like "Didn't catch that" stays in the bubble.
let noteDuration: TimeInterval = 1.5
let tempPrefix = NSTemporaryDirectory() + "voice-type-"

let logURL = URL(fileURLWithPath: home + "/Library/Logs/voice-type.log")
// The log is cut back to its newest part at launch once it passes this size.
let logLimit = 1_000_000

func log(_ message: String) {
  let line = Data("\(Date()) \(message)\n".utf8)
  if let file = try? FileHandle(forWritingTo: logURL) {
    file.seekToEndOfFile()
    file.write(line)
    try? file.close()
  } else {
    try? line.write(to: logURL)
  }
}

// Cuts the log back to its newest part, reading only that part of the file.
func trimLog() {
  guard let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path))?[.size] as? Int,
        size > logLimit, let file = try? FileHandle(forReadingFrom: logURL) else { return }
  try? file.seek(toOffset: UInt64(size - logLimit / 2))
  let tail = (try? file.readToEnd()) ?? Data()
  try? file.close()
  try? newestLines(tail).write(to: logURL, options: .atomic)
}

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
  var statusItem: NSStatusItem!
  var tap: CFMachPort?
  var recording: Recording?
  let bubble = Bubble()
  var words = ""
  var state = State.idle
  var startedAt = Date()
  var feedbackTimer: Timer?
  var limitTimer: Timer?
  var loggedWaiting = false
  var modelItems: [NSMenuItem] = []
  let lastItem = NSMenuItem(title: "No dictation yet", action: nil, keyEquivalent: "")
  var lastText = ""
  let meetingItem = NSMenuItem(title: "Start meeting notes", action: nil, keyEquivalent: "")
  var meeting: MeetingRecording?
  var meetingTimer: Timer?
  var pasteCancelled = false
  let warningItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
  var warningPane = ""

  func applicationDidFinishLaunching(_ notification: Notification) {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let menu = NSMenu()
    menu.addItem(withTitle: "Hold Ctrl + Option to talk", action: nil, keyEquivalent: "")
    warningItem.target = self
    warningItem.action = #selector(openWarningPane)
    warningItem.isHidden = true
    menu.addItem(warningItem)
    menu.delegate = self
    menu.addItem(.separator())
    let downloaded = downloadedModels()
    for model in models where downloaded.contains(model.file) {
      let item = NSMenuItem(title: model.name, action: #selector(pickModel(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = model.file
      menu.addItem(item)
      modelItems.append(item)
    }
    if !modelItems.isEmpty { menu.addItem(.separator()) }
    markPickedModel()

    meetingItem.target = self
    meetingItem.action = #selector(toggleMeeting)
    menu.addItem(meetingItem)
    menu.addItem(.separator())
    lastItem.target = self
    menu.addItem(lastItem)
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit VoiceType", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    statusItem.menu = menu
    trimLog()
    recoverMeetings()
    removeLeftoverRecordings()

    guard whisperPath != nil, let path = modelPath(), FileManager.default.fileExists(atPath: path) else {
      log("whisper-cli or the model is missing; run install.sh")
      show("mic.slash", tint: .systemOrange)
      return
    }
    show("mic", tint: nil)
    AVCaptureDevice.requestAccess(for: .audio) { granted in
      if !granted { log("microphone access was refused") }
    }
    // Only the live words in the bubble need this; without it the final text still works.
    SFSpeechRecognizer.requestAuthorization { status in
      if status != .authorized { log("speech recognition not allowed; the bubble won't show words") }
    }
    // Watching the keys needs Input Monitoring; pasting needs Accessibility. Ask for both.
    let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(prompt)
    if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
    startWatchingKeys()
  }

  // Keeps trying until Input Monitoring is allowed, so no restart is needed after granting it.
  func startWatchingKeys() {
    guard CGPreflightListenEventAccess() else {
      if tap == nil && !loggedWaiting {
        log("waiting for Input Monitoring (Accessibility: \(AXIsProcessTrusted()))")
        loggedWaiting = true
      }
      show("mic.slash", tint: .systemOrange)
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.startWatchingKeys() }
      return
    }
    let mask = [CGEventType.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown]
      .reduce(0) { $0 | (1 << $1.rawValue) }
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                      options: .listenOnly, eventsOfInterest: CGEventMask(mask),
                                      callback: onEvent, userInfo: nil) else {
      show("mic.slash", tint: .systemOrange)
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.startWatchingKeys() }
      return
    }
    self.tap = tap
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    show("mic", tint: nil)
    log("watching for Ctrl + Option (Accessibility: \(AXIsProcessTrusted()))")
  }

  func modifiersChanged(_ flags: CGEventFlags) {
    let held = flags.contains([.maskControl, .maskAlternate])
    let extra = !flags.intersection([.maskCommand, .maskShift]).isEmpty
    switch state {
    case .idle where held && !extra:
      log("Ctrl + Option held")
      startRecording()
    case .recording where extra: cancelRecording()  // Cmd or Shift added: a shortcut
    case .recording where !held: stopRecording()
    default: break
    }
  }

  // Picks up keys held or let go while the key watcher wasn't listening.
  func recheckModifiers() {
    modifiersChanged(CGEventSource.flagsState(.combinedSessionState))
  }

  func otherInput(key: Int64? = nil) {
    switch reaction(to: key, in: state) {
    case .cancelRecording: cancelRecording()
    case .cancelPaste:
      pasteCancelled = true
      hideBubble()
      log("paste cancelled with Esc")
    case .ignore: break
    }
  }

  func startRecording() {
    guard checkPermissions() else {
      log("not recording: microphone access is off")
      return
    }
    hideBubble()  // clears a note left from the last dictation
    let url = URL(fileURLWithPath: tempPrefix + "\(UUID().uuidString).wav")
    words = ""
    guard let recording = Recording(url: url, onWords: { [weak self] words in
      guard let self, self.state == .recording else { return }
      self.words = words
      if self.bubble.isShowing { self.bubble.show(words) }
    }) else { return }
    self.recording = recording
    state = .recording
    startedAt = Date()
    feedbackTimer = Timer.scheduledTimer(withTimeInterval: feedbackDelay, repeats: false) { _ in
      self.show("mic.fill", tint: .systemRed)
      NSSound(named: "Tink")?.play()
      if self.words.isEmpty { self.bubble.show("Listening…", dim: true) } else { self.bubble.show(self.words) }
    }
    limitTimer = Timer.scheduledTimer(withTimeInterval: maximumHold, repeats: false) { _ in
      log("stopped a recording that ran past \(Int(maximumHold))s")
      self.stopRecording()
    }
  }

  func cancelRecording() {
    feedbackTimer?.invalidate()
    limitTimer?.invalidate()
    recording?.discard()
    recording = nil
    state = .idle
    show("mic", tint: nil)
    hideBubble()
  }

  func stopRecording() {
    guard let recording, Date().timeIntervalSince(startedAt) >= minimumHold else {
      cancelRecording()
      return
    }
    feedbackTimer?.invalidate()
    limitTimer?.invalidate()
    recording.finish()
    self.recording = nil
    state = .transcribing
    pasteCancelled = false
    show("ellipsis", tint: nil)
    if bubble.isShowing { bubble.show(words.isEmpty ? "…" : words + " …", dim: true) }
    let url = recording.url
    let held = Date().timeIntervalSince(startedAt)
    DispatchQueue.global(qos: .userInitiated).async {
      let began = Date()
      let text = transcribe(url)
      log(String(format: "held %.1fs; Whisper gave %d characters in %.1fs",
                 held, text.count, Date().timeIntervalSince(began)))
      try? FileManager.default.removeItem(at: url)
      DispatchQueue.main.async {
        switch afterTranscribing(text, pasteCancelled: self.pasteCancelled) {
        case .sayNothingHeard: self.say("Didn't catch that")
        case .nothing: break
        case .paste:
          self.hideBubble()
          paste(text + " ")
          self.remember(text)
        case .keepOnly:
          self.hideBubble()
          self.remember(text)  // kept even after Esc, in case it was a mistake
        }
        self.state = .idle
        self.show("mic", tint: nil)
        self.recheckModifiers()  // Ctrl + Option may already be held for the next sentence
      }
    }
  }

  @objc func pickModel(_ item: NSMenuItem) {
    UserDefaults.standard.set(item.representedObject as? String, forKey: modelKey)
    markPickedModel()
  }

  // Ticks the model in use, which may not be the one picked if that file has gone.
  func markPickedModel() {
    let inUse = modelPath()
    for item in modelItems {
      item.state = (item.representedObject as? String).map { modelDir + $0 } == inUse ? .on : .off
    }
  }

  // The menu keeps the last dictation, so it can be copied again if the paste went astray.
  func remember(_ text: String) {
    lastText = text
    lastItem.title = "Copy “\(preview(text))”"
    lastItem.action = #selector(copyLast)
  }

  // Meeting notes: Start records the mic and the call until Stop; then the transcript and
  // DeepSeek's summary are saved to ~/Documents/Meeting Notes and the note opens.
  @objc func toggleMeeting() {
    if let recording = meeting {
      meeting = nil
      meetingTimer?.invalidate()
      meetingItem.title = "Writing meeting notes…"
      meetingItem.action = nil
      Task {
        await recording.stop()
        let note = await writeNotes(recording)
        await MainActor.run {
          self.meetingItem.title = "Start meeting notes"
          self.meetingItem.action = #selector(self.toggleMeeting)
          if let note { NSWorkspace.shared.open(note) } else { self.say("Couldn't save the meeting notes") }
        }
      }
      return
    }
    guard whisperPath != nil, let model = modelPath(), FileManager.default.fileExists(atPath: model) else {
      say("Meeting notes need whisper.cpp and a model: run install.sh")
      return
    }
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: break
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .audio) { granted in
        DispatchQueue.main.async {
          // Only start: a second click during the prompt mustn't turn into a Stop.
          if !granted { self.say("Meeting notes need microphone access") } else if self.meeting == nil { self.toggleMeeting() }
        }
      }
      return
    default:
      say("Meeting notes need microphone access")
      return
    }
    let folder = URL(fileURLWithPath: tempPrefix + "meeting-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    guard let recording = MeetingRecording(folder: folder) else {
      try? FileManager.default.removeItem(at: folder)
      say("Couldn't start the microphone")
      return
    }
    meeting = recording
    log("meeting: started")
    let update = { [weak self] in
      guard let self, let recording = self.meeting else { return }
      self.meetingItem.title = "Stop meeting notes (\(clock(Int(Date().timeIntervalSince(recording.started) * 1000))))"
    }
    update()
    let timer = Timer(timeInterval: 1, repeats: true) { _ in update() }
    RunLoop.main.add(timer, forMode: .common)  // keeps ticking while the menu is open
    meetingTimer = timer
  }

  @objc func copyLast() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(lastText, forType: .string)
  }

  // Shows a menu warning for a permission that's been turned off. False when the mic is off,
  // since a recording would only be silence.
  @discardableResult
  func checkPermissions() -> Bool {
    let warning = permissionWarning(mic: AVCaptureDevice.authorizationStatus(for: .audio),
                                    speech: SFSpeechRecognizer.authorizationStatus())
    warningItem.isHidden = warning == nil
    warningItem.title = warning.map { "⚠️ " + $0.title } ?? ""
    warningPane = warning?.pane ?? ""
    if warning?.blocksRecording == true { show("mic.slash", tint: .systemOrange) }
    return warning?.blocksRecording != true
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    if checkPermissions() && state == .idle && tap != nil { show("mic", tint: nil) }
  }

  @objc func openWarningPane() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(warningPane)")!)
  }

  func hideBubble() {
    bubble.hide()
  }

  // Shows a short note in the bubble for a moment. Anything shown after it cancels the hide.
  func say(_ note: String) {
    bubble.show(note, dim: true, hidingAfter: noteDuration)
  }

  func show(_ symbol: String, tint: NSColor?) {
    statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "VoiceType")
    statusItem.button?.contentTintColor = tint
  }

  // Recordings left by a quit or crash mid-recording.
  func removeLeftoverRecordings() {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    // Meeting folders are never deleted here: one recoverMeetings() couldn't move is retried
    // at the next launch.
    for file in files where file.path.hasPrefix(tempPrefix) && !file.path.hasPrefix(tempPrefix + "meeting-") {
      try? FileManager.default.removeItem(at: file)
    }
  }

  // Quitting mid-meeting stops the recording and keeps its audio beside the notes, rather
  // than losing it; transcribing it is left for later. Whisper runs for meetings are stopped.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    meetingProcesses.with { $0.filter(\.isRunning).forEach { $0.terminate() } }  // a not-yet-launched one can't be
    guard let recording = meeting else { return .terminateNow }
    meeting = nil
    Task {
      await recording.stop()
      keepAudio(recording.folder, started: recording.started, label: "unfinished")
      log("meeting: quit mid-meeting; kept the audio")
      await MainActor.run { NSApp.reply(toApplicationShouldTerminate: true) }
    }
    return .terminateLater
  }
}

let onEvent: CGEventTapCallBack = { _, type, event, _ in
  switch type {
  case .tapDisabledByTimeout, .tapDisabledByUserInput:
    if let tap = app.tap { CGEvent.tapEnable(tap: tap, enable: true) }
    app.recheckModifiers()
  case .flagsChanged: app.modifiersChanged(event.flags)
  case .keyDown: app.otherInput(key: event.getIntegerValueField(.keyboardEventKeycode))
  case .leftMouseDown, .rightMouseDown: app.otherInput()
  default: break
  }
  return Unmanaged.passUnretained(event)
}

func transcribe(_ url: URL) -> String {
  guard let model = modelPath() else {
    log("no model to transcribe with")
    return ""
  }
  let process = Process()
  process.executableURL = URL(fileURLWithPath: whisperPath!)
  process.arguments = ["-m", model, "-f", url.path, "-l", "en", "-nt", "-np"]
  let output = Pipe()
  process.standardOutput = output
  process.standardError = FileHandle.nullDevice
  do { try process.run() } catch {
    log("whisper-cli failed to start: \(error)")
    return ""
  }
  DispatchQueue.global().asyncAfter(deadline: .now() + transcribeTimeout) {
    if process.isRunning {
      log("whisper-cli took over \(Int(transcribeTimeout))s; stopped it")
      process.terminate()
    }
  }
  let data = output.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  return clean(String(decoding: data, as: UTF8.self))
}

// The user's own clipboard, kept while a transcript sits on it, and the clipboard
// change count of the latest transcript.
var savedClipboard: [NSPasteboardItem]?
var latestPaste = 0

// Pastes through the clipboard with Cmd + V, then puts back what was on the clipboard before.
func paste(_ text: String) {
  let board = NSPasteboard.general
  // A second paste before the first is put back must not save the first transcript.
  if savedClipboard == nil {
    savedClipboard = (board.pasteboardItems ?? []).map { item in
      let copy = NSPasteboardItem()
      for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
      return copy
    }
  }
  let item = NSPasteboardItem()
  item.setString(text, forType: .string)
  // Tells clipboard managers not to keep it.
  item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
  board.clearContents()
  board.writeObjects([item])
  let ours = board.changeCount
  latestPaste = ours
  let source = CGEventSource(stateID: .combinedSessionState)
  let v = keyCode(for: "v") ?? 9  // 9 is where V sits on QWERTY
  for down in [true, false] {
    let event = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: down)
    event?.flags = .maskCommand
    event?.post(tap: .cghidEventTap)
  }
  // Slow apps read the clipboard late, so wait before putting the old one back.
  DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
    guard ours == latestPaste else { return }  // a later paste puts it back instead
    if board.changeCount == ours, let saved = savedClipboard {
      board.clearContents()
      if !saved.isEmpty { board.writeObjects(saved) }
    }
    // If the count moved, the user copied something new; keep that.
    savedClipboard = nil
  }
}

let app = App()
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.delegate = app
NSApplication.shared.run()
