#!/bin/zsh
set -euo pipefail
umask 077

script_root="${0:A:h}"
repository_root="${script_root:h:h}"
packaged_app="$repository_root/.build/Umbra.app"
host=""
application="Desktop"
duration_seconds=12
output_root="$repository_root/.build/performance-runs"
lumen_log=""
client_telemetry=""
network_kind="unknown"
declared_mode="unknown"
client_protocol="umbra-legacy"
dry_run=0
self_test_cleanup=""
self_test_readiness=0
self_test_launch=0
osascript_command="${UMBRA_PERF_OSASCRIPT:-/usr/bin/osascript}"

usage() {
    print -r -- "Usage: $0 --host <saved-host-name-or-address> [options]"
    print -r -- "  --app <name>                 Host application (default: Desktop)"
    print -r -- "  --duration <5-60>            Measured streaming seconds (default: 12)"
    print -r -- "  --umbra-app <path>           Packaged Umbra.app"
    print -r -- "  --lumen-log <path>           Optional locally accessible Lumen log"
    print -r -- "  --client-telemetry <path>    Optional JSONL telemetry export"
    print -r -- "  --network-kind <kind>        lan|wifi|vpn|cellular|wan|unknown"
    print -r -- "  --declared-mode <mode>       latency|quality|unknown"
    print -r -- "  --client-protocol <kind>     vanilla-moonlight|umbra-legacy|umbra-v2"
    print -r -- "  --output-root <path>         Real, non-symlink artifact parent"
    print -r -- "  --dry-run                    Validate safety checks without launching"
}

require_value() {
    local option="$1"
    local candidate="${2:-}"
    if [[ -z "$candidate" || "$candidate" == -* ]]; then
        print -u2 -r -- "$option requires a following non-option value."
        exit 2
    fi
}

while (( $# > 0 )); do
    case "$1" in
        --host|--app|--duration|--umbra-app|--lumen-log|--client-telemetry|--network-kind|--declared-mode|--client-protocol|--output-root)
            require_value "$1" "${2:-}"
            option="$1"
            value="$2"
            shift 2
            case "$option" in
                --host) host="$value" ;;
                --app) application="$value" ;;
                --duration) duration_seconds="$value" ;;
                --umbra-app) packaged_app="$value" ;;
                --lumen-log) lumen_log="$value" ;;
                --client-telemetry) client_telemetry="$value" ;;
                --network-kind) network_kind="$value" ;;
                --declared-mode) declared_mode="$value" ;;
                --client-protocol) client_protocol="$value" ;;
                --output-root) output_root="$value" ;;
            esac
            ;;
        --dry-run)
            dry_run=1
            shift
            ;;
        --self-test-cleanup)
            self_test_cleanup="failure"
            shift
            ;;
        --self-test-cleanup-success)
            self_test_cleanup="success"
            shift
            ;;
        --self-test-signal-wait)
            self_test_cleanup="signal"
            shift
            ;;
        --self-test-identity-artifact-failure)
            self_test_cleanup="identity"
            shift
            ;;
        --self-test-readiness)
            self_test_readiness=1
            shift
            ;;
        --self-test-launch)
            self_test_launch=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            print -u2 -r -- "Unknown option: $1"
            usage >&2
            exit 2
            ;;
    esac
done

audio_volume=""
audio_muted=""
audio_restore_pending=0
cleanup_started=0
cleanup_failure=0
process_failure=0
client_pid=""
client_identity=""
client_readiness_confirmed=0
client_cleanup_block_status=0
pid_helper=""
retainer_pid=""
temporary_workspace=""

read_audio_state() {
    local settings
    settings="$($osascript_command -e 'get volume settings')" || return 1
    if [[ "$settings" =~ 'output volume:([0-9]+)' ]]; then
        REPLY_VOLUME="$match[1]"
    else
        return 1
    fi
    if [[ "$settings" =~ 'output muted:(true|false)' ]]; then
        REPLY_MUTED="$match[1]"
    else
        return 1
    fi
}

