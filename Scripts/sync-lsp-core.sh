#!/bin/sh

set -eu

export LC_ALL=C

expected_repository='git@github.com:simonfalke-01/Photon.git'
expected_commit='d353901bb52ff22e2ad88833bdc8ae2bcc8f5423'
expected_digest='fc49b5a1e44fd01379283f865ef6e59fd4c605c58f04ef25b25f41eb625771e4'

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
umbra_root=$(CDPATH='' cd -- "$script_directory/.." && pwd)
default_photon_repository="$umbra_root/../Photon"
photon_repository=${PHOTON_REPOSITORY:-"$default_photon_repository"}
mirror_directory="$umbra_root/Vendor/CLSPCore/src"
mirror_manifest="$umbra_root/Vendor/CLSPCore/source-digest.sha256"
lock_file="$umbra_root/Vendor/CLSPCore/photon.lock"
mode=${1:---check}
temporary_root=

core_files="core/control.h
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
transport/transport.h"

cleanup() {
  if [ -n "$temporary_root" ] && [ -d "$temporary_root" ]; then
    rm -rf -- "$temporary_root"
  fi
}

trap cleanup EXIT
trap 'cleanup; exit 1' HUP INT TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

calculate_digest() {
  directory=$1
  {
    for file in $core_files; do
      printf '%s\n' "$file"
      shasum -a 256 "$directory/$file" | awk '{print $1}'
    done
  } | shasum -a 256 | awk '{print $1}'
}

require_complete_directory() {
  directory=$1
  label=$2
  for file in $core_files; do
    if [ ! -f "$directory/$file" ] || [ -L "$directory/$file" ]; then
      fail "missing or non-regular $label file: $directory/$file"
    fi
  done
}

require_exact_source_set() {
  directory=$1
  label=$2
  actual_files=$(find "$directory/core" "$directory/input_plane" "$directory/media" "$directory/transport" \( -type f -o -type l \) -print \
    | sed "s|^$directory/||" \
    | sort)
  expected_files=$(printf '%s\n' "$core_files" | sort)
  if [ "$actual_files" != "$expected_files" ]; then
    fail "$label source set does not match Photon's pinned manifest"
  fi
}

require_exact_single_line() {
  file=$1
  expected=$2
  label=$3
  if [ ! -f "$file" ] || [ "$(wc -l < "$file" | tr -d ' ')" != 1 ] || [ "$(sed -n '1p' "$file")" != "$expected" ]; then
    fail "$label does not contain the pinned Photon value"
  fi
}

require_exact_content() {
  file=$1
  expected=$2
  label=$3
  if [ ! -f "$file" ] || [ "$(sed -n 'p' "$file")" != "$expected" ]; then
    fail "$label does not match Photon's pinned source set"
  fi
}

verify_lock() {
  if [ ! -f "$lock_file" ]; then
    fail "missing Photon lock file: $lock_file"
  fi
  if [ "$(wc -l < "$lock_file" | tr -d ' ')" != 3 ] \
    || [ "$(sed -n '1p' "$lock_file")" != "repository=$expected_repository" ] \
    || [ "$(sed -n '2p' "$lock_file")" != "commit=$expected_commit" ] \
    || [ "$(sed -n '3p' "$lock_file")" != "digest=$expected_digest" ]; then
    fail "Photon lock file does not match Umbra's pinned repository, commit, and digest"
  fi
}

verify_photon_checkout() {
  checkout=$1
  source_directory="$checkout/src/lsp"
  if [ ! -e "$checkout/.git" ] || [ "$(git -C "$checkout" rev-parse --is-inside-work-tree 2>/dev/null || true)" != true ]; then
    fail "Photon source is not a Git checkout: $checkout"
  fi
  if [ "$(git -C "$checkout" remote get-url origin 2>/dev/null || true)" != "$expected_repository" ]; then
    fail "Photon checkout origin does not match $expected_repository: $checkout"
  fi
  if [ "$(git -C "$checkout" rev-parse HEAD 2>/dev/null || true)" != "$expected_commit" ]; then
    fail "Photon checkout is not at pinned commit $expected_commit: $checkout"
  fi
  require_exact_single_line "$checkout/source-digest.sha256" "$expected_digest" "Photon source digest"
  require_exact_content "$checkout/source-manifest.txt" "$(printf '%s\n' "$core_files")" "Photon source manifest"
  require_complete_directory "$source_directory" "Photon"
  require_exact_source_set "$source_directory" "Photon"
  source_digest=$(calculate_digest "$source_directory")
  if [ "$source_digest" != "$expected_digest" ]; then
    fail "Photon checkout source drift: expected $expected_digest, calculated $source_digest"
  fi
}

verify_mirror() {
  require_complete_directory "$mirror_directory" "Umbra mirror"
  require_exact_source_set "$mirror_directory" "Umbra mirror"
  require_exact_single_line "$mirror_manifest" "$expected_digest" "Umbra source digest"
  mirror_digest=$(calculate_digest "$mirror_directory")
  if [ "$mirror_digest" != "$expected_digest" ]; then
    fail "Umbra Photon mirror drift: expected $expected_digest, calculated $mirror_digest"
  fi
}

verify_lock

case "$mode" in
  --sync)
    if [ -d "$photon_repository" ]; then
      source_checkout=$photon_repository
    else
      temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/umbra-photon-sync.XXXXXX")
      if [ ! -d "$temporary_root" ]; then
        fail "failed to create a temporary Photon checkout directory"
      fi
      source_checkout="$temporary_root/Photon"
      git clone --no-checkout "$expected_repository" "$source_checkout"
      git -C "$source_checkout" checkout --detach "$expected_commit"
    fi
    verify_photon_checkout "$source_checkout"
    source_directory="$source_checkout/src/lsp"
    for file in $core_files; do
      mkdir -p "$(dirname "$mirror_directory/$file")"
      cp "$source_directory/$file" "$mirror_directory/$file"
    done
    printf '%s\n' "$expected_digest" > "$mirror_manifest"
    ;;
  --check)
    ;;
  *)
    printf 'usage: %s [--check|--sync]\n' "$0" >&2
    exit 2
    ;;
esac

verify_mirror

if [ -d "$photon_repository" ]; then
  verify_photon_checkout "$photon_repository"
fi

printf 'Pinned Photon mirror verified: %s at %s\n' "$expected_digest" "$expected_commit"
