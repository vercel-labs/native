// An animation's `ready` promise: a script can wait on it before reading the animation, and it
// settles with the animation itself. A transition reports one too.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=200"><style>
body { margin: 0; font: 13px monospace; }
#d { width: 40px; height: 4px; background: #0f0; transition: width 10s linear; }
.wide { width: 140px; }
</style></head><body>
<div id="d"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function log(s: string): void { console.log(s); }
const d = document.getElementById("d") as HTMLElement;
const run = d.animate([{ offset: 0, opacity: "0" }, { offset: 1, opacity: "1" }], 1000);
run.ready.then((same: Animation) => {
  log("animation ready " + String(same === run) + " " + same.playState);
});
d.className = "wide";
const tr = d.getAnimations()[0];
tr.ready.then(() => {
  log("transition ready " + tr.transitionProperty);
});
log("script done");
`;

const EXPECTED = [
  "script done",
  "animation ready true running",
  "transition ready width",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-animation-ready-"));
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
