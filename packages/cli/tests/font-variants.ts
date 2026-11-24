// font-variant-*: each longhand picks the OpenType features the font shapes with, and the
// `font-variant` shorthand sets all six. The masks reach the font as feature settings, so a variant
// measures and paints exactly as the equivalent font-feature-settings list does.
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

// a  the digits as they come      b  font-variant-numeric: tabular-nums
// c  the same request through font-feature-settings
// d  the font-variant shorthand   e  font-variant: none     f  the caps longhand alone
// g  the shorthand with two values   h  two of one group, which is not a value
// i  normal beside another value, which is not a shorthand either
// j  an explicit "tnum" 0 beside tabular-nums, which wins
// k  a ligature variant              l  the lowercase text untouched
// m  two longhands through the shorthand, for its order
// n  none beside another value, which is not a shorthand either
// o  the two width keywords of the east-asian list, which rule each other out
const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=960"><style>
body { margin: 0; font-size: 40px; color: black; }
div { width: 400px; height: 60px; line-height: 50px; }
#a { }
#b { font-variant-numeric: tabular-nums; }
#c { font-feature-settings: "tnum" 1; }
#d { font-variant: small-caps; }
#e { font-variant: none; }
#f { font-variant-caps: small-caps; }
#g { font-variant: small-caps tabular-nums; }
#h { font-variant-numeric: lining-nums oldstyle-nums; }
#i { font-variant: normal small-caps; }
#j { font-variant-numeric: tabular-nums; font-feature-settings: "tnum" 0; }
#k { font-variant-ligatures: no-common-ligatures; }
#l { }
#m { font-variant: no-common-ligatures small-caps; }
#n { font-variant: none small-caps; }
#o { font-variant-east-asian: full-width proportional-width; }
</style></head><body>
<div id="a"><span id="sa">1111111111</span></div>
<div id="b"><span id="sb">1111111111</span></div>
<div id="c"><span id="sc">1111111111</span></div>
<div id="d"><span id="sd">hamburgefonstiv</span></div>
<div id="e"><span id="se">hamburgefonstiv</span></div>
<div id="f"><span id="sf">hamburgefonstiv</span></div>
<div id="g"><span id="sg">1111111111</span></div>
<div id="h"><span id="sh">1111111111</span></div>
<div id="i"><span id="si">1111111111</span></div>
<div id="j"><span id="sj">1111111111</span></div>
<div id="k"><span id="sk">flutter</span></div>
<div id="l"><span id="sl">hamburgefonstiv</span></div>
<div id="m"><span id="sm">hamburgefonstiv</span></div>
<div id="n"><span id="sn">1111111111</span></div>
<div id="o"><span id="so">1111111111</span></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const box = (id: string) => document.getElementById(id)!;
const style = (id: string) => getComputedStyle(box(id));
requestAnimationFrame(() => {
  requestAnimationFrame(() => {
    const out: string[] = [];
    for (const id of ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o"]) {
      out.push(id + "=" + box(id).getBoundingClientRect().top.toFixed(1));
    }
    for (const id of ["sa", "sb", "sc", "sd", "se", "sf", "sg", "sh", "si", "sj", "sk", "sl", "sm", "sn", "so"]) {
      out.push(id + "w=" + box(id).getBoundingClientRect().width.toFixed(2));
    }
    out.push("fb=" + style("b").fontVariantNumeric);
    out.push("fd=" + style("d").fontVariantCaps);
    out.push("fdshort=" + style("d").fontVariant);
    out.push("feshort=" + style("e").fontVariant);
    out.push("fashort=" + style("a").fontVariant);
    out.push("fgshort=" + style("g").fontVariant);
    out.push("fh=" + style("h").fontVariantNumeric);
    out.push("fishort=" + style("i").fontVariant);
    out.push("fk=" + style("k").fontVariantLigatures);
    out.push("fl=" + style("l").fontVariantEastAsian + " " + style("l").fontVariantPosition);
    out.push("fmshort=" + style("m").fontVariant);
    out.push("fnshort=" + style("n").fontVariant);
    out.push("fo=" + style("o").fontVariantEastAsian);
    console.log(out.join("\\n"));
  });
});
`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-variants-"));
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
const width = (id: string): number => Number(logged[id + "w"]);

// The snapshot is taken at the display's backing scale, so one CSS pixel is `scale` image pixels.
const scale = img.w / 400;
const dark = (r: number, g: number, bl: number): boolean => r < 90 && g < 90 && bl < 90;

/** The rightmost painted column of one 60px row, in CSS pixels, and its ink count. */
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

const plain = width("sa");
const tabular = width("sb");

check("tabular-nums picks the font's tabular figures",
  tabular > plain + 20, `tabular-nums is ${tabular}px wide, the default ${plain}px`);
check("tabular-nums measures exactly as the equivalent feature list",
  Math.abs(tabular - width("sc")) < 0.5, `${tabular}px against ${width("sc")}px`);
check("the painted digits follow the measure",
  row("b").right >= row("a").right + 20,
  `the variant's row ends at ${row("b").right.toFixed(1)}px, the default at ${row("a").right.toFixed(1)}px`);
