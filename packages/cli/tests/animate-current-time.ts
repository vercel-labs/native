// An animation a script pauses and then seeks with currentTime: the values it shows are the ones
// at that point, and a seek past the end and back again shows the middle again. This is how
// css/support/interpolation-testcommon.js asks what a property interpolates to at a given progress.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=200"><style>
body { margin: 0; font: 13px monospace; }
</style></head><body>
<div id="d"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function log(s: string): void { console.log(s); }
const d = document.getElementById("d") as HTMLElement;
const a = d.animate([
  { offset: 0, opacity: "0" },
  { offset: 1, opacity: "1" },
], { fill: "forwards", duration: 100000, easing: "linear" });
a.pause();
log("state " + a.playState + " at " + String(a.currentTime));
a.currentTime = 50000;
log("half " + getComputedStyle(d).opacity);
a.currentTime = 25000;
log("quarter " + getComputedStyle(d).opacity);
a.currentTime = 100000;
log("end " + getComputedStyle(d).opacity + " " + a.playState);
// Seeking back into the active phase shows that moment again.
a.currentTime = 50000;
log("back " + getComputedStyle(d).opacity + " " + String(a.currentTime));
log("done");
`;

const EXPECTED = [
  // It starts at its beginning; it was never played.
  "state paused at 0",
  "half 0.5",
  "quarter 0.25",
  "end 1 finished",
  "back 0.5 50000",
  "done",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-animate-current-time-"));
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
