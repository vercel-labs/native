// A <progress> with no value attribute is indeterminate; giving it a value takes that away, and
// rules (and :has() ancestors) follow the change.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><title>progress-indeterminate</title><style>
#wrap:has(:indeterminate) { color: rgb(0, 128, 0); }
</style></head><body>
<div id="wrap"><progress id="p" value="50" max="100"></progress></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const log = (s: string): void => { console.log(s); };
const p = document.getElementById("p") as HTMLElement;
const wrap = document.getElementById("wrap") as HTMLElement;
const state = (): string => p.matches(":indeterminate") + " " + getComputedStyle(wrap).color;
log("valued " + state());
p.removeAttribute("value");
void document.documentElement.offsetTop;
log("indeterminate " + state());
p.setAttribute("value", "25");
void document.documentElement.offsetTop;
log("valued again " + state());
`;

const BLACK = "rgb(0, 0, 0)";
const GREEN = "rgb(0, 128, 0)";
const EXPECTED_LOG = [
  `valued false ${BLACK}`,
  `indeterminate true ${GREEN}`,
  `valued again false ${BLACK}`,
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-progress-indeterminate-"));
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
