/**
 * @file CLSPCore.cpp
 * @brief Fail-closed implementation of Umbra's versioned LSP C ABI.
 */

#include "CLSPCore.h"

#include "core/core.h"
#include "runtime/BufferInternal.h"
#include "runtime/Runtime.h"

#include <atomic>
#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <memory>
#include <mutex>
#include <new>
#include <shared_mutex>

extern "C" std::uint8_t clsp_apple_input_capture_apply_lspg(
  clsp_apple_input_capture_t *capture,
  clsp_const_byte_span_t payload
);

#ifndef CLSP_CORE_HAS_WOLFSSL
  #define CLSP_CORE_HAS_WOLFSSL 0
#endif

#ifndef CLSP_CORE_HAS_LIBSRTP
  #define CLSP_CORE_HAS_LIBSRTP 0
#endif

#ifndef CLSP_CORE_HAS_RUNTIME
  #define CLSP_CORE_HAS_RUNTIME 0
#endif

static_assert(lumen::lsp::core_api_version == 1U);

/** @brief Native core object hidden behind `clsp_core_t`. */
struct clsp_core {
  std::atomic<std::uint32_t> references {1};  ///< Explicit ABI ownership count.
  std::atomic<std::uint32_t> state {CLSP_LIFECYCLE_CREATED};  ///< Coarse lifecycle state.
  std::atomic<bool> callback_active {false};  ///< Rejects reentrant ABI operations.
  std::atomic<bool> audio_callback_active {false};  ///< Prevents recursive complete-audio delivery.
  std::atomic<bool> video_callback_active {false};  ///< Prevents recursive complete-frame delivery.
  std::mutex apple_capture_mutex;  ///< Serializes low-rate LSPG application with capture teardown.
  mutable std::shared_mutex runtime_mutex;  ///< Prevents runtime reclamation during ABI calls.
  clsp_apple_input_capture_t *apple_capture {};  ///< Active native controller-output owner.
  umbra::lsp::Runtime *runtime {};  ///< Owned native socket/security/control runtime.
  clsp_configuration_t configuration {};  ///< Caller configuration copied at creation.
  clsp_callbacks_t callbacks {};  ///< Callback table copied at creation.
  std::atomic<std::uint64_t> received_datagrams {0};  ///< Authenticated receive count.
  std::atomic<std::uint64_t> transmitted_datagrams {0};  ///< Socket submission count.
  std::atomic<std::uint64_t> dropped_datagrams {0};  ///< Bounded drop count.
  std::atomic<std::uint64_t> authentication_failures {0};  ///< Authentication failure count.
  std::atomic<std::uint64_t> video_received_ip_bytes {0};  ///< Complete authenticated video IP bytes.
  std::atomic<std::uint64_t> congestion_feedback_ip_bytes {0};  ///< Complete submitted CCFB IP bytes.
  std::atomic<std::uint64_t> congestion_feedback_packets {0};  ///< Submitted CCFB packets.
  std::atomic<std::uint64_t> video_ecn_unknown_packets {0};  ///< Packets missing ECN ancillary evidence.
  std::atomic<std::uint64_t> video_ecn_ce_packets {0};  ///< Authenticated ECN-CE packets.
  std::atomic<std::uint64_t> path_probes_sent {0};  ///< Exact LSPP submissions.
  std::atomic<std::uint64_t> path_probes_acknowledged {0};  ///< Exact probe acknowledgements.
  std::atomic<std::uint64_t> path_probe_timeouts {0};  ///< Three-attempt probe timeouts.

  /** @brief Release the explicitly retained callback context. */
  ~clsp_core() {
    if (runtime != nullptr) {
      (void)runtime->stop();
      delete runtime;
    }
    if (callbacks.context != nullptr) {
      callbacks.release_context(callbacks.context);
    }
  }
};

/** @brief Native retained buffer hidden behind `clsp_buffer_t`. */
struct clsp_buffer {
  std::atomic<std::uint32_t> references {1};  ///< Explicit ABI ownership count.
  const std::uint8_t *data = nullptr;  ///< Native-owned immutable bytes.
  std::size_t length = 0;  ///< Immutable byte count.
  void *context = nullptr;  ///< Private storage owner or slot context.
  void (*destroy)(clsp_buffer_t *) = nullptr;  ///< Native storage destruction function.
};

namespace umbra::lsp {
  /** @brief One preallocated complete-frame slot embedded in its owning pool. */
  struct retained_frame_slot {
    clsp_buffer_t abi;  ///< Public opaque buffer prefix.
    std::atomic<bool> occupied {false};  ///< Lock-free slot admission flag.
    retained_frame_pool *owner {};  ///< Pool retained while this slot is externally owned.
    std::uint8_t *storage {};  ///< Fixed-capacity bytes inside the pool allocation.
  };

  /** @brief Ref-counted allocation containing every complete-frame slot and byte region. */
  struct retained_frame_pool {
    std::atomic<std::uint32_t> references {1};  ///< Runtime owner plus outstanding ABI handles.
    std::size_t maximum_frame_bytes {};  ///< Capacity of each slot.
    std::size_t slot_count {};  ///< Number of fixed slots.
    std::unique_ptr<std::uint8_t[]> bytes;  ///< Contiguous complete-frame storage.
    std::unique_ptr<retained_frame_slot[]> slots;  ///< Fixed slot metadata.
  };

  namespace {
    /** @brief Release one pool reference and its entire preallocated storage at zero. */
    void release_pool_reference(retained_frame_pool *pool) noexcept {
      if (pool != nullptr && pool->references.fetch_sub(1, std::memory_order_acq_rel) == 1U) {
        delete pool;
      }
    }

    /** @brief Return one buffer slot to the pool after its final external release. */
    void recycle_retained_frame_buffer(clsp_buffer_t *buffer) noexcept {
      if (buffer == nullptr || buffer->context == nullptr) {
        return;
      }
      auto *slot = static_cast<retained_frame_slot *>(buffer->context);
      auto *owner = slot->owner;
      buffer->data = nullptr;
      buffer->length = 0;
      slot->occupied.store(false, std::memory_order_release);
      release_pool_reference(owner);
    }
  }  // namespace

