// font-variation-settings: each axis moves the variable font the text is drawn in, and the
// measures follow the axes, as they do in a browser. The list is the last value a tag gets, and
// computes back in the alphabet's order, a value of 1 left out.
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

// a  the text as the font comes      b  a weight above the default    c  a narrower width
// d  a weight above that             e  two axes at once              f  a weight below the default
// g  a tag twice, the last one winning   h  a tag of three letters, which is not an axis
// i  a value that isn't a number     j  the initial value              k  a signed number
// l  an axis whose value comes from var(), its fallback winning
// m  an axis whose value comes from var(), the custom property's own value winning
const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=820"><style>
body { margin: 0; font-size: 40px; color: black; font-family: system-ui; }
div { width: 400px; height: 60px; line-height: 50px; }
#a { }
#b { font-variation-settings: "wght" 700; }
#c { font-variation-settings: "wdth" 80; }
#d { font-variation-settings: "wght" 900; }
#e { font-variation-settings: "wght" 700, "wdth" 80; }
#f { font-variation-settings: "wght" 100; }
#g { font-variation-settings: "wght" 700, "wght" 400; }
#h { font-variation-settings: "aaa" 700; }
#i { font-variation-settings: "wght" abc; }
#j { font-variation-settings: normal; }
#k { font-variation-settings: "wght" +700; }
#l { font-variation-settings: "wght" var(--w, 700); }
#m { font-variation-settings: "wght" var(--w, 400); --w: 900; }
</style></head><body>
<div id="a"><span id="sa">Hamburgefonstiv</span></div>
<div id="b"><span id="sb">Hamburgefonstiv</span></div>
<div id="c"><span id="sc">Hamburgefonstiv</span></div>
<div id="d"><span id="sd">Hamburgefonstiv</span></div>
<div id="e"><span id="se">Hamburgefonstiv</span></div>
<div id="f"><span id="sf">Hamburgefonstiv</span></div>
<div id="g"><span id="sg">Hamburgefonstiv</span></div>
<div id="h"><span id="sh">Hamburgefonstiv</span></div>
<div id="i"><span id="si">Hamburgefonstiv</span></div>
<div id="j"><span id="sj">Hamburgefonstiv</span></div>
<div id="k"><span id="sk">Hamburgefonstiv</span></div>
<div id="l"><span id="sl">Hamburgefonstiv</span></div>
<div id="m"><span id="sm">Hamburgefonstiv</span></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const box = (id: string) => document.getElementById(id)!;
const style = (id: string) => getComputedStyle(box(id));
requestAnimationFrame(() => {
  requestAnimationFrame(() => {
    const out: string[] = [];
    const rows = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m"];
    for (const id of rows) out.push(id + "=" + box(id).getBoundingClientRect().top.toFixed(1));
    for (const id of rows) out.push("s" + id + "w=" + box("s" + id).getBoundingClientRect().width.toFixed(2));
    for (const id of rows) out.push("v" + id + "=" + style(id).fontVariationSettings);
    console.log(out.join("\\n"));
  });
});
`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-variations-"));
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

/** The paint of one 60px row: its ink count and its rightmost column, in CSS pixels. */
function row(id: string): { right: number; count: number } {
  const top = Math.round(Number(logged[id]) * scale);
  let right = -1;
  let count = 0;
  for (let y = top; y < top + Math.round(60 * scale) && y < img.h; y++) {
    for (let x = 0; x < img.w; x++) {
      const o = (y * img.w + x) * 4;
      if (!dark(img.rgba[o], img.rgba[o + 1], img.rgba[o + 2])) continue;
      count++;
      if (x > right) right = x;
    }
  }
  return { right: right / scale, count };
}

const plain = width("a");
const heavy = width("b");

check("an axis above the default widens the text",
  heavy > plain + 20, `"wght" 700 is ${heavy}px wide, the default ${plain}px`);
check("a heavier value still widens it further",
  width("d") > heavy + 5, `"wght" 900 is ${width("d")}px, "wght" 700 ${heavy}px`);
check("a weight below the default narrows the text",
  width("f") < plain - 10, `"wght" 100 is ${width("f")}px, the default ${plain}px`);
check("a narrower width axis narrows the text",
  width("c") < plain - 20, `"wdth" 80 is ${width("c")}px, the default ${plain}px`);
check("two axes at once take both of them",
  width("e") < heavy - 10 && width("e") > width("c") + 10,
  `both axes ${width("e")}px, the weight alone ${heavy}px, the width alone ${width("c")}px`);
check("the last value a tag gets is the one that counts",
  Math.abs(width("g") - plain) < 0.5, `${width("g")}px against ${plain}px`);
check("a signed number is the number it names",
  Math.abs(width("k") - heavy) < 0.5, `${width("k")}px against ${heavy}px`);
check("a tag of three letters is not an axis, and leaves the value alone",
  Math.abs(width("h") - plain) < 0.5 && logged.vh === "normal", `${width("h")}px, ${logged.vh}`);
check("a value that isn't a number leaves the value alone",
  Math.abs(width("i") - plain) < 0.5 && logged.vi === "normal", `${width("i")}px, ${logged.vi}`);
check("font-variation-settings: normal leaves the font as it comes",
  Math.abs(width("j") - plain) < 0.5 && logged.vj === "normal", `${width("j")}px, ${logged.vj}`);

check("the axes are painted, not only measured",
  row("b").count > row("a").count && row("d").count > row("b").count,
  `${row("a").count} pixels plain, ${row("b").count} at 700, ${row("d").count} at 900`);
check("the narrower axis ends the line sooner on the page too",
  row("c").right < row("a").right - 20,
  `the narrow row ends at ${row("c").right.toFixed(1)}px, the plain one at ${row("a").right.toFixed(1)}px`);

check("one axis computes to its tag and value",
  logged.vb === '"wght" 700', logged.vb);
check("two axes compute in the alphabet's order",
  logged.ve === '"wdth" 80, "wght" 700', logged.ve);
check("a tag named twice computes once, with its last value",
  logged.vg === '"wght" 400', logged.vg);
check("an axis list with no declaration computes to normal",
  logged.va === "normal", logged.va);
check("a signed number computes without its sign",
  logged.vk === '"wght" 700', logged.vk);

check("an axis whose value comes from var() takes the fallback",
  Math.abs(width("l") - heavy) < 0.5, `${width("l")}px against ${heavy}px`);
check("an axis whose value comes from var() takes the custom property's value",
  Math.abs(width("m") - width("d")) < 0.5, `${width("m")}px against ${width("d")}px`);
check("the substituted axes compute to the values they name",
  logged.vl === '"wght" 700' && logged.vm === '"wght" 900', `${logged.vl} | ${logged.vm}`);

const notes = b.stderr.split("\n").filter((l) => l.includes("font-variation-settings"));
check("the build names the axis tag that isn't four characters",
  notes.some((l) => l.includes("'aaa' is not a four-character axis tag")), notes.join(" | "));
check("the build names the value that isn't a number",
  notes.some((l) => l.includes('"wght" abc')), notes.join(" | "));

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
