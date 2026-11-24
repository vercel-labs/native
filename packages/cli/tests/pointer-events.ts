// pointer-events and user-select: a box with `pointer-events: none` is see-through, so the press
// and the hover reach what is behind it, while a descendant that asks for events again with `auto`
// is still hit. `user-select` parses, inherits and serialises — including the prefixed spelling —
// and leaves a field's own selection alone, which is what a browser does with it.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=300"><style>
body { margin: 0; background: #fff; }
#under { position: absolute; left: 20px; top: 20px; width: 100px; height: 100px; background: #ccf; }
#over { position: absolute; left: 20px; top: 20px; width: 100px; height: 100px; background: #fcc;
        pointer-events: none; }
#child { position: absolute; left: 5px; top: 5px; width: 20px; height: 20px; background: #cfc;
         pointer-events: auto; }
#box { position: absolute; left: 200px; top: 20px; }
#us0 { user-select: none; }
#us2 { -webkit-user-select: all; }
#f1 { position: absolute; left: 0; top: 220px; width: 300px; margin: 0; font: 16px monospace;
      user-select: none; }
</style></head><body>
<div id="under"></div>
<div id="over"><div id="child"></div></div>
<div id="box"><div id="us0"><div id="us1"></div></div><div id="us2"></div><div id="us3"></div></div>
<input id="f1" value="abcdefghijklmnopqrstuvwxyz">
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function log(s: string): void { console.log(s); }
for (const id of ["under", "over", "child"]) {
  const el = document.getElementById(id)!;
  el.addEventListener("click", (e) => { if (e.target === el) log(id + " click"); });
  el.addEventListener("pointerdown", (e) => { if (e.target === el) log(id + " down"); });
}
document.addEventListener("pointermove", (e) => {
  log("move " + (e.target instanceof Element ? e.target.id : "text"));
});

const cs = (id: string) => getComputedStyle(document.getElementById(id)!);
log("select " + cs("us0").userSelect + " " + cs("us1").userSelect + " " + cs("us2").userSelect
  + " " + cs("us3").userSelect);
const us3 = document.getElementById("us3") as HTMLElement;
us3.style.webkitUserSelect = "text";
log("inline " + cs("us3").userSelect + " " + us3.style.webkitUserSelect + " " + us3.style.userSelect);
log("events " + cs("under").pointerEvents + " " + cs("over").pointerEvents + " " + cs("child").pointerEvents);

// A press inside a field takes its text whatever user-select says, as a browser lets it.
const f1 = document.getElementById("f1") as HTMLInputElement;
f1.addEventListener("pointerup", () => log("field " + f1.selectionStart + "," + f1.selectionEnd));
`;

const EXPECTED = [
  "select none none all auto",
  "inline text text text",
  "events auto none auto",
  // The press at #under's centre goes through #over, which paints over it but takes no events.
  "move under",
  "under down",
  "under click",
  // #child asks for events again inside the see-through #over, so it is hit.
  "move child",
  "child down",
  "child click",
  // A drag across a field selects its text, though the field says user-select: none. The drag
  // moves the pointer twice, at the press and where it ends.
  "move f1",
  "move f1",
  "field 5,15",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-pointer-events-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const env: NodeJS.ProcessEnv = {
  ...process.env,
  NATIVE_STEPS: "hover #under | click #under | hover #child | click #child | drag #f1 -100 0",
};
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
