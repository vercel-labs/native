// The WPT page loop runs every page of a batch in one process. A page that reports no test
// harness result must be an error, not credited with the result the page before it left on the
// window.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const root = mkdtempSync(join(tmpdir(), "native-wpt-settle-"));
mkdirSync(join(root, "resources"));
mkdirSync(join(root, "passes"));
mkdirSync(join(root, "silent"));
// The runner supplies the testharness API itself; the files only have to exist in the checkout.
for (const name of ["testharness.js", "testharnessreport.js"]) writeFileSync(join(root, "resources", name), "");

writeFileSync(join(root, "passes", "page.html"), `<!doctype html>
<title>passes</title>
<script src="/resources/testharness.js"></script>
<script src="/resources/testharnessreport.js"></script>
<script>
test(function () { assert_true(true, "the first page's test"); }, "first page test");
</script>`);

writeFileSync(join(root, "silent", "page.html"), `<!doctype html>
<title>silent</title>
<script src="/resources/testharness.js"></script>
<script src="/resources/testharnessreport.js"></script>
<script>
async_test(function () { /* never done: this page reports no result */ }, "second page test");
</script>`);

const out = join(root, "results.json");
// The two directories are given in order, so the passing page runs first in the batch.
const r = spawnSync("node", ["compiler/cli.ts", "wpt", "run", "passes", "silent", "--jobs", "1", "--batch", "10", "--out", out], {
  encoding: "utf8",
  timeout: 600000,
  env: { ...process.env, NATIVE_WPT: root },
});
if (r.status !== 0) {
  console.error(r.stdout + r.stderr);
  process.exit(1);
}

const results: { path: string; status: string; reason?: string }[] = JSON.parse(readFileSync(out, "utf8")).results;
const first = results.find((x) => x.path === "passes/page.html");
const second = results.find((x) => x.path === "silent/page.html");
// A page that never reports now names the test it is waiting on instead of coming back with
// nothing: the failure is the page's, and its reason has to carry that test's name.
const ok = first !== undefined && first.status === "pass" &&
  second !== undefined && second.status === "fail" && /tests still waiting: second page test/.test(second.reason ?? "");
console.log(`${ok ? "ok  " : "FAIL"} a page with no harness result is not credited with the previous page's`);
if (!ok) console.log(`  got ${JSON.stringify({ first, second })}\n`);
console.log(ok ? "\nall passed" : "\n1 failed");
process.exit(ok ? 0 : 1);
