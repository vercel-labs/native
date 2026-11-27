// A `display: contents` wrapper generates no box, so what it holds are items of the container it
// is flattened into: flex and grid blockify them, and that reaches through nested wrappers.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><title>display-contents-items</title><style>
body { margin: 0; }
#flex { display: flex; }
#grid { display: grid; }
.contents { display: contents; }
#s1, #s2, #s3, #s4 { display: inline; }
</style></head><body>
<div id="flex"><div class="contents"><div class="contents"><span id="s1">a</span></div></div></div>
<div id="grid"><div class="contents"><span id="s2">b</span></div></div>
<div id="plain"><span id="s3">c</span></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const log = (s: string): void => { console.log(s); };
const d = (id: string): string => getComputedStyle(document.getElementById(id) as HTMLElement).display;
// A flex item behind two contents wrappers, and a grid item behind one, are blockified; the same
// span outside a container keeps its inline display.
log("items " + d("s1") + " " + d("s2") + " " + d("s3"));
`;

const EXPECTED_LOG = ["items block block inline"];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-display-contents-items-"));
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
