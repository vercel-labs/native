// The app's Web Workers, found the way scriptc finds them: a `new Worker(...)` whose first
// argument names a file at build time. The file a URL names is a worker entry, a module script
// that runs on its own thread with the worker's globals rather than the page's; the compiler
// copies it like any other source but binds `self`, `postMessage` and the rest to the worker
// runtime. The construction itself stays in the app's source, because scriptc compiles a worker
// unit from the `new Worker(...)` it sees there; the rewrite only wraps the native worker in the
// web API the page expects.

import { existsSync, statSync } from "node:fs";
import { dirname, extname, isAbsolute, join, resolve } from "node:path";

/** One `new Worker(...)` in a source file: where it is, and the entry file it names, if the
 *  first argument is a URL or string literal the build can resolve. */
export interface WorkerConstruction {
  /** The index of the `new`. */
  start: number;
  /** The index just past the closing `)`. */
  end: number;
  /** The first argument, as written. */
  url: string;
  /** The entry file the first argument names, or null when it is computed. */
  file: string | null;
}

const EXTENSIONS = [".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs"];

/** True when the character at `i` is code rather than inside a string, template or comment. */
function isCode(text: string, i: number): boolean {
  let mode = 0; // 0 code, 1 line comment, 2 block comment, 3 single, 4 double, 5 template
  for (let k = 0; k < i; k++) {
    const c = text[k];
    const next = text[k + 1];
    switch (mode) {
      case 0:
        if (c === "/" && next === "/") { mode = 1; k++; }
        else if (c === "/" && next === "*") { mode = 2; k++; }
        else if (c === "'") mode = 3;
        else if (c === "\"") mode = 4;
        else if (c === "`") mode = 5;
        break;
      case 1:
        if (c === "\n") mode = 0;
        break;
      case 2:
        if (c === "*" && next === "/") { mode = 0; k++; }
        break;
      case 3:
        if (c === "\\") k++;
        else if (c === "'") mode = 0;
        break;
      case 4:
        if (c === "\\") k++;
        else if (c === "\"") mode = 0;
        break;
      case 5:
        if (c === "\\") k++;
        else if (c === "`") mode = 0;
        break;
    }
  }
  return mode === 0;
}

/** The index of the `)` that closes the `(` at `open`, skipping strings and comments; -1 when
 *  the file ends first. */
function closingParen(text: string, open: number): number {
  let depth = 0;
  let mode = 0;
  for (let i = open; i < text.length; i++) {
    const c = text[i];
    const next = text[i + 1];
    if (mode === 0) {
      if (c === "/" && next === "/") { mode = 1; i++; }
      else if (c === "/" && next === "*") { mode = 2; i++; }
      else if (c === "'") mode = 3;
      else if (c === "\"") mode = 4;
      else if (c === "`") mode = 5;
      else if (c === "(") depth++;
      else if (c === ")") { depth--; if (depth === 0) return i; }
    } else if (mode === 1) {
      if (c === "\n") mode = 0;
    } else if (mode === 2) {
      if (c === "*" && next === "/") { mode = 0; i++; }
    } else if (mode === 3) {
      if (c === "\\") i++;
      else if (c === "'") mode = 0;
    } else if (mode === 4) {
      if (c === "\\") i++;
      else if (c === "\"") mode = 0;
    } else {
      if (c === "\\") i++;
      else if (c === "`") mode = 0;
    }
  }
  return -1;
}

/** The top-level comma-separated arguments of a call, trimmed. */
function argumentsOf(text: string): string[] {
  const out: string[] = [];
  let start = 0;
  let depth = 0;
  let mode = 0;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    const next = text[i + 1];
    if (mode === 0) {
      if (c === "/" && next === "/") { mode = 1; i++; }
      else if (c === "/" && next === "*") { mode = 2; i++; }
      else if (c === "'") mode = 3;
      else if (c === "\"") mode = 4;
      else if (c === "`") mode = 5;
      else if (c === "(" || c === "[" || c === "{") depth++;
      else if (c === ")" || c === "]" || c === "}") depth--;
      else if (c === "," && depth === 0) { out.push(text.slice(start, i).trim()); start = i + 1; }
    } else if (mode === 1) {
      if (c === "\n") mode = 0;
    } else if (mode === 2) {
      if (c === "*" && next === "/") { mode = 0; i++; }
    } else if (mode === 3) {
      if (c === "\\") i++;
      else if (c === "'") mode = 0;
    } else if (mode === 4) {
      if (c === "\\") i++;
      else if (c === "\"") mode = 0;
    } else {
      if (c === "\\") i++;
      else if (c === "`") mode = 0;
    }
  }
  const last = text.slice(start).trim();
  if (last !== "") out.push(last);
  return out;
}

/** A string literal's value, or null when the text isn't one plain literal. */
function unescape(value: string): string {
  return value.replace(/\\(.)/g, (_m, c: string) =>
    c === "n" ? "\n" : c === "r" ? "\r" : c === "t" ? "\t" : c === "0" ? "\0" : c);
}

