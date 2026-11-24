// font-feature-settings: an OpenType feature the text asks for changes both its measures and its
// drawing, through the system font's own tables. Every box holds the same digits, so the widths
// and the painted runs show which features reached the text.
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

// a  the digits as they come   b  the same digits with tabular figures
// c  the feature off again     d  the feature on the parent, inherited by the span
// e  lowercase text with small caps, for the feature list's second entry
// g  two features at once      h  a declaration with no quotes, which is not a feature list
const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=620"><style>
body { margin: 0; font-size: 40px; color: black; }
div { width: 400px; height: 80px; line-height: 50px; }
#a { }
#b { font-feature-settings: "tnum" 1; }
#c { font-feature-settings: "tnum" 0; }
#d { font-feature-settings: "tnum" 1; }
#e { font-feature-settings: "smcp" 1; }
#f { }
#g { font-feature-settings: "tnum" 1, "smcp" 1; }
#h { font-feature-settings: tnum 1; }
</style></head><body>
<div id="a"><span id="sa">1111111111</span></div>
<div id="b"><span id="sb">1111111111</span></div>
<div id="c"><span id="sc">1111111111</span></div>
<div id="d"><span id="sd">1111111111</span></div>
<div id="e"><span id="se">hamburgefonstiv</span></div>
<div id="f"><span id="sf">hamburgefonstiv</span></div>
<div id="g"><span id="sg">1111111111</span></div>
<div id="h"><span id="sh">1111111111</span></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const box = (id: string) => document.getElementById(id)!;
const style = (id: string) => getComputedStyle(box(id));
requestAnimationFrame(() => {
  requestAnimationFrame(() => {
    const out: string[] = [];
    for (const id of ["a", "b", "c", "d", "e", "f", "g", "h"]) {
      out.push(id + "=" + box(id).getBoundingClientRect().top.toFixed(1));
    }
    for (const id of ["sa", "sb", "sc", "sd", "se", "sf", "sg", "sh"]) {
      const r = box(id).getBoundingClientRect();
      out.push(id + "w=" + r.width.toFixed(2));
    }
    out.push("fb=" + style("b").fontFeatureSettings);
    out.push("fa=" + style("a").fontFeatureSettings);
    out.push("fc=" + style("c").fontFeatureSettings);
    out.push("fg=" + style("g").fontFeatureSettings);
    out.push("fh=" + style("h").fontFeatureSettings);
    console.log(out.join("\\n"));
  });
});
`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-features-"));
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

/** The rightmost painted column of one 80px row, in CSS pixels, and its ink count. */
function row(id: string): { right: number; count: number } {
  const top = Math.round(Number(logged[id]) * scale);
  let right = -1;
  let count = 0;
  for (let y = top; y < top + Math.round(80 * scale) && y < img.h; y++) {
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

check("the system font's tabular figures measure differently from its proportional ones",
  tabular > plain + 20, `"tnum" 1 is ${tabular}px wide, the default ${plain}px`);
check("the painted digits run as wide as they measure",
  row("b").right >= row("a").right + 20,
  `the feature's row ends at ${row("b").right.toFixed(1)}px, the default at ${row("a").right.toFixed(1)}px`);
check('"tnum" 0 asks for the font\'s own figures back',
  Math.abs(width("sc") - plain) < 0.5, `${width("sc")}px against ${plain}px`);
check("a feature setting inherits to the text inside the element",
  Math.abs(width("sd") - tabular) < 0.5, `${width("sd")}px against ${tabular}px`);
check("small caps measure differently from lowercase",
  Math.abs(width("se") - width("sf")) > 5,
  `small caps ${width("se")}px, lowercase ${width("sf")}px`);
check("small caps are painted differently too",
  row("e").right < row("f").right || row("e").count !== row("f").count,
  `small caps end at ${row("e").right.toFixed(1)}px with ${row("e").count} pixels, lowercase at ${row("f").right.toFixed(1)}px with ${row("f").count}`);
check("the feature list carries more than one feature",
  Math.abs(width("sg") - tabular) < 0.5, `${width("sg")}px against ${tabular}px`);

check("font-feature-settings computes to a quoted tag, its value of 1 left out",
  logged.fb === '"tnum"', logged.fb);
check("a list of features computes to the tags in the alphabet's order",
  logged.fg === '"smcp", "tnum"', logged.fg);
check("text with no feature settings computes to normal", logged.fa === "normal", logged.fa);
check('an explicit off computes to "tag" 0', logged.fc === '"tnum" 0', logged.fc);
check("a list without quotes is not a feature list and leaves the initial value",
  logged.fh === "normal", logged.fh);
check("the build says why that declaration was dropped",
  b.stderr.includes("font-feature-settings"), b.stderr.split("\n").filter((l) => l.includes("font-")).join(" | "));

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
