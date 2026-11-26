// Editing a whitespace-only text run inside a display: contents wrapper back into visible text
// restyles the flex container that flattened the wrapper, so the run is drawn again.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=320, height=200"><style>
body { margin: 0; }
#flex { display: flex; width: max-content; font: 16px sans-serif; }
</style></head><body>
<div id="flex"><div id="wrap" style="display: contents"> </div><div id="box" style="width: 10px; height: 10px"></div></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const wrap = document.getElementById("wrap") as HTMLElement;
const flex = document.getElementById("flex") as HTMLElement;
const before = flex.getBoundingClientRect().width;
const text = wrap.firstChild as Text;
text.data = "XXXX";
const after = flex.getBoundingClientRect().width;
console.log("before " + before);
console.log("after " + after);
`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-contents-text-edit-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: "frame 1" };
delete env.NATIVE_SNAPSHOT;
const r = spawnSync(exe, [], { encoding: "utf8", env });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const lines = r.stdout.split("\n");
const before = Number(lines.find((l) => l.startsWith("before "))?.split(" ")[1]);
const after = Number(lines.find((l) => l.startsWith("after "))?.split(" ")[1]);
console.log(`     got before=${before} after=${after}`);
check("the whitespace-only run starts hidden", Number.isFinite(before), String(before));
check("editing it back to text draws it again", after > before + 20, `${before} -> ${after}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
