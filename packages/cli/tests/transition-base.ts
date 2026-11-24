// A transition that starts during a style pass is visible to the read that caused it, and the
// styles resolved in that same pass already use the value it shows: a font size a transition
// moves decides the em lengths (and the rem lengths a root transition moves decide theirs), and a
// negative delay puts the transition partway in at the moment it starts. The reads here are
// Chrome's answers (css/css-transitions/transition-base-response-003 is the font-size case).
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=300"><style>
:root { font-size: 20px; }
body { margin: 0; font: 13px monospace; }
#a { margin-left: 100px; transition: margin-left 10s -5s linear; }
#b { margin-left: 100px; transition: margin-left 10s -5s linear; }
#c { font-size: 10px; min-width: 1em; transition: font-size steps(2, start) 10s; }
#c.change { font-size: 20px; }
#d { width: 1rem; }
:root.change { transition: font-size steps(2, start) 10s; font-size: 30px; }
#e { font-size: 10px; min-width: 1em; transition: font-size 1s linear; }
#e.change { font-size: 20px; }
#g { transform: none; transition: transform 2s linear; }
</style></head><body>
<div id="a">a</div><div id="b">b</div><div id="c">c</div><div id="d">d</div><div id="e">e</div><div id="g">g</div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function log(s: string): void { console.log(s); }
const a = document.getElementById("a") as HTMLElement;
const b = document.getElementById("b") as HTMLElement;
const c = document.getElementById("c") as HTMLElement;
const d = document.getElementById("d") as HTMLElement;
const e = document.getElementById("e") as HTMLElement;
const g = document.getElementById("g") as HTMLElement;
const root = document.documentElement;
let cRuns = 0;
let cCancels = 0;
c.addEventListener("transitionrun", () => { cRuns++; });
c.addEventListener("transitioncancel", () => { cCancels++; });

// The read is the page's first style pass: it records the baseline 100px, and the change after
// it starts a transition already 5s into its 10s linear run.
log("a-before " + getComputedStyle(a).marginLeft);
a.style.marginLeft = "200px";
log("a-mid " + getComputedStyle(a).marginLeft);

// b was styled by the pass above, so its own change has a baseline too.
b.style.marginLeft = "200px";
log("b-mid " + getComputedStyle(b).marginLeft);

// A font-size transition with a step function: its size at progress 0 is 15px, and the 1em
// min-width resolves against that, in the same pass that starts the transition.
log("c-before " + getComputedStyle(c).minWidth);
c.className = "change";
log("c-mid " + getComputedStyle(c).minWidth);

// A linear font-size transition on the element itself, and a rem length under a root whose font
// size transitions: the em and rem lengths follow the sizes the transitions show.
log("e-before " + getComputedStyle(e).minWidth);
e.className = "change";
log("d-before " + getComputedStyle(d).width);
root.className = "change";
log("d-mid " + getComputedStyle(d).width);

// Reading an offset settles the pending style and layout, so this transform change transitions
// from the none the first read laid out. Were the offset read to leave the style work pending,
// the first pass would see the change as the initial style and start no transition at all.
g.offsetTop;
g.style.transform = "rotateX(180deg)";
g.offsetTop;
log("g-anims " + g.getAnimations().length);

let n = 0;
function loop(): void {
  log("f" + n + " a=" + getComputedStyle(a).marginLeft + " c=" + getComputedStyle(c).minWidth +
    " d=" + getComputedStyle(d).width + " e=" + getComputedStyle(e).minWidth);
  n++;
  if (n < 3) {
    requestAnimationFrame(loop);
    return;
  }
  // The extra pass the font-size transition asks for must not restart it: the transition was
  // created once, and never canceled.
  log("c-runs " + cRuns + " c-cancels " + cCancels);
}
requestAnimationFrame(loop);
`;

// The mid values match Chrome. At 0ms the transitions are at their start (a is 5s in because of
// its delay), at 500ms each has moved, and at 1000ms the 1s linear transition has ended while the
// 10s step ones hold their first half. A restart of c or e at its end (a pass that saw the
// cascaded size rather than the one the transition showed) would leave them one step behind.
const EXPECTED = [
  "a-before 100px",
  "a-mid 150px",
  "b-mid 150px",
  "c-before 10px",
  "c-mid 15px",
  "e-before 10px",
  "d-before 20px",
  "d-mid 25px",
  "g-anims 1",
  "f0 a=150px c=15px d=25px e=10px",
  "f1 a=155px c=15px d=25px e=15px",
  "f2 a=160px c=15px d=25px e=20px",
  "c-runs 1 c-cancels 0",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-transition-base-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: "frame 0 | frame 500 | frame 1000" };
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
