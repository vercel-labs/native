// A vertical box's width is its block size: the extent its lines take across the page. A float or
// an absolutely positioned box has to know that width before it lays its content out, so it is
// measured with the content turned — the stack of lines, not the width of the text on one line.
// The block below it takes the same text and height, and shrinks to its content in the ordinary
// layout, so the three boxes must come out the same width.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=520"><style>
body { margin: 0; font: 20px/20px monospace; }
.stage { position: relative; width: 400px; height: 160px; }
.stage.f { overflow: hidden; }
#f { float: left; writing-mode: vertical-lr; height: 140px; background: #eeeeee; }
#a { position: absolute; top: 10px; writing-mode: vertical-lr; height: 140px; background: #dddddd; }
#d { writing-mode: vertical-lr; height: 140px; background: #cccccc; }
</style></head><body>
<div class="stage f"><div id="f">aaaaa bbbbb ccccc ddddd eeeee fffff ggggg hhhhh</div></div>
<div class="stage"><div id="a">aaaaa bbbbb ccccc ddddd eeeee fffff ggggg hhhhh</div></div>
<div class="stage"><div id="d">aaaaa bbbbb ccccc ddddd eeeee fffff ggggg hhhhh</div></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function size(id: string): string {
  const el = document.getElementById(id)!;
  return el.offsetWidth + "x" + el.offsetHeight;
}
console.log("OUT " + size("f") + " " + size("a") + " " + size("d"));
`;

const dir = mkdtempSync(join(tmpdir(), "native-vertical-intrinsic-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);
const run = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame 1" } });
if (run.status !== 0) throw new Error(`render failed\n${run.stderr}`);

const line = (run.stdout + run.stderr).split("\n").find((l) => l.startsWith("OUT ")) ?? "";
const [f, a, d] = line.replace(/^OUT /, "").split(" ");
console.log(`     float=${f} absolute=${a} block=${d}`);

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

check("the block's height wraps the text into a stack of lines", d !== undefined && d.endsWith("x140"), d);
check("a float takes the block's width", f === d, `float=${f} block=${d}`);
check("an absolutely positioned box takes the block's width", a === d, `absolute=${a} block=${d}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
