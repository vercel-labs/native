// A closed <select> opens the picker the runtime draws over the page: the options under their
// group's label, the chosen one highlighted, with the arrows, type-ahead, the pointer, the wheel
// and Escape all driving it. A pick puts the option in the field and sends input then change, as a
// user's choice does; the pixel checks read the painted panel. A list box keeps its rows in the
// page, so a press on a row chooses it as before.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=360"><style>
body { margin: 0; font: 13px monospace; }
#s { position: absolute; left: 10px; top: 100px; }
#off { position: absolute; left: 10px; top: 200px; }
#box { position: absolute; left: 10px; top: 230px; }
</style></head><body>
<select id="s">
  <option value="a">one</option>
  <optgroup label="group">
    <option value="b" selected>two</option>
    <option value="c" disabled>three</option>
  </optgroup>
  <option value="d">four</option>
  <option value="e">fifth</option>
</select>
<select id="off" disabled><option>only</option></select>
<select id="box" size="3" multiple><option value="x" selected>x</option><option value="y">y</option></select>
<button id="page" style="position:absolute; left:250px; top:300px; width:100px; height:40px">page</button>
<select id="scripted" style="position:absolute; left:200px; top:100px"><option>p</option><option>q</option></select>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function log(s: string): void { console.log(s); }
const s = document.getElementById("s") as HTMLSelectElement;
const off = document.getElementById("off") as HTMLSelectElement;
const box = document.getElementById("box") as HTMLSelectElement;
const page = document.getElementById("page") as HTMLButtonElement;
const scripted = document.getElementById("scripted") as HTMLSelectElement;
s.addEventListener("input", () => log("input " + s.value));
s.addEventListener("change", () => log("change " + s.value));
off.addEventListener("input", () => log("off input"));
off.addEventListener("change", () => log("off change"));
box.addEventListener("input", () => log("box input " + box.value));
box.addEventListener("change", () => log("box change " + box.value));
page.addEventListener("click", () => log("page click"));
s.addEventListener("focus", () => log("focus s"));
box.addEventListener("focus", () => log("focus box"));
// A click a script dispatches carries no gesture, so it must not open a picker.
scripted.click();
window.addEventListener("load", () => {
  const r = s.getBoundingClientRect();
  log("ready " + s.value + " " + off.value + " " + box.selectedIndex);
  log("rect " + Math.round(r.left) + " " + Math.round(r.top) + " " + Math.round(r.width) + " " + Math.round(r.height));
});
`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-select-menu-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

/** Runs the steps and returns the lines the app printed, and its snapshot if asked for. */
function run(steps: string, snapshot = ""): { lines: string[]; rect: number[] } {
  const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: steps };
  const shot = snapshot === "" ? "" : join(dir, snapshot);
  if (shot === "") delete env.NATIVE_SNAPSHOT;
  else env.NATIVE_SNAPSHOT = shot;
  const r = spawnSync(exe, [], { encoding: "utf8", env });
  if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
  const lines = r.stdout.split("\n").slice(0, -1);
  const rectLine = lines.find((l) => l.startsWith("rect "));
  const rect = rectLine === undefined ? [] : rectLine.slice(5).split(" ").map(Number);
  return { lines, rect };
}

function expectLines(name: string, got: string[], want: string[]): void {
  for (const line of got) console.log(`     got ${JSON.stringify(line)}`);
  check(`${name} (${want.length} lines)`, got.length === want.length, `got ${got.length}`);
  for (let i = 0; i < Math.min(got.length, want.length); i++) {
    check(`${name}: ${want[i]}`, got[i] === want[i], `got ${JSON.stringify(got[i])}`);
  }
}

/** The lines a run prints apart from the page's two opening ones. */
function afterReady(lines: string[]): string[] {
  let at = 0;
  while (at < lines.length && !lines[at].startsWith("ready ")) at++;
  return lines.slice(at + 2);
}

// A row of the picker is 20px tall for a 13px font, as Chrome's menulist has it.
const ROW = 20;
const ready = ["ready b only 0"];
const rectAt = (r: number[]): string =>
  `rect ${Math.round(r[0])} ${Math.round(r[1])} ${Math.round(r[2])} ${Math.round(r[3])}`;

// Opening leaves the field alone.
{
  const r = run("click #s | selected #s");
  expectLines("open", r.lines, [...ready, rectAt(r.rect), "focus s", "idx 1 01000"]);
  check("the field is clear of the window's edge", r.rect[1] > 40, `top ${r.rect[1]}`);
}

// A press on a row picks it and closes the panel: the option before the chosen one is two rows up
// from the field's middle, where the chosen row opens.
{
  const r = run("click #s");
  const x = r.rect[0] + 12;
  const y = r.rect[1] + r.rect[3] / 2 - ROW * 2;
  const picked = run(`click #s | clickat ${x} ${y} | selected #s`);
  expectLines("picked by mouse", afterReady(picked.lines), ["focus s", "input a", "change a", "idx 0 10000"]);
}

// A press on a disabled row picks nothing, and the panel stays open for the next press.
{
  const r = run("click #s");
  const x = r.rect[0] + 12;
  const y = r.rect[1] + r.rect[3] / 2 + ROW;
  const tried = run(`click #s | clickat ${x} ${y} | selected #s`);
  expectLines("disabled row", afterReady(tried.lines), ["focus s", "idx 1 01000"]);
}

// A press away from the panel dismisses it and goes no further: the button under it hears nothing.
{
  const r = run("click #s | clickat 300 320 | selected #s");
  expectLines("outside press", afterReady(r.lines), ["focus s", "idx 1 01000"]);
}

// The arrows move the highlight, pass a disabled option over, and put its option in the field.
{
  const r = run("click #s | key ArrowDown | selected #s");
  expectLines("arrow", afterReady(r.lines), ["focus s", "input d", "change d", "idx 3 00010"]);
}

