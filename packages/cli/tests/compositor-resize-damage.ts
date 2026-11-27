// A damaged frame that lands while the window is resizing. The compositor patches a picture of
// the last frame it drew; a view that changed size has no picture of the new size, so such a frame
// has to paint the page whole. Drawing its damaged display list as a whole frame clears the
// picture to the background and paints only the damaged regions, and the window presents the
// rest empty — the bare window (a flat grey) until the next full paint.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=240, height=180"><style>
body { margin: 0; background: #0a0c10; }
#card { position: absolute; left: 10px; top: 10px; width: 100px; height: 60px; background: #22c55e; }
#label { position: absolute; left: 10px; top: 90px; color: #ffffff; font: 12px sans-serif; }
</style></head><body>
<div id="card"></div>
<div id="label">before</div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const label = document.getElementById("label") as HTMLElement;
document.addEventListener("click", () => {
  // The view resizes now; the frame this click calls for is still a damage frame unless the host
  // says the picture can't take it.
  window.resizeTo(320, 240);
  label.textContent = "after";
});
`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-compositor-resize-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const flat = join(dir, "flat.png");
const composited = join(dir, "composited.png");
const r = spawnSync(exe, [], {
  encoding: "utf8",
  env: {
    ...process.env,
    NATIVE_STEPS: "frame 0 | frame 16 | click #label | frame 32 | frame 48",
    NATIVE_SNAPSHOT: flat,
    NATIVE_SNAPSHOT_COMPOSITED: composited,
    NATIVE_COMPOSITOR_LIVE: "1",
  },
});
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);

/** The pixels at CSS coordinates (cx, cy), as [r, g, b], of a 2x snapshot. */
function at(path: string, cx: number, cy: number): number[] {
  const img = decodePng(path);
  const o = (Math.floor(cy * 2) * img.w + Math.floor(cx * 2)) * 4;
  return [img.rgba[o], img.rgba[o + 1], img.rgba[o + 2]];
}

const CARD = [34, 197, 94];
const near = (got: number[], want: number[], tol = 8): boolean => got.every((g, i) => Math.abs(g - want[i]) <= tol);
const dark = (got: number[]): boolean => got[0] < 40 && got[1] < 40 && got[2] < 40;

// The card is where it was after a resize: the frame painted the page whole rather than drawing
// only the damaged label onto an empty picture.
for (const path of [flat, composited]) {
  const kind = path === flat ? "flat" : "composited";
  check(`the ${kind} frame keeps the card across a resize`, near(at(path, 50, 40), CARD), `got ${at(path, 50, 40).join(",")}`);
  check(`the ${kind} frame keeps the page background across a resize`, dark(at(path, 200, 150)), `got ${at(path, 200, 150).join(",")}`);
}

if (failed > 0) {
  console.error(`\n${failed} check${failed === 1 ? "" : "s"} failed`);
  process.exit(1);
}
console.log("\nall compositor resize checks passed");
