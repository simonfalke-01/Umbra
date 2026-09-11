#!/bin/zsh
set -euo pipefail

repository_root="${0:A:h:h}"
prefix="${UMBRA_LSP_DEPS_PREFIX:-${UMBRA_RELEASE_DEPS_PREFIX:-$repository_root/.build/release-deps}}"
prefix="${prefix:A}"
deployment_target="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
jobs="${UMBRA_BUILD_JOBS:-$(sysctl -n hw.logicalcpu)}"
expected_architecture="arm64"
apple_clang="$(xcrun --find clang)"
macos_sdk="$(xcrun --sdk macosx --show-sdk-path)"
wolfssl_version="5.9.2"
wolfssl_sha256="2f4ef3d4fd387a9b3191d36a6316d69116c46ff69bb9583b6c82b36d7b8ca114"
libsrtp_version="2.8.0"
libsrtp_sha256="d123dcff5c56d4f1a9006f2b311ea99a85016cbf3bb24b1007885d422237db85"
manifest_name=".umbra-lsp-deps.manifest"
manifest_checksum_name="$manifest_name.sha256"
wolfssl_compile_definitions="-DHAVE_SCRYPT -DWOLFSSL_PUBLIC_MP -DWOLFSSL_PUBLIC_ECC_ADD_DBL -DWOLFSSL_ECC_GEN_REJECT_SAMPLING -DWOLFSSL_SP_MATH_ALL"

# Keep this cryptographic profile source-identical in intent with
# Lumen/cmake/dependencies/lsp_security.cmake. Installation is intentionally
# controlled separately because Umbra consumes a staged static prefix.
wolfssl_profile=(
    "WOLFSSL_DTLS=yes"
    "WOLFSSL_TLS13=yes"
    "WOLFSSL_DTLS13=yes"
    "WOLFSSL_TLSV12=no"
    "WOLFSSL_OLD_TLS=no"
    "WOLFSSL_HRR_COOKIE=yes"
    "WOLFSSL_DTLS_CH_FRAG=yes"
    "WOLFSSL_SRTP=yes"
    "WOLFSSL_KEYING_MATERIAL=yes"
    "WOLFSSL_ALPN=yes"
    "WOLFSSL_CURVE25519=yes"
    "WOLFSSL_ED25519=yes"
    "WOLFSSL_AESGCM=yes"
    "WOLFSSL_HKDF=yes"
    "WOLFSSL_PWDBASED=yes"
    "WOLFSSL_PUBLIC_MP=yes"
    "WOLFSSL_HARDEN=yes"
    "WOLFSSL_ECC=yes"
    "WOLFSSL_SP_MATH_ALL=yes"
    "WOLFSSL_KEYGEN=yes"
    "WOLFSSL_CERTGEN=yes"
    "WOLFSSL_CERTEXT=yes"
    "WOLFSSL_OPENSSLEXTRA=yes"
    "WOLFSSL_SESSION_TICKET=no"
    "WOLFSSL_SYS_CA_CERTS=no"
    "WOLFSSL_MLKEM=no"
    "WOLFSSL_PQC_HYBRIDS=no"
)
wolfssl_profile_value="${(j:;:)wolfssl_profile}"
libsrtp_profile=(
    "BUILD_SHARED_LIBS=OFF"
    "ENABLE_OPENSSL=OFF"
    "ENABLE_MBEDTLS=OFF"
    "ENABLE_NSS=OFF"
    "ENABLE_WOLFSSL=ON"
    "LIBSRTP_TEST_APPS=OFF"
)
libsrtp_profile_value="${(j:;:)libsrtp_profile}"

required_content_files=(
    "include/srtp2/srtp.h"
    "include/wolfssl/lsp_spake2_settings.h"
    "include/wolfssl/options.h"
    "include/wolfssl/ssl.h"
    "include/wolfssl/wolfcrypt/aes.h"
    "lib/libsrtp2.a"
    "lib/libwolfssl.a"
)

metadata_keys=(
    "schema"
    "install_prefix"
    "architecture"
    "deployment_target"
    "macos_sdk"
    "c_compiler"
    "wolfssl_version"
    "wolfssl_source_sha256"
    "wolfssl_profile"
    "wolfssl_compile_definitions"
    "wolfssl_spake2"
    "libsrtp_version"
    "libsrtp_source_sha256"
    "libsrtp_crypto"
    "libsrtp_profile"
)

sha256_file() {
    shasum -a 256 "$1" | awk '{print $1}'
}

