// The CSS a component library's stylesheet leans on: a ":where(:root, :host)" theme rule in a
// document (the :host alternative matches nothing), :empty, :has() inside :not(), a :host rule
// that matches nothing outside a shadow tree, touch-action's computed value, and a
// ::file-selector-button rule, which there is no file input to style.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=300"><style>
html { font-size: 20px; }
body { margin: 0; }
/* The rule that defines a theme's variables: the document matches through :root. */
:where(:root, :host) { --theme: rgb(1, 2, 3); }
#themed { color: var(--theme); }
.empty:empty { background-color: rgb(10, 20, 30); }
#noSvg:not(:has(> svg)) { background-color: rgb(40, 50, 60); }
#withSvg:has(> svg) { background-color: rgb(70, 80, 90); }
#hostRule:host { background-color: rgb(200, 0, 0); }
#ta { touch-action: manipulation; }
#ta2 { touch-action: pan-x pan-down pinch-zoom; }
#ta3 { touch-action: auto; }
#file::file-selector-button { color: rgb(0, 0, 0); }
#isnot:is(div):not(:empty) { background-color: rgb(90, 100, 110); }
/* light-dark() with oklch() inside, in the properties a theme uses, follows the used scheme. */
:root { color-scheme: light dark; }
#ld { color: light-dark(oklch(1 0 0), oklch(0 0 0)); }
#lddark { color-scheme: dark; color: light-dark(oklch(1 0 0), oklch(0 0 0)); }
#ldbg { background-color: light-dark(oklch(0 0 0), oklch(1 0 0)); }
#ldb { border: 1px solid light-dark(oklch(1 0 0), oklch(0 0 0)); }
#ldt { text-decoration: underline; text-decoration-color: light-dark(oklch(1 0 0), oklch(0 0 0)); }
#ldg { width: 10px; height: 10px; background-image: linear-gradient(light-dark(oklch(1 0 0), oklch(0 0 0)), oklch(1 0 0)); }
</style></head><body>
<div id="themed">t</div>
<div id="empty" class="empty"></div>
<div id="text" class="empty">x</div>
<div id="child" class="empty"><span></span></div>
<div id="noSvg"></div>
<div id="withSvg"><svg width="1" height="1"></svg></div>
<div id="hostRule"></div>
<div id="ta"></div><div id="ta2"></div><div id="ta3"></div>
<div id="file"></div>
<div id="isnot">x</div>
<div id="isnotEmpty"></div>
<div id="ld">x</div><div id="lddark">x</div><div id="ldbg"></div><div id="ldb"></div><div id="ldt">x</div><div id="ldg"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const log = (name: string, value: string): void => { console.log(name + " " + value); };
const cs = (sel: string): CSSStyleDeclaration => getComputedStyle(document.querySelector(sel)!, "");
log("theme", cs("#themed").color);
log("empty", cs("#empty").backgroundColor);
log("text", cs("#text").backgroundColor);
log("child", cs("#child").backgroundColor);
log("noSvg", cs("#noSvg").backgroundColor);
log("withSvg", cs("#withSvg").backgroundColor);
log("host", cs("#hostRule").backgroundColor);
log("ta", cs("#ta").touchAction);
log("ta2", cs("#ta2").touchAction);
log("ta3", cs("#ta3").touchAction);
log("isnot", cs("#isnot").backgroundColor);
log("isnotEmpty", cs("#isnotEmpty").backgroundColor);
log("ld", cs("#ld").color);
log("lddark", cs("#lddark").color);
log("ldbg", cs("#ldbg").backgroundColor);
log("ldb", cs("#ldb").borderTopColor);
log("ldt", cs("#ldt").textDecorationColor);
log("ldg", cs("#ldg").backgroundImage === "none" ? "none" : "gradient");
`;

const EXPECTED = [
  // :where(:root, :host) reaches the document through its :root alternative.
  "theme rgb(1, 2, 3)",
  // :empty is an element with no child elements and no text.
  "empty rgb(10, 20, 30)",
  "text rgba(0, 0, 0, 0)",
  "child rgba(0, 0, 0, 0)",
  // :not(:has(> svg)) asks that the element have no svg child of its own.
  "noSvg rgb(40, 50, 60)",
  "withSvg rgb(70, 80, 90)",
  // A :host rule names a shadow tree's host; a document has none, so it matches nothing.
  "host rgba(0, 0, 0, 0)",
  // touch-action reads back as the gestures it allows.
  "ta manipulation",
  "ta2 pan-x pan-down pinch-zoom",
  "ta3 auto",
  "isnot rgb(90, 100, 110)",
  "isnotEmpty rgba(0, 0, 0, 0)",
  // light-dark() picks the branch its element's used colour scheme asks for, oklch inside it too.
  // A colour keeps the space it was written in when it is serialised, as Chrome does.
  "ld oklch(1 0 0)",
  "lddark oklch(0 0 0)",
  "ldbg oklch(0 0 0)",
  "ldb rgb(255, 255, 255)",
  "ldt oklch(1 0 0)",
  "ldg gradient",
];

const dir = mkdtempSync(join(tmpdir(), "native-css-gaps-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);
// None of these selectors or values is a warning to the build.
if (/is not supported|unsupported/.test(build.stderr)) throw new Error(`warnings:\n${build.stderr}`);

// The system appearance is pinned so the light-dark() branches are the same on every machine.
const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: "frame 0", NATIVE_COLOR_SCHEME: "light" };
delete env.NATIVE_SNAPSHOT;
const r = spawnSync(exe, [], { encoding: "utf8", env });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);

const got = r.stdout.split("\n").slice(0, -1);
for (const line of got) console.log(`     got ${JSON.stringify(line)}`);
let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}
check(`log lines (${EXPECTED.length})`, got.length === EXPECTED.length, `got ${got.length}`);
for (let i = 0; i < Math.min(got.length, EXPECTED.length); i++) {
  check(EXPECTED[i], got[i] === EXPECTED[i], `got ${JSON.stringify(got[i])}`);
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
