// A row group with no rows (an empty <tbody>, or a <tbody> whose only row is display:none) has
// no row to anchor its background at; laying the table out must not read a missing group top.
// css/css-tables/border-collapse-dynamic-section.html is this page.
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
<html><head><meta name="native-window" content="width=200, height=200"></head><body>
<table style="border-collapse: collapse; width: 100px; background: red;">
  <tbody>
    <tr id="target" style="height: 50px; display: none;">
      <td style="border: solid green 25px; background: green; padding: 0;"></td>
    </tr>
  </tbody>
  <tbody>
    <tr style="height: 25px;">
      <td style="border: solid green 25px; padding: 0;"></td>
    </tr>
  </tbody>
</table>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
document.body.offsetTop;
document.getElementById("target")!.style.display = "";
console.log("OUT ok");
`;

const dir = mkdtempSync(join(tmpdir(), "native-table-empty-group-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame 1" } });
const out = (r.stdout + r.stderr).trim().split("\n");
check("the rowless group lays out and the hidden row shows", r.status === 0 && out[out.length - 1] === "OUT ok", JSON.stringify(out));
console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
