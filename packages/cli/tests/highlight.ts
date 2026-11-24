// The Custom Highlight API: the Highlight class and the registry a page reads as
// CSS.highlights. Painting ::highlight() rules comes with the painter; this is the API itself.
//   npm test

import { spawnSync } from "node:child_process";
import { decodePng } from "./png.ts";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=120"><style>
body { margin: 0; font: 20px monospace; }
</style></head><body>
<p id="p">Hello <b id="b">brave</b> world</p>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const log = (s: string): void => { console.log(s); };

const p = document.getElementById("p") as HTMLElement;
const t = p.firstChild as Text;
const r = document.createRange();
r.setStart(t, 0);
r.setEnd(t, 5);
const t2 = p.lastChild as Text;
const other = document.createRange();
other.setStart(t2, 1);
other.setEnd(t2, 6);

const hl = new Highlight();
log("empty " + hl.size + " " + hl.type + " " + hl.priority);
hl.add(r);
hl.add(other);
log("added " + hl.size + " " + hl.has(r) + " " + hl.has(other));
hl.priority = 2;
log("priority " + hl.priority);
hl.delete(r);
log("deleted " + hl.size + " " + hl.has(r) + " " + hl.has(other));

// A text node stands for a range covering all of its text.
const wordy = new Highlight(t);
log("text " + wordy.size);

// A highlight loops and spreads as a set does.
const both = new Highlight(r, other);
let seen = 0;
for (const range of both) seen += range.toString() === "" ? 0 : 1;
log("loop " + seen + " spread " + [...both].length);

CSS.highlights.set("mark", hl);
CSS.highlights.set("note", wordy);
log("reg " + CSS.highlights.size + " " + CSS.highlights.has("mark") + " " +
  String(CSS.highlights.get("note") === wordy) + " " + String(CSS.highlights.get("missing") === undefined));
log("keys " + CSS.highlights.keys().join(","));
let pairs = 0;
for (const entry of CSS.highlights) if (entry[0] !== "") pairs++;
log("pairs " + pairs);
CSS.highlights.set("mark", wordy);
log("replace " + CSS.highlights.size + " " + String(CSS.highlights.get("mark") === wordy));
log("delete " + CSS.highlights.delete("mark") + " " + CSS.highlights.size + " " +
  CSS.highlights.delete("mark"));

// A name that can't name a highlight throws, since ::highlight() couldn't reach it.
try {
  CSS.highlights.set("1bad", hl);
  log("digit accepted");
} catch (e) {
  log("digit rejected " + (String(e).indexOf("SyntaxError") >= 0));
}
try {
  CSS.highlights.set("initial", hl);
  log("reserved accepted");
} catch (e) {
  log("reserved rejected " + (String(e).indexOf("SyntaxError") >= 0));
}
CSS.highlights.set("-dash-name", hl);
CSS.highlights.clear();
log("cleared " + CSS.highlights.size);
`;

const EXPECTED_LOG = [
  "empty 0 highlight 0",
  "added 2 true true",
  "priority 2",
  "deleted 1 false true",
  "text 1",
  "loop 2 spread 2",
  "reg 2 true true true",
  "keys mark,note",
  "pairs 2",
  "replace 2 true",
  "delete true 1 false",
  "digit rejected true",
  "reserved rejected true",
  "cleared 0",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-highlight-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame" } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);

const got = r.stdout.split("\n").slice(0, -1);
const want = EXPECTED_LOG;
check(`log lines (${want.length})`, got.length === want.length,
  `got ${got.length}: ${JSON.stringify(got.slice(want.length))}`);
const n = Math.min(got.length, want.length);
for (let i = 0; i < n; i++) check(want[i], got[i] === want[i], `got ${JSON.stringify(got[i])}`);

// A ::highlight() rule paints the ranges a page registers: its background behind them and the
// glyphs in its own colour.
const PAINT_PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=40"><style>
body { margin: 0; font: 20px monospace; }
p { margin: 0; }
::highlight(mark) { background-color: rgb(0, 128, 0); color: rgb(255, 0, 0); }
</style></head><body><p id="p">Hello <b>world</b></p>
<script src="paint.ts"></script>
</body></html>`;

const PAINT_SCRIPT = `
const p = document.getElementById("p") as HTMLElement;
const t = p.firstChild as Text;
const r = document.createRange();
r.setStart(t, 0);
r.setEnd(t, 5);
CSS.highlights.set("mark", new Highlight(r));
console.log("registered " + CSS.highlights.size);
`;

const paintDir = mkdtempSync(join(tmpdir(), "native-highlight-paint-"));
writeFileSync(join(paintDir, "index.html"), PAINT_PAGE);
writeFileSync(join(paintDir, "paint.ts"), PAINT_SCRIPT);
const paintExe = join(paintDir, "app");
const pb = spawnSync("node", ["compiler/cli.ts", "build", paintDir, "-o", paintExe], { encoding: "utf8" });
if (pb.status !== 0) throw new Error(`build failed\n${pb.stderr}`);
const png = join(paintDir, "out.png");
const pr = spawnSync(paintExe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png, NATIVE_STEPS: "frame" } });
if (pr.status !== 0) throw new Error(`render failed\n${pr.stderr}`);
check("a page registers a highlight while it runs", pr.stdout.indexOf("registered 1") >= 0, JSON.stringify(pr.stdout));

const shot = decodePng(png);
const at = (x: number, y: number): number[] => {
  const o = (Math.round(y * 2) * shot.w + Math.round(x * 2)) * 4;
  return [shot.rgba[o], shot.rgba[o + 1], shot.rgba[o + 2]];
};
let green = 0, red = 0, black = 0;
for (let y = 0; y < 22; y++) for (let x = 0; x < 300; x++) {
  const [r, g, b] = at(x, y);
  if (g > 90 && r < 60 && b < 60) green++;
  else if (r > 200 && g < 60 && b < 60) red++;
  else if (r < 40 && g < 40 && b < 40) black++;
}
check("::highlight paints its background", green >= 40, `${green} green pixels`);
check("::highlight paints the text in its own colour", red >= 8, `${red} red pixels`);
check("text outside the highlight keeps its own colour", black >= 8, `${black} black pixels`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
