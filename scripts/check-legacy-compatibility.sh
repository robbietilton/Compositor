#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/Compositor.xcodeproj/project.pbxproj"
ENTITLEMENTS="$ROOT/Config/Compositor.entitlements"
RESOLVED="$ROOT/Compositor.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

if rg -n 'MACOSX_DEPLOYMENT_TARGET = ' "$PROJECT" | rg -v 'MACOSX_DEPLOYMENT_TARGET = 12\.0;' >/dev/null; then
    print -u2 "deployment target is not uniformly 12.0"
    exit 1
fi

rg -q '"version" : "2\.10\.0"' "$RESOLVED" || {
    print -u2 "Sparkle 2.10.0 is not pinned"
    exit 1
}

if rg -n 'disable-library-validation|allow-jit|allow-unsigned-executable-memory|get-task-allow' "$ENTITLEMENTS" >/dev/null; then
    print -u2 "forbidden security entitlement found"
    exit 1
fi

if rg -n 'Transferable|dropDestination|\.draggable\(|\.inspector\(|navigationSplitView|windowResizability' "$ROOT/Compositor" >/dev/null; then
    print -u2 "newer unsupported API found"
    exit 1
fi

if [[ $# -gt 0 ]]; then
    executable="$1/Contents/MacOS/Compositor"
    [[ -x "$executable" ]] || {
        print -u2 "missing app executable: $executable"
        exit 1
    }
    architectures="$(lipo -archs "$executable")"
    [[ "$architectures" == *x86_64* ]] || exit 1
    [[ "$architectures" == *arm64* ]] || exit 1
fi

print "legacy compatibility checks passed"
