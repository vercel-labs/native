// Text at font-size 0 draws nothing.
//
// measure() already gives every glyph a zero advance at a zero size, so the text takes no room.
// The host's font API clamps the size it is given, though, so without a matching check at paint
// time the letters still appear, at the smallest size the API allows.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

// Two 100px halves: the left one holds the zero-sized text over white, the right one the same
// text at 20px, so the check is that one half stays blank and the other doesn't.
const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=200, height=60"><style>
body { margin: 0; }
#zero, #control { float: left; width: 100px; height: 40px; background: #fff; color: #000; }
#zero { font-size: 0; }
#control { font-size: 20px; }
</style></head><body>
<div id="zero">MM</div><div id="control">MM</div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `const size = (id: string): string => getComputedStyle(document.getElementById(id) as HTMLElement).fontSize;
console.log("zero=" + size("zero"));
console.log("control=" + size("control"));
`;

const dir = mkdtempSync(join(tmpdir(), "native-font-size-zero-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);
const png = join(dir, "out.png");
const run = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png } });
if (run.status !== 0) throw new Error(`render failed\n${run.stderr}`);
const out = `${run.stdout}${run.stderr}`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const lines = out.split("\n").map((l) => l.trim());
check("the computed size is zero", lines.includes("zero=0px"), `got:\n${out.trim()}`);
check("the control keeps its size", lines.includes("control=20px"), `got:\n${out.trim()}`);

const img = decodePng(png);
// Dark pixels (ink, not the white background), in CSS px, over the top of both halves.
function ink(x0: number, x1: number): number {
  let n = 0;
  for (let y = 1; y < 40; y++) {
    for (let x = x0; x < x1; x++) {
      const o = ((y * 2) * img.w + x * 2) * 4;
      if (img.rgba[o] < 128 && img.rgba[o + 1] < 128 && img.rgba[o + 2] < 128) n++;
    }
  }
  return n;
}

check("a zero font size paints no ink", ink(1, 99) === 0, `${ink(1, 99)} dark pixels`);
check("the 20px text paints ink", ink(101, 199) > 20, `${ink(101, 199)} dark pixels`);

if (failed > 0) process.exit(1);
console.log("\nall passed");