capture_audio_state() {
    read_audio_state || {
        print -u2 -r -- "Could not capture the exact macOS output volume and mute state."
        return 1
    }
    audio_volume="$REPLY_VOLUME"
    audio_muted="$REPLY_MUTED"
}

mute_audio_output() {
    # Restoration is pending before the mutating call, including partial failures.
    audio_restore_pending=1
    $osascript_command -e 'set volume with output muted' >/dev/null
}

restore_audio_output() {
    (( audio_restore_pending == 1 )) || return 0
    local attempt=0
    while (( attempt < 3 )); do
        if [[ "$audio_muted" == "true" ]]; then
            $osascript_command -e "set volume output volume $audio_volume with output muted" >/dev/null 2>&1 || true
        else
            $osascript_command -e "set volume output volume $audio_volume without output muted" >/dev/null 2>&1 || true
        fi
        if read_audio_state \
            && [[ "$REPLY_VOLUME" == "$audio_volume" && "$REPLY_MUTED" == "$audio_muted" ]]; then
            audio_restore_pending=0
            return 0
        fi
        (( attempt += 1 ))
        sleep 0.05
    done
    print -u2 -r -- "Failed to restore and verify the original audio volume/mute state."
    cleanup_failure=1
    return 1
}

identity_status() {
    [[ -n "$pid_helper" && -x "$pid_helper" && -n "$client_identity" && -f "$client_identity" ]] || return 6
    "$pid_helper" verify "$client_identity" >/dev/null 2>&1
}

owned_identity_status() {
    if (( client_readiness_confirmed == 1 )); then
        identity_status
        return $?
    fi
    [[ -n "$pid_helper" && -x "$pid_helper" && -n "$client_identity" && -f "$client_identity" ]] || return 6
    local readiness_result=0
    if "$pid_helper" verify-readiness "$client_identity" >/dev/null 2>&1; then
        client_readiness_confirmed=1
        return 0
    else
        readiness_result=$?
    fi
    (( readiness_result == 8 )) && return 0
    return "$readiness_result"
}

termination_action() {
    local force="$1"
    if (( client_readiness_confirmed == 1 )); then
        (( force == 1 )) && print -r -- "force-terminate" || print -r -- "terminate"
    else
        (( force == 1 )) && print -r -- "force-terminate-bootstrap" || print -r -- "terminate-bootstrap"
    fi
}

wait_for_identity_readiness() {
    local readiness_helper="$1"
    local identity_artifact="$2"
    local attempts="$3"
    local delay_seconds="$4"
    local index=0
    local result=0
    while (( index < attempts )); do
        if "$readiness_helper" verify-readiness "$identity_artifact" >/dev/null 2>&1; then
            return 0
        else
            result=$?
        fi
        case "$result" in
            8)
                (( index += 1 ))
                if (( index < attempts )); then
                    sleep "$delay_seconds"
                    continue
                fi
                print -u2 -r -- "Umbra bundle registration remained pending through the bounded readiness wait."
                return 8
                ;;
            3)
                print -u2 -r -- "Umbra exited during readiness verification."
                return 3
                ;;
            4)
                print -u2 -r -- "Umbra PID/executable/start identity changed during readiness verification."
                return 4
                ;;
            *)
                print -u2 -r -- "Umbra identity helper/artifact failed with status $result during readiness verification."
                return "$result"
                ;;
        esac
    done
    return 8
}

launch_bound_client() {
    local launch_helper="$1"
    local app_path="$2"
    local identity_artifact="$3"
    local diagnostics_path="$4"
    local launch_host="$5"
    local launch_application="$6"
    local launch_result=0
    if "$launch_helper" launch \
        "$app_path" \
        app.umbra.Umbra \
        -- \
        stream \
        "$launch_host" \
        "$launch_application" \
        --no-quit-after \
        --no-audio-on-host \
        > "$identity_artifact" \
        2> "$diagnostics_path"; then
        pid_helper="$launch_helper"
        client_identity="$identity_artifact"
    else
        launch_result=$?
        return "$launch_result"
    fi

    if ! client_pid="$("$pid_helper" pid "$client_identity")"; then
        return 6
    fi
    [[ "$client_pid" == <-> ]] || return 6
    client_readiness_confirmed=1
    if identity_status; then
        return 0
    else
        launch_result=$?
    fi
    (( launch_result != 3 )) && client_cleanup_block_status="$launch_result"
    return "$launch_result"
}

