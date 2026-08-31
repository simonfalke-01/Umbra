/**
 * @file TransportFeedback.h
 * @brief Allocation-free RFC 8888 CCFB, compound RTCP, and LSPP wire helpers.
 */

#pragma once

#include "../core/wire.h"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <span>

namespace umbra::lsp {
  /** @brief Actual IP ECN observation, retaining unknown separately from not-ECT. */
  enum class native_ecn_mark : std::uint8_t {
    unknown,  ///< No ancillary IP ECN field was delivered by the kernel.
    not_ect,  ///< IP ECN bits were `00`.
    ect1,  ///< IP ECN bits were `01`.
    ect0,  ///< IP ECN bits were `10`.
    congestion_experienced,  ///< IP ECN bits were `11`.
  };

  /** @brief One authenticated primary-video arrival retained for RFC 8888. */
  struct native_congestion_observation {
    std::uint64_t extended_sequence {};  ///< Extended RTP sequence number.
    std::uint64_t arrival_microseconds {};  ///< Earliest local monotonic arrival.
    std::uint16_t received_ip_bytes {};  ///< Complete IP-layer bytes.
    native_ecn_mark ecn {native_ecn_mark::unknown};  ///< Actual or unavailable ECN observation.
  };

  /** @brief Result of adding one authenticated observation. */
  enum class native_feedback_record_result : std::uint8_t {
    accepted,  ///< New sequence was inserted in order.
    duplicate,  ///< Existing first arrival was retained; CE may have been upgraded.
    invalid,  ///< Sequence, time, or complete IP byte count was invalid.
    full,  ///< The bounded interval is full and must be reported.
  };

  /** @brief One serialized RFC 8888 feedback packet and its commit watermark. */
  struct native_feedback_write_result {
    std::size_t bytes_written {};  ///< Complete plaintext reduced-size RTCP bytes.
    std::uint64_t commit_through_sequence {};  ///< Highest extended sequence covered.
    std::uint64_t snapshot_version {};  ///< Observation version frozen into serialized bytes.
    std::uint16_t metric_count {};  ///< Exact `num_reports` metric-block count.

    /** @brief Return whether a complete feedback packet was produced. */
    [[nodiscard]] explicit operator bool() const noexcept {
      return bytes_written != 0 && metric_count != 0;
    }
  };

  /**
   * @brief Sorted fixed-capacity RFC 8888 interval state with bounded reorder correction.
   *
   * @tparam Capacity Maximum authenticated received-packet observations retained.
   */
  template<std::size_t Capacity = 512>
  class native_video_feedback_tracker {
  public:
    static_assert(Capacity >= 128, "RFC 8888 tracker must retain one packet-cadence interval");

    /** @brief Reset the disjoint interval and report cadence for a new video generation. */
    void reset(const std::uint64_t now_microseconds) noexcept {
      count_ = 0;
      last_report_microseconds_ = now_microseconds;
      highest_committed_sequence_ = 0;
      has_committed_sequence_ = false;
      next_version_ = 1;
    }

    /** @brief Insert one first-arrival observation in extended-sequence order. */
    native_feedback_record_result record(const native_congestion_observation &observation) noexcept {
      if (observation.arrival_microseconds == 0 || observation.received_ip_bytes == 0) {
        return native_feedback_record_result::invalid;
      }
      std::size_t position = 0;
      while (position < count_ && reports_[position].extended_sequence < observation.extended_sequence) {
        ++position;
      }
      if (position < count_ && reports_[position].extended_sequence == observation.extended_sequence) {
        if (observation.ecn == native_ecn_mark::congestion_experienced &&
            reports_[position].ecn != native_ecn_mark::congestion_experienced) {
          reports_[position].ecn = native_ecn_mark::congestion_experienced;
          versions_[position] = next_version_++;
        }
        return native_feedback_record_result::duplicate;
      }
      if (count_ == Capacity) {
        return native_feedback_record_result::full;
      }
      for (auto index = count_; index > position; --index) {
        reports_[index] = reports_[index - 1U];
        versions_[index] = versions_[index - 1U];
      }
      reports_[position] = observation;
      versions_[position] = next_version_++;
      ++count_;
      return native_feedback_record_result::accepted;
    }

