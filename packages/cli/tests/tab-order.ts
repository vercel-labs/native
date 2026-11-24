// Tab walks the page in Chrome's sequential focus order: positive tabindex values first, ascending
// and then in document order, then everything else (links, buttons, form controls, tabindex 0) in
// document order. The order is the page's own, so the test doesn't depend on the machine.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=200, height=200"><style>
body { margin: 0; font: 13px monospace; }
input, button, a, div { display: block; height: 20px; }
</style></head><body>
<input id="i">
<button id="b">B</button>
<a id="l" href="#x">L</a>
<div id="d" tabindex="0">D</div>
<div id="p1" tabindex="2">P1</div>
<div id="p2" tabindex="1">P2</div>
<script>
function note(id) {
  var el = document.getElementById(id);
  el.addEventListener("focus", function () { console.log("focus " + id); });
}
note("i");
note("b");
note("l");
note("d");
note("p1");
note("p2");
</script>
</body></html>`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-tab-order-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
const env: NodeJS.ProcessEnv = {
  ...process.env,
  NATIVE_STEPS: "key Tab | key Tab | key Tab | key Tab | key Tab | key Tab",
};
delete env.NATIVE_SNAPSHOT;
const r = spawnSync(exe, [], { encoding: "utf8", env });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const got = r.stdout.split("\n").map((l) => l.trim()).filter((l) => l.startsWith("focus "));
// tabindex 1 and 2 first, in that order; then the page's own order.
const want = ["focus p2", "focus p1", "focus i", "focus b", "focus l", "focus d"];
check("Tab follows the sequential focus order", got.join(",") === want.join(","),
  `got ${JSON.stringify(got)} wanted ${JSON.stringify(want)}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
