// document.fonts is an EventTarget: the page registers loadingdone/loadingerror listeners the way
// it does in a browser, dispatchEvent reaches them, removeEventListener takes one back, and the
// set's faces are still readable after both. A browser fires loadingdone when the faces are
// ready; the runtime's faces are local files registered at mount, so the event exists but the
// page's own listeners are attached after that first sweep — the test drives dispatchEvent.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=300"><style>
body { margin: 0; }
</style></head><body>
<p id="status">waiting</p>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const set = document.fonts;
let done = 0;
let errors = 0;
const onDone = (): void => { done++; };
const onError = (): void => { errors++; };
console.log("target=" + String(set instanceof EventTarget));
console.log("members=" + typeof set.addEventListener + "," + typeof set.removeEventListener + "," + typeof set.dispatchEvent);
set.addEventListener("loadingdone", onDone);
set.addEventListener("loadingerror", onError);
console.log("dispatch=" + String(set.dispatchEvent(new Event("loadingdone"))));
console.log("errors=" + String(set.dispatchEvent(new Event("loadingerror"))));
console.log("counts=" + done + "," + errors);
set.removeEventListener("loadingdone", onDone);
set.dispatchEvent(new Event("loadingdone"));
console.log("after-remove=" + done + "," + errors);
console.log("faces=" + set.size + " " + String(set.check("12px sans-serif")));
`;

const dir = mkdtempSync(join(tmpdir(), "native-fontfaceset-events-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: "frame 0" };
delete env.NATIVE_SNAPSHOT;
const r = spawnSync(exe, [], { encoding: "utf8", env });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);

const EXPECTED = [
  "target=true",
  "members=function,function,function",
  "dispatch=true",
  "errors=true",
  "counts=1,1",
  "after-remove=1,1",
  "faces=0 false",
];

const got = r.stdout.split("\n").slice(0, -1);
for (const line of got) console.log(`     got ${JSON.stringify(line)}`);
let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}
check(`log lines (${EXPECTED.length})`, got.length === EXPECTED.length, `got ${got.length}`);
for (let i = 0; i < Math.min(got.length, EXPECTED.length); i++) {
  check(EXPECTED[i], got[i] === EXPECTED[i], `got ${JSON.stringify(got[i])}`);
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
