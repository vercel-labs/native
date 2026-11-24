// The accessibility engine: role mapping (explicit with fallback, implicit per HTML-AAM,
// presentation conflict resolution), accessible names and descriptions per accname 1.2, and the
// states a screen reader reports.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=300"><style>body{margin:0}</style></head><body>
<label for="f1">First name</label><input id="f1">
<label>Wrapped <input id="f2"></label>
<div id="b1" role="button" aria-label="Close">X</div>
<button id="b2">Save</button>
<h3 id="h3">Section</h3>
<img id="i1" alt="A cat"><img id="i2" alt="">
<a id="l1" href="#x">Docs</a><a id="l2">Plain</a>
<div id="lb" aria-labelledby="h3 b2" aria-describedby="d1">ignored</div>
<p id="d1">A description</p>
<div id="titleOnly" title="Tooltip"></div>
<fieldset id="fs"><legend>Group <span>name</span></legend><input></fieldset>
<table id="tb"><caption>Table name</caption><tr><td id="cell">Cell</td></tr></table>
<figure id="fig"><figcaption>Caption</figcaption></figure>
<ul id="ul"><li id="li">One</li></ul>
<input id="c1" type="checkbox" checked>
<input id="r1" type="range" min="0" max="10" value="4">
<div id="hiddenParent" aria-hidden="true"><button id="hb">Hidden</button></div>
<div id="pres" role="presentation">ignored</div>
<script>
var ids = ["f1","f2","b1","b2","h3","i1","i2","l1","l2","lb","titleOnly","fs","tb","cell","fig","ul","li","c1","r1","hb","pres"];
for (var i = 0; i < ids.length; i++) {
  var a = accessibleNode(document.getElementById(ids[i]));
  var s = a.states;
  console.log(ids[i] + "|" + a.role + "|" + a.name + "|" + a.description + "|" +
    (s.disabled ? "disabled" : "") + (s.checked === true ? "checked" : "") +
    (s.level > 0 ? " level=" + s.level : "") + (s.valueNow === null ? "" : " value=" + s.valueNow));
}
</script>
</body></html>`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-a11y-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame 0" } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const got = new Map<string, string>();
for (const line of r.stdout.split("\n")) {
  if (line === "") continue;
  const id = line.split("|")[0];
  got.set(id, line);
}
const WANT: [string, string][] = [
  ["f1", "f1|textbox|First name||"],
  ["f2", "f2|textbox|Wrapped||"],
  ["b1", "b1|button|Close||"],
  ["b2", "b2|button|Save||"],
  ["h3", "h3|heading|Section|| level=3"],
  ["i1", "i1|img|A cat||"],
  ["i2", "i2|presentation|||"],
  ["l1", "l1|link|Docs||"],
  ["l2", "l2||||"],
  ["lb", "lb|generic|Section Save|A description|"],
  ["titleOnly", "titleOnly|generic|Tooltip||"],
  ["fs", "fs|group|Group name||"],
  ["tb", "tb|table|Table name||"],
  ["cell", "cell|cell|Cell||"],
  ["fig", "fig|figure|Caption||"],
  ["ul", "ul|list|||"],
  ["li", "li|listitem|One||"],
  ["c1", "c1|checkbox|||checked"],
  ["r1", "r1|slider||| value=4"],
  ["hb", "hb|button|||"],
  ["pres", "pres|presentation|||"],
];
for (const [id, want] of WANT) {
  const line = got.get(id) ?? "<missing>";
  check(`${id} reads ${want}`, line === want, `got ${line}`);
}
const lb = got.get("lb") ?? "";
check("aria-labelledby names from the referenced elements", lb === "lb|generic|Section Save|A description|", lb);
const t = got.get("titleOnly") ?? "";
check("a title names when nothing else does", t === "titleOnly|generic|Tooltip||", t);
const hiddenBtn = got.get("hb") ?? "";
check("an aria-hidden subtree contributes no name", hiddenBtn === "hb|button|||", hiddenBtn);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
