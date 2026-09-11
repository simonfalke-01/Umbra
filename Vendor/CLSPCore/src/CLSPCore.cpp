/**
 * @file CLSPCore.cpp
 * @brief Fail-closed implementation of Umbra's versioned LSP C ABI.
 */

#include "CLSPCore.h"

#include "core/core.h"
#include "runtime/BufferInternal.h"
#include "runtime/Runtime.h"
#include "runtime/SecureZero.h"
#include "runtime/WolfsslSpake2.h"
#include "transport/generation_fence.h"

#include <atomic>
#include <array>
#include <cstddef>
#include <cstdint>
#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <ctime>
#include <limits>
#include <memory>
#include <mutex>
#include <new>
#include <shared_mutex>

#if defined(__APPLE__)
  #include <dispatch/dispatch.h>
#endif

#if CLSP_CORE_HAS_WOLFSSL
  #if __has_include(<wolfssl/lsp_spake2_settings.h>)
    #include <wolfssl/lsp_spake2_settings.h>
  #else
    #include <wolfssl/options.h>
  #endif
  #include <wolfssl/wolfcrypt/random.h>
#endif

extern "C" std::uint8_t clsp_apple_input_capture_apply_lspg(
  clsp_apple_input_capture_t *capture,
  clsp_const_byte_span_t payload
);

extern "C" void clsp_apple_input_capture_quiesce(
  clsp_apple_input_capture_t *capture
);

extern "C" void clsp_apple_input_capture_retain(
  clsp_apple_input_capture_t *capture
);

