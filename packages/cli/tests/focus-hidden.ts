// A focused element the style hides loses the focus: :focus stops matching it and the document
// goes back to the body, as a browser's focus fixup does after the style change.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><title>focus-hidden</title></head><body>
<div id="wrapper"><input id="input"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const log = (s: string): void => { console.log(s); };
const input = document.getElementById("input") as HTMLElement;
const wrapper = document.getElementById("wrapper") as HTMLElement;
const active = (): string => {
  const a = document.activeElement;
  return a === null ? "null" : (a.id !== "" ? a.id : a.tagName.toLowerCase());
};
input.focus();
log("focused " + input.matches(":focus") + " " + active());
wrapper.style.display = "none";
requestAnimationFrame(() => {
  log("hidden " + input.matches(":focus") + " " + active());
  wrapper.style.display = "block";
  input.focus();
  requestAnimationFrame(() => {
    log("shown " + input.matches(":focus") + " " + active());
  });
});
`;

const EXPECTED_LOG = [
  "focused true input",
  "hidden false body",
  "shown true input",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-focus-hidden-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame | frame | frame" } });
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
