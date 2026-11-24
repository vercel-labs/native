// text-emphasis: a mark drawn beside every character, in the emphasis colour, over the text or
// under it. The marks add no advance, so the text measures the same as it does without them.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { inflateSync } from "node:zlib";

interface Image {
  w: number;
  h: number;
  bpp: number;
  rgba: Uint8Array;
}

function decodePng(path: string): Image {
  const b = readFileSync(path);
  let i = 8;
  let w = 0;
  let h = 0;
  let colorType = 0;
  const idat: Buffer[] = [];
  while (i < b.length) {
    const len = b.readUInt32BE(i);
    const type = b.toString("ascii", i + 4, i + 8);
    const data = b.subarray(i + 8, i + 8 + len);
    if (type === "IHDR") {
      w = data.readUInt32BE(0);
      h = data.readUInt32BE(4);
      colorType = data[9];
    }
    if (type === "IDAT") idat.push(data);
    i += 12 + len;
  }
  const bpp = colorType === 6 ? 4 : 3;
  const raw = inflateSync(Buffer.concat(idat));
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
  return { w, h, bpp, rgba: out };
}

// a  no mark                       b  a dot over the text
// c  an open circle in red         d  a triangle under the text
// e  a sesame                      f  a double circle
// g  the shorthand with a colour   h  `filled` alone, which is a dot
// i  `open` alone, which is an open dot   j  a mark under the text, on the left side
// k  none, with the default style named   l  a string mark, which isn't drawn
const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=960"><style>
body { margin: 0; font-size: 40px; color: black; font-family: Helvetica; }
div { width: 400px; height: 80px; line-height: 80px; }
#b { text-emphasis: dot; }
#c { text-emphasis: open circle; text-emphasis-color: red; }
#d { text-emphasis: triangle; text-emphasis-position: under; }
#e { text-emphasis: sesame; }
#f { text-emphasis: double-circle; }
#g { text-emphasis: dot rgb(0, 128, 0); }
#h { text-emphasis-style: filled; }
#i { text-emphasis-style: open; }
#j { text-emphasis: dot; text-emphasis-position: under left; }
#k { text-emphasis-style: none; }
#l { text-emphasis-style: "*"; }
</style></head><body>
<div id="a"><span id="sa">HHHH</span></div>
<div id="b"><span id="sb">HHHH</span></div>
<div id="c"><span id="sc">HHHH</span></div>
<div id="d"><span id="sd">HHHH</span></div>
<div id="e"><span id="se">HHHH</span></div>
<div id="f"><span id="sf">HHHH</span></div>
<div id="g"><span id="sg">HHHH</span></div>
<div id="h"><span id="sh">HHHH</span></div>
<div id="i"><span id="si">HHHH</span></div>
<div id="j"><span id="sj">HHHH</span></div>
<div id="k"><span id="sk">HHHH</span></div>
<div id="l"><span id="sl">HHHH</span></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const box = (id: string) => document.getElementById(id)!;
const style = (id: string) => getComputedStyle(box(id));
requestAnimationFrame(() => {
  requestAnimationFrame(() => {
    const out: string[] = [];
    const rows = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"];
    for (const id of rows) out.push(id + "=" + box(id).getBoundingClientRect().top.toFixed(1));
    for (const id of rows) out.push("s" + id + "w=" + box("s" + id).getBoundingClientRect().width.toFixed(2));
    for (const id of rows) out.push("y" + id + "=" + style(id).textEmphasisStyle);
    for (const id of rows) out.push("c" + id + "=" + style(id).textEmphasisColor);
    for (const id of rows) out.push("p" + id + "=" + style(id).textEmphasisPosition);
    out.push("sh=" + style("g").textEmphasis);
    console.log(out.join("\\n"));
  });
});
`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-emphasis-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const png = join(dir, "out.png");
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png, NATIVE_STEPS: "frame | frame" } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const img = decodePng(png);

const logged: Record<string, string> = {};
for (const line of r.stdout.split("\n")) {
  const m = /^([a-z0-9]+)=(.*)$/.exec(line.trim());
  if (m) logged[m[1]] = m[2];
}
const width = (id: string): number => Number(logged["s" + id + "w"]);

// The snapshot is taken at the display's backing scale, so one CSS pixel is `scale` image pixels.
const scale = img.w / 400;
const ROW = 80;

interface Ink {
  count: number;
  left: number;
  right: number;
  top: number;
  bottom: number;
}

const dark = (r: number, g: number, b: number): boolean => r < 128 && g < 128 && b < 128;
const painted = (r: number, g: number, b: number): boolean => r < 245 || g < 245 || b < 245;

/** The ink of one band of a row, in CSS pixels: anything that isn't the page's white. */
function ink(id: string, y0: number, y1: number, color?: (r: number, g: number, b: number) => boolean): Ink {
  const top = Math.round((Number(logged[id]) + y0) * scale);
  const bottom = Math.round((Number(logged[id]) + y1) * scale);
  const own = color ?? painted;
  let count = 0;
  let left = img.w;
  let right = -1;
  let topmost = -1;
  let bottommost = -1;
  for (let y = top; y < bottom && y < img.h; y++) {
    for (let x = 0; x < img.w; x++) {
      const o = (y * img.w + x) * img.bpp;
      if (!own(img.rgba[o], img.rgba[o + 1], img.rgba[o + 2])) continue;
      count++;
      if (x < left) left = x;
      if (x > right) right = x;
      if (topmost < 0) topmost = y;
      bottommost = y;
    }
  }
  return { count, left: left / scale, right: right / scale, top: topmost / scale, bottom: bottommost / scale };
}

/** The mark above the text: the ink of a row's top quarter, which no letter of HHHH reaches. */
const over = (id: string): Ink => ink(id, 0, ROW / 4);
/** The mark under the text: the ink of a row's bottom quarter, below every baseline here. */
const under = (id: string): Ink => ink(id, (ROW * 3) / 4, ROW);
/** The letters of a row, in their own black. */
const letters = (id: string): Ink => ink(id, ROW / 4, (ROW * 3) / 4, dark);

/** How many marks a row shows above the text: the separate columns of ink there. */
function marks(id: string): number {
  const top = Math.round(Number(logged[id]) * scale);
  const bottom = Math.round((Number(logged[id]) + ROW / 4) * scale);
  let count = 0;
  let inside = false;
  for (let x = 0; x < img.w; x++) {
    let painted = false;
    for (let y = top; y < bottom && y < img.h; y++) {
      const o = (y * img.w + x) * img.bpp;
      if (painted) break;
      if (img.rgba[o] < 245 || img.rgba[o + 1] < 245 || img.rgba[o + 2] < 245) painted = true;
    }
    if (painted && !inside) count++;
    inside = painted;
  }
  return count;
}

const plain = width("a");
// Red paint, including the antialiased edges it fades into white with.
const red = (r: number, g: number, b: number): boolean => r > g + 60 && r > b + 60;

/** The leftmost mark of a row: its box, and whether its centre is painted. A ring's centre isn't. */
function firstMark(id: string): { box: Ink; centrePainted: boolean } {
  const top = Math.round(Number(logged[id]) * scale);
  const bottom = Math.round((Number(logged[id]) + ROW / 4) * scale);
  let left = img.w;
  let right = -1;
  let topmost = -1;
  let bottommost = -1;
  let count = 0;
  // The first mark ends at the first blank column after its ink.
  let start = -1;
  for (let x = 0; x < img.w && start < 0; x++) {
    for (let y = top; y < bottom && y < img.h; y++) {
      const o = (y * img.w + x) * img.bpp;
      if (img.rgba[o] < 245 || img.rgba[o + 1] < 245 || img.rgba[o + 2] < 245) { start = x; break; }
    }
  }
  for (let x = start; x < img.w; x++) {
    let any = false;
    for (let y = top; y < bottom && y < img.h; y++) {
      const o = (y * img.w + x) * img.bpp;
      if (img.rgba[o] >= 245 && img.rgba[o + 1] >= 245 && img.rgba[o + 2] >= 245) continue;
      any = true;
      count++;
      if (x < left) left = x;
      if (x > right) right = x;
      if (topmost < 0) topmost = y;
      bottommost = y;
    }
    if (!any && right >= 0) break;
  }
  const cx = Math.round((left + right) / 2);
  const cy = Math.round((topmost + bottommost) / 2);
  const o = (cy * img.w + cx) * img.bpp;
  const centrePainted = img.rgba[o] < 245 || img.rgba[o + 1] < 245 || img.rgba[o + 2] < 245;
  return {
    box: { count, left: left / scale, right: right / scale, top: topmost / scale, bottom: bottommost / scale },
    centrePainted,
  };
}

check("a mark over the text is drawn, and the text is not",
  over("b").count > 0 && over("a").count === 0,
  `${over("b").count} pixels over row b, ${over("a").count} over row a`);
check("one mark per character", marks("b") === 4, `${marks("b")} marks`);
check("a mark sits clear above the letters",
  over("b").bottom < letters("b").top,
  `the mark ends at ${over("b").bottom.toFixed(1)}px, the letters start at ${letters("b").top.toFixed(1)}px`);
check("a mark over the text is centred on the characters",
  Math.abs((over("b").left + over("b").right) / 2 - (letters("b").left + letters("b").right) / 2) < 6,
  `the marks centre at ${((over("b").left + over("b").right) / 2).toFixed(1)}px, the letters at ${((letters("b").left + letters("b").right) / 2).toFixed(1)}px`);
check("the marks leave the text's advance alone",
  Math.abs(width("b") - plain) < 0.5 && Math.abs(width("d") - plain) < 0.5,
  `${width("b")}px with a mark, ${width("d")}px with one under, ${plain}px plain`);
check("text-emphasis-position: under draws the mark under the letters",
  under("d").count > 0 && over("d").count === 0 && under("d").top > letters("d").bottom,
  `${under("d").count} pixels under row d, the letters end at ${letters("d").bottom.toFixed(1)}px`);
check("the mark is drawn in the emphasis colour",
  ink("c", 0, ROW / 4, red).count >= over("c").count * 0.9,
  `${ink("c", 0, ROW / 4, red).count} red pixels of ${over("c").count} painted`);
check("the shorthand's colour is the one the mark is drawn in",
  ink("g", 0, ROW / 4, (r, g, b) => g > 90 && r < 90 && b < 90).count > 0,
  `${ink("g", 0, ROW / 4, (r, g, b) => g > 90 && r < 90 && b < 90).count} green pixels`);
check("a circle is drawn larger than a dot",
  over("c").right - over("c").left > over("b").right - over("b").left + 2,
  `${(over("c").right - over("c").left).toFixed(1)}px across against ${(over("b").right - over("b").left).toFixed(1)}px`);
check("an open mark is a ring, and a filled one is not",
  !firstMark("c").centrePainted && firstMark("b").centrePainted,
  `the open circle's centre is ${firstMark("c").centrePainted ? "painted" : "clear"}, the dot's is ${firstMark("b").centrePainted ? "painted" : "clear"}`);
check("a double circle covers more than a circle of the same kind",
  over("f").right - over("f").left > over("c").right - over("c").left,
  `${(over("f").right - over("f").left).toFixed(1)}px across against ${(over("c").right - over("c").left).toFixed(1)}px`);
check("a sesame is drawn as a slanted dot, not a circle",
  over("e").count > 0 && over("e").right - over("e").left > over("b").right - over("b").left,
  `${(over("e").right - over("e").left).toFixed(1)}px across`);
check("`filled` alone is a dot", logged.yh === "dot" && over("h").count > 0, logged.yh);
check("`open` alone is an open dot", logged.yi === "open dot" && over("i").count > 0, logged.yi);
check("none draws no mark", logged.yk === "none" && over("k").count === 0, logged.yk);
check("a string mark isn't drawn, and leaves the text bare",
  logged.yl === "none" && over("l").count === 0, logged.yl);

check("text-emphasis-style computes to the mark it names",
  logged.yb === "dot" && logged.yc === "open circle" && logged.yd === "triangle" &&
  logged.ye === "sesame" && logged.yf === "double-circle",
  [logged.yb, logged.yc, logged.yd, logged.ye, logged.yf].join(", "));
check("text-emphasis-color computes to the current colour when it isn't set",
  logged.ca === "rgb(0, 0, 0)" && logged.cc === "rgb(255, 0, 0)",
  `${logged.ca}, ${logged.cc}`);
check("text-emphasis-position computes to over unless it says otherwise",
  logged.pa === "over" && logged.pd === "under",
  `${logged.pa}, ${logged.pd}`);
check("the side of a position computes only when it is left",
  logged.pj === "under left", logged.pj);
check("the shorthand computes to the mark and the colour, and the position stays as it was",
  logged.sh === "dot rgb(0, 128, 0)", logged.sh);

const notes = b.stderr.split("\n").filter((l) => l.includes("text-emphasis-style"));
check("the build says a string mark isn't drawn yet",
  notes.some((l) => l.includes("isn't drawn yet")), notes.join(" | "));

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
