// Autofocus candidates: the first element the document saw with an `autofocus` attribute takes
// focus on the next rendering update, a candidate that cannot take focus is skipped (and one that
// becomes focusable before the frame still gets its turn), a reinserted candidate joins the queue
// again, and an element added to a loaded document is focused.
//   npm test

import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join } from "node:path";
import { tmpdir } from "node:os";

const root = mkdtempSync(join(tmpdir(), "native-autofocus-"));
mkdirSync(join(root, "resources"));
mkdirSync(join(root, "pages"));
for (const name of ["testharness.js", "testharnessreport.js"]) writeFileSync(join(root, "resources", name), "");

const HARNESS = `<script src="/resources/testharness.js"></script>
<script src="/resources/testharnessreport.js"></script>`;
const SETTLE = `function settle() {
  return new Promise(function (resolve) { requestAnimationFrame(function () { requestAnimationFrame(resolve); }); });
}`;

const page = (title: string, body: string): string => `<!doctype html>
<title>${title}</title>
${HARNESS}
${body}`;

// The first autofocus element in the document wins.
writeFileSync(join(root, "pages", "first.html"), page("first", `<input id="a" autofocus><input id="b" autofocus>
<script>
${SETTLE}
promise_test(async function () {
  await settle();
  assert_equals(document.activeElement.id, "a", "the first autofocus element took focus");
}, "the first autofocus element wins");
</script>`));

// A candidate that cannot take focus is skipped for one that can.
writeFileSync(join(root, "pages", "nonfocusable.html"), page("nonfocusable", `<div id="na" autofocus></div><input id="nb" autofocus>
<script>
${SETTLE}
promise_test(async function () {
  await settle();
  assert_equals(document.activeElement.id, "nb", "the non-focusable candidate was skipped");
}, "a non-focusable candidate is skipped");
</script>`));

// The order the document saw the candidates wins, not the order the tree ends up in.
writeFileSync(join(root, "pages", "temporal.html"), page("temporal", `<input id="t1" autofocus>
<script>
${SETTLE}
var t0 = document.createElement("input");
t0.id = "t0";
t0.setAttribute("autofocus", "");
document.body.insertBefore(t0, document.body.firstChild);
promise_test(async function () {
  await settle();
  assert_equals(document.activeElement.id, "t1", "the temporally first candidate won");
}, "the temporally first candidate wins");
</script>`));

// A candidate removed and reinserted joins the queue at the end again.
writeFileSync(join(root, "pages", "reconnect.html"), page("reconnect", `<input id="r1" autofocus><input id="r2" autofocus>
<script>
${SETTLE}
var r1 = document.getElementById("r1");
r1.remove();
document.body.appendChild(r1);
promise_test(async function () {
  await settle();
  assert_equals(document.activeElement.id, "r2", "the reinserted candidate queued behind the second");
}, "a reinserted candidate queues again");
</script>`));

// An element with autofocus added to a document that has loaded is focused.
writeFileSync(join(root, "pages", "late.html"), page("late", `<script>
${SETTLE}
promise_test(async function () {
  await settle();
  var late = document.createElement("input") as any;
  late.id = "late";
  late.setAttribute("autofocus", "");
  document.body.appendChild(late);
  await settle();
  assert_equals(document.activeElement.id, "late", "the late candidate took focus");
}, "an autofocus element added later takes focus");
</script>`));

// An editing host is a candidate too.
writeFileSync(join(root, "pages", "contenteditable.html"), page("contenteditable", `<div id="ce" contenteditable autofocus>edit</div>
<script>
${SETTLE}
promise_test(async function () {
  await settle();
  assert_equals(document.activeElement.id, "ce", "the editing host took focus");
}, "an editing host takes focus");
</script>`));

const out = join(root, "results.json");
const r = spawnSync("node", ["compiler/cli.ts", "wpt", "run", "pages", "--jobs", "1", "--batch", "10", "--out", out], {
  encoding: "utf8",
  timeout: 1800000,
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
for (const name of ["first", "nonfocusable", "temporal", "reconnect", "late", "contenteditable"]) {
  const got = results.find((x) => x.path === `pages/${name}.html`);
  check(`pages/${name}.html`, got !== undefined && got.status === "pass",
    got === undefined ? "missing" : `${got.status}: ${got.reason ?? ""}`);
}
console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
