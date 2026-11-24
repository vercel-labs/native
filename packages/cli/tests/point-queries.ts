// document.elementFromPoint() and document.elementsFromPoint(): the topmost element the pointer
// would reach at a viewport point, and the whole stack behind it, topmost first. A box the pointer
// can't reach is left out — see-through with pointer-events: none, inert, or display: none — and so
// is an ancestor with no box under the point, while the root always answers inside the viewport.
// The expectations are Chrome's for the same page.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=300"><style>
body { margin: 0; font: 16px monospace; }
#flow { height: 100px; background: #eef; }
#abs { position: absolute; left: 50px; top: 50px; width: 60px; height: 60px; background: #fcc; }
#abs2 { position: absolute; left: 70px; top: 70px; width: 60px; height: 60px; background: #cfc; }
#see { position: absolute; left: 200px; top: 10px; width: 60px; height: 60px; background: #ccc; pointer-events: none; }
#inert { position: absolute; left: 280px; top: 10px; width: 60px; height: 60px; background: #999; }
#past { position: absolute; left: 450px; top: 20px; width: 100px; height: 40px; background: #f00; }
#host { position: absolute; left: 10px; top: 100px; width: 40px; height: 40px; background: #ddd; }
#host::before { content: "x"; position: absolute; left: 0; top: -60px; width: 40px; height: 40px;
                background: #f0f; }
</style></head><body>
<div id="flow"><span id="txt">hello</span></div>
<div id="abs"></div>
<div id="abs2"></div>
<div id="see"></div>
<div id="inert" inert></div>
<div id="past"></div>
<div id="host"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function log(s: string): void { console.log(s); }
function nm(e: Element | null): string {
  return e === null ? "null" : (e.id !== "" ? e.id : e.tagName.toLowerCase());
}
function list(x: number, y: number): string {
  const els = document.elementsFromPoint(x, y);
  return els.map((e) => nm(e)).join(",");
}
log("text " + nm(document.elementFromPoint(5, 5)));
log("flow " + nm(document.elementFromPoint(300, 90)));
log("flowlist " + list(300, 90));
log("over " + nm(document.elementFromPoint(80, 80)));
log("overlist " + list(80, 80));
log("see " + nm(document.elementFromPoint(210, 20)));
log("seelist " + list(210, 20));
log("inert " + nm(document.elementFromPoint(290, 20)));
log("neg " + nm(document.elementFromPoint(-5, 5)));
log("far " + document.elementsFromPoint(900, 900).length);
log("html " + list(395, 295));
log("past " + nm(document.elementFromPoint(460, 20)));
log("pastlist " + list(460, 20));
log("before " + nm(document.elementFromPoint(20, 60)));
log("beforelist " + list(20, 60));
log("own " + nm(document.elementFromPoint(20, 120)));
`;

const EXPECTED = [
  // Text over a span reaches the span, not the text node.
  "text txt",
  // An empty part of the block, with the body and the root behind it.
  "flow flow",
  "flowlist flow,body,html",
  // The later positioned box wins, and the stack behind it runs back to the root.
  "over abs2",
  "overlist abs2,abs,flow,body,html",
  // A see-through box and an inert one take no events: the block behind them does.
  "see flow",
  "seelist flow,body,html",
  "inert flow",
  // Off the page on an axis, or past the viewport: nothing is there.
  "neg null",
  "far 0",
  "html html",
  // A box that overflows the viewport is still out of reach past its edge.
  "past null",
  "pastlist ",
  // A generated box isn't in the DOM, so a point over one reaches the element that makes it.
  "before host",
  "beforelist host,flow,body,html",
  "own host",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-point-queries-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: "frame" };
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
