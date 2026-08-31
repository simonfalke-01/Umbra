/**
 * @file CLSPCore.cpp
 * @brief Fail-closed implementation of the version-one Umbra LSP C ABI.
 */

#include "CLSPCore.h"

#include "core/core.h"
#include "runtime/Runtime.h"

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <new>
#include <mutex>

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

static_assert(lumen::lsp::core_api_version == CLSP_CORE_ABI_VERSION);

/** @brief Native core object hidden behind `clsp_core_t`. */
struct clsp_core {
  std::atomic<std::uint32_t> references {1};  ///< Explicit ABI ownership count.
  std::atomic<std::uint32_t> state {CLSP_LIFECYCLE_CREATED};  ///< Coarse lifecycle state.
  std::atomic<bool> callback_active {false};  ///< Rejects reentrant ABI operations.
  std::mutex apple_capture_mutex;  ///< Serializes low-rate LSPG application with capture teardown.
  clsp_apple_input_capture_t *apple_capture {};  ///< Active native controller-output owner.
  umbra::lsp::Runtime *runtime {};  ///< Owned native socket/security/control runtime.
  clsp_configuration_t configuration {};  ///< Caller configuration copied at creation.
  clsp_callbacks_t callbacks {};  ///< Callback table copied at creation.
  std::atomic<std::uint64_t> received_datagrams {0};  ///< Authenticated receive count.
  std::atomic<std::uint64_t> transmitted_datagrams {0};  ///< Socket submission count.
  std::atomic<std::uint64_t> dropped_datagrams {0};  ///< Bounded drop count.
  std::atomic<std::uint64_t> authentication_failures {0};  ///< Authentication failure count.

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
  void (*destroy)(clsp_buffer_t *) = nullptr;  ///< Native storage destruction function.
};

namespace {
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
  if (core->callback_active.load(std::memory_order_acquire)) {
    return CLSP_STATUS_REENTRANT_CALLBACK;
  }
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
  if (core->callback_active.load(std::memory_order_acquire)) {
    return CLSP_STATUS_REENTRANT_CALLBACK;
  }
  if (core->state.load(std::memory_order_acquire) != CLSP_LIFECYCLE_AUTHENTICATED || core->runtime == nullptr) {
    return CLSP_STATUS_INVALID_STATE;
  }
  const auto status = core->runtime->stop();
  delete core->runtime;
  core->runtime = nullptr;
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
  if (core->runtime == nullptr || core->state.load(std::memory_order_acquire) != CLSP_LIFECYCLE_AUTHENTICATED) {
    return CLSP_STATUS_NOT_AUTHENTICATED;
  }
  return core->runtime->send_control(message_type, request_id, payload, deadline_milliseconds);
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
  if (core->runtime == nullptr || core->state.load(std::memory_order_acquire) != CLSP_LIFECYCLE_AUTHENTICATED) {
    return CLSP_STATUS_NOT_AUTHENTICATED;
  }
  return core->runtime->configure_input(*configuration);
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
  return core->runtime == nullptr ? CLSP_STATUS_NOT_AUTHENTICATED : core->runtime->submit_pointer(*sample);
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
  return core->runtime == nullptr ? CLSP_STATUS_NOT_AUTHENTICATED : core->runtime->submit_input_edge(*edge);
}

extern "C" clsp_status_t clsp_core_neutralize_input(clsp_core_t *core) {
  if (core == nullptr) {
    return CLSP_STATUS_INVALID_ARGUMENT;
  }
  if (core->callback_active.load(std::memory_order_acquire)) {
    return CLSP_STATUS_REENTRANT_CALLBACK;
  }
  return core->runtime == nullptr ? CLSP_STATUS_NOT_AUTHENTICATED : core->runtime->neutralize_input();
}

extern "C" clsp_status_t clsp_core_submit_controller_edge(
  clsp_core_t *core,
  const clsp_controller_edge_t *edge
) {
  if (core == nullptr || edge == nullptr) return CLSP_STATUS_INVALID_ARGUMENT;
  return core->runtime == nullptr ? CLSP_STATUS_NOT_AUTHENTICATED : core->runtime->submit_controller_edge(*edge);
}

extern "C" clsp_status_t clsp_core_submit_controller_state(
  clsp_core_t *core,
  const clsp_controller_state_t *state
) {
  if (core == nullptr || state == nullptr) return CLSP_STATUS_INVALID_ARGUMENT;
  return core->runtime == nullptr ? CLSP_STATUS_NOT_AUTHENTICATED : core->runtime->submit_controller_state(*state);
}

extern "C" clsp_status_t clsp_core_submit_controller_sensor(
  clsp_core_t *core,
  const clsp_controller_sensor_t *sensor
) {
  if (core == nullptr || sensor == nullptr) return CLSP_STATUS_INVALID_ARGUMENT;
  return core->runtime == nullptr ? CLSP_STATUS_NOT_AUTHENTICATED : core->runtime->submit_controller_sensor(*sensor);
}

extern "C" clsp_status_t clsp_core_submit_controller_touch_edge(
  clsp_core_t *core,
  const clsp_controller_touch_edge_t *edge
) {
  if (core == nullptr || edge == nullptr) return CLSP_STATUS_INVALID_ARGUMENT;
  return core->runtime == nullptr ? CLSP_STATUS_NOT_AUTHENTICATED : core->runtime->submit_controller_touch_edge(*edge);
}

extern "C" clsp_status_t clsp_core_submit_controller_touch_state(
  clsp_core_t *core,
  const clsp_controller_touch_state_t *state
) {
  if (core == nullptr || state == nullptr) return CLSP_STATUS_INVALID_ARGUMENT;
  return core->runtime == nullptr ? CLSP_STATUS_NOT_AUTHENTICATED : core->runtime->submit_controller_touch_state(*state);
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
  *output = {
    .abi_version = CLSP_CORE_ABI_VERSION,
    .structure_size = sizeof(clsp_telemetry_snapshot_t),
    .lifecycle_state = core->state.load(std::memory_order_acquire),
    .provider_flags = compiled_provider_flags(),
    .received_datagrams = core->received_datagrams.load(std::memory_order_relaxed),
    .transmitted_datagrams = core->transmitted_datagrams.load(std::memory_order_relaxed),
    .dropped_datagrams = core->dropped_datagrams.load(std::memory_order_relaxed),
    .authentication_failures = core->authentication_failures.load(std::memory_order_relaxed),
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
