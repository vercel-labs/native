// A shadow tree is styled by its own sheets: a document's author rules stop at the host, the UA
// sheet still reaches inside, and :focus-within follows the flattened tree through the host.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><title>shadow-scoping</title><style>
div { color: rgb(0, 0, 255); }
</style></head><body>
<div id="outer"><div id="host"><span>light</span></div></div>
<template id="tpl">
<style>
div { background-color: rgb(0, 255, 0); }
</style>
<div id="inner" tabindex="1"></div>
</template>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const log = (s: string): void => { console.log(s); };
const host = document.getElementById("host") as HTMLElement;
const tpl = document.getElementById("tpl") as HTMLTemplateElement;
const shadow = host.attachShadow({ mode: "open" });
shadow.appendChild(document.importNode(tpl.content, true));
const inner = shadow.getElementById("inner") as HTMLElement;
const style = (el: HTMLElement): string => {
  const s = getComputedStyle(el);
  return s.color + "/" + s.backgroundColor;
};
log("inner " + style(inner) + " host " + style(host) + " outer " + style(document.getElementById("outer") as HTMLElement));
inner.focus();
log("focus " + inner.matches(":focus-within") + " " + host.matches(":focus-within") + " " +
  (document.getElementById("outer") as HTMLElement).matches(":focus-within"));
`;

const EXPECTED_LOG = [
  // The shadow sheet's background reaches the inner div; the document's colour stops at the
  // host and only reaches the inner div by inheritance.
  "inner rgb(0, 0, 255)/rgb(0, 255, 0) host rgb(0, 0, 255)/rgba(0, 0, 0, 0) outer rgb(0, 0, 255)/rgba(0, 0, 0, 0)",
  "focus true true true",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-shadow-scoping-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame" } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);

const got = r.stdout.split("\n").slice(0, -1);
for (const line of got) console.log(`     got ${JSON.stringify(line)}`);
if (got.length === EXPECTED_LOG.length) {
  for (let i = 0; i < got.length; i++) check(EXPECTED_LOG[i], got[i] === EXPECTED_LOG[i], `got ${JSON.stringify(got[i])}`);
} else {
  check(`log lines (${EXPECTED_LOG.length})`, false, `got ${got.length}`);
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
