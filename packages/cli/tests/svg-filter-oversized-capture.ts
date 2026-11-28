// A capture the host cannot take must still paint the element. A blur wide enough to reach past
// the host's 16384-pixel side grows the capture rect with its margin; the painter drops the
// margins and filters the region, so the element is drawn (and the engine reports its layer),
// where before the whole element was skipped. Only a region that is itself too big falls back to
// painting the element unfiltered.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=800, height=1200"><style>
body { margin: 0; background: #ffffff; }
svg { position: absolute; left: 0; width: 800px; height: 600px; }
#a { top: 0; }
#b { top: 600px; }
</style></head><body>
<svg id="a" viewBox="0 0 800 600">
  <defs>
    <!-- Three standard deviations of this blur are 12000 device px a side, so the capture would
         run far past the host's 16384-px surface; the region itself is 1600x1200 device. -->
    <filter id="huge" filterUnits="userSpaceOnUse" x="0" y="0" width="800" height="600"
            color-interpolation-filters="sRGB"><feGaussianBlur stdDeviation="4000"/></filter>
  </defs>
  <rect x="100" y="100" width="100" height="100" fill="#ff0000" filter="url(#huge)"/>
</svg>
<svg id="b" viewBox="0 0 800 600">
  <defs>
    <filter id="soft" filterUnits="userSpaceOnUse" x="0" y="0" width="800" height="600"
            color-interpolation-filters="sRGB"><feGaussianBlur stdDeviation="6"/></filter>
  </defs>
  <rect x="100" y="100" width="100" height="100" fill="#ff0000" filter="url(#soft)"/>
</svg>
</body></html>`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-svg-oversized-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const png = join(dir, "out.png");
const r = spawnSync(exe, [], {
  encoding: "utf8",
  env: { ...process.env, NATIVE_SNAPSHOT: png, NATIVE_SVG_FILTER_STATS: "1" },
});
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);

/** The layer stats one SVG's paint reported, if it painted a filter at all. */
function stats(svg: string): { peak: number } | null {
  const m = new RegExp(`svg=${svg} peak=(\\d+)`).exec(r.stdout);
  return m === null ? null : { peak: Number(m[1]) };
}
const huge = stats("a");
// A skipped element still paints its SVG, so the stats line can exist with no layer at all: the
// filter ran only if it reports bytes.
check("a capture past the host surface still runs the filter",
  huge !== null && huge.peak > 0, huge === null ? "no stats for svg a" : `peak ${huge.peak}`);
check("the oversized capture's layer is the region, not the margin",
  huge !== null && huge.peak > 0 && huge.peak <= 16 * 1024 * 1024,
  huge === null ? "no stats" : `peak ${huge.peak}`);

const img = decodePng(png);
const at = (cx: number, cy: number): number[] => {
  const o = (Math.floor(cy * 2) * img.w + Math.floor(cx * 2)) * 4;
  return [img.rgba[o], img.rgba[o + 1], img.rgba[o + 2]];
};
// The second SVG is the fixture's own measure of a blur that fits: it tints just outside the rect.
check("a blur the capture fits still filters", stats("b") !== null, "no stats for svg b");
const edge = at(96, 600 + 150);
check("its result is a blur at the rect's edge", edge[0] > 240 && edge[1] < 245,
  `edge ${edge.join(",")}`);

if (failed > 0) {
  console.error(`\n${failed} check${failed === 1 ? "" : "s"} failed`);
  process.exit(1);
}
console.log("\nall oversized capture checks passed");
