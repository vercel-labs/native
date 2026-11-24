// A box that paints through a backdrop filter (a blurred header, say) samples the pixels behind
// it. An animation inside it — the pulsing "Live" dot the dashboard carries — changes pixels the
// filter shows, but only near the dot: the frame repaints the dot and the filter's reach around
// it, not the whole box and not the page. The damage it hands the host is that region, so with
// the compositor off the present stays small too.
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

// The blurred header the dot pulses in, and the page under it.
const HEADER_W = 480;
const HEADER_H = 48;
const HEADER_AREA = HEADER_W * HEADER_H;

const dir = mkdtempSync(join(tmpdir(), "native-backdrop-anim-"));
writeFileSync(join(dir, "index.html"), `<!doctype html>
<html><head><title>backdrop anim</title>
<style>
html, body { margin: 0; background: #ffffff; font: 13px/1.4 system-ui; }
header { display: flex; align-items: center; gap: 8px; height: ${HEADER_H}px; padding: 0 16px;
         background: rgba(255, 255, 255, 0.8); backdrop-filter: blur(6px);
         border-bottom: 1px solid #e2e8f0; }
h1 { font-size: 14px; margin: 0 12px 0 0; }
.badge { display: flex; align-items: center; gap: 6px; padding: 2px 8px; border-radius: 999px;
         background: #ecfdf5; color: #047857; }
/* A pulsing dot: the frame loop paints it a new colour each frame, the paint a CSS animation of a
   property that isn't composited drives. */
.dot { display: inline-block; width: 6px; height: 6px; border-radius: 999px; background: #10b981; }
#bump { margin-left: 8px; }
.row { padding: 2px 10px; }
</style></head><body>
<header><h1>Northstar</h1><span class="badge"><span id="dot" class="dot"></span>Live</span><button id="bump">Pulse</button></header>
<div id="body"></div>
<script type="module" src="app.ts"></script>
</body></html>`);
writeFileSync(join(dir, "app.ts"), `const body = document.getElementById("body")!;
for (let i = 0; i < 200; i++) {
  const row = document.createElement("div");
  row.className = "row";
  row.textContent = "Row " + String(i + 1) + " of a page that is expensive to paint in full";
  body.appendChild(row);
}
const dot = document.getElementById("dot") as HTMLElement;
let n = 0;
function tick(): void {
  n++;
  dot.style.backgroundColor = n % 2 === 0 ? "rgb(5, 150, 105)" : "rgb(16, 185, 129)";
  requestAnimationFrame(tick);
}
requestAnimationFrame(tick);
`);

const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) {
  console.error(build.stderr);
  process.exit(1);
}

let script = "frame 0";
for (let i = 0; i < 40; i++) script += " | frame 16";
const env: NodeJS.ProcessEnv = {
  ...process.env,
  NATIVE_COMPOSITOR: "0",
  NATIVE_FRAME_TIMES: "1",
  NATIVE_DAMAGE_STATS: "1",
  NATIVE_STEPS: script,
};
const r = spawnSync(exe, [], { encoding: "utf8", env });
if (r.status !== 0) {
  console.error(r.stderr);
  process.exit(1);
}

// The opening frame paints the page. Every later painted frame is an animation step: it must be
// damage-limited, and its damage must cover the dot and the blur's reach, not the header or page.
const lines = String(r.stderr).split("\n");
let opening = -1;
const frames: { painted: number; limited: boolean; area: number; rects: number }[] = [];
for (let i = 0; i < lines.length; i++) {
  const f = /native: frame \d+ t=[\d.]+ .* paint=([\d.]+) .* painted=(\d+)/.exec(lines[i]);
  if (f === null) continue;
  const paint = Number(f[1]);
  const painted = Number(f[2]);
  if (opening < 0) { opening = painted; continue; }
  if (paint <= 0) continue;
  let limited = false, area = 0, rects = 0;
  for (let k = i + 1; k < lines.length; k++) {
    const d = /native: damage limited=(\d) rects=(\d+) reason=(\S+) area=(\d+)/.exec(lines[k]);
    if (d === null) continue;
    limited = d[1] === "1";
    rects = Number(d[2]);
    area = Number(d[4]);
    break;
  }
  frames.push({ painted, limited, area, rects });
}

ok("the opening frame paints the page", opening > 50, `${opening} boxes`);
ok("a change inside the box paints frames", frames.length >= 3, `${frames.length} painted frames after the opening`);
const unlimited = frames.filter((s) => !s.limited);
ok("a change inside the box is damage-limited", unlimited.length === 0,
  `${unlimited.length} of ${frames.length} painted the page`);
// The dot is 6px and the damage the paint records for it carries the painter's slack and the
// blur's reach around it: that region is well under the header. Repainting the filter's whole box
// is the header; the page is many times that.
const wide = frames.filter((s) => s.area > HEADER_AREA / 2);
ok("a change inside the box repaints only the dot's region around the filter", wide.length === 0,
  wide.map((s) => `${s.area}px² over ${s.rects} rects`).join(", "));
const heavy = frames.filter((s) => s.painted >= opening);
ok("a change inside the box walks less of the page than the opening", heavy.length === 0,
  heavy.map((s) => `${s.painted} boxes`).join(", "));

// The damage also has to be exact: replaying the damaged list over the previous frame's pixels,
// inside the damaged rectangles, must match a full paint of the same frame.
const v = spawnSync(exe, [], { encoding: "utf8", env: { ...env, NATIVE_VERIFY_DAMAGE: "1" } });
const wrong = String(v.stderr).split("\n").filter((l) => /native: damage verify mismatched=[1-9]/.test(l));
ok("a damaged frame inside the box matches a full paint", v.status === 0 && wrong.length === 0,
  wrong.slice(0, 3).join(" | "));

if (failed > 0) {
  console.error(`\n${failed} failed`);
  process.exit(1);
}
console.log("\nall passed");
