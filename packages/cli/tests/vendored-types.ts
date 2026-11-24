// A package ships its JavaScript with declaration files beside it, and another leaves its
// declarations to an `@types` package. The build copies a package's modules into the build dir,
// and copies the declarations TypeScript reads for each beside them: the package's own exports-map
// `types` entry, a sibling file, or the `@types` package installed for it. Checking the app against
// the shipped JavaScript instead infers every destructured prop of a component as required.
//   npm test

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import * as ts from "typescript";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=200, height=100"><style>
body { margin: 0; }
</style></head><body>
<div id="root"></div><script type="module" src="app.tsx"></script>
</body></html>`;

// The app names both packages the way an app does. Its call passes every prop the shipped
// JavaScript would infer, so the build type-checks either way; the declarations say more.
const APP = `
import { card } from "props-pkg";
import { label } from "hooks-pkg";
const el = card({ title: label(), className: "box", children: null });
document.getElementById("root")!.appendChild(el);
console.log(el.textContent);
`;

// A package with no declarations beside its JavaScript: its exports map names them elsewhere, and
// the entry declaration names a type from a file that has no code of its own.
const PROPS_PKG = {
  "package.json": JSON.stringify({ name: "props-pkg", type: "module", exports: { ".": { types: "./dist/index.d.ts", import: "./dist/index.js" } } }),
  "dist/index.js": `
export function card({ title, className, children }) {
  const el = document.createElement("div");
  el.className = className ?? "";
  el.textContent = title ?? "";
  if (children) el.append(children);
  return el;
}
`,
  "dist/index.d.ts": `
import type { CardProps } from "./props.js";
export declare function card(props: CardProps): HTMLElement;
`,
  "dist/props.d.ts": `
export interface CardProps {
  title?: string;
  className?: string;
  children?: unknown;
}
`,
};

// A package whose declarations live in the `@types` package installed for it.
const HOOKS_PKG = {
  "package.json": JSON.stringify({ name: "hooks-pkg", type: "module", exports: "./hook.js" }),
  "hook.js": `export function label() { return "hooked"; }\n`,
};

const HOOKS_TYPES = {
  "package.json": JSON.stringify({ name: "@types/hooks-pkg", version: "1.0.0", types: "index.d.ts" }),
  // A declaration may also name a file it needs by path, as DefinitelyTyped packages do.
  "index.d.ts": `/// <reference path="./globals.d.ts" />\nexport declare function label(): string;\n`,
  "globals.d.ts": `interface HooksGlobal { seen: boolean }\n`,
};

// The JSX runtime and its types, as tests/jsx-types.ts installs them.
const TINY_JSX = {
  "package.json": JSON.stringify({ name: "tiny-jsx", type: "module", exports: { "./jsx-runtime": "./jsx-runtime.js" } }),
  "jsx-runtime.js": `
export const Fragment = "Fragment";
export function jsx(type, props) { return { type, props: props ?? {} }; }
export const jsxs = jsx;
`,
};

const TINY_JSX_TYPES = {
  "package.json": JSON.stringify({ name: "@types/tiny-jsx", version: "1.0.0" }),
  "jsx-runtime.d.ts": `
export namespace JSX {
  interface Element { type: string; props: { [name: string]: unknown }; }
  interface IntrinsicElements { div: { id?: string; children?: unknown }; span: { children?: unknown } }
}
export function jsx(type: string | ((props: any) => JSX.Element), props: { [name: string]: unknown }): JSX.Element;
export function jsxs(type: string | ((props: any) => JSX.Element), props: { [name: string]: unknown }): JSX.Element;
export const Fragment: string;
`,
};

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

function install(dir: string, files: { [path: string]: string }): void {
  for (const [path, text] of Object.entries(files)) {
    const p = join(dir, path);
    mkdirSync(join(p, ".."), { recursive: true });
    writeFileSync(p, text);
  }
}

/** The specifier an app file imports the copy of `file` by: the copy is `dN-<name>`, and the
 *  package's own module name says which. */
function copyOf(app: string, file: string): string | null {
  const m = new RegExp(`from\\s+"(\\./deps/d\\d+-${file}\\.js)"`).exec(app);
  return m === null ? null : m[1];
}

/** What the TypeScript compiler reports for one file, compiled against the build with the app's
 *  own settings. */
function diagnostics(file: string, options: ts.CompilerOptions): string[] {
  const program = ts.createProgram([file], { noEmit: true, skipLibCheck: true, ...options });
  return ts.getPreEmitDiagnostics(program)
    .filter((d) => d.file !== undefined && d.file.fileName === file)
    .map((d) => ts.flattenDiagnosticMessageText(d.messageText, " "));
}

