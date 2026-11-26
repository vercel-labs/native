// A class a script adds to an element it created must bring that class's rule into effect. The
// rules a created element may match are worked out when it is made; a later className change names
// rules that were never in that set, so the element has to have them worked out again (a renderer
// that controls a style from state does this on every update).   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { inflateSync } from "node:zlib";

const PAGE = `<!doctype html>
<html><head><meta charset="utf-8"><meta name="native-window" content="width=200, height=120"><style>
body { margin: 0; background: #ffffff; }
.swatch { width: 80px; height: 60px; background-color: #eeeeee; }
.swatch.on { background-color: #ff0000; }
</style></head><body><script src="app.ts"></script></body></html>`;

const SCRIPT = `
// The swatch is made by script, the way a renderer makes its elements.
const swatch = document.createElement("div");
swatch.id = "swatch";
swatch.className = "swatch";
document.body.appendChild(swatch);
swatch.addEventListener("click", () => { swatch.className = "swatch on"; });
`;

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

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-created-class-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const png = join(dir, "out.png");
const run = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame 0 | click #swatch | frame 16", NATIVE_SNAPSHOT: png } });
if (run.status !== 0) throw new Error(`run failed\n${run.stderr}`);

// The snapshot draws at twice the CSS size; the swatch covers CSS (0,0)-(80,60).
const img = decodePng(png);
const at = (x: number, y: number): string => {
  const o = (y * img.w + x) * 4;
  return `${img.rgba[o]},${img.rgba[o + 1]},${img.rgba[o + 2]}`;
};
check("a class added to a created element brings its rule into effect", at(40, 40) === "255,0,0", `got ${at(40, 40)}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
