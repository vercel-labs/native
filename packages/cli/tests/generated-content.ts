// Regression tests for CSS generated content: ::before and ::after with string and attr()
// content, the display of the generated box, and how it stays out of the rest of the DOM.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { inflateSync } from "node:zlib";

interface Image {
  w: number;
  h: number;
  rgba: Uint8Array;
}

function decodePng(path: string): Image {
  const b = readFileSync(path);
  let i = 8;
  let w = 0;
  let h = 0;
  const idat: Buffer[] = [];
  while (i < b.length) {
    const len = b.readUInt32BE(i);
    const type = b.toString("ascii", i + 4, i + 8);
    const data = b.subarray(i + 8, i + 8 + len);
    if (type === "IHDR") {
      w = data.readUInt32BE(0);
      h = data.readUInt32BE(4);
    }
    if (type === "IDAT") idat.push(data);
    i += 12 + len;
  }
  const raw = inflateSync(Buffer.concat(idat));
  const bpp = 4;
  const stride = w * bpp + 1;
  const out = new Uint8Array(w * h * bpp);
  let prev = new Uint8Array(w * bpp);
  for (let y = 0; y < h; y++) {
    const filter = raw[y * stride];
    const line = raw.subarray(y * stride + 1, y * stride + 1 + w * bpp);
    const cur = new Uint8Array(w * bpp);
    for (let x = 0; x < w * bpp; x++) {
      const a = x >= bpp ? cur[x - bpp] : 0;
      const up = prev[x];
      const c = x >= bpp ? prev[x - bpp] : 0;
      let v = line[x];
      if (filter === 1) v += a;
      else if (filter === 2) v += up;
      else if (filter === 3) v += (a + up) >> 1;
      else if (filter === 4) {
        const p = a + up - c;
        const pa = Math.abs(p - a);
        const pb = Math.abs(p - up);
        const pc = Math.abs(p - c);
        v += pa <= pb && pa <= pc ? a : pb <= pc ? up : c;
      }
      cur[x] = v & 255;
    }
    out.set(cur, y * w * bpp);
    prev = cur;
  }
  return { w, h, rgba: out };
}

// Every generated box is a 10px square with a background, so the pixels say exactly where it
// went, and which of the rules generated it.
const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=200, height=300"><style>
body { margin: 0; font-family: monospace; font-size: 16px; }
.row { position: absolute; left: 0; width: 200px; }
#a::before { content: "AB"; display: inline-block; width: 10px; height: 10px; background: #ff0000; }
#a::after { content: "CD"; display: inline-block; width: 10px; height: 10px; background: #0000ff; }
#attr::before { content: attr(data-label); display: inline-block; width: 10px; height: 10px; background: #00ff00; }
#none::before { content: none; display: inline-block; width: 10px; height: 10px; background: #ff00ff; }
#blk::before { content: "X"; display: block; height: 10px; background: #ffff00; }
#dyn::before { content: "["; }
#seq::before { content: "|"; }
</style></head><body>
<div class="row" id="a" style="top: 0px"></div>
<div class="row" id="attr" data-label="IG" style="top: 40px"></div>
<div class="row" id="none" style="top: 80px">z</div>
<div class="row" id="blk" style="top: 120px"></div>
<div class="row" id="host" style="top: 160px"></div>
<div class="row" id="seq" style="top: 200px">-</div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const byId = (id: string): HTMLElement => document.getElementById(id) as HTMLElement;

// Generated text is not the element's textContent, and the generated box is not a child.
const a = byId("a");
console.log("a text=[" + a.textContent + "]");
console.log("a children=" + a.childElementCount + " first=" + a.firstElementChild);
console.log("a before content=" + getComputedStyle(a, "::before").content);
console.log("a after content=" + getComputedStyle(a, "::after").content);
console.log("a before display=" + getComputedStyle(a, "::before").display);
console.log("a before color=" + getComputedStyle(a, "::before").color);
console.log("a own content=" + getComputedStyle(a).content);

// attr() reads the originating element, and follows it when the attribute changes.
const attr = byId("attr");
console.log("attr content=" + getComputedStyle(attr, "::before").content);
attr.setAttribute("data-label", "ZZ");
console.log("attr changed=" + getComputedStyle(attr, "::before").content);

// content: none generates no box, so the shorthand's background paints nothing.
const none = byId("none");
console.log("none content=" + getComputedStyle(none, "::before").content + " display=" + getComputedStyle(none, "::before").display);

// A generated box can be a block of its own.
const blk = byId("blk");
console.log("blk display=" + getComputedStyle(blk, "::before").display);

// Elements a script creates match the same rules.
const dyn = document.createElement("span");
dyn.id = "dyn";
dyn.textContent = "t";
byId("host").appendChild(dyn);
console.log("dyn content=" + getComputedStyle(dyn, "::before").content + " text=[" + dyn.textContent + "]");

// Replacing an element's text keeps its generated boxes.
const repl = document.createElement("span");
repl.id = "dyn";
repl.textContent = "one";
byId("host").appendChild(repl);
repl.textContent = "two";
console.log("repl content=" + getComputedStyle(repl, "::before").content + " text=[" + repl.textContent + "]");

// Reading a computed style and then replacing the text must still paint the new text. The
// read settles the style work, so the node the text becomes has to ask for it again. This
// goes last, so nothing else refreshes the style before the frame that snapshots the page.
const seq = byId("seq");
const seqColor = getComputedStyle(a, "::before").getPropertyValue("color");
seq.textContent = "MMMM";
console.log("seq text=[" + seq.textContent + "] color=" + seqColor);
`;

// The same stale-text trap without generated content: a child arriving replaces an element's
// own text with a text node, and the flex container moves that text. The line the element
// painted before must go away with the own text it came from.
const TEXT_PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=200, height=40"><style>
body { margin: 0; font-family: monospace; font-size: 16px; }
#n { display: flex; justify-content: center; width: 200px; height: 20px; background: #ffffff; }
</style></head><body>
<div id="n">XX</div>
<script src="app.ts"></script>
</body></html>`;

