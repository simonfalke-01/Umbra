#ifndef UMBRA_STREAMING_BRIDGE_H
#define UMBRA_STREAMING_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Stable C ABI for moonlight-common-c.
 *
 * A process can own multiple idle sessions, but moonlight-common-c has global
 * connection state, so only one session may be starting/connected at a time.
 * `umbra_stream_session_start()` is blocking and must run on a dedicated serial
 * executor. `cancel()` is idempotent and safe from another thread; it
 * interrupts a pending start or stops a live connection. A cancelled start
 * returns `UMBRA_STREAM_ERROR_CANCELLED` unless moonlight-common-c reports a
 * more specific failure first.
 *
 * Callbacks may arrive concurrently on Moonlight networking threads. Callback
 * payload pointers are borrowed only for the duration of the callback, except
 * for `UmbraVideoFrame.data`, whose ownership may be taken explicitly with
 * `umbra_video_frame_take_data()`. The callback context is caller-owned and
 * must remain alive until session destroy succeeds. Destroy waits for callbacks
 * already in flight.
 */

typedef struct UmbraStreamSession UmbraStreamSession;

typedef enum UmbraStreamResult {
    UMBRA_STREAM_OK = 0,
    UMBRA_STREAM_ERROR_INVALID_ARGUMENT = -7001,
    UMBRA_STREAM_ERROR_INVALID_STATE = -7002,
    UMBRA_STREAM_ERROR_BUSY = -7003,
    UMBRA_STREAM_ERROR_OUT_OF_MEMORY = -7004,
    UMBRA_STREAM_ERROR_DESTROYED = -7005,
    UMBRA_STREAM_ERROR_CANCELLED = -7006
} UmbraStreamResult;

typedef enum UmbraStreamState {
    UMBRA_STREAM_STATE_IDLE = 0,
    UMBRA_STREAM_STATE_STARTING = 1,
    UMBRA_STREAM_STATE_CONNECTED = 2,
    UMBRA_STREAM_STATE_STOPPING = 3,
    UMBRA_STREAM_STATE_TERMINATED = 4
} UmbraStreamState;

typedef enum UmbraStreamRemoteMode {
    UMBRA_STREAM_REMOTE_LOCAL = 0,
    UMBRA_STREAM_REMOTE_REMOTE = 1,
    UMBRA_STREAM_REMOTE_AUTO = 2
} UmbraStreamRemoteMode;

typedef enum UmbraStreamColorSpace {
    UMBRA_STREAM_COLORSPACE_REC_601 = 0,
    UMBRA_STREAM_COLORSPACE_REC_709 = 1,
    UMBRA_STREAM_COLORSPACE_REC_2020 = 2
} UmbraStreamColorSpace;

typedef enum UmbraStreamColorRange {
    UMBRA_STREAM_COLOR_RANGE_LIMITED = 0,
    UMBRA_STREAM_COLOR_RANGE_FULL = 1
} UmbraStreamColorRange;

typedef enum UmbraStreamOptimizationMode {
    UMBRA_STREAM_OPTIMIZATION_MODE_LEGACY = 0,
    UMBRA_STREAM_OPTIMIZATION_MODE_LATENCY = 1,
    UMBRA_STREAM_OPTIMIZATION_MODE_QUALITY = 2
} UmbraStreamOptimizationMode;

typedef enum UmbraStreamFidelityMode {
    UMBRA_STREAM_FIDELITY_UNSPECIFIED = 0,
    UMBRA_STREAM_FIDELITY_VISUALLY_LOSSLESS_ALLOWED = 1,
    UMBRA_STREAM_FIDELITY_CODEC_LOSSLESS_REQUIRED = 2
} UmbraStreamFidelityMode;

