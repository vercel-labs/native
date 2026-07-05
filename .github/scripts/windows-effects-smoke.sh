#!/usr/bin/env bash
# Windows effects smoke under Wine.
#
# Exercises the effect system's live Windows path (src/runtime/effects.zig
# worker threads -> PostMessageW wake in src/platform/windows/
# webview2_host.cpp -> loop-thread drain) without Windows hardware:
# cross-compiles examples/effects-probe for x86_64-windows-gnu, runs the
# .exe under Xvfb + Wine, and asserts against the automation snapshot and
# the app's trace log:
#
#   1. snapshot ready=true                (app booted, automation server live)
#   2. gpu_backend=software + nonblank    (the canvas presented real pixels)
#   3. widget-click "Start stream"        (fx.spawn launches cmd.exe under
#                                          Wine; streamed lines land in the
#                                          model and grow the snapshot)
#   4. app log shows event=effects_wake   (the worker's PostMessageW wake was
#                                          marshalled through the message
#                                          loop -- the wake path itself, not
#                                          just the frame-tick drain)
#   5. widget-click "Cancel"              (fx.cancel terminates the child;
#                                          status shows "cancelled")
#   6. the line count freezes             (no lines arrive after cancel,
#                                          sampled across ~5 more would-be
#                                          line intervals)
#
# Known caveat: the timer present mode also drains effect completions on
# every frame tick (ui_app.zig handleFrame), so line delivery alone cannot
# isolate the wake; that is why step 4 checks the trace log for the wake
# events directly instead of inferring the wake from model updates.
#
# Deliberately NOT `set -e`: grep exits 1 on zero matches inside the poll
# loops, and we want explicit, diagnosable failures instead of silent early
# exits. Every assertion goes through fail(), which dumps diagnostics.
set -u

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
app_dir="$repo_root/examples/effects-probe"
snap="$app_dir/.zig-cache/native-sdk-automation/snapshot.txt"
cli="$repo_root/zig-out/bin/native"
app_log="${TMPDIR:-/tmp}/windows-effects-smoke-app.log"

# Wine needs an X display; when none is present (CI), re-exec the whole
# script under a private Xvfb server. The explicit screen size beats
# xvfb-run's 640x480x8 default: the app window is 560x480 and Wine wants a
# 24-bit visual.
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

# The status bar renders "{N} lines total · {M} dropped"; extract N.
total_lines() {
  grep -o '[0-9]* lines total' "$snap" 2>/dev/null | head -1 | grep -o '^[0-9]*'
}

# widget_id <name>: find a widget id in the snapshot by accessible name.
widget_id() {
  grep -o "widget @w1/probe-canvas#[0-9]* role=button name=\"$1\"" "$snap" \
    | grep -o '#[0-9]*' | tr -d '#'
}

# ---- build ----------------------------------------------------------------
(cd "$repo_root" && zig build) || fail "root zig build (CLI) failed"
# effects-probe is a zero-config app (app.zon + src, no build.zig): the CLI
# synthesizes its build graph. -Doptimize=Debug keeps the smoke binary at
# the debug shape (`native build` alone would inject ReleaseFast).
"$cli" build "$app_dir" -Dtarget=x86_64-windows-gnu -Dplatform=windows -Dweb-engine=system -Dautomation=true -Doptimize=Debug \
  || fail "effects-probe Windows cross-compile failed"

# ---- wineprefix -----------------------------------------------------------
start=$SECONDS
wineboot --init >/dev/null 2>&1
wineserver --wait >/dev/null 2>&1
echo "== wineprefix ready in $((SECONDS - start))s ($WINEPREFIX)"

# ---- launch ---------------------------------------------------------------
cd "$app_dir" || fail "missing $app_dir"
rm -rf .zig-cache/native-sdk-automation
mkdir -p .zig-cache/native-sdk-automation
wine zig-out/bin/effects-probe.exe > "$app_log" 2>&1 &
app_pid=$!

# ---- 1: automation snapshot becomes ready ---------------------------------
poll 180 'ready=true' || fail "snapshot never became ready"
echo "== ready: $(head -1 "$snap" | cut -d'|' -f1)"

# ---- 2: software backend presented non-blank pixels ------------------------
poll 60 'gpu_nonblank=true' || fail "gpu_nonblank never became true"
grep -q 'gpu_backend=software' "$snap" || fail "gpu_backend is not software"
echo "== canvas: $(grep -o 'gpu_backend=[a-z]*' "$snap" | head -1)" \
  "$(grep -o 'gpu_nonblank=[a-z]*' "$snap" | head -1)"
grep -q 'idle' "$snap" || fail "probe did not start idle"

# ---- 3: Start spawns the stream and lines arrive ---------------------------
start_id=$(widget_id "Start stream")
[ -n "$start_id" ] || fail "Start stream button not found in snapshot"
"$cli" automate widget-click probe-canvas "$start_id" || fail "CLI widget-click Start failed"
poll 30 'streaming:' || fail "status never showed streaming (spawn failed under Wine?)"
# The Windows stream paces ~1 line/s (cmd for /L + ping); wait for at
# least 2 visible lines so cancel provably interrupts an active stream.
poll 60 'stream line 2' || fail "stream lines never reached the model"
echo "== streaming: $(grep -o 'streaming: [0-9]* lines' "$snap" | head -1), status-bar: $(total_lines) lines total"

# ---- 4: the PostMessage wake path fired ------------------------------------
# handleFrame also drains completions on every frame tick, so lines in the
# model alone cannot isolate the wake. The runner's default -Dtrace=events
# sink prints every runtime event; effects_wake records prove the worker's
# PostMessageW -> kWakeMessage -> kWake -> .effects_wake marshalling ran.
grep -q 'event="effects_wake"' "$app_log" || fail "no effects_wake events in the app log (PostMessage wake never fired)"
echo "== effects_wake events so far: $(grep -c 'event="effects_wake"' "$app_log")"

# ---- 5: Cancel terminates the child ----------------------------------------
cancel_id=$(widget_id "Cancel")
[ -n "$cancel_id" ] || fail "Cancel button not found in snapshot"
"$cli" automate widget-click probe-canvas "$cancel_id" || fail "CLI widget-click Cancel failed"
poll 30 'cancelled: code' || fail "status never showed cancelled"
frozen=$(total_lines)
[ -n "$frozen" ] || fail "could not read line count after cancel"
echo "== cancelled at $frozen lines: $(grep -o 'cancelled: code [0-9-]* after [0-9]* lines' "$snap" | head -1)"

# ---- 6: the line count is frozen -------------------------------------------
# ~5 more lines would have arrived at the ~1s cadence if the child were
# still alive or queued lines were still draining.
sleep 6
after=$(total_lines)
[ "$after" = "$frozen" ] || fail "line count moved after cancel ($frozen -> $after)"
grep -q 'streaming:' "$snap" && fail "status went back to streaming after cancel"
echo "== count frozen at $after lines across 6s"

echo "PASS: windows effects smoke"
exit 0
