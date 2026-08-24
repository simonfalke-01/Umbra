# Umbra/Lumen performance harness

This directory contains a dependency-free, non-UI benchmark collector. It does not modify Umbra or Lumen production source.

## What it measures

The parser normalizes evidence from:

- Umbra support logs: launch request, audio warmup, accepted session, RTSP start, first audio/video packet, first decoded frame, renderer drops/rebuffers/silence. Startup intervals derived from these ISO timestamps carry ±1000 ms uncertainty and are never threshold-eligible.
- Optional externally correlated client telemetry JSONL: p50/p95/p99 host-processing, receive-to-decode, decode-to-Metal, and presentation-proxy durations. Production does not currently emit benchmark run IDs, so ordinary live runs mark these metrics unavailable instead of inventing correlation.
- macOS unified CoreAudio JSON/NDJSON logs: Umbra/SoundSource-correlated `ClientTimeout`, HAL overload, and ARK mute events. Real NDJSON may omit `process`, and `processID` is the emitter PID, so trust is anchored to the exact structured `processImagePath=/usr/sbin/coreaudiod`. `com.apple.coreaudio*` failures require owned-PID numeric client/context linkage plus an `AddMuter`/registration link to `app.umbra.Umbra`; `ark_mutes` is available only when this CoreAudio linkage exists. Separately, `com.apple.audioanalytics*` messages are parsed as order-independent quoted Optional fields: `"HostApplicationDisplayID": Optional(app.umbra.Umbra)`, positive `"sample_rate": Optional(...)`, `"overload_type": Optional(ClientTimeoutStart|ClientTimeoutEnd)`, and/or `"issue_type": Optional(overload)`. Analytics-only coverage can validate timeout/overload counters but leaves `ark_mutes` unavailable. `ClientTimeoutStart` counts one incident; `ClientTimeoutEnd` is retained as lifecycle evidence and is not counted again. Other apps, zero/missing sample rates, simplified non-Optional syntax, and forged emitter paths remain environment context.
- Lumen logs: only stages carrying the exact benchmark trace ID become host measurements. Encoder cache/probe, display/capture preparation, and session messages without that ID remain explicitly uncorrelated environment context.

Only runner actions use `time.monotonic_ns()` and declare observation precision. Existing support-log lines are never assigned attachment-time monotonic timestamps. Wall-clock timestamps are retained for bounded log slicing and coarse log intervals. Host and client timelines remain separate unless a host record has the exact trace ID; wall-clock proximity is never treated as correlation.

The report explicitly marks host/client cross-clock, actual scanout, and input-to-photon latency unavailable. Those require clock calibration and, for input-to-photon, a synchronized physical input plus an optical measurement rig. When causally watermarked per-event input traces are available, the report can still separate the combined two network legs without comparing host and client clock epochs: it subtracts the matched client input-to-send, host receive-to-video-send, and client video-receive-to-present-submit durations from the client-clock input-to-present-submit duration. This is performed on every raw event before percentiles. It reports combined uplink+downlink transit and the complementary host+client processing residual; it never claims a one-way split, substitutes ping/RTT, subtracts percentile summaries, or aggregates Latency and Quality mode samples. Missing or ambiguous required client evidence produces `insufficient_data`, writes reports atomically, and returns exit code 2. The included thresholds are conservative regression gates, not a claim that the stream meets a 10 ms input-to-photon target.

The schema names and per-event arithmetic are exact:

```text
combined_network_transit_residual_ms <- summarize per event:
    observed_input_to_present_submit_ns
  - client_input_to_send_ns
  - host_receive_to_video_send_ns
  - client_video_receive_to_present_submit_ns

host_client_processing_residual_ms <- summarize per event:
    client_input_to_send_ns
  + host_receive_to_video_send_ns
  + client_video_receive_to_present_submit_ns
```

Both are summaries of raw per-event results. The first is the combined uplink
and downlink only; the second is the measured host-plus-client component only.

Cellular and other WAN runs are useful for validating jitter handling and the
per-event processing residual, but they do not qualify the high-refresh LAN
target. Record them as a separate matrix. Do not estimate client/host processing
by subtracting ping or a summary RTT from input latency: the input uplink and
changed-frame downlink are different legs, and percentile subtraction is not a
valid decomposition.

## Safe live runner

Build/package Umbra first, confirm no Umbra session is active, then run:

```sh
Scripts/Performance/run_desktop_benchmark.zsh \
  --host <saved-host-name-or-address> \
  --app Desktop \
  --network-kind lan \
  --declared-mode latency \
  --client-protocol umbra-legacy \
  --duration 12 \
  --lumen-log /path/to/a/locally-accessible/lumen.log
```

The runner:

1. Enumerates `NSRunningApplication` instances and refuses to start if any Umbra bundle is active.
   It also records one immutable matrix label (`network_kind`, declared optimization mode, client protocol, and host) on every runner event. Differing matrices are rejected instead of merged. `unknown` remains valid for diagnostic runs but is not evidence for a named LAN matrix or a separate cellular diagnostic matrix.
