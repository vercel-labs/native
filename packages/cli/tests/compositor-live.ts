// The window's own frames against the flat replay, for a page that repaints every frame. Each frame
// changes one row of a long list (adding or removing the boxes it draws, so every command after it
// moves to another index) and a counter painted after the list. The last frame the compositor
// presented must hold every chunk of the paint: the same pixels as the flat snapshot, to the one
// step a composited antialiased edge may round.
//
// On macOS the run composites every frame the way the window does (NATIVE_COMPOSITOR_LIVE=1: the
// window's tile cache, its raster pool and its Metal backend, into a texture), so the snapshot is
// the window's picture rather than a fresh composite. Elsewhere it is the host's composited
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

const ROWS = 60;
const dir = mkdtempSync(join(tmpdir(), "native-compositor-live-"));
writeFileSync(join(dir, "index.html"), `<!doctype html>
<html><head><meta charset="utf-8"><meta name="native-window" content="width=360, height=420">
<style>
body { margin: 0; background: #ffffff; font: 13px/18px sans-serif; color: #1f2937; }
header { height: 28px; padding: 4px 8px; background: #111827; color: #f9fafb; }
#list { height: 300px; overflow: auto; border-bottom: 1px solid #d1d5db; }
.row { padding: 3px 8px; border-bottom: 1px solid #e5e7eb; }
.row:nth-child(odd) { background: #f9fafb; }
.badge { display: inline-block; margin-left: 4px; padding: 0 4px; border-radius: 3px; background: #dbeafe; }
.add { color: #166534; background: #dcfce7; }
.del { color: #991b1b; background: #fee2e2; }
#status { position: absolute; left: 0; right: 0; bottom: 0; height: 22px; padding: 2px 8px; background: #f3f4f6; }
</style></head><body>
<header>Live list</header>
<div id="list"></div>
<div id="status">frames <span id="count">0</span></div>
<script src="app.ts"></script>
</body></html>`);
writeFileSync(join(dir, "app.ts"), `const list = document.getElementById("list")!;
const rows: HTMLElement[] = [];
for (let i = 0; i < ${ROWS}; i++) {
  const row = document.createElement("div");
  row.className = "row " + (i % 3 === 0 ? "add" : i % 3 === 1 ? "del" : "");
  row.textContent = "line " + i + (i % 3 === 0 ? " + added" : i % 3 === 1 ? " - removed" : " context");
  list.appendChild(row);
  rows.push(row);
}
const count = document.getElementById("count")!;
let n = 0;
// One row changes on every frame, and how many boxes it draws with it, so each paint moves the
// commands after it; the counter below the list changes too.
function tick(): void {
  n++;
  const row = rows[(n * 7) % 4];
  while (row.childNodes.length > 1) row.removeChild(row.lastChild!);
  for (let k = 0; k < n % 4; k++) {
    const b = document.createElement("span");
    b.className = "badge";
    b.textContent = "#" + (n + k);
    row.appendChild(b);
  }
  count.textContent = String(n);
  requestAnimationFrame(tick);
}
requestAnimationFrame(tick);
`);

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
// The frame the last step presented, as it went out: no paint after it, so the frame is the one
// that changed a row, which a cache one paint behind would show stale or not at all.
const stderr = runApp({ NATIVE_STEPS: [...steps, `snapshotcomposited ${live}`].join(" | ") });
// The same steps, then the flat replay of the page they left.
runApp({ NATIVE_STEPS: steps.join(" | "), NATIVE_SNAPSHOT: flat });

const a = decodePng(flat);
const b = decodePng(live);
ok("both snapshots have the same size", a.w === b.w && a.h === b.h, `${a.w}x${a.h} vs ${b.w}x${b.h}`);
let differing = 0;
let worst = 0;
let firstAt = "";
let inked = 0;
const n = Math.min(a.rgba.length, b.rgba.length);
for (let i = 0; i < n; i += 4) {
  const d = Math.max(
    Math.abs(a.rgba[i] - b.rgba[i]),
    Math.abs(a.rgba[i + 1] - b.rgba[i + 1]),
    Math.abs(a.rgba[i + 2] - b.rgba[i + 2]),
    Math.abs(a.rgba[i + 3] - b.rgba[i + 3]),
  );
  if (d > 1) {
    differing++;
    if (firstAt === "") firstAt = `${(i / 4) % a.w},${Math.floor(i / 4 / a.w)}`;
  }
  if (d > worst) worst = d;
  if (a.rgba[i] !== 255 || a.rgba[i + 1] !== 255 || a.rgba[i + 2] !== 255) inked++;
}
ok("the page drew something", inked > 20000, `${inked} pixels are not white`);
ok("the presented frame holds every chunk of the paint", differing === 0,
  `${differing} pixels differ by more than one step, first at ${firstAt}, worst ${worst}`);

if (process.platform === "darwin") {
  // The run took the window's path, and the frames after the first kept most chunks' tiles: a
  // paint that changed one row rasters the chunks it changed, not the page.
  const lines = stderr.split("\n").filter((l) => l.startsWith("native: composite chunks="));
  ok("the frames went through the window's compositor", lines.length >= steps.length, `${lines.length} frames`);
  const last = lines.length > 0 ? lines[lines.length - 1] : "";
  const m = /chunks=(\d+) .*kept=(\d+) rastered=(\d+)/.exec(last);
  ok("the last frame was chunked", m !== null && Number(m[1]) > 0, last);
  if (m !== null) {
    ok("an unchanged chunk keeps its tiles when commands before it move", Number(m[2]) > Number(m[3]), last);
  }
}

if (failed > 0) {
  console.error(`\nthe snapshots are in ${dir}`);
  console.error(`\n${failed} failed`);
  process.exit(1);
}
console.log("\nall passed");
