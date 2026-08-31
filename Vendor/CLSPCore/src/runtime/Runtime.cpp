/**
 * @file Runtime.cpp
 * @brief Nonblocking UDP/kqueue worker with RFC 7983, DTLS, SRTP, and LSPC ownership.
 */

#include "Runtime.h"

#include "SecurityProviders.h"
#include "../core/control.h"

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
#endif

namespace umbra::lsp {
  namespace {
    constexpr std::size_t maximum_udp_payload = 1'472;  ///< LSP/1 standard-Ethernet IPv4 ceiling.
    constexpr std::size_t maximum_control_payload = 1'100;  ///< DTLS-safe deterministic-CBOR payload ceiling.
    constexpr std::size_t maximum_control_frame = lumen::lsp::lspc_header_size + maximum_control_payload;
    constexpr std::size_t receive_batch_size = 64;  ///< Initial bounded receive batch.
    constexpr std::size_t control_queue_capacity = 64;  ///< Bounded pre-wire control queue.

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

  private:
    /** @brief One bounded deterministic-CBOR request waiting for message-ID assignment. */
    struct ControlCommand {
      std::uint16_t message_type {};  ///< Semantic message type.
      std::uint64_t request_id {};  ///< Caller-generated request ID.
      std::uint64_t deadline_microseconds {};  ///< Absolute retry deadline.
      lumen::lsp::packet_slab<maximum_control_payload> payload {};  ///< Copied deterministic-CBOR payload.
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
            // Lane/SSRC registration remains native. Until negotiated, authenticated
            // packets are deliberately not surfaced to Swift or permitted side effects.
            increment(RuntimeCounter::dropped);
            break;
          }
          case PacketClass::invalid:
            increment(RuntimeCounter::dropped);
            break;
        }
      }
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
    std::atomic<bool> stop_requested_ {false};  ///< Cross-thread idempotent stop request.
    std::atomic<bool> authenticated_ {false};  ///< Product-visible exact-security readiness.
    std::size_t control_queue_head_ {};  ///< Next queued request to consume.
    std::size_t control_queue_tail_ {};  ///< Next free queue slot.
    std::size_t queued_control_count_ {};  ///< Occupied pre-wire queue slots.
    std::uint64_t next_message_id_ {1};  ///< Next nonzero client-to-host LSPC message ID.
    std::uint32_t connection_generation_ {};  ///< Zero through CLIENT_HELLO, then host-assigned generation.
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
}  // namespace umbra::lsp