  retained_frame_pool *create_retained_frame_pool(
    const std::size_t maximum_frame_bytes,
    const std::size_t slot_count
  ) noexcept {
    if (maximum_frame_bytes == 0 || slot_count == 0 ||
        maximum_frame_bytes > std::numeric_limits<std::size_t>::max() / slot_count) {
      return nullptr;
    }
    auto pool = std::unique_ptr<retained_frame_pool> {new (std::nothrow) retained_frame_pool};
    if (!pool) {
      return nullptr;
    }
    pool->bytes.reset(new (std::nothrow) std::uint8_t[maximum_frame_bytes * slot_count]);
    pool->slots.reset(new (std::nothrow) retained_frame_slot[slot_count]);
    if (!pool->bytes || !pool->slots) {
      return nullptr;
    }
    pool->maximum_frame_bytes = maximum_frame_bytes;
    pool->slot_count = slot_count;
    for (std::size_t index = 0; index < slot_count; ++index) {
      auto &slot = pool->slots[index];
      slot.owner = pool.get();
      slot.storage = pool->bytes.get() + index * maximum_frame_bytes;
      slot.abi.context = &slot;
      slot.abi.destroy = recycle_retained_frame_buffer;
    }
    return pool.release();
  }

  void release_retained_frame_pool(retained_frame_pool *pool) noexcept {
    release_pool_reference(pool);
  }

  clsp_buffer_t *acquire_retained_frame_buffer(
    retained_frame_pool *pool,
    const std::size_t frame_bytes
  ) noexcept {
    if (pool == nullptr || frame_bytes == 0 || frame_bytes > pool->maximum_frame_bytes) {
      return nullptr;
    }
    for (std::size_t index = 0; index < pool->slot_count; ++index) {
      auto &slot = pool->slots[index];
      auto expected = false;
      if (!slot.occupied.compare_exchange_strong(expected, true, std::memory_order_acq_rel)) {
        continue;
      }
      pool->references.fetch_add(1, std::memory_order_relaxed);
      slot.abi.references.store(1, std::memory_order_relaxed);
      slot.abi.data = slot.storage;
      slot.abi.length = frame_bytes;
      return &slot.abi;
    }
    return nullptr;
  }

  std::span<std::uint8_t> mutable_retained_frame_bytes(clsp_buffer_t *buffer) noexcept {
    if (buffer == nullptr || buffer->context == nullptr || buffer->data == nullptr || buffer->length == 0) {
      return {};
    }
    const auto *slot = static_cast<const retained_frame_slot *>(buffer->context);
    if (&slot->abi != buffer || !slot->occupied.load(std::memory_order_acquire) || slot->storage != buffer->data) {
      return {};
    }
    return {slot->storage, buffer->length};
  }

  bool resize_retained_frame_buffer(
    clsp_buffer_t *buffer,
    const std::size_t frame_bytes
  ) noexcept {
    if (buffer == nullptr || buffer->context == nullptr || frame_bytes == 0) {
      return false;
    }
    const auto *slot = static_cast<const retained_frame_slot *>(buffer->context);
    if (&slot->abi != buffer || slot->owner == nullptr ||
        !slot->occupied.load(std::memory_order_acquire) ||
        slot->storage != buffer->data || frame_bytes > slot->owner->maximum_frame_bytes) {
      return false;
    }
    buffer->length = frame_bytes;
    return true;
  }
}  // namespace umbra::lsp

namespace {
  inline constexpr std::size_t maximum_callback_stack_depth = 16;  ///< Bounded nested callbacks across distinct cores.
  thread_local std::array<const clsp_core_t *, maximum_callback_stack_depth> active_callback_cores {};  ///< Current thread callback owners.
  thread_local std::size_t active_callback_depth {};  ///< Occupied callback-owner entries.

  /** @brief Return whether this thread is executing a callback from `core`. */
  [[nodiscard]] bool callback_stack_contains(const clsp_core_t *core) noexcept {
    for (std::size_t index = 0; index < active_callback_depth; ++index) {
      if (active_callback_cores[index] == core) {
        return true;
      }
    }
    return false;
  }

  /** @brief Bounded callback-stack marker enabling same-core reentry rejection. */
  class callback_core_scope {
  public:
    explicit callback_core_scope(const clsp_core_t *core) noexcept:
        active_ {active_callback_depth < active_callback_cores.size()} {
      if (active_) {
        active_callback_cores[active_callback_depth++] = core;
      }
    }

    callback_core_scope(const callback_core_scope &) = delete;
    callback_core_scope &operator=(const callback_core_scope &) = delete;

    ~callback_core_scope() {
      if (active_) {
        active_callback_cores[--active_callback_depth] = nullptr;
      }
    }

    [[nodiscard]] bool active() const noexcept {
      return active_;
    }

  private:
    bool active_ {};  ///< Whether this scope owns one stack entry.
  };

  /** @brief Invoke one ABI operation while preventing runtime reclamation. */
  template<typename Operation>
  [[nodiscard]] clsp_status_t with_runtime(
    clsp_core_t *core,
    Operation &&operation
  ) noexcept {
    if (callback_stack_contains(core)) {
      return CLSP_STATUS_REENTRANT_CALLBACK;
    }
    std::shared_lock runtime_lock(core->runtime_mutex);
    if (core->runtime == nullptr) {
      return CLSP_STATUS_NOT_AUTHENTICATED;
    }
    return operation(*core->runtime);
  }

  /** @brief Return provider flags compiled into this target. */
  [[nodiscard]] constexpr std::uint32_t compiled_provider_flags() noexcept {
    return (CLSP_CORE_HAS_WOLFSSL ? CLSP_PROVIDER_WOLFSSL : 0U) |
           (CLSP_CORE_HAS_LIBSRTP ? CLSP_PROVIDER_LIBSRTP : 0U);
  }

  /** @brief Validate a version-one construction configuration. */
  [[nodiscard]] constexpr clsp_status_t validate_configuration(
    const clsp_configuration_t &configuration
  ) noexcept {
    if (configuration.abi_version != CLSP_CORE_ABI_VERSION ||
        configuration.structure_size != sizeof(clsp_configuration_t)) {
      return CLSP_STATUS_ABI_MISMATCH;
    }
    if (configuration.port == 0 || configuration.reserved_zero != 0 ||
        configuration.reserved_flags != 0 || configuration.telemetry_interval_milliseconds < 250U ||
        configuration.handshake_timeout_milliseconds < 1'000U ||
        configuration.handshake_timeout_milliseconds > 30'000U) {
      return CLSP_STATUS_INVALID_CONFIGURATION;
    }
    if (configuration.profile != CLSP_PROFILE_ADAPTIVE_LOW_LATENCY &&
        configuration.profile != CLSP_PROFILE_COMPETITION_LAN) {
      return CLSP_STATUS_INVALID_CONFIGURATION;
    }
    if (configuration.profile == CLSP_PROFILE_COMPETITION_LAN &&
        configuration.competition_capacity_mbps == 0) {
      return CLSP_STATUS_INVALID_CONFIGURATION;
    }
    return CLSP_STATUS_OK;
  }

