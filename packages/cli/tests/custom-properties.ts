// CSS custom properties (--x) and var(): the cascade through inheritance, var() inside
// shorthands and fallbacks, a cycle, invalid-at-computed-value-time, :root, the CSSOM side of
// custom properties, and a script changing one on :root with the page following at restyle time.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng, type Image } from "./png.ts";

const ACCENT = "rgb(51, 102, 153)";
const RED = "rgb(255, 0, 0)";

const PAGE = (accent: string, script: string): string => `<!doctype html>
<html><head><meta name="native-window" content="width=240, height=180"><style>
body { margin: 0; color: rgb(1, 2, 3); }
:root { --accent: ${accent}; --pad: 4px; --text: #fff; --base: 3px; --compose: var(--base); --Case: 5px; --case: 6px;
  border-top-style: solid; border-top-width: 7px; }
#card { background: var(--accent); padding: var(--pad) var(--gap, 8px); }
#card p { color: var(--text); }
#wrap { --inner: rgb(10, 20, 30); }
#wrap span { color: var(--inner); }
#cycle { --a: var(--b); --b: var(--a); }
#broken { background-color: var(--missing); }
#broken-text { color: var(--missing); }
#fallback { color: var(--missing, rgb(0, 128, 0)); }
#shadowed { --accent: rgb(0, 0, 255); background-color: var(--accent); }
#shorthand { margin: var(--pad); }
#case { width: var(--Case); }
#imp { --v: 1px; --v: 2px !important; width: var(--v); }
#compose { width: var(--compose); }
#btn { background: var(--accent); height: 18px; }
</style></head><body>
<div id="card"><p id="ptext">card</p></div>
<div id="wrap"><span id="inner">inner</span></div>
<div id="cycle">cycle</div>
<div id="broken">broken</div>
<div id="broken-text">broken text</div>
<div id="fallback">fallback</div>
<div id="shadowed">shadowed</div>
<div id="shorthand">shorthand</div>
<div id="case">case</div>
<div id="imp">imp</div>
<div id="compose">compose</div>
<button id="btn">Click</button>
${script}
</body></html>`;

const SCRIPT = `<script type="module">
const el = (sel: string): Element => document.querySelector(sel)!;
const cs = (sel: string): CSSStyleDeclaration => getComputedStyle(el(sel), "");
const log = (name: string, value: string): void => { console.log(name + " " + value); };

log("card-bg", cs("#card").backgroundColor);
log("card-pad", cs("#card").paddingTop + " " + cs("#card").paddingLeft);
log("card-text", cs("#ptext").color);
log("inner", cs("#inner").color);
log("cycle", JSON.stringify(cs("#cycle").getPropertyValue("--a")));
log("broken-bg", cs("#broken").backgroundColor);
log("broken-text", cs("#broken-text").color);
log("fallback", cs("#fallback").color);
log("shadowed", cs("#shadowed").backgroundColor);
log("shorthand", cs("#shorthand").marginTop);
log("case", cs("#case").width + " " + cs("#case").getPropertyValue("--Case") + " " + cs("#case").getPropertyValue("--case"));
log("imp", cs("#imp").width);
log("compose", cs("#compose").width);
log("root-border", getComputedStyle(document.documentElement, "").borderTopWidth);
log("card-border", cs("#card").borderTopWidth);
log("root-accent", getComputedStyle(document.documentElement, "").getPropertyValue("--accent"));

// A custom property on one element leaves its siblings alone.
log("sibling", cs("#btn").backgroundColor);

// The CSSOM side: setProperty, getPropertyValue (as set and as computed), removeProperty.
const btn = el("#btn");
const style = btn.style;
style.setProperty("--x", "9px");
log("inline-set", style.getPropertyValue("--x") + " " + cs("#btn").getPropertyValue("--x"));
style.removeProperty("--x");
log("inline-removed", JSON.stringify(style.getPropertyValue("--x")) + " " + JSON.stringify(cs("#btn").getPropertyValue("--x")));

// Changing the root's accent restyles everything that reads it.
log("before-click", cs("#card").backgroundColor);
const root = document.documentElement;
btn.addEventListener("click", () => { root.style.setProperty("--accent", ${JSON.stringify(RED)}); });
</script>`;

