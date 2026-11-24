// decodeAudioData's decoders. WAV is read here, MPEG audio by minimp3 (CC0) and Ogg Vorbis by
// stb_vorbis (public domain / MIT), both vendored as single files with their licences. On macOS
// AudioToolbox reads what it can from the file's own container, which is where AAC and M4A come
// from; the other platforms leave those formats to their own follow-up.
//
// Every decoder produces planar float32 at the file's own rate; a buffer for a context with a
// different rate is resampled linearly on the way in, as decodeAudioData specifies.

#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "audio.h"

#define MINIMP3_IMPLEMENTATION
#define MINIMP3_FLOAT_OUTPUT
#define MINIMP3_NO_SIMD
#include "vendor/minimp3.h"
#define STB_VORBIS_HEADER_ONLY
#include "vendor/stb_vorbis.c"

#if defined(__APPLE__)
#include <AudioToolbox/AudioToolbox.h>
#endif

static uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t rd32(const uint8_t *p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

typedef struct {
  float *left;
  float *right;
  int channels;
  int frames;
  double rate;
} Decoded;

static void decoded_free(Decoded *d) {
  free(d->left);
  free(d->right);
  memset(d, 0, sizeof(*d));
}

// ---------------------------------------------------------------------------
// WAV (RIFF/WAVE, PCM and IEEE float)

static int decode_wav(const uint8_t *data, size_t len, Decoded *out) {
  if (len < 12 || memcmp(data, "RIFF", 4) != 0 || memcmp(data + 8, "WAVE", 4) != 0) return -1;
  size_t pos = 12;
  int format = 0, channels = 0, bits = 0;
  uint32_t rate = 0;
  const uint8_t *pcm = NULL;
  size_t pcm_len = 0;
  while (pos + 8 <= len) {
    const uint8_t *id = data + pos;
    uint32_t size = rd32(data + pos + 4);
    pos += 8;
    if (pos + size > len) size = (uint32_t)(len - pos);
    if (memcmp(id, "fmt ", 4) == 0 && size >= 16) {
      format = rd16(data + pos);
      channels = rd16(data + pos + 2);
      rate = rd32(data + pos + 4);
      bits = rd16(data + pos + 14);
      if (format == 0xFFFE && size >= 40) format = rd16(data + pos + 24); // WAVE_FORMAT_EXTENSIBLE
    } else if (memcmp(id, "data", 4) == 0) {
      pcm = data + pos;
      pcm_len = size;
    }
    pos += size + (size & 1);
  }
  if (pcm == NULL || channels < 1 || channels > 2 || rate == 0) return -1;
  int bytes = bits / 8;
  if (bytes <= 0) return -1;
  size_t frame_bytes = (size_t)bytes * (size_t)channels;
  if (frame_bytes == 0) return -1;
  int frames = (int)(pcm_len / frame_bytes);
  if (frames <= 0) return -1;
  float *l = (float *)malloc((size_t)frames * sizeof(float));
  float *r = channels > 1 ? (float *)malloc((size_t)frames * sizeof(float)) : NULL;
  if (l == NULL || (channels > 1 && r == NULL)) {
    free(l);
    free(r);
    return -1;
  }
  const uint8_t *p = pcm;
  for (int i = 0; i < frames; i++) {
    for (int ch = 0; ch < channels; ch++) {
      float v = 0;
      if (format == 3 && bits == 32) {
        float f;
        memcpy(&f, p, 4);
        v = f;
      } else if (format == 3 && bits == 64) {
        double d;
        memcpy(&d, p, 8);
        v = (float)d;
      } else if (bits == 8) {
        v = ((float)p[0] - 128.0f) / 128.0f;
      } else if (bits == 16) {
        v = (float)(int16_t)rd16(p) / 32768.0f;
      } else if (bits == 24) {
        int32_t s = (int32_t)((uint32_t)p[0] << 8 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 24) >> 8;
        v = (float)s / 8388608.0f;
      } else if (bits == 32) {
        v = (float)(int32_t)rd32(p) / 2147483648.0f;
      }
      if (ch == 0) l[i] = v;
      else r[i] = v;
      p += bytes;
    }
  }
  out->left = l;
  out->right = channels > 1 ? r : NULL;
  out->channels = channels;
  out->frames = frames;
  out->rate = (double)rate;
  return 0;
}

// ---------------------------------------------------------------------------
// MPEG audio (minimp3)

static int decode_mp3(const uint8_t *data, size_t len, Decoded *out) {
  mp3dec_t dec;
  mp3dec_init(&dec);
  mp3dec_frame_info_t info;
  float frame[MINIMP3_MAX_SAMPLES_PER_FRAME];
  int capacity = 4096, frames = 0;
  float *l = (float *)malloc((size_t)capacity * sizeof(float));
  float *r = (float *)malloc((size_t)capacity * sizeof(float));
  if (l == NULL || r == NULL) {
    free(l);
    free(r);
    return -1;
  }
  int channels = 0;
  double rate = 0;
  size_t pos = 0;
  while (pos + 4 <= len) {
    int samples = mp3dec_decode_frame(&dec, data + pos, (int)(len - pos), frame, &info);
    if (info.frame_bytes <= 0) break;
    pos += (size_t)info.frame_bytes;
    if (samples <= 0) continue;
    if (info.channels > 2) break;
    if (channels == 0) channels = info.channels;
    if (rate == 0) rate = info.hz;
    if (frames + samples + 1 > capacity) {
      while (frames + samples + 1 > capacity) capacity *= 2;
      float *nl = (float *)realloc(l, (size_t)capacity * sizeof(float));
      float *nr = (float *)realloc(r, (size_t)capacity * sizeof(float));
      if (nl == NULL || nr == NULL) {
        free(nl != NULL ? nl : l);
        free(nr != NULL ? nr : r);
        return -1;
      }
      l = nl;
      r = nr;
    }
    for (int i = 0; i < samples; i++) {
      float a = frame[i * info.channels];
      float b = info.channels > 1 ? frame[i * info.channels + 1] : a;
      l[frames] = a;
      r[frames] = b;
      frames++;
    }
  }
  if (frames == 0 || rate == 0) {
    free(l);
    free(r);
    return -1;
  }
  out->left = l;
  out->right = r;
  out->channels = channels;
  out->frames = frames;
  out->rate = rate;
  return 0;
}

// ---------------------------------------------------------------------------
// Ogg Vorbis (stb_vorbis)

static int decode_vorbis(const uint8_t *data, size_t len, Decoded *out) {
  int error = 0;
  stb_vorbis *v = stb_vorbis_open_memory(data, (int)len, &error, NULL);
  if (v == NULL) return -1;
  stb_vorbis_info info = stb_vorbis_get_info(v);
  int channels = info.channels;
  if (channels < 1 || channels > 2) {
    stb_vorbis_close(v);
    return -1;
  }
  int total = (int)stb_vorbis_stream_length_in_samples(v);
  if (total <= 0) {
    stb_vorbis_close(v);
    return -1;
  }
  int capacity = total + 1024;
  float *l = (float *)malloc((size_t)capacity * sizeof(float));
  float *r = (float *)malloc((size_t)capacity * sizeof(float));
  float *interleaved = (float *)malloc((size_t)capacity * (size_t)channels * sizeof(float));
  if (l == NULL || r == NULL || interleaved == NULL) {
    free(l);
    free(r);
    free(interleaved);
    stb_vorbis_close(v);
    return -1;
  }
  int got = stb_vorbis_get_samples_float_interleaved(v, channels, interleaved, capacity * channels);
  if (got < capacity) capacity = got;
  for (int i = 0; i < capacity; i++) {
    l[i] = interleaved[i * channels];
    r[i] = channels > 1 ? interleaved[i * channels + 1] : l[i];
  }
  free(interleaved);
  stb_vorbis_close(v);
  if (capacity <= 0) {
    free(l);
    free(r);
    return -1;
  }
  out->left = l;
  out->right = r;
  out->channels = channels;
  out->frames = capacity;
  out->rate = (double)info.sample_rate;
  return 0;
}

// ---------------------------------------------------------------------------
// Platform containers (AAC and M4A on macOS)

#if defined(__APPLE__)

typedef struct {
  const uint8_t *data;
  SInt64 len;
} MemoryFile;

static OSStatus memory_read(void *client, SInt64 position, UInt32 request, void *buffer, UInt32 *actual) {
  MemoryFile *m = (MemoryFile *)client;
  if (position < 0 || position >= m->len) {
    *actual = 0;
    return noErr;
  }
  SInt64 left = m->len - position;
  UInt32 n = left < (SInt64)request ? (UInt32)left : request;
  memcpy(buffer, m->data + position, n);
  *actual = n;
  return noErr;
}

static SInt64 memory_size(void *client) { return ((MemoryFile *)client)->len; }

static int decode_platform(const uint8_t *data, size_t len, Decoded *out) {
  MemoryFile mem;
  mem.data = data;
  mem.len = (SInt64)len;
  AudioFileID file = NULL;
  if (AudioFileOpenWithCallbacks(&mem, memory_read, NULL, memory_size, NULL, 0, &file) != noErr) {
    return -1;
  }
  ExtAudioFileRef ef = NULL;
  if (ExtAudioFileWrapAudioFileID(file, false, &ef) != noErr) {
    AudioFileClose(file);
    return -1;
  }
  AudioStreamBasicDescription file_fmt;
  UInt32 size = sizeof(file_fmt);
  SInt64 total_frames = 0;
  if (ExtAudioFileGetProperty(ef, kExtAudioFileProperty_FileDataFormat, &size, &file_fmt) != noErr) {
    ExtAudioFileDispose(ef);
    AudioFileClose(file);
    return -1;
  }
  size = sizeof(total_frames);
  ExtAudioFileGetProperty(ef, kExtAudioFileProperty_FileLengthFrames, &size, &total_frames);
  int channels = (int)file_fmt.mChannelsPerFrame;
  double rate = file_fmt.mSampleRate;
  if (channels < 1 || channels > 2 || rate <= 0 || total_frames <= 0) {
    ExtAudioFileDispose(ef);
    AudioFileClose(file);
    return -1;
  }
  AudioStreamBasicDescription client;
  memset(&client, 0, sizeof(client));
  client.mSampleRate = rate;
  client.mFormatID = kAudioFormatLinearPCM;
  client.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
  client.mChannelsPerFrame = (UInt32)channels;
  client.mBitsPerChannel = 32;
  client.mFramesPerPacket = 1;
  client.mBytesPerFrame = (UInt32)(channels * 4);
  client.mBytesPerPacket = (UInt32)(channels * 4);
  if (ExtAudioFileSetProperty(ef, kExtAudioFileProperty_ClientDataFormat, sizeof(client), &client) != noErr) {
    ExtAudioFileDispose(ef);
    AudioFileClose(file);
    return -1;
  }
  int capacity = (int)total_frames + 1024;
  float *l = (float *)malloc((size_t)capacity * sizeof(float));
  float *r = (float *)malloc((size_t)capacity * sizeof(float));
  float *interleaved = (float *)malloc((size_t)capacity * (size_t)channels * sizeof(float));
  if (l == NULL || r == NULL || interleaved == NULL) {
    free(l);
    free(r);
    free(interleaved);
    ExtAudioFileDispose(ef);
    AudioFileClose(file);
    return -1;
  }
  int frames = 0;
  while (frames < capacity) {
    UInt32 want = (UInt32)(capacity - frames);
    if (want > 4096) want = 4096;
    AudioBufferList list;
    list.mNumberBuffers = 1;
    list.mBuffers[0].mNumberChannels = (UInt32)channels;
    list.mBuffers[0].mDataByteSize = want * client.mBytesPerFrame;
    list.mBuffers[0].mData = interleaved + (size_t)frames * (size_t)channels;
    UInt32 got = want;
    if (ExtAudioFileRead(ef, &got, &list) != noErr || got == 0) break;
    frames += (int)got;
  }
  ExtAudioFileDispose(ef);
  AudioFileClose(file);
  if (frames <= 0) {
    free(l);
    free(r);
    free(interleaved);
    return -1;
  }
  for (int i = 0; i < frames; i++) {
    l[i] = interleaved[i * channels];
    r[i] = channels > 1 ? interleaved[i * channels + 1] : l[i];
  }
  free(interleaved);
  out->left = l;
  out->right = r;
  out->channels = channels;
  out->frames = frames;
  out->rate = rate;
  return 0;
}

#else

static int decode_platform(const uint8_t *data, size_t len, Decoded *out) {
  (void)data;
  (void)len;
  (void)out;
  return -1;
}

#endif

// ---------------------------------------------------------------------------
// The FFI entry point

/** Decodes a file into a flat stereo pair at the context's rate. */
static int decode_any(const uint8_t *data, size_t len, Decoded *out) {
  if (len >= 12 && memcmp(data, "RIFF", 4) == 0 && memcmp(data + 8, "WAVE", 4) == 0) {
    return decode_wav(data, len, out);
  }
  if (len >= 4 && memcmp(data, "OggS", 4) == 0) {
    return decode_vorbis(data, len, out);
  }
  if (len >= 3 && (memcmp(data, "ID3", 3) == 0 || ((data[0] & 0xFF) == 0xFF && (data[1] & 0xE0) == 0xE0))) {
    return decode_mp3(data, len, out);
  }
  if (decode_platform(data, len, out) == 0) return 0;
  // Some WAVs hide their tags before RIFF; try the platform's reader, then a bare WAV scan.
  return decode_wav(data, len, out);
}

static float *resample_linear(const float *in, int frames, double from, double to, int *out_frames) {
  if (frames <= 0) {
    *out_frames = 0;
    return NULL;
  }
  int n = (int)floor((double)frames * to / from + 0.5);
  if (n <= 0) n = 1;
  float *out = (float *)malloc((size_t)n * sizeof(float));
  if (out == NULL) {
    *out_frames = 0;
    return NULL;
  }
  for (int i = 0; i < n; i++) {
    double pos = (double)i * from / to;
    int i0 = (int)pos;
    if (i0 >= frames) i0 = frames - 1;
    int i1 = i0 + 1 < frames ? i0 + 1 : frames - 1;
    double frac = pos - i0;
    out[i] = (float)(in[i0] + (in[i1] - in[i0]) * frac);
  }
  *out_frames = n;
  return out;
}

int32_t host_audio_decode(int32_t context_id, const uint8_t *data, size_t len) {
  AudioContext *c = audio_context_get(context_id);
  if (c == NULL || data == NULL || len < 4) return -1;
  Decoded decoded;
  memset(&decoded, 0, sizeof(decoded));
  if (decode_any(data, len, &decoded) != 0) return -1;
  double rate = audio_context_rate(c);
  float *left = decoded.left;
  float *right = decoded.right;
  int frames = decoded.frames;
  int channels = decoded.channels > 1 ? 2 : 1;
  if (decoded.rate > 0 && fabs(decoded.rate - rate) > 0.5) {
    int n = 0;
    left = resample_linear(decoded.left, frames, decoded.rate, rate, &n);
    if (right != NULL) right = resample_linear(decoded.right, frames, decoded.rate, rate, &n);
    if (left == NULL || (channels > 1 && right == NULL)) {
      free(left);
      free(right);
      decoded_free(&decoded);
      return -1;
    }
    decoded_free(&decoded);
    frames = n;
  }
  int id = audio_buffer_new(c, channels, frames, rate);
  if (id < 0) {
    free(left);
    free(right);
    return -1;
  }
  AudioBufferData *b = audio_buffer_get(c, id);
  if (frames > 0) {
    memcpy(b->data[0], left, (size_t)frames * sizeof(float));
    if (channels > 1 && right != NULL) memcpy(b->data[1], right, (size_t)frames * sizeof(float));
  }
  free(left);
  free(right);
  return id;
}
