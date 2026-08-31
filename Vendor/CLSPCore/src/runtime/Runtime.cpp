/**
 * @file Runtime.cpp
 * @brief Nonblocking UDP/kqueue worker with RFC 7983, DTLS, SRTP, and LSPC ownership.
 */

#include "Runtime.h"

#include "SecurityProviders.h"
#include "../core/control.h"
#include "../core/rtp.h"
#include "../input_plane/input_plane.h"

#include <array>
#include <atomic>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <new>
#include <span>

#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
  #include <arpa/inet.h>
  #include <fcntl.h>
  #include <netdb.h>
  #include <netinet/in.h>
  #include <pthread.h>
  #include <sys/event.h>
  #include <sys/socket.h>
  #include <sys/time.h>
  #include <unistd.h>
  #include <wolfssl/options.h>
  #include <wolfssl/wolfcrypt/hash.h>
#endif

namespace umbra::lsp {
  namespace {
    constexpr std::size_t maximum_udp_payload = 1'472;  ///< LSP/1 standard-Ethernet IPv4 ceiling.
    constexpr std::size_t maximum_control_payload = 1'100;  ///< DTLS-safe deterministic-CBOR payload ceiling.
    constexpr std::size_t maximum_control_frame = lumen::lsp::lspc_header_size + maximum_control_payload;
    constexpr std::size_t receive_batch_size = 64;  ///< Initial bounded receive batch.
    constexpr std::size_t control_queue_capacity = 64;  ///< Bounded pre-wire control queue.
    constexpr std::size_t capture_queue_capacity = 4'096;  ///< Bounded allocation-free Apple capture ring.

    /** @brief RFC 7983 first-byte classification. */
    enum class PacketClass : std::uint8_t {
      dtls,  ///< DTLS record, first byte 20 through 63.
      srtp_or_srtcp,  ///< RTP/RTCP packet, first byte 128 through 191.
      invalid,  ///< Reserved or invalid LSP/1 datagram.
    };

    /** @brief Classify one complete UDP datagram without side effects. */
    [[nodiscard]] constexpr PacketClass classify(const std::span<const std::uint8_t> datagram) noexcept {
      if (datagram.empty()) {
        return PacketClass::invalid;
      }
      const auto first = datagram.front();
      if (first >= 20U && first <= 63U) {
        return PacketClass::dtls;
      }
      if (first >= 128U && first <= 191U) {
        return PacketClass::srtp_or_srtcp;
      }
      return PacketClass::invalid;
    }

    /** @brief Apply RFC 5761 RTP/RTCP-mux classification to an authenticated candidate. */
    [[nodiscard]] constexpr bool is_rtcp(const std::span<const std::uint8_t> datagram) noexcept {
      return datagram.size() >= 2U && datagram[1] >= 192U && datagram[1] <= 223U;
    }

    /** @brief Return monotonic microseconds with saturation on clock failure. */
    [[nodiscard]] std::uint64_t monotonic_microseconds() noexcept {
#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      timespec value {};
      if (clock_gettime(CLOCK_MONOTONIC, &value) != 0 || value.tv_sec < 0 || value.tv_nsec < 0) {
        return 0;
      }
      const auto seconds = static_cast<std::uint64_t>(value.tv_sec);
      if (seconds > std::numeric_limits<std::uint64_t>::max() / 1'000'000U) {
        return std::numeric_limits<std::uint64_t>::max();
      }
      return seconds * 1'000'000U + static_cast<std::uint64_t>(value.tv_nsec) / 1'000U;
#else
      return 0;
#endif
    }
  }  // namespace

  class Runtime::Impl {
  public:
    /** @brief Copy immutable construction state and initialize synchronization primitives. */
    Impl(const clsp_configuration_t &configuration, const RuntimeCallbacks callbacks) noexcept:
        configuration_ {configuration},
        callbacks_ {callbacks},
        rto_ {true} {
#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      mutex_ready_ = pthread_mutex_init(&mutex_, nullptr) == 0;
      condition_ready_ = mutex_ready_ && pthread_cond_init(&condition_, nullptr) == 0;
#endif
    }

    /** @brief Stop the worker and destroy native synchronization primitives. */
    ~Impl() {
      (void)stop();
#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      if (condition_ready_) {
        pthread_cond_destroy(&condition_);
      }
      if (mutex_ready_) {
        pthread_mutex_destroy(&mutex_);
      }
#endif
    }

    /** @brief Start and synchronously await exact-policy authentication. */
    [[nodiscard]] clsp_status_t start(const clsp_endpoint_t &endpoint) noexcept {
#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      if (!mutex_ready_ || !condition_ready_ || worker_started_) {
        return CLSP_STATUS_INVALID_STATE;
      }
      if (const auto status = open_socket(endpoint); status != CLSP_STATUS_OK) {
        cleanup_platform();
        return status;
      }
      if (const auto status = dtls_.initialize(
            socket_,
            &peer_address_,
            peer_address_size_,
            std::span<const std::uint8_t, 32> {endpoint.server_spki_sha256},
            receive_application_data,
            this
          );
          status != CLSP_STATUS_OK) {
        cleanup_platform();
        return status;
      }

      stop_requested_.store(false, std::memory_order_release);
      startup_complete_ = false;
      startup_status_ = CLSP_STATUS_TIMEOUT;
      publish_lifecycle(CLSP_LIFECYCLE_CONNECTING);
      if (pthread_create(&worker_, nullptr, worker_entry, this) != 0) {
        cleanup_platform();
        publish_lifecycle(CLSP_LIFECYCLE_FAILED);
        return CLSP_STATUS_SOCKET_FAILURE;
      }
      worker_started_ = true;

      timespec deadline {};
      if (clock_gettime(CLOCK_REALTIME, &deadline) != 0) {
        request_stop();
        join_worker();
        cleanup_platform();
        return CLSP_STATUS_INTERNAL_FAILURE;
      }
      const auto timeout_nanoseconds = static_cast<std::uint64_t>(configuration_.handshake_timeout_milliseconds) * 1'000'000U;
      deadline.tv_sec += static_cast<time_t>(timeout_nanoseconds / 1'000'000'000U);
      deadline.tv_nsec += static_cast<long>(timeout_nanoseconds % 1'000'000'000U);
      if (deadline.tv_nsec >= 1'000'000'000L) {
        ++deadline.tv_sec;
        deadline.tv_nsec -= 1'000'000'000L;
      }

      pthread_mutex_lock(&mutex_);
      while (!startup_complete_) {
        const auto wait_status = pthread_cond_timedwait(&condition_, &mutex_, &deadline);
        if (wait_status == ETIMEDOUT) {
          break;
        }
        if (wait_status != 0) {
          startup_status_ = CLSP_STATUS_INTERNAL_FAILURE;
          break;
        }
      }
      const auto status = startup_complete_ ? startup_status_ : CLSP_STATUS_TIMEOUT;
      pthread_mutex_unlock(&mutex_);

      if (status != CLSP_STATUS_OK) {
        request_stop();
        join_worker();
        cleanup_platform();
        publish_lifecycle(CLSP_LIFECYCLE_FAILED);
      }
      return status;
#else
      (void)endpoint;
      return CLSP_STATUS_UNSUPPORTED;
#endif
    }

    /** @brief Stop and join the native worker. */
    [[nodiscard]] clsp_status_t stop() noexcept {
#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      if (!worker_started_) {
        return CLSP_STATUS_INVALID_STATE;
      }
      request_stop();
      join_worker();
      cleanup_platform();
      publish_lifecycle(CLSP_LIFECYCLE_STOPPED);
      return CLSP_STATUS_OK;
#else
      return CLSP_STATUS_UNSUPPORTED;
#endif
    }

