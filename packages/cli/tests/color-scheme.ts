// color-scheme: a page that asks for the dark scheme gets the UA's dark colours — white text, a
// dark canvas, dark fields and buttons — and `normal` keeps the light ones.
//   npm test

import { spawnSync } from "node:child_process";
import { decodePng } from "./png.ts";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = (scheme: string): string => `<!doctype html>
<html><head><meta name="native-window" content="width=200, height=120"><style>
html { color-scheme: ${scheme}; }
body { margin: 0; font: 16px monospace; }
#b { position: absolute; left: 20px; top: 40px; width: 60px; height: 24px; }
#i { position: absolute; left: 120px; top: 40px; width: 60px; }
</style></head><body>
<button id="b"></button><input id="i" value="x">
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const css = (sel: string) => getComputedStyle(document.querySelector(sel)!);
console.log("color=" + css("html").color);
console.log("bg=" + css("#b").backgroundColor);
console.log("inbg=" + css("#i").backgroundColor);
`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

interface Shot { img: ReturnType<typeof decodePng>; out: string }
/** Builds the page with one color-scheme value and renders it with its script's log. */
function run(scheme: string): Shot {
  const dir = mkdtempSync(join(tmpdir(), "native-color-scheme-"));
  writeFileSync(join(dir, "index.html"), PAGE(scheme));
  writeFileSync(join(dir, "app.ts"), SCRIPT);
  const exe = join(dir, "app");
  const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
  if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
  const png = join(dir, "out.png");
  const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png } });
  if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
  return { img: decodePng(png), out: `${r.stdout}${r.stderr}` };
}

/** The colour at a point in CSS pixels. */
const at = (img: ReturnType<typeof decodePng>, x: number, y: number): number[] => {
  const o = (Math.round(y * 2) * img.w + Math.round(x * 2)) * 4;
  return [img.rgba[o], img.rgba[o + 1], img.rgba[o + 2]];
};
const near = (got: number[], want: number[], tol = 3): boolean =>
  Math.abs(got[0] - want[0]) <= tol && Math.abs(got[1] - want[1]) <= tol && Math.abs(got[2] - want[2]) <= tol;

const dark = run("dark");
check("the dark scheme paints a dark canvas", near(at(dark.img, 5, 5), [18, 18, 18], 6),
  `got ${at(dark.img, 5, 5)}`);
check("its text is white", dark.out.includes("color=rgb(255, 255, 255)"), dark.out.trim());
check("its buttons are the dark ButtonFace", near(at(dark.img, 50, 52), [107, 107, 107], 6),
  `got ${at(dark.img, 50, 52)}`);
check("the button's computed background is the dark one", dark.out.includes("bg=rgb(107, 107, 107)"), dark.out.trim());
check("its fields are the dark Field", dark.out.includes("inbg=rgb(59, 59, 59)"), dark.out.trim());

const light = run("normal");
check("normal keeps the white canvas", near(at(light.img, 5, 5), [255, 255, 255], 3),
  `got ${at(light.img, 5, 5)}`);
check("and black text", light.out.includes("color=rgb(0, 0, 0)"), light.out.trim());
check("and the light button", near(at(light.img, 50, 52), [239, 239, 239], 6) &&
  light.out.includes("bg=rgb(239, 239, 239)"), `got ${at(light.img, 50, 52)}`);

const explicit = run("light");
check("an explicit light scheme stays light", near(at(explicit.img, 5, 5), [255, 255, 255], 3) &&
  explicit.out.includes("color=rgb(0, 0, 0)"), explicit.out.trim());

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
