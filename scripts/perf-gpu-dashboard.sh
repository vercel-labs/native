#!/bin/sh
# Percentile GPU performance check for examples/gpu-dashboard.
#
# The single-launch smoke (test-gpu-dashboard-smoke) proves correctness with one
# load-tolerant latency sample; this harness measures a distribution:
#
#   1. Cold start: launches the automation build N times (NATIVE_SDK_PERF_LAUNCHES,
#      default 5), recording gpu_first_frame_latency_ns from the automation
#      snapshot for each launch.
#   2. Steady state: on the final (warm) launch, drives M "Auto refresh" switch
#      clicks (NATIVE_SDK_PERF_INTERACTIONS, default 5), recording gpu_input_latency_ns
#      (input receipt -> first present) per interaction.
#   3. Prints every sample plus min/median/p90/max per series, and asserts each
#      series' p90 under its budget:
#        NATIVE_SDK_PERF_BUDGET_MS        first-frame p90 budget, default 300
#        NATIVE_SDK_PERF_INPUT_BUDGET_MS  input-latency p90 budget, default 100
#      Defaults are deliberately generous (2x+ the smoke's 150 ms first-frame
#      budget): this check exists to catch step-function regressions on shared
#      CI/dev machines, not 10% drift on an idle box.
#
# p90 is nearest-rank: sorted[ceil(0.9 * n)]. At the default n=5 that IS the
# maximum of the five samples — with five samples the nearest-rank 90th
# percentile estimator selects the max, so "max of 5 under a generous budget"
# is not a shortcut but the estimator itself; raising NATIVE_SDK_PERF_LAUNCHES past 9
# starts discarding the worst outlier as expected.
#
# Usage: scripts/perf-gpu-dashboard.sh <native-sdk-cli>
# Expects examples/gpu-dashboard already built with -Dautomation=true
# (`zig build test-gpu-dashboard-perf` wires the build + this script).
set -eu

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cli="${1:?usage: scripts/perf-gpu-dashboard.sh <native-sdk-cli>}"
case "$cli" in /*) ;; *) cli="$repo_root/$cli" ;; esac
cd "$repo_root/examples/gpu-dashboard"
app="zig-out/bin/gpu-dashboard"
[ -x "$app" ] || { echo "perf: $app is missing; build examples/gpu-dashboard with -Dautomation=true first" >&2; exit 1; }
automation_dir=".zig-cache/native-sdk-automation"
mkdir -p "$automation_dir"
log=".zig-cache/native-sdk-gpu-dashboard-perf.log"

require_positive_int() { # name value
  case "$2" in ''|*[!0-9]*) echo "perf: $1 must be a positive integer: $2" >&2; exit 1 ;; esac
  [ "$2" -gt 0 ] || { echo "perf: $1 must be a positive integer: $2" >&2; exit 1; }
}

launches="${NATIVE_SDK_PERF_LAUNCHES:-5}"
interactions="${NATIVE_SDK_PERF_INTERACTIONS:-5}"
first_frame_budget_ms="${NATIVE_SDK_PERF_BUDGET_MS:-300}"
input_budget_ms="${NATIVE_SDK_PERF_INPUT_BUDGET_MS:-100}"
require_positive_int NATIVE_SDK_PERF_LAUNCHES "$launches"
require_positive_int NATIVE_SDK_PERF_INTERACTIONS "$interactions"
require_positive_int NATIVE_SDK_PERF_BUDGET_MS "$first_frame_budget_ms"
require_positive_int NATIVE_SDK_PERF_INPUT_BUDGET_MS "$input_budget_ms"
first_frame_budget_ns=$((first_frame_budget_ms * 1000000))
input_budget_ns=$((input_budget_ms * 1000000))

dump_diagnostics() { # failure forensics for shared CI runners: app log + canvas line
  echo "---- app log ($log) ----" >&2
  cat "$log" >&2 2>/dev/null || true
  echo "---- dashboard-canvas snapshot line ----" >&2
  read_snapshot
  printf '%s\n' "$snapshot" | grep 'view @w1/dashboard-canvas' >&2 || echo "(no dashboard-canvas line in snapshot)" >&2
}

pid=""
trap 'kill "$pid" >/dev/null 2>&1 || true; wait "$pid" >/dev/null 2>&1 || true' EXIT
stop_app() {
  kill "$pid" >/dev/null 2>&1 || true
  wait "$pid" >/dev/null 2>&1 || true
  pid=""
}

read_snapshot() {
  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
}

canvas_field() { # field-name -> value of gpu_<field>=N on the dashboard-canvas line, or empty
  printf '%s\n' "$snapshot" | sed -n "s/.*view @w1\\/dashboard-canvas kind=gpu_surface.* $1=\\([0-9][0-9]*\\).*/\\1/p"
}

ns_to_ms() { # ns -> ms with one decimal
  awk "BEGIN { printf \"%.1f\", $1 / 1000000 }"
}

launch_and_measure_first_frame() {
  rm -f "$automation_dir/snapshot.txt" "$automation_dir/accessibility.txt" "$automation_dir/windows.txt" "$automation_dir/command.txt"
  "$app" > "$log" 2>&1 &
  pid=$!
  ready="$("$cli" automate wait 2>&1)"
  case "$ready" in *"ready=true"*) ;; *) echo "perf: gpu-dashboard automation snapshot was not ready" >&2; dump_diagnostics; exit 1 ;; esac
  first_frame_latency=""
  attempts=0
  while [ "$attempts" -lt 100 ]; do
    read_snapshot
    case "$snapshot" in
      *'view @w1/dashboard-canvas kind=gpu_surface'*'gpu_nonblank=true'*)
        first_frame_latency="$(canvas_field gpu_first_frame_latency_ns)"
        case "$first_frame_latency" in ''|*[!0-9]*|0) ;; *) return 0 ;; esac
        ;;
    esac
    attempts=$((attempts + 1))
    sleep 0.1
  done
  echo "perf: dashboard GPU first frame latency was not recorded within 10s" >&2
  dump_diagnostics
  exit 1
}

