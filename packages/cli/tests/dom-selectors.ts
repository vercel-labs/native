// Regression tests for the selector-taking DOM methods: querySelector, querySelectorAll,
// matches and closest. They take the same selectors the style sheets do, with the combinators,
// selector lists, :is()/:where()/:not(), attribute selectors and :scope, and an invalid selector
// throws as it does in a browser. Every expected line was taken from Chrome.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=900"><style>
body { margin: 0; font-family: system-ui; font-size: 16px; }
</style></head><body>
<div id="root">
<div class="wrap"><p class="a" data-k="1">one</p><p class="b">two</p><p class="c">three</p></div>
<p class="sp"><span id="s1">ab</span> <span id="s2">cd</span></p>
<p class="sp2"><span id="s5">x<span id="s6">y</span>z</span></p>
</div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function ids(list: Element[]): string {
  return JSON.stringify(list.map((e: Element) =>
    e.id !== "" ? e.id : e.tagName.toLowerCase() + ":" + e.className));
}
function one(selector: string): string {
  const e = document.querySelector(selector);
  return e === null ? "null" : (e.id !== "" ? e.id : e.tagName.toLowerCase());
}
function err(f: () => void): string {
  try {
    f();
    return "no error";
  } catch (e) {
    // Browsers throw a DOMException whose name and message read together as these lines do.
    // The runtime has no DOMException class, so its message carries the name itself.
    return (e as Error).message;
  }
}
const out: string[] = [];
out.push("descendant=" + ids(document.querySelectorAll("div p")));
out.push("child=" + ids(document.querySelectorAll("div > p")));
out.push("adjacent=" + ids(document.querySelectorAll("p + p")));
out.push("general=" + ids(document.querySelectorAll("p ~ p")));
out.push("list=" + ids(document.querySelectorAll("p.a, p.c")));
out.push("is=" + ids(document.querySelectorAll(":is(p.a, p.c)")) +
  " where=" + ids(document.querySelectorAll(":where(p.a)")) +
  " not=" + ids(document.querySelectorAll("p:not(.a)")));
out.push("not list=" + ids(document.querySelectorAll("p:not(.a, .c)")) +
  " not checked=" + ids(document.querySelectorAll("p:not(:checked)")));
out.push("attr=" + ids(document.querySelectorAll("[data-k]")) +
  " " + ids(document.querySelectorAll("[data-k='1']")) +
  " " + ids(document.querySelectorAll('[data-k^="1"]')));
out.push("attr descendant=" + ids(document.querySelectorAll("#root [data-k]")) +
  " " + ids(document.querySelectorAll("#root [data-k='1']")) +
  " " + ids(document.querySelectorAll(".wrap [data-k]")) +
  " " + ids(document.querySelectorAll("#root > .wrap [data-k]")));
out.push("attr flag=" + ids(document.querySelectorAll("[data-k='1' i]")) +
  " " + ids(document.querySelectorAll("[class~=a]")) +
  " " + ids(document.querySelectorAll('[data-k|="1"]')));
out.push("nth=" + ids(document.querySelectorAll(".wrap p:nth-child(2)")) +
  " " + ids(document.querySelectorAll("p:first-child")));
out.push("star=" + ids(document.querySelectorAll("*.a")) +
  " uc=" + ids(document.querySelectorAll("DIV > P.a")));
const a = document.querySelector("p.a") as Element;
out.push("matches=" + a.matches(".wrap p") + " " + a.matches("div > p") + " " +
  a.matches("p + p") + " " + a.matches(":scope") + " " + a.matches("span"));
out.push("closest=" + (a.closest(".wrap") === null ? "null" : "wrap") + " " +
  (a.closest("span") === null ? "null" : "span") + " " +
  (a.closest("div p") as Element).className);
const wrap = document.querySelector(".wrap") as Element;
out.push("element scope=" + (wrap.querySelector(":scope > p") as Element).className + " " +
  wrap.querySelectorAll(":scope > p").length + " " + wrap.querySelectorAll(":scope p").length);
out.push("document scope=" + one(":scope") + " " +
  ids(document.querySelectorAll(":scope > html")) + " " + document.documentElement.matches(":scope"));
