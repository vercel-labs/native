// formatBlock works on the caret a real key press leaves behind. A caret sets no range through
// addRange(), so the selection has to report the collapsed range a browser reports: otherwise
// rangeIn() sees rangeCount 0 and the command cannot find the paragraph at the caret.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta charset="utf-8"><meta name="native-window" content="width=420, height=200"><style>
body { margin: 0; }
#e { position: absolute; left: 10px; top: 10px; width: 400px; min-height: 100px; font: 16px sans-serif; }
</style></head><body>
<div id="e" contenteditable="true"><p id="p1">alpha beta</p><p id="p2">gamma delta</p></div>
<p id="log">none</p>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const host = document.getElementById("e") as HTMLElement;
const log = document.getElementById("log") as HTMLElement;
host.addEventListener("pointerdown", () => { host.focus(); });
const lines: string[] = [];
function say(): void {
  const sel = document.getSelection();
  lines.push("type=" + String(document.execCommand("formatBlock", false, "<h2>")) +
    "|" + (host.children[0] as HTMLElement).tagName + "|" + (host.children[1] as HTMLElement).tagName +
    "|sel=" + String(sel === null ? -1 : sel.rangeCount));
  log.textContent = lines.join(";");
}
document.addEventListener("keydown", (event: KeyboardEvent) => {
  if (!event.altKey || event.key !== "2") return;
  event.preventDefault();
  say();
});
`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-edit-caret-block-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const run = spawnSync(exe, [], {
  encoding: "utf8",
  env: {
    ...process.env,
    NATIVE_STEPS: "frame 0 | frame 16 | click #p1 | frame 16 | type X | frame 16 | key Alt+2 | frame 16 |" +
      " click #p2 | frame 16 | key ArrowLeft | frame 16 | key Alt+2 | frame 16 | print #log",
  },
});
if (run.status !== 0) throw new Error(`run failed\n${run.stderr}`);
const got = run.stdout.trim();
console.log(`     got ${got}`);
check("formatBlock changes the paragraph at a typed caret and at a moved caret",
  got === "type=true|H2|P|sel=1;type=true|H2|H2|sel=1", got);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
