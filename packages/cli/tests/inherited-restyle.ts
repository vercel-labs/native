// A restyle that changes only inherited, painted values reaches the descendants as inheritance
// does, without matching their selectors again, while the branches whose own values depend on
// what moved (currentColor, `inherit`, var()) still get their own pass. A theme switch on a class
// drives each page, and the snapshot checks the rows it repainted.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";
import type { Image } from "./png.ts";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-inherited-"));

function app(name: string, html: string): string {
  const d = join(dir, name);
  mkdirSync(d);
  writeFileSync(join(d, "index.html"), html);
  return d;
}

/** Builds the page and snapshots it after one frame, when its script has toggled the theme. */
function shot(d: string, exe: string, png: string): { status: number | null; out: string } {
  const b = spawnSync("node", ["compiler/cli.ts", "build", d, "-o", exe], { encoding: "utf8" });
  if (b.status !== 0) return { status: b.status, out: `${b.stdout}${b.stderr}` };
  const r = spawnSync(exe, [], {
    encoding: "utf8",
    env: { ...process.env, NATIVE_SNAPSHOT: png, NATIVE_STEPS: "frame 16" },
  });
  return { status: r.status, out: `${r.stdout}${r.stderr}` };
}

/** The colour at a CSS pixel; the snapshot draws two device pixels per CSS pixel. */
function at(img: Image, x: number, y: number): string {
  const i = ((y * 2) * img.w + x * 2) * 4;
  return `${img.rgba[i]},${img.rgba[i + 1]},${img.rgba[i + 2]}`;
}

// --- Only painted, inherited values moved: the fast path ---------------------------------------

// Each row is 20 CSS px tall: #a shows the body's background, #b the colour it inherits, #c a
// background it inherits explicitly, #d a declared colour that must not move, #e a currentColor
// background, and #f an em font size whose text is hidden behind its own background.
const FAST = `<!doctype html>
<html><head><meta charset="utf-8"><meta name="native-window" content="width=200, height=160">
<style>
body { margin: 0; color: #ff0000; background: #ffffff; }
body.dark { color: #00ff00; background: #0000ff; }
div { height: 20px; }
#b { background-color: currentColor; }
#c { background-color: inherit; }
#d { color: #123456; }
#d span { background-color: currentColor; height: 20px; display: block; }
#e { background-color: currentColor; }
#f { font-size: 2em; background-color: currentColor; }
.row:nth-child(even) { margin-left: 4px; }
</style></head><body>
<div id="a" class="row"></div>
<div id="b" class="row"></div>
<div id="c" class="row"></div>
<div id="d" class="row"><span></span></div>
<div id="e" class="row"></div>
<div id="f" class="row"></div>
<script>
requestAnimationFrame(function () { document.body.classList.add("dark"); });
</script>
</body></html>`;

const fastExe = join(dir, "fast-app");
const fastPng = join(dir, "fast.png");
const fast = shot(app("fast", FAST), fastExe, fastPng);
check("the theme page runs", fast.status === 0, fast.out.split("\n").slice(-4).join("\n"));
if (fast.status === 0) {
  const img = decodePng(fastPng);
  // Rows: a 0-19, b 20-39, c 40-59, d 60-79, e 80-99, f 100-119 (CSS px).
  check("the body's own paint moved", at(img, 100, 10) === "0,0,255", at(img, 100, 10));
  check("an inherited colour reaches a currentColor background", at(img, 100, 30) === "0,255,0", at(img, 100, 30));
  check("an explicitly inherited background takes the new value", at(img, 100, 50) === "0,0,255", at(img, 100, 50));
  check("a declared colour keeps its own value", at(img, 100, 70) === "18,52,86", at(img, 100, 70));
  check("currentColor follows the inherited colour", at(img, 100, 90) === "0,255,0", at(img, 100, 90));
  check("an em that doesn't depend on what moved keeps its value", at(img, 100, 110) === "0,255,0", at(img, 100, 110));
}

// --- The theme moves a custom property: every var() branch gets its own pass -------------------

const VARS = `<!doctype html>
<html><head><meta charset="utf-8"><meta name="native-window" content="width=200, height=120">
<style>
body { margin: 0; color: var(--fg); background: var(--bg); --fg: #ff0000; --bg: #ffffff; }
body.dark { --fg: #00ff00; --bg: #0000ff; }
div { height: 20px; }
#a { background-color: var(--fg); }
#b { background-color: var(--bg); }
#c { color: var(--fg); background-color: currentColor; }
</style></head><body>
<div id="a"></div>
<div id="b"></div>
<div id="c"></div>
<script>
requestAnimationFrame(function () { document.body.classList.add("dark"); });
</script>
</body></html>`;

const varsExe = join(dir, "vars-app");
const varsPng = join(dir, "vars.png");
const vars = shot(app("vars", VARS), varsExe, varsPng);
check("the var() theme page runs", vars.status === 0, vars.out.split("\n").slice(-4).join("\n"));
if (vars.status === 0) {
  const img = decodePng(varsPng);
  check("a var() background takes the theme's new colour", at(img, 100, 10) === "0,255,0", at(img, 100, 10));
  check("a var() that names the background takes the new world", at(img, 100, 30) === "0,0,255", at(img, 100, 30));
  check("a currentColor background follows the var() colour", at(img, 100, 50) === "0,255,0", at(img, 100, 50));
}

// --- A class the page names on an ancestor: the descendants are matched again ------------------

const ANCESTOR = `<!doctype html>
<html><head><meta charset="utf-8"><meta name="native-window" content="width=200, height=120">
<style>
body { margin: 0; color: #1f2937; background: #ffffff; }
.wrap { padding: 0; }
.wrap.dark .item { color: #00ff00; background-color: #0000ff; }
.item { height: 20px; background-color: #ffffff; }
</style></head><body>
<div id="wrap" class="wrap">
  <div class="item"></div>
  <div class="item"></div>
  <div class="item"></div>
</div>
<script>
requestAnimationFrame(function () { document.getElementById("wrap").classList.add("dark"); });
</script>
</body></html>`;

const ancExe = join(dir, "ancestor-app");
const ancPng = join(dir, "ancestor.png");
const anc = shot(app("ancestor", ANCESTOR), ancExe, ancPng);
check("the ancestor-class page runs", anc.status === 0, anc.out.split("\n").slice(-4).join("\n"));
if (anc.status === 0) {
  const img = decodePng(ancPng);
  check("a descendant rule sees the class its ancestor gained", at(img, 100, 10) === "0,0,255", at(img, 100, 10));
  check("every child of the ancestor is restyled", at(img, 100, 50) === "0,0,255", at(img, 100, 50));
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