    /** @brief Return whether 2 ms, 128 packets, or full bounded storage makes feedback due. */
    [[nodiscard]] bool due(const std::uint64_t now_microseconds) const noexcept {
      if (count_ == 0 || now_microseconds < last_report_microseconds_ ||
          now_microseconds - last_report_microseconds_ < 500U) {
        return false;
      }
      return count_ >= 128U || now_microseconds - last_report_microseconds_ >= 2'000U || count_ == Capacity;
    }

    /**
     * @brief Serialize one standards-compliant reduced-size RFC 8888 CCFB packet.
     *
     * Errata 8166 defines the half-open interval, so `num_reports` is the exact number of
     * metric blocks, not count minus one. Missing sequence numbers receive zero metric blocks.
     *
     * @param sender_ssrc Feedback sender SSRC.
     * @param media_ssrc Active primary-video SSRC.
     * @param now_microseconds Current monotonic instant used for ATO values.
     * @param report_timestamp Middle 32 bits of the corresponding NTP timestamp.
     * @param destination Path-safe plaintext RTCP storage.
     * @return Complete write result, or zero bytes if no bounded report fits.
     */
    [[nodiscard]] native_feedback_write_result write(
      const std::uint32_t sender_ssrc,
      const std::uint32_t media_ssrc,
      const std::uint64_t now_microseconds,
      const std::uint32_t report_timestamp,
      const std::span<std::uint8_t> destination
    ) const noexcept {
      if (sender_ssrc == 0 || media_ssrc == 0 || count_ == 0 || destination.size() < 24U) {
        return {};
      }
      auto begin = reports_[0].extended_sequence;
      if (has_committed_sequence_ && reports_[0].extended_sequence > highest_committed_sequence_) {
        begin = highest_committed_sequence_ + 1U;
      }
      auto maximum_metrics = std::min<std::size_t>(16'384U, (destination.size() - 20U) / 2U);
      while (maximum_metrics != 0) {
        const auto required = 20U + maximum_metrics * 2U + (maximum_metrics % 2U == 0 ? 0U : 2U);
        if (required <= destination.size()) {
          break;
        }
        --maximum_metrics;
      }
      if (maximum_metrics == 0) {
        return {};
      }
      const auto furthest_observed = reports_[count_ - 1U].extended_sequence;
      const auto end = furthest_observed < begin ? begin :
                                                   std::min(furthest_observed, begin + maximum_metrics - 1U);
      const auto metric_count = static_cast<std::size_t>(end - begin + 1U);
      if (metric_count == 0 || metric_count > 16'384U) {
        return {};
      }
      const auto packet_size = 20U + metric_count * 2U + (metric_count % 2U == 0 ? 0U : 2U);
      if (packet_size > destination.size() || packet_size / 4U - 1U > UINT16_MAX) {
        return {};
      }
      const auto packet = destination.first(packet_size);
      std::fill(packet.begin(), packet.end(), 0);
      packet[0] = static_cast<std::uint8_t>(0x80U | 11U);
      packet[1] = 205U;
      lumen::lsp::wire::write_be<std::uint16_t>(packet.subspan(2, 2), static_cast<std::uint16_t>(packet_size / 4U - 1U));
      lumen::lsp::wire::write_be<std::uint32_t>(packet.subspan(4, 4), sender_ssrc);
      lumen::lsp::wire::write_be<std::uint32_t>(packet.subspan(8, 4), media_ssrc);
      lumen::lsp::wire::write_be<std::uint16_t>(packet.subspan(12, 2), static_cast<std::uint16_t>(begin));
      lumen::lsp::wire::write_be<std::uint16_t>(packet.subspan(14, 2), static_cast<std::uint16_t>(metric_count));

      std::size_t report_index = 0;
      for (std::size_t metric_index = 0; metric_index < metric_count; ++metric_index) {
        const auto sequence = begin + metric_index;
        while (report_index < count_ && reports_[report_index].extended_sequence < sequence) {
          ++report_index;
        }
        if (report_index == count_ || reports_[report_index].extended_sequence != sequence) {
          continue;
        }
        const auto &report = reports_[report_index];
        const auto ecn = wire_ecn(report.ecn);
        std::uint16_t arrival_offset = 0x1fffU;
        if (report.arrival_microseconds <= now_microseconds) {
          const auto elapsed = now_microseconds - report.arrival_microseconds;
          const auto units = elapsed > UINT64_MAX / 1'024U ? UINT64_MAX : elapsed * 1'024U / 1'000'000U;
          arrival_offset = units > 8'189U ? 0x1ffeU : static_cast<std::uint16_t>(units);
        }
        const auto metric = static_cast<std::uint16_t>(0x8000U | (static_cast<std::uint16_t>(ecn) << 13U) | arrival_offset);
        lumen::lsp::wire::write_be<std::uint16_t>(packet.subspan(16U + metric_index * 2U, 2), metric);
      }
      lumen::lsp::wire::write_be<std::uint32_t>(packet.last(4), report_timestamp);
      return {
        .bytes_written = packet_size,
        .commit_through_sequence = end,
        .snapshot_version = next_version_ - 1U,
        .metric_count = static_cast<std::uint16_t>(metric_count),
      };
    }

    /** @brief Consume observations covered by one successfully submitted report. */
    bool commit(const native_feedback_write_result &written, const std::uint64_t now_microseconds) noexcept {
      if (!written || now_microseconds < last_report_microseconds_) {
        return false;
      }
      std::size_t retained = 0;
      for (std::size_t index = 0; index < count_; ++index) {
        const auto serialized = reports_[index].extended_sequence <= written.commit_through_sequence &&
                                versions_[index] <= written.snapshot_version;
        if (serialized) {
          continue;
        }
        reports_[retained] = reports_[index];
        versions_[retained] = versions_[index];
        ++retained;
      }
      count_ = retained;
      if (!has_committed_sequence_ || written.commit_through_sequence > highest_committed_sequence_) {
        highest_committed_sequence_ = written.commit_through_sequence;
        has_committed_sequence_ = true;
      }
      last_report_microseconds_ = now_microseconds;
      return true;
    }

    /** @brief Return the bounded received-observation count. */
    [[nodiscard]] std::size_t size() const noexcept {
      return count_;
    }

  private:
    /** @brief Map actual ECN state to RFC 8888's two-bit echo field. */
    [[nodiscard]] static std::uint8_t wire_ecn(const native_ecn_mark mark) noexcept {
      switch (mark) {
        case native_ecn_mark::ect1:
          return 1U;
        case native_ecn_mark::ect0:
          return 2U;
        case native_ecn_mark::congestion_experienced:
          return 3U;
        case native_ecn_mark::unknown:
        case native_ecn_mark::not_ect:
          return 0U;
      }
      return 0U;
    }

    std::array<native_congestion_observation, Capacity> reports_ {};  ///< Sorted pending first arrivals.
    std::array<std::uint64_t, Capacity> versions_ {};  ///< Mutation version for exact backpressure commit.
    std::size_t count_ {};  ///< Populated leading observations.
    std::uint64_t last_report_microseconds_ {};  ///< Prior successful CCFB submission.
    std::uint64_t highest_committed_sequence_ {};  ///< Highest normally disjoint reported sequence.
    bool has_committed_sequence_ {};  ///< Whether the next interval has a prior endpoint.
    std::uint64_t next_version_ {1};  ///< Next nonzero observation mutation version.
  };

