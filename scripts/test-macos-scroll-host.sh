#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/native-sdk-scroll-host.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
xcrun clang -fobjc-arc -O2 -Wno-deprecated-declarations \
  tests/platform/macos_scroll_host.m -o "$test_dir/scroll-host" \
  -framework AppKit -framework AVFoundation -framework CoreMedia \
  -framework ScreenCaptureKit -framework MediaToolbox -framework Accelerate \
  -framework Metal -framework QuartzCore -framework WebKit -framework CoreText \
  -framework ImageIO -framework Security -framework UniformTypeIdentifiers
"$test_dir/scroll-host"
