#!/usr/bin/env python3
"""Normalize Umbra, Lumen, and CoreAudio evidence into one benchmark report."""

from __future__ import annotations

import argparse
from datetime import datetime, timedelta, timezone
import json
import math
import os
from pathlib import Path
import re
import sys
import tempfile
from typing import Any


SCHEMA_VERSION = 2
UMBRA_LINE = re.compile(
    r"^(?P<timestamp>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z) "
    r"\[(?P<level>[^]]+)] \[(?P<source>[^]]+)] (?P<message>.*)$"
)
LUMEN_LINE = re.compile(
    r"^\[(?P<timestamp>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?:\.\d+)?)]: "
    r"(?P<level>[^:]+): (?P<message>.*)$"
)


def parse_timestamp(value: str) -> datetime:
    normalized = value.replace(" ", "T", 1)
    if normalized.endswith("Z"):
        normalized = normalized[:-1] + "+00:00"
    parsed = datetime.fromisoformat(normalized)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def iso_timestamp(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def event(name: str, timestamp: str, source: str, evidence: str, clock_domain: str) -> dict[str, Any]:
    return {
        "name": name,
        "timestamp": iso_timestamp(parse_timestamp(timestamp)),
        "source": source,
        "clock_domain": clock_domain,
        "evidence": evidence.strip(),
    }


def parse_umbra_log(
    text: str,
    window_start: str | None = None,
    window_end: str | None = None,
) -> dict[str, Any]:
    patterns = [
        ("launch_request", re.compile(r"Starting requested (?:launch|resume) stream", re.I)),
        ("streaming_task_started", re.compile(r"initial streaming task started", re.I)),
        ("audio_warmup_started", re.compile(r"Audio output started", re.I)),
        ("session_accepted", re.compile(r"requested streaming session was accepted", re.I)),
        ("rtsp_start", re.compile(r"Starting RTSP handshake", re.I)),
        ("first_video_packet", re.compile(r"Received first video packet", re.I)),
        ("first_decoded_frame", re.compile(r"Video decoder produced frame 1\b", re.I)),
        ("first_audio_packet", re.compile(r"Received first audio packet", re.I)),
    ]
    events_by_name: dict[str, dict[str, Any]] = {}
    reported_intervals: dict[str, float] = {}
    audio: dict[str, Any] = {}
    errors: list[str] = []
    launch_count = 0
    audio_summary_count = 0
    # SupportLog timestamps can be second-granularity. The exact PID-bound file
    # provides identity; a one-second wall-clock pad prevents rounding from
    # excluding boundary records. Multiple sessions inside the pad are rejected.
    start_time = parse_timestamp(window_start) - timedelta(seconds=1) if window_start else None
    end_time = parse_timestamp(window_end) + timedelta(seconds=1) if window_end else None

    summary_pattern = re.compile(
        r"packets accepted=(?P<accepted>\d+) played=(?P<played>\d+) "
        r"dropped=(?P<dropped>\d+) rejected=(?P<rejected>\d+); "
        r"callbacks=(?P<callbacks>\d+) rebuffers=(?P<rebuffers>\d+); "
        r"frames real=(?P<real>\d+) silence=(?P<silence>\d+)",
        re.I,
    )
    packet_delay_pattern = re.compile(r"after (?P<milliseconds>\d+(?:\.\d+)?) ms", re.I)

    for raw_line in text.splitlines():
        match = UMBRA_LINE.match(raw_line.strip())
        if match is None:
            continue
        line_time = parse_timestamp(match.group("timestamp"))
        if start_time is not None and line_time < start_time:
            continue
        if end_time is not None and line_time > end_time:
            continue
        message = match.group("message")
        for name, pattern in patterns:
            if pattern.search(message):
                if name == "launch_request":
                    launch_count += 1
                if name not in events_by_name:
                    events_by_name[name] = event(
                        name,
                        match.group("timestamp"),
                        f"umbra.{match.group('source').lower()}",
                        message,
                        "client_wall_clock",
                    )
                delay = packet_delay_pattern.search(message)
                if delay and name in {"first_video_packet", "first_audio_packet"} and name in events_by_name:
                    packet = "video" if name == "first_video_packet" else "audio"
                    reported_intervals.setdefault(
                        f"rtsp_to_first_{packet}_packet", float(delay.group("milliseconds"))
                    )
                break
        summary = summary_pattern.search(message)
        if summary:
            audio_summary_count += 1
            audio = {
                "accepted_packets": int(summary.group("accepted")),
                "played_packets": int(summary.group("played")),
                "dropped_packets": int(summary.group("dropped")),
                "rejected_packets": int(summary.group("rejected")),
                "callbacks": int(summary.group("callbacks")),
                "rebuffers": int(summary.group("rebuffers")),
                "real_frames": int(summary.group("real")),
                "silence_frames": int(summary.group("silence")),
            }

    if launch_count > 1:
        errors.append(f"multiple launch requests ({launch_count}) found in selected client log window")
    if audio_summary_count > 1:
        errors.append(f"multiple audio summaries ({audio_summary_count}) found in selected client log window")
    if errors:
        audio = {}
        events_by_name = {}
        reported_intervals = {}

    ordered_events = sorted(events_by_name.values(), key=lambda item: parse_timestamp(item["timestamp"]))
    return {
        "valid": not errors,
        "errors": errors,
        "clock_domain": "client_wall_clock",
        "clock_precision": "log timestamps; precision depends on the emitting build",
        "events": ordered_events,
        "reported_intervals_ms": reported_intervals,
        "audio": audio,
    }


def parse_lumen_log(text: str, expected_trace_id: str | None = None) -> dict[str, Any]:
    events: list[dict[str, Any]] = []
    durations: dict[str, float] = {}
    environment_context: list[dict[str, Any]] = []
    errors: list[str] = []
    matched_trace_id = False
    structured = re.compile(
        r"\bPERF\s+trace_id=(?P<trace>[^\s]+)\s+stage=(?P<stage>[a-zA-Z0-9_.-]+)\s+"
        r"duration_ms=(?P<duration>\d+(?:\.\d+)?)"
    )
    probe_hit = re.compile(r"Encoder probe cache hit .* in (?P<duration>\d+(?:\.\d+)?) ms", re.I)
    probe_miss = re.compile(r"Encoder exhaustive probe completed in (?P<duration>\d+(?:\.\d+)?) ms", re.I)
    display_stages = re.compile(
        r"Stream startup stage timings: display enumeration=(?P<enumeration>\d+(?:\.\d+)?) ms, "
        r"display ready=(?P<ready>\d+(?:\.\d+)?) ms",
        re.I,
    )
    encoder_ready = re.compile(
        r"Stream startup stage timing: encoder device ready=(?P<duration>\d+(?:\.\d+)?) ms",
        re.I,
    )

    for raw_line in text.splitlines():
        match = LUMEN_LINE.match(raw_line.strip())
        if match is None:
            continue
        message = match.group("message")
        timestamp = match.group("timestamp")

        structured_match = structured.search(message)
        if structured_match:
            trace = structured_match.group("trace")
            if expected_trace_id is not None and trace == expected_trace_id:
                matched_trace_id = True
                stage = structured_match.group("stage")
                if stage in durations:
                    errors.append(f"multiple matching Lumen records for stage {stage}")
                else:
                    durations[stage] = float(structured_match.group("duration"))
                    events.append(event(stage, timestamp, "lumen.perf", message, "host_wall_clock"))
            continue

        duration_match = probe_hit.search(message)
        if duration_match:
            environment_context.append(
                event("encoder_probe_cache_hit", timestamp, "lumen.video", message, "host_wall_clock")
            )
            continue
        duration_match = probe_miss.search(message)
        if duration_match:
            environment_context.append(
                event("encoder_exhaustive_probe", timestamp, "lumen.video", message, "host_wall_clock")
            )
            continue
        duration_match = display_stages.search(message)
        if duration_match:
            environment_context.append(
                event("display_ready", timestamp, "lumen.capture", message, "host_wall_clock")
            )
            continue
        duration_match = encoder_ready.search(message)
        if duration_match:
            environment_context.append(
                event("encoder_device_ready", timestamp, "lumen.encoder", message, "host_wall_clock")
            )
            continue
        if "New streaming session started" in message:
            environment_context.append(
                event("host_session_started", timestamp, "lumen.rtsp", message, "host_wall_clock")
            )

    events.sort(key=lambda item: parse_timestamp(item["timestamp"]))
    environment_context.sort(key=lambda item: parse_timestamp(item["timestamp"]))
    if errors:
        events = []
        durations = {}
        matched_trace_id = False
    return {
        "valid": not errors,
        "errors": errors,
        "clock_domain": "host_wall_clock",
        "events": events,
        "durations_ms": durations,
        "environment_context": environment_context,
        "correlation": {
            "method": "explicit_trace_id" if matched_trace_id else "unavailable",
            "expected_trace_id": expected_trace_id,
            "matched_trace_id": matched_trace_id,
        },
    }


def parse_coreaudio_log(
    text: str,
    expected_pid: int,
    bundle_identifier: str = "app.umbra.Umbra",
) -> dict[str, Any]:
    stripped = text.strip()
    records: list[dict[str, Any]] = []
    if stripped:
        if stripped.startswith("["):
            decoded = json.loads(stripped)
            if not isinstance(decoded, list) or not all(isinstance(item, dict) for item in decoded):
                raise ValueError("CoreAudio JSON log must be an array of objects")
            records = decoded
        else:
            records = parse_json_lines(stripped)

    def message(record: dict[str, Any]) -> str:
        value = record.get("eventMessage")
        return value if isinstance(value, str) else ""

    def is_trusted_coreaudiod_image(record: dict[str, Any]) -> bool:
        image_path = record.get("processImagePath") or record.get("senderImagePath")
        return isinstance(image_path, str) and image_path == "/usr/sbin/coreaudiod"

    trusted_image_records = [record for record in records if is_trusted_coreaudiod_image(record)]
    trusted_coreaudio_records = [
        record
        for record in trusted_image_records
        if isinstance(record.get("subsystem"), str)
        and record["subsystem"].startswith("com.apple.coreaudio")
    ]
    trusted_audioanalytics_records = [
        record
        for record in trusted_image_records
        if isinstance(record.get("subsystem"), str)
        and record["subsystem"].startswith("com.apple.audioanalytics")
    ]
    pid_token = rf"\bpid\s*:\s*{re.escape(str(expected_pid))}\b"
    client_pid_pattern = re.compile(
        rf"\bclient\s+(?P<identifier>\d+)\s*\(\s*pid\s*:?[ ]*{re.escape(str(expected_pid))}\s*\)",
        re.I,
    )
    context_pid_pattern = re.compile(
        rf"\b(?:ContextID|IOContext)\s*[:=]?\s*(?P<identifier>\d+)\b[^\n]*?{pid_token}",
        re.I,
    )
    bundle_client_pattern = re.compile(
        rf"\bProcess\s+{re.escape(bundle_identifier)}\s*\((?P<identifier>\d+)\)",
        re.I,
    )
    reference_pattern = re.compile(
        r"\b(?:client(?:\s+ID)?|ContextID|IOContext)\s*[:=]?\s*(?P<identifier>\d+)\b",
        re.I,
    )

    pid_linked_identifiers: set[int] = set()
    bundle_linked_identifiers: set[int] = set()
    linkage_record_count = 0
    for record in trusted_coreaudio_records:
        record_message = message(record)
        contributed = False
        for pattern in (client_pid_pattern, context_pid_pattern):
            for match in pattern.finditer(record_message):
                pid_linked_identifiers.add(int(match.group("identifier")))
                contributed = True
        for match in bundle_client_pattern.finditer(record_message):
            bundle_linked_identifiers.add(int(match.group("identifier")))
            contributed = True
        if contributed:
            linkage_record_count += 1

    verified_client_identifiers = pid_linked_identifiers & bundle_linked_identifiers
    linkage_established = bool(verified_client_identifiers)
    correlated_identifiers = pid_linked_identifiers if linkage_established else set()

    def references_correlated_identifier(record: dict[str, Any]) -> bool:
        return any(
            int(match.group("identifier")) in correlated_identifiers
            for match in reference_pattern.finditer(message(record))
        )

    correlated_failures = [
        record
        for record in trusted_coreaudio_records
        if linkage_established and references_correlated_identifier(record)
    ]

    def optional_analytics_field(record_message: str, key: str) -> str | None:
        key_pattern = rf'(?:"{re.escape(key)}"|(?<![A-Za-z0-9_]){re.escape(key)}(?![A-Za-z0-9_]))'
        match = re.search(
            rf"{key_pattern}\s*[:=]\s*Optional\(\s*(?P<value>[^)]*?)\s*\)",
            record_message,
            re.I,
        )
        if match is None:
            return None
        return match.group("value").strip().strip('"')

    correlated_audioanalytics: list[tuple[dict[str, Any], str | None, str | None]] = []
    for record in trusted_audioanalytics_records:
        record_message = message(record)
        host_application = optional_analytics_field(record_message, "HostApplicationDisplayID")
        sample_rate_value = optional_analytics_field(record_message, "sample_rate")
        overload_type = optional_analytics_field(record_message, "overload_type")
        issue_type = optional_analytics_field(record_message, "issue_type")
        try:
            sample_rate = float(sample_rate_value) if sample_rate_value is not None else 0.0
        except ValueError:
            sample_rate = 0.0
        has_known_event = (
            overload_type in {"ClientTimeoutStart", "ClientTimeoutEnd"}
            or (issue_type is not None and issue_type.casefold() == "overload")
        )
        if host_application == bundle_identifier and sample_rate > 0 and has_known_event:
            correlated_audioanalytics.append((record, overload_type, issue_type))

    def is_core_overload_message(record_message: str) -> bool:
        return re.search(
            r"\b(?:HAL|IO)\s*overload\b|\boverload\s+(?:for\s+)?(?:ContextID|IOContext)\b",
            record_message,
            re.I,
        ) is not None

    context_timeouts = sum(bool(re.search(r"ClientTimeout", message(record), re.I)) for record in records)
    context_overloads = sum(
        bool(
            is_core_overload_message(message(record))
            or re.search(
                r'(?:(?:"issue_type")|issue_type)\s*[:=]\s*Optional\(\s*overload\s*\)',
                message(record),
                re.I,
            )
        )
        for record in records
    )
    coreaudio_coverage_count = linkage_record_count if linkage_established else 0
    analytics_coverage_count = len(correlated_audioanalytics)
    coverage_count = coreaudio_coverage_count + analytics_coverage_count
    client_timeouts = (
        sum(bool(re.search(r"ClientTimeout", message(record), re.I)) for record in correlated_failures)
        # Start is the incident. End is lifecycle closure and is not counted again.
        + sum(overload_type == "ClientTimeoutStart" for _, overload_type, _ in correlated_audioanalytics)
        if coverage_count > 0
        else None
    )
    hal_overloads = (
        sum(
            is_core_overload_message(message(record))
            for record in correlated_failures
        )
        + sum(
            issue_type is not None and issue_type.casefold() == "overload"
            for _, _, issue_type in correlated_audioanalytics
        )
        if coverage_count > 0
        else None
    )
    ark_mutes = (
        sum(
            bool(re.search(r"muted by com\.rogueamoeba\.ARK", message(record), re.I))
            and any(
                int(match.group("identifier")) in verified_client_identifiers
                for match in bundle_client_pattern.finditer(message(record))
            )
            for record in trusted_coreaudio_records
        )
        if coreaudio_coverage_count > 0
        else None
    )
    return {
        "client_timeouts": client_timeouts,
        "hal_overloads": hal_overloads,
        "ark_mutes": ark_mutes,
        "structured_coverage_count": coverage_count,
        "provenance": {
            "required_pid": expected_pid,
            "required_bundle_identifier": bundle_identifier,
            "trusted_emitter": {
                "processImagePath": "/usr/sbin/coreaudiod",
                "coreaudio_subsystem_prefix": "com.apple.coreaudio",
                "audioanalytics_subsystem_prefix": "com.apple.audioanalytics",
                "process_field_required": False,
            },
            "rule": "CoreAudio failures require owned-PID numeric linkage plus Umbra bundle linkage; AudioAnalytics failures require exact HostApplicationDisplayID, positive sample_rate, and parsed cause/overload fields",
            "verified_client_identifiers": sorted(verified_client_identifiers),
            "correlated_identifiers": sorted(correlated_identifiers),
            "trusted_emitter_process_ids": sorted({
                record["processID"]
                for record in trusted_image_records
                if isinstance(record.get("processID"), int)
                and not isinstance(record.get("processID"), bool)
            }),
            "trusted_coreaudio_record_count": len(trusted_coreaudio_records),
            "trusted_audioanalytics_record_count": len(trusted_audioanalytics_records),
            "coreaudio_linkage_coverage_count": coreaudio_coverage_count,
            "audioanalytics_host_coverage_count": analytics_coverage_count,
            "audioanalytics_client_timeout_start_count": sum(
                overload_type == "ClientTimeoutStart"
                for _, overload_type, _ in correlated_audioanalytics
            ),
            "audioanalytics_client_timeout_end_count": sum(
                overload_type == "ClientTimeoutEnd"
                for _, overload_type, _ in correlated_audioanalytics
            ),
            "audioanalytics_timeout_semantics": "ClientTimeoutStart counts one incident; ClientTimeoutEnd is retained as lifecycle evidence and does not increment the incident counter",
        },
        "environment_context": {
            "client_timeouts": context_timeouts,
            "hal_overloads": context_overloads,
            "record_count": len(records),
        },
    }


def parse_json_lines(text: str) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for line_number, raw_line in enumerate(text.splitlines(), start=1):
        stripped = raw_line.strip()
        if not stripped:
            continue
        try:
            value = json.loads(stripped)
        except json.JSONDecodeError as error:
            raise ValueError(f"invalid JSONL record at line {line_number}: {error.msg}") from error
        if not isinstance(value, dict):
            raise ValueError(f"JSONL record at line {line_number} must be an object")
        records.append(value)
    return records


def nearest_rank_summary_nanoseconds(values: list[int], provenance: str, evidence: str) -> dict[str, Any]:
    """Return nearest-rank millisecond percentiles over nonnegative durations."""
    ordered = sorted(values)
    if not ordered:
        raise ValueError("cannot summarize an empty duration set")

    def percentile(percent: int) -> float:
        rank = max(1, math.ceil(percent / 100 * len(ordered)))
        return round(ordered[rank - 1] / 1_000_000, 6)

    return {
        "samples": len(ordered),
        "p50": percentile(50),
        "p95": percentile(95),
        "p99": percentile(99),
        "evidence": evidence,
        "provenance": provenance,
    }


def parse_input_network_decomposition(
    records: list[dict[str, Any]],
    expected_run_id: str,
    expected_trace_id: str,
) -> dict[str, Any]:
    """Derive combined network transit without comparing machine clock epochs."""
    matching = [
        record
        for record in records
        if record.get("type") == "input_trace"
        and record.get("run_id") == expected_run_id
        and record.get("trace_id") == expected_trace_id
    ]
    if not matching:
        return {
            "available": False,
            "errors": [],
            "samples": 0,
            "metrics": {},
            "method": "unavailable",
        }

    errors: list[str] = []
    seen_event_ids: set[int] = set()
    selected_mode: str | None = None
    selected_client_protocol: str | None = None
    observed: list[int] = []
    processing: list[int] = []
    network: list[int] = []
    client_input: list[int] = []
    host_pipeline: list[int] = []
    client_video: list[int] = []
    measurement_error_bounds: list[int] = []
    fields = (
        "observed_input_to_present_submit_ns",
        "client_input_to_send_ns",
        "host_receive_to_video_send_ns",
        "client_video_receive_to_present_submit_ns",
    )
    for index, record in enumerate(matching, start=1):
        event_id = record.get("input_event_id")
        frame_id = record.get("changed_frame_id")
        mode = record.get("mode")
        client_protocol = record.get("client_protocol")
        if mode not in {"latency", "quality"}:
            errors.append(f"input trace {index} has invalid mode")
            continue
        if client_protocol not in {"vanilla-moonlight", "umbra-legacy", "umbra-v2"}:
            errors.append(f"input trace {index} has invalid client protocol")
            continue
        if selected_mode is None:
            selected_mode = mode
        elif selected_mode != mode:
            errors.append("input traces from different optimization modes cannot be aggregated")
            continue
        if selected_client_protocol is None:
            selected_client_protocol = client_protocol
        elif selected_client_protocol != client_protocol:
            errors.append("input traces from different client protocols cannot be aggregated")
            continue
        if (
            not isinstance(event_id, int)
            or isinstance(event_id, bool)
            or event_id <= 0
            or event_id in seen_event_ids
            or not isinstance(frame_id, int)
            or isinstance(frame_id, bool)
            or frame_id <= 0
            or record.get("correlation") != "causal_input_frame_watermark_v1"
        ):
            errors.append(f"input trace {index} has invalid or duplicate causal identity")
            continue
        values = [record.get(field) for field in fields]
        if not all(
            isinstance(value, int) and not isinstance(value, bool) and value >= 0
            for value in values
        ):
            errors.append(f"input trace {event_id} has invalid duration fields")
            continue
        measurement_error_bound = record.get("measurement_error_bound_ns")
        if (
            not isinstance(measurement_error_bound, int)
            or isinstance(measurement_error_bound, bool)
            or measurement_error_bound < 0
        ):
            errors.append(f"input trace {event_id} has invalid measurement error bound")
            continue
        total, input_duration, host_duration, video_duration = values
        processing_duration = input_duration + host_duration + video_duration
        if processing_duration > total:
            errors.append(f"input trace {event_id} has processing durations exceeding observed latency")
            continue
        seen_event_ids.add(event_id)
        observed.append(total)
        processing.append(processing_duration)
        network.append(total - processing_duration)
        client_input.append(input_duration)
        host_pipeline.append(host_duration)
        client_video.append(video_duration)
        measurement_error_bounds.append(measurement_error_bound)

    if errors or not observed:
        return {
            "available": False,
            "errors": errors or ["no valid matching input traces"],
            "samples": 0,
            "metrics": {},
            "method": "invalid",
        }

    provenance = (
        "Per-event causal input/frame watermark; client end-to-end duration minus "
        "same-machine client-input, host-pipeline, and client-video durations"
    )
    return {
        "available": True,
        "errors": [],
        "samples": len(observed),
        "mode": selected_mode,
        "client_protocol": selected_client_protocol,
        "method": "offset_free_combined_two_leg_network_residual_v1",
        "one_way_split_available": False,
        "maximum_measurement_error_bound_ns": max(measurement_error_bounds),
        "metrics": {
            "observed_input_to_present_submit_ms": nearest_rank_summary_nanoseconds(
                observed, provenance, "client_monotonic_causal_input_to_present_submit"
            ),
            "combined_network_transit_residual_ms": nearest_rank_summary_nanoseconds(
                network, provenance, "observed_minus_correlated_same_machine_processing"
            ),
            "host_client_processing_residual_ms": nearest_rank_summary_nanoseconds(
                processing, provenance, "sum_of_correlated_same_machine_processing"
            ),
            "client_input_to_send_ms": nearest_rank_summary_nanoseconds(
                client_input, provenance, "client_monotonic"
            ),
            "host_receive_to_video_send_ms": nearest_rank_summary_nanoseconds(
                host_pipeline, provenance, "host_monotonic"
            ),
            "client_video_receive_to_present_submit_ms": nearest_rank_summary_nanoseconds(
                client_video, provenance, "client_monotonic"
            ),
        },
    }


def parse_client_telemetry(
    text: str,
    expected_run_id: str,
    expected_trace_id: str,
) -> dict[str, Any]:
    errors: list[str] = []
    records = parse_json_lines(text)
    matching = [
        record
        for record in records
        if record.get("type") == "latency_summary"
        and record.get("run_id") == expected_run_id
        and record.get("trace_id") == expected_trace_id
    ]
    if len(matching) != 1:
        errors.append(f"expected exactly one matching telemetry summary, found {len(matching)}")
        return {
            "valid": False,
            "errors": errors,
            "clock_domain": "client_monotonic_durations",
            "summary_count": len(matching),
            "metrics": {},
            "input_network_decomposition": parse_input_network_decomposition(
                records, expected_run_id, expected_trace_id
            ),
        }

    record = matching[0]
    optimization_mode = record.get("optimization_mode")
    client_protocol = record.get("client_protocol")
    if optimization_mode not in {"latency", "quality"}:
        errors.append("telemetry summary has invalid optimization mode")
    if client_protocol not in {"vanilla-moonlight", "umbra-legacy", "umbra-v2"}:
        errors.append("telemetry summary has invalid client protocol")
    provenance = record.get("provenance")
    if not isinstance(provenance, str) or not provenance.strip():
        errors.append("telemetry summary is missing provenance")
    raw_metrics = record.get("metrics")
    if not isinstance(raw_metrics, dict) or not raw_metrics:
        errors.append("telemetry summary has no metrics")
        raw_metrics = {}
    validated_metrics: dict[str, Any] = {}
    for name, value in raw_metrics.items():
        if not isinstance(value, dict):
            errors.append(f"telemetry metric {name} is not an object")
            continue
        samples = value.get("samples")
        percentiles = [value.get("p50"), value.get("p95"), value.get("p99")]
        valid_samples = isinstance(samples, int) and not isinstance(samples, bool) and samples > 0
        valid_percentiles = all(
            isinstance(item, (int, float))
            and not isinstance(item, bool)
            and math.isfinite(float(item))
            and float(item) >= 0
            for item in percentiles
        )
        ordered = valid_percentiles and percentiles[0] <= percentiles[1] <= percentiles[2]
        if not valid_samples or not valid_percentiles or not ordered:
            errors.append(f"telemetry metric {name} has invalid samples or percentile ordering")
            continue
        validated_metrics[name] = dict(value)
        validated_metrics[name]["provenance"] = provenance

    metrics = {} if errors else validated_metrics
    return {
        "valid": not errors,
        "errors": errors,
        "clock_domain": "client_monotonic_durations",
        "summary_count": 1,
        "optimization_mode": optimization_mode,
        "client_protocol": client_protocol,
        "metrics": metrics,
        "input_network_decomposition": parse_input_network_decomposition(
            records, expected_run_id, expected_trace_id
        ),
    }


def parse_runner_events(
    text: str,
    expected_run_id: str | None = None,
    expected_trace_id: str | None = None,
) -> dict[str, Any]:
    events: list[dict[str, Any]] = []
    errors: list[str] = []
    event_names: set[str] = set()
    matrix: dict[str, Any] | None = None
    for record in parse_json_lines(text):
        if (
            not isinstance(record.get("event"), str)
            or not isinstance(record.get("wall_timestamp"), str)
            or not isinstance(record.get("monotonic_ns"), int)
        ):
            continue
        if expected_run_id is not None and record.get("run_id") != expected_run_id:
            continue
        if expected_trace_id is not None and record.get("trace_id") != expected_trace_id:
            continue
        if record["event"] in event_names:
            errors.append(f"multiple runner events named {record['event']}")
            continue
        event_names.add(record["event"])
        record_matrix = record.get("matrix")
        if record_matrix is not None:
            if not isinstance(record_matrix, dict):
                errors.append("runner event matrix must be an object")
                continue
            if matrix is None:
                matrix = record_matrix
            elif matrix != record_matrix:
                errors.append("runner events from different matrices cannot be merged")
                continue
        events.append(
            {
                "name": record["event"],
                "wall_timestamp": iso_timestamp(parse_timestamp(record["wall_timestamp"])),
                "monotonic_ns": record["monotonic_ns"],
                "source": "benchmark.runner",
                "clock_domain": "client_monotonic",
                "precision": record.get("precision", {}),
                "evidence": record.get("evidence", record["event"]),
                "run_id": record.get("run_id"),
                "trace_id": record.get("trace_id"),
            }
        )
    events.sort(key=lambda item: item["monotonic_ns"])
    if errors:
        events = []
    return {
        "valid": not errors,
        "errors": errors,
        "clock_domain": "client_monotonic",
        "events": events,
        "matrix": matrix or {
            "network_kind": "unknown",
            "optimization_mode": "unknown",
            "client_protocol": "umbra-legacy",
            "host": "unknown",
        },
    }


def first_event(*collections: dict[str, Any], name: str) -> dict[str, Any] | None:
    candidates = [
        item
        for collection in collections
        for item in collection.get("events", [])
        if item.get("name") == name
    ]
    if not candidates:
        return None
    if all("monotonic_ns" in item for item in candidates):
        return min(candidates, key=lambda item: item["monotonic_ns"])
    return min(candidates, key=lambda item: parse_timestamp(item["timestamp"]))


def same_clock_interval_ms(start: dict[str, Any] | None, end: dict[str, Any] | None) -> float | None:
    if start is None or end is None or start.get("clock_domain") != end.get("clock_domain"):
        return None
    if "monotonic_ns" in start and "monotonic_ns" in end:
        interval_ns = end["monotonic_ns"] - start["monotonic_ns"]
        return round(interval_ns / 1_000_000, 6) if interval_ns >= 0 else None
    interval = (parse_timestamp(end["timestamp"]) - parse_timestamp(start["timestamp"])).total_seconds() * 1000
    return round(interval, 3) if interval >= 0 else None


def uncertain_log_interval(
    start: dict[str, Any] | None,
    end: dict[str, Any] | None,
) -> dict[str, Any] | None:
    value = same_clock_interval_ms(start, end)
    if value is None:
        return None
    return {
        "value_ms": value,
        "uncertainty_ms": 1_000.0,
        "basis": "ISO support-log timestamps; emitting build may have one-second granularity",
        "threshold_eligible": False,
    }


def reported_library_interval(value: Any) -> dict[str, Any] | None:
    if not isinstance(value, (int, float)) or not math.isfinite(float(value)) or value < 0:
        return None
    return {
        "value_ms": float(value),
        "uncertainty_ms": 100.0,
        "basis": "Moonlight library reported rounded elapsed duration",
        "threshold_eligible": False,
    }


def build_report(
    *,
    run_id: str,
    trace_id: str,
    runner: dict[str, Any],
    umbra: dict[str, Any],
    lumen: dict[str, Any],
    coreaudio: dict[str, Any],
    telemetry: dict[str, Any],
) -> dict[str, Any]:
    launch = first_event(umbra, name="launch_request")
    accepted = first_event(umbra, name="session_accepted")
    rtsp = first_event(umbra, name="rtsp_start")
    first_video = first_event(umbra, name="first_video_packet")
    first_audio = first_event(umbra, name="first_audio_packet")
    first_decoded = first_event(umbra, name="first_decoded_frame")
    audio_warmup = first_event(umbra, name="audio_warmup_started")

    startup = {
        "launch_request_to_audio_warmup": uncertain_log_interval(launch, audio_warmup),
        "launch_request_to_session_accepted": uncertain_log_interval(launch, accepted),
        "launch_request_to_rtsp_start": uncertain_log_interval(launch, rtsp),
        "launch_request_to_first_video_packet": uncertain_log_interval(launch, first_video),
        "launch_request_to_first_audio_packet": uncertain_log_interval(launch, first_audio),
        "launch_request_to_first_decoded_frame": uncertain_log_interval(launch, first_decoded),
        "rtsp_to_first_video_packet_reported": reported_library_interval(
            umbra.get("reported_intervals_ms", {}).get("rtsp_to_first_video_packet")
        ),
        "rtsp_to_first_audio_packet_reported": reported_library_interval(
            umbra.get("reported_intervals_ms", {}).get("rtsp_to_first_audio_packet")
        ),
    }
    coreaudio_metrics = {
        key: value
        for key, value in coreaudio.items()
        if key not in {"environment_context", "provenance"}
    }
    required_runner_events = {
        "launch_request",
        "graceful_stop_requested",
        "audio_restored",
        "client_exit_confirmed",
        "coreaudio_postroll_end",
    }
    observed_runner_events = {item.get("name") for item in runner.get("events", [])}
    missing_required = [
        f"runner.{name}" for name in sorted(required_runner_events - observed_runner_events)
    ]
    if not runner.get("valid", False):
        missing_required.append("runner.single_run_event_set")
    if not umbra.get("valid", False):
        missing_required.append("umbra.single_session_log")
    if not umbra.get("audio"):
        missing_required.append("umbra.audio_renderer_summary")
    if (
        not coreaudio.get("provenance")
        or coreaudio.get("structured_coverage_count", 0) <= 0
    ):
        missing_required.append("coreaudio.pid_and_bundle_correlated_window")
    if telemetry and not telemetry.get("valid", False):
        missing_required.append("client_telemetry.externally_correlated_summary")
    if lumen and not lumen.get("valid", False):
        missing_required.append("lumen.externally_correlated_stages")
    decomposition = telemetry.get("input_network_decomposition", {})
    declared_mode = runner.get("matrix", {}).get("optimization_mode", "unknown")
    declared_protocol = runner.get("matrix", {}).get("client_protocol")
    summary_mode_mismatch = (
        telemetry.get("valid", False)
        and declared_mode != "unknown"
        and telemetry.get("optimization_mode") != declared_mode
    )
    summary_protocol_mismatch = (
        telemetry.get("valid", False)
        and declared_protocol is not None
        and telemetry.get("client_protocol") != declared_protocol
    )
    matrix_mode_mismatch = (
        decomposition.get("available", False)
        and declared_mode != "unknown"
        and decomposition.get("mode") != declared_mode
    )
    decomposition_protocol_mismatch = (
        decomposition.get("available", False)
        and declared_protocol is not None
        and decomposition.get("client_protocol") != declared_protocol
    )
    summary_decomposition_mode_mismatch = (
        decomposition.get("available", False)
        and telemetry.get("valid", False)
        and telemetry.get("optimization_mode") != decomposition.get("mode")
    )
    summary_decomposition_protocol_mismatch = (
        decomposition.get("available", False)
        and telemetry.get("valid", False)
        and telemetry.get("client_protocol") != decomposition.get("client_protocol")
    )
    invalid_decomposition = decomposition.get("method") == "invalid"
    if summary_mode_mismatch or matrix_mode_mismatch:
        missing_required.append("matrix.optimization_mode_matches_telemetry")
    if summary_protocol_mismatch or decomposition_protocol_mismatch:
        missing_required.append("matrix.client_protocol_matches_telemetry")
    if invalid_decomposition:
        missing_required.append("client_telemetry.valid_input_network_decomposition")
    if summary_decomposition_mode_mismatch or summary_decomposition_protocol_mismatch:
        missing_required.append("client_telemetry.summary_matches_input_traces")

    return {
        "schema_version": SCHEMA_VERSION,
        "run_id": run_id,
        "trace_id": trace_id,
        "generated_at": iso_timestamp(datetime.now(timezone.utc)),
        "matrix": runner.get("matrix", {
            "network_kind": "unknown",
            "optimization_mode": "unknown",
            "client_protocol": "umbra-legacy",
            "host": "unknown",
        }),
        "correlation": {
            "client": "runner monotonic observations; wall-log events remain a separate evidence timeline",
            "host": lumen.get("correlation", {}).get("method", "unavailable"),
            "cross_clock": "not calibrated",
        },
        "evidence_status": {
            "status": "complete" if not missing_required else "insufficient_data",
            "missing_required": missing_required,
            "parse_errors": (
                runner.get("errors", [])
                + umbra.get("errors", [])
                + telemetry.get("errors", [])
                + lumen.get("errors", [])
                + decomposition.get("errors", [])
                + (["telemetry mode does not match the declared run matrix"] if summary_mode_mismatch or matrix_mode_mismatch else [])
                + (["telemetry client protocol does not match the declared run matrix"] if summary_protocol_mismatch or decomposition_protocol_mismatch else [])
                + (["latency summary does not match input trace mode/client protocol"] if summary_decomposition_mode_mismatch or summary_decomposition_protocol_mismatch else [])
            ),
        },
        "startup": startup,
        "timelines": {
            "client_monotonic": runner.get("events", []),
            "client_wall_log": umbra.get("events", []),
            "host_explicit_trace": lumen.get("events", []),
        },
        "audio": umbra.get("audio", {}),
        "coreaudio": coreaudio_metrics,
        "client_telemetry": telemetry.get("metrics", {}),
        "telemetry_matrix": {
            "optimization_mode": telemetry.get("optimization_mode", "unknown"),
            "client_protocol": telemetry.get("client_protocol", "unknown"),
        },
        "input_network_decomposition": telemetry.get(
            "input_network_decomposition",
            {
                "available": False,
                "errors": [],
                "samples": 0,
                "metrics": {},
                "method": "unavailable",
            },
        ),
        "host_stages_ms": lumen.get("durations_ms", {}),
        "measurement_provenance": {
            "coreaudio": coreaudio.get("provenance", {}),
            "client_telemetry": sorted({
                metric.get("provenance", "")
                for metric in telemetry.get("metrics", {}).values()
                if metric.get("provenance")
            }),
            "client_log": (
                "one selected file/window; live runner additionally records PID identity and lsof binding"
                if umbra.get("valid", False)
                else "unavailable"
            ),
        },
        "environment_context": {
            "coreaudio": coreaudio.get("environment_context", {}),
            "lumen_uncorrelated": lumen.get("environment_context", []),
        },
        "unavailable_metrics": [
            {
                "metric": "host_to_client_cross_clock_latency",
                "reason": "Host and client wall clocks were not calibrated to a bounded uncertainty.",
            },
            {
                "metric": "input_to_photon_latency",
                "reason": "Requires a synchronized input stimulus and optical high-speed capture or equivalent hardware.",
            },
            {
                "metric": "actual_scanout_latency",
                "reason": "Metal presentation proxies are not proof of panel scanout or photon emission.",
            },
            *(
                []
                if telemetry.get("input_network_decomposition", {}).get("available", False)
                else [{
                    "metric": "input_network_factor_decomposition",
                    "reason": "No causally matched per-event input/change-frame traces were supplied; ping/RTT is not substituted.",
                }]
            ),
            *(
                []
                if telemetry.get("valid", False) and telemetry.get("metrics")
                else [{
                    "metric": "client_latency_percentiles",
                    "reason": "Production does not emit benchmark run IDs; no externally correlated telemetry summary was supplied.",
                }]
            ),
            *(
                []
                if lumen.get("correlation", {}).get("matched_trace_id")
                else [{
                    "metric": "host_pipeline_stages",
                    "reason": "No Lumen records carried the exact benchmark trace ID; uncorrelated host logs remain environment context only.",
                }]
            ),
        ],
    }


def nested_value(document: dict[str, Any], path: str) -> Any:
    value: Any = document
    for component in path.split("."):
        if not isinstance(value, dict) or component not in value:
            return None
        value = value[component]
    return value


def evaluate_thresholds(report: dict[str, Any], thresholds: dict[str, Any]) -> dict[str, Any]:
    checks: list[dict[str, Any]] = []
    evidence_insufficient = report.get("evidence_status", {}).get("status") != "complete"
    missing_configured_metric = False
    overall = "insufficient_data" if evidence_insufficient else "pass"
    rank = {"pass": 0, "unavailable": 0, "warn": 1, "fail": 2, "insufficient_data": 3}
    for threshold in thresholds.get("checks", []):
        metric = threshold["metric"]
        value = nested_value(report, metric)
        status = "unavailable"
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            if value > threshold["fail_above"]:
                status = "fail"
            elif value > threshold["warn_above"]:
                status = "warn"
            else:
                status = "pass"
        if status == "unavailable":
            missing_configured_metric = True
        if not evidence_insufficient and rank[status] > rank[overall]:
            overall = status
        checks.append(
            {
                "metric": metric,
                "value": value,
                "warn_above": threshold["warn_above"],
                "fail_above": threshold["fail_above"],
                "status": status,
            }
        )
    if evidence_insufficient or missing_configured_metric:
        overall = "insufficient_data"
    return {"status": overall, "checks": checks}


def display_value(value: Any) -> str:
    if value is None:
        return "unavailable"
    if isinstance(value, float):
        return f"{value:.3f}".rstrip("0").rstrip(".")
    return str(value)


def render_markdown(report: dict[str, Any]) -> str:
    lines = [
        "# Umbra/Lumen Performance Run",
        "",
        f"- Run ID: `{report['run_id']}`",
        f"- Trace ID: `{report['trace_id']}`",
        f"- Matrix: `{json.dumps(report.get('matrix', {}), sort_keys=True)}`",
        f"- Generated: {report['generated_at']}",
        f"- Evidence status: **{report.get('evidence_status', {}).get('status', 'insufficient_data')}**",
        f"- Threshold status: **{report.get('threshold_evaluation', {}).get('status', 'not evaluated')}**",
        f"- Telemetry matrix: `{json.dumps(report.get('telemetry_matrix', {}), sort_keys=True)}`",
        "",
        "## Startup",
        "",
        "| Metric | Milliseconds | Uncertainty | Basis |",
        "| --- | ---: | ---: | --- |",
    ]
    for name, measurement in report.get("startup", {}).items():
        if isinstance(measurement, dict):
            lines.append(
                f"| `{name}` | {display_value(measurement.get('value_ms'))} | "
                f"±{display_value(measurement.get('uncertainty_ms'))} ms | "
                f"{measurement.get('basis', 'unavailable')} |"
            )
        else:
            lines.append(f"| `{name}` | unavailable | not applicable | not applicable |")

    lines.extend([
        "", "## Client latency telemetry", "",
        "| Metric | Samples | p50 | p95 | p99 | Evidence | Provenance |",
        "| --- | ---: | ---: | ---: | ---: | --- | --- |",
    ])
    for name, summary in report.get("client_telemetry", {}).items():
        lines.append(
            f"| `{name}` | {display_value(summary.get('samples'))} | "
            f"{display_value(summary.get('p50'))} | {display_value(summary.get('p95'))} | "
            f"{display_value(summary.get('p99'))} | "
            f"{summary.get('evidence', 'unspecified software duration')} | "
            f"{summary.get('provenance', 'unavailable')} |"
        )
    if not report.get("client_telemetry"):
        lines.append("| unavailable | not applicable | not applicable | not applicable | not applicable | not applicable | not applicable |")

    decomposition = report.get("input_network_decomposition", {})
    lines.extend([
        "",
        "## Input/network decomposition",
        "",
        f"- Mode: `{decomposition.get('mode', 'unavailable')}`",
        f"- Client protocol: `{decomposition.get('client_protocol', 'unavailable')}`",
        f"- Method: `{decomposition.get('method', 'unavailable')}`",
        "- One-way split: unavailable (combined uplink + downlink only)",
        f"- Maximum measurement error bound: `{decomposition.get('maximum_measurement_error_bound_ns', 'unavailable')} ns`",
        "",
        "| Metric | Samples | p50 | p95 | p99 |",
        "| --- | ---: | ---: | ---: | ---: |",
    ])
    for name, summary in decomposition.get("metrics", {}).items():
        lines.append(
            f"| `{name}` | {display_value(summary.get('samples'))} | "
            f"{display_value(summary.get('p50'))} | {display_value(summary.get('p95'))} | "
            f"{display_value(summary.get('p99'))} |"
        )
    if not decomposition.get("available", False):
        lines.append("| unavailable | not applicable | not applicable | not applicable | not applicable |")
        for error in decomposition.get("errors", []):
            lines.append(f"- Rejected input trace evidence: {error}")

    lines.extend(["", "## Audio health", "", "| Metric | Value |", "| --- | ---: |"])
    for section in ("audio", "coreaudio"):
        for name, value in report.get(section, {}).items():
            lines.append(f"| `{section}.{name}` | {display_value(value)} |")
    if not report.get("audio") and not report.get("coreaudio"):
        lines.append("| unavailable | not applicable |")

    lines.extend(["", "## Host stages", "", "| Metric | Milliseconds |", "| --- | ---: |"])
    for name, value in report.get("host_stages_ms", {}).items():
        lines.append(f"| `{name}` | {display_value(value)} |")
    if not report.get("host_stages_ms"):
        lines.append("| unavailable | not applicable |")

    missing = report.get("evidence_status", {}).get("missing_required", [])
    lines.extend(["", "## Evidence completeness", ""])
    if missing:
        lines.append("Required evidence is incomplete; this run cannot pass regression gates:")
        lines.append("")
        for item in missing:
            lines.append(f"- `{item}`")
    else:
        lines.append("All required client-local evidence was present and unambiguous.")

    context = report.get("environment_context", {})
    lines.extend(["", "## Uncorrelated environment context", ""])
    lines.append(
        "This context is retained for diagnosis only. It is not merged into client or host performance measurements."
    )
    lines.append("")
    lines.append(f"- CoreAudio: `{json.dumps(context.get('coreaudio', {}), sort_keys=True)}`")
    lines.append(f"- Lumen uncorrelated records: {len(context.get('lumen_uncorrelated', []))}")

    lines.extend(["", "## Measurement limitations", ""])
    labels = {
        "input_to_photon_latency": "Input-to-photon latency",
        "host_to_client_cross_clock_latency": "Host-to-client cross-clock latency",
        "actual_scanout_latency": "Actual scanout latency",
    }
    for item in report.get("unavailable_metrics", []):
        label = labels.get(item["metric"], item["metric"])
        lines.append(f"- **{label}: unavailable.** {item['reason']}")

    checks = report.get("threshold_evaluation", {}).get("checks", [])
    lines.extend(["", "## Regression thresholds", "", "| Metric | Value | Status |", "| --- | ---: | --- |"])
    for check in checks:
        lines.append(f"| `{check['metric']}` | {display_value(check['value'])} | {check['status']} |")
    if not checks:
        lines.append("| not evaluated | not applicable | not applicable |")
    lines.append("")
    return "\n".join(lines)


def read_optional(path: str | None) -> str:
    return Path(path).read_text(encoding="utf-8", errors="replace") if path else ""


def validate_thresholds(thresholds: dict[str, Any]) -> None:
    if thresholds.get("schema_version") != 1 or not isinstance(thresholds.get("checks"), list):
        raise ValueError("threshold file does not match schema version 1")
    seen: set[str] = set()
    for index, check in enumerate(thresholds["checks"]):
        if not isinstance(check, dict) or not isinstance(check.get("metric"), str):
            raise ValueError(f"threshold check {index} is invalid")
        metric = check["metric"]
        if metric.startswith("startup."):
            raise ValueError("coarse support-log startup intervals are not threshold-eligible")
        if metric in seen:
            raise ValueError(f"duplicate threshold metric: {metric}")
        seen.add(metric)
        warn = check.get("warn_above")
        fail = check.get("fail_above")
        if not all(
            isinstance(value, (int, float))
            and not isinstance(value, bool)
            and math.isfinite(float(value))
            and value >= 0
            for value in (warn, fail)
        ) or warn > fail:
            raise ValueError(f"threshold check {metric} has invalid bounds")


def validate_schema_contract(schema: dict[str, Any]) -> None:
    required = {
        "schema_version",
        "run_id",
        "trace_id",
        "generated_at",
        "matrix",
        "correlation",
        "evidence_status",
        "startup",
        "timelines",
        "audio",
        "coreaudio",
        "client_telemetry",
        "telemetry_matrix",
        "input_network_decomposition",
        "host_stages_ms",
        "measurement_provenance",
        "environment_context",
        "unavailable_metrics",
    }
    if schema.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
        raise ValueError("unsupported report schema declaration")
    if schema.get("properties", {}).get("schema_version", {}).get("const") != SCHEMA_VERSION:
        raise ValueError("report schema version does not match parser")
    if not required.issubset(set(schema.get("required", []))):
        raise ValueError(f"report schema omits required version-{SCHEMA_VERSION} fields")


def validate_schema_instance(
    instance: Any,
    schema: dict[str, Any],
    root_schema: dict[str, Any],
    path: str,
) -> None:
    """Validate the dependency-free JSON-Schema subset used by schema.json."""
    reference = schema.get("$ref")
    if reference is not None:
        if not isinstance(reference, str) or not reference.startswith("#/"):
            raise ValueError(f"unsupported schema reference at {path}")
        target: Any = root_schema
        for component in reference[2:].split("/"):
            component = component.replace("~1", "/").replace("~0", "~")
            if not isinstance(target, dict) or component not in target:
                raise ValueError(f"unresolved schema reference at {path}")
            target = target[component]
        if not isinstance(target, dict):
            raise ValueError(f"schema reference is not an object at {path}")
        validate_schema_instance(instance, target, root_schema, path)
        return

    variants = schema.get("oneOf")
    if variants is not None:
        matches = 0
        for variant in variants:
            try:
                validate_schema_instance(instance, variant, root_schema, path)
                matches += 1
            except ValueError:
                pass
        if matches != 1:
            raise ValueError(f"schema oneOf mismatch at {path}")
        return

    if "const" in schema:
        expected = schema["const"]
        if type(instance) is not type(expected) or instance != expected:
            raise ValueError(f"schema const mismatch at {path}")
    if "enum" in schema and not any(
        type(instance) is type(candidate) and instance == candidate
        for candidate in schema["enum"]
    ):
        raise ValueError(f"schema enum mismatch at {path}")

    declared_types = schema.get("type")
    if declared_types is not None:
        names = [declared_types] if isinstance(declared_types, str) else declared_types

        def matches_type(name: str) -> bool:
            return {
                "null": instance is None,
                "boolean": isinstance(instance, bool),
                "integer": isinstance(instance, int) and not isinstance(instance, bool),
                "number": isinstance(instance, (int, float)) and not isinstance(instance, bool),
                "string": isinstance(instance, str),
                "array": isinstance(instance, list),
                "object": isinstance(instance, dict),
            }.get(name, False)

        if not isinstance(names, list) or not all(isinstance(name, str) for name in names):
            raise ValueError(f"invalid schema type declaration at {path}")
        if not any(matches_type(name) for name in names):
            raise ValueError(f"schema type mismatch at {path}")

    if isinstance(instance, (int, float)) and not isinstance(instance, bool):
        if not math.isfinite(float(instance)):
            raise ValueError(f"non-finite schema number at {path}")
        if "minimum" in schema and instance < schema["minimum"]:
            raise ValueError(f"schema minimum violation at {path}")
    if isinstance(instance, str):
        if "minLength" in schema and len(instance) < schema["minLength"]:
            raise ValueError(f"schema string length violation at {path}")
        if schema.get("format") == "date-time":
            if re.fullmatch(
                r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})",
                instance,
            ) is None:
                raise ValueError(f"schema date-time violation at {path}")
            try:
                parse_timestamp(instance)
            except (TypeError, ValueError) as error:
                raise ValueError(f"schema date-time violation at {path}") from error
    if isinstance(instance, list) and isinstance(schema.get("items"), dict):
        for index, item in enumerate(instance):
            validate_schema_instance(item, schema["items"], root_schema, f"{path}[{index}]")
    if isinstance(instance, dict):
        required = schema.get("required", [])
        if not isinstance(required, list) or not all(isinstance(name, str) for name in required):
            raise ValueError(f"invalid schema required declaration at {path}")
        missing = [name for name in required if name not in instance]
        if missing:
            raise ValueError(f"schema required property missing at {path}.{missing[0]}")
        properties = schema.get("properties", {})
        if not isinstance(properties, dict):
            raise ValueError(f"invalid schema properties declaration at {path}")
        additional = schema.get("additionalProperties", True)
        for name, value in instance.items():
            if name in properties:
                validate_schema_instance(value, properties[name], root_schema, f"{path}.{name}")
            elif additional is False:
                raise ValueError(f"schema additional property at {path}.{name}")
            elif isinstance(additional, dict):
                validate_schema_instance(value, additional, root_schema, f"{path}.{name}")


