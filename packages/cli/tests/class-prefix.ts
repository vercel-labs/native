// Class-prefix selectors (".foo-*"): a class token that starts with the prefix, has something
// after it, and that character is not another dash. They weigh one class and work in :not(),
// :is() and the style sheet's cascade.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><title>class-prefix</title><style>
.foo-* { color: rgb(0, 128, 0); }
#y.foo-bar-* { background-color: rgb(0, 0, 255); }
.bar-*::before { content: "X"; }
</style></head><body>
<div id="x" class="foo--bar"></div>
<div id="y" class="foo-bar-baz"></div>
<div id="z" class="foo-"></div>
<div id="w" class="foobar"></div>
<span id="s" class="foo-bar"></span>
<div id="p1" class="bar-x"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const log = (s: string): void => { console.log(s); };
const m = (id: string, sel: string): string => {
  const e = document.getElementById(id) as HTMLElement;
  return id + ":" + e.matches(sel);
};
log([m("x", ".foo-*"), m("y", ".foo-*"), m("z", ".foo-*"), m("w", ".foo-*")].join(" "));
log([m("x", ".foo--*"), m("y", ".foo-bar-*"), m("z", ".foo-bar-*"), m("s", "span.foo-*")].join(" "));
log([m("y", ":not(.foo-*)"), m("z", ":not(.foo-*)"), m("y", ":is(.foo-*, .qux)"), m("w", ":is(.foo-*, .qux)")].join(" "));
let n = 0;
for (const e of document.querySelectorAll(".foo-*")) n++;
log("query=" + n);
const style = (id: string): string => {
  const s = getComputedStyle(document.getElementById(id) as HTMLElement);
  return s.color + "/" + s.backgroundColor;
};
log("style y=" + style("y") + " z=" + style("z"));
log("before " + getComputedStyle(document.getElementById("p1") as HTMLElement, "::before").content);
`;

const EXPECTED_LOG = [
  // "foo--bar" starts with "foo-" but the next character is a dash, so it names another prefix.
  "x:false y:true z:false w:false",
  "x:true y:true z:false s:true",
  "y:false z:true y:true w:false",
  "query=2",
  // The rule colours y and #y.foo-bar-* fills it; z and the others keep their own style.
  "style y=rgb(0, 128, 0)/rgb(0, 0, 255) z=rgb(0, 0, 0)/rgba(0, 0, 0, 0)",
  // A prefix rule styles a pseudo-element too: the box is made and the rule decides.
  'before "X"',
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-class-prefix-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame" } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);

const got = r.stdout.split("\n").slice(0, -1);
for (const line of got) console.log(`     got ${JSON.stringify(line)}`);
if (got.length === EXPECTED_LOG.length) {
  for (let i = 0; i < got.length; i++) check(EXPECTED_LOG[i], got[i] === EXPECTED_LOG[i], `got ${JSON.stringify(got[i])}`);
} else {
  check(`log lines (${EXPECTED_LOG.length})`, false, `got ${got.length}`);
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
