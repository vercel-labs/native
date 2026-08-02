// The grammar completeness matrix: the subset means "TypeScript minus the
// ecosystem minus the purity violations" — NEVER "minus basic syntax". This
// suite enumerates the ENTIRE TS/ES grammar surface (every statement form,
// every expression/operator family, every declaration form) and pins each
// production to exactly one verdict:
//
//   emits   SUPPORTED — transpiles clean, and the emitted Zig compiles
//           (the zig half runs when a toolchain is on PATH).
//   gate    BANNED or deferred — stops with EXACTLY the named teaching rule
//           (NS9001 marks a genuine roadmap deferral with a tailored
//           message, never an accidental hole).
//   tsc     rejected by the type system / strict module semantics itself —
//           tsc's own diagnostic is the teacher (`with`, `export =`, JSX in
//           .ts, `this` under noImplicitThis, ...).
//   check   like `gate`, but asserted through the checker alone because the
//           fixture cannot be made tsc-clean (decorators).
//
// COMPLETENESS IS MACHINE-CHECKED: `productions` is the canonical grammar
// enumeration and the matrix must cover it exactly — a production missing
// from the table (or an unknown row) fails the suite, so the grammar can
// never grow a silent gap again.

import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { transpile, transpileFiles, checkOnly, ruleIds } from "./helpers.ts";

const pkg = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const hasZig = spawnSync("zig", ["version"], { stdio: "ignore" }).status === 0;

type Row =
  | { readonly verdict: "emits"; readonly src?: string; readonly files?: Record<string, string> }
  | { readonly verdict: "gate"; readonly id: string; readonly src?: string; readonly files?: Record<string, string> }
  | { readonly verdict: "tsc"; readonly src: string }
  | { readonly verdict: "check"; readonly id: string; readonly src: string };

/// The canonical enumeration. Grouped by grammar chapter; names are stable
/// row keys, not TS API names.
const productions: readonly string[] = [
  // ---- statements
  "stmt/const-declaration",
  "stmt/let-declaration",
  "stmt/let-uninitialized-typed",
  "stmt/var-declaration",
  "stmt/object-destructuring-const",
  "stmt/array-destructuring",
  "stmt/empty",
  "stmt/expression",
  "stmt/block",
  "stmt/if-else",
  "stmt/do-while",
  "stmt/while",
  "stmt/for-classic",
  "stmt/for-multi-init-comma-incrementor",
  "stmt/for-countdown",
  "stmt/for-in",
  "stmt/for-of",
  "stmt/for-of-entries",
  "stmt/for-await-of",
  "stmt/continue",
  "stmt/continue-labeled",
  "stmt/break",
  "stmt/break-labeled",
  "stmt/labeled-loop",
  "stmt/labeled-block",
  "stmt/labeled-unreferenced",
  "stmt/return",
  "stmt/switch-union-kind",
  "stmt/switch-union-kind-default",
  "stmt/switch-value-default",
  "stmt/switch-plain-number",
  "stmt/switch-plain-string",
  "stmt/throw",
  "stmt/throw-heterogeneous",
  "stmt/catch-kind-narrowing",
  "stmt/throw-error-object",
  "stmt/try-catch-finally",
  "stmt/try-unsafe-finally",
  "stmt/with",
  "stmt/debugger",
  // ---- declarations & module surface
  "decl/function",
  "decl/function-nested",
  "decl/function-generator",
  "decl/function-async",
  "decl/function-generic",
  "decl/class",
  "decl/class-extends",
  "decl/class-accessor",
  "decl/class-static",
  "decl/class-static-mutable",
  "decl/class-private-keyword",
  "decl/class-private-hash",
  "decl/class-generic",
  "decl/interface",
  "decl/interface-generic",
  "decl/type-alias",
  "decl/enum",
  "decl/namespace",
  "decl/decorator",
  "decl/module-let",
  "decl/parameter-default",
  "decl/parameter-rest",
  "decl/parameter-destructuring",
  "decl/import-named",
  "decl/import-type",
  "decl/import-namespace",
  "decl/import-namespace-sdk",
  "decl/import-default",
  "decl/import-equals",
  "decl/export-named",
  "decl/export-default",
  "decl/export-assignment",
  "decl/export-list",
  "decl/export-list-renamed",
  "decl/re-export-value",
  "decl/re-export-value-renamed",
  "decl/re-export-star",
  "decl/re-export-type-only",
  // ---- expressions: literals & templates
  "expr/literal-number",
  "expr/literal-bigint",
  "expr/literal-string",
  "expr/literal-boolean-null",
  "expr/literal-regex",
  "expr/template-no-substitution",
  "expr/template-with-holes",
  "expr/template-tagged",
  "expr/array-literal-spread",
  "expr/object-literal-spread",
  "expr/object-literal-shorthand",
  "expr/object-literal-computed-key",
  "expr/object-literal-accessor",
  // ---- expressions: access & calls
  "expr/property-access",
  "expr/element-access",
  "expr/optional-chain-property",
  "expr/optional-chain-call",
  "expr/optional-chain-element",
  "expr/call-function",
  "expr/call-recursive",
  "expr/call-spread-arguments",
  "expr/arguments-object",
  "expr/new-uint8array",
  "expr/new-class",
  "expr/new-map-set",
  "expr/new-function",
  "expr/new-regexp",
  "expr/new-promise",
  "expr/new-date",
  // ---- expressions: functions as values
  "expr/arrow-callback",
  "expr/function-reference-callback",
  "expr/arrow-stored",
  "expr/function-expression",
  "expr/class-expression",
  "expr/this",
  "expr/yield",
  "expr/await",
  // ---- expressions: operator families
  "expr/ternary",
  "expr/comma-outside-for",
  "expr/void",
  "expr/assignment-as-value",
  "expr/assignment-as-value-read-elsewhere",
  "expr/typeof-value",
  "expr/in-operator",
  "expr/instanceof",
  "expr/delete",
  "op/unary-not",
  "op/unary-minus",
  "op/unary-plus",
  "op/unary-bitnot",
  "op/increment-statement",
  "op/increment-as-value",
  "op/increment-as-value-conditional",
  "op/add-sub-mul",
  "op/div-mod",
  "op/exponent",
  "op/relational",
  "op/strict-equality",
  "op/loose-equality",
  "op/logical-and-or",
  "op/nullish-coalescing",
  "op/bitwise-and-or-xor",
  "op/shifts",
  "op/compound-arithmetic-assign",
  "op/compound-bitwise-assign",
  "op/compound-logical-assign",
  "op/string-concat",
  "op/relational-strings",
  // ---- erasable type-level syntax
  "type/as-assertion",
  "type/satisfies",
  "type/non-null-assertion",
  "type/typeof-type-query",
  // ---- runtime surfaces reached through globals
  "global/eval",
  "global/dynamic-import",
  "global/object-statics",
  "global/array-statics",
  "global/json",
  "global/symbol",
  "global/bigint-call",
  "global/jsx",
];

