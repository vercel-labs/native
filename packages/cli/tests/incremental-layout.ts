// Incremental layout (NATIVE_INCREMENTAL_LAYOUT, runtime/layout/incremental.ts): a page that changes
// one thing per frame — text, children, classes, inline styles, a positioned row, a textarea's
// value, an inherited font size, a float — is laid out in verify mode, which lays every frame out
// again from scratch and reports any box the reused layout got wrong. None may differ, the reuse
// must actually happen, and the geometry the page reads back must match a run without it.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=480, height=360"><style>
body { margin: 0; font: 13px sans-serif; }
#app { display: flex; flex-direction: column; height: 100vh; }
header { display: flex; gap: 6px; padding: 4px; }
header .grow { flex: 1; }
main { display: flex; flex: 1; min-height: 0; }
aside { width: 120px; overflow-y: auto; }
aside p { margin: 6px 0; }
#list { flex: 1; overflow-y: auto; }
#spacer { position: relative; height: 600px; }
.row { position: absolute; left: 0; right: 0; padding: 2px 4px; }
.wide { width: 200px; }
#blocks { padding: 4px; }
#blocks div { margin: 8px 0; }
.float { float: left; width: 40px; height: 30px; }
#grid { display: grid; grid-template-columns: auto 1fr; gap: 4px; }
textarea { width: 160px; }
.big { font-size: 18px; }
.hide { display: none; }
footer { height: 20px; display: flex; }
#more { display: flex; flex-wrap: wrap; gap: 4px; width: 200px; }
#more > span { padding: 2px; }
.ib { display: inline-block; padding: 2px; }
#fixed { position: fixed; right: 4px; bottom: 4px; }
#contents { display: contents; }
#auto-grid { display: grid; grid-template-columns: repeat(2, auto); }
.cv { content-visibility: hidden; }
</style></head><body>
<div id="app">
  <header><span id="title">Title</span><span class="grow"></span><button id="btn">Go</button></header>
  <main>
    <aside id="side"><p>one</p><p id="two">two</p><p>three</p></aside>
    <div id="list"><div id="spacer"></div></div>
    <div id="blocks"><div id="b1">block one</div><div id="b2">block two</div><div id="b3"></div>
      <div id="grid"><span>a</span><span id="g2">grid cell</span><span>b</span><span>c</span></div>
      <textarea id="ta" rows="3">text</textarea>
      <table><tr><td id="cell">cell</td><td>x</td></tr></table>
    </div>
  </main>
  <footer><span id="fps">0 fps</span></footer>
  <div id="more"><span>alpha</span><span id="m2">beta</span><span>gamma</span><span>delta</span></div>
  <p>Inline <span class="ib" id="ib">block</span> text and <b id="bold">bold</b> words.</p>
  <ol id="list"><li>one</li><li>two</li></ol>
  <div id="fixed">fixed</div>
  <div id="wrap"><div id="contents"><span id="c1">in contents</span></div></div>
  <div id="auto-grid"><span id="ag1">x</span><span>y</span></div>
  <div id="cvbox"><span id="cvtext">visible content</span></div>
