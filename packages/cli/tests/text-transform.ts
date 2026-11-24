// text-transform: uppercase, lowercase and capitalize change the rendered text (and the room it
// takes) without changing the DOM.
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

// Each line sits at a known y, 24px apart, right-aligned in a 120px box: a wider rendering
// starts further to the left, which is how these checks compare the drawn widths.
const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=320, height=200"><style>
body { margin: 0; font: 13px sans-serif; }
div { position: absolute; left: 10px; width: 120px; height: 20px; text-align: right; overflow: hidden; }
#upper { top: 0; text-transform: uppercase; }
#lower { top: 24px; text-transform: lowercase; }
#cap { top: 48px; text-transform: capitalize; }
#plain { top: 72px; }
#capbase { top: 96px; }
#inline { top: 120px; }
#toggled { top: 144px; }
#abcplain { top: 168px; }
</style></head><body>
<div id="upper">hi there</div>
<div id="lower">HI THERE</div>
<div id="cap">word</div>
<div id="plain">hi there</div>
<div id="capbase">word</div>
<div id="inline">abc</div>
<div id="toggled">abc</div>
<div id="abcplain">abc</div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const upper = document.getElementById("upper")!;
console.log("upper=" + getComputedStyle(upper).textTransform + " dom=" + upper.textContent);
const lower = document.getElementById("lower")!;
console.log("lower=" + getComputedStyle(lower).textTransform);
const cap = document.getElementById("cap")!;
console.log("cap=" + getComputedStyle(cap).textTransform);
const plain = document.getElementById("plain")!;
console.log("plain=" + getComputedStyle(plain).textTransform);
const inline = document.getElementById("inline")!;
inline.style.textTransform = "uppercase";
console.log("inline=" + getComputedStyle(inline).textTransform);
console.log("inline text=" + inline.textContent);
const toggled = document.getElementById("toggled")!;
toggled.style.textTransform = "lowercase";
toggled.style.removeProperty("text-transform");
console.log("removed=" + getComputedStyle(toggled).textTransform);
`;

const EXPECTED_LOG: [string, string][] = [
  ["an uppercase transform serializes", "upper=uppercase dom=hi there"],
  ["a lowercase transform serializes", "lower=lowercase"],
  ["a capitalize transform serializes", "cap=capitalize"],
  ["the initial transform is none", "plain=none"],
  ["an inline transform applies", "inline=uppercase"],
  ["removing it restores the rule's", "removed=none"],
  ["the DOM text is untouched", "inline text=abc"],
];

function buildAndRun(): { img: Image; out: string } {
  const dir = mkdtempSync(join(tmpdir(), "native-text-transform-"));
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

/** The leftmost CSS x with ink on the line band y0..y1, or -1 when the band is blank. */
function firstInkX(y0: number, y1: number): number {
  for (let x = 0; x < 160 * 2; x++) {
    for (let y = Math.round(y0 * 2); y < Math.round(y1 * 2); y++) {
      const o = (y * img.w + x) * 4;
      if (img.rgba[o] < 160 && img.rgba[o + 1] < 160 && img.rgba[o + 2] < 160) return x / 2;
    }
  }
  return -1;
}

const upperX = firstInkX(0, 20);
const plainX = firstInkX(72, 92);
const capX = firstInkX(48, 68);
const capBaseX = firstInkX(96, 116);
check("uppercase text is drawn", upperX >= 0, `leftmost ink at ${upperX}`);
check("lowercase text is drawn", firstInkX(24, 44) >= 0, "");
check("capitalize text is drawn", capX >= 0, "");
// Uppercase letters are wider, and the line is right-aligned, so it starts further left.
check("uppercase is wider than the plain text", upperX >= 0 && upperX < plainX - 3, `upper ${upperX}, plain ${plainX}`);
check("a capitalized word is wider than the plain one", capX >= 0 && capX < capBaseX - 0.5, `cap ${capX}, plain ${capBaseX}`);
// The DOM still holds "abc"; the inline transform renders "ABC", which is wider than the plain
// "abc" below it, so the right-aligned line starts further left.
check("an inline transform redraws without touching the DOM", firstInkX(120, 140) < firstInkX(168, 188) - 0.5,
  `transformed ${firstInkX(120, 140)}, plain ${firstInkX(168, 188)}`);

const lines = out.split("\n");
EXPECTED_LOG.forEach(([name, want]) => {
  check(name, lines.includes(want), `want line "${want}"`);
});

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
