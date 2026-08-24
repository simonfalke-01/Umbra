#include "UmbraStreamingBridge.h"
#include "UmbraStreamingBridgeTestHooks.h"
#include "Limelight.h"
#include "Input.h"
#include "LinkedBlockingQueue.h"
#include "Rtsp.h"
#include "UmbraClientMicrophoneRTSPExtension.h"
#include "UmbraOptimizationModeRTSPExtension.h"

#ifdef NDEBUG
#undef NDEBUG
#endif
#include <assert.h>
#include <arpa/inet.h>
#include <errno.h>
#include <limits.h>
#include <netinet/in.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

extern struct sockaddr_storage RemoteAddr;

static UmbraStreamConfiguration valid_configuration(void) {
    UmbraStreamConfiguration configuration;
    umbra_stream_configuration_init(&configuration);
    configuration.address = "127.0.0.1";
    configuration.server_app_version = "7.1.431.0";
    return configuration;
}

typedef struct CallbackRecord {
    int event_calls;
    char message[32];
    UmbraStreamEvent event;
    int video_setup_calls;
    UmbraVideoFormat video_format;
    int32_t video_setup_result;
    int video_start_calls;
    int video_stop_calls;
    int video_cleanup_calls;
    int video_frame_calls;
    UmbraVideoFrame video_frame;
    uint8_t video_data[32];
    const uint8_t *video_source;
    bool take_video_data;
    uint8_t *owned_video_data;
    size_t owned_video_length;
    int32_t video_frame_result;
    int prepared_video_frame_calls;
    UmbraPreparedVideoFrame prepared_video_frame;
    uint8_t prepared_video_data[256];
    bool skip_prepared_copy;
    bool take_prepared_data;
    uint8_t *owned_prepared_data;
    size_t owned_prepared_length;
    bool block_prepared_callback;
    bool prepared_callback_waiting;
    pthread_mutex_t prepared_callback_mutex;
    pthread_cond_t prepared_callback_condition;
    int audio_init_calls;
    UmbraAudioFormat audio_format;
    int32_t audio_init_result;
    int audio_start_calls;
    int audio_stop_calls;
    int audio_cleanup_calls;
    int audio_packet_calls;
    uint8_t audio_data[32];
    size_t audio_length;
} CallbackRecord;

typedef struct InputTeardownRace {
    UmbraStreamSession *session;
    int32_t input_result;
    int32_t destroy_result;
    atomic_bool destroy_finished;
} InputTeardownRace;

typedef struct PreparedVideoTeardownRace {
    UmbraStreamSession *session;
    UmbraVideoFrame frame;
    int32_t video_result;
    int32_t destroy_result;
    atomic_bool destroy_finished;
} PreparedVideoTeardownRace;

#define QUEUE_COUNT_RACE_ITEMS 4096
#define QUEUE_COUNT_RACE_CAPACITY 8

typedef struct QueueCountRace {
    LINKED_BLOCKING_QUEUE queue;
    LINKED_BLOCKING_QUEUE_ENTRY entries[QUEUE_COUNT_RACE_ITEMS];
    atomic_int produced;
    atomic_int consumed;
    atomic_bool failed;
} QueueCountRace;

#define INPUT_PACKET_RECORD_CAPACITY 512
#define INPUT_PACKET_BYTE_CAPACITY 128
#define TEST_ENET_PACKET_FLAG_RELIABLE 1u

typedef struct InputPacketRecord {
    unsigned char bytes[INPUT_PACKET_BYTE_CAPACITY];
    int length;
    unsigned char channel_id;
    unsigned int flags;
    bool more_data;
} InputPacketRecord;

typedef struct InputPacketRecorder {
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    InputPacketRecord packets[INPUT_PACKET_RECORD_CAPACITY];
    int packet_count;
    bool block_next_packet;
    bool packet_blocked;
    bool release_blocked_packet;
} InputPacketRecorder;

static void initialize_input_packet_recorder(InputPacketRecorder *recorder) {
    memset(recorder, 0, sizeof(*recorder));
    assert(pthread_mutex_init(&recorder->mutex, NULL) == 0);
    assert(pthread_cond_init(&recorder->condition, NULL) == 0);
}

static void destroy_input_packet_recorder(InputPacketRecorder *recorder) {
    assert(pthread_cond_destroy(&recorder->condition) == 0);
    assert(pthread_mutex_destroy(&recorder->mutex) == 0);
}

static struct timespec input_test_deadline(void) {
    struct timespec deadline;
    assert(clock_gettime(CLOCK_REALTIME, &deadline) == 0);
    deadline.tv_sec += 5;
    return deadline;
}

static bool record_input_packet(
    const unsigned char *packet,
    int packet_length,
    unsigned char channel_id,
    unsigned int packet_flags,
    bool more_data,
    void *context
) {
    InputPacketRecorder *recorder = context;
    assert(packet != NULL);
    assert(packet_length > 0);
    assert(packet_length <= INPUT_PACKET_BYTE_CAPACITY);

    pthread_mutex_lock(&recorder->mutex);
    assert(recorder->packet_count < INPUT_PACKET_RECORD_CAPACITY);
    InputPacketRecord *record = &recorder->packets[recorder->packet_count++];
    memcpy(record->bytes, packet, (size_t)packet_length);
    record->length = packet_length;
    record->channel_id = channel_id;
    record->flags = packet_flags;
    record->more_data = more_data;
    pthread_cond_broadcast(&recorder->condition);

    if (recorder->block_next_packet) {
        recorder->block_next_packet = false;
        recorder->packet_blocked = true;
        pthread_cond_broadcast(&recorder->condition);
        while (!recorder->release_blocked_packet) {
            pthread_cond_wait(&recorder->condition, &recorder->mutex);
        }
        recorder->release_blocked_packet = false;
        recorder->packet_blocked = false;
    }

    pthread_mutex_unlock(&recorder->mutex);
    return true;
}

static void wait_for_input_packets(InputPacketRecorder *recorder, int packet_count) {
    struct timespec deadline = input_test_deadline();
    pthread_mutex_lock(&recorder->mutex);
    while (recorder->packet_count < packet_count) {
        int result = pthread_cond_timedwait(&recorder->condition, &recorder->mutex, &deadline);
        assert(result == 0 || result == EINTR);
    }
    pthread_mutex_unlock(&recorder->mutex);
}

static void block_next_input_packet(InputPacketRecorder *recorder) {
    pthread_mutex_lock(&recorder->mutex);
    recorder->block_next_packet = true;
    pthread_mutex_unlock(&recorder->mutex);
}

static void wait_for_blocked_input_packet(InputPacketRecorder *recorder) {
    struct timespec deadline = input_test_deadline();
    pthread_mutex_lock(&recorder->mutex);
    while (!recorder->packet_blocked) {
        int result = pthread_cond_timedwait(&recorder->condition, &recorder->mutex, &deadline);
        assert(result == 0 || result == EINTR);
    }
    pthread_mutex_unlock(&recorder->mutex);
}

static void release_blocked_input_packet(InputPacketRecorder *recorder) {
    pthread_mutex_lock(&recorder->mutex);
    recorder->release_blocked_packet = true;
    pthread_cond_broadcast(&recorder->condition);
    pthread_mutex_unlock(&recorder->mutex);
}

static uint32_t recorded_input_magic(const InputPacketRecord *record) {
    assert(record->length >= (int)sizeof(NV_INPUT_HEADER));
    return (uint32_t)record->bytes[4] |
        ((uint32_t)record->bytes[5] << 8) |
        ((uint32_t)record->bytes[6] << 16) |
        ((uint32_t)record->bytes[7] << 24);
}

static int16_t recorded_big_endian_i16(const InputPacketRecord *record, int offset) {
    assert(offset >= 0);
    assert(offset + 2 <= record->length);
    uint16_t value = ((uint16_t)record->bytes[offset] << 8) |
        (uint16_t)record->bytes[offset + 1];
    return (int16_t)value;
}

