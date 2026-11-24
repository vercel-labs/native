// A ::first-line that changes the font re-breaks the first line in it: the line holds fewer
// characters and stands taller, and the rest of the paragraph keeps the element's font.
//   npm test

import { spawnSync } from "node:child_process";
import { decodePng } from "./png.ts";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = (firstLine: string): string => `<!doctype html>
<html><head><meta name="native-window" content="width=240, height=240"><style>
body { margin: 0; font: 16px monospace; }
p { width: 240px; margin: 0; }
${firstLine}
</style></head><body>
<p id="p">alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu</p>
</body></html>`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

interface Shot { img: ReturnType<typeof decodePng> }
function run(firstLine: string): Shot {
  const dir = mkdtempSync(join(tmpdir(), "native-first-line-"));
  writeFileSync(join(dir, "index.html"), PAGE(firstLine));
  const exe = join(dir, "app");
  const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
  if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
  const png = join(dir, "out.png");
  const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png } });
  if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
  return { img: decodePng(png) };
}

/** The rows of the snapshot that hold any dark ink, top to bottom. */
function inkRows(img: ReturnType<typeof decodePng>): { top: number; bottom: number }[] {
  const rows: boolean[] = [];
  for (let y = 0; y < img.h; y++) {
    let ink = false;
    for (let x = 0; x < img.w; x++) {
      const o = (y * img.w + x) * 4;
      if (img.rgba[o] < 100 && img.rgba[o + 1] < 100 && img.rgba[o + 2] < 100) { ink = true; break; }
    }
    rows.push(ink);
  }
  const bands: { top: number; bottom: number }[] = [];
  let start = -1;
  for (let y = 0; y < rows.length; y++) {
    if (rows[y] && start < 0) start = y;
    if (!rows[y] && start >= 0) { bands.push({ top: start, bottom: y - 1 }); start = -1; }
  }
  if (start >= 0) bands.push({ top: start, bottom: rows.length - 1 });
  return bands;
}

const plain = inkRows(run("").img);
const styled = inkRows(run("p::first-line { font-size: 32px; }").img);
// Snapshot rows are device pixels: 2 per CSS pixel.
const firstTall = styled.length > 0 ? styled[0].bottom - styled[0].top + 1 : 0;
check("the first line stands in its own font's height", firstTall > 40, `${firstTall} device rows in the first band`);
check("the rest of the paragraph keeps the element's font",
  styled.length > 1 && styled[1].bottom - styled[1].top + 1 < 35, `${styled[1]?.bottom - styled[1]?.top + 1} device rows in the second band`);
check("the re-broken first line pushes the text to more lines", styled.length > plain.length,
  `${styled.length} bands with the rule, ${plain.length} without`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
