#ifndef UMBRA_COPUS_SHIM_H
#define UMBRA_COPUS_SHIM_H

#include <opus.h>
#include <opus_multistream.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

// C variadic functions are unavailable to Swift. Keep the control operation
// behind a typed shim so decoder state can be reset during stream lifecycle
// transitions without recreating the allocation.
static inline int umbra_opus_multistream_decoder_reset(OpusMSDecoder *decoder) {
    return opus_multistream_decoder_ctl(decoder, OPUS_RESET_STATE);
}

static inline int umbra_opus_encoder_set_bitrate(OpusEncoder *encoder, opus_int32 bitrate) {
    return opus_encoder_ctl(encoder, OPUS_SET_BITRATE(bitrate));
}

static inline int umbra_opus_encoder_set_inband_fec(OpusEncoder *encoder, int enabled) {
    return opus_encoder_ctl(encoder, OPUS_SET_INBAND_FEC(enabled));
}

static inline int umbra_opus_encoder_set_packet_loss_percentage(OpusEncoder *encoder, int percentage) {
    return opus_encoder_ctl(encoder, OPUS_SET_PACKET_LOSS_PERC(percentage));
}

static inline int umbra_opus_encoder_set_dtx(OpusEncoder *encoder, int enabled) {
    return opus_encoder_ctl(encoder, OPUS_SET_DTX(enabled));
}

static inline int umbra_opus_encoder_reset(OpusEncoder *encoder) {
    return opus_encoder_ctl(encoder, OPUS_RESET_STATE);
}

static inline int umbra_opus_encoder_get_bitrate(OpusEncoder *encoder, opus_int32 *bitrate) {
    return opus_encoder_ctl(encoder, OPUS_GET_BITRATE(bitrate));
}

static inline int umbra_opus_encoder_get_inband_fec(OpusEncoder *encoder, int *enabled) {
    return opus_encoder_ctl(encoder, OPUS_GET_INBAND_FEC(enabled));
}

static inline int umbra_opus_encoder_get_packet_loss_percentage(OpusEncoder *encoder, int *percentage) {
    return opus_encoder_ctl(encoder, OPUS_GET_PACKET_LOSS_PERC(percentage));
}

static inline int umbra_opus_encoder_get_dtx(OpusEncoder *encoder, int *enabled) {
    return opus_encoder_ctl(encoder, OPUS_GET_DTX(enabled));
}

static inline int umbra_opus_encoder_get_in_dtx(OpusEncoder *encoder, int *in_dtx) {
    return opus_encoder_ctl(encoder, OPUS_GET_IN_DTX(in_dtx));
}

// Lock-free SPSC storage for the input AudioQueue callback. The producer never
// waits. On overflow it drops input and raises a discontinuity barrier; the
// consumer then discards the partial timeline before emitting RESET.
typedef struct UmbraMicrophoneSampleRing {
    float *storage;
    uint32_t capacity;
    _Atomic uint64_t read_position;
    _Atomic uint64_t write_position;
    _Atomic bool discontinuity;
    _Atomic bool terminal_failure;
    _Atomic bool accepting;
} UmbraMicrophoneSampleRing;

static inline void umbra_microphone_sample_ring_init(
    UmbraMicrophoneSampleRing *ring,
    float *storage,
    uint32_t capacity
) {
    ring->storage = storage;
    ring->capacity = capacity;
    atomic_init(&ring->read_position, 0);
    atomic_init(&ring->write_position, 0);
    atomic_init(&ring->discontinuity, false);
    atomic_init(&ring->terminal_failure, false);
    atomic_init(&ring->accepting, false);
}

static inline void umbra_microphone_sample_ring_reset(UmbraMicrophoneSampleRing *ring) {
    atomic_store_explicit(&ring->accepting, false, memory_order_release);
    atomic_store_explicit(&ring->read_position, 0, memory_order_release);
    atomic_store_explicit(&ring->write_position, 0, memory_order_release);
    atomic_store_explicit(&ring->discontinuity, false, memory_order_release);
    atomic_store_explicit(&ring->terminal_failure, false, memory_order_release);
}

