// Gradients interpolate their stops in the colour space their prelude names, as CSS Images 4
// says and Tailwind v4 writes (`linear-gradient(to right in oklab, …)`). A space this build
// converts interpolates there, a polar space follows its hue method, and an unknown method
// leaves the gradient invalid. `@supports` sees the syntax as supported, so Tailwind's oklab
// branch is taken.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";
import type { Image } from "./png.ts";

// #a: oklab red to blue. #b: the same stops in sRGB, whose half mix is purple. #c: explicit
// srgb. #d: oklch takes the shorter hue arc. #e: oklch longer hue takes the other one. #f: a
// radial with the method after its shape. #g: a conic with the method before its stops. #s: a
// rule guarded by @supports for the oklab syntax, which a Tailwind gradient utility relies on.
// #bad: an unknown colour space leaves the gradient invalid. #v: the same gradient written
// through var(), as Tailwind's utility composes it.
const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=320, height=520"><style>
body { margin: 0; background: #ffffff; }
div { position: absolute; left: 0; width: 100px; height: 20px; }
#a { top: 0; background-image: linear-gradient(to right in oklab, #ff0000, #0000ff); }
#b { top: 30px; background-image: linear-gradient(to right, #ff0000, #0000ff); }
#c { top: 60px; background-image: linear-gradient(to right in srgb, #ff0000, #0000ff); }
#d { top: 90px; background-image: linear-gradient(to right in oklch, #ff0000, #0000ff); }
#e { top: 120px; background-image: linear-gradient(to right in oklch longer hue, #ff0000, #0000ff); }
#f { top: 150px; height: 100px; background-image: radial-gradient(circle in oklab, #ff0000, #0000ff); }
#g { top: 270px; height: 100px; background-image: conic-gradient(in oklab, #ff0000, #0000ff); }
#s { top: 400px; width: 10px; height: 10px; }
#bad { top: 430px; background-image: linear-gradient(in nonsense, #ff0000, #0000ff); }
/* the way Tailwind writes a gradient: its pieces in custom properties, substituted at use */
#v { top: 460px; --pos: to right in oklab; --from: #ff0000; --to: #0000ff;
     --stops: var(--pos), var(--from) 0%, var(--to) 100%;
     background-image: linear-gradient(var(--stops)); }
@supports (background-image: linear-gradient(in lab, red, red)) {
  #s { background-color: #00ff00; }
}
</style></head><body>
<div id="a"></div><div id="b"></div><div id="c"></div><div id="d"></div><div id="e"></div>
<div id="f"></div><div id="g"></div><div id="s"></div><div id="bad"></div><div id="v"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
console.log("OUT " + getComputedStyle(document.getElementById("a")!).getPropertyValue("background-image"));
console.log("VAR " + getComputedStyle(document.getElementById("v")!).getPropertyValue("background-image"));
`;

function near(img: Image, cx: number, cy: number, want: number[], tol = 4): string | null {
  const o = (cy * 2 * img.w + cx * 2) * 4;
  const got = [img.rgba[o], img.rgba[o + 1], img.rgba[o + 2]];
  const ok = got.every((g, i) => Math.abs(g - want[i]) <= tol);
  return ok ? null : `got ${got.join(",")}, want about ${want.join(",")}`;
}

const dir = mkdtempSync(join(tmpdir(), "native-gradient-interpolation-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const png = join(dir, "out.png");
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const img = decodePng(png);

let failed = 0;
function check(name: string, bad: string | null): void {
  if (bad !== null) failed++;
  console.log(`${bad === null ? "ok  " : "FAIL"} ${name}${bad === null ? "" : ` — ${bad}`}`);
}

const lines = (r.stdout + r.stderr).split("\n");
const out = lines.find((line) => line.startsWith("OUT ")) ?? "";
const variant = lines.find((line) => line.startsWith("VAR ")) ?? "";
check("the computed image keeps the interpolation method",
  out.includes("linear-gradient(to right in oklab,") ? null : out);
check("a gradient written through var() computes its text",
  variant.includes("linear-gradient(to right in oklab,") ? null : variant);
// oklab half of red and blue is a pale violet, where sRGB's is purple.
check("oklab interpolates red to blue", near(img, 50, 10, [140, 83, 162]));
check("sRGB stays the default", near(img, 50, 40, [128, 0, 128]));
check("in srgb names sRGB's mix", near(img, 50, 70, [128, 0, 128]));
check("oklch follows the shorter hue arc", near(img, 50, 100, [186, 0, 194]));
check("oklch longer hue takes the longer arc", near(img, 50, 130, [0, 147, 0]));
check("a radial gradient takes the method", near(img, 50, 200, [255, 0, 0]));
check("a conic gradient takes the method", near(img, 50, 275, [255, 0, 0], 8));
check("a gradient still starts at its first stop", near(img, 0, 10, [255, 0, 0]));
check("a gradient still ends at its second stop", near(img, 99, 10, [0, 0, 255], 8));
// Tailwind's gradient utilities put `in oklab` behind this @supports query.
check("@supports accepts a gradient with a colour space", near(img, 5, 405, [0, 255, 0], 0));
// A colour space CSS doesn't name leaves the gradient invalid, as a browser drops it.
check("an unknown colour space leaves no gradient", near(img, 5, 435, [255, 255, 255], 0));
check("a gradient written through var() paints in its space", near(img, 50, 470, [140, 83, 162]));

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
