// Regression tests for absolute and fixed positioning and z-index: the containing block is the
// padding box of the nearest positioned ancestor (or the viewport), an auto offset falls back to
// the static position, an auto width shrinks to fit, positioned boxes paint above in-flow content
// sorted by z-index, and clicks are routed in the same order.
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

// #a: containing block is its padding box (5px border, 5px padding). #b: static positions.
// #c: paint order and z-index. A fixed box sits at the bottom right of the viewport (400x300),
// with a fixed child that must also measure from the viewport.
const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=300"><style>
body { margin: 0; }
#a { position: absolute; left: 0; top: 0; width: 100px; height: 100px; padding: 5px;
     border: 5px solid #000000; background: #cccccc; }
#abs1 { position: absolute; left: 0; top: 0; width: 20px; height: 20px; background: #ff0000; }
#abs2 { position: absolute; right: 0; bottom: 0; width: 20px; height: 20px; background: #0000ff; }
#abs3 { position: absolute; left: 0; top: 50px; background: #00ff00; }
#abs3 .inner { width: 30px; height: 10px; }
#b { position: absolute; left: 200px; top: 0; width: 100px; height: 100px; background: #dddddd;
     font-size: 0; line-height: 0; }
#b .pre { height: 15px; background: #eeeeee; }
#b .ib { display: inline-block; width: 30px; height: 15px; background: #eeeeee; }
#b .sa { position: absolute; width: 20px; height: 10px; background: #ffff00; }
#b .si { position: absolute; width: 16px; height: 16px; background: #00ffff; }
#c { position: absolute; left: 200px; top: 120px; width: 100px; height: 100px; background: #ffffff;
     z-index: 0; }
#c .flow { height: 40px; background: #000000; }
#c .over { position: absolute; left: 0; top: 0; width: 10px; height: 8px; background: #ffff00; }
#c .one { position: absolute; left: 10px; top: 10px; width: 30px; height: 30px;
          background: #ff0000; z-index: 1; }
#c .two { position: absolute; left: 20px; top: 20px; width: 50px; height: 50px;
          background: #0000ff; }
#c .three { position: absolute; left: 30px; top: 30px; width: 50px; height: 50px;
            background: #00ff00; z-index: -1; }
#d { position: absolute; left: 300px; top: 0; width: 100px; height: 60px; background: #eeeeee;
     font-size: 10px; line-height: 15px; }
#d .after { position: absolute; width: 20px; height: 10px; background: #000000; }
/* A fixed box with Chrome's popover style: fit-content on both axes, centred by auto margins. */
#pop { position: fixed; inset: 0; width: fit-content; height: fit-content; margin: auto;
       border: 1px solid #000000; background: #0000ff; font-size: 16px; line-height: 18px; }
/* The auto margins take the spare room on both axes, so the box sits in the middle. */
#e { position: absolute; left: 0; top: 140px; width: 100px; height: 100px; background: #cccccc; }
#e .center { position: absolute; inset: 0; margin: auto; width: 40px; height: 20px;
             background: #0000ff; }
#fx { position: fixed; right: 10px; bottom: 10px; width: 20px; height: 20px; background: #ff00ff; }
#fx .child { position: fixed; right: 0; bottom: 0; width: 10px; height: 10px;
             background: #880000; }
</style></head><body>
<div id="a">
  <div id="abs1"></div>
  <div id="abs2"></div>
  <div id="abs3"><div class="inner"></div></div>
</div>
<div id="b">
  <div class="pre"></div>
  <div class="sa"></div>
  <span class="ib"></span><span class="si"></span>
</div>
<div id="c">
  <div class="flow"></div>
  <div class="over"></div>
  <div class="one"></div>
  <div class="two"></div>
  <div class="three"></div>