const TEXT_SCRIPT = `
const n = document.getElementById("n")!;
n.addEventListener("click", () => {
  const box = document.createElement("div");
  box.style.width = "20px";
  box.style.height = "20px";
  box.style.backgroundColor = "#ff0000";
  n.appendChild(box);
  console.log("n text=[" + n.textContent + "] children=" + n.childElementCount);
});
`;

// Inline-level boxes with no text sit at the top of the row, the same way a real
// inline-block child does. The two boxes of #a are side by side at the left edge; the
// samples stay clear of the generated text painted inside them.
const EXPECTED: [string, number, number, string][] = [
  ["::before paints at the start of the element", 5, 1, "255,0,0"],
  ["::after follows it", 18, 1, "0,0,255"],
  ["attr() content makes a box of its own", 5, 41, "0,255,0"],
  ["content: none generates no box", 150, 85, "255,255,255"],
  ["a block generated box spans the element", 100, 125, "255,255,0"],
];

const EXPECTED_LOG: [string, string][] = [
  ["generated text is not textContent", "a text=[]"],
  ["the generated box is not a child", "a children=0 first=null"],
  ["::before content serializes as a string", 'a before content="AB"'],
  ["::after content serializes as a string", 'a after content="CD"'],
  ["a generated box takes its display from the rule", "a before display=inline-block"],
  ["::before styles apply to the box", "a before color=rgb(0, 0, 0)"],
  ["an element's own content stays normal", "a own content=normal"],
  ["attr() content is read from the element", 'attr content="IG"'],
  ["an attribute change updates the content", 'attr changed="ZZ"'],
  ["content: none hides the box", "none content=none display=none"],
  ["a generated box can be a block", "blk display=block"],
  ["a text update after a style read keeps the value", "seq text=[MMMM] color=rgb(0, 0, 0)"],
  ["a created element gets generated content", 'dyn content="[" text=[t]'],
  ["setting textContent keeps the generated box", 'repl content="[" text=[two]'],
];

function buildAndRun(page = PAGE, script = SCRIPT, steps?: string): { img: Image; out: string } {
  const dir = mkdtempSync(join(tmpdir(), "native-generated-content-"));
  writeFileSync(join(dir, "index.html"), page);
  writeFileSync(join(dir, "app.ts"), script);
  const exe = join(dir, "app");
  const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
  if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
  const png = join(dir, "out.png");
  const env = steps === undefined
    ? { ...process.env, NATIVE_SNAPSHOT: png }
    : { ...process.env, NATIVE_SNAPSHOT: png, NATIVE_STEPS: steps };
  const r = spawnSync(exe, [], { encoding: "utf8", env });
  if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
  return { img: decodePng(png), out: `${r.stdout}${r.stderr}` };
}

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const { img, out } = buildAndRun();
const colorAt = (x: number, y: number): string => {
  const o = (y * img.w + x) * 4;
  return `${img.rgba[o]},${img.rgba[o + 1]},${img.rgba[o + 2]}`;
};
for (const [name, x, y, want] of EXPECTED) {
  // The snapshot is 2 device px per CSS px.
  const got = colorAt(x * 2, y * 2);
  check(name, got === want, `got ${got}, want ${want}`);
}

// The text a script sets after a style read paints in the row, beside the `|` the rule generates.
// The run is sampled whole: one pixel can fall in the gap between a glyph's stems, which depends
// on the font the machine resolves for `monospace`.
let runDark = 0;
let runLeft = 999;
let runRight = -1;
for (let y = 202; y < 216; y++) {
  for (let x = 8; x < 60; x++) {
    const [r, g, b] = colorAt(x * 2, y * 2).split(",").map(Number);
    if (r > 128 || g > 128 || b > 128) continue;
    runDark++;
    runLeft = Math.min(runLeft, x);
    runRight = Math.max(runRight, x);
  }
}
check("text set after a style read still paints", runDark > 100 && runLeft >= 8 && runRight > 40,
  `${runDark} dark pixels, x ${runLeft}..${runRight}`);

const lines = out.split("\n");
EXPECTED_LOG.forEach(([name, want]) => {
  check(name, lines.includes(want), `want line "${want}"`);
});

// An element that takes a child no longer paints its own text, and the flex container then
// centers the text node it became: the left edge of the row must be empty.
const moved = buildAndRun(TEXT_PAGE, TEXT_SCRIPT, "click #n");
const movedAt = (x: number, y: number): string => {
  const o = (y * moved.img.w + x) * 4;
  return `${moved.img.rgba[o]},${moved.img.rgba[o + 1]},${moved.img.rgba[o + 2]}`;
};
// Device rows 0-40 are the first (and only) row; the text now starts at CSS x≈80.
let oldText = 0;
for (let y = 0; y < 40; y++) for (let x = 0; x < 60; x++) if (movedAt(x, y) !== "255,255,255") oldText++;
check("the text line the element no longer owns is gone", oldText === 0, `${oldText} pixels left behind`);
const box = movedAt(110 * 2, 10 * 2);
check("the child that replaced the text paints", box === "255,0,0", `got ${box}, want 255,0,0`);
check("the text becomes a text node", moved.out.split("\n").includes("n text=[XX] children=1"));

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