static inline void umbra_microphone_sample_ring_set_accepting(
    UmbraMicrophoneSampleRing *ring,
    bool accepting
) {
    atomic_store_explicit(&ring->accepting, accepting, memory_order_release);
}

static inline bool umbra_microphone_sample_ring_is_accepting(
    const UmbraMicrophoneSampleRing *ring
) {
    return atomic_load_explicit(&ring->accepting, memory_order_acquire);
}

static inline void umbra_microphone_sample_ring_mark_discontinuity(
    UmbraMicrophoneSampleRing *ring
) {
    atomic_store_explicit(&ring->discontinuity, true, memory_order_release);
}

static inline void umbra_microphone_sample_ring_mark_terminal_failure(
    UmbraMicrophoneSampleRing *ring
) {
    atomic_store_explicit(&ring->accepting, false, memory_order_release);
    atomic_store_explicit(&ring->terminal_failure, true, memory_order_release);
}

static inline bool umbra_microphone_sample_ring_write(
    UmbraMicrophoneSampleRing *ring,
    const float *samples,
    uint32_t sample_count
) {
    if (!atomic_load_explicit(&ring->accepting, memory_order_acquire) || sample_count == 0) {
        return false;
    }
    uint64_t write_position = atomic_load_explicit(&ring->write_position, memory_order_relaxed);
    uint64_t read_position = atomic_load_explicit(&ring->read_position, memory_order_acquire);
    if (sample_count > ring->capacity || sample_count > ring->capacity - (write_position - read_position)) {
        atomic_store_explicit(&ring->discontinuity, true, memory_order_release);
        return false;
    }

    uint32_t write_index = (uint32_t)(write_position % ring->capacity);
    uint32_t first_count = sample_count;
    if (first_count > ring->capacity - write_index) {
        first_count = ring->capacity - write_index;
    }
    memcpy(ring->storage + write_index, samples, first_count * sizeof(float));
    if (sample_count > first_count) {
        memcpy(ring->storage, samples + first_count, (sample_count - first_count) * sizeof(float));
    }
    atomic_store_explicit(
        &ring->write_position,
        write_position + sample_count,
        memory_order_release
    );
    return true;
}

// Returns -2 for terminal capture failure, -1 for discontinuity, 0 when no
// frame is ready, and 1 for one frame.
static inline int umbra_microphone_sample_ring_take_960(
    UmbraMicrophoneSampleRing *ring,
    float *output
) {
    if (atomic_exchange_explicit(&ring->terminal_failure, false, memory_order_acq_rel)) {
        return -2;
    }
    if (atomic_exchange_explicit(&ring->discontinuity, false, memory_order_acq_rel)) {
        uint64_t write_position = atomic_load_explicit(&ring->write_position, memory_order_acquire);
        atomic_store_explicit(&ring->read_position, write_position, memory_order_release);
        return -1;
    }
    uint64_t read_position = atomic_load_explicit(&ring->read_position, memory_order_relaxed);
    uint64_t write_position = atomic_load_explicit(&ring->write_position, memory_order_acquire);
    if (write_position - read_position < 960) {
        return 0;
    }

    uint32_t read_index = (uint32_t)(read_position % ring->capacity);
    uint32_t first_count = 960;
    if (first_count > ring->capacity - read_index) {
        first_count = ring->capacity - read_index;
    }
    memcpy(output, ring->storage + read_index, first_count * sizeof(float));
    if (first_count < 960) {
        memcpy(output + first_count, ring->storage, (960 - first_count) * sizeof(float));
    }
    atomic_store_explicit(&ring->read_position, read_position + 960, memory_order_release);
    return 1;
}

// Real-time-safe SPSC storage for decoded output PCM. The Moonlight decoder is
// the sole producer and the AudioQueue output callback is the sole consumer.
// Packet end positions preserve source-packet accounting without allocating or
// locking in either path.
typedef struct UmbraOutputBufferMetadata {
    uint32_t packet_count;
    uint32_t real_sample_count;
} UmbraOutputBufferMetadata;