</div>
<div id="d">ab<div class="after"></div></div>
<div id="e"><div class="center"></div></div>
<div id="fx"><div class="child"></div></div>
<div id="pop">abc</div>
</body></html>`;

const SCRIPT = `
document.addEventListener("click", (e) => {
  const t = e.target as HTMLElement;
  console.log("hit " + t.className);
});
window.addEventListener("load", () => {
  const r = document.getElementById("pop")!.getBoundingClientRect();
  console.log("pop h=" + Math.round(r.height) + " cx=" + Math.round(r.left + r.width / 2) +
    " cy=" + Math.round(r.top + r.height / 2) + " wide=" + (r.width > 20));
});
`;

// [name, CSS x, CSS y, expected colour]. The snapshot is 2 device px per CSS px.
const CHECKS: [string, number, number, string][] = [
  ["abs left/top measure from the padding box", 15, 15, "255,0,0"],
  ["abs right/bottom measure from the padding box", 110, 110, "0,0,255"],
  ["the padding edge, not the content edge, ends the containing block", 112, 110, "0,0,255"],
  ["an abs auto width shrinks to fit its content", 30, 60, "0,255,0"],
  ["shrink-to-fit is not the containing block's width", 40, 60, "204,204,204"],
  ["a block-level box's auto offsets use its static position", 205, 20, "255,255,0"],
  ["an inline-level box's static position follows the inline content", 235, 20, "0,255,255"],
  ["a positioned box paints above in-flow content", 205, 124, "255,255,0"],
  ["z-index 1 paints above a later box with no z-index", 230, 150, "255,0,0"],
  ["the z-index 0 box shows where the other doesn't cover it", 250, 170, "0,0,255"],
  ["a negative z-index paints below the in-flow content", 275, 155, "0,0,0"],
  ["a negative z-index paints above its stacking context's background", 275, 180, "0,255,0"],
  ["a block-level auto box after text starts on the next line", 310, 20, "0,0,0"],
  ["that box leaves the line it follows alone", 315, 5, "238,238,238"],
  ["auto margins center a box on both axes", 50, 190, "0,0,255"],
  ["it leaves the space above and below", 50, 145, "204,204,204"],
  ["and none of the spare room to the left", 10, 190, "204,204,204"],
  ["fixed right/bottom measure from the viewport", 380, 280, "255,0,255"],
  ["a fixed box inside a fixed box also measures from the viewport", 395, 295, "136,0,0"],
];

// Clicking .one's centre lands on .two as well: the higher z-index must win. Clicking .three,
// which paints below the in-flow content, lands on .two; .over lands on itself through .flow.
const STEPS = "click .one | click .three | click .over";
const HITS = ["hit one", "hit two", "hit over"];

function build(html: string, script: string): { dir: string; exe: string } {
  const dir = mkdtempSync(join(tmpdir(), "native-position-"));
  writeFileSync(join(dir, "index.html"), html.replace("</body>", `<script src="app.ts"></script></body>`));
  writeFileSync(join(dir, "app.ts"), script);
  const exe = join(dir, "app");
  const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
  if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
  return { dir, exe };
}

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const { dir, exe } = build(PAGE, SCRIPT);
const png = join(dir, "out.png");
const r = spawnSync(exe, [], {
  encoding: "utf8",
  env: { ...process.env, NATIVE_SNAPSHOT: png, NATIVE_STEPS: STEPS },
});
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);

const img = decodePng(png);
CHECKS.forEach(([name, cx, cy, want]) => {
  const o = ((cy * 2) * img.w + cx * 2) * 4;
  const got = `${img.rgba[o]},${img.rgba[o + 1]},${img.rgba[o + 2]}`;
  check(name, got === want, `got ${got}, want ${want}`);
});

const hits = r.stdout.split("\n").map((l) => l.trim()).filter((l) => l.startsWith("hit "));
check(`clicks reach the topmost positioned box (${HITS.join(", ")})`, hits.join("|") === HITS.join("|"),
  `got ${JSON.stringify(hits)}`);
const out = `${r.stdout}${r.stderr}`;
const pop = out.trim().split("\n").find((l) => l.startsWith("pop ")) ?? out.trim();
check("fit-content on both axes takes the content size", pop.includes("h=20"), pop);
check("and auto margins centre it in the viewport", pop.includes("cx=200 cy=150"), pop);
check("the width is max-content, not min-content", pop.includes("wide=true"), pop);

// A root element that is out of flow takes the initial containing block — the viewport — as its
// own, so a pair of insets decides each of its sizes and the box sits where they put it.
const ROOT_PAGE = `<!doctype html>
<html><head><meta charset="utf-8"><meta name="native-window" content="width=400, height=300"><style>
html { display: flex; position: absolute; left: 10px; right: 20px; top: 30px; bottom: 40px;
       border: 5px solid #000000; box-sizing: border-box; background: #cccccc; }
body { margin: 0; }
#in { width: 20px; height: 20px; background: #ff0000; }
</style></head><body><div id="in"></div></body></html>`;

const ROOT_SCRIPT = `
window.addEventListener("load", () => {
  const root = document.documentElement.getBoundingClientRect();
  const inBox = document.getElementById("in")!.getBoundingClientRect();
  console.log("root " + Math.round(root.left) + "," + Math.round(root.top) + " " +
    Math.round(root.width) + "x" + Math.round(root.height));
  console.log("in " + Math.round(inBox.left) + "," + Math.round(inBox.top));
});
`;
const second = build(ROOT_PAGE, ROOT_SCRIPT);
const r2 = spawnSync(second.exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: join(second.dir, "out.png") } });
const out2 = `${r2.stdout}${r2.stderr}`;
check("an out-of-flow root takes its size from its insets", out2.includes("root 10,30 370x230"), out2.trim());
check("and its content starts inside that box", out2.includes("in 15,35"), out2.trim());

// Text written straight under <html> builds the body a browser makes, so a flex root holds the
// text in that one item rather than laying the text runs out as items of its own.
const TEXT_ROOT_PAGE = `<!doctype html>
<html><head><meta charset="utf-8"><meta name="native-window" content="width=400, height=300"><style>
html { display: flex; }
body { margin: 0; }
</style></head>
one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen<script src="app.ts"></script></html>`;

const TEXT_ROOT_SCRIPT = `
window.addEventListener("load", () => {
  const b = document.body;
  const line = b === null ? "none" :
    b.tagName + " " + Math.round(b.getBoundingClientRect().width) + "x" +
    Math.round(b.getBoundingClientRect().height);
  console.log("body " + line);
});
`;
const third = build(TEXT_ROOT_PAGE, TEXT_ROOT_SCRIPT);
const r3 = spawnSync(third.exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: join(third.dir, "out.png") } });
const out3 = `${r3.stdout}${r3.stderr}`.trim();
const bodyLine = out3.split("\n").find((l) => l.startsWith("body ")) ?? "none";
// One item filling the viewport's width, as tall as the lines the text wraps into.
check("text under <html> goes into the body a browser builds", bodyLine.startsWith("body BODY 400x"), out3);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