enum {
    UMBRA_VIDEO_FORMAT_H264 = 0x0001,
    UMBRA_VIDEO_FORMAT_H264_HIGH8_444 = 0x0004,
    UMBRA_VIDEO_FORMAT_H265 = 0x0100,
    UMBRA_VIDEO_FORMAT_H265_MAIN10 = 0x0200,
    UMBRA_VIDEO_FORMAT_H265_REXT8_444 = 0x0400,
    UMBRA_VIDEO_FORMAT_H265_REXT10_444 = 0x0800,
    UMBRA_VIDEO_FORMAT_AV1_MAIN8 = 0x1000,
    UMBRA_VIDEO_FORMAT_AV1_MAIN10 = 0x2000,
    UMBRA_VIDEO_FORMAT_AV1_HIGH8_444 = 0x4000,
    UMBRA_VIDEO_FORMAT_AV1_HIGH10_444 = 0x8000
};

enum {
    UMBRA_AUDIO_CONFIGURATION_STEREO = (0x3 << 16) | (2 << 8) | 0xCA,
    UMBRA_AUDIO_CONFIGURATION_51_SURROUND = (0x3F << 16) | (6 << 8) | 0xCA,
    UMBRA_AUDIO_CONFIGURATION_71_SURROUND = (0x63F << 16) | (8 << 8) | 0xCA
};

enum {
    UMBRA_RENDER_CAPABILITY_DIRECT_SUBMIT = 0x1,
    UMBRA_RENDER_CAPABILITY_REFERENCE_FRAME_INVALIDATION_AVC = 0x2,
    UMBRA_RENDER_CAPABILITY_REFERENCE_FRAME_INVALIDATION_HEVC = 0x4,
    UMBRA_RENDER_CAPABILITY_SLOW_OPUS_DECODER = 0x8,
    UMBRA_RENDER_CAPABILITY_ARBITRARY_AUDIO_DURATION = 0x10,
    UMBRA_RENDER_CAPABILITY_REFERENCE_FRAME_INVALIDATION_AV1 = 0x40
};

enum {
    UMBRA_VIDEO_DECODE_QUEUE_CAPACITY_MIN = 1,
    UMBRA_VIDEO_DECODE_QUEUE_CAPACITY_MAX = 15,
    UMBRA_VIDEO_DECODE_QUEUE_CAPACITY_DEFAULT = 15
};

typedef struct UmbraStreamConfiguration {
    const char *address;
    const char *server_app_version;
    const char *server_gfe_version;
    const char *rtsp_session_url;
    int32_t server_codec_mode_support;

    int32_t width;
    int32_t height;
    int32_t fps;
    int32_t bitrate;
    int32_t packet_size;
    UmbraStreamRemoteMode remote_mode;
    int32_t audio_configuration;
    int32_t supported_video_formats;
    int32_t client_refresh_rate_x100;
    UmbraStreamColorSpace color_space;
    UmbraStreamColorRange color_range;
    int32_t encryption_flags;
    uint8_t remote_input_aes_key[16];
    uint8_t remote_input_aes_iv[16];

    bool client_microphone_requested;
    uint16_t client_microphone_client_port;

    int32_t video_capabilities;
    int32_t audio_capabilities;
    int32_t video_renderer_flags;
    int32_t audio_renderer_flags;
    int32_t video_decode_queue_capacity;

    /* Host-advertised Lumen RTSP policy; legacy emits no extension. */
    UmbraStreamOptimizationMode rtsp_optimization_mode;

    /* Exact Lumen fidelity request; unspecified emits no extension. */
    UmbraStreamFidelityMode rtsp_fidelity_mode;

    /* Local moonlight-common-c input pacing policy. */
    UmbraStreamOptimizationMode input_optimization_mode;
} UmbraStreamConfiguration;

void umbra_stream_configuration_init(UmbraStreamConfiguration *configuration);
int32_t umbra_stream_configuration_validate(const UmbraStreamConfiguration *configuration);

