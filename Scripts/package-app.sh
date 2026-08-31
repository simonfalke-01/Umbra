#!/bin/zsh
set -euo pipefail

repository_root="${0:A:h:h}"
configuration="${CONFIGURATION:-release}"
app_root="${UMBRA_APP_OUTPUT_PATH:-$repository_root/.build/Umbra.app}"
app_root="${app_root:A}"
build_scratch_path="${UMBRA_BUILD_SCRATCH_PATH:-}"
expected_app_identifier="app.umbra.Umbra"
qualifying_build="${UMBRA_QUALIFYING_BUILD:-0}"
approved_certificate_sha256="${UMBRA_APPROVED_SIGNING_CERTIFICATE_SHA256:-}"
approved_entitlements_sha256="${UMBRA_APPROVED_ENTITLEMENTS_SHA256:-}"
signing_entitlements_path="${UMBRA_SIGNING_ENTITLEMENTS_PATH:-}"
validate_only_path=""
typeset -a cleanup_paths=()

cleanup() {
    local cleanup_path
    for cleanup_path in "${cleanup_paths[@]}"; do
        [[ -e "$cleanup_path" ]] && rm -rf -- "$cleanup_path"
    done
}
trap cleanup EXIT

fail() {
    echo "$1" >&2
    exit 1
}

