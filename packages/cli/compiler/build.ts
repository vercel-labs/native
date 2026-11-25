// The build pipeline behind native: HTML/CSS/TS app -> native executable, plus the data a dev
// build reloads. Kept apart from cli.ts so the dev command uses the same steps as build.

import { declNames, hoistableDecl, identifiersOf, importPath, inPlaceNames, isJs, scriptStatements, splitVar, topLevelDeclarations, windowAliases, withDomImports, windowVarNames, implicitGlobals } from "./scripts.ts";
import { withoutSdkWarnings } from "./build-output.ts";
import { readFileSync, writeFileSync, copyFileSync, mkdirSync, mkdtempSync, existsSync, statSync, readdirSync, rmSync, symlinkSync, readlinkSync, renameSync, linkSync } from "node:fs";
import { dirname, join, relative, resolve, basename, extname } from "node:path";
import { spawn, spawnSync, type SpawnOptions } from "node:child_process";
import { availableParallelism, tmpdir, totalmem } from "node:os";
import { createRequire, registerHooks } from "node:module";
import { createHash } from "node:crypto";
import { fileURLToPath, pathToFileURL } from "node:url";
import { installedPackage, nodeModulesDirs } from "./installed.ts";
import { Diagnostics } from "./diagnostics.ts";
import { domGlobalsModule } from "./dom-globals.ts";
import { applyHostLink, buildTarget, buildingWindows, hostCommonCompileCommand, hostCompileCommand, hostCompositorCompileCommand, hostSources, hostSourceDigest, isCompositorBackend, prepareMetalShaders, windowsSqliteImportLibrary, MACOS } from "./native-host.ts";
import { compileApp, type CompiledApp, type HandlerAttribute, type ScriptFile } from "./compile.ts";
import { AssetBundle, copyBundle, publicDirOf, type BundleCopy, type BundleFile } from "./bundle.ts";
import { workerEntries } from "./worker-entries.ts";
import { TABLE_FIELDS } from "./fields.ts";
import { BuildCache, fastKey, programIdentity, programKey, programManifest, readBuildRecord, writeBuildRecord, writeManifest, type CacheEntry } from "./cache.ts";
import { PAGE_TABLES_DIR, PAGE_TABLES_FILE } from "../shared/page-tables.ts";
import { writeUpdateConfig } from "./updates.ts";
import { BuildProgress, parseTimingLine, type TimingEvent } from "./progress.ts";
import { appInfoOf, bundledInfo, type AppInfo } from "./app-info.ts";
import { packageMacApp } from "./package-macos.ts";
import { writeDevSources } from "./source-map.ts";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const RUNTIME = join(ROOT, "runtime");
const HOST = join(ROOT, "host");
export const color = process.stderr.isTTY ?? false;

/** A build error the caller reports; the dev command catches it and keeps watching. */
export function die(msg: string): never {
  throw new Error(`native: ${msg}`);
}

/**
 * The scriptc command. `node_modules/.bin/scriptc` is a symlink to the native compiler on Unix
 * and an npm shell shim on Windows, which a process cannot start directly; the compiler itself
 * lives at `scriptc/bin/scriptc.exe` once its install script has run, and in its platform package
 * when that script was skipped (npm's allowScripts gate, for instance).
 */
/** The size under which scriptc's executable is still the placeholder its package ships. */
const PLACEHOLDER_BYTES = 4096;

export function findScriptc(): string {
  // A path named outright wins: it is how a checkout of the compiler itself, or a build of it in a
  // directory of its own, is used without installing anything over the project.
  const chosen = process.env.NATIVE_SCRIPTC;
  if (chosen !== undefined && chosen !== "" && existsSync(chosen)) return chosen;
  // scriptc ships a placeholder script as its executable until its install script swaps the
  // release binary in, so a placeholder is passed over for the platform package's own binary.
  const scriptcDir = installedPackage(ROOT, "scriptc");
  const installed = scriptcDir === null ? null : join(scriptcDir, "bin", "scriptc.exe");
  if (installed !== null && existsSync(installed) && statSync(installed).size > PLACEHOLDER_BYTES) return installed;
  // The platform package sits beside scriptc: in its own node_modules under pnpm, and in the
  // nearest one above it, or above the CLI, when npm hoists it.
  const searched = [...(scriptcDir === null ? [] : nodeModulesDirs(scriptcDir)), ...nodeModulesDirs(ROOT)];
  for (const modules of searched) {
    const scoped = join(modules, "@scriptc");
    if (!existsSync(scoped)) continue;
    for (const name of readdirSync(scoped)) {
      if (!name.startsWith("cli-")) continue;
      for (const rel of [["dist", "bin", "scriptc.exe"], ["bin", "scriptc.exe"], ["dist", "bin", "scriptc"],
                         ["bin", "scriptc"]]) {
        const candidate = join(scoped, name, ...rel);
        if (existsSync(candidate)) return candidate;
      }
    }
  }
  if (installed !== null && existsSync(installed)) return installed;
  // npm's own shim: on Windows a .cmd beside the .exe a package's install script places, and it is
  // what a project that replaced the compiler (a checkout's own CLI, a build of main) ends up
  // with. The executable above is the published release, so the shim is only reached when that
  // is gone.
  for (const modules of nodeModulesDirs(ROOT)) {
    for (const name of ["scriptc.cmd", "scriptc"]) {
      const local = join(modules, ".bin", name);
      if (existsSync(local)) return local;
    }
  }
  return "scriptc";
}

/**
 * The heap scriptc's frontend gets, in megabytes: most of the machine's memory, up to the 8 GB a
 * large React app's program needs, and never less than Node's own default. The frontend is a
 * JavaScript program, so a component library's page can otherwise reach the default heap limit
 * before the compiler starts.
 */
export function scriptcHeapMb(totalBytes: number = totalmem()): number {
  return Math.max(2048, Math.min(8192, Math.floor((totalBytes / (1024 * 1024)) * 0.75)));
}

/** The environment a build gives scriptc: the caller's, with a heap sized for a large app unless
 *  the caller already chose one in NODE_OPTIONS. */
function scriptcEnv(): NodeJS.ProcessEnv {
  const options = process.env["NODE_OPTIONS"];
  if (options !== undefined && /--max-old-space-size/.test(options)) return process.env;
  const heap = `--max-old-space-size=${scriptcHeapMb()}`;
  return { ...process.env, NODE_OPTIONS: options === undefined || options.trim() === "" ? heap : `${options} ${heap}` };
}

/** Whether a resolved compiler is a batch shim, which only a shell can start. */
function isBatchShim(path: string): boolean {
  const lower = path.toLowerCase();
  return lower.endsWith(".cmd") || lower.endsWith(".bat");
}

/** One argument as a batch file's command line wants it: quoted, with quotes it carries escaped
 *  the way the C runtime parses them back. */
