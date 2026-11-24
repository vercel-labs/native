// `calc(<length> * <number>)` in `translate` and the transform functions: Tailwind v4's spacing
// scale is calc(var(--spacing) * N) with --spacing: 0.25rem, so a rem leaf has to keep its unit
// through the multiplication and resolve against the root's font size. The computed translate
// resolves those lengths to pixels and keeps percentages, as a browser reports it.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const PAGE = `<!doctype html>
<html><head><meta charset="utf-8"><style>
:root { --spacing: 0.25rem; }
body { margin: 0; font-size: 16px; }
div { position: absolute; left: 100px; top: 0; width: 10px; height: 10px; }
#a { translate: calc(0.25rem * 4) 0px; }
#b { translate: calc(1rem * 4) 0px; }
#c { transform: translateX(calc(0.25rem * 4)); }
#d { --tw-translate-x: calc(var(--spacing) * 4); --tw-translate-y: 0px;
     translate: var(--tw-translate-x) var(--tw-translate-y); }
#e { translate: calc(var(--spacing) * 8) 0px; }
#f { font-size: 20px; translate: 2em 0px; }
#g { translate: 50% 0px; }
#h { translate: calc(0.25rem * 4); }
#i { translate: calc(1px * 3 + 2px) 0px; }
#j { transform: translate(calc(0.25rem * 4), calc(0.5rem * 2)); }
#k { translate: calc(0.25rem * 4 + 0.5rem * 2) 0px; }
</style></head><body>
<div id="a"></div><div id="b"></div><div id="c"></div><div id="d"></div><div id="e"></div>
<div id="f"></div><div id="g"></div><div id="h"></div><div id="i"></div><div id="j"></div>
<div id="k"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const out: string[] = [];
for (const id of ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k"]) {
  const cs = getComputedStyle(document.getElementById(id)!);
  out.push(id + ".translate=" + cs.getPropertyValue("translate")
    + ";transform=" + cs.getPropertyValue("transform"));
}
console.log("OUT " + out.join("|"));
`;

const dir = mkdtempSync(join(tmpdir(), "native-translate-calc-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame | frame" } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const line = (r.stdout + r.stderr).split("\n").find((l) => l.startsWith("OUT ")) ?? "";
const values = new Map<string, string>();
for (const part of line.replace(/^OUT /, "").split("|")) {
  const k = part.indexOf(".");
  if (k > 0) values.set(part.slice(0, k), part.slice(k + 1));
}
const got = (id: string): string => values.get(id) ?? "";
const field = (id: string, name: string): string => {
  const at = got(id).indexOf(name + "=");
  if (at < 0) return "";
  const start = at + name.length + 1;
  const end = got(id).indexOf(";", start);
  return got(id).slice(start, end < 0 ? got(id).length : end);
};

check("calc(0.25rem * 4) translates 16px", field("a", "translate") === "translate(16px, 0px)"
  && field("a", "transform") === "matrix(1, 0, 0, 1, 16, 0)", got("a"));
check("calc(1rem * 4) multiplies to 64px", field("b", "translate") === "translate(64px, 0px)"
  && field("b", "transform") === "matrix(1, 0, 0, 1, 64, 0)", got("b"));
check("the calc in translateX reaches the matrix", field("c", "transform") === "matrix(1, 0, 0, 1, 16, 0)", got("c"));
check("Tailwind's var() form translates 16px", field("d", "translate") === "translate(16px, 0px)"
  && field("d", "transform") === "matrix(1, 0, 0, 1, 16, 0)", got("d"));
check("calc(var(--spacing) * 8) translates 32px", field("e", "translate") === "translate(32px, 0px)"
  && field("e", "transform") === "matrix(1, 0, 0, 1, 32, 0)", got("e"));
check("em resolves against the element's font size", field("f", "translate") === "translate(40px, 0px)"
  && field("f", "transform") === "matrix(1, 0, 0, 1, 40, 0)", got("f"));
check("percentages stay percentages as Chrome reports them", field("g", "translate") === "translate(50%, 0px)"
  && field("g", "transform") === "matrix(1, 0, 0, 1, 5, 0)", got("g"));
check("a one-value translate reports both axes", field("h", "translate") === "translate(16px, 0)", got("h"));
check("a remaining calc() folds to pixels", field("i", "translate") === "translate(5px, 0px)"
  && field("i", "transform") === "matrix(1, 0, 0, 1, 5, 0)", got("i"));
check("the transform function's pair translates both axes", field("j", "transform") === "matrix(1, 0, 0, 1, 16, 16)", got("j"));
check("two rem terms add and resolve", field("k", "translate") === "translate(32px, 0px)"
  && field("k", "transform") === "matrix(1, 0, 0, 1, 32, 0)", got("k"));

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
