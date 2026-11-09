#!/usr/bin/env bash
# Link a fresh TypeScript app through the real iOS dev path. An invalid
# simulator name stops the CLI after bundle assembly, so this works on CI
# runners without an installed simulator runtime.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cli="$repo_root/zig-out/bin/native"
work_dir="$(mktemp -d /tmp/native-ios-dev-link.XXXXXX)"
trap 'rm -rf "$work_dir"' EXIT

app_name="ios-link-smoke"
app_dir="$work_dir/$app_name"
log="$work_dir/dev.log"
invalid_device="native-ios-link-smoke-invalid"
bundle="$app_dir/.native/ios/$app_name.app"
archive="$app_dir/.native/embed/aarch64-ios-simulator/lib/lib$app_name.a"
runtime="libclang_rt.ubsan_iossim_dynamic.dylib"

fail() {
  echo "FAIL: $1" >&2
  if [ -f "$log" ]; then cat "$log" >&2; fi
  exit 1
}

(cd "$repo_root" && zig build) || fail "building the native CLI"
(cd "$work_dir" && "$cli" init "$app_name" --framework "$repo_root") || fail "scaffolding the TypeScript app"

if (cd "$app_dir" && "$cli" dev --target ios --device "$invalid_device") >"$log" 2>&1; then
  fail "native dev unexpectedly booted the invalid simulator"
fi
grep -Fq "native dev (ios): booting simulator \"$invalid_device\"" "$log" \
  || fail "native dev stopped before the iOS host linked and signed"
[ -s "$bundle/$app_name" ] || fail "linked iOS executable is missing"
# ScriptC's packaged runtime objects do not require Clang UBSan. Keep the
# bundle checks for toolchain paths whose archives reference its handlers.
xcrun nm -u -j "$archive" >"$work_dir/undefined-symbols.txt" \
  || fail "could not inspect the embed archive for sanitizer references"
if grep -Fq "___ubsan_handle_" "$work_dir/undefined-symbols.txt"; then
  [ -s "$bundle/$runtime" ] || fail "simulator UBSan runtime is missing"
  otool -L "$bundle/$app_name" | grep -Fq "@rpath/$runtime" \
    || fail "linked executable does not load the bundled UBSan runtime"
fi
codesign --verify --deep --strict "$bundle" || fail "signed iOS bundle failed verification"

echo "PASS: fresh TypeScript iOS dev app linked and signed"
