#include "UmbraStreamingBridge.h"
#include "UmbraClientMicrophoneRTSPExtension.h"
#include "UmbraOptimizationModeRTSPExtension.h"

#include "Limelight.h"

#include <limits.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct UmbraStreamSession {
    SERVER_INFORMATION server;
    STREAM_CONFIGURATION stream;
    UmbraStreamCallbacks callbacks;
    DECODER_RENDERER_CALLBACKS video_callbacks;
    AUDIO_RENDERER_CALLBACKS audio_callbacks;
    int32_t video_flags;
    int32_t audio_flags;
    UmbraPreparedVideoFrameCallback prepared_video_frame;
    int32_t negotiated_video_format;

    char *address;
    char *server_app_version;
    char *server_gfe_version;
    char *rtsp_session_url;
    bool client_microphone_requested;
    uint16_t client_microphone_client_port;
    UmbraStreamOptimizationMode rtsp_optimization_mode;
    UmbraStreamFidelityMode rtsp_fidelity_mode;

    atomic_int state;
    atomic_bool cancellation_requested;
    pthread_mutex_t callback_mutex;
    pthread_cond_t callback_condition;
    uint32_t callbacks_in_flight;
    bool destroyed;
#if defined(UMBRA_STREAM_TESTING)
    pthread_mutex_t test_input_mutex;
    pthread_cond_t test_input_condition;
    bool test_input_blocked;
    bool test_input_waiting;
#endif
};

static pthread_mutex_t g_active_mutex = PTHREAD_MUTEX_INITIALIZER;
static UmbraStreamSession *g_active_session;

#define UMBRA_MAX_VIDEO_FRAME_BYTES ((size_t)64 * 1024 * 1024)
#define UMBRA_MAX_VIDEO_FRAGMENTS ((size_t)131072)

typedef enum PreparedCodec {
    PREPARED_CODEC_INVALID = 0,
    PREPARED_CODEC_H264,
    PREPARED_CODEC_HEVC,
    PREPARED_CODEC_AV1
} PreparedCodec;

typedef struct FragmentCursor {
    PLENTRY entry;
    size_t entry_offset;
    size_t absolute_offset;
    size_t total_length;
} FragmentCursor;

typedef struct StartCode {
    size_t offset;
    size_t length;
} StartCode;

static PreparedCodec prepared_codec_for_format(int32_t format) {
    switch (format) {
    case VIDEO_FORMAT_H264:
    case VIDEO_FORMAT_H264_HIGH8_444:
        return PREPARED_CODEC_H264;
    case VIDEO_FORMAT_H265:
    case VIDEO_FORMAT_H265_MAIN10:
    case VIDEO_FORMAT_H265_REXT8_444:
    case VIDEO_FORMAT_H265_REXT10_444:
        return PREPARED_CODEC_HEVC;
    case VIDEO_FORMAT_AV1_MAIN8:
    case VIDEO_FORMAT_AV1_MAIN10:
    case VIDEO_FORMAT_AV1_HIGH8_444:
    case VIDEO_FORMAT_AV1_HIGH10_444:
        return PREPARED_CODEC_AV1;
    default:
        return PREPARED_CODEC_INVALID;
    }
}

static bool validate_fragment_chain(PDECODE_UNIT unit, size_t *fragment_count_out) {
    if (unit == NULL || unit->fullLength <= 0 ||
        (size_t)unit->fullLength > UMBRA_MAX_VIDEO_FRAME_BYTES) {
        return false;
    }
    size_t sum = 0;
    size_t count = 0;
    for (PLENTRY entry = unit->bufferList; entry != NULL; entry = entry->next) {
        if (++count > UMBRA_MAX_VIDEO_FRAGMENTS || entry->data == NULL || entry->length <= 0 ||
            (size_t)entry->length > (size_t)unit->fullLength - sum) {
            return false;
        }
        sum += (size_t)entry->length;
    }
    if (count == 0 || sum != (size_t)unit->fullLength) {
        return false;
    }
    if (fragment_count_out != NULL) {
        *fragment_count_out = count;
    }
    return true;
}

static void fragment_cursor_init(FragmentCursor *cursor, PDECODE_UNIT unit) {
    cursor->entry = unit->bufferList;
    cursor->entry_offset = 0;
    cursor->absolute_offset = 0;
    cursor->total_length = (size_t)unit->fullLength;
}

static bool fragment_cursor_advance(FragmentCursor *cursor, size_t count) {
    if (count > cursor->total_length - cursor->absolute_offset) {
        return false;
    }
    while (count > 0) {
        if (cursor->entry == NULL) {
            return false;
        }
        size_t available = (size_t)cursor->entry->length - cursor->entry_offset;
        size_t step = count < available ? count : available;
        cursor->entry_offset += step;
        cursor->absolute_offset += step;
        count -= step;
        if (cursor->entry_offset == (size_t)cursor->entry->length) {
            cursor->entry = cursor->entry->next;
            cursor->entry_offset = 0;
        }
    }
    return true;
}

static bool fragment_cursor_peek(const FragmentCursor *cursor, size_t relative, uint8_t *byte_out) {
    if (relative >= cursor->total_length - cursor->absolute_offset) {
        return false;
    }
    PLENTRY entry = cursor->entry;
    size_t offset = cursor->entry_offset;
    while (entry != NULL) {
        size_t available = (size_t)entry->length - offset;
        if (relative < available) {
            *byte_out = (uint8_t)entry->data[offset + relative];
            return true;
        }
        relative -= available;
        entry = entry->next;
        offset = 0;
    }
    return false;
}

static bool fragment_cursor_find_start_code(FragmentCursor *cursor, StartCode *start_code_out) {
    while (cursor->absolute_offset + 3 <= cursor->total_length) {
        uint8_t first;
        uint8_t second;
        uint8_t third;
        uint8_t fourth;
        if (!fragment_cursor_peek(cursor, 0, &first) ||
            !fragment_cursor_peek(cursor, 1, &second) ||
            !fragment_cursor_peek(cursor, 2, &third)) {
            return false;
        }
        size_t length = 0;
        if (cursor->absolute_offset + 4 <= cursor->total_length &&
            fragment_cursor_peek(cursor, 3, &fourth) &&
            first == 0 && second == 0 && third == 0 && fourth == 1) {
            length = 4;
        } else if (first == 0 && second == 0 && third == 1) {
            length = 3;
        }
        if (length != 0) {
            start_code_out->offset = cursor->absolute_offset;
            start_code_out->length = length;
            return fragment_cursor_advance(cursor, length);
        }
        if (!fragment_cursor_advance(cursor, 1)) {
            return false;
        }
    }
    return false;
}

static bool fragment_cursor_range_is_zero(PDECODE_UNIT unit, size_t end) {
    FragmentCursor cursor;
    fragment_cursor_init(&cursor, unit);
    while (cursor.absolute_offset < end) {
        uint8_t byte;
        if (!fragment_cursor_peek(&cursor, 0, &byte) || byte != 0 ||
            !fragment_cursor_advance(&cursor, 1)) {
            return false;
        }
    }
    return true;
}

static bool scan_annex_b_fragments(PDECODE_UNIT unit, size_t *output_length_out) {
    FragmentCursor cursor;
    fragment_cursor_init(&cursor, unit);
    StartCode start_code;
    if (!fragment_cursor_find_start_code(&cursor, &start_code) ||
        !fragment_cursor_range_is_zero(unit, start_code.offset)) {
        return false;
    }
    size_t payload_start = start_code.offset + start_code.length;
    size_t output_length = 0;
    while (true) {
        StartCode next;
        bool has_next = fragment_cursor_find_start_code(&cursor, &next);
        size_t payload_end = has_next ? next.offset : cursor.total_length;
        if (payload_start >= payload_end || payload_end - payload_start > UINT32_MAX ||
            output_length > UMBRA_MAX_VIDEO_FRAME_BYTES - sizeof(uint32_t) ||
            payload_end - payload_start > UMBRA_MAX_VIDEO_FRAME_BYTES - output_length - sizeof(uint32_t)) {
            return false;
        }
        output_length += sizeof(uint32_t) + payload_end - payload_start;
        if (!has_next) {
            break;
        }
        payload_start = next.offset + next.length;
    }
    if (output_length == 0 || output_length > UMBRA_MAX_VIDEO_FRAME_BYTES) {
        return false;
    }
    *output_length_out = output_length;
    return true;
}

