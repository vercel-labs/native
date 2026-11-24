// Builds the examples and drives them headlessly through NATIVE_STEPS, checking printed output.
//   npm test

import { spawnSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { basename, join } from "node:path";
import { tmpdir } from "node:os";
import { outputPaths } from "../compiler/build.ts";

const out = mkdtempSync(join(tmpdir(), "native-test-"));
let failed = 0;

/**
 * Builds an example from a copy, then moves the built app off on its own and deletes the copy:
 * what the checks run is a self-contained app, with none of the source's files left to read.
 */
function build(example: string): string {
  const src = join(out, `${example}-src`);
  cpSync(join("..", "..", "examples", example), src, {
    recursive: true,
    filter: (path) => !path.split("/").includes(".native") && !path.split("/").includes("node_modules"),
  });
  const target = join(out, `${example}-build`, example);
  const r = spawnSync("node", ["compiler/cli.ts", "build", src, "-o", target], { encoding: "utf8" });
  if (r.status !== 0) {
    console.error(r.stderr);
    throw new Error(`build of ${example} failed`);
  }
  const paths = outputPaths(target, true);
  const moved = join(out, `${example}-app`);
  mkdirSync(moved, { recursive: true });
  let exe: string;
  if (paths.bundle !== null) {
    const app = join(moved, basename(paths.bundle));
    cpSync(paths.bundle, app, { recursive: true });
    exe = join(app, "Contents", "MacOS", basename(target));
  } else {
    exe = join(moved, basename(paths.executable));
    cpSync(paths.executable, exe);
    if (existsSync(paths.resources)) {
      cpSync(paths.resources, join(moved, basename(paths.resources)), { recursive: true });
    }
  }
  rmSync(src, { recursive: true, force: true });
  rmSync(join(out, `${example}-build`), { recursive: true, force: true });
  return exe;
}

function check(name: string, exe: string, steps: string, expected: string[]): void {
  const r = spawnSync(exe, [], {
    encoding: "utf8",
    env: { ...process.env, NATIVE_STEPS: steps, NATIVE_SNAPSHOT: join(out, `${name.replace(/\W+/g, "-")}.png`) },
  });
  const got = r.stdout.split("\n").slice(0, -1);
  const ok = r.status === 0 && JSON.stringify(got) === JSON.stringify(expected);
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}`);
  if (!ok) console.log(`  expected ${JSON.stringify(expected)}\n  got      ${JSON.stringify(got)} (exit ${r.status})\n${r.stderr}`);
}

const counter = build("counter");
check("counter: clicks", counter, "click #inc | click #inc | click #dec | print #count | print #status", ["1", "3 clicks so far"]);
check("counter: reset", counter, "click #inc | click #reset | print #count", ["0"]);

const todo = build("todo");
check("input: typing and word deletion", todo, "type hello world | key Alt+Backspace | type there | print #new", ["hello there"]);
check("input: caret movement and selection", todo,
  "type hello there | key Meta+ArrowLeft | type > | key Alt+ArrowRight | key Alt+ArrowRight | key Shift+ArrowLeft | key Shift+ArrowLeft | type ! | print #new",
  [">hello the!"]);
check("input: select all", todo, "type abc | key SelectAll | type z | print #new", ["z"]);
check("todo: add, toggle, remove", todo,
  "type a | key Enter | type b | key Enter | type c | key Enter | print #left | click .item | print #left | click .remove | print #list",
  ["3 items left", "2 items left", "b×c×"]);
check("todo: clear completed", todo, "type a | key Enter | type b | key Enter | click .item | click #clear | print #list | print #left",
  ["b×", "1 item left"]);
check("todo: add button refocuses input", todo, "type x | click #add | type y | print #new | print #list", ["y", "x×"]);

const many = Array.from({ length: 12 }, (_, i) => `type item ${i + 1} | key Enter`).join(" | ");
check("scroll: new items scroll into view", todo, `${many} | scrolltop #list`, ["215"]);
check("scroll: wheel scrolls and clamps", todo, `${many} | wheel #list -100 | scrolltop #list | wheel #list -1000 | scrolltop #list | wheel #list 50 | scrolltop #list`,
  ["115", "0", "50"]);
check("scroll: survives restyle and relayout", todo, `${many} | hover .item | click .item | scrolltop #list`, ["215"]);
check("scroll: clicks hit scrolled content", todo, `${many} | wheel #list -1000 | click .remove | print #left`, ["11 items left"]);

const dashboard = build("dashboard");
check("dashboard: resend invite updates the button", dashboard, "click #resend | print #resend", ["Invite sent ✓"]);

const article = build("article");
check("inline: clicking a link's text targets the link", article, "click #link | print #status", ["Clicked the link (1 total)."]);
check("inline: atomic button inside a paragraph", article, "click #inline-btn | click #link | print #status", ["Clicked the link (2 total)."]);

// A page whose colour comes through a custom property on :root. A :root rule that lands on the
// doctype node instead of the document element never applies, and the text stays its initial
// black — which is how the doctype's arrival broke every :root rule on the page until mount learned
// to put the doctype beside the root.
const rootDir = mkdtempSync(join(tmpdir(), "native-smoke-root-"));
writeFileSync(join(rootDir, "index.html"), `<!doctype html>
<html><head><meta name="native-window" content="width=120, height=60"><style>
:root { --c: rgb(1, 2, 3); }
body { margin: 0; color: var(--c); }
</style></head><body><p id="p">text</p>
<script src="app.ts"></script>
</body></html>`);
writeFileSync(join(rootDir, "app.ts"), `const p = document.getElementById("p")!;
console.log("root color " + getComputedStyle(p).color);
`);
const rootExe = join(out, "root");
const rootBuild = spawnSync("node", ["compiler/cli.ts", "build", rootDir, "-o", rootExe], { encoding: "utf8" });
if (rootBuild.status !== 0) throw new Error(`build of the :root page failed\n${rootBuild.stderr}`);
{
  const r = spawnSync(rootExe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame 1" } });
  const got = r.stdout.trim();
  const want = "root color rgb(1, 2, 3)";
  const ok = r.status === 0 && got === want;
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} :root custom property reaches the page`);
  if (!ok) console.log(`  expected ${JSON.stringify(want)}\n  got      ${JSON.stringify(got)} (exit ${r.status})\n${r.stderr}`);
}
// A TypeScript page script must typecheck against the DOM as lib.dom declares it: in particular
// document.body is an HTMLElement, so `document.body.appendChild(...)` builds. A null-typed body
// broke every TS app that writes that, so the landing smoke checks it here.
function typedScript(): string {
  const dir = mkdtempSync(join(tmpdir(), "native-typed-"));
  writeFileSync(join(dir, "index.html"),
    `<!doctype html>
<html><head><meta name="native-window" content="width=200, height=100"></head><body>
<script src="app.ts"></script>
</body></html>`);
  writeFileSync(join(dir, "app.ts"),
    `document.body.appendChild(document.createElement("p"));
document.querySelector("p")!.textContent = "ok";
console.log(document.querySelector("p")!.textContent);
`);
  const exe = join(out, "typed");
  const r = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
  if (r.status !== 0) {
    console.error(r.stderr);
    throw new Error("a typed page script that appends to document.body failed to build");
  }
  return exe;
}
check("typed script: document.body appends and querySelector reads back", typedScript(), "frame 1", ["ok"]);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
