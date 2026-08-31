/**
 * @file BufferInternal.h
 * @brief Internal retained C-buffer construction for complete native frames.
 */

#pragma once

#include "CLSPCore.h"

#include <cstddef>
#include <cstdint>
#include <span>

namespace umbra::lsp {
  /** @brief Opaque bounded storage shared by the runtime and outstanding frame
   * handles. */
  struct retained_frame_pool;

  /**
   * @brief Allocate all complete-frame storage before the video generation is
   * admitted.
   *
   * @param maximum_frame_bytes Byte capacity of every slot.
   * @param slot_count Number of simultaneously retained complete frames.
   * @return Owning pool reference, or null when the bounded allocation fails.
   */
  [[nodiscard]] retained_frame_pool *
  create_retained_frame_pool(std::size_t maximum_frame_bytes, std::size_t slot_count) noexcept;

  /** @brief Release the runtime's pool reference after teardown or
   * reconfiguration. */
  void release_retained_frame_pool(retained_frame_pool *pool) noexcept;

  /**
   * @brief Acquire one already allocated complete-frame slot.
   *
   * The returned buffer owns one pool reference and returns its slot on final C
   * ABI release.
   *
   * @param pool Configured pool.
   * @param frame_bytes Exact completed access-unit byte count.
   * @return Owning C ABI handle, or null when no slot is available.
   */
  [[nodiscard]] clsp_buffer_t *
  acquire_retained_frame_buffer(retained_frame_pool *pool, std::size_t frame_bytes) noexcept;

  /**
   * @brief Borrow writable bytes while constructing a newly acquired native
   * frame.
   *
   * @param buffer Pool-backed buffer returned by `acquire_retained_frame_buffer`.
   * @return Exact mutable frame span, or an empty span for an invalid buffer.
   */
  [[nodiscard]] std::span<std::uint8_t>
  mutable_retained_frame_bytes(clsp_buffer_t *buffer) noexcept;

  /**
   * @brief Shrink one occupied retained buffer to its completed logical size.
   *
   * @param buffer Pool-backed occupied buffer.
   * @param frame_bytes Positive logical byte count no greater than slot capacity.
   * @return `true` only when the occupied buffer was resized.
   */
  [[nodiscard]] bool resize_retained_frame_buffer(
    clsp_buffer_t *buffer,
    std::size_t frame_bytes
  ) noexcept;
}  // namespace umbra::lsp
