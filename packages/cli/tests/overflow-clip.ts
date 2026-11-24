// Clipping and scrollbar painting in a scrolling list: a scroller clips every descendant it
// contains, positioned rows included, and its scrollbar is drawn above them.
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

// The scroll container is at (20, 20) under a search box strip, and 200x100; a sticky 20px header
// sits in it, then six 30px relative rows, so its content is 200px tall and it scrolls by 80.
// Chrome lays the same page out with the container at [20, 20, 200, 100], the header at
// [20, 20, 200, 20] and the first row at [20, 40, 200, 30] (scrollWidth and scrollHeight both
// 200). With scrollTop 40 it answers elementFromPoint(150, 10) with the search box — a row that
// has scrolled out of the container is clipped, so it is not hit — and elementFromPoint(80, 80)
// with a row.
const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=240"><style>
body { margin: 0; font: 13px monospace; background: #fff; }
#top { height: 20px; background: #ffffff; }
#sc { margin-left: 20px; width: 200px; height: 100px; overflow: auto; background: #ffffff; }
.row { position: relative; height: 30px; background: #0000ff; }
.day { position: sticky; top: 0; height: 20px; background: #00ff00; z-index: 1; }
#below { position: absolute; left: 70px; top: 130px; width: 20px; height: 20px; background: #ffffff; }
</style></head><body>
<div id="top">top</div>
<div id="sc"><div class="day"></div>
<div class="row" id="r0"></div>
<div class="row" id="r1"></div>
<div class="row" id="r2"></div>
<div class="row" id="r3"></div>
<div class="row" id="r4"></div>
<div class="row" id="r5"></div>
</div>
<div id="below">none</div>
<script src="app.ts"></script>
</body></html>`;

// A click reports the element it reaches, as elementFromPoint does in a browser.
const SCRIPT = `
const sc = document.getElementById("sc")!;
const day = document.querySelector(".day")!;
const row = document.getElementById("r0")!;
const below = document.getElementById("below")!;
document.addEventListener("click", (e) => {
  const t = e.target as HTMLElement;
  below.textContent = t.id || t.className;
});
window.addEventListener("load", () => {
  const box = sc.getBoundingClientRect();
  const d = day.getBoundingClientRect();
  const r = row.getBoundingClientRect();
  console.log("geo=" + JSON.stringify({ sc: [box.left, box.top, box.width, box.height],
    day: [d.left, d.top, d.width, d.height], row: [r.left, r.top, r.width, r.height],
    sw: sc.scrollWidth, sh: sc.scrollHeight }));
});
`;

interface Geo {
  sc: number[];
  day: number[];
  row: number[];
  sw: number;
  sh: number;
}

function buildAndRun(): { img: Image; out: string } {
  const dir = mkdtempSync(join(tmpdir(), "native-overflow-clip-"));
  writeFileSync(join(dir, "index.html"), PAGE);
  writeFileSync(join(dir, "app.ts"), SCRIPT);
  const exe = join(dir, "app");
  const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
  if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
  const png = join(dir, "out.png");
  // Scroll the list by 40, then click below it and inside it: the clip is what decides which
  // element each click reaches.
  const steps = "wheel #sc 40 | scrolltop #sc | click #top | print #below | click #r2 | print #below";
  const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: steps, NATIVE_SNAPSHOT: png } });
  if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
  return { img: decodePng(png), out: `${r.stdout}${r.stderr}` };
}

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const { img, out } = buildAndRun();

/** Whether the pixel at a CSS coordinate is the row colour. */
function blue(x: number, y: number): boolean {
  const o = (Math.round(y * 2) * img.w + Math.round(x * 2)) * 4;
  return img.rgba[o] < 60 && img.rgba[o + 1] < 60 && img.rgba[o + 2] > 200;
}

/** Whether the pixel at a CSS coordinate is the sticky header's colour. */
function green(x: number, y: number): boolean {
  const o = (Math.round(y * 2) * img.w + Math.round(x * 2)) * 4;
  return img.rgba[o] < 60 && img.rgba[o + 1] > 200 && img.rgba[o + 2] < 60;
}

/** The blue channel at a CSS coordinate, for reading a thumb drawn over the rows. */
function blueChannel(x: number, y: number): number {
  return img.rgba[(Math.round(y * 2) * img.w + Math.round(x * 2)) * 4 + 2];
}

const lines = out.split("\n");
const geoLine = lines.find((l) => l.startsWith("geo="));
const geo: Geo = geoLine === undefined ? { sc: [], day: [], row: [], sw: NaN, sh: NaN } : JSON.parse(geoLine.slice(4));
const near = (a: number, b: number): boolean => Math.abs(a - b) <= 0.5;

check("the scroll container is laid out as Chrome lays it out",
  geo.sc.length === 4 && near(geo.sc[0], 20) && near(geo.sc[1], 20) && near(geo.sc[2], 200) && near(geo.sc[3], 100),
  JSON.stringify(geo.sc));
check("its contents are as tall as Chrome makes them", near(geo.sh, 200) && near(geo.sw, 200),
  `${geo.sw}x${geo.sh}`);
check("the sticky header sits at the top of the scrollport, as in Chrome",
  geo.day.length === 4 && near(geo.day[1], 20) && near(geo.day[3], 20), JSON.stringify(geo.day));
check("the first row starts under the header, as in Chrome",
  geo.row.length === 4 && near(geo.row[1], 40) && near(geo.row[3], 30), JSON.stringify(geo.row));

check("the list scrolled by 40", lines[1] === "40", `scrollTop ${lines[1]}`);

// With the list scrolled, the rows that have moved past the container's top edge are clipped:
// they paint nothing over the search box, and a click there reaches the search box, not a row.
check("a scrolled row paints nothing above its container", !blue(60, 5) && !blue(150, 10) && !blue(150, 18));
check("a click above the container reaches the search box, not the clipped row",
  lines[2] === "top", `hit ${lines[2]}`);
check("a click inside the container still reaches the row it is over", lines[3] === "r2", `hit ${lines[3]}`);
check("rows still paint inside the container", blue(60, 110) && blue(60, 100));
check("the sticky header stays over the rows", green(60, 30) && !blue(60, 30));

// The overlay scrollbar goes over the rows rather than under them: at the top of the thumb the
// pixel is the row's blue darkened by the thumb, and further down the same column is bare row.
check("the scrollbar paints above the rows", blueChannel(214, 60) < 220 && blueChannel(214, 105) > 240,
  `thumb ${blueChannel(214, 60)}, row ${blueChannel(214, 105)}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