typedef struct UmbraOutputSampleRing {
    float *storage;
    uint64_t *packet_end_positions;
    uint32_t sample_capacity;
    uint32_t packet_capacity;
    uint32_t channel_count;
    uint32_t minimum_preroll_sample_count;
    _Atomic uint64_t read_position;
    _Atomic uint64_t write_position;
    _Atomic uint64_t packet_read_position;
    _Atomic uint64_t packet_write_position;
    _Atomic uint64_t accepted_packets;
    _Atomic uint64_t played_packets;
    _Atomic uint64_t dropped_packets;
    _Atomic uint64_t rejected_packets;
    _Atomic uint64_t scheduled_packets;
    _Atomic uint64_t scheduled_real_samples;
    _Atomic uint64_t rendered_real_samples;
    _Atomic uint64_t rendered_silence_samples;
    _Atomic uint64_t callback_count;
    _Atomic uint64_t underrun_count;
    _Atomic uint64_t rebuffer_count;
    _Atomic uint32_t active_writers;
    _Atomic uint32_t active_callbacks;
    _Atomic uintptr_t queue_identity;
    _Atomic int32_t callback_error;
    _Atomic uint64_t flush_sample_position;
    _Atomic uint64_t flush_packet_position;
    _Atomic bool flush_requested;
    _Atomic bool prerolling;
    _Atomic bool accepting;
    _Atomic bool callback_enabled;
} UmbraOutputSampleRing;

static inline void umbra_output_sample_ring_init(
    UmbraOutputSampleRing *ring,
    float *storage,
    uint32_t sample_capacity,
    uint64_t *packet_end_positions,
    uint32_t packet_capacity,
    uint32_t channel_count,
    uint32_t minimum_preroll_sample_count
) {
    ring->storage = storage;
    ring->packet_end_positions = packet_end_positions;
    ring->sample_capacity = sample_capacity;
    ring->packet_capacity = packet_capacity;
    ring->channel_count = channel_count;
    ring->minimum_preroll_sample_count = minimum_preroll_sample_count;
    atomic_init(&ring->read_position, 0);
    atomic_init(&ring->write_position, 0);
    atomic_init(&ring->packet_read_position, 0);
    atomic_init(&ring->packet_write_position, 0);
    atomic_init(&ring->accepted_packets, 0);
    atomic_init(&ring->played_packets, 0);
    atomic_init(&ring->dropped_packets, 0);
    atomic_init(&ring->rejected_packets, 0);
    atomic_init(&ring->scheduled_packets, 0);
    atomic_init(&ring->scheduled_real_samples, 0);
    atomic_init(&ring->rendered_real_samples, 0);
    atomic_init(&ring->rendered_silence_samples, 0);
    atomic_init(&ring->callback_count, 0);
    atomic_init(&ring->underrun_count, 0);
    atomic_init(&ring->rebuffer_count, 0);
    atomic_init(&ring->active_writers, 0);
    atomic_init(&ring->active_callbacks, 0);
    atomic_init(&ring->queue_identity, 0);
    atomic_init(&ring->callback_error, 0);
    atomic_init(&ring->flush_sample_position, 0);
    atomic_init(&ring->flush_packet_position, 0);
    atomic_init(&ring->flush_requested, false);
    atomic_init(&ring->prerolling, true);
    atomic_init(&ring->accepting, false);
    atomic_init(&ring->callback_enabled, false);
}

static inline void umbra_output_sample_ring_set_accepting(
    UmbraOutputSampleRing *ring,
    bool accepting
) {
    atomic_store_explicit(&ring->accepting, accepting, memory_order_release);
}

static inline void umbra_output_sample_ring_set_callback(
    UmbraOutputSampleRing *ring,
    uintptr_t queue_identity,
    bool enabled
) {
    if (enabled) {
        atomic_store_explicit(&ring->queue_identity, queue_identity, memory_order_release);
        atomic_store_explicit(&ring->callback_enabled, true, memory_order_release);
    } else {
        atomic_store_explicit(&ring->callback_enabled, false, memory_order_release);
        atomic_store_explicit(&ring->queue_identity, 0, memory_order_release);
    }
}

static inline uint32_t umbra_output_sample_ring_active_writers(
    const UmbraOutputSampleRing *ring
) {
    return atomic_load_explicit(&ring->active_writers, memory_order_acquire);
}

