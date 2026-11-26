// The runner's page rewrites and its EventWatcher keep a page's own text and its own tests: an
// apostrophe in a comment is not a quote, and a watcher that times out fails the test that made it
// instead of leaving the page waiting.
//   npm test

import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join } from "node:path";
import { tmpdir } from "node:os";

const root = mkdtempSync(join(tmpdir(), "native-wpt-harness-"));
mkdirSync(join(root, "resources"));
mkdirSync(join(root, "scripts"));
mkdirSync(join(root, "watcher"));
// The runner supplies the testharness API itself; the files only have to exist in the checkout.
for (const name of ["testharness.js", "testharnessreport.js"]) writeFileSync(join(root, "resources", name), "");

const HARNESS = `<script src="/resources/testharness.js"></script>
<script src="/resources/testharnessreport.js"></script>`;

// The comment's apostrophe must not put the rewrite into string mode: the long name in the code is
// shortened so scriptc keeps its binding, and the id string keeps its own text.
writeFileSync(join(root, "scripts", "page.html"), `<!doctype html>
<title>scripts</title>
${HARNESS}
<div id="elementNamedWithAVeryLongIdentifierForHarnessTest"></div>
<script>
// don't lose the names below: the apostrophe in this comment is not a quote.
function aFunctionNamedWithAVeryLongIdentifierForTheHarnessTest(a, b) { return a + b; }
test(function () {
  assert_equals(aFunctionNamedWithAVeryLongIdentifierForTheHarnessTest(1, 2), 3, "the long name is callable");
}, "a long name is callable");
test(function () {
  var el = document.getElementById('elementNamedWithAVeryLongIdentifierForHarnessTest');
  assert_true(el !== null, "the id string keeps its value");
}, "an id in a single-quoted string is found");
test(function () {
  var text = \`\${aFunctionNamedWithAVeryLongIdentifierForTheHarnessTest(2, 3)}\`;
  assert_equals(text, "5", "the interpolation calls the long name");
}, "a long name inside a template interpolation");
test(function () {
  var text = "don't lose aFunctionNamedWithAVeryLongIdentifierForTheHarnessTest";
  assert_equals(text, "don't lose aFunctionNamedWithAVeryLongIdentifierForTheHarnessTest", "the double-quoted text keeps the name");
}, "an apostrophe in a double-quoted string is text");
test(function () {
  var matched = false;
  if (!matched) /aFunctionNamedWithAVeryLongIdentifierForTheHarnessTest/.test("aFunctionNamedWithAVeryLongIdentifierForTheHarnessTest") && (matched = true);
  assert_true(matched, "the regular expression after an if condition keeps its text");
}, "a regular expression right after an if condition");
test(function () {
  var hit = \`\${/aFunctionNamedWithAVeryLongIdentifierForTheHarnessTest/.test("aFunctionNamedWithAVeryLongIdentifierForTheHarnessTest")}\`;
  assert_equals(hit, "true", "the pattern at the start of an interpolation keeps its text");
}, "a regular expression at the start of a template interpolation");
test(function () {
  var aFunctionNamedWithAVeryLongIdentifierForTheHarnessTest = 7;
  var box = { aFunctionNamedWithAVeryLongIdentifierForTheHarnessTest };
  assert_equals(box["aFunctionNamedWithAVeryLongIdentifierForTheHarnessTest"], 7, "the shorthand keeps its key");
}, "a shorthand property keeps its key");
test(function () {
  var box = { aFunctionNamedWithAVeryLongIdentifierForTheHarnessTest: 9 };
  var { aFunctionNamedWithAVeryLongIdentifierForTheHarnessTest } = box;
  assert_equals(aFunctionNamedWithAVeryLongIdentifierForTheHarnessTest, 9, "the destructured name keeps the key");
}, "a shorthand binding keeps its key");
test(function () {
  var list = [4, 5];
  var [aFunctionNamedWithAVeryLongIdentifierForTheHarnessTest] = list;
  assert_equals(aFunctionNamedWithAVeryLongIdentifierForTheHarnessTest, 4, "the array element binds the variable");
}, "an array destructuring renames its variable");
test(function () {
  var box = { a: 1, b: 2 };
  var { ...aFunctionNamedWithAVeryLongIdentifierForTheHarnessTest } = box;
  assert_equals(aFunctionNamedWithAVeryLongIdentifierForTheHarnessTest.a, 1, "the rest binding renames its variable");
}, "an object rest renames its variable");
test(function () {
  var pattern = /aFunctionNamedWithAVeryLongIdentifierForTheHarnessTest/;
  assert_true(pattern.test("aFunctionNamedWithAVeryLongIdentifierForTheHarnessTest"), "the regular expression keeps its text");
}, "a regular expression keeps its own text");
</script>`);

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
const r = spawnSync("node", ["compiler/cli.ts", "wpt", "run", "scripts", "watcher", "--jobs", "1", "--batch", "10", "--out", out], {
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
const scripts = results.find((x) => x.path === "scripts/page.html");
check("scripts/page.html passes", scripts !== undefined && scripts.status === "pass",
  scripts === undefined ? "missing" : `${scripts.status}: ${scripts.reason ?? ""}`);
const watcher = results.find((x) => x.path === "watcher/page.html");
const reason = watcher?.reason ?? "";
check("watcher/page.html fails on its own test", watcher !== undefined && watcher.status === "fail" &&
  reason.includes("a timeout fails the owning test") && reason.includes("Timed out waiting for click"),
  watcher === undefined ? "missing" : `${watcher.status}: ${reason}`);
check("watcher/page.html still reports", !/no test harness result|produced no result/.test(reason), reason);
console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