static bool fragment_cursor_copy_range(
    FragmentCursor *cursor,
    size_t start,
    size_t end,
    uint8_t *destination
) {
    if (start < cursor->absolute_offset || end < start || end > cursor->total_length ||
        !fragment_cursor_advance(cursor, start - cursor->absolute_offset)) {
        return false;
    }
    size_t remaining = end - start;
    while (remaining > 0) {
        if (cursor->entry == NULL) {
            return false;
        }
        size_t available = (size_t)cursor->entry->length - cursor->entry_offset;
        size_t count = remaining < available ? remaining : available;
        memcpy(destination, cursor->entry->data + cursor->entry_offset, count);
        destination += count;
        remaining -= count;
        if (!fragment_cursor_advance(cursor, count)) {
            return false;
        }
    }
    return true;
}

static uint8_t *write_annex_b_length_prefixed(PDECODE_UNIT unit, size_t output_length) {
    uint8_t *output = malloc(output_length);
    if (output == NULL) {
        return NULL;
    }
    FragmentCursor scan_cursor;
    FragmentCursor copy_cursor;
    fragment_cursor_init(&scan_cursor, unit);
    fragment_cursor_init(&copy_cursor, unit);
    StartCode start_code;
    if (!fragment_cursor_find_start_code(&scan_cursor, &start_code)) {
        free(output);
        return NULL;
    }
    size_t payload_start = start_code.offset + start_code.length;
    size_t destination_offset = 0;
    while (true) {
        StartCode next;
        bool has_next = fragment_cursor_find_start_code(&scan_cursor, &next);
        size_t payload_end = has_next ? next.offset : scan_cursor.total_length;
        uint32_t unit_length = (uint32_t)(payload_end - payload_start);
        output[destination_offset] = (uint8_t)(unit_length >> 24);
        output[destination_offset + 1] = (uint8_t)(unit_length >> 16);
        output[destination_offset + 2] = (uint8_t)(unit_length >> 8);
        output[destination_offset + 3] = (uint8_t)unit_length;
        destination_offset += sizeof(unit_length);
        if (!fragment_cursor_copy_range(
                &copy_cursor,
                payload_start,
                payload_end,
                output + destination_offset)) {
            free(output);
            return NULL;
        }
        destination_offset += payload_end - payload_start;
        if (!has_next) {
            break;
        }
        payload_start = next.offset + next.length;
    }
    if (destination_offset != output_length) {
        free(output);
        return NULL;
    }
    return output;
}

static uint8_t *copy_fragment_chain(PDECODE_UNIT unit) {
    uint8_t *output = malloc((size_t)unit->fullLength);
    if (output == NULL) {
        return NULL;
    }
    FragmentCursor cursor;
    fragment_cursor_init(&cursor, unit);
    if (!fragment_cursor_copy_range(&cursor, 0, cursor.total_length, output)) {
        free(output);
        return NULL;
    }
    return output;
}

static char *copy_optional_string(const char *value) {
    if (value == NULL) {
        return NULL;
    }
    size_t length = strlen(value) + 1;
    char *copy = malloc(length);
    if (copy != NULL) {
        memcpy(copy, value, length);
    }
    return copy;
}

static bool begin_callback(UmbraStreamSession *session) {
    if (session == NULL) {
        return false;
    }
    pthread_mutex_lock(&session->callback_mutex);
    bool allowed = !session->destroyed;
    if (allowed) {
        session->callbacks_in_flight++;
    }
    pthread_mutex_unlock(&session->callback_mutex);
    return allowed;
}

static UmbraStreamSession *begin_active_callback(void) {
    pthread_mutex_lock(&g_active_mutex);
    UmbraStreamSession *session = g_active_session;
    bool allowed = begin_callback(session);
    pthread_mutex_unlock(&g_active_mutex);
    return allowed ? session : NULL;
}

static void end_callback(UmbraStreamSession *session) {
    pthread_mutex_lock(&session->callback_mutex);
    session->callbacks_in_flight--;
    if (session->callbacks_in_flight == 0) {
        pthread_cond_broadcast(&session->callback_condition);
    }
    pthread_mutex_unlock(&session->callback_mutex);
}

static void emit_event(UmbraStreamSession *session, const UmbraStreamEvent *event) {
    if (session->callbacks.event != NULL) {
        session->callbacks.event(session->callbacks.context, event);
    }
}

static void emit_stage_event(UmbraStreamEventType type, int stage, int error_code) {
    UmbraStreamSession *session = begin_active_callback();
    if (session == NULL) {
        return;
    }
    UmbraStreamEvent event = {0};
    event.type = type;
    event.stage = stage;
    event.error_code = error_code;
    event.stage_name = LiGetStageName(stage);
    emit_event(session, &event);
    end_callback(session);
}

static void connection_stage_starting(int stage) {
    emit_stage_event(UMBRA_STREAM_EVENT_STAGE_STARTING, stage, 0);
    pthread_mutex_lock(&g_active_mutex);
    UmbraStreamSession *session = g_active_session;
    bool cancelled = session != NULL && atomic_load_explicit(
        &session->cancellation_requested,
        memory_order_acquire
    );
    pthread_mutex_unlock(&g_active_mutex);
    if (cancelled) {
        /* LiStartConnection resets its interrupt flag before the first stage. */
        LiInterruptConnection();
    }
}

static void connection_stage_complete(int stage) {
    emit_stage_event(UMBRA_STREAM_EVENT_STAGE_COMPLETE, stage, 0);
}

static void connection_stage_failed(int stage, int error_code) {
    emit_stage_event(UMBRA_STREAM_EVENT_STAGE_FAILED, stage, error_code);
}

static void connection_started(void) {
    UmbraStreamSession *session = begin_active_callback();
    if (session == NULL) {
        return;
    }
    atomic_store_explicit(&session->state, UMBRA_STREAM_STATE_CONNECTED, memory_order_release);
    UmbraStreamEvent event = {0};
    event.type = UMBRA_STREAM_EVENT_CONNECTION_STARTED;
    emit_event(session, &event);
    end_callback(session);
}

static void connection_terminated(int error_code) {
    UmbraStreamSession *session = begin_active_callback();
    if (session == NULL) {
        return;
    }
    atomic_store_explicit(&session->state, UMBRA_STREAM_STATE_TERMINATED, memory_order_release);
    UmbraStreamEvent event = {0};
    event.type = UMBRA_STREAM_EVENT_CONNECTION_TERMINATED;
    event.error_code = error_code;
    emit_event(session, &event);
    end_callback(session);
}

static void connection_log(const char *format, ...) {
    UmbraStreamSession *session = begin_active_callback();
    if (session == NULL) {
        return;
    }
    char message[2048];
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(message, sizeof(message), format, arguments);
    va_end(arguments);
    UmbraStreamEvent event = {0};
    event.type = UMBRA_STREAM_EVENT_LOG;
    event.message = message;
    emit_event(session, &event);
    end_callback(session);
}

static void connection_rumble(unsigned short controller, unsigned short low, unsigned short high) {
    UmbraStreamSession *session = begin_active_callback();
    if (session == NULL) {
        return;
    }
    UmbraStreamEvent event = {0};
    event.type = UMBRA_STREAM_EVENT_RUMBLE;
    event.controller_number = controller;
    event.low_frequency_motor = low;
    event.high_frequency_motor = high;
    emit_event(session, &event);
    end_callback(session);
}

static void connection_status(int status) {
    UmbraStreamSession *session = begin_active_callback();
    if (session == NULL) {
        return;
    }
    UmbraStreamEvent event = {0};
    event.type = UMBRA_STREAM_EVENT_CONNECTION_STATUS;
    event.status = status;
    emit_event(session, &event);
    end_callback(session);
}

static void connection_hdr(bool enabled) {
    UmbraStreamSession *session = begin_active_callback();
    if (session == NULL) {
        return;
    }
    UmbraStreamEvent event = {0};
    event.type = UMBRA_STREAM_EVENT_HDR_MODE;
    event.enabled = enabled;
    SS_HDR_METADATA metadata;
    if (enabled && LiGetHdrMetadata(&metadata)) {
        event.hdr_metadata.valid = true;
        event.hdr_metadata.red_x = metadata.displayPrimaries[0].x;
        event.hdr_metadata.red_y = metadata.displayPrimaries[0].y;
        event.hdr_metadata.green_x = metadata.displayPrimaries[1].x;
        event.hdr_metadata.green_y = metadata.displayPrimaries[1].y;
        event.hdr_metadata.blue_x = metadata.displayPrimaries[2].x;
        event.hdr_metadata.blue_y = metadata.displayPrimaries[2].y;
        event.hdr_metadata.white_x = metadata.whitePoint.x;
        event.hdr_metadata.white_y = metadata.whitePoint.y;
        event.hdr_metadata.max_display_luminance = metadata.maxDisplayLuminance;
        event.hdr_metadata.min_display_luminance = metadata.minDisplayLuminance;
        event.hdr_metadata.max_content_light_level = metadata.maxContentLightLevel;
        event.hdr_metadata.max_frame_average_light_level = metadata.maxFrameAverageLightLevel;
        event.hdr_metadata.max_full_frame_luminance = metadata.maxFullFrameLuminance;
    }
    emit_event(session, &event);
    end_callback(session);
}

