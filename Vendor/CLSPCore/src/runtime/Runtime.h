/**
 * @file Runtime.h
 * @brief Native macOS UDP, DTLS, SRTP, and LSPC runtime owned behind the C ABI.
 */

#pragma once

#include "CLSPCore.h"

#include <cstdint>

namespace umbra::lsp {
  /** @brief Non-owning callbacks from the native worker to the C ABI owner. */
  struct RuntimeCallbacks {
    /** @brief Publish a coarse lifecycle transition. */
    using Lifecycle = void (*)(void *context, std::uint32_t state) noexcept;

    /** @brief Publish one authenticated, de-duplicated LSPC frame. */
    using Control = void (*)(void *context, const clsp_control_event_t &event) noexcept;

    /** @brief Increment one thread-owned telemetry counter at snapshot frequency. */
    using Counter = void (*)(void *context, std::uint32_t counter, std::uint64_t amount) noexcept;

    /** @brief Apply one authenticated LSPG payload and return a terminal command status. */
    using ControllerOutput = std::uint8_t (*)(void *context, clsp_const_byte_span_t payload) noexcept;

    /** @brief Deliver one authenticated complete Opus RTP payload. */
    using AudioPacket = void (*)(void *context, const clsp_audio_packet_event_t &event) noexcept;
    using AudioTiming = void (*)(void *context, const clsp_audio_timing_event_t &event) noexcept;
    using VideoFrame = void (*)(void *context, const clsp_video_frame_event_t &event) noexcept;

    void *context {};  ///< Opaque C ABI owner.
    Lifecycle lifecycle {};  ///< Required lifecycle callback.
    Control control {};  ///< Optional authenticated-control callback.
    Counter counter {};  ///< Required telemetry callback.
    ControllerOutput controller_output {};  ///< Optional generation-checked GameController output callback.
    AudioPacket audio_packet {};  ///< Optional complete Opus packet callback.
    AudioTiming audio_timing {};  ///< Optional authenticated sender-report callback.
    VideoFrame video_frame {};  ///< Optional retained complete access-unit callback.
  };

  /** @brief Runtime telemetry counter identifiers. */
  enum class RuntimeCounter : std::uint32_t {
    received = 0,  ///< Authenticated DTLS/SRTP/SRTCP packet received.
    transmitted = 1,  ///< Complete UDP datagram submitted.
    dropped = 2,  ///< Datagram or bounded command discarded.
    authentication_failure = 3,  ///< DTLS, SPKI, SRTP, or SRTCP authentication failure.
  };

  /** @brief One connection's native execution owner. */
  class Runtime final {
  public:
    /**
     * @brief Construct an inactive runtime with copied immutable configuration.
     *
     * @param configuration Validated C ABI configuration.
     * @param callbacks Stable callbacks whose context outlives this runtime.
     */
    Runtime(const clsp_configuration_t &configuration, RuntimeCallbacks callbacks) noexcept;

    Runtime(const Runtime &) = delete;
    Runtime &operator=(const Runtime &) = delete;
    Runtime(Runtime &&) = delete;
    Runtime &operator=(Runtime &&) = delete;

    /** @brief Stop the worker, destroy security contexts, and release sockets. */
    ~Runtime();

    /**
     * @brief Resolve, connect, authenticate, pin, export, and install SRTP contexts.
     *
     * @param endpoint Validated remote endpoint.
     * @return Exact fail-closed startup result.
     */
    [[nodiscard]] clsp_status_t start(const clsp_endpoint_t &endpoint) noexcept;

    /**
     * @brief Stop and join the native worker.
     *
     * @return Success when a live worker was quiesced.
     */
    [[nodiscard]] clsp_status_t stop() noexcept;

    /**
     * @brief Queue one reliable LSPC request for the native worker.
     *
     * @param message_type Nonzero semantic message type.
     * @param request_id Random nonzero request identifier.
     * @param payload Deterministic-CBOR payload.
     * @param deadline_milliseconds Relative bounded deadline.
     * @return Exact bounded queueing status.
     */
    [[nodiscard]] clsp_status_t send_control(
      std::uint16_t message_type,
      std::uint64_t request_id,
      clsp_const_byte_span_t payload,
      std::uint32_t deadline_milliseconds
    ) noexcept;

