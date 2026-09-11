/**
 * @file FixedTelemetry.h
 * @brief Allocation-free fixed-bucket native timing distributions.
 */

#pragma once

#include "CLSPCore.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>

namespace umbra::lsp {
  /** @brief Fixed microsecond bucket upper bounds shared by worker and Apple capture telemetry. */
  inline constexpr std::array<std::uint64_t, 32> native_timing_bucket_bounds {
    0U,
    1U,
    2U,
    4U,
    8U,
    16U,
    32U,
    64U,
    125U,
    250U,
    500U,
    1'000U,
    2'000U,
    4'000U,
    8'000U,
    16'000U,
    32'000U,
    64'000U,
    125'000U,
    250'000U,
    500'000U,
    1'000'000U,
    2'000'000U,
    4'000'000U,
    8'000'000U,
    16'000'000U,
    32'000'000U,
    64'000'000U,
    125'000'000U,
    250'000'000U,
    500'000'000U,
    std::numeric_limits<std::uint64_t>::max(),
  };

  /** @brief Thread-owned fixed-bucket cumulative distribution with no allocation or locks. */
  class FixedTelemetryDistribution {
  public:
    /**
     * @brief Record one valid local duration.
     *
     * @param microseconds Nonnegative duration in microseconds.
     * @param flags Additional clock-quality flags observed by this sample.
     */
    void record(const std::uint64_t microseconds, const std::uint32_t flags = 0U) noexcept {
      std::size_t index = 0U;
      while (index + 1U < native_timing_bucket_bounds.size() &&
             microseconds > native_timing_bucket_bounds[index]) ++index;
      if (buckets_[index] != std::numeric_limits<std::uint64_t>::max()) ++buckets_[index];
      if (count_ != std::numeric_limits<std::uint64_t>::max()) ++count_;
      maximum_ = microseconds > maximum_ ? microseconds : maximum_;
      observed_flags_ |= flags;
    }

    /**
     * @brief Record one unavailable or invalid correlation.
     *
     * @param flags Additional unknown/clock evidence.
     */
    void drop(const std::uint32_t flags = CLSP_NATIVE_TIMING_UNKNOWN_COMPONENT) noexcept {
      add_drops(1U, flags);
    }

    /**
     * @brief Add a coarse producer-owned drop delta on the worker thread.
     *
     * @param amount Number of unavailable correlations.
     * @param flags Additional unknown/clock evidence.
     */
    void add_drops(
      const std::uint64_t amount,
      const std::uint32_t flags = CLSP_NATIVE_TIMING_UNKNOWN_COMPONENT
    ) noexcept {
      drops_ = std::numeric_limits<std::uint64_t>::max() - drops_ < amount ?
                 std::numeric_limits<std::uint64_t>::max() : drops_ + amount;
      observed_flags_ |= flags;
    }

    /**
     * @brief Produce one fixed-layout percentile summary.
     *
     * @param base_flags Stage availability and base clock-domain flags.
     * @return C ABI distribution snapshot.
     */
    [[nodiscard]] clsp_native_distribution_t snapshot(const std::uint32_t base_flags) const noexcept {
      return {
        .count = count_,
        .p50_microseconds = percentile(50U),
        .p95_microseconds = percentile(95U),
        .p99_microseconds = percentile(99U),
        .maximum_microseconds = maximum_,
        .drops = drops_,
        .flags = base_flags | observed_flags_,
      };
    }

  private:
    /**
     * @brief Return one fixed-bucket percentile upper bound.
     *
     * @param percentile_value Percentile from one through one hundred.
     * @return Bucket upper bound, exact maximum for the overflow bucket, or zero without samples.
     */
    [[nodiscard]] std::uint64_t percentile(const std::uint32_t percentile_value) const noexcept {
      if (count_ == 0U) return 0U;
      const auto target = (count_ / 100U) * percentile_value +
                          ((count_ % 100U) * percentile_value + 99U) / 100U;
      std::uint64_t cumulative = 0U;
      for (std::size_t index = 0U; index < buckets_.size(); ++index) {
        cumulative = std::numeric_limits<std::uint64_t>::max() - cumulative < buckets_[index] ?
                       std::numeric_limits<std::uint64_t>::max() : cumulative + buckets_[index];
        if (cumulative >= target) {
          return index + 1U == buckets_.size() ? maximum_ : native_timing_bucket_bounds[index];
        }
      }
      return maximum_;
    }

    std::array<std::uint64_t, native_timing_bucket_bounds.size()> buckets_ {};  ///< Cumulative fixed buckets.
    std::uint64_t count_ {};  ///< Valid samples.
    std::uint64_t maximum_ {};  ///< Exact maximum.
    std::uint64_t drops_ {};  ///< Missing/invalid correlations.
    std::uint32_t observed_flags_ {};  ///< Sample-derived unknown/kernel flags.
  };
}  // namespace umbra::lsp
