// A live composited run draws a frame with a backdrop filter, and draws it as the replay does.
//
// The live path turned every backdrop frame away before compositing it, on the ground that only
// the replay can answer what is under the box. The compositor can answer it too: it draws the
// page whole as one picture and composites from that. This checks both halves. The live run must
// log a composited frame, and the picture it composites must match the replay the same page
// produces with the compositor off.
//
//   npm test

import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

let failed = 0;
function ok(name: string, cond: boolean, detail = ""): void {
  if (!cond) failed++;
  console.log(`${cond ? "ok  " : "FAIL"} ${name}${cond || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-backdrop-live-"));
writeFileSync(join(dir, "index.html"), `<!doctype html>
<html><head><meta charset="utf-8"><meta name="native-window" content="width=300, height=380">
<style>
html, body { margin: 0; width: 300px; height: 380px; background: #2f6df6; overflow: hidden; }
#mark { position: absolute; left: 60px; top: 45px; width: 34px; height: 34px; background: #ffffff; }
#glass { position: absolute; left: 50px; top: 35px; width: 130px; height: 95px;
  border-radius: 34px; background: rgba(255, 255, 255, 0.05); backdrop-filter: blur(10px); }
#card { position: absolute; left: 40px; top: 190px; width: 200px; height: 120px;
  border-radius: 24px; background: #ffffff; box-shadow: 0 8px 24px rgba(0, 0, 0, 0.35); }
</style></head><body>
<div id="mark"></div><div id="glass"></div><div id="card"></div>
</body></html>`);
writeFileSync(join(dir, "app.ts"), `// A static page: the snapshot is its only frame.
`);

const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) {
  console.error(build.stderr);
  process.exit(1);
}

const live = join(dir, "live.png");
const flat = join(dir, "flat.png");
const steps = "frame 0 | frame 16 | snapshotcomposited ";
// The live run composites the frame; its snapshot is the picture the compositor drew.
const runLive = spawnSync(exe, [], {
  encoding: "utf8",
  env: { ...process.env, NATIVE_COMPOSITOR_LIVE: "1", NATIVE_DAMAGE: "0",
         NATIVE_STEPS: steps + live, NATIVE_FRAME_TIMES: "1" },
});
// The same page with the compositor off: the CoreGraphics replay is the picture to hold it to.
const runFlat = spawnSync(exe, [], {
  encoding: "utf8",
  env: { ...process.env, NATIVE_COMPOSITOR: "0", NATIVE_DAMAGE: "0",
         NATIVE_STEPS: "frame 0 | frame 16", NATIVE_SNAPSHOT: flat },
});
if (runLive.status !== 0 || runFlat.status !== 0) {
  console.error(runLive.stderr || runFlat.stderr);
  process.exit(1);
}

// The frame log is the macOS host's; the composited picture exists on every host, and the
// comparison below is what holds the frame to the replay there.
if (process.platform === "darwin") {
  ok("the live run composited a frame with a backdrop filter",
    /native: composite \d/.test(runLive.stderr || ""),
    (runLive.stderr || "").split("\n").filter((l) => l.includes("native: ")).slice(0, 3).join(" | "));
} else {
  console.log(`ok   skipped: the composited frame log is macOS's (this is ${process.platform})`);
}

if (!existsSync(live) || !existsSync(flat)) {
  ok("both runs wrote a picture", false, `${existsSync(live)} ${existsSync(flat)}`);
  console.log("\n1 failed");
  process.exit(1);
}

const a = decodePng(live);
const b = decodePng(flat);
ok("the two pictures are the same size", a.w === b.w && a.h === b.h, `${a.w}x${a.h} vs ${b.w}x${b.h}`);
if (a.w === b.w && a.h === b.h) {
  let diff = 0, worst = 0;
  const n = a.rgba.length / 4;
  for (let i = 0; i < a.rgba.length; i += 4) {
    const d = Math.max(Math.abs(a.rgba[i] - b.rgba[i]), Math.abs(a.rgba[i + 1] - b.rgba[i + 1]),
                       Math.abs(a.rgba[i + 2] - b.rgba[i + 2]));
    if (d > 2) diff++;
    if (d > worst) worst = d;
  }
  ok("the composited frame is the replay's picture", diff === 0,
    `${diff}/${n} pixels differ by more than 2, worst ${worst}`);
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
