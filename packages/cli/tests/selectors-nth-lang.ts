// Selector forms the engine has to match like Chrome: :lang() through the language it inherits,
// :nth-child(An+B of S) counting only the siblings S matches, complex selectors inside :not() and
// :is(), and @supports selector() deciding a condition.
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
<html><head><meta name="native-window" content="width=400, height=600"><style>
body { margin: 0; }
/* :lang() reads the nearest lang up the tree. */
:lang(es) { color: rgb(1, 2, 3); }
:lang(en-GB) { background-color: rgb(4, 5, 6); }
/* :nth-child(… of S) counts only the siblings S matches. */
ul li { height: 1px; }
li:nth-child(2 of .x) { width: 100px; }
li:nth-child(1 of li:not(.x)) { width: 50px; }
li:nth-last-child(1 of .x) { height: 9px; }
/* A complex selector inside :not() and :is(). */
p:not(div + p) { text-indent: 11px; }
.anc :is(.mid + .leaf) { text-indent: 22px; }
/* @supports selector() asks whether the build can match the selector. */
@supports not selector(:lang(es)) { p { text-indent: 99px; } }
@supports selector(:lang(es)) { .sup { text-indent: 33px; } }
/* HTML attribute values match case-insensitively unless the selector's s flag says otherwise. */
[lang|="es"] { text-indent: 44px; }
[lang|="es" s] { text-indent: 55px; }
/* A one-letter subtag starts an extension, which only a range that names it reaches. */
:lang(fr-standard) { text-indent: 77px; }
:lang(fr-x-standard) { text-indent: 88px; }
/* :dir() on the element before a sibling, through a dir=auto ancestor whose text changes. */
#dx:dir(rtl) + span { text-indent: 123px; }
</style></head><body>
<div id="langs">
  <span id="l1" lang="es">a</span>
  <span id="l2" lang="es-MX">b</span>
  <span id="l3" lang="en">c</span>
  <div lang="en-GB"><span id="l4">d</span><span id="l5" lang="es">e</span></div>
  <span id="l6" lang="ES">f</span>
</div>
<ul id="nth">
  <li class="x" id="i1"></li>
  <li id="i2"></li>
  <li class="x" id="i3"></li>
  <li class="x" id="i4"></li>
  <li id="i5"></li>
  <li class="x" id="i6"></li>
</ul>
<div id="nots">
  <p id="p1">p1</p>
  <div><p id="p2">p2</p></div>
  <p id="p4">p4</p>
