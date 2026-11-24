// SVG as an image: a .svg referenced by <img src> or a CSS url() is compiled into a draw program
// at build time and rasterized at the size it is drawn at (see compiler/svg-image.ts and
// runtime/svg-image.ts). The checks cover the intrinsic size rules (width and height attributes,
// one of them plus a viewBox ratio, and a viewBox alone, which has a ratio and no size), the
// file's own geometry and paint, object-fit, and background tiles sized by background-size.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

// Four quadrants, so a fit or a tile shows which part of the picture landed where.
const QUAD = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <rect width="50" height="50" fill="#ff0000"/>
  <rect x="50" width="50" height="50" fill="#00ff00"/>
  <rect y="50" width="50" height="50" fill="#0000ff"/>
  <rect x="50" y="50" width="50" height="50" fill="#ffff00"/>
</svg>`;

const FILES: Record<string, string> = {
  // No size attributes: a ratio and no size of its own, so it fills the box it is drawn in.
  "square.svg": `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
    <rect width="100" height="100" fill="#ff0000"/></svg>`,
  // Both sizes given: the intrinsic size is exactly those.
  "wide.svg": `<svg width="80" height="40" viewBox="0 0 8 4">
    <rect width="4" height="4" fill="#0000ff"/><rect x="4" width="4" height="4" fill="#00ff00"/></svg>`,
  // Width alone: the height comes from the viewBox's ratio.
  "ratio.svg": `<svg width="120" viewBox="0 0 60 30">
    <rect width="60" height="30" fill="#00aaaa"/></svg>`,
  "quad.svg": QUAD,
  "dot.svg": `<svg width="20" height="20" viewBox="0 0 20 20">
    <rect width="20" height="20" fill="#ff00ff"/></svg>`,
  // A transform inside the file, and a viewBox that scales user units into the image's size.
  "trans.svg": `<svg width="60" height="60" viewBox="0 0 60 60">
    <rect width="30" height="30" fill="#ff8800" transform="translate(30 30)"/></svg>`,
  // currentColor in a file is the file's own colour (the initial black), not the page's.
  "cc.svg": `<svg width="40" height="40">
    <rect width="40" height="40" fill="currentColor"/></svg>`,
  "op.svg": `<svg width="60" height="20">
    <rect width="60" height="20" fill="#ff0000" fill-opacity="0.5"/></svg>`,
  "st.svg": `<svg width="40" height="40">
    <circle cx="20" cy="20" r="10" fill="none" stroke="#0000ff" stroke-width="6"/></svg>`,
  // A square viewBox stretched into a wide box: the rect covers the left half only.
  "par.svg": `<svg viewBox="0 0 100 100" preserveAspectRatio="none">
    <rect width="50" height="100" fill="#ff00ff"/></svg>`,
  // A ratio with no size of its own: it fills the width it is given, 2 to 1.
  "bar.svg": `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 100">
    <rect width="200" height="100" fill="#ff0000"/></svg>`,
  // A gradient inside the file: a paint server the compiled program paints with.
  "grad.svg": `<svg width="60" height="60" viewBox="0 0 60 60">
    <defs><linearGradient id="gg" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="#ff0000"/><stop offset="1" stop-color="#0000ff"/>
    </linearGradient></defs>
    <rect width="60" height="60" fill="url(#gg)"/></svg>`,
  // A clip path inside the file: the shape is drawn only where the clip's shapes cover it.
  "clip.svg": `<svg width="40" height="20">
    <defs><clipPath id="c"><rect width="20" height="20"/></clipPath></defs>
    <rect width="40" height="20" fill="#ff0000" clip-path="url(#c)"/></svg>`,
  // Nested clips intersect in a file too: the group's clip and the shape's own.
  "clipnest.svg": `<svg width="40" height="20">
    <defs>
      <clipPath id="left"><rect width="20" height="20"/></clipPath>
      <clipPath id="top"><rect width="40" height="10"/></clipPath>
    </defs>
    <g clip-path="url(#left)"><rect width="40" height="20" fill="#ff0000" clip-path="url(#top)"/></g>
  </svg>`,
  // A dashed stroke: the program carries the pattern, so it draws in the image too.
  "dash.svg": `<svg width="60" height="20">
    <line x1="5" y1="10" x2="55" y2="10" stroke="#ff0000" stroke-width="8" stroke-dasharray="8 8"/></svg>`,
  // use and a symbol inside the file: the compiled program resolves the reference too.
  "use.svg": `<svg width="60" height="20" viewBox="0 0 60 20">
    <defs>
      <rect id="u1" width="20" height="20"/>
      <symbol id="u2" viewBox="0 0 10 10"><rect width="10" height="10"/></symbol>
    </defs>
    <use href="#u1" fill="#ff0000"/>
    <use href="#u2" x="30" width="20" height="20" fill="#0000ff"/>
  </svg>`,
  // A percentage root size is no size of its own: the picture is drawn at the box it fills, and
  // the geometry's percentages resolve against that box.
  "pct.svg": `<svg xmlns="http://www.w3.org/2000/svg" width="25%" height="50%">
    <rect width="100%" height="50%" fill="#ff0000"/>
    <rect y="50%" width="100%" height="50%" fill="#0000ff"/></svg>`,
  // The file's own viewport is 10 by 20 user units, and a box twice that size scales each axis:
  // the picture's halves stay halves and its shapes double.
  "px.svg": `<svg xmlns="http://www.w3.org/2000/svg" width="10" height="20">
    <rect width="10" height="10" fill="#00ff00"/>
    <rect y="10" width="10" height="10" fill="#ffff00"/></svg>`,
  // A ratio so extreme that a cover fit is billions of pixels tall: the picture is drawn from a
  // bitmap of the visible part rather than one that size.
  "extreme.svg": `<svg xmlns="http://www.w3.org/2000/svg" height="8px"
      viewBox="0 0 1 2147483647" preserveAspectRatio="none">
    <rect width="100%" height="100%" fill="#00ff00"/></svg>`,
  // A viewBox with a zero height disables rendering (SVG 1.1 §7.7): the picture paints nothing.
  "zero.svg": `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 8 0" preserveAspectRatio="none">
    <rect width="100%" height="100%" fill="#00ff00"/></svg>`,
  // Text in the file lays out in the image's own program: the fill, a tspan's shift and colour,
  // and text-anchor, as the inline painter draws them.
  "text.svg": `<svg width="140" height="60" viewBox="0 0 140 60">
    <text x="4" y="18" font-size="18" font-family="monospace" fill="#ff0000">HH</text>
    <text x="4" y="38" font-size="18" font-family="monospace" fill="#0000ff">H<tspan dx="8" fill="#00ff00">H</tspan></text>
    <text x="120" y="56" font-size="18" font-family="monospace" text-anchor="end" fill="#000000">HH</text>
  </svg>`,
};

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=800"><style>
body { margin: 0; background: #ffffff; }
img, div { position: absolute; }
#n1 { left: 0; top: 0; width: 150px; height: 150px; }
#n2 { left: 160px; top: 0; }
#n3 { left: 160px; top: 50px; }
#fit { left: 0; top: 160px; width: 100px; height: 50px; object-fit: contain; }
#cover { left: 120px; top: 160px; width: 200px; height: 50px; object-fit: cover; }
#bg { left: 0; top: 220px; width: 100px; height: 100px; }
#bp { left: 120px; top: 220px; width: 60px; height: 40px;
      background-image: url(dot.svg); background-repeat: no-repeat; background-position: right bottom; }
#bgc { left: 200px; top: 220px; width: 100px; height: 50px;
       background-image: url(quad.svg); background-size: contain; background-repeat: no-repeat; }
#trans { left: 320px; top: 220px; }
#cc { left: 0; top: 330px; color: #ff0000; }
#op { left: 60px; top: 330px; }
#st { left: 140px; top: 330px; }
#par { left: 200px; top: 330px; width: 100px; height: 20px; }
#wonly { left: 320px; top: 330px; width: 70px; }
#flow { left: 0; top: 400px; width: 100px; height: 100px; background: #00ff00; }
#inflow { position: static; }
#bgs { left: 120px; top: 400px; width: 200px; height: 160px;
       background-image: url(square.svg); background-repeat: no-repeat; }
#gimg { left: 330px; top: 400px; }
#useimg { left: 0; top: 570px; }
#dashimg { left: 80px; top: 570px; }
#clipimg { left: 160px; top: 570px; }
#clipnest { left: 210px; top: 570px; }
#textimg { left: 0; top: 610px; }
#bgpct { left: 0; top: 680px; width: 120px; height: 60px;
         background-image: url(pct.svg); background-repeat: no-repeat; }
#bgpx { left: 140px; top: 680px; width: 100px; height: 40px;
        background-image: url(px.svg); background-size: 20px 40px; background-repeat: no-repeat; }
#bgcover { left: 0; top: 740px; width: 100px; height: 40px;
           background-image: url(extreme.svg); background-size: cover; background-repeat: no-repeat; }
#bgzero { left: 140px; top: 740px; width: 100px; height: 40px;
          background-image: url(zero.svg); background-size: cover; background-repeat: no-repeat; }
</style></head><body>
<img id="n1" src="square.svg">
<img id="n2" src="wide.svg">
<img id="n3" src="ratio.svg">
<img id="fit" src="quad.svg">
<img id="cover" src="quad.svg">
<div id="bg" style="background-image: url(quad.svg); background-size: 50px 50px"></div>
<div id="bp"></div>
<div id="bgc"></div>
<img id="trans" src="trans.svg">
<img id="cc" src="cc.svg">
<img id="op" src="op.svg">
<img id="st" src="st.svg">
<img id="par" src="par.svg">
<img id="wonly" src="wide.svg">
<div id="flow"><img id="inflow" src="bar.svg"></div>
<div id="bgs"></div>
<img id="gimg" src="grad.svg">
<img id="useimg" src="use.svg">
<img id="dashimg" src="dash.svg">
<img id="clipimg" src="clip.svg">
<img id="clipnest" src="clipnest.svg">
<img id="textimg" src="text.svg">
<div id="bgpct"></div>
<div id="bgpx"></div>
<div id="bgcover"></div>
<div id="bgzero"></div>
</body></html>`;

