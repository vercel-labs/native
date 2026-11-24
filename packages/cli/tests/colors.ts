// CSS Color 4 syntax: oklab()/oklch()/lab()/lch(), the `/ alpha` form and color-mix(). The
// expected sRGB values are the ones Chrome computes for the same colors (read back from a
// canvas), so they check the conversions against a browser, not against themselves.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { parseColor } from "../shared/css/colors.ts";
import { decodePng } from "./png.ts";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const rgba = (n: number | null): string =>
  n === null ? "unparsed" : [n >>> 24, (n >>> 16) & 255, (n >>> 8) & 255, n & 255].join(",");

const CASES: [string, string][] = [
  ["oklch(58.5% 0.233 277.117)", "97,95,255,255"],
  ["oklch(98.4% 0.003 247.858)", "248,250,252,255"],
  ["oklch(20.8% 0.042 265.755)", "15,23,43,255"],
  ["oklab(0.585 0.15 -0.18)", "165,64,224,255"],
  ["lab(50% 40 -30)", "165,91,171,255"],
  ["lch(50% 40 300)", "129,108,178,255"],
  ["oklch(58.5% 0.233 277.117 / 50%)", "97,95,255,128"],
  ["rgb(255 0 0 / 50%)", "255,0,0,128"],
  ["hsl(0 100% 50% / 50%)", "255,0,0,128"],
  ["hwb(120 0% 49.8039%)", "0,128,0,255"],
  ["hwb(120 20% 30%)", "51,179,51,255"],
  ["hwb(0 100% 100%)", "128,128,128,255"],
  ["hwb(120 70% 60%)", "137,137,137,255"],
  ["rgba(0, 0, 255, 0.25)", "0,0,255,64"],
  ["#abc", "170,187,204,255"],
  ["rebeccapurple", "102,51,153,255"],
  ["LightGoldenrodYellow", "250,250,210,255"],
  ["lightgrey", "211,211,211,255"],
  ["cyan", "0,255,255,255"],
  ["color-mix(in srgb, red, blue)", "128,0,128,255"],
  ["color-mix(in oklch, red, blue)", "186,0,194,255"],
  ["color-mix(in oklch, red 25%, blue)", "122,0,244,255"],
  ["color-mix(in oklab, oklch(20.8% 0.042 265.755) 5%, oklch(100% 0 0))", "241,242,243,255"],
  ["color-mix(in oklab, oklch(20.8% 0.042 265.755) 5%, transparent)", "15,23,43,13"],
  // Relative colors: the origin's own channels, in the function's space (identity or permuted).
  ["oklab(from #ff0000 l a b)", "255,0,0,255"],
  ["lab(from rgb(0, 128, 0) l a b)", "0,128,0,255"],
  ["lch(from rgb(0, 128, 0) l c h)", "0,128,0,255"],
  ["oklch(from rgb(0, 128, 0) l c h)", "0,128,0,255"],
  ["rgb(from rgb(128, 0, 0) g r b)", "0,128,0,255"],
  ["hsl(from rgb(0, 128, 0) 120 s l)", "0,128,0,255"],
  ["hwb(from rgb(0, 128, 0) h w b)", "0,128,0,255"],
  ["color(from rgb(0, 128, 0) a98-rgb r g b)", "0,128,0,255"],
  ["color(from rgb(0, 128, 0) display-p3 r g b)", "0,128,0,255"],
  ["color(from rgb(0, 128, 0) rec2020 r g b)", "0,128,0,255"],
  ["color(from rgb(0, 128, 0) prophoto-rgb r g b)", "0,128,0,255"],
  ["color(from rgb(0, 128, 0) xyz-d50 x y z)", "0,128,0,255"],
  ["color(display-p3-linear 0.0383 0.2087 0.0156)", "0,128,0,255"],
  // contrast-color() picks black or white for the color it is given.
  ["contrast-color(white)", "0,0,0,255"],
  ["contrast-color(darkblue)", "255,255,255,255"],
];
for (const [value, want] of CASES) {
  const got = rgba(parseColor(value));
  check(`${value} -> ${want}`, got === want, `got ${got}`);
}

// The same syntax reaching a declaration: the stylesheet's background and a runtime style.
const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=100, height=100"><style>
body { margin: 0; }
#box { width: 100px; height: 50px; background-color: oklch(58.5% 0.233 277.117); color: lab(50% 40 -30); }
</style></head><body><div id="box">x</div></body></html>`;
const dir = mkdtempSync(join(tmpdir(), "native-colors-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
const log = `${b.stdout}${b.stderr}`;
check("the build doesn't call oklch() unsupported", !/oklch|unsupported color/.test(log), log.split("\n").slice(0, 3).join("\n"));

const png = join(dir, "out.png");
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const img = decodePng(png);
const at = (x: number, y: number): string => {
  const o = (y * img.w + x) * 4;
  return `${img.rgba[o]},${img.rgba[o + 1]},${img.rgba[o + 2]}`;
};
check("a background-color in oklch() paints", at(80, 40) === "97,95,255", `got ${at(80, 40)}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
