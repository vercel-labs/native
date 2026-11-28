// A blurred panel whose content animates, in a compositing window with damage on. The frame is
// patched from its damaged rectangles alone, so the backdrop filter must be given the pixels under
// its whole box: a damaged region smaller than the box leaves the blur reading the region's edge
// instead of the page behind the panel.
//
// A change inside the box therefore damages the box's filter-expanded bounds — the box plus the
// blur's reach — and the panel is re-filtered over that, the way Chrome does. This window run
// holds the frame's damage to that: every damaged frame covers at least the whole panel, and the
// compositor patches it.
//   npm test
// This opens a real window and skips cleanly when the session has none.

import { spawn, spawnSync } from "node:child_process";
import { mkdtempSync, openSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

let failed = 0;
function ok(name: string, cond: boolean, detail = ""): void {
  if (!cond) failed++;
  console.log(`${cond ? "ok  " : "FAIL"} ${name}${cond || detail === "" ? "" : ` — ${detail}`}`);
}

if (process.platform !== "darwin") {
  console.log(`ok   skipped: the compositor's damage patch is macOS's (this is ${process.platform})`);
  process.exit(0);
}

// The panel, in CSS px; a change inside it has to repaint at least this much.
const PANEL_W = 400;
const PANEL_H = 280;

const dir = mkdtempSync(join(tmpdir(), "native-backdrop-damage-"));
writeFileSync(join(dir, "index.html"), `<!doctype html>
<html><head><meta charset="utf-8"><meta name="native-window" content="width=900, height=600">
<style>
html, body { margin: 0; width: 900px; height: 600px; overflow: hidden; background: #f7f6f3;
  font: 600 13px/16px sans-serif; color: #121214; }
#under { position: absolute; left: 250px; top: 160px; width: ${PANEL_W}px; height: ${PANEL_H}px;
  background: linear-gradient(90deg, #3d3bf3 0 50%, #ff6a3d 50% 100%); }
#glass { position: absolute; left: 250px; top: 160px; width: ${PANEL_W}px; height: ${PANEL_H}px;
  background: rgba(255, 255, 255, 0.5); backdrop-filter: blur(18px); }
#n { position: absolute; left: 180px; top: 130px; }
</style></head><body>
<div id="under"></div>
<div id="glass"><div id="n">0</div></div>
<script type="module" src="app.ts"></script>
</body></html>`);
// The counter sits inside the panel and changes every frame: every frame after the first is a
// damaged frame whose blur has to be patched from the panel's own pixels.
writeFileSync(join(dir, "app.ts"), `const n = document.getElementById("n")!;
let k = 0;
function tick(): void {
  n.textContent = String(k++);
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

const log = join(dir, "app.log");
const fd = openSync(log, "w");
const sleep = (ms: number): void => {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
};
const running = (pid: number): boolean => {
  const r = spawnSync("ps", ["-p", String(pid)], { encoding: "utf8" });
  return r.status === 0 && r.stdout.trim() !== "";
};
function start(): number {
  const env = { ...process.env, NATIVE_DAMAGE_STATS: "1", NATIVE_COMPOSITOR_STATS: "1", NATIVE_FRAME_TIMES: "1" };
  const child = spawn(exe, [], { detached: true, stdio: ["ignore", fd, fd], env });
  const pid = child.pid ?? 0;
  for (let i = 0; i < 30 && pid !== 0; i++) {
    sleep(200);
    if (running(pid)) return pid;
  }
  return 0;
}

const pid = start();
if (pid === 0) {
  console.log("ok   skipped: the app did not open a window in this session");
  console.log("\nall passed");
  process.exit(0);
}
// Let the window open, paint whole once, then patch a few damaged frames.
for (let i = 0; i < 12; i++) {
  sleep(250);
  if (!running(pid)) break;
}
spawnSync("kill", [String(pid)]);
sleep(200);

const text = readFileSync(log, "utf8");
const composited = [...text.matchAll(/native: composite damage /g)].length;
if (composited === 0) {
  console.log("ok   skipped: the window did not composite a damaged frame in this session");
  console.log("\nall passed");
  process.exit(0);
}
const damages = [...text.matchAll(/native: damage limited=(\d) rects=(\d+) reason=(\S+) area=(\d+)/g)]
  .map((m) => ({ limited: Number(m[1]), rects: Number(m[2]), area: Number(m[4]) }));
const limited = damages.filter((d) => d.limited === 1);
const small = limited.filter((d) => d.area < PANEL_W * PANEL_H);
ok("the window composited damaged frames", composited > 0, `${composited} patches`);
ok("a change inside the panel is damage-limited", limited.length > 0,
  `${limited.length} of ${damages.length} frames`);
ok("a change inside the panel repaints the whole panel", small.length === 0,
  small.length === 0 ? "" : `${small.length} frames under ${PANEL_W * PANEL_H}px²: ${small.map((d) => d.area).join(", ")}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