wait_for_identity_exit() {
    local attempts="$1"
    local index=0
    while (( index < attempts )); do
        owned_identity_status
        local result=$?
        if (( result == 3 )); then
            return 0
        fi
        if (( result != 0 )); then
            if (( result == 4 )); then
                print -u2 -r -- "Umbra PID identity changed during cleanup; refusing to touch the replacement process."
            else
                print -u2 -r -- "Umbra identity helper/artifact failed with status $result during cleanup."
            fi
            process_failure=1
            return 2
        fi
        sleep 0.1
        (( index += 1 ))
    done
    return 1
}

stop_owned_client() {
    [[ -n "$client_identity" ]] || return 0
    if (( client_cleanup_block_status != 0 )); then
        if (( client_cleanup_block_status == 4 )); then
            print -u2 -r -- "Umbra PID identity no longer matches; no termination was attempted."
        else
            print -u2 -r -- "Umbra identity helper failed with status $client_cleanup_block_status; no termination was attempted."
        fi
        process_failure=1
        return 1
    fi
    owned_identity_status
    local initial_status=$?
    if (( initial_status == 3 )); then
        return 0
    fi
    if (( initial_status != 0 )); then
        if (( initial_status == 4 )); then
            print -u2 -r -- "Umbra PID identity no longer matches; no termination was attempted."
        else
            print -u2 -r -- "Umbra identity helper/artifact failed with status $initial_status; no termination was attempted."
        fi
        process_failure=1
        return 1
    fi

    local action="$(termination_action 0)"
    "$pid_helper" "$action" "$client_identity" >/dev/null 2>&1 || true
    wait_for_identity_exit 50 && return 0
    (( process_failure == 0 )) || return 1

    # Retry graceful termination only after another exact identity verification.
    owned_identity_status || {
        print -u2 -r -- "Umbra identity verification failed before termination retry."
        process_failure=1
        return 1
    }
    action="$(termination_action 0)"
    "$pid_helper" "$action" "$client_identity" >/dev/null 2>&1 || true
    wait_for_identity_exit 30 && return 0
    (( process_failure == 0 )) || return 1

    owned_identity_status || {
        print -u2 -r -- "Umbra identity verification failed before force termination."
        process_failure=1
        return 1
    }
    action="$(termination_action 1)"
    "$pid_helper" "$action" "$client_identity" >/dev/null 2>&1 || true
    if ! wait_for_identity_exit 50; then
        print -u2 -r -- "Owned Umbra process survived PID-scoped graceful and force termination."
        process_failure=1
        return 1
    fi
}

stop_retainer() {
    [[ -n "$retainer_pid" ]] || return 0
    if kill -0 "$retainer_pid" 2>/dev/null; then
        kill -TERM "$retainer_pid" 2>/dev/null || true
        if ! wait "$retainer_pid"; then
            print -u2 -r -- "Retained support-log snapshot failed."
            cleanup_failure=1
        fi
    fi
    retainer_pid=""
}

remove_temporary_workspace() {
    [[ -n "$temporary_workspace" && -d "$temporary_workspace" ]] || return 0
    find "$temporary_workspace" -depth -type f -delete 2>/dev/null || true
    find "$temporary_workspace" -depth -type d -exec rmdir {} \; 2>/dev/null || true
    temporary_workspace=""
}

