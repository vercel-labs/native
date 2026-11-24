// A package's declarations name the DOM the way a browser's lib.dom.d.ts provides it:
// `HTMLElement`, `HTMLInputElement`, `Event`. The build type-checks those declarations, so the
// names have to resolve to the DOM Native SDK implements, not to a browser's and not to `any`.
// The generated dom-globals module is what binds them; a name the runtime doesn't implement
// stays undeclared, and a declaration that needs it fails with a missing-name diagnostic.
//   npm test

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import * as ts from "typescript";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=200, height=100"><style>
body { margin: 0; }
</style></head><body>
<div id="root"></div><script type="module" src="app.ts"></script>
</body></html>`;

// The app calls the package the way its declarations describe it. It also imports a framework's
// types, which declare the empty DOM interfaces a framework ships for projects without a DOM
// library (React's global.d.ts does this): the generated globals have to merge with them.
const APP = `
import type { Marker } from "framework";
import { card, input, on } from "dom-pkg";
const el = card();
console.log(el.isConnected);
const field = input();
field.value = "typed";
on((event) => console.log(event.type));
const marker: Marker | null = null;
console.log(marker);
document.getElementById("root")!.appendChild(el);
`;

const FRAMEWORK_TYPES = {
  "package.json": JSON.stringify({ name: "@types/framework", version: "1.0.0" }),
  "index.d.ts": `/// <reference path="./global.d.ts" />\nexport interface Marker { id: string }\n`,
  "global.d.ts": `interface HTMLElement {}\ninterface HTMLInputElement extends HTMLElement {}\n`,
};

// A package that ships declarations beside its JavaScript. Its declarations name browser globals,
// as the declarations of a UI package written for the DOM do.
const DOM_PKG = {
  "package.json": JSON.stringify({ name: "dom-pkg", type: "module", exports: { ".": { types: "./index.d.ts", import: "./index.js" } } }),
  "index.js": `
export function card() { return document.createElement("div"); }
export function input() { return document.createElement("input"); }
export function on(listener) { document.addEventListener("click", (event) => listener(event)); }
`,
  "index.d.ts": `
export declare function card(): HTMLElement;
export declare function input(): HTMLInputElement;
export declare function on(listener: (event: Event) => void): void;
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
    mkdirSync(dirname(p), { recursive: true });
    writeFileSync(p, text);
  }
}

/** What the TypeScript compiler reports for one file, compiled without a DOM library: the app's
 *  own type world has none, and Node's declarations only stand in for what a Node program has. */
function diagnostics(file: string): string[] {
  const program = ts.createProgram([file], {
    noEmit: true,
    skipLibCheck: true,
    strict: true,
    target: ts.ScriptTarget.ES2022,
    module: ts.ModuleKind.ESNext,
    moduleResolution: ts.ModuleResolutionKind.Bundler,
    lib: ["lib.es2022.d.ts"],
    // Node's declarations supply Event, console and process, as scriptc's do for a build.
    types: ["node"],
    typeRoots: [join(ROOT, "node_modules", "@types")],
    allowImportingTsExtensions: true,
  });
  return ts.getPreEmitDiagnostics(program)
    .filter((d) => d.file !== undefined && d.file.fileName === file)
    .map((d) => ts.flattenDiagnosticMessageText(d.messageText, " "));
}

const dir = mkdtempSync(join(tmpdir(), "native-vendored-dom-types-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), APP);
writeFileSync(join(dir, "tsconfig.json"), JSON.stringify({ compilerOptions: { strict: true } }));
install(join(dir, "node_modules", "dom-pkg"), DOM_PKG);
install(join(dir, "node_modules", "@types", "framework"), FRAMEWORK_TYPES);

const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
check("the app builds", b.status === 0, b.stderr.slice(-1200));

const build = join(dir, ".native");
const generated = join(build, "dom-globals.ts");
const source = existsSync(generated) ? readFileSync(generated, "utf8") : "";
// The DOM names resolve to the runtime's own classes and values, not to a browser library and
// not to `any`.
check("the build writes the DOM globals", source.includes("declare global"), source.slice(0, 400));
check("the global class is the runtime's class",
  source.includes("HTMLElement as HTMLElement$impl") && source.includes("/runtime/dom.ts"),
  source.split("\n").find((l) => l.includes("HTMLElement as")) ?? "");
check("the global names a value as well as a type",
  source.includes("interface HTMLElement extends HTMLElement$impl {}") && source.includes("var HTMLElement: typeof HTMLElement$impl;"),
  source.split("\n").filter((l) => l.includes("HTMLElement =") || l.includes("var HTMLElement")).join("\n"));
check("nothing is typed as any", !/:\s*any\b/.test(source), source);

// The declarations the build copied beside the module, checked without a DOM library: the app's
// own type world has none, so a DOM name has to come from the generated globals.
const appCopy = join(build, "src", "app.ts");
const importLine = existsSync(appCopy) ? /\bfrom\s+"(\.\/deps\/d\d+-index\.js)"/.exec(readFileSync(appCopy, "utf8")) : null;
const packageSpec = importLine === null ? null : importLine[1];
const declaration = packageSpec === null ? "" : join(build, "src", packageSpec.replace("./deps/", "deps/").replace(/\.js$/, ".d.ts"));
check("the package's declaration is copied beside its module", declaration !== "" && existsSync(declaration), `no declaration for ${packageSpec}`);
check("the copy keeps the DOM names the package declares",
  declaration !== "" && existsSync(declaration) && readFileSync(declaration, "utf8").includes("HTMLElement"),
  declaration !== "" && existsSync(declaration) ? readFileSync(declaration, "utf8") : "");

const probe = join(build, "src", "dom-probe.ts");
writeFileSync(probe, [
  // The framework's empty interfaces are in the program, as they would be in an app that uses it.
  `/// <reference path=${JSON.stringify(join(dir, "node_modules", "@types", "framework", "global.d.ts"))} />`,
  'import "../dom-globals.ts";',
  packageSpec === null ? "" : `import { card, input, on } from "${packageSpec}";`,
  "const el = card();",
  "console.log(el.isConnected);",
  "const field = input();",
  "field.value = \"typed\";",
  "on((event) => console.log(event.type));",
  "const list: NodeListOf<HTMLElement> = document.querySelectorAll(\"div\");",
  "console.log(list.length);",
  "",
].join("\n"));
const good = diagnostics(probe);
check("a vendored declaration types against the runtime's DOM", good.length === 0, JSON.stringify(good));

// The declared class is the runtime's real class, not `any`: a value of it isn't a number.
const wrong = join(build, "src", "dom-wrong.ts");
writeFileSync(wrong, 'import "../dom-globals.ts";\nconst n: number = document.createElement("div");\n');
const wrongDiag = diagnostics(wrong);
check("the global is a real type, not any", wrongDiag.some((d) => d.includes("not assignable to type 'number'")), JSON.stringify(wrongDiag));

// A name the runtime doesn't implement is a diagnostic at the place that uses it, not a crash
// and not a silent `any`.
const missing = join(build, "src", "dom-missing.ts");
writeFileSync(missing, 'import "../dom-globals.ts";\ndeclare const shape: SVGElement;\nconsole.log(shape);\n');
const missingDiag = diagnostics(missing);
check("an unimplemented DOM name is a diagnostic", missingDiag.some((d) => d.includes("Cannot find name 'SVGElement'")), JSON.stringify(missingDiag));

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
