// A WPT page may link a stylesheet (or a script) under the server's "/external/wpt/" prefix,
// which names the same file as the path without it. The runner resolves both.
//   npm test

import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join } from "node:path";
import { tmpdir } from "node:os";

const root = mkdtempSync(join(tmpdir(), "native-wpt-external-"));
mkdirSync(join(root, "resources"));
mkdirSync(join(root, "pages"));
// The runner supplies the testharness API itself; the files only have to exist in the checkout.
for (const name of ["testharness.js", "testharnessreport.js"]) writeFileSync(join(root, "resources", name), "");
writeFileSync(join(root, "resources", "support.css"), "body { color: rgb(0, 128, 0); }\n");

writeFileSync(join(root, "pages", "page.html"), `<!doctype html>
<title>external url</title>
<link rel="stylesheet" href="/external/wpt/resources/support.css">
<script src="/resources/testharness.js"></script>
<script src="/resources/testharnessreport.js"></script>
<body>
<script>
test(function () {
  assert_equals(getComputedStyle(document.body).color, "rgb(0, 128, 0)", "the sheet under /external/wpt/ applied");
}, "a stylesheet under /external/wpt/");
</script>
</body>`);

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
const page = results.find((x) => x.path === "pages/page.html");
const ok = page !== undefined && page.status === "pass";
console.log(`${ok ? "ok  " : "FAIL"} a stylesheet under /external/wpt/ resolves to the checkout` +
  (ok ? "" : ` — ${page === undefined ? "missing" : `${page.status}: ${page.reason ?? ""}`}`));
console.log(ok ? "\nall passed" : "\n1 failed");
process.exit(ok ? 0 : 1);
