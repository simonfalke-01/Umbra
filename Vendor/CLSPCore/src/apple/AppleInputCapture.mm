/**
 * @file AppleInputCapture.mm
 * @brief Native IOHID and focused-window AppKit capture for LSP input.
 */

#include "CLSPCore.h"
#include "../input_plane/feedback.h"
#include "../runtime/FixedTelemetry.h"

#import <AppKit/AppKit.h>
#import <IOKit/hid/IOHIDManager.h>
#import <GameController/GameController.h>
#import <CoreHaptics/CoreHaptics.h>
#import <dispatch/dispatch.h>
#import <mach/mach_time.h>

#include <array>
#include <algorithm>
#include <atomic>
#include <cstdint>
#include <mutex>
#include <new>

extern "C" bool clsp_core_register_apple_capture(clsp_core_t *, clsp_apple_input_capture_t *);
extern "C" void clsp_core_unregister_apple_capture(clsp_core_t *, clsp_apple_input_capture_t *);
extern "C" void clsp_core_publish_device_offer(clsp_core_t *, clsp_device_offer_event_t);
extern "C" void clsp_core_observe_input_device(
  clsp_core_t *,
  std::uint8_t,
  std::uint32_t,
  std::uint32_t,
  bool,
  std::uint8_t
);

/** @brief Opaque native Apple capture owner declared by the public C ABI. */
struct clsp_apple_input_capture {
  std::atomic<std::uint32_t> references {1};  ///< External owner plus transient native quiesce leases.
  std::mutex quiesce_mutex;  ///< Serializes native handoff drain with external owner teardown.
  clsp_core_t *core {};  ///< Retained LSP core receiving allocation-free records.
  IOHIDManagerRef manager {};  ///< Public IOHID device and value callback owner.
  dispatch_queue_t queue {};  ///< Dedicated serial native callback queue.
  dispatch_semaphore_t cancelled {};  ///< Cancellation barrier for callback quiescence.
  std::atomic<bool> active {false};  ///< Callback admission gate.
  bool activated {};  ///< Whether dispatch-queue activation requires cancellation.
  __strong id appkit_monitor {};  ///< Focused-window fallback monitor owned entirely in Objective-C++.
  __strong NSWindow *appkit_window {};  ///< Exact key window allowed to produce fallback events.
  bool prior_mouse_coalescing {};  ///< Mouse-coalescing state restored when AppKit capture stops.
  bool appkit_coalescing_owned {};  ///< Whether this owner changed the process-wide coalescing state.
  std::uint8_t capture_source {CLSP_DEVICE_CAPTURE_IOHID};  ///< Active pointer/keyboard adapter kind.
  std::array<bool, 256> keyboard {};  ///< Current keyboard-page usage state.
  std::array<bool, 6> pointer_buttons {};  ///< Pointer buttons one through five.
  double pointer_x_remainder {};  ///< AppKit sub-integer relative X carried to the next event.
  double pointer_y_remainder {};  ///< AppKit sub-integer relative Y carried to the next event.
  double vertical_scroll_remainder {};  ///< AppKit sub-integer vertical scroll carried forward.
  double horizontal_scroll_remainder {};  ///< AppKit sub-integer horizontal scroll carried forward.
  std::uint32_t pointer_generation {};  ///< Aggregate pointer-source arrival generation.
  std::uint64_t pointer_rate_window_start {};  ///< First motion timestamp in current measurement window.
  std::uint64_t pointer_last_offer {};  ///< Last coarse pointer-rate publication time.
  std::uint64_t pointer_samples {};  ///< Cumulative pointer samples in this generation.
  std::uint64_t pointer_window_samples {};  ///< Samples in current pointer-rate window.
  std::uint64_t pointer_previous_sample {};  ///< Previous pointer timestamp for interval distribution.
  std::uint32_t pointer_minimum_interval {UINT32_MAX};  ///< Window minimum pointer interval.
  std::uint32_t pointer_maximum_interval {};  ///< Window maximum pointer interval.
  umbra::lsp::FixedTelemetryDistribution pointer_spacing;  ///< Cumulative pointer callback spacing.
  __strong GCController *controllers[16] {};  ///< Controller slots owned on the native queue.
  std::array<std::uint32_t, 16> controller_generations {};  ///< Per-slot instance generations.
  std::array<std::uint32_t, 16> controller_buttons {};  ///< Last emitted digital-button masks.
  std::array<std::uint64_t, 16> controller_rate_window_start {};  ///< Controller state-rate window origins.
  std::array<std::uint64_t, 16> controller_last_offer {};  ///< Last controller-rate offer time.
  std::array<std::uint64_t, 16> controller_samples {};  ///< Cumulative controller-state samples.
  std::array<std::uint64_t, 16> controller_window_samples {};  ///< Current controller-rate samples.
  std::array<std::uint64_t, 16> controller_previous_sample {};  ///< Previous controller-state timestamps.
  std::array<std::uint32_t, 16> controller_minimum_interval {};  ///< Window minimum controller intervals.
  std::array<std::uint32_t, 16> controller_maximum_interval {};  ///< Window maximum controller intervals.
  std::array<umbra::lsp::FixedTelemetryDistribution, 16> controller_spacing {};  ///< Controller-state spacing.
  std::array<std::uint64_t, 16> controller_sensor_rate_window_start {};  ///< Motion-callback rate window origins.
  std::array<std::uint64_t, 16> controller_sensor_samples {};  ///< Cumulative motion callbacks per generation.
  std::array<std::uint64_t, 16> controller_sensor_window_samples {};  ///< Motion callbacks in the current window.
  std::array<std::uint64_t, 16> controller_sensor_previous_sample {};  ///< Previous motion callback timestamps.
  std::array<std::uint32_t, 16> controller_sensor_minimum_interval {};  ///< Window minimum motion intervals.
  std::array<std::uint32_t, 16> controller_sensor_maximum_interval {};  ///< Window maximum motion intervals.
  std::array<umbra::lsp::FixedTelemetryDistribution, 16> controller_sensor_spacing {};  ///< Motion spacing.
  std::array<std::uint64_t, 16> latest_output_sequences {};  ///< Applied replaceable output sequences.
  std::array<std::uint64_t, 64> command_sequences {};  ///< Retry-safe terminal command cache keys.
  std::array<std::uint32_t, 64> command_controller_ids {};  ///< Cached controller IDs.
  std::array<std::uint32_t, 64> command_generations {};  ///< Cached instance generations.
  std::array<std::uint8_t, 64> command_statuses {};  ///< Cached terminal command statuses.
  std::size_t next_command_cache {};  ///< Next bounded cache replacement slot.
  std::array<bool, 16> touch_active {};  ///< Active primary touch contact by controller slot.
  std::array<float, 16> touch_x {};  ///< Latest primary touch X.
  std::array<float, 16> touch_y {};  ///< Latest primary touch Y.
  std::array<float, 16> touch_pressure {};  ///< Latest primary touch pressure.
  __strong id connect_observer {};  ///< Low-rate controller-arrival observer.
  __strong id disconnect_observer {};  ///< Low-rate controller-removal observer.
  __strong CHHapticEngine *haptic_engines[16] {};  ///< Reused public controller haptic engines.
  __strong id<CHHapticAdvancedPatternPlayer> haptic_players[16] {};  ///< Reused continuous players.
  mach_timebase_info_data_t timebase {};  ///< Absolute-time to nanoseconds conversion.
};

namespace {
  [[nodiscard]] std::uint64_t timestamp_microseconds(
    const clsp_apple_input_capture &capture,
    std::uint64_t timestamp
  ) noexcept;

  /** @brief Convert GameController seconds or callback entry to monotonic microseconds. */
  [[nodiscard]] std::uint64_t controller_timestamp(
    const clsp_apple_input_capture &capture,
    const NSTimeInterval timestamp
  ) noexcept {
    if (timestamp > 0) {
      return std::max<std::uint64_t>(1, static_cast<std::uint64_t>(timestamp * 1'000'000.0));
    }
    return timestamp_microseconds(capture, mach_absolute_time());
  }

