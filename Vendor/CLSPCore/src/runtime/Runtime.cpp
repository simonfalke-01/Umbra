/**
 * @file Runtime.cpp
 * @brief Nonblocking UDP/kqueue worker with RFC 7983, DTLS, SRTP, and LSPC ownership.
 */

#include "Runtime.h"
#include "../core/control.h"
#include "../core/rtp.h"
#include "../input_plane/input_plane.h"
#include "../media/media.h"
#include "../transport/rtcp.h"
#include "BufferInternal.h"
#include "SecurityProviders.h"

#include <algorithm>

#include <array>
#include <atomic>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <new>
#include <optional>
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
    constexpr std::size_t microphone_queue_capacity = 3;  ///< Two live packets plus one SPSC sentinel slot.
    constexpr std::size_t maximum_microphone_opus_bytes = 1'172;  ///< 1,200 minus RTP and SRTP tag.
    constexpr std::size_t video_delivery_queue_capacity =
      4;  ///< Maximum negotiated hardware submissions.
    constexpr std::size_t maximum_depacketized_video_bytes =
      4'096;  ///< Worst-case small-NAL aggregation expansion.
    constexpr std::array<std::uint8_t, 4> annex_b_start_code{
      0,
      0,
      0,
      1
    };  ///< Decoder-ready NAL prefix.

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

    /** @brief Saturating addition used for frame age deadlines. */
    [[nodiscard]] constexpr std::uint64_t
    saturating_add(const std::uint64_t left, const std::uint64_t right) noexcept {
      return left > std::numeric_limits<std::uint64_t>::max() - right ? std::numeric_limits<std::uint64_t>::max() : left + right;
    }

    /** @brief Parsed RFC8285 boundary metadata after RFC6904 decryption. */
    struct VideoExtensions {
      bool has_frame_marking{};                   ///< Whether one-byte frame marking was present.
      bool starts_frame{};                        ///< RFC9626 short start flag.
      bool ends_frame{};                          ///< RFC9626 short end flag.
      bool independent{};                         ///< RFC9626 short independent flag.
      bool has_frame_id{};                        ///< Whether repeated frame ID was present.
      bool has_capture_time{};                    ///< Whether absolute capture time was present.
      bool has_input_watermark{};                 ///< Whether applied-input watermark was present.
      bool has_encoder_timing{};                  ///< Whether encoder timing was present.
      std::uint64_t frame_id{};                   ///< Parsed nonzero repeated frame ID.
      std::uint64_t capture_time_microseconds{};  ///< NTP fixed-point absolute
                                                  ///< capture value in microseconds.
      std::uint64_t input_state_sequence{};       ///< Applied input state sequence.
      std::uint64_t input_edge_id{};              ///< Applied input edge identifier.
    };

    /** @brief Authenticated RTP payload and negotiated boundary metadata. */
    struct ParsedVideoPacket {
      lumen::lsp::rtp_fixed_header header{};  ///< Validated visible RTP header.
      VideoExtensions extensions{};           ///< Validated negotiated extensions.
      std::span<const std::uint8_t>
        payload{};  ///< Exact codec RTP payload without padding.
    };

    /** @brief Convert one unsigned 64-bit NTP fixed-point value to saturated
     * microseconds. */
    [[nodiscard]] constexpr std::uint64_t
    ntp_to_microseconds(const std::uint64_t value) noexcept {
      const auto seconds = value >> 32U;
      if (seconds > std::numeric_limits<std::uint64_t>::max() / 1'000'000U) {
        return std::numeric_limits<std::uint64_t>::max();
      }
      const auto fraction = static_cast<std::uint32_t>(value);
      return seconds * 1'000'000U +
             ((static_cast<std::uint64_t>(fraction) * 1'000'000U) >> 32U);
    }

    /** @brief Return whether the five negotiated RFC8285 IDs are unique values one
     * through fourteen. */
    [[nodiscard]] constexpr bool valid_video_extension_ids(
      const clsp_video_configuration_t &configuration
    ) noexcept {
      const std::array<std::uint8_t, 5> ids{
        configuration.frame_marking_extension,
        configuration.absolute_capture_extension,
        configuration.frame_id_extension,
        configuration.input_watermark_extension,
        configuration.encoder_timing_extension,
      };
      for (std::size_t index = 0; index < ids.size(); ++index) {
        if (ids[index] == 0 || ids[index] > 14U) {
          return false;
        }
        for (std::size_t other = index + 1; other < ids.size(); ++other) {
          if (ids[index] == ids[other]) {
            return false;
          }
        }
      }
      return true;
    }

    /** @brief Parse exact RFC8285 one-byte video extensions and locate the codec
     * payload. */
    [[nodiscard]] std::optional<ParsedVideoPacket>
    parse_video_packet(const std::span<const std::uint8_t> packet, const clsp_video_configuration_t &configuration) noexcept {
      const auto parsed = lumen::lsp::parse_rtp_fixed_header(packet);
      if (!parsed || parsed.header.csrc_count != 0 ||
          parsed.header.ssrc != configuration.primary_ssrc ||
          parsed.header.payload_type != configuration.primary_payload_type) {
        return std::nullopt;
      }
      auto payload_offset = parsed.bytes_consumed;
      VideoExtensions extensions;
      std::array<bool, 5> seen{};
      if (parsed.header.extension) {
        if (packet.size() < payload_offset + 4U ||
            lumen::lsp::wire::read_be<std::uint16_t>(
              packet.subspan(payload_offset, 2)
            ) != 0xbeDEU) {
          return std::nullopt;
        }
        const auto words = lumen::lsp::wire::read_be<std::uint16_t>(
          packet.subspan(payload_offset + 2U, 2)
        );
        const auto extension_bytes = static_cast<std::size_t>(words) * 4U;
        if (extension_bytes > packet.size() - payload_offset - 4U) {
          return std::nullopt;
        }
        auto encoded = packet.subspan(payload_offset + 4U, extension_bytes);
        std::size_t offset = 0;
        while (offset < encoded.size()) {
          const auto header = encoded[offset++];
          if (header == 0) {
            continue;
          }
          const auto id = static_cast<std::uint8_t>(header >> 4U);
          if (id == 15U) {
            return std::nullopt;
          }
          const auto length = static_cast<std::size_t>(header & 0x0fU) + 1U;
          if (length > encoded.size() - offset) {
            return std::nullopt;
          }
          const auto value = encoded.subspan(offset, length);
          offset += length;
          std::size_t field = 5;
          if (id == configuration.frame_marking_extension) {
            field = 0;
          } else if (id == configuration.absolute_capture_extension) {
            field = 1;
          } else if (id == configuration.frame_id_extension) {
            field = 2;
          } else if (id == configuration.input_watermark_extension) {
            field = 3;
          } else if (id == configuration.encoder_timing_extension) {
            field = 4;
          }
          if (field == 5 || seen[field]) {
            return std::nullopt;
          }
          seen[field] = true;
          switch (field) {
          case 0:
            if (length != 1U || (value[0] & 0x0fU) != 0) {
              return std::nullopt;
            }
            extensions.has_frame_marking = true;
            extensions.starts_frame = (value[0] & 0x80U) != 0;
            extensions.ends_frame = (value[0] & 0x40U) != 0;
            extensions.independent = (value[0] & 0x20U) != 0;
            break;
          case 1:
            if (length != 8U) {
              return std::nullopt;
            }
            extensions.has_capture_time = true;
            extensions.capture_time_microseconds = ntp_to_microseconds(
              lumen::lsp::wire::read_be<std::uint64_t>(value)
            );
            break;
          case 2:
            if (length != 8U) {
              return std::nullopt;
            }
            extensions.has_frame_id = true;
            extensions.frame_id = lumen::lsp::wire::read_be<std::uint64_t>(value);
            if (extensions.frame_id == 0) {
              return std::nullopt;
            }
            break;
          case 3:
            if (length != 16U) {
              return std::nullopt;
            }
            extensions.has_input_watermark = true;
            extensions.input_state_sequence =
              lumen::lsp::wire::read_be<std::uint64_t>(value.first(8));
            extensions.input_edge_id =
              lumen::lsp::wire::read_be<std::uint64_t>(value.subspan(8, 8));
            break;
          case 4:
            if (length != 8U) {
              return std::nullopt;
            }
            extensions.has_encoder_timing = true;
            break;
          default:
            return std::nullopt;
          }
        }
        payload_offset += 4U + extension_bytes;
      }
      auto payload_end = packet.size();
      if (parsed.header.padding) {
        if (payload_end <= payload_offset) {
          return std::nullopt;
        }
        const auto padding = static_cast<std::size_t>(packet.back());
        if (padding == 0 || padding > payload_end - payload_offset) {
          return std::nullopt;
        }
        payload_end -= padding;
      }
      if (payload_end <= payload_offset) {
        return std::nullopt;
      }
      return ParsedVideoPacket{
        .header = parsed.header,
        .extensions = extensions,
        .payload = packet.subspan(payload_offset, payload_end - payload_offset),
      };
    }

    /** @brief Validate one complete H.264 NAL unit carried inside an RTP payload.
     */
    [[nodiscard]] constexpr bool
    valid_h264_nal(const std::span<const std::uint8_t> nal) noexcept {
      if (nal.empty() || (nal.front() & 0x80U) != 0) {
        return false;
      }
      const auto type = static_cast<std::uint8_t>(nal.front() & 0x1fU);
      return type >= 1U && type <= 23U;
    }

    /** @brief Validate one complete HEVC NAL unit carried inside an RTP payload. */
    [[nodiscard]] constexpr bool
    valid_hevc_nal(const std::span<const std::uint8_t> nal) noexcept {
      if (nal.size() < 2U || (nal[0] & 0x80U) != 0 || (nal[1] & 0x07U) == 0) {
        return false;
      }
      return static_cast<std::uint8_t>((nal[0] >> 1U) & 0x3fU) <= 47U;
    }

    /** @brief Convert one H.264 RTP payload into its ordered Annex-B frame chunk.
     */
    [[nodiscard]] bool
    depacketize_h264(const std::span<const std::uint8_t> payload, lumen::lsp::packet_slab<maximum_depacketized_video_bytes> &output) noexcept {
      output.clear();
      if (payload.empty() || (payload[0] & 0x80U) != 0) {
        return false;
      }
      const auto type = static_cast<std::uint8_t>(payload[0] & 0x1fU);
      if (type >= 1U && type <= 23U) {
        return output.append(annex_b_start_code) && output.append(payload);
      }
      if (type == lumen::lsp::media::h264_stap_a_type) {
        std::size_t offset = 1;
        std::size_t units = 0;
        while (offset < payload.size()) {
          if (payload.size() - offset < 2U) {
            return false;
          }
          const auto length = static_cast<std::size_t>(
            lumen::lsp::wire::read_be<std::uint16_t>(payload.subspan(offset, 2))
          );
          offset += 2U;
          if (length == 0 || length > payload.size() - offset) {
            return false;
          }
          const auto nal = payload.subspan(offset, length);
          if (!valid_h264_nal(nal) || !output.append(annex_b_start_code) ||
              !output.append(nal)) {
            return false;
          }
          offset += length;
          ++units;
        }
        return units != 0;
      }
      if (type != lumen::lsp::media::h264_fu_a_type || payload.size() < 3U) {
        return false;
      }
      const auto fu = payload[1];
      const auto start = (fu & 0x80U) != 0;
      const auto end = (fu & 0x40U) != 0;
      const auto original_type = static_cast<std::uint8_t>(fu & 0x1fU);
      if ((fu & 0x20U) != 0 || (start && end) || original_type == 0 ||
          original_type > 23U) {
        return false;
      }
      if (start) {
        const std::array<std::uint8_t, 1> header{
          static_cast<std::uint8_t>((payload[0] & 0x60U) | original_type),
        };
        if (!output.append(annex_b_start_code) || !output.append(header)) {
          return false;
        }
      }
      return output.append(payload.subspan(2));
    }

    /** @brief Convert one HEVC RTP payload into its ordered Annex-B frame chunk. */
    [[nodiscard]] bool
    depacketize_hevc(const std::span<const std::uint8_t> payload, lumen::lsp::packet_slab<maximum_depacketized_video_bytes> &output) noexcept {
      output.clear();
      if (payload.size() < 2U || (payload[0] & 0x80U) != 0 ||
          (payload[1] & 0x07U) == 0) {
        return false;
      }
      const auto type = static_cast<std::uint8_t>((payload[0] >> 1U) & 0x3fU);
      if (type <= 47U) {
        return output.append(annex_b_start_code) && output.append(payload);
      }
      if (type == lumen::lsp::media::hevc_ap_type) {
        std::size_t offset = 2;
        std::size_t units = 0;
        while (offset < payload.size()) {
          if (payload.size() - offset < 2U) {
            return false;
          }
          const auto length = static_cast<std::size_t>(
            lumen::lsp::wire::read_be<std::uint16_t>(payload.subspan(offset, 2))
          );
          offset += 2U;
          if (length == 0 || length > payload.size() - offset) {
            return false;
          }
          const auto nal = payload.subspan(offset, length);
          if (!valid_hevc_nal(nal) || !output.append(annex_b_start_code) ||
              !output.append(nal)) {
            return false;
          }
          offset += length;
          ++units;
        }
        return units != 0;
      }
      if (type != lumen::lsp::media::hevc_fu_type || payload.size() < 4U) {
        return false;
      }
      const auto fu = payload[2];
      const auto start = (fu & 0x80U) != 0;
      const auto end = (fu & 0x40U) != 0;
      const auto original_type = static_cast<std::uint8_t>(fu & 0x3fU);
      if ((start && end) || original_type > 47U) {
        return false;
      }
      if (start) {
        const std::array<std::uint8_t, 2> header{
          static_cast<std::uint8_t>((payload[0] & 0x81U) | (original_type << 1U)),
          payload[1],
        };
        if (!output.append(annex_b_start_code) || !output.append(header)) {
          return false;
        }
      }
      return output.append(payload.subspan(3));
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
      release_video_state();
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
      microphone_active_.store(false, std::memory_order_release);
      microphone_prepared_.store(false, std::memory_order_release);
      request_stop();
      join_worker();
      release_video_state();
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
      command.flags = static_cast<std::uint8_t>(lumen::lsp::lspc_flag::acknowledgement_required);
      command.response = false;
      command.activate_microphone = false;
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

    [[nodiscard]] clsp_status_t send_control_response(
      const std::uint16_t message_type,
      const std::uint64_t request_id,
      const clsp_const_byte_span_t payload,
      const bool error_response,
      const std::uint32_t deadline_milliseconds
    ) noexcept {
#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      if (!authenticated_.load(std::memory_order_acquire)) return CLSP_STATUS_NOT_AUTHENTICATED;
      if (message_type == 0 || request_id == 0 || deadline_milliseconds < 20U || deadline_milliseconds > 30'000U ||
          payload.length > maximum_control_payload || (payload.data == nullptr && payload.length != 0)) {
        return CLSP_STATUS_INVALID_ARGUMENT;
      }
      pthread_mutex_lock(&mutex_);
      if (queued_control_count_ == control_queue_capacity) {
        pthread_mutex_unlock(&mutex_);
        return CLSP_STATUS_CONTROL_WINDOW_FULL;
      }
      auto &command = control_queue_[control_queue_tail_];
      command.message_type = message_type;
      command.request_id = request_id;
      command.flags = static_cast<std::uint8_t>(lumen::lsp::lspc_flag::acknowledgement_required) |
                      static_cast<std::uint8_t>(lumen::lsp::lspc_flag::response) |
                      (error_response ? static_cast<std::uint8_t>(lumen::lsp::lspc_flag::error_response) : 0U);
      command.response = true;
      command.activate_microphone = message_type == 0x0215U && !error_response;
      command.payload.assign(std::span<const std::uint8_t> {payload.data, payload.length});
      const auto now = monotonic_microseconds();
      const auto duration = static_cast<std::uint64_t>(deadline_milliseconds) * 1'000U;
      command.deadline_microseconds = now > std::numeric_limits<std::uint64_t>::max() - duration ?
                                         std::numeric_limits<std::uint64_t>::max() : now + duration;
      control_queue_tail_ = (control_queue_tail_ + 1U) % control_queue_capacity;
      ++queued_control_count_;
      pthread_mutex_unlock(&mutex_);
      wake_worker();
      return CLSP_STATUS_OK;
#else
      (void)message_type; (void)request_id; (void)payload; (void)error_response; (void)deadline_milliseconds;
      return CLSP_STATUS_UNSUPPORTED;
#endif
    }

    [[nodiscard]] clsp_status_t wait_control_response(
      const std::uint64_t request_id,
      const std::uint32_t timeout_milliseconds
    ) noexcept {
#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      if (request_id == 0 || timeout_milliseconds == 0 || timeout_milliseconds > 30'000U) {
        return CLSP_STATUS_INVALID_ARGUMENT;
      }
      timespec deadline {};
      if (clock_gettime(CLOCK_REALTIME, &deadline) != 0) return CLSP_STATUS_INTERNAL_FAILURE;
      const auto nanoseconds = static_cast<std::uint64_t>(timeout_milliseconds) * 1'000'000U;
      deadline.tv_sec += static_cast<time_t>(nanoseconds / 1'000'000'000U);
      deadline.tv_nsec += static_cast<long>(nanoseconds % 1'000'000'000U);
      if (deadline.tv_nsec >= 1'000'000'000L) { ++deadline.tv_sec; deadline.tv_nsec -= 1'000'000'000L; }
      pthread_mutex_lock(&mutex_);
      while (completed_response_request_.load(std::memory_order_acquire) != request_id) {
        const auto wait = pthread_cond_timedwait(&condition_, &mutex_, &deadline);
        if (wait == ETIMEDOUT) { pthread_mutex_unlock(&mutex_); return CLSP_STATUS_TIMEOUT; }
        if (wait != 0) { pthread_mutex_unlock(&mutex_); return CLSP_STATUS_INTERNAL_FAILURE; }
      }
      pthread_mutex_unlock(&mutex_);
      return CLSP_STATUS_OK;
#else
      (void)request_id; (void)timeout_milliseconds;
      return CLSP_STATUS_UNSUPPORTED;
#endif
    }

    [[nodiscard]] clsp_status_t configure_audio(const clsp_audio_configuration_t &configuration) noexcept {
#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      if (!authenticated_.load(std::memory_order_acquire)) return CLSP_STATUS_NOT_AUTHENTICATED;
      if (!valid_audio_configuration(configuration)) return CLSP_STATUS_INVALID_CONFIGURATION;
      if (audio_configured_.load(std::memory_order_acquire)) {
        return same_audio_configuration(audio_configuration_, configuration) ? CLSP_STATUS_OK : CLSP_STATUS_INVALID_STATE;
      }
      audio_configuration_ = configuration;
      audio_configured_.store(true, std::memory_order_release);
      return CLSP_STATUS_OK;
#else
      (void)configuration;
      return CLSP_STATUS_UNSUPPORTED;
#endif
    }

    [[nodiscard]] clsp_status_t configure_microphone(const clsp_microphone_configuration_t &configuration) noexcept {
#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      if (!authenticated_.load(std::memory_order_acquire)) return CLSP_STATUS_NOT_AUTHENTICATED;
      if (!valid_microphone_configuration(configuration)) return CLSP_STATUS_INVALID_CONFIGURATION;
      if (microphone_prepared_.load(std::memory_order_acquire)) {
        return same_microphone_configuration(microphone_configuration_, configuration) ? CLSP_STATUS_OK : CLSP_STATUS_INVALID_STATE;
      }
      microphone_configuration_ = configuration;
      microphone_read_.store(0, std::memory_order_release);
      microphone_write_.store(0, std::memory_order_release);
      microphone_sequence_ = static_cast<std::uint16_t>(arc4random());
      microphone_timestamp_ = arc4random();
      microphone_marker_.store(true, std::memory_order_release);
      microphone_packet_count_ = 0;
      microphone_octet_count_ = 0;
      microphone_last_report_us_ = 0;
      microphone_last_credit_us_ = monotonic_microseconds();
      const auto rate = microphone_pacing_rate(configuration);
      microphone_tokens_bits_ = microphone_credit_capacity(configuration);
      microphone_prepared_.store(true, std::memory_order_release);
      return CLSP_STATUS_OK;
#else
      (void)configuration;
      return CLSP_STATUS_UNSUPPORTED;
#endif
    }

    [[nodiscard]] clsp_status_t submit_microphone_packet(const clsp_const_byte_span_t packet) noexcept {
#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      if (!microphone_prepared_.load(std::memory_order_acquire)) return CLSP_STATUS_INVALID_STATE;
      if (packet.data == nullptr || packet.length == 0 || packet.length > maximum_microphone_opus_bytes) {
        return CLSP_STATUS_INVALID_ARGUMENT;
      }
      const auto write = microphone_write_.load(std::memory_order_relaxed);
      const auto next = (write + 1U) % microphone_queue_capacity;
      if (next == microphone_read_.load(std::memory_order_acquire)) {
        microphone_marker_.store(true, std::memory_order_release);
        return CLSP_STATUS_RESOURCE_EXHAUSTED;
      }
      microphone_queue_[write].assign(std::span<const std::uint8_t> {packet.data, packet.length});
      microphone_write_.store(next, std::memory_order_release);
      wake_worker();
      return CLSP_STATUS_OK;
#else
      (void)packet;
      return CLSP_STATUS_UNSUPPORTED;
#endif
    }

    [[nodiscard]] clsp_status_t mark_microphone_discontinuity() noexcept {
      if (!microphone_active_.load(std::memory_order_acquire)) return CLSP_STATUS_INVALID_STATE;
      microphone_marker_.store(true, std::memory_order_release);
      return CLSP_STATUS_OK;
    }

    [[nodiscard]] clsp_status_t stop_microphone() noexcept {
      microphone_active_.store(false, std::memory_order_release);
      microphone_prepared_.store(false, std::memory_order_release);
      microphone_read_.store(microphone_write_.load(std::memory_order_acquire), std::memory_order_release);
      return CLSP_STATUS_OK;
    }

    /** @brief Install one immutable video generation and all bounded
     * complete-frame storage. */
    [[nodiscard]] clsp_status_t
    configure_video(const clsp_video_configuration_t &configuration) noexcept {
#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      if (!authenticated_.load(std::memory_order_acquire)) {
        return CLSP_STATUS_NOT_AUTHENTICATED;
      }
      if (!valid_video_configuration(configuration)) {
        return CLSP_STATUS_INVALID_CONFIGURATION;
      }
      if (callbacks_.video_frame == nullptr) {
        return CLSP_STATUS_INVALID_STATE;
      }
      pthread_mutex_lock(&mutex_);
      if (video_configured_.load(std::memory_order_acquire)) {
        const auto same =
          same_video_configuration(video_configuration_, configuration);
        pthread_mutex_unlock(&mutex_);
        return same ? CLSP_STATUS_OK : CLSP_STATUS_INVALID_STATE;
      }
      auto *pool = create_retained_frame_pool(
        configuration.maximum_access_unit_bytes,
        static_cast<std::size_t>(configuration.decoder_surfaces) + 2U
      );
      if (pool == nullptr) {
        pthread_mutex_unlock(&mutex_);
        return CLSP_STATUS_RESOURCE_EXHAUSTED;
      }
      const std::array<int, 3> encrypted_extensions{
        configuration.frame_id_extension,
        configuration.input_watermark_extension,
        configuration.encoder_timing_extension,
      };
      const auto security_status = srtp_.configure_video_inbound(
        configuration.primary_ssrc,
        encrypted_extensions
      );
      if (security_status != CLSP_STATUS_OK) {
        release_retained_frame_pool(pool);
        pthread_mutex_unlock(&mutex_);
        return security_status;
      }
      if (!video_decoder_credit_.configure(configuration.decoder_surfaces)) {
        release_retained_frame_pool(pool);
        pthread_mutex_unlock(&mutex_);
        return CLSP_STATUS_INVALID_CONFIGURATION;
      }
      video_configuration_ = configuration;
      video_frame_pool_ = pool;
      video_reassembler_.emplace(configuration.maximum_access_unit_bytes);
      video_metadata_ = {};
      video_retired_frames_ = {};
      video_sequence_initialized_ = false;
      video_timestamp_initialized_ = false;
      video_largest_extended_sequence_ = 0;
      video_largest_extended_timestamp_ = 0;
      video_largest_complete_frame_id_ = 0;
      video_largest_decoded_frame_id_ = 0;
      video_largest_metal_frame_id_ = 0;
      video_next_metadata_order_ = 1;
      video_next_retirement_order_ = 1;
      video_render_mailbox_occupancy_ = 0;
      video_deadline_miss_latched_ = false;
      lspv_coalescer_ = {};
      video_configured_.store(true, std::memory_order_release);
      pthread_mutex_unlock(&mutex_);
      return CLSP_STATUS_OK;
#else
      (void)configuration;
      return CLSP_STATUS_UNSUPPORTED;
#endif
    }

    /** @brief Record one terminal hardware decode outcome for bounded credit and
     * LSPV. */
    [[nodiscard]] clsp_status_t report_video_decode(
      const std::uint32_t video_generation,
      const std::uint64_t frame_id,
      const std::uint32_t recovery_epoch,
      const std::uint8_t decoder_status,
      const std::uint8_t decoder_credit,
      const std::uint8_t render_mailbox_occupancy
    ) noexcept {
#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      if (!video_configured_.load(std::memory_order_acquire)) {
        return CLSP_STATUS_INVALID_STATE;
      }
      pthread_mutex_lock(&mutex_);
      if (!video_configured_.load(std::memory_order_acquire)) {
        pthread_mutex_unlock(&mutex_);
        return CLSP_STATUS_INVALID_STATE;
      }
      if (video_generation != video_configuration_.video_generation ||
          frame_id == 0 || frame_id > video_largest_complete_frame_id_ ||
          recovery_epoch != video_configuration_.recovery_epoch ||
          decoder_status > static_cast<std::uint8_t>(
                             lumen::lsp::transport::lspv_decoder_status::
                               unrecoverable_error
                           ) ||
          render_mailbox_occupancy > 1U ||
          video_decoder_credit_.in_flight() == 0 ||
          decoder_credit !=
            static_cast<std::uint8_t>(video_decoder_credit_.capacity() - video_decoder_credit_.in_flight() + 1U)) {
        pthread_mutex_unlock(&mutex_);
        return CLSP_STATUS_INVALID_ARGUMENT;
      }
      (void)video_decoder_credit_.release();
      video_render_mailbox_occupancy_ = render_mailbox_occupancy;
      const auto typed_status =
        static_cast<lumen::lsp::transport::lspv_decoder_status>(decoder_status);
      if (typed_status == lumen::lsp::transport::lspv_decoder_status::ready) {
        video_largest_decoded_frame_id_ =
          std::max(video_largest_decoded_frame_id_, frame_id);
      }
      const auto status = current_lspv_status(typed_status);
      const auto update = lspv_coalescer_.update(
        status,
        lumen::lsp::transport::lspv_event::decode_completion
      );
      pthread_mutex_unlock(&mutex_);
      if (update != lumen::lsp::transport::lspv_update_result::accepted) {
        return CLSP_STATUS_INTERNAL_FAILURE;
      }
      wake_worker();
      return CLSP_STATUS_OK;
#else
      (void)video_generation;
      (void)frame_id;
      (void)recovery_epoch;
      (void)decoder_status;
      (void)decoder_credit;
      (void)render_mailbox_occupancy;
      return CLSP_STATUS_UNSUPPORTED;
#endif
    }

    /** @brief Advance the latest committed-frame watermark and coalesce protected
     * LSPV. */
    [[nodiscard]] clsp_status_t
    report_video_commit(const std::uint32_t video_generation, const std::uint64_t frame_id, const std::uint8_t render_mailbox_occupancy) noexcept {
#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      if (!video_configured_.load(std::memory_order_acquire)) {
        return CLSP_STATUS_INVALID_STATE;
      }
      pthread_mutex_lock(&mutex_);
      if (!video_configured_.load(std::memory_order_acquire)) {
        pthread_mutex_unlock(&mutex_);
        return CLSP_STATUS_INVALID_STATE;
      }
      if (video_generation != video_configuration_.video_generation ||
          frame_id == 0 || frame_id > video_largest_decoded_frame_id_ ||
          render_mailbox_occupancy > 1U) {
        pthread_mutex_unlock(&mutex_);
        return CLSP_STATUS_INVALID_ARGUMENT;
      }
      video_largest_metal_frame_id_ =
        std::max(video_largest_metal_frame_id_, frame_id);
      video_render_mailbox_occupancy_ = render_mailbox_occupancy;
      const auto decoder_status =
        video_decoder_credit_.available() == 0 ? lumen::lsp::transport::lspv_decoder_status::surface_exhausted : lumen::lsp::transport::lspv_decoder_status::ready;
      const auto update = lspv_coalescer_.update(
        current_lspv_status(decoder_status),
        lumen::lsp::transport::lspv_event::capacity_transition
      );
      pthread_mutex_unlock(&mutex_);
      if (update != lumen::lsp::transport::lspv_update_result::accepted) {
        return CLSP_STATUS_INTERNAL_FAILURE;
      }
      wake_worker();
      return CLSP_STATUS_OK;
