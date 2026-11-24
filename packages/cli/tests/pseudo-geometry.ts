// A pseudo-element's geometry is its own box's, not its originating element's: the ::before box's
// border box, and the content, padding and margin boxes getBoxQuads() names. A pseudo-element the
// page never generates (no content, or display: none) has no quads.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=320, height=220"><style>
body { margin: 0; }
#target {
  position: absolute; left: 20px; top: 10px; width: 200px; height: 100px;
  padding: 10px; border: 5px solid black;
}
#target::before {
  content: ''; display: block; width: 50px; height: 30px;
  padding: 5px; border: 2px solid blue; margin: 3px;
}
#target::after { content: 'after'; display: block; width: 80px; height: 40px; }
#none::before { content: 'hidden'; display: none; }
</style></head><body>
<div id="target"></div>
<div id="none"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function log(s: string): void { console.log(s); }
const target = document.getElementById("target") as HTMLElement;
const before = target.pseudo("::before")!;
const rect = before.getBoundingClientRect();
log("rect " + rect.width + "x" + rect.height);
const quad = (box: string): string => {
  const q = before.getBoxQuads({ box: box })[0];
  const b = q.getBounds();
  return b.width + "x" + b.height;
};
log("border " + quad("border"));
log("padding " + quad("padding"));
log("content " + quad("content"));
log("margin " + quad("margin"));
const after = target.pseudo("::after")!;
log("after " + String(after.getBoxQuads().length >= 1) + " " + (after.getBoundingClientRect().width > 0));
const none = document.getElementById("none") as HTMLElement;
log("none " + String(none.pseudo("::before")!.getBoxQuads().length) + " " + String(none.pseudo("::before")!.getBoundingClientRect().width));
`;

const EXPECTED = [
  // The ::before's border box: 50 + 2*5 padding + 2*2 border wide, 30 + 10 + 4 high.
  "rect 64x44",
  "border 64x44",
  "padding 60x40",
  "content 50x30",
  "margin 70x50",
  // The ::after box exists and has a size.
  "after true true",
  // A display:none pseudo-element has no box to report.
  "none 0 0",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-pseudo-geometry-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: "frame 1" };
delete env.NATIVE_SNAPSHOT;
const r = spawnSync(exe, [], { encoding: "utf8", env });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const got = r.stdout.split("\n").slice(0, -1);
for (const line of got) console.log(`     got ${JSON.stringify(line)}`);
check(`log lines (${EXPECTED.length})`, got.length === EXPECTED.length, `got ${got.length}`);
for (let i = 0; i < Math.min(got.length, EXPECTED.length); i++) {
  check(EXPECTED[i], got[i] === EXPECTED[i], `got ${JSON.stringify(got[i])}`);
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