  /** @brief Validate the complete ABI-v2 video tuple before runtime admission. */
  [[nodiscard]] constexpr bool validate_video_configuration(
    const clsp_video_configuration_t &value
  ) noexcept {
    const auto valid_profile =
      (value.codec == CLSP_VIDEO_CODEC_H264 &&
       ((value.profile == CLSP_VIDEO_PROFILE_H264_HIGH && value.pixel_format == CLSP_VIDEO_PIXEL_420_8) ||
        (value.profile == CLSP_VIDEO_PROFILE_H264_HIGH_444 && value.pixel_format == CLSP_VIDEO_PIXEL_444_8))) ||
      (value.codec == CLSP_VIDEO_CODEC_HEVC &&
       ((value.profile == CLSP_VIDEO_PROFILE_HEVC_MAIN && value.pixel_format == CLSP_VIDEO_PIXEL_420_8) ||
        (value.profile == CLSP_VIDEO_PROFILE_HEVC_MAIN10 && value.pixel_format == CLSP_VIDEO_PIXEL_420_10) ||
        (value.profile == CLSP_VIDEO_PROFILE_HEVC_REXT &&
         (value.pixel_format == CLSP_VIDEO_PIXEL_444_8 || value.pixel_format == CLSP_VIDEO_PIXEL_444_10)))) ||
      (value.codec == CLSP_VIDEO_CODEC_AV1 &&
       ((value.profile == CLSP_VIDEO_PROFILE_AV1_MAIN &&
         (value.pixel_format == CLSP_VIDEO_PIXEL_420_8 || value.pixel_format == CLSP_VIDEO_PIXEL_420_10)) ||
        (value.profile == CLSP_VIDEO_PROFILE_AV1_HIGH &&
         (value.pixel_format == CLSP_VIDEO_PIXEL_444_8 || value.pixel_format == CLSP_VIDEO_PIXEL_444_10))));
    const auto sdr = value.color_primaries == 1U && value.transfer_characteristics == 1U &&
                     value.matrix_coefficients == 1U;
    const auto hdr = value.codec != CLSP_VIDEO_CODEC_H264 &&
                     (value.pixel_format == CLSP_VIDEO_PIXEL_420_10 || value.pixel_format == CLSP_VIDEO_PIXEL_444_10) &&
                     value.full_range == 0U && value.color_primaries == 9U &&
                     (value.transfer_characteristics == 16U || value.transfer_characteristics == 18U) &&
                     value.matrix_coefficients == 9U;
    const auto flexfec_disabled = value.flexfec_ssrc == 0U && value.flexfec_payload_type == 0U &&
                                  value.flexfec_repair_window_microseconds == 0U &&
                                  value.flexfec_maximum_group_packets == 0U;
    const auto flexfec_enabled = value.flexfec_ssrc != 0U && value.flexfec_ssrc != value.primary_ssrc &&
                                 value.flexfec_payload_type >= 96U && value.flexfec_payload_type <= 127U &&
                                 value.flexfec_payload_type != value.primary_payload_type &&
                                 value.flexfec_repair_window_microseconds != 0U &&
                                 value.flexfec_repair_window_microseconds <= value.maximum_frame_age_microseconds &&
                                 value.flexfec_maximum_group_packets == 15U;
    const auto rtx_disabled = value.rtx_ssrc == 0U && value.rtx_payload_type == 0U &&
                              value.rtx_associated_payload_type == 0U;
    const auto rtx_enabled = value.rtx_ssrc != 0U && value.rtx_ssrc != value.primary_ssrc &&
                             value.rtx_ssrc != value.flexfec_ssrc && value.rtx_payload_type >= 96U &&
                             value.rtx_payload_type <= 127U && value.rtx_payload_type != value.primary_payload_type &&
                             value.rtx_payload_type != value.flexfec_payload_type &&
                             value.rtx_associated_payload_type == value.primary_payload_type;
    return value.abi_version == CLSP_CORE_ABI_VERSION &&
           value.structure_size == sizeof(clsp_video_configuration_t) &&
           value.stream_generation != 0U && value.video_generation != 0U && value.primary_ssrc != 0U &&
           value.clock_rate == 90'000U && value.width >= 1U && value.width <= 16'384U &&
           value.height >= 1U && value.height <= 16'384U && value.refresh_numerator != 0U &&
           value.refresh_denominator != 0U && value.bitrate >= 1'000U && value.bitrate <= 1'000'000'000U &&
           value.maximum_access_unit_bytes != 0U && value.maximum_access_unit_bytes <= 16U * 1'024U * 1'024U &&
           value.maximum_frame_age_microseconds != 0U && value.frame_id_origin != 0U &&
           value.recovery_epoch != 0U && value.udp_payload_size == 1'200U &&
           value.primary_payload_type >= 96U && value.primary_payload_type <= 127U && valid_profile &&
           value.full_range <= 1U && (sdr || hdr) && value.delivery == CLSP_VIDEO_DELIVERY_COMPLETE_ACCESS_UNIT &&
           ((value.codec == CLSP_VIDEO_CODEC_AV1 && value.payload_format == CLSP_VIDEO_PAYLOAD_AV1_LOW_OVERHEAD_OBU) ||
            (value.codec != CLSP_VIDEO_CODEC_AV1 && value.payload_format == CLSP_VIDEO_PAYLOAD_ANNEX_B)) &&
           value.decoder_surfaces >= 2U && value.decoder_surfaces <= 4U &&
           value.frame_marking_extension == 1U && value.absolute_capture_extension == 2U &&
           value.frame_id_extension == 3U && value.input_watermark_extension == 4U &&
           value.encoder_timing_extension == 5U &&
           (flexfec_disabled || flexfec_enabled) && (rtx_disabled || rtx_enabled);
  }

  /** @brief Publish one non-reentrant lifecycle event without protocol locks held. */
  void publish_lifecycle(clsp_core_t *core, const std::uint32_t state) noexcept {
    core->state.store(state, std::memory_order_release);
    if (core->callbacks.lifecycle == nullptr) {
      return;
    }
    auto expected = false;
    if (!core->callback_active.compare_exchange_strong(expected, true, std::memory_order_acq_rel)) {
      return;
    }
    clsp_core_retain(core);
    const clsp_lifecycle_event_t event {
      .abi_version = CLSP_CORE_ABI_VERSION,
      .structure_size = sizeof(clsp_lifecycle_event_t),
      .state = state,
      .reserved_zero = 0,
    };
    callback_core_scope callback_scope {core};
    if (!callback_scope.active()) {
      core->callback_active.store(false, std::memory_order_release);
      clsp_core_release(core);
      return;
    }
    core->callbacks.lifecycle(core->callbacks.context, &event);
    core->callback_active.store(false, std::memory_order_release);
    clsp_core_release(core);
  }