def validate_report(report: dict[str, Any], schema: dict[str, Any]) -> None:
    validate_schema_contract(schema)
    validate_schema_instance(report, schema, schema, "report")
    for field in schema["required"]:
        if field not in report:
            raise ValueError(f"report omits required field: {field}")
    if report.get("schema_version") != SCHEMA_VERSION:
        raise ValueError("report schema version mismatch")
    matrix = report.get("matrix")
    if not isinstance(matrix, dict):
        raise ValueError("report matrix is missing")
    if matrix.get("network_kind") not in {"lan", "wifi", "vpn", "cellular", "wan", "unknown"}:
        raise ValueError("report matrix has invalid network kind")
    if matrix.get("optimization_mode") not in {"latency", "quality", "unknown"}:
        raise ValueError("report matrix has invalid optimization mode")
    if matrix.get("client_protocol") not in {"vanilla-moonlight", "umbra-legacy", "umbra-v2"}:
        raise ValueError("report matrix has invalid client protocol")
    telemetry_matrix = report.get("telemetry_matrix")
    if not isinstance(telemetry_matrix, dict):
        raise ValueError("telemetry matrix is missing")
    if "timeline" in report or not isinstance(report.get("timelines"), dict):
        raise ValueError("report must keep calibrated clock domains in separate timelines")
    status = report.get("evidence_status", {}).get("status")
    if status not in {"complete", "insufficient_data"}:
        raise ValueError("invalid evidence status")
    timelines = report["timelines"]
    expected_domains = {
        "client_monotonic": "client_monotonic",
        "client_wall_log": "client_wall_clock",
        "host_explicit_trace": "host_wall_clock",
    }
    for timeline_name, expected_domain in expected_domains.items():
        events = timelines.get(timeline_name)
        if not isinstance(events, list):
            raise ValueError(f"missing timeline: {timeline_name}")
        for timeline_event in events:
            if not isinstance(timeline_event, dict) or timeline_event.get("clock_domain") != expected_domain:
                raise ValueError(f"clock-domain violation in {timeline_name}")
            if expected_domain == "client_monotonic" and not isinstance(
                timeline_event.get("monotonic_ns"), int
            ):
                raise ValueError("client monotonic event is missing monotonic_ns")
    for metric_name, metric in report.get("client_telemetry", {}).items():
        if not isinstance(metric.get("provenance"), str) or not metric["provenance"]:
            raise ValueError(f"telemetry metric {metric_name} is missing provenance")
        values = [metric.get("p50"), metric.get("p95"), metric.get("p99")]
        if not all(isinstance(value, (int, float)) and math.isfinite(float(value)) for value in values):
            raise ValueError(f"telemetry metric {metric_name} has non-finite percentiles")
        if not values[0] <= values[1] <= values[2]:
            raise ValueError(f"telemetry metric {metric_name} has unordered percentiles")
    decomposition = report.get("input_network_decomposition", {})
    if not isinstance(decomposition, dict) or not isinstance(decomposition.get("available"), bool):
        raise ValueError("input network decomposition is malformed")
    if decomposition.get("available"):
        if decomposition.get("mode") not in {"latency", "quality"}:
            raise ValueError("input network decomposition has invalid mode")
        if decomposition.get("one_way_split_available") is not False:
            raise ValueError("input network decomposition must not claim a one-way split")
        error_bound = decomposition.get("maximum_measurement_error_bound_ns")
        if not isinstance(error_bound, int) or isinstance(error_bound, bool) or error_bound < 0:
            raise ValueError("input network decomposition has invalid measurement error bound")
        declared_mode = matrix.get("optimization_mode")
        if declared_mode != "unknown" and decomposition.get("mode") != declared_mode:
            raise ValueError("input network decomposition mode differs from run matrix")
        declared_protocol = matrix.get("client_protocol")
        if decomposition.get("client_protocol") != declared_protocol:
            raise ValueError("input network decomposition client protocol differs from run matrix")
        if telemetry_matrix.get("optimization_mode") != decomposition.get("mode"):
            raise ValueError("latency summary mode differs from input traces")
        if telemetry_matrix.get("client_protocol") != decomposition.get("client_protocol"):
            raise ValueError("latency summary client protocol differs from input traces")
        for metric_name, metric in decomposition.get("metrics", {}).items():
            values = [metric.get("p50"), metric.get("p95"), metric.get("p99")]
            if not all(
                isinstance(value, (int, float)) and math.isfinite(float(value)) and value >= 0
                for value in values
            ) or not values[0] <= values[1] <= values[2]:
                raise ValueError(f"input decomposition metric {metric_name} is invalid")
    for metric_name, measurement in report.get("startup", {}).items():
        if measurement is None:
            continue
        if (
            not isinstance(measurement, dict)
            or measurement.get("threshold_eligible") is not False
            or not isinstance(measurement.get("uncertainty_ms"), (int, float))
            or measurement["uncertainty_ms"] <= 0
        ):
            raise ValueError(f"startup measurement {metric_name} lacks uncertainty/non-gating metadata")

    def inspect(value: Any, path: str) -> None:
        if isinstance(value, float) and not math.isfinite(value):
            raise ValueError(f"non-finite report number at {path}")
        if isinstance(value, dict):
            for key, child in value.items():
                inspect(child, f"{path}.{key}")
        elif isinstance(value, list):
            for index, child in enumerate(value):
                inspect(child, f"{path}[{index}]")

    inspect(report, "report")


