// A focused contenteditable host draws a caret at its collapsed selection. The text is
// transparent and the caret is red, so the snapshot's only red pixels are the caret.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=320, height=200"><style>
body { margin: 0; background: #ffffff; }
#e { position: absolute; left: 10px; top: 10px; width: 240px; min-height: 40px;
     padding: 6px; font: 24px sans-serif; color: transparent; caret-color: #ff0000; }
</style></head><body>
<div id="e" contenteditable="true">hello</div>
</body></html>`;

const dir = mkdtempSync(join(tmpdir(), "native-contenteditable-caret-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const png = join(dir, "caret.png");
const env: NodeJS.ProcessEnv = {
  ...process.env,
  NATIVE_STEPS: "frame 0 | frame 16 | clickat 18 22 | frame 16",
  NATIVE_SNAPSHOT: png,
};
const r = spawnSync(exe, [], { encoding: "utf8", env });
if (r.status !== 0) throw new Error(`run failed\n${r.stderr}`);

const img = decodePng(png);
let red = 0;
let top = Infinity;
let bottom = -Infinity;
for (let i = 0; i < img.rgba.length; i += 4) {
  const a = img.rgba[i];
  const g = img.rgba[i + 1];
  const b = img.rgba[i + 2];
  if (a > 180 && g < 100 && b < 100) {
    red++;
    const y = Math.floor(i / 4 / img.w);
    if (y < top) top = y;
    if (y > bottom) bottom = y;
  }
}
console.log(`red pixels ${red}, height ${bottom - top + 1}`);
let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}
check("a caret is drawn", red > 10, `got ${red} red pixels`);
check("the caret is a thin line", bottom - top > 10 && red < 400, `${red} pixels, ${bottom - top + 1} tall`);
console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
