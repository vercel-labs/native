// `vertical-align: top` and `bottom` name the line box's over and under sides, and in vertical text
// the over side is the page's right — the page's left in sideways-lr (css-writing-modes 6.4) — not
// the frame's own block-start. Each box below holds one 40px line box, the div's whole content box,
// and a 10px box aligned to one of those sides, so the span's page position says which side it took.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=400"><style>
body { margin: 0; font: 20px/2 monospace; }
div { width: 40px; height: 70px; margin: 8px; }
div span { font-size: 10px; }
#vlr-top { writing-mode: vertical-lr; }
#vlr-bottom { writing-mode: vertical-lr; }
#vrl-top { writing-mode: vertical-rl; }
#vrl-bottom { writing-mode: vertical-rl; }
#slr-top { writing-mode: sideways-lr; }
#slr-bottom { writing-mode: sideways-lr; }
#vlr-top span, #vrl-top span, #slr-top span { vertical-align: top; }
#vlr-bottom span, #vrl-bottom span, #slr-bottom span { vertical-align: bottom; }
</style></head><body>
<div id="vlr-top">A<span id="o1">O</span></div>
<div id="vlr-bottom">A<span id="o2">O</span></div>
<div id="vrl-top">A<span id="o3">O</span></div>
<div id="vrl-bottom">A<span id="o4">O</span></div>
<div id="slr-top">A<span id="o5">O</span></div>
<div id="slr-bottom">A<span id="o6">O</span></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function rect(id: string): string {
  const r = document.getElementById(id)!.getBoundingClientRect();
  return [r.left, r.top, r.width, r.height].map((n) => Math.round(n * 10) / 10).join(",");
}
console.log("OUT " + ["vlr-top", "o1", "vlr-bottom", "o2", "vrl-top", "o3", "vrl-bottom", "o4",
  "slr-top", "o5", "slr-bottom", "o6"].map((id) => id + "=" + rect(id)).join(" "));
`;

const dir = mkdtempSync(join(tmpdir(), "native-vertical-align-vertical-"));
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
/** The span's centre relative to its box's: negative towards the page's left. */
function side(box: string, span: string): number {
  const b = at(box), s = at(span);
  return s[0] + s[2] / 2 - (b[0] + b[2] / 2);
}

check("a vertical-lr box puts a top-aligned box on the page's right (its over side)",
  side("vlr-top", "o1") > 0, field("o1"));
check("and a bottom-aligned one on the page's left",
  side("vlr-bottom", "o2") < 0, field("o2"));
check("a vertical-rl box puts a top-aligned box on the page's right too",
  side("vrl-top", "o3") > 0, field("o3"));
check("and a bottom-aligned one on the page's left",
  side("vrl-bottom", "o4") < 0, field("o4"));
check("a sideways-lr box puts a top-aligned box on the page's left (its over side)",
  side("slr-top", "o5") < 0, field("o5"));
check("and a bottom-aligned one on the page's right",
  side("slr-bottom", "o6") > 0, field("o6"));

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
