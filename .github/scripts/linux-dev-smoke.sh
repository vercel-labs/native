#!/usr/bin/env bash
# Linux DEBUG-scaffold smoke under Xvfb — the `native dev` shape, pinned.
#
# The linux-canvas-smoke job builds at the graph's release default, and
# Release builds always use the LLVM backend — so a Debug-only x86_64
# codegen fault can pass every release-shaped CI lane and still crash the
# very first thing a new user runs (`native init` + `native dev` builds
# Debug). This smoke is the receipt for that gap: it scaffolds the ts-core
# template with the CLI (the `native init` default), builds it exactly as
# the dev loop does (-Doptimize=Debug), runs it headless, and requires the
# startup scene to actually come up — app_start, scene load, the
# gpu_surface shell view created through the GTK host's C seam, and real
# presented pixels. The original failure this pins: zig 0.16.0's
# self-hosted x86_64 backend (the Debug default without use_llvm) shifts
# the stack-passed arguments of `native_sdk_gtk_create_view`, so the host
# read a garbage `role` pointer and segfaulted before the first frame.
#
# Deliberately NOT `set -e` (same reasoning as linux-canvas-smoke.sh):
# every assertion goes through fail(), which dumps the snapshot and the
# app log instead of dying silently on a swallowed capture.
set -u

# GTK_A11Y=none: under Xvfb there is no session bus providing org.a11y.Bus,
# and GTK4's a11y init blocks ~25 s before continuing (see
# linux-canvas-smoke.sh, which measured it). Accessibility is not what
# this smoke tests.
export GTK_A11Y="${GTK_A11Y:-none}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cli="$repo_root/zig-out/bin/native"
work_dir="${TMPDIR:-/tmp}/native-linux-dev-smoke"
app_name="dev-smoke"
app_dir="$work_dir/$app_name"
snap="$app_dir/.zig-cache/native-sdk-automation/snapshot.txt"
app_log="${TMPDIR:-/tmp}/linux-dev-smoke-app.log"

# Same widened cold-start readiness budget as linux-canvas-smoke.sh:
# shared runners stall tens of seconds before the first runtime event.
ready_timeout_ms=90000

app_pid=""
cleanup() {
  [ -n "$app_pid" ] && kill "$app_pid" >/dev/null 2>&1
  pkill -f "$app_dir/zig-out/bin/$app_name" >/dev/null 2>&1
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

# ---- build the CLI ---------------------------------------------------------
(cd "$repo_root" && zig build) || fail "root zig build (CLI) failed"

# ---- scaffold the default template (ts-core, native frontend) --------------
rm -rf "$work_dir"
mkdir -p "$work_dir" || fail "cannot create $work_dir"
(cd "$work_dir" && "$cli" init "$app_name" --framework "$repo_root") \
  || fail "native init failed"

# ---- build the app the way the dev loop does (Debug) ------------------------
# `native build` forwards -D flags to the generated graph verbatim;
# -Doptimize=Debug pins the exact mode `native dev` uses, and
# -Dautomation=true arms the snapshot publisher this smoke asserts on.
(cd "$app_dir" && "$cli" build -Doptimize=Debug -Dautomation=true) \
  || fail "Debug scaffold build failed"

# ---- launch headless --------------------------------------------------------
cd "$app_dir" || fail "missing $app_dir"
rm -rf .zig-cache/native-sdk-automation
xvfb-run -a "$app_dir/zig-out/bin/$app_name" > "$app_log" 2>&1 &
app_pid=$!

# ---- startup scene reached the host: ready, then presented pixels ----------
# ready=true alone proves the crash site passed: the snapshot publishes
# only after app_start dispatched and the scene's shell views (the
# gpu_surface view with its role/accessibility strings) were created
# through native_sdk_gtk_create_view.
"$cli" automate assert --timeout-ms "$ready_timeout_ms" 'ready=true' \
  || fail "snapshot never became ready (startup scene did not come up)"
"$cli" automate assert --timeout-ms 30000 'gpu_nonblank=true' \
  || fail "gpu_nonblank never became true"

# ---- the template's UI actually built over the scene ------------------------
"$cli" automate assert --timeout-ms 30000 'role=button name="Reset"' 'total: 0' \
  || fail "template widgets missing from the snapshot"

echo "PASS: linux dev smoke (Debug scaffold booted its startup scene)"
exit 0