static inline uint32_t umbra_output_sample_ring_active_callbacks(
    const UmbraOutputSampleRing *ring
) {
    return atomic_load_explicit(&ring->active_callbacks, memory_order_acquire);
}

// reset_counters is used for a new renderer session. When false, pending source
// packets are counted as dropped so a flush retains honest lifetime metrics.
// The caller first disables producer and callback admission and waits for both
// short critical sections to quiesce.
static inline void umbra_output_sample_ring_reset(
    UmbraOutputSampleRing *ring,
    bool reset_counters
) {
    uint64_t packet_read = atomic_load_explicit(&ring->packet_read_position, memory_order_relaxed);
    uint64_t packet_write = atomic_load_explicit(&ring->packet_write_position, memory_order_relaxed);
    uint64_t scheduled = atomic_load_explicit(&ring->scheduled_packets, memory_order_relaxed);
    if (reset_counters) {
        atomic_store_explicit(&ring->accepted_packets, 0, memory_order_relaxed);
        atomic_store_explicit(&ring->played_packets, 0, memory_order_relaxed);
        atomic_store_explicit(&ring->dropped_packets, 0, memory_order_relaxed);
        atomic_store_explicit(&ring->rejected_packets, 0, memory_order_relaxed);
        atomic_store_explicit(&ring->rendered_real_samples, 0, memory_order_relaxed);
        atomic_store_explicit(&ring->rendered_silence_samples, 0, memory_order_relaxed);
        atomic_store_explicit(&ring->callback_count, 0, memory_order_relaxed);
        atomic_store_explicit(&ring->underrun_count, 0, memory_order_relaxed);
        atomic_store_explicit(&ring->rebuffer_count, 0, memory_order_relaxed);
    } else {
        atomic_fetch_add_explicit(
            &ring->dropped_packets,
            packet_write - packet_read + scheduled,
            memory_order_relaxed
        );
    }
    atomic_store_explicit(&ring->read_position, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->write_position, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->packet_read_position, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->packet_write_position, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->scheduled_packets, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->scheduled_real_samples, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->callback_error, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->flush_sample_position, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->flush_packet_position, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->flush_requested, false, memory_order_relaxed);
    atomic_store_explicit(&ring->prerolling, true, memory_order_relaxed);
}

// Publishes an exact discard barrier. Samples committed after these positions
// remain eligible for the next callback, so a concurrent post-flush producer
// packet is never accidentally discarded.
static inline void umbra_output_sample_ring_request_flush(UmbraOutputSampleRing *ring) {
    uint64_t sample_position = atomic_load_explicit(&ring->write_position, memory_order_acquire);
    uint64_t packet_position = atomic_load_explicit(
        &ring->packet_write_position,
        memory_order_acquire
    );
    atomic_store_explicit(
        &ring->flush_sample_position,
        sample_position,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &ring->flush_packet_position,
        packet_position,
        memory_order_relaxed
    );
    atomic_store_explicit(&ring->prerolling, true, memory_order_release);
    atomic_store_explicit(&ring->flush_requested, true, memory_order_release);
}