static float recorded_little_endian_float(const InputPacketRecord *record, int offset) {
    assert(offset >= 0);
    assert(offset + (int)sizeof(float) <= record->length);
    uint32_t bits = (uint32_t)record->bytes[offset] |
        ((uint32_t)record->bytes[offset + 1] << 8) |
        ((uint32_t)record->bytes[offset + 2] << 16) |
        ((uint32_t)record->bytes[offset + 3] << 24);
    float value;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

static atomic_int video_queue_recovery_calls;
static atomic_bool video_queue_recovery_was_rfi;

static size_t count_occurrences(const char *value, const char *needle) {
    size_t count = 0;
    size_t needle_length = strlen(needle);
    const char *cursor = value;
    while ((cursor = strstr(cursor, needle)) != NULL) {
        count++;
        cursor += needle_length;
    }
    return count;
}

static void *produce_queue_count_items(void *opaque) {
    QueueCountRace *race = opaque;
    for (int index = 0; index < QUEUE_COUNT_RACE_ITEMS; index++) {
        int result;
        do {
            result = LbqOfferQueueItem(
                &race->queue,
                &race->entries[index],
                &race->entries[index]
            );
            if (result == LBQ_BOUND_EXCEEDED) {
                sched_yield();
            }
        } while (result == LBQ_BOUND_EXCEEDED);
        if (result != LBQ_SUCCESS) {
            atomic_store_explicit(&race->failed, true, memory_order_release);
            return NULL;
        }
        atomic_fetch_add_explicit(&race->produced, 1, memory_order_release);
    }
    return NULL;
}

static void *consume_queue_count_items(void *opaque) {
    QueueCountRace *race = opaque;
    for (int index = 0; index < QUEUE_COUNT_RACE_ITEMS;) {
        void *item = NULL;
        int result = LbqPollQueueElement(&race->queue, &item);
        if (result == LBQ_NO_ELEMENT) {
            sched_yield();
            continue;
        }
        if (result != LBQ_SUCCESS || item != &race->entries[index]) {
            atomic_store_explicit(&race->failed, true, memory_order_release);
            return NULL;
        }
        index++;
        atomic_fetch_add_explicit(&race->consumed, 1, memory_order_release);
    }
    return NULL;
}

static void record_video_queue_recovery(bool reference_frame_invalidation) {
    atomic_fetch_add_explicit(&video_queue_recovery_calls, 1, memory_order_relaxed);
    atomic_store_explicit(
        &video_queue_recovery_was_rfi,
        reference_frame_invalidation,
        memory_order_relaxed
    );
}

static void *send_keyboard_on_thread(void *opaque) {
    InputTeardownRace *race = opaque;
    race->input_result = umbra_stream_session_send_keyboard(
        race->session,
        (int16_t)0x8041,
        3,
        0,
        0
    );
    return NULL;
}

static void *destroy_session_on_thread(void *opaque) {
    InputTeardownRace *race = opaque;
    race->destroy_result = umbra_stream_session_destroy(race->session);
    atomic_store_explicit(&race->destroy_finished, true, memory_order_release);
    return NULL;
}

static void *send_prepared_video_on_thread(void *opaque) {
    PreparedVideoTeardownRace *race = opaque;
    race->video_result = umbra_stream_test_video_frame(race->session, &race->frame, 3);
    return NULL;
}

static void *destroy_session_during_prepared_video(void *opaque) {
    PreparedVideoTeardownRace *race = opaque;
    race->destroy_result = umbra_stream_session_destroy(race->session);
    atomic_store_explicit(&race->destroy_finished, true, memory_order_release);
    return NULL;
}

static void record_event(void *context, const UmbraStreamEvent *event) {
    CallbackRecord *record = context;
    record->event_calls++;
    record->event = *event;
    if (event->message != NULL) {
        snprintf(record->message, sizeof(record->message), "%s", event->message);
    }
}

static int32_t record_video_setup(void *context, const UmbraVideoFormat *format) {
    CallbackRecord *record = context;
    record->video_setup_calls++;
    record->video_format = *format;
    return record->video_setup_result;
}

static void record_video_start(void *context) {
    ((CallbackRecord *)context)->video_start_calls++;
}

static void record_video_stop(void *context) {
    ((CallbackRecord *)context)->video_stop_calls++;
}

static void record_video_cleanup(void *context) {
    ((CallbackRecord *)context)->video_cleanup_calls++;
}

static int32_t record_video_frame(void *context, UmbraVideoFrame *frame) {
    CallbackRecord *record = context;
    record->video_frame_calls++;
    record->video_frame = *frame;
    assert(frame->data != record->video_source);
    assert(frame->length <= sizeof(record->video_data));
    memcpy(record->video_data, frame->data, frame->length);
    if (record->take_video_data) {
        record->owned_video_length = frame->length;
        record->owned_video_data = umbra_video_frame_take_data(frame);
        assert(record->owned_video_data != NULL);
        assert(frame->data == NULL);
        assert(frame->length == 0);
    }
    return record->video_frame_result;
}

static int32_t record_prepared_video_frame(void *context, UmbraPreparedVideoFrame *frame) {
    CallbackRecord *record = context;
    record->prepared_video_frame_calls++;
    record->prepared_video_frame = *frame;
    assert(frame->abi_version == UMBRA_PREPARED_VIDEO_FRAME_ABI_VERSION);
    if (!record->skip_prepared_copy) {
        assert(frame->length <= sizeof(record->prepared_video_data));
        memcpy(record->prepared_video_data, frame->data, frame->length);
    }
    if (record->take_prepared_data) {
        record->owned_prepared_length = frame->length;
        record->owned_prepared_data = umbra_prepared_video_frame_take_data(frame);
        assert(record->owned_prepared_data != NULL);
        assert(frame->data == NULL);
        assert(frame->length == 0);
    }
    if (record->block_prepared_callback) {
        pthread_mutex_lock(&record->prepared_callback_mutex);
        record->prepared_callback_waiting = true;
        pthread_cond_broadcast(&record->prepared_callback_condition);
        while (record->block_prepared_callback) {
            pthread_cond_wait(&record->prepared_callback_condition, &record->prepared_callback_mutex);
        }
        pthread_mutex_unlock(&record->prepared_callback_mutex);
    }
    return record->video_frame_result;
}

static int32_t record_audio_init(void *context, const UmbraAudioFormat *format) {
    CallbackRecord *record = context;
    record->audio_init_calls++;
    record->audio_format = *format;
    return record->audio_init_result;
}

static void record_audio_start(void *context) {
    ((CallbackRecord *)context)->audio_start_calls++;
}

static void record_audio_stop(void *context) {
    ((CallbackRecord *)context)->audio_stop_calls++;
}

static void record_audio_cleanup(void *context) {
    ((CallbackRecord *)context)->audio_cleanup_calls++;
}

static void record_audio_packet(void *context, const UmbraAudioPacket *packet) {
    CallbackRecord *record = context;
    record->audio_packet_calls++;
    assert(packet->length <= sizeof(record->audio_data));
    record->audio_length = packet->length;
    if (packet->length > 0) {
        assert(packet->data != NULL);
        memcpy(record->audio_data, packet->data, packet->length);
    }
}

static UmbraStreamSession *create_callback_session_with_configuration(
    CallbackRecord *record,
    const UmbraStreamConfiguration *configuration
) {
    UmbraStreamCallbacks callbacks = {0};
    callbacks.context = record;
    callbacks.event = record_event;
    callbacks.video_setup = record_video_setup;
    callbacks.video_start = record_video_start;
    callbacks.video_stop = record_video_stop;
    callbacks.video_cleanup = record_video_cleanup;
    callbacks.video_frame = record_video_frame;
    callbacks.audio_init = record_audio_init;
    callbacks.audio_start = record_audio_start;
    callbacks.audio_stop = record_audio_stop;
    callbacks.audio_cleanup = record_audio_cleanup;
    callbacks.audio_packet = record_audio_packet;
    int32_t result = 0;
    UmbraStreamSession *session = umbra_stream_session_create(configuration, &callbacks, &result);
    assert(session != NULL);
    assert(result == UMBRA_STREAM_OK);
    return session;
}

static UmbraStreamSession *create_callback_session(CallbackRecord *record) {
    UmbraStreamConfiguration configuration = valid_configuration();
    return create_callback_session_with_configuration(record, &configuration);
}

static UmbraStreamSession *create_prepared_callback_session(CallbackRecord *record, int32_t format) {
    UmbraStreamSession *session = create_callback_session(record);
    assert(umbra_stream_session_set_prepared_video_callback(session, record_prepared_video_frame) == 0);
    UmbraVideoFormat video_format = {
        .format = format,
        .width = 1920,
        .height = 1080,
        .redraw_rate = 120
    };
    assert(umbra_stream_test_video_setup(session, &video_format) == 0);
    return session;
}

static void test_configuration_defaults_and_validation(void) {
    UmbraStreamConfiguration configuration = valid_configuration();
    assert(UMBRA_STREAM_OPTIMIZATION_MODE_LEGACY == 0);
    assert(UMBRA_STREAM_OPTIMIZATION_MODE_LATENCY == 1);
    assert(UMBRA_STREAM_OPTIMIZATION_MODE_QUALITY == 2);
    assert(configuration.width == 1920);
    assert(configuration.height == 1080);
    assert(configuration.fps == 60);
    assert(configuration.packet_size == 1392);
    assert(configuration.client_refresh_rate_x100 == 0);
    assert(configuration.video_decode_queue_capacity == UMBRA_VIDEO_DECODE_QUEUE_CAPACITY_DEFAULT);
    assert(configuration.rtsp_optimization_mode == UMBRA_STREAM_OPTIMIZATION_MODE_LEGACY);
    assert(configuration.input_optimization_mode == UMBRA_STREAM_OPTIMIZATION_MODE_LEGACY);
    assert(configuration.color_space == UMBRA_STREAM_COLORSPACE_REC_601);
    assert(!configuration.client_microphone_requested);
    assert(configuration.client_microphone_client_port == 0);
    assert(umbra_stream_configuration_validate(&configuration) == UMBRA_STREAM_OK);

    configuration.width = 0;
    assert(umbra_stream_configuration_validate(&configuration) == UMBRA_STREAM_ERROR_INVALID_ARGUMENT);
    configuration = valid_configuration();
    configuration.address = "";
    assert(umbra_stream_configuration_validate(&configuration) == UMBRA_STREAM_ERROR_INVALID_ARGUMENT);
    configuration = valid_configuration();
    configuration.client_refresh_rate_x100 = -1;
    assert(umbra_stream_configuration_validate(&configuration) == UMBRA_STREAM_ERROR_INVALID_ARGUMENT);
    configuration = valid_configuration();
    configuration.client_microphone_requested = true;
    assert(umbra_stream_configuration_validate(&configuration) == UMBRA_STREAM_ERROR_INVALID_ARGUMENT);
    configuration.client_microphone_client_port = 65535;
    assert(umbra_stream_configuration_validate(&configuration) == UMBRA_STREAM_ERROR_INVALID_ARGUMENT);
    configuration.client_microphone_client_port = 55000;
    assert(umbra_stream_configuration_validate(&configuration) == UMBRA_STREAM_OK);
    configuration.rtsp_optimization_mode = (UmbraStreamOptimizationMode)-1;
    assert(umbra_stream_configuration_validate(&configuration) == UMBRA_STREAM_ERROR_INVALID_ARGUMENT);
    configuration = valid_configuration();
    configuration.rtsp_optimization_mode = (UmbraStreamOptimizationMode)3;
    assert(umbra_stream_configuration_validate(&configuration) == UMBRA_STREAM_ERROR_INVALID_ARGUMENT);
    configuration = valid_configuration();
    configuration.input_optimization_mode = (UmbraStreamOptimizationMode)-1;
    assert(umbra_stream_configuration_validate(&configuration) == UMBRA_STREAM_ERROR_INVALID_ARGUMENT);
    configuration = valid_configuration();
    configuration.input_optimization_mode = (UmbraStreamOptimizationMode)3;
    assert(umbra_stream_configuration_validate(&configuration) == UMBRA_STREAM_ERROR_INVALID_ARGUMENT);
    configuration = valid_configuration();
    configuration.rtsp_fidelity_mode = UMBRA_STREAM_FIDELITY_CODEC_LOSSLESS_REQUIRED;
    assert(umbra_stream_configuration_validate(&configuration) == UMBRA_STREAM_ERROR_INVALID_ARGUMENT);
    configuration.rtsp_optimization_mode = UMBRA_STREAM_OPTIMIZATION_MODE_QUALITY;
    assert(umbra_stream_configuration_validate(&configuration) == UMBRA_STREAM_OK);
    assert(umbra_stream_configuration_validate(NULL) == UMBRA_STREAM_ERROR_INVALID_ARGUMENT);
}

static void test_optimization_mode_announce_is_exact_bounded_and_isolated(void) {
    static const char base_payload[] = "v=0\r\na=x-nv-video[0].maxFPS:120\r\n";
    static const char prefix[] = "a=x-lumen-optimization-mode:";
    static const char latency_attribute[] = "a=x-lumen-optimization-mode:latency\r\n";
    static const char quality_attribute[] = "a=x-lumen-optimization-mode:quality\r\n";
    static const char client_prefix[] = "a=x-umbra-client-protocol:";
    static const char client_attribute[] = "a=x-umbra-client-protocol:legacy-v1\r\n";

    assert(umbra_optimization_mode_rtsp_test_current() == UMBRA_STREAM_OPTIMIZATION_MODE_LEGACY);
    char *legacy_payload = strdup(base_payload);
    assert(legacy_payload != NULL);
    int legacy_length = (int)strlen(legacy_payload);
    assert(umbra_optimization_mode_rtsp_append_announce(&legacy_payload, &legacy_length));
    assert((size_t)legacy_length == strlen(base_payload));
    assert(strcmp(legacy_payload, base_payload) == 0);
    assert(count_occurrences(legacy_payload, client_prefix) == 0);
    free(legacy_payload);

    assert(umbra_optimization_mode_rtsp_configure(UMBRA_STREAM_OPTIMIZATION_MODE_LATENCY));
    char *latency_payload = strdup(base_payload);
    assert(latency_payload != NULL);
    int latency_length = (int)strlen(latency_payload);
    assert(umbra_optimization_mode_rtsp_append_announce(&latency_payload, &latency_length));
    assert((size_t)latency_length == strlen(base_payload) + strlen(client_attribute) + strlen(latency_attribute));
    assert(strncmp(latency_payload + strlen(base_payload), client_attribute, strlen(client_attribute)) == 0);
    assert(strcmp(latency_payload + strlen(base_payload) + strlen(client_attribute), latency_attribute) == 0);
    assert(count_occurrences(latency_payload, prefix) == 1);
    assert(count_occurrences(latency_payload, client_prefix) == 1);
    int exact_latency_length = latency_length;
    assert(!umbra_optimization_mode_rtsp_append_announce(&latency_payload, &latency_length));
    assert(latency_length == exact_latency_length);
    assert(count_occurrences(latency_payload, prefix) == 1);
    free(latency_payload);

    assert(umbra_optimization_mode_rtsp_configure(UMBRA_STREAM_OPTIMIZATION_MODE_QUALITY));
    char *quality_payload = strdup(base_payload);
    assert(quality_payload != NULL);
    int quality_length = (int)strlen(quality_payload);
    assert(umbra_optimization_mode_rtsp_append_announce(&quality_payload, &quality_length));
    assert(strncmp(quality_payload + strlen(base_payload), client_attribute, strlen(client_attribute)) == 0);
    assert(strcmp(quality_payload + strlen(base_payload) + strlen(client_attribute), quality_attribute) == 0);
    assert(count_occurrences(quality_payload, prefix) == 1);
    free(quality_payload);

    assert(umbra_video_fidelity_rtsp_configure(UMBRA_STREAM_FIDELITY_CODEC_LOSSLESS_REQUIRED));
    char *lossless_payload = strdup(base_payload);
    assert(lossless_payload != NULL);
    int lossless_length = (int)strlen(lossless_payload);
    assert(umbra_optimization_mode_rtsp_append_announce(&lossless_payload, &lossless_length));
    assert(strstr(lossless_payload, "a=x-lumen-optimization-mode:quality\r\n") != NULL);
    assert(strstr(lossless_payload, "a=x-lumen-video-fidelity:codec-lossless-required\r\n") != NULL);
    free(lossless_payload);

    char *bounded_payload = strdup(base_payload);
    assert(bounded_payload != NULL);
    int oversized_length = INT_MAX;
    assert(!umbra_optimization_mode_rtsp_append_announce(&bounded_payload, &oversized_length));
    assert(oversized_length == INT_MAX);
    assert(strcmp(bounded_payload, base_payload) == 0);
    assert(!umbra_optimization_mode_rtsp_append_announce(NULL, &quality_length));
    assert(!umbra_optimization_mode_rtsp_append_announce(&bounded_payload, NULL));
    free(bounded_payload);

    assert(!umbra_optimization_mode_rtsp_configure((UmbraStreamOptimizationMode)99));
    assert(umbra_optimization_mode_rtsp_test_current() == UMBRA_STREAM_OPTIMIZATION_MODE_LEGACY);
    umbra_optimization_mode_rtsp_clear();
    assert(umbra_optimization_mode_rtsp_test_current() == UMBRA_STREAM_OPTIMIZATION_MODE_LEGACY);
}

static void test_optimization_mode_is_snapshotted_into_moonlight_stream_configuration(void) {
    assert(UMBRA_STREAM_OPTIMIZATION_MODE_LEGACY == STREAM_OPTIMIZATION_MODE_LEGACY);
    assert(UMBRA_STREAM_OPTIMIZATION_MODE_LATENCY == STREAM_OPTIMIZATION_MODE_LATENCY);
    assert(UMBRA_STREAM_OPTIMIZATION_MODE_QUALITY == STREAM_OPTIMIZATION_MODE_QUALITY);

    const UmbraStreamOptimizationMode modes[] = {
        UMBRA_STREAM_OPTIMIZATION_MODE_LEGACY,
        UMBRA_STREAM_OPTIMIZATION_MODE_LATENCY,
        UMBRA_STREAM_OPTIMIZATION_MODE_QUALITY,
    };
    for (size_t index = 0; index < sizeof(modes) / sizeof(modes[0]); index++) {
        UmbraStreamConfiguration configuration = valid_configuration();
        configuration.input_optimization_mode = modes[index];
        configuration.rtsp_optimization_mode = modes[
            (sizeof(modes) / sizeof(modes[0]) - 1) - index
        ];
        int32_t result = 0;
        UmbraStreamSession *session = umbra_stream_session_create(&configuration, NULL, &result);
        assert(session != NULL);
        assert(result == UMBRA_STREAM_OK);
        assert(umbra_stream_test_input_optimization_mode(session) == (int32_t)modes[index]);
        assert(umbra_stream_test_rtsp_optimization_mode(session) ==
            (int32_t)configuration.rtsp_optimization_mode);
        assert(umbra_stream_session_destroy(session) == UMBRA_STREAM_OK);
    }

    UmbraStreamConfiguration nvidia = valid_configuration();
    nvidia.input_optimization_mode = UMBRA_STREAM_OPTIMIZATION_MODE_LATENCY;
    nvidia.rtsp_optimization_mode = UMBRA_STREAM_OPTIMIZATION_MODE_LEGACY;
    int32_t result = 0;
    UmbraStreamSession *session = umbra_stream_session_create(&nvidia, NULL, &result);
    assert(session != NULL);
    assert(result == UMBRA_STREAM_OK);
    assert(umbra_stream_test_input_optimization_mode(session) == STREAM_OPTIMIZATION_MODE_LATENCY);
    assert(umbra_stream_test_rtsp_optimization_mode(session) == UMBRA_STREAM_OPTIMIZATION_MODE_LEGACY);
    assert(umbra_stream_session_destroy(session) == UMBRA_STREAM_OK);
}

static void test_split_modes_keep_nvidia_announce_legacy_and_lumen_both_active(void) {
    static const char base_payload[] = "v=0\r\na=x-nv-video[0].maxFPS:120\r\n";
    static const char latency_attribute[] = "a=x-lumen-optimization-mode:latency\r\n";
    static const char client_attribute[] = "a=x-umbra-client-protocol:legacy-v1\r\n";

    UmbraStreamConfiguration nvidia = valid_configuration();
    nvidia.input_optimization_mode = UMBRA_STREAM_OPTIMIZATION_MODE_LATENCY;
    nvidia.rtsp_optimization_mode = UMBRA_STREAM_OPTIMIZATION_MODE_LEGACY;
    int32_t result = 0;
    UmbraStreamSession *nvidia_session = umbra_stream_session_create(&nvidia, NULL, &result);
    assert(nvidia_session != NULL);
    assert(result == UMBRA_STREAM_OK);
    assert(umbra_stream_test_input_optimization_mode(nvidia_session) == STREAM_OPTIMIZATION_MODE_LATENCY);
    assert(umbra_optimization_mode_rtsp_configure(
        (UmbraStreamOptimizationMode)umbra_stream_test_rtsp_optimization_mode(nvidia_session)
    ));
    char *nvidia_payload = strdup(base_payload);
    assert(nvidia_payload != NULL);
    int nvidia_length = (int)strlen(nvidia_payload);
    assert(umbra_optimization_mode_rtsp_append_announce(&nvidia_payload, &nvidia_length));
    assert(nvidia_length == (int)strlen(base_payload));
    assert(strcmp(nvidia_payload, base_payload) == 0);
    free(nvidia_payload);
    umbra_optimization_mode_rtsp_clear();
    assert(umbra_stream_session_destroy(nvidia_session) == UMBRA_STREAM_OK);

    UmbraStreamConfiguration lumen = valid_configuration();
    lumen.input_optimization_mode = UMBRA_STREAM_OPTIMIZATION_MODE_LATENCY;
    lumen.rtsp_optimization_mode = UMBRA_STREAM_OPTIMIZATION_MODE_LATENCY;
    UmbraStreamSession *lumen_session = umbra_stream_session_create(&lumen, NULL, &result);
    assert(lumen_session != NULL);
    assert(result == UMBRA_STREAM_OK);
    assert(umbra_stream_test_input_optimization_mode(lumen_session) == STREAM_OPTIMIZATION_MODE_LATENCY);
    assert(umbra_optimization_mode_rtsp_configure(
        (UmbraStreamOptimizationMode)umbra_stream_test_rtsp_optimization_mode(lumen_session)
    ));
    char *lumen_payload = strdup(base_payload);
    assert(lumen_payload != NULL);
    int lumen_length = (int)strlen(lumen_payload);
    assert(umbra_optimization_mode_rtsp_append_announce(&lumen_payload, &lumen_length));
    assert(lumen_length == (int)(strlen(base_payload) + strlen(client_attribute) + strlen(latency_attribute)));
    assert(memcmp(lumen_payload, base_payload, strlen(base_payload)) == 0);
    assert(strncmp(lumen_payload + strlen(base_payload), client_attribute, strlen(client_attribute)) == 0);
    assert(strcmp(lumen_payload + strlen(base_payload) + strlen(client_attribute), latency_attribute) == 0);
    free(lumen_payload);
    umbra_optimization_mode_rtsp_clear();
    assert(umbra_stream_session_destroy(lumen_session) == UMBRA_STREAM_OK);
}

static void test_input_batching_delay_is_mode_isolated_and_latency_has_no_sleep(void) {
    for (int repetition = 0; repetition < 1000; repetition++) {
        assert(LiTestGetInputBatchingDelayMs(
            STREAM_OPTIMIZATION_MODE_LEGACY,
            100,
            100,
            1
        ) == 1);
        assert(LiTestGetInputBatchingDelayMs(
            STREAM_OPTIMIZATION_MODE_QUALITY,
            100,
            100,
            1
        ) == 1);
        assert(LiTestGetInputBatchingDelayMs(
            STREAM_OPTIMIZATION_MODE_LATENCY,
            100,
            100,
            1
        ) == 0);
    }

    assert(LiTestGetInputBatchingDelayMs(
        STREAM_OPTIMIZATION_MODE_LATENCY,
        99,
        100,
        1
    ) == 0);
    assert(LiTestGetInputBatchingDelayMs(
        STREAM_OPTIMIZATION_MODE_LEGACY,
        101,
        100,
        1
    ) == 0);
    assert(LiTestGetInputBatchingDelayMs(
        STREAM_OPTIMIZATION_MODE_QUALITY,
        100,
        100,
        0
    ) == 0);
}

static void run_input_wire_identity_script(int optimization_mode, InputPacketRecorder *recorder) {
    assert(LiTestInitializeInputStream(optimization_mode, record_input_packet, recorder) == 0);
    assert(LiTestStartInputStream() == 0);
    wait_for_input_packets(recorder, 1);

    assert(LiSendMouseMoveEvent(17, -23) == 0);
    wait_for_input_packets(recorder, 2);
    assert(LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_LEFT) == 0);
    wait_for_input_packets(recorder, 3);
    assert(LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT) == 0);
    wait_for_input_packets(recorder, 4);
    assert(LiSendKeyboardEvent(0x41, KEY_ACTION_DOWN, 0) == 0);
    wait_for_input_packets(recorder, 5);
    assert(LiSendKeyboardEvent(0x41, KEY_ACTION_UP, 0) == 0);
    wait_for_input_packets(recorder, 6);

    LiTestDestroyInputStream();
}

