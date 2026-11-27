// A nested filter is clamped to the layer it paints into, not to the root viewport measured in
// that layer's local pixels. A child placed near its parent filter region's right edge has a
// region that runs past the parent; nothing it paints past the parent's edge is in the parent to
// begin with, and a layer sized from the root's width would both allocate past the region and
// measure its region in the wrong space. The test checks the filtered pixels are there and that
// no layer is wider than the parent filter region.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=200"><style>
body { margin: 0; background: #ffffff; }
#s { position: absolute; left: 0; top: 0; width: 400px; height: 200px; }
</style></head><body>
<svg id="s" viewBox="0 0 400 200">
  <defs>
    <!-- The outer region is the 100 px band at x=100..200, so its layer is 200 device px wide
         at 2x; the child sits at local 190 and its own region runs past that edge. -->
    <filter id="outer" filterUnits="userSpaceOnUse" x="100" y="0" width="100" height="100"
            color-interpolation-filters="sRGB"><feGaussianBlur stdDeviation="0.5"/></filter>
    <filter id="inner" color-interpolation-filters="sRGB"><feGaussianBlur stdDeviation="2"/></filter>
  </defs>
  <g filter="url(#outer)">
    <rect x="190" y="20" width="40" height="40" fill="#ff0000" filter="url(#inner)"/>
  </g>
</svg>
</body></html>`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-nested-offset-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const png = join(dir, "out.png");
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png, NATIVE_SVG_FILTER_STATS: "1" } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const img = decodePng(png);
const at = (cx: number, cy: number): number[] => {
  const o = (Math.floor(cy * 2) * img.w + Math.floor(cx * 2)) * 4;
  return [img.rgba[o], img.rgba[o + 1], img.rgba[o + 2]];
};

// The child's blur is visible inside the parent region: user x 190..200 is its left part.
const inside = at(195, 40);
check("a nested filter on an offset child paints inside its parent region",
  inside[0] > 200 && inside[1] < 200 && inside[2] < 200, `got ${inside.join(",")}`);
// Its middle, outside the outer region, is clipped by the outer filter region.
check("the outer filter region clips what is past its edge", at(220, 40).every((v) => v > 245), `got ${at(220, 40).join(",")}`);

// The region's far edge: the outer region is 100 user units = 200 device px wide, and the nested
// child's region ends at 268 device px if it is clamped against the root viewport in this
// layer-local space, or at 200 if it is clamped to the layer it paints into.
const edge = /nested=(\d+)x(\d+)/.exec(r.stdout);
check("a nested region is clamped to the layer it paints into",
  edge !== null && Number(edge[1]) <= 200, edge === null ? "no stats" : `edge ${edge[1]}x${edge[2]}`);

if (failed > 0) {
  console.error(`\n${failed} check${failed === 1 ? "" : "s"} failed`);
  process.exit(1);
}
console.log("\nall nested offset filter checks passed");
