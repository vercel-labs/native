#!/usr/bin/env bash
# Shared helpers for driving automation-enabled showcase apps on Linux
# under Xvfb. Sourced by the per-app drive scripts and run-all.sh; runs
# INSIDE the container (see Dockerfile), never on the host.
#
# Transport: the app (built with -Dautomation=true) publishes
# .zig-cache/native-sdk-automation/snapshot.txt and consumes a bounded
# queue of command-<n>.txt entries, oldest first, DELETING each entry as
# its consumption ack. The CLI already waits for its own entry's
# deletion before exiting; wait_done below is the belt-and-braces check
# that the whole queue drained.

CLI=/work/zig-out/bin/native
# :77 avoids colliding with any xvfb-run-owned :99 from ad-hoc runs.
DISPLAY_NUM=:77
AUTOMATION_DIR=.zig-cache/native-sdk-automation
SNAP="$AUTOMATION_DIR/snapshot.txt"

# One shared Xvfb with access control off so xwd can capture the root
# window without the per-run cookie dance xvfb-run would require.
start_xvfb() {
  if ! xdpyinfo -display "$DISPLAY_NUM" >/dev/null 2>&1; then
    Xvfb "$DISPLAY_NUM" -ac -screen 0 1600x1000x24 >/tmp/xvfb.log 2>&1 &
    for _ in $(seq 1 50); do
      xdpyinfo -display "$DISPLAY_NUM" >/dev/null 2>&1 && break
      sleep 0.1
    done
  fi
  export DISPLAY="$DISPLAY_NUM"
}

APP_PID=""

# launch_app <binary> [ready-timeout-ms] — clear the dropbox, start the
# app on the shared display, wait for the automation snapshot.
launch_app() {
  local bin="$1" timeout="${2:-30000}"
  # A straggler from an earlier run would keep publishing snapshots into
  # its own dropbox and steal the display's focus truth; clear the field.
  # Kill by exact process name (comm), never by command-line pattern: a
  # pattern like the binary's path also matches the CALLING shell when
  # the script text mentions it, and the sweep would kill its own driver.
  for app_bin in /work/examples/*/zig-out/bin/*; do
    [ -x "$app_bin" ] && pkill -KILL -x "$(basename "$app_bin")" 2>/dev/null
  done
  rm -rf "$AUTOMATION_DIR"
  "$bin" >/tmp/app.log 2>&1 &
  APP_PID=$!
  "$CLI" automate assert --timeout-ms "$timeout" 'ready=true' >/dev/null || {
    echo "LAUNCH FAIL: snapshot never ready"
    tail -20 /tmp/app.log
    return 1
  }
}

stop_app() {
  [ -n "$APP_PID" ] && kill "$APP_PID" >/dev/null 2>&1
  wait "$APP_PID" 2>/dev/null
  APP_PID=""
}

# Pacing: block until the app has consumed every queued command (the
# app deletes each command-<n>.txt entry as it consumes it, so an empty
# queue means everything dispatched).
wait_done() {
  for _ in $(seq 1 200); do
    if ! ls "$AUTOMATION_DIR"/command-*.txt >/dev/null 2>&1; then return 0; fi
    sleep 0.05
  done
  echo "WARN: command queue not drained within 10s"
  return 1
}

# send <automate-subcommand...> — queue one command and wait for consumption.
send() {
  "$CLI" automate "$@" >/dev/null || { echo "WARN: send $* failed"; return 1; }
  wait_done
}

snapshot_lines() { tr '|' '\n' < "$SNAP"; }

# widget_id <canvas> <role> <name> — resolve a widget id from the snapshot.
# Retries briefly: the app rewrites snapshot.txt on every published frame
# (constantly, while an animation runs), so a single read can catch a
# partially written file.
widget_id() {
  local id
  for _ in $(seq 1 20); do
    id=$(snapshot_lines \
      | grep -o "widget @w1/$1#[0-9]* role=$2 name=\"$3\"" \
      | head -1 | grep -o '#[0-9]*' | tr -d '#')
    [ -n "$id" ] && { echo "$id"; return 0; }
    sleep 0.1
  done
  return 1
}

# click <canvas> <role> <name>
click() {
  local id
  id=$(widget_id "$1" "$2" "$3")
  [ -n "$id" ] || { echo "WARN: widget $2 \"$3\" not found on $1"; return 1; }
  send widget-click "$1" "$id"
}

# expect <pattern> [timeout-ms] — assert the snapshot reaches a state.
expect() {
  "$CLI" automate assert --timeout-ms "${2:-10000}" "$1" >/dev/null 2>&1 \
    && echo "ok: $1" || { echo "MISS: $1"; return 1; }
}

# shot <canvas-label> <out.png> — engine screenshot (platform-honest pixels).
shot() {
  send screenshot "$1" || return 1
  local name="$AUTOMATION_DIR/screenshot-$1.png"
  for _ in $(seq 1 100); do [ -s "$name" ] && break; sleep 0.05; done
  cp "$name" "$2" 2>/dev/null || echo "WARN: engine screenshot $1 missing"
}

# xshot <out.png> — X-root capture (window chrome included).
xshot() {
  xwd -display "$DISPLAY_NUM" -root -silent | convert xwd:- "$1" 2>/dev/null \
    || echo "WARN: xwd capture failed"
}
