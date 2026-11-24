// List items and their markers: the UA sheet's display: list-item, list-style-type and
// list-style-position, ::marker rules, the ordinals of an ordered list, and how a marker stays
// out of the rest of the DOM.
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

// Each list is a 200px row at a known top, with 40px of left padding, so the content edge is
// at x = 40 and a marker outside it has to paint to the left of that. Markers are colored per
// row so the pixels say which item drew them.
const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=200, height=800"><style>
body { margin: 0; font-family: monospace; font-size: 16px; }
.row { position: absolute; left: 0; width: 200px; margin: 0; padding-left: 40px; }
#outside { top: 0; }
#outside ::marker { color: #ff0000; }
#ordered { top: 100px; }
#ordered ::marker { color: #ff0000; }
#ordered li:nth-child(2)::marker { color: #0000ff; }
#ordered li:nth-child(3)::marker { color: #00aa00; }
#none { top: 160px; list-style-type: none; }
#inside { top: 220px; list-style-position: inside; }
#inside ::marker { color: #0000ff; }
#dyn { top: 300px; }
.dynmark::marker { color: #00aa00; }
#contlist { top: 340px; }
#cont::marker { content: "->"; }
#nested { top: 380px; }
/* A reversed list counts down, so its first marker is two digits and its last one digit. */
#rev { top: 460px; line-height: 20px; }
#rev ::marker { color: #ff0000; }
/* A counter started at 8 and incremented by each ::before: 9, then 10, then 11. */
#cnt { top: 720px; line-height: 20px; counter-reset: c 8; }
#cnt div { width: 100px; text-align: right; }
#cnt div::before { content: counter(c) "x"; counter-increment: c; color: #ff0000; }
</style></head><body>
<ul class="row" id="outside"><li id="first">a</li><li>b</li></ul>
<ol class="row" id="ordered" start="3"><li>x</li><li value="10">y</li><li>z</li></ol>
<ul class="row" id="none"><li>n1</li><li>n2</li></ul>
<ul class="row" id="inside"><li>in</li></ul>
<ul class="row" id="dyn"></ul>
<ul class="row" id="contlist"><li id="cont">c</li></ul>
<ul class="row" id="nested"><li>outer</li><li>outer<ul id="inner"><li>inner</li></ul></li></ul>
<ul id="plain" style="position: absolute; top: 440px; left: 0; width: 200px;"><li>p</li></ul>
<ol class="row" id="rev" reversed><li>r1</li><li>r2</li><li>r3</li><li>r4</li><li>r5</li><li>r6</li>
  <li>r7</li><li>r8</li><li>r9</li><li>r10</li><li>r11</li><li>r12</li></ol>
<div class="row" id="cnt"><div>a</div><div>b</div><div>c</div></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const first = document.getElementById("first")!;
console.log("first display=" + getComputedStyle(first).display);
console.log("first type=" + getComputedStyle(first).listStyleType + " pos=" + getComputedStyle(first).listStylePosition);
console.log("first marker display=" + getComputedStyle(first, "::marker").display + " color=" + getComputedStyle(first, "::marker").color);
console.log("first text=[" + first.textContent + "] children=" + first.childElementCount + " first=" + first.firstElementChild);
console.log("cont marker content=" + getComputedStyle(document.getElementById("cont")!, "::marker").content);
const ordered = document.getElementById("ordered")!;
console.log("ordered type=" + getComputedStyle(ordered.firstElementChild!).listStyleType);
const none = document.getElementById("none")!;
console.log("none type=" + getComputedStyle(none).listStyleType + " marker display=" + getComputedStyle(none.firstElementChild!, "::marker").display);
// A list item a script makes gets a marker box too, and its ::marker rule finds it.
const dyn = document.getElementById("dyn")!;
const li = document.createElement("li");
li.textContent = "made";
li.className = "dynmark";
dyn.appendChild(li);
console.log("dyn text=[" + dyn.textContent + "] children=" + dyn.childElementCount);
console.log("dyn marker color=" + getComputedStyle(li, "::marker").color);
// Replacing the children keeps the marker box too: it comes from style, not content.
const fresh = document.createElement("li");
fresh.className = "dynmark";
fresh.textContent = "tmp";
dyn.appendChild(fresh);
fresh.replaceChildren(document.createElement("b"));
console.log("replaced marker=" + getComputedStyle(fresh, "::marker").display + " children=" + fresh.childElementCount);
// Replacing an item's text keeps its marker.
first.textContent = "aa";
console.log("after text set [" + first.textContent + "] children=" + first.childElementCount);
// The UA sheet spaces a list from its surroundings but not a list inside a list.
const inner = document.getElementById("inner")!;
const plain = document.getElementById("plain")!;
console.log("nested margins=" + getComputedStyle(inner).marginTop + "/" + getComputedStyle(inner).marginBottom + " plain=" + getComputedStyle(plain).marginTop);
`;

const EXPECTED_LOG: [string, string][] = [
  ["the UA sheet makes <li> a list item", "first display=list-item"],
  ["list-style-* is inherited and reported", "first type=disc pos=outside"],
  ["a marker is a box of its own", "first marker display=inline color=rgb(255, 0, 0)"],
  ["a marker is not the item's text or a child", "first text=[a] children=0 first=null"],
  ["::marker content replaces the marker text", 'cont marker content="->"'],
  ["<ol> writes decimal markers", "ordered type=decimal"],
  ["list-style-type: none hides the marker", "none type=none marker display=none"],
  ["a created list item gets a marker", 'dyn text=[made] children=1'],
  ["a created item's ::marker rule applies", "dyn marker color=rgb(0, 170, 0)"],
  ["replaceChildren keeps the marker box", "replaced marker=inline children=1"],
  ["the text update kept the marker", "after text set [aa] children=0"],
  ["a nested list takes no block margins", "nested margins=0px/0px plain=16px"],
];

function buildAndRun(): { img: Image; out: string } {
  const dir = mkdtempSync(join(tmpdir(), "native-lists-"));
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
const colorAt = (x: number, y: number): string => {
  const o = (Math.round(y * 2) * img.w + Math.round(x * 2)) * 4;
  return `${img.rgba[o]},${img.rgba[o + 1]},${img.rgba[o + 2]}`;
};

/** How many pixels of `want` (within a tolerance) lie in a CSS-pixel rectangle. */
function countColor(want: string, x0: number, y0: number, x1: number, y1: number): number {
  const [r, g, b] = want.split(",").map(Number);
  let n = 0;
  for (let y = Math.round(y0 * 2); y < Math.round(y1 * 2); y++) {
    for (let x = Math.round(x0 * 2); x < Math.round(x1 * 2); x++) {
      const o = (y * img.w + x) * 4;
      if (Math.abs(img.rgba[o] - r) <= 40 && Math.abs(img.rgba[o + 1] - g) <= 40 && Math.abs(img.rgba[o + 2] - b) <= 40) n++;
    }
  }
  return n;
}

/** The left edge of the leftmost pixel of `want` in a CSS-pixel rectangle, or -1. */
function leftEdge(want: string, x0: number, y0: number, x1: number, y1: number): number {
  const [r, g, b] = want.split(",").map(Number);
  for (let x = Math.round(x0 * 2); x < Math.round(x1 * 2); x++) {
    for (let y = Math.round(y0 * 2); y < Math.round(y1 * 2); y++) {
      const o = (y * img.w + x) * 4;
      if (Math.abs(img.rgba[o] - r) <= 40 && Math.abs(img.rgba[o + 1] - g) <= 40 && Math.abs(img.rgba[o + 2] - b) <= 40) return x / 2;
    }
  }
  return -1;
}

/** How many dark (text) pixels lie in a CSS-pixel rectangle. */
function countDark(x0: number, y0: number, x1: number, y1: number): number {
  let n = 0;
  for (let y = Math.round(y0 * 2); y < Math.round(y1 * 2); y++) {
    for (let x = Math.round(x0 * 2); x < Math.round(x1 * 2); x++) {
      const o = (y * img.w + x) * 4;
      if (img.rgba[o] < 150 && img.rgba[o + 1] < 150 && img.rgba[o + 2] < 150) n++;
    }
  }
  return n;
}

// An outside marker hangs left of the 40px content edge.
check("the disc marker paints outside the content edge", countColor("255,0,0", 0, 0, 38, 40) > 0,
  `${countColor("255,0,0", 0, 0, 38, 40)} red pixels`);
check("the disc marker stays clear of the content edge", countColor("255,0,0", 32, 0, 200, 40) === 0,
  "a red pixel reached into the content box");

// list-style-type: none generates no marker box at all, so its rows start clean at x = 0.
check("list-style-type: none paints no marker", countDark(0, 160, 38, 200) === 0,
  `${countDark(0, 160, 38, 200)} dark pixels`);

// An <ol> numbers its items: "3.", then the value attribute's "10.", then "11.". Outside
// markers are right-aligned against the content edge, so a two-digit number starts further
// left than a one-digit one.
const red = leftEdge("255,0,0", 0, 100, 200, 160);
const blue = leftEdge("0,0,255", 0, 100, 200, 160);
const green = leftEdge("0,170,0", 0, 100, 200, 160);
check("the first ordered item draws an outside marker", red > 0, `left edge ${red}`);
check("a larger ordinal widens the marker to the left", blue >= 0 && blue < red - 4, `10. at ${blue}, 3. at ${red}`);
check("the item after a value counts on from it", green >= 0 && Math.abs(green - blue) <= 2, `11. at ${green}, 10. at ${blue}`);

// An inside marker is the first inline content of the item: it starts at the content edge and
// pushes the text to the right.
const inside = leftEdge("0,0,255", 0, 220, 200, 260);
check("an inside marker starts at the content edge", inside >= 40 && inside < 50, `left edge ${inside}`);
check("an inside marker pushes the text along", countDark(38, 220, 50, 260) === 0 && countDark(50, 220, 200, 260) > 0,
  "text overlapped the marker");

check("a created list item's marker paints", countColor("0,170,0", 0, 300, 38, 330) > 0);
check("::marker content paints in the marker's place", countDark(0, 340, 38, 370) > 0);

// A reversed list counts down from the item count: "12." is wider than "1.", so the first item's
// marker starts further left than the last one's.
const firstRev = leftEdge("255,0,0", 0, 460, 200, 480);
const lastRev = leftEdge("255,0,0", 0, 680, 200, 700);
check("a reversed list counts down to 1", firstRev >= 0 && lastRev >= 0 && lastRev > firstRev + 4,
  `12. at ${firstRev}, 1. at ${lastRev}`);

// counter() counts on from the reset, and gets a digit wider at 10.
const nine = leftEdge("255,0,0", 0, 720, 200, 740);
const ten = leftEdge("255,0,0", 0, 740, 200, 760);
check("counter() counts on from its reset", nine >= 0 && ten >= 0 && ten < nine - 4, `9x at ${nine}, 10x at ${ten}`);

const lines = out.split("\n");
EXPECTED_LOG.forEach(([name, want]) => {
  check(name, lines.includes(want), `want line "${want}"`);
});

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
