/**
 * @file Runtime.h
 * @brief Native macOS UDP, DTLS, SRTP, and LSPC runtime owned behind the C ABI.
 */

#pragma once

#include "CLSPCore.h"

#include <cstdint>
#include <span>

namespace umbra::lsp {
  /** @brief Non-owning callbacks from the native worker to the C ABI owner. */
  struct RuntimeCallbacks {
    /** @brief Publish a coarse lifecycle transition and its first fatal status. */
    using Lifecycle = void (*)(void *context, std::uint32_t state, clsp_status_t terminal_status) noexcept;

    /** @brief Publish one authenticated, de-duplicated LSPC frame. */
    using Control = void (*)(void *context, const clsp_control_event_t &event) noexcept;

    /** @brief Increment one thread-owned telemetry counter at snapshot frequency. */
    using Counter = void (*)(void *context, std::uint32_t counter, std::uint64_t amount) noexcept;

    /** @brief Publish one fixed-layout worker-owned timing snapshot at no more than four hertz. */
    using Timing = void (*)(void *context, const clsp_native_timing_snapshot_t &snapshot) noexcept;

    /** @brief Apply one authenticated LSPG payload and return a terminal command status. */
    using ControllerOutput = std::uint8_t (*)(void *context, clsp_const_byte_span_t payload) noexcept;

    /** @brief Publish one authenticated input-baseline ACK at control frequency. */
    using InputBaseline = void (*)(
      void *context,
      bool acknowledged,
      std::uint32_t connection_generation,
      std::uint32_t input_generation,
      std::uint64_t baseline_id
    ) noexcept;

    /** @brief Deliver one authenticated complete Opus RTP payload. */
    using AudioPacket = void (*)(void *context, const clsp_audio_packet_event_t &event) noexcept;
    using AudioTiming = void (*)(void *context, const clsp_audio_timing_event_t &event) noexcept;
    using VideoFrame = void (*)(void *context, const clsp_video_frame_event_t &event) noexcept;
    using PathProbe = bool (*)(void *context, const clsp_path_probe_event_t &event) noexcept;

    void *context {};  ///< Opaque C ABI owner.
    Lifecycle lifecycle {};  ///< Required lifecycle callback.
    Control control {};  ///< Optional authenticated-control callback.
    Counter counter {};  ///< Required telemetry callback.
    Timing timing {};  ///< Optional coarse timing-distribution callback.
    ControllerOutput controller_output {};  ///< Optional generation-checked GameController output callback.
    InputBaseline input_baseline {};  ///< Optional authenticated baseline-ACK callback.
    AudioPacket audio_packet {};  ///< Optional complete Opus packet callback.
    AudioTiming audio_timing {};  ///< Optional authenticated sender-report callback.
    VideoFrame video_frame {};  ///< Optional retained complete access-unit callback.
    PathProbe path_probe {};  ///< Optional low-rate DPLPMTUD lifecycle callback.
  };

  /** @brief Runtime telemetry counter identifiers. */
  enum class RuntimeCounter : std::uint32_t {
    received = 0,  ///< Authenticated DTLS/SRTP/SRTCP packet received.
    transmitted = 1,  ///< Complete UDP datagram submitted.
    dropped = 2,  ///< Datagram or bounded command discarded.
    authentication_failure = 3,  ///< DTLS, SPKI, SRTP, or SRTCP authentication failure.
    video_received_ip_bytes = 4,  ///< Complete authenticated forward IP bytes.
    congestion_feedback_ip_bytes = 5,  ///< Complete submitted reverse CCFB IP bytes.
    congestion_feedback_packets = 6,  ///< Submitted CCFB packet count.
    video_ecn_unknown_packets = 7,  ///< Packets without actual ancillary ECN evidence.
    video_ecn_ce_packets = 8,  ///< Authenticated ECN-CE video packets.
    path_probes_sent = 9,  ///< Exact protected LSPP kernel submissions.
    path_probes_acknowledged = 10,  ///< Exact authenticated probe ACKs.
    path_probe_timeouts = 11,  ///< Three-attempt probe timeouts.
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

    /** @brief Reserve one invisible bounded control request and its queue capacity. */
    [[nodiscard]] clsp_status_t reserve_control(
      std::uint16_t message_type,
      std::uint64_t request_id,
      clsp_const_byte_span_t payload,
      std::uint32_t deadline_milliseconds,
      std::uint64_t &reservation_token
    ) noexcept;

    /** @brief Publish one exact reserved request and wake the native worker. */
    [[nodiscard]] clsp_status_t commit_control_reservation(std::uint64_t reservation_token) noexcept;

    /** @brief Release one invisible reserved request without transmission. */
    void cancel_control_reservation(std::uint64_t reservation_token) noexcept;

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

    /** @brief Open completed-frame publication after the semantic video ACK is submitted. */
    [[nodiscard]] clsp_status_t activate_video(std::uint32_t video_generation) noexcept;

    /** @brief Enable native DPLPMTUD after the video generation is active. */
    [[nodiscard]] clsp_status_t start_path_discovery() noexcept;

