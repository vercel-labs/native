// The SVG filter painter's memory bounds. A filtered element paints into a layer the size of its
// filter region; nesting is capped, the pooled layer bytes are capped, and past either cap the
// element paints unfiltered. Four hostile shapes are measured at 800x600 and 2x: deep nesting,
// a huge declared region, many filtered siblings, and an SVG removed from the page. The engine
// reports each paint's peak layer bytes on stdout with NATIVE_SVG_FILTER_STATS, and on Linux the
// child's peak RSS is sampled too; without the bounds a 30-deep filter nesting peaks near 400 MB
// on a 1000x700 SVG, and every nesting level keeps a root-sized bitmap (the coordinator's probe:
// 200 levels at 800x600 retain 368 MB even for a 1x1 region).
//   npm test

import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

const BOX_W = 800, BOX_H = 600;
const DEEP = 30;
const HUGE = 10;
const SIBLINGS = 200;
const MiB = 1024 * 1024;

function wrapped(inner: string, filter: string, count: number): string {
  let s = inner;
  for (let i = 0; i < count; i++) s = `<g filter="url(#${filter})">${s}</g>`;
  return s;
}

let siblings = "";
for (let i = 0; i < SIBLINGS; i++) {
  const x = (i % 20) * 20, y = Math.floor(i / 20) * 20;
  siblings += `<rect x="${x}" y="${y}" width="16" height="16" fill="#880088" filter="url(#soft)"/>`;
}

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=${BOX_W}, height=${BOX_H * 4}"><style>
body { margin: 0; background: #ffffff; }
svg { position: absolute; left: 0; width: ${BOX_W}px; height: ${BOX_H}px; }
#deep { top: 0; }
#huge { top: ${BOX_H}px; }
#sibs { top: ${BOX_H * 2}px; }
#gone { top: ${BOX_H * 3}px; }
</style></head><body>
<svg id="deep" viewBox="0 0 ${BOX_W} ${BOX_H}">
  <defs><filter id="soft" color-interpolation-filters="sRGB"><feGaussianBlur stdDeviation="2"/></filter></defs>
  ${wrapped(`<circle cx="400" cy="300" r="24" fill="#ff0000"/>`, "soft", DEEP)}
</svg>
<svg id="huge" viewBox="0 0 ${BOX_W} ${BOX_H}">
  <defs><filter id="hugeF" color-interpolation-filters="sRGB" filterUnits="userSpaceOnUse"
    x="-1000000" y="-1000000" width="2000000" height="2000000"><feGaussianBlur stdDeviation="1"/></filter></defs>
  ${wrapped(`<rect x="380" y="280" width="40" height="40" fill="#00aa00"/>`, "hugeF", HUGE)}
</svg>
<svg id="sibs" viewBox="0 0 ${BOX_W} ${BOX_H}">
  ${siblings}
</svg>
<svg id="gone" viewBox="0 0 ${BOX_W} ${BOX_H}">
  <defs><filter id="goneF" color-interpolation-filters="sRGB" filterUnits="userSpaceOnUse"
    x="-1000000" y="-1000000" width="2000000" height="2000000"><feGaussianBlur stdDeviation="1"/></filter></defs>
  ${wrapped(`<rect x="380" y="280" width="40" height="40" fill="#00aa00"/>`, "goneF", HUGE)}
</svg>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
if (process.env.NATIVE_BOUNDS_UNMOUNT === "1") {
  // One frame later: the first frame has painted the big filters, so their layers exist and the
  // removal can prove they are given back.
  requestAnimationFrame(() => requestAnimationFrame(() => {
    const gone = document.getElementById("gone");
    if (gone !== null) gone.remove();
    const huge = document.getElementById("huge");
    if (huge !== null) huge.remove();
  }));
}
`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

interface Run {
  code: number | null;
  stdout: string;
  peakKb: number;
}

/** Runs the app, sampling its peak RSS on Linux; extraEnv reaches the app's script. */
async function run(exe: string, png: string, extraEnv: Record<string, string> = {}): Promise<Run> {
  return await new Promise((resolve, reject) => {
    const child = spawn(exe, [], {
      env: {
        ...process.env, NATIVE_SNAPSHOT: png, NATIVE_STEPS: "frame | frame | frame | frame",
        NATIVE_SVG_FILTER_STATS: "1", ...extraEnv,
      },
    });
    let stdout = "";
    let peakKb = 0;
    child.stdout.on("data", (d) => (stdout += d));
    child.stderr.on("data", (d) => (stdout += d));
    const timer = setInterval(() => {
      try {
        const status = readFileSync(`/proc/${child.pid}/status`, "utf8");
        const m = /VmHWM:\s+(\d+) kB/.exec(status);
        if (m) peakKb = Math.max(peakKb, Number(m[1]));
      } catch {
        // Not Linux: no /proc, so the RSS check is skipped below.
      }
    }, 5);
    child.on("error", reject);
    child.on("close", (code) => {
      clearInterval(timer);
      resolve({ code, stdout, peakKb });
    });
  });
}

interface Stat { svg: string; peak: number; depth: number; pool: number }
function stats(text: string): Stat[] {
  const out: Stat[] = [];
  const re = /native: svg filter layers svg=(\S*) peak=(\d+) depth=(\d+) pool=(\d+)/g;
  for (const m of text.matchAll(re)) {
    out.push({ svg: m[1], peak: Number(m[2]), depth: Number(m[3]), pool: Number(m[4]) });
  }
  return out;
}
function worst(list: Stat[]): Record<string, Stat> {
  const out: Record<string, Stat> = {};
  for (const s of list) {
    const held = out[s.svg];
    if (held === undefined) out[s.svg] = { ...s };
    else {
      held.peak = Math.max(held.peak, s.peak);
      held.depth = Math.max(held.depth, s.depth);
      held.pool = Math.max(held.pool, s.pool);
    }
  }
  return out;
}

const dir = mkdtempSync(join(tmpdir(), "native-svg-bounds-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
await new Promise<void>((resolve, reject) => {
  const b = spawn("node", ["compiler/cli.ts", "build", dir, "-o", exe], { stdio: "ignore" });
  b.on("error", reject);
  b.on("exit", (code) => (code === 0 ? resolve() : reject(new Error(`build failed with ${code}`))));
});

// Run 1: every case stays in the page. Stats, painted pixels and peak RSS are asserted.
const png = join(dir, "out.png");
const first = await run(exe, png);
if (first.code !== 0) throw new Error(`render failed\n${first.stdout}`);
const img = decodePng(png);
const list = stats(first.stdout);
const per = worst(list);
check("the engine reports its layer use", list.length > 0, "no stats lines");

check("deep nesting keeps every layer to its region",
  (per.deep?.peak ?? Infinity) < 4 * MiB, `peak ${per.deep?.peak} bytes`);
check("deep nesting stops nesting at the depth cap", (per.deep?.depth ?? 0) === 16, `depth ${per.deep?.depth}`);
check("deep nesting still paints its content", (() => {
  const o = (300 * 2 * img.w + 400 * 2) * 4; // (400, 300) CSS at 2x
  return img.rgba[o] > 200 && img.rgba[o + 1] < 80 && img.rgba[o + 2] < 80;
})(), "the circle's middle is not red");

check("huge filter regions stay inside the memory cap",
  (per.huge?.peak ?? Infinity) <= 64 * MiB, `peak ${per.huge?.peak} bytes`);
check("huge filter regions stop at the depth the cap allows", (per.huge?.depth ?? 0) <= 16, `depth ${per.huge?.depth}`);
check("a filter past the cap still paints its content unfiltered", (() => {
  const o = ((BOX_H + 300) * 2 * img.w + 400 * 2) * 4;
  return img.rgba[o] < 80 && img.rgba[o + 1] > 120 && img.rgba[o + 2] < 80;
})(), "the square's middle is not green");

check("many filtered siblings reuse one region layer",
  (per.sibs?.peak ?? Infinity) < 2 * MiB, `peak ${per.sibs?.peak} bytes`);
check("many filtered siblings do not nest", (per.sibs?.depth ?? 0) <= 1, `depth ${per.sibs?.depth}`);
check("a sibling's content paints", (() => {
  const o = ((BOX_H * 2 + 8) * 2 * img.w + 8 * 2) * 4;
  return img.rgba[o] > 120 && img.rgba[o + 1] < 140 && img.rgba[o + 2] > 120;
})(), "the first sibling is not purple");

check("the pooled bitmaps stay under the memory cap",
  Math.max(...list.map((s) => s.pool)) <= 64 * MiB, `pool ${Math.max(...list.map((s) => s.pool))} bytes`);
if (first.peakKb > 0) {
  check("the render stays far below the unbounded peak", first.peakKb < 260_000, `${first.peakKb} kB peak RSS`);
} else {
  console.log("ok   peak RSS sampled on Linux only (skipped here)");
}

// Run 2: the big SVGs are removed after the first frame. The pool was large, then it is given
// back; the last paint runs with only the small shapes.
const second = await run(exe, join(dir, "gone.png"), { NATIVE_BOUNDS_UNMOUNT: "1" });
if (second.code !== 0) throw new Error(`render failed\n${second.stdout}`);
const after = stats(second.stdout);
const maxPool = Math.max(...after.map((s) => s.pool));
const lastPool = after.length > 0 ? after[after.length - 1].pool : -1;
check("the removed SVG's layers had been allocated", maxPool >= 40 * MiB, `max pool ${maxPool} bytes`);
check("removing the SVG releases the pooled layers", lastPool >= 0 && lastPool < 8 * MiB, `last pool ${lastPool} bytes`);

if (failed > 0) {
  console.error(`\n${failed} check${failed === 1 ? "" : "s"} failed`);
  process.exit(1);
}
console.log("\nall svg filter bounds checks passed");
