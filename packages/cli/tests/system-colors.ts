// CSS's system colours: Canvas, CanvasText, ButtonFace, the deprecated CSS Color 3 names, and the
// ones that follow the element's color-scheme. A system colour resolves when the element's style is
// computed, so an element in a dark scheme gets the dark platform colours, while the declaration
// itself still reads back as the keyword a page wrote.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta charset="utf-8"><meta name="native-window" content="width=300, height=200"></head><body>
<div id="box" style="background-color: Canvas; color: CanvasText">text</div>
<div id="probe"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const log = (s: string): void => { console.log(s); };
const box = document.getElementById("box")!;
const probe = document.getElementById("probe")!;

// The declaration keeps the keyword as the page wrote it, and the computed value is the colour.
box.style.backgroundColor = "Canvas";
log("specified " + box.style.backgroundColor);
log("specified cssText " + (box.style.cssText.indexOf("Canvas") >= 0 || box.style.cssText.indexOf("canvas") >= 0));
log("light canvas " + getComputedStyle(box).backgroundColor);
log("light canvastext " + getComputedStyle(box).color);
log("light buttonface " + (probe.style.color = "ButtonFace", getComputedStyle(probe).color));
log("light field " + (probe.style.color = "Field", getComputedStyle(probe).color));
log("light linktext " + (probe.style.color = "LinkText", getComputedStyle(probe).color));
log("light mark " + (probe.style.color = "Mark", getComputedStyle(probe).color));
log("light graytext " + (probe.style.color = "GrayText", getComputedStyle(probe).color));

// The deprecated names mean the system colours they were replaced by.
probe.style.color = "Window";
log("deprecated window " + probe.style.color + " " + getComputedStyle(probe).color);
probe.style.color = "ThreeDFace";
log("deprecated threedface " + probe.style.color + " " + getComputedStyle(probe).color);
probe.style.color = "InfoText";
log("deprecated infotext " + probe.style.color + " " + getComputedStyle(probe).color);

// A colour name inside a shorthand and a shadow is a colour too.
box.style.border = "1px solid ButtonBorder";
log("shorthand border " + getComputedStyle(box).borderTopColor);
box.style.boxShadow = "0 0 0 1px ButtonBorder";
log("shadow " + getComputedStyle(box).boxShadow);

// A custom property keeps its token stream: its value isn't a colour position of its own.
probe.style.setProperty("--tone", "Canvas");
log("custom property " + getComputedStyle(probe).getPropertyValue("--tone"));

// A system colour no custom property of the page can see: it isn't one of the page's own.
log("no custom property " + getComputedStyle(box).getPropertyValue("--native-sys-canvas"));
log("supports " + CSS.supports("color", "Canvas"));

// The scheme an element is drawn in picks its platform colours.
document.documentElement.style.colorScheme = "dark";
log("dark canvas " + getComputedStyle(box).backgroundColor);
log("dark canvastext " + getComputedStyle(box).color);
log("dark buttonface " + (probe.style.color = "ButtonFace", getComputedStyle(probe).color));
log("dark linktext " + (probe.style.color = "LinkText", getComputedStyle(probe).color));

// An element can ask for the other scheme than the page's.
probe.style.colorScheme = "light";
log("element light canvastext " + (probe.style.color = "CanvasText", getComputedStyle(probe).color));
probe.style.colorScheme = "";
document.documentElement.style.colorScheme = "";

// \`light dark\` follows the system's appearance.
document.documentElement.style.colorScheme = "light dark";
const systemDark = matchMedia("(prefers-color-scheme: dark)").matches;
log("follows the system " + (getComputedStyle(box).backgroundColor === (systemDark ? "rgb(18, 18, 18)" : "rgb(255, 255, 255)")));
document.documentElement.style.colorScheme = "";

// light-dark() picks its branch by the element's scheme.
probe.style.colorScheme = "light";
probe.style.color = "light-dark(white, black)";
log("light-dark light " + getComputedStyle(probe).color);
probe.style.colorScheme = "dark";
log("light-dark dark " + getComputedStyle(probe).color);
probe.style.colorScheme = "";

