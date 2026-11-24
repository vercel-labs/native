// The canvas example: a fixed, full-window canvas draws with the 2D API, animates on
// requestAnimationFrame, follows the window's size and the reduced-motion preference, and cycles
// its mode on a key or a click, remembering the mode in localStorage. Pixel checks are in CSS
// pixels; the snapshot is 2 device px per CSS px.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";
import type { Image } from "./png.ts";

const dir = mkdtempSync(join(tmpdir(), "native-canvas-"));
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", "../../examples/canvas", "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

interface Run {
  out: string[];
  img: Image;
  storage: string;
}

// Each run gets a storage file of its own unless it passes one in, so a saved mode from an
// earlier run only carries over on purpose. The steps drive the headless clock and input.
function run(name: string, steps: string, opts: { store?: string; reduced?: boolean } = {}): Run {
  const png = join(dir, `${name}.png`);
  const storage = opts.store ?? join(dir, `${name}.json`);
  const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_SNAPSHOT: png, NATIVE_STEPS: steps, NATIVE_STORAGE: storage };
  if (opts.reduced) env.NATIVE_REDUCED_MOTION = "1";
  const r = spawnSync(exe, [], { encoding: "utf8", env });
  if (r.status !== 0) throw new Error(`run ${name} failed\n${r.stderr}`);
  const out = r.stdout.split("\n").map((l) => l.trim()).filter((l) => l !== "");
  return { out, img: decodePng(png), storage };
}

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

function checkPixels(img: Image, checks: [string, number, number, string][]): void {
  for (const [name, cx, cy, want] of checks) {
    const o = (cy * 2 * img.w + cx * 2) * 4;
    const got = `${img.rgba[o]},${img.rgba[o + 1]},${img.rgba[o + 2]}`;
    check(name, got === want, `got ${got}, want ${want}`);
  }
}

// The canvas is a bitmap of its own that the host draws, so a sample on a stroke's edge or in the
// middle of a glow lands a little differently in each rasterizer. The samples the two hosts
// disagree on record what CoreGraphics draws on macOS and what Cairo draws on Linux.
function pixel(macos: string, linux: string): string {
  return process.platform === "darwin" ? macos : linux;
}

function same(a: Image, b: Image): boolean {
  if (a.w !== b.w || a.h !== b.h) return false;
  for (let i = 0; i < a.rgba.length; i++) if (a.rgba[i] !== b.rgba[i]) return false;
  return true;
}

function saveValue(run: Run): string {
  try {
    return readFileSync(run.storage, "utf8");
  } catch {
    return "";
  }
}

// --- Orbits, the mode with nothing saved ---------------------------------------------------

const orbits = run("orbits", "frame 0 | frame 1000 | print #mode");
check("with nothing saved the example starts in orbits", orbits.out.join("|") === "ORBITS", `got ${JSON.stringify(orbits.out)}`);
checkPixels(orbits.img, [
  ["the background fills the window", 4, 4, "7,11,22"],
  ["the sun sits at the centre of the window", 440, 270, "255,245,214"],
  // The glow is a radial gradient from rgba(255, 236, 190, 0.85) to transparent, painted with
  // "lighter". Chromium draws 42,44,48 here; a host that hands CoreGraphics premultiplied stops
  // paints 37,39,44, the stop's alpha applied twice.
  ["the additive glow lightens the night sky", 440, 170, pixel("42,44,48", "42,43,48")],
  ["an orbit ring is stroked around the sun", 636, 270, "16,25,37"],
]);

// The HUD is HTML, placed by `inset: auto auto max(18px, env(…)) max(18px, env(…))`. Its text is
// the only bright thing near the bottom of the window, so it finds the box.
function hudBottom(img: Image, fromY: number): { x0: number; x1: number; y0: number; y1: number } {
  let x0 = Infinity, x1 = -1, y0 = Infinity, y1 = -1;
  for (let y = fromY * 2; y < img.h; y++) {
    for (let x = 0; x < img.w; x++) {
      const i = (y * img.w + x) * 4;
      if (img.rgba[i + 1] < 100 || img.rgba[i + 2] < 100) continue;
      if (x < x0) x0 = x;
      if (x > x1) x1 = x;
      if (y < y0) y0 = y;
      if (y > y1) y1 = y;
    }
  }
  return { x0: x0 / 2, x1: x1 / 2, y0: y0 / 2, y1: y1 / 2 };
}

const hud = hudBottom(orbits.img, 505);
check("the HUD is inset 18px from the bottom left (inset, max, env)", hud.x0 >= 15 && hud.x0 < 30 && hud.y0 >= 520 && hud.y1 <= 545,
  `bbox x ${hud.x0}..${hud.x1} y ${hud.y0}..${hud.y1}`);
check("the HUD stays inside the window", hud.x1 < 440, `right edge at ${hud.x1}`);

