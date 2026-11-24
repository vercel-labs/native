// The live element lists: getElementsByTagName, getElementsByClassName and getElementsByName,
// which keep up with nodes and attributes that change after the list was made.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=200"><style>
body { margin: 0; }
</style></head><body>
<ul id="list"><li class="item odd">one</li><li class="item">two</li><li class="item odd">three</li></ul>
<div id="box"><p class="item">p1</p><span class="item">s1</span></div>
<input name="q" value="1"><input name="q" value="2"><input name="r">
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const log = (s: string): void => { console.log(s); };

const list = document.getElementById("list") as HTMLElement;
const box = document.getElementById("box") as HTMLElement;
const items = document.getElementsByClassName("item");
const lis = document.getElementsByTagName("li");
const both = document.getElementsByClassName("item odd");
const named = document.getElementsByName("q");

log("lis " + lis.length + " " + lis[1].textContent + " " + lis.item(0)!.textContent);
log("items " + items.length + " odd " + both.length + " box " + box.getElementsByClassName("item").length);
log("names " + named.length + " first " + named[0].getAttribute("value"));

// the tag name matches however it is written, and an element's own list leaves it out
log("tags " + box.getElementsByTagName("P").length + " self " +
  (box as unknown as Element).getElementsByTagName("div").length + " " +
  document.getElementsByTagName("html").length);

// a node added after the lists were made is in them
const made = document.createElement("li");
made.className = "item";
made.textContent = "four";
list.appendChild(made);
log("added " + lis.length + " " + lis[3].textContent + " " + items.length);

// and one removed leaves, index and all
list.removeChild(lis[0]);
log("removed " + lis.length + " " + lis[0].textContent + " stale " + String(lis[3]));

// class changes move an element between the class lists
made.classList.remove("item");
log("class off " + items.length + " " + both.length);
made.classList.add("odd");
log("class none " + both.length);
made.className = "item odd";
log("class back " + items.length + " " + both.length);

// id and name attributes answer namedItem and getElementsByName
made.id = "four";
log("named " + String(lis.namedItem("four") === made) + " " + String(items.namedItem("four") === made));
const extra = document.createElement("span");
extra.setAttribute("name", "q");
list.appendChild(extra);
log("name added " + named.length + " " + String(named.item(0) === extra));
extra.setAttribute("name", "r");
log("name moved " + named.length);

// the document's lists count the root element; every tag with "*"
log("star " + String(document.getElementsByTagName("*").length >= 8));
`;

const EXPECTED_LOG = [
  "lis 3 two one",
  "items 5 odd 2 box 2",
  "names 2 first 1",
  "tags 1 self 0 1",
  "added 4 four 6",
  "removed 3 two stale undefined",
  "class off 4 1",
  "class none 1",
  "class back 5 2",
  "named true true",
  "name added 3 true",
  "name moved 2",
  "star true",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-collections-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const r = spawnSync(exe, [], {
  encoding: "utf8",
  env: { ...process.env, NATIVE_STEPS: "frame" },
});
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);

const got = r.stdout.split("\n").slice(0, -1);
const want = EXPECTED_LOG;
check(`log lines (${want.length})`, got.length === want.length, `got ${got.length}: ${JSON.stringify(got.slice(want.length))}`);
const n = Math.min(got.length, want.length);
for (let i = 0; i < n; i++) check(want[i], got[i] === want[i], `got ${JSON.stringify(got[i])}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
