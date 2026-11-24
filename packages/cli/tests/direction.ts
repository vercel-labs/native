// direction: `start` and `end` line up with the side the direction says the text begins on, while
// `left` and `right` stay put, and the direction is inherited (the `dir` attribute included).
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { inflateSync } from "node:zlib";

interface Image {
  w: number;
  h: number;
  bpp: number;
  rgba: Uint8Array;
}

function decodePng(path: string): Image {
  const b = readFileSync(path);
  let i = 8;
  let w = 0;
  let h = 0;
  let colorType = 0;
  const idat: Buffer[] = [];
  while (i < b.length) {
    const len = b.readUInt32BE(i);
    const type = b.toString("ascii", i + 4, i + 8);
    const data = b.subarray(i + 8, i + 8 + len);
    if (type === "IHDR") {
      w = data.readUInt32BE(0);
      h = data.readUInt32BE(4);
      colorType = data[9];
    }
    if (type === "IDAT") idat.push(data);
    i += 12 + len;
  }
  const bpp = colorType === 6 ? 4 : 3;
  const raw = inflateSync(Buffer.concat(idat));
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
  return { w, h, bpp, rgba: out };
}

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=400"><style>
body { margin: 0; font-size: 16px; font-family: Helvetica; line-height: 20px; color: black; }
.row { width: 200px; height: 20px; }
</style></head><body>
<div class="row" id="l1" style="text-align: start">ab</div>
<div class="row" id="l2" style="text-align: end">ab</div>
<div class="row" id="l3" style="direction: rtl; text-align: start">ab</div>
<div class="row" id="l4" style="direction: rtl; text-align: end">ab</div>
<div class="row" id="l5" style="direction: rtl">ab</div>
<div class="row" id="l6" style="direction: rtl; text-align: left">ab</div>
<div class="row" id="l7" style="direction: rtl; text-align: right">ab</div>
<div class="row" id="l8" dir="rtl">ab</div>
<div class="row" id="l9"><span id="in9" style="direction: rtl">ab</span></div>
<div class="row" id="t1" style="text-indent: 20px">ab</div>
<div class="row" id="t2" style="direction: rtl; text-indent: 20px">ab</div>
<div class="row" id="l10" style="writing-mode: horizontal-tb; text-align: end">ab</div>
<div class="row" id="a1" dir="auto">שלום</div>
<div class="row" id="a2" dir="auto">abc</div>
<div class="row" id="a3"><bdi id="a3b">שלום</bdi></div>
<div class="row" id="a4" dir="auto">123</div>
<input id="a5" dir="auto" value="שלום">
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const ids = ["l1", "l2", "l3", "l4", "l5", "l6", "l7", "l8", "l9", "in9", "t1", "t2", "l10", "a1", "a2", "a3b", "a4", "a5"];
const out: string[] = [];
requestAnimationFrame(() => {
  for (const id of ids) {
    const box = document.getElementById(id)!;
    const r = box.getBoundingClientRect();
    const cs = getComputedStyle(box);
    out.push(id + "=" + r.top.toFixed(1) + "," + cs.direction + "," + cs.textAlign + "," + cs.writingMode);
  }
  console.log(out.join("\\n"));
});
`;

const dir = mkdtempSync(join(tmpdir(), "native-direction-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const png = join(dir, "out.png");
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png, NATIVE_STEPS: "frame | frame" } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const img = decodePng(png);

interface Info {
  top: number;
  direction: string;
  align: string;
  mode: string;
}
const logged: Record<string, Info> = {};
for (const line of r.stdout.split("\n")) {
  const m = /^([a-z0-9]+)=(.*)$/.exec(line.trim());
  if (m === null) continue;
  const parts = m[2].split(",");
  logged[m[1]] = { top: Number(parts[0]), direction: parts[1], align: parts[2], mode: parts[3] };
}

const scale = img.w / 400;

/** The leftmost and rightmost ink in the row of an element, in CSS pixels. */
function ink(id: string): { left: number; right: number } {
  const top = Math.round(logged[id].top * scale);
  const bottom = Math.round((logged[id].top + 20) * scale);
  let left = img.w;
  let right = -1;
  for (let y = top; y < bottom && y < img.h; y++) {
    for (let x = 0; x < img.w; x++) {
      const o = (y * img.w + x) * img.bpp;
      if (img.rgba[o] >= 245 && img.rgba[o + 1] >= 245 && img.rgba[o + 2] >= 245) continue;
      if (x < left) left = x;
      if (x > right) right = x;
    }
  }
  return { left: left / scale, right: right / scale };
}

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}
const atLeft = (id: string): boolean => ink(id).left < 1.5 && ink(id).right < 100;
const atRight = (id: string): boolean => ink(id).right > 198.5;
const span = (id: string): string => {
  const i = ink(id);
  return `${i.left.toFixed(1)}..${i.right.toFixed(1)}`;
};

check("text-align: start lines the text up at the left in ltr",
  atLeft("l1"), span("l1"));
check("text-align: end lines it up at the right in ltr",
  atRight("l2"), span("l2"));
check("text-align: start lines it up at the right in rtl",
  atRight("l3"), span("l3"));
check("text-align: end lines it up at the left in rtl",
  atLeft("l4"), span("l4"));
check("an rtl block that names no text-align starts at the right",
  atRight("l5"), span("l5"));
check("text-align: left stays at the left in rtl",
  atLeft("l6"), span("l6"));
check("text-align: right stays at the right in rtl",
  atRight("l7"), span("l7"));
check("the dir attribute sets the direction",
  atRight("l8") && logged["l8"].direction === "rtl", `${span("l8")}, ${logged["l8"].direction}`);
check("direction is inherited by a child that sets only itself to rtl",
  logged["in9"]?.direction === "rtl", logged["in9"]?.direction);

check("text-align computes to the keyword it was given",
  logged["l1"].align === "start" && logged["l2"].align === "end" &&
  logged["l6"].align === "left" && logged["l7"].align === "right",
  [logged["l1"].align, logged["l2"].align, logged["l6"].align, logged["l7"].align].join(", "));
check("dir=auto reads the first strong character: rtl text", logged["a1"].direction === "rtl", logged["a1"].direction);
check("dir=auto reads the first strong character: latin text", logged["a2"].direction === "ltr", logged["a2"].direction);
check("bdi takes its direction from its text", logged["a3b"].direction === "rtl", logged["a3b"].direction);
check("dir=auto with no strong character keeps the inherited direction", logged["a4"].direction === "ltr", logged["a4"].direction);
check("a field reads dir=auto from its value", logged["a5"].direction === "rtl", logged["a5"].direction);

check("direction computes to a keyword",
  logged["l1"].direction === "ltr" && logged["l5"].direction === "rtl",
  `${logged["l1"].direction}, ${logged["l5"].direction}`);

check("text-indent moves the start edge of the first line in ltr",
  Math.abs(ink("t1").left - 20) < 1.5, span("t1"));
check("an rtl first line takes its text-indent off the right edge",
  Math.abs(ink("t2").right - 180) < 1.5, span("t2"));
check("writing-mode computes to horizontal-tb",
  logged["l1"].mode === "horizontal-tb" && logged["l10"].mode === "horizontal-tb",
  `${logged["l1"].mode}, ${logged["l10"].mode}`);
check("horizontal-tb is laid out like any other line",
  atRight("l10"), span("l10"));

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