static void connection_trigger_rumble(uint16_t controller, uint16_t left, uint16_t right) {
    UmbraStreamSession *session = begin_active_callback();
    if (session == NULL) {
        return;
    }
    UmbraStreamEvent event = {0};
    event.type = UMBRA_STREAM_EVENT_TRIGGER_RUMBLE;
    event.controller_number = controller;
    event.low_frequency_motor = left;
    event.high_frequency_motor = right;
    emit_event(session, &event);
    end_callback(session);
}

static void connection_motion_state(uint16_t controller, uint8_t motion_type, uint16_t report_rate_hz) {
    UmbraStreamSession *session = begin_active_callback();
    if (session == NULL) {
        return;
    }
    UmbraStreamEvent event = {0};
    event.type = UMBRA_STREAM_EVENT_MOTION_STATE;
    event.controller_number = controller;
    event.motion_type = motion_type;
    event.report_rate_hz = report_rate_hz;
    emit_event(session, &event);
    end_callback(session);
}

static void connection_controller_led(uint16_t controller, uint8_t red, uint8_t green, uint8_t blue) {
    UmbraStreamSession *session = begin_active_callback();
    if (session == NULL) {
        return;
    }
    UmbraStreamEvent event = {0};
    event.type = UMBRA_STREAM_EVENT_CONTROLLER_LED;
    event.controller_number = controller;
    event.red = red;
    event.green = green;
    event.blue = blue;
    emit_event(session, &event);
    end_callback(session);
}

static void connection_adaptive_triggers(
    uint16_t controller,
    uint8_t event_flags,
    uint8_t left_type,
    uint8_t right_type,
    uint8_t *left,
    uint8_t *right
) {
    UmbraStreamSession *session = begin_active_callback();
    if (session == NULL) {
        return;
    }
    UmbraStreamEvent event = {0};
    event.type = UMBRA_STREAM_EVENT_ADAPTIVE_TRIGGERS;
    event.controller_number = controller;
    event.adaptive_event_flags = event_flags;
    event.adaptive_left_type = left_type;
    event.adaptive_right_type = right_type;
    if (left != NULL) {
        memcpy(event.adaptive_left, left, sizeof(event.adaptive_left));
    }
    if (right != NULL) {
        memcpy(event.adaptive_right, right, sizeof(event.adaptive_right));
    }
    emit_event(session, &event);
    end_callback(session);
}

static int video_setup(int format, int width, int height, int redraw_rate, void *context, int flags) {
    UmbraStreamSession *session = context;
    if (!begin_callback(session)) {
        return -1;
    }
    UmbraVideoFormat video_format = {
        .format = format,
        .width = width,
        .height = height,
        .redraw_rate = redraw_rate,
        .flags = flags
    };
    session->negotiated_video_format = 0;
    int32_t result = session->callbacks.video_setup == NULL
        ? 0
        : session->callbacks.video_setup(session->callbacks.context, &video_format);
    if (result == 0) {
        session->negotiated_video_format = format;
    }
    end_callback(session);
    return result;
}

static void video_start(void) {
    UmbraStreamSession *session = begin_active_callback();
    if (session != NULL) {
        UmbraRendererLifecycleCallback callback = session->callbacks.video_start;
        if (callback != NULL) {
            callback(session->callbacks.context);
        }
        end_callback(session);
    }
}

static void video_stop(void) {
    UmbraStreamSession *session = begin_active_callback();
    if (session != NULL) {
        UmbraRendererLifecycleCallback callback = session->callbacks.video_stop;
        if (callback != NULL) {
            callback(session->callbacks.context);
        }
        end_callback(session);
    }
}

static void video_cleanup(void) {
    UmbraStreamSession *session = begin_active_callback();
    if (session != NULL) {
        UmbraRendererLifecycleCallback callback = session->callbacks.video_cleanup;
        if (callback != NULL) {
            callback(session->callbacks.context);
        }
        end_callback(session);
    }
}

uint8_t *umbra_video_frame_take_data(UmbraVideoFrame *frame) {
    if (frame == NULL) {
        return NULL;
    }
    uint8_t *data = frame->data;
    frame->data = NULL;
    frame->length = 0;
    return data;
}

void umbra_video_frame_release_data(uint8_t *data) {
    free(data);
}

uint8_t *umbra_prepared_video_frame_take_data(UmbraPreparedVideoFrame *frame) {
    if (frame == NULL || frame->abi_version != UMBRA_PREPARED_VIDEO_FRAME_ABI_VERSION) {
        return NULL;
    }
    uint8_t *data = frame->data;
    frame->data = NULL;
    frame->length = 0;
    return data;
}

void umbra_prepared_video_frame_release_data(uint8_t *data) {
    free(data);
}

static int prepared_video_frame(UmbraStreamSession *session, PDECODE_UNIT decode_unit) {
    size_t fragment_count;
    if (!validate_fragment_chain(decode_unit, &fragment_count)) {
        return DR_NEED_IDR;
    }
    (void)fragment_count;
    PreparedCodec codec = prepared_codec_for_format(session->negotiated_video_format);
    UmbraPreparedVideoPayloadFormat payload_format;
    size_t output_length;
    uint8_t *data;
    switch (codec) {
    case PREPARED_CODEC_H264:
    case PREPARED_CODEC_HEVC:
        if (!scan_annex_b_fragments(decode_unit, &output_length)) {
            return DR_NEED_IDR;
        }
        data = write_annex_b_length_prefixed(decode_unit, output_length);
        payload_format = UMBRA_PREPARED_VIDEO_PAYLOAD_VIDEO_TOOLBOX_LENGTH_PREFIXED;
        break;
    case PREPARED_CODEC_AV1:
        output_length = (size_t)decode_unit->fullLength;
        data = copy_fragment_chain(decode_unit);
        payload_format = UMBRA_PREPARED_VIDEO_PAYLOAD_AV1_LOW_OVERHEAD_OBU;
        break;
    default:
        return DR_NEED_IDR;
    }
    if (data == NULL) {
        return DR_NEED_IDR;
    }
    UmbraPreparedVideoFrame frame = {
        .abi_version = UMBRA_PREPARED_VIDEO_FRAME_ABI_VERSION,
        .payload_format = payload_format,
        .data = data,
        .length = output_length,
        .frame_number = decode_unit->frameNumber,
        .frame_type = decode_unit->frameType,
        .host_processing_latency_tenths_ms = decode_unit->frameHostProcessingLatency,
        .receive_time_us = decode_unit->receiveTimeUs,
        .enqueue_time_us = decode_unit->enqueueTimeUs,
        .presentation_time_us = decode_unit->presentationTimeUs,
        .rtp_timestamp = decode_unit->rtpTimestamp,
        .hdr_active = decode_unit->hdrActive,
        .color_space = decode_unit->colorspace
    };
    int32_t result = session->prepared_video_frame(session->callbacks.context, &frame);
    umbra_prepared_video_frame_release_data(frame.data);
    return result;
}

