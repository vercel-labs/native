// text-decoration's longhands: which lines are drawn, their style, colour, thickness and the
// underline's offset. Every line is painted, so the checks read the rendering; the computed
// values are read through the DOM as well.
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

// Each row is one decoration: a 50px-tall block with a single line of transparent text, so every
// painted pixel is the decoration's own. The last row keeps black text, to show the decoration
// colour is the one it names rather than the text's.
const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=800"><style>
body { margin: 0; font-size: 20px; }
div { width: 200px; height: 50px; line-height: 30px; color: transparent; }
#u { text-decoration: underline; text-decoration-color: red; }
#u6 { text-decoration: underline; text-decoration-color: red; text-decoration-thickness: 6px; }
#o { text-decoration: overline; text-decoration-color: red; }
#lt { text-decoration: line-through; text-decoration-color: red; }
#d { text-decoration: underline dashed; text-decoration-color: red; text-decoration-thickness: 2px; }
#s { text-decoration: underline solid; text-decoration-color: red; text-decoration-thickness: 2px; }
#off { text-decoration: underline; text-decoration-color: red; text-decoration-thickness: 2px; text-underline-offset: 12px; }
#c { text-decoration: underline; text-decoration-color: blue; color: black; }
#db { text-decoration: underline double; text-decoration-color: red; text-decoration-thickness: 6px; }
#dot { text-decoration: underline dotted; text-decoration-color: red; text-decoration-thickness: 2px; }
/* A decoration is drawn over the text of in-flow descendants, but not inside an inline-block, and
   a descendant's own thickness doesn't change the ancestor's line. */
