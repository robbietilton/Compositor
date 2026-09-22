#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="${COMPOSITOR_BUILD_DIR:-$repo_root/build}"
# Local ad-hoc builds have no Apple team identity to match the pre-signed Sparkle framework.
# Keep the app sandbox, but use the same non-hardened runtime as local Debug builds.
# Notarized distribution should use a real signing team and the project's hardened Release settings.
xcodebuild -project "$repo_root/Compositor.xcodeproj" -scheme Compositor \
  -configuration Release -derivedDataPath "$build_root" \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO \
  EXCLUDED_SOURCE_FILE_NAMES='*.pyc __pycache__' build
app_source="$build_root/Build/Products/Release/Compositor.app"
if [[ "${1:-}" == "--install" ]]; then
  app_destination="${2:-$HOME/Applications/Compositor MCP.app}"
  if [[ -e "$app_destination" ]]; then
    echo "Destination already exists: $app_destination" >&2
    echo "Choose a new destination or move the previous build before installing." >&2
    exit 1
  fi
  mkdir -p "$(dirname "$app_destination")"
  ditto "$app_source" "$app_destination"
  echo "Installed: $app_destination"
else
  echo "Built: $app_source"
fi
