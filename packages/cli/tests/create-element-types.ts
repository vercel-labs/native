// createElement() names the class the runtime builds for the tag, so the element's own API is
// typed without a cast: an anchor has href, a button has type, a textarea has value. The tags
// with a class of their own come from the same table newElementFor() builds.   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta charset="utf-8"><meta name="native-window" content="width=400, height=200"></head><body>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const a = document.createElement("a");
a.href = "https://example.com";
a.textContent = "link";
const b = document.createElement("button");
b.type = "submit";
b.textContent = "go";
const t = document.createElement("textarea");
t.value = "typed";
const s = document.createElement("select");
const o = document.createElement("option");
o.value = "one";
o.textContent = "One";
s.appendChild(o);
s.selectedIndex = 0;
const f = document.createElement("form");
f.appendChild(b);
const div: HTMLDivElement = document.createElement("div");
div.textContent = "box";
const h: HTMLHeadingElement = document.createElement("h2");
h.textContent = "Title";
const p: HTMLParagraphElement = document.createElement("p");
p.textContent = "Para";
const unknown: HTMLElement = document.createElement("my-widget");
unknown.textContent = "custom";
const log = document.createElement("p");
log.id = "log";
log.textContent = a.href + "|" + b.type + "|" + t.value + "|" + String(s.selectedIndex) + "|" + o.value + "|" + div.tagName + "|" + h.tagName + "|" + p.tagName + "|" + unknown.tagName + "|" + f.tagName;
document.body.appendChild(a);
document.body.appendChild(t);
document.body.appendChild(s);
document.body.appendChild(div);
document.body.appendChild(h);
document.body.appendChild(p);
document.body.appendChild(unknown);
document.body.appendChild(f);
document.body.appendChild(log);
`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-create-element-types-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const run = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame 0 | frame 16 | print #log" } });
if (run.status !== 0) throw new Error(`run failed\n${run.stderr}`);
const got = run.stdout.trim();
console.log(`     got ${got}`);
check("a created element carries its tag's own type and class",
  got === "https://example.com|submit|typed|0|one|DIV|H2|P|MY-WIDGET|FORM", got);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
