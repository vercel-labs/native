// Key presses: keydown and keyup both reach the page, a held key's repeats carry repeat=true,
// and a keyup carries the key its press did. Window, document and element listeners are typed
// by their event maps, so each handler below takes the event class it names without a cast.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=320, height=200"><style>
body { margin: 0; }
#t { position: absolute; left: 10px; top: 10px; width: 280px; }
</style></head><body>
<input id="t">
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const log = (s: string): void => { console.log(s); };
const t = document.getElementById("t") as HTMLInputElement;
t.focus();
// A listener names its event's class in the map, so the parameter is that class: no cast, and
// a listener typed with the wrong class would not compile.
window.addEventListener("keydown", (event) => log("win down " + event.key + " repeat=" + String(event.repeat)));
window.addEventListener("keyup", (event) => log("win up " + event.key + " repeat=" + String(event.repeat)));
document.addEventListener("keydown", (event) => log("doc down " + event.key + " code=" + event.code + " target=" + (event.target as Element).id));
document.addEventListener("keyup", (event) => log("doc up " + event.key + " code=" + event.code));
t.addEventListener("keydown", (event) => log("input down " + event.key + " repeat=" + String(event.repeat) + " value=" + t.value));
t.addEventListener("keyup", (event) => log("input up " + event.key + " value=" + t.value));
`;

const dir = mkdtempSync(join(tmpdir(), "native-key-events-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const env: NodeJS.ProcessEnv = {
  ...process.env,
  // One press, two auto-repeats, the release; then a full press through the "key" step.
  NATIVE_STEPS: "keydown a | keyrepeat a | keyrepeat a | keyup a | key b",
};
delete env.NATIVE_SNAPSHOT;
const r = spawnSync(exe, [], { encoding: "utf8", env });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);

const EXPECTED = [
  // The first press types nothing yet: its text lands after the listeners run.
  "input down a repeat=false value=",
  "doc down a code=KeyA target=t",
  "win down a repeat=false",
  // A held key's repeats say so, and each one types its character.
  "input down a repeat=true value=a",
  "doc down a code=KeyA target=t",
  "win down a repeat=true",
  "input down a repeat=true value=aa",
  "doc down a code=KeyA target=t",
  "win down a repeat=true",
  // The release names the same key, is not a repeat, and types nothing.
  "input up a value=aaa",
  "doc up a code=KeyA",
  "win up a repeat=false",
  // "key" is a whole press: down, its default action, then up.
  "input down b repeat=false value=aaa",
  "doc down b code=KeyB target=t",
  "win down b repeat=false",
  "input up b value=aaab",
  "doc up b code=KeyB",
  "win up b repeat=false",
];

const got = r.stdout.split("\n").slice(0, -1);
for (const line of got) console.log(`     got ${JSON.stringify(line)}`);
let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}
check(`events (${EXPECTED.length})`, got.length === EXPECTED.length, `got ${got.length}`);
for (let i = 0; i < Math.min(got.length, EXPECTED.length); i++) {
  check(EXPECTED[i], got[i] === EXPECTED[i], `got ${JSON.stringify(got[i])}`);
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
