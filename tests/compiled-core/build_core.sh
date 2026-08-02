#!/bin/sh
# Build one ts-core fixture's compiled-core archive + contract sidecar
# with an external core toolchain (library mode), staging everything the
# compile needs into a scratch tree:
#
#   NATIVE_SDK_CORE_COMPILER="<toolchain command>" \
#     tests/compiled-core/build_core.sh <fixture> <workdir>
#
#   <fixture>: ai-chat | soundboard | system-monitor | host-fixture | markup
#   <workdir>: scratch directory (created; contents replaced)
#
# The stage carries: the AUTHOR'S core sources verbatim except for
# import-specifier resolution (the "@native-sdk/core*" bare specifiers
# rewrite to the staged ./sdk/ copies of the same files — the toolchain
# compiles its module graph from files, not package resolution), and the
# GENERATED compile entry + compiler profile from the staged contract
# artifacts (`zig build stage-core-contracts` emits both from the
# fixture's extracted contract sidecar — corewire's --facade and
# --profile projections).
#
# Outputs in <workdir>: lib<name>.a, core.contract.json, and a
# build-times line (cold/warm wall clock) on stdout.

set -eu

fixture="${1:?usage: build_core.sh <fixture> <workdir>}"
work="${2:?usage: build_core.sh <fixture> <workdir>}"
compiler="${NATIVE_SDK_CORE_COMPILER:?set NATIVE_SDK_CORE_COMPILER to the external core toolchain command}"
repo="$(cd "$(dirname "$0")/../.." && pwd)"

# The profile's determinism-fence table is RELEASE-PINNED DATA (see tools/corewire/emit_profile.zig): its ids resolve against one toolchain release's surface manifest, so the supplied command must BE that release. tests/compiled-core/core_compiler_pin is the one place the pin lives — bump it there and everything downstream follows.
pin="$(cat "$repo/tests/compiled-core/core_compiler_pin")"
reported="$($compiler -v)"
if [ "$reported" != "$pin" ]; then
  echo "external core toolchain reports version $reported, but the profile's fence table is pinned to $pin (tests/compiled-core/core_compiler_pin) — supply that release, or bump the pin when the fence table has been re-verified against the new release's surface manifest" >&2
  exit 2
fi

case "$fixture" in
  ai-chat)
    source_root="examples/ai-chat-ts/src"
    sources="core.ts api.ts"
    contract="ai-chat"
    ;;
  soundboard)
    source_root="examples/soundboard-ts/src"
    sources="core.ts library.ts player.ts"
    contract="soundboard"
    ;;
  system-monitor)
    source_root="examples/system-monitor-ts/src"
    sources="core.ts parsers.ts table.ts"
    contract="system-monitor"
    ;;
  host-fixture)
    source_root="tests/ts-core"
    sources="fixture.ts"
    contract="host-fixture"
    ;;
  markup)
    source_root="tests/ts-core"
    sources="markup_fixture.ts"
    contract="markup-fixture"
    ;;
  *)
    echo "unknown fixture \"$fixture\" (ai-chat | soundboard | system-monitor | host-fixture | markup)" >&2
    exit 2
    ;;
esac

staged="$repo/zig-out/core-contracts/$contract"
if [ ! -f "$staged/core_facade.ts" ] || [ ! -f "$staged/core_profile.json" ]; then
  echo "no staged contract artifacts for $fixture — run \`zig build stage-core-contracts\` first (it emits the generated entry module and compiler profile under zig-out/core-contracts/$contract)" >&2
  exit 2
fi

rm -rf "$work"
mkdir -p "$work/sdk"

# Two mechanical, behavior-preserving staging transforms:
#   1. bare-specifier resolution — the staged tree carries the SDK
#      modules the author imports, so every specifier resolves to a
#      file in the stage;
#   2. readonly-array erasure — `readonly T[]` (ReadonlyArray) sits
#      outside the toolchain's sidecar type vocabulary today, so the
#      TYPE-LEVEL readonly is erased on staged copies (`T[]` projects);
#      values and behavior are untouched, and the paired battery holds
#      the result byte-identical to the transpiler lane;
#   3. Bytes-alias folding — the corpus's `type Bytes = Uint8Array`
#      alias is tabled (not folded) by the toolchain's sidecar emitter
#      and a tabled scalar alias refuses, so staged copies spell
#      Uint8Array directly and drop the alias declaration/imports.
resolve_specifiers() {
  sed \
    -e 's|"@native-sdk/core/text"|"./sdk/text.ts"|g' \
    -e 's|"@native-sdk/core/events"|"./sdk/events.ts"|g' \
    -e 's|"@native-sdk/core"|"./sdk/core.ts"|g' \
    -e 's|readonly \([A-Za-z_][A-Za-z0-9_]*\(<[A-Za-z_, ]*>\)\{0,1\}\)\[\]|\1[]|g' \
    -e 's|\([^A-Za-z0-9_]\)Bytes\([^A-Za-z0-9_]\)|\1Uint8Array\2|g' \
    -e '/^export type Uint8Array = Uint8Array;$/d' \
    -e '/^ *type Uint8Array,$/d' \
    -e 's|type Uint8Array, ||g' \
    -e 's|, type Uint8Array\([,}]\)|\1|g' \
    "$1" > "$2"
}

