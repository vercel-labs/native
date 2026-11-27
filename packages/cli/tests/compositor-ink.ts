// An opacity group's layer is bounded by the ink the group actually paints, whatever commands that
// ink is recorded with: a polygon border (a triangle with no content box), a child a perspective
// projects past its box, a mask inside a transformed subtree with a sibling after it, and a leaf
// under seven nested retained layers. Each of them paints outside the group's border box and must
// still be in the presented frame, which must match the flat replay exactly.
//
// On macOS the run composites every frame the way the window does (NATIVE_COMPOSITOR_LIVE=1), so
// the presented picture is the window's own tile cache; elsewhere it is the host's composited
// snapshot of the same paint.
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

const deep = (n: number): string =>
  n === 0 ? `<i class="leaf"></i>` : `<div class="deep">${deep(n - 1)}</div>`;

const dir = mkdtempSync(join(tmpdir(), "native-compositor-ink-"));
writeFileSync(join(dir, "index.html"), `<!doctype html>
<html><head><meta charset="utf-8"><meta name="native-window" content="width=360, height=280">
<style>
body { margin: 0; background: #060607; color: #f4f2ee; font: 16px/1.3 sans-serif; }
#poly { position: absolute; left: 20px; top: 150px; width: 60px; height: 20px; opacity: .6; }
#poly .tri { position: absolute; left: 10px; top: 30px; width: 0; height: 0;
  border-left: 18px solid transparent; border-right: 18px solid transparent;
  border-top: 28px solid #2a7cff; }
#persp { position: absolute; left: 40px; top: 60px; width: 60px; height: 60px; opacity: .6; }
#persp .plane { position: absolute; left: 10px; top: 10px; width: 40px; height: 40px;
  background: #ffd166; transform: perspective(200px) translateZ(100px); }
#mgroup { position: absolute; left: 210px; top: 190px; width: 60px; height: 24px; opacity: .6; }
#mgroup .shift { position: absolute; left: 0; top: 0; width: 60px; height: 24px;
  transform: translate(0, -70px); }
#mgroup .masked { position: absolute; left: 0; top: 0; width: 60px; height: 24px; background: #ff3b30;
  -webkit-mask-image: linear-gradient(180deg, transparent 0, #000 30%, #000 70%, transparent 100%);
  mask-image: linear-gradient(180deg, transparent 0, #000 30%, #000 70%, transparent 100%); }
#mgroup .sib { position: absolute; left: 10px; top: 30px; width: 30px; height: 16px; background: #2a7cff; }
#deco { position: absolute; left: 20px; top: 200px; width: 200px; height: 20px; opacity: .6; }
.deco { text-decoration: underline; text-decoration-thickness: 10px; text-decoration-color: #2a7cff;
  text-decoration-skip-ink: none; text-underline-offset: 40px; }
#deep { position: absolute; left: 120px; top: 90px; width: 40px; height: 20px; opacity: .6; }
.deep { position: absolute; left: 0; top: 0; width: 40px; height: 20px; will-change: transform; }
.leaf { position: absolute; left: 0; top: 30px; width: 40px; height: 16px; background: #6dffb0; }
</style></head><body>
<div id="poly"><div class="tri"></div></div>
<div id="persp"><div class="plane"></div></div>
<div id="mgroup"><div class="shift"><div class="masked"></div></div><div class="sib"></div></div>
<div id="deco"><span class="deco">decorated</span></div>
<div id="deep">${deep(7)}</div>
</body></html>`);

const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) {
  console.error(build.stderr);
  process.exit(1);
}

const steps: string[] = [];
for (let i = 1; i <= 24; i++) steps.push(`frame ${i * 16}`);
const flat = join(dir, "flat.png");
const live = join(dir, "live.png");
function runApp(extra: Record<string, string>): string {
  const r = spawnSync(exe, [], {
    encoding: "utf8",
    env: { ...process.env, NATIVE_COMPOSITOR_LIVE: "1", NATIVE_COMPOSITOR_STATS: "1", ...extra },
  });
  if (r.status !== 0) {
    console.error(r.stderr);
    process.exit(1);
  }
  return r.stderr;
}
const stderr = runApp({ NATIVE_STEPS: [...steps, `snapshotcomposited ${live}`].join(" | ") });
runApp({ NATIVE_STEPS: steps.join(" | "), NATIVE_SNAPSHOT: flat });

const a = decodePng(flat);
const b = decodePng(live);
ok("both snapshots have the same size", a.w === b.w && a.h === b.h, `${a.w}x${a.h} vs ${b.w}x${b.h}`);
const scale = a.w / 360;
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
  if (d > 1) differing++;
  if (d > worst) worst = d;
  if (a.rgba[i] !== 6 || a.rgba[i + 1] !== 6 || a.rgba[i + 2] !== 7) inked++;
}
ok("the page drew something", inked > 3000, `${inked} pixels are not the background`);
ok("the presented frame holds every group's ink", differing === 0,
  `${differing} pixels differ by more than one step, worst ${worst}`);

/** A pixel of the presented frame, from a point in CSS px. */
function liveAt(x: number, y: number): number[] {
  const at = (Math.round(y * scale) * b.w + Math.round(x * scale)) * 4;
  return [b.rgba[at], b.rgba[at + 1], b.rgba[at + 2]];
}
function notBackground(c: number[]): boolean {
  return Math.abs(c[0] - 6) > 8 || Math.abs(c[1] - 6) > 8 || Math.abs(c[2] - 7) > 8;
}

// The triangle is border polygons only, hanging 30 px below its group's border box.
const tri = liveAt(48, 196);
ok("a polygon-only child paints outside the group's border box", tri[2] > 100 && tri[2] > tri[0] + 40,
  `${tri}`);
// A perspective pushes the plane's projected quad 10 px past the group's box on each side.
const projL = liveAt(34, 90);
const projR = liveAt(106, 90);
ok("a projected child paints outside the group's border box",
  projL[0] > 100 && projR[0] > 100, `${projL} ${projR}`);
// A sibling after a mask inside a transformed subtree sits 30 px below the group's border box.
const sib = liveAt(232, 228);
ok("a sibling after a mask in a transformed subtree is in the bounds", sib[2] > 100 && sib[2] > sib[0] + 40,
  `${sib}`);
// A thick underline sits 40 px below the group's border box, with nothing else of the group's
// ink outside it.
const deco = liveAt(40, 260);
ok("a thick underline paints outside the group's border box", deco[2] > 100 && deco[2] > deco[0] + 60,
  `${deco}`);
// A leaf under seven nested layers sits 30 px below the group's border box.
const leaf = liveAt(140, 128);
ok("a leaf under seven nested layers is in the bounds", leaf[1] > 100 && leaf[1] > leaf[0] + 40, `${leaf}`);

if (process.platform === "darwin") {
  const stats = stderr.split("\n").filter((l) => l.startsWith("native: composite chunks="));
  ok("the frames went through the window's compositor", stats.length >= 1, `${stats.length} frames`);
}

if (failed > 0) process.exit(1);