    /** @brief Enqueue one bounded reliable request and wake kqueue. */
    [[nodiscard]] clsp_status_t send_control(
      const std::uint16_t message_type,
      const std::uint64_t request_id,
      const clsp_const_byte_span_t payload,
      const std::uint32_t deadline_milliseconds
    ) noexcept {
#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      if (!authenticated_.load(std::memory_order_acquire)) {
        return CLSP_STATUS_NOT_AUTHENTICATED;
      }
      if (message_type == 0 || request_id == 0 || deadline_milliseconds < 20U || deadline_milliseconds > 30'000U ||
          payload.length > maximum_control_payload || (payload.data == nullptr && payload.length != 0)) {
        return CLSP_STATUS_INVALID_ARGUMENT;
      }
      pthread_mutex_lock(&mutex_);
      if (queued_control_count_ == control_queue_capacity) {
        pthread_mutex_unlock(&mutex_);
        increment(RuntimeCounter::dropped);
        return CLSP_STATUS_CONTROL_WINDOW_FULL;
      }
      auto &command = control_queue_[control_queue_tail_];
      command.message_type = message_type;
      command.request_id = request_id;
      command.payload.assign(std::span<const std::uint8_t> {payload.data, payload.length});
      const auto now = monotonic_microseconds();
      const auto duration = static_cast<std::uint64_t>(deadline_milliseconds) * 1'000U;
      command.deadline_microseconds = now > std::numeric_limits<std::uint64_t>::max() - duration ?
                                         std::numeric_limits<std::uint64_t>::max() :
                                         now + duration;
      control_queue_tail_ = (control_queue_tail_ + 1U) % control_queue_capacity;
      ++queued_control_count_;
      pthread_mutex_unlock(&mutex_);
      wake_worker();
      return CLSP_STATUS_OK;
#else
      (void)message_type;
      (void)request_id;
      (void)payload;
      (void)deadline_milliseconds;
      return CLSP_STATUS_UNSUPPORTED;
#endif
    }

    /** @brief Queue one authenticated START-selected input mapping. */
    [[nodiscard]] clsp_status_t configure_input(const clsp_input_configuration_t &configuration) noexcept {
#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      if (!authenticated_.load(std::memory_order_acquire)) {
        return CLSP_STATUS_NOT_AUTHENTICATED;
      }
      if (configuration.abi_version != CLSP_CORE_ABI_VERSION ||
          configuration.structure_size != sizeof(clsp_input_configuration_t) ||
          configuration.stream_generation == 0 || configuration.input_generation == 0 ||
          configuration.input_ssrc == 0 || configuration.acknowledgement_ssrc == 0 ||
          configuration.input_ssrc == configuration.acknowledgement_ssrc ||
          configuration.input_payload_type < 96U || configuration.input_payload_type > 127U ||
          configuration.pointer_rate < 125U || configuration.pointer_rate > 16'000U ||
          configuration.controller_rate < 125U || configuration.controller_rate > 2'000U ||
          configuration.sensor_rate < 125U || configuration.sensor_rate > 4'000U ||
          configuration.reconciliation_rate < 50U || configuration.reconciliation_rate > 1'000U ||
          configuration.reserved_input_wire_bits_per_second == 0 ||
          configuration.reserved_input_wire_bits_per_second > 32'000'000U ||
          configuration.baseline_required != 1U || configuration.reserved_zero != 0) {
        return CLSP_STATUS_INVALID_CONFIGURATION;
      }
      pthread_mutex_lock(&mutex_);
      pending_input_configuration_ = configuration;
      input_configuration_pending_ = true;
      pthread_mutex_unlock(&mutex_);
      wake_worker();
      return CLSP_STATUS_OK;
#else
      (void)configuration;
      return CLSP_STATUS_UNSUPPORTED;
#endif
    }

    /** @brief Queue one bounded relative-pointer record. */
    [[nodiscard]] clsp_status_t submit_pointer(const clsp_pointer_sample_t &sample) noexcept {
#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      if (!authenticated_.load(std::memory_order_acquire) || sample.sample_time_microseconds == 0) {
        return sample.sample_time_microseconds == 0 ? CLSP_STATUS_INVALID_ARGUMENT : CLSP_STATUS_NOT_AUTHENTICATED;
      }
      CaptureRecord record {.kind = CaptureKind::pointer, .pointer = sample};
      return enqueue_capture(record);
#else
      (void)sample;
      return CLSP_STATUS_UNSUPPORTED;
#endif
    }

    /** @brief Queue one bounded keyboard or pointer-button edge. */
    [[nodiscard]] clsp_status_t submit_input_edge(const clsp_input_edge_t &edge) noexcept {
#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      const auto known_kind = edge.kind >= CLSP_INPUT_EDGE_KEY_DOWN && edge.kind <= CLSP_INPUT_EDGE_POINTER_BUTTON_UP;
      const auto pointer = edge.kind == CLSP_INPUT_EDGE_POINTER_BUTTON_DOWN || edge.kind == CLSP_INPUT_EDGE_POINTER_BUTTON_UP;
      if (!authenticated_.load(std::memory_order_acquire)) {
        return CLSP_STATUS_NOT_AUTHENTICATED;
      }
      if (edge.sample_time_microseconds == 0 || !known_kind || edge.reserved_zero != 0 || edge.control_id == 0 ||
          (pointer && edge.control_id > 5U)) {
        return CLSP_STATUS_INVALID_ARGUMENT;
      }
      CaptureRecord record {.kind = CaptureKind::edge, .edge = edge};
      return enqueue_capture(record);
#else
      (void)edge;
      return CLSP_STATUS_UNSUPPORTED;
#endif
    }

    [[nodiscard]] clsp_status_t submit_controller_edge(const clsp_controller_edge_t &edge) noexcept {
#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      if (edge.sample_time_microseconds == 0 || edge.controller_id == 0 || edge.controller_id > 16 ||
          edge.instance_generation == 0 || edge.kind < 5 || edge.kind > 8 || edge.reserved_zero != 0 ||
          ((edge.kind == 7 || edge.kind == 8) && edge.control_id > 31)) {
        return CLSP_STATUS_INVALID_ARGUMENT;
      }
      CaptureRecord record {.kind = CaptureKind::controller_edge, .controller_edge = edge};
      return enqueue_capture(record);
#else
      (void)edge;
      return CLSP_STATUS_UNSUPPORTED;
#endif
    }

    [[nodiscard]] clsp_status_t submit_controller_state(const clsp_controller_state_t &state) noexcept {
#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      if (state.sample_time_microseconds == 0 || state.controller_id == 0 || state.controller_id > 16 ||
          state.instance_generation == 0) {
        return CLSP_STATUS_INVALID_ARGUMENT;
      }
      CaptureRecord record {.kind = CaptureKind::controller_state, .controller_state = state};
      return enqueue_capture(record);
#else
      (void)state;
      return CLSP_STATUS_UNSUPPORTED;
#endif
    }

    [[nodiscard]] clsp_status_t submit_controller_sensor(const clsp_controller_sensor_t &sensor) noexcept {
#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      if (sensor.sample_time_microseconds == 0 || sensor.controller_id == 0 || sensor.controller_id > 16 ||
          sensor.instance_generation == 0 || sensor.sensor_type < 1 || sensor.sensor_type > 2 ||
          sensor.reserved_zero[0] != 0 || sensor.reserved_zero[1] != 0 || sensor.reserved_zero[2] != 0) {
        return CLSP_STATUS_INVALID_ARGUMENT;
      }
      CaptureRecord record {.kind = CaptureKind::controller_sensor, .controller_sensor = sensor};
      return enqueue_capture(record);
#else
      (void)sensor;
      return CLSP_STATUS_UNSUPPORTED;
#endif
    }

    [[nodiscard]] clsp_status_t submit_controller_touch_edge(const clsp_controller_touch_edge_t &edge) noexcept {
#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      if (edge.sample_time_microseconds == 0 || edge.controller_id == 0 || edge.controller_id > 16 ||
          edge.contact_id == 0 || edge.contact_id > 16 || edge.instance_generation == 0 ||
          edge.kind < 9 || edge.kind > 11 || edge.reserved_zero[0] != 0 || edge.reserved_zero[1] != 0 || edge.reserved_zero[2] != 0) {
        return CLSP_STATUS_INVALID_ARGUMENT;
      }
      CaptureRecord record {.kind = CaptureKind::touch_edge, .touch_edge = edge};
      return enqueue_capture(record);
#else
      (void)edge;
      return CLSP_STATUS_UNSUPPORTED;
#endif
    }

    [[nodiscard]] clsp_status_t submit_controller_touch_state(const clsp_controller_touch_state_t &state) noexcept {
#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      if (state.sample_time_microseconds == 0 || state.controller_id == 0 || state.controller_id > 16 ||
          state.contact_id == 0 || state.contact_id > 16 || state.instance_generation == 0) {
        return CLSP_STATUS_INVALID_ARGUMENT;
      }
      CaptureRecord record {.kind = CaptureKind::touch_state, .touch_state = state};
      return enqueue_capture(record);
#else
      (void)state;
      return CLSP_STATUS_UNSUPPORTED;
#endif
    }

    /** @brief Stop new capture while retaining release edges until acknowledged. */
    [[nodiscard]] clsp_status_t neutralize_input() noexcept {
#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      if (!authenticated_.load(std::memory_order_acquire)) {
        return CLSP_STATUS_NOT_AUTHENTICATED;
      }
      CaptureRecord record {.kind = CaptureKind::neutralize};
      return enqueue_capture(record);
#else
      return CLSP_STATUS_UNSUPPORTED;
