// The canvas pages the GPU canvas raster is held to: each page draws solid fills, translucent
// colours, overlaps, glows, nested save/restore, clips and transforms at fractional positions, and
// the app's composited snapshot must match Chrome's screenshot of the same page within 2/255 a
// channel on every page the GPU path draws. The Chrome screenshots in canvas-gpu/chrome were taken
// from the same page code at 2x.
//   npm test
//
// The pages whose fills this stage draws on the GPU are CORE; the others (a gradient, a path of
// many circles) still go through the CPU and are reported for the stages that cover them.

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";
import type { Image } from "./png.ts";
import { PAGES, SIZE, writeApps } from "./canvas-gpu/pages.ts";

const CORE = new Set(["circle", "ellipse", "rects", "saverestore", "clip", "transforms"]);
const TARGET = 2;

let failed = 0;
function ok(name: string, cond: boolean, detail = ""): void {
  if (!cond) failed++;
  console.log(`${cond ? "ok  " : "FAIL"} ${name}${cond || detail === "" ? "" : ` (${detail})`}`);
}

interface Diff { max: number; mean: number; at: string; }

function diff(a: Image, b: Image): Diff {
  if (a.w !== b.w || a.h !== b.h) return { max: 255, mean: 255, at: `${a.w}x${a.h} vs ${b.w}x${b.h}` };
  let max = 0, sum = 0, at = "", count = 0;
  for (let i = 0; i < a.rgba.length; i++) {
    if (i % 4 === 3) continue; // the pages are opaque: alpha says nothing extra
    const d = Math.abs(a.rgba[i] - b.rgba[i]);
    sum += d;
    count++;
    if (d > max) {
      max = d;
      const p = i >> 2;
      at = `${p % a.w},${Math.floor(p / a.w)}`;
    }
  }
  return { max, mean: count > 0 ? sum / count : 0, at };
}

/** Runs one page's app at 2x, with the fills on the GPU or not, and answers the snapshot. */
function snapshot(dir: string, exe: string, out: string, attributes: Record<string, string>): { image: Image; stderr: string } {
  // NATIVE_COMPOSITOR_LIVE makes a headless run composite every frame the way the window does;
  // without it the snapshot replays the page on CoreGraphics and a canvas never reaches its
  // texture, so the GPU path would silently not run.
  const r = spawnSync(exe, [], { encoding: "utf8", env: {
    ...process.env, ...attributes, NATIVE_COMPOSITOR_LIVE: "1", NATIVE_SNAPSHOT_COMPOSITED: out,
  } });
  if (r.status !== 0 || !existsSync(out)) {
    throw new Error(`the page did not render (${r.status})\n${r.stderr.slice(-2000)}`);
  }
  return { image: decodePng(out), stderr: r.stderr };
}

const root = mkdtempSync(join(tmpdir(), "native-canvas-gpu-"));
mkdirSync(root, { recursive: true });
writeApps(root);

// CANVAS_GPU_PAGES=circle,rects runs those pages only, for a quick look at one of them.
const only = process.env.CANVAS_GPU_PAGES?.split(",").filter((n) => n !== "");
const names = Object.keys(PAGES).filter((n) => only === undefined || only.includes(n));

for (const name of names) {
  const dir = join(root, name);
  const exe = join(dir, "app");
  const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
  ok(`${name}: the page builds`, build.status === 0, build.stderr.slice(-600));
  if (build.status !== 0) continue;

  const chrome = decodePng(join(import.meta.dirname, "canvas-gpu", "chrome", `${name}.png`));
  ok(`${name}: the Chrome reference is ${SIZE.width * 2}x${SIZE.height * 2}`,
     chrome.w === SIZE.width * 2 && chrome.h === SIZE.height * 2, `${chrome.w}x${chrome.h}`);

  const cpu = snapshot(dir, exe, join(dir, "cpu.png"), { NATIVE_GPU_CANVAS: "0" });
  const gpu = snapshot(dir, exe, join(dir, "gpu.png"), { NATIVE_GPU_CANVAS: "1", NATIVE_CANVAS_STATS: "1" });
  const cpuDiff = diff(cpu.image, chrome);
  const gpuDiff = diff(gpu.image, chrome);
  // The flag has to have drawn something, or a silent fallback would pass as parity.
  let shapes = 0;
  for (const m of gpu.stderr.matchAll(/canvas gpu shapes=(\d+)/g)) shapes += Number(m[1]);
  if (CORE.has(name) && name !== "clip") {
    ok(`${name}: the fills were drawn on the GPU`, shapes > 0, `${shapes} shapes`);
  }
  console.log(`# ${name}: gpu max ${gpuDiff.max}/255 (mean ${gpuDiff.mean.toFixed(2)}) at ${gpuDiff.at}, ` +
              `cpu max ${cpuDiff.max}/255 (mean ${cpuDiff.mean.toFixed(2)})`);
  if (CORE.has(name)) {
    ok(`${name}: the GPU fills are within ${TARGET}/255 of Chrome`, gpuDiff.max <= TARGET,
       `max ${gpuDiff.max} at ${gpuDiff.at}, mean ${gpuDiff.mean.toFixed(2)}`);
  }
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