// The reference page needs only the accent it ends on; its console output isn't checked.
const REFERENCE_SCRIPT = `<script type="module">
const root = document.documentElement;
document.querySelector("#btn")!.addEventListener("click", () => { root.style.setProperty("--accent", ${JSON.stringify(RED)}); });
</script>`;

const EXPECTED_LOG = [
  `card-bg ${ACCENT}`,
  "card-pad 4px 8px",
  "card-text rgb(255, 255, 255)",
  "inner rgb(10, 20, 30)",
  "cycle \"\"",
  "broken-bg rgba(0, 0, 0, 0)",
  "broken-text rgb(1, 2, 3)",
  "fallback rgb(0, 128, 0)",
  "shadowed rgb(0, 0, 255)",
  "shorthand 4px",
  "case 5px 5px 6px",
  "imp 2px",
  "compose 3px",
  "root-border 7px",
  "card-border 0px",
  `root-accent ${ACCENT}`,
  `sibling ${ACCENT}`,
  "inline-set 9px 9px",
  `inline-removed "" ""`,
  `before-click ${ACCENT}`,
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-vars-"));

/** Builds and renders one page, returning its snapshot and the lines it logged. */
function render(name: string, html: string, steps: string): { image: Image; log: string[] } {
  const app = join(dir, name);
  mkdirSync(app);
  writeFileSync(join(app, "index.html"), html);
  const exe = join(app, "exe");
  const b = spawnSync("node", ["compiler/cli.ts", "build", app, "-o", exe], { encoding: "utf8" });
  if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
  const png = join(app, "out.png");
  const r = spawnSync(exe, [], {
    encoding: "utf8",
    env: { ...process.env, NATIVE_SNAPSHOT: png, NATIVE_STEPS: steps },
  });
  if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
  return { image: decodePng(png), log: r.stdout.split("\n").slice(0, -1) };
}

// The changed page starts on the indigo accent and is clicked, which sets the root's --accent to
// red; the reference page is built with red from the start and never clicked.
const changed = render("changed", PAGE(ACCENT, SCRIPT), "click #btn");
const fresh = render("fresh", PAGE(RED, REFERENCE_SCRIPT), "");

const got = changed.log ?? [];
check(`log lines (${EXPECTED_LOG.length})`, got.length === EXPECTED_LOG.length,
  `got ${got.length}: ${JSON.stringify(got.slice(EXPECTED_LOG.length))}`);
const n = Math.min(got.length, EXPECTED_LOG.length);
for (let i = 0; i < n; i++) check(EXPECTED_LOG[i], got[i] === EXPECTED_LOG[i], `got ${JSON.stringify(got[i])}`);

check(`${fresh.image.w}x${fresh.image.h} snapshot`,
  fresh.image.w === changed.image.w && fresh.image.h === changed.image.h,
  `the changed page is ${changed.image.w}x${changed.image.h}`);
// The reference has to paint the accent at all, or a blank page would match for free.
let red = 0;
for (let i = 0; i < fresh.image.rgba.length; i += 4) {
  if (fresh.image.rgba[i] === 255 && fresh.image.rgba[i + 1] === 0 && fresh.image.rgba[i + 2] === 0) red++;
}
check("the reference page paints the changed accent", red > 1000, `${red} red pixels`);
let differ = 0;
const len = Math.min(changed.image.rgba.length, fresh.image.rgba.length);
for (let i = 0; i < len; i += 4) {
  if (changed.image.rgba[i] !== fresh.image.rgba[i] || changed.image.rgba[i + 1] !== fresh.image.rgba[i + 1] ||
    changed.image.rgba[i + 2] !== fresh.image.rgba[i + 2]) differ++;
}
check("a page whose :root custom property changed paints as a fresh build does", differ === 0, `${differ} pixels differ`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