#endif
    }

  private:
    /** @brief One bounded deterministic-CBOR request waiting for message-ID assignment. */
    struct ControlCommand {
      std::uint16_t message_type {};  ///< Semantic message type.
      std::uint64_t request_id {};  ///< Caller-generated request ID.
      std::uint64_t deadline_microseconds {};  ///< Absolute retry deadline.
      lumen::lsp::packet_slab<maximum_control_payload> payload {};  ///< Copied deterministic-CBOR payload.
    };

    /** @brief Capture-record discriminator for the bounded native ring. */
    enum class CaptureKind : std::uint8_t {
      pointer,  ///< Relative pointer sample.
      edge,  ///< Keyboard or pointer-button edge.
      neutralize,  ///< Stop accepting new physical state after queued releases.
      controller_edge,  ///< Controller lifecycle or digital button edge.
      controller_state,  ///< Latest controller triggers and sticks.
      controller_sensor,  ///< Latest gyro or accelerometer sample.
      touch_edge,  ///< Controller touchpad lifecycle edge.
      touch_state,  ///< Latest controller touch coordinates.
    };

    /** @brief One allocation-free record copied from an Apple capture callback. */
    struct CaptureRecord {
      CaptureKind kind {CaptureKind::neutralize};  ///< Record kind.
      clsp_pointer_sample_t pointer {};  ///< Pointer fields when `kind` is pointer.
      clsp_input_edge_t edge {};  ///< Edge fields when `kind` is edge.
      clsp_controller_edge_t controller_edge {};  ///< Controller edge fields.
      clsp_controller_state_t controller_state {};  ///< Controller analog fields.
      clsp_controller_sensor_t controller_sensor {};  ///< Controller sensor fields.
      clsp_controller_touch_edge_t touch_edge {};  ///< Touch lifecycle fields.
      clsp_controller_touch_state_t touch_state {};  ///< Touch coordinate fields.
    };

    /** @brief Worker-owned latest controller analog state. */
    struct ControllerLatest {
      clsp_controller_state_t value {};  ///< Latest captured value.
      std::uint64_t physical_ordinal {};  ///< Increasing native sample ordinal.
      std::uint64_t last_sent_us {};  ///< Most recent network submission.
      bool dirty {};  ///< Whether a newer sample awaits submission.
    };

    /** @brief Worker-owned latest controller sensor state. */
    struct ControllerSensorLatest {
      clsp_controller_sensor_t value {};  ///< Latest captured vector.
      std::uint64_t physical_ordinal {};  ///< Increasing native sample ordinal.
      std::uint64_t last_sent_us {};  ///< Most recent network submission.
      bool dirty {};  ///< Whether a newer vector awaits submission.
    };

    /** @brief Worker-owned latest controller touch coordinates. */
    struct TouchLatest {
      clsp_controller_touch_state_t value {};  ///< Latest captured contact.
      std::uint64_t physical_ordinal {};  ///< Increasing contact sample ordinal.
      std::uint64_t last_sent_us {};  ///< Most recent network submission.
      bool dirty {};  ///< Whether newer coordinates await submission.
    };

    /** @brief Increment one C ABI telemetry counter. */
    void increment(const RuntimeCounter counter, const std::uint64_t amount = 1) const noexcept {
      if (callbacks_.counter != nullptr) {
        callbacks_.counter(callbacks_.context, static_cast<std::uint32_t>(counter), amount);
      }
    }

    /** @brief Publish one coarse lifecycle transition. */
    void publish_lifecycle(const std::uint32_t state) const noexcept {
      if (callbacks_.lifecycle != nullptr) {
        callbacks_.lifecycle(callbacks_.context, state);
      }
    }

