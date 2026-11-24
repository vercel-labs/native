// display: contents: the box isn't generated, and the children take its place in the flow — a
// block child in the parent's flow, an inline child in the line.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";
import type { Image } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=200"><style>
body { margin: 0; }
#outer { position: absolute; left: 0; top: 0; width: 200px; padding: 10px; background: #00aa00; }
#c1 { display: contents; background: #0000ff; }
#kid { width: 50px; height: 50px; background: #ff0000; }
#line { position: absolute; left: 0; top: 120px; width: 200px; font: 20px monospace; color: #000000; }
#c2 { display: contents; color: #0000ff; }
#blk { display: inline-block; width: 20px; height: 10px; background: #0000ff; }
</style></head><body>
<div id="outer"><div id="c1"><div id="kid"></div></div></div>
<div id="line">A<span id="c2"><span id="blk"></span></span>C</div>
<script>
const c1 = getComputedStyle(document.getElementById("c1")!);
console.log("display=" + c1.display + " background=" + c1.backgroundColor);

</script>
</body></html>`;

function buildAndRun(): { img: Image; out: string } {
  const dir = mkdtempSync(join(tmpdir(), "native-contents-"));
  writeFileSync(join(dir, "index.html"), PAGE);
  const exe = join(dir, "app");
  const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
  if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
  const png = join(dir, "out.png");
  const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png } });
  if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
  return { img: decodePng(png), out: `${r.stdout}${r.stderr}` };
}

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const { img, out } = buildAndRun();
const rgb = (x: number, y: number): number[] => {
  const o = (Math.round(y * 2) * img.w + Math.round(x * 2)) * 4;
  return [img.rgba[o], img.rgba[o + 1], img.rgba[o + 2]];
};
const near = (x: number, y: number, c: number[], tol = 24): boolean => {
  const p = rgb(x, y);
  return Math.abs(p[0] - c[0]) <= tol && Math.abs(p[1] - c[1]) <= tol && Math.abs(p[2] - c[2]) <= tol;
};

// The contents wrapper has no box: its child starts at the outer box's content origin.
check("a block child of a contents element sits in the parent's flow", near(35, 35, [255, 0, 0]), `got ${rgb(35, 35)}`);
check("the parent's background shows beside it", near(100, 35, [0, 170, 0]), `got ${rgb(100, 35)}`);
check("the contents element paints no background of its own", near(100, 10, [0, 170, 0]), `got ${rgb(100, 10)}`);

const lines = out.split("\n");
check("display computes as contents", lines.includes("display=contents background=rgba(0, 0, 255, 1)") ||
  lines.some((l) => l.startsWith("display=contents")), JSON.stringify(lines.filter((l) => l.startsWith("display="))));
// The inline-block inside the contents span is laid out on the line, so it paints blue in the
// line's band and the text after it stays on the same line.
let blue = 0, blackBelow = 0;
for (let y = 118; y < 150; y++) for (let x = 0; x < 200; x++) {
  if (near(x, y, [0, 0, 255], 30)) blue++;
}
for (let y = 152; y < 190; y++) for (let x = 0; x < 200; x++) {
  if (near(x, y, [0, 0, 0], 60)) blackBelow++;
}
check("an inline contents element joins the line", blue >= 20, `${blue} blue pixels in the line`);
check("the line does not wrap around it", blackBelow === 0, `${blackBelow} black pixels below the line`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
