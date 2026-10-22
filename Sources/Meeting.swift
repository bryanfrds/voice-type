import AVFoundation
import AppKit
import ScreenCaptureKit

// A meeting being recorded: the mic to mic-N.wav files and, when Screen Recording is
// allowed, the Mac's own sound to call.wav (a call's other side). Kept apart so the
// transcript can say who spoke. In a room with no call, only the mic has anything.
final class MeetingRecording: NSObject, SCStreamOutput, SCStreamDelegate {
  let started = Date()
  let folder: URL
  let callURL: URL
  private let engine = AVAudioEngine()
  private let lock = NSLock()            // the mic file and parts: main and audio threads
  private var micFile: AVAudioFile?
  private var parts: [MicPart] = []
  private var micStopped = false         // set first thing in stop(); ends mic restarts
  private var stream: SCStream?
  private var callFile: AVAudioFile?
  private var stopped = false            // read and written on callQueue only
  private let callQueue = DispatchQueue(label: "voice-type.meeting-call-audio")
  private var starting: Task<Void, Never>?
  private var configObserver: NSObjectProtocol?

  init?(folder: URL) {
    self.folder = folder
    callURL = folder.appendingPathComponent("call.wav")
    super.init()
    guard startMic() else { return nil }
    // A new mic (AirPods connecting, say) stops the engine; carry on in a new file.
    // Runs on main, as stop() does its mic teardown, so the two can't interleave; a failed
    // restart doesn't end it, so the next change (AirPods finishing connecting) tries again.
    configObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
      guard let self, !self.lock.withLock({ self.micStopped }) else { return }
      log("meeting: the microphone changed; carrying on in a new file")
      self.engine.inputNode.removeTap(onBus: 0)
      self.closeMicFile()
      if !self.startMic() { log("meeting: the new microphone couldn't start; waiting for the next change") }
    }
    starting = Task { await startCallAudio() }
  }

  // The mic files so far, each with when it started.
  var micParts: [MicPart] { lock.withLock { parts } }

  // Starts the mic into a new file, numbered after the ones before it, whose start time
  // is kept so its words land at the right moment in the transcript.
  private func startMic() -> Bool {
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    let part = MicPart(url: folder.appendingPathComponent("mic-\(micParts.count + 1).wav"),
                       offset: Int(Date().timeIntervalSince(started) * 1000))
    guard format.sampleRate > 0,
          let file = try? AVAudioFile(forWriting: part.url, settings: format.settings,
                                      commonFormat: format.commonFormat, interleaved: format.isInterleaved) else {
      log("meeting: no microphone input")
      return false
    }
    lock.withLock {
      micFile = file
      parts.append(part)
    }
    input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
      guard let self else { return }
      self.lock.withLock { try? self.micFile?.write(from: buffer) }
    }
    do { try engine.start() } catch {
      log("meeting: could not start the microphone: \(error)")
      input.removeTap(onBus: 0)
      closeMicFile()
      // Nothing was recorded, so the empty file mustn't count as a part (or a failure).
      lock.withLock { _ = parts.popLast() }
      try? FileManager.default.removeItem(at: part.url)
      return false
    }
    return true
  }

  // Dropping the AVAudioFile is what writes its header, so Whisper can read it.
  private func closeMicFile() { lock.withLock { micFile = nil } }

  // The Mac's sound through ScreenCaptureKit. Without Screen Recording permission this
  // fails, macOS asks for it once, and the meeting carries on with the mic alone.
  private func startCallAudio() async {
    do {
      let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
      guard let display = content.displays.first else { return }
      let config = SCStreamConfiguration()
      config.capturesAudio = true
      config.excludesCurrentProcessAudio = true
      config.sampleRate = 48_000
      config.channelCount = 1
      // Video can't be turned off, so ask for the least of it.
      config.width = 2
      config.height = 2
      config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
      let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                            configuration: config, delegate: self)
      try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: callQueue)
      try await stream.startCapture()
      self.stream = stream
    } catch {
      log("meeting: no call audio, recording the mic only (\(error.localizedDescription))")
    }
  }

  func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
    // On callQueue, like `stopped`: nothing after Stop reopens or rewrites call.wav.
    guard type == .audio, !stopped, buffer.isValid,
          let description = buffer.formatDescription?.audioStreamBasicDescription else { return }
    var asbd = description
    guard let format = AVAudioFormat(streamDescription: &asbd) else { return }
    try? buffer.withAudioBufferList { list, _ in
      guard let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer) else { return }
      if callFile == nil {
        callFile = try? AVAudioFile(forWriting: callURL, settings: format.settings,
                                    commonFormat: format.commonFormat, interleaved: format.isInterleaved)
      }
      try? callFile?.write(from: pcm)
    }
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    log("meeting: call audio stopped: \(error.localizedDescription)")
  }

  // Stops both and closes the files so Whisper can read them. Waits for the call audio to
  // finish starting first, so a capture that was still starting can't keep running.
  func stop() async {
    lock.withLock { micStopped = true }
    await MainActor.run {
      if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
      closeMicFile()
    }
    callQueue.sync { stopped = true }
    await starting?.value
    if let stream {
      do { try await stream.stopCapture() } catch { log("meeting: stopping call audio: \(error.localizedDescription)") }
    }
    stream = nil
    callQueue.sync { callFile = nil }
  }
}