  /** @brief Exact validated plaintext LSPP application probe. */
  struct lspp_probe {
    std::uint64_t probe_id {};  ///< Authenticated nonzero probe ID.
    std::uint16_t udp_payload_size {};  ///< Exact protected UDP payload size.
  };

  /** @brief One RFC 3550 receiver report block derived from authenticated RTP arrivals. */
  struct native_receiver_report_block {
    std::uint32_t media_ssrc {};  ///< Reported RTP source.
    std::uint8_t fraction_lost {};  ///< Interval loss fraction in 1/256 units.
    std::int32_t cumulative_lost {};  ///< Signed 24-bit cumulative loss.
    std::uint32_t extended_highest_sequence {};  ///< Low 32 bits of extended maximum sequence.
    std::uint32_t interarrival_jitter {};  ///< RFC 3550 jitter in RTP timestamp units.
    std::uint32_t last_sender_report {};  ///< Middle-NTP sender-report timestamp, or zero.
    std::uint32_t delay_since_last_sender_report {};  ///< 1/65536 seconds, or zero.
  };

  /** @brief Allocation-free cumulative and interval RTP receiver statistics for one SSRC. */
  class native_rtp_reception_stats {
  public:
    /** @brief Reset all sequence, loss, and jitter state for a new generation. */
    void reset() noexcept {
      *this = {};
    }

