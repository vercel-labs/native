// Disabling and re-media-querying a page's own style sheets: HTMLStyleElement.disabled,
// CSSStyleSheet.disabled, a sheet's MediaList and a <link>'s media/disabled take rules in and out
// of the cascade and restyle without a reload. The build compiled those rules into the page's
// tables, so the switch has to reach them there, and it must only reach the disabled sheet's
// rules — a node whose declarations came from two sheets keeps the other sheet's.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=200">
<style id="s1">.a { color: rgb(255, 0, 0); } .b { display: inline; }</style>
<style id="s2">.a { background-color: rgb(0, 128, 0); }</style>
<style id="s3" media="print">#x { color: rgb(0, 0, 200); }</style>
<link id="l1" rel="stylesheet" href="site.css" media="print">
</head><body>
<div id="x" class="a">x</div>
<div id="y" class="b">y</div>
<script src="app.ts"></script>
</body></html>`;

const SITE = `#y { color: rgb(0, 128, 128); }
`;

const SCRIPT = `
function log(s: string): void { console.log(s); }
function cs(id: string): CSSStyleDeclaration {
  return getComputedStyle(document.getElementById(id) as HTMLElement);
}
const s1 = document.getElementById("s1") as HTMLStyleElement;
const s2 = document.getElementById("s2") as HTMLStyleElement;
const s3 = document.getElementById("s3") as HTMLStyleElement;
log("s1.sheet " + (s1.sheet === null ? "null" : "sheet"));
log("before " + cs("x").color + " " + cs("x").backgroundColor + " " + cs("y").display);
log("flag " + String(s1.disabled));
// A <style> the build compiled goes out of the cascade, and comes back.
s1.disabled = true;
log("s1 off " + String(s1.disabled) + " " + cs("x").color + " " + cs("x").backgroundColor + " " + cs("y").display);
s1.disabled = false;
log("s1 on " + String(s1.disabled) + " " + cs("x").color + " " + cs("x").backgroundColor + " " + cs("y").display);
// document.styleSheets reaches the same flag on the same sheet.
let first: CSSStyleSheet | null = null;
for (let i = 0; i < document.styleSheets.length; i++) {
  if (document.styleSheets[i].ownerNode === s1) first = document.styleSheets[i];
}
log("found " + (first === null ? "no" : "yes"));
if (first !== null) first.disabled = true;
log("doc off " + cs("x").color + " " + String(s1.disabled));
if (first !== null) first.disabled = false;
log("doc on " + cs("x").color + " " + String(s1.disabled));
// Disabling one sheet leaves the other sheet's rules on the same element in force.
s2.disabled = true;
log("s2 off " + cs("x").color + " " + cs("x").backgroundColor);
s2.disabled = false;
log("s2 on " + cs("x").backgroundColor + " " + cs("y").display);
// A sheet a script builds takes part in the cascade the same way.
const made = document.createElement("style");
made.textContent = "#x { border-top: 3px solid rgb(0, 0, 255); }";
document.head.appendChild(made);
log("made " + cs("x").borderTopWidth);
const madeSheet = (made as HTMLStyleElement).sheet;
if (madeSheet !== null) madeSheet.disabled = true;
log("made off " + cs("x").borderTopWidth);
if (madeSheet !== null) madeSheet.disabled = false;
// A sheet written for print doesn't apply on screen; its media list is what changes that.
const sheet3 = s3.sheet;
const list = sheet3 === null ? null : sheet3.media;
log("print " + cs("x").color + " " + (list === null ? "-" : list.mediaText) + " " + (list === null ? "-" : String(list.length)) + " " + (list === null ? "-" : list.item(0)));
s3.media = "screen";
log("screen " + cs("x").color + " " + (list === null ? "-" : list.mediaText));
if (list !== null) list.mediaText = "print";
log("print again " + cs("x").color + " " + (list === null ? "-" : String(list.length)));
if (list !== null) list.appendMedium("screen");
log("appended " + cs("x").color + " " + (list === null ? "-" : list.mediaText));
if (list !== null) list.deleteMedium("screen");
log("deleted " + cs("x").color + " " + (list === null ? "-" : list.mediaText) + " " + (list === null ? "-" : list.item(0)));
// The attribute and the list are one thing: removing it takes the condition away, setting it
// again puts one back.
s3.removeAttribute("media");
log("removed " + cs("x").color + " " + (list === null ? "-" : list.mediaText) + " " + (list === null ? "-" : String(list.length)));
s3.setAttribute("media", "print");
log("reset " + cs("x").color + " " + (list === null ? "-" : list.mediaText));
window.onload = function (): void {
  // A <link> reaches the sheet the build compiled from it the same way, once it has loaded.
  const l1 = document.getElementById("l1") as HTMLLinkElement;
  log("link print " + cs("y").color + " " + String(l1.disabled) + " " + l1.media);
  l1.media = "all";
  log("link all " + cs("y").color + " " + l1.media);
  l1.disabled = true;
  log("link off " + cs("y").color + " " + String(l1.disabled));
  l1.disabled = false;
  log("link on " + cs("y").color + " " + String(l1.disabled));
  log("frame " + cs("x").color + " " + cs("x").borderTopWidth + " " + String(s1.disabled) + " " + cs("y").color);
};
`;

const EXPECTED = [
  "s1.sheet sheet",
  "before rgb(255, 0, 0) rgb(0, 128, 0) inline",
  "flag false",
  "s1 off true rgb(0, 0, 0) rgb(0, 128, 0) block",
  "s1 on false rgb(255, 0, 0) rgb(0, 128, 0) inline",
  "found yes",
  "doc off rgb(0, 0, 0) true",
  "doc on rgb(255, 0, 0) false",
  "s2 off rgb(255, 0, 0) rgba(0, 0, 0, 0)",
  "s2 on rgb(0, 128, 0) inline",
  "made 3px",
  "made off 0px",
  // A print sheet is out of the cascade on screen; its media list says so.
  "print rgb(255, 0, 0) print 1 print",
  "screen rgb(0, 0, 200) screen",
  "print again rgb(255, 0, 0) 1",
  "appended rgb(0, 0, 200) print, screen",
  "deleted rgb(255, 0, 0) print print",
  "removed rgb(0, 0, 200)  0",
  "reset rgb(255, 0, 0) print",
  // The linked sheet's rules follow its media and disabled attributes.
  "link print rgb(0, 0, 0) false print",
  "link all rgb(0, 128, 128) all",
  "link off rgb(0, 0, 0) true",
  "link on rgb(0, 128, 128) false",
  "frame rgb(255, 0, 0) 3px false rgb(0, 128, 128)",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-css-sheet-disabled-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "site.css"), SITE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);
const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: "frame 3" };
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
