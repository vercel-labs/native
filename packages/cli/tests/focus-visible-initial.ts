// Programmatic focus shows :focus-visible while the user has not touched the page, and editable
// content always matches it once focused, as Chrome does. The first is what a page that focuses
// a field on load sees.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><title>focus-visible-initial</title><style>
#el:focus-visible, #ed:focus-visible { outline: 2px solid rgb(0, 128, 0); }
</style></head><body>
<div id="el" tabindex="0">Focus me</div>
<span id="ed" contenteditable>Editable</span>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const log = (s: string): void => { console.log(s); };
const el = document.getElementById("el") as HTMLElement;
const ed = document.getElementById("ed") as HTMLElement;
window.addEventListener("load", () => {
  el.focus();
  log("load focus " + getComputedStyle(el).outlineColor + " " + document.querySelectorAll(":focus-visible").length);
  ed.focus();
  log("editable focus " + getComputedStyle(ed).outlineColor + " " + document.querySelectorAll(":focus-visible").length);
});
`;

const EXPECTED_LOG = [
  "load focus rgb(0, 128, 0) 1",
  "editable focus rgb(0, 128, 0) 1",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-focus-visible-initial-"));
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