const matrix: Record<string, Row> = {
  // ------------------------------------------------------------- statements
  "stmt/const-declaration": {
    verdict: "emits",
    src: `export function f(): number { const x = 2; return x; }`,
  },
  "stmt/let-declaration": {
    verdict: "emits",
    src: `export function f(): number { let x = 2; x = 3; return x; }`,
  },
  "stmt/let-uninitialized-typed": {
    verdict: "emits",
    src: `export function f(b: boolean): number { let x: number; if (b) { x = 1; } else { x = 2; } return x; }`,
  },
  "stmt/var-declaration": {
    verdict: "gate",
    id: "NS1049",
    src: `export function f(): number { var x = 1; x = 2; return x; }`,
  },
  "stmt/object-destructuring-const": {
    verdict: "emits",
    src: `
export interface Stats { readonly total: number; readonly done: number; readonly label: Uint8Array; }
export function pct(stats: Stats): number {
  const { total, done: doneCount } = stats;
  if (total === 0) return 0;
  return doneCount * 100 / total;
}`,
  },
  "stmt/array-destructuring": {
    verdict: "gate",
    id: "NS1045",
    src: `export function f(xs: readonly number[]): number { const [a] = xs; return a; }`,
  },
  "stmt/empty": {
    verdict: "emits",
    src: `export function f(): number { ; return 1; }`,
  },
  "stmt/expression": {
    verdict: "emits",
    src: `export function f(): number { let x = 0; x += 1; return x; }`,
  },
  "stmt/block": {
    verdict: "emits",
    src: `export function f(): number { let x = 0; { x = 2; } return x; }`,
  },
  "stmt/if-else": {
    verdict: "emits",
    src: `export function f(b: boolean): number { if (b) { return 1; } else { return 2; } }`,
  },
  "stmt/do-while": {
    verdict: "emits",
    src: `
export function count(n: number): number {
  let i = 0;
  let total = 0;
  do { total += 1; i += 1; } while (i < n);
  do { if (total % 2 === 0) { total += 3; continue; } total += 1; } while (total < 10);
  return total;
}`,
  },
  "stmt/while": {
    verdict: "emits",
    src: `export function f(n: number): number { let i = 0; while (i < n) { i += 1; } return i; }`,
  },
  "stmt/for-classic": {
    verdict: "emits",
    src: `export function f(xs: Uint8Array): number { let t = 0; for (let i = 0; i < xs.length; i++) { t += xs[i]; } return t; }`,
  },
  "stmt/for-multi-init-comma-incrementor": {
    verdict: "emits",
    src: `export function meet(n: number): number { let acc = 0; for (let i = 0, j = n; i < j; i++, j--) { acc += 1; } return acc; }`,
  },
  "stmt/for-countdown": {
    verdict: "emits",
    src: `export function down(n: number): number { let acc = 0; for (let i = n; i > 0; i--) { acc += i; } return acc; }`,
  },
  "stmt/for-in": {
    verdict: "gate",
    id: "NS1009",
    src: `export function f(o: { readonly a: number }): number { let n = 0; for (const k in o) { n += 1; } return n; }`,
  },
  "stmt/for-of": {
    verdict: "emits",
    src: `export function f(xs: Uint8Array): number { let t = 0; for (const b of xs) { t += b; } return t; }`,
  },
  "stmt/for-of-entries": {
    // The destructured-tuple loop form ONLY (`[i, x]`, two identifiers);
    // general tuple destructuring stays taught (stmt/array-destructuring).
    verdict: "emits",
    src: `export function f(xs: readonly number[]): number { let t = 0; for (const [i, x] of xs.entries()) { t += i * x; } return t; }`,
  },
  "stmt/for-await-of": {
    verdict: "tsc",
    src: `export function f(xs: readonly number[]): number { let t = 0; for await (const x of xs) { t += x; } return t; }`,
  },
  "stmt/continue": {
    verdict: "emits",
    src: `export function f(xs: Uint8Array): number { let t = 0; for (const b of xs) { if (b === 0) continue; t += b; } return t; }`,
  },
  "stmt/continue-labeled": {
    verdict: "emits",
    src: `
export function f(): number {
  let acc = 0;
  outer: for (let i = 0; i < 3; i++) {
    for (let j = 0; j < 3; j++) {
      if (j === 1) continue outer;
      acc += 1;
    }
  }
  return acc;
}`,
  },
  "stmt/break": {
    verdict: "emits",
    src: `export function f(xs: Uint8Array): number { let t = 0; for (const b of xs) { if (b === 9) break; t += b; } return t; }`,
  },
  "stmt/break-labeled": {
    verdict: "emits",
    src: `
export function f(): number {
  let acc = 0;
  outer: for (let i = 0; i < 3; i++) {
    for (let j = 0; j < 3; j++) {
      if (i === 1 && j === 1) break outer;
      acc += 1;
    }
  }
  return acc;
}`,
  },
  "stmt/labeled-loop": {
    verdict: "emits",
    src: `
export function f(n: number): number {
  let i = 0;
  scan: while (i < n) {
    i += 1;
    if (i === 5) break scan;
  }
  return i;
}`,
  },
  "stmt/labeled-block": {
    verdict: "emits",
    src: `
export function f(b: boolean): number {
  let acc = 0;
  work: { acc += 1; if (b) break work; acc += 10; }
  return acc;
}`,
  },
  "stmt/labeled-unreferenced": {
    // JS allows a label nothing jumps to; Zig rejects an unused one, so the
    // emitted loop drops it.
    verdict: "emits",
    src: `
export function f(n: number): number {
  let acc = 0;
  quietly: for (let i = 0; i < n; i++) { acc += i; }
  return acc;
}`,
  },
  "stmt/return": {
    verdict: "emits",
    src: `export function f(): number { return 7; }`,
  },
  "stmt/switch-union-kind": {
    verdict: "emits",
    src: `
export type Msg = { readonly kind: "a" } | { readonly kind: "b"; readonly v: number };
export function f(msg: Msg): number {
  switch (msg.kind) {
    case "a": return 0;
    case "b": return msg.v;
  }
}`,
  },
  "stmt/switch-union-kind-default": {
    verdict: "emits",
    src: `
export type Msg = { readonly kind: "a" } | { readonly kind: "b"; readonly v: number } | { readonly kind: "c" };
export function f(msg: Msg): number {
  switch (msg.kind) {
    case "b": return msg.v;
    default: return -1;
  }
}
export function g(msg: Msg): number {
  // Every kind covered AND a default: the default is dead code in JS.
  switch (msg.kind) {
    case "a": return 1;
    case "b": return 2;
    case "c": return 3;
    default: return -1;
  }
}`,
  },
  "stmt/switch-value-default": {
    verdict: "emits",
    src: `
export type Filter = "all" | "active" | "done";
export function f(filter: Filter): number {
  switch (filter) {
    case "all": return 0;
    default: return 1;
  }
}`,
  },
  "stmt/switch-plain-number": {
    // Plain number/string scrutinees lower to an if/else chain with JS
    // strict-equality and case-order semantics (default matches only after
    // every case misses, wherever it sits).
    verdict: "emits",
    src: `export function f(n: number): number { switch (n) { case 1: return 10; default: return 0; } }`,
  },
  "stmt/switch-plain-string": {
    verdict: "emits",
    src: `export function f(s: string): number { switch (s) { case "a": return 1; case "b": return 2; default: return 0; } }`,
  },
  "stmt/throw": {
    // R20: exceptions are deterministic control flow — `throw` carries a
    // subset value (the core's ONE error shape, NS1057) to the nearest
    // catch; an uncaught throw is a defined panic at the exported
    // boundary, exactly where node's process would crash.
    verdict: "emits",
    src: `export type Failure = { readonly kind: "negative" } | { readonly kind: "overflow" };
export function f(n: number): number {
  if (n < 0) throw { kind: "negative" } as Failure;
  return n;
}`,
  },
  "stmt/throw-heterogeneous": {
    // R20 heterogeneous throws: distinct kind-tagged shapes merge into the
    // core's thrown union; the payload slot is that union.
    verdict: "emits",
    src: `export interface ParseError { readonly kind: "parse"; readonly at: number; }
export interface IoError { readonly kind: "io"; readonly code: number; }
export function f(n: number): number {
  if (n < 0) throw { kind: "parse", at: n } as ParseError;
  if (n > 100) throw { kind: "io", code: n } as IoError;
  return n;
}`,
  },
  "stmt/catch-kind-narrowing": {
    // `catch (e)` binds the thrown union; kind tests narrow it like any
    // discriminated union — no `as` ceremony.
    verdict: "emits",
    src: `export interface ParseError { readonly kind: "parse"; readonly at: number; }
export interface IoError { readonly kind: "io"; readonly code: number; }
function go(n: number): number {
  if (n < 0) throw { kind: "parse", at: n } as ParseError;
  if (n > 100) throw { kind: "io", code: n } as IoError;
  return n * 2;
}
export function f(n: number): number {
  try { return go(n); } catch (e) {
    if (e.kind === "parse") return e.at - 1;
    if (e.kind === "io") return e.code + 1;
    return 0;
  }
}`,
  },
  "stmt/throw-error-object": {
    // `Error` objects carry engine stack traces with no native shape;
    // thrown values are subset values.
    verdict: "gate",
    id: "NS1057",
    src: `export function f(): number { throw new Error("x"); }`,
  },
  "stmt/try-catch-finally": {
    verdict: "emits",
    src: `export function f(): number { try { return 1; } catch { return 0; } finally { } }`,
  },
  "stmt/try-unsafe-finally": {
    // `finally` runs via a scoped defer on every exit; a `return` inside
    // it would override the pending return/exception (no-unsafe-finally).
    verdict: "gate",
    id: "NS1058",
    src: `export function f(): number { try { return 1; } finally { return 0; } }`,
  },
  "stmt/with": {
    verdict: "tsc",
    src: `export function f(o: { a: number }): number { with (o) { return a; } }`,
  },
  "stmt/debugger": {
    verdict: "gate",
    id: "NS1013",
    src: `export function f(): number { debugger; return 1; }`,
  },
  // ------------------------------------------- declarations, module surface
  "decl/function": {
    verdict: "emits",
    src: `function helper(n: number): number { return n + 1; }
export function f(): number { return helper(1); }`,
  },
  "decl/function-nested": {
    verdict: "gate",
    id: "NS1046",
    src: `export function f(): number { function inner(): number { return 1; } return inner(); }`,
  },
  "decl/function-generator": {
    verdict: "gate",
    id: "NS1042",
    src: `export function* gen(): Generator<number> { yield 1; }
export function f(): number { return 1; }`,
  },
  "decl/function-async": {
    verdict: "gate",
    id: "NS1002",
    src: `export async function load(): Promise<number> { return 1; }
export function f(): number { return 1; }`,
  },
  "decl/function-generic": {
    // R15e: user generics monomorphize per call site from tsc's resolved
    // type arguments (`first__Task`, `first__f64`), deduped; unresolvable
    // call sites teach NS1053.
    verdict: "emits",
    src: `export function first<T>(xs: readonly T[]): T | null { return xs.length > 0 ? xs[0] : null; }
export function firstOr(xs: readonly number[], d: number): number { return first(xs) ?? d; }`,
  },
  "decl/class": {
    // R19: data classes — annotated fields, one constructor, plain
    // methods; `new` constructs a record-shaped value, methods emit as
    // module-level fns (mutating ones take the receiver by pointer).
    verdict: "emits",
    src: `export class Counter {
  n: number = 0;
  bump(): void { this.n += 1; }
}
export function f(): number { const c = new Counter(); c.bump(); return c.n; }`,
  },
  "decl/class-extends": {
    verdict: "gate",
    id: "NS1055",
    src: `class Base { n: number = 0; }
export class Derived extends Base { m: number = 1; }
export function f(): number { return 1; }`,
  },
  "decl/class-accessor": {
    verdict: "gate",
    id: "NS1056",
    src: `export class Config { get doubled(): number { return 4; } }
export function f(): number { return 1; }`,
  },
  "decl/class-static": {
    // R19b: static methods are receiver-less module fns, static readonly
    // fields are module consts — both under the class's mangled names.
    verdict: "emits",
    src: `export class Config {
  n: number = 0;
  static readonly LIMIT = 4;
  static clamp(v: number): number { return v > Config.LIMIT ? Config.LIMIT : v; }
}
export function f(n: number): number { const c = new Config(); return c.n + Config.clamp(n); }`,
  },
  "decl/class-static-mutable": {
    // A mutable static is module state by another spelling.
    verdict: "gate",
    id: "NS1010",
    src: `export class Config { static shared: number = 2; }
export function f(): number { return 1; }`,
  },
  "decl/class-private-keyword": {
    // `private`/`protected` keywords are erased: tsc enforces them at the
    // type level, which is their whole meaning.
    verdict: "emits",
    src: `export class Counter {
  private n: number = 0;
  bump(): void { this.n += 1; }
  value(): number { return this.n; }
}
export function f(): number { const c = new Counter(); c.bump(); return c.value(); }`,
  },
  "decl/class-private-hash": {
    verdict: "gate",
    id: "NS1056",
    src: `export class Config { #secret: number = 1; }
export function f(): number { return 1; }`,
  },
  "decl/class-generic": {
    verdict: "gate",
    id: "NS1053",
    src: `export class Box<T> { v: T | null = null; }
export function f(): number { return 1; }`,
  },
  "decl/interface": {
    verdict: "emits",
    src: `export interface P { readonly x: number; }
export function f(p: P): number { return p.x; }`,
  },
  "decl/interface-generic": {
    // Generic interfaces/aliases are templates: instantiations resolve
    // structurally through the type table (`Box<Task>` -> `Box__Task`).
    verdict: "emits",
    src: `export interface Box<T> { readonly v: T; }
export interface Task { readonly id: number; }
export function f(b: Box<Task>): number { return b.v.id; }`,
  },
  "decl/type-alias": {
    verdict: "emits",
    src: `export type Filter = "all" | "done";
export function f(x: Filter): boolean { return x === "all"; }`,
  },
  "decl/enum": {
    verdict: "gate",
    id: "NS1008",
    src: `export enum Color { Red, Green }
export function f(): number { return 1; }`,
  },
  "decl/namespace": {
    verdict: "gate",
    id: "NS1008",
    src: `export namespace Util { export const N = 1; }
export function f(): number { return 1; }`,
  },
  "decl/decorator": {
    // Standard decorators cannot be spelled tsc-clean without a class (which
    // gates on its own), so the pin runs through the checker alone.
    verdict: "check",
    id: "NS1008",
    src: `function dec(value: unknown, context: unknown): void {}
@dec class C {}
export function f(): number { return 1; }`,
  },
  "decl/module-let": {
    verdict: "gate",
    id: "NS1010",
    src: `let counter = 0;
export function f(): number { return counter; }`,
  },
  "decl/parameter-default": {
    verdict: "gate",
    id: "NS1019",
    src: `export function f(n: number = 3): number { return n; }`,
  },
  "decl/parameter-rest": {
    verdict: "gate",
    id: "NS1019",
    src: `export function f(...xs: readonly number[]): number { return xs.length; }`,
  },
  "decl/parameter-destructuring": {
    verdict: "gate",
    id: "NS1045",
    src: `export function f({ a }: { readonly a: number }): number { return a; }`,
  },
  "decl/import-named": {
    verdict: "emits",
    files: {
      "core.ts": `import { bump } from "./util.ts";
export function f(n: number): number { return bump(n); }`,
      "util.ts": `export function bump(n: number): number { return n + 1; }`,
    },
  },
  "decl/import-type": {
    verdict: "emits",
    files: {
      "core.ts": `import type { Cfg } from "./util.ts";
export function f(c: Cfg): number { return c.n; }`,
      "util.ts": `export interface Cfg { readonly n: number; }`,
    },
  },
  "decl/import-namespace": {
    verdict: "emits",
    files: {
      "core.ts": `import * as util from "./util.ts";
export function f(n: number): number { const c: util.Cfg = { step: util.SEED }; return util.bump(n) + c.step; }`,
      "util.ts": `export interface Cfg { readonly step: number; }
export const SEED = 5;
export function bump(n: number): number { return n + 1; }`,
    },
  },
  "decl/import-namespace-sdk": {
    verdict: "gate",
    id: "NS1039",
    src: `import * as sdk from "@native-sdk/core";
export function f(): number { return 1; }`,
  },
  "decl/import-default": {
    verdict: "gate",
    id: "NS1047",
    files: {
      "core.ts": `import bump from "./util.ts";
export function f(n: number): number { return bump(n); }`,
      "util.ts": `export default function bump(n: number): number { return n + 1; }`,
    },
  },
  "decl/import-equals": {
    verdict: "tsc",
    src: `import util = require("./util.ts");
export function f(): number { return 1; }`,
  },
  "decl/export-named": {
    verdict: "emits",
    src: `export const LIMIT = 9;
export function f(): number { return LIMIT; }`,
  },
  "decl/export-default": {
    verdict: "gate",
    id: "NS1047",
    src: `export default function f(): number { return 1; }`,
  },
  "decl/export-assignment": {
    verdict: "tsc",
    src: `function f(): number { return 1; }
export = f;`,
  },
  "decl/export-list": {
    // Export lists bind names over existing declarations in the flat
    // namespace — the un-renamed entry exports the declaration itself.
    verdict: "emits",
    src: `function f(): number { return 1; }
export { f };
export function g(): number { return f(); }`,
  },
  "decl/export-list-renamed": {
    // `export { a as b }` binds the NEW name over the declaration (a
    // `pub const b = a;` alias in the emitted module).
    verdict: "emits",
    src: `function f(): number { return 1; }
export { f as bump };
export function g(): number { return f(); }`,
  },
  "decl/re-export-value": {
    verdict: "emits",
    files: {
      "core.ts": `export { bump } from "./util.ts";
export function g(n: number): number { return n + 1; }`,
      "util.ts": `export function bump(n: number): number { return n + 1; }`,
    },
  },
  "decl/re-export-value-renamed": {
    verdict: "emits",
    files: {
      "core.ts": `export { bump as inc } from "./util.ts";
export function g(n: number): number { return n + 1; }`,
      "util.ts": `export function bump(n: number): number { return n + 1; }`,
    },
  },
  "decl/re-export-star": {
    verdict: "gate",
    id: "NS1047",
    files: {
      "core.ts": `export * from "./util.ts";
export function f(): number { return 1; }`,
      "util.ts": `export function bump(n: number): number { return n + 1; }`,
    },
  },
  "decl/re-export-type-only": {
    verdict: "emits",
    files: {
      "core.ts": `import type { Cfg } from "./api.ts";
export function f(c: Cfg): number { return c.n; }`,
      "api.ts": `export type { Cfg } from "./impl.ts";`,
      "impl.ts": `export interface Cfg { readonly n: number; }`,
    },
  },
  // ------------------------------------------------------ literal & template
  "expr/literal-number": {
    verdict: "emits",
    src: `export function f(): number { return 0x10 + 0b101 + 0o17 + 1_000 + 1.5e2; }`,
  },
  "expr/literal-bigint": {
    verdict: "gate",
    id: "NS1044",
    src: `export function f(): number { const b = 10n; return b === 10n ? 1 : 0; }`,
  },
  "expr/literal-string": {
    verdict: "emits",
    src: `export function f(tag: string): boolean { return tag === "app.add"; }`,
  },
  "expr/literal-boolean-null": {
    verdict: "emits",
    src: `export function f(x: number | null): boolean { return x === null ? true : false; }`,
  },
  "expr/literal-regex": {
    verdict: "gate",
    id: "NS1040",
    src: `export function f(): number { const re = /a+/; return re === re ? 1 : 0; }`,
  },
  "expr/template-no-substitution": {
    verdict: "emits",
    src: `export function f(): boolean { const s = \`abc\`; return s === "abc"; }`,
  },
  "expr/template-with-holes": {
    verdict: "emits",
    src: `import { asciiBytes } from "@native-sdk/core";
export function f(xs: Uint8Array): Uint8Array { return asciiBytes(\`\${xs.length} items\`); }`,
  },
  "expr/template-tagged": {
    verdict: "gate",
    id: "NS1018",
    src: `export function f(): number { const s = String.raw\`abc\`; return s === "abc" ? 1 : 0; }`,
  },
  "expr/array-literal-spread": {
    verdict: "emits",
    src: `export function f(xs: readonly number[], x: number): readonly number[] { return [...xs, x]; }`,
  },
  "expr/object-literal-spread": {
    verdict: "emits",
    src: `
export interface Model { readonly a: number; readonly b: number; }
export function f(m: Model): Model { return { ...m, a: m.a + 1 }; }`,
  },
  "expr/object-literal-shorthand": {
    verdict: "emits",
    src: `
export interface P { readonly x: number; }
export function f(x: number): P { return { x }; }`,
  },
  "expr/object-literal-computed-key": {
    verdict: "gate",
    id: "NS1012",
    src: `export function f(k: string): number { const o = { [k]: 1 } as unknown as { a: number }; return o.a; }`,
  },
  "expr/object-literal-accessor": {
    verdict: "gate",
    id: "NS1012",
    src: `export function f(): number { const o = { get a(): number { return 1; } }; return o.a; }`,
  },
  // ------------------------------------------------------------ access, calls
  "expr/property-access": {
    verdict: "emits",
    src: `export interface P { readonly x: number; }
export function f(p: P): number { return p.x; }`,
  },
  "expr/element-access": {
    verdict: "emits",
    src: `export function f(xs: Uint8Array, i: number): number { return xs[i]; }`,
  },
  "expr/optional-chain-property": {
    verdict: "emits",
    src: `
export interface Sel { readonly at: number; }
export function f(sel: Sel | null): number { return sel?.at ?? -1; }`,
  },
  "expr/optional-chain-call": {
    verdict: "gate",
    id: "NS1046",
    src: `export function f(g: (() => number) | null): number { return g?.() ?? 0; }`,
  },
  "expr/optional-chain-element": {
    // Element hops null-propagate like property hops (R7b); the chain value
    // is optional and `??` consumes it.
    verdict: "emits",
    src: `
export interface M { readonly xs: Uint8Array; }
export function f(m: M | null): number { return m?.xs[0] ?? 0; }`,
  },
  "expr/call-function": {
    verdict: "emits",
    src: `function add(a: number, b: number): number { return a + b; }
export function f(): number { return add(1, 2); }`,
  },
  "expr/call-recursive": {
    verdict: "emits",
    src: `export function fib(n: number): number { if (n < 2) return n; return fib(n - 1) + fib(n - 2); }`,
  },
  "expr/call-spread-arguments": {
    verdict: "gate",
    id: "NS1019",
    src: `function add(a: number, b: number): number { return a + b; }
export function f(xs: readonly [number, number]): number { return add(...xs); }`,
  },
  "expr/arguments-object": {
    verdict: "gate",
    id: "NS1019",
    src: `export function f(): number { return (arguments as unknown as { length: number }).length; }`,
  },
  "expr/new-uint8array": {
    verdict: "emits",
    src: `export function f(n: number): Uint8Array { const b = new Uint8Array(4); return b; }`,
  },
  "expr/new-class": {
    // `new` of an AMBIENT class (a user data class emits — decl/class);
    // `new Error` has its own teach (NS1057, stmt/throw-error-object).
    verdict: "gate",
    id: "NS1006",
    src: `export function f(): number { const e = new WeakRef({ n: 1 }); return e === e ? 1 : 0; }`,
  },
  "expr/new-map-set": {
    verdict: "gate",
    id: "NS1011",
    src: `export function f(): number { const m = new Map<number, number>(); return m === m ? 1 : 0; }`,
  },
  "expr/new-function": {
    verdict: "gate",
    id: "NS1013",
    src: `export function f(): number { const g = new Function("return 1"); return g === g ? 1 : 0; }`,
  },
  "expr/new-regexp": {
    verdict: "gate",
    id: "NS1040",
    src: `export function f(): number { const re = new RegExp("a+"); return re === re ? 1 : 0; }`,
  },
  "expr/new-promise": {
    verdict: "gate",
    id: "NS1002",
    src: `export function f(): number { const p = new Promise<number>((resolve) => resolve(1)); return p === p ? 1 : 0; }`,
  },
  "expr/new-date": {
    verdict: "gate",
    id: "NS1005",
    src: `export function f(): number { const d = new Date(); return d === d ? 1 : 0; }`,
  },
  // -------------------------------------------------------- function values
  "expr/arrow-callback": {
    verdict: "emits",
    src: `export function f(xs: readonly number[]): readonly number[] { return xs.map((x) => x * 2); }`,
  },
  "expr/function-reference-callback": {
    // A bare reference to a module-level fn (or a hoisted local helper) in
    // callback position inlines exactly like the arrow form spelled at the
    // site: `xs.map(double)` IS `xs.map((n) => double's body)`.
    verdict: "emits",
    src: `function double(n: number): number { return n * 2; }
export function f(xs: readonly number[]): readonly number[] { return xs.map(double); }`,
  },
  "expr/arrow-stored": {
    // R15d: a const-bound, capture-free, fully-annotated local helper
    // hoists to a module-level fn; captures/reassignment/other uses teach
    // (NS1054/NS1046).
    verdict: "emits",
    src: `export function f(): number { const g = (x: number): number => x + 1; return g(1); }`,
  },
  "expr/function-expression": {
    verdict: "emits",
    src: `export function f(): number { const g = function (x: number): number { return x + 1; }; return g(1); }`,
  },
  "expr/class-expression": {
    verdict: "gate",
    id: "NS1006",
    src: `export function f(): number { const C = class {}; return C === C ? 1 : 0; }`,
  },
  "expr/this": {
    verdict: "tsc",
    src: `export function f(): number { return (this as unknown as { n: number }).n; }`,
  },
  "expr/yield": {
    verdict: "gate",
    id: "NS1042",
    src: `export function* gen(): Generator<number> { yield 1; yield 2; }
export function f(): number { return 1; }`,
  },
  "expr/await": {
    verdict: "gate",
    id: "NS1002",
    src: `const x = await Promise.resolve(1);
export function f(): number { return 1; }`,
  },
  // ------------------------------------------------------ operator families
  "expr/ternary": {
    verdict: "emits",
    src: `export function f(b: boolean): number { return b ? 1 : 2; }`,
  },
  "expr/comma-outside-for": {
    verdict: "gate",
    id: "NS1043",
    src: `export function f(): number { let a = 0; const x = (a++, a); return x; }`,
  },
  "expr/void": {
    verdict: "gate",
    id: "NS1043",
    src: `export function f(): number { void 0; return 1; }`,
  },
  "expr/assignment-as-value": {
    // Legal when the split statement is order-exact (sole mention,
    // unskippable position); the taught remainder keeps NS1043.
    verdict: "emits",
    src: `export function f(): number { let y = 0; const z = (y = 5); return z * 10 + y; }`,
  },
  "expr/assignment-as-value-read-elsewhere": {
    verdict: "gate",
    id: "NS1043",
    src: `export function f(): number { let y = 0; const z = (y = 5) + y; return z; }`,
  },
  "expr/typeof-value": {
    verdict: "gate",
    id: "NS1041",
    src: `export function f(x: number): number { const t = typeof x; return t === "number" ? 1 : 0; }`,
  },
  "expr/in-operator": {
    verdict: "gate",
    id: "NS1041",
    src: `export function f(o: { readonly a: number }): boolean { return "a" in o; }`,
  },
  "expr/instanceof": {
    verdict: "gate",
    id: "NS1041",
    src: `export function f(x: unknown): boolean { return x instanceof Uint8Array; }`,
  },
  "expr/delete": {
    verdict: "gate",
    id: "NS1012",
    src: `export function f(o: { a?: number }): number { delete o.a; return 1; }`,
  },
  "op/unary-not": {
    verdict: "emits",
    src: `export function f(b: boolean): boolean { return !b; }`,
  },
  "op/unary-minus": {
    verdict: "emits",
    src: `export function f(n: number): number { return -n; }`,
  },
  "op/unary-plus": {
    verdict: "emits",
    src: `export function f(n: number): number { return +n + 1; }`,
  },
  "op/unary-bitnot": {
    verdict: "emits",
    src: `export function f(n: number): number { let i = 0; i = n | 0; return ~i; }`,
  },
  "op/increment-statement": {
    verdict: "emits",
    src: `export function f(): number { let x = 0; x++; ++x; x--; --x; return x; }`,
  },
  "op/increment-as-value": {
    // `arr[i++]` / `const n = ++count`: the step lowers to its own
    // statement (JS-order-exact by the sole-mention + unskippable rule).
    verdict: "emits",
    src: `export function f(): number { let x = 1; const y = ++x; return y; }`,
  },
  "op/increment-as-value-conditional": {
    verdict: "gate",
    id: "NS1043",
    src: `export function f(b: boolean): number { let x = 1; const y = b ? x++ : 0; return y; }`,
  },
  "op/add-sub-mul": {
    verdict: "emits",
    src: `export function f(a: number, b: number): number { return a + b - a * b; }`,
  },
  "op/div-mod": {
    verdict: "emits",
    src: `export function f(a: number, b: number): number { return a / b + a % b; }`,
  },
  "op/exponent": {
    verdict: "emits",
    src: `export function f(a: number, b: number): number { let v = a ** b; v **= 2; return v; }`,
  },
  "op/relational": {
    verdict: "emits",
    src: `export function f(a: number, b: number): boolean { return a < b && a <= b && a > b === false && a >= b === false; }`,
  },
  "op/strict-equality": {
    verdict: "emits",
    src: `export function f(a: number, b: number): boolean { return a === b || a !== b; }`,
  },
  "op/loose-equality": {
    verdict: "gate",
    id: "NS1048",
    src: `export function f(a: number, b: number): boolean { return a == b; }`,
  },
  "op/logical-and-or": {
    verdict: "emits",
    src: `export function f(a: boolean, b: boolean): boolean { return (a && b) || (!a && !b); }`,
  },
  "op/nullish-coalescing": {
    verdict: "emits",
    src: `export function f(x: number | null): number { return x ?? 7; }`,
  },
  "op/bitwise-and-or-xor": {
    verdict: "emits",
    src: `export function f(a: number, b: number): number { let x = 0; let y = 0; x = a | 0; y = b | 0; return (x & y) + (x | y) + (x ^ y); }`,
  },
  "op/shifts": {
    verdict: "emits",
    src: `export function f(a: number, b: number): number { let x = 0; let n = 0; x = a | 0; n = b | 0; return (x << n) + (x >> n) + (x >>> n); }`,
  },
  "op/compound-arithmetic-assign": {
    verdict: "emits",
    src: `export function f(a: number): number { let v = a; v += 1; v -= 2; v *= 3; v /= 2; v %= 7; v **= 2; return v; }`,
  },
  "op/compound-bitwise-assign": {
    verdict: "emits",
    src: `export function f(a: number): number { let v = 0; v = a | 0; v &= 255; v |= 1; v ^= 3; v <<= 2; v >>= 1; v >>>= 1; return v; }`,
  },
  "op/compound-logical-assign": {
    verdict: "emits",
    src: `
export function f(a: boolean, b: boolean, n: number | null): number {
  let x = a;
  x &&= b;
  x ||= a;
  let v = n;
  v ??= 9;
  if (x) return v ?? -1;
  return 0;
}`,
  },
  "op/string-concat": {
    verdict: "gate",
    id: "NS1018",
    src: `export function f(a: string, b: string): boolean { return (a + b) === "ab"; }`,
  },
  "op/relational-strings": {
    verdict: "gate",
    id: "NS1004",
    src: `export function f(a: string, b: string): boolean { return a < b; }`,
  },
  // --------------------------------------------------- erasable type syntax
  "type/as-assertion": {
    verdict: "emits",
    src: `export type Filter = "all" | "done";
export function f(): boolean { const x = "all" as Filter; return x === "all"; }`,
  },
  "type/satisfies": {
    verdict: "emits",
    src: `
export interface P { readonly x: number; }
const TABLE: P = { x: 1 } satisfies P;
export function f(): number { return TABLE.x; }`,
  },
  "type/non-null-assertion": {
    verdict: "emits",
    src: `export function f(x: number | null): number { if (x === null) return 0; return x!; }`,
  },
  "type/typeof-type-query": {
    // `typeof CONST` resolves through the checker's own type query and
    // widens to the value's slot type (type-level only; erases under node).
    verdict: "emits",
    src: `const LIMIT = 9;
export type Limit = typeof LIMIT;
export function f(l: Limit): number { return l; }`,
  },
  // ----------------------------------------------------------- global gates
  "global/eval": {
    verdict: "gate",
    id: "NS1013",
    src: `export function f(): number { eval("1"); return 1; }`,
  },
  "global/dynamic-import": {
    verdict: "tsc",
    src: `export function f(): number { return 1; }
import("./other.ts");`,
  },
  "global/object-statics": {
    verdict: "gate",
    id: "NS1041",
    src: `export function f(o: { readonly a: number }): number { return Object.keys(o).length; }`,
  },
  "global/array-statics": {
    // NS1059: the Array constructors get their own accurate teaching — they
    // BUILD arrays through runtime protocols; the literal/spread/loop forms
    // build the same arrays statically (Array.isArray stays NS1041, the
    // runtime type test it actually is).
    verdict: "gate",
    id: "NS1059",
    src: `export function f(xs: readonly number[]): number { const c = Array.from(xs); return c.length; }`,
  },
  "global/json": {
    verdict: "gate",
    id: "NS1041",
    src: `export function f(): number { const s = JSON.stringify(1); return s === "1" ? 1 : 0; }`,
  },
  "global/symbol": {
    verdict: "gate",
    id: "NS1044",
    src: `export function f(): number { const s = Symbol("x"); return s === s ? 1 : 0; }`,
  },
  "global/bigint-call": {
    verdict: "gate",
    id: "NS1044",
    src: `export function f(): number { const b = BigInt(1); return b === b ? 1 : 0; }`,
  },
  "global/jsx": {
    verdict: "tsc",
    src: `export const x = <div/>;`,
  },
};

