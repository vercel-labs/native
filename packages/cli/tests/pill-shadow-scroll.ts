// A status pill inside a collapsing table row keeps its background and ring when the table's
// scroller moves. A collapsing table holds the inline-level boxes inside its cells back until it
// has painted its border grid; those held boxes are put down again under the clips their ancestors
// impose, and the clips are rectangles in page space, so a scroller's translation has to be taken
// out of them. Without that, every held pill is cut away by its scroller's clip once the page
// scrolls, while the surrounding cell text paints normally.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { inflateSync } from "node:zlib";

interface Image { w: number; h: number; rgba: Uint8Array }

function decodePng(path: string): Image {
  const b = readFileSync(path);
  let i = 8, w = 0, h = 0;
  const idat: Buffer[] = [];
  while (i < b.length) {
    const len = b.readUInt32BE(i);
    const type = b.toString("ascii", i + 4, i + 8);
    const data = b.subarray(i + 8, i + 8 + len);
    if (type === "IHDR") { w = data.readUInt32BE(0); h = data.readUInt32BE(4); }
    if (type === "IDAT") idat.push(data);
    i += 12 + len;
  }
  const raw = inflateSync(Buffer.concat(idat));
  const bpp = 4, stride = w * bpp + 1;
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
        const p = a + up - c, pa = Math.abs(p - a), pb = Math.abs(p - up), pc = Math.abs(p - c);
        v += pa <= pb && pa <= pc ? a : pb <= pc ? up : c;
      }
      cur[x] = v & 255;
    }
    out.set(cur, y * w * bpp);
    prev = cur;
  }
  return { w, h, rgba: out };
}

const COLORS = [
  { ring: [167, 243, 208], bg: [236, 253, 245] },
  { ring: [253, 230, 138], bg: [255, 251, 235] },
  { ring: [254, 205, 211], bg: [255, 241, 242] },
];

// The dashboard's shape: a flex column with a scrolling main, a collapsing table with row borders,
// and a rounded inline-flex status pill inside every cell.
const PAGE = `<!doctype html>
<html><head><meta charset="utf-8"><meta name="native-window" content="width=900, height=500"><style>
body { margin: 0; display: flex; height: 500px; }
#side { width: 180px; flex: none; background: #0f172a; }
#main { min-height: 0; flex: 1; overflow-y: auto; background: #f8fafc; padding: 0 24px; }
#spacer { height: 400px; }
table { width: 100%; border-collapse: collapse; text-align: left; }
tr { border-top: 1px solid #e2e8f0; }
td { padding: 12px; }
.pill { display: inline-flex; align-items: center; gap: 4px; padding: 2px 8px; border-radius: 9999px;
  font-size: 11px; font-weight: 500; }
.dot { width: 6px; height: 6px; border-radius: 9999px; background: currentColor; }
</style></head><body>
<div id="side"></div>
<div id="main"><div id="spacer"></div><table><tbody id="rows"></tbody></table></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const rows = document.getElementById("rows")!;
const colors = ${JSON.stringify(COLORS)};
const statuses = ["Live", "Live", "Building", "Live", "Error", "Building"];
for (let i = 0; i < 6; i++) {
  const tr = document.createElement("tr");
  const a = document.createElement("td"); a.textContent = "Project " + i;
  const b = document.createElement("td");
  const p = document.createElement("span");
  p.className = "pill";
  p.id = "p" + i;
  p.style.color = "rgb(" + colors[i % 3].ring.map((v: number) => Math.max(0, v - 140)).join(",") + ")";
  p.style.background = "rgb(" + colors[i % 3].bg.join(",") + ")";
  p.style.boxShadow = "0 0 0 1px rgb(" + colors[i % 3].ring.join(",") + ")";
  const dot = document.createElement("span"); dot.className = "dot";
  p.appendChild(dot);
  p.appendChild(document.createTextNode(statuses[i]));
  b.appendChild(p);
  const c = document.createElement("td"); c.textContent = "Owner " + i;
  tr.appendChild(a); tr.appendChild(b); tr.appendChild(c);
  rows.appendChild(tr);
}
const main = document.getElementById("main")!;
let n = 0;
const tick = () => {
  if (n === 2) main.scrollTop = 200;
  if (++n < 5) { requestAnimationFrame(tick); return; }
  const out: string[] = [];
  for (let i = 0; i < 6; i++) {
    const r = document.getElementById("p" + i)!.getBoundingClientRect();
    out.push(r.left + "," + r.top + "," + r.width + "," + r.height);
  }
  console.log("OUT " + out.join("|"));
};
requestAnimationFrame(tick);
`;

const dir = mkdtempSync(join(tmpdir(), "native-pill-shadow-scroll-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
const png = join(dir, "out.png");
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png, NATIVE_STEPS: "frame | frame | frame | frame | frame | frame" } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const img = decodePng(png);
const line = (r.stdout + r.stderr).split("\n").find((l) => l.startsWith("OUT ")) ?? "";
const rects = line.replace(/^OUT /, "").split("|").map((s) => s.split(",").map(Number));
const scale = img.w / 900;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}
const px = (x: number, y: number): number[] => {
  const o = (Math.round(y * scale) * img.w + Math.round(x * scale)) * 4;
  return [img.rgba[o], img.rgba[o + 1], img.rgba[o + 2]];
};
const near = (got: number[], want: number[], tol = 12): boolean =>
  got.every((g, i) => Math.abs(g - want[i]) <= tol);

check("the scroller moved", rects.length === 6 && rects[0][1] < 400, JSON.stringify(rects));
for (let i = 0; i < Math.min(6, rects.length); i++) {
  const [left, top, w, h] = rects[i];
  const cx = left + w / 2;
  const ring = px(cx, top - 1);
  const inside = px(left + 4, top + h / 2);
  check(`pill ${i}'s ring scrolls with its cell`, near(ring, COLORS[i % 3].ring), `got ${ring.join(",")} want ${COLORS[i % 3].ring.join(",")}`);
  check(`pill ${i}'s fill scrolls with its cell`, near(inside, COLORS[i % 3].bg), `got ${inside.join(",")} want ${COLORS[i % 3].bg.join(",")}`);
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
