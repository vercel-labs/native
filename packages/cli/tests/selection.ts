// The Selection API: a range over the page's text, the selection that holds it, and the text a
// copy takes.
//   npm test

import { spawnSync } from "node:child_process";
import { decodePng } from "./png.ts";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=200"><style>
body { margin: 0; font: 20px monospace; }
</style></head><body>
<div id="a">Hello <b id="b">brave</b> world</div>
<div id="c">second paragraph</div>
<input id="f" value="alpha beta">
<script>
document.addEventListener("pointerup", () => {
  const s2 = document.getSelection()!;
  const an = s2.anchorNode === null ? "null" : s2.anchorNode.nodeName;
  const fn = s2.focusNode === null ? "null" : s2.focusNode.nodeName;
  console.log("pointer=" + JSON.stringify(s2.toString()) + " " + s2.type + " " + an + "@" + s2.anchorOffset + "/" + fn + "@" + s2.focusOffset);
});
const el = document.getElementById("a")!;
const b = document.getElementById("b")!;
const sel = document.getSelection()!;
console.log("empty=" + sel.rangeCount + "," + sel.isCollapsed + "," + sel.type + "," + JSON.stringify(sel.toString()));
// A range over the b element's text.
const r = document.createRange();
r.selectNodeContents(b);
const r2 = (b.firstChild as Text | null);
r.setStart(r2 ?? b, 2);
r.setEnd(r2 ?? b, 5);
console.log("btext=" + JSON.stringify(r.toString()) + " collapsed=" + r.collapsed);
sel.removeAllRanges();
sel.addRange(r);
console.log("sel=" + JSON.stringify(sel.toString()) + " type=" + sel.type + " ranges=" + sel.rangeCount);
console.log("anchor=" + (sel.anchorNode === b || sel.anchorNode === r2));
// A range from inside one element to inside another reads across the boundary.
const ra = document.createRange();
const at = el.firstChild as Text | null;
const ct = document.getElementById("c")!.firstChild as Text | null;
ra.setStart(at ?? el, 6);
ra.setEnd(ct ?? document.getElementById("c")!, 6);
console.log("across=" + JSON.stringify(ra.toString()));
// Everything in the div, and a collapse to a caret.
const all = document.createRange();
all.selectNodeContents(el);
console.log("all=" + JSON.stringify(all.toString()));
sel.collapse(at ?? el, 3);
console.log("caret=" + sel.type + "," + sel.isCollapsed + "," + (sel.anchorOffset === 3));
sel.removeAllRanges();
console.log("cleared=" + sel.rangeCount + "," + sel.type);
// Tab focuses the field and selects its text, so Cmd+C takes the field's own selection.
</script>
</body></html>`;

const EXPECTED: [string, string][] = [
  ["an empty selection has no ranges and no text", 'empty=0,true,None,""'],
  ["a range over part of a text node reads its text", 'btext="ave" collapsed=false'],
  ["the selection reads its range's text", 'sel="ave" type=Range ranges=1'],
  ["the anchor is the range's start", "anchor=true"],
  ["a range across two elements reads between them", 'across="brave world\\nsecond"'],
  ["selectNodeContents covers the whole element", 'all="Hello brave world"'],
  ["a collapsed selection is a caret", "caret=Caret,true,true"],
  ["removing every range empties the selection", "cleared=0,None"],
];

function buildAndShot(steps: string): { w: number; h: number; rgba: Uint8Array } {
  const d = mkdtempSync(join(tmpdir(), "native-selection-shot-"));
  return shoot(d, steps);
}

/**
 * Builds the page in `d` and runs it with `steps`, returning the snapshot and the process. The
 * run keeps its pasteboard in `d/pasteboard`, so a test never touches the user's own clipboard.
 */
function shoot(d: string, steps: string, page = PAGE): { w: number; h: number; rgba: Uint8Array; out: string } {
  writeFileSync(join(d, "index.html"), page);
  const e = join(d, "app");
  const b = spawnSync("node", ["compiler/cli.ts", "build", d, "-o", e], { encoding: "utf8" });
  if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
  const png = join(d, "out.png");
  const r2 = spawnSync(e, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png, NATIVE_STEPS: steps, NATIVE_PASTEBOARD: join(d, "pasteboard") } });
  if (r2.status !== 0) throw new Error(`render failed\n${r2.stderr}`);
  return { ...decodePng(png), out: `${r2.stdout}${r2.stderr}` };
}

const dir = mkdtempSync(join(tmpdir(), "native-selection-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
const r = spawnSync(exe, [], {
  encoding: "utf8",
  env: {
    ...process.env,
    NATIVE_SNAPSHOT: join(dir, "out.png"),
    NATIVE_STEPS: "drag #a 60 0|dblclick #a|tripleclick #c",
  },
});
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}
const lines = r.stdout.split("\n");
for (const [name, want] of EXPECTED) {
  check(name, lines.includes(want), `want line ${JSON.stringify(want)}, got ${JSON.stringify(lines.filter((l) => l.startsWith(want.split("=")[0] + "=")))}`);
}

// A drag over the first paragraph selects some of its text, and a double-click takes the word
// under the pointer. The headless steps drive the pointer.
const pointerLines = lines.filter((l) => l.startsWith("pointer=")).map((l) => l.replace(/ (Range|Caret|None) .*$/, ""));
check("a drag selects text", pointerLines.some((l) => /^pointer="[^"]+"/.test(l)),
  JSON.stringify(pointerLines));
check("a double-click selects a word", pointerLines.some((l) => /^pointer="[A-Za-z]+"$/.test(l)),
  JSON.stringify(pointerLines));
check("a triple-click selects the paragraph", pointerLines.some((l) => /^pointer="second paragraph"$/.test(l)),
  JSON.stringify(pointerLines));

if (failed > 0) console.log(r.stdout + r.stderr);
// The drag left "world" selected, and the last snapshot was taken after the triple-click; ask for
// a picture after a drag on its own instead.
const shot = buildAndShot("drag #a 60 0");
const rgb = (x: number, y: number): number[] => {
  const o = (Math.round(y * 2) * shot.w + Math.round(x * 2)) * 4;
  return [shot.rgba[o], shot.rgba[o + 1], shot.rgba[o + 2]];
};
// A highlight is a colour of its own behind the glyphs, whatever the system's accent colour is:
// count pixels that are neither the white page nor the black text.
let highlight = 0;
for (let y = 0; y < 24; y++) for (let x = 0; x < 240; x++) {
  const p = rgb(x, y);
  const white = p[0] > 240 && p[1] > 240 && p[2] > 240;
  const black = p[0] < 40 && p[1] < 40 && p[2] < 40;
  if (!white && !black) highlight++;
}
check("the selection paints a highlight", highlight >= 40, `${highlight} highlight pixels`);

// Cmd+C puts the selection on the pasteboard. The run's pasteboard is a file of its own.
const copyDir = mkdtempSync(join(tmpdir(), "native-selection-copy-"));
shoot(copyDir, "drag #a 60 0|key Meta+Copy");
let copied = "";
try {
  copied = readFileSync(join(copyDir, "pasteboard"), "utf8");
} catch {
  copied = "";
}
check("Cmd+C copies the selection to the pasteboard",
  copied.trim() !== "" && "Hello brave world".includes(copied.trim()), JSON.stringify(copied));

// Tab focuses the field, which selects its text: Cmd+C then copies the field's own selection.
const fieldDir = mkdtempSync(join(tmpdir(), "native-selection-field-"));
shoot(fieldDir, "key Tab|key Meta+Copy");
let fromField = "";
try {
  fromField = readFileSync(join(fieldDir, "pasteboard"), "utf8");
} catch {
  fromField = "";
}
check("Cmd+C in a field copies the field's selection", fromField.trim() === "alpha beta",
  JSON.stringify(fromField));

// ::selection paints its own colours: the highlight's background, and the selected glyphs. The
// rule sits on body so the paragraph's text takes it by inheritance, as a highlight does in Chrome.
const COLOR_PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=40"><style>
body { margin: 0; font: 20px monospace; }
#a { width: 120px; }
body::selection { background: rgb(255, 0, 0); color: rgb(0, 0, 255); }
</style></head><body><div id="a">Hello world</div></body></html>`;
const colorDir = mkdtempSync(join(tmpdir(), "native-selection-colour-"));
const colourShot = shoot(colorDir, "drag #a 60 0", COLOR_PAGE);
const at = (x: number, y: number): number[] => {
  const o = (Math.round(y * 2) * colourShot.w + Math.round(x * 2)) * 4;
  return [colourShot.rgba[o], colourShot.rgba[o + 1], colourShot.rgba[o + 2]];
};
let red = 0, blue = 0, black = 0;
for (let y = 0; y < 22; y++) for (let x = 0; x < 300; x++) {
  const [r, g, b2] = at(x, y);
  if (r > 200 && g < 60 && b2 < 60) red++;
  else if (b2 > 200 && r < 60 && g < 60) blue++;
  else if (r < 40 && g < 40 && b2 < 40) black++;
}
check("::selection paints its own background", red >= 40, `${red} red pixels`);
check("::selection paints the selected text in its own colour", blue >= 8, `${blue} blue pixels`);
check("text outside the selection keeps its own colour", black >= 8, `${black} black pixels`);

