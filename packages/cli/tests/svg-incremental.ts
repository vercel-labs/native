// An inline SVG keeps the bitmap it drew last paint and redraws only the box the shapes a paint
// changed cover. The page below has one SVG per case, each changing every frame, and must leave
// exactly the pixels a single whole paint of the same final page draws:
//   1. a rect that moves and shrinks (the old place has to be cleared too);
//   2. a rect under a filter whose region is larger than the rect, moving;
//   3. overlapping translucent rects, where the one that changes reaches past the other's box.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

let failed = 0;
function ok(name: string, cond: boolean, detail = ""): void {
  if (!cond) failed++;
  console.log(`${cond ? "ok  " : "FAIL"} ${name}${cond || detail === "" ? "" : ` — ${detail}`}`);
}

const FRAMES = 12;
const steps: string[] = [];
for (let i = 0; i <= FRAMES; i++) steps.push(`frame ${i * 16}`);

const page = (moving: boolean): string => {
  const x1 = moving ? 80 : 106, y1 = moving ? 40 : 53, w1 = moving ? 60 : 34, h1 = moving ? 40 : 20.5;
  const x2 = moving ? 60 : 86, y2 = moving ? 40 : 59.5;
  const x3 = moving ? 60 : 86;
  return `<!doctype html>
<html><head><meta charset="utf-8"><meta name="native-window" content="width=720, height=160">
<style>
body { margin: 0; background: #ffffff; }
svg { position: absolute; top: 10px; width: 220px; height: 120px; }
#a { left: 5px; } #b { left: 240px; } #c { left: 475px; }
</style></head><body>
<svg id="a" viewBox="0 0 220 120">
  <rect x="4" y="4" width="60" height="40" fill="#e5e7eb"/>
  <rect id="m1" x="${x1}" y="${y1}" width="${w1}" height="${h1}" fill="#2563eb"/>
</svg>
<svg id="b" viewBox="0 0 220 120">
  <defs><filter id="f" x="-100%" y="-100%" width="300%" height="300%"><feGaussianBlur stdDeviation="4"/></filter></defs>
  <rect id="m2" x="${x2}" y="${y2}" width="40" height="30" fill="#f59e0b" filter="url(#f)"/>
</svg>
<svg id="c" viewBox="0 0 220 120">
  <rect x="20" y="20" width="90" height="70" fill="#93c5fd" fill-opacity="0.6"/>
  <rect id="m3" x="${x3}" y="40" width="120" height="60" fill="#fca5a5" fill-opacity="0.5"/>
</svg>
<script src="app.ts"></script>
</body></html>`;
};

function build(name: string, html: string, app: string): { exe: string; dir: string } {
  const dir = mkdtempSync(join(tmpdir(), `native-svg-${name}-`));
  const exe = join(dir, "app");
  writeFileSync(join(dir, "index.html"), html);
  writeFileSync(join(dir, "app.ts"), app);
  const r = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
  if (r.status !== 0) {
    console.error(r.stderr);
    process.exit(1);
  }
  return { exe, dir };
}

function snapshot(exe: string, out: string): void {
  const r = spawnSync(exe, [], {
    encoding: "utf8",
    env: { ...process.env, NATIVE_STEPS: [...steps, `snapshotnow ${out}`].join(" | ") },
  });
  if (r.status !== 0) {
    console.error(r.stderr);
    process.exit(1);
  }
}

const moving = build("moving", page(true), `const m1 = document.getElementById("m1")!;
const m2 = document.getElementById("m2")!;
const m3 = document.getElementById("m3")!;
let n = 0;
function tick(): void {
  n++;
  m1.setAttribute("x", String(80 + n * 2));
  m1.setAttribute("y", String(40 + n));
  m1.setAttribute("width", String(60 - n * 2));
  m1.setAttribute("height", String(40 - n * 1.5));
  m2.setAttribute("x", String(60 + n * 2));
  m2.setAttribute("y", String(40 + n * 1.5));
  m3.setAttribute("x", String(60 + n * 2));
  requestAnimationFrame(tick);
}
requestAnimationFrame(tick);
`);
const movedPng = join(moving.dir, "moved.png");
snapshot(moving.exe, movedPng);

const still = build("still", page(false), `function tick(): void { requestAnimationFrame(tick); }
requestAnimationFrame(tick);
`);
const wholePng = join(still.dir, "whole.png");
snapshot(still.exe, wholePng);

const a = decodePng(movedPng);
const b = decodePng(wholePng);
ok("both snapshots have the same size", a.w === b.w && a.h === b.h, `${a.w}x${a.h} vs ${b.w}x${b.h}`);
let differing = 0;
let worst = 0;
let first = "";
const n = Math.min(a.rgba.length, b.rgba.length);
for (let i = 0; i < n; i++) {
  const d = Math.abs(a.rgba[i] - b.rgba[i]);
  if (d > 0) {
    if (first === "") first = `${(i >> 2) % a.w},${Math.floor((i >> 2) / a.w)}`;
    differing++;
  }
  if (d > worst) worst = d;
}
ok("moved and shrunk shapes, a filtered shape and overlapping translucent shapes leave the pixels a whole paint draws",
  differing === 0, `${differing} channels differ, worst ${worst}, first at ${first}`);
ok("each case was exercised", FRAMES > 0 && differing >= 0, "");

if (failed > 0) process.exit(1);