static int video_frame(PDECODE_UNIT decode_unit) {
    UmbraStreamSession *session = begin_active_callback();
    if (session == NULL) {
        return DR_NEED_IDR;
    }
    if (session->prepared_video_frame != NULL) {
        int result = prepared_video_frame(session, decode_unit);
        end_callback(session);
        return result;
    }
    if (session->callbacks.video_frame == NULL) {
        end_callback(session);
        return DR_OK;
    }
    if (!validate_fragment_chain(decode_unit, NULL)) {
        end_callback(session);
        return DR_NEED_IDR;
    }
    uint8_t *data = malloc((size_t)decode_unit->fullLength);
    if (data == NULL) {
        end_callback(session);
        return DR_NEED_IDR;
    }
    size_t offset = 0;
    for (PLENTRY entry = decode_unit->bufferList; entry != NULL; entry = entry->next) {
        memcpy(data + offset, entry->data, (size_t)entry->length);
        offset += (size_t)entry->length;
    }
    if (offset != (size_t)decode_unit->fullLength) {
        free(data);
        end_callback(session);
        return DR_NEED_IDR;
    }
    UmbraVideoFrame frame = {
        .data = data,
        .length = offset,
        .frame_number = decode_unit->frameNumber,
        .frame_type = decode_unit->frameType,
        .host_processing_latency_tenths_ms = decode_unit->frameHostProcessingLatency,
        .receive_time_us = decode_unit->receiveTimeUs,
        .enqueue_time_us = decode_unit->enqueueTimeUs,
        .presentation_time_us = decode_unit->presentationTimeUs,
        .rtp_timestamp = decode_unit->rtpTimestamp,
        .hdr_active = decode_unit->hdrActive,
        .color_space = decode_unit->colorspace
    };
    int32_t result = session->callbacks.video_frame(session->callbacks.context, &frame);
    umbra_video_frame_release_data(frame.data);
    end_callback(session);
    return result;
}

static int audio_init(int audio_configuration, const POPUS_MULTISTREAM_CONFIGURATION opus, void *context, int flags) {
    UmbraStreamSession *session = context;
    if (!begin_callback(session)) {
        return -1;
    }
    if (opus == NULL) {
        end_callback(session);
        return -1;
    }
    UmbraAudioFormat format = {
        .audio_configuration = audio_configuration,
        .sample_rate = opus->sampleRate,
        .channel_count = opus->channelCount,
        .streams = opus->streams,
        .coupled_streams = opus->coupledStreams,
        .samples_per_frame = opus->samplesPerFrame,
        .flags = flags
    };
    memcpy(format.mapping, opus->mapping, sizeof(format.mapping));
    int32_t result = session->callbacks.audio_init == NULL
        ? 0
        : session->callbacks.audio_init(session->callbacks.context, &format);
    end_callback(session);
    return result;
}

static void audio_start(void) {
    UmbraStreamSession *session = begin_active_callback();
    if (session != NULL) {
        UmbraRendererLifecycleCallback callback = session->callbacks.audio_start;
        if (callback != NULL) {
            callback(session->callbacks.context);
        }
        end_callback(session);
    }
}

static void audio_stop(void) {
    UmbraStreamSession *session = begin_active_callback();
    if (session != NULL) {
        UmbraRendererLifecycleCallback callback = session->callbacks.audio_stop;
        if (callback != NULL) {
            callback(session->callbacks.context);
        }
        end_callback(session);
    }
}

static void audio_cleanup(void) {
    UmbraStreamSession *session = begin_active_callback();
    if (session != NULL) {
        UmbraRendererLifecycleCallback callback = session->callbacks.audio_cleanup;
        if (callback != NULL) {
            callback(session->callbacks.context);
        }
        end_callback(session);
    }
}

static void audio_packet(char *sample_data, int sample_length) {
    UmbraStreamSession *session = begin_active_callback();
    if (session == NULL) {
        return;
    }
    if (session->callbacks.audio_packet != NULL && sample_length >= 0 &&
        (sample_data != NULL || sample_length == 0)) {
        UmbraAudioPacket packet = {
            .data = (const uint8_t *)sample_data,
            .length = (size_t)sample_length
        };
        session->callbacks.audio_packet(session->callbacks.context, &packet);
    }
    end_callback(session);
}

void umbra_stream_configuration_init(UmbraStreamConfiguration *configuration) {
    if (configuration == NULL) {
        return;
    }
    memset(configuration, 0, sizeof(*configuration));
    configuration->width = 1920;
    configuration->height = 1080;
    configuration->fps = 60;
    configuration->bitrate = 20000;
    configuration->packet_size = 1392;
    configuration->remote_mode = UMBRA_STREAM_REMOTE_AUTO;
    configuration->audio_configuration = UMBRA_AUDIO_CONFIGURATION_STEREO;
    configuration->supported_video_formats = UMBRA_VIDEO_FORMAT_H264;
    configuration->color_space = UMBRA_STREAM_COLORSPACE_REC_601;
    configuration->color_range = UMBRA_STREAM_COLOR_RANGE_LIMITED;
    configuration->encryption_flags = -1;
    configuration->video_decode_queue_capacity = UMBRA_VIDEO_DECODE_QUEUE_CAPACITY_DEFAULT;
    configuration->rtsp_optimization_mode = UMBRA_STREAM_OPTIMIZATION_MODE_LEGACY;
    configuration->rtsp_fidelity_mode = UMBRA_STREAM_FIDELITY_UNSPECIFIED;
    configuration->input_optimization_mode = UMBRA_STREAM_OPTIMIZATION_MODE_LEGACY;
}

static int32_t clamp_video_decode_queue_capacity(int32_t capacity) {
    if (capacity < UMBRA_VIDEO_DECODE_QUEUE_CAPACITY_MIN) {
        return UMBRA_VIDEO_DECODE_QUEUE_CAPACITY_MIN;
    }
    if (capacity > UMBRA_VIDEO_DECODE_QUEUE_CAPACITY_MAX) {
        return UMBRA_VIDEO_DECODE_QUEUE_CAPACITY_MAX;
    }
    return capacity;
}

static bool is_known_single_video_format(int32_t format) {
    switch (format) {
        case UMBRA_VIDEO_FORMAT_H264:
        case UMBRA_VIDEO_FORMAT_H264_HIGH8_444:
        case UMBRA_VIDEO_FORMAT_H265:
        case UMBRA_VIDEO_FORMAT_H265_MAIN10:
        case UMBRA_VIDEO_FORMAT_H265_REXT8_444:
        case UMBRA_VIDEO_FORMAT_H265_REXT10_444:
        case UMBRA_VIDEO_FORMAT_AV1_MAIN8:
        case UMBRA_VIDEO_FORMAT_AV1_MAIN10:
        case UMBRA_VIDEO_FORMAT_AV1_HIGH8_444:
        case UMBRA_VIDEO_FORMAT_AV1_HIGH10_444:
            return true;
        default:
            return false;
    }
}

int32_t umbra_stream_configuration_validate(const UmbraStreamConfiguration *configuration) {
    if (configuration == NULL || configuration->address == NULL || configuration->address[0] == '\0' ||
        configuration->server_app_version == NULL || configuration->server_app_version[0] == '\0') {
        return UMBRA_STREAM_ERROR_INVALID_ARGUMENT;
    }
    if (configuration->width <= 0 || configuration->height <= 0 || configuration->fps <= 0 ||
        configuration->bitrate <= 0 || configuration->packet_size <= 0 ||
        configuration->client_refresh_rate_x100 < 0 ||
        configuration->audio_configuration == 0 ||
        !is_known_single_video_format(configuration->supported_video_formats)) {
        return UMBRA_STREAM_ERROR_INVALID_ARGUMENT;
    }
    if (configuration->client_microphone_requested &&
        (configuration->client_microphone_client_port == 0 ||
         configuration->client_microphone_client_port == UINT16_MAX)) {
        return UMBRA_STREAM_ERROR_INVALID_ARGUMENT;
    }
    if (configuration->remote_mode < UMBRA_STREAM_REMOTE_LOCAL || configuration->remote_mode > UMBRA_STREAM_REMOTE_AUTO ||
        configuration->color_space < UMBRA_STREAM_COLORSPACE_REC_601 || configuration->color_space > UMBRA_STREAM_COLORSPACE_REC_2020 ||
        configuration->color_range < UMBRA_STREAM_COLOR_RANGE_LIMITED || configuration->color_range > UMBRA_STREAM_COLOR_RANGE_FULL ||
        configuration->rtsp_optimization_mode < UMBRA_STREAM_OPTIMIZATION_MODE_LEGACY ||
        configuration->rtsp_optimization_mode > UMBRA_STREAM_OPTIMIZATION_MODE_QUALITY ||
        configuration->rtsp_fidelity_mode < UMBRA_STREAM_FIDELITY_UNSPECIFIED ||
        configuration->rtsp_fidelity_mode > UMBRA_STREAM_FIDELITY_CODEC_LOSSLESS_REQUIRED ||
        (configuration->rtsp_fidelity_mode != UMBRA_STREAM_FIDELITY_UNSPECIFIED &&
         configuration->rtsp_optimization_mode != UMBRA_STREAM_OPTIMIZATION_MODE_QUALITY) ||
        configuration->input_optimization_mode < UMBRA_STREAM_OPTIMIZATION_MODE_LEGACY ||
        configuration->input_optimization_mode > UMBRA_STREAM_OPTIMIZATION_MODE_QUALITY) {
        return UMBRA_STREAM_ERROR_INVALID_ARGUMENT;
    }
    return UMBRA_STREAM_OK;
}