#else
      (void)video_generation;
      (void)frame_id;
      (void)render_mailbox_occupancy;
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
      const auto token = input_configuration_requested_.fetch_add(1, std::memory_order_acq_rel) + 1U;
      pending_input_configuration_token_ = token;
      input_configuration_pending_ = true;
      pthread_mutex_unlock(&mutex_);
      wake_worker();
      timespec deadline {};
      if (clock_gettime(CLOCK_REALTIME, &deadline) != 0) return CLSP_STATUS_INTERNAL_FAILURE;
      deadline.tv_nsec += 100'000'000L;
      if (deadline.tv_nsec >= 1'000'000'000L) { ++deadline.tv_sec; deadline.tv_nsec -= 1'000'000'000L; }
      pthread_mutex_lock(&mutex_);
      while (input_configuration_completed_.load(std::memory_order_acquire) < token) {
        const auto wait = pthread_cond_timedwait(&condition_, &mutex_, &deadline);
        if (wait == ETIMEDOUT) { pthread_mutex_unlock(&mutex_); return CLSP_STATUS_TIMEOUT; }
        if (wait != 0) { pthread_mutex_unlock(&mutex_); return CLSP_STATUS_INTERNAL_FAILURE; }
      }
      pthread_mutex_unlock(&mutex_);
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
      const auto token = neutralize_requested_.fetch_add(1, std::memory_order_acq_rel) + 1U;
      CaptureRecord record {.kind = CaptureKind::neutralize, .neutralize_token = token};
      const auto queued = enqueue_capture(record);
      if (queued != CLSP_STATUS_OK) return queued;
      timespec deadline {};
      if (clock_gettime(CLOCK_REALTIME, &deadline) != 0) return CLSP_STATUS_INTERNAL_FAILURE;
      deadline.tv_nsec += 100'000'000L;
      if (deadline.tv_nsec >= 1'000'000'000L) { ++deadline.tv_sec; deadline.tv_nsec -= 1'000'000'000L; }
      pthread_mutex_lock(&mutex_);
      while (neutralize_completed_.load(std::memory_order_acquire) < token) {
        const auto wait = pthread_cond_timedwait(&condition_, &mutex_, &deadline);
        if (wait == ETIMEDOUT) { pthread_mutex_unlock(&mutex_); return CLSP_STATUS_TIMEOUT; }
        if (wait != 0) { pthread_mutex_unlock(&mutex_); return CLSP_STATUS_INTERNAL_FAILURE; }
      }
      pthread_mutex_unlock(&mutex_);
      return CLSP_STATUS_OK;
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
      std::uint8_t flags {};  ///< Exact LSPC request/response/error flags.
      bool response {};  ///< Whether response cache insertion is required.
      bool activate_microphone {};  ///< Enable prepared microphone only after ACK submission.
    };

    /** @brief One retained authenticated host request awaiting a semantic response. */
    struct PendingInboundRequest {
      std::uint64_t request_id {};  ///< Nonzero host request ID.
      lumen::lsp::packet_slab<maximum_control_frame> frame {};  ///< Exact original LSPC bytes.
      bool occupied {};  ///< Whether this slot is live.
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
      std::uint64_t neutralize_token {};  ///< Synchronous quiesce completion token.
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

    /** @brief Boundary metadata retained for either of the two incomplete video frames. */
    struct VideoFrameMetadata {
      bool occupied {};  ///< Whether this slot tracks a provisional RTP frame.
      lumen::lsp::media::frame_key key {};  ///< SSRC plus extended timestamp key.
      std::uint64_t deadline_microseconds {};  ///< Fixed deadline shared by every fragment.
      std::uint64_t arrival_order {};  ///< Oldest-frame bounded eviction order.
      std::uint64_t frame_id {};  ///< Repeated nonzero frame identifier when observed.
      std::uint64_t capture_time_microseconds {};  ///< Repeated absolute capture time when observed.
      std::uint64_t input_state_sequence {};  ///< Repeated applied state watermark.
      std::uint64_t input_edge_id {};  ///< Repeated applied edge watermark.
      bool has_capture_time {};  ///< Whether capture time has been bound.
      bool has_input_watermark {};  ///< Whether the input watermark has been bound.
      bool has_independent_marking {};  ///< Whether independence metadata has been bound.
      bool independent {};  ///< Whether any repeated frame marking says independent.
    };

    /** @brief Recently retired frame key preventing late-packet resurrection. */
    struct VideoRetiredFrame {
      bool occupied {};  ///< Whether a key is retained.
      lumen::lsp::media::frame_key key {};  ///< Completed, expired, or evicted frame key.
      std::uint64_t retirement_order {};  ///< Bounded oldest-key replacement order.
    };

    /** @brief Increment one C ABI telemetry counter. */
    void increment(const RuntimeCounter counter, const std::uint64_t amount = 1) const noexcept {
      if (callbacks_.counter != nullptr) {
        callbacks_.counter(callbacks_.context, static_cast<std::uint32_t>(counter), amount);
      }
    }

    /** @brief Validate the exact complete-access-unit SDR H.264/HEVC generation
     * mapping. */
    [[nodiscard]] static bool
    valid_video_configuration(const clsp_video_configuration_t &value) noexcept {
      return value.abi_version == CLSP_CORE_ABI_VERSION &&
             value.structure_size == sizeof(clsp_video_configuration_t) &&
             value.stream_generation != 0 && value.video_generation != 0 &&
             value.primary_ssrc != 0 && value.clock_rate == 90'000U &&
             value.width != 0 && value.height != 0 &&
             value.refresh_numerator != 0 && value.refresh_denominator != 0 &&
             value.bitrate != 0 && value.maximum_access_unit_bytes != 0 &&
             value.maximum_access_unit_bytes <=
               lumen::lsp::media::absolute_frame_size_limit &&
             value.maximum_frame_age_microseconds != 0 &&
             value.frame_id_origin != 0 && value.recovery_epoch != 0 &&
             value.udp_payload_size == 1'200U &&
             value.primary_payload_type >= 96U &&
             value.primary_payload_type <= 127U &&
             ((value.codec == 1U && value.profile == 1U) ||
              (value.codec == 2U && value.profile == 2U)) &&
             value.decoder_surfaces >= 2U && value.decoder_surfaces <= 4U &&
             valid_video_extension_ids(value);
    }

    /** @brief Compare every immutable native video generation field for
     * idempotent admission. */
    [[nodiscard]] static bool
    same_video_configuration(const clsp_video_configuration_t &left, const clsp_video_configuration_t &right) noexcept {
      return left.stream_generation == right.stream_generation &&
             left.video_generation == right.video_generation &&
             left.primary_ssrc == right.primary_ssrc &&
             left.clock_rate == right.clock_rate && left.width == right.width &&
             left.height == right.height &&
             left.refresh_numerator == right.refresh_numerator &&
             left.refresh_denominator == right.refresh_denominator &&
             left.bitrate == right.bitrate &&
             left.maximum_access_unit_bytes == right.maximum_access_unit_bytes &&
             left.maximum_frame_age_microseconds ==
               right.maximum_frame_age_microseconds &&
             left.frame_id_origin == right.frame_id_origin &&
             left.recovery_epoch == right.recovery_epoch &&
             left.udp_payload_size == right.udp_payload_size &&
             left.primary_payload_type == right.primary_payload_type &&
             left.codec == right.codec && left.profile == right.profile &&
             left.decoder_surfaces == right.decoder_surfaces &&
             left.frame_marking_extension == right.frame_marking_extension &&
             left.absolute_capture_extension ==
               right.absolute_capture_extension &&
             left.frame_id_extension == right.frame_id_extension &&
             left.input_watermark_extension == right.input_watermark_extension &&
             left.encoder_timing_extension == right.encoder_timing_extension;
    }

    /** @brief Snapshot current bounded decoder/render state for protected LSPV.
     */
    [[nodiscard]] lumen::lsp::transport::lspv_status current_lspv_status(
      const lumen::lsp::transport::lspv_decoder_status decoder_status
    ) const noexcept {
      return {
        .session_generation = video_configuration_.stream_generation,
        .video_generation = video_configuration_.video_generation,
        .recovery_epoch = video_configuration_.recovery_epoch,
        .largest_complete_frame_id = video_largest_complete_frame_id_,
        .largest_decoded_frame_id = video_largest_decoded_frame_id_,
        .largest_metal_committed_frame_id = video_largest_metal_frame_id_,
        .deadline_miss = video_deadline_miss_latched_,
        .decoder_status = decoder_status,
        .decode_submissions_in_flight = video_decoder_credit_.in_flight(),
        .maximum_decode_submissions = video_decoder_credit_.capacity(),
        .render_mailbox_occupancy = video_render_mailbox_occupancy_,
      };
    }

    /** @brief Release runtime-owned video storage after the socket worker is
     * quiescent. */
    void release_video_state() noexcept {
      video_configured_.store(false, std::memory_order_release);
#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      if (mutex_ready_) {
        pthread_mutex_lock(&mutex_);
      }
#endif
      for (std::size_t index = 0; index < pending_video_delivery_count_;
           ++index) {
        clsp_buffer_release(pending_video_deliveries_[index].frame);
        pending_video_deliveries_[index] = {};
      }
      pending_video_delivery_count_ = 0;
      video_reassembler_.reset();
      video_metadata_ = {};
      video_retired_frames_ = {};
      auto *pool = video_frame_pool_;
      video_frame_pool_ = nullptr;
#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      if (mutex_ready_) {
        pthread_mutex_unlock(&mutex_);
      }