// Returns 1 when accepted, 0 while stopped, -1 when the packet-count bound is
// full, -2 when the duration bound is full, and -3 for invalid input.
static inline int umbra_output_sample_ring_write_planar(
    UmbraOutputSampleRing *ring,
    float * _Nonnull const * _Nonnull channels,
    uint32_t frame_count,
    uint32_t channel_count
) {
    atomic_fetch_add_explicit(&ring->active_writers, 1, memory_order_acquire);
    if (!atomic_load_explicit(&ring->accepting, memory_order_acquire)) {
        atomic_fetch_sub_explicit(&ring->active_writers, 1, memory_order_release);
        return 0;
    }
    if (channels == NULL || frame_count == 0 || channel_count != ring->channel_count) {
        atomic_fetch_add_explicit(&ring->rejected_packets, 1, memory_order_relaxed);
        atomic_fetch_sub_explicit(&ring->active_writers, 1, memory_order_release);
        return -3;
    }

    uint64_t packet_write = atomic_load_explicit(&ring->packet_write_position, memory_order_relaxed);
    uint64_t packet_read = atomic_load_explicit(&ring->packet_read_position, memory_order_acquire);
    if (packet_write - packet_read >= ring->packet_capacity) {
        atomic_fetch_add_explicit(&ring->rejected_packets, 1, memory_order_relaxed);
        atomic_fetch_sub_explicit(&ring->active_writers, 1, memory_order_release);
        return -1;
    }

    uint64_t sample_count = (uint64_t)frame_count * channel_count;
    uint64_t write_position = atomic_load_explicit(&ring->write_position, memory_order_relaxed);
    uint64_t read_position = atomic_load_explicit(&ring->read_position, memory_order_acquire);
    if (sample_count > ring->sample_capacity ||
        sample_count > ring->sample_capacity - (write_position - read_position)) {
        atomic_fetch_add_explicit(&ring->dropped_packets, 1, memory_order_relaxed);
        atomic_fetch_sub_explicit(&ring->active_writers, 1, memory_order_release);
        return -2;
    }

    uint32_t write_index = (uint32_t)(write_position % ring->sample_capacity);
    for (uint32_t frame = 0; frame < frame_count; frame++) {
        for (uint32_t channel = 0; channel < channel_count; channel++) {
            ring->storage[write_index] = channels[channel][frame];
            write_index++;
            if (write_index == ring->sample_capacity) {
                write_index = 0;
            }
        }
    }
    uint64_t end_position = write_position + sample_count;
    ring->packet_end_positions[packet_write % ring->packet_capacity] = end_position;
    atomic_store_explicit(&ring->write_position, end_position, memory_order_relaxed);
    atomic_store_explicit(&ring->packet_write_position, packet_write + 1, memory_order_release);
    atomic_fetch_add_explicit(&ring->accepted_packets, 1, memory_order_relaxed);
    atomic_fetch_sub_explicit(&ring->active_writers, 1, memory_order_release);
    return 1;
}

static inline void umbra_output_sample_ring_note_rejected(UmbraOutputSampleRing *ring) {
    atomic_fetch_add_explicit(&ring->rejected_packets, 1, memory_order_relaxed);
}

static inline bool umbra_output_sample_ring_begin_callback(
    UmbraOutputSampleRing *ring,
    uintptr_t queue_identity
) {
    atomic_fetch_add_explicit(&ring->active_callbacks, 1, memory_order_acquire);
    bool enabled = atomic_load_explicit(&ring->callback_enabled, memory_order_acquire);
    uintptr_t expected = atomic_load_explicit(&ring->queue_identity, memory_order_acquire);
    if (!enabled || expected != queue_identity) {
        atomic_fetch_sub_explicit(&ring->active_callbacks, 1, memory_order_release);
        return false;
    }
    return true;
}

static inline void umbra_output_sample_ring_end_callback(UmbraOutputSampleRing *ring) {
    atomic_fetch_sub_explicit(&ring->active_callbacks, 1, memory_order_release);
}

