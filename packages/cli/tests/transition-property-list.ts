// transition-property takes any property name, as CSS says: a longhand, a shorthand, a custom
// property or one this build doesn't animate. A name it can't interpolate still belongs in the
// list, and dropping the declaration must not collapse it to the initial `all`. Tailwind v4's
// `transition` utility lists shorthands and custom properties, so this keeps its list intact.
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

const TAILWIND_TRANSITION = "color, background-color, border-color, outline-color, " +
  "text-decoration-color, fill, stroke, --tw-gradient-from, --tw-gradient-via, --tw-gradient-to, " +
  "opacity, box-shadow, transform, translate, scale, rotate, filter, -webkit-backdrop-filter, " +
  "backdrop-filter, display, content-visibility, overlay, pointer-events";

const PAGE = `<!doctype html>
<html><head><meta charset="utf-8"><style>
body { margin: 0; }
#a { transition-property: ${TAILWIND_TRANSITION}; }
#b { transition-property: transform, translate, scale, rotate; }
#c { transition-property: color, --x; }
#d { transition-property: border-color, filter; }
#e { transition-property: all; }
#f { transition-property: none; }
#g { transition: color 150ms; }
#h { transition-property: color, background-color; }
</style></head><body>
<div id="a">a</div><div id="b">b</div><div id="c">c</div><div id="d">d</div>
<div id="e">e</div><div id="f">f</div><div id="g">g</div><div id="h">h</div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const out: string[] = [];
for (const id of ["a", "b", "c", "d", "e", "f", "g", "h"]) {
  const cs = getComputedStyle(document.getElementById(id)!);
  out.push(id + "=" + cs.getPropertyValue("transition-property"));
}
console.log("OUT " + out.join("|"));
`;

const dir = mkdtempSync(join(tmpdir(), "native-transition-property-list-"));
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
  const at = part.indexOf("=");
  if (at > 0) values.set(part.slice(0, at), part.slice(at + 1));
}
const got = (id: string): string => values.get(id) ?? "";

check("Tailwind's transition utility keeps its whole list", got("a") === TAILWIND_TRANSITION, got("a"));
check("an animatable list keeps its order", got("b") === "transform, translate, scale, rotate", got("b"));
check("a custom property is a valid name", got("c") === "color, --x", got("c"));
check("a shorthand and an unanimated property stay listed", got("d") === "border-color, filter", got("d"));
check("all stands alone", got("e") === "all", got("e"));
check("none stands alone", got("f") === "none", got("f"));
check("the transition shorthand keeps its property", got("g") === "color", got("g"));
check("a plain pair is unchanged", got("h") === "color, background-color", got("h"));

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
