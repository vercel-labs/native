// Keyboard focus draws the system's focus ring around the focused box, the way Chrome on macOS
// does for :focus-visible; a pointer press focuses without it.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=120, height=80"><style>
body { margin: 0; background: #ffffff; }
#b { position: absolute; left: 20px; top: 20px; width: 40px; height: 20px; background: #000000; }
</style></head><body>
<div id="b" tabindex="0"></div>
</body></html>`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-focus-ring-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

/** The snapshot after `steps`. */
function shot(steps: string, name: string): { w: number; h: number; rgba: Uint8Array } {
  const png = join(dir, name + ".png");
  const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: steps, NATIVE_SNAPSHOT: png } });
  if (r.status !== 0) throw new Error(`render failed ('${steps}')\n${r.stderr}`);
  return decodePng(png);
}

/** How many pixels just outside the box's left edge (CSS x 16..19, mid box) aren't white. */
function ringPixels(img: { w: number; rgba: Uint8Array }): number {
  let n = 0;
  for (let x = 16; x < 20; x++) {
    for (let y = 28; y < 32; y++) {
      const o = (y * 2 * img.w + x * 2) * 4;
      if (img.rgba[o] < 250 || img.rgba[o + 1] < 250 || img.rgba[o + 2] < 250) n++;
    }
  }
  return n;
}

const tab = shot("key Tab", "tab");
check("Tab draws a ring just outside the box", ringPixels(tab) >= 2, `${ringPixels(tab)} ring pixels`);
const boxPx = (28 * 2 * tab.w + 30 * 2) * 4;
check("the box itself still paints black", tab.rgba[boxPx] < 20 && tab.rgba[boxPx + 1] < 20 && tab.rgba[boxPx + 2] < 20,
  `${tab.rgba[boxPx]},${tab.rgba[boxPx + 1]},${tab.rgba[boxPx + 2]}`);

const click = shot("click #b", "click");
check("a pointer press draws no ring", ringPixels(click) === 0, `${ringPixels(click)} ring pixels`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