// ---------------------------------------------------------------------------
// The mutation matrix: the grammar productions above classify SYNTAX; this
// section machine-pins the library-surface classification of every mutating
// array method under the ownership rule (locally-owned arrays mutate freely;
// teaching errors fire only at the semantic boundaries). One row per method x
// ownership verdict, so the classification can never grow a silent gap.

const mutationSurface: readonly string[] = [
  // ---- every supported method on a locally-owned array
  "owned/push",
  "owned/pop",
  "owned/shift",
  "owned/unshift",
  "owned/splice",
  "owned/reverse",
  "owned/fill",
  "owned/sort",
  "owned/indexed-write",
  "owned/append-write",
  "owned/reassigned-all-owning",
  "owned/borrowed-readonly-pass",
  // ---- the semantic boundaries
  "boundary/parameter",
  "boundary/model-field",
  "boundary/module-const",
  "boundary/alias",
  "boundary/reassigned-mixed",
  "boundary/escape-call",
  "boundary/escape-store",
  "boundary/borrow-alias-out",
  "boundary/sort-shared",
  "boundary/indexed-write-parameter",
  "boundary/append-write-parameter",
  // ---- shape stops (owned, but the form has no mapping)
  "shape/copyWithin",
  "shape/sort-value-position",
  "shape/push-value-position",
  "shape/append-write-compound",
  "shape/iterating-length-change",
];