extern "C" void clsp_apple_input_capture_release(
  clsp_apple_input_capture_t *capture
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

/** @brief Lifetime-safe internal observation binding shared by association cores. */
struct clsp_handoff_observer_binding;

/** @brief Native core object hidden behind `clsp_core_t`. */
struct clsp_core {
  std::atomic<std::uint32_t> references {1};  ///< Explicit ABI ownership count or terminal finalization sentinel.
  std::atomic<std::uint32_t> state {CLSP_LIFECYCLE_CREATED};  ///< Coarse lifecycle state.
  std::mutex apple_capture_mutex;  ///< Serializes low-rate LSPG application with capture teardown.
  std::mutex handoff_observer_mutex;  ///< Serializes handoff observation binding replacement.
  std::mutex host_hello_mutex;  ///< Serializes authenticated SERVER_HELLO identity binding.
  std::mutex producer_wait_mutex;  ///< Wait owner for native producer-lease drain.
  std::condition_variable producer_wait_condition;  ///< Producer-lease drain notification.
  mutable std::mutex baseline_mutex;  ///< Serializes association-local baseline readiness.
  mutable std::condition_variable baseline_condition;  ///< Baseline readiness wait notification.
  std::mutex device_offer_mutex;  ///< Serializes coarse native hot-plug offers.
  mutable std::mutex native_timing_mutex;  ///< Serializes coarse fixed-layout timing publications.
  mutable std::shared_mutex runtime_mutex;  ///< Prevents runtime reclamation during ABI calls.
  std::atomic<std::uint32_t> producer_leases {0};  ///< In-flight input producer operations.
  std::atomic<bool> producers_accepting {true};  ///< Input producer admission gate.
  clsp_handoff_observer_binding *handoff_observer {};  ///< Non-owning-by-contract ref-counted observer binding.
  clsp_host_hello_identity_t host_hello {};  ///< Exact association-bound authenticated host identity.
  std::array<std::uint8_t, 32> expected_server_spki {};  ///< Current endpoint's pinned server SPKI digest.
  bool host_hello_bound {};  ///< Whether `host_hello` is valid for the current runtime.
  std::uint32_t baseline_connection_generation {};  ///< Last configured association generation.
  std::uint32_t baseline_input_generation {};  ///< Last configured input generation.
  std::uint32_t baseline_authority_epoch {};  ///< Last handoff-derived local authority epoch.
  std::uint64_t baseline_event_generation {};  ///< Monotonic readiness transition generation.
  bool baseline_acknowledged {};  ///< Whether the exact current baseline is authenticated.
  std::array<clsp_device_offer_event_t, 32> device_offers {};  ///< Bounded device-offer ring.
  std::size_t device_offer_read {};  ///< Next event to drain.
  std::size_t device_offer_write {};  ///< Next free event slot.
  std::size_t device_offer_count {};  ///< Occupied events.
  std::uint64_t next_device_offer_sequence {1};  ///< Next nonzero event identity.
  clsp_native_timing_snapshot_t native_timing {};  ///< Latest worker stages merged with device capture evidence.
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
    {
      std::unique_lock runtime_lock(runtime_mutex);
      if (runtime != nullptr) {
        (void)runtime->stop();
        delete runtime;
        runtime = nullptr;
      }
    }
    if (callbacks.context != nullptr) {
      callbacks.release_context(callbacks.context);
    }
    lumen::lsp::secure_zero({reinterpret_cast<std::uint8_t *>(&host_hello), sizeof(host_hello)});
    lumen::lsp::secure_zero(expected_server_spki);
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

/** @brief Lifetime-safe bridge from an association runtime into one handoff owner. */
struct clsp_handoff_observer_binding {
  std::atomic<std::uint32_t> references {1};  ///< Handoff owner plus bound-core references.
  std::mutex mutex;  ///< Serializes owner detachment with active observation calls.
  std::condition_variable condition;  ///< Detachment wait for active observation calls.
  clsp_handoff_t *owner {};  ///< Valid only while `active_calls` protects it.
  std::uint32_t active_calls {};  ///< Observation calls currently using `owner`.
};

/** @brief Native fresh-association authority owner hidden behind `clsp_handoff_t`. */
struct clsp_handoff {
  std::atomic<std::uint32_t> references {1};  ///< Explicit ABI ownership count.
  mutable std::mutex mutex;  ///< Serializes every authority transition and snapshot.
  std::mutex callback_mutex;  ///< Preserves callback ordering without holding core locks.
  clsp_handoff_callbacks_t callbacks {};  ///< Explicitly retained coarse callback table.
  clsp_handoff_observer_binding *observer {};  ///< Shared runtime observation bridge.
  clsp_core_t *active {};  ///< Retained forward-authoritative association core.
  clsp_core_t *candidate {};  ///< Retained uncommitted candidate association core.
  clsp_core_t *retiring {};  ///< Retained prior association after committed handoff.
  lumen::lsp::transport::reconnect_generation_fence fence;  ///< Canonical Photon authority fence.
  std::uint32_t phase {CLSP_HANDOFF_PHASE_AUTHORITATIVE};  ///< Current `clsp_handoff_phase_t`.
  std::uint32_t reason {};  ///< Current `clsp_handoff_reason_t`, or zero.
  std::uint32_t baseline_generation {};  ///< Exact generation gated on a fresh baseline ACK.
  std::uint32_t baseline_authority_epoch {};  ///< Epoch installed when the gated baseline is acknowledged.
  std::uint32_t baseline_connection_generation {};  ///< Association carrying the gated baseline.
  std::uint32_t baseline_rollback_generation {};  ///< Rejected candidate binding same-generation rollback.
  std::uint32_t terminal_reason {};  ///< Latched `clsp_handoff_terminal_reason_t`, or zero.
  bool active_lost {};  ///< Current active transport is no longer usable.
  bool candidate_authenticated {};  ///< Candidate application identity is authenticated.
  bool candidate_lost {};  ///< Candidate transport failed during an in-progress producer drain.
  bool old_input_neutralized {};  ///< Old producer/callback drain completed.
  bool baseline_required {};  ///< Fresh baseline ACK blocks input admission.
  bool attach_committed {};  ///< ATTACH moved authority irreversibly forward.
  bool attach_submitted {};  ///< Native ATTACH send admission succeeded.
  bool forward_only {};  ///< Old association can never regain authority.
  bool transition_in_progress {};  ///< One blocking producer-drain transition is outside the mutex.
  std::uint64_t begun_count {};  ///< Fresh-association attempts begun.
  std::uint64_t committed_count {};  ///< Irreversible ATTACH commits.
  std::uint64_t definite_rollback_count {};  ///< Definitely rejected safe rollbacks.
  std::uint64_t terminal_count {};  ///< Terminal fail-closed transitions.
};

/** @brief Native client-side PIN-pairing owner hidden behind `clsp_pairing_t`. */
struct clsp_pairing {
  std::atomic<std::uint32_t> references {1};  ///< Explicit ABI ownership count.
  mutable std::mutex mutex;  ///< Serializes the one-shot pairing lifecycle.
  clsp_core_t *core {};  ///< Retained authenticated association.
  clsp_host_hello_identity_t host_hello {};  ///< Copied authenticated association identity.
  std::array<std::uint8_t, 32> pairing_exporter {};  ///< Dedicated pairing TLS exporter.
  std::array<std::uint8_t, 16> client_id {};  ///< Stable client UUID bytes.
  std::array<std::uint8_t, 32> client_identity_key {};  ///< Stable Ed25519 client public key.
  std::array<std::uint8_t, 64> client_name {};  ///< Copied UTF-8 client name.
  std::size_t client_name_length {};  ///< Populated client-name bytes.
  std::uint32_t requested_permissions {};  ///< Requested known permission mask.
  std::uint32_t phase {CLSP_PAIRING_PHASE_CREATED};  ///< Current `clsp_pairing_phase_t`.
  std::array<std::uint8_t, 6> pin {};  ///< Secret six-digit ASCII PIN.
  std::array<std::uint8_t, 16> salt {};  ///< Secret per-session scrypt salt.
  std::array<std::uint8_t, 16> client_pairing_nonce {};  ///< BEGIN pairing nonce.
  lumen::lsp::Spake2Point point_a {};  ///< Generated client SPAKE point.
  lumen::lsp::Spake2Point point_b {};  ///< Validated host SPAKE point.
  lumen::lsp::Spake2Confirmation confirmation_a {};  ///< Client confirmation cA.
  std::array<std::uint8_t, 16> pairing_session_id {};  ///< Host-issued PENDING session.
  std::uint32_t effective_permissions {};  ///< Host-bounded permission mask.
  std::uint32_t approval_generation {};  ///< One-time host approval generation.
  std::uint32_t revocation_generation {};  ///< RESULT revocation generation.
  std::uint64_t expires_at_utc_seconds {};  ///< Exact PENDING/CHALLENGE expiry.
  std::array<std::uint8_t, 512> aad {};  ///< Canonical exact-17 pairing AAD.
  std::size_t aad_length {};  ///< Populated AAD bytes.
#if CLSP_CORE_HAS_WOLFSSL
  std::unique_ptr<lumen::lsp::WolfsslSpake2ClientSession> spake;  ///< Secret SPAKE session owner.
#endif
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
  inline constexpr auto finalizing_core_reference =
    std::numeric_limits<std::uint32_t>::max();  ///< Terminal value that forbids zero-reference resurrection.
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

  /** @brief Retain one live core without reviving terminal finalization. */
  [[nodiscard]] bool try_retain_core(clsp_core_t *core) noexcept {
    if (core == nullptr) {
      return false;
    }
    auto references = core->references.load(std::memory_order_relaxed);
    while (references != 0U && references < finalizing_core_reference - 1U) {
      if (core->references.compare_exchange_weak(
            references,
            references + 1U,
            std::memory_order_relaxed,
            std::memory_order_relaxed
          )) {
        return true;
      }
    }
    return false;
  }

#if defined(__APPLE__)
  /** @brief Destroy a callback-released core away from its runtime worker stack. */
  void destroy_core_asynchronously(void *context) noexcept {
    delete static_cast<clsp_core_t *>(context);
  }
#endif

  /** @brief Complete terminal core finalization without joining the current callback worker. */
  void finalize_core(clsp_core_t *core) noexcept {
#if defined(__APPLE__)
    if (callback_stack_contains(core)) {
      dispatch_async_f(
        dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0),
        core,
        destroy_core_asynchronously
      );
      return;
    }
#endif
    delete core;
  }

  /** @brief Bounded callback-stack marker enabling same-core reentry rejection. */
  class callback_core_scope {
  public:
    explicit callback_core_scope(const clsp_core_t *core) noexcept:
        active_ {core != nullptr && active_callback_depth < active_callback_cores.size()} {
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

  thread_local std::array<const clsp_handoff_t *, maximum_callback_stack_depth> active_handoff_callbacks {};
  thread_local std::size_t active_handoff_callback_depth {};

  /** @brief Return whether this thread is executing a callback from `handoff`. */
  [[nodiscard]] bool handoff_callback_stack_contains(const clsp_handoff_t *handoff) noexcept {
    for (std::size_t index = 0; index < active_handoff_callback_depth; ++index) {
      if (active_handoff_callbacks[index] == handoff) {
        return true;
      }
    }
    return false;
  }

  /** @brief Bounded callback-stack marker enabling same-handoff reentry rejection. */
  class handoff_callback_scope {
  public:
    explicit handoff_callback_scope(const clsp_handoff_t *handoff) noexcept:
        active_ {active_handoff_callback_depth < active_handoff_callbacks.size()} {
      if (active_) {
        active_handoff_callbacks[active_handoff_callback_depth++] = handoff;
      }
    }

    handoff_callback_scope(const handoff_callback_scope &) = delete;
    handoff_callback_scope &operator=(const handoff_callback_scope &) = delete;

    ~handoff_callback_scope() {
      if (active_) {
        active_handoff_callbacks[--active_handoff_callback_depth] = nullptr;
      }
    }

    [[nodiscard]] bool active() const noexcept {
      return active_;
    }

  private:
    bool active_ {};  ///< Whether this scope owns one stack entry.
  };

  /** @brief Mark every retained association as a callback owner for core reentry checks. */
  class handoff_core_callback_scope {
  public:
    explicit handoff_core_callback_scope(const clsp_handoff_t &handoff) noexcept {
      const std::array<const clsp_core_t *, 3> cores {
        handoff.active,
        handoff.candidate,
        handoff.retiring,
      };
      for (const auto *core : cores) {
        if (core == nullptr || callback_stack_contains(core)) {
          continue;
        }
        if (active_callback_depth >= active_callback_cores.size()) {
          while (added_ != 0U) {
            active_callback_cores[--active_callback_depth] = nullptr;
            --added_;
          }
          return;
        }
        active_callback_cores[active_callback_depth++] = core;
        ++added_;
      }
      active_ = true;
    }

    handoff_core_callback_scope(const handoff_core_callback_scope &) = delete;
    handoff_core_callback_scope &operator=(const handoff_core_callback_scope &) = delete;

    ~handoff_core_callback_scope() {
      while (added_ != 0U) {
        active_callback_cores[--active_callback_depth] = nullptr;
        --added_;
      }
    }

    [[nodiscard]] bool active() const noexcept {
      return active_;
    }

  private:
    std::size_t added_ {};  ///< Number of association markers owned by this scope.
    bool active_ {};  ///< Whether every distinct association marker fit.
  };

  /** @brief One input-producer call protected against concurrent handoff quiescence. */
  class core_producer_lease {
  public:
    explicit core_producer_lease(clsp_core_t *core) noexcept:
        core_ {core} {
      if (core_ == nullptr || !core_->producers_accepting.load(std::memory_order_acquire)) {
        return;
      }
      core_->producer_leases.fetch_add(1, std::memory_order_acq_rel);
      if (!core_->producers_accepting.load(std::memory_order_acquire)) {
        release();
        return;
      }
      active_ = true;
    }

    core_producer_lease(const core_producer_lease &) = delete;
    core_producer_lease &operator=(const core_producer_lease &) = delete;

    ~core_producer_lease() {
      if (active_) {
        release();
      }
    }

    [[nodiscard]] bool active() const noexcept {
      return active_;
    }

  private:
    void release() noexcept {
      active_ = false;
      if (core_->producer_leases.fetch_sub(1, std::memory_order_acq_rel) == 1U) {
        std::lock_guard lock(core_->producer_wait_mutex);
        core_->producer_wait_condition.notify_all();
      }
    }

    clsp_core_t *core_ {};  ///< Borrowed core protected by the ABI caller.
    bool active_ {};  ///< Whether one producer lease is held.
  };

  /** @brief Keep a handoff alive across one ABI call and its callbacks. */
  class handoff_call_reference {
  public:
    explicit handoff_call_reference(clsp_handoff_t *handoff) noexcept:
        handoff_ {handoff} {
      clsp_handoff_retain(handoff_);
    }

    handoff_call_reference(const handoff_call_reference &) = delete;
    handoff_call_reference &operator=(const handoff_call_reference &) = delete;

    ~handoff_call_reference() {
      clsp_handoff_release(handoff_);
    }

  private:
    clsp_handoff_t *handoff_ {};  ///< Retained handoff for the current ABI call.
  };

  /** @brief Return one nonzero cryptographically seeded platform baseline identifier. */
  [[nodiscard]] std::uint64_t fresh_baseline_id() noexcept {
#if defined(__APPLE__)
    auto value = (static_cast<std::uint64_t>(arc4random()) << 32U) | arc4random();
    return value == 0U ? std::uint64_t {1} : value;
#else
    static std::atomic<std::uint64_t> fallback {1};
    return fallback.fetch_add(1, std::memory_order_relaxed);
#endif
  }

  /** @brief Return whether fixed bytes contain at least one nonzero octet. */
  template<typename Range>
  [[nodiscard]] bool contains_nonzero(const Range &bytes) noexcept {
    return std::any_of(std::begin(bytes), std::end(bytes), [](const std::uint8_t byte) { return byte != 0U; });
  }

  /** @brief Fill bytes from wolfCrypt's process-backed CSPRNG. */
  [[nodiscard]] clsp_status_t random_bytes(const std::span<std::uint8_t> output) noexcept {
#if CLSP_CORE_HAS_WOLFSSL
    if (output.empty() || output.size() > static_cast<std::size_t>(std::numeric_limits<word32>::max())) {
      return CLSP_STATUS_INVALID_ARGUMENT;
    }
    WC_RNG rng {};
    if (wc_InitRng(&rng) != 0) return CLSP_STATUS_PAIRING_FAILED;
    const auto status = wc_RNG_GenerateBlock(
      &rng,
      output.data(),
      static_cast<word32>(output.size())
    );
    wc_FreeRng(&rng);
    return status == 0 ? CLSP_STATUS_OK : CLSP_STATUS_PAIRING_FAILED;
#else
    (void)output;
    return CLSP_STATUS_MISSING_WOLFSSL;
#endif
  }

  /** @brief Fill a bounded random field and reject the all-zero encoding. */
  [[nodiscard]] clsp_status_t random_nonzero_bytes(const std::span<std::uint8_t> output) noexcept {
    for (std::uint32_t attempt = 0; attempt < 8U; ++attempt) {
      const auto status = random_bytes(output);
      if (status != CLSP_STATUS_OK) return status;
      if (std::any_of(output.begin(), output.end(), [](const std::uint8_t byte) { return byte != 0U; })) {
        return CLSP_STATUS_OK;
      }
    }
    return CLSP_STATUS_PAIRING_FAILED;
  }

  /** @brief Generate an unbiased six-digit ASCII PIN, including leading zeroes. */
  [[nodiscard]] clsp_status_t generate_pairing_pin(std::array<std::uint8_t, 6> &pin) noexcept {
    constexpr std::uint64_t range = std::uint64_t {UINT32_MAX} + 1U;
    constexpr std::uint64_t limit = range / 1'000'000U * 1'000'000U;
    std::array<std::uint8_t, 4> sample_bytes {};
    std::uint32_t sample = 0;
    do {
      const auto status = random_bytes(sample_bytes);
      if (status != CLSP_STATUS_OK) return status;
      sample = static_cast<std::uint32_t>(sample_bytes[0]) << 24U |
               static_cast<std::uint32_t>(sample_bytes[1]) << 16U |
               static_cast<std::uint32_t>(sample_bytes[2]) << 8U |
               static_cast<std::uint32_t>(sample_bytes[3]);
    } while (sample >= limit);
    auto value = sample % 1'000'000U;
    for (std::size_t index = pin.size(); index != 0U; --index) {
      pin[index - 1U] = static_cast<std::uint8_t>('0' + value % 10U);
      value /= 10U;
    }
    lumen::lsp::secure_zero(sample_bytes);
    return CLSP_STATUS_OK;
  }

  /** @brief Validate canonical UTF-8 scalar encoding for a bounded client name. */
  [[nodiscard]] bool valid_utf8_name(const std::span<const std::uint8_t> bytes) noexcept {
    if (bytes.empty() || bytes.size() > 64U) return false;
    std::size_t offset = 0;
    while (offset < bytes.size()) {
      const auto first = bytes[offset++];
      if (first <= 0x7fU) {
        if (first < 0x20U || first == 0x7fU) return false;
        continue;
      }
      std::uint32_t scalar = 0;
      std::size_t continuation = 0;
      if (first >= 0xc2U && first <= 0xdfU) { scalar = first & 0x1fU; continuation = 1; }
      else if (first >= 0xe0U && first <= 0xefU) { scalar = first & 0x0fU; continuation = 2; }
      else if (first >= 0xf0U && first <= 0xf4U) { scalar = first & 0x07U; continuation = 3; }
      else return false;
      if (continuation > bytes.size() - offset) return false;
      for (std::size_t index = 0; index < continuation; ++index) {
        const auto byte = bytes[offset++];
        if ((byte & 0xc0U) != 0x80U) return false;
        scalar = (scalar << 6U) | (byte & 0x3fU);
      }
      if ((continuation == 2U && scalar < 0x800U) ||
          (continuation == 3U && scalar < 0x10000U) ||
          scalar > 0x10ffffU || (scalar >= 0xd800U && scalar <= 0xdfffU)) return false;
    }
    return true;
  }

  /** @brief Bounded deterministic-CBOR encoder for flat pairing maps. */
  class pairing_cbor_encoder {
  public:
    explicit pairing_cbor_encoder(const std::span<std::uint8_t> output) noexcept: output_ {output} {}

    [[nodiscard]] bool map(const std::uint64_t count) noexcept { return head(5U, count); }
    [[nodiscard]] bool unsigned_integer(const std::uint64_t value) noexcept { return head(0U, value); }
    [[nodiscard]] bool bytes(const std::span<const std::uint8_t> value) noexcept {
      return head(2U, value.size()) && append(value);
    }
    [[nodiscard]] bool text(const std::string_view value) noexcept {
      return head(3U, value.size()) && append(std::as_bytes(std::span {value.data(), value.size()}));
    }
    [[nodiscard]] std::size_t size() const noexcept { return offset_; }

  private:
    [[nodiscard]] bool append(const std::span<const std::byte> bytes) noexcept {
      if (bytes.size() > output_.size() - offset_) return false;
      for (const auto byte : bytes) output_[offset_++] = std::to_integer<std::uint8_t>(byte);
      return true;
    }
    [[nodiscard]] bool append(const std::span<const std::uint8_t> bytes) noexcept {
      return append(std::as_bytes(bytes));
    }
    [[nodiscard]] bool octet(const std::uint8_t byte) noexcept {
      if (offset_ == output_.size()) return false;
      output_[offset_++] = byte;
      return true;
    }
    [[nodiscard]] bool head(const std::uint8_t major, const std::uint64_t value) noexcept {
      if (value < 24U) return octet(static_cast<std::uint8_t>(major << 5U | value));
      if (value <= UINT8_MAX) return octet(static_cast<std::uint8_t>(major << 5U | 24U)) && octet(value);
      if (value <= UINT16_MAX) {
        return octet(static_cast<std::uint8_t>(major << 5U | 25U)) && octet(value >> 8U) && octet(value);
      }
      if (value <= UINT32_MAX) {
        if (!octet(static_cast<std::uint8_t>(major << 5U | 26U))) return false;
        for (int shift = 24; shift >= 0; shift -= 8) if (!octet(value >> shift)) return false;
        return true;
      }
      if (!octet(static_cast<std::uint8_t>(major << 5U | 27U))) return false;
      for (int shift = 56; shift >= 0; shift -= 8) if (!octet(value >> shift)) return false;
      return true;
    }

    std::span<std::uint8_t> output_;  ///< Caller-owned fixed output.
    std::size_t offset_ {};  ///< Populated bytes.
  };

  /** @brief Map one provider result to the narrow public pairing status set. */
  [[nodiscard]] constexpr clsp_status_t pairing_status(const lumen::lsp::Spake2Status status) noexcept {
    using Status = lumen::lsp::Spake2Status;
    switch (status) {
      case Status::success: return CLSP_STATUS_OK;
      case Status::invalid_argument:
      case Status::invalid_pin:
      case Status::invalid_salt:
      case Status::invalid_scalar:
      case Status::invalid_point: return CLSP_STATUS_INVALID_CONFIGURATION;
      case Status::invalid_state: return CLSP_STATUS_INVALID_STATE;
      case Status::unavailable: return CLSP_STATUS_MISSING_WOLFSSL;
      case Status::crypto_failure: return CLSP_STATUS_PAIRING_FAILED;
      case Status::confirmation_failed: return CLSP_STATUS_PAIRING_CONFIRMATION_FAILED;
    }
    return CLSP_STATUS_PAIRING_FAILED;
  }

  /** @brief Encode the exact frozen 18-key PIN-pairing AAD. */
  [[nodiscard]] bool build_pairing_aad(
    clsp_pairing_t &pairing,
    const clsp_pairing_challenge_t &challenge
  ) noexcept {
    static constexpr std::string_view label = "lumen-stream/1 pin-pair aad";
    pairing_cbor_encoder encoder {pairing.aad};
    const auto key = [&](const std::uint64_t value) { return encoder.unsigned_integer(value); };
    const auto ok = encoder.map(18U) &&
      key(1U) && encoder.text(label) &&
      key(2U) && encoder.unsigned_integer(1U) &&
      key(3U) && encoder.bytes(pairing.host_hello.host_id) &&
      key(4U) && encoder.bytes(pairing.host_hello.host_identity_key) &&
      key(5U) && encoder.bytes(pairing.host_hello.server_spki_sha256) &&
      key(6U) && encoder.bytes(pairing.client_id) &&
      key(7U) && encoder.bytes(pairing.client_identity_key) &&
      key(8U) && encoder.bytes(challenge.pairing_session_id) &&
      key(9U) && encoder.bytes(pairing.client_pairing_nonce) &&
      key(10U) && encoder.unsigned_integer(pairing.host_hello.connection_generation) &&
      key(11U) && encoder.unsigned_integer(challenge.approval_generation) &&
      key(12U) && encoder.bytes(pairing.host_hello.client_nonce) &&
      key(13U) && encoder.bytes(pairing.host_hello.server_nonce) &&
      key(14U) && encoder.bytes(pairing.salt) &&
      key(15U) && encoder.unsigned_integer(pairing.requested_permissions) &&
      key(16U) && encoder.unsigned_integer(challenge.effective_permissions) &&
      key(17U) && encoder.unsigned_integer(challenge.expires_at_utc_seconds) &&
      key(18U) && encoder.bytes(pairing.pairing_exporter);
    pairing.aad_length = ok ? encoder.size() : 0U;
    return ok;
  }

  /** @brief Encode the exact frozen three-key client signature transcript. */
  [[nodiscard]] bool build_client_signature_input(
    const clsp_pairing_t &pairing,
    clsp_pairing_client_confirmation_t &output
  ) noexcept {
    static constexpr std::string_view label = "lumen-stream/1 pin-pair client";
    pairing_cbor_encoder encoder {output.client_signature_input};
    const auto ok = encoder.map(3U) &&
      encoder.unsigned_integer(1U) && encoder.text(label) &&
      encoder.unsigned_integer(2U) && encoder.bytes(
        std::span<const std::uint8_t> {pairing.aad}.first(pairing.aad_length)
      ) &&
      encoder.unsigned_integer(3U) && encoder.bytes(pairing.confirmation_a);
    if (!ok || encoder.size() > UINT16_MAX) return false;
    output.client_signature_input_length = static_cast<std::uint16_t>(encoder.size());
    return true;
  }

  /** @brief Encode the exact frozen five-key host signature transcript. */
  [[nodiscard]] bool build_host_signature_input(
    const clsp_pairing_t &pairing,
    const lumen::lsp::Spake2Confirmation &confirmation_b,
    const std::uint32_t revocation_generation,
    clsp_pairing_result_t &output
  ) noexcept {
    static constexpr std::string_view label = "lumen-stream/1 pin-pair host";
    pairing_cbor_encoder encoder {output.host_signature_input};
    const auto ok = encoder.map(5U) &&
      encoder.unsigned_integer(1U) && encoder.text(label) &&
      encoder.unsigned_integer(2U) && encoder.bytes(
        std::span<const std::uint8_t> {pairing.aad}.first(pairing.aad_length)
      ) &&
      encoder.unsigned_integer(3U) && encoder.bytes(pairing.confirmation_a) &&
      encoder.unsigned_integer(4U) && encoder.bytes(confirmation_b) &&
      encoder.unsigned_integer(5U) && encoder.unsigned_integer(revocation_generation);
    if (!ok || encoder.size() > UINT16_MAX) return false;
    output.host_signature_input_length = static_cast<std::uint16_t>(encoder.size());
    return true;
  }

  /** @brief Zeroize every pairing secret while preserving secret-free terminal telemetry. */
  void zeroize_pairing_secrets(clsp_pairing_t &pairing) noexcept {
#if CLSP_CORE_HAS_WOLFSSL
    pairing.spake.reset();
#endif
    lumen::lsp::secure_zero(pairing.pin);
    lumen::lsp::secure_zero(pairing.salt);
    lumen::lsp::secure_zero(pairing.client_pairing_nonce);
    lumen::lsp::secure_zero(pairing.point_a);
    lumen::lsp::secure_zero(pairing.point_b);
    lumen::lsp::secure_zero(pairing.confirmation_a);
    lumen::lsp::secure_zero(pairing.pairing_exporter);
    lumen::lsp::secure_zero(pairing.aad);
    pairing.aad_length = 0;
  }

  /** @brief Latch non-retryable pairing failure and zeroize every secret. */
  [[nodiscard]] clsp_status_t fail_pairing_locked(
    clsp_pairing_t &pairing,
    const clsp_status_t status
  ) noexcept {
    pairing.phase = CLSP_PAIRING_PHASE_FAILED;
    zeroize_pairing_secrets(pairing);
    return status;
  }

  /** @brief Return whether the current UTC whole second reached pairing expiry. */
  [[nodiscard]] bool pairing_expired(const clsp_pairing_t &pairing) noexcept {
    const auto now = std::time(nullptr);
    return now < 0 || pairing.expires_at_utc_seconds == 0U ||
           static_cast<std::uint64_t>(now) >= pairing.expires_at_utc_seconds;
  }

  /** @brief Verify that the pairing still names its original authenticated association. */
  [[nodiscard]] bool pairing_association_authenticated(const clsp_pairing_t &pairing) noexcept {
    std::shared_lock runtime_lock(pairing.core->runtime_mutex);
    return pairing.core->runtime != nullptr &&
           pairing.core->state.load(std::memory_order_acquire) == CLSP_LIFECYCLE_AUTHENTICATED &&
           pairing.core->runtime->current_connection_generation() == pairing.host_hello.connection_generation;
  }

  /** @brief Add one owning reference to an internal observer binding. */
  void retain_observer_binding(clsp_handoff_observer_binding *binding) noexcept {
    if (binding != nullptr) {
      binding->references.fetch_add(1, std::memory_order_relaxed);
    }
  }

  /** @brief Release one internal observer binding reference. */
  void release_observer_binding(clsp_handoff_observer_binding *binding) noexcept {
    if (binding != nullptr && binding->references.fetch_sub(1, std::memory_order_acq_rel) == 1U) {
      delete binding;
    }
  }

  /** @brief Bind one association core to a lifetime-safe handoff observer. */
  [[nodiscard]] bool bind_handoff_observer(
    clsp_core_t *core,
    clsp_handoff_observer_binding *binding
  ) noexcept {
    if (core == nullptr || binding == nullptr) {
      return false;
    }
    std::lock_guard lock(core->handoff_observer_mutex);
    if (core->handoff_observer != nullptr) {
      return false;
    }
    retain_observer_binding(binding);
    core->handoff_observer = binding;
    return true;
  }

  /** @brief Remove one exact association-to-handoff observation binding. */
  void unbind_handoff_observer(
    clsp_core_t *core,
    clsp_handoff_observer_binding *binding
  ) noexcept {
    if (core == nullptr || binding == nullptr) {
      return;
    }
    clsp_handoff_observer_binding *released = nullptr;
    {
      std::lock_guard lock(core->handoff_observer_mutex);
      if (core->handoff_observer == binding) {
        released = core->handoff_observer;
        core->handoff_observer = nullptr;
      }
    }
    release_observer_binding(released);
  }

  /** @brief Invoke one lifetime-safe internal handoff observation. */
  template<typename Operation>
  void with_handoff_observer(clsp_core_t *core, Operation &&operation) noexcept {
    clsp_handoff_observer_binding *binding = nullptr;
    {
      std::lock_guard lock(core->handoff_observer_mutex);
      binding = core->handoff_observer;
      retain_observer_binding(binding);
    }
    if (binding == nullptr) {
      return;
    }
    clsp_handoff_t *owner = nullptr;
    {
      std::lock_guard lock(binding->mutex);
      if (binding->owner != nullptr) {
        ++binding->active_calls;
        owner = binding->owner;
        clsp_handoff_retain(owner);
      }
    }
    if (owner != nullptr) {
      operation(owner);
      {
        std::lock_guard lock(binding->mutex);
        if (--binding->active_calls == 0U) {
          binding->condition.notify_all();
        }
      }
      clsp_handoff_release(owner);
    }
    release_observer_binding(binding);
  }

  /** @brief Close producer admission and wait until all high-rate calls have returned. */
  [[nodiscard]] clsp_status_t quiesce_core_producers(clsp_core_t *core) noexcept {
    if (core == nullptr) {
      return CLSP_STATUS_INVALID_ARGUMENT;
    }
    clsp_apple_input_capture_t *capture = nullptr;
    {
      std::lock_guard capture_lock(core->apple_capture_mutex);
      capture = core->apple_capture;
      if (capture != nullptr) {
        clsp_apple_input_capture_retain(capture);
        core->apple_capture = nullptr;
      }
    }
    if (capture != nullptr) {
      clsp_apple_input_capture_quiesce(capture);
      clsp_apple_input_capture_release(capture);
    }
    core->producers_accepting.store(false, std::memory_order_release);
    {
      std::unique_lock wait_lock(core->producer_wait_mutex);
      core->producer_wait_condition.wait(wait_lock, [&] {
        return core->producer_leases.load(std::memory_order_acquire) == 0U;
      });
    }
    std::shared_lock runtime_lock(core->runtime_mutex);
    return core->runtime == nullptr ? CLSP_STATUS_OK : core->runtime->quiesce_input();
  }

  /** @brief Reopen high-rate producer admission after an exact fresh baseline ACK. */
  void resume_core_producers(clsp_core_t *core) noexcept {
    if (core != nullptr) {
      core->producers_accepting.store(true, std::memory_order_release);
    }
  }

  /** @brief Install one association-local callback epoch for baseline readiness. */
  void set_core_baseline_authority_epoch(
    clsp_core_t *core,
    const std::uint32_t input_authority_epoch
  ) noexcept {
    if (core == nullptr || input_authority_epoch == 0U) {
      return;
    }
    std::lock_guard baseline_lock(core->baseline_mutex);
    core->baseline_authority_epoch = input_authority_epoch;
  }

  /** @brief Map a canonical generation-fence rejection onto the narrow ABI status set. */
  [[nodiscard]] constexpr clsp_status_t fence_status(
    const lumen::lsp::transport::generation_fence_result result
  ) noexcept {
    using Result = lumen::lsp::transport::generation_fence_result;
    switch (result) {
      case Result::accepted:
        return CLSP_STATUS_OK;
      case Result::invalid_generation:
      case Result::candidate_mismatch:
      case Result::active_authority_mismatch:
      case Result::baseline_mismatch:
      case Result::retiring_mismatch:
        return CLSP_STATUS_INVALID_CONFIGURATION;
      case Result::wrong_phase:
      case Result::input_not_neutralized:
        return CLSP_STATUS_INVALID_STATE;
    }
    return CLSP_STATUS_INTERNAL_FAILURE;
  }

  /** @brief Return one association lifecycle without exposing runtime details. */
  [[nodiscard]] std::uint32_t core_lifecycle(const clsp_core_t *core) noexcept {
    return core == nullptr ? CLSP_LIFECYCLE_STOPPED : core->state.load(std::memory_order_acquire);
  }

  /** @brief Fill a secret-free handoff snapshot while its state mutex is held. */
  void fill_handoff_snapshot_locked(
    const clsp_handoff_t &handoff,
    clsp_handoff_snapshot_t &output
  ) noexcept {
    const auto fence = handoff.fence.snapshot();
    output = {
      .abi_version = CLSP_CORE_ABI_VERSION,
      .structure_size = sizeof(clsp_handoff_snapshot_t),
      .active_connection_generation = fence.active_connection_generation,
      .active_input_generation = fence.active_input_generation,
      .input_authority_epoch = fence.input_authority_epoch,
      .connection_generation_high_watermark = fence.connection_generation_high_watermark,
      .candidate_connection_generation = fence.candidate_connection_generation,
      .rollback_connection_generation = fence.rollback_connection_generation,
      .retiring_connection_generation = fence.retiring_connection_generation,
      .phase = handoff.phase,
      .reason = handoff.reason,
      .active_lifecycle_state = core_lifecycle(handoff.active),
      .candidate_lifecycle_state = core_lifecycle(handoff.candidate),
      .retiring_lifecycle_state = core_lifecycle(handoff.retiring),
      .begun_count = handoff.begun_count,
      .committed_count = handoff.committed_count,
      .definite_rollback_count = handoff.definite_rollback_count,
      .terminal_count = handoff.terminal_count,
      .active_lost = static_cast<std::uint8_t>(handoff.active_lost),
      .candidate_authenticated = static_cast<std::uint8_t>(handoff.candidate_authenticated),
      .old_input_neutralized = static_cast<std::uint8_t>(handoff.old_input_neutralized),
      .baseline_required = static_cast<std::uint8_t>(handoff.baseline_required),
      .attach_committed = static_cast<std::uint8_t>(handoff.attach_committed),
      .forward_only = static_cast<std::uint8_t>(handoff.forward_only),
      .has_candidate = static_cast<std::uint8_t>(handoff.candidate != nullptr),
      .has_retiring = static_cast<std::uint8_t>(handoff.retiring != nullptr),
    };
  }

  /** @brief Fill one association-local baseline snapshot while its mutex is held. */
  void fill_input_baseline_snapshot_locked(
    const clsp_core_t &core,
    clsp_input_baseline_snapshot_t &output
  ) noexcept {
    output = {
      .abi_version = CLSP_CORE_ABI_VERSION,
      .structure_size = sizeof(clsp_input_baseline_snapshot_t),
      .connection_generation = core.baseline_connection_generation,
      .input_generation = core.baseline_input_generation,
      .input_authority_epoch = core.baseline_authority_epoch,
      .reserved_zero = 0,
      .event_generation = core.baseline_event_generation,
      .acknowledged = static_cast<std::uint8_t>(core.baseline_acknowledged),
      .reserved_tail = {},
    };
  }

  /** @brief Publish one ordered non-reentrant phase callback with the state mutex held. */
  void publish_handoff_phase_locked(clsp_handoff_t *handoff) noexcept {
    if (handoff->callbacks.phase == nullptr) {
      return;
    }
    std::lock_guard callback_lock(handoff->callback_mutex);
    handoff_callback_scope callback_scope {handoff};
    handoff_core_callback_scope core_callback_scope {*handoff};
    if (!callback_scope.active() || !core_callback_scope.active()) {
      return;
    }
    const auto fence = handoff->fence.snapshot();
    const clsp_handoff_phase_event_t event {
      .abi_version = CLSP_CORE_ABI_VERSION,
      .structure_size = sizeof(clsp_handoff_phase_event_t),
      .phase = handoff->phase,
      .reason = handoff->reason,
      .active_connection_generation = fence.active_connection_generation,
      .active_input_generation = fence.active_input_generation,
      .candidate_connection_generation = fence.candidate_connection_generation,
      .baseline_required = static_cast<std::uint8_t>(handoff->baseline_required),
      .forward_only = static_cast<std::uint8_t>(handoff->forward_only),
      .reserved_zero = {},
    };
    handoff->callbacks.phase(handoff->callbacks.context, &event);
  }

  /** @brief Publish one ordered non-reentrant baseline callback with the state mutex held. */
  void publish_handoff_baseline_locked(
    clsp_handoff_t *handoff,
    const std::uint32_t kind,
    const std::uint32_t input_generation
  ) noexcept {
    if (handoff->callbacks.baseline == nullptr) {
      return;
    }
    std::lock_guard callback_lock(handoff->callback_mutex);
    handoff_callback_scope callback_scope {handoff};
    handoff_core_callback_scope core_callback_scope {*handoff};
    if (!callback_scope.active() || !core_callback_scope.active()) {
      return;
    }
    const clsp_handoff_baseline_event_t event {
      .abi_version = CLSP_CORE_ABI_VERSION,
      .structure_size = sizeof(clsp_handoff_baseline_event_t),
      .kind = kind,
      .input_generation = input_generation,
      .input_authority_epoch = handoff->baseline_authority_epoch,
      .connection_generation = handoff->baseline_connection_generation,
      .rollback_connection_generation = handoff->baseline_rollback_generation,
      .reserved_zero = 0,
    };
    handoff->callbacks.baseline(handoff->callbacks.context, &event);
  }

  /** @brief Publish one ordered non-reentrant reconnect/rekey callback. */
  void publish_handoff_rekey_locked(clsp_handoff_t *handoff) noexcept {
    if (handoff->callbacks.rekey == nullptr) {
      return;
    }
    std::lock_guard callback_lock(handoff->callback_mutex);
    handoff_callback_scope callback_scope {handoff};
    handoff_core_callback_scope core_callback_scope {*handoff};
    if (!callback_scope.active() || !core_callback_scope.active()) {
      return;
    }
    const auto fence = handoff->fence.snapshot();
    const clsp_handoff_rekey_event_t event {
      .abi_version = CLSP_CORE_ABI_VERSION,
      .structure_size = sizeof(clsp_handoff_rekey_event_t),
      .reason = handoff->reason,
      .candidate_connection_generation = fence.candidate_connection_generation,
    };
    handoff->callbacks.rekey(handoff->callbacks.context, &event);
  }

  /** @brief Publish one ordered latched terminal callback with the state mutex held. */
  void publish_handoff_terminal_locked(clsp_handoff_t *handoff) noexcept {
    if (handoff->callbacks.terminal == nullptr || handoff->terminal_reason == 0U) {
      return;
    }
    std::lock_guard callback_lock(handoff->callback_mutex);
    handoff_callback_scope callback_scope {handoff};
    handoff_core_callback_scope core_callback_scope {*handoff};
    if (!callback_scope.active() || !core_callback_scope.active()) {
      return;
    }
    const clsp_handoff_terminal_event_t event {
      .abi_version = CLSP_CORE_ABI_VERSION,
      .structure_size = sizeof(clsp_handoff_terminal_event_t),
      .reason = handoff->terminal_reason,
      .last_connection_generation = handoff->fence.snapshot().active_connection_generation,
    };
    handoff->callbacks.terminal(handoff->callbacks.context, &event);
  }

  /** @brief Enter the terminal forward-only state exactly once. */
  void enter_handoff_terminal_locked(
    clsp_handoff_t *handoff,
    const std::uint32_t terminal_reason
  ) noexcept {
    if (handoff->phase == CLSP_HANDOFF_PHASE_TERMINAL) {
      return;
    }
    handoff->phase = CLSP_HANDOFF_PHASE_TERMINAL;
    handoff->terminal_reason = terminal_reason;
    handoff->forward_only = true;
    handoff->baseline_required = false;
    ++handoff->terminal_count;
    publish_handoff_phase_locked(handoff);
    publish_handoff_terminal_locked(handoff);
  }

  /** @brief Association ownership released and baseline work started by definite rollback. */
  struct handoff_rollback_work {
    clsp_core_t *candidate {};  ///< Candidate removed from handoff ownership.
    clsp_core_t *active {};  ///< Retained old association receiving the fresh baseline.
    std::uint64_t baseline_id {};  ///< Exact fresh neutral baseline identifier.
  };

  /** @brief Enter same-wire-generation rollback after old input has been neutralized. */
  [[nodiscard]] clsp_status_t begin_handoff_rollback_locked(
    clsp_handoff_t *handoff,
    handoff_rollback_work &work
  ) noexcept {
    if (handoff->candidate == nullptr || !handoff->old_input_neutralized || handoff->active_lost) {
      return CLSP_STATUS_INVALID_STATE;
    }
    const auto before = handoff->fence.snapshot();
    work.baseline_id = fresh_baseline_id();
    const auto status = fence_status(handoff->fence.reject_attach(
      before.candidate_connection_generation,
      work.baseline_id
    ));
    if (status != CLSP_STATUS_OK) {
      return status;
    }
    const auto rollback = handoff->fence.snapshot();
    work.candidate = handoff->candidate;
    work.active = handoff->active;
    clsp_core_retain(work.active);
    set_core_baseline_authority_epoch(work.active, rollback.rollback_connection_generation);
    handoff->candidate = nullptr;
    handoff->candidate_authenticated = false;
    handoff->candidate_lost = false;
    handoff->attach_submitted = false;
    handoff->baseline_required = true;
    handoff->baseline_generation = rollback.active_input_generation;
    handoff->baseline_authority_epoch = rollback.rollback_connection_generation;
    handoff->baseline_connection_generation = rollback.active_connection_generation;
    handoff->baseline_rollback_generation = rollback.rollback_connection_generation;
    handoff->phase = CLSP_HANDOFF_PHASE_ROLLBACK_PENDING;
    publish_handoff_phase_locked(handoff);
    publish_handoff_baseline_locked(
      handoff,
      CLSP_HANDOFF_BASELINE_REQUIRED,
      handoff->baseline_generation
    );
    return CLSP_STATUS_OK;
  }

  /** @brief Release a rejected candidate and install its exact old-association baseline. */
  [[nodiscard]] clsp_status_t complete_handoff_rollback(
    clsp_handoff_t *handoff,
    const handoff_rollback_work &work,
    const bool stop_candidate
  ) noexcept {
    if (work.candidate != nullptr) {
      unbind_handoff_observer(work.candidate, handoff->observer);
      if (stop_candidate) {
        (void)clsp_core_stop(work.candidate);
      }
      clsp_core_release(work.candidate);
    }
    if (work.active == nullptr) {
      return CLSP_STATUS_INTERNAL_FAILURE;
    }
    clsp_status_t restart_status = CLSP_STATUS_NOT_AUTHENTICATED;
    {
      std::shared_lock runtime_lock(work.active->runtime_mutex);
      if (work.active->runtime != nullptr) {
        restart_status = work.active->runtime->restart_input_baseline(work.baseline_id);
      }
    }
    clsp_core_release(work.active);
    if (restart_status != CLSP_STATUS_OK) {
      std::lock_guard lock(handoff->mutex);
      enter_handoff_terminal_locked(handoff, CLSP_HANDOFF_TERMINAL_BASELINE_FAILED);
    }
    return restart_status;
  }

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
  void publish_lifecycle(
    clsp_core_t *core,
    const std::uint32_t state,
    const clsp_status_t terminal_status
  ) noexcept {
    core->state.store(state, std::memory_order_release);
    if (core->callbacks.lifecycle == nullptr) {
      return;
    }
    if (!try_retain_core(core)) {
      return;
    }
    const clsp_lifecycle_event_t event {
      .abi_version = CLSP_CORE_ABI_VERSION,
      .structure_size = sizeof(clsp_lifecycle_event_t),
      .state = state,
      .reserved_zero = 0,
      .terminal_status = static_cast<std::uint32_t>(terminal_status),
    };
    callback_core_scope callback_scope {core};
    if (!callback_scope.active()) {
      clsp_core_release(core);
      return;
    }
    core->callbacks.lifecycle(core->callbacks.context, &event);
    clsp_core_release(core);
  }

  /** @brief Publish one authenticated control event without core locks held. */
  void publish_control(clsp_core_t *core, const clsp_control_event_t &event) noexcept {
    if (core->callbacks.control == nullptr) {
      return;
    }
    if (!try_retain_core(core)) {
      return;
    }
    callback_core_scope callback_scope {core};
    if (!callback_scope.active()) {
      clsp_core_release(core);
      return;
    }
    core->callbacks.control(core->callbacks.context, &event);
    clsp_core_release(core);
  }

  /** @brief Receive one native runtime lifecycle transition. */
  void runtime_lifecycle(
    void *context,
    const std::uint32_t state,
    const clsp_status_t terminal_status
  ) noexcept {
    auto *core = static_cast<clsp_core_t *>(context);
    const auto raw_terminal = static_cast<std::uint32_t>(terminal_status);
    const auto assigned_terminal = raw_terminal <=
      static_cast<std::uint32_t>(CLSP_STATUS_PAIRING_CONFIRMATION_FAILED);
    const auto valid_terminal = assigned_terminal &&
      (state == CLSP_LIFECYCLE_FAILED ? terminal_status != CLSP_STATUS_OK : terminal_status == CLSP_STATUS_OK);
    const auto published_state = valid_terminal ? state : static_cast<std::uint32_t>(CLSP_LIFECYCLE_FAILED);
    publish_lifecycle(
      core,
      published_state,
      valid_terminal ? terminal_status : CLSP_STATUS_INTERNAL_FAILURE
    );
    if (published_state == CLSP_LIFECYCLE_FAILED) {
      with_handoff_observer(core, [&](clsp_handoff_t *handoff) {
        (void)clsp_handoff_lost(handoff, core);
      });
    }
  }

  /** @brief Receive one native authenticated LSPC frame. */
  void runtime_control(void *context, const clsp_control_event_t &event) noexcept {
    publish_control(static_cast<clsp_core_t *>(context), event);
  }

  /** @brief Receive one authenticated native input-baseline ACK. */
  void runtime_input_baseline(
    void *context,
    const bool acknowledged,
    const std::uint32_t connection_generation,
    const std::uint32_t input_generation,
    const std::uint64_t baseline_id
  ) noexcept {
    auto *core = static_cast<clsp_core_t *>(context);
    bool handoff_bound = false;
    {
      std::lock_guard observer_lock(core->handoff_observer_mutex);
      handoff_bound = core->handoff_observer != nullptr;
    }
    if (acknowledged) {
      with_handoff_observer(core, [&](clsp_handoff_t *handoff) {
        (void)clsp_handoff_acknowledge_baseline(handoff, input_generation, baseline_id);
      });
    }
    {
      std::lock_guard baseline_lock(core->baseline_mutex);
      core->baseline_connection_generation = connection_generation;
      core->baseline_input_generation = input_generation;
      if (!handoff_bound || core->baseline_authority_epoch == 0U) {
        core->baseline_authority_epoch = connection_generation;
      }
      core->baseline_acknowledged = acknowledged;
      ++core->baseline_event_generation;
      if (core->baseline_event_generation == 0U) {
        ++core->baseline_event_generation;
      }
      core->baseline_condition.notify_all();
    }
    if (!acknowledged) {
      return;
    }
  }

  /** @brief Publish one authenticated complete Opus packet. */
  void runtime_audio_packet(void *context, const clsp_audio_packet_event_t &event) noexcept {
    auto *core = static_cast<clsp_core_t *>(context);
    if (core->callbacks.audio_packet == nullptr) return;
    if (!try_retain_core(core)) {
      return;
    }
    callback_core_scope callback_scope {core};
    if (!callback_scope.active()) {
      clsp_core_release(core);
      return;
    }
    core->callbacks.audio_packet(core->callbacks.context, &event);
    clsp_core_release(core);
  }

  /** @brief Publish one authenticated audio sender-report timeline. */
  void runtime_audio_timing(void *context, const clsp_audio_timing_event_t &event) noexcept {
    auto *core = static_cast<clsp_core_t *>(context);
    if (core->callbacks.audio_timing == nullptr) return;
    if (!try_retain_core(core)) {
      return;
    }
    callback_core_scope callback_scope {core};
    if (!callback_scope.active()) {
      clsp_core_release(core);
      return;
    }
    core->callbacks.audio_timing(core->callbacks.context, &event);
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
    if (!try_retain_core(core)) {
      clsp_buffer_release(event.frame);
      return;
    }
    callback_core_scope callback_scope {core};
    if (!callback_scope.active()) {
      clsp_buffer_release(event.frame);
      clsp_core_release(core);
      return;
    }
    core->callbacks.video_access_unit(core->callbacks.context, &event);
    clsp_core_release(core);
  }

  /** @brief Publish one low-rate authenticated path-probe lifecycle event. */
  bool runtime_path_probe(void *context, const clsp_path_probe_event_t &event) noexcept {
    auto *core = static_cast<clsp_core_t *>(context);
    if (core->callbacks.path_probe == nullptr) {
      return true;
    }
    if (!try_retain_core(core)) {
      return false;
    }
    callback_core_scope callback_scope {core};
    if (!callback_scope.active()) {
      clsp_core_release(core);
      return false;
    }
    core->callbacks.path_probe(core->callbacks.context, &event);
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

  /** @brief Publish one worker-owned native timing snapshot without invoking product callbacks. */
  void runtime_timing(void *context, const clsp_native_timing_snapshot_t &snapshot) noexcept {
    auto *core = static_cast<clsp_core_t *>(context);
    std::lock_guard lock(core->native_timing_mutex);
    core->native_timing.abi_version = CLSP_CORE_ABI_VERSION;
    core->native_timing.structure_size = sizeof(clsp_native_timing_snapshot_t);
    core->native_timing.snapshot_generation = snapshot.snapshot_generation;
    core->native_timing.snapshot_time_microseconds = snapshot.snapshot_time_microseconds;
    core->native_timing.stream_generation = snapshot.stream_generation;
    core->native_timing.input_generation = snapshot.input_generation;
    core->native_timing.video_generation = snapshot.video_generation;
    core->native_timing.audio_generation = snapshot.audio_generation;
    core->native_timing.pointer_generation = snapshot.pointer_generation;
    std::copy(std::begin(snapshot.controller_generations), std::end(snapshot.controller_generations),
              std::begin(core->native_timing.controller_generations));
    std::copy(std::begin(snapshot.touch_generations), std::end(snapshot.touch_generations),
              std::begin(core->native_timing.touch_generations));
    std::copy(std::begin(snapshot.pen_generations), std::end(snapshot.pen_generations),
              std::begin(core->native_timing.pen_generations));
    std::copy(std::begin(snapshot.stages), std::end(snapshot.stages), std::begin(core->native_timing.stages));
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
  (void)try_retain_core(core);
}

extern "C" void clsp_core_release(clsp_core_t *core) {
  if (core == nullptr) {
    return;
  }
  auto references = core->references.load(std::memory_order_acquire);
  while (references != 0U && references != finalizing_core_reference) {
    const auto next = references == 1U ? finalizing_core_reference : references - 1U;
    if (!core->references.compare_exchange_weak(
          references,
          next,
          std::memory_order_acq_rel,
          std::memory_order_acquire
        )) {
      continue;
    }
    if (next == finalizing_core_reference) {
      finalize_core(core);
    }
    return;
  }
}

extern "C" clsp_status_t clsp_core_bind_host_hello(
  clsp_core_t *core,
  const clsp_host_hello_identity_t *identity
) {
  if (core == nullptr || identity == nullptr) return CLSP_STATUS_INVALID_ARGUMENT;
  if (callback_stack_contains(core)) return CLSP_STATUS_REENTRANT_CALLBACK;
  if (identity->abi_version != CLSP_CORE_ABI_VERSION ||
      identity->structure_size != sizeof(clsp_host_hello_identity_t)) {
    return CLSP_STATUS_ABI_MISMATCH;
  }
  const auto nonzero = [](const auto &bytes) {
    return std::any_of(std::begin(bytes), std::end(bytes), [](const std::uint8_t byte) { return byte != 0U; });
  };
  if (identity->connection_generation == 0U || identity->reserved_zero != 0U ||
      !nonzero(identity->host_id) || !nonzero(identity->host_identity_key) ||
      !nonzero(identity->server_spki_sha256) || !nonzero(identity->client_nonce) ||
      !nonzero(identity->server_nonce)) {
    return CLSP_STATUS_INVALID_CONFIGURATION;
  }
  std::shared_lock runtime_lock(core->runtime_mutex);
  if (core->runtime == nullptr || core->state.load(std::memory_order_acquire) != CLSP_LIFECYCLE_AUTHENTICATED) {
    return CLSP_STATUS_NOT_AUTHENTICATED;
  }
  if (core->runtime->current_connection_generation() != identity->connection_generation) {
    return CLSP_STATUS_PAIRING_GENERATION_MISMATCH;
  }
  std::lock_guard host_lock(core->host_hello_mutex);
  if (!std::equal(
        std::begin(identity->server_spki_sha256),
        std::end(identity->server_spki_sha256),
        core->expected_server_spki.begin()
      )) {
    return CLSP_STATUS_SPKI_MISMATCH;
  }
  if (core->host_hello_bound) {
    return std::memcmp(&core->host_hello, identity, sizeof(*identity)) == 0 ?
             CLSP_STATUS_OK : CLSP_STATUS_INVALID_STATE;
  }
  core->host_hello = *identity;
  core->host_hello_bound = true;
  return CLSP_STATUS_OK;
}

extern "C" clsp_status_t clsp_pairing_create(
  clsp_core_t *core,
  const clsp_pairing_configuration_t *configuration,
  clsp_pairing_t **output
) {
  if (core == nullptr || configuration == nullptr || output == nullptr) {
    return CLSP_STATUS_INVALID_ARGUMENT;
  }
  *output = nullptr;
  if (callback_stack_contains(core)) return CLSP_STATUS_REENTRANT_CALLBACK;
  if (configuration->abi_version != CLSP_CORE_ABI_VERSION ||
      configuration->structure_size != sizeof(clsp_pairing_configuration_t)) {
    return CLSP_STATUS_ABI_MISMATCH;
  }
  const auto client_name = std::span<const std::uint8_t> {
    configuration->client_name.data,
    configuration->client_name.length
  };
  constexpr std::uint32_t known_permissions = 0x7fU;
  if (configuration->client_name.data == nullptr || !valid_utf8_name(client_name) ||
      !contains_nonzero(configuration->client_id) || !contains_nonzero(configuration->client_identity_key) ||
      configuration->requested_permissions == 0U ||
      (configuration->requested_permissions & ~known_permissions) != 0U || configuration->reserved_zero != 0U) {
    return CLSP_STATUS_INVALID_CONFIGURATION;
  }

  std::array<std::uint8_t, 32> pairing_exporter {};
  std::uint32_t connection_generation = 0;
  {
    std::shared_lock runtime_lock(core->runtime_mutex);
    if (core->runtime == nullptr || core->state.load(std::memory_order_acquire) != CLSP_LIFECYCLE_AUTHENTICATED) {
      return CLSP_STATUS_NOT_AUTHENTICATED;
    }
    connection_generation = core->runtime->current_connection_generation();
    const auto exporter_status = core->runtime->copy_pairing_exporter(pairing_exporter);
    if (exporter_status != CLSP_STATUS_OK) return exporter_status;
  }
  clsp_host_hello_identity_t host_hello {};
  {
    std::lock_guard host_lock(core->host_hello_mutex);
    if (!core->host_hello_bound || core->host_hello.connection_generation != connection_generation) {
      lumen::lsp::secure_zero(pairing_exporter);
      return CLSP_STATUS_NOT_AUTHENTICATED;
    }
    host_hello = core->host_hello;
  }

  auto *pairing = new (std::nothrow) clsp_pairing_t;
  if (pairing == nullptr) {
    lumen::lsp::secure_zero(pairing_exporter);
    return CLSP_STATUS_RESOURCE_EXHAUSTED;
  }
  pairing->core = core;
  clsp_core_retain(core);
  pairing->host_hello = host_hello;
  pairing->pairing_exporter = pairing_exporter;
  std::copy_n(configuration->client_id, pairing->client_id.size(), pairing->client_id.begin());
  std::copy_n(
    configuration->client_identity_key,
    pairing->client_identity_key.size(),
    pairing->client_identity_key.begin()
  );
  std::copy(client_name.begin(), client_name.end(), pairing->client_name.begin());
  pairing->client_name_length = client_name.size();
  pairing->requested_permissions = configuration->requested_permissions;
  lumen::lsp::secure_zero(pairing_exporter);
  *output = pairing;
  return CLSP_STATUS_OK;
}

extern "C" void clsp_pairing_retain(clsp_pairing_t *pairing) {
  if (pairing != nullptr) pairing->references.fetch_add(1, std::memory_order_relaxed);
}

extern "C" void clsp_pairing_release(clsp_pairing_t *pairing) {
  if (pairing == nullptr || pairing->references.fetch_sub(1, std::memory_order_acq_rel) != 1U) return;
  {
    std::lock_guard lock(pairing->mutex);
    zeroize_pairing_secrets(*pairing);
    lumen::lsp::secure_zero(pairing->client_id);
    lumen::lsp::secure_zero(pairing->client_identity_key);
    lumen::lsp::secure_zero(pairing->client_name);
    lumen::lsp::secure_zero({
      reinterpret_cast<std::uint8_t *>(&pairing->host_hello),
      sizeof(pairing->host_hello)
    });
  }
  clsp_core_release(pairing->core);
  pairing->core = nullptr;
  delete pairing;
}

extern "C" clsp_status_t clsp_pairing_begin(
  clsp_pairing_t *pairing,
  clsp_pairing_begin_t *output
) {
  if (pairing == nullptr || output == nullptr) return CLSP_STATUS_INVALID_ARGUMENT;
  *output = {.abi_version = CLSP_CORE_ABI_VERSION, .structure_size = sizeof(*output)};
  if (callback_stack_contains(pairing->core)) return CLSP_STATUS_REENTRANT_CALLBACK;
  std::lock_guard lock(pairing->mutex);
  if (pairing->phase != CLSP_PAIRING_PHASE_CREATED) return CLSP_STATUS_INVALID_STATE;
  if (!pairing_association_authenticated(*pairing)) {
    return fail_pairing_locked(*pairing, CLSP_STATUS_NOT_AUTHENTICATED);
  }
  auto status = generate_pairing_pin(pairing->pin);
  if (status == CLSP_STATUS_OK) status = random_nonzero_bytes(pairing->salt);
  if (status == CLSP_STATUS_OK) status = random_nonzero_bytes(pairing->client_pairing_nonce);
  if (status != CLSP_STATUS_OK) {
    pairing->phase = CLSP_PAIRING_PHASE_FAILED;
    zeroize_pairing_secrets(*pairing);
    return status;
  }
#if CLSP_CORE_HAS_WOLFSSL
  lumen::lsp::Spake2Status provider_status = lumen::lsp::Spake2Status::success;
  pairing->spake = lumen::lsp::WolfsslSpake2ClientSession::create(
    {
      .pin = std::string_view {reinterpret_cast<const char *>(pairing->pin.data()), pairing->pin.size()},
      .salt = pairing->salt,
      .identity_a = pairing->client_id,
      .identity_b = pairing->host_hello.host_id,
    },
    provider_status
  );
  status = pairing_status(provider_status);
  if (status == CLSP_STATUS_OK && pairing->spake != nullptr) {
    status = pairing_status(pairing->spake->start(pairing->point_a));
  }
  if (status != CLSP_STATUS_OK || pairing->spake == nullptr) {
    pairing->phase = CLSP_PAIRING_PHASE_FAILED;
    zeroize_pairing_secrets(*pairing);
    return status == CLSP_STATUS_OK ? CLSP_STATUS_PAIRING_FAILED : status;
  }
#else
  pairing->phase = CLSP_PAIRING_PHASE_FAILED;
  zeroize_pairing_secrets(*pairing);
  return CLSP_STATUS_MISSING_WOLFSSL;
#endif
  std::copy(pairing->pin.begin(), pairing->pin.end(), std::begin(output->pin_digits));
  std::copy(pairing->salt.begin(), pairing->salt.end(), std::begin(output->scrypt_salt));
  std::copy(
    pairing->client_pairing_nonce.begin(),
    pairing->client_pairing_nonce.end(),
    std::begin(output->client_pairing_nonce)
  );
  std::copy(pairing->point_a.begin(), pairing->point_a.end(), std::begin(output->client_point));
  lumen::lsp::secure_zero(pairing->pin);
  pairing->phase = CLSP_PAIRING_PHASE_BEGUN;
  return CLSP_STATUS_OK;
}

extern "C" clsp_status_t clsp_pairing_bind_pending(
  clsp_pairing_t *pairing,
  const clsp_pairing_pending_t *pending
) {
  if (pairing == nullptr || pending == nullptr) return CLSP_STATUS_INVALID_ARGUMENT;
  if (callback_stack_contains(pairing->core)) return CLSP_STATUS_REENTRANT_CALLBACK;
  if (pending->abi_version != CLSP_CORE_ABI_VERSION || pending->structure_size != sizeof(*pending)) {
    return CLSP_STATUS_ABI_MISMATCH;
  }
  std::lock_guard lock(pairing->mutex);
  if (pairing->phase != CLSP_PAIRING_PHASE_BEGUN) return CLSP_STATUS_INVALID_STATE;
  if (!pairing_association_authenticated(*pairing)) {
    return fail_pairing_locked(*pairing, CLSP_STATUS_NOT_AUTHENTICATED);
  }
  const auto now = std::time(nullptr);
  if (now < 0 || pending->expires_at_utc_seconds <= static_cast<std::uint64_t>(now) ||
      pending->expires_at_utc_seconds > static_cast<std::uint64_t>(now) + 120U) {
    return fail_pairing_locked(*pairing, CLSP_STATUS_PAIRING_EXPIRED);
  }
  if (!contains_nonzero(pending->pairing_session_id) || pending->effective_permissions == 0U ||
      (pending->effective_permissions & ~pairing->requested_permissions) != 0U || pending->reserved_zero != 0U) {
    return CLSP_STATUS_INVALID_CONFIGURATION;
  }
  std::copy_n(
    pending->pairing_session_id,
    pairing->pairing_session_id.size(),
    pairing->pairing_session_id.begin()
  );
  pairing->effective_permissions = pending->effective_permissions;
  pairing->expires_at_utc_seconds = pending->expires_at_utc_seconds;
  pairing->phase = CLSP_PAIRING_PHASE_PENDING_BOUND;
  return CLSP_STATUS_OK;
}

extern "C" clsp_status_t clsp_pairing_accept_challenge(
  clsp_pairing_t *pairing,
  const clsp_pairing_challenge_t *challenge,
  clsp_pairing_client_confirmation_t *output
) {
  if (pairing == nullptr || challenge == nullptr || output == nullptr) return CLSP_STATUS_INVALID_ARGUMENT;
  *output = {.abi_version = CLSP_CORE_ABI_VERSION, .structure_size = sizeof(*output)};
  if (callback_stack_contains(pairing->core)) return CLSP_STATUS_REENTRANT_CALLBACK;
  if (challenge->abi_version != CLSP_CORE_ABI_VERSION || challenge->structure_size != sizeof(*challenge)) {
    return CLSP_STATUS_ABI_MISMATCH;
  }
  std::lock_guard lock(pairing->mutex);
  if (pairing->phase != CLSP_PAIRING_PHASE_PENDING_BOUND
#if CLSP_CORE_HAS_WOLFSSL
      || pairing->spake == nullptr
#endif
  ) {
    return CLSP_STATUS_INVALID_STATE;
  }
  if (!pairing_association_authenticated(*pairing)) {
    return fail_pairing_locked(*pairing, CLSP_STATUS_NOT_AUTHENTICATED);
  }
  if (pairing_expired(*pairing) || challenge->expires_at_utc_seconds != pairing->expires_at_utc_seconds) {
    return fail_pairing_locked(*pairing, CLSP_STATUS_PAIRING_EXPIRED);
  }
  if (!std::equal(
        std::begin(challenge->pairing_session_id),
        std::end(challenge->pairing_session_id),
        pairing->pairing_session_id.begin()
      ) || challenge->approval_generation == 0U) {
    return CLSP_STATUS_PAIRING_GENERATION_MISMATCH;
  }
  if (challenge->effective_permissions != pairing->effective_permissions ||
      challenge->host_point[0] != 0x04U ||
      std::any_of(
        std::begin(challenge->reserved_tail),
        std::end(challenge->reserved_tail),
        [](const std::uint8_t byte) { return byte != 0U; }
      )) {
    return CLSP_STATUS_INVALID_CONFIGURATION;
  }
  std::copy_n(challenge->host_point, pairing->point_b.size(), pairing->point_b.begin());
  if (!build_pairing_aad(*pairing, *challenge)) {
    pairing->phase = CLSP_PAIRING_PHASE_FAILED;
    zeroize_pairing_secrets(*pairing);
    return CLSP_STATUS_INTERNAL_FAILURE;
  }
#if CLSP_CORE_HAS_WOLFSSL
  auto status = pairing_status(pairing->spake->receive_host_point(
    pairing->point_b,
    std::span<const std::uint8_t> {pairing->aad}.first(pairing->aad_length),
    pairing->confirmation_a
  ));
#else
  const auto status = CLSP_STATUS_MISSING_WOLFSSL;
#endif
  if (status != CLSP_STATUS_OK) {
    pairing->phase = CLSP_PAIRING_PHASE_FAILED;
    zeroize_pairing_secrets(*pairing);
    return status;
  }
  pairing->approval_generation = challenge->approval_generation;
  std::copy(
    pairing->pairing_session_id.begin(),
    pairing->pairing_session_id.end(),
    std::begin(output->pairing_session_id)
  );
  output->approval_generation = pairing->approval_generation;
  output->effective_permissions = pairing->effective_permissions;
  output->expires_at_utc_seconds = pairing->expires_at_utc_seconds;
  std::copy(
    pairing->confirmation_a.begin(),
    pairing->confirmation_a.end(),
    std::begin(output->client_confirmation)
  );
  if (!build_client_signature_input(*pairing, *output)) {
    pairing->phase = CLSP_PAIRING_PHASE_FAILED;
    zeroize_pairing_secrets(*pairing);
    return CLSP_STATUS_INTERNAL_FAILURE;
  }
  pairing->phase = CLSP_PAIRING_PHASE_CHALLENGE_ACCEPTED;
  return CLSP_STATUS_OK;
}

extern "C" clsp_status_t clsp_pairing_verify_host(
  clsp_pairing_t *pairing,
  const clsp_pairing_host_confirmation_t *confirmation,
  clsp_pairing_result_t *output
) {
  if (pairing == nullptr || confirmation == nullptr || output == nullptr) return CLSP_STATUS_INVALID_ARGUMENT;
  *output = {.abi_version = CLSP_CORE_ABI_VERSION, .structure_size = sizeof(*output)};
  if (callback_stack_contains(pairing->core)) return CLSP_STATUS_REENTRANT_CALLBACK;
  if (confirmation->abi_version != CLSP_CORE_ABI_VERSION ||
      confirmation->structure_size != sizeof(*confirmation)) {
    return CLSP_STATUS_ABI_MISMATCH;
  }
  std::lock_guard lock(pairing->mutex);
  if (pairing->phase != CLSP_PAIRING_PHASE_CHALLENGE_ACCEPTED
#if CLSP_CORE_HAS_WOLFSSL
      || pairing->spake == nullptr
#endif
  ) {
    return CLSP_STATUS_INVALID_STATE;
  }
  if (!pairing_association_authenticated(*pairing)) {
    return fail_pairing_locked(*pairing, CLSP_STATUS_NOT_AUTHENTICATED);
  }
  if (pairing_expired(*pairing)) return fail_pairing_locked(*pairing, CLSP_STATUS_PAIRING_EXPIRED);
  if (!std::equal(
        std::begin(confirmation->pairing_session_id),
        std::end(confirmation->pairing_session_id),
        pairing->pairing_session_id.begin()
      ) || confirmation->approval_generation != pairing->approval_generation ||
      confirmation->revocation_generation == 0U) {
    return CLSP_STATUS_PAIRING_GENERATION_MISMATCH;
  }
  lumen::lsp::Spake2Confirmation confirmation_b {};
  lumen::lsp::Spake2SharedKey shared_key {};
  std::copy_n(
    confirmation->host_confirmation,
    confirmation_b.size(),
    confirmation_b.begin()
  );
#if CLSP_CORE_HAS_WOLFSSL
  const auto status = pairing_status(pairing->spake->verify_host_confirmation(confirmation_b, shared_key));
#else
  const auto status = CLSP_STATUS_MISSING_WOLFSSL;
#endif
  lumen::lsp::secure_zero(shared_key);
  if (status != CLSP_STATUS_OK) {
    pairing->phase = CLSP_PAIRING_PHASE_FAILED;
    lumen::lsp::secure_zero(confirmation_b);
    zeroize_pairing_secrets(*pairing);
    return status;
  }
  pairing->revocation_generation = confirmation->revocation_generation;
  std::copy(
    pairing->pairing_session_id.begin(),
    pairing->pairing_session_id.end(),
    std::begin(output->pairing_session_id)
  );
  output->approval_generation = pairing->approval_generation;
  output->effective_permissions = pairing->effective_permissions;
  output->revocation_generation = pairing->revocation_generation;
  output->expires_at_utc_seconds = pairing->expires_at_utc_seconds;
  if (!build_host_signature_input(*pairing, confirmation_b, pairing->revocation_generation, *output)) {
    pairing->phase = CLSP_PAIRING_PHASE_FAILED;
    lumen::lsp::secure_zero(confirmation_b);
    zeroize_pairing_secrets(*pairing);
    return CLSP_STATUS_INTERNAL_FAILURE;
  }
  lumen::lsp::secure_zero(confirmation_b);
  pairing->phase = CLSP_PAIRING_PHASE_COMPLETE;
  zeroize_pairing_secrets(*pairing);
  return CLSP_STATUS_OK;
}

extern "C" clsp_status_t clsp_pairing_cancel(clsp_pairing_t *pairing) {
  if (pairing == nullptr) return CLSP_STATUS_INVALID_ARGUMENT;
  if (callback_stack_contains(pairing->core)) return CLSP_STATUS_REENTRANT_CALLBACK;
  std::lock_guard lock(pairing->mutex);
  if (pairing->phase == CLSP_PAIRING_PHASE_COMPLETE || pairing->phase == CLSP_PAIRING_PHASE_CANCELLED) {
    return CLSP_STATUS_INVALID_STATE;
  }
  pairing->phase = CLSP_PAIRING_PHASE_CANCELLED;
  zeroize_pairing_secrets(*pairing);
  return CLSP_STATUS_OK;
}

extern "C" clsp_status_t clsp_pairing_copy_snapshot(
  const clsp_pairing_t *pairing,
  clsp_pairing_snapshot_t *output
) {
  if (pairing == nullptr || output == nullptr) return CLSP_STATUS_INVALID_ARGUMENT;
  if (callback_stack_contains(pairing->core)) return CLSP_STATUS_REENTRANT_CALLBACK;
  std::lock_guard lock(pairing->mutex);
  *output = {
    .abi_version = CLSP_CORE_ABI_VERSION,
    .structure_size = sizeof(*output),
    .phase = pairing->phase,
    .effective_permissions = pairing->effective_permissions,
    .approval_generation = pairing->approval_generation,
    .revocation_generation = pairing->revocation_generation,
    .expires_at_utc_seconds = pairing->expires_at_utc_seconds,
    .reserved_zero = 0,
  };
  return CLSP_STATUS_OK;
}

extern "C" clsp_status_t clsp_handoff_create(
  clsp_core_t *active,
  const std::uint32_t active_connection_generation,
  const std::uint32_t active_input_generation,
  const clsp_handoff_callbacks_t *callbacks,
  clsp_handoff_t **output
) {
  if (active == nullptr || output == nullptr) {
    return CLSP_STATUS_INVALID_ARGUMENT;
  }
  *output = nullptr;
  if (callbacks != nullptr &&
      (callbacks->abi_version != CLSP_CORE_ABI_VERSION ||
       callbacks->structure_size != sizeof(clsp_handoff_callbacks_t))) {
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

  auto *handoff = new (std::nothrow) clsp_handoff_t;
  auto *observer = new (std::nothrow) clsp_handoff_observer_binding;
  if (handoff == nullptr || observer == nullptr) {
    delete observer;
    delete handoff;
    return CLSP_STATUS_RESOURCE_EXHAUSTED;
  }
  if (const auto status = fence_status(handoff->fence.initialize(
        active_connection_generation,
        active_input_generation
      )); status != CLSP_STATUS_OK) {
    delete observer;
    delete handoff;
    return status;
  }
  observer->owner = handoff;
  handoff->observer = observer;
  clsp_core_retain(active);
  {
    std::lock_guard lock(handoff->mutex);
    handoff->active = active;
  }
  set_core_baseline_authority_epoch(active, handoff->fence.snapshot().input_authority_epoch);
  if (!bind_handoff_observer(active, observer)) {
    {
      std::lock_guard lock(handoff->mutex);
      handoff->active = nullptr;
    }
    clsp_core_release(active);
    delete observer;
    delete handoff;
    return CLSP_STATUS_INVALID_STATE;
  }
  if (callbacks != nullptr) {
    handoff->callbacks = *callbacks;
    if (handoff->callbacks.context != nullptr) {
      handoff->callbacks.retain_context(handoff->callbacks.context);
    }
  } else {
    handoff->callbacks.abi_version = CLSP_CORE_ABI_VERSION;
    handoff->callbacks.structure_size = sizeof(clsp_handoff_callbacks_t);
  }
  *output = handoff;
  return CLSP_STATUS_OK;
}

extern "C" void clsp_handoff_retain(clsp_handoff_t *handoff) {
  if (handoff != nullptr) {
    handoff->references.fetch_add(1, std::memory_order_relaxed);
  }
}

extern "C" void clsp_handoff_release(clsp_handoff_t *handoff) {
  if (handoff == nullptr) {
    return;
  }

  auto *observer = handoff->observer;
  std::unique_lock observer_lock(observer->mutex);
  if (handoff->references.fetch_sub(1, std::memory_order_acq_rel) != 1U) {
    return;
  }
  if (observer != nullptr) {
    observer->owner = nullptr;
    observer->condition.wait(observer_lock, [&] { return observer->active_calls == 0U; });
  }
  observer_lock.unlock();

  clsp_core_t *active = nullptr;
  clsp_core_t *candidate = nullptr;
  clsp_core_t *retiring = nullptr;
  {
    std::lock_guard lock(handoff->mutex);
    active = handoff->active;
    candidate = handoff->candidate;
    retiring = handoff->retiring;
    handoff->active = nullptr;
    handoff->candidate = nullptr;
    handoff->retiring = nullptr;
  }
  unbind_handoff_observer(active, observer);
  unbind_handoff_observer(candidate, observer);
  unbind_handoff_observer(retiring, observer);
  if (handoff->callbacks.context != nullptr) {
    handoff->callbacks.release_context(handoff->callbacks.context);
  }
  clsp_core_release(active);
  clsp_core_release(candidate);
  clsp_core_release(retiring);
  release_observer_binding(observer);
  delete handoff;
}

extern "C" clsp_status_t clsp_handoff_begin(
  clsp_handoff_t *handoff,
  clsp_core_t *candidate,
  const std::uint32_t candidate_connection_generation,
  const std::uint32_t reason
) {
  if (handoff == nullptr || candidate == nullptr ||
      (reason != CLSP_HANDOFF_REASON_TRANSPORT_LOSS && reason != CLSP_HANDOFF_REASON_PLANNED_REKEY)) {
    return CLSP_STATUS_INVALID_ARGUMENT;
  }
  if (handoff_callback_stack_contains(handoff)) {
    return CLSP_STATUS_REENTRANT_CALLBACK;
  }
  handoff_call_reference call_reference {handoff};
  clsp_status_t status = CLSP_STATUS_OK;
  {
    std::lock_guard lock(handoff->mutex);
    if (handoff->transition_in_progress || handoff->phase == CLSP_HANDOFF_PHASE_TERMINAL ||
        handoff->candidate != nullptr || handoff->retiring != nullptr ||
        candidate == handoff->active) {
      return CLSP_STATUS_INVALID_STATE;
    }
    status = fence_status(handoff->fence.begin_fresh_association(candidate_connection_generation));
    if (status != CLSP_STATUS_OK) {
      return status;
    }
    clsp_core_retain(candidate);
    handoff->candidate = candidate;
    handoff->candidate_authenticated = false;
    handoff->candidate_lost = false;
    handoff->old_input_neutralized = false;
    handoff->baseline_required = false;
    handoff->attach_committed = false;
    handoff->attach_submitted = false;
    handoff->forward_only = false;
    handoff->reason = reason;
    handoff->transition_in_progress = true;
  }

  if (!bind_handoff_observer(candidate, handoff->observer)) {
    status = CLSP_STATUS_INVALID_STATE;
  } else {
    status = quiesce_core_producers(candidate);
  }

  bool staged = false;
  {
    std::lock_guard lock(handoff->mutex);
    handoff->transition_in_progress = false;
    if (status == CLSP_STATUS_OK && !handoff->candidate_lost && handoff->candidate == candidate) {
      handoff->phase = CLSP_HANDOFF_PHASE_CANDIDATE_HANDSHAKE;
      ++handoff->begun_count;
      staged = true;
      publish_handoff_rekey_locked(handoff);
      publish_handoff_phase_locked(handoff);
    } else {
      const auto candidate_generation = handoff->fence.snapshot().candidate_connection_generation;
      const auto rollback_status = fence_status(handoff->fence.cancel_candidate(candidate_generation));
      if (status == CLSP_STATUS_OK) {
        status = rollback_status == CLSP_STATUS_OK ? CLSP_STATUS_INVALID_STATE : rollback_status;
      }
      handoff->candidate = nullptr;
      handoff->candidate_authenticated = false;
      handoff->candidate_lost = false;
    }
  }
  if (!staged) {
    unbind_handoff_observer(candidate, handoff->observer);
    resume_core_producers(candidate);
    clsp_core_release(candidate);
  }
  return status;
}

extern "C" clsp_status_t clsp_handoff_authenticate(
  clsp_handoff_t *handoff,
  const std::uint32_t candidate_connection_generation
) {
  if (handoff == nullptr) return CLSP_STATUS_INVALID_ARGUMENT;
  if (handoff_callback_stack_contains(handoff)) return CLSP_STATUS_REENTRANT_CALLBACK;
  handoff_call_reference call_reference {handoff};
  std::lock_guard lock(handoff->mutex);
  if (handoff->transition_in_progress || handoff->candidate == nullptr ||
      handoff->phase != CLSP_HANDOFF_PHASE_CANDIDATE_HANDSHAKE) {
    return CLSP_STATUS_INVALID_STATE;
  }
  const auto status = fence_status(handoff->fence.mark_candidate_authenticated(candidate_connection_generation));
  if (status != CLSP_STATUS_OK) return status;
  handoff->candidate_authenticated = true;
  handoff->phase = CLSP_HANDOFF_PHASE_CANDIDATE_AUTHENTICATED;
  publish_handoff_phase_locked(handoff);
  return CLSP_STATUS_OK;
}

extern "C" clsp_status_t clsp_handoff_lost(
  clsp_handoff_t *handoff,
  clsp_core_t *association
) {
  if (handoff == nullptr || association == nullptr) return CLSP_STATUS_INVALID_ARGUMENT;
  if (handoff_callback_stack_contains(handoff)) return CLSP_STATUS_REENTRANT_CALLBACK;
  handoff_call_reference call_reference {handoff};
  clsp_core_t *released_candidate = nullptr;
  handoff_rollback_work rollback_work;
  {
    std::lock_guard lock(handoff->mutex);
    if (handoff->phase == CLSP_HANDOFF_PHASE_TERMINAL) return CLSP_STATUS_OK;
    if (association == handoff->retiring) {
      return CLSP_STATUS_OK;
    }
    if (association == handoff->active) {
      if (handoff->active_lost) return CLSP_STATUS_OK;
      handoff->active_lost = true;
      association->producers_accepting.store(false, std::memory_order_release);
      if (handoff->attach_committed) {
        enter_handoff_terminal_locked(handoff, CLSP_HANDOFF_TERMINAL_COMMITTED_ASSOCIATION_LOST);
      } else if (handoff->candidate == nullptr || handoff->phase == CLSP_HANDOFF_PHASE_AUTHORITATIVE) {
        handoff->phase = CLSP_HANDOFF_PHASE_ACTIVE_LOST;
        publish_handoff_phase_locked(handoff);
      } else {
        publish_handoff_phase_locked(handoff);
      }
      return CLSP_STATUS_OK;
    }
    if (association != handoff->candidate) return CLSP_STATUS_INVALID_ARGUMENT;
    if (handoff->transition_in_progress) {
      handoff->candidate_lost = true;
      return CLSP_STATUS_OK;
    }
    const auto fence = handoff->fence.snapshot();
    if (!handoff->old_input_neutralized && !handoff->active_lost) {
      const auto status = fence_status(handoff->fence.cancel_candidate(fence.candidate_connection_generation));
      if (status != CLSP_STATUS_OK) return status;
      released_candidate = handoff->candidate;
      handoff->candidate = nullptr;
      handoff->candidate_authenticated = false;
      handoff->phase = CLSP_HANDOFF_PHASE_AUTHORITATIVE;
      publish_handoff_phase_locked(handoff);
    } else if (handoff->old_input_neutralized && !handoff->attach_submitted && !handoff->active_lost) {
      const auto status = begin_handoff_rollback_locked(handoff, rollback_work);
      if (status != CLSP_STATUS_OK) {
        enter_handoff_terminal_locked(handoff, CLSP_HANDOFF_TERMINAL_BASELINE_FAILED);
        return status;
      }
    } else {
      if (handoff->old_input_neutralized && handoff->attach_submitted && !handoff->attach_committed) {
        (void)handoff->fence.mark_attach_outcome_ambiguous(fence.candidate_connection_generation);
      }
      enter_handoff_terminal_locked(
        handoff,
        handoff->attach_submitted ? CLSP_HANDOFF_TERMINAL_AMBIGUOUS_ATTACH :
                                    CLSP_HANDOFF_TERMINAL_CANDIDATE_LOST
      );
    }
  }
  if (released_candidate != nullptr) {
    unbind_handoff_observer(released_candidate, handoff->observer);
    clsp_core_release(released_candidate);
  }
  if (rollback_work.active == nullptr) return CLSP_STATUS_OK;
  const auto rollback_status = complete_handoff_rollback(handoff, rollback_work, false);
  return rollback_status == CLSP_STATUS_OK ? CLSP_STATUS_ROLLBACK_PENDING : rollback_status;
}

extern "C" clsp_status_t clsp_handoff_neutralize(clsp_handoff_t *handoff) {
  if (handoff == nullptr) return CLSP_STATUS_INVALID_ARGUMENT;
  if (handoff_callback_stack_contains(handoff)) return CLSP_STATUS_REENTRANT_CALLBACK;
  handoff_call_reference call_reference {handoff};
  clsp_core_t *active = nullptr;
  std::uint32_t candidate_generation = 0;
  {
    std::lock_guard lock(handoff->mutex);
    if (handoff->transition_in_progress || handoff->candidate == nullptr ||
        !handoff->candidate_authenticated || handoff->phase != CLSP_HANDOFF_PHASE_CANDIDATE_AUTHENTICATED) {
      return CLSP_STATUS_INVALID_STATE;
    }
    handoff->transition_in_progress = true;
    active = handoff->active;
    clsp_core_retain(active);
    candidate_generation = handoff->fence.snapshot().candidate_connection_generation;
  }

  const auto quiesce_status = quiesce_core_producers(active);
  clsp_core_release(active);
  handoff_rollback_work rollback_work;
  {
    std::lock_guard lock(handoff->mutex);
    handoff->transition_in_progress = false;
    if (quiesce_status != CLSP_STATUS_OK) {
      enter_handoff_terminal_locked(handoff, CLSP_HANDOFF_TERMINAL_BASELINE_FAILED);
      return quiesce_status;
    }
    if (handoff->candidate == nullptr || handoff->phase != CLSP_HANDOFF_PHASE_CANDIDATE_AUTHENTICATED) {
      enter_handoff_terminal_locked(handoff, CLSP_HANDOFF_TERMINAL_CANDIDATE_LOST);
      return CLSP_STATUS_INVALID_STATE;
    }
    const auto status = fence_status(handoff->fence.neutralize_old_input(candidate_generation));
    if (status != CLSP_STATUS_OK) {
      enter_handoff_terminal_locked(handoff, CLSP_HANDOFF_TERMINAL_BASELINE_FAILED);
      return status;
    }
    handoff->old_input_neutralized = true;
    if (handoff->candidate_lost) {
      if (handoff->active_lost) {
        enter_handoff_terminal_locked(handoff, CLSP_HANDOFF_TERMINAL_CANDIDATE_LOST);
        return CLSP_STATUS_INVALID_STATE;
      }
      const auto rollback_status = begin_handoff_rollback_locked(handoff, rollback_work);
      if (rollback_status != CLSP_STATUS_OK) {
        enter_handoff_terminal_locked(handoff, CLSP_HANDOFF_TERMINAL_BASELINE_FAILED);
        return rollback_status;
      }
    } else {
      handoff->phase = CLSP_HANDOFF_PHASE_OLD_INPUT_NEUTRALIZED;
      publish_handoff_phase_locked(handoff);
      return CLSP_STATUS_OK;
    }
  }
  const auto rollback_status = complete_handoff_rollback(handoff, rollback_work, false);
  return rollback_status == CLSP_STATUS_OK ? CLSP_STATUS_ROLLBACK_PENDING : rollback_status;
}

extern "C" clsp_status_t clsp_handoff_submit_attach(
  clsp_handoff_t *handoff,
  const std::uint16_t message_type,
  const std::uint64_t request_id,
  const clsp_const_byte_span_t payload,
  const std::uint32_t deadline_milliseconds,
  clsp_control_submission_t *output
) {
  if (output == nullptr) {
    return CLSP_STATUS_INVALID_ARGUMENT;
  }
  *output = {
    .abi_version = CLSP_CORE_ABI_VERSION,
    .structure_size = sizeof(clsp_control_submission_t),
    .request_id = 0,
  };
  if (handoff == nullptr || message_type != 0x0202U || request_id == 0U) {
    return CLSP_STATUS_INVALID_ARGUMENT;
  }
  if (handoff_callback_stack_contains(handoff)) return CLSP_STATUS_REENTRANT_CALLBACK;
  handoff_call_reference call_reference {handoff};
  clsp_core_t *candidate = nullptr;
  {
    std::lock_guard lock(handoff->mutex);
    if (handoff->transition_in_progress || handoff->candidate == nullptr || handoff->candidate_lost ||
        handoff->attach_submitted || handoff->phase != CLSP_HANDOFF_PHASE_OLD_INPUT_NEUTRALIZED) {
      return CLSP_STATUS_INVALID_STATE;
    }
    candidate = handoff->candidate;
    clsp_core_retain(candidate);
  }

  clsp_status_t status = CLSP_STATUS_NOT_AUTHENTICATED;
  std::shared_lock runtime_lock(candidate->runtime_mutex);
  std::uint64_t reservation_token = 0;
  if (candidate->runtime != nullptr) {
    status = candidate->runtime->reserve_control(
      message_type,
      request_id,
      payload,
      deadline_milliseconds,
      reservation_token
    );
  }
  if (status != CLSP_STATUS_OK) {
    runtime_lock.unlock();
    clsp_core_release(candidate);
    return status;
  }

  {
    std::lock_guard lock(handoff->mutex);
    if (handoff->candidate != candidate || handoff->candidate_lost || handoff->attach_submitted ||
        handoff->phase != CLSP_HANDOFF_PHASE_OLD_INPUT_NEUTRALIZED) {
      candidate->runtime->cancel_control_reservation(reservation_token);
      status = CLSP_STATUS_INVALID_STATE;
    } else {
      handoff->attach_submitted = true;
      handoff->phase = CLSP_HANDOFF_PHASE_ATTACH_SUBMITTED;
      status = candidate->runtime->commit_control_reservation(reservation_token);
      if (status == CLSP_STATUS_OK) {
        output->request_id = request_id;
        publish_handoff_phase_locked(handoff);
      } else {
        handoff->attach_submitted = false;
        handoff->phase = CLSP_HANDOFF_PHASE_OLD_INPUT_NEUTRALIZED;
        candidate->runtime->cancel_control_reservation(reservation_token);
      }
    }
  }
  runtime_lock.unlock();
  clsp_core_release(candidate);
  return status;
}

extern "C" clsp_status_t clsp_handoff_commit(
  clsp_handoff_t *handoff,
  const std::uint32_t new_input_generation
) {
  if (handoff == nullptr) return CLSP_STATUS_INVALID_ARGUMENT;
  if (handoff_callback_stack_contains(handoff)) return CLSP_STATUS_REENTRANT_CALLBACK;
  handoff_call_reference call_reference {handoff};
  std::lock_guard lock(handoff->mutex);
  if (handoff->transition_in_progress || handoff->candidate == nullptr ||
      handoff->candidate_lost || !handoff->attach_submitted ||
      handoff->phase != CLSP_HANDOFF_PHASE_ATTACH_SUBMITTED ||
      handoff->retiring != nullptr) {
    return CLSP_STATUS_INVALID_STATE;
  }
  const auto candidate_generation = handoff->fence.snapshot().candidate_connection_generation;
  const auto status = fence_status(handoff->fence.commit_attach(candidate_generation, new_input_generation));
  if (status != CLSP_STATUS_OK) return status;
  const auto committed = handoff->fence.snapshot();
  handoff->retiring = handoff->active;
  handoff->active = handoff->candidate;
  set_core_baseline_authority_epoch(handoff->active, committed.input_authority_epoch);
  handoff->candidate = nullptr;
  handoff->active_lost = false;
  handoff->candidate_authenticated = false;
  handoff->old_input_neutralized = false;
  handoff->attach_committed = true;
  handoff->forward_only = true;
  handoff->baseline_required = true;
  handoff->baseline_generation = new_input_generation;
  handoff->baseline_authority_epoch = committed.input_authority_epoch;
  handoff->baseline_connection_generation = committed.active_connection_generation;
  handoff->baseline_rollback_generation = 0;
  handoff->phase = CLSP_HANDOFF_PHASE_COMMITTED_BASELINE;
  ++handoff->committed_count;
  publish_handoff_phase_locked(handoff);
  publish_handoff_baseline_locked(handoff, CLSP_HANDOFF_BASELINE_REQUIRED, new_input_generation);
  return CLSP_STATUS_OK;
}

extern "C" clsp_status_t clsp_handoff_cancel(
  clsp_handoff_t *handoff,
  const std::uint32_t kind
) {
  if (handoff == nullptr ||
      (kind != CLSP_HANDOFF_CANCEL_DEFINITE_REJECTION && kind != CLSP_HANDOFF_CANCEL_AMBIGUOUS)) {
    return CLSP_STATUS_INVALID_ARGUMENT;
  }
  if (handoff_callback_stack_contains(handoff)) return CLSP_STATUS_REENTRANT_CALLBACK;
  handoff_call_reference call_reference {handoff};
  clsp_core_t *released_candidate = nullptr;
  handoff_rollback_work rollback_work;
  {
    std::lock_guard lock(handoff->mutex);
    if (handoff->transition_in_progress || handoff->candidate == nullptr || handoff->attach_committed ||
        handoff->phase == CLSP_HANDOFF_PHASE_TERMINAL) {
      return CLSP_STATUS_INVALID_STATE;
    }
    const auto fence = handoff->fence.snapshot();
    if (kind == CLSP_HANDOFF_CANCEL_AMBIGUOUS) {
      if (!handoff->attach_submitted || handoff->phase != CLSP_HANDOFF_PHASE_ATTACH_SUBMITTED) {
        return CLSP_STATUS_INVALID_STATE;
      }
      const auto status = fence_status(
        handoff->fence.mark_attach_outcome_ambiguous(fence.candidate_connection_generation)
      );
      if (status != CLSP_STATUS_OK) return status;
      enter_handoff_terminal_locked(handoff, CLSP_HANDOFF_TERMINAL_AMBIGUOUS_ATTACH);
      return CLSP_STATUS_OK;
    }
    if (!handoff->old_input_neutralized) {
      const auto status = fence_status(handoff->fence.cancel_candidate(fence.candidate_connection_generation));
      if (status != CLSP_STATUS_OK) return status;
      released_candidate = handoff->candidate;
      handoff->candidate = nullptr;
      handoff->candidate_authenticated = false;
      if (handoff->active_lost) {
        enter_handoff_terminal_locked(handoff, CLSP_HANDOFF_TERMINAL_ACTIVE_LOST);
      } else {
        handoff->phase = CLSP_HANDOFF_PHASE_AUTHORITATIVE;
        resume_core_producers(handoff->active);
        publish_handoff_phase_locked(handoff);
      }
    } else {
      if (handoff->active_lost) {
        enter_handoff_terminal_locked(handoff, CLSP_HANDOFF_TERMINAL_BASELINE_FAILED);
        return CLSP_STATUS_INVALID_STATE;
      }
      const auto status = begin_handoff_rollback_locked(handoff, rollback_work);
      if (status != CLSP_STATUS_OK) return status;
    }
  }

  if (released_candidate != nullptr) {
    unbind_handoff_observer(released_candidate, handoff->observer);
    (void)clsp_core_stop(released_candidate);
    clsp_core_release(released_candidate);
  }
  if (rollback_work.active == nullptr) return CLSP_STATUS_OK;
  const auto rollback_status = complete_handoff_rollback(handoff, rollback_work, true);
  return rollback_status == CLSP_STATUS_OK ? CLSP_STATUS_ROLLBACK_PENDING : rollback_status;
}

extern "C" clsp_status_t clsp_handoff_acknowledge_baseline(
  clsp_handoff_t *handoff,
  const std::uint32_t input_generation,
  const std::uint64_t baseline_id
) {
  if (handoff == nullptr || input_generation == 0U || baseline_id == 0U) {
    return CLSP_STATUS_INVALID_ARGUMENT;
  }
  if (handoff_callback_stack_contains(handoff)) return CLSP_STATUS_REENTRANT_CALLBACK;
  handoff_call_reference call_reference {handoff};
  std::lock_guard lock(handoff->mutex);
  if (!handoff->baseline_required || input_generation != handoff->baseline_generation) {
    return CLSP_STATUS_INVALID_STATE;
  }
  if (handoff->phase == CLSP_HANDOFF_PHASE_ROLLBACK_PENDING) {
    const auto fence = handoff->fence.snapshot();
    const auto status = fence_status(handoff->fence.acknowledge_old_neutral_baseline(
      fence.active_connection_generation,
      input_generation,
      baseline_id
    ));
    if (status != CLSP_STATUS_OK) return status;
    ++handoff->definite_rollback_count;
    handoff->forward_only = false;
  } else if (handoff->phase != CLSP_HANDOFF_PHASE_COMMITTED_BASELINE) {
    return CLSP_STATUS_INVALID_STATE;
  }
  handoff->baseline_required = false;
  handoff->baseline_generation = 0;
  handoff->phase = CLSP_HANDOFF_PHASE_AUTHORITATIVE;
  resume_core_producers(handoff->active);
  publish_handoff_baseline_locked(handoff, CLSP_HANDOFF_BASELINE_ACKNOWLEDGED, input_generation);
  publish_handoff_phase_locked(handoff);
  handoff->baseline_authority_epoch = 0;
  handoff->baseline_connection_generation = 0;
  handoff->baseline_rollback_generation = 0;
  return CLSP_STATUS_OK;
}

extern "C" clsp_status_t clsp_handoff_retire(clsp_handoff_t *handoff) {
  if (handoff == nullptr) return CLSP_STATUS_INVALID_ARGUMENT;
  if (handoff_callback_stack_contains(handoff)) return CLSP_STATUS_REENTRANT_CALLBACK;
  handoff_call_reference call_reference {handoff};
  clsp_core_t *retiring = nullptr;
  {
    std::lock_guard lock(handoff->mutex);
    if (handoff->transition_in_progress || handoff->retiring == nullptr || handoff->baseline_required ||
        handoff->phase == CLSP_HANDOFF_PHASE_TERMINAL) {
      return CLSP_STATUS_INVALID_STATE;
    }
    const auto retiring_generation = handoff->fence.snapshot().retiring_connection_generation;
    const auto status = fence_status(handoff->fence.retire_old_association(retiring_generation));
    if (status != CLSP_STATUS_OK) return status;
    retiring = handoff->retiring;
    handoff->retiring = nullptr;
    publish_handoff_phase_locked(handoff);
  }
  unbind_handoff_observer(retiring, handoff->observer);
  (void)clsp_core_stop(retiring);
  clsp_core_release(retiring);
  return CLSP_STATUS_OK;
}

extern "C" clsp_status_t clsp_handoff_copy_snapshot(
  const clsp_handoff_t *handoff,
  clsp_handoff_snapshot_t *output
) {
  if (handoff == nullptr || output == nullptr) return CLSP_STATUS_INVALID_ARGUMENT;
  if (handoff_callback_stack_contains(handoff)) return CLSP_STATUS_REENTRANT_CALLBACK;
  std::lock_guard lock(handoff->mutex);
  fill_handoff_snapshot_locked(*handoff, *output);
  return CLSP_STATUS_OK;
}

extern "C" clsp_status_t clsp_core_copy_input_baseline(
  const clsp_core_t *core,
  clsp_input_baseline_snapshot_t *output
) {
  if (core == nullptr || output == nullptr) return CLSP_STATUS_INVALID_ARGUMENT;
  if (callback_stack_contains(core)) return CLSP_STATUS_REENTRANT_CALLBACK;
  std::lock_guard baseline_lock(core->baseline_mutex);
  fill_input_baseline_snapshot_locked(*core, *output);
  return CLSP_STATUS_OK;
}

extern "C" clsp_status_t clsp_core_wait_input_baseline(
  const clsp_core_t *core,
  const std::uint32_t input_generation,
  const std::uint32_t timeout_milliseconds,
  clsp_input_baseline_snapshot_t *output
) {
  if (core == nullptr || output == nullptr || input_generation == 0U ||
      timeout_milliseconds == 0U || timeout_milliseconds > 30'000U) {
    return CLSP_STATUS_INVALID_ARGUMENT;
  }
  if (callback_stack_contains(core)) return CLSP_STATUS_REENTRANT_CALLBACK;
  std::unique_lock baseline_lock(core->baseline_mutex);
  const auto ready = core->baseline_condition.wait_for(
    baseline_lock,
    std::chrono::milliseconds {timeout_milliseconds},
    [&] {
      return core->baseline_acknowledged && core->baseline_input_generation == input_generation;
    }
  );
  fill_input_baseline_snapshot_locked(*core, *output);
  return ready ? CLSP_STATUS_OK : CLSP_STATUS_TIMEOUT;
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
  {
    std::lock_guard host_lock(core->host_hello_mutex);
    core->host_hello = {};
    core->host_hello_bound = false;
    std::copy_n(endpoint->server_spki_sha256, core->expected_server_spki.size(), core->expected_server_spki.begin());
  }
  auto *runtime = new (std::nothrow) umbra::lsp::Runtime {
    core->configuration,
    {
      .context = core,
      .lifecycle = runtime_lifecycle,
      .control = runtime_control,
      .counter = runtime_counter,
      .timing = runtime_timing,
      .controller_output = runtime_controller_output,
      .input_baseline = runtime_input_baseline,
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
  } else {
    std::lock_guard observer_lock(core->handoff_observer_mutex);
    if (core->handoff_observer == nullptr) {
      resume_core_producers(core);
    }
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
  const auto quiesce_status = quiesce_core_producers(core);
  {
    std::lock_guard host_lock(core->host_hello_mutex);
    core->host_hello = {};
    core->host_hello_bound = false;
  }
  std::unique_lock runtime_lock(core->runtime_mutex);
  const auto prior_state = core->state.load(std::memory_order_acquire);
  if (core->runtime == nullptr) {
    if (prior_state != CLSP_LIFECYCLE_FAILED) {
      core->state.store(CLSP_LIFECYCLE_STOPPED, std::memory_order_release);
    }
    return quiesce_status;
  }
  const auto status = core->runtime->stop();
  delete core->runtime;
  core->runtime = nullptr;
  if (prior_state == CLSP_LIFECYCLE_FAILED) {
    core->state.store(CLSP_LIFECYCLE_FAILED, std::memory_order_release);
    return quiesce_status == CLSP_STATUS_OK ? CLSP_STATUS_OK : quiesce_status;
  }
  return quiesce_status == CLSP_STATUS_OK ? status : quiesce_status;
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
  if (callback_stack_contains(core)) {
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
  if (callback_stack_contains(core)) {
    return CLSP_STATUS_REENTRANT_CALLBACK;
  }
  return with_runtime(core, [&](umbra::lsp::Runtime &runtime) {
    if (core->state.load(std::memory_order_acquire) != CLSP_LIFECYCLE_AUTHENTICATED) {
      return CLSP_STATUS_NOT_AUTHENTICATED;
    }
    return runtime.configure_input(*configuration);
  });
}

extern "C" clsp_status_t clsp_core_update_input_rates(
  clsp_core_t *core,
  const clsp_input_rate_update_t *update
) {
  if (core == nullptr || update == nullptr) return CLSP_STATUS_INVALID_ARGUMENT;
  if (callback_stack_contains(core)) return CLSP_STATUS_REENTRANT_CALLBACK;
  return with_runtime(core, [&](umbra::lsp::Runtime &runtime) { return runtime.update_input_rates(*update); });
}

extern "C" clsp_status_t clsp_core_copy_input_feedback(
  const clsp_core_t *core,
  clsp_input_feedback_snapshot_t *output
) {
  if (core == nullptr || output == nullptr) return CLSP_STATUS_INVALID_ARGUMENT;
  if (callback_stack_contains(core)) return CLSP_STATUS_REENTRANT_CALLBACK;
  std::shared_lock runtime_lock(core->runtime_mutex);
  return core->runtime == nullptr ? CLSP_STATUS_NOT_AUTHENTICATED :
                                    core->runtime->copy_input_feedback(*output);
}

extern "C" clsp_status_t clsp_core_copy_input_edge_snapshot(
  const clsp_core_t *core,
  clsp_input_edge_snapshot_t *output
) {
  if (core == nullptr || output == nullptr) return CLSP_STATUS_INVALID_ARGUMENT;
  if (callback_stack_contains(core)) return CLSP_STATUS_REENTRANT_CALLBACK;
  std::shared_lock runtime_lock(core->runtime_mutex);
  return core->runtime == nullptr ? CLSP_STATUS_NOT_AUTHENTICATED :
                                    core->runtime->copy_input_edge_snapshot(*output);
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
  if (callback_stack_contains(core)) return CLSP_STATUS_REENTRANT_CALLBACK;
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
  if (callback_stack_contains(core)) {
    return CLSP_STATUS_REENTRANT_CALLBACK;
  }
  core_producer_lease producer_lease {core};
  if (!producer_lease.active()) return CLSP_STATUS_INVALID_STATE;
  return with_runtime(core, [&](umbra::lsp::Runtime &runtime) { return runtime.submit_pointer(*sample); });
}

extern "C" clsp_status_t clsp_core_submit_input_edge(
  clsp_core_t *core,
  const clsp_input_edge_t *edge
) {
  if (core == nullptr || edge == nullptr) {
    return CLSP_STATUS_INVALID_ARGUMENT;
  }
  if (callback_stack_contains(core)) {
    return CLSP_STATUS_REENTRANT_CALLBACK;
  }
  core_producer_lease producer_lease {core};
  if (!producer_lease.active()) return CLSP_STATUS_INVALID_STATE;
  return with_runtime(core, [&](umbra::lsp::Runtime &runtime) { return runtime.submit_input_edge(*edge); });
}

extern "C" clsp_status_t clsp_core_neutralize_input(clsp_core_t *core) {
  if (core == nullptr) {
    return CLSP_STATUS_INVALID_ARGUMENT;
  }
  if (callback_stack_contains(core)) {
    return CLSP_STATUS_REENTRANT_CALLBACK;
  }
  return with_runtime(core, [](umbra::lsp::Runtime &runtime) { return runtime.neutralize_input(); });
}

extern "C" clsp_status_t clsp_core_restart_input_baseline(clsp_core_t *core) {
  if (core == nullptr) return CLSP_STATUS_INVALID_ARGUMENT;
  if (callback_stack_contains(core)) return CLSP_STATUS_REENTRANT_CALLBACK;
  const auto baseline_id = fresh_baseline_id();
  const auto status = with_runtime(core, [&](umbra::lsp::Runtime &runtime) {
    return runtime.restart_input_baseline(baseline_id);
  });
  if (status == CLSP_STATUS_OK) resume_core_producers(core);
  return status;
}

extern "C" clsp_status_t clsp_core_submit_controller_edge(
  clsp_core_t *core,
  const clsp_controller_edge_t *edge
) {
  if (core == nullptr || edge == nullptr) return CLSP_STATUS_INVALID_ARGUMENT;
  if (callback_stack_contains(core)) return CLSP_STATUS_REENTRANT_CALLBACK;
  core_producer_lease producer_lease {core};
  if (!producer_lease.active()) return CLSP_STATUS_INVALID_STATE;
  return with_runtime(core, [&](umbra::lsp::Runtime &runtime) { return runtime.submit_controller_edge(*edge); });
}

extern "C" clsp_status_t clsp_core_submit_controller_state(
  clsp_core_t *core,
  const clsp_controller_state_t *state
) {
  if (core == nullptr || state == nullptr) return CLSP_STATUS_INVALID_ARGUMENT;
  if (callback_stack_contains(core)) return CLSP_STATUS_REENTRANT_CALLBACK;
  core_producer_lease producer_lease {core};
  if (!producer_lease.active()) return CLSP_STATUS_INVALID_STATE;
  return with_runtime(core, [&](umbra::lsp::Runtime &runtime) { return runtime.submit_controller_state(*state); });
}

extern "C" clsp_status_t clsp_core_submit_controller_sensor(
  clsp_core_t *core,
  const clsp_controller_sensor_t *sensor
) {
  if (core == nullptr || sensor == nullptr) return CLSP_STATUS_INVALID_ARGUMENT;
  if (callback_stack_contains(core)) return CLSP_STATUS_REENTRANT_CALLBACK;
  core_producer_lease producer_lease {core};
  if (!producer_lease.active()) return CLSP_STATUS_INVALID_STATE;
  return with_runtime(core, [&](umbra::lsp::Runtime &runtime) { return runtime.submit_controller_sensor(*sensor); });
}

extern "C" clsp_status_t clsp_core_submit_controller_touch_edge(
  clsp_core_t *core,
  const clsp_controller_touch_edge_t *edge
) {
  if (core == nullptr || edge == nullptr) return CLSP_STATUS_INVALID_ARGUMENT;
  if (callback_stack_contains(core)) return CLSP_STATUS_REENTRANT_CALLBACK;
  core_producer_lease producer_lease {core};
  if (!producer_lease.active()) return CLSP_STATUS_INVALID_STATE;
  return with_runtime(core, [&](umbra::lsp::Runtime &runtime) { return runtime.submit_controller_touch_edge(*edge); });
}

extern "C" clsp_status_t clsp_core_submit_controller_touch_state(
  clsp_core_t *core,
  const clsp_controller_touch_state_t *state
) {
  if (core == nullptr || state == nullptr) return CLSP_STATUS_INVALID_ARGUMENT;
  if (callback_stack_contains(core)) return CLSP_STATUS_REENTRANT_CALLBACK;
  core_producer_lease producer_lease {core};
  if (!producer_lease.active()) return CLSP_STATUS_INVALID_STATE;
  return with_runtime(core, [&](umbra::lsp::Runtime &runtime) { return runtime.submit_controller_touch_state(*state); });
}

extern "C" bool clsp_core_register_apple_capture(
  clsp_core_t *core,
  clsp_apple_input_capture_t *capture
) {
  if (core == nullptr || capture == nullptr) return false;
  std::lock_guard lock(core->apple_capture_mutex);
  if (core->apple_capture != nullptr || !core->producers_accepting.load(std::memory_order_acquire)) return false;
  core->apple_capture = capture;
  return true;
}

extern "C" void clsp_core_publish_device_offer(
  clsp_core_t *core,
  clsp_device_offer_event_t event
) {
  if (core == nullptr || event.kind < CLSP_DEVICE_OFFER_ARRIVED ||
      event.kind > CLSP_DEVICE_OFFER_RATE_OBSERVED ||
      event.device_type < CLSP_DEVICE_OFFER_POINTER || event.device_type > CLSP_DEVICE_OFFER_CONTROLLER ||
      event.device_id == 0U || event.instance_generation == 0U ||
      event.capture_source < CLSP_DEVICE_CAPTURE_IOHID || event.capture_source > CLSP_DEVICE_CAPTURE_APPKIT ||
      (event.device_type == CLSP_DEVICE_OFFER_POINTER && event.device_id != 1U) ||
      (event.device_type == CLSP_DEVICE_OFFER_CONTROLLER && event.device_id > 16U)) return;
  event.dropped_samples = 0U;
  event.attributed_wire_bytes = 0U;
  (void)with_runtime(core, [&](umbra::lsp::Runtime &runtime) {
    event.dropped_samples = runtime.input_dropped_samples(
      event.device_type,
      event.device_id,
      event.instance_generation
    );
    event.attributed_wire_bytes = runtime.input_attributed_wire_bytes(
      event.device_type,
      event.device_id,
      event.instance_generation
    );
    return CLSP_STATUS_OK;
  });
  if (event.kind == CLSP_DEVICE_OFFER_REMOVED) {
    event.observed_capture_hz = 0U;
    event.observed_sensor_hz = 0U;
    event.minimum_state_rate = 0U;
    event.maximum_state_rate = 0U;
    event.minimum_sensor_rate = 0U;
    event.maximum_sensor_rate = 0U;
    event.effective_wire_bits_per_second = 0U;
    event.minimum_sample_interval_microseconds = 0U;
    event.maximum_sample_interval_microseconds = 0U;
    event.maximum_state_packet_bytes = 0U;
    event.maximum_sensor_packet_bytes = 0U;
  }
  {
    std::lock_guard timing_lock(core->native_timing_mutex);
    auto &device = core->native_timing.devices[
      event.device_type == CLSP_DEVICE_OFFER_POINTER ? 0U : event.device_id
    ];
    device = {
      .state_spacing = {
        .count = event.state_spacing_count,
        .p50_microseconds = event.state_spacing_p50_microseconds,
        .p95_microseconds = event.state_spacing_p95_microseconds,
        .p99_microseconds = event.state_spacing_p99_microseconds,
        .maximum_microseconds = event.state_spacing_maximum_microseconds,
        .drops = event.state_spacing_drops,
        .flags = event.timing_flags,
      },
      .sensor_spacing = {
        .count = event.sensor_spacing_count,
        .p50_microseconds = event.sensor_spacing_p50_microseconds,
        .p95_microseconds = event.sensor_spacing_p95_microseconds,
        .p99_microseconds = event.sensor_spacing_p99_microseconds,
        .maximum_microseconds = event.sensor_spacing_maximum_microseconds,
        .drops = event.sensor_spacing_drops,
        .flags = event.device_type == CLSP_DEVICE_OFFER_CONTROLLER &&
                     (event.maximum_sensor_rate != 0U || event.sensor_spacing_count != 0U) ?
                   event.timing_flags : 0U,
      },
      .captured_samples = event.captured_samples,
      .dropped_samples = event.dropped_samples,
      .attributed_wire_bytes = event.attributed_wire_bytes,
      .device_id = event.device_id,
      .instance_generation = event.instance_generation,
      .observed_state_hz = event.observed_capture_hz,
      .observed_sensor_hz = event.observed_sensor_hz,
      .device_type = event.device_type,
      .capture_source = event.capture_source,
      .active = static_cast<std::uint8_t>(event.kind != CLSP_DEVICE_OFFER_REMOVED),
    };
  }
  std::lock_guard lock(core->device_offer_mutex);
  event.abi_version = CLSP_CORE_ABI_VERSION;
  event.structure_size = sizeof(clsp_device_offer_event_t);
  event.event_sequence = core->next_device_offer_sequence++;
  if (core->next_device_offer_sequence == 0U) ++core->next_device_offer_sequence;
  event.reserved_zero[0] = event.reserved_zero[1] = event.reserved_zero[2] = 0;
  event.reserved_zero[3] = event.reserved_zero[4] = 0;
  if (core->device_offer_count == core->device_offers.size()) {
    core->device_offer_read = (core->device_offer_read + 1U) % core->device_offers.size();
    --core->device_offer_count;
  }
  core->device_offers[core->device_offer_write] = event;
  core->device_offer_write = (core->device_offer_write + 1U) % core->device_offers.size();
  ++core->device_offer_count;
}

extern "C" void clsp_core_observe_input_device(
  clsp_core_t *core,
  const std::uint8_t device_type,
  const std::uint32_t device_id,
  const std::uint32_t instance_generation,
  const bool active,
  const std::uint8_t sensor_mask
) {
  if (core == nullptr || device_type < 2U || device_type > 5U || device_id == 0U ||
      instance_generation == 0U || (device_type != 3U && sensor_mask != 0U) ||
      (sensor_mask & ~std::uint8_t {3}) != 0U) return;
  (void)with_runtime(core, [&](umbra::lsp::Runtime &runtime) {
    runtime.observe_input_device(
      device_type,
      device_id,
      instance_generation,
      active,
      sensor_mask
    );
    return CLSP_STATUS_OK;
  });
}

extern "C" clsp_status_t clsp_core_poll_device_offer(
  clsp_core_t *core,
  clsp_device_offer_event_t *output
) {
  if (core == nullptr || output == nullptr) return CLSP_STATUS_INVALID_ARGUMENT;
  if (callback_stack_contains(core)) return CLSP_STATUS_REENTRANT_CALLBACK;
  std::lock_guard lock(core->device_offer_mutex);
  if (core->device_offer_count == 0U) {
    *output = {
      .abi_version = CLSP_CORE_ABI_VERSION,
      .structure_size = sizeof(clsp_device_offer_event_t),
      .kind = CLSP_DEVICE_OFFER_NONE,
    };
    return CLSP_STATUS_OK;
  }
  *output = core->device_offers[core->device_offer_read];
  core->device_offers[core->device_offer_read] = {};
  core->device_offer_read = (core->device_offer_read + 1U) % core->device_offers.size();
  --core->device_offer_count;
  return CLSP_STATUS_OK;
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
    .current_receive_udp_payload_size = core->runtime == nullptr ? std::uint16_t {1'200} :
                                                                   core->runtime->current_receive_udp_payload_size(),
  };
  return CLSP_STATUS_OK;
}

extern "C" clsp_status_t clsp_core_copy_native_timing(
  const clsp_core_t *core,
  clsp_native_timing_snapshot_t *output
) {
  if (core == nullptr || output == nullptr) return CLSP_STATUS_INVALID_ARGUMENT;
  if (callback_stack_contains(core)) return CLSP_STATUS_REENTRANT_CALLBACK;
  std::lock_guard lock(core->native_timing_mutex);
  *output = core->native_timing;
  output->abi_version = CLSP_CORE_ABI_VERSION;
  output->structure_size = sizeof(clsp_native_timing_snapshot_t);
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
    case CLSP_STATUS_ROLLBACK_PENDING:
      return "input rollback baseline acknowledgement is pending";
    case CLSP_STATUS_PAIRING_FAILED:
      return "native PIN pairing failed";
    case CLSP_STATUS_PAIRING_EXPIRED:
      return "native PIN pairing expired";
    case CLSP_STATUS_PAIRING_GENERATION_MISMATCH:
      return "native PIN pairing generation mismatch";
    case CLSP_STATUS_PAIRING_CONFIRMATION_FAILED:
      return "native PIN pairing confirmation failed";
  }
  return "unknown LSP status";
}
