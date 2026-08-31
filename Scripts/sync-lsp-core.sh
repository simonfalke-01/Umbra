#!/bin/sh

set -eu

export LC_ALL=C

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
umbra_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
lumen_root=${UMBRA_LUMEN_REPOSITORY:-"$umbra_root/../Lumen"}
source_directory="$lumen_root/src/protocol_lsp"
mirror_directory="$umbra_root/Vendor/CLSPCore/src"
mirror_manifest="$umbra_root/Vendor/CLSPCore/source-digest.sha256"
mode=${1:---check}

core_files="
core/control.h
core/core.h
core/input.h
core/packet.h
core/rtp.h
core/telemetry.h
core/transport.h
core/wire.h
input_plane/feedback.h
input_plane/input_plane.h
input_plane/rate.h
input_plane/state.h
input_plane/wire.h
media/audio.h
media/av1.h
media/common.h
media/frame_pipeline.h
media/h264.h
media/hevc.h
media/media.h
transport/congestion.h
transport/generation_fence.h
transport/repair.h
transport/rtcp.h
transport/transport.h
"

calculate_digest() {
  directory=$1
  {
    for file in $core_files; do
      printf '%s\n' "$file"
      shasum -a 256 "$directory/$file" | awk '{print $1}'
    done
  } | shasum -a 256 | awk '{print $1}'
}

read_digest() {
  awk 'NR == 1 { print $1 }' "$1"
}

require_complete_directory() {
  directory=$1
  for file in $core_files; do
    if [ ! -f "$directory/$file" ]; then
      printf 'missing LSP core file: %s/%s\n' "$directory" "$file" >&2
      exit 1
    fi
  done
}

case "$mode" in
  --sync)
    require_complete_directory "$source_directory"
    source_digest=$(calculate_digest "$source_directory")
    for file in $core_files; do
      mkdir -p "$(dirname "$mirror_directory/$file")"
      cp "$source_directory/$file" "$mirror_directory/$file"
    done
    printf '%s\n' "$source_digest" > "$mirror_manifest"
    ;;
  --check)
    require_complete_directory "$mirror_directory"
    ;;
  *)
    printf 'usage: %s [--check|--sync]\n' "$0" >&2
    exit 2
    ;;
esac

if [ ! -f "$mirror_manifest" ]; then
  printf 'missing Umbra LSP core digest manifest: %s\n' "$mirror_manifest" >&2
  exit 1
fi

expected_digest=$(read_digest "$mirror_manifest")
mirror_digest=$(calculate_digest "$mirror_directory")
if [ "$mirror_digest" != "$expected_digest" ]; then
  printf 'Umbra LSP core mirror drift: expected %s, calculated %s\n' "$expected_digest" "$mirror_digest" >&2
  exit 1
fi

if [ -d "$source_directory" ]; then
  require_complete_directory "$source_directory"
  source_digest=$(calculate_digest "$source_directory")
  if [ "$source_digest" != "$mirror_digest" ]; then
    printf 'LSP core repositories differ: Lumen %s, Umbra %s\n' "$source_digest" "$mirror_digest" >&2
    exit 1
  fi
fi

printf 'LSP core mirror verified: %s\n' "$mirror_digest"
