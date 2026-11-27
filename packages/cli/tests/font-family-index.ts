// A page's own @font-face families are indexed from FF_CUSTOM (7). The Linux host subtracted 6
// from the packed family id instead, so the first family's text drew the second family's faces
// and the last family's text fell back to the system font.
//
// The check registers two custom families from two different system files and compares each
// family's advance with the advance its own file's tables give. An off-by-one moves the first
// family onto the second family's face and the second onto the system fallback, so both
// comparisons fail.
//   npm test

import { spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

// The host that indexes a page's families itself is the Linux one; the other platforms hand the
// file to the system's font stack and number the families the same way.
if (process.platform !== "linux") {
  console.log("ok   a page's @font-face families are indexed from 7 (skipped on this platform)");
  console.log("\nall passed");
  process.exit(0);
}

const SANS = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf";
const MONO = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf";
if (!existsSync(SANS) || !existsSync(MONO)) {
  console.log("ok   a page's @font-face families need two system font files (skipped)");
  console.log("\nall passed");
  process.exit(0);
}

const TEXT = "Hamburgefonstiv";
const SIZE = 30;

/** A font file's advance for `text` at `size`, read from its head, hhea, hmtx and cmap tables. */
function advance(file: string, text: string, size: number): number {
  const font = readFileSync(file);
  const table = (tag: string): number => {
    const count = font.readUInt16BE(4);
    for (let i = 0; i < count; i++) {
      const rec = 12 + i * 16;
      if (font.toString("ascii", rec, rec + 4) === tag) return font.readUInt32BE(rec + 8);
    }
    return -1;
  };
  const head = table("head"), hhea = table("hhea"), hmtx = table("hmtx"), cmap = table("cmap");
  if (head < 0 || hhea < 0 || hmtx < 0 || cmap < 0) throw new Error(`${file} has no outline tables`);
  const upem = font.readUInt16BE(head + 18);
  const metrics = font.readUInt16BE(hhea + 34);
  const advanceOf = (glyph: number): number =>
    font.readUInt16BE(hmtx + 4 * Math.min(glyph, metrics - 1));
  // The first format 4 subtable: enough for the Basic Latin text here, and what these files use.
  let sub = -1;
  const subtables = font.readUInt16BE(cmap + 2);
  for (let i = 0; i < subtables; i++) {
    const rec = cmap + 4 + i * 8;
    const at = cmap + font.readUInt32BE(rec + 4);
    if (at + 4 <= font.length && font.readUInt16BE(at) === 4) { sub = at; break; }
  }
  if (sub < 0) throw new Error(`${file} has no format 4 cmap`);
  const segments = font.readUInt16BE(sub + 6) / 2;
  const ends = sub + 14, starts = ends + segments * 2 + 2;
  const deltas = starts + segments * 2, offsets = deltas + segments * 2;
  const glyphOf = (code: number): number => {
    for (let i = 0; i < segments; i++) {
      if (font.readUInt16BE(ends + i * 2) < code) continue;
      if (font.readUInt16BE(starts + i * 2) > code) return 0;
      const range = font.readUInt16BE(offsets + i * 2);
      if (range === 0) return (code + font.readUInt16BE(deltas + i * 2)) & 0xffff;
      const at = offsets + i * 2 + range + (code - font.readUInt16BE(starts + i * 2)) * 2;
      if (at + 2 > font.length) return 0;
      const glyph = font.readUInt16BE(at);
      return glyph === 0 ? 0 : (glyph + font.readUInt16BE(deltas + i * 2)) & 0xffff;
    }
    return 0;
  };
  let total = 0;
  for (const ch of text) total += advanceOf(glyphOf(ch.charCodeAt(0)));
  return (total / upem) * size;
}

const expectedSans = advance(SANS, TEXT, SIZE);
const expectedMono = advance(MONO, TEXT, SIZE);

const PAGE = `<!doctype html>
<html><head><meta charset="utf-8"><meta name="native-window" content="width=600, height=240"><style>
body { margin: 0; font-size: ${SIZE}px; font-kerning: none; }
div { height: 40px; }
@font-face { font-family: FamilyA; src: url("a.ttf"); }
@font-face { font-family: FamilyB; src: url("b.ttf"); }
</style></head><body>
<div><span id="familyA" style="font-family: FamilyA">${TEXT}</span></div>
<div><span id="familyB" style="font-family: FamilyB">${TEXT}</span></div>
<script src="app.ts"></script>
</body></html>`;

// The rects are laid out by the first frame, so the reads happen in a later one.
const SCRIPT = `
requestAnimationFrame(() => requestAnimationFrame(() => {
  for (const id of ["familyA", "familyB"]) {
    console.log(id + "=" + Math.round(document.getElementById(id)!.getBoundingClientRect().width * 100) / 100);
  }
}));
`;

const dir = mkdtempSync(join(tmpdir(), "native-font-family-index-"));
copyFileSync(SANS, join(dir, "a.ttf"));
copyFileSync(MONO, join(dir, "b.ttf"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame | frame" } });
if (r.status !== 0) throw new Error(`run failed\n${r.stderr}`);
const widths: Record<string, number> = {};
for (const line of r.stdout.split("\n")) {
  const m = /^(\w+)=([\d.]+)$/.exec(line.trim());
  if (m) widths[m[1]] = Number(m[2]);
}

check("the first custom family draws its own face", Math.abs(widths.familyA - expectedSans) < 0.05,
  `FamilyA ${widths.familyA}, its file ${expectedSans.toFixed(2)}`);
check("the second custom family draws its own face", Math.abs(widths.familyB - expectedMono) < 0.05,
  `FamilyB ${widths.familyB}, its file ${expectedMono.toFixed(2)}`);
check("the two families draw different faces", Math.abs(widths.familyA - widths.familyB) > 1,
  `FamilyA ${widths.familyA}, FamilyB ${widths.familyB}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
