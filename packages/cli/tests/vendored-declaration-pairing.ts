// A package compiled from JavaScript ships declarations beside it, and the build
// copies both. A declaration that names another module of the package and the
// module's own JavaScript copy must be numbered together: TypeScript resolves
// the declaration first, so a declaration whose runtime sibling landed under
// another name leaves the compiler nothing to bind the imported value to.
//   npm test
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { build } from "../compiler/build.ts";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

function app(files: { [path: string]: string }): string {
  const dir = mkdtempSync(join(tmpdir(), "native-vendor-pairing-"));
  for (const [path, text] of Object.entries(files)) {
    mkdirSync(dirname(join(dir, path)), { recursive: true });
    writeFileSync(join(dir, path), text);
  }
  return dir;
}

const dir = app({
  "index.html": `<!doctype html>
<html><head><meta charset="utf-8"><title>Pairing</title></head>
<body><div id="root"></div><script type="module" src="app.ts"></script></body></html>`,
  "app.ts": `import { use, hiddenAttrs } from "pkg"\nconsole.log(use(), hiddenAttrs(false, true))\n`,
  "node_modules/pkg/package.json": JSON.stringify({
    name: "pkg",
    version: "1.0.0",
    type: "module",
    main: "index.js",
    types: "index.d.ts",
  }),
  // The implementation graph: index.js re-exports panel.js.
  "node_modules/pkg/index.js": `export { hiddenAttrs } from "./panel.js"\nexport function use() { return hiddenAttrs(false, true) }\n`,
  "node_modules/pkg/index.d.ts": `export { hiddenAttrs } from "./panel.js"\nexport declare function use(): { hidden: string | undefined }\n`,
  "node_modules/pkg/panel.js": `export function hiddenAttrs(shown, findable) { return { hidden: shown ? undefined : findable ? "until-found" : "" } }\n`,
  "node_modules/pkg/panel.d.ts": `export declare function hiddenAttrs(shown: boolean, findable: boolean): { hidden: string | undefined }\n`,
});

// The build copies the sources before it runs the compiler; a compiler that
// refuses the app afterward is expected here (this checkout may have none).
const stub = join(dir, "stub-scriptc");
writeFileSync(stub, "#!/bin/sh\nexit 1\n");
chmodSync(stub, 0o755);
const previous = process.env.NATIVE_SCRIPTC;
process.env.NATIVE_SCRIPTC = stub;
try {
  build(dir, join(dir, "out", "pairing"));
} catch {
  // The stub compiler refuses; the copied tree is what this test reads.
} finally {
  if (previous === undefined) delete process.env.NATIVE_SCRIPTC;
  else process.env.NATIVE_SCRIPTC = previous;
}

const deps = join(dir, ".native", "src", "deps");
const panelFiles = readdirSync(deps).filter((name) => /-panel\.(?:d\.ts|js)$/.test(name));
const panelJs = panelFiles.filter((name) => name.endsWith(".js"));
const panelDts = panelFiles.filter((name) => name.endsWith(".d.ts"));
check("one JavaScript copy of the module", panelJs.length === 1, JSON.stringify(panelFiles));
check("one declaration copy of the module", panelDts.length === 1, JSON.stringify(panelFiles));
if (panelJs.length === 1 && panelDts.length === 1) {
  const id = (name: string): string => name.slice(0, name.indexOf("-"));
  check(
    "the declaration copy shares its module copy's number",
    id(panelJs[0]!) === id(panelDts[0]!),
    `${panelJs[0]} vs ${panelDts[0]}`,
  );
  // Every declaration that names the module reads the JavaScript copy's number.
  const references = readdirSync(deps)
    .filter((name) => name.endsWith(".d.ts"))
    .flatMap((name) =>
      [...readFileSync(join(deps, name), "utf8").matchAll(/(d\d+)-panel\.js/g)].map((m) => m[1]!),
    );
  check(
    "declarations that name the module point at its JavaScript copy",
    references.length > 0 && references.every((ref) => ref === id(panelJs[0]!)),
    JSON.stringify(references),
  );
}
console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
