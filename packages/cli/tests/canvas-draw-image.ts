// Canvas drawImage: an <img> blitted 1:1, scaled to a rect, and cut from a source rect into a
// scaled dest rect. The expected pixels are Chromium's for the same page (the image below, the
// same three calls); a scaled draw's filtering differs between engines, so pixels are compared
// with a small per-channel tolerance: cairo matches Chromium exactly, while CoreGraphics (and
// Direct2D) interpolate a scaled draw a little differently, so those allow a wider spread.
// Drawing the canvas into another canvas gives the same pixels back, and a canvas source drawn
// through a quarter turn at globalAlpha 0.5 lands where Chromium puts it.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const IMAGE = "iVBORw0KGgoAAAANSUhEUgAAAAQAAAACCAYAAAB/qH1jAAAAHElEQVR4AQ3BgQEAIAzDIOr/P2fCooWlePIlbHO76AkAyhaFkAAAAABJRU5ErkJggg==";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=300"><style>
body { margin: 0; }
canvas { display: block; }
</style></head><body>
<img id="i" src="data:image/png;base64,${IMAGE}">
<canvas id="c" width="16" height="8"></canvas>
<canvas id="d" width="16" height="8"></canvas>
<canvas id="s" width="8" height="4"></canvas>
<canvas id="t" width="16" height="8"></canvas>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const img = document.getElementById("i") as HTMLImageElement;
const canvas = document.getElementById("c") as HTMLCanvasElement;
const ctx = canvas.getContext("2d")!;
img.decode().then(() => {
  ctx.drawImage(img, 0, 0);
  ctx.drawImage(img, 6, 4, 4, 2);
  ctx.drawImage(img, 1, 0, 2, 2, 8, 6, 8, 4);
  const px = ctx.getImageData(0, 0, 16, 8).data;
  let line = "";
  for (let i = 0; i < px.length; i++) line += (i === 0 ? "" : ",") + px[i];
  console.log("px " + line);
  // A canvas source draws the same pixels into another canvas.
  const copy = document.getElementById("d") as HTMLCanvasElement;
  copy.getContext("2d")!.drawImage(canvas, 0, 0);
  const px2 = copy.getContext("2d")!.getImageData(0, 0, 16, 8).data;
  let line2 = "";
  for (let i = 0; i < px2.length; i++) line2 += (i === 0 ? "" : ",") + px2[i];
  console.log("copy " + line2);
  // A canvas source follows the context: a quarter turn and globalAlpha 0.5.
  const src = document.getElementById("s") as HTMLCanvasElement;
  const sc = src.getContext("2d")!;
  sc.fillStyle = "#ff0000"; sc.fillRect(0, 0, 4, 2);
  sc.fillStyle = "#00ff00"; sc.fillRect(4, 0, 4, 2);
  sc.fillStyle = "#0000ff"; sc.fillRect(0, 2, 4, 2);
  sc.fillStyle = "#ffff00"; sc.fillRect(4, 2, 4, 2);
  const rt = (document.getElementById("t") as HTMLCanvasElement).getContext("2d")!;
  rt.globalAlpha = 0.5;
  rt.setTransform(0, 1, -1, 0, 12, 2);
  rt.drawImage(src, 0, 0);
  const px3 = rt.getImageData(0, 0, 16, 8).data;
  let line3 = "";
  for (let i = 0; i < px3.length; i++) line3 += (i === 0 ? "" : ",") + px3[i];
  console.log("rot " + line3);
}).catch((e: Error) => { console.log("decode-failed " + e.message); });
`;

// Chromium 140, same page and calls: RGBA of the 16x8 canvas, row by row.
const CHROME = [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 0, 255, 0, 255, 255, 255, 255, 0, 255, 255, 0, 0, 0, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 0, 255, 0, 255, 255, 255, 255, 0, 255, 255, 0, 0, 0, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 95, 159, 0, 255, 31, 223, 0, 255, 0, 223, 31, 255, 0, 159, 95, 255, 0, 95, 159, 255, 0, 31, 223, 255, 31, 31, 255, 255, 95, 95, 255, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 95, 183, 39, 255, 31, 231, 55, 255, 7, 223, 87, 255, 23, 159, 135, 255, 39, 95, 183, 255, 55, 31, 231, 255, 79, 23, 247, 255, 111, 71, 231, 255];

// Chromium (Playwright 1.49), the same quarter-turn call at globalAlpha 0.5.
const ROT = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 128, 0, 0, 255, 128, 255, 0, 0, 128, 255, 0, 0, 128, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 128, 0, 0, 255, 128, 255, 0, 0, 128, 255, 0, 0, 128, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 128, 0, 0, 255, 128, 255, 0, 0, 128, 255, 0, 0, 128, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 128, 0, 0, 255, 128, 255, 0, 0, 128, 255, 0, 0, 128, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 0, 128, 255, 255, 0, 128, 0, 255, 0, 128, 0, 255, 0, 128, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 0, 128, 255, 255, 0, 128, 0, 255, 0, 128, 0, 255, 0, 128, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];

const dir = mkdtempSync(join(tmpdir(), "native-drawimage-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: "wait 500" };
delete env.NATIVE_SNAPSHOT;
const r = spawnSync(exe, [], { encoding: "utf8", env });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const lines = r.stdout.split("\n").filter((l) => l !== "");
const pxLine = lines.find((l) => l.startsWith("px "));
check("prints the canvas pixels", pxLine !== undefined);
if (pxLine) {
  const got = pxLine.slice(3).split(",").map(Number);
  check(`pixel count (${CHROME.length})`, got.length === CHROME.length, `got ${got.length}`);
  let maxDiff = 0;
  let sum = 0;
  const n = Math.min(got.length, CHROME.length);
  for (let i = 0; i < n; i++) {
    const d = Math.abs(got[i] - CHROME[i]);
    if (d > maxDiff) maxDiff = d;
    sum += d;
  }
  const mean = n === 0 ? 0 : sum / n;
  // CoreGraphics' interpolation for a scaled draw is a little softer than Chromium's and cairo's;
  // observed on macOS 26 it differs by at most the low 50s on a few channels of the 9-argument
  // draw, while the 1:1 and 5-argument draws match exactly. Other backends get the same room.
  const spread = process.platform === "linux" ? 12 : 56;
  check(`pixels within ${spread} of Chromium (max ${maxDiff}, mean ${mean.toFixed(2)})`,
    maxDiff <= spread && mean <= 2, `max ${maxDiff}, mean ${mean.toFixed(2)}`);
}
const copyLine = lines.find((l) => l.startsWith("copy "));
check("a canvas source draws the same pixels", copyLine !== undefined && pxLine !== undefined
  && copyLine.slice(5) === pxLine.slice(3));

const rotLine = lines.find((l) => l.startsWith("rot "));
check("prints the rotated canvas pixels", rotLine !== undefined);
if (rotLine) {
  const got = rotLine.slice(4).split(",").map(Number);
  check(`rotated pixel count (${ROT.length})`, got.length === ROT.length, `got ${got.length}`);
  let maxDiff = 0;
  let sum = 0;
  const n = Math.min(got.length, ROT.length);
  for (let i = 0; i < n; i++) {
    const d = Math.abs(got[i] - ROT[i]);
    if (d > maxDiff) maxDiff = d;
    sum += d;
  }
  const mean = n === 0 ? 0 : sum / n;
  // A quarter turn draws 1:1, so the pixels match apart from alpha rounding.
  check(`rotated pixels within 2 of Chromium (max ${maxDiff}, mean ${mean.toFixed(2)})`,
    maxDiff <= 2 && mean <= 1, `max ${maxDiff}, mean ${mean.toFixed(2)}`);
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
