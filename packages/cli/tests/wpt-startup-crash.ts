// A page that kills the compiled runner before its first page is reported as a crash for that page,
// and the pages beside it are still measured: the batch is run one page per program rather than
// split in halves until the page is found.
//   npm test

import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join } from "node:path";
import { tmpdir } from "node:os";

const root = mkdtempSync(join(tmpdir(), "native-wpt-startup-crash-"));
mkdirSync(join(root, "resources"));
mkdirSync(join(root, "pages"));
// The runner supplies the testharness API itself; the files only have to exist in the checkout.
for (const name of ["testharness.js", "testharnessreport.js"]) writeFileSync(join(root, "resources", name), "");

const HARNESS = `<script src="/resources/testharness.js"></script>
<script src="/resources/testharnessreport.js"></script>`;

// A classic script that defines a custom element for a tag already in its DOM, which today makes
// the compiled runner overflow its stack while the program starts.
writeFileSync(join(root, "pages", "crash.html"), `<!doctype html>
<title>crash</title>
${HARNESS}
<div id="fg"><fg-item tabindex="0"></fg-item></div>
<script>
class FgItem extends HTMLElement {
  constructor() { super(); this.textContent = "Item"; }
}
customElements.define("fg-item", FgItem);
test(function () { assert_true(true); }, "the crashing page's own test");
</script>`);

writeFileSync(join(root, "pages", "fine.html"), `<!doctype html>
<title>fine</title>
${HARNESS}
<script>
test(function () { assert_true(true, "the page beside the crash still runs"); }, "a page beside the crash");
</script>`);

const out = join(root, "results.json");
const r = spawnSync("node", ["compiler/cli.ts", "wpt", "run", "pages", "--jobs", "1", "--batch", "5", "--out", out], {
  encoding: "utf8",
  timeout: 2400000,
  env: { ...process.env, NATIVE_WPT: root },
});
const log = (r.stdout ?? "") + (r.stderr ?? "");
if (r.status !== 0) {
  console.error(log);
  process.exit(1);
}

const results: { path: string; status: string; reason?: string }[] = JSON.parse(readFileSync(out, "utf8")).results;
let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}
const crash = results.find((x) => x.path === "pages/crash.html");
check("the page that kills the runner is the crash", crash !== undefined && crash.status === "crash",
  crash === undefined ? "missing" : `${crash.status}: ${crash.reason ?? ""}`);
const fine = results.find((x) => x.path === "pages/fine.html");
check("the page beside it is still measured", fine !== undefined && fine.status === "pass",
  fine === undefined ? "missing" : `${fine.status}: ${fine.reason ?? ""}`);
check("the batch was run one page per program", /one per program/.test(log) && !/splitting to find/.test(log));
console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