static void test_legacy_and_quality_input_wire_packets_are_byte_for_byte_identical(void) {
    InputPacketRecorder legacy;
    InputPacketRecorder quality;
    initialize_input_packet_recorder(&legacy);
    initialize_input_packet_recorder(&quality);

    run_input_wire_identity_script(STREAM_OPTIMIZATION_MODE_LEGACY, &legacy);
    run_input_wire_identity_script(STREAM_OPTIMIZATION_MODE_QUALITY, &quality);

    assert(legacy.packet_count == quality.packet_count);
    for (int index = 0; index < legacy.packet_count; index++) {
        const InputPacketRecord *legacy_packet = &legacy.packets[index];
        const InputPacketRecord *quality_packet = &quality.packets[index];
        assert(legacy_packet->length == quality_packet->length);
        assert(legacy_packet->channel_id == quality_packet->channel_id);
        assert(legacy_packet->flags == quality_packet->flags);
        assert(memcmp(
            legacy_packet->bytes,
            quality_packet->bytes,
            (size_t)legacy_packet->length
        ) == 0);
    }

    destroy_input_packet_recorder(&legacy);
    destroy_input_packet_recorder(&quality);
}

static void test_latency_input_preserves_coalescing_edges_order_and_queue_pressure(void) {
    InputPacketRecorder recorder;
    initialize_input_packet_recorder(&recorder);
    assert(LiTestInitializeInputStream(
        STREAM_OPTIMIZATION_MODE_LATENCY,
        record_input_packet,
        &recorder
    ) == 0);
    assert(LiTestStartInputStream() == 0);
    wait_for_input_packets(&recorder, 1);

    block_next_input_packet(&recorder);
    assert(LiSendMouseMoveEvent(1, 2) == 0);
    wait_for_blocked_input_packet(&recorder);

    for (int index = 0; index < 100; index++) {
        assert(LiSendMouseMoveEvent(1, -1) == 0);
    }
    assert(LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_LEFT) == 0);
    assert(LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT) == 0);

    int queue_capacity = LiTestGetInputQueueCapacity();
    assert(queue_capacity == 150);
    int keyboard_packet_count = queue_capacity - 2;
    for (int index = 0; index < keyboard_packet_count; index++) {
        char action = (index & 1) == 0 ? KEY_ACTION_DOWN : KEY_ACTION_UP;
        assert(LiSendKeyboardEvent((short)(0x30 + (index % 10)), action, 0) == 0);
    }
    assert(LiSendKeyboardEvent(0x5A, KEY_ACTION_DOWN, 0) == LBQ_BOUND_EXCEEDED);

    release_blocked_input_packet(&recorder);
    LiTestDestroyInputStream();

    int expected_packet_count = 1 + 2 + 2 + keyboard_packet_count;
    assert(recorder.packet_count == expected_packet_count);
    assert(recorded_input_magic(&recorder.packets[1]) == MOUSE_MOVE_REL_MAGIC_GEN5);
    assert(recorded_big_endian_i16(&recorder.packets[1], 8) == 1);
    assert(recorded_big_endian_i16(&recorder.packets[1], 10) == 2);
    assert(recorded_input_magic(&recorder.packets[2]) == MOUSE_MOVE_REL_MAGIC_GEN5);
    assert(recorded_big_endian_i16(&recorder.packets[2], 8) == 100);
    assert(recorded_big_endian_i16(&recorder.packets[2], 10) == -100);
    assert(recorded_input_magic(&recorder.packets[3]) == MOUSE_BUTTON_DOWN_EVENT_MAGIC_GEN5);
    assert(recorded_input_magic(&recorder.packets[4]) == MOUSE_BUTTON_UP_EVENT_MAGIC_GEN5);

    for (int index = 1; index < recorder.packet_count; index++) {
        assert(recorder.packets[index].flags == TEST_ENET_PACKET_FLAG_RELIABLE);
    }
    for (int index = 0; index < keyboard_packet_count; index++) {
        uint32_t expected_magic = (index & 1) == 0
            ? KEY_DOWN_EVENT_MAGIC
            : KEY_UP_EVENT_MAGIC;
        assert(recorded_input_magic(&recorder.packets[5 + index]) == expected_magic);
    }
    assert(recorded_input_magic(&recorder.packets[recorder.packet_count - 1]) == KEY_UP_EVENT_MAGIC);

    destroy_input_packet_recorder(&recorder);
}

