// A @keyframes with no blocks still defines an animation: the element naming it has an animation
// that reports itself and moves nothing. A name no @keyframes defines has no animation at all,
// and a class that starts one is seen at once.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=200"><style>
body { margin: 0; font: 13px monospace; }
@keyframes empty {}
#t { animation: empty 10s linear; opacity: 0.5; }
#n { animation: missing 10s linear; }
.later { animation-name: empty; }
</style></head><body>
<div id="t"></div>
<div id="n"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function log(s: string): void { console.log(s); }
const t = document.getElementById("t") as HTMLElement;
const n = document.getElementById("n") as HTMLElement;
const runs = t.getAnimations();
log("empty " + String(runs.length) + " " + (runs.length > 0 ? runs[0].animationName : "none"));
log("missing " + String(n.getAnimations().length));
// An empty @keyframes moves nothing: the cascaded opacity stays.
log("opacity " + getComputedStyle(t).opacity);
// A class that gives the element the name is seen by getAnimations() at once.
t.classList.add("later");
log("later " + String(t.getAnimations().length));
log("done");
`;

const EXPECTED = [
  "empty 1 empty",
  "missing 0",
  "opacity 0.5",
  "later 1",
  "done",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-empty-keyframes-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: "frame 1" };
delete env.NATIVE_SNAPSHOT;
const r = spawnSync(exe, [], { encoding: "utf8", env });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const got = r.stdout.split("\n").slice(0, -1);
for (const line of got) console.log(`     got ${JSON.stringify(line)}`);
check(`log lines (${EXPECTED.length})`, got.length === EXPECTED.length, `got ${got.length}`);
for (let i = 0; i < Math.min(got.length, EXPECTED.length); i++) {
  check(EXPECTED[i], got[i] === EXPECTED[i], `got ${JSON.stringify(got[i])}`);
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