// The mode name is canvas text: fillText with textAlign "center" and textBaseline "middle".
function titleBox(img: Image): { x0: number; x1: number; y0: number; y1: number } {
  let x0 = Infinity, x1 = -1, y0 = Infinity, y1 = -1;
  for (let y = 0; y < 80 * 2; y++) {
    for (let x = 0; x < img.w; x++) {
      const i = (y * img.w + x) * 4;
      if (img.rgba[i + 1] < 150 || img.rgba[i + 2] < 150) continue;
      if (x < x0) x0 = x;
      if (x > x1) x1 = x;
      if (y < y0) y0 = y;
      if (y > y1) y1 = y;
    }
  }
  return { x0: x0 / 2, x1: x1 / 2, y0: y0 / 2, y1: y1 / 2 };
}

function titleCentred(img: Image, centreX: number): boolean {
  const t = titleBox(img);
  return t.x1 > t.x0 && Math.abs((t.x0 + t.x1) / 2 - centreX) <= 4 && t.y0 >= 34 && t.y1 <= 56;
}

check("the mode name is drawn centred at the top of the canvas", titleCentred(orbits.img, 440), `bbox ${JSON.stringify(titleBox(orbits.img))}`);

// --- A click cycles the mode, and localStorage keeps it ------------------------------------

const spiral = run("spiral", "frame 0 | frame 1000 | click #stage | print #mode");
check("a click switches to the next mode", spiral.out.join("|") === "SPIRAL", `got ${JSON.stringify(spiral.out)}`);
check("the mode is saved in localStorage", saveValue(spiral) === `{"phases.mode":"1"}`, `got ${saveValue(spiral)}`);
checkPixels(spiral.img, [
  ["the spiral starts at the centre of the canvas", 440, 270, pixel("68,114,136", "65,113,135")],
  ["the spiral arm is drawn out at t = 0.1s", 34, 130, pixel("158,72,144", "157,69,145")],
  ["an outer arm is stroked round a turn later", 116, 130, pixel("127,63,144", "126,62,143")],
]);

const kept = run("kept", "frame 0 | frame 1000 | print #mode", { store: spiral.storage });
check("a later run opens in the saved mode", kept.out.join("|") === "SPIRAL", `got ${JSON.stringify(kept.out)}`);
check("the saved mode draws exactly as it did before the save", same(kept.img, spiral.img), "snapshots differ");

// --- Keys, the window listener, and cycling past the last mode -----------------------------

const ripples = run("ripples", "frame 0 | frame 1000 | key Space | key Enter | print #mode");
check("space and enter also cycle the mode", ripples.out.join("|") === "RIPPLES", `got ${JSON.stringify(ripples.out)}`);
check("the key presses save the mode too", saveValue(ripples) === `{"phases.mode":"2"}`, `got ${saveValue(ripples)}`);
checkPixels(ripples.img, [
  ["a ripple ring is stroked a quarter of the way out", 602, 270, pixel("52,92,127", "47,85,118")],
  ["a second ripple ring follows it", 678, 270, pixel("42,67,105", "38,61,97")],
  ["a third ring fades as it travels", 754, 270, pixel("33,47,83", "30,43,78")],
  ["the rings reach the top edge of the window", 602, 1, pixel("26,38,69", "26,37,67")],
]);

const wrapped = run("wrapped", "click #stage | click #stage | click #stage | print #mode");
check("a click after the last mode wraps around", wrapped.out.join("|") === "ORBITS", `got ${JSON.stringify(wrapped.out)}`);
check("the wrapped mode is saved", saveValue(wrapped) === `{"phases.mode":"0"}`, `got ${saveValue(wrapped)}`);

// --- The window resizes, and the canvas follows it -----------------------------------------

const resized = run("resized", "frame 0 | frame 1000 | resize 400 300 | frame 1100");
check("the snapshot is the resized window", resized.img.w === 800 && resized.img.h === 600, `${resized.img.w}x${resized.img.h}`);
checkPixels(resized.img, [
  ["the sun moves to the centre of the smaller window", 200, 140, "255,245,214"],
  ["the rings are re-stroked for the smaller window", 305, 140, "16,25,37"],
  ["the background still fills the window", 396, 296, "7,11,22"],
]);
const smallHud = hudBottom(resized.img, 250);
check("the HUD follows the smaller window's bottom left", smallHud.x0 >= 15 && smallHud.x0 < 30 && smallHud.y0 >= 265 && smallHud.y1 <= 285,
  `bbox x ${smallHud.x0}..${smallHud.x1} y ${smallHud.y0}..${smallHud.y1}`);
check("the mode name is centred again in the smaller window", titleCentred(resized.img, 200), `bbox ${JSON.stringify(titleBox(resized.img))}`);

// --- requestAnimationFrame drives the animation, and reduced motion stops it ---------------

const moving = run("moving", "frame 0 | frame 1000");
const moved = run("moved", "frame 0 | frame 1000 | frame 1100");
check("another frame 100ms later moves the drawing", !same(moving.img, moved.img), "the snapshots are identical");

const still = run("still", "frame 0 | frame 2000", { reduced: true });
const stillLater = run("still-later", "frame 0 | frame 5000", { reduced: true });
check("prefers-reduced-motion holds the drawing still", same(still.img, stillLater.img), "the snapshots differ");

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
