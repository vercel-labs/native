// font-synthesis: a family with no bold or italic face may have the host draw one, by painting the
// text heavier or slanting it, and neither changes the advance the text measures — as in a browser.
// `font-synthesis` turns a kind of face off, and off text is painted exactly as the plain face is.
//   npm test

import { spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
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

// The one face of TestSans, a regular Arial: a weight of 700 and an italic style have no face to
// come from, so the host draws them itself. The file is the system's, copied next to the page so
// the build can read it; a machine without it skips the test.
const SRC = "/System/Library/Fonts/Supplemental/Arial.ttf";

// a  the face as it comes        b  a weight the family has no face for, drawn heavier
// c  an italic the family has no face for, drawn slanted
// d  the same weight, with weight synthesis off   e  the same italic, with style synthesis off
// f  the weight with style synthesis off only     g  the italic with weight synthesis off only
// h  weight and italic with style alone allowed   i  every kind named, which is the default
// j  none beside another kind, which is not a value and leaves the default
const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=660"><style>
body { margin: 0; font-size: 40px; color: black; font-family: TestSans; }
div { width: 400px; height: 60px; line-height: 50px; }
@font-face { font-family: TestSans; font-weight: 100 500; src: url("regular.ttf") format("truetype"); }
#a { }
#b { font-weight: 700; }
#c { font-style: italic; }
#d { font-weight: 700; font-synthesis: none; }
#e { font-style: italic; font-synthesis: none; }
#f { font-weight: 700; font-synthesis: style; }
#g { font-style: italic; font-synthesis: weight; }
#h { font-weight: 700; font-style: italic; font-synthesis: style; }
#i { font-weight: 700; font-synthesis: weight style small-caps; }
#j { font-weight: 700; font-synthesis: none weight; }
</style></head><body>
<div id="a"><span id="sa">HHHHHHHH</span></div>
<div id="b"><span id="sb">HHHHHHHH</span></div>
<div id="c"><span id="sc">HHHHHHHH</span></div>
<div id="d"><span id="sd">HHHHHHHH</span></div>
<div id="e"><span id="se">HHHHHHHH</span></div>
<div id="f"><span id="sf">HHHHHHHH</span></div>
<div id="g"><span id="sg">HHHHHHHH</span></div>
<div id="h"><span id="sh">HHHHHHHH</span></div>
<div id="i"><span id="si">HHHHHHHH</span></div>
<div id="j"><span id="sj">HHHHHHHH</span></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const box = (id: string) => document.getElementById(id)!;
const style = (id: string) => getComputedStyle(box(id));
requestAnimationFrame(() => {
  requestAnimationFrame(() => {
    const out: string[] = [];
    const rows = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"];
    for (const id of rows) out.push(id + "=" + box(id).getBoundingClientRect().top.toFixed(1));
    for (const id of rows) out.push("s" + id + "w=" + box("s" + id).getBoundingClientRect().width.toFixed(2));
    for (const id of rows) out.push("y" + id + "=" + style(id).fontSynthesis);
    console.log(out.join("\\n"));
  });
});
`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

if (!existsSync(SRC)) {
  console.log(`ok   synthetic faces need the system fonts (${SRC} isn't here; skipped)`);
  console.log("\nall passed");
  process.exit(0);
}

const dir = mkdtempSync(join(tmpdir(), "native-synthesis-"));
copyFileSync(SRC, join(dir, "regular.ttf"));
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
const dark = (r: number, g: number, bl: number): boolean => r < 90 && g < 90 && bl < 90;

interface Paint {
  left: number;
  right: number;
  count: number;
  /** The leftmost painted column of the top third of the row, and of its bottom third. */
  topLeft: number;
  bottomLeft: number;
}

/** The paint of one 60px row, in CSS pixels. An upright run's two thirds start at the same column;
 *  a slanted run's top third starts to the right of its bottom third. */
function row(id: string): Paint {
  const top = Math.round(Number(logged[id]) * scale);
  const height = Math.round(60 * scale);
  let left = img.w;
  let right = -1;
  let count = 0;
  let firstRow = -1;
  let lastRow = -1;
  for (let y = top; y < top + height && y < img.h; y++) {
    for (let x = 0; x < img.w; x++) {
      const o = (y * img.w + x) * 4;
      if (!dark(img.rgba[o], img.rgba[o + 1], img.rgba[o + 2])) continue;
      count++;
      if (x < left) left = x;
      if (x > right) right = x;
      if (firstRow < 0) firstRow = y;
      lastRow = y;
    }
  }
  let topLeft = img.w;
  let bottomLeft = img.w;
  const third = Math.max(1, Math.round((lastRow - firstRow + 1) / 3));
  for (let y = firstRow; y < img.h && y < firstRow + third; y++) {
    for (let x = 0; x < img.w; x++) {
      const o = (y * img.w + x) * 4;
      if (dark(img.rgba[o], img.rgba[o + 1], img.rgba[o + 2]) && x < topLeft) topLeft = x;
    }
  }
  for (let y = Math.max(firstRow, lastRow - third + 1); y <= lastRow; y++) {
    for (let x = 0; x < img.w; x++) {
      const o = (y * img.w + x) * 4;
      if (dark(img.rgba[o], img.rgba[o + 1], img.rgba[o + 2]) && x < bottomLeft) bottomLeft = x;
    }
  }
  return { left: left / scale, right: right / scale, count, topLeft: topLeft / scale, bottomLeft: bottomLeft / scale };
}

const plain = width("a");
/** How far the top of the run sits right of its bottom: a right-leaning run's is positive. */
const slant = (id: string): number => row(id).topLeft - row(id).bottomLeft;
const paintedLikePlain = (id: string): boolean => {
  const p = row(id);
  const q = row("a");
  return p.count === q.count && p.left === q.left && p.right === q.right &&
    p.topLeft === q.topLeft && p.bottomLeft === q.bottomLeft;
};

check("a weight with no face to come from is drawn heavier",
  row("b").count > row("a").count * 1.15 && row("b").right > row("a").right,
  `${row("a").count} pixels plain, ${row("b").count} at 700`);
check("the heavier paint leaves the advance alone, as browsers do",
  Math.abs(width("b") - plain) < 0.5, `${width("b")}px against ${plain}px`);
check("an italic with no face to come from is drawn slanted",
  slant("c") >= 3, `the top third starts ${slant("c").toFixed(1)}px right of the bottom third`);
check("the slant leaves the advance alone too",
  Math.abs(width("c") - plain) < 0.5, `${width("c")}px against ${plain}px`);
check("the plain face itself is upright",
  Math.abs(slant("a")) <= 1, `${slant("a").toFixed(1)}px`);
check("font-synthesis: none leaves the heavy text on the plain face",
  Math.abs(width("d") - plain) < 0.5 && paintedLikePlain("d"),
  `${width("d")}px, ${row("d").count} pixels against ${row("a").count}`);
check("font-synthesis: none leaves the italic text on the plain face",
  Math.abs(width("e") - plain) < 0.5 && paintedLikePlain("e"),
  `${width("e")}px, ${slant("e").toFixed(1)}px of slant`);
check("with only style allowed, the weight is not drawn",
  paintedLikePlain("f"), `${row("f").count} pixels against ${row("a").count}`);
check("with only weight allowed, the italic is not drawn",
  paintedLikePlain("g"), `${slant("g").toFixed(1)}px of slant`);
check("with style alone allowed, the italic is drawn and the weight is not",
  slant("h") >= 3 && row("h").count < row("b").count,
  `${slant("h").toFixed(1)}px of slant, ${row("h").count} pixels against ${row("b").count}`);
check("naming every kind is the default and still draws the weight",
  row("i").count === row("b").count, `${row("i").count} pixels against ${row("b").count}`);
check("none beside another kind is not a value and leaves the default",
  logged.yj === "weight style small-caps" && row("j").count === row("b").count,
  `${logged.yj}, ${row("j").count} pixels against ${row("b").count}`);

check("font-synthesis computes to the kinds a family may draw in",
  logged.ya === "weight style small-caps", logged.ya);
check("font-synthesis: none computes to none", logged.yd === "none", logged.yd);
check("one kind computes to itself", logged.yf === "style", logged.yf);
check("kinds compute in weight, style, small-caps order",
  logged.yh === "style", logged.yh);

const notes = b.stderr.split("\n").filter((l) => l.includes("font-synthesis"));
check("the build names the kind that can't stand beside none",
  notes.some((l) => l.includes("font-synthesis")), notes.join(" | "));

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