archive_has_symbol() {
    nm -g "$1" 2>/dev/null | awk -v required="$2" '$3 == required { found = 1 } END { exit(found ? 0 : 1) }'
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
    count="$(awk -v key="$key" '
        index($0, "=") > 0 && substr($0, 1, index($0, "=") - 1) == key {
            count++
        }
        END { print count + 0 }
    ' "$manifest")"
    [[ "$count" == "1" ]] || return 1
    [[ "$(manifest_value "$manifest" "$key")" == "$expected" ]]
}

header_defines() {
    grep -Eq "^#define[[:space:]]+$2([[:space:]]|$)" "$1"
}

validate_header_profile() {
    local candidate="$1"
    local options="$candidate/include/wolfssl/options.h"
    local spake2="$candidate/include/wolfssl/lsp_spake2_settings.h"
    local required_macro
    for required_macro in \
        HAVE_AESGCM \
        HAVE_ALPN \
        HAVE_CURVE25519 \
        HAVE_ECC \
        HAVE_ED25519 \
        HAVE_HKDF \
        HAVE_KEYING_MATERIAL \
        NO_OLD_TLS \
        WOLFSSL_CERT_EXT \
        WOLFSSL_CERT_GEN \
        WOLFSSL_DTLS \
        WOLFSSL_DTLS13 \
        WOLFSSL_DTLS_CH_FRAG \
        WOLFSSL_KEY_GEN \
        WOLFSSL_NO_TLS12 \
        WOLFSSL_SEND_HRR_COOKIE \
        WOLFSSL_SRTP \
        WOLFSSL_TLS13; do
        header_defines "$options" "$required_macro" || return 1
    done
    for required_macro in \
        HAVE_SCRYPT \
        WOLFSSL_PUBLIC_MP \
        WOLFSSL_PUBLIC_ECC_ADD_DBL \
        WOLFSSL_ECC_GEN_REJECT_SAMPLING \
        WOLFSSL_SP_MATH_ALL; do
        header_defines "$spake2" "$required_macro" || return 1
    done
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
    validate_archive "$candidate/lib/libwolfssl.a" || return 1
    validate_archive "$candidate/lib/libsrtp2.a" || return 1
    archive_has_symbol "$candidate/lib/libwolfssl.a" "_wolfDTLSv1_3_client_method" || return 1
    archive_has_symbol "$candidate/lib/libwolfssl.a" "_wolfSSL_export_dtls_srtp_keying_material" || return 1
    archive_has_symbol "$candidate/lib/libwolfssl.a" "_wc_scrypt_ex" || return 1
    archive_has_symbol "$candidate/lib/libwolfssl.a" "_wc_ecc_mulmod_ex2" || return 1
    archive_has_symbol "$candidate/lib/libwolfssl.a" "_ecc_projective_add_point_safe" || return 1
    archive_has_symbol "$candidate/lib/libsrtp2.a" "_srtp_create" || return 1
    ar -t "$candidate/lib/libsrtp2.a" | grep -q "aes_gcm_wolfssl" || return 1
    ar -t "$candidate/lib/libsrtp2.a" | grep -q "aes_icm_wolfssl" || return 1
}

validate_no_dynamic_lsp_libraries() {
    local candidate="$1"
    local dynamic_library
    dynamic_library="$(find "$candidate" \
        \( -type f -o -type l \) \
        \( -name 'libwolfssl*.dylib' \
            -o -name 'libwolfssl.so*' \
            -o -name 'libsrtp2*.dylib' \
            -o -name 'libsrtp2.so*' \) \
        -print -quit 2>/dev/null)"
    [[ -z "$dynamic_library" ]]
}