    /** @brief Record one newly authenticated nonduplicate RTP packet. */
    void record(
      const std::uint64_t extended_sequence,
      const std::uint32_t rtp_timestamp,
      const std::uint64_t arrival_microseconds,
      const std::uint32_t clock_rate
    ) noexcept {
      if (arrival_microseconds == 0 || clock_rate == 0) {
        return;
      }
      if (!initialized_) {
        base_sequence_ = extended_sequence;
        highest_sequence_ = extended_sequence;
        initialized_ = true;
      } else {
        highest_sequence_ = std::max(highest_sequence_, extended_sequence);
      }
      ++received_packets_;
      const auto arrival_timestamp = static_cast<std::uint32_t>(
        arrival_microseconds > UINT64_MAX / clock_rate ? UINT64_MAX :
                                                         arrival_microseconds * clock_rate / 1'000'000U
      );
      const auto transit = static_cast<std::int32_t>(arrival_timestamp - rtp_timestamp);
      if (has_transit_) {
        const auto difference = static_cast<std::int64_t>(transit) - prior_transit_;
        const auto delta = difference >= 0 ? static_cast<std::uint64_t>(difference) :
                                             static_cast<std::uint64_t>(-difference);
        jitter_ += (static_cast<std::int64_t>(delta) - jitter_ + 8) / 16;
      }
      prior_transit_ = transit;
      has_transit_ = true;
    }

    /** @brief Return whether at least one authenticated packet initialized this source. */
    [[nodiscard]] bool initialized() const noexcept {
      return initialized_;
    }

    /** @brief Retain middle-NTP and local arrival for the latest authenticated sender report. */
    void note_sender_report(
      const std::uint32_t middle_ntp,
      const std::uint64_t received_microseconds
    ) noexcept {
      if (middle_ntp == 0 || received_microseconds == 0) {
        return;
      }
      last_sender_report_ = middle_ntp;
      last_sender_report_received_microseconds_ = received_microseconds;
    }

    /** @brief Snapshot one RFC 3550 report block and advance interval counters. */
    native_receiver_report_block report(
      const std::uint32_t media_ssrc,
      const std::uint64_t now_microseconds
    ) noexcept {
      if (!initialized_ || media_ssrc == 0) {
        return {};
      }
      const auto expected = highest_sequence_ - base_sequence_ + 1U;
      const auto cumulative = static_cast<std::int64_t>(expected) - static_cast<std::int64_t>(received_packets_);
      const auto interval_expected = expected - prior_expected_;
      const auto interval_received = received_packets_ - prior_received_;
      const auto interval_lost = static_cast<std::int64_t>(interval_expected) - static_cast<std::int64_t>(interval_received);
      prior_expected_ = expected;
      prior_received_ = received_packets_;
      const auto fraction = interval_expected == 0 || interval_lost <= 0 ? 0U :
                                                                           std::min<std::uint64_t>(255U, static_cast<std::uint64_t>(interval_lost) * 256U / interval_expected);
      const auto clamped_lost = std::clamp<std::int64_t>(cumulative, -8'388'608, 8'388'607);
      const auto delay = last_sender_report_ == 0 || now_microseconds < last_sender_report_received_microseconds_ ? 0U :
                                                                                                                    static_cast<std::uint32_t>(std::min<std::uint64_t>(
                                                                                                                      UINT32_MAX,
                                                                                                                      (now_microseconds - last_sender_report_received_microseconds_) * 65'536U / 1'000'000U
                                                                                                                    ));
      return {
        .media_ssrc = media_ssrc,
        .fraction_lost = static_cast<std::uint8_t>(fraction),
        .cumulative_lost = static_cast<std::int32_t>(clamped_lost),
        .extended_highest_sequence = static_cast<std::uint32_t>(highest_sequence_),
        .interarrival_jitter = jitter_ <= 0 ? 0U : static_cast<std::uint32_t>(std::min<std::int64_t>(jitter_, UINT32_MAX)),
        .last_sender_report = last_sender_report_,
        .delay_since_last_sender_report = delay,
      };
    }

