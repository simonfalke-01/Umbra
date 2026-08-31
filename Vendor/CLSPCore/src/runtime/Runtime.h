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

    void *context {};  ///< Opaque C ABI owner.
    Lifecycle lifecycle {};  ///< Required lifecycle callback.
    Control control {};  ///< Optional authenticated-control callback.
    Counter counter {};  ///< Required telemetry callback.
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

    /** @brief Install an authenticated input-only START_RESPONSE mapping. */
    [[nodiscard]] clsp_status_t configure_input(const clsp_input_configuration_t &configuration) noexcept;

    /** @brief Queue one allocation-free relative-pointer capture record. */
    [[nodiscard]] clsp_status_t submit_pointer(const clsp_pointer_sample_t &sample) noexcept;

    /** @brief Queue one allocation-free keyboard or pointer-button edge. */
    [[nodiscard]] clsp_status_t submit_input_edge(const clsp_input_edge_t &edge) noexcept;

    /** @brief Neutralize and stop the current native input authority. */
    [[nodiscard]] clsp_status_t neutralize_input() noexcept;

  private:
    class Impl;
    Impl *impl_ {};  ///< Nothrow-allocated platform implementation.
  };
}  // namespace umbra::lsp