  /** @brief Publish one honest <=4 Hz measured native capture-rate offer. */
  void publish_measured_rate(
    clsp_apple_input_capture &capture,
    const std::uint8_t device_type,
    const std::uint32_t device_id,
    const std::uint32_t generation,
    const std::uint64_t timestamp,
    std::uint64_t &window_start,
    std::uint64_t &last_offer,
    std::uint64_t &window_samples,
    std::uint64_t &previous_sample,
    std::uint32_t &minimum_interval,
    std::uint32_t &maximum_interval,
    umbra::lsp::FixedTelemetryDistribution &spacing,
    const std::uint64_t captured_samples,
    const std::uint32_t maximum_state_rate,
    const std::uint32_t maximum_sensor_rate,
    const std::uint16_t maximum_state_packet_bytes,
    const std::uint16_t maximum_sensor_packet_bytes,
    const std::uint8_t capture_source
  ) noexcept {
    if (window_start == 0U) window_start = timestamp;
    if (previous_sample != 0U && timestamp > previous_sample) {
      const auto interval = static_cast<std::uint32_t>(std::min<std::uint64_t>(UINT32_MAX, timestamp - previous_sample));
      minimum_interval = std::min(minimum_interval, interval);
      maximum_interval = std::max(maximum_interval, interval);
      spacing.record(interval);
    } else if (previous_sample != 0U) {
      spacing.drop(CLSP_NATIVE_TIMING_UNKNOWN_COMPONENT);
    }
    previous_sample = timestamp;
    ++window_samples;
    if (timestamp <= window_start || timestamp - last_offer < 250'000U) return;
    const auto elapsed = timestamp - window_start;
    const auto measured = static_cast<std::uint32_t>(std::min<std::uint64_t>(
      maximum_state_rate,
      window_samples * 1'000'000U / elapsed
    ));
    const auto packet_bytes = static_cast<std::uint64_t>(maximum_state_packet_bytes) + 12U + 16U + 28U;
    const auto spacing_snapshot = spacing.snapshot(
      CLSP_NATIVE_TIMING_AVAILABLE | CLSP_NATIVE_TIMING_CLIENT_MONOTONIC |
      CLSP_NATIVE_TIMING_SAME_ENDPOINT | CLSP_NATIVE_TIMING_PARTIAL_WIRE_BYTES
    );
    clsp_core_publish_device_offer(capture.core, {
      .device_id = device_id,
      .instance_generation = generation,
      .observed_capture_hz = measured,
      .observed_sensor_hz = 0U,
      .minimum_state_rate = 125,
      .maximum_state_rate = maximum_state_rate,
      .minimum_sensor_rate = maximum_sensor_rate == 0U ? 0U : 125U,
      .maximum_sensor_rate = maximum_sensor_rate,
      .captured_samples = captured_samples,
      .effective_wire_bits_per_second = measured * packet_bytes * 8U,
      .state_spacing_count = spacing_snapshot.count,
      .state_spacing_p50_microseconds = spacing_snapshot.p50_microseconds,
      .state_spacing_p95_microseconds = spacing_snapshot.p95_microseconds,
      .state_spacing_p99_microseconds = spacing_snapshot.p99_microseconds,
      .state_spacing_maximum_microseconds = spacing_snapshot.maximum_microseconds,
      .state_spacing_drops = spacing_snapshot.drops,
      .minimum_sample_interval_microseconds = minimum_interval == UINT32_MAX ? 0U : minimum_interval,
      .maximum_sample_interval_microseconds = maximum_interval,
      .timing_flags = spacing_snapshot.flags,
      .maximum_state_packet_bytes = maximum_state_packet_bytes,
      .maximum_sensor_packet_bytes = maximum_sensor_packet_bytes,
      .kind = CLSP_DEVICE_OFFER_RATE_OBSERVED,
      .device_type = device_type,
      .capture_source = capture_source,
    });
    last_offer = timestamp;
    window_start = timestamp;
    window_samples = 0;
    minimum_interval = UINT32_MAX;
    maximum_interval = 0;
  }

  /** @brief Record one independently clocked state or motion callback sample. */
  void record_rate_sample(
    const std::uint64_t timestamp,
    std::uint64_t &window_start,
    std::uint64_t &window_samples,
    std::uint64_t &previous_sample,
    std::uint32_t &minimum_interval,
    std::uint32_t &maximum_interval,
    umbra::lsp::FixedTelemetryDistribution &spacing
  ) noexcept {
    if (window_start == 0U) window_start = timestamp;
    if (previous_sample != 0U && timestamp > previous_sample) {
      const auto interval = static_cast<std::uint32_t>(std::min<std::uint64_t>(UINT32_MAX, timestamp - previous_sample));
      minimum_interval = std::min(minimum_interval, interval);
      maximum_interval = std::max(maximum_interval, interval);
      spacing.record(interval);
    } else if (previous_sample != 0U) {
      spacing.drop(CLSP_NATIVE_TIMING_UNKNOWN_COMPONENT);
    }
    previous_sample = timestamp;
    ++window_samples;
  }

  /** @brief Publish one combined controller offer with independently measured state and sensor rates. */
  void publish_controller_rates(
    clsp_apple_input_capture &capture,
    const std::size_t slot,
    const std::uint64_t timestamp,
    const bool has_motion
  ) noexcept {
    if (timestamp - capture.controller_last_offer[slot] < 250'000U) return;
    const auto state_elapsed = capture.controller_rate_window_start[slot] == 0U ? 0U :
      timestamp - capture.controller_rate_window_start[slot];
    const auto sensor_elapsed = capture.controller_sensor_rate_window_start[slot] == 0U ? 0U :
      timestamp - capture.controller_sensor_rate_window_start[slot];
    const auto state_rate = state_elapsed == 0U ? 0U : static_cast<std::uint32_t>(std::min<std::uint64_t>(
      2'000U,
      capture.controller_window_samples[slot] * 1'000'000U / state_elapsed
    ));
    const auto sensor_rate = sensor_elapsed == 0U ? 0U : static_cast<std::uint32_t>(std::min<std::uint64_t>(
      4'000U,
      capture.controller_sensor_window_samples[slot] * 1'000'000U / sensor_elapsed
    ));
    if (state_rate == 0U && sensor_rate == 0U) return;
    const auto state_wire_bytes = std::uint64_t {88U + 12U + 16U + 28U};
    const auto sensor_wire_bytes = std::uint64_t {36U + 12U + 16U + 28U};
    const auto state_interval = capture.controller_minimum_interval[slot] != UINT32_MAX;
    const auto timing_flags = CLSP_NATIVE_TIMING_AVAILABLE | CLSP_NATIVE_TIMING_CLIENT_MONOTONIC |
                              CLSP_NATIVE_TIMING_SAME_ENDPOINT | CLSP_NATIVE_TIMING_PARTIAL_WIRE_BYTES;
    const auto state_spacing = capture.controller_spacing[slot].snapshot(timing_flags);
    const auto sensor_spacing = capture.controller_sensor_spacing[slot].snapshot(timing_flags);
    clsp_core_publish_device_offer(capture.core, {
      .device_id = static_cast<std::uint32_t>(slot + 1U),
      .instance_generation = capture.controller_generations[slot],
      .observed_capture_hz = state_rate,
      .observed_sensor_hz = sensor_rate,
      .minimum_state_rate = 125U,
      .maximum_state_rate = 2'000U,
      .minimum_sensor_rate = has_motion ? 125U : 0U,
      .maximum_sensor_rate = has_motion ? 4'000U : 0U,
      .captured_samples = capture.controller_samples[slot] + capture.controller_sensor_samples[slot],
      .effective_wire_bits_per_second =
        (static_cast<std::uint64_t>(state_rate) * state_wire_bytes +
         static_cast<std::uint64_t>(sensor_rate) * sensor_wire_bytes * 2U) * 8U,
      .state_spacing_count = state_spacing.count,
      .state_spacing_p50_microseconds = state_spacing.p50_microseconds,
      .state_spacing_p95_microseconds = state_spacing.p95_microseconds,
      .state_spacing_p99_microseconds = state_spacing.p99_microseconds,
      .state_spacing_maximum_microseconds = state_spacing.maximum_microseconds,
      .state_spacing_drops = state_spacing.drops,
      .sensor_spacing_count = sensor_spacing.count,
      .sensor_spacing_p50_microseconds = sensor_spacing.p50_microseconds,
      .sensor_spacing_p95_microseconds = sensor_spacing.p95_microseconds,
      .sensor_spacing_p99_microseconds = sensor_spacing.p99_microseconds,
      .sensor_spacing_maximum_microseconds = sensor_spacing.maximum_microseconds,
      .sensor_spacing_drops = sensor_spacing.drops,
      .minimum_sample_interval_microseconds = state_interval ?
        capture.controller_minimum_interval[slot] :
        capture.controller_sensor_minimum_interval[slot] == UINT32_MAX ? 0U :
          capture.controller_sensor_minimum_interval[slot],
      .maximum_sample_interval_microseconds = state_interval ?
        capture.controller_maximum_interval[slot] : capture.controller_sensor_maximum_interval[slot],
      .timing_flags = timing_flags,
      .maximum_state_packet_bytes = 88U,
      .maximum_sensor_packet_bytes = has_motion ? std::uint16_t {36U} : std::uint16_t {0U},
      .kind = CLSP_DEVICE_OFFER_RATE_OBSERVED,
      .device_type = CLSP_DEVICE_OFFER_CONTROLLER,
      .capture_source = CLSP_DEVICE_CAPTURE_GAME_CONTROLLER,
    });
    capture.controller_last_offer[slot] = timestamp;
    capture.controller_rate_window_start[slot] = timestamp;
    capture.controller_window_samples[slot] = 0U;
    capture.controller_minimum_interval[slot] = UINT32_MAX;
    capture.controller_maximum_interval[slot] = 0U;
    capture.controller_sensor_rate_window_start[slot] = timestamp;
    capture.controller_sensor_window_samples[slot] = 0U;
    capture.controller_sensor_minimum_interval[slot] = UINT32_MAX;
    capture.controller_sensor_maximum_interval[slot] = 0U;
  }

  /** @brief Rebuild one neutral authority baseline after a native hot-plug set changes. */
  [[nodiscard]] bool restart_device_baseline(clsp_apple_input_capture &capture) noexcept {
    if (clsp_core_neutralize_input(capture.core) != CLSP_STATUS_OK ||
        clsp_core_restart_input_baseline(capture.core) != CLSP_STATUS_OK) return false;
    std::fill(capture.keyboard.begin(), capture.keyboard.end(), false);
    std::fill(capture.pointer_buttons.begin(), capture.pointer_buttons.end(), false);
    std::fill(capture.controller_buttons.begin(), capture.controller_buttons.end(), 0U);
    std::fill(capture.touch_active.begin(), capture.touch_active.end(), false);
    return true;
  }

  /** @brief Convert one IOHID absolute timestamp to nonzero monotonic microseconds. */
  [[nodiscard]] std::uint64_t timestamp_microseconds(
    const clsp_apple_input_capture &capture,
    const std::uint64_t timestamp
  ) noexcept {
    if (timestamp == 0 || capture.timebase.denom == 0) {
      return 0;
    }
    const auto quotient = timestamp / capture.timebase.denom;
    const auto remainder = timestamp % capture.timebase.denom;
    const auto nanoseconds = quotient * capture.timebase.numer +
                             remainder * capture.timebase.numer / capture.timebase.denom;
    return std::max<std::uint64_t>(1, nanoseconds / 1'000U);
  }

  /** @brief Submit one physical edge without Objective-C or heap work. */
  void submit_edge(
    clsp_apple_input_capture &capture,
    const std::uint64_t timestamp,
    const std::uint16_t control,
    const std::uint8_t kind
  ) noexcept {
    clsp_input_edge_t edge {
      .sample_time_microseconds = timestamp,
      .control_id = control,
      .kind = kind,
      .reserved_zero = 0,
    };
    (void)clsp_core_submit_input_edge(capture.core, &edge);
  }

  /** @brief Release all locally tracked held state after focus/device/permission loss. */
  void release_all(clsp_apple_input_capture &capture, const std::uint64_t timestamp) noexcept {
    for (std::size_t usage = 0; usage < capture.keyboard.size(); ++usage) {
      if (capture.keyboard[usage]) {
        capture.keyboard[usage] = false;
        submit_edge(capture, timestamp, static_cast<std::uint16_t>(usage), CLSP_INPUT_EDGE_KEY_UP);
      }
    }
    for (std::size_t button = 1; button < capture.pointer_buttons.size(); ++button) {
      if (capture.pointer_buttons[button]) {
        capture.pointer_buttons[button] = false;
        submit_edge(capture, timestamp, static_cast<std::uint16_t>(button), CLSP_INPUT_EDGE_POINTER_BUTTON_UP);
      }
    }
  }

  /** @brief Convert a macOS virtual key code to one USB HID keyboard-page usage. */
  [[nodiscard]] std::uint16_t appkit_hid_usage(const unsigned short key_code) noexcept {
    switch (key_code) {
      case 0: return 0x04; case 11: return 0x05; case 8: return 0x06; case 2: return 0x07;
      case 14: return 0x08; case 3: return 0x09; case 5: return 0x0A; case 4: return 0x0B;
      case 34: return 0x0C; case 38: return 0x0D; case 40: return 0x0E; case 37: return 0x0F;
      case 46: return 0x10; case 45: return 0x11; case 31: return 0x12; case 35: return 0x13;
      case 12: return 0x14; case 15: return 0x15; case 1: return 0x16; case 17: return 0x17;
      case 32: return 0x18; case 9: return 0x19; case 13: return 0x1A; case 7: return 0x1B;
      case 16: return 0x1C; case 6: return 0x1D;
      case 18: return 0x1E; case 19: return 0x1F; case 20: return 0x20; case 21: return 0x21;
      case 23: return 0x22; case 22: return 0x23; case 26: return 0x24; case 28: return 0x25;
      case 25: return 0x26; case 29: return 0x27;
      case 36: return 0x28; case 53: return 0x29; case 51: return 0x2A; case 48: return 0x2B;
      case 49: return 0x2C; case 27: return 0x2D; case 24: return 0x2E; case 33: return 0x2F;
      case 30: return 0x30; case 42: return 0x31; case 41: return 0x33; case 39: return 0x34;
      case 50: return 0x35; case 43: return 0x36; case 47: return 0x37; case 44: return 0x38;
      case 57: return 0x39;
      case 122: return 0x3A; case 120: return 0x3B; case 99: return 0x3C; case 118: return 0x3D;
      case 96: return 0x3E; case 97: return 0x3F; case 98: return 0x40; case 100: return 0x41;
      case 101: return 0x42; case 109: return 0x43; case 103: return 0x44; case 111: return 0x45;
      case 123: return 0x50; case 124: return 0x4F; case 125: return 0x51; case 126: return 0x52;
      case 56: return 0xE1; case 60: return 0xE5; case 59: return 0xE0; case 62: return 0xE4;
      case 58: return 0xE2; case 61: return 0xE6; case 55: return 0xE3; case 54: return 0xE7;
      default: return 0;
    }
  }

  /** @brief Convert one AppKit uptime timestamp to nonzero monotonic microseconds. */
  [[nodiscard]] std::uint64_t appkit_timestamp(const clsp_apple_input_capture &capture, NSEvent *event) noexcept {
    const auto seconds = event.timestamp;
    if (seconds > 0) {
      return std::max<std::uint64_t>(1U, static_cast<std::uint64_t>(seconds * 1'000'000.0));
    }
    return timestamp_microseconds(capture, mach_absolute_time());
  }

  /** @brief Record one native pointer callback and publish measured source-rate telemetry. */
  void record_pointer_sample(clsp_apple_input_capture &capture, const std::uint64_t timestamp) noexcept {
    ++capture.pointer_samples;
    publish_measured_rate(
      capture,
      CLSP_DEVICE_OFFER_POINTER,
      1U,
      std::max<std::uint32_t>(1U, capture.pointer_generation),
      timestamp,
      capture.pointer_rate_window_start,
      capture.pointer_last_offer,
      capture.pointer_window_samples,
      capture.pointer_previous_sample,
      capture.pointer_minimum_interval,
      capture.pointer_maximum_interval,
      capture.pointer_spacing,
      capture.pointer_samples,
      16'000U,
      0U,
      56U,
      0U,
      capture.capture_source
    );
  }

  /** @brief Submit one AppKit keyboard transition using native held-state ownership. */
  void handle_appkit_key(
    clsp_apple_input_capture &capture,
    NSEvent *event,
    const std::uint64_t timestamp
  ) noexcept {
    const auto usage = appkit_hid_usage(event.keyCode);
    if (usage == 0U || usage >= capture.keyboard.size()) return;
    if (event.type == NSEventTypeFlagsChanged) {
      if (usage == 0x39U) {
        submit_edge(capture, timestamp, usage, CLSP_INPUT_EDGE_KEY_DOWN);
        submit_edge(capture, timestamp, usage, CLSP_INPUT_EDGE_KEY_UP);
        return;
      }
      const auto pressed = !capture.keyboard[usage];
      capture.keyboard[usage] = pressed;
      submit_edge(
        capture,
        timestamp,
        usage,
        pressed ? CLSP_INPUT_EDGE_KEY_DOWN : CLSP_INPUT_EDGE_KEY_UP
      );
      return;
    }
    const auto pressed = event.type == NSEventTypeKeyDown;
    if ((pressed && event.isARepeat) || capture.keyboard[usage] == pressed) return;
    capture.keyboard[usage] = pressed;
    submit_edge(
      capture,
      timestamp,
      usage,
      pressed ? CLSP_INPUT_EDGE_KEY_DOWN : CLSP_INPUT_EDGE_KEY_UP
    );
  }

  /** @brief Submit one AppKit pointer-button transition using native held-state ownership. */
  void handle_appkit_button(
    clsp_apple_input_capture &capture,
    NSEvent *event,
    const std::uint64_t timestamp,
    const bool pressed
  ) noexcept {
    const auto native_button = event.buttonNumber;
    if (native_button < 0 || native_button >= 5) return;
    const auto button = static_cast<std::size_t>(native_button + 1);
    if (capture.pointer_buttons[button] == pressed) return;
    capture.pointer_buttons[button] = pressed;
    submit_edge(
      capture,
      timestamp,
      static_cast<std::uint16_t>(button),
      pressed ? CLSP_INPUT_EDGE_POINTER_BUTTON_DOWN : CLSP_INPUT_EDGE_POINTER_BUTTON_UP
    );
  }

  /** @brief Submit one accumulated AppKit motion or scroll sample to the native composer. */
  void handle_appkit_pointer(
    clsp_apple_input_capture &capture,
    NSEvent *event,
    const std::uint64_t timestamp,
    const bool scroll
  ) noexcept {
    record_pointer_sample(capture, timestamp);
    clsp_pointer_sample_t sample {.sample_time_microseconds = timestamp};
    if (scroll) {
      capture.vertical_scroll_remainder += event.scrollingDeltaY;
      capture.horizontal_scroll_remainder += event.scrollingDeltaX;
      sample.vertical_scroll = static_cast<std::int64_t>(capture.vertical_scroll_remainder);
      sample.horizontal_scroll = static_cast<std::int64_t>(capture.horizontal_scroll_remainder);
      capture.vertical_scroll_remainder -= static_cast<double>(sample.vertical_scroll);
      capture.horizontal_scroll_remainder -= static_cast<double>(sample.horizontal_scroll);
    } else {
      capture.pointer_x_remainder += event.deltaX;
      capture.pointer_y_remainder += event.deltaY;
      sample.delta_x = static_cast<std::int64_t>(capture.pointer_x_remainder);
      sample.delta_y = static_cast<std::int64_t>(capture.pointer_y_remainder);
      capture.pointer_x_remainder -= static_cast<double>(sample.delta_x);
      capture.pointer_y_remainder -= static_cast<double>(sample.delta_y);
    }
    if (sample.delta_x != 0 || sample.delta_y != 0 ||
        sample.vertical_scroll != 0 || sample.horizontal_scroll != 0) {
      (void)clsp_core_submit_pointer(capture.core, &sample);
    }
  }

  /** @brief Handle one focused-window AppKit event without crossing the Swift ABI. */
  void handle_appkit_event(clsp_apple_input_capture &capture, NSEvent *event) noexcept {
    if (event == nil || capture.appkit_window == nil || event.window != capture.appkit_window ||
        !capture.appkit_window.isKeyWindow || !capture.active.load(std::memory_order_acquire)) return;
    const auto timestamp = appkit_timestamp(capture, event);
    switch (event.type) {
      case NSEventTypeMouseMoved:
      case NSEventTypeLeftMouseDragged:
      case NSEventTypeRightMouseDragged:
      case NSEventTypeOtherMouseDragged:
        handle_appkit_pointer(capture, event, timestamp, false);
        return;
      case NSEventTypeScrollWheel:
        handle_appkit_pointer(capture, event, timestamp, true);
        return;
      case NSEventTypeLeftMouseDown:
      case NSEventTypeRightMouseDown:
      case NSEventTypeOtherMouseDown:
        handle_appkit_button(capture, event, timestamp, true);
        return;
      case NSEventTypeLeftMouseUp:
      case NSEventTypeRightMouseUp:
      case NSEventTypeOtherMouseUp:
        handle_appkit_button(capture, event, timestamp, false);
        return;
      case NSEventTypeKeyDown:
      case NSEventTypeKeyUp:
      case NSEventTypeFlagsChanged:
        handle_appkit_key(capture, event, timestamp);
        return;
      default:
        return;
    }
  }

  /** @brief Return the frozen digital-button mask for one extended profile. */
  [[nodiscard]] std::uint32_t controller_button_mask(GCExtendedGamepad *gamepad) noexcept {
    using lumen::lsp::input_plane::controller_button_bit;
    std::uint32_t mask = 0;
    auto set = [&mask](const unsigned bit, GCControllerButtonInput *button) noexcept {
      if (button != nil && button.isPressed) mask |= std::uint32_t {1} << bit;
    };
    auto bit = [](const controller_button_bit value) noexcept {
      return static_cast<unsigned>(value);
    };
    set(bit(controller_button_bit::south), gamepad.buttonA);
    set(bit(controller_button_bit::east), gamepad.buttonB);
    set(bit(controller_button_bit::west), gamepad.buttonX);
    set(bit(controller_button_bit::north), gamepad.buttonY);
    set(bit(controller_button_bit::left_shoulder), gamepad.leftShoulder);
    set(bit(controller_button_bit::right_shoulder), gamepad.rightShoulder);
    set(bit(controller_button_bit::left_stick), gamepad.leftThumbstickButton);
    set(bit(controller_button_bit::right_stick), gamepad.rightThumbstickButton);
    set(bit(controller_button_bit::menu), gamepad.buttonMenu);
    set(bit(controller_button_bit::view), gamepad.buttonOptions);
    set(bit(controller_button_bit::guide), gamepad.buttonHome);
    set(bit(controller_button_bit::dpad_up), gamepad.dpad.up);
    set(bit(controller_button_bit::dpad_down), gamepad.dpad.down);
    set(bit(controller_button_bit::dpad_left), gamepad.dpad.left);
    set(bit(controller_button_bit::dpad_right), gamepad.dpad.right);
    return mask;
  }

  /** @brief Submit one exact controller lifecycle/button edge. */
  void submit_controller_edge(
    clsp_apple_input_capture &capture,
    const std::size_t slot,
    const std::uint64_t timestamp,
    const std::uint8_t kind,
    const std::uint16_t control
  ) noexcept {
    clsp_controller_edge_t edge {
      .sample_time_microseconds = timestamp,
      .controller_id = static_cast<std::uint32_t>(slot + 1U),
      .instance_generation = capture.controller_generations[slot],
      .control_id = control,
      .kind = kind,
    };
    (void)clsp_core_submit_controller_edge(capture.core, &edge);
  }

  /** @brief Normalize an analog stick value to signed 16-bit wire range. */
  [[nodiscard]] std::int16_t axis(const float value) noexcept {
    return static_cast<std::int16_t>(std::clamp(value, -1.0F, 1.0F) * 32'767.0F);
  }

  /** @brief Normalize an analog trigger to unsigned 8-bit wire range. */
  [[nodiscard]] std::uint8_t trigger(const float value) noexcept {
    return static_cast<std::uint8_t>(std::clamp(value, 0.0F, 1.0F) * 255.0F);
  }

  /** @brief Convert normalized signed touch coordinates to Q0.32. */
  [[nodiscard]] std::uint32_t touch_coordinate(const float value) noexcept {
    const auto normalized = (std::clamp(value, -1.0F, 1.0F) + 1.0F) * 0.5F;
    return static_cast<std::uint32_t>(normalized * static_cast<double>(UINT32_MAX));
  }

  /** @brief Submit exact controller touch lifecycle and coordinates. */
  void submit_touch(
    clsp_apple_input_capture &capture,
    const std::size_t slot,
    GCExtendedGamepad *profile,
    const std::uint8_t kind,
    const float x,
    const float y,
    const float pressure
  ) noexcept {
    const auto timestamp = controller_timestamp(capture, profile.lastEventTimestamp);
    clsp_controller_touch_edge_t edge {
      .sample_time_microseconds = timestamp,
      .controller_id = static_cast<std::uint32_t>(slot + 1U),
      .contact_id = static_cast<std::uint32_t>(slot + 1U),
      .instance_generation = capture.controller_generations[slot],
      .kind = kind,
    };
    clsp_controller_touch_state_t state {
      .sample_time_microseconds = timestamp,
      .controller_id = static_cast<std::uint32_t>(slot + 1U),
      .contact_id = static_cast<std::uint32_t>(slot + 1U),
      .instance_generation = capture.controller_generations[slot],
      .x = touch_coordinate(x),
      .y = touch_coordinate(y),
      .pressure = static_cast<std::uint32_t>(std::clamp(pressure, 0.0F, 1.0F) * static_cast<double>(UINT32_MAX)),
    };
    if (kind == 9) {
      (void)clsp_core_submit_controller_touch_edge(capture.core, &edge);
      (void)clsp_core_submit_controller_touch_state(capture.core, &state);
    } else if (kind == 10 || kind == 11) {
      (void)clsp_core_submit_controller_touch_state(capture.core, &state);
      (void)clsp_core_submit_controller_touch_edge(capture.core, &edge);
    } else {
      (void)clsp_core_submit_controller_touch_state(capture.core, &state);
    }
  }

  /** @brief Create one reusable public CoreHaptics continuous player. */
  void prepare_haptics(clsp_apple_input_capture &capture, const std::size_t slot, GCController *controller) noexcept {
    if (controller.haptics == nil) return;
    CHHapticEngine *engine = [controller.haptics createEngineWithLocality:GCHapticsLocalityDefault];
    if (engine == nil) return;
    NSError *error = nil;
    if (![engine startAndReturnError:&error]) return;
    CHHapticEventParameter *intensity = [[CHHapticEventParameter alloc]
      initWithParameterID:CHHapticEventParameterIDHapticIntensity value:0.0F];
    CHHapticEvent *event = [[CHHapticEvent alloc]
      initWithEventType:CHHapticEventTypeHapticContinuous
      parameters:@[intensity]
      relativeTime:0
      duration:GCHapticDurationInfinite];
    CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:@[event] parameters:@[] error:&error];
    id<CHHapticAdvancedPatternPlayer> player = pattern == nil ? nil : [engine createAdvancedPlayerWithPattern:pattern error:&error];
    if (player == nil || ![player startAtTime:0 error:&error]) {
      [engine stopWithCompletionHandler:nil];
      return;
    }
    capture.haptic_engines[slot] = engine;
    capture.haptic_players[slot] = player;
  }

  /** @brief Update the reused public haptic player intensity. */
  [[nodiscard]] bool set_haptic_intensity(
    clsp_apple_input_capture &capture,
    const std::size_t slot,
    const std::uint16_t low,
    const std::uint16_t high
  ) noexcept {
    id<CHHapticAdvancedPatternPlayer> player = capture.haptic_players[slot];
    if (player == nil) return false;
    const auto value = std::max(low, high) / 65'535.0F;
    CHHapticDynamicParameter *parameter = [[CHHapticDynamicParameter alloc]
      initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:value relativeTime:0];
    NSError *error = nil;
    return [player sendParameters:@[parameter] atTime:0 error:&error];
  }

  /** @brief Find a native slot by controller identity. */
  [[nodiscard]] std::size_t controller_slot(
    const clsp_apple_input_capture &capture,
    GCController *controller
  ) noexcept {
    for (std::size_t index = 0; index < 16; ++index) {
      if (capture.controllers[index] == controller) return index;
    }
    return 16;
  }

  /** @brief Install GameController value and motion handlers on the dedicated native queue. */
  void connect_controller(clsp_apple_input_capture &capture, GCController *controller) noexcept {
    if (controller == nil || controller.extendedGamepad == nil || controller_slot(capture, controller) != 16) return;
    std::size_t slot = 16;
    for (std::size_t index = 0; index < 16; ++index) {
      if (capture.controllers[index] == nil) { slot = index; break; }
    }
    if (slot == 16) return;
    capture.controllers[slot] = controller;
    capture.controller_generations[slot] = capture.controller_generations[slot] == UINT32_MAX ? 1U : capture.controller_generations[slot] + 1U;
    capture.controller_buttons[slot] = 0;
    capture.controller_rate_window_start[slot] = 0;
    capture.controller_last_offer[slot] = 0;
    capture.controller_samples[slot] = 0;
    capture.controller_window_samples[slot] = 0;
    capture.controller_previous_sample[slot] = 0;
    capture.controller_minimum_interval[slot] = UINT32_MAX;
    capture.controller_maximum_interval[slot] = 0;
    capture.controller_spacing[slot] = {};
    capture.controller_sensor_rate_window_start[slot] = 0;
    capture.controller_sensor_samples[slot] = 0;
    capture.controller_sensor_window_samples[slot] = 0;
    capture.controller_sensor_previous_sample[slot] = 0;
    capture.controller_sensor_minimum_interval[slot] = UINT32_MAX;
    capture.controller_sensor_maximum_interval[slot] = 0;
    capture.controller_sensor_spacing[slot] = {};
    capture.latest_output_sequences[slot] = 0;
    controller.handlerQueue = capture.queue;
    GCExtendedGamepad *gamepad = controller.extendedGamepad;
    GCControllerTouchpad *touchpad = gamepad.allTouchpads.anyObject;
    const auto arrival_time = controller_timestamp(capture, gamepad.lastEventTimestamp);
    const auto generation = capture.controller_generations[slot];
    const auto device_id = static_cast<std::uint32_t>(slot + 1U);
    clsp_core_observe_input_device(
      capture.core,
      3U,
      device_id,
      generation,
      true,
      controller.motion == nil ? 0U : 3U
    );
    if (touchpad != nil) {
      clsp_core_observe_input_device(capture.core, 4U, device_id, generation, true, 0U);
    }
    submit_controller_edge(capture, slot, arrival_time, 5, 1);
    prepare_haptics(capture, slot, controller);
    clsp_core_publish_device_offer(capture.core, {
      .device_id = static_cast<std::uint32_t>(slot + 1U),
      .instance_generation = capture.controller_generations[slot],
      .captured_samples = capture.controller_samples[slot],
      .observed_capture_hz = 0,
      .minimum_state_rate = 125,
      .maximum_state_rate = 2'000,
      .minimum_sensor_rate = controller.motion == nil ? 0U : 125U,
      .maximum_sensor_rate = controller.motion == nil ? 0U : 4'000U,
      .timing_flags = CLSP_NATIVE_TIMING_AVAILABLE | CLSP_NATIVE_TIMING_CLIENT_MONOTONIC |
                      CLSP_NATIVE_TIMING_SAME_ENDPOINT | CLSP_NATIVE_TIMING_PARTIAL_WIRE_BYTES,
      .maximum_state_packet_bytes = 88,
      .maximum_sensor_packet_bytes = controller.motion == nil ? std::uint16_t {0} : std::uint16_t {36},
      .kind = CLSP_DEVICE_OFFER_ARRIVED,
      .device_type = CLSP_DEVICE_OFFER_CONTROLLER,
      .capture_source = CLSP_DEVICE_CAPTURE_GAME_CONTROLLER,
    });

    gamepad.valueChangedHandler = ^(GCExtendedGamepad *profile, GCControllerElement *element) {
      (void)element;
      if (!capture.active.load(std::memory_order_acquire) || capture.controllers[slot] != controller) return;
      const auto timestamp = controller_timestamp(capture, profile.lastEventTimestamp);
      const auto next_buttons = controller_button_mask(profile);
      const auto changed = capture.controller_buttons[slot] ^ next_buttons;
      for (unsigned bit = 0; bit < 32; ++bit) {
        if ((changed & (std::uint32_t {1} << bit)) != 0) {
          submit_controller_edge(capture, slot, timestamp, (next_buttons & (std::uint32_t {1} << bit)) != 0 ? 7 : 8, static_cast<std::uint16_t>(bit));
        }
      }
      capture.controller_buttons[slot] = next_buttons;
      clsp_controller_state_t state {
        .sample_time_microseconds = timestamp,
        .controller_id = static_cast<std::uint32_t>(slot + 1U),
        .instance_generation = capture.controller_generations[slot],
        .left_trigger = trigger(profile.leftTrigger.value),
        .right_trigger = trigger(profile.rightTrigger.value),
        .left_stick_x = axis(profile.leftThumbstick.xAxis.value),
        .left_stick_y = axis(profile.leftThumbstick.yAxis.value),
        .right_stick_x = axis(profile.rightThumbstick.xAxis.value),
        .right_stick_y = axis(profile.rightThumbstick.yAxis.value),
      };
      ++capture.controller_samples[slot];
      record_rate_sample(
        timestamp,
        capture.controller_rate_window_start[slot],
        capture.controller_window_samples[slot],
        capture.controller_previous_sample[slot],
        capture.controller_minimum_interval[slot],
        capture.controller_maximum_interval[slot],
        capture.controller_spacing[slot]
      );
      publish_controller_rates(capture, slot, timestamp, controller.motion != nil);
      (void)clsp_core_submit_controller_state(capture.core, &state);
    };

    if (controller.motion != nil) {
      if (controller.motion.sensorsRequireManualActivation) controller.motion.sensorsActive = YES;
      controller.motion.valueChangedHandler = ^(GCMotion *motion) {
        if (!capture.active.load(std::memory_order_acquire) || capture.controllers[slot] != controller) return;
        const auto timestamp = controller_timestamp(capture, 0);
        ++capture.controller_sensor_samples[slot];
        record_rate_sample(
          timestamp,
          capture.controller_sensor_rate_window_start[slot],
          capture.controller_sensor_window_samples[slot],
          capture.controller_sensor_previous_sample[slot],
          capture.controller_sensor_minimum_interval[slot],
          capture.controller_sensor_maximum_interval[slot],
          capture.controller_sensor_spacing[slot]
        );
        publish_controller_rates(capture, slot, timestamp, true);
        const auto rotation = motion.rotationRate;
        clsp_controller_sensor_t gyro {
          .sample_time_microseconds = timestamp,
          .controller_id = static_cast<std::uint32_t>(slot + 1U),
          .instance_generation = capture.controller_generations[slot],
          .x = static_cast<float>(rotation.x), .y = static_cast<float>(rotation.y), .z = static_cast<float>(rotation.z),
          .sensor_type = 1,
        };
        (void)clsp_core_submit_controller_sensor(capture.core, &gyro);
        const auto acceleration = motion.acceleration;
        clsp_controller_sensor_t accel {
          .sample_time_microseconds = timestamp,
          .controller_id = static_cast<std::uint32_t>(slot + 1U),
          .instance_generation = capture.controller_generations[slot],
          .x = static_cast<float>(acceleration.x), .y = static_cast<float>(acceleration.y), .z = static_cast<float>(acceleration.z),
          .sensor_type = 2,
        };
        (void)clsp_core_submit_controller_sensor(capture.core, &accel);
      };
    }
    if (touchpad != nil) {
      touchpad.reportsAbsoluteTouchSurfaceValues = YES;
      touchpad.touchDown = ^(GCControllerTouchpad *pad, float x, float y, float button, BOOL pressed) {
        (void)pad; (void)pressed;
        if (capture.active.load(std::memory_order_acquire) && capture.controllers[slot] == controller) {
          capture.touch_active[slot] = true; capture.touch_x[slot] = x; capture.touch_y[slot] = y; capture.touch_pressure[slot] = button;
          submit_touch(capture, slot, gamepad, 9, x, y, button);
        }
      };
      touchpad.touchMoved = ^(GCControllerTouchpad *pad, float x, float y, float button, BOOL pressed) {
        (void)pad; (void)pressed;
        if (capture.active.load(std::memory_order_acquire) && capture.controllers[slot] == controller) {
          capture.touch_x[slot] = x; capture.touch_y[slot] = y; capture.touch_pressure[slot] = button;
          submit_touch(capture, slot, gamepad, 0, x, y, button);
        }
      };
      touchpad.touchUp = ^(GCControllerTouchpad *pad, float x, float y, float button, BOOL pressed) {
        (void)pad; (void)pressed;
        if (capture.active.load(std::memory_order_acquire) && capture.controllers[slot] == controller) {
          capture.touch_x[slot] = x; capture.touch_y[slot] = y; capture.touch_pressure[slot] = button;
          submit_touch(capture, slot, gamepad, 10, x, y, button);
          capture.touch_active[slot] = false;
        }
      };
    }
  }

  /** @brief Quiesce one controller slot and emit releases/removal before retirement. */
  void disconnect_controller(clsp_apple_input_capture &capture, GCController *controller) noexcept {
    const auto slot = controller_slot(capture, controller);
    if (slot == 16) return;
    const auto timestamp = controller_timestamp(capture, controller.extendedGamepad.lastEventTimestamp);
    const auto buttons = capture.controller_buttons[slot];
    for (unsigned bit = 0; bit < 32; ++bit) {
      if ((buttons & (std::uint32_t {1} << bit)) != 0) submit_controller_edge(capture, slot, timestamp, 8, static_cast<std::uint16_t>(bit));
    }
    controller.extendedGamepad.valueChangedHandler = nil;
    if (controller.motion != nil) {
      controller.motion.valueChangedHandler = nil;
      if (controller.motion.sensorsRequireManualActivation) controller.motion.sensorsActive = NO;
    }
    for (GCControllerTouchpad *touchpad in controller.extendedGamepad.allTouchpads) {
      touchpad.touchDown = nil;
      touchpad.touchMoved = nil;
      touchpad.touchUp = nil;
    }
    if (capture.touch_active[slot]) {
      submit_touch(capture, slot, controller.extendedGamepad, 11, capture.touch_x[slot], capture.touch_y[slot], capture.touch_pressure[slot]);
      capture.touch_active[slot] = false;
    }
    submit_controller_edge(capture, slot, timestamp, 6, 0);
    const auto device_id = static_cast<std::uint32_t>(slot + 1U);
    const auto generation = capture.controller_generations[slot];
    if (controller.extendedGamepad.allTouchpads.count != 0U) {
      clsp_core_observe_input_device(capture.core, 4U, device_id, generation, false, 0U);
    }
    clsp_core_observe_input_device(capture.core, 3U, device_id, generation, false, 0U);
    const auto timing_flags = CLSP_NATIVE_TIMING_AVAILABLE | CLSP_NATIVE_TIMING_CLIENT_MONOTONIC |
                              CLSP_NATIVE_TIMING_SAME_ENDPOINT | CLSP_NATIVE_TIMING_PARTIAL_WIRE_BYTES;
    const auto state_spacing = capture.controller_spacing[slot].snapshot(timing_flags);
    const auto sensor_spacing = capture.controller_sensor_spacing[slot].snapshot(timing_flags);
    clsp_core_publish_device_offer(capture.core, {
      .device_id = device_id,
      .instance_generation = generation,
      .captured_samples = capture.controller_samples[slot] + capture.controller_sensor_samples[slot],
      .state_spacing_count = state_spacing.count,
      .state_spacing_p50_microseconds = state_spacing.p50_microseconds,
      .state_spacing_p95_microseconds = state_spacing.p95_microseconds,
      .state_spacing_p99_microseconds = state_spacing.p99_microseconds,
      .state_spacing_maximum_microseconds = state_spacing.maximum_microseconds,
      .state_spacing_drops = state_spacing.drops,
      .sensor_spacing_count = sensor_spacing.count,
      .sensor_spacing_p50_microseconds = sensor_spacing.p50_microseconds,
      .sensor_spacing_p95_microseconds = sensor_spacing.p95_microseconds,
      .sensor_spacing_p99_microseconds = sensor_spacing.p99_microseconds,
      .sensor_spacing_maximum_microseconds = sensor_spacing.maximum_microseconds,
      .sensor_spacing_drops = sensor_spacing.drops,
      .timing_flags = timing_flags,
      .kind = CLSP_DEVICE_OFFER_REMOVED,
      .device_type = CLSP_DEVICE_OFFER_CONTROLLER,
      .capture_source = CLSP_DEVICE_CAPTURE_GAME_CONTROLLER,
    });
    if (capture.haptic_players[slot] != nil) {
      [capture.haptic_players[slot] stopAtTime:0 error:nil];
      capture.haptic_players[slot] = nil;
    }
    if (capture.haptic_engines[slot] != nil) {
      [capture.haptic_engines[slot] stopWithCompletionHandler:nil];
      capture.haptic_engines[slot] = nil;
    }
    if ([controller.extendedGamepad isKindOfClass:GCDualSenseGamepad.class]) {
      GCDualSenseGamepad *dual_sense = static_cast<GCDualSenseGamepad *>(controller.extendedGamepad);
      [dual_sense.leftTrigger setModeOff];
      [dual_sense.rightTrigger setModeOff];
    }
    capture.controller_buttons[slot] = 0;
    capture.controllers[slot] = nil;
  }

  /** @brief Apply one DualSense positional adaptive-trigger program. */
  [[nodiscard]] bool apply_adaptive_trigger(
    GCDualSenseAdaptiveTrigger *trigger,
    const std::uint8_t type,
    const std::uint8_t *values
  ) noexcept {
    if (trigger == nil) return false;
    if (type == 0) {
      [trigger setModeOff];
      return true;
    }
    if (type == 1) {
      GCDualSenseAdaptiveTriggerPositionalResistiveStrengths strengths {};
      for (std::size_t index = 0; index < 10; ++index) strengths.values[index] = values[index] / 255.0F;
      [trigger setModeFeedbackWithResistiveStrengths:strengths];
      return true;
    }
    return false;
  }

  /** @brief Apply a validated LSPG payload on the controller handler queue. */
  [[nodiscard]] std::uint8_t apply_lspg(
    clsp_apple_input_capture &capture,
    const std::span<const std::uint8_t> bytes
  ) noexcept {
    using namespace lumen::lsp::input_plane;
    const auto parsed = parse_lspg(bytes);
    if (!parsed || parsed.controller_id == 0 || parsed.controller_id > 16) {
      return static_cast<std::uint8_t>(controller_command_status::failed);
    }
    const auto slot = parsed.controller_id - 1U;
    GCController *controller = capture.controllers[slot];
    if (controller == nil || capture.controller_generations[slot] != parsed.instance_generation) {
      return static_cast<std::uint8_t>(controller_command_status::stale_generation);
    }
    if (parsed.subtype == lspg_subtype::latest_state) {
      if (parsed.sequence <= capture.latest_output_sequences[slot]) return static_cast<std::uint8_t>(controller_command_status::success);
      controller_latest_state latest;
      if (decode_controller_latest(parsed, latest) != lspg_error::none) return static_cast<std::uint8_t>(controller_command_status::failed);
      if (controller.light != nil) {
        controller.light.color = [[GCColor alloc]
          initWithRed:latest.led_red / 255.0F
          green:latest.led_green / 255.0F
          blue:latest.led_blue / 255.0F];
      }
      (void)set_haptic_intensity(capture, slot, latest.low_frequency_rumble, latest.high_frequency_rumble);
      capture.latest_output_sequences[slot] = parsed.sequence;
      return static_cast<std::uint8_t>(controller_command_status::success);
    }
    if (parsed.subtype != lspg_subtype::command) return static_cast<std::uint8_t>(controller_command_status::failed);
    for (std::size_t index = 0; index < capture.command_sequences.size(); ++index) {
      if (capture.command_sequences[index] == parsed.sequence &&
          capture.command_controller_ids[index] == parsed.controller_id &&
          capture.command_generations[index] == parsed.instance_generation) {
        return capture.command_statuses[index];
      }
    }

    controller_command command;
    if (decode_controller_command(parsed, command) != lspg_error::none) return static_cast<std::uint8_t>(controller_command_status::failed);
    auto status = controller_command_status::unsupported;
    switch (command.kind) {
      case controller_command_kind::motion_sensor:
        if (command.parameter_length == 4 && command.parameters[1] == 0 && controller.motion != nil) {
          const auto rate = lumen::lsp::wire::read_be<std::uint16_t>(std::span<const std::uint8_t> {command.parameters}.subspan(2, 2));
          if (command.parameters[0] >= 1 && command.parameters[0] <= 2 && controller.motion.sensorsRequireManualActivation) {
            controller.motion.sensorsActive = rate != 0;
            status = controller_command_status::success;
          } else if (command.parameters[0] >= 1 && command.parameters[0] <= 2) {
            status = controller_command_status::success;
          }
        }
        break;
      case controller_command_kind::player_slot:
        if (command.parameter_length == 1 && command.parameters[0] <= 3) {
          controller.playerIndex = static_cast<GCControllerPlayerIndex>(command.parameters[0]);
          status = controller_command_status::success;
        }
        break;
      case controller_command_kind::adaptive_trigger:
        if (command.parameter_length == 23 && [controller.extendedGamepad isKindOfClass:GCDualSenseGamepad.class]) {
          GCDualSenseGamepad *dual_sense = static_cast<GCDualSenseGamepad *>(controller.extendedGamepad);
          const auto flags = command.parameters[0];
          const auto left = (flags & 1U) == 0 || apply_adaptive_trigger(dual_sense.leftTrigger, command.parameters[1], command.parameters.data() + 3);
          const auto right = (flags & 2U) == 0 || apply_adaptive_trigger(dual_sense.rightTrigger, command.parameters[2], command.parameters.data() + 13);
          status = left && right ? controller_command_status::success : controller_command_status::unsupported;
        }
        break;
      case controller_command_kind::haptic_waveform:
        if (command.parameter_length == 4) {
          const auto left = lumen::lsp::wire::read_be<std::uint16_t>(std::span<const std::uint8_t> {command.parameters}.first<2>());
          const auto right = lumen::lsp::wire::read_be<std::uint16_t>(std::span<const std::uint8_t> {command.parameters}.subspan(2, 2));
          status = set_haptic_intensity(capture, slot, left, right) ?
                     controller_command_status::success : controller_command_status::unsupported;
        }
        break;
    }
    const auto cache = capture.next_command_cache++ % capture.command_sequences.size();
    capture.command_sequences[cache] = parsed.sequence;
    capture.command_controller_ids[cache] = parsed.controller_id;
    capture.command_generations[cache] = parsed.instance_generation;
    capture.command_statuses[cache] = static_cast<std::uint8_t>(status);
    return capture.command_statuses[cache];
  }

  /** @brief Receive one public IOHID value callback on the dedicated native queue. */
  void input_value_callback(
    void *context,
    const IOReturn result,
    void *sender,
    IOHIDValueRef value
  ) noexcept {
    (void)sender;
    auto *capture = static_cast<clsp_apple_input_capture *>(context);
    if (capture == nullptr || value == nullptr || result != kIOReturnSuccess ||
        !capture->active.load(std::memory_order_acquire)) {
      return;
    }
    const auto timestamp = timestamp_microseconds(*capture, IOHIDValueGetTimeStamp(value));
    IOHIDElementRef element = IOHIDValueGetElement(value);
    if (timestamp == 0 || element == nullptr) {
      return;
    }
    const auto page = IOHIDElementGetUsagePage(element);
    const auto usage = IOHIDElementGetUsage(element);
    const auto integer = IOHIDValueGetIntegerValue(value);

    if (page == kHIDPage_KeyboardOrKeypad && usage > 0 && usage < capture->keyboard.size()) {
      const auto pressed = integer != 0;
      if (capture->keyboard[usage] == pressed) {
        return;
      }
      capture->keyboard[usage] = pressed;
      submit_edge(
        *capture,
        timestamp,
        static_cast<std::uint16_t>(usage),
        pressed ? CLSP_INPUT_EDGE_KEY_DOWN : CLSP_INPUT_EDGE_KEY_UP
      );
      return;
    }
    if (page == kHIDPage_Button && usage > 0 && usage < capture->pointer_buttons.size()) {
      const auto pressed = integer != 0;
      if (capture->pointer_buttons[usage] == pressed) {
        return;
      }
      capture->pointer_buttons[usage] = pressed;
      submit_edge(
        *capture,
        timestamp,
        static_cast<std::uint16_t>(usage),
        pressed ? CLSP_INPUT_EDGE_POINTER_BUTTON_DOWN : CLSP_INPUT_EDGE_POINTER_BUTTON_UP
      );
      return;
    }

    clsp_pointer_sample_t sample {.sample_time_microseconds = timestamp};
    if (page == kHIDPage_GenericDesktop && usage == kHIDUsage_GD_X) {
      sample.delta_x = integer;
    } else if (page == kHIDPage_GenericDesktop && usage == kHIDUsage_GD_Y) {
      sample.delta_y = integer;
    } else if (page == kHIDPage_GenericDesktop && usage == kHIDUsage_GD_Wheel) {
      sample.vertical_scroll = integer;
    } else if (page == kHIDPage_Consumer && usage == kHIDUsage_Csmr_ACPan) {
      sample.horizontal_scroll = integer;
    } else {
      return;
    }
    record_pointer_sample(*capture, timestamp);
    (void)clsp_core_submit_pointer(capture->core, &sample);
  }

  /** @brief Publish a real IOHID aggregate source arrival generation. */
  void device_arrived_callback(
    void *context,
    const IOReturn result,
    void *sender,
    IOHIDDeviceRef device
  ) noexcept {
    (void)sender;
    auto *capture = static_cast<clsp_apple_input_capture *>(context);
    if (capture == nullptr || device == nullptr || result != kIOReturnSuccess ||
        !capture->active.load(std::memory_order_acquire)) return;
    if (capture->pointer_generation != 0U) return;
    capture->pointer_generation = 1U;
    capture->pointer_samples = 0;
    capture->pointer_window_samples = 0;
    capture->pointer_rate_window_start = 0;
    capture->pointer_last_offer = 0;
    capture->pointer_previous_sample = 0;
    capture->pointer_minimum_interval = UINT32_MAX;
    capture->pointer_maximum_interval = 0;
    capture->pointer_spacing = {};
    clsp_core_observe_input_device(capture->core, 2U, 1U, capture->pointer_generation, true, 0U);
    clsp_core_publish_device_offer(capture->core, {
      .device_id = 1,
      .instance_generation = capture->pointer_generation,
      .minimum_state_rate = 125,
      .maximum_state_rate = 16'000,
      .timing_flags = CLSP_NATIVE_TIMING_AVAILABLE | CLSP_NATIVE_TIMING_CLIENT_MONOTONIC |
                      CLSP_NATIVE_TIMING_SAME_ENDPOINT | CLSP_NATIVE_TIMING_PARTIAL_WIRE_BYTES,
      .maximum_state_packet_bytes = 56,
      .kind = CLSP_DEVICE_OFFER_ARRIVED,
      .device_type = CLSP_DEVICE_OFFER_POINTER,
      .capture_source = capture->capture_source,
    });
  }

  /** @brief Neutralize held state when any owned device leaves the native capture set. */
  void device_removed_callback(
    void *context,
    const IOReturn result,
    void *sender,
    IOHIDDeviceRef device
  ) noexcept {
    (void)result;
    (void)sender;
    (void)device;
    auto *capture = static_cast<clsp_apple_input_capture *>(context);
    if (capture == nullptr || !capture->active.load(std::memory_order_acquire)) {
      return;
    }
    release_all(*capture, timestamp_microseconds(*capture, mach_absolute_time()));
  }

  /** @brief Create one IOHID matching dictionary for a usage page/usage pair. */
  [[nodiscard]] CFMutableDictionaryRef matching(const int page, const int usage) noexcept {
    CFMutableDictionaryRef result = CFDictionaryCreateMutable(
      kCFAllocatorDefault,
      2,
      &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks
    );
    if (result == nullptr) {
      return nullptr;
    }
    CFNumberRef page_value = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &page);
    CFNumberRef usage_value = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &usage);
    if (page_value == nullptr || usage_value == nullptr) {
      if (page_value != nullptr) CFRelease(page_value);
      if (usage_value != nullptr) CFRelease(usage_value);
      CFRelease(result);
      return nullptr;
    }
    // IOHID's key macros are C string literals; CFType dictionary callbacks
    // require CFString objects and would otherwise message raw string bytes.
    CFDictionarySetValue(result, CFSTR(kIOHIDDeviceUsagePageKey), page_value);
    CFDictionarySetValue(result, CFSTR(kIOHIDDeviceUsageKey), usage_value);
    CFRelease(page_value);
    CFRelease(usage_value);
    return result;
  }

  /** @brief Publish the aggregate pointer source owned by this native adapter. */
  void publish_pointer_arrival(clsp_apple_input_capture &capture) noexcept {
    capture.pointer_generation = 1U;
    capture.pointer_minimum_interval = UINT32_MAX;
    clsp_core_observe_input_device(capture.core, 2U, 1U, capture.pointer_generation, true, 0U);
    clsp_core_publish_device_offer(capture.core, {
      .device_id = 1U,
      .instance_generation = capture.pointer_generation,
      .minimum_state_rate = 125U,
      .maximum_state_rate = 16'000U,
      .timing_flags = CLSP_NATIVE_TIMING_AVAILABLE | CLSP_NATIVE_TIMING_CLIENT_MONOTONIC |
                      CLSP_NATIVE_TIMING_SAME_ENDPOINT | CLSP_NATIVE_TIMING_PARTIAL_WIRE_BYTES,
      .maximum_state_packet_bytes = 56U,
      .kind = CLSP_DEVICE_OFFER_ARRIVED,
      .device_type = CLSP_DEVICE_OFFER_POINTER,
      .capture_source = capture.capture_source,
    });
  }

  /** @brief Install native GameController sources shared by IOHID and AppKit pointer capture. */
  void install_controller_sources(clsp_apple_input_capture &capture) noexcept {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    auto *capture_pointer = &capture;
    capture.connect_observer = [center
      addObserverForName:GCControllerDidConnectNotification
      object:nil
      queue:nil
      usingBlock:^(NSNotification *notification) {
        GCController *controller = static_cast<GCController *>(notification.object);
        dispatch_async(capture_pointer->queue, ^{
          connect_controller(*capture_pointer, controller);
          if (capture_pointer->active.load(std::memory_order_acquire) &&
              !restart_device_baseline(*capture_pointer)) {
            capture_pointer->active.store(false, std::memory_order_release);
          }
        });
      }];
    capture.disconnect_observer = [center
      addObserverForName:GCControllerDidDisconnectNotification
      object:nil
      queue:nil
      usingBlock:^(NSNotification *notification) {
        GCController *controller = static_cast<GCController *>(notification.object);
        dispatch_async(capture_pointer->queue, ^{
          disconnect_controller(*capture_pointer, controller);
          if (capture_pointer->active.load(std::memory_order_acquire) &&
              !restart_device_baseline(*capture_pointer)) {
            capture_pointer->active.store(false, std::memory_order_release);
          }
        });
      }];
    dispatch_sync(capture.queue, ^{
      for (GCController *controller in GCController.controllers) connect_controller(capture, controller);
    });
  }

  /** @brief Install the focused-window local monitor and disable mouse coalescing. */
  [[nodiscard]] bool install_appkit_monitor(clsp_apple_input_capture &capture) noexcept {
    if (!NSThread.isMainThread) return false;
    capture.appkit_window = NSApp.keyWindow;
    if (capture.appkit_window == nil || !capture.appkit_window.isKeyWindow) return false;
    capture.prior_mouse_coalescing = NSEvent.isMouseCoalescingEnabled;
    NSEvent.mouseCoalescingEnabled = NO;
    capture.appkit_coalescing_owned = true;
    auto *capture_pointer = &capture;
    const NSEventMask mask = NSEventMaskMouseMoved |
                             NSEventMaskLeftMouseDragged |
                             NSEventMaskRightMouseDragged |
                             NSEventMaskOtherMouseDragged |
                             NSEventMaskLeftMouseDown |
                             NSEventMaskLeftMouseUp |
                             NSEventMaskRightMouseDown |
                             NSEventMaskRightMouseUp |
                             NSEventMaskOtherMouseDown |
                             NSEventMaskOtherMouseUp |
                             NSEventMaskScrollWheel |
                             NSEventMaskKeyDown |
                             NSEventMaskKeyUp |
                             NSEventMaskFlagsChanged;
    capture.appkit_monitor = [NSEvent
      addLocalMonitorForEventsMatchingMask:mask
      handler:^NSEvent *(NSEvent *event) {
        handle_appkit_event(*capture_pointer, event);
        return event;
      }];
    if (capture.appkit_monitor != nil) return true;
    NSEvent.mouseCoalescingEnabled = capture.prior_mouse_coalescing;
    capture.appkit_coalescing_owned = false;
    capture.appkit_window = nil;
    return false;
  }

  /** @brief Remove the local monitor and restore the exact process coalescing state. */
  void remove_appkit_monitor(clsp_apple_input_capture &capture) noexcept {
    if (capture.appkit_monitor == nil && !capture.appkit_coalescing_owned) return;
    __strong id monitor = capture.appkit_monitor;
    const auto restore_coalescing = capture.appkit_coalescing_owned;
    const auto prior_coalescing = capture.prior_mouse_coalescing;
    capture.appkit_monitor = nil;
    capture.appkit_window = nil;
    capture.appkit_coalescing_owned = false;
    void (^remove)(void) = ^{
      if (monitor != nil) [NSEvent removeMonitor:monitor];
      if (restore_coalescing) NSEvent.mouseCoalescingEnabled = prior_coalescing;
    };
    if (NSThread.isMainThread) {
      remove();
    } else {
      dispatch_sync(dispatch_get_main_queue(), remove);
    }
  }

  /** @brief Fully quiesce an initialized or partially initialized capture owner. */
  void quiesce(clsp_apple_input_capture &capture) noexcept {
    std::lock_guard quiesce_lock(capture.quiesce_mutex);
    const auto was_active = capture.active.exchange(false, std::memory_order_acq_rel);
    remove_appkit_monitor(capture);
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    if (capture.connect_observer != nil) [center removeObserver:capture.connect_observer];
    if (capture.disconnect_observer != nil) [center removeObserver:capture.disconnect_observer];
    capture.connect_observer = nil;
    capture.disconnect_observer = nil;
    if (capture.queue != nullptr) {
      dispatch_sync(capture.queue, ^{
        for (std::size_t index = 0; index < 16; ++index) {
          if (capture.controllers[index] != nil) disconnect_controller(capture, capture.controllers[index]);
        }
      });
    }
    if (capture.manager != nullptr && capture.activated) {
      IOHIDManagerCancel(capture.manager);
      if (capture.cancelled != nullptr) {
        (void)dispatch_semaphore_wait(capture.cancelled, DISPATCH_TIME_FOREVER);
      }
      capture.activated = false;
    }
    if (was_active) {
      release_all(capture, timestamp_microseconds(capture, mach_absolute_time()));
      (void)clsp_core_neutralize_input(capture.core);
    }
    if (capture.manager != nullptr) {
      (void)IOHIDManagerClose(capture.manager, kIOHIDOptionsTypeNone);
      CFRelease(capture.manager);
      capture.manager = nullptr;
    }
    capture.queue = nullptr;
    capture.cancelled = nullptr;
  }
}  // namespace

extern "C" clsp_status_t clsp_core_start_apple_input_capture(
  clsp_core_t *core,
  clsp_apple_input_capture_t **output
) {
  if (core == nullptr || output == nullptr) {
    return CLSP_STATUS_INVALID_ARGUMENT;
  }
  *output = nullptr;
  auto *capture = new (std::nothrow) clsp_apple_input_capture_t;
  if (capture == nullptr) {
    return CLSP_STATUS_RESOURCE_EXHAUSTED;
  }
  capture->core = core;
  clsp_core_retain(core);
  if (mach_timebase_info(&capture->timebase) != KERN_SUCCESS || capture->timebase.denom == 0) {
    clsp_core_release(core);
    delete capture;
    return CLSP_STATUS_INPUT_UNAVAILABLE;
  }
  capture->manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
  capture->queue = dispatch_queue_create("app.umbra.lsp-iohid", DISPATCH_QUEUE_SERIAL);
  capture->cancelled = dispatch_semaphore_create(0);
  if (capture->manager == nullptr || capture->queue == nullptr || capture->cancelled == nullptr) {
    quiesce(*capture);
    clsp_core_release(core);
    delete capture;
    return CLSP_STATUS_RESOURCE_EXHAUSTED;
  }

  CFMutableDictionaryRef keyboard = matching(kHIDPage_GenericDesktop, kHIDUsage_GD_Keyboard);
  CFMutableDictionaryRef mouse = matching(kHIDPage_GenericDesktop, kHIDUsage_GD_Mouse);
  const void *values[] = {keyboard, mouse};
  CFArrayRef matches = keyboard != nullptr && mouse != nullptr ?
                         CFArrayCreate(kCFAllocatorDefault, values, 2, &kCFTypeArrayCallBacks) :
                         nullptr;
  if (keyboard != nullptr) CFRelease(keyboard);
  if (mouse != nullptr) CFRelease(mouse);
  if (matches == nullptr) {
    quiesce(*capture);
    clsp_core_release(core);
    delete capture;
    return CLSP_STATUS_RESOURCE_EXHAUSTED;
  }
  IOHIDManagerSetDeviceMatchingMultiple(capture->manager, matches);
  CFRelease(matches);
  IOHIDManagerRegisterInputValueCallback(capture->manager, input_value_callback, capture);
  IOHIDManagerRegisterDeviceMatchingCallback(capture->manager, device_arrived_callback, capture);
  IOHIDManagerRegisterDeviceRemovalCallback(capture->manager, device_removed_callback, capture);
  const auto open_result = IOHIDManagerOpen(capture->manager, kIOHIDOptionsTypeNone);
  if (open_result != kIOReturnSuccess) {
    quiesce(*capture);
    clsp_core_release(core);
    delete capture;
    return open_result == kIOReturnNotPermitted ? CLSP_STATUS_INPUT_PERMISSION_DENIED : CLSP_STATUS_INPUT_UNAVAILABLE;
  }
  CFSetRef devices = IOHIDManagerCopyDevices(capture->manager);
  const auto device_count = devices == nullptr ? 0 : CFSetGetCount(devices);
  if (devices != nullptr) CFRelease(devices);
  if (device_count == 0) {
    quiesce(*capture);
    clsp_core_release(core);
    delete capture;
    return CLSP_STATUS_INPUT_UNAVAILABLE;
  }
  publish_pointer_arrival(*capture);
  const auto neutralize_status = clsp_core_neutralize_input(core);
  if (neutralize_status != CLSP_STATUS_OK) {
    quiesce(*capture);
    clsp_core_release(core);
    delete capture;
    return neutralize_status;
  }
  // Queue assignment requires activation and completed cancellation before
  // release, even when opening devices fails. Defer it until all fallible
  // preparation above succeeds so early cleanup owns an unscheduled manager.
  IOHIDManagerSetDispatchQueue(capture->manager, capture->queue);
  IOHIDManagerSetCancelHandler(capture->manager, ^{
    dispatch_semaphore_signal(capture->cancelled);
  });
  IOHIDManagerActivate(capture->manager);
  capture->activated = true;
  install_controller_sources(*capture);
  if (!clsp_core_register_apple_capture(core, capture)) {
    quiesce(*capture);
    clsp_core_release(core);
    delete capture;
    return CLSP_STATUS_INVALID_STATE;
  }
  const auto baseline_status = clsp_core_restart_input_baseline(core);
  if (baseline_status != CLSP_STATUS_OK) {
    clsp_core_unregister_apple_capture(core, capture);
    quiesce(*capture);
    clsp_core_release(core);
    delete capture;
    return baseline_status;
  }
  capture->active.store(true, std::memory_order_release);
  *output = capture;
  return CLSP_STATUS_OK;
}

extern "C" clsp_status_t clsp_core_start_apple_appkit_input_capture(
  clsp_core_t *core,
  clsp_apple_input_capture_t **output
) {
  if (core == nullptr || output == nullptr) return CLSP_STATUS_INVALID_ARGUMENT;
  *output = nullptr;
  if (!NSThread.isMainThread) return CLSP_STATUS_INVALID_STATE;
  auto *capture = new (std::nothrow) clsp_apple_input_capture_t;
  if (capture == nullptr) return CLSP_STATUS_RESOURCE_EXHAUSTED;
  capture->core = core;
  capture->capture_source = CLSP_DEVICE_CAPTURE_APPKIT;
  clsp_core_retain(core);
  if (mach_timebase_info(&capture->timebase) != KERN_SUCCESS || capture->timebase.denom == 0) {
    clsp_core_release(core);
    delete capture;
    return CLSP_STATUS_INPUT_UNAVAILABLE;
  }
  capture->queue = dispatch_queue_create("app.umbra.lsp-appkit", DISPATCH_QUEUE_SERIAL);
  if (capture->queue == nullptr || !install_appkit_monitor(*capture)) {
    quiesce(*capture);
    clsp_core_release(core);
    delete capture;
    return CLSP_STATUS_RESOURCE_EXHAUSTED;
  }
  publish_pointer_arrival(*capture);
  const auto neutralize_status = clsp_core_neutralize_input(core);
  if (neutralize_status != CLSP_STATUS_OK) {
    quiesce(*capture);
    clsp_core_release(core);
    delete capture;
    return neutralize_status;
  }
  install_controller_sources(*capture);
  if (!clsp_core_register_apple_capture(core, capture)) {
    quiesce(*capture);
    clsp_core_release(core);
    delete capture;
    return CLSP_STATUS_INVALID_STATE;
  }
  const auto baseline_status = clsp_core_restart_input_baseline(core);
  if (baseline_status != CLSP_STATUS_OK) {
    clsp_core_unregister_apple_capture(core, capture);
    quiesce(*capture);
    clsp_core_release(core);
    delete capture;
    return baseline_status;
  }
  capture->active.store(true, std::memory_order_release);
  *output = capture;
  return CLSP_STATUS_OK;
}

extern "C" std::uint8_t clsp_apple_input_capture_apply_lspg(
  clsp_apple_input_capture_t *capture,
  const clsp_const_byte_span_t payload
) {
  if (capture == nullptr || payload.data == nullptr || payload.length == 0 ||
      !capture->active.load(std::memory_order_acquire)) {
    return static_cast<std::uint8_t>(lumen::lsp::input_plane::controller_command_status::stale_generation);
  }
  __block std::uint8_t status = static_cast<std::uint8_t>(lumen::lsp::input_plane::controller_command_status::failed);
  dispatch_sync(capture->queue, ^{
    status = apply_lspg(*capture, std::span<const std::uint8_t> {payload.data, payload.length});
  });
  return status;
}

extern "C" void clsp_apple_input_capture_quiesce(clsp_apple_input_capture_t *capture) {
  if (capture != nullptr) {
    quiesce(*capture);
  }
}

extern "C" void clsp_apple_input_capture_retain(clsp_apple_input_capture_t *capture) {
  if (capture != nullptr) {
    capture->references.fetch_add(1, std::memory_order_relaxed);
  }
}

extern "C" void clsp_apple_input_capture_release(clsp_apple_input_capture_t *capture) {
  if (capture != nullptr && capture->references.fetch_sub(1, std::memory_order_acq_rel) == 1U) {
    delete capture;
  }
}

extern "C" void clsp_apple_input_capture_stop(clsp_apple_input_capture_t *capture) {
  if (capture == nullptr) {
    return;
  }
  if (capture->pointer_generation != 0U) {
    clsp_core_observe_input_device(capture->core, 2U, 1U, capture->pointer_generation, false, 0U);
    const auto spacing = capture->pointer_spacing.snapshot(
      CLSP_NATIVE_TIMING_AVAILABLE | CLSP_NATIVE_TIMING_CLIENT_MONOTONIC |
      CLSP_NATIVE_TIMING_SAME_ENDPOINT | CLSP_NATIVE_TIMING_PARTIAL_WIRE_BYTES
    );
    clsp_core_publish_device_offer(capture->core, {
      .device_id = 1,
      .instance_generation = capture->pointer_generation,
      .captured_samples = capture->pointer_samples,
      .state_spacing_count = spacing.count,
      .state_spacing_p50_microseconds = spacing.p50_microseconds,
      .state_spacing_p95_microseconds = spacing.p95_microseconds,
      .state_spacing_p99_microseconds = spacing.p99_microseconds,
      .state_spacing_maximum_microseconds = spacing.maximum_microseconds,
      .state_spacing_drops = spacing.drops,
      .timing_flags = spacing.flags,
      .kind = CLSP_DEVICE_OFFER_REMOVED,
      .device_type = CLSP_DEVICE_OFFER_POINTER,
      .capture_source = capture->capture_source,
    });
  }
  clsp_core_unregister_apple_capture(capture->core, capture);
  quiesce(*capture);
  clsp_core_release(capture->core);
  clsp_apple_input_capture_release(capture);
}
