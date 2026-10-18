#!/bin/bash
set -euo pipefail

# A bare command-line executable has no advertised Chinese localization. Foundation then
# constrains framework lookup to its English development language. Use an actual bundle
# declaring the same languages as Compositor, without enabling mixed localizations.
root="$(cd "$(dirname "$0")/.." && pwd)"
products="${1:?Usage: bash scripts/run-camera-raw-plugin-smoke.sh <Debug-products-directory>}"
products="$(cd "$products" && pwd)"
workspace="$(mktemp -d "${TMPDIR:-/tmp/}CompositorLanguageSmoke.XXXXXX")"
host="$workspace/Smoke.app/Contents"
mkdir -p "$host/MacOS"
cp "$root/scripts/camera-raw-smoke-info.plist" "$host/Info.plist"
xcrun swiftc -swift-version 6 -parse-as-library \
    -target "$(uname -m)-apple-macos26.0" \
    -F "$products" -framework CameraRawHostContract \
    -Xlinker -rpath -Xlinker "$products" \
    "$root/CameraRawPlugin/CameraRawLocalization.swift" \
    "$root/CameraRawPlugin/CameraRawDraft.swift" \
    "$root/CameraRawPlugin/CameraRawPanelModel.swift" \
    "$root/scripts/camera-raw-plugin-smoke.swift" \
    -o "$host/MacOS/camera-raw-plugin-smoke"
for language in en zh-Hans; do
    "$host/MacOS/camera-raw-plugin-smoke" "$products/CameraRawPlugin.framework" \
        "$language" -AppleLanguages "($language)"
done
printf 'Smoke host retained at %s\n' "$workspace/Smoke.app"