  /** @brief Publish one authenticated control event without core locks held. */
  void publish_control(clsp_core_t *core, const clsp_control_event_t &event) noexcept {
    if (core->callbacks.control == nullptr) {
      return;
    }
    auto expected = false;
    if (!core->callback_active.compare_exchange_strong(expected, true, std::memory_order_acq_rel)) {
      return;
    }
    clsp_core_retain(core);
    callback_core_scope callback_scope {core};
    if (!callback_scope.active()) {
      core->callback_active.store(false, std::memory_order_release);
      clsp_core_release(core);
      return;
    }
    core->callbacks.control(core->callbacks.context, &event);
    core->callback_active.store(false, std::memory_order_release);
    clsp_core_release(core);
  }

  /** @brief Receive one native runtime lifecycle transition. */
  void runtime_lifecycle(void *context, const std::uint32_t state) noexcept {
    publish_lifecycle(static_cast<clsp_core_t *>(context), state);
  }

  /** @brief Receive one native authenticated LSPC frame. */
  void runtime_control(void *context, const clsp_control_event_t &event) noexcept {
    publish_control(static_cast<clsp_core_t *>(context), event);
  }

  /** @brief Publish one authenticated complete Opus packet. */
  void runtime_audio_packet(void *context, const clsp_audio_packet_event_t &event) noexcept {
    auto *core = static_cast<clsp_core_t *>(context);
    if (core->callbacks.audio_packet == nullptr) return;
    auto expected = false;
    if (!core->audio_callback_active.compare_exchange_strong(expected, true, std::memory_order_acq_rel)) return;
    clsp_core_retain(core);
    callback_core_scope callback_scope {core};
    if (!callback_scope.active()) {
      core->audio_callback_active.store(false, std::memory_order_release);
      clsp_core_release(core);
      return;
    }
    core->callbacks.audio_packet(core->callbacks.context, &event);
    core->audio_callback_active.store(false, std::memory_order_release);
    clsp_core_release(core);
  }

  /** @brief Publish one authenticated audio sender-report timeline. */
  void runtime_audio_timing(void *context, const clsp_audio_timing_event_t &event) noexcept {
    auto *core = static_cast<clsp_core_t *>(context);
    if (core->callbacks.audio_timing == nullptr) return;
    auto expected = false;
    if (!core->audio_callback_active.compare_exchange_strong(expected, true, std::memory_order_acq_rel)) return;
    clsp_core_retain(core);
    callback_core_scope callback_scope {core};
    if (!callback_scope.active()) {
      core->audio_callback_active.store(false, std::memory_order_release);
      clsp_core_release(core);
      return;
    }
    core->callbacks.audio_timing(core->callbacks.context, &event);
    core->audio_callback_active.store(false, std::memory_order_release);
    clsp_core_release(core);
  }

  /** @brief Transfer one retained complete frame to the coarse product callback.
   */
  void runtime_video_frame(void *context, const clsp_video_frame_event_t &event) noexcept {
    auto *core = static_cast<clsp_core_t *>(context);
    if (core->callbacks.video_access_unit == nullptr) {
      clsp_buffer_release(event.frame);
      return;
    }
    auto expected = false;
    if (!core->video_callback_active.compare_exchange_strong(
          expected,
          true,
          std::memory_order_acq_rel
        )) {
      clsp_buffer_release(event.frame);
      return;
    }
    expected = false;
    if (!core->callback_active.compare_exchange_strong(
          expected,
          true,
          std::memory_order_acq_rel
        )) {
      core->video_callback_active.store(false, std::memory_order_release);
      clsp_buffer_release(event.frame);
      return;
    }
    clsp_core_retain(core);
    callback_core_scope callback_scope {core};
    if (!callback_scope.active()) {
      core->callback_active.store(false, std::memory_order_release);
      core->video_callback_active.store(false, std::memory_order_release);
      clsp_buffer_release(event.frame);
      clsp_core_release(core);
      return;
    }
    core->callbacks.video_access_unit(core->callbacks.context, &event);
    core->callback_active.store(false, std::memory_order_release);
    core->video_callback_active.store(false, std::memory_order_release);
    clsp_core_release(core);
  }

  /** @brief Publish one low-rate authenticated path-probe lifecycle event. */
  bool runtime_path_probe(void *context, const clsp_path_probe_event_t &event) noexcept {
    auto *core = static_cast<clsp_core_t *>(context);
    if (core->callbacks.path_probe == nullptr) {
      return true;
    }
    auto expected = false;
    if (!core->callback_active.compare_exchange_strong(expected, true, std::memory_order_acq_rel)) {
      return false;
    }
    clsp_core_retain(core);
    callback_core_scope callback_scope {core};
    if (!callback_scope.active()) {
      core->callback_active.store(false, std::memory_order_release);
      clsp_core_release(core);
      return false;
    }
    core->callbacks.path_probe(core->callbacks.context, &event);
    core->callback_active.store(false, std::memory_order_release);
    clsp_core_release(core);
    return true;
  }

  /** @brief Accumulate one native runtime telemetry counter. */
  void runtime_counter(
    void *context,
    const std::uint32_t counter,
    const std::uint64_t amount
  ) noexcept {
    auto *core = static_cast<clsp_core_t *>(context);
    switch (static_cast<umbra::lsp::RuntimeCounter>(counter)) {
      case umbra::lsp::RuntimeCounter::received:
        core->received_datagrams.fetch_add(amount, std::memory_order_relaxed);
        return;
      case umbra::lsp::RuntimeCounter::transmitted:
        core->transmitted_datagrams.fetch_add(amount, std::memory_order_relaxed);
        return;
      case umbra::lsp::RuntimeCounter::dropped:
        core->dropped_datagrams.fetch_add(amount, std::memory_order_relaxed);
        return;
      case umbra::lsp::RuntimeCounter::authentication_failure:
        core->authentication_failures.fetch_add(amount, std::memory_order_relaxed);
        return;
      case umbra::lsp::RuntimeCounter::video_received_ip_bytes:
        core->video_received_ip_bytes.fetch_add(amount, std::memory_order_relaxed);
        return;
      case umbra::lsp::RuntimeCounter::congestion_feedback_ip_bytes:
        core->congestion_feedback_ip_bytes.fetch_add(amount, std::memory_order_relaxed);
        return;
      case umbra::lsp::RuntimeCounter::congestion_feedback_packets:
        core->congestion_feedback_packets.fetch_add(amount, std::memory_order_relaxed);
        return;
      case umbra::lsp::RuntimeCounter::video_ecn_unknown_packets:
        core->video_ecn_unknown_packets.fetch_add(amount, std::memory_order_relaxed);
        return;
      case umbra::lsp::RuntimeCounter::video_ecn_ce_packets:
        core->video_ecn_ce_packets.fetch_add(amount, std::memory_order_relaxed);
        return;
      case umbra::lsp::RuntimeCounter::path_probes_sent:
        core->path_probes_sent.fetch_add(amount, std::memory_order_relaxed);
        return;
      case umbra::lsp::RuntimeCounter::path_probes_acknowledged:
        core->path_probes_acknowledged.fetch_add(amount, std::memory_order_relaxed);
        return;
      case umbra::lsp::RuntimeCounter::path_probe_timeouts:
        core->path_probe_timeouts.fetch_add(amount, std::memory_order_relaxed);
        return;
    }
  }