// Consumes the metadata from this buffer's previous trip through AudioQueue,
// then fills one complete hardware quantum or one complete quantum of silence.
// Partial PCM is never consumed and padded: startup and starvation re-enter a
// pre-roll barrier so source chronology remains intact. No allocation, lock,
// logging, or dispatch.
static inline void umbra_output_sample_ring_fill(
    UmbraOutputSampleRing *ring,
    float *output,
    uint32_t requested_sample_count,
    UmbraOutputBufferMetadata *metadata
) {
    if (metadata->packet_count > 0) {
        atomic_fetch_add_explicit(&ring->played_packets, metadata->packet_count, memory_order_relaxed);
        atomic_fetch_sub_explicit(&ring->scheduled_packets, metadata->packet_count, memory_order_relaxed);
    }
    if (metadata->real_sample_count > 0) {
        atomic_fetch_sub_explicit(
            &ring->scheduled_real_samples,
            metadata->real_sample_count,
            memory_order_relaxed
        );
    }
    metadata->packet_count = 0;
    metadata->real_sample_count = 0;

    uint64_t read_position = atomic_load_explicit(&ring->read_position, memory_order_relaxed);
    uint64_t packet_read = atomic_load_explicit(&ring->packet_read_position, memory_order_relaxed);
    if (atomic_exchange_explicit(&ring->flush_requested, false, memory_order_acq_rel)) {
        uint64_t flush_sample_position = atomic_load_explicit(
            &ring->flush_sample_position,
            memory_order_relaxed
        );
        uint64_t flush_packet_position = atomic_load_explicit(
            &ring->flush_packet_position,
            memory_order_relaxed
        );
        if (flush_packet_position > packet_read) {
            atomic_fetch_add_explicit(
                &ring->dropped_packets,
                flush_packet_position - packet_read,
                memory_order_relaxed
            );
            packet_read = flush_packet_position;
            read_position = flush_sample_position;
            atomic_store_explicit(&ring->read_position, read_position, memory_order_release);
            atomic_store_explicit(
                &ring->packet_read_position,
                packet_read,
                memory_order_release
            );
        }
        atomic_store_explicit(&ring->prerolling, true, memory_order_release);
    }
    uint64_t packet_write = atomic_load_explicit(&ring->packet_write_position, memory_order_acquire);
    uint64_t available_samples = 0;
    if (packet_write > packet_read) {
        uint64_t last_end = ring->packet_end_positions[(packet_write - 1) % ring->packet_capacity];
        available_samples = last_end - read_position;
    }
    if (requested_sample_count == 0) {
        atomic_fetch_add_explicit(&ring->callback_count, 1, memory_order_relaxed);
        return;
    }

    uint64_t required_preroll_samples = ring->minimum_preroll_sample_count;
    if (required_preroll_samples < requested_sample_count) {
        required_preroll_samples = requested_sample_count;
    }
    bool prerolling = atomic_load_explicit(&ring->prerolling, memory_order_acquire);
    bool emit_silence = false;
    if (prerolling) {
        if (available_samples < required_preroll_samples) {
            emit_silence = true;
        } else {
            atomic_store_explicit(&ring->prerolling, false, memory_order_release);
        }
    } else if (available_samples < requested_sample_count) {
        atomic_store_explicit(&ring->prerolling, true, memory_order_release);
        atomic_fetch_add_explicit(&ring->rebuffer_count, 1, memory_order_relaxed);
        emit_silence = true;
    }

    if (emit_silence) {
        memset(output, 0, requested_sample_count * sizeof(float));
        atomic_fetch_add_explicit(&ring->underrun_count, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(
            &ring->rendered_silence_samples,
            requested_sample_count,
            memory_order_relaxed
        );
        atomic_fetch_add_explicit(&ring->callback_count, 1, memory_order_relaxed);
        return;
    }

    uint32_t real_sample_count = requested_sample_count;

    uint32_t read_index = (uint32_t)(read_position % ring->sample_capacity);
    uint32_t first_count = real_sample_count;
    if (first_count > ring->sample_capacity - read_index) {
        first_count = ring->sample_capacity - read_index;
    }
    if (first_count > 0) {
        memcpy(output, ring->storage + read_index, first_count * sizeof(float));
    }
    if (real_sample_count > first_count) {
        memcpy(
            output + first_count,
            ring->storage,
            (real_sample_count - first_count) * sizeof(float)
        );
    }
    uint64_t new_read_position = read_position + real_sample_count;
    uint32_t completed_packets = 0;
    while (packet_read < packet_write &&
           ring->packet_end_positions[packet_read % ring->packet_capacity] <= new_read_position) {
        packet_read++;
        completed_packets++;
    }
    atomic_store_explicit(&ring->read_position, new_read_position, memory_order_release);
    atomic_store_explicit(&ring->packet_read_position, packet_read, memory_order_release);
    metadata->packet_count = completed_packets;
    metadata->real_sample_count = real_sample_count;
    if (completed_packets > 0) {
        atomic_fetch_add_explicit(&ring->scheduled_packets, completed_packets, memory_order_relaxed);
    }
    if (real_sample_count > 0) {
        atomic_fetch_add_explicit(
            &ring->scheduled_real_samples,
            real_sample_count,
            memory_order_relaxed
        );
        atomic_fetch_add_explicit(
            &ring->rendered_real_samples,
            real_sample_count,
            memory_order_relaxed
        );
    }
    atomic_fetch_add_explicit(&ring->callback_count, 1, memory_order_relaxed);
}

static inline void umbra_output_sample_ring_callback_enqueue_failed(
    UmbraOutputSampleRing *ring,
    UmbraOutputBufferMetadata *metadata,
    int32_t status
) {
    if (metadata->packet_count > 0) {
        atomic_fetch_sub_explicit(&ring->scheduled_packets, metadata->packet_count, memory_order_relaxed);
        atomic_fetch_add_explicit(&ring->dropped_packets, metadata->packet_count, memory_order_relaxed);
    }
    if (metadata->real_sample_count > 0) {
        atomic_fetch_sub_explicit(
            &ring->scheduled_real_samples,
            metadata->real_sample_count,
            memory_order_relaxed
        );
    }
    metadata->packet_count = 0;
    metadata->real_sample_count = 0;
    atomic_store_explicit(&ring->callback_error, status, memory_order_release);
    atomic_store_explicit(&ring->callback_enabled, false, memory_order_release);
}

static inline uint64_t umbra_output_sample_ring_accepted_packets(const UmbraOutputSampleRing *ring) {
    return atomic_load_explicit(&ring->accepted_packets, memory_order_acquire);
}
static inline uint64_t umbra_output_sample_ring_played_packets(const UmbraOutputSampleRing *ring) {
    return atomic_load_explicit(&ring->played_packets, memory_order_acquire);
}
static inline uint64_t umbra_output_sample_ring_dropped_packets(const UmbraOutputSampleRing *ring) {
    return atomic_load_explicit(&ring->dropped_packets, memory_order_acquire);
}
static inline uint64_t umbra_output_sample_ring_rejected_packets(const UmbraOutputSampleRing *ring) {
    return atomic_load_explicit(&ring->rejected_packets, memory_order_acquire);
}
static inline uint64_t umbra_output_sample_ring_queued_packets(const UmbraOutputSampleRing *ring) {
    uint64_t write = atomic_load_explicit(&ring->packet_write_position, memory_order_acquire);
    uint64_t read = atomic_load_explicit(&ring->packet_read_position, memory_order_acquire);
    return write - read;
}
static inline uint64_t umbra_output_sample_ring_scheduled_packets(const UmbraOutputSampleRing *ring) {
    return atomic_load_explicit(&ring->scheduled_packets, memory_order_acquire);
}
static inline uint64_t umbra_output_sample_ring_queued_samples(const UmbraOutputSampleRing *ring) {
    uint64_t write = atomic_load_explicit(&ring->write_position, memory_order_acquire);
    uint64_t read = atomic_load_explicit(&ring->read_position, memory_order_acquire);
    uint64_t scheduled = atomic_load_explicit(&ring->scheduled_real_samples, memory_order_acquire);
    return write - read + scheduled;
}
static inline uint64_t umbra_output_sample_ring_rendered_real_samples(const UmbraOutputSampleRing *ring) {
    return atomic_load_explicit(&ring->rendered_real_samples, memory_order_acquire);
}
static inline uint64_t umbra_output_sample_ring_rendered_silence_samples(const UmbraOutputSampleRing *ring) {
    return atomic_load_explicit(&ring->rendered_silence_samples, memory_order_acquire);
}
static inline uint64_t umbra_output_sample_ring_callback_count(const UmbraOutputSampleRing *ring) {
    return atomic_load_explicit(&ring->callback_count, memory_order_acquire);
}
static inline uint64_t umbra_output_sample_ring_underrun_count(const UmbraOutputSampleRing *ring) {
    return atomic_load_explicit(&ring->underrun_count, memory_order_acquire);
}
static inline uint64_t umbra_output_sample_ring_rebuffer_count(const UmbraOutputSampleRing *ring) {
    return atomic_load_explicit(&ring->rebuffer_count, memory_order_acquire);
}
static inline int32_t umbra_output_sample_ring_callback_error(const UmbraOutputSampleRing *ring) {
    return atomic_load_explicit(&ring->callback_error, memory_order_acquire);
}

#endif
