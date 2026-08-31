# Compatibility and validation status

Umbra is a native Apple Silicon macOS client. This checklist records implemented
legacy Moonlight behavior and the hardware or human validation that remains. A
checked item means repository coverage exists; it is not a blanket performance,
HDR, accessibility, or hardware-matrix claim.

The pinned comparison source is the local `reference/moonlight-qt` checkout at
commit `d2f6990b`. The checkout is intentionally not part of the Umbra source tree.

## Hosts and onboarding

- [x] Discover `_nvstream._tcp` hosts on the local network.
- [x] Add hosts by DNS name, IPv4, IPv6, or `moonlight://` address.
- [x] Poll online, offline, paired, unpaired, and busy state.
- [x] Pair with the host using the PIN and certificate flow.
- [x] Pin and persist the host certificate and client identity securely.
- [x] Wake hosts with Wake-on-LAN on standard and GameStream ports.
- [x] Rename, remove, inspect, and test connectivity for a saved host.
- [x] Report blocked-port, unsupported-server, timeout, and certificate errors.

## Applications

- [x] Load and refresh the host application catalog and box art.
- [x] Launch, resume, and quit a host application.
- [x] Confirm before replacing an already running application.
- [x] Direct-launch an application.
- [x] Hide and unhide applications, including the hidden-only empty state.
- [x] Preserve host, selection, filter, and scroll context after a session.

## Streaming

- [x] Negotiate and transport sessions through `moonlight-common-c`.
- [x] Decode H.264, HEVC, and AV1 using VideoToolbox where supported.
- [ ] Support HDR/EDR and YUV 4:4:4 where the host and display support them.
- [x] Pace frames and honor V-Sync, frame-pacing, resolution, FPS, and bitrate.
- [x] Render with Metal and provide a native fallback path.
- [x] Decode stereo, 5.1, and 7.1 Opus audio through native macOS audio APIs.
- [x] Mute host audio and mute the client while inactive when configured.
- [x] Treat client microphone forwarding as optional by default, with explicit
      degraded startup and a fail-closed required mode.
- [x] Show connection quality, performance statistics, stage, and failure state.
- [x] Disconnect and optionally quit the host application after streaming.

## Input and controllers

- [x] Forward keyboard input and normalize clipboard text entry.
- [x] Support relative captured mouse and absolute remote-desktop pointer modes.
- [x] Forward all mouse buttons and scrolling with swap/reverse preferences,
      accumulating fractional wheel motion before integer wire emission.
- [x] Support trackpad/direct-touch gestures and virtual trackpad behavior.
- [x] Support up to 16 locally allocated controller slots, hot-plugging, mappings,
      and generation-safe heterogeneous merged player one.
- [x] Forward controller battery, touchpad, motion, rumble, trigger rumble, LEDs,
      and adaptive triggers where the macOS GameController API exposes them.
- [x] Support controller mouse mode and gamepad navigation in the client UI.
- [x] Support background controller input when configured.
- [x] Capture system shortcuts in fullscreen or always, with honest permission state.
- [x] Implement the mouse-mode, statistics, and disconnect shortcut chords.

## Preferences

- [x] Resolution presets and custom resolution.
- [x] 30/60 FPS presets and custom FPS.
- [x] Bitrate selection and recommended default reset.
- [x] Fullscreen, borderless-windowed, and windowed stream display modes.
- [x] V-Sync, frame pacing, and HDR.
- [x] Stereo, 5.1, and 7.1 audio.
- [x] Host audio mute and inactive-client mute.
- [x] Optimize host game settings and quit-after-stream.
- [ ] Language, GUI window mode, warnings, presence integration, and keep-awake.
- [x] Remote-desktop mouse, shortcut capture, trackpad, buttons, and scrolling.
- [x] Face-button swap, forced controller one, controller mouse, background input.
- [x] Automatic/software/hardware decoder selection.
- [x] Automatic/H.264/HEVC/AV1 codec selection.
- [x] Automatic/Metal/native-fallback renderer selection.
- [ ] YUV 4:4:4, unlocked bitrate, discovery, port detection, and statistics.

## macOS application behavior

- [x] Native menus and commands for Add Host, Settings, Help, Back, and Quit.
- [x] Windowed and maximized main-window behavior, plus borderless and native fullscreen streaming.
- [x] Notch-safe fullscreen content and correct multi-display selection.
- [x] Prevent display sleep during a session when configured.
- [ ] Keyboard, pointer, controller, VoiceOver, light, dark, and increased-contrast UI.
- [x] Honest empty, loading, offline, pairing, reconnecting, error, and dense states.
- [x] Command-line list, pair, start, and quit workflows retained where applicable.

## Remaining validation gaps

The remaining unchecked composites require direct evidence: exact live HDR/EDR
and YUV 4:4:4 tuples, complete human-reviewed localization catalogs, and direct
VoiceOver and contrast traversal. Experimental protocol-v2, lossless, and
Lumen VDD work does not change the status of these legacy-client checks.
Umbra must not expose a capability as proven when only parser, fixture, or
portable test coverage exists.
