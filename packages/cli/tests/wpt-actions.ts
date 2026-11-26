// test_driver.Actions drives input the way WebDriver's perform does: the last tick's pause holds
// the sequence before it settles, and a scroll's deltas are the DOM's, where a positive deltaY
// scrolls down and a positive deltaX right.
//   npm test

import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join } from "node:path";
import { tmpdir } from "node:os";

const root = mkdtempSync(join(tmpdir(), "native-wpt-actions-"));
mkdirSync(join(root, "resources"));
mkdirSync(join(root, "actions"));
// The runner supplies the testharness API itself; the files only have to exist in the checkout.
for (const name of ["testharness.js", "testharnessreport.js"]) writeFileSync(join(root, "resources", name), "");

const HARNESS = `<script src="/resources/testharness.js"></script>
<script src="/resources/testharnessreport.js"></script>`;

// A pointer sequence whose last tick is a pause: send() must not settle before the pause is over.
writeFileSync(join(root, "actions", "pause.html"), `<!doctype html>
<title>actions pause</title>
${HARNESS}
<div id="target" style="width: 100px; height: 100px; background: #ccc"></div>
<script>
promise_test(async (t) => {
  const start = performance.now();
  await new test_driver.Actions().pointerDown().pointerUp().pause(300).send();
  // The assertion runs as one of the test's steps, so a failure is the test's own.
  t.step(function () {
    assert_greater_than_equal(performance.now() - start, 300, "the last tick's pause elapsed before send() settled");
  });
}, "a pause in the last tick holds the sequence");
</script>`);

// A page taller and wider than the viewport: a scroll's deltas must move it the way the DOM's
// do, from the top-left corner, where a positive deltaY scrolls down and a positive deltaX right.
writeFileSync(join(root, "actions", "wheel.html"), `<!doctype html>
<title>actions scroll</title>
${HARNESS}
<style>body { margin: 0; width: 3000px; height: 3000px; }</style>
<script>
promise_test(async () => {
  assert_equals(window.scrollY, 0, "the page starts at the top");
  await new test_driver.Actions().scroll(10, 10, 0, 200).send();
  assert_greater_than(window.scrollY, 0, "a positive deltaY scrolls down");
}, "a positive deltaY scrolls down from the top");
promise_test(async () => {
  const before = window.scrollY;
  await new test_driver.Actions().scroll(10, 10, 0, -100).send();
  assert_less_than(window.scrollY, before, "a negative deltaY scrolls up");
}, "a negative deltaY scrolls up");
promise_test(async () => {
  assert_equals(window.scrollX, 0, "the page starts at the left");
  await new test_driver.Actions().scroll(10, 10, 200, 0).send();
  assert_greater_than(window.scrollX, 0, "a positive deltaX scrolls right");
}, "a positive deltaX scrolls right from the left");
</script>`);

const out = join(root, "results.json");
const r = spawnSync("node", ["compiler/cli.ts", "wpt", "run", "actions", "--jobs", "1", "--batch", "10", "--out", out], {
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
for (const page of ["actions/pause.html", "actions/wheel.html"]) {
  const got = results.find((x) => x.path === page);
  check(page, got !== undefined && got.status === "pass",
    got === undefined ? "missing" : `${got.status}: ${got.reason ?? ""}`);
}
console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
