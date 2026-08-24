import importlib.util
import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("parse_benchmark", ROOT / "parse_benchmark.py")
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class UmbraParserTests(unittest.TestCase):
    def test_parses_each_client_startup_milestone(self):
        parsed = MODULE.parse_umbra_log((ROOT / "fixtures/umbra-support.log").read_text())

        self.assertEqual(
            [event["name"] for event in parsed["events"]],
            [
                "launch_request",
                "streaming_task_started",
                "audio_warmup_started",
                "session_accepted",
                "rtsp_start",
                "first_video_packet",
                "first_decoded_frame",
                "first_audio_packet",
            ],
        )

    def test_prefers_reported_packet_delay_over_coarse_log_timestamp(self):
        parsed = MODULE.parse_umbra_log((ROOT / "fixtures/umbra-support.log").read_text())

        self.assertEqual(parsed["reported_intervals_ms"]["rtsp_to_first_video_packet"], 300.0)
        self.assertEqual(parsed["reported_intervals_ms"]["rtsp_to_first_audio_packet"], 600.0)

    def test_parses_audio_renderer_health_summary(self):
        parsed = MODULE.parse_umbra_log((ROOT / "fixtures/umbra-support.log").read_text())

        self.assertEqual(parsed["audio"]["rebuffers"], 1)
        self.assertEqual(parsed["audio"]["dropped_packets"], 2)
        self.assertEqual(parsed["audio"]["silence_frames"], 14400)

    def test_rejects_multiple_sessions_in_one_selected_window(self):
        fixture = (ROOT / "fixtures/umbra-support.log").read_text()
        parsed = MODULE.parse_umbra_log(fixture + "\n" + fixture)

        self.assertFalse(parsed["valid"])
        self.assertIn("multiple launch requests", parsed["errors"][0])


class LumenParserTests(unittest.TestCase):
    def test_parses_host_startup_and_pipeline_stages(self):
        parsed = MODULE.parse_lumen_log(
            (ROOT / "fixtures/lumen-host.log").read_text(), expected_trace_id="trace-fixture"
        )

        self.assertEqual(parsed["durations_ms"]["first_encode"], 2.4)
        self.assertNotIn("encoder_probe_cache_hit", parsed["durations_ms"])
        self.assertEqual(parsed["correlation"]["method"], "explicit_trace_id")

    def test_rejects_structured_stage_from_another_trace(self):
        parsed = MODULE.parse_lumen_log(
            "[2026-08-24 00:00:01.100]: Debug: PERF trace_id=other stage=first_send duration_ms=0.2",
            expected_trace_id="trace-fixture",
        )

        self.assertNotIn("first_send", parsed["durations_ms"])

    def test_marks_host_stages_unavailable_without_matching_trace(self):
        parsed = MODULE.parse_lumen_log(
            "[2026-08-24 00:00:00.970]: Info: New streaming session started [active sessions: 1]",
            expected_trace_id="trace-fixture",
        )

        self.assertEqual(parsed["correlation"]["method"], "unavailable")
        self.assertEqual(parsed["durations_ms"], {})
        self.assertNotEqual(parsed["environment_context"], [])

    def test_rejects_duplicate_matching_host_stage_instead_of_overwriting(self):
        line = (
            "[2026-08-24 00:00:01.100]: Debug: "
            "PERF trace_id=trace-fixture stage=first_send duration_ms=0.2\n"
        )
        parsed = MODULE.parse_lumen_log(line + line, expected_trace_id="trace-fixture")

        self.assertFalse(parsed["valid"])
        self.assertEqual(parsed["durations_ms"], {})
        self.assertEqual(parsed["correlation"]["method"], "unavailable")


