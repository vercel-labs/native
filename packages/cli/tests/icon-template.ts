// A page's icon drawn the way a browser reads it is rarely drawn for a platform's icon grid. A
// maskable icon gets the platform's template; a full-bleed `any` icon does too, because it is
// almost never what its author meant; an icon that already has padding, or whose purpose is
// stated, is used as it is.
//
// The checks render the macOS .icns with the same code the build uses and read the 1024-pixel
// picture back: a full-bleed picture is inset to the grid, its corners are masked away, and a
// shadow sits under it, while a padded picture keeps its own margins.
//   npm test

import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { appInfoOf } from "../compiler/app-info.ts";
import { iconChoice, macIcon, platformIcon, writeIcns, MACOS_CANVAS } from "../compiler/app-icon.ts";
import { alphaBounds, type Raster } from "../compiler/png.ts";
import { decodePng, encodePng } from "./png.ts";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

/** A 512-pixel full-bleed picture: a white disc on a blue field, opaque to every edge. */
function fullBleed(): Buffer {
  return encodePng(512, 512, (x, y) => {
    const dx = x - 256, dy = y - 256;
    return dx * dx + dy * dy < 200 * 200 ? [250, 250, 250, 255] : [29, 78, 216, 255];
  });
}

/** A 512-pixel picture whose art keeps a quarter of the canvas transparent on every side. */
function padded(): Buffer {
  return encodePng(512, 512, (x, y) => {
    const inside = x >= 128 && x < 384 && y >= 128 && y < 384;
    return inside ? [29, 78, 216, 255] : [0, 0, 0, 0];
  });
}

/** A page's app info, with `body` as its markup and any files written beside it. */
function app(markup: (files: Record<string, Buffer | string>) => string): ReturnType<typeof appInfoOf> {
  const dir = mkdtempSync(join(tmpdir(), "native-icon-template-"));
  const files: Record<string, Buffer | string> = { "full.png": fullBleed(), "padded.png": padded() };
  writeFileSync(join(dir, "index.html"), markup(files));
  for (const [name, body] of Object.entries(files)) {
    if (name === "index.html") continue;
    writeFileSync(join(dir, name), body);
  }
  return appInfoOf(join(dir, "index.html"));
}

/** The PNG one chunk of an .icns holds. */
function icnsChunk(icns: Buffer, type: string): Buffer | null {
  if (icns.toString("ascii", 0, 4) !== "icns") return null;
  let at = 8;
  while (at + 8 <= icns.length) {
    const kind = icns.toString("ascii", at, at + 4);
    const length = icns.readUInt32BE(at + 4);
    if (length < 8) return null;
    if (kind === type) return icns.subarray(at + 8, at + length);
    at += length;
  }
  return null;
}

/** The pixels of an .icns's 1024-pixel chunk. */
function icnsPicture(icns: Buffer): Raster {
  const png = icnsChunk(icns, "ic10");
  if (png === null) throw new Error("the .icns has no 1024-pixel chunk");
  const dir = mkdtempSync(join(tmpdir(), "native-icon-read-"));
  const file = join(dir, "icon.png");
  writeFileSync(file, png);
  const img = decodePng(file);
  return { width: img.w, height: img.h, rgba: img.rgba };
}

const alphaAt = (img: Raster, x: number, y: number): number => img.rgba[(y * img.width + x) * 4 + 3];

// A full-bleed icon, named by a <link rel="icon"> with no purpose: macOS's grid applies.
const linked = app(() => `<!doctype html><html><head>
<link rel="icon" href="full.png" sizes="512x512" type="image/png"></head><body></body></html>`);
const fullChoice = iconChoice(linked, "macos");
check("a full-bleed icon gets the macOS template", fullChoice !== null && fullChoice.template,
  fullChoice === null ? "no choice" : `template ${fullChoice.template}`);