static void test_input_lifecycle_reset_restores_neutral_coalescing_and_pen_state(void) {
    InputPacketRecorder first;
    InputPacketRecorder second;
    initialize_input_packet_recorder(&first);
    initialize_input_packet_recorder(&second);

    assert(LiTestInitializeInputStream(
        STREAM_OPTIMIZATION_MODE_LATENCY,
        record_input_packet,
        &first
    ) == 0);
    assert(LiTestStartInputStream() == 0);
    wait_for_input_packets(&first, 1);
    assert(LiSendMouseMoveEvent(300, -400) == 0);
    wait_for_input_packets(&first, 2);
    assert(LiSendPenEvent(
        LI_TOUCH_EVENT_MOVE,
        LI_TOOL_TYPE_PEN,
        LI_PEN_BUTTON_PRIMARY,
        0.25f,
        0.5f,
        1.0f,
        0.0f,
        0.0f,
        LI_ROT_UNKNOWN,
        LI_TILT_UNKNOWN
    ) == 0);
    wait_for_input_packets(&first, 3);
    assert(first.packets[2].flags == TEST_ENET_PACKET_FLAG_RELIABLE);
    LiTestDestroyInputStream();

    assert(LiTestInitializeInputStream(
        STREAM_OPTIMIZATION_MODE_LATENCY,
        record_input_packet,
        &second
    ) == 0);
    assert(LiTestStartInputStream() == 0);
    wait_for_input_packets(&second, 1);
    assert(LiSendMouseMoveEvent(1, 2) == 0);
    wait_for_input_packets(&second, 2);
    assert(recorded_big_endian_i16(&second.packets[1], 8) == 1);
    assert(recorded_big_endian_i16(&second.packets[1], 10) == 2);
    assert(LiSendPenEvent(
        LI_TOUCH_EVENT_MOVE,
        LI_TOOL_TYPE_PEN,
        LI_PEN_BUTTON_PRIMARY,
        0.25f,
        0.5f,
        1.0f,
        0.0f,
        0.0f,
        LI_ROT_UNKNOWN,
        LI_TILT_UNKNOWN
    ) == 0);
    wait_for_input_packets(&second, 3);
    assert(second.packets[2].flags == TEST_ENET_PACKET_FLAG_RELIABLE);
    LiTestDestroyInputStream();

    destroy_input_packet_recorder(&first);
    destroy_input_packet_recorder(&second);
}

static void test_latency_pen_coalescing_keeps_latest_state_before_reliable_release(void) {
    InputPacketRecorder recorder;
    initialize_input_packet_recorder(&recorder);
    assert(LiTestInitializeInputStream(
        STREAM_OPTIMIZATION_MODE_LATENCY,
        record_input_packet,
        &recorder
    ) == 0);
    assert(LiTestStartInputStream() == 0);
    wait_for_input_packets(&recorder, 1);

    block_next_input_packet(&recorder);
    assert(LiSendPenEvent(
        LI_TOUCH_EVENT_MOVE,
        LI_TOOL_TYPE_PEN,
        0,
        0.0f,
        0.5f,
        1.0f,
        0.0f,
        0.0f,
        LI_ROT_UNKNOWN,
        LI_TILT_UNKNOWN
    ) == 0);
    wait_for_blocked_input_packet(&recorder);

    for (int index = 1; index <= 64; index++) {
        assert(LiSendPenEvent(
            LI_TOUCH_EVENT_MOVE,
            LI_TOOL_TYPE_PEN,
            0,
            (float)index / 64.0f,
            0.5f,
            1.0f,
            0.0f,
            0.0f,
            LI_ROT_UNKNOWN,
            LI_TILT_UNKNOWN
        ) == 0);
    }
    assert(LiSendPenEvent(
        LI_TOUCH_EVENT_UP,
        LI_TOOL_TYPE_PEN,
        0,
        1.0f,
        0.5f,
        0.0f,
        0.0f,
        0.0f,
        LI_ROT_UNKNOWN,
        LI_TILT_UNKNOWN
    ) == 0);

    release_blocked_input_packet(&recorder);
    LiTestDestroyInputStream();

    assert(recorder.packet_count == 4);
    assert(recorded_input_magic(&recorder.packets[1]) == SS_PEN_MAGIC);
    assert(recorded_input_magic(&recorder.packets[2]) == SS_PEN_MAGIC);
    assert(recorded_input_magic(&recorder.packets[3]) == SS_PEN_MAGIC);
    assert(recorder.packets[1].bytes[8] == LI_TOUCH_EVENT_MOVE);
    assert(recorder.packets[2].bytes[8] == LI_TOUCH_EVENT_MOVE);
    assert(recorder.packets[3].bytes[8] == LI_TOUCH_EVENT_UP);
    assert(recorded_little_endian_float(&recorder.packets[2], 12) == 1.0f);
    assert(recorder.packets[1].flags == 0);
    assert(recorder.packets[2].flags == 0);
    assert(recorder.packets[3].flags == TEST_ENET_PACKET_FLAG_RELIABLE);

    destroy_input_packet_recorder(&recorder);
}

static void test_failed_start_clears_scoped_optimization_mode(void) {
    CallbackRecord record = {0};
    UmbraStreamConfiguration configuration = valid_configuration();
    configuration.address = "umbra-start-failure.invalid";
    configuration.server_codec_mode_support = UMBRA_VIDEO_FORMAT_H264;
    configuration.rtsp_optimization_mode = UMBRA_STREAM_OPTIMIZATION_MODE_LATENCY;
    UmbraStreamSession *session = create_callback_session_with_configuration(&record, &configuration);

    assert(umbra_stream_session_start(session) != UMBRA_STREAM_OK);
    assert(umbra_stream_session_state(session) == UMBRA_STREAM_STATE_IDLE);
    assert(umbra_optimization_mode_rtsp_test_current() == UMBRA_STREAM_OPTIMIZATION_MODE_LEGACY);
    assert(umbra_stream_session_destroy(session) == UMBRA_STREAM_OK);
}