typedef enum UmbraStreamEventType {
    UMBRA_STREAM_EVENT_STAGE_STARTING = 0,
    UMBRA_STREAM_EVENT_STAGE_COMPLETE = 1,
    UMBRA_STREAM_EVENT_STAGE_FAILED = 2,
    UMBRA_STREAM_EVENT_CONNECTION_STARTED = 3,
    UMBRA_STREAM_EVENT_CONNECTION_TERMINATED = 4,
    UMBRA_STREAM_EVENT_LOG = 5,
    UMBRA_STREAM_EVENT_RUMBLE = 6,
    UMBRA_STREAM_EVENT_CONNECTION_STATUS = 7,
    UMBRA_STREAM_EVENT_HDR_MODE = 8,
    UMBRA_STREAM_EVENT_TRIGGER_RUMBLE = 9,
    UMBRA_STREAM_EVENT_MOTION_STATE = 10,
    UMBRA_STREAM_EVENT_CONTROLLER_LED = 11,
    UMBRA_STREAM_EVENT_ADAPTIVE_TRIGGERS = 12,
    UMBRA_STREAM_EVENT_CLIENT_MICROPHONE_GENERATION = 13
} UmbraStreamEventType;

#define UMBRA_CLIENT_MICROPHONE_REMOTE_ADDRESS_CAPACITY 64

typedef struct UmbraClientMicrophoneGeneration {
    uint8_t session_id[16];
    uint8_t salt[16];
    uint16_t server_port;
    uint16_t client_port;
    char remote_address[UMBRA_CLIENT_MICROPHONE_REMOTE_ADDRESS_CAPACITY];
} UmbraClientMicrophoneGeneration;

typedef struct UmbraHDRMetadata {
    bool valid;
    uint16_t red_x;
    uint16_t red_y;
    uint16_t green_x;
    uint16_t green_y;
    uint16_t blue_x;
    uint16_t blue_y;
    uint16_t white_x;
    uint16_t white_y;
    uint16_t max_display_luminance;
    uint16_t min_display_luminance;
    uint16_t max_content_light_level;
    uint16_t max_frame_average_light_level;
    uint16_t max_full_frame_luminance;
} UmbraHDRMetadata;

typedef struct UmbraStreamEvent {
    UmbraStreamEventType type;
    int32_t stage;
    int32_t error_code;
    int32_t status;
    const char *stage_name;
    const char *message;
    uint16_t controller_number;
    uint16_t low_frequency_motor;
    uint16_t high_frequency_motor;
    uint16_t report_rate_hz;
    uint8_t motion_type;
    bool enabled;
    uint8_t red;
    uint8_t green;
    uint8_t blue;
    uint8_t adaptive_event_flags;
    uint8_t adaptive_left_type;
    uint8_t adaptive_right_type;
    uint8_t adaptive_left[10];
    uint8_t adaptive_right[10];
    UmbraHDRMetadata hdr_metadata;
    UmbraClientMicrophoneGeneration client_microphone_generation;
} UmbraStreamEvent;

typedef struct UmbraVideoFormat {
    int32_t format;
    int32_t width;
    int32_t height;
    int32_t redraw_rate;
    int32_t flags;
} UmbraVideoFormat;

typedef struct UmbraVideoFrame {
    uint8_t *data;
    size_t length;
    int32_t frame_number;
    int32_t frame_type;
    uint16_t host_processing_latency_tenths_ms;
    uint64_t receive_time_us;
    uint64_t enqueue_time_us;
    uint64_t presentation_time_us;
    uint32_t rtp_timestamp;
    bool hdr_active;
    uint8_t color_space;
} UmbraVideoFrame;

typedef enum UmbraPreparedVideoPayloadFormat {
    UMBRA_PREPARED_VIDEO_PAYLOAD_ANNEX_B = 0,
    UMBRA_PREPARED_VIDEO_PAYLOAD_VIDEO_TOOLBOX_LENGTH_PREFIXED = 1,
    UMBRA_PREPARED_VIDEO_PAYLOAD_AV1_LOW_OVERHEAD_OBU = 2
} UmbraPreparedVideoPayloadFormat;

/*
 * ABI-versioned opt-in frame used by the fragment-aware writer. Existing
 * `UmbraStreamCallbacks.video_frame` users retain the original Annex-B/OBU
 * payload contract and struct layout. Version 1 is the only accepted version.
 */
