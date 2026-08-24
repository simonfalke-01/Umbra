#!/bin/zsh
set -euo pipefail

repository_root="${0:A:h:h}"
packaged_app="${UMBRA_PACKAGED_APP:-$repository_root/.build/Umbra.app}"
probe_source="$repository_root/Scripts/AudioCompatibility/SilentAudioQueueProbe.c"
expected_identifier="app.umbra.Umbra"
cycle_count="${UMBRA_AUDIO_PROBE_CYCLES:-3}"
cycle_duration="${UMBRA_AUDIO_PROBE_CYCLE_SECONDS:-0.35}"
require_soundsource="${UMBRA_REQUIRE_SOUNDSOURCE:-1}"

[[ -d "$packaged_app" ]] || {
    echo "Packaged Umbra app not found: $packaged_app" >&2
    exit 2
}
[[ -f "$probe_source" ]] || {
    echo "Silent AudioQueue probe source not found: $probe_source" >&2
    exit 2
}

packaged_identifier="$(plutil -extract CFBundleIdentifier raw "$packaged_app/Contents/Info.plist")"
[[ "$packaged_identifier" == "$expected_identifier" ]] || {
    echo "Unexpected packaged Umbra identity: $packaged_identifier" >&2
    exit 2
}

soundsource_processes="$(pgrep -ifl 'SoundSource|Rogue Amoeba|com\.rogueamoeba\.ARK' || true)"
if [[ "$require_soundsource" == "1" && -z "$soundsource_processes" ]]; then
    echo "SoundSource/ARK is not running; compatibility verification would be meaningless." >&2
    exit 3
fi

artifact_stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
artifact_root="${UMBRA_AUDIO_PROBE_ARTIFACTS:-$repository_root/.build/audio-compatibility/$artifact_stamp}"
mkdir -p "$artifact_root"
print -r -- "$soundsource_processes" > "$artifact_root/soundsource-processes.txt"

probe_workspace="$(mktemp -d "${TMPDIR:-/tmp}/umbra-audio-probe.XXXXXX")"
trap 'rm -rf -- "$probe_workspace"' EXIT
probe_app="$probe_workspace/Umbra.app"
mkdir -p "$probe_app/Contents/MacOS"
cp "$packaged_app/Contents/Info.plist" "$probe_app/Contents/Info.plist"

xcrun clang \
    -std=c11 \
    -Wall \
    -Wextra \
    -Werror \
    -framework AudioToolbox \
    -framework CoreAudio \
    -framework CoreFoundation \
    "$probe_source" \
    -o "$probe_app/Contents/MacOS/Umbra"
codesign --force --sign - --identifier "$expected_identifier" "$probe_app" >/dev/null

codesign -d --verbose=4 "$probe_app" 2> "$artifact_root/codesign.txt"
grep -q "Identifier=$expected_identifier" "$artifact_root/codesign.txt" || {
    echo "Probe did not retain Umbra's packaged signing identity." >&2
    exit 4
}

log_start="$(date '+%Y-%m-%d %H:%M:%S')"
"$probe_app/Contents/MacOS/Umbra" "$cycle_count" "$cycle_duration" \
    > "$artifact_root/probe-stdout.txt" \
    2> "$artifact_root/probe-stderr.txt"
sleep 1
log_end="$(date '+%Y-%m-%d %H:%M:%S')"

result_line="$(grep '^RESULT ' "$artifact_root/probe-stdout.txt")"
[[ "$result_line" == *"identity=$expected_identifier"* && "$result_line" == *"status=clean"* ]] || {
    echo "The silent AudioQueue probe did not complete a clean lifecycle." >&2
    cat "$artifact_root/probe-stderr.txt" >&2
    exit 5
}
probe_pid="${${result_line#* pid=}%% *}"

log_predicate='(process == "Umbra") OR (process == "coreaudiod") OR (process CONTAINS[c] "SoundSource") OR (eventMessage CONTAINS[c] "app.umbra.Umbra") OR (eventMessage CONTAINS[c] "ClientTimeout") OR (eventMessage CONTAINS[c] "overload") OR (eventMessage CONTAINS[c] "com.rogueamoeba.ARK")'
if ! /usr/bin/log show \
    --start "$log_start" \
    --end "$log_end" \
    --style compact \
    --info \
    --debug \
    --predicate "$log_predicate" \
    > "$artifact_root/coreaudio.log" \
    2> "$artifact_root/log-stderr.txt"; then
    echo "Could not read unified CoreAudio logs; lifecycle passed but SoundSource correlation is unverified." >&2
    exit 6
fi

count_matches() {
    local pattern="$1"
    local file="$2"
    local count
    count="$(grep -Eic "$pattern" "$file" || true)"
    print -r -- "${count:-0}"
}

ark_mute_count="$(count_matches 'muted by com\.rogueamoeba\.ARK' "$artifact_root/coreaudio.log")"
ark_client_timeout_count="$(count_matches '(ClientTimeout.*(Umbra|app\.umbra\.Umbra|rogueamoeba|ARK))|((Umbra|app\.umbra\.Umbra|rogueamoeba|ARK).*ClientTimeout)' "$artifact_root/coreaudio.log")"
ark_hal_overload_count="$(count_matches '((HAL|IO)[^\n]*overload[^\n]*(Umbra|app\.umbra\.Umbra|rogueamoeba|ARK))|((Umbra|app\.umbra\.Umbra|rogueamoeba|ARK)[^\n]*(HAL|IO)[^\n]*overload)' "$artifact_root/coreaudio.log")"
umbra_pid_timeout_count="$(count_matches "ClientTimeout.*(pid[=: ]*$probe_pid|\\[$probe_pid\\]|:$probe_pid)" "$artifact_root/coreaudio.log")"
ambient_client_timeout_count="$(count_matches 'ClientTimeout' "$artifact_root/coreaudio.log")"
ambient_hal_overload_count="$(count_matches '(HAL|IO)[^\n]*overload|overload[^\n]*(HAL|IO)' "$artifact_root/coreaudio.log")"

cat > "$artifact_root/summary.txt" <<SUMMARY
packaged_identity=$packaged_identifier
probe_pid=$probe_pid
cycles=$cycle_count
cycle_duration_seconds=$cycle_duration
lifecycle=clean
ark_mute_count=$ark_mute_count
soundsource_intercepted=$([[ "$ark_mute_count" -gt 0 ]] && echo yes || echo no)
ark_client_timeout_count=$ark_client_timeout_count
ark_hal_overload_count=$ark_hal_overload_count
umbra_pid_timeout_count=$umbra_pid_timeout_count
ambient_client_timeout_count=$ambient_client_timeout_count
ambient_hal_overload_count=$ambient_hal_overload_count
SUMMARY

correlated_failure_count=$((
    ark_client_timeout_count
    + ark_hal_overload_count
    + umbra_pid_timeout_count
))
if (( ark_mute_count == 0 )); then
    echo "SoundSource was running but did not intercept the packaged-identity probe." >&2
    echo "Artifacts: $artifact_root" >&2
    cat "$artifact_root/summary.txt" >&2
    exit 7
fi
if (( correlated_failure_count > 0 )); then
    echo "SoundSource compatibility probe found $correlated_failure_count Umbra-correlated CoreAudio failure event(s)." >&2
    echo "Artifacts: $artifact_root" >&2
    cat "$artifact_root/summary.txt" >&2
    exit 7
fi

cat "$artifact_root/summary.txt"
echo "SoundSource compatibility verification passed."
echo "Artifacts: $artifact_root"
