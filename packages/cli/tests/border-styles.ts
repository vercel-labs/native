// Border styles: dashed, dotted, double, groove, ridge, inset and outset, each side keeping its
// own style, and the styles on a rounded box.
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

// Each box is 80x40 with its left edge at x = 40 and its top at a known y, so a side's band
// can be sampled by position. White backgrounds make the gaps and the 3D shading visible.
const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=240, height=1000"><style>
body { margin: 0; font-family: monospace; font-size: 16px; }
.box { position: absolute; left: 40px; width: 80px; height: 40px; background: #ffffff; }
#solid { top: 0; border: 4px solid #ff0000; }
#dashed { top: 60px; border: 4px dashed #ff0000; }
#dotted { top: 120px; border: 4px dotted #0000ff; }
#double { top: 180px; border: 6px double #00aa00; }
#groove { top: 240px; border: 8px groove #808080; }
#inset { top: 300px; border: 8px inset #808080; }
#outset { top: 360px; border: 8px outset #808080; }
#ridge { top: 420px; border: 8px ridge #808080; }
#mixed { top: 480px; border: 4px dashed #ff0000; border-top-style: solid; }
#round { top: 540px; border: 4px dashed #ff0000; border-radius: 16px; }
#narrow { top: 600px; border-style: dashed; }
#late { top: 660px; border: 10px #ff0000; border-style: solid; }
#reset { top: 720px; border-style: solid; border: 10px #0000ff; }
#triTop { position: absolute; top: 780px; left: 40px; width: 0; height: 0; border-top: 40px solid #ff0000; border-left: 40px solid transparent; }
#triBottom { position: absolute; top: 780px; left: 120px; width: 0; height: 0; border-bottom: 40px solid #0000ff; border-right: 40px solid transparent; }
#corner { position: absolute; top: 840px; left: 40px; width: 80px; height: 40px; background: #ffffff; border-top: 10px solid #ff0000; border-left: 10px solid #0000ff; }
</style></head><body>
<div class="box" id="solid"></div>
<div class="box" id="dashed"></div>
<div class="box" id="dotted"></div>
<div class="box" id="double"></div>
<div class="box" id="groove"></div>
<div class="box" id="inset"></div>
<div class="box" id="outset"></div>
<div class="box" id="ridge"></div>
<div class="box" id="mixed"></div>
<div class="box" id="round"></div>
<div class="box" id="narrow"></div>
<div class="box" id="late"></div>
<div class="box" id="reset"></div>
<div id="triTop"></div>
<div id="triBottom"></div>
<div id="corner"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const dashed = document.getElementById("dashed")!;
console.log("dashed style=" + getComputedStyle(dashed).borderTopStyle + " width=" + getComputedStyle(dashed).borderTopWidth);
const mixed = document.getElementById("mixed")!;
console.log("mixed styles=" + getComputedStyle(mixed).borderStyle);
console.log("mixed widths=" + getComputedStyle(mixed).borderTopWidth + "/" + getComputedStyle(mixed).borderLeftWidth);
const narrow = document.getElementById("narrow")!;
console.log("medium width=" + getComputedStyle(narrow).borderTopWidth + " style=" + getComputedStyle(narrow).borderTopStyle);
const round = document.getElementById("round")!;
console.log("round style=" + getComputedStyle(round).borderTopStyle + " radius=" + getComputedStyle(round).borderRadius);
const narrowEl = document.getElementById("narrow")!;
narrowEl.style.borderTopStyle = "dotted";
console.log("set inline=" + getComputedStyle(narrowEl).borderTopStyle);
const late = document.getElementById("late")!;
console.log("late width=" + getComputedStyle(late).borderTopWidth + " style=" + getComputedStyle(late).borderTopStyle);
const reset = document.getElementById("reset")!;
console.log("reset width=" + getComputedStyle(reset).borderTopWidth + " style=" + getComputedStyle(reset).borderTopStyle);
`;

const EXPECTED_LOG: [string, string][] = [
  ["a dashed border keeps its style and width", "dashed style=dashed width=4px"],
  ["each side serializes its own border style", "mixed styles=solid dashed dashed dashed"],
  ["a side's style leaves the width alone", "mixed widths=4px/4px"],
  ["a style with no width uses medium", "medium width=3px style=dashed"],
  ["a rounded box keeps its style", "round style=dashed radius=16px"],
  ["an inline border style applies", "set inline=dotted"],
  ["a later border-style brings the shorthand's width back", "late width=10px style=solid"],
  ["a shorthand after the style resets it", "reset width=0px style=none"],
];

function buildAndRun(): { img: Image; out: string } {
  const dir = mkdtempSync(join(tmpdir(), "native-border-styles-"));
  writeFileSync(join(dir, "index.html"), PAGE);
  writeFileSync(join(dir, "app.ts"), SCRIPT);
  const exe = join(dir, "app");
  const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
  if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
  const png = join(dir, "out.png");
  const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png } });
  if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
  return { img: decodePng(png), out: `${r.stdout}${r.stderr}` };
}

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const { img, out } = buildAndRun();
// The snapshot is 2 device px per CSS px; the helpers take CSS coordinates.
const rgb = (x: number, y: number): number[] => {
  const o = (Math.round(y * 2) * img.w + Math.round(x * 2)) * 4;
  return [img.rgba[o], img.rgba[o + 1], img.rgba[o + 2]];
};
const near = (x: number, y: number, c: number[], tol = 24): boolean => {
  const p = rgb(x, y);
  return Math.abs(p[0] - c[0]) <= tol && Math.abs(p[1] - c[1]) <= tol && Math.abs(p[2] - c[2]) <= tol;
};
const white = (x: number, y: number): boolean => near(x, y, [255, 255, 255]);
const RED = [255, 0, 0];
const BLUE = [0, 0, 255];
const GREEN = [0, 170, 0];
const DARK = [64, 64, 64];
const LIGHT = [192, 192, 192];

// A box is 80x40 of content with a 4px border, so its border box is 88x48: the bottom band sits
// at y = 44..48.
check("a solid side fills its band", near(60, 2, RED) && near(60, 46, RED), `${rgb(60, 2)} / ${rgb(60, 46)}`);

// Dashes are three widths long with one width between them: 12 on, 4 off from the corner.
check("a dash paints", near(44, 61, RED), `got ${rgb(44, 61)}`);
check("the gap after a dash stays clear", white(53, 61), `got ${rgb(53, 61)}`);
check("the next dash paints", near(58, 61, RED), `got ${rgb(58, 61)}`);

// Dots are round, one width wide: the center of a dot is painted, the middle of the gap isn't.
check("a dot paints at its center", near(58, 122, BLUE), `got ${rgb(58, 122)}`);
check("the space between dots stays clear", white(46, 122), `got ${rgb(46, 122)}`);

// Double is two lines a third of the width, with a third between them.
check("a double border draws its outer line", near(60, 181, GREEN), `got ${rgb(60, 181)}`);
check("a double border leaves the middle open", white(60, 183), `got ${rgb(60, 183)}`);
check("a double border draws its inner line", near(60, 185, GREEN), `got ${rgb(60, 185)}`);
// At a corner each line is whole: two lines a third of the width, with a third between them.
check("a double border's outer line fills its corner square", near(41, 182, GREEN), `got ${rgb(41, 182)}`);
check("a double border's inner line fills its corner square", near(44, 185, GREEN), `got ${rgb(44, 185)}`);

// A side's dash pattern starts at the corner, so it runs the border box's whole length.
check("a dash on the left side starts at the corner", near(41, 68, RED), `got ${rgb(41, 68)}`);
check("the gap after a corner dash stays clear", white(41, 73), `got ${rgb(41, 73)}`);
// A 3D side runs through the corner too, its outer half shading it there.
check("a groove's side reaches into the corner", near(41, 246, DARK), `got ${rgb(41, 246)}`);

// Groove: the outer half of the top side is dark, the inner half light.
check("a groove's outer band is dark", near(60, 242, DARK), `got ${rgb(60, 242)}`);
check("a groove's inner band is light", near(60, 246, LIGHT), `got ${rgb(60, 246)}`);

// Inset: dark on the top and left, light on the bottom and right.
check("an inset's top is dark", near(60, 302, DARK), `got ${rgb(60, 302)}`);
check("an inset's bottom is light", near(60, 350, LIGHT), `got ${rgb(60, 350)}`);

// Outset is the other way round.
check("an outset's top is light", near(60, 362, LIGHT), `got ${rgb(60, 362)}`);
check("an outset's bottom is dark", near(60, 412, DARK), `got ${rgb(60, 412)}`);

// Ridge: the outer half of the top side is light, the inner half dark.
check("a ridge's outer band is light", near(60, 422, LIGHT), `got ${rgb(60, 422)}`);
check("a ridge's inner band is dark", near(60, 426, DARK), `got ${rgb(60, 426)}`);

// One side's style overrides the shorthand's: the top is solid, the left stays dashed.
check("a later side style overrides the shorthand", near(58, 482, RED), `got ${rgb(58, 482)}`);
check("the other sides keep the shorthand's style", near(42, 490, RED) && white(42, 493), `${rgb(42, 490)} / ${rgb(42, 493)}`);

// On a rounded box the corners are drawn whole and the straight runs between them are dashed.
check("a rounded border keeps its corner arc", near(46, 546, RED, 70), `got ${rgb(46, 546)}`);
check("a rounded border dashes its straight run", near(58, 541, RED) && white(70, 541), `${rgb(58, 541)} / ${rgb(70, 541)}`);

// A style with no width uses the initial medium, so the border is 3px of dashes.
const medium = [42, 45, 48, 51, 54, 57].map((x) => rgb(x, 601));
check("a style with no width uses medium", medium.some((p) => p[0] < 90 && p[1] < 90 && p[2] < 90),
  `${medium.map((p) => p.join(",")).join(" ")}`);
check("the medium border is 3px wide", white(60, 605), `got ${rgb(60, 605)}`);

// `border: 10px` leaves the style none, so the width is declared but unused until a style comes;
// the later `border-style: solid` draws the 10px band it declared.
check("a width from the shorthand is used once a style follows", near(60, 665, RED), `got ${rgb(60, 665)}`);
check("the band is the declared width", white(60, 676), `got ${rgb(60, 676)}`);

// A zero-size box draws each side as the triangle its corners miter into: #triTop keeps the half
// below its diagonal, and the transparent left border leaves the other half white.
check("a zero-size box draws its border as a triangle", near(70, 790, RED), `got ${rgb(70, 790)}`);
check("the transparent side leaves its triangle clear", white(45, 810), `got ${rgb(45, 810)}`);
check("the mirrored triangle sits below its diagonal", near(130, 810, BLUE), `got ${rgb(130, 810)}`);
check("the mirrored triangle's other half is clear", white(155, 790), `got ${rgb(155, 790)}`);

// Two sides of different colours meet along the miter, not along the box's own corner square.
check("the left side owns the corner below the miter", near(45, 849, BLUE), `got ${rgb(45, 849)}`);
check("the top side owns the corner above the miter", near(45, 841, RED), `got ${rgb(45, 841)}`);

// The other order: the shorthand comes last and resets the style to none, so nothing is drawn.
check("a shorthand after the style draws nothing", white(60, 725), `got ${rgb(60, 725)}`);
check("the reset box keeps its content", white(80, 745), `got ${rgb(80, 745)}`);

const lines = out.split("\n");
EXPECTED_LOG.forEach(([name, want]) => {
  check(name, lines.includes(want), `want line "${want}"`);
});

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
