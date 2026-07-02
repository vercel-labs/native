#!/usr/bin/env bash
# M3 input-fidelity verification on the iOS simulator, with REAL input
# injection (system touch/keyboard events, not automation widget actions):
#
#   1. Build the example's mobile embed lib + shim .app (run.sh --build-only)
#      and launch it with ZERO_NATIVE_AUTOMATION=1, so the embedded runtime
#      publishes automation snapshots into the app's data container.
#   2. Compile a minimal XCUITest bundle (InputUITests.m, no .xcodeproj),
#      wrap it in the stock XCTRunner.app template, generate a .xctestrun,
#      and drive it with `xcodebuild test-without-building`. XCUITest
#      injects hardware-true touches and keyboard input.
#   3. Between test steps, read snapshot.txt from the container as ground
#      truth for model state:
#        (a) tap "Add task"          -> open count grows
#        (b) tap draft textbox       -> system keyboard appears (asserted in
#            the XCUITest), type text -> draft lands in the snapshot, tap
#            elsewhere -> keyboard hides
#        (c) drag-scroll the list    -> scroll offset changes
#   4. Re-verify the M2 non-blank screenshot check still passes.
#
# Usage:
#   ./verify_input.sh                       # ui-inbox on "iPhone 15"
#   ./verify_input.sh --device "iPhone 15 Pro" --shutdown
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE_DIR="$SCRIPT_DIR/../../ui-inbox"
DEVICE="iPhone 15"
SHUTDOWN=0
TYPE_TEXT="Milk run"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --example-dir) EXAMPLE_DIR="$2"; shift 2 ;;
    --device) DEVICE="$2"; shift 2 ;;
    --shutdown) SHUTDOWN=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

EXAMPLE_DIR="$(cd "$EXAMPLE_DIR" && pwd)"

echo "== build shim app (run.sh --build-only)"
"$SCRIPT_DIR/run.sh" --example-dir "$EXAMPLE_DIR" --build-arg -Dmobile=true --build-only

LIB="$(ls "$EXAMPLE_DIR"/zig-out/lib/*.a | head -1)"
APP_NAME="$(basename "$LIB")"
APP_NAME="${APP_NAME#lib}"
APP_NAME="${APP_NAME%.a}"
BUNDLE_ID="dev.zero-native.${APP_NAME}"
APP_BUNDLE="$SCRIPT_DIR/build/$APP_NAME/$APP_NAME.app"
WORK_DIR="$SCRIPT_DIR/build/$APP_NAME/input-verify"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

echo "== boot simulator: $DEVICE"
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b >/dev/null
UDID="$(xcrun simctl list devices booted -j | python3 -c '
import json, sys
for devices in json.load(sys.stdin)["devices"].values():
    for device in devices:
        if device["state"] == "Booted":
            print(device["udid"])
            raise SystemExit
')"
[[ -n "$UDID" ]] || { echo "no booted simulator" >&2; exit 1; }

echo "== install + launch $BUNDLE_ID with automation enabled"
xcrun simctl install "$UDID" "$APP_BUNDLE"
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
SIMCTL_CHILD_ZERO_NATIVE_AUTOMATION=1 xcrun simctl launch "$UDID" "$BUNDLE_ID"

CONTAINER="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)"
SNAPSHOT="$CONTAINER/Documents/zero-native-automation/snapshot.txt"
echo "== automation snapshot: $SNAPSHOT"

# Wait for a snapshot that already contains the installed widget tree (the
# first publish can precede the first gpu frame).
wait_for_snapshot() {
  for _ in $(seq 1 60); do
    grep -q 'name="Add task"' "$SNAPSHOT" 2>/dev/null && return 0
    sleep 0.5
  done
  echo "snapshot.txt never contained the widget tree" >&2
  exit 1
}
wait_for_snapshot

