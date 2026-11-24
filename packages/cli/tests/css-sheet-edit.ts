// A script editing the page's own style rules: a deleted rule stops applying, a removed
// declaration takes its effect with it, a changed one shows, and an inserted rule joins the
// cascade. The build compiled those rules too, so the compiled copies have to stand down.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=200">
<style>.a { color: rgb(255, 0, 0); }</style>
<style>.b { color: rgb(255, 0, 0); }</style>
<style>.c { color: rgb(255, 0, 0); }</style>
<style>.d { color: rgb(255, 0, 0); }</style>
</head><body>
<div id="x" class="a">x</div>
<div id="y" class="b">y</div>
<div id="z" class="c">z</div>
<div id="w" class="d">w</div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function log(s: string): void { console.log(s); }
function colour(id: string): string {
  return getComputedStyle(document.getElementById(id) as HTMLElement).color;
}
log("before " + colour("x"));
// A deleted rule is gone.
document.styleSheets[0].deleteRule(0);
// A changed declaration shows, and leaves the rest of its rule alone.
(document.styleSheets[2].cssRules[0] as CSSRule).style.backgroundColor = "rgb(0, 128, 0)";
// A removed declaration goes with it.
(document.styleSheets[1].cssRules[0] as CSSRule).style.removeProperty("color");
// An inserted rule joins the cascade, ahead of the rule the sheet already had.
document.styleSheets[3].insertRule("#w { color: rgb(0, 0, 255); }", 0);
window.requestAnimationFrame(function () {
  log("x " + colour("x"));
  log("y " + colour("y"));
  log("z " + colour("z"));
  const z = getComputedStyle(document.getElementById("z") as HTMLElement);
  log("z bg " + z.backgroundColor);
  log("w " + colour("w"));
});
`;

const EXPECTED = [
  "before rgb(255, 0, 0)",
  // The deleted rule and the removed declaration leave the default colour.
  "x rgb(0, 0, 0)",
  "y rgb(0, 0, 0)",
  // A rule the script only adds a property to keeps its colour.
  "z rgb(255, 0, 0)",
  "z bg rgb(0, 128, 0)",
  // The inserted id rule beats the sheet's class rule.
  "w rgb(0, 0, 255)",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-css-sheet-edit-"));
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
