#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/compositor-finish.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -g \
    -I Compositor/Rendering Compositor/Rendering/FinishPixels.c \
    scripts/tests/finish_pixels_test.c -o "$build_dir/finish-tests"
"$build_dir/finish-tests"

clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -g \
    -I Compositor/Rendering Compositor/Rendering/ESRGANPixels.c \
    scripts/tests/esrgan_pixels_test.c -o "$build_dir/esrgan-pixel-tests"
"$build_dir/esrgan-pixel-tests"

swiftc -module-cache-path "$build_dir/swift-cache" \
    Compositor/Rendering/CanvasViewport.swift Compositor/Rendering/FinishComparisonGeometry.swift \
    scripts/tests/finish_comparison_test.swift -o "$build_dir/comparison-tests"
"$build_dir/comparison-tests"
