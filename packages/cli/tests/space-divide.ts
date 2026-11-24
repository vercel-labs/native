// Tailwind v4's space-y-* and divide-y-* utilities: a `:where(... > :not(:last-child))` rule,
// nested as `:where(& > :not(:last-child))` or written whole, whose logical margins and borders
// come from calc() over the spacing scale. The margin spaces the children, and the divide border
// sits between them, as in a browser.
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
<html><head><meta charset="utf-8"><meta name="native-window" content="width=300, height=400"><style>
:root { --spacing: 0.25rem; }
body { margin: 0; font-size: 16px; }
@property --tw-space-y-reverse { syntax: "*"; inherits: false; initial-value: 0; }
@property --tw-divide-y-reverse { syntax: "*"; inherits: false; initial-value: 0; }
@property --tw-border-style { syntax: "*"; inherits: false; initial-value: solid; }
#space > div, #space2 > div, #divide > div { height: 10px; }
/* the shape Tailwind v4 writes for space-y-4, nested with the parent's & */
.space-y-4 {
  :where(& > :not(:last-child)) {
    --tw-space-y-reverse: 0;
    margin-block-start: calc(calc(var(--spacing) * 4) * var(--tw-space-y-reverse));
    margin-block-end: calc(calc(var(--spacing) * 4) * calc(1 - var(--tw-space-y-reverse)));
  }
}
/* the flattened shape: the class on the parent inside :where() */
:where(.divide-y > :not(:last-child)) {
  --tw-divide-y-reverse: 0;
  border-top-style: var(--tw-border-style);
  border-bottom-style: var(--tw-border-style);
  border-top-width: calc(1px * var(--tw-divide-y-reverse));
  border-bottom-width: calc(1px * calc(1 - var(--tw-divide-y-reverse)));
}
/* the repro's longhand, on inline children */
#space2 > :not(:last-child) { margin-block-start: calc(0.25rem * 4); }
</style></head><body>
<div id="space" class="space-y-4"><div>a</div><div>b</div><div>c</div></div>
<div id="divide" class="divide-y"><div>a</div><div>b</div><div>c</div></div>
<div id="space2"><span>a</span><span>b</span></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const kids = (id: string): Element[] => Array.from(document.getElementById(id)!.children);
const at = (id: string, i: number): CSSStyleDeclaration => getComputedStyle(kids(id)[i]);
// The distance from one child's top to the next, so a margin or a border on the first shows up.
const gaps = (id: string): number[] => {
  const k = kids(id) as HTMLElement[];
  const out: number[] = [];
  for (let i = 1; i < k.length; i++) out.push(k[i].getBoundingClientRect().top - k[i - 1].getBoundingClientRect().top);
  return out;
};
const out: string[] = [];
const s0 = at("space", 0);
out.push("space.start=" + s0.getPropertyValue("margin-block-start"));
out.push("space.end=" + s0.getPropertyValue("margin-block-end"));
out.push("space.last-end=" + at("space", 2).getPropertyValue("margin-block-end"));
out.push("space.gaps=" + gaps("space").join(","));
const d0 = at("divide", 0), d1 = at("divide", 1);
out.push("divide.bottom=" + d0.getPropertyValue("border-bottom-width"));
out.push("divide.top=" + d0.getPropertyValue("border-top-width"));
out.push("divide.last-bottom=" + at("divide", 2).getPropertyValue("border-bottom-width"));
out.push("divide.style=" + d0.getPropertyValue("border-bottom-style"));
out.push("divide.gaps=" + gaps("divide").join(","));
out.push("repro.start=" + getComputedStyle(kids("space2")[0]).getPropertyValue("margin-block-start"));
console.log("OUT " + out.join("|"));
`;

const dir = mkdtempSync(join(tmpdir(), "native-space-divide-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
if (/warning: .*selector/.test(b.stderr)) throw new Error(`selector warning\n${b.stderr}`);

const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame | frame" } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const line = (r.stdout + r.stderr).split("\n").find((l) => l.startsWith("OUT ")) ?? "";
const values = new Map<string, string>();
for (const part of line.replace(/^OUT /, "").split("|")) {
  const k = part.indexOf("=");
  if (k > 0) values.set(part.slice(0, k), part.slice(k + 1));
}
const got = (k: string): string => values.get(k) ?? "";

check("space-y-4 leaves no margin above the first child", got("space.start") === "0px", got("space.start"));
check("space-y-4 puts its spacing below all but the last", got("space.end") === "16px", got("space.end"));
check("space-y-4 spares the last child", got("space.last-end") === "0px", got("space.last-end"));
check("space-y-4 spaces the laid out children", got("space.gaps") === "26,26", got("space.gaps"));
check("divide-y draws its border below all but the last", got("divide.bottom") === "1px", got("divide.bottom"));
check("divide-y leaves the top edge alone", got("divide.top") === "0px", got("divide.top"));
check("divide-y spares the last child", got("divide.last-bottom") === "0px", got("divide.last-bottom"));
check("divide-y chooses its border style", got("divide.style") === "solid", got("divide.style"));
check("divide-y adds a pixel between children", got("divide.gaps") === "11,11", got("divide.gaps"));
check("the longhand calc() on :not(:last-child) computes", got("repro.start") === "16px", got("repro.start"));

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
