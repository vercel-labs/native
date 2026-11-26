// window.open() opens a new window only while a user gesture counts: a call while the page is
// loading is a popup, which browsers block, and so this does. A call from a click listener opens
// one. The second half matters beyond popups: a window that starts the app again runs the same
// page, so an unguarded load-time call would open another window for ever.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=320, height=200"><style>
body { margin: 0; }
#hit { position: absolute; left: 0; top: 0; width: 320px; height: 200px; }
</style></head><body>
<div id="hit"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const atLoad = window.open("#/settings", "settings");
console.log("load=" + (atLoad === null ? "null" : "window"));
const hit = document.getElementById("hit") as HTMLElement;
hit.addEventListener("click", () => {
  const atClick = window.open("#/settings", "settings", "width=420,height=300");
  console.log("click=" + (atClick === null ? "null" : "window"));
});
`;

const dir = mkdtempSync(join(tmpdir(), "native-window-open-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: "frame 0 | clickat 10 10" };
delete env.NATIVE_SNAPSHOT;
const r = spawnSync(exe, [], { encoding: "utf8", env });
if (r.status !== 0) throw new Error(`run failed\n${r.stderr}`);

const EXPECTED = ["load=null", "click=window"];
const got = r.stdout.split("\n").slice(0, -1);
for (const line of got) console.log(`     got ${JSON.stringify(line)}`);
let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}
check(`lines (${EXPECTED.length})`, got.length === EXPECTED.length, `got ${got.length}`);
for (let i = 0; i < Math.min(got.length, EXPECTED.length); i++) {
  check(EXPECTED[i], got[i] === EXPECTED[i], `got ${JSON.stringify(got[i])}`);
}
console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
