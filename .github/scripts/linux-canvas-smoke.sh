#!/usr/bin/env bash
# Linux canvas smoke under Xvfb — run on a machine with NO WebKitGTK dev
# package, which makes the build itself the native-only link test.
#
# Exercises the Linux gpu_surface software path without a display server:
# builds examples/ui-inbox (a native-only app, so its GTK host compiles
# with the WebKitGTK stub seam and never links webkitgtk-6.0) with
# -Dplatform=linux -Dweb-engine=system -Dautomation=true, runs it under
# Xvfb, and asserts against the automation snapshot:
#
#   1. the built ELF carries no WebKitGTK reference (no libwebkitgtk
#      DT_NEEDED entry, no webkit_/jsc_ dynamic symbol), audited on the
#      real binary by tools/audit_web_layer.zig
#   2. snapshot ready=true            (app booted, automation server live)
#   3. gpu_backend=software           (the software present path is active)
#   4. gpu_nonblank=true              (real pixels were presented)
#   5. widget-click "Add task" -> '4 open'   (automation input mutates state)
#   6. a real X11 right-click opens a task row's declared context menu and
#      clicking its item dispatches the Msg ('1 done')
#   7. automate screenshot renders a non-empty PNG
#   8. ZERO WebKit helper processes for the whole run (a native-only app
#      has no web layer to boot WebKit with)
#
# Deliberately NOT `set -e` (same as windows-canvas-smoke.sh): grep exits 1
# on zero matches, and under `set -e` an assignment like `x=$(grep ...)` or
# a swallowed `$(cli 2>&1)` capture dies with NO output — this job failed
# three times with nothing in the log but the exit code. Every assertion
# goes through fail(), which dumps the snapshot and the app log.
set -u

# No WebKit sandbox workaround: a native-only app's host is compiled
# without the web layer entirely (and even in web builds the main
# WebView is lazy), so no WebKit helper processes start and the runner's
# user-namespace restrictions never come into play. The zero-WebKit
# assertion below keeps it that way.

# GTK_A11Y=none: under Xvfb there is no session bus providing org.a11y.Bus,
# and GTK4's a11y init blocks ~25 s on the GDBus name lookup before warning
# and continuing — the app's first runtime event landed after the readiness
# window had already expired (reproduced in a local container: without this
# the wait times out at startup; with it the full smoke passes).
# Accessibility is not what this smoke tests.
export GTK_A11Y="${GTK_A11Y:-none}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
app_dir="$repo_root/examples/ui-inbox"
snap="$app_dir/.zig-cache/native-sdk-automation/snapshot.txt"
cli="$repo_root/zig-out/bin/native"
app_log="${TMPDIR:-/tmp}/linux-canvas-smoke-app.log"

# Readiness budget. Even with GTK_A11Y=none, shared ubuntu-24.04 runners
# show a consistent ~27 s stall between EGL init and the app's first
# runtime event (measured in runs 28690855597 pass / 28691951139 fail —
# the SAME stall in both; the old hard 30 s `automate wait` window flipped
# green/red on one or two seconds of runner noise). Local containers show
# no stall at all. Widen the budget here instead of weakening the CLI
# default; every correctness assertion stays strict.
ready_timeout_ms=90000

app_pid=""
xvfb_pid=""
cleanup() {
  [ -n "$app_pid" ] && kill "$app_pid" >/dev/null 2>&1
  # Reap the app and our Xvfb directly so local runs exit clean (CI would
  # otherwise rely on the runner's orphan sweep).
  pkill -f "$app_dir/zig-out/bin/ui-inbox" >/dev/null 2>&1
  [ -n "$xvfb_pid" ] && kill "$xvfb_pid" >/dev/null 2>&1
}
trap cleanup EXIT

