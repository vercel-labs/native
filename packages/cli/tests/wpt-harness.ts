// The runner's EventWatcher: a watcher that times out fails the test that made it, and the page
// still reports instead of waiting for ever.
//   npm test

import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join } from "node:path";
import { tmpdir } from "node:os";

const root = mkdtempSync(join(tmpdir(), "native-wpt-harness-"));
mkdirSync(join(root, "resources"));
mkdirSync(join(root, "watcher"));
// The runner supplies the testharness API itself; the files only have to exist in the checkout.
for (const name of ["testharness.js", "testharnessreport.js"]) writeFileSync(join(root, "resources", name), "");

const HARNESS = `<script src="/resources/testharness.js"></script>
<script src="/resources/testharnessreport.js"></script>`;

// A watcher whose event never comes: the timeout fails the promise test that made the watcher, and
// the page still reports. The second test's event does come, so the ordinary wait is unchanged.
writeFileSync(join(root, "watcher", "page.html"), `<!doctype html>
<title>watcher</title>
${HARNESS}
<div id="target" style="width: 100px; height: 100px; background: #ddd"></div>
<script>
promise_test(async function (t) {
  var watcher = new EventWatcher(t, document.getElementById("target"), "click", function () {
    return new Promise(function (resolve) { setTimeout(function () { resolve(1); }, 50); });
  });
  await watcher.wait_for("click");
}, "a timeout fails the owning test");
promise_test(async function (t) {
  var target = document.getElementById("target");
  var watcher = new EventWatcher(t, target, "click");
  var wait = watcher.wait_for("click");
  await test_driver.click(target);
  var evt = await wait;
  assert_equals(evt.type, "click");
}, "an event that arrives passes");
</script>`);

const out = join(root, "results.json");
const r = spawnSync("node", ["compiler/cli.ts", "wpt", "run", "watcher", "--jobs", "1", "--batch", "10", "--out", out], {
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
const watcher = results.find((x) => x.path === "watcher/page.html");
const reason = watcher?.reason ?? "";
check("watcher/page.html fails on its own test", watcher !== undefined && watcher.status === "fail" &&
  reason.includes("a timeout fails the owning test") && reason.includes("Timed out waiting for click"),
  watcher === undefined ? "missing" : `${watcher.status}: ${reason}`);
check("watcher/page.html still reports", !/no test harness result|produced no result/.test(reason), reason);
console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
