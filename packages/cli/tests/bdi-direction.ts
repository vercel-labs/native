// A <bdi> is auto unless its dir names a direction: an invalid value is ignored, so the element
// takes its direction from the first strong character of its contents rather than inheriting.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><title>bdi-direction</title></head><body>
<bdi id="a">abc</bdi>
<bdi id="b" dir="foo">x</bdi>
<bdi id="c" dir="LTR">x</bdi>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const log = (s: string): void => { console.log(s); };
const a = document.getElementById("a") as HTMLElement;
const b = document.getElementById("b") as HTMLElement;
const c = document.getElementById("c") as HTMLElement;
const dirs = (el: HTMLElement): string => el.matches(":dir(ltr)") + "/" + el.matches(":dir(rtl)");
const HEBREW = "\\u05EA";
log("initial " + dirs(a) + " " + dirs(b) + " " + dirs(c));
a.textContent = HEBREW;
b.textContent = HEBREW;
c.textContent = HEBREW;
log("hebrew " + dirs(a) + " " + dirs(b) + " " + dirs(c));
`;

const EXPECTED_LOG = [
  // The invalid dir leaves b auto, so its "x" reads ltr; c's LTR is not case-sensitive.
  "initial true/false true/false true/false",
  // a and b took the auto direction from their Hebrew contents; c keeps the direction it names.
  "hebrew false/true false/true true/false",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-bdi-direction-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b2 = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b2.status !== 0) throw new Error(`build failed\n${b2.stderr}`);

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