#define UMBRA_PREPARED_VIDEO_FRAME_ABI_VERSION 1u

typedef struct UmbraPreparedVideoFrame {
    uint32_t abi_version;
    UmbraPreparedVideoPayloadFormat payload_format;
    uint8_t *data;
    size_t length;
    int32_t frame_number;
    int32_t frame_type;
    uint16_t host_processing_latency_tenths_ms;
    uint64_t receive_time_us;
    uint64_t enqueue_time_us;
    uint64_t presentation_time_us;
    uint32_t rtp_timestamp;
    bool hdr_active;
    uint8_t color_space;
} UmbraPreparedVideoFrame;

/*
 * Transfers the encoded payload allocation out of a video callback frame.
 * This may be called at most once while the callback is running. On success,
 * the frame is cleared and the returned allocation remains valid after the
 * callback returns. Release it exactly once with
 * `umbra_video_frame_release_data()`. If ownership is not taken, the bridge
 * releases the allocation automatically after the callback returns.
 */
uint8_t *umbra_video_frame_take_data(UmbraVideoFrame *frame);
void umbra_video_frame_release_data(uint8_t *data);
uint8_t *umbra_prepared_video_frame_take_data(UmbraPreparedVideoFrame *frame);
void umbra_prepared_video_frame_release_data(uint8_t *data);

typedef struct UmbraAudioFormat {
    int32_t audio_configuration;
    int32_t sample_rate;
    int32_t channel_count;
    int32_t streams;
    int32_t coupled_streams;
    int32_t samples_per_frame;
    uint8_t mapping[8];
    int32_t flags;
} UmbraAudioFormat;

typedef struct UmbraAudioPacket {
    const uint8_t *data;
    size_t length;
} UmbraAudioPacket;

typedef void (*UmbraStreamEventCallback)(void *context, const UmbraStreamEvent *event);
typedef int32_t (*UmbraVideoSetupCallback)(void *context, const UmbraVideoFormat *format);
typedef void (*UmbraRendererLifecycleCallback)(void *context);
typedef int32_t (*UmbraVideoFrameCallback)(void *context, UmbraVideoFrame *frame);
typedef int32_t (*UmbraPreparedVideoFrameCallback)(void *context, UmbraPreparedVideoFrame *frame);
typedef int32_t (*UmbraAudioInitCallback)(void *context, const UmbraAudioFormat *format);
typedef void (*UmbraAudioPacketCallback)(void *context, const UmbraAudioPacket *packet);

typedef struct UmbraStreamCallbacks {
    void *context;
    UmbraStreamEventCallback event;
    UmbraVideoSetupCallback video_setup;
    UmbraRendererLifecycleCallback video_start;
    UmbraRendererLifecycleCallback video_stop;
    UmbraRendererLifecycleCallback video_cleanup;
    UmbraVideoFrameCallback video_frame;
    UmbraAudioInitCallback audio_init;
    UmbraRendererLifecycleCallback audio_start;
    UmbraRendererLifecycleCallback audio_stop;
    UmbraRendererLifecycleCallback audio_cleanup;
    UmbraAudioPacketCallback audio_packet;
} UmbraStreamCallbacks;

typedef struct UmbraStreamStatistics {
    uint32_t estimated_rtt_ms;
    uint32_t estimated_rtt_variance_ms;
    bool has_estimated_rtt;
    int32_t pending_video_frames;
    int32_t pending_audio_frames;
    int32_t pending_audio_duration_ms;
    uint32_t audio_packets;
    uint32_t audio_fec_packets;
    uint32_t audio_fec_recovered;
    uint32_t audio_fec_failed;
    uint32_t audio_out_of_sequence;
    uint32_t audio_invalid;
    uint32_t video_packets;
    uint32_t video_fec_packets;
    uint32_t video_fec_recovered;
    uint32_t video_fec_failed;
    uint32_t video_out_of_sequence;
    uint32_t video_invalid;
    int32_t video_decode_queue_capacity;
} UmbraStreamStatistics;