UmbraStreamSession *umbra_stream_session_create(
    const UmbraStreamConfiguration *configuration,
    const UmbraStreamCallbacks *callbacks,
    int32_t *result
) {
    int32_t validation = umbra_stream_configuration_validate(configuration);
    if (result != NULL) {
        *result = validation;
    }
    if (validation != UMBRA_STREAM_OK) {
        return NULL;
    }
    UmbraStreamSession *session = calloc(1, sizeof(*session));
    if (session == NULL) {
        if (result != NULL) {
            *result = UMBRA_STREAM_ERROR_OUT_OF_MEMORY;
        }
        return NULL;
    }
    session->address = copy_optional_string(configuration->address);
    session->server_app_version = copy_optional_string(configuration->server_app_version);
    session->server_gfe_version = copy_optional_string(configuration->server_gfe_version);
    session->rtsp_session_url = copy_optional_string(configuration->rtsp_session_url);
    session->client_microphone_requested = configuration->client_microphone_requested;
    session->client_microphone_client_port = configuration->client_microphone_client_port;
    session->rtsp_optimization_mode = configuration->rtsp_optimization_mode;
    session->rtsp_fidelity_mode = configuration->rtsp_fidelity_mode;
    if (session->address == NULL || session->server_app_version == NULL ||
        (configuration->server_gfe_version != NULL && session->server_gfe_version == NULL) ||
        (configuration->rtsp_session_url != NULL && session->rtsp_session_url == NULL)) {
        free(session->address);
        free(session->server_app_version);
        free(session->server_gfe_version);
        free(session->rtsp_session_url);
        free(session);
        if (result != NULL) {
            *result = UMBRA_STREAM_ERROR_OUT_OF_MEMORY;
        }
        return NULL;
    }
    LiInitializeServerInformation(&session->server);
    session->server.address = session->address;
    session->server.serverInfoAppVersion = session->server_app_version;
    session->server.serverInfoGfeVersion = session->server_gfe_version;
    session->server.rtspSessionUrl = session->rtsp_session_url;
    session->server.serverCodecModeSupport = configuration->server_codec_mode_support;

    LiInitializeStreamConfiguration(&session->stream);
    session->stream.width = configuration->width;
    session->stream.height = configuration->height;
    session->stream.fps = configuration->fps;
    session->stream.bitrate = configuration->bitrate;
    session->stream.packetSize = configuration->packet_size;
    session->stream.streamingRemotely = configuration->remote_mode;
    session->stream.audioConfiguration = configuration->audio_configuration;
    session->stream.supportedVideoFormats = configuration->supported_video_formats;
    session->stream.clientRefreshRateX100 = configuration->client_refresh_rate_x100;
    session->stream.colorSpace = configuration->color_space;
    session->stream.colorRange = configuration->color_range;
    session->stream.encryptionFlags = configuration->encryption_flags;
    session->stream.videoDecodeQueueCapacity = clamp_video_decode_queue_capacity(
        configuration->video_decode_queue_capacity
    );
    session->stream.optimizationMode = configuration->input_optimization_mode;
    memcpy(session->stream.remoteInputAesKey, configuration->remote_input_aes_key, sizeof(configuration->remote_input_aes_key));
    memcpy(session->stream.remoteInputAesIv, configuration->remote_input_aes_iv, sizeof(configuration->remote_input_aes_iv));

    if (callbacks != NULL) {
        session->callbacks = *callbacks;
    }
    LiInitializeVideoCallbacks(&session->video_callbacks);
    session->video_callbacks.setup = video_setup;
    session->video_callbacks.start = video_start;
    session->video_callbacks.stop = video_stop;
    session->video_callbacks.cleanup = video_cleanup;
    session->video_callbacks.submitDecodeUnit = video_frame;
    session->video_callbacks.capabilities = configuration->video_capabilities;

    LiInitializeAudioCallbacks(&session->audio_callbacks);
    session->audio_callbacks.init = audio_init;
    session->audio_callbacks.start = audio_start;
    session->audio_callbacks.stop = audio_stop;
    session->audio_callbacks.cleanup = audio_cleanup;
    session->audio_callbacks.decodeAndPlaySample = audio_packet;
    session->audio_callbacks.capabilities = configuration->audio_capabilities;

    session->video_flags = configuration->video_renderer_flags;
    session->audio_flags = configuration->audio_renderer_flags;
    atomic_init(&session->state, UMBRA_STREAM_STATE_IDLE);
    atomic_init(&session->cancellation_requested, false);
    pthread_mutex_init(&session->callback_mutex, NULL);
    pthread_cond_init(&session->callback_condition, NULL);
#if defined(UMBRA_STREAM_TESTING)
    pthread_mutex_init(&session->test_input_mutex, NULL);
    pthread_cond_init(&session->test_input_condition, NULL);
#endif
    if (result != NULL) {
        *result = UMBRA_STREAM_OK;
    }
    return session;
}

int32_t umbra_stream_session_set_prepared_video_callback(
    UmbraStreamSession *session,
    UmbraPreparedVideoFrameCallback callback
) {
    if (session == NULL) {
        return UMBRA_STREAM_ERROR_INVALID_ARGUMENT;
    }
    pthread_mutex_lock(&session->callback_mutex);
    if (session->destroyed) {
        pthread_mutex_unlock(&session->callback_mutex);
        return UMBRA_STREAM_ERROR_DESTROYED;
    }
    if (umbra_stream_session_state(session) != UMBRA_STREAM_STATE_IDLE) {
        pthread_mutex_unlock(&session->callback_mutex);
        return UMBRA_STREAM_ERROR_INVALID_STATE;
    }
    session->prepared_video_frame = callback;
    pthread_mutex_unlock(&session->callback_mutex);
    return UMBRA_STREAM_OK;
}

int32_t umbra_stream_session_destroy(UmbraStreamSession *session) {
    if (session == NULL) {
        return UMBRA_STREAM_ERROR_INVALID_ARGUMENT;
    }
    if (umbra_stream_session_state(session) != UMBRA_STREAM_STATE_IDLE) {
        return UMBRA_STREAM_ERROR_INVALID_STATE;
    }
    pthread_mutex_lock(&g_active_mutex);
    if (g_active_session == session) {
        pthread_mutex_unlock(&g_active_mutex);
        return UMBRA_STREAM_ERROR_BUSY;
    }
    pthread_mutex_lock(&session->callback_mutex);
    session->destroyed = true;
    pthread_cond_broadcast(&session->callback_condition);
    pthread_mutex_unlock(&g_active_mutex);
    while (session->callbacks_in_flight != 0) {
        pthread_cond_wait(&session->callback_condition, &session->callback_mutex);
    }
    pthread_mutex_unlock(&session->callback_mutex);
#if defined(UMBRA_STREAM_TESTING)
    pthread_cond_destroy(&session->test_input_condition);
    pthread_mutex_destroy(&session->test_input_mutex);
#endif
    pthread_cond_destroy(&session->callback_condition);
    pthread_mutex_destroy(&session->callback_mutex);
    free(session->address);
    free(session->server_app_version);
    free(session->server_gfe_version);
    free(session->rtsp_session_url);
    free(session);
    return UMBRA_STREAM_OK;
}

UmbraStreamState umbra_stream_session_state(const UmbraStreamSession *session) {
    if (session == NULL) {
        return UMBRA_STREAM_STATE_IDLE;
    }
    return (UmbraStreamState)atomic_load_explicit(&session->state, memory_order_acquire);
}

static void release_active_session(UmbraStreamSession *session) {
    pthread_mutex_lock(&g_active_mutex);
    if (g_active_session == session) {
        g_active_session = NULL;
    }
    pthread_mutex_unlock(&g_active_mutex);
}

