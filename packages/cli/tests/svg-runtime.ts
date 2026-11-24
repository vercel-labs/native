// SVG a script builds: an <svg> made with document.createElementNS() lays out and paints from the
// subtree it has at the time, its presentation attributes (fill, stroke, stroke-width) and a
// style="" attribute reach the paint, its viewBox maps user units into the box, and a change to
// the subtree or its attributes redraws the picture.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=240, height=160"><style>
body { margin: 0; background: #ffffff; }
svg { position: absolute; }
</style></head><body>
<script type="module">
const ns = "http://www.w3.org/2000/svg";
function svgAt(left, top, width, height, viewBox) {
  const el = document.createElementNS(ns, "svg");
  el.setAttribute("width", String(width));
  el.setAttribute("height", String(height));
  el.setAttribute("viewBox", viewBox);
  el.style.position = "absolute";
  el.style.left = left + "px";
  el.style.top = top + "px";
  document.body.appendChild(el);
  return el;
}
function rect(svg, x, y, w, h, fill) {
  const r = document.createElementNS(ns, "rect");
  r.setAttribute("x", String(x));
  r.setAttribute("y", String(y));
  r.setAttribute("width", String(w));
  r.setAttribute("height", String(h));
  if (fill !== null) r.setAttribute("fill", fill);
  svg.appendChild(r);
  return r;
}

// A viewBox much larger than the box: the picture has to be scaled into it.
const scaled = svgAt(0, 0, 40, 40, "0 0 100 100");
rect(scaled, 0, 0, 100, 100, "#ff0000");

// A stroke, from the presentation attributes, in a viewBox of its own size.
const stroked = svgAt(50, 0, 40, 20, "0 0 40 20");
const path = document.createElementNS(ns, "path");
path.setAttribute("d", "M2 10h36");
path.setAttribute("stroke", "#0000ff");
path.setAttribute("stroke-width", "4");
stroked.appendChild(path);

// A subtree that grows after it is first painted.
const mutating = svgAt(100, 0, 60, 40, "0 0 60 40");
const grow = rect(mutating, 0, 0, 10, 10, "#00ff00");

// A paint from a style="" attribute.
const styled = svgAt(0, 50, 40, 40, "0 0 40 40");
const styledRect = rect(styled, 0, 0, 40, 40, null);
styledRect.setAttribute("style", "fill: #3366cc");

// A viewBox a script changes: with no aspect-ratio fitting, the same rect first draws into the top
// half of the box, then into all of it.
const reboxed = svgAt(100, 50, 40, 40, "0 0 80 80");
reboxed.setAttribute("preserveAspectRatio", "none");
rect(reboxed, 0, 0, 80, 40, "#ff8800");

requestAnimationFrame(() => {
  console.log("stroke " + getComputedStyle(path).stroke);
  grow.setAttribute("fill", "#ff00ff");
  rect(mutating, 20, 0, 10, 10, "#00aaaa");
  console.log("fill " + getComputedStyle(grow).fill);
  reboxed.setAttribute("viewBox", "0 0 80 40");
});
</script>
</body></html>`;

const EXPECTED_LOG = [
  // The created path takes its stroke from the attribute, through the cascade.
  "stroke rgb(0, 0, 255)",
  "fill rgb(255, 0, 255)",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}
function near(px: number[], want: number[], tol = 6): boolean {
  return px.every((p, i) => Math.abs(p - want[i]) <= tol);
}

const dir = mkdtempSync(join(tmpdir(), "native-svg-runtime-"));
writeFileSync(join(dir, "index.html"), PAGE);
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

const RED = [255, 0, 0], BLUE = [0, 0, 255], WHITE = [255, 255, 255];
const MAGENTA = [255, 0, 255], TEAL = [0, 170, 170], STEEL = [51, 102, 204], ORANGE = [255, 136, 0];

check("a created rect fills its box", near(at(20, 20), RED), `got ${at(20, 20).join(",")}`);
check("its viewBox scales user units into the box", near(at(35, 35), RED), `got ${at(35, 35).join(",")}`);
check("the box's outside stays empty", near(at(45, 20), WHITE), `got ${at(45, 20).join(",")}`);

check("a created path takes its stroke from the attribute", near(at(70, 10), BLUE), `got ${at(70, 10).join(",")}`);
check("its stroke-width holds", near(at(70, 2), WHITE) && near(at(70, 18), WHITE),
  `got ${at(70, 2).join(",")} / ${at(70, 18).join(",")}`);

check("a style attribute paints", near(at(20, 70), STEEL), `got ${at(20, 70).join(",")}`);

check("a changed attribute repaints the shape", near(at(105, 5), MAGENTA), `got ${at(105, 5).join(",")}`);
check("a child appended later is painted", near(at(125, 5), TEAL), `got ${at(125, 5).join(",")}`);
check("the new child doesn't paint where it isn't", near(at(105, 20), WHITE), `got ${at(105, 20).join(",")}`);

check("a changed viewBox remaps the picture", near(at(120, 85), ORANGE), `got ${at(120, 85).join(",")}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