check("small-caps measures differently from lowercase",
  Math.abs(width("sd") - width("sl")) > 5,
  `small caps ${width("sd")}px, lowercase ${width("sl")}px`);
check("the font-variant shorthand sets the same feature as the longhand",
  Math.abs(width("sd") - width("sf")) < 0.5, `${width("sd")}px against ${width("sf")}px`);
check("small caps are painted differently too",
  row("d").right < row("l").right || row("d").count !== row("l").count,
  `small caps end at ${row("d").right.toFixed(1)}px with ${row("d").count} pixels, lowercase at ${row("l").right.toFixed(1)}px with ${row("l").count}`);
check("font-variant: none leaves the text as it comes",
  Math.abs(width("se") - width("sl")) < 0.5, `${width("se")}px against ${width("sl")}px`);
check("the shorthand takes several values, one from each of their groups",
  Math.abs(width("sg") - tabular) < 0.5, `${width("sg")}px against ${tabular}px`);
check("an explicit feature setting still overrides the variant",
  Math.abs(width("sj") - plain) < 0.5, `${width("sj")}px against ${plain}px`);
check("two values of one group are not a value and leave the initial one",
  Math.abs(width("sh") - plain) < 0.5 && logged.fh === "normal", `${width("sh")}px, ${logged.fh}`);
check("normal beside another value is not a shorthand and leaves every longhand",
  Math.abs(width("si") - plain) < 0.5 && logged.fishort === "normal", `${width("si")}px, ${logged.fishort}`);
check("none beside another value is not a shorthand either",
  Math.abs(width("sn") - plain) < 0.5 && logged.fnshort === "normal", `${width("sn")}px, ${logged.fnshort}`);
check("the two width keywords of the east-asian list are not a pair",
  Math.abs(width("so") - plain) < 0.5 && logged.fo === "normal", `${width("so")}px, ${logged.fo}`);

check("a variant longhand computes to its keyword",
  logged.fb === "tabular-nums", logged.fb);
check("font-variant-ligatures computes to its own keyword",
  logged.fk === "no-common-ligatures", logged.fk);
check("the shorthand computes to the longhands that aren't normal",
  logged.fdshort === "small-caps", logged.fdshort);
check("two values in the shorthand compute in CSS's order",
  logged.fgshort === "small-caps tabular-nums", logged.fgshort);
check("the shorthand computes ligatures before caps, as browsers write them",
  logged.fmshort === "no-common-ligatures small-caps", logged.fmshort);
check("font-variant: none computes to none", logged.feshort === "none", logged.feshort);
check("the initial shorthand computes to normal", logged.fashort === "normal", logged.fashort);
check("the longhands a value leaves alone compute to normal",
  logged.fl === "normal normal", logged.fl);

const notes = b.stderr.split("\n").filter((l) => l.includes("font-variant"));
check("the build names the longhand whose two values conflict",
  notes.some((l) => l.includes("'font-variant-numeric': it names two of one value")),
  notes.join(" | "));
check("the build names the shorthand whose value mixes normal with another",
  notes.some((l) => l.includes("'font-variant': normal can't be combined")),
  notes.join(" | "));
check("the build names the shorthand whose value mixes none with another",
  notes.some((l) => l.includes("'font-variant': none can't be combined")),
  notes.join(" | "));
check("the build names the east-asian longhand whose two widths conflict",
  notes.some((l) => l.includes("'font-variant-east-asian': it names two of one value")),
  notes.join(" | "));

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
