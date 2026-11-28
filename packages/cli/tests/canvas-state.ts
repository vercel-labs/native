// The canvas drawing state save() and restore() carry: textAlign and textBaseline are part of it
// in the spec, and a page that sets them inside a save block must find the old ones back after
// the restore. Three rows of the same run place the ink by alignment and baseline; the third row
// must sit exactly where the first does.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=320, height=180"><style>
body { margin: 0; background: #ffffff; }
#c { position: absolute; left: 0; top: 0; width: 320px; height: 180px; }
</style></head><body>
<canvas id="c" width="320" height="180"></canvas>
<script>
const ctx = document.getElementById("c").getContext("2d");
ctx.font = "32px monospace";
ctx.fillStyle = "#000000";

// Row 1: start alignment, alphabetic baseline: the run begins at x=100, ink is above y=40.
ctx.fillText("MMMM", 100, 40);

// Row 2: inside a save, the run ends at x=200 and hangs below y=90.
ctx.save();
ctx.textAlign = "end";
ctx.textBaseline = "top";
ctx.fillText("MMMM", 200, 90);
ctx.restore();

// Row 3: after the restore the run must be placed exactly like row 1.
ctx.fillText("MMMM", 100, 150);
</script>
</body></html>`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-canvas-state-"));
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
const inked = (p: number[]): boolean => p[0] < 160 && p[1] < 160 && p[2] < 160;

/** Whether any ink lies in a CSS rect: a glyph's own strokes are thin, so a single sample can
 *  land in the gap between two of them. */
function inkIn(x0: number, y0: number, x1: number, y1: number): boolean {
  for (let y = y0; y < y1; y += 0.5) {
    for (let x = x0; x < x1; x += 0.5) if (inked(at(x, y))) return true;
  }
  return false;
}

// Row 1: start alignment, alphabetic baseline (ink above y=40, right of x=100).
check("a start-aligned run begins at its point", inkIn(101, 10, 130, 38));
check("a start-aligned run leaves nothing left of its point", !inkIn(78, 10, 97, 38));
// Row 2: end alignment and top baseline, inside the save block.
check("an end-aligned run ends at its point", inkIn(170, 92, 199, 110));
check("an end-aligned run leaves nothing right of its point", !inkIn(203, 92, 230, 110));
check("a top baseline hangs the run below its point", !inkIn(140, 70, 199, 86));
// Row 3: the restore brought both back, so it is placed exactly like row 1 — the ink starts at
// x=100 and sits above y=150. Before the restore is fixed it stays end-aligned (ink runs left of
// x=100, where a start-aligned run has none) and top-baselined (ink hangs below y=150).
check("restore brings start alignment back", inkIn(101, 126, 130, 148));
check("the restored run is not still end-aligned", !inkIn(20, 120, 98, 178));
check("restore brings the alphabetic baseline back", !inkIn(0, 152, 230, 178));

if (failed > 0) {
  console.error(`\n${failed} check${failed === 1 ? "" : "s"} failed`);
  process.exit(1);
}
console.log("\nall canvas state checks passed");
