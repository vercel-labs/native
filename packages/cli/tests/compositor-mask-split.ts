// A mask the compositor splits into its image and its content (a linear-gradient mask over a
// clipped column of fading, blurred lines) presents the same frame as the whole-mask replay, down
// to the pixel. The comparison runs the window's own compositor on macOS (NATIVE_COMPOSITOR_LIVE)
// with the split on and with NATIVE_MASK_SPLIT=0, which keeps the mask whole.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

let failed = 0;
function ok(name: string, cond: boolean, detail = ""): void {
  if (!cond) failed++;
  console.log(`${cond ? "ok  " : "FAIL"} ${name}${cond || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-compositor-mask-split-"));
writeFileSync(join(dir, "index.html"), `<!doctype html>
<html><head><meta charset="utf-8"><meta name="native-window" content="width=360, height=300">
<style>
body { margin: 0; background: #060607; }
#col { position: absolute; left: 20px; top: 20px; width: 320px; height: 240px; overflow: hidden;
  -webkit-mask-image: linear-gradient(180deg, transparent 0, #000 22%, #000 78%, transparent 100%);
  mask-image: linear-gradient(180deg, transparent 0, #000 22%, #000 78%, transparent 100%); }
#lines { position: absolute; left: 0; top: 0; width: 320px; will-change: transform; }
#lines p { margin: 0; padding: 8px 0; font-family: system-ui, sans-serif; font-size: 22px;
  line-height: 1.15; color: #fff; will-change: filter, opacity; }
#lines p:nth-child(1) { opacity: .34; }
#lines p:nth-child(2) { opacity: .68; filter: blur(2px); }
#lines p:nth-child(3) { filter: blur(1px); }
</style></head><body>
<div id="col"><div id="lines">
  <p>one line of the chorus</p>
  <p>another line of it</p>
  <p>a third line here</p>
  <p>and a fourth one</p>
</div></div>
<script>
  // Frames move the column, so the content's chunks are rastered and then kept.
  let y = 0;
  requestAnimationFrame(function step() {
    y += 3;
    document.getElementById("lines").style.transform = "translateY(" + y + "px)";
    requestAnimationFrame(step);
  });
</script>
</body></html>`);

const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) {
  console.error(build.stderr);
  process.exit(1);
}

const steps: string[] = [];
for (let i = 1; i <= 20; i++) steps.push(`frame ${i * 16}`);
function run(extra: Record<string, string>): string {
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

const whole = join(dir, "whole.png");
const split = join(dir, "split.png");
const wholeOut = run({ NATIVE_STEPS: [...steps, `snapshotcomposited ${whole}`].join(" | "), NATIVE_MASK_SPLIT: "0" });
const splitOut = run({ NATIVE_STEPS: [...steps, `snapshotcomposited ${split}`].join(" | "), NATIVE_MASK_SPLIT: "1" });

const a = readFileSync(whole);
const b = readFileSync(split);
ok("both runs presented a frame", a.length > 0 && b.length > 0, `${a.length} vs ${b.length} bytes`);
ok("the split mask presents the same frame as the whole mask", a.equals(b),
  `${a.length} vs ${b.length} bytes`);

if (process.platform === "darwin") {
  const masks = splitOut.split("\n").filter((l) => l.startsWith("native: composite masks="));
  const chunks = splitOut.split("\n").filter((l) => l.startsWith("native: composite chunks="));
  ok("the split path ran", masks.length >= 1, `${masks.length} frames`);
  ok("the frame went through the window's compositor", chunks.length >= 1, `${chunks.length} frames`);
  const wholeMasks = wholeOut.split("\n").filter((l) => l.startsWith("native: composite masks="));
  ok("the whole-mask run did not split", wholeMasks.length === 0, `${wholeMasks.length} frames`);
}

if (failed > 0) process.exit(1);
