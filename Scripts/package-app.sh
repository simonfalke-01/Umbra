#!/bin/zsh
set -euo pipefail

repository_root="${0:A:h:h}"
configuration="${CONFIGURATION:-release}"
app_root="${UMBRA_APP_OUTPUT_PATH:-$repository_root/.build/Umbra.app}"
app_root="${app_root:A}"
build_scratch_path="${UMBRA_BUILD_SCRATCH_PATH:-}"
expected_app_identifier="app.umbra.Umbra"

[[ "$app_root" == *.app ]] || {
    echo "Umbra's package output must be a specific .app path." >&2
    exit 1
}
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
[[ "$app_identifier" == "$expected_app_identifier" ]] || {
    echo "Umbra's bundle identifier must remain $expected_app_identifier for macOS privacy permissions." >&2
    exit 1
}
[[ "$(plutil -extract CFBundleURLTypes.0.CFBundleURLSchemes.0 raw "$app_root/Contents/Info.plist")" == "umbra" ]] || {
    echo "Umbra's secure-pairing URL scheme is missing from the packaged app." >&2
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
trap 'rm -rf "$compiled_localizations"' EXIT
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

localizable_strings="$app_root/Contents/Resources/en.lproj/Localizable.strings"
info_plist_strings="$app_root/Contents/Resources/en.lproj/InfoPlist.strings"
nested_localizable_strings="$packaged_resource_bundle/en.lproj/Localizable.strings"
nested_info_plist_strings="$packaged_resource_bundle/en.lproj/InfoPlist.strings"
[[ -f "$localizable_strings"
    && -f "$info_plist_strings"
    && -f "$nested_localizable_strings"
    && -f "$nested_info_plist_strings" ]] || {
    echo "Umbra's English localization resources are incomplete." >&2
    exit 1
}
if find "$app_root/Contents/Resources" -name '*.xcstrings' -print -quit | grep -q .; then
    echo "Umbra's package contains localization source catalogs instead of compiled resources." >&2
    exit 1
fi
plutil -lint \
    "$localizable_strings" \
    "$info_plist_strings" \
    "$nested_localizable_strings" \
    "$nested_info_plist_strings" >/dev/null
[[ "$(plutil -extract CFBundleDisplayName raw "$info_plist_strings")" == "Umbra" ]] || {
    echo "Umbra's localized display name is missing or invalid." >&2
    exit 1
}
[[ -n "$(plutil -extract NSLocalNetworkUsageDescription raw "$info_plist_strings")" ]] || {
    echo "Umbra's localized local-network usage description is missing." >&2
    exit 1
}
[[ -n "$(plutil -extract NSInputMonitoringUsageDescription raw "$info_plist_strings")" ]] || {
    echo "Umbra's localized Input Monitoring usage description is missing." >&2
    exit 1
}
[[ -n "$(plutil -extract NSMicrophoneUsageDescription raw "$info_plist_strings")" ]] || {
    echo "Umbra's localized microphone usage description is missing." >&2
    exit 1
}

dynamic_dependencies="$(otool -L "$app_root/Contents/MacOS/Umbra")"
if [[ "$dynamic_dependencies" == *"/opt/homebrew"*
    || "$dynamic_dependencies" == *"/usr/local"*
    || "$dynamic_dependencies" == *"libopus"*
    || "$dynamic_dependencies" == *"libssl"*
    || "$dynamic_dependencies" == *"libcrypto"* ]]; then
    echo "Refusing to package an executable with non-system dynamic dependencies." >&2
    exit 1
fi

if nm -gU "$app_root/Contents/MacOS/Umbra" \
    | awk '$3 ~ /^_SSL_/ || $3 ~ /^_umbra_tls_client_/ { found = 1 }
           END { exit(found ? 0 : 1) }'; then
    echo "Refusing to package dormant TLS facade or libssl symbols before integration review." >&2
    exit 1
fi

[[ "$(lipo -archs "$app_root/Contents/MacOS/Umbra")" == "arm64" ]] || {
    echo "Umbra release executable must be arm64-only." >&2
    exit 1
}

if [[ -n "${CODE_SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$CODE_SIGN_IDENTITY" "$app_root"
else
    codesign \
        --force \
        --sign - \
        --identifier "$app_identifier" \
        "$app_root"
fi

codesign --verify --deep --strict --verbose=2 "$app_root"

echo "$app_root"