struct MicPart {
  let url: URL
  let offset: Int  // ms from the start of the meeting
}

// The whisper-cli processes transcribing meetings, so quitting can stop them.
let meetingProcesses = Locked<[Process]>([])

final class Locked<Value> {
  private let lock = NSLock()
  private var value: Value
  init(_ value: Value) { self.value = value }
  func with<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&value) } }
}

// Runs a tool on a meeting recording and waits for it without holding a thread, its output
// going to `output` if given. False when it failed. The limit is three times the
// recording's length; `purpose` says in the log what it was doing ("transcribing").
func runTool(_ path: String, _ arguments: [String], output: URL? = nil, on url: URL,
             length: TimeInterval, purpose: String) async -> Bool {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: path)
  process.arguments = arguments
  // A file rather than a pipe, so a long meeting's output can't fill the pipe and stall it.
  if let output, FileManager.default.createFile(atPath: output.path, contents: nil) {
    process.standardOutput = (try? FileHandle(forWritingTo: output)) ?? FileHandle.nullDevice
  } else {
    process.standardOutput = FileHandle.nullDevice
  }
  process.standardError = FileHandle.nullDevice
  let name = URL(fileURLWithPath: path).lastPathComponent
  let limit = max(300, length * 3)
  meetingProcesses.with { $0.append(process) }  // before run, so a quit can't miss it
  let status: Int32? = await withCheckedContinuation { done in
    process.terminationHandler = { done.resume(returning: $0.terminationStatus) }
    do { try process.run() } catch {
      log("meeting: \(name) failed to start: \(error)")
      process.terminationHandler = nil
      done.resume(returning: nil)
      return
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + limit) {
      if process.isRunning {
        log("meeting: \(name) took over \(Int(limit))s on \(url.lastPathComponent); stopped it")
        process.terminate()
      }
    }
  }
  meetingProcesses.with { $0.removeAll { $0 === process } }
  try? (process.standardOutput as? FileHandle)?.close()
  guard status == 0 else {
    log("meeting: \(name) failed \(purpose) \(url.lastPathComponent) (exit \(status.map(String.init) ?? "none"))")
    return false
  }
  return true
}

// Whisper over a whole recording, as segments for `speaker` shifted by `offset` ms. Nil when
// it failed (as opposed to [] for silence), so the audio is kept rather than thrown away.
func meetingSegments(_ url: URL, speaker: String, offset: Int = 0, length: TimeInterval) async -> [Segment]? {
  guard FileManager.default.fileExists(atPath: url.path) else { return [] }
  let base = url.deletingPathExtension().path
  guard let model = modelPath(), let whisper = whisperPath,
        await runTool(whisper, ["-m", model, "-l", "auto"] + segmentOptions(for: speaker) + ["-f", url.path, "-oj", "-of", base, "-np"],
                      on: url, length: length, purpose: "transcribing"),
        let data = FileManager.default.contents(atPath: base + ".json"),
        let found = segments(fromWhisperJSON: data, speaker: speaker) else {
    log("meeting: no transcript for \(url.lastPathComponent)")
    return nil
  }
  return shifted(found, by: offset)
}

