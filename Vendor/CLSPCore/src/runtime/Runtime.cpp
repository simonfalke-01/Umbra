/**
 * @file Runtime.cpp
 * @brief Nonblocking UDP/kqueue worker with RFC 7983, DTLS, SRTP, and LSPC ownership.
 */

#include "Runtime.h"

#include "../core/control.h"
#include "../core/rtp.h"
#include "../input_plane/input_plane.h"
#include "../media/media.h"
#include "../transport/congestion.h"
#include "../transport/repair.h"
#include "../transport/rtcp.h"
#include "BufferInternal.h"
#include "FixedTelemetry.h"
#include "SecurityProviders.h"
#include "TransportFeedback.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <bit>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <memory>
#include <new>
#include <optional>
#include <span>

#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
  #include <arpa/inet.h>
  #include <fcntl.h>
  #include <mach/mach_time.h>
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
    constexpr std::size_t safe_udp_payload = 1'200;  ///< Mandatory LSP/1 unprobed UDP payload.
    constexpr std::size_t input_rtp_header_bytes = 12;  ///< Fixed RTP header without extensions.
    constexpr std::size_t input_srtp_tag_bytes = 16;  ///< AEAD AES-128-GCM authentication tag.
    constexpr std::size_t baseline_part_data_capacity =
      safe_udp_payload - input_rtp_header_bytes - input_srtp_tag_bytes -
      lumen::lsp::input_plane::common_header_size - lumen::lsp::input_plane::baseline_part_header_size;
    constexpr std::size_t microphone_queue_capacity = 3;  ///< Two live packets plus one SPSC sentinel slot.
    constexpr std::size_t maximum_microphone_opus_bytes = 1'172;  ///< 1,200 minus RTP and SRTP tag.
    constexpr std::size_t input_feedback_ledger_capacity = 65'536;  ///< One exact slot per RTP sequence value.
    constexpr std::uint64_t input_feedback_freshness_microseconds = 1'000'000;  ///< Bounded high-rate feedback age.
    constexpr std::size_t microphone_feedback_ledger_capacity = 512;  ///< More than ten seconds at 20-ms cadence.
    constexpr std::uint64_t microphone_feedback_freshness_microseconds = 5'000'000;  ///< Maximum sent-ledger age.
    constexpr std::uint64_t microphone_compound_freshness_microseconds = 5'000'000;  ///< RFC 5506 authority lifetime.
    constexpr std::uint8_t microphone_minimum_failure_intervals = 8;  ///< Sustained minimum-capacity failure threshold.
    constexpr std::size_t video_delivery_queue_capacity =
      4;  ///< Maximum negotiated hardware submissions.
    constexpr std::size_t maximum_depacketized_video_bytes =
      4'096;  ///< Worst-case small-NAL aggregation expansion.
    constexpr std::size_t authenticated_video_source_capacity =
      128;  ///< Shared source replay-window retention bound.
    constexpr std::size_t pending_flexfec_repair_capacity =
      16;  ///< Bounded authenticated repair packets awaiting a deterministic decode.
    constexpr std::size_t maximum_video_gap_count =
      256;  ///< Bounded unresolved primary sequences and one-shot NACK entries.
    constexpr std::uint64_t competition_reorder_delay_microseconds =
      100;  ///< Maximum validated competition-path reordering wait.
    constexpr std::uint64_t adaptive_reorder_delay_microseconds =
      1'000;  ///< Conservative adaptive-path reordering wait.
    constexpr std::uint64_t authenticated_repair_abuse_window_microseconds =
      10'000'000;  ///< Rolling malformed authenticated repair window.
    constexpr std::uint16_t authenticated_repair_abuse_limit =
      32;  ///< Fail only after bounded repeated authenticated repair abuse.
    constexpr std::uint8_t maximum_video_nack_attempts = 3;  ///< Initial Generic NACK plus two repeats.
    constexpr std::uint64_t competition_nack_repeat_microseconds = 500;  ///< Competition repeat floor.
    constexpr std::uint64_t adaptive_nack_repeat_microseconds = 2'000;  ///< Adaptive repeat floor.
    constexpr std::size_t minimum_retained_video_payload_bytes = 512;  ///< Abuse-resistant slab sizing floor.
    constexpr std::size_t maximum_video_receive_slabs = 65'536;  ///< Per-association receive-slab ceiling.
    constexpr std::uint64_t path_probe_timer_microseconds = 15'000'000U;  ///< RFC 8899 conservative PROBE_TIMER.
    constexpr std::uint64_t path_probe_intent_retention_microseconds = 60'000'000U;  ///< Authenticated intent lifetime.
    constexpr std::uint64_t path_probe_smoothed_rtt_microseconds = 20'000U;  ///< Local-path initial SRTT estimate.
    constexpr std::uint8_t maximum_path_probe_attempts = 3;  ///< RFC 8899 default MAX_PROBES.
    constexpr std::uint64_t compound_rtcp_interval_microseconds = 1'000'000U;  ///< Regular RR/SDES cadence.
    constexpr std::uint64_t active_stream_peer_silence_timeout_microseconds =
      3U * compound_rtcp_interval_microseconds;  ///< Three missed authenticated streaming report intervals.
    constexpr std::uint64_t path_mtu_raise_interval_microseconds = 600'000'000U;  ///< RFC 8899 PMTU_RAISE_TIMER.
    constexpr std::uint64_t recovery_lspv_repeat_interval_microseconds = 20'000U;  ///< Recovery evidence repeat cadence.
    constexpr std::size_t video_frame_state_extension_bytes = 12;  ///< Encrypted frame ID plus epoch bytes.
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

    /** @brief Authenticated negotiated host-to-client video RTP lane. */
    enum class VideoRtpLane : std::uint8_t {
      none,  ///< SSRC is not part of the active video registry.
      primary,  ///< Primary codec RTP source.
      flexfec,  ///< RFC 8627 repair RTP source.
      rtx,  ///< RFC 4588 retransmission RTP source.
    };

    /** @brief Trust origin for one plaintext primary video packet. */
    enum class VideoSourceOrigin : std::uint8_t {
      primary_srtp,  ///< Authenticated directly by the primary SRTP policy.
      flexfec,  ///< Reconstructed from authenticated repair and source inputs.
      rtx,  ///< Reconstructed from an authenticated RFC 4588 RTX packet.
    };

    /** @brief Deterministic FlexFEC decode disposition for one authenticated repair. */
    enum class FlexFecAttempt : std::uint8_t {
      waiting,  ///< More authenticated source packets are required.
      recovered,  ///< Exactly one source was reconstructed and admitted.
      redundant,  ///< Every protected source was already admitted.
      invalid,  ///< Authenticated repair or reconstruction violated negotiation.
    };

    /** @brief Shared primary replay/gap admission disposition. */
    enum class VideoSourceAdmission : std::uint8_t {
      accepted,  ///< New original or recovered source was admitted.
      duplicate,  ///< Already-admitted or too-old source was harmlessly suppressed.
      rejected,  ///< Bounded repair or registry state rejected the source.
    };

    /** @brief Result of classifying authenticated SRTCP as an LSPP probe. */
    enum class PathProbePacketResult : std::uint8_t {
      not_probe,  ///< Packet belongs to another authenticated RTCP lane.
      accepted,  ///< Exact LSPP matched or entered the bounded reorder record.
      invalid,  ///< LSPP name was present but its exact contract failed.
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

    /** @brief Return whether one LSPC ACK base/bitmap explicitly covers a message ID. */
    [[nodiscard]] constexpr bool acknowledges_message(
      const std::uint64_t base,
      const std::uint64_t bitmap,
      const std::uint64_t message_id
    ) noexcept {
      if (base == 0 || message_id == 0 || message_id > base) {
        return false;
      }
      if (message_id == base) {
        return true;
      }
      const auto distance = base - message_id;
      return distance <= 64U && (bitmap & (std::uint64_t {1} << (distance - 1U))) != 0;
    }

    /** @brief Return awake-only uptime microseconds, matching Apple input and socket timestamps. */
    [[nodiscard]] std::uint64_t monotonic_microseconds() noexcept {
#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      timespec value {};
      if (clock_gettime(CLOCK_UPTIME_RAW, &value) != 0 || value.tv_sec < 0 || value.tv_nsec < 0) {
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

#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
    /** @brief Scale raw Mach ticks without intermediate overflow; zero means unavailable. */
    [[nodiscard]] constexpr std::uint64_t mach_ticks_microseconds(
      const std::uint64_t ticks,
      const std::uint32_t numerator,
      const std::uint32_t denominator
    ) noexcept {
      if (numerator == 0 || denominator == 0) {
        return 0;
      }
      const auto value = static_cast<__uint128_t>(ticks) * numerator /
                         (static_cast<std::uint64_t>(denominator) * 1'000U);
      return value > std::numeric_limits<std::uint64_t>::max() ?
               std::numeric_limits<std::uint64_t>::max() : static_cast<std::uint64_t>(value);
    }

    static_assert(mach_ticks_microseconds(24'000'000U, 125U, 3U) == 1'000'000U);
    static_assert(mach_ticks_microseconds(1'000'000U, 1U, 1U) == 1'000U);

    /** @brief Decode Darwin SCM_TIMESTAMP_MONOTONIC, whose payload is mach_absolute_time ticks. */
    [[nodiscard]] std::uint64_t kernel_timestamp_microseconds(const std::uint64_t ticks) noexcept {
      static const auto timebase = []() noexcept {
        mach_timebase_info_data_t value {};
        (void) mach_timebase_info(&value);
        return value;
      }();
      return mach_ticks_microseconds(ticks, timebase.numer, timebase.denom);
    }
#endif

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
      std::uint32_t recovery_epoch{};             ///< Parsed nonzero repeated recovery epoch.
      std::uint64_t capture_time_microseconds{};  ///< NTP fixed-point absolute
                                                  ///< capture value in microseconds.
      std::uint64_t input_state_sequence{};       ///< Applied input state sequence.
      std::uint64_t input_edge_id{};              ///< Applied input edge identifier.
    };

    /** @brief Authenticated recovery-epoch disposition for one video packet. */
    enum class VideoEpochDisposition : std::uint8_t {
      current,  ///< Packet belongs to the active recovery epoch.
      stale,  ///< Packet belongs to an older recovery epoch and must be dropped.
      advance,  ///< Independent-frame metadata advances exactly one epoch.
      invalid,  ///< Epoch jumped, wrapped, or advanced on a dependent frame.
    };

    /**
     * @brief Classify one authenticated per-frame recovery epoch.
     *
     * @param current Nonzero active epoch.
     * @param incoming Nonzero epoch carried by the encrypted frame-state extension.
     * @param independent Whether repeated authenticated frame marking is independent.
     * @return Exact transition disposition.
     */
    [[nodiscard]] constexpr VideoEpochDisposition classify_video_epoch(
      const std::uint32_t current,
      const std::uint32_t incoming,
      const bool independent
    ) noexcept {
      if (current == 0 || incoming == 0) {
        return VideoEpochDisposition::invalid;
      }
      if (incoming < current) {
        return VideoEpochDisposition::stale;
      }
      if (incoming == current) {
        return VideoEpochDisposition::current;
      }
      if (current != std::numeric_limits<std::uint32_t>::max() && incoming == current + 1U && independent) {
        return VideoEpochDisposition::advance;
      }
      return VideoEpochDisposition::invalid;
    }

    /** @brief Return whether latched recovery evidence needs another protected LSPV. */
    [[nodiscard]] constexpr bool recovery_lspv_repeat_due(
      const bool pending,
      const std::uint64_t last_submission_microseconds,
      const std::uint64_t now_microseconds
    ) noexcept {
      return pending &&
             (last_submission_microseconds == 0 || now_microseconds < last_submission_microseconds ||
              now_microseconds - last_submission_microseconds >= recovery_lspv_repeat_interval_microseconds);
    }

    static_assert(classify_video_epoch(7, 7, false) == VideoEpochDisposition::current);
    static_assert(classify_video_epoch(7, 6, true) == VideoEpochDisposition::stale);
    static_assert(classify_video_epoch(7, 8, true) == VideoEpochDisposition::advance);
    static_assert(classify_video_epoch(7, 8, false) == VideoEpochDisposition::invalid);
    static_assert(classify_video_epoch(7, 9, true) == VideoEpochDisposition::invalid);
    static_assert(recovery_lspv_repeat_due(true, 0, 1));
    static_assert(!recovery_lspv_repeat_due(true, 10, 20'009));
    static_assert(recovery_lspv_repeat_due(true, 10, 20'010));
    static_assert(!recovery_lspv_repeat_due(false, 10, 30'000));

    /** @brief Return whether epoch advancement retires a provisional key. */
    [[nodiscard]] constexpr bool retire_on_video_epoch_advance(
      const bool occupied,
      const lumen::lsp::media::frame_key candidate,
      const lumen::lsp::media::frame_key current
    ) noexcept {
      return occupied && candidate != current;
    }

    static_assert(!retire_on_video_epoch_advance(true, {9, 10}, {9, 10}));
    static_assert(retire_on_video_epoch_advance(true, {9, 9}, {9, 10}));
    static_assert(!retire_on_video_epoch_advance(false, {9, 9}, {9, 10}));

    /** @brief New-epoch recovery evidence derived from the validated current frame deadline. */
    struct VideoEpochAdvanceEvidence {
      bool deadline_miss {};  ///< Whether the current recovery frame already expired.
      bool repeat_feedback {};  ///< Whether protected LSPV must repeat until a later ready decode.
      std::uint64_t decoded_watermark {};  ///< Decode watermark that must advance to clear evidence.
    };

    /** @brief Build clean or deadline-latched evidence for an atomic epoch advance. */
    [[nodiscard]] constexpr VideoEpochAdvanceEvidence video_epoch_advance_evidence(
      const bool current_frame_expired,
      const std::uint64_t decoded_watermark
    ) noexcept {
      return {
        .deadline_miss = current_frame_expired,
        .repeat_feedback = current_frame_expired,
        .decoded_watermark = current_frame_expired ? decoded_watermark : 0,
      };
    }

    static_assert(video_epoch_advance_evidence(true, 41).deadline_miss);
    static_assert(video_epoch_advance_evidence(true, 41).repeat_feedback);
    static_assert(video_epoch_advance_evidence(true, 41).decoded_watermark == 41);
    static_assert(!video_epoch_advance_evidence(false, 41).deadline_miss);
    static_assert(video_epoch_advance_evidence(false, 41).decoded_watermark == 0);

    /** @brief Why one video frame key entered the bounded late-packet fence. */
    enum class VideoRetirementReason : std::uint8_t {
      expired_incomplete,  ///< Receive deadline elapsed before completion.
      evicted_incomplete,  ///< A newer provisional frame displaced this key.
      stale_epoch,  ///< Authenticated media belonged to an older recovery epoch.
      malformed,  ///< Authenticated fragments or repeated metadata conflicted.
      completed,  ///< The key reached complete-frame terminal handling.
    };

    /** @brief Validate late +1 recovery against the retired key's reason and bound identity. */
    [[nodiscard]] constexpr bool permit_late_video_epoch_advance(
      const VideoRetirementReason reason,
      const std::uint64_t bound_frame_id,
      const std::uint32_t bound_epoch,
      const std::uint64_t incoming_frame_id,
      const std::uint32_t incoming_epoch
    ) noexcept {
      if (reason != VideoRetirementReason::expired_incomplete || incoming_frame_id == 0 || incoming_epoch == 0) {
        return false;
      }
      if (bound_frame_id == 0 && bound_epoch == 0) {
        return true;
      }
      return bound_frame_id != 0 && bound_epoch != 0 &&
             bound_frame_id == incoming_frame_id && bound_epoch == incoming_epoch;
    }

    static_assert(permit_late_video_epoch_advance(VideoRetirementReason::expired_incomplete, 0, 0, 90, 2));
    static_assert(permit_late_video_epoch_advance(VideoRetirementReason::expired_incomplete, 90, 2, 90, 2));
    static_assert(!permit_late_video_epoch_advance(VideoRetirementReason::completed, 90, 2, 90, 2));
    static_assert(!permit_late_video_epoch_advance(VideoRetirementReason::malformed, 0, 0, 90, 2));
    static_assert(!permit_late_video_epoch_advance(VideoRetirementReason::expired_incomplete, 89, 2, 90, 2));
    static_assert(!permit_late_video_epoch_advance(VideoRetirementReason::expired_incomplete, 90, 1, 90, 2));

    /** @brief Authenticated RTP payload and negotiated boundary metadata. */
    struct ParsedVideoPacket {
      lumen::lsp::rtp_fixed_header header{};  ///< Validated visible RTP header.
      VideoExtensions extensions{};           ///< Validated negotiated extensions.
      std::span<const std::uint8_t>
        payload{};  ///< Exact codec RTP payload without padding.
    };

    /** @brief Borrowed generic RTP payload after bounded CSRC, extension, and padding parsing. */
    struct RtpPayloadView {
      lumen::lsp::rtp_fixed_header header {};  ///< Validated visible fixed RTP fields.
      std::span<const std::uint8_t> header_bytes {};  ///< Header and extension bytes before payload.
      std::span<const std::uint8_t> payload {};  ///< Exact payload excluding RTP padding.
    };

    /** @brief Parse generic RTP payload bounds without interpreting codec extensions. */
    [[nodiscard]] constexpr std::optional<RtpPayloadView> parse_rtp_payload(
      const std::span<const std::uint8_t> packet
    ) noexcept {
      const auto parsed = lumen::lsp::parse_rtp_fixed_header(packet);
      if (!parsed) {
        return std::nullopt;
      }
      auto payload_offset = parsed.bytes_consumed;
      if (parsed.header.extension) {
        if (packet.size() < payload_offset + 4U) {
          return std::nullopt;
        }
        const auto extension_words = lumen::lsp::wire::read_be<std::uint16_t>(
          packet.subspan(payload_offset + 2U, 2)
        );
        const auto extension_bytes = static_cast<std::size_t>(extension_words) * 4U;
        if (extension_bytes > packet.size() - payload_offset - 4U) {
          return std::nullopt;
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
      return RtpPayloadView {
        .header = parsed.header,
        .header_bytes = packet.first(payload_offset),
        .payload = packet.subspan(payload_offset, payload_end - payload_offset),
      };
    }

    /** @brief Typed result of reconstructing one RFC 4588 primary RTP packet. */
    struct RtxReconstructionResult {
      std::size_t bytes_written {};  ///< Complete reconstructed primary plaintext bytes.
      std::uint16_t original_sequence_number {};  ///< RFC 4588 OSN extracted from RTX payload.

      /** @brief Return whether a complete primary packet was reconstructed. */
      [[nodiscard]] constexpr explicit operator bool() const noexcept {
        return bytes_written != 0;
      }
    };

    /**
     * @brief Reconstruct one primary RTP packet from an authenticated RFC 4588 packet.
     *
     * @param packet Complete authenticated/decrypted RTX RTP packet.
     * @param rtx_ssrc Negotiated RTX SSRC.
     * @param rtx_payload_type Negotiated RTX payload type.
     * @param primary_ssrc Associated primary SSRC.
     * @param primary_payload_type Associated primary payload type.
     * @param destination Fixed caller storage for reconstructed plaintext.
     * @return Exact reconstructed byte count and OSN, or an empty result.
     */
    [[nodiscard]] constexpr RtxReconstructionResult reconstruct_rtx_source(
      const std::span<const std::uint8_t> packet,
      const std::uint32_t rtx_ssrc,
      const std::uint8_t rtx_payload_type,
      const std::uint32_t primary_ssrc,
      const std::uint8_t primary_payload_type,
      const std::span<std::uint8_t> destination
    ) noexcept {
      const auto parsed = parse_rtp_payload(packet);
      if (!parsed || parsed->header.padding || parsed->header.csrc_count != 0 ||
          parsed->header.ssrc != rtx_ssrc || parsed->header.payload_type != rtx_payload_type ||
          parsed->payload.size() <= 2U) {
        return {};
      }
      const auto required = parsed->header_bytes.size() + parsed->payload.size() - 2U;
      if (destination.size() < required) {
        return {};
      }
      const auto original_sequence = lumen::lsp::wire::read_be<std::uint16_t>(parsed->payload.first(2));
      std::copy(parsed->header_bytes.begin(), parsed->header_bytes.end(), destination.begin());
      std::copy(
        parsed->payload.begin() + 2,
        parsed->payload.end(),
        destination.begin() + static_cast<std::ptrdiff_t>(parsed->header_bytes.size())
      );
      auto reconstructed = destination.first(required);
      reconstructed[1] = static_cast<std::uint8_t>((reconstructed[1] & 0x80U) | primary_payload_type);
      lumen::lsp::wire::write_be<std::uint16_t>(reconstructed.subspan(2, 2), original_sequence);
      lumen::lsp::wire::write_be<std::uint32_t>(reconstructed.subspan(8, 4), primary_ssrc);
      return {
        .bytes_written = required,
        .original_sequence_number = original_sequence,
      };
    }

    /** @brief Compile-time RFC 4588 OSN/header reconstruction regression check. */
    [[nodiscard]] constexpr bool rtx_reconstruction_contract() noexcept {
      std::array<std::uint8_t, 16> rtx {
        0x80, 0xe2, 0x00, 0x09, 0x00, 0x00, 0x00, 0x07,
        0x11, 0x22, 0x33, 0x44, 0x12, 0x34, 0xaa, 0xbb,
      };
      std::array<std::uint8_t, 16> primary {};
      const auto result = reconstruct_rtx_source(
        rtx,
        0x1122'3344U,
        98U,
        0x5566'7788U,
        97U,
        primary
      );
      return result && result.bytes_written == 14U && result.original_sequence_number == 0x1234U &&
             primary[1] == 0xe1U && primary[2] == 0x12U && primary[3] == 0x34U &&
             primary[8] == 0x55U && primary[9] == 0x66U && primary[10] == 0x77U &&
             primary[11] == 0x88U && primary[12] == 0xaaU && primary[13] == 0xbbU;
    }

    static_assert(rtx_reconstruction_contract());

    /** @brief Return whether one RFC 8627 mask represents a source sequence. */
    [[nodiscard]] constexpr bool flexfec_mask_contains_sequence(
      const std::uint16_t base_sequence_number,
      const std::uint64_t source_mask,
      const std::uint16_t sequence_number
    ) noexcept {
      const auto offset = static_cast<std::uint16_t>(sequence_number - base_sequence_number);
      return offset < lumen::lsp::transport::maximum_flexfec_group_packets &&
             (source_mask & (std::uint64_t {1} << offset)) != 0;
    }

    static_assert(flexfec_mask_contains_sequence(65'534U, 0b111U, 0U));
    static_assert(!flexfec_mask_contains_sequence(65'534U, 0b011U, 0U));

    /** @brief Decide whether pending parity belongs to an advancing recovery frame. */
    [[nodiscard]] constexpr bool flexfec_repair_matches_advancing_frame(
      const bool frame_bound,
      const std::uint32_t bound_rtp_timestamp,
      const std::uint64_t bound_frame_id,
      const std::uint32_t bound_recovery_epoch,
      const std::uint32_t repair_timestamp,
      const std::uint16_t base_sequence_number,
      const std::uint64_t source_mask,
      const std::uint16_t boundary_sequence_number,
      const std::uint32_t advancing_rtp_timestamp,
      const std::uint64_t advancing_frame_id,
      const std::uint32_t advancing_recovery_epoch
    ) noexcept {
      if (!frame_bound) {
        return repair_timestamp == advancing_rtp_timestamp ||
               flexfec_mask_contains_sequence(
                 base_sequence_number,
                 source_mask,
                 boundary_sequence_number
               );
      }
      return bound_rtp_timestamp == advancing_rtp_timestamp &&
             (bound_frame_id == 0 || bound_frame_id == advancing_frame_id) &&
             (bound_recovery_epoch == 0 || bound_recovery_epoch == advancing_recovery_epoch);
    }

    static_assert(flexfec_repair_matches_advancing_frame(
      false, 0, 0, 0, 6, 99, 0b11U, 100, 7, 8, 2
    ));
    static_assert(flexfec_repair_matches_advancing_frame(
      false, 0, 0, 0, 7, 400, 0b11U, 100, 7, 8, 2
    ));
    static_assert(!flexfec_repair_matches_advancing_frame(
      false, 0, 0, 0, 6, 400, 0b11U, 100, 7, 8, 2
    ));
    static_assert(flexfec_repair_matches_advancing_frame(
      true, 7, 8, 2, 999, 0, 0, 0, 7, 8, 2
    ));
    static_assert(!flexfec_repair_matches_advancing_frame(
      true, 7, 8, 1, 7, 0, 0, 0, 7, 8, 2
    ));

    /** @brief One fixed-size reference-counted UDP receive slab. */
    struct VideoReceiveSlab {
      std::array<std::uint8_t, maximum_udp_payload> bytes {};  ///< In-place recv/SRTP/plaintext storage.
      std::uint32_t generation {};  ///< Nonzero token incarnation.
      std::uint32_t references {};  ///< Worker-owned live references.
    };

    /** @brief Configuration-time fixed receive pool with generation-safe tokens. */
    class VideoReceivePool {
    public:
      /** @brief Allocate a bounded slab/free-index arena. */
      [[nodiscard]] bool configure(const std::size_t count) noexcept {
        if (count == 0 || count > maximum_video_receive_slabs || slabs_) {
          return false;
        }
        auto slabs = std::unique_ptr<VideoReceiveSlab[]> {new (std::nothrow) VideoReceiveSlab[count]};
        auto free_indices = std::unique_ptr<std::uint32_t[]> {new (std::nothrow) std::uint32_t[count]};
        if (!slabs || !free_indices) {
          return false;
        }
        for (std::size_t index = 0; index < count; ++index) {
          free_indices[index] = static_cast<std::uint32_t>(count - index - 1U);
        }
        slabs_ = std::move(slabs);
        free_indices_ = std::move(free_indices);
        capacity_ = count;
        free_count_ = count;
        return true;
      }

      /** @brief Acquire one root receive reference and mutable capacity. */
      [[nodiscard]] bool acquire(std::uint64_t &token, std::span<std::uint8_t> &bytes) noexcept {
        token = 0;
        bytes = {};
        if (!slabs_ || free_count_ == 0) {
          return false;
        }
        const auto index = free_indices_[--free_count_];
        auto &slab = slabs_[index];
        ++slab.generation;
        if (slab.generation == 0) {
          ++slab.generation;
        }
        slab.references = 1;
        token = (static_cast<std::uint64_t>(slab.generation) << 32U) |
                (static_cast<std::uint64_t>(index) + 1U);
        bytes = slab.bytes;
        return true;
      }

      /** @brief Retain one live slab token. */
      [[nodiscard]] bool retain(const std::uint64_t token) noexcept {
        auto *slab = find(token);
        if (slab == nullptr || slab->references == std::numeric_limits<std::uint32_t>::max()) {
          return false;
        }
        ++slab->references;
        return true;
      }

      /** @brief Release one live token and recycle its slab at zero. */
      [[nodiscard]] bool release(const std::uint64_t token) noexcept {
        auto *slab = find(token);
        if (slab == nullptr) {
          return false;
        }
        if (--slab->references == 0) {
          const auto index = static_cast<std::uint32_t>((token & 0xffff'ffffU) - 1U);
          free_indices_[free_count_++] = index;
        }
        return true;
      }

      /** @brief Borrow complete mutable slab storage for one live token. */
      [[nodiscard]] std::span<std::uint8_t> mutable_bytes(const std::uint64_t token) noexcept {
        auto *slab = find(token);
        return slab == nullptr ? std::span<std::uint8_t> {} : std::span<std::uint8_t> {slab->bytes};
      }

      /** @brief Borrow complete immutable slab storage for one live token. */
      [[nodiscard]] std::span<const std::uint8_t> bytes(const std::uint64_t token) const noexcept {
        const auto *slab = find(token);
        return slab == nullptr ? std::span<const std::uint8_t> {} : std::span<const std::uint8_t> {slab->bytes};
      }

      /** @brief Return whether configuration storage exists. */
      [[nodiscard]] bool ready() const noexcept {
        return slabs_ != nullptr;
      }

      /** @brief Release storage only after every slab reference was returned. */
      [[nodiscard]] bool clear() noexcept {
        if (slabs_ && free_count_ != capacity_) {
          return false;
        }
        slabs_.reset();
        free_indices_.reset();
        capacity_ = 0;
        free_count_ = 0;
        return true;
      }

    private:
      /** @brief Resolve one mutable generation-safe token. */
      [[nodiscard]] VideoReceiveSlab *find(const std::uint64_t token) noexcept {
        const auto index_plus_one = static_cast<std::uint32_t>(token);
        const auto generation = static_cast<std::uint32_t>(token >> 32U);
        if (!slabs_ || index_plus_one == 0 || index_plus_one > capacity_) {
          return nullptr;
        }
        auto &slab = slabs_[index_plus_one - 1U];
        return generation != 0 && slab.generation == generation && slab.references != 0 ? &slab : nullptr;
      }

      /** @brief Resolve one immutable generation-safe token. */
      [[nodiscard]] const VideoReceiveSlab *find(const std::uint64_t token) const noexcept {
        const auto index_plus_one = static_cast<std::uint32_t>(token);
        const auto generation = static_cast<std::uint32_t>(token >> 32U);
        if (!slabs_ || index_plus_one == 0 || index_plus_one > capacity_) {
          return nullptr;
        }
        const auto &slab = slabs_[index_plus_one - 1U];
        return generation != 0 && slab.generation == generation && slab.references != 0 ? &slab : nullptr;
      }

      std::unique_ptr<VideoReceiveSlab[]> slabs_ {};  ///< Fixed packet storage.
      std::unique_ptr<std::uint32_t[]> free_indices_ {};  ///< O(1) free stack.
      std::size_t capacity_ {};  ///< Allocated slab count.
      std::size_t free_count_ {};  ///< Free-stack depth.
    };

    /** @brief Scope-owned root receive-slab reference. */
    class VideoReceiveLease {
    public:
      /** @brief Construct an empty lease. */
      VideoReceiveLease() noexcept = default;

      /** @brief Release the root reference at scope exit. */
      ~VideoReceiveLease() {
        reset();
      }

      VideoReceiveLease(const VideoReceiveLease &) = delete;
      VideoReceiveLease &operator=(const VideoReceiveLease &) = delete;

      /** @brief Acquire from one configured pool. */
      [[nodiscard]] bool acquire(VideoReceivePool &pool) noexcept {
        reset();
        if (!pool.acquire(token_, bytes_)) {
          return false;
        }
        pool_ = &pool;
        return true;
      }

      /** @brief Return the live slab token. */
      [[nodiscard]] std::uint64_t token() const noexcept {
        return token_;
      }

      /** @brief Return mutable receive capacity. */
      [[nodiscard]] std::span<std::uint8_t> bytes() const noexcept {
        return bytes_;
      }

      /** @brief Transfer the root token without releasing its pool reference. */
      [[nodiscard]] std::uint64_t detach() noexcept {
        const auto token = token_;
        pool_ = nullptr;
        token_ = 0;
        bytes_ = {};
        return token;
      }

      /** @brief Adopt one detached root token without changing its reference count. */
      [[nodiscard]] bool adopt(VideoReceivePool &pool, const std::uint64_t token) noexcept {
        reset();
        auto bytes = pool.mutable_bytes(token);
        if (token == 0U || bytes.empty()) return false;
        pool_ = &pool;
        token_ = token;
        bytes_ = bytes;
        return true;
      }

      /** @brief Release any current root reference. */
      void reset() noexcept {
        if (pool_ != nullptr) {
          (void)pool_->release(token_);
        }
        pool_ = nullptr;
        token_ = 0;
        bytes_ = {};
      }

    private:
      VideoReceivePool *pool_ {};  ///< Owning pool while live.
      std::uint64_t token_ {};  ///< Generation-safe root token.
      std::span<std::uint8_t> bytes_ {};  ///< Mutable slab capacity.
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

    /** @brief Return whether the five RFC8285 IDs equal the frozen LSP assignments. */
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
      return ids == std::array<std::uint8_t, 5> {1, 2, 3, 4, 5};
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
            if (length != video_frame_state_extension_bytes) {
              return std::nullopt;
            }
            extensions.has_frame_id = true;
            extensions.frame_id = lumen::lsp::wire::read_be<std::uint64_t>(value.first(8));
            extensions.recovery_epoch = lumen::lsp::wire::read_be<std::uint32_t>(value.subspan(8, 4));
            if (extensions.frame_id == 0 || extensions.recovery_epoch == 0) {
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

    /** @brief Validate one H.264 RTP payload without copying codec bytes. */
    [[nodiscard]] bool valid_h264_payload(const std::span<const std::uint8_t> payload) noexcept {
      if (payload.empty() || (payload[0] & 0x80U) != 0) {
        return false;
      }
      const auto type = static_cast<std::uint8_t>(payload[0] & 0x1fU);
      if (type >= 1U && type <= 23U) {
        return true;
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
          if (length == 0 || length > payload.size() - offset ||
              !valid_h264_nal(payload.subspan(offset, length))) {
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
      const auto original_type = static_cast<std::uint8_t>(fu & 0x1fU);
      return (fu & 0x20U) == 0 && (fu & 0xc0U) != 0xc0U && original_type != 0 &&
             original_type <= 23U;
    }

    /** @brief Validate one HEVC RTP payload without copying codec bytes. */
    [[nodiscard]] bool valid_hevc_payload(const std::span<const std::uint8_t> payload) noexcept {
      if (payload.size() < 2U || (payload[0] & 0x80U) != 0 || (payload[1] & 0x07U) == 0) {
        return false;
      }
      const auto type = static_cast<std::uint8_t>((payload[0] >> 1U) & 0x3fU);
      if (type <= 47U) {
        return true;
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
          if (length == 0 || length > payload.size() - offset ||
              !valid_hevc_nal(payload.subspan(offset, length))) {
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
      return (fu & 0xc0U) != 0xc0U && static_cast<std::uint8_t>(fu & 0x3fU) <= 47U;
    }
  }  // namespace

  class Runtime::Impl {
  public:
    /** @brief Copy immutable construction state and initialize synchronization primitives. */
    Impl(const clsp_configuration_t &configuration, const RuntimeCallbacks callbacks) noexcept:
        configuration_ {configuration},
        callbacks_ {callbacks},
        rto_ {lumen::lsp::control_path_profile::local} {
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
      terminal_failed_.store(false, std::memory_order_release);
      terminal_status_.store(CLSP_STATUS_OK, std::memory_order_release);
      startup_complete_ = false;
      startup_status_ = CLSP_STATUS_TIMEOUT;
      publish_lifecycle(CLSP_LIFECYCLE_CONNECTING);
      if (pthread_create(&worker_, nullptr, worker_entry, this) != 0) {
        cleanup_platform();
        publish_lifecycle(
          CLSP_LIFECYCLE_FAILED,
          latch_terminal_status(CLSP_STATUS_SOCKET_FAILURE)
        );
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
        terminal_failed_.store(true, std::memory_order_release);
        request_stop();
        join_worker();
        cleanup_platform();
        publish_lifecycle(CLSP_LIFECYCLE_FAILED, latch_terminal_status(status));
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
        microphone_active_.store(false, std::memory_order_release);
        microphone_prepared_.store(false, std::memory_order_release);
        release_video_state();
        cleanup_platform();
        return CLSP_STATUS_OK;
      }
      microphone_active_.store(false, std::memory_order_release);
      microphone_prepared_.store(false, std::memory_order_release);
      const auto preserve_failed = terminal_failed_.load(std::memory_order_acquire);
      request_stop();
      join_worker();
      release_video_state();
      cleanup_platform();
      if (!preserve_failed) {
        publish_lifecycle(CLSP_LIFECYCLE_STOPPED);
      }
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
      if (control_queue_full_locked()) {
        pthread_mutex_unlock(&mutex_);
        producer_dropped_.fetch_add(1U, std::memory_order_relaxed);
        return CLSP_STATUS_CONTROL_WINDOW_FULL;
      }
      auto &command = control_queue_[control_queue_tail_];
      command.message_type = message_type;
      command.request_id = request_id;
      command.flags = static_cast<std::uint8_t>(lumen::lsp::lspc_flag::acknowledgement_required);
      command.response = false;
      command.activate_microphone = false;
      command.transmit_path_probe = false;
      command.path_probe_id = 0;
      command.path_probe_size = 0;
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

    /** @brief Reserve one invisible request plus exact queue capacity. */
    [[nodiscard]] clsp_status_t reserve_control(
      const std::uint16_t message_type,
      const std::uint64_t request_id,
      const clsp_const_byte_span_t payload,
      const std::uint32_t deadline_milliseconds,
      std::uint64_t &reservation_token
    ) noexcept {
      reservation_token = 0;
#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      if (!authenticated_.load(std::memory_order_acquire)) {
        return CLSP_STATUS_NOT_AUTHENTICATED;
      }
      if (message_type == 0 || request_id == 0 || deadline_milliseconds < 20U ||
          deadline_milliseconds > 30'000U || payload.length > maximum_control_payload ||
          (payload.data == nullptr && payload.length != 0)) {
        return CLSP_STATUS_INVALID_ARGUMENT;
      }
      pthread_mutex_lock(&mutex_);
      if (control_reservation_.occupied || control_queue_full_locked()) {
        pthread_mutex_unlock(&mutex_);
        producer_dropped_.fetch_add(1U, std::memory_order_relaxed);
        return CLSP_STATUS_CONTROL_WINDOW_FULL;
      }
      auto &command = control_reservation_.command;
      command.message_type = message_type;
      command.request_id = request_id;
      command.flags = static_cast<std::uint8_t>(lumen::lsp::lspc_flag::acknowledgement_required);
      command.response = false;
      command.activate_microphone = false;
      command.transmit_path_probe = false;
      command.path_probe_id = 0;
      command.path_probe_size = 0;
      command.payload.assign(std::span<const std::uint8_t> {payload.data, payload.length});
      const auto now = monotonic_microseconds();
      const auto duration = static_cast<std::uint64_t>(deadline_milliseconds) * 1'000U;
      command.deadline_microseconds = now > std::numeric_limits<std::uint64_t>::max() - duration ?
                                         std::numeric_limits<std::uint64_t>::max() :
                                         now + duration;
      ++next_control_reservation_token_;
      if (next_control_reservation_token_ == 0U) {
        ++next_control_reservation_token_;
      }
      control_reservation_.token = next_control_reservation_token_;
      control_reservation_.occupied = true;
      reservation_token = control_reservation_.token;
      pthread_mutex_unlock(&mutex_);
      return CLSP_STATUS_OK;
#else
      (void)message_type;
      (void)request_id;
      (void)payload;
      (void)deadline_milliseconds;
      return CLSP_STATUS_UNSUPPORTED;
#endif
    }

    /** @brief Publish one exact reserved request and wake the worker. */
    [[nodiscard]] clsp_status_t commit_control_reservation(
      const std::uint64_t reservation_token
    ) noexcept {
#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      if (reservation_token == 0U) return CLSP_STATUS_INVALID_ARGUMENT;
      pthread_mutex_lock(&mutex_);
      if (!control_reservation_.occupied || control_reservation_.token != reservation_token ||
          queued_control_count_ >= control_queue_capacity) {
        pthread_mutex_unlock(&mutex_);
        return CLSP_STATUS_INVALID_STATE;
      }
      control_queue_[control_queue_tail_] = control_reservation_.command;
      control_queue_tail_ = (control_queue_tail_ + 1U) % control_queue_capacity;
      ++queued_control_count_;
      control_reservation_ = {};
      pthread_mutex_unlock(&mutex_);
      wake_worker();
      return CLSP_STATUS_OK;
#else
      (void)reservation_token;
      return CLSP_STATUS_UNSUPPORTED;
#endif
    }

    /** @brief Release one invisible reserved request. */
    void cancel_control_reservation(const std::uint64_t reservation_token) noexcept {
#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      if (reservation_token == 0U) return;
      pthread_mutex_lock(&mutex_);
      if (control_reservation_.occupied && control_reservation_.token == reservation_token) {
        control_reservation_ = {};
      }
      pthread_mutex_unlock(&mutex_);
#else
      (void)reservation_token;
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
      if (control_queue_full_locked()) {
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
      command.transmit_path_probe = false;
      command.path_probe_id = 0;
      command.path_probe_size = 0;
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
      if (!authenticated_.load(std::memory_order_acquire)) {
        return CLSP_STATUS_NOT_AUTHENTICATED;
      }
      if (!valid_audio_configuration(configuration)) {
        return CLSP_STATUS_INVALID_CONFIGURATION;
      }
      pthread_mutex_lock(&mutex_);
      if (audio_configured_.load(std::memory_order_acquire)) {
        const auto status = same_audio_configuration(audio_configuration_, configuration) ?
                              CLSP_STATUS_OK :
                              CLSP_STATUS_INVALID_STATE;
        pthread_mutex_unlock(&mutex_);
        return status;
      }
      const std::array<std::uint32_t, 1> ssrcs {configuration.audio_ssrc};
      const std::array<std::uint8_t, 1> payload_types {configuration.audio_payload_type};
      if (!reserve_media_identifiers_locked(ssrcs, payload_types)) {
        pthread_mutex_unlock(&mutex_);
        return CLSP_STATUS_INVALID_CONFIGURATION;
      }
      pthread_mutex_unlock(&mutex_);
      const std::array<InboundSecurityStream, 1> security_streams {
        InboundSecurityStream {.ssrc = configuration.audio_ssrc},
      };
      const auto security_status = install_inbound_security_streams(security_streams);
      pthread_mutex_lock(&mutex_);
      if (security_status != CLSP_STATUS_OK) {
        rollback_media_identifiers_locked(ssrcs.size(), payload_types.size());
        pthread_mutex_unlock(&mutex_);
        return security_status;
      }
      audio_configuration_ = configuration;
      audio_feedback_.reset(monotonic_microseconds());
      audio_reception_.reset();
      audio_feedback_sequence_initialized_ = false;
      audio_feedback_largest_extended_sequence_ = 0;
      authenticated_audio_fingerprints_ = {};
      audio_configured_.store(true, std::memory_order_release);
      pthread_mutex_unlock(&mutex_);
      return CLSP_STATUS_OK;
#else
      (void) configuration;
      return CLSP_STATUS_UNSUPPORTED;
#endif
    }

    [[nodiscard]] clsp_status_t configure_microphone(const clsp_microphone_configuration_t &configuration) noexcept {
#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      if (!authenticated_.load(std::memory_order_acquire)) return CLSP_STATUS_NOT_AUTHENTICATED;
      if (!valid_microphone_configuration(configuration)) return CLSP_STATUS_INVALID_CONFIGURATION;
      pthread_mutex_lock(&mutex_);
      if (microphone_prepared_.load(std::memory_order_acquire)) {
        const auto status = same_microphone_configuration(microphone_configuration_, configuration) ?
                              CLSP_STATUS_OK :
                              CLSP_STATUS_INVALID_STATE;
        pthread_mutex_unlock(&mutex_);
        return status;
      }
      const std::array<std::uint32_t, 1> ssrcs {configuration.microphone_ssrc};
      const std::array<std::uint8_t, 1> payload_types {configuration.microphone_payload_type};
      if (!reserve_media_identifiers_locked(ssrcs, payload_types)) {
        pthread_mutex_unlock(&mutex_);
        return CLSP_STATUS_INVALID_CONFIGURATION;
      }
      microphone_configuration_ = configuration;
      pending_microphone_ = {};
      microphone_read_.store(0, std::memory_order_release);
      microphone_write_.store(0, std::memory_order_release);
      microphone_sequence_ = static_cast<std::uint16_t>(arc4random());
      microphone_next_extended_sequence_ = microphone_sequence_;
      microphone_timestamp_ = arc4random();
      microphone_marker_.store(true, std::memory_order_release);
      microphone_packet_count_ = 0;
      microphone_octet_count_ = 0;
      microphone_last_report_us_ = 0;
      microphone_last_credit_us_ = monotonic_microseconds();
      microphone_congestion_.reset();
      reverse_controller_includes_microphone_ = false;
      microphone_congestion_rate_bits_per_second_ = microphone_pacing_rate(configuration);
      microphone_tokens_bits_ = microphone_credit_capacity(
        configuration,
        microphone_congestion_rate_bits_per_second_
      );
      microphone_sent_packets_ = {};
      microphone_sender_report_timings_ = {};
      microphone_sender_report_timing_index_ = 0;
      microphone_bytes_in_flight_ = 0;
      microphone_delivered_bytes_ = 0;
      microphone_lost_bytes_ = 0;
      microphone_ecn_ce_bytes_ = 0;
      microphone_last_delay_send_microseconds_ = 0;
      microphone_last_delay_arrival_timestamp_ = 0;
      microphone_minimum_failure_count_ = 0;
      microphone_has_delay_sample_ = false;
      microphone_prepared_.store(true, std::memory_order_release);
      pthread_mutex_unlock(&mutex_);
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
      pending_microphone_ = {};
      microphone_read_.store(microphone_write_.load(std::memory_order_acquire), std::memory_order_release);
      return CLSP_STATUS_OK;
    }

    /** @brief Install one immutable video schema revision three repair generation and bounded AU storage. */
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
      std::array<std::uint32_t, 3> ssrcs {configuration.primary_ssrc};
      std::array<std::uint8_t, 3> payload_types {configuration.primary_payload_type};
      std::size_t ssrc_count = 1;
      std::size_t payload_type_count = 1;
      if (configuration.flexfec_ssrc != 0) {
        ssrcs[ssrc_count++] = configuration.flexfec_ssrc;
        payload_types[payload_type_count++] = configuration.flexfec_payload_type;
      }
      if (configuration.rtx_ssrc != 0) {
        ssrcs[ssrc_count++] = configuration.rtx_ssrc;
        payload_types[payload_type_count++] = configuration.rtx_payload_type;
      }
      const auto selected_ssrcs = std::span<const std::uint32_t> {ssrcs}.first(ssrc_count);
      const auto selected_payload_types = std::span<const std::uint8_t> {payload_types}.first(payload_type_count);
      if (!reserve_media_identifiers_locked(selected_ssrcs, selected_payload_types)) {
        pthread_mutex_unlock(&mutex_);
        return CLSP_STATUS_INVALID_CONFIGURATION;
      }
      auto *pool = create_retained_frame_pool(
        configuration.maximum_access_unit_bytes,
        static_cast<std::size_t>(configuration.decoder_surfaces) + 2U
      );
      if (pool == nullptr) {
        rollback_media_identifiers_locked(ssrc_count, payload_type_count);
        pthread_mutex_unlock(&mutex_);
        return CLSP_STATUS_RESOURCE_EXHAUSTED;
      }
      auto reassembly_capacity = static_cast<std::size_t>(configuration.maximum_access_unit_bytes);
      constexpr auto maximum_transport_overhead =
        lumen::lsp::media::maximum_fragments_per_frame * 6U;
      const auto available = lumen::lsp::media::absolute_frame_size_limit - reassembly_capacity;
      reassembly_capacity += std::min<std::size_t>(available, maximum_transport_overhead);
      const auto frame_slabs = (reassembly_capacity + minimum_retained_video_payload_bytes - 1U) /
                               minimum_retained_video_payload_bytes;
      const auto requested_slabs = frame_slabs > (maximum_video_receive_slabs - 256U) / 2U ?
                                     maximum_video_receive_slabs :
                                     frame_slabs * 2U + 256U;
      if (!video_receive_pool_.configure(requested_slabs)) {
        release_retained_frame_pool(pool);
        rollback_media_identifiers_locked(ssrc_count, payload_type_count);
        pthread_mutex_unlock(&mutex_);
        return CLSP_STATUS_RESOURCE_EXHAUSTED;
      }
      const auto maximum_fragments = std::min<std::size_t>(
        lumen::lsp::media::maximum_fragments_per_frame,
        frame_slabs + 64U
      );
      video_reassembly_slices_.reset(
        new (std::nothrow) lumen::lsp::media::token_frame_slice[maximum_fragments * 2U]
      );
      if (!video_reassembly_slices_) {
        (void)video_receive_pool_.clear();
        release_retained_frame_pool(pool);
        rollback_media_identifiers_locked(ssrc_count, payload_type_count);
        pthread_mutex_unlock(&mutex_);
        return CLSP_STATUS_RESOURCE_EXHAUSTED;
      }
      video_reassembler_.emplace(
        std::span<lumen::lsp::media::token_frame_slice> {
          video_reassembly_slices_.get(),
          maximum_fragments * 2U,
        },
        reassembly_capacity,
        maximum_fragments
      );
      if (!video_reassembler_->ready()) {
        video_reassembler_.reset();
        video_reassembly_slices_.reset();
        (void)video_receive_pool_.clear();
        release_retained_frame_pool(pool);
        rollback_media_identifiers_locked(ssrc_count, payload_type_count);
        pthread_mutex_unlock(&mutex_);
        return CLSP_STATUS_RESOURCE_EXHAUSTED;
      }
      const std::array<int, 3> encrypted_extensions{
        configuration.frame_id_extension,
        configuration.input_watermark_extension,
        configuration.encoder_timing_extension,
      };
      std::array<InboundSecurityStream, 3> security_streams {};
      std::size_t security_stream_count = 0;
      security_streams[security_stream_count++] = {
        .encrypted_extensions = encrypted_extensions,
        .ssrc = configuration.primary_ssrc,
        .encrypted_extension_count = encrypted_extensions.size(),
      };
      if (configuration.flexfec_ssrc != 0) {
        security_streams[security_stream_count++] = {
          .ssrc = configuration.flexfec_ssrc,
        };
      }
      if (configuration.rtx_ssrc != 0) {
        security_streams[security_stream_count++] = {
          .encrypted_extensions = encrypted_extensions,
          .ssrc = configuration.rtx_ssrc,
          .encrypted_extension_count = encrypted_extensions.size(),
        };
      }
      pthread_mutex_unlock(&mutex_);
      const auto security_status = install_inbound_security_streams(
        std::span<const InboundSecurityStream> {security_streams}.first(security_stream_count)
      );
      pthread_mutex_lock(&mutex_);
      if (security_status != CLSP_STATUS_OK) {
        video_reassembler_.reset();
        video_reassembly_slices_.reset();
        (void)video_receive_pool_.clear();
        release_retained_frame_pool(pool);
        rollback_media_identifiers_locked(ssrc_count, payload_type_count);
        pthread_mutex_unlock(&mutex_);
        return security_status;
      }
      if (!video_decoder_credit_.configure(configuration.decoder_surfaces)) {
        video_reassembler_.reset();
        video_reassembly_slices_.reset();
        (void)video_receive_pool_.clear();
        release_retained_frame_pool(pool);
        rollback_media_identifiers_locked(ssrc_count, payload_type_count);
        pthread_mutex_unlock(&mutex_);
        return CLSP_STATUS_INVALID_CONFIGURATION;
      }
      video_configuration_ = configuration;
      video_current_recovery_epoch_ = configuration.recovery_epoch;
      video_frame_pool_ = pool;
      video_metadata_ = {};
      delivered_video_frames_ = {};
      video_retired_frames_ = {};
      authenticated_video_fingerprints_ = {};
      authenticated_flexfec_fingerprints_ = {};
      authenticated_rtx_fingerprints_ = {};
      authenticated_video_sources_ = {};
      pending_flexfec_repairs_ = {};
      pending_video_nack_ = {};
      video_nack_retries_ = {};
      if (!video_source_replay_.reset(configuration.primary_ssrc, configuration.video_generation) ||
          !video_gap_tracker_.reset(
            configuration.primary_ssrc,
            configuration.video_generation,
            configuration_.profile == CLSP_PROFILE_COMPETITION_LAN ?
              competition_reorder_delay_microseconds :
              adaptive_reorder_delay_microseconds
          )) {
        video_reassembler_.reset();
        video_reassembly_slices_.reset();
        (void)video_receive_pool_.clear();
        video_frame_pool_ = nullptr;
        release_retained_frame_pool(pool);
        rollback_media_identifiers_locked(ssrc_count, payload_type_count);
        pthread_mutex_unlock(&mutex_);
        return CLSP_STATUS_INTERNAL_FAILURE;
      }
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
      video_recovery_feedback_pending_ = false;
      video_recovery_evidence_watermark_ = 0;
      last_recovery_lspv_microseconds_ = 0;
      authenticated_repair_abuse_window_start_ = 0;
      authenticated_repair_abuse_count_ = 0;
      video_delivery_active_.store(false, std::memory_order_release);
      last_authenticated_inbound_microseconds_.store(0U, std::memory_order_release);
      video_feedback_.reset(monotonic_microseconds());
      flexfec_feedback_.reset(monotonic_microseconds());
      rtx_feedback_.reset(monotonic_microseconds());
      video_reception_.reset();
      flexfec_reception_.reset();
      rtx_reception_.reset();
      feedback_sequence_initialized_ = false;
      feedback_largest_extended_sequence_ = 0;
      flexfec_feedback_sequence_initialized_ = false;
      flexfec_feedback_largest_extended_sequence_ = 0;
      rtx_feedback_sequence_initialized_ = false;
      rtx_feedback_largest_extended_sequence_ = 0;
      compound_rtcp_sent_ = false;
      last_compound_rtcp_microseconds_ = 0;
      pending_rtcp_ = {};
      path_discovery_enabled_.store(false, std::memory_order_release);
      outbound_path_probe_ = {};
      inbound_path_probe_intent_ = {};
      unmatched_path_probe_ = {};
      path_probe_notification_pending_ = false;
      emitted_path_probe_id_.store(0, std::memory_order_release);
      emitted_path_probe_size_.store(0, std::memory_order_release);
      pending_path_ack_id_.store(0, std::memory_order_release);
      pending_path_probe_event_count_ = 0;
      path_intent_message_id_ = 0;
      path_intent_request_id_ = 0;
      path_intent_probe_id_ = 0;
      path_intent_probe_size_ = 0;
      path_intent_control_ = {};
      lspv_coalescer_ = {};
      video_configured_.store(true, std::memory_order_release);
      pthread_mutex_unlock(&mutex_);
      return CLSP_STATUS_OK;
#else
      (void)configuration;
      return CLSP_STATUS_UNSUPPORTED;
#endif
    }

    /** @brief Open retained complete-frame delivery only after the semantic ACK crossed DTLS. */
    [[nodiscard]] clsp_status_t activate_video(const std::uint32_t video_generation) noexcept {
#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      if (!video_configured_.load(std::memory_order_acquire)) {
        return CLSP_STATUS_INVALID_STATE;
      }
      pthread_mutex_lock(&mutex_);
      const auto matches = video_configured_.load(std::memory_order_acquire) &&
                           video_configuration_.video_generation == video_generation;
      if (matches) {
        last_authenticated_inbound_microseconds_.store(monotonic_microseconds(), std::memory_order_release);
        video_delivery_active_.store(true, std::memory_order_release);
      }
      pthread_mutex_unlock(&mutex_);
      if (!matches) {
        return CLSP_STATUS_INVALID_ARGUMENT;
      }
      wake_worker();
      return CLSP_STATUS_OK;
#else
      (void) video_generation;
      return CLSP_STATUS_UNSUPPORTED;
#endif
    }

    /** @brief Enable native DPLPMTUD after video and input mappings are installed. */
    [[nodiscard]] clsp_status_t start_path_discovery() noexcept {
#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      if (!authenticated_.load(std::memory_order_acquire) ||
          !video_configured_.load(std::memory_order_acquire) || !input_configured_ || !path_mtu_) {
        return CLSP_STATUS_INVALID_STATE;
      }
      path_discovery_enabled_.store(true, std::memory_order_release);
      last_path_raise_microseconds_ = monotonic_microseconds();
      wake_worker();
      return CLSP_STATUS_OK;
#else
      return CLSP_STATUS_UNSUPPORTED;
#endif
    }

    /** @brief Queue one reliable client intent that gates exact-size LSPP submission. */
    [[nodiscard]] clsp_status_t send_path_probe(
      const std::uint64_t probe_id,
      const std::uint16_t udp_payload_size,
      const std::uint64_t request_id,
      const clsp_const_byte_span_t payload,
      const std::uint32_t deadline_milliseconds
    ) noexcept {
#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      if (!authenticated_.load(std::memory_order_acquire)) {
        return CLSP_STATUS_NOT_AUTHENTICATED;
      }
      if (probe_id == 0 || request_id == 0 || udp_payload_size < 1'200U ||
          deadline_milliseconds < 20U || deadline_milliseconds > 60'000U ||
          payload.length > maximum_control_payload || (payload.data == nullptr && payload.length != 0)) {
        return CLSP_STATUS_INVALID_ARGUMENT;
      }
      pthread_mutex_lock(&mutex_);
      const auto emitted_probe_id = emitted_path_probe_id_.load(std::memory_order_acquire);
      const auto emitted_probe_size = emitted_path_probe_size_.load(std::memory_order_acquire);
      const auto queue_full = control_queue_full_locked();
      if (emitted_probe_id != probe_id || emitted_probe_size != udp_payload_size || queue_full) {
        pthread_mutex_unlock(&mutex_);
        return queue_full ? CLSP_STATUS_CONTROL_WINDOW_FULL : CLSP_STATUS_INVALID_STATE;
      }
      auto &command = control_queue_[control_queue_tail_];
      command.message_type = 0x0300U;
      command.request_id = request_id;
      command.flags = static_cast<std::uint8_t>(lumen::lsp::lspc_flag::acknowledgement_required);
      command.response = false;
      command.activate_microphone = false;
      command.transmit_path_probe = true;
      command.path_probe_id = probe_id;
      command.path_probe_size = udp_payload_size;
      command.payload.assign(std::span<const std::uint8_t> {payload.data, payload.length});
      const auto now = monotonic_microseconds();
      const auto duration = static_cast<std::uint64_t>(deadline_milliseconds) * 1'000U;
      command.deadline_microseconds = saturating_add(now, duration);
      control_queue_tail_ = (control_queue_tail_ + 1U) % control_queue_capacity;
      ++queued_control_count_;
      pthread_mutex_unlock(&mutex_);
      wake_worker();
      return CLSP_STATUS_OK;
#else
      (void) probe_id;
      (void) udp_payload_size;
      (void) request_id;
      (void) payload;
      (void) deadline_milliseconds;
      return CLSP_STATUS_UNSUPPORTED;
#endif
    }

    /** @brief Retain one authenticated host intent and match one reordered LSPP record. */
    [[nodiscard]] clsp_status_t accept_path_probe(
      const std::uint64_t probe_id,
      const std::uint16_t udp_payload_size,
      const std::uint64_t request_id
    ) noexcept {
#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      if (probe_id == 0 || request_id == 0 || udp_payload_size < 1'200U || !path_mtu_ ||
          udp_payload_size > path_mtu_->ceiling_payload_bytes()) {
        return CLSP_STATUS_INVALID_ARGUMENT;
      }
      pthread_mutex_lock(&mutex_);
      if (inbound_path_probe_intent_.occupied &&
          (inbound_path_probe_intent_.probe_id != probe_id ||
           inbound_path_probe_intent_.udp_payload_size != udp_payload_size ||
           inbound_path_probe_intent_.request_id != request_id)) {
        pthread_mutex_unlock(&mutex_);
        return CLSP_STATUS_INVALID_STATE;
      }
      inbound_path_probe_intent_ = {
        .probe_id = probe_id,
        .request_id = request_id,
        .received_microseconds = monotonic_microseconds(),
        .udp_payload_size = udp_payload_size,
        .occupied = true,
      };
      if (unmatched_path_probe_.occupied && unmatched_path_probe_.probe_id == probe_id &&
          unmatched_path_probe_.udp_payload_size == udp_payload_size) {
        if (!queue_path_probe_event_locked(CLSP_PATH_PROBE_RECEIVED, probe_id, udp_payload_size, request_id)) {
          pthread_mutex_unlock(&mutex_);
          return CLSP_STATUS_RESOURCE_EXHAUSTED;
        }
        unmatched_path_probe_ = {};
        inbound_path_probe_intent_ = {};
        last_received_probe_id_ = probe_id;
        last_received_probe_size_ = udp_payload_size;
        // Publish the same proved receive ceiling when the protected probe
        // arrived before its coarse control-intent callback. Otherwise ACKing
        // this match makes the host send packets that we still reject as large.
        receive_udp_payload_size_.store(udp_payload_size, std::memory_order_release);
      }
      pthread_mutex_unlock(&mutex_);
      wake_worker();
      return CLSP_STATUS_OK;
#else
      (void) probe_id;
      (void) udp_payload_size;
      (void) request_id;
      return CLSP_STATUS_UNSUPPORTED;
#endif
    }

    /** @brief Commit one exact client-initiated ACK and advance confirmed PMTU. */
    [[nodiscard]] clsp_status_t confirm_path_probe(
      const std::uint64_t probe_id,
      const std::uint16_t received_payload_size
    ) noexcept {
#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      if (probe_id == 0 || received_payload_size < 1'200U || received_payload_size > maximum_udp_payload) {
        return CLSP_STATUS_INVALID_ARGUMENT;
      }
      pending_path_ack_size_.store(received_payload_size, std::memory_order_release);
      auto expected = std::uint64_t {0};
      if (!pending_path_ack_id_.compare_exchange_strong(expected, probe_id, std::memory_order_acq_rel) &&
          expected != probe_id) {
        return CLSP_STATUS_INVALID_STATE;
      }
      wake_worker();
      return CLSP_STATUS_OK;
#else
      (void) probe_id;
      (void) received_payload_size;
      return CLSP_STATUS_UNSUPPORTED;
#endif
    }

    /** @brief Return the authenticated confirmed UDP payload ceiling. */
    [[nodiscard]] std::uint16_t current_udp_payload_size() const noexcept {
      return current_udp_payload_size_.load(std::memory_order_acquire);
    }

    [[nodiscard]] std::uint16_t current_receive_udp_payload_size() const noexcept {
      return receive_udp_payload_size_.load(std::memory_order_acquire);
    }

    /** @brief Copy the exact authenticated exporter for native pairing transcript binding. */
    [[nodiscard]] clsp_status_t copy_pairing_exporter(
      const std::span<std::uint8_t, 32> output
    ) const noexcept {
      if (!authenticated_.load(std::memory_order_acquire) || !dtls_.authenticated()) {
        return CLSP_STATUS_NOT_AUTHENTICATED;
      }
      std::copy(dtls_.pairing_exporter().begin(), dtls_.pairing_exporter().end(), output.begin());
      return CLSP_STATUS_OK;
    }

    /** @brief Return the published authenticated SERVER_HELLO generation. */
    [[nodiscard]] std::uint32_t current_connection_generation() const noexcept {
      return authenticated_connection_generation_.load(std::memory_order_acquire);
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
      auto *delivered = find_delivered_video_frame(frame_id, recovery_epoch);
      if (video_generation != video_configuration_.video_generation || delivered == nullptr ||
          frame_id == 0 || frame_id > video_largest_complete_frame_id_ ||
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
      *delivered = {};
      (void)video_decoder_credit_.release();
      video_render_mailbox_occupancy_ = render_mailbox_occupancy;
      const auto typed_status =
        static_cast<lumen::lsp::transport::lspv_decoder_status>(decoder_status);
      if (typed_status == lumen::lsp::transport::lspv_decoder_status::ready) {
        video_largest_decoded_frame_id_ =
          std::max(video_largest_decoded_frame_id_, frame_id);
      }
      const auto current_epoch = recovery_epoch == video_current_recovery_epoch_;
      const auto decoder_error =
        typed_status == lumen::lsp::transport::lspv_decoder_status::recoverable_error ||
        typed_status == lumen::lsp::transport::lspv_decoder_status::unrecoverable_error;
      const auto recovery_relevant_error =
        current_epoch && decoder_error && frame_id > video_largest_decoded_frame_id_;
      const auto decode_event_relevant = current_epoch && (!decoder_error || recovery_relevant_error);
      if (current_epoch && typed_status == lumen::lsp::transport::lspv_decoder_status::ready &&
          video_recovery_feedback_pending_ && frame_id > video_recovery_evidence_watermark_) {
        video_recovery_feedback_pending_ = false;
        video_recovery_evidence_watermark_ = 0;
        video_deadline_miss_latched_ = false;
      } else if (recovery_relevant_error) {
        video_recovery_feedback_pending_ = true;
        video_recovery_evidence_watermark_ =
          std::max(video_recovery_evidence_watermark_, video_largest_decoded_frame_id_);
      }
      const auto status = current_lspv_status(
        decode_event_relevant ? typed_status : current_decoder_capacity_status()
      );
      const auto update = lspv_coalescer_.update(
        status,
        decode_event_relevant ? lumen::lsp::transport::lspv_event::decode_completion :
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
      const auto decoder_status = current_decoder_capacity_status();
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
      if (input_configured_) {
        const auto status = same_input_configuration(input_configuration_, configuration) ?
                              CLSP_STATUS_OK :
                              CLSP_STATUS_INVALID_STATE;
        pthread_mutex_unlock(&mutex_);
        return status;
      }
      if (input_configuration_pending_) {
        pthread_mutex_unlock(&mutex_);
        return CLSP_STATUS_INVALID_STATE;
      }
      const std::array<std::uint32_t, 2> ssrcs {
        configuration.input_ssrc,
        configuration.acknowledgement_ssrc,
      };
      const std::array<std::uint8_t, 1> payload_types {configuration.input_payload_type};
      if (!reserve_media_identifiers_locked(ssrcs, payload_types)) {
        pthread_mutex_unlock(&mutex_);
        return CLSP_STATUS_INVALID_CONFIGURATION;
      }
      pthread_mutex_unlock(&mutex_);
      const std::array<InboundSecurityStream, 1> security_streams {
        InboundSecurityStream {.ssrc = configuration.acknowledgement_ssrc},
      };
      const auto security_status = install_inbound_security_streams(security_streams);
      pthread_mutex_lock(&mutex_);
      if (security_status != CLSP_STATUS_OK) {
        rollback_media_identifiers_locked(ssrcs.size(), payload_types.size());
        pthread_mutex_unlock(&mutex_);
        return security_status;
      }
      pending_input_configuration_ = configuration;
      pending_baseline_id_ = 0;
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
    [[nodiscard]] clsp_status_t update_input_rates(const clsp_input_rate_update_t &update) noexcept {
#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      if (!authenticated_.load(std::memory_order_acquire)) return CLSP_STATUS_NOT_AUTHENTICATED;
      if (update.abi_version != CLSP_CORE_ABI_VERSION || update.structure_size != sizeof(update) ||
          update.stream_generation == 0U || update.input_generation == 0U ||
          update.pointer_rate < 125U || update.pointer_rate > 16'000U ||
          update.controller_rate < 125U || update.controller_rate > 2'000U ||
          update.sensor_rate < 125U || update.sensor_rate > 4'000U ||
          update.reconciliation_rate < 50U || update.reconciliation_rate > 1'000U ||
          update.reserved_input_wire_bits_per_second == 0U ||
          update.reserved_input_wire_bits_per_second > 32'000'000U) return CLSP_STATUS_INVALID_CONFIGURATION;
      pthread_mutex_lock(&mutex_);
      if (!input_configured_ || pending_input_rate_update_ ||
          update.stream_generation != input_configuration_.stream_generation ||
          update.input_generation != input_configuration_.input_generation) {
        pthread_mutex_unlock(&mutex_);
        return CLSP_STATUS_INVALID_STATE;
      }
      pending_input_rates_ = update;
      const auto token = input_rate_update_requested_.fetch_add(1U, std::memory_order_acq_rel) + 1U;
      pending_input_rate_token_ = token;
      pending_input_rate_update_ = true;
      pthread_mutex_unlock(&mutex_);
      wake_worker();
      timespec deadline {};
      if (clock_gettime(CLOCK_REALTIME, &deadline) != 0) return CLSP_STATUS_INTERNAL_FAILURE;
      deadline.tv_nsec += 100'000'000L;
      if (deadline.tv_nsec >= 1'000'000'000L) { ++deadline.tv_sec; deadline.tv_nsec -= 1'000'000'000L; }
      pthread_mutex_lock(&mutex_);
      while (input_rate_update_completed_.load(std::memory_order_acquire) < token) {
        const auto wait = pthread_cond_timedwait(&condition_, &mutex_, &deadline);
        if (wait == ETIMEDOUT) { pthread_mutex_unlock(&mutex_); return CLSP_STATUS_TIMEOUT; }
        if (wait != 0) { pthread_mutex_unlock(&mutex_); return CLSP_STATUS_INTERNAL_FAILURE; }
      }
      pthread_mutex_unlock(&mutex_);
      return CLSP_STATUS_OK;
#else
      (void)update;
      return CLSP_STATUS_UNSUPPORTED;
#endif
    }

    [[nodiscard]] clsp_status_t copy_input_feedback(clsp_input_feedback_snapshot_t &output) noexcept {
#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      pthread_mutex_lock(&mutex_);
      output = input_feedback_snapshot_;
      pthread_mutex_unlock(&mutex_);
      return output.abi_version == CLSP_CORE_ABI_VERSION ? CLSP_STATUS_OK : CLSP_STATUS_INVALID_STATE;
#else
      (void)output;
      return CLSP_STATUS_UNSUPPORTED;
#endif
    }

    [[nodiscard]] clsp_status_t copy_input_edge_snapshot(clsp_input_edge_snapshot_t &output) const noexcept {
      const auto stream_generation = published_stream_generation_.load(std::memory_order_acquire);
      const auto input_generation = published_input_generation_.load(std::memory_order_acquire);
      if (stream_generation == 0U || input_generation == 0U) return CLSP_STATUS_INVALID_STATE;
      output = {
        .abi_version = CLSP_CORE_ABI_VERSION,
        .structure_size = sizeof(clsp_input_edge_snapshot_t),
        .stream_generation = stream_generation,
        .input_generation = input_generation,
        .latest_assigned_edge_id = published_latest_edge_id_.load(std::memory_order_acquire),
        .latest_edge_sample_time_microseconds = published_latest_edge_time_.load(std::memory_order_acquire),
      };
      return CLSP_STATUS_OK;
    }

    /** @brief Publish one native device generation for the next deterministic baseline. */
    void observe_input_device(
      const std::uint8_t device_type,
      const std::uint32_t device_id,
      const std::uint32_t instance_generation,
      const bool active,
      const std::uint8_t sensor_mask
    ) noexcept {
      if (instance_generation == 0U) return;
      const auto device = static_cast<lumen::lsp::input_plane::device_type>(device_type);
      if (device == lumen::lsp::input_plane::device_type::pointer && device_id == 1U) {
        if (active) {
          const auto prior = pointer_drop_generation_.exchange(instance_generation, std::memory_order_acq_rel);
          if (prior != instance_generation) {
            pointer_dropped_samples_.store(0U, std::memory_order_release);
            pointer_attributed_wire_bytes_.store(0U, std::memory_order_release);
          }
          published_pointer_generation_.store(instance_generation, std::memory_order_release);
        } else if (published_pointer_generation_.load(std::memory_order_acquire) == instance_generation) {
          published_pointer_generation_.store(0U, std::memory_order_release);
        }
        return;
      }
      if (device_id > 16U) return;
      const auto index = device_id - 1U;
      if (device == lumen::lsp::input_plane::device_type::controller) {
        if (active) {
          const auto prior = controller_drop_generations_[index].exchange(instance_generation, std::memory_order_acq_rel);
          if (prior != instance_generation) {
            controller_dropped_samples_[index].store(0U, std::memory_order_release);
            controller_attributed_wire_bytes_[index].store(0U, std::memory_order_release);
          }
          published_controller_sensor_masks_[index].store(sensor_mask, std::memory_order_release);
          published_controller_generations_[index].store(instance_generation, std::memory_order_release);
        } else if (published_controller_generations_[index].load(std::memory_order_acquire) == instance_generation) {
          published_controller_sensor_masks_[index].store(0U, std::memory_order_release);
          published_controller_generations_[index].store(0U, std::memory_order_release);
        }
        return;
      }
      auto *generations = device == lumen::lsp::input_plane::device_type::touch ?
                            &published_touch_generations_ :
                            device == lumen::lsp::input_plane::device_type::pen ?
                              &published_pen_generations_ : nullptr;
      if (generations == nullptr) return;
      if (active) {
        (*generations)[index].store(instance_generation, std::memory_order_release);
      } else if ((*generations)[index].load(std::memory_order_acquire) == instance_generation) {
        (*generations)[index].store(0U, std::memory_order_release);
      }
    }

    /** @brief Return cumulative ring drops for one exact device generation. */
    [[nodiscard]] std::uint64_t input_dropped_samples(
      const std::uint8_t offer_type,
      const std::uint32_t device_id,
      const std::uint32_t instance_generation
    ) const noexcept {
      if (offer_type == CLSP_DEVICE_OFFER_POINTER && device_id == 1U &&
          pointer_drop_generation_.load(std::memory_order_acquire) == instance_generation) {
        return pointer_dropped_samples_.load(std::memory_order_acquire);
      }
      if (offer_type == CLSP_DEVICE_OFFER_CONTROLLER && device_id >= 1U && device_id <= 16U) {
        const auto index = device_id - 1U;
        if (controller_drop_generations_[index].load(std::memory_order_acquire) == instance_generation) {
          return controller_dropped_samples_[index].load(std::memory_order_acquire);
        }
      }
      return 0U;
    }

    /** @brief Return attributable state/sensor complete IP bytes for one exact generation. */
    [[nodiscard]] std::uint64_t input_attributed_wire_bytes(
      const std::uint8_t offer_type,
      const std::uint32_t device_id,
      const std::uint32_t instance_generation
    ) const noexcept {
      if (offer_type == CLSP_DEVICE_OFFER_POINTER && device_id == 1U &&
          pointer_drop_generation_.load(std::memory_order_acquire) == instance_generation) {
        return pointer_attributed_wire_bytes_.load(std::memory_order_acquire);
      }
      if (offer_type == CLSP_DEVICE_OFFER_CONTROLLER && device_id >= 1U && device_id <= 16U) {
        const auto index = device_id - 1U;
        if (controller_drop_generations_[index].load(std::memory_order_acquire) == instance_generation) {
          return controller_attributed_wire_bytes_[index].load(std::memory_order_acquire);
        }
      }
      return 0U;
    }

    /** @brief Queue one bounded relative-pointer record. */
    [[nodiscard]] clsp_status_t submit_pointer(const clsp_pointer_sample_t &sample) noexcept {
#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      if (!authenticated_.load(std::memory_order_acquire) || sample.sample_time_microseconds == 0) {
        return sample.sample_time_microseconds == 0 ? CLSP_STATUS_INVALID_ARGUMENT : CLSP_STATUS_NOT_AUTHENTICATED;
      }
      CaptureRecord record {
        .kind = CaptureKind::pointer,
        .pointer = sample,
        .device_generation = std::max<std::uint32_t>(
          1U,
          published_pointer_generation_.load(std::memory_order_acquire)
        ),
      };
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
      CaptureRecord record {
        .kind = CaptureKind::edge,
        .edge = edge,
        .device_generation = pointer ? std::max<std::uint32_t>(
          1U,
          published_pointer_generation_.load(std::memory_order_acquire)
        ) : 1U,
      };
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
      if (edge.kind == 5U) {
        observe_input_device(
          3U,
          edge.controller_id,
          edge.instance_generation,
          true,
          published_controller_sensor_masks_[edge.controller_id - 1U].load(std::memory_order_acquire)
        );
      } else if (edge.kind == 6U) {
        observe_input_device(4U, edge.controller_id, edge.instance_generation, false, 0U);
        observe_input_device(3U, edge.controller_id, edge.instance_generation, false, 0U);
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
      const auto sensor_index = sensor.controller_id - 1U;
      published_controller_sensor_masks_[sensor_index].fetch_or(
        static_cast<std::uint8_t>(1U << (sensor.sensor_type - 1U)),
        std::memory_order_acq_rel
      );
      CaptureRecord record {
        .kind = CaptureKind::controller_sensor,
        .controller_sensor = sensor,
        .timestamp_unknown = true,
      };
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
      if (edge.kind == 9U) {
        observe_input_device(4U, edge.controller_id, edge.instance_generation, true, 0U);
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
      if (!authenticated_.load(std::memory_order_acquire) ||
          input_configuration_completed_.load(std::memory_order_acquire) == 0U) {
        capture_accepting_ = false;
        capture_read_.store(capture_write_.load(std::memory_order_acquire), std::memory_order_release);
        return CLSP_STATUS_OK;
      }
      const auto token = neutralize_requested_.fetch_add(1, std::memory_order_acq_rel) + 1U;
      CaptureRecord record {.kind = CaptureKind::neutralize, .neutralize_token = token};
      auto queued = enqueue_capture(record);
      for (std::uint32_t attempt = 0; queued == CLSP_STATUS_RESOURCE_EXHAUSTED && attempt < 1'000U; ++attempt) {
        wake_worker();
        usleep(100);
        queued = enqueue_capture(record);
      }
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

    /** @brief Idempotently quiesce input from every runtime lifecycle state. */
    [[nodiscard]] clsp_status_t quiesce_input() noexcept {
      return neutralize_input();
    }

    /** @brief Restart the unchanged mapping with one exact fresh neutral baseline. */
    [[nodiscard]] clsp_status_t restart_input_baseline(const std::uint64_t baseline_id) noexcept {
#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      if (baseline_id == 0U) {
        return CLSP_STATUS_INVALID_ARGUMENT;
      }
      if (!authenticated_.load(std::memory_order_acquire)) {
        return CLSP_STATUS_NOT_AUTHENTICATED;
      }
      pthread_mutex_lock(&mutex_);
      if (!input_configured_ || input_configuration_pending_ || capture_accepting_.load(std::memory_order_acquire)) {
        pthread_mutex_unlock(&mutex_);
        return CLSP_STATUS_INVALID_STATE;
      }
      pending_input_configuration_ = input_configuration_;
      pending_baseline_id_ = baseline_id;
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
      (void)baseline_id;
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
      bool transmit_path_probe {};  ///< Submit exact-size LSPP only after this intent is sent.
      std::uint64_t path_probe_id {};  ///< Logical LSPP probe ID.
      std::uint16_t path_probe_size {};  ///< Exact protected UDP probe size.
    };

    /** @brief One invisible control queue reservation owned by an atomic handoff submit. */
    struct ControlReservation {
      ControlCommand command {};  ///< Immutable copied request awaiting publication.
      std::uint64_t token {};  ///< Nonzero reservation incarnation.
      bool occupied {};  ///< Whether one queue slot is reserved.
    };

    /** @brief Return whether published plus invisible commands exhaust bounded capacity. */
    [[nodiscard]] bool control_queue_full_locked() const noexcept {
      return queued_control_count_ + static_cast<std::size_t>(control_reservation_.occupied) >=
             control_queue_capacity;
    }

    /** @brief One retained authenticated host request awaiting a semantic response. */
    struct PendingInboundRequest {
      std::uint64_t request_id {};  ///< Nonzero host request ID.
      lumen::lsp::response_semantic_identity identity {};  ///< Exact cache discriminator.
      lumen::lsp::packet_slab<maximum_control_frame> frame {};  ///< Exact original LSPC bytes.
      bool occupied {};  ///< Whether this slot is live.
    };

    /** @brief One exact inbound libSRTP stream install descriptor. */
    struct InboundSecurityStream {
      std::array<int, 3> encrypted_extensions {};  ///< Optional RFC 6904 extension IDs.
      std::uint32_t ssrc {};  ///< Nonzero negotiated inbound SSRC.
      std::size_t encrypted_extension_count {};  ///< Populated encrypted-extension IDs.
    };

    /** @brief One synchronous provider mutation owned by the socket thread. */
    struct PendingInboundSecurityInstall {
      std::array<InboundSecurityStream, 3> streams {};  ///< One audio/ACK or three video streams.
      std::uint64_t token {};  ///< Monotonic synchronous request identity.
      clsp_status_t result {CLSP_STATUS_TIMEOUT};  ///< Worker-completed provider result.
      std::size_t stream_count {};  ///< Populated stream descriptors.
      bool pending {};  ///< Whether the socket owner must execute the request.
      bool awaiting_result {};  ///< Whether the synchronous caller still owns the result.
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
      std::uint32_t device_generation {};  ///< Pointer/keyboard generation absent from their compact ABI records.
      bool timestamp_unknown {};  ///< Timestamp begins at callback entry instead of device delivery.
    };

    /** @brief Worker-owned latest controller analog state. */
    struct ControllerLatest {
      clsp_controller_state_t value {};  ///< Latest captured value.
      std::uint64_t physical_ordinal {};  ///< Increasing native sample ordinal.
      std::uint64_t buttons {};  ///< Current exactly-once digital-button bitmap.
      std::uint64_t composed_microseconds {};  ///< Worker composition time for the newest state.
      std::uint64_t last_sent_us {};  ///< Most recent network submission.
      bool dirty {};  ///< Whether a newer sample awaits submission.
    };

    /** @brief Worker-owned latest controller sensor state. */
    struct ControllerSensorLatest {
      clsp_controller_sensor_t value {};  ///< Latest captured vector.
      std::uint64_t physical_ordinal {};  ///< Increasing native sample ordinal.
      std::uint64_t composed_microseconds {};  ///< Worker composition time for the newest vector.
      std::uint64_t last_sent_us {};  ///< Most recent network submission.
      bool dirty {};  ///< Whether a newer vector awaits submission.
    };

    /** @brief Worker-owned latest controller touch coordinates. */
    struct TouchLatest {
      clsp_controller_touch_state_t value {};  ///< Latest captured contact.
      std::uint64_t physical_ordinal {};  ///< Increasing contact sample ordinal.
      std::uint64_t composed_microseconds {};  ///< Worker composition time for the newest contact state.
      std::uint64_t last_sent_us {};  ///< Most recent network submission.
      bool active {};  ///< Whether the contact belongs in the latest touch state.
      bool dirty {};  ///< Whether newer coordinates await submission.
    };

    /** @brief Fixed correlation for one exactly-once edge through authenticated host ACK. */
    struct EdgeTimingSlot {
      std::uint64_t edge_id {};  ///< Exact edge identity occupying this modulo slot.
      std::uint64_t composed_microseconds {};  ///< Worker composition time.
      std::uint64_t first_submitted_microseconds {};  ///< First successful socket submission.
      std::uint64_t last_submitted_microseconds {};  ///< Most recent retry submission.
      std::uint8_t transmissions {};  ///< Saturating successful submissions.
      bool occupied {};  ///< Whether authenticated host acknowledgement remains pending.
    };

    /** @brief Boundary metadata retained for either of the two incomplete video frames. */
    struct VideoFrameMetadata {
      bool occupied {};  ///< Whether this slot tracks a provisional RTP frame.
      lumen::lsp::media::frame_key key {};  ///< SSRC plus extended timestamp key.
      std::uint64_t deadline_microseconds {};  ///< Fixed deadline shared by every fragment.
      std::uint64_t first_authenticated_microseconds {};  ///< Earliest local SRTP-auth completion in the frame.
      std::uint64_t arrival_order {};  ///< Oldest-frame bounded eviction order.
      std::uint64_t frame_id {};  ///< Repeated nonzero frame identifier when observed.
      std::uint32_t recovery_epoch {};  ///< Repeated nonzero recovery epoch when observed.
      std::uint64_t capture_time_microseconds {};  ///< Repeated absolute capture time when observed.
      std::uint64_t input_state_sequence {};  ///< Repeated applied state watermark.
      std::uint64_t input_edge_id {};  ///< Repeated applied edge watermark.
      std::uint16_t start_sequence_number {};  ///< RTP sequence carrying authenticated frame start.
      bool has_capture_time {};  ///< Whether capture time has been bound.
      bool has_input_watermark {};  ///< Whether the input watermark has been bound.
      bool has_independent_marking {};  ///< Whether independence metadata has been bound.
      bool has_start_sequence {};  ///< Whether the authenticated start sequence is bound.
      bool independent {};  ///< Whether any repeated frame marking says independent.
    };

    /** @brief Exact native-to-Swift frame tuple retained until terminal decode reporting. */
    struct DeliveredVideoFrame {
      std::uint64_t frame_id {};  ///< Nonzero delivered frame identifier.
      std::uint32_t recovery_epoch {};  ///< Authenticated per-frame recovery epoch.
      bool independent {};  ///< Authenticated independent-frame marking.
      bool occupied {};  ///< Whether this decoder-credit slot awaits a terminal report.
    };

    /** @brief Recently retired frame key preventing late-packet resurrection. */
    struct VideoRetiredFrame {
      bool occupied {};  ///< Whether a key is retained.
      lumen::lsp::media::frame_key key {};  ///< Completed, expired, or evicted frame key.
      VideoRetirementReason reason {VideoRetirementReason::malformed};  ///< Terminal retirement classification.
      std::uint64_t frame_id {};  ///< Bound authenticated frame ID, or zero when not yet known.
      std::uint32_t recovery_epoch {};  ///< Bound authenticated epoch, or zero when not yet known.
      std::uint64_t retirement_order {};  ///< Bounded oldest-key replacement order.
    };

    /** @brief One authenticated host PATH_PROBE intent awaiting exact LSPP. */
    struct InboundPathProbeIntent {
      std::uint64_t probe_id {};  ///< Nonzero authenticated intent ID.
      std::uint64_t request_id {};  ///< Reliable host request ID.
      std::uint64_t received_microseconds {};  ///< Intent retention origin.
      std::uint16_t udp_payload_size {};  ///< Exact expected protected datagram size.
      bool occupied {};  ///< Whether one intent is live.
    };

    /** @brief One authenticated LSPP retained across intent/probe UDP reordering. */
    struct UnmatchedPathProbe {
      std::uint64_t probe_id {};  ///< Validated probe ID.
      std::uint64_t received_microseconds {};  ///< Bounded retention origin.
      std::uint16_t udp_payload_size {};  ///< Exact received protected datagram size.
      bool occupied {};  ///< Whether one unmatched record is live.
    };

    /** @brief Exact protected client LSPP retained for immediate would-block retry. */
    struct OutboundPathProbePacket {
      std::array<std::uint8_t, maximum_udp_payload> bytes {};  ///< Protected SRTCP bytes.
      std::uint64_t probe_id {};  ///< Logical probe ID shared across timed attempts.
      std::uint64_t last_send_microseconds {};  ///< Last successful kernel submission.
      std::size_t length {};  ///< Exact protected datagram length.
      std::uint16_t udp_payload_size {};  ///< Candidate size.
      std::uint8_t attempts {};  ///< Successful timed submissions, at most three.
      bool pending_send {};  ///< Exact protected bytes await first/EAGAIN submission.
      bool active {};  ///< Probe timer remains live after successful submission.
    };

    /** @brief One protected compound or CCFB packet retained across immediate backpressure. */
    struct PendingProtectedRtcp {
      enum class Kind : std::uint8_t {
        none,  ///< No packet retained.
        compound,  ///< Regular RR plus SDES CNAME.
        congestion_feedback,  ///< Reduced-size RFC 8888 CCFB.
        lspv,  ///< Protected decoder/render status.
        microphone_report,  ///< Reverse microphone sender report.
      } kind {Kind::none};  ///< Retained packet semantic.
      std::array<std::uint8_t, maximum_udp_payload> bytes {};  ///< Exact protected bytes.
      native_feedback_write_result video_feedback {};  ///< Video commit watermark for CCFB.
      native_feedback_write_result flexfec_feedback {};  ///< FlexFEC commit watermark for CCFB.
      native_feedback_write_result rtx_feedback {};  ///< RTX commit watermark for CCFB.
      native_feedback_write_result audio_feedback {};  ///< Audio commit watermark for CCFB.
      std::size_t length {};  ///< Exact protected datagram length.
      std::uint64_t created_microseconds {};  ///< Report timestamp and successful commit time.
      std::uint32_t input_lsr {};  ///< Middle-NTP identity for a pending input SR.
      std::uint32_t microphone_lsr {};  ///< Middle-NTP identity for a pending microphone SR.

      /** @brief Return whether exact protected bytes await submission. */
      [[nodiscard]] explicit operator bool() const noexcept {
        return kind != Kind::none && length != 0;
      }
    };

    /** @brief One exact protected microphone RTP datagram retained across socket backpressure. */
    struct PendingProtectedMicrophone {
      std::array<std::uint8_t, maximum_udp_payload> bytes {};  ///< Immutable already-protected RTP bytes.
      std::size_t length {};  ///< Exact protected datagram length.
      std::size_t queue_index {};  ///< Source Opus queue slot committed only after send.
      std::size_t opus_bytes {};  ///< Source payload bytes for sender counters.
      std::uint64_t charged_bits {};  ///< Aggregate reverse-controller debit on success.
      std::uint64_t extended_sequence {};  ///< Exact RTP sequence incarnation retained for CCFB.
      std::uint32_t microphone_generation {};  ///< Generation owning this immutable packet.
      bool occupied {};  ///< Whether exact bytes await first/retry submission.
    };

    /** @brief Terminal RFC 8888 disposition for one successfully submitted microphone packet. */
    enum class MicrophoneFeedbackState : std::uint8_t {
      unreported,  ///< Final socket submission has no receiver disposition.
      lost,  ///< A valid report declared the packet lost.
      received,  ///< A valid report declared the packet received.
    };

    /** @brief Worker-owned sent-packet correlation retained for bounded microphone CCFB. */
    struct MicrophoneSentPacket {
      std::uint64_t extended_sequence {};  ///< Exact sequence incarnation, including wrap generation.
      std::uint64_t sent_microseconds {};  ///< Successful socket-submission time.
      std::uint32_t complete_ip_bytes {};  ///< Exact IP/UDP/protected-RTP byte count.
      std::uint32_t arrival_timestamp {};  ///< Reconstructed middle-NTP arrival timestamp.
      std::uint32_t microphone_generation {};  ///< Negotiated microphone generation.
      MicrophoneFeedbackState state {MicrophoneFeedbackState::unreported};  ///< Current overlap-safe disposition.
      std::uint8_t ecn {};  ///< Latest authenticated RFC 8888 ECN echo.
      bool arrival_timestamp_valid {};  ///< Whether a bounded ATO established arrival identity.
      bool occupied {};  ///< Whether this slot retains one successful send.
    };

    /** @brief Successful microphone SR timing retained for authenticated RR LSR/DLSR RTT. */
    struct MicrophoneSenderReportTiming {
      std::uint64_t sent_microseconds {};  ///< Final socket-submission time.
      std::uint32_t lsr {};  ///< Exact middle-NTP sender-report identity.
    };

    /** @brief Terminal feedback disposition for one protect-consumed input RTP sequence. */
    enum class InputFeedbackState : std::uint8_t {
      unreported,  ///< Successful socket submission has no receiver disposition.
      lost,  ///< A valid report declared a successful submission lost.
      received,  ///< A valid report declared a successful submission received.
      local_unsent,  ///< Protection consumed the sequence but no UDP datagram was submitted.
    };

    /** @brief O(1) generation-qualified input sent/tombstone correlation. */
    struct InputSentPacket {
      std::uint64_t extended_sequence {};  ///< Exact sequence incarnation across 16-bit wrap.
      std::uint64_t terminal_microseconds {};  ///< Successful send or local-unsent time.
      std::uint32_t complete_ip_bytes {};  ///< Exact successful IP bytes, zero for a tombstone.
      std::uint32_t arrival_timestamp {};  ///< Reconstructed middle-NTP arrival identity.
      std::uint32_t input_generation {};  ///< Negotiated input authority generation.
      InputFeedbackState state {InputFeedbackState::local_unsent};  ///< Current overlap-safe disposition.
      std::uint8_t ecn {};  ///< Latest authenticated RFC 8888 ECN echo.
      bool arrival_timestamp_valid {};  ///< Whether bounded ATO established arrival identity.
      bool occupied {};  ///< Whether this sequence value has a current incarnation.
    };

    /** @brief One protected video RTP datagram deferred behind urgent reverse work. */
    struct DeferredVideoDatagram {
      std::uint64_t token {};  ///< Original socket receive-slab root token.
      std::size_t length {};  ///< Protected datagram length.
      std::uint64_t arrival_microseconds {};  ///< Kernel monotonic arrival time.
      native_ecn_mark ecn {native_ecn_mark::unknown};  ///< Kernel ECN evidence.
      bool kernel_timestamped {};  ///< Whether monotonic kernel ancillary time was present.
    };

    /** @brief One urgent protected Generic NACK retained across socket backpressure. */
    struct PendingProtectedNack {
      std::array<std::uint8_t, maximum_udp_payload> bytes {};  ///< Exact protected reduced-size RTCP.
      std::array<std::uint16_t, maximum_video_gap_count> sequences {};  ///< Missing primary sequences named by the packet.
      std::array<std::uint64_t, maximum_video_gap_count> frame_deadlines {};  ///< Per-sequence strict RTX deadlines.
      std::size_t length {};  ///< Complete protected datagram length.
      std::size_t sequence_count {};  ///< Populated sequence identifiers.
      bool initial {};  ///< Whether gap tracker one-shot state is not yet committed.

      /** @brief Return whether one protected NACK awaits kernel submission. */
      [[nodiscard]] explicit operator bool() const noexcept {
        return length != 0 && sequence_count != 0;
      }
    };

    /** @brief One successfully submitted NACK eligible for bounded fresh-index repeats. */
    struct VideoNackRetry {
      std::uint64_t frame_deadline_microseconds {};  ///< Strict RTX arrival deadline.
      std::uint64_t next_retry_microseconds {};  ///< Earliest fresh SRTCP retry.
      std::uint16_t sequence_number {};  ///< Missing primary OSN.
      std::uint8_t attempts {};  ///< Successful NACK submissions, at most three.
      bool occupied {};  ///< Whether another retry may be useful.
    };

    /** @brief One exact protected controller command ACK retained across backpressure. */
    struct PendingControllerAck {
      std::array<std::uint8_t, maximum_udp_payload> bytes {};  ///< Exact protected SRTCP bytes.
      std::size_t length {};  ///< Protected datagram length.
      bool occupied {};  ///< Whether immediate retry remains pending.
    };

    /** @brief Bounded exact fingerprint of one previously authenticated SRTP packet. */
    struct AuthenticatedRtpFingerprint {
      std::array<std::uint8_t, 16> authentication_tag {};  ///< Exact AES-GCM tag from authenticated SRTP.
      std::uint64_t first_arrival_microseconds {};  ///< Earliest authenticated arrival.
      std::uint32_t ssrc {};  ///< Visible primary SSRC.
      std::uint32_t rtp_timestamp {};  ///< Authenticated RTP timestamp.
      std::uint16_t sequence {};  ///< RTP sequence number.
      std::uint16_t protected_bytes {};  ///< Exact protected UDP payload bytes.
      std::uint8_t first_header_byte {};  ///< Authenticated RTP flags/CSRC byte.
      std::uint8_t second_header_byte {};  ///< Authenticated marker/payload type byte.
      bool occupied {};  ///< Whether this ring slot is authenticated.
    };

    /** @brief One fixed-slot authenticated primary plaintext retained for FlexFEC decode. */
    struct AuthenticatedVideoSourcePacket {
      std::uint64_t frame_deadline_microseconds {};  ///< Protected frame repair deadline.
      std::uint64_t frame_id {};  ///< Bound frame identifier, or zero before repeated metadata.
      std::uint64_t slab_token {};  ///< Retained receive-pool slab token.
      std::uint32_t video_generation {};  ///< Active generation that authenticated the source.
      std::uint32_t rtp_timestamp {};  ///< Frame-local RTP timestamp.
      std::uint32_t recovery_epoch {};  ///< Bound source epoch, or zero before repeated metadata.
      std::size_t length {};  ///< Populated plaintext byte count.
      std::uint16_t sequence_number {};  ///< Primary RTP sequence.
      bool occupied {};  ///< Whether this fixed slot is live.
    };

    /** @brief One authenticated FlexFEC packet retained until decode or bounded expiry. */
    struct PendingFlexFecRepair {
      std::uint64_t expires_microseconds {};  ///< Negotiated repair-window expiry.
      std::uint64_t slab_token {};  ///< Retained receive-pool repair slab token.
      std::uint64_t source_mask {};  ///< Exact RFC 8627 protected-source mask.
      std::uint64_t bound_frame_id {};  ///< Bound source frame ID, or zero before metadata.
      std::uint32_t repair_timestamp {};  ///< Repair-stream RTP timestamp for diagnostics.
      std::uint32_t bound_rtp_timestamp {};  ///< Bound protected-source frame timestamp.
      std::uint32_t bound_recovery_epoch {};  ///< Epoch assigned when the frame association is known.
      std::size_t length {};  ///< Populated plaintext byte count.
      std::uint16_t repair_sequence_number {};  ///< Repair-stream replay identity.
      std::uint16_t base_sequence_number {};  ///< First source sequence represented by `source_mask`.
      bool frame_bound {};  ///< Whether source evidence established `bound_rtp_timestamp`.
      bool occupied {};  ///< Whether deterministic recovery remains possible.
    };

    /** @brief Atomically reserve globally unique RTP SSRC and dynamic PT identifiers. */
    [[nodiscard]] bool reserve_media_identifiers_locked(
      const std::span<const std::uint32_t> ssrcs,
      const std::span<const std::uint8_t> payload_types
    ) noexcept {
      if (reserved_ssrc_count_ + ssrcs.size() > reserved_ssrcs_.size() ||
          reserved_payload_type_count_ + payload_types.size() > reserved_payload_types_.size()) {
        return false;
      }
      const auto existing_ssrcs = std::span<const std::uint32_t> {reserved_ssrcs_}.first(reserved_ssrc_count_);
      for (std::size_t index = 0; index < ssrcs.size(); ++index) {
        if (ssrcs[index] == 0 ||
            std::ranges::find(existing_ssrcs, ssrcs[index]) != existing_ssrcs.end()) {
          return false;
        }
        const auto preceding = ssrcs.first(index);
        if (std::ranges::find(preceding, ssrcs[index]) != preceding.end()) {
          return false;
        }
      }
      const auto existing_payload_types =
        std::span<const std::uint8_t> {reserved_payload_types_}.first(reserved_payload_type_count_);
      for (std::size_t index = 0; index < payload_types.size(); ++index) {
        if (!lumen::lsp::transport::valid_lsp_dynamic_payload_type(payload_types[index]) ||
            std::ranges::find(existing_payload_types, payload_types[index]) != existing_payload_types.end()) {
          return false;
        }
        const auto preceding = payload_types.first(index);
        if (std::ranges::find(preceding, payload_types[index]) != preceding.end()) {
          return false;
        }
      }
      std::copy(ssrcs.begin(), ssrcs.end(), reserved_ssrcs_.begin() + static_cast<std::ptrdiff_t>(reserved_ssrc_count_));
      std::copy(
        payload_types.begin(),
        payload_types.end(),
        reserved_payload_types_.begin() + static_cast<std::ptrdiff_t>(reserved_payload_type_count_)
      );
      reserved_ssrc_count_ += ssrcs.size();
      reserved_payload_type_count_ += payload_types.size();
      return true;
    }

    /** @brief Roll back the most recent reservation while the registry mutex remains held. */
    void rollback_media_identifiers_locked(
      const std::size_t ssrc_count,
      const std::size_t payload_type_count
    ) noexcept {
      if (ssrc_count <= reserved_ssrc_count_) {
        reserved_ssrc_count_ -= ssrc_count;
        std::fill(reserved_ssrcs_.begin() + static_cast<std::ptrdiff_t>(reserved_ssrc_count_), reserved_ssrcs_.end(), 0);
      }
      if (payload_type_count <= reserved_payload_type_count_) {
        reserved_payload_type_count_ -= payload_type_count;
        std::fill(
          reserved_payload_types_.begin() + static_cast<std::ptrdiff_t>(reserved_payload_type_count_),
          reserved_payload_types_.end(),
          0
        );
      }
    }

    /** @brief Optional reliable PATH_PROBE intent kept outside fatal control operations. */
    struct PathIntentControlFrame {
      lumen::lsp::packet_slab<maximum_control_frame> frame {};  ///< Exact LSPC bytes.
      std::uint64_t message_id {};  ///< Logical control message ID.
      std::uint64_t deadline_microseconds {};  ///< Optional intent retry deadline.
      std::uint64_t next_retry_microseconds {};  ///< Next byte-identical retry.
      std::uint8_t transmissions {};  ///< Completed DTLS submissions.
      bool occupied {};  ///< Whether peer ACK remains outstanding.
    };

    /** @brief Increment one C ABI telemetry counter. */
    void increment(const RuntimeCounter counter, const std::uint64_t amount = 1) const noexcept {
      const auto index = static_cast<std::size_t>(counter);
      if (index < worker_counters_.size()) {
        worker_counters_[index] = saturating_add(worker_counters_[index], amount);
      }
    }

    /** @brief Record one same-endpoint stage duration or one invalid correlation. */
    void record_timing_stage(
      const clsp_native_timing_stage_t stage,
      const std::uint64_t start_microseconds,
      const std::uint64_t end_microseconds,
      const std::uint32_t flags = 0U
    ) noexcept {
      auto &distribution = timing_distributions_[static_cast<std::size_t>(stage)];
      if (start_microseconds == 0U || end_microseconds < start_microseconds) {
        distribution.drop(flags | CLSP_NATIVE_TIMING_UNKNOWN_COMPONENT);
        return;
      }
      distribution.record(end_microseconds - start_microseconds, flags);
    }

    /** @brief Publish cumulative fixed-bucket timing stages at the coarse telemetry cadence. */
    void publish_timing_snapshot(const std::uint64_t now) noexcept {
      if (callbacks_.timing == nullptr) return;
      if (last_timing_publication_microseconds_ != 0U &&
          now - last_timing_publication_microseconds_ < 250'000U) return;
      auto generation = ++timing_snapshot_generation_;
      if (generation == 0U) generation = ++timing_snapshot_generation_;
      clsp_native_timing_snapshot_t snapshot {
        .abi_version = CLSP_CORE_ABI_VERSION,
        .structure_size = sizeof(clsp_native_timing_snapshot_t),
        .snapshot_generation = generation,
        .snapshot_time_microseconds = now,
        .stream_generation = input_configured_ ? input_configuration_.stream_generation : 0U,
        .input_generation = input_configured_ ? input_configuration_.input_generation : 0U,
        .video_generation = video_configured_.load(std::memory_order_acquire) ?
                              video_configuration_.video_generation : 0U,
        .audio_generation = audio_configured_.load(std::memory_order_acquire) ?
                              audio_configuration_.audio_generation : 0U,
        .pointer_generation = std::max<std::uint32_t>(
          1U,
          published_pointer_generation_.load(std::memory_order_acquire)
        ),
      };
      constexpr auto local_flags = CLSP_NATIVE_TIMING_AVAILABLE |
                                   CLSP_NATIVE_TIMING_CLIENT_MONOTONIC |
                                   CLSP_NATIVE_TIMING_SAME_ENDPOINT;
      for (std::size_t index = 0U; index < timing_distributions_.size(); ++index) {
        snapshot.stages[index] = timing_distributions_[index].snapshot(local_flags);
      }
      for (std::size_t index = 0U; index < 16U; ++index) {
        snapshot.controller_generations[index] =
          published_controller_generations_[index].load(std::memory_order_acquire);
        snapshot.touch_generations[index] =
          published_touch_generations_[index].load(std::memory_order_acquire);
        snapshot.pen_generations[index] =
          published_pen_generations_[index].load(std::memory_order_acquire);
      }
      callbacks_.timing(callbacks_.context, snapshot);
      last_timing_publication_microseconds_ = now;
    }

    /** @brief Publish worker-owned counter deltas at no more than four hertz. */
    void flush_telemetry(const std::uint64_t now, const bool force = false) noexcept {
      if (callbacks_.counter == nullptr && callbacks_.timing == nullptr) return;
      const auto interval = std::max<std::uint64_t>(250'000U, static_cast<std::uint64_t>(configuration_.telemetry_interval_milliseconds) * 1'000U);
      if (!force && last_telemetry_flush_microseconds_ != 0U &&
          now - last_telemetry_flush_microseconds_ < interval) return;
      if (callbacks_.counter != nullptr) {
        worker_counters_[static_cast<std::size_t>(RuntimeCounter::dropped)] = saturating_add(
          worker_counters_[static_cast<std::size_t>(RuntimeCounter::dropped)],
          producer_dropped_.exchange(0U, std::memory_order_acq_rel)
        );
        for (std::size_t index = 0; index < worker_counters_.size(); ++index) {
          const auto amount = worker_counters_[index];
          if (amount != 0U) {
            callbacks_.counter(callbacks_.context, static_cast<std::uint32_t>(index), amount);
            worker_counters_[index] = 0;
          }
        }
      }
      timing_distributions_[CLSP_NATIVE_TIMING_INPUT_CALLBACK_TO_COMPOSE].add_drops(
        producer_callback_timing_drops_.exchange(0U, std::memory_order_acq_rel)
      );
      publish_timing_snapshot(now);
      last_telemetry_flush_microseconds_ = now;
    }

    /** @brief Validate one exact schema-revision-three video generation mapping. */
    [[nodiscard]] static bool
    valid_video_configuration(const clsp_video_configuration_t &value) noexcept {
      const auto valid_codec_profile =
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
      const auto valid_payload_format =
        value.codec == CLSP_VIDEO_CODEC_AV1 ?
          value.payload_format == CLSP_VIDEO_PAYLOAD_AV1_LOW_OVERHEAD_OBU :
          value.payload_format == CLSP_VIDEO_PAYLOAD_ANNEX_B;
      const auto ten_bit = value.pixel_format == CLSP_VIDEO_PIXEL_420_10 ||
                           value.pixel_format == CLSP_VIDEO_PIXEL_444_10;
      const auto valid_color =
        (value.color_primaries == 1U && value.transfer_characteristics == 1U &&
         value.matrix_coefficients == 1U) ||
        (value.codec != CLSP_VIDEO_CODEC_H264 && ten_bit && value.full_range == 0U &&
         value.color_primaries == 9U && value.matrix_coefficients == 9U &&
         (value.transfer_characteristics == 16U || value.transfer_characteristics == 18U));
      const auto flexfec_disabled =
        value.flexfec_ssrc == 0 && value.flexfec_payload_type == 0 &&
        value.flexfec_repair_window_microseconds == 0 && value.flexfec_maximum_group_packets == 0;
      const auto flexfec_enabled =
        value.flexfec_ssrc != 0 && value.flexfec_ssrc != value.primary_ssrc &&
        lumen::lsp::transport::valid_lsp_dynamic_payload_type(value.flexfec_payload_type) &&
        value.flexfec_payload_type != value.primary_payload_type &&
        value.flexfec_repair_window_microseconds != 0 &&
        value.flexfec_repair_window_microseconds <= value.maximum_frame_age_microseconds &&
        value.flexfec_maximum_group_packets == 15U;
      const auto rtx_disabled =
        value.rtx_ssrc == 0 && value.rtx_payload_type == 0 && value.rtx_associated_payload_type == 0;
      const auto rtx_enabled =
        value.rtx_ssrc != 0 && value.rtx_ssrc != value.primary_ssrc &&
        value.rtx_ssrc != value.flexfec_ssrc &&
        lumen::lsp::transport::valid_lsp_dynamic_payload_type(value.rtx_payload_type) &&
        value.rtx_payload_type != value.primary_payload_type &&
        value.rtx_payload_type != value.flexfec_payload_type &&
        value.rtx_associated_payload_type == value.primary_payload_type;
      return value.abi_version == CLSP_CORE_ABI_VERSION &&
             value.structure_size == sizeof(clsp_video_configuration_t) &&
             value.stream_generation != 0 && value.video_generation != 0 &&
             value.primary_ssrc != 0 && value.clock_rate == 90'000U &&
             value.width != 0 && value.width <= 16'384U &&
             value.height != 0 && value.height <= 16'384U &&
             value.refresh_numerator != 0 && value.refresh_denominator != 0 &&
             value.bitrate >= 1'000U && value.bitrate <= 1'000'000'000U &&
             value.maximum_access_unit_bytes != 0 &&
             value.maximum_access_unit_bytes <= 16U * 1024U * 1024U &&
             value.maximum_frame_age_microseconds != 0 &&
             value.maximum_frame_age_microseconds <= 1'000'000U &&
             value.frame_id_origin != 0 && value.recovery_epoch != 0 &&
             value.udp_payload_size == 1'200U &&
             lumen::lsp::transport::valid_lsp_dynamic_payload_type(value.primary_payload_type) &&
             valid_codec_profile && value.full_range <= 1U && valid_color &&
             value.delivery == CLSP_VIDEO_DELIVERY_COMPLETE_ACCESS_UNIT &&
             valid_payload_format && (flexfec_disabled || flexfec_enabled) &&
             (rtx_disabled || rtx_enabled) &&
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
             left.pixel_format == right.pixel_format &&
             left.color_primaries == right.color_primaries &&
             left.transfer_characteristics == right.transfer_characteristics &&
             left.matrix_coefficients == right.matrix_coefficients &&
             left.full_range == right.full_range && left.delivery == right.delivery &&
             left.payload_format == right.payload_format &&
             left.decoder_surfaces == right.decoder_surfaces &&
             left.frame_marking_extension == right.frame_marking_extension &&
             left.absolute_capture_extension ==
               right.absolute_capture_extension &&
             left.frame_id_extension == right.frame_id_extension &&
             left.input_watermark_extension == right.input_watermark_extension &&
             left.encoder_timing_extension == right.encoder_timing_extension &&
             left.flexfec_ssrc == right.flexfec_ssrc &&
             left.flexfec_repair_window_microseconds == right.flexfec_repair_window_microseconds &&
             left.rtx_ssrc == right.rtx_ssrc &&
             left.flexfec_payload_type == right.flexfec_payload_type &&
             left.flexfec_maximum_group_packets == right.flexfec_maximum_group_packets &&
             left.rtx_payload_type == right.rtx_payload_type &&
             left.rtx_associated_payload_type == right.rtx_associated_payload_type;
    }

    /** @brief Compare every immutable native input-generation field. */
    [[nodiscard]] static bool same_input_configuration(
      const clsp_input_configuration_t &left,
      const clsp_input_configuration_t &right
    ) noexcept {
      return left.stream_generation == right.stream_generation &&
             left.input_generation == right.input_generation &&
             left.input_ssrc == right.input_ssrc &&
             left.acknowledgement_ssrc == right.acknowledgement_ssrc &&
             left.pointer_rate == right.pointer_rate &&
             left.controller_rate == right.controller_rate &&
             left.sensor_rate == right.sensor_rate &&
             left.reconciliation_rate == right.reconciliation_rate &&
             left.reserved_input_wire_bits_per_second == right.reserved_input_wire_bits_per_second &&
             left.input_payload_type == right.input_payload_type &&
             left.baseline_required == right.baseline_required;
    }

    /** @brief Snapshot current bounded decoder/render state for protected LSPV.
     */
    [[nodiscard]] lumen::lsp::transport::lspv_status current_lspv_status(
      const lumen::lsp::transport::lspv_decoder_status decoder_status
    ) noexcept {
      return {
        .session_generation = video_configuration_.stream_generation,
        .video_generation = video_configuration_.video_generation,
        .recovery_epoch = video_current_recovery_epoch_,
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

    /** @brief Derive current decoder capacity without replacing latched recovery evidence. */
    [[nodiscard]] lumen::lsp::transport::lspv_decoder_status current_decoder_capacity_status() const noexcept {
      return video_decoder_credit_.available() == 0 ?
               lumen::lsp::transport::lspv_decoder_status::surface_exhausted :
               lumen::lsp::transport::lspv_decoder_status::ready;
    }

    /**
     * @brief Retain one exact delivered frame in the fixed decoder-credit table.
     *
     * @param frame_id Nonzero completed frame ID.
     * @param recovery_epoch Authenticated frame epoch.
     * @param independent Authenticated independent-frame marking.
     * @return True only when a unique empty slot was populated.
     */
    [[nodiscard]] bool remember_delivered_video_frame(
      const std::uint64_t frame_id,
      const std::uint32_t recovery_epoch,
      const bool independent
    ) noexcept {
      if (frame_id == 0 || recovery_epoch == 0 ||
          std::ranges::any_of(delivered_video_frames_, [frame_id](const DeliveredVideoFrame &frame) {
            return frame.occupied && frame.frame_id == frame_id;
          })) {
        return false;
      }
      const auto empty = std::ranges::find_if(delivered_video_frames_, [](const DeliveredVideoFrame &frame) {
        return !frame.occupied;
      });
      if (empty == delivered_video_frames_.end()) {
        return false;
      }
      *empty = {
        .frame_id = frame_id,
        .recovery_epoch = recovery_epoch,
        .independent = independent,
        .occupied = true,
      };
      return true;
    }

    /**
     * @brief Find one exact delivered frame awaiting Swift's terminal decoder report.
     *
     * @param frame_id Reported frame ID.
     * @param recovery_epoch Reported per-frame recovery epoch.
     * @return Matching fixed-table entry, or null.
     */
    [[nodiscard]] DeliveredVideoFrame *find_delivered_video_frame(
      const std::uint64_t frame_id,
      const std::uint32_t recovery_epoch
    ) noexcept {
      const auto found = std::ranges::find_if(delivered_video_frames_, [&](const DeliveredVideoFrame &frame) {
        return frame.occupied && frame.frame_id == frame_id && frame.recovery_epoch == recovery_epoch;
      });
      return found == delivered_video_frames_.end() ? nullptr : &*found;
    }

    /** @brief Release runtime-owned video storage after the socket worker is
     * quiescent. */
    void release_video_state() noexcept {
      video_configured_.store(false, std::memory_order_release);
      video_delivery_active_.store(false, std::memory_order_release);
      last_authenticated_inbound_microseconds_.store(0U, std::memory_order_release);
      path_discovery_enabled_.store(false, std::memory_order_release);
#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      if (mutex_ready_) {
        pthread_mutex_lock(&mutex_);
      }
#endif
      for (std::size_t index = 0; index < pending_video_delivery_count_;
           ++index) {
        clsp_buffer_release(pending_video_deliveries_[index].frame);
        pending_video_deliveries_[index] = {};
        pending_video_auth_times_[index] = 0U;
      }
      pending_video_delivery_count_ = 0;
      if (video_reassembler_) {
        (void)video_reassembler_->clear([this](const std::uint64_t token) noexcept {
          (void)video_receive_pool_.release(token);
        });
      }
      video_reassembler_.reset();
      video_reassembly_slices_.reset();
      video_metadata_ = {};
      delivered_video_frames_ = {};
      video_retired_frames_ = {};
      authenticated_video_fingerprints_ = {};
      authenticated_flexfec_fingerprints_ = {};
      authenticated_rtx_fingerprints_ = {};
      for (auto &source : authenticated_video_sources_) {
        if (source.occupied) {
          (void)video_receive_pool_.release(source.slab_token);
          source = {};
        }
      }
      for (auto &repair : pending_flexfec_repairs_) {
        if (repair.occupied) {
          (void)video_receive_pool_.release(repair.slab_token);
          repair = {};
        }
      }
      pending_video_nack_ = {};
      video_nack_retries_ = {};
      outbound_path_probe_ = {};
      inbound_path_probe_intent_ = {};
      unmatched_path_probe_ = {};
      path_probe_notification_pending_ = false;
      emitted_path_probe_id_.store(0, std::memory_order_release);
      emitted_path_probe_size_.store(0, std::memory_order_release);
      pending_path_ack_id_.store(0, std::memory_order_release);
      pending_path_probe_event_count_ = 0;
      path_intent_message_id_ = 0;
      path_intent_request_id_ = 0;
      path_intent_probe_id_ = 0;
      path_intent_probe_size_ = 0;
      path_intent_control_ = {};
      compound_rtcp_sent_ = false;
      pending_rtcp_ = {};
      video_current_recovery_epoch_ = 0;
      video_recovery_feedback_pending_ = false;
      video_recovery_evidence_watermark_ = 0;
      last_recovery_lspv_microseconds_ = 0;
      authenticated_repair_abuse_window_start_ = 0;
      authenticated_repair_abuse_count_ = 0;
      auto *pool = video_frame_pool_;
      video_frame_pool_ = nullptr;
      const auto receive_pool_cleared = video_receive_pool_.clear();
#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      if (mutex_ready_) {
        pthread_mutex_unlock(&mutex_);
      }
#endif
      release_retained_frame_pool(pool);
      if (!receive_pool_cleared) {
        realtime_failure_status_ = CLSP_STATUS_INTERNAL_FAILURE;
      }
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

    /** @brief Return the IP/UDP bytes outside one protected UDP payload for the active family. */
    [[nodiscard]] std::uint32_t ip_udp_overhead_bytes() const noexcept {
#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      return socket_family_ == AF_INET6 ? 48U : 28U;
#else
      return 0;  // No active socket in a provider-disabled build.
#endif
    }

    /** @brief Return the minimum complete-wire rate required by negotiated microphone media. */
    [[nodiscard]] std::uint64_t microphone_minimum_wire_rate(
      const clsp_microphone_configuration_t &value
    ) const noexcept {
      constexpr std::uint64_t packets_per_second = 50U;
      const auto per_packet_overhead = static_cast<std::uint64_t>(12U + 16U + ip_udp_overhead_bytes());
      return static_cast<std::uint64_t>(value.bitrate) + per_packet_overhead * 8U * packets_per_second;
    }

    /** @brief Return bounded microphone credit for a selected feedback-controlled rate. */
    [[nodiscard]] std::uint64_t microphone_credit_capacity(
      const clsp_microphone_configuration_t &value,
      const std::uint64_t pacing_rate
    ) const noexcept {
      const auto two_frame_quanta = pacing_rate / 25U;
      const auto two_path_packets =
        static_cast<std::uint64_t>(value.udp_payload_size + ip_udp_overhead_bytes()) * 8U * 2U;
      return std::max(two_frame_quanta, two_path_packets);
    }

    /** @brief Add two rates without permitting an arithmetic wrap. */
    [[nodiscard]] static std::uint64_t saturating_rate_add(
      const std::uint64_t left,
      const std::uint64_t right
    ) noexcept {
      return left > std::numeric_limits<std::uint64_t>::max() - right ?
               std::numeric_limits<std::uint64_t>::max() :
               left + right;
    }

    /** @brief Return the feedback-selected microphone pacing rate, or its safe initial value. */
    [[nodiscard]] std::uint64_t current_microphone_pacing_rate() const noexcept {
      return microphone_congestion_rate_bits_per_second_ != 0 ?
               microphone_congestion_rate_bits_per_second_ :
               microphone_pacing_rate(microphone_configuration_);
    }

    /** @brief Initialize one aggregate reverse controller while preserving the input minimum. */
    [[nodiscard]] bool reset_reverse_congestion_controller(
      const bool include_prepared_microphone = false
    ) noexcept {
      if (!input_configured_) {
        microphone_congestion_.reset();
        reverse_congestion_rate_bits_per_second_ = 0;
        reverse_controller_includes_microphone_ = false;
        return false;
      }
      const auto input_rate = input_configuration_.reserved_input_wire_bits_per_second;
      const auto microphone_selected =
        microphone_active_.load(std::memory_order_acquire) || include_prepared_microphone;
      if (microphone_selected &&
          (!microphone_prepared_.load(std::memory_order_acquire) ||
           input_configuration_.stream_generation != microphone_configuration_.stream_generation)) {
        microphone_congestion_.reset();
        reverse_congestion_rate_bits_per_second_ = 0;
        reverse_controller_includes_microphone_ = false;
        return false;
      }
      const auto microphone_minimum = microphone_selected ?
        microphone_minimum_wire_rate(microphone_configuration_) : 0U;
      const auto microphone_initial = microphone_selected ?
        std::max(microphone_minimum, microphone_pacing_rate(microphone_configuration_)) : 0U;
      const auto minimum_rate = saturating_rate_add(input_rate, microphone_minimum);
      const auto initial_rate = saturating_rate_add(input_rate, microphone_initial);
      auto maximum_rate = initial_rate;
      auto competition_rate = std::uint64_t {0};
      const auto competition = configuration_.profile == CLSP_PROFILE_COMPETITION_LAN;
      const auto control_srtt = rto_.sampled() ? rto_.smoothed_microseconds() : rto_.timeout_microseconds();
      const auto initial_srtt = microphone_smoothed_rtt_microseconds_ != 0 ?
        static_cast<std::uint64_t>(microphone_smoothed_rtt_microseconds_) : control_srtt;
      if (competition) {
        competition_rate = static_cast<std::uint64_t>(configuration_.competition_capacity_mbps) * 1'000'000U;
        maximum_rate = competition_rate;
      }
      microphone_congestion_.emplace(lumen::lsp::transport::controller_config {
        .profile = competition ?
          lumen::lsp::transport::controller_profile::competition_lan :
          lumen::lsp::transport::controller_profile::adaptive_low_latency,
        .initial_pacing_bits_per_second = initial_rate,
        .minimum_pacing_bits_per_second = minimum_rate,
        .maximum_pacing_bits_per_second = maximum_rate,
        .competition_capacity_bits_per_second = competition_rate,
        .reserved_overhead_bits_per_second = 0,
        .maximum_rtt_microseconds = competition ?
          static_cast<std::uint32_t>(std::min<std::uint64_t>(
            UINT32_MAX,
            std::max<std::uint64_t>(10'000U, initial_srtt)
          )) :
          100'000U,
        .queue_delay_budget_microseconds = competition ? 2'000U : 10'000U,
      });
      if (microphone_congestion_->error() != lumen::lsp::transport::controller_error::none) {
        microphone_congestion_.reset();
        reverse_congestion_rate_bits_per_second_ = 0;
        microphone_congestion_rate_bits_per_second_ = 0;
        reverse_controller_includes_microphone_ = false;
        return false;
      }
      reverse_congestion_rate_bits_per_second_ = initial_rate;
      microphone_congestion_rate_bits_per_second_ = microphone_initial;
      reverse_controller_includes_microphone_ = microphone_selected;
      if (microphone_smoothed_rtt_microseconds_ == 0) {
        const auto control_variation = rto_.sampled() ? rto_.variation_microseconds() : control_srtt / 2U;
        microphone_smoothed_rtt_microseconds_ = static_cast<std::uint32_t>(std::min<std::uint64_t>(
          UINT32_MAX,
          control_srtt
        ));
        microphone_rtt_variation_microseconds_ = static_cast<std::uint32_t>(std::min<std::uint64_t>(
          UINT32_MAX,
          control_variation
        ));
      }
      microphone_minimum_failure_count_ = 0;
      return true;
    }

    /** @brief Retain one exact host request until Swift installs and responds. */
    [[nodiscard]] static std::optional<lumen::lsp::response_semantic_identity> response_identity(
      const lumen::lsp::lspc_header &header,
      const std::span<const std::uint8_t> request
    ) noexcept {
#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      if (header.message_type == 0U || header.connection_generation == 0U || header.request_id == 0U ||
          request.empty() || request.size() > static_cast<std::size_t>(std::numeric_limits<word32>::max())) {
        return std::nullopt;
      }
      lumen::lsp::response_semantic_identity identity {
        .message_type = header.message_type,
        .schema_version = 1,
        .generation = header.connection_generation,
      };
      lumen::lsp::wire::write_be<std::uint64_t>(identity.semantic_id, header.request_id);
      lumen::lsp::wire::write_be<std::uint32_t>(std::span<std::uint8_t> {identity.semantic_id}.subspan(8, 4), header.connection_generation);
      lumen::lsp::wire::write_be<std::uint16_t>(std::span<std::uint8_t> {identity.semantic_id}.subspan(12, 2), header.message_type);
      lumen::lsp::wire::write_be<std::uint16_t>(std::span<std::uint8_t> {identity.semantic_id}.subspan(14, 2), 1U);
      if (wc_Sha256Hash(request.data(), static_cast<word32>(request.size()), identity.request_digest.data()) != 0) {
        return std::nullopt;
      }
      return identity;
#else
      (void)header;
      (void)request;
      return std::nullopt;
#endif
    }

    /** @brief Retain one exact host request until Swift installs and responds. */
    [[nodiscard]] bool retain_inbound_request(
      const std::uint64_t request_id,
      const lumen::lsp::response_semantic_identity &identity,
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
      free_slot->identity = identity;
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

    /** @brief Preserve and return the first non-success terminal status. */
    [[nodiscard]] clsp_status_t latch_terminal_status(const clsp_status_t status) noexcept {
      auto expected = static_cast<std::uint32_t>(CLSP_STATUS_OK);
      (void)terminal_status_.compare_exchange_strong(
        expected,
        static_cast<std::uint32_t>(status),
        std::memory_order_acq_rel,
        std::memory_order_acquire
      );
      return static_cast<clsp_status_t>(terminal_status_.load(std::memory_order_acquire));
    }

    /** @brief Publish one coarse lifecycle transition with exact terminal status. */
    void publish_lifecycle(
      const std::uint32_t state,
      const clsp_status_t terminal_status = CLSP_STATUS_OK
    ) const noexcept {
      if (callbacks_.lifecycle != nullptr) {
        callbacks_.lifecycle(callbacks_.context, state, terminal_status);
      }
    }

    /** @brief Retain one low-rate DPLPMTUD event until the C ABI callback accepts it. */
    [[nodiscard]] bool queue_path_probe_event(
      const std::uint8_t kind,
      const std::uint64_t probe_id,
      const std::uint16_t udp_payload_size,
      const std::uint64_t request_id
    ) noexcept {
#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      pthread_mutex_lock(&mutex_);
      const auto queued = queue_path_probe_event_locked(kind, probe_id, udp_payload_size, request_id);
      pthread_mutex_unlock(&mutex_);
      if (queued) {
        wake_worker();
      }
      return queued;
#else
      (void) kind;
      (void) probe_id;
      (void) udp_payload_size;
      (void) request_id;
      return false;
#endif
    }

    /** @brief Append one path event while `mutex_` is already held. */
    [[nodiscard]] bool queue_path_probe_event_locked(
      const std::uint8_t kind,
      const std::uint64_t probe_id,
      const std::uint16_t udp_payload_size,
      const std::uint64_t request_id
    ) noexcept {
#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      if (pending_path_probe_event_count_ == pending_path_probe_events_.size()) {
        return false;
      }
      pending_path_probe_events_[pending_path_probe_event_count_++] = {
        .abi_version = CLSP_CORE_ABI_VERSION,
        .structure_size = sizeof(clsp_path_probe_event_t),
        .probe_id = probe_id,
        .request_id = request_id,
        .udp_payload_size = udp_payload_size,
        .kind = kind,
        .reserved_zero = 0,
      };
      return true;
#else
      (void) kind;
      (void) probe_id;
      (void) udp_payload_size;
      (void) request_id;
      return false;
#endif
    }

    /** @brief Deliver retained path events without dropping them during another active callback. */
    void deliver_path_probe_events() noexcept {
#if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      if (callbacks_.path_probe == nullptr) {
        return;
      }
      for (;;) {
        pthread_mutex_lock(&mutex_);
        if (pending_path_probe_event_count_ == 0) {
          pthread_mutex_unlock(&mutex_);
          return;
        }
        const auto event = pending_path_probe_events_[0];
        pthread_mutex_unlock(&mutex_);
        if (!callbacks_.path_probe(callbacks_.context, event)) {
          return;
        }
        pthread_mutex_lock(&mutex_);
        for (std::size_t index = 1; index < pending_path_probe_event_count_; ++index) {
          pending_path_probe_events_[index - 1U] = pending_path_probe_events_[index];
        }
        --pending_path_probe_event_count_;
        pthread_mutex_unlock(&mutex_);
      }
#endif
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
        socket_family_ = candidate->ai_family;
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
      const int receive_ecn = 1;
      const int do_not_fragment = 1;
      if (socket_family_ == AF_INET) {
        if (setsockopt(socket_, IPPROTO_IP, IP_DONTFRAG, &do_not_fragment, sizeof(do_not_fragment)) != 0) {
          return CLSP_STATUS_SOCKET_FAILURE;
        }
  #ifdef IP_RECVTOS
        (void) setsockopt(socket_, IPPROTO_IP, IP_RECVTOS, &receive_ecn, sizeof(receive_ecn));
  #endif
        path_mtu_.emplace(lumen::lsp::transport::path_mtu_config {
          .ip_version = lumen::lsp::transport::path_ip_version::ipv4,
          .sender_interface_limit = 1'472,
          .receiver_advertised_limit = 1'472,
          .operator_configured_limit = 1'472,
        });
      } else if (socket_family_ == AF_INET6) {
  #ifdef IPV6_DONTFRAG
        constexpr auto ipv6_do_not_fragment_option = IPV6_DONTFRAG;
  #else
        constexpr int ipv6_do_not_fragment_option = 62;
  #endif
        if (setsockopt(socket_, IPPROTO_IPV6, ipv6_do_not_fragment_option, &do_not_fragment, sizeof(do_not_fragment)) != 0) {
          return CLSP_STATUS_SOCKET_FAILURE;
        }
  #ifdef IPV6_RECVTCLASS
        (void) setsockopt(socket_, IPPROTO_IPV6, IPV6_RECVTCLASS, &receive_ecn, sizeof(receive_ecn));
  #endif
        path_mtu_.emplace(lumen::lsp::transport::path_mtu_config {
          .ip_version = lumen::lsp::transport::path_ip_version::ipv6,
          .sender_interface_limit = 1'452,
          .receiver_advertised_limit = 1'452,
          .operator_configured_limit = 1'452,
        });
      }
      if (!path_mtu_ || !path_mtu_->valid()) {
        return CLSP_STATUS_INVALID_CONFIGURATION;
      }
      current_udp_payload_size_.store(1'200U, std::memory_order_release);
      receive_udp_payload_size_.store(1'200U, std::memory_order_release);
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
        const auto urgent_repair_timer = configuration_.profile == CLSP_PROFILE_COMPETITION_LAN &&
                                         video_gap_tracker_.size() != 0;
        const timespec timeout {
          .tv_sec = 0,
          .tv_nsec = urgent_repair_timer ? 100'000L : 1'000'000L,
        };
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
          next_path_probe_id_ = (static_cast<std::uint64_t>(arc4random()) << 32U) | arc4random();
          if (next_path_probe_id_ == 0) {
            next_path_probe_id_ = 1;
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

        process_inbound_security_install();

        if (video_configured_.load(std::memory_order_acquire)) {
          const auto repair_now = monotonic_microseconds();
          expire_video_repair_state(repair_now);
          status = transmit_video_nacks(repair_now);
          if (status != CLSP_STATUS_OK) {
            fail_worker(status);
            return;
          }
        }

        status = drain_control_queue();
        if (status != CLSP_STATUS_OK) {
          fail_worker(status);
          return;
        }
        status = retry_control();
        if (status != CLSP_STATUS_OK) {
          fail_worker(status, "control retransmission");
          return;
        }
        status = process_input_configuration();
        if (status != CLSP_STATUS_OK) {
          fail_worker(status);
          return;
        }
        status = process_input_rate_update();
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
          fail_worker(status, "input transmission");
          return;
        }
        status = transmit_pending_controller_ack();
        if (status != CLSP_STATUS_OK) {
          fail_worker(status);
          return;
        }
        status = transmit_microphone();
        if (status != CLSP_STATUS_OK) {
          fail_worker(status);
          return;
        }
        status = process_deferred_video_batch();
        if (status != CLSP_STATUS_OK) {
          fail_worker(status);
          return;
        }
        const auto peer_liveness_now = monotonic_microseconds();
        if (active_stream_peer_timed_out(peer_liveness_now)) {
          fail_worker(CLSP_STATUS_TIMEOUT, "authenticated peer silence");
          return;
        }
        deliver_path_probe_events();
        deliver_video_frames();
        if (video_configured_.load(std::memory_order_acquire)) {
          const auto video_now = monotonic_microseconds();
          expire_video_frames(video_now);
          expire_video_repair_state(video_now);
        }
        const auto transport_now = monotonic_microseconds();
        status = drive_path_mtu(transport_now);
        if (status != CLSP_STATUS_OK) {
          fail_worker(status);
          return;
        }
        status = transmit_outbound_path_probe(transport_now);
        if (status != CLSP_STATUS_OK) {
          fail_worker(status);
          return;
        }
        status = transmit_pending_rtcp(transport_now);
        if (status != CLSP_STATUS_OK) {
          fail_worker(status);
          return;
        }
        status = transmit_compound_rtcp(transport_now);
        if (status != CLSP_STATUS_OK) {
          fail_worker(status);
          return;
        }
        status = transmit_video_nacks(transport_now);
        if (status != CLSP_STATUS_OK) {
          fail_worker(status);
          return;
        }
        status = transmit_congestion_feedback(transport_now);
        if (status != CLSP_STATUS_OK) {
          fail_worker(status);
          return;
        }
        status = transmit_lspv();
        if (status != CLSP_STATUS_OK) {
          fail_worker(status);
          return;
        }
        flush_telemetry(transport_now);
      }
      flush_telemetry(monotonic_microseconds(), true);
    }

    /** @brief Drain up to the bounded initial receive batch from the UDP socket. */
    [[nodiscard]] clsp_status_t drain_socket() noexcept {
      clear_deferred_video_batch();
      const auto drain_started_microseconds = monotonic_microseconds();
      std::uint64_t oldest_arrival_microseconds = 0U;
      std::size_t drained_datagrams = 0U;
      bool batch_used_kernel_timestamp = false;
      bool batch_used_fallback_timestamp = false;
      for (std::size_t index = 0; index < receive_batch_size; ++index) {
        std::array<std::uint8_t, maximum_udp_payload> fallback_packet {};
        VideoReceiveLease receive_lease;
        auto receive_storage = std::span<std::uint8_t> {fallback_packet};
        if (video_configured_.load(std::memory_order_acquire) &&
            receive_lease.acquire(video_receive_pool_)) {
          receive_storage = receive_lease.bytes();
        }
        std::array<std::uint8_t, 128> control {};
        iovec vector {.iov_base = receive_storage.data(), .iov_len = receive_storage.size()};
        msghdr message {};
        message.msg_iov = &vector;
        message.msg_iovlen = 1;
        message.msg_control = control.data();
        message.msg_controllen = control.size();
        const auto received = recvmsg(socket_, &message, 0);
        auto arrival_microseconds = monotonic_microseconds();
        auto kernel_timestamped = false;
        if (received < 0) {
          if (errno == EAGAIN || errno == EWOULDBLOCK) break;
          return CLSP_STATUS_SOCKET_FAILURE;
        }
        if (received == 0) {
          increment(RuntimeCounter::dropped);
          continue;
        }
        if ((message.msg_flags & MSG_TRUNC) != 0 || static_cast<std::size_t>(received) > receive_storage.size()) {
          increment(RuntimeCounter::dropped);
          continue;
        }
        auto ecn = native_ecn_mark::unknown;
        for (auto *header = CMSG_FIRSTHDR(&message); header != nullptr; header = CMSG_NXTHDR(&message, header)) {
#ifdef SCM_TIMESTAMP_MONOTONIC
          if (header->cmsg_level == SOL_SOCKET && header->cmsg_type == SCM_TIMESTAMP_MONOTONIC &&
              header->cmsg_len >= CMSG_LEN(sizeof(std::uint64_t))) {
            std::uint64_t timestamp_ticks = 0;
            std::memcpy(&timestamp_ticks, CMSG_DATA(header), sizeof(timestamp_ticks));
            const auto timestamp_microseconds = kernel_timestamp_microseconds(timestamp_ticks);
            if (timestamp_microseconds != 0U) {
              arrival_microseconds = timestamp_microseconds;
              kernel_timestamped = true;
            }
            continue;
          }
#endif
          auto ipv4_tos = header->cmsg_level == IPPROTO_IP && header->cmsg_type == IP_TOS;
  #ifdef IP_RECVTOS
          ipv4_tos = ipv4_tos || (header->cmsg_level == IPPROTO_IP && header->cmsg_type == IP_RECVTOS);
  #endif
  #ifdef IPV6_TCLASS
          const auto ipv6_class = header->cmsg_level == IPPROTO_IPV6 && header->cmsg_type == IPV6_TCLASS;
  #else
          const auto ipv6_class = false;
  #endif
          if (!ipv4_tos && !ipv6_class) {
            continue;
          }
          int traffic_class = 0;
          const auto available = header->cmsg_len > CMSG_LEN(0) ? header->cmsg_len - CMSG_LEN(0) : 0;
          std::memcpy(&traffic_class, CMSG_DATA(header), std::min<std::size_t>(available, sizeof(traffic_class)));
          switch (static_cast<unsigned int>(traffic_class) & 0x03U) {
            case 0U:
              ecn = native_ecn_mark::not_ect;
              break;
            case 1U:
              ecn = native_ecn_mark::ect1;
              break;
            case 2U:
              ecn = native_ecn_mark::ect0;
              break;
            case 3U:
              ecn = native_ecn_mark::congestion_experienced;
              break;
          }
          break;
        }
        ++drained_datagrams;
        batch_used_kernel_timestamp = batch_used_kernel_timestamp || kernel_timestamped;
        batch_used_fallback_timestamp = batch_used_fallback_timestamp || !kernel_timestamped;
        oldest_arrival_microseconds = oldest_arrival_microseconds == 0U ? arrival_microseconds :
          std::min(oldest_arrival_microseconds, arrival_microseconds);
        auto datagram = receive_storage.first(static_cast<std::size_t>(received));
        const auto protected_datagram_size = static_cast<std::uint16_t>(datagram.size());
        const auto packet_class = classify(datagram);
        if (packet_class == PacketClass::srtp_or_srtcp && srtp_.ready() && !is_rtcp(datagram) &&
            datagram.size() >= 12U) {
          const auto visible_ssrc = lumen::lsp::wire::read_be<std::uint32_t>(datagram.subspan(8, 4));
          if (video_lane_for_ssrc(visible_ssrc) != VideoRtpLane::none) {
            if (receive_lease.token() == 0U) {
              record_local_video_pressure();
              increment(RuntimeCounter::dropped);
              continue;
            }
            auto &deferred = deferred_video_[deferred_video_count_++];
            deferred.token = receive_lease.detach();
            deferred.length = datagram.size();
            deferred.arrival_microseconds = arrival_microseconds;
            deferred.ecn = ecn;
            deferred.kernel_timestamped = kernel_timestamped;
            continue;
          }
        }
        switch (packet_class) {
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
                                              ) :
                                              (!rtcp && datagram.size() >= 12U ? lumen::lsp::wire::read_be<std::uint32_t>(
                                                                                   datagram.subspan(8, 4)
                                                                                 ) :
                                                                                 0U);
            if (!inbound_ssrc_registered(visible_ssrc, rtcp)) {
              increment(RuntimeCounter::dropped);
              break;
            }
            const auto video_lane = video_lane_for_ssrc(visible_ssrc);
            const auto use_video_context = video_lane != VideoRtpLane::none;
            const auto video_rtp_candidate = use_video_context && !rtcp && datagram.size() >= 28U;
            const auto audio_rtp_candidate = !use_video_context && !rtcp && datagram.size() >= 28U &&
                                             audio_configured_.load(std::memory_order_acquire) &&
                                             visible_ssrc == audio_configuration_.audio_ssrc;
            const auto feedback_rtp_candidate = video_rtp_candidate || audio_rtp_candidate;
            std::array<std::uint8_t, 16> authentication_tag {};
            if (feedback_rtp_candidate) {
              std::copy(datagram.end() - 16, datagram.end(), authentication_tag.begin());
            }
            const auto visible_sequence = feedback_rtp_candidate ?
                                            lumen::lsp::wire::read_be<std::uint16_t>(datagram.subspan(2, 2)) :
                                            0U;
            const auto visible_timestamp = feedback_rtp_candidate ?
                                             lumen::lsp::wire::read_be<std::uint32_t>(datagram.subspan(4, 4)) :
                                             0U;
            const auto first_header_byte = feedback_rtp_candidate ? datagram[0] : 0U;
            const auto second_header_byte = feedback_rtp_candidate ? datagram[1] : 0U;
            bool replay = false;
            const auto status = use_video_context ?
                                  srtp_.unprotect_video(receive_storage, packet_length, rtcp, replay) :
                                  srtp_.unprotect(receive_storage, packet_length, rtcp, replay);
            if (status != CLSP_STATUS_OK) {
              timing_distributions_[CLSP_NATIVE_TIMING_RECEIVE_TO_AUTH].drop(
                kernel_timestamped ? CLSP_NATIVE_TIMING_KERNEL_TIMESTAMPED :
                                       CLSP_NATIVE_TIMING_UNKNOWN_COMPONENT
              );
              if (replay && feedback_rtp_candidate) {
                auto *fingerprints = video_rtp_candidate ? video_fingerprints(video_lane) :
                                                           &authenticated_audio_fingerprints_;
                if (fingerprints != nullptr) {
                  if (const auto *fingerprint = authenticated_rtp_fingerprint(
                      *fingerprints,
                      visible_sequence,
                      visible_ssrc,
                      visible_timestamp,
                      protected_datagram_size,
                      first_header_byte,
                      second_header_byte,
                      authentication_tag
                    )) {
                    if (video_rtp_candidate) {
                      record_video_duplicate_ce(*fingerprint, ecn, video_lane);
                    } else {
                      record_audio_duplicate_ce(*fingerprint, ecn);
                    }
                    increment(RuntimeCounter::received);
                    break;
                  }
                }
              }
              increment(RuntimeCounter::authentication_failure);
              break;
            }
            const auto authenticated_microseconds = monotonic_microseconds();
            record_timing_stage(
              CLSP_NATIVE_TIMING_RECEIVE_TO_AUTH,
              arrival_microseconds,
              authenticated_microseconds,
              kernel_timestamped ? CLSP_NATIVE_TIMING_KERNEL_TIMESTAMPED :
                                     CLSP_NATIVE_TIMING_UNKNOWN_COMPONENT
            );
            increment(RuntimeCounter::received);
            if (use_video_context && !rtcp && receive_lease.token() == 0) {
              record_local_video_pressure();
              increment(RuntimeCounter::dropped);
              if (realtime_failure_status_ != CLSP_STATUS_OK) {
                const auto failure = realtime_failure_status_;
                realtime_failure_status_ = CLSP_STATUS_OK;
                return failure;
              }
              break;
            }
            const auto plaintext = std::span<const std::uint8_t> {receive_storage.data(), packet_length};
            const auto path_probe = rtcp ? handle_authenticated_path_probe(plaintext, visible_ssrc, protected_datagram_size, arrival_microseconds) :
                                           PathProbePacketResult::not_probe;
            if (path_probe == PathProbePacketResult::invalid ||
                (path_probe == PathProbePacketResult::not_probe &&
                 protected_datagram_size > receive_udp_payload_size_.load(std::memory_order_acquire))) {
              increment(RuntimeCounter::dropped);
              break;
            }
            if (path_probe == PathProbePacketResult::accepted) {
              note_authenticated_inbound(authenticated_microseconds);
              break;
            }
            if (!rtcp && use_video_context) {
              const auto video_rtp = lumen::lsp::parse_rtp_fixed_header(plaintext);
              if (video_rtp && video_rtp.header.ssrc == visible_ssrc &&
                  video_rtp.header.payload_type == video_payload_type(video_lane)) {
                record_video_feedback_for_lane(
                  plaintext,
                  protected_datagram_size,
                  arrival_microseconds,
                  ecn,
                  video_lane
                );
                auto *fingerprints = video_fingerprints(video_lane);
                if (fingerprints != nullptr) {
                  store_authenticated_rtp_fingerprint(
                    *fingerprints,
                    visible_sequence,
                    visible_ssrc,
                    visible_timestamp,
                    protected_datagram_size,
                    arrival_microseconds,
                    first_header_byte,
                    second_header_byte,
                    authentication_tag
                  );
                }
              }
            } else if (audio_rtp_candidate) {
              const auto audio_rtp = lumen::lsp::parse_rtp_fixed_header(plaintext);
              if (audio_rtp && audio_rtp.header.ssrc == audio_configuration_.audio_ssrc &&
                  audio_rtp.header.payload_type == audio_configuration_.audio_payload_type) {
                record_audio_feedback(plaintext, protected_datagram_size, arrival_microseconds, ecn);
                store_authenticated_rtp_fingerprint(
                  authenticated_audio_fingerprints_,
                  visible_sequence,
                  visible_ssrc,
                  visible_timestamp,
                  protected_datagram_size,
                  arrival_microseconds,
                  first_header_byte,
                  second_header_byte,
                  authentication_tag
                );
              }
            }
            const auto handled = handle_authenticated_realtime(
              plaintext,
              rtcp,
              arrival_microseconds,
              authenticated_microseconds,
              receive_lease.token()
            );
            if (realtime_failure_status_ != CLSP_STATUS_OK) {
              const auto failure = realtime_failure_status_;
              realtime_failure_status_ = CLSP_STATUS_OK;
              return failure;
            }
            if (!handled) {
              increment(RuntimeCounter::dropped);
            } else {
              note_authenticated_inbound(authenticated_microseconds);
            }
            break;
            }
          case PacketClass::invalid:
            increment(RuntimeCounter::dropped);
            break;
        }
      }
      if (drained_datagrams != 0U) {
        const auto drained_microseconds = monotonic_microseconds();
        record_timing_stage(
          CLSP_NATIVE_TIMING_SOCKET_BATCH_DRAIN,
          drain_started_microseconds,
          drained_microseconds
        );
        record_timing_stage(
          CLSP_NATIVE_TIMING_SOCKET_BATCH_OLDEST_AGE,
          oldest_arrival_microseconds,
          drained_microseconds,
          (batch_used_kernel_timestamp ? CLSP_NATIVE_TIMING_KERNEL_TIMESTAMPED : 0U) |
          (batch_used_fallback_timestamp ? CLSP_NATIVE_TIMING_UNKNOWN_COMPONENT : 0U)
        );
      }
      return CLSP_STATUS_OK;
    }

    /** @brief Authenticate/process deferred video only after urgent reverse submission. */
    void clear_deferred_video_batch() noexcept {
      for (std::size_t index = 0; index < deferred_video_count_; ++index) {
        if (deferred_video_[index].token != 0U) {
          (void)video_receive_pool_.release(deferred_video_[index].token);
        }
        deferred_video_[index] = {};
      }
      deferred_video_count_ = 0;
    }

    /** @brief Authenticate/process deferred video only after urgent reverse submission. */
    [[nodiscard]] clsp_status_t process_deferred_video_batch() noexcept {
      for (std::size_t index = 0; index < deferred_video_count_; ++index) {
        auto &deferred = deferred_video_[index];
        VideoReceiveLease receive_lease;
        if (!receive_lease.adopt(video_receive_pool_, deferred.token)) {
          record_local_video_pressure();
          increment(RuntimeCounter::dropped);
          continue;
        }
        deferred.token = 0;
        auto receive_storage = receive_lease.bytes();
        auto datagram = receive_storage.first(deferred.length);
        const auto protected_datagram_size = static_cast<std::uint16_t>(deferred.length);
        const auto visible_ssrc = lumen::lsp::wire::read_be<std::uint32_t>(datagram.subspan(8, 4));
        const auto video_lane = video_lane_for_ssrc(visible_ssrc);
        if (video_lane == VideoRtpLane::none || !inbound_ssrc_registered(visible_ssrc, false) || datagram.size() < 28U) {
          increment(RuntimeCounter::dropped);
          continue;
        }
        const auto visible_sequence = lumen::lsp::wire::read_be<std::uint16_t>(datagram.subspan(2, 2));
        const auto visible_timestamp = lumen::lsp::wire::read_be<std::uint32_t>(datagram.subspan(4, 4));
        const auto first_header_byte = datagram[0];
        const auto second_header_byte = datagram[1];
        std::array<std::uint8_t, 16> authentication_tag {};
        std::copy(datagram.end() - 16, datagram.end(), authentication_tag.begin());
        auto packet_length = datagram.size();
        bool replay = false;
        const auto unprotect_status = srtp_.unprotect_video(receive_storage, packet_length, false, replay);
        if (unprotect_status != CLSP_STATUS_OK) {
          timing_distributions_[CLSP_NATIVE_TIMING_RECEIVE_TO_AUTH].drop(
            deferred.kernel_timestamped ? CLSP_NATIVE_TIMING_KERNEL_TIMESTAMPED :
                                            CLSP_NATIVE_TIMING_UNKNOWN_COMPONENT
          );
          if (replay) {
            auto *fingerprints = video_fingerprints(video_lane);
            if (fingerprints != nullptr) {
              if (const auto *fingerprint = authenticated_rtp_fingerprint(
                    *fingerprints,
                    visible_sequence,
                    visible_ssrc,
                    visible_timestamp,
                    protected_datagram_size,
                    first_header_byte,
                    second_header_byte,
                    authentication_tag
                  )) {
                record_video_duplicate_ce(*fingerprint, deferred.ecn, video_lane);
                increment(RuntimeCounter::received);
                continue;
              }
            }
          }
          increment(RuntimeCounter::authentication_failure);
          continue;
        }
        const auto authenticated_microseconds = monotonic_microseconds();
        record_timing_stage(
          CLSP_NATIVE_TIMING_RECEIVE_TO_AUTH,
          deferred.arrival_microseconds,
          authenticated_microseconds,
          deferred.kernel_timestamped ? CLSP_NATIVE_TIMING_KERNEL_TIMESTAMPED :
                                          CLSP_NATIVE_TIMING_UNKNOWN_COMPONENT
        );
        increment(RuntimeCounter::received);
        if (protected_datagram_size > receive_udp_payload_size_.load(std::memory_order_acquire)) {
          increment(RuntimeCounter::dropped);
          continue;
        }
        const auto plaintext = std::span<const std::uint8_t> {receive_storage.data(), packet_length};
        const auto video_rtp = lumen::lsp::parse_rtp_fixed_header(plaintext);
        if (!video_rtp || video_rtp.header.ssrc != visible_ssrc ||
            video_rtp.header.payload_type != video_payload_type(video_lane)) {
          increment(RuntimeCounter::dropped);
          continue;
        }
        record_video_feedback_for_lane(
          plaintext,
          protected_datagram_size,
          deferred.arrival_microseconds,
          deferred.ecn,
          video_lane
        );
        if (auto *fingerprints = video_fingerprints(video_lane); fingerprints != nullptr) {
          store_authenticated_rtp_fingerprint(
            *fingerprints,
            visible_sequence,
            visible_ssrc,
            visible_timestamp,
            protected_datagram_size,
            deferred.arrival_microseconds,
            first_header_byte,
            second_header_byte,
            authentication_tag
          );
        }
        if (!handle_authenticated_realtime(
              plaintext,
              false,
              deferred.arrival_microseconds,
              authenticated_microseconds,
              receive_lease.token()
            )) {
          increment(RuntimeCounter::dropped);
        } else {
          note_authenticated_inbound(authenticated_microseconds);
        }
        if (realtime_failure_status_ != CLSP_STATUS_OK) {
          const auto failure = realtime_failure_status_;
          realtime_failure_status_ = CLSP_STATUS_OK;
          clear_deferred_video_batch();
          return failure;
        }
      }
      clear_deferred_video_batch();
      return CLSP_STATUS_OK;
    }

    /** @brief Queue exact inbound SRTP installs and wait for socket-thread completion. */
    [[nodiscard]] clsp_status_t install_inbound_security_streams(
      const std::span<const InboundSecurityStream> streams
    ) noexcept {
      if (streams.empty() || streams.size() > 3U) {
        return CLSP_STATUS_INVALID_ARGUMENT;
      }
      pthread_mutex_lock(&mutex_);
      if (pending_inbound_security_install_.pending ||
          pending_inbound_security_install_.awaiting_result) {
        pthread_mutex_unlock(&mutex_);
        return CLSP_STATUS_INVALID_STATE;
      }
      auto token = next_inbound_security_install_token_++;
      if (token == 0) {
        token = next_inbound_security_install_token_++;
      }
      if (token == 0) {
        pthread_mutex_unlock(&mutex_);
        return CLSP_STATUS_INTERNAL_FAILURE;
      }
      pending_inbound_security_install_ = {};
      std::copy(streams.begin(), streams.end(), pending_inbound_security_install_.streams.begin());
      pending_inbound_security_install_.token = token;
      pending_inbound_security_install_.stream_count = streams.size();
      pending_inbound_security_install_.pending = true;
      pending_inbound_security_install_.awaiting_result = true;
      pthread_mutex_unlock(&mutex_);
      wake_worker();

      timespec deadline {};
      if (clock_gettime(CLOCK_REALTIME, &deadline) != 0) {
        return CLSP_STATUS_INTERNAL_FAILURE;
      }
      ++deadline.tv_sec;
      pthread_mutex_lock(&mutex_);
      while (completed_inbound_security_install_token_ < token) {
        const auto wait = pthread_cond_timedwait(&condition_, &mutex_, &deadline);
        if (wait == ETIMEDOUT) {
          pending_inbound_security_install_.awaiting_result = false;
          pthread_mutex_unlock(&mutex_);
          return CLSP_STATUS_TIMEOUT;
        }
        if (wait != 0) {
          pending_inbound_security_install_.awaiting_result = false;
          pthread_mutex_unlock(&mutex_);
          return CLSP_STATUS_INTERNAL_FAILURE;
        }
      }
      const auto result = pending_inbound_security_install_.result;
      pending_inbound_security_install_.awaiting_result = false;
      pthread_mutex_unlock(&mutex_);
      return result;
    }

    /** @brief Execute one queued exact-SSRC libSRTP install on the socket thread. */
    void process_inbound_security_install() noexcept {
      PendingInboundSecurityInstall selected;
      pthread_mutex_lock(&mutex_);
      if (!pending_inbound_security_install_.pending) {
        pthread_mutex_unlock(&mutex_);
        return;
      }
      selected = pending_inbound_security_install_;
      pthread_mutex_unlock(&mutex_);

      auto result = CLSP_STATUS_OK;
      for (const auto &stream : std::span<const InboundSecurityStream> {selected.streams}.first(
             selected.stream_count
           )) {
        result = srtp_.configure_inbound_stream(
          stream.ssrc,
          std::span<const int> {stream.encrypted_extensions}.first(stream.encrypted_extension_count)
        );
        if (result != CLSP_STATUS_OK) {
          break;
        }
      }
      pthread_mutex_lock(&mutex_);
      if (pending_inbound_security_install_.pending &&
          pending_inbound_security_install_.token == selected.token) {
        pending_inbound_security_install_.result = result;
        pending_inbound_security_install_.pending = false;
        completed_inbound_security_install_token_ = selected.token;
        pthread_cond_broadcast(&condition_);
      }
      pthread_mutex_unlock(&mutex_);
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
      const auto selected_baseline_id = pending_baseline_id_;
      pending_baseline_id_ = 0;
      token = pending_input_configuration_token_;
      input_configuration_pending_ = false;
      pthread_mutex_unlock(&mutex_);

      const auto restoring_same_mapping = input_configured_ &&
                                          input_configuration_.input_generation == selected.input_generation &&
                                          input_configuration_.input_ssrc == selected.input_ssrc &&
                                          input_configuration_.acknowledgement_ssrc == selected.acknowledgement_ssrc &&
                                          input_configuration_.input_payload_type == selected.input_payload_type;
      input_configuration_ = selected;
      pending_controller_ack_ = {};
      const auto pointer_generation = std::max<std::uint32_t>(
        1U,
        published_pointer_generation_.load(std::memory_order_acquire)
      );
      if (!pointer_composer_.reset(1, pointer_generation) || !edge_sender_.reset(selected.input_generation)) {
        return CLSP_STATUS_INTERNAL_FAILURE;
      }
      for (std::size_t index = 0; index < controller_states_.size(); ++index) {
        const auto controller_generation = published_controller_generations_[index].load(std::memory_order_acquire);
        controller_states_[index] = {};
        controller_states_[index].physical_ordinal = 1U;
        controller_states_[index].value.controller_id = static_cast<std::uint32_t>(index + 1U);
        controller_states_[index].value.instance_generation = controller_generation;
        for (auto &sensor : controller_sensors_[index]) {
          sensor = {};
          sensor.physical_ordinal = 1U;
        }
        touch_states_[index] = {};
        touch_states_[index].physical_ordinal = 1U;
      }
      input_configured_ = true;
      capture_accepting_ = true;
      baseline_acknowledged_ = false;
      baseline_id_ = selected_baseline_id != 0U ? selected_baseline_id :
        (static_cast<std::uint64_t>(arc4random()) << 32U) | arc4random();
      if (baseline_id_ == 0) {
        baseline_id_ = 1;
      }
      if (callbacks_.input_baseline != nullptr) {
        callbacks_.input_baseline(
          callbacks_.context,
          false,
          connection_generation_,
          selected.input_generation,
          baseline_id_
        );
      }
      baseline_last_sent_us_ = 0;
      baseline_body_length_ = 0;
      baseline_edge_watermark_ = 0;
      baseline_next_part_index_ = 0U;
      baseline_part_count_ = 0U;
      baseline_first_submitted_microseconds_ = 0U;
      pointer_dirty_ = false;
      pointer_ordinal_ = 1U;
      pointer_composed_microseconds_ = 0U;
      for (auto &timing : edge_timing_) timing = {};
      latest_edge_id_ = 0;
      published_stream_generation_.store(selected.stream_generation, std::memory_order_release);
      published_input_generation_.store(selected.input_generation, std::memory_order_release);
      published_latest_edge_id_.store(0U, std::memory_order_release);
      published_latest_edge_time_.store(0U, std::memory_order_release);
      latest_state_sequence_ = 2;
      next_state_sequence_ = 2;
      if (!restoring_same_mapping) {
        rtp_sequence_ = static_cast<std::uint16_t>(arc4random());
        input_next_extended_sequence_ = rtp_sequence_;
        for (auto &record : input_sent_packets_) {
          record = {};
        }
        input_sender_report_timings_ = {};
        input_sender_report_timing_index_ = 0;
        input_bytes_in_flight_ = 0;
        input_delivered_bytes_ = 0;
        input_lost_bytes_ = 0;
        input_ecn_ce_bytes_ = 0;
        input_last_delay_send_microseconds_ = 0;
        input_last_delay_arrival_timestamp_ = 0;
        input_last_rtp_send_microseconds_ = 0;
        input_last_rtp_timestamp_ = 0;
        input_packet_count_ = 0;
        input_octet_count_ = 0;
        input_has_delay_sample_ = false;
        microphone_feedback_cname_length_ = 0;
        microphone_last_compound_microseconds_ = 0;
        microphone_last_feedback_microseconds_ = 0;
        microphone_last_feedback_timestamp_ = 0;
        microphone_smoothed_rtt_microseconds_ = 0;
        microphone_rtt_variation_microseconds_ = 0;
        microphone_has_feedback_timestamp_ = false;
        microphone_congestion_.reset();
        reverse_controller_includes_microphone_ = false;
        reverse_congestion_rate_bits_per_second_ = selected.reserved_input_wire_bits_per_second;
      }
      if (compound_cname_length_ == 0) {
        constexpr std::array<std::uint8_t, 16> hexadecimal {
          '0',
          '1',
          '2',
          '3',
          '4',
          '5',
          '6',
          '7',
          '8',
          '9',
          'a',
          'b',
          'c',
          'd',
          'e',
          'f'
        };
        compound_cname_[0] = 'l';
        compound_cname_[1] = 's';
        compound_cname_[2] = 'p';
        compound_cname_[3] = '-';
        for (std::size_t index = 0; index < 16U; ++index) {
          const auto byte = static_cast<std::uint8_t>(arc4random());
          compound_cname_[4U + index * 2U] = hexadecimal[byte >> 4U];
          compound_cname_[5U + index * 2U] = hexadecimal[byte & 0x0fU];
        }
        compound_cname_length_ = 36U;
      }
      input_tokens_bits_ = selected.reserved_input_wire_bits_per_second / 500U;
      input_last_credit_us_ = monotonic_microseconds();
      reverse_tokens_bits_ = input_tokens_bits_;
      reverse_last_credit_us_ = input_last_credit_us_;
      last_pointer_sent_us_ = 0;
      pthread_mutex_lock(&mutex_);
      input_feedback_snapshot_ = {
        .abi_version = CLSP_CORE_ABI_VERSION,
        .structure_size = sizeof(clsp_input_feedback_snapshot_t),
        .stream_generation = selected.stream_generation,
        .input_generation = selected.input_generation,
        .pointer_rate = selected.pointer_rate,
        .controller_rate = selected.controller_rate,
        .sensor_rate = selected.sensor_rate,
        .reconciliation_rate = selected.reconciliation_rate,
        .reserved_input_wire_bits_per_second = selected.reserved_input_wire_bits_per_second,
      };
      input_configuration_completed_.store(token, std::memory_order_release);
      pthread_cond_broadcast(&condition_);
      pthread_mutex_unlock(&mutex_);
      return CLSP_STATUS_OK;
    }

    /** @brief Move captured records into portable native composers. */
    [[nodiscard]] clsp_status_t process_input_rate_update() noexcept {
      clsp_input_rate_update_t selected {};
      std::uint64_t token = 0;
      pthread_mutex_lock(&mutex_);
      if (!pending_input_rate_update_) {
        pthread_mutex_unlock(&mutex_);
        return CLSP_STATUS_OK;
      }
      selected = pending_input_rates_;
      token = pending_input_rate_token_;
      pending_input_rate_update_ = false;
      pthread_mutex_unlock(&mutex_);
      if (!input_configured_ || selected.stream_generation != input_configuration_.stream_generation ||
          selected.input_generation != input_configuration_.input_generation) return CLSP_STATUS_INVALID_STATE;
      input_configuration_.pointer_rate = selected.pointer_rate;
      input_configuration_.controller_rate = selected.controller_rate;
      input_configuration_.sensor_rate = selected.sensor_rate;
      input_configuration_.reconciliation_rate = selected.reconciliation_rate;
      input_configuration_.reserved_input_wire_bits_per_second = selected.reserved_input_wire_bits_per_second;
      input_tokens_bits_ = std::min(
        input_tokens_bits_,
        selected.reserved_input_wire_bits_per_second / 500U
      );
      if (!reset_reverse_congestion_controller()) {
        return CLSP_STATUS_INVALID_CONFIGURATION;
      }
      if (microphone_active_.load(std::memory_order_acquire)) {
        microphone_tokens_bits_ = std::min(
          microphone_tokens_bits_,
          microphone_credit_capacity(
            microphone_configuration_,
            microphone_congestion_rate_bits_per_second_
          )
        );
      }
      const auto reverse_capacity = std::max<std::uint64_t>(
        selected.reserved_input_wire_bits_per_second / 500U +
          microphone_congestion_rate_bits_per_second_ / 25U,
        2U * static_cast<std::uint64_t>(maximum_udp_payload + ip_udp_overhead_bytes()) * 8U
      );
      reverse_tokens_bits_ = std::min(reverse_tokens_bits_, reverse_capacity);
      pthread_mutex_lock(&mutex_);
      input_feedback_snapshot_.pointer_rate = selected.pointer_rate;
      input_feedback_snapshot_.controller_rate = selected.controller_rate;
      input_feedback_snapshot_.sensor_rate = selected.sensor_rate;
      input_feedback_snapshot_.reconciliation_rate = selected.reconciliation_rate;
      input_feedback_snapshot_.reserved_input_wire_bits_per_second = selected.reserved_input_wire_bits_per_second;
      input_rate_update_completed_.store(token, std::memory_order_release);
      pthread_cond_broadcast(&condition_);
      pthread_mutex_unlock(&mutex_);
      return CLSP_STATUS_OK;
    }

    /** @brief Return the local captured timestamp carried by one native input record. */
    [[nodiscard]] static std::uint64_t capture_record_timestamp(const CaptureRecord &record) noexcept {
      switch (record.kind) {
        case CaptureKind::pointer:
          return record.pointer.sample_time_microseconds;
        case CaptureKind::edge:
          return record.edge.sample_time_microseconds;
        case CaptureKind::controller_edge:
          return record.controller_edge.sample_time_microseconds;
        case CaptureKind::controller_state:
          return record.controller_state.sample_time_microseconds;
        case CaptureKind::controller_sensor:
          return record.controller_sensor.sample_time_microseconds;
        case CaptureKind::touch_edge:
          return record.touch_edge.sample_time_microseconds;
        case CaptureKind::touch_state:
          return record.touch_state.sample_time_microseconds;
        case CaptureKind::neutralize:
          return 0U;
      }
      return 0U;
    }

    /** @brief Retain one bounded edge correlation until authenticated LSPI acknowledgement. */
    void retain_edge_timing(
      const std::uint64_t edge_id,
      const std::uint64_t composed_microseconds
    ) noexcept {
      auto &slot = edge_timing_[edge_id % edge_timing_.size()];
      if (slot.occupied && slot.edge_id != edge_id) {
        timing_distributions_[CLSP_NATIVE_TIMING_INPUT_ACK_AGE].drop();
      }
      slot = {
        .edge_id = edge_id,
        .composed_microseconds = composed_microseconds,
        .occupied = true,
      };
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
        const auto composed_microseconds = monotonic_microseconds();
        const auto captured_microseconds = capture_record_timestamp(record);
        if (captured_microseconds != 0U) {
          record_timing_stage(
            CLSP_NATIVE_TIMING_INPUT_CALLBACK_TO_COMPOSE,
            captured_microseconds,
            composed_microseconds,
            record.timestamp_unknown ? CLSP_NATIVE_TIMING_UNKNOWN_COMPONENT : 0U
          );
        }

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
            record.device_generation,
            pointer_ordinal_,
            record.pointer.delta_x,
            record.pointer.delta_y,
            record.pointer.vertical_scroll,
            record.pointer.horizontal_scroll
          );
          if (result == lumen::lsp::input_plane::pointer_compose_result::accepted) {
            pointer_dirty_ = true;
            pointer_sample_time_us_ = record.pointer.sample_time_microseconds;
            pointer_composed_microseconds_ = composed_microseconds;
          } else if (result != lumen::lsp::input_plane::pointer_compose_result::batch_full) {
            return CLSP_STATUS_INTERNAL_FAILURE;
          }
          continue;
        }

        if (record.kind == CaptureKind::controller_state) {
          auto &state = controller_states_[record.controller_state.controller_id - 1U];
          if (published_controller_generations_[record.controller_state.controller_id - 1U].load(
                std::memory_order_acquire
              ) != record.controller_state.instance_generation) {
            continue;
          }
          state.value = record.controller_state;
          ++state.physical_ordinal;
          state.composed_microseconds = composed_microseconds;
          state.dirty = true;
          continue;
        }
        if (record.kind == CaptureKind::controller_sensor) {
          if (published_controller_generations_[record.controller_sensor.controller_id - 1U].load(
                std::memory_order_acquire
              ) != record.controller_sensor.instance_generation) {
            continue;
          }
          auto &sensor = controller_sensors_[record.controller_sensor.controller_id - 1U]
                                            [record.controller_sensor.sensor_type - 1U];
          sensor.value = record.controller_sensor;
          ++sensor.physical_ordinal;
          sensor.composed_microseconds = composed_microseconds;
          sensor.dirty = true;
          continue;
        }
        if (record.kind == CaptureKind::controller_edge || record.kind == CaptureKind::touch_edge) {
          const auto controller = record.kind == CaptureKind::controller_edge;
          if (controller) {
            const auto index = record.controller_edge.controller_id - 1U;
            auto &state = controller_states_[index];
            if (record.controller_edge.kind == 5U) {
              state = {};
              state.value.controller_id = record.controller_edge.controller_id;
              state.value.instance_generation = record.controller_edge.instance_generation;
              state.physical_ordinal = 1U;
              for (auto &sensor : controller_sensors_[index]) {
                sensor = {};
                sensor.physical_ordinal = 1U;
              }
              touch_states_[index] = {};
              touch_states_[index].physical_ordinal = 1U;
            } else if (record.controller_edge.kind == 6U) {
              state.buttons = 0U;
              state.dirty = false;
              for (auto &sensor : controller_sensors_[index]) sensor.dirty = false;
              touch_states_[index].active = false;
              touch_states_[index].dirty = false;
            } else if (record.controller_edge.control_id < 64U) {
              const auto mask = std::uint64_t {1} << record.controller_edge.control_id;
              if (record.controller_edge.kind == 7U) state.buttons |= mask;
              if (record.controller_edge.kind == 8U) state.buttons &= ~mask;
              state.composed_microseconds = composed_microseconds;
              state.dirty = true;
            }
          } else {
            auto &touch = touch_states_[record.touch_edge.controller_id - 1U];
            if (record.touch_edge.kind == 9U) touch.active = true;
            if (record.touch_edge.kind == 10U || record.touch_edge.kind == 11U) touch.active = false;
            touch.composed_microseconds = composed_microseconds;
            touch.dirty = true;
          }
          lumen::lsp::input_plane::edge_record edge {
            .physical_time_us = controller ? record.controller_edge.sample_time_microseconds : record.touch_edge.sample_time_microseconds,
            .kind = static_cast<lumen::lsp::input_plane::edge_kind>(controller ? record.controller_edge.kind : record.touch_edge.kind),
            .device = controller ? lumen::lsp::input_plane::device_type::controller : lumen::lsp::input_plane::device_type::touch,
            .control_id = controller ? record.controller_edge.control_id : static_cast<std::uint16_t>(record.touch_edge.contact_id),
            .device_id = controller ? record.controller_edge.controller_id : record.touch_edge.controller_id,
            .instance_generation = controller ? record.controller_edge.instance_generation : record.touch_edge.instance_generation,
          };
          std::uint64_t assigned_id = 0;
          if (edge_sender_.enqueue(edge, assigned_id) != lumen::lsp::input_plane::edge_send_result::accepted) {
            return CLSP_STATUS_RESOURCE_EXHAUSTED;
          }
          latest_edge_id_ = assigned_id;
          retain_edge_timing(assigned_id, composed_microseconds);
          published_latest_edge_id_.store(assigned_id, std::memory_order_release);
          published_latest_edge_time_.store(edge.physical_time_us, std::memory_order_release);
          continue;
        }
        if (record.kind == CaptureKind::touch_state) {
          auto &touch = touch_states_[record.touch_state.controller_id - 1U];
          if (published_touch_generations_[record.touch_state.controller_id - 1U].load(
                std::memory_order_acquire
              ) != record.touch_state.instance_generation) {
            continue;
          }
          touch.value = record.touch_state;
          ++touch.physical_ordinal;
          touch.composed_microseconds = composed_microseconds;
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
        retain_edge_timing(assigned_id, composed_microseconds);
        published_latest_edge_id_.store(assigned_id, std::memory_order_release);
        published_latest_edge_time_.store(edge.physical_time_us, std::memory_order_release);
      }
    }

    /** @brief Send baseline, due edge retries, and latest cumulative pointer state. */
    [[nodiscard]] clsp_status_t transmit_input() noexcept {
      if (!input_configured_) {
        return CLSP_STATUS_OK;
      }
      const auto now = monotonic_microseconds();
      replenish_input_credit(now);
      replenish_reverse_credit(now);
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

    /** @brief Freeze every active device generation into one deterministic neutral baseline body. */
    [[nodiscard]] clsp_status_t build_neutral_baseline() noexcept {
      using namespace lumen::lsp::input_plane;
      baseline_edge_watermark_ = latest_edge_id_;
      std::array<input_baseline_record_view, maximum_input_baseline_records> records {};
      std::size_t record_count = 0U;
      auto append = [&](const input_baseline_record_header &header, const auto &payload) noexcept {
        if (record_count >= records.size()) return false;
        records[record_count++] = {.header = header, .payload = payload};
        return true;
      };

      std::array<std::uint8_t, core_state_payload_size> core_payload {};
      const core_state_payload core {
        .neutral = true,
        .keyboard_instance_generation = 1U,
        .physical_ordinal = 1U,
        .text_barrier_edge_id = baseline_edge_watermark_,
      };
      if (serialize_core_state_payload(core, core_payload) != wire_error::none ||
          !append(
            {
              .kind = baseline_record_kind::core,
              .payload_length = static_cast<std::uint32_t>(core_payload.size()),
              .instance_generation = 1U,
              .state_sequence = 1U,
              .physical_ordinal = 1U,
            },
            core_payload
          )) return CLSP_STATUS_INTERNAL_FAILURE;

      constexpr std::size_t maximum_lifecycle_records = 49U;
      std::array<std::array<std::uint8_t, 4>, maximum_lifecycle_records> lifecycle_payloads {};
      std::size_t lifecycle_count = 0U;
      auto append_lifecycle = [&](const device_type device, const std::uint32_t device_id, const std::uint32_t generation) noexcept {
        if (generation == 0U || lifecycle_count >= lifecycle_payloads.size()) return generation == 0U;
        auto &payload = lifecycle_payloads[lifecycle_count++];
        if (serialize_device_lifecycle_payload({.device = device, .presence = device_presence::active}, payload) !=
            wire_error::none) return false;
        return append(
          {
            .kind = baseline_record_kind::device_lifecycle,
            .subtype = static_cast<std::uint8_t>(device),
            .payload_length = static_cast<std::uint32_t>(payload.size()),
            .device_id = device_id,
            .instance_generation = generation,
            .state_sequence = 1U,
            .physical_ordinal = 1U,
          },
          payload
        );
      };

      const auto pointer_generation = std::max<std::uint32_t>(
        1U,
        published_pointer_generation_.load(std::memory_order_acquire)
      );
      if (!append_lifecycle(device_type::pointer, 1U, pointer_generation)) return CLSP_STATUS_RESOURCE_EXHAUSTED;
      for (std::size_t index = 0; index < 16U; ++index) {
        const auto generation = published_controller_generations_[index].load(std::memory_order_acquire);
        if (generation != 0U && !append_lifecycle(device_type::controller, index + 1U, generation)) {
          return CLSP_STATUS_RESOURCE_EXHAUSTED;
        }
      }
      for (std::size_t index = 0; index < 16U; ++index) {
        const auto generation = published_touch_generations_[index].load(std::memory_order_acquire);
        if (generation != 0U && !append_lifecycle(device_type::touch, index + 1U, generation)) {
          return CLSP_STATUS_RESOURCE_EXHAUSTED;
        }
      }
      for (std::size_t index = 0; index < 16U; ++index) {
        const auto generation = published_pen_generations_[index].load(std::memory_order_acquire);
        if (generation != 0U && !append_lifecycle(device_type::pen, index + 1U, generation)) {
          return CLSP_STATUS_RESOURCE_EXHAUSTED;
        }
      }

      std::array<std::uint8_t, pointer_payload_size> pointer_bytes {};
      const pointer_payload pointer {
        .instance_generation = pointer_generation,
        .mode = pointer_flag::relative,
        .represented_reports = 1U,
        .physical_ordinal = 1U,
      };
      if (serialize_pointer_payload(pointer, pointer_bytes) != wire_error::none ||
          !append(
            {
              .kind = baseline_record_kind::pointer,
              .payload_length = static_cast<std::uint32_t>(pointer_bytes.size()),
              .device_id = 1U,
              .instance_generation = pointer_generation,
              .state_sequence = 1U,
              .physical_ordinal = 1U,
            },
            pointer_bytes
          )) return CLSP_STATUS_INTERNAL_FAILURE;

      std::array<std::array<std::uint8_t, controller_state_payload_size>, 16> controller_payloads {};
      for (std::size_t index = 0; index < 16U; ++index) {
        const auto generation = published_controller_generations_[index].load(std::memory_order_acquire);
        if (generation == 0U) continue;
        controller_state_payload state {
          .prefix = {
            .device = device_type::controller,
            .represented_reports = 1U,
            .device_id = static_cast<std::uint32_t>(index + 1U),
            .instance_generation = generation,
            .record_length = controller_state_payload_size,
            .physical_ordinal = 1U,
          },
        };
        auto &payload = controller_payloads[index];
        if (serialize_controller_state_payload(state, payload) != wire_error::none ||
            !append(
              {
                .kind = baseline_record_kind::controller,
                .payload_length = static_cast<std::uint32_t>(payload.size()),
                .device_id = static_cast<std::uint32_t>(index + 1U),
                .instance_generation = generation,
                .state_sequence = 1U,
                .physical_ordinal = 1U,
              },
              payload
            )) return CLSP_STATUS_INTERNAL_FAILURE;
      }

      std::array<std::array<std::uint8_t, controller_sensor_payload_size>, 32> sensor_payloads {};
      std::size_t sensor_payload_count = 0U;
      for (std::uint8_t sensor_value = 1U; sensor_value <= 2U; ++sensor_value) {
        for (std::size_t index = 0; index < 16U; ++index) {
          const auto generation = published_controller_generations_[index].load(std::memory_order_acquire);
          const auto mask = published_controller_sensor_masks_[index].load(std::memory_order_acquire);
          if (generation == 0U || (mask & (1U << (sensor_value - 1U))) == 0U) continue;
          controller_sensor_payload sensor {
            .prefix = {
              .device = device_type::controller,
              .represented_reports = 1U,
              .device_id = static_cast<std::uint32_t>(index + 1U),
              .instance_generation = generation,
              .record_length = controller_sensor_payload_size,
              .physical_ordinal = 1U,
            },
            .sensor = static_cast<sensor_type>(sensor_value),
          };
          auto &payload = sensor_payloads[sensor_payload_count++];
          if (serialize_controller_sensor_payload(sensor, payload) != wire_error::none ||
              !append(
                {
                  .kind = baseline_record_kind::controller_sensor,
                  .subtype = sensor_value,
                  .payload_length = static_cast<std::uint32_t>(payload.size()),
                  .device_id = static_cast<std::uint32_t>(index + 1U),
                  .instance_generation = generation,
                  .state_sequence = 1U,
                  .physical_ordinal = 1U,
                },
                payload
              )) return CLSP_STATUS_INTERNAL_FAILURE;
        }
      }

      std::array<std::array<std::uint8_t, touch_state_header_size>, 16> touch_payloads {};
      for (std::size_t index = 0; index < 16U; ++index) {
        const auto generation = published_touch_generations_[index].load(std::memory_order_acquire);
        if (generation == 0U) continue;
        const touch_state_view touch {
          .prefix = {
            .device = device_type::touch,
            .represented_reports = 1U,
            .device_id = static_cast<std::uint32_t>(index + 1U),
            .instance_generation = generation,
            .record_length = touch_state_header_size,
            .physical_ordinal = 1U,
          },
        };
        auto &payload = touch_payloads[index];
        if (serialize_touch_state_payload(touch, payload) != wire_error::none ||
            !append(
              {
                .kind = baseline_record_kind::touch,
                .payload_length = static_cast<std::uint32_t>(payload.size()),
                .device_id = static_cast<std::uint32_t>(index + 1U),
                .instance_generation = generation,
                .state_sequence = 1U,
                .physical_ordinal = 1U,
              },
              payload
            )) return CLSP_STATUS_INTERNAL_FAILURE;
      }

      std::array<std::array<std::uint8_t, pen_state_payload_size>, 16> pen_payloads {};
      for (std::size_t index = 0; index < 16U; ++index) {
        const auto generation = published_pen_generations_[index].load(std::memory_order_acquire);
        if (generation == 0U) continue;
        const pen_state_payload pen {
          .prefix = {
            .device = device_type::pen,
            .represented_reports = 1U,
            .device_id = static_cast<std::uint32_t>(index + 1U),
            .instance_generation = generation,
            .record_length = pen_state_payload_size,
            .physical_ordinal = 1U,
          },
        };
        auto &payload = pen_payloads[index];
        if (serialize_pen_state_payload(pen, payload) != wire_error::none ||
            !append(
              {
                .kind = baseline_record_kind::pen,
                .payload_length = static_cast<std::uint32_t>(payload.size()),
                .device_id = static_cast<std::uint32_t>(index + 1U),
                .instance_generation = generation,
                .state_sequence = 1U,
                .physical_ordinal = 1U,
              },
              payload
            )) return CLSP_STATUS_INTERNAL_FAILURE;
      }

      const auto serialized = serialize_input_baseline(
        {
          .neutral = true,
          .edge_watermark = baseline_edge_watermark_,
          .text_barrier_edge_id = baseline_edge_watermark_,
          .records = std::span<const input_baseline_record_view> {records}.first(record_count),
        },
        baseline_body_
      );
      if (serialized.error != wire_error::none || serialized.bytes_written == 0U) {
        return CLSP_STATUS_INTERNAL_FAILURE;
      }
      baseline_body_length_ = serialized.bytes_written;
      if (!parse_input_baseline(
            std::span<const std::uint8_t> {baseline_body_}.first(baseline_body_length_)
          )) return CLSP_STATUS_INTERNAL_FAILURE;
      baseline_part_count_ = static_cast<std::uint8_t>(
        (baseline_body_length_ + baseline_part_data_capacity - 1U) / baseline_part_data_capacity
      );
      baseline_next_part_index_ = 0U;
      if (baseline_part_count_ == 0U || baseline_part_count_ > maximum_baseline_parts ||
          wc_Sha256Hash(
            baseline_body_.data(),
            static_cast<word32>(baseline_body_length_),
            baseline_digest_.data()
          ) != 0) return CLSP_STATUS_INTERNAL_FAILURE;
      return CLSP_STATUS_OK;
    }

    /** @brief Serialize and send one path-safe part of the retained neutral baseline. */
    [[nodiscard]] clsp_status_t send_baseline(const std::uint64_t now) noexcept {
      if (baseline_body_length_ == 0U) {
        const auto build = build_neutral_baseline();
        if (build != CLSP_STATUS_OK) return build;
      }
      const auto part_index = baseline_next_part_index_;
      const auto part_offset = static_cast<std::size_t>(part_index) * baseline_part_data_capacity;
      const auto part_length = std::min(baseline_part_data_capacity, baseline_body_length_ - part_offset);
      const auto baseline = std::span<const std::uint8_t> {baseline_body_}.first(baseline_body_length_);
      std::array<
        std::uint8_t,
        lumen::lsp::input_plane::baseline_part_header_size + baseline_part_data_capacity
      > part_bytes {};
      const lumen::lsp::input_plane::baseline_part part {
        .part_index = part_index,
        .part_count = baseline_part_count_,
        .total_length = static_cast<std::uint32_t>(baseline.size()),
        .part_offset = static_cast<std::uint32_t>(part_offset),
        .part_length = static_cast<std::uint32_t>(part_length),
        .digest = baseline_digest_,
        .bytes = baseline.subspan(part_offset, part_length),
      };
      const auto part_output = std::span<std::uint8_t> {part_bytes}.first(
        lumen::lsp::input_plane::baseline_part_header_size + part_length
      );
      if (lumen::lsp::input_plane::serialize_baseline_part(part, part_output) !=
          lumen::lsp::input_plane::wire_error::none) return CLSP_STATUS_INTERNAL_FAILURE;
      const lumen::lsp::input_plane::common_header header {
        .input_generation = input_configuration_.input_generation,
        .kind = lumen::lsp::input_plane::packet_kind::baseline_part,
        .state_sequence = 1U,
        .sample_time_us = now,
        .object_id = baseline_id_,
        .edge_watermark = baseline_edge_watermark_,
      };
      bool submitted = false;
      const auto status = send_input_packet(header, part_output, now, submitted);
      if (status == CLSP_STATUS_OK && submitted) {
        if (baseline_first_submitted_microseconds_ == 0U) {
          baseline_first_submitted_microseconds_ = monotonic_microseconds();
        }
        baseline_next_part_index_ = static_cast<std::uint8_t>(part_index + 1U);
        if (baseline_next_part_index_ == baseline_part_count_) {
          baseline_next_part_index_ = 0U;
          baseline_last_sent_us_ = now;
        } else {
          baseline_last_sent_us_ = 0U;
        }
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
      if (status == CLSP_STATUS_OK && submitted) {
        const auto submitted_microseconds = monotonic_microseconds();
        for (const auto &edge : edges) {
          auto &timing = edge_timing_[edge.edge_id % edge_timing_.size()];
          if (!timing.occupied || timing.edge_id != edge.edge_id) {
            timing_distributions_[CLSP_NATIVE_TIMING_INPUT_ACK_AGE].drop();
            continue;
          }
          if (timing.first_submitted_microseconds == 0U) {
            timing.first_submitted_microseconds = submitted_microseconds;
          }
          timing.last_submitted_microseconds = submitted_microseconds;
          if (timing.transmissions != std::numeric_limits<std::uint8_t>::max()) ++timing.transmissions;
        }
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
      const auto status = send_input_packet(
        header,
        payload,
        now,
        submitted,
        pointer_composed_microseconds_,
        true
      );
      if (status == CLSP_STATUS_OK && submitted) {
        latest_state_sequence_ = sequence;
        ++next_state_sequence_;
        pointer_composer_.mark_emitted();
        pointer_dirty_ = false;
        last_pointer_sent_us_ = now;
      }
      return status;
    }

    /** @brief Convert one finite controller sensor component to signed Q16.16. */
    [[nodiscard]] static std::int32_t sensor_q16_16(const float value) noexcept {
      if (value != value) return 0;
      const auto bounded = std::clamp(static_cast<double>(value), -32'768.0, 32'767.9999847412109375);
      return static_cast<std::int32_t>(bounded * 65'536.0);
    }

    /** @brief Serialize and submit one exact frozen controller state record. */
    [[nodiscard]] clsp_status_t send_controller_state(const std::size_t index, const std::uint64_t now) noexcept {
      auto &state = controller_states_[index];
      lumen::lsp::input_plane::controller_state_payload frozen {
        .prefix = {
          .device = lumen::lsp::input_plane::device_type::controller,
          .represented_reports = 1U,
          .device_id = state.value.controller_id,
          .instance_generation = state.value.instance_generation,
          .record_length = lumen::lsp::input_plane::controller_state_payload_size,
          .physical_ordinal = state.physical_ordinal,
        },
        .buttons = state.buttons,
      };
      frozen.axes[0] = state.value.left_stick_x;
      frozen.axes[1] = state.value.left_stick_y;
      frozen.axes[2] = state.value.right_stick_x;
      frozen.axes[3] = state.value.right_stick_y;
      frozen.triggers[0] = static_cast<std::uint16_t>(state.value.left_trigger) * 257U;
      frozen.triggers[1] = static_cast<std::uint16_t>(state.value.right_trigger) * 257U;
      std::array<std::uint8_t, lumen::lsp::input_plane::controller_state_payload_size> payload {};
      if (lumen::lsp::input_plane::serialize_controller_state_payload(frozen, payload) !=
          lumen::lsp::input_plane::wire_error::none) return CLSP_STATUS_INTERNAL_FAILURE;
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
      const auto status = send_input_packet(
        header,
        payload,
        now,
        submitted,
        state.composed_microseconds,
        true
      );
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
      const lumen::lsp::input_plane::controller_sensor_payload frozen {
        .prefix = {
          .device = lumen::lsp::input_plane::device_type::controller,
          .represented_reports = 1U,
          .device_id = sensor.value.controller_id,
          .instance_generation = sensor.value.instance_generation,
          .record_length = lumen::lsp::input_plane::controller_sensor_payload_size,
          .physical_ordinal = sensor.physical_ordinal,
        },
        .sensor = static_cast<lumen::lsp::input_plane::sensor_type>(sensor.value.sensor_type),
        .vector = {
          sensor_q16_16(sensor.value.x),
          sensor_q16_16(sensor.value.y),
          sensor_q16_16(sensor.value.z),
        },
      };
      std::array<std::uint8_t, lumen::lsp::input_plane::controller_sensor_payload_size> payload {};
      if (lumen::lsp::input_plane::serialize_controller_sensor_payload(frozen, payload) !=
          lumen::lsp::input_plane::wire_error::none) return CLSP_STATUS_INTERNAL_FAILURE;
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
      const auto status = send_input_packet(
        header,
        payload,
        now,
        submitted,
        sensor.composed_microseconds,
        true
      );
      if (status == CLSP_STATUS_OK && submitted) {
        latest_state_sequence_ = sequence;
        ++next_state_sequence_;
        sensor.last_sent_us = now;
        sensor.dirty = false;
      }
      return status;
    }

    /** @brief Serialize and submit one exact frozen direct-touch device record. */
    [[nodiscard]] clsp_status_t send_touch_state(const std::size_t index, const std::uint64_t now) noexcept {
      auto &touch = touch_states_[index];
      const std::array<lumen::lsp::input_plane::touch_contact_payload, 1> contacts {{
        {
          .contact_id = static_cast<std::uint16_t>(touch.value.contact_id),
          .active = true,
          .x = touch.value.x,
          .y = touch.value.y,
          .pressure = static_cast<std::uint16_t>(touch.value.pressure >> 16U),
          .physical_ordinal = touch.physical_ordinal,
        },
      }};
      const auto active_contacts = touch.active ?
        std::span<const lumen::lsp::input_plane::touch_contact_payload> {contacts} :
        std::span<const lumen::lsp::input_plane::touch_contact_payload> {};
      const auto payload_length = lumen::lsp::input_plane::touch_state_header_size +
                                  active_contacts.size() * lumen::lsp::input_plane::touch_contact_size;
      const lumen::lsp::input_plane::touch_state_view frozen {
        .prefix = {
          .device = lumen::lsp::input_plane::device_type::touch,
          .represented_reports = 1U,
          .device_id = touch.value.controller_id,
          .instance_generation = touch.value.instance_generation,
          .record_length = static_cast<std::uint16_t>(payload_length),
          .physical_ordinal = touch.physical_ordinal,
        },
        .contacts = active_contacts,
      };
      std::array<
        std::uint8_t,
        lumen::lsp::input_plane::touch_state_header_size + lumen::lsp::input_plane::touch_contact_size
      > payload {};
      const auto live_payload = std::span<std::uint8_t> {payload}.first(payload_length);
      if (lumen::lsp::input_plane::serialize_touch_state_payload(frozen, live_payload) !=
          lumen::lsp::input_plane::wire_error::none) return CLSP_STATUS_INTERNAL_FAILURE;
      const auto sequence = next_state_sequence_;
      const lumen::lsp::input_plane::common_header header {
        .input_generation = input_configuration_.input_generation,
        .kind = lumen::lsp::input_plane::packet_kind::device_state,
        .state_sequence = sequence,
        .sample_time_us = touch.value.sample_time_microseconds,
        .object_id = lumen::lsp::input_plane::make_device_object_id(
          lumen::lsp::input_plane::device_type::touch,
          touch.value.controller_id
        ),
        .edge_watermark = latest_edge_id_,
      };
      bool submitted = false;
      const auto status = send_input_packet(
        header,
        live_payload,
        now,
        submitted,
        touch.composed_microseconds,
        true
      );
      if (status == CLSP_STATUS_OK && submitted) {
        latest_state_sequence_ = sequence;
        ++next_state_sequence_;
        touch.last_sent_us = now;
        touch.dirty = false;
      }
      return status;
    }

    /** @brief Record one successful or protect-consumed-unsent input sequence in O(1). */
    [[nodiscard]] bool record_input_terminal(
      const std::uint64_t extended_sequence,
      const std::uint64_t terminal_microseconds,
      const std::uint32_t complete_ip_bytes,
      const InputFeedbackState state
    ) noexcept {
      if (input_configuration_.input_generation == 0 || terminal_microseconds == 0 ||
          (state == InputFeedbackState::local_unsent) != (complete_ip_bytes == 0)) {
        return false;
      }
      auto &record = input_sent_packets_[static_cast<std::uint16_t>(extended_sequence)];
      if (record.occupied && record.state == InputFeedbackState::unreported) {
        return false;
      }
      record = {
        .extended_sequence = extended_sequence,
        .terminal_microseconds = terminal_microseconds,
        .complete_ip_bytes = complete_ip_bytes,
        .input_generation = input_configuration_.input_generation,
        .state = state,
        .occupied = true,
      };
      if (state == InputFeedbackState::unreported) {
        input_bytes_in_flight_ = saturating_rate_add(input_bytes_in_flight_, complete_ip_bytes);
      }
      return true;
    }

    /** @brief Wrap one checked input payload in RTP, protect in place, pace, and send. */
    [[nodiscard]] clsp_status_t send_input_packet(
      const lumen::lsp::input_plane::common_header &header,
      const std::span<const std::uint8_t> payload,
      const std::uint64_t now,
      bool &submitted,
      const std::uint64_t composed_microseconds = 0U,
      const bool attributable_device_state = false
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
      const auto charged_bits = static_cast<std::uint64_t>(
        length + 16U + ip_udp_overhead_bytes()
      ) * 8U;
      if (charged_bits > input_tokens_bits_ || charged_bits > reverse_tokens_bits_) {
        return CLSP_STATUS_OK;
      }
      const auto status = srtp_.protect(packet, length, false);
      if (status != CLSP_STATUS_OK) {
        if (composed_microseconds != 0U) {
          timing_distributions_[CLSP_NATIVE_TIMING_INPUT_COMPOSE_TO_PROTECT].drop();
        }
        return status;
      }
      const auto protected_microseconds = monotonic_microseconds();
      if (composed_microseconds != 0U) {
        record_timing_stage(
          CLSP_NATIVE_TIMING_INPUT_COMPOSE_TO_PROTECT,
          composed_microseconds,
          protected_microseconds
        );
      }
      const auto extended_sequence = input_next_extended_sequence_++;
      const auto sent = ::send(socket_, packet.data(), length, 0);
      ++rtp_sequence_;
      if (sent != static_cast<ssize_t>(length)) {
        timing_distributions_[CLSP_NATIVE_TIMING_INPUT_PROTECT_TO_SUBMIT].drop();
        if (!record_input_terminal(
              extended_sequence,
              monotonic_microseconds(),
              0,
              InputFeedbackState::local_unsent
            )) {
          return CLSP_STATUS_RESOURCE_EXHAUSTED;
        }
        if (sent < 0 && errno == EMSGSIZE) {
          current_udp_payload_size_.store(1'200U, std::memory_order_release);
          return CLSP_STATUS_OK;
        }
        return sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == ENOBUFS) ?
                 CLSP_STATUS_OK : CLSP_STATUS_SOCKET_FAILURE;
      }
      const auto submitted_microseconds = monotonic_microseconds();
      const auto complete_ip_bytes = static_cast<std::uint32_t>(length) + ip_udp_overhead_bytes();
      const auto ledger_accepted = record_input_terminal(
        extended_sequence,
        submitted_microseconds,
        complete_ip_bytes,
        InputFeedbackState::unreported
      );
      input_tokens_bits_ -= charged_bits;
      reverse_tokens_bits_ -= charged_bits;
      submitted = true;
      input_last_rtp_send_microseconds_ = submitted_microseconds;
      input_last_rtp_timestamp_ = rtp.timestamp;
      ++input_packet_count_;
      input_octet_count_ += static_cast<std::uint32_t>(
        lumen::lsp::input_plane::common_header_size + payload.size()
      );
      record_timing_stage(
        CLSP_NATIVE_TIMING_INPUT_PROTECT_TO_SUBMIT,
        protected_microseconds,
        submitted_microseconds
      );
      if (attributable_device_state) {
        if (header.kind == lumen::lsp::input_plane::packet_kind::pointer_motion) {
          pointer_attributed_wire_bytes_.fetch_add(complete_ip_bytes, std::memory_order_relaxed);
        } else if (header.kind == lumen::lsp::input_plane::packet_kind::device_state ||
                   header.kind == lumen::lsp::input_plane::packet_kind::sensor_state) {
          const auto device_id = static_cast<std::uint32_t>(header.object_id);
          if (device_id >= 1U && device_id <= controller_attributed_wire_bytes_.size()) {
            controller_attributed_wire_bytes_[device_id - 1U].fetch_add(
              complete_ip_bytes,
              std::memory_order_relaxed
            );
          }
        }
      }
      increment(RuntimeCounter::transmitted);
      (void)now;
      return ledger_accepted ? CLSP_STATUS_OK : CLSP_STATUS_RESOURCE_EXHAUSTED;
    }

    /** @brief Retry one immutable protected microphone datagram and commit source state once. */
    [[nodiscard]] clsp_status_t transmit_pending_microphone() noexcept {
  #if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      if (!pending_microphone_.occupied) return CLSP_STATUS_OK;
      const auto sent = ::send(socket_, pending_microphone_.bytes.data(), pending_microphone_.length, 0);
      if (sent == static_cast<ssize_t>(pending_microphone_.length)) {
        const auto sent_microseconds = monotonic_microseconds();
        auto &record = microphone_sent_packets_[
          pending_microphone_.extended_sequence % microphone_sent_packets_.size()
        ];
        const auto ledger_exhausted = record.occupied && record.state == MicrophoneFeedbackState::unreported;
        if (!ledger_exhausted) {
          record = {
            .extended_sequence = pending_microphone_.extended_sequence,
            .sent_microseconds = sent_microseconds,
            .complete_ip_bytes = static_cast<std::uint32_t>(pending_microphone_.length) + ip_udp_overhead_bytes(),
            .microphone_generation = pending_microphone_.microphone_generation,
            .state = MicrophoneFeedbackState::unreported,
            .occupied = true,
          };
          microphone_bytes_in_flight_ = saturating_rate_add(
            microphone_bytes_in_flight_,
            record.complete_ip_bytes
          );
        }
        microphone_tokens_bits_ -= std::min(microphone_tokens_bits_, pending_microphone_.charged_bits);
        reverse_tokens_bits_ -= std::min(reverse_tokens_bits_, pending_microphone_.charged_bits);
        microphone_marker_.store(false, std::memory_order_release);
        microphone_timestamp_ += 960U;
        ++microphone_packet_count_;
        microphone_octet_count_ += static_cast<std::uint32_t>(pending_microphone_.opus_bytes);
        microphone_queue_[pending_microphone_.queue_index].clear();
        microphone_read_.store(
          (pending_microphone_.queue_index + 1U) % microphone_queue_capacity,
          std::memory_order_release
        );
        pending_microphone_ = {};
        increment(RuntimeCounter::transmitted);
        return ledger_exhausted ? CLSP_STATUS_RESOURCE_EXHAUSTED : CLSP_STATUS_OK;
      }
      if (sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == ENOBUFS)) {
        return CLSP_STATUS_OK;
      }
      if (sent < 0 && errno == EMSGSIZE) {
        current_udp_payload_size_.store(1'200U, std::memory_order_release);
        microphone_marker_.store(true, std::memory_order_release);
        microphone_queue_[pending_microphone_.queue_index].clear();
        microphone_read_.store(
          (pending_microphone_.queue_index + 1U) % microphone_queue_capacity,
          std::memory_order_release
        );
        pending_microphone_ = {};
        return CLSP_STATUS_OK;
      }
      return CLSP_STATUS_SOCKET_FAILURE;
  #else
      return CLSP_STATUS_UNSUPPORTED;
  #endif
    }

    /** @brief Pace, protect, and submit at most one complete microphone Opus packet. */
    [[nodiscard]] clsp_status_t transmit_microphone() noexcept {
  #if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      if (!microphone_active_.load(std::memory_order_acquire)) return CLSP_STATUS_OK;
      if (pending_microphone_.occupied) return transmit_pending_microphone();
      const auto now = monotonic_microseconds();
      replenish_microphone_credit(now);
      replenish_reverse_credit(now);
      const auto read = microphone_read_.load(std::memory_order_relaxed);
      if (read != microphone_write_.load(std::memory_order_acquire)) {
        const auto opus = microphone_queue_[read].bytes();
        const auto charged =
          static_cast<std::uint64_t>(12U + opus.size() + 16U + ip_udp_overhead_bytes()) * 8U;
        const auto input_reserve = input_configured_ ?
          input_configuration_.reserved_input_wire_bits_per_second / 500U : 0U;
        if (charged <= microphone_tokens_bits_ && reverse_tokens_bits_ > input_reserve &&
            charged <= reverse_tokens_bits_ - input_reserve) {
          auto &packet = pending_microphone_.bytes;
          std::fill(packet.begin(), packet.end(), 0);
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
          pending_microphone_.extended_sequence = microphone_next_extended_sequence_++;
          pending_microphone_.microphone_generation = microphone_configuration_.microphone_generation;
          ++microphone_sequence_;
          pending_microphone_.length = length;
          pending_microphone_.queue_index = read;
          pending_microphone_.opus_bytes = opus.size();
          pending_microphone_.charged_bits = charged;
          pending_microphone_.occupied = true;
          const auto send_status = transmit_pending_microphone();
          if (send_status != CLSP_STATUS_OK) return send_status;
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

    /** @brief Refill one aggregate reverse controller while preserving the input reservation. */
    void replenish_reverse_credit(const std::uint64_t now) noexcept {
      if (reverse_last_credit_us_ == 0U || now < reverse_last_credit_us_) {
        reverse_last_credit_us_ = now;
        return;
      }
      const auto input_rate = input_configured_ ? input_configuration_.reserved_input_wire_bits_per_second : 0U;
      const auto microphone_rate = microphone_active_.load(std::memory_order_acquire) ?
                                     current_microphone_pacing_rate() : 0U;
      const auto fallback_rate = saturating_rate_add(input_rate, microphone_rate);
      const auto rate = reverse_congestion_rate_bits_per_second_ != 0 ?
                          reverse_congestion_rate_bits_per_second_ : fallback_rate;
      const auto elapsed = now - reverse_last_credit_us_;
      const auto earned = rate == 0U ? 0U :
        (elapsed > std::numeric_limits<std::uint64_t>::max() / rate ?
           std::numeric_limits<std::uint64_t>::max() : elapsed * rate / 1'000'000U);
      const auto capacity = std::max<std::uint64_t>(
        input_rate / 500U + microphone_rate / 25U,
        2U * static_cast<std::uint64_t>(maximum_udp_payload + ip_udp_overhead_bytes()) * 8U
      );
      reverse_tokens_bits_ = earned >= capacity || reverse_tokens_bits_ >= capacity - earned ?
                               capacity : reverse_tokens_bits_ + earned;
      reverse_last_credit_us_ = now;
    }

    /** @brief Refill the reverse-microphone pacer below the dedicated input lane. */
    void replenish_microphone_credit(const std::uint64_t now) noexcept {
      if (now < microphone_last_credit_us_) { microphone_last_credit_us_ = now; return; }
      const auto rate = current_microphone_pacing_rate();
      const auto elapsed = now - microphone_last_credit_us_;
      const auto earned = elapsed > std::numeric_limits<std::uint64_t>::max() / rate ?
                            std::numeric_limits<std::uint64_t>::max() : elapsed * rate / 1'000'000U;
      const auto capacity = microphone_credit_capacity(microphone_configuration_, rate);
      microphone_tokens_bits_ = earned >= capacity || microphone_tokens_bits_ >= capacity - earned ?
                                  capacity : microphone_tokens_bits_ + earned;
      microphone_last_credit_us_ = now;
    }

    /** @brief Emit a regular microphone SR/SDES compound with the association's established CNAME. */
    [[nodiscard]] clsp_status_t send_microphone_report(const std::uint64_t now) noexcept {
      if (pending_rtcp_) {
        return CLSP_STATUS_OK;
      }
      auto &packet = pending_rtcp_.bytes;
      std::fill(packet.begin(), packet.end(), 0);
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
      const auto ntp_seconds_field = static_cast<std::uint32_t>(ntp_seconds);
      const auto ntp_fraction_field = static_cast<std::uint32_t>(ntp_fraction);
      lumen::lsp::wire::write_be<std::uint32_t>(std::span<std::uint8_t> {packet}.subspan(8, 4), ntp_seconds_field);
      lumen::lsp::wire::write_be<std::uint32_t>(std::span<std::uint8_t> {packet}.subspan(12, 4), ntp_fraction_field);
      lumen::lsp::wire::write_be<std::uint32_t>(std::span<std::uint8_t> {packet}.subspan(16, 4), microphone_timestamp_ - 960U);
      lumen::lsp::wire::write_be<std::uint32_t>(std::span<std::uint8_t> {packet}.subspan(20, 4), microphone_packet_count_);
      lumen::lsp::wire::write_be<std::uint32_t>(std::span<std::uint8_t> {packet}.subspan(24, 4), microphone_octet_count_);
      // This SSRC has its own sender timeline, but shares the association CNAME
      // with input/video feedback. A bare SR cannot establish RTCP authority.
      const auto sdes_length = lumen::lsp::transport::write_sdes_cname(
        microphone_configuration_.microphone_ssrc,
        std::span<const std::uint8_t> {compound_cname_}.first(compound_cname_length_),
        std::span<std::uint8_t> {packet}.subspan(28)
      );
      if (sdes_length == 0) return CLSP_STATUS_INTERNAL_FAILURE;
      auto length = std::size_t {28} + sdes_length;
      const auto status = srtp_.protect(packet, length, true);
      if (status != CLSP_STATUS_OK) return status;
      pending_rtcp_.kind = PendingProtectedRtcp::Kind::microphone_report;
      pending_rtcp_.length = length;
      pending_rtcp_.created_microseconds = now;
      pending_rtcp_.microphone_lsr = (ntp_seconds_field << 16U) | (ntp_fraction_field >> 16U);
      return transmit_pending_rtcp(now);
    }

    /** @brief Return the middle 32 bits of a current NTP timestamp. */
    [[nodiscard]] std::uint32_t middle_ntp_timestamp() const noexcept {
      timespec realtime {};
      if (clock_gettime(CLOCK_REALTIME, &realtime) != 0 || realtime.tv_sec < 0 || realtime.tv_nsec < 0) {
        return 0;
      }
      constexpr std::uint64_t ntp_epoch_offset = 2'208'988'800ULL;
      const auto seconds = static_cast<std::uint64_t>(realtime.tv_sec) + ntp_epoch_offset;
      const auto fraction = static_cast<std::uint64_t>(realtime.tv_nsec) * (std::uint64_t {1} << 32U) / 1'000'000'000ULL;
      return static_cast<std::uint32_t>(((seconds & 0xffffU) << 16U) | (fraction >> 16U));
    }

    /** @brief Classify one visible SSRC through the authenticated video registry. */
    [[nodiscard]] VideoRtpLane video_lane_for_ssrc(const std::uint32_t ssrc) const noexcept {
      if (!video_configured_.load(std::memory_order_acquire) || ssrc == 0) {
        return VideoRtpLane::none;
      }
      if (ssrc == video_configuration_.primary_ssrc) {
        return VideoRtpLane::primary;
      }
      if (video_configuration_.flexfec_ssrc != 0 && ssrc == video_configuration_.flexfec_ssrc) {
        return VideoRtpLane::flexfec;
      }
      if (video_configuration_.rtx_ssrc != 0 && ssrc == video_configuration_.rtx_ssrc) {
        return VideoRtpLane::rtx;
      }
      return VideoRtpLane::none;
    }

    /** @brief Reject unnegotiated visible SSRCs before any libSRTP state lookup. */
    [[nodiscard]] bool inbound_ssrc_registered(
      const std::uint32_t ssrc,
      const bool rtcp
    ) const noexcept {
      if (ssrc == 0) {
        return false;
      }
      if (video_lane_for_ssrc(ssrc) != VideoRtpLane::none) {
        return true;
      }
      if (audio_configured_.load(std::memory_order_acquire) &&
          ssrc == audio_configuration_.audio_ssrc) {
        return true;
      }
      return rtcp && input_configured_ && ssrc == input_configuration_.acknowledgement_ssrc;
    }

    /** @brief Return the exact authenticated-datagram fingerprint table for one video lane. */
    [[nodiscard]] std::array<AuthenticatedRtpFingerprint, 128> *video_fingerprints(
      const VideoRtpLane lane
    ) noexcept {
      switch (lane) {
        case VideoRtpLane::primary:
          return &authenticated_video_fingerprints_;
        case VideoRtpLane::flexfec:
          return &authenticated_flexfec_fingerprints_;
        case VideoRtpLane::rtx:
          return &authenticated_rtx_fingerprints_;
        case VideoRtpLane::none:
          return nullptr;
      }
      return nullptr;
    }

    /** @brief Return the exact negotiated RTP payload type for one video lane. */
    [[nodiscard]] std::uint8_t video_payload_type(const VideoRtpLane lane) const noexcept {
      switch (lane) {
        case VideoRtpLane::primary:
          return video_configuration_.primary_payload_type;
        case VideoRtpLane::flexfec:
          return video_configuration_.flexfec_payload_type;
        case VideoRtpLane::rtx:
          return video_configuration_.rtx_payload_type;
        case VideoRtpLane::none:
          return 0;
      }
      return 0;
    }

    /** @brief Extend one RTP lane's sequence around its independent RFC 8888 origin. */
    [[nodiscard]] static std::uint64_t extend_feedback_sequence(
      const std::uint16_t sequence,
      bool &initialized,
      std::uint64_t &largest_extended_sequence
    ) noexcept {
      if (!initialized) {
        initialized = true;
        largest_extended_sequence = sequence;
        return sequence;
      }
      constexpr std::uint64_t modulus = std::uint64_t {1} << 16U;
      constexpr std::uint64_t half = modulus / 2U;
      auto candidate = (largest_extended_sequence & ~(modulus - 1U)) | sequence;
      if (candidate + half < largest_extended_sequence) {
        candidate += modulus;
      } else if (candidate > largest_extended_sequence + half && candidate >= modulus) {
        candidate -= modulus;
      }
      largest_extended_sequence = std::max(largest_extended_sequence, candidate);
      return candidate;
    }

    /** @brief Extend audio sequence numbers independently for RFC 8888 reporting. */
    [[nodiscard]] std::uint64_t extend_audio_feedback_sequence(const std::uint16_t sequence) noexcept {
      return extend_feedback_sequence(
        sequence,
        audio_feedback_sequence_initialized_,
        audio_feedback_largest_extended_sequence_
      );
    }

    /** @brief Record one authenticated negotiated video-lane packet and its RR state. */
    void record_video_feedback_for_lane(
      const std::span<const std::uint8_t> packet,
      const std::uint16_t protected_udp_bytes,
      const std::uint64_t arrival_microseconds,
      const native_ecn_mark ecn,
      const VideoRtpLane lane
    ) noexcept {
      const auto rtp = lumen::lsp::parse_rtp_fixed_header(packet);
      if (!rtp) {
        return;
      }
      native_video_feedback_tracker<> *feedback = nullptr;
      native_rtp_reception_stats *reception = nullptr;
      bool *sequence_initialized = nullptr;
      std::uint64_t *largest_sequence = nullptr;
      std::uint32_t expected_ssrc = 0;
      std::uint8_t expected_payload_type = 0;
      switch (lane) {
        case VideoRtpLane::primary:
          feedback = &video_feedback_;
          reception = &video_reception_;
          sequence_initialized = &feedback_sequence_initialized_;
          largest_sequence = &feedback_largest_extended_sequence_;
          expected_ssrc = video_configuration_.primary_ssrc;
          expected_payload_type = video_configuration_.primary_payload_type;
          break;
        case VideoRtpLane::flexfec:
          feedback = &flexfec_feedback_;
          reception = &flexfec_reception_;
          sequence_initialized = &flexfec_feedback_sequence_initialized_;
          largest_sequence = &flexfec_feedback_largest_extended_sequence_;
          expected_ssrc = video_configuration_.flexfec_ssrc;
          expected_payload_type = video_configuration_.flexfec_payload_type;
          break;
        case VideoRtpLane::rtx:
          feedback = &rtx_feedback_;
          reception = &rtx_reception_;
          sequence_initialized = &rtx_feedback_sequence_initialized_;
          largest_sequence = &rtx_feedback_largest_extended_sequence_;
          expected_ssrc = video_configuration_.rtx_ssrc;
          expected_payload_type = video_configuration_.rtx_payload_type;
          break;
        case VideoRtpLane::none:
          return;
      }
      if (rtp.header.ssrc != expected_ssrc || rtp.header.payload_type != expected_payload_type) {
        return;
      }
      const auto ip_overhead = socket_family_ == AF_INET6 ? 48U : 28U;
      const auto complete_bytes = static_cast<std::uint32_t>(protected_udp_bytes) + ip_overhead;
      if (complete_bytes > UINT16_MAX) {
        return;
      }
      const auto extended = extend_feedback_sequence(
        rtp.header.sequence_number,
        *sequence_initialized,
        *largest_sequence
      );
      const auto result = feedback->record({
        .extended_sequence = extended,
        .arrival_microseconds = arrival_microseconds,
        .received_ip_bytes = static_cast<std::uint16_t>(complete_bytes),
        .ecn = ecn,
      });
      if (result == native_feedback_record_result::accepted) {
        reception->record(
          extended,
          rtp.header.timestamp,
          arrival_microseconds,
          90'000U
        );
        if (lane == VideoRtpLane::primary) {
          video_received_ip_bytes_ += complete_bytes;
          increment(RuntimeCounter::video_received_ip_bytes, complete_bytes);
          if (ecn == native_ecn_mark::unknown) {
            ++video_ecn_unknown_packets_;
            increment(RuntimeCounter::video_ecn_unknown_packets);
          } else if (ecn == native_ecn_mark::congestion_experienced) {
            ++video_ecn_ce_packets_;
            increment(RuntimeCounter::video_ecn_ce_packets);
          }
        }
      }
    }

    /** @brief Retain one exact protected-RTP identity only after successful SRTP authentication. */
    static void store_authenticated_rtp_fingerprint(
      std::array<AuthenticatedRtpFingerprint, 128> &fingerprints,
      const std::uint16_t sequence,
      const std::uint32_t ssrc,
      const std::uint32_t rtp_timestamp,
      const std::uint16_t protected_bytes,
      const std::uint64_t first_arrival_microseconds,
      const std::uint8_t first_header_byte,
      const std::uint8_t second_header_byte,
      const std::array<std::uint8_t, 16> &authentication_tag
    ) noexcept {
      auto &slot = fingerprints[sequence % fingerprints.size()];
      slot = {
        .authentication_tag = authentication_tag,
        .first_arrival_microseconds = first_arrival_microseconds,
        .ssrc = ssrc,
        .rtp_timestamp = rtp_timestamp,
        .sequence = sequence,
        .protected_bytes = protected_bytes,
        .first_header_byte = first_header_byte,
        .second_header_byte = second_header_byte,
        .occupied = true,
      };
    }

    /** @brief Return the exact prior authenticated fingerprint for one replayed datagram. */
    [[nodiscard]] static const AuthenticatedRtpFingerprint *authenticated_rtp_fingerprint(
      const std::array<AuthenticatedRtpFingerprint, 128> &fingerprints,
      const std::uint16_t sequence,
      const std::uint32_t ssrc,
      const std::uint32_t rtp_timestamp,
      const std::uint16_t protected_bytes,
      const std::uint8_t first_header_byte,
      const std::uint8_t second_header_byte,
      const std::array<std::uint8_t, 16> &authentication_tag
    ) noexcept {
      const auto &slot = fingerprints[sequence % fingerprints.size()];
      return slot.occupied && slot.sequence == sequence && slot.ssrc == ssrc &&
                 slot.rtp_timestamp == rtp_timestamp && slot.protected_bytes == protected_bytes &&
                 slot.first_header_byte == first_header_byte && slot.second_header_byte == second_header_byte &&
                 slot.authentication_tag == authentication_tag ?
               &slot :
               nullptr;
    }

    /** @brief Upgrade one exact authenticated video-lane replay to ECN-CE without media re-admission. */
    void record_video_duplicate_ce(
      const AuthenticatedRtpFingerprint &fingerprint,
      const native_ecn_mark ecn,
      const VideoRtpLane lane
    ) noexcept {
      if (ecn != native_ecn_mark::congestion_experienced) {
        return;
      }
      const auto ip_overhead = socket_family_ == AF_INET6 ? 48U : 28U;
      const auto complete_bytes = static_cast<std::uint32_t>(fingerprint.protected_bytes) + ip_overhead;
      if (complete_bytes > UINT16_MAX) {
        return;
      }
      native_video_feedback_tracker<> *feedback = nullptr;
      bool *initialized = nullptr;
      std::uint64_t *largest_sequence = nullptr;
      switch (lane) {
        case VideoRtpLane::primary:
          feedback = &video_feedback_;
          initialized = &feedback_sequence_initialized_;
          largest_sequence = &feedback_largest_extended_sequence_;
          break;
        case VideoRtpLane::flexfec:
          feedback = &flexfec_feedback_;
          initialized = &flexfec_feedback_sequence_initialized_;
          largest_sequence = &flexfec_feedback_largest_extended_sequence_;
          break;
        case VideoRtpLane::rtx:
          feedback = &rtx_feedback_;
          initialized = &rtx_feedback_sequence_initialized_;
          largest_sequence = &rtx_feedback_largest_extended_sequence_;
          break;
        case VideoRtpLane::none:
          return;
      }
      (void)feedback->record({
        .extended_sequence = extend_feedback_sequence(fingerprint.sequence, *initialized, *largest_sequence),
        .arrival_microseconds = fingerprint.first_arrival_microseconds,
        .received_ip_bytes = static_cast<std::uint16_t>(complete_bytes),
        .ecn = native_ecn_mark::congestion_experienced,
      });
    }

    /** @brief Upgrade one exact authenticated audio replay to ECN-CE without Opus re-admission. */
    void record_audio_duplicate_ce(
      const AuthenticatedRtpFingerprint &fingerprint,
      const native_ecn_mark ecn
    ) noexcept {
      if (ecn != native_ecn_mark::congestion_experienced) {
        return;
      }
      const auto ip_overhead = socket_family_ == AF_INET6 ? 48U : 28U;
      const auto complete_bytes = static_cast<std::uint32_t>(fingerprint.protected_bytes) + ip_overhead;
      if (complete_bytes > UINT16_MAX) {
        return;
      }
      (void) audio_feedback_.record({
        .extended_sequence = extend_audio_feedback_sequence(fingerprint.sequence),
        .arrival_microseconds = fingerprint.first_arrival_microseconds,
        .received_ip_bytes = static_cast<std::uint16_t>(complete_bytes),
        .ecn = native_ecn_mark::congestion_experienced,
      });
    }

    /** @brief Record one authenticated host-audio packet for CCFB and RR statistics. */
    void record_audio_feedback(
      const std::span<const std::uint8_t> packet,
      const std::uint16_t protected_udp_bytes,
      const std::uint64_t arrival_microseconds,
      const native_ecn_mark ecn
    ) noexcept {
      if (!audio_configured_.load(std::memory_order_acquire)) {
        return;
      }
      const auto rtp = lumen::lsp::parse_rtp_fixed_header(packet);
      if (!rtp || rtp.header.ssrc != audio_configuration_.audio_ssrc ||
          rtp.header.payload_type != audio_configuration_.audio_payload_type) {
        return;
      }
      const auto ip_overhead = socket_family_ == AF_INET6 ? 48U : 28U;
      const auto complete_bytes = static_cast<std::uint32_t>(protected_udp_bytes) + ip_overhead;
      if (complete_bytes > UINT16_MAX) {
        return;
      }
      const auto extended = extend_audio_feedback_sequence(rtp.header.sequence_number);
      const auto result = audio_feedback_.record({
        .extended_sequence = extended,
        .arrival_microseconds = arrival_microseconds,
        .received_ip_bytes = static_cast<std::uint16_t>(complete_bytes),
        .ecn = ecn,
      });
      if (result == native_feedback_record_result::accepted) {
        audio_reception_.record(extended, rtp.header.timestamp, arrival_microseconds, 48'000U);
      }
    }

    /** @brief Match one authenticated exact-size host LSPP against its reliable intent. */
    [[nodiscard]] PathProbePacketResult handle_authenticated_path_probe(
      const std::span<const std::uint8_t> packet,
      const std::uint32_t visible_ssrc,
      const std::uint16_t protected_udp_size,
      const std::uint64_t received_microseconds
    ) noexcept {
      if (packet.size() < 12U || packet[1] != 204U || packet[8] != 'L' || packet[9] != 'S' ||
          packet[10] != 'P' || packet[11] != 'P') {
        return PathProbePacketResult::not_probe;
      }
      if (!video_configured_.load(std::memory_order_acquire) || visible_ssrc != video_configuration_.primary_ssrc) {
        return PathProbePacketResult::invalid;
      }
      const auto probe = parse_lspp(packet, visible_ssrc, protected_udp_size);
      if (probe.probe_id == 0) {
        return PathProbePacketResult::invalid;
      }
      std::uint64_t request_id = 0;
      pthread_mutex_lock(&mutex_);
      if (last_received_probe_id_ == probe.probe_id && last_received_probe_size_ == probe.udp_payload_size) {
        pthread_mutex_unlock(&mutex_);
        return PathProbePacketResult::accepted;
      }
      if (inbound_path_probe_intent_.occupied && inbound_path_probe_intent_.probe_id == probe.probe_id &&
          inbound_path_probe_intent_.udp_payload_size == probe.udp_payload_size) {
        request_id = inbound_path_probe_intent_.request_id;
        if (!queue_path_probe_event_locked(
              CLSP_PATH_PROBE_RECEIVED,
              probe.probe_id,
              probe.udp_payload_size,
              request_id
            )) {
          pthread_mutex_unlock(&mutex_);
          return PathProbePacketResult::invalid;
        }
        inbound_path_probe_intent_ = {};
        unmatched_path_probe_ = {};
        last_received_probe_id_ = probe.probe_id;
        last_received_probe_size_ = probe.udp_payload_size;
        receive_udp_payload_size_.store(probe.udp_payload_size, std::memory_order_release);
      } else if (!unmatched_path_probe_.occupied ||
                 (unmatched_path_probe_.probe_id == probe.probe_id &&
                  unmatched_path_probe_.udp_payload_size == probe.udp_payload_size)) {
        unmatched_path_probe_ = {
          .probe_id = probe.probe_id,
          .received_microseconds = received_microseconds,
          .udp_payload_size = probe.udp_payload_size,
          .occupied = true,
        };
      } else {
        pthread_mutex_unlock(&mutex_);
        return PathProbePacketResult::invalid;
      }
      pthread_mutex_unlock(&mutex_);
      if (request_id != 0) {
        wake_worker();
      }
      return PathProbePacketResult::accepted;
    }

    /** @brief Protect one fresh SRTCP LSPP packet for first send or PROBE_TIMER retry. */
    [[nodiscard]] clsp_status_t prepare_outbound_path_probe(
      const std::uint64_t probe_id,
      const std::uint16_t udp_payload_size
    ) noexcept {
      if (!input_configured_ || probe_id == 0 || udp_payload_size > maximum_udp_payload) {
        return CLSP_STATUS_INVALID_STATE;
      }
      std::size_t trailer = 0;
      const auto trailer_status = srtp_.rtcp_protect_trailer_length(trailer);
      if (trailer_status != CLSP_STATUS_OK || trailer >= udp_payload_size) {
        return CLSP_STATUS_SRTP_FAILURE;
      }
      const auto plaintext_size = static_cast<std::size_t>(udp_payload_size) - trailer;
      auto &probe = outbound_path_probe_;
      if (!probe.active || probe.probe_id != probe_id || probe.udp_payload_size != udp_payload_size) {
        probe = {};
        probe.probe_id = probe_id;
        probe.udp_payload_size = udp_payload_size;
      }
      if (!write_lspp(input_configuration_.input_ssrc, probe_id, udp_payload_size, std::span<std::uint8_t> {probe.bytes}.first(plaintext_size))) {
        return CLSP_STATUS_INVALID_CONFIGURATION;
      }
      auto length = plaintext_size;
      const auto status = srtp_.protect(probe.bytes, length, true);
      if (status != CLSP_STATUS_OK || length != udp_payload_size) {
        return CLSP_STATUS_SRTP_FAILURE;
      }
      probe.length = length;
      probe.pending_send = true;
      probe.active = true;
      return CLSP_STATUS_OK;
    }

    /** @brief Retry one already protected LSPP only across immediate socket backpressure. */
    [[nodiscard]] clsp_status_t transmit_outbound_path_probe(const std::uint64_t now) noexcept {
      auto &probe = outbound_path_probe_;
      if (!probe.active || !probe.pending_send) {
        return CLSP_STATUS_OK;
      }
      const auto sent = ::send(socket_, probe.bytes.data(), probe.length, 0);
      if (sent == static_cast<ssize_t>(probe.length)) {
        probe.pending_send = false;
        probe.last_send_microseconds = now;
        ++probe.attempts;
        increment(RuntimeCounter::path_probes_sent);
        increment(RuntimeCounter::transmitted);
        return CLSP_STATUS_OK;
      }
      if (sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == ENOBUFS)) {
        return CLSP_STATUS_OK;
      }
      if (sent < 0 && errno == EMSGSIZE) {
        pthread_mutex_lock(&mutex_);
        if (path_mtu_) {
          (void) path_mtu_->probe_timed_out();
        }
        last_path_raise_microseconds_ = now;
        current_udp_payload_size_.store(1'200U, std::memory_order_release);
        outbound_path_probe_ = {};
        emitted_path_probe_id_.store(0, std::memory_order_release);
        emitted_path_probe_size_.store(0, std::memory_order_release);
        pthread_mutex_unlock(&mutex_);
        return CLSP_STATUS_OK;
      }
      return CLSP_STATUS_SOCKET_FAILURE;
    }

    /** @brief Drive native RFC 8899 search, conservative timer retry, and bounded intent callbacks. */
    [[nodiscard]] clsp_status_t drive_path_mtu(const std::uint64_t now) noexcept {
      if (!path_discovery_enabled_.load(std::memory_order_acquire) || !path_mtu_ || !video_delivery_active_.load(std::memory_order_acquire)) {
        return CLSP_STATUS_OK;
      }
      const auto acknowledged_id = pending_path_ack_id_.exchange(0, std::memory_order_acq_rel);
      if (acknowledged_id != 0) {
        const auto acknowledged_size = pending_path_ack_size_.load(std::memory_order_acquire);
        if (last_acknowledged_probe_id_ != acknowledged_id || last_acknowledged_probe_size_ != acknowledged_size) {
          if (path_mtu_->acknowledge_probe(acknowledged_id, acknowledged_size) !=
              lumen::lsp::transport::path_mtu_result::accepted) {
            return CLSP_STATUS_INVALID_ARGUMENT;
          }
          last_acknowledged_probe_id_ = acknowledged_id;
          last_acknowledged_probe_size_ = acknowledged_size;
          current_udp_payload_size_.store(acknowledged_size, std::memory_order_release);
          increment(RuntimeCounter::path_probes_acknowledged);
        }
        outbound_path_probe_ = {};
        path_probe_notification_pending_ = false;
        emitted_path_probe_id_.store(0, std::memory_order_release);
        emitted_path_probe_size_.store(0, std::memory_order_release);
      }
      pthread_mutex_lock(&mutex_);
      if (inbound_path_probe_intent_.occupied && now >= inbound_path_probe_intent_.received_microseconds &&
          now - inbound_path_probe_intent_.received_microseconds >= path_probe_intent_retention_microseconds) {
        inbound_path_probe_intent_ = {};
      }
      if (unmatched_path_probe_.occupied && now >= unmatched_path_probe_.received_microseconds &&
          now - unmatched_path_probe_.received_microseconds >= path_probe_timer_microseconds) {
        unmatched_path_probe_ = {};
      }
      pthread_mutex_unlock(&mutex_);
      if (outbound_path_probe_.active) {
        if (outbound_path_probe_.pending_send) {
          return transmit_outbound_path_probe(now);
        }
        if (now >= outbound_path_probe_.last_send_microseconds &&
            now - outbound_path_probe_.last_send_microseconds >= path_probe_timer_microseconds) {
          if (outbound_path_probe_.attempts >= maximum_path_probe_attempts) {
            pthread_mutex_lock(&mutex_);
            (void) path_mtu_->probe_timed_out();
            outbound_path_probe_ = {};
            path_probe_notification_pending_ = false;
            emitted_path_probe_id_.store(0, std::memory_order_release);
            emitted_path_probe_size_.store(0, std::memory_order_release);
            increment(RuntimeCounter::path_probe_timeouts);
            current_udp_payload_size_.store(1'200U, std::memory_order_release);
            last_path_raise_microseconds_ = now;
            pthread_mutex_unlock(&mutex_);
          } else {
            const auto status = prepare_outbound_path_probe(
              outbound_path_probe_.probe_id,
              outbound_path_probe_.udp_payload_size
            );
            if (status != CLSP_STATUS_OK) {
              return status;
            }
            return transmit_outbound_path_probe(now);
          }
        }
        return CLSP_STATUS_OK;
      }
      if (path_probe_notification_pending_) {
        if (now >= path_probe_notification_microseconds_ &&
            now - path_probe_notification_microseconds_ >= path_probe_timer_microseconds) {
          const auto probe = path_mtu_->outstanding_probe();
          path_probe_notification_microseconds_ = now;
          if (probe && !queue_path_probe_event(CLSP_PATH_PROBE_SEND_INTENT, probe.probe_id, probe.payload_bytes, 0)) {
            path_probe_notification_microseconds_ = 0;
          }
        }
        return CLSP_STATUS_OK;
      }

      if (path_mtu_->candidate_payload_bytes() == 0) {
        if (path_mtu_->current_payload_bytes() >= path_mtu_->ceiling_payload_bytes() ||
            now < last_path_raise_microseconds_ ||
            now - last_path_raise_microseconds_ < path_mtu_raise_interval_microseconds) {
          return CLSP_STATUS_OK;
        }
        if (path_mtu_->raise_timer_elapsed() != lumen::lsp::transport::path_mtu_result::accepted) {
          return CLSP_STATUS_OK;
        }
        last_path_raise_microseconds_ = now;
      }
      pthread_mutex_lock(&mutex_);
      auto probe_id = next_path_probe_id_++;
      if (probe_id == 0) {
        probe_id = next_path_probe_id_++;
      }
      const auto started = path_mtu_->start_probe(probe_id, now, path_probe_smoothed_rtt_microseconds);
      const auto probe = path_mtu_->outstanding_probe();
      if (started == lumen::lsp::transport::path_mtu_result::accepted) {
        path_probe_notification_pending_ = true;
        path_probe_notification_microseconds_ = now;
        emitted_path_probe_id_.store(probe.probe_id, std::memory_order_release);
        emitted_path_probe_size_.store(probe.payload_bytes, std::memory_order_release);
      }
      pthread_mutex_unlock(&mutex_);
      if (started == lumen::lsp::transport::path_mtu_result::accepted) {
        if (!queue_path_probe_event(CLSP_PATH_PROBE_SEND_INTENT, probe.probe_id, probe.payload_bytes, 0)) {
          path_probe_notification_microseconds_ = 0;
        }
      }
      return CLSP_STATUS_OK;
    }

    /** @brief Submit one already protected compound/CCFB packet exactly across backpressure. */
    [[nodiscard]] clsp_status_t transmit_pending_rtcp(const std::uint64_t now) noexcept {
      if (!pending_rtcp_) {
        return CLSP_STATUS_OK;
      }
      const auto sent = ::send(socket_, pending_rtcp_.bytes.data(), pending_rtcp_.length, 0);
      if (sent == static_cast<ssize_t>(pending_rtcp_.length)) {
        if (pending_rtcp_.kind == PendingProtectedRtcp::Kind::compound) {
          compound_rtcp_sent_ = true;
          last_compound_rtcp_microseconds_ = now;
          if (pending_rtcp_.input_lsr != 0) {
            input_sender_report_timings_[input_sender_report_timing_index_] = {
              .sent_microseconds = now,
              .lsr = pending_rtcp_.input_lsr,
            };
            input_sender_report_timing_index_ =
              (input_sender_report_timing_index_ + 1U) % input_sender_report_timings_.size();
          }
        } else if (pending_rtcp_.kind == PendingProtectedRtcp::Kind::congestion_feedback) {
          if (pending_rtcp_.video_feedback) {
            (void) video_feedback_.commit(pending_rtcp_.video_feedback, now);
          }
          if (pending_rtcp_.flexfec_feedback) {
            (void)flexfec_feedback_.commit(pending_rtcp_.flexfec_feedback, now);
          }
          if (pending_rtcp_.rtx_feedback) {
            (void)rtx_feedback_.commit(pending_rtcp_.rtx_feedback, now);
          }
          if (pending_rtcp_.audio_feedback) {
            (void) audio_feedback_.commit(pending_rtcp_.audio_feedback, now);
          }
          congestion_feedback_ip_bytes_ += static_cast<std::uint64_t>(pending_rtcp_.length) +
                                           (socket_family_ == AF_INET6 ? 48U : 28U);
          ++congestion_feedback_packets_;
          increment(
            RuntimeCounter::congestion_feedback_ip_bytes,
            static_cast<std::uint64_t>(pending_rtcp_.length) + (socket_family_ == AF_INET6 ? 48U : 28U)
          );
          increment(RuntimeCounter::congestion_feedback_packets);
        } else if (pending_rtcp_.kind == PendingProtectedRtcp::Kind::microphone_report) {
          microphone_last_report_us_ = now;
          if (pending_rtcp_.microphone_lsr != 0) {
            microphone_sender_report_timings_[microphone_sender_report_timing_index_] = {
              .sent_microseconds = now,
              .lsr = pending_rtcp_.microphone_lsr,
            };
            microphone_sender_report_timing_index_ =
              (microphone_sender_report_timing_index_ + 1U) % microphone_sender_report_timings_.size();
          }
        } else if (pending_rtcp_.kind == PendingProtectedRtcp::Kind::lspv) {
          pthread_mutex_lock(&mutex_);
          if (video_recovery_feedback_pending_) {
            last_recovery_lspv_microseconds_ = now;
          }
          pthread_mutex_unlock(&mutex_);
        }
        pending_rtcp_ = {};
        increment(RuntimeCounter::transmitted);
        return CLSP_STATUS_OK;
      }
      if (sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == ENOBUFS)) {
        return CLSP_STATUS_OK;
      }
      return CLSP_STATUS_SOCKET_FAILURE;
    }

    /** @brief Submit one urgent already-protected Generic NACK across backpressure. */
    [[nodiscard]] clsp_status_t transmit_pending_video_nack(const std::uint64_t now) noexcept {
      if (!pending_video_nack_) {
        return CLSP_STATUS_OK;
      }
      const auto estimate = rtx_deadline_estimate();
      for (std::size_t index = 0; index < pending_video_nack_.sequence_count; ++index) {
        if (!lumen::lsp::transport::rtx_deadline_eligible(
              now,
              pending_video_nack_.frame_deadlines[index],
              estimate
            )) {
          pending_video_nack_ = {};
          return CLSP_STATUS_OK;
        }
      }
      const auto sent = ::send(socket_, pending_video_nack_.bytes.data(), pending_video_nack_.length, 0);
      if (sent == static_cast<ssize_t>(pending_video_nack_.length)) {
        if (pending_video_nack_.initial) {
          const auto marked = video_gap_tracker_.mark_nacks_sent(
            std::span<const std::uint16_t> {pending_video_nack_.sequences}.first(
              pending_video_nack_.sequence_count
            )
          );
          if (marked != pending_video_nack_.sequence_count) {
            pending_video_nack_ = {};
            return CLSP_STATUS_INTERNAL_FAILURE;
          }
        }
        const auto repeat_interval = configuration_.profile == CLSP_PROFILE_COMPETITION_LAN ?
                                       competition_nack_repeat_microseconds :
                                       adaptive_nack_repeat_microseconds;
        for (std::size_t index = 0; index < pending_video_nack_.sequence_count; ++index) {
          auto *retry = std::ranges::find_if(video_nack_retries_, [&](const VideoNackRetry &candidate) {
            return candidate.occupied && candidate.sequence_number == pending_video_nack_.sequences[index];
          });
          if (retry == video_nack_retries_.end()) {
            retry = std::ranges::find_if(video_nack_retries_, [](const VideoNackRetry &candidate) {
              return !candidate.occupied;
            });
          }
          if (retry == video_nack_retries_.end()) {
            record_local_video_pressure();
            continue;
          }
          if (!retry->occupied) {
            *retry = {
              .frame_deadline_microseconds = pending_video_nack_.frame_deadlines[index],
              .sequence_number = pending_video_nack_.sequences[index],
              .occupied = true,
            };
          }
          if (retry->attempts < maximum_video_nack_attempts) {
            ++retry->attempts;
          }
          retry->next_retry_microseconds = saturating_add(now, repeat_interval);
          if (retry->attempts >= maximum_video_nack_attempts) {
            retry->occupied = false;
          }
        }
        pending_video_nack_ = {};
        increment(RuntimeCounter::transmitted);
        return realtime_failure_status_ == CLSP_STATUS_OK ? CLSP_STATUS_OK : realtime_failure_status_;
      }
      if (sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == ENOBUFS)) {
        return CLSP_STATUS_OK;
      }
      return CLSP_STATUS_SOCKET_FAILURE;
    }

    /** @brief Build and immediately submit one deadline-qualified reduced-size Generic NACK. */
    [[nodiscard]] clsp_status_t transmit_video_nacks(const std::uint64_t now) noexcept {
      if (video_configuration_.rtx_ssrc == 0 || !compound_rtcp_sent_) {
        return CLSP_STATUS_OK;
      }
      if (pending_video_nack_) {
        return transmit_pending_video_nack(now);
      }
      std::array<lumen::lsp::transport::video_gap_nack_candidate, maximum_video_gap_count> candidates {};
      const auto batch = video_gap_tracker_.pending_nacks(now, rtx_deadline_estimate(), candidates);
      if (!batch) {
        return CLSP_STATUS_INTERNAL_FAILURE;
      }
      auto candidate_count = batch.count;
      auto initial = candidate_count != 0;
      if (candidate_count == 0) {
        const auto estimate = rtx_deadline_estimate();
        for (auto &retry : video_nack_retries_) {
          if (!retry.occupied) {
            continue;
          }
          if (retry.attempts >= maximum_video_nack_attempts ||
              !lumen::lsp::transport::rtx_deadline_eligible(
                now,
                retry.frame_deadline_microseconds,
                estimate
              )) {
            retry = {};
            continue;
          }
          if (now < retry.next_retry_microseconds) {
            continue;
          }
          candidates[candidate_count++] = {
            .frame_deadline_microseconds = retry.frame_deadline_microseconds,
            .sequence_number = retry.sequence_number,
          };
        }
      }
      if (candidate_count == 0) {
        return CLSP_STATUS_OK;
      }
      lumen::lsp::transport::generic_nack<maximum_video_gap_count> nack;
      nack.sender_ssrc = input_configuration_.input_ssrc;
      nack.media_ssrc = video_configuration_.primary_ssrc;
      nack.pair_count = candidate_count;
      for (std::size_t index = 0; index < candidate_count; ++index) {
        nack.pairs[index] = {
          .packet_id = candidates[index].sequence_number,
          .lost_packet_bitmask = 0,
        };
        pending_video_nack_.sequences[index] = candidates[index].sequence_number;
        pending_video_nack_.frame_deadlines[index] = candidates[index].frame_deadline_microseconds;
      }
      const auto written = lumen::lsp::transport::write_generic_nack(nack, pending_video_nack_.bytes);
      if (!written) {
        pending_video_nack_ = {};
        return CLSP_STATUS_INTERNAL_FAILURE;
      }
      auto length = written.bytes_written;
      const auto protected_status = srtp_.protect(pending_video_nack_.bytes, length, true);
      if (protected_status != CLSP_STATUS_OK ||
          length > current_udp_payload_size_.load(std::memory_order_acquire)) {
        pending_video_nack_ = {};
        return CLSP_STATUS_SRTP_FAILURE;
      }
      pending_video_nack_.length = length;
      pending_video_nack_.sequence_count = candidate_count;
      pending_video_nack_.initial = initial;
      return transmit_pending_video_nack(now);
    }

    /** @brief Expire fixed repair sources, pending parity, and deadline-past gaps. */
    void expire_video_repair_state(const std::uint64_t now) noexcept {
      for (auto &source : authenticated_video_sources_) {
        if (source.occupied && now >= source.frame_deadline_microseconds) {
          (void)video_receive_pool_.release(source.slab_token);
          source = {};
        }
      }
      for (auto &repair : pending_flexfec_repairs_) {
        if (repair.occupied && now >= repair.expires_microseconds) {
          (void)video_receive_pool_.release(repair.slab_token);
          repair = {};
        }
      }
      for (auto &retry : video_nack_retries_) {
        if (retry.occupied && now >= retry.frame_deadline_microseconds) {
          retry = {};
        }
      }
      if (pending_video_nack_) {
        const auto deadlines = std::span<const std::uint64_t> {pending_video_nack_.frame_deadlines}.first(
          pending_video_nack_.sequence_count
        );
        if (std::ranges::any_of(deadlines, [now](const std::uint64_t deadline) {
              return now >= deadline;
            })) {
          pending_video_nack_ = {};
        }
      }
      if (video_gap_tracker_.erase_expired(now) != 0 && pending_video_nack_) {
        pending_video_nack_ = {};
      }
    }

    /** @brief Send the initial and periodic regular compound RR plus privacy-safe SDES CNAME. */
    [[nodiscard]] clsp_status_t transmit_compound_rtcp(const std::uint64_t now) noexcept {
      if (pending_rtcp_ || !video_delivery_active_.load(std::memory_order_acquire) || !input_configured_ ||
          (compound_rtcp_sent_ && now >= last_compound_rtcp_microseconds_ &&
           now - last_compound_rtcp_microseconds_ < compound_rtcp_interval_microseconds)) {
        return CLSP_STATUS_OK;
      }
      std::array<native_receiver_report_block, 4> reports {};
      std::size_t report_count = 0;
      if (video_configured_.load(std::memory_order_acquire) && video_reception_.initialized()) {
        reports[report_count++] = video_reception_.report(video_configuration_.primary_ssrc, now);
      }
      if (video_configuration_.flexfec_ssrc != 0 && flexfec_reception_.initialized()) {
        reports[report_count++] = flexfec_reception_.report(video_configuration_.flexfec_ssrc, now);
      }
      if (video_configuration_.rtx_ssrc != 0 && rtx_reception_.initialized()) {
        reports[report_count++] = rtx_reception_.report(video_configuration_.rtx_ssrc, now);
      }
      if (audio_configured_.load(std::memory_order_acquire) && audio_reception_.initialized()) {
        reports[report_count++] = audio_reception_.report(audio_configuration_.audio_ssrc, now);
      }
      const auto cname = std::span<const std::uint8_t> {compound_cname_}.first(compound_cname_length_);
      const auto live_reports = std::span<const native_receiver_report_block> {reports}.first(report_count);
      auto plaintext = std::size_t {0};
      pending_rtcp_.input_lsr = 0;
      if (input_packet_count_ != 0 && input_last_rtp_send_microseconds_ != 0 &&
          now >= input_last_rtp_send_microseconds_) {
        timespec realtime {};
        if (clock_gettime(CLOCK_REALTIME, &realtime) != 0 || realtime.tv_sec < 0 || realtime.tv_nsec < 0) {
          return CLSP_STATUS_INTERNAL_FAILURE;
        }
        constexpr std::uint64_t ntp_epoch_offset = 2'208'988'800ULL;
        const auto ntp_seconds = static_cast<std::uint32_t>(
          static_cast<std::uint64_t>(realtime.tv_sec) + ntp_epoch_offset
        );
        const auto ntp_fraction = static_cast<std::uint32_t>(
          static_cast<std::uint64_t>(realtime.tv_nsec) * (std::uint64_t {1} << 32U) / 1'000'000'000ULL
        );
        const auto projected_timestamp = input_last_rtp_timestamp_ + static_cast<std::uint32_t>(
          now - input_last_rtp_send_microseconds_
        );
        plaintext = write_compound_input_sr_sdes(
          input_configuration_.input_ssrc,
          cname,
          ntp_seconds,
          ntp_fraction,
          projected_timestamp,
          input_packet_count_,
          input_octet_count_,
          live_reports,
          pending_rtcp_.bytes
        );
        pending_rtcp_.input_lsr = (ntp_seconds << 16U) | (ntp_fraction >> 16U);
      } else {
        plaintext = write_compound_rr_sdes(
          input_configuration_.input_ssrc,
          cname,
          live_reports,
          pending_rtcp_.bytes
        );
      }
      if (plaintext == 0) {
        return CLSP_STATUS_INTERNAL_FAILURE;
      }
      auto length = plaintext;
      const auto protected_status = srtp_.protect(pending_rtcp_.bytes, length, true);
      if (protected_status != CLSP_STATUS_OK) {
        return protected_status;
      }
      pending_rtcp_.kind = PendingProtectedRtcp::Kind::compound;
      pending_rtcp_.length = length;
      pending_rtcp_.created_microseconds = now;
      return transmit_pending_rtcp(now);
    }

    /** @brief Send one reduced-size RFC 8888 CCFB report after regular compound RTCP. */
    [[nodiscard]] clsp_status_t transmit_congestion_feedback(const std::uint64_t now) noexcept {
      const auto feedback_due = video_feedback_.due(now) || flexfec_feedback_.due(now) ||
                                rtx_feedback_.due(now) || audio_feedback_.due(now);
      if (pending_rtcp_ || !compound_rtcp_sent_ || !feedback_due || !input_configured_) {
        return CLSP_STATUS_OK;
      }
      std::size_t trailer = 0;
      const auto trailer_status = srtp_.rtcp_protect_trailer_length(trailer);
      const auto maximum = current_udp_payload_size_.load(std::memory_order_acquire);
      if (trailer_status != CLSP_STATUS_OK || trailer >= maximum) {
        return CLSP_STATUS_SRTP_FAILURE;
      }
      const auto plaintext_limit = static_cast<std::size_t>(maximum) - trailer;
      auto &packet = pending_rtcp_.bytes;
      std::fill(packet.begin(), packet.end(), 0);
      packet[0] = 0x8bU;
      packet[1] = 205U;
      lumen::lsp::wire::write_be<std::uint32_t>(std::span<std::uint8_t> {packet}.subspan(4, 4), input_configuration_.input_ssrc);
      const auto report_timestamp = middle_ntp_timestamp();
      std::array<std::uint8_t, maximum_udp_payload> scratch {};
      std::size_t offset = 8U;
      const auto append_block = [&](
                                  auto &tracker,
                                  const std::uint32_t media_ssrc,
                                  native_feedback_write_result &result
                                ) noexcept {
        if (tracker.size() == 0 || offset + 12U > plaintext_limit) {
          return;
        }
        const auto available_block = plaintext_limit - offset - 4U;
        const auto scratch_limit = std::min<std::size_t>(scratch.size(), available_block + 12U);
        result = tracker.write(
          input_configuration_.input_ssrc,
          media_ssrc,
          now,
          report_timestamp,
          std::span<std::uint8_t> {scratch}.first(scratch_limit)
        );
        if (!result) {
          return;
        }
        const auto block_bytes = result.bytes_written - 12U;
        std::copy_n(scratch.begin() + 8, block_bytes, packet.begin() + static_cast<std::ptrdiff_t>(offset));
        offset += block_bytes;
      };
      native_feedback_write_result video_written;
      native_feedback_write_result flexfec_written;
      native_feedback_write_result rtx_written;
      native_feedback_write_result audio_written;
      if (video_configured_.load(std::memory_order_acquire)) {
        append_block(video_feedback_, video_configuration_.primary_ssrc, video_written);
        if (video_configuration_.flexfec_ssrc != 0) {
          append_block(flexfec_feedback_, video_configuration_.flexfec_ssrc, flexfec_written);
        }
        if (video_configuration_.rtx_ssrc != 0) {
          append_block(rtx_feedback_, video_configuration_.rtx_ssrc, rtx_written);
        }
      }
      if (audio_configured_.load(std::memory_order_acquire)) {
        append_block(audio_feedback_, audio_configuration_.audio_ssrc, audio_written);
      }
      if (!video_written && !flexfec_written && !rtx_written && !audio_written) {
        return CLSP_STATUS_OK;
      }
      lumen::lsp::wire::write_be<std::uint32_t>(std::span<std::uint8_t> {packet}.subspan(offset, 4), report_timestamp);
      auto length = offset + 4U;
      lumen::lsp::wire::write_be<std::uint16_t>(std::span<std::uint8_t> {packet}.subspan(2, 2), static_cast<std::uint16_t>(length / 4U - 1U));
      const auto protected_status = srtp_.protect(pending_rtcp_.bytes, length, true);
      if (protected_status != CLSP_STATUS_OK || length > maximum) {
        return CLSP_STATUS_SRTP_FAILURE;
      }
      pending_rtcp_.kind = PendingProtectedRtcp::Kind::congestion_feedback;
      pending_rtcp_.video_feedback = video_written;
      pending_rtcp_.flexfec_feedback = flexfec_written;
      pending_rtcp_.rtx_feedback = rtx_written;
      pending_rtcp_.audio_feedback = audio_written;
      pending_rtcp_.length = length;
      pending_rtcp_.created_microseconds = now;
      return transmit_pending_rtcp(now);
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

    /** @brief Return the exact bounded retirement record for one frame key. */
    [[nodiscard]] std::optional<VideoRetiredFrame>
    retired_video_frame(const lumen::lsp::media::frame_key key) const noexcept {
      const auto found = std::ranges::find_if(video_retired_frames_, [&](const VideoRetiredFrame &entry) {
        return entry.occupied && entry.key == key;
      });
      return found == video_retired_frames_.end() ? std::nullopt : std::optional<VideoRetiredFrame> {*found};
    }

    /** @brief Return whether a terminal key must reject ordinary late packets. */
    [[nodiscard]] bool video_frame_retired(const lumen::lsp::media::frame_key key) const noexcept {
      return retired_video_frame(key).has_value();
    }

    /**
     * @brief Retain one recently retired key, reason, and optional authenticated identity.
     *
     * @param key Terminal provisional frame key.
     * @param reason Why the key retired.
     * @param frame_id Bound frame ID, or zero only with a zero epoch.
     * @param recovery_epoch Bound epoch, or zero only with a zero frame ID.
     */
    void retire_video_frame(
      const lumen::lsp::media::frame_key key,
      const VideoRetirementReason reason,
      const std::uint64_t frame_id = 0,
      const std::uint32_t recovery_epoch = 0
    ) noexcept {
      if ((frame_id == 0) != (recovery_epoch == 0)) {
        realtime_failure_status_ = CLSP_STATUS_INTERNAL_FAILURE;
        return;
      }
      const auto existing = std::ranges::find_if(video_retired_frames_, [&](const VideoRetiredFrame &entry) {
        return entry.occupied && entry.key == key;
      });
      if (existing != video_retired_frames_.end()) {
        if (existing->reason == VideoRetirementReason::expired_incomplete &&
            existing->frame_id == 0 && existing->recovery_epoch == 0 &&
            reason == VideoRetirementReason::expired_incomplete && frame_id != 0) {
          existing->frame_id = frame_id;
          existing->recovery_epoch = recovery_epoch;
        }
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
        .reason = reason,
        .frame_id = frame_id,
        .recovery_epoch = recovery_epoch,
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
      const auto decoder_error =
        decoder_status == lumen::lsp::transport::lspv_decoder_status::recoverable_error ||
        decoder_status == lumen::lsp::transport::lspv_decoder_status::unrecoverable_error;
      if (decoder_error || deadline_miss) {
        video_recovery_feedback_pending_ = true;
        video_recovery_evidence_watermark_ =
          std::max(video_recovery_evidence_watermark_, video_largest_decoded_frame_id_);
      }
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
      if (deadline_miss) {
        video_recovery_feedback_pending_ = true;
        video_recovery_evidence_watermark_ =
          std::max(video_recovery_evidence_watermark_, video_largest_decoded_frame_id_);
      }
      const auto status = current_decoder_capacity_status();
      const auto update =
        lspv_coalescer_.update(current_lspv_status(status), event);
      pthread_mutex_unlock(&mutex_);
      if (update == lumen::lsp::transport::lspv_update_result::accepted) {
        wake_worker();
      }
    }

    /** @brief Classify encrypted epoch metadata without changing recovery state. */
    [[nodiscard]] VideoEpochDisposition pending_video_epoch(const VideoExtensions &extensions) noexcept {
      if (!extensions.has_frame_id) {
        return VideoEpochDisposition::current;
      }
      pthread_mutex_lock(&mutex_);
      const auto disposition = classify_video_epoch(
        video_current_recovery_epoch_,
        extensions.recovery_epoch,
        extensions.has_frame_marking && extensions.independent
      );
      pthread_mutex_unlock(&mutex_);
      return disposition;
    }

    /**
     * @brief Commit one already validated +1 epoch and retire only older provisional frames.
     *
     * @param key Current authenticated provisional frame key to preserve.
     * @param extensions Validated repeated metadata carrying the next epoch.
     * @param sequence_number Boundary packet primary RTP sequence.
     * @param current_frame_expired Whether the validated current frame is already retired or expired.
     * @return True only when the epoch and coalescer advanced atomically.
     */
    [[nodiscard]] bool advance_video_epoch(
      const lumen::lsp::media::frame_key key,
      const VideoExtensions &extensions,
      const std::uint16_t sequence_number,
      const bool current_frame_expired
    ) noexcept {
      pthread_mutex_lock(&mutex_);
      if (classify_video_epoch(
            video_current_recovery_epoch_,
            extensions.recovery_epoch,
            extensions.has_frame_marking && extensions.independent
          ) != VideoEpochDisposition::advance) {
        pthread_mutex_unlock(&mutex_);
        return false;
      }
      video_current_recovery_epoch_ = extensions.recovery_epoch;
      const auto evidence = video_epoch_advance_evidence(current_frame_expired, video_largest_decoded_frame_id_);
      video_deadline_miss_latched_ = evidence.deadline_miss;
      video_recovery_feedback_pending_ = evidence.repeat_feedback;
      video_recovery_evidence_watermark_ = evidence.decoded_watermark;
      last_recovery_lspv_microseconds_ = 0;
      const auto update = lspv_coalescer_.update(
        current_lspv_status(current_decoder_capacity_status()),
        lumen::lsp::transport::lspv_event::capacity_transition
      );
      pthread_mutex_unlock(&mutex_);
      if (update != lumen::lsp::transport::lspv_update_result::accepted) {
        return false;
      }
      for (auto &metadata : video_metadata_) {
        if (retire_on_video_epoch_advance(metadata.occupied, metadata.key, key)) {
          retire_video_frame(
            metadata.key,
            VideoRetirementReason::evicted_incomplete,
            metadata.frame_id,
            metadata.recovery_epoch
          );
          metadata = {};
        }
      }
      if (video_reassembler_) {
        (void)video_reassembler_->clear_except(
          key,
          [this](const std::uint64_t token) noexcept {
            (void)video_receive_pool_.release(token);
          }
        );
      }
      for (auto &source : authenticated_video_sources_) {
        const auto same_frame = source.rtp_timestamp == static_cast<std::uint32_t>(key.extended_timestamp) &&
                                (source.frame_id == 0 || source.frame_id == extensions.frame_id);
        if (source.occupied && !same_frame) {
          (void)video_receive_pool_.release(source.slab_token);
          source = {};
        }
      }
      for (auto &repair : pending_flexfec_repairs_) {
        if (!repair.occupied) {
          continue;
        }
        const auto association_valid = bind_pending_flexfec_repair(
          repair,
          extensions.recovery_epoch
        );
        auto same_frame = association_valid && flexfec_repair_matches_advancing_frame(
          repair.frame_bound,
          repair.bound_rtp_timestamp,
          repair.bound_frame_id,
          repair.bound_recovery_epoch,
          repair.repair_timestamp,
          repair.base_sequence_number,
          repair.source_mask,
          sequence_number,
          static_cast<std::uint32_t>(key.extended_timestamp),
          extensions.frame_id,
          extensions.recovery_epoch
        );
        if (same_frame && !repair.frame_bound) {
          repair.bound_rtp_timestamp = static_cast<std::uint32_t>(key.extended_timestamp);
          repair.bound_frame_id = extensions.frame_id;
          repair.bound_recovery_epoch = extensions.recovery_epoch;
          repair.frame_bound = true;
          same_frame = true;
        }
        if (!same_frame) {
          (void)video_receive_pool_.release(repair.slab_token);
          repair = {};
        }
      }
      pending_video_nack_ = {};
      video_nack_retries_ = {};
      if (!video_gap_tracker_.reset(
            video_configuration_.primary_ssrc,
            video_configuration_.video_generation,
            configuration_.profile == CLSP_PROFILE_COMPETITION_LAN ?
              competition_reorder_delay_microseconds :
              adaptive_reorder_delay_microseconds
          )) {
        return false;
      }
      wake_worker();
      return true;
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
          retire_video_frame(
            metadata.key,
            VideoRetirementReason::expired_incomplete,
            metadata.frame_id,
            metadata.recovery_epoch
          );
          metadata = {};
          ++expired;
        }
      }
      (void)video_reassembler_->expire(now, [this](const std::uint64_t token) noexcept {
        (void)video_receive_pool_.release(token);
      });
      if (expired != 0) {
        coalesce_video_capacity_status(
          lumen::lsp::transport::lspv_event::capacity_transition,
          true
        );
      }
    }

    /** @brief Find bounded metadata for one provisional video frame without creating it. */
    [[nodiscard]] VideoFrameMetadata *find_video_metadata(const lumen::lsp::media::frame_key key) noexcept {
      const auto found = std::ranges::find_if(video_metadata_, [&](const VideoFrameMetadata &metadata) {
        return metadata.occupied && metadata.key == key;
      });
      return found == video_metadata_.end() ? nullptr : &*found;
    }

    /** @brief Find or create bounded metadata for one provisional video frame. */
    [[nodiscard]] VideoFrameMetadata *
    video_metadata_for(const lumen::lsp::media::frame_key key, const std::uint64_t now) noexcept {
      if (auto *metadata = find_video_metadata(key); metadata != nullptr) {
        return metadata;
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
        .first_authenticated_microseconds = now,
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
    merge_video_metadata(
      VideoFrameMetadata &metadata,
      const VideoExtensions &extensions,
      const std::uint16_t sequence_number
    ) noexcept {
      if (extensions.has_frame_id) {
        if (extensions.frame_id < video_configuration_.frame_id_origin ||
            (metadata.frame_id != 0 && metadata.frame_id != extensions.frame_id) ||
            (metadata.recovery_epoch != 0 && metadata.recovery_epoch != extensions.recovery_epoch)) {
          return false;
        }
        metadata.frame_id = extensions.frame_id;
        metadata.recovery_epoch = extensions.recovery_epoch;
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
      if (extensions.starts_frame) {
        if (metadata.has_start_sequence && metadata.start_sequence_number != sequence_number) {
          return false;
        }
        metadata.has_start_sequence = true;
        metadata.start_sequence_number = sequence_number;
      }
      return true;
    }

    /** @brief Return one exact retained authenticated source by generation and sequence. */
    [[nodiscard]] const AuthenticatedVideoSourcePacket *authenticated_video_source(
      const std::uint16_t sequence_number
    ) const noexcept {
      const auto &slot = authenticated_video_sources_[sequence_number % authenticated_video_sources_.size()];
      return slot.occupied && slot.sequence_number == sequence_number &&
                     slot.video_generation == video_configuration_.video_generation ?
               &slot :
               nullptr;
    }

    /** @brief Borrow one retained authenticated source packet. */
    [[nodiscard]] std::span<const std::uint8_t> authenticated_video_source_bytes(
      const AuthenticatedVideoSourcePacket &source
    ) const noexcept {
      const auto slab = video_receive_pool_.bytes(source.slab_token);
      return source.occupied && source.length <= slab.size() ? slab.first(source.length) :
                                                              std::span<const std::uint8_t> {};
    }

    /** @brief Borrow one retained authenticated FlexFEC repair packet. */
    [[nodiscard]] std::span<const std::uint8_t> pending_flexfec_repair_bytes(
      const PendingFlexFecRepair &repair
    ) const noexcept {
      const auto slab = video_receive_pool_.bytes(repair.slab_token);
      return repair.occupied && repair.length <= slab.size() ? slab.first(repair.length) :
                                                              std::span<const std::uint8_t> {};
    }

    /** @brief Bind pending parity to authenticated contributing-source frame evidence. */
    [[nodiscard]] bool bind_pending_flexfec_repair(
      PendingFlexFecRepair &repair,
      const std::uint32_t recovery_epoch = 0
    ) noexcept {
      auto found_source = false;
      auto bound_timestamp = repair.bound_rtp_timestamp;
      auto bound_frame_id = repair.bound_frame_id;
      auto bound_epoch = repair.bound_recovery_epoch;
      for (std::size_t offset = 0; offset < lumen::lsp::transport::maximum_flexfec_group_packets; ++offset) {
        if ((repair.source_mask & (std::uint64_t {1} << offset)) == 0) {
          continue;
        }
        const auto sequence = static_cast<std::uint16_t>(repair.base_sequence_number + offset);
        const auto *source = authenticated_video_source(sequence);
        if (source == nullptr) {
          continue;
        }
        if ((repair.frame_bound && source->rtp_timestamp != bound_timestamp) ||
            (found_source && source->rtp_timestamp != bound_timestamp) ||
            (bound_frame_id != 0 && source->frame_id != 0 && source->frame_id != bound_frame_id) ||
            (bound_epoch != 0 && source->recovery_epoch != 0 && source->recovery_epoch != bound_epoch)) {
          return false;
        }
        if (!repair.frame_bound && !found_source) {
          bound_timestamp = source->rtp_timestamp;
        }
        if (bound_frame_id == 0 && source->frame_id != 0) {
          bound_frame_id = source->frame_id;
        }
        if (bound_epoch == 0 && source->recovery_epoch != 0) {
          bound_epoch = source->recovery_epoch;
        }
        found_source = true;
      }
      if (found_source) {
        repair.bound_rtp_timestamp = bound_timestamp;
        repair.bound_frame_id = bound_frame_id;
        repair.bound_recovery_epoch = bound_epoch;
        repair.frame_bound = true;
      }
      if (repair.frame_bound && repair.bound_recovery_epoch == 0 && recovery_epoch != 0) {
        repair.bound_recovery_epoch = recovery_epoch;
      }
      return true;
    }

    /** @brief Count hostile authenticated malformed repair and close only at the rolling limit. */
    void record_authenticated_malformed_repair(const std::uint64_t now) noexcept {
      if (authenticated_repair_abuse_window_start_ == 0 ||
          now < authenticated_repair_abuse_window_start_ ||
          now - authenticated_repair_abuse_window_start_ >= authenticated_repair_abuse_window_microseconds) {
        authenticated_repair_abuse_window_start_ = now;
        authenticated_repair_abuse_count_ = 0;
      }
      if (authenticated_repair_abuse_count_ < std::numeric_limits<std::uint16_t>::max()) {
        ++authenticated_repair_abuse_count_;
      }
      if (authenticated_repair_abuse_count_ >= authenticated_repair_abuse_limit) {
        realtime_failure_status_ = CLSP_STATUS_INVALID_STATE;
      }
    }

    /** @brief Report local pool/queue pressure without fabricating decoder damage. */
    void record_local_video_pressure(const bool deadline_miss = false) noexcept {
      coalesce_video_status(
        lumen::lsp::transport::lspv_decoder_status::surface_exhausted,
        lumen::lsp::transport::lspv_event::capacity_transition,
        deadline_miss
      );
    }

    /** @brief Report genuine unrepaired source damage as recoverable decoder evidence. */
    void record_genuine_video_damage() noexcept {
      coalesce_video_status(
        lumen::lsp::transport::lspv_decoder_status::recoverable_error,
        lumen::lsp::transport::lspv_event::decode_completion,
        false
      );
    }

    /** @brief Retain one admitted primary plaintext packet in fixed FlexFEC source storage. */
    [[nodiscard]] bool retain_authenticated_video_source(
      const std::span<const std::uint8_t> packet,
      const ParsedVideoPacket &parsed,
      const VideoFrameMetadata &metadata,
      const std::uint64_t source_token
    ) noexcept {
      if (video_configuration_.flexfec_ssrc == 0) {
        return true;
      }
      const auto slab = video_receive_pool_.bytes(source_token);
      if (source_token == 0 || packet.empty() || packet.size() > maximum_udp_payload ||
          metadata.deadline_microseconds == 0 || slab.data() != packet.data() || packet.size() > slab.size() ||
          !video_receive_pool_.retain(source_token)) {
        return false;
      }
      auto &slot = authenticated_video_sources_[
        parsed.header.sequence_number % authenticated_video_sources_.size()
      ];
      if (slot.occupied) {
        (void)video_receive_pool_.release(slot.slab_token);
      }
      slot = {};
      slot.frame_deadline_microseconds = metadata.deadline_microseconds;
      slot.frame_id = metadata.frame_id;
      slot.slab_token = source_token;
      slot.video_generation = video_configuration_.video_generation;
      slot.rtp_timestamp = parsed.header.timestamp;
      slot.recovery_epoch = metadata.recovery_epoch;
      slot.length = packet.size();
      slot.sequence_number = parsed.header.sequence_number;
      slot.occupied = true;
      return true;
    }

    /** @brief Drop any protected unsent NACK that names a newly resolved source. */
    void cancel_pending_nack_for(const std::uint16_t sequence_number) noexcept {
      if (pending_video_nack_) {
        const auto sequences = std::span<const std::uint16_t> {pending_video_nack_.sequences}.first(
          pending_video_nack_.sequence_count
        );
        if (std::ranges::find(sequences, sequence_number) != sequences.end()) {
          pending_video_nack_ = {};
        }
      }
      for (auto &retry : video_nack_retries_) {
        if (retry.occupied && retry.sequence_number == sequence_number) {
          retry = {};
          break;
        }
      }
    }

    /** @brief Return strict receiver-side RTX timing reserves for the active profile. */
    [[nodiscard]] lumen::lsp::transport::rtx_deadline_estimate rtx_deadline_estimate() const noexcept {
      if (configuration_.profile == CLSP_PROFILE_COMPETITION_LAN &&
          configuration_.competition_capacity_mbps != 0) {
        const auto bits = static_cast<std::uint64_t>(current_udp_payload_size_.load(std::memory_order_acquire)) * 8U;
        const auto rate = static_cast<std::uint64_t>(configuration_.competition_capacity_mbps) * 1'000'000U;
        return {
          .reverse_feedback_microseconds = competition_reorder_delay_microseconds,
          .retransmission_serialization_microseconds = (bits * 1'000'000U + rate - 1U) / rate,
          .forward_delivery_microseconds = competition_reorder_delay_microseconds,
          .decode_safety_reserve_microseconds = 500U,
        };
      }
      return {
        .reverse_feedback_microseconds = 2'000U,
        .retransmission_serialization_microseconds = 1'000U,
        .forward_delivery_microseconds = 2'000U,
        .decode_safety_reserve_microseconds = 1'000U,
      };
    }

    /** @brief Admit one primary sequence into shared replay and deadline-aware gap state. */
    [[nodiscard]] VideoSourceAdmission admit_video_source_sequence(
      const ParsedVideoPacket &parsed,
      const VideoFrameMetadata &metadata,
      const std::uint64_t now
    ) noexcept {
      const auto previous_highest = video_source_replay_.highest_sequence();
      const auto replay = video_source_replay_.admit(
        parsed.header.ssrc,
        video_configuration_.video_generation,
        parsed.header.sequence_number
      );
      if (replay == lumen::lsp::transport::source_replay_result::duplicate ||
          replay == lumen::lsp::transport::source_replay_result::too_old) {
        return VideoSourceAdmission::duplicate;
      }
      if (replay != lumen::lsp::transport::source_replay_result::accepted_new_highest &&
          replay != lumen::lsp::transport::source_replay_result::accepted_reordered) {
        realtime_failure_status_ = CLSP_STATUS_INVALID_STATE;
        return VideoSourceAdmission::rejected;
      }
      if (previous_highest && replay == lumen::lsp::transport::source_replay_result::accepted_new_highest) {
        const auto forward = static_cast<std::uint16_t>(parsed.header.sequence_number - *previous_highest);
        if (forward > maximum_video_gap_count + 1U) {
          record_genuine_video_damage();
          return VideoSourceAdmission::rejected;
        }
        auto gap_frame_id = metadata.frame_id;
        auto gap_deadline = metadata.deadline_microseconds;
        if (parsed.extensions.starts_frame) {
          if (const auto *previous = authenticated_video_source(*previous_highest);
              previous != nullptr && previous->rtp_timestamp != parsed.header.timestamp &&
              previous->frame_id != 0) {
            gap_frame_id = previous->frame_id;
            gap_deadline = previous->frame_deadline_microseconds;
          }
        }
        if (gap_frame_id != 0) {
          for (std::uint16_t offset = 1; offset < forward; ++offset) {
            const auto missing = static_cast<std::uint16_t>(*previous_highest + offset);
            const auto recorded = video_gap_tracker_.record_gap(
              video_configuration_.primary_ssrc,
              video_configuration_.video_generation,
              missing,
              gap_frame_id,
              gap_deadline,
              now
            );
            if (recorded == lumen::lsp::transport::video_gap_result::capacity_exceeded) {
              record_local_video_pressure();
              return VideoSourceAdmission::rejected;
            }
            if (recorded == lumen::lsp::transport::video_gap_result::conflicting_gap ||
                recorded == lumen::lsp::transport::video_gap_result::invalid_gap ||
                recorded == lumen::lsp::transport::video_gap_result::invalid_identifier) {
              record_authenticated_malformed_repair(now);
              return VideoSourceAdmission::rejected;
            }
          }
        }
      }
      const auto observed = video_gap_tracker_.observe_source(
        video_configuration_.primary_ssrc,
        video_configuration_.video_generation,
        parsed.header.sequence_number
      );
      if (observed == lumen::lsp::transport::video_gap_result::invalid_identifier) {
        realtime_failure_status_ = CLSP_STATUS_INTERNAL_FAILURE;
        return VideoSourceAdmission::rejected;
      }
      cancel_pending_nack_for(parsed.header.sequence_number);
      return VideoSourceAdmission::accepted;
    }

    /** @brief Admit one authenticated primary video RTP packet into bounded
     * native reassembly. */
    [[nodiscard]] bool
    handle_authenticated_video(
      const std::span<const std::uint8_t> packet,
      const std::uint64_t now,
      const VideoSourceOrigin origin = VideoSourceOrigin::primary_srtp,
      const lumen::lsp::transport::authenticated_recovered_packet *recovered_marker = nullptr,
      const std::uint64_t source_token = 0
    ) noexcept {
      if (!video_reassembler_) {
        return false;
      }
      const auto parsed = parse_video_packet(packet, video_configuration_);
      if (!parsed) {
        return false;
      }
      const auto source_slab = video_receive_pool_.bytes(source_token);
      if (source_token == 0 || source_slab.data() != packet.data() || packet.size() > source_slab.size()) {
        realtime_failure_status_ = CLSP_STATUS_INTERNAL_FAILURE;
        return false;
      }
      if (origin == VideoSourceOrigin::flexfec &&
          (recovered_marker == nullptr ||
           recovered_marker->source_ssrc() != video_configuration_.primary_ssrc ||
           recovered_marker->generation() != video_configuration_.video_generation ||
           recovered_marker->payload_type() != video_configuration_.primary_payload_type)) {
        realtime_failure_status_ = CLSP_STATUS_INVALID_STATE;
        return false;
      }
      if (origin != VideoSourceOrigin::flexfec && recovered_marker != nullptr) {
        realtime_failure_status_ = CLSP_STATUS_INVALID_STATE;
        return false;
      }
      const auto key = lumen::lsp::media::frame_key{
        .ssrc = parsed->header.ssrc,
        .extended_timestamp = extend_video_timestamp(parsed->header.timestamp),
      };
      if (parsed->header.marker != parsed->extensions.ends_frame ||
          ((parsed->extensions.starts_frame || parsed->extensions.ends_frame) &&
           (!parsed->extensions.has_frame_id ||
            !parsed->extensions.has_frame_marking))) {
        retire_video_frame(
          key,
          VideoRetirementReason::malformed,
          parsed->extensions.frame_id,
          parsed->extensions.recovery_epoch
        );
        return false;
      }
      const auto epoch = pending_video_epoch(parsed->extensions);
      if (epoch == VideoEpochDisposition::stale) {
        retire_video_frame(
          key,
          VideoRetirementReason::stale_epoch,
          parsed->extensions.frame_id,
          parsed->extensions.recovery_epoch
        );
        erase_video_metadata(key);
        return true;
      }
      if (epoch == VideoEpochDisposition::invalid) {
        realtime_failure_status_ = CLSP_STATUS_INVALID_STATE;
        return false;
      }
      const auto payload_type = video_configuration_.codec == CLSP_VIDEO_CODEC_H264 ?
                                  static_cast<std::uint8_t>(parsed->payload[0] & 0x1fU) :
                                  static_cast<std::uint8_t>((parsed->payload[0] >> 1U) & 0x3fU);
      if (video_configuration_.codec == CLSP_VIDEO_CODEC_H264 &&
          payload_type == lumen::lsp::media::h264_fu_a_type) {
        if ((parsed->extensions.starts_frame &&
             (parsed->payload.size() < 2U ||
              (parsed->payload[1] & 0x80U) == 0)) ||
            (parsed->extensions.ends_frame &&
             (parsed->payload.size() < 2U || (parsed->payload[1] & 0x40U) == 0))) {
          retire_video_frame(
            key,
            VideoRetirementReason::malformed,
            parsed->extensions.frame_id,
            parsed->extensions.recovery_epoch
          );
          return false;
        }
      }
      if (video_configuration_.codec == CLSP_VIDEO_CODEC_HEVC &&
          payload_type == lumen::lsp::media::hevc_fu_type) {
        if ((parsed->extensions.starts_frame &&
             (parsed->payload.size() < 3U ||
              (parsed->payload[2] & 0x80U) == 0)) ||
            (parsed->extensions.ends_frame &&
             (parsed->payload.size() < 3U || (parsed->payload[2] & 0x40U) == 0))) {
          retire_video_frame(
            key,
            VideoRetirementReason::malformed,
            parsed->extensions.frame_id,
            parsed->extensions.recovery_epoch
          );
          return false;
        }
      }
      auto valid_payload = false;
      if (video_configuration_.codec == CLSP_VIDEO_CODEC_H264) {
        valid_payload = valid_h264_payload(parsed->payload);
      } else if (video_configuration_.codec == CLSP_VIDEO_CODEC_HEVC) {
        valid_payload = valid_hevc_payload(parsed->payload);
      } else {
        const auto aggregation = lumen::lsp::media::parse_av1_aggregation_header(parsed->payload);
        valid_payload = aggregation &&
                        (!parsed->extensions.starts_frame ||
                         !aggregation.header.continuation_from_previous) &&
                        (!parsed->extensions.ends_frame || !aggregation.header.continues_in_next);
      }
      if (!valid_payload) {
        retire_video_frame(
          key,
          VideoRetirementReason::malformed,
          parsed->extensions.frame_id,
          parsed->extensions.recovery_epoch
        );
        return false;
      }
      const auto retired_before_validation = retired_video_frame(key);
      if (epoch != VideoEpochDisposition::advance && retired_before_validation) {
        return true;
      }
      if (epoch == VideoEpochDisposition::advance && retired_before_validation &&
          !permit_late_video_epoch_advance(
            retired_before_validation->reason,
            retired_before_validation->frame_id,
            retired_before_validation->recovery_epoch,
            parsed->extensions.frame_id,
            parsed->extensions.recovery_epoch
          )) {
        realtime_failure_status_ = CLSP_STATUS_INVALID_STATE;
        return false;
      }
      auto *metadata = video_metadata_for(key, now);
      if (metadata == nullptr ||
          !merge_video_metadata(*metadata, parsed->extensions, parsed->header.sequence_number)) {
        if (metadata != nullptr) {
          retire_video_frame(
            key,
            VideoRetirementReason::malformed,
            metadata->frame_id,
            metadata->recovery_epoch
          );
        }
        erase_video_metadata(key);
        return false;
      }
      const auto source_admission = admit_video_source_sequence(*parsed, *metadata, now);
      if (source_admission != VideoSourceAdmission::accepted) {
        return source_admission == VideoSourceAdmission::duplicate;
      }
      const auto current_frame_expired = retired_before_validation.has_value() || metadata->deadline_microseconds <= now;
      if (epoch == VideoEpochDisposition::advance &&
          !advance_video_epoch(
            key,
            parsed->extensions,
            parsed->header.sequence_number,
            current_frame_expired
          )) {
        erase_video_metadata(key);
        realtime_failure_status_ = CLSP_STATUS_INTERNAL_FAILURE;
        return false;
      }
      if (current_frame_expired) {
        if (epoch == VideoEpochDisposition::advance) {
          retire_video_frame(
            key,
            VideoRetirementReason::expired_incomplete,
            metadata->frame_id,
            metadata->recovery_epoch
          );
          erase_video_metadata(key);
          (void)video_reassembler_->expire(now, [this](const std::uint64_t token) noexcept {
            (void)video_receive_pool_.release(token);
          });
        } else {
          expire_video_frames(now);
        }
        return true;
      }
      expire_video_frames(now);
      if (video_frame_retired(key)) {
        return true;
      }
      if (!retain_authenticated_video_source(packet, *parsed, *metadata, source_token)) {
        realtime_failure_status_ = CLSP_STATUS_INTERNAL_FAILURE;
        return false;
      }
      const auto result = video_reassembler_->add(
        {
          .key = key,
          .frame_id = parsed->extensions.has_frame_id ? parsed->extensions.frame_id : 0,
          .extended_sequence =
            extend_video_sequence(parsed->header.sequence_number),
          .deadline_us = metadata->deadline_microseconds,
          .slice_token = source_token,
          .starts_frame = parsed->extensions.starts_frame,
          .ends_frame = parsed->extensions.ends_frame,
          .marker = parsed->header.marker,
          .payload = parsed->payload,
        },
        now,
        [this](const std::uint64_t token) noexcept {
          return video_receive_pool_.retain(token);
        },
        [this](const std::uint64_t token) noexcept {
          (void)video_receive_pool_.release(token);
        }
      );
      if (result.evicted) {
        const auto *evicted = find_video_metadata(*result.evicted);
        retire_video_frame(
          *result.evicted,
          VideoRetirementReason::evicted_incomplete,
          evicted == nullptr ? 0 : evicted->frame_id,
          evicted == nullptr ? 0 : evicted->recovery_epoch
        );
        erase_video_metadata(*result.evicted);
      }
      if (result.status ==
            lumen::lsp::media::frame_reassembly_status::malformed ||
          result.status ==
            lumen::lsp::media::frame_reassembly_status::frame_too_large ||
          result.status == lumen::lsp::media::frame_reassembly_status::expired ||
          result.status == lumen::lsp::media::frame_reassembly_status::resource_exhausted) {
        retire_video_frame(
          key,
          result.status == lumen::lsp::media::frame_reassembly_status::expired ?
            VideoRetirementReason::expired_incomplete :
            VideoRetirementReason::malformed,
          metadata->frame_id,
          metadata->recovery_epoch
        );
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
      const auto completed = result.frame;
      if (!completed || completed.frame_id == 0 ||
          completed.frame_id != metadata->frame_id || metadata->recovery_epoch == 0 ||
          !metadata->has_independent_marking || !metadata->has_start_sequence ||
          completed.total_size == 0 ||
          completed.total_size > lumen::lsp::media::absolute_frame_size_limit) {
        (void)video_reassembler_->release(completed, [this](const std::uint64_t token) noexcept {
          (void)video_receive_pool_.release(token);
        });
        retire_video_frame(key, VideoRetirementReason::malformed, metadata->frame_id, metadata->recovery_epoch);
        erase_video_metadata(key);
        return false;
      }
      const auto buffer_size = static_cast<std::size_t>(video_configuration_.maximum_access_unit_bytes);
      auto *buffer = acquire_retained_frame_buffer(video_frame_pool_, buffer_size);
      if (buffer == nullptr) {
        (void)video_reassembler_->release(completed, [this](const std::uint64_t token) noexcept {
          (void)video_receive_pool_.release(token);
        });
        coalesce_video_status(
          lumen::lsp::transport::lspv_decoder_status::surface_exhausted,
          lumen::lsp::transport::lspv_event::capacity_transition,
          false
        );
        retire_video_frame(key, VideoRetirementReason::completed, metadata->frame_id, metadata->recovery_epoch);
        erase_video_metadata(key);
        return true;
      }
      auto destination = mutable_retained_frame_bytes(buffer);
      std::size_t offset = 0;
      if (video_configuration_.codec == CLSP_VIDEO_CODEC_AV1) {
        lumen::lsp::media::av1_depacketizer depacketizer {destination};
        lumen::lsp::media::av1_depacketization_result state;
        for (std::size_t index = 0; index < completed.slices.size(); ++index) {
          state = depacketizer.push_packet(
            static_cast<std::uint16_t>(metadata->start_sequence_number + index),
            parsed->header.timestamp,
            index + 1U == completed.slices.size(),
            completed.slices[index].bytes
          );
          if (!state || !state.packet_consumed) {
            break;
          }
        }
        if (!state || !state.packet_consumed || !state.temporal_unit_complete ||
            !depacketizer.complete() || depacketizer.fragment_pending() || depacketizer.bytes().empty() ||
            !resize_retained_frame_buffer(buffer, depacketizer.bytes().size())) {
          (void)video_reassembler_->release(completed, [this](const std::uint64_t token) noexcept {
            (void)video_receive_pool_.release(token);
          });
          clsp_buffer_release(buffer);
          retire_video_frame(key, VideoRetirementReason::malformed, metadata->frame_id, metadata->recovery_epoch);
          erase_video_metadata(key);
          return false;
        }
        offset = depacketizer.bytes().size();
      } else {
        for (const auto source : completed.slices) {
          lumen::lsp::packet_slab<maximum_depacketized_video_bytes> chunk;
          const auto depacketized = video_configuration_.codec == CLSP_VIDEO_CODEC_H264 ?
                                      depacketize_h264(source.bytes, chunk) :
                                      depacketize_hevc(source.bytes, chunk);
          if (!depacketized || chunk.size() > destination.size() - offset) {
            (void)video_reassembler_->release(completed, [this](const std::uint64_t token) noexcept {
              (void)video_receive_pool_.release(token);
            });
            clsp_buffer_release(buffer);
            retire_video_frame(key, VideoRetirementReason::malformed, metadata->frame_id, metadata->recovery_epoch);
            erase_video_metadata(key);
            return false;
          }
          std::copy(chunk.bytes().begin(), chunk.bytes().end(), destination.begin() + static_cast<std::ptrdiff_t>(offset));
          offset += chunk.size();
        }
        if (offset == 0 || !resize_retained_frame_buffer(buffer, offset)) {
          (void)video_reassembler_->release(completed, [this](const std::uint64_t token) noexcept {
            (void)video_receive_pool_.release(token);
          });
          clsp_buffer_release(buffer);
          retire_video_frame(key, VideoRetirementReason::malformed, metadata->frame_id, metadata->recovery_epoch);
          erase_video_metadata(key);
          return false;
        }
      }
      pthread_mutex_lock(&mutex_);
      video_largest_complete_frame_id_ = std::max(video_largest_complete_frame_id_, completed.frame_id);
      pthread_mutex_unlock(&mutex_);
      if (!video_reassembler_->release(completed, [this](const std::uint64_t token) noexcept {
            (void)video_receive_pool_.release(token);
          })) {
        clsp_buffer_release(buffer);
        retire_video_frame(key, VideoRetirementReason::malformed, metadata->frame_id, metadata->recovery_epoch);
        erase_video_metadata(key);
        return false;
      }
      if (pending_video_delivery_count_ >= pending_video_deliveries_.size()) {
        timing_distributions_[CLSP_NATIVE_TIMING_AUTH_TO_HANDOFF].drop();
        clsp_buffer_release(buffer);
        retire_video_frame(key, VideoRetirementReason::completed, metadata->frame_id, metadata->recovery_epoch);
        erase_video_metadata(key);
        coalesce_video_status(
          lumen::lsp::transport::lspv_decoder_status::surface_exhausted,
          lumen::lsp::transport::lspv_event::capacity_transition,
          false
        );
        return true;
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
        timing_distributions_[CLSP_NATIVE_TIMING_AUTH_TO_HANDOFF].drop();
        clsp_buffer_release(buffer);
        retire_video_frame(key, VideoRetirementReason::completed, metadata->frame_id, metadata->recovery_epoch);
        erase_video_metadata(key);
        if (update == lumen::lsp::transport::lspv_update_result::accepted) {
          wake_worker();
        }
        return true;
      }
      if (!remember_delivered_video_frame(completed.frame_id, metadata->recovery_epoch, metadata->independent)) {
        (void)video_decoder_credit_.release();
        pthread_mutex_unlock(&mutex_);
        timing_distributions_[CLSP_NATIVE_TIMING_AUTH_TO_HANDOFF].drop();
        clsp_buffer_release(buffer);
        retire_video_frame(key, VideoRetirementReason::completed, metadata->frame_id, metadata->recovery_epoch);
        erase_video_metadata(key);
        realtime_failure_status_ = CLSP_STATUS_INTERNAL_FAILURE;
        return false;
      }
      const auto update = lspv_coalescer_.update(
        current_lspv_status(current_decoder_capacity_status()),
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
        .frame_id = completed.frame_id,
        .receive_time_microseconds = now,
        .capture_time_microseconds = metadata->capture_time_microseconds,
        .input_state_sequence = metadata->input_state_sequence,
        .input_edge_id = metadata->input_edge_id,
        .recovery_epoch = metadata->recovery_epoch,
        .independent = static_cast<std::uint8_t>(metadata->independent),
        .codec = video_configuration_.codec,
        .payload_format = video_configuration_.payload_format,
        .reserved_zero = 0,
        .encoded_access_unit = buffer,
      };
      const auto first_authenticated_microseconds = metadata->first_authenticated_microseconds;
      retire_video_frame(key, VideoRetirementReason::completed, metadata->frame_id, metadata->recovery_epoch);
      erase_video_metadata(key);
      pending_video_auth_times_[pending_video_delivery_count_] = first_authenticated_microseconds;
      pending_video_deliveries_[pending_video_delivery_count_++] = event;
      return true;
    }

    /** @brief Attempt one RFC 8627 decode from authenticated fixed-pool inputs. */
    [[nodiscard]] FlexFecAttempt attempt_flexfec_repair(
      const std::span<const std::uint8_t> packet,
      const std::uint64_t now
    ) noexcept {
      const auto parsed = lumen::lsp::transport::parse_flexfec_repair(packet);
      if (!parsed || parsed.repair.primary_ssrc != video_configuration_.primary_ssrc ||
          parsed.repair.repair_ssrc != video_configuration_.flexfec_ssrc ||
          parsed.repair.repair_payload_type != video_configuration_.flexfec_payload_type ||
          std::popcount(parsed.repair.source_mask) > video_configuration_.flexfec_maximum_group_packets ||
          std::bit_width(parsed.repair.source_mask) > video_configuration_.flexfec_maximum_group_packets) {
        return FlexFecAttempt::invalid;
      }
      std::array<std::span<const std::uint8_t>, lumen::lsp::transport::maximum_flexfec_group_packets> sources {};
      std::size_t source_count = 0;
      std::optional<std::uint16_t> missing;
      std::uint64_t frame_deadline = 0;
      std::uint32_t frame_timestamp = 0;
      for (std::size_t offset = 0; offset < lumen::lsp::transport::maximum_flexfec_group_packets; ++offset) {
        if ((parsed.repair.source_mask & (std::uint64_t {1} << offset)) == 0) {
          continue;
        }
        const auto sequence = static_cast<std::uint16_t>(parsed.repair.base_sequence_number + offset);
        const auto *source = authenticated_video_source(sequence);
        if (source == nullptr) {
          if (missing) {
            return FlexFecAttempt::waiting;
          }
          missing = sequence;
          continue;
        }
        if (frame_timestamp != 0 && source->rtp_timestamp != frame_timestamp) {
          return FlexFecAttempt::invalid;
        }
        frame_timestamp = source->rtp_timestamp;
        frame_deadline = frame_deadline == 0 ?
                           source->frame_deadline_microseconds :
                           std::min(frame_deadline, source->frame_deadline_microseconds);
        const auto source_bytes = authenticated_video_source_bytes(*source);
        if (source_bytes.empty()) {
          return FlexFecAttempt::invalid;
        }
        sources[source_count++] = source_bytes;
      }
      if (!missing) {
        return FlexFecAttempt::redundant;
      }
      VideoReceiveLease recovered_lease;
      if (!recovered_lease.acquire(video_receive_pool_)) {
        return FlexFecAttempt::waiting;
      }
      const auto recovered = lumen::lsp::transport::recover_flexfec_source(
        parsed.repair,
        *missing,
        std::span<const std::span<const std::uint8_t>> {sources}.first(source_count),
        recovered_lease.bytes()
      );
      if (!recovered) {
        return FlexFecAttempt::invalid;
      }
      const auto recovered_packet = std::span<const std::uint8_t> {recovered_lease.bytes()}.first(recovered.bytes_written);
      const auto recovered_rtp = parse_video_packet(recovered_packet, video_configuration_);
      if (!recovered_rtp || (frame_timestamp != 0 && recovered_rtp->header.timestamp != frame_timestamp)) {
        return FlexFecAttempt::invalid;
      }
      if (frame_deadline == 0) {
        frame_deadline = saturating_add(now, video_configuration_.maximum_frame_age_microseconds);
      }
      const auto authorization = lumen::lsp::transport::recovered_packet_admission::authorize({
        .repair_authenticated_and_decrypted = true,
        .all_contributing_sources_authenticated_and_decrypted = true,
        .expected_source_ssrc = video_configuration_.primary_ssrc,
        .recovered_source_ssrc = recovered_rtp->header.ssrc,
        .expected_generation = video_configuration_.video_generation,
        .recovered_generation = video_configuration_.video_generation,
        .expected_payload_type = video_configuration_.primary_payload_type,
        .recovered_payload_type = recovered_rtp->header.payload_type,
        .recovered_packet_bytes = recovered.bytes_written,
        .maximum_packet_bytes = current_udp_payload_size_.load(std::memory_order_acquire),
        .now_microseconds = now,
        .frame_deadline_microseconds = frame_deadline,
      });
      if (!authorization) {
        return authorization.error == lumen::lsp::transport::recovered_packet_error::expired ?
                 FlexFecAttempt::redundant :
                 FlexFecAttempt::invalid;
      }
      if (!handle_authenticated_video(
            recovered_packet,
            now,
            VideoSourceOrigin::flexfec,
            &*authorization.marker,
            recovered_lease.token()
          )) {
        return FlexFecAttempt::invalid;
      }
      return FlexFecAttempt::recovered;
    }

    /** @brief Revisit retained authenticated repairs after one source admission. */
    [[nodiscard]] bool attempt_pending_flexfec_repairs(const std::uint64_t now) noexcept {
      for (auto &repair : pending_flexfec_repairs_) {
        if (!repair.occupied) {
          continue;
        }
        if (now >= repair.expires_microseconds) {
          (void)video_receive_pool_.release(repair.slab_token);
          repair = {};
          continue;
        }
        if (!bind_pending_flexfec_repair(repair)) {
          (void)video_receive_pool_.release(repair.slab_token);
          repair = {};
          record_authenticated_malformed_repair(now);
          return false;
        }
        const auto repair_bytes = pending_flexfec_repair_bytes(repair);
        if (repair_bytes.empty()) {
          (void)video_receive_pool_.release(repair.slab_token);
          repair = {};
          record_local_video_pressure();
          return false;
        }
        const auto attempted = attempt_flexfec_repair(repair_bytes, now);
        if (attempted == FlexFecAttempt::waiting) {
          continue;
        }
        (void)video_receive_pool_.release(repair.slab_token);
        repair = {};
        if (attempted == FlexFecAttempt::invalid) {
          record_authenticated_malformed_repair(now);
          return false;
        }
      }
      return true;
    }

    /** @brief Authenticate registry fields, decode immediately, or retain one FlexFEC repair. */
    [[nodiscard]] bool handle_authenticated_flexfec(
      const std::span<const std::uint8_t> packet,
      const std::uint64_t now,
      const std::uint64_t packet_token
    ) noexcept {
      if (video_configuration_.flexfec_ssrc == 0 || packet.size() > maximum_udp_payload) {
        record_authenticated_malformed_repair(now);
        return false;
      }
      const auto parsed = lumen::lsp::transport::parse_flexfec_repair(packet);
      if (!parsed || parsed.repair.primary_ssrc != video_configuration_.primary_ssrc ||
          parsed.repair.repair_ssrc != video_configuration_.flexfec_ssrc ||
          parsed.repair.repair_payload_type != video_configuration_.flexfec_payload_type) {
        record_authenticated_malformed_repair(now);
        return false;
      }
      const auto attempted = attempt_flexfec_repair(packet, now);
      if (attempted == FlexFecAttempt::recovered || attempted == FlexFecAttempt::redundant) {
        return true;
      }
      if (attempted == FlexFecAttempt::invalid) {
        record_authenticated_malformed_repair(now);
        return false;
      }
      for (const auto &repair : pending_flexfec_repairs_) {
        if (repair.occupied && repair.repair_sequence_number == parsed.repair.repair_sequence_number) {
          return true;
        }
      }
      auto *slot = std::ranges::find_if(pending_flexfec_repairs_, [](const PendingFlexFecRepair &repair) {
        return !repair.occupied;
      });
      if (slot == pending_flexfec_repairs_.end()) {
        record_local_video_pressure();
        return false;
      }
      const auto slab = video_receive_pool_.bytes(packet_token);
      if (packet_token == 0 || slab.data() != packet.data() || packet.size() > slab.size() ||
          !video_receive_pool_.retain(packet_token)) {
        record_local_video_pressure();
        return false;
      }
      *slot = {};
      slot->expires_microseconds = saturating_add(
        now,
        video_configuration_.flexfec_repair_window_microseconds
      );
      slot->slab_token = packet_token;
      slot->source_mask = parsed.repair.source_mask;
      slot->repair_timestamp = parsed.repair.repair_timestamp;
      slot->length = packet.size();
      slot->repair_sequence_number = parsed.repair.repair_sequence_number;
      slot->base_sequence_number = parsed.repair.base_sequence_number;
      slot->occupied = true;
      if (!bind_pending_flexfec_repair(*slot)) {
        (void)video_receive_pool_.release(slot->slab_token);
        *slot = {};
        record_authenticated_malformed_repair(now);
        return false;
      }
      return true;
    }

    /** @brief Reconstruct and admit one authenticated RFC 4588 retransmission. */
    [[nodiscard]] bool handle_authenticated_rtx(
      const std::span<const std::uint8_t> packet,
      const std::uint64_t now
    ) noexcept {
      if (video_configuration_.rtx_ssrc == 0) {
        record_authenticated_malformed_repair(now);
        return false;
      }
      VideoReceiveLease reconstructed_lease;
      if (!reconstructed_lease.acquire(video_receive_pool_)) {
        record_local_video_pressure();
        return false;
      }
      const auto reconstructed = reconstruct_rtx_source(
        packet,
        video_configuration_.rtx_ssrc,
        video_configuration_.rtx_payload_type,
        video_configuration_.primary_ssrc,
        video_configuration_.rtx_associated_payload_type,
        reconstructed_lease.bytes()
      );
      if (!reconstructed || reconstructed.bytes_written > current_udp_payload_size_.load(std::memory_order_acquire)) {
        record_authenticated_malformed_repair(now);
        return false;
      }
      const auto source = std::span<const std::uint8_t> {reconstructed_lease.bytes()}.first(reconstructed.bytes_written);
      if (!handle_authenticated_video(
            source,
            now,
            VideoSourceOrigin::rtx,
            nullptr,
            reconstructed_lease.token()
          )) {
        if (realtime_failure_status_ == CLSP_STATUS_OK) {
          record_authenticated_malformed_repair(now);
        }
        return false;
      }
      if (!attempt_pending_flexfec_repairs(now)) {
        return false;
      }
      return true;
    }

    /** @brief Deliver complete-frame callbacks only after the current socket
     * drain finishes. */
    void deliver_video_frames() noexcept {
      if (!video_delivery_active_.load(std::memory_order_acquire)) {
        return;
      }
      for (std::size_t index = 0; index < pending_video_delivery_count_;
           ++index) {
        record_timing_stage(
          CLSP_NATIVE_TIMING_AUTH_TO_HANDOFF,
          pending_video_auth_times_[index],
          monotonic_microseconds()
        );
        callbacks_.video_frame(callbacks_.context, pending_video_deliveries_[index]);
        pending_video_deliveries_[index] = {};
        pending_video_auth_times_[index] = 0U;
      }
      pending_video_delivery_count_ = 0;
    }

    /** @brief Serialize and submit the frozen 56-byte protected RTCP APP LSPV
     * status. */
    [[nodiscard]] clsp_status_t transmit_lspv() noexcept {
  #if defined(__APPLE__) && CLSP_CORE_HAS_RUNTIME
      if (!video_delivery_active_.load(std::memory_order_acquire) || !compound_rtcp_sent_ ||
          !video_configured_.load(std::memory_order_acquire) || !input_configured_ || pending_rtcp_) {
        return CLSP_STATUS_OK;
      }
      const auto now = monotonic_microseconds();
      lumen::lsp::transport::lspv_status status;
      lumen::lsp::transport::lspv_event event;
      pthread_mutex_lock(&mutex_);
      if (recovery_lspv_repeat_due(video_recovery_feedback_pending_, last_recovery_lspv_microseconds_, now)) {
        const auto repeated = lspv_coalescer_.update(
          current_lspv_status(current_decoder_capacity_status()),
          lumen::lsp::transport::lspv_event::capacity_transition
        );
        if (repeated != lumen::lsp::transport::lspv_update_result::accepted) {
          pthread_mutex_unlock(&mutex_);
          return CLSP_STATUS_INTERNAL_FAILURE;
        }
      }
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
      auto &packet = pending_rtcp_.bytes;
      std::fill(packet.begin(), packet.end(), 0);
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
      pending_rtcp_.kind = PendingProtectedRtcp::Kind::lspv;
      pending_rtcp_.length = length;
      pending_rtcp_.created_microseconds = now;
      return transmit_pending_rtcp(now);
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

    /** @brief Return whether authenticated feedback names the active input authority. */
    [[nodiscard]] bool active_reverse_feedback_mapping() const noexcept {
      return input_configured_ && input_configuration_.stream_generation != 0 &&
             input_configuration_.input_generation != 0 && input_configuration_.input_ssrc != 0 &&
             input_configuration_.acknowledgement_ssrc != 0;
    }

    /** @brief Return whether the active reverse authority also owns microphone media. */
    [[nodiscard]] bool active_microphone_feedback_mapping() const noexcept {
      return active_reverse_feedback_mapping() && microphone_active_.load(std::memory_order_acquire) &&
             microphone_prepared_.load(std::memory_order_acquire) &&
             microphone_configuration_.stream_generation != 0 &&
             microphone_configuration_.stream_generation == input_configuration_.stream_generation &&
             microphone_configuration_.microphone_generation != 0 &&
             microphone_configuration_.microphone_ssrc != 0 &&
             input_configuration_.acknowledgement_ssrc != 0;
    }

    /** @brief Validate host compound RR/CNAME and derive reverse RTT from real LSR/DLSR. */
    [[nodiscard]] bool handle_reverse_receiver_report(
      const std::span<const std::uint8_t> packet,
      const std::uint64_t now
    ) noexcept {
      if (!active_reverse_feedback_mapping()) {
        return false;
      }
      const auto authority = lumen::lsp::transport::validate_compound_rtcp_authority(
        packet,
        input_configuration_.acknowledgement_ssrc
      );
      if (!authority ||
          authority.first_report.packet_type != lumen::lsp::transport::rtcp_receiver_report_type ||
          now < microphone_last_compound_microseconds_ ||
          (microphone_feedback_cname_length_ != 0 &&
           (microphone_feedback_cname_length_ != authority.cname.size() ||
            !std::equal(
              authority.cname.begin(),
              authority.cname.end(),
              microphone_feedback_cname_.begin()
            )))) {
        return false;
      }

      const auto &report_packet = authority.first_report;
      const auto report_offset = report_packet.packet_type == lumen::lsp::transport::rtcp_sender_report_type ?
                                   24U : 4U;
      std::uint32_t candidate_rtt = 0;
      const auto microphone_active = active_microphone_feedback_mapping();
      bool input_report_seen = false;
      bool microphone_report_seen = false;
      for (std::size_t index = 0; index < report_packet.count; ++index) {
        const auto report = report_packet.payload.subspan(report_offset + index * 24U, 24U);
        const auto media_ssrc = lumen::lsp::wire::read_be<std::uint32_t>(report.first<4>());
        const std::array<MicrophoneSenderReportTiming, 8> *timings = nullptr;
        if (media_ssrc == input_configuration_.input_ssrc) {
          if (input_report_seen) {
            return false;
          }
          input_report_seen = true;
          timings = &input_sender_report_timings_;
        } else if (microphone_active && media_ssrc == microphone_configuration_.microphone_ssrc) {
          if (microphone_report_seen) {
            return false;
          }
          microphone_report_seen = true;
          timings = &microphone_sender_report_timings_;
        } else {
          return false;
        }
        const auto lsr = lumen::lsp::wire::read_be<std::uint32_t>(report.subspan<16, 4>());
        const auto dlsr = lumen::lsp::wire::read_be<std::uint32_t>(report.subspan<20, 4>());
        std::uint64_t sender_report_time = 0;
        for (const auto &timing : *timings) {
          if (timing.lsr == lsr) {
            sender_report_time = timing.sent_microseconds;
            break;
          }
        }
        if (lsr == 0 || sender_report_time == 0 || sender_report_time > now) {
          continue;
        }
        const auto receiver_delay = static_cast<std::uint64_t>(dlsr) * 1'000'000ULL / 65'536ULL;
        const auto elapsed = now - sender_report_time;
        if (receiver_delay < elapsed && elapsed - receiver_delay <= 10'000'000U) {
          candidate_rtt = static_cast<std::uint32_t>(elapsed - receiver_delay);
        }
      }

      if (microphone_feedback_cname_length_ == 0) {
        std::copy(authority.cname.begin(), authority.cname.end(), microphone_feedback_cname_.begin());
        microphone_feedback_cname_length_ = authority.cname.size();
      }
      if (candidate_rtt != 0) {
        if (microphone_smoothed_rtt_microseconds_ == 0) {
          microphone_smoothed_rtt_microseconds_ = candidate_rtt;
          microphone_rtt_variation_microseconds_ = candidate_rtt / 2U;
        } else {
          const auto difference = microphone_smoothed_rtt_microseconds_ > candidate_rtt ?
                                    microphone_smoothed_rtt_microseconds_ - candidate_rtt :
                                    candidate_rtt - microphone_smoothed_rtt_microseconds_;
          microphone_rtt_variation_microseconds_ =
            (microphone_rtt_variation_microseconds_ * 3U + difference) / 4U;
          microphone_smoothed_rtt_microseconds_ =
            (microphone_smoothed_rtt_microseconds_ * 7U + candidate_rtt) / 8U;
        }
      }
      microphone_last_compound_microseconds_ = now;
      return true;
    }

    /** @brief Atomically apply authenticated input/microphone CCFB to the aggregate reverse controller. */
    [[nodiscard]] bool handle_reverse_congestion_feedback(
      const std::span<const std::uint8_t> packet,
      const std::uint64_t now
    ) noexcept {
      if (!active_reverse_feedback_mapping() || microphone_feedback_cname_length_ == 0 ||
          now < microphone_last_compound_microseconds_ ||
          now - microphone_last_compound_microseconds_ > microphone_compound_freshness_microseconds) {
        return false;
      }
      const auto feedback = lumen::lsp::transport::validate_congestion_feedback_packet(
        packet,
        input_configuration_.acknowledgement_ssrc
      );
      if (!feedback) {
        return false;
      }
      const lumen::lsp::transport::congestion_feedback_block_view *input_block = nullptr;
      const lumen::lsp::transport::congestion_feedback_block_view *microphone_block = nullptr;
      const auto microphone_active = active_microphone_feedback_mapping();
      for (std::size_t index = 0; index < feedback.block_count; ++index) {
        const auto &block = feedback.blocks[index];
        if (block.media_ssrc == input_configuration_.input_ssrc) {
          if (input_block != nullptr) {
            return false;
          }
          input_block = &block;
        } else if (microphone_active && block.media_ssrc == microphone_configuration_.microphone_ssrc) {
          if (microphone_block != nullptr) {
            return false;
          }
          microphone_block = &block;
        } else {
          return false;
        }
      }
      if (input_block == nullptr && microphone_block == nullptr) {
        return false;
      }
      const auto input_report_count = input_block == nullptr ? 0U : input_block->report_count;
      const auto microphone_report_count = microphone_block == nullptr ? 0U : microphone_block->report_count;
      if (input_report_count == 0 && microphone_report_count == 0) {
        return true;
      }
      if (input_report_count > input_sent_packets_.size() ||
          microphone_report_count > microphone_sent_packets_.size() ||
          (microphone_last_feedback_microseconds_ != 0 &&
           (now < microphone_last_feedback_microseconds_ ||
            now - microphone_last_feedback_microseconds_ <
              lumen::lsp::transport::congestion_feedback_floor_microseconds)) ||
          (microphone_has_feedback_timestamp_ &&
           static_cast<std::int32_t>(feedback.report_timestamp - microphone_last_feedback_timestamp_) <= 0)) {
        return false;
      }

      if (input_block != nullptr) {
        std::uint64_t first_extended_sequence = 0;
        for (std::size_t index = 0; index < input_block->report_count; ++index) {
          const auto sequence = static_cast<std::uint16_t>(input_block->begin_sequence + index);
          const auto &record = input_sent_packets_[sequence];
          const auto metric = lumen::lsp::wire::read_be<std::uint16_t>(
            input_block->metrics.subspan(index * 2U, 2U)
          );
          const auto received = (metric & 0x8000U) != 0;
          if (!record.occupied || record.input_generation != input_configuration_.input_generation ||
              static_cast<std::uint16_t>(record.extended_sequence) != sequence ||
              record.terminal_microseconds > now ||
              now - record.terminal_microseconds > input_feedback_freshness_microseconds ||
              (record.state == InputFeedbackState::local_unsent && received) ||
              (record.state != InputFeedbackState::local_unsent && record.complete_ip_bytes == 0) ||
              (!received && record.state == InputFeedbackState::received)) {
            return false;
          }
          if (index == 0) {
            first_extended_sequence = record.extended_sequence;
          } else if (record.extended_sequence != first_extended_sequence + index) {
            return false;
          }
          if (received) {
            const auto ato = static_cast<std::uint16_t>(metric & 0x1fffU);
            if (ato <= 0x1ffdU && record.arrival_timestamp_valid) {
              const auto arrival = feedback.report_timestamp - static_cast<std::uint32_t>(ato) * 64U;
              const auto difference = static_cast<std::int32_t>(arrival - record.arrival_timestamp);
              if (difference < -64 || difference > 64) {
                return false;
              }
            }
          }
        }
      }
      if (microphone_block != nullptr) {
        std::uint64_t first_extended_sequence = 0;
        for (std::size_t index = 0; index < microphone_block->report_count; ++index) {
          const auto sequence = static_cast<std::uint16_t>(microphone_block->begin_sequence + index);
          const auto &record = microphone_sent_packets_[sequence % microphone_sent_packets_.size()];
          const auto metric = lumen::lsp::wire::read_be<std::uint16_t>(
            microphone_block->metrics.subspan(index * 2U, 2U)
          );
          const auto received = (metric & 0x8000U) != 0;
          if (!record.occupied || record.microphone_generation != microphone_configuration_.microphone_generation ||
              static_cast<std::uint16_t>(record.extended_sequence) != sequence || record.complete_ip_bytes == 0 ||
              record.sent_microseconds > now ||
              now - record.sent_microseconds > microphone_feedback_freshness_microseconds ||
              (!received && record.state == MicrophoneFeedbackState::received)) {
            return false;
          }
          if (index == 0) {
            first_extended_sequence = record.extended_sequence;
          } else if (record.extended_sequence != first_extended_sequence + index) {
            return false;
          }
          if (received) {
            const auto ato = static_cast<std::uint16_t>(metric & 0x1fffU);
            if (ato <= 0x1ffdU && record.arrival_timestamp_valid) {
              const auto arrival = feedback.report_timestamp - static_cast<std::uint32_t>(ato) * 64U;
              const auto difference = static_cast<std::int32_t>(arrival - record.arrival_timestamp);
              if (difference < -64 || difference > 64) {
                return false;
              }
            }
          }
        }
      }

      std::uint64_t delivered_bytes = 0;
      std::uint64_t lost_bytes = 0;
      std::uint64_t ecn_ce_bytes = 0;
      std::int32_t queue_delay_trend = 0;
      bool input_delay_observed = false;
      if (input_block != nullptr) {
        for (std::size_t index = 0; index < input_block->report_count; ++index) {
          const auto sequence = static_cast<std::uint16_t>(input_block->begin_sequence + index);
          auto &record = input_sent_packets_[sequence];
          const auto metric = lumen::lsp::wire::read_be<std::uint16_t>(
            input_block->metrics.subspan(index * 2U, 2U)
          );
          const auto received = (metric & 0x8000U) != 0;
          const auto ecn = static_cast<std::uint8_t>((metric >> 13U) & 0x03U);
          if (record.state == InputFeedbackState::local_unsent) {
            continue;
          }
          if (received) {
            const auto newly_received = record.state != InputFeedbackState::received;
            if (record.state == InputFeedbackState::unreported) {
              input_bytes_in_flight_ = input_bytes_in_flight_ > record.complete_ip_bytes ?
                                         input_bytes_in_flight_ - record.complete_ip_bytes : 0;
            } else if (record.state == InputFeedbackState::lost) {
              input_lost_bytes_ = input_lost_bytes_ > record.complete_ip_bytes ?
                                    input_lost_bytes_ - record.complete_ip_bytes : 0;
            }
            if (newly_received) {
              record.state = InputFeedbackState::received;
              delivered_bytes = saturating_rate_add(delivered_bytes, record.complete_ip_bytes);
              input_delivered_bytes_ = saturating_rate_add(input_delivered_bytes_, record.complete_ip_bytes);
            }
            if (ecn == 3U && record.ecn != 3U) {
              record.ecn = 3U;
              ecn_ce_bytes = saturating_rate_add(ecn_ce_bytes, record.complete_ip_bytes);
              input_ecn_ce_bytes_ = saturating_rate_add(input_ecn_ce_bytes_, record.complete_ip_bytes);
            }
            const auto ato = static_cast<std::uint16_t>(metric & 0x1fffU);
            if (ato <= 0x1ffdU) {
              const auto arrival = feedback.report_timestamp - static_cast<std::uint32_t>(ato) * 64U;
              record.arrival_timestamp = arrival;
              record.arrival_timestamp_valid = true;
              if (newly_received &&
                  (!input_has_delay_sample_ ||
                   record.terminal_microseconds > input_last_delay_send_microseconds_)) {
                if (input_has_delay_sample_) {
                  const auto arrival_ticks = static_cast<std::int32_t>(
                    arrival - input_last_delay_arrival_timestamp_
                  );
                  if (arrival_ticks >= 0) {
                    const auto arrival_delta =
                      static_cast<std::int64_t>(arrival_ticks) * 1'000'000LL / 65'536LL;
                    const auto send_delta = static_cast<std::int64_t>(
                      record.terminal_microseconds - input_last_delay_send_microseconds_
                    );
                    queue_delay_trend = static_cast<std::int32_t>(std::clamp<std::int64_t>(
                      arrival_delta - send_delta,
                      std::numeric_limits<std::int32_t>::min(),
                      std::numeric_limits<std::int32_t>::max()
                    ));
                  }
                }
                input_last_delay_arrival_timestamp_ = arrival;
                input_last_delay_send_microseconds_ = record.terminal_microseconds;
                input_has_delay_sample_ = true;
                input_delay_observed = true;
              }
            }
          } else if (record.state == InputFeedbackState::unreported) {
            record.state = InputFeedbackState::lost;
            lost_bytes = saturating_rate_add(lost_bytes, record.complete_ip_bytes);
            input_lost_bytes_ = saturating_rate_add(input_lost_bytes_, record.complete_ip_bytes);
            input_bytes_in_flight_ = input_bytes_in_flight_ > record.complete_ip_bytes ?
                                       input_bytes_in_flight_ - record.complete_ip_bytes : 0;
          }
        }
      }
      if (microphone_block != nullptr) {
      for (std::size_t index = 0; index < microphone_block->report_count; ++index) {
        const auto sequence = static_cast<std::uint16_t>(microphone_block->begin_sequence + index);
        auto &record = microphone_sent_packets_[sequence % microphone_sent_packets_.size()];
        const auto metric = lumen::lsp::wire::read_be<std::uint16_t>(
          microphone_block->metrics.subspan(index * 2U, 2U)
        );
        const auto received = (metric & 0x8000U) != 0;
        const auto ecn = static_cast<std::uint8_t>((metric >> 13U) & 0x03U);
        if (received) {
          const auto newly_received = record.state != MicrophoneFeedbackState::received;
          if (record.state == MicrophoneFeedbackState::unreported) {
            microphone_bytes_in_flight_ = microphone_bytes_in_flight_ > record.complete_ip_bytes ?
                                            microphone_bytes_in_flight_ - record.complete_ip_bytes : 0;
          } else if (record.state == MicrophoneFeedbackState::lost) {
            microphone_lost_bytes_ = microphone_lost_bytes_ > record.complete_ip_bytes ?
                                       microphone_lost_bytes_ - record.complete_ip_bytes : 0;
          }
          if (newly_received) {
            record.state = MicrophoneFeedbackState::received;
            delivered_bytes = saturating_rate_add(delivered_bytes, record.complete_ip_bytes);
            microphone_delivered_bytes_ = saturating_rate_add(
              microphone_delivered_bytes_,
              record.complete_ip_bytes
            );
          }
          if (ecn == 3U && record.ecn != 3U) {
            record.ecn = 3U;
            ecn_ce_bytes = saturating_rate_add(ecn_ce_bytes, record.complete_ip_bytes);
            microphone_ecn_ce_bytes_ = saturating_rate_add(
              microphone_ecn_ce_bytes_,
              record.complete_ip_bytes
            );
          }
          const auto ato = static_cast<std::uint16_t>(metric & 0x1fffU);
          if (ato <= 0x1ffdU) {
            const auto arrival = feedback.report_timestamp - static_cast<std::uint32_t>(ato) * 64U;
            record.arrival_timestamp = arrival;
            record.arrival_timestamp_valid = true;
            if (newly_received &&
                (!microphone_has_delay_sample_ ||
                 record.sent_microseconds > microphone_last_delay_send_microseconds_)) {
              if (microphone_has_delay_sample_) {
                const auto arrival_ticks = static_cast<std::int32_t>(
                  arrival - microphone_last_delay_arrival_timestamp_
                );
                if (arrival_ticks >= 0) {
                  const auto arrival_delta = static_cast<std::int64_t>(arrival_ticks) * 1'000'000LL / 65'536LL;
                  const auto send_delta = static_cast<std::int64_t>(
                    record.sent_microseconds - microphone_last_delay_send_microseconds_
                  );
                  if (!input_delay_observed) {
                    queue_delay_trend = static_cast<std::int32_t>(std::clamp<std::int64_t>(
                      arrival_delta - send_delta,
                      std::numeric_limits<std::int32_t>::min(),
                      std::numeric_limits<std::int32_t>::max()
                    ));
                  }
                }
              }
              microphone_last_delay_arrival_timestamp_ = arrival;
              microphone_last_delay_send_microseconds_ = record.sent_microseconds;
              microphone_has_delay_sample_ = true;
            }
          }
        } else if (record.state == MicrophoneFeedbackState::unreported) {
          record.state = MicrophoneFeedbackState::lost;
          lost_bytes = saturating_rate_add(lost_bytes, record.complete_ip_bytes);
          microphone_lost_bytes_ = saturating_rate_add(microphone_lost_bytes_, record.complete_ip_bytes);
          microphone_bytes_in_flight_ = microphone_bytes_in_flight_ > record.complete_ip_bytes ?
                                          microphone_bytes_in_flight_ - record.complete_ip_bytes : 0;
        }
      }
      }
      microphone_last_feedback_timestamp_ = feedback.report_timestamp;
      microphone_last_feedback_microseconds_ = now;
      microphone_has_feedback_timestamp_ = true;

      if (delivered_bytes == 0 && lost_bytes == 0 && ecn_ce_bytes == 0) {
        return true;
      }
      if ((!microphone_congestion_ || reverse_controller_includes_microphone_ != microphone_active) &&
          !reset_reverse_congestion_controller()) {
        realtime_failure_status_ = CLSP_STATUS_INVALID_CONFIGURATION;
        return false;
      }
      microphone_congestion_->apply_feedback({
        .delivered_bytes = delivered_bytes,
        .lost_bytes = lost_bytes,
        .ecn_ce_bytes = ecn_ce_bytes,
        .bytes_in_flight = saturating_rate_add(input_bytes_in_flight_, microphone_bytes_in_flight_),
        .smoothed_rtt_microseconds = microphone_smoothed_rtt_microseconds_,
        .rtt_variation_microseconds = microphone_rtt_variation_microseconds_,
        .queue_delay_trend_microseconds = queue_delay_trend,
      });
      const auto snapshot = microphone_congestion_->snapshot();
      const auto input_rate = input_configuration_.reserved_input_wire_bits_per_second;
      if (snapshot.pacing_bits_per_second < input_rate) {
        realtime_failure_status_ = CLSP_STATUS_RESOURCE_EXHAUSTED;
        return false;
      }
      reverse_congestion_rate_bits_per_second_ = snapshot.pacing_bits_per_second;
      microphone_congestion_rate_bits_per_second_ = microphone_active ?
        snapshot.pacing_bits_per_second - input_rate : 0U;
      if (microphone_active) {
        if (microphone_congestion_rate_bits_per_second_ <
            microphone_minimum_wire_rate(microphone_configuration_)) {
          realtime_failure_status_ = CLSP_STATUS_RESOURCE_EXHAUSTED;
          return false;
        }
        microphone_tokens_bits_ = std::min(
          microphone_tokens_bits_,
          microphone_credit_capacity(microphone_configuration_, microphone_congestion_rate_bits_per_second_)
        );
      }
      const auto reverse_capacity = std::max<std::uint64_t>(
        input_rate / 500U + microphone_congestion_rate_bits_per_second_ / 25U,
        2U * static_cast<std::uint64_t>(maximum_udp_payload + ip_udp_overhead_bytes()) * 8U
      );
      reverse_tokens_bits_ = std::min(reverse_tokens_bits_, reverse_capacity);
      if (snapshot.minimum_unsustainable) {
        microphone_minimum_failure_count_ = static_cast<std::uint8_t>(std::min<unsigned>(
          microphone_minimum_failure_intervals,
          static_cast<unsigned>(microphone_minimum_failure_count_) + 1U
        ));
        if (microphone_minimum_failure_count_ == microphone_minimum_failure_intervals) {
          realtime_failure_status_ = CLSP_STATUS_RESOURCE_EXHAUSTED;
          return false;
        }
      } else {
        microphone_minimum_failure_count_ = 0;
      }
      return true;
    }

    /** @brief Parse authenticated SRTCP LSPI and retire baseline/edge state. */
    [[nodiscard]] bool handle_authenticated_realtime(
      const std::span<const std::uint8_t> packet,
      const bool rtcp,
      const std::uint64_t arrival_microseconds,
      const std::uint64_t authenticated_microseconds,
      const std::uint64_t packet_token
    ) noexcept {
      if (packet.size() < 12U || (packet[0] >> 6U) != 2U) {
        return false;
      }
      if (!rtcp) {
        const auto rtp = lumen::lsp::parse_rtp_fixed_header(packet);
        if (!rtp) {
          return false;
        }
        const auto video_lane = video_lane_for_ssrc(rtp.header.ssrc);
        const auto now = authenticated_microseconds;
        if (video_lane == VideoRtpLane::primary) {
          return handle_authenticated_video(
                   packet,
                   now,
                   VideoSourceOrigin::primary_srtp,
                   nullptr,
                   packet_token
                 ) &&
                 attempt_pending_flexfec_repairs(now);
        }
        if (video_lane == VideoRtpLane::flexfec) {
          return handle_authenticated_flexfec(packet, now, packet_token);
        }
        if (video_lane == VideoRtpLane::rtx) {
          return handle_authenticated_rtx(packet, now);
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
        record_timing_stage(
          CLSP_NATIVE_TIMING_AUTH_TO_HANDOFF,
          authenticated_microseconds,
          monotonic_microseconds()
        );
        callbacks_.audio_packet(callbacks_.context, event);
        return true;
      }
      if (packet[1] == lumen::lsp::transport::rtcp_receiver_report_type) {
        return handle_reverse_receiver_report(packet, authenticated_microseconds);
      }
      if (packet[1] == lumen::lsp::transport::rtcp_transport_feedback_type &&
          (packet[0] & 0x1fU) == lumen::lsp::transport::rtcp_congestion_feedback_format) {
        return handle_reverse_congestion_feedback(packet, authenticated_microseconds);
      }
      if (packet[1] == 200U) {
        const auto first_sender_ssrc = packet.size() >= 8U ?
                                         lumen::lsp::wire::read_be<std::uint32_t>(packet.subspan(4, 4)) : 0U;
        const auto authority = lumen::lsp::transport::validate_compound_rtcp_authority(
          packet,
          first_sender_ssrc
        );
        if (!authority || authority.first_report.packet_type != lumen::lsp::transport::rtcp_sender_report_type ||
            authority.first_report.payload.size() < 24U) {
          return false;
        }
        const auto sender_ssrc = lumen::lsp::wire::read_be<std::uint32_t>(
          authority.first_report.payload.first<4>()
        );
        const auto video_lane = video_lane_for_ssrc(sender_ssrc);
        if (video_lane != VideoRtpLane::none) {
          const auto seconds = lumen::lsp::wire::read_be<std::uint32_t>(
            authority.first_report.payload.subspan<4, 4>()
          );
          const auto fraction = lumen::lsp::wire::read_be<std::uint32_t>(
            authority.first_report.payload.subspan<8, 4>()
          );
          auto *reception = video_lane == VideoRtpLane::primary ? &video_reception_ :
                            (video_lane == VideoRtpLane::flexfec ? &flexfec_reception_ : &rtx_reception_);
          reception->note_sender_report((seconds << 16U) | (fraction >> 16U), arrival_microseconds);
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
        const auto seconds = lumen::lsp::wire::read_be<std::uint32_t>(
          authority.first_report.payload.subspan<4, 4>()
        );
        const auto fraction = lumen::lsp::wire::read_be<std::uint32_t>(
          authority.first_report.payload.subspan<8, 4>()
        );
        audio_reception_.note_sender_report((seconds << 16U) | (fraction >> 16U), arrival_microseconds);
        const clsp_audio_timing_event_t timing {
          .abi_version = CLSP_CORE_ABI_VERSION,
          .structure_size = sizeof(clsp_audio_timing_event_t),
          .audio_generation = audio.audio_generation,
          .ssrc = audio.audio_ssrc,
          .ntp_seconds = lumen::lsp::wire::read_be<std::uint32_t>(
            authority.first_report.payload.subspan<4, 4>()
          ),
          .ntp_fraction = lumen::lsp::wire::read_be<std::uint32_t>(
            authority.first_report.payload.subspan<8, 4>()
          ),
          .rtp_timestamp = lumen::lsp::wire::read_be<std::uint32_t>(
            authority.first_report.payload.subspan<12, 4>()
          ),
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
      const auto baseline_became_acknowledged =
        !baseline_acknowledged_ && ack.value.accepted_baseline_id == baseline_id_;
      if (baseline_became_acknowledged) {
        baseline_acknowledged_ = true;
        if (baseline_first_submitted_microseconds_ != 0U) {
          record_timing_stage(
            CLSP_NATIVE_TIMING_INPUT_ACK_AGE,
            baseline_first_submitted_microseconds_,
            monotonic_microseconds()
          );
          baseline_first_submitted_microseconds_ = 0U;
        }
        if (callbacks_.input_baseline != nullptr) {
          callbacks_.input_baseline(
            callbacks_.context,
            true,
            connection_generation_,
            input_configuration_.input_generation,
            baseline_id_
          );
        }
      }
      const auto acknowledged_microseconds = monotonic_microseconds();
      for (auto &timing : edge_timing_) {
        if (!timing.occupied) continue;
        auto acknowledged = timing.edge_id <= ack.value.contiguous_edge_id;
        if (!acknowledged && timing.edge_id > ack.value.contiguous_edge_id) {
          const auto distance = timing.edge_id - ack.value.contiguous_edge_id;
          acknowledged = distance <= 64U &&
                         (ack.value.edge_reception_bitmap & (std::uint64_t {1} << (distance - 1U))) != 0U;
        }
        if (!acknowledged) continue;
        if (timing.first_submitted_microseconds == 0U) {
          timing_distributions_[CLSP_NATIVE_TIMING_INPUT_ACK_AGE].drop();
        } else {
          record_timing_stage(
            CLSP_NATIVE_TIMING_INPUT_ACK_AGE,
            timing.first_submitted_microseconds,
            acknowledged_microseconds
          );
        }
        timing = {};
      }
      edge_sender_.acknowledge(ack.value.contiguous_edge_id, ack.value.edge_reception_bitmap);
      if ((ack.value.flags & static_cast<std::uint8_t>(lumen::lsp::input_plane::lspi_flag::baseline_requested)) != 0) {
        baseline_acknowledged_ = false;
        baseline_last_sent_us_ = 0;
        baseline_body_length_ = 0;
        baseline_edge_watermark_ = 0;
        baseline_first_submitted_microseconds_ = 0U;
        baseline_id_ = (static_cast<std::uint64_t>(arc4random()) << 32U) | arc4random();
        if (baseline_id_ == 0U) baseline_id_ = 1U;
      }
      pthread_mutex_lock(&mutex_);
      input_feedback_snapshot_.accepted_baseline_id = ack.value.accepted_baseline_id;
      input_feedback_snapshot_.contiguous_edge_id = ack.value.contiguous_edge_id;
      input_feedback_snapshot_.edge_reception_bitmap = ack.value.edge_reception_bitmap;
      input_feedback_snapshot_.received_at_microseconds = arrival_microseconds;
      input_feedback_snapshot_.baseline_acknowledged = static_cast<std::uint8_t>(baseline_acknowledged_);
      input_feedback_snapshot_.baseline_requested = static_cast<std::uint8_t>(
        (ack.value.flags & static_cast<std::uint8_t>(lumen::lsp::input_plane::lspi_flag::baseline_requested)) != 0
      );
      pthread_mutex_unlock(&mutex_);
      return true;
    }

    /** @brief Retry one exact protected controller ACK across immediate socket backpressure. */
    [[nodiscard]] clsp_status_t transmit_pending_controller_ack() noexcept {
      if (!pending_controller_ack_.occupied) {
        return CLSP_STATUS_OK;
      }
      const auto sent = ::send(socket_, pending_controller_ack_.bytes.data(), pending_controller_ack_.length, 0);
      if (sent == static_cast<ssize_t>(pending_controller_ack_.length)) {
        pending_controller_ack_ = {};
        increment(RuntimeCounter::transmitted);
        return CLSP_STATUS_OK;
      }
      if (sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == ENOBUFS)) {
        return CLSP_STATUS_OK;
      }
      return CLSP_STATUS_SOCKET_FAILURE;
    }

    /** @brief Protect and retain one terminal client-to-host LSPG command ACK. */
    [[nodiscard]] clsp_status_t send_controller_ack(
      const lumen::lsp::input_plane::parsed_lspg &command,
      const lumen::lsp::input_plane::controller_command_status status
    ) noexcept {
      if (!lumen::lsp::input_plane::valid_controller_command_status(status)) {
        return CLSP_STATUS_INTERNAL_FAILURE;
      }
      const auto pending_status = transmit_pending_controller_ack();
      if (pending_status != CLSP_STATUS_OK) {
        return pending_status;
      }
      if (pending_controller_ack_.occupied) {
        return CLSP_STATUS_RESOURCE_EXHAUSTED;
      }
      auto &packet = pending_controller_ack_.bytes;
      std::fill(packet.begin(), packet.end(), 0);
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
      pending_controller_ack_.length = length;
      pending_controller_ack_.occupied = true;
      return transmit_pending_controller_ack();
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
      if (path_intent_message_id_ != 0 && acknowledges_message(
                                            parsed.header.acknowledgement_base,
                                            parsed.header.acknowledgement_bitmap,
                                            path_intent_message_id_
                                          )) {
        const auto probe_status = prepare_outbound_path_probe(path_intent_probe_id_, path_intent_probe_size_);
        if (probe_status != CLSP_STATUS_OK) {
          return false;
        }
        path_intent_message_id_ = 0;
        path_intent_request_id_ = 0;
        path_intent_probe_id_ = 0;
        path_intent_probe_size_ = 0;
        path_intent_control_ = {};
      }
      const auto control_now = monotonic_microseconds();
      (void)outbound_window_.acknowledge(
        parsed.header.acknowledgement_base,
        parsed.header.acknowledgement_bitmap,
        control_now,
        rto_
      );
      const auto observed = receive_window_.observe(parsed.header.message_id);
      if (observed == lumen::lsp::receive_id_result::too_far_ahead ||
          observed == lumen::lsp::receive_id_result::too_old ||
          observed == lumen::lsp::receive_id_result::zero) {
        increment(RuntimeCounter::dropped);
        return false;
      }
      if (observed == lumen::lsp::receive_id_result::accepted) {
        note_authenticated_inbound(control_now);
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
      const auto semantic_identity = semantic_request ? response_identity(parsed.header, plaintext) : std::nullopt;
      if (semantic_request && !semantic_identity) return false;
      if (observed == lumen::lsp::receive_id_result::duplicate) {
        if (semantic_request) {
          const auto cached = inbound_response_cache_.lookup(
            parsed.header.request_id,
            *semantic_identity,
            plaintext,
            control_now
          );
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
      if (semantic_request && !retain_inbound_request(parsed.header.request_id, *semantic_identity, plaintext)) return false;
      if (parsed.header.message_type == 0x0002U && parsed.header.connection_generation != 0) {
        connection_generation_ = parsed.header.connection_generation;
        authenticated_connection_generation_.store(connection_generation_, std::memory_order_release);
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
          const auto now = monotonic_microseconds();
          const auto cached = inbound_response_cache_.insert(
            command.request_id,
            {
              .identity = pending_request->identity,
              .retention_deadline_microseconds = saturating_add(now, 120'000'000U),
            },
            pending_request->frame.bytes(),
            encoded,
            now
          );
          if (cached != lumen::lsp::response_cache_result::stored && cached != lumen::lsp::response_cache_result::hit) {
            return CLSP_STATUS_INTERNAL_FAILURE;
          }
        }
        if (!command.transmit_path_probe) {
          const auto reserved = outbound_window_.reserve(message_id, encoded, command.deadline_microseconds);
          if (reserved != lumen::lsp::outbound_store_result::stored) {
            return reserved == lumen::lsp::outbound_store_result::window_full ?
                     CLSP_STATUS_CONTROL_WINDOW_FULL : CLSP_STATUS_INTERNAL_FAILURE;
          }
        }
        const auto status = dtls_.send_application_data(encoded);
        if (status != CLSP_STATUS_OK) {
          return status;
        }
        const auto submitted_at = monotonic_microseconds();
        increment(RuntimeCounter::transmitted);
        if (command.transmit_path_probe) {
          if (path_intent_control_.occupied) {
            return CLSP_STATUS_INVALID_STATE;
          }
          const auto now = monotonic_microseconds();
          path_intent_control_.frame.assign(encoded);
          path_intent_control_.message_id = message_id;
          path_intent_control_.deadline_microseconds = command.deadline_microseconds;
          path_intent_control_.next_retry_microseconds = saturating_add(now, rto_.timeout_for_attempt(1));
          path_intent_control_.transmissions = 1;
          path_intent_control_.occupied = true;
          path_intent_message_id_ = message_id;
          path_intent_request_id_ = command.request_id;
          path_intent_probe_id_ = command.path_probe_id;
          path_intent_probe_size_ = command.path_probe_size;
          path_probe_notification_pending_ = false;
        } else if (outbound_window_.mark_initial_submitted(message_id, submitted_at, rto_) !=
                   lumen::lsp::outbound_submission_result::submitted) {
          return CLSP_STATUS_INTERNAL_FAILURE;
        }
        if (pending_request != nullptr) {
          pending_request->occupied = false;
          pending_request->frame.clear();
        }
        if (command.activate_microphone) {
          if (!microphone_prepared_.load(std::memory_order_acquire)) return CLSP_STATUS_INVALID_STATE;
          if (!reset_reverse_congestion_controller(true)) return CLSP_STATUS_INVALID_CONFIGURATION;
          const auto now = monotonic_microseconds();
          microphone_last_credit_us_ = now;
          microphone_tokens_bits_ = microphone_credit_capacity(
            microphone_configuration_,
            microphone_congestion_rate_bits_per_second_
          );
          reverse_last_credit_us_ = now;
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
      if (path_intent_control_.occupied) {
        if (path_intent_control_.transmissions >= 5U || now >= path_intent_control_.deadline_microseconds) {
          if (path_intent_request_id_ != 0) {
            if (!queue_path_probe_event(
                  CLSP_PATH_PROBE_REQUEST_FAILED,
                  path_intent_probe_id_,
                  path_intent_probe_size_,
                  path_intent_request_id_
                )) {
              return CLSP_STATUS_OK;
            }
          }
          path_intent_control_ = {};
          path_intent_message_id_ = 0;
          path_intent_request_id_ = 0;
          path_intent_probe_id_ = 0;
          path_intent_probe_size_ = 0;
          path_probe_notification_pending_ = true;
          path_probe_notification_microseconds_ = 0;
        } else if (now >= path_intent_control_.next_retry_microseconds) {
          const auto status = dtls_.send_application_data(path_intent_control_.frame.bytes());
          if (status != CLSP_STATUS_OK) {
            return status;
          }
          increment(RuntimeCounter::transmitted);
          ++path_intent_control_.transmissions;
          path_intent_control_.next_retry_microseconds = saturating_add(
            now,
            rto_.timeout_for_attempt(path_intent_control_.transmissions)
          );
        }
      }
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
    void fail_worker(const clsp_status_t status, const char *stage = nullptr) noexcept {
      if (stage != nullptr) {
        std::fprintf(stderr, "LSP transport failed during %s (status=%u).\n", stage, static_cast<unsigned int>(status));
      }
      clear_deferred_video_batch();
      capture_accepting_.store(false, std::memory_order_release);
      capture_read_.store(capture_write_.load(std::memory_order_acquire), std::memory_order_release);
      last_authenticated_inbound_microseconds_.store(0U, std::memory_order_release);
      flush_telemetry(monotonic_microseconds(), true);
      signal_startup(status);
      terminal_failed_.store(true, std::memory_order_release);
      authenticated_.store(false, std::memory_order_release);
      stop_requested_.store(true, std::memory_order_release);
      publish_lifecycle(CLSP_LIFECYCLE_FAILED, latch_terminal_status(status));
    }

    /** @brief Record one newly admitted authenticated peer packet for active-stream liveness. */
    void note_authenticated_inbound(const std::uint64_t now) noexcept {
      if (now != 0U && video_delivery_active_.load(std::memory_order_acquire)) {
        last_authenticated_inbound_microseconds_.store(now, std::memory_order_release);
      }
    }

    /** @brief Return whether an active stream missed three authenticated report intervals. */
    [[nodiscard]] bool active_stream_peer_timed_out(const std::uint64_t now) const noexcept {
      if (!video_delivery_active_.load(std::memory_order_acquire)) {
        return false;
      }
      const auto last = last_authenticated_inbound_microseconds_.load(std::memory_order_acquire);
      return last != 0U && now >= last && now - last >= active_stream_peer_silence_timeout_microseconds;
    }

    /** @brief Attribute one bounded ring failure to its exact native device generation. */
    void record_capture_drop(const CaptureRecord &record) noexcept {
      if (record.kind == CaptureKind::pointer || record.kind == CaptureKind::edge) {
        const auto pointer_edge = record.kind == CaptureKind::pointer ||
                                  record.edge.kind == CLSP_INPUT_EDGE_POINTER_BUTTON_DOWN ||
                                  record.edge.kind == CLSP_INPUT_EDGE_POINTER_BUTTON_UP;
        if (pointer_edge && record.device_generation != 0U &&
            pointer_drop_generation_.load(std::memory_order_acquire) == record.device_generation) {
          pointer_dropped_samples_.fetch_add(1U, std::memory_order_relaxed);
        }
        return;
      }
      std::uint32_t controller_id = 0U;
      std::uint32_t generation = 0U;
      switch (record.kind) {
        case CaptureKind::controller_edge:
          controller_id = record.controller_edge.controller_id;
          generation = record.controller_edge.instance_generation;
          break;
        case CaptureKind::controller_state:
          controller_id = record.controller_state.controller_id;
          generation = record.controller_state.instance_generation;
          break;
        case CaptureKind::controller_sensor:
          controller_id = record.controller_sensor.controller_id;
          generation = record.controller_sensor.instance_generation;
          break;
        case CaptureKind::touch_edge:
          controller_id = record.touch_edge.controller_id;
          generation = record.touch_edge.instance_generation;
          break;
        case CaptureKind::touch_state:
          controller_id = record.touch_state.controller_id;
          generation = record.touch_state.instance_generation;
          break;
        case CaptureKind::pointer:
        case CaptureKind::edge:
        case CaptureKind::neutralize:
          return;
      }
      if (controller_id >= 1U && controller_id <= 16U) {
        const auto index = controller_id - 1U;
        if (controller_drop_generations_[index].load(std::memory_order_acquire) == generation) {
          controller_dropped_samples_[index].fetch_add(1U, std::memory_order_relaxed);
        }
      }
    }

    /** @brief Copy one capture record into the bounded native ring. */
    [[nodiscard]] clsp_status_t enqueue_capture(const CaptureRecord &record) noexcept {
      const auto write = capture_write_.load(std::memory_order_relaxed);
      const auto next = (write + 1U) % capture_queue_capacity;
      if (next == capture_read_.load(std::memory_order_acquire)) {
        producer_dropped_.fetch_add(1U, std::memory_order_relaxed);
        producer_callback_timing_drops_.fetch_add(1U, std::memory_order_relaxed);
        record_capture_drop(record);
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
      authenticated_connection_generation_.store(0U, std::memory_order_release);
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
    int socket_family_ {};  ///< Active address family for ECN and complete IP accounting.
    bool mutex_ready_ {};  ///< Mutex initialization state.
    bool condition_ready_ {};  ///< Condition initialization state.
    bool worker_started_ {};  ///< Join ownership state.
    bool startup_complete_ {};  ///< Whether startup status is terminal.
    clsp_status_t startup_status_ {CLSP_STATUS_TIMEOUT};  ///< Terminal startup result.
#endif

    clsp_configuration_t configuration_ {};  ///< Copied immutable core configuration.
    RuntimeCallbacks callbacks_ {};  ///< Stable C ABI owner callbacks.
    mutable std::array<std::uint64_t, 12> worker_counters_ {};  ///< Socket-worker telemetry deltas.
    std::array<FixedTelemetryDistribution, CLSP_NATIVE_TIMING_STAGE_COUNT>
      timing_distributions_ {};  ///< Worker-owned cumulative native stage histograms.
    std::array<EdgeTimingSlot, lumen::lsp::input_plane::edge_sender::capacity>
      edge_timing_ {};  ///< Exact edge-to-ACK correlations.
    std::atomic<std::uint64_t> producer_dropped_ {0};  ///< Producer-side bounded drops drained by worker.
    std::atomic<std::uint64_t> producer_callback_timing_drops_ {0};  ///< Ring drops without compose timestamps.
    std::uint64_t last_telemetry_flush_microseconds_ {};  ///< Last <=4 Hz counter publication.
    std::uint64_t timing_snapshot_generation_ {};  ///< Monotonic coarse timing publication identity.
    std::uint64_t last_timing_publication_microseconds_ {};  ///< Hard four-hertz publication floor.
    clsp_status_t realtime_failure_status_ {CLSP_STATUS_OK};  ///< Fatal authenticated parser result bubbled to the worker.
    WolfSSLDtlsClient dtls_;  ///< Exact-policy DTLS client.
    SrtpSession srtp_;  ///< Directional AEAD AES-128-GCM contexts.
    lumen::lsp::selective_ack_window receive_window_;  ///< Peer logical-frame receive/ACK state.
    lumen::lsp::outbound_control_window<maximum_control_frame> outbound_window_;  ///< Byte-identical retry state.
    lumen::lsp::response_cache<maximum_control_frame, maximum_control_frame> inbound_response_cache_;  ///< Host request response replay.
    lumen::lsp::control_rto rto_;  ///< Local-path bounded RTO estimator.
    std::array<ControlCommand, control_queue_capacity> control_queue_ {};  ///< Pre-wire bounded queue.
    ControlReservation control_reservation_ {};  ///< Sole invisible atomic-handoff queue reservation.
    std::array<PendingInboundRequest, 64> pending_inbound_requests_ {};  ///< Authenticated requests awaiting semantic response.
    std::array<CaptureRecord, capture_queue_capacity> capture_queue_ {};  ///< Allocation-free captured-input ring.
    clsp_input_configuration_t pending_input_configuration_ {};  ///< Producer-copied pending input mapping.
    clsp_input_configuration_t input_configuration_ {};  ///< Worker-owned active input mapping.
    clsp_input_rate_update_t pending_input_rates_ {};  ///< Producer-copied authenticated rate renegotiation.
    clsp_input_feedback_snapshot_t input_feedback_snapshot_ {};  ///< Latest coarse LSPI/effective-rate evidence.
    lumen::lsp::input_plane::pointer_composer pointer_composer_;  ///< Cumulative relative pointer state.
    lumen::lsp::input_plane::edge_sender edge_sender_;  ///< Exactly-once retained edge window.
    std::array<ControllerLatest, 16> controller_states_ {};  ///< Latest analog state by controller slot.
    std::array<std::array<ControllerSensorLatest, 2>, 16> controller_sensors_ {};  ///< Latest gyro/accel states.
    std::array<TouchLatest, 16> touch_states_ {};  ///< Latest controller touch contacts.
    std::atomic<bool> stop_requested_ {false};  ///< Cross-thread idempotent stop request.
    std::atomic<bool> terminal_failed_ {false};  ///< Preserve FAILED while reclaiming a failed runtime.
    std::atomic<std::uint32_t> terminal_status_ {CLSP_STATUS_OK};  ///< First fatal runtime status.
    std::atomic<bool> authenticated_ {false};  ///< Product-visible exact-security readiness.
    std::atomic<bool> audio_configured_ {false};  ///< Exact host-audio mapping admission gate.
    std::atomic<bool> video_configured_ {false};  ///< Exact primary-video mapping admission gate.
    std::atomic<bool> video_delivery_active_ {false};  ///< ACK-gated complete-frame publication.
    std::atomic<std::uint64_t> last_authenticated_inbound_microseconds_ {0};  ///< Active-stream peer watchdog evidence.
    std::atomic<bool> path_discovery_enabled_ {false};  ///< Native PMTU search activation.
    std::atomic<std::uint32_t> published_stream_generation_ {0};  ///< Coarse current stream generation.
    std::atomic<std::uint32_t> published_input_generation_ {0};  ///< Coarse current input generation.
    std::atomic<std::uint64_t> published_latest_edge_id_ {0};  ///< Coarse newest assigned edge ID.
    std::atomic<std::uint64_t> published_latest_edge_time_ {0};  ///< Coarse newest edge capture time.
    std::atomic<std::uint16_t> current_udp_payload_size_ {1'200};  ///< Authenticated confirmed ceiling.
    std::atomic<std::uint16_t> receive_udp_payload_size_ {1'200};  ///< Independently confirmed host-to-client ceiling.
    std::atomic<std::uint32_t> authenticated_connection_generation_ {0};  ///< Published SERVER_HELLO generation.
    std::atomic<std::uint64_t> emitted_path_probe_id_ {0};  ///< Native probe offered to Swift.
    std::atomic<std::uint16_t> emitted_path_probe_size_ {0};  ///< Offered protected payload size.
    std::atomic<std::uint64_t> pending_path_ack_id_ {0};  ///< Swift-confirmed ACK awaiting worker commit.
    std::atomic<std::uint16_t> pending_path_ack_size_ {0};  ///< ACK payload size paired with pending ID.
    clsp_audio_configuration_t audio_configuration_ {};  ///< Installed audio generation/SSRC/PT tuple.
    clsp_video_configuration_t video_configuration_ {};  ///< Immutable active video generation mapping.
    retained_frame_pool *video_frame_pool_ {};  ///< Preallocated complete-frame ABI storage.
    VideoReceivePool video_receive_pool_ {};  ///< Fixed in-place UDP/video packet slab owner.
    std::unique_ptr<lumen::lsp::media::token_frame_slice[]> video_reassembly_slices_ {};  ///< Two fixed zero-copy descriptor tables.
    std::optional<lumen::lsp::media::token_video_frame_reassembler> video_reassembler_ {};  ///< Token-retained two-frame storage.
    lumen::lsp::media::decoder_credit_state video_decoder_credit_;  ///< Two-to-four hardware submissions.
    lumen::lsp::transport::lspv_coalescer lspv_coalescer_;  ///< Protected 500-microsecond status coalescer.
    native_video_feedback_tracker<> video_feedback_;  ///< Sorted bounded RFC 8888 observations.
    native_video_feedback_tracker<> flexfec_feedback_;  ///< FlexFEC-SSRC RFC 8888 observations.
    native_video_feedback_tracker<> rtx_feedback_;  ///< RTX-SSRC RFC 8888 observations.
    native_video_feedback_tracker<> audio_feedback_;  ///< Sorted bounded audio RFC 8888 observations.
    native_rtp_reception_stats video_reception_;  ///< Cumulative primary-video RR loss/jitter/SR state.
    native_rtp_reception_stats flexfec_reception_;  ///< FlexFEC-SSRC RR loss/jitter/SR state.
    native_rtp_reception_stats rtx_reception_;  ///< RTX-SSRC RR loss/jitter/SR state.
    native_rtp_reception_stats audio_reception_;  ///< Cumulative host-audio RR loss/jitter/SR state.
    std::optional<lumen::lsp::transport::path_mtu_discovery> path_mtu_ {};  ///< RFC 8899 search state.
    std::array<VideoFrameMetadata, 2> video_metadata_ {};  ///< Repeated metadata for two incomplete frames.
    std::array<DeliveredVideoFrame, video_delivery_queue_capacity> delivered_video_frames_ {};  ///< Exact native-to-Swift decoder submissions.
    std::array<VideoRetiredFrame, 128> video_retired_frames_ {};  ///< Mirrors the inbound SRTP replay window.
    std::array<AuthenticatedRtpFingerprint, 128> authenticated_video_fingerprints_ {};  ///< Exact video replay identities.
    std::array<AuthenticatedRtpFingerprint, 128> authenticated_flexfec_fingerprints_ {};  ///< Exact FlexFEC replay identities.
    std::array<AuthenticatedRtpFingerprint, 128> authenticated_rtx_fingerprints_ {};  ///< Exact RTX replay identities.
    std::array<AuthenticatedRtpFingerprint, 128> authenticated_audio_fingerprints_ {};  ///< Exact audio replay identities.
    std::array<AuthenticatedVideoSourcePacket, authenticated_video_source_capacity> authenticated_video_sources_ {};  ///< Fixed authenticated primary plaintext retention.
    std::array<PendingFlexFecRepair, pending_flexfec_repair_capacity> pending_flexfec_repairs_ {};  ///< Authenticated repairs awaiting one source.
    std::array<VideoNackRetry, maximum_video_gap_count> video_nack_retries_ {};  ///< Bounded fresh-index NACK repeats.
    std::array<std::uint32_t, 16> reserved_ssrcs_ {};  ///< Globally unique per-association SSRC registry.
    std::array<std::uint8_t, 16> reserved_payload_types_ {};  ///< Globally unique dynamic PT registry.
    lumen::lsp::transport::source_replay_window video_source_replay_;  ///< Shared original/FEC/RTX-OSN admission state.
    lumen::lsp::transport::video_gap_tracker<maximum_video_gap_count> video_gap_tracker_;  ///< Primary gap/NACK state.
    std::array<clsp_video_frame_event_t, video_delivery_queue_capacity> pending_video_deliveries_ {};  ///< Post-drain frame callbacks.
    std::array<std::uint64_t, video_delivery_queue_capacity> pending_video_auth_times_ {};  ///< Earliest auth time per pending frame.
    std::array<clsp_path_probe_event_t, 4> pending_path_probe_events_ {};  ///< Retained coarse probe callbacks.
    clsp_microphone_configuration_t microphone_configuration_ {};  ///< Installed reverse microphone tuple.
    PendingProtectedMicrophone pending_microphone_ {};  ///< Exact protected RTP retry state.
    std::array<DeferredVideoDatagram, receive_batch_size> deferred_video_ {};  ///< Current bounded priority batch.
    std::size_t deferred_video_count_ {};  ///< Protected video packets collected this worker turn.
    std::array<lumen::lsp::packet_slab<maximum_microphone_opus_bytes>, microphone_queue_capacity> microphone_queue_ {};  ///< Complete Opus SPSC queue.
    std::array<InputSentPacket, input_feedback_ledger_capacity>
      input_sent_packets_ {};  ///< O(1) successful-send and local-unsent input correlation.
    std::array<MicrophoneSentPacket, microphone_feedback_ledger_capacity>
      microphone_sent_packets_ {};  ///< Successful microphone sends retained for CCFB.
    std::array<MicrophoneSenderReportTiming, 8>
      input_sender_report_timings_ {};  ///< Recent input SR LSR/send-time correlations.
    std::array<MicrophoneSenderReportTiming, 8>
      microphone_sender_report_timings_ {};  ///< Recent SR LSR/send-time correlations.
    std::optional<lumen::lsp::transport::congestion_controller>
      microphone_congestion_ {};  ///< Independent reverse-path capacity state.
    std::atomic<std::size_t> microphone_read_ {0};  ///< Native sender queue read cursor.
    std::atomic<std::size_t> microphone_write_ {0};  ///< Swift encoder queue write cursor.
    std::atomic<bool> microphone_active_ {false};  ///< Capture-to-network admission state.
    std::atomic<bool> microphone_prepared_ {false};  ///< Mapping/queue prepared before semantic ACK.
    std::atomic<bool> microphone_marker_ {true};  ///< Marker for the next discontinuous packet.
    std::atomic<std::uint64_t> neutralize_requested_ {0};  ///< Latest synchronous neutralize token.
    std::atomic<std::uint64_t> neutralize_completed_ {0};  ///< Worker-completed neutralize token.
    std::atomic<std::uint64_t> input_configuration_requested_ {0};  ///< Latest synchronous mapping token.
    std::atomic<std::uint64_t> input_configuration_completed_ {0};  ///< Worker-installed mapping token.
    std::atomic<std::uint64_t> input_rate_update_requested_ {0};  ///< Latest producer rate-update token.
    std::atomic<std::uint64_t> input_rate_update_completed_ {0};  ///< Worker-applied rate-update token.
    std::atomic<std::uint64_t> completed_response_request_ {0};  ///< Last submitted/cached semantic response ID.
    std::size_t control_queue_head_ {};  ///< Next queued request to consume.
    std::size_t control_queue_tail_ {};  ///< Next free queue slot.
    std::size_t queued_control_count_ {};  ///< Occupied pre-wire queue slots.
    std::size_t pending_video_delivery_count_ {};  ///< Completed frames awaiting post-drain callback.
    std::size_t reserved_ssrc_count_ {};  ///< Populated SSRC reservations.
    std::size_t reserved_payload_type_count_ {};  ///< Populated dynamic PT reservations.
    std::size_t pending_path_probe_event_count_ {};  ///< Populated retained path callbacks.
    PendingProtectedRtcp pending_rtcp_ {};  ///< Exact protected regular/reduced RTCP retry.
    PendingInboundSecurityInstall pending_inbound_security_install_ {};  ///< Socket-thread provider mutation.
    PendingProtectedNack pending_video_nack_ {};  ///< Urgent protected Generic NACK retry.
    PendingControllerAck pending_controller_ack_ {};  ///< Exact protected controller ACK retry.
    PathIntentControlFrame path_intent_control_ {};  ///< Optional nonfatal reliable probe intent.
    std::atomic<std::size_t> capture_read_ {0};  ///< Worker-owned SPSC read cursor.
    std::atomic<std::size_t> capture_write_ {0};  ///< Capture-source-owned SPSC write cursor.
    std::atomic<std::uint32_t> published_pointer_generation_ {1};  ///< Logical pointer generation available to AppKit/native capture.
    std::array<std::atomic<std::uint32_t>, 16> published_controller_generations_ {};  ///< Active controller generations.
    std::array<std::atomic<std::uint32_t>, 16> published_touch_generations_ {};  ///< Active touch-device generations.
    std::array<std::atomic<std::uint32_t>, 16> published_pen_generations_ {};  ///< Active pen-device generations.
    std::array<std::atomic<std::uint8_t>, 16> published_controller_sensor_masks_ {};  ///< Active gyro/accelerometer capabilities.
    std::atomic<std::uint32_t> pointer_drop_generation_ {1};  ///< Exact generation owning pointer drop telemetry.
    std::atomic<std::uint64_t> pointer_dropped_samples_ {0};  ///< Bounded pointer ring drops in the exact generation.
    std::atomic<std::uint64_t> pointer_attributed_wire_bytes_ {0};  ///< Pointer state complete IP bytes.
    std::array<std::atomic<std::uint32_t>, 16> controller_drop_generations_ {};  ///< Exact controller drop generations.
    std::array<std::atomic<std::uint64_t>, 16> controller_dropped_samples_ {};  ///< Bounded controller ring drops.
    std::array<std::atomic<std::uint64_t>, 16> controller_attributed_wire_bytes_ {};  ///< Controller state/sensor IP bytes.
    std::uint64_t next_message_id_ {1};  ///< Next nonzero client-to-host LSPC message ID.
    std::uint64_t next_control_reservation_token_ {};  ///< Next invisible request reservation incarnation.
    std::uint64_t next_inbound_security_install_token_ {1};  ///< Next provider-install request token.
    std::uint64_t completed_inbound_security_install_token_ {};  ///< Last provider-install completion token.
    std::uint64_t video_next_metadata_order_ {1};  ///< Oldest-frame eviction ordering.
    std::uint64_t video_next_retirement_order_ {1};  ///< Retired-key replacement ordering.
    std::uint64_t feedback_largest_extended_sequence_ {};  ///< RFC 8888 sequence expansion origin.
    std::uint64_t flexfec_feedback_largest_extended_sequence_ {};  ///< FlexFEC RFC 8888 sequence origin.
    std::uint64_t rtx_feedback_largest_extended_sequence_ {};  ///< RTX RFC 8888 sequence origin.
    std::uint64_t audio_feedback_largest_extended_sequence_ {};  ///< Audio CCFB sequence origin.
    std::uint64_t next_path_probe_id_ {1};  ///< Per-association logical probe ID sequence.
    std::uint64_t path_probe_notification_microseconds_ {};  ///< Swift intent callback origin.
    std::uint64_t path_intent_message_id_ {};  ///< LSPC intent awaiting explicit peer ACK.
    std::uint64_t path_intent_request_id_ {};  ///< Swift continuation paired with optional intent.
    std::uint64_t path_intent_probe_id_ {};  ///< Probe ID paired with the ACK-gated intent.
    std::uint64_t last_acknowledged_probe_id_ {};  ///< Idempotent PATH_PROBE_ACK identity.
    std::uint64_t last_received_probe_id_ {};  ///< Idempotent host LSPP identity.
    std::uint64_t last_compound_rtcp_microseconds_ {};  ///< Last regular RTCP submission.
    std::uint64_t last_path_raise_microseconds_ {};  ///< Safe PMTU raise-search timer origin.
    std::uint64_t video_received_ip_bytes_ {};  ///< Complete authenticated video IP-layer bytes.
    std::uint64_t congestion_feedback_ip_bytes_ {};  ///< Complete reverse CCFB IP-layer bytes.
    std::uint64_t congestion_feedback_packets_ {};  ///< Successfully submitted CCFB count.
    std::uint64_t video_ecn_unknown_packets_ {};  ///< Packets lacking kernel ECN ancillary data.
    std::uint64_t video_ecn_ce_packets_ {};  ///< Authenticated ECN-CE video packets.
    std::uint64_t video_largest_extended_sequence_ {};  ///< RTP sequence wrap/reorder origin.
    std::uint64_t video_largest_extended_timestamp_ {};  ///< RTP timestamp wrap/reorder origin.
    std::uint64_t video_largest_complete_frame_id_ {};  ///< LSPV complete watermark.
    std::uint64_t video_largest_decoded_frame_id_ {};  ///< LSPV hardware-decode watermark.
    std::uint64_t video_largest_metal_frame_id_ {};  ///< LSPV Metal-commit watermark.
    std::uint64_t video_recovery_evidence_watermark_ {};  ///< Decoded watermark that must advance to clear repeated recovery evidence.
    std::uint64_t last_recovery_lspv_microseconds_ {};  ///< Last submitted recovery-relevant LSPV.
    std::uint64_t authenticated_repair_abuse_window_start_ {};  ///< Rolling repair-abuse window origin.
    std::uint32_t video_current_recovery_epoch_ {};  ///< Dynamic epoch seeded by VIDEO_CONFIG and advanced by authenticated media.
    std::uint8_t video_render_mailbox_occupancy_ {};  ///< Current Swift render mailbox occupancy.
    std::uint16_t last_acknowledged_probe_size_ {};  ///< Idempotent confirmed payload size.
    std::uint16_t last_received_probe_size_ {};  ///< Idempotent received payload size.
    std::uint16_t path_intent_probe_size_ {};  ///< Candidate paired with ACK-gated intent.
    std::uint16_t authenticated_repair_abuse_count_ {};  ///< Malformed/resource repair events in the current window.
    std::array<std::uint8_t, 36> compound_cname_ {};  ///< Privacy-safe random per-session CNAME.
    std::size_t compound_cname_length_ {};  ///< Populated CNAME byte count.
    InboundPathProbeIntent inbound_path_probe_intent_ {};  ///< Host intent awaiting LSPP.
    UnmatchedPathProbe unmatched_path_probe_ {};  ///< One authenticated reordered LSPP.
    OutboundPathProbePacket outbound_path_probe_ {};  ///< Client probe send/timer state.
    std::uint64_t pending_input_configuration_token_ {};  ///< Token paired with pending START/ATTACH mapping.
    std::uint64_t pending_input_rate_token_ {};  ///< Token paired with pending rate renegotiation.
    std::uint64_t pending_baseline_id_ {};  ///< Exact handoff rollback baseline ID, or zero for native generation.
    std::uint32_t connection_generation_ {};  ///< Zero through CLIENT_HELLO, then host-assigned generation.
    std::uint64_t baseline_id_ {};  ///< Current random neutral-baseline identifier.
    std::uint64_t baseline_last_sent_us_ {};  ///< Most recent baseline submission time.
    std::array<std::uint8_t, lumen::lsp::input_plane::maximum_baseline_bytes>
      baseline_body_ {};  ///< Byte-identical complete neutral baseline retained through ACK.
    std::array<std::uint8_t, 32> baseline_digest_ {};  ///< SHA-256 over the exact retained complete baseline.
    std::size_t baseline_body_length_ {};  ///< Populated deterministic baseline bytes.
    std::uint64_t baseline_edge_watermark_ {};  ///< Frozen edge watermark for the retained baseline ID.
    std::uint64_t baseline_first_submitted_microseconds_ {};  ///< First part submission awaiting host ACK.
    std::uint8_t baseline_next_part_index_ {};  ///< Next path-safe part in the retained retransmission cycle.
    std::uint8_t baseline_part_count_ {};  ///< Frozen path-safe part count one through thirty-two.
    std::uint64_t pointer_ordinal_ {};  ///< Monotonic physical pointer sample ordinal.
    std::uint64_t pointer_sample_time_us_ {};  ///< Newest captured pointer time.
    std::uint64_t pointer_composed_microseconds_ {};  ///< Worker composition time for newest pointer state.
    std::uint64_t latest_edge_id_ {};  ///< Newest assigned physical edge identifier.
    std::uint64_t latest_state_sequence_ {2};  ///< Latest sampled replaceable-state sequence.
    std::uint64_t next_state_sequence_ {2};  ///< Next replaceable-state sequence.
    std::uint64_t input_tokens_bits_ {};  ///< Dedicated input-pacer credit.
    std::uint64_t input_last_credit_us_ {};  ///< Last token refill time.
    std::uint64_t reverse_tokens_bits_ {};  ///< Aggregate input-plus-microphone pacing credit.
    std::uint64_t reverse_last_credit_us_ {};  ///< Aggregate reverse-controller refill time.
    std::uint64_t reverse_congestion_rate_bits_per_second_ {};  ///< Feedback-selected aggregate reverse rate.
    std::uint64_t last_pointer_sent_us_ {};  ///< Last cumulative pointer submission time.
    std::uint16_t rtp_sequence_ {};  ///< Input RTP sequence with libSRTP rollover tracking.
    std::uint64_t input_next_extended_sequence_ {};  ///< Next protect-consumed input RTP sequence incarnation.
    std::uint64_t input_bytes_in_flight_ {};  ///< Successful input sends without terminal feedback.
    std::uint64_t input_delivered_bytes_ {};  ///< Overlap-corrected delivered complete input IP bytes.
    std::uint64_t input_lost_bytes_ {};  ///< Overlap-corrected lost complete input IP bytes.
    std::uint64_t input_ecn_ce_bytes_ {};  ///< Authenticated delivered input CE bytes.
    std::uint64_t input_last_delay_send_microseconds_ {};  ///< Latest input CCFB delay-trend send sample.
    std::uint64_t input_last_rtp_send_microseconds_ {};  ///< Successful send time for input SR projection.
    std::uint32_t input_last_delay_arrival_timestamp_ {};  ///< Latest input CCFB arrival middle-NTP sample.
    std::uint32_t input_last_rtp_timestamp_ {};  ///< Latest successful 1-MHz RTP timestamp.
    std::uint32_t input_packet_count_ {};  ///< Successful input RTP packet count for SR.
    std::uint32_t input_octet_count_ {};  ///< Successful input RTP payload octets for SR.
    std::size_t input_sender_report_timing_index_ {};  ///< Next bounded input SR timing slot.
    bool input_has_delay_sample_ {};  ///< Whether input queue-delay trend has a prior delivery.
    std::uint16_t microphone_sequence_ {};  ///< Microphone RTP sequence.
    std::uint32_t microphone_timestamp_ {};  ///< 48-kHz microphone RTP timestamp.
    std::uint32_t microphone_packet_count_ {};  ///< Sender-report packet count.
    std::uint32_t microphone_octet_count_ {};  ///< Sender-report Opus octet count.
    std::uint64_t microphone_tokens_bits_ {};  ///< Reverse microphone pacing credit.
    std::uint64_t microphone_last_credit_us_ {};  ///< Last microphone token refill.
    std::uint64_t microphone_last_report_us_ {};  ///< Last microphone RTCP SR submission.
    std::uint64_t microphone_next_extended_sequence_ {};  ///< Next microphone RTP sequence incarnation.
    std::uint64_t microphone_congestion_rate_bits_per_second_ {};  ///< Feedback-selected microphone sub-pacer rate.
    std::uint64_t microphone_last_compound_microseconds_ {};  ///< Fresh host RR/CNAME authority time.
    std::uint64_t microphone_last_feedback_microseconds_ {};  ///< Accepted nonempty CCFB cadence origin.
    std::uint64_t microphone_bytes_in_flight_ {};  ///< Successful sends without terminal feedback.
    std::uint64_t microphone_delivered_bytes_ {};  ///< Overlap-corrected delivered complete IP bytes.
    std::uint64_t microphone_lost_bytes_ {};  ///< Overlap-corrected lost complete IP bytes.
    std::uint64_t microphone_ecn_ce_bytes_ {};  ///< Authenticated delivered CE bytes.
    std::uint64_t microphone_last_delay_send_microseconds_ {};  ///< Latest CCFB delay-trend send sample.
    std::uint32_t microphone_last_feedback_timestamp_ {};  ///< Latest nonempty CCFB middle-NTP time.
    std::uint32_t microphone_smoothed_rtt_microseconds_ {};  ///< SR/RR-derived reverse media SRTT.
    std::uint32_t microphone_rtt_variation_microseconds_ {};  ///< SR/RR-derived reverse media RTTVAR.
    std::uint32_t microphone_last_delay_arrival_timestamp_ {};  ///< Latest CCFB arrival middle-NTP sample.
    std::array<std::uint8_t, 255> microphone_feedback_cname_ {};  ///< Stable host feedback CNAME.
    std::size_t microphone_feedback_cname_length_ {};  ///< Populated host feedback CNAME length.
    std::size_t microphone_sender_report_timing_index_ {};  ///< Next bounded SR timing replacement slot.
    std::uint8_t microphone_minimum_failure_count_ {};  ///< Consecutive impaired intervals at minimum capacity.
    bool microphone_has_feedback_timestamp_ {};  ///< Whether CCFB timestamp monotonicity has an origin.
    bool microphone_has_delay_sample_ {};  ///< Whether queue-delay trend has a prior delivery.
    bool reverse_controller_includes_microphone_ {};  ///< Whether aggregate bounds include microphone minima.
    bool input_configuration_pending_ {};  ///< Producer installed a new START mapping.
    bool pending_input_rate_update_ {};  ///< Producer queued one worker-owned rate update.
    bool video_sequence_initialized_ {};  ///< Whether extended sequence state has an origin.
    bool video_timestamp_initialized_ {};  ///< Whether extended timestamp state has an origin.
    bool feedback_sequence_initialized_ {};  ///< Whether CCFB sequence expansion has an origin.
    bool flexfec_feedback_sequence_initialized_ {};  ///< Whether FlexFEC CCFB expansion has an origin.
    bool rtx_feedback_sequence_initialized_ {};  ///< Whether RTX CCFB expansion has an origin.
    bool audio_feedback_sequence_initialized_ {};  ///< Whether audio CCFB expansion has an origin.
    bool video_deadline_miss_latched_ {};  ///< Deadline miss retained until LSPV consumption.
    bool video_recovery_feedback_pending_ {};  ///< Recovery evidence must repeat until a later ready decode or epoch.
    bool path_probe_notification_pending_ {};  ///< Swift has not queued the emitted client intent.
    bool compound_rtcp_sent_ {};  ///< RFC 5506 reduced-size feedback is unlocked.
    bool input_configured_ {};  ///< Worker has an active input mapping.
    std::atomic<bool> capture_accepting_ {false};  ///< New physical capture is authorized.
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

  clsp_status_t Runtime::reserve_control(
    const std::uint16_t message_type,
    const std::uint64_t request_id,
    const clsp_const_byte_span_t payload,
    const std::uint32_t deadline_milliseconds,
    std::uint64_t &reservation_token
  ) noexcept {
    return impl_ == nullptr ? CLSP_STATUS_RESOURCE_EXHAUSTED :
                              impl_->reserve_control(
                                message_type,
                                request_id,
                                payload,
                                deadline_milliseconds,
                                reservation_token
                              );
  }

  clsp_status_t Runtime::commit_control_reservation(const std::uint64_t reservation_token) noexcept {
    return impl_ == nullptr ? CLSP_STATUS_RESOURCE_EXHAUSTED :
                              impl_->commit_control_reservation(reservation_token);
  }

  void Runtime::cancel_control_reservation(const std::uint64_t reservation_token) noexcept {
    if (impl_ != nullptr) {
      impl_->cancel_control_reservation(reservation_token);
    }
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

  clsp_status_t Runtime::activate_video(const std::uint32_t video_generation) noexcept {
    return impl_ == nullptr ? CLSP_STATUS_RESOURCE_EXHAUSTED : impl_->activate_video(video_generation);
  }

  clsp_status_t Runtime::start_path_discovery() noexcept {
    return impl_ == nullptr ? CLSP_STATUS_RESOURCE_EXHAUSTED : impl_->start_path_discovery();
  }

  clsp_status_t Runtime::send_path_probe(
    const std::uint64_t probe_id,
    const std::uint16_t udp_payload_size,
    const std::uint64_t request_id,
    const clsp_const_byte_span_t payload,
    const std::uint32_t deadline_milliseconds
  ) noexcept {
    return impl_ == nullptr ? CLSP_STATUS_RESOURCE_EXHAUSTED :
                              impl_->send_path_probe(
                                probe_id,
                                udp_payload_size,
                                request_id,
                                payload,
                                deadline_milliseconds
                              );
  }

  clsp_status_t Runtime::accept_path_probe(
    const std::uint64_t probe_id,
    const std::uint16_t udp_payload_size,
    const std::uint64_t request_id
  ) noexcept {
    return impl_ == nullptr ? CLSP_STATUS_RESOURCE_EXHAUSTED :
                              impl_->accept_path_probe(probe_id, udp_payload_size, request_id);
  }

  clsp_status_t Runtime::confirm_path_probe(
    const std::uint64_t probe_id,
    const std::uint16_t received_payload_size
  ) noexcept {
    return impl_ == nullptr ? CLSP_STATUS_RESOURCE_EXHAUSTED :
                              impl_->confirm_path_probe(probe_id, received_payload_size);
  }

  std::uint16_t Runtime::current_udp_payload_size() const noexcept {
    return impl_ == nullptr ? std::uint16_t {1'200} : impl_->current_udp_payload_size();
  }

  std::uint16_t Runtime::current_receive_udp_payload_size() const noexcept {
    return impl_ == nullptr ? std::uint16_t {1'200} : impl_->current_receive_udp_payload_size();
  }

  clsp_status_t Runtime::copy_pairing_exporter(
    const std::span<std::uint8_t, 32> output
  ) const noexcept {
    return impl_ == nullptr ? CLSP_STATUS_RESOURCE_EXHAUSTED : impl_->copy_pairing_exporter(output);
  }

  std::uint32_t Runtime::current_connection_generation() const noexcept {
    return impl_ == nullptr ? 0U : impl_->current_connection_generation();
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

  clsp_status_t Runtime::update_input_rates(const clsp_input_rate_update_t &update) noexcept {
    return impl_ == nullptr ? CLSP_STATUS_RESOURCE_EXHAUSTED : impl_->update_input_rates(update);
  }

  clsp_status_t Runtime::copy_input_feedback(clsp_input_feedback_snapshot_t &output) noexcept {
    return impl_ == nullptr ? CLSP_STATUS_RESOURCE_EXHAUSTED : impl_->copy_input_feedback(output);
  }

  clsp_status_t Runtime::copy_input_edge_snapshot(clsp_input_edge_snapshot_t &output) const noexcept {
    return impl_ == nullptr ? CLSP_STATUS_RESOURCE_EXHAUSTED : impl_->copy_input_edge_snapshot(output);
  }

  void Runtime::observe_input_device(
    const std::uint8_t device_type,
    const std::uint32_t device_id,
    const std::uint32_t instance_generation,
    const bool active,
    const std::uint8_t sensor_mask
  ) noexcept {
    if (impl_ != nullptr) {
      impl_->observe_input_device(device_type, device_id, instance_generation, active, sensor_mask);
    }
  }

  std::uint64_t Runtime::input_dropped_samples(
    const std::uint8_t offer_type,
    const std::uint32_t device_id,
    const std::uint32_t instance_generation
  ) const noexcept {
    return impl_ == nullptr ? 0U : impl_->input_dropped_samples(offer_type, device_id, instance_generation);
  }

  std::uint64_t Runtime::input_attributed_wire_bytes(
    const std::uint8_t offer_type,
    const std::uint32_t device_id,
    const std::uint32_t instance_generation
  ) const noexcept {
    return impl_ == nullptr ? 0U :
                              impl_->input_attributed_wire_bytes(offer_type, device_id, instance_generation);
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

  clsp_status_t Runtime::quiesce_input() noexcept {
    return impl_ == nullptr ? CLSP_STATUS_RESOURCE_EXHAUSTED : impl_->quiesce_input();
  }

  clsp_status_t Runtime::restart_input_baseline(const std::uint64_t baseline_id) noexcept {
    return impl_ == nullptr ? CLSP_STATUS_RESOURCE_EXHAUSTED : impl_->restart_input_baseline(baseline_id);
  }
}  // namespace umbra::lsp
