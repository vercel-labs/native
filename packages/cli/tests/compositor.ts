// Frames where only a transform or an opacity moved update the display list instead of styling,
// laying out and painting the page again. Their pixels must be the full path's: the same frames
// are snapshotted twice, once as the compositor left the display list and once after a full paint,
// and every pixel is compared.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";
import type { Image } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta charset="utf-8"><meta name="native-window" content="width=220, height=140"><style>
html, body { margin: 0; background: #ffffff; font: 12px/1.2 sans-serif; }
#a { position: absolute; left: 10px; top: 10px; width: 60px; height: 40px; background: #dd3333;
     border: 2px solid #333333; border-radius: 6px; box-shadow: 2px 2px 4px #00000066;
     animation: spin 2s linear infinite; }
#b { position: absolute; left: 100px; top: 10px; width: 60px; height: 40px; background: #33aa33;
     animation: fade 2s linear infinite alternate; }
#c { position: absolute; left: 10px; top: 80px; width: 90px; height: 46px; background: #3366cc;
     animation: slide 2s linear infinite; }
#d { position: absolute; left: 6px; top: 6px; width: 36px; height: 24px; background: #ffcc00;
     animation: slide 1s linear infinite alternate; }
#e { position: absolute; left: 110px; top: 80px; color: #111111; }
@keyframes spin { from { transform: rotate(0deg); } to { transform: rotate(360deg); } }
@keyframes slide { from { transform: translate(0px, 0px); } to { transform: translate(18px, 6px); } }
@keyframes fade { from { opacity: 1; } to { opacity: 0.25; } }
</style></head><body>
<div id="a">A</div>
<div id="b">B</div>
<div id="c"><div id="d">D</div></div>
<div id="e">Still</div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `// The page only has CSS animations; the frames come from the run's steps.
`;

const STEPS = "frame 0 | frame 100 | frame 200 | frame 300 | frame 400 | frame 500";

const dir = mkdtempSync(join(tmpdir(), "native-compositor-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

function run(steps: string, snapshot: string | null): string {
  const env: Record<string, string> = { ...process.env } as Record<string, string>;
  env.NATIVE_STEPS = steps;
  if (snapshot !== null) env.NATIVE_SNAPSHOT = snapshot;
  const r = spawnSync(exe, [], { encoding: "utf8", env });
  if (r.status !== 0) throw new Error(`run failed\n${r.stderr}\n${r.stdout}`);
  return r.stdout;
}

// The full path: the snapshot paints the page as it stands after the same frames.
const refPng = join(dir, "ref.png");
run(STEPS, refPng);
// The compositor path: the display list the last frame presented, with no full paint first.
const fastPng = join(dir, "fast.png");
run(`${STEPS} | snapshotnow ${fastPng}`, null);
const stats = run(`${STEPS} | paintstats`, null).trim();

const ref: Image = decodePng(refPng);
const fast: Image = decodePng(fastPng);

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

check("same size", ref.w === fast.w && ref.h === fast.h, `${fast.w}x${fast.h}, expected ${ref.w}x${ref.h}`);
let diff = -1, diffAt = "";
let count = 0;
for (let i = 0; i < Math.min(ref.rgba.length, fast.rgba.length); i += 4) {
  if (ref.rgba[i] !== fast.rgba[i] || ref.rgba[i + 1] !== fast.rgba[i + 1] ||
      ref.rgba[i + 2] !== fast.rgba[i + 2] || ref.rgba[i + 3] !== fast.rgba[i + 3]) {
    if (diff < 0) {
      diff = i;
      const px = i / 4;
      diffAt = `at ${px % fast.w},${Math.floor(px / fast.w)}: ${ref.rgba[i]},${ref.rgba[i + 1]},${ref.rgba[i + 2]},${ref.rgba[i + 3]}` +
        ` vs ${fast.rgba[i]},${fast.rgba[i + 1]},${fast.rgba[i + 2]},${fast.rgba[i + 3]}`;
    }
    count++;
  }
}
check("composited pixels are the full path's", count === 0, count === 0 ? "" : `${count} px differ, first ${diffAt}`);

// The comparison only means something if the frames took the compositor path: after the opacity
// group is first recorded, the rest did.
const m = /^composited (\d+) fallbacks (\d+)$/.exec(stats);
check("paintstats printed", m !== null, JSON.stringify(stats));
if (m !== null) {
  check("frames used the compositor", Number(m[1]) >= 3, stats);
  // The first frames of the opacity animation legitimately paint the page: the group starts when
  // opacity first drops below 1. A fallback on every frame would mean the fast path never ran.
  check("most frames skipped the paint", Number(m[1]) > Number(m[2]), stats);
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