const mutationMatrix: Record<string, Row> = {
  "owned/push": {
    verdict: "emits",
    src: `export function f(n: number): readonly number[] { const out: number[] = []; out.push(n); return out; }`,
  },
  "owned/pop": {
    verdict: "emits",
    src: `export function f(xs: readonly number[]): number { const w = xs.slice(); return w.pop() ?? -1; }`,
  },
  "owned/shift": {
    verdict: "emits",
    src: `export function f(xs: readonly number[]): number { const w = xs.slice(); return w.shift() ?? -1; }`,
  },
  "owned/unshift": {
    verdict: "emits",
    src: `export function f(xs: readonly number[]): readonly number[] { const w = xs.slice(); w.unshift(0); return w; }`,
  },
  "owned/splice": {
    verdict: "emits",
    src: `export function f(xs: readonly number[]): readonly number[] { const w = xs.slice(); const cut = w.splice(1, 2, 9); return cut.concat(w); }`,
  },
  "owned/reverse": {
    verdict: "emits",
    src: `export function f(xs: readonly number[]): readonly number[] { const w = xs.slice(); w.reverse(); return w; }`,
  },
  "owned/fill": {
    verdict: "emits",
    src: `export function f(xs: readonly number[]): readonly number[] { const w = xs.slice(); w.fill(0, 1, -1); return w; }`,
  },
  "owned/sort": {
    verdict: "emits",
    src: `export function f(xs: readonly number[]): readonly number[] { const w = xs.slice(); w.sort((a, b) => a - b); return w; }`,
  },
  "owned/indexed-write": {
    verdict: "emits",
    src: `export function f(xs: readonly number[]): readonly number[] { const w = xs.slice(); if (w.length > 0) w[0] = 9; return w; }`,
  },
  "boundary/parameter": {
    verdict: "gate",
    id: "NS1001",
    src: `export function f(xs: number[], x: number): number[] { xs.push(x); return xs; }`,
  },
  "boundary/model-field": {
    verdict: "gate",
    id: "NS1001",
    src: `
export interface Model { readonly xs: readonly number[]; }
export function f(model: Model): readonly number[] { (model.xs as number[]).push(1); return model.xs; }`,
  },
  "boundary/module-const": {
    verdict: "gate",
    id: "NS1001",
    src: `const TABLE: number[] = [1];
export function f(): number { TABLE.pop(); return TABLE.length; }`,
  },
  "boundary/alias": {
    verdict: "gate",
    id: "NS1001",
    src: `export function f(): number { const a: number[] = [1]; const b = a; b.push(2); return a.length; }`,
  },
  "boundary/reassigned-mixed": {
    // ONE assignment that is not a fresh construction ends the binding's
    // ownership everywhere (the flow-sensitive rule needs every assignment
    // owning).
    verdict: "gate",
    id: "NS1001",
    src: `
export function f(xs: number[]): readonly number[] {
  let w = xs.slice();
  w = xs;
  w.pop();
  return w;
}`,
  },
  "boundary/escape-call": {
    // A MUTABLE parameter could write or retain the array — passing there
    // still ends ownership (`readonly T[]` reader params borrow instead:
    // owned/borrowed-readonly-pass).
    verdict: "gate",
    id: "NS1051",
    src: `
function probe(xs: number[]): number { return xs.length; }
export function f(): number { const out: number[] = [1]; const t = probe(out); out.push(2); return t; }`,
  },
  "boundary/borrow-alias-out": {
    // A readonly parameter the callee RETURNS aliases the array out — the
    // borrow only holds when the callee provably cannot alias it onward.
    verdict: "gate",
    id: "NS1051",
    src: `
function pass(xs: readonly number[]): readonly number[] { return xs; }
export function f(): number { const out: number[] = [1]; const kept = pass(out); out.push(2); return kept.length; }`,
  },
  "boundary/escape-store": {
    verdict: "gate",
    id: "NS1051",
    src: `
export interface Pair { readonly xs: readonly number[]; }
export function f(): Pair { const out: number[] = [1]; const p: Pair = { xs: out }; out.pop(); return p; }`,
  },
  "boundary/sort-shared": {
    verdict: "gate",
    id: "NS1022",
    src: `export function f(xs: number[]): number[] { xs.sort((a, b) => a - b); return xs; }`,
  },
  "boundary/indexed-write-parameter": {
    verdict: "gate",
    id: "NS1001",
    src: `export function f(xs: number[]): number { xs[0] = 1; return xs[0]; }`,
  },
  "shape/copyWithin": {
    verdict: "gate",
    id: "NS1001",
    src: `export function f(xs: readonly number[]): readonly number[] { const w = xs.slice(); w.copyWithin(0, 1); return w; }`,
  },
  "shape/sort-value-position": {
    verdict: "gate",
    id: "NS9001",
    src: `export function f(xs: readonly number[]): readonly number[] { const w = xs.slice(); return w.sort((a, b) => a - b); }`,
  },
  "shape/push-value-position": {
    verdict: "gate",
    id: "NS9001",
    src: `export function f(n: number): number { const out: number[] = []; const len = out.push(n); return len; }`,
  },
  "owned/append-write": {
    // `xs[xs.length] = v` is the one growth shape: exactly a push.
    verdict: "emits",
    src: `export function f(): readonly number[] { const out = [1]; out[out.length] = 2; out[out.length] = 3; return out; }`,
  },
  "owned/reassigned-all-owning": {
    // Flow-sensitive ownership: every assignment installs a fresh owning
    // construction, so the binding can never hold a shared array.
    verdict: "emits",
    src: `
export function f(xs: readonly number[]): readonly number[] {
  let w = xs.slice();
  w.push(1);
  w = xs.filter((x) => x > 0);
  w.push(2);
  return w;
}`,
  },
  "owned/borrowed-readonly-pass": {
    // Passing to a readonly READER parameter borrows; ownership survives.
    verdict: "emits",
    src: `
function total(xs: readonly number[]): number { let t = 0; for (const x of xs) { t += x; } return t; }
export function f(n: number): number {
  const out: number[] = [n];
  const before = total(out);
  out.push(n + 1);
  return before + total(out);
}`,
  },
  "boundary/append-write-parameter": {
    verdict: "gate",
    id: "NS1001",
    src: `export function f(xs: number[]): number { xs[xs.length] = 1; return xs.length; }`,
  },
  "shape/append-write-compound": {
    // The compound forms read the missing slot first (JS undefined).
    verdict: "gate",
    id: "NS9001",
    src: `export function f(): readonly number[] { const out = [1]; out[out.length] += 2; return out; }`,
  },
  "shape/iterating-length-change": {
    verdict: "gate",
    id: "NS9001",
    src: `
export function f(): number {
  const out: number[] = [1, 2];
  let t = 0;
  for (const x of out) { t += x; out.pop(); }
  return t;
}`,
  },
};

