// CSS Nesting: a rule's body may hold nested style rules (with `&` or a descendant selector) and
// the conditional at-rules @media, @supports, @container and @starting-style, whose declarations
// apply to the parent selector inside the condition.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=200, height=200"><style>
body { margin: 0; }
div { height: 20px; background: #000000; }
#a { background: #ff0000; @media (min-width: 1px) { background: #00ff00; } }
#b { background: #0000ff; @media (min-width: 9999px) { background: #00ffff; } }
#c { background: #101010; .kid { background: #0000ff; } }
#d { background: #202020; &:where(.on) { background: #00ff00; } }
#e { background: #303030; }
#wrap { container-type: inline-size; }
#e { @container (min-width: 1px) { background: #00ffff; } }
#f { background: #404040; @starting-style { background: #ff00ff; } }
</style></head><body>
<div id="a"></div><div id="b"></div><div id="c"><div class="kid"></div></div><div id="d" class="on"></div>
<div id="wrap"><div id="e"></div></div><div id="f"></div>
</body></html>`;

const EXPECTED: [string, string][] = [
  ["#a: a nested @media that holds applies", "0,255,0"],
  ["#b: a nested @media that doesn't match leaves the rule", "0,0,255"],
  ["#c: a nested descendant selector styles the child", "0,0,255"],
  ["#d: a nested '&' selector matches the parent", "0,255,0"],
  ["#e: a nested @container applies inside its container", "0,255,255"],
  ["#f: a nested @starting-style is accepted and settles", "64,64,64"],
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-nesting-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
check("the build takes nested rules and at-rules without an unsupported warning",
  !b.stderr.includes("is not supported yet"), b.stderr.slice(0, 400));
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: join(dir, "out.png") } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const img = decodePng(join(dir, "out.png"));
// Rows are 20 CSS px tall and the snapshot draws at 2x, so a row's middle is 40 px below the
// previous one in the image.
const colorAt = (row: number): string => {
  const o = (row * 40 + 20) * img.w * 4 + 100 * 4;
  return `${img.rgba[o]},${img.rgba[o + 1]},${img.rgba[o + 2]}`;
};
const rows = [0, 1, 2, 3, 4, 5];
EXPECTED.forEach(([name, want], i) => {
  const got = colorAt(rows[i]);
  check(name, got === want, `got ${got}, want ${want}`);
});

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
