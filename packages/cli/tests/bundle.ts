// A built app is self-contained: its images (markup, CSS, inline style and data: URLs), its
// @font-face files, the style sheets the page links and the files a script fetches travel with
// it, and the app keeps rendering after the output is moved and the source is deleted.
//   npm test

import { spawnSync } from "node:child_process";
import { copyFileSync, cpSync, existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { basename, join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng, encodePng } from "./png.ts";
import type { Image } from "./png.ts";
import { outputPaths } from "../compiler/build.ts";

const dir = mkdtempSync(join(tmpdir(), "native-bundle-"));
const app = join(dir, "app");
mkdirSync(join(app, "img"), { recursive: true });
mkdirSync(join(app, "alt"), { recursive: true });
mkdirSync(join(app, "bg"), { recursive: true });
mkdirSync(join(app, "data"), { recursive: true });
mkdirSync(join(app, "css"), { recursive: true });

const RED = [255, 0, 0], GREEN = [0, 255, 0], BLUE = [0, 0, 255], WHITE = [255, 255, 255];
/** A 4x4 solid-colour PNG. */
const solid = (colour: number[]): Buffer => encodePng(4, 4, () => [...colour, 255]);

// Two different pictures with the same name in different directories: the bundle must keep both,
// at the places the page names them.
writeFileSync(join(app, "img", "icon.png"), solid(RED));
writeFileSync(join(app, "alt", "icon.png"), solid(GREEN));
writeFileSync(join(app, "bg", "tex.png"), solid(BLUE));
writeFileSync(join(app, "data", "note.txt"), "hello bundle\n");
writeFileSync(join(app, "data", "inline.txt"), "inline fetch\n");
// The same bytes as a data: URL, which the build writes to a file of its own.
const dot = solid(BLUE).toString("base64");

// A face the machine has, copied next to the page so the build reads it; a machine without one
// leaves the font checks out (the file checks and images still run).
// A face whose metrics differ from the system sans-serif, so the text's width says whether the
// file loaded (Arial is the default sans on macOS, so it would tell nothing).
const FONT_CANDIDATES = [
  "/System/Library/Fonts/Supplemental/Times New Roman.ttf",
  "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
  "/usr/share/fonts/truetype/dejavu/DejaVuSerif.ttf",
  "/System/Library/Fonts/Supplemental/Arial.ttf",
];
const fontFile = FONT_CANDIDATES.find((f) => existsSync(f)) ?? null;
let fontCss = "";
let fontSpans = "";
let fontCheck = false;
if (fontFile !== null) {
  mkdirSync(join(app, "fonts"), { recursive: true });
  copyFileSync(fontFile, join(app, "fonts", "face.ttf"));
  // From the sheet in css/, the font is one directory up: the bundle keeps that relation.
  fontCss = `@font-face { font-family: BundleFace; src: url("../fonts/face.ttf?v=1") format("truetype"); }`;
  fontSpans = `<div id="faces" style="position: absolute; left: 0; top: 60px; white-space: nowrap">
<span id="own" style="font-family: BundleFace">Hamburgefonstiv</span>
<span id="sans" style="font-family: sans-serif">Hamburgefonstiv</span></div>`;
  fontCheck = true;
}

const PAGE = `<!doctype html>
<html><head><link rel="stylesheet" href="css/site.css"><meta name="native-window" content="width=120, height=90"><style>
body { margin: 0; background: #ffffff; font-size: 20px; }
img, div { position: absolute; width: 20px; height: 20px; }
#red { left: 0; top: 0; }
#green { left: 20px; top: 0; }
#bg { left: 40px; top: 0; }
#inline { left: 60px; top: 0; }
#dot { left: 80px; top: 0; background: url(data:image/png;base64,${dot}) 0 0 / 20px 20px no-repeat; }
#text { left: 0; top: 40px; }
</style></head><body>
<img id="red" src="img/icon.png?v=1#frag">
<img id="green" src="alt/icon.png">
<div id="bg"></div>
<div id="inline" style="background-image: url('alt/icon.png')"></div>
<div id="dot"></div>
<p id="text">-</p>
<p id="inlineNote" style="position: absolute; left: 0; top: 20px">-</p>
${fontSpans}
<script>
fetch("data/inline.txt").then((r) => r.text()).then((t) => {
  document.getElementById("inlineNote").textContent = t.trim();
});
</script>
<script src="app.ts"></script>
</body></html>
`;
writeFileSync(join(app, "index.html"), PAGE);
// The sheet sits in css/, and both its background and its @font-face name files one directory
// up, so the bundle has to keep the sheet's own place for its URLs to keep working.
writeFileSync(join(app, "css", "site.css"), `#bg { background: url("../bg/tex.png") 0 0 / 20px 20px no-repeat; }
${fontCss}
p { color: rgb(1, 2, 3); }
`);
writeFileSync(join(app, "app.ts"), `
const note = document.getElementById("text")!;
fetch("data/note.txt?x=1#y").then((r) => r.text()).then((t) => {
  note.textContent = t.trim();
  console.log("note=" + t.trim());
});
requestAnimationFrame(() => {
  requestAnimationFrame(() => {
    const width = (id: string): number =>
      Math.round(document.getElementById(id)!.getBoundingClientRect().width * 100) / 100;
    console.log("own=" + width("own") + " sans=" + width("sans"));
  });
});
`);


let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const built = join(dir, "out", "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", app, "-o", built], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

// Where the build put the executable and the app's files.
const paths = outputPaths(built, true);
const exe = paths.executable;

// A second build of the same inputs answers from the build cache, before the front end runs.
// Its entry carries the app's files, so a hit has to put the bundle back too: deleting it
// first proves the cached build did.
rmSync(paths.resources, { recursive: true, force: true });
const again = spawnSync("node", ["compiler/cli.ts", "build", app, "-o", built], { encoding: "utf8" });
if (again.status !== 0) throw new Error(`cached build failed\n${again.stderr}`);

function run(file: string, snapshot: string, steps: string): { stdout: string[]; png: Image } {
  const r = spawnSync(file, [], {
    encoding: "utf8",
    env: { ...process.env, NATIVE_STEPS: steps, NATIVE_SNAPSHOT: snapshot },
  });
  if (r.status !== 0) throw new Error(`run failed (${r.status})\n${r.stderr}\n${r.stdout}`);
  return { stdout: r.stdout.split("\n").filter((l) => l !== ""), png: decodePng(snapshot) };
}

const STEPS = fontCheck ? "frame 1 | frame 1 | print #text | print #inlineNote" : "frame 1 | print #text | print #inlineNote";
const before = run(exe, join(dir, "before.png"), STEPS);

// The bundle holds the files the app reads, each at the place the page names it.
const res = paths.resources;
check("the build cache answered the second build", again.stderr.includes("scriptc cached"), again.stderr);
for (const file of ["img/icon.png", "alt/icon.png", "bg/tex.png", "data/note.txt", "data/inline.txt", "css/site.css"]) {
  check(`the bundle holds ${file}`, existsSync(join(res, ...file.split("/"))));
}
if (fontCheck) check("the bundle holds the font file", existsSync(join(res, "fonts", "face.ttf")));
if (paths.bundle !== null) check("the app bundle has an Info.plist", existsSync(join(paths.bundle, "Contents", "Info.plist")));

// The app keeps its files when the output moves and the source goes away.
const moved = join(dir, "moved");
mkdirSync(moved, { recursive: true });
let movedExe: string;
if (paths.bundle !== null) {
  const target = join(moved, basename(paths.bundle));
  cpSync(paths.bundle, target, { recursive: true });
  movedExe = join(target, "Contents", "MacOS", basename(built));
} else {
  movedExe = join(moved, basename(paths.executable));
  copyFileSync(paths.executable, movedExe);
  if (existsSync(paths.resources)) cpSync(paths.resources, join(moved, basename(paths.resources)), { recursive: true });
}
rmSync(app, { recursive: true, force: true });
rmSync(join(dir, "out"), { recursive: true, force: true });

const after = run(movedExe, join(dir, "after.png"), STEPS);
check("the moved app prints what it did before", JSON.stringify(after.stdout) === JSON.stringify(before.stdout),
  `before ${JSON.stringify(before.stdout)}, after ${JSON.stringify(after.stdout)}`);
check("the moved app renders what it did before", after.png.w === before.png.w && after.png.h === before.png.h &&
  after.png.rgba.every((v, i) => v === before.png.rgba[i]));

// The pictures are where they were, from the bundle: the same-named files in different
// directories each draw their own colour, and the CSS, inline-style and data: images too.
const scale = after.png.w / 120;
function at(cx: number, cy: number): number[] {
  const o = (Math.round(cy * scale) * after.png.w + Math.round(cx * scale)) * 4;
  return [after.png.rgba[o], after.png.rgba[o + 1], after.png.rgba[o + 2]];
}
function near(cx: number, cy: number, want: number[]): boolean {
  const got = at(cx, cy);
  return got.every((g, i) => Math.abs(g - want[i]) <= 8);
}
check("the markup image from img/ draws", near(10, 10, RED), `got ${at(10, 10)}`);
check("the same-named image from alt/ draws", near(30, 10, GREEN), `got ${at(30, 10)}`);
check("the style sheet's background image draws", near(50, 10, BLUE), `got ${at(50, 10)}`);
check("the inline style's background image draws", near(70, 10, GREEN), `got ${at(70, 10)}`);
check("the data: background image draws", near(90, 10, BLUE), `got ${at(90, 10)}`);
for (const [x, y] of [[5, 25], [115, 25]]) check("the page background stays white", near(x, y, WHITE));

if (fontCheck) {
  const stdout = before.stdout.join("\n");
  const m = /own=([\d.]+) sans=([\d.]+)/.exec(stdout);
  check("the @font-face file loaded from the bundle", m !== null && Math.abs(Number(m[1]) - Number(m[2])) > 0.5,
    m === null ? `no measurement in ${JSON.stringify(before.stdout)}` : `own=${m[1]} sans=${m[2]}`);
}

// A missing asset is named in the diagnostic, and a missing style sheet stops the build.
const missing = join(dir, "missing");
mkdirSync(missing, { recursive: true });
writeFileSync(join(missing, "index.html"), '<!doctype html><html><body><img src="nothere.png">' +
  '<link rel="stylesheet" href="gone.css"></body></html>');
const missingCheck = spawnSync("node", ["compiler/cli.ts", "check", missing], { encoding: "utf8" });
check("a missing image is named", missingCheck.stderr.includes("image 'nothere.png' not found"), missingCheck.stderr);
check("a missing style sheet is an error", missingCheck.status !== 0 &&
  missingCheck.stderr.includes("stylesheet 'gone.css' not found"), missingCheck.stderr);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
