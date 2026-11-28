// A comment is no token of a custom property's value: "--foo: 1px /* hello */ rgb(0, 128, 0)"
// stands for "1px rgb(0, 128, 0)" when a var() substitutes it, so the shadow parses.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><title>var-comments</title></head><body>
<div id="t1" style="--foo: 1px /* hello */ rgb(0, 128, 0); box-shadow: 1px 1px 1px var(--foo)"></div>
<div id="t2" style="--c: rgb(0, 128, 0) /* tail */; color: var(--c)"></div>
<div id="t3" style="--i: url(/*icons*/green.png); background-image: var(--i)"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const log = (s: string): void => { console.log(s); };
const cs = (id: string): CSSStyleDeclaration => getComputedStyle(document.getElementById(id) as HTMLElement);
log("shadow " + cs("t1").boxShadow);
log("colour " + cs("t2").color);
log("url " + JSON.stringify(cs("t3").getPropertyValue("--i")));
`;

const EXPECTED_LOG = [
  "shadow rgb(0, 128, 0) 1px 1px 1px 1px",
  // A trailing comment goes the same way, and the colour after it still parses.
  "colour rgb(0, 128, 0)",
  // An unquoted url() is one token, so the comment in it is part of the URL and stays.
  'url "url(/*icons*/green.png)"',
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-var-comments-"));
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