  private:
    std::uint64_t base_sequence_ {};  ///< First authenticated extended sequence.
    std::uint64_t highest_sequence_ {};  ///< Highest authenticated extended sequence.
    std::uint64_t received_packets_ {};  ///< Unique authenticated packet count.
    std::uint64_t prior_expected_ {};  ///< Prior report expected count.
    std::uint64_t prior_received_ {};  ///< Prior report received count.
    std::int32_t prior_transit_ {};  ///< Prior modulo-32-bit arrival-minus-RTP transit.
    std::int64_t jitter_ {};  ///< Smoothed absolute transit delta.
    std::uint64_t last_sender_report_received_microseconds_ {};  ///< Local arrival of latest SR.
    std::uint32_t last_sender_report_ {};  ///< Middle 32 bits of latest SR NTP timestamp.
    bool initialized_ {};  ///< Whether sequence state has an origin.
    bool has_transit_ {};  ///< Whether jitter has a prior transit sample.
  };

  /** @brief Write one exact-size LSPP APP packet with authenticated zero application padding. */
  [[nodiscard]] inline bool write_lspp(
    const std::uint32_t sender_ssrc,
    const std::uint64_t probe_id,
    const std::uint16_t protected_udp_payload_size,
    const std::span<std::uint8_t> plaintext
  ) noexcept {
    if (sender_ssrc == 0 || probe_id == 0 || protected_udp_payload_size < 1'200U ||
        plaintext.size() < 24U || plaintext.size() % 4U != 0 || plaintext.size() / 4U - 1U > UINT16_MAX) {
      return false;
    }
    std::fill(plaintext.begin(), plaintext.end(), 0);
    plaintext[0] = 0x80U;
    plaintext[1] = 204U;
    lumen::lsp::wire::write_be<std::uint16_t>(plaintext.subspan(2, 2), static_cast<std::uint16_t>(plaintext.size() / 4U - 1U));
    lumen::lsp::wire::write_be<std::uint32_t>(plaintext.subspan(4, 4), sender_ssrc);
    plaintext[8] = 'L';
    plaintext[9] = 'S';
    plaintext[10] = 'P';
    plaintext[11] = 'P';
    plaintext[12] = 1U;
    lumen::lsp::wire::write_be<std::uint16_t>(plaintext.subspan(14, 2), protected_udp_payload_size);
    lumen::lsp::wire::write_be<std::uint64_t>(plaintext.subspan(16, 8), probe_id);
    return true;
  }

  /** @brief Parse one exact-size LSPP APP plaintext packet and validate every zero padding byte. */
  [[nodiscard]] inline lspp_probe parse_lspp(
    const std::span<const std::uint8_t> plaintext,
    const std::uint32_t expected_sender_ssrc,
    const std::uint16_t protected_udp_payload_size
  ) noexcept {
    if (plaintext.size() < 24U || plaintext.size() % 4U != 0 || plaintext[0] != 0x80U ||
        plaintext[1] != 204U ||
        (static_cast<std::size_t>(lumen::lsp::wire::read_be<std::uint16_t>(plaintext.subspan(2, 2))) + 1U) * 4U != plaintext.size() ||
        lumen::lsp::wire::read_be<std::uint32_t>(plaintext.subspan(4, 4)) != expected_sender_ssrc ||
        plaintext[8] != 'L' || plaintext[9] != 'S' || plaintext[10] != 'P' || plaintext[11] != 'P' ||
        plaintext[12] != 1U || plaintext[13] != 0U ||
        lumen::lsp::wire::read_be<std::uint16_t>(plaintext.subspan(14, 2)) != protected_udp_payload_size) {
      return {};
    }
    for (std::size_t index = 24; index < plaintext.size(); ++index) {
      if (plaintext[index] != 0U) {
        return {};
      }
    }
    const auto probe_id = lumen::lsp::wire::read_be<std::uint64_t>(plaintext.subspan(16, 8));
    return probe_id == 0 ? lspp_probe {} : lspp_probe {.probe_id = probe_id, .udp_payload_size = protected_udp_payload_size};
  }

