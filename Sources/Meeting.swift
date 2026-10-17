import AVFoundation
import AppKit
import ScreenCaptureKit

// A meeting being recorded: the mic to one file ("You") and, when Screen Recording is
// allowed, the Mac's own sound to another ("Others": a call's other side). Kept apart so
// the transcript can say who spoke. In a room with no call, only the mic has anything.
final class MeetingRecording: NSObject, SCStreamOutput, SCStreamDelegate {
  let started = Date()
  let micURL: URL
  let callURL: URL
  private let engine = AVAudioEngine()
  private var stream: SCStream?
  private var callFile: AVAudioFile?
  private let callQueue = DispatchQueue(label: "voice-type.meeting-call-audio")

  init?(folder: URL) {
    micURL = folder.appendingPathComponent("mic.wav")
    callURL = folder.appendingPathComponent("call.wav")
    super.init()
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0,
          let file = try? AVAudioFile(forWriting: micURL, settings: format.settings,
                                      commonFormat: format.commonFormat, interleaved: format.isInterleaved) else {
      log("meeting: no microphone input")
      return nil
    }
    input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in try? file.write(from: buffer) }
    do { try engine.start() } catch {
      log("meeting: could not start the microphone: \(error)")
      input.removeTap(onBus: 0)
      return nil
    }
    Task { await startCallAudio() }
  }

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
    guard type == .audio, buffer.isValid,
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

  // Stops both, then closes the files so Whisper can read them.
  func stop() async {
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    if let stream { try? await stream.stopCapture() }
    stream = nil
    callQueue.sync { callFile = nil }
  }
}

// Whisper over a whole recording, as segments for `speaker`. Long meetings take minutes, so
// this runs off the main thread, with a limit that grows with the recording.
func meetingSegments(_ url: URL, speaker: String, length: TimeInterval) -> [Segment] {
  guard FileManager.default.fileExists(atPath: url.path), let model = modelPath(), let whisper = whisperPath else { return [] }
  let base = url.deletingPathExtension().path
  let process = Process()
  process.executableURL = URL(fileURLWithPath: whisper)
  process.arguments = ["-m", model, "-f", url.path, "-l", "auto", "-oj", "-of", base, "-np"]
  process.standardOutput = FileHandle.nullDevice
  process.standardError = FileHandle.nullDevice
  do { try process.run() } catch {
    log("meeting: whisper-cli failed to start: \(error)")
    return []
  }
  let limit = max(120, length)  // never slower than the meeting itself
  DispatchQueue.global().asyncAfter(deadline: .now() + limit) {
    if process.isRunning {
      log("meeting: whisper-cli took over \(Int(limit))s on \(url.lastPathComponent); stopped it")
      process.terminate()
    }
  }
  process.waitUntilExit()
  guard let data = FileManager.default.contents(atPath: base + ".json") else { return [] }
  return segments(fromWhisperJSON: data, speaker: speaker)
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
    guard status == 200, let text = summary(fromReply: data) else {
      log("meeting: DeepSeek answered \(status): \(String(decoding: data.prefix(300), as: UTF8.self))")
      return (nil, status == 402 ? "the DeepSeek balance is empty" : "DeepSeek answered with an error (\(status))")
    }
    return (text, nil)
  } catch {
    log("meeting: DeepSeek request failed: \(error.localizedDescription)")
    return (nil, "DeepSeek couldn't be reached")
  }
}

// From a stopped recording to a note in ~/Documents/Meeting Notes, opened when ready.
// The audio is deleted once the transcript is in the note.
func writeNotes(_ recording: MeetingRecording, folder: URL) async -> URL? {
  let length = Date().timeIntervalSince(recording.started)
  let you = meetingSegments(recording.micURL, speaker: "You", length: length)
  let others = meetingSegments(recording.callURL, speaker: "Others", length: length)
  let text = transcript([you, others])
  let (summaryText, reason) = text.isEmpty ? (nil, "nothing was heard") : await summarize(text)
  let notes = URL(fileURLWithPath: home + "/Documents/Meeting Notes")
  try? FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
  let file = notes.appendingPathComponent(noteName(for: recording.started))
  let body = note(date: recording.started, length: Int(length * 1000), summary: summaryText,
                  missing: reason, transcript: text)
  do { try body.write(to: file, atomically: true, encoding: .utf8) } catch {
    log("meeting: could not save the note: \(error)")
    return nil
  }
  try? FileManager.default.removeItem(at: folder)
  log("meeting: \(Int(length))s, \(you.count + others.count) segments, saved \(file.lastPathComponent)")
  return file
}