for src in $sources; do
  mkdir -p "$(dirname "$work/$src")"
  resolve_specifiers "$repo/$source_root/$src" "$work/$src"
done
# Transform 5, event-record storage: the toolchain's sidecar emitter
# reads a declaration's FORM as its storage class — an `interface` is a
# by-reference node type, an object-literal `type` alias is value-stored
# — and the host-constructed channel arms (chrome, appearance) must
# carry value-stored records, because the host builds those records by
# field name. The two forms are interchangeable for these shapes (no
# declaration merging, no inheritance), so the staged SDK event/text
# modules spell them as aliases.
for sdk_file in text.ts events.ts; do
  sed -e 's|^export interface \([A-Za-z0-9_]*\) {|export type \1 = {|' \
    "$repo/packages/core/sdk/$sdk_file" > "$work/sdk/$sdk_file"
done
# The stage's @native-sdk/core is the static restatement: the reference
# module's factory VALUES verbatim, inside the toolchain's static
# surface (no overloads, no generic value instantiation). The paired
# battery holds every produced byte to the transpiler lane. The
# reference module's byte-text ambient surface also stays out: no
# fixture calls it, and its Uint8Array augmentation collides with the
# toolchain's own node ambient typings.
cp "$repo/tests/compiled-core/sdk_core_static.ts" "$work/sdk/core.ts"
# Transform 4, duplicate-alias dedupe: a tabled type's member order must
# derive from one declaration site, and the same effect-state alias is
# spelled in more than one place across the corpus (a fixture declares
# its own copy, and the SDK's events subpath declares the copy the root
# module also carries — identical member order, no import between them).
# The staged root-module copy drops any alias another staged file
# declares, so the one surviving site is the one the author imports.
author_aliases=""
for src in $sources; do
  more="$(awk '/^export type [A-Za-z0-9_]+ =/ { print $3 }' "$work/$src" | tr '\n' ' ')"
  author_aliases="$author_aliases $more"
done
for sdk_file in text.ts events.ts; do
  more="$(awk '/^export type [A-Za-z0-9_]+ =/ { print $3 }' "$work/sdk/$sdk_file" | tr '\n' ' ')"
  author_aliases="$author_aliases $more"
done
awk -v names="$author_aliases" '
  BEGIN { n = split(names, arr, " "); for (i = 1; i <= n; i++) drop[arr[i]] = 1 }
  {
    if (skip) { if ($0 ~ /;[ \t]*$/) skip = 0; next }
    if ($0 ~ /^export type [A-Za-z0-9_]+ =/ && ($3 in drop)) {
      if ($0 ~ /;[ \t]*$/) next
      skip = 1
      next
    }
    print
  }
' "$work/sdk/core.ts" > "$work/sdk/core.deduped.ts"
mv "$work/sdk/core.deduped.ts" "$work/sdk/core.ts"
# The generated compile entry and its profile, from the staged contract
# artifacts (one corewire invocation emits both, so the profile's entry
# spelling and the facade's file name can never skew).
cp "$staged/core_facade.ts" "$work/core_facade.ts"
cp "$staged/core_profile.json" "$work/profile.json"

name="$(printf '%s' "$fixture" | tr '-' '_')_core"

cd "$work"
cold_start=$(date +%s)
$compiler build --lib --profile profile.json -o "$name"
cold_end=$(date +%s)
warm_start=$(date +%s)
$compiler build --lib --profile profile.json -o "$name"
warm_end=$(date +%s)

# The toolchain writes the ar archive at the bare -o name (some
# releases add .lib.a); the link input needs a recognized extension, so
# normalize to lib<name>.a.
if [ -f "$name.lib.a" ]; then
  mv "$name.lib.a" "lib$name.a"
elif [ -f "$name" ]; then
  mv "$name" "lib$name.a"
fi
if [ ! -f "lib$name.a" ]; then
  echo "no archive produced (expected $name.lib.a or $name)" >&2
  exit 1
fi

echo "archive: $work/lib$name.a ($(wc -c < "lib$name.a" | tr -d ' ') bytes)"
echo "sidecar: $work/core.contract.json"
echo "build-times: cold $((cold_end - cold_start))s, warm $((warm_end - warm_start))s"
