// Document order (Node.compareDocumentPosition()) and document.createTreeWalker(): the bitmask
// that says where one node sits relative to another, and the walk over a subtree that takes only
// the node types a walker asks for and what its filter accepts or skips. The expectations are
// DOM's constants and the order Chrome walks the same page in.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=300"><style>
body { margin: 0; font: 16px monospace; }
</style></head><body>
<div id="root"><p id="a">alpha</p><div id="b"><span id="c">beta</span><!-- note --></div><p id="d">delta</p></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function log(s: string): void { console.log(s); }
function $(id: string): HTMLElement { return document.getElementById(id) as HTMLElement; }
function idOf(n: Node | null): string { return n === null ? "null" : (n as HTMLElement).id; }
const root = $("root");
const a = $("a");
const b = $("b");
const c = $("c");
const d = $("d");

// The bitmask: FOLLOWING 4, PRECEDING 2, CONTAINS 8, CONTAINED_BY 16, DISCONNECTED 1, and 32
// when the two are in different trees.
log("self " + a.compareDocumentPosition(a));
log("after " + a.compareDocumentPosition(b));
log("before " + b.compareDocumentPosition(a));
log("holds " + root.compareDocumentPosition(c));
log("inside " + c.compareDocumentPosition(root));
log("deep " + a.compareDocumentPosition(c));
log("deepback " + c.compareDocumentPosition(a));
const loose = document.createElement("div");
log("loose " + a.compareDocumentPosition(loose));
log("looseback " + loose.compareDocumentPosition(a));

// The walker's constants are the DOM's.
log("bits " + NodeFilter.SHOW_ELEMENT + " " + NodeFilter.SHOW_TEXT + " " + NodeFilter.SHOW_COMMENT + " " + NodeFilter.SHOW_ALL);
// The legacy entity and notation constants are still on the interface.
log("legacy " + NodeFilter.SHOW_ENTITY_REFERENCE + " " + NodeFilter.SHOW_ENTITY + " " + NodeFilter.SHOW_NOTATION);

// Elements only, forwards, then backwards from the end.
const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
const forward: string[] = [];
for (let n: Node | null = walker.nextNode(); n !== null; n = walker.nextNode()) {
  forward.push((n as HTMLElement).id);
}
log("elements " + forward.join(","));
const back: string[] = [];
while (walker.previousNode() !== null) back.push((walker.currentNode as HTMLElement).id);
log("back " + back.join(","));

// The steps a walker takes from one node: child, sibling, parent, and where it is.
walker.currentNode = root;
log("first " + idOf(walker.firstChild()));
log("at " + (walker.currentNode as HTMLElement).id);
log("next " + idOf(walker.nextSibling()));
log("parent " + idOf(walker.parentNode()));
walker.currentNode = b;
log("last " + idOf(walker.lastChild()));
walker.currentNode = d;
log("prev " + idOf(walker.previousSibling()));
// The root is the last node a walk backwards reaches, and no step goes past it.
walker.currentNode = a;
log("prevroot " + idOf(walker.previousNode()));
walker.currentNode = root;
log("rootparent " + idOf(walker.parentNode()));
log("rootnext " + idOf(walker.nextNode()));

// Text nodes, and a filter that rejects or skips one element.
const text = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
const runs: string[] = [];
while (text.nextNode() !== null) runs.push(text.currentNode.textContent ?? "");
log("text " + runs.join("|"));

const reject = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT, (n: Node) =>
  (n as HTMLElement).id === "b" ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT);
const rejected: string[] = [];
while (reject.nextNode() !== null) rejected.push((reject.currentNode as HTMLElement).id);
log("reject " + rejected.join(","));

const skip = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT, {
  acceptNode(n: Node): number {
    return (n as HTMLElement).id === "b" ? NodeFilter.FILTER_SKIP : NodeFilter.FILTER_ACCEPT;
  },
});
const skipped: string[] = [];
while (skip.nextNode() !== null) skipped.push((skip.currentNode as HTMLElement).id);
log("skip " + skipped.join(","));

// A comment is a node type of its own. The build folds a comment in the markup away, so the page
// makes one at runtime, as a browser's DOM would already have the one in the markup.
b.appendChild(document.createComment("note"));
const comments = document.createTreeWalker(root, NodeFilter.SHOW_COMMENT);
log("comment " + String(comments.nextNode() !== null) + " " + String(comments.nextNode() === null));
walker.currentNode = root;
log("root " + idOf(walker.currentNode as HTMLElement));

// A cursor visits the same nodes one at a time, and it keeps going after the caller removes the
// node it handed out (the reference node loses its parent, so the cursor remembers what follows).
const strip = document.createElement("div");
strip.appendChild(document.createTextNode("  "));
const keep = document.createElement("span");
keep.appendChild(document.createTextNode("kept"));
strip.appendChild(keep);
strip.appendChild(document.createTextNode("\t"));
const cursor = document.createNodeIterator(strip, NodeFilter.SHOW_TEXT, (n: Node) =>
  (n as Text).data.replace(/\\s/g, "").length === 0 ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT);
const gone: string[] = [];
for (let n: Node | null = cursor.nextNode(); n !== null; n = cursor.nextNode()) {
  gone.push(JSON.stringify((n as Text).data));
  n.remove();
}
log("iter " + gone.join(",") + " left " + strip.childNodes.length + " " + strip.textContent);
`;

const EXPECTED = [
  "self 0",
  "after 4",
  "before 2",
  "holds 20",
  "inside 10",
  "deep 4",
  "deepback 2",
  "loose 37",
  "looseback 35",
  "bits 1 4 128 4294967295",
  "legacy 16 32 2048",
  "elements a,b,c,d",
  "back c,b,a,root",
  "first a",
  "at a",
  "next b",
  "parent root",
  "last c",
  "prev b",
  "prevroot root",
  "rootparent null",
  "rootnext a",
  "text alpha|beta|delta",
  "reject a,d",
  "skip a,c,d",
  "comment true true",
  "root root",
  'iter "  ","\\t" left 1 kept',
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-traversal-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: "frame 0" };
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
