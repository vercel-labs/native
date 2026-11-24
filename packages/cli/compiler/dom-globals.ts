// The DOM names a page's scripts share with a browser, as the build's type world declares them:
// each is the class, type or value the runtime module of that name exports. A vendored package's
// declaration files name the DOM without importing it, as a browser's lib.dom.d.ts provides it,
// and this module is what makes those names resolve to what Native SDK implements rather than to
// a browser the app doesn't run in.
//
// A name the runtime doesn't implement stays undeclared, so a declaration that uses it fails to
// type-check with "Cannot find name" at the place that needs it, instead of being typed as
// something the app can't run.

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { GLOBALS } from "./globals.ts";

/** The names Node's declarations already give a program, whatever version of @types/node it
 *  type-checks with. Declaring one again would be a duplicate identifier, and the declarations
 *  Node has are the web-standard shapes (Event, Headers, fetch, ...) the page's runtime
 *  implements. */
const NODE_DECLARED = new Set([
  "Blob",
  "Event",
  "EventTarget",
  "File",
  "Headers",
  "MessageEvent",
  "Request",
  "Response",
  "fetch",
  "localStorage",
  "sessionStorage",
]);

/** Names only scriptc's bundled Node declarations supply (`scriptc-node-fallback.d.ts`), for a
 *  project with no @types/node: Node 24 has them as globals, but @types/node leaves them out. */
const FALLBACK_DECLARED = new Set([
  "AddEventListenerOptions",
  "CustomEvent",
  "Navigator",
  "navigator",
]);

/** Names only a project's own @types/node supplies: the undici-backed globals. */
const PROJECT_NODE_DECLARED = new Set([
  "EventSource",
  "FormData",
  "Storage",
  "WebSocket",
]);

/**
 * Every name Node's declarations may supply, so a build that leaves the name to its type world
 * gets Node's meaning rather than the runtime's. A name here keeps its runtime import even when a
 * source only names it as a type.
 */
export const NODE_SUPPLIED = new Set([
  ...NODE_DECLARED,
  ...FALLBACK_DECLARED,
  ...PROJECT_NODE_DECLARED,
]);

/** A declared name's meanings: a type, a value, or both (a class or an enum). */
const TYPE = 1;
const VALUE = 2;

/** What a module exports: its own declarations, the names it imports, and how it re-exports. */
interface Module {
  /** Declared here, as TYPE and VALUE bits: `class` and `enum` are both. */
  kinds: Map<string, number>;
  /** The declaration's form, which decides how a global names it: an interface may extend it,
   *  and a type alias may be a union an interface cannot extend. */
  shapes: Map<string, "class" | "interface" | "type">;
  /** A declaration's own type parameters, such as `<T = unknown>`, kept so a global alias is as
   *  generic as what it names. */
  params: Map<string, string>;
  /** A local name and the module it was imported from. */
  imports: Map<string, { file: string; name: string }>;
  /** An exported name and the local name it re-exports. */
  locals: Map<string, string>;
  /** An exported name and the module (and name there) it re-exports. */
  remote: Map<string, { file: string; name: string }>;
  /** Exports written `export type { … }`: the names exist only in the type world, whatever the
   *  module they come from declares. */
  typeOnly: Set<string>;
  /** `export * from` targets. */
  stars: string[];
}

