// The Windows executable's icon, from the PNG the page names, the same web-first source macOS
// turns into an .icns. Windows reads an .ico that holds the picture at the sizes the shell asks
// for, and the icon is a resource of the executable itself.
//
// The resource is compiled by `zig rc`, which a Windows build already has: scriptc links Windows
// apps with zig, and zig carries the resource compiler next to the linker.

import { spawnSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { readPng, resizePng, writePng, type Raster } from "./png.ts";

/** The sizes a Windows app's .ico carries: the shell's small and large icons, and the large tile. */
export const ICO_SIZES: readonly number[] = [16, 24, 32, 48, 64, 256];

/** The resource id host/windows.cpp loads the app icon by, for WM_SETICON. */
export const APP_ICON_ID = 1;

/** An .ico holding the picture at each size, each entry PNG-encoded (Windows Vista and later). */
export function icoOf(img: Raster, sizes: readonly number[] = ICO_SIZES): Buffer {
  const images = sizes.map((size) => writePng(resizePng(img, size)));
  const header = Buffer.alloc(6);
  header.writeUInt16LE(0, 0);
  header.writeUInt16LE(1, 2);
  header.writeUInt16LE(images.length, 4);
  const entries: Buffer[] = [];
  let offset = 6 + 16 * images.length;
  for (let i = 0; i < images.length; i++) {
    const entry = Buffer.alloc(16);
    // A width or height of 256 is written as 0.
    entry[0] = sizes[i] >= 256 ? 0 : sizes[i];
    entry[1] = sizes[i] >= 256 ? 0 : sizes[i];
    entry.writeUInt16LE(1, 4);
    entry.writeUInt16LE(32, 6);
    entry.writeUInt32LE(images[i].length, 8);
    entry.writeUInt32LE(offset, 12);
    offset += images[i].length;
    entries.push(entry);
  }
  return Buffer.concat([header, ...entries, ...images]);
}

/**
 * Writes the app icon into the build directory and returns the COFF object holding its resource,
 * or null when the PNG can't be read or `zig rc` fails. The caller adds the object to the link, so
 * the icon lands in the executable's resource directory.
 */
export function windowsIconObject(buildDir: string, png: string): string | null {
  const raster = readPng(png);
  if (raster === null) {
    process.stderr.write(`native: the app icon '${png}' isn't a PNG this build can read; the executable has no icon\n`);
    return null;
  }
  writeFileSync(join(buildDir, "app.ico"), icoOf(raster));
  writeFileSync(join(buildDir, "app.rc"), `${APP_ICON_ID} ICON "app.ico"\n`);
  const object = join(buildDir, "app-icon.obj");
  const r = spawnSync("zig", ["rc", "/:output-format", "coff", "/:target", "x64", "/fo", object, "app.rc"], {
    cwd: buildDir,
    encoding: "utf8",
  });
  if (r.status !== 0) {
    const said = `${r.stdout ?? ""}${r.stderr ?? ""}`.trim();
    process.stderr.write(`native: could not embed the app icon${said === "" ? "" : `: ${said.split("\n")[0]}`}\n`);
    return null;
  }
  return object;
}