if (( $# > 0 )); then
    if [[ "$1" != "--validate-only" || $# != 2 ]]; then
        fail "Usage: package-app.sh [--validate-only /absolute/path/Umbra.app]"
    fi
    validate_only_path="${2:A}"
    app_root="$validate_only_path"
fi

if [[ "$qualifying_build" != "0" && "$qualifying_build" != "1" ]]; then
    fail "UMBRA_QUALIFYING_BUILD must be 0 or 1."
fi

normalize_sha256() {
    local digest="${1:l}"
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || fail "$2 must be a lowercase SHA-256 digest."
    echo "$digest"
}

certificate_sha256_for_identity() {
    local identity="$1"
    local metadata
    metadata="$(security find-certificate -c "$identity" -Z 2>/dev/null)" || {
        fail "The requested code-signing certificate is unavailable: $identity"
    }
    echo "$metadata" | awk '
        /^SHA-256 hash:/ { digest = tolower($3); count += 1 }
        END { if (count == 1) print digest; else exit 1 }
    ' || fail "The requested code-signing identity is ambiguous or has no SHA-256 certificate hash."
}

canonical_entitlements_sha256() {
    python3 - "$1" <<'PY'
import hashlib
import plistlib
import sys
from pathlib import Path

data = Path(sys.argv[1]).read_bytes()
value = plistlib.loads(data) if data else {}
canonical = plistlib.dumps(value, fmt=plistlib.FMT_BINARY, sort_keys=True)
print(hashlib.sha256(canonical).hexdigest())
PY
}

require_qualifying_identity() {
    [[ -n "${CODE_SIGN_IDENTITY:-}" && "$CODE_SIGN_IDENTITY" != "-" ]] || {
        fail "Qualifying Umbra packages require an explicit non-ad-hoc CODE_SIGN_IDENTITY."
    }
    approved_certificate_sha256="$(normalize_sha256 \
        "$approved_certificate_sha256" \
        "UMBRA_APPROVED_SIGNING_CERTIFICATE_SHA256")"
    approved_entitlements_sha256="$(normalize_sha256 \
        "$approved_entitlements_sha256" \
        "UMBRA_APPROVED_ENTITLEMENTS_SHA256")"
    local available_certificate_sha256
    available_certificate_sha256="$(certificate_sha256_for_identity "$CODE_SIGN_IDENTITY")"
    [[ "$available_certificate_sha256" == "$approved_certificate_sha256" ]] || {
        fail "CODE_SIGN_IDENTITY does not match the certificate frozen for this qualifying build."
    }
    if [[ -n "$signing_entitlements_path" ]]; then
        signing_entitlements_path="${signing_entitlements_path:A}"
        [[ -f "$signing_entitlements_path" && ! -L "$signing_entitlements_path" ]] || {
            fail "UMBRA_SIGNING_ENTITLEMENTS_PATH must identify a regular file."
        }
    fi
}

validate_packaged_app() {
    local candidate="$1"
    [[ -d "$candidate" && ! -L "$candidate" ]] || fail "Umbra package is not a regular app directory."
    if find "$candidate" -type l -print -quit | grep -q .; then
        fail "Qualifying Umbra packages may not contain symlinks."
    fi

    local info_plist="$candidate/Contents/Info.plist"
    local executable="$candidate/Contents/MacOS/Umbra"
    local resource_directory="$candidate/Contents/Resources"
    [[ -f "$info_plist" && -f "$executable" && -d "$resource_directory" ]] || {
        fail "Umbra's packaged executable, Info.plist, or resources are missing."
    }

    local app_identifier
    app_identifier="$(plutil -extract CFBundleIdentifier raw "$info_plist")"
    [[ "$app_identifier" == "$expected_app_identifier" ]] || {
        fail "Umbra's bundle identifier must remain $expected_app_identifier for macOS privacy permissions."
    }
    [[ "$(plutil -extract NSBonjourServices.0 raw "$info_plist")" == "_nvstream._tcp" ]] || {
        fail "Umbra's legacy GameStream Bonjour declaration is missing."
    }

    local packaged_resource_bundle="$resource_directory/Umbra_UmbraApp.bundle"
    local localizable_strings="$resource_directory/en.lproj/Localizable.strings"
    local info_plist_strings="$resource_directory/en.lproj/InfoPlist.strings"
    local nested_localizable_strings="$packaged_resource_bundle/en.lproj/Localizable.strings"
    local nested_info_plist_strings="$packaged_resource_bundle/en.lproj/InfoPlist.strings"
    [[ -f "$localizable_strings"
        && -f "$info_plist_strings"
        && -f "$nested_localizable_strings"
        && -f "$nested_info_plist_strings" ]] || {
        fail "Umbra's English localization resources are incomplete."
    }
    if find "$resource_directory" -name '*.xcstrings' -print -quit | grep -q .; then
        fail "Umbra's package contains localization source catalogs instead of compiled resources."
    fi
    plutil -lint \
        "$localizable_strings" \
        "$info_plist_strings" \
        "$nested_localizable_strings" \
        "$nested_info_plist_strings" >/dev/null
    [[ "$(plutil -extract CFBundleDisplayName raw "$info_plist_strings")" == "Umbra" ]] || {
        fail "Umbra's localized display name is missing or invalid."
    }
    [[ -n "$(plutil -extract NSLocalNetworkUsageDescription raw "$info_plist_strings")" ]] || {
        fail "Umbra's localized local-network usage description is missing."
    }
    [[ -n "$(plutil -extract NSInputMonitoringUsageDescription raw "$info_plist_strings")" ]] || {
        fail "Umbra's localized Input Monitoring usage description is missing."
    }
    [[ -n "$(plutil -extract NSMicrophoneUsageDescription raw "$info_plist_strings")" ]] || {
        fail "Umbra's localized microphone usage description is missing."
    }

    local dynamic_dependencies
    dynamic_dependencies="$(otool -L "$executable")"
    if [[ "$dynamic_dependencies" == *"/opt/homebrew"*
        || "$dynamic_dependencies" == *"/usr/local"*
        || "$dynamic_dependencies" == *"libopus"*
        || "$dynamic_dependencies" == *"libssl"*
        || "$dynamic_dependencies" == *"libcrypto"* ]]; then
        fail "Refusing to package an executable with non-system dynamic dependencies."
    fi
    if nm -gU "$executable" \
        | awk '$3 ~ /^_SSL_/ || $3 ~ /^_umbra_tls_client_/ { found = 1 }
               END { exit(found ? 0 : 1) }'; then
        fail "Refusing to package dormant TLS facade or libssl symbols before integration review."
    fi
    [[ "$(lipo -archs "$executable")" == "arm64" ]] || {
        fail "Umbra release executable must be arm64-only."
    }

    codesign --verify --deep --strict --verbose=2 "$candidate"
    if [[ "$qualifying_build" == "1" ]]; then
        require_qualifying_identity
        local signature_details
        signature_details="$(codesign --display --verbose=4 "$candidate" 2>&1)"
        [[ "$signature_details" != *"Signature=adhoc"*
            && "$signature_details" != *"TeamIdentifier=not set"*
            && "$signature_details" == *"Authority=$CODE_SIGN_IDENTITY"* ]] || {
            fail "Umbra package is not signed by the approved non-ad-hoc identity."
        }
        echo "$signature_details" | grep -Eq 'flags=.*\(.*runtime.*\)' || {
            fail "Umbra qualifying signature is missing hardened-runtime flags."
        }

        local certificate_directory certificate_prefix signed_certificate_sha256
        certificate_directory="$(mktemp -d)"
        cleanup_paths+=("$certificate_directory")
        certificate_prefix="$certificate_directory/codesign"
        codesign --display --extract-certificates "$certificate_prefix" "$candidate" >/dev/null 2>&1
        [[ -f "${certificate_prefix}0" ]] || fail "Unable to extract Umbra's leaf signing certificate."
        signed_certificate_sha256="$(shasum -a 256 "${certificate_prefix}0" | awk '{print tolower($1)}')"
        [[ "$signed_certificate_sha256" == "$approved_certificate_sha256" ]] || {
            fail "Umbra's embedded signing certificate differs from the frozen identity."
        }

        local entitlement_directory entitlement_output entitlement_stderr actual_entitlements_sha256
        entitlement_directory="$(mktemp -d)"
        cleanup_paths+=("$entitlement_directory")
        entitlement_output="$entitlement_directory/entitlements.plist"
        entitlement_stderr="$entitlement_directory/entitlements.stderr"
        codesign --display --entitlements :- "$candidate" \
            >"$entitlement_output" 2>"$entitlement_stderr"
        actual_entitlements_sha256="$(canonical_entitlements_sha256 "$entitlement_output")"
        [[ "$actual_entitlements_sha256" == "$approved_entitlements_sha256" ]] || {
            fail "Umbra's signed entitlements differ from the frozen policy."
        }

        echo "QUALIFYING_SIGNATURE_IDENTITY_SHA256=$signed_certificate_sha256"
        echo "QUALIFYING_ENTITLEMENTS_SHA256=$actual_entitlements_sha256"
        echo "QUALIFYING_CODESIGN_DETAILS_BEGIN"
        echo "$signature_details"
        echo "QUALIFYING_CODESIGN_DETAILS_END"
        echo "QUALIFYING_ENTITLEMENTS_BEGIN"
        cat "$entitlement_output"
        echo "QUALIFYING_ENTITLEMENTS_END"
    fi
}

[[ "$app_root" == *.app ]] || {
    echo "Umbra's package output must be a specific .app path." >&2
    exit 1
}

if [[ -n "$validate_only_path" ]]; then
    validate_packaged_app "$app_root"
    echo "$app_root"
    exit 0
fi
case "$app_root" in
    /|"$repository_root"|"$repository_root/.build"|"${repository_root:h}")
        echo "Refusing unsafe Umbra package output: $app_root" >&2
        exit 1
        ;;
esac

cd "$repository_root"
if [[ "$configuration" == "release" ]]; then
    release_prefix="$("$repository_root/Scripts/bootstrap-release-deps.sh")"
    export UMBRA_RELEASE_DEPS_PREFIX="$release_prefix"
    export PKG_CONFIG_LIBDIR="$release_prefix/lib/pkgconfig"
    export PKG_CONFIG_PATH=""
    export MACOSX_DEPLOYMENT_TARGET="14.0"
fi

swift_build_args=(-c "$configuration")
if [[ "$qualifying_build" == "1" ]]; then
    require_qualifying_identity
    swift_build_args+=(
        -Xswiftc -warnings-as-errors
        -Xcc -Werror
        -Xlinker -fatal_warnings
    )
fi
if [[ -n "$build_scratch_path" ]]; then
    swift_build_args+=(--scratch-path "${build_scratch_path:A}")
elif [[ "$configuration" == "release" ]]; then
    swift_build_args+=(--scratch-path "$repository_root/.build/release-static")
fi
build_root="$(env -u CC -u CXX swift build "${swift_build_args[@]}" --show-bin-path)"
env -u CC -u CXX swift build "${swift_build_args[@]}" --product Umbra

rm -rf "$app_root"
mkdir -p "$app_root/Contents/MacOS" "$app_root/Contents/Resources"
cp "$build_root/Umbra" "$app_root/Contents/MacOS/Umbra"
cp "$repository_root/Resources/Umbra/Info.plist" "$app_root/Contents/Info.plist"
app_identifier="$(plutil -extract CFBundleIdentifier raw "$app_root/Contents/Info.plist")"
[[ "$app_identifier" == "$expected_app_identifier" ]] || fail \
    "Umbra's bundle identifier must remain $expected_app_identifier for macOS privacy permissions."
[[ "$(plutil -extract NSBonjourServices.0 raw "$app_root/Contents/Info.plist")" == "_nvstream._tcp" ]] || {
    echo "Umbra's legacy GameStream Bonjour declaration is missing." >&2
    exit 1
}
cp "$repository_root/LICENSE" "$app_root/Contents/Resources/LICENSE"
cp "$repository_root/NOTICE.md" "$app_root/Contents/Resources/NOTICE.md"
cp "$repository_root/THIRD_PARTY_NOTICES.md" "$app_root/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp "$repository_root/Vendor/MoonlightCommon/PROVENANCE.md" "$app_root/Contents/Resources/MOONLIGHT_PROVENANCE.md"

resource_bundle="$build_root/Umbra_UmbraApp.bundle"
[[ -d "$resource_bundle" ]] || {
    echo "Umbra localization resources were not produced by SwiftPM." >&2
    exit 1
}
ditto "$resource_bundle" "$app_root/Contents/Resources/${resource_bundle:t}"
packaged_resource_bundle="$app_root/Contents/Resources/${resource_bundle:t}"
rm -f "$packaged_resource_bundle"/*.xcstrings(N)

compiled_localizations="$(mktemp -d)"
cleanup_paths+=("$compiled_localizations")
xcrun xcstringstool compile \
    "$repository_root/Sources/UmbraApp/Resources/Localizable.xcstrings" \
    --output-directory "$compiled_localizations"
xcrun xcstringstool compile \
    "$repository_root/Sources/UmbraApp/Resources/InfoPlist.xcstrings" \
    --output-directory "$compiled_localizations"
ditto \
    "$compiled_localizations" \
    "$app_root/Contents/Resources/${resource_bundle:t}"

for localization_directory in "$compiled_localizations"/*.lproj(N); do
    destination="$app_root/Contents/Resources/${localization_directory:t}"
    mkdir -p "$destination"
    ditto "$localization_directory" "$destination"
done

if [[ "$qualifying_build" == "1" ]]; then
    typeset -a codesign_arguments=(
        --force
        --options runtime
        --timestamp
        --sign "$CODE_SIGN_IDENTITY"
    )
    if [[ -n "$signing_entitlements_path" ]]; then
        codesign_arguments+=(--entitlements "$signing_entitlements_path")
    fi
    codesign "${codesign_arguments[@]}" "$app_root"
elif [[ -n "${CODE_SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$CODE_SIGN_IDENTITY" "$app_root"
else
    codesign \
        --force \
        --sign - \
        --identifier "$app_identifier" \
        "$app_root"
fi

validate_packaged_app "$app_root"

echo "$app_root"