function batchQuote(arg: string): string {
  if (arg !== "" && !/[ "'\t]/.test(arg)) return arg;
  return '"' + arg.replace(/(\\*)"/g, '$1$1\\"') + '"';
}

/** A module specifier, either `from "x"`, `import "x"` or `import("x")`. */
const SPECIFIER = /(?:\bfrom\s*|\bimport\s*(?:\(\s*)?|\bexport\s*\*\s*from\s*)(["'])([^"'\n]+)\1/g;

/** A CommonJS `require("x")` specifier, which a vendored module outside this build names its
 *  dependencies with. `require.resolve` and other members aren't calls to require. */
const REQUIRED = /(?<![\w$.])require\s*\(\s*(["'])([^"'\n]+)\1\s*\)/g;

/** The extensions a vendored copy can hold. A require of anything else (a Node builtin, a native
 *  addon) is left where it stands for scriptc to report. */
const COPYABLE_EXTS = new Set([".js", ".jsx", ".mjs", ".cjs", ".ts", ".tsx", ".mts", ".json"]);

/** Copied dependencies: package source file -> its path in the build dir. */
interface Vendored {
  bySource: Map<string, string>;
  next: number;
  /** The specifier that first reached a copy, so a diagnostic can name what the app imported. */
  specs: Map<string, string>;
  /** The app dir, whose node_modules resolves a package's own bare imports. */
  appDir: string;
  /** True once a copy held JSX, which the build then needs a runtime and a tsconfig for. */
  jsx: boolean;
  /** Declaration file in the installed package -> its copy beside the module it describes. */
  declarations: Map<string, string>;
  /** The app's own script files that were copied, for a dev build's source table. */
  appFiles: string[];
}

/** App files copied into the build dir. A JSX file is a script like any other, but the build
 *  needs the app's JSX settings and a runtime for it. */
const APP_EXTS = [".ts", ".tsx", ".mts", ".js", ".jsx", ".mjs"];

/** Source extensions a bundler-style import may leave off; tried in this order. */
const SOURCE_EXTS = [".ts", ".tsx", ".mts", ".js", ".jsx", ".mjs", ".cjs"];

/** The source file a resolved path names, adding an extension or index file when the import
 *  left it off, as a bundler would. Packages written for bundlers omit the extension. */
function sourceFileFor(path: string): string | null {
  if (existsSync(path) && statSync(path).isFile()) return path;
  if (!SOURCE_EXTS.includes(extname(path))) {
    for (const ext of SOURCE_EXTS) {
      const candidate = path + ext;
      if (existsSync(candidate) && statSync(candidate).isFile()) return candidate;
    }
  }
  if (existsSync(path) && statSync(path).isDirectory()) {
    for (const ext of SOURCE_EXTS) {
      const index = join(path, "index" + ext);
      if (existsSync(index)) return index;
    }
  }
  return null;
}

const PROBE = "native-probe:";
/** The file a probe resolves from, set for the duration of one resolveSpecifier call. */
let probeParent: string | null = null;
const esmResolve = typeof registerHooks === "function";

// A package's "import" condition names the ESM build, which is the one an app's `import` runs;
// require() would find its CommonJS build instead, whose requires scriptc can't compile.
// import.meta.resolve only ever resolves from native's own file, so a resolve hook hands the
// loader the app file to resolve from.
if (esmResolve) {
  registerHooks({
    resolve(specifier, context, nextResolve) {
      if (probeParent !== null && specifier.startsWith(PROBE)) {
        return nextResolve(specifier.slice(PROBE.length), { ...context, parentURL: probeParent });
      }
      return nextResolve(specifier, context);
    },
  });
}

/** The file a specifier names, resolved as Node's ESM loader would from the importing file, so
 *  the app's own node_modules is searched (where its dependencies are installed). */
function resolveSpecifier(spec: string, fromFile: string, appDir: string): string | null {
  const from = (parent: string): string | null => {
    if (esmResolve) {
      probeParent = pathToFileURL(resolve(parent)).href;
      try {
        return sourceFileFor(fileURLToPath(import.meta.resolve(PROBE + spec)));
      } catch {
        return null; // a Node builtin, or a package that isn't installed
      } finally {
        probeParent = null;
      }
    }
    // Node before 22.15 has no synchronous resolve hook. A require made beside the file finds the
    // same node_modules, though with require's conditions (a package's CommonJS build).
    try {
      return sourceFileFor(createRequire(join(dirname(parent), "_.js")).resolve(spec));
    } catch {
      return null; // a Node builtin, or a package that isn't installed
    }
  };
  const hit = from(fromFile);
  if (hit !== null) return hit;
  // A package's own files name its sibling packages, which only the app's install has: a
  // workspace package has no node_modules of its own once installed from a registry.
  const bare = !spec.startsWith(".") && !spec.startsWith("/") && !/^[a-z][a-z0-9+.-]*:/i.test(spec);
  return bare ? from(join(appDir, "_.js")) : null;
}

/** The file a require() names, resolved as Node resolves one from the requiring file: a package
 *  through its "require" condition (the CommonJS build, which is what runs), a relative path
 *  through the extensions and index files require tries. A path Node won't resolve, but a bundler
 *  would have (an extensionless import of a .ts source), is tried as a source file. */
function resolveRequired(spec: string, fromFile: string, appDir: string): string | null {
  const from = (parent: string): string | null => {
    const dir = dirname(parent);
    try {
      return copyableFile(sourceFileFor(createRequire(join(dir, "_.js")).resolve(spec)) ?? "");
    } catch {
      // A Node builtin, an uninstalled package, or a resolution require's own rules won't take.
    }
    if (!spec.startsWith(".") && !spec.startsWith("/")) return null;
    return copyableFile(sourceFileFor(resolve(dir, spec)) ?? "");
  };
  const hit = from(fromFile);
  if (hit !== null) return hit;
  const bare = !spec.startsWith(".") && !spec.startsWith("/") && !/^[a-z][a-z0-9+.-]*:/i.test(spec);
  return bare ? from(join(appDir, "_.js")) : null;
}

/** The file itself when this build can copy it, null when it holds nothing to copy ("" included,
 *  which stands in for a resolution that found a name Node answers without a file). */
function copyableFile(path: string): string | null {
  return path !== "" && COPYABLE_EXTS.has(extname(path)) ? path : null;
}

/** True for a type-only import, whose specifier must keep resolving from node_modules. */
function typeOnly(text: string, offset: number): boolean {
  const head = text.slice(Math.max(0, offset - 200), offset);
  const cut = Math.max(head.lastIndexOf(";"), head.lastIndexOf("\n"), head.lastIndexOf("}"));
  const stmt = cut >= 0 ? head.slice(cut + 1) : head;
  return /\b(?:import|export)\s+type\b/.test(stmt) || /\{[^}]*\btype\b/.test(stmt);
}

/** Whether the nearest package.json above `dir` says "type": "module", as Node decides for a .js file. */
function isModulePackage(dir: string): boolean {
  for (let d = dir; ; d = dirname(d)) {
    const pkg = join(d, "package.json");
    if (existsSync(pkg)) {
      try {
        return (JSON.parse(readFileSync(pkg, "utf8")) as { type?: string }).type === "module";
      } catch {
        return false;
      }
    }
    if (dirname(d) === d) return false;
  }
}

/** The declaration file TypeScript reads for a JavaScript file: `x.js` -> `x.d.ts`,
 *  `x.mjs` -> `x.d.mts`, `x.cjs` -> `x.d.cts`, and `x.d.ts` where that's all a package ships. */
function declarationSibling(jsFile: string): string | null {
  const ext = extname(jsFile);
  const base = ext === "" ? jsFile : jsFile.slice(0, -ext.length);
  const candidates =
    ext === ".mjs" ? [base + ".d.mts", base + ".d.ts"] :
    ext === ".cjs" ? [base + ".d.cts", base + ".d.ts"] :
    ext === "" ? [base + ".d.ts", base + ".d.mts", base + ".d.cts"] :
    [base + ".d.ts"];
  for (const candidate of candidates) {
    if (existsSync(candidate) && statSync(candidate).isFile()) return candidate;
  }
  return null;
}

/** The declaration file a relative import names, resolved the way a declaration reads one:
 *  `./x.js` -> `x.d.ts`, `./x` -> `x.d.ts`, and a directory's `index.d.ts`. */
function resolveDeclaration(spec: string, fromFile: string): string | null {
  if (!spec.startsWith(".") && !spec.startsWith("/")) return null;
  const base = resolve(dirname(fromFile), spec);
  if (/\.d\.[cm]?ts$/.test(spec)) return existsSync(base) ? base : null;
  const sibling = declarationSibling(base);
  if (sibling !== null) return sibling;
  if (existsSync(base) && statSync(base).isDirectory()) {
    for (const ext of [".d.ts", ".d.mts", ".d.cts"]) {
      const index = join(base, "index" + ext);
      if (existsSync(index)) return index;
    }
  }
  return null;
}

/** The nearest package.json above a file, whose `imports` map names its `#` imports: a package's
 *  scope for Node need not name the package, so this doesn't ask for a name as packageAt does. */
function packageScope(file: string): { dir: string; data: any } | null {
  let dir = dirname(file);
  for (;;) {
    const pj = join(dir, "package.json");
    if (existsSync(pj)) {
      try {
        return { dir, data: JSON.parse(readFileSync(pj, "utf8")) };
      } catch {
        return null; // a package.json that doesn't parse describes nothing
      }
    }
    const up = dirname(dir);
    if (up === dir) return null;
    dir = up;
  }
}

/** The value an `imports` map gives a specifier: an exact key first, else the longest pattern
 *  whose `*` matches the middle of the specifier, with the match substituted into its target. */
function importsValue(map: any, spec: string): any {
  if (map === null || typeof map !== "object" || Array.isArray(map)) return undefined;
  if (spec.indexOf("*") < 0 && Object.prototype.hasOwnProperty.call(map, spec)) return map[spec];
  let best = "";
  for (const key of Object.keys(map)) {
    const star = key.indexOf("*");
    if (star < 0 || key.indexOf("*", star + 1) >= 0) continue;
    const prefix = key.slice(0, star), suffix = key.slice(star + 1);
    if (!spec.startsWith(prefix) || !spec.endsWith(suffix)) continue;
    if (spec.length < prefix.length + suffix.length) continue;
    if (prefix.length > (best === "" ? -1 : best.indexOf("*"))) best = key;
  }
  if (best === "") return undefined;
  const star = best.indexOf("*");
  const matched = spec.slice(star, spec.length - (best.length - star - 1));
  const swap = (value: any): any => {
    if (typeof value === "string") return value.split("*").join(matched);
    if (Array.isArray(value)) return value.map(swap);
    if (value !== null && typeof value === "object") {
      const out: any = {};
      for (const key of Object.keys(value)) out[key] = swap(value[key]);
      return out;
    }
    return value;
  };
  return swap(map[best]);
}

/** The declaration file an `imports` map target names: a `types` condition outright, or else the
 *  JavaScript target's sibling declaration. Targets are relative to the package's directory. */
function importsDeclarationTarget(value: any, dir: string): string | null {
  if (typeof value === "string") {
    if (!value.startsWith("./")) return null;
    const target = resolve(dir, value);
    if (/\.d\.[cm]?ts$/.test(target)) return existsSync(target) ? target : null;
    const sibling = declarationSibling(target);
    return sibling !== null && existsSync(sibling) ? sibling : null;
  }
  if (Array.isArray(value)) {
    for (const item of value) {
      const hit = importsDeclarationTarget(item, dir);
      if (hit !== null) return hit;
    }
    return null;
  }
  if (value !== null && typeof value === "object") {
    // `types` names the declaration; the other conditions name the JavaScript that runs, whose
    // sibling declares it. Node's object order decides between them, as it does for exports.
    for (const key of Object.keys(value)) {
      if (key !== "types" && key !== "node" && key !== "import" && key !== "default" && key !== "browser") continue;
      const hit = importsDeclarationTarget(value[key], dir);
      if (hit !== null) return hit;
    }
  }
  return null;
}

/** The declaration for a package-internal `#` import, through the owning package's imports map. */
function importsDeclaration(spec: string, fromFile: string): string | null {
  const scope = packageScope(fromFile);
  if (scope === null) return null;
  return importsDeclarationTarget(importsValue(scope.data.imports, spec), scope.dir);
}

/** The declaration file a specifier's import has, resolved as TypeScript resolves one: the
 *  package's exports-map `types` entry, its `types` field, the file beside the JavaScript the
 *  import resolved to, its root `index.d.ts`, or the `@types` package installed for it. */
function declarationFor(spec: string, jsFile: string, fromFile: string): string | null {
  if (spec.startsWith(".") || spec.startsWith("/")) {
    return declarationSibling(jsFile) ?? resolveDeclaration(spec, fromFile);
  }
  // A "#" specifier is the owning package's imports map, not a package name: resolving it as a
  // bare package would take the package's root declarations, which need not export the module.
  if (spec.startsWith("#")) {
    return importsDeclaration(spec, fromFile) ?? declarationSibling(jsFile);
  }
  // A declaration beside the JavaScript the import resolved to describes that module; it is the
  // file TypeScript reads before it considers what the package's root entry declares.
  const beside = declarationSibling(jsFile);
  if (beside !== null) return beside;
  const parts = spec.split("/");
  const scoped = spec.startsWith("@");
  const pkg = scoped ? parts.slice(0, 2).join("/") : parts[0];
  const subpath = scoped ? parts.slice(2).join("/") : parts.slice(1).join("/");
  // The specifier's own package: a package can hold a nested one (preact's jsx-runtime has its
  // own package.json), and the exports map that names the types is the outer package's. An alias
  // installed under another name falls back to the package that holds the file.
  const manifest = packageManifest(pkg, jsFile) ?? packageAt(jsFile);
  if (manifest !== null) {
    const { dir, data } = manifest;
    const exportsMap = data.exports;
    if (exportsMap !== null && typeof exportsMap === "object" && !Array.isArray(exportsMap)) {
      const hit = typesIn(exportsMap[subpath === "" ? "." : "./" + subpath], dir);
      if (hit !== null && existsSync(hit)) return hit;
    }
    // A package's `types` field names its root entry, not a subpath.
    if (subpath === "") {
      for (const field of ["types", "typings"]) {
        if (typeof data[field] === "string" && existsSync(join(dir, data[field]))) return join(dir, data[field]);
      }
    }
    if (subpath === "") {
      const index = join(dir, "index.d.ts");
      if (existsSync(index)) return index;
    }
  }
  const typesDir = typesPackageDir(pkg, fromFile);
  return typesDir === null ? null : typesPackageFile(typesDir, subpath);
}

/** The declaration file that belongs beside a module's copy: the name TypeScript reads for the
 *  copy's own kind, which the build's package.json makes ES modules (`.js`, `.mjs`) or CommonJS
 *  (`.cjs`). */
function declarationBeside(jsOut: string): string {
  if (jsOut.endsWith(".cjs")) return jsOut.slice(0, -4) + ".d.cts";
  if (jsOut.endsWith(".mjs")) return jsOut.slice(0, -4) + ".d.mts";
  return jsOut.replace(/\.jsx?$/, ".d.ts");
}

/** The name a declaration file takes when it is copied for another declaration to read: its own
 *  name, in the kind its package writes it as (a CommonJS package's `.d.ts` is `.d.cts` beside an
 *  ES module's). */
function declarationName(decl: string): string {
  if (/\.d\.(?:mts|cts)$/.test(decl)) return basename(decl);
  return isModulePackage(dirname(decl)) ? basename(decl) : basename(decl, ".ts") + ".cts";
}

/** The specifier by which a copied declaration imports another one: the JavaScript file that
 *  stands for the declaration, as TypeScript writes it (`x.d.ts` is `x.js`, `x.d.cts` `x.cjs`). */
function declarationSpecifier(fromFile: string, decl: string): string {
  let p = relative(dirname(fromFile), decl).split("\\").join("/");
  if (!p.startsWith(".")) p = "./" + p;
  return p.replace(/\.d\.mts$/, ".mjs").replace(/\.d\.cts$/, ".cjs").replace(/\.d\.ts$/, ".js");
}

/** The JavaScript file Node loads for a declaration, when the package ships one. */
function runtimeSiblingOfDeclaration(decl: string): string | null {
  const sibling = decl
    .replace(/\.d\.mts$/, ".mjs")
    .replace(/\.d\.cts$/, ".cjs")
    .replace(/\.d\.ts$/, ".js");
  return sibling !== decl && existsSync(sibling) ? sibling : null;
}

/** The declaration TypeScript reads for a JavaScript file, when the package ships one. */
function declarationSiblingOfRuntime(js: string): string | null {
  const suffix = js.endsWith(".mjs") ? "d.mts" : js.endsWith(".cjs") ? "d.cts" : "d.ts";
  const candidate = js.replace(/\.(?:mjs|cjs|js)$/, "." + suffix);
  return candidate !== js && existsSync(candidate) ? candidate : null;
}

/** A `/// <reference path="…" />` directive's target. */
const REFERENCE_PATH = /\/\/\/\s*<reference\s+path\s*=\s*(["'])([^"']+)\1/g;

/** Copies a declaration file to `out`, and through it the declarations it names, so a type the
 *  copy names is the same type through every path that reaches it. A relative import is pointed
 *  at the copy of what it named; a bare one still resolves from the app's node_modules. */
function copyDeclaration(decl: string, out: string, srcOut: string, vendored: Vendored): string | null {
  if (!/\.d\.[cm]?ts$/.test(decl)) return null;
  vendored.declarations.set(decl, out); // before rewriting, so a cycle of declarations ends
  mkdirSync(dirname(out), { recursive: true });
  // A reference names a path relative to the file that holds it, an import a module specifier.
  const rewrite = (reference: boolean) => (whole: string, _quote: string, spec: string): string => {
    // A "#" import is the owning package's `imports` map, which a copy outside the package no
    // longer has: resolve it from the file it came from, as the module copy's imports are.
    const target = !reference && spec.startsWith("#")
      ? importsDeclaration(spec, decl)
      : resolveDeclaration(reference && !spec.startsWith(".") && !spec.startsWith("/") ? "./" + spec : spec, decl);
    if (target === null) return whole;
    const dest = declarationCopy(target, srcOut, vendored);
    const to = dest === null ? null : reference ? importPath(dirname(out), dest) : declarationSpecifier(out, dest);
    return to === null ? whole : whole.replace(spec, to);
  };
  const text = readFileSync(decl, "utf8").replace(SPECIFIER, rewrite(false)).replace(REFERENCE_PATH, rewrite(true));
  writeFileSync(out, text);
  return out;
}

/** The copy of a declaration another declaration names: one more file beside the copies. */
function declarationCopy(decl: string, srcOut: string, vendored: Vendored): string | null {
  const hit = vendored.declarations.get(decl);
  if (hit !== undefined) return hit;
  const runtime = runtimeSiblingOfDeclaration(decl);
  const runtimeOut = runtime === null ? undefined : vendored.bySource.get(runtime);
  if (runtimeOut !== undefined)
    return copyDeclaration(decl, declarationBeside(runtimeOut), srcOut, vendored);
  return copyDeclaration(decl, join(srcOut, "deps", `d${vendored.next++}-${declarationName(decl)}`), srcOut, vendored);
}

/** Copies the declarations of the module a copy was made from, under the name TypeScript reads
 *  beside the copy. The import that reached the module says which declarations TypeScript would
 *  use for it: the package's own, named by its exports map or `types` field, or the `@types`
 *  package installed for it. Without them the compiler infers the module's shape from the shipped
 *  JavaScript, where a component's every destructured prop is required. */
function keepDeclarations(source: string, out: string, spec: string | undefined, fromFile: string | undefined, srcOut: string, vendored: Vendored): void {
  if (spec === undefined || fromFile === undefined) return;
  // A TypeScript source keeps its own types: the copy is compiled, not inferred.
  if (/\.[cm]?tsx?$/.test(source)) return;
  const decl = declarationFor(spec, source, fromFile);
  if (decl === null) return;
  copyDeclaration(decl, declarationBeside(out), srcOut, vendored);
}

/**
 * Copies a package's source file into the build dir, so its bare `document` and friends can be
 * bound to the runtime's own. Packages are compiled from their shipped sources anyway, and a
 * copy lets us rewrite the specifiers of everything they import. `spec` is the specifier that
 * reached the file, from `fromFile`, which is how the build finds the declarations TypeScript
 * would read for it.
 */
function copyDependency(source: string, srcOut: string, vendored: Vendored, spec?: string, fromFile?: string): string {
  const hit = vendored.bySource.get(source);
  if (hit !== undefined) return hit;
  // The build dir's package.json makes .js an ES module there; a CommonJS file keeps its kind as .cjs.
  const name = extname(source) === ".js" && !isModulePackage(dirname(source))
    ? basename(source, ".js") + ".cjs"
    : basename(source);
  // A declaration copy of this module already exists: place the JavaScript beside it under the
  // same name, so the checker's declaration graph and the compiler's implementation graph agree.
  const declSibling = declarationSiblingOfRuntime(source);
  const declOut = declSibling === null ? undefined : vendored.declarations.get(declSibling);
  const out = declOut === undefined
    ? join(srcOut, "deps", `d${vendored.next++}-${name}`)
    : declOut.replace(/\.d\.(?:mts|cts|ts)$/, extname(source) === ".mjs" ? ".mjs" : extname(source) === ".cjs" ? ".cjs" : ".js");
  vendored.bySource.set(source, out); // before rewriting, so an import cycle ends
  if (spec !== undefined) vendored.specs.set(out, spec);
  if (extname(source) === ".tsx" || extname(source) === ".jsx") vendored.jsx = true;
  mkdirSync(dirname(out), { recursive: true });
  if (extname(source) === ".json") {
    // Data names no modules of its own, so a required JSON file is copied as it stands.
    copyFileSync(source, out);
    return out;
  }
  keepDeclarations(source, out, spec, fromFile, srcOut, vendored);
  const text = rewriteSpecifiers(readFileSync(source, "utf8"), source, out, srcOut, vendored, true);
  writeFileSync(out, withDomImports(text, out, undefined, isJs(out)));
  return out;
}

/** True when the offset is inside a block comment, where an `import()` names a type and the
 *  loader may map it to a declaration file that has no code to copy. */
function inComment(text: string, offset: number): boolean {
  return text.lastIndexOf("/*", offset) > text.lastIndexOf("*/", offset);
}

/**
 * Points a copied file's imports and requires at the copies of the files they name. A required
 * file is part of the module either way: a require of a relative file would look for it beside the
 * copy, where nothing wrote it, and a require of a package would look in a node_modules the build
 * has none of — so both are copied into the build and the specifier pointed at the copy, as
 * imports are. An app file's relative imports and requires are left alone: the walk over the app
 * dir copies those to the same relative place.
 */
function rewriteSpecifiers(text: string, fromFile: string, outFile: string, srcOut: string, vendored: Vendored, inDependency: boolean): string {
  const copy = (spec: string, required: boolean): string | null => {
    const target = required
      ? resolveRequired(spec, fromFile, vendored.appDir)
      : resolveSpecifier(spec, fromFile, vendored.appDir);
    return target === null ? null : copyDependency(target, srcOut, vendored, spec, fromFile);
  };
  const withImports = text.replace(SPECIFIER, (whole: string, _quote: string, spec: string, offset: number) => {
    if (inComment(text, offset)) return whole;
    // An app's type-only import keeps resolving from node_modules; a package's own type-only
    // import points into its sources, which need this same copying to have the DOM bound.
    if (!inDependency && typeOnly(text, offset)) return whole;
    const relativeSpec = spec.startsWith(".") || spec.startsWith("/");
    if (!inDependency && relativeSpec) return whole;
    const dest = copy(spec, false);
    return dest === null ? whole : whole.replace(spec, importPath(dirname(outFile), dest));
  });
  return withImports.replace(REQUIRED, (whole: string, _quote: string, spec: string, offset: number) => {
    if (inComment(withImports, offset)) return whole;
    const relativeSpec = spec.startsWith(".") || spec.startsWith("/");
    if (!inDependency && relativeSpec) return whole;
    const dest = copy(spec, true);
    return dest === null ? whole : whole.replace(spec, importPath(dirname(outFile), dest));
  });
}

/** The app's own script files, in no particular order, as they are on disk. */
export function* appSources(appDir: string): Generator<{ path: string; text: string }> {
  const walk = function* (dir: string): Generator<{ path: string; text: string }> {
    for (const name of readdirSync(dir)) {
      if (name === ".native" || name === "node_modules" || name.startsWith(".")) continue;
      // A build's own output (an app bundle or resources directory), when it sits inside the
      // app, isn't an app source.
      if (name.endsWith(".app") || name.endsWith(".resources")) continue;
      const p = join(dir, name);
      if (statSync(p).isDirectory()) {
        yield* walk(p);
        continue;
      }
      if (APP_EXTS.includes(extname(name))) yield { path: p, text: readFileSync(p, "utf8") };
    }
  };
  yield* walk(appDir);
}

/** Copies the app's TS/JS sources into the build dir, making the DOM globals importable. */
function copySources(appDir: string, srcOut: string): Vendored {
  const vendored: Vendored = { bySource: new Map(), next: 0, specs: new Map(), appDir, jsx: false, declarations: new Map(), appFiles: [] };
  const sources = [...appSources(appDir)];
  // The files a `new Worker(...)` names get the worker's globals instead of the page's. They are
  // found before any copy, so a worker that imports another app source is known as it is copied.
  const workers = workerEntries(appDir, sources);
  // Rewriting the imports copies the dependencies' sources and declarations, so whether the
  // program checks against a browser's DOM library is known once every file is rewritten: the
  // same question dom-globals.ts answers, asked here before the globals are injected.
  const rewritten = new Map<string, string>();
  for (const { path: p, text } of sources) {
    const ext = extname(p);
    if (ext === ".tsx" || ext === ".jsx") vendored.jsx = true;
    const out = join(srcOut, relative(appDir, p));
    mkdirSync(dirname(out), { recursive: true });
    rewritten.set(out, rewriteSpecifiers(text, p, out, srcOut, vendored, false));
  }
  const buildRoot = dirname(srcOut);
  // A build checks against a browser's DOM types when a dependency's declarations ask for them,
  // or when an app that isn't JSX names the DOM library itself. Otherwise its global names are
  // the runtime's generated interfaces, which have no method bodies to compile a call through,
  // so a name used only as a type keeps its import there.
  const dependencyDomLib = declarationsLoadDomLib(buildRoot);
  const appDomLib = !vendored.jsx && appNamesDomLib(buildRoot);
  const globalTypes = dependencyDomLib || appDomLib;
  // A plain TypeScript page whose DOM types come only from a dependency's request for the
  // browser library still names the runtime's classes: its declarations and the page have to
  // meet on one set of classes, and scriptc cannot lower a property access through the library's
  // interfaces. A JSX page, or one whose own tsconfig asks for the library, keeps the type
  // world's meaning.
  const runtimeDomTypes = !vendored.jsx && dependencyDomLib && !appDomLib;
  for (const { path: p } of sources) {
    const out = join(srcOut, relative(appDir, p));
    vendored.appFiles.push(p);
    writeFileSync(out, withDomImports(rewritten.get(out) as string, out, undefined, undefined,
      { worker: workers.has(p), appDir, baseFile: out, globalTypes, runtimeDomTypes }));
  }
  return vendored;
}

/** Copies the app's sources and the dependencies they reach into `srcOut`, as a build does before
 *  compiling them, and returns each dependency's source path and its copy. A build goes on to
 *  compile what this wrote; the vendoring test reads the copies on their own. */
export function vendorSources(appDir: string, srcOut: string): Map<string, string> {
  return copySources(appDir, srcOut).bySource;
}

/** The vendored project a build analyzes, without compiling it: the app's sources copied and
 *  the JSX runtime wired to the build's own module, exactly as a build writes them before it
 *  compiles. `native dev`'s coverage check reads this program, so its findings are the build's. */
export function prepareAnalysisProject(appDir: string, srcOut: string): { jsxImportSource: string | null } {
  const vendored = copySources(appDir, srcOut);
  if (!vendored.jsx) return { jsxImportSource: null };
  const jsx = jsxSettings(appDir, false);
  if (jsx.jsx === "react") return { jsxImportSource: null };
  installJsxRuntime(appDir, srcOut, vendored, jsx);
  return { jsxImportSource: join(srcOut, JSX_SHIM) };
}

/** The NODE_ENV define a build hands scriptc, the way a bundler defines it for the code it
 *  compiles: a release build is production, a dev build development. */
export function nodeEnvDefine(dev: boolean): string {
  return `process.env.NODE_ENV=${dev ? '"development"' : '"production"'}`;
}

/** The app's JSX settings, from its tsconfig.json, defaulted as a browser toolchain does. */
interface JsxSettings {
  jsx: string;
  jsxImportSource: string;
  jsxFactory: string;
  jsxFragmentFactory: string;
}

/** The directory in the build that stands in for the app's jsx runtime. It holds a module per
 *  runtime the JSX mode can name, each re-exporting the vendored copy: scriptc's JSX transform
 *  writes an import of `<jsxImportSource>/jsx-runtime` into every JSX file, and that has to be
 *  the same module instance as the one the app's own imports reach — a second copy of preact
 *  would have its own Fragment and hooks, and fragments and hooks would stop working. The
 *  runtime is also vendored so its own `document` binds to this runtime's. */
const JSX_SHIM = "native-jsx";

/** JSON with the comments and trailing commas a tsconfig.json may carry. */
function parseJsonc(text: string): any {
  let out = "";
  let i = 0;
  while (i < text.length) {
    const c = text[i];
    if (c === "\"") {
      const start = i++;
      while (i < text.length && text[i] !== "\"") i += text[i] === "\\" ? 2 : 1;
      out += text.slice(start, i + 1);
      i++;
    } else if (c === "/" && text[i + 1] === "/") {
      while (i < text.length && text[i] !== "\n") i++;
    } else if (c === "/" && text[i + 1] === "*") {
      i += 2;
      while (i < text.length && !(text[i] === "*" && text[i + 1] === "/")) i++;
      i += 2;
    } else {
      out += c;
      i++;
    }
  }
  return JSON.parse(out.replace(/,(\s*[}\]])/g, "$1"));
}

/** What the app's tsconfig.json says about JSX: its `jsx`, `jsxImportSource` and, for the
 *  classic runtime, `jsxFactory` and `jsxFragmentFactory`. A dev build asks for the dev runtime
 *  when the package ships one, so a debugger sees jsxDEV calls. */
export function jsxSettings(appDir: string, dev: boolean): JsxSettings {
  let opts: { [key: string]: any } = {};
  const file = join(appDir, "tsconfig.json");
  if (existsSync(file)) {
    let cfg: any = null;
    try {
      cfg = parseJsonc(readFileSync(file, "utf8").replace(/^\uFEFF/, ""));
    } catch {
      die(`${relative(process.cwd(), file)} doesn't parse`);
    }
    const o = cfg === null || typeof cfg !== "object" ? null : cfg.compilerOptions;
    if (o !== null && typeof o === "object") opts = o;
  }
  const text = (v: any, fallback: string): string => (typeof v === "string" ? v : fallback);
  const jsxImportSource = text(opts.jsxImportSource, "react");
  let jsx = text(opts.jsx, "react-jsx");
  if (!["react-jsx", "react-jsxdev", "react"].includes(jsx)) {
    die(`jsx: ${JSON.stringify(jsx)} in tsconfig.json leaves the JSX for another tool to transform; use "react-jsx" or "react"`);
  }
  if (dev && jsx === "react-jsx" && resolveSpecifier(`${jsxImportSource}/jsx-dev-runtime`, join(appDir, "_.js"), appDir) !== null) {
    jsx = "react-jsxdev";
  }
  return {
    jsx,
    jsxImportSource,
    jsxFactory: text(opts.jsxFactory, "React.createElement"),
    jsxFragmentFactory: text(opts.jsxFragmentFactory, "React.Fragment"),
  };
}

/** The tsconfig of a build whose app has none of its own: the entry is the project, and the
 *  packages copied beside it are dependencies whose shipped JavaScript isn't the app's to check.
 *  `strictNullChecks` matches what the JSX config sets; scriptc's own defaults cover the rest. */
export function writeProjectTsconfig(buildDir: string, entry: string = "./entry.ts"): void {
  writeFileSync(join(buildDir, "tsconfig.json"),
    JSON.stringify({ files: [entry], compilerOptions: { strictNullChecks: true } }, null, 2) + "\n");
}

/** Whether a declaration the build copies asks for the browser's DOM library with a
 *  `/// <reference lib="dom…" />`. A package ships one so a browser project with no `lib: ["dom"]`
 *  still resolves the DOM names its declarations use; here that library's globals and
 *  dom-globals.ts's would be two declarations of the same names ("Subsequent variable declarations
 *  must have the same type", once per name, and duplicate type aliases). When a copied declaration
 *  asks for it, the build leaves the DOM to that library: the app's own DOM values still come from
 *  the runtime imports the build writes, and a package's declarations resolve to the browser's
 *  types, as they would in a browser project. */
function declarationsLoadDomLib(buildDir: string): boolean {
  const domLib = /\/\/\/[ \t]*<reference[ \t]+lib[ \t]*=[ \t]*["']dom(?:\.(?:iterable|asynciterable))?["']/;
  const walk = (dir: string): boolean => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const path = join(dir, entry.name);
      if (entry.isDirectory()) {
        if (walk(path)) return true;
      } else if (/\.d\.[cm]?ts$/.test(entry.name) && domLib.test(readFileSync(path, "utf8"))) {
        return true;
      }
    }
    return false;
  };
  return walk(buildDir);
}

/** The tsconfig scriptc reads beside the build, naming the JSX mode the app asked for. It lives
 *  in .native so scriptc finds it from every copied source and the app's own tsconfig can stay
 *  where it is (with settings, such as paths, that mean nothing from here). */
function writeJsxTsconfig(buildDir: string, srcOut: string, jsx: JsxSettings): void {
  // scriptc requires null and undefined to be distinct static types, as its inherited default
  // has them; only the JSX options come from the app's own tsconfig. The automatic runtime's
  // import source is an absolute path, so every JSX file reaches the build's own runtime
  // whatever directory it sits in.
  const compilerOptions: { [key: string]: string | boolean } = { jsx: jsx.jsx, strictNullChecks: true };
  if (jsx.jsx === "react-jsx" || jsx.jsx === "react-jsxdev") {
    compilerOptions.jsxImportSource = join(srcOut, JSX_SHIM);
  } else if (jsx.jsx === "react") {
    compilerOptions.jsxFactory = jsx.jsxFactory;
    compilerOptions.jsxFragmentFactory = jsx.jsxFragmentFactory;
  }
  // The entry and what it imports are the program. Left to itself, the compiler also takes every
  // file under the build dir as a root, and a declaration file it is handed that way is one it
  // can't load; the declarations the build copies for a vendored module are read through the
  // import that names them instead.
  writeFileSync(join(buildDir, "tsconfig.json"), JSON.stringify({ files: ["./entry.ts"], compilerOptions }, null, 2) + "\n");
}

/** True when the tsconfig the build reads names the browser's DOM library in `lib`, so a build
 *  without JSX already type-checks against lib.dom.d.ts. */
function appNamesDomLib(buildDir: string): boolean {
  const seen = new Set<string>();
  const read = (file: string): string[] | null => {
    if (seen.has(file) || seen.size > 8) return null;
    seen.add(file);
    let cfg: any;
    try {
      cfg = parseJsonc(readFileSync(file, "utf8").replace(/^\uFEFF/, ""));
    } catch {
      return null;
    }
    if (cfg === null || typeof cfg !== "object") return null;
    const parents = typeof cfg.extends === "string" ? [cfg.extends] : Array.isArray(cfg.extends) ? cfg.extends.filter((v: any) => typeof v === "string") : [];
    let fromParent: string[] | null = null;
    for (const spec of parents) {
      const inherited = extendsFile(spec, dirname(file));
      const lib = inherited === null ? null : read(inherited);
      if (lib !== null) fromParent = lib;
    }
    const lib = cfg.compilerOptions?.lib;
    return Array.isArray(lib) ? lib.filter((v: any) => typeof v === "string") : fromParent;
  };
  for (let dir = buildDir; ; ) {
    const file = join(dir, "tsconfig.json");
    if (existsSync(file)) {
      const lib = read(file);
      return lib !== null && lib.some((name) => /^dom(\.|$)/i.test(name));
    }
    const up = dirname(dir);
    if (up === dir) return false;
    dir = up;
  }
}

/** The file a tsconfig's `extends` names: a relative path, or a package's config. */
function extendsFile(spec: string, fromDir: string): string | null {
  if (spec.startsWith(".") || spec.startsWith("/")) {
    const base = resolve(fromDir, spec);
    for (const candidate of [base, base + ".json", join(base, "tsconfig.json")]) {
      if (existsSync(candidate) && statSync(candidate).isFile()) return candidate;
    }
    return null;
  }
  const require = createRequire(join(fromDir, "_.js"));
  for (const candidate of [spec, spec + ".json", spec + "/tsconfig.json"]) {
    try {
      return require.resolve(candidate);
    } catch {
      // try the next spelling
    }
  }
  return null;
}

/** True when the build type-checks with the app's own @types/node. scriptc reads a project's
 *  @types/node only for a project with a tsconfig: from a directory with none it type-checks
 *  with its own Node declarations instead. With one, it finds the type directive named `node`
 *  by searching the node_modules directories above the entry file. */
export function nodeTypesInstalled(buildDir: string): boolean {
  let project = false;
  for (let dir = buildDir; ; ) {
    if (existsSync(join(dir, "tsconfig.json"))) {
      project = true;
      break;
    }
    const up = dirname(dir);
    if (up === dir) break;
    dir = up;
  }
  if (!project) return false;
  for (let dir = buildDir; ; ) {
    if (existsSync(join(dir, "node_modules", "@types", "node", "package.json"))) return true;
    const up = dirname(dir);
    if (up === dir) return false;
    dir = up;
  }
}

/** The package.json of the installed package `pkg` that holds `file`, or null. */
function packageManifest(pkg: string, file: string): { dir: string; data: any } | null {
  let dir = dirname(file);
  for (;;) {
    const pj = join(dir, "package.json");
    if (existsSync(pj)) {
      try {
        const data = JSON.parse(readFileSync(pj, "utf8"));
        if (data.name === pkg) return { dir, data };
      } catch {
        // A package.json that doesn't parse describes nothing.
      }
    }
    const up = dirname(dir);
    if (up === dir) return null;
    dir = up;
  }
}

/** The type declarations an exports-map entry names. Only a `types` condition names one: the
 *  other conditions name the JavaScript that runs, which a copy must not be checked against. The
 *  condition's own value may be an object, as DefinitelyTyped writes it. */
function typesIn(value: any, dir: string, inTypes = false): string | null {
  if (typeof value === "string") return inTypes ? join(dir, value) : null;
  if (value === null || typeof value !== "object") return null;
  const hit = typesIn(value.types, dir, true);
  if (hit !== null) return hit;
  if (inTypes) {
    for (const key of ["import", "browser", "default", "require"]) {
      const nested = typesIn(value[key], dir, true);
      if (nested !== null) return nested;
    }
  }
  return null;
}

/** The `@types` package directory for `pkg`, searching the node_modules directories above
 *  `fromFile` as TypeScript does. React ships no declarations; they live in `@types/react`, and a
 *  scoped package's declarations are named for its scope: `@types/scope__name`. */
function typesPackageDir(pkg: string, fromFile: string): string | null {
  const name = pkg.startsWith("@") ? pkg.slice(1).replace("/", "__") : pkg;
  let dir = dirname(fromFile);
  for (;;) {
    const candidate = join(dir, "node_modules", "@types", name);
    if (existsSync(candidate)) return candidate;
    const up = dirname(dir);
    if (up === dir) return null;
    dir = up;
  }
}

/** The declaration file a `@types` package has for a subpath, found the way TypeScript finds it:
 *  the package's declared type entry at its root, an exports-map entry, `<subpath>.d.ts`, or a
 *  directory's `index.d.ts`. */
function typesPackageFile(typesDir: string, subpath: string): string | null {
  let data: any = null;
  try {
    data = JSON.parse(readFileSync(join(typesDir, "package.json"), "utf8"));
  } catch {
    // A package.json that doesn't parse describes nothing.
  }
  if (subpath === "") {
    for (const field of ["types", "typings"]) {
      if (typeof data?.[field] === "string" && existsSync(join(typesDir, data[field]))) return join(typesDir, data[field]);
    }
  }
  const exportsMap = data?.exports;
  if (exportsMap !== null && typeof exportsMap === "object" && !Array.isArray(exportsMap)) {
    const hit = typesIn(exportsMap[subpath === "" ? "." : "./" + subpath], typesDir);
    if (hit !== null && existsSync(hit)) return hit;
  }
  const base = join(typesDir, subpath);
  const candidates = subpath === "" ? [join(typesDir, "index.d.ts")] : [base + ".d.ts", join(base, "index.d.ts")];
  for (const candidate of candidates) {
    if (existsSync(candidate)) return candidate;
  }
  return null;
}

/** The package that holds `file`, by the nearest package.json that names one. */
function packageAt(file: string): { dir: string; data: any } | null {
  let dir = dirname(file);
  for (;;) {
    const pj = join(dir, "package.json");
    if (existsSync(pj)) {
      try {
        const data = JSON.parse(readFileSync(pj, "utf8"));
        if (typeof data.name === "string") return { dir, data };
      } catch {
        // A package.json that doesn't parse describes nothing.
      }
    }
    const up = dirname(dir);
    if (up === dir) return null;
    dir = up;
  }
}

/** True when an import clause binds `name`: a named, namespace or default import. */
function bindsName(clause: string, name: string): boolean {
  const braces = /\{([^}]*)\}/.exec(clause);
  if (braces !== null) {
    for (const part of braces[1].split(",")) {
      const bits = part.trim().split(/\s+as\s+/);
      if (bits[bits.length - 1].trim() === name) return true;
    }
  }
  const star = /\*\s+as\s+([A-Za-z_$][\w$]*)/.exec(clause);
  if (star !== null) return star[1] === name;
  // A default import is what is left once the braces and a namespace alias are gone.
  const rest = clause.replace(/\{[^}]*\}/, "").trim();
  return rest === name;
}

/** The JSX types a classic-runtime app's factory comes with: TypeScript looks the JSX namespace
 *  up in the module that declares `jsxFactory`, so the build finds that module the same way, as
 *  the app's own import of the factory, and takes the package's type declarations. */
function factoryTypes(appDir: string, factory: string): string | null {
  const root = factory.split(".")[0].trim();
  for (const { path, text } of appSources(appDir)) {
    for (const m of text.matchAll(/import\s+([^;]*?)\s+from\s+(["'])([^"']+)\2/g)) {
      if (!bindsName(m[1], root)) continue;
      const target = resolveSpecifier(m[3], path, appDir);
      if (target === null) continue;
      const types = declarationFor(m[3], target, path);
      if (types !== null) return types;
    }
  }
  return null;
}

/** Writes the build's JSX runtime, and vendors the app's runtime so it can re-export it. For the
 *  automatic runtime that is one module per runtime the tsconfig names (`jsx-runtime`, or a dev
 *  build's `jsx-dev-runtime`). scriptc's classic transform finds the JSX namespace only when it
 *  is global, so there the build writes one from the factory's package instead. The entry imports
 *  the classic one for its `declare global` to be part of the program. */
function installJsxRuntime(appDir: string, srcOut: string, vendored: Vendored, jsx: JsxSettings): string | null {
  const dir = join(srcOut, JSX_SHIM);
  if (jsx.jsx === "react") {
    const types = factoryTypes(appDir, jsx.jsxFactory);
    if (types === null) return null;
    mkdirSync(dir, { recursive: true });
    const out = join(dir, "globals.ts");
    // Type aliases, not interfaces extending the package's: its ElementClass can be a union.
    writeFileSync(out, [
      "// Generated by native: the classic JSX runtime's types, as the global namespace scriptc's",
      "// transform reads. TypeScript would take them from the module that declares the factory.",
      `import type { JSX as AppJSX } from ${JSON.stringify(importPath(dir, types).replace(/\.d\.ts$/, ""))};`,
      "declare global {",
      "  namespace JSX {",
      "    type IntrinsicElements = AppJSX.IntrinsicElements;",
      "    type Element = AppJSX.Element;",
      "    type ElementClass = AppJSX.ElementClass;",
      "    type ElementAttributesProperty = AppJSX.ElementAttributesProperty;",
      "    type ElementChildrenAttribute = AppJSX.ElementChildrenAttribute;",
      "    type IntrinsicAttributes = AppJSX.IntrinsicAttributes;",
      "  }",
      "}",
      "export {};",
      "",
    ].join("\n"));
    return out;
  }
  const subpath = jsx.jsx === "react-jsxdev" ? "jsx-dev-runtime" : "jsx-runtime";
  const spec = `${jsx.jsxImportSource}/${subpath}`;
  const target = resolveSpecifier(spec, join(appDir, "_.js"), appDir);
  if (target === null) die(`${spec} isn't installed, and JSX needs it (npm install ${jsx.jsxImportSource})`);
  const types = declarationFor(spec, target, join(appDir, "_.js"));
  if (types === null) die(`${spec} has no type declarations, and JSX needs them to type-check`);

  mkdirSync(dir, { recursive: true });
  // The copy needs no declaration beside it: the JSX namespace is a type no JavaScript value
  // stands for, so the shim below names the runtime's types itself and leaves its functions
  // typed from their own JavaScript, as any module without declarations is.
  const copy = copyDependency(target, srcOut, vendored);
  // The values come from the vendored copy; the types from the installed package, without the
  // extension, which a path ending in .d.ts needs a flag this build doesn't set. A JSX function
  // keeps the declared signature rather than its JavaScript's: a runtime written in JavaScript
  // may name fewer parameters than the JSX contract passes (React 19.3's development runtime
  // names four of the six), and a typed call passes all six.
  const declared = readFileSync(types, "utf8");
  const functions = (subpath === "jsx-dev-runtime" ? ["jsxDEV"] : ["jsx", "jsxs"]).filter((name) =>
    new RegExp(`\\bfunction\\s+${name}\\b`).test(declared),
  );
  const typed = functions.flatMap((name) => {
    const parameters = declaredParameters(declared, name);
    const params = parameters.map((_, i) => `p${i}`);
    return [
      `import { ${name} as _${name} } from ${JSON.stringify(importPath(dir, copy))};`,
      `import type { ${name} as _${name}Declared } from ${JSON.stringify(typesSpecifier(dir, types))};`,
      `export function ${name}(`,
      ...parameters.map(
        (parameter, i) =>
          `  ${params[i]}${parameter.optional ? "?" : ""}: Parameters<typeof _${name}Declared>[${i}],`,
      ),
      `): ReturnType<typeof _${name}Declared> {`,
      `  return (_${name} as any)(${params.join(", ")});`,
      `}`,
    ];
  });
  // A CommonJS runtime assigns `module.exports`, which a build reads as an `export =`, and a
  // module with that export can't be re-exported with `export *`. The JSX functions are exported
  // by name below; Fragment, the one other name the transform imports, is re-exported directly.
  const cjs = copy.endsWith(".cjs");
  // Fragment is a symbol in React's CommonJS runtime, where its declarations give it the type of
  // a component; the shim keeps the value and leaves its type open, as the runtime's own
  // declarations are what JSX checks against.
  //
  // React's Fragment is `Symbol.for("react.fragment")`, from React 16 on. Reading it through the
  // CommonJS runtime at the shim's load miscompiles on scriptc 0.4.16: the read is lowered to the
  // same-named `REACT_FRAGMENT_TYPE` of react.production.js, which the automatic JSX import loads
  // after this shim, so the app crashed before its first frame. The registry symbol is the same
  // value and needs no module to have run.
  const reactRuntime = jsx.jsxImportSource === "react";
  const header = cjs
    ? reactRuntime
      ? ['export const Fragment: any = Symbol.for("react.fragment");']
      : [
          `import { Fragment as _Fragment } from ${JSON.stringify(importPath(dir, copy))};`,
          "export const Fragment: any = _Fragment;",
        ]
    : [`export * from ${JSON.stringify(importPath(dir, copy))};`];
  writeFileSync(join(dir, subpath + ".ts"), [
    "// Generated by native: the app's JSX runtime, as one module instance.",
    ...header,
    ...typed,
    `export type { JSX } from ${JSON.stringify(typesSpecifier(dir, types))};`,
    "",
  ].join("\n"));
  return null;
}

/** The parameters the declaration's `name` function names, with whether each
 * is optional (`key?:`, or a default value); the wrapper keeps a parameter
 * optional, so a call the contract allows without it still type-checks. */
function declaredParameters(text: string, name: string): { optional: boolean }[] {
  const match = new RegExp(`\\bfunction\\s+${name}\\s*\\(`).exec(text);
  if (match === null) return [];
  let depth = 1;
  const parameters: { optional: boolean }[] = [];
  let current = "";
  for (let i = match.index + match[0].length; i < text.length && depth > 0; i++) {
    const ch = text[i]!;
    if (ch === "(" || ch === "[" || ch === "{" || ch === "<") depth++;
    else if (ch === ")" || ch === "]" || ch === "}" || ch === ">") depth--;
    if (depth === 0) break;
    if (depth !== 1) {
      current += ch;
      continue;
    }
    if (ch === ",") {
      // A trailing comma before the closing parenthesis adds no parameter.
      if (current.trim() !== "") parameters.push({ optional: isOptionalParameter(current) });
      current = "";
      continue;
    }
    current += ch;
  }
  if (current.trim() !== "") parameters.push({ optional: isOptionalParameter(current) });
  return parameters;
}

/** Whether one parameter's declaration text makes it optional. */
function isOptionalParameter(text: string): boolean {
  return /^\s*\.\.\./.test(text) || text.includes("?") || text.includes("=");
}

/** The specifier a generated module imports a declaration by. TypeScript drops a `.d.ts`
 *  extension from the path it writes, and reads `.d.mts` and `.d.cts` as the JavaScript kinds
 *  they describe. */
function typesSpecifier(fromDir: string, types: string): string {
  return importPath(fromDir, types).replace(/\.d\.mts$/, ".mjs").replace(/\.d\.cts$/, ".cjs").replace(/\.d\.ts$/, "");
}

/** A URL a script hands fetch() as a string literal, whose file the build can find. */
const FETCH_LITERAL = /\bfetch\s*\(\s*(["'])([^"'\n]+)\1/g;

/** The path a page-relative URL names, with "." and ".." resolved and ".." stopping at the
 *  page's directory, as the runtime resolves a fetch URL (see runtime/fetch.ts). */
function normalizeUrlPath(path: string): string {
  const out: string[] = [];
  for (const part of path.split("/")) {
    if (part === "" || part === ".") continue;
    if (part === "..") { if (out.length > 0) out.pop(); continue; }
    out.push(part);
  }
  return out.join("/");
}

/** A URL's path as the bytes it names: the runtime percent-decodes a fetch URL's path. */
function decodeUrlPath(path: string): string {
  try {
    return decodeURIComponent(path);
  } catch {
    return path;
  }
}

/**
 * Collects the files the app's scripts load and the build can see: a literal URL passed to
 * fetch(), and an import of a file that isn't a module (a JSON table, a binary). The runtime
 * resolves a fetch URL against the page's directory, so the build does too, whatever directory
 * the script sits in. A URL that names nothing is left alone: it fails at runtime as it did
 * before, which is how a page that expects a failed fetch keeps working.
 */
function collectScriptAssets(appDir: string, bundle: AssetBundle,
  sources: Iterable<{ path: string; text: string }> = appSources(appDir)): void {
  for (const { path, text } of sources) {
    for (const m of text.matchAll(FETCH_LITERAL)) {
      const url = m[2];
      const clean = url.split(/[?#]/)[0];
      if (clean === "" || clean.startsWith("//") || /^[a-z][a-z0-9+.-]*:/i.test(clean)) continue;
      const target = join(appDir, normalizeUrlPath(decodeUrlPath(clean)));
      if (existsSync(target) && statSync(target).isFile()) bundle.add(target);
    }
    for (const m of text.matchAll(SPECIFIER)) {
      if (inComment(text, m.index ?? 0)) continue;
      const spec = m[2];
      if (!spec.startsWith(".") && !spec.startsWith("/")) continue;
      const target = resolveSpecifier(spec, path, appDir);
      if (target === null || SOURCE_EXTS.includes(extname(target))) continue;
      bundle.add(target);
    }
  }
}

/** The text of every source file the app's scripts import, transitively, the app's own modules
 *  included. A package builds elements the page never spells out, so without this the build sees
 *  no tags to match and no class names to test, and drops their rules. */
function scriptDependencyText(appDir: string, scripts: { path: string | null; text: string }[]): string[] {
  const out: string[] = [];
  const seen = new Set<string>();
  const visit = (text: string, fromFile: string): void => {
    for (const m of text.matchAll(SPECIFIER)) {
      if (inComment(text, m.index ?? 0)) continue;
      const target = resolveSpecifier(m[2], fromFile, appDir);
      if (target === null || seen.has(target) || !SOURCE_EXTS.includes(extname(target))) continue;
      seen.add(target);
      const dep = readFileSync(target, "utf8");
      out.push(dep);
      visit(dep, target);
    }
  };
  for (const s of scripts) visit(s.text, s.path ?? join(appDir, "_.js"));
  return out;
}


// ---------------------------------------------------------------------------
// The build

/** An app's front end compiled, before anything is written or scriptc runs. */
export interface FrontEnd {
  htmlPath: string;
  appDir: string;
  app: CompiledApp;
  diags: Diagnostics;
  /** The files the app reads at runtime, for a build that is copied into a bundle. */
  bundle: AssetBundle | null;
  /** Time the HTML/CSS front end took, in milliseconds. */
  frontEndMs: number;
}

/** The part of the front end a build keeps: its page, its compiled tables, the diagnostics
 *  it printed and how long it took. */
export type AppBuild = Omit<FrontEnd, "diags"> & { diagnostics: string };

export interface BuildResult {
  /** The executable to run: inside the .app on macOS. */
  output: string;
  /** The directory the app's own files were copied into, or "" for a build that isn't bundled. */
  resources: string;
  /** What the bundle holds, for the build's summary line; 0 files for a dev build. */
  assets: BundleCopy;
  /** The whole native side of the build, in milliseconds. */
  nativeMs: number;
  /** scriptc's compile and link, in milliseconds. */
  scriptcMs: number;
  /** True when an earlier build's executable was reused instead of compiling. */
  cached: boolean;
  /** The page's compiled front end; absent when a build before the front end answered. */
  app?: CompiledApp;
}

/** Where a build's executable, and the app's files, go: a .app bundle on macOS, the executable
 *  plus a resources directory beside it elsewhere. A dev build writes just the executable. */
export interface OutputPaths {
  executable: string;
  resources: string;
  /** The .app directory, or null when the build isn't a bundle. */
  bundle: string | null;
  /** The path a caller asked for, which stays a way to run the app on macOS. */
  alias: string;
}

export function outputPaths(out: string, bundled: boolean): OutputPaths {
  // A Windows executable carries its extension, so a build's output is run by the name it has.
  const exe = buildingWindows() && !out.endsWith(".exe") ? out + ".exe" : out;
  if (!bundled) return { executable: exe, resources: "", bundle: null, alias: out };
  if (MACOS) {
    const dir = out.endsWith(".app") ? out : out + ".app";
    const name = basename(dir, ".app");
    return {
      executable: join(dir, "Contents", "MacOS", name),
      resources: join(dir, "Contents", "Resources"),
      bundle: dir,
      alias: out,
    };
  }
  return { executable: exe, resources: exe + ".resources", bundle: null, alias: out };
}

/** Escapes text for an XML plist's string value. */
function xmlText(text: string): string {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

/** A bundle identifier made from the app's name, as macOS expects ("letters, digits, hyphen, period"). */
function bundleIdentifier(name: string): string {
  const id = name.toLowerCase().replace(/[^a-z0-9.-]+/g, "-").replace(/^-+|-+$/g, "");
  return "dev.native-sdk." + (id === "" ? "app" : id);
}

/**
 * The Info.plist that makes the .app directory an app Finder can open. The app metadata names the
 * bundle, its display name, its version and its icon; the fallback covers a build with no page to
 * read it from.
 */
export function writeInfoPlist(bundleDir: string, executableName: string, title: string,
  info: AppInfo | null = null, iconFile: string | null = null): void {
  const name = info === null ? (title === "" ? executableName : title) : info.shortName;
  const lines = [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
    '<plist version="1.0">',
    "<dict>",
    "  <key>CFBundleDevelopmentRegion</key><string>en</string>",
    `  <key>CFBundleExecutable</key><string>${xmlText(executableName)}</string>`,
    `  <key>CFBundleIdentifier</key><string>${xmlText(info === null ? bundleIdentifier(executableName) : info.id)}</string>`,
    "  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>",
    `  <key>CFBundleName</key><string>${xmlText(name)}</string>`,
    ...(info === null || info.name === name ? [] : [`  <key>CFBundleDisplayName</key><string>${xmlText(info.name)}</string>`]),
    "  <key>CFBundlePackageType</key><string>APPL</string>",
    `  <key>CFBundleShortVersionString</key><string>${xmlText(info === null ? "1.0" : info.version)}</string>`,
    `  <key>CFBundleVersion</key><string>${xmlText(info === null ? "1" : info.version)}</string>`,
    ...(iconFile === null ? [] : [`  <key>CFBundleIconFile</key><string>${xmlText(iconFile)}</string>`]),
    "  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>",
    "  <key>NSHighResolutionCapable</key><true/>",
    "  <key>NSPrincipalClass</key><string>NSApplication</string>",
    "</dict>",
    "</plist>",
    "",
  ];
  mkdirSync(join(bundleDir, "Contents"), { recursive: true });
  writeFileSync(join(bundleDir, "Contents", "Info.plist"), lines.join("\n"));
}

/** The file a dev build's runtime watches for recompiled HTML/CSS tables. */
export const DEV_DATA = "dev.json";

export function devDataPath(appDir: string): string {
  return join(appDir, ".native", DEV_DATA);
}

/** Writes the compiled tables to a file a runtime reads them from, replacing it atomically: a
 *  run that is starting reads either the old tables or the new ones. */
function writeTables(file: string, app: CompiledApp): void {
  mkdirSync(dirname(file), { recursive: true });
  const tmp = file + ".tmp";
  writeFileSync(tmp, JSON.stringify(app.tables));
  renameSync(tmp, file);
}

/** Writes the compiled tables where a dev build's runtime reads them. */
export function writeDevData(appDir: string, app: CompiledApp): void {
  writeTables(devDataPath(appDir), app);
}

/** Where a release build's runtime reads the compiled tables: a file in the bundle's own
 *  directory, beside the app's files. The executable carries no tables of its own. */
export function pageDataPath(resources: string): string {
  return join(resources, PAGE_TABLES_DIR, PAGE_TABLES_FILE);
}

/** Writes the compiled tables into a build's bundle, where the next launch reads them. */
export function writePageData(resources: string, app: CompiledApp): void {
  writeTables(pageDataPath(resources), app);
}

/** A page's scripts as one string: the dev command rebuilds when this changes, since a script
 *  cannot be applied to a running process. */
export function scriptSignature(scripts: { path: string | null; text: string }[]): string {
  return scripts.map((s) => (s.path !== null ? `file:${s.path}` : `inline:${s.text}`)).join("\u0000");
}

/**
 * Writes the one module a page's classic scripts share, in document order, with the page's handler
 * attributes attached in that scope before the first of them runs. A name a script leaves on the
 * window is bound for the scripts after it, as a browser's global object does. Returns the file.
 *
 * The module is TypeScript when every script in it is (so they keep their checking), and plain
 * JavaScript otherwise; a page that mixes the two loses the checking of its TypeScript scripts,
 * which is the price of their sharing one scope. Inline scripts are JavaScript already.
 */
function writeClassicScripts(srcOut: string, classic: ScriptFile[], handlers: HandlerAttribute[], appDir: string, htmlPath: string): string {
  const ts = classic.filter((s) => s.path !== null && /\.[cm]?tsx?$/.test(s.path));
  const allTs = ts.length === classic.length;
  const mixed = ts.length > 0 && !allTs;
  const out = join(srcOut, allTs || mixed ? ".scripts.ts" : ".scripts.js");
  const lines: string[] = [];
  // The pragma has to be the file's first line, which is why the banner follows it.
  if (mixed) lines.push("// @ts-nocheck");
  lines.push("// Generated by native: the page's classic scripts, in document order and in one scope.");
  lines.push(`import { reportUncaughtError } from ${JSON.stringify(importPath(dirname(out), join(RUNTIME, "window.ts")))};`);
  if (handlers.length > 0) {
    lines.push(`import { attachHandler } from ${JSON.stringify(importPath(dirname(out), join(RUNTIME, "app.ts")))};`);
    for (const h of handlers) {
      lines.push(`attachHandler(${h.node}, ${JSON.stringify(h.type)}, function (this: any, event: any): any {`);
      lines.push(h.code);
      lines.push("});");
    }
  }
  // A declaration that stays in its script's try is block-scoped there; its value is copied
  // into this object as it initializes, which is how the scripts after it see the name at
  // the module's top level. A JavaScript page needs no type on the carrier: only a
  // TypeScript module checks the string index.
  lines.push(allTs || mixed ? "const __nativeBound: any = {};" : "const __nativeBound = {};");
  const declared = topLevelDeclarations(classic.map((s) => s.text).join("\n"));
  const aliased = new Set<string>();
  const texts = classic.map((s) => s.text);
  // Names a script assigns without declaring are the page's globals in a browser; a module is
  // strict, so they get a binding here and are copied onto the window as each script ends.
  const implicit = [...new Set(texts.flatMap((t) => implicitGlobals(t, declared, aliased)))];
  const statements = texts.map(scriptStatements);
  const names = statements.map((sts) => sts.map((st) => (st.decl ? declNames(st.text) : [])));
  const handlerText = handlers.map((h) => `function () {\n${h.code}\n}`).join("\n");
  // The names a script declares that something outside its own try can see — a handler, or another
  // script — have to be module bindings: a block's own names end with the try.
  const shared = new Set<string>();
  for (let i = 0; i < classic.length; i++) {
    let outside = handlerText;
    for (let j = 0; j < texts.length; j++) if (j !== i) outside += "\n" + texts[j];
    // A function or class this script declares is lowered away from the block it was written in,
    // and scriptc can't reference a block-scoped binding from there, so every name its body uses
    // is a module binding too. (A page's own component class capturing a const is the common case.)
    for (const st of scriptStatements(texts[i])) {
      if (!/^(?:(?:async\s+)?function\b|class\b|abstract\s+class\b)/.test(st.text)) continue;
      outside += "\n" + st.text;
    }
    for (const sts of names[i]) for (const n of sts) if (new RegExp("\\b" + n + "\\b").test(outside)) shared.add(n);
  }
  // A declaration hoisted whole (a function, a class, a destructuring) takes the names in its text
  // with it: they are module bindings too. Repeat, since one of those can name another.
  const allDeclared = new Set<string>();
  for (const sts of names) for (const st of sts) for (const n of st) allDeclared.add(n);
  for (let grew = true; grew; ) {
    grew = false;
    for (let i = 0; i < classic.length; i++) {
      for (let k = 0; k < statements[i].length; k++) {
        const st = statements[i][k];
        if (!st.decl || !names[i][k].some((n) => shared.has(n))) continue;
        if (splitVar(st.text) !== null) continue;
        for (const id of identifiersOf(st.text)) {
          if (!allDeclared.has(id) || shared.has(id)) continue;
          shared.add(id);
          grew = true;
        }
      }
    }
  }
  // A name a script assigns without declaring is a property of the page's global object in a
  // browser. A module is strict, so the binding starts from what the window holds and the window
  // is updated after each script (see implicitGlobals).
  // `var`, not `let`: a `var` of the same name anywhere in the scripts (a block at the top level,
  // say) hoists to this scope too, and two `var`s of one name are one binding where a `let` and a
  // `var` would be a redeclaration error.
  for (const name of implicit) {
    lines.push(allTs || mixed
      ? `var ${name}: any = (window as any).${name};`
      : `var ${name} = window.${name};`);
  }
  for (let i = 0; i < classic.length; i++) {
    const s = classic[i];
    // A script sees its own element through document.currentScript while it runs.
    lines.push(`document.currentScript = document.getElementsByTagName("script")[${s.order}];`);
    // A script's statements run inside a try: a throw stops that script only, as a browser's does,
    // and the next script still runs. A declaration stays where it stood, so the statements before
    // it run first, and only a name something outside the try can see is declared at the top too.
    // That keeps a page's own const a const, with the type it infers, whenever nothing else names
    // it. Two things a browser does differently: a function declared in a later script is callable
    // before that script runs, since modules hoist them all; and a let or const read before its
    // statement gives undefined here where a browser's temporal dead zone throws.
    const decls: string[] = [];
    const body: string[] = [];
    const bound: string[] = [];
    for (let k = 0; k < statements[i].length; k++) {
      const st = statements[i][k];
      // An ambient declaration says what exists rather than making it, so it can stand at the top
      // whatever its name is.
      const ambient = /^declare\b/.test(st.text);
      if (!st.decl || !(ambient || names[i][k].some((n) => shared.has(n)))) {
        body.push(st.text);
        continue;
      }
      // A module binding is declared at the top and given its value where the statement stood.
      // A let or const whose initializers name nothing this script declares can move to the top
      // whole, keeping its inferred types; anything else is split, so its initializer keeps its
      // place in the script (and a TypeScript page gets the split's explicit any).
      if (/^(?:const|let)\b/.test(st.text) && hoistableDecl(st.text, allDeclared)) {
        decls.push(st.text);
        continue;
      }
      const split = splitVar(st.text, allTs || mixed);
      if (split !== null) {
        decls.push(split.decl);
        if (split.inits !== "") body.push(split.inits);
        continue;
      }
      // A shared let, const or class keeps its place and publishes each name as it initializes,
      // so its initializer still runs after the statements it uses.
      const inPlace = inPlaceNames(st.text);
      if (inPlace === null) decls.push(st.text);
      else {
        body.push(st.text);
        body.push(inPlace.map((n) => `__nativeBound[${JSON.stringify(n)}] = ${n};`).join(" "));
        for (const n of inPlace) bound.push(n);
      }
    }
    // A classic script's top-level var and function names are window properties in a browser.
    // A name published through __nativeBound is ready only once the binding is rebuilt below.
    const varNames = windowVarNames(s.text);
    const lateVars = varNames.filter((n) => bound.indexOf(n) >= 0);
    // The bundle is TypeScript when any script is: an arbitrary window property needs the cast
    // there, as Window's own type has no index signature.
    const windowWrite = (n: string): string => allTs || mixed ? `(window as any).${n} = ${n};` : `window.${n} = ${n};`;
    for (const n of varNames) if (bound.indexOf(n) < 0) body.push(windowWrite(n));
    // A name the script wrote to without declaring it is a window property too, written where
    // the script's own statements end as a browser would have left it.
    for (const n of implicit) body.push(windowWrite(n));
    for (const d of decls) lines.push(d);
    lines.push("try {");
    for (const b of body) lines.push(b);
    lines.push("} catch (e) {");
    lines.push("  reportUncaughtError(e);");
    lines.push("}");
    for (const n of bound) lines.push(`var ${n} = __nativeBound[${JSON.stringify(n)}];`);
    for (const n of lateVars) lines.push(windowWrite(n));
    const alias = windowAliases(s.text, aliased, declared);
    if (alias !== "") lines.push(alias);
  }
  lines.push("document.currentScript = null;");
  writeFileSync(out, withDomImports(lines.join("\n") + "\n", out, true, !(allTs || mixed),
    { appDir, baseFile: htmlPath }));
  return out;
}

/** Resolves an app directory or index.html and compiles its HTML and CSS the way a build does,
 *  following the module graph its scripts import. Diagnostics come back rather than ending the
 *  process, so the check command can report them as they are. A `bundled` compile also collects
 *  the files the app reads, for a build that copies them beside the executable. */
export function compileFrontEnd(input: string, bundled = false): FrontEnd {
  let htmlPath = resolve(input);
  if (existsSync(htmlPath) && statSync(htmlPath).isDirectory()) htmlPath = join(htmlPath, "index.html");
  if (!existsSync(htmlPath)) die(`${input}: no index.html found`);
  const appDir = dirname(htmlPath);
  const publicDir = publicDirOf(appDir);

  const t0 = performance.now();
  const diags = new Diagnostics();
  const bundle = bundled ? new AssetBundle(appDir, publicDir) : null;
  // A public directory is the site root, so every file in it goes to the bundle as it is, whether
  // or not the build can see a reference to it: that is what a URL a script builds at runtime
  // names. It goes in first, so a referenced file with the same path takes a name beside it.
  if (bundle !== null) bundle.addPublicDir();
  if (bundle !== null) collectScriptAssets(appDir, bundle);
  const app = compileApp(htmlPath, diags, {
    // "/x" is a public URL when there is a public directory; without one it keeps naming a file
    // beside the page, as it always has.
    root: publicDir ?? undefined,
    publicDir: publicDir ?? undefined,
    scriptDependencies: (scripts) => scriptDependencyText(appDir, scripts),
    bundle: bundle ?? undefined,
  });
  // A page's scripts load files the walk over its source files didn't see: an inline script's
  // literal fetch() is one of them. They resolve against the page's directory, as at runtime.
  if (bundle !== null) {
    collectScriptAssets(appDir, bundle, [
      ...app.scripts.map((s) => ({ path: s.path ?? join(appDir, "_.js"), text: s.text })),
      ...app.handlers.map((h) => ({ path: join(appDir, "_.js"), text: h.code })),
    ]);
  }
  return { htmlPath, appDir, app, diags, bundle, frontEndMs: performance.now() - t0 };
}

/** The page an input names: a directory's index.html, or the file itself. */
export function htmlPathOf(input: string): string {
  let htmlPath = resolve(input);
  if (existsSync(htmlPath) && statSync(htmlPath).isDirectory()) htmlPath = join(htmlPath, "index.html");
  return htmlPath;
}

/** The app directory an input names. */
export function appDirOf(input: string): string {
  return dirname(htmlPathOf(input));
}

/** The executable a build with this output writes. */
export function outputPath(appDir: string, out: string | null): string {
  return resolve(out ?? join(appDir, basename(appDir)));
}

/** Checks that the output's nearest existing ancestor is a directory, and creates the ones
 *  below it. */
function ensureOutputDir(output: string): void {
  for (let d = dirname(output); d !== dirname(d); d = dirname(d)) {
    if (existsSync(d)) {
      if (!statSync(d).isDirectory()) die(`can't write ${relative(process.cwd(), output)}: ${relative(process.cwd(), d) || d} is a file, not a directory`);
      break;
    }
  }
  mkdirSync(dirname(output), { recursive: true });
}

/** The page's compiled statistics, as the summary line prints them. */
function summaryOf(app: CompiledApp): string {
  const s = app.stats;
  return `${s.elements} nodes, ${s.rules} rules (${s.conditionalRules} conditional, ${s.rulesDropped} dead removed` +
    (s.dynamicSelectors > 0 ? `, ${s.dynamicSelectors} runtime selectors` : "") +
    (s.staticChains + s.runtimeChains > 0 ? `, combinators: ${s.staticChains} resolved at build time, ${s.runtimeChains} at runtime` : "") + ")";
}

/** Writes what a build printed, and the line that summarises it. `scriptc` is the time it took in
 *  milliseconds, "cached" when an executable an earlier build stored was reused, or "skipped" when
 *  the program was unchanged and only the page's data needed writing. */
function report(output: string, bytes: number, summary: string, nativeMs: number, scriptc: number | string,
  assets?: BundleCopy): void {
  const time = typeof scriptc === "number" ? `${(scriptc / 1000).toFixed(1)}s` : scriptc;
  const copied = assets === undefined || assets.count === 0 ? ""
    : `, ${assets.count} asset${assets.count === 1 ? "" : "s"} (${(assets.bytes / 1024).toFixed(0)} KB)`;
  console.error(
    `native: ${relative(process.cwd(), output)} (${(bytes / 1024 / 1024).toFixed(1)} MB) — ${summary}; ` +
      `native ${nativeMs.toFixed(0)}ms, scriptc ${time}${copied}`,
  );
}

/** The libraries ANGLE comes as: EGL, the ES implementation, and the shader compiler under it. */
const ANGLE_LIBRARIES = ["libEGL.dll", "libGLESv2.dll", "d3dcompiler_47.dll"];

/** The optional package that carries ANGLE for the Windows host. Its `os` and `cpu` fields keep it
 *  to win32-x64, so npm installs it beside the CLI exactly on the machines a Windows build runs on,
 *  and a build asks for it nowhere else. */
const ANGLE_PACKAGE = join("@native-sdk", "angle-win32-x64");

/** Where the ANGLE build this app's WebGL 2 uses is: NATIVE_ANGLE_DIR when it is set, so a build
 *  can use another ANGLE build (a cross-build from Linux or macOS has to, since the package is not
 *  installed there), and otherwise the @native-sdk/angle-win32-x64 package installed beside the
 *  CLI. Null when neither is there. */
function angleDirectory(): string | null {
  const chosen = process.env.NATIVE_ANGLE_DIR;
  if (chosen !== undefined && chosen !== "") return chosen;
  return installedPackage(ROOT, ANGLE_PACKAGE);
}

/** Copies ANGLE's libraries into a Windows app's resources. The host loads them from there first,
 *  so the app carries WebGL 2 with it and needs no ANGLE on the machine it runs on; without them a
 *  page that asks for WebGL 2 gets the same null a browser without WebGL gives. */
function installAngleLibraries(resources: string): void {
  const dir = angleDirectory();
  if (dir === null) return;
  mkdirSync(resources, { recursive: true });
  for (const name of ANGLE_LIBRARIES) {
    const source = join(dir, name);
    if (!existsSync(source)) continue;
    copyFileSync(source, join(resources, name));
  }
}

/** The iconset entries an .icns holds: the pixel size and the name iconutil expects. */
const ICNS_ENTRIES: readonly (readonly [number, string])[] = [
  [16, "icon_16x16.png"], [32, "icon_16x16@2x.png"],
  [32, "icon_32x32.png"], [64, "icon_32x32@2x.png"],
  [128, "icon_128x128.png"], [256, "icon_128x128@2x.png"],
  [256, "icon_256x256.png"], [512, "icon_256x256@2x.png"],
  [512, "icon_512x512.png"], [1024, "icon_512x512@2x.png"],
];

/** Builds an .icns from a PNG with the system's sips and iconutil; false when either is
 *  missing or the image can't be read. */
function writeIcns(png: string, out: string): boolean {
  const dir = mkdtempSync(join(tmpdir(), "native-icon-"));
  try {
    const iconset = join(dir, "AppIcon.iconset");
    mkdirSync(iconset);
    for (const [size, name] of ICNS_ENTRIES) {
      const r = spawnSync("sips", ["-z", String(size), String(size), png, "--out", join(iconset, name)], { encoding: "utf8" });
      if (r.status !== 0) return false;
    }
    return spawnSync("iconutil", ["-c", "icns", iconset, "-o", out], { encoding: "utf8" }).status === 0;
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

/** Writes the app facts and the icon a bundle carries. Returns the icon's name for the Info.plist
 *  (without its extension) when the bundle has one. */
function writeAppMetadata(resources: string, info: AppInfo): string | null {
  const dir = join(resources, PAGE_TABLES_DIR);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "app.json"), JSON.stringify(bundledInfo(info), null, 2) + "\n");
  if (info.icon === null) return null;
  const png = join(dir, "icon.png");
  copyFileSync(info.icon.source, png);
  if (!MACOS) return null;
  return writeIcns(png, join(resources, "AppIcon.icns")) ? "AppIcon" : null;
}

/** Puts the app's own files in place: the bundle beside the executable, the macOS wrapper
 *  that makes it a Finder app, and the requested path as a way to run it. A bundled build also
 *  writes the app's identity and icon. */
function installBundle(paths: OutputPaths, output: string, title: string, files: readonly BundleFile[],
  info: AppInfo | null = null): BundleCopy {
  if (paths.resources === "") return { count: 0, bytes: 0 };
  let copy: BundleCopy = { count: 0, bytes: 0 };
  if (files.length > 0) copy = copyBundle(files, paths.resources);
  else {
    // An app bundle always has a Resources directory; one whose app has no files leaves it
    // empty, and an earlier build's files don't stay. A Linux build with nothing to bundle has
    // no resources directory at all, unless a release build writes its app facts there.
    rmSync(paths.resources, { recursive: true, force: true });
    if (info !== null) mkdirSync(paths.resources, { recursive: true });
  }
  const icon = info === null ? null : writeAppMetadata(paths.resources, info);
  if (buildingWindows()) installAngleLibraries(paths.resources);
  if (paths.bundle !== null) {
    writeInfoPlist(paths.bundle, basename(output), title, info, icon);
    mkdirSync(paths.resources, { recursive: true });
    // The requested path keeps working as a way to run the app (a hard link to the same
    // binary, so no second copy), and the host finds the .app's Resources from it.
    if (paths.alias !== paths.bundle) {
      if (existsSync(paths.alias) && statSync(paths.alias).isDirectory()) {
        die(`can't write ${relative(process.cwd(), paths.alias)}: it is a directory, and the app bundle is ${relative(process.cwd(), paths.bundle)}`);
      }
      rmSync(paths.alias, { force: true });
      try {
        linkSync(output, paths.alias);
      } catch {
        // A filesystem without hard links (or a different one) takes a copy instead.
        copyFileSync(output, paths.alias);
      }
    }
  }
  return copy;
}

/** Signs and packages a release build's .app on macOS. A plain build, a dev build and a build on
 *  another platform have nothing to do here. */
function packageRelease(paths: OutputPaths, info: AppInfo | null, release: boolean): void {
  if (!release || info === null || !MACOS || paths.bundle === null) return;
  packageMacApp({ bundle: paths.bundle, executable: paths.executable, alias: paths.alias }, info);
}

/** Reuses a stored build: copies its executable and tables into place, writes its bundle,
 *  prints what the build printed, and reports it as a hit. */
function reuseBuild(cache: BuildCache, entry: CacheEntry, paths: OutputPaths, dev: boolean,
  appDir: string, app: CompiledApp | null, t0: number, printDiagnostics: boolean,
  files: readonly BundleFile[], title: string, info: AppInfo | null = null, release: boolean = false): BuildResult {
  const output = paths.executable;
  ensureOutputDir(output);
  cache.restore(entry, output, dev ? devDataPath(appDir) : null);
  writeManifest(appDir, entry.files);
  const assets = installBundle(paths, output, title, files, info);
  // The entry keeps the page tables a release build reads; writing them into the bundle a build
  // has just made is all a markup edit needs, and this build didn't even parse the page.
  if (!dev && paths.resources !== "") {
    cache.restorePage(entry, pageDataPath(paths.resources));
    packageRelease(paths, info, release);
    if (entry.program !== "") {
      const built = statSync(output);
      writeBuildRecord(appDir, output, { program: entry.program, size: built.size, mtimeMs: built.mtimeMs });
    }
  }
  if (printDiagnostics && entry.diagnostics !== "") process.stderr.write(entry.diagnostics);
  if (entry.stderr !== "") process.stderr.write(entry.stderr);
  const nativeMs = performance.now() - t0;
  report(paths.bundle ?? output, entry.bytes, entry.summary, nativeMs, "cached", assets);
  return { output, resources: paths.resources, assets, nativeMs, scriptcMs: 0, cached: true, app: app ?? undefined };
}

/** A page compiled for a build, with its diagnostics printed and any error fatal. */
export function openApp(input: string, bundled = false): AppBuild {
  const { htmlPath, appDir, app, diags, bundle, frontEndMs } = compileFrontEnd(input, bundled);
  const diagnostics = diags.list.length > 0 ? diags.format(color) : "";
  if (diagnostics !== "") console.error(diagnostics);
  if (diags.errorCount > 0) die(`${diags.errorCount} error(s)`);
  return { htmlPath, appDir, app, bundle, frontEndMs, diagnostics };
}


/** What a scriptc run printed and how it ended. */
export interface ScriptcResult {
  status: number | null;
  /** The signal that ended the compiler, when one did; `status` is null in that case. */
  signal?: NodeJS.Signals | null;
  stdout: string;
  stderr: string;
  error?: Error;
}

/** Runs `command` with its output collected, handing each scriptc timing line to `onTiming` as it
 *  is written instead of collecting it: that is what lets the build follow its phases while the
 *  compiler works. A timing line is only taken out of the output when a reader takes it. */
function runStreaming(command: string, args: string[], options: SpawnOptions,
  onTiming?: (event: TimingEvent) => void): Promise<ScriptcResult> {
  return new Promise((resolve) => {
    let child;
    try {
      child = spawn(command, args, options);
    } catch (error) {
      resolve({ status: null, stdout: "", stderr: "", error: error as Error });
      return;
    }
    let stdout = "";
    let stderr = "";
    let partial = "";
    const take = (line: string): boolean => {
      const event = onTiming === undefined ? null : parseTimingLine(line);
      if (event === null) return false;
      onTiming!(event);
      return true;
    };
    child.stdout?.on("data", (chunk: Buffer) => { stdout += chunk.toString("utf8"); });
    child.stderr?.on("data", (chunk: Buffer) => {
      const text = partial + chunk.toString("utf8");
      const lines = text.split("\n");
      partial = lines.pop() ?? "";
      for (const line of lines) if (!take(line)) stderr += line + "\n";
    });
    let done = false;
    const settle = (status: number | null, signal: NodeJS.Signals | null, error?: Error): void => {
      if (done) return;
      done = true;
      if (partial !== "" && !take(partial)) stderr += partial;
      resolve(error === undefined ? { status, signal, stdout, stderr } : { status, signal, stdout, stderr, error });
    };
    // A command that couldn't start reports `error` and then closes with no status.
    child.on("error", (error) => settle(null, null, error));
    child.on("close", (status, signal) => settle(status, signal));
  });
}

/**
 * Runs the scriptc command with `args`, as the build does: the compiler from findScriptc(), with
 * the batch shim a shell needs on Windows. `env` adds to the environment for this run. When
 * `onTiming` is given, scriptc's SCRIPTC_TIMING lines are passed to it rather than collected.
 */
export async function runScriptc(args: string[], env?: NodeJS.ProcessEnv,
  onTiming?: (event: TimingEvent) => void): Promise<ScriptcResult> {
  const scriptcPath = findScriptc();
  // The compiler's warnings for a large program (the whole SDK runtime) run past a megabyte. A
  // spawnSync had to be given a maxBuffer well above its 1 MB default to keep them; this reader
  // streams and keeps every line, so nothing is truncated at any size.
  const options: SpawnOptions = env === undefined
    ? { stdio: ["ignore", "pipe", "pipe"] }
    : { stdio: ["ignore", "pipe", "pipe"], env: { ...process.env, ...env } };
  if (isBatchShim(scriptcPath)) {
    // cmd strips the first and last quote of a /c line that starts with one, so the line carries a
    // wrapping pair of its own: without it the trailing arguments are cut off and the compiler
    // sees no command at all.
    const command = '"' + [batchQuote(scriptcPath), ...args.map(batchQuote)].join(" ") + '"';
    return runStreaming(process.env.ComSpec || "cmd.exe", ["/d", "/s", "/c", command],
                        { ...options, windowsVerbatimArguments: true }, onTiming);
  }
  return runStreaming(scriptcPath, args, options, onTiming);
}

/** Links scriptc's contract types into a build directory, so generated code resolves them from
 *  native's own install. Replaces a link left by an earlier native install or checkout
 *  (existsSync is false for a dangling link). */
export function linkScriptcTypes(buildDir: string): void {
  const typesLink = join(buildDir, "node_modules", "@scriptc", "types");
  const typesTarget = installedPackage(ROOT, join("@scriptc", "types")) ?? join(ROOT, "node_modules", "@scriptc", "types");
  let current: string | null = null;
  try {
    current = readlinkSync(typesLink);
  } catch {
    current = null;
  }
  // A junction is the directory link Windows makes without Developer Mode or an administrator;
  // elsewhere a plain symbolic link is what a link is.
  const linkType: "dir" | "junction" = process.platform === "win32" ? "junction" : "dir";
  const sameTarget = current !== null && resolve(current) === resolve(typesTarget);
  if (!sameTarget) {
    rmSync(typesLink, { force: true, recursive: true });
    mkdirSync(dirname(typesLink), { recursive: true });
    symlinkSync(typesTarget, typesLink, linkType);
  }
}

/** The boot module a dev build compiles: it mounts the page through the generated tables, which
 *  the runtime replaces from the dev data file as the dev command rebuilds them. The tables are
 *  one object literal, so the build can hand the same shape to the runtime as plain parsed data
 *  (see runtime/app/dev.ts). */
export function devBootSource(buildDir: string, absolute = false): string {
  const runtimeModule = (file: string): string =>
    absolute ? join(RUNTIME, file).split("\\").join("/") : importPath(buildDir, join(RUNTIME, file));
  return [
    "// Generated by native. Builds the DOM before any user module runs.",
    `import { mountDev } from ${JSON.stringify(runtimeModule("app/dev.ts"))};`,
    `import * as G from "./gen.ts";`,
    "const t = {",
    ...TABLE_FIELDS.map(([f, g]) => `  ${f}: G.${g},`),
    "};",
    "mountDev(t);",
    "",
  ].join("\n");
}

/** The host objects a build compiles: the platform's own source and the portable engine sources,
 *  each to its own object, cached in the build directory. The key covers every source's content
 *  and the toolchain that compiles it — not either one's mtime. The toolchain belongs in the key:
 *  a build directory that arrives from another machine holds objects for that machine's ABI and
 *  runtime, and linking them here would mix two C runtimes in one process. */
interface HostObjectsPlan {
  sources: string[];
  objects: string[];
  builds: { cc: string; args: string[] }[];
  key: string;
  /** A line to print when the build could not precompile the compositor's Metal shaders. */
  note: string;
}

function hostObjectsPlan(buildDir: string): HostObjectsPlan {
  const sources = hostSources(HOST);
  // The macOS host includes the compositor's shaders as a header this prepares: the metallib
  // the app carries, or the source it compiles when the build had no Metal toolchain.
  const shaders = buildingWindows() ? null : prepareMetalShaders(HOST, buildDir);
  const includeDirs = shaders === null ? [] : [buildDir];
  const objects = sources.map((source) => join(buildDir, basename(source).replace(/\.(m|c|cpp)$/, ".o")));
  const builds = sources.map((source, i) =>
    i === 0
      ? hostCompileCommand(source, objects[i], process.platform, buildTarget(), includeDirs)
      : isCompositorBackend(source)
        ? hostCompositorCompileCommand(source, objects[i])
        : hostCommonCompileCommand(source, objects[i], HOST));
  const key = createHash("sha256")
    .update(sources.map(hostSourceDigest).join("\0"))
    .update("\0")
    .update(shaders === null ? "" : shaders.key)
    .update("\0")
    .update(builds
      .map((build) => [build.cc, ...build.args.filter((arg) => !sources.includes(arg) && !objects.includes(arg))].join("\0"))
      .join("\0"))
    .digest("hex");
  return { sources, objects, builds, key, note: shaders === null ? "" : shaders.note };
}

/** The content and toolchain digest of the host objects a build directory would compile. */
export function hostBuildKey(buildDir: string): string {
  return hostObjectsPlan(buildDir).key;
}

/** Compiles the host objects into `buildDir` when the keyed ones aren't there, and writes the
 *  host's ffi.json beside them. Answers the objects. */
export function buildHostObjects(buildDir: string): string[] {
  const { sources, objects, builds, key, note } = hostObjectsPlan(buildDir);
  if (note !== "") {
    process.stderr.write(`native: ${note}; the app will compile the shaders when it starts\n`);
  }
  const keyFile = objects[0] + ".key";
  if (!objects.every((obj) => existsSync(obj)) || !existsSync(keyFile) || readFileSync(keyFile, "utf8") !== key) {
    for (let i = 0; i < sources.length; i++) {
      const build = builds[i];
      // The compiler's own diagnostics are what says why a host didn't build, so they are
      // captured rather than inherited: a runner that loses a child's console still gets them.
      const cc = spawnSync(build.cc, build.args, { encoding: "utf8" });
      const said = `${cc.stdout ?? ""}${cc.stderr ?? ""}`.trim();
      if (cc.status !== 0) {
        // Say what the compiler said, and when it said nothing, what was run and how it ended.
        if (said !== "") process.stderr.write(said + "\n");
        const failure = cc.error !== undefined ? cc.error.message : `exit ${cc.status}`;
        // The one line a gate prints is the last one, so the compiler's first error rides along.
        const firstError = said.split("\n").find((line) => /error|fatal/i.test(line)) ?? "";
        const detail = firstError === "" ? "" : " — " + firstError.trim();
        die(`failed to compile the native host: ${failure}${detail}`);
      } else if (said !== "") {
        process.stderr.write(said + "\n");
      }
    }
    writeFileSync(keyFile, key);
  }
  const manifest = JSON.parse(readFileSync(join(HOST, "ffi.json"), "utf8"));
  manifest.libraries = objects;
  // A Windows build links the import library for the system's winsqlite3.dll beside the host's
  // own objects; there is no sqlite3 to link the way Linux and macOS link theirs.
  if (buildingWindows()) manifest.libraries.push(windowsSqliteImportLibrary(HOST, buildDir));
  applyHostLink(manifest);
  writeFileSync(join(buildDir, "ffi.json"), JSON.stringify(manifest, null, 2));
  return objects;
}

/** Writes the build directory and runs scriptc. In a dev build the executable mounts the page
 *  through runtime/app/dev.ts, which reloads tables from the dev data file as they change; a
 *  release build writes the tables into its bundle and its executable reads them there, so a
 *  build whose program matches the one the executable was built from skips scriptc entirely.
 *  A build whose inputs match one an earlier build stored reuses that build's executable. */
export async function emitApp(built: AppBuild, out: string | null, dev: boolean = false, fastHint?: string,
  info: AppInfo | null = null, progress?: BuildProgress, release: boolean = false): Promise<BuildResult> {
  const { appDir, app } = built;
  const t0 = performance.now();
  const buildDir = join(appDir, ".native");
  const srcOut = join(buildDir, "src");
  const wanted = outputPath(appDir, out);
  const paths = outputPaths(wanted, built.bundle !== null);
  const output = paths.executable;
  // The cache is consulted before anything in the build directory is touched: a hit means
  // none of it is written.
  const cache = BuildCache.open();
  const fast = cache === null ? "" : fastHint ?? fastKey({ appDir, out: wanted, dev, packaged: info !== null, root: ROOT, input: built.htmlPath });
  if (cache !== null) {
    const hit = cache.lookupFast(fast);
    // A release build reads its page tables from the bundle, so an entry without them can't
    // answer it: the build goes on and stores an entry that has them.
    if (hit !== null && (dev || hit.pageTables)) {
      progress?.finish();
      return reuseBuild(cache, hit, paths, dev, appDir, app, t0, false,
        built.bundle === null ? hit.assets : built.bundle.files, app.title, info, release);
    }
  }
  rmSync(srcOut, { recursive: true, force: true });
  mkdirSync(srcOut, { recursive: true });

  // The generated modules and the app's copied sources are ES modules whatever package the app
  // sits in; without this, an app inside a CommonJS package would have its build dir read as CommonJS.
  writeFileSync(join(buildDir, "package.json"), '{ "type": "module" }\n');
  // A dev build's executable carries the tables it first mounts and reloads newer ones from the
  // dev data file. A release build's tables are data in the bundle instead (see
  // runtime/app/page.ts), so the page is not compiled into its executable at all: an edit to the
  // markup or styles rewrites that file and needs nothing compiled.
  if (dev) writeFileSync(join(buildDir, "gen.ts"), app.genSource);
  else rmSync(join(buildDir, "gen.ts"), { force: true });
  if (dev) writeDevData(appDir, app);
  linkScriptcTypes(buildDir);
  const boot = ["// Generated by native. Builds the DOM before any user module runs."];
  if (dev) {
    boot.push(...devBootSource(buildDir).split("\n"));
  } else {
    boot.push(
      // The tables are data in the app's bundle, which the runtime reads as the app starts.
      `import { mountPage } from ${JSON.stringify(importPath(buildDir, join(RUNTIME, "app/page.ts")))};`,
      "mountPage();",
      "",
    );
  }
  writeFileSync(join(buildDir, "boot.ts"), boot.join("\n"));

  const copied = copySources(appDir, srcOut);
  let jsxEntry: string | null = null;
  if (copied.jsx) {
    const jsx = jsxSettings(appDir, dev);
    writeJsxTsconfig(buildDir, srcOut, jsx);
    jsxEntry = installJsxRuntime(appDir, srcOut, copied, jsx);
  } else if (!existsSync(join(appDir, "tsconfig.json"))) {
    // scriptc reads the nearest tsconfig to the entry. Without one, every vendored dependency
    // under .native/src/deps is a project source, so a package's shipped JavaScript is checked
    // like the app's own; the file is what marks the entry as the project and the copies as
    // dependencies. An app with its own tsconfig keeps it: it names settings this one can't.
    writeProjectTsconfig(buildDir);
  }
  // The DOM names a vendored package's declarations use resolve to the runtime's classes and
  // types, the way a browser's lib.dom.d.ts resolves them in an ordinary web app. A JSX build
  // type-checks with .native/tsconfig.json, which carries the app's JSX settings and no lib, so
  // the app's own lib.dom.d.ts never reaches scriptc; a build without JSX leaves the app's
  // tsconfig for scriptc to read, and an app that already names DOM there has the browser's
  // declarations, which these would duplicate.
  // A declaration that asks for the browser's DOM library already declares the names
  // dom-globals.ts would; two declarations can't coexist (see declarationsLoadDomLib).
  const writeDomGlobals = !declarationsLoadDomLib(buildDir) && (copied.jsx || !appNamesDomLib(buildDir));
  if (writeDomGlobals) {
    writeFileSync(join(buildDir, "dom-globals.ts"), domGlobalsModule(RUNTIME, nodeTypesInstalled(buildDir)));
  } else {
    // A build of this app may have written it before the app named DOM in its tsconfig.
    rmSync(join(buildDir, "dom-globals.ts"), { force: true });
  }
  // A page's classic scripts share one scope, as they share the global object in a browser: they
  // are written into one module in document order, and the page's handler attributes are attached
  // in that same scope, so `onload="start()"` can call a function the first script declares. A
  // module script keeps its declarations to itself and is imported where it sits.
  const entryImports: string[] = [];
  if (writeDomGlobals) entryImports.push(`import "./dom-globals.ts";`);
  if (jsxEntry !== null) entryImports.push(`import ${JSON.stringify(importPath(buildDir, jsxEntry))};`);
  const classic = app.scripts.filter((s) => !s.module);
  const bundle = classic.length > 0 ? writeClassicScripts(srcOut, classic, app.handlers, appDir, built.htmlPath) : null;
  let handlerFile: string | null = null;
  if (bundle === null && app.handlers.length > 0) {
    const out = join(srcOut, ".handlers.js");
    handlerFile = out;
    const lines = [
      "// Generated by native: the page's inline event handler attributes, in document order.",
      `import { attachHandler } from ${JSON.stringify(importPath(dirname(out), join(RUNTIME, "app.ts")))};`,
    ];
    for (const h of app.handlers) {
      lines.push(`attachHandler(${h.node}, ${JSON.stringify(h.type)}, function (this: any, event: any): any {`);
      lines.push(h.code);
      lines.push("});");
    }
    writeFileSync(out, withDomImports(lines.join("\n") + "\n", out, undefined, undefined,
      { appDir, baseFile: built.htmlPath }));
    entryImports.push(`import ${JSON.stringify(importPath(buildDir, out))};`);
  }
  // The bundle is imported where the first of its scripts sits, and a module script where it sits:
  // the page's scripts run in the order a browser would run them.
  let inlineIndex = 0;
  let bundled = false;
  const inlineFiles: { file: string; line: number }[] = [];
  for (const s of app.scripts) {
    if (!s.module) {
      if (!bundled && bundle !== null) {
        entryImports.push(`import ${JSON.stringify(importPath(buildDir, bundle))};`);
        bundled = true;
      }
      continue;
    }
    if (s.path !== null) {
      entryImports.push(`import ${JSON.stringify(importPath(buildDir, join(srcOut, relative(appDir, s.path))))};`);
      continue;
    }
    const outFile = join(srcOut, `.inline-${inlineIndex++}.js`);
    writeFileSync(outFile, withDomImports(s.text, outFile, false, true,
      { appDir, baseFile: built.htmlPath }));
    inlineFiles.push({ file: outFile, line: s.line });
    entryImports.push(`import ${JSON.stringify(importPath(buildDir, outFile))};`);
  }
  if (dev) {
    // Where the modules a stack frame names came from, for the runtime that reports an
    // exception against the developer's own files (see runtime/app/source-map.ts).
    writeDevSources({
      appDir,
      htmlPath: built.htmlPath,
      app,
      sdk: ROOT,
      srcOut,
      appFiles: copied.appFiles,
      vendored: copied.bySource,
      inlineFiles,
      classicBundle: bundle,
      handlerFile,
      firstClassicLine: classic.length > 0 ? classic[0].line : 1,
      firstHandlerLine: app.handlers.length > 0 ? app.handlers[0].line : 1,
    });
  }
  writeFileSync(join(buildDir, "entry.ts"), [
    "// Generated by native.",
    // The web Worker members the runtime adds to the worker_threads class, for the page's types.
    `import ${JSON.stringify(importPath(buildDir, join(RUNTIME, "worker-types.ts")))};`,
    `import "./boot.ts";`,
    ...entryImports,
    `import { document } from ${JSON.stringify(importPath(buildDir, join(RUNTIME, "dom.ts")))};`,
    `import { run } from ${JSON.stringify(importPath(buildDir, join(RUNTIME, "app.ts")))};`,
    "document.currentScript = null;",
    "run();",
    "",
  ].join("\n"));

  // Native host: the objects cached per build directory, and the ffi manifest beside them.
  progress?.phase("host");
  buildHostObjects(buildDir);

  // The program is written; only the page's tables are missing from it, since a release build
  // carries them as data. A build whose program is byte for byte the one the executable at this
  // path was built from has nothing for scriptc to do: it writes the new tables and the app's
  // files beside the executable it already has.
  const files = programManifest(buildDir);
  const identity = programIdentity({ appDir, out: wanted, dev, packaged: info !== null, root: ROOT, input: built.htmlPath }, files);
  if (!dev && paths.resources !== "") {
    const record = readBuildRecord(appDir, output);
    const existing = record !== null && existsSync(output) ? statSync(output) : null;
    if (record !== null && existing !== null && record.program === identity &&
        record.size === existing.size && record.mtimeMs === existing.mtimeMs) {
      progress?.phase("packaging");
      const assets = installBundle(paths, output, app.title, built.bundle === null ? [] : built.bundle.files, info);
      writePageData(paths.resources, app);
      packageRelease(paths, info, release);
      writeManifest(appDir, files);
      const nativeMs = built.frontEndMs + (performance.now() - t0);
      progress?.finish();
      report(paths.bundle ?? output, existing.size, summaryOf(app), nativeMs, "skipped", assets);
      return { output, resources: paths.resources, assets, nativeMs, scriptcMs: 0, cached: false, app };
    }
  }

  ensureOutputDir(output);
  const t1 = performance.now();
  // scriptc writes the program's LLVM IR next to the executable (<entry>.ll); remove it after the
  // build unless a file of that name was already there.
  const irFile = join(dirname(output), "entry.ll");
  const irExisted = existsSync(irFile);
  const scArgs = ["build", join(buildDir, "entry.ts"), "--ffi", join(buildDir, "ffi.json")];
  // A bundler defines process.env.NODE_ENV for the libraries it compiles, and packages such as
  // React branch on it: the development build reports every warning in detail, the production one
  // strips them. Without the define the compiler sees `process.env.NODE_ENV === "production"` as
  // false whatever the build is, so every app ships the development build — larger, and slower to
  // start — and React's development build fails at run time on scriptc 0.4.15.
  scArgs.push("--define", nodeEnvDefine(dev));
  // A dev build compiles at -O0 with scriptc's cached object shards: faster to rebuild, and it
  // leaves breakpoints in the executable. A release build ships without the symbol and debug
  // tables the linker keeps by default, which no app needs at run time: they are a tenth of a
  // small app's executable, and far more of a large one.
  if (dev) scArgs.push("--optimization", "dev");
  else scArgs.push("--strip");
  // A Windows app is a windowed program: without the GUI subsystem Windows opens a console
  // window behind it, which a page has no use for. Its output still goes to whatever handles it
  // was started with, which is how a headless run prints what its steps did.
  if (buildingWindows()) scArgs.push("--windows-subsystem", "gui");
  scArgs.push("-o", output);
  progress?.beginScriptc();
  // scriptc compiles an executable's LLVM in partitions, one thread per lane, but it uses more
  // than one only when SCRIPTC_LANES asks. A dev rebuild is the case that can use every core:
  // the window is waiting on it. An explicit setting from the environment still wins.
  const baseEnv = scriptcEnv();
  const scEnv = dev && (baseEnv.SCRIPTC_LANES === undefined || baseEnv.SCRIPTC_LANES === "")
    ? { ...baseEnv, SCRIPTC_LANES: String(availableParallelism()) }
    : baseEnv;
  // The progress reader is the only consumer of scriptc's timing lines: without one, the run is
  // exactly the one it was before, and a user's SCRIPTC_TIMING output stays in the build's log.
  // The compiler's frontend is a JavaScript program, so the build hands it a heap sized to the
  // machine (see scriptcEnv).
  const sc = progress === undefined
    ? await runScriptc(scArgs, scEnv)
    : await runScriptc(scArgs, { ...scEnv, SCRIPTC_TIMING: "1" }, (event) => progress.scriptc(event.phase));
  // Point diagnostics in copied sources back at the originals, on their original lines.
  // A diagnostic in a copy points at the file the app installed.
  const origins = [...copied.bySource].map(([source, out]) => [out, source] as const);
  const fix = (s: string) => {
    let text = s;
    for (const [out, source] of origins) text = text.split(out).join(source);
    // A message can quote the specifier the app wrote, as the build rewrote it to reach the copy
    // ("Module '\"./deps/@ui-sdk/react/dist/slider.js\"' has no exported member"). Name the
    // specifier the app wrote instead.
    for (const [out] of origins) {
      const spec = copied.specs.get(out);
      if (spec === undefined || spec.startsWith(".")) continue;
      const rel = relative(srcOut, out).split("\\").join("/");
      text = text.split(`"./${rel}"`).join(`"${spec}"`).split(`'./${rel}'`).join(`'${spec}'`);
    }
    return withoutSdkWarnings(text, ROOT, [process.cwd(), buildDir], (abs) => relative(process.cwd(), abs.split(srcOut + "/").join(appDir + "/"))).split(srcOut + "/").join(appDir + "/");
  };
  if (!irExisted && existsSync(irFile)) rmSync(irFile, { force: true });
  const printed = (sc.status !== 0 && sc.stdout ? fix(sc.stdout) : "") + (sc.stderr ? fix(sc.stderr) : "");
  if (printed !== "") {
    // The compiler's warnings and errors take lines of their own; the running phase redraws below.
    progress?.interrupt();
    process.stderr.write(printed);
  }
  if (sc.status !== 0) {
    // The gate prints only the last line of a failed build, so the first error rides in this one.
    // The compiler's own error first: a hint or a usage line can match "error" without being
    // the thing that failed.
    const lines = printed.split("\n").map((line) => line.trim()).filter((line) => line !== "");
    const first = lines.find((line) => /^\S+:\d+:\d+: error|^error\b|undefined symbol|LNK\d{4}|^fatal/i.test(line))
      ?? lines.find((line) => /error|undefined symbol|LNK\d|fatal/i.test(line) && !/^hint:/i.test(line) && !line.startsWith("native:"))
      ?? "";
    const how = sc.error !== undefined ? sc.error.message : `exit ${sc.status}`;
    die(`scriptc build failed: ${how}` + (first === "" ? "" : " — " + first));
  }

  // The app's own files, the page's tables, and the macOS wrapper that makes them a Finder app.
  progress?.phase("packaging");
  const assets = installBundle(paths, output, app.title, built.bundle === null ? [] : built.bundle.files, info);
  if (paths.resources !== "") writePageData(paths.resources, app);
  // A release build is signed after everything the bundle holds is in place.
  packageRelease(paths, info, release);

  const t2 = performance.now();

  const written = statSync(output);
  const size = written.size;
  const summary = summaryOf(app);
  const nativeMs = built.frontEndMs + (t1 - t0);
  const scriptcMs = t2 - t1;
  // Remember the program this executable compiles, so an edit to the page alone can keep it, and
  // how long scriptc took, so the next build's progress can estimate where it is.
  if (!dev) writeBuildRecord(appDir, output, { program: identity, size, mtimeMs: written.mtimeMs, scriptcMs });
  // Store the executable, its tables and everything needed to answer the same build without
  // scriptc, keyed by every module that went into it.
  if (cache !== null) {
    cache.save({
      key: programKey(fast, files),
      fast,
      out: output,
      dev,
      bin: output,
      devData: dev ? devDataPath(appDir) : null,
      pageData: dev ? null : pageDataPath(paths.resources),
      program: identity,
      summary,
      stderr: printed,
      diagnostics: built.diagnostics,
      files,
      assets: built.bundle === null ? [] : built.bundle.files,
      title: app.title,
    });
    writeManifest(appDir, files);
  }
  progress?.finish();
  report(paths.bundle ?? output, size, summary, nativeMs, scriptcMs, assets);
  return { output, resources: paths.resources, assets, nativeMs, scriptcMs, cached: false, app };
}

/** The app's product metadata for a bundled build, and the problems reading it, printed once. */
function appInfoFor(htmlPath: string, bundled: boolean): AppInfo | null {
  if (!bundled) return null;
  const info = appInfoOf(htmlPath);
  for (const warning of info.warnings) console.error(`native: ${warning}`);
  return info;
}

export async function build(input: string, out: string | null, dev: boolean = false, release: boolean = false): Promise<BuildResult> {
  const t0 = performance.now();
  const htmlPath = htmlPathOf(input);
  const appDir = dirname(htmlPath);
  const wanted = outputPath(appDir, out);
  const paths = outputPaths(wanted, !dev);
  const info = appInfoFor(htmlPath, !dev);
  const cache = BuildCache.open();
  const fast = cache === null ? undefined : fastKey({ appDir, out: wanted, dev, packaged: info !== null, root: ROOT, input: htmlPath });
  if (cache !== null && fast !== undefined) {
    const hit = cache.lookupFast(fast);
    if (hit !== null && (dev || hit.pageTables)) {
      const result = reuseBuild(cache, hit, paths, dev, appDir, null, t0, true, hit.assets, hit.title, info, release);
      if (result.resources !== "") writeUpdateConfig(result.resources, htmlPath);
      return result;
    }
  }
  // How long this app's last compile took estimates the one that is starting. A build of the same
  // app and output only records one after a compile, so a first build shows elapsed time alone.
  const progress = new BuildProgress({ estimateMs: readBuildRecord(appDir, paths.executable)?.scriptcMs ?? 0 });
  try {
    progress.phase("resolving");
    const result = await emitApp(openApp(input, !dev), out, dev, fast, info, progress, release);
    // The update check is data in the bundle, like the page tables: writing it needs no compile,
    // and a manifest edit that adds or drops update_url lands with the next build.
    if (result.resources !== "") writeUpdateConfig(result.resources, htmlPath);
    return result;
  } catch (err) {
    progress.fail();
    throw err;
  }
}