diagnostics() {
  echo "---- diagnostics ----"
  echo "-- snapshot ($snap):"
  if [ -f "$snap" ]; then tr '|' '\n' < "$snap" | sed 's/^/  /'; else echo "  (missing)"; fi
  echo "-- app log head ($app_log):"
  head -20 "$app_log" 2>/dev/null | sed 's/^/  /'
  echo "-- app log tail ($app_log):"
  tail -40 "$app_log" 2>/dev/null | sed 's/^/  /'
  # The X window list names what is actually on the glass — the context
  # menu popover is an override-redirect X window that never appears in
  # the automation snapshot, so this is the only record of whether it
  # (or anything else) was mapped when a step failed.
  echo "-- X windows (xwininfo -root -children):"
  if [ -n "${DISPLAY:-}" ] && command -v xwininfo >/dev/null 2>&1; then
    xwininfo -root -children 2>/dev/null | sed 's/^/  /'
  else
    echo "  (no DISPLAY or xwininfo not installed)"
  fi
  echo "---------------------"
}

# The hex ids of every child of the root window, popovers included
# (override-redirect windows never pass through a window manager — Xvfb
# has none anyway — but they are always children of the root).
x_window_ids() {
  xwininfo -root -children 2>/dev/null | grep -oE '0x[0-9a-f]+'
}

fail() {
  echo "FAIL: $1"
  diagnostics
  exit 1
}

# Canvas apps must never spawn WebKit: the window's main WebView is
# created lazily and nothing in this app materializes it, so any
# WebKitWebProcess/WebKitNetworkProcess during the run means an eager
# creation regressed (and with it launch latency, resident helper
# processes, and the sandbox trouble this smoke used to work around).
assert_no_webkit() {
  local helpers
  helpers=$(pgrep -af 'WebKit(Web|Network)Process' 2>/dev/null)
  if [ -n "$helpers" ]; then
    echo "-- WebKit helper processes found ($1):"
    echo "$helpers" | sed 's/^/  /'
    fail "canvas app spawned WebKit processes ($1)"
  fi
}

# ---- build ----------------------------------------------------------------
(cd "$repo_root" && zig build) || fail "root zig build (CLI) failed"
(cd "$app_dir" && zig build -Dplatform=linux -Dweb-engine=system -Dautomation=true) \
  || fail "ui-inbox Linux build failed (a native-only app must build without the WebKitGTK dev package)"

# ---- 1: the native-only ELF carries no WebKitGTK reference -----------------
(cd "$repo_root" && zig run tools/audit_web_layer.zig -- "$app_dir/zig-out/bin/ui-inbox" absent) \
  || fail "native-only ELF audit failed (the binary references WebKitGTK)"
echo "== native-only ELF audit ok"

# ---- launch ---------------------------------------------------------------
# The script owns its Xvfb (instead of wrapping the app in xvfb-run) so
# the xdotool step below shares the app's display. -displayfd picks a
# free display number, the modern equivalent of xvfb-run -a's probing.
display_file="$(mktemp)"
Xvfb -displayfd 4 -screen 0 1280x800x24 4>"$display_file" &
xvfb_pid=$!
for _ in $(seq 1 100); do
  [ -s "$display_file" ] && break
  sleep 0.1
done
[ -s "$display_file" ] || fail "Xvfb never reported a display number"
export DISPLAY=":$(cat "$display_file")"
echo "== Xvfb on $DISPLAY"

cd "$app_dir" || fail "missing $app_dir"
rm -rf .zig-cache/native-sdk-automation
"$app_dir/zig-out/bin/ui-inbox" > "$app_log" 2>&1 &
app_pid=$!

# ---- 2: automation snapshot becomes ready ---------------------------------
# `automate assert` self-reports on timeout (missing patterns + snapshot
# tail) and prints the measured latency on success, so green logs carry
# the readiness margin.
"$cli" automate assert --timeout-ms "$ready_timeout_ms" 'ready=true' \
  || fail "snapshot never became ready"

# ---- 3 + 4: software backend presented non-blank pixels --------------------
"$cli" automate assert --timeout-ms 30000 'gpu_nonblank=true' \
  || fail "gpu_nonblank never became true"
