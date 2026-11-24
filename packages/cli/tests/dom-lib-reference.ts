// A package whose type declarations ask for the browser's DOM library (`/// <reference
// lib="dom" />`) must not collide with the build's generated DOM globals: the browser library
// and dom-globals.ts would declare the same names twice ("Subsequent variable declarations must
// have the same type", and duplicate type aliases). The build leaves the DOM to that library when
// a copied declaration asks for it.
//   npm test

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const dir = mkdtempSync(join(tmpdir(), "native-dom-lib-"));
const app = join(dir, "app");
const pkg = join(app, "pkg");
mkdirSync(pkg, { recursive: true });

// A JSX runtime package whose declarations carry the browser DOM library reference, as preact's
// jsx.d.ts does.
writeFileSync(join(pkg, "package.json"), JSON.stringify({
  name: "dom-jsx-pkg",
  version: "1.0.0",
  type: "module",
  main: "./index.js",
  exports: {
    ".": "./index.js",
    "./jsx-runtime": { types: "./jsx-runtime.d.ts", import: "./jsx-runtime.js" },
  },
}));
writeFileSync(join(pkg, "index.js"), "export {};\n");
writeFileSync(join(pkg, "jsx-runtime.js"), `
export function jsx(type, props) { return { type, props }; }
export function jsxs(type, props) { return jsx(type, props); }
`);
writeFileSync(join(pkg, "jsx-runtime.d.ts"), `/// <reference lib="dom" />
export declare namespace JSX {
  type Element = any;
  interface IntrinsicElements {
    div: { className?: string; children?: any };
  }
}
export declare function jsx(type: any, props?: any, key?: any): any;
export declare function jsxs(type: any, props?: any, key?: any): any;
`);

writeFileSync(join(app, "package.json"), JSON.stringify({
  name: "dom-lib-app",
  private: true,
  type: "module",
  dependencies: { "dom-jsx-pkg": "file:./pkg" },
}));
writeFileSync(join(app, "tsconfig.json"), JSON.stringify({
  compilerOptions: { target: "ESNext", module: "ESNext", jsx: "react-jsx", jsxImportSource: "dom-jsx-pkg", strict: true },
}));
writeFileSync(join(app, "index.html"), `<!doctype html>
<html><head><meta charset="utf-8"><meta name="native-window" content="width=320, height=200"></head>
<body><div id="o">…</div><script type="module" src="app.tsx"></script></body></html>
`);
writeFileSync(join(app, "app.tsx"), `
const el = <div className="x">hi</div>;
document.getElementById("o")!.textContent = el.type + ":" + el.props.className;
`);

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const install = spawnSync("npm", ["install", "--no-audit", "--no-fund"], { cwd: app, encoding: "utf8" });
check("the app installs its JSX runtime", install.status === 0, install.stderr.slice(-400));

const exe = join(dir, "app-out");
const build = spawnSync("node", ["compiler/cli.ts", "build", app, "-o", exe], { encoding: "utf8" });
check("the app builds", build.status === 0, (build.stdout + build.stderr).slice(-800));
check("the browser DOM library and the generated globals don't collide",
  !/Subsequent variable declarations|Duplicate identifier/.test(build.stdout + build.stderr),
  (build.stdout + build.stderr).slice(-800));
check("no generated DOM globals were written", !existsSync(join(app, ".native", "dom-globals.ts")));

if (build.status === 0) {
  const run = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame 16 | print #o" } });
  check("the JSX runtime's module runs", run.status === 0, run.stderr.slice(-400));
  check("the element was built", run.stdout.trim() === "div:x", `got ${JSON.stringify(run.stdout.trim())}`);
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
