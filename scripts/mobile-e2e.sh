#!/usr/bin/env bash
# Mobile execution lane for TypeScript cores and in-process services.
#
#   NATIVE_SDK_MOBILE=1 scripts/mobile-e2e.sh
#
# Builds the TS mobile e2e battery (tests/ts-services/mobile_e2e_battery.zig
# over the service fixture's compiled core and service archives) for
# aarch64-ios-simulator and aarch64-linux-android, packages the TS service
# fixture app (tests/ts-services/ok) and a services-free TS example
# (examples/kanban) through the real mobile app lanes, then EXECUTES the
# battery on real device classes:
#
#   - iOS: linked with the simulator SDK's clang (the embedder link
#     pattern) and run on a booted iPhone simulator via `xcrun simctl
#     spawn`. Override the device with NATIVE_SDK_MOBILE_IOS_DEVICE.
#   - Android: linked with the NDK's clang against bionic and run on a
#     headless arm64 emulator via adb. Reuses (or creates, then deletes)
#     the AVD named by NATIVE_SDK_MOBILE_AVD (default native-mobile-e2e;
#     creation needs a JDK and the arm64-v8a android-35 system image).
#     NATIVE_SDK_MOBILE_ANDROID_PORT selects its dedicated even emulator
#     port (default 5584), keeping every adb command pinned to this run.
#
# The executed proof per target: core update round trips with typed
# service results through the in-process pool, trap isolation, and a
# journal replay that reproduces the recorded model without initializing
# the archive. The lane needs Xcode's simulator runtime and the Android
# SDK/NDK, which is why gate.sh runs it only when NATIVE_SDK_MOBILE=1.
set -u

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root" || exit 1

sdk_root="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
adb="$sdk_root/platform-tools/adb"
emulator="$sdk_root/emulator/emulator"
avdmanager="$sdk_root/cmdline-tools/latest/bin/avdmanager"
avd_name="${NATIVE_SDK_MOBILE_AVD:-native-mobile-e2e}"
android_port="${NATIVE_SDK_MOBILE_ANDROID_PORT:-5584}"
android_serial="emulator-$android_port"
ios_min="15.0"
harness_dir=".zig-cache/mobile/harness"

case "$android_port" in
  ''|*[!0-9]*)
    echo "mobile-e2e: NATIVE_SDK_MOBILE_ANDROID_PORT must be an even port in 5554..5682." >&2
    exit 2
    ;;
esac
if [ "$android_port" -lt 5554 ] || [ "$android_port" -gt 5682 ] || [ $((android_port % 2)) -ne 0 ]; then
  echo "mobile-e2e: NATIVE_SDK_MOBILE_ANDROID_PORT must be an even port in 5554..5682." >&2
  exit 2
fi

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

# The lane promises a mobile verdict once invoked: a missing dependency is
# a failure with a teaching, never a skip.
missing=""
command -v xcrun >/dev/null 2>&1 || missing="$missing xcrun"
command -v node >/dev/null 2>&1 || missing="$missing node"
[ -x "$adb" ] || missing="$missing adb"
[ -x "$emulator" ] || missing="$missing emulator"
if [ -n "$missing" ]; then
  echo "mobile-e2e: missing required tools:$missing" >&2
  echo "The lane needs Xcode (simulator runtime), node, and the Android SDK at $sdk_root." >&2
  exit 2
fi
if [ -z "${ANDROID_NDK_ROOT:-}" ] && [ -z "${ANDROID_NDK_HOME:-}" ] && ! ls "$sdk_root/ndk" >/dev/null 2>&1; then
  echo "mobile-e2e: no Android NDK found (set ANDROID_NDK_ROOT or install one under $sdk_root/ndk)." >&2
  exit 2
fi
ndk_root="${ANDROID_NDK_ROOT:-${ANDROID_NDK_HOME:-$(ls -d "$sdk_root"/ndk/* 2>/dev/null | sort -V | tail -1)}}"
ndk_clang="$(ls "$ndk_root"/toolchains/llvm/prebuilt/*/bin/clang 2>/dev/null | head -1)"
if [ -z "$ndk_clang" ]; then
  echo "mobile-e2e: the NDK at $ndk_root carries no prebuilt clang." >&2
  exit 2
fi

# ---- builds -----------------------------------------------------------------