  /** @brief Apply authenticated LSPG through the currently active Apple capture owner. */
  std::uint8_t runtime_controller_output(void *context, const clsp_const_byte_span_t payload) noexcept {
    auto *core = static_cast<clsp_core_t *>(context);
    std::lock_guard lock(core->apple_capture_mutex);
    auto *capture = core->apple_capture;
    return capture == nullptr ? 1U : clsp_apple_input_capture_apply_lspg(capture, payload);
  }

  /** @brief Validate an exact remote endpoint and nonzero 32-byte pin. */
  [[nodiscard]] bool valid_endpoint(const clsp_endpoint_t &endpoint) noexcept {
    if (endpoint.abi_version != CLSP_CORE_ABI_VERSION || endpoint.structure_size != sizeof(clsp_endpoint_t) ||
        endpoint.host.data == nullptr || endpoint.host.length == 0 || endpoint.host.length > 255U ||
        endpoint.port == 0 || endpoint.reserved_zero != 0) {
      return false;
    }
    std::uint8_t aggregate = 0;
    for (const auto byte : endpoint.server_spki_sha256) {
      aggregate = static_cast<std::uint8_t>(aggregate | byte);
    }
    return aggregate != 0;
  }
}  // namespace

extern "C" std::uint32_t clsp_core_abi_version(void) {
  return CLSP_CORE_ABI_VERSION;
}

extern "C" const char *clsp_core_source_digest(void) {
  return CLSP_CORE_SOURCE_DIGEST;
}

extern "C" std::uint32_t clsp_core_provider_flags(void) {
  return compiled_provider_flags();
}

extern "C" clsp_status_t clsp_core_create(
  const clsp_configuration_t *configuration,
  const clsp_callbacks_t *callbacks,
  clsp_core_t **output
) {
  if (output == nullptr) {
    return CLSP_STATUS_INVALID_ARGUMENT;
  }
  *output = nullptr;
  if (configuration == nullptr) {
    return CLSP_STATUS_INVALID_ARGUMENT;
  }
  if (const auto status = validate_configuration(*configuration); status != CLSP_STATUS_OK) {
    return status;
  }
  if (callbacks != nullptr &&
      (callbacks->abi_version != CLSP_CORE_ABI_VERSION ||
       callbacks->structure_size != sizeof(clsp_callbacks_t))) {
    return CLSP_STATUS_ABI_MISMATCH;
  }
  if (callbacks != nullptr &&
      ((callbacks->context == nullptr) !=
       (callbacks->retain_context == nullptr && callbacks->release_context == nullptr))) {
    return CLSP_STATUS_INVALID_ARGUMENT;
  }
  if (callbacks != nullptr && callbacks->context != nullptr &&
      (callbacks->retain_context == nullptr || callbacks->release_context == nullptr)) {
    return CLSP_STATUS_INVALID_ARGUMENT;
  }

  auto *core = new (std::nothrow) clsp_core_t;
  if (core == nullptr) {
    return CLSP_STATUS_RESOURCE_EXHAUSTED;
  }
  core->configuration = *configuration;
  if (callbacks != nullptr) {
    core->callbacks = *callbacks;
    if (core->callbacks.context != nullptr) {
      core->callbacks.retain_context(core->callbacks.context);
    }
  } else {
    core->callbacks.abi_version = CLSP_CORE_ABI_VERSION;
    core->callbacks.structure_size = sizeof(clsp_callbacks_t);
  }
  *output = core;
  return CLSP_STATUS_OK;
}

extern "C" void clsp_core_retain(clsp_core_t *core) {
  if (core != nullptr) {
    core->references.fetch_add(1, std::memory_order_relaxed);
  }
}

extern "C" void clsp_core_release(clsp_core_t *core) {
  if (core != nullptr && core->references.fetch_sub(1, std::memory_order_acq_rel) == 1) {
    delete core;
  }
}

extern "C" clsp_status_t clsp_core_start(clsp_core_t *core, const clsp_endpoint_t *endpoint) {
  if (core == nullptr || endpoint == nullptr) {
    return CLSP_STATUS_INVALID_ARGUMENT;
  }
  if (callback_stack_contains(core)) {
    return CLSP_STATUS_REENTRANT_CALLBACK;
  }
  std::unique_lock runtime_lock(core->runtime_mutex);
  const auto providers = compiled_provider_flags();
  if ((providers & CLSP_PROVIDER_WOLFSSL) == 0) {
    return CLSP_STATUS_MISSING_WOLFSSL;
  }
  if ((providers & CLSP_PROVIDER_LIBSRTP) == 0) {
    return CLSP_STATUS_MISSING_LIBSRTP;
  }
  if (!CLSP_CORE_HAS_RUNTIME) {
    return CLSP_STATUS_UNSUPPORTED;
  }
  if (!valid_endpoint(*endpoint)) {
    return CLSP_STATUS_INVALID_ENDPOINT;
  }

  auto state = core->state.load(std::memory_order_acquire);
  if (state != CLSP_LIFECYCLE_CREATED && state != CLSP_LIFECYCLE_STOPPED && state != CLSP_LIFECYCLE_FAILED) {
    return CLSP_STATUS_INVALID_STATE;
  }
  if (core->runtime != nullptr) {
    return CLSP_STATUS_INVALID_STATE;
  }
  auto *runtime = new (std::nothrow) umbra::lsp::Runtime {
    core->configuration,
    {
      .context = core,
      .lifecycle = runtime_lifecycle,
      .control = runtime_control,
      .counter = runtime_counter,
      .controller_output = runtime_controller_output,
      .audio_packet = runtime_audio_packet,
      .audio_timing = runtime_audio_timing,
      .video_frame = runtime_video_frame,
      .path_probe = runtime_path_probe,
    },
  };
  if (runtime == nullptr) {
    return CLSP_STATUS_RESOURCE_EXHAUSTED;
  }
  core->runtime = runtime;
  const auto status = runtime->start(*endpoint);
  if (status != CLSP_STATUS_OK) {
    delete core->runtime;
    core->runtime = nullptr;
    core->state.store(CLSP_LIFECYCLE_FAILED, std::memory_order_release);
  }
  return status;
}

