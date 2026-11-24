// line-clamp: the block shows only its first N lines and the last of them ends in an ellipsis.
// The heights come from the DOM; the rendering shows the text stops at the clamp and that the
// ellipsis is really added to the line rather than the line just being cut off.
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

// Every box holds three short lines, so the clamp has more to hide than it shows. The text is
// broken by newlines (collapsed to breaks by pre-line) and by <br>, which are the two paths a
// block's lines come from: its own text, and the inline content of its children.
//
//   a  two lines, its own text        b  the same text with no clamp
//   c  two lines through a span       d  the same with the -webkit- spelling and display
//   e  one line                       f  a line too long for the box, cut to fit
const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=520"><style>
body { margin: 0; font-size: 20px; color: black; }
div { width: 260px; line-height: 20px; margin: 0 0 20px; white-space: pre-line; }
#a, #b, #e { }
#a { line-clamp: 2; }
#c, #d { white-space: normal; }
#c { line-clamp: 2; }
#d { -webkit-line-clamp: 2; display: -webkit-box; -webkit-box-orient: vertical; }
#e { line-clamp: 1; }
#f { width: 200px; line-clamp: 2; }
</style></head><body>
<div id="a">one
two
three</div>
<div id="b">one
two
three</div>
<div id="c"><span>one<br>two<br>three</span></div>
<div id="d"><span>one<br>two<br>three</span></div>
<div id="e">one
two
three</div>
<div id="f">one
MMMMMMMMMMMMMMMMMMMMMMMMMMMMMM
three</div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const box = (id: string) => document.getElementById(id)!;
const at = (id: string) => box(id).getBoundingClientRect();
const style = (id: string) => getComputedStyle(box(id));
requestAnimationFrame(() => {
  requestAnimationFrame(() => {
    const out: string[] = [];
    for (const id of ["a", "b", "c", "d", "e", "f"]) {
      const r = at(id);
      out.push(id + "=" + r.top.toFixed(1) + "," + r.height.toFixed(1));
    }
    const spanRects = (id: string) => box(id).querySelector("span")!.getClientRects().length;
    out.push("crects=" + spanRects("c"));
    out.push("drects=" + spanRects("d"));
    out.push("aclamp=" + style("a").lineClamp);
    out.push("bclamp=" + style("b").lineClamp);
    out.push("cclamp=" + style("c").lineClamp);
    out.push("eclamp=" + style("e").lineClamp);
    out.push("dwebkit=" + style("d").getPropertyValue("-webkit-line-clamp"));
    out.push("ddark=" + style("d").display);
    console.log(out.join("\\n"));
  });
});
`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-clamp-"));
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
const boxInfo = (id: string): [number, number] => {
  const [t, h] = logged[id].split(",");
  return [Number(t), Number(h)];
};

// The snapshot is taken at the display's backing scale, so one CSS pixel is `scale` image pixels.
const scale = img.w / 400;
const dark = (r: number, g: number, bl: number): boolean => r < 90 && g < 90 && bl < 90;

/** The ink of one line: its painted columns, top row and pixel count, in CSS pixels. */
function line(id: string, n: number): { left: number; right: number; top: number; count: number } {
  const [top] = boxInfo(id);
  const y0 = Math.round((top + n * 20) * scale);
  const y1 = Math.round((top + (n + 1) * 20) * scale);
  let left = -1;
  let right = -1;
  let first = -1;
  let count = 0;
  for (let y = y0; y < y1 && y < img.h; y++) {
    for (let x = 0; x < img.w; x++) {
      const o = (y * img.w + x) * 4;
      if (!dark(img.rgba[o], img.rgba[o + 1], img.rgba[o + 2])) continue;
      count++;
      if (left < 0) left = x;
      right = x;
      if (first < 0) first = y;
    }
  }
  return { left, right, top: first, count };
}

const a1 = line("a", 0);
const a2 = line("a", 1);
const a3 = line("a", 2);
const b1 = line("b", 0);
const b2 = line("b", 1);
const b3 = line("b", 2);
const e1 = line("e", 0);
const f1 = line("f", 0);
const f2 = line("f", 1);
const f3 = line("f", 2);

const h = (id: string): number => boxInfo(id)[1];
const rightOf = (l: { right: number }): number => l.right / scale;

check("line-clamp: 2 makes a two-line block", Math.abs(h("a") - 40) < 0.6, `${h("a")}px tall`);
check("the same block without a clamp is three lines", Math.abs(h("b") - 60) < 0.6, `${h("b")}px tall`);
check("line-clamp: 1 makes a one-line block", Math.abs(h("e") - 20) < 0.6, `${h("e")}px tall`);
check("inline content is clamped too", Math.abs(h("c") - 40) < 0.6, `${h("c")}px tall`);
check("-webkit-line-clamp with display: -webkit-box is clamped the same way",
  Math.abs(h("d") - 40) < 0.6, `${h("d")}px tall`);

check("an inline box is laid out on two lines, not three",
  logged.crects === "2", `${logged.crects} rects`);
check("the -webkit- spelling clamps its inline box as well", logged.drects === "2", `${logged.drects} rects`);

check("the two kept lines are painted", a1.count > 20 && a2.count > 20, `${a1.count}, ${a2.count} pixels`);
check("the third line is not painted", a3.count === 0, `${a3.count} pixels below the clamp`);
check("the unclamped block paints its third line", b3.count > 20, `${b3.count} pixels`);
check("the lines above the clamp are untouched", Math.abs(rightOf(a1) - rightOf(b1)) < 0.6,
  `first line ends at ${rightOf(a1).toFixed(1)}px, unclamped at ${rightOf(b1).toFixed(1)}px`);

// The last kept line ends in the ellipsis, which the unclamped rendering of the same word lacks.
check("the last kept line ends in an ellipsis", rightOf(a2) >= rightOf(b2) + 4,
  `clamped line ends at ${rightOf(a2).toFixed(1)}px, the same word unclamped at ${rightOf(b2).toFixed(1)}px`);
check("a one-line clamp puts the ellipsis on the first line", rightOf(e1) >= rightOf(a1) + 4,
  `clamped line ends at ${rightOf(e1).toFixed(1)}px, the same word unclamped at ${rightOf(a1).toFixed(1)}px`);

check("a line too long for the block is cut to the content width",
  f2.count > 20 && rightOf(f2) <= 202 && rightOf(f2) >= 190,
  `the line ends at ${rightOf(f2).toFixed(1)}px of 200px`);
check("the cut line's ellipsis is the last thing painted", f3.count === 0, `${f3.count} pixels`);
check("the first line of a cut block is painted", f1.count > 20, `${f1.count} pixels`);

check("line-clamp computes to its number", logged.aclamp === "2", logged.aclamp);
check("line-clamp: 1 computes to 1", logged.eclamp === "1", logged.eclamp);
check("an unclamped block computes to none", logged.bclamp === "none", logged.bclamp);
check("the -webkit- spelling computes to the same number", logged.dwebkit === "2", logged.dwebkit);
check("display: -webkit-box lays the block out", logged.ddark !== "inline", logged.ddark);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
