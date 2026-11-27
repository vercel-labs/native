// An opacity group's layer is bounded by its box: a page with a fading box inside a mask-image
// and a second fading group whose child overflows it and whose shadow reaches past it must
// present exactly what the flat replay holds — the group's alpha, its blend, the mask's gradient,
// and the ink that reaches past the group's border box.
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

const dir = mkdtempSync(join(tmpdir(), "native-compositor-opacity-"));
writeFileSync(join(dir, "index.html"), `<!doctype html>
<html><head><meta charset="utf-8"><meta name="native-window" content="width=360, height=280">
<style>
body { margin: 0; background: #060607; color: #f4f2ee; font: 20px/1.3 sans-serif; }
#masked { position: absolute; left: 16px; top: 16px; width: 260px; height: 160px; overflow: hidden;
  -webkit-mask-image: linear-gradient(180deg, transparent 0, #000 30%, #000 70%, transparent 100%);
  mask-image: linear-gradient(180deg, transparent 0, #000 30%, #000 70%, transparent 100%); }
#fade { position: absolute; left: 8px; top: 20px; width: 220px; padding: 6px; opacity: .45;
  background: #f4f2ee; color: #060607; border-radius: 6px; }
#over { position: absolute; left: 210px; top: 200px; width: 100px; height: 30px; opacity: .5;
  background: #ff3b30; box-shadow: 0 0 16px 6px #6dffb0; }
#over i { position: absolute; left: -30px; top: 6px; width: 40px; height: 18px; background: #2a7cff; }
</style></head><body>
<div id="masked"><div id="fade">a fading group inside a mask</div></div>
<div id="over"><i></i></div>
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
ok("the presented frame holds the masked opacity group", differing === 0,
  `${differing} pixels differ by more than one step, worst ${worst}`);

/** A pixel of the snapshot, from a point in CSS px. */
function pixelAt(x: number, y: number): number[] {
  const at = (Math.round(y * scale) * a.w + Math.round(x * scale)) * 4;
  return [a.rgba[at], a.rgba[at + 1], a.rgba[at + 2]];
}
const background = [6, 6, 7];
function notBackground(c: number[]): boolean {
  return Math.abs(c[0] - background[0]) > 8 || Math.abs(c[1] - background[1]) > 8 ||
    Math.abs(c[2] - background[2]) > 8;
}
// The child hangs 30 px past its group's left edge, at CSS x 180..220, y 206..224.
const child = pixelAt(195, 215);
ok("an overflowing child paints outside the group's border box", child[2] > 80 && child[2] > child[0] + 30,
  `${child}`);
// The shadow spreads past the group's top edge at CSS y 178..200.
ok("a shadow paints outside the group's border box", notBackground(pixelAt(255, 188)), `${pixelAt(255, 188)}`);

if (process.platform === "darwin") {
  const stats = stderr.split("\n").filter((l) => l.startsWith("native: composite chunks="));
  ok("the frames went through the window's compositor", stats.length >= 1, `${stats.length} frames`);
}

if (failed > 0) process.exit(1);