def ensure_safe_output_directory(path: Path) -> None:
    if path.is_symlink():
        raise ValueError(f"output path is a symlink: {path}")
    absolute = path.absolute().resolve(strict=False)
    if not absolute.exists():
        absolute.mkdir(parents=True, mode=0o700)
    if not absolute.is_dir() or absolute.is_symlink():
        raise ValueError("output path must be a real directory")
    absolute.chmod(0o700)


def atomic_write(path: Path, contents: str) -> None:
    if path.exists() and path.is_symlink():
        raise ValueError(f"refusing to replace symlink: {path}")
    descriptor, temporary_path = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(contents)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary_path, 0o600)
        os.replace(temporary_path, path)
        directory_descriptor = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    finally:
        if os.path.exists(temporary_path):
            os.unlink(temporary_path)


def parse_arguments(arguments: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--trace-id", required=True)
    parser.add_argument("--runner-events")
    parser.add_argument("--umbra-log")
    parser.add_argument("--lumen-log")
    parser.add_argument("--coreaudio-log")
    parser.add_argument("--umbra-pid", type=int)
    parser.add_argument("--client-telemetry")
    parser.add_argument("--window-start")
    parser.add_argument("--window-end")
    parser.add_argument("--coreaudio-window-start")
    parser.add_argument("--coreaudio-window-end")
    parser.add_argument("--thresholds", default=str(Path(__file__).with_name("thresholds.json")))
    parser.add_argument("--schema", default=str(Path(__file__).with_name("schema.json")))
    parser.add_argument("--output-dir", required=True)
    return parser.parse_args(arguments)


def main(arguments: list[str]) -> int:
    os.umask(0o077)
    options = parse_arguments(arguments)
    if options.coreaudio_log and options.umbra_pid is None:
        raise ValueError("--umbra-pid is required with --coreaudio-log")
    report = build_report(
        run_id=options.run_id,
        trace_id=options.trace_id,
        runner=(
            parse_runner_events(
                read_optional(options.runner_events),
                expected_run_id=options.run_id,
                expected_trace_id=options.trace_id,
            )
            if options.runner_events
            else {}
        ),
        umbra=(
            parse_umbra_log(
                read_optional(options.umbra_log),
                window_start=options.window_start,
                window_end=options.window_end,
            )
            if options.umbra_log
            else {}
        ),
        lumen=parse_lumen_log(read_optional(options.lumen_log), options.trace_id) if options.lumen_log else {},
        coreaudio=(
            parse_coreaudio_log(read_optional(options.coreaudio_log), expected_pid=options.umbra_pid)
            if options.coreaudio_log
            else {}
        ),
        telemetry=(
            parse_client_telemetry(
                read_optional(options.client_telemetry),
                expected_run_id=options.run_id,
                expected_trace_id=options.trace_id,
            )
            if options.client_telemetry
            else {}
        ),
    )
    thresholds = json.loads(Path(options.thresholds).read_text(encoding="utf-8"))
    schema = json.loads(Path(options.schema).read_text(encoding="utf-8"))
    if options.coreaudio_log:
        report["measurement_provenance"]["coreaudio"]["window_start"] = (
            options.coreaudio_window_start
        )
        report["measurement_provenance"]["coreaudio"]["window_end"] = options.coreaudio_window_end
        report["measurement_provenance"]["coreaudio"]["includes_postroll"] = bool(
            options.coreaudio_window_end
        )
    validate_thresholds(thresholds)
    report["threshold_evaluation"] = evaluate_thresholds(report, thresholds)
    output_directory = Path(options.output_dir)
    validate_report(report, schema)
    ensure_safe_output_directory(output_directory)
    atomic_write(output_directory / "report.json", json.dumps(report, indent=2, sort_keys=True) + "\n")
    atomic_write(output_directory / "report.md", render_markdown(report))
    print(output_directory / "report.json")
    print(output_directory / "report.md")
    status = report["threshold_evaluation"]["status"]
    if status == "insufficient_data":
        return 2
    return 1 if status == "fail" else 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"performance report error: {error}", file=sys.stderr)
        sys.exit(64)
