// A quirks document reads ids and class names case-insensitively when it matches selectors — in a
// compiled sheet as much as in one a script adds — and a class removed under another case still
// restyles what it styled. A standards document is exact in both respects.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const BODY = `<style>
#s1 { color: rgb(0, 128, 0); }
.s2 { color: rgb(0, 0, 255); }
.bar p { background-color: rgb(255, 0, 0); }
</style>
<div id="s1">a</div>
<div id="c2" class="S2">b</div>
<div id="anc" class="Bar"><p id="t">c</p></div>
<script src="app.ts"></script>`;
const QUIRKS = `<!-- no doctype: quirks mode -->\n<html><head><title>quirks-selectors</title></head><body>${BODY}</body></html>`;
const STANDARDS = `<!doctype html>\n<html><head><title>quirks-selectors</title></head><body>${BODY}</body></html>`;

const SCRIPT = `
const log = (s: string): void => { console.log(s); };
const s1 = document.getElementById("s1") as HTMLElement;
const c2 = document.getElementById("c2") as HTMLElement;
const t = document.getElementById("t") as HTMLElement;
const anc = document.getElementById("anc") as HTMLElement;
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
anc.classList.remove("Bar");
void document.documentElement.offsetTop;
log("removed " + s(t));
`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

function run(page: string): string[] {
  const dir = mkdtempSync(join(tmpdir(), "native-quirks-selectors-"));
  writeFileSync(join(dir, "index.html"), page);
  writeFileSync(join(dir, "app.ts"), SCRIPT);
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
const BLACK = "rgb(0, 0, 0)";
const CLEAR = "rgba(0, 0, 0, 0)";

const quirks = run(QUIRKS);
const standards = run(STANDARDS);
for (const line of quirks) console.log(`     quirks    ${JSON.stringify(line)}`);
for (const line of standards) console.log(`     standards ${JSON.stringify(line)}`);
const wantQuirks = [
  // Compiled sheet: "#s1" finds id="s1", ".s2" finds class="S2", ".bar p" follows class="Bar".
  `static BackCompat ${GREEN}/${CLEAR} ${BLUE}/${CLEAR} ${BLACK}/${RED}`,
  `runtime ${BLUE} ${GREEN}`,
  // Removing "Bar" takes the descendant's red away.
  `removed ${BLACK}/${CLEAR}`,
];
const wantStandards = [
  // The id and class written exactly still match; only the differing case does not.
  `static CSS1Compat ${GREEN}/${CLEAR} ${BLACK}/${CLEAR} ${BLACK}/${CLEAR}`,
  `runtime ${BLUE} ${GREEN}`,
  `removed ${BLACK}/${CLEAR}`,
];
for (let i = 0; i < wantQuirks.length; i++) check(`quirks: ${wantQuirks[i]}`, quirks[i] === wantQuirks[i], `got ${JSON.stringify(quirks[i])}`);
for (let i = 0; i < wantStandards.length; i++) check(`standards: ${wantStandards[i]}`, standards[i] === wantStandards[i], `got ${JSON.stringify(standards[i])}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