cleanup() {
    local original_exit="${1:-$?}"
    (( cleanup_started == 0 )) || return
    cleanup_started=1
    trap - EXIT
    trap '' INT TERM HUP

    # Audio is restored before any potentially slow process shutdown operation.
    restore_audio_output || true
    stop_owned_client || true
    stop_retainer
    remove_temporary_workspace

    if (( cleanup_failure != 0 || process_failure != 0 )); then
        print -u2 -r -- "Cleanup safety failure; original exit status was $original_exit."
        exit 70
    fi
    exit "$original_exit"
}
trap 'cleanup $?' EXIT
trap 'cleanup 130' INT
trap 'cleanup 143' TERM
trap 'cleanup 129' HUP

if (( self_test_readiness == 1 )); then
    readiness_helper="${UMBRA_PERF_SELF_TEST_PID_HELPER:-}"
    readiness_identity="${UMBRA_PERF_SELF_TEST_IDENTITY:-}"
    readiness_attempts="${UMBRA_PERF_SELF_TEST_READINESS_ATTEMPTS:-3}"
    readiness_delay="${UMBRA_PERF_SELF_TEST_READINESS_DELAY:-0.01}"
    [[ -x "$readiness_helper" && -d "${readiness_identity:h}" && "$readiness_attempts" == <-> ]] || exit 2
    capture_audio_state
    mute_audio_output
    bootstrap_status=0
    if "$readiness_helper" capture-bootstrap 123 /fixture/Umbra app.umbra.Umbra > "$readiness_identity"; then
        pid_helper="$readiness_helper"
        client_identity="$readiness_identity"
    else
        bootstrap_status=$?
    fi
    (( bootstrap_status == 0 )) || exit "$bootstrap_status"
    readiness_status=0
    wait_for_identity_readiness \
        "$readiness_helper" \
        "$readiness_identity" \
        "$readiness_attempts" \
        "$readiness_delay" || readiness_status=$?
    (( readiness_status == 0 )) && client_readiness_confirmed=1
    (( readiness_status != 0 && readiness_status != 3 && readiness_status != 8 )) \
        && client_cleanup_block_status="$readiness_status"
    exit "$readiness_status"
fi

if (( self_test_launch == 1 )); then
    launch_helper="${UMBRA_PERF_SELF_TEST_PID_HELPER:-}"
    launch_identity="${UMBRA_PERF_SELF_TEST_IDENTITY:-}"
    launch_app="${UMBRA_PERF_SELF_TEST_APP:-}"
    launch_host="${UMBRA_PERF_SELF_TEST_HOST:-fixture-host}"
    launch_application="${UMBRA_PERF_SELF_TEST_APPLICATION:-Desktop}"
    launch_diagnostics="${launch_identity}.stderr"
    [[ -x "$launch_helper" && -d "${launch_identity:h}" && -n "$launch_app" ]] || exit 2
    capture_audio_state
    mute_audio_output
    self_launch_status=0
    launch_bound_client \
        "$launch_helper" \
        "$launch_app" \
        "$launch_identity" \
        "$launch_diagnostics" \
        "$launch_host" \
        "$launch_application" || self_launch_status=$?
    exit "$self_launch_status"
fi

if [[ -n "$self_test_cleanup" ]]; then
    capture_audio_state
    mute_audio_output
    case "$self_test_cleanup" in
        failure) exit 97 ;;
        success) exit 0 ;;
        signal)
            [[ -n "${UMBRA_PERF_SELF_TEST_READY:-}" ]] || exit 2
            : > "$UMBRA_PERF_SELF_TEST_READY"
            while true; do sleep 1; done
            ;;
        identity)
            temporary_workspace="$(mktemp -d "${TMPDIR:-/tmp}/umbra-identity-test.XXXXXX")"
            pid_helper="$temporary_workspace/pid-helper"
            client_identity="$temporary_workspace/identity.json"
            printf '#!/bin/zsh\nexit 6\n' > "$pid_helper"
            chmod +x "$pid_helper"
            print -r -- 'malformed' > "$client_identity"
            exit 0
            ;;
    esac
fi

