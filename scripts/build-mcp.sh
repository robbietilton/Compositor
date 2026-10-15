#!/bin/zsh
set -euo pipefail

repository="${0:A:h:h}"
package="$repository/Tools/CompositorMCP"
output="$repository/build/CompositorMCP"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/CompositorMCPModuleCache"
export SWIFT_MODULECACHE_PATH="$CLANG_MODULE_CACHE_PATH"

xcrun swift build --disable-sandbox --package-path "$package" --configuration release --scratch-path "$output"
echo "$output/release/compositor-mcp"