extern "C" clsp_status_t clsp_core_stop(clsp_core_t *core) {
  if (core == nullptr) {
    return CLSP_STATUS_INVALID_ARGUMENT;
  }
  if (callback_stack_contains(core)) {
    return CLSP_STATUS_REENTRANT_CALLBACK;
  }
  std::unique_lock runtime_lock(core->runtime_mutex);
  const auto prior_state = core->state.load(std::memory_order_acquire);
  if (core->runtime == nullptr) {
    return prior_state == CLSP_LIFECYCLE_STOPPED || prior_state == CLSP_LIFECYCLE_FAILED ?
             CLSP_STATUS_OK : CLSP_STATUS_INVALID_STATE;
  }
  if (prior_state != CLSP_LIFECYCLE_AUTHENTICATED && prior_state != CLSP_LIFECYCLE_FAILED) {
    return CLSP_STATUS_INVALID_STATE;
  }
  const auto status = core->runtime->stop();
  delete core->runtime;
  core->runtime = nullptr;
  if (prior_state == CLSP_LIFECYCLE_FAILED) {
    core->state.store(CLSP_LIFECYCLE_FAILED, std::memory_order_release);
    return CLSP_STATUS_OK;
  }
  return status;
}

extern "C" clsp_status_t clsp_core_send_control(
  clsp_core_t *core,
  const std::uint16_t message_type,
  const std::uint64_t request_id,
  const clsp_const_byte_span_t payload,
  const std::uint32_t deadline_milliseconds
) {
  if (core == nullptr) {
    return CLSP_STATUS_INVALID_ARGUMENT;
  }
  if (core->callback_active.load(std::memory_order_acquire)) {
    return CLSP_STATUS_REENTRANT_CALLBACK;
  }
  return with_runtime(core, [&](umbra::lsp::Runtime &runtime) {
    if (core->state.load(std::memory_order_acquire) != CLSP_LIFECYCLE_AUTHENTICATED) {
      return CLSP_STATUS_NOT_AUTHENTICATED;
    }
    return runtime.send_control(message_type, request_id, payload, deadline_milliseconds);
  });
}

extern "C" clsp_status_t clsp_core_configure_input(
  clsp_core_t *core,
  const clsp_input_configuration_t *configuration
) {
  if (core == nullptr || configuration == nullptr) {
    return CLSP_STATUS_INVALID_ARGUMENT;
  }
  if (core->callback_active.load(std::memory_order_acquire)) {
    return CLSP_STATUS_REENTRANT_CALLBACK;
  }
  return with_runtime(core, [&](umbra::lsp::Runtime &runtime) {
    if (core->state.load(std::memory_order_acquire) != CLSP_LIFECYCLE_AUTHENTICATED) {
      return CLSP_STATUS_NOT_AUTHENTICATED;
    }
    return runtime.configure_input(*configuration);
  });
}

extern "C" clsp_status_t clsp_core_send_control_response(
  clsp_core_t *core,
  const std::uint16_t message_type,
  const std::uint64_t request_id,
  const clsp_const_byte_span_t payload,
  const std::uint8_t error_response,
  const std::uint32_t deadline_milliseconds
) {
  if (core == nullptr || error_response > 1U) return CLSP_STATUS_INVALID_ARGUMENT;
  if (core->callback_active.load(std::memory_order_acquire)) return CLSP_STATUS_REENTRANT_CALLBACK;
  return with_runtime(core, [&](umbra::lsp::Runtime &runtime) {
    return runtime.send_control_response(
      message_type,
      request_id,
      payload,
      error_response != 0,
      deadline_milliseconds
    );
  });
}

extern "C" clsp_status_t clsp_core_configure_audio(
  clsp_core_t *core,
  const clsp_audio_configuration_t *configuration
) {
  if (core == nullptr || configuration == nullptr) return CLSP_STATUS_INVALID_ARGUMENT;
  return with_runtime(core, [&](umbra::lsp::Runtime &runtime) {
    return runtime.configure_audio(*configuration);
  });
}

extern "C" clsp_status_t clsp_core_wait_control_response(
  clsp_core_t *core,
  const std::uint64_t request_id,
  const std::uint32_t timeout_milliseconds
) {
  if (core == nullptr) return CLSP_STATUS_INVALID_ARGUMENT;
  return with_runtime(core, [&](umbra::lsp::Runtime &runtime) {
    return runtime.wait_control_response(request_id, timeout_milliseconds);
  });
}

extern "C" clsp_status_t clsp_core_configure_microphone(
  clsp_core_t *core,
  const clsp_microphone_configuration_t *configuration
) {
  if (core == nullptr || configuration == nullptr) return CLSP_STATUS_INVALID_ARGUMENT;
  return with_runtime(core, [&](umbra::lsp::Runtime &runtime) {
    return runtime.configure_microphone(*configuration);
  });
}

extern "C" clsp_status_t clsp_core_submit_microphone_packet(
  clsp_core_t *core,
  const clsp_const_byte_span_t opus_packet
) {
  if (core == nullptr) return CLSP_STATUS_INVALID_ARGUMENT;
  return with_runtime(core, [&](umbra::lsp::Runtime &runtime) {
    return runtime.submit_microphone_packet(opus_packet);
  });
}

extern "C" clsp_status_t clsp_core_mark_microphone_discontinuity(clsp_core_t *core) {
  if (core == nullptr) return CLSP_STATUS_INVALID_ARGUMENT;
  return with_runtime(core, [](umbra::lsp::Runtime &runtime) {
    return runtime.mark_microphone_discontinuity();
  });
}

extern "C" clsp_status_t clsp_core_stop_microphone(clsp_core_t *core) {
  if (core == nullptr) return CLSP_STATUS_INVALID_ARGUMENT;
  return with_runtime(core, [](umbra::lsp::Runtime &runtime) {
    return runtime.stop_microphone();
  });
}

extern "C" clsp_status_t
clsp_core_configure_video(clsp_core_t *core, const clsp_video_configuration_t *configuration) {
  if (core == nullptr || configuration == nullptr) {
    return CLSP_STATUS_INVALID_ARGUMENT;
  }
  if (!validate_video_configuration(*configuration)) {
    return CLSP_STATUS_INVALID_CONFIGURATION;
  }
  return with_runtime(core, [&](umbra::lsp::Runtime &runtime) {
    return runtime.configure_video(*configuration);
  });
}

