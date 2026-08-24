import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / "run_desktop_benchmark.zsh"


def make_fake_osascript(root: Path) -> tuple[Path, Path, Path]:
    calls = root / "calls.log"
    state = root / "audio-state.txt"
    state.write_text("37,false\n")
    executable = root / "osascript"
    executable.write_text(
        "#!/bin/zsh\n"
        "print -r -- \"$*\" >> \"$UMBRA_PERF_FAKE_CALLS\"\n"
        "IFS=, read -r volume muted < \"$UMBRA_PERF_FAKE_STATE\"\n"
        "if [[ \"$*\" == *'get volume settings'* ]]; then\n"
        "  print -r -- \"output volume:$volume, input volume:50, alert volume:80, output muted:$muted\"\n"
        "elif [[ \"$*\" == *'set volume with output muted'* ]]; then\n"
        "  print -r -- \"$volume,true\" > \"$UMBRA_PERF_FAKE_STATE\"\n"
        "elif [[ \"$*\" == *'set volume output volume 37 without output muted'* ]]; then\n"
        "  [[ \"${UMBRA_PERF_FAIL_RESTORE:-0}\" == 1 ]] && exit 1\n"
        "  print -r -- '37,false' > \"$UMBRA_PERF_FAKE_STATE\"\n"
        "fi\n"
    )
    executable.chmod(0o755)
    return executable, calls, state


def environment_for(fake: Path, calls: Path, state: Path) -> dict[str, str]:
    environment = os.environ.copy()
    environment["UMBRA_PERF_OSASCRIPT"] = str(fake)
    environment["UMBRA_PERF_FAKE_CALLS"] = str(calls)
    environment["UMBRA_PERF_FAKE_STATE"] = str(state)
    return environment


def make_launchable_fixture_app(root: Path) -> tuple[Path, Path]:
    app = root / "LaunchFixture.app"
    macos = app / "Contents" / "MacOS"
    macos.mkdir(parents=True)
    executable = macos / "LaunchFixture"
    source = root / "LaunchFixture.swift"
    source.write_text(
        "import AppKit\n"
        "import Darwin\n"
        "import Foundation\n"
        "let application = NSApplication.shared\n"
        "application.setActivationPolicy(.prohibited)\n"
        "application.finishLaunching()\n"
        "let arguments = Array(CommandLine.arguments.dropFirst())\n"
        "if let markerIndex = arguments.firstIndex(of: \"--launch-record\"), "
        "markerIndex + 1 < arguments.count {\n"
        "    let recordURL = URL(fileURLWithPath: arguments[markerIndex + 1])\n"
        "    let record: [String: Any] = [\"pid\": Int(getpid()), \"arguments\": arguments]\n"
        "    let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])\n"
        "    try data.write(to: recordURL, options: [.atomic])\n"
        "}\n"
        "if let siblingIndex = arguments.firstIndex(of: \"--spawn-sibling-record\"), "
        "siblingIndex + 1 < arguments.count {\n"
        "    let task = Process()\n"
        "    task.executableURL = URL(fileURLWithPath: \"/usr/bin/open\")\n"
        "    task.arguments = [\"-n\", Bundle.main.bundlePath, \"--args\", "
        "\"--launch-record\", arguments[siblingIndex + 1]]\n"
        "    try task.run()\n"
        "}\n"
        "if arguments.contains(\"--exit-immediately\") { exit(23) }\n"
        "if let exitIndex = arguments.firstIndex(of: \"--exit-after-ms\"), "
        "exitIndex + 1 < arguments.count, "
        "let milliseconds = Double(arguments[exitIndex + 1]) {\n"
        "    DispatchQueue.main.asyncAfter(deadline: .now() + milliseconds / 1000) {\n"
        "        application.terminate(nil)\n"
        "    }\n"
        "}\n"
        "application.run()\n"
    )
    compile_result = subprocess.run(
        ["xcrun", "swiftc", str(source), "-o", str(executable)],
        text=True,
        capture_output=True,
        check=False,
    )
    if compile_result.returncode != 0:
        raise AssertionError(compile_result.stderr)
    info = {
        "CFBundleExecutable": "LaunchFixture",
        "CFBundleIdentifier": "app.umbra.LaunchFixture",
        "CFBundleName": "LaunchFixture",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1",
        "LSBackgroundOnly": True,
    }
    with (app / "Contents" / "Info.plist").open("wb") as handle:
        plistlib.dump(info, handle)
    return app, executable


