// A textarea draws the text it holds, however the field came by it: the value a script sets, the
// text the markup gave it, a text child a renderer puts in it, and the same text after the DOM has
// been read through the field's children (childNodes, firstChild, a Range), which turns an
// element's own text into the #text child a browser has. A field that holds its text in a child
// still draws its value, and still edits the same text.   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";
import type { Image } from "./png.ts";

// Four 30 CSS px tall bands over a white page, at 2 device px per CSS px: band i covers device
// rows [60i, 60i + 60). Every field holds "Hg" in red, and all four must draw it in the same
// pixels: #a from the value a script set, #b from the markup's text after its children are read,
// #c from a script's value after firstChild and a Range read it, inside a scrolled pane (the
// shape the app had), and #d from the text child a renderer appends.
const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=200, height=120"><style>
body { margin: 0; background: #ffffff; }
textarea { display: block; width: 190px; height: 30px; margin: 0; border: 0; padding: 0;
  font: 20px monospace; color: #ff0000; background: #ffffff; }
#pane { height: 30px; overflow: auto; }
#pane div { height: 60px; }
</style></head><body>
<textarea id="a" rows="1"></textarea>
<textarea id="b" rows="1">Hg</textarea>
<div id="pane"><div></div><textarea id="c" rows="1"></textarea></div>
<textarea id="d" rows="1"></textarea>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
window.requestAnimationFrame(() => {
  const a = document.getElementById("a") as HTMLTextAreaElement;
  a.value = "Hg";
  // #a keeps its own text: nothing reads its children.
  const b = document.getElementById("b") as HTMLTextAreaElement;
  void b.childNodes.length;
  const c = document.getElementById("c") as HTMLTextAreaElement;
  c.value = "Hg";
  const pane = document.getElementById("pane") as HTMLElement;
  pane.scrollTop = 60;
  void c.firstChild;
  void document.createRange().selectNodeContents(c);
  // A renderer renders a field's text as a child of it.
  const d = document.getElementById("d") as HTMLTextAreaElement;
  d.appendChild(document.createTextNode("Hg"));
});
`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-textarea-value-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const png = join(dir, "out.png");
const run = spawnSync(exe, [], {
  encoding: "utf8",
  env: {
    ...process.env,
    NATIVE_STEPS: "frame 0 | frame 0 | print #a | print #b | print #c | print #d",
    NATIVE_SNAPSHOT: png,
  },
});
if (run.status !== 0) throw new Error(`render failed\n${run.stderr}`);
check("each field's value reads back", run.stdout.trim() === "Hg\nHg\nHg\nHg", JSON.stringify(run.stdout));

const img = decodePng(png);
const BAND = 60;

/** The pixels in a band, cropped to the field's own box. */
function band(i: number): Image {
  const w = 190 * 2;
  const h = BAND;
  const rgba = new Uint8Array(w * h * 4);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const from = ((i * BAND + y) * img.w + x) * 4;
      const to = (y * w + x) * 4;
      for (let k = 0; k < 4; k++) rgba[to + k] = img.rgba[from + k];
    }
  }
  return { w, h, rgba };
}

/** How many pixels in an image are the field's text colour. */
function glyphs(image: Image): number {
  let n = 0;
  for (let i = 0; i < image.rgba.length; i += 4) {
    if (image.rgba[i] > 150 && image.rgba[i + 1] < 100 && image.rgba[i + 2] < 100) n++;
  }
  return n;
}

const control = band(0);
const fromMarkup = band(1);
const inPane = band(2);
const fromChild = band(3);
check("the field whose value the script set draws it", glyphs(control) > 50, `${glyphs(control)} glyph pixels`);
check("a value read through childNodes still draws", glyphs(fromMarkup) === glyphs(control),
  `${glyphs(fromMarkup)} glyph pixels against ${glyphs(control)}`);
check("a value read through firstChild and a Range, in a scrolled pane, still draws",
  glyphs(inPane) === glyphs(control), `${glyphs(inPane)} glyph pixels against ${glyphs(control)}`);
check("a text child a renderer appends draws", glyphs(fromChild) === glyphs(control),
  `${glyphs(fromChild)} glyph pixels against ${glyphs(control)}`);

// A field holding its text in a child also takes edits: a press puts the caret at its end, as in
// a browser, and typing extends the same value.
const edited = spawnSync(exe, [], {
  encoding: "utf8",
  env: { ...process.env, NATIVE_STEPS: "frame 0 | click #d | key s | print #d | print #a" },
});
if (edited.status !== 0) throw new Error(`edit run failed\n${edited.stderr}`);
check("a field holding its text in a child still edits it", edited.stdout.trim() === "Hgs\nHg",
  JSON.stringify(edited.stdout));

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
