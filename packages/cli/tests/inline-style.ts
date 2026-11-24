// Regression tests for runtime inline styles: el.style (camelCase properties, setProperty,
// getPropertyValue, removeProperty, cssText, length), the style="" attribute, and
// getComputedStyle. The page's script sets styles and the build checks the pixels they paint,
// plus the strings the API hands back.
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

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=200, height=280"><style>
body { margin: 0; font-size: 10px; }
div { height: 20px; background: #000000; }
#c { background: #0000ff; }
#d { background: #0000ff; }
#e { background: #ffff00 !important; }
#f { background: #0000ff !important; }
#i { background: #ff0000; }
#j { color: #123456; font-size: 2em; width: 30px; }
/* The same image, but named by a stylesheet rule rather than a style attribute: the runtime has no
   build root to resolve the URL against, so the build records it for the computed value to find. */
#n { background-image: url(red.png); }
</style></head><body>
<div id="a"></div>
<div id="b"></div>
<div id="c" style="background: #ff00ff"></div>
<div id="d" style="background: #ff0000"></div>
<div id="e" style="background: #ff8800 !important"></div>
<div id="f"></div>
<div id="h"></div>
<div id="i"></div>
<div id="j"></div>
<div id="k"></div>
<div id="l"></div>
<div id="m" style="background-image: url(red.png)"></div>
<div id="n"></div>
<script src="app.ts"></script>
</body></html>`;

const RED_PNG =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==";

const SCRIPT = `
const byId = (id: string): HTMLElement => document.getElementById(id) as HTMLElement;

// A camelCase property.
byId("a").style.backgroundColor = "red";

// setProperty with a functional color, which serializes as rgb().
byId("b").style.setProperty("background-color", "rgb(0, 128, 0)");

// An inline style from the style attribute, replaced from the script.
byId("c").style.backgroundColor = "#00ffff";

// An inline style beats a rule; removeProperty hands the rule back.
const d = byId("d");
console.log("d before=" + d.style.backgroundColor);
d.style.removeProperty("background-color");
console.log("d after=" + d.style.backgroundColor);

// An important rule beats a normal inline declaration.
byId("f").style.backgroundColor = "#00ff00";

// Layout follows a script-set width and margin.
const h = byId("h");
h.style.backgroundColor = "#ff00ff";
h.style.marginLeft = "100px";
h.style.width = "50px";

// An invalid value is ignored, and an empty one removes the declaration.
const i = byId("i");
i.style.backgroundColor = "notacolor";
console.log("i invalid=" + getComputedStyle(i).backgroundColor);
i.style.backgroundColor = "#ffff00";
i.style.backgroundColor = "";
console.log("i cleared=" + getComputedStyle(i).backgroundColor);

// Computed style, as CSS-serialized values.
const j = getComputedStyle(byId("j"));
console.log("j display=" + j.getPropertyValue("display"));
console.log("j color=" + j.getPropertyValue("color"));
console.log("j width=" + j.getPropertyValue("width"));
console.log("j font-size=" + j.getPropertyValue("font-size"));
console.log("j background-color=" + j.getPropertyValue("background-color"));
console.log("j camel=" + j.backgroundColor);

// The declaration block the object holds.
const k = byId("k");
k.style.width = "10px";
k.style.backgroundColor = "#010203";
console.log("k cssText=" + k.style.cssText);
console.log("k length=" + String(k.style.length));
console.log("k item0=" + k.style.item(0));
console.log("k attr=" + k.getAttribute("style"));

// setAttribute("style") replaces the whole block.
const l = byId("l");
l.setAttribute("style", "background-color: #0000ff; width: 20px");
console.log("l bg=" + l.style.backgroundColor + " w=" + l.style.width);
l.removeAttribute("style");
console.log("l removed=" + String(l.getAttribute("style")));

// A created element gets its style from script, and the compiled rules still apply to it.
const g = document.createElement("div");
g.style.cssText = "background: #008888";
document.body.appendChild(g);

// Every property id has a name, so the flexbox ones serialize like the rest. Reading a detached
// element's computed style must not settle the page's own pending styles: the pixel checks below
// depend on k's width and g's background still being applied afterwards.
const m = document.createElement("div");
m.style.flexWrap = "wrap";
m.style.alignContent = "space-between";
m.style.order = "2";
m.style.flexDirection = "row-reverse";
console.log("m cssText=" + m.style.cssText);
const mc = getComputedStyle(m);
console.log("m computed=" + mc.getPropertyValue("flex-wrap") + " " + mc.alignContent + " " + mc.flexDirection);

// The alignment keywords: a self position keeps the keyword it was written with, an overflow
// position keeps its prefix, a place-* shorthand writes both axes, and a keyword the property
// does not take is dropped the way a browser drops it.
m.style.alignSelf = "safe center";
m.style.justifySelf = "right";
m.style.justifyItems = "self-start";
m.style.placeContent = "safe center end";
m.style.alignItems = "left";
const nc = getComputedStyle(m);
console.log("n align=" + [nc.alignSelf, nc.justifySelf, nc.justifyItems, nc.placeContent,
  nc.alignContent, nc.justifyContent, nc.alignItems].join("|"));

// The box shorthands read back from their longhands.
const q = document.createElement("div");
q.style.margin = "1px 2px 3px 4px";
q.style.padding = "5px";
q.style.inset = "6px 7px";
q.style.border = "1px solid rgb(1, 1, 1)";
const borderBefore = q.style.border;
q.style.borderTop = "2px dashed rgb(2, 2, 2)";
q.style.borderStartStartRadius = "9px";
console.log("q shorthands=" + [q.style.margin, q.style.padding, q.style.inset, borderBefore, q.style.borderTop,
  q.style.borderStartStartRadius].join("|"));
`;

// Expected background of each div, in document order (the created one goes last).
const EXPECTED: [string, string][] = [
  ["a: style.backgroundColor", "255,0,0"],
  ["b: style.setProperty", "0,128,0"],
  ["c: script overrides the style attribute", "0,255,255"],
  ["d: the rule applies again after removeProperty", "0,0,255"],
  ["e: inline !important beats the rule's !important", "255,136,0"],
  ["f: the rule's !important beats a normal inline style", "0,0,255"],
  // The sampled point is in #h's margin (see below), and past the narrow #j and #k boxes.
  ["h: the sampled point is in its margin", "255,255,255"],
  ["i: invalid value ignored, then removed", "255,0,0"],
  ["j: the sampled point is past its 30px width", "255,255,255"],
  ["k: the sampled point is past its 10px width", "255,255,255"],
  ["l: style attribute removed", "0,0,0"],
  ["m: inline background-image url()", "255,0,0"],
  ["n: a stylesheet rule's background-image url()", "255,0,0"],
  ["g: created element with cssText", "0,136,136"],
];

const EXPECTED_LOG: [string, string][] = [
  ["d before: the style attribute", "d before=rgb(255, 0, 0)"],
  ["d after: removeProperty", "d after="],
  ["i invalid: computed falls back to the rule", "i invalid=rgb(255, 0, 0)"],
  ["i cleared: computed falls back to the rule", "i cleared=rgb(255, 0, 0)"],
  ["j display", "j display=block"],
  ["j color", "j color=rgb(18, 52, 86)"],
  ["j width", "j width=30px"],
  ["j font-size: 2em of the parent's 10px", "j font-size=20px"],
  ["j background-color: the div rule's black", "j background-color=rgb(0, 0, 0)"],
  ["j camelCase on a computed style", "j camel=rgb(0, 0, 0)"],
  ["k cssText serializes colors as rgb()", "k cssText=width: 10px; background-color: rgb(1, 2, 3);"],
  ["k length", "k length=2"],
  ["k item(0)", "k item0=width"],
  ["k getAttribute(\"style\")", "k attr=width: 10px; background-color: rgb(1, 2, 3);"],
  ["l setAttribute(\"style\")", "l bg=rgb(0, 0, 255) w=20px"],
  ["l removeAttribute(\"style\")", "l removed=null"],
  ["m cssText: flexbox properties serialize by name", "m cssText=flex-wrap: wrap; align-content: space-between; order: 2; flex-direction: row-reverse;"],
  ["m computed: flexbox values serialize as keywords", "m computed=wrap space-between row-reverse"],
  ["n computed: alignment keywords and the overflow position keep their words",
    "n align=safe center|right|self-start|safe center end|safe center|end|normal"],
  ["q: margin, padding, inset and border read back from their longhands",
    "q shorthands=1px 2px 3px 4px|5px|6px 7px|1px solid rgb(1, 1, 1)|2px dashed rgb(2, 2, 2)|9px"],
];

function buildAndRun(): { img: Image; out: string } {
  const dir = mkdtempSync(join(tmpdir(), "native-inline-style-"));
  writeFileSync(join(dir, "index.html"), PAGE);
  writeFileSync(join(dir, "app.ts"), SCRIPT);
  // A 1x1 red PNG: repeated, it fills #m's background.
  writeFileSync(join(dir, "red.png"), Buffer.from(RED_PNG, "base64"));
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
const colorAt = (x: number, y: number): string => {
  const o = (y * img.w + x) * 4;
  return `${img.rgba[o]},${img.rgba[o + 1]},${img.rgba[o + 2]}`;
};
// Each div is 20 CSS px tall and the snapshot is 2 device px per CSS px, so div i covers
// device rows [40i, 40i + 40).
EXPECTED.forEach(([name, want], i) => {
  const got = colorAt(100, 40 * i + 20);
  check(name, got === want, `got ${got}, want ${want}`);
});

// #h starts at 100 CSS px (device 200) and is 50 CSS px wide (device 100), so the margin
// shows the page's background and the box shows its own.
const rowH = 6 * 40;
check("h: margin-left leaves the page background", colorAt(100, rowH + 20) === "255,255,255",
  `got ${colorAt(100, rowH + 20)}`);
check("h: script-set background inside the box", colorAt(250, rowH + 20) === "255,0,255",
  `got ${colorAt(250, rowH + 20)}`);
check("h: width ends the box", colorAt(310, rowH + 20) === "255,255,255",
  `got ${colorAt(310, rowH + 20)}`);

const lines = out.split("\n");
EXPECTED_LOG.forEach(([name, want]) => {
  check(name, lines.includes(want), `want line "${want}"`);
});

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
