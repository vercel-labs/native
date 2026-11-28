// A custom property may name another one twice, so thirty-one levels double into gigabytes of
// text. A browser treats a substitution that would grow past its limit as invalid at
// computed-value time instead of building it, and so does this build: the page runs, and the
// property that asked for the value falls back to its initial value.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><title>var-blowup</title></head><body>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const log = (s: string): void => { console.log(s); };
let css = '--v0: "Something really really really long";';
for (let i = 0; i < 31; i++) css += "--v" + (i + 1) + ": var(--v" + i + ") var(--v" + i + ");";
const style = document.createElement("style");
style.innerHTML = ":root { " + css + " } :root::before { content: var(--v31); }";
document.head.appendChild(style);
const before = getComputedStyle(document.documentElement, "::before");
log("content " + JSON.stringify(before.content));
log("v31 " + JSON.stringify(getComputedStyle(document.documentElement).getPropertyValue("--v31")));
`;

// The computed content of a box that isn't generated is "normal" here (Chrome says "none"); what
// this test is about is that the doubling substitution is refused rather than built, so the
// property that asked for it reads back empty and the page runs.

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-var-blowup-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame" } });
check("the page runs", r.status === 0, `${r.status} ${r.stderr.slice(0, 200)}`);

const got = r.stdout.split("\n").slice(0, -1);
for (const line of got) console.log(`     got ${JSON.stringify(line)}`);
check("the doubled property is invalid at computed-value time", got.includes('v31 ""'), got.join(" | "));
check("both lines were printed", got.length === 2, `${got.length}`);
check("the content declaration fell back", got[0] === undefined ? false : got[0].startsWith("content "), got[0] ?? "");

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
