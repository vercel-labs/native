// The shared Geist kit under examples/_fonts: Geist Sans and Geist Mono at 400, 500 and 600, as
// three static faces each, linked from a page through the kit's fonts.css. The check sees the
// weights on screen: the same text in a heavier face lays down more ink, and the sans faces also
// measure wider.
//
// It also covers the host's custom-family lookup. A family's faces are indexed from FF_CUSTOM
// (7); an off-by-one there sends the first family's text to the second family's faces and the
// last family's text to the system font, which leaves Geist Mono 500 drawing with Geist Mono
// 400's outlines. The ink checks catch exactly that.
//   npm test
//   node tests/font-kit.ts

import { spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdtempSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { decodePng } from "./png.ts";

const DIR = dirname(fileURLToPath(import.meta.url));
const KIT = join(DIR, "..", "..", "..", "examples", "_fonts");

const FONTS = [
  "Geist-Regular.ttf",
  "Geist-Medium.ttf",
  "Geist-SemiBold.ttf",
  "GeistMono-Regular.ttf",
  "GeistMono-Medium.ttf",
  "GeistMono-SemiBold.ttf",
];

const ROWS = ["sans400", "sans500", "sans600", "mono400", "mono500", "mono600"];
const PAGE = `<!doctype html>
<html><head><meta charset="utf-8"><meta name="native-window" content="width=520, height=440">
<link rel="stylesheet" href="fonts.css">
<style>
body { margin: 0; background: #fff; color: #000; }
div { height: 60px; font-size: 44px; line-height: 60px; }
span { white-space: pre; }
</style></head><body>
<div><span id="sans400" style="font-family: 'Geist Sans'; font-weight: 400">Hamburgefonstiv</span></div>
<div><span id="sans500" style="font-family: 'Geist Sans'; font-weight: 500">Hamburgefonstiv</span></div>
<div><span id="sans600" style="font-family: 'Geist Sans'; font-weight: 600">Hamburgefonstiv</span></div>
<div><span id="mono400" style="font-family: 'Geist Mono'; font-weight: 400">0123456789</span></div>
<div><span id="mono500" style="font-family: 'Geist Mono'; font-weight: 500">0123456789</span></div>
<div><span id="mono600" style="font-family: 'Geist Mono'; font-weight: 600">0123456789</span></div>
<script src="app.ts"></script>
</body></html>`;

// The rects are laid out by the first frame, so the reads happen in a later one.
const SCRIPT = `requestAnimationFrame(() => requestAnimationFrame(() => {
  for (const id of ${JSON.stringify(ROWS)}) {
    console.log(id + "=" + Math.round(document.getElementById(id)!.getBoundingClientRect().width * 100) / 100);
  }
}));`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

for (const name of FONTS) {
  if (!existsSync(join(KIT, name))) throw new Error(`the shared font kit is missing examples/_fonts/${name}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-font-kit-"));
copyFileSync(join(KIT, "fonts.css"), join(dir, "fonts.css"));
for (const name of FONTS) copyFileSync(join(KIT, name), join(dir, name));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const png = join(dir, "out.png");
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png, NATIVE_STEPS: "frame | frame" } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const img = decodePng(png);

const widths: Record<string, number> = {};
for (const line of r.stdout.split("\n")) {
  const m = /^(\w+)=([\d.]+)$/.exec(line.trim());
  if (m) widths[m[1]] = Number(m[2]);
}

/** Ink in one 60px row of the page, in device pixels. */
function ink(row: number): number {
  let n = 0;
  for (let y = row * 120; y < (row + 1) * 120; y++) {
    for (let x = 0; x < img.w; x++) {
      const o = (y * img.w + x) * 4;
      if (img.rgba[o] < 160 && img.rgba[o + 1] < 160 && img.rgba[o + 2] < 160) n++;
    }
  }
  return n;
}

const [s400, s500, s600, m400, m500, m600] = ROWS.map((_, i) => ink(i));
check("Geist Sans 400 draws", s400 > 500, `${s400} dark pixels`);
check("Geist Sans 500 is heavier than 400", s500 > s400 * 1.05, `${s400} → ${s500} dark pixels`);
check("Geist Sans 600 is heavier than 500", s600 > s500 * 1.05, `${s500} → ${s600} dark pixels`);
check("Geist Mono 400 draws", m400 > 500, `${m400} dark pixels`);
check("Geist Mono 500 is heavier than 400", m500 > m400 * 1.05, `${m400} → ${m500} dark pixels`);
check("Geist Mono 600 is heavier than 500", m600 > m500 * 1.05, `${m500} → ${m600} dark pixels`);
check("Geist Sans advances grow with the weight",
  widths.sans500 > widths.sans400 && widths.sans600 > widths.sans500,
  `${widths.sans400} → ${widths.sans500} → ${widths.sans600}`);
check("Geist Mono keeps its tabular advance at every weight",
  Math.abs(widths.mono500 - widths.mono400) < 0.01 && Math.abs(widths.mono600 - widths.mono400) < 0.01,
  `${widths.mono400}, ${widths.mono500}, ${widths.mono600}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