test("mutation matrix: the enumeration and the table cover each other exactly", () => {
  const enumerated = new Set(mutationSurface);
  const rows = new Set(Object.keys(mutationMatrix));
  const missing = [...enumerated].filter((p) => !rows.has(p));
  const unknown = [...rows].filter((p) => !enumerated.has(p));
  assert.deepEqual(missing, [], `mutation rows without a matrix entry (classify them!): ${missing.join(", ")}`);
  assert.deepEqual(unknown, [], `mutation matrix rows outside the enumeration: ${unknown.join(", ")}`);
  assert.equal(mutationSurface.length, new Set(mutationSurface).size, "duplicate mutation row names");
});

test("mutation matrix: every row produces exactly its classified outcome", () => {
  for (const name of mutationSurface) {
    const row = mutationMatrix[name];
    assert.notEqual(row.verdict, "check");
    const result = row.verdict !== "tsc" && row.files ? transpileFiles(row.files) : transpile((row as { src: string }).src);
    assert.equal(
      result.typeErrors.length,
      0,
      `${name}: fixture must be tsc-clean\n${result.typeErrors.join("\n")}`,
    );
    if (row.verdict === "gate") {
      assert.equal(result.ok, false, `${name}: expected ${row.id}, but it transpiled`);
      const ids = result.diagnostics.map((d) => d.id);
      assert.ok(ids.includes(row.id), `${name}: expected ${row.id}, got ${ids.join(", ") || "none"}`);
      const d = result.diagnostics.find((x) => x.id === row.id)!;
      assert.ok(d.message.length > d.title.length + 20, `${name}: ${row.id} message reads as a bare fallback`);
    } else {
      const details = result.diagnostics.map((d) => `${d.id} ${d.message}`).join("\n");
      assert.equal(result.ok, true, `${name}: expected clean transpile\n${details}`);
    }
  }
});