// Lightness at the ends of its range is white or black whatever the other components say, and a
// negative saturation clamps to none.
probe.style.color = "lab(150 50 20)";
log("lab over " + getComputedStyle(probe).color);
probe.style.color = "lch(100% 110 60)";
log("lch white " + getComputedStyle(probe).color);
probe.style.color = "hsl(0 -100% 50%)";
log("hsl clamp " + getComputedStyle(probe).color);

// A modern colour function computes to its own space, which CSSOM reads back; the value as
// written stays the specified one, and a plain colour that wins later has no form of its own.
probe.style.color = "oklch(58.5% 0.233 277.117)";
log("form oklch " + getComputedStyle(probe).color);
log("form specified " + probe.style.color);
probe.style.color = "lab(50% 40 -30)";
log("form lab " + getComputedStyle(probe).color);
probe.style.color = "color(display-p3 1 0 0)";
log("form color " + getComputedStyle(probe).color);
probe.style.color = "color-mix(in srgb, red, blue)";
log("mix form " + getComputedStyle(probe).color);
// An achromatic mix has no hue to name, and CSS writes that as none.
probe.style.color = "color-mix(in lch, black, black)";
log("mix achromatic " + getComputedStyle(probe).color);
probe.style.color = "red";
log("form cleared " + getComputedStyle(probe).color);
probe.style.color = "";

// Highlight is the colour a selection paints with, so it is a real colour and not the canvas.
probe.style.color = "Highlight";
log("highlight " + getComputedStyle(probe).color);
`;

const EXPECTED = [
  "specified canvas",
  "specified cssText true",
  "light canvas rgb(255, 255, 255)",
  "light canvastext rgb(0, 0, 0)",
  "light buttonface rgb(239, 239, 239)",
  "light field rgb(255, 255, 255)",
  "light linktext rgb(0, 0, 238)",
  "light mark rgb(255, 255, 0)",
  "light graytext rgb(118, 118, 118)",
  "deprecated window canvas rgb(255, 255, 255)",
  "deprecated threedface buttonface rgb(239, 239, 239)",
  "deprecated infotext canvastext rgb(0, 0, 0)",
  "shorthand border rgb(118, 118, 118)",
  "shadow rgb(118, 118, 118) 0px 0px 0px 1px",
  "custom property Canvas",
  "no custom property",
  "supports true",
  "dark canvas rgb(18, 18, 18)",
  "dark canvastext rgb(255, 255, 255)",
  "dark buttonface rgb(107, 107, 107)",
  "dark linktext rgb(158, 158, 255)",
  "element light canvastext rgb(0, 0, 0)",
  "follows the system true",
  "light-dark light rgb(255, 255, 255)",
  "light-dark dark rgb(0, 0, 0)",
  "lab over lab(100 50 20)",
  "lch white lch(100 110 60)",
  "hsl clamp rgb(128, 128, 128)",
  "form oklch oklch(0.585 0.233 277.117)",
  "form specified oklch(58.5% 0.233 277.117)",
  "form lab lab(50 40 -30)",
  "form color color(display-p3 1 0 0)",
  "mix form color(srgb 0.5 0 0.5)",
  "mix achromatic lch(0 0 none)",
  "form cleared rgb(255, 0, 0)",
  "highlight rgba(128, 188, 254, 0.6)",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-system-colors-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: "frame 2" };
delete env.NATIVE_SNAPSHOT;
const r = spawnSync(exe, [], { encoding: "utf8", env });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const got = r.stdout.split("\n").map((l) => l.trim()).filter((l) => l !== "");
for (const line of got) console.log(`     got ${JSON.stringify(line)}`);
check("the page logs every line", got.length === EXPECTED.length, `got ${got.length}, wanted ${EXPECTED.length}`);
for (let i = 0; i < Math.min(got.length, EXPECTED.length); i++) {
  const ok = EXPECTED[i].endsWith("rgb(") ? got[i].startsWith(EXPECTED[i]) : got[i] === EXPECTED[i];
  check(EXPECTED[i].length > 40 ? EXPECTED[i].slice(0, 40) : EXPECTED[i], ok, `got ${JSON.stringify(got[i])}`);
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
