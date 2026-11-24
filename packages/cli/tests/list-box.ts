// A <select> that is a list box — `multiple`, or a `size` over one row — shows its options as rows
// and takes its choice from the row a press lands on: that row alone in a single box, and in a
// multiple box too until Cmd or Shift is wired, which needs modifiers carried to the pointer. Each
// change sends input then change, as Chrome's list box does on the same page.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=200"><style>
body { margin: 0; font: 13px monospace; }
select { display: block; }
</style></head><body>
<select id="m" multiple size="3">
  <option value="a">alpha</option>
  <option value="b" selected>beta</option>
  <option value="c">gamma</option>
  <option value="d">delta</option>
</select>
<select id="s" size="2">
  <option value="x">one</option>
  <option value="y" selected>two</option>
  <option value="z">three</option>
</select>
<div id="d" style="position: absolute; left: 0; top: 150px; width: 100px; height: 30px; background: #eee"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function log(s: string): void { console.log(s); }
for (const id of ["m", "s"]) {
  const el = document.getElementById(id) as HTMLSelectElement;
  el.addEventListener("input", () => log(id + " input " + el.selectedIndex));
  el.addEventListener("change", () => log(id + " change " + el.selectedIndex));
}
const d = document.getElementById("d") as HTMLElement;
d.addEventListener("click", (e) => log("mods " + String(e.metaKey) + "," + String(e.shiftKey) + "," + String(e.altKey)));
requestAnimationFrame(() => {
  const m = document.getElementById("m") as HTMLSelectElement;
  const b = m.getBoundingClientRect();
  log("rows " + Math.round(b.width) + "x" + Math.round(b.height));
  log("shown " + String(getComputedStyle(m.options[0]).display));
  const o = m.options[2].getBoundingClientRect();
  log("row2 " + Math.round(o.x) + "," + Math.round(o.y) + " " + Math.round(o.width) + "x" + Math.round(o.height));
});
`;

// Type-ahead isn't measurable headlessly — Chrome's is native, and on the test Mac typing a letter
// at a focused select changes nothing in the DOM — so those checks follow the HTML algorithm: the
// first option whose label starts with the typed letters, ignoring case.
//
// The page's font is 13px monospace: our line box is 15px, so three rows are 45 plus two borders
// (Chrome's rows are 17px — 53 for the same box — because its Arial metrics give a taller line).
const STEP_CASES: { steps: string; want: string[] }[] = [
  // The first row is alpha's: a press takes it alone, clearing beta, and both events follow.
  { steps: "clickat 20 10 | selected #m", want: ["m input 0", "m change 0", "idx 0 1000"] },
  // The third row is gamma's (rows are 15px tall from y=1): a press moves the choice there.
  { steps: "clickat 20 40 | selected #m", want: ["m input 2", "m change 2", "idx 2 0010"] },
  // A single list box starts below the multiple one; its first row is one's.
  { steps: "clickat 20 62 | selected #s", want: ["s input 0", "s change 0", "idx 0 100"] },
  // A press on the row already chosen in a multiple box selects just it, and sends nothing.
  { steps: "clickat 20 25 | selected #m", want: ["idx 1 0100"] },
  // Shift extends from the row last pressed plainly to the row pressed: all three are chosen.
  { steps: "clickat 20 10 | clickat 20 40 Shift | selected #m",
    want: ["m input 0", "m change 0", "m input 0", "m change 0", "idx 0 1110"] },
  // Cmd adds the pressed row (the second, beta) to the choice without clearing the rest.
  { steps: "clickat 20 10 | clickat 20 25 Meta | selected #m",
    want: ["m input 0", "m change 0", "m input 0", "m change 0", "idx 0 1100"] },
  // The modifiers ride on the mouse events themselves, not just the list box.
  { steps: "clickat 10 160 Meta+Shift", want: ["mods true,true,false"] },
  // Arrows move a list box's choice a row at a time, sending input then change (Chrome, measured).
  { steps: "clickat 20 10 | key ArrowDown | key ArrowDown | selected #m",
    want: ["m input 0", "m change 0", "m input 1", "m change 1", "m input 2", "m change 2", "idx 2 0010"] },
  // Typing a letter reaches the option that starts with it.
  { steps: "clickat 20 10 | key g | selected #m",
    want: ["m input 0", "m change 0", "m input 2", "m change 2", "idx 2 0010"] },
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-list-box-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

function run(steps: string): string[] {
  const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: steps === "" ? "frame 1" : `frame 1 | ${steps}` };
  delete env.NATIVE_SNAPSHOT;
  const r = spawnSync(exe, [], { encoding: "utf8", env });
  if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
  return r.stdout.split("\n").slice(0, -1);
}

const base = run("");
for (const line of base) console.log(`     got ${JSON.stringify(line)}`);
check("a multiple box three rows tall", base[0] === "rows 300x47", base[0]);
check("its options are shown", base[1] === "shown block", base[1]);
check("each option is a row of the field", base[2] === "row2 1,31 298x15", base[2]);

for (const { steps, want } of STEP_CASES) {
  const got = run(steps).slice(3);
  for (const line of got) console.log(`     got ${JSON.stringify(line)}`);
  check(`${steps} (${want.length} lines)`, got.length === want.length, `got ${got.length}: ${got.join(" | ")}`);
  for (let i = 0; i < Math.min(got.length, want.length); i++) {
    check(`${steps}: ${want[i]}`, got[i] === want[i], `got ${JSON.stringify(got[i])}`);
  }
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
