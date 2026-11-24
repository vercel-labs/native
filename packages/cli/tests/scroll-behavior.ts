// scroll-behavior: a script's scroll jumps or travels the way the box's computed value says.
// `smooth` eases to the target over animation frames, `auto` jumps there at once, and an explicit
// `behavior: "instant"` overrides the stylesheet. The value inherits, the root's reaches the
// viewport (a body's doesn't), and a wheel stops a journey where it has got to.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=800, height=600"><style>
html, body { margin: 0; }
body { font: 16px/1 monospace; }
/* A scroll container that travels, and one that jumps. */
#box { width: 200px; height: 200px; overflow: auto; }
.smooth { scroll-behavior: smooth; }
#inner { height: 2000px; }
#plain { width: 100px; height: 100px; overflow: auto; }
/* Enough content for the page itself to scroll. */
#page { height: 2000px; }
#log, button { position: fixed; left: 600px; }
#log { top: 0; }
#b1 { top: 30px; } #b2 { top: 60px; } #b3 { top: 90px; }
#b4 { top: 120px; } #b5 { top: 150px; } #b6 { top: 180px; }
</style></head>
<body>
<div id="box"><div id="inner"></div></div>
<div id="plain"></div>
<div id="page"></div>
<div id="log">0</div>
<button id="b1">scrollTo 300</button>
<button id="b2">scrollTop 100</button>
<button id="b3">instant 0</button>
<button id="b4">scrollBy 100</button>
<button id="b5">page 400</button>
<button id="b6">page 0</button>
<script>
const box = document.getElementById("box");
const log = document.getElementById("log");
let events = 0;
// Every move of a journey tells the page it scrolled.
box.addEventListener("scroll", () => { log.textContent = String(++events); });
box.className = "smooth";
const on = (id, fn) => document.getElementById(id).addEventListener("click", fn);
on("b1", () => { box.scrollTo(0, 300); });
on("b2", () => { box.scrollTop = 100; });
on("b3", () => { box.scrollTo({ top: 0, behavior: "instant" }); });
on("b4", () => { box.scrollBy({ top: 100 }); });
on("b5", () => { document.documentElement.className = "smooth"; window.scrollTo(0, 400); });
on("b6", () => { document.documentElement.className = ""; document.body.className = "smooth"; window.scrollTo(0, 0); });
const cs = (el) => getComputedStyle(el).getPropertyValue("scroll-behavior");
console.log("css=" + JSON.stringify([cs(box), cs(document.getElementById("inner")), cs(document.getElementById("plain")),
  typeof box.scroll, typeof box.scrollTo, typeof box.scrollBy, getComputedStyle(box).scrollBehavior]));
</script>
</body></html>`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-scroll-behavior-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

function run(steps: string[]): string[] {
  const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: steps.join(" | ") };
  delete env.NATIVE_SNAPSHOT;
  const r = spawnSync(exe, [], { encoding: "utf8", env });
  if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
  return r.stdout.split("\n").slice(0, -1);
}

// Each row: a step, and the lines it prints (empty when it prints nothing). `frame <ms>` runs the
// animation callbacks at that timestamp, which is how the journeys advance here.
const steps: string[] = [];
const want: string[] = [];
const labels: string[] = [];
function step(name: string, ...prints: string[]): void {
  steps.push(name);
  for (const p of prints) {
    want.push(p);
    labels.push(`${name}`);
  }
}

step("scrolltop #box", "0");
// A smooth scrollTo does not jump: it starts on the next animation frame and eases across.
step("click #b1");
step("scrolltop #box", "0");
step("frame 0");
step("scrolltop #box", "0");
step("frame 200");
step("scrolltop #box", "150");
step("frame 400");
step("scrolltop #box", "300");
step("print #log", "2");
// The scrollTop setter follows the same value, travelling from where the box is.
step("click #b2");
step("scrolltop #box", "300");
step("frame 400");
step("scrolltop #box", "300");
step("frame 600");
step("scrolltop #box", "200");
step("frame 800");
step("scrolltop #box", "100");
// behavior: "instant" overrides the stylesheet and puts the box there at once.
step("click #b3");
step("scrolltop #box", "0");
// scrollBy travels from where the box is now.
step("click #b4");
step("scrolltop #box", "0");
step("frame 800");
step("scrolltop #box", "0");
step("frame 1000");
step("scrolltop #box", "50");
step("frame 1200");
step("scrolltop #box", "100");
// The root's scroll-behavior reaches the viewport, and window.scrollTo travels.
step("click #b5");
step("scrolltop html", "0");
step("frame 1200");
step("scrolltop html", "0");
step("frame 1400");
step("scrolltop html", "200");
step("frame 1600");
step("scrolltop html", "400");
// A body's scroll-behavior doesn't reach the viewport: the page jumps.
step("click #b6");
step("scrolltop html", "0");
// A wheel over a travelling box jumps it by the wheel's delta and stops the journey.
step("click #b1");
step("frame 1600");
step("scrolltop #box", "100");
step("frame 1800");
step("scrolltop #box", "200");
step("wheel #box 100");
step("scrolltop #box", "300");
step("frame 2000");
step("scrolltop #box", "300");
step("frame 2200");
step("scrolltop #box", "300");
// An instant scroll in the middle of a journey lands at once and stops the journey there.
step("click #b2");
step("frame 2200");
step("scrolltop #box", "300");
step("frame 2400");
step("scrolltop #box", "200");
step("click #b3");
step("scrolltop #box", "0");
step("frame 2600");
step("scrolltop #box", "0");
// A second smooth scroll replaces the first, setting off from where it had got to.
step("click #b1");
step("frame 2600");
step("scrolltop #box", "0");
step("frame 2800");
step("scrolltop #box", "150");
step("click #b4");
step("scrolltop #box", "150");
step("frame 2800");
step("scrolltop #box", "150");
step("frame 3000");
step("scrolltop #box", "200");
step("frame 3200");
step("scrolltop #box", "250");

const lines = run(steps);
const css = lines[0].startsWith("css=") ? (JSON.parse(lines[0].slice(4)) as unknown[]) : null;
const got = lines.slice(1);
check(`print lines`, got.length === want.length, `got ${got.length}, want ${want.length}: ${JSON.stringify(got)}`);
for (let i = 0; i < Math.min(got.length, want.length); i++) {
  check(labels[i], got[i] === want[i], `got ${JSON.stringify(got[i])}, want ${JSON.stringify(want[i])}`);
}

check("the container's value reads as its keyword", css !== null && css[0] === "smooth", `got ${JSON.stringify(css?.[0])}`);
check("the value inherits", css !== null && css[1] === "smooth", `got ${JSON.stringify(css?.[1])}`);
check("an element without one reads auto", css !== null && css[2] === "auto", `got ${JSON.stringify(css?.[2])}`);
check("the element has scroll, scrollTo and scrollBy",
  css !== null && css[3] === "function" && css[4] === "function" && css[5] === "function", `got ${JSON.stringify(css?.slice(3))}`);
check("the camelCase accessor reads the same", css !== null && css[6] === "smooth", `got ${JSON.stringify(css?.[6])}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