class CoreAudioParserTests(unittest.TestCase):
    def test_counts_correlated_audio_failures(self):
        parsed = MODULE.parse_coreaudio_log(
            (ROOT / "fixtures/coreaudio.log").read_text(), expected_pid=123
        )

        self.assertEqual(parsed["client_timeouts"], 2)
        self.assertEqual(parsed["hal_overloads"], 2)
        self.assertEqual(parsed["ark_mutes"], 1)
        self.assertEqual(parsed["structured_coverage_count"], 6)
        self.assertEqual(parsed["provenance"]["verified_client_identifiers"], [7001])
        self.assertEqual(parsed["provenance"]["correlated_identifiers"], [7001, 7002])
        self.assertEqual(parsed["provenance"]["audioanalytics_host_coverage_count"], 3)
        self.assertEqual(parsed["provenance"]["audioanalytics_client_timeout_start_count"], 1)
        self.assertEqual(parsed["provenance"]["audioanalytics_client_timeout_end_count"], 1)
        self.assertEqual(parsed["provenance"]["trusted_audioanalytics_record_count"], 5)

    def test_does_not_attribute_safari_or_music_failures_to_umbra(self):
        parsed = MODULE.parse_coreaudio_log(
            (ROOT / "fixtures/coreaudio.log").read_text(), expected_pid=123
        )

        self.assertEqual(parsed["client_timeouts"], 2)
        self.assertEqual(parsed["hal_overloads"], 2)
        self.assertEqual(parsed["environment_context"]["client_timeouts"], 8)
        self.assertEqual(parsed["environment_context"]["hal_overloads"], 3)

    def test_audioanalytics_host_id_can_establish_coverage_without_numeric_context(self):
        parsed = MODULE.parse_coreaudio_log(
            "\n".join([
                json.dumps(
                    {
                        "timestamp": "2026-08-24 00:00:00.310000+0000",
                        "processID": 412,
                        "processImagePath": "/usr/sbin/coreaudiod",
                        "subsystem": "com.apple.audioanalytics.performance",
                        "category": "ClientPerformance",
                        "eventMessage": (
                            '{ "sample_rate": Optional(96000), '
                            '"overload_type": Optional(ClientTimeoutStart), '
                            '"HostApplicationDisplayID": Optional(app.umbra.Umbra) }'
                        ),
                    }
                ),
                json.dumps(
                    {
                        "timestamp": "2026-08-24 00:00:00.320000+0000",
                        "processID": 412,
                        "processImagePath": "/usr/sbin/coreaudiod",
                        "subsystem": "com.apple.audioanalytics.performance",
                        "category": "ClientPerformance",
                        "eventMessage": (
                            '{ "HostApplicationDisplayID": Optional(app.umbra.Umbra), '
                            '"sample_rate": Optional(96000), '
                            '"overload_type": Optional(ClientTimeoutEnd) }'
                        ),
                    }
                ),
            ]),
            expected_pid=123,
        )

        self.assertEqual(parsed["structured_coverage_count"], 2)
        self.assertEqual(parsed["client_timeouts"], 1)
        self.assertEqual(parsed["hal_overloads"], 0)
        self.assertIsNone(parsed["ark_mutes"])
        self.assertEqual(parsed["provenance"]["verified_client_identifiers"], [])
        self.assertEqual(parsed["provenance"]["audioanalytics_client_timeout_end_count"], 1)

    def test_umbra_owned_or_fake_daemon_records_cannot_enable_daemon_zero_pass(self):
        parsed = MODULE.parse_coreaudio_log(
            "\n".join(
                [
                    json.dumps(
                        {
                            "process": "Umbra",
                            "processID": 123,
                            "processImagePath": "/Applications/Umbra.app/Contents/MacOS/Umbra",
                            "subsystem": "app.umbra.Umbra",
                            "eventMessage": "Audio client registered",
                        }
                    ),
                    json.dumps(
                        {
                            "process": "coreaudiod",
                            "processID": 412,
                            "processImagePath": "/tmp/coreaudiod",
                            "subsystem": "com.apple.coreaudio",
                            "eventMessage": "client 7001 (pid 123) app.umbra.Umbra",
                        }
                    ),
                ]
            ),
            expected_pid=123,
        )

        self.assertEqual(parsed["structured_coverage_count"], 0)
        self.assertIsNone(parsed["client_timeouts"])

    def test_counters_are_unavailable_without_positive_structured_identity_coverage(self):
        parsed = MODULE.parse_coreaudio_log(
            json.dumps(
                {
                    "process": "coreaudiod",
                    "processID": 999,
                    "subsystem": "com.apple.Safari",
                    "eventMessage": "ClientTimeout for app.umbra.Umbra pid=123",
                }
            ),
            expected_pid=123,
        )

        self.assertEqual(parsed["structured_coverage_count"], 0)
        self.assertIsNone(parsed["client_timeouts"])
        self.assertIsNone(parsed["hal_overloads"])

    def test_simplified_non_optional_audioanalytics_syntax_is_not_accepted(self):
        parsed = MODULE.parse_coreaudio_log(
            json.dumps(
                {
                    "processID": 412,
                    "processImagePath": "/usr/sbin/coreaudiod",
                    "subsystem": "com.apple.audioanalytics",
                    "eventMessage": (
                        "HostApplicationDisplayID: Optional(app.umbra.Umbra), "
                        "sample_rate: 96000, cause: ClientTimeout"
                    ),
                }
            ),
            expected_pid=123,
        )

        self.assertEqual(parsed["structured_coverage_count"], 0)
        self.assertIsNone(parsed["client_timeouts"])


