// compiler/resolve.ts against Node's own resolvers: for packages laid out the ways npm packages
// are (an "exports" map with conditions and patterns, "imports", a self-reference, a plain
// "main", a scoped package, a nested node_modules), each specifier must resolve to the file
// import.meta.resolve names for an import and require.resolve names for a require.

import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { resolveModule, type ResolveMode } from "../compiler/resolve.ts";

const root = realpathSync(mkdtempSync(join(tmpdir(), "native-resolve-")));
const files: { [path: string]: string } = {
  "app/package.json": JSON.stringify({ name: "app", imports: { "#util": "./src/util.js", "#dep/*": "dual/*", "#cond": { import: "./src/a.mjs", require: "./src/a.cjs" } }, exports: { ".": "./src/main.js", "./feature": "./src/feature.js" } }),
  "app/src/main.js": "",
  "app/src/util.js": "",
  "app/src/feature.js": "",
  "app/src/a.mjs": "",
  "app/src/a.cjs": "",
  "app/src/index.js": "",
  "app/src/lib/index.js": "",
  "app/src/data.json": "{}",
  "app/node_modules/dual/package.json": JSON.stringify({
    name: "dual",
    exports: {
      ".": { types: "./index.d.ts", import: "./esm/index.js", require: "./cjs/index.js" },
      "./sub": { node: { import: "./esm/sub.js", default: "./cjs/sub.js" } },
      "./features/*.js": "./esm/features/*.js",
      "./features/private/*": null,
      "./package.json": "./package.json",
      "./fallback": ["./missing-is-still-a-path.js", "./esm/index.js"],
    },
  }),
  "app/node_modules/dual/esm/index.js": "",
  "app/node_modules/dual/cjs/index.js": "",
  "app/node_modules/dual/esm/sub.js": "",
  "app/node_modules/dual/cjs/sub.js": "",
  "app/node_modules/dual/esm/features/x.js": "",
  "app/node_modules/dual/esm/x.js": "",
  "app/node_modules/plain/package.json": JSON.stringify({ name: "plain", main: "lib/entry" }),
  "app/node_modules/plain/lib/entry.js": "",
  "app/node_modules/plain/other.js": "",
  "app/node_modules/plain/dir/index.js": "",
  "app/node_modules/nomain/index.js": "",
  "app/node_modules/nomain/package.json": JSON.stringify({ name: "nomain" }),
  "app/node_modules/@scope/pkg/package.json": JSON.stringify({ name: "@scope/pkg", exports: "./main.mjs" }),
  "app/node_modules/@scope/pkg/main.mjs": "",
  "app/node_modules/sugar/package.json": JSON.stringify({ name: "sugar", exports: { import: "./i.mjs", default: "./d.cjs" } }),
  "app/node_modules/sugar/i.mjs": "",
  "app/node_modules/sugar/d.cjs": "",
  "app/node_modules/outer/package.json": JSON.stringify({ name: "outer", main: "index.js" }),
  "app/node_modules/outer/index.js": "",
  "app/node_modules/outer/node_modules/plain/package.json": JSON.stringify({ name: "plain", main: "nested.js" }),
  "app/node_modules/outer/node_modules/plain/nested.js": "",
};
for (const [path, text] of Object.entries(files)) {
  mkdirSync(dirname(join(root, path)), { recursive: true });
  writeFileSync(join(root, path), text);
}

const specs = [
  "dual", "dual/sub", "dual/features/x.js", "dual/features/private/y.js", "dual/package.json", "dual/esm/index.js",
  "dual/fallback", "dual/nope", "plain", "plain/other", "plain/other.js", "plain/dir", "nomain", "@scope/pkg",
  "sugar", "#util", "#dep/sub", "#cond", "#missing", "app", "app/feature", "./util.js", "./util", "./lib", "./data.json",
  "../src/main.js", "fs", "node:path", "events", "not-installed",
];
const parents = [join(root, "app/src/main.js"), join(root, "app/node_modules/outer/index.js")];

/** What Node answers for each specifier from `parent`: a path, null for a builtin or a failure. */
function nodeAnswers(parent: string, mode: ResolveMode): (string | null)[] {
  const probe = join(dirname(parent), `probe-${mode}.mjs`);
  writeFileSync(probe, [
    `import { createRequire, isBuiltin } from "node:module";`,
    `import { fileURLToPath } from "node:url";`,
    `const require = createRequire(${JSON.stringify(parent)});`,
    `const out = [];`,
    `for (const spec of ${JSON.stringify(specs)}) {`,
    `  try {`,
    `    if (isBuiltin(spec)) { out.push(null); continue; }`,
    mode === "import"
      ? `    out.push(fileURLToPath(import.meta.resolve(spec)));`
      : `    out.push(require.resolve(spec));`,
    `  } catch { out.push(null); }`,
    `}`,
    `console.log(JSON.stringify(out));`,
  ].join("\n"));
  const r = spawnSync(process.execPath, [probe], { encoding: "utf8" });
  if (r.status !== 0) throw new Error(r.stderr);
  return JSON.parse(r.stdout) as (string | null)[];
}

let failed = 0;
for (const parent of parents) {
  for (const mode of ["import", "require"] as const) {
    // import.meta.resolve answers relative to the probe, which sits beside the parent.
    const want = nodeAnswers(parent, mode);
    specs.forEach((spec, i) => {
      const got = resolveModule(spec, parent, mode);
      // Node names a resolved file by its real path; a missing file keeps the path it was given.
      const expected = want[i];
      const name = `${mode} ${JSON.stringify(spec)} from ${parent.slice(root.length + 1)}`;
      if (got === expected) {
        console.log(`ok   ${name} -> ${got === null ? "null" : got.slice(root.length + 1)}`);
      } else {
        failed++;
        console.log(`FAIL ${name}: got ${got}, Node resolves ${expected}`);
      }
    });
  }
}
void fileURLToPath;
if (failed > 0) {
  console.log(`${failed} failed`);
  process.exit(1);
}
console.log("all passed");
