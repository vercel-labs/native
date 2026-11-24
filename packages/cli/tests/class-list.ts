// classList: the variadic add/remove a browser takes, toggle's force argument, replace, and the
// token rules DOMTokenList enforces (an empty token is a SyntaxError, one with whitespace an
// InvalidCharacterError). Every call here is one an app writes in a browser.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=300"><style>
body { margin: 0; }
button { display: block; }
</style></head><body>
<div id="box" class="a b"></div>
<button id="add">add</button>
<button id="remove">remove</button>
<button id="toggle">toggle</button>
<button id="replace">replace</button>
<button id="contains">contains</button>
<button id="replace-same">replace-same</button>
<button id="bad">bad</button>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const box = document.getElementById("box") as HTMLElement;
const log = (s: string): void => { console.log(s); };
const text = (): string => box.getAttribute("class") + " | " + box.className + " | " + box.classList.length;

document.getElementById("add")!.addEventListener("click", () => {
  box.classList.add("c", "d", "a");
  log("add " + text());
});
document.getElementById("remove")!.addEventListener("click", () => {
  box.classList.remove("b", "d", "nope");
  log("remove " + text());
});
document.getElementById("toggle")!.addEventListener("click", () => {
  const on = box.classList.toggle("e");
  const off = box.classList.toggle("e");
  const forcedOn = box.classList.toggle("f", true);
  const forcedOff = box.classList.toggle("f", false);
  const forcedAgain = box.classList.toggle("f", true);
  log("toggle " + String([on, off, forcedOn, forcedOff, forcedAgain]) + " " + box.className);
});
document.getElementById("replace")!.addEventListener("click", () => {
  const hit = box.classList.replace("a", "z");
  const miss = box.classList.replace("nope", "q");
  log("replace " + String([hit, miss]) + " " + box.className);
});
document.getElementById("contains")!.addEventListener("click", () => {
  log("contains " + String(box.classList.contains("z")) + " " + String(box.classList.contains("nope")));
  log("supports " + String(box.classList.supports("z")));
});
document.getElementById("replace-same")!.addEventListener("click", () => {
  // Replacing a token with itself removes it: the new token is already in the list.
  const same = box.classList.replace("z", "z");
  log("replace-same " + String(same) + " " + box.className);
});
document.getElementById("bad")!.addEventListener("click", () => {
  const errors: string[] = [];
  const bad = (fn: () => void): void => {
    try { fn(); errors.push("none"); } catch (e) { errors.push((e as Error).message.split(":")[0]); }
  };
  // Tokens before the bad one are still added, as the spec processes them in order.
  try { box.classList.add("partial", ""); } catch (e) { errors.push("caught"); }
  bad(() => box.classList.add("partial2", ""));
  bad(() => box.classList.add("two words"));
  bad(() => box.classList.contains(""));
  bad(() => box.classList.toggle("a b"));
  bad(() => box.classList.replace("partial", ""));
  log("bad " + box.className + " " + errors.join(","));
});
`;

const dir = mkdtempSync(join(tmpdir(), "native-class-list-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const env: NodeJS.ProcessEnv = {
  ...process.env,
  NATIVE_STEPS: "click #add | click #remove | click #toggle | click #replace | click #contains | click #replace-same | click #bad",
};
delete env.NATIVE_SNAPSHOT;
const r = spawnSync(exe, [], { encoding: "utf8", env });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);

const EXPECTED = [
  // adding several tokens at once, one already there: "a b" gains c and d.
  "add a b c d | a b c d | 4",
  // removing several at once: b and d go, a token that isn't there is no error.
  "remove a c | a c | 2",
  // toggle without a force flips and reports; with one it sets that state whatever it held.
  "toggle true,false,true,false,true a c f",
  // replace keeps the token's place, and reports whether there was one to replace.
  "replace true,false z c f",
  "contains true false",
  "supports true",
  // Replacing a token with itself finds the new token already there, so the token goes.
  "replace-same true c f",
  // The empty and whitespace tokens throw the names a browser's DOMException carries, and the
  // token before the bad one in an add() still lands.
  "bad c f partial partial2 caught,SyntaxError,InvalidCharacterError,SyntaxError,InvalidCharacterError,SyntaxError",
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
