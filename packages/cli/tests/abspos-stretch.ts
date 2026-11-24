// `stretch` on an absolutely positioned box fills its inset-modified containing block: two
// offsets leave the space between them, and an auto side leaves the box's static position or the
// block's edge. A canvas with no offsets fills from where it would have gone to the block's end.
//   node tests/abspos-stretch.ts

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=300"><style>
body { margin: 0; }
p { margin: 0; height: 32px; }
#canvas { position: absolute; width: stretch; height: stretch; }
.box { position: absolute; background: lime; }
</style></head><body>
<p>x</p>
<div style="display: flow-root; position: relative; width: 150px; height: 150px; margin-top: -50px; margin-left: -50px;">
  <div style="margin-left: 50px; margin-top: 50px;"><canvas id="canvas" width="50" height="25"></canvas></div>
  <div id="inset" class="box" style="inset: 25px; width: stretch; height: stretch;"></div>
</div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const c = document.getElementById("canvas")!;
const i = document.getElementById("inset")!;
requestAnimationFrame(() => {
  requestAnimationFrame(() => {
    const a = c.getBoundingClientRect();
    const b = i.getBoundingClientRect();
    console.log([
      "canvasX=" + Math.round(a.x), "canvasY=" + Math.round(a.y),
      "canvasW=" + Math.round(a.width), "canvasH=" + Math.round(a.height),
      "insetX=" + Math.round(b.x), "insetW=" + Math.round(b.width), "insetH=" + Math.round(b.height),
    ].join("\\n"));
  });
});
`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-abspos-stretch-"));
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

check("a stretched canvas fills from its static position to the block's end",
  values.canvasW === "100" && values.canvasH === "100", `${values.canvasW}x${values.canvasH}`);
check("and it stays where it would have gone in the flow",
  values.canvasX === "0" && values.canvasY === "32", `${values.canvasX},${values.canvasY}`);
check("definite offsets leave their space to the stretch size",
  values.insetW === "100" && values.insetH === "100", `${values.insetW}x${values.insetH}`);
check("and the box sits on its start offset", values.insetX === "-25", values.insetX);

if (failed > 0) {
  console.error(`\n${failed} check(s) failed`);
  process.exit(1);
}
console.log("\nall passed");
