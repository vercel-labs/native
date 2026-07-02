#!/usr/bin/env bash
# Build a zero-native mobile embed static library for the iOS simulator,
# link it into the minimal ObjC presentation shim (main.m), assemble an
# .app bundle without an .xcodeproj, then install + launch it on a booted
# simulator and verify a non-blank screenshot.
#
# Usage:
#   ./run.sh                                   # mobile-canvas on "iPhone 15"
#   ./run.sh --example-dir ../../ui-inbox --build-arg -Dmobile=true
#   ./run.sh --device "iPhone 15 Pro" --shutdown
#   ./run.sh --build-only                      # stop after the .app bundle
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE_DIR="$SCRIPT_DIR/.."
DEVICE="iPhone 15"
BUILD_ONLY=0
SHUTDOWN=0
SCREENSHOT=""
BUILD_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --example-dir) EXAMPLE_DIR="$2"; shift 2 ;;
    --device) DEVICE="$2"; shift 2 ;;
    --build-arg) BUILD_ARGS+=("$2"); shift 2 ;;
    --screenshot) SCREENSHOT="$2"; shift 2 ;;
    --build-only) BUILD_ONLY=1; shift ;;
    --shutdown) SHUTDOWN=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

EXAMPLE_DIR="$(cd "$EXAMPLE_DIR" && pwd)"

echo "== zig build lib -Dtarget=aarch64-ios-simulator (${EXAMPLE_DIR})"
(cd "$EXAMPLE_DIR" && zig build lib -Dtarget=aarch64-ios-simulator "${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}")

LIB="$(ls "$EXAMPLE_DIR"/zig-out/lib/*.a | head -1)"
[[ -f "$LIB" ]] || { echo "no static library under $EXAMPLE_DIR/zig-out/lib" >&2; exit 1; }
APP_NAME="$(basename "$LIB")"
APP_NAME="${APP_NAME#lib}"
APP_NAME="${APP_NAME%.a}"
BUNDLE_ID="dev.zero-native.${APP_NAME}"

BUILD_DIR="$SCRIPT_DIR/build/$APP_NAME"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE"

echo "== compile + link shim -> $APP_BUNDLE"
xcrun --sdk iphonesimulator clang \
  -target arm64-apple-ios15.0-simulator \
  -fobjc-arc -O2 \
  "$SCRIPT_DIR/main.m" "$LIB" \
  -framework UIKit -framework Metal -framework QuartzCore \
  -framework Foundation -framework CoreGraphics \
  -o "$APP_BUNDLE/$APP_NAME"

sed -e "s/__APP_NAME__/$APP_NAME/g" -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" \
  "$SCRIPT_DIR/Info.plist.in" > "$APP_BUNDLE/Info.plist"

codesign --force --sign - "$APP_BUNDLE" >/dev/null

if [[ "$BUILD_ONLY" -eq 1 ]]; then
  echo "== built $APP_BUNDLE (skipping simulator)"
  exit 0
fi

echo "== boot simulator: $DEVICE"
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b >/dev/null

echo "== install + launch $BUNDLE_ID"
xcrun simctl install "$DEVICE" "$APP_BUNDLE"
xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl launch "$DEVICE" "$BUNDLE_ID"

sleep 4
SCREENSHOT="${SCREENSHOT:-$BUILD_DIR/$APP_NAME-simulator.png}"
xcrun simctl io "$DEVICE" screenshot "$SCREENSHOT" >/dev/null
echo "== screenshot: $SCREENSHOT"

# Non-blank verification: decode via sips -> BMP, sample a grid, count
# distinct colors. A blank/solid screen yields a handful; rendered UI yields
# dozens or more.
BMP="$BUILD_DIR/$APP_NAME-simulator.bmp"
sips -s format bmp "$SCREENSHOT" --out "$BMP" >/dev/null
DISTINCT="$(python3 - "$BMP" <<'PY'
import struct, sys
data = open(sys.argv[1], "rb").read()
offset = struct.unpack("<I", data[10:14])[0]
width = struct.unpack("<i", data[18:22])[0]
height = abs(struct.unpack("<i", data[22:26])[0])
bpp = struct.unpack("<H", data[28:30])[0]
assert bpp in (24, 32), f"unexpected bmp bpp {bpp}"
step = bpp // 8
row_size = ((width * step + 3) // 4) * 4
colors = set()
for y in range(0, height, max(1, height // 240)):
    row = offset + y * row_size
    for x in range(0, width, max(1, width // 240)):
        p = row + x * step
        colors.add(data[p:p + 3])
print(len(colors))
PY
)"
echo "== distinct sampled colors: $DISTINCT"

if [[ "$SHUTDOWN" -eq 1 ]]; then
  xcrun simctl shutdown "$DEVICE" || true
fi

if [[ "$DISTINCT" -lt 10 ]]; then
  echo "FAIL: screenshot looks blank ($DISTINCT distinct colors)" >&2
  exit 1
fi
echo "OK: non-blank simulator frame ($DISTINCT distinct colors)"
