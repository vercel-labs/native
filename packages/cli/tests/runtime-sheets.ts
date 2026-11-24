// Style sheets a script adds at runtime: a <style> element's text, document.styleSheets and the
// constructable sheets behind adoptedStyleSheets, matched alongside the compiled rules.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=200, height=100"><style>
body { margin: 0; }
#box { width: 100px; height: 50px; background-color: rgb(10, 20, 30); color: rgb(200, 0, 0); }
#box .kid { font-size: 20px; }
</style></head><body>
<div id="box"><span class="kid" id="kid">k</span></div>
<script src="app.ts"></script>
</body></html>`;

// The script builds a <style>, appends it to document.head, and reads what it did: the sheet's
// rules, the computed values with specificity and importance resolved, a media query that
// doesn't match, a generated ::before box, and removal putting the compiled style back.
const SCRIPT = `
const log = (s: string): void => { console.log(s); };

const box = document.getElementById("box") as HTMLElement;
const kid = document.getElementById("kid") as HTMLElement;
const value = (el: Element, prop: string, pseudo: string = ""): string =>
  getComputedStyle(el, pseudo).getPropertyValue(prop);

// --- The build leaves <head> out of the tree; a script asking for it gets one.
const head = document.head;
log("head " + head.localName + " " + String(head.parentElement === document.documentElement) +
  " before body=" + String(head.nextElementSibling === (document.body as unknown as Node)));
log("sheets at start " + document.styleSheets.length);

// --- A <style> appended to the head applies, and its rules are readable at once
const style = document.createElement("style");
style.textContent = "#box { background-color: rgb(255, 0, 0); }";
head.appendChild(style);
const s1 = style.sheet as CSSStyleSheet;
log("sheet " + document.styleSheets.length + " rules=" + s1.cssRules.length +
  " owner=" + String(s1.ownerNode === (style as unknown as Element)));
log("bg " + value(box, "background-color"));

// --- Specificity, then source order: #box beats div, and the later #box keeps its color
style.textContent = "div { color: rgb(0, 0, 255); } #box { color: rgb(0, 128, 0); }" +
  " #box .kid { font-size: 30px; }";
log("cascade " + value(box, "color") + " " + value(kid, "font-size"));

// --- A runtime !important beats the inline style; a normal rule loses to it
box.style.setProperty("color", "rgb(1, 2, 3)");
style.textContent = "#box { color: rgb(0, 128, 0) !important; }";
log("important " + value(box, "color"));
style.textContent = "#box { color: rgb(0, 128, 0); }";
log("normal " + value(box, "color"));
box.style.removeProperty("color");

// --- A media query the window doesn't match leaves its rule out
const adopted = new CSSStyleSheet();
adopted.replaceSync("#box { width: 40px; } @media (min-width: 500px) { #box { width: 70px; } }");
document.adoptedStyleSheets = [adopted];
log("adopted " + document.adoptedStyleSheets.length + " rules=" + adopted.cssRules.length +
  " first=" + adopted.cssRules[0].selectorText);
log("width " + value(box, "width"));

// --- insertRule and deleteRule change the sheet, and the style, on the spot
const at = adopted.insertRule("#box { height: 10px; }", 0);
log("insert " + at + " rules=" + adopted.cssRules.length + " height=" + value(box, "height"));
adopted.deleteRule(0);
log("delete rules=" + adopted.cssRules.length + " height=" + value(box, "height"));

// --- A runtime ::before rule generates its box
style.textContent = "#box::before { content: 'X'; color: rgb(0, 0, 255); }";
log("pseudo " + value(box, "display", "::before") + " " + value(box, "color", "::before"));

// --- A sheet put anywhere in the document applies too, in document order after the head's
const late = document.createElement("style");
late.textContent = "#kid { text-decoration: underline; }";
document.body.appendChild(late);
log("body sheet " + value(kid, "text-decoration") + " sheets=" + document.styleSheets.length);

// --- Removing a sheet takes its rules away again
late.remove();
log("removed " + value(kid, "text-decoration"));

// --- The last sheet stays, so the snapshot shows what it painted
style.textContent = "#box { background-color: rgb(0, 200, 0); }";
log("painted " + value(box, "background-color"));
`;

const EXPECTED_LOG = [
  "head head true before body=true",
  "sheets at start 1",
  "sheet 2 rules=1 owner=true",
  "bg rgb(255, 0, 0)",
  "cascade rgb(0, 128, 0) 30px",
  "important rgb(0, 128, 0)",
  "normal rgb(1, 2, 3)",
  "adopted 1 rules=2 first=#box",
  "width 40px",
  "insert 0 rules=3 height=10px",
  "delete rules=2 height=50px",
  "pseudo inline rgb(0, 0, 255)",
  "body sheet underline sheets=3",
  "removed none",
  "painted rgb(0, 200, 0)",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-runtime-sheets-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const png = join(dir, "out.png");
const r = spawnSync(exe, [], {
  encoding: "utf8",
  env: { ...process.env, NATIVE_SNAPSHOT: png, NATIVE_STEPS: "frame | frame" },
});
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);

const got = r.stdout.split("\n").slice(0, -1);
const want = EXPECTED_LOG;
check(`log lines (${want.length})`, got.length === want.length, `got ${got.length}: ${JSON.stringify(got.slice(want.length))}`);
const n = Math.min(got.length, want.length);
for (let i = 0; i < n; i++) check(want[i], got[i] === want[i], `got ${JSON.stringify(got[i])}`);

// The last runtime sheet's color is what the box actually paints.
const img = decodePng(png);
const at = (x: number, y: number): string => {
  const o = (y * img.w + x) * 4;
  return `${img.rgba[o]},${img.rgba[o + 1]},${img.rgba[o + 2]}`;
};
check("the runtime sheet's background paints", at(50, 25) === "0,200,0", `got ${at(50, 25)}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
