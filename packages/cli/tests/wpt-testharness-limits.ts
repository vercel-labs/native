// A page whose test never finishes says which test it is waiting on, and an assertion made in a
// promise test's continuation fails that test instead of waiting for ever.
//   npm test

import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join } from "node:path";
import { tmpdir } from "node:os";

const root = mkdtempSync(join(tmpdir(), "native-wpt-limits-"));
mkdirSync(join(root, "resources"));
mkdirSync(join(root, "pages"));
// The runner supplies the testharness API itself; the files only have to exist in the checkout.
for (const name of ["testharness.js", "testharnessreport.js"]) writeFileSync(join(root, "resources", name), "");

const HARNESS = `<script src="/resources/testharness.js"></script>
<script src="/resources/testharnessreport.js"></script>`;

// An assertion after an await runs outside the test's own steps. It must fail the test that made
// the promise, and the page must still report (a second, passing test proves the page did).
writeFileSync(join(root, "pages", "assertion.html"), `<!doctype html>
<title>assertion in a continuation</title>
${HARNESS}
<script>
promise_test(async function () {
  await new Promise(function (resolve) { setTimeout(resolve, 0); });
  assert_equals(1 + 1, 3, "the arithmetic is wrong on purpose");
}, "an assertion after an await fails its test");
test(function () { assert_true(true, "the page still reports"); }, "a passing test after it");
</script>`);

// A test that never finishes: the page reports which test it was waiting on rather than nothing.
writeFileSync(join(root, "pages", "pending.html"), `<!doctype html>
<title>a test that never finishes</title>
${HARNESS}
<script>
async_test(function () { /* never done */ }, "the test that never finishes");
</script>`);

const out = join(root, "results.json");
const r = spawnSync("node", ["compiler/cli.ts", "wpt", "run", "pages", "--jobs", "1", "--batch", "5", "--out", out], {
  encoding: "utf8",
  timeout: 600000,
  env: { ...process.env, NATIVE_WPT: root },
});
if (r.status !== 0) {
  console.error(r.stdout + r.stderr);
  process.exit(1);
}

const results: { path: string; status: string; reason?: string }[] = JSON.parse(readFileSync(out, "utf8")).results;
let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}
const assertion = results.find((x) => x.path === "pages/assertion.html");
const assertionReason = assertion?.reason ?? "";
check("an assertion after an await fails its test", assertion !== undefined && assertion.status === "fail" &&
  assertionReason.includes("an assertion after an await fails its test") && assertionReason.includes("assert_equals"),
  assertion === undefined ? "missing" : `${assertion.status}: ${assertionReason}`);
const pending = results.find((x) => x.path === "pages/pending.html");
const pendingReason = pending?.reason ?? "";
check("a page that never finishes names its test", pending !== undefined && pending.status === "fail" &&
  pendingReason.includes("tests still waiting") && pendingReason.includes("the test that never finishes"),
  pending === undefined ? "missing" : `${pending.status}: ${pendingReason}`);
check("neither page is a silent no-result", !/produced no result/.test(assertionReason + pendingReason),
  assertionReason + " | " + pendingReason);
console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
