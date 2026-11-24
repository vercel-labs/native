// HTML drag and drop: the draggable attribute, the drag lifecycle a press-and-move sends
// (dragstart, drag, dragenter, dragover, drop, dragend), the DataTransfer each carries, and a drop
// of files from outside the app, which the dropfiles step delivers the way the host does.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=400">
<style>
  body { margin: 0; }
  #src { position: absolute; left: 0; top: 0; width: 100px; height: 100px; background: #ddd; }
  #dst { position: absolute; left: 0; top: 150px; width: 200px; height: 100px; background: #eee; }
  #zone { position: absolute; left: 0; top: 300px; width: 200px; height: 80px; background: #fafafa; }
  #linkbox { position: absolute; left: 250px; top: 0; width: 140px; height: 40px; }
</style></head>
<body>
<div id="src" draggable="true"></div>
<div id="dst"></div>
<div id="zone"></div>
<div id="linkbox"><a id="link" href="/docs/page.html">doc</a></div>
<script src="app.ts"></script></body></html>`;

const SCRIPT = `
function log(s: string): void { console.log(s); }
const src = document.getElementById("src") as HTMLElement;
const dst = document.getElementById("dst") as HTMLElement;
const zone = document.getElementById("zone") as HTMLElement;
const link = document.getElementById("link") as HTMLElement;

log("defaults " + src.draggable + " " + dst.draggable + " " + link.draggable);
const made = document.createElement("div");
log("created " + made.draggable);
made.setAttribute("draggable", "true");
log("attribute " + made.draggable);

let drags = 0;
let types = "";
let allowed = "";
const seq: string[] = [];

src.addEventListener("dragstart", (e) => {
  drags++;
  if (drags === 3) {
    // A cancelled dragstart means no drag at all: no drag, dragend or drop follows.
    e.preventDefault();
    log("cancelstart");
    return;
  }
  seq.push("start");
  const dt = (e as DragEvent).dataTransfer as DataTransfer;
  types = dt.types.join(",");
  allowed = dt.effectAllowed;
  dt.setData("text/plain", "payload");
  dt.effectAllowed = "copyMove";
});
src.addEventListener("drag", () => { seq.push("drag"); });
src.addEventListener("dragend", (e) => {
  const dt = (e as DragEvent).dataTransfer as DataTransfer;
  seq.push("end:" + dt.dropEffect);
  log("seq " + seq.join(","));
  log("start types=" + types + " allowed=" + allowed);
  seq.length = 0;
});

dst.addEventListener("dragenter", () => { seq.push("enter"); });
dst.addEventListener("dragover", (e) => {
  seq.push("over");
  const dt = (e as DragEvent).dataTransfer as DataTransfer;
  dt.dropEffect = "move";
  // The first drag is taken; the second is not, so a release over the box drops nothing.
  if (drags === 1) e.preventDefault();
});
dst.addEventListener("drop", (e) => {
  const dt = (e as DragEvent).dataTransfer as DataTransfer;
  seq.push("drop:" + dt.getData("text/plain") + ":" + dt.dropEffect);
});

// A link drags without saying so, carrying its URL.
link.addEventListener("dragstart", (e) => {
  const dt = (e as DragEvent).dataTransfer as DataTransfer;
  log("link " + dt.types.join(",") + " " + dt.getData("text/uri-list") + " " + dt.getData("text/plain"));
});
link.addEventListener("dragend", () => { log("linkend"); });

// Files dropped in from outside the app.
zone.addEventListener("dragenter", () => { log("zoneenter"); });
zone.addEventListener("dragover", (e) => {
  e.preventDefault();
  const dt = (e as DragEvent).dataTransfer as DataTransfer;
  log("zoneover " + dt.types.join(",") + " " + dt.dropEffect);
});
zone.addEventListener("drop", (e) => {
  const dt = (e as DragEvent).dataTransfer as DataTransfer;
  const f = dt.files[0];
  log("dropitem " + dt.items.length + " " + dt.items[0].kind + " " + dt.items[0].type);
  log("dropfile " + f.name + " " + f.type + " " + f.size);
  f.text().then((text) => { log("filedata " + text.trim()); });
});
`;

const EXPECTED = [
  "defaults true false true",
  "created false",
  "attribute true",
  "seq start,drag,drag,enter,over,drop:payload:move,end:move",
  "start types= allowed=uninitialized",
  "seq start,drag,drag,enter,over,end:none",
  "start types= allowed=uninitialized",
  "cancelstart",
  "link text/uri-list,text/plain /docs/page.html /docs/page.html",
  "linkend",
  "zoneenter",
  "zoneover Files copy",
  "dropitem 1 file text/plain",
  "dropfile note.txt text/plain 16",
  "filedata hello from disk",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-dnd-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const note = join(dir, "note.txt");
writeFileSync(note, "hello from disk\n");
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const steps = [
  "frame", // the page's first layout
  "drag #src 0 150", // taken: drop fires
  "drag #src 0 150", // not taken: no drop
  "drag #src 0 150", // cancelled at dragstart
  "drag #link 0 40", // a link's own payload
  `dropfiles #zone ${note}`,
  "wait 50",
].join(" | ");

const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: steps };
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