const dir = mkdtempSync(join(tmpdir(), "native-vendored-types-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.tsx"), APP);
writeFileSync(join(dir, "tsconfig.json"), JSON.stringify({ compilerOptions: { jsx: "react-jsx", jsxImportSource: "tiny-jsx", strict: true } }));
install(join(dir, "node_modules", "props-pkg"), PROPS_PKG);
install(join(dir, "node_modules", "hooks-pkg"), HOOKS_PKG);
install(join(dir, "node_modules", "@types", "hooks-pkg"), HOOKS_TYPES);
install(join(dir, "node_modules", "tiny-jsx"), TINY_JSX);
install(join(dir, "node_modules", "@types", "tiny-jsx"), TINY_JSX_TYPES);

const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
check("the app builds", b.status === 0, b.stderr.slice(-800));

const build = join(dir, ".native");
const app = readFileSync(join(build, "src", "app.tsx"), "utf8");
const propsSpec = copyOf(app, "index");
const hooksSpec = copyOf(app, "hook");
check("the app imports copies of both packages", propsSpec !== null && hooksSpec !== null, app);

if (propsSpec !== null && hooksSpec !== null) {
  const deps = join(build, "src", "deps");
  const copy = (spec: string): string => join(deps, spec.slice("./deps/".length));
  const beside = (p: string): string => p.replace(/\.js$/, ".d.ts");
  const propsCopy = copy(propsSpec);
  const hooksCopy = copy(hooksSpec);
  const files = readdirSync(deps).join(" ");

  // The package named its declarations in its exports map, so beside the module's copy is the only
  // place TypeScript looks.
  check("the exports-map declaration is copied beside its module", existsSync(beside(propsCopy)), files);
  const propsTypes = existsSync(beside(propsCopy)) ? readFileSync(beside(propsCopy), "utf8") : "";
  check("the copy keeps the package's declarations", propsTypes.includes("export declare function card(props: CardProps)"), propsTypes);
  // The entry declaration names a type from a file with no JavaScript of its own: that one is
  // copied too, and the import between them reaches the copy.
  const inner = /from\s+"\.\/(d\d+-props)\.js"/.exec(propsTypes)?.[1];
  const innerTypes = inner !== undefined && existsSync(join(deps, inner + ".d.ts")) ? readFileSync(join(deps, inner + ".d.ts"), "utf8") : "";
  check("a declaration the entry names is copied and its import repointed", innerTypes.includes("title?: string") && innerTypes.includes("className?: string"), propsTypes);
  check("the @types package's declaration is copied beside its module", existsSync(beside(hooksCopy)) && readFileSync(beside(hooksCopy), "utf8").includes("label(): string"), files);
  // A `/// <reference path>` names a file rather than a module, and the copy has to point at the
  // copy of that file.
  const hooksTypes = existsSync(beside(hooksCopy)) ? readFileSync(beside(hooksCopy), "utf8") : "";
  const referenced = /<reference\s+path="\.\/([^"]+)"/.exec(hooksTypes)?.[1];
  check("a reference path is repointed at the copied file", referenced !== undefined && existsSync(join(deps, referenced)), hooksTypes);

  // The copies are what TypeScript reads: a call the shipped JavaScript would accept is a type
  // error against the package's own declarations.
  const probe = join(build, "src", "probe.ts");
  writeFileSync(probe, `import { card } from ${JSON.stringify(propsSpec)};\ncard({ title: 1 });\n`);
  const options: ts.CompilerOptions = {
    strict: true,
    target: ts.ScriptTarget.ES2022,
    module: ts.ModuleKind.ESNext,
    moduleResolution: ts.ModuleResolutionKind.Bundler,
    lib: ["lib.es2022.d.ts", "lib.dom.d.ts"],
  };
  const got = diagnostics(probe, options);
  check("the copied declaration types the module", got.some((d) => d.includes("not assignable to type 'string'")), JSON.stringify(got));
  const kept = beside(propsCopy);
  const aside = kept + ".aside";
  renameSync(kept, aside);
  try {
    const bare = diagnostics(probe, options);
    check("without it TypeScript resolves no declaration for the copy", bare.some((d) => d.includes("Could not find a declaration file")), JSON.stringify(bare));
  } finally {
    renameSync(aside, kept);
    rmSync(probe, { force: true });
  }
}

// The app itself still runs, and the copies are the modules it loaded.
if (b.status === 0) {
  const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame | frame" } });
  const lines = r.stdout.split("\n");
  check("the app runs", r.status === 0 && lines[0] === "hooked", `${r.status} ${JSON.stringify(lines.slice(0, 2))} ${r.stderr.slice(-300)}`);
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
