// A quirks document reads ids and class names case-insensitively when it matches selectors, while
// a standards document is exact. Both pages add the same sheets at runtime.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const BODY = `<div id="foo" class="bar">x</div>
<script src="app.ts"></script>`;
const QUIRKS = `<!-- no doctype: quirks mode -->\n<html><head><title>quirks-selectors</title></head><body>${BODY}</body></html>`;
const STANDARDS = `<!doctype html>\n<html><head><title>quirks-selectors</title></head><body>${BODY}</body></html>`;

const SCRIPT = `
const log = (s: string): void => { console.log(s); };
const el = document.getElementById("foo") as HTMLElement;
const add = (css: string): void => {
  const style = document.createElement("style");
  style.textContent = css;
  document.body.appendChild(style);
};
add("#FoO { color: rgb(0, 128, 0); }");
add(".Bar { background-color: rgb(0, 0, 255); }");
const s = getComputedStyle(el);
log("quirks " + document.compatMode + " " + s.color + " " + s.backgroundColor);
`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

function run(page: string): string {
  const dir = mkdtempSync(join(tmpdir(), "native-quirks-selectors-"));
  writeFileSync(join(dir, "index.html"), page);
  writeFileSync(join(dir, "app.ts"), SCRIPT);
  const exe = join(dir, "app");
  const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
  if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
  const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame" } });
  if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
  return r.stdout.split("\n")[0];
}

const quirks = run(QUIRKS);
const standards = run(STANDARDS);
console.log(`     got ${JSON.stringify(quirks)}`);
console.log(`     got ${JSON.stringify(standards)}`);
check("a quirks document folds ids and classes", quirks === "quirks BackCompat rgb(0, 128, 0) rgb(0, 0, 255)", quirks);
check("a standards document does not", standards === "quirks CSS1Compat rgb(0, 0, 0) rgba(0, 0, 0, 0)", standards);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
