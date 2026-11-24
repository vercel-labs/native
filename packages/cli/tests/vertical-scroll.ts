// A vertical scroller's scrollable extent follows the page's axes, not its frame's: a child wider
// than the box overflows across the page, so it is scrollWidth that grows, and the box's own
// inline size is what scrollHeight reports. A vertical box in a horizontal flow is a frame root,
// and its content reach was measured in the frame's axes (inline down the page, block across it).
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=300"><style>
body { margin: 0; font: 16px monospace; }
#v { writing-mode: vertical-lr; overflow: scroll; width: 200px; height: 150px; background: #eeeeee; }
#v > div { width: 400px; height: 100px; background: #8888ff; }
#h { overflow: scroll; width: 200px; height: 150px; background: #eeeeee; }
#h > div { width: 400px; height: 100px; background: #ff8888; }
#rl { writing-mode: vertical-rl; overflow: scroll; width: 200px; height: 150px; background: #eeeeee; }
#rl > div { width: 400px; height: 100px; background: #88ff88; }
#y { writing-mode: vertical-lr; direction: rtl; overflow: scroll; width: 200px; height: 150px; background: #eeeeee; }
#y > div { width: 100px; height: 300px; background: #ffff88; }
</style></head><body>
<div id="v"><div></div></div>
<div id="h"><div></div></div>
<div id="rl"><div></div></div>
<div id="y"><div></div></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function size(id: string): string {
  const el = document.getElementById(id)!;
  return "sw=" + el.scrollWidth + " sh=" + el.scrollHeight + " cw=" + el.clientWidth + " ch=" + el.clientHeight;
}
const v = document.getElementById("v")!;
v.scrollLeft = 100;
const rl = document.getElementById("rl")!;
const rlRest = rl.scrollLeft;
rl.scrollLeft = -50;
const rlMoved = rl.scrollLeft;
rl.scrollLeft = 40;
const rlClamped = rl.scrollLeft;
const y = document.getElementById("y")!;
const yRest = y.scrollTop;
y.scrollTop = -100;
const yMoved = y.scrollTop;
y.scrollTop = 40;
const yClamped = y.scrollTop;
console.log("OUT v " + size("v") + " left=" + v.scrollLeft + " | h " + size("h") +
  " | rl " + size("rl") + " rest=" + rlRest + " moved=" + rlMoved + " clamped=" + rlClamped +
  " | y " + size("y") + " rest=" + yRest + " moved=" + yMoved + " clamped=" + yClamped);
`;

const dir = mkdtempSync(join(tmpdir(), "native-vertical-scroll-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);
const run = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame 1" } });
if (run.status !== 0) throw new Error(`render failed\n${run.stderr}`);

const line = (run.stdout + run.stderr).split("\n").find((l) => l.startsWith("OUT ")) ?? "";
const got = line.replace(/^OUT /, "");
console.log(`     ${got}`);
const field = (name: string): string => {
  const at = got.indexOf(name + " ");
  if (at < 0) return "";
  const rest = got.slice(at + name.length + 1);
  const end = rest.indexOf(" | ");
  return end < 0 ? rest : rest.slice(0, end);
};

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const v = field("v");
const h = field("h");
check("a vertical scroller's wide child scrolls across the page", v.startsWith("sw=400 sh=150"), v);
check("its scrollport is the box's own size", v.indexOf("cw=200 ch=150") >= 0, v);
check("a vertical-lr scroller scrolls right from the left edge", v.indexOf("left=100") >= 0, v);
check("a horizontal scroller is measured in the page's axes", h.startsWith("sw=400 sh=150"), h);
const rl = field("rl");
check("a vertical-rl scroller reads 0 at its right-edge start", rl.indexOf("rest=0") >= 0, rl);
check("it scrolls left into negative scrollLeft", rl.indexOf("moved=-50") >= 0, rl);
check("a positive scrollLeft clamps to its start", rl.indexOf("clamped=0") >= 0, rl);
const y = field("y");
check("a vertical box with direction rtl starts at its bottom edge", y.indexOf("rest=0") >= 0, y);
check("its scrollTop runs negative upward", y.indexOf("moved=-100") >= 0, y);
check("a positive scrollTop clamps to its start", y.indexOf("clamped=0") >= 0, y);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