const DECLARED = /^export\s+(?:((?:abstract\s+)?class)|(type|interface)|(const|let|var|function)|(enum))\s+([A-Za-z_$][\w$]*)(<[^>\n]*>)?/gm;
const IMPORTED = /^import\s+(?:type\s+)?(?:\{([^}]*)\}|([A-Za-z_$][\w$]*))\s*from\s*(["'])([^"']+)\3/gm;
const EXPORTED_FROM = /^export\s+(type\s+)?\{([^}]*)\}\s*from\s*(["'])([^"']+)\3/gm;
const EXPORTED_LOCAL = /^export\s+(type\s+)?\{([^}]*)\}\s*;?\s*$/gm;
const EXPORTED_STAR = /^export\s+\*\s*from\s*(["'])([^"']+)\1/gm;

/** The `a, b as c` list a braces clause holds, as `[local, exported]` pairs. */
function names(clause: string): [string, string][] {
  const out: [string, string][] = [];
  for (const part of clause.split(",")) {
    const bits = part.trim().split(/\s+as\s+/);
    if (bits[0] === "") continue;
    out.push([bits[0], bits[1] ?? bits[0]]);
  }
  return out;
}

function moduleAt(file: string, cache: Map<string, Module>): Module {
  const hit = cache.get(file);
  if (hit !== undefined) return hit;
  const mod: Module = { kinds: new Map(), shapes: new Map(), params: new Map(), imports: new Map(), locals: new Map(), remote: new Map(), typeOnly: new Set(), stars: [] };
  cache.set(file, mod); // before the walk, so an import cycle ends
  let text = "";
  try {
    text = readFileSync(file, "utf8");
  } catch {
    // A runtime module that isn't there exports nothing; the globals it would have declared go
    // undeclared, and a declaration that needs them reports its own missing name.
  }
  for (const m of text.matchAll(DECLARED)) {
    const bits = m[1] !== undefined || m[4] !== undefined ? TYPE | VALUE : m[2] !== undefined ? TYPE : VALUE;
    mod.kinds.set(m[5], (mod.kinds.get(m[5]) ?? 0) | bits);
    if (m[1] !== undefined || m[4] !== undefined) mod.shapes.set(m[5], "class");
    else if (m[2] === "interface") mod.shapes.set(m[5], "interface");
    else if (m[2] === "type") mod.shapes.set(m[5], "type");
    if (m[6] !== undefined) mod.params.set(m[5], m[6]);
  }
  for (const m of text.matchAll(IMPORTED)) {
    const from = join(dirname(file), m[4]);
    if (m[2] !== undefined) mod.imports.set(m[2], { file: from, name: "default" });
    else for (const [local, remote] of names(m[1])) mod.imports.set(local, { file: from, name: remote });
  }
  for (const m of text.matchAll(EXPORTED_FROM)) {
    const from = join(dirname(file), m[4]);
    for (const [remote, exported] of names(m[2])) {
      mod.remote.set(exported, { file: from, name: remote });
      if (m[1] !== undefined) mod.typeOnly.add(exported);
    }
  }
  for (const m of text.matchAll(EXPORTED_LOCAL)) {
    for (const [local, exported] of names(m[2])) {
      mod.locals.set(exported, local);
      if (m[1] !== undefined) mod.typeOnly.add(exported);
    }
  }
  for (const m of text.matchAll(EXPORTED_STAR)) mod.stars.push(join(dirname(file), m[2]));
  return mod;
}

/** What `name` is in `file`: its TYPE and VALUE bits and its type parameters. Follows re-exports,
 *  so a name dom.ts re-exports from another runtime module is as real as one it declares. */
function lookup(file: string, name: string, cache: Map<string, Module>, seen = new Set<string>()): { bits: number; params: string; shape: "class" | "interface" | "type" | null } | null {
  const key = `${file}\u0000${name}`;
  if (seen.has(key)) return null;
  seen.add(key);
  const mod = moduleAt(file, cache);
  const bits = mod.kinds.get(name);
  if (bits !== undefined) return { bits, params: mod.params.get(name) ?? "", shape: mod.shapes.get(name) ?? null };
  const onlyType = mod.typeOnly.has(name);
  const only = (hit: ReturnType<typeof lookup>): ReturnType<typeof lookup> =>
    hit === null || !onlyType ? hit : { ...hit, bits: hit.bits & ~VALUE };
  const local = mod.locals.get(name);
  if (local !== undefined) {
    const imported = mod.imports.get(local);
    return only(imported === undefined ? lookup(file, local, cache, seen) : lookup(imported.file, imported.name, cache, seen));
  }
  const remote = mod.remote.get(name);
  if (remote !== undefined) return only(lookup(remote.file, remote.name, cache, seen));
  for (const star of mod.stars) {
    const hit = lookup(star, name, cache, seen);
    if (hit !== null) return hit;
  }
  return null;
}

/** The names among `names` that the runtime module `file` exports as values. GLOBALS lists the
 *  names user code may refer to; the module's own declarations say which of them exist at run
 *  time, so a name listed as a value but declared only as a type stays out. */
export function runtimeValueNames(runtimeDir: string, file: string, names: readonly string[]): string[] {
  const cache = new Map<string, Module>();
  const found: string[] = [];
  for (const name of names) {
    const hit = lookup(join(runtimeDir, file), name, cache);
    if (hit !== null && (hit.bits & VALUE) !== 0) found.push(name);
  }
  return found;
}

/** The classes a runtime module declares itself, whatever name user code knows them by. An
 *  island needs their method tables even when the class is no global binding (DOMTokenList comes
 *  from `element.classList`), because an object of one can come back from a getter or a call. */
export function runtimeClassNames(runtimeDir: string, file: string): string[] {
  const mod = moduleAt(join(runtimeDir, file), new Map());
  const out: string[] = [];
  for (const [name, shape] of mod.shapes)
    if (shape === "class" && ((mod.kinds.get(name) ?? 0) & VALUE) !== 0) out.push(name);
  return out.sort();
}

/** A DOM global: where it comes from, and whether it is a value and a type. */
interface Global {
  file: string;
  value: boolean;
  type: boolean;
  /** The runtime declaration's form: an interface (which a global interface can extend) or a
   *  type alias (which it cannot when the alias may be a union). */
  shape: "class" | "interface" | "type";
  params: string;
}

/** The generated module that declares the DOM globals for the build's program. It has no code:
 *  every import is type-only, so including it costs a module load and nothing else.
 *
 *  `nodeTypes` says whether the build type-checks with the app's own @types/node, which decides
 *  which globals Node's declarations already provide. */
export function domGlobalsModule(runtimeDir: string, nodeTypes: boolean): string {
  const declared = (name: string): boolean =>
    NODE_DECLARED.has(name) || (nodeTypes ? PROJECT_NODE_DECLARED.has(name) : FALLBACK_DECLARED.has(name));
  const cache = new Map<string, Module>();
  const from = new Map<string, Global>();
  for (const g of GLOBALS) {
    const file = join(runtimeDir, g.file);
    for (const name of new Set([...g.values, ...g.types])) {
      if (declared(name)) continue;
      const found = lookup(file, name, cache);
      if (found === null) continue;
      const hit = from.get(name);
      if (hit !== undefined) {
        hit.value ||= (found.bits & VALUE) !== 0;
        hit.type ||= (found.bits & TYPE) !== 0;
      } else {
        from.set(name, {
          file: g.file,
          value: (found.bits & VALUE) !== 0,
          type: (found.bits & TYPE) !== 0,
          shape: found.shape ?? "type",
          params: found.params,
        });
      }
    }
  }
  // One type-only import per runtime module, naming the globals it supplies.
  const byFile = new Map<string, string[]>();
  for (const [name, { file }] of from) {
    const list = byFile.get(file) ?? [];
    list.push(name);
    byFile.set(file, list);
  }

  const lines = [
    "// Generated by native. The DOM names a page's scripts share with a browser, as the runtime",
    "// implements them: a vendored package's declarations resolve to these classes and types,",
    "// not to a browser's. A name the runtime doesn't implement is left undeclared, so using it",
    "// is a type error where it is used.",
    "",
  ];
  for (const [file, names] of byFile) {
    names.sort();
    lines.push(
      `import type { ${names.map((n) => `${n} as ${n}$impl`).join(", ")} } from ${JSON.stringify(join(runtimeDir, file))};`,
    );
  }
  lines.push("", "declare global {");
  for (const [name, { value, type, shape, params }] of from) {
    // An interface extends what the runtime declares, so it merges with a declaration an
    // installed package already makes in the program (a framework's empty DOM interfaces, say)
    // instead of colliding with it.
    if (type) lines.push(extendable(name, shape) ? `  ${interfaceAlias(name, params)}` : `  ${typeAlias(name, params)}`);
    if (value) lines.push(`  var ${name}: typeof ${name}$impl;`);
  }
  lines.push("}", "", "export {};", "");
  return lines.join("\n");
}

/** The name's type parameters as the arguments a runtime declaration takes, or "". */
function typeArgs(params: string): string {
  if (params === "") return "";
  const args = params
    .slice(1, -1)
    .split(",")
    .map((p) => p.trim().split(/\s+extends\s+|\s*=/)[0].trim())
    .filter((p) => p !== "");
  return `<${args.join(", ")}>`;
}

/** True when the global is an interface that extends the runtime's declaration, so it merges with
 *  one an installed package already makes in the program (a framework's empty DOM interfaces, as
 *  React's global.d.ts ships for projects without a DOM library).
 *
 *  A type alias is kept as a type alias where the runtime declared one: scriptc lowers an array
 *  alias as the array it is, and an interface wrapping it loses that. TouchList is the exception:
 *  React's empty DOM interfaces include it, so an alias would be a duplicate identifier, and no
 *  runtime code reads a TouchList the way it reads a NodeList. */
function extendable(name: string, shape: "class" | "interface" | "type"): boolean {
  return shape !== "type" || name === "TouchList";
}

/** `interface Name<params> extends Name$impl<args> {}`: a declaration that names
 *  `NodeListOf<HTMLElement>` keeps working, with the runtime declaration's own parameters and
 *  defaults carried over. */
function interfaceAlias(name: string, params: string): string {
  return `interface ${name}${params} extends ${name}$impl${typeArgs(params)} {}`;
}

/** `type Name<params> = Name$impl<args>`, for a runtime type alias an interface cannot extend. */
function typeAlias(name: string, params: string): string {
  return `type ${name}${params} = ${name}$impl${typeArgs(params)};`;
}
