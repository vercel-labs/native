#!/usr/bin/env bash
# Cross-target execution lane for TypeScript cores and services.
#
#   NATIVE_SDK_CROSS=1 scripts/cross-e2e.sh
#
# Cross-builds the TS-core e2e batteries (host fixture, markup view,
# in-process service pool), one example app (examples/kanban), and the
# service fixture app (tests/ts-services/ok, in-process carrier — the
# core and service archives in one executable) for x86_64-windows-gnu
# and x86_64-linux-musl from this host, then EXECUTES the batteries on
# real targets:
#
#   - Windows: over ssh to the `windows-dev` box (key auth; override the
#     alias with NATIVE_SDK_CROSS_WIN_HOST). Binaries travel as tar over
#     ssh; each battery runs remotely and reports its own verdict.
#   - Linux: in a local Docker container (alpine, linux/amd64 — the musl
#     triple's matching distribution; emulated on non-x86 hosts).
#
# The lane needs those machines, which is why it is opt-in: gate.sh
# skips it unless NATIVE_SDK_CROSS=1 is set. Run it after changes to the
# core/service compile lanes, the cross pairing matrix, or the compiled
# archives' runtime seams.
set -u

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root" || exit 1

win_host="${NATIVE_SDK_CROSS_WIN_HOST:-windows-dev}"
win_dir="C:/Users/rdp/work/native-cross-e2e"
batteries="ts-core-e2e-tests ts-markup-e2e-tests ts-services-pool-e2e-tests"

# ---- step machinery (gate.sh's shape) --------------------------------------

step_names=""
step_status=""
failures=0

record() { step_names="$step_names$1|"; step_status="$step_status$2|"; }

run_step() { # name command...
  name="$1"; shift
  echo ""
  echo "==> $name: $*"
  "$@"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    record "$name" PASS
  else
    record "$name" FAIL
    failures=$((failures + 1))
    echo "==> $name FAILED (exit $rc)" >&2
  fi
}

# The lane promises a cross verdict once invoked: a missing dependency is
# a failure with a teaching, never a skip.
missing=""
command -v docker >/dev/null 2>&1 || missing="$missing docker"
command -v ssh >/dev/null 2>&1 || missing="$missing ssh"
if [ -n "$missing" ]; then
  echo "cross-e2e: missing required tools:$missing" >&2
  echo "The lane executes Linux batteries in a Docker container and Windows batteries over ssh ($win_host)." >&2
  exit 2
fi
if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "$win_host" "echo ok" >/dev/null 2>&1; then
  echo "cross-e2e: cannot reach the Windows box over ssh (alias: $win_host, key auth)." >&2
  echo "Configure the host alias in ~/.ssh/config or set NATIVE_SDK_CROSS_WIN_HOST." >&2
  exit 2
fi

# ---- cross builds -----------------------------------------------------------

stage_batteries() { # triple
  zig build stage-cross-e2e "-Dtarget=$1" -p ".zig-cache/cross/$1"
}
run_step "stage-windows-gnu" stage_batteries x86_64-windows-gnu
run_step "stage-linux-musl" stage_batteries x86_64-linux-musl

# The CLI drives the app builds (zero-config graphs), exactly as a user's
# cross build would.
run_step "build-cli" zig build

app_build() { # app-dir extra-flags...
  dir="$1"; shift
  (cd "$dir" && "$repo_root/zig-out/bin/native" build "$@")
}
run_step "app-kanban-windows" app_build examples/kanban -Dtarget=x86_64-windows-gnu
run_step "app-kanban-linux-musl" app_build examples/kanban -Dtarget=x86_64-linux-musl -Dplatform=null
run_step "app-services-windows" app_build tests/ts-services/ok -Dtarget=x86_64-windows-gnu -Dservice-carrier=in_process
run_step "app-services-linux-musl" app_build tests/ts-services/ok -Dtarget=x86_64-linux-musl -Dplatform=null -Dservice-carrier=in_process

# ---- Linux execution (container) -------------------------------------------

# The raised stack ulimit keeps the deepest battery frames clear of the
# 8 MiB container default, which the amd64 emulation on non-x86 hosts
# inflates past the probe.
linux_batteries() {
  docker run --rm --platform linux/amd64 --ulimit stack=67108864:67108864 \
    -v "$repo_root/.zig-cache/cross/x86_64-linux-musl/e2e:/e2e:ro" -w /tmp alpine:3.20 \
    sh -c 'mkdir -p work && cd work && for t in ts-core-e2e-tests ts-markup-e2e-tests ts-services-pool-e2e-tests; do "/e2e/$t" || exit 1; done'
}
run_step "execute-linux-musl" linux_batteries

# ---- Windows execution (windows-dev) ----------------------------------------

windows_transfer() {
  win_dir_bs="${win_dir//\//\\}"
  ssh -o BatchMode=yes "$win_host" "(if exist $win_dir_bs rmdir /s /q $win_dir_bs) && mkdir $win_dir_bs" &&
  tar -C .zig-cache/cross/x86_64-windows-gnu/e2e -cf - . | ssh -o BatchMode=yes "$win_host" "tar -C $win_dir -xf -"
}
run_step "windows-transfer" windows_transfer

for battery in $batteries; do
  windows_battery() {
    ssh -o BatchMode=yes "$win_host" "cd /d ${win_dir//\//\\} && $battery.exe"
  }
  run_step "execute-windows-$battery" windows_battery
done

# ---- summary ----------------------------------------------------------------

echo ""
echo "==================== cross-e2e summary ===================="
old_ifs="$IFS"; IFS='|'
set -- $step_names
names=("$@")
set -- $step_status
statuses=("$@")
IFS="$old_ifs"
i=0
while [ "$i" -lt "${#names[@]}" ]; do
  printf '  %-34s %s\n' "${names[$i]}" "${statuses[$i]}"
  i=$((i + 1))
done
if [ "$failures" -gt 0 ]; then
  echo "cross-e2e: $failures step(s) failed" >&2
  exit 1
fi
echo "cross-e2e: all steps green"
