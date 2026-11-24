// Media queries: the range syntax, the keyword features, boolean forms, media types, and the
// system settings (appearance, reduce motion) reaching both matchMedia and @media rules.
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
<html><head><meta charset="utf-8"><meta name="native-window" content="width=800, height=600"><style>
body { margin: 0; background: #ffffff; font: 10px/1 sans-serif; }
#dark { position: absolute; left: 0; top: 0; width: 40px; height: 40px; background: #ffffff; }
@media (prefers-color-scheme: dark) { #dark { background: #0000ff; } }
#motion { position: absolute; left: 50px; top: 0; width: 40px; height: 40px; background: #ffffff; }
@media (prefers-reduced-motion: reduce) { #motion { background: #ff0000; } }
#range { position: absolute; left: 100px; top: 0; width: 40px; height: 40px; background: #ffffff; }
@media (width >= 400px) { #range { background: #00ff00; } }
#typed { position: absolute; left: 150px; top: 0; width: 40px; height: 40px; background: #ffffff; }
@media print { #typed { background: #ff00ff; } }
@page { size: A4; margin: 1cm; }
@page :first { margin-top: 2cm; }
#scr { position: absolute; left: 200px; top: 0; width: 40px; height: 40px; background: #ffffff; }
@media screen { #scr { background: #0088ff; } }
</style></head><body>
<div id="dark"></div><div id="motion"></div><div id="range"></div><div id="typed"></div><div id="scr"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
window.addEventListener("load", () => {
  const qs = [
    "(min-width: 600px)", "(max-width: 400px)", "(width >= 600px)", "(400px <= width < 900px)",
    "(400px < width < 800px)", "(orientation: landscape)", "(hover: hover)", "(pointer: fine)",
    "(prefers-color-scheme: dark)", "(prefers-reduced-motion: reduce)", "(min-resolution: 1dppx)",
    "(color)", "(grid)", "not print", "print", "screen and (min-width: 1px)", "(aspect-ratio: 4/3)",
    "(min-width: 900px) or (max-width: 900px)",
    "(min-aspect-ratio: calc(400/600))", "(max-aspect-ratio: 0/0)",
    "(color-gamut: dci-p3)", "not (color-gamut: dci-p3)", "not and", "print", "screen",
  ];
  for (const q of qs) console.log("q|" + q + "=" + matchMedia(q).matches);
});
`;

const dir = mkdtempSync(join(tmpdir(), "native-media-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
check("the media features compile without a warning", !/media feature/.test(b.stdout + b.stderr), b.stderr);

const png = join(dir, "out.png");
const r = spawnSync(exe, [], {
  encoding: "utf8",
  env: { ...process.env, NATIVE_SNAPSHOT: png, NATIVE_STEPS: "frame", NATIVE_COLOR_SCHEME: "dark", NATIVE_REDUCED_MOTION: "1" },
});
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const img = decodePng(png);
const out = `${r.stdout}${r.stderr}`;
const colorAt = (x: number, y: number): string => {
  const o = (Math.round(y * 2) * img.w + Math.round(x * 2)) * 4;
  return `${img.rgba[o]},${img.rgba[o + 1]},${img.rgba[o + 2]}`;
};
const WHITE = "255,255,255";

const q = (s: string): string => {
  const line = out.split("\n").find((l) => l.startsWith(`q|${s}=`));
  return line === undefined ? "missing" : line.slice(line.lastIndexOf("=") + 1).trim();
};
check("min-width matches", q("(min-width: 600px)") === "true", q("(min-width: 600px)"));
check("a width range matches", q("(width >= 600px)") === "true", q("(width >= 600px)"));
check("a two-sided range matches", q("(400px <= width < 900px)") === "true", q("(400px <= width < 900px)"));
check("a two-sided range outside its bound does not", q("(400px < width < 800px)") === "false", q("(400px < width < 800px)"));
check("keyword features match", q("(orientation: landscape)") === "true" && q("(hover: hover)") === "true", q("(orientation: landscape)"));
check("the appearance reaches matchMedia", q("(prefers-color-scheme: dark)") === "true", q("(prefers-color-scheme: dark)"));
check("the reduce-motion setting reaches matchMedia", q("(prefers-reduced-motion: reduce)") === "true", q("(prefers-reduced-motion: reduce)"));
check("a resolution range matches", q("(min-resolution: 1dppx)") === "true", q("(min-resolution: 1dppx)"));
check("boolean features tell a colour screen from a grid one", q("(color)") === "true" && q("(grid)") === "false",
  `${q("(color)")} / ${q("(grid)")}`);
check("media types and not", q("not print") === "true" && q("print") === "false" && q("screen and (min-width: 1px)") === "true",
  `${q("not print")} / ${q("print")}`);
check("a ratio query matches", q("(aspect-ratio: 4/3)") === "true", q("(aspect-ratio: 4/3)"));
check("or joins two conditions", q("(min-width: 900px) or (max-width: 900px)") === "true",
  q("(min-width: 900px) or (max-width: 900px)"));
check("a calc() ratio works out", q("(min-aspect-ratio: calc(400/600))") === "true", q("(min-aspect-ratio: calc(400/600))"));
check("a zero ratio is infinite", q("(max-aspect-ratio: 0/0)") === "true", q("(max-aspect-ratio: 0/0)"));
check("an unknown feature value makes the query invalid, negated or not",
  q("(color-gamut: dci-p3)") === "false" && q("not (color-gamut: dci-p3)") === "false",
  `${q("(color-gamut: dci-p3)")} / ${q("not (color-gamut: dci-p3)")}`);
check("a reserved word is an invalid media type", q("not and") === "false", q("not and"));

check("@media prefers-color-scheme paints", colorAt(20, 20) === "0,0,255", `got ${colorAt(20, 20)}`);
check("@media prefers-reduced-motion paints", colorAt(70, 20) === "255,0,0", `got ${colorAt(70, 20)}`);
check("@media with a width range paints", colorAt(120, 20) === "0,255,0", `got ${colorAt(120, 20)}`);
check("@media print does not apply on screen", colorAt(170, 20) === WHITE, `got ${colorAt(170, 20)}`);
check("the screen media type matches", q("screen") === "true" && q("print") === "false", `${q("screen")} / ${q("print")}`);

// The same page laid out for print: the print media type and its rules apply.
const printPng = join(dir, "print.png");
const pr = spawnSync(exe, [], {
  encoding: "utf8",
  env: { ...process.env, NATIVE_SNAPSHOT: printPng, NATIVE_STEPS: "frame", NATIVE_MEDIA: "print" },
});
if (pr.status !== 0) throw new Error(`print render failed\n${pr.stderr}`);
const pimg = decodePng(printPng);
const pout = `${pr.stdout}${pr.stderr}`;
const pq = (s: string): string => {
  const line = pout.split("\n").find((l) => l.startsWith(`q|${s}=`));
  return line === undefined ? "missing" : line.slice(line.lastIndexOf("=") + 1).trim();
};
const pcolorAt = (x: number, y: number): string => {
  const o = (Math.round(y * 2) * pimg.w + Math.round(x * 2)) * 4;
  return `${pimg.rgba[o]},${pimg.rgba[o + 1]},${pimg.rgba[o + 2]}`;
};
check("NATIVE_MEDIA=print selects print media", pq("print") === "true" && pq("screen") === "false",
  `${pq("print")} / ${pq("screen")}`);
check("its @media print rules apply", pcolorAt(170, 20) === "255,0,255", `got ${pcolorAt(170, 20)}`);
check("and the screen-only rules do not", pcolorAt(220, 20) === WHITE, `got ${pcolorAt(220, 20)}`);
check("the screen-only rule paints on screen", colorAt(220, 20) === "0,136,255", `got ${colorAt(220, 20)}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
