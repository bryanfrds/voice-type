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

func log(_ message: String) {
  FileHandle.standardError.write(Data("\(Date()) \(message)\n".utf8))
}

enum State { case idle, recording, transcribing }

final class App: NSObject, NSApplicationDelegate {
  var statusItem: NSStatusItem!
  var tap: CFMachPort?
  var recorder: AVAudioRecorder?
  var state = State.idle
  var startedAt = Date()
  var feedbackTimer: Timer?

  func applicationDidFinishLaunching(_ notification: Notification) {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let menu = NSMenu()
    menu.addItem(withTitle: "Hold Ctrl + Option to talk", action: nil, keyEquivalent: "")
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit VoiceType", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    statusItem.menu = menu

    guard whisperPath != nil, FileManager.default.fileExists(atPath: modelPath) else {
      log("whisper-cli or the model is missing; run install.sh")
      show("mic.slash", tint: .systemOrange)
      return
    }
    show("mic", tint: nil)
    AVCaptureDevice.requestAccess(for: .audio) { granted in
      if !granted { log("microphone access was refused") }
    }
    // Asks for Accessibility, which both watching the keys and pasting need.
    let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(prompt)
    startWatchingKeys()
  }

  // Keeps trying until Accessibility is allowed, so no restart is needed after granting it.
  func startWatchingKeys() {
    let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
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
    log("watching for Ctrl + Option")
  }

  func modifiersChanged(_ flags: CGEventFlags) {
    let held = flags.contains([.maskControl, .maskAlternate])
      && flags.intersection([.maskCommand, .maskShift]).isEmpty
    if held && state == .idle { startRecording() }
    else if !held && state == .recording { stopRecording() }
  }

  // A key pressed while Ctrl + Option is held means a shortcut, not talking.
  func keyPressed() {
    if state == .recording { cancelRecording() }
  }

  func startRecording() {
    let url = URL(fileURLWithPath: NSTemporaryDirectory() + "voice-type-\(UUID().uuidString).wav")
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
    ]
    guard let recorder = try? AVAudioRecorder(url: url, settings: settings), recorder.record() else {
      log("could not start recording")
      return
    }
    self.recorder = recorder
    state = .recording
    startedAt = Date()
    feedbackTimer = Timer.scheduledTimer(withTimeInterval: feedbackDelay, repeats: false) { _ in
      self.show("mic.fill", tint: .systemRed)
      NSSound(named: "Tink")?.play()
    }
  }

  func cancelRecording() {
    feedbackTimer?.invalidate()
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
      }
    }
  }

  func show(_ symbol: String, tint: NSColor?) {
    statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "VoiceType")
    statusItem.button?.contentTintColor = tint
  }
}

let onEvent: CGEventTapCallBack = { _, type, event, _ in
  switch type {
  case .tapDisabledByTimeout, .tapDisabledByUserInput:
    if let tap = app.tap { CGEvent.tapEnable(tap: tap, enable: true) }
  case .flagsChanged: app.modifiersChanged(event.flags)
  case .keyDown: app.keyPressed()
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

// Pastes through the clipboard with Cmd + V, then puts back what was on the clipboard before.
func paste(_ text: String) {
  let board = NSPasteboard.general
  let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
    let copy = NSPasteboardItem()
    for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
    return copy
  }
  board.clearContents()
  board.setString(text, forType: .string)
  let source = CGEventSource(stateID: .combinedSessionState)
  for down in [true, false] {
    let event = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: down)  // 9 is V
    event?.flags = .maskCommand
    event?.post(tap: .cghidEventTap)
  }
  DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
    board.clearContents()
    if !saved.isEmpty { board.writeObjects(saved) }
  }
}

let app = App()
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.delegate = app
NSApplication.shared.run()