stage_battery() { # triple
  zig build stage-mobile-e2e "-Dtarget=$1" -p ".zig-cache/mobile/$1"
}
run_step "stage-ios-simulator" stage_battery aarch64-ios-simulator
run_step "stage-android" stage_battery aarch64-linux-android

# The CLI drives the app packaging (zero-config graphs), exactly as a
# user's mobile package would: the embed library carries the compiled
# core (and in-process service) archives, and the host tiers link it.
run_step "build-cli" zig build

app_package() { # app-dir target app-name
  local app_dir="$1"
  local target="$2"
  local app_name="$3"
  local artifact="$app_dir/zig-out/package/$app_name-$target"

  # A previous successful package must not satisfy this run's assertions
  # after a failed rebuild. Remove only the outputs this step proves; the
  # package command owns refreshing the surrounding generated host project.
  rm -f "$artifact/Libraries/libnative-sdk.a" "$artifact/$app_name-debug.apk"
  (cd "$app_dir" && "$repo_root/zig-out/bin/native" package --target "$target") || return

  # `native package` may deliberately emit a libraryless host project for
  # apps with no mobile UiApp. These fixtures DO have TypeScript mobile cores,
  # so this lane's contract is stronger: packaging must have built and copied
  # the embed archive, and Android must have linked it into the runnable APK.
  if [ ! -s "$artifact/Libraries/libnative-sdk.a" ]; then
    echo "mobile-e2e: $app_name $target package contains no Libraries/libnative-sdk.a" >&2
    return 1
  fi
  if [ "$target" = "android" ] && [ ! -s "$artifact/$app_name-debug.apk" ]; then
    echo "mobile-e2e: $app_name android package contains no $app_name-debug.apk" >&2
    return 1
  fi
}
run_step "app-services-ios" app_package tests/ts-services/ok ios ts-services-fixture
run_step "app-services-android" app_package tests/ts-services/ok android ts-services-fixture
run_step "app-kanban-android" app_package examples/kanban android kanban

# ---- the battery harness ----------------------------------------------------

mkdir -p "$harness_dir"
cat > "$harness_dir/main.c" <<'EOF'
#include <string.h>
#ifdef __APPLE__
#include <dlfcn.h>
#include <mach-o/dyld.h>
/* Zig's std.debug symbolication references
 * _dyld_get_image_header_containing_address, which the iOS SDK marks
 * __API_UNAVAILABLE(ios). Same dladdr shim the toolkit UIKit host carries. */
const struct mach_header *_dyld_get_image_header_containing_address(const void *address) {
    Dl_info info;
    if (dladdr(address, &info) != 0 && info.dli_fbase != NULL) {
        return (const struct mach_header *)info.dli_fbase;
    }
    return NULL;
}
#endif
#ifdef __ANDROID__
/* ARM64 bionic refuses executables whose PT_TLS alignment is below 64; the
 * battery's Zig objects carry 8-byte-aligned TLS. This anchor raises the
 * segment alignment (the harness links at API 29 so it lands in ELF TLS). */
__thread char nsme_tls_align[64] __attribute__((aligned(64)));
#endif
extern int nsme_run(const unsigned char *root, unsigned long len);
int main(int argc, char **argv) {
    const char *root = argc > 1 ? argv[1] : ".";
    return nsme_run((const unsigned char *)root, strlen(root));
}
EOF

# ---- iOS execution (simulator) ----------------------------------------------

link_ios() {
  xcrun --sdk iphonesimulator clang -target "arm64-apple-ios$ios_min-simulator" -O2 \
    "$harness_dir/main.c" ".zig-cache/mobile/aarch64-ios-simulator/e2e/libts-mobile-e2e.a" \
    -o "$harness_dir/battery-ios" &&
  codesign --force --sign - "$harness_dir/battery-ios"
}
run_step "link-ios-battery" link_ios

pick_ios_device() {
  if [ -n "${NATIVE_SDK_MOBILE_IOS_DEVICE:-}" ]; then
    echo "$NATIVE_SDK_MOBILE_IOS_DEVICE"
    return
  fi
  xcrun simctl list devices available | sed -n 's/^ *\(iPhone[^(]*\) (.*$/\1/p' | sed 's/ *$//' | head -1
}
ios_device="$(pick_ios_device)"

