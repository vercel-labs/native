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
#   6. automate screenshot renders a non-empty PNG
#   7. ZERO WebKit helper processes for the whole run (a native-only app
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
cleanup() {
  [ -n "$app_pid" ] && kill "$app_pid" >/dev/null 2>&1
  # xvfb-run does not forward signals to an already-detached app; reap the
  # app and its Xvfb directly so local runs exit clean (CI would otherwise
  # rely on the runner's orphan sweep).
  pkill -f "$app_dir/zig-out/bin/ui-inbox" >/dev/null 2>&1
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
  echo "---------------------"
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
cd "$app_dir" || fail "missing $app_dir"
rm -rf .zig-cache/native-sdk-automation
xvfb-run -a "$app_dir/zig-out/bin/ui-inbox" > "$app_log" 2>&1 &
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

# ---- 6: screenshot renders a non-empty PNG ---------------------------------
"$cli" automate screenshot inbox-canvas || fail "CLI screenshot failed"
test -s .zig-cache/native-sdk-automation/screenshot-inbox-canvas.png \
  || fail "screenshot PNG missing or empty"

# ---- 7: still zero WebKit processes at the end of the run -------------------
assert_no_webkit "at end of run"
echo "== zero WebKit processes at end of run"

echo "PASS: linux canvas smoke"
exit 0
