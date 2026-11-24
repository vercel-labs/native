// The Preact todo app in examples/preact-todo, built natively and driven headlessly. Each step
// is a real pointer or keyboard event, and the app re-renders in a microtask, so the printed
// state and the snapshot show what a person would see after the step.
//   npm test

import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { inflateSync } from "node:zlib";

const APP = "../../examples/preact-todo";
const out = mkdtempSync(join(tmpdir(), "native-preact-"));

// The app's dependency is installed the way an app installs one.
if (!existsSync(join(APP, "node_modules", "preact"))) {
  const r = spawnSync("npm", ["install", "--no-audit", "--no-fund"], { cwd: APP, encoding: "utf8" });
  if (r.status !== 0) {
    console.error(r.stderr);
    throw new Error(`npm install in ${APP} failed`);
  }
}

const exe = join(out, "preact-todo");
const b = spawnSync("node", ["compiler/cli.ts", "build", APP, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) {
  console.error(b.stderr);
  throw new Error("build of the Preact app failed");
}

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

// Type and press Enter to add one, type and click Add for the other; then toggle the second by
// clicking its label, delete the first, and read the state back after each step. The mount
// effect focuses the field, so the frame step comes first.
const STEPS = [
  "frame 0",                  // the mount effect focuses the field
  "print #count",
  "type Buy milk", "key Enter",
  "print #count", "print #list", "print #new",
  "type Walk dog", "click #add",
  "print #count", "print #list",
  "click #label-2", "print #count", "print #label-2",
  "click #del-1", "print #list", "print #count",
].join(" | ");

const WANT = [
  "No todos",                 // the initial render
  "1 left of 1",              // Enter added the first
  "Buy milkx",                // its text, then the delete button's
  "",
  "2 left of 2",              // the Add button added the second
  "Buy milkxWalk dogx",
  "1 left of 2",              // clicking the label toggled it
  "Walk dog",
  "Walk dogx",                // deleting the first left the second
  "0 left of 1",
];

const png = join(out, "snapshot.png");
const r = spawnSync(exe, [], {
  encoding: "utf8",
  env: { ...process.env, NATIVE_STEPS: STEPS, NATIVE_SNAPSHOT: png },
});
if (r.status !== 0) console.error(r.stderr);
const got = r.stdout.split("\n").slice(0, -1);
check("steps run", r.status === 0, `exit ${r.status}`);
check(`printed state (${WANT.length} lines)`, JSON.stringify(got) === JSON.stringify(WANT), `got ${JSON.stringify(got)}`);

// The list is painted: dark text below the input row, and the remaining item's label struck
// through in grey.
function decodePng(path: string): { w: number; h: number; rgba: Uint8Array } {
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
  const rgba = new Uint8Array(w * h * bpp);
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
    rgba.set(cur, y * w * bpp);
    prev = cur;
  }
  return { w, h, rgba };
}

const img = decodePng(png);
// The snapshot is drawn at 2x; the list starts below the 16px padding and the 33px input row.
let grey = 0;
let red = 0;
for (let y = 120; y < 300; y++) {
  for (let x = 0; x < img.w; x++) {
    const o = (y * img.w + x) * 4;
    const v = img.rgba[o];
    if (v > 130 && v < 175) grey++;
    if (v > 190 && img.rgba[o + 1] < 120 && img.rgba[o + 2] < 110) red++;
  }
}
check("the row's delete button is drawn", red > 100, `${red} red pixels`);
check("the done item's label is drawn", grey > 100, `${grey} grey pixels`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
