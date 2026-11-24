// A vertical box with an auto inline size is as tall as the line its content makes along the page,
// whether that content is one run of text or several (an inline span splits it into fragments).
// The two boxes below hold the same two characters, so they must be the same height.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=400"><style>
body { margin: 0; font: 20px monospace; }
div { writing-mode: vertical-lr; margin: 8px; }
</style></head><body>
<div id="plain">AB</div>
<div id="split">A<span id="b">B</span></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function rect(id: string): string {
  const r = document.getElementById(id)!.getBoundingClientRect();
  return [r.left, r.top, r.width, r.height].map((n) => Math.round(n * 10) / 10).join(",");
}
console.log("OUT plain=" + rect("plain") + " split=" + rect("split") + " b=" + rect("b"));
`;

const dir = mkdtempSync(join(tmpdir(), "native-vertical-extent-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);
const run = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame 1" } });
if (run.status !== 0) throw new Error(`render failed\n${run.stderr}`);

const line = (run.stdout + run.stderr).split("\n").find((l) => l.startsWith("OUT ")) ?? "";
const got = line.replace(/^OUT /, "");
console.log(`     ${got}`);
const field = (name: string): string => {
  const at = got.indexOf(name + "=");
  if (at < 0) return "";
  const rest = got.slice(at + name.length + 1);
  const end = rest.indexOf(" ");
  return end < 0 ? rest : rest.slice(0, end);
};

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const at = (id: string): number[] => field(id).split(",").map((n) => Number(n));
const plain = at("plain");
const split = at("split");
// One glyph's advance along the page, which the split box shows as its own height.
const glyph = at("b")[3];

check("a vertical box holding one text run is as tall as the two glyphs it draws",
  Math.abs(plain[3] - 2 * glyph) < 1.5, `plain ${plain[3]} vs two glyphs ${2 * glyph}`);
check("a vertical box whose content is fragments is the same height",
  Math.abs(split[3] - plain[3]) < 1, `plain ${plain[3]} vs split ${split[3]}`);
check("and it is as wide as the line box it laid out", Math.abs(split[2] - plain[2]) < 1,
  `plain ${plain[2]} vs split ${split[2]}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
