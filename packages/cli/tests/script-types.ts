// A <script> whose type names data (an import map, a template block) is not code: it doesn't run
// and its text isn't JavaScript, so the page compiles and the classic script after it runs.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=100, height=50">
<script type="importmap">
{ "imports": { "sheet": "data:text/css,span { color: blue }" } }
</script>
<script type="text/template"><b>not code</b></script>
</head><body>
<script>
console.log("OUT ok");
</script>
</body></html>`;

const dir = mkdtempSync(join(tmpdir(), "native-script-types-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame 1" } });
const out = (r.stdout + r.stderr).trim().split("\n");
check("a data script is not compiled and the classic script runs",
  r.status === 0 && out[out.length - 1] === "OUT ok", JSON.stringify(out));
console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
