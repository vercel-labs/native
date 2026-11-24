// A package's internal "#" imports and its modules' declarations. The build copies a package's
// modules into the build dir and the declarations TypeScript reads beside them: a "#" specifier
// resolves through the package's imports map (an exact key, a conditional entry with a `types`
// target, or a pattern), and the declaration beside the JavaScript that resolved wins over the
// package's root declaration.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta charset="utf-8"><title>Imports</title></head>
<body><div id="root"></div><script type="module" src="app.ts"></script></body></html>`;

// Every module reads a value through a "#" import: the dev stub has a declaration beside it, the
// config's declaration lives in a `types` condition (no sibling), and the feature module is
// reached through an imports-map pattern.
const APP = `
import { definePrimitive } from "ui-core";
import { edge, marker } from "edge-pkg";
const el = document.createElement("div");
el.textContent = definePrimitive().textContent + " " + marker;
document.getElementById("root")!.appendChild(el);
console.log("OUT " + el.textContent + " " + edge().id);
`;

const UI_CORE = {
  "package.json": JSON.stringify({
    name: "ui-core",
    version: "1.0.0",
    type: "module",
    imports: {
      "#dev": "./dist/foundation/kernel/dev-stub.js",
      "#config": { types: "./types/config.d.ts", import: "./dist/config.js" },
      "#features/*": "./dist/features/*.js",
    },
    exports: { ".": { types: "./dist/index.d.ts", import: "./dist/index.js" } },
  }),
  "dist/index.js": `export { definePrimitive } from "./primitive.js";\n`,
  // The package root names only its entry: a "#" import is not the entry, so reading this barrel
  // for dev-stub.js finds no `dev`.
  "dist/index.d.ts": `export declare function definePrimitive(): HTMLElement;\n`,
  "dist/primitive.js": `
import { dev } from "#dev";
import { config } from "#config";
import { one } from "#features/one";
export function definePrimitive() {
  const el = document.createElement("div");
  el.textContent = dev.name + " " + config.mode + " " + one;
  return el;
}
`,
  "dist/primitive.d.ts": `export declare function definePrimitive(): HTMLElement;\n`,
  "dist/foundation/kernel/dev-stub.js": `export const dev = { name: "stub" };\n`,
  "dist/foundation/kernel/dev-stub.d.ts": `export declare const dev: { name: string };\n`,
  "dist/config.js": `export const config = { mode: "native" };\n`,
  "types/config.d.ts": `export declare const config: { mode: string };\n`,
  "dist/features/one.js": `export const one = "one";\n`,
  "dist/features/one.d.ts": `export declare const one: string;\n`,
};

// A bare package whose exports map names one declaration but whose JavaScript has another beside
// it: the sibling describes the module that was copied.
const EDGE_PKG = {
  "package.json": JSON.stringify({
    name: "edge-pkg", version: "1.0.0", type: "module",
    exports: { ".": { types: "./dist/barrel.d.ts", import: "./dist/edge.js" } },
  }),
  "dist/edge.js": `
export const marker = "sibling";
export function edge() { const el = document.createElement("div"); el.id = "edge"; return el; }
`,
  "dist/edge.d.ts": `export declare const marker: "sibling";\nexport declare function edge(): HTMLElement;\n`,
  "dist/barrel.d.ts": `export declare const marker: "barrel";\nexport declare function edge(): HTMLElement;\n`,
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

const dir = mkdtempSync(join(tmpdir(), "native-imports-declarations-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), APP);
install(join(dir, "node_modules", "ui-core"), UI_CORE);
install(join(dir, "node_modules", "edge-pkg"), EDGE_PKG);

const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
check("the app builds", b.status === 0, b.stderr.slice(-800));

const deps = join(dir, ".native", "src", "deps");
const names = b.status === 0 ? readdirSync(deps) : [];
const declarationFor = (suffix: string): string => {
  const name = names.find((n) => n.endsWith(suffix));
  return name === undefined ? "" : readFileSync(join(deps, name), "utf8");
};
const dev = declarationFor("-dev-stub.d.ts");
check("a # import copies the declaration beside its module", dev.includes("export declare const dev"), dev);
check("the package root declaration is not used for it", !dev.includes("definePrimitive"), dev);
const config = declarationFor("-config.d.ts");
check("a # import's types condition is copied", config.includes("config: { mode: string }"), config);
const one = declarationFor("-one.d.ts");
check("a # import pattern finds its target's declaration", one.includes("export declare const one"), one);
const edge = declarationFor("-edge.d.ts");
check("a module's sibling declaration wins over the package root", edge.includes('marker: "sibling"'), edge);

if (b.status === 0) {
  const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame | frame" } });
  const out = r.stdout.split("\n").find((line) => line.startsWith("OUT ")) ?? "";
  check("the values arrive through the # imports", out === "OUT stub native one sibling edge", JSON.stringify(out));
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