int32_t umbra_stream_session_start(UmbraStreamSession *session) {
    if (session == NULL) {
        return UMBRA_STREAM_ERROR_INVALID_ARGUMENT;
    }
    pthread_mutex_lock(&g_active_mutex);
    if (g_active_session != NULL) {
        pthread_mutex_unlock(&g_active_mutex);
        return UMBRA_STREAM_ERROR_BUSY;
    }
    pthread_mutex_lock(&session->callback_mutex);
    if (umbra_stream_session_state(session) != UMBRA_STREAM_STATE_IDLE) {
        pthread_mutex_unlock(&session->callback_mutex);
        pthread_mutex_unlock(&g_active_mutex);
        return UMBRA_STREAM_ERROR_INVALID_STATE;
    }
    if (session->callbacks.video_setup == NULL ||
        (session->callbacks.video_frame == NULL && session->prepared_video_frame == NULL) ||
        session->callbacks.audio_init == NULL || session->callbacks.audio_packet == NULL) {
        pthread_mutex_unlock(&session->callback_mutex);
        pthread_mutex_unlock(&g_active_mutex);
        return UMBRA_STREAM_ERROR_INVALID_ARGUMENT;
    }
    atomic_store_explicit(&session->cancellation_requested, false, memory_order_release);
    atomic_store_explicit(&session->state, UMBRA_STREAM_STATE_STARTING, memory_order_release);
    g_active_session = session;
    pthread_mutex_unlock(&session->callback_mutex);
    pthread_mutex_unlock(&g_active_mutex);

    umbra_client_microphone_rtsp_configure(
        session->client_microphone_requested,
        session->client_microphone_client_port
    );
    if (!umbra_optimization_mode_rtsp_configure(session->rtsp_optimization_mode)) {
        umbra_client_microphone_rtsp_clear();
        atomic_store_explicit(&session->state, UMBRA_STREAM_STATE_IDLE, memory_order_release);
        release_active_session(session);
        return UMBRA_STREAM_ERROR_INVALID_ARGUMENT;
    }
    if (!umbra_video_fidelity_rtsp_configure(session->rtsp_fidelity_mode)) {
        umbra_optimization_mode_rtsp_clear();
        umbra_client_microphone_rtsp_clear();
        atomic_store_explicit(&session->state, UMBRA_STREAM_STATE_IDLE, memory_order_release);
        release_active_session(session);
        return UMBRA_STREAM_ERROR_INVALID_ARGUMENT;
    }

    CONNECTION_LISTENER_CALLBACKS connection_callbacks;
    LiInitializeConnectionCallbacks(&connection_callbacks);
    connection_callbacks.stageStarting = connection_stage_starting;
    connection_callbacks.stageComplete = connection_stage_complete;
    connection_callbacks.stageFailed = connection_stage_failed;
    connection_callbacks.connectionStarted = connection_started;
    connection_callbacks.connectionTerminated = connection_terminated;
    connection_callbacks.logMessage = connection_log;
    connection_callbacks.rumble = connection_rumble;
    connection_callbacks.connectionStatusUpdate = connection_status;
    connection_callbacks.setHdrMode = connection_hdr;
    connection_callbacks.rumbleTriggers = connection_trigger_rumble;
    connection_callbacks.setMotionEventState = connection_motion_state;
    connection_callbacks.setControllerLED = connection_controller_led;
    connection_callbacks.setAdaptiveTriggers = connection_adaptive_triggers;

    int32_t result = LiStartConnection(
        &session->server,
        &session->stream,
        &connection_callbacks,
        &session->video_callbacks,
        &session->audio_callbacks,
        session,
        session->video_flags,
        session,
        session->audio_flags
    );
    /* The blocking call returns after setup, failure, or LiInterruptConnection(). */
    umbra_optimization_mode_rtsp_clear();
    if (result != 0) {
        atomic_store_explicit(&session->state, UMBRA_STREAM_STATE_IDLE, memory_order_release);
        release_active_session(session);
    } else if (atomic_load_explicit(&session->cancellation_requested, memory_order_acquire)) {
        (void)umbra_stream_session_stop(session);
        result = UMBRA_STREAM_ERROR_CANCELLED;
    }
    if (result == 0) {
        UmbraClientMicrophoneRTSPSnapshot snapshot;
        if (umbra_client_microphone_rtsp_take_snapshot(&snapshot) && begin_callback(session)) {
            UmbraStreamEvent event = {0};
            event.type = UMBRA_STREAM_EVENT_CLIENT_MICROPHONE_GENERATION;
            memcpy(
                event.client_microphone_generation.session_id,
                snapshot.session_id,
                sizeof(snapshot.session_id)
            );
            memcpy(
                event.client_microphone_generation.salt,
                snapshot.salt,
                sizeof(snapshot.salt)
            );
            event.client_microphone_generation.server_port = snapshot.server_port;
            event.client_microphone_generation.client_port = snapshot.client_port;
            memcpy(
                event.client_microphone_generation.remote_address,
                snapshot.remote_address,
                sizeof(snapshot.remote_address)
            );
            emit_event(session, &event);
            end_callback(session);
        }
        else {
            umbra_client_microphone_rtsp_clear();
        }
    }
    else {
        umbra_client_microphone_rtsp_clear();
    }
    return result;
}

int32_t umbra_stream_session_stop(UmbraStreamSession *session) {
    if (session == NULL) {
        return UMBRA_STREAM_ERROR_INVALID_ARGUMENT;
    }
    UmbraStreamState state = umbra_stream_session_state(session);
    if (state == UMBRA_STREAM_STATE_IDLE) {
        return UMBRA_STREAM_OK;
    }
    if (state == UMBRA_STREAM_STATE_STARTING) {
        pthread_mutex_lock(&session->callback_mutex);
        state = umbra_stream_session_state(session);
        if (state != UMBRA_STREAM_STATE_STARTING) {
            pthread_mutex_unlock(&session->callback_mutex);
            return umbra_stream_session_stop(session);
        }
        bool was_requested = atomic_exchange_explicit(
            &session->cancellation_requested,
            true,
            memory_order_acq_rel
        );
        pthread_mutex_unlock(&session->callback_mutex);
        if (!was_requested) {
            LiInterruptConnection();
        }
        return UMBRA_STREAM_OK;
    }
    if (state != UMBRA_STREAM_STATE_CONNECTED && state != UMBRA_STREAM_STATE_TERMINATED) {
        return UMBRA_STREAM_ERROR_INVALID_STATE;
    }
    int expected = state;
    if (!atomic_compare_exchange_strong(&session->state, &expected, UMBRA_STREAM_STATE_STOPPING)) {
        return UMBRA_STREAM_ERROR_INVALID_STATE;
    }
    LiStopConnection();
    atomic_store_explicit(&session->state, UMBRA_STREAM_STATE_IDLE, memory_order_release);
    release_active_session(session);
    return UMBRA_STREAM_OK;
}

int32_t umbra_stream_session_cancel(UmbraStreamSession *session) {
    return umbra_stream_session_stop(session);
}

static int32_t require_connected(UmbraStreamSession *session) {
    if (session == NULL) {
        return UMBRA_STREAM_ERROR_INVALID_ARGUMENT;
    }
    return umbra_stream_session_state(session) == UMBRA_STREAM_STATE_CONNECTED
        ? UMBRA_STREAM_OK
        : UMBRA_STREAM_ERROR_INVALID_STATE;
}

static int32_t begin_connected_input(UmbraStreamSession *session) {
    if (session == NULL) {
        return UMBRA_STREAM_ERROR_INVALID_ARGUMENT;
    }
    if (!begin_callback(session)) {
        return UMBRA_STREAM_ERROR_INVALID_STATE;
    }
    int32_t result = require_connected(session);
    if (result != UMBRA_STREAM_OK) {
        end_callback(session);
        return result;
    }
#if defined(UMBRA_STREAM_TESTING)
    pthread_mutex_lock(&session->test_input_mutex);
    while (session->test_input_blocked) {
        session->test_input_waiting = true;
        pthread_cond_broadcast(&session->test_input_condition);
        pthread_cond_wait(&session->test_input_condition, &session->test_input_mutex);
    }
    session->test_input_waiting = false;
    pthread_mutex_unlock(&session->test_input_mutex);
#endif
    return result;
}

static int32_t finish_input(UmbraStreamSession *session, int32_t result) {
    end_callback(session);
    return result;
}