if (fullChoice !== null && fullChoice.raster !== null) {
  const icns = writeIcns(macIcon(fullChoice.raster, fullChoice.template));
  check("the .icns holds the 1024-pixel chunk", icnsChunk(icns, "ic10") !== null);
  const img = icnsPicture(icns);
  check("the canvas is 1024", img.width === MACOS_CANVAS && img.height === MACOS_CANVAS);
  check("the picture is inset to the grid", alphaAt(img, 512, 100) > 200 && alphaAt(img, 5, 5) === 0,
    `edge ${alphaAt(img, 512, 100)}, corner ${alphaAt(img, 5, 5)}`);
  check("the squircle masks the corners", alphaAt(img, 104, 104) === 0,
    `corner alpha ${alphaAt(img, 104, 104)}`);
  check("a shadow sits under the shape", alphaAt(img, 512, 940) > 0 && alphaAt(img, 512, 940) < 200,
    `shadow alpha ${alphaAt(img, 512, 940)}`);
  const solid = alphaBounds(img);
  check("the shape spans the 824-pixel grid", solid.left <= 101 && solid.right >= 923,
    `${solid.left}..${solid.right}`);
  // The Windows and Linux template keeps a 5% margin around the same picture.
  const win = platformIcon(fullChoice.raster, 256, true);
  const inside = alphaBounds(win);
  check("Windows and Linux inset a templated picture", inside.left >= 10 && inside.right <= 246,
    `${inside.left}..${inside.right}`);
}

// A picture with its own transparent padding is used as it is.
const paddedChoice = iconChoice(app(() => `<!doctype html><html><head>
<link rel="icon" href="padded.png" sizes="512x512" type="image/png"></head><body></body></html>`), "macos");
check("a padded icon is used as it is", paddedChoice !== null && !paddedChoice.template,
  paddedChoice === null ? "no choice" : `template ${paddedChoice.template}`);
if (paddedChoice !== null && paddedChoice.raster !== null) {
  const img = icnsPicture(writeIcns(macIcon(paddedChoice.raster, paddedChoice.template)));
  const bounds = alphaBounds(img);
  const quarter = MACOS_CANVAS / 4;
  check("its own margins are kept", bounds.left >= quarter - 2 && bounds.right <= MACOS_CANVAS - quarter + 2,
    `${bounds.left}..${bounds.right}`);
  check("nothing is masked", alphaAt(img, 300, 300) > 200 && alphaAt(img, 5, 5) === 0,
    `corner alpha ${alphaAt(img, 300, 300)}`);
}

// Stating the purpose is the opt-out: an explicit `any` full-bleed icon is not templated.
const explicit = app((files) => {
  files["manifest.json"] = JSON.stringify({
    icons: [{ src: "full.png", sizes: "512x512", type: "image/png", purpose: "any" }],
  });
  return `<!doctype html><html><head><link rel="manifest" href="manifest.json"></head><body></body></html>`;
});
const statedChoice = iconChoice(explicit, "macos");
check("a stated purpose is the opt-out", statedChoice !== null && !statedChoice.template,
  statedChoice === null ? "no choice" : `template ${statedChoice.template}`);
if (statedChoice !== null && statedChoice.raster !== null) {
  const img = icnsPicture(writeIcns(macIcon(statedChoice.raster, statedChoice.template)));
  check("its full bleed is kept", alphaAt(img, 2, 2) > 200, `corner alpha ${alphaAt(img, 2, 2)}`);
}

// With both kinds listed, each platform takes the one drawn for it.
const both = app((files) => {
  files["manifest.json"] = JSON.stringify({
    icons: [
      { src: "padded.png", sizes: "512x512", type: "image/png", purpose: "any" },
      { src: "full.png", sizes: "512x512", type: "image/png", purpose: "maskable" },
    ],
  });
  return `<!doctype html><html><head><link rel="manifest" href="manifest.json"></head><body></body></html>`;
});
const macPick = iconChoice(both, "macos");
const winPick = iconChoice(both, "windows");
const linuxPick = iconChoice(both, "linux");
check("macOS picks the maskable icon", macPick !== null && macPick.icon.href === "full.png" && macPick.template,
  macPick === null ? "no choice" : `${macPick.icon.href} template ${macPick.template}`);
check("Windows picks the padding-ready icon", winPick !== null && winPick.icon.href === "padded.png" && !winPick.template,
  winPick === null ? "no choice" : `${winPick.icon.href} template ${winPick.template}`);
check("Linux picks the padding-ready icon", linuxPick !== null && linuxPick.icon.href === "padded.png" && !linuxPick.template,
  linuxPick === null ? "no choice" : `${linuxPick.icon.href} template ${linuxPick.template}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
