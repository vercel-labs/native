// A package may name its own modules with "#" specifiers through the `imports` map in its
// package.json ("#dev", "#lib/util"). Vendoring copies a package's files out of it, so a copy no
// longer sits inside the package the map belongs to: the build resolves each "#" specifier the
// way Node would from the file it came from, for the JavaScript copies and their declarations
// alike, and names the copy it lands in.
//   npm test

import { chmodSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";
import { build } from "../compiler/build.ts";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

function app(files: { [path: string]: string }): string {
  const dir = mkdtempSync(join(tmpdir(), "native-package-imports-"));
  for (const [path, text] of Object.entries(files)) {
    mkdirSync(dirname(join(dir, path)), { recursive: true });
    writeFileSync(join(dir, path), text);
  }
  return dir;
}

const dir = app({
  "index.html": `<!doctype html>
<html><head><meta charset="utf-8"><title>Imports</title></head>
<body><script type="module" src="app.ts"></script></body></html>`,
  "app.ts": `import { ok } from "pkg"\nconsole.log(ok)\n`,
  // The map's development branch is not a condition this build resolves, so the default one is
  // what a copy must reach, exactly as the app reaches it in a browser build.
  "node_modules/pkg/package.json": JSON.stringify({
    name: "pkg",
    version: "1.0.0",
    type: "module",
    exports: { ".": { types: "./index.d.ts", default: "./index.js" } },
    imports: {
      "#dev": { development: "./dev.js", default: "./dev-stub.js" },
      "#name-check": "./name-check.js",
      "#lib/*": "./lib/*.js",
    },
  }),
  "node_modules/pkg/index.js": `import { dev } from "#dev"\nimport { name } from "#name-check"\nimport { util } from "#lib/util"\nexport const ok = dev + name + util\n`,
  "node_modules/pkg/index.d.ts": `export { dev } from "#dev"\nexport { name } from "#name-check"\nexport declare const ok: string\n`,
  "node_modules/pkg/dev.js": `export const dev = "dev"\n`,
  "node_modules/pkg/dev-stub.js": `export const dev = "stub"\n`,
  "node_modules/pkg/dev-stub.d.ts": `export declare const dev: string\n`,
  "node_modules/pkg/name-check.js": `export const name = "name"\n`,
  "node_modules/pkg/name-check.d.ts": `export declare const name: string\n`,
  "node_modules/pkg/lib/util.js": `export const util = "util"\n`,
  "node_modules/pkg/lib/util.d.ts": `export declare const util: string\n`,
});

// The build copies the sources before it runs the compiler; a compiler that refuses the app
// afterward is expected here (this checkout may have none).
const stub = join(dir, "stub-scriptc");
writeFileSync(stub, "#!/bin/sh\nexit 1\n");
chmodSync(stub, 0o755);
const previous = process.env["NATIVE_SCRIPTC"];
process.env["NATIVE_SCRIPTC"] = stub;
try {
  await build(dir, join(dir, "out", "imports"));
} catch {
  // The stub compiler refuses; the copied tree is what this test reads.
} finally {
  if (previous === undefined) delete process.env["NATIVE_SCRIPTC"];
  else process.env["NATIVE_SCRIPTC"] = previous;
}

const deps = join(dir, ".native", "src", "deps");
const files = readdirSync(deps);
const left = files.filter((name) => /\.(?:m|c)?js|\.d\.[cm]?ts$/.test(name))
  .filter((name) => /"#(?:dev|name-check|lib)/.test(readFileSync(join(deps, name), "utf8")));
check("no copied file keeps a # specifier", left.length === 0, JSON.stringify(left));

const copyOf = (label: string, ext: string): string | null => {
  const hit = files.find((name) => new RegExp(`-${label}\\.${ext}$`).test(name));
  return hit === undefined ? null : hit;
};
const id = (name: string | null): string => (name === null ? "" : name.slice(0, name.indexOf("-")));

const indexJs = copyOf("index", "js");
const indexDts = copyOf("index", "d.ts");
check("the module is copied", indexJs !== null && indexDts !== null, JSON.stringify(files));
if (indexJs !== null && indexDts !== null) {
  const js = readFileSync(join(deps, indexJs), "utf8");
  const dts = readFileSync(join(deps, indexDts), "utf8");
  // The default condition names the stub, and both the module and its declaration point at the
  // same copy of it so TypeScript and the compiler see one module.
  const jsDev = /from\s+"\.\/([^"]+)"\n/.exec(js)?.[1] ?? "";
  const dtsDev = /from\s+"\.\/([^"]+)"/.exec(dts)?.[1] ?? "";
  check("the copy reaches the map's default branch", jsDev.includes("dev-stub"), jsDev);
  check("the declaration reaches the same copy", dtsDev.startsWith(jsDev.replace(/\.js$/, "")),
    `${dtsDev} vs ${jsDev}`);
  check("a pattern key resolves too", /from\s+"\.\/[^"]+util\.js"/.test(js), js);
  check("the development branch is not copied", !files.some((name) => /-dev\.js$/.test(name)),
    JSON.stringify(files));
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