// sherpa-onnx's speaker diarization and its two models, which install.sh puts beside the
// speech models: one finds where someone is speaking, the other fingerprints each voice.
let diarizer = modelDir + "sherpa-onnx-offline-speaker-diarization"
let voiceFinder = modelDir + "speaker-segmentation.onnx"
let voicePrinter = modelDir + "nemo_en_titanet_small.onnx"
// How alike two voices must be to count as one person. 0.85 told the people apart in all
// four of sherpa-onnx's test recordings (two to four people, English and Chinese).
let sameVoice = "0.85"

// Who was speaking when in a recording, shifted by `offset` ms. Only a help for reading the
// transcript, so a missing tool or a failure gives [] and loses nothing.
func meetingVoices(_ url: URL, offset: Int = 0, length: TimeInterval) async -> [VoiceSpan] {
  let files = [diarizer, voiceFinder, voicePrinter]
  guard FileManager.default.fileExists(atPath: url.path),
        files.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) else { return [] }
  // The diarizer only takes 16 kHz mono; the mic records at whatever the device gives.
  let base = url.deletingPathExtension().path
  let small = URL(fileURLWithPath: base + "-16k.wav")
  let output = URL(fileURLWithPath: base + "-voices.txt")
  guard await runTool("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", url.path, small.path],
                      on: url, length: length, purpose: "converting"),
        await runTool(diarizer, ["--segmentation.pyannote-model=" + voiceFinder, "--embedding.model=" + voicePrinter,
                                 "--clustering.cluster-threshold=" + sameVoice, small.path],
                      output: output, on: url, length: length, purpose: "telling voices apart in"),
        let text = try? String(contentsOf: output, encoding: .utf8) else { return [] }
  return voiceSpans(fromDiarization: text).map {
    VoiceSpan(start: $0.start + offset, end: $0.end + offset, speaker: $0.speaker)
  }
}

// Asks DeepSeek for the summary. Returns it, or nil with the reason to show in the note.
func summarize(_ transcript: String) async -> (String?, String?) {
  let config = try? String(contentsOfFile: home + "/.config/voice-type/config", encoding: .utf8)
  guard let key = deepSeekKey(environment: ProcessInfo.processInfo.environment, config: config) else {
    return (nil, "add DEEPSEEK_API_KEY to ~/.config/voice-type/config")
  }
  do {
    let (data, response) = try await URLSession.shared.data(for: summaryRequest(transcript: transcript, key: key))
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    if status == 200, let text = summary(fromReply: data) { return (text, nil) }
    // Error bodies say what went wrong; a 200 body would be meeting content, so not that.
    log("meeting: DeepSeek answered \(status)" +
        (status == 200 ? " with a reply that couldn't be read" : ": \(String(decoding: data.prefix(300), as: UTF8.self))"))
    switch status {
    case 200: return (nil, "DeepSeek's reply couldn't be read")
    case 401: return (nil, "DeepSeek didn't accept the API key")
    case 402: return (nil, "the DeepSeek balance is empty")
    default: return (nil, "DeepSeek answered with an error (\(status))")
    }
  } catch {
    log("meeting: DeepSeek request failed: \(error.localizedDescription)")
    return (nil, "DeepSeek couldn't be reached")
  }
}

let meetingNotesFolder = URL(fileURLWithPath: home + "/Documents/Meeting Notes")

// A free path in the notes folder: "<stem><ext>", or "<stem> (2)<ext>" if that's taken.
// (Stems like "2026-10-17 14.30" contain a dot, so the extension is passed separately.)
func freeNoteURL(stem: String, ext: String) -> URL {
  var url = meetingNotesFolder.appendingPathComponent(stem + ext)
  var n = 2
  while FileManager.default.fileExists(atPath: url.path) {
    url = meetingNotesFolder.appendingPathComponent("\(stem) (\(n))\(ext)")
    n += 1
  }
  return url
}

