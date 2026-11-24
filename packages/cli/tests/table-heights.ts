// Table heights: an empty table has no grid, so no border spacing and (under collapsed borders)
// no border box at all, and a row group with a height of its own shares what its rows leave over
// among the rows that have none. Matches css/css-tables/tentative/tbody-height-redistribution.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=800, height=600"><style>
html, body { margin: 0; }
body { font: 16px/1 monospace; }
td { padding: 0; }
main { width: 400px; }
#out { position: fixed; left: 0; top: 0; font: 12px/1.2 monospace; }
#show { position: fixed; left: 500px; top: 0; }
</style></head>
<body><main>
<!-- 1: an empty row group has no size at all under collapsed borders, border and all. -->
<table id="one" style="border-collapse: collapse; border-spacing: 10px; border: 10px solid green">
  <tbody><tr> </tr></tbody>
</table>
<!-- 2: under separate borders it is its border, but the border spacing has nothing to surround. -->
<table id="two" style="border-collapse: separate; border-spacing: 10px; border: 10px solid green">
  <tbody><tr> </tr></tbody>
</table>
<!-- 3: the group's height is shared by its unconstrained rows in proportion to their own heights. -->
<table id="three"><tbody id="threeBody" style="height:100px">
  <tr><td><div style="height:10px">a</div></td></tr>
  <tr><td><div style="height:30px">b</div></td></tr>
</tbody></table>
<!-- 4: a row with a height of its own keeps it; the auto row takes what is left. -->
<table id="four"><tbody style="height:100px">
  <tr style="height:10px"><td></td></tr>
  <tr><td>c</td></tr>
</tbody></table>
<!-- 5: percentage row heights resolve against the group's height, and the auto row gets the rest. -->
<table id="five"><tbody style="height:100px">
  <tr style="height:25%"><td>d</td></tr>
  <tr style="height:50%"><td>e</td></tr>
  <tr><td>f</td></tr>
</tbody></table>
<!-- 6: a group height is a minimum: a taller row keeps its height and the group grows to it. -->
<table id="six"><tbody id="sixBody" style="height:100px">
  <tr style="height:125px"><td>g</td></tr>
</tbody></table>
<!-- 7: an empty auto row grows when every other row is constrained. -->
<table id="seven"><tbody style="height:100px">
  <tr style="height:20px"><td>h</td></tr>
  <tr style="height:30px"><td>i</td></tr>
  <tr><td></td></tr>
</tbody></table>
<!-- 8: an empty row group's height still gives it a box. -->
<table id="eight"><tbody id="eightBody" style="height:75px"></tbody></table>
<!-- 9: three empty rows share the group's height. -->
<table id="nine"><tbody id="nineBody" style="height:75px">
  <tr></tr><tr></tr><tr></tr>
</tbody></table>
<!-- 10: a zero-height constrained row doesn't stop the empty rows filling the group. -->
<table id="ten" style="width:50px"><tbody style="height:50px">
  <tr style="height:0"><td></td></tr>
  <tr><td></td></tr>
  <tr><td></td></tr>
</tbody></table>
<!-- 11: rows with no cells still get the table's inner width and share its height. -->
<table id="eleven" style="box-sizing:border-box; width:60px; height:60px; border:5px solid green; border-spacing:10px">
  <tr></tr><tr></tr>
</table>
<!-- 12: a cell's height is its row's; the table's extra height goes to the row with none. -->
<table id="twelve" style="height:100px">
  <tr><td style="height:30px">j</td></tr>
  <tr><td>k</td></tr>
</table>
<!-- 13: when every row names a height, the table's extra height is shared in proportion to them. -->
<table id="thirteen" style="height:100px">
  <tr><td style="height:30px">l</td></tr>
  <tr><td style="height:60px">m</td></tr>
</table>
</main>
<div id="out"></div>
<button id="show">show</button>
<script>
const size = (el): string => Math.round(el.getBoundingClientRect().width) + "x" +
  Math.round(el.getBoundingClientRect().height);
const rows = (id): string => {
  const t = document.getElementById(id);
  const hs: number[] = [];
  for (const r of [...t.querySelectorAll("tr")]) hs.push(Math.round(r.getBoundingClientRect().height));
  return hs.join(",");
};
const bodyH = (id): string => String(Math.round(document.getElementById(id).getBoundingClientRect().height));
document.getElementById("show").addEventListener("click", () => {
  const o = document.getElementById("out");
  o.textContent = [size(document.getElementById("one")), size(document.getElementById("two")),
    rows("three"), bodyH("threeBody"),
    rows("four"), rows("five"), bodyH("sixBody"),
    rows("seven"), bodyH("eightBody"),
    bodyH("nineBody"), rows("nine"), rows("ten"), rows("eleven"), size(document.getElementById("eleven").querySelector("tr")), rows("twelve"), rows("thirteen")].join(" | ");
});
</script>
</body></html>`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-table-heights-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);
const run = spawnSync(exe, [], {
  encoding: "utf8",
  env: { ...process.env, NATIVE_STEPS: "click #show | print #out", NATIVE_SNAPSHOT: join(dir, "out.png") },
});
if (run.status !== 0) throw new Error(`render failed\n${run.stderr}`);
const got = run.stdout.split("\n").slice(0, -1);
const want = [
  // The empty tables.
  "0x0", "20x20",
  // 3: proportional to 10 and 30; the group keeps the height it was given.
  "25,75", "100",
  // 4: the constrained row keeps 10, the auto row takes the other 90.
  "10,90",
  // 5: 25% and 50% of 100, then the rest.
  "25,50,25",
  // 6: the group grows to its row.
  "125",
  // 7: 20 and 30 are constrained, the empty row takes the remaining 50.
  "20,30,50",
  // 8: an empty group with a height.
  "75",
  // 9: three empty rows share 75.
  "75", "25,25,25",
  // 10: a zero-height row is constrained; the two empty rows split 50.
  "0,25,25",
  // 11: a 50px inner height holds two rows and the three 10px gutters around and between them.
  "10,10", "50x10",
  // 12: the cell's 30px makes its row constrained, so the auto row takes what is left.
  "30,64",
  // 13: both rows are constrained and share the extra height in proportion to their heights.
  "31,63",
];
check("print lines", got.length === 1, `got ${JSON.stringify(got)}`);
const parts = (got[0] ?? "").split(" | ");
for (let i = 0; i < want.length; i++) {
  check(want[i], parts[i] === want[i], `got ${JSON.stringify(parts[i])}`);
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
