// ::placeholder styles the text a text field shows when it is empty. The field draws that text
// itself, in the placeholder's colour, at its opacity, in its font; a field without a
// ::placeholder colour draws it in its own colour at half opacity, as before.   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

// Three 50 CSS px tall fields, 200 by 150 CSS px at 2 device px per CSS px: field i covers
// device rows [100i, 100i + 100). The window is white and each field holds one placeholder
// character, large enough that a stroke covers whole pixels.
const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=200, height=150"><style>
body { margin: 0; background: #ffffff; }
input { display: block; width: 200px; height: 50px; border: 0; padding: 0; margin: 0;
  font-family: sans-serif; font-size: 40px; color: #000000; background: #ffffff; }
#a::placeholder { color: #ff0000; }
#b::placeholder { color: #0000ff; opacity: 0.4; }
</style></head><body>
<input id="a" placeholder="H"><input id="b" placeholder="H"><input id="c" placeholder="H">
</body></html>`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-placeholder-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
check("the build doesn't report ::placeholder as unsupported", !/is not supported yet/.test(b.stderr),
  b.stderr.trim());
const png = join(dir, "out.png");
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const img = decodePng(png);

interface Rgb { r: number; g: number; b: number; score: number }
/** The pixel in field `field`'s band with the highest `score`, and its colour. */
function extreme(field: number, score: (r: number, g: number, b: number) => number): Rgb {
  let best: Rgb = { r: 255, g: 255, b: 255, score: -Infinity };
  for (let y = 100 * field; y < 100 * field + 100; y++) {
    for (let x = 0; x < img.w; x++) {
      const o = (y * img.w + x) * 4;
      const s = score(img.rgba[o], img.rgba[o + 1], img.rgba[o + 2]);
      if (s > best.score) best = { r: img.rgba[o], g: img.rgba[o + 1], b: img.rgba[o + 2], score: s };
    }
  }
  return best;
}

const red = extreme(0, (r, g, b) => r - Math.max(g, b));
check("a ::placeholder colour draws the placeholder text", red.r > 200 && red.g < 80 && red.b < 80,
  `reddest pixel is ${red.r},${red.g},${red.b}`);

const blue = extreme(1, (r, g, b) => b - Math.max(r, g));
// #0000ff at 40% over white is (153, 153, 255): blue, but visibly lighter than the declaration.
check("::placeholder opacity lightens the text", blue.b > 200 && blue.r > 90 && blue.g > 90,
  `bluest pixel is ${blue.r},${blue.g},${blue.b}`);

const dark = extreme(2, (r, g, b) => 255 - (r + g + b) / 3);
check("without a ::placeholder colour the text is the field's colour at half opacity",
  Math.abs(dark.r - dark.g) <= 8 && Math.abs(dark.g - dark.b) <= 8 && dark.r > 60 && dark.r < 200,
  `darkest pixel is ${dark.r},${dark.g},${dark.b}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