const dir = mkdtempSync(join(tmpdir(), "native-svg-image-"));
for (const [name, body] of Object.entries(FILES)) writeFileSync(join(dir, name), body);
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

/**
 * How many device pixels of the page's CSS rect (x0, y0)–(x1, y1) are painted `want` (within
 * tol). A glyph is thin and antialiased, so a text check counts its ink rather than asking for
 * one exact pixel.
 */
function ink(x0: number, y0: number, x1: number, y1: number, want: number[], tol = 40): number {
  let n = 0;
  for (let y = y0; y < y1; y += 0.5) {
    for (let x = x0; x < x1; x += 0.5) {
      const got = at(x, y);
      if (got.every((g, i) => Math.abs(g - want[i]) <= tol)) n++;
    }
  }
  return n;
}

/** How many device pixels of the same rect are painted something other than the page's white. */
function drawn(x0: number, y0: number, x1: number, y1: number): number {
  let n = 0;
  for (let y = y0; y < y1; y += 0.5) {
    for (let x = x0; x < x1; x += 0.5) {
      if (at(x, y).some((g) => g < 245)) n++;
    }
  }
  return n;
}

const RED = [255, 0, 0], GREEN = [0, 255, 0], BLUE = [0, 0, 255], YELLOW = [255, 255, 0],
  WHITE = [255, 255, 255], PINK = [255, 0, 255],
  TEAL = [0, 170, 170], ORANGE = [255, 136, 0], BLACK = [0, 0, 0];

