// A disabled button with an author background still paints that background, and its label: the
// disabled attribute doesn't remove the element from the paint. Chrome dims the UA colour but
// paints both.   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta charset="utf-8"><meta name="native-window" content="width=320, height=140"><style>
body { margin: 0; background: #dddddd; font: 16px sans-serif; padding: 20px; }
button { background: #ffffff; color: #111111; border: 0; padding: 10px 16px; }
</style></head><body>
<button id="b" disabled>Disabled</button>
</body></html>`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-disabled-button-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const png = join(dir, "out.png");
const run = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png, NATIVE_STEPS: "frame 0 | frame 16" } });
if (run.status !== 0) throw new Error(`render failed\n${run.stderr}`);
const img = decodePng(png);
let white = 0;
let dark = 0;
for (let i = 0; i < img.rgba.length; i += 4) {
  const r = img.rgba[i], g = img.rgba[i + 1], b = img.rgba[i + 2];
  if (r >= 250 && g >= 250 && b >= 250) white++;
  if (r <= 40 && g <= 40 && b <= 40) dark++;
}
check("the disabled button paints its author background", white > 300, `white pixels: ${white}`);
check("the disabled button paints its label", dark > 100, `dark pixels: ${dark}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
