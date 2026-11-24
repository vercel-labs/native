// SVG presentation attributes a script changes: setAttribute()/removeAttribute() of a paint or
// font attribute restyles the element, because those attributes are hints in the cascade rather
// than values baked at build time — an author rule and a style="" declaration still beat them —
// and a changed geometry attribute redraws the picture.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=120"><style>
body { margin: 0; background: #ffffff; }
#s { position: absolute; left: 0; top: 0; width: 300px; height: 120px; }
/* A CSS rule of any specificity beats a presentation attribute, before and after a change. */
.ruled { fill: #00ff00; }
</style></head><body>
<svg id="s" viewBox="0 0 300 120">
  <circle id="arc" cx="50" cy="50" r="20" fill="#ff0000" stroke="#0000ff" stroke-width="4"/>
  <rect id="ruled" class="ruled" x="120" y="30" width="40" height="40" fill="#ff0000"/>
  <rect id="styled" x="200" y="30" width="40" height="40" fill="#ff0000" style="fill: #0000ff"/>
</svg>
<!-- XHTML writes the root with a namespace prefix; its width and height still size its box. -->
<svg:svg id="prefixed" xmlns:svg="http://www.w3.org/2000/svg" width="80" height="40"
  style="position: absolute; left: 0; top: 80px"></svg:svg>
<script type="module">
const arc = document.querySelector("#arc");
const ruled = document.querySelector("#ruled");
const styled = document.querySelector("#styled");
const prop = (el, name) => getComputedStyle(el, "").getPropertyValue(name);
const log = (name, value) => console.log(name + " " + value);
requestAnimationFrame(() => {
  const box = document.querySelector("#prefixed").getBoundingClientRect();
  log("prefixed", box.width + " " + box.height);
  log("initial", prop(arc, "fill") + " " + prop(arc, "stroke-width") + " " + prop(ruled, "fill") + " " + prop(styled, "fill"));
  arc.setAttribute("fill", "#0000ff");
  arc.setAttribute("stroke-dasharray", "20 10");
  arc.setAttribute("stroke-width", "8");
  arc.setAttribute("cx", "250");
  arc.setAttribute("cy", "100");
  arc.setAttribute("r", "10");
  ruled.setAttribute("fill", "#0000ff");
  styled.setAttribute("fill", "#00ff00");
  requestAnimationFrame(() => {
    log("changed", prop(arc, "fill") + " " + prop(arc, "stroke-width") + " " + prop(arc, "stroke-dasharray") +
      " " + prop(ruled, "fill") + " " + prop(styled, "fill"));
    arc.removeAttribute("fill");
    arc.removeAttribute("stroke-width");
    requestAnimationFrame(() => {
      log("removed", prop(arc, "fill") + " " + prop(arc, "stroke-width"));
    });
  });
});
</script>
</body></html>`;

const EXPECTED_LOG = [
  // A namespace-prefixed root takes its box from its width and height attributes.
  "prefixed 80 40",
  // The attributes paint to begin with, the rule beats #ruled's own fill, and style="" wins.
  "initial rgb(255, 0, 0) 4px rgb(0, 255, 0) rgb(0, 0, 255)",
  // Every changed attribute reaches the cascade; the rule still beats #ruled's attribute.
  "changed rgb(0, 0, 255) 8px 20px, 10px rgb(0, 255, 0) rgb(0, 0, 255)",
  // A removed attribute falls back to what the cascade would give without it (fill inherits black).
  "removed rgb(0, 0, 0) 1px",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}
function near(px: number[], want: number[], tol = 6): boolean {
  return px.every((p, i) => Math.abs(p - want[i]) <= tol);
}

const dir = mkdtempSync(join(tmpdir(), "native-svg-attributes-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const png = join(dir, "out.png");
const r = spawnSync(exe, [], {
  encoding: "utf8",
  env: { ...process.env, NATIVE_SNAPSHOT: png, NATIVE_STEPS: "frame | frame | frame | frame" },
});
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);

const got = r.stdout.split("\n").slice(0, -1);
check(`log lines (${EXPECTED_LOG.length})`, got.length === EXPECTED_LOG.length,
  `got ${got.length}: ${JSON.stringify(got.slice(EXPECTED_LOG.length))}`);
const n = Math.min(got.length, EXPECTED_LOG.length);
for (let i = 0; i < n; i++) check(EXPECTED_LOG[i], got[i] === EXPECTED_LOG[i], `got ${JSON.stringify(got[i])}`);

const img = decodePng(png);
/** The pixel at CSS coordinates (cx, cy), as [r, g, b]. */
function at(cx: number, cy: number): number[] {
  const o = (Math.floor(cy * 2) * img.w + Math.floor(cx * 2)) * 4;
  return [img.rgba[o], img.rgba[o + 1], img.rgba[o + 2]];
}

const GREEN = [0, 255, 0], BLUE = [0, 0, 255], WHITE = [255, 255, 255];

// The circle was red at (50, 50) with r=20; it is now drawn at (250, 100) with r=10, and the fill
// was then removed, so the inherited black draws it.
check("the moved circle draws where its new cx and cy say", near(at(250, 100), [0, 0, 0]), `got ${at(250, 100).join(",")}`);
check("the smaller radius leaves the old ring empty", near(at(250, 114), WHITE), `got ${at(250, 114).join(",")}`);
check("the old position is empty", near(at(50, 50), WHITE), `got ${at(50, 50).join(",")}`);
check("a CSS rule still beats a changed attribute", near(at(140, 50), GREEN), `got ${at(140, 50).join(",")}`);
check("a style attribute still beats a changed attribute", near(at(220, 50), BLUE), `got ${at(220, 50).join(",")}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
