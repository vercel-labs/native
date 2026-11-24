// visibility: a hidden box keeps its room in the layout but paints nothing and takes no pointer
// event, it inherits, and a descendant that says `visible` shows again inside it.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const PAGE = `<!doctype html>
<html><head><meta charset="utf-8"><style>
body { margin: 0; background: #ffffff; font: 16px/1 sans-serif; }
#h1 { height: 40px; background: #0000ff; visibility: hidden; }
#f1 { height: 10px; background: #ffff00; }
#outer { position: absolute; left: 60px; top: 0; width: 50px; height: 50px; background: #00ff00;
         visibility: hidden; }
#inner { position: absolute; left: 5px; top: 5px; width: 20px; height: 20px; background: #ffff00;
         visibility: visible; }
#under { position: absolute; left: 120px; top: 0; width: 50px; height: 50px; background: #ff0000; }
#over { position: absolute; left: 120px; top: 0; width: 50px; height: 50px; background: #0000ff;
        visibility: hidden; }
</style></head><body>
<div id="h1"></div>
<div id="f1"></div>
<div id="outer"><div id="inner"></div></div>
<div id="under"></div>
<div id="over"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
document.addEventListener("click", (e) => {
  const t = e.target as HTMLElement;
  console.log("hit " + t.id);
});
console.log("hidden=" + getComputedStyle(document.getElementById("h1")!).visibility);
`;

const dir = mkdtempSync(join(tmpdir(), "native-visibility-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
check("visibility compiles without a warning", !/css property: visibility|'visibility'/.test(b.stdout + b.stderr), b.stderr);

const png = join(dir, "out.png");
const r = spawnSync(exe, [], {
  encoding: "utf8",
  env: { ...process.env, NATIVE_SNAPSHOT: png, NATIVE_STEPS: "click #under" },
});
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const img = decodePng(png);
const out = `${r.stdout}${r.stderr}`;

/** The colour at a CSS position, as "r,g,b". */
const colorAt = (x: number, y: number): string => {
  const o = (Math.round(y * 2) * img.w + Math.round(x * 2)) * 4;
  return `${img.rgba[o]},${img.rgba[o + 1]},${img.rgba[o + 2]}`;
};
const WHITE = "255,255,255";

check("the hidden box paints nothing", colorAt(10, 5) === WHITE, `got ${colorAt(10, 5)}`);
check("but keeps its room in the flow", colorAt(10, 45) === "255,255,0", `got ${colorAt(10, 45)}`);
check("a visible descendant of a hidden box paints", colorAt(70, 10) === "255,255,0", `got ${colorAt(70, 10)}`);
check("and the hidden box around it does not", colorAt(70, 35) === WHITE, `got ${colorAt(70, 35)}`);
check("a hidden box over another shows the one below", colorAt(125, 10) === "255,0,0", `got ${colorAt(125, 10)}`);
check("the hidden box takes no click", out.includes("hit under"), out.trim());
check("getComputedStyle reads it back", out.includes("hidden=hidden"), out.trim());

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