# Parse injection coordinates + model facts out of the snapshot. Emits
# shell-evalable NAME=VALUE lines.
snapshot_facts() {
  python3 - "$SNAPSHOT" <<'PY'
import re, sys

text = open(sys.argv[1], encoding="utf-8").read()
widgets = [line for line in text.splitlines() if line.strip().startswith("widget @")]

def bounds(line):
    m = re.search(r"bounds=\(([-\d.]+),([-\d.]+) ([-\d.]+)x([-\d.]+)\)", line)
    return tuple(float(v) for v in m.groups()) if m else None

def center(line):
    b = bounds(line)
    return (b[0] + b[2] / 2, b[1] + b[3] / 2)

def find(predicate, description):
    for line in widgets:
        if predicate(line):
            return line
    raise SystemExit(f"snapshot is missing: {description}")

add = find(lambda l: "role=button" in l and 'name="Add task"' in l, "Add task button")
textbox = find(lambda l: "role=textbox" in l, "draft textbox")
# Blur target: the empty gap right of the "done" filter tab — inside the
# app (clear of the system status bar) with no focusable widget under it,
# so a tap there drops textbox focus without other model effects.
done_tab = find(lambda l: "role=button" in l and 'name="done"' in l, "done filter button")
scroll = find(lambda l: "scroll=[offset=" in l, "scrollable widget")

def emit_point(name, line):
    x, y = center(line)
    print(f'{name}="{x:.1f},{y:.1f}"')

emit_point("ADD_POINT", add)
emit_point("TEXTBOX_POINT", textbox)
dx, dy, dw, dh = bounds(done_tab)
print(f'BLUR_POINT="{dx + dw + 30:.1f},{dy + dh / 2:.1f}"')

sx, sy, sw, sh = bounds(scroll)
from_y = sy + sh * 0.75
to_y = sy + sh * 0.25
cx = sx + sw / 2
print(f'SCROLL_FROM="{cx:.1f},{from_y:.1f}"')
print(f'SCROLL_TO="{cx:.1f},{to_y:.1f}"')

open_match = re.search(r'name="(\d+) open', text)
print(f"OPEN_COUNT={open_match.group(1) if open_match else -1}")
print(f"CHECKBOX_COUNT={sum('role=checkbox' in l for l in widgets)}")
offset = re.search(r"scroll=\[offset=([-\d.]+)", scroll)
print(f"SCROLL_OFFSET={offset.group(1)}")
draft = re.search(r' text="([^"]*)"', textbox)
print(f'DRAFT_TEXT="{draft.group(1) if draft else ""}"')
PY
}

echo "== build XCUITest runner (no .xcodeproj)"
DEVELOPER_DIR="$(xcode-select -p)"
SIM_PLATFORM="$DEVELOPER_DIR/Platforms/iPhoneSimulator.platform/Developer"
AGENTS="$SIM_PLATFORM/Library/Xcode/Agents"
PUBLIC_FW="$SIM_PLATFORM/Library/Frameworks"
PRIVATE_FW="$SIM_PLATFORM/Library/PrivateFrameworks"
USR_LIB="$SIM_PLATFORM/usr/lib"

TEST_NAME="InputUITests"
RUNNER="$WORK_DIR/$TEST_NAME-Runner.app"
XCTEST_BUNDLE="$RUNNER/PlugIns/$TEST_NAME.xctest"

cp -R "$AGENTS/XCTRunner.app" "$RUNNER"
mv "$RUNNER/XCTRunner" "$RUNNER/$TEST_NAME-Runner"
plutil -replace CFBundleExecutable -string "$TEST_NAME-Runner" "$RUNNER/Info.plist"
plutil -replace CFBundleIdentifier -string "dev.zero-native.$TEST_NAME.xctrunner" "$RUNNER/Info.plist"
plutil -replace CFBundleName -string "$TEST_NAME-Runner" "$RUNNER/Info.plist"

mkdir -p "$RUNNER/Frameworks" "$XCTEST_BUNDLE"
for framework in XCTest XCUIAutomation; do
  cp -R "$PUBLIC_FW/$framework.framework" "$RUNNER/Frameworks/"
done
for framework in XCTestCore XCTestSupport XCTAutomationSupport; do
  cp -R "$PRIVATE_FW/$framework.framework" "$RUNNER/Frameworks/"
done
cp "$USR_LIB/libXCTestSwiftSupport.dylib" "$RUNNER/Frameworks/"

xcrun --sdk iphonesimulator clang \
  -target arm64-apple-ios15.0-simulator \
  -fobjc-arc -bundle \
  -F "$PUBLIC_FW" \
  -framework XCTest -framework Foundation -framework CoreGraphics \
  "$SCRIPT_DIR/InputUITests.m" \
  -o "$XCTEST_BUNDLE/$TEST_NAME"
cat > "$XCTEST_BUNDLE/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$TEST_NAME</string>
  <key>CFBundleIdentifier</key><string>dev.zero-native.$TEST_NAME</string>
  <key>CFBundleName</key><string>$TEST_NAME</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
</dict>
</plist>
PLIST

find "$RUNNER/Frameworks" -maxdepth 1 \( -name "*.framework" -o -name "*.dylib" \) \
  -exec codesign --force --sign - {} \; 2>/dev/null
codesign --force --sign - "$XCTEST_BUNDLE" >/dev/null 2>&1
codesign --force --sign - "$RUNNER" >/dev/null 2>&1

# Injection coordinates from the current snapshot.
eval "$(snapshot_facts)"
echo "== targets: add=$ADD_POINT textbox=$TEXTBOX_POINT blur=$BLUR_POINT scroll=$SCROLL_FROM->$SCROLL_TO"

