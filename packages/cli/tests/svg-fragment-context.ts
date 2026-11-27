// The namespace a fragment parses into follows HTML's fragment-parsing context element: the
// element the new nodes become children of. insertAdjacentHTML('beforebegin'|'afterend') takes
// the parent, so siblings of an <svg> in an HTML box are HTML; the other positions take the
// element itself. An SVG <foreignObject>'s children are HTML again, whether they come from markup
// inside it or from innerHTML on it. innerHTML, outerHTML and setHTMLUnsafe follow the same rule.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=200, height=100"><style>
body { margin: 0; }
#host { width: 100px; height: 50px; }
#a, #b { width: 50px; height: 50px; }
</style></head><body>
<div id="host"><svg id="a" viewBox="0 0 10 10"></svg></div>
<svg id="b" viewBox="0 0 10 10"><svg id="c" viewBox="0 0 10 10"></svg></svg>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const SVG = "http://www.w3.org/2000/svg";
const XHTML = "http://www.w3.org/1999/xhtml";
const ns = (id: string): string => {
  const e = document.getElementById(id);
  return e === null ? "none" : String(e.namespaceURI);
};
const a = document.getElementById("a") as Element;
const b = document.getElementById("b") as Element;
const c = document.getElementById("c") as Element;
// Siblings of the <svg> in the HTML box parse against its parent, so they are HTML.
a.insertAdjacentHTML("beforebegin", '<span id="before"></span>');
const before = ns("before");
a.insertAdjacentHTML("afterend", '<span id="after"></span>');
const after = ns("after");
// Its children parse against the <svg> itself.
a.insertAdjacentHTML("afterbegin", '<circle id="inside" r="1"/>');
const inside = ns("inside");
a.setHTMLUnsafe('<rect id="unsafe" width="1" height="1"/>');
const unsafe = ns("unsafe");
// A sibling inside another <svg> parses against that <svg>, so it is SVG.
c.insertAdjacentHTML("beforebegin", '<circle id="sib" r="1"/>');
const sib = ns("sib");
// foreignObject's children are HTML, from assigned markup and from innerHTML on it.
b.innerHTML = '<foreignObject id="fo"><div id="deep"></div></foreignObject>';
const fo = ns("fo");
const deep = ns("deep");
const foEl = document.getElementById("fo") as Element;
foEl.innerHTML = '<b id="fohtml"></b>';
const fohtml = ns("fohtml");
// outerHTML parses against the parent: a replacement in the HTML box is HTML.
(document.getElementById("before") as Element).outerHTML = '<i id="replaced"></i>';
const replaced = ns("replaced");
console.log("before=" + before);
console.log("after=" + after);
console.log("inside=" + inside);
console.log("unsafe=" + unsafe);
console.log("sib=" + sib);
console.log("fo=" + fo);
console.log("deep=" + deep);
console.log("fohtml=" + fohtml);
console.log("replaced=" + replaced);
console.log("svg=" + SVG);
console.log("xhtml=" + XHTML);
`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-svg-fragment-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame" } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);

const logged: Record<string, string> = {};
for (const line of r.stdout.split("\n")) {
  const at = line.indexOf("=");
  if (at > 0) logged[line.slice(0, at)] = line.slice(at + 1);
}
const svg = logged.svg ?? "http://www.w3.org/2000/svg";
const xhtml = logged.xhtml ?? "http://www.w3.org/1999/xhtml";

// insertAdjacentHTML beside an <svg> in an HTML box: the parent is the context, so HTML.
check("beforebegin on an <svg> in HTML makes an HTML sibling", logged.before === xhtml, logged.before);
check("afterend on an <svg> in HTML makes an HTML sibling", logged.after === xhtml, logged.after);
// Inside the <svg>: the element itself is the context.
check("afterbegin on an <svg> makes an SVG child", logged.inside === svg, logged.inside);
check("setHTMLUnsafe on an <svg> makes SVG children", logged.unsafe === svg, logged.unsafe);
// Beside an <svg> that sits in another <svg>: the parent is still SVG.
check("beforebegin on an <svg> inside an <svg> makes an SVG sibling", logged.sib === svg, logged.sib);
// foreignObject is SVG, its children are HTML.
check("an assigned foreignObject is SVG", logged.fo === svg, logged.fo);
check("markup inside a foreignObject is HTML", logged.deep === xhtml, logged.deep);
check("innerHTML on a foreignObject is HTML", logged.fohtml === xhtml, logged.fohtml);
// outerHTML parses against the parent.
check("outerHTML in an HTML box makes an HTML replacement", logged.replaced === xhtml, logged.replaced);

if (failed > 0) {
  console.error(`\n${failed} check${failed === 1 ? "" : "s"} failed`);
  process.exit(1);
}
console.log("\nall fragment context checks passed");