int32_t umbra_stream_session_get_statistics(
    const UmbraStreamSession *session,
    UmbraStreamStatistics *statistics
) {
    if (statistics == NULL) {
        return UMBRA_STREAM_ERROR_INVALID_ARGUMENT;
    }
    int32_t guard = require_connected((UmbraStreamSession *)session);
    if (guard != UMBRA_STREAM_OK) {
        return guard;
    }
    memset(statistics, 0, sizeof(*statistics));
    statistics->has_estimated_rtt = LiGetEstimatedRttInfo(
        &statistics->estimated_rtt_ms,
        &statistics->estimated_rtt_variance_ms
    );
    statistics->pending_video_frames = LiGetPendingVideoFrames();
    statistics->video_decode_queue_capacity = LiGetVideoDecodeQueueCapacity();
    statistics->pending_audio_frames = LiGetPendingAudioFrames();
    statistics->pending_audio_duration_ms = LiGetPendingAudioDuration();
    const RTP_AUDIO_STATS *audio = LiGetRTPAudioStats();
    if (audio != NULL) {
        statistics->audio_packets = audio->packetCountAudio;
        statistics->audio_fec_packets = audio->packetCountFec;
        statistics->audio_fec_recovered = audio->packetCountFecRecovered;
        statistics->audio_fec_failed = audio->packetCountFecFailed;
        statistics->audio_out_of_sequence = audio->packetCountOOS;
        statistics->audio_invalid = audio->packetCountInvalid + audio->packetCountFecInvalid;
    }
    const RTP_VIDEO_STATS *video = LiGetRTPVideoStats();
    if (video != NULL) {
        statistics->video_packets = video->packetCountVideo;
        statistics->video_fec_packets = video->packetCountFec;
        statistics->video_fec_recovered = video->packetCountFecRecovered;
        statistics->video_fec_failed = video->packetCountFecFailed;
        statistics->video_out_of_sequence = video->packetCountOOS;
        statistics->video_invalid = video->packetCountInvalid + video->packetCountFecInvalid;
    }
    return UMBRA_STREAM_OK;
}

int32_t umbra_stream_session_request_idr(UmbraStreamSession *session) {
    int32_t guard = require_connected(session);
    if (guard == UMBRA_STREAM_OK) {
        LiRequestIdrFrame();
    }
    return guard;
}

int32_t umbra_stream_session_send_mouse_move(UmbraStreamSession *session, int16_t delta_x, int16_t delta_y) {
    int32_t guard = begin_connected_input(session);
    return guard == UMBRA_STREAM_OK
        ? finish_input(session, LiSendMouseMoveEvent(delta_x, delta_y))
        : guard;
}

int32_t umbra_stream_session_send_mouse_position(UmbraStreamSession *session, int16_t x, int16_t y, int16_t width, int16_t height) {
    int32_t guard = begin_connected_input(session);
    return guard == UMBRA_STREAM_OK
        ? finish_input(session, LiSendMousePositionEvent(x, y, width, height))
        : guard;
}

int32_t umbra_stream_session_send_mouse_move_as_position(UmbraStreamSession *session, int16_t delta_x, int16_t delta_y, int16_t width, int16_t height) {
    int32_t guard = begin_connected_input(session);
    return guard == UMBRA_STREAM_OK
        ? finish_input(session, LiSendMouseMoveAsMousePositionEvent(delta_x, delta_y, width, height))
        : guard;
}

int32_t umbra_stream_session_send_mouse_button(UmbraStreamSession *session, int8_t action, int32_t button) {
    int32_t guard = begin_connected_input(session);
    return guard == UMBRA_STREAM_OK
        ? finish_input(session, LiSendMouseButtonEvent(action, button))
        : guard;
}

int32_t umbra_stream_session_send_scroll(UmbraStreamSession *session, int16_t vertical, int16_t horizontal) {
    int32_t guard = begin_connected_input(session);
    if (guard != UMBRA_STREAM_OK) {
        return guard;
    }
    int32_t result = vertical == 0 ? 0 : LiSendHighResScrollEvent(vertical);
    if (result == 0 && horizontal != 0) {
        result = LiSendHighResHScrollEvent(horizontal);
    }
    return finish_input(session, result);
}

int32_t umbra_stream_session_send_keyboard(UmbraStreamSession *session, int16_t key_code, int8_t action, int8_t modifiers, int8_t flags) {
    int32_t guard = begin_connected_input(session);
    return guard == UMBRA_STREAM_OK
        ? finish_input(session, LiSendKeyboardEvent2(key_code, action, modifiers, flags))
        : guard;
}

int32_t umbra_stream_session_send_utf8_text(UmbraStreamSession *session, const char *text, size_t length) {
    int32_t guard = begin_connected_input(session);
    if (guard != UMBRA_STREAM_OK) {
        return guard;
    }
    if (text == NULL || length == 0 || length > UINT32_MAX) {
        return finish_input(session, UMBRA_STREAM_ERROR_INVALID_ARGUMENT);
    }
    return finish_input(session, LiSendUtf8TextEvent(text, (unsigned int)length));
}

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
) {
    int32_t guard = begin_connected_input(session);
    return guard == UMBRA_STREAM_OK
        ? finish_input(
            session,
            LiSendTouchEvent(
                event_type,
                pointer_id,
                x,
                y,
                pressure_or_distance,
                contact_area_major,
                contact_area_minor,
                rotation
            )
        )
        : guard;
}

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
) {
    int32_t guard = begin_connected_input(session);
    return guard == UMBRA_STREAM_OK
        ? finish_input(
            session,
            LiSendPenEvent(
                event_type,
                tool_type,
                pen_buttons,
                x,
                y,
                pressure_or_distance,
                contact_area_major,
                contact_area_minor,
                rotation,
                tilt
            )
        )
        : guard;
}

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
) {
    int32_t guard = begin_connected_input(session);
    return guard == UMBRA_STREAM_OK
        ? finish_input(
            session,
            LiSendMultiControllerEvent(
                controller_number,
                active_gamepad_mask,
                button_flags,
                left_trigger,
                right_trigger,
                left_stick_x,
                left_stick_y,
                right_stick_x,
                right_stick_y
            )
        )
        : guard;
}

int32_t umbra_stream_session_send_controller_arrival(
    UmbraStreamSession *session,
    uint8_t controller_number,
    uint16_t active_gamepad_mask,
    uint8_t type,
    uint32_t supported_button_flags,
    uint16_t capabilities
) {
    int32_t guard = begin_connected_input(session);
    return guard == UMBRA_STREAM_OK
        ? finish_input(
            session,
            LiSendControllerArrivalEvent(
                controller_number,
                active_gamepad_mask,
                type,
                supported_button_flags,
                capabilities
            )
        )
        : guard;
}

int32_t umbra_stream_session_send_controller_touch(
    UmbraStreamSession *session,
    uint8_t controller_number,
    uint8_t event_type,
    uint8_t touchpad_index,
    uint32_t pointer_id,
    float x,
    float y,
    float pressure
) {
    int32_t guard = begin_connected_input(session);
    return guard == UMBRA_STREAM_OK
        ? finish_input(
            session,
            LiSendControllerTouchEvent2(controller_number, event_type, touchpad_index, pointer_id, x, y, pressure)
        )
        : guard;
}

int32_t umbra_stream_session_send_controller_motion(
    UmbraStreamSession *session,
    uint8_t controller_number,
    uint8_t motion_type,
    float x,
    float y,
    float z
) {
    int32_t guard = begin_connected_input(session);
    return guard == UMBRA_STREAM_OK
        ? finish_input(session, LiSendControllerMotionEvent(controller_number, motion_type, x, y, z))
        : guard;
}

int32_t umbra_stream_session_send_controller_battery(
    UmbraStreamSession *session,
    uint8_t controller_number,
    uint8_t battery_state,
    uint8_t battery_percentage
) {
    int32_t guard = begin_connected_input(session);
    return guard == UMBRA_STREAM_OK
        ? finish_input(
            session,
            LiSendControllerBatteryEvent(controller_number, battery_state, battery_percentage)
        )
        : guard;
}

int32_t umbra_stream_session_get_host_feature_flags(UmbraStreamSession *session, uint32_t *feature_flags) {
    int32_t guard = require_connected(session);
    if (guard != UMBRA_STREAM_OK) {
        return guard;
    }
    if (feature_flags == NULL) {
        return UMBRA_STREAM_ERROR_INVALID_ARGUMENT;
    }
    *feature_flags = LiGetHostFeatureFlags();
    return UMBRA_STREAM_OK;
}

#if defined(UMBRA_STREAM_TESTING)
static UmbraStreamSession *test_swap_active_session(UmbraStreamSession *session) {
    pthread_mutex_lock(&g_active_mutex);
    UmbraStreamSession *previous = g_active_session;
    g_active_session = session;
    pthread_mutex_unlock(&g_active_mutex);
    return previous;
}

