// document.execCommand() on a contenteditable host: bold/italic/underline, formatBlock,
// createLink, removeFormat, insertText and undo, with queryCommandState reporting each style the
// caret is in. The editor example's toolbar uses these.   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta charset="utf-8"><meta name="native-window" content="width=420, height=240"><style>
body { margin: 0; }
#e { position: absolute; left: 10px; top: 10px; width: 380px; min-height: 120px; font: 20px sans-serif; }
</style></head><body>
<div id="e" contenteditable="true"><h1>Heading</h1><p>Some words to select</p></div>
<p id="log"></p>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const host = document.getElementById("e") as HTMLElement;
const log = document.getElementById("log")!;
const lines: string[] = [];
function say(text: string): void {
  lines.push(text);
  log.textContent = lines.join("|");
}
function selectText(start: number, end: number): string {
  const p = host.querySelector("p")!;
  const node = p.firstChild!;
  const range = document.createRange();
  range.setStart(node, start);
  range.setEnd(node, end);
  const sel = document.getSelection()!;
  sel.removeAllRanges();
  sel.addRange(range);
  return sel.toString();
}

const picked = selectText(0, 9);
say("picked=" + picked + " state=" + String(document.queryCommandState("bold")));
say("bold=" + String(document.execCommand("bold", false, "")) + " state=" + String(document.queryCommandState("bold")) + " strong=" + String(host.querySelectorAll("strong").length));
say("italic=" + String(document.execCommand("italic", false, "")) + " em=" + String(host.querySelectorAll("em").length));
say("removeFormat=" + String(document.execCommand("removeFormat", false, "")) + " strong=" + String(host.querySelectorAll("strong").length) + " em=" + String(host.querySelectorAll("em").length));

selectText(5, 10);
say("link=" + String(document.execCommand("createLink", false, "https://example.com")) + " href=" + String(host.querySelector("a")!.getAttribute("href")));
say("linkState=" + String(document.queryCommandState("createLink")));
document.execCommand("removeFormat", false, "");

const p = host.querySelector("p")!;
const blockRange = document.createRange();
blockRange.selectNodeContents(p);
const sel = document.getSelection()!;
sel.removeAllRanges();
sel.addRange(blockRange);
say("block=" + String(document.execCommand("formatBlock", false, "<h2>")) + " h2=" + String(host.querySelectorAll("h2").length));

const caret = document.createRange();
caret.setStart(host, 0);
caret.collapse(true);
sel.removeAllRanges();
sel.addRange(caret);
say("insert=" + String(document.execCommand("insertText", false, "Note: ")) + " text=" + String(host.textContent).slice(0, 12));
say("undo=" + String(document.execCommand("undo", false, "")) + " text=" + String(host.textContent).slice(0, 12));
say("redo=" + String(document.execCommand("redo", false, "")) + " text=" + String(host.textContent).slice(0, 12));
`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-edit-commands-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const run = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame 0 | print #log" } });
if (run.status !== 0) throw new Error(`run failed\n${run.stderr}`);
const got = run.stdout.trim();
const want = [
  "picked=Some word state=false",
  "bold=true state=true strong=1",
  "italic=true em=1",
  "removeFormat=true strong=0 em=0",
  "link=true href=https://example.com",
  "linkState=true",
  "block=true h2=1",
  "insert=true text=Note: Headin",
  "undo=true text=HeadingSome ",
  "redo=true text=Note: Headin",
].join("|");
check("the editing commands act on the host, and the state follows", got === want, `got ${JSON.stringify(got)}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
