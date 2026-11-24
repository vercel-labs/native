// A disabled button keeps the background its rules give it, paints its label, and takes the UA's
// grey for the text when no author rule names a colour — Chrome's treatment of :disabled. The
// variants here are the ways an app sets a button's background: a plain colour, a CSS variable,
// a translucent colour, a class, and a button in a flex row.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=260, height=140"><style>
body { margin: 0; background: #444444; }
:root { --button-bg: #ffffff; }
button { border: 0; padding: 6px 12px; font-size: 12px; }
#plain, #variable, #alpha, #flexed { background: #ffffff; color: #111111; }
#variable { background: var(--button-bg); }
#alpha { background-color: rgba(255, 255, 255, 0.5); }
#author { background: #ffffff; color: rgb(9, 9, 9); }
.row { display: flex; }
</style></head><body>
<button id="plain" disabled>plain</button>
<button id="variable" disabled>variable</button>
<button id="alpha" disabled>alpha</button>
<div class="row"><button id="flexed" disabled>flex</button></div>
<button id="bare" disabled>bare</button>
<button id="author" disabled>author</button>
<script type="module" src="app.ts"></script>
</body></html>`;

const APP = `
const show = (id: string): void => {
  const el = document.getElementById(id)!;
  const cs = getComputedStyle(el);
  console.log(id + " bg [" + cs.backgroundColor + "] color [" + cs.color + "]");
};
requestAnimationFrame(() => {
  show("plain");
  show("variable");
  show("alpha");
  show("flexed");
  show("bare");
  show("author");
});
`;

const EXPECTED = [
  "plain bg [rgb(255, 255, 255)] color [rgb(17, 17, 17)]",
  "variable bg [rgb(255, 255, 255)] color [rgb(17, 17, 17)]",
  "alpha bg [rgba(255, 255, 255, 0.502)] color [rgb(17, 17, 17)]",
  "flexed bg [rgb(255, 255, 255)] color [rgb(17, 17, 17)]",
  // No author colour: the UA's grey, on the UA's own button background.
  "bare bg [rgb(239, 239, 239)] color [rgb(118, 118, 118)]",
  // An author colour still wins over the UA's.
  "author bg [rgb(255, 255, 255)] color [rgb(9, 9, 9)]",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-disabled-button-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), APP);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const png = join(dir, "out.png");
const r = spawnSync(exe, [], {
  encoding: "utf8",
  env: { ...process.env, NATIVE_SNAPSHOT: png, NATIVE_STEPS: "frame | frame" },
});
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);

const got = r.stdout.split("\n").slice(0, -1);
check(`log lines (${EXPECTED.length})`, got.length === EXPECTED.length, `got ${got.length}: ${JSON.stringify(got)}`);
for (let i = 0; i < Math.min(got.length, EXPECTED.length); i++) {
  check(EXPECTED[i], got[i] === EXPECTED[i], `got ${JSON.stringify(got[i])}`);
}

const img = decodePng(png);
/** The pixel at CSS coordinates (cx, cy), as [r, g, b]. */
function at(cx: number, cy: number): number[] {
  const o = (Math.floor(cy * 2) * img.w + Math.floor(cx * 2)) * 4;
  return [img.rgba[o], img.rgba[o + 1], img.rgba[o + 2]];
}
function near(px: number[], want: number[], tol = 6): boolean {
  return px.every((p, i) => Math.abs(p - want[i]) <= tol);
}
const WHITE = [255, 255, 255], BG = [68, 68, 68];

check("a disabled button paints its background", near(at(10, 10), WHITE), `got ${at(10, 10).join(",")}`);
check("the page around it still shows", near(at(250, 130), BG), `got ${at(250, 130).join(",")}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
