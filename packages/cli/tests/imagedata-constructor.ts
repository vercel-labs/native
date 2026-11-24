// ImageData's two DOM constructor forms: `new ImageData(width, height[, data])` and
// `new ImageData(data, width[, height])`, the form a page writes when it converts pixels back
// from a canvas (a size-first-only constructor refused the second form with a type error).
// The data form's height follows from the buffer when it is omitted, and a buffer whose length
// does not match the size is an IndexSizeError, as a browser's constructor throws.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=300"><style>
body { margin: 0; }
</style></head><body>
<canvas id="c" width="4" height="2"></canvas>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const a = new ImageData(2, 3);
console.log("size " + a.width + "x" + a.height + " " + a.data.length + " " + a.data[0]);

const pixels = new Uint8ClampedArray([255, 0, 0, 255, 0, 255, 0, 255]);
const b = new ImageData(pixels, 2);
console.log("data " + b.width + "x" + b.height + " " + b.data.length + " " + b.data[0] + " " + b.data[5]);

const c = new ImageData(pixels, 2, 1);
console.log("sized " + c.width + "x" + c.height + " " + c.data.length);

let err = "none";
try {
  new ImageData(new Uint8ClampedArray(7), 2, 1);
} catch (e) {
  err = (e as Error).message.split(":")[0];
}
console.log("bad " + err);

// A canvas round trip through the data form: read the pixels, hand them back, write them down.
const ctx = (document.getElementById("c") as HTMLCanvasElement).getContext("2d")!;
ctx.fillStyle = "#ff0000";
ctx.fillRect(0, 0, 2, 1);
const read = ctx.getImageData(0, 0, 2, 1);
const copy = new ImageData(read.data, 2, 1);
console.log("round " + copy.width + "x" + copy.height + " " + copy.data[0] + "," + copy.data[1] + "," + copy.data[2] + "," + copy.data[3]);
`;

const dir = mkdtempSync(join(tmpdir(), "native-imagedata-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: "frame 0" };
delete env.NATIVE_SNAPSHOT;
const r = spawnSync(exe, [], { encoding: "utf8", env });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);

const EXPECTED = [
  "size 2x3 24 0",
  "data 2x1 8 255 255",
  "sized 2x1 8",
  "bad IndexSizeError",
  "round 2x1 255,0,0,255",
];

const got = r.stdout.split("\n").slice(0, -1);
for (const line of got) console.log(`     got ${JSON.stringify(line)}`);
let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}
check(`log lines (${EXPECTED.length})`, got.length === EXPECTED.length, `got ${got.length}`);
for (let i = 0; i < Math.min(got.length, EXPECTED.length); i++) {
  check(EXPECTED[i], got[i] === EXPECTED[i], `got ${JSON.stringify(got[i])}`);
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
