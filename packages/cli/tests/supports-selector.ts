// Feature detection for selectors: `CSS.supports("selector(…)")` answers whether the build can
// match the selector, and a stylesheet keeps a rule whose block is empty, as Chrome does. Pages
// detect `:focus-visible` and friends with the first before styling for it.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><title>supports-selector</title></head><body>
<div id="a"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const log = (s: string): void => { console.log(s); };
log("supports " + CSS.supports("selector(:focus-visible)") + " " +
  CSS.supports("selector(.a, #b)") + " " + CSS.supports("selector(a > b)") + " " +
  CSS.supports("selector(:madeup-pseudo)") + " " + CSS.supports("not selector(:focus-visible)") + " " +
  CSS.supports("(selector(:has(a)))") + " " + CSS.supports("selector()"));
// The answers Chrome 158 gives for these, checked with headless Chrome.
const chrome: string[] = [
  "selector(.a, .b)", "selector(.a, #b)", "selector(.a:is(.b, .c))", "selector(.a,)",
  "selector(.a)", "selector(.a > .b)", "selector(.a::before)", "selector(*)",
  "selector(:not(.a, .b))", "selector(.a, .b) or selector(.c)", "selector(.a) and selector(#b)",
  "(--x: a and b)", "(font-family: Rock and Roll)", "((--x: a and b))", "(a: b and c)",
  "(display: flex) and (color: red)", "(color: red",
];
log("chrome " + chrome.map((c) => String(CSS.supports(c))).join(" "));
// A declaration's value is read whole once a colon at the top level names the property, so words
// like "and" inside it are text; an unclosed parenthesis is closed at the end.
log("declarations " + CSS.supports("(font-family: Rock and Roll)") + " " +
  CSS.supports("(--x: a and b"));

const style = document.createElement("style");
document.head.append(style);
const sheet = style.sheet as CSSStyleSheet;
// A rule may have an empty block: a page inserts one to learn whether its selector is valid.
sheet.insertRule(":focus-visible {}", 0);
const first = sheet.cssRules[0] as CSSRule;
log("inserted " + sheet.cssRules.length + " " + first.selectorText);
sheet.insertRule("div { color: green }", 1);
log("after " + sheet.cssRules.length + " " + (sheet.cssRules[1] as CSSRule).selectorText);
let threw = false;
try {
  sheet.insertRule(":madeup-pseudo {}", 0);
} catch {
  threw = true;
}
log("invalid " + threw + " " + sheet.cssRules.length);
`;

const EXPECTED_LOG = [
  "supports true false true false false true false",
  "chrome false false true false true true true true true true true true true true false true true",
  "declarations true true",
  "inserted 1 :focus-visible",
  "after 2 div",
  "invalid true 2",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-supports-selector-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame | frame" } });
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
