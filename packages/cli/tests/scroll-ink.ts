// A scroll that repaints (a container with positioned rows, which the compositor can't move as
// one layer) repaints what the scrollport shows, including the rows that scrolled into it. Their
// ink was recorded where they were in the last full paint, so a damaged frame that culls by that
// ink alone leaves them blank until something paints the page again.
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

const dir = mkdtempSync(join(tmpdir(), "native-scroll-ink-"));
writeFileSync(join(dir, "index.html"), `<!doctype html>
<html><head><title>ink</title>
<style>
html, body { margin: 0; background: #ffffff; font: 13px/1.4 system-ui; }
#pane { height: 300px; overflow-y: auto; }
/* Positioned rows: the scroll container can't composite them, so every scroll step paints. */
.row { position: relative; height: 20px; padding: 0 6px; }
</style></head><body>
<div id="pane"></div>
<script type="module" src="app.ts"></script>
</body></html>`);
writeFileSync(join(dir, "app.ts"), `const pane = document.getElementById("pane")!;
for (let i = 0; i < 300; i++) {
  const row = document.createElement("div");
  row.className = "row";
  row.textContent = "Row " + String(i + 1);
  pane.appendChild(row);
}
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
    NATIVE_COMPOSITOR: "0",
    NATIVE_FRAME_TIMES: "1",
    NATIVE_DAMAGE_STATS: "1",
    NATIVE_STEPS: "frame 16 | wheel #pane 600 | frame 16 | frame 16 | wheel #pane -600 | frame 16 | frame 16",
  },
});
if (r.status !== 0) {
  console.error(r.stderr);
  process.exit(1);
}

// Every painted frame after the opening is a scroll step: its damage stays inside the scrollport
// and it paints the rows there, both the ones that were on screen and the ones that just scrolled
// in. The opening paints every box; a scroll that culls the new rows paints well under this.
const lines = String(r.stderr).split("\n");
let openingBoxes = 0;
const steps: { paint: number; painted: number; limited: boolean }[] = [];
let first = true;
for (let i = 0; i < lines.length; i++) {
  const f = /native: frame \d+ t=[\d.]+ .* paint=([\d.]+) .* painted=(\d+)/.exec(lines[i]);
  if (f === null) continue;
  const paint = Number(f[1]);
  const painted = Number(f[2]);
  if (first) { first = false; openingBoxes = painted; continue; }
  if (paint <= 0) continue;
  let limited = false;
  for (let k = i + 1; k < lines.length; k++) {
    const d = /native: damage limited=(\d)/.exec(lines[k]);
    if (d === null) continue;
    limited = d[1] === "1";
    break;
  }
  steps.push({ paint, painted, limited });
}

ok("the opening frame paints every row", openingBoxes > 50, `${openingBoxes} boxes`);
ok("both scroll steps paint", steps.length >= 2, `${steps.length} painted frames after the opening`);
const scrolled = steps.filter((s) => s.limited);
ok("a scroll step is damage-limited", scrolled.length === steps.length,
  `${scrolled.length} of ${steps.length} limited`);
// Each scroll step must paint the rows that scrolled into the scrollport, not just the ones that
// were already there: ~15 visible rows, ~1 box each, plus the pane.
const thin = steps.filter((s) => s.painted < 30);
ok("a scroll step paints the rows that scrolled into view", thin.length === 0,
  thin.map((s) => `${s.painted} boxes`).join(", "));

if (failed > 0) {
  console.error(`\n${failed} failed`);
  process.exit(1);
}
console.log("\nall passed");