let failed = 0;
function check(name: string, bad: string | null): void {
  if (bad !== null) failed++;
  console.log(`${bad === null ? "ok  " : "FAIL"} ${name}${bad === null ? "" : ` — ${bad}`}`);
}

// An image drawn at a size the CSS gives it.
check("a CSS width and height fill the picture", near(75, 75, RED));
check("the picture reaches the box's far corner", near(145, 145, RED));
check("the picture stops at the box's edge", near(155, 75, WHITE));
check("width and height attributes are the intrinsic size", near(170, 10, BLUE));
check("the right half of the file draws green", near(230, 10, GREEN));
check("an 80x40 image ends at 80", near(245, 10, WHITE));
check("a width attribute alone takes the viewBox ratio for the height", near(170, 60, TEAL));
check("the ratio's height reaches the bottom", near(270, 100, TEAL));
check("the ratio's height stops at 60", near(270, 115, WHITE));
check("a 120px image ends at 120", near(290, 60, WHITE));
check("a width in CSS takes the file's ratio for the height", near(330, 340, BLUE));
check("the ratio's height puts green at the bottom right", near(380, 355, GREEN));
check("the ratio's height stops where it says", near(380, 370, WHITE));
// A file with only a viewBox has a ratio and no size of its own: it fills the box it is given.
check("a viewBox-only image fills the width it is given", near(50, 420, RED));
check("it does not take the 300px default object size", near(105, 420, WHITE));
check("the ratio gives it a height from that width", near(50, 445, RED));
check("its height stops where the ratio says", near(50, 460, GREEN));
// A viewBox-only background has a ratio and no size: an auto size fits that ratio into the
// positioning area — 160 square in this 200 by 160 box, not the default object size.
check("a ratio-only background fits the area's short side", near(195, 475, RED));
check("its square reaches the area's far corner", near(275, 555, RED));
check("it stops at the fitted square's edge", near(285, 475, WHITE));
check("its height fills the area", near(125, 555, RED));