</div>
<div class="anc"><span class="mid"></span><span class="leaf" id="leaf">x</span></div>
<p class="sup" id="sup">s</p>
<span id="sg1" lang="fr-standard">a</span><span id="sg2" lang="fr-x-standard">b</span>
<div id="dauto" dir="auto"><span id="dchild">a</span></div>
<div id="host"><span id="slotted">s</span></div>
<div id="douter" dir="auto"><div id="dx"></div><span id="dinner">a</span></div>
<script>
function style(id: string, prop: string): string {
  return getComputedStyle(document.getElementById(id)).getPropertyValue(prop);
}
for (const [id, prop] of [["l1", "color"], ["l2", "color"], ["l3", "color"], ["l4", "background-color"],
  ["l5", "color"], ["l6", "color"], ["l1", "text-indent"], ["l2", "text-indent"], ["l3", "text-indent"], ["l6", "text-indent"], ["i1", "width"], ["i2", "width"], ["i3", "width"], ["i5", "width"],
  ["i6", "height"], ["i3", "height"], ["p1", "text-indent"], ["p2", "text-indent"], ["p4", "text-indent"], ["sg1", "text-indent"], ["sg2", "text-indent"],
  ["leaf", "text-indent"], ["sup", "text-indent"]]) {
  console.log(id + " " + prop + "=" + style(id, prop));
}
function rtl(id: string): string {
  return document.querySelector("#" + id + ":dir(rtl)") !== null ? "rtl" : "ltr";
}
const dchild = document.getElementById("dchild")!;
const dauto = document.getElementById("dauto")!;
console.log("dauto initial=" + rtl("dauto"));
dchild.innerText = "\u05EA";
void dauto.offsetTop;
console.log("dauto updated=" + rtl("dauto"));
dchild.dir = "ltr";
void dauto.offsetTop;
console.log("dauto forced=" + rtl("dauto"));
dchild.dir = "";
void dauto.offsetTop;
console.log("dauto cleared=" + rtl("dauto"));
const slotted = document.getElementById("slotted")!;
const shadow = document.getElementById("host")!.attachShadow({ mode: "open" });
shadow.innerHTML = '<slot lang="ja"></slot>';
console.log("slotted lang=" + (slotted.matches(":lang(ja)") ? "ja" : "none"));
const dinner = document.getElementById("dinner")!;
const dx = document.getElementById("dx")!;
console.log("dirchain initial=" + getComputedStyle(dinner).textIndent);
dinner.innerHTML = "\u05DE\u05E7\u05D5\u05E8";
void dx.offsetTop;
console.log("dirchain changed=" + (dx.matches(":dir(rtl)") ? "rtl" : "ltr") + " " + getComputedStyle(dinner).textIndent);
dinner.firstChild!.data = "LTR";
void dx.offsetTop;
console.log("dirchain textdata=" + getComputedStyle(dinner).textIndent);
document.dir = "rtl";
void document.body.offsetTop;
console.log("document dir=" + document.dir);
const langed = document.getElementById("sg1")!;
langed.lang = "fr";
console.log("lang property=" + langed.lang + " " + (langed.matches(":lang(fr)") ? "matches" : "no"));
</script>
</body></html>`;

const dir = mkdtempSync(join(tmpdir(), "native-selectors-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
const log = `${b.stdout}${b.stderr}`;
for (const value of [":lang(es)", "nth-child(2 of .x)", ":not(div + p)", ":is(.mid + .leaf)", "selector(:lang(es))"]) {
  const line = log.split("\n").find((l) => l.includes(`'${value}'`));
  check(`the build accepts '${value}'`, line === undefined, line ?? "");
}

const run = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: join(dir, "snap.png") } });
if (run.status !== 0) throw new Error(`run failed\n${run.stderr}`);
const got = new Map<string, string>();
for (const line of run.stdout.split("\n")) {
  const m = /^(\w+) ([\w-]+)=(.*)$/.exec(line);
  if (m !== null) got.set(`${m[1]} ${m[2]}`, m[3]);
}

// Every expectation below is what Chrome computes for the same page.
const want: [string, string][] = [
  ["l1 color", "rgb(1, 2, 3)"],
  ["l2 color", "rgb(1, 2, 3)"],
  ["l3 color", "rgb(0, 0, 0)"],
  ["l4 background-color", "rgb(4, 5, 6)"],
  ["l5 color", "rgb(1, 2, 3)"],
  ["l6 color", "rgb(1, 2, 3)"],
  // `[lang|="es"]` matches "ES" case-insensitively; the `s` flag makes "ES" not match.
  ["l1 text-indent", "55px"],
  ["l2 text-indent", "55px"],
  ["l3 text-indent", "0px"],
  ["l6 text-indent", "44px"],
  // The singleton `x` starts a private-use extension: `fr-standard` does not reach it.
  ["sg1 text-indent", "77px"],
  ["sg2 text-indent", "88px"],
  // .x siblings are i1, i3, i4, i6: the 2nd of them is i3, the last is i6; the first li that
  // isn't .x is i2.
  ["i1 width", "auto"],
  ["i2 width", "50px"],
  ["i3 width", "100px"],
  ["i5 width", "auto"],
  ["i3 height", "1px"],
  ["i6 height", "9px"],
  // p1 has no preceding sibling, and p2's previous sibling is a <p>, so :not(div + p) applies
  // to both; p4 follows a <div>, so `div + p` matches it and the rule does not.
  ["p1 text-indent", "11px"],
  ["p2 text-indent", "11px"],
  ["p4 text-indent", "0px"],
  ["leaf text-indent", "22px"],
  ["sup text-indent", "33px"],
  ["dauto initial", "ltr"],
  ["dauto updated", "rtl"],
  ["dauto forced", "ltr"],
  ["dauto cleared", "rtl"],
  ["slotted lang", "ja"],
  ["lang property", "fr matches"],
  ["dirchain initial", "0px"],
  ["dirchain changed", "rtl 123px"],
  ["dirchain textdata", "0px"],
  ["document dir", "rtl"],
];
for (const [key, value] of want) {
  const have = got.get(key);
  check(`${key} is ${value}`, have === value, have === undefined ? "missing" : `got ${have}`);
}

if (failed > 0) {
  console.log(`\n${failed} failed`);
  process.exit(1);
}
console.log("\nall passed");
