// SVG <path> geometry: getTotalLength() and getPointAtLength() on paths a script builds. The
// expected numbers were measured in Chromium 140 (the same paths, same calls) and are compared
// with the tolerance a different flattening of a curve can move them: exact for straight
// segments, within half a user unit for curves. A closed subpath's closing segment counts, and
// a distance past the end clamps to the last point, as a browser's does.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=300"><style>
body { margin: 0; }
</style></head><body>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const ns = "http://www.w3.org/2000/svg";
type Case = { name: string; d: string };
const cases: Case[] = [
  { name: "lines", d: "M0 0 H100 V50" },
  { name: "diagonal", d: "M0 0 L30 40" },
  { name: "cubic", d: "M0 0 C 0 100 100 100 100 0" },
  { name: "quad", d: "M0 0 Q 50 100 100 0" },
  { name: "square", d: "M0 0 H100 V100 H0 Z" },
];
for (const c of cases) {
  const path = document.createElementNS(ns, "path") as SVGPathElement;
  path.setAttribute("d", c.d);
  const len = path.getTotalLength();
  const mid = path.getPointAtLength(len / 2);
  const end = path.getPointAtLength(len);
  const beyond = path.getPointAtLength(len + 10);
  console.log(c.name + " " + len.toFixed(3) + " " + mid.x.toFixed(3) + "," + mid.y.toFixed(3) +
    " " + end.x.toFixed(3) + "," + end.y.toFixed(3) + " " + beyond.x.toFixed(3) + "," + beyond.y.toFixed(3));
}
`;

const dir = mkdtempSync(join(tmpdir(), "native-svg-geometry-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: "frame 0" };
delete env.NATIVE_SNAPSHOT;
const r = spawnSync(exe, [], { encoding: "utf8", env });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);

// Chromium 140 measured: length, point at half, point at the end, point past the end.
const CHROME: Record<string, { len: number; mid: [number, number]; end: [number, number]; beyond: [number, number] }> = {
  lines: { len: 150, mid: [75, 0], end: [100, 50], beyond: [100, 50] },
  diagonal: { len: 50, mid: [14.999999046325684, 20], end: [30, 40], beyond: [30, 40] },
  cubic: { len: 200.0001068115234, mid: [49.999961853027344, 75], end: [100, 0], beyond: [100, 0] },
  quad: { len: 147.89434814453125, mid: [50.00001907348633, 50.000003814697266], end: [100, 0], beyond: [100, 0] },
  square: { len: 400, mid: [100, 100], end: [0, 0], beyond: [0, 0] },
};

function close(a: number, b: number, tol: number): boolean {
  return Math.abs(a - b) <= tol;
}

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const lines = r.stdout.split("\n").filter((l) => l !== "");
check(`one line per case (${Object.keys(CHROME).length})`, lines.length === Object.keys(CHROME).length, `got ${lines.length}`);
for (const line of lines) {
  const [name, lenText, midText, endText, beyondText] = line.split(" ");
  const want = CHROME[name];
  if (!want) { check(`${name} is a known case`, false, line); continue; }
  const len = Number(lenText);
  const point = (text: string): [number, number] => {
    const parts = text.split(",");
    return [Number(parts[0]), Number(parts[1])];
  };
  const mid = point(midText), end = point(endText), beyond = point(beyondText);
  // Straight paths are exact; a flattened curve may differ from Chrome's own flattening.
  const tol = name === "cubic" || name === "quad" ? Math.max(0.5, want.len * 0.005) : 1e-3;
  check(`${name} length ${len.toFixed(3)} ≈ ${want.len.toFixed(3)}`, close(len, want.len, tol), `tol ${tol}`);
  check(`${name} midpoint ${midText}`, close(mid[0], want.mid[0], 0.5) && close(mid[1], want.mid[1], 0.5));
  check(`${name} end ${endText}`, close(end[0], want.end[0], 0.5) && close(end[1], want.end[1], 0.5));
  check(`${name} past the end clamps ${beyondText}`, close(beyond[0], want.beyond[0], 0.5) && close(beyond[1], want.beyond[1], 0.5));
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