#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
    /** @brief Resolve and connect one nonblocking UDP socket, then register kqueue readiness. */
    [[nodiscard]] clsp_status_t open_socket(const clsp_endpoint_t &endpoint) noexcept {
      std::array<char, 256> host {};
      if (endpoint.host.length == 0 || endpoint.host.length >= host.size() || endpoint.host.data == nullptr || endpoint.port == 0) {
        return CLSP_STATUS_INVALID_ENDPOINT;
      }
      std::memcpy(host.data(), endpoint.host.data, endpoint.host.length);
      host[endpoint.host.length] = '\0';
      std::array<char, 6> service {};
      const auto service_length = std::snprintf(service.data(), service.size(), "%u", endpoint.port);
      if (service_length <= 0 || static_cast<std::size_t>(service_length) >= service.size()) {
        return CLSP_STATUS_INVALID_ENDPOINT;
      }

      addrinfo hints {};
      hints.ai_family = AF_UNSPEC;
      hints.ai_socktype = SOCK_DGRAM;
      hints.ai_protocol = IPPROTO_UDP;
      addrinfo *addresses = nullptr;
      if (getaddrinfo(host.data(), service.data(), &hints, &addresses) != 0 || addresses == nullptr) {
        return CLSP_STATUS_INVALID_ENDPOINT;
      }
      for (auto *candidate = addresses; candidate != nullptr; candidate = candidate->ai_next) {
        if (candidate->ai_addr == nullptr || candidate->ai_addrlen > sizeof(peer_address_)) {
          continue;
        }
        const auto descriptor = ::socket(candidate->ai_family, candidate->ai_socktype, candidate->ai_protocol);
        if (descriptor < 0) {
          continue;
        }
        const auto flags = fcntl(descriptor, F_GETFL, 0);
        if (flags < 0 || fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != 0 ||
            ::connect(descriptor, candidate->ai_addr, candidate->ai_addrlen) != 0) {
          ::close(descriptor);
          continue;
        }
        socket_ = descriptor;
        std::memcpy(&peer_address_, candidate->ai_addr, candidate->ai_addrlen);
        peer_address_size_ = static_cast<unsigned int>(candidate->ai_addrlen);
        break;
      }
      freeaddrinfo(addresses);
      if (socket_ < 0) {
        return CLSP_STATUS_SOCKET_FAILURE;
      }

#ifdef SO_TIMESTAMP_MONOTONIC
      const int enabled = 1;
      (void)setsockopt(socket_, SOL_SOCKET, SO_TIMESTAMP_MONOTONIC, &enabled, sizeof(enabled));
#endif
      kqueue_ = kqueue();
      if (kqueue_ < 0) {
        return CLSP_STATUS_SOCKET_FAILURE;
      }
      std::array<struct kevent, 2> registrations {};
      EV_SET(&registrations[0], socket_, EVFILT_READ, EV_ADD | EV_CLEAR, 0, 0, nullptr);
      EV_SET(&registrations[1], wake_identifier, EVFILT_USER, EV_ADD | EV_CLEAR, 0, 0, nullptr);
      return kevent(kqueue_, registrations.data(), static_cast<int>(registrations.size()), nullptr, 0, nullptr) == 0 ?
               CLSP_STATUS_OK :
               CLSP_STATUS_SOCKET_FAILURE;
    }

    /** @brief Static pthread entry point. */
    static void *worker_entry(void *opaque) noexcept {
      auto *self = static_cast<Impl *>(opaque);
      self->run_worker();
      return nullptr;
    }

    /** @brief Own the complete socket/security/control runtime until stop or failure. */
    void run_worker() noexcept {
      auto status = dtls_.advance_handshake();
      if (status != CLSP_STATUS_OK) {
        fail_worker(status);
        return;
      }
      auto last_dtls_progress = monotonic_microseconds();
      while (!stop_requested_.load(std::memory_order_acquire)) {
        std::array<struct kevent, 8> events {};
        const timespec timeout {.tv_sec = 0, .tv_nsec = 1'000'000L};
        const auto count = kevent(kqueue_, nullptr, 0, events.data(), static_cast<int>(events.size()), &timeout);
        if (count < 0 && errno != EINTR) {
          fail_worker(CLSP_STATUS_SOCKET_FAILURE);
          return;
        }
        if (count > 0) {
          for (int index = 0; index < count; ++index) {
            if (events[static_cast<std::size_t>(index)].filter == EVFILT_READ) {
              status = drain_socket();
              last_dtls_progress = monotonic_microseconds();
              if (status != CLSP_STATUS_OK) {
                fail_worker(status);
                return;
              }
            }
          }
        }

        if (dtls_.authenticated() && !authenticated_.load(std::memory_order_acquire)) {
          status = srtp_.initialize(dtls_.exporter());
          if (status != CLSP_STATUS_OK) {
            fail_worker(status);
            return;
          }
          authenticated_.store(true, std::memory_order_release);
          signal_startup(CLSP_STATUS_OK);
          publish_lifecycle(CLSP_LIFECYCLE_AUTHENTICATED);
        }

        if (!dtls_.authenticated()) {
          const auto timeout_seconds = dtls_.timeout_seconds();
          const auto now = monotonic_microseconds();
          if (timeout_seconds != 0 && now >= last_dtls_progress &&
              now - last_dtls_progress >= static_cast<std::uint64_t>(timeout_seconds) * 1'000'000U) {
            status = dtls_.handle_timeout();
            last_dtls_progress = now;
            if (status != CLSP_STATUS_OK) {
              fail_worker(status);
              return;
            }
          }
          continue;
        }

        status = drain_control_queue();
        if (status != CLSP_STATUS_OK) {
          fail_worker(status);
          return;
        }
        status = retry_control();
        if (status != CLSP_STATUS_OK) {
          fail_worker(status);
          return;
        }
        status = process_input_configuration();
        if (status != CLSP_STATUS_OK) {
          fail_worker(status);
          return;
        }
        status = drain_capture_queue();
        if (status != CLSP_STATUS_OK) {
          fail_worker(status);
          return;
        }
        status = transmit_input();
        if (status != CLSP_STATUS_OK) {
          fail_worker(status);
          return;
        }
      }
    }

    /** @brief Drain up to the bounded initial receive batch from the UDP socket. */
    [[nodiscard]] clsp_status_t drain_socket() noexcept {
      for (std::size_t index = 0; index < receive_batch_size; ++index) {
        std::array<std::uint8_t, maximum_udp_payload> packet {};
        const auto received = recv(socket_, packet.data(), packet.size(), 0);
        if (received < 0) {
          return errno == EAGAIN || errno == EWOULDBLOCK ? CLSP_STATUS_OK : CLSP_STATUS_SOCKET_FAILURE;
        }
        if (received == 0) {
          increment(RuntimeCounter::dropped);
          continue;
        }
        auto datagram = std::span<std::uint8_t> {packet.data(), static_cast<std::size_t>(received)};
        switch (classify(datagram)) {
          case PacketClass::dtls: {
            const auto status = dtls_.receive(datagram);
            if (status != CLSP_STATUS_OK) {
              increment(RuntimeCounter::authentication_failure);
              return status;
            }
            break;
          }
          case PacketClass::srtp_or_srtcp: {
            if (!srtp_.ready()) {
              increment(RuntimeCounter::dropped);
              break;
            }
            auto packet_length = datagram.size();
            const auto status = srtp_.unprotect(packet, packet_length, is_rtcp(datagram));
            if (status != CLSP_STATUS_OK) {
              increment(RuntimeCounter::authentication_failure);
              break;
            }
            increment(RuntimeCounter::received);
            if (!handle_authenticated_realtime(std::span<const std::uint8_t> {packet.data(), packet_length})) {
              increment(RuntimeCounter::dropped);
            }
            break;
          }
          case PacketClass::invalid:
            increment(RuntimeCounter::dropped);
            break;
        }
      }
      return CLSP_STATUS_OK;
    }

    /** @brief Install a pending input authority on the socket-owner thread. */
    [[nodiscard]] clsp_status_t process_input_configuration() noexcept {
      clsp_input_configuration_t selected {};
      pthread_mutex_lock(&mutex_);
      if (!input_configuration_pending_) {
        pthread_mutex_unlock(&mutex_);
        return CLSP_STATUS_OK;
      }
      selected = pending_input_configuration_;
      input_configuration_pending_ = false;
      pthread_mutex_unlock(&mutex_);

      input_configuration_ = selected;
      if (!pointer_composer_.reset(1, 1) || !edge_sender_.reset(selected.input_generation)) {
        return CLSP_STATUS_INTERNAL_FAILURE;
      }
      input_configured_ = true;
      capture_accepting_ = true;
      baseline_acknowledged_ = false;
      baseline_id_ = (static_cast<std::uint64_t>(arc4random()) << 32U) | arc4random();
      if (baseline_id_ == 0) {
        baseline_id_ = 1;
      }
      baseline_last_sent_us_ = 0;
      pointer_dirty_ = false;
      pointer_ordinal_ = 0;
      latest_edge_id_ = 0;
      latest_state_sequence_ = 2;
      next_state_sequence_ = 2;
      rtp_sequence_ = static_cast<std::uint16_t>(arc4random());
      input_tokens_bits_ = selected.reserved_input_wire_bits_per_second / 500U;
      input_last_credit_us_ = monotonic_microseconds();
      last_pointer_sent_us_ = 0;
      return CLSP_STATUS_OK;
    }

    /** @brief Move captured records into portable native composers. */
    [[nodiscard]] clsp_status_t drain_capture_queue() noexcept {
      if (!input_configured_) {
        return CLSP_STATUS_OK;
      }
      for (;;) {
        CaptureRecord record;
        const auto read = capture_read_.load(std::memory_order_relaxed);
        if (read == capture_write_.load(std::memory_order_acquire)) {
          return CLSP_STATUS_OK;
        }
        record = capture_queue_[read];
        capture_read_.store((read + 1U) % capture_queue_capacity, std::memory_order_release);

        if (record.kind == CaptureKind::neutralize) {
          capture_accepting_ = false;
          pointer_dirty_ = false;
          continue;
        }
        if (!capture_accepting_) {
          continue;
        }
        if (record.kind == CaptureKind::pointer) {
          ++pointer_ordinal_;
          const auto result = pointer_composer_.add_relative(
            1,
            pointer_ordinal_,
            record.pointer.delta_x,
            record.pointer.delta_y,
            record.pointer.vertical_scroll,
            record.pointer.horizontal_scroll
          );
          if (result == lumen::lsp::input_plane::pointer_compose_result::accepted) {
            pointer_dirty_ = true;
            pointer_sample_time_us_ = record.pointer.sample_time_microseconds;
          } else if (result != lumen::lsp::input_plane::pointer_compose_result::batch_full) {
            return CLSP_STATUS_INTERNAL_FAILURE;
          }
          continue;
        }

        if (record.kind == CaptureKind::controller_state) {
          auto &state = controller_states_[record.controller_state.controller_id - 1U];
          state.value = record.controller_state;
          ++state.physical_ordinal;
          state.dirty = true;
          continue;
        }
        if (record.kind == CaptureKind::controller_sensor) {
          auto &sensor = controller_sensors_[record.controller_sensor.controller_id - 1U]
                                            [record.controller_sensor.sensor_type - 1U];
          sensor.value = record.controller_sensor;
          ++sensor.physical_ordinal;
          sensor.dirty = true;
          continue;
        }
        if (record.kind == CaptureKind::controller_edge || record.kind == CaptureKind::touch_edge) {
          const auto controller = record.kind == CaptureKind::controller_edge;
          lumen::lsp::input_plane::edge_record edge {
            .physical_time_us = controller ? record.controller_edge.sample_time_microseconds : record.touch_edge.sample_time_microseconds,
            .kind = static_cast<lumen::lsp::input_plane::edge_kind>(controller ? record.controller_edge.kind : record.touch_edge.kind),
            .device = controller ? lumen::lsp::input_plane::device_type::controller : lumen::lsp::input_plane::device_type::touch,
            .control_id = controller ? record.controller_edge.control_id : static_cast<std::uint16_t>(record.touch_edge.controller_id),
            .device_id = controller ? record.controller_edge.controller_id : record.touch_edge.contact_id,
            .instance_generation = controller ? record.controller_edge.instance_generation : record.touch_edge.instance_generation,
          };
          std::uint64_t assigned_id = 0;
          if (edge_sender_.enqueue(edge, assigned_id) != lumen::lsp::input_plane::edge_send_result::accepted) {
            return CLSP_STATUS_RESOURCE_EXHAUSTED;
          }
          latest_edge_id_ = assigned_id;
          continue;
        }
        if (record.kind == CaptureKind::touch_state) {
          auto &touch = touch_states_[record.touch_state.contact_id - 1U];
          touch.value = record.touch_state;
          ++touch.physical_ordinal;
          touch.dirty = true;
          continue;
        }

        lumen::lsp::input_plane::edge_record edge {
          .physical_time_us = record.edge.sample_time_microseconds,
          .kind = static_cast<lumen::lsp::input_plane::edge_kind>(record.edge.kind),
          .device = record.edge.kind <= CLSP_INPUT_EDGE_KEY_UP ?
                      lumen::lsp::input_plane::device_type::keyboard :
                      lumen::lsp::input_plane::device_type::pointer,
          .control_id = record.edge.control_id,
          .device_id = 1,
          .instance_generation = 1,
        };
        std::uint64_t assigned_id = 0;
        const auto result = edge_sender_.enqueue(edge, assigned_id);
        if (result != lumen::lsp::input_plane::edge_send_result::accepted) {
          return result == lumen::lsp::input_plane::edge_send_result::window_full ?
                   CLSP_STATUS_RESOURCE_EXHAUSTED :
                   CLSP_STATUS_INTERNAL_FAILURE;
        }
        latest_edge_id_ = assigned_id;
      }
    }

    /** @brief Send baseline, due edge retries, and latest cumulative pointer state. */
    [[nodiscard]] clsp_status_t transmit_input() noexcept {
      if (!input_configured_) {
        return CLSP_STATUS_OK;
      }
      const auto now = monotonic_microseconds();
      replenish_input_credit(now);
      if (!baseline_acknowledged_) {
        if (baseline_last_sent_us_ == 0 || now - baseline_last_sent_us_ >= 20'000U) {
          return send_baseline(now);
        }
        return CLSP_STATUS_OK;
      }

      std::array<lumen::lsp::input_plane::edge_record, 16> edges {};
      const auto edge_count = edge_sender_.due_batch(now, 20'000U, edges);
      if (edge_count != 0) {
        const auto status = send_edges(std::span<const lumen::lsp::input_plane::edge_record> {edges.data(), edge_count}, now);
        if (status != CLSP_STATUS_OK) {
          return status;
        }
      }
      const auto pointer_interval = std::max<std::uint64_t>(1U, 1'000'000U / input_configuration_.pointer_rate);
      if (pointer_dirty_ && (last_pointer_sent_us_ == 0 || now - last_pointer_sent_us_ >= pointer_interval)) {
        return send_pointer(now);
      }
      const auto controller_interval = std::max<std::uint64_t>(1U, 1'000'000U / input_configuration_.controller_rate);
      const auto sensor_interval = std::max<std::uint64_t>(1U, 1'000'000U / input_configuration_.sensor_rate);
      for (std::size_t index = 0; index < controller_states_.size(); ++index) {
        auto &state = controller_states_[index];
        if (state.dirty && (state.last_sent_us == 0 || now - state.last_sent_us >= controller_interval)) {
          return send_controller_state(index, now);
        }
        for (std::size_t sensor_index = 0; sensor_index < 2; ++sensor_index) {
          auto &sensor = controller_sensors_[index][sensor_index];
          if (sensor.dirty && (sensor.last_sent_us == 0 || now - sensor.last_sent_us >= sensor_interval)) {
            return send_controller_sensor(index, sensor_index, now);
          }
        }
      }
      for (std::size_t index = 0; index < touch_states_.size(); ++index) {
        auto &touch = touch_states_[index];
        if (touch.dirty && (touch.last_sent_us == 0 || now - touch.last_sent_us >= controller_interval)) {
          return send_touch_state(index, now);
        }
      }
      return CLSP_STATUS_OK;
    }

    /** @brief Serialize and send the exact neutral one-part baseline. */
    [[nodiscard]] clsp_status_t send_baseline(const std::uint64_t now) noexcept {
      std::array<std::uint8_t, 16> baseline {'L', 'S', 'P', 'B', 1, 0, 0, 0};
      lumen::lsp::wire::write_be<std::uint64_t>(std::span<std::uint8_t> {baseline}.subspan(8, 8), latest_edge_id_);
      std::array<std::uint8_t, 32> digest {};
      if (wc_Sha256Hash(baseline.data(), static_cast<word32>(baseline.size()), digest.data()) != 0) {
        return CLSP_STATUS_INTERNAL_FAILURE;
      }
      std::array<std::uint8_t, lumen::lsp::input_plane::baseline_part_header_size + 16> part_bytes {};
      const lumen::lsp::input_plane::baseline_part part {
        .part_index = 0,
        .part_count = 1,
        .total_length = static_cast<std::uint32_t>(baseline.size()),
        .part_offset = 0,
        .part_length = static_cast<std::uint32_t>(baseline.size()),
        .digest = digest,
        .bytes = baseline,
      };
      if (lumen::lsp::input_plane::serialize_baseline_part(part, part_bytes) != lumen::lsp::input_plane::wire_error::none) {
        return CLSP_STATUS_INTERNAL_FAILURE;
      }
      const lumen::lsp::input_plane::common_header header {
        .input_generation = input_configuration_.input_generation,
        .kind = lumen::lsp::input_plane::packet_kind::baseline_part,
        .state_sequence = 1,
        .sample_time_us = now,
        .object_id = baseline_id_,
        .edge_watermark = latest_edge_id_,
      };
      bool submitted = false;
      const auto status = send_input_packet(header, part_bytes, now, submitted);
      if (status == CLSP_STATUS_OK && submitted) {
        baseline_last_sent_us_ = now;
      }
      return status;
    }

    /** @brief Serialize and send one retained-until-ACK edge batch. */
    [[nodiscard]] clsp_status_t send_edges(
      const std::span<const lumen::lsp::input_plane::edge_record> edges,
      const std::uint64_t now
    ) noexcept {
      std::array<std::uint8_t, 16U * lumen::lsp::input_plane::edge_record_size> payload {};
      for (std::size_t index = 0; index < edges.size(); ++index) {
        if (lumen::lsp::input_plane::serialize_edge_record(
              edges[index],
              std::span<std::uint8_t> {payload}.subspan(index * lumen::lsp::input_plane::edge_record_size)
            ) != lumen::lsp::input_plane::wire_error::none) {
          return CLSP_STATUS_INTERNAL_FAILURE;
        }
      }
      const lumen::lsp::input_plane::common_header header {
        .input_generation = input_configuration_.input_generation,
        .kind = lumen::lsp::input_plane::packet_kind::edge_batch,
        .state_sequence = latest_state_sequence_,
        .sample_time_us = edges.back().physical_time_us,
        .object_id = edges.back().edge_id,
        .edge_watermark = edges.back().edge_id,
      };
      const auto live_payload = std::span<const std::uint8_t> {payload.data(), edges.size() * lumen::lsp::input_plane::edge_record_size};
      bool submitted = false;
      const auto status = send_input_packet(header, live_payload, now, submitted);
      if (status == CLSP_STATUS_OK && submitted && !edge_sender_.mark_sent(edges.front().edge_id, edges.size(), now)) {
        return CLSP_STATUS_INTERNAL_FAILURE;
      }
      return status;
    }

    /** @brief Serialize and send the newest cumulative relative-pointer sample. */
    [[nodiscard]] clsp_status_t send_pointer(const std::uint64_t now) noexcept {
      std::array<std::uint8_t, lumen::lsp::input_plane::pointer_payload_size> payload {};
      if (lumen::lsp::input_plane::serialize_pointer_payload(pointer_composer_.state(), payload) !=
          lumen::lsp::input_plane::wire_error::none) {
        return CLSP_STATUS_INTERNAL_FAILURE;
      }
      const auto sequence = next_state_sequence_;
      const lumen::lsp::input_plane::common_header header {
        .input_generation = input_configuration_.input_generation,
        .kind = lumen::lsp::input_plane::packet_kind::pointer_motion,
        .state_sequence = sequence,
        .sample_time_us = pointer_sample_time_us_,
        .object_id = pointer_composer_.pointer_id(),
        .edge_watermark = latest_edge_id_,
      };
      bool submitted = false;
      const auto status = send_input_packet(header, payload, now, submitted);
      if (status == CLSP_STATUS_OK && submitted) {
        latest_state_sequence_ = sequence;
        ++next_state_sequence_;
        pointer_composer_.mark_emitted();
        pointer_dirty_ = false;
        last_pointer_sent_us_ = now;
      }
      return status;
    }

    /** @brief Serialize and submit one exact 36-byte controller analog record. */
    [[nodiscard]] clsp_status_t send_controller_state(const std::size_t index, const std::uint64_t now) noexcept {
      auto &state = controller_states_[index];
      std::array<std::uint8_t, 36> payload {};
      payload[0] = 3;
      lumen::lsp::wire::write_be<std::uint16_t>(std::span<std::uint8_t> {payload}.subspan(2, 2), 1);
      lumen::lsp::wire::write_be<std::uint32_t>(std::span<std::uint8_t> {payload}.subspan(4, 4), state.value.controller_id);
      lumen::lsp::wire::write_be<std::uint32_t>(std::span<std::uint8_t> {payload}.subspan(8, 4), state.value.instance_generation);
      lumen::lsp::wire::write_be<std::uint16_t>(std::span<std::uint8_t> {payload}.subspan(12, 2), 36);
      lumen::lsp::wire::write_be<std::uint64_t>(std::span<std::uint8_t> {payload}.subspan(16, 8), state.physical_ordinal);
      payload[24] = state.value.left_trigger;
      payload[25] = state.value.right_trigger;
      lumen::lsp::wire::write_be<std::uint16_t>(std::span<std::uint8_t> {payload}.subspan(28, 2), std::bit_cast<std::uint16_t>(state.value.left_stick_x));
      lumen::lsp::wire::write_be<std::uint16_t>(std::span<std::uint8_t> {payload}.subspan(30, 2), std::bit_cast<std::uint16_t>(state.value.left_stick_y));
      lumen::lsp::wire::write_be<std::uint16_t>(std::span<std::uint8_t> {payload}.subspan(32, 2), std::bit_cast<std::uint16_t>(state.value.right_stick_x));
      lumen::lsp::wire::write_be<std::uint16_t>(std::span<std::uint8_t> {payload}.subspan(34, 2), std::bit_cast<std::uint16_t>(state.value.right_stick_y));
      const auto sequence = next_state_sequence_;
      const lumen::lsp::input_plane::common_header header {
        .input_generation = input_configuration_.input_generation,
        .kind = lumen::lsp::input_plane::packet_kind::device_state,
        .state_sequence = sequence,
        .sample_time_us = state.value.sample_time_microseconds,
        .object_id = lumen::lsp::input_plane::make_device_object_id(lumen::lsp::input_plane::device_type::controller, state.value.controller_id),
        .edge_watermark = latest_edge_id_,
      };
      bool submitted = false;
      const auto status = send_input_packet(header, payload, now, submitted);
      if (status == CLSP_STATUS_OK && submitted) {
        latest_state_sequence_ = sequence;
        ++next_state_sequence_;
        state.last_sent_us = now;
        state.dirty = false;
      }
      return status;
    }

    /** @brief Serialize and submit one exact 36-byte controller sensor record. */
    [[nodiscard]] clsp_status_t send_controller_sensor(
      const std::size_t index,
      const std::size_t sensor_index,
      const std::uint64_t now
    ) noexcept {
      auto &sensor = controller_sensors_[index][sensor_index];
      std::array<std::uint8_t, 36> payload {};
      payload[0] = 3;
      payload[1] = sensor.value.sensor_type;
      lumen::lsp::wire::write_be<std::uint16_t>(std::span<std::uint8_t> {payload}.subspan(2, 2), 1);
      lumen::lsp::wire::write_be<std::uint32_t>(std::span<std::uint8_t> {payload}.subspan(4, 4), sensor.value.controller_id);
      lumen::lsp::wire::write_be<std::uint32_t>(std::span<std::uint8_t> {payload}.subspan(8, 4), sensor.value.instance_generation);
      lumen::lsp::wire::write_be<std::uint16_t>(std::span<std::uint8_t> {payload}.subspan(12, 2), 36);
      lumen::lsp::wire::write_be<std::uint64_t>(std::span<std::uint8_t> {payload}.subspan(16, 8), sensor.physical_ordinal);
      lumen::lsp::wire::write_be<std::uint32_t>(std::span<std::uint8_t> {payload}.subspan(24, 4), std::bit_cast<std::uint32_t>(sensor.value.x));
      lumen::lsp::wire::write_be<std::uint32_t>(std::span<std::uint8_t> {payload}.subspan(28, 4), std::bit_cast<std::uint32_t>(sensor.value.y));
      lumen::lsp::wire::write_be<std::uint32_t>(std::span<std::uint8_t> {payload}.subspan(32, 4), std::bit_cast<std::uint32_t>(sensor.value.z));
      const auto sequence = next_state_sequence_;
      const lumen::lsp::input_plane::common_header header {
        .input_generation = input_configuration_.input_generation,
        .kind = lumen::lsp::input_plane::packet_kind::sensor_state,
        .state_sequence = sequence,
        .sample_time_us = sensor.value.sample_time_microseconds,
        .object_id = lumen::lsp::input_plane::make_sensor_object_id(sensor.value.controller_id, static_cast<lumen::lsp::input_plane::sensor_type>(sensor.value.sensor_type)),
        .edge_watermark = latest_edge_id_,
      };
      bool submitted = false;
      const auto status = send_input_packet(header, payload, now, submitted);
      if (status == CLSP_STATUS_OK && submitted) {
        latest_state_sequence_ = sequence;
        ++next_state_sequence_;
        sensor.last_sent_us = now;
        sensor.dirty = false;
      }
      return status;
    }

    /** @brief Serialize and submit one exact 40-byte controller touch record. */
    [[nodiscard]] clsp_status_t send_touch_state(const std::size_t index, const std::uint64_t now) noexcept {
      auto &touch = touch_states_[index];
      std::array<std::uint8_t, 40> payload {};
      payload[0] = 4;
      lumen::lsp::wire::write_be<std::uint16_t>(std::span<std::uint8_t> {payload}.subspan(2, 2), 1);
      lumen::lsp::wire::write_be<std::uint32_t>(std::span<std::uint8_t> {payload}.subspan(4, 4), touch.value.contact_id);
      lumen::lsp::wire::write_be<std::uint32_t>(std::span<std::uint8_t> {payload}.subspan(8, 4), touch.value.instance_generation);
      lumen::lsp::wire::write_be<std::uint16_t>(std::span<std::uint8_t> {payload}.subspan(12, 2), 40);
      lumen::lsp::wire::write_be<std::uint64_t>(std::span<std::uint8_t> {payload}.subspan(16, 8), touch.physical_ordinal);
      lumen::lsp::wire::write_be<std::uint32_t>(std::span<std::uint8_t> {payload}.subspan(24, 4), touch.value.controller_id);
      lumen::lsp::wire::write_be<std::uint32_t>(std::span<std::uint8_t> {payload}.subspan(28, 4), touch.value.x);
      lumen::lsp::wire::write_be<std::uint32_t>(std::span<std::uint8_t> {payload}.subspan(32, 4), touch.value.y);
      lumen::lsp::wire::write_be<std::uint32_t>(std::span<std::uint8_t> {payload}.subspan(36, 4), touch.value.pressure);
      const auto sequence = next_state_sequence_;
      const lumen::lsp::input_plane::common_header header {
        .input_generation = input_configuration_.input_generation,
        .kind = lumen::lsp::input_plane::packet_kind::device_state,
        .state_sequence = sequence,
        .sample_time_us = touch.value.sample_time_microseconds,
        .object_id = lumen::lsp::input_plane::make_device_object_id(lumen::lsp::input_plane::device_type::touch, touch.value.contact_id),
        .edge_watermark = latest_edge_id_,
      };
      bool submitted = false;
      const auto status = send_input_packet(header, payload, now, submitted);
      if (status == CLSP_STATUS_OK && submitted) {
        latest_state_sequence_ = sequence;
        ++next_state_sequence_;
        touch.last_sent_us = now;
        touch.dirty = false;
      }
      return status;
    }

    /** @brief Wrap one checked input payload in RTP, protect in place, pace, and send. */
    [[nodiscard]] clsp_status_t send_input_packet(
      const lumen::lsp::input_plane::common_header &header,
      const std::span<const std::uint8_t> payload,
      const std::uint64_t now,
      bool &submitted
    ) noexcept {
      submitted = false;
      std::array<std::uint8_t, maximum_udp_payload> packet {};
      const lumen::lsp::rtp_fixed_header rtp {
        .payload_type = input_configuration_.input_payload_type,
        .sequence_number = rtp_sequence_,
        .timestamp = static_cast<std::uint32_t>(header.sample_time_us),
        .ssrc = input_configuration_.input_ssrc,
      };
      const auto rtp_result = lumen::lsp::write_rtp_fixed_header(rtp, {}, packet);
      if (!rtp_result) {
        return CLSP_STATUS_INTERNAL_FAILURE;
      }
      const auto input_destination = std::span<std::uint8_t> {packet}.subspan(rtp_result.bytes_written);
      if (lumen::lsp::input_plane::serialize_packet(header, payload, input_destination) !=
          lumen::lsp::input_plane::wire_error::none) {
        return CLSP_STATUS_INTERNAL_FAILURE;
      }
      auto length = rtp_result.bytes_written + lumen::lsp::input_plane::common_header_size + payload.size();
      const auto charged_bits = static_cast<std::uint64_t>(length + 16U + 28U) * 8U;
      if (charged_bits > input_tokens_bits_) {
        return CLSP_STATUS_OK;
      }
      const auto status = srtp_.protect(packet, length, false);
      if (status != CLSP_STATUS_OK) {
        return status;
      }
      const auto sent = ::send(socket_, packet.data(), length, 0);
      ++rtp_sequence_;
      if (sent != static_cast<ssize_t>(length)) {
        return sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) ? CLSP_STATUS_OK : CLSP_STATUS_SOCKET_FAILURE;
      }
      input_tokens_bits_ -= charged_bits;
      submitted = true;
      increment(RuntimeCounter::transmitted);
      (void)now;
      return CLSP_STATUS_OK;
    }

    /** @brief Refill at most two milliseconds of dedicated input credit. */
    void replenish_input_credit(const std::uint64_t now) noexcept {
      if (now < input_last_credit_us_) {
        input_last_credit_us_ = now;
        return;
      }
      const auto elapsed = now - input_last_credit_us_;
      const auto earned = elapsed > std::numeric_limits<std::uint64_t>::max() /
                                      input_configuration_.reserved_input_wire_bits_per_second ?
                            std::numeric_limits<std::uint64_t>::max() :
                            elapsed * input_configuration_.reserved_input_wire_bits_per_second / 1'000'000U;
      const auto capacity = input_configuration_.reserved_input_wire_bits_per_second / 500U;
      input_tokens_bits_ = earned >= capacity || input_tokens_bits_ >= capacity - earned ?
                             capacity : input_tokens_bits_ + earned;
      input_last_credit_us_ = now;
    }

    /** @brief Parse authenticated SRTCP LSPI and retire baseline/edge state. */
    [[nodiscard]] bool handle_authenticated_realtime(const std::span<const std::uint8_t> packet) noexcept {
      if (!input_configured_ || packet.size() < 12U || (packet[0] >> 6U) != 2U || packet[1] != 204U) {
        return false;
      }
      const auto words = lumen::lsp::wire::read_be<std::uint16_t>(packet.subspan(2, 2));
      if ((static_cast<std::size_t>(words) + 1U) * 4U != packet.size() ||
          lumen::lsp::wire::read_be<std::uint32_t>(packet.subspan(4, 4)) != input_configuration_.acknowledgement_ssrc) {
        return false;
      }
      if (std::equal(lumen::lsp::input_plane::lspg_name.begin(), lumen::lsp::input_plane::lspg_name.end(), packet.begin() + 8)) {
        const auto parsed = lumen::lsp::input_plane::parse_lspg(packet.subspan(12));
        if (!parsed || parsed.input_generation != input_configuration_.input_generation || callbacks_.controller_output == nullptr) {
          return false;
        }
        const auto status = callbacks_.controller_output(
          callbacks_.context,
          {.data = packet.data() + 12, .length = packet.size() - 12U}
        );
        if (parsed.subtype == lumen::lsp::input_plane::lspg_subtype::command) {
          return send_controller_ack(parsed, static_cast<lumen::lsp::input_plane::controller_command_status>(status)) == CLSP_STATUS_OK;
        }
        return true;
      }
      if (!std::equal(lumen::lsp::input_plane::lspi_name.begin(), lumen::lsp::input_plane::lspi_name.end(), packet.begin() + 8)) {
        return false;
      }
      const auto ack = lumen::lsp::input_plane::parse_lspi_ack(packet.subspan(12), input_configuration_.input_generation);
      if (!ack) {
        return false;
      }
      if (ack.value.accepted_baseline_id == baseline_id_) {
        baseline_acknowledged_ = true;
      }
      edge_sender_.acknowledge(ack.value.contiguous_edge_id, ack.value.edge_reception_bitmap);
      if ((ack.value.flags & static_cast<std::uint8_t>(lumen::lsp::input_plane::lspi_flag::baseline_requested)) != 0) {
        baseline_acknowledged_ = false;
        baseline_last_sent_us_ = 0;
      }
      return true;
    }

    /** @brief Protect and send one terminal client-to-host LSPG command ACK. */
    [[nodiscard]] clsp_status_t send_controller_ack(
      const lumen::lsp::input_plane::parsed_lspg &command,
      const lumen::lsp::input_plane::controller_command_status status
    ) noexcept {
      if (!lumen::lsp::input_plane::valid_controller_command_status(status)) {
        return CLSP_STATUS_INTERNAL_FAILURE;
      }
      std::array<std::uint8_t, maximum_udp_payload> packet {};
      packet[0] = 0x80;
      packet[1] = 204;
      lumen::lsp::wire::write_be<std::uint32_t>(std::span<std::uint8_t> {packet}.subspan(4, 4), input_configuration_.input_ssrc);
      std::copy(lumen::lsp::input_plane::lspg_name.begin(), lumen::lsp::input_plane::lspg_name.end(), packet.begin() + 8);
      const lumen::lsp::input_plane::controller_command_ack ack {
        .input_generation = command.input_generation,
        .controller_id = command.controller_id,
        .instance_generation = command.instance_generation,
        .sequence = command.sequence,
        .status = status,
      };
      if (lumen::lsp::input_plane::serialize_controller_ack(ack, std::span<std::uint8_t> {packet}.subspan(12)) !=
          lumen::lsp::input_plane::lspg_error::none) {
        return CLSP_STATUS_INTERNAL_FAILURE;
      }
      auto length = 12U + lumen::lsp::input_plane::lspg_header_size + 4U;
      lumen::lsp::wire::write_be<std::uint16_t>(
        std::span<std::uint8_t> {packet}.subspan(2, 2),
        static_cast<std::uint16_t>(length / 4U - 1U)
      );
      const auto protected_status = srtp_.protect(packet, length, true);
      if (protected_status != CLSP_STATUS_OK) return protected_status;
      const auto sent = ::send(socket_, packet.data(), length, 0);
      if (sent != static_cast<ssize_t>(length)) {
        return sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) ? CLSP_STATUS_OK : CLSP_STATUS_SOCKET_FAILURE;
      }
      increment(RuntimeCounter::transmitted);
      return CLSP_STATUS_OK;
    }

    /** @brief Receive one authenticated DTLS application record from wolfSSL. */
    static bool receive_application_data(
      void *opaque,
      const std::span<const std::uint8_t> plaintext
    ) noexcept {
      return static_cast<Impl *>(opaque)->handle_control_frame(plaintext);
    }

    /** @brief Validate ACK state, suppress duplicates, ACK, and publish one LSPC frame. */
    [[nodiscard]] bool handle_control_frame(const std::span<const std::uint8_t> plaintext) noexcept {
      const auto parsed = lumen::lsp::parse_lspc(plaintext);
      if (!parsed) {
        increment(RuntimeCounter::dropped);
        return true;
      }
      outbound_window_.acknowledge(parsed.header.acknowledgement_base, parsed.header.acknowledgement_bitmap);
      const auto observed = receive_window_.observe(parsed.header.message_id);
      if (observed == lumen::lsp::receive_id_result::too_far_ahead ||
          observed == lumen::lsp::receive_id_result::too_old ||
          observed == lumen::lsp::receive_id_result::zero) {
        increment(RuntimeCounter::dropped);
        return false;
      }
      increment(RuntimeCounter::received);
      const auto ack_required = lumen::lsp::has_flag(
        parsed.header.flags,
        lumen::lsp::lspc_flag::acknowledgement_required
      );
      if (ack_required || observed == lumen::lsp::receive_id_result::duplicate) {
        if (send_acknowledgement() != CLSP_STATUS_OK) {
          return false;
        }
      }
      if (observed == lumen::lsp::receive_id_result::duplicate ||
          lumen::lsp::has_flag(parsed.header.flags, lumen::lsp::lspc_flag::acknowledgement_only)) {
        return true;
      }
      if (parsed.header.message_type == 0x0002U && parsed.header.connection_generation != 0) {
        connection_generation_ = parsed.header.connection_generation;
      }
      if (callbacks_.control != nullptr) {
        const clsp_control_event_t event {
          .abi_version = CLSP_CORE_ABI_VERSION,
          .structure_size = sizeof(clsp_control_event_t),
          .message_type = parsed.header.message_type,
          .flags = parsed.header.flags,
          .reserved_zero = 0,
          .connection_generation = parsed.header.connection_generation,
          .message_id = parsed.header.message_id,
          .request_id = parsed.header.request_id,
          .payload = {.data = parsed.payload.data(), .length = parsed.payload.size()},
        };
        callbacks_.control(callbacks_.context, event);
      }
      return true;
    }

    /** @brief Emit one immediate ACK-only frame. */
    [[nodiscard]] clsp_status_t send_acknowledgement() noexcept {
      std::array<std::uint8_t, lumen::lsp::lspc_header_size> frame {};
      const lumen::lsp::lspc_header header {
        .flags = static_cast<std::uint8_t>(lumen::lsp::lspc_flag::acknowledgement_only),
        .message_type = 0,
        .connection_generation = connection_generation_,
        .payload_length = 0,
        .message_id = next_message_id_++,
        .request_id = 0,
        .acknowledgement_base = receive_window_.base(),
        .acknowledgement_bitmap = receive_window_.bitmap(),
      };
      const auto serialized = lumen::lsp::serialize_lspc(header, {}, frame);
      if (!serialized) {
        return CLSP_STATUS_INTERNAL_FAILURE;
      }
      const auto status = dtls_.send_application_data(frame);
      if (status == CLSP_STATUS_OK) {
        increment(RuntimeCounter::transmitted);
      }
      return status;
    }

    /** @brief Assign message IDs and transmit queued control while the 64-frame window has room. */
    [[nodiscard]] clsp_status_t drain_control_queue() noexcept {
      while (outbound_window_.size() < 64U) {
        ControlCommand command;
        pthread_mutex_lock(&mutex_);
        if (queued_control_count_ == 0) {
          pthread_mutex_unlock(&mutex_);
          return CLSP_STATUS_OK;
        }
        command = control_queue_[control_queue_head_];
        control_queue_[control_queue_head_].payload.clear();
        control_queue_head_ = (control_queue_head_ + 1U) % control_queue_capacity;
        --queued_control_count_;
        pthread_mutex_unlock(&mutex_);

        std::array<std::uint8_t, maximum_control_frame> frame {};
        const auto message_id = next_message_id_++;
        const lumen::lsp::lspc_header header {
          .flags = static_cast<std::uint8_t>(lumen::lsp::lspc_flag::acknowledgement_required),
          .message_type = command.message_type,
          .connection_generation = command.message_type == 0x0001U ? 0U : connection_generation_,
          .payload_length = static_cast<std::uint32_t>(command.payload.size()),
          .message_id = message_id,
          .request_id = command.request_id,
          .acknowledgement_base = receive_window_.base(),
          .acknowledgement_bitmap = receive_window_.bitmap(),
        };
        const auto serialized = lumen::lsp::serialize_lspc(header, command.payload.bytes(), frame);
        if (!serialized) {
          return CLSP_STATUS_INTERNAL_FAILURE;
        }
        const auto encoded = std::span<const std::uint8_t> {frame.data(), serialized.bytes_written};
        const auto status = dtls_.send_application_data(encoded);
        if (status != CLSP_STATUS_OK) {
          return status;
        }
        increment(RuntimeCounter::transmitted);
        const auto stored = outbound_window_.store(
          message_id,
          encoded,
          monotonic_microseconds(),
          command.deadline_microseconds,
          rto_
        );
        if (stored != lumen::lsp::outbound_store_result::stored) {
          return stored == lumen::lsp::outbound_store_result::window_full ?
                   CLSP_STATUS_CONTROL_WINDOW_FULL :
                   CLSP_STATUS_INTERNAL_FAILURE;
        }
      }
      return CLSP_STATUS_OK;
    }

    /** @brief Retransmit byte-identical due LSPC frames or fail an exhausted operation. */
    [[nodiscard]] clsp_status_t retry_control() noexcept {
      const auto now = monotonic_microseconds();
      if (outbound_window_.has_failed(now)) {
        return CLSP_STATUS_TIMEOUT;
      }
      while (auto *retained = outbound_window_.due(now)) {
        const auto status = dtls_.send_application_data(retained->frame.bytes());
        if (status != CLSP_STATUS_OK) {
          return status;
        }
        increment(RuntimeCounter::transmitted);
        outbound_window_.mark_retransmitted(*retained, now, rto_);
      }
      return CLSP_STATUS_OK;
    }

    /** @brief Publish one terminal startup result and wake the starting thread. */
    void signal_startup(const clsp_status_t status) noexcept {
      pthread_mutex_lock(&mutex_);
      if (!startup_complete_) {
        startup_status_ = status;
        startup_complete_ = true;
        pthread_cond_broadcast(&condition_);
      }
      pthread_mutex_unlock(&mutex_);
    }

    /** @brief Fail the worker without exposing parser/security details to the peer. */
    void fail_worker(const clsp_status_t status) noexcept {
      signal_startup(status);
      authenticated_.store(false, std::memory_order_release);
      stop_requested_.store(true, std::memory_order_release);
      publish_lifecycle(CLSP_LIFECYCLE_FAILED);
    }

    /** @brief Copy one capture record into the bounded native ring. */
    [[nodiscard]] clsp_status_t enqueue_capture(const CaptureRecord &record) noexcept {
      const auto write = capture_write_.load(std::memory_order_relaxed);
      const auto next = (write + 1U) % capture_queue_capacity;
      if (next == capture_read_.load(std::memory_order_acquire)) {
        increment(RuntimeCounter::dropped);
        return CLSP_STATUS_RESOURCE_EXHAUSTED;
      }
      capture_queue_[write] = record;
      capture_write_.store(next, std::memory_order_release);
      wake_worker();
      return CLSP_STATUS_OK;
    }

    /** @brief Trigger the worker's EVFILT_USER wake source. */
    void wake_worker() noexcept {
      if (kqueue_ < 0) {
        return;
      }
      struct kevent event {};
      EV_SET(&event, wake_identifier, EVFILT_USER, 0, NOTE_TRIGGER, 0, nullptr);
      (void)kevent(kqueue_, &event, 1, nullptr, 0, nullptr);
    }

    /** @brief Request an idempotent worker stop. */
    void request_stop() noexcept {
      stop_requested_.store(true, std::memory_order_release);
      wake_worker();
    }

    /** @brief Join the worker exactly once. */
    void join_worker() noexcept {
      if (worker_started_) {
        pthread_join(worker_, nullptr);
        worker_started_ = false;
      }
    }

    /** @brief Close kqueue/socket descriptors and reset non-secret platform state. */
    void cleanup_platform() noexcept {
      authenticated_.store(false, std::memory_order_release);
      if (kqueue_ >= 0) {
        ::close(kqueue_);
        kqueue_ = -1;
      }
      if (socket_ >= 0) {
        ::close(socket_);
        socket_ = -1;
      }
      peer_address_ = {};
      peer_address_size_ = 0;
    }

    static constexpr uintptr_t wake_identifier = 1;  ///< Private kqueue user-event identifier.
    pthread_t worker_ {};  ///< Dedicated socket/security/control thread.
    pthread_mutex_t mutex_ {};  ///< Startup and bounded outbound-queue lock.
    pthread_cond_t condition_ {};  ///< Synchronous startup completion condition.
    sockaddr_storage peer_address_ {};  ///< Connected peer address for DTLS cookie processing.
    unsigned int peer_address_size_ {};  ///< Encoded peer-address size.
    int socket_ {-1};  ///< Connected nonblocking UDP socket.
    int kqueue_ {-1};  ///< Socket readiness and producer wake owner.
    bool mutex_ready_ {};  ///< Mutex initialization state.
    bool condition_ready_ {};  ///< Condition initialization state.
    bool worker_started_ {};  ///< Join ownership state.
    bool startup_complete_ {};  ///< Whether startup status is terminal.
    clsp_status_t startup_status_ {CLSP_STATUS_TIMEOUT};  ///< Terminal startup result.
