// :heading names the h1-h6 elements and :heading(<level>) the levels it lists; aria-level and
// role=heading don't change that, and both forms weigh one pseudo-class.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><title>heading-selector</title></head><body>
<h1 id="h1"></h1><h2 id="h2"></h2><h3 id="h3"></h3><h4 id="h4"></h4><h5 id="h5"></h5><h6 id="h6"></h6>
<h7 id="h7"></h7>
<h1 id="al" aria-level="2"></h1>
<div id="d" role="heading" aria-level="1"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const ids = ["h1", "h2", "h3", "h4", "h5", "h6", "h7", "al", "d"];
const m = (sel: string): string => ids.map((id) => {
  const el = document.getElementById(id) as HTMLElement;
  return el.matches(sel) ? "1" : "0";
}).join("");
const log = (s: string): void => { console.log(s); };
log("heading " + m(":heading"));
log("level2 " + m(":heading(2)"));
log("levels13 " + m(":heading(1, 3)"));
log("level7 " + m(":heading(7)"));
log("not " + m(":not(:heading)"));
// A level may carry a sign: -1 is no heading's level, +2 is h2's.
log("signed " + m(":heading(-1, 2)") + " " + m(":heading(+2)"));
`;

const EXPECTED_LOG = [
  // h1-h6 match (the aria-level h1 counts as an h1); h7 and the role=heading div don't.
  "heading 111111010",
  "level2 010000000",
  "levels13 101000010",
  "level7 000000000",
  "not 000000101",
  "signed 010000000 010000000",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-heading-selector-"));
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
