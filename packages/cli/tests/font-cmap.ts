// A @font-face file's tables are read by FreeType and HarfBuzz, as Chrome reads them. A cmap whose
// subtable length or group count is wrong must still render: the libraries bound every read to
// the file, so the page draws instead of taking the app down.
//   npm test

import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

// The host that reads a font's tables itself is the Linux one; other platforms hand the file to
// the system's font stack.
if (process.platform !== "linux") {
  console.log("ok   font table bounds are read by the Linux host (skipped on this platform)");
  console.log("\nall passed");
  process.exit(0);
}

const match = spawnSync("fc-match", ["-f", "%{file}", "sans-serif"], { encoding: "utf8" });
const source = match.status === 0 ? match.stdout.trim() : "";
if (source === "" || !existsSync(source)) {
  console.log("ok   font table bounds need a system font (fc-match found none; skipped)");
  console.log("\nall passed");
  process.exit(0);
}
const font = readFileSync(source);

/** A table's file offset and length, from the font's table directory. */
function table(tag: string): { off: number; len: number } | null {
  const count = font.readUInt16BE(4);
  for (let i = 0; i < count; i++) {
    const rec = 12 + i * 16;
    if (font.toString("ascii", rec, rec + 4) === tag) {
      return { off: font.readUInt32BE(rec + 8), len: font.readUInt32BE(rec + 12) };
    }
  }
  return null;
}

/** The file offset of the first format 12 subtable of the cmap table. */
function format12(cmap: { off: number; len: number }): number {
  const count = font.readUInt16BE(cmap.off + 2);
  for (let i = 0; i < count; i++) {
    const rec = cmap.off + 4 + i * 8;
    const off = cmap.off + font.readUInt32BE(rec + 4);
    if (off + 2 <= cmap.off + cmap.len && font.readUInt16BE(off) === 12) return off;
  }
  return -1;
}

const cmap = table("cmap");
const sub = cmap === null ? -1 : format12(cmap);
if (sub < 0) {
  console.log("ok   font table bounds need a font with a format 12 cmap (this one has none; skipped)");
  console.log("\nall passed");
  process.exit(0);
}

// Three copies of the same font: one as it is, one whose subtable length stops before its
// groups, and one whose group count runs past them.
const plain = Buffer.from(font);
const short = Buffer.from(font);
short.writeUInt32BE(16, sub + 4);
const groups = Buffer.from(font);
groups.writeUInt32BE(0xffffffff, sub + 12);

// A character the cmap doesn't map measures as glyph 0, the font's missing glyph.
const head = table("head");
const hmtx = table("hmtx");
const upem = head === null ? 0 : font.readUInt16BE(head.off + 18);
const missing = head === null || hmtx === null || upem === 0
  ? 0
  : (font.readUInt16BE(hmtx.off) / upem) * 20 * "Hamburgefonstiv".length;

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=200"><style>
body { margin: 0; font-size: 20px; }
span { white-space: pre; }
@font-face { font-family: Plain; src: url("plain.ttf"); }
@font-face { font-family: Short; src: url("short.ttf"); }
@font-face { font-family: Groups; src: url("groups.ttf"); }
</style></head><body>
<span id="plain" style="font-family: Plain">Hamburgefonstiv</span>
<span id="short" style="font-family: Short">Hamburgefonstiv</span>
<span id="groups" style="font-family: Groups">Hamburgefonstiv</span>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const byId = (id: string): HTMLElement => document.getElementById(id)!;
const width = (id: string): number => Math.round(byId(id).getBoundingClientRect().width * 100) / 100;
requestAnimationFrame(() => {
  requestAnimationFrame(() => {
    for (const id of ["plain", "short", "groups"]) console.log(id + "=" + width(id));
  });
});
`;

const dir = mkdtempSync(join(tmpdir(), "native-font-cmap-"));
writeFileSync(join(dir, "plain.ttf"), plain);
writeFileSync(join(dir, "short.ttf"), short);
writeFileSync(join(dir, "groups.ttf"), groups);
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const r = spawnSync(exe, [], {
  encoding: "utf8",
  env: { ...process.env, NATIVE_SNAPSHOT: join(dir, "out.png"), NATIVE_STEPS: "frame | frame" },
});
if (r.status !== 0) throw new Error(`render failed (exit ${r.status ?? r.signal})\n${r.stderr}`);

const widths: Record<string, number> = {};
for (const line of r.stdout.split("\n")) {
  const m = /^(\w+)=([\d.]+)$/.exec(line.trim());
  if (m) widths[m[1]] = Number(m[2]);
}

check("the font as it is maps the text", widths.plain > 0, `plain ${widths.plain}`);
check("a group count past the table still renders the font", widths.groups > 0,
  `groups ${widths.groups}`);
check("a subtable length before its groups still renders the font", widths.short > 0,
  `short ${widths.short}`);
// FreeType fails closed on a group count it cannot trust: the characters draw as the missing
// glyph rather than as whichever glyphs the bad offsets would name.
check("a group count past the table names no glyphs", Math.abs(widths.groups - missing) < 0.05,
  `groups ${widths.groups}, missing glyph ${missing.toFixed(2)}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