class TelemetryParserTests(unittest.TestCase):
    def test_preserves_client_percentile_samples_and_evidence(self):
        parsed = MODULE.parse_client_telemetry(
            (ROOT / "fixtures/client-telemetry.jsonl").read_text(),
            expected_run_id="run-fixture",
            expected_trace_id="trace-fixture",
        )

        metric = parsed["metrics"]["metal_commit_to_presentation_proxy_ms"]
        self.assertEqual(metric["samples"], 120)
        self.assertEqual(metric["p99"], 8.3)
        self.assertEqual(metric["evidence"], "display_link_presentation_target")
        self.assertTrue(parsed["valid"])

    def test_rejects_multiple_matching_summaries_instead_of_merging(self):
        fixture = (ROOT / "fixtures/client-telemetry.jsonl").read_text()
        parsed = MODULE.parse_client_telemetry(
            fixture + fixture,
            expected_run_id="run-fixture",
            expected_trace_id="trace-fixture",
        )

        self.assertFalse(parsed["valid"])
        self.assertEqual(parsed["metrics"], {})

    def test_rejects_non_finite_or_out_of_order_percentiles(self):
        record = {
            "type": "latency_summary",
            "run_id": "run-fixture",
            "trace_id": "trace-fixture",
            "provenance": "test",
            "metrics": {
                "receive_to_decode_ms": {
                    "samples": 1,
                    "p50": 3.0,
                    "p95": 2.0,
                    "p99": float("inf"),
                }
            },
        }
        parsed = MODULE.parse_client_telemetry(
            json.dumps(record),
            expected_run_id="run-fixture",
            expected_trace_id="trace-fixture",
        )

        self.assertFalse(parsed["valid"])
        self.assertEqual(parsed["metrics"], {})

    def test_rejects_summary_without_exact_mode_and_client_protocol(self):
        record = json.loads((ROOT / "fixtures/client-telemetry.jsonl").read_text())
        del record["optimization_mode"]
        del record["client_protocol"]

        parsed = MODULE.parse_client_telemetry(
            json.dumps(record), "run-fixture", "trace-fixture"
        )

        self.assertFalse(parsed["valid"])
        self.assertEqual(parsed["metrics"], {})
        self.assertTrue(any("invalid optimization mode" in error for error in parsed["errors"]))
        self.assertTrue(any("invalid client protocol" in error for error in parsed["errors"]))

    def test_derives_offset_free_two_leg_network_residual_per_event(self):
        summary = json.loads((ROOT / "fixtures/client-telemetry.jsonl").read_text())
        traces = [
            {
                "type": "input_trace",
                "run_id": "run-fixture",
                "trace_id": "trace-fixture",
                "mode": "latency",
                "client_protocol": "umbra-legacy",
                "input_event_id": event_id,
                "changed_frame_id": 9000 + event_id,
                "correlation": "causal_input_frame_watermark_v1",
                "observed_input_to_present_submit_ns": total,
                "client_input_to_send_ns": 300_000,
                "host_receive_to_video_send_ns": host,
                "client_video_receive_to_present_submit_ns": 2_000_000,
                "measurement_error_bound_ns": 100_000,
            }
            for event_id, total, host in [
                (1, 70_000_000, 7_000_000),
                (2, 80_000_000, 8_000_000),
                (3, 100_000_000, 10_000_000),
            ]
        ]
        text = "\n".join(json.dumps(item) for item in [summary, *traces])

        parsed = MODULE.parse_client_telemetry(text, "run-fixture", "trace-fixture")
        decomposition = parsed["input_network_decomposition"]

        self.assertTrue(decomposition["available"])
        self.assertEqual(decomposition["mode"], "latency")
        self.assertFalse(decomposition["one_way_split_available"])
        self.assertEqual(decomposition["samples"], 3)
        self.assertEqual(decomposition["maximum_measurement_error_bound_ns"], 100_000)
        self.assertEqual(
            decomposition["metrics"]["combined_network_transit_residual_ms"]["p50"],
            69.7,
        )
        self.assertEqual(
            decomposition["metrics"]["host_client_processing_residual_ms"]["p99"],
            12.3,
        )

    def test_rejects_network_residual_when_components_exceed_observed_total(self):
        summary = (ROOT / "fixtures/client-telemetry.jsonl").read_text().strip()
        invalid = {
            "type": "input_trace",
            "run_id": "run-fixture",
            "trace_id": "trace-fixture",
            "mode": "quality",
            "client_protocol": "umbra-legacy",
            "input_event_id": 1,
            "changed_frame_id": 2,
            "correlation": "causal_input_frame_watermark_v1",
            "observed_input_to_present_submit_ns": 1_000_000,
            "client_input_to_send_ns": 500_000,
            "host_receive_to_video_send_ns": 600_000,
            "client_video_receive_to_present_submit_ns": 100_000,
            "measurement_error_bound_ns": 100_000,
        }

        parsed = MODULE.parse_client_telemetry(
            summary + "\n" + json.dumps(invalid), "run-fixture", "trace-fixture"
        )

        self.assertFalse(parsed["input_network_decomposition"]["available"])
        self.assertIn("exceeding observed latency", parsed["input_network_decomposition"]["errors"][0])

    def test_rejects_aggregation_across_latency_and_quality_modes(self):
        summary = (ROOT / "fixtures/client-telemetry.jsonl").read_text().strip()
        base = {
            "type": "input_trace",
            "run_id": "run-fixture",
            "trace_id": "trace-fixture",
            "client_protocol": "umbra-legacy",
            "changed_frame_id": 2,
            "correlation": "causal_input_frame_watermark_v1",
            "observed_input_to_present_submit_ns": 10_000_000,
            "client_input_to_send_ns": 100_000,
            "host_receive_to_video_send_ns": 2_000_000,
            "client_video_receive_to_present_submit_ns": 1_000_000,
            "measurement_error_bound_ns": 100_000,
        }
        latency = dict(base, input_event_id=1, mode="latency")
        quality = dict(base, input_event_id=2, changed_frame_id=3, mode="quality")

        parsed = MODULE.parse_client_telemetry(
            "\n".join([summary, json.dumps(latency), json.dumps(quality)]),
            "run-fixture",
            "trace-fixture",
        )

        self.assertFalse(parsed["input_network_decomposition"]["available"])
        self.assertIn("different optimization modes", parsed["input_network_decomposition"]["errors"][0])


