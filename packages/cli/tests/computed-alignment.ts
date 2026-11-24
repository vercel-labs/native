// Computed box alignment reads back with the flow-relative names browsers use, and the root's auto
// margins are solved against the viewport.
//   node tests/computed-alignment.ts

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html style="width: 100px; margin-left: auto"><head>
<meta name="native-window" content="width=200, height=120">
<style>
body { margin: 0; }
#a { align-content: flex-start; align-items: flex-end; justify-content: safe flex-end;
     justify-items: normal; align-self: flex-start; }
</style></head><body>
<div id="a"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const a = document.getElementById("a")!;
requestAnimationFrame(() => {
  requestAnimationFrame(() => {
    const s = getComputedStyle(a);
    const content = s.alignContent;
    a.style.alignContent = "flex-end";
    console.log([
      "content=" + content,
      "items=" + s.alignItems,
      "self=" + s.alignSelf,
      "justify=" + s.justifyContent,
      "itemsNormal=" + s.justifyItems,
      "specified=" + a.style.alignContent,
      "inline=" + s.alignContent,
      "rootLeft=" + document.documentElement.offsetLeft,
    ].join("\\n"));
  });
});
`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-computed-alignment-"));
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

check("align-content: flex-start computes to flow-start", values.content === "flow-start", values.content);
check("align-items: flex-end computes to flow-end", values.items === "flow-end", values.items);
check("align-self: flex-start computes to flow-start", values.self === "flow-start", values.self);
check("justify-content keeps the overflow position", values.justify === "safe flow-end", values.justify);
check("justify-items: normal stays normal", values.itemsNormal === "normal", values.itemsNormal);
check("a specified value keeps the flex spelling", values.specified === "flex-end", values.specified);
check("the inline value computes to flow-end", values.inline === "flow-end", values.inline);
check("the root's auto margin takes the free space", values.rootLeft === "100", values.rootLeft);

if (failed > 0) {
  console.error(`\n${failed} check(s) failed`);
  process.exit(1);
}
console.log("\nall passed");
