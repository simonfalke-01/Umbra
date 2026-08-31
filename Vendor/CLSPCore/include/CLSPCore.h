/**
 * @file CLSPCore.h
 * @brief Versioned C ABI for Umbra's native Lumen Streaming Protocol core.
 */

#ifndef CLSP_CORE_H
#define CLSP_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** @brief C ABI version implemented by CLSPCore. */
#define CLSP_CORE_ABI_VERSION UINT32_C(1)

/** @brief Source digest of the mirrored portable LSP core. */
#define CLSP_CORE_SOURCE_DIGEST "7f338b3da343cc9b1fdc36d7a2590cfccdf00afd87c12d8cfc1acfff0c6e6362"

/** @brief Default LSP UDP application port. */
#define CLSP_DEFAULT_PORT UINT16_C(48030)

  /** @brief Opaque native protocol-core handle. */
  typedef struct clsp_core clsp_core_t;

  /** @brief Opaque retained native byte-buffer handle. */
  typedef struct clsp_buffer clsp_buffer_t;

  /** @brief Borrowed immutable byte span whose lifetime is defined by the containing call. */
  typedef struct clsp_const_byte_span {
    const uint8_t *data;  ///< First byte, or null only when `length` is zero.
    size_t length;  ///< Number of borrowed bytes.
  } clsp_const_byte_span_t;

  /** @brief Typed result returned by every fallible ABI operation. */
  typedef enum clsp_status {
    CLSP_STATUS_OK = 0,  ///< Operation completed successfully.
    CLSP_STATUS_INVALID_ARGUMENT = 1,  ///< A pointer, length, field, or state was invalid.
    CLSP_STATUS_ABI_MISMATCH = 2,  ///< Caller and native ABI versions differ.
    CLSP_STATUS_MISSING_WOLFSSL = 3,  ///< Commercial wolfSSL DTLS 1.3 provider is unavailable.
    CLSP_STATUS_MISSING_LIBSRTP = 4,  ///< libSRTP AES-GCM provider is unavailable.
    CLSP_STATUS_INVALID_CONFIGURATION = 5,  ///< Configuration violates an LSP invariant.
    CLSP_STATUS_INVALID_STATE = 6,  ///< Lifecycle transition is not valid from the current state.
    CLSP_STATUS_REENTRANT_CALLBACK = 7,  ///< A core operation was attempted from its own callback.
    CLSP_STATUS_RESOURCE_EXHAUSTED = 8,  ///< A bounded native resource could not be allocated.
    CLSP_STATUS_UNSUPPORTED = 9,  ///< The requested production capability is not implemented.
    CLSP_STATUS_INTERNAL_FAILURE = 10,  ///< An internal invariant failed without exposing details.
  } clsp_status_t;

  /** @brief Operator-selected congestion-control profile. */
  typedef enum clsp_profile {
    CLSP_PROFILE_ADAPTIVE_LOW_LATENCY = 0,  ///< Safe adaptive low-delay default.
    CLSP_PROFILE_COMPETITION_LAN = 1,  ///< Explicitly provisioned competition profile.
  } clsp_profile_t;

  /** @brief Native lifecycle state visible at coarse product boundaries. */
  typedef enum clsp_lifecycle_state {
    CLSP_LIFECYCLE_CREATED = 0,  ///< Core handle exists but owns no live transport.
    CLSP_LIFECYCLE_RUNNING = 1,  ///< Native transport workers are active.
    CLSP_LIFECYCLE_STOPPED = 2,  ///< Transport workers are quiesced and may be restarted.
  } clsp_lifecycle_state_t;

  /** @brief Bit mask describing linked production security providers. */
  typedef enum clsp_provider_flag {
    CLSP_PROVIDER_WOLFSSL = 1U << 0U,  ///< wolfSSL DTLS 1.3 provider is linked.
    CLSP_PROVIDER_LIBSRTP = 1U << 1U,  ///< libSRTP AES-128-GCM provider is linked.
  } clsp_provider_flag_t;

  /** @brief Fixed-layout construction configuration copied by `clsp_core_create`. */
  typedef struct clsp_configuration {
    uint32_t abi_version;  ///< Must equal `CLSP_CORE_ABI_VERSION`.
    uint32_t structure_size;  ///< Must equal `sizeof(clsp_configuration_t)`.
    uint16_t port;  ///< Nonzero UDP application port.
    uint16_t reserved_zero;  ///< Reserved and required to be zero.
    uint32_t profile;  ///< One `clsp_profile_t` value.
    uint32_t competition_capacity_mbps;  ///< Required nonzero ceiling only for competition mode.
    uint32_t telemetry_interval_milliseconds;  ///< Coarse snapshot interval, at least 250 ms.
    uint32_t reserved_flags;  ///< Reserved and required to be zero.
  } clsp_configuration_t;

  /** @brief Coarse native lifecycle notification delivered without core locks held. */
  typedef struct clsp_lifecycle_event {
    uint32_t abi_version;  ///< Event layout version.
    uint32_t structure_size;  ///< Size of this event structure.
    uint32_t state;  ///< One `clsp_lifecycle_state_t` value.
    uint32_t reserved_zero;  ///< Reserved and required to be zero.
  } clsp_lifecycle_event_t;

  /** @brief Low-rate telemetry snapshot copied across the ABI. */
  typedef struct clsp_telemetry_snapshot {
    uint32_t abi_version;  ///< Snapshot layout version.
    uint32_t structure_size;  ///< Size of this snapshot structure.
    uint32_t lifecycle_state;  ///< Current `clsp_lifecycle_state_t` value.
    uint32_t provider_flags;  ///< Linked `clsp_provider_flag_t` mask.
    uint64_t received_datagrams;  ///< Authenticated datagrams received by the core.
    uint64_t transmitted_datagrams;  ///< Datagrams submitted by the core.
    uint64_t dropped_datagrams;  ///< Datagrams discarded by bounded policy.
    uint64_t authentication_failures;  ///< DTLS, SRTP, and SRTCP authentication failures.
  } clsp_telemetry_snapshot_t;

  /**
   * @brief Coarse non-reentrant lifecycle callback.
   *
   * The event is a transient borrowed view valid only for this call. Calling a
   * lifecycle operation on the same core from this callback returns
   * `CLSP_STATUS_REENTRANT_CALLBACK`.
   *
   * @param context Caller-owned context retained by the caller.
   * @param event Transient lifecycle event.
   */
  typedef void (*clsp_lifecycle_callback_t)(void *context, const clsp_lifecycle_event_t *event);

  /**
   * @brief Retain an explicitly owned callback context.
   *
   * This function must not throw or call back into the core.
   *
   * @param context Context to retain before `clsp_core_create` returns.
   */
  typedef void (*clsp_context_retain_t)(void *context);

  /**
   * @brief Release an explicitly owned callback context.
   *
   * This function must not throw or call back into the core.
   *
   * @param context Context to release when the native core is destroyed.
   */
  typedef void (*clsp_context_release_t)(void *context);

  /** @brief Callback table copied during core construction. */
  typedef struct clsp_callbacks {
    uint32_t abi_version;  ///< Must equal `CLSP_CORE_ABI_VERSION`.
    uint32_t structure_size;  ///< Must equal `sizeof(clsp_callbacks_t)`.
    void *context;  ///< Explicitly retained callback context, or null.
    clsp_context_retain_t retain_context;  ///< Required retain operation for nonnull context.
    clsp_context_release_t release_context;  ///< Required release operation for nonnull context.
    clsp_lifecycle_callback_t lifecycle;  ///< Optional coarse lifecycle callback.
  } clsp_callbacks_t;

  /**
   * @brief Return the C ABI version without constructing a core.
   *
   * @return `CLSP_CORE_ABI_VERSION`.
   */
  uint32_t clsp_core_abi_version(void);

  /**
   * @brief Return the portable-core source digest.
   *
   * @return Static null-terminated lowercase SHA-256 string.
   */
  const char *clsp_core_source_digest(void);

  /**
   * @brief Return the linked provider mask.
   *
   * @return Bitwise combination of `clsp_provider_flag_t`.
   */
  uint32_t clsp_core_provider_flags(void);

  /**
   * @brief Construct a native core handle without starting network activity.
   *
   * @param configuration Fixed-layout configuration copied by the core.
   * @param callbacks Optional callback table copied by the core.
   * @param output Receives an owned handle with retain count one on success.
   * @return Typed construction status.
   */
  clsp_status_t clsp_core_create(
    const clsp_configuration_t *configuration,
    const clsp_callbacks_t *callbacks,
    clsp_core_t **output
  );

  /**
   * @brief Add one owning reference to a core handle.
   *
   * @param core Core handle, or null for no operation.
   */
  void clsp_core_retain(clsp_core_t *core);

  /**
   * @brief Release one owning reference to a core handle.
   *
   * @param core Core handle, or null for no operation.
   */
  void clsp_core_release(clsp_core_t *core);

  /**
   * @brief Start native transport ownership after provider validation.
   *
   * @param core Core handle.
   * @return Success or a fail-closed provider/lifecycle status.
   */
  clsp_status_t clsp_core_start(clsp_core_t *core);

  /**
   * @brief Stop native transport ownership and quiesce callbacks.
   *
   * @param core Core handle.
   * @return Typed lifecycle status.
   */
  clsp_status_t clsp_core_stop(clsp_core_t *core);

  /**
   * @brief Copy a low-rate telemetry snapshot.
   *
   * @param core Core handle.
   * @param output Caller-owned fixed-layout output.
   * @return Typed copy status.
   */
  clsp_status_t clsp_core_copy_telemetry(
    const clsp_core_t *core,
    clsp_telemetry_snapshot_t *output
  );

  /**
   * @brief Add one owning reference to a retained callback buffer.
   *
   * @param buffer Buffer handle, or null for no operation.
   */
  void clsp_buffer_retain(clsp_buffer_t *buffer);

  /**
   * @brief Release one owning reference to a retained callback buffer.
   *
   * @param buffer Buffer handle, or null for no operation.
   */
  void clsp_buffer_release(clsp_buffer_t *buffer);

  /**
   * @brief Borrow immutable bytes from a retained buffer.
   *
   * The returned span remains valid while the caller retains `buffer`.
   *
   * @param buffer Retained buffer handle.
   * @param output Receives a borrowed pointer/length span.
   * @return Typed access status.
   */
  clsp_status_t clsp_buffer_bytes(
    const clsp_buffer_t *buffer,
    clsp_const_byte_span_t *output
  );

  /**
   * @brief Return a stable English diagnostic label for one status value.
   *
   * @param status Typed status.
   * @return Static null-terminated diagnostic string.
   */
  const char *clsp_status_description(clsp_status_t status);

#ifdef __cplusplus
}
#endif

#endif
