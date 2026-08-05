#ifndef NATIVE_SDK_AUDIO_CAPTURE_H
#define NATIVE_SDK_AUDIO_CAPTURE_H

#include <stddef.h>
#include <stdint.h>

typedef struct native_sdk_audio_capture native_sdk_audio_capture_t;

typedef enum {
    NATIVE_SDK_AUDIO_CAPTURE_EVENT_CAPTURE = 0,
    NATIVE_SDK_AUDIO_CAPTURE_EVENT_DEVICE = 1,
    NATIVE_SDK_AUDIO_CAPTURE_EVENT_DEVICES_CHANGED = 2,
    NATIVE_SDK_AUDIO_CAPTURE_EVENT_ACCESS = 3,
} native_sdk_audio_capture_event_kind_t;

typedef struct {
    native_sdk_audio_capture_event_kind_t kind;
    int state;
    int reason;
    uint32_t sample_rate_hz;
    uint8_t channel_count;
    const char *device_id;
    size_t device_id_len;
    const char *device_name;
    size_t device_name_len;
    int device_is_default;
    uint32_t device_index;
    uint32_t device_total;
    int access_source;
    int access_status;
    int restart_required;
} native_sdk_audio_capture_event_t;

typedef void (*native_sdk_audio_capture_callback_t)(void *context, const native_sdk_audio_capture_event_t *event);
typedef int (*native_sdk_audio_capture_frame_callback_t)(void *context, uint64_t token,
    uint64_t frame_offset, uint32_t frame_count,
    const uint8_t *system_pcm, size_t system_pcm_len,
    const uint8_t *microphone_pcm, size_t microphone_pcm_len,
    uint32_t system_gap_frames, uint32_t microphone_gap_frames);

native_sdk_audio_capture_t *native_sdk_audio_capture_create(native_sdk_audio_capture_callback_t callback, void *context);
void native_sdk_audio_capture_destroy(native_sdk_audio_capture_t *capture);

/* Start results: 0 accepted; 1 invalid options; 2 already active;
 * 4 permission required; 5 device missing; 6 unavailable. */
int native_sdk_audio_capture_start(native_sdk_audio_capture_t *capture,
                                   int system_audio, int microphone_kind,
                                   const char *microphone_id, size_t microphone_id_len,
                                   uint32_t sample_rate_hz, uint8_t channel_count,
                                   int exclude_current_process_audio,
                                   native_sdk_audio_capture_frame_callback_t frame_callback,
                                   void *frame_context, uint64_t frame_token);
void native_sdk_audio_capture_stop(native_sdk_audio_capture_t *capture);
void native_sdk_audio_capture_list_microphones(native_sdk_audio_capture_t *capture);
void native_sdk_capture_access(native_sdk_audio_capture_t *capture, int source, int action);
void native_sdk_audio_capture_observe_microphones(native_sdk_audio_capture_t *capture, int enabled);

#endif
