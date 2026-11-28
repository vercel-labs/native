// Focusgroup segments, as Chrome ships them: a toolbar, tablist, listbox, a nomemory toolbar and a
// wrapping toolbar; a segment is one tab stop, arrows move along its axis, Tab returns to the item
// it held, and the focusGroup IDL attribute reads and writes the attribute.
//   npm test

import { mkdtempSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=400"><style>body { margin: 0; }</style></head><body>
<div id="t" focusgroup="toolbar"><span id="t1" tabindex="0">t1</span><span id="t2" tabindex="0">t2</span><span id="t3" tabindex="0">t3</span></div>
<button id="after_t">after toolbar</button>
<div id="u" focusgroup="tablist"><span id="u1" tabindex="0">u1</span><span id="u2" tabindex="0">u2</span><span id="u3" tabindex="0">u3</span></div>
<button id="after_u">after tablist</button>
<div id="l" focusgroup="listbox"><span id="l1" tabindex="0">l1</span><span id="l2" tabindex="0">l2</span></div>
<div id="n" focusgroup="toolbar nomemory"><span id="n1" tabindex="0">n1</span><span id="n2" tabindex="0">n2</span></div>
<button id="after_n">after nomemory</button>
<div id="w" focusgroup="toolbar wrap"><span id="w1" tabindex="0">w1</span><span id="w2" tabindex="0">w2</span><span id="w3" tabindex="0">w3</span></div>
<div id="m" focusgroup="toolbar"><span id="m1" tabindex="0">m1</span><span id="m2" tabindex="0">m2</span><span id="m3" tabindex="0">m3</span></div>
<button id="after_m">after memory</button>
<div id="d" focusgroup="toolbar"><span id="d1" tabindex="0">d1</span><span id="d2" tabindex="0" style="display:none">d2</span><span id="d3" tabindex="0">d3</span></div>
<button id="after_d">after hidden</button>
<div id="q" focusgroup="toolbar"><span id="q1" tabindex="0">q1</span><span id="q2" tabindex="0" style="visibility:hidden">q2</span><span id="q3" tabindex="0">q3</span></div>
<div id="b" focusgroup="menubar"><span id="b1" tabindex="0">b1</span><span id="b2" tabindex="0">b2</span><span id="b3" tabindex="0">b3</span></div>
<div id="nm" focusgroup="menu"><span id="nm1" tabindex="0">nm1</span><span id="nm2" tabindex="0">nm2</span><span id="nm3" tabindex="0">nm3</span></div>
<div id="r" focusgroup="radiogroup"><span id="r1" tabindex="0">r1</span><span id="r2" tabindex="0">r2</span></div>
<div id="gr" focusgroup="grid"><span id="gr1" tabindex="0">gr1</span><span id="gr2" tabindex="0">gr2</span></div>
<div id="tb" focusgroup="tablist block"><span id="tb1" tabindex="0">tb1</span><span id="tb2" tabindex="0">tb2</span></div>
<div id="tw" focusgroup="tablist nowrap"><span id="tw1" tabindex="0">tw1</span><span id="tw2" tabindex="0">tw2</span></div>
<div id="li" focusgroup="listbox inline"><span id="li1" tabindex="0">li1</span><span id="li2" tabindex="0">li2</span></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const t = document.getElementById("t") as HTMLElement;
console.log("idl=" + (typeof (t as any).focusGroup) + " tokens=" + (t as any).focusGroup.value);
(t as any).focusGroup.add("wrap");
console.log("attr=" + t.getAttribute("focusgroup"));
(t as any).focusGroup.remove("wrap");
console.log("attr=" + t.getAttribute("focusgroup"));
document.addEventListener("keyup", (e: KeyboardEvent) => {
  const el = document.activeElement as HTMLElement | null;
  console.log("key " + e.key + " -> " + (el === null ? "null" : el.id));
}, true);
`;

const STEPS = [
  "frame 0",
  // toolbar: inline arrows, no wrap, remembers its item across Tab
  "click #t1", "key ArrowRight", "key ArrowRight", "key ArrowRight", "key ArrowLeft",
  "key Tab", "key Shift+Tab", "key Home",
  // tablist: inline arrows, wraps by default
  "click #u1", "key ArrowRight", "key ArrowRight", "key ArrowRight",
  // listbox: block arrows only
  "click #l1", "key ArrowDown", "key ArrowRight",
  // nomemory: Tab returns to the first item
  "click #n1", "key ArrowRight", "key Tab", "key Shift+Tab",
  // wrap token
  "click #w1", "key ArrowRight", "key ArrowRight", "key ArrowRight",
  // the remembered item follows any focus change, not just Tab: click m2, click away, come back
  "click #m2", "click #after_m", "key Shift+Tab",
  // a display: none item is no entry stop and no arrow target
  "click #after_d", "key Shift+Tab", "click #d1", "key ArrowRight",
  // nor is a visibility: hidden one
  "click #q1", "key ArrowRight",
  // menubar: inline arrows, wraps at both ends
  "click #b1", "key ArrowRight", "key ArrowRight", "key ArrowRight", "key ArrowLeft",
  // menu: block arrows, wraps; a horizontal arrow does nothing
  "click #nm1", "key ArrowDown", "key ArrowDown", "key ArrowDown", "key ArrowUp", "key ArrowRight",
  // radiogroup: both axes, wraps either way
  "click #r1", "key ArrowRight", "key ArrowRight", "click #r1", "key ArrowDown", "key ArrowUp",
  // grid is not a token Chrome ships: its items are ordinary tab stops and its arrows do nothing
  "click #gr1", "key ArrowRight",
  // block overrides a tablist's inline default; nowrap turns its wrapping off
  "click #tb1", "key ArrowDown", "key ArrowRight",
  "click #tw2", "key ArrowRight",
  // inline overrides a listbox's block default
  "click #li1", "key ArrowRight", "key ArrowDown",
].join(" | ");

const EXPECTED = [
  "idl=object tokens=toolbar",
  "attr=toolbar wrap",
  "attr=toolbar",
  "key ArrowRight -> t2",
  "key ArrowRight -> t3",
  "key ArrowRight -> t3",
  "key ArrowLeft -> t2",
  "key Tab -> after_t",
  "key Tab -> t2",
  "key Home -> t1",
  "key ArrowRight -> u2",
  "key ArrowRight -> u3",
  "key ArrowRight -> u1",
  "key ArrowDown -> l2",
  "key ArrowRight -> l2",
  "key ArrowRight -> n2",
  "key Tab -> after_n",
  "key Tab -> n1",
  "key ArrowRight -> w2",
  "key ArrowRight -> w3",
  "key ArrowRight -> w1",
  "key Tab -> m2",
  "key Tab -> d1",
  "key ArrowRight -> d3",
  "key ArrowRight -> q3",
  "key ArrowRight -> b2",
  "key ArrowRight -> b3",
  "key ArrowRight -> b1",
  "key ArrowLeft -> b3",
  "key ArrowDown -> nm2",
  "key ArrowDown -> nm3",
  "key ArrowDown -> nm1",
  "key ArrowUp -> nm3",
  "key ArrowRight -> nm3",
  "key ArrowRight -> r2",
  "key ArrowRight -> r1",
  "key ArrowDown -> r2",
  "key ArrowUp -> r1",
  "key ArrowRight -> gr1",
  "key ArrowDown -> tb2",
  "key ArrowRight -> tb2",
  "key ArrowRight -> tw2",
  "key ArrowRight -> li2",
  "key ArrowDown -> li2",
];

const dir = mkdtempSync(join(tmpdir(), "native-focusgroup-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: STEPS };
delete env.NATIVE_SNAPSHOT;
const r = spawnSync(exe, [], { encoding: "utf8", env });
if (r.status !== 0) throw new Error(`run failed\n${r.stderr}`);

const got = r.stdout.split("\n").slice(0, -1);
let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}
for (const line of got) if (EXPECTED.indexOf(line) < 0) console.log(`     extra ${JSON.stringify(line)}`);
check(`lines (${EXPECTED.length})`, got.length === EXPECTED.length, `got ${got.length}`);
for (let i = 0; i < Math.min(got.length, EXPECTED.length); i++) {
  check(EXPECTED[i], got[i] === EXPECTED[i], `got ${JSON.stringify(got[i])}`);
}
console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
