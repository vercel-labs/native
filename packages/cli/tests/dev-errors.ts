// A dev build's runtime exception report: the stack names the build's copies of the app's
// modules, and the report names the files and lines the developer wrote.
//
//   node tests/dev-errors.ts

import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { registerHooks } from "node:module";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { pathToFileURL } from "node:url";

/** The host module's functions, as no-ops: reporting an exception needs none of them to work. */
function stubHost(dir: string): string {
  const source = readFileSync(new URL("../runtime/host.ts", import.meta.url), "utf8");
  const names = [...source.matchAll(/export declare function (\w+)/g)].map((m) => m[1]);
  const file = join(dir, "host-stub.mjs");
  const consts = [...source.matchAll(/^export const (\w+) = ([^;\n]+);/gm)].map((m) => `export const ${m[1]} = ${m[2]};`);
  writeFileSync(file, [...names.map((name) => `export function ${name}() { return 0; }`), ...consts].join("\n"));
  return pathToFileURL(file).href;
}

const dir = mkdtempSync(join(tmpdir(), "native-dev-errors-"));
const hostStub = stubHost(dir);
registerHooks({
  resolve(specifier, context, nextResolve) {
    const resolved = nextResolve(specifier, context) as { url: string };
    if (resolved.url.endsWith("/runtime/host.ts")) return { url: hostStub, shortCircuit: true };
    return resolved;
  },
});

const { compileApp } = await import("../compiler/compile.ts");
const { Diagnostics } = await import("../compiler/diagnostics.ts");
const { writeDevSources } = await import("../compiler/source-map.ts");
const { loadSourceMap, formatException } = await import("../runtime/app/source-map.ts");

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const appDir = join(dir, "app");
mkdirSync(join(appDir, "src"), { recursive: true });
const htmlPath = join(appDir, "index.html");
writeFileSync(join(appDir, "app.ts"), [
  "const count = document.getElementById(\"count\")!;",
  "",
  "function change(): void {",
  "  const missing = document.getElementById(\"nope\")!;",
  "  missing.textContent = \"x\";",
  "}",
  "",
  "document.getElementById(\"b\")!.addEventListener(\"click\", change);",
  "",
].join("\n"));
const html = [
  "<!doctype html>",
  "<html>",
  "  <head><title>Errors</title></head>",
  "  <body>",
  "    <div id=\"count\">0</div>",
  "    <button id=\"b\">press</button>",
  "    <script type=\"module\">",
  "      const inline = 1;",
  "      throw new Error(\"inline \" + inline);",
  "    </script>",
  "    <script type=\"module\" src=\"app.ts\"></script>",
  "  </body>",
  "</html>",
].join("\n");
writeFileSync(htmlPath, html);
const diags = new Diagnostics();
const app = compileApp(htmlPath, diags);
check("the page compiles", diags.errorCount === 0, diags.format(false));

const srcOut = join(appDir, ".native", "src");
mkdirSync(srcOut, { recursive: true });
writeFileSync(join(srcOut, "app.ts"), readFileSync(join(appDir, "app.ts")));
const inline = app.scripts.find((s) => s.path === null);
check("the inline module script is in the tables", inline !== undefined);
const inlineFile = join(srcOut, ".inline-0.js");
writeFileSync(inlineFile, inline!.text);
const file = writeDevSources({
  appDir,
  htmlPath,
  app,
  sdk: join(dir, "sdk"),
  srcOut,
  appFiles: [join(appDir, "app.ts")],
  vendored: new Map(),
  inlineFiles: [{ file: inlineFile, line: inline!.line }],
  classicBundle: null,
  handlerFile: null,
  firstClassicLine: 1,
  firstHandlerLine: 1,
});
check("the source table is written", loadSourceMap(file));
check("the table names the app's file", readFileSync(file, "utf8").includes(join(appDir, "app.ts")));

const error = new Error("Cannot read properties of null (reading 'textContent')");
error.name = "TypeError";
(error as { stack?: string }).stack = [
  "TypeError: Cannot read properties of null (reading 'textContent')",
  `    at change (${join(srcOut, "app.ts")}:5:11)`,
  `    at HTMLButtonElement.<anonymous> (${join(srcOut, "app.ts")}:8:46)`,
  `    at dispatch (${join(dir, "sdk", "runtime", "dom.ts")}:123:7)`,
].join("\n");
const report = formatException(error, "Uncaught");
check("the report names the app's file and line", report.includes(`at change (${join(appDir, "app.ts")}:5:11)`), report);
check("the second frame is mapped too", report.includes(`${join(appDir, "app.ts")}:8:46`), report);
check("the SDK's own frame is left out", !report.includes("runtime/dom.ts"), report);
check("the heading names the error", report.startsWith("Uncaught TypeError: Cannot read properties of null"), report);

const inlineError = new Error("inline 1");
(inlineError as { stack?: string }).stack = [
  "Error: inline 1",
  `    at ${join(inlineFile)}:2:13`,
].join("\n");
const inlineReport = formatException(inlineError, "Uncaught");
check("an inline script points into the page", inlineReport.includes(`${htmlPath}:${inline!.line + 1}:13`), inlineReport);

const stringReport = formatException("a string throw", "Uncaught");
check("a thrown string reports without a stack", stringReport === "Uncaught Error: a string throw", stringReport);

console.log(failed === 0 ? "all passed" : `${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