grep -q 'gpu_backend=software' "$snap" || fail "gpu_backend is not software"
echo "== canvas: $(grep -o 'gpu_backend=[a-z]*' "$snap" | head -1)" \
  "$(grep -o 'gpu_nonblank=[a-z]*' "$snap" | head -1)"
assert_no_webkit "after first presented frame"
echo "== zero WebKit processes after first presented frame"

# ---- 5: automation widget-click mutates the model --------------------------
echo "== open before click: $(grep -oE '[0-9]+ open' "$snap" | head -1)"
add_id=$(grep -o 'widget @w1/inbox-canvas#[0-9]* role=button name="Add task"' "$snap" \
  | grep -o '#[0-9]*' | tr -d '#')
[ -n "$add_id" ] || fail "Add task button not found in snapshot"
"$cli" automate widget-click inbox-canvas "$add_id" || fail "CLI widget-click failed"
"$cli" automate assert --timeout-ms 30000 '4 open' \
  || fail "widget-click did not reach '4 open'"
echo "== open after click: $(grep -oE '[0-9]+ open' "$snap" | head -1)"

# ---- 6: a real right-click opens and drives a task-row context menu --------
# What this proves: an X-level SECONDARY-button press (GDK button 3)
# travels the whole GTK path — click gesture -> button mapping -> runtime
# secondary check -> declared-menu lookup -> native popover — and
# clicking the popover's "Toggle done" item dispatches the row's Msg,
# observable as the model change '1 done' in the snapshot (the popover
# itself is an OS surface and never appears in the snapshot, so the
# dispatched selection is the provable signal).
# The menu is driven by POINTER, never keyboard: under Xvfb there is no
# window manager, so the popover's X window never receives keyboard
# focus and `xdotool key Down/Return` dies on the canvas beneath it —
# but pointer events resolve by position (and the popover holds the
# pointer grab), so a click on the popover surface reaches the item. The
# popover is an override-redirect X window of its own: it is found by
# diffing the root's children across the right-click, and because the
# row declares exactly one item and the popover draws no arrow, the
# center of that new window IS "Toggle done".
# Regression coverage: the swapped GDK button mapping this smoke was
# blind to made every right-click arrive as MIDDLE and never open the
# menu — under that defect the popover window never appears and the
# step fails at the popover lookup, before any selection.
# Limit: '1 done' proves the toggle Msg dispatched; it cannot attribute
# the dispatch to the popover VISUALLY (no snapshot record of the OS
# menu), but the click lands on the popover's own X window, so no
# canvas-level path can consume it — the canvas never sees the press.
echo "== done before right-click: $(grep -oE '[0-9]+ done' "$snap" | head -1)"
row_line=$(grep -o 'widget @w1/inbox-canvas#[0-9]*[^|]*context_menu=\["Toggle done"\][^|]*' "$snap" | head -1)
[ -n "$row_line" ] || fail "no task row with the declared context menu in snapshot"
bounds=$(echo "$row_line" | grep -o 'bounds=([^)]*)')
bx=$(echo "$bounds" | sed -n 's/bounds=(\([0-9.-]*\),.*/\1/p')
by=$(echo "$bounds" | sed -n 's/bounds=([0-9.-]*,\([0-9.-]*\) .*/\1/p')
bw=$(echo "$bounds" | sed -n 's/.* \([0-9.]*\)x[0-9.]*).*/\1/p')
bh=$(echo "$bounds" | sed -n 's/.* [0-9.]*x\([0-9.]*\)).*/\1/p')
[ -n "$bx" ] && [ -n "$by" ] && [ -n "$bw" ] && [ -n "$bh" ] || fail "could not parse row bounds: $row_line"
win=""
for w in $(xdotool search --name "Inbox" 2>/dev/null); do win="$w"; done
[ -n "$win" ] || fail "app X window not found"
eval "$(xdotool getwindowgeometry --shell "$win")"
# Xvfb has no compositor, so GTK draws no CSD shadow and the X window is
# exactly the client area; correct by the measured height difference the
# same way windows-canvas-smoke.sh does, in case a runner image ever
# composites.
client_h=$(grep -o 'window @w1 "[^"]*" bounds=([^)]*)' "$snap" | head -1 \
  | sed -n 's/.*x\([0-9]*\)[^x]*$/\1/p')