// Home and End reach the ends of the list.
{
  const home = run("click #s | key Home | selected #s");
  expectLines("home", afterReady(home.lines), ["focus s", "input a", "change a", "idx 0 10000"]);
  const end = run("click #s | key End | selected #s");
  expectLines("end", afterReady(end.lines), ["focus s", "input e", "change e", "idx 4 00001"]);
}

// Type-ahead moves the highlight as the letters narrow the search.
{
  const r = run("click #s | type f | type i | selected #s");
  expectLines("type-ahead", afterReady(r.lines), ["focus s", "input d", "change d", "input e", "change e", "idx 4 00001"]);
}

// Enter picks the highlight and closes the panel; a second arrow then opens a fresh one from the
// field's new choice, which is where the highlight starts.
{
  const r = run("click #s | key ArrowDown | key Enter | selected #s");
  expectLines("enter closes", afterReady(r.lines), ["focus s", "input d", "change d", "idx 3 00010"]);
}

// Escape closes the panel and keeps the choice already made; the next arrow opens a new panel
// without moving the field.
{
  const r = run("click #s | key ArrowDown | key Escape | key ArrowUp | selected #s");
  expectLines("escape", afterReady(r.lines), ["focus s", "input d", "change d", "idx 3 00010"]);
}

// Tab closes the panel and moves focus on.
{
  const r = run("click #s | key Tab | selected #s");
  expectLines("tab", afterReady(r.lines), ["focus s", "focus box", "idx 1 01000"]);
}

// A disabled field never opens.
{
  const r = run("click #off | selected #off");
  expectLines("disabled field", afterReady(r.lines), ["idx 0 1"]);
}

// A list box keeps choosing rows in the page.
{
  const r = run("clickat 15 235 | key ArrowDown | selected #box");
  expectLines("list box", afterReady(r.lines), ["focus box", "box input y", "box change y", "idx 1 01"]);
}

// --- the panel's pixels -----------------------------------------------------

/** A pixel of the snapshot at a CSS point: the snapshot draws at twice the CSS size. */
function pixel(im: { rgba: Uint8Array; w: number }, x: number, y: number): number[] {
  const i = (Math.round(y * 2) * im.w + Math.round(x * 2)) * 4;
  return [im.rgba[i], im.rgba[i + 1], im.rgba[i + 2]];
}

function luminance(c: number[]): number {
  return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
}

/** The darkest pixel in a stretch of the snapshot, in CSS coordinates. */
function darkest(im: { rgba: Uint8Array; w: number; h: number }, x0: number, y0: number, x1: number, y1: number): number {
  let dark = 255;
  for (let y = Math.round(y0 * 2); y < Math.round(y1 * 2); y++) {
    for (let x = Math.round(x0 * 2); x < Math.round(x1 * 2); x++) {
      const i = (y * im.w + x) * 4;
      const lum = 0.2126 * im.rgba[i] + 0.7152 * im.rgba[i + 1] + 0.0722 * im.rgba[i + 2];
      if (lum < dark) dark = lum;
    }
  }
  return dark;
}

/** How many pixels of a stretch of the snapshot are the accent colour, in CSS coordinates. */
function accentPixels(im: { rgba: Uint8Array; w: number; h: number }, x0: number, y0: number, x1: number, y1: number): number {
  let n = 0;
  for (let y = Math.round(y0 * 2); y < Math.round(y1 * 2); y++) {
    for (let x = Math.round(x0 * 2); x < Math.round(x1 * 2); x++) {
      const i = (y * im.w + x) * 4;
      if (im.rgba[i] < 20 && im.rgba[i + 1] > 90 && im.rgba[i + 1] < 140 && im.rgba[i + 2] > 220) n++;
    }
  }
  return n;
}

{
  const r = run("click #s", "open.png");
  const im = decodePng(join(dir, "open.png"));
  const left = r.rect[0];
  const mid = r.rect[1] + r.rect[3] / 2;
  // The rows a picker draws, from the chosen one up and down: the option before the chosen one,
  // the group's label, then the chosen row, then the disabled option under it.
  const option = darkest(im, left + 5, mid - ROW * 2.5, left + 60, mid - ROW * 1.5);
  const group = darkest(im, left + 5, mid - ROW * 1.5, left + 60, mid - ROW / 2);
  const off = darkest(im, left + 5, mid + ROW / 2, left + 60, mid + ROW * 1.5);
  const lit = pixel(im, left + 50, mid);
  check("the chosen row is painted in the accent colour", lit[0] < 30 && lit[1] > 100 && lit[1] < 135 && lit[2] > 230,
    `rgb ${lit.join(",")}`);
  check("an option's text is the field's ink", option < 60, `darkest ${option.toFixed(0)}`);
  check("a group's label is painted grey", group > 70 && group < 140, `darkest ${group.toFixed(0)}`);
  check("a disabled option is painted grey", off > 100 && off < 190, `darkest ${off.toFixed(0)}`);
}

{
  // Tab moves focus off the field, so the panel's place holds nothing but the page after Escape.
  const r = run("click #s | key Escape | key Tab", "closed.png");
  const im = decodePng(join(dir, "closed.png"));
  const left = r.rect[0];
  const top = r.rect[1];
  const left1 = accentPixels(im, left - 4, top - 40, left + 80, top + 100);
  check("Escape takes the panel away", left1 === 0, `${left1} accent pixels left`);
  // The field a script clicked sits across the page from the one the pointer opened, and carries
  // no panel of its own.
  const scripted = accentPixels(im, 190, 60, 280, 180);
  check("a script's click() opens nothing", scripted === 0, `${scripted} accent pixels`);
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