// The file's own geometry, transforms and paint.
check("a transform in the file moves the shape", near(370, 260, ORANGE));
check("the shape is not where it was before the transform", near(330, 230, WHITE));
check("currentColor is the file's own black, not the page's colour", near(20, 350, BLACK));
check("fill-opacity fades toward the page", near(80, 340, [255, 128, 128]));
check("a stroke-only shape leaves its middle clear", near(160, 350, WHITE));
check("the stroke is drawn at its width", near(160, 341, BLUE));
check("the stroke stops outside its width", near(160, 333, WHITE));
check("a use in a file draws what it references", near(10, 580, RED));
check("a use in a file sizes its symbol", near(40, 580, BLUE));
check("a use in a file leaves the space between its copies", near(25, 580, WHITE));
check("a use in a file ends where its width says", near(55, 580, WHITE));
check("a dasharray in a file draws its dashes", near(90, 580, RED));
check("a dasharray in a file leaves its gaps", near(98, 580, WHITE));
check("a dasharray in a file repeats", near(106, 580, RED));
check("a clip path in a file keeps what it covers", near(170, 580, RED));
check("a clip path in a file cuts what it leaves out", near(190, 580, WHITE));
check("nested clips intersect in a file", near(220, 575, RED));
check("the file's group clip cuts the outer side", near(240, 575, WHITE));
check("the file's shape clip cuts the lower side", near(220, 585, WHITE));
check("preserveAspectRatio none stretches the viewBox", near(220, 340, PINK));
check("the stretch leaves the right half empty", near(280, 340, WHITE));

// object-fit, against the four quadrants of quad.svg.
check("contain keeps the picture's ratio, red quadrant", near(37, 172, RED));
check("contain reaches the green quadrant", near(62, 172, GREEN));
check("contain reaches the blue quadrant", near(37, 197, BLUE));
check("contain reaches the yellow quadrant", near(62, 197, YELLOW));
check("contain leaves the box's left side empty", near(10, 185, WHITE));
check("contain leaves the box's right side empty", near(90, 185, WHITE));
check("cover crops: red quadrant", near(170, 172, RED));
check("cover crops: green quadrant", near(270, 172, GREEN));
check("cover crops: blue quadrant", near(170, 197, BLUE));
check("cover crops: yellow quadrant", near(270, 197, YELLOW));

