// KeyframeEffect.setKeyframes(): a running animation's keyframes replaced mid-flight, so the next
// frame shows the new values and the effect reads them back. The frame clock makes each value exact.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=200"><style>
body { margin: 0; font: 13px monospace; }
#d { width: 40px; height: 40px; background: #f00; opacity: 0.2; }
</style></head><body>
<div id="d"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function log(s: string): void { console.log(s); }
const d = document.getElementById("d") as HTMLElement;
const a = d.animate([{ opacity: "0" }, { opacity: "1" }], { duration: 100, fill: "forwards" });
const e = a.effect as KeyframeEffect;
let n = 0;
function tick(): void {
  n++;
  if (n === 2) {
    // Replace the keyframes a quarter of the way through: 0.2 to 0.8 from now on.
    e.setKeyframes([{ opacity: "0.2" }, { opacity: "0.8" }]);
    log("set " + String(e.getKeyframes()[0].opacity) + " " + String(e.getKeyframes()[1].opacity));
  }
  const cs = getComputedStyle(d);
  log("f" + n + " " + cs.opacity + " " + a.playState);
  if (n < 5) requestAnimationFrame(tick);
}
requestAnimationFrame(tick);
`;

const EXPECTED = [
  "f1 0 running",
  // The set lands before this frame's read, so the new keyframes already apply: 0.2 + 0.6 * 0.25.
  "set 0.2 0.8",
  "f2 0.35 running",
  // Halfway through: 0.2 + 0.6 * 0.5.
  "f3 0.5 running",
  // Three quarters: 0.2 + 0.6 * 0.75.
  "f4 0.65 running",
  "f5 0.8 finished",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-set-keyframes-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: "frame 0 | frame 25 | frame 50 | frame 75 | frame 100" };
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