validate_manifest() {
    local candidate="$1"
    local manifest="$candidate/$manifest_name"
    local checksum_file="$candidate/$manifest_checksum_name"
    local expected_checksum
    local expected_line_count
    local relative
    local key

    [[ -f "$manifest" && -f "$checksum_file" ]] || return 1
    expected_checksum="$(tr -d '[:space:]' < "$checksum_file")"
    [[ "$expected_checksum" == "$(sha256_file "$manifest")" ]] || return 1
    expected_line_count=$(( ${#metadata_keys[@]} + ${#required_content_files[@]} ))
    [[ "$(wc -l < "$manifest" | tr -d '[:space:]')" == "$expected_line_count" ]] || return 1

    require_manifest_value "$manifest" "schema" "3" || return 1
    require_manifest_value "$manifest" "install_prefix" "$prefix" || return 1
    require_manifest_value "$manifest" "architecture" "$expected_architecture" || return 1
    require_manifest_value "$manifest" "deployment_target" "$deployment_target" || return 1
    require_manifest_value "$manifest" "macos_sdk" "$macos_sdk" || return 1
    require_manifest_value "$manifest" "c_compiler" "$apple_clang" || return 1
    require_manifest_value "$manifest" "wolfssl_version" "$wolfssl_version" || return 1
    require_manifest_value "$manifest" "wolfssl_source_sha256" "$wolfssl_sha256" || return 1
    require_manifest_value "$manifest" "wolfssl_profile" "$wolfssl_profile_value" || return 1
    require_manifest_value "$manifest" "wolfssl_compile_definitions" "$wolfssl_compile_definitions" || return 1
    require_manifest_value "$manifest" "wolfssl_spake2" "RFC9382-P256-SHA256-HKDF-HMAC" || return 1
    require_manifest_value "$manifest" "libsrtp_version" "$libsrtp_version" || return 1
    require_manifest_value "$manifest" "libsrtp_source_sha256" "$libsrtp_sha256" || return 1
    require_manifest_value "$manifest" "libsrtp_crypto" "wolfcrypt" || return 1
    require_manifest_value "$manifest" "libsrtp_profile" "$libsrtp_profile_value" || return 1

    for relative in "${required_content_files[@]}"; do
        [[ -f "$candidate/$relative" && ! -L "$candidate/$relative" ]] || return 1
        key="$(content_manifest_key "$relative")"
        require_manifest_value \
            "$manifest" \
            "$key" \
            "$(sha256_file "$candidate/$relative")" || return 1
    done
}

validate_prefix() {
    local candidate="${1:-$prefix}"
    [[ -d "$candidate" ]] || return 1
    validate_no_dynamic_lsp_libraries "$candidate" || return 1
    validate_header_profile "$candidate" || return 1
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
        print -r -- "schema=3"
        print -r -- "install_prefix=$prefix"
        print -r -- "architecture=$expected_architecture"
        print -r -- "deployment_target=$deployment_target"
        print -r -- "macos_sdk=$macos_sdk"
        print -r -- "c_compiler=$apple_clang"
        print -r -- "wolfssl_version=$wolfssl_version"
        print -r -- "wolfssl_source_sha256=$wolfssl_sha256"
        print -r -- "wolfssl_profile=$wolfssl_profile_value"
        print -r -- "wolfssl_compile_definitions=$wolfssl_compile_definitions"
        print -r -- "wolfssl_spake2=RFC9382-P256-SHA256-HKDF-HMAC"
        print -r -- "libsrtp_version=$libsrtp_version"
        print -r -- "libsrtp_source_sha256=$libsrtp_sha256"
        print -r -- "libsrtp_crypto=wolfcrypt"
        print -r -- "libsrtp_profile=$libsrtp_profile_value"
        for relative in "${required_content_files[@]}"; do
            key="$(content_manifest_key "$relative")"
            print -r -- "$key=$(sha256_file "$candidate/$relative")"
        done
    } > "$manifest"
    sha256_file "$manifest" > "$checksum_file"
}

case "$prefix" in
    /|"$repository_root"|"$repository_root/.build"|"${repository_root:h}")
        print -u2 -- "Refusing unsafe LSP dependency prefix: $prefix"
        exit 1
        ;;
esac

if [[ "${UMBRA_LSP_DEPS_FORCE_REBUILD:-0}" != "1" ]] && validate_prefix; then
    print -r -- "$prefix"
    exit 0
fi

task_temp="$(mktemp -d "${TMPDIR:-/tmp}/umbra-lsp-deps.XXXXXX")"
trap 'rm -rf "$task_temp"' EXIT
staged_prefix="$task_temp/staged-prefix"
mkdir -p "$staged_prefix/lib"
if [[ -d "$prefix" ]]; then
    cp -R "$prefix/." "$staged_prefix"
fi
rm -rf \
    "$staged_prefix/include/srtp2" \
    "$staged_prefix/include/wolfssl"
rm -f \
    "$staged_prefix/lib/libsrtp2.a" \
    "$staged_prefix/lib/libwolfssl.a" \
    "$staged_prefix/lib/pkgconfig/libsrtp2.pc" \
    "$staged_prefix/lib/pkgconfig/wolfssl.pc" \
    "$staged_prefix/$manifest_name" \
    "$staged_prefix/$manifest_checksum_name"
find "$staged_prefix" \
    \( -type f -o -type l \) \
    \( -name 'libwolfssl*.dylib' \
        -o -name 'libwolfssl.so*' \
        -o -name 'libsrtp2*.dylib' \
        -o -name 'libsrtp2.so*' \) \
    -delete

wolfssl_archive="$task_temp/wolfssl.tar.gz"
libsrtp_archive="$task_temp/libsrtp.tar.gz"
curl --fail --location --retry 3 \
    "https://github.com/wolfSSL/wolfssl/archive/refs/tags/v$wolfssl_version-stable.tar.gz" \
    --output "$wolfssl_archive"
curl --fail --location --retry 3 \
    "https://github.com/cisco/libsrtp/archive/refs/tags/v$libsrtp_version.tar.gz" \
    --output "$libsrtp_archive"
[[ "$(sha256_file "$wolfssl_archive")" == "$wolfssl_sha256" ]]
[[ "$(sha256_file "$libsrtp_archive")" == "$libsrtp_sha256" ]]
tar -xzf "$wolfssl_archive" -C "$task_temp"
tar -xzf "$libsrtp_archive" -C "$task_temp"

cmake -S "$task_temp/wolfssl-$wolfssl_version-stable" -B "$task_temp/wolfssl-build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$staged_prefix" \
    -DCMAKE_C_COMPILER="$apple_clang" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$deployment_target" \
    -DCMAKE_OSX_SYSROOT="$macos_sdk" \
    -DBUILD_SHARED_LIBS=OFF \
    -DWOLFSSL_EXAMPLES=OFF \
    -DWOLFSSL_CRYPT_TESTS=OFF \
    "${(@)wolfssl_profile/#/-D}" \
    -DCMAKE_C_FLAGS="$wolfssl_compile_definitions"
cmake --build "$task_temp/wolfssl-build" --parallel "$jobs"
cmake --install "$task_temp/wolfssl-build"

spake2_settings="$staged_prefix/include/wolfssl/lsp_spake2_settings.h"
{
    print -r -- "#pragma once"
    print -r -- "#include <wolfssl/options.h>"
    print -r -- "#ifndef HAVE_SCRYPT"
    print -r -- "#define HAVE_SCRYPT"
    print -r -- "#endif"
    print -r -- "#ifndef WOLFSSL_PUBLIC_MP"
    print -r -- "#define WOLFSSL_PUBLIC_MP"
    print -r -- "#endif"
    print -r -- "#ifndef WOLFSSL_PUBLIC_ECC_ADD_DBL"
    print -r -- "#define WOLFSSL_PUBLIC_ECC_ADD_DBL"
    print -r -- "#endif"
    print -r -- "#ifndef WOLFSSL_ECC_GEN_REJECT_SAMPLING"
    print -r -- "#define WOLFSSL_ECC_GEN_REJECT_SAMPLING"
    print -r -- "#endif"
    print -r -- "#ifndef WOLFSSL_SP_MATH_ALL"
    print -r -- "#define WOLFSSL_SP_MATH_ALL"
    print -r -- "#endif"
} > "$spake2_settings"

libsrtp_source="$task_temp/libsrtp-$libsrtp_version"
cp "$repository_root/Vendor/CLibSRTP/Patches/aes_gcm_wolfssl.c" "$libsrtp_source/crypto/cipher/aes_gcm_wolfssl.c"
cp "$repository_root/Vendor/CLibSRTP/Patches/aes_icm_wolfssl.c" "$libsrtp_source/crypto/cipher/aes_icm_wolfssl.c"
patch -d "$libsrtp_source" -p1 < "$repository_root/Vendor/CLibSRTP/Patches/libsrtp-2.8.0-wolfssl.patch"
cmake -S "$libsrtp_source" -B "$task_temp/libsrtp-build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$staged_prefix" \
    -DCMAKE_PREFIX_PATH="$staged_prefix" \
    -DCMAKE_C_COMPILER="$apple_clang" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$deployment_target" \
    -DCMAKE_OSX_SYSROOT="$macos_sdk" \
    "${(@)libsrtp_profile/#/-D}"
cmake --build "$task_temp/libsrtp-build" --parallel "$jobs"
cmake --install "$task_temp/libsrtp-build"

write_manifest "$staged_prefix"
validate_prefix "$staged_prefix" || {
    print -u2 -- "Newly built LSP dependencies failed locked validation."
    exit 1
}

old_prefix="$task_temp/old-prefix"
mkdir -p "${prefix:h}"
if [[ -e "$prefix" ]]; then
    mv "$prefix" "$old_prefix"
fi
if ! mv "$staged_prefix" "$prefix" || ! validate_prefix "$prefix"; then
    rm -rf "$prefix"
    if [[ -e "$old_prefix" ]]; then
        mv "$old_prefix" "$prefix"
    fi
    print -u2 -- "Pinned LSP dependency installation failed validation."
    exit 1
fi
print -r -- "$prefix"
