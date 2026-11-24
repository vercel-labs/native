// background-position-x and -y: a value set from script reads back as CSS text, and the computed
// style reports the same axis (or the one background-position gives it), not a row id.
//   node tests/background-position.ts

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=200, height=120"><style>
body { margin: 0; }
div { width: 100px; height: 50px; background: linear-gradient(red, blue); }
</style></head><body>
<div id="a"></div>
<div id="b" style="background-position: 10px center;"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const a = document.getElementById("a")!;
const b = document.getElementById("b")!;
a.style.backgroundPositionX = "10px";
a.style.backgroundPositionY = "20%";
requestAnimationFrame(() => {
  requestAnimationFrame(() => {
    const sa = getComputedStyle(a);
    const sb = getComputedStyle(b);
    console.log([
      "declX=" + a.style.backgroundPositionX,
      "declY=" + a.style.backgroundPositionY,
      "compX=" + sa.backgroundPositionX,
      "compY=" + sa.backgroundPositionY,
      "shorthandX=" + sb.backgroundPositionX,
      "shorthandY=" + sb.backgroundPositionY,
    ].join("\\n"));
  });
});
`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-bg-position-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8", cwd: process.cwd() });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame | frame" } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const values: Record<string, string> = {};
for (const line of r.stdout.split("\n")) {
  const m = /^(\w+)=(.*)$/.exec(line.trim());
  if (m) values[m[1]] = m[2];
}

check("a declared background-position-x reads back as written", values.declX === "10px", values.declX);
check("a declared background-position-y reads back as written", values.declY === "20%", values.declY);
check("the computed x is the value it was given", values.compX === "10px", values.compX);
check("the computed y is the value it was given", values.compY === "20%", values.compY);
check("the computed x comes from background-position", values.shorthandX === "10px", values.shorthandX);
check("the computed y is centered by the shorthand", values.shorthandY === "center", values.shorthandY);

if (failed > 0) {
  console.error(`\n${failed} check(s) failed`);
  process.exit(1);
}
console.log("\nall passed");
