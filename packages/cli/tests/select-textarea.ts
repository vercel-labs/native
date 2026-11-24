// <select> and <textarea> written in the markup: the elements the page builds, the values they
// read, and the field boxes the UA sheet gives them. A select shows the label of its chosen option
// and is sized by its widest one; a textarea's cols and rows size its box, and its text wraps there.
// Both controls draw with Menlo, Chrome's fixed-width face, so their heights are Chrome's: 19, 36
// and 51. Their widths are a little off for now: a textarea in Chrome is wider by its scrollbar
// thickness (183 and 103 against 167 and 86, a constant ~17px over cols x the advance), and a
// select's label is drawn in Arial in Chrome, which this build can't name yet, so it measures 112
// against 103.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=300"><style>
body { margin: 0; font: 16px monospace; }
</style></head><body>
<select id="s"><option value="a">one</option><option value="b" selected>second-longer</option></select>
<textarea id="t">hello
world</textarea>
<textarea id="t2" cols="10" rows="3"></textarea>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function log(s: string): void { console.log(s); }
requestAnimationFrame(() => {
  const s = document.getElementById("s") as HTMLSelectElement;
  const labels: string[] = [];
  for (const o of s.options) labels.push(o.text);
  log("select " + labels.join(",") + " value " + s.value + " index " + s.selectedIndex
    + " chosen " + s.chosenLabel);
  s.selectedIndex = 0;
  log("chosen2 " + s.value + " " + s.chosenLabel);
  s.value = "b";
  log("value2 " + s.selectedIndex + " " + s.chosenLabel);

  const t = document.getElementById("t") as HTMLTextAreaElement;
  log("area " + JSON.stringify(t.value));

  const box = (id: string): string => {
    const el = document.getElementById(id) as HTMLElement;
    const cs = getComputedStyle(el);
    const b = el.getBoundingClientRect();
    return Math.round(b.width) + "x" + Math.round(b.height) + " " + cs.display + " "
      + cs.borderTopWidth + " " + cs.paddingTop;
  };
  log("selbox " + box("s"));
  log("areabox " + box("t"));
  log("smallbox " + box("t2"));
});
`;

const EXPECTED = [
  "select one,second-longer value b index 1 chosen second-longer",
  "chosen2 a one",
  "value2 1 second-longer",
  'area "hello\\nworld"',
  // The field boxes the UA sheet gives the controls, in our font metrics.
  "selbox 112x19 inline-block 1px 1px",
  "areabox 167x36 inline-block 1px 2px",
  "smallbox 86x51 inline-block 1px 2px",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-select-textarea-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);
check("the build doesn't warn that the tags are unsupported", !/isn't supported|aren't supported/.test(build.stderr), build.stderr);

const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: "frame 1" };
delete env.NATIVE_SNAPSHOT;
const r = spawnSync(exe, [], { encoding: "utf8", env });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const got = r.stdout.split("\n").slice(0, -1);
for (const line of got) console.log(`     got ${JSON.stringify(line)}`);
check(`log lines (${EXPECTED.length})`, got.length === EXPECTED.length, `got ${got.length}`);
for (let i = 0; i < Math.min(got.length, EXPECTED.length); i++) {
  check(EXPECTED[i], got[i] === EXPECTED[i], `got ${JSON.stringify(got[i])}`);
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