  /** @brief Write one privacy-safe compound RR plus SDES CNAME packet. */
  [[nodiscard]] inline std::size_t write_compound_rr_sdes(
    const std::uint32_t sender_ssrc,
    const std::span<const std::uint8_t> cname,
    const std::span<const native_receiver_report_block> reports,
    const std::span<std::uint8_t> destination
  ) noexcept {
    if (sender_ssrc == 0 || cname.empty() || cname.size() > UINT8_MAX || reports.size() > 31U) {
      return 0;
    }
    for (const auto &report : reports) {
      if (report.media_ssrc == 0) {
        return 0;
      }
    }
    const auto rr_size = 8U + reports.size() * 24U;
    const auto sdes_unpadded = 4U + 4U + 2U + cname.size() + 1U;
    const auto sdes_size = (sdes_unpadded + 3U) & ~std::size_t {3U};
    const auto total = rr_size + sdes_size;
    if (destination.size() < total || sdes_size / 4U - 1U > UINT16_MAX) {
      return 0;
    }
    const auto packet = destination.first(total);
    std::fill(packet.begin(), packet.end(), 0);
    packet[0] = static_cast<std::uint8_t>(0x80U | reports.size());
    packet[1] = 201U;
    lumen::lsp::wire::write_be<std::uint16_t>(packet.subspan(2, 2), static_cast<std::uint16_t>(rr_size / 4U - 1U));
    lumen::lsp::wire::write_be<std::uint32_t>(packet.subspan(4, 4), sender_ssrc);
    for (std::size_t index = 0; index < reports.size(); ++index) {
      const auto offset = 8U + index * 24U;
      const auto &report = reports[index];
      lumen::lsp::wire::write_be<std::uint32_t>(packet.subspan(offset, 4), report.media_ssrc);
      packet[offset + 4U] = report.fraction_lost;
      const auto lost = static_cast<std::uint32_t>(report.cumulative_lost) & 0x00ff'ffffU;
      packet[offset + 5U] = static_cast<std::uint8_t>(lost >> 16U);
      packet[offset + 6U] = static_cast<std::uint8_t>(lost >> 8U);
      packet[offset + 7U] = static_cast<std::uint8_t>(lost);
      lumen::lsp::wire::write_be<std::uint32_t>(packet.subspan(offset + 8U, 4), report.extended_highest_sequence);
      lumen::lsp::wire::write_be<std::uint32_t>(packet.subspan(offset + 12U, 4), report.interarrival_jitter);
      lumen::lsp::wire::write_be<std::uint32_t>(packet.subspan(offset + 16U, 4), report.last_sender_report);
      lumen::lsp::wire::write_be<std::uint32_t>(packet.subspan(offset + 20U, 4), report.delay_since_last_sender_report);
    }
    packet[rr_size] = 0x81U;
    packet[rr_size + 1U] = 202U;
    lumen::lsp::wire::write_be<std::uint16_t>(packet.subspan(rr_size + 2U, 2), static_cast<std::uint16_t>(sdes_size / 4U - 1U));
    lumen::lsp::wire::write_be<std::uint32_t>(packet.subspan(rr_size + 4U, 4), sender_ssrc);
    packet[rr_size + 8U] = 1U;
    packet[rr_size + 9U] = static_cast<std::uint8_t>(cname.size());
    std::copy(cname.begin(), cname.end(), packet.begin() + static_cast<std::ptrdiff_t>(rr_size + 10U));
    return total;
  }
}  // namespace umbra::lsp
