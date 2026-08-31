#!/bin/zsh
set -euo pipefail

repository_root="${0:A:h:h}"
prefix="${UMBRA_LSP_DEPS_PREFIX:-${UMBRA_RELEASE_DEPS_PREFIX:-$repository_root/.build/release-deps}}"
prefix="${prefix:A}"
deployment_target="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
jobs="${UMBRA_BUILD_JOBS:-$(sysctl -n hw.logicalcpu)}"
wolfssl_version="5.9.2"
wolfssl_sha256="2f4ef3d4fd387a9b3191d36a6316d69116c46ff69bb9583b6c82b36d7b8ca114"
libsrtp_version="2.8.0"
libsrtp_sha256="d123dcff5c56d4f1a9006f2b311ea99a85016cbf3bb24b1007885d422237db85"
manifest="$prefix/.umbra-lsp-deps.manifest"

sha256_file() {
    shasum -a 256 "$1" | awk '{print $1}'
}

archive_has_symbol() {
    nm -g "$1" 2>/dev/null | awk -v required="$2" '$3 == required { found = 1 } END { exit(found ? 0 : 1) }'
}

validate_prefix() {
    [[ -f "$prefix/include/wolfssl/options.h" ]]
    [[ -f "$prefix/include/wolfssl/ssl.h" ]]
    [[ -f "$prefix/include/srtp2/srtp.h" ]]
    [[ -f "$prefix/lib/libwolfssl.a" ]]
    [[ -f "$prefix/lib/libsrtp2.a" ]]
    [[ -f "$manifest" ]]
    grep -qx "wolfssl_version=$wolfssl_version" "$manifest"
    grep -qx "libsrtp_version=$libsrtp_version" "$manifest"
    grep -qx "libsrtp_crypto=wolfcrypt" "$manifest"
    archive_has_symbol "$prefix/lib/libwolfssl.a" "_wolfDTLSv1_3_client_method"
    archive_has_symbol "$prefix/lib/libwolfssl.a" "_wolfSSL_export_dtls_srtp_keying_material"
    archive_has_symbol "$prefix/lib/libsrtp2.a" "_srtp_create"
    ar -t "$prefix/lib/libsrtp2.a" | grep -q "aes_gcm_wolfssl"
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
mkdir -p "$staged_prefix"
if [[ -d "$prefix" ]]; then
    cp -R "$prefix/." "$staged_prefix"
fi

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
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$deployment_target" \
    -DBUILD_SHARED_LIBS=OFF \
    -DWOLFSSL_EXAMPLES=OFF \
    -DWOLFSSL_CRYPT_TESTS=OFF \
    -DWOLFSSL_DTLS=ON \
    -DWOLFSSL_TLS13=ON \
    -DWOLFSSL_DTLS13=ON \
    -DWOLFSSL_SRTP=ON \
    -DWOLFSSL_ALPN=ON \
    -DWOLFSSL_AESGCM=ON \
    -DWOLFSSL_CURVE25519=ON \
    -DWOLFSSL_ED25519=ON \
    -DWOLFSSL_OPENSSLEXTRA=ON
cmake --build "$task_temp/wolfssl-build" --parallel "$jobs"
cmake --install "$task_temp/wolfssl-build"

libsrtp_source="$task_temp/libsrtp-$libsrtp_version"
cp "$repository_root/Vendor/CLibSRTP/Patches/aes_gcm_wolfssl.c" "$libsrtp_source/crypto/cipher/aes_gcm_wolfssl.c"
cp "$repository_root/Vendor/CLibSRTP/Patches/aes_icm_wolfssl.c" "$libsrtp_source/crypto/cipher/aes_icm_wolfssl.c"
patch -d "$libsrtp_source" -p1 < "$repository_root/Vendor/CLibSRTP/Patches/libsrtp-2.8.0-wolfssl.patch"
cmake -S "$libsrtp_source" -B "$task_temp/libsrtp-build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$staged_prefix" \
    -DCMAKE_PREFIX_PATH="$staged_prefix" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$deployment_target" \
    -DBUILD_SHARED_LIBS=OFF \
    -DENABLE_OPENSSL=OFF \
    -DENABLE_WOLFSSL=ON \
    -DTEST_APPS=OFF
cmake --build "$task_temp/libsrtp-build" --parallel "$jobs"
cmake --install "$task_temp/libsrtp-build"

{
    print -r -- "schema=1"
    print -r -- "wolfssl_version=$wolfssl_version"
    print -r -- "wolfssl_source_sha256=$wolfssl_sha256"
    print -r -- "libsrtp_version=$libsrtp_version"
    print -r -- "libsrtp_source_sha256=$libsrtp_sha256"
    print -r -- "libsrtp_crypto=wolfcrypt"
    print -r -- "deployment_target=$deployment_target"
    print -r -- "architecture=arm64"
} > "$staged_prefix/.umbra-lsp-deps.manifest"

old_prefix="$task_temp/old-prefix"
mkdir -p "${prefix:h}"
if [[ -e "$prefix" ]]; then
    mv "$prefix" "$old_prefix"
fi
if ! mv "$staged_prefix" "$prefix" || ! validate_prefix; then
    rm -rf "$prefix"
    if [[ -e "$old_prefix" ]]; then
        mv "$old_prefix" "$prefix"
    fi
    print -u2 -- "Pinned LSP dependency installation failed validation."
    exit 1
fi
print -r -- "$prefix"