static void test_video_decode_queue_capacity_is_clamped_and_direct_submit_stays_disabled(void) {
    UmbraStreamConfiguration configuration = valid_configuration();
    int32_t result = 0;
    const int32_t reference_frame_capabilities =
        UMBRA_RENDER_CAPABILITY_REFERENCE_FRAME_INVALIDATION_HEVC |
        UMBRA_RENDER_CAPABILITY_REFERENCE_FRAME_INVALIDATION_AV1;

    configuration.video_decode_queue_capacity = -7;
    configuration.video_capabilities = reference_frame_capabilities;
    UmbraStreamSession *session = umbra_stream_session_create(&configuration, NULL, &result);
    assert(session != NULL);
    assert(result == UMBRA_STREAM_OK);
    assert(umbra_stream_test_video_decode_queue_capacity(session) == UMBRA_VIDEO_DECODE_QUEUE_CAPACITY_MIN);
    assert(umbra_stream_test_video_capabilities(session) == reference_frame_capabilities);
    assert((umbra_stream_test_video_capabilities(session) & UMBRA_RENDER_CAPABILITY_DIRECT_SUBMIT) == 0);
    assert(umbra_stream_session_destroy(session) == UMBRA_STREAM_OK);

    configuration = valid_configuration();
    configuration.video_decode_queue_capacity = 99;
    session = umbra_stream_session_create(&configuration, NULL, &result);
    assert(session != NULL);
    assert(result == UMBRA_STREAM_OK);
    assert(umbra_stream_test_video_decode_queue_capacity(session) == UMBRA_VIDEO_DECODE_QUEUE_CAPACITY_MAX);
    assert(umbra_stream_session_destroy(session) == UMBRA_STREAM_OK);
}

static void test_video_decode_queue_overflow_uses_actual_depacketizer_recovery(void) {
    UmbraStreamConfiguration configuration = valid_configuration();
    configuration.video_decode_queue_capacity = 1;
    int32_t result = 0;
    UmbraStreamSession *session = umbra_stream_session_create(&configuration, NULL, &result);
    assert(session != NULL);
    assert(result == UMBRA_STREAM_OK);

    atomic_store_explicit(&video_queue_recovery_calls, 0, memory_order_relaxed);
    atomic_store_explicit(&video_queue_recovery_was_rfi, false, memory_order_relaxed);
    LiTestInitializeVideoDecodeQueue(
        umbra_stream_test_video_decode_queue_capacity(session),
        record_video_queue_recovery
    );

    assert(LiGetVideoDecodeQueueCapacity() == 1);
    assert(LiGetPendingVideoFrames() == 0);
    assert(LiTestOfferCompleteVideoDecodeUnit(1));
    assert(LiGetPendingVideoFrames() == 1);
    assert(!LiTestOfferCompleteVideoDecodeUnit(2));
    assert(LiGetPendingVideoFrames() == 0);
    assert(atomic_load_explicit(&video_queue_recovery_calls, memory_order_relaxed) == 1);
    assert(!atomic_load_explicit(&video_queue_recovery_was_rfi, memory_order_relaxed));
    assert(LiTestVideoDecodeQueueWaitingForIdr());
    assert(!LiTestVideoDecodeQueueWaitingForRfi());

    LiTestDestroyVideoDecodeQueue();
    assert(umbra_stream_session_destroy(session) == UMBRA_STREAM_OK);
}

static void test_queue_count_snapshot_is_safe_during_concurrent_offer_and_poll(void) {
    QueueCountRace race = {0};
    assert(LbqInitializeLinkedBlockingQueue(&race.queue, QUEUE_COUNT_RACE_CAPACITY) == 0);
    atomic_init(&race.produced, 0);
    atomic_init(&race.consumed, 0);
    atomic_init(&race.failed, false);

    pthread_t producer;
    pthread_t consumer;
    assert(pthread_create(&producer, NULL, produce_queue_count_items, &race) == 0);
    assert(pthread_create(&consumer, NULL, consume_queue_count_items, &race) == 0);

    while (atomic_load_explicit(&race.consumed, memory_order_acquire) < QUEUE_COUNT_RACE_ITEMS) {
        int count = LbqGetItemCount(&race.queue);
        assert(count >= 0);
        assert(count <= QUEUE_COUNT_RACE_CAPACITY);
        assert(!atomic_load_explicit(&race.failed, memory_order_acquire));
        sched_yield();
    }

    assert(pthread_join(producer, NULL) == 0);
    assert(pthread_join(consumer, NULL) == 0);
    assert(atomic_load_explicit(&race.produced, memory_order_acquire) == QUEUE_COUNT_RACE_ITEMS);
    assert(atomic_load_explicit(&race.consumed, memory_order_acquire) == QUEUE_COUNT_RACE_ITEMS);
    assert(!atomic_load_explicit(&race.failed, memory_order_acquire));
    assert(LbqGetItemCount(&race.queue) == 0);
    LbqSignalQueueShutdown(&race.queue);
    assert(LbqDestroyLinkedBlockingQueue(&race.queue) == NULL);
}

static const char k_microphone_describe[] =
    "a=x-ss-general.featureFlags:0\n"
    "a=x-lumen-mic.version:1\r\n"
    "a=x-lumen-mic.codec:opus\r\n"
    "a=x-lumen-mic.sampleRate:48000\r\n"
    "a=x-lumen-mic.channels:1\r\n"
    "a=x-lumen-mic.packetDurationMs:20\r\n"
    "a=x-lumen-mic.crypto:aes-256-gcm\r\n"
    "a=x-lumen-mic.fec:opus-inband\r\n"
    "a=rtpmap:98 AV1/90000\n";

static void test_client_microphone_describe_and_transport_are_exact_and_optional(void) {
    char transport[64] = {0};

    umbra_client_microphone_rtsp_configure(false, 55000);
    assert(!umbra_client_microphone_rtsp_accept_describe(
        k_microphone_describe,
        sizeof(k_microphone_describe) - 1
    ));
    assert(!umbra_client_microphone_rtsp_should_setup());

    umbra_client_microphone_rtsp_configure(true, 55000);
    assert(umbra_client_microphone_rtsp_accept_describe(
        k_microphone_describe,
        sizeof(k_microphone_describe) - 1
    ));
    assert(umbra_client_microphone_rtsp_should_setup());
    assert(strcmp(umbra_client_microphone_rtsp_setup_target(), "streamid=lumen-mic/1/0") == 0);
    assert(umbra_client_microphone_rtsp_format_transport(transport, sizeof(transport)));
    assert(strcmp(transport, "unicast;X-GS-ClientPort=55000-55001") == 0);

    static const char partial[] =
        "a=x-lumen-mic.version:1\r\n"
        "a=x-lumen-mic.codec:opus\r\n";
    umbra_client_microphone_rtsp_configure(true, 55000);
    assert(!umbra_client_microphone_rtsp_accept_describe(partial, sizeof(partial) - 1));
    assert(!umbra_client_microphone_rtsp_should_setup());

    static const char duplicate[] =
        "a=x-lumen-mic.version:1\r\n"
        "a=x-lumen-mic.codec:opus\r\n"
        "a=x-lumen-mic.sampleRate:48000\r\n"
        "a=x-lumen-mic.channels:1\r\n"
        "a=x-lumen-mic.packetDurationMs:20\r\n"
        "a=x-lumen-mic.crypto:aes-256-gcm\r\n"
        "a=x-lumen-mic.fec:opus-inband\r\n"
        "a=x-lumen-mic.fec:opus-inband\r\n";
    umbra_client_microphone_rtsp_configure(true, 55000);
    assert(!umbra_client_microphone_rtsp_accept_describe(duplicate, sizeof(duplicate) - 1));
    assert(!umbra_client_microphone_rtsp_should_setup());

    static const char unknown[] =
        "a=x-lumen-mic.version:1\r\n"
        "a=x-lumen-mic.codec:opus\r\n"
        "a=x-lumen-mic.sampleRate:48000\r\n"
        "a=x-lumen-mic.channels:1\r\n"
        "a=x-lumen-mic.packetDurationMs:20\r\n"
        "a=x-lumen-mic.crypto:aes-256-gcm\r\n"
        "a=x-lumen-mic.unsupported:1\r\n"
        "a=x-lumen-mic.fec:opus-inband\r\n";
    umbra_client_microphone_rtsp_configure(true, 55000);
    assert(!umbra_client_microphone_rtsp_accept_describe(unknown, sizeof(unknown) - 1));
    assert(!umbra_client_microphone_rtsp_should_setup());
}

static void prepare_microphone_setup(void) {
    memset(&RemoteAddr, 0, sizeof(RemoteAddr));
    struct sockaddr_in *remote = (struct sockaddr_in *)&RemoteAddr;
    remote->sin_family = AF_INET;
    assert(inet_pton(AF_INET, "192.0.2.42", &remote->sin_addr) == 1);
    umbra_client_microphone_rtsp_configure(true, 55000);
    assert(umbra_client_microphone_rtsp_accept_describe(
        k_microphone_describe,
        sizeof(k_microphone_describe) - 1
    ));
}

static RTSP_MESSAGE microphone_setup_response(
    OPTION_ITEM options[3],
    char *session,
    char *salt,
    char *transport
) {
    options[0] = (OPTION_ITEM){.option = "X-Lumen-Mic-Session", .content = session, .next = &options[1]};
    options[1] = (OPTION_ITEM){.option = "X-Lumen-Mic-Salt", .content = salt, .next = &options[2]};
    options[2] = (OPTION_ITEM){.option = "Transport", .content = transport, .next = NULL};
    RTSP_MESSAGE response = {0};
    response.type = TYPE_RESPONSE;
    response.message.response.statusCode = 200;
    response.options = options;
    return response;
}

