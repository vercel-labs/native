#!/bin/sh
# Determinism-fence negative control: prove the profile's fences FIRE, not merely that clean cores pass under them.
#
#   NATIVE_SDK_CORE_COMPILER="<toolchain command>" \
#     tests/compiled-core/fence_check.sh <workdir>
#
#   <workdir>: scratch directory (created; contents replaced)
#
# Two halves, one workdir (the markup fixture — the smallest core in the corpus):
#
#   1. positive control — build_core.sh compiles the pristine fixture and the co-emitted contract sidecar must attest `deterministic: true`;
#   2. negative control — the staged fixture gets one injected fenced ambient read (Date.now() at the top of update), and the SAME compile invocation must refuse it, naming the fenced surface id (stdlib.date.now), with no archive and no attesting sidecar emitted.
#
# Skip-clean like the parity battery: no external toolchain supplied means the check reports the skip and exits 0, so unconditional callers (local dev boxes without the toolchain) stay green.

set -u

work="${1:?usage: fence_check.sh <workdir>}"
repo="$(cd "$(dirname "$0")/../.." && pwd)"

if [ -z "${NATIVE_SDK_CORE_COMPILER:-}" ]; then
  echo "fence-check: skipped — set NATIVE_SDK_CORE_COMPILER to the external core toolchain command to run the determinism-fence negative control"
  exit 0
fi
compiler="$NATIVE_SDK_CORE_COMPILER"

# Half 1: the pristine compile succeeds and attests deterministic.
if ! "$repo/tests/compiled-core/build_core.sh" markup "$work"; then
  echo "fence-check: FAILED — the pristine markup fixture must compile cleanly under the profile" >&2
  exit 1
fi
if ! grep -q '"deterministic": true' "$work/core.contract.json"; then
  echo "fence-check: FAILED — the pristine compile's contract sidecar must attest deterministic: true" >&2
  exit 1
fi
echo "fence-check: pristine compile attests deterministic: true"

# Half 2: one injected fenced ambient read must be refused. The injection anchors on the staged fixture's update signature; if the fixture is reshaped, the anchor check below fails the run with a teaching instead of passing on a compile that never saw the read.
awk '
  { print }
  /^export function update\(/ && !injected {
    print "  const ambientNowMs = Date.now();"
    print "  if (ambientNowMs < 0) { return [model, Cmd.none]; }"
    injected = 1
  }
' "$work/markup_fixture.ts" > "$work/markup_fixture.injected.ts"
if ! grep -q 'Date\.now()' "$work/markup_fixture.injected.ts"; then
  echo "fence-check: FAILED — the Date.now() injection found no update signature to anchor on; re-anchor the injection to the current markup fixture" >&2
  exit 1
fi
mv "$work/markup_fixture.injected.ts" "$work/markup_fixture.ts"
rm -f "$work/libmarkup_core.a" "$work/core.contract.json"

cd "$work"
status=0
refusal="$($compiler build --lib --profile profile.json -o markup_core 2>&1)" || status=$?
if [ "$status" -eq 0 ]; then
  echo "fence-check: FAILED — the compile accepted an injected Date.now() in update; the profile's determinism fences did not fire" >&2
  exit 1
fi
case "$refusal" in
  *stdlib.date.now*) ;;
  *)
    echo "fence-check: FAILED — the compile refused (exit $status) but not on the injected fence; expected the refusal to name stdlib.date.now:" >&2
    echo "$refusal" >&2
    exit 1
    ;;
esac
if [ -f "libmarkup_core.a" ] || [ -f "markup_core" ] || [ -f "markup_core.lib.a" ]; then
  echo "fence-check: FAILED — the refused compile still produced an archive" >&2
  exit 1
fi
if [ -f "core.contract.json" ]; then
  echo "fence-check: FAILED — the refused compile still emitted a contract sidecar" >&2
  exit 1
fi
echo "fence-check: injected Date.now() refused (exit $status), fence stdlib.date.now fired:"
echo "$refusal"
echo "fence-check: PASS"
