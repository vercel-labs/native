// The selection editing commands leave behind: toggling a style off or removing formatting keeps
// the text selected, formatBlock acts on the block around a collapsed caret (including one sitting
// on the block element itself), and undo/redo put the caret back so the next typing lands where
// the change was.   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta charset="utf-8"><meta name="native-window" content="width=420, height=200"><style>
body { margin: 0; }
#e { position: absolute; left: 10px; top: 10px; width: 400px; min-height: 120px; font: 16px sans-serif; }
</style></head><body>
<div id="e" contenteditable="true"><p id="p1">alpha beta</p><p id="p2">gamma delta</p></div>
<p id="log">none</p>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const host = document.getElementById("e") as HTMLElement;
const log = document.getElementById("log") as HTMLElement;
const out: string[] = [];
function current(): HTMLElement {
  return document.getElementById("p1") as HTMLElement;
}
function selText(): string {
  const s = document.getSelection();
  return s === null ? "none" : s.toString();
}
interface Point { node: Text; offset: number; }
function find(node: Node, target: number, acc: { n: number }): Point | null {
  if (node.nodeType === 3) {
    const t = node as Text;
    if (target <= acc.n + t.data.length) return { node: t, offset: target - acc.n };
    acc.n += t.data.length;
    return null;
  }
  for (let i = 0; i < node.childNodes.length; i++) {
    const r = find(node.childNodes[i], target, acc);
    if (r !== null) return r;
  }
  return null;
}
function point(el: Element, target: number): Point {
  const acc = { n: 0 };
  const r = find(el, target, acc);
  if (r !== null) return r;
  let last: Point = { node: el as any, offset: 0 } as any;
  const walk = (n: Node): void => {
    if (n.nodeType === 3) last = { node: n as Text, offset: (n as Text).data.length };
    for (let i = 0; i < n.childNodes.length; i++) walk(n.childNodes[i]);
  };
  walk(el);
  return last;
}
function select(el: Element, a: number, b: number): void {
  const x = point(el, a);
  const y = point(el, b);
  const r = document.createRange();
  r.setStart(x.node, x.offset);
  r.setEnd(y.node, y.offset);
  const s = document.getSelection()!;
  s.removeAllRanges();
  s.addRange(r);
}
function caret(el: Element, at: number): void {
  const x = point(el, at);
  const r = document.createRange();
  r.setStart(x.node, x.offset);
  r.collapse(true);
  const s = document.getSelection()!;
  s.removeAllRanges();
  s.addRange(r);
}
function caretOn(el: Element): void {
  const r = document.createRange();
  r.setStart(el, 0);
  r.collapse(true);
  const s = document.getSelection()!;
  s.removeAllRanges();
  s.addRange(r);
}
function count(tag: string): number {
  return host.querySelectorAll(tag).length;
}

select(current(), 0, 5);
document.execCommand("bold", false, "");
out.push("bold1=" + selText(), "strong1=" + String(count("strong")));
document.execCommand("bold", false, "");
out.push("off=" + selText(), "strong2=" + String(count("strong")));
document.execCommand("italic", false, "");
out.push("italic=" + selText(), "em1=" + String(count("em")));
select(current(), 0, 5);
document.execCommand("removeFormat", false, "");
out.push("remove=" + selText(), "em2=" + String(count("em")), "strong3=" + String(count("strong")));
document.execCommand("bold", false, "");
out.push("afterRemove=" + selText(), "strong4=" + String(count("strong")));

caret(host.children[1], 5);
document.execCommand("formatBlock", false, "<h2>");
out.push("block=" + (host.children[1] as HTMLElement).tagName, "h2=" + String(count("h2")));
caretOn(host.children[1]);
document.execCommand("formatBlock", false, "<h3>");
out.push("blockStart=" + (host.children[1] as HTMLElement).tagName);
const end = document.createRange();
end.setStart(host, host.childNodes.length);
end.collapse(true);
const sel = document.getSelection()!;
sel.removeAllRanges();
sel.addRange(end);
document.execCommand("formatBlock", false, "<h4>");
out.push("blockEnd=" + (host.children[1] as HTMLElement).tagName);

caret(current(), 5);
document.execCommand("insertText", false, "X");
out.push("typed=" + String(current().textContent));
document.execCommand("undo", false, "");
out.push("undone=" + String(current().textContent));
document.execCommand("redo", false, "");
out.push("redone=" + String(current().textContent));
document.execCommand("undo", false, "");
out.push("undone2=" + String(current().textContent));
document.execCommand("insertText", false, "Y");
out.push("afterY=" + String(current().textContent));
log.textContent = out.join("|");
`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-edit-selection-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const run = spawnSync(exe, [], {
  encoding: "utf8",
  env: { ...process.env, NATIVE_STEPS: "frame 0 | frame 16 | print #log" },
});
if (run.status !== 0) throw new Error(`run failed\n${run.stderr}`);
const got = run.stdout.trim();
console.log(`     got ${got}`);
const want = "bold1=alpha|strong1=1|off=alpha|strong2=0|italic=alpha|em1=1|remove=alpha|em2=0|strong3=0|afterRemove=alpha|strong4=1|block=H2|h2=1|blockStart=H3|blockEnd=H4|typed=alphaX beta|undone=alpha beta|redone=alphaX beta|undone2=alpha beta|afterY=alphaY beta";
check("commands keep the selection, format the caret's block and restore the caret on undo and redo", got === want, got);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
