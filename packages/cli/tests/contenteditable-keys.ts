// Arrow keys, Home and End move the caret in a contenteditable host, Shift extends the selection,
// and typing replaces what is selected.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=320, height=200"><style>
body { margin: 0; }
#e { position: absolute; left: 10px; top: 10px; width: 280px; min-height: 40px; padding: 6px; font: 24px sans-serif; }
</style></head><body>
<div id="e" contenteditable="true">hello</div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const e = document.getElementById("e") as HTMLElement;
e.addEventListener("input", () => console.log("text=" + e.textContent));
console.log("start=" + e.textContent);
`;

const dir = mkdtempSync(join(tmpdir(), "native-contenteditable-keys-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const env: NodeJS.ProcessEnv = {
  ...process.env,
  NATIVE_STEPS: "frame 0 | frame 16 | clickat 18 22 | key Meta+a | key ArrowRight | type X | key Home | type Y | key End | type Z | key ArrowLeft | type W | key Shift+ArrowLeft | type Q | key Home | key Shift+End | type R | key Meta+a | type abcde | key ArrowRight | key Shift+ArrowLeft | key Shift+ArrowLeft | type Q | key Home | key Shift+ArrowRight | key Shift+ArrowRight | key End | type Z | key Shift+Home | key Home | type T | key Shift+End | key End | type V",
};
delete env.NATIVE_SNAPSHOT;
const r = spawnSync(exe, [], { encoding: "utf8", env });
if (r.status !== 0) throw new Error(`run failed\n${r.stderr}`);

const EXPECTED = ["start=hello", "text=helloX", "text=YhelloX", "text=YhelloXZ", "text=YhelloXWZ", "text=YhelloXQZ", "text=R",
  "text=a", "text=ab", "text=abc", "text=abcd", "text=abcde", "text=abcQ", "text=abcQZ", "text=TabcQZ", "text=TabcQZV"];
const got = r.stdout.split("\n").slice(0, -1);
for (const line of got) console.log(`     got ${JSON.stringify(line)}`);
let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}
check(`lines (${EXPECTED.length})`, got.length === EXPECTED.length, `got ${got.length}`);
for (let i = 0; i < Math.min(got.length, EXPECTED.length); i++) check(EXPECTED[i], got[i] === EXPECTED[i], `got ${JSON.stringify(got[i])}`);
console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
