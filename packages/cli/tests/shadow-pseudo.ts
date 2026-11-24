// :host and ::slotted style the host and the light nodes a slot took, from a shadow tree's sheet.
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
<html><head><meta name="native-window" content="width=200, height=100"></head><body>
<div id="host"><p id="light">light</p></div>
<div id="host2"><p id="light2">two</p></div>
<p id="outside">outside</p>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function probe(): void {
  const host = document.getElementById("host")!;
  const root = host.attachShadow({ mode: "open" });
  root.innerHTML = '<style>'
    + ':host { color: rgb(1, 2, 3); }'
    + ':host(.nope) { color: rgb(20, 21, 22); }'
    + ':host(#host) { background-color: rgb(4, 5, 6); }'
    + '::slotted(p) { color: rgb(7, 8, 9); }'
    + 'p { color: rgb(10, 11, 12); }'
    + '</style><slot></slot><p id="inner">inner</p>';
  const inner = root.querySelector("#inner")!;
  const light = document.getElementById("light")!;
  const outside = document.getElementById("outside")!;
  // A constructed sheet adopted by a tree styles that tree and nothing else.
  const host2 = document.getElementById("host2")!;
  const root2 = host2.attachShadow({ mode: "open" });
  root2.innerHTML = "<slot></slot>";
  const sheet = new CSSStyleSheet();
  sheet.replaceSync("::slotted(p) { color: rgb(9, 8, 7); } :host { padding-top: 3px; }");
  root2.adoptedStyleSheets = [sheet];
  const light2 = document.getElementById("light2")!;
  console.log("OUT "
    + "|host=" + getComputedStyle(host).color
    + "|hostBg=" + getComputedStyle(host).backgroundColor
    + "|inner=" + getComputedStyle(inner).color
    + "|light=" + getComputedStyle(light).color
    + "|outside=" + getComputedStyle(outside).color
    + "|host2Pad=" + getComputedStyle(host2).paddingTop
    + "|light2=" + getComputedStyle(light2).color);
}
console.log("BEFORE");
probe();
console.log("AFTER");
`;

const dir = mkdtempSync(join(tmpdir(), "native-shadow-pseudo-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame 1" } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const line = (r.stdout + r.stderr).split("\n").find((l) => l.startsWith("OUT ")) ?? "";
const got = line.replace(/^OUT /, "");
const field = (name: string): string => {
  const at = got.indexOf("|" + name + "=");
  if (at < 0) return "";
  const start = at + name.length + 2;
  const end = got.indexOf("|", start);
  return got.slice(start, end < 0 ? got.length : end);
};
check(":host styles the host", field("host") === "rgb(1, 2, 3)", got);
check(":host(sel) applies when the host matches", field("hostBg") === "rgb(4, 5, 6)", got);
check("the shadow tree's p rule styles its own p", field("inner") === "rgb(10, 11, 12)", got);
check("::slotted(p) styles the node the slot took", field("light") === "rgb(7, 8, 9)", got);
check("the shadow sheet leaves the page alone", field("outside") === "rgb(0, 0, 0)", got);
check("an adopted sheet styles its tree's host", field("host2Pad") === "3px", got);
check("an adopted sheet's ::slotted rule styles the node the slot took", field("light2") === "rgb(9, 8, 7)", got);
console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