2. Captures the exact macOS output volume/mute state, marks restoration pending before muting, and restores plus verifies both values through a signal-resistant exit trap.
3. Launches the public Umbra `stream` CLI through `NSWorkspace.openApplication`, with `createsNewApplicationInstance=true`, activation and recent-items insertion disabled, and the exact CLI argument array ending in `--no-quit-after --no-audio-on-host`. It never issues the host `quit` command and never launches the bundle executable directly.
4. Snapshots exact bundle-and-resolved-executable matches inside the helper immediately before launch. Once the returned `NSRunningApplication` exposes a positive PID, that PID becomes exclusive: transient process-registration checks may retry only that PID, and its exit or any identity mismatch fails without considering another candidate. Candidate discovery is available only while the returned object remains a non-positive placeholder. In that case, the helper performs a monotonic, ten-second bounded search for applications matching both the exact bundle and executable that were absent from the prelaunch snapshot. One new candidate must remain uniquely stable for 250 monotonic milliseconds; zero candidates time out, and two candidates fail as ambiguous without terminating either. The helper then captures PID, executable device/inode, and process start time once, writes that immutable identity artifact, and the runner immediately performs strict verification. Failure diagnostics retain the completion error or returned-application termination state plus all observed/disappeared candidate PIDs. It then uses `lsof` FD/device/inode/name fields to select the one support log actually held by that exact PID, including delayed opens.
5. Opens that exact log once with `O_NOFOLLOW`, verifies its device/inode via `fstat`, then re-runs `lsof` after the retainer is ready and requires the same FD/device/inode to remain open by the bound PID. The retained descriptor survives rotation/replacement and is the only source used for the snapshot. First-frame detection controls the bounded run but does not create a timing measurement.
6. Uses only PID-scoped `NSRunningApplication.terminate()`/`forceTerminate()` after two immediate full-identity re-verifications. It retries bounded cleanup and fails if the exact returned process survives. There is no bundle-wide quit, executable-wide kill, path-prefix PID match, or termination of another concurrently launched Umbra instance.
7. Restores audio, confirms the exact client process exited, retains a one-second CoreAudio post-roll, then collects structured JSON/NDJSON logs. CoreAudio failures count against Umbra only when structured fields in the same event contain the exact PID and bundle identifier; other failures remain environment context.

Artifact directories use exclusive UUID creation, mode `0700`, `umask 077`, and reject symlink paths. Reports are atomically replaced from `0600` temporary files after runtime schema and threshold validation.

Use `--dry-run` to perform preflight checks without launching Umbra or changing audio state.

## Parse existing evidence

```sh
python3 Scripts/Performance/parse_benchmark.py \
  --run-id manual-run \
  --trace-id manual-trace \
  --runner-events Scripts/Performance/fixtures/runner-events.jsonl \
  --umbra-log /path/to/Umbra.log \
  --lumen-log /path/to/lumen.log \
  --coreaudio-log /path/to/coreaudio.log \
  --umbra-pid 123 \
  --coreaudio-window-start 2026-08-24T00:00:00Z \
  --coreaudio-window-end 2026-08-24T00:00:20Z \
  --client-telemetry /path/to/client-telemetry.jsonl \
  --output-dir .build/performance-runs/manual-run
```

Outputs are `report.json` (schema: `schema.json`) and `report.md`. Report schema v2 adds the required `input_network_decomposition` object; v1 artifacts remain historical inputs and are not relabeled as v2. Threshold files retain their independent v1 schema. A threshold failure returns exit code 1; missing required evidence or any configured threshold metric returns exit code 2. Reports are preserved in both cases.

Client telemetry uses one JSON object per line:

```json
{"timestamp":"2026-08-24T00:00:05.000Z","type":"latency_summary","run_id":"<run-id>","trace_id":"<trace-id>","optimization_mode":"latency","client_protocol":"umbra-v2","provenance":"Umbra in-process monotonic telemetry","metrics":{"receive_to_decode_ms":{"samples":120,"p50":0.8,"p95":1.4,"p99":1.9,"evidence":"video_toolbox_output_callback"}}}
```

Optional causally matched input/change-frame traces use raw nanosecond durations. The observed duration is client-clock input capture to first watermarked present submission. Each component is a duration measured within one machine, so clock offset is irrelevant; the parser rejects traces whose components exceed the observed total, whose optimization modes differ, or whose mode disagrees with the declared run matrix. Every sample carries a conservative local timestamp/watermark `measurement_error_bound_ns`; the report retains the maximum bound instead of hiding precision loss.

```json
{"type":"input_trace","run_id":"<run-id>","trace_id":"<trace-id>","mode":"latency","input_event_id":42,"changed_frame_id":9001,"correlation":"causal_input_frame_watermark_v1","observed_input_to_present_submit_ns":72000000,"client_input_to_send_ns":300000,"host_receive_to_video_send_ns":7800000,"client_video_receive_to_present_submit_ns":2400000,"measurement_error_bound_ns":100000}
```

Structured Lumen stages, when available, use a log message shaped like:

```text
PERF trace_id=<trace-id> stage=first_encode duration_ms=2.4
```

Without an explicit matching trace ID, host stages are unavailable. Time-window-adjacent host messages remain diagnostic context and are never merged into measurements.

## Tests

```sh
python3 -m unittest discover -s Scripts/Performance/tests -v
zsh -n Scripts/Performance/run_desktop_benchmark.zsh
xcrun swiftc Scripts/Performance/PIDScopedTermination.swift -o /tmp/umbra-pid-helper-check
python3 -m py_compile Scripts/Performance/parse_benchmark.py Scripts/Performance/discover_support_log.py Scripts/Performance/retain_support_log.py
```

The cleanup test uses a fake `osascript` executable and proves the failure trap restores the exact original output volume and mute state.
