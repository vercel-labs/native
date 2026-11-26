// A document's author rules stop at a shadow boundary, so moving an element between a shadow tree
// and the document changes which of them apply: the element resolves its rules again.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><title>shadow-reparent</title><style>
#x { color: rgb(0, 128, 0); }
</style></head><body>
<div id="host"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const log = (s: string): void => { console.log(s); };
const host = document.getElementById("host") as HTMLElement;
const shadow = host.attachShadow({ mode: "open" });
const x = document.createElement("div");
x.id = "x";
shadow.appendChild(x);
void document.documentElement.offsetTop;
log("in shadow " + getComputedStyle(x).color);
document.body.appendChild(x);
void document.documentElement.offsetTop;
log("in document " + getComputedStyle(x).color);
shadow.appendChild(x);
void document.documentElement.offsetTop;
log("back in shadow " + getComputedStyle(x).color);
`;

const BLACK = "rgb(0, 0, 0)";
const GREEN = "rgb(0, 128, 0)";
const EXPECTED_LOG = [
  // The document's rule does not reach into the shadow tree until the element comes out.
  `in shadow ${BLACK}`,
  `in document ${GREEN}`,
  `back in shadow ${BLACK}`,
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-shadow-reparent-"));
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
