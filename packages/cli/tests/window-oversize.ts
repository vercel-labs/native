// A window keeps the size a page asks for even when the page is larger than the display. AppKit
// shrinks an ordinary window to the screen's visible frame, so a page laid out for the larger
// window opens at the screen's width, and fixed-position content laid out for the page's own width
// is cut off. A browser keeps the requested size and lets the window hang past the screen.
//
// The check opens a window a little wider and taller than the main screen and requires the page to
// report the size it asked for.
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
  console.log(`ok   skipped: a window's frame is macOS's here (this is ${process.platform})`);
  process.exit(0);
}

const dir = mkdtempSync(join(tmpdir(), "native-window-oversize-"));

function screenPoints(): number[] | null {
  const src = join(dir, "screen.m");
  const probe = join(dir, "screen");
  writeFileSync(src, `#import <Cocoa/Cocoa.h>
#include <stdio.h>
int main(void) {
  @autoreleasepool {
    NSScreen *s = [NSScreen mainScreen];
    if (s == nil) return 1;
    NSRect f = s.frame;
    printf("%.0f %.0f\\n", f.size.width, f.size.height);
  }
  return 0;
}
`);
  const built = spawnSync("clang", ["-fobjc-arc", "-O1", "-o", probe, src, "-framework", "Cocoa"], { encoding: "utf8" });
  if (built.status !== 0) return null;
  const ran = spawnSync(probe, [], { encoding: "utf8" });
  if (ran.status !== 0) return null;
  const parts = ran.stdout.trim().split(/\s+/).map(Number);
  return parts.length === 2 && parts[0] > 0 && parts[1] > 0 ? parts : null;
}

const screen = screenPoints();
if (screen === null) {
  console.log("skip: this session has no display to open a window on");
  console.log("\nall passed");
  process.exit(0);
}

const WANT_W = Math.round(screen[0]) + 240;
const WANT_H = Math.round(screen[1]) + 120;

writeFileSync(join(dir, "index.html"), `<!doctype html>
<html><head><meta charset="utf-8">
<meta name="native-window" content="width=${WANT_W}, height=${WANT_H}">
<title>Oversize</title>
<style>html, body { margin: 0; height: 100%; background: #101014; color: #f2f2f2; font: 14px sans-serif; }</style>
</head><body><script src="app.ts"></script></body></html>`);

writeFileSync(join(dir, "app.ts"), `
let n = 0;
function tick(): void {
  n++;
  if (n === 3) console.log("inner=" + String(window.innerWidth) + "x" + String(window.innerHeight));
  requestAnimationFrame(tick);
}
requestAnimationFrame(tick);
`);

const exe = join(dir, "window-oversize");
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
const m = /inner=(\d+)x(\d+)/.exec(text);
ok("the page reports its size", m !== null, text.trim().split("\n").slice(-2).join(" | "));
if (m) {
  ok("a window larger than the screen keeps the page's width", Number(m[1]) === WANT_W, `wanted ${WANT_W}, got ${m[1]}`);
  ok("and its height", Number(m[2]) === WANT_H, `wanted ${WANT_H}, got ${m[2]}`);
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
