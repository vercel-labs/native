// text-decoration-inset holds two insets, the start and the end, and interpolates them as
// lengths: `auto` stands for the length the line metrics choose at the element's current font
// size (so it re-resolves when the size changes mid-animation), and a percentage mixes with a
// length through a calc(). Every value here is what Chrome computes for the same page.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=500, height=300"><style>
body { margin: 0; font-size: 16px; }
.t { display: inline-block; }
</style></head><body>
<span id="m" class="t">M</span><span id="a" class="t">A</span><span id="b" class="t">B</span>
<span id="c" class="t">C</span><span id="d" class="t">D</span><span id="e" class="t">E</span>
<span id="f" class="t">F</span><span id="g" class="t">G</span>
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
function sample(el: HTMLElement, from: string, to: string, y: number): string {
  const a = el.animate([{ textDecorationInset: from }, { textDecorationInset: to }], { duration: 100000, fill: "forwards", easing: easing(y) });
  a.pause();
  a.currentTime = 50000;
  return getComputedStyle(el).textDecorationInset;
}
const m = document.getElementById("m") as HTMLElement;
m.style.textDecorationInset = "auto";
// A paused auto-to-0px animation at its start shows auto as the length it stands for.
const ma = m.animate([{ textDecorationInset: "auto" }, { textDecorationInset: "0px" }], { duration: 1000, fill: "none" });
ma.pause();
ma.currentTime = 0;
log("av " + parseFloat(getComputedStyle(m).textDecorationInset));
const a = document.getElementById("a") as HTMLElement;
a.style.textDecorationInset = "auto";
log("a-0.125 " + sample(a, "auto", "10px -20px", 0.125));
const b = document.getElementById("b") as HTMLElement;
b.style.textDecorationInset = "auto";
log("b-0 " + sample(b, "10%", "auto", 0));
const c = document.getElementById("c") as HTMLElement;
c.style.textDecorationInset = "auto";
log("c-0.5 " + sample(c, "10%", "auto", 0.5));
const d = document.getElementById("d") as HTMLElement;
d.style.textDecorationInset = "auto";
log("d-1 " + sample(d, "10%", "auto", 1));
const e = document.getElementById("e") as HTMLElement;
e.style.textDecorationInset = "auto";
log("e-0.125 " + sample(e, "0px", "10px -20px", 0.125));
const f = document.getElementById("f") as HTMLElement;
f.style.textDecorationInset = "auto";
log("f-auto " + sample(f, "auto", "auto", 0.5));
const g = document.getElementById("g") as HTMLElement;
g.style.textDecorationInset = "auto";
g.style.fontSize = "10px";
log("g-10 " + sample(g, "auto", "10px", 0.5));
g.style.fontSize = "40px";
log("g-40 " + getComputedStyle(g).textDecorationInset);
log("done");
`;

const EXPECTED = [
  "av 1",
  "a-0.125 2.125px -1.625px",
  "b-0 10%",
  "c-0.5 calc(5% + 0.5px)",
  "d-1 calc(0% + 1px)",
  "e-0.125 1.25px -2.5px",
  "f-auto auto",
  "g-10 5.5px",
  "g-40 6px",
  "done",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-inset-interp-"));
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