static void test_client_microphone_setup_snapshot_and_announce_are_exact(void) {
    char session[] = "000f102a3b4c5d6e7f8091a2b3c4d5ff";
    char salt[] = "ffeeddccbbaa99887766554433221100";
    char transport[] = "unicast;server_port=48012";
    OPTION_ITEM options[3];
    RTSP_MESSAGE response = microphone_setup_response(options, session, salt, transport);

    prepare_microphone_setup();
    assert(umbra_client_microphone_rtsp_evaluate_setup(&response) ==
        UMBRA_CLIENT_MICROPHONE_RTSP_SETUP_ACCEPTED);
    assert(umbra_client_microphone_rtsp_test_setup_succeeded());

    const char base[] = "v=0\r\n";
    int payload_length = (int)(sizeof(base) - 1);
    char *payload = malloc((size_t)payload_length);
    assert(payload != NULL);
    memcpy(payload, base, (size_t)payload_length);
    assert(umbra_client_microphone_rtsp_append_announce(&payload, &payload_length));
    static const char expected[] =
        "v=0\r\n"
        "a=x-lumen-mic.enabled:1\r\n"
        "a=x-lumen-mic.version:1\r\n"
        "a=x-lumen-mic.codec:opus\r\n"
        "a=x-lumen-mic.sampleRate:48000\r\n"
        "a=x-lumen-mic.channels:1\r\n"
        "a=x-lumen-mic.packetDurationMs:20\r\n"
        "a=x-lumen-mic.fec:opus-inband\r\n";
    assert(payload_length == (int)(sizeof(expected) - 1));
    assert(memcmp(payload, expected, sizeof(expected) - 1) == 0);
    free(payload);

    UmbraClientMicrophoneRTSPSnapshot snapshot = {0};
    assert(umbra_client_microphone_rtsp_take_snapshot(&snapshot));
    assert(snapshot.client_port == 55000);
    assert(snapshot.server_port == 48012);
    assert(strcmp(snapshot.remote_address, "192.0.2.42") == 0);
    const uint8_t expected_session[] = {
        0x00, 0x0f, 0x10, 0x2a, 0x3b, 0x4c, 0x5d, 0x6e,
        0x7f, 0x80, 0x91, 0xa2, 0xb3, 0xc4, 0xd5, 0xff
    };
    assert(memcmp(snapshot.session_id, expected_session, sizeof(expected_session)) == 0);
    assert(!umbra_client_microphone_rtsp_take_snapshot(&snapshot));
}

static void test_client_microphone_snapshot_preserves_scoped_ipv6_without_url_brackets(void) {
    char session[] = "000f102a3b4c5d6e7f8091a2b3c4d5ff";
    char salt[] = "ffeeddccbbaa99887766554433221100";
    char transport[] = "unicast;server_port=48012";
    OPTION_ITEM options[3];
    RTSP_MESSAGE response = microphone_setup_response(options, session, salt, transport);

    prepare_microphone_setup();
    memset(&RemoteAddr, 0, sizeof(RemoteAddr));
    struct sockaddr_in6 *remote = (struct sockaddr_in6 *)&RemoteAddr;
    remote->sin6_family = AF_INET6;
    remote->sin6_scope_id = 7;
    assert(inet_pton(AF_INET6, "fe80::1234", &remote->sin6_addr) == 1);
    assert(umbra_client_microphone_rtsp_evaluate_setup(&response) ==
        UMBRA_CLIENT_MICROPHONE_RTSP_SETUP_ACCEPTED);

    UmbraClientMicrophoneRTSPSnapshot snapshot = {0};
    assert(umbra_client_microphone_rtsp_take_snapshot(&snapshot));
    assert(strcmp(snapshot.remote_address, "fe80::1234%7") == 0);
}

static void test_client_microphone_setup_rejects_malformed_success(void) {
    char session[] = "000f102a3b4c5d6e7f8091a2b3c4d5ff";
    char salt[] = "ffeeddccbbaa99887766554433221100";
    char transport[] = "unicast;server_port=48012";
    OPTION_ITEM options[3];
    RTSP_MESSAGE response = microphone_setup_response(options, session, salt, transport);

    prepare_microphone_setup();
    session[3] = 'F';
    assert(umbra_client_microphone_rtsp_evaluate_setup(&response) ==
        UMBRA_CLIENT_MICROPHONE_RTSP_SETUP_FATAL);
    assert(!umbra_client_microphone_rtsp_test_setup_succeeded());

    session[3] = 'f';
    prepare_microphone_setup();
    options[2].content = "unicast;server_port=0";
    assert(umbra_client_microphone_rtsp_evaluate_setup(&response) ==
        UMBRA_CLIENT_MICROPHONE_RTSP_SETUP_FATAL);

    prepare_microphone_setup();
    options[2].content = "unicast;server_port=48012-48013";
    assert(umbra_client_microphone_rtsp_evaluate_setup(&response) ==
        UMBRA_CLIENT_MICROPHONE_RTSP_SETUP_FATAL);

    prepare_microphone_setup();
    options[2].content = transport;
    options[0].next = &options[1];
    options[1].next = &options[2];
    OPTION_ITEM duplicate = {
        .option = "X-Lumen-Mic-Session",
        .content = session,
        .next = NULL
    };
    options[2].next = &duplicate;
    assert(umbra_client_microphone_rtsp_evaluate_setup(&response) ==
        UMBRA_CLIENT_MICROPHONE_RTSP_SETUP_FATAL);

    prepare_microphone_setup();
    response.message.response.statusCode = 404;
    assert(umbra_client_microphone_rtsp_evaluate_setup(&response) ==
        UMBRA_CLIENT_MICROPHONE_RTSP_SETUP_DECLINED);
    assert(!umbra_client_microphone_rtsp_should_setup());
}

static void test_rtsp_parser_preserves_duplicate_microphone_headers_for_rejection(void) {
    char raw_response[] =
        "RTSP/1.0 200 OK\r\n"
        "CSeq: 7\r\n"
        "x-lumen-mic-session: 000f102a3b4c5d6e7f8091a2b3c4d5ff\r\n"
        "x-lumen-mic-session: 000f102a3b4c5d6e7f8091a2b3c4d5ff\r\n"
        "X-Lumen-Mic-Salt: ffeeddccbbaa99887766554433221100\r\n"
        "Transport: unicast;server_port=48012\r\n\r\n";
    RTSP_MESSAGE response;
    assert(parseRtspMessage(&response, raw_response, (int)(sizeof(raw_response) - 1)) == RTSP_ERROR_SUCCESS);
    size_t session_headers = 0;
    for (POPTION_ITEM option = response.options; option != NULL; option = option->next) {
        if (strcmp(option->option, "x-lumen-mic-session") == 0) {
            session_headers++;
        }
    }
    assert(session_headers == 2);
    prepare_microphone_setup();
    assert(umbra_client_microphone_rtsp_evaluate_setup(&response) ==
        UMBRA_CLIENT_MICROPHONE_RTSP_SETUP_FATAL);
    freeMessage(&response);
}

static void test_idle_lifecycle_and_guards(void) {
    UmbraStreamConfiguration configuration = valid_configuration();
    int32_t result = 1234;
    UmbraStreamSession *session = umbra_stream_session_create(&configuration, NULL, &result);
    assert(session != NULL);
    assert(result == UMBRA_STREAM_OK);
    assert(umbra_stream_session_state(session) == UMBRA_STREAM_STATE_IDLE);
    assert(umbra_stream_session_start(session) == UMBRA_STREAM_ERROR_INVALID_ARGUMENT);
    assert(umbra_stream_session_state(session) == UMBRA_STREAM_STATE_IDLE);
    assert(umbra_stream_session_stop(session) == UMBRA_STREAM_OK);
    assert(umbra_stream_session_cancel(session) == UMBRA_STREAM_OK);
    assert(umbra_stream_session_request_idr(session) == UMBRA_STREAM_ERROR_INVALID_STATE);
    assert(umbra_stream_session_send_mouse_move(session, 1, 1) == UMBRA_STREAM_ERROR_INVALID_STATE);
    assert(umbra_stream_session_send_keyboard(session, 0x41, 3, 0, 0) == UMBRA_STREAM_ERROR_INVALID_STATE);
    assert(umbra_stream_session_send_utf8_text(session, "x", 1) == UMBRA_STREAM_ERROR_INVALID_STATE);
    UmbraStreamStatistics statistics;
    memset(&statistics, 0xA5, sizeof(statistics));
    assert(umbra_stream_session_get_statistics(session, &statistics) == UMBRA_STREAM_ERROR_INVALID_STATE);
    assert(umbra_stream_session_destroy(session) == UMBRA_STREAM_OK);
}

static void test_connected_keyboard_send_reaches_moonlight_input_boundary(void) {
    UmbraStreamConfiguration configuration = valid_configuration();
    int32_t result = 0;
    UmbraStreamSession *session = umbra_stream_session_create(&configuration, NULL, &result);
    assert(session != NULL);
    assert(result == UMBRA_STREAM_OK);

    // A successful Moonlight input send requires initializeInputStream() and
    // startInputStream(), which are performed by a real LiStartConnection().
    // This harness has no live host, so -2 is the strongest safe proof that the
    // connected bridge branch reached LiSendKeyboardEvent2() rather than being
    // rejected by Umbra's state guard.
    umbra_stream_test_set_state(session, UMBRA_STREAM_STATE_CONNECTED);
    assert(umbra_stream_session_send_keyboard(session, (int16_t)0x8041, 3, 0, 0) == -2);

    umbra_stream_test_set_state(session, UMBRA_STREAM_STATE_IDLE);
    assert(umbra_stream_session_destroy(session) == UMBRA_STREAM_OK);
}

static void test_destroy_waits_for_input_send_already_inside_facade(void) {
    UmbraStreamConfiguration configuration = valid_configuration();
    int32_t result = 0;
    UmbraStreamSession *session = umbra_stream_session_create(&configuration, NULL, &result);
    assert(session != NULL);
    assert(result == UMBRA_STREAM_OK);

    InputTeardownRace race = {
        .session = session,
        .input_result = 0,
        .destroy_result = 0,
    };
    atomic_init(&race.destroy_finished, false);
    umbra_stream_test_set_state(session, UMBRA_STREAM_STATE_CONNECTED);
    umbra_stream_test_set_input_blocked(session, true);

    pthread_t input_thread;
    assert(pthread_create(&input_thread, NULL, send_keyboard_on_thread, &race) == 0);
    umbra_stream_test_wait_until_input_blocked(session);

    umbra_stream_test_set_state(session, UMBRA_STREAM_STATE_IDLE);
    pthread_t destroy_thread;
    assert(pthread_create(&destroy_thread, NULL, destroy_session_on_thread, &race) == 0);
    umbra_stream_test_wait_until_destroy_started(session);
    assert(!atomic_load_explicit(&race.destroy_finished, memory_order_acquire));

    umbra_stream_test_set_input_blocked(session, false);
    assert(pthread_join(input_thread, NULL) == 0);
    assert(pthread_join(destroy_thread, NULL) == 0);
    assert(race.input_result == -2);
    assert(race.destroy_result == UMBRA_STREAM_OK);
    assert(atomic_load_explicit(&race.destroy_finished, memory_order_acquire));
}

