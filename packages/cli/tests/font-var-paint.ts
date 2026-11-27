// A variable font's per-run variation settings must reach the outline the host paints, not only
// the advances layout measures. The same four glyphs at wght 200 and wght 800 are sampled from a
// snapshot: the heavy run must carry more ink and a different width, or the host drew both at the
// face's default instance. The font fixture is a 7 KB subset of Geist Variable (see tests/fonts).
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

// The Linux host loads and paints the font files itself; other platforms hand them to the system
// font stack, which this test is not about.
if (process.platform !== "linux") {
  console.log("ok   a variable font's run axes are painted by the Linux host (skipped on this platform)");
  console.log("\nall passed");
  process.exit(0);
}

const font = fileURLToPath(new URL("./fonts/Geist-Variable-Subset.ttf", import.meta.url));

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=220"><style>
body { margin: 0; background: #ffffff; }
@font-face { font-family: Var; src: url("var.ttf"); }
.run { position: absolute; left: 10px; width: 380px; height: 90px; font: 48px Var;
       font-weight: 400; color: #000000; white-space: pre; }
#light { top: 10px; font-variation-settings: "wght" 200; }
#bold { top: 110px; font-variation-settings: "wght" 800; }
</style></head><body>
<div class="run" id="light">HHHH</div>
<div class="run" id="bold">HHHH</div>
</body></html>`;

const dir = mkdtempSync(join(tmpdir(), "native-font-variations-"));
writeFileSync(join(dir, "index.html"), PAGE);
copyFileSync(font, join(dir, "var.ttf"));
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const png = join(dir, "out.png");
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const img = decodePng(png);

/** The ink in a CSS-pixel rect: its pixel count and its left/right extent in device pixels. */
function ink(x0: number, y0: number, x1: number, y1: number): { count: number; left: number; right: number } {
  let count = 0, left = Infinity, right = -Infinity;
  for (let y = Math.floor(y0 * 2); y < Math.ceil(y1 * 2); y++) {
    for (let x = Math.floor(x0 * 2); x < Math.ceil(x1 * 2); x++) {
      const o = (y * img.w + x) * 4;
      if (img.rgba[o] < 128 && img.rgba[o + 1] < 128 && img.rgba[o + 2] < 128) {
        count++;
        if (x < left) left = x;
        if (x > right) right = x;
      }
    }
  }
  return { count, left, right };
}

const light = ink(10, 10, 390, 100);
const bold = ink(10, 110, 390, 200);
check("the light run draws its glyphs", light.count > 100, `ink ${light.count}`);
check("the heavy run draws its glyphs", bold.count > 100, `ink ${bold.count}`);
// The heavy outlines carry more ink per glyph; a host that paints the default instance gives the
// two runs the same amount of ink however the advances were laid out.
check("the heavy run carries more ink than the light one",
  bold.count > light.count * 1.2, `light ${light.count}, heavy ${bold.count}`);
// A heavy instance is also wider than a light one at the same size.
check("the heavy run is wider than the light one",
  bold.right - bold.left > light.right - light.left,
  `light ${light.right - light.left}, heavy ${bold.right - bold.left}`);

if (failed > 0) {
  console.error(`\n${failed} check${failed === 1 ? "" : "s"} failed`);
  process.exit(1);
}
console.log("\nall variable font checks passed");
