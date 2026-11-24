// Every property the build parses answers to its camelCase name on a style declaration: a script
// writes it and reads it back, on the declaration a style attribute gives and on the computed one,
// and the declaration serialises the hyphenated name. tests/props.ts fails when a parsed property
// has no accessor, so this checks the accessors that exist really reach the property.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=200"><style>
body { margin: 0; font: 13px monospace; }
</style></head><body>
<div id="d">x</div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function log(s: string): void { console.log(s); }
const d = document.getElementById("d") as HTMLElement;
// Writes through the accessor, then reads the declaration's own value and the computed one.
function check(name: string, write: (v: string) => void, read: () => string, computed: (cs: CSSStyleDeclaration) => string, value: string): void {
  write(value);
  const cs = getComputedStyle(d);
  log(name + " " + read() + "|" + computed(cs));
}
check("transitionProperty", (v) => { d.style.transitionProperty = v; }, () => d.style.transitionProperty, (cs) => cs.transitionProperty, "opacity");
check("transitionDuration", (v) => { d.style.transitionDuration = v; }, () => d.style.transitionDuration, (cs) => cs.transitionDuration, "0.3s");
check("animationName", (v) => { d.style.animationName = v; }, () => d.style.animationName, (cs) => cs.animationName, "spin");
check("animationPlayState", (v) => { d.style.animationPlayState = v; }, () => d.style.animationPlayState, (cs) => cs.animationPlayState, "paused");
check("columnCount", (v) => { d.style.columnCount = v; }, () => d.style.columnCount, (cs) => cs.columnCount, "2");
check("orphans", (v) => { d.style.orphans = v; }, () => d.style.orphans, (cs) => cs.orphans, "3");
check("breakInside", (v) => { d.style.breakInside = v; }, () => d.style.breakInside, (cs) => cs.breakInside, "avoid");
check("textAlignLast", (v) => { d.style.textAlignLast = v; }, () => d.style.textAlignLast, (cs) => cs.textAlignLast, "center");
check("printColorAdjust", (v) => { d.style.printColorAdjust = v; }, () => d.style.printColorAdjust, (cs) => cs.printColorAdjust, "exact");
check("textOrientation", (v) => { d.style.textOrientation = v; }, () => d.style.textOrientation, (cs) => cs.textOrientation, "mixed");
// The declaration writes the CSS name, not the camelCase one.
log("serialised " + d.style.cssText.includes("animation-play-state") + " " + d.style.cssText.includes("animationPlayState"));
log("done");
`;

const EXPECTED = [
  "transitionProperty opacity|opacity",
  "transitionDuration 0.3s|0.3s",
  "animationName spin|spin",
  "animationPlayState paused|paused",
  "columnCount 2|2",
  "orphans 3|3",
  "breakInside avoid|avoid",
  "textAlignLast center|center",
  "printColorAdjust exact|exact",
  "textOrientation mixed|mixed",
  "serialised true false",
  "done",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-css-accessors-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: "frame 1" };
delete env.NATIVE_SNAPSHOT;
const r = spawnSync(exe, [], { encoding: "utf8", env });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const got = r.stdout.split("\n").slice(0, -1);
for (const line of got) console.log(`     got ${JSON.stringify(line)}`);
check(`log lines (${EXPECTED.length})`, got.length === EXPECTED.length, `got ${got.length}`);
for (let i = 0; i < Math.min(got.length, EXPECTED.length); i++) {
  check(EXPECTED[i], got[i] === EXPECTED[i], `got ${JSON.stringify(got[i])}`);
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
