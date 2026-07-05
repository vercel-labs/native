#!/usr/bin/env bash
# Recon pass: build every showcase app for Linux, launch each under Xvfb,
# and dump its automation snapshot, widget inventory, log tail, and both
# screenshot channels to /out/<app>/. This is the discovery half of the
# loop; drive.sh replays real interaction scenarios on top of it.
set -u
source /src/tools/linux-truth/lib.sh

APPS="${APPS:-calculator notes soundboard markdown-viewer system-monitor gpu-dashboard deck feed kanban ui-inbox}"
OUT=/out
mkdir -p "$OUT"
start_xvfb

# The CLI drives every app build below (most showcase apps are zero-config:
# app.zon + src only, no build.zig — the CLI synthesizes their build graph
# into .native/build). Build it first; automation commands need it anyway.
echo "==== build native CLI ===="
(cd /work && zig build) >/tmp/cli-build.log 2>&1 || {
  echo "CLI BUILD FAIL"
  tail -30 /tmp/cli-build.log
  exit 1
}

for app in $APPS; do
  dir="/work/examples/$app"
  out="$OUT/$app"
  mkdir -p "$out"
  echo "==== $app ===="
  # -Doptimize=Debug: keep recon binaries at the debug shape (`native
  # build` alone would inject ReleaseFast).
  (cd "$dir" && "$CLI" build -Dplatform=linux -Dweb-engine=system -Dautomation=true -Doptimize=Debug) \
    >"$out/build.log" 2>&1
  if [ $? -ne 0 ]; then
    echo "BUILD FAIL"
    tail -30 "$out/build.log"
    echo "build=FAIL" > "$out/status.txt"
    continue
  fi
  echo "build=OK" > "$out/status.txt"
  cd "$dir" || continue
  bin="zig-out/bin/$app"
  [ -x "$bin" ] || bin=$(ls zig-out/bin/* 2>/dev/null | head -1)
  if ! launch_app "$bin" 30000; then
    echo "launch=FAIL" >> "$out/status.txt"
    cp /tmp/app.log "$out/app.log" 2>/dev/null
    stop_app
    continue
  fi
  echo "launch=OK" >> "$out/status.txt"
  sleep 2
  snapshot_lines > "$out/snapshot.txt"
  grep -o 'widget @w1/[^#]*#[0-9]* role=[a-z]* name="[^"]*"' "$out/snapshot.txt" > "$out/widgets.txt"
  grep -o 'view @w1/[^ ]* kind=[a-z_]*' "$out/snapshot.txt" > "$out/views.txt"
  grep -o 'runtime_uptime_ns=[0-9]*' "$out/snapshot.txt" | head -1 >> "$out/status.txt"
  grep -o 'dispatch_errors=[0-9]*' "$out/snapshot.txt" | head -1 >> "$out/status.txt"
  grep -o 'gpu_backend=[a-z]*' "$out/snapshot.txt" | head -1 >> "$out/status.txt"
  grep -o 'gpu_nonblank=[a-z]*' "$out/snapshot.txt" | head -1 >> "$out/status.txt"
  canvas=$(sed -n 's|.*view @w1/\([^ ]*\) kind=gpu_surface.*|\1|p' "$out/views.txt" | head -1)
  [ -n "$canvas" ] && shot "$canvas" "$out/engine.png"
  xshot "$out/x11.png"
  cp /tmp/app.log "$out/app.log" 2>/dev/null
  stop_app
  echo "done"
done
echo "recon complete"