test("mutation matrix: every SUPPORTED row's Zig compiles", { skip: !hasZig, timeout: 300_000 }, () => {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "native-core-mutation-"));
  try {
    fs.copyFileSync(path.join(pkg, "rt", "rt.zig"), path.join(work, "rt.zig"));
    const imports: string[] = [];
    let i = 0;
    for (const name of mutationSurface) {
      const row = mutationMatrix[name];
      if (row.verdict !== "emits") continue;
      const result = transpile(row.src!);
      assert.equal(result.ok, true, `${name}: transpile failed before the zig step`);
      const file = `m_${String(i++).padStart(3, "0")}.zig`;
      fs.writeFileSync(path.join(work, file), result.zig!);
      imports.push(`    // ${name}\n    refAllDecls(@import("${file}"));`);
    }
    const driver = [
      `const refAllDecls = @import("std").testing.refAllDecls;`,
      ``,
      `test {`,
      ...imports,
      `}`,
      ``,
    ].join("\n");
    fs.writeFileSync(path.join(work, "driver.zig"), driver);
    try {
      execFileSync("zig", ["test", "driver.zig"], { cwd: work, encoding: "utf8", stdio: "pipe" });
    } catch (e) {
      const err = e as { stderr?: string; stdout?: string };
      assert.fail(`emitted Zig failed to compile:\n${err.stderr ?? ""}${err.stdout ?? ""}`);
    }
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
});

