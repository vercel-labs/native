// A development JSX runtime written in JavaScript may name fewer parameters
// than the JSX contract passes: the transform calls
// `jsxDEV(type, props, key, isStatic, source, self)`, while React 19.3's
// development runtime names the first four and ignores the rest. The build's
// JSX shim keeps the runtime's declared signature for that function, so a
// typed call passes all six; typed from the JavaScript alone, the call would
// be refused as passing too many arguments.
//   npm test
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { build } from "../compiler/build.ts";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

function app(files: { [path: string]: string }): string {
  const dir = mkdtempSync(join(tmpdir(), "native-jsxdev-types-"));
  for (const [path, text] of Object.entries(files)) {
    mkdirSync(dirname(join(dir, path)), { recursive: true });
    writeFileSync(join(dir, path), text);
  }
  return dir;
}

const dir = app({
  "index.html": `<!doctype html>
<html><head><meta charset="utf-8"><title>JSX</title></head>
<body><div id="root"></div><script type="module" src="app.tsx"></script></body></html>`,
  "tsconfig.json": JSON.stringify({
    compilerOptions: { jsx: "react-jsxdev", jsxImportSource: "pkg", strict: true },
  }),
  "app.tsx": `function View() {\n  return <p title="t">hi</p>;\n}\nconsole.log(View());\n`,
  "node_modules/pkg/package.json": JSON.stringify({
    name: "pkg",
    version: "1.0.0",
    type: "module",
    main: "index.js",
    types: "index.d.ts",
  }),
  "node_modules/pkg/index.js": `export * from "./jsx-dev-runtime.js"\n`,
  "node_modules/pkg/index.d.ts": `export * from "./jsx-dev-runtime.js"\n`,
  // The JavaScript names four of the contract's six arguments.
  "node_modules/pkg/jsx-dev-runtime.js":
    `export const Fragment = "#fragment"\n` +
    `export function jsxDEV(type, props, key, isStatic) { return String(type) }\n`,
  "node_modules/pkg/jsx-dev-runtime.d.ts":
    `export declare const Fragment: string\n` +
    `export declare function jsxDEV(\n  type: unknown,\n  props: unknown,\n  key: unknown,\n  isStatic: boolean,\n  source?: { fileName: string; lineNumber: number; columnNumber: number },\n  self?: unknown,\n): string\n` +
    `export declare namespace JSX {\n  type Element = string\n  interface IntrinsicElements {\n    [name: string]: object\n  }\n}\n`,
});

const stub = join(dir, "stub-scriptc");
writeFileSync(stub, "#!/bin/sh\nexit 1\n");
chmodSync(stub, 0o755);
const previous = process.env.NATIVE_SCRIPTC;
process.env.NATIVE_SCRIPTC = stub;
try {
  await build(dir, join(dir, "out", "jsx"));
} catch {
  // The stub compiler refuses; the generated shim is what this test reads.
} finally {
  if (previous === undefined) delete process.env.NATIVE_SCRIPTC;
  else process.env.NATIVE_SCRIPTC = previous;
}

const shim = join(dir, ".native", "src", "native-jsx", "jsx-dev-runtime.ts");
const text = readFileSync(shim, "utf8");
check(
  "the shim names the runtime's declared jsxDEV",
  /import type \{ jsxDEV as _jsxDEVDeclared \}/.test(text),
  text,
);
check(
  "the exported jsxDEV wraps the runtime with the declared signature",
  /export function jsxDEV\(/.test(text) &&
    /p3: Parameters<typeof _jsxDEVDeclared>\[3\],/.test(text) &&
    /p5\?: Parameters<typeof _jsxDEVDeclared>\[5\],/.test(text) &&
    /return \(_jsxDEV as any\)\(p0, p1, p2, p3, p4, p5\);/.test(text),
  text,
);
check(
  "the JSX namespace still comes from the declarations",
  /export type \{ JSX \}/.test(text),
  text,
);
// A production runtime: `key` is optional, so the wrapper keeps it optional
// and a two-argument jsx call still type-checks.
const prod = app({
  "index.html": `<!doctype html>
<html><head><meta charset="utf-8"><title>JSX</title></head>
<body><div id="root"></div><script type="module" src="app.tsx"></script></body></html>`,
  "tsconfig.json": JSON.stringify({
    compilerOptions: { jsx: "react-jsx", jsxImportSource: "prod", strict: true },
  }),
  "app.tsx": `function View() {\n  return <p>hi</p>;\n}\nconsole.log(View());\n`,
  "node_modules/prod/package.json": JSON.stringify({
    name: "prod",
    version: "1.0.0",
    type: "module",
    main: "index.js",
    types: "index.d.ts",
  }),
  "node_modules/prod/index.js": `export * from "./jsx-runtime.js"\n`,
  "node_modules/prod/index.d.ts": `export * from "./jsx-runtime.js"\n`,
  "node_modules/prod/jsx-runtime.js":
    `export const Fragment = "#fragment"\n` +
    `export function jsx(type, props, key) { return String(type) }\n` +
    `export function jsxs(type, props, key) { return String(type) }\n`,
  "node_modules/prod/jsx-runtime.d.ts":
    `export declare const Fragment: string\n` +
    `export declare function jsx(type: unknown, props: unknown, key?: unknown): string\n` +
    `export declare function jsxs(type: unknown, props: unknown, key?: unknown): string\n` +
    `export declare namespace JSX {\n  type Element = string\n  interface IntrinsicElements {\n    [name: string]: object\n  }\n}\n`,
});
process.env.NATIVE_SCRIPTC = stub;
try {
  await build(prod, join(prod, "out", "jsx"));
} catch {
  // The stub compiler refuses; the generated shim is what this test reads.
} finally {
  if (previous === undefined) delete process.env.NATIVE_SCRIPTC;
  else process.env.NATIVE_SCRIPTC = previous;
}
const prodShim = readFileSync(join(prod, ".native", "src", "native-jsx", "jsx-runtime.ts"), "utf8");
check(
  "an optional declared parameter stays optional in the wrapper",
  /p2\?: Parameters<typeof _jsxDeclared>\[2\],/.test(prodShim),
  prodShim,
);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