void umbra_stream_test_emit_log(UmbraStreamSession *session, const char *message) {
    if (!begin_callback(session)) {
        return;
    }
    UmbraStreamEvent event = {0};
    event.type = UMBRA_STREAM_EVENT_LOG;
    event.message = message;
    emit_event(session, &event);
    end_callback(session);
}

void umbra_stream_test_set_state(UmbraStreamSession *session, UmbraStreamState state) {
    atomic_store_explicit(&session->state, state, memory_order_release);
}

int32_t umbra_stream_test_video_decode_queue_capacity(const UmbraStreamSession *session) {
    return session->stream.videoDecodeQueueCapacity;
}

int32_t umbra_stream_test_input_optimization_mode(const UmbraStreamSession *session) {
    return session->stream.optimizationMode;
}

int32_t umbra_stream_test_rtsp_optimization_mode(const UmbraStreamSession *session) {
    return session->rtsp_optimization_mode;
}

int32_t umbra_stream_test_video_capabilities(const UmbraStreamSession *session) {
    return session->video_callbacks.capabilities;
}

void umbra_stream_test_set_input_blocked(UmbraStreamSession *session, bool blocked) {
    pthread_mutex_lock(&session->test_input_mutex);
    session->test_input_blocked = blocked;
    pthread_cond_broadcast(&session->test_input_condition);
    pthread_mutex_unlock(&session->test_input_mutex);
}

void umbra_stream_test_wait_until_input_blocked(UmbraStreamSession *session) {
    pthread_mutex_lock(&session->test_input_mutex);
    while (!session->test_input_waiting) {
        pthread_cond_wait(&session->test_input_condition, &session->test_input_mutex);
    }
    pthread_mutex_unlock(&session->test_input_mutex);
}

void umbra_stream_test_wait_until_destroy_started(UmbraStreamSession *session) {
    pthread_mutex_lock(&session->callback_mutex);
    while (!session->destroyed) {
        pthread_cond_wait(&session->callback_condition, &session->callback_mutex);
    }
    pthread_mutex_unlock(&session->callback_mutex);
}

void umbra_stream_test_clear_active_session(UmbraStreamSession *session) {
    pthread_mutex_lock(&g_active_mutex);
    if (g_active_session == session) {
        g_active_session = NULL;
    }
    pthread_mutex_unlock(&g_active_mutex);
}

int32_t umbra_stream_test_video_setup(UmbraStreamSession *session, const UmbraVideoFormat *format) {
    if (format == NULL) {
        return -1;
    }
    return video_setup(
        format->format,
        format->width,
        format->height,
        format->redraw_rate,
        session,
        format->flags
    );
}

void umbra_stream_test_video_start(UmbraStreamSession *session) {
    UmbraStreamSession *previous = test_swap_active_session(session);
    video_start();
    test_swap_active_session(previous);
}

void umbra_stream_test_video_stop(UmbraStreamSession *session) {
    UmbraStreamSession *previous = test_swap_active_session(session);
    video_stop();
    test_swap_active_session(previous);
}

void umbra_stream_test_video_cleanup(UmbraStreamSession *session) {
    UmbraStreamSession *previous = test_swap_active_session(session);
    video_cleanup();
    test_swap_active_session(previous);
}

int32_t umbra_stream_test_video_frame(
    UmbraStreamSession *session,
    const UmbraVideoFrame *frame,
    size_t first_chunk_length
) {
    if (frame == NULL || frame->data == NULL || frame->length > INT_MAX ||
        first_chunk_length == 0 || first_chunk_length >= frame->length) {
        return DR_NEED_IDR;
    }
    LENTRY second = {
        .next = NULL,
        .data = (char *)(frame->data + first_chunk_length),
        .length = (int)(frame->length - first_chunk_length),
        .bufferType = BUFFER_TYPE_PICDATA
    };
    LENTRY first = {
        .next = &second,
        .data = (char *)frame->data,
        .length = (int)first_chunk_length,
        .bufferType = BUFFER_TYPE_PICDATA
    };
    DECODE_UNIT unit = {
        .frameNumber = frame->frame_number,
        .frameType = frame->frame_type,
        .frameHostProcessingLatency = frame->host_processing_latency_tenths_ms,
        .receiveTimeUs = frame->receive_time_us,
        .enqueueTimeUs = frame->enqueue_time_us,
        .presentationTimeUs = frame->presentation_time_us,
        .rtpTimestamp = frame->rtp_timestamp,
        .fullLength = (int)frame->length,
        .bufferList = &first,
        .hdrActive = frame->hdr_active,
        .colorspace = frame->color_space
    };
    UmbraStreamSession *previous = test_swap_active_session(session);
    int32_t result = video_frame(&unit);
    test_swap_active_session(previous);
    return result;
}

int32_t umbra_stream_test_video_frame_fragments(
    UmbraStreamSession *session,
    const UmbraVideoFrame *frame,
    const size_t *chunk_lengths,
    size_t chunk_count
) {
    if (session == NULL || frame == NULL || frame->data == NULL || chunk_lengths == NULL ||
        chunk_count == 0 || chunk_count > SIZE_MAX / sizeof(LENTRY)) {
        return DR_NEED_IDR;
    }
    LENTRY *entries = calloc(chunk_count, sizeof(*entries));
    if (entries == NULL) {
        return DR_NEED_IDR;
    }
    size_t offset = 0;
    bool valid = frame->length <= INT_MAX;
    for (size_t index = 0; valid && index < chunk_count; index++) {
        size_t length = chunk_lengths[index];
        valid = length > 0 && length <= INT_MAX && length <= frame->length - offset;
        if (valid) {
            entries[index].next = index + 1 < chunk_count ? &entries[index + 1] : NULL;
            entries[index].data = (char *)(frame->data + offset);
            entries[index].length = (int)length;
            entries[index].bufferType = BUFFER_TYPE_PICDATA;
            offset += length;
        }
    }
    valid = valid && offset == frame->length;
    int32_t result = DR_NEED_IDR;
    if (valid) {
        DECODE_UNIT unit = {
            .frameNumber = frame->frame_number,
            .frameType = frame->frame_type,
            .frameHostProcessingLatency = frame->host_processing_latency_tenths_ms,
            .receiveTimeUs = frame->receive_time_us,
            .enqueueTimeUs = frame->enqueue_time_us,
            .presentationTimeUs = frame->presentation_time_us,
            .rtpTimestamp = frame->rtp_timestamp,
            .fullLength = (int)frame->length,
            .bufferList = entries,
            .hdrActive = frame->hdr_active,
            .colorspace = frame->color_space
        };
        UmbraStreamSession *previous = test_swap_active_session(session);
        result = video_frame(&unit);
        test_swap_active_session(previous);
    }
    free(entries);
    return result;
}

int32_t umbra_stream_test_audio_init(UmbraStreamSession *session, const UmbraAudioFormat *format) {
    if (format == NULL) {
        return -1;
    }
    OPUS_MULTISTREAM_CONFIGURATION opus = {
        .sampleRate = format->sample_rate,
        .channelCount = format->channel_count,
        .streams = format->streams,
        .coupledStreams = format->coupled_streams,
        .samplesPerFrame = format->samples_per_frame
    };
    memcpy(opus.mapping, format->mapping, sizeof(opus.mapping));
    return audio_init(format->audio_configuration, &opus, session, format->flags);
}

void umbra_stream_test_audio_start(UmbraStreamSession *session) {
    UmbraStreamSession *previous = test_swap_active_session(session);
    audio_start();
    test_swap_active_session(previous);
}

void umbra_stream_test_audio_stop(UmbraStreamSession *session) {
    UmbraStreamSession *previous = test_swap_active_session(session);
    audio_stop();
    test_swap_active_session(previous);
}

void umbra_stream_test_audio_cleanup(UmbraStreamSession *session) {
    UmbraStreamSession *previous = test_swap_active_session(session);
    audio_cleanup();
    test_swap_active_session(previous);
}

void umbra_stream_test_audio_packet(UmbraStreamSession *session, const uint8_t *data, size_t length) {
    if ((data == NULL && length != 0) || length > INT_MAX) {
        return;
    }
    UmbraStreamSession *previous = test_swap_active_session(session);
    audio_packet((char *)data, (int)length);
    test_swap_active_session(previous);
}

void umbra_stream_test_connection_terminated(UmbraStreamSession *session, int32_t error_code) {
    UmbraStreamSession *previous = test_swap_active_session(session);
    connection_terminated(error_code);
    test_swap_active_session(previous);
}
#endif
