#ifndef UMBRA_STREAMING_BRIDGE_TEST_HOOKS_H
#define UMBRA_STREAMING_BRIDGE_TEST_HOOKS_H

#include "UmbraStreamingBridge.h"

void umbra_stream_test_emit_log(UmbraStreamSession *session, const char *message);
void umbra_stream_test_set_state(UmbraStreamSession *session, UmbraStreamState state);
int32_t umbra_stream_test_video_decode_queue_capacity(const UmbraStreamSession *session);
int32_t umbra_stream_test_input_optimization_mode(const UmbraStreamSession *session);
int32_t umbra_stream_test_rtsp_optimization_mode(const UmbraStreamSession *session);
int32_t umbra_stream_test_video_capabilities(const UmbraStreamSession *session);
void umbra_stream_test_set_input_blocked(UmbraStreamSession *session, bool blocked);
void umbra_stream_test_wait_until_input_blocked(UmbraStreamSession *session);
void umbra_stream_test_wait_until_destroy_started(UmbraStreamSession *session);
void umbra_stream_test_clear_active_session(UmbraStreamSession *session);
int32_t umbra_stream_test_video_setup(UmbraStreamSession *session, const UmbraVideoFormat *format);
void umbra_stream_test_video_start(UmbraStreamSession *session);
void umbra_stream_test_video_stop(UmbraStreamSession *session);
void umbra_stream_test_video_cleanup(UmbraStreamSession *session);
int32_t umbra_stream_test_video_frame(
    UmbraStreamSession *session,
    const UmbraVideoFrame *frame,
    size_t first_chunk_length
);
int32_t umbra_stream_test_video_frame_fragments(
    UmbraStreamSession *session,
    const UmbraVideoFrame *frame,
    const size_t *chunk_lengths,
    size_t chunk_count
);
int32_t umbra_stream_test_audio_init(UmbraStreamSession *session, const UmbraAudioFormat *format);
void umbra_stream_test_audio_start(UmbraStreamSession *session);
void umbra_stream_test_audio_stop(UmbraStreamSession *session);
void umbra_stream_test_audio_cleanup(UmbraStreamSession *session);
void umbra_stream_test_audio_packet(UmbraStreamSession *session, const uint8_t *data, size_t length);
void umbra_stream_test_connection_terminated(UmbraStreamSession *session, int32_t error_code);

#endif
