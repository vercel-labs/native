// A contenteditable host takes focus, types at the selected caret, deletes with Backspace, reports
// isContentEditable, and sends a cancelable beforeinput before each change followed by input.
//   npm test
import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=360, height=220"><style>
body { margin: 0; }
#e { position: absolute; left: 10px; top: 10px; width: 320px; min-height: 40px; padding: 6px; font: 20px sans-serif; }
</style></head><body>
<div id="e" contenteditable="true">hello</div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const e = document.getElementById("e") as HTMLElement;
const out = (tag: string): void => { console.log(tag + " text=" + e.textContent + " editable=" + String(e.isContentEditable)); };
out("start");
e.addEventListener("focus", () => out("focus"));
e.addEventListener("beforeinput", (ev) => {
  console.log("before " + ev.inputType + " data=" + String(ev.data));
  if (ev.data === "x") ev.preventDefault();
});
e.addEventListener("input", (ev) => out("input " + ev.inputType + " data=" + String(ev.data)));
`;

const dir = mkdtempSync(join(tmpdir(), "native-contenteditable-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const env: NodeJS.ProcessEnv = {
  ...process.env,
  NATIVE_STEPS: "frame 0 | frame 16 | clickat 30 22 | key Meta+a | type ab | key Backspace | type x | key Meta+a | type Z",
};
delete env.NATIVE_SNAPSHOT;
const r = spawnSync(exe, [], { encoding: "utf8", env });
if (r.status !== 0) throw new Error(`run failed\n${r.stderr}`);

const EXPECTED = [
  "start text=hello editable=true",
  "focus text=hello editable=true",
  "before insertText data=a",
  "input insertText data=a text=a editable=true",
  "before insertText data=b",
  "input insertText data=b text=ab editable=true",
  "before deleteContentBackward data=null",
  "input deleteContentBackward data=null text=a editable=true",
  "before insertText data=x",
  "before insertText data=Z",
  "input insertText data=Z text=Z editable=true",
];

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