// CSS url() backgrounds: tiles, their size, and their position.
check("a background tile draws its first quadrant", near(12, 232, RED));
check("a background tile draws its second quadrant", near(37, 232, GREEN));
check("a background tile draws its third quadrant", near(12, 257, BLUE));
check("a background tile draws its fourth quadrant", near(37, 257, YELLOW));
check("a background repeats across", near(87, 232, GREEN));
check("a background repeats down", near(12, 282, RED));
check("a background-size in px sets the tile's size", near(62, 282, RED));
check("a 50px tile repeats its second quadrant", near(87, 282, GREEN));
check("a non-repeating background leaves the rest of the box", near(190, 250, WHITE));
check("background-position right bottom places the image", near(170, 250, PINK));
check("background-position right bottom leaves the left side", near(125, 225, WHITE));
check("background-position right bottom leaves the top", near(175, 225, WHITE));
check("background-size contain keeps the ratio: red", near(212, 232, RED));
check("background-size contain keeps the ratio: green", near(237, 232, GREEN));
check("background-size contain keeps the ratio: blue", near(212, 257, BLUE));
check("background-size contain keeps the ratio: yellow", near(237, 257, YELLOW));
check("background-size contain leaves the box's right side empty", near(255, 225, WHITE));

// A gradient in the file's own draw program.
check("an image gradient starts at its first stop", near(332, 430, [247, 0, 8], 12));
check("an image gradient runs between its stops", near(360, 430, [127, 0, 128], 12));
check("an image gradient ends at its last stop", near(388, 430, [8, 0, 247], 12));

// Text in the file: its glyphs fill in its paint from the baseline point, a tspan takes the fill
// it declares from the pen's place on, and text-anchor moves the text to its anchor point.
const TY = 610;
check("an image's text glyph is filled in its paint", ink(4, TY + 6, 18, TY + 18, RED) >= 4 ? null : "no red ink");
check("an image's text ends where its glyphs do", drawn(40, TY + 6, 120, TY + 20) === 0 ? null : "ink past the text");
check("an image's tspan-less run keeps the text's fill", ink(4, TY + 27, 16, TY + 37, BLUE) >= 4 ? null : "no blue ink");
check("an image's tspan takes the fill it declares", ink(24, TY + 27, 40, TY + 37, GREEN) >= 4 ? null : "no green ink");
check("an image's tspan dx moves the pen on", drawn(18, TY + 27, 22, TY + 37) === 0 ? null : "ink before the dx");
check("an image's text-anchor end ends at x", drawn(100, TY + 43, 120, TY + 56) > 0 ? null : "no ink at the anchor");
check("an image's text-anchor end moves the text left", drawn(60, TY + 43, 96, TY + 56) === 0 ? null : "ink right of it");

// A percentage root size leaves the picture no size of its own: an auto background is the box,
// and the file's percentage geometry fills it.
check("a percentage-sized image takes the box's width", near(10, 690, RED));
check("a percentage-sized image takes the box's height", near(10, 735, BLUE));
check("and reaches the box's far corner", near(115, 735, BLUE));

// A file that gives its own 10 by 20 px viewport is drawn at 20 by 40 scaled: its 10px halves
// double, and the drawn image still ends at its own width.
check("a sized image scales its shapes at 2x", near(150, 690, GREEN));
check("the scaled picture's second half follows", near(150, 710, YELLOW));
check("the scaled picture ends at its drawn width", near(175, 690, WHITE));

// A cover fit of an extreme ratio is billions of pixels tall: the visible part is still painted.
check("an extreme-ratio cover fills the box", near(10, 750, GREEN));
check("it reaches the box's far corner", near(95, 775, GREEN));
// A viewBox with a zero height disables rendering: an auto-sized background paints nothing.
check("a zero-height viewBox paints nothing", near(150, 750, WHITE));
check("it paints nothing at the far corner", near(235, 775, WHITE));

if (failed > 0) {
  console.error(`\n${failed} check${failed === 1 ? "" : "s"} failed`);
  process.exit(1);
}
console.log("\nall svg image checks passed");