extern "C" clsp_status_t clsp_core_activate_video(
  clsp_core_t *core,
  const std::uint32_t video_generation
) {
  if (core == nullptr || video_generation == 0) {
    return CLSP_STATUS_INVALID_ARGUMENT;
  }
  return with_runtime(core, [&](umbra::lsp::Runtime &runtime) {
    return runtime.activate_video(video_generation);
  });
}

extern "C" clsp_status_t clsp_core_start_path_discovery(clsp_core_t *core) {
  if (core == nullptr) {
    return CLSP_STATUS_INVALID_ARGUMENT;
  }
  return with_runtime(core, [](umbra::lsp::Runtime &runtime) {
    return runtime.start_path_discovery();
  });
}

extern "C" clsp_status_t clsp_core_send_path_probe(
  clsp_core_t *core,
  const std::uint64_t probe_id,
  const std::uint16_t udp_payload_size,
  const std::uint64_t request_id,
  const clsp_const_byte_span_t payload,
  const std::uint32_t deadline_milliseconds
) {
  if (core == nullptr) {
    return CLSP_STATUS_INVALID_ARGUMENT;
  }
  return with_runtime(core, [&](umbra::lsp::Runtime &runtime) {
    return runtime.send_path_probe(
                                      probe_id,
                                      udp_payload_size,
                                      request_id,
                                      payload,
                                      deadline_milliseconds
                                    );
  });
}

extern "C" clsp_status_t clsp_core_accept_path_probe(
  clsp_core_t *core,
  const std::uint64_t probe_id,
  const std::uint16_t udp_payload_size,
  const std::uint64_t request_id
) {
  if (core == nullptr) {
    return CLSP_STATUS_INVALID_ARGUMENT;
  }
  return with_runtime(core, [&](umbra::lsp::Runtime &runtime) {
    return runtime.accept_path_probe(probe_id, udp_payload_size, request_id);
  });
}

extern "C" clsp_status_t clsp_core_confirm_path_probe(
  clsp_core_t *core,
  const std::uint64_t probe_id,
  const std::uint16_t received_payload_size
) {
  if (core == nullptr) {
    return CLSP_STATUS_INVALID_ARGUMENT;
  }
  return with_runtime(core, [&](umbra::lsp::Runtime &runtime) {
    return runtime.confirm_path_probe(probe_id, received_payload_size);
  });
}

extern "C" clsp_status_t clsp_core_report_video_decode(
  clsp_core_t *core,
  const std::uint32_t video_generation,
  const std::uint64_t frame_id,
  const std::uint32_t recovery_epoch,
  const std::uint8_t decoder_status,
  const std::uint8_t decoder_credit,
  const std::uint8_t render_mailbox_occupancy
) {
  if (core == nullptr ||
      decoder_status > CLSP_VIDEO_DECODER_UNRECOVERABLE_ERROR ||
      render_mailbox_occupancy > 1U) {
    return CLSP_STATUS_INVALID_ARGUMENT;
  }
  return with_runtime(core, [&](umbra::lsp::Runtime &runtime) {
    return runtime.report_video_decode(
      video_generation,
      frame_id,
      recovery_epoch,
      decoder_status,
      decoder_credit,
      render_mailbox_occupancy
    );
  });
}

extern "C" clsp_status_t clsp_core_report_video_commit(
  clsp_core_t *core,
  const std::uint32_t video_generation,
  const std::uint64_t frame_id,
  const std::uint8_t render_mailbox_occupancy
) {
  if (core == nullptr || render_mailbox_occupancy > 1U) {
    return CLSP_STATUS_INVALID_ARGUMENT;
  }
  return with_runtime(core, [&](umbra::lsp::Runtime &runtime) {
    return runtime.report_video_commit(video_generation, frame_id, render_mailbox_occupancy);
  });
}

extern "C" clsp_status_t clsp_core_submit_pointer(
  clsp_core_t *core,
  const clsp_pointer_sample_t *sample
) {
  if (core == nullptr || sample == nullptr) {
    return CLSP_STATUS_INVALID_ARGUMENT;
  }
  if (core->callback_active.load(std::memory_order_acquire)) {
    return CLSP_STATUS_REENTRANT_CALLBACK;
  }
  return with_runtime(core, [&](umbra::lsp::Runtime &runtime) { return runtime.submit_pointer(*sample); });
}

extern "C" clsp_status_t clsp_core_submit_input_edge(
  clsp_core_t *core,
  const clsp_input_edge_t *edge
) {
  if (core == nullptr || edge == nullptr) {
    return CLSP_STATUS_INVALID_ARGUMENT;
  }
  if (core->callback_active.load(std::memory_order_acquire)) {
    return CLSP_STATUS_REENTRANT_CALLBACK;
  }
  return with_runtime(core, [&](umbra::lsp::Runtime &runtime) { return runtime.submit_input_edge(*edge); });
}

extern "C" clsp_status_t clsp_core_neutralize_input(clsp_core_t *core) {
  if (core == nullptr) {
    return CLSP_STATUS_INVALID_ARGUMENT;
  }
  if (core->callback_active.load(std::memory_order_acquire)) {
    return CLSP_STATUS_REENTRANT_CALLBACK;
  }
  return with_runtime(core, [](umbra::lsp::Runtime &runtime) { return runtime.neutralize_input(); });
}

extern "C" clsp_status_t clsp_core_submit_controller_edge(
  clsp_core_t *core,
  const clsp_controller_edge_t *edge
) {
  if (core == nullptr || edge == nullptr) return CLSP_STATUS_INVALID_ARGUMENT;
  return with_runtime(core, [&](umbra::lsp::Runtime &runtime) { return runtime.submit_controller_edge(*edge); });
}

extern "C" clsp_status_t clsp_core_submit_controller_state(
  clsp_core_t *core,
  const clsp_controller_state_t *state
) {
  if (core == nullptr || state == nullptr) return CLSP_STATUS_INVALID_ARGUMENT;
  return with_runtime(core, [&](umbra::lsp::Runtime &runtime) { return runtime.submit_controller_state(*state); });
}

extern "C" clsp_status_t clsp_core_submit_controller_sensor(
  clsp_core_t *core,
  const clsp_controller_sensor_t *sensor
) {
  if (core == nullptr || sensor == nullptr) return CLSP_STATUS_INVALID_ARGUMENT;
  return with_runtime(core, [&](umbra::lsp::Runtime &runtime) { return runtime.submit_controller_sensor(*sensor); });
}

extern "C" clsp_status_t clsp_core_submit_controller_touch_edge(
  clsp_core_t *core,
  const clsp_controller_touch_edge_t *edge
) {
  if (core == nullptr || edge == nullptr) return CLSP_STATUS_INVALID_ARGUMENT;
  return with_runtime(core, [&](umbra::lsp::Runtime &runtime) { return runtime.submit_controller_touch_edge(*edge); });
}

