#!/usr/bin/env bash
# Windows canvas smoke under Wine.
#
# Exercises the Windows gpu_surface software path (src/platform/windows/
# webview2_host.cpp: child HWND, WM_TIMER frame events, SetDIBitsToDevice
# blits) without Windows hardware: cross-compiles examples/ui-inbox for
# x86_64-windows-gnu, runs the .exe under Xvfb + Wine, and asserts against
# the automation snapshot:
#
#   1. snapshot ready=true            (app booted, automation server live)
#   2. gpu_backend=software           (the SetDIBitsToDevice path is active)
#   3. gpu_nonblank=true              (real pixels were presented)
#   4. widget-click "Add task" -> '4 open'   (automation input mutates state)
#   5. real X11 click + typing lands in the draft textbox (XTEST -> Wine ->
#      WM_LBUTTONDOWN/WM_CHAR -> runtime)
#
# Step 5 (xdotool) is deliberately included: it is the only coverage of the
# Win32 pointer/keyboard input mapping in webview2_host.cpp. It is also the
# flakiest step (window lookup, focus without a window manager), so every
# failure path dumps the X window list, the snapshot, and the app log.
#
# Deliberately NOT `set -e`: grep exits 1 on zero matches inside the poll
# loops, and we want explicit, diagnosable failures instead of silent early
# exits. Every assertion goes through fail(), which dumps diagnostics.
set -u

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
app_dir="$repo_root/examples/ui-inbox"
snap="$app_dir/.zig-cache/zero-native-automation/snapshot.txt"
cli="$repo_root/zig-out/bin/zero-native"
app_log="${TMPDIR:-/tmp}/windows-canvas-smoke-app.log"

# Wine needs an X display; when none is present (CI), re-exec the whole
# script under a private Xvfb server so the app and xdotool share it. The
# explicit screen size beats xvfb-run's 640x480x8 default: the app window is
# 720x520 and Wine wants a 24-bit visual.
if [ -z "${DISPLAY:-}" ]; then
  exec xvfb-run -a --server-args="-screen 0 1280x800x24" "$0" "$@"
fi

export WINEPREFIX="${WINEPREFIX:-$repo_root/.zig-cache/wineprefix}"
export WINEDEBUG="${WINEDEBUG:--all}"

app_pid=""
cleanup() {
  [ -n "$app_pid" ] && kill "$app_pid" >/dev/null 2>&1
  wineserver -k >/dev/null 2>&1
}
trap cleanup EXIT

diagnostics() {
  echo "---- diagnostics ----"
  echo "-- X windows:"
  xdotool search --name "." 2>/dev/null | while read -r w; do
    echo "  $w: $(xdotool getwindowname "$w" 2>/dev/null)"
  done
  echo "-- snapshot ($snap):"
  if [ -f "$snap" ]; then tr '|' '\n' < "$snap" | sed 's/^/  /'; else echo "  (missing)"; fi
  echo "-- app log tail ($app_log):"
  tail -40 "$app_log" 2>/dev/null | sed 's/^/  /'
  echo "---------------------"
}

fail() {
  echo "FAIL: $1"
  diagnostics
  exit 1
}

# poll <seconds> <pattern>: wait until $snap contains <pattern>.
poll() {
  local deadline=$((SECONDS + $1))
  while [ "$SECONDS" -lt "$deadline" ]; do
    [ -f "$snap" ] && grep -q "$2" "$snap" && return 0
    sleep 0.5
  done
  return 1
}

# ---- build ----------------------------------------------------------------
(cd "$repo_root" && zig build) || fail "root zig build (CLI) failed"
(cd "$app_dir" && zig build -Dtarget=x86_64-windows-gnu -Dplatform=windows -Dweb-engine=system -Dautomation=true) \
  || fail "ui-inbox Windows cross-compile failed"

# ---- wineprefix -----------------------------------------------------------
# First run initializes the prefix (measured ~10-30s on CI-class machines);
# subsequent runs are instant, so no cache step is needed.
start=$SECONDS
wineboot --init >/dev/null 2>&1
wineserver --wait >/dev/null 2>&1
echo "== wineprefix ready in $((SECONDS - start))s ($WINEPREFIX)"