static void test_create_rejects_invalid_configuration(void) {
    UmbraStreamConfiguration configuration = valid_configuration();
    configuration.supported_video_formats = 0;
    int32_t result = 0;
    assert(umbra_stream_session_create(&configuration, NULL, &result) == NULL);
    assert(result == UMBRA_STREAM_ERROR_INVALID_ARGUMENT);

    configuration = valid_configuration();
    configuration.supported_video_formats = UMBRA_VIDEO_FORMAT_H264 | UMBRA_VIDEO_FORMAT_H265;
    assert(umbra_stream_session_create(&configuration, NULL, &result) == NULL);
    assert(result == UMBRA_STREAM_ERROR_INVALID_ARGUMENT);

    configuration = valid_configuration();
    configuration.supported_video_formats = 0x0020;
    assert(umbra_stream_session_create(&configuration, NULL, &result) == NULL);
    assert(result == UMBRA_STREAM_ERROR_INVALID_ARGUMENT);
}

static void test_callback_and_lifecycle_guards(void) {
    UmbraStreamConfiguration configuration = valid_configuration();
    CallbackRecord record = {0};
    UmbraStreamCallbacks callbacks = {0};
    callbacks.context = &record;
    callbacks.event = record_event;
    int32_t result = 0;
    UmbraStreamSession *session = umbra_stream_session_create(&configuration, &callbacks, &result);
    assert(session != NULL);
    umbra_stream_test_emit_log(session, "borrowed callback payload");
    assert(record.event_calls == 1);
    assert(record.event.type == UMBRA_STREAM_EVENT_LOG);
    assert(strcmp(record.message, "borrowed callback payload") == 0);

    umbra_stream_test_set_state(session, UMBRA_STREAM_STATE_CONNECTED);
    assert(umbra_stream_session_destroy(session) == UMBRA_STREAM_ERROR_INVALID_STATE);
    umbra_stream_test_set_state(session, UMBRA_STREAM_STATE_IDLE);
    assert(umbra_stream_session_destroy(session) == UMBRA_STREAM_OK);
}

static void test_video_setup_maps_every_field_and_return_value(void) {
    CallbackRecord record = {.video_setup_result = 37};
    UmbraStreamSession *session = create_callback_session(&record);
    UmbraVideoFormat expected = {
        .format = UMBRA_VIDEO_FORMAT_H265_MAIN10,
        .width = 2560,
        .height = 1440,
        .redraw_rate = 120,
        .flags = 0x1234
    };

    assert(umbra_stream_test_video_setup(session, &expected) == 37);
    assert(record.video_setup_calls == 1);
    assert(record.video_format.format == expected.format);
    assert(record.video_format.width == expected.width);
    assert(record.video_format.height == expected.height);
    assert(record.video_format.redraw_rate == expected.redraw_rate);
    assert(record.video_format.flags == expected.flags);
    assert(umbra_stream_session_destroy(session) == UMBRA_STREAM_OK);
}

static void test_video_frame_copies_chained_payload_and_maps_metadata(void) {
    CallbackRecord record = {.video_frame_result = -1};
    UmbraStreamSession *session = create_callback_session(&record);
    uint8_t source[] = {0x00, 0x00, 0x01, 0x67, 0x11, 0x22, 0x33, 0x44};
    record.video_source = source;
    UmbraVideoFrame input = {
        .data = source,
        .length = sizeof(source),
        .frame_number = 42,
        .frame_type = 1,
        .host_processing_latency_tenths_ms = 91,
        .receive_time_us = 1001,
        .enqueue_time_us = 1002,
        .presentation_time_us = 1003,
        .rtp_timestamp = 90090,
        .hdr_active = true,
        .color_space = UMBRA_STREAM_COLORSPACE_REC_2020
    };

    assert(umbra_stream_test_video_frame(session, &input, 4) == -1);
    assert(record.video_frame_calls == 1);
    assert(record.video_frame.length == sizeof(source));
    assert(memcmp(record.video_data, source, sizeof(source)) == 0);
    assert(record.video_frame.frame_number == 42);
    assert(record.video_frame.frame_type == 1);
    assert(record.video_frame.host_processing_latency_tenths_ms == 91);
    assert(record.video_frame.receive_time_us == 1001);
    assert(record.video_frame.enqueue_time_us == 1002);
    assert(record.video_frame.presentation_time_us == 1003);
    assert(record.video_frame.rtp_timestamp == 90090);
    assert(record.video_frame.hdr_active);
    assert(record.video_frame.color_space == UMBRA_STREAM_COLORSPACE_REC_2020);
    assert(umbra_stream_session_destroy(session) == UMBRA_STREAM_OK);
}

static void test_video_frame_can_transfer_payload_ownership_past_callback(void) {
    CallbackRecord record = {.take_video_data = true};
    UmbraStreamSession *session = create_callback_session(&record);
    uint8_t source[] = {0x00, 0x00, 0x00, 0x01, 0x26, 0xAA, 0xBB, 0xCC};
    record.video_source = source;
    UmbraVideoFrame input = {
        .data = source,
        .length = sizeof(source),
        .frame_number = 43,
        .frame_type = 1
    };

    assert(umbra_stream_test_video_frame(session, &input, 3) == 0);
    memset(source, 0, sizeof(source));
    assert(record.owned_video_length == sizeof(source));
    const uint8_t expected[] = {0x00, 0x00, 0x00, 0x01, 0x26, 0xAA, 0xBB, 0xCC};
    assert(memcmp(record.owned_video_data, expected, sizeof(expected)) == 0);
    umbra_video_frame_release_data(record.owned_video_data);
    assert(umbra_stream_session_destroy(session) == UMBRA_STREAM_OK);
}

static void test_prepared_h264_handles_every_fragment_split_without_intermediate_annex_b(void) {
    const uint8_t source[] = {
        0, 0, 0, 1, 0x67, 0x64, 0x1F,
        0, 0, 1, 0x68, 0xEE,
        0, 0, 0, 1, 0x65, 0xAA, 0xBB
    };
    const uint8_t expected[] = {
        0, 0, 0, 3, 0x67, 0x64, 0x1F,
        0, 0, 0, 2, 0x68, 0xEE,
        0, 0, 0, 3, 0x65, 0xAA, 0xBB
    };
    CallbackRecord record = {0};
    UmbraStreamSession *session = create_prepared_callback_session(&record, VIDEO_FORMAT_H264);
    UmbraVideoFrame input = {
        .data = (uint8_t *)source,
        .length = sizeof(source),
        .frame_number = 44,
        .frame_type = 1,
        .hdr_active = true,
        .color_space = UMBRA_STREAM_COLORSPACE_REC_2020
    };
    for (size_t split = 1; split < sizeof(source); split++) {
        size_t lengths[] = {split, sizeof(source) - split};
        assert(umbra_stream_test_video_frame_fragments(session, &input, lengths, 2) == 0);
        assert(record.prepared_video_frame_calls == (int)split);
        assert(record.prepared_video_frame.payload_format ==
            UMBRA_PREPARED_VIDEO_PAYLOAD_VIDEO_TOOLBOX_LENGTH_PREFIXED);
        assert(record.prepared_video_frame.length == sizeof(expected));
        assert(memcmp(record.prepared_video_data, expected, sizeof(expected)) == 0);
        assert(record.prepared_video_frame.frame_number == 44);
        assert(record.prepared_video_frame.hdr_active);
    }
    assert(umbra_stream_session_destroy(session) == UMBRA_STREAM_OK);
}

static void test_prepared_av1_copies_fragments_once_into_final_payload(void) {
    const uint8_t source[] = {0x12, 0x00, 0x0A, 0x02, 0xDE, 0xAD, 0x32, 0x01, 0xBE};
    const size_t lengths[] = {1, 2, 1, 3, 2};
    CallbackRecord record = {0};
    UmbraStreamSession *session = create_prepared_callback_session(&record, VIDEO_FORMAT_AV1_MAIN10);
    UmbraVideoFrame input = {.data = (uint8_t *)source, .length = sizeof(source)};

    assert(umbra_stream_test_video_frame_fragments(session, &input, lengths, 5) == 0);
    assert(record.prepared_video_frame_calls == 1);
    assert(record.prepared_video_frame.payload_format == UMBRA_PREPARED_VIDEO_PAYLOAD_AV1_LOW_OVERHEAD_OBU);
    assert(record.prepared_video_frame.length == sizeof(source));
    assert(memcmp(record.prepared_video_data, source, sizeof(source)) == 0);
    assert(umbra_stream_session_destroy(session) == UMBRA_STREAM_OK);
}

static void test_prepared_hevc_handles_split_start_codes_headers_and_bodies(void) {
    const uint8_t source[] = {
        0, 0, 1, 0x40, 0x01, 0xAA,
        0, 0, 0, 1, 0x42, 0x01, 0xBB,
        0, 0, 1, 0x26, 0x01, 0xCC, 0xDD
    };
    const uint8_t expected[] = {
        0, 0, 0, 3, 0x40, 0x01, 0xAA,
        0, 0, 0, 3, 0x42, 0x01, 0xBB,
        0, 0, 0, 4, 0x26, 0x01, 0xCC, 0xDD
    };
    CallbackRecord record = {0};
    UmbraStreamSession *session = create_prepared_callback_session(&record, VIDEO_FORMAT_H265_REXT10_444);
    UmbraVideoFrame input = {.data = (uint8_t *)source, .length = sizeof(source)};
    for (size_t split = 1; split < sizeof(source); split++) {
        size_t lengths[] = {split, sizeof(source) - split};
        assert(umbra_stream_test_video_frame_fragments(session, &input, lengths, 2) == 0);
        assert(record.prepared_video_frame.length == sizeof(expected));
        assert(memcmp(record.prepared_video_data, expected, sizeof(expected)) == 0);
    }
    assert(record.prepared_video_frame_calls == (int)(sizeof(source) - 1));
    assert(umbra_stream_session_destroy(session) == UMBRA_STREAM_OK);
}

static void test_prepared_writer_rejects_malformed_and_excessive_fragment_chains(void) {
    CallbackRecord record = {0};
    UmbraStreamSession *session = create_prepared_callback_session(&record, VIDEO_FORMAT_H265_MAIN10);
    uint8_t malformed[] = {0, 0, 1, 0, 0, 0, 1, 0x26};
    UmbraVideoFrame malformed_frame = {.data = malformed, .length = sizeof(malformed)};
    size_t malformed_lengths[] = {2, 1, 2, 3};
    assert(umbra_stream_test_video_frame_fragments(
        session,
        &malformed_frame,
        malformed_lengths,
        4
    ) == DR_NEED_IDR);
    assert(record.prepared_video_frame_calls == 0);

    size_t fragment_count = 131073;
    uint8_t *bytes = malloc(fragment_count);
    size_t *lengths = malloc(fragment_count * sizeof(*lengths));
    assert(bytes != NULL && lengths != NULL);
    memset(bytes, 1, fragment_count);
    for (size_t index = 0; index < fragment_count; index++) {
        lengths[index] = 1;
    }
    UmbraVideoFrame excessive = {.data = bytes, .length = fragment_count};
    assert(umbra_stream_test_video_frame_fragments(
        session,
        &excessive,
        lengths,
        fragment_count
    ) == DR_NEED_IDR);
    assert(record.prepared_video_frame_calls == 0);
    free(lengths);
    free(bytes);
    assert(umbra_stream_session_destroy(session) == UMBRA_STREAM_OK);
}

