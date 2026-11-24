// A page whose script never calls createElement: every element it makes comes from markup text
// or a clone of one. The build has no literal tag to go on, so it must keep every rule for
// runtime matching, or these elements lay out unstyled.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=200, height=100"><style>
body { margin: 0; }
.box { width: 120px; height: 30px; }
</style></head><body>
<div id="host"></div>
<script src="app.ts"></script>
</body></html>`;

// innerHTML and cloneNode are the only ways this script makes elements.
const SCRIPT = `
const host = document.getElementById("host") as HTMLElement;
host.innerHTML = '<div class="box" id="a">x</div>';
const a = document.getElementById("a") as HTMLElement;
const b = a.cloneNode(true) as HTMLElement;
b.id = "b";
host.appendChild(b);
requestAnimationFrame(() => {
  requestAnimationFrame(() => {
    const ra = a.getBoundingClientRect();
    const rb = b.getBoundingClientRect();
    console.log("parsed " + ra.width + "x" + ra.height + " clone " + rb.width + "x" + rb.height +
      " top " + ra.top + " " + rb.top);
    console.log("computed " + getComputedStyle(a).getPropertyValue("width") +
      " " + getComputedStyle(b).getPropertyValue("height"));
  });
});
`;

const EXPECTED_LOG = [
  "parsed 120x30 clone 120x30 top 0 30",
  "computed 120px 30px",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-markup-rules-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

// A snapshot path ends the run after the steps; the output itself is only for the log check.
const png = join(dir, "out.png");
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame | frame", NATIVE_SNAPSHOT: png } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);

const got = r.stdout.split("\n").slice(0, -1);
const want = EXPECTED_LOG;
check(`log lines (${want.length})`, got.length === want.length, `got ${got.length}: ${JSON.stringify(got.slice(want.length))}`);
const n = Math.min(got.length, want.length);
for (let i = 0; i < n; i++) check(want[i], got[i] === want[i], `got ${JSON.stringify(got[i])}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
