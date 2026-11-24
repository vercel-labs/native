// :focus-visible matches the focus a UA shows a ring for: keyboard focus (Tab, or focus() after
// a key press), and any focus of a text field, which always accepts keyboard input. A pointer
// press focuses but doesn't match it. Each case pairs a focusable with the sibling box its
// state colours, so a snapshot of one run shows what one interaction did.   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

// Each case is 40 CSS px tall: the focusable on top, the marker it colours below. The window is
// 200 by 240, so case i's marker covers device rows [80i + 40, 80i + 80).
const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=200, height=240"><style>
body { margin: 0; background: #ffffff; }
.box, .m { display: block; height: 20px; background: #000000; }
#in { display: block; width: 200px; height: 20px; border: 0; padding: 0; margin: 0; font-size: 12px; }
#a:focus + .ma { background: #0000ff; }
#a:focus-visible + .ma { background: #ff0000; }
#b:focus + .mb { background: #0000ff; }
#b:focus-visible + .mb { background: #00ff00; }
#in:focus + .mi { background: #0000ff; }
#in:focus-visible + .mi { background: #00ffff; }
#p:focus + .mp { background: #0000ff; }
#p:focus-visible + .mp { background: #ffffff; }
</style></head><body>
<div id="a" class="box" tabindex="0"></div><div class="m ma"></div>
<div id="b" class="box" tabindex="0"></div><div class="m mb"></div>
<input id="in"><div class="m mi"></div>
<div id="p" class="box" tabindex="0"></div><div class="m mp"></div>
<div id="go1" class="box" tabindex="0" onclick="document.getElementById('p').focus()"></div><div class="m"></div>
<div id="go2" class="box" tabindex="0" onclick="document.getElementById('p').focus({focusVisible: true})"></div><div class="m"></div>
</body></html>`;

const BLACK = "0,0,0";
const BLUE = "0,0,255"; // :focus only
const RED = "255,0,0"; // both, for #a
const GREEN = "0,255,0";
const CYAN = "0,255,255";
const WHITE = "255,255,255";

// One run per interaction: [steps, each case's marker colour after them].
const CASES: [string, string, string[]][] = [
  ["a pointer press focuses without :focus-visible", "click #a", [BLUE, BLACK, BLACK, BLACK]],
  ["Tab moves focus, and it is :focus-visible", "key Tab", [RED, BLACK, BLACK, BLACK]],
  ["a text field is :focus-visible even when clicked", "click #in", [BLACK, BLACK, CYAN, BLACK]],
  ["focus() inside a click handler isn't :focus-visible", "click #go1", [BLACK, BLACK, BLACK, BLUE]],
  ["focus({focusVisible: true}) is :focus-visible", "click #go2", [BLACK, BLACK, BLACK, WHITE]],
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-focus-visible-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
check("the build doesn't report the selectors as unsupported", !/is not supported yet/.test(b.stderr),
  b.stderr.trim());

CASES.forEach(([name, steps, want], run) => {
  const png = join(dir, `out${run}.png`);
  const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: steps, NATIVE_SNAPSHOT: png } });
  if (r.status !== 0) throw new Error(`render failed ('${steps}')\n${r.stderr}`);
  const img = decodePng(png);
  want.forEach((expected, i) => {
    const o = ((80 * i + 60) * img.w + 100) * 4;
    const got = `${img.rgba[o]},${img.rgba[o + 1]},${img.rgba[o + 2]}`;
    check(`${name}: case ${i} is ${expected}`, got === expected, `got ${got} after '${steps}'`);
  });
});

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