out.push("pseudo chars=" + one("p::before") + " " + one("p::first-line") + " " + one("::selection"));
out.push("checked=" + one(":checked") + " empty=" + one("p:empty"));
out.push("invalid1=" + err(() => document.querySelector("p >")));
out.push("invalid2=" + err(() => document.querySelector(",")));
out.push("invalid3=" + err(() => document.querySelector("[a=")));
out.push("invalid4=" + err(() => document.querySelector("p:nth-child(foo)")));
out.push("invalid5=" + err(() => document.querySelector("")));
out.push("invalid6=" + err(() => document.querySelector("div p,")));
out.push("invalid7=" + err(() => document.querySelector("> p")));
out.push("invalid8=" + err(() => document.querySelector("p::")));
out.push("invalid9=" + err(() => document.querySelector("[data-k^=1]")));
out.push("invalid10=" + err(() => document.querySelector(".1a")));
out.push("invalid11=" + err(() => document.querySelector("p::before span")));
out.push("invalid matches=" + err(() => a.matches("p >")));
out.push("invalid closest=" + err(() => a.closest("p >")));
out.push("invalid all=" + err(() => document.querySelectorAll("p >")));
for (const line of out) console.log(line);
`;

// The lines Chrome prints for the same page and script.
const EXPECTED_LOG: [string, string][] = [
  ["the child combinator", "child=[\"p:a\",\"p:b\",\"p:c\",\"p:sp\",\"p:sp2\"]"],
  ["the descendant combinator", "descendant=[\"p:a\",\"p:b\",\"p:c\",\"p:sp\",\"p:sp2\"]"],
  ["the adjacent sibling combinator", "adjacent=[\"p:b\",\"p:c\",\"p:sp2\"]"],
  ["the general sibling combinator", "general=[\"p:b\",\"p:c\",\"p:sp2\"]"],
  ["a selector list", "list=[\"p:a\",\"p:c\"]"],
  ["a selector list", "is=[\"p:a\",\"p:c\"] where=[\"p:a\"] not=[\"p:b\",\"p:c\",\"p:sp\",\"p:sp2\"]"],
  ["a comma list inside :not()", "not list=[\"p:b\",\"p:sp\",\"p:sp2\"] not checked=[\"p:a\",\"p:b\",\"p:c\",\"p:sp\",\"p:sp2\"]"],
  ["attribute selectors", "attr=[\"p:a\"] [\"p:a\"] [\"p:a\"]"],
  // A space before an attribute selector still separates compounds: the attribute names the
  // element below the one on the left, not the same element.
  ["an attribute selector after a descendant combinator", "attr descendant=[\"p:a\"] [\"p:a\"] [\"p:a\"] [\"p:a\"]"],
  ["attribute selectors with operators and flags", "attr flag=[\"p:a\"] [\"p:a\"] [\"p:a\"]"],
  ["structural pseudo-classes", "nth=[\"p:b\"] [\"p:a\"]"],
  ["* and upper-case type selectors", "star=[\"p:a\"] uc=[\"p:a\"]"],
  ["matches() takes combinators and :scope", "matches=true true false true false"],
  ["closest() walks the ancestors", "closest=wrap null a"],
  ["an element's query is scoped to it", "element scope=a 3 3"],
  ["the document's query is scoped to the root", "document scope=html [] true"],
  ["pseudo-elements name nothing", "pseudo chars=null null null"],
  ["an unknown pseudo-class names nothing", "checked=null empty=null"],
  ["a dangling combinator throws", "invalid1=SyntaxError: Failed to execute 'querySelector' on 'Document': 'p >' is not a valid selector."],
  ["a bare comma throws", "invalid2=SyntaxError: Failed to execute 'querySelector' on 'Document': ',' is not a valid selector."],
  ["an unclosed attribute selector throws", "invalid3=SyntaxError: Failed to execute 'querySelector' on 'Document': '[a=' is not a valid selector."],
  ["a bad :nth-child() argument throws", "invalid4=SyntaxError: Failed to execute 'querySelector' on 'Document': 'p:nth-child(foo)' is not a valid selector."],
  ["an empty selector throws", "invalid5=SyntaxError: Failed to execute 'querySelector' on 'Document': The provided selector is empty."],
  ["a trailing comma throws", "invalid6=SyntaxError: Failed to execute 'querySelector' on 'Document': 'div p,' is not a valid selector."],
  ["a leading combinator throws", "invalid7=SyntaxError: Failed to execute 'querySelector' on 'Document': '> p' is not a valid selector."],
  ["an empty pseudo-element throws", "invalid8=SyntaxError: Failed to execute 'querySelector' on 'Document': 'p::' is not a valid selector."],
  ["an unquoted attribute value starting with a digit throws", "invalid9=SyntaxError: Failed to execute 'querySelector' on 'Document': '[data-k^=1]' is not a valid selector."],
  ["a class starting with a digit throws", "invalid10=SyntaxError: Failed to execute 'querySelector' on 'Document': '.1a' is not a valid selector."],
  ["a pseudo-element in the middle throws", "invalid11=SyntaxError: Failed to execute 'querySelector' on 'Document': 'p::before span' is not a valid selector."],
  ["matches() throws too", "invalid matches=SyntaxError: Failed to execute 'matches' on 'Element': 'p >' is not a valid selector."],
  ["closest() throws too", "invalid closest=SyntaxError: Failed to execute 'closest' on 'Element': 'p >' is not a valid selector."],
  ["querySelectorAll() throws too", "invalid all=SyntaxError: Failed to execute 'querySelectorAll' on 'Document': 'p >' is not a valid selector."],
];

function buildAndRun(): string {
  const dir = mkdtempSync(join(tmpdir(), "native-dom-selectors-"));
  writeFileSync(join(dir, "index.html"), PAGE);
  writeFileSync(join(dir, "app.ts"), SCRIPT);
  const exe = join(dir, "app");
  const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
  if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
  const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: join(dir, "out.png") } });
  if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
  return `${r.stdout}${r.stderr}`;
}

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const out = buildAndRun();
const lines = out.split("\n");
EXPECTED_LOG.forEach(([name, want]) => {
  check(name, lines.includes(want), `want line "${want}"`);
});

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