// Moves a meeting's audio next to the notes, so a failed or interrupted meeting isn't lost.
// Returns where it went.
@discardableResult
func keepAudio(_ folder: URL, started: Date, label: String) -> URL? {
  try? FileManager.default.createDirectory(at: meetingNotesFolder, withIntermediateDirectories: true)
  let target = freeNoteURL(stem: noteStem(for: started) + " " + label, ext: "")
  do { try FileManager.default.moveItem(at: folder, to: target) } catch {
    log("meeting: could not keep the audio: \(error)")
    return nil
  }
  return target
}

// From a stopped recording to a note in ~/Documents/Meeting Notes, opened when ready. The
// audio is deleted once the transcript is in the note; if Whisper failed, it's kept beside it.
// `progress` hears each step ("Transcribing 1 of 2…", "Summarizing…").
func writeNotes(_ recording: MeetingRecording, progress: @escaping (String) async -> Void = { _ in }) async -> URL? {
  let length = Date().timeIntervalSince(recording.started)
  let parts = recording.micParts
  let steps = parts.count + 1
  await progress(transcribingStep(1, of: steps))
  let call = await meetingSegments(recording.callURL, speaker: "Others", length: length)
  // With no one heard through the Mac, it was a room: everyone is on the mic. (If the call
  // side failed, that can't be told, so the mic stays "You".)
  let micSpeaker = call?.isEmpty == true ? "Room" : "You"
  var mic: [Segment] = []
  var numbers: [String: Int] = [:]  // speaker numbers, kept across the mic files
  var micFailed = false
  for (i, part) in parts.enumerated() {
    await progress(transcribingStep(i + 2, of: steps))
    if var found = await meetingSegments(part.url, speaker: micSpeaker, offset: part.offset, length: length) {
      if micSpeaker == "Room", !found.isEmpty {
        await progress("Telling voices apart…")
        let voices = await meetingVoices(part.url, offset: part.offset, length: length)
        found = labellingPart(found, voices: voices, part: i, numbers: &numbers)
      }
      mic += found
    } else {
      micFailed = true  // the other parts still go in the note; the audio is kept
    }
  }
  let failed = call == nil || micFailed
  let text = transcript([mic, call ?? []])
  let (summaryText, reason): (String?, String?)
  if text.isEmpty {
    (summaryText, reason) = (nil, failed ? "the transcription failed" : "nothing was heard")
  } else {
    await progress("Summarizing meeting notes…")
    (summaryText, reason) = await summarize(text)
  }
  try? FileManager.default.createDirectory(at: meetingNotesFolder, withIntermediateDirectories: true)
  var body = note(date: recording.started, length: Int(length * 1000), summary: summaryText,
                  missing: reason, transcript: text)
  if failed, let kept = keepAudio(recording.folder, started: recording.started, label: "audio") {
    body += "\n_Part of the transcription failed, so the recording is kept in \"\(kept.lastPathComponent)\"._\n"
  }
  let file = freeNoteURL(stem: noteStem(for: recording.started), ext: ".md")
  do { try body.write(to: file, atomically: true, encoding: .utf8) } catch {
    log("meeting: could not save the note: \(error)")
    if !failed { keepAudio(recording.folder, started: recording.started, label: "audio") }
    return nil
  }
  if !failed { try? FileManager.default.removeItem(at: recording.folder) }
  log("meeting: \(Int(length))s, \(mic.count + (call ?? []).count) segments\(failed ? ", transcription failed" : ""), saved \(file.lastPathComponent)")
  return file
}

// Meetings left in the temp folder by a quit or crash: moved beside the notes, not deleted.
func recoverMeetings() {
  let dir = URL(fileURLWithPath: NSTemporaryDirectory())
  let found = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
  for folder in found where folder.path.hasPrefix(tempPrefix + "meeting-") {
    let created = (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
    if let kept = keepAudio(folder, started: created, label: "unfinished") {
      log("meeting: kept an unfinished meeting's audio in \(kept.lastPathComponent)")
    }
  }
}
