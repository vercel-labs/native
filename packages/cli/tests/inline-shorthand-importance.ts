// A style attribute lists declarations in the cascade's order: a shorthand that uses a var()
// comes after an !important longhand it covers, and the cascade decides between them. Parsing
// the attribute used to drop the earlier longhand when the later shorthand arrived.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><title>inline-shorthand-importance</title></head><body>
<div id="t1" style="--prop: 8px; margin: var(--prop); margin-top: 10px"></div>
<div id="t2" style="--prop: 8px; margin: var(--prop) !important; margin-top: 10px"></div>
<div id="t3" style="--prop: 8px; margin-top: 10px !important; margin: var(--prop);"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const log = (s: string): void => { console.log(s); };
for (const id of ["t1", "t2", "t3"]) {
  const cs = getComputedStyle(document.getElementById(id) as HTMLElement);
  log(id + " " + cs.marginTop + " " + cs.marginLeft);
}
`;

const EXPECTED_LOG = [
  // A later longhand beats the shorthand before it.
  "t1 10px 8px",
  // An important shorthand beats a later normal longhand.
  "t2 8px 8px",
  // An important longhand beats a later normal shorthand, which still sets the other sides.
  "t3 10px 8px",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-inline-shorthand-"));
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
