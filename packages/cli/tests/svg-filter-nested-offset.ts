// Nested filters and where their source comes from. A filter inside another filter's layer
// measures its region in that layer's pixels, so it is clamped to the layer it paints into, not
// to the root viewport measured in that space. Its source, though, is the element's own drawing:
// the surface it is captured on also holds the element's box, so a primitive can move or blur
// content into the region from outside it, as a renderer that keeps the source for the whole
// chain does. Both are checked here, and so is the clamp: no region may run past the layer it
// paints into.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=400"><style>
body { margin: 0; background: #ffffff; }
svg { position: absolute; left: 0; width: 400px; height: 200px; }
#s { top: 0; }
#t { top: 200px; }
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
<svg id="t" viewBox="0 0 400 200">
  <defs>
    <!-- Same parent band. The offset child sits at x=210, right of the parent's edge; its own
         region reaches from 140 to 260, so the offset carries it to 150..170 inside the band. -->
    <filter id="outer2" filterUnits="userSpaceOnUse" x="100" y="0" width="100" height="100"
            color-interpolation-filters="sRGB"><feGaussianBlur stdDeviation="0.5"/></filter>
    <filter id="moved" filterUnits="userSpaceOnUse" x="140" y="0" width="120" height="100"
            color-interpolation-filters="sRGB"><feOffset dx="-60" dy="0"/></filter>
    <!-- The blurred child sits at 202..212, outside the band; its region reaches back to 185, so
         the blur's left tail falls inside the band. -->
    <filter id="soft" filterUnits="userSpaceOnUse" x="185" y="40" width="50" height="80"
            color-interpolation-filters="sRGB"><feGaussianBlur stdDeviation="10"/></filter>
  </defs>
  <g filter="url(#outer2)">
    <rect x="210" y="20" width="20" height="40" fill="#ff0000" filter="url(#moved)"/>
    <rect x="202" y="60" width="10" height="40" fill="#ff0000" filter="url(#soft)"/>
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
const white = (p: number[]): boolean => p.every((v) => v > 245);
const reddish = (p: number[]): boolean => p[0] - Math.max(p[1], p[2]) > 40;

// --- The clamp: a nested region stays inside the layer it paints into --------------------------
// The child's blur is visible inside the parent region: user x 190..200 is its left part.
const inside = at(195, 40);
check("a nested filter on an offset child paints inside its parent region",
  inside[0] > 200 && inside[1] < 200 && inside[2] < 200, `got ${inside.join(",")}`);
// Its middle, outside the outer region, is clipped by the outer filter region.
check("the outer filter region clips what is past its edge", white(at(220, 40)), `got ${at(220, 40).join(",")}`);
// The nested region must end inside the layer it paints into — the parent's capture surface,
// 260 device px wide here — not at the root bitmap's 800 device px, which is what it measured
// itself against when the bound was the root viewport in this layer-local space.
const edge = /svg=s .*nested=(\d+)x(\d+) clamp=(\d+)x/.exec(r.stdout);
check("a nested region is bounded by the layer it paints into",
  edge !== null && Number(edge[1]) <= Number(edge[3]) && Number(edge[3]) < 800,
  edge === null ? "no stats" : `edge ${edge[1]} clamped to ${edge[3]}`);

// --- The source: content outside the region can be moved or blurred into it -------------------
// The offset child starts at x=210 outside the band and lands at 150..170 inside it.
check("an offset carries source into the parent region from outside it",
  reddish(at(160, 240)), `got ${at(160, 240).join(",")}`);
check("nothing paints between the moved child and the band's right edge",
  white(at(190, 240)), `got ${at(190, 240).join(",")}`);
check("the offset moved only where it landed", white(at(105, 240)), `got ${at(105, 240).join(",")}`);
// The blurred child starts just outside the band at 202; its tail falls back into it.
const tail = at(196, 280);
check("a blur pulls source into the parent region from outside it",
  tail[0] - Math.max(tail[1], tail[2]) > 5, `got ${tail.join(",")}`);
check("the blur leaves the rest of the band alone", white(at(160, 280)), `got ${at(160, 280).join(",")}`);

if (failed > 0) {
  console.error(`\n${failed} check${failed === 1 ? "" : "s"} failed`);
  process.exit(1);
}
console.log("\nall nested offset filter checks passed");