write_xctestrun() {
  cat > "$WORK_DIR/input.xctestrun" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>__xctestrun_metadata__</key>
  <dict>
    <key>FormatVersion</key><integer>1</integer>
  </dict>
  <key>$TEST_NAME</key>
  <dict>
    <key>TestBundlePath</key><string>__TESTHOST__/PlugIns/$TEST_NAME.xctest</string>
    <key>TestHostPath</key><string>__TESTROOT__/$TEST_NAME-Runner.app</string>
    <key>TestHostBundleIdentifier</key><string>dev.zero-native.$TEST_NAME.xctrunner</string>
    <key>UITargetAppPath</key><string>$APP_BUNDLE</string>
    <key>UITargetAppBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>IsUITestBundle</key><true/>
    <key>IsXCTRunnerHostedTestBundle</key><true/>
    <key>TestingEnvironmentVariables</key>
    <dict>
      <key>ZN_TARGET_BUNDLE_ID</key><string>$BUNDLE_ID</string>
      <key>ZN_TAP_POINT</key><string>$ADD_POINT</string>
      <key>ZN_TEXTBOX_POINT</key><string>$TEXTBOX_POINT</string>
      <key>ZN_BLUR_POINT</key><string>$BLUR_POINT</string>
      <key>ZN_TYPE_TEXT</key><string>$TYPE_TEXT</string>
      <key>ZN_PRESCROLL_TAPS</key><string>24</string>
      <key>ZN_SCROLL_FROM</key><string>$SCROLL_FROM</string>
      <key>ZN_SCROLL_TO</key><string>$SCROLL_TO</string>
    </dict>
  </dict>
</dict>
</plist>
PLIST
}
write_xctestrun

run_test() {
  local method="$1"
  echo "== xcodebuild test-without-building: $method"
  xcodebuild test-without-building \
    -xctestrun "$WORK_DIR/input.xctestrun" \
    -destination "platform=iOS Simulator,id=$UDID" \
    -only-testing:"$TEST_NAME/ZeroNativeInputUITests/$method" \
    >"$WORK_DIR/xcodebuild-$method.log" 2>&1 || {
      tail -50 "$WORK_DIR/xcodebuild-$method.log" >&2
      echo "FAIL: $method" >&2
      exit 1
    }
  grep -E "Test Suite 'ZeroNativeInputUITests' (passed|failed)" "$WORK_DIR/xcodebuild-$method.log" | tail -1 || true
}

# Snapshot assertions retry a few seconds: publish happens on the app's
# next pumped frame after the injected input.
assert_snapshot() {
  local description="$1"
  shift
  for _ in $(seq 1 20); do
    if "$@" >/dev/null 2>&1; then
      echo "OK: $description"
      return 0
    fi
    sleep 0.5
  done
  "$@" || { echo "FAIL: $description" >&2; exit 1; }
}

# ------------------------------------------------------------ (a) tap add
cp "$SNAPSHOT" "$WORK_DIR/snapshot-0-initial.txt"
BEFORE_OPEN="$OPEN_COUNT"
BEFORE_CHECKBOXES="$CHECKBOX_COUNT"
run_test testTapAddTask
check_tap() {
  eval "$(snapshot_facts)"
  [[ "$OPEN_COUNT" -eq $((BEFORE_OPEN + 1)) && "$CHECKBOX_COUNT" -eq $((BEFORE_CHECKBOXES + 1)) ]]
}
assert_snapshot "tap on 'Add task' grew open count $BEFORE_OPEN -> $((BEFORE_OPEN + 1))" check_tap
cp "$SNAPSHOT" "$WORK_DIR/snapshot-1-after-tap.txt"

# --------------------------------------- (b) focus, keyboard, type, blur
run_test testFocusTypeAndDismissKeyboard
check_typed() {
  eval "$(snapshot_facts)"
  [[ "$DRAFT_TEXT" == "$TYPE_TEXT" ]]
}
assert_snapshot "typed text '$TYPE_TEXT' landed in the draft textbox" check_typed
cp "$SNAPSHOT" "$WORK_DIR/snapshot-2-after-type.txt"

# ------------------------------------------------------ (c) drag scroll
run_test testDragScroll
check_scrolled() {
  eval "$(snapshot_facts)"
  python3 -c "import sys; sys.exit(0 if float('$SCROLL_OFFSET') > 0 else 1)"
}
assert_snapshot "drag-scroll moved the list offset above 0" check_scrolled
cp "$SNAPSHOT" "$WORK_DIR/snapshot-3-after-scroll.txt"
eval "$(snapshot_facts)"
echo "== final scroll offset: $SCROLL_OFFSET"

# ------------------------------------------- M2 non-blank screenshot check
SCREENSHOT="$WORK_DIR/$APP_NAME-input-verify.png"
xcrun simctl io "$UDID" screenshot "$SCREENSHOT" >/dev/null
BMP="$WORK_DIR/$APP_NAME-input-verify.bmp"
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
if [[ "$DISTINCT" -lt 10 ]]; then
  echo "FAIL: post-input screenshot looks blank ($DISTINCT distinct colors)" >&2
  exit 1
fi

if [[ "$SHUTDOWN" -eq 1 ]]; then
  xcrun simctl shutdown "$UDID" || true
fi

echo "PASS: tap, keyboard show/type/hide, and drag-scroll verified on the simulator"
