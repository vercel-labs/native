// The CSS object's feature detection, escaping and property registration, and the navigator's
// browser-facing fields.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=200"><style>
body { margin: 0; }
</style></head><body>
<div id="outer" style="--ui-a: 4px; --ui-b: 5px"><div id="inner"></div></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const log = (s: string): void => { console.log(s); };

CSS.registerProperty({ name: "--ui-a", syntax: "*", inherits: false });
CSS.registerProperty({ name: "--ui-c", syntax: "*", inherits: true, initialValue: "7px" });
let dup = false;
try {
  CSS.registerProperty({ name: "--ui-a", syntax: "*", inherits: false });
} catch {
  dup = true;
}

log("ua " + /Macintosh/.test(navigator.userAgent) + " " + navigator.platform + " " + navigator.language +
  " " + navigator.languages.length + " " + navigator.maxTouchPoints + " " + navigator.cookieEnabled);
log("supports flex " + CSS.supports("display", "flex") + " grid " + CSS.supports("display", "grid") +
  " color " + CSS.supports("color", "red") + " width " + CSS.supports("width", "10px"));
log("supports no " + CSS.supports("width", "banana") + " " + CSS.supports("not-a-property", "1") +
  " custom " + CSS.supports("--x", "anything at all"));
log("conditions " + CSS.supports("(display: flex)") + " " +
  CSS.supports("(display: none) and (color: red)") + " " + CSS.supports("not (display: grid)"));
// A property a transition declares is answered by the same value parser the cascade uses, and a
// padded property name or a bare declaration condition answers as a browser does.
log("supports edge " + CSS.supports(" transition-delay ", "0s") + " " +
  CSS.supports("transition-delay: 0s") + " " + CSS.supports("transition-delay", "0s"));
log("escape " + CSS.escape("a b") + "|" + CSS.escape("0x") + "|" + CSS.escape("-") + "|" + CSS.escape("--a"));
log("duplicate " + dup);

requestAnimationFrame(() => {
  const outer = getComputedStyle(document.getElementById("outer") as HTMLElement);
  const inner = getComputedStyle(document.getElementById("inner") as HTMLElement);
  log("customs outer " + outer.getPropertyValue("--ui-a") + " " + outer.getPropertyValue("--ui-b"));
  log("customs inner " + inner.getPropertyValue("--ui-a") + " " + inner.getPropertyValue("--ui-b") +
    " " + inner.getPropertyValue("--ui-c"));
});
`;

const EXPECTED_LOG = [
  "ua true MacIntel en-US 1 0 false",
  "supports flex true grid true color true width true",
  "supports no false false custom true",
  "conditions true true false",
  "supports edge false true true",
  "escape a\\ b|\\30 x|\\-|--a",
  "duplicate true",
  "customs outer 4px 5px",
  "customs inner  5px 7px",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-css-navigator-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const r = spawnSync(exe, [], {
  encoding: "utf8",
  env: { ...process.env, NATIVE_STEPS: "frame | frame" },
});
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);

const got = r.stdout.split("\n").slice(0, -1);
for (const line of got) console.log(`     got ${JSON.stringify(line)}`);
const want = EXPECTED_LOG;
if (want.length > 0) {
  check(`log lines (${want.length})`, got.length === want.length, `got ${got.length}`);
  const n = Math.min(got.length, want.length);
  for (let i = 0; i < n; i++) check(want[i], got[i] === want[i], `got ${JSON.stringify(got[i])}`);
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
