#!/bin/zsh
set -euo pipefail

repository_root="${0:A:h:h}"
prefix="${UMBRA_RELEASE_DEPS_PREFIX:-$repository_root/.build/release-deps}"
prefix="${prefix:A}"
deployment_target="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
jobs="${UMBRA_BUILD_JOBS:-$(sysctl -n hw.logicalcpu)}"
apple_clang="$(xcrun --find clang)"
apple_clangxx="$(xcrun --find clang++)"
macos_sdk="$(xcrun --sdk macosx --show-sdk-path)"
# OpenSSL and libtool makefiles cannot quote toolchain paths, so an Xcode bundle
# name with a space (for example "Xcode 27.0.app") is reached through a stable link.
developer_dir="$(xcode-select -p)"
if [[ "$developer_dir" == *" "* ]]; then
    developer_link="$repository_root/.build/xcode-developer"
    mkdir -p "${developer_link:h}"
    ln -sfn "$developer_dir" "$developer_link"
    apple_clang="${apple_clang/#$developer_dir/$developer_link}"
    apple_clangxx="${apple_clangxx/#$developer_dir/$developer_link}"
    macos_sdk="${macos_sdk/#$developer_dir/$developer_link}"
fi
expected_architecture="arm64"
source_date_epoch="0"
zero_ar_date="1"
build_locale="C"
build_timezone="UTC"

openssl_version="3.5.7"
openssl_sha256="a8c0d28a529ca480f9f36cf5792e2cd21984552a3c8e4aa11a24aa31aeac98e8"
openssl_license_sha256="7d5450cb2d142651b8afa315b5f238efc805dad827d91ba367d8516bc9d49e7a"
openssl_configure_target="darwin64-arm64-cc"
openssl_configure_flags="no-shared no-tests"
openssl_cflags="-isysroot $macos_sdk -mmacosx-version-min=$deployment_target"
openssl_ldflags="-isysroot $macos_sdk -mmacosx-version-min=$deployment_target"
opus_version="1.6.1"
opus_sha256="6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1"
opus_license_sha256="01e1167d54a096d123cf6dfbbeb19587278845c6481d2d66d545669846079551"
opus_configure_flags="--disable-shared --enable-static"
opus_cflags="-O2 -isysroot $macos_sdk -mmacosx-version-min=$deployment_target"
opus_ldflags="-isysroot $macos_sdk -mmacosx-version-min=$deployment_target"
manifest_name=".umbra-release-deps.manifest"
manifest_checksum_name="$manifest_name.sha256"

required_content_files=(
    "include/openssl/crypto.h"
    "include/openssl/evp.h"
    "include/openssl/rand.h"
    "include/openssl/ssl.h"
    "include/openssl/x509.h"
    "include/opus/opus.h"
    "lib/libcrypto.a"
    "lib/libopus.a"
    "lib/libssl.a"
    "lib/pkgconfig/libcrypto.pc"
    "lib/pkgconfig/libssl.pc"
    "lib/pkgconfig/openssl.pc"
    "lib/pkgconfig/opus.pc"
)

metadata_keys=(
    "schema"
    "install_prefix"
    "architecture"
    "source_date_epoch"
    "zero_ar_date"
    "build_locale"
    "build_timezone"
    "deployment_target"
    "macos_sdk"
    "c_compiler"
    "cxx_compiler"
    "openssl_version"
    "openssl_source_sha256"
    "openssl_configure_target"
    "openssl_configure_flags"
    "openssl_cflags"
    "openssl_ldflags"
    "opus_version"
    "opus_source_sha256"
    "opus_configure_flags"
    "opus_cflags"
    "opus_ldflags"
)

log() {
    print -u2 -r -- "$*"
}

fail() {
    log "$*"
    return 1
}

sha256_file() {
    shasum -a 256 "$1" | awk '{print $1}'
}

content_manifest_key() {
    local key="${1//\//_}"
    key="${key//./_}"
    print -r -- "content_${key}_sha256"
}

