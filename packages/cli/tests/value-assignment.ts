// A script may hand a field any value: the IDL attribute converts with ToString, with null as the
// one exception, so undefined reads as "undefined" and null as empty — and the states that read
// the value (:placeholder-shown, validity) follow what was stored.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><title>value-assignment</title></head><body>
<input id="in" required>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const log = (s: string): void => { console.log(s); };
const el = document.getElementById("in") as HTMLInputElement;
const state = (label: string): string =>
  label + " [" + el.value + "] ph=" + el.matches(":placeholder-shown") + " valid=" + el.matches(":valid");
log(state("initial"));
el.value = undefined;
log(state("undefined"));
el.value = null;
log(state("null"));
el.setAttribute("placeholder", "p");
el.value = undefined;
log(state("placeholder"));
`;

const EXPECTED_LOG = [
  "initial [] ph=false valid=false",
  // undefined becomes the text "undefined", which fills the required field.
  "undefined [undefined] ph=false valid=true",
  // null is the one value that means empty.
  "null [] ph=false valid=false",
  "placeholder [undefined] ph=false valid=true",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-value-assignment-"));
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
