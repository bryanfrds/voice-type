import AVFoundation
import Speech

// One hold of Ctrl + Option. The mic is saved to a file for Whisper, which gives the final
// text, and fed to Apple's speech recognizer, which gives the live words for the bubble.
final class Recording {
  let url: URL
  private let engine = AVAudioEngine()
  private var file: AVAudioFile?
  private let onWords: (String) -> Void
  private let recognizer: SFSpeechRecognizer?
  // The recognizer gives up after a pause, so a new pass starts each time one ends.
  // The audio thread appends to whichever pass is current, hence the lock.
  private let lock = NSLock()
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var earlier = ""  // words from passes that have ended
  private var latest = ""   // words from the current pass
  private var passes = 0
  private var active = true

  init?(url: URL, onWords: @escaping (String) -> Void) {
    self.url = url
    self.onWords = onWords
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0 else {
      log("no microphone input")
      return nil
    }
    let file: AVAudioFile
    do {
      file = try AVAudioFile(forWriting: url, settings: format.settings,
                             commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    } catch {
      log("could not create the recording file: \(error)")
      return nil
    }
    self.file = file

    if SFSpeechRecognizer.authorizationStatus() == .authorized,
       let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.isAvailable {
      self.recognizer = recognizer
    } else {
      recognizer = nil
    }
    startPass()

    input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
      try? file.write(from: buffer)
      guard let self else { return }
      self.lock.withLock { self.request }?.append(buffer)
    }
    do { try engine.start() } catch {
      log("could not start the microphone: \(error)")
      input.removeTap(onBus: 0)
      try? FileManager.default.removeItem(at: url)
      return nil
    }
  }

  private func startPass() {
    // A recognizer that fails straight away every time would otherwise restart forever.
    guard let recognizer, active, passes < 50 else { return }
    passes += 1
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.addsPunctuation = true
    if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
    lock.withLock { self.request = request }
    task = recognizer.recognitionTask(with: request) { [weak self] result, error in
      DispatchQueue.main.async { self?.handle(result, error) }
    }
  }

  private func handle(_ result: SFSpeechRecognitionResult?, _ error: Error?) {
    guard active else { return }
    if let result {
      let words = result.bestTranscription.formattedString
      // After a pause the recognizer can start over within the same pass, without saying
      // so. A result much shorter than the last one, starting differently, is that.
      if startedOver(from: latest, to: words) { earlier = joined(earlier, latest) }
      latest = words
      onWords(joined(earlier, latest))
    }
    if result?.isFinal == true || error != nil {
      earlier = joined(earlier, latest)
      latest = ""
      startPass()
    }
  }

  // Stops the mic and closes the file so Whisper can read all of it.
  func finish() {
    active = false
    engine.stop()
    engine.inputNode.removeTap(onBus: 0)
    lock.withLock { request }?.endAudio()
    task?.cancel()
    file?.close()
    file = nil
  }

  func discard() {
    finish()
    try? FileManager.default.removeItem(at: url)
  }
}