manifest_value() {
    local manifest="$1"
    local key="$2"
    awk -v key="$key" '
        index($0, "=") > 0 && substr($0, 1, index($0, "=") - 1) == key {
            print substr($0, index($0, "=") + 1)
        }
    ' "$manifest"
}

require_manifest_value() {
    local manifest="$1"
    local key="$2"
    local expected="$3"
    local count
    local actual
    count="$(awk -v key="$key" '
        index($0, "=") > 0 && substr($0, 1, index($0, "=") - 1) == key {
            count++
        }
        END { print count + 0 }
    ' "$manifest")"
    [[ "$count" == "1" ]] || return 1
    actual="$(manifest_value "$manifest" "$key")"
    [[ "$actual" == "$expected" ]]
}

archive_has_symbol() {
    local archive="$1"
    local required_symbol="$2"
    nm -g "$archive" 2>/dev/null \
        | awk -v required="$required_symbol" \
            '$3 == required { found = 1 } END { exit(found ? 0 : 1) }'
}

validate_archive() {
    local archive="$1"
    local members
    [[ -s "$archive" ]] || return 1
    [[ "$(file -b "$archive")" == *"current ar archive"* ]] || return 1
    [[ "$(lipo -archs "$archive" 2>/dev/null)" == "$expected_architecture" ]] || return 1
    members="$(ar -t "$archive" 2>/dev/null)"
    [[ -n "$members" && "$members" == *".o"* ]] || return 1
}

validate_archives_and_symbols() {
    local candidate="$1"
    validate_archive "$candidate/lib/libssl.a" || return 1
    validate_archive "$candidate/lib/libcrypto.a" || return 1
    validate_archive "$candidate/lib/libopus.a" || return 1
    archive_has_symbol "$candidate/lib/libssl.a" "_SSL_export_keying_material" || return 1
    archive_has_symbol "$candidate/lib/libssl.a" "_SSL_new" || return 1
    archive_has_symbol "$candidate/lib/libcrypto.a" "_EVP_Digest" || return 1
    archive_has_symbol "$candidate/lib/libcrypto.a" "_RAND_bytes" || return 1
    archive_has_symbol "$candidate/lib/libopus.a" "_opus_decoder_create" || return 1
    archive_has_symbol "$candidate/lib/libopus.a" "_opus_multistream_decoder_create" || return 1
}

validate_no_dynamic_libraries() {
    local candidate="$1"
    local dynamic_library
    dynamic_library="$(find "$candidate" \
        \( -type f -o -type l \) \
        \( -name '*.dylib' -o -name '*.so' -o -name '*.dll' \) \
        -print -quit)"
    [[ -z "$dynamic_library" ]]
}