static void test_prepared_writer_accepts_exact_frame_cap_and_rejects_cap_plus_one(void) {
    const size_t maximum = (size_t)64 * 1024 * 1024;
    uint8_t *bytes = malloc(maximum + 1);
    assert(bytes != NULL);
    memset(bytes, 0xA5, maximum + 1);
    bytes[0] = 0;
    bytes[1] = 0;
    bytes[2] = 0;
    bytes[3] = 1;

    CallbackRecord record = {.skip_prepared_copy = true};
    UmbraStreamSession *session = create_prepared_callback_session(&record, VIDEO_FORMAT_H264);
    UmbraVideoFrame frame = {.data = bytes, .length = maximum};
    size_t exact_length[] = {maximum};
    assert(umbra_stream_test_video_frame_fragments(session, &frame, exact_length, 1) == 0);
    assert(record.prepared_video_frame_calls == 1);
    assert(record.prepared_video_frame.length == maximum);

    frame.length = maximum + 1;
    size_t excessive_length[] = {maximum + 1};
    assert(umbra_stream_test_video_frame_fragments(session, &frame, excessive_length, 1) == DR_NEED_IDR);
    assert(record.prepared_video_frame_calls == 1);
    free(bytes);
    assert(umbra_stream_session_destroy(session) == UMBRA_STREAM_OK);
}

static void test_destroy_waits_for_prepared_callback_and_transferred_storage(void) {
    uint8_t source[] = {0, 0, 1, 0x67, 0xAA, 0, 0, 1, 0x65, 0xBB};
    CallbackRecord record = {
        .take_prepared_data = true,
        .block_prepared_callback = true
    };
    assert(pthread_mutex_init(&record.prepared_callback_mutex, NULL) == 0);
    assert(pthread_cond_init(&record.prepared_callback_condition, NULL) == 0);
    UmbraStreamSession *session = create_prepared_callback_session(&record, VIDEO_FORMAT_H264);
    PreparedVideoTeardownRace race = {
        .session = session,
        .frame = {.data = source, .length = sizeof(source)}
    };
    atomic_init(&race.destroy_finished, false);

    pthread_t video_thread;
    assert(pthread_create(&video_thread, NULL, send_prepared_video_on_thread, &race) == 0);
    pthread_mutex_lock(&record.prepared_callback_mutex);
    while (!record.prepared_callback_waiting) {
        pthread_cond_wait(&record.prepared_callback_condition, &record.prepared_callback_mutex);
    }
    pthread_mutex_unlock(&record.prepared_callback_mutex);

    umbra_stream_test_clear_active_session(session);
    pthread_t destroy_thread;
    assert(pthread_create(&destroy_thread, NULL, destroy_session_during_prepared_video, &race) == 0);
    umbra_stream_test_wait_until_destroy_started(session);
    assert(!atomic_load_explicit(&race.destroy_finished, memory_order_acquire));

    pthread_mutex_lock(&record.prepared_callback_mutex);
    record.block_prepared_callback = false;
    pthread_cond_broadcast(&record.prepared_callback_condition);
    pthread_mutex_unlock(&record.prepared_callback_mutex);
    assert(pthread_join(video_thread, NULL) == 0);
    assert(pthread_join(destroy_thread, NULL) == 0);
    assert(race.video_result == 0);
    assert(race.destroy_result == UMBRA_STREAM_OK);
    assert(atomic_load_explicit(&race.destroy_finished, memory_order_acquire));
    const uint8_t expected[] = {0, 0, 0, 2, 0x67, 0xAA, 0, 0, 0, 2, 0x65, 0xBB};
    assert(record.owned_prepared_length == sizeof(expected));
    assert(memcmp(record.owned_prepared_data, expected, sizeof(expected)) == 0);
    umbra_prepared_video_frame_release_data(record.owned_prepared_data);
    pthread_cond_destroy(&record.prepared_callback_condition);
    pthread_mutex_destroy(&record.prepared_callback_mutex);
}

static void test_video_lifecycle_maps_each_callback_once(void) {
    CallbackRecord record = {0};
    UmbraStreamSession *session = create_callback_session(&record);

    umbra_stream_test_video_start(session);
    umbra_stream_test_video_stop(session);
    umbra_stream_test_video_cleanup(session);

    assert(record.video_start_calls == 1);
    assert(record.video_stop_calls == 1);
    assert(record.video_cleanup_calls == 1);
    assert(umbra_stream_session_destroy(session) == UMBRA_STREAM_OK);
}

static void test_audio_init_maps_every_field_and_return_value(void) {
    CallbackRecord record = {.audio_init_result = 23};
    UmbraStreamSession *session = create_callback_session(&record);
    UmbraAudioFormat expected = {
        .audio_configuration = UMBRA_AUDIO_CONFIGURATION_71_SURROUND,
        .sample_rate = 48000,
        .channel_count = 8,
        .streams = 5,
        .coupled_streams = 3,
        .samples_per_frame = 240,
        .mapping = {0, 1, 4, 5, 2, 3, 6, 7},
        .flags = 0x55
    };

    assert(umbra_stream_test_audio_init(session, &expected) == 23);
    assert(record.audio_init_calls == 1);
    assert(record.audio_format.audio_configuration == expected.audio_configuration);
    assert(record.audio_format.sample_rate == expected.sample_rate);
    assert(record.audio_format.channel_count == expected.channel_count);
    assert(record.audio_format.streams == expected.streams);
    assert(record.audio_format.coupled_streams == expected.coupled_streams);
    assert(record.audio_format.samples_per_frame == expected.samples_per_frame);
    assert(memcmp(record.audio_format.mapping, expected.mapping, sizeof(expected.mapping)) == 0);
    assert(record.audio_format.flags == expected.flags);
    assert(umbra_stream_session_destroy(session) == UMBRA_STREAM_OK);
}

static void test_audio_packet_maps_borrowed_bytes(void) {
    CallbackRecord record = {0};
    UmbraStreamSession *session = create_callback_session(&record);
    const uint8_t packet[] = {0xF8, 0xFF, 0xFE, 0x01, 0x02};

    umbra_stream_test_audio_packet(session, packet, sizeof(packet));

    assert(record.audio_packet_calls == 1);
    assert(record.audio_length == sizeof(packet));
    assert(memcmp(record.audio_data, packet, sizeof(packet)) == 0);
    assert(umbra_stream_session_destroy(session) == UMBRA_STREAM_OK);
}

static void test_audio_packet_preserves_packet_loss_concealment(void) {
    CallbackRecord record = {0};
    UmbraStreamSession *session = create_callback_session(&record);

    umbra_stream_test_audio_packet(session, NULL, 0);

    assert(record.audio_packet_calls == 1);
    assert(record.audio_length == 0);
    assert(umbra_stream_session_destroy(session) == UMBRA_STREAM_OK);
}

static void test_audio_lifecycle_maps_each_callback_once(void) {
    CallbackRecord record = {0};
    UmbraStreamSession *session = create_callback_session(&record);

    umbra_stream_test_audio_start(session);
    umbra_stream_test_audio_stop(session);
    umbra_stream_test_audio_cleanup(session);

    assert(record.audio_start_calls == 1);
    assert(record.audio_stop_calls == 1);
    assert(record.audio_cleanup_calls == 1);
    assert(umbra_stream_session_destroy(session) == UMBRA_STREAM_OK);
}

static void test_connection_termination_maps_error_and_state(void) {
    CallbackRecord record = {0};
    UmbraStreamSession *session = create_callback_session(&record);

    umbra_stream_test_connection_terminated(session, -77);

    assert(record.event_calls == 1);
    assert(record.event.type == UMBRA_STREAM_EVENT_CONNECTION_TERMINATED);
    assert(record.event.error_code == -77);
    assert(umbra_stream_session_state(session) == UMBRA_STREAM_STATE_TERMINATED);
    umbra_stream_test_set_state(session, UMBRA_STREAM_STATE_IDLE);
    assert(umbra_stream_session_destroy(session) == UMBRA_STREAM_OK);
}

int main(void) {
    test_configuration_defaults_and_validation();
    test_optimization_mode_announce_is_exact_bounded_and_isolated();
    test_optimization_mode_is_snapshotted_into_moonlight_stream_configuration();
    test_split_modes_keep_nvidia_announce_legacy_and_lumen_both_active();
    test_input_batching_delay_is_mode_isolated_and_latency_has_no_sleep();
    test_legacy_and_quality_input_wire_packets_are_byte_for_byte_identical();
    test_latency_input_preserves_coalescing_edges_order_and_queue_pressure();
    test_input_lifecycle_reset_restores_neutral_coalescing_and_pen_state();
    test_latency_pen_coalescing_keeps_latest_state_before_reliable_release();
    test_failed_start_clears_scoped_optimization_mode();
    test_video_decode_queue_capacity_is_clamped_and_direct_submit_stays_disabled();
    test_video_decode_queue_overflow_uses_actual_depacketizer_recovery();
    test_queue_count_snapshot_is_safe_during_concurrent_offer_and_poll();
    test_client_microphone_describe_and_transport_are_exact_and_optional();
    test_client_microphone_setup_snapshot_and_announce_are_exact();
    test_client_microphone_snapshot_preserves_scoped_ipv6_without_url_brackets();
    test_client_microphone_setup_rejects_malformed_success();
    test_rtsp_parser_preserves_duplicate_microphone_headers_for_rejection();
    test_idle_lifecycle_and_guards();
    test_connected_keyboard_send_reaches_moonlight_input_boundary();
    test_destroy_waits_for_input_send_already_inside_facade();
    test_create_rejects_invalid_configuration();
    test_callback_and_lifecycle_guards();
    test_video_setup_maps_every_field_and_return_value();
    test_video_frame_copies_chained_payload_and_maps_metadata();
    test_video_frame_can_transfer_payload_ownership_past_callback();
    test_prepared_h264_handles_every_fragment_split_without_intermediate_annex_b();
    test_prepared_av1_copies_fragments_once_into_final_payload();
    test_prepared_hevc_handles_split_start_codes_headers_and_bodies();
    test_prepared_writer_rejects_malformed_and_excessive_fragment_chains();
    test_prepared_writer_accepts_exact_frame_cap_and_rejects_cap_plus_one();
    test_destroy_waits_for_prepared_callback_and_transferred_storage();
    test_video_lifecycle_maps_each_callback_once();
    test_audio_init_maps_every_field_and_return_value();
    test_audio_packet_maps_borrowed_bytes();
    test_audio_packet_preserves_packet_loss_concealment();
    test_audio_lifecycle_maps_each_callback_once();
    test_connection_termination_maps_error_and_state();
    puts("CMoonlightBridge tests passed");
    return 0;
}
