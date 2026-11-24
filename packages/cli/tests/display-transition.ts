// display is a discrete property. A transition starts only where transition-behavior allows it,
// a box that wasn't rendered has no starting style, and the value flips at the end when it
// becomes none and at the start when it leaves none; two other values flip at half way.
// Every value here is what Chrome computes for the same page.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=500, height=400"><style>
body { margin: 0; }
.t { margin: 0; }
</style></head><body>
<div id="a" class="t">A</div><div id="b" class="t">B</div><div id="c" class="t">C</div>
<div id="d" class="t">D</div><div id="e" class="t">E</div><div id="f" class="t">F</div>
<div id="g" class="t">G</div><div id="h" class="t">H</div><div id="i" class="t">I</div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function log(s: string): void { console.log(s); }
// The WPT harness's overshoot easing: cubic-bezier(0, b, 1, b) with b = (8y - 1) / 6.
function easing(y: number): string {
  if (y === 0) return "steps(1, end)";
  if (y === 1) return "steps(1, start)";
  if (y === 0.5) return "linear";
  const b = (8 * y - 1) / 6;
  return "cubic-bezier(0, " + b + ", 1, " + b + ")";
}
function trans(el: HTMLElement, to: string, y: number, behavior: boolean): string {
  getComputedStyle(el).display;
  el.style.transitionDuration = "100s";
  el.style.transitionDelay = "-50s";
  el.style.transitionTimingFunction = easing(y);
  el.style.transitionProperty = "display";
  if (behavior) el.style.transitionBehavior = "allow-discrete";
  el.style.display = to;
  return getComputedStyle(el).display;
}
function anim(el: HTMLElement, from: string, to: string, y: number): string {
  const a = el.animate([{ display: from }, { display: to }], { duration: 100000, fill: "forwards", easing: easing(y) });
  a.pause();
  a.currentTime = 50000;
  return getComputedStyle(el).display;
}
const a = document.getElementById("a") as HTMLElement;
a.style.display = "block";
log("allow 0.9 " + trans(a, "none", 0.9, true));
const b = document.getElementById("b") as HTMLElement;
b.style.display = "block";
log("plain 0.5 " + trans(b, "none", 0.5, false));
const c = document.getElementById("c") as HTMLElement;
c.style.display = "none";
log("from-none 0.1 " + trans(c, "block", 0.1, true));
const d = document.getElementById("d") as HTMLElement;
d.style.display = "inline";
log("inline 0.4 " + trans(d, "block", 0.4, true));
const e = document.getElementById("e") as HTMLElement;
e.style.display = "inline";
log("inline 0.6 " + trans(e, "block", 0.6, true));
const f = document.getElementById("f") as HTMLElement;
f.style.display = "block";
log("anim-block 0.9 " + anim(f, "block", "none", 0.9));
const g = document.getElementById("g") as HTMLElement;
g.style.display = "none";
log("anim-none 0.1 " + anim(g, "none", "block", 0.1));
const h = document.getElementById("h") as HTMLElement;
h.style.display = "inline";
log("anim-inline 0.4 " + anim(h, "inline", "block", 0.4));
const i = document.getElementById("i") as HTMLElement;
i.style.display = "inline";
log("anim-inline 0.6 " + anim(i, "inline", "block", 0.6));
log("done");
`;

const EXPECTED = [
  "allow 0.9 block",
  "plain 0.5 none",
  "from-none 0.1 block",
  "inline 0.4 inline",
  "inline 0.6 block",
  "anim-block 0.9 block",
  "anim-none 0.1 block",
  "anim-inline 0.4 inline",
  "anim-inline 0.6 block",
  "done",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-display-transition-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);
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
