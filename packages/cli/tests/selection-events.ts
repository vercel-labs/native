// A pointer selection sends `selectionchange` at the document, as a browser does, and
// `document.getSelection()` reports the range it made. An editor keeps its toolbar in step through
// that event.   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta charset="utf-8"><meta name="native-window" content="width=420, height=200"><style>
body { margin: 0; }
#e { position: absolute; left: 10px; top: 10px; width: 380px; min-height: 60px; font: 20px sans-serif; }
</style></head><body>
<div id="e" contenteditable="true"><h1>Heading</h1><p>Some words to select</p></div>
<p id="log">count=0 state=-</p>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const log = document.getElementById("log")!;
let count = 0;
document.addEventListener("selectionchange", () => {
  count++;
  const sel = document.getSelection();
  const state = sel === null ? "none" : String(sel.rangeCount) + ":" + String(sel.toString().length);
  log.textContent = "count=" + String(count) + " state=" + state;
});
`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-selection-events-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const run = spawnSync(exe, [], {
  encoding: "utf8",
  env: { ...process.env, NATIVE_STEPS: "frame 0 | dragat 20 22 130 22 | frame 16 | print #log | clickat 60 45 | frame 16 | print #log | clickat 40 22 | frame 16 | key Meta+a | frame 16 | print #log" },
});
if (run.status !== 0) throw new Error(`run failed\n${run.stderr}`);
const lines = run.stdout.trim().split("\n");
const dragged = lines[0];
const clicked = lines[1];
const hostAll = lines[2];
check("a drag sends selectionchange with a range", /^count=[1-9]\d* state=1:[1-9]\d*$/.test(dragged), dragged);
check("a click moves the caret and sends it again", /^count=[1-9]\d* state=[01]:0$/.test(clicked), clicked);
check("Cmd+A in the host selects all of its text", /^count=[1-9]\d* state=1:27$/.test(hostAll), hostAll);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
