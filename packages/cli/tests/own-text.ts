// An element whose text the build kept as its own rather than as a text child: every DOM view of
// its children has to show that text as a child.
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
<p id="a">hello</p>
<div id="b">plain <span>inner</span></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const a = document.getElementById("a")!;
const out: string[] = [];
out.push("text=" + a.textContent);
out.push("html=" + a.innerHTML);
out.push("outer=" + a.outerHTML);
out.push("childNodes=" + a.childNodes.length);
out.push("first=" + (a.firstChild === null ? "null" : a.firstChild.nodeType + ":" + a.firstChild.textContent));
out.push("last=" + (a.lastChild === null ? "null" : a.lastChild.nodeType + ":" + a.lastChild.textContent));
out.push("has=" + a.hasChildNodes());
out.push("children=" + a.children.length);
out.push("inner=" + a.innerText);
const copy = a.cloneNode(true);
out.push("clone=" + copy.textContent);
// The text survives an append to innerHTML, which replaced it before.
a.innerHTML += " world";
out.push("after=" + a.textContent);
const b = document.getElementById("b")!;
out.push("mixed=" + b.innerHTML);
console.log("OUT " + out.join(" | "));
`;

const dir = mkdtempSync(join(tmpdir(), "native-own-text-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: join(dir, "out.png") } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const line = (r.stdout + r.stderr).split("\n").find((l) => l.startsWith("OUT ")) ?? "";
const got = line.replace(/^OUT /, "");
const want = [
  "text=hello",
  "html=hello",
  "outer=<p id=\"a\">hello</p>",
  "childNodes=1",
  "first=3:hello",
  "last=3:hello",
  "has=true",
  "children=0",
  "inner=hello",
  "clone=hello",
  "after=hello world",
  "mixed=plain <span>inner</span>",
].join(" | ");
check("every DOM view of an own-text element shows its text", got === want, `got ${got}`);
check("childNodes hands a text node", got.includes("first=3:hello"), got);

const fails = (r.stdout + r.stderr).split("\n").filter((l) => l.startsWith("FAIL"));
if (fails.length > 0) for (const f of fails) console.log(f);
console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
