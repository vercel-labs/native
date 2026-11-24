// JSX in an app's own sources: the automatic runtime through Preact (hooks, fragments, a
// component in another .tsx file) and the classic runtime's h() factory. Both apps are built by
// native and driven the way a person would, and both print what a step leaves on screen.
//   npm test

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

// The apps below use the Preact install the example already has, the way an app's own
// node_modules would resolve it.
const DEPS = "examples/preact-todo";
if (!existsSync(join(DEPS, "node_modules", "preact"))) {
  const r = spawnSync("npm", ["install", "--no-audit", "--no-fund"], { cwd: DEPS, encoding: "utf8" });
  if (r.status !== 0) {
    console.error(r.stderr);
    throw new Error(`npm install in ${DEPS} failed`);
  }
}

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

/** Writes a page and its sources into a fresh app dir, with the example's install beside it. */
function appDir(name: string, files: { [path: string]: string }): string {
  const dir = mkdtempSync(join(tmpdir(), `native-${name}-`));
  symlinkSync(join(process.cwd(), DEPS, "node_modules"), join(dir, "node_modules"), "dir");
  for (const [path, text] of Object.entries(files)) {
    mkdirSync(join(dir, path, ".."), { recursive: true });
    writeFileSync(join(dir, path), text);
  }
  return dir;
}

function build(dir: string, name: string): string {
  const exe = join(dir, name);
  const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
  if (b.status !== 0) {
    console.error(b.stderr);
    throw new Error(`build of ${dir} failed`);
  }
  return exe;
}

function drive(exe: string, steps: string): string[] {
  const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: steps } });
  if (r.status !== 0) {
    console.error(r.stderr);
    throw new Error(`render failed (exit ${r.status})`);
  }
  return r.stdout.split("\n").slice(0, -1);
}

const PAGE = (src: string) => `<!doctype html>
<html><head><meta name="native-window" content="width=320, height=200"></head>
<body><div id="root"></div><script type="module" src="${src}"></script></body></html>`;

// --- The automatic runtime: react-jsx with Preact -------------------------------------------

const auto = appDir("tsx-auto", {
  "index.html": PAGE("app.tsx"),
  "tsconfig.json": `{
  // A bundler's tsconfig, not this repo's.
  "compilerOptions": { "jsx": "react-jsx", "jsxImportSource": "preact", "strict": true },
}
`,
  "counter.tsx": `
import { useState } from "preact/hooks";

export function Counter(props: { id: string; label: string }) {
  const [n, setN] = useState(0);
  return (
    <div>
      <button id={props.id} onClick={() => setN(n + 1)}>{props.label}</button>
      <p id={props.id + "-out"}>count: {n}</p>
    </div>
  );
}
`,
  "app.tsx": `
import { render } from "preact";
import { Counter } from "./counter";

function App() {
  return (
    <>
      <Counter id="b1" label="one" />
      <Counter id="b2" label="two" />
    </>
  );
}

render(<App />, document.getElementById("root")!);
`,
});

const autoExe = build(auto, "auto");
const AUTO_STEPS = [
  "frame 0",
  "print #b1-out", "print #b2-out",
  "click #b1", "click #b1",
  "print #b1-out", "print #b2-out",
  "click #b2",
  "print #b1-out", "print #b2-out",
].join(" | ");
const AUTO_WANT = [
  "count: 0", "count: 0",
  "count: 2", "count: 0",
  "count: 2", "count: 1",
];
const autoGot = drive(autoExe, AUTO_STEPS);
check(`automatic runtime (${AUTO_WANT.length} lines)`, JSON.stringify(autoGot) === JSON.stringify(AUTO_WANT), `got ${JSON.stringify(autoGot)}`);

// --- The classic runtime: jsxFactory h ------------------------------------------------------

const classic = appDir("tsx-classic", {
  "index.html": PAGE("app.tsx"),
  "tsconfig.json": `{
  "compilerOptions": {
    "jsx": "react",
    "jsxFactory": "h",
    "jsxFragmentFactory": "Fragment",
    "strict": true,
  },
}
`,
  "app.tsx": `
import { Fragment, h, render } from "preact";

function Page(props: { title: string }) {
  return (
    <>
      <h1 id="title">{props.title}</h1>
      <p id="body">built by the classic runtime</p>
    </>
  );
}

render(<Page title="Classic" />, document.getElementById("root")!);
`,
});

const classicExe = build(classic, "classic");
const classicGot = drive(classicExe, "frame 0 | print #title | print #body");
const CLASSIC_WANT = ["Classic", "built by the classic runtime"];
check(`classic runtime (${CLASSIC_WANT.length} lines)`, JSON.stringify(classicGot) === JSON.stringify(CLASSIC_WANT), `got ${JSON.stringify(classicGot)}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
