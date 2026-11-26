// Hiding a shadow host hides what its tree shows: a focused control inside loses the focus as a
// hidden one does.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><title>focus-hidden-shadow</title></head><body>
<div id="host"></div>
<template id="tpl"><input id="in"></template>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const log = (s: string): void => { console.log(s); };
const host = document.getElementById("host") as HTMLElement;
const shadow = host.attachShadow({ mode: "open" });
const tpl = document.getElementById("tpl") as HTMLTemplateElement;
shadow.appendChild(document.importNode(tpl.content, true));
const input = shadow.getElementById("in") as HTMLElement;
const active = (): string => {
  const el = document.activeElement;
  return el === null ? "null" : (el.id !== "" ? el.id : el.tagName.toLowerCase());
};
input.focus();
log("focused " + input.matches(":focus") + " " + active());
host.style.display = "none";
requestAnimationFrame(() => {
  log("hidden " + input.matches(":focus") + " " + active());
});
`;

const EXPECTED_LOG = ["focused true in", "hidden false body"];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-focus-hidden-shadow-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame | frame" } });
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
