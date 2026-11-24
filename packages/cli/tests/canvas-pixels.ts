// The canvas 2D pixel API: getImageData reads the bitmap back as straight RGBA, putImageData
// writes pixels where it is told (whatever the transform and alpha are), and createImageData makes
// a blank one. The console checks read the bitmap back; the snapshot checks that what was written
// is what the page shows.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";
import type { Image } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=60, height=40"><style>
body { margin: 0; background: #ffffff; }
canvas { position: absolute; left: 0; top: 0; }
</style></head><body>
<canvas id="c" width="60" height="40"></canvas>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const ctx = (document.getElementById("c") as HTMLCanvasElement).getContext("2d")!;
const at = (data: ImageData, x: number, y: number): string => {
  const i = (y * data.width + x) * 4;
  return data.data[i] + "," + data.data[i + 1] + "," + data.data[i + 2] + "," + data.data[i + 3];
};

ctx.fillStyle = "#ff0000";
ctx.fillRect(0, 0, 20, 10);
const all = ctx.getImageData(0, 0, 60, 40);
console.log("size " + all.width + "x" + all.height + " bytes " + all.data.length);
console.log("inside " + at(all, 5, 5) + " outside " + at(all, 50, 30));

// A half-transparent pixel comes back straight, with its alpha.
ctx.fillStyle = "rgba(0, 0, 255, 0.5)";
ctx.fillRect(20, 0, 10, 10);
console.log("half " + at(ctx.getImageData(22, 2, 1, 1), 0, 0));

// A new image is blank, and putting it back writes the pixels it holds.
const patch = ctx.createImageData(4, 4);
console.log("patch " + patch.data.length + " " + at(patch, 3, 3));
for (let i = 0; i < patch.data.length; i += 4) { patch.data[i + 1] = 255; patch.data[i + 3] = 255; }
ctx.putImageData(patch, 40, 20);
const back = ctx.getImageData(40, 20, 4, 4);
console.log("patch back " + at(back, 0, 0) + " " + at(back, 3, 3));

// The dirty rect picks the pixels to write; the rest of the image is left alone.
const block = ctx.createImageData(8, 8);
for (let i = 0; i < block.data.length; i += 4) {
  block.data[i] = 255;
  block.data[i + 1] = 255;
  block.data[i + 2] = 0;
  block.data[i + 3] = 255;
}
ctx.putImageData(block, 44, 28, 2, 2, 4, 4);
const dirty = ctx.getImageData(44, 28, 8, 8);
console.log("dirty " + at(dirty, 0, 0) + " | " + at(dirty, 2, 2) + " " + at(dirty, 5, 5) + " | " + at(dirty, 7, 7));

// A rect that hangs off the bitmap reads transparent outside it, and writes only where it lands.
const off = ctx.getImageData(-5, -5, 10, 10);
console.log("off " + at(off, 0, 0) + " " + at(off, 9, 9));
const corner = ctx.createImageData(6, 6);
for (let i = 0; i < corner.data.length; i += 4) { corner.data[i + 2] = 255; corner.data[i + 3] = 255; }
ctx.putImageData(corner, -2, -2);
console.log("corner " + at(ctx.getImageData(0, 0, 1, 1), 0, 0) + " " + at(ctx.getImageData(1, 1, 1, 1), 0, 0)
  + " " + at(ctx.getImageData(30, 30, 1, 1), 0, 0));
`;

const EXPECTED = [
  "size 60x40 bytes 9600",
  "inside 255,0,0,255 outside 0,0,0,0",
  "half 0,0,255,128",
  "patch 64 0,0,0,0",
  "patch back 0,255,0,255 0,255,0,255",
  "dirty 0,0,0,0 | 255,255,0,255 255,255,0,255 | 0,0,0,0",
  "off 0,0,0,0 255,0,0,255",
  "corner 0,0,255,255 0,0,255,255 0,0,0,0",
];

const dir = mkdtempSync(join(tmpdir(), "native-canvas-pixels-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
const png = join(dir, "out.png");
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const got = r.stdout.split("\n").slice(0, -1);
const img: Image = decodePng(png);

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

check(`log lines (${EXPECTED.length})`, got.length === EXPECTED.length, `got ${JSON.stringify(got)}`);
for (let i = 0; i < Math.min(got.length, EXPECTED.length); i++) {
  check(EXPECTED[i], got[i] === EXPECTED[i], `got ${JSON.stringify(got[i])}`);
}

/** The pixel at CSS coordinates (cx, cy), as "r,g,b"; the snapshot is 2 device px per CSS px. */
function at(cx: number, cy: number): string {
  const o = (cy * 2 * img.w + cx * 2) * 4;
  return `${img.rgba[o]},${img.rgba[o + 1]},${img.rgba[o + 2]}`;
}

check("the red rect is on the page", at(5, 5) === "255,0,0", `got ${at(5, 5)}`);
check("putImageData's green block is on the page", at(41, 21) === "0,255,0" && at(48, 26) === "255,255,255",
  `got ${at(41, 21)} and ${at(48, 26)}`);
check("the dirty rect left its neighbours alone", at(47, 31) === "255,255,0" && at(45, 29) === "255,255,255",
  `got ${at(47, 31)} and ${at(45, 29)}`);
check("the corner write landed inside the bitmap", at(1, 1) === "0,0,255" && at(8, 8) === "255,0,0",
  `got ${at(1, 1)} and ${at(8, 8)}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
