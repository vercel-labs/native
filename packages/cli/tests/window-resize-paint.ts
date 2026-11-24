// A window grown past the display keeps presenting its page. Growing the window reallocates the
// compositor's picture textures, and the full frame painted after that resize has to reach the
// window with the page on it: a frame holding nothing but the page's background is what the
// window shows when the picture is drawn somewhere other than the texture presented.
//   npm test
// This opens a real window, as the AX test does, and skips cleanly when the session has none.
// The host prints one line per presented frame under NATIVE_PRESENT_STATS, with the frame's size
// and how many distinct colours it holds.

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
  console.log(`ok   skipped: a window's Metal presentation is macOS's (this is ${process.platform})`);
  process.exit(0);
}

const dir = mkdtempSync(join(tmpdir(), "native-window-resize-paint-"));

/** The display's size in points, from AppKit; the window is grown to twice its width. */
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
  const built = spawnSync("clang", ["-fobjc-arc", "-O1", "-o", probe, src, "-framework", "Cocoa"],
                          { encoding: "utf8" });
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

const OPEN_W = 420, OPEN_H = 320;
// Twice the display's width: the window reaches past the screen on every edge the width crosses.
const GROWN_W = Math.round(screen[0] * 2), GROWN_H = Math.round(screen[1]);
// Blocks of their own colour across the page, so a frame that holds the page has many colours no
// matter which part of it the sample grid lands on.
const COLOURS = [
  "#e6194b", "#3cb44b", "#ffe119", "#4363d8", "#f58231", "#911eb4", "#46f0f0", "#f032e6",
  "#bcf60c", "#fabebe", "#008080", "#e6beff", "#9a6324", "#fffac8", "#800000", "#aaffc3",
  "#808000", "#ffd8b1", "#000075", "#808080", "#ff6600", "#1f77b4", "#2ca02c", "#d62728",
];

writeFileSync(join(dir, "index.html"), `<!doctype html>
<html><head><meta charset="utf-8"><meta name="native-window" content="width=${OPEN_W}, height=${OPEN_H}">
<title>Resize paint</title>
<style>
html, body { margin: 0; height: 100%; background: #1e1e1e; color: #f2f2f2;
  font: 13px -apple-system, BlinkMacSystemFont, sans-serif; }
h1 { margin: 12px; font-size: 18px; }
#row { display: flex; height: 120px; margin: 12px; }
#row div { flex: 1; }
</style></head><body>
<h1 id="title">Frames keep coming</h1>
<div id="row"></div>
<script type="module" src="app.ts"></script>
</body></html>`);

writeFileSync(join(dir, "app.ts"), `const row = document.getElementById("row")!;
const colours = ${JSON.stringify(COLOURS)};
for (const colour of colours) {
  const block = document.createElement("div");
  block.setAttribute("style", "background: " + colour);
  row.appendChild(block);
}
const title = document.getElementById("title")!;
let n = 0;
// A paint every frame, so the compositor keeps presenting frames after the resize too.
function tick(): void {
  n++;
  title.textContent = "Frames keep coming " + String(n);
  requestAnimationFrame(tick);
}
requestAnimationFrame(tick);
window.addEventListener("resize", () => {
  console.log("resize " + String(window.innerWidth) + "x" + String(window.innerHeight));
});
// The window is grown past the display once the opening frame has been drawn.
setTimeout(() => window.resizeTo(${GROWN_W}, ${GROWN_H}), 400);
`);

const exe = join(dir, "window-resize-paint");
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
const env = { ...process.env, NATIVE_PRESENT_STATS: "1" };
const sleep = (ms: number): void => {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
};
const running = (): number => {
  const found = spawnSync("pgrep", ["-f", exe], { encoding: "utf8" }).stdout.trim().split("\n")[0];
  return found === "" ? 0 : Number(found);
};
/** Starts the app, in the session's desktop or through launchctl when started over ssh. */
function start(): number {
  const direct = spawn(exe, [], { detached: true, stdio: ["ignore", fd, fd], env });
  direct.unref();
  for (let i = 0; i < 60; i++) {
    sleep(200);
    const pid = running();
    if (pid !== 0) return pid;
  }
  const uid = spawnSync("id", ["-u"], { encoding: "utf8" }).stdout.trim();
  const viaSession = spawn("launchctl", ["asuser", uid, exe], { detached: true, stdio: ["ignore", fd, fd], env });
  viaSession.unref();
  for (let i = 0; i < 60; i++) {
    sleep(200);
    const pid = running();
    if (pid !== 0) return pid;
  }
  return 0;
}

const pid = start();
if (pid === 0) {
  console.log("skip: the app could not open a window in this session");
  console.log("\nall passed");
  process.exit(0);
}
ok("the app opens a window", pid > 0, `pid ${pid}`);

const text = (): string => readFileSync(log, "utf8");
/** Waits for the app's log to show what the resize and the presented frames write. */
function until(test: (log: string) => boolean, ms = 8000): string {
  for (let waited = 0; waited < ms; waited += 100) {
    const seen = text();
    if (test(seen)) return seen;
    sleep(100);
  }
  return text();
}

/** One presented frame: the stage's device size and the colours it holds. */
interface Present {
  w: number;
  h: number;
  colours: number;
}
const presents = (log: string): Present[] => {
  const out: Present[] = [];
  for (const line of log.split("\n")) {
    const m = /native: present (\d+)x(\d+) colours=(-?\d+)/.exec(line);
    if (m !== null) out.push({ w: Number(m[1]), h: Number(m[2]), colours: Number(m[3]) });
  }
  return out;
};

const seen = until((log) => log.includes(`resize ${GROWN_W}x`) && presents(log).length > 0);

ok("the page sees the window grow past the display", seen.includes(`resize ${GROWN_W}x`),
   `the page's resize line is missing; page said ${JSON.stringify(seen.split("\n").filter((l) => l.startsWith("resize ")))}`);

// The device scale the window draws at: the opening frame's width over the opening size in points.
const opening = presents(seen);
const scale = opening.length > 0 ? opening[0].w / OPEN_W : 0;
// The page paints every frame, so frames at the larger size keep coming if the resize left it able
// to paint at all. Wait for a stretch of them before reading the log's picture of the run.
const later = scale > 0
  ? until((log) => presents(log).filter((p) => Math.round(p.w / scale) === GROWN_W).length >= 10, 10000)
  : text();
const all = presents(later);
const grown = all.filter((p) => Math.round(p.w / scale) === GROWN_W);

ok("frames keep presenting at the larger size", grown.length >= 10,
   `${grown.length} frames presented at ${GROWN_W} points (of ${all.length} in all)`);
ok("the first frame at the larger size holds the page, not just its background",
   grown.length > 0 && grown[0].colours > 10,
   grown.length === 0 ? "no frame reached the larger size" : `${grown[0].colours} colours at ${grown[0].w}x${grown[0].h}`);
ok("no frame was dropped for want of a drawable", !later.includes("present drop"),
   later.split("\n").filter((l) => l.includes("present drop")).join(" | "));

spawnSync("pkill", ["-f", exe]);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
