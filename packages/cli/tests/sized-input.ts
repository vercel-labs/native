// A form control is an inline-block, so a width and height given to it size its box.
//   npm test

import { spawnSync } from "node:child_process";
import { decodePng } from "./png.ts";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=260, height=80"><style>
body { margin: 0; }
input { width: 200px; height: 30px; background: rgb(0, 128, 0); border: 0; }
</style></head><body><input id="i" value=""></body></html>`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-sized-input-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
const png = join(dir, "out.png");
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);

const img = decodePng(png);
const green = (x: number, y: number): boolean => {
  const o = (y * img.w + x) * 4;
  return img.rgba[o] < 60 && img.rgba[o + 1] > 90 && img.rgba[o + 1] < 180 && img.rgba[o + 2] < 60;
};
// Snapshot pixels are device pixels: 2 per CSS pixel.
check("the input's 200x30 box is painted", green(2, 2) && green(398, 2) && green(2, 58) && green(398, 58),
  `corners: ${green(2, 2)} ${green(398, 2)} ${green(2, 58)} ${green(398, 58)}`);
check("and nothing past it", !green(402, 2) && !green(2, 62), `past: ${green(402, 2)} ${green(2, 62)}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