[[ -n "$host" ]] || {
    print -u2 -r -- "--host is required."
    exit 2
}
[[ "$duration_seconds" == <-> ]] || {
    print -u2 -r -- "--duration must be an integer."
    exit 2
}
(( duration_seconds >= 5 && duration_seconds <= 60 )) || {
    print -u2 -r -- "--duration must be between 5 and 60 seconds."
    exit 2
}
[[ "$network_kind" == (lan|wifi|vpn|cellular|wan|unknown) ]] || {
    print -u2 -r -- "--network-kind must be lan, wifi, vpn, cellular, wan, or unknown."
    exit 2
}
[[ "$declared_mode" == (latency|quality|unknown) ]] || {
    print -u2 -r -- "--declared-mode must be latency, quality, or unknown."
    exit 2
}
[[ "$client_protocol" == (vanilla-moonlight|umbra-legacy|umbra-v2) ]] || {
    print -u2 -r -- "--client-protocol must be vanilla-moonlight, umbra-legacy, or umbra-v2."
    exit 2
}
[[ -d "$packaged_app" && ! -L "$packaged_app" ]] || {
    print -u2 -r -- "Packaged Umbra app must be a real directory: $packaged_app"
    exit 2
}
client_executable="$packaged_app/Contents/MacOS/Umbra"
[[ -x "$client_executable" && ! -L "$client_executable" ]] || {
    print -u2 -r -- "Umbra executable must be a real executable: $client_executable"
    exit 2
}
[[ "$(plutil -extract CFBundleIdentifier raw "$packaged_app/Contents/Info.plist")" == "app.umbra.Umbra" ]] || {
    print -u2 -r -- "Refusing a package with an unexpected bundle identifier."
    exit 2
}
[[ -z "$lumen_log" || ( -f "$lumen_log" && ! -L "$lumen_log" ) ]] || {
    print -u2 -r -- "Lumen log must be a real file: $lumen_log"
    exit 2
}
[[ -z "$client_telemetry" || ( -f "$client_telemetry" && ! -L "$client_telemetry" ) ]] || {
    print -u2 -r -- "Client telemetry must be a real file: $client_telemetry"
    exit 2
}
[[ ! -L "$output_root" ]] || {
    print -u2 -r -- "Artifact output root must not be a symlink: $output_root"
    exit 2
}

temporary_workspace="$(mktemp -d "${TMPDIR:-/tmp}/umbra-performance.XXXXXX")"
pid_helper="$temporary_workspace/pid-helper"
xcrun swiftc "$script_root/PIDScopedTermination.swift" -o "$pid_helper"
existing_pids="$($pid_helper find-bundle app.umbra.Umbra)"
if [[ -n "$existing_pids" ]]; then
    print -u2 -r -- "Umbra is already running (PID(s): ${existing_pids//$'\n'/, }); refusing to touch another session."
    exit 3
fi

if (( dry_run == 1 )); then
    print -r -- "Safety checks passed. No process launched and no audio setting changed."
    exit 0
fi

run_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
trace_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
artifact_root="$(python3 - "$output_root" "$run_id" <<'PY'
from pathlib import Path
import os
import stat
import sys

root = Path(sys.argv[1]).absolute()
current = Path(root.anchor)
for component in root.parts[1:]:
    current /= component
    if current.exists() and current.is_symlink():
        raise SystemExit(f"artifact path contains symlink: {current}")
root.mkdir(parents=True, mode=0o700, exist_ok=True)
root.chmod(0o700)
run = root / sys.argv[2]
os.mkdir(run, 0o700)
os.mkdir(run / "raw", 0o700)
print(run)
PY
)"
cp "$pid_helper" "$artifact_root/raw/pid-helper"
pid_helper="$artifact_root/raw/pid-helper"
runner_events="$artifact_root/raw/runner-events.jsonl"
support_log_dir="$HOME/Library/Application Support/app.umbra.Umbra/Logs"
first_frame_marker="$artifact_root/raw/first-frame-observed"
lumen_start_size=0
[[ -n "$lumen_log" ]] && lumen_start_size="$(stat -f '%z' "$lumen_log")"

