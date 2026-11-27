// A Windows build embeds the page's icon in its executable: the PNG becomes an .ico at
// 16/24/32/48/64/256, which is compiled into a resource object and linked with the app. Explorer,
// Alt-Tab, the taskbar and the window (WM_SETICON, host/windows.cpp) all read it from there.
//
// The check builds a small app and reads the PE's resource directory back: the icon group with the
// six sizes, and six RT_ICON images, each the PNG the .ico holds.
//   npm test

import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { encodePng } from "./png.ts";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const windows = process.platform === "win32" || /windows/.test(process.env.SCRIPTC_TARGET ?? "");
if (!windows) {
  console.log("ok   a Windows build embeds the app icon (skipped on this platform)");
  console.log("\nall passed");
  process.exit(0);
}
if (spawnSync("zig", ["version"], { encoding: "utf8" }).status !== 0) {
  console.log("ok   a Windows build embeds the app icon (needs zig on the PATH; skipped)");
  console.log("\nall passed");
  process.exit(0);
}
// A cross-build needs the Windows compiler packs, which npm installs only with --force.
if (process.platform !== "win32") {
  const require = createRequire(import.meta.url);
  try {
    require.resolve("@scriptc/runtime-win32-x64-msvc/package.json");
    require.resolve("@scriptc/llvm-win32-x64-msvc/package.json");
  } catch {
    console.log("ok   a Windows build embeds the app icon (needs the Windows compiler packs; skipped)");
    console.log("\nall passed");
    process.exit(0);
  }
}

// A 256px PNG with a bright ring, so the resampled sizes differ from a flat colour.
const png = encodePng(256, 256, (x, y) => {
  const dx = x - 128, dy = y - 128, d = Math.sqrt(dx * dx + dy * dy);
  const v = d > 96 && d < 116 ? 255 : 16;
  return [v, v, v, 255];
});
const dir = mkdtempSync(join(tmpdir(), "native-windows-icon-"));
writeFileSync(join(dir, "icon.png"), png);
writeFileSync(join(dir, "index.html"), `<!doctype html>
<html><head><meta charset="utf-8"><meta name="native-window" content="width=320, height=240">
<link rel="icon" href="icon.png">
<title>Icon</title></head><body><script src="app.ts"></script></body></html>`);
writeFileSync(join(dir, "app.ts"), `document.body.dataset.ready = "yes";\n`);
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", join(dir, "app")], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
const exe = join(dir, "app.exe");
check("the build writes a Windows executable", existsSync(exe));
const file = readFileSync(exe);
check("the executable is a PE image", file.readUInt16LE(0) === 0x5a4d &&
  file.toString("ascii", file.readUInt32LE(0x3c), file.readUInt32LE(0x3c) + 4) === "PE\u0000\u0000");

// The PE's resource directory: the optional header names it by RVA, and the section table maps
// that to a file offset.
const pe = file.readUInt32LE(0x3c);
const coff = pe + 4;
const sectionCount = file.readUInt16LE(coff + 2);
const optSize = file.readUInt16LE(coff + 16);
const opt = coff + 20;
const magic = file.readUInt16LE(opt);
const dirAt = opt + (magic === 0x20b ? 112 : 96);
const resourceRva = file.readUInt32LE(dirAt + 16);
const sections: { va: number; size: number; raw: number }[] = [];
for (let i = 0; i < sectionCount; i++) {
  const at = opt + optSize + i * 40;
  sections.push({ va: file.readUInt32LE(at + 12), size: file.readUInt32LE(at + 8), raw: file.readUInt32LE(at + 20) });
}
const offsetOf = (rva: number): number => {
  for (const s of sections) if (rva >= s.va && rva < s.va + s.size) return rva - s.va + s.raw;
  return -1;
};
check("the executable has a resource directory", resourceRva !== 0);
const dirOffset = offsetOf(resourceRva);

/** A resource directory's entries, with the directory or data entry each names. */
function entries(at: number): { id: number; sub: number; leaf: number }[] {
  const named = file.readUInt16LE(at + 12), ids = file.readUInt16LE(at + 14);
  const out: { id: number; sub: number; leaf: number }[] = [];
  for (let i = 0; i < named + ids; i++) {
    const e = at + 16 + i * 8;
    const name = file.readUInt32LE(e), to = file.readUInt32LE(e + 4);
    if ((name & 0x80000000) !== 0) continue;
    out.push({
      id: name & 0xffff,
      sub: (to & 0x80000000) !== 0 ? dirOffset + (to & 0x7fffffff) : -1,
      leaf: (to & 0x80000000) === 0 ? dirOffset + to : -1,
    });
  }
  return out;
}

/** The bytes a data entry names. `leaf` is already an offset into the file. */
function data(leaf: number): Buffer {
  const rva = file.readUInt32LE(leaf);
  const size = file.readUInt32LE(leaf + 4);
  const at = offsetOf(rva);
  return file.subarray(at, at + size);
}

/** The bytes of a resource: its type, its name (the icon's id), and its first language. */
function resource(type: number, name: number): Buffer | null {
  const typeEntry = entries(dirOffset).find((e) => e.id === type);
  if (typeEntry === undefined || typeEntry.sub < 0) return null;
  const nameEntry = entries(typeEntry.sub).find((e) => e.id === name);
  if (nameEntry === undefined || nameEntry.sub < 0) return null;
  const language = entries(nameEntry.sub)[0];
  if (language === undefined || language.leaf < 0) return null;
  return data(language.leaf);
}

const group = resource(14, 1);
check("the resources hold the icon group", group !== null);
if (group !== null) {
  const count = group.readUInt16LE(4);
  const sizes: number[] = [];
  for (let i = 0; i < count; i++) {
    const width = group[6 + i * 14];
    sizes.push(width === 0 ? 256 : width);
  }
  check("the group holds 16, 24, 32, 48, 64 and 256", JSON.stringify(sizes) === JSON.stringify([16, 24, 32, 48, 64, 256]),
    sizes.join(", "));
}
const iconType = entries(dirOffset).find((e) => e.id === 3);
const names = iconType === undefined || iconType.sub < 0 ? [] : entries(iconType.sub);
check("the resources hold the six icon images", names.length === 6, `${names.length}`);
let pngs = 0;
for (const name of names) {
  const bytes = name.sub < 0 ? null : resource(3, name.id);
  if (bytes !== null && bytes[0] === 0x89 && bytes.toString("ascii", 1, 4) === "PNG") pngs++;
}
check("each icon image is a PNG", pngs === names.length && pngs > 0, `${pngs} of ${names.length}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
