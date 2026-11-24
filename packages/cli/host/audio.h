// The native Web Audio engine's internals: the context, its buffers and the few entry points the
// decoder file shares. The runtime only reaches the engine through the host_audio_* symbols in
// audio.c; audio-decode.c includes this header to allocate the buffers it decodes into.

#ifndef NATIVE_SDK_AUDIO_H
#define NATIVE_SDK_AUDIO_H

#include <stddef.h>
#include <stdint.h>

#define AUDIO_QUANTUM 128
#define AUDIO_MAX_NODES 512
#define AUDIO_MAX_INPUTS 32
#define AUDIO_MAX_PARAMS 12
#define AUDIO_MAX_BUFFERS 4096
#define AUDIO_ANALYSER_RING 32768

typedef struct {
  int channels;
  int frames;
  double rate;
  float *data[2];
} AudioBufferData;

typedef struct AudioContext AudioContext;

/** The context with this id, or NULL when no context has it (or it has closed). */
AudioContext *audio_context_get(int32_t id);

/** The context's sample rate: the rate decodeAudioData decodes to. */
double audio_context_rate(AudioContext *c);

/** Allocates a silent buffer with room for `frames` frames on each channel. */
int32_t audio_buffer_new(AudioContext *c, int channels, int frames, double rate);

/** The buffer with this id, or NULL. */
AudioBufferData *audio_buffer_get(AudioContext *c, int32_t id);

/** Frees a buffer's channel data (used by a decoder that failed part way through). */
void audio_buffer_free(AudioBufferData *b);

#endif
