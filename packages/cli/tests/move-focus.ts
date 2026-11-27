// moveBefore() preserves the node's state, the focus it holds included: the removal it takes in
// passing is not an element leaving the page.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><title>move-focus</title></head><body>
<div id="a" tabindex="0">a</div>
<div id="b"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const log = (s: string): void => { console.log(s); };
const a = document.getElementById("a") as HTMLElement;
const b = document.getElementById("b") as HTMLElement;
const active = (): string => {
  const el = document.activeElement;
  return el === null ? "null" : (el.id !== "" ? el.id : el.tagName.toLowerCase());
};
let blurs = 0;
a.addEventListener("blur", () => { blurs++; });
a.focus();
log("before " + active() + " " + a.matches(":focus"));
b.moveBefore(a, null);
log("after " + active() + " " + a.matches(":focus") + " " + a.parentElement!.id + " blurs=" + blurs);
`;

const EXPECTED_LOG = ["before a true", "after a true b blurs=0"];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-move-focus-"));
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
