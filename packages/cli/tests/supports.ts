// @supports: a condition holds when every declaration in it compiles here, so a guard for a
// feature this build lacks (-webkit-hyphens, margin-trim) fails, and one for a feature it has
// (color-mix(), display: flex) holds. A nested @supports group inside a rule applies its
// declarations in place when it holds, which is how Tailwind upgrades a colour.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=200, height=260"><style>
body { margin: 0; }
div { height: 20px; background: #000000; }
@supports (display: flex) { #a { background: #ff0000; } }
@supports (not (display: flex)) { #a { background: #00ff00; } }
@supports (color: color-mix(in lab, red, red)) { #b { background: #0000ff; } }
@supports (color: rgb(from red r g b)) { #b { background: #00ffff; } }
@supports ((-webkit-hyphens: none) and (not (margin-trim: block))) { #c { background: #ff00ff; } }
/* A custom property's value has to be a <declaration-value>: a top-level ";" or "!" inside a
   var() fallback makes the declaration invalid, an empty value is valid, and "--" is no name. */
@supports (--a: a) and (not (--a: var(--b,!))) { #f { background: #00ff00; } }
@supports (--a: ) { #g { background: #00ffff; } }
@supports (--: a) { #h { background: #ff0000; } }
@supports (color: var(--a)) and (not (color: var(--a);)) { #i { background: #ffff00; } }
#d { background: #123456; @supports (color: color-mix(in lab, red, red)) { background: #654321; } }
#e { background: #111111; @supports (color: rgb(from red r g b)) { background: #222222; } }
</style></head><body>
<div id="a"></div><div id="b"></div><div id="c"></div><div id="d"></div><div id="e"></div>
<div id="f"></div><div id="g"></div><div id="h"></div><div id="i"></div>
</body></html>`;

// One entry per div: most carry two guards, one that holds here and one that doesn't, so the
// colour shows that the holding rule applied and the failing one was dropped.
const EXPECTED: [string, string][] = [
  ["#a: (display: flex) holds, its not() doesn't", "255,0,0"],
  ["#b: color-mix() and rgb(from …) both parse here", "0,255,255"],
  ["#c: a browser-only guard doesn't hold", "0,0,0"],
  ["#d: a nested @supports that holds applies", "101,67,33"],
  ["#e: a nested @supports that parses applies", "34,34,34"],
  ["#f: a var() fallback with a top-level ! is invalid", "0,255,0"],
  ["#g: an empty custom property value is valid", "0,255,255"],
  ["#h: -- is not a custom property name", "0,0,0"],
  ["#i: a top-level ; in the value is invalid", "255,255,0"],
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-supports-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
check("the build reports the guard that doesn't hold", b.stderr.includes("doesn't hold here"),
  b.stderr.slice(0, 200));
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: join(dir, "out.png") } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const img = decodePng(join(dir, "out.png"));
const colorAt = (y: number): string => {
  const o = (y * img.w + 100) * 4;
  return `${img.rgba[o]},${img.rgba[o + 1]},${img.rgba[o + 2]}`;
};
EXPECTED.forEach(([name, want], i) => {
  const got = colorAt(40 * i + 20);
  check(name, got === want, `got ${got}, want ${want}`);
});

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
