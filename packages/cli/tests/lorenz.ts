// A local-only smoke check for a real page outside the repository: a Lorenz clock fixture you
// point it at. It builds the fixture headlessly, runs a few frames, and checks the canvas
// actually painted over its background. It isn't part of `npm test`, because the page isn't in
// the repo; run it by hand:
//   node tests/lorenz.ts <app-dir>

import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

const appDir = process.argv[2];
if (!appDir) {
  console.log("usage: node tests/lorenz.ts <app-dir>");
  process.exit(2);
}
if (!existsSync(join(appDir, "index.html"))) {
  console.log(`skip the Lorenz check: no page at ${appDir}`);
  process.exit(0);
}

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-lorenz-"));
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", appDir, "-o", exe], { encoding: "utf8" });
const buildOut = `${build.stdout}${build.stderr}`;
check("the fixture builds", build.status === 0, buildOut.split("\n").slice(-6).join("\n"));
// The page links a remote stylesheet; a browser carries on without it, and so does the build.
check("the remote stylesheet is a warning, not an error", /warning: remote stylesheet 'https:\/\//.test(buildOut),
  "no remote-stylesheet warning in the build output");

if (build.status === 0) {
  const png = join(dir, "frame.png");
  // A few animation frames, so the clock has drawn rather than only sized its canvas.
  const steps = "frame 0 | frame 100 | frame 500";
  const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_SNAPSHOT: png, NATIVE_STEPS: steps, NATIVE_STORAGE: join(dir, "store.json") };
  const run = spawnSync(exe, [], { encoding: "utf8", env });
  check("the page runs headlessly", run.status === 0, run.stderr);

  const img = decodePng(png);
  check("the snapshot is the page's window", img.w > 0 && img.h > 0, `${img.w}x${img.h}`);
  // The page paints a dark background, so anything close to the top-left pixel is background.
  const bg = [img.rgba[0], img.rgba[1], img.rgba[2]];
  let painted = 0;
  for (let i = 0; i < img.rgba.length; i += 4) {
    if (Math.abs(img.rgba[i] - bg[0]) + Math.abs(img.rgba[i + 1] - bg[1]) + Math.abs(img.rgba[i + 2] - bg[2]) > 24) painted++;
  }
  check("the canvas painted over its background", painted > 1000, `${painted} pixels differ from ${bg.join(",")}`);
  check("the page's background is dark at the top left", bg[0] + bg[1] + bg[2] < 120, `top left is ${bg.join(",")}`);
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