record_runner_event() {
    python3 - "$runner_events" "$1" "$run_id" "$trace_id" "$network_kind" "$declared_mode" "$client_protocol" "$host" <<'PY'
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import sys
import time

path = Path(sys.argv[1])
record = {
    "wall_timestamp": datetime.now(timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z"),
    "monotonic_ns": time.monotonic_ns(),
    "event": sys.argv[2],
    "run_id": sys.argv[3],
    "trace_id": sys.argv[4],
    "matrix": {
        "network_kind": sys.argv[5],
        "optimization_mode": sys.argv[6],
        "client_protocol": sys.argv[7],
        "host": sys.argv[8],
    },
    "clock_domain": "client_monotonic",
    "precision": {"kind": "process_monotonic_clock", "upper_bound_ms": 0.001},
}
descriptor = os.open(path, os.O_APPEND | os.O_CREAT | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
try:
    os.write(descriptor, (json.dumps(record, separators=(",", ":"), sort_keys=True) + "\n").encode())
    os.fsync(descriptor)
finally:
    os.close(descriptor)
PY
}

capture_audio_state
mute_audio_output
record_runner_event "launch_request"
identity_candidate="$artifact_root/raw/client-identity.json"
launch_status=0
launch_bound_client \
    "$pid_helper" \
    "$packaged_app" \
    "$identity_candidate" \
    "$artifact_root/raw/umbra-launch-helper-stderr.txt" \
    "$host" \
    "$application" || launch_status=$?
(( launch_status == 0 )) || {
    print -u2 -r -- "NSWorkspace launch or exact returned-application identity binding failed with status $launch_status."
    exit 4
}

new_support_log=""
identity_status || {
    print -u2 -r -- "Umbra identity failed before support-log discovery."
    exit 4
}
discovery="$(python3 "$script_root/discover_support_log.py" \
    --pid "$client_pid" \
    --root "$support_log_dir" \
    --timeout-ms 5000)" || {
    print -u2 -r -- "Could not bind one support log to the exact launched Umbra PID."
    exit 4
}
identity_status || {
    print -u2 -r -- "Umbra identity changed during support-log discovery."
    exit 4
}
IFS=$'\t' read -r new_support_log support_fd support_device support_inode <<< "$discovery"
[[ -n "$new_support_log" && -n "$support_fd" && -n "$support_device" && -n "$support_inode" ]] || {
    print -u2 -r -- "Support-log discovery returned incomplete identity evidence."
    exit 4
}

retainer_ready="$artifact_root/raw/support-log-retained"
python3 "$script_root/retain_support_log.py" \
    --log "$new_support_log" \
    --snapshot "$artifact_root/raw/umbra-support.log" \
    --binding "$artifact_root/raw/support-log-binding.json" \
    --ready "$retainer_ready" \
    --first-frame-marker "$first_frame_marker" \
    --expected-device "$support_device" \
    --expected-inode "$support_inode" \
    --expected-client-fd "$support_fd" &
retainer_pid=$!

for _ in {1..200}; do
    [[ -f "$retainer_ready" ]] && break
    kill -0 "$retainer_pid" 2>/dev/null || break
    sleep 0.01
done
[[ -f "$retainer_ready" ]] || {
    print -u2 -r -- "Support-log descriptor retention failed."
    exit 4
}
retained_discovery="$(python3 "$script_root/discover_support_log.py" \
    --pid "$client_pid" \
    --root "$support_log_dir" \
    --timeout-ms 500 \
    --expected-fd "$support_fd" \
    --expected-device "$support_device" \
    --expected-inode "$support_inode")" || {
    print -u2 -r -- "The retained support-log FD/inode is no longer open by the bound Umbra PID."
    exit 4
}
[[ "$retained_discovery" == "$discovery" ]] || {
    print -u2 -r -- "Support-log identity changed between discovery and retained-FD verification."
    exit 4
}
identity_status || {
    print -u2 -r -- "Umbra identity changed before retained-FD verification completed."
    exit 4
}

for _ in {1..2000}; do
    [[ -f "$first_frame_marker" ]] && break
    identity_status || break
    kill -0 "$retainer_pid" 2>/dev/null || break
    sleep 0.01
done
[[ -f "$first_frame_marker" ]] || {
    print -u2 -r -- "No first decoded frame was observed within 20 seconds."
    exit 5
}

sleep "$duration_seconds"
record_runner_event "graceful_stop_requested"
restore_audio_output || true
(( audio_restore_pending == 0 )) && record_runner_event "audio_restored"
stop_owned_client || true
(( cleanup_failure == 0 && process_failure == 0 )) || exit 70
record_runner_event "client_exit_confirmed"
sleep 1
record_runner_event "coreaudio_postroll_end"
stop_retainer
(( cleanup_failure == 0 )) || exit 70
[[ -f "$artifact_root/raw/umbra-support.log" ]] || {
    print -u2 -r -- "Retained support-log snapshot is missing."
    exit 70
}

if [[ -n "$lumen_log" ]]; then
    python3 - "$lumen_log" "$lumen_start_size" "$artifact_root/raw/lumen-host.log" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1])
