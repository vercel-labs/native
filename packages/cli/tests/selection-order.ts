// Typing or deleting in a contenteditable host sends beforeinput, then input, then
// selectionchange. A selection listener that reads editor state has to see the DOM after input,
// as it does in a browser.   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta charset="utf-8"><meta name="native-window" content="width=320, height=160"><style>
body { margin: 0; }
#e { position: absolute; left: 10px; top: 10px; width: 300px; min-height: 40px; font: 20px sans-serif; }
</style></head><body>
<div id="e" contenteditable="true">ab</div>
<p id="log">none</p>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const log = document.getElementById("log")!;
const seen: string[] = [];
function note(name: string): void {
  // The click that places the caret sends its own selectionchange; the edit starts at beforeinput.
  if (seen.length === 0 && name !== "beforeinput") return;
  seen.push(name);
  log.textContent = seen.join(",");
}
document.addEventListener("beforeinput", () => note("beforeinput"));
document.addEventListener("input", () => note("input"));
document.addEventListener("selectionchange", () => note("selectionchange"));
`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-selection-order-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const run = spawnSync(exe, [], {
  encoding: "utf8",
  env: { ...process.env, NATIVE_STEPS: "frame 0 | frame 16 | click #e | frame 16 | type x | frame 16 | print #log" },
});
if (run.status !== 0) throw new Error(`run failed\n${run.stderr}`);
const got = run.stdout.trim();
check("selectionchange follows input", got === "beforeinput,input,selectionchange", got);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
