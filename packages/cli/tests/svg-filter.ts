// Inline SVG filters: a <filter> named by an element's filter attribute runs over the element's
// finished picture, in device pixels, through the host's portable filter engine. The primitives
// feGaussianBlur, feOffset, feColorMatrix, feBlend, feMerge, feFlood, feComposite and feDropShadow
// are each checked by sampling the snapshot at known places, and the wiring between them by the
// colours only a correct in/in2/result graph reaches.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=160"><style>
body { margin: 0; background: #ffffff; }
#fx { position: absolute; left: 0; top: 0; width: 400px; height: 160px; }
</style></head><body>
<svg id="fx" viewBox="0 0 400 160">
  <defs>
    <filter id="blur" color-interpolation-filters="sRGB" x="-100%" y="-100%" width="300%" height="300%">
      <feGaussianBlur stdDeviation="4"/>
    </filter>
    <filter id="offset" color-interpolation-filters="sRGB" x="-100%" y="-100%" width="300%" height="300%">
      <feOffset dx="20" dy="0"/>
    </filter>
    <filter id="swap" color-interpolation-filters="sRGB">
      <feColorMatrix type="matrix" values="0 1 0 0 0  1 0 0 0 0  0 0 1 0 0  0 0 0 1 0"/>
    </filter>
    <filter id="saturate" color-interpolation-filters="sRGB">
      <feColorMatrix type="saturate" values="0"/>
    </filter>
    <filter id="glow" color-interpolation-filters="sRGB" x="-50%" y="-50%" width="200%" height="200%">
      <feGaussianBlur stdDeviation="3" result="b"/>
      <feMerge>
        <feMergeNode in="b"/>
        <feMergeNode in="SourceGraphic"/>
      </feMerge>
    </filter>
    <filter id="halo" color-interpolation-filters="sRGB" x="-50%" y="-50%" width="200%" height="200%">
      <feGaussianBlur in="SourceAlpha" stdDeviation="3" result="b"/>
      <feFlood flood-color="#ff00ff" result="c"/>
      <feComposite in="c" in2="b" operator="in" result="d"/>
      <feMerge>
        <feMergeNode in="d"/>
        <feMergeNode in="SourceGraphic"/>
      </feMerge>
    </filter>
    <filter id="mult" color-interpolation-filters="sRGB">
      <feFlood flood-color="#00ff00" result="g"/>
      <feBlend in="SourceGraphic" in2="g" mode="multiply"/>
    </filter>
    <filter id="shadow" color-interpolation-filters="sRGB" x="-50%" y="-50%" width="200%" height="200%">
      <feDropShadow dx="8" dy="8" stdDeviation="2" flood-color="#000000" flood-opacity="0.75"/>
    </filter>
  </defs>
  <rect x="10" y="10" width="30" height="30" fill="#ff0000" filter="url(#blur)"/>
  <rect x="70" y="10" width="20" height="20" fill="#00ff00" filter="url(#offset)"/>
  <rect x="110" y="10" width="20" height="20" fill="#ff0000" filter="url(#swap)"/>
  <rect x="150" y="10" width="20" height="20" fill="#0000ff" filter="url(#glow)"/>
  <rect x="190" y="10" width="20" height="20" fill="#ffff00" filter="url(#halo)"/>
  <rect x="230" y="10" width="20" height="20" fill="#ff0000" filter="url(#mult)"/>
  <rect x="270" y="10" width="20" height="20" fill="#ff0000" filter="url(#saturate)"/>
  <rect x="310" y="10" width="20" height="20" fill="#00ff00" filter="url(#shadow)"/>
  <rect x="10" y="90" width="20" height="20" fill="#ff0000" style="filter: url(#offset)"/>
  <rect x="40" y="90" width="20" height="20" fill="#0000ff" opacity="0.5"/>
</svg>
</body></html>`;

const dir = mkdtempSync(join(tmpdir(), "native-svg-filter-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const png = join(dir, "out.png");
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const img = decodePng(png);

/** The pixel at CSS coordinates (cx, cy), as [r, g, b]. */
function at(cx: number, cy: number): number[] {
  const o = (Math.floor(cy * 2) * img.w + Math.floor(cx * 2)) * 4;
  return [img.rgba[o], img.rgba[o + 1], img.rgba[o + 2]];
}

function near(cx: number, cy: number, want: number[], tol = 6): string | null {
  const got = at(cx, cy);
  return got.every((g, i) => Math.abs(g - want[i]) <= tol) ? null : `got ${got.join(",")}, want about ${want.join(",")}`;
}

const RED = [255, 0, 0], GREEN = [0, 255, 0], BLUE = [0, 0, 255], WHITE = [255, 255, 255],
  BLACK = [0, 0, 0];

let failed = 0;
function check(name: string, bad: string | null): void {
  if (bad !== null) failed++;
  console.log(`${bad === null ? "ok  " : "FAIL"} ${name}${bad === null ? "" : ` — ${bad}`}`);
}

/** Something between the page's white and the shape's colour, for a blurred edge. */
function tinted(cx: number, cy: number, channel: number, above: number, below: number): string | null {
  const got = at(cx, cy);
  return got[channel] > above && got[channel] < below ? null : `got ${got.join(",")}`;
}

// feGaussianBlur: the shape keeps its middle and fades past its own edge.
check("a blur keeps the shape's middle solid", near(25, 25, RED));
check("a blur spreads past the shape's edge", tinted(42, 25, 1, 110, 235));
check("a blur leaves the page clear well outside", near(60, 25, WHITE));

// feOffset moves the picture.
check("an offset moves the shape by dx", near(105, 20, GREEN));
check("an offset leaves where the shape was empty", near(75, 20, WHITE));

// feColorMatrix, as a matrix and as a saturation.
check("a colour matrix swaps the channels", near(120, 20, GREEN));
check("a saturating matrix at zero makes grey", near(280, 20, [54, 54, 54], 12));

// feGaussianBlur + feMerge: the blurred copy under the source graphic is a glow.
check("a merged blurred copy glows outside the shape", tinted(173, 20, 0, 20, 240));
check("the glow leaves the shape's middle solid", near(160, 20, BLUE));

// feFlood + feComposite in + feMerge: a coloured halo from the blurred alpha. Just outside the
// shape the halo is a translucent magenta over the white page, not full magenta.
{
  const halo = at(213, 20);
  check("a flood masked by the blurred alpha glows",
    halo[0] > 245 && halo[2] > 245 && halo[1] < 235 ? null : `got ${halo.join(",")}`);
}

// feBlend multiply: red over green is black.
check("a multiply blend mixes the source with the flood", near(240, 20, BLACK, 8));

// The same filter from a style="" declaration.
check("a style filter moves the shape by dx", near(34, 100, RED));
check("a style filter leaves where the shape was empty", near(15, 100, WHITE));

// feDropShadow: a dark shadow below and right of the shape, which itself stays solid.
check("a drop shadow darkens beside the shape", tinted(335, 35, 0, 20, 200));
check("a drop shadow leaves the shape solid", near(320, 20, GREEN));

if (failed > 0) {
  console.error(`\n${failed} check${failed === 1 ? "" : "s"} failed`);
  process.exit(1);
}
console.log("\nall svg filter checks passed");