extern "C" clsp_status_t clsp_core_submit_controller_touch_state(
  clsp_core_t *core,
  const clsp_controller_touch_state_t *state
) {
  if (core == nullptr || state == nullptr) return CLSP_STATUS_INVALID_ARGUMENT;
  return with_runtime(core, [&](umbra::lsp::Runtime &runtime) { return runtime.submit_controller_touch_state(*state); });
}

extern "C" bool clsp_core_register_apple_capture(
  clsp_core_t *core,
  clsp_apple_input_capture_t *capture
) {
  if (core == nullptr || capture == nullptr) return false;
  std::lock_guard lock(core->apple_capture_mutex);
  if (core->apple_capture != nullptr) return false;
  core->apple_capture = capture;
  return true;
}

extern "C" void clsp_core_unregister_apple_capture(
  clsp_core_t *core,
  clsp_apple_input_capture_t *capture
) {
  if (core == nullptr || capture == nullptr) return;
  std::lock_guard lock(core->apple_capture_mutex);
  if (core->apple_capture == capture) core->apple_capture = nullptr;
}

extern "C" clsp_status_t clsp_core_copy_telemetry(
  const clsp_core_t *core,
  clsp_telemetry_snapshot_t *output
) {
  if (core == nullptr || output == nullptr) {
    return CLSP_STATUS_INVALID_ARGUMENT;
  }
  if (callback_stack_contains(core)) {
    return CLSP_STATUS_REENTRANT_CALLBACK;
  }
  std::shared_lock runtime_lock(core->runtime_mutex);
  *output = {
    .abi_version = CLSP_CORE_ABI_VERSION,
    .structure_size = sizeof(clsp_telemetry_snapshot_t),
    .lifecycle_state = core->state.load(std::memory_order_acquire),
    .provider_flags = compiled_provider_flags(),
    .received_datagrams = core->received_datagrams.load(std::memory_order_relaxed),
    .transmitted_datagrams = core->transmitted_datagrams.load(std::memory_order_relaxed),
    .dropped_datagrams = core->dropped_datagrams.load(std::memory_order_relaxed),
    .authentication_failures = core->authentication_failures.load(std::memory_order_relaxed),
    .video_received_ip_bytes = core->video_received_ip_bytes.load(std::memory_order_relaxed),
    .congestion_feedback_ip_bytes = core->congestion_feedback_ip_bytes.load(std::memory_order_relaxed),
    .congestion_feedback_packets = core->congestion_feedback_packets.load(std::memory_order_relaxed),
    .video_ecn_unknown_packets = core->video_ecn_unknown_packets.load(std::memory_order_relaxed),
    .video_ecn_ce_packets = core->video_ecn_ce_packets.load(std::memory_order_relaxed),
    .path_probes_sent = core->path_probes_sent.load(std::memory_order_relaxed),
    .path_probes_acknowledged = core->path_probes_acknowledged.load(std::memory_order_relaxed),
    .path_probe_timeouts = core->path_probe_timeouts.load(std::memory_order_relaxed),
    .current_udp_payload_size = core->runtime == nullptr ? std::uint16_t {1'200} :
                                                           core->runtime->current_udp_payload_size(),
    .reserved_zero = 0,
  };
  return CLSP_STATUS_OK;
}

extern "C" void clsp_buffer_retain(clsp_buffer_t *buffer) {
  if (buffer != nullptr) {
    buffer->references.fetch_add(1, std::memory_order_relaxed);
  }
}

extern "C" void clsp_buffer_release(clsp_buffer_t *buffer) {
  if (buffer != nullptr && buffer->references.fetch_sub(1, std::memory_order_acq_rel) == 1) {
    if (buffer->destroy != nullptr) {
      buffer->destroy(buffer);
    } else {
      delete buffer;
    }
  }
}

extern "C" clsp_status_t clsp_buffer_bytes(
  const clsp_buffer_t *buffer,
  clsp_const_byte_span_t *output
) {
  if (buffer == nullptr || output == nullptr || (buffer->data == nullptr && buffer->length != 0)) {
    return CLSP_STATUS_INVALID_ARGUMENT;
  }
  *output = {.data = buffer->data, .length = buffer->length};
  return CLSP_STATUS_OK;
}

extern "C" const char *clsp_status_description(const clsp_status_t status) {
  switch (status) {
    case CLSP_STATUS_OK:
      return "success";
    case CLSP_STATUS_INVALID_ARGUMENT:
      return "invalid argument";
    case CLSP_STATUS_ABI_MISMATCH:
      return "ABI mismatch";
    case CLSP_STATUS_MISSING_WOLFSSL:
      return "wolfSSL DTLS 1.3 provider unavailable";
    case CLSP_STATUS_MISSING_LIBSRTP:
      return "libSRTP AES-GCM provider unavailable";
    case CLSP_STATUS_INVALID_CONFIGURATION:
      return "invalid LSP configuration";
    case CLSP_STATUS_INVALID_STATE:
      return "invalid LSP lifecycle state";
    case CLSP_STATUS_REENTRANT_CALLBACK:
      return "reentrant LSP callback";
    case CLSP_STATUS_RESOURCE_EXHAUSTED:
      return "bounded native resource exhausted";
    case CLSP_STATUS_UNSUPPORTED:
      return "unsupported LSP capability";
    case CLSP_STATUS_INTERNAL_FAILURE:
      return "internal LSP failure";
    case CLSP_STATUS_INVALID_ENDPOINT:
      return "invalid LSP endpoint or SPKI pin";
    case CLSP_STATUS_SOCKET_FAILURE:
      return "LSP UDP or kqueue failure";
    case CLSP_STATUS_DTLS_FAILURE:
      return "LSP DTLS 1.3 failure";
    case CLSP_STATUS_SPKI_MISMATCH:
      return "LSP server SPKI pin mismatch";
    case CLSP_STATUS_SRTP_FAILURE:
      return "LSP SRTP or SRTCP failure";
    case CLSP_STATUS_NOT_AUTHENTICATED:
      return "LSP association is not authenticated";
    case CLSP_STATUS_CONTROL_WINDOW_FULL:
      return "LSP control window is full";
    case CLSP_STATUS_TIMEOUT:
      return "LSP operation timed out";
    case CLSP_STATUS_INPUT_PERMISSION_DENIED:
      return "macOS denied native LSP input capture";
    case CLSP_STATUS_INPUT_UNAVAILABLE:
      return "native LSP input capture is unavailable";
  }
  return "unknown LSP status";
}