execute_ios() {
  [ -n "$ios_device" ] || { echo "mobile-e2e: no available iPhone simulator" >&2; return 1; }
  xcrun simctl boot "$ios_device" >/dev/null 2>&1
  xcrun simctl bootstatus "$ios_device" -b >/dev/null &&
  rm -rf /tmp/native-mobile-e2e-ios && mkdir -p /tmp/native-mobile-e2e-ios &&
  xcrun simctl spawn "$ios_device" "$repo_root/$harness_dir/battery-ios" /tmp/native-mobile-e2e-ios
}
run_step "execute-ios-simulator" execute_ios

# ---- Android execution (headless emulator) ----------------------------------

# The battery links at API 29 (the first bionic release whose loader takes
# ELF-TLS executables) while the archives keep their API 26 floor — the
# floor is the EMBEDDER contract; this harness is lane tooling.
link_android() {
  "$ndk_clang" --target=aarch64-linux-android29 -O2 \
    "$harness_dir/main.c" ".zig-cache/mobile/aarch64-linux-android/e2e/libts-mobile-e2e.a" \
    -lm -ldl -o "$harness_dir/battery-android"
}
run_step "link-android-battery" link_android

resolve_java_home() {
  if [ -n "${JAVA_HOME:-}" ]; then echo "$JAVA_HOME"; return; fi
  for candidate in /opt/homebrew/opt/openjdk /usr/local/opt/openjdk; do
    [ -x "$candidate/bin/java" ] && { echo "$candidate"; return; }
  done
  echo ""
}

created_avd=false
ensure_avd() {
  if [ -d "$HOME/.android/avd/$avd_name.avd" ]; then return 0; fi
  java_home="$(resolve_java_home)"
  if [ -z "$java_home" ] || [ ! -x "$avdmanager" ]; then
    echo "mobile-e2e: AVD \"$avd_name\" does not exist and avdmanager needs a JDK to create it." >&2
    echo "Create one once (arm64-v8a, android-35) or set NATIVE_SDK_MOBILE_AVD to an existing AVD." >&2
    return 1
  fi
  echo no | JAVA_HOME="$java_home" "$avdmanager" create avd -n "$avd_name" \
    -k "system-images;android-35;google_apis;arm64-v8a" --force || return 1
  created_avd=true
}
run_step "ensure-avd" ensure_avd

emulator_pid=""
execute_android() {
  "$adb" start-server >/dev/null 2>&1
  if "$adb" -s "$android_serial" get-state >/dev/null 2>&1; then
    echo "mobile-e2e: $android_serial is already in use; choose another NATIVE_SDK_MOBILE_ANDROID_PORT." >&2
    return 1
  fi
  "$emulator" -avd "$avd_name" -port "$android_port" -no-window -no-audio -no-boot-anim -no-snapshot \
    > .zig-cache/mobile/emulator.log 2>&1 &
  emulator_pid=$!
  booted=""
  for _ in $(seq 1 60); do
    if ! kill -0 "$emulator_pid" 2>/dev/null; then
      echo "mobile-e2e: $android_serial exited before boot; see .zig-cache/mobile/emulator.log" >&2
      return 1
    fi
    booted="$("$adb" -s "$android_serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')"
    [ "$booted" = "1" ] && break
    sleep 5
  done
  [ "$booted" = "1" ] || { echo "mobile-e2e: the emulator did not finish booting" >&2; return 1; }
  "$adb" -s "$android_serial" push "$harness_dir/battery-android" /data/local/tmp/ts-mobile-e2e >/dev/null &&
  "$adb" -s "$android_serial" shell "chmod +x /data/local/tmp/ts-mobile-e2e && rm -rf /data/local/tmp/nsme && mkdir -p /data/local/tmp/nsme && /data/local/tmp/ts-mobile-e2e /data/local/tmp/nsme"
}
run_step "execute-android-emulator" execute_android

# Teardown: stop the emulator; delete the AVD only if this run created it.
if [ -n "$emulator_pid" ]; then
  "$adb" -s "$android_serial" emu kill >/dev/null 2>&1
  wait "$emulator_pid" 2>/dev/null
fi
if $created_avd; then
  java_home="$(resolve_java_home)"
  [ -n "$java_home" ] && JAVA_HOME="$java_home" "$avdmanager" delete avd -n "$avd_name" >/dev/null 2>&1
fi

# ---- summary ----------------------------------------------------------------

echo ""
echo "==================== mobile-e2e summary ===================="
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
  echo "mobile-e2e: $failures step(s) failed" >&2
  exit 1
fi
echo "mobile-e2e: all steps green"