    /** @brief Queue the reliable client intent paired with one exact-size LSPP. */
    [[nodiscard]] clsp_status_t send_path_probe(
      std::uint64_t probe_id,
      std::uint16_t udp_payload_size,
      std::uint64_t request_id,
      clsp_const_byte_span_t payload,
      std::uint32_t deadline_milliseconds
    ) noexcept;

    /** @brief Retain an authenticated host intent until its matching LSPP arrives. */
    [[nodiscard]] clsp_status_t accept_path_probe(
      std::uint64_t probe_id,
      std::uint16_t udp_payload_size,
      std::uint64_t request_id
    ) noexcept;

    /** @brief Confirm one exact client-initiated PATH_PROBE_ACK. */
    [[nodiscard]] clsp_status_t confirm_path_probe(
      std::uint64_t probe_id,
      std::uint16_t received_payload_size
    ) noexcept;

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

    /** @brief Apply one exact coarse input-rate renegotiation on the socket worker. */
    [[nodiscard]] clsp_status_t update_input_rates(const clsp_input_rate_update_t &update) noexcept;

    /** @brief Copy latest authenticated LSPI and effective-rate evidence. */
    [[nodiscard]] clsp_status_t copy_input_feedback(clsp_input_feedback_snapshot_t &output) noexcept;

    /** @brief Copy newest locally assigned edge identity for text/IME barriers. */
    [[nodiscard]] clsp_status_t copy_input_edge_snapshot(clsp_input_edge_snapshot_t &output) const noexcept;

    /**
     * @brief Publish one native device generation for deterministic baseline construction.
     *
     * @param device_type One frozen LSP input device type.
     * @param device_id Nonzero stable device identifier.
     * @param instance_generation Nonzero hot-plug generation.
     * @param active Whether the exact generation is active.
     * @param sensor_mask Controller sensor capability bits one and two, otherwise zero.
     */
    void observe_input_device(
      std::uint8_t device_type,
      std::uint32_t device_id,
      std::uint32_t instance_generation,
      bool active,
      std::uint8_t sensor_mask
    ) noexcept;

    /**
     * @brief Return cumulative bounded capture-ring drops for one exact offered generation.
     *
     * @param offer_type One `clsp_device_offer_type_t` value.
     * @param device_id Pointer source one or controller slot one through sixteen.
     * @param instance_generation Exact nonzero native generation.
     * @return Cumulative drops, or zero for an unknown/stale generation.
     */
    [[nodiscard]] std::uint64_t input_dropped_samples(
      std::uint8_t offer_type,
      std::uint32_t device_id,
      std::uint32_t instance_generation
    ) const noexcept;

    /**
     * @brief Return complete IP bytes attributable to one exact state/sensor generation.
     *
     * Shared edge-batch and baseline overhead is intentionally excluded.
     *
     * @param offer_type One `clsp_device_offer_type_t` value.
     * @param device_id Pointer source one or controller slot one through sixteen.
     * @param instance_generation Exact nonzero native generation.
     * @return Cumulative attributable complete IP bytes, or zero for a stale generation.
     */
    [[nodiscard]] std::uint64_t input_attributed_wire_bytes(
      std::uint8_t offer_type,
      std::uint32_t device_id,
      std::uint32_t instance_generation
    ) const noexcept;

    /** @brief Queue one allocation-free relative-pointer capture record. */
    [[nodiscard]] clsp_status_t submit_pointer(const clsp_pointer_sample_t &sample) noexcept;

    /** @brief Queue one allocation-free absolute-pointer capture record. */
    [[nodiscard]] clsp_status_t submit_absolute_pointer(const clsp_absolute_pointer_sample_t &sample) noexcept;

    /**
     * @brief Drop relative capture motion while the client draws an absolute cursor.
     * @param inside_video Whether that cursor is over the video; presses and scrolls outside it are dropped.
     */
    [[nodiscard]] clsp_status_t set_pointer_motion_absolute(bool absolute, bool inside_video) noexcept;

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

    /** @brief Idempotently quiesce input from every runtime lifecycle state. */
    [[nodiscard]] clsp_status_t quiesce_input() noexcept;

    /** @brief Restart the unchanged input generation with one exact fresh neutral baseline. */
    [[nodiscard]] clsp_status_t restart_input_baseline(std::uint64_t baseline_id) noexcept;

    /** @brief Return the authenticated confirmed UDP payload ceiling. */
    [[nodiscard]] std::uint16_t current_udp_payload_size() const noexcept;

    /** @brief Return the independently confirmed host-to-client UDP payload ceiling. */
    [[nodiscard]] std::uint16_t current_receive_udp_payload_size() const noexcept;

    /** @brief Copy the authenticated association's exact DTLS-SRTP exporter for native transcript binding. */
    [[nodiscard]] clsp_status_t copy_pairing_exporter(
      std::span<std::uint8_t, 32> output
    ) const noexcept;

    /** @brief Return the authenticated SERVER_HELLO connection generation. */
    [[nodiscard]] std::uint32_t current_connection_generation() const noexcept;

  private:
    class Impl;
    Impl *impl_ {};  ///< Nothrow-allocated platform implementation.
  };
}  // namespace umbra::lsp
