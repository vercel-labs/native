#!/usr/bin/env bash
# Windows canvas smoke under Wine.
#
# Exercises the Windows gpu_surface Direct2D path (src/platform/windows/
# webview2_host.cpp: child HWND, WM_TIMER frame events, retained binary
# packets) under Wine: cross-compiles examples/ui-inbox for
# x86_64-windows-gnu, runs the .exe under Xvfb + Wine, and asserts against
# the automation snapshot:
#
#   1. snapshot ready=true            (app booted, automation server live)
#   2. gpu_backend=direct2d           (the retained packet path is active)
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
snap="$app_dir/.zig-cache/native-sdk-automation/snapshot.txt"
cli="$repo_root/zig-out/bin/native"
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

# Print the first snapshot match, retrying reads that land between the
# runtime's truncate and rewrite on a presented frame.
snapshot_match() {
  local match=""
  for _ in $(seq 1 20); do
    match=$(grep -o "$1" "$snap" | head -1)
    if [ -n "$match" ]; then
      printf '%s\n' "$match"
      return 0
    fi
    sleep 0.1
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
rm -rf .zig-cache/native-sdk-automation
mkdir -p .zig-cache/native-sdk-automation
wine zig-out/bin/ui-inbox.exe > "$app_log" 2>&1 &
app_pid=$!

# ---- 1: automation snapshot becomes ready ---------------------------------
poll 180 'ready=true' || fail "snapshot never became ready"
echo "== ready: $(head -1 "$snap" | cut -d'|' -f1)"

# ---- 2 + 3: Direct2D backend presented non-blank pixels --------------------
poll 60 'gpu_nonblank=true' || fail "gpu_nonblank never became true"
poll 10 'gpu_backend=direct2d' || fail "gpu_backend is not direct2d"
echo "== canvas: $(grep -o 'gpu_backend=[a-z]*' "$snap" | head -1)" \
  "$(grep -o 'gpu_nonblank=[a-z]*' "$snap" | head -1)" \
  "$(grep -o 'gpu_sample=0x[0-9a-f]*' "$snap" | head -1)" \
  "$(grep -o 'gpu_present_mode=[a-z]*' "$snap" | head -1)"

# ---- 4: automation widget-click mutates the model --------------------------
echo "== open before click: $(grep -oE '[0-9]+ open' "$snap" | head -1)"
add_id=$(snapshot_match 'widget @w1/inbox-canvas#[0-9]* role=button name="Add task"' \
  | grep -o '#[0-9]*' | tr -d '#')
[ -n "$add_id" ] || fail "Add task button not found in snapshot"
"$cli" automate widget-click inbox-canvas "$add_id" || fail "CLI widget-click failed"
poll 30 '4 open' || fail "widget-click did not reach '4 open'"
echo "== open after click: $(grep -oE '[0-9]+ open' "$snap" | head -1)"

# ---- 5: real X11 input through the Win32 path ------------------------------
# Root-coordinate math. Hidden-titlebar windows keep the full overlapped
# frame and reclaim the caption band through WM_NCCALCSIZE, so the Win32
# client area starts at the very top of the window. Under a WM-less Wine
# the X11 driver still places (and reports) the client X window at the
# DEFAULT frame offset - one caption band lower - so the X origin sits a
# band BELOW where Win32 client coordinates actually map, and the reported
# X height is short by exactly that band (measured: X window 718x489 at
# y=30 for a 718x519 client whose clicks land at y=0). The snapshot knows
# the true client height, so the height shortfall IS the y correction; a
# standard-frame window reports matching heights and corrects by zero.
win=""
for w in $(xdotool search --name "." 2>/dev/null); do
  case "$(xdotool getwindowname "$w" 2>/dev/null)" in
    *[Ii]nbox*) win="$w" ;;
  esac
done
[ -n "$win" ] || fail "app X window not found"
eval "$(xdotool getwindowgeometry --shell "$win")"
# The runtime rewrites snapshot.txt on every presented frame. Retry the
# extraction instead of treating a read that lands between truncate and
# write as a standard-frame window: that fallback erases the 30px Wine
# caption correction and turns the real-input receipt into a flaky miss.
client_line=$(snapshot_match 'window @w1 "[^"]*" bounds=([^)]*)')
[ -n "$client_line" ] || fail "could not read client bounds from snapshot"
client_h=$(printf '%s\n' "$client_line" | sed -n 's/.*x\([0-9]*\)[^x]*$/\1/p')
[ -n "$client_h" ] || fail "could not read client height from snapshot"
y_off=$((client_h - HEIGHT))
[ "$y_off" -ge 0 ] 2>/dev/null || y_off=0
echo "== x window $win: pos=($X,$Y) size=${WIDTH}x${HEIGHT} client_h=$client_h y_off=$y_off"
xdotool windowactivate "$win" >/dev/null 2>&1 || xdotool windowfocus "$win" >/dev/null 2>&1

draft_line=$(snapshot_match 'widget @w1/inbox-canvas#[0-9]* role=textbox[^|]*')
[ -n "$draft_line" ] || fail "draft textbox not found in snapshot"
bounds=$(echo "$draft_line" | grep -o 'bounds=([^)]*)')
bx=$(echo "$bounds" | sed -n 's/bounds=(\([0-9.]*\),.*/\1/p')
by=$(echo "$bounds" | sed -n 's/bounds=([0-9.]*,\([0-9.]*\) .*/\1/p')
bw=$(echo "$bounds" | sed -n 's/.* \([0-9.]*\)x[0-9.]*).*/\1/p')
bh=$(echo "$bounds" | sed -n 's/.* [0-9.]*x\([0-9.]*\)).*/\1/p')
[ -n "$bx" ] && [ -n "$by" ] && [ -n "$bw" ] && [ -n "$bh" ] || fail "could not parse draft bounds: $draft_line"
cx=$(awk "BEGIN{printf \"%d\", $X + $bx + $bw / 2}")
cy=$(awk "BEGIN{printf \"%d\", $Y - $y_off + $by + $bh / 2}")
echo "== clicking draft field $bounds at ($cx,$cy)"
xdotool mousemove "$cx" "$cy" click 1
# The click must move widget focus into the textbox before any keys are
# sent: spaces in the typed string would otherwise activate whatever
# widget held focus (a button press adds a task and the real failure -
# input landing in the wrong widget - would read as missing text).
poll 10 'role=textbox[^|]*focused=true' || fail "draft textbox did not take focus from the click"
sleep 1
xdotool type --delay 120 "hi from wine"
poll 30 'hi from wine' || fail "typed text never appeared in the snapshot"
echo "== draft after typing: $(grep -o 'widget @w1/inbox-canvas#[0-9]* role=textbox[^|]*' "$snap" | head -1 | cut -c1-160)"
echo "== input latency: $(grep -o 'gpu_input_latency_ns=[0-9]*' "$snap" | head -1)"

echo "PASS: windows canvas smoke"
exit 0
