// A box that paints through a backdrop filter (a blurred header, say) samples the pixels behind
// it. A change under it has to repaint that box, but a change elsewhere on the page must still be
// damage-limited: the filter's box is the largest thing such a change can force, never the page.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

let failed = 0;
function ok(name: string, cond: boolean, detail = ""): void {
  if (!cond) failed++;
  console.log(`${cond ? "ok  " : "FAIL"} ${name}${cond || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-backdrop-"));
writeFileSync(join(dir, "index.html"), `<!doctype html>
<html><head><title>backdrop</title>
<style>
html, body { margin: 0; background: #ffffff; font: 13px/1.4 system-ui; }
header { display: flex; align-items: center; gap: 6px; height: 48px; padding: 0 10px;
         background: rgba(255, 255, 255, 0.7); backdrop-filter: blur(6px);
         position: sticky; top: 0; }
.row { padding: 2px 10px; }
#bump { margin-left: auto; }
</style></head><body>
<header>Live<button id="bump">bump</button></header>
<div id="body"></div>
<script type="module" src="app.ts"></script>
</body></html>`);
writeFileSync(join(dir, "app.ts"), `const body = document.getElementById("body")!;
const rows: HTMLElement[] = [];
for (let i = 0; i < 200; i++) {
  const row = document.createElement("div");
  row.className = "row";
  row.textContent = "Row " + String(i + 1) + " of a page that is expensive to paint in full";
  body.appendChild(row);
  rows.push(row);
}
document.getElementById("bump")!.addEventListener("click", () => {
  rows[20].textContent = "Row 21 changed under the blurred header";
});
`);

const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) {
  console.error(build.stderr);
  process.exit(1);
}

const r = spawnSync(exe, [], {
  encoding: "utf8",
  env: {
    ...process.env,
    NATIVE_FRAME_TIMES: "1",
    NATIVE_DAMAGE_STATS: "1",
    NATIVE_STEPS: "frame 16 | click #bump | frame 16 | frame 16",
  },
});
if (r.status !== 0) {
  console.error(r.stderr);
  process.exit(1);
}

const lines = String(r.stderr).split("\n");
let opening = -1;
let changed = -1;
let changedRects = 0;
let changedLimited = false;
for (let i = 0; i < lines.length; i++) {
  const f = /native: frame \d+ t=[\d.]+ .* paint=([\d.]+) .* total=[\d.]+/.exec(lines[i]);
  if (f === null) continue;
  const paint = Number(f[1]);
  if (opening < 0) { opening = paint; continue; }
  if (paint <= 0) continue;
  for (let k = i + 1; k < lines.length; k++) {
    const d = /native: damage limited=(\d) rects=(\d+) reason=(\S+)/.exec(lines[k]);
    if (d === null) continue;
    changedLimited = d[1] === "1";
    changedRects = Number(d[2]);
    break;
  }
  changed = paint;
}

ok("the opening frame paints the page", opening > 1, `opening paint ${opening} ms`);
ok("the change behind the blurred header paints", changed > 0, `change frame paint ${changed} ms`);
ok("the change is damage-limited", changedLimited, `limited=${changedLimited}`);
ok("the damage reaches the filter box", changedRects >= 2, `${changedRects} rects`);
ok("a change under a backdrop filter does not repaint the page", changed > 0 && changed < opening / 2,
  `${changed.toFixed(2)} ms against ${opening.toFixed(2)} ms for the page`);

if (failed > 0) {
  console.error(`\n${failed} failed`);
  process.exit(1);
}
console.log("\nall passed");
