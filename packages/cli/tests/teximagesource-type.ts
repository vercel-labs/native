// TexImageSource: the pixel-source union WebGL's texture uploads take. A three.js canvas layer
// annotates its texImage2D wrapper with this name, and without it the whole layer failed to
// compile ("Cannot find name 'TexImageSource'"). The runtime's sources are an ImageData, an
// <img> and a <canvas> — the three it can hand the host — so the name must type all three and
// flow through a parameter unchanged.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=300"><style>
body { margin: 0; }
</style></head><body>
<img id="i">
<canvas id="c" width="2" height="2"></canvas>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const img = document.getElementById("i") as HTMLImageElement;
const canvas = document.getElementById("c") as HTMLCanvasElement;
const data = new ImageData(1, 1);
const a: TexImageSource = img;
const b: TexImageSource = canvas;
const c: TexImageSource = data;
console.log("assigned " + String(a === img) + " " + String(b === canvas) + " " + String(c === data));
function which(source: TexImageSource): string {
  return source === img ? "img" : source === canvas ? "canvas" : source === data ? "data" : "other";
}
console.log("takes " + which(img) + " " + which(canvas) + " " + which(data));
const list: TexImageSource[] = [data, canvas, img];
console.log("array " + list.length + " " + which(list[2]!));
`;

const dir = mkdtempSync(join(tmpdir(), "native-teximagesource-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: "frame 0" };
delete env.NATIVE_SNAPSHOT;
const r = spawnSync(exe, [], { encoding: "utf8", env });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);

const EXPECTED = ["assigned true true true", "takes img canvas data", "array 3 img"];
const got = r.stdout.split("\n").slice(0, -1);
for (const line of got) console.log(`     got ${JSON.stringify(line)}`);
let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}
check(`log lines (${EXPECTED.length})`, got.length === EXPECTED.length, `got ${got.length}`);
for (let i = 0; i < Math.min(got.length, EXPECTED.length); i++) check(EXPECTED[i], got[i] === EXPECTED[i], `got ${JSON.stringify(got[i])}`);
console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
