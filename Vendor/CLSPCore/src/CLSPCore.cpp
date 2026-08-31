/**
 * @file CLSPCore.cpp
 * @brief Fail-closed implementation of the version-one Umbra LSP C ABI.
 */

#include "CLSPCore.h"

#include "core/core.h"

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <new>

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
  clsp_configuration_t configuration {};  ///< Caller configuration copied at creation.
  clsp_callbacks_t callbacks {};  ///< Callback table copied at creation.
  std::atomic<std::uint64_t> received_datagrams {0};  ///< Authenticated receive count.
  std::atomic<std::uint64_t> transmitted_datagrams {0};  ///< Socket submission count.
  std::atomic<std::uint64_t> dropped_datagrams {0};  ///< Bounded drop count.
  std::atomic<std::uint64_t> authentication_failures {0};  ///< Authentication failure count.

  /** @brief Release the explicitly retained callback context. */
  ~clsp_core() {
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
        configuration.reserved_flags != 0 || configuration.telemetry_interval_milliseconds < 250U) {
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

extern "C" clsp_status_t clsp_core_start(clsp_core_t *core) {
  if (core == nullptr) {
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

  auto state = core->state.load(std::memory_order_acquire);
  while (state != CLSP_LIFECYCLE_RUNNING) {
    if (state != CLSP_LIFECYCLE_CREATED && state != CLSP_LIFECYCLE_STOPPED) {
      return CLSP_STATUS_INVALID_STATE;
    }
    if (core->state.compare_exchange_weak(
          state,
          CLSP_LIFECYCLE_RUNNING,
          std::memory_order_acq_rel
        )) {
      publish_lifecycle(core, CLSP_LIFECYCLE_RUNNING);
      return CLSP_STATUS_OK;
    }
  }
  return CLSP_STATUS_INVALID_STATE;
}

extern "C" clsp_status_t clsp_core_stop(clsp_core_t *core) {
  if (core == nullptr) {
    return CLSP_STATUS_INVALID_ARGUMENT;
  }
  if (core->callback_active.load(std::memory_order_acquire)) {
    return CLSP_STATUS_REENTRANT_CALLBACK;
  }
  auto expected = static_cast<std::uint32_t>(CLSP_LIFECYCLE_RUNNING);
  if (!core->state.compare_exchange_strong(
        expected,
        CLSP_LIFECYCLE_STOPPED,
        std::memory_order_acq_rel
      )) {
    return CLSP_STATUS_INVALID_STATE;
  }
  publish_lifecycle(core, CLSP_LIFECYCLE_STOPPED);
  return CLSP_STATUS_OK;
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
  }
  return "unknown LSP status";
}