#endif
      release_retained_frame_pool(pool);
    }

    /** @brief Validate one exact host-audio tuple before native admission. */
    [[nodiscard]] static bool valid_audio_configuration(const clsp_audio_configuration_t &value) noexcept {
      if (value.abi_version != CLSP_CORE_ABI_VERSION || value.structure_size != sizeof(clsp_audio_configuration_t) ||
          value.stream_generation == 0 || value.audio_generation == 0 || value.audio_ssrc == 0 ||
          value.clock_rate != 48'000U || value.audio_payload_type < 96U || value.audio_payload_type > 127U ||
          (value.channels != 2U && value.channels != 6U && value.channels != 8U) || value.mapping_length != value.channels ||
          value.streams == 0 || value.coupled_streams > value.streams ||
          static_cast<unsigned>(value.streams) + value.coupled_streams != value.channels ||
          (value.frame_samples != 120U && value.frame_samples != 240U && value.frame_samples != 480U && value.frame_samples != 960U) ||
          value.bitrate < 6'000U || value.bitrate > 2'048'000U || value.inband_fec > 1U || value.dtx > 1U ||
          value.udp_payload_size < 1'200U || value.udp_payload_size > maximum_udp_payload || value.preroll_packets != 1U) {
        return false;
      }
      const auto coded_channels = static_cast<unsigned>(value.streams) + value.coupled_streams;
      for (std::size_t index = 0; index < value.mapping_length; ++index) {
        if (value.mapping[index] >= coded_channels) return false;
      }
      return true;
    }

    /** @brief Compare every wire-significant native audio mapping field. */
    [[nodiscard]] static bool same_audio_configuration(
      const clsp_audio_configuration_t &left,
      const clsp_audio_configuration_t &right
    ) noexcept {
      return left.stream_generation == right.stream_generation && left.audio_generation == right.audio_generation &&
             left.audio_ssrc == right.audio_ssrc && left.clock_rate == right.clock_rate && left.bitrate == right.bitrate &&
             left.frame_samples == right.frame_samples && left.udp_payload_size == right.udp_payload_size &&
             left.audio_payload_type == right.audio_payload_type && left.channels == right.channels &&
             left.streams == right.streams && left.coupled_streams == right.coupled_streams &&
             left.mapping_length == right.mapping_length && left.inband_fec == right.inband_fec && left.dtx == right.dtx &&
             left.preroll_packets == right.preroll_packets &&
             std::equal(left.mapping, left.mapping + left.mapping_length, right.mapping);
    }

    [[nodiscard]] static bool valid_microphone_configuration(
      const clsp_microphone_configuration_t &value
    ) noexcept {
      return value.abi_version == CLSP_CORE_ABI_VERSION &&
             value.structure_size == sizeof(clsp_microphone_configuration_t) &&
             value.stream_generation != 0 && value.microphone_generation != 0 && value.microphone_ssrc != 0 &&
             value.clock_rate == 48'000U && value.bitrate >= 6'000U && value.bitrate <= 128'000U &&
             value.frame_samples == 960U && value.udp_payload_size == 1'200U &&
             value.microphone_payload_type >= 96U && value.microphone_payload_type <= 127U &&
             value.channels == 1U && value.inband_fec <= 1U && value.dtx <= 1U;
    }

    [[nodiscard]] static bool same_microphone_configuration(
      const clsp_microphone_configuration_t &left,
      const clsp_microphone_configuration_t &right
    ) noexcept {
      return left.stream_generation == right.stream_generation &&
             left.microphone_generation == right.microphone_generation &&
             left.microphone_ssrc == right.microphone_ssrc && left.clock_rate == right.clock_rate &&
             left.bitrate == right.bitrate && left.frame_samples == right.frame_samples &&
             left.udp_payload_size == right.udp_payload_size &&
             left.microphone_payload_type == right.microphone_payload_type && left.channels == right.channels &&
             left.inband_fec == right.inband_fec && left.dtx == right.dtx;
    }

    [[nodiscard]] static std::uint64_t microphone_pacing_rate(
      const clsp_microphone_configuration_t &value
    ) noexcept {
      return std::max<std::uint64_t>(64'000U, static_cast<std::uint64_t>(value.bitrate) * 3U / 2U);
    }

    [[nodiscard]] static std::uint64_t microphone_credit_capacity(
      const clsp_microphone_configuration_t &value
    ) noexcept {
      const auto two_frame_quanta = microphone_pacing_rate(value) / 25U;
      const auto two_path_packets = static_cast<std::uint64_t>(value.udp_payload_size + 28U) * 8U * 2U;
      return std::max(two_frame_quanta, two_path_packets);
    }

    /** @brief Retain one exact host request until Swift installs and responds. */
    [[nodiscard]] bool retain_inbound_request(
      const std::uint64_t request_id,
      const std::span<const std::uint8_t> frame
    ) noexcept {
      PendingInboundRequest *free_slot = nullptr;
      for (auto &entry : pending_inbound_requests_) {
        if (entry.occupied && entry.request_id == request_id) {
          return entry.frame.bytes().size() == frame.size() &&
                 std::equal(entry.frame.bytes().begin(), entry.frame.bytes().end(), frame.begin());
        }
        if (!entry.occupied && free_slot == nullptr) free_slot = &entry;
      }
      if (free_slot == nullptr) return false;
      free_slot->request_id = request_id;
      free_slot->frame.assign(frame);
      free_slot->occupied = true;
      return true;
    }

    /** @brief Find one retained exact host request by request ID. */
    [[nodiscard]] PendingInboundRequest *pending_inbound_request(const std::uint64_t request_id) noexcept {
      for (auto &entry : pending_inbound_requests_) {
        if (entry.occupied && entry.request_id == request_id) return &entry;
      }
      return nullptr;
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
        deliver_video_frames();
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
        status = transmit_microphone();
        if (status != CLSP_STATUS_OK) {
          fail_worker(status);
          return;
        }
        if (video_configured_.load(std::memory_order_acquire)) {
          expire_video_frames(monotonic_microseconds());
        }
        status = transmit_lspv();
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
            const auto rtcp = is_rtcp(datagram);
            const auto visible_ssrc =
            rtcp && datagram.size() >= 8U ? lumen::lsp::wire::read_be<std::uint32_t>(
                                              datagram.subspan(4, 4)
                                            )
                                          : (!rtcp && datagram.size() >= 12U ? lumen::lsp::wire::read_be<std::uint32_t>(
                                                                                 datagram.subspan(8, 4)
                                                                               )
                                                                             : 0U);
          const auto use_video_context =
            video_configured_.load(std::memory_order_acquire) &&
            visible_ssrc == video_configuration_.primary_ssrc;
          const auto status =
            use_video_context ? srtp_.unprotect_video(packet, packet_length, rtcp) : srtp_.unprotect(packet, packet_length, rtcp);
            if (status != CLSP_STATUS_OK) {
              increment(RuntimeCounter::authentication_failure);
              break;
            }
            increment(RuntimeCounter::received);
            if (!handle_authenticated_realtime(std::span<const std::uint8_t> {packet.data(), packet_length}, rtcp)) {
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
      std::uint64_t token = 0;
      pthread_mutex_lock(&mutex_);
      if (!input_configuration_pending_) {
        pthread_mutex_unlock(&mutex_);
        return CLSP_STATUS_OK;
      }
      selected = pending_input_configuration_;
      token = pending_input_configuration_token_;
      input_configuration_pending_ = false;
      pthread_mutex_unlock(&mutex_);

      const auto restoring_same_mapping = input_configured_ &&
                                          input_configuration_.input_generation == selected.input_generation &&
                                          input_configuration_.input_ssrc == selected.input_ssrc &&
                                          input_configuration_.acknowledgement_ssrc == selected.acknowledgement_ssrc &&
                                          input_configuration_.input_payload_type == selected.input_payload_type;
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
      if (!restoring_same_mapping) {
        rtp_sequence_ = static_cast<std::uint16_t>(arc4random());
      }
      input_tokens_bits_ = selected.reserved_input_wire_bits_per_second / 500U;
      input_last_credit_us_ = monotonic_microseconds();
      last_pointer_sent_us_ = 0;
      input_configuration_completed_.store(token, std::memory_order_release);
      pthread_mutex_lock(&mutex_);
      pthread_cond_broadcast(&condition_);
      pthread_mutex_unlock(&mutex_);
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
          neutralize_completed_.store(record.neutralize_token, std::memory_order_release);
          pthread_mutex_lock(&mutex_);
          pthread_cond_broadcast(&condition_);
          pthread_mutex_unlock(&mutex_);
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

    /** @brief Pace, protect, and submit at most one complete microphone Opus packet. */
    [[nodiscard]] clsp_status_t transmit_microphone() noexcept {
#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      if (!microphone_active_.load(std::memory_order_acquire)) return CLSP_STATUS_OK;
      const auto now = monotonic_microseconds();
      replenish_microphone_credit(now);
      const auto read = microphone_read_.load(std::memory_order_relaxed);
      if (read != microphone_write_.load(std::memory_order_acquire)) {
        const auto opus = microphone_queue_[read].bytes();
        const auto charged = static_cast<std::uint64_t>(12U + opus.size() + 16U + 28U) * 8U;
        if (charged <= microphone_tokens_bits_) {
          std::array<std::uint8_t, maximum_udp_payload> packet {};
          const lumen::lsp::rtp_fixed_header header {
            .marker = microphone_marker_.load(std::memory_order_acquire),
            .payload_type = microphone_configuration_.microphone_payload_type,
            .sequence_number = microphone_sequence_,
            .timestamp = microphone_timestamp_,
            .ssrc = microphone_configuration_.microphone_ssrc,
          };
          const auto written = lumen::lsp::write_rtp_fixed_header(header, {}, packet);
          if (!written || written.bytes_written + opus.size() + 16U > microphone_configuration_.udp_payload_size) {
            return CLSP_STATUS_INVALID_CONFIGURATION;
          }
          std::copy(opus.begin(), opus.end(), packet.begin() + static_cast<std::ptrdiff_t>(written.bytes_written));
          auto length = written.bytes_written + opus.size();
          const auto protected_status = srtp_.protect(packet, length, false);
          if (protected_status != CLSP_STATUS_OK) return protected_status;
          ++microphone_sequence_;
          const auto sent = ::send(socket_, packet.data(), length, 0);
          if (sent == static_cast<ssize_t>(length)) {
            microphone_tokens_bits_ -= charged;
            microphone_marker_.store(false, std::memory_order_release);
            microphone_timestamp_ += 960U;
            ++microphone_packet_count_;
            microphone_octet_count_ += static_cast<std::uint32_t>(opus.size());
            microphone_queue_[read].clear();
            microphone_read_.store((read + 1U) % microphone_queue_capacity, std::memory_order_release);
            increment(RuntimeCounter::transmitted);
          } else if (sent < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
            return CLSP_STATUS_SOCKET_FAILURE;
          }
        }
      }
      if (microphone_packet_count_ != 0 &&
          (microphone_last_report_us_ == 0 || now - microphone_last_report_us_ >= 1'000'000U)) {
        return send_microphone_report(now);
      }
      return CLSP_STATUS_OK;
#else
      return CLSP_STATUS_UNSUPPORTED;
#endif
    }

    /** @brief Refill the reverse-microphone pacer below the dedicated input lane. */
    void replenish_microphone_credit(const std::uint64_t now) noexcept {
      if (now < microphone_last_credit_us_) { microphone_last_credit_us_ = now; return; }
      const auto rate = microphone_pacing_rate(microphone_configuration_);
      const auto elapsed = now - microphone_last_credit_us_;
      const auto earned = elapsed > std::numeric_limits<std::uint64_t>::max() / rate ?
                            std::numeric_limits<std::uint64_t>::max() : elapsed * rate / 1'000'000U;
      const auto capacity = microphone_credit_capacity(microphone_configuration_);
      microphone_tokens_bits_ = earned >= capacity || microphone_tokens_bits_ >= capacity - earned ?
                                  capacity : microphone_tokens_bits_ + earned;
      microphone_last_credit_us_ = now;
    }

    /** @brief Emit one protected RTCP sender report for the microphone timeline. */
    [[nodiscard]] clsp_status_t send_microphone_report(const std::uint64_t now) noexcept {
      std::array<std::uint8_t, 64> packet {};
      packet[0] = 0x80;
      packet[1] = 200;
      lumen::lsp::wire::write_be<std::uint16_t>(std::span<std::uint8_t> {packet}.subspan(2, 2), 6);
      lumen::lsp::wire::write_be<std::uint32_t>(std::span<std::uint8_t> {packet}.subspan(4, 4), microphone_configuration_.microphone_ssrc);
      timespec realtime {};
      if (clock_gettime(CLOCK_REALTIME, &realtime) != 0 || realtime.tv_sec < 0 || realtime.tv_nsec < 0) {
        return CLSP_STATUS_INTERNAL_FAILURE;
      }
      constexpr std::uint64_t ntp_epoch_offset = 2'208'988'800ULL;
      const auto ntp_seconds = static_cast<std::uint64_t>(realtime.tv_sec) + ntp_epoch_offset;
      const auto ntp_fraction = static_cast<std::uint64_t>(realtime.tv_nsec) * (std::uint64_t {1} << 32U) / 1'000'000'000ULL;
      lumen::lsp::wire::write_be<std::uint32_t>(std::span<std::uint8_t> {packet}.subspan(8, 4), static_cast<std::uint32_t>(ntp_seconds));
      lumen::lsp::wire::write_be<std::uint32_t>(std::span<std::uint8_t> {packet}.subspan(12, 4), static_cast<std::uint32_t>(ntp_fraction));
      lumen::lsp::wire::write_be<std::uint32_t>(std::span<std::uint8_t> {packet}.subspan(16, 4), microphone_timestamp_ - 960U);
      lumen::lsp::wire::write_be<std::uint32_t>(std::span<std::uint8_t> {packet}.subspan(20, 4), microphone_packet_count_);
      lumen::lsp::wire::write_be<std::uint32_t>(std::span<std::uint8_t> {packet}.subspan(24, 4), microphone_octet_count_);
      auto length = std::size_t {28};
      const auto status = srtp_.protect(packet, length, true);
      if (status != CLSP_STATUS_OK) return status;
      const auto sent = ::send(socket_, packet.data(), length, 0);
      if (sent != static_cast<ssize_t>(length)) {
        return sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) ? CLSP_STATUS_OK : CLSP_STATUS_SOCKET_FAILURE;
      }
      microphone_last_report_us_ = now;
      increment(RuntimeCounter::transmitted);
      return CLSP_STATUS_OK;
    }

    /** @brief Extend a 16-bit RTP sequence into the nearest generation around the
     * largest value. */
    [[nodiscard]] std::uint64_t
    extend_video_sequence(const std::uint16_t sequence) noexcept {
      if (!video_sequence_initialized_) {
        video_sequence_initialized_ = true;
        video_largest_extended_sequence_ = sequence;
        return sequence;
      }
      constexpr std::uint64_t modulus = std::uint64_t{1} << 16U;
      constexpr std::uint64_t half = modulus / 2U;
      auto candidate =
        (video_largest_extended_sequence_ & ~(modulus - 1U)) | sequence;
      if (candidate + half < video_largest_extended_sequence_) {
        candidate += modulus;
      } else if (candidate > video_largest_extended_sequence_ + half &&
                 candidate >= modulus) {
        candidate -= modulus;
      }
      video_largest_extended_sequence_ =
        std::max(video_largest_extended_sequence_, candidate);
      return candidate;
    }

    /** @brief Extend a 32-bit RTP timestamp into the nearest generation around
     * the largest value. */
    [[nodiscard]] std::uint64_t
    extend_video_timestamp(const std::uint32_t timestamp) noexcept {
      if (!video_timestamp_initialized_) {
        video_timestamp_initialized_ = true;
        video_largest_extended_timestamp_ = timestamp;
        return timestamp;
      }
      constexpr std::uint64_t modulus = std::uint64_t{1} << 32U;
      constexpr std::uint64_t half = modulus / 2U;
      auto candidate =
        (video_largest_extended_timestamp_ & ~(modulus - 1U)) | timestamp;
      if (candidate + half < video_largest_extended_timestamp_) {
        candidate += modulus;
      } else if (candidate > video_largest_extended_timestamp_ + half &&
                 candidate >= modulus) {
        candidate -= modulus;
      }
      video_largest_extended_timestamp_ =
        std::max(video_largest_extended_timestamp_, candidate);
      return candidate;
    }

    /** @brief Return whether a completed, expired, or evicted key must reject
     * late packets. */
    [[nodiscard]] bool
    video_frame_retired(const lumen::lsp::media::frame_key key) const noexcept {
      return std::ranges::any_of(video_retired_frames_, [&](const VideoRetiredFrame &entry) {
        return entry.occupied && entry.key == key;
      });
    }

    /** @brief Retain one recently retired key in a fixed-size late-packet fence.
     */
    void retire_video_frame(const lumen::lsp::media::frame_key key) noexcept {
      if (video_frame_retired(key)) {
        return;
      }
      auto *selected = static_cast<VideoRetiredFrame *>(nullptr);
      for (auto &entry : video_retired_frames_) {
        if (!entry.occupied) {
          selected = &entry;
          break;
        }
      }
      if (selected == nullptr) {
        selected = &*std::ranges::min_element(
          video_retired_frames_,
          {},
          &VideoRetiredFrame::retirement_order
        );
      }
      *selected = {
        .occupied = true,
        .key = key,
        .retirement_order = video_next_retirement_order_++,
      };
    }

    /** @brief Coalesce one decoder/capacity transition, preserving deadline
     * misses until submission. */
    void coalesce_video_status(
      const lumen::lsp::transport::lspv_decoder_status decoder_status,
      const lumen::lsp::transport::lspv_event event,
      const bool deadline_miss
    ) noexcept {
      pthread_mutex_lock(&mutex_);
      video_deadline_miss_latched_ =
        video_deadline_miss_latched_ || deadline_miss;
      const auto update =
        lspv_coalescer_.update(current_lspv_status(decoder_status), event);
      pthread_mutex_unlock(&mutex_);
      if (update == lumen::lsp::transport::lspv_update_result::accepted) {
        wake_worker();
      }
    }

    /** @brief Coalesce current derived hardware-credit state without racing
     * decoder callbacks. */
    void
    coalesce_video_capacity_status(const lumen::lsp::transport::lspv_event event, const bool deadline_miss) noexcept {
      pthread_mutex_lock(&mutex_);
      video_deadline_miss_latched_ =
        video_deadline_miss_latched_ || deadline_miss;
      const auto status =
        video_decoder_credit_.available() == 0 ? lumen::lsp::transport::lspv_decoder_status::surface_exhausted : lumen::lsp::transport::lspv_decoder_status::ready;
      const auto update =
        lspv_coalescer_.update(current_lspv_status(status), event);
      pthread_mutex_unlock(&mutex_);
      if (update == lumen::lsp::transport::lspv_update_result::accepted) {
        wake_worker();
      }
    }

    /** @brief Expire incomplete frames, retire their keys, and report an LSPV
     * deadline miss. */
    void expire_video_frames(const std::uint64_t now) noexcept {
      if (!video_reassembler_) {
        return;
      }
      std::size_t expired = 0;
      for (auto &metadata : video_metadata_) {
        if (metadata.occupied && metadata.deadline_microseconds <= now) {
          retire_video_frame(metadata.key);
          metadata = {};
          ++expired;
        }
      }
      (void)video_reassembler_->expire(now);
      if (expired != 0) {
        coalesce_video_capacity_status(
          lumen::lsp::transport::lspv_event::capacity_transition,
          true
        );
      }
    }

    /** @brief Find or create bounded metadata for one provisional video frame. */
    [[nodiscard]] VideoFrameMetadata *
    video_metadata_for(const lumen::lsp::media::frame_key key, const std::uint64_t now) noexcept {
      for (auto &metadata : video_metadata_) {
        if (metadata.occupied && metadata.key == key) {
          return &metadata;
        }
      }
      auto *selected = static_cast<VideoFrameMetadata *>(nullptr);
      for (auto &metadata : video_metadata_) {
        if (!metadata.occupied) {
          selected = &metadata;
          break;
        }
      }
      if (selected == nullptr) {
        selected = &*std::ranges::min_element(video_metadata_, {}, &VideoFrameMetadata::arrival_order);
      }
      *selected = {
        .occupied = true,
        .key = key,
        .deadline_microseconds = saturating_add(
          now,
          video_configuration_.maximum_frame_age_microseconds
        ),
        .arrival_order = video_next_metadata_order_++,
      };
      return selected;
    }

    /** @brief Remove one provisional metadata record after completion or portable
     * eviction. */
    void erase_video_metadata(const lumen::lsp::media::frame_key key) noexcept {
      for (auto &metadata : video_metadata_) {
        if (metadata.occupied && metadata.key == key) {
          metadata = {};
          return;
        }
      }
    }

    /** @brief Merge repeated boundary metadata and reject authenticated
     * conflicts. */
    [[nodiscard]] bool
    merge_video_metadata(VideoFrameMetadata &metadata, const VideoExtensions &extensions) noexcept {
      if (extensions.has_frame_id) {
        if (extensions.frame_id < video_configuration_.frame_id_origin ||
            (metadata.frame_id != 0 && metadata.frame_id != extensions.frame_id)) {
          return false;
        }
        metadata.frame_id = extensions.frame_id;
      }
      if (extensions.has_capture_time) {
        if (metadata.has_capture_time && metadata.capture_time_microseconds !=
                                           extensions.capture_time_microseconds) {
          return false;
        }
        metadata.has_capture_time = true;
        metadata.capture_time_microseconds = extensions.capture_time_microseconds;
      }
      if (extensions.has_input_watermark) {
        if (metadata.has_input_watermark &&
            (metadata.input_state_sequence != extensions.input_state_sequence ||
             metadata.input_edge_id != extensions.input_edge_id)) {
          return false;
        }
        metadata.has_input_watermark = true;
        metadata.input_state_sequence = extensions.input_state_sequence;
        metadata.input_edge_id = extensions.input_edge_id;
      }
      if (extensions.has_frame_marking) {
        if (metadata.has_independent_marking &&
            metadata.independent != extensions.independent) {
          return false;
        }
        metadata.has_independent_marking = true;
        metadata.independent = extensions.independent;
      }
      return true;
    }

    /** @brief Admit one authenticated primary video RTP packet into bounded
     * native reassembly. */
    [[nodiscard]] bool
    handle_authenticated_video(const std::span<const std::uint8_t> packet, const std::uint64_t now) noexcept {
      if (!video_reassembler_) {
        return false;
      }
      const auto parsed = parse_video_packet(packet, video_configuration_);
      if (!parsed || parsed->header.marker != parsed->extensions.ends_frame ||
          ((parsed->extensions.starts_frame || parsed->extensions.ends_frame) &&
           (!parsed->extensions.has_frame_id ||
            !parsed->extensions.has_frame_marking))) {
        return false;
      }
      lumen::lsp::packet_slab<maximum_depacketized_video_bytes> chunk;
      const auto payload_type =
        video_configuration_.codec == 1U ? static_cast<std::uint8_t>(parsed->payload[0] & 0x1fU) : static_cast<std::uint8_t>((parsed->payload[0] >> 1U) & 0x3fU);
      if (video_configuration_.codec == 1U &&
          payload_type == lumen::lsp::media::h264_fu_a_type) {
        if ((parsed->extensions.starts_frame &&
             (parsed->payload.size() < 2U ||
              (parsed->payload[1] & 0x80U) == 0)) ||
            (parsed->extensions.ends_frame &&
             (parsed->payload.size() < 2U || (parsed->payload[1] & 0x40U) == 0))) {
          return false;
        }
      }
      if (video_configuration_.codec == 2U &&
          payload_type == lumen::lsp::media::hevc_fu_type) {
        if ((parsed->extensions.starts_frame &&
             (parsed->payload.size() < 3U ||
              (parsed->payload[2] & 0x80U) == 0)) ||
            (parsed->extensions.ends_frame &&
             (parsed->payload.size() < 3U || (parsed->payload[2] & 0x40U) == 0))) {
          return false;
        }
      }
      const auto depacketized = video_configuration_.codec == 1U ? depacketize_h264(parsed->payload, chunk) : depacketize_hevc(parsed->payload, chunk);
      if (!depacketized) {
        return false;
      }
      const auto key = lumen::lsp::media::frame_key{
        .ssrc = parsed->header.ssrc,
        .extended_timestamp = extend_video_timestamp(parsed->header.timestamp),
      };
      expire_video_frames(now);
      if (video_frame_retired(key)) {
        return true;
      }
      auto *metadata = video_metadata_for(key, now);
      if (metadata == nullptr ||
          !merge_video_metadata(*metadata, parsed->extensions)) {
        erase_video_metadata(key);
        return false;
      }
      auto retained =
        lumen::lsp::media::retained_packet_slice::copy(chunk.bytes());
      if (!retained) {
        erase_video_metadata(key);
        return false;
      }
      const auto result = video_reassembler_->add(
        {
          .key = key,
          .frame_id = parsed->extensions.has_frame_id ? parsed->extensions.frame_id : 0,
          .extended_sequence =
            extend_video_sequence(parsed->header.sequence_number),
          .deadline_us = metadata->deadline_microseconds,
          .starts_frame = parsed->extensions.starts_frame,
          .ends_frame = parsed->extensions.ends_frame,
          .marker = parsed->header.marker,
          .payload = std::move(*retained),
        },
        now
      );
      if (result.evicted) {
        retire_video_frame(*result.evicted);
        erase_video_metadata(*result.evicted);
      }
      if (result.status ==
            lumen::lsp::media::frame_reassembly_status::malformed ||
          result.status ==
            lumen::lsp::media::frame_reassembly_status::frame_too_large ||
          result.status == lumen::lsp::media::frame_reassembly_status::expired) {
        retire_video_frame(key);
        erase_video_metadata(key);
        if (result.status ==
            lumen::lsp::media::frame_reassembly_status::expired) {
          coalesce_video_capacity_status(
            lumen::lsp::transport::lspv_event::capacity_transition,
            true
          );
        }
        return false;
      }
      if (result.status != lumen::lsp::media::frame_reassembly_status::completed) {
        return true;
      }
      const auto *completed = result.frame.get();
      if (completed == nullptr || completed->frame_id() == 0 ||
          completed->frame_id() != metadata->frame_id || completed->size() == 0 ||
          completed->size() > video_configuration_.maximum_access_unit_bytes) {
        retire_video_frame(key);
        erase_video_metadata(key);
        return false;
      }
      pthread_mutex_lock(&mutex_);
      video_largest_complete_frame_id_ =
        std::max(video_largest_complete_frame_id_, completed->frame_id());
      pthread_mutex_unlock(&mutex_);
      auto *buffer =
        acquire_retained_frame_buffer(video_frame_pool_, completed->size());
      if (buffer == nullptr) {
        coalesce_video_status(
          lumen::lsp::transport::lspv_decoder_status::surface_exhausted,
          lumen::lsp::transport::lspv_event::capacity_transition,
          false
        );
        retire_video_frame(key);
        erase_video_metadata(key);
        return true;
      }
      auto destination = mutable_retained_frame_bytes(buffer);
      std::size_t offset = 0;
      for (const auto &slice : completed->slices()) {
        const auto source = slice.bytes();
        if (source.size() > destination.size() - offset) {
          clsp_buffer_release(buffer);
          retire_video_frame(key);
          erase_video_metadata(key);
          return false;
        }
        std::copy(source.begin(), source.end(), destination.begin() + static_cast<std::ptrdiff_t>(offset));
        offset += source.size();
      }
      if (offset != destination.size()) {
        clsp_buffer_release(buffer);
        retire_video_frame(key);
        erase_video_metadata(key);
        return false;
      }
      pthread_mutex_lock(&mutex_);
      if (!video_decoder_credit_.try_acquire()) {
        const auto update = lspv_coalescer_.update(
          current_lspv_status(
            lumen::lsp::transport::lspv_decoder_status::surface_exhausted
          ),
          lumen::lsp::transport::lspv_event::capacity_transition
        );
        pthread_mutex_unlock(&mutex_);
        clsp_buffer_release(buffer);
        retire_video_frame(key);
        erase_video_metadata(key);
        if (update == lumen::lsp::transport::lspv_update_result::accepted) {
          wake_worker();
        }
        return true;
      }
      const auto update = lspv_coalescer_.update(
        current_lspv_status(
          video_decoder_credit_.available() == 0 ? lumen::lsp::transport::lspv_decoder_status::surface_exhausted : lumen::lsp::transport::lspv_decoder_status::ready
        ),
        lumen::lsp::transport::lspv_event::capacity_transition
      );
      pthread_mutex_unlock(&mutex_);
      if (update == lumen::lsp::transport::lspv_update_result::accepted) {
        wake_worker();
      }
      const clsp_video_frame_event_t event{
        .abi_version = CLSP_CORE_ABI_VERSION,
        .structure_size = sizeof(clsp_video_frame_event_t),
        .video_generation = video_configuration_.video_generation,
        .rtp_timestamp = parsed->header.timestamp,
        .frame_id = completed->frame_id(),
        .receive_time_microseconds = now,
        .capture_time_microseconds = metadata->capture_time_microseconds,
        .input_state_sequence = metadata->input_state_sequence,
        .input_edge_id = metadata->input_edge_id,
        .recovery_epoch = video_configuration_.recovery_epoch,
        .independent = static_cast<std::uint8_t>(metadata->independent),
        .codec = video_configuration_.codec,
        .reserved_zero = 0,
        .frame = buffer,
      };
      retire_video_frame(key);
      erase_video_metadata(key);
      if (pending_video_delivery_count_ >= pending_video_deliveries_.size()) {
        pthread_mutex_lock(&mutex_);
        (void)video_decoder_credit_.release();
        pthread_mutex_unlock(&mutex_);
        clsp_buffer_release(buffer);
        coalesce_video_status(
          lumen::lsp::transport::lspv_decoder_status::surface_exhausted,
          lumen::lsp::transport::lspv_event::capacity_transition,
          false
        );
        return true;
      }
      pending_video_deliveries_[pending_video_delivery_count_++] = event;
      return true;
    }

    /** @brief Deliver complete-frame callbacks only after the current socket
     * drain finishes. */
    void deliver_video_frames() noexcept {
      for (std::size_t index = 0; index < pending_video_delivery_count_;
           ++index) {
        callbacks_.video_frame(callbacks_.context, pending_video_deliveries_[index]);
        pending_video_deliveries_[index] = {};
      }
      pending_video_delivery_count_ = 0;
    }

    /** @brief Serialize and submit the frozen 56-byte protected RTCP APP LSPV
     * status. */
    [[nodiscard]] clsp_status_t transmit_lspv() noexcept {
  #if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      if (!video_configured_.load(std::memory_order_acquire) ||
          !input_configured_) {
        return CLSP_STATUS_OK;
      }
      const auto now = monotonic_microseconds();
      lumen::lsp::transport::lspv_status status;
      lumen::lsp::transport::lspv_event event;
      pthread_mutex_lock(&mutex_);
      const auto available = lspv_coalescer_.take(now, status, event);
      if (available && status.deadline_miss) {
        video_deadline_miss_latched_ = false;
      }
      pthread_mutex_unlock(&mutex_);
      if (!available) {
        return CLSP_STATUS_OK;
      }
      if (lumen::lsp::transport::validate_lspv_status(status) !=
          lumen::lsp::transport::lspv_status_error::none) {
        return CLSP_STATUS_INTERNAL_FAILURE;
      }
      std::array<std::uint8_t, 96> packet{};
      packet[0] = 0x80;
      packet[1] = lumen::lsp::transport::rtcp_app_type;
      lumen::lsp::wire::write_be<std::uint16_t>(
        std::span<std::uint8_t>{packet}.subspan(2, 2),
        13U
      );
      lumen::lsp::wire::write_be<std::uint32_t>(
        std::span<std::uint8_t>{packet}.subspan(4, 4),
        input_configuration_.input_ssrc
      );
      std::copy(lumen::lsp::transport::lspv_app_name.begin(), lumen::lsp::transport::lspv_app_name.end(), packet.begin() + 8);
      packet[12] = 1U;
      packet[13] = status.deadline_miss ? 1U : 0U;
      packet[14] = static_cast<std::uint8_t>(status.decoder_status);
      packet[15] = status.maximum_decode_submissions;
      lumen::lsp::wire::write_be<std::uint32_t>(
        std::span<std::uint8_t>{packet}.subspan(16, 4),
        status.session_generation
      );
      lumen::lsp::wire::write_be<std::uint32_t>(
        std::span<std::uint8_t>{packet}.subspan(20, 4),
        status.video_generation
      );
      lumen::lsp::wire::write_be<std::uint32_t>(
        std::span<std::uint8_t>{packet}.subspan(24, 4),
        status.recovery_epoch
      );
      lumen::lsp::wire::write_be<std::uint64_t>(
        std::span<std::uint8_t>{packet}.subspan(28, 8),
        status.largest_complete_frame_id
      );
      lumen::lsp::wire::write_be<std::uint64_t>(
        std::span<std::uint8_t>{packet}.subspan(36, 8),
        status.largest_decoded_frame_id
      );
      lumen::lsp::wire::write_be<std::uint64_t>(
        std::span<std::uint8_t>{packet}.subspan(44, 8),
        status.largest_metal_committed_frame_id
      );
      packet[52] = status.decode_submissions_in_flight;
      packet[53] = status.render_mailbox_occupancy;
      auto length = std::size_t{56};
      const auto protected_status = srtp_.protect(packet, length, true);
      if (protected_status != CLSP_STATUS_OK) {
        return protected_status;
      }
      const auto sent = ::send(socket_, packet.data(), length, 0);
      if (sent != static_cast<ssize_t>(length)) {
        if (sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
          pthread_mutex_lock(&mutex_);
          video_deadline_miss_latched_ =
            video_deadline_miss_latched_ || status.deadline_miss;
          (void)lspv_coalescer_.update(status, event);
          pthread_mutex_unlock(&mutex_);
          return CLSP_STATUS_OK;
        }
        return CLSP_STATUS_SOCKET_FAILURE;
      }
      increment(RuntimeCounter::transmitted);
      return CLSP_STATUS_OK;
  #else
      return CLSP_STATUS_UNSUPPORTED;
  #endif
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
    [[nodiscard]] bool handle_authenticated_realtime(
      const std::span<const std::uint8_t> packet,
      const bool rtcp
    ) noexcept {
      if (packet.size() < 12U || (packet[0] >> 6U) != 2U) {
        return false;
      }
      if (!rtcp) {
        const auto rtp = lumen::lsp::parse_rtp_fixed_header(packet);
        if (!rtp) {
          return false;
        }
        if (video_configured_.load(std::memory_order_acquire) &&
            rtp.header.ssrc == video_configuration_.primary_ssrc) {
          return handle_authenticated_video(packet, monotonic_microseconds());
        }
        if (!audio_configured_.load(std::memory_order_acquire)) return false;
        const auto audio = audio_configuration_;
        if (!rtp || rtp.header.padding || rtp.header.extension || rtp.header.csrc_count != 0 ||
            rtp.header.ssrc != audio.audio_ssrc || rtp.header.payload_type != audio.audio_payload_type ||
            packet.size() > audio.udp_payload_size || packet.size() <= rtp.bytes_consumed || callbacks_.audio_packet == nullptr) {
          return false;
        }
        const auto opus = packet.subspan(rtp.bytes_consumed);
        const clsp_audio_packet_event_t event {
          .abi_version = CLSP_CORE_ABI_VERSION,
          .structure_size = sizeof(clsp_audio_packet_event_t),
          .audio_generation = audio.audio_generation,
          .ssrc = audio.audio_ssrc,
          .timestamp = rtp.header.timestamp,
          .sequence_number = rtp.header.sequence_number,
          .marker = static_cast<std::uint8_t>(rtp.header.marker),
          .reserved_zero = 0,
          .opus_packet = {.data = opus.data(), .length = opus.size()},
        };
        callbacks_.audio_packet(callbacks_.context, event);
        return true;
      }
      if (packet[1] == 200U) {
        if (packet.size() < 28U) {
          return false;
        }
        const auto words = lumen::lsp::wire::read_be<std::uint16_t>(packet.subspan(2, 2));
        if ((static_cast<std::size_t>(words) + 1U) * 4U != packet.size()) {
          return false;
        }
        const auto sender_ssrc =
            lumen::lsp::wire::read_be<std::uint32_t>(packet.subspan(4, 4));
        if (video_configured_.load(std::memory_order_acquire) &&
            sender_ssrc == video_configuration_.primary_ssrc) {
          return true;
        }
        if (!audio_configured_.load(std::memory_order_acquire) ||
            callbacks_.audio_timing == nullptr) {
          return false;
        }
        const auto audio = audio_configuration_;
        if (sender_ssrc != audio.audio_ssrc) {
          return false;
        }
        const clsp_audio_timing_event_t timing {
          .abi_version = CLSP_CORE_ABI_VERSION,
          .structure_size = sizeof(clsp_audio_timing_event_t),
          .audio_generation = audio.audio_generation,
          .ssrc = audio.audio_ssrc,
          .ntp_seconds = lumen::lsp::wire::read_be<std::uint32_t>(packet.subspan(8, 4)),
          .ntp_fraction = lumen::lsp::wire::read_be<std::uint32_t>(packet.subspan(12, 4)),
          .rtp_timestamp = lumen::lsp::wire::read_be<std::uint32_t>(packet.subspan(16, 4)),
        };
        callbacks_.audio_timing(callbacks_.context, timing);
        return true;
      }
      if (packet[1] != 204U) return false;
      if (!input_configured_) return false;
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
      const auto semantic_request = !lumen::lsp::has_flag(parsed.header.flags, lumen::lsp::lspc_flag::response) &&
                                    !lumen::lsp::has_flag(parsed.header.flags, lumen::lsp::lspc_flag::acknowledgement_only) &&
                                    parsed.header.request_id != 0;
      if (observed == lumen::lsp::receive_id_result::duplicate) {
        if (semantic_request) {
          const auto cached = inbound_response_cache_.lookup(parsed.header.request_id, plaintext);
          if (cached.result == lumen::lsp::response_cache_result::hit) {
            const auto status = dtls_.send_application_data(cached.response);
            if (status != CLSP_STATUS_OK) return false;
            increment(RuntimeCounter::transmitted);
          } else if (cached.result == lumen::lsp::response_cache_result::conflicting_request) {
            return false;
          }
        }
        return true;
      }
      if (lumen::lsp::has_flag(parsed.header.flags, lumen::lsp::lspc_flag::acknowledgement_only)) {
        return true;
      }
      if (semantic_request && !retain_inbound_request(parsed.header.request_id, plaintext)) return false;
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
          .flags = command.flags,
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
        PendingInboundRequest *pending_request = nullptr;
        if (command.response) {
          pending_request = pending_inbound_request(command.request_id);
          if (pending_request == nullptr) return CLSP_STATUS_INVALID_STATE;
          const auto cached = inbound_response_cache_.insert(command.request_id, pending_request->frame.bytes(), encoded);
          if (cached != lumen::lsp::response_cache_result::stored && cached != lumen::lsp::response_cache_result::hit) {
            return CLSP_STATUS_INTERNAL_FAILURE;
          }
        }
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
        if (pending_request != nullptr) {
          pending_request->occupied = false;
          pending_request->frame.clear();
        }
        if (command.activate_microphone) {
          if (!microphone_prepared_.load(std::memory_order_acquire)) return CLSP_STATUS_INVALID_STATE;
          microphone_active_.store(true, std::memory_order_release);
        }
        if (command.response) {
          completed_response_request_.store(command.request_id, std::memory_order_release);
          pthread_mutex_lock(&mutex_);
          pthread_cond_broadcast(&condition_);
          pthread_mutex_unlock(&mutex_);
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
    lumen::lsp::response_cache<maximum_control_frame, maximum_control_frame> inbound_response_cache_;  ///< Host request response replay.
    lumen::lsp::control_rto rto_;  ///< Local-path bounded RTO estimator.
    std::array<ControlCommand, control_queue_capacity> control_queue_ {};  ///< Pre-wire bounded queue.
    std::array<PendingInboundRequest, 64> pending_inbound_requests_ {};  ///< Authenticated requests awaiting semantic response.
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
    std::atomic<bool> audio_configured_ {false};  ///< Exact host-audio mapping admission gate.
    std::atomic<bool> video_configured_ {false};  ///< Exact primary-video mapping admission gate.
    clsp_audio_configuration_t audio_configuration_ {};  ///< Installed audio generation/SSRC/PT tuple.
    clsp_video_configuration_t video_configuration_ {};  ///< Immutable active video generation mapping.
    retained_frame_pool *video_frame_pool_ {};  ///< Preallocated complete-frame ABI storage.
    std::optional<lumen::lsp::media::video_frame_reassembler> video_reassembler_ {};  ///< Two incomplete frames.
    lumen::lsp::media::decoder_credit_state video_decoder_credit_;  ///< Two-to-four hardware submissions.
    lumen::lsp::transport::lspv_coalescer lspv_coalescer_;  ///< Protected 500-microsecond status coalescer.
    std::array<VideoFrameMetadata, 2> video_metadata_ {};  ///< Repeated metadata for two incomplete frames.
    std::array<VideoRetiredFrame, 128> video_retired_frames_ {};  ///< Mirrors the inbound SRTP replay window.
    std::array<clsp_video_frame_event_t, video_delivery_queue_capacity> pending_video_deliveries_ {};  ///< Post-drain frame callbacks.
    clsp_microphone_configuration_t microphone_configuration_ {};  ///< Installed reverse microphone tuple.
    std::array<lumen::lsp::packet_slab<maximum_microphone_opus_bytes>, microphone_queue_capacity> microphone_queue_ {};  ///< Complete Opus SPSC queue.
    std::atomic<std::size_t> microphone_read_ {0};  ///< Native sender queue read cursor.
    std::atomic<std::size_t> microphone_write_ {0};  ///< Swift encoder queue write cursor.
    std::atomic<bool> microphone_active_ {false};  ///< Capture-to-network admission state.
    std::atomic<bool> microphone_prepared_ {false};  ///< Mapping/queue prepared before semantic ACK.
    std::atomic<bool> microphone_marker_ {true};  ///< Marker for the next discontinuous packet.
    std::atomic<std::uint64_t> neutralize_requested_ {0};  ///< Latest synchronous neutralize token.
    std::atomic<std::uint64_t> neutralize_completed_ {0};  ///< Worker-completed neutralize token.
    std::atomic<std::uint64_t> input_configuration_requested_ {0};  ///< Latest synchronous mapping token.
    std::atomic<std::uint64_t> input_configuration_completed_ {0};  ///< Worker-installed mapping token.
    std::atomic<std::uint64_t> completed_response_request_ {0};  ///< Last submitted/cached semantic response ID.
    std::size_t control_queue_head_ {};  ///< Next queued request to consume.
    std::size_t control_queue_tail_ {};  ///< Next free queue slot.
    std::size_t queued_control_count_ {};  ///< Occupied pre-wire queue slots.
    std::size_t pending_video_delivery_count_ {};  ///< Completed frames awaiting post-drain callback.
    std::atomic<std::size_t> capture_read_ {0};  ///< Worker-owned SPSC read cursor.
    std::atomic<std::size_t> capture_write_ {0};  ///< Capture-source-owned SPSC write cursor.
    std::uint64_t next_message_id_ {1};  ///< Next nonzero client-to-host LSPC message ID.
    std::uint64_t video_next_metadata_order_ {1};  ///< Oldest-frame eviction ordering.
    std::uint64_t video_next_retirement_order_ {1};  ///< Retired-key replacement ordering.
    std::uint64_t video_largest_extended_sequence_ {};  ///< RTP sequence wrap/reorder origin.
    std::uint64_t video_largest_extended_timestamp_ {};  ///< RTP timestamp wrap/reorder origin.
    std::uint64_t video_largest_complete_frame_id_ {};  ///< LSPV complete watermark.
    std::uint64_t video_largest_decoded_frame_id_ {};  ///< LSPV hardware-decode watermark.
    std::uint64_t video_largest_metal_frame_id_ {};  ///< LSPV Metal-commit watermark.
    std::uint8_t video_render_mailbox_occupancy_ {};  ///< Current Swift render mailbox occupancy.
    std::uint64_t pending_input_configuration_token_ {};  ///< Token paired with pending START/ATTACH mapping.
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
    std::uint16_t microphone_sequence_ {};  ///< Microphone RTP sequence.
    std::uint32_t microphone_timestamp_ {};  ///< 48-kHz microphone RTP timestamp.
    std::uint32_t microphone_packet_count_ {};  ///< Sender-report packet count.
    std::uint32_t microphone_octet_count_ {};  ///< Sender-report Opus octet count.
    std::uint64_t microphone_tokens_bits_ {};  ///< Reverse microphone pacing credit.
    std::uint64_t microphone_last_credit_us_ {};  ///< Last microphone token refill.
    std::uint64_t microphone_last_report_us_ {};  ///< Last microphone RTCP SR submission.
    bool input_configuration_pending_ {};  ///< Producer installed a new START mapping.
    bool video_sequence_initialized_ {};  ///< Whether extended sequence state has an origin.
    bool video_timestamp_initialized_ {};  ///< Whether extended timestamp state has an origin.
    bool video_deadline_miss_latched_ {};  ///< Deadline miss retained until LSPV consumption.
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

  clsp_status_t Runtime::send_control_response(
    const std::uint16_t message_type,
    const std::uint64_t request_id,
    const clsp_const_byte_span_t payload,
    const bool error_response,
    const std::uint32_t deadline_milliseconds
  ) noexcept {
    return impl_ == nullptr ? CLSP_STATUS_RESOURCE_EXHAUSTED :
                              impl_->send_control_response(
                                message_type,
                                request_id,
                                payload,
                                error_response,
                                deadline_milliseconds
                              );
  }

  clsp_status_t Runtime::configure_audio(const clsp_audio_configuration_t &configuration) noexcept {
    return impl_ == nullptr ? CLSP_STATUS_RESOURCE_EXHAUSTED : impl_->configure_audio(configuration);
  }

  clsp_status_t Runtime::wait_control_response(
    const std::uint64_t request_id,
    const std::uint32_t timeout_milliseconds
  ) noexcept {
    return impl_ == nullptr ? CLSP_STATUS_RESOURCE_EXHAUSTED :
                              impl_->wait_control_response(request_id, timeout_milliseconds);
  }

  clsp_status_t Runtime::configure_microphone(const clsp_microphone_configuration_t &configuration) noexcept {
    return impl_ == nullptr ? CLSP_STATUS_RESOURCE_EXHAUSTED : impl_->configure_microphone(configuration);
  }

  clsp_status_t Runtime::submit_microphone_packet(const clsp_const_byte_span_t opus_packet) noexcept {
    return impl_ == nullptr ? CLSP_STATUS_RESOURCE_EXHAUSTED : impl_->submit_microphone_packet(opus_packet);
  }

  clsp_status_t Runtime::mark_microphone_discontinuity() noexcept {
    return impl_ == nullptr ? CLSP_STATUS_RESOURCE_EXHAUSTED : impl_->mark_microphone_discontinuity();
  }

  clsp_status_t Runtime::stop_microphone() noexcept {
    return impl_ == nullptr ? CLSP_STATUS_RESOURCE_EXHAUSTED : impl_->stop_microphone();
  }

  clsp_status_t Runtime::configure_video(
    const clsp_video_configuration_t &configuration
  ) noexcept {
    return impl_ == nullptr ? CLSP_STATUS_RESOURCE_EXHAUSTED : impl_->configure_video(configuration);
  }

  clsp_status_t Runtime::report_video_decode(
    const std::uint32_t video_generation,
    const std::uint64_t frame_id,
    const std::uint32_t recovery_epoch,
    const std::uint8_t decoder_status,
    const std::uint8_t decoder_credit,
    const std::uint8_t render_mailbox_occupancy
  ) noexcept {
    return impl_ == nullptr ? CLSP_STATUS_RESOURCE_EXHAUSTED : impl_->report_video_decode(video_generation, frame_id, recovery_epoch, decoder_status, decoder_credit, render_mailbox_occupancy);
  }

  clsp_status_t Runtime::report_video_commit(
    const std::uint32_t video_generation,
    const std::uint64_t frame_id,
    const std::uint8_t render_mailbox_occupancy
  ) noexcept {
    return impl_ == nullptr ? CLSP_STATUS_RESOURCE_EXHAUSTED : impl_->report_video_commit(video_generation, frame_id, render_mailbox_occupancy);
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