validate_manifest() {
    local candidate="$1"
    local manifest="$candidate/$manifest_name"
    local checksum_file="$candidate/$manifest_checksum_name"
    local expected_line_count
    local expected_checksum
    local relative
    local key

    [[ -f "$manifest" && -f "$checksum_file" ]] || return 1
    expected_checksum="$(tr -d '[:space:]' < "$checksum_file")"
    [[ "$expected_checksum" == "$(sha256_file "$manifest")" ]] || return 1
    expected_line_count=$(( ${#metadata_keys[@]} + ${#required_content_files[@]} ))
    [[ "$(wc -l < "$manifest" | tr -d '[:space:]')" == "$expected_line_count" ]] || return 1

    require_manifest_value "$manifest" "schema" "1" || return 1
    require_manifest_value "$manifest" "install_prefix" "$prefix" || return 1
    require_manifest_value "$manifest" "architecture" "$expected_architecture" || return 1
    require_manifest_value "$manifest" "source_date_epoch" "$source_date_epoch" || return 1
    require_manifest_value "$manifest" "zero_ar_date" "$zero_ar_date" || return 1
    require_manifest_value "$manifest" "build_locale" "$build_locale" || return 1
    require_manifest_value "$manifest" "build_timezone" "$build_timezone" || return 1
    require_manifest_value "$manifest" "deployment_target" "$deployment_target" || return 1
    require_manifest_value "$manifest" "macos_sdk" "$macos_sdk" || return 1
    require_manifest_value "$manifest" "c_compiler" "$apple_clang" || return 1
    require_manifest_value "$manifest" "cxx_compiler" "$apple_clangxx" || return 1
    require_manifest_value "$manifest" "openssl_version" "$openssl_version" || return 1
    require_manifest_value "$manifest" "openssl_source_sha256" "$openssl_sha256" || return 1
    require_manifest_value "$manifest" "openssl_configure_target" "$openssl_configure_target" || return 1
    require_manifest_value "$manifest" "openssl_configure_flags" "$openssl_configure_flags" || return 1
    require_manifest_value "$manifest" "openssl_cflags" "$openssl_cflags" || return 1
    require_manifest_value "$manifest" "openssl_ldflags" "$openssl_ldflags" || return 1
    require_manifest_value "$manifest" "opus_version" "$opus_version" || return 1
    require_manifest_value "$manifest" "opus_source_sha256" "$opus_sha256" || return 1
    require_manifest_value "$manifest" "opus_configure_flags" "$opus_configure_flags" || return 1
    require_manifest_value "$manifest" "opus_cflags" "$opus_cflags" || return 1
    require_manifest_value "$manifest" "opus_ldflags" "$opus_ldflags" || return 1

    for relative in "${required_content_files[@]}"; do
        [[ -f "$candidate/$relative" ]] || return 1
        key="$(content_manifest_key "$relative")"
        require_manifest_value \
            "$manifest" \
            "$key" \
            "$(sha256_file "$candidate/$relative")" || return 1
    done
}

validate_prefix() {
    local candidate="$1"
    [[ -d "$candidate" ]] || return 1
    validate_no_dynamic_libraries "$candidate" || return 1
    validate_archives_and_symbols "$candidate" || return 1
    validate_manifest "$candidate" || return 1
}

write_manifest() {
    local candidate="$1"
    local manifest="$candidate/$manifest_name"
    local checksum_file="$candidate/$manifest_checksum_name"
    local relative
    local key
    {
        print -r -- "schema=1"
        print -r -- "install_prefix=$prefix"
        print -r -- "architecture=$expected_architecture"
        print -r -- "source_date_epoch=$source_date_epoch"
        print -r -- "zero_ar_date=$zero_ar_date"
        print -r -- "build_locale=$build_locale"
        print -r -- "build_timezone=$build_timezone"
        print -r -- "deployment_target=$deployment_target"
        print -r -- "macos_sdk=$macos_sdk"
        print -r -- "c_compiler=$apple_clang"
        print -r -- "cxx_compiler=$apple_clangxx"
        print -r -- "openssl_version=$openssl_version"
        print -r -- "openssl_source_sha256=$openssl_sha256"
        print -r -- "openssl_configure_target=$openssl_configure_target"
        print -r -- "openssl_configure_flags=$openssl_configure_flags"
        print -r -- "openssl_cflags=$openssl_cflags"
        print -r -- "openssl_ldflags=$openssl_ldflags"
        print -r -- "opus_version=$opus_version"
        print -r -- "opus_source_sha256=$opus_sha256"
        print -r -- "opus_configure_flags=$opus_configure_flags"
        print -r -- "opus_cflags=$opus_cflags"
        print -r -- "opus_ldflags=$opus_ldflags"
        for relative in "${required_content_files[@]}"; do
            key="$(content_manifest_key "$relative")"
            print -r -- "$key=$(sha256_file "$candidate/$relative")"
        done
    } > "$manifest"
    sha256_file "$manifest" > "$checksum_file"
}

validate_prefix_target() {
    [[ -n "$prefix" ]] || fail "Release dependency prefix is empty."
    case "$prefix" in
        /|"$repository_root"|"$repository_root/.build"|"${repository_root:h}")
            fail "Refusing unsafe release dependency prefix: $prefix"
            ;;
    esac
}

verify_archive() {
    local archive="$1"
    local expected="$2"
    local actual
    actual="$(sha256_file "$archive")"
    [[ "$actual" == "$expected" ]] || {
        log "Checksum mismatch for $archive"
        exit 1
    }
}

validate_prefix_target
[[ "$(sha256_file "$repository_root/OPENSSL_LICENSE.txt")" == "$openssl_license_sha256" ]] || {
    fail "OPENSSL_LICENSE.txt does not match the pinned OpenSSL $openssl_version source release."
    exit 1
}
[[ "$(sha256_file "$repository_root/OPUS_LICENSE.txt")" == "$opus_license_sha256" ]] || {
    fail "OPUS_LICENSE.txt does not match the pinned Opus $opus_version source release."
    exit 1
}
if [[ "${UMBRA_RELEASE_DEPS_FORCE_REBUILD:-0}" != "1" ]] && validate_prefix "$prefix"; then
    print -r -- "$prefix"
    exit 0
fi

log "Rebuilding locked Umbra release dependencies at $prefix"
export SOURCE_DATE_EPOCH="$source_date_epoch"
export ZERO_AR_DATE="$zero_ar_date"
export LC_ALL="$build_locale"
export TZ="$build_timezone"

task_temp="$(mktemp -d "${TMPDIR:-/tmp}/umbra-deps.XXXXXX")"
trap 'rm -rf "$task_temp"' EXIT
install_root="$task_temp/install-root"
staged_prefix="$install_root$prefix"
mkdir -p "$install_root"

openssl_archive="$task_temp/openssl-$openssl_version.tar.gz"
curl --fail --location --retry 3 \
    "https://github.com/openssl/openssl/releases/download/openssl-$openssl_version/openssl-$openssl_version.tar.gz" \
    --output "$openssl_archive"
verify_archive "$openssl_archive" "$openssl_sha256"
tar -xzf "$openssl_archive" -C "$task_temp"
(
    cd "$task_temp/openssl-$openssl_version"
    export MACOSX_DEPLOYMENT_TARGET="$deployment_target"
    export SDKROOT="$macos_sdk"
    export CC="$apple_clang"
    export CXX="$apple_clangxx"
    export CFLAGS="$openssl_cflags"
    export LDFLAGS="$openssl_ldflags"
    ./Configure \
        "$openssl_configure_target" \
        no-shared \
        no-tests \
        --prefix="$prefix"
    make -j"$jobs" build_libs
    make install_dev DESTDIR="$install_root"
) >&2

opus_archive="$task_temp/opus-$opus_version.tar.gz"
curl --fail --location --retry 3 \
    "https://downloads.xiph.org/releases/opus/opus-$opus_version.tar.gz" \
    --output "$opus_archive"
verify_archive "$opus_archive" "$opus_sha256"
tar -xzf "$opus_archive" -C "$task_temp"
(
    cd "$task_temp/opus-$opus_version"
    export MACOSX_DEPLOYMENT_TARGET="$deployment_target"
    export SDKROOT="$macos_sdk"
    export CC="$apple_clang"
    export CXX="$apple_clangxx"
    ./configure \
        --prefix="$prefix" \
        --disable-shared \
        --enable-static \
        CFLAGS="$opus_cflags" \
        LDFLAGS="$opus_ldflags"
    make -j"$jobs"
    make install DESTDIR="$install_root"
) >&2

write_manifest "$staged_prefix"
validate_prefix "$staged_prefix" || {
    log "Newly built release dependencies failed locked validation."
    exit 1
}

mkdir -p "${prefix:h}"
previous_prefix="$task_temp/previous-prefix"
if [[ -e "$prefix" ]]; then
    mv "$prefix" "$previous_prefix"
fi
if ! mv "$staged_prefix" "$prefix"; then
    if [[ -e "$previous_prefix" ]]; then
        mv "$previous_prefix" "$prefix"
    fi
    log "Failed to install rebuilt release dependencies."
    exit 1
fi
validate_prefix "$prefix" || {
    failed_prefix="$task_temp/failed-prefix"
    mv "$prefix" "$failed_prefix"
    if [[ -e "$previous_prefix" ]]; then
        mv "$previous_prefix" "$prefix"
    fi
    log "Installed release dependencies failed locked validation."
    exit 1
}

print -r -- "$prefix"
