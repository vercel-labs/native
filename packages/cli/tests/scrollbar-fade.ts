// The overlay scrollbar fades about a second after a scroll stops. The fade repaints the box that
// owns the bar, not the page: the frame it lands on is damage-limited, where before the fade asked
// for a full page paint.
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

const dir = mkdtempSync(join(tmpdir(), "native-fade-"));
// A tall list whose rows have no hover styling: after the wheel, the only thing that repaints is
// the bar fading, so the last painted frame is that fade.
writeFileSync(join(dir, "index.html"), `<!doctype html>
<html><head><title>fade</title>
<style>
html, body { margin: 0; background: #ffffff; font: 13px/1.4 system-ui; }
#pane { height: 300px; overflow-y: auto; }
.row { height: 20px; padding: 0 6px; }
</style>
</head><body>
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

const steps = "frame 16 | wheel #pane 300 | frame 16 | wait 1200 | frame 16 | frame 16";

interface Run {
  stderr: string;
}

function run(name: string, env: NodeJS.ProcessEnv): Run {
  const png = join(dir, `${name}.png`);
  const r = spawnSync(exe, [], {
    encoding: "utf8",
    env: { ...process.env, NATIVE_FRAME_TIMES: "1", ...env, NATIVE_STEPS: steps, NATIVE_SNAPSHOT: png },
  });
  if (r.status !== 0) {
    console.error(r.stderr);
    process.exit(1);
  }
  return { stderr: String(r.stderr) };
}

const damaged = run("damaged", { NATIVE_DAMAGE_STATS: "1" });

// The last frame that painted after the wheel is the fade. Pair each frame line with the damage
// line endFrame prints after it.
const lines = damaged.stderr.split("\n");
let lastPaintAt = -1;
for (let i = 0; i < lines.length; i++) {
  if (!lines[i].includes("native: frame ")) continue;
  if (!/ paint=[1-9]/.test(lines[i])) continue;
  lastPaintAt = i;
}
let reason = "";
let limited = "";
if (lastPaintAt >= 0) {
  for (let i = lastPaintAt + 1; i < lines.length; i++) {
    const m = /native: damage limited=(\d) rects=(\d+) reason=(\S+)/.exec(lines[i]);
    if (m !== null) {
      limited = m[1];
      reason = m[3];
      break;
    }
  }
}
ok("the fade frame painted", lastPaintAt >= 0);
ok("the last painted frame is the scrollbar fade, and it is damage-limited", limited === "1",
  `limited=${limited || "?"} reason=${reason || "?"}`);

if (failed > 0) {
  console.error(`\n${failed} failed`);
  process.exit(1);
}
console.log("\nall passed");