class ReportTests(unittest.TestCase):
    def test_report_schema_v2_requires_network_decomposition_contract(self):
        report = MODULE.build_report(
            run_id="run-empty",
            trace_id="trace-empty",
            runner={},
            umbra={},
            lumen={},
            coreaudio={},
            telemetry={},
        )
        schema = json.loads((ROOT / "schema.json").read_text())

        MODULE.validate_report(report, schema)

        self.assertEqual(report["schema_version"], 2)
        self.assertIn("input_network_decomposition", schema["required"])
        self.assertIn("telemetry_matrix", schema["required"])
        self.assertFalse(report["input_network_decomposition"]["available"])

    def test_schema_validator_rejects_boolean_integer_and_additional_property(self):
        report = MODULE.build_report(
            run_id="run-empty",
            trace_id="trace-empty",
            runner={
                "valid": True,
                "events": [{
                    "name": "launch_request",
                    "monotonic_ns": True,
                    "source": "test",
                    "clock_domain": "client_monotonic",
                    "evidence": "test",
                }],
            },
            umbra={},
            lumen={},
            coreaudio={},
            telemetry={},
        )
        schema = json.loads((ROOT / "schema.json").read_text())

        with self.assertRaisesRegex(ValueError, "schema type mismatch"):
            MODULE.validate_report(report, schema)

        report["timelines"]["client_monotonic"] = []
        report["matrix"]["unexpected"] = "forbidden"
        with self.assertRaisesRegex(ValueError, "schema additional property"):
            MODULE.validate_report(report, schema)

    def test_schema_validator_rejects_negative_nested_number_and_missing_property(self):
        report = MODULE.build_report(
            run_id="run-empty",
            trace_id="trace-empty",
            runner={},
            umbra={},
            lumen={},
            coreaudio={},
            telemetry={},
        )
        schema = json.loads((ROOT / "schema.json").read_text())
        report["audio"]["rebuffers"] = -1

        with self.assertRaisesRegex(ValueError, "schema minimum violation"):
            MODULE.validate_report(report, schema)

        report["audio"].clear()
        del report["matrix"]["host"]
        with self.assertRaisesRegex(ValueError, "schema required property missing"):
            MODULE.validate_report(report, schema)

    def test_schema_validator_rejects_naive_date_time(self):
        report = MODULE.build_report(
            run_id="run-empty",
            trace_id="trace-empty",
            runner={},
            umbra={},
            lumen={},
            coreaudio={},
            telemetry={},
        )
        report["generated_at"] = "2026-08-24T12:00:00"

        with self.assertRaisesRegex(ValueError, "schema date-time violation"):
            MODULE.validate_report(report, json.loads((ROOT / "schema.json").read_text()))

    def test_runner_rejects_events_from_different_matrices(self):
        fixture = (ROOT / "fixtures/runner-events.jsonl").read_text().splitlines()
        first = json.loads(fixture[0])
        second = json.loads(fixture[1])
        first["matrix"] = {
            "network_kind": "lan",
            "optimization_mode": "latency",
            "client_protocol": "umbra-legacy",
            "host": "host-a",
        }
        second["matrix"] = dict(first["matrix"], network_kind="cellular")

        parsed = MODULE.parse_runner_events(
            "\n".join([json.dumps(first), json.dumps(second)]),
            expected_run_id="run-fixture",
            expected_trace_id="trace-fixture",
        )

        self.assertFalse(parsed["valid"])
        self.assertEqual(parsed["events"], [])

    def test_report_rejects_input_trace_mode_that_differs_from_run_matrix(self):
        report = MODULE.build_report(
            run_id="run-fixture",
            trace_id="trace-fixture",
            runner={
                "valid": True,
                "events": [],
                "matrix": {
                    "network_kind": "cellular",
                    "optimization_mode": "quality",
                    "client_protocol": "umbra-v2",
                    "host": "example-host",
                },
            },
            umbra={},
            lumen={},
            coreaudio={},
            telemetry={
                "valid": True,
                "errors": [],
                "metrics": {},
                "input_network_decomposition": {
                    "available": True,
                    "errors": [],
                    "samples": 1,
                    "mode": "latency",
                    "client_protocol": "umbra-v2",
                    "method": "offset_free_combined_two_leg_network_residual_v1",
                    "one_way_split_available": False,
                    "maximum_measurement_error_bound_ns": 100_000,
                    "metrics": {},
                },
            },
        )

        self.assertEqual(report["evidence_status"]["status"], "insufficient_data")
        self.assertIn(
            "matrix.optimization_mode_matches_telemetry",
            report["evidence_status"]["missing_required"],
        )
        with self.assertRaisesRegex(ValueError, "mode differs from run matrix"):
            MODULE.validate_report(report, json.loads((ROOT / "schema.json").read_text()))

    def test_invalid_supplied_input_trace_forces_insufficient_data_with_exact_error(self):
        summary = json.loads((ROOT / "fixtures/client-telemetry.jsonl").read_text())
        malformed = {
            "type": "input_trace",
            "run_id": "run-fixture",
            "trace_id": "trace-fixture",
            "mode": "latency",
            "client_protocol": "umbra-legacy",
            "input_event_id": 1,
            "changed_frame_id": 2,
            "correlation": "causal_input_frame_watermark_v1",
            "observed_input_to_present_submit_ns": 1,
            "client_input_to_send_ns": 2,
            "host_receive_to_video_send_ns": 0,
            "client_video_receive_to_present_submit_ns": 0,
            "measurement_error_bound_ns": 0,
        }
        telemetry = MODULE.parse_client_telemetry(
            "\n".join([json.dumps(summary), json.dumps(malformed)]),
            "run-fixture",
            "trace-fixture",
        )
        report = MODULE.build_report(
            run_id="run-fixture",
            trace_id="trace-fixture",
            runner={
                "valid": True,
                "events": [],
                "matrix": {
                    "network_kind": "cellular",
                    "optimization_mode": "latency",
                    "client_protocol": "umbra-legacy",
                    "host": "example-host",
                },
            },
            umbra={},
            lumen={},
            coreaudio={},
            telemetry=telemetry,
        )

        self.assertEqual(report["evidence_status"]["status"], "insufficient_data")
        self.assertIn(
            "client_telemetry.valid_input_network_decomposition",
            report["evidence_status"]["missing_required"],
        )
        self.assertTrue(any(
            "processing durations exceeding observed latency" in error
            for error in report["evidence_status"]["parse_errors"]
        ))
        self.assertIn("Rejected input trace evidence", MODULE.render_markdown(report))

    def test_summary_and_input_trace_matrices_must_match_even_when_runner_unknown(self):
        report = MODULE.build_report(
            run_id="run-fixture",
            trace_id="trace-fixture",
            runner={
                "valid": True,
                "events": [],
                "matrix": {
                    "network_kind": "unknown",
                    "optimization_mode": "unknown",
                    "client_protocol": "umbra-legacy",
                    "host": "unknown",
                },
            },
            umbra={},
            lumen={},
            coreaudio={},
            telemetry={
                "valid": True,
                "errors": [],
                "optimization_mode": "latency",
                "client_protocol": "umbra-legacy",
                "metrics": {},
                "input_network_decomposition": {
                    "available": True,
                    "errors": [],
                    "samples": 1,
                    "mode": "quality",
                    "client_protocol": "umbra-legacy",
                    "method": "offset_free_combined_two_leg_network_residual_v1",
                    "one_way_split_available": False,
                    "maximum_measurement_error_bound_ns": 0,
                    "metrics": {},
                },
            },
        )

        self.assertEqual(report["evidence_status"]["status"], "insufficient_data")
        self.assertIn(
            "client_telemetry.summary_matches_input_traces",
            report["evidence_status"]["missing_required"],
        )
        with self.assertRaisesRegex(ValueError, "summary mode differs"):
            MODULE.validate_report(report, json.loads((ROOT / "schema.json").read_text()))

    def test_markdown_renders_network_residual_as_combined_two_leg_only(self):
        report = MODULE.build_report(
            run_id="run-fixture",
            trace_id="trace-fixture",
            runner={},
            umbra={},
            lumen={},
            coreaudio={},
            telemetry={
                "input_network_decomposition": {
                    "available": True,
                    "errors": [],
                    "samples": 1,
                    "mode": "latency",
                    "method": "offset_free_combined_two_leg_network_residual_v1",
                    "one_way_split_available": False,
                    "maximum_measurement_error_bound_ns": 100_000,
                    "metrics": {
                        "combined_network_transit_residual_ms": {
                            "samples": 1,
                            "p50": 40.0,
                            "p95": 40.0,
                            "p99": 40.0,
                            "evidence": "fixture",
                            "provenance": "fixture",
                        }
                    },
                }
            },
        )

        markdown = MODULE.render_markdown(report)

        self.assertIn("Input/network decomposition", markdown)
        self.assertIn("combined uplink + downlink only", markdown)
        self.assertIn("offset_free_combined_two_leg_network_residual_v1", markdown)

    def test_marks_cross_clock_and_optical_metrics_unavailable(self):
        report = MODULE.build_report(
            run_id="run-fixture",
            trace_id="trace-fixture",
            runner=MODULE.parse_runner_events((ROOT / "fixtures/runner-events.jsonl").read_text()),
            umbra=MODULE.parse_umbra_log((ROOT / "fixtures/umbra-support.log").read_text()),
            lumen=MODULE.parse_lumen_log(
                (ROOT / "fixtures/lumen-host.log").read_text(), expected_trace_id="trace-fixture"
            ),
            coreaudio=MODULE.parse_coreaudio_log(
                (ROOT / "fixtures/coreaudio.log").read_text(), expected_pid=123
            ),
            telemetry=MODULE.parse_client_telemetry(
                (ROOT / "fixtures/client-telemetry.jsonl").read_text(),
                expected_run_id="run-fixture",
                expected_trace_id="trace-fixture",
            ),
        )

        unavailable = {item["metric"] for item in report["unavailable_metrics"]}
        self.assertIn("host_to_client_cross_clock_latency", unavailable)
        self.assertIn("input_to_photon_latency", unavailable)

    def test_thresholds_report_failures_without_claiming_input_to_photon(self):
        thresholds = json.loads((ROOT / "thresholds.json").read_text())
        report = MODULE.build_report(
            run_id="run-fixture",
            trace_id="trace-fixture",
            runner=MODULE.parse_runner_events((ROOT / "fixtures/runner-events.jsonl").read_text()),
            umbra=MODULE.parse_umbra_log((ROOT / "fixtures/umbra-support.log").read_text()),
            lumen={},
            coreaudio=MODULE.parse_coreaudio_log(
                (ROOT / "fixtures/coreaudio.log").read_text(), expected_pid=123
            ),
            telemetry=MODULE.parse_client_telemetry(
                (ROOT / "fixtures/client-telemetry.jsonl").read_text(),
                expected_run_id="run-fixture",
                expected_trace_id="trace-fixture",
            ),
        )

        evaluations = MODULE.evaluate_thresholds(report, thresholds)

        self.assertEqual(evaluations["status"], "fail")
        self.assertNotIn("input_to_photon_latency", {item["metric"] for item in evaluations["checks"]})

    def test_markdown_discloses_clock_limitations(self):
        report = MODULE.build_report(
            run_id="run-fixture",
            trace_id="trace-fixture",
            runner={},
            umbra={},
            lumen={},
            coreaudio={},
            telemetry={},
        )

        markdown = MODULE.render_markdown(report)

        self.assertIn("Input-to-photon latency", markdown)
        self.assertIn("unavailable", markdown.lower())

    def test_markdown_preserves_latency_evidence_and_provenance(self):
        telemetry = MODULE.parse_client_telemetry(
            (ROOT / "fixtures/client-telemetry.jsonl").read_text(),
            "run-fixture",
            "trace-fixture",
        )
        report = MODULE.build_report(
            run_id="run-fixture",
            trace_id="trace-fixture",
            runner={},
            umbra={},
            lumen={},
            coreaudio={},
            telemetry=telemetry,
        )

        markdown = MODULE.render_markdown(report)

        self.assertIn("display_link_presentation_target", markdown)
        self.assertIn("Umbra in-process monotonic telemetry", markdown)

    def test_all_missing_required_evidence_is_insufficient_data(self):
        report = MODULE.build_report(
            run_id="run-empty",
            trace_id="trace-empty",
            runner={},
            umbra={},
            lumen={},
            coreaudio={},
            telemetry={},
        )
        thresholds = json.loads((ROOT / "thresholds.json").read_text())

        evaluations = MODULE.evaluate_thresholds(report, thresholds)

        self.assertEqual(evaluations["status"], "insufficient_data")
        self.assertNotEqual(report["evidence_status"]["missing_required"], [])

    def test_host_and_client_events_are_never_merged_into_one_timeline(self):
        report = MODULE.build_report(
            run_id="run-fixture",
            trace_id="trace-fixture",
            runner=MODULE.parse_runner_events((ROOT / "fixtures/runner-events.jsonl").read_text()),
            umbra=MODULE.parse_umbra_log((ROOT / "fixtures/umbra-support.log").read_text()),
            lumen=MODULE.parse_lumen_log(
                (ROOT / "fixtures/lumen-host.log").read_text(), expected_trace_id="trace-fixture"
            ),
            coreaudio={},
            telemetry={},
        )

        self.assertIn("client_monotonic", report["timelines"])
        self.assertIn("client_wall_log", report["timelines"])
        self.assertIn("host_explicit_trace", report["timelines"])
        self.assertNotIn("timeline", report)

    def test_runner_action_intervals_use_monotonic_nanoseconds_and_disclose_precision(self):
        runner = MODULE.parse_runner_events((ROOT / "fixtures/runner-events.jsonl").read_text())
        launch = MODULE.first_event(runner, name="launch_request")
        stop = MODULE.first_event(runner, name="graceful_stop_requested")

        self.assertEqual(MODULE.same_clock_interval_ms(launch, stop), 6100.0)
        self.assertEqual(stop["clock_domain"], "client_monotonic")
        self.assertEqual(stop["precision"]["upper_bound_ms"], 0.001)

    def test_coreaudio_postroll_follows_audio_restore_and_confirmed_client_exit(self):
        runner = MODULE.parse_runner_events((ROOT / "fixtures/runner-events.jsonl").read_text())
        names = [event["name"] for event in runner["events"]]

        self.assertLess(names.index("audio_restored"), names.index("coreaudio_postroll_end"))
        self.assertLess(names.index("client_exit_confirmed"), names.index("coreaudio_postroll_end"))

    def test_startup_intervals_are_coarse_log_measurements_and_not_threshold_eligible(self):
        report = MODULE.build_report(
            run_id="run-fixture",
            trace_id="trace-fixture",
            runner=MODULE.parse_runner_events((ROOT / "fixtures/runner-events.jsonl").read_text()),
            umbra=MODULE.parse_umbra_log((ROOT / "fixtures/umbra-support.log").read_text()),
            lumen={},
            coreaudio=MODULE.parse_coreaudio_log(
                (ROOT / "fixtures/coreaudio.log").read_text(), expected_pid=123
            ),
            telemetry={},
        )

        measurement = report["startup"]["launch_request_to_first_decoded_frame"]
        self.assertEqual(measurement["uncertainty_ms"], 1000.0)
        self.assertFalse(measurement["threshold_eligible"])

    def test_runtime_threshold_validation_rejects_invalid_bounds(self):
        with self.assertRaises(ValueError):
            MODULE.validate_thresholds(
                {
                    "schema_version": 1,
                    "checks": [
                        {"metric": "audio.rebuffers", "warn_above": 2, "fail_above": 1}
                    ],
                }
            )

    def test_runtime_threshold_validation_rejects_coarse_startup_metric(self):
        with self.assertRaises(ValueError):
            MODULE.validate_thresholds(
                {
                    "schema_version": 1,
                    "checks": [
                        {
                            "metric": "startup.launch_request_to_first_decoded_frame.value_ms",
                            "warn_above": 1000,
                            "fail_above": 2000,
                        }
                    ],
                }
            )

    def test_missing_configured_threshold_metric_forces_insufficient_data(self):
        report = MODULE.build_report(
            run_id="run-fixture",
            trace_id="trace-fixture",
            runner=MODULE.parse_runner_events((ROOT / "fixtures/runner-events.jsonl").read_text()),
            umbra=MODULE.parse_umbra_log((ROOT / "fixtures/umbra-support.log").read_text()),
            lumen={},
            coreaudio=MODULE.parse_coreaudio_log(
                (ROOT / "fixtures/coreaudio.log").read_text(), expected_pid=123
            ),
            telemetry={},
        )
        thresholds = {
            "schema_version": 1,
            "checks": [
                {"metric": "client_telemetry.missing.p99", "warn_above": 1, "fail_above": 2}
            ],
        }

        evaluation = MODULE.evaluate_thresholds(report, thresholds)

        self.assertEqual(evaluation["status"], "insufficient_data")

    def test_live_run_does_not_require_unwired_host_trace_or_client_telemetry(self):
        report = MODULE.build_report(
            run_id="run-fixture",
            trace_id="trace-fixture",
            runner=MODULE.parse_runner_events((ROOT / "fixtures/runner-events.jsonl").read_text()),
            umbra=MODULE.parse_umbra_log((ROOT / "fixtures/umbra-support.log").read_text()),
            lumen={},
            coreaudio=MODULE.parse_coreaudio_log(
                (ROOT / "fixtures/coreaudio.log").read_text(), expected_pid=123
            ),
            telemetry={},
        )

        unavailable = {item["metric"] for item in report["unavailable_metrics"]}
        self.assertEqual(report["evidence_status"]["status"], "complete")
        self.assertIn("host_pipeline_stages", unavailable)
        self.assertIn("client_latency_percentiles", unavailable)

    def test_runner_duplicate_milestone_is_rejected_instead_of_merged(self):
        fixture = (ROOT / "fixtures/runner-events.jsonl").read_text()
        first_record = fixture.splitlines()[0]
        parsed = MODULE.parse_runner_events(
            fixture + first_record + "\n",
            expected_run_id="run-fixture",
            expected_trace_id="trace-fixture",
        )

        self.assertFalse(parsed["valid"])
        self.assertEqual(parsed["events"], [])


if __name__ == "__main__":
    unittest.main()
