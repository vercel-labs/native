#!/usr/bin/env bash
# Tiered local gate for the Native SDK.
#
#   scripts/gate.sh fast [base-ref]                  # affected-only: what your diff touches
#   scripts/gate.sh full [base-ref] [--all] [--perf] # everything CI-shaped that runs locally
#
# fast — root `zig build test` + `zig build validate`, plus the suites for
# the examples AFFECTED by your diff against base-ref (default: main). The
# diff is `git diff --name-only` against `git merge-base base-ref HEAD`,
# plus untracked files, so uncommitted work counts.
#
# Path -> step mapping (fast tier):
#   src/**, build.zig, build.zig.zon, build/**,
#   tools/**, tests/**, assets/**              -> framework change: root suites
#                                                 + ALL example suites
#                                                 (frontends, native, mobile)
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
# canvas-preview, mobile), the four macOS GPU smokes (gpu-surface,
# gpu-dashboard, gpu-components, canvas-preview; skipped off-macOS), a
# markup check over every example .zml, and the docs check if docs/ changed
# vs base-ref or --all was passed. --perf additionally runs the percentile
# GPU perf check (test-gpu-dashboard-perf; macOS only, slow, load-sensitive —
# opt-in so a busy dev box doesn't fail the gate on noise).
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
docs_changed=false
meta_changed=false
affected_examples=""   # space-separated example dir names
mobile_affected=false

# Examples with a root `test-example-<name>` step (see build.zig).
registered_examples="calculator canvas-preview capabilities command-app effects-probe gpu-components gpu-dashboard gpu-surface habits kanban markdown-viewer native-panels native-shell next notes react soundboard svelte ui-inbox vue"
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
  run_step "docs-check" pnpm --dir docs check
}

is_macos=false
[ "$(uname -s)" = "Darwin" ] && is_macos=true

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

  if $is_macos; then
    run_step "smoke-gpu-surface" zig build test-gpu-surface-smoke
    run_step "smoke-gpu-dashboard" zig build test-gpu-dashboard-smoke
    run_step "smoke-gpu-components" zig build test-gpu-components-smoke
    run_step "smoke-webview" zig build test-webview-smoke
    run_step "smoke-native-shell" zig build test-native-shell-smoke
    run_step "smoke-canvas-preview" zig build test-canvas-preview-smoke
  else
    skip_step "smoke-gpu-surface" "macOS only"
    skip_step "smoke-gpu-dashboard" "macOS only"
    skip_step "smoke-gpu-components" "macOS only"
    skip_step "smoke-webview" "macOS only"
    skip_step "smoke-native-shell" "macOS only"
    skip_step "smoke-canvas-preview" "macOS only"
  fi

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
    ./zig-out/bin/native markup check $(find examples -name '*.zml' | sort)
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
