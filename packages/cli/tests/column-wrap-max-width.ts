// A column-wrap flex container's max-content width packs items into its definite height: the
// line break includes the row gap, the column widths are summed with the column gap, a percentage
// height is resolved once, and a definite flex-basis does not lose a growable item's max-content
// contribution or raise a shrinkable item's min-content contribution.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=400"><style>
body { margin: 0; }
.item { display: inline-block; width: 30px; height: 10px; background: rgb(0, 128, 0); }
</style></head><body>
<div style="height: 200px">
  <!-- 50% of 200 is 100px; each item is 40px tall and the row gap is 10px, so two fit a column.
       Three items make two columns, and the column gap is 20px: 10 + 20 + 10 = 40. -->
  <div id="cw" style="display: flex; flex-direction: column; flex-wrap: wrap; height: 50%;
                      row-gap: 10px; column-gap: 20px; width: max-content">
    <div style="width: 10px; height: 40px"></div>
    <div style="width: 10px; height: 40px"></div>
    <div style="width: 10px; height: 40px"></div>
  </div>
</div>
<!-- A growable item with a small definite basis still contributes its content's max-content
     width (two 30px words with a break opportunity between them). -->
<div id="growTest" style="display: flex; width: max-content">
  <div style="flex: 1 1 10px"><span class="item"></span> <span class="item"></span></div>
</div>
<div id="growAuto" style="display: flex; width: max-content">
  <div style="flex: 1 1 auto"><span class="item"></span> <span class="item"></span></div>
</div>
<!-- A shrinkable item with a large basis contributes its min-content width, not the basis. -->
<div id="shrinkTest" style="display: flex; width: min-content">
  <div style="flex: 0 1 100px"><span class="item"></span> <span class="item"></span></div>
</div>
<div id="shrinkAuto" style="display: flex; width: min-content">
  <div style="flex: 0 1 auto"><span class="item"></span> <span class="item"></span></div>
</div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function width(id: string): number {
  return (document.getElementById(id) as HTMLElement).getBoundingClientRect().width;
}
console.log("cw " + width("cw"));
console.log("grow " + width("growTest") + " " + width("growAuto"));
console.log("shrink " + width("shrinkTest") + " " + width("shrinkAuto"));
`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-column-wrap-max-width-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: "frame 1" };
delete env.NATIVE_SNAPSHOT;
const r = spawnSync(exe, [], { encoding: "utf8", env });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const line = (prefix: string): string => r.stdout.split("\n").find((l) => l.startsWith(prefix + " ")) ?? "";
const cw = Number(line("cw").split(" ")[1]);
const grow = line("grow").split(" ").slice(1).map(Number);
const shrink = line("shrink").split(" ").slice(1).map(Number);
console.log(`     got cw=${cw} grow=${grow.join(",")} shrink=${shrink.join(",")}`);

// Two columns of 10px with one 20px column gap.
check("column-wrap max-content includes the column gap", cw === 40, String(cw));
check("a percentage height packs lines at the resolved height", cw === 40, String(cw));
// The growable item's content max-content width is not replaced by its 10px basis.
check("a growable item keeps its max-content contribution", grow[0] === grow[1], grow.join(","));
// The shrinkable item can go below its 100px basis to its min-content width.
check("a shrinkable item contributes its min-content width", shrink[0] === shrink[1], shrink.join(","));

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
