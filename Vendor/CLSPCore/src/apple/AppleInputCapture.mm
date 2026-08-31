/**
 * @file AppleInputCapture.mm
 * @brief Preferred public IOHID keyboard and mouse capture for native LSP input.
 */

#include "CLSPCore.h"

#import <IOKit/hid/IOHIDManager.h>
#import <GameController/GameController.h>
#import <dispatch/dispatch.h>
#import <mach/mach_time.h>

#include <array>
#include <algorithm>
#include <atomic>
#include <cstdint>
#include <new>

/** @brief Opaque native Apple capture owner declared by the public C ABI. */
struct clsp_apple_input_capture {
  clsp_core_t *core {};  ///< Retained LSP core receiving allocation-free records.
  IOHIDManagerRef manager {};  ///< Public IOHID device and value callback owner.
  dispatch_queue_t queue {};  ///< Dedicated serial native callback queue.
  dispatch_semaphore_t cancelled {};  ///< Cancellation barrier for callback quiescence.
  std::atomic<bool> active {false};  ///< Callback admission gate.
  bool activated {};  ///< Whether dispatch-queue activation requires cancellation.
  std::array<bool, 256> keyboard {};  ///< Current keyboard-page usage state.
  std::array<bool, 6> pointer_buttons {};  ///< Pointer buttons one through five.
  __strong GCController *controllers[16] {};  ///< Controller slots owned on the native queue.
  std::array<std::uint32_t, 16> controller_generations {};  ///< Per-slot instance generations.
  std::array<std::uint32_t, 16> controller_buttons {};  ///< Last emitted digital-button masks.
  __strong id connect_observer {};  ///< Low-rate controller-arrival observer.
  __strong id disconnect_observer {};  ///< Low-rate controller-removal observer.
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

  /** @brief Return the frozen digital-button mask for one extended profile. */
  [[nodiscard]] std::uint32_t controller_button_mask(GCExtendedGamepad *gamepad) noexcept {
    std::uint32_t mask = 0;
    auto set = [&mask](const unsigned bit, GCControllerButtonInput *button) noexcept {
      if (button != nil && button.isPressed) mask |= std::uint32_t {1} << bit;
    };
    set(0, gamepad.buttonA); set(1, gamepad.buttonB); set(2, gamepad.buttonX); set(3, gamepad.buttonY);
    set(4, gamepad.dpad.up); set(5, gamepad.dpad.down); set(6, gamepad.dpad.left); set(7, gamepad.dpad.right);
    set(8, gamepad.leftShoulder); set(9, gamepad.rightShoulder);
    set(10, gamepad.leftThumbstickButton); set(11, gamepad.rightThumbstickButton);
    set(12, gamepad.buttonMenu); set(13, gamepad.buttonOptions); set(14, gamepad.buttonHome);
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
    controller.handlerQueue = capture.queue;
    GCExtendedGamepad *gamepad = controller.extendedGamepad;
    const auto arrival_time = controller_timestamp(capture, gamepad.lastEventTimestamp);
    submit_controller_edge(capture, slot, arrival_time, 5, 1);

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
      (void)clsp_core_submit_controller_state(capture.core, &state);
    };

    if (controller.motion != nil) {
      if (controller.motion.sensorsRequireManualActivation) controller.motion.sensorsActive = YES;
      controller.motion.valueChangedHandler = ^(GCMotion *motion) {
        if (!capture.active.load(std::memory_order_acquire) || capture.controllers[slot] != controller) return;
        const auto timestamp = controller_timestamp(capture, 0);
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
    submit_controller_edge(capture, slot, timestamp, 6, 0);
    controller.extendedGamepad.valueChangedHandler = nil;
    if (controller.motion != nil) {
      controller.motion.valueChangedHandler = nil;
      if (controller.motion.sensorsRequireManualActivation) controller.motion.sensorsActive = NO;
    }
    capture.controller_buttons[slot] = 0;
    capture.controllers[slot] = nil;
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
    (void)clsp_core_submit_pointer(capture->core, &sample);
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
    CFDictionarySetValue(result, kIOHIDDeviceUsagePageKey, page_value);
    CFDictionarySetValue(result, kIOHIDDeviceUsageKey, usage_value);
    CFRelease(page_value);
    CFRelease(usage_value);
    return result;
  }

  /** @brief Fully quiesce an initialized or partially initialized capture owner. */
  void quiesce(clsp_apple_input_capture &capture) noexcept {
    const auto was_active = capture.active.exchange(false, std::memory_order_acq_rel);
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
  IOHIDManagerRegisterDeviceRemovalCallback(capture->manager, device_removed_callback, capture);
  IOHIDManagerSetDispatchQueue(capture->manager, capture->queue);
  IOHIDManagerSetCancelHandler(capture->manager, ^{
    dispatch_semaphore_signal(capture->cancelled);
  });
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
  IOHIDManagerActivate(capture->manager);
  capture->activated = true;
  capture->active.store(true, std::memory_order_release);
  NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
  capture->connect_observer = [center addObserverForName:GCControllerDidConnectNotification object:nil queue:nil usingBlock:^(NSNotification *notification) {
    GCController *controller = static_cast<GCController *>(notification.object);
    dispatch_async(capture->queue, ^{ connect_controller(*capture, controller); });
  }];
  capture->disconnect_observer = [center addObserverForName:GCControllerDidDisconnectNotification object:nil queue:nil usingBlock:^(NSNotification *notification) {
    GCController *controller = static_cast<GCController *>(notification.object);
    dispatch_async(capture->queue, ^{ disconnect_controller(*capture, controller); });
  }];
  dispatch_sync(capture->queue, ^{
    for (GCController *controller in GCController.controllers) connect_controller(*capture, controller);
  });
  *output = capture;
  return CLSP_STATUS_OK;
}

extern "C" void clsp_apple_input_capture_stop(clsp_apple_input_capture_t *capture) {
  if (capture == nullptr) {
    return;
  }
  quiesce(*capture);
  clsp_core_release(capture->core);
  delete capture;
}
