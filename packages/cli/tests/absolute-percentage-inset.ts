// A percentage inset on an absolutely positioned box resolves against the containing block's
// padding box however its height was reached: an auto-height wrapper around a field is the usual
// place an icon's `top: 50%` centres it.
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
<html><head><meta charset="utf-8"><meta name="native-window" content="width=400, height=300"><style>
body { margin: 0; }
#wrap { position: relative; margin: 40px; width: 300px; }
#inp { display: block; height: 36px; width: 256px; border: 0; background: #eeeeee; }
#icon { position: absolute; left: 12px; top: 50%; width: 16px; height: 16px; background: #ff0000; translate: 0 -50%; }
#wrap2 { position: relative; margin: 0 40px; width: 300px; height: 40px; }
#bottom { position: absolute; left: 0; bottom: 25%; width: 10px; height: 10px; background: #0000ff; }
</style></head><body>
<div id="wrap"><div id="icon"></div><input id="inp"></div>
<div id="wrap2"><div id="bottom"></div></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const rect = (id: string): DOMRect => document.getElementById(id)!.getBoundingClientRect();
const w = rect("wrap"), i = rect("icon"), inp = rect("inp"), w2 = rect("wrap2"), b = rect("bottom");
console.log("OUT icon=" + Math.round(i.top - w.top) + "," + Math.round(i.left - w.left) +
  " bottom=" + Math.round(w2.bottom - b.bottom) + " input=" + Math.round(inp.top - w.top));
`;

const dir = mkdtempSync(join(tmpdir(), "native-absolute-percent-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame | frame" } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const line = (r.stdout + r.stderr).split("\n").find((l) => l.startsWith("OUT ")) ?? "";
const got = line.replace(/^OUT /, "");

check("top: 50% resolves against an auto-height wrapper", got.includes("icon=18,12"), got);
check("bottom: 25% resolves the same way", got.includes("bottom=10"), got);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
