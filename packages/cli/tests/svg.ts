// Inline SVG: an <svg> in the document is a replaced box whose picture is drawn from its own
// subtree. The shapes, the path grammar, the paint properties (fill, stroke, their opacities and
// the fill rule), the presentation attributes, the viewBox and preserveAspectRatio, group
// transforms and currentColor are each checked by sampling the snapshot of a page that draws
// them at known places.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=400"><style>
body { margin: 0; background: #ffffff; }
#shapes { position: absolute; left: 0; top: 0; width: 200px; height: 60px; }
#paths { position: absolute; left: 220px; top: 0; width: 160px; height: 60px; }
/* CSS reaches the shapes: a rule beats a presentation attribute, and color feeds currentColor. */
#css { position: absolute; left: 0; top: 80px; width: 120px; height: 60px; color: #3366cc; }
#css .cssfill { fill: #00ff00; }
.ruled { fill: #880088; }
#meet { position: absolute; left: 130px; top: 80px; width: 100px; height: 50px; }
#slice { position: absolute; left: 240px; top: 80px; width: 100px; height: 50px; }
#stretch { position: absolute; left: 0; top: 140px; width: 100px; height: 50px; }
#trans { position: absolute; left: 110px; top: 140px; width: 160px; height: 60px; }
#flow { position: absolute; left: 0; top: 210px; }
#grad { position: absolute; left: 60px; top: 210px; width: 160px; height: 40px; }
#use { position: absolute; left: 0; top: 260px; width: 240px; height: 60px; }
#dash { position: absolute; left: 230px; top: 210px; width: 160px; height: 60px; }
#clip { position: absolute; left: 250px; top: 270px; width: 140px; height: 60px; }
#text { position: absolute; left: 250px; top: 330px; width: 140px; height: 60px; }
#pattern { position: absolute; left: 0; top: 330px; width: 120px; height: 60px; }
</style></head><body>
<svg id="shapes" viewBox="0 0 200 60">
  <rect x="0" y="0" width="40" height="30" fill="#ff0000"/>
  <circle cx="70" cy="15" r="15" fill="#00ff00"/>
  <ellipse cx="110" cy="15" rx="20" ry="10" fill="#0000ff"/>
  <line x1="0" y1="48" x2="40" y2="48" stroke="#ff00ff" stroke-width="6"/>
  <polygon points="80,55 90,35 100,55" fill="#00aaaa"/>
  <rect x="120" y="35" width="40" height="20" rx="10" fill="#000000"/>
</svg>
<svg id="paths" viewBox="0 0 160 60">
  <path d="M 5 5 H 45 V 25 H 5 Z" fill="#ff0000"/>
  <path d="M 55 5 h 20 v 20 h -20 z M 65 15 h 20 v 20 h -20 z" fill-rule="evenodd"/>
  <path d="M 120 40 A 10 10 0 0 1 140 40 L 140 55 L 120 55 Z" fill="#0000ff"/>
  <path d="m 5 35 l 20 0 l 0 15 l -20 0 z" fill="#ff8800"/>
  <path d="M 45 45 Q 55 30 65 45 T 85 45 L 85 55 L 45 55 Z" fill="#880088"/>
</svg>
<svg id="css">
  <rect x="5" y="5" width="30" height="30" fill="currentColor"/>
  <rect x="45" y="5" width="30" height="30" fill="#ff0000" class="cssfill"/>
  <rect x="85" y="5" width="30" height="30" style="fill: #ff8800"/>
  <rect x="5" y="45" width="50" height="10" fill="#00ff00" fill-opacity="0.5"/>
  <line x1="65" y1="50" x2="115" y2="50" stroke="#0000ff" stroke-opacity="0.5" stroke-width="6"/>
  <rect x="0" y="35" width="50%" height="5" fill="#555555"/>
</svg>
<svg id="meet" viewBox="0 0 100 100">
  <rect x="0" y="0" width="100" height="100" fill="#ff0000"/>
</svg>
<svg id="slice" viewBox="0 0 100 100" preserveAspectRatio="xMinYMin slice">
  <rect x="0" y="0" width="100" height="20" fill="#0000ff"/>
  <rect x="0" y="30" width="100" height="20" fill="#00ff00"/>
  <rect x="0" y="60" width="100" height="20" fill="#ff0000"/>
</svg>
<svg id="stretch" viewBox="0 0 100 100" preserveAspectRatio="none">
  <rect x="0" y="0" width="50" height="50" fill="#ff00ff"/>
  <rect x="50" y="50" width="50" height="50" fill="#00ffff"/>
</svg>
<svg id="trans" viewBox="0 0 160 60">
  <g transform="translate(20 10)"><rect width="20" height="20" fill="#ff0000"/></g>
  <g transform="translate(80 30) rotate(45)"><rect x="-10" y="-10" width="20" height="20" fill="#0000ff"/></g>
  <g transform="scale(2 1) translate(10 0)"><rect width="10" height="10" fill="#00ff00"/></g>
  <path d="M 110 10 L 140 10" stroke="#000000" stroke-width="10" stroke-linecap="round"/>
</svg>
<div id="flow"><svg width="40" height="20" viewBox="0 0 40 20">
  <rect width="40" height="20" fill="#123456"/>
</svg></div>
<svg id="grad" viewBox="0 0 160 40">
  <defs>
    <!-- The stops are on their own lines on purpose: the whitespace between them is a text node
         in the gradient's subtree, which a lookup of the stops has to step over. -->
    <linearGradient id="lg" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="#ff0000"/>
      <stop offset="1" stop-color="#0000ff"/>
    </linearGradient>
    <radialGradient id="rg"><stop offset="0" stop-color="#00ff00"/><stop offset="1" stop-color="#000000"/></radialGradient>
  </defs>
  <rect x="0" y="0" width="80" height="40" fill="url(#lg)"/>
  <rect x="80" y="0" width="80" height="40" fill="url(#rg)"/>
</svg>
<svg id="use" viewBox="0 0 240 60">
  <defs>
    <!-- None of these declares a paint, so what the <use> that references it says is what it
         draws with; a definition in <defs> is never painted where it is written. -->
    <rect id="plain" width="30" height="20"/>
    <rect id="src" width="30" height="20" fill="currentColor"/>
    <symbol id="icon" viewBox="0 0 10 10"><rect width="10" height="10"/></symbol>
    <g id="grp"><rect width="20" height="20"/></g>
    <!-- A rule of the page's sheet styles this definition; a copy keeps what it declares. -->
    <rect id="ruled" class="ruled" width="30" height="20"/>
  </defs>
  <use href="#plain" x="10" y="10" fill="#0000ff"/>
  <use href="#src" x="50" y="10" color="#00aaaa"/>
  <use href="#icon" x="100" y="10" width="20" height="20" fill="#00ff00"/>
  <use href="#grp" x="140" y="10" fill="#ff8800"/>
  <use xlink:href="#plain" x="180" y="10" fill="#ff0000"/>
  <use href="#ruled" x="205" y="35" fill="#0000ff"/>
  <use id="loop" href="#loop" x="0" y="50"/>
</svg>
<svg id="dash" viewBox="0 0 160 60">
  <!-- A dash pattern from the attribute grammar, where a bare number is a length. -->
  <line x1="10" y1="8" x2="150" y2="8" stroke="#ff0000" stroke-width="6" stroke-dasharray="10 5"/>
  <!-- The offset says how far into the pattern the line starts. -->
  <line x1="10" y1="24" x2="150" y2="24" stroke="#0000ff" stroke-width="6"
        stroke-dasharray="10 5" stroke-dashoffset="5"/>
  <!-- The same from a style="" attribute, with a unit and a single length. -->
  <line x1="10" y1="40" x2="150" y2="40" stroke="#00ff00" stroke-width="6" style="stroke-dasharray: 4px"/>
  <!-- All zero lengths are no gaps at all: the line is solid. -->
  <line x1="10" y1="54" x2="150" y2="54" stroke="#000000" stroke-width="6" stroke-dasharray="0"/>
</svg>
<svg id="clip" viewBox="0 0 140 60">
  <defs>
    <clipPath id="half"><rect width="70" height="60"/></clipPath>
    <clipPath id="unit" clipPathUnits="objectBoundingBox"><rect width="0.5" height="1"/></clipPath>
    <clipPath id="quarter"><rect width="35" height="60"/></clipPath>
  </defs>
  <!-- A clip path of shapes in the element's user space keeps the left half of a wide rect. -->
  <rect width="140" height="20" fill="#ff0000" clip-path="url(#half)"/>
  <!-- The same idea in objectBoundingBox units: the unit box is the rect's own bounds. -->
  <rect x="80" width="60" height="20" fill="#0000ff" clip-path="url(#unit)"/>
  <!-- A group's clip reaches the shapes inside it. -->
  <g clip-path="url(#half)"><rect y="20" width="120" height="20" fill="#00ff00"/></g>
  <!-- A clip on a transformed group moves with the group, as Chrome's does. -->
  <g clip-path="url(#half)" transform="translate(60 40)">
    <rect width="120" height="20" fill="#ff8800"/>
  </g>
  <!-- Nested clips intersect: the group's clip, then the shape's own. -->
  <g clip-path="url(#half)"><rect y="40" width="140" height="20" fill="#000000" clip-path="url(#quarter)"/></g>
</svg>
<svg id="text" viewBox="0 0 140 60">
  <!-- A glyph is filled in the text's paint, starting at the baseline point its x and y give. -->
  <text x="4" y="18" font-size="18" font-family="monospace" fill="#ff0000">HH</text>
  <!-- A tspan takes the fill it declares, from the pen's place in the text on. -->
  <text x="4" y="38" font-size="18" font-family="monospace" fill="#0000ff">H<tspan dx="8" fill="#00ff00">H</tspan></text>
  <!-- text-anchor="end" ends the text at x. -->
  <text x="120" y="56" font-size="18" font-family="monospace" text-anchor="end" fill="#000000">HH</text>
</svg>
<svg id="pattern" viewBox="0 0 120 60">
  <!-- A pattern paint server tiles its own content, clipped to each tile, across the shape. -->
  <defs>
    <pattern id="checkers" patternUnits="userSpaceOnUse" x="0" y="0" width="20" height="20">
      <rect x="0" y="0" width="10" height="10" fill="#ff0000"/>
      <rect x="10" y="10" width="10" height="10" fill="#0000ff"/>
    </pattern>
    <!-- patternTransform moves the tiles, not the content inside them. -->
    <pattern id="shifted" patternUnits="userSpaceOnUse" x="0" y="0" width="20" height="20"
      patternTransform="translate(10 0)">
      <rect x="0" y="0" width="10" height="10" fill="#ff0000"/>
    </pattern>
  </defs>
  <rect x="0" y="0" width="60" height="40" fill="url(#checkers)"/>
  <rect x="60" y="0" width="60" height="40" fill="url(#shifted)"/>
</svg>
</body></html>`;

const dir = mkdtempSync(join(tmpdir(), "native-svg-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const png = join(dir, "out.png");
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const img = decodePng(png);

/** The pixel at CSS coordinates (cx, cy), as [r, g, b]. */
function at(cx: number, cy: number): number[] {
  const o = (Math.floor(cy * 2) * img.w + Math.floor(cx * 2)) * 4;
  return [img.rgba[o], img.rgba[o + 1], img.rgba[o + 2]];
}

function near(cx: number, cy: number, want: number[], tol = 6): string | null {
  const got = at(cx, cy);
  return got.every((g, i) => Math.abs(g - want[i]) <= tol) ? null : `got ${got.join(",")}, want about ${want.join(",")}`;
}

/** A sampler whose coordinates are relative to the svg box placed at (left, top). */
function inBox(left: number, top: number): (x: number, y: number, want: number[], tol?: number) => string | null {
  return (x, y, want, tol = 6) => near(left + x, top + y, want, tol);
}

/**
 * How many device pixels of the box at (left, top) are painted `want` (within tol) inside the CSS
 * rect (x0, y0)–(x1, y1). A glyph is thin and antialiased, so a text check counts its ink instead
 * of asking for one exact pixel.
 */
function ink(left: number, top: number, x0: number, y0: number, x1: number, y1: number,
  want: number[], tol = 40): number {
  let n = 0;
  for (let y = y0; y < y1; y += 0.5) {
    for (let x = x0; x < x1; x += 0.5) {
      const got = at(left + x, top + y);
      if (got.every((g, i) => Math.abs(g - want[i]) <= tol)) n++;
    }
  }
  return n;
}

/** How many device pixels of the same rect are painted something other than the page's white. */
function drawn(left: number, top: number, x0: number, y0: number, x1: number, y1: number): number {
  let n = 0;
  for (let y = y0; y < y1; y += 0.5) {
    for (let x = x0; x < x1; x += 0.5) {
      const got = at(left + x, top + y);
      if (got.some((g) => g < 245)) n++;
    }
  }
  return n;
}

const shapes = inBox(0, 0), paths = inBox(220, 0), css = inBox(0, 80), meet = inBox(130, 80),
  slice = inBox(240, 80), stretch = inBox(0, 140), trans = inBox(110, 140), grad = inBox(60, 210),
  use = inBox(0, 260), dash = inBox(230, 210), clip = inBox(250, 270), pattern = inBox(0, 330);

const RED = [255, 0, 0], GREEN = [0, 255, 0], BLUE = [0, 0, 255], WHITE = [255, 255, 255],
  BLACK = [0, 0, 0], MAGENTA = [255, 0, 255], TEAL = [0, 170, 170], ORANGE = [255, 136, 0],
  PURPLE = [136, 0, 136];

let failed = 0;
function check(name: string, bad: string | null): void {
  if (bad !== null) failed++;
  console.log(`${bad === null ? "ok  " : "FAIL"} ${name}${bad === null ? "" : ` — ${bad}`}`);
}

// The basic shapes, at a 1:1 viewBox, so a user unit is a CSS px.
check("a rect fills its box", shapes(20, 15, RED));
check("a circle fills its middle", shapes(70, 15, GREEN));
check("a circle leaves its outside alone", shapes(52, 15, WHITE));
check("an ellipse fills its middle", shapes(110, 15, BLUE));
check("an ellipse is flatter than a circle", shapes(110, 3, WHITE));
check("a line is stroked at its width", shapes(20, 48, MAGENTA));
check("a line is not stroked outside its width", shapes(20, 41, WHITE));
check("a polygon fills its triangle", shapes(90, 50, TEAL));
check("a rounded rect keeps its corners clear", shapes(121, 36, WHITE));
check("a rounded rect fills its middle", shapes(140, 45, BLACK));

// The path grammar: absolute and relative commands, H/V, the even-odd rule, an arc, and the
// quadratic with its T continuation.
check("a path with H and V fills", paths(25, 15, RED));
check("even-odd leaves the overlap empty", paths(70, 20, WHITE));
check("even-odd fills each subpath", paths(60, 10, BLACK));
check("even-odd fills the second subpath", paths(80, 30, BLACK));
check("an arc bulges over its chord", paths(130, 35, BLUE));
check("an arc leaves the space above it", paths(130, 28, WHITE));
check("relative linetos close their subpath", paths(15, 42, ORANGE));
check("a quadratic curve fills under it", paths(65, 50, PURPLE));
check("a quadratic curve leaves the space above it", paths(50, 33, WHITE));
check("a quadratic curve fills below it", paths(50, 43, PURPLE));

// The paint properties from CSS and the presentation attributes.
check("currentColor follows the CSS color", css(20, 20, [51, 102, 204]));
check("a CSS rule beats a presentation attribute", css(60, 20, GREEN));
check("a style attribute beats everything", css(100, 20, ORANGE));
check("fill-opacity fades a fill toward the page", css(30, 50, [128, 255, 128]));
check("stroke-opacity fades a stroke toward the page", css(90, 50, [128, 128, 255]));
check("a percentage width resolves against the viewport", css(30, 37, [85, 85, 85]));
check("a percentage width stops where it says", css(70, 37, WHITE));

// viewBox and preserveAspectRatio.
check("a taller viewBox is fitted with room at the sides", meet(50, 25, RED));
check("meet leaves the left margin", meet(10, 25, WHITE));
check("meet leaves the right margin", meet(90, 25, WHITE));
check("slice scales to cover and crops", slice(50, 10, BLUE));
check("slice keeps the middle band", slice(50, 35, GREEN));
check("slice crops what falls below the box", slice(50, 45, GREEN));
check("preserveAspectRatio none stretches", stretch(25, 12, MAGENTA));
check("preserveAspectRatio none keeps both halves", stretch(75, 40, [0, 255, 255]));

// Group transforms and the stroke's ends.
check("translate moves a group", trans(30, 20, RED));
check("translate leaves where it came from", trans(15, 20, WHITE));
check("rotate turns about the translate", trans(80, 30, BLUE));
check("rotate keeps the square's reach", trans(80, 42, BLUE));
check("rotate leaves the space beyond it", trans(80, 46, WHITE));
check("scale multiplies the group's own translate", trans(30, 5, GREEN));
check("a round cap reaches past the end", trans(107, 10, BLACK));

// An svg in the flow, sized by its width and height attributes.
check("an inline svg takes its attribute size", near(20, 220, [18, 52, 86]));
check("an inline svg ends where its width says", near(45, 220, WHITE));

// Paint servers: fill="url(#id)" names a gradient, whose stops are read from its subtree.
check("a linear gradient starts at its first stop", grad(2, 20, [249, 0, 6], 10));
check("a linear gradient runs between its stops", grad(40, 20, [127, 0, 128], 10));
check("a linear gradient ends at its last stop", grad(78, 20, [6, 0, 249], 10));
check("a radial gradient fills its centre", grad(120, 20, [0, 253, 0], 10));
check("a radial gradient darkens toward its edge", grad(158, 20, [0, 13, 0], 14));

// <use> and <symbol>: a reference draws a copy of what it names, with the fills, colours and
// sizes the reference itself carries.
check("a use draws what it references", use(25, 20, BLUE));
check("a use places it at its x and y", use(5, 20, WHITE));
check("an xlink:href is a reference too", use(195, 20, RED));
check("a second use of a definition takes its own fill and stops where it says", use(215, 20, WHITE));
check("a use that refers to itself draws nothing", use(10, 55, WHITE));
check("a definition in defs is not drawn where it is written", use(25, 40, WHITE));
check("a use's fill reaches content that declares none", use(65, 20, TEAL));
check("a use sized over a symbol scales the symbol", use(110, 20, GREEN));
check("a symbol ends where the use's width says", use(125, 20, WHITE));
check("a use's fill reaches into a referenced group", use(150, 20, ORANGE));
check("a copy keeps the style the element's own rule gives it", use(220, 45, PURPLE));

// stroke-dasharray and stroke-dashoffset: the pen lifts for the lengths that are off.
check("a dasharray draws its dashes", dash(15, 8, RED));
check("a dasharray leaves its gaps", dash(22, 8, WHITE));
check("the pattern repeats: the second dash", dash(45, 8, RED));
check("the pattern repeats: the second gap", dash(37, 8, WHITE));
check("a dasharray starts at the line's start", dash(12, 8, RED));
check("a dasharray stops at the line's end", dash(152, 8, WHITE));
check("a dash offset moves the pattern", dash(17, 24, WHITE));
check("the pattern resumes past the offset", dash(25, 24, BLUE));
check("a style attribute's dasharray draws dashes", dash(12, 40, GREEN));
check("a one-length pattern alternates", dash(16, 40, WHITE));
check("a single length repeats to fill the pattern", dash(20, 40, GREEN));
check("an all-zero dasharray strokes solid", dash(23, 54, BLACK));

// clip-path: a shape is drawn only where the clip path's own shapes cover it.
check("a clip path keeps what it covers", clip(30, 10, RED));
check("a clip path cuts away what it leaves out", clip(75, 10, WHITE));
check("objectBoundingBox maps the unit box onto the element", clip(95, 10, BLUE));
check("objectBoundingBox halves the element's own width", clip(125, 10, WHITE));
check("a group's clip reaches its children", clip(30, 30, GREEN));
check("a group's clip cuts its children too", clip(100, 30, WHITE));
check("a clip on a transformed group moves with it", clip(90, 50, ORANGE));
check("the moving clip still ends where it says", clip(135, 50, WHITE));
check("a clip leaves the space its group moved off", clip(50, 50, WHITE));
check("nested clips intersect", clip(15, 50, BLACK));
check("the inner clip cuts what it leaves out", clip(45, 50, WHITE));

// text: a glyph fills where its strokes are, in the text's own paint, from the baseline point its
// x and y give. A tspan takes the fill it declares, and text-anchor moves the text to its anchor.
const TX = 250, TY = 330;
check("a text glyph is filled in the text's paint", ink(TX, TY, 4, 6, 18, 18, RED) >= 4 ? null : "no red ink");
check("text ends where its glyphs do", drawn(TX, TY, 40, 6, 120, 20) === 0 ? null : "ink past the text");
check("a text glyph keeps the text's fill on a tspan-less run", ink(TX, TY, 4, 27, 16, 37, BLUE) >= 4 ? null : "no blue ink");
check("a tspan takes the fill it declares", ink(TX, TY, 24, 27, 40, 37, GREEN) >= 4 ? null : "no green ink");
check("a tspan's dx moves the pen on", drawn(TX, TY, 18, 27, 22, 37) === 0 ? null : "ink before the dx");
check("text-anchor end ends the text at x", drawn(TX, TY, 100, 43, 120, 56) > 0 ? null : "no ink at the anchor");
check("text-anchor end moves the text left of its x", drawn(TX, TY, 60, 43, 96, 56) === 0 ? null : "ink right of the end");

// A pattern: the tile's shapes repeat across the shape, each copy clipped to its tile.
check("a pattern repeats its tile", pattern(5, 5, RED));
check("the tile's second shape paints too", pattern(15, 15, BLUE));
check("a pattern repeats across the shape", pattern(25, 5, RED));
check("a pattern leaves the tile's gaps empty", pattern(5, 15, WHITE));
check("the next tile keeps the tile's layout", pattern(35, 15, BLUE));
check("a patternTransform moves the tile", pattern(65, 5, WHITE));
check("the moved tile paints past its first position", pattern(75, 5, RED));
check("the next moved tile repeats a tile later", pattern(95, 5, RED));

if (failed > 0) {
  console.error(`\n${failed} check${failed === 1 ? "" : "s"} failed`);
  process.exit(1);
}
console.log("\nall svg checks passed");
