// A full paint after a damage-limited frame paints the whole page. The frame that lights one row
// is damage-limited (it repaints that row); the snapshot's own full paint after it used to
// keep that frame's limit and cull the walk to the clicked row, so everything else came out as the
// page background. On a window the same stale limit blanked any full paint that followed a damaged
// frame. The snapshot must match the one the same steps leave with damage-limited painting off.
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

const ROWS = 10;
let rows = "";
for (let i = 0; i < ROWS; i++) rows += `<div class="row" id="r${i}">block ${i}: a line of the article</div>`;
const dir = mkdtempSync(join(tmpdir(), "native-damage-snapshot-"));
writeFileSync(join(dir, "index.html"), `<!doctype html>
<html><head><meta charset="utf-8"><meta name="native-window" content="width=480, height=360"><style>
html, body { margin: 0; height: 100%; background: #fbf8f2; font: 13px/18px sans-serif; color: #222222; }
header { height: 32px; padding: 6px 10px; background: #1f2937; color: #f9fafb; }
#side { position: absolute; left: 0; top: 44px; bottom: 0; width: 110px; background: #efe9df; }
#side div { padding: 4px 8px; }
#article { position: absolute; left: 120px; right: 0; top: 44px; bottom: 0; overflow: auto; }
.row { margin: 4px 8px; padding: 4px 8px; border-radius: 4px; }
.row.on { background: #fde68a; }
</style></head><body>
<header>Notes · the quiet launch</header>
<div id="side"><div>All pages</div><div>Starred</div><div>Release checklist</div><div>Field journal</div></div>
<div id="article">${rows}</div>
<script src="app.ts"></script>
</body></html>`);
writeFileSync(join(dir, "app.ts"), `// One row lights up after the first frames, as a selection moving to it would.
setTimeout(() => document.getElementById("r9")!.classList.add("on"), 100);
`);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) {
  console.error(b.stderr);
  process.exit(1);
}

const steps = "frame 0 | frame 16 | wait 200 | frame 16";
function run(png: string, extra: Record<string, string>): string {
  const r = spawnSync(exe, [], {
    encoding: "utf8",
    env: { ...process.env, NATIVE_STEPS: steps, NATIVE_SNAPSHOT: png, NATIVE_DAMAGE_STATS: "1", NATIVE_FRAME_TIMES: "1", ...extra },
  });
  if (r.status !== 0) {
    console.error(r.stderr);
    process.exit(1);
  }
  return r.stderr;
}
const limitedPng = join(dir, "limited.png");
const fullPng = join(dir, "full.png");
const stderr = run(limitedPng, {});
run(fullPng, { NATIVE_DAMAGE: "0" });

ok("the frame that lights a row is damage-limited", /native: damage limited=1 rects=[1-8] /.test(stderr),
  stderr.split("\n").filter((l) => l.startsWith("native: damage")).join(" / "));
const a = decodePng(fullPng);
const c = decodePng(limitedPng);
ok("both snapshots have the same size", a.w === c.w && a.h === c.h, `${a.w}x${a.h} vs ${c.w}x${c.h}`);
let differing = 0;
for (let i = 0; i < Math.min(a.rgba.length, c.rgba.length); i += 4) {
  const d = Math.max(Math.abs(a.rgba[i] - c.rgba[i]), Math.abs(a.rgba[i + 1] - c.rgba[i + 1]),
    Math.abs(a.rgba[i + 2] - c.rgba[i + 2]), Math.abs(a.rgba[i + 3] - c.rgba[i + 3]));
  if (d > 0) differing++;
}
ok("the snapshot after a damaged frame is the whole page", differing === 0,
  `${differing} pixels differ from the snapshot with damage-limited painting off (in ${dir})`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