# ---- launch ---------------------------------------------------------------
cd "$app_dir" || fail "missing $app_dir"
rm -rf .zig-cache/zero-native-automation
mkdir -p .zig-cache/zero-native-automation
wine zig-out/bin/ui-inbox.exe > "$app_log" 2>&1 &
app_pid=$!

# ---- 1: automation snapshot becomes ready ---------------------------------
poll 180 'ready=true' || fail "snapshot never became ready"
echo "== ready: $(head -1 "$snap" | cut -d'|' -f1)"

# ---- 2 + 3: software backend presented non-blank pixels --------------------
poll 60 'gpu_nonblank=true' || fail "gpu_nonblank never became true"
grep -q 'gpu_backend=software' "$snap" || fail "gpu_backend is not software"
echo "== canvas: $(grep -o 'gpu_backend=[a-z]*' "$snap" | head -1)" \
  "$(grep -o 'gpu_nonblank=[a-z]*' "$snap" | head -1)" \
  "$(grep -o 'gpu_sample=0x[0-9a-f]*' "$snap" | head -1)" \
  "$(grep -o 'gpu_present_mode=[a-z]*' "$snap" | head -1)"

# ---- 4: automation widget-click mutates the model --------------------------
echo "== open before click: $(grep -oE '[0-9]+ open' "$snap" | head -1)"
add_id=$(grep -o 'widget @w1/inbox-canvas#[0-9]* role=button name="Add task"' "$snap" \
  | grep -o '#[0-9]*' | tr -d '#')
[ -n "$add_id" ] || fail "Add task button not found in snapshot"
"$cli" automate widget-click inbox-canvas "$add_id" || fail "CLI widget-click failed"
poll 30 '4 open' || fail "widget-click did not reach '4 open'"
echo "== open after click: $(grep -oE '[0-9]+ open' "$snap" | head -1)"

# ---- 5: real X11 input through the Win32 path ------------------------------
# Under Wine the app's X window maps 1:1 onto the Win32 client area (no
# decoration offset), so widget snapshot bounds translate directly to root
# coordinates relative to the window origin.
win=""
for w in $(xdotool search --name "." 2>/dev/null); do
  case "$(xdotool getwindowname "$w" 2>/dev/null)" in
    *[Ii]nbox*) win="$w" ;;
  esac
done
[ -n "$win" ] || fail "app X window not found"
eval "$(xdotool getwindowgeometry --shell "$win")"
echo "== x window $win: pos=($X,$Y) size=${WIDTH}x${HEIGHT}"
xdotool windowactivate "$win" >/dev/null 2>&1 || xdotool windowfocus "$win" >/dev/null 2>&1

draft_line=$(grep -o 'widget @w1/inbox-canvas#[0-9]* role=textbox[^|]*' "$snap" | head -1)
[ -n "$draft_line" ] || fail "draft textbox not found in snapshot"
bounds=$(echo "$draft_line" | grep -o 'bounds=([^)]*)')
bx=$(echo "$bounds" | sed -n 's/bounds=(\([0-9.]*\),.*/\1/p')
by=$(echo "$bounds" | sed -n 's/bounds=([0-9.]*,\([0-9.]*\) .*/\1/p')
bw=$(echo "$bounds" | sed -n 's/.* \([0-9.]*\)x[0-9.]*).*/\1/p')
bh=$(echo "$bounds" | sed -n 's/.* [0-9.]*x\([0-9.]*\)).*/\1/p')
[ -n "$bx" ] && [ -n "$by" ] && [ -n "$bw" ] && [ -n "$bh" ] || fail "could not parse draft bounds: $draft_line"
cx=$(awk "BEGIN{printf \"%d\", $X + $bx + $bw / 2}")
cy=$(awk "BEGIN{printf \"%d\", $Y + $by + $bh / 2}")
echo "== clicking draft field $bounds at ($cx,$cy)"
xdotool mousemove "$cx" "$cy" click 1
sleep 2
xdotool type --delay 120 "hi from wine"
poll 30 'hi from wine' || fail "typed text never appeared in the snapshot"
echo "== draft after typing: $(grep -o 'widget @w1/inbox-canvas#[0-9]* role=textbox[^|]*' "$snap" | head -1 | cut -c1-160)"
echo "== input latency: $(grep -o 'gpu_input_latency_ns=[0-9]*' "$snap" | head -1)"

echo "PASS: windows canvas smoke"
exit 0