// ---------------------------------------------------------------------------
// The byte-text method matrix: the library-surface classification of the
// everyday string methods on core bytes (`Uint8Array`). One row per method x
// verdict — the supported set must emit, and every STAYS-OUT spelling must
// reach exactly its named teaching (never a bare tsc "property does not
// exist") — so this surface can never grow a silent gap either.

const textSurface: readonly string[] = [
  // ---- the supported byte-honest surface
  "text/toUpperCase",
  "text/toLowerCase",
  "text/repeat",
  "text/startsWith",
  "text/endsWith",
  "text/includes-bytes",
  "text/includes-number",
  "text/indexOf-bytes",
  "text/indexOf-number",
  "text/lastIndexOf-bytes",
  "text/lastIndexOf-number",
  "text/padStart",
  "text/padEnd",
  "text/trim",
  "text/trimStart",
  "text/trimEnd",
  "text/split",
  "text/at",
  // ---- taught edges of the supported set
  "text-edge/repeat-negative-literal",
  "text-edge/repeat-fractional-literal",
  "text-edge/split-empty-literal-separator",
  "text-edge/includes-fromIndex",
  // ---- the stays-out set, each with its named reason
  "text-out/charCodeAt",
  "text-out/charAt",
  "text-out/codePointAt",
  "text-out/normalize",
  "text-out/replace",
  "text-out/replaceAll",
  "text-out/localeCompare",
  "text-out/toLocaleUpperCase",
  "text-out/toLocaleLowerCase",
  "text-out/match",
  "text-out/matchAll",
  "text-out/search",
];

const textMatrix: Record<string, Row> = {
  "text/toUpperCase": {
    verdict: "emits",
    src: `export function f(s: Uint8Array): Uint8Array { return s.toUpperCase(); }`,
  },
  "text/toLowerCase": {
    verdict: "emits",
    src: `export function f(s: Uint8Array): Uint8Array { return s.toLowerCase(); }`,
  },
  "text/repeat": {
    verdict: "emits",
    src: `export function f(s: Uint8Array, n: number): Uint8Array { return s.repeat(n); }`,
  },
  "text/startsWith": {
    verdict: "emits",
    src: `export function f(s: Uint8Array, t: Uint8Array): boolean { return s.startsWith(t); }`,
  },
  "text/endsWith": {
    verdict: "emits",
    src: `export function f(s: Uint8Array, t: Uint8Array): boolean { return s.endsWith(t); }`,
  },
  "text/includes-bytes": {
    verdict: "emits",
    src: `export function f(s: Uint8Array, t: Uint8Array): boolean { return s.includes(t); }`,
  },
  "text/includes-number": {
    // The dispatch-by-argument-type rule: a number keeps JS TypedArray
    // element search (one byte value), a bytes needle is substring search.
    verdict: "emits",
    src: `export function f(s: Uint8Array, b: number): boolean { return s.includes(b); }`,
  },
  "text/indexOf-bytes": {
    verdict: "emits",
    src: `export function f(s: Uint8Array, t: Uint8Array): number { return s.indexOf(t); }`,
  },
  "text/indexOf-number": {
    verdict: "emits",
    src: `export function f(s: Uint8Array, b: number): number { return s.indexOf(b); }`,
  },
  "text/lastIndexOf-bytes": {
    verdict: "emits",
    src: `export function f(s: Uint8Array, t: Uint8Array): number { return s.lastIndexOf(t); }`,
  },
  "text/lastIndexOf-number": {
    verdict: "emits",
    src: `export function f(s: Uint8Array, b: number): number { return s.lastIndexOf(b); }`,
  },
  "text/padStart": {
    verdict: "emits",
    src: `
import { asciiBytes } from "@native-sdk/core";
export function f(s: Uint8Array, n: number): Uint8Array { return s.padStart(n, asciiBytes("0")); }
export function g(s: Uint8Array): Uint8Array { return s.padStart(8); }`,
  },
  "text/padEnd": {
    verdict: "emits",
    src: `export function f(s: Uint8Array, n: number): Uint8Array { return s.padEnd(n); }`,
  },
  "text/trim": {
    verdict: "emits",
    src: `export function f(s: Uint8Array): Uint8Array { return s.trim(); }`,
  },
  "text/trimStart": {
    verdict: "emits",
    src: `export function f(s: Uint8Array): Uint8Array { return s.trimStart(); }`,
  },
  "text/trimEnd": {
    verdict: "emits",
    src: `export function f(s: Uint8Array): Uint8Array { return s.trimEnd(); }`,
  },
  "text/split": {
    verdict: "emits",
    src: `
import { asciiBytes } from "@native-sdk/core";
export function f(s: Uint8Array): number {
  const parts = s.split(asciiBytes(","));
  let total = 0;
  for (const p of parts) total += p.length;
  return total + parts.length;
}`,
  },
  "text/at": {
    verdict: "emits",
    src: `export function f(s: Uint8Array): number { return s.at(-1) ?? -1; }`,
  },
  "text-edge/repeat-negative-literal": {
    // JS throws RangeError; a compile-time-knowable negative stops the
    // build instead of shipping the guaranteed panic.
    verdict: "gate",
    id: "NS9001",
    src: `export function f(s: Uint8Array): Uint8Array { return s.repeat(-1); }`,
  },
  "text-edge/repeat-fractional-literal": {
    // The count is an integer position (JS truncates; the subset keeps
    // integer flows integer end to end).
    verdict: "gate",
    id: "NS1016",
    src: `export function f(s: Uint8Array): Uint8Array { return s.repeat(2.5); }`,
  },
  "text-edge/split-empty-literal-separator": {
    // Per-code-point splitting would expose the UTF-16/UTF-8 seam.
    verdict: "gate",
    id: "NS9001",
    src: `
import { asciiBytes } from "@native-sdk/core";
export function f(s: Uint8Array): number { return s.split(asciiBytes("")).length; }`,
  },
  "text-edge/includes-fromIndex": {
    verdict: "gate",
    id: "NS9001",
    src: `export function f(s: Uint8Array, b: number): boolean { return s.includes(b, 2); }`,
  },
  "text-out/charCodeAt": {
    verdict: "gate",
    id: "NS1060",
    src: `export function f(s: Uint8Array): number { return s.charCodeAt(0); }`,
  },
  "text-out/charAt": {
    verdict: "gate",
    id: "NS1060",
    src: `export function f(s: Uint8Array): Uint8Array { return s.charAt(0); }`,
  },
  "text-out/codePointAt": {
    verdict: "gate",
    id: "NS1060",
    src: `export function f(s: Uint8Array): number { return s.codePointAt(0); }`,
  },
  "text-out/normalize": {
    verdict: "gate",
    id: "NS1060",
    src: `export function f(s: Uint8Array): Uint8Array { return s.normalize(); }`,
  },
  "text-out/replace": {
    verdict: "gate",
    id: "NS1060",
    src: `export function f(s: Uint8Array, t: Uint8Array): Uint8Array { return s.replace(t, t); }`,
  },
  "text-out/replaceAll": {
    verdict: "gate",
    id: "NS1060",
    src: `export function f(s: Uint8Array, t: Uint8Array): Uint8Array { return s.replaceAll(t, t); }`,
  },
  "text-out/localeCompare": {
    verdict: "gate",
    id: "NS1005",
    src: `export function f(s: Uint8Array, t: Uint8Array): number { return s.localeCompare(t); }`,
  },
  "text-out/toLocaleUpperCase": {
    verdict: "gate",
    id: "NS1005",
    src: `export function f(s: Uint8Array): Uint8Array { return s.toLocaleUpperCase(); }`,
  },
  "text-out/toLocaleLowerCase": {
    verdict: "gate",
    id: "NS1005",
    src: `export function f(s: Uint8Array): Uint8Array { return s.toLocaleLowerCase(); }`,
  },
  "text-out/match": {
    verdict: "gate",
    id: "NS1040",
    src: `export function f(s: Uint8Array): boolean { return s.match(1); }`,
  },
  "text-out/matchAll": {
    verdict: "gate",
    id: "NS1040",
    src: `export function f(s: Uint8Array): boolean { return s.matchAll(1); }`,
  },
  "text-out/search": {
    verdict: "gate",
    id: "NS1040",
    src: `export function f(s: Uint8Array): number { return s.search(1); }`,
  },
};

