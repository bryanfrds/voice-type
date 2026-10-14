import AVFoundation
import Speech

// What to tell the user when a permission VoiceType needs has been turned off: the menu text
// and the Privacy & Security page that fixes it. The mic matters most, since without it
// nothing is heard; Speech Recognition only feeds the live words in the bubble.
struct PermissionWarning: Equatable {
  let title: String
  let pane: String
  let blocksRecording: Bool
}

func permissionWarning(mic: AVAuthorizationStatus, speech: SFSpeechRecognizerAuthorizationStatus) -> PermissionWarning? {
  if mic == .denied || mic == .restricted {
    return PermissionWarning(title: "Microphone is off: open Settings to allow it",
                             pane: "Privacy_Microphone", blocksRecording: true)
  }
  if speech == .denied || speech == .restricted {
    return PermissionWarning(title: "Live words are off: allow Speech Recognition",
                             pane: "Privacy_SpeechRecognition", blocksRecording: false)
  }
  return nil
}