function literal(text: string): string | null {
  const m = /^(["'])((?:\\.|(?!\1)[\s\S])*)\1$/.exec(text.trim());
  if (m === null) return null;
  return unescape(m[2]);
}

/** True when the file declares a `Worker` of its own that isn't the web one, in which case its
 *  `new Worker(...)` is somebody else's constructor and not a worker entry. */
function declaresOwnWorker(text: string): boolean {
  if (/(?:^|\n)\s*(?:export\s+)?(?:abstract\s+)?class\s+Worker\b/.test(text)) return true;
  if (/(?:^|\n)\s*(?:export\s+)?(?:const|let|var|function)\s+Worker\b/.test(text)) return true;
  const imported = /(?:^|\n)\s*import\s+([^;\n]+?)\s+from\s+["']([^"']+)["']/g;
  for (const m of text.matchAll(imported)) {
    const clause = m[1];
    const from = m[2];
    if (from === "node:worker_threads" || from === "worker_threads") continue;
    if (/\bWorker\b/.test(clause)) return true;
  }
  return false;
}

/** The path a first argument names, resolved the way the worker runtime will resolve it: a URL
 *  against the module's own file, a plain string against the page. */
function entryPath(url: string, file: string, appDir: string): string | null {
  const trimmed = url.trim();
  const urlCall = /^new\s+URL\s*\(\s*(["'])((?:\\.|(?!\1)[\s\S])*)\1\s*,\s*import\.meta\.url\s*\)$/.exec(trimmed);
  if (urlCall !== null) {
    const spec = urlCall[2];
    if (spec === "") return null;
    const base = dirname(file);
    return isAbsolute(spec) ? spec : resolve(base, spec);
  }
  if (/^import\.meta\.url$/.test(trimmed)) return file;
  const plain = literal(trimmed);
  if (plain === null) return null;
  if (isAbsolute(plain)) return plain;
  // A relative string is resolved against the page's URL, as the web's worker URL is.
  return resolve(appDir, plain);
}

/** Every worker entry the app's sources name, with the file that constructs it. Files that
 *  declare their own `Worker` class are skipped. */
export function workerConstructs(text: string, file: string, appDir: string): WorkerConstruction[] {
  if (declaresOwnWorker(text)) return [];
  const out: WorkerConstruction[] = [];
  const re = /(^|[^\w$.])new\s+Worker\s*\(/g;
  for (const m of text.matchAll(re)) {
    const start = m.index! + m[1].length;
    if (!isCode(text, start)) continue;
    const open = text.indexOf("(", start);
    const close = closingParen(text, open);
    if (close === -1) continue;
    const args = argumentsOf(text.slice(open + 1, close));
    const url = args.length > 0 ? args[0] : "";
    out.push({ start, end: close + 1, url, file: entryPath(url, file, appDir) });
  }
  return out;
}

/** The worker entry files the app's sources construct: paths of existing source files. */
export function workerEntries(appDir: string, sources: { path: string; text: string }[]): Set<string> {
  const out = new Set<string>();
  for (const source of sources) {
    for (const c of workerConstructs(source.text, source.path, appDir)) {
      if (c.file === null) continue;
      const file = c.file;
      if (!EXTENSIONS.includes(extname(file))) continue;
      if (!existsSync(file) || !statSync(file).isFile()) continue;
      out.add(file);
    }
  }
  return out;
}

/** Rewrites each `new Worker(url, options?)` as `alias(new Worker(url))`: the constructor stays
 *  where scriptc can compile the worker entry, and the alias gives the page the web API.
 *  `imports` collects the alias import the rewritten file needs. */
export function rewriteWorkerConstructions(text: string, file: string, appDir: string, alias: string,
  modulePath: string): { text: string; changed: boolean; imports: string } {
  const constructions = workerConstructs(text, file, appDir);
  if (constructions.length === 0) return { text, changed: false, imports: "" };
  let out = text;
  for (let i = constructions.length - 1; i >= 0; i--) {
    const c = constructions[i];
    const args = argumentsOf(text.slice(text.indexOf("(", c.start) + 1, c.end - 1));
    let url = args.length > 0 ? args[0] : "";
    // scriptc compiles a worker entry named by a URL or an absolute path, not a relative string
    // (Node resolves that against the process's cwd). The web resolves it against the page, so
    // the build resolves it here and writes the absolute path the compiler can follow.
    if (literal(url) !== null && !isAbsolute(literal(url) as string) && c.file !== null) {
      url = JSON.stringify(c.file);
    }
    out = out.slice(0, c.start) + `${alias}(new Worker(${url}))` + out.slice(c.end);
  }
  return { text: out, changed: true, imports: `import { createWorker as ${alias} } from ${JSON.stringify(modulePath)}; ` };
}

export type { WorkerConstruction as WorkerSite };
export const WORKER_RUNTIME = "worker.ts";
export function workerRuntimePath(runtimeDir: string): string {
  return join(runtimeDir, WORKER_RUNTIME);
}