offset = int(sys.argv[2])
destination = Path(sys.argv[3])
data = source.read_bytes()
destination.write_bytes(data[offset:] if len(data) >= offset else data)
PY
fi
[[ -n "$client_telemetry" ]] && cp "$client_telemetry" "$artifact_root/raw/client-telemetry.jsonl"

window_start="$(head -n 1 "$runner_events" | python3 -c 'import json,sys; print(json.load(sys.stdin)["wall_timestamp"])')"
window_end="$(python3 - "$runner_events" <<'PY'
import json,sys
records=[json.loads(line) for line in open(sys.argv[1]) if line.strip()]
print(next(record["wall_timestamp"] for record in records if record["event"] == "client_exit_confirmed"))
PY
)"
coreaudio_window_end="$(tail -n 1 "$runner_events" | python3 -c 'import json,sys; print(json.load(sys.stdin)["wall_timestamp"])')"
log_predicate='(process == "Umbra") OR (process == "coreaudiod") OR (process CONTAINS[c] "SoundSource") OR (eventMessage CONTAINS[c] "app.umbra.Umbra") OR (eventMessage CONTAINS[c] "ClientTimeout") OR (eventMessage CONTAINS[c] "overload") OR (eventMessage CONTAINS[c] "com.rogueamoeba.ARK")'
if /usr/bin/log show \
    --start "$window_start" \
    --end "$coreaudio_window_end" \
    --style ndjson \
    --info \
    --debug \
    --predicate "$log_predicate" \
    > "$artifact_root/raw/coreaudio.log" \
    2> "$artifact_root/raw/coreaudio-log-stderr.txt"; then
    :
else
    /usr/bin/log show \
        --start "$window_start" \
        --end "$coreaudio_window_end" \
        --style json \
        --info \
        --debug \
        --predicate "$log_predicate" \
        > "$artifact_root/raw/coreaudio.log" \
        2>> "$artifact_root/raw/coreaudio-log-stderr.txt" || : > "$artifact_root/raw/coreaudio.log"
fi

parser_arguments=(
    --run-id "$run_id"
    --trace-id "$trace_id"
    --runner-events "$runner_events"
    --umbra-log "$artifact_root/raw/umbra-support.log"
    --coreaudio-log "$artifact_root/raw/coreaudio.log"
    --umbra-pid "$client_pid"
    --window-start "$window_start"
    --window-end "$window_end"
    --coreaudio-window-start "$window_start"
    --coreaudio-window-end "$coreaudio_window_end"
    --output-dir "$artifact_root"
)
[[ -f "$artifact_root/raw/lumen-host.log" ]] && parser_arguments+=(--lumen-log "$artifact_root/raw/lumen-host.log")
[[ -f "$artifact_root/raw/client-telemetry.jsonl" ]] && parser_arguments+=(--client-telemetry "$artifact_root/raw/client-telemetry.jsonl")

set +e
python3 "$script_root/parse_benchmark.py" $parser_arguments
parser_exit=$?
set -e
print -r -- "Artifacts: $artifact_root"
exit "$parser_exit"
