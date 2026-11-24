// A paint that skips boxes outside its clip against one that paints everything: the same frame
// must land on the same pixels. `NATIVE_PAINT_CULL=0` paints every box, so the two runs differ
// only in whether the boxes below the fold are recorded.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

let failed = 0;
function ok(name: string, cond: boolean, detail = ""): void {
  if (!cond) failed++;
  console.log(`${cond ? "ok  " : "FAIL"} ${name}${cond || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-cull-"));
// A tall list whose rows are leaves, with the kinds of box a cull has to be careful about mixed
// in: a shadow, a transform, text that outgrows its box, and a positioned child.
writeFileSync(join(dir, "index.html"), `<!doctype html>
<html><head><title>cull</title>
<style>
html, body { margin: 0; background: #ffffff; font: 13px/1.4 system-ui; }
#pane { height: 300px; overflow: auto; }
#tidy { height: 300px; overflow: auto; }
.row { height: 24px; padding: 2px 6px; }
.tidyrow { height: 20px; padding: 0 6px; white-space: nowrap; overflow: hidden; }
.shadowed { box-shadow: 0 0 14px #334155; }
.moved { transform: translateX(6px); }
.wide { white-space: nowrap; }
.rel { position: relative; }
.pin { position: absolute; left: 300px; top: 0; color: #b91c1c; }
</style>
</head><body>
<div id="pane"></div>
<div id="tidy"></div>
<script type="module" src="app.ts"></script>
</body></html>`);
writeFileSync(join(dir, "app.ts"), `const pane = document.getElementById("pane")!;
for (let i = 0; i < 300; i++) {
  const row = document.createElement("div");
  let cls = "row";
  if (i === 40) cls = cls + " shadowed";
  if (i === 41) cls = cls + " moved";
  if (i === 42) cls = cls + " wide";
  if (i === 43) cls = cls + " rel";
  row.className = cls;
  row.textContent = "Row " + String(i + 1) + " the quick brown fox jumps over the lazy dog, and keeps running past the edge of its box for the overflow case";
  if (i === 43) {
    const pin = document.createElement("span");
    pin.className = "pin";
    pin.textContent = "pinned";
    row.appendChild(pin);
  }
  pane.appendChild(row);
}
// A second list whose rows stay inside their boxes: the case where a row below the scrollport
// is skipped by where it is rather than by what it holds.
const tidy = document.getElementById("tidy")!;
for (let i = 0; i < 300; i++) {
  const row = document.createElement("div");
  row.className = "tidyrow";
  row.textContent = "Row " + String(i + 1) + " stays inside its box";
  tidy.appendChild(row);
}
`);

const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) {
  console.error(build.stderr);
  process.exit(1);
}

function shot(pane: string, offset: number, culled: boolean): string {
  const file = join(dir, `shot-${pane}-${offset}-${culled ? "cull" : "all"}.png`);
  const r = spawnSync(exe, [], {
    encoding: "utf8",
    env: {
      ...process.env,
      NATIVE_STEPS: `frame 16 | scrolltop #${pane} ${offset} | frame 32`,
      NATIVE_SNAPSHOT: file,
      NATIVE_PAINT_CULL: culled ? "1" : "0",
    },
  });
  if (r.status !== 0) {
    console.error(r.stderr);
    process.exit(1);
  }
  return file;
}

// The rows of both lists, with the scrollport at the top and scrolled far past it: the second
// list's rows fit in their boxes, so only their position has to keep them out of the clip.
for (const pane of ["pane", "tidy"]) for (const offset of [0, 2400, 6000]) {
  const a = decodePng(shot(pane, offset, false));
  const b = decodePng(shot(pane, offset, true));
  let differing = 0;
  let worst = 0;
  let inked = 0;
  const n = Math.min(a.rgba.length, b.rgba.length);
  for (let i = 0; i < n; i += 4) {
    const d = Math.max(
      Math.abs(a.rgba[i] - b.rgba[i]),
      Math.abs(a.rgba[i + 1] - b.rgba[i + 1]),
      Math.abs(a.rgba[i + 2] - b.rgba[i + 2]),
      Math.abs(a.rgba[i + 3] - b.rgba[i + 3]),
    );
    if (d > 0) differing++;
    if (d > worst) worst = d;
    if (a.rgba[i] !== 255 || a.rgba[i + 1] !== 255 || a.rgba[i + 2] !== 255) inked++;
  }
  ok(`${pane} at ${offset}: the picture has content`, inked > 500, `${inked} pixels are not white`);
  ok(`${pane} at ${offset}: skipping boxes outside the clip changes no pixel`, differing === 0,
    `${differing} pixels differ, worst ${worst}`);
}

if (failed > 0) {
  console.error(`\n${failed} failed`);
  process.exit(1);
}
console.log("\nall passed");
