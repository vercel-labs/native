// An @media block inserted at runtime: `sheet.insertRule("@media screen { … }")` makes a
// CSSMediaRule whose rules apply while the condition holds, whose media list a script can
// rewrite, and whose own insertRule/deleteRule edit the rules inside it.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=200">
<style id="s">#a { color: rgb(255, 0, 0); }</style>
</head><body>
<div id="a">a</div><div id="b">b</div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function log(s: string): void { console.log(s); }
function colour(id: string): string {
  return getComputedStyle(document.getElementById(id) as HTMLElement).color;
}
function bg(id: string): string {
  return getComputedStyle(document.getElementById(id) as HTMLElement).backgroundColor;
}
const made = document.createElement("style");
document.head.appendChild(made);
const ms = (made as HTMLStyleElement).sheet;
log("rules " + (ms === null ? "-" : String(ms.cssRules.length)));
if (ms !== null) {
  const at = ms.insertRule("@media screen { #b { color: rgb(0, 128, 0); } }", 0);
  log("inserted " + String(at) + " " + String(ms.cssRules.length) + " " + String(ms.cssRules[0].type));
  const block = ms.cssRules[0] as CSSMediaRule;
  log("block " + block.conditionText + " " + block.media.mediaText + " " + String(block.cssRules.length));
  log("applies " + colour("b"));
  block.media.mediaText = "print";
  log("print " + colour("b") + " " + block.conditionText);
  block.media.mediaText = "screen";
  log("screen " + colour("b") + " " + block.conditionText);
  block.insertRule("#a { background-color: rgb(0, 0, 255); }", 0);
  log("inner " + String(block.cssRules.length) + " " + bg("a"));
  block.deleteRule(1);
  log("deleted inner " + String(block.cssRules.length) + " " + colour("b"));
  ms.deleteRule(0);
  log("gone " + String(ms.cssRules.length) + " " + bg("a"));
}
`;

const EXPECTED = [
  "rules 0",
  "inserted 0 1 4",
  "block screen screen 1",
  "applies rgb(0, 128, 0)",
  "print rgb(0, 0, 0) print",
  "screen rgb(0, 128, 0) screen",
  "inner 2 rgb(0, 0, 255)",
  "deleted inner 1 rgb(0, 0, 0)",
  "gone 0 rgba(0, 0, 0, 0)",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-css-media-rule-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);
const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: "frame 3" };
delete env.NATIVE_SNAPSHOT;
const r = spawnSync(exe, [], { encoding: "utf8", env });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const got = r.stdout.split("\n").slice(0, -1);
for (const line of got) console.log(`     got ${JSON.stringify(line)}`);
check(`log lines (${EXPECTED.length})`, got.length === EXPECTED.length, `got ${got.length}`);
for (let i = 0; i < Math.min(got.length, EXPECTED.length); i++) {
  check(EXPECTED[i], got[i] === EXPECTED[i], `got ${JSON.stringify(got[i])}`);
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
