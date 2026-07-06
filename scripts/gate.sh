#!/usr/bin/env bash
# Tiered local gate for the Native SDK.
#
#   scripts/gate.sh fast [base-ref]                  # affected-only: what your diff touches
#   scripts/gate.sh full [base-ref] [--all] [--perf] # everything CI-shaped that runs locally
#
# fast — root `zig build test` + `zig build validate`, plus the suites for
# the examples AFFECTED by your diff against base-ref (default: main). The
# diff is `git diff --name-only` against `git merge-base base-ref HEAD`,
# plus untracked files, so uncommitted work counts. Framework diffs on
# macOS additionally run the render-benchmark budget ratchet (see below).
#
# Path -> step mapping (fast tier):
#   src/**, build.zig, build.zig.zon, build/**,
#   tools/**, tests/**, assets/**              -> framework change: root suites
#                                                 + ALL example suites
#                                                 (frontends, native, mobile)
#   src/platform/macos/**                       -> additionally cef-host-link:
#                                                 build the WebView example
#                                                 with -Dweb-engine=chromium so
#                                                 cef_host.mm actually compiles
#                                                 and links (macOS only; skipped
#                                                 with a loud warning when the
#                                                 CEF layout is absent — prime
#                                                 with `zig build &&
#                                                 ./zig-out/bin/native cef install`)
#   examples/<name>/**                          -> that example's suite only
#                                                 (test-example-<name>; the
#                                                 mobile projects map to
#                                                 test-examples-mobile; hello/
#                                                 webview/browser run their
#                                                 in-dir `zig build test`)
#   docs/**                                     -> docs `pnpm check`
#   anything else (README, .github, packages,
#   scripts, skills, changelog.d, ...)          -> root suites only
# A docs-ONLY diff runs only the docs check. The docs check is path-gated
# in both tiers: it never runs unless docs/ changed (or --all in full).
#
# full — root test + validate, every example suite (frontends, native incl.
# canvas-preview, mobile), the Chromium host link check (cef-host-link),
# the macOS automation smokes (gpu-surface,
# gpu-dashboard, gpu-components, canvas-preview, writeback; skipped off-macOS), a
# markup check over every example markup file, and the docs check if docs/ changed
# vs base-ref or --all was passed. --perf additionally runs the percentile
# GPU perf check (test-gpu-dashboard-perf; macOS only, slow, load-sensitive —
# opt-in so a busy dev box doesn't fail the gate on noise).
#
# bench-check — the render-benchmark budget ratchet
# (`zig build bench-render -Doptimize=ReleaseFast -- --check
# tools/bench-render-budgets.txt`): median e2e p50 of three deterministic
# suite passes per scenario vs committed budgets with ~1.3x+ headroom, so
# it trips on order-of-magnitude regressions (a reintroduced O(n^2)
# planner scan, an extra emission per input), not machine noise. Unlike
# the --perf harness it is headless, in-process, and seconds-long once the
# ReleaseFast build is cached — that is why it runs by DEFAULT (fast tier:
# framework diffs only, since engine perf cannot regress from an
# example-only or docs diff; full tier: always) instead of opt-in like
# --perf: a ratchet that only runs when someone remembers to ask is not a
# ratchet. macOS-only because the budgets are calibrated on Apple Silicon.
# Set NATIVE_SDK_SKIP_BENCH_CHECK=1 to skip it on a box that is too busy
# even for the generous budgets.
#
# Deliberately NOT `set -e`: every step runs even after a failure so the
# summary shows the whole picture; the exit code is non-zero if any step
# failed. Step output streams through; each step is timed.
set -u

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root" || exit 1

usage() {
  echo "usage: scripts/gate.sh <fast|full> [base-ref] [--all] [--perf]" >&2
  exit 2
}

tier="${1:-}"
case "$tier" in fast|full) ;; *) usage ;; esac
shift

base_ref="main"
run_all=false
run_perf=false
for arg in "$@"; do
  case "$arg" in
    --all) run_all=true ;;
    --perf) run_perf=true ;;
    -*) usage ;;
    *) base_ref="$arg" ;;
  esac
done

# ---- diff classification --------------------------------------------------

base_commit="$(git merge-base "$base_ref" HEAD 2>/dev/null)"
if [ -z "$base_commit" ]; then
  echo "gate: cannot resolve merge-base of '$base_ref' and HEAD" >&2
  exit 2
fi
changed_files="$( (git diff --name-only "$base_commit"; git ls-files --others --exclude-standard) | sort -u)"

framework_changed=false
macos_platform_changed=false
docs_changed=false
meta_changed=false
affected_examples=""   # space-separated example dir names
mobile_affected=false