test("text matrix: the enumeration and the table cover each other exactly", () => {
  const enumerated = new Set(textSurface);
  const rows = new Set(Object.keys(textMatrix));
  const missing = [...enumerated].filter((p) => !rows.has(p));
  const unknown = [...rows].filter((p) => !enumerated.has(p));
  assert.deepEqual(missing, [], `text rows without a matrix entry (classify them!): ${missing.join(", ")}`);
  assert.deepEqual(unknown, [], `text matrix rows outside the enumeration: ${unknown.join(", ")}`);
  assert.equal(textSurface.length, new Set(textSurface).size, "duplicate text row names");
});

test("text matrix: every row produces exactly its classified outcome", () => {
  for (const name of textSurface) {
    const row = textMatrix[name];
    assert.notEqual(row.verdict, "check");
    assert.notEqual(row.verdict, "tsc");
    const result = transpile((row as { src: string }).src);
    assert.equal(
      result.typeErrors.length,
      0,
      `${name}: fixture must be tsc-clean\n${result.typeErrors.join("\n")}`,
    );
    if (row.verdict === "gate") {
      assert.equal(result.ok, false, `${name}: expected ${row.id}, but it transpiled`);
      const ids = result.diagnostics.map((d) => d.id);
      assert.ok(ids.includes(row.id), `${name}: expected ${row.id}, got ${ids.join(", ") || "none"}`);
      const d = result.diagnostics.find((x) => x.id === row.id)!;
      assert.ok(d.message.length > d.title.length + 20, `${name}: ${row.id} message reads as a bare fallback`);
    } else {
      const details = result.diagnostics.map((d) => `${d.id} ${d.message}`).join("\n");
      assert.equal(result.ok, true, `${name}: expected clean transpile\n${details}`);
    }
  }
});

test("text matrix: every SUPPORTED row's Zig compiles", { skip: !hasZig, timeout: 300_000 }, () => {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "native-core-text-"));
  try {
    fs.copyFileSync(path.join(pkg, "rt", "rt.zig"), path.join(work, "rt.zig"));
    const imports: string[] = [];
    let i = 0;
    for (const name of textSurface) {
      const row = textMatrix[name];
      if (row.verdict !== "emits") continue;
      const result = transpile(row.src!);
      assert.equal(result.ok, true, `${name}: transpile failed before the zig step`);
      const file = `t_${String(i++).padStart(3, "0")}.zig`;
      fs.writeFileSync(path.join(work, file), result.zig!);
      imports.push(`    // ${name}\n    refAllDecls(@import("${file}"));`);
    }
    const driver = [
      `const refAllDecls = @import("std").testing.refAllDecls;`,
      ``,
      `test {`,
      ...imports,
      `}`,
      ``,
    ].join("\n");
    fs.writeFileSync(path.join(work, "driver.zig"), driver);
    try {
      execFileSync("zig", ["test", "driver.zig"], { cwd: work, encoding: "utf8", stdio: "pipe" });
    } catch (e) {
      const err = e as { stderr?: string; stdout?: string };
      assert.fail(`emitted Zig failed to compile:\n${err.stderr ?? ""}${err.stdout ?? ""}`);
    }
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
});

test("grammar matrix: the enumeration and the table cover each other exactly", () => {
  const enumerated = new Set(productions);
  const rows = new Set(Object.keys(matrix));
  const missing = [...enumerated].filter((p) => !rows.has(p));
  const unknown = [...rows].filter((p) => !enumerated.has(p));
  assert.deepEqual(missing, [], `productions without a matrix row (classify them!): ${missing.join(", ")}`);
  assert.deepEqual(unknown, [], `matrix rows outside the enumeration: ${unknown.join(", ")}`);
  assert.equal(productions.length, new Set(productions).size, "duplicate production names");
});

test("grammar matrix: every production produces exactly its classified outcome", () => {
  for (const name of productions) {
    const row = matrix[name];
    if (row.verdict === "check") {
      const ids = ruleIds(checkOnly(row.src));
      assert.ok(ids.includes(row.id), `${name}: expected ${row.id} from the checker, got ${ids.join(", ") || "none"}`);
      continue;
    }
    const result = row.files ? transpileFiles(row.files) : transpile(row.src!);
    if (row.verdict === "tsc") {
      assert.ok(result.typeErrors.length > 0, `${name}: expected tsc itself to reject this`);
      continue;
    }
    assert.equal(
      result.typeErrors.length,
      0,
      `${name}: fixture must be tsc-clean\n${result.typeErrors.join("\n")}`,
    );
    if (row.verdict === "gate") {
      assert.equal(result.ok, false, `${name}: expected ${row.id}, but it transpiled`);
      const ids = result.diagnostics.map((d) => d.id);
      assert.ok(ids.includes(row.id), `${name}: expected ${row.id}, got ${ids.join(", ") || "none"}`);
    } else {
      const details = result.diagnostics.map((d) => `${d.id} ${d.message}`).join("\n");
      assert.equal(result.ok, true, `${name}: expected clean transpile\n${details}`);
    }
  }
});

test("grammar matrix: no gated diagnostic is a bare fallback — each names its construct", () => {
  for (const name of productions) {
    const row = matrix[name];
    if (row.verdict !== "gate") continue;
    const result = row.files ? transpileFiles(row.files) : transpile(row.src!);
    const d = result.diagnostics.find((x) => x.id === row.id)!;
    // Teaching contract: rule + fix + why — the message always carries a
    // site-specific lead-in longer than the bare rule title.
    assert.ok(d.message.length > d.title.length + 20, `${name}: ${row.id} message reads as a bare fallback`);
  }
});

test("grammar matrix: every SUPPORTED production's Zig compiles", { skip: !hasZig, timeout: 300_000 }, () => {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "native-core-grammar-"));
  try {
    fs.copyFileSync(path.join(pkg, "rt", "rt.zig"), path.join(work, "rt.zig"));
    const imports: string[] = [];
    let i = 0;
    for (const name of productions) {
      const row = matrix[name];
      if (row.verdict !== "emits") continue;
      const result = row.files ? transpileFiles(row.files) : transpile(row.src!);
      assert.equal(result.ok, true, `${name}: transpile failed before the zig step`);
      const file = `g_${String(i++).padStart(3, "0")}.zig`;
      fs.writeFileSync(path.join(work, file), result.zig!);
      imports.push(`    // ${name}\n    refAllDecls(@import("${file}"));`);
    }
    const driver = [
      `const refAllDecls = @import("std").testing.refAllDecls;`,
      ``,
      `test {`,
      ...imports,
      `}`,
      ``,
    ].join("\n");
    fs.writeFileSync(path.join(work, "driver.zig"), driver);
    try {
      execFileSync("zig", ["test", "driver.zig"], { cwd: work, encoding: "utf8", stdio: "pipe" });
    } catch (e) {
      const err = e as { stderr?: string; stdout?: string };
      assert.fail(`emitted Zig failed to compile:\n${err.stderr ?? ""}${err.stdout ?? ""}`);
    }
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
});