# ---- series bookkeeping -----------------------------------------------------

first_frame_samples=""
input_samples=""

append_sample() { # list-var-name value
  eval "current=\$$1"
  if [ -z "$current" ]; then eval "$1=\$2"; else eval "$1=\"\$current
\$2\""; fi
}

p90_rank() { # n -> nearest-rank index for p90: ceil(0.9 * n)
  echo $(( (9 * $1 + 9) / 10 ))
}

series_stat() { # newline-list rank -> value at 1-based rank of ascending sort
  printf '%s\n' "$1" | sort -n | sed -n "${2}p"
}

report_series() { # label list budget_ns budget_ms -> prints summary, returns 1 on p90 overrun
  label="$1"; list="$2"; budget_ns="$3"; budget_ms="$4"
  n="$(printf '%s\n' "$list" | wc -l | tr -d ' ')"
  rank="$(p90_rank "$n")"
  min="$(series_stat "$list" 1)"
  median="$(series_stat "$list" $(( (n + 1) / 2 )))"
  p90="$(series_stat "$list" "$rank")"
  max="$(series_stat "$list" "$n")"
  echo "perf: $label summary over $n samples: min $(ns_to_ms "$min") ms, median $(ns_to_ms "$median") ms, p90 $(ns_to_ms "$p90") ms, max $(ns_to_ms "$max") ms (budget $budget_ms ms)"
  if [ "$p90" -gt "$budget_ns" ]; then
    echo "perf: $label p90 exceeded the $budget_ms ms budget: $p90 ns ($(ns_to_ms "$p90") ms)" >&2
    return 1
  fi
  return 0
}

# ---- cold start: N launches, first-frame latency ----------------------------

i=1
while [ "$i" -le "$launches" ]; do
  launch_and_measure_first_frame
  append_sample first_frame_samples "$first_frame_latency"
  echo "perf: first-frame sample $i/$launches: $first_frame_latency ns ($(ns_to_ms "$first_frame_latency") ms)"
  if [ "$i" -lt "$launches" ]; then stop_app; fi
  i=$((i + 1))
done

# ---- steady state: M widget clicks on the final (warm) launch ---------------
# Each click of the "Auto refresh" switch requests a GPU frame; the runtime
# records gpu_input_latency_ns = input receipt -> first present that consumed
# it. A sample is ready once the snapshot shows this click's input timestamp
# AND a frame timestamp at/after it (that frame is what recorded the latency).

read_snapshot
prev_input_ts="$(canvas_field gpu_input_timestamp_ns)"
case "$prev_input_ts" in ''|*[!0-9]*) prev_input_ts=0 ;; esac

i=1
while [ "$i" -le "$interactions" ]; do
  read_snapshot
  switch_id="$(printf '%s\n' "$snapshot" | sed -n 's/.*widget @w1\/dashboard-canvas#\([0-9][0-9]*\) role=switch name="Auto refresh".*/\1/p' | head -1)"
  case "$switch_id" in ''|*[!0-9]*) echo "perf: dashboard auto refresh switch id was missing from snapshot" >&2; exit 1 ;; esac
  "$cli" automate widget-click dashboard-canvas "$switch_id" >/dev/null 2>&1
  input_latency=""
  attempts=0
  # 200 x 50ms nominal; each iteration also spawns several subprocesses, so
  # the real window is 2-4x longer on a loaded shared runner. That headroom
  # only delays a genuine failure — a healthy click lands in a few frames.
  while [ "$attempts" -lt 200 ]; do
    read_snapshot
    input_ts="$(canvas_field gpu_input_timestamp_ns)"
    frame_ts="$(canvas_field gpu_timestamp_ns)"
    case "$input_ts" in ''|*[!0-9]*) input_ts=0 ;; esac
    case "$frame_ts" in ''|*[!0-9]*) frame_ts=0 ;; esac
    if [ "$input_ts" -gt "$prev_input_ts" ] && [ "$frame_ts" -ge "$input_ts" ]; then
      input_latency="$(canvas_field gpu_input_latency_ns)"
      case "$input_latency" in ''|*[!0-9]*|0) input_latency="" ;; *) break ;; esac
    fi
    attempts=$((attempts + 1))
    sleep 0.05
  done
  if [ -z "$input_latency" ]; then
    echo "perf: widget-click $i did not produce a presented frame with recorded input latency within the wait window" >&2
    dump_diagnostics
    exit 1
  fi
  prev_input_ts="$input_ts"
  append_sample input_samples "$input_latency"
  echo "perf: input-latency sample $i/$interactions: $input_latency ns ($(ns_to_ms "$input_latency") ms)"
  i=$((i + 1))
done

stop_app

# ---- summary + assertions ---------------------------------------------------

failures=0
report_series "first-frame latency" "$first_frame_samples" "$first_frame_budget_ns" "$first_frame_budget_ms" || failures=$((failures + 1))
report_series "input latency" "$input_samples" "$input_budget_ns" "$input_budget_ms" || failures=$((failures + 1))
[ "$failures" -eq 0 ] || exit 1
echo "gpu-dashboard perf ok"
