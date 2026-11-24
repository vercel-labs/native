// ::first-letter takes the punctuation that belongs to it: everything before the letter, and the
// punctuation after it except an opening one or a dash.
//   npm test

import { spawnSync } from "node:child_process";
import { decodePng } from "./png.ts";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=240, height=280"><style>
body { margin: 0; }
div { font: 24px monospace; position: absolute; left: 0; }
#a { top: 0; }
#b { top: 40px; }
#c { top: 80px; }
#d { top: 120px; }
#e { top: 160px; }
#f { top: 200px; }
#g { top: 240px; }
div::first-letter { color: rgb(255, 0, 0); }
#g::first-letter { opacity: 0; }
</style></head><body>
<div id="a">(T)est</div>
<div id="b">T(rail</div>
<div id="c">T–rail</div>
<div id="d">« T »est</div>
<div id="e">T .est</div>
<div id="f">T. est</div>
<div id="g">First</div>
</body></html>`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-first-letter-punct-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const built = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (built.status !== 0) throw new Error(`build failed\n${built.stderr}`);
const png = join(dir, "out.png");
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);

const img = decodePng(png);
/** The columns of one text band holding red ink, in CSS pixels; -1 when none. */
function redExtent(top: number, bottom: number): [number, number] {
  let lo = -1, hi = -1;
  for (let y = top * 2; y < bottom * 2 && y < img.h; y++) {
    for (let x = 0; x < img.w; x++) {
      const o = (y * img.w + x) * 4;
      if (!(img.rgba[o] > 180 && img.rgba[o + 1] < 80 && img.rgba[o + 2] < 80)) continue;
      const cx = x / 2;
      if (lo < 0 || cx < lo) lo = cx;
      if (cx > hi) hi = cx;
    }
  }
  return [lo, hi];
}

// At 24px monospace a glyph advances 14.4 CSS px: "(" is the first cell, "T" the second, ")" the
// third. A letter group that takes the brackets paints red through the third cell; one that
// stops at the letter paints only the second.
const a = redExtent(0, 40);
check("a bracketed letter takes both brackets", a[0] >= 0 && a[0] < 15 && a[1] > 30,
  `red x ${a[0]}..${a[1]}`);
const open = redExtent(40, 80);
check("an opening bracket after the letter is not part of it", open[0] >= 0 && open[1] < 15,
  `red x ${open[0]}..${open[1]}`);
const dash = redExtent(80, 120);
check("a dash after the letter is not part of it", dash[0] >= 0 && dash[1] < 15,
  `red x ${dash[0]}..${dash[1]}`);

// A quote before the letter is part of it across a no-break space, while the no-break space
// after the letter stops the group; a typographic space bridges to a following dot.
const quoted = redExtent(120, 160);
check("a quote and a no-break space before the letter are part of it", quoted[1] > 30 && quoted[1] < 45,
  `red x ${quoted[0]}..${quoted[1]}`);
const bridged = redExtent(160, 200);
check("a typographic space bridges to the dot after it", bridged[1] > 30 && bridged[1] < 50,
  `red x ${bridged[0]}..${bridged[1]}`);
const stopped = redExtent(200, 240);
check("a dot before a typographic space stays the end", stopped[1] < 30,
  `red x ${stopped[0]}..${stopped[1]}`);

// An invisible letter keeps its advance and paints nothing.
const hidden = redExtent(240, 280);
let darkInRow = 0;
for (let y = 240 * 2; y < 280 * 2 && y < img.h; y++) {
  for (let x = 0; x < img.w; x++) {
    const o = (y * img.w + x) * 4;
    if (img.rgba[o] < 100 && img.rgba[o + 1] < 100 && img.rgba[o + 2] < 100) darkInRow++;
  }
}
check("a letter with opacity 0 paints nothing, and the rest still paints",
  hidden[0] < 0 && darkInRow > 40, `red ${hidden[0]}..${hidden[1]}, ${darkInRow} dark pixels`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
