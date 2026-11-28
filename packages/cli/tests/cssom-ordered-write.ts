// A write to a declaration block is skipped only when the block it leaves is the one it found:
// order counts. `all: initial` after a colour resets it, and the same colour written again after
// that reset must win again; a longhand after a shorthand wins, and the shorthand written again
// after the longhand wins again too. The computed values are Chrome's.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=200, height=100"><style>
body { margin: 0; }
#box { width: 50px; height: 50px; }
</style></head><body>
<div id="box"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const box = document.getElementById("box") as HTMLElement;
const style = box.style;
// A colour, then a reset of everything, then the same colour again: the second write is a new
// declaration after the reset, so it wins.
style.color = "red";
style.all = "initial";
style.color = "red";
console.log("all color=" + getComputedStyle(box).color);
// A shorthand, then a longhand, then the shorthand again: each later write wins.
style.margin = "10px";
style.marginLeft = "20px";
console.log("longhand margin-left=" + getComputedStyle(box).marginLeft);
style.margin = "30px";
console.log("shorthand margin-left=" + getComputedStyle(box).marginLeft);
// The same write twice changes nothing the second time, and the block stays what it was.
style.color = "blue";
style.color = "blue";
console.log("twice color=" + getComputedStyle(box).color);
// A later declaration after all: initial, with the same all: initial written again: a scripted
// write keeps the declaration where it already is, so the colour written after it still wins.
// Chrome 158 reads rgb(255, 0, 0) here.
style.all = "initial";
style.color = "red";
console.log("later color=" + getComputedStyle(box).color);
style.all = "initial";
console.log("reset color=" + getComputedStyle(box).color);
// A parsed block applies each all: initial where it is written, so the second one, after the
// colour, resets it. Chrome 158 reads rgb(0, 0, 0).
box.style.cssText = "all: initial; color: red; all: initial";
console.log("parsed reset color=" + getComputedStyle(box).color);
`;

const EXPECTED = [
  "all color=rgb(255, 0, 0)",
  "longhand margin-left=20px",
  "shorthand margin-left=30px",
  "twice color=rgb(0, 0, 255)",
  "later color=rgb(255, 0, 0)",
  "reset color=rgb(255, 0, 0)",
  "parsed reset color=rgb(0, 0, 0)",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-cssom-ordered-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame 0 | frame 16" } });
if (r.status !== 0) throw new Error(`run failed\n${r.stderr}`);
const got = r.stdout.split("\n").filter((line) => line.includes("="));
check(`log lines (${EXPECTED.length})`, got.length === EXPECTED.length, `got ${got.length}: ${JSON.stringify(got)}`);
for (let i = 0; i < Math.min(got.length, EXPECTED.length); i++) {
  check(EXPECTED[i], got[i] === EXPECTED[i], `got ${JSON.stringify(got[i])}`);
}

if (failed > 0) {
  console.error(`\n${failed} check${failed === 1 ? "" : "s"} failed`);
  process.exit(1);
}
console.log("\nall ordered-write checks passed");