#prop { text-decoration: underline; text-decoration-color: red; }
#prop2 { text-decoration: underline; text-decoration-color: red; }
#thick { text-decoration: underline; text-decoration-color: red; text-decoration-thickness: 2px; }
#thick span { text-decoration-thickness: 8px; }
#nest { text-decoration: underline; text-decoration-color: red; }
#nest span { text-decoration: overline; text-decoration-color: red; }
</style></head><body>
<div id="u">MMMMMM</div>
<div id="u6">MMMMMM</div>
<div id="o">MMMMMM</div>
<div id="lt">MMMMMM</div>
<div id="d">MMMMMM</div>
<div id="s">MMMMMM</div>
<div id="off">MMMMMM</div>
<div id="c">MMMMMM</div>
<div id="db">MMMMMM</div>
<div id="dot">MMMMMM</div>
<div id="prop">MMMM<span id="child">MM</span></div>
<div id="prop2"><span style="display: inline-block">MMMM</span></div>
<div id="thick">MMMM<span>MM</span></div>
<div id="nest">MM<span>MM</span>MMMM</div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const style = (id: string) => getComputedStyle(document.getElementById(id)!);
const d = style("d");
const u = style("u");
const u6 = style("u6");
console.log("line=" + d.textDecorationLine);
console.log("style=" + d.textDecorationStyle);
console.log("dcolor=" + d.textDecorationColor);
console.log("dthick=" + d.textDecorationThickness);
console.log("offset=" + style("off").textUnderlineOffset);
console.log("uthick=" + u.textDecorationThickness);
console.log("ushort=" + u.textDecoration);
console.log("u6short=" + u6.textDecoration);
console.log("dshort=" + d.textDecoration);
console.log("ccolor=" + style("c").textDecorationColor);
console.log("childline=" + getComputedStyle(document.getElementById("child")!).textDecorationLine);
`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-decoration-"));
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

interface Band { top: number; bottom: number; count: number; cols: number }

// The snapshot is taken at the display's backing scale, so one CSS pixel is `scale` image pixels.
const scale = img.w / 400;
const rowTop = (row: number): number => row * 50 * scale;

/** The pixels of one colour in a row's 50px band. */
function band(row: number, hit: (r: number, g: number, bl: number) => boolean): Band {
  const y0 = rowTop(row);
  let top = -1;
  let bottom = -1;
  let count = 0;
  const cols = new Set<number>();
  for (let y = y0; y < y0 + 50 * scale && y < img.h; y++) {
    for (let x = 0; x < img.w; x++) {
      const o = (y * img.w + x) * 4;
      if (!hit(img.rgba[o], img.rgba[o + 1], img.rgba[o + 2])) continue;
      count++;
      cols.add(x);
      if (top < 0) top = y;
      bottom = y;
    }
  }
  return { top, bottom, count, cols: cols.size };
}

const red = (r: number, g: number, bl: number): boolean => r > 170 && g < 90 && bl < 90;
const blue = (r: number, g: number, bl: number): boolean => bl > 170 && r < 90 && g < 90;
const dark = (r: number, g: number, bl: number): boolean => r < 90 && g < 90 && bl < 90;

const u = band(0, red);
const u6 = band(1, red);
const o = band(2, red);
const lt = band(3, red);
const d = band(4, red);
const s = band(5, red);
const off = band(6, red);
const cBlue = band(7, blue);
const cDark = band(7, dark);
const db = band(8, red);
const dot = band(9, red);

/** How many separate line segments (runs of painted rows) a row's band holds. */
function groups(row: number, hit: (r: number, g: number, bl: number) => boolean): number {
  const y0 = rowTop(row);
  let runs = 0;
  let painted = false;
  for (let y = y0; y < y0 + 50 * scale && y < img.h; y++) {
    let thisRow = false;
    for (let x = 0; x < img.w && !thisRow; x++) {
      const o = (y * img.w + x) * 4;
      thisRow = hit(img.rgba[o], img.rgba[o + 1], img.rgba[o + 2]);
    }
    if (thisRow && !painted) runs++;
    painted = thisRow;
  }
  return runs;
}

// Where a line sits inside its own row, in CSS pixels below the row's top edge.
const at = (b: Band, row: number): number => (b.top - rowTop(row)) / scale;
const tall = (b: Band): number => (b.bottom - b.top + 1) / scale;

check("an underline is drawn", u.count > 100, `${u.count} red pixels`);
check("an overline is drawn above the text", o.count > 100 && at(o, 2) < at(lt, 3),
  `overline ${at(o, 2).toFixed(1)}px down, strikeout ${at(lt, 3).toFixed(1)}px`);
check("a line-through sits between the overline and the underline",
  lt.count > 100 && at(o, 2) < at(lt, 3) && at(lt, 3) < at(u, 0),
  `overline ${at(o, 2).toFixed(1)}px, strikeout ${at(lt, 3).toFixed(1)}px, underline ${at(u, 0).toFixed(1)}px`);
check("text-decoration-thickness makes the line thicker",
  tall(u6) >= 6 && tall(u6) > tall(u) * 2,
  `6px is ${tall(u6).toFixed(1)}px tall, auto ${tall(u).toFixed(1)}px`);
check("a dashed line leaves gaps", d.count > 40 && d.count < s.count * 0.75,
  `dashed ${d.count} pixels, solid ${s.count}`);
check("text-underline-offset moves the underline down",
  at(off, 6) >= at(s, 5) + 8,
  `offset underline ${at(off, 6).toFixed(1)}px down, plain ${at(s, 5).toFixed(1)}px`);
check("text-decoration-color paints the line, not the text's colour",
  cBlue.count > 100 && cDark.count > 30, `blue ${cBlue.count}, black ${cDark.count}`);
check("a double line is two lines", db.count > 100 && groups(8, red) === 2, `${groups(8, red)} lines`);
check("a dotted line is dots with gaps",
  dot.count > 40 && dot.count < s.count * 0.75 && groups(9, red) === 1,
  `dotted ${dot.count} pixels in ${groups(9, red)} line, solid ${s.count}`);

check("text-decoration-line computes to its line", logged.line === "underline", logged.line);
check("text-decoration-style computes to its keyword", logged.style === "dashed", logged.style);
check("text-decoration-color computes to the colour", logged.dcolor === "rgb(255, 0, 0)", logged.dcolor);
check("text-decoration-thickness computes to its length", logged.dthick === "2px", logged.dthick);
check("an auto thickness computes to auto", logged.uthick === "auto", logged.uthick);
check("text-underline-offset computes to its length", logged.offset === "12px", logged.offset);
check("the text-decoration shorthand writes its line and colour",
  logged.ushort === "underline rgb(255, 0, 0)", logged.ushort);
check("the shorthand carries its thickness", logged.u6short === "underline 6px rgb(255, 0, 0)", logged.u6short);
check("the shorthand writes line, thickness, style, colour in that order",
  logged.dshort === "underline 2px dashed rgb(255, 0, 0)", logged.dshort);
check("a named decoration colour computes to itself", logged.ccolor === "rgb(0, 0, 255)", logged.ccolor);

const prop = band(10, red);
const prop2 = band(11, red);
const thick = band(12, red);
const nest = band(13, red);

check("a decoration is drawn over the text of a child element",
  Math.abs(prop.cols - u.cols) <= 4, `${prop.cols} columns against ${u.cols}`);
check("a decoration doesn't reach inside an inline-block",
  prop2.count === 0, `${prop2.count} red pixels`);
check("a child's own thickness doesn't change the ancestor's line",
  Math.abs(tall(thick) - 2) < 0.6, `${tall(thick).toFixed(1)}px tall`);
check("a child's own decoration is drawn with the ancestor's",
  groups(13, red) === 2 && nest.cols > 100, `${groups(13, red)} lines over ${nest.cols} columns`);
check("the decoration is not inherited into the computed style",
  logged.childline === "none", logged.childline);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
