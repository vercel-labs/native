// A release build's page tables, written into the app's bundle and mounted from there headlessly.
// The native host is replaced by a stub whose hostBundleDir names the directory the test writes,
// so this runs on any platform.
//
//   node tests/page-tables.ts

import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { registerHooks } from "node:module";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { pathToFileURL } from "node:url";
import { AssetBundle } from "../compiler/bundle.ts";

/** The host module's functions, as no-ops except the one that names the bundle. */
function stubHost(dir: string, bundle: string): string {
  const source = readFileSync(new URL("../runtime/host.ts", import.meta.url), "utf8");
  const names = [...source.matchAll(/export declare function (\w+)/g)].map((m) => m[1]);
  const file = join(dir, "host-stub.mjs");
  // Constants (modifier bits and the like) are copied as they are written.
  const consts = [...source.matchAll(/^export const (\w+) = ([^;\n]+);/gm)].map((m) => `export const ${m[1]} = ${m[2]};`);
  const lines = names.map((name) => name === "hostBundleDir"
    ? `export function hostBundleDir(receive) { receive(${JSON.stringify(bundle)}); }`
    : `export function ${name}() { return 0; }`);
  writeFileSync(file, [...lines, ...consts].join("\n"));
  return pathToFileURL(file).href;
}

const dir = mkdtempSync(join(tmpdir(), "native-page-"));
const appDir = join(dir, "app");
mkdirSync(appDir, { recursive: true });
// The bundle a release build makes: the executable's resources directory.
const bundle = join(appDir, "app.resources");
mkdirSync(bundle, { recursive: true });

const hostStub = stubHost(dir, bundle);
registerHooks({
  resolve(specifier, context, nextResolve) {
    const resolved = nextResolve(specifier, context) as { url: string };
    if (resolved.url.endsWith("/runtime/host.ts")) return { url: hostStub, shortCircuit: true };
    return resolved;
  },
});

const { compileApp } = await import("../compiler/compile.ts");
const { Diagnostics } = await import("../compiler/diagnostics.ts");
const { pageDataPath, writePageData } = await import("../compiler/build.ts");
const { document } = await import("../runtime/dom.ts");
const { mountPage } = await import("../runtime/app/page.ts");

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const page = `<!doctype html>
<html>
  <head><meta charset="utf-8"><title>Bundled</title><style>#box { color: rgb(1, 2, 3) }</style></head>
  <body>
    <div id="box" class="a"><h1 id="heading">Read from the bundle</h1></div>
    <input id="field" value="compiled">
  </body>
</html>`;

writeFileSync(join(appDir, "index.html"), page);
const diags = new Diagnostics();
const app = compileApp(join(appDir, "index.html"), diags, { bundle: new AssetBundle(appDir) });
check("the page compiles", diags.errorCount === 0, diags.format(false));
check("a bundled compile marks the tables bundled", app.tables.bundled === true);

// The build writes the tables into the bundle, as plain data.
writePageData(bundle, app);
const file = pageDataPath(bundle);
check("the tables are a file in the bundle", readFileSync(file, "utf8") === JSON.stringify(app.tables));

// The runtime mounts the page from that file, and from nothing else: no tables are handed to it.
mountPage();
const box = document.getElementById("box");
const heading = document.querySelector("h1");
check("the page mounts from the bundle's tables", box !== null && heading !== null);
check("the markup builds the text", heading !== null && heading.textContent === "Read from the bundle");
check("the title comes from the tables", document.title === "Bundled", document.title);
check("a class comes from the tables", box !== null && box.classList.value === "a", box === null ? "" : box.classList.value);
check("an attribute comes from the tables", (document.getElementById("field") as HTMLInputElement | null)?.value === "compiled");

// The file is the whole page: rewriting it is all a later build has to do.
const rewritten = JSON.stringify({ ...app.tables, title: "Rewritten" });
writeFileSync(file, rewritten);
check("the runtime reads the file the build writes", JSON.parse(readFileSync(file, "utf8")).title === "Rewritten");

process.exitCode = failed > 0 ? 1 : 0;
if (failed > 0) console.error(`${failed} check(s) failed`);
