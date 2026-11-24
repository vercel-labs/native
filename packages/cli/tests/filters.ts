// filter (blur, the colour functions, drop-shadow), mix-blend-mode and isolation: the pixels each
// one paints, and the computed value's text.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";
import type { Image } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=320, height=360"><style>
body { margin: 0; }
.box { position: absolute; background: #ff0000; }
#gray { left: 0; top: 0; width: 40px; height: 40px; filter: grayscale(1); }
#inv { left: 50px; top: 0; width: 40px; height: 40px; filter: invert(1); }
#bri { left: 100px; top: 0; width: 40px; height: 40px; filter: brightness(0.5); }
#fade { left: 150px; top: 0; width: 40px; height: 40px; filter: opacity(0.5); }
#sat { left: 200px; top: 0; width: 40px; height: 40px; filter: saturate(0); }
#sep { left: 250px; top: 0; width: 40px; height: 40px; background: #0000ff; filter: sepia(1); }
#blur { left: 40px; top: 60px; width: 60px; height: 40px; filter: blur(4px); }
#drop { left: 40px; top: 120px; width: 60px; height: 40px; filter: drop-shadow(5px 0 #00aa00); }
#dropv { left: 140px; top: 120px; width: 40px; height: 40px; filter: drop-shadow(0 3px #00aa00); }
#bdunder { left: 160px; top: 60px; width: 80px; height: 40px; background: #ff0000; }
#bdover { position: absolute; left: 180px; top: 70px; width: 40px; height: 20px; backdrop-filter: invert(1); }
#back { left: 0; top: 200px; width: 100px; height: 40px; background: #0000ff; }
#front { left: 50px; top: 210px; width: 100px; height: 40px; mix-blend-mode: multiply; }
#under { left: 150px; top: 270px; width: 100px; height: 40px; background: #0000ff; }
#group { left: 175px; top: 270px; width: 50px; height: 40px; background: none; isolation: isolate; }
#child { position: absolute; left: 0; top: 0; width: 50px; height: 40px; background: #ff0000; mix-blend-mode: multiply; }
#em { left: 300px; top: 0; width: 16px; height: 16px; font-size: 20px; filter: blur(0.5em); background: none; }
#cbwrap { left: 240px; top: 60px; width: 60px; height: 40px; filter: brightness(1); }
#cbchild { position: absolute; left: 0; bottom: 0; width: 20px; height: 10px; background: #0000ff; }
#plain { left: 0; top: 350px; width: 10px; height: 10px; }
</style></head><body>
<div class="box" id="gray"></div>
<div class="box" id="inv"></div>
<div class="box" id="bri"></div>
<div class="box" id="fade"></div>
<div class="box" id="sat"></div>
<div class="box" id="sep"></div>
<div class="box" id="blur"></div>
<div class="box" id="drop"></div>
<div class="box" id="dropv"></div>
<div class="box" id="bdunder"></div>
<div id="bdover"></div>
<div class="box" id="back"></div>
<div class="box" id="front"></div>
<div class="box" id="under"></div>
<div class="box" id="group"><div id="child"></div></div>
<div class="box" id="em"></div>
<div class="box" id="cbwrap"><div id="cbchild"></div></div>
<div class="box" id="plain"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const css = (id: string) => getComputedStyle(document.getElementById(id)!);
for (const id of ["gray", "inv", "bri", "fade", "sat", "sep", "blur", "drop", "plain", "em"]) {
  console.log(id + "=" + css(id).filter);
}
console.log("mix=" + css("front").mixBlendMode);
console.log("mixplain=" + css("plain").mixBlendMode);
console.log("iso=" + css("group").isolation);
console.log("isoplain=" + css("plain").isolation);
console.log("backdrop=" + css("plain").backdropFilter);
const inv = document.getElementById("inv")!;
inv.style.filter = "blur(2px) brightness(50%)";
console.log("inline=" + css("inv").filter);
inv.style.filter = "blur(-1px)";
console.log("invalid=" + css("inv").filter);
inv.style.removeProperty("filter");
console.log("removed=" + css("inv").filter);
const plain = document.getElementById("plain")!;
plain.style.filter = "hue-rotate(0.25turn) grayscale(50%) drop-shadow(2px 3px 4px)";
plain.style.color = "#0000ff";
console.log("list=" + css("plain").filter);
plain.style.backdropFilter = "blur(3px) saturate(150%)";
console.log("backdropinline=" + css("plain").backdropFilter);
plain.style.mixBlendMode = "screen";
plain.style.isolation = "isolate";
console.log("mixinline=" + css("plain").mixBlendMode);
console.log("isoinline=" + css("plain").isolation);
`;

const EXPECTED_LOG: [string, string][] = [
  ["grayscale serializes its amount", "gray=grayscale(1)"],
  ["invert serializes its amount", "inv=invert(1)"],
  ["brightness keeps its number", "bri=brightness(0.5)"],
  ["opacity keeps its fraction", "fade=opacity(0.5)"],
  ["saturate keeps zero", "sat=saturate(0)"],
  ["a blur serializes its length", "blur=blur(4px)"],
  ["drop-shadow serializes color first", "drop=drop-shadow(rgb(0, 170, 0) 5px 0px 0px)"],
  ["no filter computes as none", "plain=none"],
  ["an em blur resolves against the font size", "em=blur(10px)"],
  ["sepia serializes", "sep=sepia(1)"],
  ["no blending computes as normal", "mixplain=normal"],
  ["a blend mode serializes", "mix=multiply"],
  ["isolation defaults to auto", "isoplain=auto"],
  ["isolation serializes", "iso=isolate"],
  ["no backdrop filter computes as none", "backdrop=none"],
  ["a percentage is a fraction in the serialized value", "inline=blur(2px) brightness(0.5)"],
  ["a negative blur is invalid and leaves the last value", "invalid=blur(2px) brightness(0.5)"],
  ["removing the inline filter restores the rule", "removed=invert(1)"],
  ["a list keeps its written order, with currentColor resolved",
    "list=hue-rotate(90deg) grayscale(0.5) drop-shadow(rgb(0, 0, 255) 2px 3px 4px)"],
  ["an inline backdrop filter parses and serializes", "backdropinline=blur(3px) saturate(1.5)"],
  ["an inline blend mode applies", "mixinline=screen"],
  ["an inline isolation applies", "isoinline=isolate"],
];

function buildAndRun(): { img: Image; out: string } {
  const dir = mkdtempSync(join(tmpdir(), "native-filters-"));
  writeFileSync(join(dir, "index.html"), PAGE);
  writeFileSync(join(dir, "app.ts"), SCRIPT);
  const exe = join(dir, "app");
  const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
  if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
  const png = join(dir, "out.png");
  const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png } });
  if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
  return { img: decodePng(png), out: `${r.stdout}${r.stderr}` };
}

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const { img, out } = buildAndRun();
// The snapshot is 2 device px per CSS px; the helpers take CSS coordinates.
const rgb = (x: number, y: number): number[] => {
  const o = (Math.round(y * 2) * img.w + Math.round(x * 2)) * 4;
  return [img.rgba[o], img.rgba[o + 1], img.rgba[o + 2]];
};
const near = (x: number, y: number, c: number[], tol = 24): boolean => {
  const p = rgb(x, y);
  return Math.abs(p[0] - c[0]) <= tol && Math.abs(p[1] - c[1]) <= tol && Math.abs(p[2] - c[2]) <= tol;
};
const white = (x: number, y: number): boolean => near(x, y, [255, 255, 255]);
const RED = [255, 0, 0];
const GREEN = [0, 170, 0];
const BLUE = [0, 0, 255];

// Row 1: one colour function each, on a red box 40x40 (blue for sepia).
check("grayscale(1) leaves a hue-less luminance", near(20, 20, [54, 54, 54]), `got ${rgb(20, 20)}`);
check("invert(1) turns red into cyan", near(70, 20, [0, 255, 255]), `got ${rgb(70, 20)}`);
check("brightness(0.5) halves the colour", near(120, 20, [128, 0, 0]), `got ${rgb(120, 20)}`);
check("opacity(0.5) lets the page show through", near(170, 20, [255, 128, 128]), `got ${rgb(170, 20)}`);
check("saturate(0) leaves a hue-less luminance", near(220, 20, [54, 54, 54]), `got ${rgb(220, 20)}`);
check("sepia(1) tints blue towards brown", near(270, 20, [48, 43, 33]), `got ${rgb(270, 20)}`);

// #blur at (40, 60), 60x40, `blur(4px)`: the interior stays red, the edge mixes with the white
// page, and a few pixels out nothing is left.
check("a blur keeps the middle of the box", near(70, 80, RED), `got ${rgb(70, 80)}`);
const edge = rgb(70, 60);
check("a blur softens the box's edge", edge[0] === 255 && edge[1] > 40 && edge[1] < 220, `got ${edge}`);
check("a blur fades out past the edge", white(70, 46), `got ${rgb(70, 46)}`);
check("a blur reaches outside the box a little", !near(70, 58, [255, 255, 255], 6), `got ${rgb(70, 58)}`);

// #drop at (40, 120), 60x40, `drop-shadow(5px 0 #00aa00)`: the shadow is the box's own shape
// (background included) moved 5px right.
check("a drop shadow shows past the box", near(102, 140, GREEN), `got ${rgb(102, 140)}`);
check("a drop shadow ends where the shape ends", white(106, 140), `got ${rgb(106, 140)}`);
check("a drop shadow leaves the other side clear", white(30, 140), `got ${rgb(30, 140)}`);
check("a drop shadow has the box's height", white(102, 163), `got ${rgb(102, 163)}`);
check("the box paints over its own drop shadow", near(70, 140, RED), `got ${rgb(70, 140)}`);
check("a drop shadow's vertical offset goes down", near(160, 161, GREEN), `got ${rgb(160, 161)}`);
check("a drop shadow doesn't go up instead", white(160, 118), `got ${rgb(160, 118)}`);

// #bdover at (180, 70), 40x20 with `backdrop-filter: invert(1)` over #bdunder's red: the box shows
// the inverted backdrop, and the red around it is untouched.
check("a backdrop filter inverts what is behind the box", near(200, 80, [0, 255, 255]), `got ${rgb(200, 80)}`);
check("a backdrop filter leaves the rest of the backdrop", near(170, 80, RED), `got ${rgb(170, 80)}`);
check("a backdrop filter stops at the border box", near(200, 95, RED), `got ${rgb(200, 95)}`);

// #front at (50, 210), red with `mix-blend-mode: multiply`, over #back (blue, (0, 200), 100x40):
// where they overlap red x blue is black, and the rest of the red box only multiplies with the
// white page, so it stays red.
check("multiply darkens the overlap to black", near(70, 225, [0, 0, 0]), `got ${rgb(70, 225)}`);
check("multiply over white leaves the color", near(120, 225, RED), `got ${rgb(120, 225)}`);
check("multiply leaves the box below alone", near(20, 205, BLUE), `got ${rgb(20, 205)}`);

// #group at (175, 270) isolates its content: its red child multiplies with the group's own
// (transparent) backdrop rather than with the blue box beneath, so the group still paints red.
check("isolation keeps a blended child off the backdrop", near(200, 290, RED), `got ${rgb(200, 290)}`);

// #cbwrap at (240, 60) carries a filter, which makes it the containing block of its absolutely
// positioned child (bottom-left of its padding box) rather than the viewport.
check("a filtered box contains its absolute child", near(250, 95, BLUE), `got ${rgb(250, 95)}`);
check("that child isn't placed against the viewport", !near(5, 355, BLUE, 30), `got ${rgb(5, 355)}`);

const lines = out.split("\n");
EXPECTED_LOG.forEach(([name, want]) => {
  check(name, lines.includes(want), `want line "${want}"`);
});

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