</div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const spacer = document.getElementById("spacer") as HTMLElement;
const rows: HTMLElement[] = [];
for (let i = 0; i < 8; i++) {
  const r = document.createElement("div");
  r.className = "row";
  r.style.top = (i * 24) + "px";
  r.textContent = "row " + i;
  spacer.appendChild(r);
  rows.push(r);
}
const byId = (id: string): HTMLElement => document.getElementById(id) as HTMLElement;
const steps: (() => void)[] = [
  () => { byId("fps").textContent = "60 fps"; },
  () => { rows[2].textContent = "row two, now a much longer line that wraps across the list"; },
  () => { rows[3].style.top = "300px"; },
  () => { const r = document.createElement("div"); r.className = "row"; r.style.top = "400px"; r.textContent = "new row"; spacer.appendChild(r); rows.push(r); },
  () => { spacer.removeChild(rows[0]); },
  () => { spacer.style.height = "900px"; },
  () => { byId("title").textContent = "A longer title"; },
  () => { byId("b1").textContent = "block one has more text now, enough to wrap onto another line in its box"; },
  () => { byId("b2").className = "wide"; },
  () => { const f = document.createElement("div"); f.className = "float"; byId("b3").appendChild(f); byId("b3").appendChild(document.createTextNode("text beside a float")); },
  () => { (byId("ta") as HTMLTextAreaElement).value = "line\\nline\\nline\\nline\\nmore"; },
  () => { byId("g2").textContent = "a wider grid cell"; },
  () => { byId("side").className = "big"; },
  () => { byId("two").className = "hide"; },
  () => { byId("two").className = ""; },
  () => { byId("cell").textContent = "a wider table cell"; },
  () => { byId("btn").textContent = "Go further"; },
  () => { byId("fps").textContent = "59 fps"; byId("b2").className = ""; },
  () => { rows[1].className = "row big"; },
  () => { byId("m2").textContent = "a much longer beta item"; },
  () => { byId("ib").textContent = "a wider inline block"; },
  () => { byId("bold").textContent = "much bolder words that wrap"; },
  () => { const li = document.createElement("li"); li.textContent = "three"; byId("list").appendChild(li); },
  () => { byId("fixed").textContent = "fixed, and longer"; },
  () => { byId("c1").textContent = "inside display: contents, longer"; },
  () => { byId("ag1").textContent = "wider grid item"; },
  () => { byId("cvbox").className = "cv"; },
  () => { byId("cvtext").textContent = "changed while hidden"; },
  () => { byId("cvbox").className = ""; },
  () => { byId("two").style.display = "none"; },
  () => { byId("two").textContent = "two, edited while hidden"; },
  () => { byId("two").style.display = ""; },
  () => { byId("list").removeChild(byId("list").firstElementChild as Element); },
];
let at = 0;
function tick(): void {
  if (at < steps.length) steps[at++]();
  requestAnimationFrame(tick);
}
requestAnimationFrame(tick);
(globalThis as any).dump = () => {
  for (const el of Array.from(document.querySelectorAll("*"))) {
    const r = (el as HTMLElement).getBoundingClientRect();
    console.log(el.tagName + "#" + el.id + " " + r.x + "," + r.y + " " + r.width + "x" + r.height);
  }
};
window.addEventListener("keydown", () => (globalThis as any).dump());
`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-incremental-layout-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const frames: string[] = [];
for (let i = 1; i <= 40; i++) {
  frames.push(`frame ${i * 16}`);
  // The window changes size between frames, as a drag of its corner or the host settling it
  // does: the root's containing block moves, so nothing laid out against the old one holds.
  if (i === 6) frames.push("resize 360 300");
  if (i === 9) frames.push("resize 480 360");
}
const STEPS = frames.join(" | ") + " | key a";

function run(mode: "full" | "incremental" | "verify"): { stdout: string; stderr: string } {
  const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: STEPS, NATIVE_FRAME_TIMES: "1" };
  delete env.NATIVE_SNAPSHOT;
  delete env.NATIVE_VERIFY_INCREMENTAL;
  // On by default: the full run turns it off.
  env.NATIVE_INCREMENTAL_LAYOUT = mode === "full" ? "0" : "1";
  if (mode === "verify") env.NATIVE_VERIFY_INCREMENTAL = "1";
  const r = spawnSync(exe, [], { encoding: "utf8", env });
  if (r.status !== 0) throw new Error(`${mode} run failed\n${r.stderr}`);
  return { stdout: r.stdout, stderr: r.stderr };
}

const verify = run("verify");
const mismatches = verify.stderr.split("\n").filter((l) => l.includes("layout mismatch"));
for (const l of mismatches.slice(0, 10)) console.log(`     ${l}`);
check("verify mode finds no box the reused layout got wrong", mismatches.length === 0, `${mismatches.length} mismatches`);
const counted = verify.stderr.split("\n").filter((l) => / mismatches=\d+$/.test(l));
check("verify mode counts mismatches on the frame line", counted.length > 0 && counted.every((l) => l.endsWith(" mismatches=0")));

const inc = run("incremental");
let reused = 0;
let laidOut = 0;
for (const l of inc.stderr.split("\n")) {
  const m = / laidOut=(\d+) .* cached=(\d+)$/.exec(l);
  if (m === null) continue;
  laidOut += Number(m[1]);
  reused += Number(m[2]);
}
check("incremental layout reuses boxes", reused > 0, `laidOut=${laidOut} cached=${reused}`);

const full = run("full");
check("the page reads back the same geometry with and without it", inc.stdout === full.stdout && full.stdout.length > 0);
check("a run without it prints no incremental counters", !/ cached=/.test(full.stderr));

const plain = (() => {
  const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: STEPS, NATIVE_FRAME_TIMES: "1" };
  delete env.NATIVE_SNAPSHOT;
  delete env.NATIVE_INCREMENTAL_LAYOUT;
  delete env.NATIVE_VERIFY_INCREMENTAL;
  const r = spawnSync(exe, [], { encoding: "utf8", env });
  if (r.status !== 0) throw new Error(`default run failed\n${r.stderr}`);
  return r;
})();
check("incremental layout is on by default", / cached=\d+/.test(plain.stderr) && plain.stdout === full.stdout);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