UmbraStreamSession *umbra_stream_session_create(
    const UmbraStreamConfiguration *configuration,
    const UmbraStreamCallbacks *callbacks,
    int32_t *result
);
/* Must be called while the session is idle. Passing NULL disables the opt-in path. */
int32_t umbra_stream_session_set_prepared_video_callback(
    UmbraStreamSession *session,
    UmbraPreparedVideoFrameCallback callback
);
int32_t umbra_stream_session_destroy(UmbraStreamSession *session);
UmbraStreamState umbra_stream_session_state(const UmbraStreamSession *session);
int32_t umbra_stream_session_start(UmbraStreamSession *session);
int32_t umbra_stream_session_stop(UmbraStreamSession *session);
int32_t umbra_stream_session_cancel(UmbraStreamSession *session);
int32_t umbra_stream_session_get_statistics(
    const UmbraStreamSession *session,
    UmbraStreamStatistics *statistics
);
int32_t umbra_stream_session_request_idr(UmbraStreamSession *session);

int32_t umbra_stream_session_send_mouse_move(UmbraStreamSession *session, int16_t delta_x, int16_t delta_y);
int32_t umbra_stream_session_send_mouse_position(UmbraStreamSession *session, int16_t x, int16_t y, int16_t reference_width, int16_t reference_height);
int32_t umbra_stream_session_send_mouse_move_as_position(UmbraStreamSession *session, int16_t delta_x, int16_t delta_y, int16_t reference_width, int16_t reference_height);
int32_t umbra_stream_session_send_mouse_button(UmbraStreamSession *session, int8_t action, int32_t button);
int32_t umbra_stream_session_send_scroll(UmbraStreamSession *session, int16_t vertical, int16_t horizontal);
int32_t umbra_stream_session_send_keyboard(UmbraStreamSession *session, int16_t key_code, int8_t action, int8_t modifiers, int8_t flags);
int32_t umbra_stream_session_send_utf8_text(UmbraStreamSession *session, const char *text, size_t length);
int32_t umbra_stream_session_send_touch(
    UmbraStreamSession *session,
    uint8_t event_type,
    uint32_t pointer_id,
    float x,
    float y,
    float pressure_or_distance,
    float contact_area_major,
    float contact_area_minor,
    uint16_t rotation
);
int32_t umbra_stream_session_send_pen(
    UmbraStreamSession *session,
    uint8_t event_type,
    uint8_t tool_type,
    uint8_t pen_buttons,
    float x,
    float y,
    float pressure_or_distance,
    float contact_area_major,
    float contact_area_minor,
    uint16_t rotation,
    uint8_t tilt
);
int32_t umbra_stream_session_send_controller(
    UmbraStreamSession *session,
    int16_t controller_number,
    int16_t active_gamepad_mask,
    int32_t button_flags,
    uint8_t left_trigger,
    uint8_t right_trigger,
    int16_t left_stick_x,
    int16_t left_stick_y,
    int16_t right_stick_x,
    int16_t right_stick_y
);
int32_t umbra_stream_session_send_controller_arrival(
    UmbraStreamSession *session,
    uint8_t controller_number,
    uint16_t active_gamepad_mask,
    uint8_t type,
    uint32_t supported_button_flags,
    uint16_t capabilities
);
int32_t umbra_stream_session_send_controller_touch(
    UmbraStreamSession *session,
    uint8_t controller_number,
    uint8_t event_type,
    uint8_t touchpad_index,
    uint32_t pointer_id,
    float x,
    float y,
    float pressure
);
int32_t umbra_stream_session_send_controller_motion(
    UmbraStreamSession *session,
    uint8_t controller_number,
    uint8_t motion_type,
    float x,
    float y,
    float z
);
int32_t umbra_stream_session_send_controller_battery(
    UmbraStreamSession *session,
    uint8_t controller_number,
    uint8_t battery_state,
    uint8_t battery_percentage
);
int32_t umbra_stream_session_get_host_feature_flags(UmbraStreamSession *session, uint32_t *feature_flags);

#ifdef __cplusplus
}
#endif

#endif
