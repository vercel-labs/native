// A filter's buffers share one budget with its layer. Every primitive keeps its own result, so a
// small page that declares a big region and a long chain could ask the host for hundreds of
// megabytes: the chain must stop at the budget and leave the element unfiltered rather than hand
// back a partial result. The page holds two filters over the same 2200x1600 device region: a
// short chain that fits runs, and a long one that does not.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=1100, height=800"><style>
body { margin: 0; background: #ffffff; }
svg { position: absolute; left: 0; width: 1100px; height: 800px; }
</style></head><body>
<svg viewBox="0 0 1100 800">
  <defs>
    <!-- The whole viewport in device pixels: 2200x1600, 14 MB a buffer at 2x. -->
    <filter id="one" filterUnits="userSpaceOnUse" x="0" y="0" width="1100" height="800"
            color-interpolation-filters="sRGB"><feGaussianBlur stdDeviation="8"/></filter>
    <filter id="many" filterUnits="userSpaceOnUse" x="0" y="0" width="1100" height="800"
            color-interpolation-filters="sRGB">
      <feGaussianBlur stdDeviation="8"/>
      <feGaussianBlur stdDeviation="8"/>
      <feGaussianBlur stdDeviation="8"/>
      <feGaussianBlur stdDeviation="8"/>
      <feGaussianBlur stdDeviation="8"/>
      <feGaussianBlur stdDeviation="8"/>
    </filter>
  </defs>
  <rect x="100" y="100" width="200" height="200" fill="#ff0000" filter="url(#one)"/>
  <rect x="600" y="100" width="200" height="200" fill="#ff0000" filter="url(#many)"/>
</svg>
</body></html>`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-svg-budget-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const png = join(dir, "out.png");
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const img = decodePng(png);
const at = (cx: number, cy: number): number[] => {
  const o = (Math.floor(cy * 2) * img.w + Math.floor(cx * 2)) * 4;
  return [img.rgba[o], img.rgba[o + 1], img.rgba[o + 2]];
};

// A blur of 8 user px tints the page just outside a rect's edge; an unfiltered rect leaves it
// white. Both rects are sampled the same way above their top edge.
const near = (cx: number): number[] => at(cx, 94);
check("a chain inside the budget filters", near(200)[0] > 250 && near(200)[1] < 250,
  `one blur at (200,94): ${near(200).join(",")}`);
const over = near(700);
check("a chain past the budget paints the element unfiltered",
  over.every((v) => v > 250), `six blurs at (700,94): ${over.join(",")}`);
const inside = at(700, 200);
check("the unfiltered rect keeps its own pixels", inside[0] > 240 && inside[1] < 20 && inside[2] < 20,
  `six blurs at (700,200): ${inside.join(",")}`);

if (failed > 0) {
  console.error(`\n${failed} check${failed === 1 ? "" : "s"} failed`);
  process.exit(1);
}
console.log("\nall svg filter budget checks passed");