def stop_fixture_process(process_pid: int):
    try:
        os.kill(process_pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        try:
            os.kill(process_pid, 0)
        except ProcessLookupError:
            return
        time.sleep(0.01)
    try:
        os.kill(process_pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


class RunnerCleanupTests(unittest.TestCase):
    def assert_signal_restores_audio_and_exits(self, sent_signal: signal.Signals, expected_status: int):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            fake, calls, state = make_fake_osascript(root)
            ready = root / "ready"
            environment = environment_for(fake, calls, state)
            environment["UMBRA_PERF_SELF_TEST_READY"] = str(ready)
            process = subprocess.Popen(
                [str(RUNNER), "--self-test-signal-wait"],
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            try:
                deadline = time.monotonic() + 5
                while not ready.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(ready.exists())
                process.send_signal(sent_signal)
                process.communicate(timeout=5)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()

            self.assertEqual(process.returncode, expected_status)
            self.assertEqual(state.read_text().strip(), "37,false")
            self.assertEqual(calls.read_text().count("set volume output volume 37 without output muted"), 1)

    def test_failure_trap_restores_and_verifies_original_audio_state(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            fake, calls, state = make_fake_osascript(root)

            result = subprocess.run(
                [str(RUNNER), "--self-test-cleanup"],
                env=environment_for(fake, calls, state),
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 97)
            self.assertEqual(state.read_text().strip(), "37,false")
            self.assertGreaterEqual(calls.read_text().count("get volume settings"), 2)

    def test_restore_failure_is_reported_and_overrides_success(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            fake, calls, state = make_fake_osascript(root)
            environment = environment_for(fake, calls, state)
            environment["UMBRA_PERF_FAIL_RESTORE"] = "1"

            result = subprocess.run(
                [str(RUNNER), "--self-test-cleanup-success"],
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("failed to restore", result.stderr.lower())
            self.assertEqual(state.read_text().strip(), "37,true")

    def test_double_signal_runs_signal_resistant_restore_once(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            fake, calls, state = make_fake_osascript(root)
            ready = root / "ready"
            environment = environment_for(fake, calls, state)
            environment["UMBRA_PERF_SELF_TEST_READY"] = str(ready)
            process = subprocess.Popen(
                [str(RUNNER), "--self-test-signal-wait"],
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            try:
                deadline = time.monotonic() + 5
                while not ready.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(ready.exists())
                process.send_signal(signal.SIGTERM)
                process.send_signal(signal.SIGTERM)
                process.communicate(timeout=5)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()

            self.assertEqual(process.returncode, 143)
            self.assertEqual(state.read_text().strip(), "37,false")
            self.assertEqual(calls.read_text().count("set volume output volume 37 without output muted"), 1)

    def test_interrupt_signal_restores_audio_and_exits_130(self):
        self.assert_signal_restores_audio_and_exits(signal.SIGINT, 130)

    def test_hangup_signal_restores_audio_and_exits_129(self):
        self.assert_signal_restores_audio_and_exits(signal.SIGHUP, 129)

    def test_identity_artifact_failure_is_distinct_and_forces_cleanup_exit_70(self):
        result = subprocess.run(
            [str(RUNNER), "--self-test-identity-artifact-failure"],
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(result.returncode, 70)
        self.assertIn("helper/artifact failed with status 6", result.stderr)

    def test_readiness_wait_retries_bundle_registration_then_restores_audio_and_stops_owned_process(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            fake, calls, state = make_fake_osascript(root)
            counter = root / "readiness-count"
            counter.write_text("0\n")
            actions = root / "identity-actions.log"
            terminated = root / "terminated"
            identity = root / "identity.json"
            helper = root / "pid-helper"
            helper.write_text(
                "#!/bin/zsh\n"
                "print -r -- \"$1\" >> \"$UMBRA_PERF_IDENTITY_ACTIONS\"\n"
                "case \"$1\" in\n"
                "  capture-bootstrap) print -r -- '{}'; exit 0 ;;\n"
                "  verify-readiness)\n"
                "    [[ -f \"$UMBRA_PERF_TERMINATED\" ]] && exit 3\n"
                "    count=$(<\"$UMBRA_PERF_READINESS_COUNTER\")\n"
                "    count=$((count + 1))\n"
                "    print -r -- $count > \"$UMBRA_PERF_READINESS_COUNTER\"\n"
                "    (( count < 3 )) && exit 8\n"
                "    exit 0 ;;\n"
                "  verify) [[ -f \"$UMBRA_PERF_TERMINATED\" ]] && exit 3; exit 0 ;;\n"
                "  terminate|force-terminate|terminate-bootstrap|force-terminate-bootstrap)\n"
                "    : > \"$UMBRA_PERF_TERMINATED\"; exit 0 ;;\n"
                "  *) exit 9 ;;\n"
                "esac\n"
            )
            helper.chmod(0o755)
            environment = environment_for(fake, calls, state)
            environment["UMBRA_PERF_SELF_TEST_PID_HELPER"] = str(helper)
            environment["UMBRA_PERF_SELF_TEST_IDENTITY"] = str(identity)
            environment["UMBRA_PERF_SELF_TEST_READINESS_ATTEMPTS"] = "5"
            environment["UMBRA_PERF_SELF_TEST_READINESS_DELAY"] = "0.01"
            environment["UMBRA_PERF_READINESS_COUNTER"] = str(counter)
            environment["UMBRA_PERF_IDENTITY_ACTIONS"] = str(actions)
            environment["UMBRA_PERF_TERMINATED"] = str(terminated)

            result = subprocess.run(
                [str(RUNNER), "--self-test-readiness"],
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(counter.read_text().strip(), "3")
            self.assertEqual(actions.read_text().splitlines().count("capture-bootstrap"), 1)
            self.assertIn("terminate", actions.read_text().splitlines())
            self.assertNotIn("terminate-bootstrap", actions.read_text().splitlines())
            self.assertTrue(
                terminated.exists(),
                f"stderr={result.stderr!r} actions={actions.read_text()!r} calls={calls.read_text()!r}",
            )
            self.assertEqual(
                state.read_text().strip(),
                "37,false",
                f"stderr={result.stderr!r} calls={calls.read_text()!r}",
            )
            self.assertGreaterEqual(calls.read_text().count("get volume settings"), 2)

    def test_readiness_timeout_restores_audio_and_stops_the_bound_owned_process(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            fake, calls, state = make_fake_osascript(root)
            identity = root / "identity.json"
            counter = root / "readiness-count"
            counter.write_text("0\n")
            actions = root / "identity-actions.log"
            terminated = root / "terminated"
            helper = root / "pid-helper"
            helper.write_text(
                "#!/bin/zsh\n"
                "print -r -- \"$1\" >> \"$UMBRA_PERF_IDENTITY_ACTIONS\"\n"
                "case \"$1\" in\n"
                "  capture-bootstrap) print -r -- '{}'; exit 0 ;;\n"
                "  verify-readiness)\n"
                "    [[ -f \"$UMBRA_PERF_TERMINATED\" ]] && exit 3\n"
                "    count=$(<\"$UMBRA_PERF_READINESS_COUNTER\")\n"
                "    print -r -- $((count + 1)) > \"$UMBRA_PERF_READINESS_COUNTER\"\n"
                "    exit 8 ;;\n"
                "  verify) [[ -f \"$UMBRA_PERF_TERMINATED\" ]] && exit 3; exit 0 ;;\n"
                "  terminate|force-terminate|terminate-bootstrap|force-terminate-bootstrap)\n"
                "    : > \"$UMBRA_PERF_TERMINATED\"; exit 0 ;;\n"
                "  *) exit 9 ;;\n"
                "esac\n"
            )
            helper.chmod(0o755)
            environment = environment_for(fake, calls, state)
            environment["UMBRA_PERF_SELF_TEST_PID_HELPER"] = str(helper)
            environment["UMBRA_PERF_SELF_TEST_IDENTITY"] = str(identity)
            environment["UMBRA_PERF_SELF_TEST_READINESS_ATTEMPTS"] = "3"
            environment["UMBRA_PERF_SELF_TEST_READINESS_DELAY"] = "0.01"
            environment["UMBRA_PERF_READINESS_COUNTER"] = str(counter)
            environment["UMBRA_PERF_IDENTITY_ACTIONS"] = str(actions)
            environment["UMBRA_PERF_TERMINATED"] = str(terminated)

            result = subprocess.run(
                [str(RUNNER), "--self-test-readiness"],
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(
                result.returncode,
                8,
                f"stderr={result.stderr!r} actions={actions.read_text()!r}",
            )
            self.assertEqual(counter.read_text().strip(), "4")
            self.assertIn("bundle registration remained pending", result.stderr.lower())
            self.assertEqual(actions.read_text().splitlines().count("capture-bootstrap"), 1)
            self.assertIn("terminate-bootstrap", actions.read_text().splitlines())
            self.assertTrue(
                terminated.exists(),
                f"stderr={result.stderr!r} actions={actions.read_text()!r} calls={calls.read_text()!r}",
            )
            self.assertEqual(
                state.read_text().strip(),
                "37,false",
                f"stderr={result.stderr!r} calls={calls.read_text()!r}",
            )

    def test_readiness_wait_fails_identity_mismatch_without_retry(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            fake, _, state = make_fake_osascript(root)
            identity = root / "identity.json"
            counter = root / "readiness-count"
            counter.write_text("0\n")
            helper = root / "pid-helper"
            helper.write_text(
                "#!/bin/zsh\n"
                "case \"$1\" in\n"
                "  capture-bootstrap) print -r -- '{}'; exit 0 ;;\n"
                "  verify-readiness)\n"
                "    count=$(<\"$UMBRA_PERF_READINESS_COUNTER\")\n"
                "    print -r -- $((count + 1)) > \"$UMBRA_PERF_READINESS_COUNTER\"\n"
                "    exit 4 ;;\n"
                "  verify) exit 4 ;;\n"
                "  *) exit 9 ;;\n"
                "esac\n"
            )
            helper.chmod(0o755)
            environment = environment_for(fake, root / "calls.log", state)
            environment["UMBRA_PERF_SELF_TEST_PID_HELPER"] = str(helper)
            environment["UMBRA_PERF_SELF_TEST_IDENTITY"] = str(identity)
            environment["UMBRA_PERF_SELF_TEST_READINESS_ATTEMPTS"] = "5"
            environment["UMBRA_PERF_SELF_TEST_READINESS_DELAY"] = "0.01"
            environment["UMBRA_PERF_READINESS_COUNTER"] = str(counter)

            result = subprocess.run(
                [str(RUNNER), "--self-test-readiness"],
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 70)
            self.assertEqual(counter.read_text().strip(), "1")
            self.assertIn("identity changed during readiness", result.stderr.lower())
            self.assertEqual(state.read_text().strip(), "37,false")

    def test_readiness_process_exit_restores_audio_without_termination(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            fake, calls, state = make_fake_osascript(root)
            identity = root / "identity.json"
            terminated = root / "terminated"
            helper = root / "pid-helper"
            helper.write_text(
                "#!/bin/zsh\n"
                "case \"$1\" in\n"
                "  capture-bootstrap) print -r -- '{}'; exit 0 ;;\n"
                "  verify-readiness|verify) exit 3 ;;\n"
                "  terminate|force-terminate|terminate-bootstrap|force-terminate-bootstrap)\n"
                "    : > \"$UMBRA_PERF_TERMINATED\"; exit 0 ;;\n"
                "  *) exit 9 ;;\n"
                "esac\n"
            )
            helper.chmod(0o755)
            environment = environment_for(fake, calls, state)
            environment["UMBRA_PERF_SELF_TEST_PID_HELPER"] = str(helper)
            environment["UMBRA_PERF_SELF_TEST_IDENTITY"] = str(identity)
            environment["UMBRA_PERF_SELF_TEST_READINESS_ATTEMPTS"] = "5"
            environment["UMBRA_PERF_SELF_TEST_READINESS_DELAY"] = "0.01"
            environment["UMBRA_PERF_TERMINATED"] = str(terminated)

            result = subprocess.run(
                [str(RUNNER), "--self-test-readiness"],
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 3)
            self.assertIn("exited during readiness", result.stderr.lower())
            self.assertFalse(terminated.exists())
            self.assertEqual(
                state.read_text().strip(),
                "37,false",
                f"stderr={result.stderr!r} calls={calls.read_text()!r}",
            )

    def test_bootstrap_identity_mismatch_is_attempted_once_and_restores_audio(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            fake, calls, state = make_fake_osascript(root)
            identity = root / "identity.json"
            counter = root / "bootstrap-count"
            counter.write_text("0\n")
            helper = root / "pid-helper"
            helper.write_text(
                "#!/bin/zsh\n"
                "[[ \"$1\" == capture-bootstrap ]] || exit 9\n"
                "count=$(<\"$UMBRA_PERF_BOOTSTRAP_COUNTER\")\n"
                "print -r -- $((count + 1)) > \"$UMBRA_PERF_BOOTSTRAP_COUNTER\"\n"
                "exit 4\n"
            )
            helper.chmod(0o755)
            environment = environment_for(fake, calls, state)
            environment["UMBRA_PERF_SELF_TEST_PID_HELPER"] = str(helper)
            environment["UMBRA_PERF_SELF_TEST_IDENTITY"] = str(identity)
            environment["UMBRA_PERF_BOOTSTRAP_COUNTER"] = str(counter)

            result = subprocess.run(
                [str(RUNNER), "--self-test-readiness"],
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 4)
            self.assertEqual(counter.read_text().strip(), "1")
            self.assertEqual(state.read_text().strip(), "37,false")

    def test_bootstrap_process_exit_is_attempted_once_and_restores_audio(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            fake, calls, state = make_fake_osascript(root)
            identity = root / "identity.json"
            counter = root / "bootstrap-count"
            counter.write_text("0\n")
            helper = root / "pid-helper"
            helper.write_text(
                "#!/bin/zsh\n"
                "[[ \"$1\" == capture-bootstrap ]] || exit 9\n"
                "count=$(<\"$UMBRA_PERF_BOOTSTRAP_COUNTER\")\n"
                "print -r -- $((count + 1)) > \"$UMBRA_PERF_BOOTSTRAP_COUNTER\"\n"
                "exit 3\n"
            )
            helper.chmod(0o755)
            environment = environment_for(fake, calls, state)
            environment["UMBRA_PERF_SELF_TEST_PID_HELPER"] = str(helper)
            environment["UMBRA_PERF_SELF_TEST_IDENTITY"] = str(identity)
            environment["UMBRA_PERF_BOOTSTRAP_COUNTER"] = str(counter)

            result = subprocess.run(
                [str(RUNNER), "--self-test-readiness"],
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 3)
            self.assertEqual(counter.read_text().strip(), "1")
            self.assertEqual(state.read_text().strip(), "37,false")

    def test_workspace_launch_preserves_arguments_and_stops_only_returned_identity(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            fake, calls, state = make_fake_osascript(root)
            identity = root / "identity.json"
            actions = root / "launch-actions.log"
            terminated = root / "terminated"
            concurrent = root / "concurrent-umbra"
            concurrent.write_text("untouched\n")
            helper = root / "pid-helper"
            helper.write_text(
                "#!/bin/zsh\n"
                "print -r -- \"$1\" >> \"$UMBRA_PERF_LAUNCH_ACTIONS\"\n"
                "case \"$1\" in\n"
                "  launch)\n"
                "    shift\n"
                "    for argument in \"$@\"; do print -r -- \"ARG:$argument\" >> \"$UMBRA_PERF_LAUNCH_ACTIONS\"; done\n"
                "    print -r -- '{\"pid\":4242,\"bundle_identifier\":\"app.umbra.Umbra\",\"executable_path\":\"/fixture/Umbra\",\"executable_device\":1,\"executable_inode\":2,\"start_seconds\":3,\"start_microseconds\":4}'\n"
                "    exit 0 ;;\n"
                "  pid) print -r -- '4242'; exit 0 ;;\n"
                "  verify) [[ -f \"$UMBRA_PERF_TERMINATED\" ]] && exit 3; exit 0 ;;\n"
                "  terminate|force-terminate) : > \"$UMBRA_PERF_TERMINATED\"; exit 0 ;;\n"
                "  *) exit 9 ;;\n"
                "esac\n"
            )
            helper.chmod(0o755)
            environment = environment_for(fake, calls, state)
            environment["UMBRA_PERF_SELF_TEST_PID_HELPER"] = str(helper)
            environment["UMBRA_PERF_SELF_TEST_IDENTITY"] = str(identity)
            environment["UMBRA_PERF_SELF_TEST_APP"] = str(root / "Umbra.app")
            environment["UMBRA_PERF_SELF_TEST_HOST"] = "host with spaces"
            environment["UMBRA_PERF_SELF_TEST_APPLICATION"] = "Desktop Game"
            environment["UMBRA_PERF_LAUNCH_ACTIONS"] = str(actions)
            environment["UMBRA_PERF_TERMINATED"] = str(terminated)

            result = subprocess.run(
                [str(RUNNER), "--self-test-launch"],
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                actions.read_text().splitlines(),
                [
                    "launch",
                    f"ARG:{root / 'Umbra.app'}",
                    "ARG:app.umbra.Umbra",
                    "ARG:--",
                    "ARG:stream",
                    "ARG:host with spaces",
                    "ARG:Desktop Game",
                    "ARG:--no-quit-after",
                    "ARG:--no-audio-on-host",
                    "pid",
                    "verify",
                    "verify",
                    "terminate",
                    "verify",
                ],
            )
            self.assertTrue(terminated.exists())
            self.assertEqual(concurrent.read_text(), "untouched\n")
            self.assertEqual(state.read_text().strip(), "37,false")

    def test_workspace_launch_error_restores_audio_without_identity_adoption(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            fake, calls, state = make_fake_osascript(root)
            identity = root / "identity.json"
            actions = root / "launch-actions.log"
            helper = root / "pid-helper"
            helper.write_text(
                "#!/bin/zsh\n"
                "print -r -- \"$1\" >> \"$UMBRA_PERF_LAUNCH_ACTIONS\"\n"
                "[[ \"$1\" == launch ]] || exit 9\n"
                "exit 9\n"
            )
            helper.chmod(0o755)
            environment = environment_for(fake, calls, state)
            environment["UMBRA_PERF_SELF_TEST_PID_HELPER"] = str(helper)
            environment["UMBRA_PERF_SELF_TEST_IDENTITY"] = str(identity)
            environment["UMBRA_PERF_SELF_TEST_APP"] = str(root / "Umbra.app")
            environment["UMBRA_PERF_LAUNCH_ACTIONS"] = str(actions)

            result = subprocess.run(
                [str(RUNNER), "--self-test-launch"],
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 9)
            self.assertEqual(actions.read_text().splitlines(), ["launch"])
            self.assertEqual(state.read_text().strip(), "37,false")


class RunnerArgumentTests(unittest.TestCase):
    def test_missing_value_cannot_reinterpret_next_option_as_host(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            fake, calls, state = make_fake_osascript(root)

            result = subprocess.run(
                [str(RUNNER), "--host", "--dry-run"],
                env=environment_for(fake, calls, state),
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 2)
            self.assertFalse(calls.exists())
            self.assertEqual(state.read_text().strip(), "37,false")

    def test_symlink_artifact_root_is_rejected_before_audio_or_launch(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            fake, calls, state = make_fake_osascript(root)
            target = root / "target"
            target.mkdir()
            link = root / "artifacts"
            link.symlink_to(target, target_is_directory=True)

            result = subprocess.run(
                [
                    str(RUNNER),
                    "--host",
                    "benchmark.invalid",
                    "--output-root",
                    str(link),
                    "--dry-run",
                ],
                env=environment_for(fake, calls, state),
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 2)
            self.assertFalse(calls.exists())
            self.assertEqual(list(target.iterdir()), [])


class PIDScopedTerminationTests(unittest.TestCase):
    def compile_helper(self, root: Path) -> Path:
        helper = root / "pid-helper"
        compile_result = subprocess.run(
            [
                "xcrun",
                "swiftc",
                str(ROOT / "PIDScopedTermination.swift"),
                "-o",
                str(helper),
            ],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(compile_result.returncode, 0, compile_result.stderr)
        return helper

    def test_tampered_identity_cannot_terminate_owned_or_unrelated_process(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            helper = self.compile_helper(root)
            malformed = root / "malformed.json"
            malformed.write_text("not json")
            malformed_result = subprocess.run(
                [str(helper), "verify", str(malformed)],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(malformed_result.returncode, 6)
            unavailable_result = subprocess.run(
                [str(helper), "identity", "999999", "/bin/sleep", ""],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(unavailable_result.returncode, 3)
            sleeper = subprocess.Popen(["/bin/sleep", "30"])
            try:
                identity_path = root / "identity.json"
                identity_result = subprocess.run(
                    [str(helper), "identity", str(sleeper.pid), "/bin/sleep", ""],
                    text=True,
                    capture_output=True,
                    check=False,
                )
                self.assertEqual(identity_result.returncode, 0, identity_result.stderr)
                identity = json.loads(identity_result.stdout)
                identity["executable_inode"] += 1
                identity_path.write_text(json.dumps(identity))

                termination = subprocess.run(
                    [str(helper), "terminate", str(identity_path)],
                    text=True,
                    capture_output=True,
                    check=False,
                )

                self.assertNotEqual(termination.returncode, 0)
                self.assertIsNone(sleeper.poll())
            finally:
                sleeper.terminate()
                sleeper.wait(timeout=5)

    def test_bootstrap_rejects_process_without_running_application_registration(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            helper = self.compile_helper(root)
            sleeper = subprocess.Popen(["/bin/sleep", "30"])
            try:
                captured = subprocess.run(
                    [
                        str(helper),
                        "capture-bootstrap",
                        str(sleeper.pid),
                        "/bin/sleep",
                        "app.umbra.ReadinessFixture",
                    ],
                    text=True,
                    capture_output=True,
                    check=False,
                )

                self.assertEqual(captured.returncode, 5)
                self.assertIn("nsrunningapplication unavailable", captured.stderr.lower())
                self.assertEqual(captured.stdout, "")
                self.assertIsNone(sleeper.poll())
            finally:
                sleeper.terminate()
                sleeper.wait(timeout=5)

    def test_workspace_launch_returns_exact_pid_and_preserves_arguments(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            helper = self.compile_helper(root)
            app, executable = make_launchable_fixture_app(root)
            launch_record = root / "launch-record.json"
            identity_path = root / "identity.json"
            launch_arguments = [
                "--launch-record",
                str(launch_record),
                "stream",
                "host with spaces",
                "Desktop Game",
                "--no-quit-after",
            ]

            launched = subprocess.run(
                [
                    str(helper),
                    "launch",
                    str(app),
                    "app.umbra.LaunchFixture",
                    "--",
                    *launch_arguments,
                ],
                text=True,
                capture_output=True,
                check=False,
                timeout=10,
            )
            self.assertEqual(launched.returncode, 0, launched.stderr)
            identity_path.write_text(launched.stdout)
            identity = json.loads(launched.stdout)
            try:
                deadline = time.monotonic() + 5
                while not launch_record.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(launch_record.exists())
                record = json.loads(launch_record.read_text())
                self.assertEqual(identity["pid"], record["pid"])
                self.assertEqual(record["arguments"], launch_arguments)
                self.assertEqual(identity["bundle_identifier"], "app.umbra.LaunchFixture")
                self.assertTrue(os.path.samefile(identity["executable_path"], executable))
                verified = subprocess.run(
                    [str(helper), "verify", str(identity_path)],
                    text=True,
                    capture_output=True,
                    check=False,
                )
                self.assertEqual(verified.returncode, 0, verified.stderr)
            finally:
                terminated = subprocess.run(
                    [str(helper), "force-terminate", str(identity_path)],
                    text=True,
                    capture_output=True,
                    check=False,
                )
                self.assertEqual(terminated.returncode, 0, terminated.stderr)
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    exited = subprocess.run(
                        [str(helper), "verify", str(identity_path)],
                        text=True,
                        capture_output=True,
                        check=False,
                    )
                    if exited.returncode == 3:
                        break
                    time.sleep(0.01)
                self.assertEqual(exited.returncode, 3, exited.stderr)

    def test_workspace_placeholder_launch_returns_unique_new_candidate(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            helper = self.compile_helper(root)
            app, _ = make_launchable_fixture_app(root)
            launch_record = root / "launch-record.json"
            identity_path = root / "identity.json"

            launched = subprocess.run(
                [
                    str(helper),
                    "launch",
                    str(app),
                    "app.umbra.LaunchFixture",
                    "--",
                    "--launch-record",
                    str(launch_record),
                ],
                text=True,
                capture_output=True,
                check=False,
                env={
                    **os.environ,
                    "UMBRA_PERF_TEST_FORCE_PLACEHOLDER": "1",
                },
                timeout=10,
            )
            self.assertEqual(launched.returncode, 0, launched.stderr)
            identity_path.write_text(launched.stdout)
            identity = json.loads(launched.stdout)
            try:
                self.assertTrue(launch_record.exists())
                self.assertEqual(identity["pid"], json.loads(launch_record.read_text())["pid"])
            finally:
                subprocess.run(
                    [str(helper), "force-terminate", str(identity_path)],
                    text=True,
                    capture_output=True,
                    check=False,
                )

    def test_workspace_positive_returned_pid_exit_never_adopts_concurrent_sibling(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            helper = self.compile_helper(root)
            app, _ = make_launchable_fixture_app(root)
            primary_record = root / "primary-record.json"
            sibling_record = root / "sibling-record.json"
            sibling_pid = None
            try:
                launched = subprocess.run(
                    [
                        str(helper),
                        "launch",
                        str(app),
                        "app.umbra.LaunchFixture",
                        "--",
                        "--launch-record",
                        str(primary_record),
                        "--spawn-sibling-record",
                        str(sibling_record),
                        "--exit-after-ms",
                        "100",
                    ],
                    text=True,
                    capture_output=True,
                    check=False,
                    env={
                        **os.environ,
                        "UMBRA_PERF_TEST_RETURNED_CAPTURE_DELAY_MS": "300",
                    },
                    timeout=10,
                )
                self.assertEqual(launched.returncode, 3, launched.stderr)
                self.assertEqual(launched.stdout, "")
                deadline = time.monotonic() + 5
                while (
                    (not primary_record.exists() or not sibling_record.exists())
                    and time.monotonic() < deadline
                ):
                    time.sleep(0.01)
                self.assertTrue(primary_record.exists())
                self.assertTrue(sibling_record.exists())
                primary_pid = json.loads(primary_record.read_text())["pid"]
                sibling_pid = json.loads(sibling_record.read_text())["pid"]
                self.assertNotEqual(primary_pid, sibling_pid)
                with self.assertRaises(ProcessLookupError):
                    os.kill(primary_pid, 0)
                os.kill(sibling_pid, 0)
            finally:
                if sibling_pid is not None:
                    stop_fixture_process(sibling_pid)

    def test_workspace_placeholder_launch_fails_when_no_new_candidate_is_visible(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            helper = self.compile_helper(root)
            app, _ = make_launchable_fixture_app(root)
            launch_record = root / "launch-record.json"
            process_pid = None
            try:
                launched = subprocess.run(
                    [
                        str(helper),
                        "launch",
                        str(app),
                        "app.umbra.LaunchFixture",
                        "--",
                        "--launch-record",
                        str(launch_record),
                    ],
                    text=True,
                    capture_output=True,
                    check=False,
                    env={
                        **os.environ,
                        "UMBRA_PERF_TEST_FORCE_PLACEHOLDER": "1",
                        "UMBRA_PERF_TEST_HIDE_CANDIDATES": "1",
                    },
                    timeout=15,
                )
                self.assertEqual(launched.returncode, 9)
                self.assertEqual(launched.stdout, "")
                self.assertIn("observed_new_pids", launched.stderr)
                if launch_record.exists():
                    process_pid = json.loads(launch_record.read_text())["pid"]
            finally:
                if process_pid is not None:
                    stop_fixture_process(process_pid)

    def test_workspace_placeholder_launch_fails_without_adopting_two_concurrent_candidates(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            helper = self.compile_helper(root)
            app, _ = make_launchable_fixture_app(root)
            primary_record = root / "primary-record.json"
            sibling_record = root / "sibling-record.json"
            process_pids = []
            try:
                launched = subprocess.run(
                    [
                        str(helper),
                        "launch",
                        str(app),
                        "app.umbra.LaunchFixture",
                        "--",
                        "--launch-record",
                        str(primary_record),
                        "--spawn-sibling-record",
                        str(sibling_record),
                    ],
                    text=True,
                    capture_output=True,
                    check=False,
                    env={
                        **os.environ,
                        "UMBRA_PERF_TEST_FORCE_PLACEHOLDER": "1",
                    },
                    timeout=15,
                )
                self.assertEqual(launched.returncode, 9, launched.stderr)
                self.assertIn("ambiguous", launched.stderr.lower())
                deadline = time.monotonic() + 5
                while (
                    (not primary_record.exists() or not sibling_record.exists())
                    and time.monotonic() < deadline
                ):
                    time.sleep(0.01)
                self.assertTrue(primary_record.exists())
                self.assertTrue(sibling_record.exists())
                process_pids = [
                    json.loads(primary_record.read_text())["pid"],
                    json.loads(sibling_record.read_text())["pid"],
                ]
                for process_pid in process_pids:
                    os.kill(process_pid, 0)
            finally:
                for process_pid in process_pids:
                    stop_fixture_process(process_pid)

    def test_workspace_placeholder_launch_reports_process_exit_without_adoption(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            helper = self.compile_helper(root)
            app, _ = make_launchable_fixture_app(root)
            launch_record = root / "launch-record.json"

            launched = subprocess.run(
                [
                    str(helper),
                    "launch",
                    str(app),
                    "app.umbra.LaunchFixture",
                    "--",
                    "--launch-record",
                    str(launch_record),
                    "--exit-immediately",
                ],
                text=True,
                capture_output=True,
                check=False,
                env={
                    **os.environ,
                    "UMBRA_PERF_TEST_FORCE_PLACEHOLDER": "1",
                },
                timeout=15,
            )

            self.assertEqual(launched.returncode, 9)
            self.assertEqual(launched.stdout, "")
            self.assertTrue(launch_record.exists())
            exited_pid = json.loads(launch_record.read_text())["pid"]
            self.assertIn("is_terminated", launched.stderr)
            self.assertIn("observed_new_pids", launched.stderr)
            self.assertIn("disappeared_candidate_pids", launched.stderr)
            self.assertIn(str(exited_pid), launched.stderr)

    def test_workspace_launch_rejects_wrong_expected_bundle_before_launch(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            helper = self.compile_helper(root)
            app, _ = make_launchable_fixture_app(root)
            launch_record = root / "launch-record.json"

            launched = subprocess.run(
                [
                    str(helper),
                    "launch",
                    str(app),
                    "app.umbra.WrongBundle",
                    "--",
                    "--launch-record",
                    str(launch_record),
                ],
                text=True,
                capture_output=True,
                check=False,
                timeout=10,
            )

            self.assertEqual(launched.returncode, 4)
            self.assertIn("bundle mismatch", launched.stderr.lower())
            self.assertFalse(launch_record.exists())

    def test_workspace_launch_reports_invalid_app_without_identity_output(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            helper = self.compile_helper(root)

            launched = subprocess.run(
                [
                    str(helper),
                    "launch",
                    str(root / "Missing.app"),
                    "app.umbra.Missing",
                    "--",
                    "stream",
                ],
                text=True,
                capture_output=True,
                check=False,
                timeout=10,
            )

            self.assertEqual(launched.returncode, 9)
            self.assertEqual(launched.stdout, "")

    def test_readiness_reports_missing_running_application_as_nonretryable(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            helper = self.compile_helper(root)
            sleeper = subprocess.Popen(["/bin/sleep", "30"])
            try:
                identity_path = root / "identity.json"
                captured = subprocess.run(
                    [
                        str(helper),
                        "identity",
                        str(sleeper.pid),
                        "/bin/sleep",
                        "app.umbra.ReadinessFixture",
                    ],
                    text=True,
                    capture_output=True,
                    check=False,
                )
                self.assertEqual(captured.returncode, 0, captured.stderr)
                identity_path.write_text(captured.stdout)
                original_identity = identity_path.read_bytes()

                readiness = subprocess.run(
                    [str(helper), "verify-readiness", str(identity_path)],
                    text=True,
                    capture_output=True,
                    check=False,
                )

                self.assertEqual(readiness.returncode, 5, readiness.stderr)
                self.assertIn("nsrunningapplication unavailable", readiness.stderr.lower())
                self.assertEqual(identity_path.read_bytes(), original_identity)
                strict = subprocess.run(
                    [str(helper), "verify", str(identity_path)],
                    text=True,
                    capture_output=True,
                    check=False,
                )
                self.assertEqual(strict.returncode, 5)
            finally:
                sleeper.terminate()
                sleeper.wait(timeout=5)

    def test_readiness_rejects_executable_identity_mismatch(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            helper = self.compile_helper(root)
            sleeper = subprocess.Popen(["/bin/sleep", "30"])
            try:
                captured = subprocess.run(
                    [str(helper), "identity", str(sleeper.pid), "/bin/sleep", ""],
                    text=True,
                    capture_output=True,
                    check=False,
                )
                self.assertEqual(captured.returncode, 0, captured.stderr)
                identity = json.loads(captured.stdout)
                identity["executable_inode"] += 1
                identity_path = root / "identity.json"
                identity_path.write_text(json.dumps(identity))

                readiness = subprocess.run(
                    [str(helper), "verify-readiness", str(identity_path)],
                    text=True,
                    capture_output=True,
                    check=False,
                )

                self.assertEqual(readiness.returncode, 4)
                self.assertIn("identity changed", readiness.stderr.lower())
                self.assertIsNone(sleeper.poll())
            finally:
                sleeper.terminate()
                sleeper.wait(timeout=5)

    def test_readiness_rejects_pid_substitution(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            helper = self.compile_helper(root)
            original = subprocess.Popen(["/bin/sleep", "30"])
            replacement = subprocess.Popen(["/bin/sleep", "30"])
            try:
                captured = subprocess.run(
                    [str(helper), "identity", str(original.pid), "/bin/sleep", ""],
                    text=True,
                    capture_output=True,
                    check=False,
                )
                self.assertEqual(captured.returncode, 0, captured.stderr)
                identity = json.loads(captured.stdout)
                identity["pid"] = replacement.pid
                identity_path = root / "identity.json"
                identity_path.write_text(json.dumps(identity))

                readiness = subprocess.run(
                    [str(helper), "verify-readiness", str(identity_path)],
                    text=True,
                    capture_output=True,
                    check=False,
                )

                self.assertEqual(readiness.returncode, 4)
                self.assertIsNone(original.poll())
                self.assertIsNone(replacement.poll())
            finally:
                original.terminate()
                replacement.terminate()
                original.wait(timeout=5)
                replacement.wait(timeout=5)

    def test_readiness_rejects_process_start_time_mismatch(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            helper = self.compile_helper(root)
            sleeper = subprocess.Popen(["/bin/sleep", "30"])
            try:
                captured = subprocess.run(
                    [str(helper), "identity", str(sleeper.pid), "/bin/sleep", ""],
                    text=True,
                    capture_output=True,
                    check=False,
                )
                self.assertEqual(captured.returncode, 0, captured.stderr)
                identity = json.loads(captured.stdout)
                identity["start_microseconds"] += 1
                identity_path = root / "identity.json"
                identity_path.write_text(json.dumps(identity))

                readiness = subprocess.run(
                    [str(helper), "verify-readiness", str(identity_path)],
                    text=True,
                    capture_output=True,
                    check=False,
                )

                self.assertEqual(readiness.returncode, 4)
                self.assertIsNone(sleeper.poll())
            finally:
                sleeper.terminate()
                sleeper.wait(timeout=5)

    def test_readiness_reports_process_exit_without_waiting_for_bundle(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            helper = self.compile_helper(root)
            sleeper = subprocess.Popen(["/bin/sleep", "30"])
            captured = subprocess.run(
                [str(helper), "identity", str(sleeper.pid), "/bin/sleep", ""],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(captured.returncode, 0, captured.stderr)
            identity_path = root / "identity.json"
            identity_path.write_text(captured.stdout)
            sleeper.terminate()
            sleeper.wait(timeout=5)

            readiness = subprocess.run(
                [str(helper), "verify-readiness", str(identity_path)],
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(readiness.returncode, 3)
            self.assertIn("unavailable", readiness.stderr.lower())


class SupportLogRetentionTests(unittest.TestCase):
    def test_retained_descriptor_survives_rotation_replacement_and_symlink_race(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            support_log = root / "Umbra-session.log"
            support_log.write_text(
                "2026-08-24T00:00:01Z [INFO] [Media] Video decoder produced frame 1.\n"
            )
            metadata = support_log.stat()
            snapshot = root / "snapshot.log"
            binding = root / "binding.json"
            ready = root / "ready"
            marker = root / "first-frame"
            retainer = subprocess.Popen(
                [
                    "python3",
                    str(ROOT / "retain_support_log.py"),
                    "--log",
                    str(support_log),
                    "--snapshot",
                    str(snapshot),
                    "--binding",
                    str(binding),
                    "--ready",
                    str(ready),
                    "--first-frame-marker",
                    str(marker),
                    "--expected-device",
                    str(metadata.st_dev),
                    "--expected-inode",
                    str(metadata.st_ino),
                    "--expected-client-fd",
                    "42u",
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            try:
                deadline = time.monotonic() + 5
                while not ready.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(ready.exists())
                while not marker.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(marker.exists())
                rotated = root / "Umbra-session.log.1"
                support_log.rename(rotated)
                malicious = root / "malicious.log"
                malicious.write_text("MALICIOUS REPLACEMENT\n")
                support_log.symlink_to(malicious)
                with rotated.open("a") as handle:
                    handle.write("ORIGINAL INODE TEARDOWN SUMMARY\n")
                retainer.send_signal(signal.SIGTERM)
                _, stderr = retainer.communicate(timeout=5)
                self.assertEqual(retainer.returncode, 0, stderr)
            finally:
                if retainer.poll() is None:
                    retainer.kill()
                    retainer.communicate()

            contents = snapshot.read_text()
            self.assertIn("ORIGINAL INODE TEARDOWN SUMMARY", contents)
            self.assertNotIn("MALICIOUS REPLACEMENT", contents)
            retained = json.loads(binding.read_text())
            self.assertEqual(retained["device"], metadata.st_dev)
            self.assertEqual(retained["inode"], metadata.st_ino)
            self.assertEqual(retained["client_fd_at_discovery"], "42u")

    def test_replacement_between_discovery_and_open_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            support_log = root / "Umbra-race.log"
            support_log.write_text("ORIGINAL\n")
            discovered = support_log.stat()
            support_log.rename(root / "Umbra-race.log.original")
            support_log.write_text("REPLACEMENT\n")

            result = subprocess.run(
                [
                    "python3",
                    str(ROOT / "retain_support_log.py"),
                    "--log",
                    str(support_log),
                    "--snapshot",
                    str(root / "snapshot.log"),
                    "--binding",
                    str(root / "binding.json"),
                    "--ready",
                    str(root / "ready"),
                    "--first-frame-marker",
                    str(root / "first-frame"),
                    "--expected-device",
                    str(discovered.st_dev),
                    "--expected-inode",
                    str(discovered.st_ino),
                    "--expected-client-fd",
                    "42u",
                ],
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((root / "ready").exists())
            self.assertFalse((root / "snapshot.log").exists())

    def test_discovery_filters_empty_lsof_entries_and_waits_for_delayed_open(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            log = root / "Umbra-delayed.log"
            log.write_text("ready\n")
            counter = root / "counter"
            counter.write_text("0")
            metadata = log.stat()
            fake_lsof = root / "lsof"
            fake_lsof.write_text(
                "#!/bin/zsh\n"
                "count=$(<\"$UMBRA_DISCOVERY_COUNTER\")\n"
                "count=$((count + 1))\n"
                "print -r -- $count > \"$UMBRA_DISCOVERY_COUNTER\"\n"
                "print -r -- 'p123'\n"
                "print -r -- 'f9r'\n"
                "print -r -- \"D$UMBRA_DISCOVERY_DEVICE\"\n"
                "print -r -- \"i$UMBRA_DISCOVERY_INODE\"\n"
                "print -r -- 'n'\n"
                "if (( count >= 3 )); then\n"
                "  print -r -- 'f42u'\n"
                "  print -r -- \"D$UMBRA_DISCOVERY_DEVICE\"\n"
                "  print -r -- \"i$UMBRA_DISCOVERY_INODE\"\n"
                "  print -r -- \"n$UMBRA_DISCOVERY_LOG\"\n"
                "fi\n"
            )
            fake_lsof.chmod(0o755)
            environment = os.environ.copy()
            environment["UMBRA_DISCOVERY_COUNTER"] = str(counter)
            environment["UMBRA_DISCOVERY_LOG"] = str(log)
            environment["UMBRA_DISCOVERY_DEVICE"] = str(metadata.st_dev)
            environment["UMBRA_DISCOVERY_INODE"] = str(metadata.st_ino)

            result = subprocess.run(
                [
                    "python3",
                    str(ROOT / "discover_support_log.py"),
                    "--pid",
                    "123",
                    "--root",
                    str(root),
                    "--timeout-ms",
                    "1000",
                    "--lsof",
                    str(fake_lsof),
                ],
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                result.stdout.strip(),
                f"{log}\t42u\t{metadata.st_dev}\t{metadata.st_ino}",
            )
            self.assertGreaterEqual(int(counter.read_text()), 3)

            verified = subprocess.run(
                [
                    "python3",
                    str(ROOT / "discover_support_log.py"),
                    "--pid",
                    "123",
                    "--root",
                    str(root),
                    "--timeout-ms",
                    "100",
                    "--lsof",
                    str(fake_lsof),
                    "--expected-fd",
                    "42u",
                    "--expected-device",
                    str(metadata.st_dev),
                    "--expected-inode",
                    str(metadata.st_ino),
                ],
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(verified.returncode, 0, verified.stderr)

            mismatched = subprocess.run(
                [
                    "python3",
                    str(ROOT / "discover_support_log.py"),
                    "--pid",
                    "123",
                    "--root",
                    str(root),
                    "--timeout-ms",
                    "50",
                    "--lsof",
                    str(fake_lsof),
                    "--expected-fd",
                    "99u",
                    "--expected-device",
                    str(metadata.st_dev),
                    "--expected-inode",
                    str(metadata.st_ino),
                ],
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(mismatched.returncode, 0)


class ParserOutputSafetyTests(unittest.TestCase):
    def test_output_directory_symlink_is_rejected_without_touching_target(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            target = root / "target"
            target.mkdir()
            link = root / "output-link"
            link.symlink_to(target, target_is_directory=True)

            result = subprocess.run(
                [
                    "python3",
                    str(ROOT / "parse_benchmark.py"),
                    "--run-id",
                    "run-fixture",
                    "--trace-id",
                    "trace-fixture",
                    "--runner-events",
                    str(ROOT / "fixtures/runner-events.jsonl"),
                    "--umbra-log",
                    str(ROOT / "fixtures/umbra-support.log"),
                    "--output-dir",
                    str(link),
                ],
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(list(target.iterdir()), [])

    def test_missing_required_evidence_writes_insufficient_report_and_returns_two(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            output = Path(temporary_directory) / "report"

            result = subprocess.run(
                [
                    "python3",
                    str(ROOT / "parse_benchmark.py"),
                    "--run-id",
                    "run-empty",
                    "--trace-id",
                    "trace-empty",
                    "--output-dir",
                    str(output),
                ],
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 2, result.stderr)
            report = json.loads((output / "report.json").read_text())
            self.assertEqual(report["threshold_evaluation"]["status"], "insufficient_data")
            self.assertEqual((output / "report.json").stat().st_mode & 0o777, 0o600)
            self.assertEqual((output / "report.md").stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