#endif

    clsp_configuration_t configuration_ {};  ///< Copied immutable core configuration.
    RuntimeCallbacks callbacks_ {};  ///< Stable C ABI owner callbacks.
    WolfSSLDtlsClient dtls_;  ///< Exact-policy DTLS client.
    SrtpSession srtp_;  ///< Directional AEAD AES-128-GCM contexts.
    lumen::lsp::selective_ack_window receive_window_;  ///< Peer logical-frame receive/ACK state.
    lumen::lsp::outbound_control_window<maximum_control_frame> outbound_window_;  ///< Byte-identical retry state.
    lumen::lsp::control_rto rto_;  ///< Local-path bounded RTO estimator.
    std::array<ControlCommand, control_queue_capacity> control_queue_ {};  ///< Pre-wire bounded queue.
    std::array<CaptureRecord, capture_queue_capacity> capture_queue_ {};  ///< Allocation-free captured-input ring.
    clsp_input_configuration_t pending_input_configuration_ {};  ///< Producer-copied pending input mapping.
    clsp_input_configuration_t input_configuration_ {};  ///< Worker-owned active input mapping.
    lumen::lsp::input_plane::pointer_composer pointer_composer_;  ///< Cumulative relative pointer state.
    lumen::lsp::input_plane::edge_sender edge_sender_;  ///< Exactly-once retained edge window.
    std::array<ControllerLatest, 16> controller_states_ {};  ///< Latest analog state by controller slot.
    std::array<std::array<ControllerSensorLatest, 2>, 16> controller_sensors_ {};  ///< Latest gyro/accel states.
    std::array<TouchLatest, 16> touch_states_ {};  ///< Latest controller touch contacts.
    std::atomic<bool> stop_requested_ {false};  ///< Cross-thread idempotent stop request.
    std::atomic<bool> authenticated_ {false};  ///< Product-visible exact-security readiness.
    std::size_t control_queue_head_ {};  ///< Next queued request to consume.
    std::size_t control_queue_tail_ {};  ///< Next free queue slot.
    std::size_t queued_control_count_ {};  ///< Occupied pre-wire queue slots.
    std::atomic<std::size_t> capture_read_ {0};  ///< Worker-owned SPSC read cursor.
    std::atomic<std::size_t> capture_write_ {0};  ///< Capture-source-owned SPSC write cursor.
    std::uint64_t next_message_id_ {1};  ///< Next nonzero client-to-host LSPC message ID.
    std::uint32_t connection_generation_ {};  ///< Zero through CLIENT_HELLO, then host-assigned generation.
    std::uint64_t baseline_id_ {};  ///< Current random neutral-baseline identifier.
    std::uint64_t baseline_last_sent_us_ {};  ///< Most recent baseline submission time.
    std::uint64_t pointer_ordinal_ {};  ///< Monotonic physical pointer sample ordinal.
    std::uint64_t pointer_sample_time_us_ {};  ///< Newest captured pointer time.
    std::uint64_t latest_edge_id_ {};  ///< Newest assigned physical edge identifier.
    std::uint64_t latest_state_sequence_ {2};  ///< Latest sampled replaceable-state sequence.
    std::uint64_t next_state_sequence_ {2};  ///< Next replaceable-state sequence.
    std::uint64_t input_tokens_bits_ {};  ///< Dedicated input-pacer credit.
    std::uint64_t input_last_credit_us_ {};  ///< Last token refill time.
    std::uint64_t last_pointer_sent_us_ {};  ///< Last cumulative pointer submission time.
    std::uint16_t rtp_sequence_ {};  ///< Input RTP sequence with libSRTP rollover tracking.
    bool input_configuration_pending_ {};  ///< Producer installed a new START mapping.
    bool input_configured_ {};  ///< Worker has an active input mapping.
    bool capture_accepting_ {};  ///< New physical capture is authorized.
    bool baseline_acknowledged_ {};  ///< LSPI accepted the current baseline.
    bool pointer_dirty_ {};  ///< Cumulative pointer state has unsent reports.
  };

  Runtime::Runtime(const clsp_configuration_t &configuration, const RuntimeCallbacks callbacks) noexcept:
      impl_ {new (std::nothrow) Impl {configuration, callbacks}} {
  }

  Runtime::~Runtime() {
    delete impl_;
  }

  clsp_status_t Runtime::start(const clsp_endpoint_t &endpoint) noexcept {
    return impl_ == nullptr ? CLSP_STATUS_RESOURCE_EXHAUSTED : impl_->start(endpoint);
  }

  clsp_status_t Runtime::stop() noexcept {
    return impl_ == nullptr ? CLSP_STATUS_RESOURCE_EXHAUSTED : impl_->stop();
  }

  clsp_status_t Runtime::send_control(
    const std::uint16_t message_type,
    const std::uint64_t request_id,
    const clsp_const_byte_span_t payload,
    const std::uint32_t deadline_milliseconds
  ) noexcept {
    return impl_ == nullptr ? CLSP_STATUS_RESOURCE_EXHAUSTED :
                              impl_->send_control(message_type, request_id, payload, deadline_milliseconds);
  }

  clsp_status_t Runtime::configure_input(const clsp_input_configuration_t &configuration) noexcept {
    return impl_ == nullptr ? CLSP_STATUS_RESOURCE_EXHAUSTED : impl_->configure_input(configuration);
  }

  clsp_status_t Runtime::submit_pointer(const clsp_pointer_sample_t &sample) noexcept {
    return impl_ == nullptr ? CLSP_STATUS_RESOURCE_EXHAUSTED : impl_->submit_pointer(sample);
  }

  clsp_status_t Runtime::submit_input_edge(const clsp_input_edge_t &edge) noexcept {
    return impl_ == nullptr ? CLSP_STATUS_RESOURCE_EXHAUSTED : impl_->submit_input_edge(edge);
  }

  clsp_status_t Runtime::submit_controller_edge(const clsp_controller_edge_t &edge) noexcept {
    return impl_ == nullptr ? CLSP_STATUS_RESOURCE_EXHAUSTED : impl_->submit_controller_edge(edge);
  }

  clsp_status_t Runtime::submit_controller_state(const clsp_controller_state_t &state) noexcept {
    return impl_ == nullptr ? CLSP_STATUS_RESOURCE_EXHAUSTED : impl_->submit_controller_state(state);
  }

  clsp_status_t Runtime::submit_controller_sensor(const clsp_controller_sensor_t &sensor) noexcept {
    return impl_ == nullptr ? CLSP_STATUS_RESOURCE_EXHAUSTED : impl_->submit_controller_sensor(sensor);
  }

  clsp_status_t Runtime::submit_controller_touch_edge(const clsp_controller_touch_edge_t &edge) noexcept {
    return impl_ == nullptr ? CLSP_STATUS_RESOURCE_EXHAUSTED : impl_->submit_controller_touch_edge(edge);
  }

  clsp_status_t Runtime::submit_controller_touch_state(const clsp_controller_touch_state_t &state) noexcept {
    return impl_ == nullptr ? CLSP_STATUS_RESOURCE_EXHAUSTED : impl_->submit_controller_touch_state(state);
  }

  clsp_status_t Runtime::neutralize_input() noexcept {
    return impl_ == nullptr ? CLSP_STATUS_RESOURCE_EXHAUSTED : impl_->neutralize_input();
  }
}  // namespace umbra::lsp
