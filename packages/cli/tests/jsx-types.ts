// JSX types that live in a separate `@types` package, as React's do: the automatic runtime finds
// `@types/<pkg>/<subpath>.d.ts`, and the classic runtime finds `@types/<pkg>/index.d.ts`. Both
// apps are built by native and driven the way a person would.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

/** Writes a page and its sources into a fresh app dir, with the given files under its
 *  node_modules, the way a package and its `@types` declarations are installed. */
function appDir(name: string, files: { [path: string]: string }): string {
  const dir = mkdtempSync(join(tmpdir(), `native-${name}-`));
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
<body><div id="out"></div><script type="module" src="${src}"></script></body></html>`;

// --- The automatic runtime: types in @types/<pkg>/<subpath>.d.ts ---------------------------

const RUNTIME_JS = `
export const Fragment = "Fragment";
export function jsx(type, props) {
  return { type, props: props ?? {} };
}
export const jsxs = jsx;
`;

const auto = appDir("jsx-types-auto", {
  "index.html": PAGE("app.tsx"),
  "tsconfig.json": `{
  "compilerOptions": { "jsx": "react-jsx", "jsxImportSource": "tiny-jsx", "strict": true }
}
`,
  "app.tsx": `
const el = <div id="hi">hello</div>;
document.getElementById("out")!.textContent = (el.props as { id: string }).id;
`,
  "node_modules/tiny-jsx/package.json": `{
  "name": "tiny-jsx",
  "version": "1.0.0",
  "type": "module",
  "exports": { "./jsx-runtime": "./jsx-runtime.js" }
}
`,
  "node_modules/tiny-jsx/jsx-runtime.js": RUNTIME_JS,
  "node_modules/@types/tiny-jsx/package.json": `{
  "name": "@types/tiny-jsx",
  "version": "1.0.0"
}
`,
  "node_modules/@types/tiny-jsx/jsx-runtime.d.ts": `
export namespace JSX {
  interface Element {
    type: string;
    props: { [name: string]: unknown };
  }
  interface IntrinsicElements {
    div: { id?: string; children?: unknown };
  }
}
export function jsx(type: string, props: { [name: string]: unknown }): JSX.Element;
export function jsxs(type: string, props: { [name: string]: unknown }): JSX.Element;
export const Fragment: string;
`,
});

const autoExe = build(auto, "auto");
const autoGot = drive(autoExe, "frame 0 | print #out");
check("automatic runtime types from @types/<pkg>/jsx-runtime.d.ts", JSON.stringify(autoGot) === JSON.stringify(["hi"]), `got ${JSON.stringify(autoGot)}`);

// --- The classic runtime: types in @types/<pkg>/index.d.ts ---------------------------------

const classic = appDir("jsx-types-classic", {
  "index.html": PAGE("app.tsx"),
  "tsconfig.json": `{
  "compilerOptions": {
    "jsx": "react",
    "jsxFactory": "h",
    "jsxFragmentFactory": "Fragment",
    "strict": true
  }
}
`,
  "app.tsx": `
import { h } from "tiny-jsx";

const el = <div id="hi">hello</div>;
document.getElementById("out")!.textContent = (el.props as { id: string }).id;
`,
  "node_modules/tiny-jsx/package.json": `{
  "name": "tiny-jsx",
  "version": "1.0.0",
  "type": "module"
}
`,
  "node_modules/tiny-jsx/index.js": `
export const Fragment = "Fragment";
export function h(type, props, ...children) {
  return { type, props: props ?? {}, children };
}
`,
  "node_modules/@types/tiny-jsx/package.json": `{
  "name": "@types/tiny-jsx",
  "version": "1.0.0",
  "types": "index.d.ts"
}
`,
  "node_modules/@types/tiny-jsx/index.d.ts": `
export namespace JSX {
  interface Element {
    type: string;
    props: { [name: string]: unknown };
    children: unknown[];
  }
  interface ElementClass {
    render?: unknown;
  }
  interface ElementAttributesProperty {
    props: { [name: string]: unknown };
  }
  interface ElementChildrenAttribute {
    children: unknown[];
  }
  interface IntrinsicAttributes {}
  interface IntrinsicElements {
    div: { id?: string; children?: unknown };
  }
}
export function h(type: string, props: { [name: string]: unknown } | null, ...children: unknown[]): JSX.Element;
export const Fragment: string;
`,
});

const classicExe = build(classic, "classic");
const classicGot = drive(classicExe, "frame 0 | print #out");
check("classic runtime types from @types/<pkg>/index.d.ts", JSON.stringify(classicGot) === JSON.stringify(["hi"]), `got ${JSON.stringify(classicGot)}`);

// --- The automatic runtime as CommonJS: a runtime that assigns module.exports -----------------

const cjs = appDir("jsx-types-cjs", {
  "index.html": PAGE("app.tsx"),
  "tsconfig.json": `{
  "compilerOptions": { "jsx": "react-jsx", "jsxImportSource": "tiny-cjs", "strict": true }
}
`,
  "app.tsx": `
const el = <><div id="hi">hello</div></>;
const child = (el.props as { children: { props: { id: string } } }).children;
document.getElementById("out")!.textContent = child.props.id;
`,
  "node_modules/tiny-cjs/package.json": `{
  "name": "tiny-cjs",
  "version": "1.0.0",
  "main": "jsx-runtime.js",
  "exports": { "./jsx-runtime": "./jsx-runtime.js" }
}
`,
  "node_modules/tiny-cjs/jsx-runtime.js": `
const Fragment = "Fragment";
function jsx(type, props) { return { type: type, props: props ?? {} }; }
module.exports = { Fragment: Fragment, jsx: jsx, jsxs: jsx };
`,
  "node_modules/@types/tiny-cjs/package.json": `{
  "name": "@types/tiny-cjs",
  "version": "1.0.0"
}
`,
  "node_modules/@types/tiny-cjs/jsx-runtime.d.ts": `
export namespace JSX {
  interface Element {
    type: string;
    props: { [name: string]: unknown };
  }
  interface IntrinsicElements {
    div: { id?: string; children?: unknown };
  }
}
export function jsx(type: string, props: { [name: string]: unknown }): JSX.Element;
export function jsxs(type: string, props: { [name: string]: unknown }): JSX.Element;
export const Fragment: string;
`,
});

const cjsExe = build(cjs, "cjs");
const cjsGot = drive(cjsExe, "frame 0 | print #out");
check("automatic runtime from a CommonJS module", JSON.stringify(cjsGot) === JSON.stringify(["hi"]), `got ${JSON.stringify(cjsGot)}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
