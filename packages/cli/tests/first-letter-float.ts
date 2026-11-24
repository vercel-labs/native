// A floated ::first-letter makes a drop cap: the letter paints at its own size, and the rest of
// the paragraph wraps beside it and under it. The letter is still the element's text.
//   npm test

import { spawnSync } from "node:child_process";
import { decodePng } from "./png.ts";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=240, height=160"><style>
body { margin: 0; font: 16px monospace; }
p { width: 220px; margin: 0; }
p::first-letter { float: left; font-size: 48px; line-height: 48px; color: rgb(255, 0, 0); }
</style></head><body>
<p id="p">Wide words wrap beside the drop cap and run on under it to the end of the line.</p>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `console.log("text=[" + (document.getElementById("p") as HTMLElement).textContent + "]");`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-first-letter-float-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
const png = join(dir, "out.png");
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);

const img = decodePng(png);
const px = (x: number, y: number): number[] => {
  const o = (y * img.w + x) * 4;
  return [img.rgba[o], img.rgba[o + 1], img.rgba[o + 2]];
};
const isRed = (p: number[]): boolean => p[0] > 180 && p[1] < 80 && p[2] < 80;
const isDark = (p: number[]): boolean => p[0] < 100 && p[1] < 100 && p[2] < 100;

// The drop cap is the only red on the page, so its box is the letter's ink.
let red = 0, redMaxX = -1, redMaxY = -1, redMinX = 1e9, redMinY = 1e9;
for (let y = 0; y < img.h; y++) {
  for (let x = 0; x < img.w; x++) {
    if (!isRed(px(x, y))) continue;
    red++;
    redMinX = Math.min(redMinX, x); redMaxX = Math.max(redMaxX, x);
    redMinY = Math.min(redMinY, y); redMaxY = Math.max(redMaxY, y);
  }
}
check("the first letter paints in its own colour and size", red > 400 && redMinX < 40 && redMaxY > 60,
  `${red} red pixels, x ${redMinX}..${redMaxX}, y ${redMinY}..${redMaxY}`);

// The grey text of the first line starts to the right of the letter, and the text below the
// letter runs from the paragraph's left edge again.
let beside = 0, below = 0;
for (let y = 0; y < img.h; y++) {
  for (let x = 0; x < img.w; x++) {
    if (!isDark(px(x, y))) continue;
    if (y < redMaxY && x > redMaxX + 4) beside++;
    if (y > redMaxY + 8 && x < 20) below++;
  }
}
check("the paragraph wraps beside the drop cap", beside > 60, `${beside} pixels beside it`);
check("and runs on under it", below > 20, `${below} pixels under it`);

check("the letter is still the element's text", r.stdout.includes("text=[Wide words wrap beside the drop cap"));

// A drag that starts on the first line's text and runs to the end selects the paragraph from its
// start, so the copy includes the drop cap's letter.
const copy = join(dir, "copy.txt");
const drag = spawnSync(exe, [], {
  encoding: "utf8",
  env: {
    ...process.env, NATIVE_SNAPSHOT: join(dir, "drag.png"),
    NATIVE_STEPS: "dragat 32 6 220 100 | key Meta+Copy", NATIVE_PASTEBOARD: copy,
  },
});
if (drag.status !== 0) throw new Error(`drag failed\n${drag.stderr}`);
const copied = readFileSync(copy, "utf8");
check("a drag from the first line copies the paragraph with its letter",
  copied.startsWith("Wide words wrap beside the drop cap"), JSON.stringify(copied.slice(0, 40)));

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
