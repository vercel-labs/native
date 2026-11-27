// A quirks document reads ids and class names case-insensitively wherever selectors compare them:
// compiled sheets and runtime-added ones, ids as attribute conditions, ancestor chains, and the
// identity check that restyles a pseudo-element when a class changes. A standards document is
// exact throughout.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const BODY = `<style>
#s1 { color: rgb(0, 128, 0); }
.s2 { color: rgb(0, 0, 255); }
.bar p { background-color: rgb(255, 0, 0); }
.S1::before { content: "P"; }
#S9 { color: rgb(128, 0, 128); }
[id="S1"] { font-style: italic; }
[class="s2"] { font-style: italic; }
[id="s1"] { font-weight: 700; }
</style>
<div id="s1">a</div>
<div id="c2" class="S2">b</div>
<div id="anc" class="Bar"><p id="t">c</p></div>
<div id="p1" class="S1">d</div>
<div id="s9">e</div>
<script src="app.ts"></script>`;
const QUIRKS = `<!-- no doctype: quirks mode -->\n<html><head><title>quirks-selectors</title></head><body>${BODY}</body></html>`;
const STANDARDS = `<!doctype html>\n<html><head><title>quirks-selectors</title></head><body>${BODY}</body></html>`;

const SCRIPT = `
const log = (s: string): void => { console.log(s); };
const s1 = document.getElementById("s1") as HTMLElement;
const c2 = document.getElementById("c2") as HTMLElement;
const t = document.getElementById("t") as HTMLElement;
const anc = document.getElementById("anc") as HTMLElement;
const p1 = document.getElementById("p1") as HTMLElement;
const s9 = document.getElementById("s9") as HTMLElement;
const add = (css: string): void => {
  const style = document.createElement("style");
  style.textContent = css;
  document.body.appendChild(style);
};
// A sheet a script adds is read the same way as a compiled one.
add("#s1 { border-top-color: rgb(0, 0, 255); }");
add(".S2 { outline-color: rgb(0, 128, 0); }");
const s = (el: HTMLElement): string => {
  const st = getComputedStyle(el);
  return st.color + "/" + st.backgroundColor;
};
log("static " + document.compatMode + " " + s(s1) + " " + s(c2) + " " + s(t));
log("runtime " + getComputedStyle(s1).borderTopColor + " " + getComputedStyle(c2).outlineColor);
log("ids " + getComputedStyle(s9).color);
log("pseudo " + getComputedStyle(p1, "::before").content);
// Attribute selectors stay case-sensitive even in a quirks document; only #id and .class fold.
log("attr " + getComputedStyle(s1).fontStyle + "/" + getComputedStyle(s1).fontWeight + " " +
  getComputedStyle(c2).fontStyle);
anc.classList.remove("Bar");
p1.classList.remove("S1");
void document.documentElement.offsetTop;
log("removed " + s(t) + " " + getComputedStyle(p1, "::before").content);
`;

// A page with no script mutations at all, so ancestor ids are matched statically.
const STATIC_BODY = `<style>
#Anc .k { color: rgb(0, 0, 255); }
</style>
<div id="anc"><p id="k" class="k">x</p></div>
<script src="app.ts"></script>`;
const STATIC_QUIRKS = `<!-- no doctype: quirks mode -->\n<html><head><title>quirks-static</title></head><body>${STATIC_BODY}</body></html>`;
const STATIC_SCRIPT = `
const k = document.getElementById("k") as HTMLElement;
console.log("chain " + getComputedStyle(k).color);
`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

function run(page: string, script: string): string[] {
  const dir = mkdtempSync(join(tmpdir(), "native-quirks-selectors-"));
  writeFileSync(join(dir, "index.html"), page);
  writeFileSync(join(dir, "app.ts"), script);
  const exe = join(dir, "app");
  const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
  if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
  const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame" } });
  if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
  return r.stdout.split("\n").slice(0, -1);
}

const GREEN = "rgb(0, 128, 0)";
const BLUE = "rgb(0, 0, 255)";
const RED = "rgb(255, 0, 0)";
const PURPLE = "rgb(128, 0, 128)";
const BLACK = "rgb(0, 0, 0)";
const CLEAR = "rgba(0, 0, 0, 0)";
const NONE = "none";

const quirks = run(QUIRKS, SCRIPT);
const standards = run(STANDARDS, SCRIPT);
const statics = run(STATIC_QUIRKS, STATIC_SCRIPT);
for (const line of quirks) console.log(`     quirks    ${JSON.stringify(line)}`);
for (const line of standards) console.log(`     standards ${JSON.stringify(line)}`);
for (const line of statics) console.log(`     static    ${JSON.stringify(line)}`);

const wantQuirks = [
  // Compiled sheet: "#s1" finds id="s1", ".s2" finds class="S2", ".bar p" follows class="Bar".
  `static BackCompat ${GREEN}/${CLEAR} ${BLUE}/${CLEAR} ${BLACK}/${RED}`,
  `runtime ${BLUE} ${GREEN}`,
  // A subject id that differs in case, matched as an attribute condition because the script changes markup.
  `ids ${PURPLE}`,
  // A pseudo-element rule written on a class in another case.
  `pseudo "P"`,
  // [id="S1"] and [class="s2"] name other cases and stay exact; [id="s1"] matches as written.
  `attr normal/700 normal`,
  // Removing "Bar" and "S1" takes the descendant's red and the pseudo-element's content away;
  // a pseudo-element with no rule left computes its content as "normal", as browsers have it.
  `removed ${BLACK}/${CLEAR} normal`,
];
const wantStandards = [
  // Only the names written exactly match.
  `static CSS1Compat ${GREEN}/${CLEAR} ${BLACK}/${CLEAR} ${BLACK}/${CLEAR}`,
  `runtime ${BLUE} ${GREEN}`,
  `ids ${BLACK}`,
  // The class is written exactly here, so the pseudo-element rule applies; removing it does not.
  `pseudo "P"`,
  `attr normal/700 normal`,
  `removed ${BLACK}/${CLEAR} normal`,
];
for (let i = 0; i < wantQuirks.length; i++) check(`quirks: ${wantQuirks[i]}`, quirks[i] === wantQuirks[i], `got ${JSON.stringify(quirks[i])}`);
for (let i = 0; i < wantStandards.length; i++) check(`standards: ${wantStandards[i]}`, standards[i] === wantStandards[i], `got ${JSON.stringify(standards[i])}`);
check(`a static ancestor id folds: chain ${BLUE}`, statics[0] === `chain ${BLUE}`, `got ${JSON.stringify(statics[0])}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
