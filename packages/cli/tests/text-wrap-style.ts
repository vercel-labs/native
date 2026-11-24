// text-wrap and hyphens: a balanced block spreads its words evenly over the lines it wraps to,
// a pretty one doesn't end on a lone word, `nowrap` keeps the text on one line, and a soft hyphen
// is a break opportunity with the mark drawn only where the break is taken.
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

/** The spans of a paragraph of words, one span each: words of one width, so a balanced line is
 * told apart from a wrapped one by the words it holds. */
function words(n: number): string {
  const out: string[] = [];
  for (let i = 0; i < n; i++) out.push("<span>aaa</span>");
  return out.join(" ");
}

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=600, height=1700"><style>
body { margin: 0; font-size: 16px; font-family: Helvetica; line-height: 20px; color: black; }
.row { width: 200px; }
.big { font-size: 40px; line-height: 50px; width: 60px; height: 100px; }
</style></head><body>
<div class="row" id="w1">${words(9)}</div>
<div class="row" id="b1" style="text-wrap: balance">${words(9)}</div>
<div class="row" id="w2">${words(16)}</div>
<div class="row" id="b2" style="text-wrap: balance">${words(16)}</div>
<div class="row" id="w6">${words(33)}</div>
<div class="row" id="b6" style="text-wrap: balance">${words(33)}</div>
<div class="row" id="w7">${words(37)}</div>
<div class="row" id="b7" style="text-wrap: balance">${words(37)}</div>
<div class="row" id="w3">${words(7)}</div>
<div class="row" id="p3" style="text-wrap: pretty">${words(7)}</div>
<div class="row" id="w4">${words(8)}</div>
<div class="row" id="p4" style="text-wrap: pretty">${words(8)}</div>
<div class="row" id="n1" style="text-wrap: nowrap">${words(16)}</div>
<div class="row" id="n2" style="white-space: nowrap">${words(16)}</div>
<div class="row" id="n3" style="text-wrap: nowrap; white-space: normal">${words(16)}</div>
<div class="row" id="n4" style="text-wrap: balance; white-space: nowrap">${words(16)}</div>
<div class="big" id="h1" style="hyphens: manual">hy&#173;phen</div>
<div class="big" id="h2" style="hyphens: none">hy&#173;phen</div>
<div class="big" id="h3" style="hyphens: auto">hy&#173;phen</div>
<div class="big" id="h4" style="width: 200px">hy&#173;phen</div>
<div class="big" id="h5">hyphen</div>
<div class="big" id="h6">hy-</div>
<div class="big" id="h7">hy</div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
interface Stats { words: number; left: number; right: number; top: number; }
const box = (id: string) => document.getElementById(id)!;
function stats(id: string): Stats[] {
  const el = box(id);
  const out: Stats[] = [];
  for (let i = 0; i < el.children.length; i++) {
    const rects = el.children[i].getClientRects();
    for (const r of rects) {
      const t = Math.round(r.top);
      let k = -1;
      for (let j = 0; j < out.length; j++) if (out[j].top === t) k = j;
      if (k < 0) out.push({ words: 1, left: r.left, right: r.right, top: t });
      else {
        const s = out[k];
        s.words++;
        if (r.left < s.left) s.left = r.left;
        if (r.right > s.right) s.right = r.right;
      }
    }
  }
  return out;
}
requestAnimationFrame(() => {
  requestAnimationFrame(() => {
    const out: string[] = [];
    for (const id of ["w1", "b1", "w2", "b2", "w6", "b6", "w7", "b7", "w3", "p3", "w4", "p4",
      "n1", "n2", "n3", "n4", "h1", "h2", "h3", "h4", "h5", "h6", "h7"]) {
      const st = stats(id);
      const parts: string[] = [];
      for (const s of st) parts.push(s.words + ":" + (s.right - s.left).toFixed(1));
      out.push(id + "=" + parts.join(","));
    }
    for (const id of ["w1", "b1", "n1", "n2", "n3", "n4", "h1", "h2", "h3", "h4", "h5", "h6", "h7"]) {
      out.push("r" + id + "=" + box(id).getBoundingClientRect().top.toFixed(1) + "/" + box(id).getBoundingClientRect().height.toFixed(1));
    }
    for (const id of ["w1", "b1", "n1", "n2", "n3", "n4", "h1", "h2", "h3", "h4"]) {
      const cs = getComputedStyle(box(id));
      out.push("t" + id + "=" + cs.textWrap + "|" + cs.hyphens + "|" + cs.whiteSpace);
    }
    console.log(out.join("\\n"));
  });
});
`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-wrap-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const png = join(dir, "out.png");
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png, NATIVE_STEPS: "frame | frame" } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const img = decodePng(png);

interface Line {
  words: number;
  width: number;
}
const logged: Record<string, string> = {};
for (const line of r.stdout.split("\n")) {
  const m = /^([a-z0-9]+)=(.*)$/.exec(line.trim());
  if (m) logged[m[1]] = m[2];
}

/** The lines of a paragraph: their words, and the width from the first word to the last. */
function lines(id: string): Line[] {
  const text = logged[id] ?? "";
  return text.split(",").map((p) => {
    const [w, width] = p.split(":");
    return { words: Number(w), width: Number(width) };
  });
}
/** A paragraph's height, in line boxes of 20px. */
function lineCount(id: string): number {
  return Number((logged["r" + id] ?? "0/0").split("/")[1]) / 20;
}
function computed(id: string): string[] {
  return (logged["t" + id] ?? "").split("|");
}
const spread = (ls: Line[]): number => {
  let lo = Number.POSITIVE_INFINITY;
  let hi = 0;
  for (const l of ls) {
    if (l.width < lo) lo = l.width;
    if (l.width > hi) hi = l.width;
  }
  return hi - lo;
};
const same = (a: Line[], b: Line[]): boolean => {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) {
    if (a[i].words !== b[i].words || Math.abs(a[i].width - b[i].width) > 0.2) return false;
  }
  return true;
};

// The snapshot is taken at the display's backing scale, so one CSS pixel is `scale` image pixels.
const scale = img.w / 600;
/** The ink of one 50px band of a big row, in CSS pixels. */
function ink(id: string, line: number): { count: number; left: number; right: number } {
  const top = Math.round((Number((logged["r" + id] ?? "0/0").split("/")[0]) + line * 50) * scale);
  const bottom = Math.round((Number((logged["r" + id] ?? "0/0").split("/")[0]) + (line + 1) * 50) * scale);
  let count = 0;
  let left = img.w;
  let right = -1;
  for (let y = top; y < bottom && y < img.h; y++) {
    for (let x = 0; x < img.w; x++) {
      const o = (y * img.w + x) * img.bpp;
      if (img.rgba[o] >= 245 && img.rgba[o + 1] >= 245 && img.rgba[o + 2] >= 245) continue;
      count++;
      if (x < left) left = x;
      if (x > right) right = x;
    }
  }
  return { count, left: left / scale, right: right / scale };
}
/** Whether a 40px row's 50px line box below the first holds any ink: a second line. */
const secondLine = (id: string): boolean => ink(id, 1).count > 0;

check("a balanced block keeps the number of lines it wraps to",
  lineCount("b1") === lineCount("w1") && lineCount("b2") === lineCount("w2"),
  `${lineCount("b1")} against ${lineCount("w1")}, and ${lineCount("b2")} against ${lineCount("w2")}`);
check("balance evens out the lines",
  spread(lines("b1")) < spread(lines("w1")) / 2,
  `balanced lines spread ${spread(lines("b1")).toFixed(1)}px, wrapped ones ${spread(lines("w1")).toFixed(1)}px`);
check("balance spreads the words over the lines",
  lines("b1")[0].words < lines("w1")[0].words && lines("b1")[1].words > lines("w1")[1].words,
  `${lines("b1").map((l) => l.words).join("/")} against ${lines("w1").map((l) => l.words).join("/")}`);
check("balance evens out a block of three lines too",
  spread(lines("b2")) < spread(lines("w2")) / 2 && lines("b2").length === 3,
  `balanced ${lines("b2").map((l) => l.width.toFixed(0)).join("/")}, wrapped ${lines("w2").map((l) => l.width.toFixed(0)).join("/")}`);
check("a block of six lines is balanced",
  spread(lines("b6")) < spread(lines("w6")) && lines("b6").length === 6,
  `balanced ${lines("b6").map((l) => l.width.toFixed(0)).join("/")}, wrapped ${lines("w6").map((l) => l.width.toFixed(0)).join("/")}`);
check("a block of more than six lines is left as it wrapped",
  same(lines("b7"), lines("w7")) && lines("b7").length === 7,
  `${lines("b7").map((l) => l.width.toFixed(0)).join("/")} against ${lines("w7").map((l) => l.width.toFixed(0)).join("/")}`);

check("pretty moves the word before a lone last word down",
  lines("p3").length === lines("w3").length && lines("p3")[lines("p3").length - 1].words === 2 &&
  lines("w3")[lines("w3").length - 1].words === 1,
  `${lines("p3").map((l) => l.words).join("/")} against ${lines("w3").map((l) => l.words).join("/")}`);
check("pretty leaves a last line of two words alone",
  same(lines("p4"), lines("w4")),
  `${lines("p4").map((l) => l.words).join("/")} against ${lines("w4").map((l) => l.words).join("/")}`);

check("text-wrap: nowrap keeps the text on one line",
  lineCount("n1") === 1 && lineCount("n2") === 1,
  `${lineCount("n1")} and ${lineCount("n2")} lines`);
check("text-wrap computes to the mode and style it names",
  computed("w1")[0] === "wrap" && computed("b1")[0] === "balance" && computed("n1")[0] === "nowrap",
  [computed("w1")[0], computed("b1")[0], computed("n1")[0]].join(", "));
check("white-space: nowrap shows in the computed text-wrap, and a later white-space resets it",
  computed("n2")[0] === "nowrap" && computed("n3")[0] === "wrap" && lineCount("n3") > 1,
  `${computed("n2")[0]}, then ${computed("n3")[0]} over ${lineCount("n3")} lines`);
check("a balanced block that may not wrap says both",
  computed("n4")[0] === "nowrap balance" && lineCount("n4") === 1,
  `${computed("n4")[0]} over ${lineCount("n4")} lines`);

check("a soft hyphen breaks the word when the line runs out",
  secondLine("h1"), "no second line");
check("hyphens: none takes the soft hyphen out and breaks nowhere",
  !secondLine("h2"), "the word broke anyway");
check("hyphens: auto breaks at the soft hyphen it finds",
  secondLine("h3"), "no second line");
check("hyphens computes to the keyword it was given",
  computed("h1")[1] === "manual" && computed("h2")[1] === "none" && computed("h3")[1] === "auto",
  [computed("h1")[1], computed("h2")[1], computed("h3")[1]].join(", "));
check("the break draws a mark past the letters it ends",
  ink("h1", 0).right > ink("h7", 0).right + 3,
  `the line ends at ${ink("h1", 0).right.toFixed(1)}px, \`hy\` alone at ${ink("h7", 0).right.toFixed(1)}px`);
check("the mark drawn is a hyphen",
  Math.abs(ink("h1", 0).right - ink("h6", 0).right) < 1.5,
  `${ink("h1", 0).right.toFixed(1)}px against a typed hyphen's ${ink("h6", 0).right.toFixed(1)}px`);
check("a soft hyphen that isn't needed draws nothing",
  !secondLine("h4") && Math.abs(ink("h4", 0).right - ink("h5", 0).right) < 1.5,
  `the word ends at ${ink("h4", 0).right.toFixed(1)}px with the soft hyphen, ${ink("h5", 0).right.toFixed(1)}px without`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
