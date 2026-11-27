// A page's @font-face file may be WOFF or WOFF2, where the font's tables sit in a compressed
// container. The Linux host reads a face's tables itself to measure it; on a compressed file that
// walk found none, so the face stayed unloaded and the run painted no text at all. A face that
// can't be read also stopped the family list where a browser moves on to the next family, so a
// broken file left the run unpainted instead of drawing the fallback font.
//
// The check draws the same text three ways — from a WOFF2 face, from a face whose file isn't a
// font, and from the system sans — and counts the ink each band holds, so a band that paints
// nothing fails while the fallback band still passes.
//   npm test

import { spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdtempSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { decodePng } from "./png.ts";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

// The host that reads a page's own files is the Linux one; the other platforms hand them to the
// system's font stack, which reads WOFF2 by itself.
if (process.platform !== "linux") {
  console.log("ok   WOFF2 @font-face files draw their text (skipped on this platform)");
  console.log("\nall passed");
  process.exit(0);
}

const FIXTURE = join(dirname(fileURLToPath(import.meta.url)), "fixtures", "inter-latin.woff2");
if (!existsSync(FIXTURE)) {
  console.log("ok   WOFF2 @font-face files need the inter-latin.woff2 fixture (skipped)");
  console.log("\nall passed");
  process.exit(0);
}

const SIZE = 48;
const BAND = 64;
const TEXT = "HHHH";

const PAGE = `<!doctype html>
<html><head><meta charset="utf-8">
<meta name="native-window" content="width=320, height=${BAND * 3}">
<style>
body { margin: 0; background: #ffffff; color: #000000; }
div { height: ${BAND}px; font-size: ${SIZE}px; line-height: ${BAND}px; }
@font-face { font-family: Compressed; src: url("face.woff2"); }
@font-face { font-family: Broken; src: url("broken.ttf"); }
</style></head><body>
<div id="compressed" style="font-family: Compressed">${TEXT}</div>
<div id="broken" style="font-family: Broken">${TEXT}</div>
<div id="system" style="font-family: sans-serif">${TEXT}</div>
</body></html>`;

const dir = mkdtempSync(join(tmpdir(), "native-woff-face-"));
copyFileSync(FIXTURE, join(dir, "face.woff2"));
// A file that isn't a font: the host can't read a face from it, as with a file that went missing.
writeFileSync(join(dir, "broken.ttf"), "this file is not a font\n");
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const png = join(dir, "snap.png");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const r = spawnSync(exe, [], {
  encoding: "utf8",
  env: { ...process.env, NATIVE_STEPS: "frame 0 | frame 16", NATIVE_SNAPSHOT: png },
});
if (r.status !== 0) throw new Error(`run failed\n${r.stderr}`);
const img = decodePng(png);

/** The number of dark pixels in a band of the snapshot, at 2x the page's own size. */
function ink(band: number): number {
  let n = 0;
  for (let y = band * BAND * 2; y < (band + 1) * BAND * 2 && y < img.h; y++) {
    for (let x = 0; x < img.w; x++) {
      const i = (y * img.w + x) * 4;
      if (img.rgba[i] + img.rgba[i + 1] + img.rgba[i + 2] < 3 * 128) n++;
    }
  }
  return n;
}

const compressed = ink(0);
const broken = ink(1);
const system = ink(2);
check("a WOFF2 face draws its text", compressed > 200, `${compressed} dark pixels`);
check("a face the host can't read falls back to the standard font", broken > 200, `${broken} dark pixels`);
check("the system sans draws the same text", system > 200, `${system} dark pixels`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
