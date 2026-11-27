// An <svg> whose <defs> and <path>s a script rebuilds with innerHTML every frame. The paths fill
// with gradients the same assignment defines, by url(#id): the paint resolves the id in the
// subtree the frame holds, so a gradient defined again on every frame paints, and so does one
// whose id changes each time (the old id stays in the paint URL table but nothing names it). The
// computed value reads back as the url(#id) it was written as. Relay's live traffic sparkline is
// rebuilt this way: before markup assigned to an <svg> was parsed in the SVG namespace (#874),
// the paths kept the initial black fill and the chart came up empty.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=240, height=260"><style>
body { margin: 0; background: #000000; }
svg { position: absolute; left: 0; width: 220px; height: 70px; }
#static { top: 0; }
#rebuilt { top: 85px; }
#renamed { top: 170px; }
</style></head><body>
<svg id="static" viewBox="0 0 220 70">
  <defs><linearGradient id="once" x1="0" x2="1">
    <stop offset="0" stop-color="#ff0000" stop-opacity="1"/>
    <stop offset="1" stop-color="#ff0000" stop-opacity="1"/>
  </linearGradient></defs>
  <rect width="220" height="70" fill="url(#once)"/>
</svg>
<svg id="rebuilt" viewBox="0 0 220 70"></svg>
<svg id="renamed" viewBox="0 0 220 70"></svg>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const green = (id: string): string =>
  '<linearGradient id="' + id + '" x1="0" x2="1">' +
  '<stop offset="0" stop-color="#00ff00"/><stop offset="1" stop-color="#00ff00"/>' +
  '</linearGradient>';
const rebuilt = document.getElementById("rebuilt") as Element;
const renamed = document.getElementById("renamed") as Element;
let frame = 0;
function paint(): void {
  // Each frame's rectangle is wider than the last, so a paint that keeps the first frame's nodes
  // leaves the old, narrower rectangle behind, and one that never resolved the gradient shows
  // nothing at all.
  const w = frame === 0 ? 60 : 200;
  rebuilt.innerHTML = '<defs>' + green("green") + '</defs>' +
    '<path d="M0 0 H' + w + ' V70 H0 Z" fill="url(#green)"/>' +
    '<path d="M0 65 H220" fill="none" stroke="#0000ff" stroke-width="8"/>';
  renamed.innerHTML = '<defs>' + green("named" + frame) + '</defs>' +
    '<path d="M0 0 H' + w + ' V70 H0 Z" fill="url(#named' + frame + ')"/>';
  const fill = (svg: Element): string => {
    const shape = svg.querySelector("path");
    return shape === null ? "none" : getComputedStyle(shape).fill;
  };
  // The computed value names the paint server, as a browser's does; "rgb(0, 0, 0)" would be the
  // initial fill an assignment in the wrong namespace falls back to.
  console.log("rebuilt fill=" + fill(rebuilt) + " renamed fill=" + fill(renamed));
  frame++;
}
paint();
requestAnimationFrame(paint);
requestAnimationFrame(paint);
`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-rebuilt-defs-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const png = join(dir, "out.png");
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png, NATIVE_STEPS: "frame 0 | frame 16 | frame 32" } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const img = decodePng(png);

/** The pixel at CSS coordinates (cx, cy), as [r, g, b]; the snapshot is 2 device px per CSS px. */
function at(cx: number, cy: number): number[] {
  const o = (Math.floor(cy * 2) * img.w + Math.floor(cx * 2)) * 4;
  return [img.rgba[o], img.rgba[o + 1], img.rgba[o + 2]];
}

const RED = [255, 0, 0], GREEN = [0, 255, 0], BLUE = [0, 0, 255];
const near = (got: number[], want: number[], tol = 6): boolean => got.every((g, i) => Math.abs(g - want[i]) <= tol);

// A gradient in the page's markup is the control: the painter itself is fine.
check("a gradient in markup paints its rectangle", near(at(110, 35), RED), `got ${at(110, 35).join(",")}`);

// The rebuilt <defs> names its gradient by id every frame; the frame's paths fill from it.
check("a gradient rebuilt with innerHTML paints the frame's rectangle", near(at(100, 120), GREEN), `got ${at(100, 120).join(",")}`);
check("the rebuilt rectangle reaches the width the last frame gave it", near(at(180, 120), GREEN), `got ${at(180, 120).join(",")}`);
check("a plain stroke in the rebuilt markup paints too", near(at(110, 150), BLUE), `got ${at(110, 150).join(",")}`);

// A gradient whose id changes every frame resolves against the definition that frame made.
check("a gradient named afresh each frame paints", near(at(100, 205), GREEN), `got ${at(100, 205).join(",")}`);
check("the renamed rectangle reaches the last frame's width", near(at(180, 205), GREEN), `got ${at(180, 205).join(",")}`);

// The computed value keeps the url(#id) the markup wrote, as a browser's does.
check("the computed fill names the paint server", /rebuilt fill=url\("#green"\) renamed fill=url\("#named\d+"\)/.test(r.stdout), r.stdout.trim().split("\n")[0] ?? "no output");

if (failed > 0) {
  console.error(`\n${failed} check${failed === 1 ? "" : "s"} failed`);
  process.exit(1);
}
console.log("\nall rebuilt <defs> checks passed");
