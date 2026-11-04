// voice-type-voiceprint: one voiceprint (speaker embedding) for one person in a recording.
//   voice-type-voiceprint <model.onnx> <16 kHz mono wav> <start ms> <end ms> [<start> <end>...]
// Every given stretch is fed in as one stream, so all of a person's speech counts. Prints
// the voiceprint as one line of numbers, or exits 1 with nothing printed. install.sh
// builds it against sherpa-onnx's C library; VoiceType compares the prints itself.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "sherpa-onnx/c-api/c-api.h"

int main(int argc, char *argv[]) {
  if (argc < 5 || (argc - 3) % 2 != 0) {
    fprintf(stderr, "usage: %s model.onnx audio.wav start_ms end_ms [start_ms end_ms...]\n", argv[0]);
    return 1;
  }
  const SherpaOnnxWave *wave = SherpaOnnxReadWave(argv[2]);
  if (!wave || wave->sample_rate != 16000) {
    fprintf(stderr, "needs a 16 kHz wav\n");
    return 1;
  }
  SherpaOnnxSpeakerEmbeddingExtractorConfig config;
  memset(&config, 0, sizeof(config));
  config.model = argv[1];
  config.num_threads = 2;
  config.provider = "cpu";
  const SherpaOnnxSpeakerEmbeddingExtractor *extractor = SherpaOnnxCreateSpeakerEmbeddingExtractor(&config);
  if (!extractor) {
    fprintf(stderr, "could not load %s\n", argv[1]);
    return 1;
  }
  const SherpaOnnxOnlineStream *stream = SherpaOnnxSpeakerEmbeddingExtractorCreateStream(extractor);
  for (int i = 3; i + 1 < argc; i += 2) {
    long start = atol(argv[i]) * 16, end = atol(argv[i + 1]) * 16;  // ms to samples at 16 kHz
    if (start < 0) start = 0;
    if (end > wave->num_samples) end = wave->num_samples;
    if (end > start) SherpaOnnxOnlineStreamAcceptWaveform(stream, 16000, wave->samples + start, (int32_t)(end - start));
  }
  SherpaOnnxOnlineStreamInputFinished(stream);
  if (!SherpaOnnxSpeakerEmbeddingExtractorIsReady(extractor, stream)) {
    fprintf(stderr, "too little speech\n");
    return 1;
  }
  const float *print = SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(extractor, stream);
  if (!print) {
    fprintf(stderr, "no voiceprint\n");
    return 1;
  }
  int32_t dim = SherpaOnnxSpeakerEmbeddingExtractorDim(extractor);
  for (int32_t i = 0; i < dim; i++) printf(i ? " %.6g" : "%.6g", print[i]);
  printf("\n");
  SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding(print);
  SherpaOnnxDestroyOnlineStream(stream);
  SherpaOnnxDestroySpeakerEmbeddingExtractor(extractor);
  SherpaOnnxFreeWave(wave);
  return 0;
}
