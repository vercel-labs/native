// A <template> in page markup keeps its content in its content fragment, where a script can
// clone it into a shadow tree, as the WPT shadow helpers do.
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
<div id="host"><template id="sr"><p id="inner">hi</p></template></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function probe(): void {
  const host = document.getElementById("host")!;
  const template = host.querySelector("template") as HTMLTemplateElement;
  const contentKids = template.content.childNodes.length;
  const markup = template.innerHTML;
  const contentInner = template.content.querySelector("#inner") === null ? "missing" : "found";
  const root = host.attachShadow({ mode: "open" });
  root.appendChild(document.importNode(template.content, true));
  const inner = root.querySelector("#inner")!;
  // A clone of the host carries the template's content too, as the WPT helpers rely on.
  const clone = host.cloneNode(true) as Element;
  const cloneTemplate = clone.querySelector("template") as HTMLTemplateElement;
  const cloneKids = cloneTemplate.content.childNodes.length;
  // Writing the template's markup goes through its content, and reads back from it.
  template.innerHTML = '<p id="inner2">two</p>';
  const rewrittenInner = template.content.querySelector("#inner2") === null ? "missing" : "found";
  const rewrittenMarkup = template.innerHTML;
  console.log("OUT "
    + "|contentKids=" + contentKids
    + "|markup=" + markup
    + "|contentInner=" + contentInner
    + "|inner=" + inner.textContent
    + "|display=" + getComputedStyle(template).display
    + "|rootKids=" + root.childNodes.length
    + "|cloneKids=" + cloneKids
    + "|rewrittenInner=" + rewrittenInner
    + "|rewrittenMarkup=" + rewrittenMarkup);
}
probe();
`;

const dir = mkdtempSync(join(tmpdir(), "native-template-"));
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
check("the template's markup is in its content", field("contentKids") === "1" && field("markup") === '<p id="inner">hi</p>', got);
check("its content can be imported into a shadow tree", field("inner") === "hi" && field("rootKids") === "1", got);
check("a template is never displayed", field("display") === "none", got);
check("cloning the page keeps the template's content", field("cloneKids") === "1", got);
check("content.querySelector finds the compiled markup", field("contentInner") === "found", got);
check("innerHTML writes into the content and reads back", field("rewrittenInner") === "found" && field("rewrittenMarkup") === '<p id="inner2">two</p>', got);
console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