[ -n "$client_h" ] || client_h=$HEIGHT
y_off=$((HEIGHT - client_h))
[ "$y_off" -ge 0 ] 2>/dev/null || y_off=0
cx=$(awk "BEGIN{printf \"%d\", $X + $bx + $bw / 2}")
cy=$(awk "BEGIN{printf \"%d\", $Y + $y_off + $by + $bh / 2}")
xdotool windowactivate "$win" >/dev/null 2>&1 || xdotool windowfocus "$win" >/dev/null 2>&1
command -v xwininfo >/dev/null 2>&1 || fail "xwininfo not installed (x11-utils) — required to locate the popover's X window"
# xdotool reports decimal window ids, xwininfo hexadecimal; compare in hex.
win_hex=$(printf '0x%x' "$win")
pre_windows=" $(x_window_ids | tr '\n' ' ') "
echo "== right-clicking task row $bounds at ($cx,$cy)"
xdotool mousemove "$cx" "$cy" click 3
# Wait for the popover's X window: a viewable, non-trivial root child
# that did not exist before the right-click.
popover=""
popover_geom=""
for _ in $(seq 1 50); do
  # Root children list in stacking order (bottom to top): scan top-down
  # so the just-mapped popover wins over any other new surface.
  for w in $(x_window_ids | tac); do
    case "$pre_windows" in *" $w "*) continue ;; esac
    [ "$w" = "$win_hex" ] && continue
    geom=$(xwininfo -id "$w" 2>/dev/null)
    echo "$geom" | grep -q 'Map State: IsViewable' || continue
    pw=$(echo "$geom" | sed -n 's/^ *Width: *\([0-9]*\).*/\1/p')
    ph=$(echo "$geom" | sed -n 's/^ *Height: *\([0-9]*\).*/\1/p')
    [ -n "$pw" ] && [ -n "$ph" ] && [ "$pw" -gt 10 ] && [ "$ph" -gt 10 ] || continue
    popover="$w"
    popover_geom="$geom"
    break
  done
  [ -n "$popover" ] && break
  sleep 0.2
done
[ -n "$popover" ] || fail "context-menu popover X window never appeared after the right-click"
px=$(echo "$popover_geom" | sed -n 's/^ *Absolute upper-left X: *\(-*[0-9]*\).*/\1/p')
py=$(echo "$popover_geom" | sed -n 's/^ *Absolute upper-left Y: *\(-*[0-9]*\).*/\1/p')
pw=$(echo "$popover_geom" | sed -n 's/^ *Width: *\([0-9]*\).*/\1/p')
ph=$(echo "$popover_geom" | sed -n 's/^ *Height: *\([0-9]*\).*/\1/p')
[ -n "$px" ] && [ -n "$py" ] || fail "could not parse popover geometry for $popover"
mx=$((px + pw / 2))
my=$((py + ph / 2))
echo "== popover $popover at ${pw}x${ph}+${px}+${py}; clicking its only item at ($mx,$my)"
xdotool mousemove "$mx" "$my" click 1
"$cli" automate assert --timeout-ms 30000 '1 done' \
  || fail "right-click menu selection did not dispatch the toggle Msg ('1 done')"
echo "== done after menu selection: $(grep -oE '[0-9]+ done' "$snap" | head -1)"

# ---- 7: screenshot renders a non-empty PNG ---------------------------------
"$cli" automate screenshot inbox-canvas || fail "CLI screenshot failed"
test -s .zig-cache/native-sdk-automation/screenshot-inbox-canvas.png \
  || fail "screenshot PNG missing or empty"

# ---- 8: still zero WebKit processes at the end of the run -------------------
assert_no_webkit "at end of run"
echo "== zero WebKit processes at end of run"

echo "PASS: linux canvas smoke"
exit 0