# Examples with a root `test-example-<name>` step, derived from build.zig's
# `addExampleTestStep(...)` registrations so this script is never a second
# registry that drifts (it did, twice in one day — soundboard/calculator/
# notes were silently skipped). Layout/file-contains checks register other
# `test-example-*` names via different helpers and are deliberately not
# example suites, so the match is keyed on the helper name.
registered_examples="$(sed -n 's/.*addExampleTestStep([^"]*"test-example-\([A-Za-z0-9-]*\)".*/\1/p' build.zig | sort -u | tr '\n' ' ')"
if [ -z "$registered_examples" ]; then
  echo "gate: derived no registered examples from build.zig (addExampleTestStep pattern matched nothing — helper renamed?)" >&2
  exit 2
fi
# Examples whose suite is their own in-dir `zig build test`.
indir_examples="browser hello webview"
# Mobile example projects, covered as a group by test-examples-mobile.
mobile_examples="android ios mobile-canvas mobile-shell"

note_example() {
  case " $affected_examples " in *" $1 "*) ;; *) affected_examples="$affected_examples $1" ;; esac
}

while IFS= read -r file; do
  [ -n "$file" ] || continue
  case "$file" in
    docs/*) docs_changed=true ;;
    src/platform/macos/*) framework_changed=true; macos_platform_changed=true ;;
    src/*|build.zig|build.zig.zon|build/*|tools/*|tests/*|assets/*) framework_changed=true ;;
    examples/*/*)
      example="${file#examples/}"
      example="${example%%/*}"
      case " $mobile_examples " in
        *" $example "*) mobile_affected=true ;;
        *) note_example "$example" ;;
      esac
      ;;
    *) meta_changed=true ;;
  esac
done <<EOF_FILES
$changed_files
EOF_FILES

# ---- step machinery -------------------------------------------------------

step_names=""
step_status=""
step_secs=""
failures=0
gate_start=$(date +%s)

record() { # name status seconds
  step_names="$step_names$1|"
  step_status="$step_status$2|"
  step_secs="$step_secs$3|"
}

run_step() { # name command...
  name="$1"; shift
  echo ""
  echo "==> $name: $*"
  start=$(date +%s)
  "$@"
  rc=$?
  secs=$(( $(date +%s) - start ))
  if [ "$rc" -eq 0 ]; then
    record "$name" PASS "$secs"
  else
    record "$name" FAIL "$secs"
    failures=$((failures + 1))
    echo "==> $name FAILED (exit $rc)" >&2
  fi
}

skip_step() { # name reason
  echo ""
  echo "==> $1: skipped ($2)"
  record "$1" SKIP 0
}

docs_check() {
  run_step "docs-install" pnpm --dir docs install --frozen-lockfile
  # Build into a gate-owned dist dir so the check never corrupts a running
  # dev server's .next cache.
  run_step "docs-check" env NEXT_DIST_DIR=.next-gate pnpm --dir docs check
}

is_macos=false
[ "$(uname -s)" = "Darwin" ] && is_macos=true

bench_check() {
  zig build bench-render -Doptimize=ReleaseFast -- --check "$repo_root/tools/bench-render-budgets.txt"
}

run_bench_check_step() { # runs (or explains skipping) the render-benchmark ratchet
  if ! $is_macos; then
    skip_step "bench-check" "budgets calibrated on Apple Silicon macOS"
  elif [ -n "${NATIVE_SDK_SKIP_BENCH_CHECK:-}" ]; then
    skip_step "bench-check" "NATIVE_SDK_SKIP_BENCH_CHECK set"
  else
    run_step "bench-check" bench_check
  fi
}

# The Chromium (CEF) host, src/platform/macos/cef_host.mm, is only compiled
# by Chromium-engine app builds — never by `zig build test`/`validate` — so
# without this step an edit that keeps it merely grep-identical to the
# AppKit host can land without ever seeing a compiler. test-webview-cef-link
# builds (and links) the WebView example against the host for real.
cef_layout_ready() {
  [ -f third_party/cef/macos/include/cef_app.h ] &&
  [ -d "third_party/cef/macos/Release/Chromium Embedded Framework.framework" ] &&
  [ -f third_party/cef/macos/libcef_dll_wrapper/libcef_dll_wrapper.a ]
}

cef_host_step() {
  if ! $is_macos; then
    skip_step "cef-host-link" "macOS only"
    return
  fi
  if ! cef_layout_ready; then
    echo "" >&2
    echo "==> cef-host-link: WARNING — src/platform/macos changed but the CEF layout is absent," >&2
    echo "    so the Chromium host was NOT compiled. Blind cef_host.mm edits will not be caught." >&2
    echo "    Prime it once (downloads the prepared CEF runtime into third_party/cef/macos):" >&2
    echo "      zig build && ./zig-out/bin/native cef install" >&2
    skip_step "cef-host-link" "CEF layout absent at third_party/cef/macos (see warning)"
    return
  fi
  run_step "cef-host-link" zig build test-webview-cef-link
}

