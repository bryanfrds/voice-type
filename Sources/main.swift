// VoiceType: hold Ctrl + Option, talk, let go. The speech is turned into text on this Mac
// by whisper.cpp and pasted wherever the cursor is.
import AppKit
import AVFoundation

let home = FileManager.default.homeDirectoryForCurrentUser.path
let modelPath = ProcessInfo.processInfo.environment["VOICE_TYPE_MODEL"]
  ?? home + "/.local/share/voice-type/ggml-small.en.bin"
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
let tempPrefix = NSTemporaryDirectory() + "voice-type-"

let logURL = URL(fileURLWithPath: home + "/Library/Logs/voice-type.log")

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

enum State { case idle, recording, transcribing }

final class App: NSObject, NSApplicationDelegate {
  var statusItem: NSStatusItem!
  var tap: CFMachPort?
  var recorder: AVAudioRecorder?
  var state = State.idle
  var startedAt = Date()
  var feedbackTimer: Timer?
  var limitTimer: Timer?
  var loggedWaiting = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let menu = NSMenu()
    menu.addItem(withTitle: "Hold Ctrl + Option to talk", action: nil, keyEquivalent: "")
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit VoiceType", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    statusItem.menu = menu
    removeLeftoverRecordings()

    guard whisperPath != nil, FileManager.default.fileExists(atPath: modelPath) else {
      log("whisper-cli or the model is missing; run install.sh")
      show("mic.slash", tint: .systemOrange)
      return
    }
    show("mic", tint: nil)
    AVCaptureDevice.requestAccess(for: .audio) { granted in
      if !granted { log("microphone access was refused") }
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

  // A key or click while Ctrl + Option is held means a shortcut, not talking.
  func otherInput() {
    if state == .recording { cancelRecording() }
  }

  func startRecording() {
    let url = URL(fileURLWithPath: tempPrefix + "\(UUID().uuidString).wav")
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
    ]
    guard let recorder = try? AVAudioRecorder(url: url, settings: settings), recorder.record() else {
      log("could not start recording")
      try? FileManager.default.removeItem(at: url)
      return
    }
    self.recorder = recorder
    state = .recording
    startedAt = Date()
    feedbackTimer = Timer.scheduledTimer(withTimeInterval: feedbackDelay, repeats: false) { _ in
      self.show("mic.fill", tint: .systemRed)
      NSSound(named: "Tink")?.play()
    }
    limitTimer = Timer.scheduledTimer(withTimeInterval: maximumHold, repeats: false) { _ in
      log("stopped a recording that ran past \(Int(maximumHold))s")
      self.stopRecording()
    }
  }

  func cancelRecording() {
    feedbackTimer?.invalidate()
    limitTimer?.invalidate()
    if let recorder {
      recorder.stop()
      recorder.deleteRecording()
    }
    recorder = nil
    state = .idle
    show("mic", tint: nil)
  }

  func stopRecording() {
    guard let recorder, Date().timeIntervalSince(startedAt) >= minimumHold else {
      cancelRecording()
      return
    }
    feedbackTimer?.invalidate()
    limitTimer?.invalidate()
    recorder.stop()
    self.recorder = nil
    state = .transcribing
    show("ellipsis", tint: nil)
    let url = recorder.url
    DispatchQueue.global(qos: .userInitiated).async {
      let text = transcribe(url)
      try? FileManager.default.removeItem(at: url)
      DispatchQueue.main.async {
        if !text.isEmpty { paste(text + " ") }
        self.state = .idle
        self.show("mic", tint: nil)
        self.recheckModifiers()  // Ctrl + Option may already be held for the next sentence
      }
    }
  }

  func show(_ symbol: String, tint: NSColor?) {
    statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "VoiceType")
    statusItem.button?.contentTintColor = tint
  }

  // Recordings left by a quit or crash mid-recording.
  func removeLeftoverRecordings() {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    for file in files where file.path.hasPrefix(tempPrefix) { try? FileManager.default.removeItem(at: file) }
  }
}

let onEvent: CGEventTapCallBack = { _, type, event, _ in
  switch type {
  case .tapDisabledByTimeout, .tapDisabledByUserInput:
    if let tap = app.tap { CGEvent.tapEnable(tap: tap, enable: true) }
    app.recheckModifiers()
  case .flagsChanged: app.modifiersChanged(event.flags)
  case .keyDown, .leftMouseDown, .rightMouseDown: app.otherInput()
  default: break
  }
  return Unmanaged.passUnretained(event)
}

func transcribe(_ url: URL) -> String {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: whisperPath!)
  process.arguments = ["-m", modelPath, "-f", url.path, "-l", "en", "-nt", "-np"]
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

// Whisper marks silence and noise as [BLANK_AUDIO] or (wind blowing); those aren't words.
func clean(_ raw: String) -> String {
  raw.components(separatedBy: .newlines)
    .map { $0.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
             .trimmingCharacters(in: .whitespaces) }
    .filter { !$0.isEmpty && !($0.hasPrefix("(") && $0.hasSuffix(")")) }
    .joined(separator: " ")
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
  for down in [true, false] {
    let event = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: down)  // 9 is V
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
