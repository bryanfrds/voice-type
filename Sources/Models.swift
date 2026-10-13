import Foundation

// The whisper.cpp models VoiceType knows, best first. Only those downloaded can be picked.
struct Model {
  let name: String
  let file: String
}

let models = [
  Model(name: "Accurate (large-v3 turbo)", file: "ggml-large-v3-turbo-q5_0.bin"),
  Model(name: "Fast (small, English)", file: "ggml-small.en.bin"),
]

// The model to use: the one picked in the menu if it's still there, otherwise the best one
// downloaded. Nil when none are.
func chooseModel(picked: String?, downloaded: Set<String>) -> Model? {
  models.first { $0.file == picked && downloaded.contains($0.file) }
    ?? models.first { downloaded.contains($0.file) }
}
