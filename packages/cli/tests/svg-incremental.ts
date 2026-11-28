// An inline SVG keeps the bitmap it drew last paint and redraws only the box the shapes a paint
// changed cover. The page below moves one rect of a three-rect SVG on every frame; the same page
// with the rect moved once, in its first paint, must come out byte identical: the incremental
// repaint has to leave every pixel the whole repaint would have drawn.
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
const START = 80;
const STEP = 2;
const END = START + (FRAMES + 1) * STEP;
const page = (x: number): string => `<!doctype html>
<html><head><meta charset="utf-8"><meta name="native-window" content="width=240, height=140">
<style>
body { margin: 0; background: #ffffff; }
svg { position: absolute; left: 10px; top: 10px; width: 220px; height: 120px; }
</style></head><body>
<svg viewBox="0 0 220 120">
  <rect x="4" y="4" width="60" height="40" fill="#e5e7eb"/>
  <rect id="m" x="${x}" y="40" width="60" height="40" fill="#2563eb"/>
  <circle cx="180" cy="60" r="24" fill="#f59e0b"/>
</svg>
<script src="app.ts"></script>
</body></html>`;

const steps: string[] = [];
for (let i = 0; i <= FRAMES; i++) steps.push(`frame ${i * 16}`);

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

// One rect moved on every frame: ten part-redraws of a canvas that is never drawn whole again.
const moving = build("moving", page(START), `const m = document.getElementById("m")!;
let n = 0;
function tick(): void {
  n++;
  m.setAttribute("x", String(${START} + n * ${STEP}));
  requestAnimationFrame(tick);
}
requestAnimationFrame(tick);
`);
const movedPng = join(moving.dir, "moved.png");
snapshot(moving.exe, movedPng);

// The same page, the same final rect position, drawn whole in its first paint.
const still = build("still", page(END), `function tick(): void { requestAnimationFrame(tick); }
requestAnimationFrame(tick);
`);
const wholePng = join(still.dir, "whole.png");
snapshot(still.exe, wholePng);

const a = decodePng(movedPng);
const b = decodePng(wholePng);
ok("both snapshots have the same size", a.w === b.w && a.h === b.h, `${a.w}x${a.h} vs ${b.w}x${b.h}`);
let differing = 0;
let worst = 0;
const n = Math.min(a.rgba.length, b.rgba.length);
for (let i = 0; i < n; i++) {
  const d = Math.abs(a.rgba[i] - b.rgba[i]);
  if (d > 0) differing++;
  if (d > worst) worst = d;
}
ok("rects moved over several paints leave the pixels a whole paint draws", differing === 0,
  `${differing} channels differ, worst ${worst}`);

if (failed > 0) process.exit(1);
