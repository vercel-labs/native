// The device pixel ratio is the same on a page's first frame as it is later. A window that isn't
// on a screen yet reports a backing scale of 1, and a page's scripts run before the window is
// shown: a page that sizes a canvas from devicePixelRatio at load made a 1x canvas on a Retina
// display, and the frames after the window appeared scaled their drawing for 2x.
//
// The check opens a window, records the ratio and a canvas sized from it at load, and requires the
// ratio to be unchanged a few frames later and the canvas to hold as many pixels as the ratio says.
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
  console.log(`ok   skipped: a window's backing scale is macOS's here (this is ${process.platform})`);
  process.exit(0);
}

const dir = mkdtempSync(join(tmpdir(), "native-backing-scale-"));

function hasDisplay(): boolean {
  const src = join(dir, "screen.m");
  const probe = join(dir, "screen");
  writeFileSync(src, `#import <Cocoa/Cocoa.h>
#include <stdio.h>
int main(void) {
  @autoreleasepool {
    NSScreen *s = [NSScreen mainScreen];
    if (s == nil) return 1;
    printf("%.0f %.0f %.0f\\n", s.frame.size.width, s.frame.size.height, s.backingScaleFactor);
  }
  return 0;
}
`);
  const built = spawnSync("clang", ["-fobjc-arc", "-O1", "-o", probe, src, "-framework", "Cocoa"], { encoding: "utf8" });
  return built.status === 0 && spawnSync(probe, [], { encoding: "utf8" }).status === 0;
}

if (!hasDisplay()) {
  console.log("skip: this session has no display to open a window on");
  console.log("\nall passed");
  process.exit(0);
}

writeFileSync(join(dir, "index.html"), `<!doctype html>
<html><head><meta charset="utf-8">
<meta name="native-window" content="width=420, height=320">
<title>Backing scale</title>
<style>html, body { margin: 0; height: 100%; background: #101014; }</style>
</head><body><script src="app.ts"></script></body></html>`);

writeFileSync(join(dir, "app.ts"), `
// What a page does at load: read the ratio and size a canvas from it.
const loadRatio = window.devicePixelRatio;
const canvas = document.createElement("canvas") as HTMLCanvasElement;
canvas.width = Math.round(window.innerWidth * loadRatio);
canvas.height = Math.round(window.innerHeight * loadRatio);
let n = 0;
function tick(): void {
  n++;
  if (n === 4) {
    console.log("load=" + String(loadRatio));
    console.log("later=" + String(window.devicePixelRatio));
    console.log("canvas=" + String(canvas.width) + "x" + String(canvas.height));
    console.log("inner=" + String(window.innerWidth) + "x" + String(window.innerHeight));
  }
  requestAnimationFrame(tick);
}
requestAnimationFrame(tick);
`);

const exe = join(dir, "backing-scale");
const built = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (built.status !== 0) {
  console.error(built.stderr);
  console.log("FAIL the app builds");
  console.log("\n1 failed");
  process.exit(1);
}
ok("the app builds", true);

const log = join(dir, "app.log");
const fd = openSync(log, "w");
const sleep = (ms: number): void => {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
};
const running = (): number => {
  const found = spawnSync("pgrep", ["-f", exe], { encoding: "utf8" }).stdout.trim().split("\n")[0];
  return found === "" ? 0 : Number(found);
};
function start(): number {
  spawn(exe, [], { detached: true, stdio: ["ignore", fd, fd], env: process.env });
  for (let i = 0; i < 30; i++) {
    sleep(200);
    const pid = running();
    if (pid !== 0) return pid;
  }
  const uid = spawnSync("id", ["-u"], { encoding: "utf8" }).stdout.trim();
  spawn("launchctl", ["asuser", uid, exe], { detached: true, stdio: ["ignore", fd, fd], env: process.env });
  for (let i = 0; i < 30; i++) {
    sleep(200);
    const pid = running();
    if (pid !== 0) return pid;
  }
  return 0;
}

const pid = start();
if (pid === 0) {
  console.log("skip: the app did not open a window in this session");
  console.log("\nall passed");
  process.exit(0);
}
sleep(1500);
spawnSync("kill", [String(pid)]);
sleep(200);

const text = readFileSync(log, "utf8");
const pick = (k: string): string | null => {
  const m = new RegExp(`^${k}=(.+)$`, "m").exec(text);
  return m ? m[1] : null;
};
const load = pick("load"), later = pick("later"), canvas = pick("canvas"), inner = pick("inner");
ok("the page reports its ratio at load and later", load !== null && later !== null && inner !== null,
  text.trim().split("\n").slice(-4).join(" | "));
if (load !== null && later !== null && canvas !== null && inner !== null) {
  ok("the ratio at load is the ratio later", load === later, `load ${load}, later ${later}`);
  const [iw] = inner.split("x").map(Number);
  const [cw] = canvas.split("x").map(Number);
  ok("a canvas sized at load holds the pixels the ratio says", cw === Math.round(iw * Number(later)),
    `canvas ${canvas}, ${iw} css px at ${later}`);
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