    /** @brief Queue one semantic LSPC response for a retained authenticated request. */
    [[nodiscard]] clsp_status_t send_control_response(
      std::uint16_t message_type,
      std::uint64_t request_id,
      clsp_const_byte_span_t payload,
      bool error_response,
      std::uint32_t deadline_milliseconds
    ) noexcept;

    /** @brief Wait for actual native submission/cache completion of a semantic response. */
    [[nodiscard]] clsp_status_t wait_control_response(
      std::uint64_t request_id,
      std::uint32_t timeout_milliseconds
    ) noexcept;

    /** @brief Install exact host-audio packet admission before semantic ACK. */
    [[nodiscard]] clsp_status_t configure_audio(const clsp_audio_configuration_t &configuration) noexcept;

    /** @brief Install exact reverse microphone sender mapping. */
    [[nodiscard]] clsp_status_t configure_microphone(const clsp_microphone_configuration_t &configuration) noexcept;

    /** @brief Queue one complete Opus microphone packet. */
    [[nodiscard]] clsp_status_t submit_microphone_packet(clsp_const_byte_span_t opus_packet) noexcept;

    /** @brief Mark the next microphone packet as a discontinuity. */
    [[nodiscard]] clsp_status_t mark_microphone_discontinuity() noexcept;

    /** @brief Stop the microphone sender and discard queued stale packets. */
    [[nodiscard]] clsp_status_t stop_microphone() noexcept;

    /** @brief Install exact video SSRC/PT/generation and encrypted extension admission. */
    [[nodiscard]] clsp_status_t configure_video(const clsp_video_configuration_t &configuration) noexcept;

    /** @brief Update native LSPV decode state. */
    [[nodiscard]] clsp_status_t report_video_decode(
      std::uint32_t video_generation,
      std::uint64_t frame_id,
      std::uint32_t recovery_epoch,
      std::uint8_t decoder_status,
      std::uint8_t decoder_credit,
      std::uint8_t render_mailbox_occupancy
    ) noexcept;

    /** @brief Update native LSPV Metal-commit state. */
    [[nodiscard]] clsp_status_t report_video_commit(
      std::uint32_t video_generation,
      std::uint64_t frame_id,
      std::uint8_t render_mailbox_occupancy
    ) noexcept;

    /** @brief Install an authenticated input-only START_RESPONSE mapping. */
    [[nodiscard]] clsp_status_t configure_input(const clsp_input_configuration_t &configuration) noexcept;

    /** @brief Queue one allocation-free relative-pointer capture record. */
    [[nodiscard]] clsp_status_t submit_pointer(const clsp_pointer_sample_t &sample) noexcept;

    /** @brief Queue one allocation-free keyboard or pointer-button edge. */
    [[nodiscard]] clsp_status_t submit_input_edge(const clsp_input_edge_t &edge) noexcept;

    /** @brief Queue one GameController lifecycle/button edge. */
    [[nodiscard]] clsp_status_t submit_controller_edge(const clsp_controller_edge_t &edge) noexcept;

    /** @brief Queue latest controller triggers and sticks. */
    [[nodiscard]] clsp_status_t submit_controller_state(const clsp_controller_state_t &state) noexcept;

    /** @brief Queue latest controller gyro or accelerometer state. */
    [[nodiscard]] clsp_status_t submit_controller_sensor(const clsp_controller_sensor_t &sensor) noexcept;

    /** @brief Queue one controller touch lifecycle edge. */
    [[nodiscard]] clsp_status_t submit_controller_touch_edge(const clsp_controller_touch_edge_t &edge) noexcept;

    /** @brief Queue latest controller touch coordinates. */
    [[nodiscard]] clsp_status_t submit_controller_touch_state(const clsp_controller_touch_state_t &state) noexcept;

    /** @brief Neutralize and stop the current native input authority. */
    [[nodiscard]] clsp_status_t neutralize_input() noexcept;

  private:
    class Impl;
    Impl *impl_ {};  ///< Nothrow-allocated platform implementation.
  };
}  // namespace umbra::lsp
