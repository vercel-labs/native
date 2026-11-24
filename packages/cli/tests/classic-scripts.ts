// A page's classic scripts share one scope, as they share the global object in a browser: a
// function the first declares is callable from the second and from the body's onload handler, a
// var one leaves is the page's, and a const another declares is visible to the first too. A
// module script keeps its own declarations, even one named the same as a classic script's.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=200"><style>
body { margin: 0; font: 13px monospace; }
</style></head>
<body onload="onLoaded()">
<div id="out"></div>
<script>
var shared = "one";
function greet(who) { return "hi " + who; }
function onLoaded() { console.log("onload " + shared + " " + second + " " + greet("all")); }
window.onerror = function () { console.log("error event"); };
</script>
<script>
const second = "two";
console.log("second " + greet("there"));
throw new Error("boom");
</script>
<script>
console.log("after throw " + shared + " " + second);
</script>
<script>
var tag = "p";
const labelled = tag + "-one";
console.log("ordered " + labelled);
</script>
<script type="module">
const shared = "module";
console.log("module " + shared);
</script>
</body></html>`;

const EXPECTED = [
  // The second script calls the first script's function.
  "second hi there",
  // Its throw is reported to the window, and the script after it still runs.
  "error event",
  "after throw one two",
  // A const's initializer runs where it is written, after the statement that gives it its input.
  "ordered p-one",
  // The module script keeps its own `shared`.
  "module module",
  // The onload handler — attached in the scripts' scope — sees a var, a const and a function.
  "onload one two hi all",
];

// Two scripts of the page's own, both TypeScript and neither with an import of its own: the
// scope they share keeps the first's interface and var, and the second's function is callable
// from the body's onload handler.
const TS_LIB = `interface Item { name: string }
function label(item: Item): string { return "item " + item.name }
var fromLib = "lib";
`;

const TS_APP = `const item: Item = { name: "box" };
console.log("app " + label(item) + " " + fromLib);
function onLoaded(): void { console.log("loaded " + label(item)); }
`;

const TS_PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=200"><style>
body { margin: 0; font: 13px monospace; }
</style></head>
<body onload="onLoaded()">
<script src="lib.ts"></script>
<script src="app.ts"></script>
</body></html>`;

const TS_EXPECTED = [
  // The second script sees the first's function, its interface and the var it assigned.
  "app item box lib",
  "loaded item box",
];

// A classic script's bare `onload = …` and `onresize = …` are window handler properties, not
// implicit globals of the page's own; the handlers have to fire.
const HANDLER_PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=200"></head>
<body><script>
onload = function () { console.log("bare onload"); };
onresize = function () { console.log("bare onresize"); };
</script></body></html>`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

/** Builds a page directory and runs it one frame, checking its log lines. */
function run(name: string, files: Record<string, string>, expected: string[], stderrHas = "",
  steps: string = "frame 1"): void {
  const dir = mkdtempSync(join(tmpdir(), `native-classic-scripts-${name}-`));
  for (const [file, text] of Object.entries(files)) writeFileSync(join(dir, file), text);
  const exe = join(dir, "app");
  const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
  if (build.status !== 0) throw new Error(`${name}: build failed\n${build.stderr}`);
  const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: steps };
  delete env.NATIVE_SNAPSHOT;
  const r = spawnSync(exe, [], { encoding: "utf8", env });
  if (r.status !== 0) throw new Error(`${name}: render failed\n${r.stderr}`);
  const got = r.stdout.split("\n").slice(0, -1);
  for (const line of got) console.log(`     got ${JSON.stringify(line)}`);
  if (stderrHas !== "") check(`${name}: the throw reaches the console`, r.stderr.includes(stderrHas), JSON.stringify(r.stderr));
  check(`${name}: log lines (${expected.length})`, got.length === expected.length, `got ${got.length}`);
  for (let i = 0; i < Math.min(got.length, expected.length); i++) {
    check(`${name}: ${expected[i]}`, got[i] === expected[i], `got ${JSON.stringify(got[i])}`);
  }
}

run("inline", { "index.html": PAGE }, EXPECTED, "Uncaught boom");
run("typescript", { "index.html": TS_PAGE, "lib.ts": TS_LIB, "app.ts": TS_APP }, TS_EXPECTED);

run("bare-handlers", { "index.html": HANDLER_PAGE }, ["bare onload", "bare onresize"], "",
  "resize 200 150 | frame 1");

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
