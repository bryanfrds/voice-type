import AVFoundation
import Speech

// One hold of Ctrl + Option. The mic is saved to a file for Whisper, which gives the final
// text, and fed to Apple's speech recognizer, which gives the live words for the bubble.
final class Recording {
  let url: URL
  private let engine = AVAudioEngine()
  private var file: AVAudioFile?
  private let request = SFSpeechAudioBufferRecognitionRequest()
  private var task: SFSpeechRecognitionTask?

  init?(url: URL, onWords: @escaping (String) -> Void) {
    self.url = url
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
      request.shouldReportPartialResults = true
      request.addsPunctuation = true
      if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
      task = recognizer.recognitionTask(with: request) { result, _ in
        guard let words = result?.bestTranscription.formattedString else { return }
        DispatchQueue.main.async { onWords(words) }
      }
    }

    let request = self.request
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
      try? file.write(from: buffer)
      request.append(buffer)
    }
    do { try engine.start() } catch {
      log("could not start the microphone: \(error)")
      input.removeTap(onBus: 0)
      try? FileManager.default.removeItem(at: url)
      return nil
    }
  }

  // Stops the mic and closes the file so Whisper can read all of it.
  func finish() {
    engine.stop()
    engine.inputNode.removeTap(onBus: 0)
    request.endAudio()
    task?.cancel()
    file?.close()
    file = nil
  }

  func discard() {
    finish()
    try? FileManager.default.removeItem(at: url)
  }
}