# ---- tiers ----------------------------------------------------------------

if [ "$tier" = "fast" ]; then
  non_docs_change=false
  { $framework_changed || $meta_changed || $mobile_affected || [ -n "$affected_examples" ]; } && non_docs_change=true

  if $non_docs_change || ! $docs_changed; then
    # Root suites run for any non-docs diff, and also for an empty diff
    # (a clean tree still deserves a baseline check).
    run_step "zig-test" zig build test
    run_step "zig-validate" zig build validate
  else
    skip_step "zig-test" "docs-only diff"
    skip_step "zig-validate" "docs-only diff"
  fi

  if $framework_changed; then
    run_step "examples-frontends" zig build test-examples-frontends
    run_step "examples-native" zig build test-examples-native
    run_step "examples-mobile" zig build test-examples-mobile
    # Engine perf can only regress through framework code, so the ratchet
    # rides the same trigger as the full example sweep.
    run_bench_check_step
  else
    for example in $affected_examples; do
      case " $registered_examples " in
        *" $example "*) run_step "example-$example" zig build "test-example-$example" ;;
        *)
          case " $indir_examples " in
            *" $example "*) run_step "example-$example" sh -c "cd 'examples/$example' && zig build test -Dplatform=null" ;;
            *) skip_step "example-$example" "no test suite registered for examples/$example" ;;
          esac
          ;;
      esac
    done
    $mobile_affected && run_step "examples-mobile" zig build test-examples-mobile
  fi

  if $macos_platform_changed; then
    cef_host_step
  else
    skip_step "cef-host-link" "src/platform/macos unchanged vs $base_ref"
  fi

  if $docs_changed; then
    docs_check
  else
    skip_step "docs-check" "docs/ unchanged vs $base_ref"
  fi
else # full
  run_step "zig-test" zig build test
  run_step "zig-validate" zig build validate
  run_step "examples-frontends" zig build test-examples-frontends
  run_step "examples-native" zig build test-examples-native
  run_step "examples-mobile" zig build test-examples-mobile

  cef_host_step

  if $is_macos; then
    run_step "smoke-gpu-surface" zig build test-gpu-surface-smoke
    run_step "smoke-gpu-dashboard" zig build test-gpu-dashboard-smoke
    run_step "smoke-gpu-components" zig build test-gpu-components-smoke
    run_step "smoke-webview" zig build test-webview-smoke
    run_step "smoke-native-shell" zig build test-native-shell-smoke
    run_step "smoke-canvas-preview" zig build test-canvas-preview-smoke
    run_step "smoke-writeback" zig build test-writeback-smoke
  else
    skip_step "smoke-gpu-surface" "macOS only"
    skip_step "smoke-gpu-dashboard" "macOS only"
    skip_step "smoke-gpu-components" "macOS only"
    skip_step "smoke-webview" "macOS only"
    skip_step "smoke-native-shell" "macOS only"
    skip_step "smoke-canvas-preview" "macOS only"
    skip_step "smoke-writeback" "macOS only"
  fi

  run_bench_check_step

  if $run_perf; then
    if $is_macos; then
      run_step "perf-gpu-dashboard" zig build test-gpu-dashboard-perf
    else
      skip_step "perf-gpu-dashboard" "macOS only"
    fi
  else
    skip_step "perf-gpu-dashboard" "opt-in: pass --perf (slow, load-sensitive)"
  fi

  markup_check() {
    zig build || return 1
    # shellcheck disable=SC2046
    # -type f: zero-config app builds leave a .native/ cache DIRECTORY in
    # example dirs, which the name pattern would otherwise match.
    ./zig-out/bin/native markup check $(find examples -name '*.native' -type f | sort)
  }
  run_step "markup-check" markup_check

  if $docs_changed || $run_all; then
    docs_check
  else
    skip_step "docs-check" "docs/ unchanged vs $base_ref (pass --all to force)"
  fi
fi

# ---- summary --------------------------------------------------------------

total_secs=$(( $(date +%s) - gate_start ))
echo ""
echo "==================== gate $tier summary (base: $base_ref) ===================="
old_ifs="$IFS"; IFS='|'
set -- $step_names
names=("$@")
set -- $step_status
statuses=("$@")
set -- $step_secs
secs=("$@")
IFS="$old_ifs"
i=0
while [ "$i" -lt "${#names[@]}" ]; do
  printf '  %-22s %-4s %4ss\n' "${names[$i]}" "${statuses[$i]}" "${secs[$i]}"
  i=$((i + 1))
done
printf '  %-22s %-4s %4ss\n' "total" "$([ "$failures" -eq 0 ] && echo PASS || echo FAIL)" "$total_secs"
if [ "$failures" -gt 0 ]; then
  echo "gate $tier: $failures step(s) failed" >&2
  exit 1
fi
echo "gate $tier: all steps green"
