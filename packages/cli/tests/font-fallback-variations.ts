// A run that falls back to another face for a character must give that face the run's variation
// axes too. The primary font here has only "H", so every "a" is shaped and painted by the family
// list's fallback, a variable face: at wght 200 and then wght 800 the fallback's outlines must
// change with the run, not keep the first row's instance. The fixtures are 3.7 KB and 7 KB subsets
// of Geist Variable (see tests/fonts).
//   npm test

import { spawnSync } from "node:child_process";
import { copyFileSync, mkdtempSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

// The Linux host loads and paints the font files itself.
if (process.platform !== "linux") {
  console.log("ok   a fallback face takes the run's axes (skipped on this platform)");
  console.log("\nall passed");
  process.exit(0);
}

const primary = fileURLToPath(new URL("./fonts/Geist-Variable-H.ttf", import.meta.url));
const fallback = fileURLToPath(new URL("./fonts/Geist-Variable-Subset.ttf", import.meta.url));

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=220"><style>
body { margin: 0; background: #ffffff; }
@font-face { font-family: Var; src: url("primary.ttf"); }
@font-face { font-family: Fb; src: url("fallback.ttf"); }
.run { position: absolute; left: 10px; width: 380px; height: 90px; font: 48px Var, Fb;
       font-weight: 400; color: #000000; white-space: pre; }
#light { top: 10px; font-variation-settings: "wght" 200; }
#bold { top: 110px; font-variation-settings: "wght" 800; }
</style></head><body>
<div class="run" id="light">aa</div>
<div class="run" id="bold">aa</div>
</body></html>`;

const dir = mkdtempSync(join(tmpdir(), "native-font-fallback-"));
writeFileSync(join(dir, "index.html"), PAGE);
copyFileSync(primary, join(dir, "primary.ttf"));
copyFileSync(fallback, join(dir, "fallback.ttf"));
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const png = join(dir, "out.png");
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const img = decodePng(png);

/** The ink in a CSS-pixel rect, in device pixels. */
function ink(x0: number, y0: number, x1: number, y1: number): number {
  let count = 0;
  for (let y = Math.floor(y0 * 2); y < Math.ceil(y1 * 2); y++) {
    for (let x = Math.floor(x0 * 2); x < Math.ceil(x1 * 2); x++) {
      const o = (y * img.w + x) * 4;
      if (img.rgba[o] < 128 && img.rgba[o + 1] < 128 && img.rgba[o + 2] < 128) count++;
    }
  }
  return count;
}

const light = ink(10, 10, 390, 100);
const bold = ink(10, 110, 390, 200);
check("the fallback face draws the light run", light > 50, `ink ${light}`);
check("the fallback face draws the heavy run", bold > 50, `ink ${bold}`);
// Both rows fall back for every glyph; a host that configures only the primary face draws both
// at the fallback's default instance, so the ink is the same.
check("the fallback face takes the second run's weight too",
  bold > light * 1.2, `light ${light}, heavy ${bold}`);

if (failed > 0) {
  console.error(`\n${failed} check${failed === 1 ? "" : "s"} failed`);
  process.exit(1);
}
console.log("\nall fallback variation checks passed");
