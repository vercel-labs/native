// An image's EXIF orientation is read before the image is decoded, from offsets the file itself
// supplies. A PNG whose eXIf chunk names an IFD at or just below the top of its 32-bit range has
// to read as recording no orientation, not as a read past the file.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { chunk, decodePng, encodePng } from "./png.ts";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

// The host that reads EXIF itself is the Linux one; other platforms hand the file to the
// system's image stack.
if (process.platform !== "linux") {
  console.log("ok   EXIF offsets are read by the Linux host (skipped on this platform)");
  console.log("\nall passed");
  process.exit(0);
}

const RED = [255, 0, 0, 255];
const base = encodePng(16, 8, () => RED);
// PNG signature and the IHDR chunk, the point a chunk of our own goes after.
const AFTER_IHDR = 8 + 12 + 13;

/** The fixture PNG with a TIFF header whose IFD sits at `offset`. */
function withIfd(offset: number): Buffer {
  const tiff = Buffer.alloc(8);
  tiff.write("MM", 0, "ascii");
  tiff.writeUInt16BE(42, 2);
  tiff.writeUInt32BE(offset, 4);
  return Buffer.concat([base.subarray(0, AFTER_IHDR), chunk("eXIf", tiff), base.subarray(AFTER_IHDR)]);
}

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=120, height=40"><style>
body { margin: 0; background: #ffffff; }
img { position: absolute; top: 0; left: 0; }
#near { left: 40px; }
</style></head><body>
<img id="top" src="top.png"><img id="near" src="near.png">
</body></html>`;

const dir = mkdtempSync(join(tmpdir(), "native-png-exif-"));
writeFileSync(join(dir, "top.png"), withIfd(0xffffffff));
writeFileSync(join(dir, "near.png"), withIfd(0xfffffffe));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const png = join(dir, "out.png");
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png, NATIVE_STEPS: "frame" } });
if (r.status !== 0) throw new Error(`render failed (exit ${r.status ?? r.signal})\n${r.stderr}`);
const img = decodePng(png);

/** The pixel at CSS (x, y) of the snapshot, which draws at twice the CSS size. */
function pixel(x: number, y: number): number[] {
  const o = (Math.floor(y * 2) * img.w + Math.floor(x * 2)) * 4;
  return [img.rgba[o], img.rgba[o + 1], img.rgba[o + 2]];
}

function isRed(px: number[]): boolean {
  return px[0] > 200 && px[1] < 60 && px[2] < 60;
}

const top = pixel(4, 4);
check("an IFD offset at the top of the range leaves the image unrotated", isRed(top), `pixel ${top.join(",")}`);
const near = pixel(44, 4);
check("an IFD offset one below it leaves the image unrotated", isRed(near), `pixel ${near.join(",")}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