// A ::selection rule that sets only a colour leaves the highlight's background to the element it
// starts from, as Chrome does: the selected text keeps the element's green, and the system's
// highlight colour isn't painted. The sample is the top row of the line, above the glyphs.
const COLOUR_ONLY_PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=40"><style>
body { margin: 0; font: 20px monospace; }
#a { width: 120px; background: rgb(0, 128, 0); color: rgb(255, 255, 255); }
#a::selection { color: rgb(0, 0, 255); }
</style></head><body><div id="a">Hello world</div>
<script>
window.addEventListener("load", function () {
  const a = document.getElementById("a");
  const s = window.getSelection();
  if (a !== null && s !== null) s.selectAllChildren(a);
});
</script></body></html>`;
const onlyDir = mkdtempSync(join(tmpdir(), "native-selection-colour-only-"));
const onlyShot = shoot(onlyDir, "frame 2", COLOUR_ONLY_PAGE);
let greenLine = 0, blueOnly = 0;
for (let x = 5; x <= 115; x++) {
  const o = (2 * onlyShot.w + Math.round(x * 2)) * 4;
  if (onlyShot.rgba[o + 1] > 90 && onlyShot.rgba[o] < 60 && onlyShot.rgba[o + 2] < 60) greenLine++;
}
for (let y = 0; y < 22; y++) for (let x = 0; x < 300; x++) {
  const o = (Math.round(y * 2) * onlyShot.w + Math.round(x * 2)) * 4;
  if (onlyShot.rgba[o + 2] > 200 && onlyShot.rgba[o] < 60 && onlyShot.rgba[o + 1] < 60) blueOnly++;
}
check("a colour-only ::selection keeps the element's background", greenLine >= 90, `${greenLine} green line pixels`);
check("and the selection still paints the text in its colour", blueOnly >= 8, `${blueOnly} blue pixels`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
