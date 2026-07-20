// Conformance corpus: the transpiler's output contract is that an author who
// passes tsc and the subset checker NEVER sees a Zig compile error. Each case
// is a small subset-legal module exercising a type-boundary combination
// (literal unions x comparisons x assignments x args/returns x elements x
// integer inference). A case either EMITS — transpile-clean must imply
// zig-build-clean — or is GATED by a named teaching rule at check time.
//
// The zig-build half runs as one `zig test` over every emitted module
// (skipped when no zig toolchain is on PATH; the gating half always runs).

import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { transpile, transpileFiles } from "./helpers.ts";

const pkg = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const hasZig = spawnSync("zig", ["version"], { stdio: "ignore" }).status === 0;

interface Case {
  readonly name: string;
  /// Expected teaching rule; omitted means the case must emit Zig that compiles.
  readonly gate?: string;
  readonly src: string;
}

const enumCases: Case[] = [
  {
    name: "cross-enum equality, superset filter over category",
    src: `
export type Category = "food" | "travel" | "gear";
export type CategoryFilter = "all" | "food" | "travel" | "gear";
export interface Expense { readonly id: number; readonly category: Category; }
export interface Model { readonly expenses: readonly Expense[]; readonly filter: CategoryFilter; }
export type Msg =
  | { readonly kind: "set_filter"; readonly filter: CategoryFilter }
  | { readonly kind: "clear" };
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "set_filter": return { ...model, filter: msg.filter };
    case "clear": return { ...model, filter: "all" };
  }
}
export function visible(model: Model): readonly Expense[] {
  return model.expenses.filter((e) => model.filter === "all" || e.category === model.filter);
}
`,
  },
  {
    name: "cross-enum inequality",
    src: `
export type Small = "a" | "b";
export type Big = "a" | "b" | "c";
export function differs(s: Small, b: Big): boolean {
  return s !== b;
}
`,
  },
  {
    name: "cross-enum against an optional of the other union",
    src: `
export type Category = "food" | "travel" | "gear";
export type CategoryFilter = "all" | "food" | "travel" | "gear";
export function matches(category: Category, filter: CategoryFilter | null): boolean {
  return filter === null || category === filter;
}
`,
  },
  {
    name: "cross-enum with both sides optional (null equals only null)",
    src: `
export type Small = "a" | "b";
export type Big = "a" | "b" | "c";
export function same(s: Small | null, b: Big | null): boolean {
  return s === b;
}
`,
  },
  {
    name: "cross-enum equality with partial overlap",
    src: `
export type Left = "x" | "y";
export type Right = "y" | "z";
export function overlap(l: Left, r: Right): boolean {
  return l === r;
}
`,
  },
  {
    name: "cross-enum assignment: subset value into superset field",
    src: `
export type Category = "food" | "travel" | "gear";
export type CategoryFilter = "all" | "food" | "travel" | "gear";
export interface Model { readonly filter: CategoryFilter; }
export type Msg =
  | { readonly kind: "pick"; readonly category: Category }
  | { readonly kind: "clear" };
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "pick": return { filter: msg.category };
    case "clear": return { filter: "all" };
  }
}
`,
  },
  {
    name: "cross-enum function argument",
    src: `
export type Category = "food" | "travel" | "gear";
export type CategoryFilter = "all" | "food" | "travel" | "gear";
export function isShown(filter: CategoryFilter): boolean {
  return filter !== "all";
}
export function categoryShown(category: Category): boolean {
  return isShown(category);
}
`,
  },
  {
    name: "cross-enum function return",
    src: `
export type Category = "food" | "travel" | "gear";
export type CategoryFilter = "all" | "food" | "travel" | "gear";
export function asFilter(category: Category): CategoryFilter {
  return category;
}
`,
  },
  {
    name: "cross-enum array literal element",
    src: `
export type Category = "food" | "travel" | "gear";
export type CategoryFilter = "all" | "food" | "travel" | "gear";
export function withAll(category: Category): readonly CategoryFilter[] {
  return [category, "all"];
}
`,
  },
  {
    name: "cross-enum in ternary branches",
    src: `
export type Category = "food" | "travel" | "gear";
export type CategoryFilter = "all" | "food" | "travel" | "gear";
export function pick(category: Category, everything: boolean): CategoryFilter {
  const filter: CategoryFilter = everything ? "all" : category;
  return filter;
}
`,
  },
  {
    name: "reversed literal comparison (literal on the left)",
    src: `
export type CategoryFilter = "all" | "food" | "travel" | "gear";
export function unfiltered(filter: CategoryFilter): boolean {
  return "all" === filter;
}
`,
  },
  {
    name: "reversed kind comparison (literal on the left)",
    src: `
export type Msg = { readonly kind: "add" } | { readonly kind: "remove" };
export function isAdd(msg: Msg): boolean {
  return "add" === msg.kind;
}
`,
  },
  {
    name: "optional enum against its own literal",
    src: `
export type Category = "food" | "travel" | "gear";
export function isFood(category: Category | null): boolean {
  return category === "food";
}
`,
  },
  {
    name: "same enum, optional against plain (regression)",
    src: `
export type Category = "food" | "travel" | "gear";
export function sameCategory(a: Category | null, b: Category): boolean {
  return a === b;
}
`,
  },
  {
    name: "relational comparison on literal-union values is taught, not emitted",
    gate: "NS1004",
    src: `
export type Rank = "bronze" | "silver" | "gold";
export function before(a: Rank, b: Rank): boolean {
  return a < b;
}
`,
  },
  {
    name: "number-literal unions compare across aliases (shared integer repr)",
    src: `
export type Bit = 0 | 1;
export type Level = 0 | 1 | 2;
export function matches(b: Bit, l: Level): boolean {
  return b === l;
}
`,
  },
  {
    name: "plain alias of an enum compares as the same enum",
    src: `
export type Category = "food" | "travel" | "gear";
export type Chosen = Category;
export function same(a: Category, b: Chosen): boolean {
  return a === b;
}
`,
  },
  {
    name: "cross-enum equality under a logical chain in a filter callback",
    src: `
export type Category = "food" | "travel" | "gear";
export type CategoryFilter = "all" | "food" | "travel" | "gear";
export interface Item { readonly id: number; readonly category: Category; readonly active: boolean; }
export function shown(items: readonly Item[], filter: CategoryFilter): readonly Item[] {
  return items.filter((i) => i.active && (filter === "all" || i.category === filter));
}
`,
  },
  {
    name: "cross-enum comparison between two narrowed union payloads",
    src: `
export type Category = "food" | "travel" | "gear";
export type CategoryFilter = "all" | "food" | "travel" | "gear";
export type Ev =
  | { readonly kind: "tag"; readonly category: Category }
  | { readonly kind: "pick"; readonly filter: CategoryFilter };
export function samePick(a: Ev, b: Ev): boolean {
  if (a.kind !== "tag") return false;
  if (b.kind !== "pick") return false;
  return a.category === b.filter;
}
`,
  },
  {
    name: "cross-enum through a null-coalescing fallback",
    src: `
export type Category = "food" | "travel" | "gear";
export type CategoryFilter = "all" | "food" | "travel" | "gear";
export function effective(stored: CategoryFilter | null, category: Category): CategoryFilter {
  return stored ?? category;
}
`,
  },
];

const numberCases: Case[] = [
  {
    name: "payload demand reaches the model field it is assigned into",
    src: `
export interface Model {
  readonly durationSeconds: number;
  readonly remainingSeconds: number;
  readonly running: boolean;
}
export type Msg =
  | { readonly kind: "tick" }
  | { readonly kind: "set_duration"; readonly seconds: number };
export function initialModel(): Model {
  return { durationSeconds: 300, remainingSeconds: 300, running: false };
}
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "tick": {
      const remaining = model.remainingSeconds - 1;
      if (remaining === 0) {
        return { ...model, remainingSeconds: remaining, running: false };
      }
      return { ...model, remainingSeconds: remaining };
    }
    case "set_duration": {
      if (msg.seconds <= 0) return model;
      return { ...model, durationSeconds: msg.seconds, remainingSeconds: msg.seconds };
    }
  }
}
`,
  },
  {
    name: "minimal demand-across-assignment edge",
    src: `
export interface Model { readonly total: number; }
export type Msg =
  | { readonly kind: "set"; readonly value: number }
  | { readonly kind: "reset" };
export function update(model: Model, msg: Msg, bytes: Uint8Array): Model {
  switch (msg.kind) {
    case "set": {
      const b = bytes[msg.value];
      return { total: msg.value + b };
    }
    case "reset": return { total: 0 };
  }
}
`,
  },
  {
    name: "float taint flows backward: field and payload agree on f64",
    src: `
export interface Model { readonly ratio: number; }
export type Msg =
  | { readonly kind: "set"; readonly value: number }
  | { readonly kind: "halve" };
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "set": return { ratio: msg.value };
    case "halve": return { ratio: model.ratio * 0.5 };
  }
}
`,
  },
  {
    name: "fractional literal reaching an index slot is taught",
    gate: "NS1016",
    src: `
export function read(bytes: Uint8Array): number {
  let i = 0;
  i = 1.5;
  return bytes[i];
}
`,
  },
  {
    name: "payload both indexed and compared with a fraction is taught",
    gate: "NS1016",
    src: `
export type Msg = { readonly kind: "at"; readonly pos: number } | { readonly kind: "noop" };
export function read(msg: Msg, bytes: Uint8Array): number {
  switch (msg.kind) {
    case "at": {
      if (msg.pos === 0.5) return 0;
      return bytes[msg.pos];
    }
    case "noop": return 0;
  }
}
`,
  },
  {
    name: "float-valued field flowing into an index slot is taught",
    gate: "NS1016",
    src: `
export interface Model { readonly ratio: number; }
export function init(): Model { return { ratio: 0.5 }; }
export function sample(model: Model, bytes: Uint8Array): number {
  const at = model.ratio;
  return bytes[at];
}
`,
  },
  {
    name: "length scaled by a fraction widens into the float site",
    src: `
export function half(bytes: Uint8Array): number {
  return bytes.length * 0.5;
}
`,
  },
  {
    name: "float parameter compared against a length read",
    src: `
export function pastEnd(cursor: number, bytes: Uint8Array): boolean {
  return cursor * 1.5 > bytes.length;
}
`,
  },
  {
    name: "returns mixing a length read with a fractional literal",
    src: `
export function measure(bytes: Uint8Array, empty: boolean): number {
  if (empty) return 0.5;
  return bytes.length;
}
`,
  },
  {
    name: "fractional literal used directly as an index is taught",
    gate: "NS1016",
    src: `
export function bad(bytes: Uint8Array): number {
  return bytes[1.5];
}
`,
  },
  {
    name: "optional payload with integer fallback feeding an index",
    src: `
export interface Model { readonly cursor: number | null; }
export function at(model: Model, bytes: Uint8Array): number {
  const i = model.cursor ?? 0;
  return bytes[i];
}
`,
  },
  {
    name: "demand travels through a chain of locals into the field",
    src: `
export interface Model { readonly offset: number; }
export type Msg = { readonly kind: "move"; readonly by: number } | { readonly kind: "stay" };
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "move": {
      const step = msg.by;
      const next = step + model.offset;
      return { offset: next };
    }
    case "stay": return model;
  }
}
export function read(model: Model, bytes: Uint8Array): number {
  return bytes[model.offset];
}
`,
  },
  {
    name: "callee demand claims the caller's field argument",
    src: `
export interface Model { readonly at: number; }
export function byteAt(bytes: Uint8Array, i: number): number {
  return bytes[i];
}
export function sample(model: Model, bytes: Uint8Array): number {
  return byteAt(bytes, model.at);
}
`,
  },
  {
    name: "Math.max mixing an integer constant with a float demotes the constant",
    src: `
export const FLOOR = 4;
export function clampScale(x: number): number {
  return Math.max(FLOOR, x * 0.25);
}
`,
  },
  {
    name: "Math.min mixing a float expression with a length read widens the read",
    src: `
export function capped(x: number, bytes: Uint8Array): number {
  return Math.min(x * 0.5, bytes.length);
}
`,
  },
  {
    name: "guarded payload access through and/or chains and an else branch",
    src: `
export type Msg = { readonly kind: "add"; readonly n: number } | { readonly kind: "zero" };
export function inRange(msg: Msg, bytes: Uint8Array): boolean {
  return msg.kind === "add" && msg.n < bytes.length;
}
export function inRangeOrZero(msg: Msg, bytes: Uint8Array): boolean {
  return msg.kind !== "add" || msg.n < bytes.length;
}
export function low(msg: Msg): number {
  if (msg.kind !== "add") {
    return 0;
  } else {
    return msg.n & 255;
  }
}
`,
  },
  {
    name: "template hole fed by a length read stays integer",
    src: `
import { asciiBytes } from "@native-sdk/core";
export function label(items: Uint8Array): Uint8Array {
  return asciiBytes(\`count \${items.length}\`);
}
`,
  },
  {
    name: "demanded payload appended to a number array widens at the element",
    src: `
export function record(samples: readonly number[], n: number, bytes: Uint8Array): readonly number[] {
  const probe = bytes[n];
  return [...samples, n + probe];
}
`,
  },
  {
    name: "map over a number array keeps float element math",
    src: `
export function doubled(samples: readonly number[]): readonly number[] {
  return samples.map((x) => x * 2);
}
`,
  },
  {
    name: "filter over a number array compares floats",
    src: `
export function positive(samples: readonly number[]): readonly number[] {
  return samples.filter((x) => x > 0);
}
`,
  },
  {
    name: "indexing by a number-array element is taught",
    gate: "NS1016",
    src: `
export function gather(indices: readonly number[], bytes: Uint8Array): readonly number[] {
  return indices.map((x) => bytes[x]);
}
`,
  },
  {
    name: "uninitialized integer local assigned from payload and literal",
    src: `
export type Msg = { readonly kind: "jump"; readonly to: number } | { readonly kind: "home" };
export function land(msg: Msg, bytes: Uint8Array): number {
  let target: number;
  switch (msg.kind) {
    case "jump": {
      target = msg.to;
      break;
    }
    case "home": {
      target = 0;
      break;
    }
  }
  return bytes[target];
}
`,
  },
  {
    name: "compound assignment feeds demand back through the accumulator",
    src: `
export type Msg = { readonly kind: "add"; readonly n: number } | { readonly kind: "zero" };
export function tally(msg: Msg, bytes: Uint8Array): number {
  let acc = 0;
  if (msg.kind === "add") acc += msg.n;
  return bytes[acc];
}
`,
  },
  {
    name: "float-bounded counting loop stays f64 end to end",
    src: `
export function steps(limit: number): number {
  let total = 0.0;
  for (let i = 0; i < limit * 0.5; i++) {
    total += 1;
  }
  return total;
}
`,
  },
  {
    name: "integer counting loop over bytes (regression)",
    src: `
export function spaces(bytes: Uint8Array): number {
  let n = 0;
  for (let i = 0; i < bytes.length; i++) {
    if (bytes[i] === 32) n += 1;
  }
  return n;
}
`,
  },
  {
    name: "undemanded payload mixed with a fraction in a ternary goes f64",
    src: `
export type Msg = { readonly kind: "set"; readonly value: number } | { readonly kind: "half" };
export function level(msg: Msg): number {
  return msg.kind === "set" ? msg.value : 0.5;
}
`,
  },
  {
    name: "demanded payload mixed with a fraction in a ternary is taught",
    gate: "NS1016",
    src: `
export type Msg = { readonly kind: "set"; readonly value: number } | { readonly kind: "half" };
export function pick(msg: Msg, flag: boolean, bytes: Uint8Array): number {
  const v = flag && msg.kind === "set" ? msg.value : 0.5;
  return bytes[v];
}
`,
  },
  {
    name: "two undecided payloads compare as the same float class",
    src: `
export type Msg =
  | { readonly kind: "pair"; readonly a: number; readonly b: number }
  | { readonly kind: "none" };
export function same(msg: Msg): boolean {
  if (msg.kind !== "pair") return false;
  return msg.a === msg.b;
}
`,
  },
  {
    name: "comparison against a proven-integer side claims the payload",
    src: `
export type Msg = { readonly kind: "check"; readonly n: number } | { readonly kind: "skip" };
export function atEnd(msg: Msg, bytes: Uint8Array): boolean {
  if (msg.kind !== "check") return false;
  return msg.n === bytes.length;
}
`,
  },
  {
    name: "bitwise demand on a payload (R9 regression)",
    src: `
export type Msg = { readonly kind: "mask"; readonly bits: number } | { readonly kind: "none" };
export function low(msg: Msg): number {
  if (msg.kind !== "mask") return 0;
  return msg.bits & 255;
}
`,
  },
  {
    name: "optional float field takes fractions and payload values",
    src: `
export interface Model { readonly hue: number | null; }
export type Msg = { readonly kind: "tint"; readonly hue: number } | { readonly kind: "clear" };
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "tint": return { hue: msg.hue * 0.1 };
    case "clear": return { hue: null };
  }
}
`,
  },
  {
    name: "orelse fusion on an optional number result (R7 regression)",
    src: `
export function find(xs: Uint8Array, want: number): number | null {
  for (let i = 0; i < xs.length; i++) {
    if (xs[i] === want) return i;
  }
  return null;
}
export function findOrZero(xs: Uint8Array, want: number): number {
  const hit = find(xs, want);
  if (hit === null) return 0;
  return hit;
}
`,
  },
  {
    name: "optional numeric equality in every expression position (null-safe, no unwrap)",
    src: `
export function isZero(cls: number | null): boolean {
  return cls === 0;
}
export function nonZero(cls: number | null): boolean {
  return cls !== 0;
}
export function reversed(cls: number | null): boolean {
  return 0 === cls;
}
export function inTernary(cls: number | null): number {
  return cls === 0 ? 1 : cls !== 0 ? 2 : 3;
}
export function inChain(cls: number | null, flag: boolean): boolean {
  return flag && cls === 1;
}
export function bothOptional(a: number | null, b: number | null): boolean {
  return a === b;
}
export function againstValue(cls: number | null, n: number): boolean {
  return cls === n;
}
`,
  },
  {
    name: "division is float always; integer reads widen into the site",
    src: `
export function ratio(a: number, b: number): number {
  return a / b;
}
export function halfLen(bytes: Uint8Array): number {
  return bytes.length / 2;
}
`,
  },
  {
    name: "remainder on integer and float sites",
    src: `
export function wrapAt(bytes: Uint8Array, at: number): number {
  return bytes[at % bytes.length];
}
export function frac(x: number): number {
  return x % 1;
}
`,
  },
  {
    name: "bitwise beyond a provable 32-bit range takes the wrap helpers",
    src: `
export function band(a: number, b: number): number {
  return a & b;
}
export function bor(a: number, b: number): number {
  return a | b;
}
export function bxor(a: number, b: number): number {
  return a ^ b;
}
export function bmask(a: number): number {
  return a & 255;
}
`,
  },
  {
    name: "Math.round emits in value positions",
    src: `
export function nearest(x: number): number {
  return Math.round(x);
}
export interface Model { readonly scale: number; }
export function snapped(model: Model): number {
  return Math.round(model.scale * 1.5);
}
`,
  },
  {
    name: "Math.round feeding an index slot is taught, not emitted",
    gate: "NS1016",
    src: `
export function sample(bytes: Uint8Array, x: number): number {
  return bytes[Math.round(x)];
}
`,
  },
  {
    name: "union-typed local built by a selector ternary carries its annotation",
    src: `
export type Ev =
  | { readonly kind: "insert"; readonly text: Uint8Array }
  | { readonly kind: "move"; readonly dx: number; readonly dy: number }
  | { readonly kind: "clear" };
export function weigh(sel: number, payload: Uint8Array, dx: number, dy: number): number {
  const ev: Ev = sel === 0 ? { kind: "insert", text: payload } : sel === 1 ? { kind: "move", dx: dx, dy: dy } : { kind: "clear" };
  switch (ev.kind) {
    case "insert": return ev.text.length;
    case "move": return ev.dx + ev.dy;
    case "clear": return 0;
  }
}
`,
  },
  {
    // R7d dual: `x === undefined ? A : <uses x>` narrows the ELSE branch —
    // the find-miss ternary the guard-first spelling already covered, in
    // the miss-first order (both operand orders).
    name: "=== undefined / === null miss-first ternaries narrow the else branch",
    src: `
export interface Task { readonly id: number; }
export interface Model { readonly tasks: readonly Task[]; readonly sel: number | null; }
export function firstOrMinus(model: Model, id: number): number {
  const found = model.tasks.find((t) => t.id === id);
  return found === undefined ? -1 : found.id + 1;
}
export function flipped(model: Model, id: number): number {
  const found = model.tasks.find((t) => t.id === id);
  return undefined === found ? -1 : found.id + 1;
}
export function selPlus(model: Model): number {
  return model.sel === null ? 0 : model.sel + 1;
}
`,
  },
  {
    // R7 dual in statement position: `if (x === null) { A } else { uses x }`
    // narrows the else branch, and an exiting miss branch narrows the
    // statements after the if too (else-if chains included).
    name: "=== null if/else statement narrowing, else-if chains, and post-if reads",
    src: `
export interface Task { readonly id: number; }
export interface Model { readonly tasks: readonly Task[]; }
export function branch(model: Model, id: number, bytes: Uint8Array): number {
  const found = model.tasks.find((t) => t.id === id);
  if (found === undefined) {
    return 0;
  } else {
    return bytes[found.id];
  }
}
export function chained(model: Model, id: number): number {
  const found = model.tasks.find((t) => t.id === id);
  if (found === undefined) {
    return -1;
  } else if (found.id > 5) {
    return found.id * 2;
  }
  return found.id;
}
`,
  },
  {
    // R7 fusion over a TERNARY initializer: `const x = c ? f(a) : g(a);
    // if (x === null) <exit>` lowers to `(if (c) f else g) orelse <exit>`
    // — the conditional must parenthesize, or Zig binds the orelse to the
    // ELSE arm alone (the system-monitor-ts memory-sampler shape).
    name: "orelse fusion over a ternary initializer parenthesizes the conditional",
    src: `
export interface Sample { readonly used: number; }
function parseA(bytes: Uint8Array): Sample | null {
  if (bytes.length === 0) return null;
  return { used: bytes[0] };
}
function parseB(bytes: Uint8Array): Sample | null {
  if (bytes.length < 2) return null;
  return { used: bytes[1] };
}
export function pick(first: boolean, bytes: Uint8Array): number {
  const sample = first ? parseA(bytes) : parseB(bytes);
  if (sample === null) {
    return -1;
  }
  return sample.used;
}
export function pickInline(first: boolean, bytes: Uint8Array): number {
  const sample = first ? parseA(bytes) : parseB(bytes);
  if (sample === null) return -1;
  return sample.used;
}
`,
  },
  {
    // Mixed-class optional equality: an optional slot the number tier
    // classes i64 compared against a float value routes through the
    // null-safe widening helper instead of emitting \`?i64 == f64\`.
    name: "optional integer slot against a float value widens null-safely",
    src: `
export interface Model { readonly sel: number | null; readonly frac: number; }
export function pickAt(model: Model, bytes: Uint8Array): number {
  if (model.sel !== null) return bytes[model.sel];
  return 0;
}
export function atHalf(model: Model): boolean {
  const half = model.frac * 0.5;
  return model.sel === half;
}
export function offHalf(model: Model): boolean {
  const half = model.frac * 0.5;
  return model.sel !== half;
}
export function atFractionLiteral(model: Model): boolean {
  return model.sel === 0.5;
}
`,
  },
];

const structuralCases: Case[] = [
  {
    // The five wiring channels together: the emitted module must carry
    // compilable fns, arm consts, and the envMsgs tuple.
    name: "the host-event wiring channels emit and compile",
    src: `
export type ColorScheme = "light" | "dark";
export interface FrameEvent { readonly width: number; readonly height: number; readonly timestampMs: number; readonly intervalMs: number; }
export interface KeyEvent { readonly key: string; readonly shift: boolean; readonly control: boolean; readonly alt: boolean; readonly super: boolean; }
export interface ChromeInsets { readonly top: number; readonly right: number; readonly bottom: number; readonly left: number; }
export interface ChromeButtons { readonly x: number; readonly y: number; readonly width: number; readonly height: number; }
export interface Model { readonly width: number; readonly dark: boolean; readonly chromeTop: number; readonly base: Uint8Array; }
export type Msg =
  | { readonly kind: "resized"; readonly width: number }
  | { readonly kind: "toggled" }
  | { readonly kind: "appearance_changed"; readonly colorScheme: ColorScheme; readonly reduceMotion: boolean; readonly highContrast: boolean }
  | { readonly kind: "chrome_changed"; readonly insets: ChromeInsets; readonly buttons: ChromeButtons; readonly tabsProjected: boolean }
  | { readonly kind: "base_set"; readonly value: Uint8Array };
export function frameMsg(model: Model, frame: FrameEvent): Msg | null {
  if (frame.width !== model.width) return { kind: "resized", width: frame.width };
  return null;
}
export function keyMsg(key: KeyEvent): Msg | null {
  if (key.control || key.alt || key.super || key.shift) return null;
  if (key.key === "space") return { kind: "toggled" };
  return null;
}
export const appearanceMsg = "appearance_changed";
export const chromeMsg = "chrome_changed";
export const envMsgs = [{ env: "APP_BASE", msg: "base_set" }] as const;
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "resized": return { ...model, width: msg.width };
    case "toggled": return model;
    case "appearance_changed": return { ...model, dark: msg.colorScheme === "dark" };
    case "chrome_changed": return { ...model, chromeTop: msg.insets.top };
    case "base_set": return { ...model, base: msg.value };
  }
}
`,
  },
  {
    name: "record array update with spread, map, and filter (R15-R17 regression)",
    src: `
export interface Task { readonly id: number; readonly done: boolean; }
export interface Model { readonly tasks: readonly Task[]; readonly nextId: number; }
export type Msg =
  | { readonly kind: "add" }
  | { readonly kind: "toggle"; readonly id: number }
  | { readonly kind: "purge" };
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "add":
      return { ...model, tasks: [...model.tasks, { id: model.nextId, done: false }], nextId: model.nextId + 1 };
    case "toggle":
      return { ...model, tasks: model.tasks.map((t) => (t.id === msg.id ? { ...t, done: !t.done } : t)) };
    case "purge":
      return { ...model, tasks: model.tasks.filter((t) => !t.done) };
  }
}
`,
  },
  {
    name: "multi-field union arm mixing a cross-enum value and a demanded number",
    src: `
export type Category = "food" | "travel" | "gear";
export type CategoryFilter = "all" | "food" | "travel" | "gear";
export type Msg =
  | { readonly kind: "place"; readonly filter: CategoryFilter; readonly at: number }
  | { readonly kind: "none" };
export function place(category: Category, at: number, bytes: Uint8Array): Msg {
  const probe = bytes[at];
  if (probe === 0) return { kind: "none" };
  return { kind: "place", filter: category, at: at };
}
`,
  },
  {
    name: "switch payload capture feeding integer math (R13 regression)",
    src: `
export type Ev =
  | { readonly kind: "insert"; readonly text: Uint8Array }
  | { readonly kind: "move"; readonly dx: number; readonly dy: number }
  | { readonly kind: "clear" };
export function weight(ev: Ev): number {
  switch (ev.kind) {
    case "insert": return ev.text.length;
    case "move": return ev.dx + ev.dy;
    case "clear": return 0;
  }
}
export function at(ev: Ev, bytes: Uint8Array): number {
  return bytes[weight(ev)];
}
`,
  },
];

const cmdCases: Case[] = [
  {
    name: "Cmd pair-return with every v1 factory (effects channel regression)",
    src: `
import { Cmd } from "@native-sdk/core";
export interface Model { readonly count: number; readonly saved: number; }
export type Msg =
  | { readonly kind: "add" }
  | { readonly kind: "save" }
  | { readonly kind: "stamp" }
  | { readonly kind: "tick"; readonly at: number };
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "add": return { ...model, count: model.count + 1 };
    case "save": return [{ ...model, saved: model.count }, Cmd.persist()];
    case "stamp": return [model, Cmd.batch([Cmd.now("tick"), Cmd.host("beep", model.count)])];
    case "tick": return { ...model, count: msg.at };
  }
}
`,
  },
  {
    name: "conditional command in the return slot",
    src: `
import { Cmd } from "@native-sdk/core";
export interface Model { readonly count: number; }
export type Msg = { readonly kind: "add" } | { readonly kind: "noop" };
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "add": return [{ count: model.count + 1 }, model.count > 10 ? Cmd.persist() : Cmd.none];
    case "noop": return model;
  }
}
`,
  },
  {
    name: "Cmd escaping into a helper is taught, not emitted",
    gate: "NS1017",
    src: `
import { Cmd } from "@native-sdk/core";
export interface Model { readonly count: number; }
export type Msg = { readonly kind: "add" } | { readonly kind: "noop" };
function saveCmd(): Cmd<Msg> {
  return Cmd.persist();
}
export function update(model: Model, msg: Msg): Model { return model; }
`,
  },
];

// The Cmd v2 surface: bytes/record payloads, keyed routed requests, cancel,
// the initialModel boot pair, and declarative subscriptions — each either
// emitting zig-compile-clean or gated by its teaching rule.
const cmdV2Cases: Case[] = [
  {
    name: "Cmd.host bytes payloads: model bytes, fresh bytes, empty bytes",
    src: `
import { Cmd, asciiBytes } from "@native-sdk/core";
export interface Model { readonly draft: Uint8Array; }
export type Msg = { readonly kind: "save" } | { readonly kind: "flush" } | { readonly kind: "zero" };
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "save": return [model, Cmd.host("store.write", model.draft)];
    case "flush": return [model, Cmd.host("store.write", asciiBytes(\`\${model.draft.length} bytes\`))];
    case "zero": return [model, Cmd.host("store.write", new Uint8Array(0))];
  }
}
`,
  },
  {
    name: "Cmd.host record payload lowers through the derived encoder",
    src: `
import { Cmd, asciiBytes } from "@native-sdk/core";
export interface Model { readonly gain: number; readonly on: boolean; }
export type Msg = { readonly kind: "save" } | { readonly kind: "noop" };
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "save": return [model, Cmd.host("cfg.save", { gain: model.gain, on: model.on, tag: asciiBytes("v2") })];
    case "noop": return model;
  }
}
`,
  },
  {
    name: "Cmd.request routes results by arm name, keyed and unkeyed; cancel drops a key",
    src: `
import { Cmd, asciiBytes } from "@native-sdk/core";
export interface Model { readonly data: Uint8Array; readonly errs: number; }
export type Msg =
  | { readonly kind: "load" }
  | { readonly kind: "probe" }
  | { readonly kind: "stop" }
  | { readonly kind: "loaded"; readonly body: Uint8Array }
  | { readonly kind: "failed"; readonly why: Uint8Array };
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "load": return [model, Cmd.request("store.read", asciiBytes("notes.json"), { key: "load", ok: "loaded", err: "failed" })];
    case "probe": return [model, Cmd.request("store.read", model.data, { ok: "loaded", err: "failed" })];
    case "stop": return [model, Cmd.batch([Cmd.cancel("load"), Cmd.persist()])];
    case "loaded": return { ...model, data: msg.body };
    case "failed": return { ...model, errs: model.errs + 1 };
  }
}
`,
  },
  {
    name: "initialModel boot pair: the init command runs once at install",
    src: `
import { Cmd, asciiBytes } from "@native-sdk/core";
export interface Model { readonly data: Uint8Array; }
export type Msg =
  | { readonly kind: "loaded"; readonly body: Uint8Array }
  | { readonly kind: "failed"; readonly why: Uint8Array };
export function initialModel(): [Model, Cmd<Msg>] {
  return [{ data: new Uint8Array(0) }, Cmd.request("store.read", asciiBytes("boot.bin"), { key: "boot", ok: "loaded", err: "failed" })];
}
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "loaded": return { data: msg.body };
    case "failed": return model;
  }
}
`,
  },
  {
    name: "subscriptions: timers derived from the model, batched, paused via Sub.none",
    src: `
import { Sub } from "@native-sdk/core";
export interface Model { readonly running: boolean; readonly fast: boolean; readonly ticks: number; }
export type Msg =
  | { readonly kind: "toggle" }
  | { readonly kind: "tick"; readonly at: number }
  | { readonly kind: "blink"; readonly at: number };
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "toggle": return { ...model, running: !model.running };
    case "tick": return { ...model, ticks: model.ticks + 1 };
    case "blink": return model;
  }
}
export function subscriptions(model: Model): Sub<Msg> {
  if (!model.running) return Sub.none;
  return Sub.batch([
    Sub.timer("tick", model.fast ? 40 : 100, "tick"),
    Sub.timer("blink", 250, "blink"),
  ]);
}
`,
  },
  {
    name: "a payload mixed with extra arguments is taught",
    gate: "NS1026",
    src: `
import { Cmd } from "@native-sdk/core";
export interface Model { readonly draft: Uint8Array; readonly count: number; }
export type Msg = { readonly kind: "save" } | { readonly kind: "noop" };
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "save": return [model, Cmd.host("store.write", model.draft as never, model.count as never)];
    case "noop": return model;
  }
}
`,
  },
  {
    name: "a nested record payload field is taught (no wire encoding)",
    gate: "NS1026",
    src: `
import { Cmd } from "@native-sdk/core";
export interface Inner { readonly a: number; }
export interface Model { readonly inner: Inner; }
export type Msg = { readonly kind: "save" } | { readonly kind: "noop" };
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "save": return [model, Cmd.host("cfg.save", { nested: model.inner as never })];
    case "noop": return model;
  }
}
`,
  },
  {
    name: "a routing callback is taught, not run (routing is data)",
    gate: "NS1027",
    src: `
import { Cmd, type BytesKind } from "@native-sdk/core";
export interface Model { readonly data: Uint8Array; }
export type Msg =
  | { readonly kind: "load" }
  | { readonly kind: "loaded"; readonly body: Uint8Array }
  | { readonly kind: "failed"; readonly why: Uint8Array };
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "load": return [model, Cmd.request("store.read", model.data, {
      ok: ((body: Uint8Array) => ({ kind: "loaded", body })) as unknown as BytesKind<Msg>,
      err: "failed",
    })];
    case "loaded": return { ...model, data: msg.body };
    case "failed": return model;
  }
}
`,
  },
  {
    name: "a non-literal routing arm is taught (decoders derive at build time)",
    gate: "NS1027",
    src: `
import { Cmd } from "@native-sdk/core";
export interface Model { readonly data: Uint8Array; readonly alt: boolean; }
export type Msg =
  | { readonly kind: "load" }
  | { readonly kind: "loaded"; readonly body: Uint8Array }
  | { readonly kind: "failed"; readonly why: Uint8Array };
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "load": return [model, Cmd.request("store.read", model.data, {
      ok: model.alt ? "loaded" : "loaded",
      err: "failed",
    })];
    case "loaded": return { ...model, data: msg.body };
    case "failed": return model;
  }
}
`,
  },
  {
    name: "a routing arm without a bytes payload is taught",
    gate: "NS1027",
    src: `
import { Cmd, type BytesKind } from "@native-sdk/core";
export interface Model { readonly data: Uint8Array; readonly ticks: number; }
export type Msg =
  | { readonly kind: "load" }
  | { readonly kind: "tick"; readonly at: number }
  | { readonly kind: "failed"; readonly why: Uint8Array };
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "load": return [model, Cmd.request("store.read", model.data, {
      ok: "tick" as BytesKind<Msg>,
      err: "failed",
    })];
    case "tick": return { ...model, ticks: model.ticks + 1 };
    case "failed": return model;
  }
}
`,
  },
  {
    name: "a Sub in update's return is taught (subscriptions are declared, not issued)",
    gate: "NS1025",
    src: `
import { Sub } from "@native-sdk/core";
export interface Model { readonly ticks: number; }
export type Msg = { readonly kind: "go" } | { readonly kind: "tick"; readonly at: number };
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "go": {
      const sub = Sub.timer<Msg>("tick", 100, "tick");
      return model;
    }
    case "tick": return { ...model, ticks: model.ticks + 1 };
  }
}
`,
  },
  {
    name: "a Sub stored in a local inside subscriptions is taught",
    gate: "NS1025",
    src: `
import { Sub } from "@native-sdk/core";
export interface Model { readonly ticks: number; }
export type Msg = { readonly kind: "noop" } | { readonly kind: "tick"; readonly at: number };
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "noop": return model;
    case "tick": return { ...model, ticks: model.ticks + 1 };
  }
}
export function subscriptions(model: Model): Sub<Msg> {
  const stored = Sub.timer<Msg>("tick", 100, "tick");
  return stored;
}
`,
  },
  {
    name: "a Sub-typed return outside subscriptions is taught",
    gate: "NS1025",
    src: `
import { Sub } from "@native-sdk/core";
export interface Model { readonly ticks: number; }
export type Msg = { readonly kind: "noop" } | { readonly kind: "tick"; readonly at: number };
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "noop": return model;
    case "tick": return { ...model, ticks: model.ticks + 1 };
  }
}
function timers(model: Model): Sub<Msg> {
  return Sub.timer("tick", 100, "tick");
}
`,
  },
  {
    name: "a timer target without a single number payload is taught",
    gate: "NS1027",
    src: `
import { Sub, type TimestampKind } from "@native-sdk/core";
export interface Model { readonly data: Uint8Array; }
export type Msg = { readonly kind: "noop" } | { readonly kind: "loaded"; readonly body: Uint8Array };
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "noop": return model;
    case "loaded": return { data: msg.body };
  }
}
export function subscriptions(model: Model): Sub<Msg> {
  return Sub.timer("load", 100, "loaded" as TimestampKind<Msg>);
}
`,
  },
];

// A shared preamble for the named-op cases: every arm shape a routed op
// can target, plus one of each wrong shape to gate against.
const namedOpMsg = `
export interface Model { readonly code: number; readonly data: Uint8Array; readonly errs: number; }
export type Msg =
  | { readonly kind: "go" }
  | { readonly kind: "loaded"; readonly body: Uint8Array }
  | { readonly kind: "wrote" }
  | { readonly kind: "fetched"; readonly status: number; readonly body: Uint8Array }
  | { readonly kind: "fired"; readonly at: number }
  | { readonly kind: "failed"; readonly why: Uint8Array };
export function initialModel(): Model { return { code: -1, data: new Uint8Array(0), errs: 0 }; }
`;

// Slice C: the named buffered engine ops (readFile/writeFile/fetch/
// clipboard) and the one-shot delay — emit-clean in their exact shapes,
// gated with the taught rules everywhere else.
const namedOpCases: Case[] = [
  {
    name: "every named op emits in its documented shape",
    src: `
import { Cmd, asciiBytes } from "@native-sdk/core";
export interface Model { readonly code: number; readonly data: Uint8Array; readonly saved: boolean; readonly errs: number; readonly at: number; }
export type Msg =
  | { readonly kind: "go"; readonly which: number }
  | { readonly kind: "loaded"; readonly body: Uint8Array }
  | { readonly kind: "wrote" }
  | { readonly kind: "fetched"; readonly status: number; readonly body: Uint8Array }
  | { readonly kind: "fired"; readonly at: number }
  | { readonly kind: "failed"; readonly why: Uint8Array };
export function initialModel(): Model { return { code: -1, data: new Uint8Array(0), saved: false, errs: 0, at: -1 }; }
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go":
      if (msg.which === 0) return [model, Cmd.readFile(asciiBytes("a.bin"), { key: "r", ok: "loaded", err: "failed" })];
      if (msg.which === 1) return [model, Cmd.writeFile(asciiBytes("a.bin"), model.data, { key: "w", ok: "wrote", err: "failed" })];
      if (msg.which === 2) return [model, Cmd.fetch({ url: asciiBytes("https://a.test"), method: "PUT", headers: { accept: "text/plain" }, body: model.data, timeoutMs: 1000 }, { ok: "fetched", err: "failed" })];
      if (msg.which === 3) return [model, Cmd.fetch({ url: model.data }, { key: "g", ok: "fetched", err: "failed" })];
      if (msg.which === 4) return [model, Cmd.clipboardWrite(model.data)];
      if (msg.which === 5) return [model, Cmd.clipboardRead({ key: "p", ok: "loaded", err: "failed" })];
      if (msg.which === 6) return [model, Cmd.delay("d", model.at + 100, "fired")];
      return [model, Cmd.batch([Cmd.delay("d", 250, "fired"), Cmd.cancel("d")])];
    case "loaded": return { ...model, data: msg.body };
    case "wrote": return { ...model, saved: true };
    case "fetched": return { ...model, code: msg.status, data: msg.body };
    case "fired": return { ...model, at: msg.at };
    case "failed": return { ...model, errs: model.errs + 1 };
  }
}
`,
  },
  {
    name: "a fetch ok arm that is not a {status, body} record is taught",
    gate: "NS1027",
    src: `
import { Cmd, asciiBytes, type FetchedKind } from "@native-sdk/core";
${namedOpMsg}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.fetch({ url: asciiBytes("https://a.test") }, { ok: "loaded" as FetchedKind<Msg>, err: "failed" })];
    case "loaded": return { ...model, data: msg.body };
    case "wrote": return model;
    case "fetched": return { ...model, code: msg.status, data: msg.body };
    case "fired": return model;
    case "failed": return { ...model, errs: model.errs + 1 };
  }
}
`,
  },
  {
    name: "a writeFile ok arm carrying a payload is taught",
    gate: "NS1027",
    src: `
import { Cmd, asciiBytes, type EmptyKind } from "@native-sdk/core";
${namedOpMsg}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.writeFile(asciiBytes("a.bin"), model.data, { ok: "loaded" as EmptyKind<Msg>, err: "failed" })];
    case "loaded": return { ...model, data: msg.body };
    case "wrote": return model;
    case "fetched": return { ...model, code: msg.status, data: msg.body };
    case "fired": return model;
    case "failed": return { ...model, errs: model.errs + 1 };
  }
}
`,
  },
  {
    name: "a delay target without a single number payload is taught",
    gate: "NS1027",
    src: `
import { Cmd, type TimestampKind } from "@native-sdk/core";
${namedOpMsg}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.delay("d", 100, "loaded" as TimestampKind<Msg>)];
    case "loaded": return { ...model, data: msg.body };
    case "wrote": return model;
    case "fetched": return { ...model, code: msg.status, data: msg.body };
    case "fired": return model;
    case "failed": return { ...model, errs: model.errs + 1 };
  }
}
`,
  },
  {
    name: "a runtime bytes fetch header value emits and compiles (names stay compile-time)",
    src: `
import { Cmd, asciiBytes } from "@native-sdk/core";
${namedOpMsg}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.fetch({ url: asciiBytes("https://a.test"), headers: { authorization: model.data, accept: "text/plain", "x-trace": asciiBytes("t-1") } }, { ok: "fetched", err: "failed" })];
    case "loaded": return { ...model, data: msg.body };
    case "wrote": return model;
    case "fetched": return { ...model, code: msg.status, data: msg.body };
    case "fired": return model;
    case "failed": return { ...model, errs: model.errs + 1 };
  }
}
`,
  },
  {
    name: "a smuggled string fetch header value is taught (values are literals or bytes)",
    gate: "NS1029",
    src: `
import { Cmd, asciiBytes } from "@native-sdk/core";
${namedOpMsg}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.fetch({ url: asciiBytes("https://a.test"), headers: { etag: model.errs > 0 ? "a" : "b" } }, { ok: "fetched", err: "failed" })];
    case "loaded": return { ...model, data: msg.body };
    case "wrote": return model;
    case "fetched": return { ...model, code: msg.status, data: msg.body };
    case "fired": return model;
    case "failed": return { ...model, errs: model.errs + 1 };
  }
}
`,
  },
  {
    name: "a non-flat headers record is taught",
    gate: "NS1029",
    src: `
import { Cmd, asciiBytes } from "@native-sdk/core";
${namedOpMsg}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.fetch({ url: asciiBytes("https://a.test"), headers: { nested: { deep: "x" } } as unknown as { readonly [name: string]: string } }, { ok: "fetched", err: "failed" })];
    case "loaded": return { ...model, data: msg.body };
    case "wrote": return model;
    case "fetched": return { ...model, code: msg.status, data: msg.body };
    case "fired": return model;
    case "failed": return { ...model, errs: model.errs + 1 };
  }
}
`,
  },
  {
    name: "a string path smuggled past the bytes rule is taught",
    gate: "NS1029",
    src: `
import { Cmd } from "@native-sdk/core";
${namedOpMsg}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.readFile("store.bin" as unknown as Uint8Array, { ok: "loaded", err: "failed" })];
    case "loaded": return { ...model, data: msg.body };
    case "wrote": return model;
    case "fetched": return { ...model, code: msg.status, data: msg.body };
    case "fired": return model;
    case "failed": return { ...model, errs: model.errs + 1 };
  }
}
`,
  },
  {
    name: "an over-bound path literal stops at compile time",
    gate: "NS1030",
    src: `
import { Cmd, asciiBytes } from "@native-sdk/core";
${namedOpMsg}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.readFile(asciiBytes(${JSON.stringify("p".repeat(1025))}), { ok: "loaded", err: "failed" })];
    case "loaded": return { ...model, data: msg.body };
    case "wrote": return model;
    case "fetched": return { ...model, code: msg.status, data: msg.body };
    case "fired": return model;
    case "failed": return { ...model, errs: model.errs + 1 };
  }
}
`,
  },
  {
    name: "more headers than the engine accepts stops at compile time",
    gate: "NS1030",
    src: `
import { Cmd, asciiBytes } from "@native-sdk/core";
${namedOpMsg}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.fetch({ url: asciiBytes("https://a.test"), headers: { a: "1", b: "2", c: "3", d: "4", e: "5", f: "6", g: "7", h: "8", i: "9" } }, { ok: "fetched", err: "failed" })];
    case "loaded": return { ...model, data: msg.body };
    case "wrote": return model;
    case "fetched": return { ...model, code: msg.status, data: msg.body };
    case "fired": return model;
    case "failed": return { ...model, errs: model.errs + 1 };
  }
}
`,
  },
  {
    name: "a literal delay outside the 1ms..one-year bound stops at compile time",
    gate: "NS1030",
    src: `
import { Cmd } from "@native-sdk/core";
${namedOpMsg}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.delay("d", 0, "fired")];
    case "loaded": return { ...model, data: msg.body };
    case "wrote": return model;
    case "fetched": return { ...model, code: msg.status, data: msg.body };
    case "fired": return model;
    case "failed": return { ...model, errs: model.errs + 1 };
  }
}
`,
  },
];

// The emit-contract hardening round: constructs that once transpiled into
// invalid Zig now either emit correctly (optional chains, string equality,
// the asciiBytes intrinsic) or stop with a taught rule (concatenation,
// parameter defaults, host-arg smuggling, chain null tests, Map/Set).
const contractCases: Case[] = [
  {
    name: "optional chains: ?? folds, value comparisons, boolean conditions",
    src: `
export type Tone = "info" | "warn";
export interface Badge { readonly count: number; readonly label: Uint8Array; readonly urgent: boolean; readonly tone: Tone | null; }
export interface Panel { readonly badge: Badge | null; readonly width: number; }
export interface Model { readonly panel: Panel | null; readonly fallback: number; }
export function badgeCount(model: Model): number {
  return model.panel?.badge?.count ?? 0;
}
export function labelLen(model: Model): number {
  return model.panel?.badge?.label.length ?? -1;
}
export function isUrgent(model: Model): boolean {
  return model.panel?.badge?.urgent ?? false;
}
export function urgentGate(model: Model, on: boolean): boolean {
  if (model.panel?.badge?.urgent) return true;
  return on && !model.panel?.badge?.urgent;
}
export function isWarn(model: Model): boolean {
  return model.panel?.badge?.tone === "warn";
}
export function countIsFive(model: Model): boolean {
  return model.panel?.badge?.count === 5;
}
export function widthOrFallback(model: Model): number {
  const w = model.panel?.width ?? model.fallback;
  return w * 2;
}
export function toneOrNull(model: Model): Tone | null {
  return model.panel?.badge?.tone ?? null;
}
`,
  },
  {
    name: "optional chain on a local holding an optional record",
    src: `
export interface Sel { readonly at: number; readonly len: number; }
export interface Model { readonly sel: Sel | null; }
export function span(model: Model): number {
  const sel = model.sel;
  return (sel?.at ?? 0) + (sel?.len ?? 0);
}
`,
  },
  {
    name: "string equality: the command-mapper idiom emits and compiles",
    src: `
export interface Model { readonly count: number; }
export type Msg = { readonly kind: "add" } | { readonly kind: "remove" };
export function commandMsg(name: string): Msg | null {
  if (name === "app.add") return { kind: "add" };
  if (name === "app.remove") return { kind: "remove" };
  return null;
}
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "add": return { count: model.count + 1 };
    case "remove": return { count: model.count - 1 };
  }
}
`,
  },
  {
    name: "string equality against optional strings keeps the null table",
    src: `
export function pick(name: string | null): number {
  if (name === "left") return 1;
  if (name !== "right") return 2;
  return 3;
}
export function same(a: string | null, b: string | null): boolean {
  return a === b;
}
`,
  },
  {
    name: "literal-union value equals a plain string by tag name",
    src: `
export type Filter = "all" | "active" | "done";
export function matchesName(f: Filter, name: string): boolean {
  return f === name;
}
`,
  },
  {
    name: "SDK asciiBytes intrinsic: literal to rodata, template to arena bytes",
    src: `
import { asciiBytes } from "@native-sdk/core";
export interface Model { readonly count: number; }
export function banner(): Uint8Array {
  return asciiBytes("expenses");
}
export function summary(model: Model): Uint8Array {
  return asciiBytes(\`\${model.count} items\`);
}
`,
  },
  {
    name: "string + concatenation is taught, not emitted",
    gate: "NS1018",
    src: `
export function shout(s: string): string {
  return s + "!";
}
`,
  },
  {
    name: "parameter defaults are taught, not silently dropped",
    gate: "NS1019",
    src: `
function step(n: number, by: number = 1): number {
  return n + by;
}
export function next(n: number): number {
  return step(n);
}
`,
  },
  {
    name: "Cmd.host argument smuggled past the types is taught",
    gate: "NS1020",
    src: `
import { Cmd } from "@native-sdk/core";
export interface Model { readonly count: number; }
export type Msg = { readonly kind: "go"; readonly path: string } | { readonly kind: "noop" };
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.host("open", msg.path as unknown as number)];
    case "noop": return model;
  }
}
`,
  },
  {
    name: "null test on an optional chain is taught (undefined vs null would diverge)",
    gate: "NS1021",
    src: `
export interface Inner { readonly x: number | null; }
export interface Model { readonly inner: Inner | null; }
export function f(model: Model): boolean {
  return model.inner?.x === null;
}
`,
  },
  {
    name: "bare new Map() is the taught container rule, not an internal stop",
    gate: "NS1011",
    src: `
export function f(): number {
  const m = new Map();
  return m.size;
}
`,
  },
  {
    name: "a relative import of a missing module is taught, before resolution matters",
    gate: "NS1037",
    src: `
// @ts-expect-error the sibling module deliberately does not exist: the rule
// must fire before resolution matters.
import { helper } from "./helper_mod.ts";
export function f(n: number): number { return helper(n); }
`,
  },
];

// The iteration round: for...of over arrays and bytes, and the array-method
// lowerings (find/findIndex/some/every/reduce/slice/concat/indexOf/includes/
// join). Emitting cases must compile; the JS corners with no mapping are
// gated by their teaching rules.
const bindingSurfaceCases: Case[] = [
  {
    name: "exported model helpers forward as Model declarations and viewUnbound emits the opt-out",
    src: `
export interface Task { readonly id: number; readonly done: boolean; }
export interface Model { readonly tasks: readonly Task[]; readonly nextId: number; }
export type Msg = { readonly kind: "add" } | { readonly kind: "chrome_changed"; readonly inset: number };
export const viewUnbound = ["nextId", "chrome_changed", "openTasks"] as const;
export function initialModel(): Model { return { tasks: [], nextId: 1 }; }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "add": return { ...model, tasks: [...model.tasks, { id: model.nextId, done: false }], nextId: model.nextId + 1 };
    case "chrome_changed": return model;
  }
}
export function remainingCount(model: Model): number {
  return model.tasks.filter((t) => !t.done).length;
}
export function openTasks(model: Model): readonly Task[] {
  return model.tasks.filter((t) => !t.done);
}
export function total(model: Model): number { return model.nextId - 1; }
`,
  },
  {
    name: "a helper colliding with a field's emitted name is gated",
    gate: "NS1031",
    src: `
interface Totals { readonly doneCount: number; }
export interface Model { readonly totals: Totals; readonly doneCount: number; }
export type Msg = { readonly kind: "a" } | { readonly kind: "b" };
export function initialModel(): Model { return { totals: { doneCount: 0 }, doneCount: 0 }; }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) { case "a": return model; case "b": return model; }
}
export function doneCount(model: Model): number { return model.totals.doneCount; }
`,
  },
  {
    name: "helpers and fields with different spellings never collide (names emit verbatim)",
    src: `
export interface Model { readonly done_count: number; }
export type Msg = { readonly kind: "a" } | { readonly kind: "b" };
export function initialModel(): Model { return { done_count: 0 }; }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) { case "a": return model; case "b": return model; }
}
export function doneCount(model: Model): number { return model.done_count; }
`,
  },
  {
    name: "a viewUnbound entry outside the model surface is gated",
    gate: "NS1032",
    src: `
export interface Model { readonly count: number; }
export type Msg = { readonly kind: "a" } | { readonly kind: "b" };
export const viewUnbound = ["typoedName"] as const;
export function initialModel(): Model { return { count: 0 }; }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) { case "a": return model; case "b": return model; }
}
`,
  },
];

const stackedUnionCases: Case[] = [
  {
    name: "stacked union-switch labels sharing a body coalesce into one arm",
    src: `
export type Ev = { readonly kind: "a"; readonly n: number } | { readonly kind: "b" } | { readonly kind: "c" };
export function pick(e: Ev): number {
  switch (e.kind) {
    case "a": return e.n;
    case "b":
    case "c": return -1;
  }
}
`,
  },
  {
    name: "stacked labels whose shared body reads a payload are gated",
    gate: "NS9001",
    src: `
export type Ev = { readonly kind: "a"; readonly n: number } | { readonly kind: "b"; readonly n: number };
export function pick(e: Ev): number {
  switch (e.kind) {
    case "b":
    case "a": return e.n;
  }
}
`,
  },
];

const iterationCases: Case[] = [
  {
    name: "for...of over a record array with break and continue",
    src: `
export interface Task { readonly id: number; readonly done: boolean; }
export function firstOpenId(tasks: readonly Task[]): number {
  let hit = -1;
  for (const t of tasks) {
    if (t.done) continue;
    hit = t.id;
    break;
  }
  return hit;
}
`,
  },
  {
    name: "for...of over bytes: integer widening, demand, and float use",
    src: `
export function total(bytes: Uint8Array): number {
  let n = 0;
  for (const b of bytes) {
    n += b;
  }
  return n;
}
export function probe(bytes: Uint8Array, table: Uint8Array): number {
  let acc = 0;
  for (const b of bytes) {
    acc += table[b];
  }
  return acc;
}
export function scaled(bytes: Uint8Array): number {
  let n = 0.0;
  for (const b of bytes) {
    n += b * 0.5;
  }
  return n;
}
`,
  },
  {
    name: "for...of over a number array keeps float element math",
    src: `
export function product(xs: readonly number[]): number {
  let p = 1;
  for (const x of xs) {
    p = p * x;
  }
  return p;
}
`,
  },
  {
    name: "for...of over a filtered array and an unused binding",
    src: `
export interface Task { readonly id: number; readonly done: boolean; }
export function doneTally(tasks: readonly Task[]): number {
  let n = 0;
  for (const t of tasks.filter((x) => x.done)) {
    n += 1;
  }
  return n;
}
`,
  },
  {
    name: "for...of over .entries() emits the indexed loop (the [i, x] pair form)",
    src: `
export function sum(xs: readonly number[]): number {
  let total = 0;
  for (const [i, x] of xs.entries()) {
    total += x + i;
  }
  return total;
}
`,
  },
  {
    name: "for...of over .entries() beyond the [i, x] pair form is taught",
    gate: "NS9001",
    src: `
export function sum(xs: readonly number[]): number {
  let total = 0;
  for (const [i] of xs.entries()) {
    total += i;
  }
  return total;
}
`,
  },
  {
    name: "for...of with a let binding is taught, not emitted",
    gate: "NS9001",
    src: `
export function last(xs: readonly number[]): number {
  let hit = 0;
  for (let x of xs) {
    hit = x;
  }
  return hit;
}
`,
  },
  {
    name: "find consumed through the miss-test fusion and payload reads",
    src: `
export interface Task { readonly id: number; readonly done: boolean; }
export function firstDoneId(tasks: readonly Task[]): number {
  const hit = tasks.find((t) => t.done);
  if (hit === undefined) return -1;
  return hit.id;
}
`,
  },
  {
    name: "find consumed through ?? and an identifier guard block",
    src: `
export function firstOver(xs: readonly number[], lim: number): number {
  return xs.find((x) => x > lim) ?? -1;
}
export interface Task { readonly id: number; readonly done: boolean; }
export function doubledId(tasks: readonly Task[]): number {
  const hit = tasks.find((t) => !t.done);
  if (hit !== undefined) {
    const twice = hit.id * 2;
    return twice;
  }
  return 0;
}
`,
  },
  {
    name: "findIndex, some, every, indexOf, and includes over scalar arrays",
    src: `
export type Category = "food" | "travel" | "gear";
export interface Task { readonly id: number; readonly done: boolean; }
export function doneAt(tasks: readonly Task[]): number {
  return tasks.findIndex((t) => t.done);
}
export function anyDone(tasks: readonly Task[]): boolean {
  return tasks.some((t) => t.done);
}
export function allDone(tasks: readonly Task[]): boolean {
  return tasks.every((t) => t.done);
}
export function whereIs(xs: readonly number[], v: number): number {
  return xs.indexOf(v);
}
export function hasCategory(cats: readonly Category[], c: Category): boolean {
  return cats.includes(c);
}
`,
  },
  {
    name: "findIndex demand: the result indexes memory",
    src: `
export interface Task { readonly id: number; readonly done: boolean; }
export function markByte(tasks: readonly Task[], bytes: Uint8Array): number {
  const at = tasks.findIndex((t) => t.done);
  if (at === -1) return 0;
  return bytes[at];
}
`,
  },
  {
    name: "reduce with an initial value over numbers and records",
    src: `
export interface Expense { readonly cents: number; }
export function total(xs: readonly number[]): number {
  return xs.reduce((sum, x) => sum + x, 0);
}
export function centsTotal(expenses: readonly Expense[]): number {
  return expenses.reduce((sum, e) => sum + e.cents, 0);
}
export function countBig(xs: readonly number[], lim: number): number {
  return xs.reduce((n, x) => (x > lim ? n + 1 : n), 0);
}
`,
  },
  {
    name: "reduce without an initial value is taught (empty-array throw)",
    gate: "NS1007",
    src: `
export function total(xs: readonly number[]): number {
  return xs.reduce((sum, x) => sum + x);
}
`,
  },
  {
    name: "reduce result flowing into an index slot is taught (float-classed)",
    gate: "NS1016",
    src: `
export function pick(xs: readonly number[], bytes: Uint8Array): number {
  const at = xs.reduce((sum, x) => sum + x, 0);
  return bytes[at];
}
`,
  },
  {
    name: "array slice and concat over records and numbers",
    src: `
export interface Task { readonly id: number; readonly done: boolean; }
export function firstTwo(tasks: readonly Task[]): readonly Task[] {
  return tasks.slice(0, 2);
}
export function lastTwo(xs: readonly number[]): readonly number[] {
  return xs.slice(-2);
}
export function trimmed(xs: readonly number[], from: number, to: number): readonly number[] {
  return xs.slice(from, to);
}
export function stitched(a: readonly Task[], b: readonly Task[]): readonly Task[] {
  return a.concat(b);
}
export function tripled(a: readonly number[], b: readonly number[], c: readonly number[]): readonly number[] {
  return a.concat(b, c);
}
`,
  },
  {
    name: "indexOf on a record array is taught (JS reference identity)",
    gate: "NS9001",
    src: `
export interface Task { readonly id: number; readonly done: boolean; }
export function has(tasks: readonly Task[], t: Task): number {
  return tasks.indexOf(t);
}
`,
  },
  {
    name: "join over bytes emits; join over a number array is taught",
    src: `
export function csv(bytes: Uint8Array): string {
  return bytes.join("-");
}
export function bare(bytes: Uint8Array): string {
  return bytes.join("");
}
export function commas(bytes: Uint8Array): string {
  return bytes.join();
}
`,
  },
  {
    name: "join on a number array is taught (float elements)",
    gate: "NS9001",
    src: `
export function csv(xs: readonly number[]): string {
  return xs.join(",");
}
`,
  },
  {
    name: "the wrong empty test is taught in both directions (R7c)",
    gate: "NS9001",
    src: `
export function f(cursor: number | null): boolean {
  return cursor === undefined;
}
`,
  },
  {
    name: "=== null on a find result is taught (the miss is JS undefined)",
    gate: "NS9001",
    src: `
export function f(xs: readonly number[]): number {
  const hit = xs.find((x) => x > 0);
  if (hit === null) return -1;
  return 0;
}
`,
  },
];

// The building-and-sorting round: block-body callbacks in the array methods,
// the push-builder, prepend/multi-spread literals, toSorted, and the two
// comptime/clamping fixes. Emitting cases must compile; the shapes with no
// mapping are gated by their teaching rules.
const builderSortCases: Case[] = [
  {
    name: "block-body callbacks across map, filter, find, findIndex, some, every, reduce",
    src: `
export interface Task { readonly id: number; readonly streak: number; readonly done: boolean; }
export interface Model { readonly tasks: readonly Task[]; }
export function capped(model: Model, lim: number): readonly Task[] {
  return model.tasks.map((t) => {
    if (t.streak > lim) return { ...t, streak: lim };
    return t;
  });
}
export function margins(model: Model, lim: number): readonly Task[] {
  return model.tasks.filter((t) => {
    if (t.done) return false;
    const margin = lim - t.streak;
    return margin > 0;
  });
}
export function pickId(model: Model, want: number): number {
  const hit = model.tasks.find((t) => {
    if (t.id === want) return true;
    return t.streak > want;
  });
  if (hit === undefined) return -1;
  return hit.id;
}
export function whereDone(model: Model): number {
  return model.tasks.findIndex((t) => {
    if (t.streak === 0) return false;
    return t.done;
  });
}
export function anyOpen(model: Model): boolean {
  return model.tasks.some((t) => {
    const open = !t.done;
    return open;
  });
}
export function allSeeded(model: Model): boolean {
  return model.tasks.every((t) => {
    if (t.done) return true;
    return t.streak > 0;
  });
}
export function streakTotal(model: Model): number {
  return model.tasks.reduce((sum, t) => {
    if (t.done) return sum;
    return sum + t.streak;
  }, 0);
}
`,
  },
  {
    name: "block-body callback with orelse fusion and a nested expression callback",
    src: `
export interface Task { readonly id: number; readonly streak: number; readonly done: boolean; }
export function pairSum(tasks: readonly Task[], others: readonly Task[]): number {
  return tasks.reduce((sum, t) => {
    const twin = others.find((o) => o.id === t.id);
    if (twin === undefined) return sum;
    return sum + twin.streak;
  }, 0);
}
`,
  },
  {
    name: "push-builder: for...of, classic for, while, and pushes inside if/else",
    src: `
export interface Task { readonly id: number; readonly done: boolean; }
export function openIds(tasks: readonly Task[]): readonly number[] {
  const out: number[] = [];
  for (const t of tasks) {
    if (t.done) {
      out.push(-t.id);
    } else {
      out.push(t.id);
    }
  }
  return out;
}
export function evens(bytes: Uint8Array): readonly number[] {
  const out: number[] = [];
  for (let i = 0; i < bytes.length; i++) {
    if (bytes[i] % 2 === 0) out.push(bytes[i]);
  }
  return out;
}
export function countdown(n: number): readonly number[] {
  const out: number[] = [];
  let left = n;
  while (left > 0) {
    out.push(left);
    left -= 1;
  }
  return out;
}
`,
  },
  {
    name: "push-builder of records escaping into the model (commit walkers see the prefix)",
    src: `
export interface Task { readonly id: number; readonly done: boolean; }
export interface Model { readonly tasks: readonly Task[]; }
export type Msg = { readonly kind: "mark"; readonly id: number } | { readonly kind: "noop" };
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "mark": {
      const next: Task[] = [];
      for (const t of model.tasks) {
        if (t.id === msg.id) next.push({ ...t, done: true });
        else next.push(t);
      }
      return { tasks: next };
    }
    case "noop": return model;
  }
}
`,
  },
  {
    name: "builder length and element reads see the filled prefix",
    src: `
export function firstBig(xs: readonly number[], lim: number): number {
  const out: number[] = [];
  for (const x of xs) {
    if (x > lim) out.push(x);
  }
  if (out.length === 0) return -1;
  return out[0];
}
`,
  },
  {
    name: "prepend and multi-spread literals over numbers and records",
    src: `
export interface Task { readonly id: number; readonly done: boolean; }
export function pre(xs: readonly number[], x: number): readonly number[] {
  return [x, ...xs];
}
export function preTask(tasks: readonly Task[], t: Task): readonly Task[] {
  return [t, ...tasks];
}
export function stitch(a: readonly number[], b: readonly number[], x: number): readonly number[] {
  return [...a, x, ...b];
}
export function wrap(xs: readonly number[], lo: number, hi: number): readonly number[] {
  return [lo, ...xs, hi];
}
`,
  },
  {
    name: "toSorted over records, numbers, and a block-body comparator",
    src: `
export interface Task { readonly id: number; readonly streak: number; readonly done: boolean; }
export interface Model { readonly tasks: readonly Task[]; }
export function byStreak(model: Model): readonly Task[] {
  return model.tasks.toSorted((a, b) => a.streak - b.streak);
}
export function descending(xs: readonly number[]): readonly number[] {
  return xs.toSorted((a, b) => b - a);
}
export function doneLast(model: Model): readonly Task[] {
  return model.tasks.toSorted((a, b) => {
    if (a.done === b.done) return a.streak - b.streak;
    if (a.done) return 1;
    return -1;
  });
}
`,
  },
  {
    name: "bytes slice with out-of-range and negative bounds compiles to the clamped copy",
    src: `
export function tail(bytes: Uint8Array, from: number): Uint8Array {
  return bytes.slice(from);
}
export function window(bytes: Uint8Array, from: number, to: number): Uint8Array {
  return bytes.slice(from, to);
}
export function lastTwo(bytes: Uint8Array): Uint8Array {
  return bytes.slice(-2);
}
`,
  },
  {
    name: "comptime division folds to the JS f64 value (0/0 once emitted an illegal divide)",
    src: `
export const RATE = 1 / 0;
export function nanv(): number { return 0 / 0; }
export function half(): number { return 5 / 2; }
export function negZero(): number { return 0 / -1; }
`,
  },
  {
    name: "number const from a ternary of literal branches carries its runtime type",
    src: `
export function step(flag: boolean): number {
  const delta = flag ? -1 : 1;
  return delta;
}
export interface Habit { readonly id: number; readonly streak: number; readonly doneToday: boolean; }
export function toggled(habits: readonly Habit[], id: number): readonly Habit[] {
  return habits.map((h) => {
    if (h.id !== id) return h;
    const bump = h.doneToday ? -1 : 1;
    return { ...h, doneToday: !h.doneToday, streak: h.streak + bump };
  });
}
`,
  },
  {
    name: "toSorted without a comparator is taught (JS ToString ordering)",
    gate: "NS9001",
    src: `
export function f(xs: readonly number[]): readonly number[] {
  return xs.toSorted();
}
`,
  },
  {
    name: "in-place .sort() is taught toward .toSorted",
    gate: "NS1022",
    src: `
export function f(xs: number[]): number[] {
  xs.sort((a, b) => a - b);
  return xs;
}
`,
  },
  {
    name: "push on a parameter array is the mutation rule",
    gate: "NS1001",
    src: `
export function f(xs: number[], x: number): number[] {
  xs.push(x);
  return xs;
}
`,
  },
  {
    name: "push on a MIXED reassigned binding is taught (an alias assignment ends ownership)",
    gate: "NS1001",
    src: `
export function f(xs: number[], n: number): readonly number[] {
  let out: number[] = [];
  out.push(n);
  out = xs;
  return out;
}
`,
  },
  {
    name: "R17m: a reassigned binding whose every assignment is a fresh construction mutates freely",
    src: `
export function f(n: number): readonly number[] {
  let out: number[] = [];
  out.push(n);
  out = [n, n];
  out.push(n + 1);
  return out;
}
`,
  },
  {
    name: "push in value position is taught (the JS value is the new length)",
    gate: "NS9001",
    src: `
export function f(n: number): number {
  const out: number[] = [];
  const len = out.push(n);
  return len;
}
`,
  },
  {
    name: "an un-annotated spread local is taught its array-type annotation (NS1052)",
    gate: "NS1052",
    src: `
export interface Turn { readonly id: number; readonly text: Uint8Array; }
export interface Model { readonly turns: readonly Turn[]; readonly nextId: number; }
export type Msg = { readonly kind: "add"; readonly text: Uint8Array } | { readonly kind: "clear" };
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "add": {
      const turns = [...model.turns, { id: model.nextId, text: msg.text }];
      return { ...model, turns: turns, nextId: model.nextId + 1 };
    }
    case "clear": return { ...model, turns: [] };
  }
}
`,
  },
  {
    name: "push with a spread argument is taught (one element per call)",
    gate: "NS9001",
    src: `
export function f(xs: readonly number[]): readonly number[] {
  const out: number[] = [];
  out.push(...xs);
  return out;
}
`,
  },
  {
    name: "pushing to the array a for...of iterates is taught, not silently snapshotted",
    gate: "NS9001",
    src: `
export function f(n: number): readonly number[] {
  const out: number[] = [];
  out.push(n);
  for (const x of out) {
    if (x > 0) out.push(x - 1);
  }
  return out;
}
`,
  },
  {
    name: "a callback path falling off the end is taught (implicit undefined)",
    gate: "NS9001",
    src: `
export function f(xs: readonly number[]): readonly number[] {
  return xs.filter((x) => {
    if (x > 0) return true;
  });
}
`,
  },
];

// The local-mutation round: mutating array methods are legal on arrays the
// function creates and still owns (the push-builder generalized to the full
// method set); the teaching rules fire only at the true semantic boundaries
// (shared inputs NS1001/NS1022, mutation after an escape NS1051).
const localMutationCases: Case[] = [
  {
    name: "R17m: recursion over borrowed readonly slices keeps the caller's ownership",
    src: `
function sumFrom(xs: readonly number[], i: number): number {
  if (i >= xs.length) return 0;
  return xs[i] + sumFrom(xs, i + 1);
}
export function f(n: number): number {
  const out: number[] = [n, n + 1];
  const a = sumFrom(out, 0);
  out.push(n + 2);
  return a + sumFrom(out, 0);
}
`,
  },
  {
    name: "NS1051: a readonly param handed onward into a MUTABLE position ends the borrow",
    gate: "NS1051",
    src: `
function scrub(xs: number[]): number { xs.pop(); return xs.length; }
function relay(xs: readonly number[]): number { return scrub(xs as number[]); }
export function f(): number { const out: number[] = [1, 2]; const t = relay(out); out.push(3); return t; }
`,
  },
  {
    name: "NS1051: a readonly param the callee aliases through a cast is no borrow",
    gate: "NS1051",
    src: `
function sneak(xs: readonly number[]): number {
  const grabbed = xs as number[];
  return grabbed.length;
}
export function f(): number { const out: number[] = [1]; const t = sneak(out); out.push(2); return t; }
`,
  },
  {
    name: "owned mutation: a parser stack (push/pop) over a byte scan",
    src: `
export function maxDepth(bytes: Uint8Array): number {
  const stack: number[] = [];
  let max = 0;
  for (const b of bytes) {
    if (b === 40) stack.push(b);
    if (b === 41) stack.pop();
    if (stack.length > max) max = stack.length;
  }
  return max;
}
`,
  },
  {
    name: "owned mutation: pop and shift values ride the find-miss optional machinery",
    src: `
export function lastOr(xs: readonly number[], fallback: number): number {
  const work = xs.slice();
  const v = work.pop();
  if (v === undefined) return fallback;
  return v;
}
export function firstOr(xs: readonly number[], fallback: number): number {
  const work = xs.slice();
  return work.shift() ?? fallback;
}
`,
  },
  {
    name: "owned mutation: the canonical in-place sort (slice copy, then sort)",
    src: `
export interface Task { readonly id: number; readonly streak: number; }
export function byStreak(tasks: readonly Task[]): readonly Task[] {
  const copy = tasks.slice();
  copy.sort((a, b) => a.streak - b.streak);
  return copy;
}
export function ordered(xs: readonly number[]): readonly number[] {
  const copy = xs.slice();
  copy.sort((a, b) => a - b);
  return copy;
}
`,
  },
  {
    name: "owned mutation: splice in value and statement position, unshift, reverse, fill",
    src: `
export function surgery(xs: readonly number[]): readonly number[] {
  const work = xs.slice();
  const removed = work.splice(1, 2, 9, 8);
  work.splice(0, 1);
  work.unshift(-1, -2);
  work.reverse();
  work.fill(0, 1, 2);
  return removed.concat(work);
}
`,
  },
  {
    name: "owned mutation: non-empty starts (literal seed, map/filter/concat/toSorted copies)",
    src: `
export function seeded(n: number): readonly number[] {
  const st = [1, 2, 3];
  for (let i = 0; i < n; i++) st.push(i);
  return st;
}
export function doubledThenTrimmed(xs: readonly number[]): readonly number[] {
  const work = xs.map((x) => x * 2);
  work.pop();
  return work;
}
export function keptThenGrown(xs: readonly number[], lim: number): readonly number[] {
  const work = xs.filter((x) => x > lim);
  work.push(lim);
  return work;
}
export function joinedThenRotated(a: readonly number[], b: readonly number[]): readonly number[] {
  const work = a.concat(b);
  const head = work.shift();
  if (head !== undefined) work.push(head);
  return work;
}
export function sortedThenCapped(xs: readonly number[], cap: number): readonly number[] {
  const work = xs.toSorted((a, b) => a - b);
  work.fill(cap, -1);
  return work;
}
`,
  },
  {
    name: "owned mutation: indexed writes and interleaved reads on owned arrays",
    src: `
export function swap(xs: readonly number[]): readonly number[] {
  const work = xs.slice();
  if (work.length >= 2) {
    const tmp = work[0];
    work[0] = work[work.length - 1];
    work[work.length - 1] = tmp;
  }
  return work;
}
export function builderWrites(n: number): readonly number[] {
  const out: number[] = [];
  for (let i = 0; i < n; i++) out.push(i);
  if (out.length > 0) out[0] = out[out.length - 1] + 1;
  return out;
}
`,
  },
  {
    name: "owned mutation: records pop into an optional record, splice moves them",
    src: `
export interface Task { readonly id: number; readonly done: boolean; }
export function dropLastDone(tasks: readonly Task[]): readonly Task[] {
  const work = tasks.slice();
  const last = work.pop();
  if (last === undefined) return work;
  if (!last.done) work.push(last);
  return work;
}
export function promote(tasks: readonly Task[], at: number): readonly Task[] {
  const work = tasks.slice();
  const moved = work.splice(at, 1);
  return moved.concat(work);
}
`,
  },
  {
    name: "owned mutation: an early exit return is terminal, not an escape",
    src: `
export function padded(xs: readonly number[], min: number): readonly number[] {
  const work = xs.slice();
  if (work.length >= min) return work;
  while (work.length < min) work.push(0);
  return work;
}
`,
  },
  {
    name: "escape then mutate: push after the array was passed into a mutable position",
    gate: "NS1051",
    src: `
function total(xs: number[]): number { return xs.length; }
export function f(): number {
  const out: number[] = [1];
  const t = total(out);
  out.push(2);
  return t + out.length;
}
`,
  },
  {
    name: "R17m: a readonly reader call is a borrow — mutation continues after it",
    src: `
function total(xs: readonly number[]): number { return xs.length; }
export function f(): number {
  const out: number[] = [1];
  const t = total(out);
  out.push(2);
  return t + out.length;
}
`,
  },
  {
    name: "escape then mutate: pop after the array was stored into the returned record",
    gate: "NS1051",
    src: `
export interface Pair { readonly xs: readonly number[]; readonly n: number; }
export function f(b: boolean): Pair {
  const out: number[] = [1, 2];
  const pair: Pair = { xs: out, n: 0 };
  if (b) out.pop();
  return pair;
}
`,
  },
  {
    name: "escape then mutate: aliasing ends the original's ownership",
    gate: "NS1051",
    src: `
export function f(): number {
  const a: number[] = [1];
  const b = a;
  a.push(2);
  return b.length;
}
`,
  },
  {
    name: "escape inside a loop gates the whole loop body (second iteration mutates after the pass)",
    gate: "NS1051",
    src: `
function probe(xs: number[]): number { return xs.length; }
export function f(n: number): number {
  const out: number[] = [];
  let t = 0;
  for (let i = 0; i < n; i++) {
    out.push(i);
    t += probe(out);
  }
  return t;
}
`,
  },
  {
    name: "never owned: mutating the alias of an owned array",
    gate: "NS1001",
    src: `
export function f(): number {
  const a: number[] = [1];
  const b = a;
  b.push(2);
  return a.length;
}
`,
  },
  {
    name: "never owned: pop on a parameter",
    gate: "NS1001",
    src: `
export function f(xs: number[]): number {
  return xs.pop() ?? -1;
}
`,
  },
  {
    name: "never owned: splice on a model field through an as-cast",
    gate: "NS1001",
    src: `
export interface Model { readonly xs: readonly number[]; }
export function f(model: Model): readonly number[] {
  (model.xs as number[]).splice(0, 1);
  return model.xs;
}
`,
  },
  {
    name: "never owned: push on a module-level table",
    gate: "NS1001",
    src: `
const TABLE: number[] = [1, 2];
export function f(): number {
  TABLE.push(3);
  return TABLE.length;
}
`,
  },
  {
    name: "never owned: an array produced by a helper call (copy with .slice to own it)",
    gate: "NS1001",
    src: `
function make(): number[] { return [1, 2]; }
export function f(): readonly number[] {
  const xs = make();
  xs.push(3);
  return xs;
}
`,
  },
  {
    name: "never owned: indexed write through a parameter",
    gate: "NS1001",
    src: `
export function f(xs: number[]): number {
  xs[0] = 1;
  return xs[0];
}
`,
  },
  {
    name: "in-place sort keeps NS1022 on shared arrays, naming the local-copy idiom",
    gate: "NS1022",
    src: `
export function f(xs: number[]): number[] {
  xs.sort((a, b) => a - b);
  return xs;
}
`,
  },
  {
    name: "in-place sort without a comparator is taught (JS ToString ordering)",
    gate: "NS9001",
    src: `
export function f(xs: readonly number[]): readonly number[] {
  const copy = xs.slice();
  copy.sort();
  return copy;
}
`,
  },
  {
    name: "copyWithin stays out of v1 even on an owned array",
    gate: "NS1001",
    src: `
export function f(xs: readonly number[]): readonly number[] {
  const copy = xs.slice();
  copy.copyWithin(0, 1);
  return copy;
}
`,
  },
  {
    name: "sort/reverse in value position is taught (JS returns the same array)",
    gate: "NS9001",
    src: `
export function f(xs: readonly number[]): readonly number[] {
  const copy = xs.slice();
  return copy.sort((a, b) => a - b);
}
`,
  },
  {
    name: "unshift in value position is taught (the JS value is the new length)",
    gate: "NS9001",
    src: `
export function f(xs: readonly number[]): number {
  const copy = xs.slice();
  const n = copy.unshift(0);
  return n;
}
`,
  },
  {
    name: "splice with a spread argument is taught",
    gate: "NS9001",
    src: `
export function f(xs: readonly number[], ys: readonly number[]): readonly number[] {
  const copy = xs.slice();
  copy.splice(0, 0, ...ys);
  return copy;
}
`,
  },
  {
    name: "R17m: the appending write IS a push (the one growth shape)",
    src: `
export function f(): readonly number[] {
  const out = [1, 2];
  out[out.length] = 3;
  return out;
}
`,
  },
  {
    name: "a compound appending write is taught (it reads the missing slot first)",
    gate: "NS9001",
    src: `
export function f(): readonly number[] {
  const out = [1, 2];
  out[out.length] += 3;
  return out;
}
`,
  },
  {
    name: "length-changing mutation of the array a for...of iterates is taught",
    gate: "NS9001",
    src: `
export function f(): number {
  const out: number[] = [1, 2, 3];
  let t = 0;
  for (const x of out) {
    t += x;
    out.pop();
  }
  return t;
}
`,
  },
  {
    name: "length-changing mutation from inside an iterating callback is taught",
    gate: "NS9001",
    src: `
export function f(xs: readonly number[]): number {
  const out: number[] = [1, 2, 3];
  return out.reduce((acc, x) => {
    out.pop();
    return acc + x;
  }, 0);
}
`,
  },
  {
    name: "mutating a MIXED reassigned binding is taught (a shared array could ride in)",
    gate: "NS1001",
    src: `
export function f(xs: number[]): readonly number[] {
  let work = xs.slice();
  work = xs;
  work.pop();
  return work;
}
`,
  },
  {
    name: "R17m: a reassigned binding of fresh copies stays owned (pop through the reassignment)",
    src: `
export function f(xs: readonly number[]): readonly number[] {
  let work = xs.slice();
  work = xs.slice();
  work.pop();
  return work;
}
`,
  },
];


const arrayStaticCases: Case[] = [
  {
    name: "NS1059: Array.from is taught toward the spread copy",
    gate: "NS1059",
    src: `export function f(xs: readonly number[]): number { const c = Array.from(xs); return c.length; }`,
  },
  {
    name: "NS1059: Array.of is taught toward the literal",
    gate: "NS1059",
    src: `export function f(): number { const c = Array.of(1, 2, 3); return c.length; }`,
  },
  {
    name: "NS1041: Array.isArray stays the runtime type test it is",
    gate: "NS1041",
    src: `export function f(x: unknown): boolean { return Array.isArray(x); }`,
  },
];

const mathAndTableCases: Case[] = [
  {
    name: "Math batch: float sites, integer identities, and mixed min/max arities",
    src: `
export function flo(x: number): number { return Math.floor(x); }
export function cei(x: number): number { return Math.ceil(x); }
export function tru(x: number): number { return Math.trunc(x); }
export function ab(x: number): number { return Math.abs(x); }
export function sg(x: number): number { return Math.sign(x); }
export function sq(x: number): number { return Math.sqrt(x); }
export function floInt(bytes: Uint8Array): number { return Math.floor(bytes.length); }
export function abInt(bytes: Uint8Array): number { return Math.abs(bytes.length - 10); }
export function sgInt(bytes: Uint8Array): number { return Math.sign(bytes.length - 2); }
export function sqInt(bytes: Uint8Array): number { return Math.sqrt(bytes.length); }
export function noArgs(): number { return Math.min() + Math.max(); }
export function oneArg(x: number): number { return Math.max(x); }
export function three(a: number, b: number, c: number): number { return Math.min(a, b, c); }
export function threeMixed(bytes: Uint8Array, x: number): number { return Math.max(bytes.length, x, 0); }
`,
  },
  {
    name: "Math comptime folds: module consts and expression positions",
    src: `
export const HALF = Math.floor(5 / 2);
export const DOWN = Math.floor(-5 / 2);
export const ROOT = Math.sqrt(2);
export const NANV = Math.sign(0 / 0);
export function pick(bytes: Uint8Array): number { return bytes[HALF]; }
export function low(): number { return Math.min(3, 2.5); }
export function ceilNegHalf(): number { return Math.ceil(-0.5); }
`,
  },
  {
    name: "a float Math.floor result used as an index is the taught NS1016, not invalid Zig",
    gate: "NS1016",
    src: `
export function pick(bytes: Uint8Array, x: number): number {
  return bytes[Math.floor(x / 2)];
}
`,
  },
  {
    name: "Math methods outside the v1 set are taught by name",
    gate: "NS9001",
    src: `
export function powed(x: number): number { return Math.pow(x, 2); }
`,
  },
  {
    name: "Number classifiers compile on float and integer-classed arguments",
    src: `
export function isInt(x: number): boolean { return Number.isInteger(x); }
export function isFin(x: number): boolean { return Number.isFinite(x); }
export function isNan(x: number): boolean { return Number.isNaN(x); }
export function intAlways(bytes: Uint8Array): boolean { return Number.isInteger(bytes.length); }
export function intFinite(bytes: Uint8Array): boolean { return Number.isFinite(bytes.length); }
export function intNever(bytes: Uint8Array): boolean { return Number.isNaN(bytes.length); }
export function guard(xs: readonly number[]): readonly number[] {
  return xs.filter((x) => Number.isFinite(x) && !Number.isNaN(x));
}
`,
  },
  {
    name: "Number methods outside the v1 classifiers are taught by name",
    gate: "NS9001",
    src: `
export function parsed(): number { return Number.parseFloat("1.5"); }
`,
  },
  {
    name: "the NaN and Infinity globals emit as f64 literals in every position",
    src: `
export function nanv(): number { return NaN; }
export function inf(): number { return Infinity; }
export function negInf(): number { return -Infinity; }
export function isMax(x: number): boolean { return x === Infinity; }
export function clamped(x: number): number { return Math.min(x, Infinity); }
`,
  },
  {
    name: "comptime % folds to the JS value (zero divisor, -0 dividend results, fractions)",
    src: `
export const REM_NAN = 5 % 0;
export function nanv(): number { return 5 % 0; }
export function negZero(): number { return -5 % 5; }
export function frac(): number { return 5.5 % 2; }
export function pick(bytes: Uint8Array): number { return bytes[6 % 4]; }
`,
  },
  {
    name: "module const tables: number/enum/string arrays, records, nested record arrays",
    src: `
import { asciiBytes } from "@native-sdk/core";
export type Filter = "all" | "active" | "done";
export const WEEKDAYS = [3, 5, 2, 8];
export const FACTORS: readonly number[] = [0.5, 1, 2];
export const ORDER: readonly Filter[] = ["done", "active", "all"];
export const NAMES: readonly string[] = ["mon", "tue"];
export const SEED_NAME = asciiBytes("Stretch");
export const DEFAULT_FILTER: Filter = "active";
export interface Limits { readonly lo: number; readonly hi: number; }
export const LIMITS: Limits = { lo: 1, hi: 9 };
export interface Task { readonly id: number; readonly title: Uint8Array; readonly done: boolean; }
export interface Model { readonly tasks: readonly Task[]; }
export const SEEDS: readonly Task[] = [
  { id: 1, title: asciiBytes("Ship"), done: false },
  { id: 2, title: asciiBytes("Test"), done: true },
];
export function initialModel(): Model { return { tasks: SEEDS }; }
export function weekdayAt(i: number): number { return WEEKDAYS[i]; }
export function weekdayCount(): number { return WEEKDAYS.length; }
export function weekdayTotal(): number {
  let t = 0;
  for (const w of WEEKDAYS) t += w;
  return t;
}
export function bigWeekdays(lim: number): readonly number[] { return WEEKDAYS.filter((w) => w > lim); }
export function orderAt(i: number): Filter { return ORDER[i]; }
export function nameMatches(n: string): boolean { return NAMES[0] === n; }
export function seedTitle(i: number): Uint8Array { return SEEDS[i].title; }
export function inRange(x: number): boolean { return x >= LIMITS.lo && x <= LIMITS.hi; }
`,
  },
  {
    name: "an unannotated module const record is taught toward the interface annotation",
    gate: "NS9001",
    src: `
export const LIMITS = { lo: 1, hi: 9 };
export function f(): number { return 1; }
`,
  },
  {
    name: "a spread in a module const table is a taught stop (tables are comptime data)",
    gate: "NS9001",
    src: `
export interface Limits { readonly lo: number; readonly hi: number; }
export const BASE: Limits = { lo: 1, hi: 9 };
export const WIDE: Limits = { ...BASE, hi: 99 };
export function f(): number { return 1; }
`,
  },
  {
    name: "a table number that does not fold at compile time is a taught stop",
    gate: "NS9001",
    src: `
function seed(): number { return 3; }
export const TABLE: readonly number[] = [1, seed()];
export function f(): number { return TABLE[0]; }
`,
  },
  {
    name: "type-changing map: scalars, bytes, block bodies, optional results, chained reads",
    src: `
export interface Task { readonly id: number; readonly title: Uint8Array; readonly streak: number; }
export function ids(tasks: readonly Task[]): readonly number[] { return tasks.map((t) => t.id); }
export function titles(tasks: readonly Task[]): readonly Uint8Array[] { return tasks.map((t) => t.title); }
export function doubled(tasks: readonly Task[]): readonly number[] { return tasks.map((t) => t.streak * 2); }
export function orNull(xs: readonly number[]): readonly (number | null)[] {
  return xs.map((x) => (x > 0 ? x : null));
}
export function capped(tasks: readonly Task[], lim: number): readonly number[] {
  return tasks.map((t) => {
    if (t.streak > lim) return lim;
    return t.streak;
  });
}
export function mappedCount(tasks: readonly Task[]): number {
  return tasks.map((t) => t.id).length;
}
export function firstTwoIds(tasks: readonly Task[]): readonly number[] {
  const all = tasks.map((t) => t.id);
  return all.slice(0, 2);
}
`,
  },
  {
    name: "callback index parameters across map/filter/find/findIndex/some/every",
    src: `
export interface Task { readonly id: number; readonly streak: number; }
export function weighted(xs: readonly number[]): readonly number[] { return xs.map((x, i) => x * i); }
export function evenSlots(xs: readonly number[]): readonly number[] { return xs.filter((x, i) => i % 2 === 0); }
export function lateBig(xs: readonly number[], at: number): number {
  return xs.find((x, i) => i > at && x > 0) ?? -1;
}
export function lateAt(xs: readonly number[], at: number): number {
  return xs.findIndex((x, i) => i >= at && x > 0);
}
export function anyLate(xs: readonly number[], at: number): boolean {
  return xs.some((x, i) => i > at);
}
export function frontLoaded(tasks: readonly Task[]): boolean {
  return tasks.every((t, i) => t.streak >= i);
}
`,
  },
  {
    name: "a callback declaring the third (array) parameter is a taught stop",
    gate: "NS9001",
    src: `
export function f(xs: readonly number[]): readonly number[] {
  return xs.map((x, i, all) => x + all.length);
}
`,
  },
  {
    name: "a reduce callback with an index parameter is a taught stop",
    gate: "NS9001",
    src: `
export function f(xs: readonly number[]): number {
  return xs.reduce((sum, x, i) => sum + x * i, 0);
}
`,
  },
  {
    name: "bytes subarray with out-of-range and negative bounds compiles to the clamped view",
    src: `
export function window(bytes: Uint8Array, from: number, to: number): Uint8Array {
  return bytes.subarray(from, to);
}
export function tail(bytes: Uint8Array, from: number): Uint8Array {
  return bytes.subarray(from);
}
export function whole(bytes: Uint8Array): Uint8Array {
  return bytes.subarray();
}
export function chained(bytes: Uint8Array, from: number): Uint8Array {
  return bytes.subarray(from).subarray(-2);
}
`,
  },
  {
    name: "array-method calls lower directly inside if and else-if conditions",
    src: `
export interface Task { readonly id: number; readonly done: boolean; }
export function grade(xs: readonly number[], flag: boolean): number {
  if (flag) return -1;
  else if (xs.some((x) => x > 3)) return 1;
  else if (xs.every((x) => x < 0)) return 2;
  return 0;
}
export function firstDone(tasks: readonly Task[]): number {
  if (tasks.some((t) => t.done)) {
    const hit = tasks.find((t) => t.done);
    if (hit === undefined) return -1;
    return hit.id;
  }
  return 0;
}
export function countIf(xs: readonly number[], lim: number): number {
  if (xs.filter((x) => x > lim).length > 1) return 2;
  return xs.findIndex((x) => x > lim) >= 0 ? 1 : 0;
}
`,
  },
  {
    name: "a while condition still may not lower statements (re-evaluated per iteration)",
    gate: "NS9001",
    src: `
export function f(xs: readonly number[]): number {
  let n = 0;
  while (xs.some((x) => x > n)) {
    n += 1;
  }
  return n;
}
`,
  },
  {
    name: "switch on a literal-union value: full coverage, shared labels, defaults, partial + break",
    src: `
export type Filter = "all" | "active" | "done";
export type Bit = 0 | 1;
export function label(f: Filter): number {
  switch (f) {
    case "all": return 0;
    case "active": return 1;
    case "done": return 2;
  }
}
export function sharedBody(f: Filter): number {
  switch (f) {
    case "active":
    case "done":
      return 1;
    default:
      return 0;
  }
}
export function partial(f: Filter): number {
  let n = 0;
  switch (f) {
    case "done":
      n = 5;
      break;
    case "active": {
      n = 2;
      break;
    }
  }
  return n;
}
export function flip(b: Bit): number {
  switch (b) {
    case 0: return 1;
    case 1: return 0;
  }
}
export function bitDefault(b: Bit): number {
  switch (b) {
    case 0: return 7;
    default: return 9;
  }
}
`,
  },
  {
    name: "a value-switch default that is not the last clause is a taught stop",
    gate: "NS9001",
    src: `
export type Filter = "all" | "active" | "done";
export function f(x: Filter): number {
  switch (x) {
    case "all": return 0;
    default: return 9;
    case "done": return 2;
  }
  return 1;
}
`,
  },
  {
    name: "case labels falling through into a value-switch default are a taught stop",
    gate: "NS9001",
    src: `
export type Filter = "all" | "active" | "done";
export function f(x: Filter): number {
  switch (x) {
    case "all":
    default:
      return 9;
  }
}
`,
  },
  {
    name: "switching on a plain number value emits the if/else chain",
    src: `
export function f(x: number): number {
  switch (x) {
    case 1: return 1;
    default: return 0;
  }
}
`,
  },
];

// The model tier (round 3): tagged unions as model fields, primitive arrays
// in the model, optional fields end to end, null-guarded `&&`/`||` chains,
// the -0 slot rule, and the NS1024 string-field gate.
const modelTierCases: Case[] = [
  {
    name: "a tag-discriminated union as a model field: construction, switch, kind guards",
    src: `
export type View =
  | { readonly kind: "list" }
  | { readonly kind: "detail"; readonly id: number };
export interface Model { readonly view: View; readonly n: number; }
export type Msg = { readonly kind: "open"; readonly id: number } | { readonly kind: "back" };
export function initialModel(): Model { return { view: { kind: "list" }, n: 0 }; }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "open": return { ...model, view: { kind: "detail", id: msg.id } };
    case "back": return { ...model, view: { kind: "list" } };
  }
}
export function shownId(model: Model): number {
  if (model.view.kind === "detail") return model.view.id;
  return -1;
}
export function viewCode(model: Model): number {
  switch (model.view.kind) {
    case "list": return 0;
    case "detail": return model.view.id;
  }
}
`,
  },
  {
    name: "model union arms with deep payloads: records, bytes, and primitive arrays",
    src: `
import { asciiBytes } from "@native-sdk/core";
export interface Note { readonly id: number; readonly title: Uint8Array; }
export type View =
  | { readonly kind: "list"; readonly scroll: number }
  | { readonly kind: "detail"; readonly note: Note; readonly tags: readonly number[] }
  | { readonly kind: "compose"; readonly draft: Uint8Array };
export interface Model { readonly view: View | null; readonly flags: readonly boolean[]; }
export type Msg = { readonly kind: "open"; readonly id: number } | { readonly kind: "close" };
export function initialModel(): Model { return { view: null, flags: [] }; }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "open":
      return { ...model, view: { kind: "detail", note: { id: msg.id, title: asciiBytes("note") }, tags: [1, 2, 3] } };
    case "close":
      return { ...model, view: { kind: "list", scroll: 0 } };
  }
}
export function weight(model: Model): number {
  if (model.view !== null && model.view.kind === "detail") return model.view.note.id + model.view.tags.length;
  return 0;
}
`,
  },
  {
    name: "primitive arrays in the model: numbers, booleans, tags, nested and optional",
    src: `
export type Grade = "low" | "high";
export interface Series { readonly points: readonly number[]; readonly name: Uint8Array; }
export interface Model {
  readonly xs: readonly number[];
  readonly flags: readonly boolean[];
  readonly grades: readonly Grade[];
  readonly series: readonly Series[];
  readonly pending: readonly number[] | null;
}
export type Msg = { readonly kind: "push"; readonly v: number } | { readonly kind: "clear" };
export function initialModel(): Model {
  return { xs: [], flags: [], grades: [], series: [], pending: null };
}
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "push":
      return { ...model, xs: [...model.xs, msg.v], flags: [...model.flags, msg.v > 0], pending: model.xs };
    case "clear":
      return { ...model, xs: [], flags: [], pending: null };
  }
}
export function total(model: Model): number {
  return model.xs.reduce((sum, x) => sum + x, 0);
}
`,
  },
  {
    name: "null-guarded && chains: statement, else-bearing, ternary, both orders, relational optionals",
    src: `
export interface Sel { readonly items: readonly number[]; readonly at: number; }
export interface Model { readonly sel: Sel | null; }
export type Msg = { readonly kind: "a" } | { readonly kind: "b" };
export function initialModel(): Model { return { sel: null }; }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) { case "a": return model; case "b": return { sel: null }; }
}
export function hasItems(model: Model): boolean {
  if (model.sel !== null && model.sel.items.length > 0) return true;
  return false;
}
export function branchy(model: Model): number {
  if (model.sel !== null && model.sel.at > 0) return model.sel.at;
  else return -1;
}
export function ternary(model: Model): number {
  return model.sel !== null && model.sel.at > 0 ? model.sel.at : -1;
}
export function flipped(model: Model): boolean {
  return null !== model.sel && model.sel.at >= 0;
}
export function below(cls: number | null, lim: number): boolean {
  return cls !== null && cls < lim;
}
`,
  },
  {
    name: "null-guarded || chains: or-else shape, exit narrowing, ternary dual",
    src: `
export interface Sel { readonly items: readonly number[]; readonly at: number; }
export function emptyish(sel: Sel | null): boolean {
  return sel === null || sel.items.length === 0;
}
export function firstOrMinus(sel: Sel | null): number {
  if (sel === null || sel.items.length === 0) return -1;
  return sel.items[0];
}
export function clamp(cls: number | null): number {
  if (cls === null || cls < 0) return 0;
  return cls;
}
export function pick(sel: Sel | null): number {
  return sel === null || sel.at < 0 ? -1 : sel.at;
}
`,
  },
  {
    name: "a null guard in a while condition re-tests per iteration",
    src: `
export interface Sel { readonly at: number; readonly len: number; }
export function walk(start: Sel | null): number {
  let cur: Sel | null = start;
  let hops = 0;
  while (cur !== null && cur.len > 0) {
    hops += cur.len;
    cur = cur.len > 2 ? { at: cur.at, len: cur.len - 1 } : null;
  }
  return hops;
}
`,
  },
  {
    name: "-0 literals and -0-producing constant arithmetic take float slots",
    src: `
export function negZero(): number { return -0; }
export function prodNegZero(): number { return 0 * -1; }
export function viaConst(): number { const z = -0; return z; }
export function timesNeg(x: number): number { return x * -1; }
`,
  },
  {
    name: "nested callbacks with colliding element and index names emit uniquely",
    src: `
export function weights(xs: readonly number[]): number {
  return xs.map((x, i) => xs.map((y, i2) => y * i2 + i).reduce((acc, v) => acc + v, 0) + x * i).reduce((acc, v) => acc + v, 0);
}
export function pairs(xs: readonly number[]): number {
  return xs.map((x, i) => xs.map((x2, j) => x2 * x + j * i).reduce((a, v) => a + v, 0)).reduce((a, v) => a + v, 0);
}
`,
  },
  {
    name: "a string-typed model field is a taught stop at the declaration",
    gate: "NS1024",
    src: `
export interface Model { readonly title: string; readonly n: number; }
export type Msg = { readonly kind: "a" } | { readonly kind: "b" };
export function initialModel(): Model { return { title: "x", n: 0 }; }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) { case "a": return model; case "b": return model; }
}
`,
  },
  {
    name: "a string field nested in a model union arm is the same taught stop",
    gate: "NS1024",
    src: `
export type View =
  | { readonly kind: "list" }
  | { readonly kind: "detail"; readonly caption: string };
export interface Model { readonly view: View; }
export type Msg = { readonly kind: "a" } | { readonly kind: "b" };
export function initialModel(): Model { return { view: { kind: "list" } }; }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) { case "a": return model; case "b": return model; }
}
`,
  },
  {
    name: "a string-array model field is the same taught stop",
    gate: "NS1024",
    src: `
export interface Model { readonly names: readonly string[]; }
export type Msg = { readonly kind: "a" } | { readonly kind: "b" };
export function initialModel(): Model { return { names: [] }; }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) { case "a": return model; case "b": return model; }
}
`,
  },
  {
    name: "an array of unions in the model stays a loud stop (not in v1)",
    gate: "NS9001",
    src: `
export type Item = { readonly kind: "a" } | { readonly kind: "b"; readonly n: number };
export interface Model { readonly items: readonly Item[]; }
export type Msg = { readonly kind: "x" } | { readonly kind: "y" };
export function initialModel(): Model { return { items: [] }; }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) { case "x": return model; case "y": return model; }
}
`,
  },
  {
    name: "an array of byte-strings in the model stays a loud stop (not in v1)",
    gate: "NS9001",
    src: `
export interface Model { readonly rows: readonly Uint8Array[]; }
export type Msg = { readonly kind: "x" } | { readonly kind: "y" };
export function initialModel(): Model { return { rows: [] }; }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) { case "x": return model; case "y": return model; }
}
`,
  },
];

// A shared preamble for the streaming-op cases (slice D): every arm shape
// a spawn/audio stream can target, plus the audio event record.
const streamMsg = `
export type AudioState = "loaded" | "position" | "completed" | "failed" | "rejected" | "spectrum";
export interface Model { readonly lines: number; readonly out: Uint8Array; readonly code: number; readonly errs: number; readonly pos: number; }
export type Msg =
  | { readonly kind: "go"; readonly which: number }
  | { readonly kind: "line"; readonly text: Uint8Array }
  | { readonly kind: "done"; readonly code: number }
  | { readonly kind: "sampled"; readonly code: number; readonly output: Uint8Array }
  | { readonly kind: "audio_evt"; readonly state: AudioState; readonly positionMs: number; readonly durationMs: number; readonly playing: boolean; readonly buffering: boolean; readonly bands: Uint8Array }
  | { readonly kind: "failed"; readonly why: Uint8Array };
export function initialModel(): Model { return { lines: 0, out: new Uint8Array(0), code: -1, errs: 0, pos: 0 }; }
`;

// The tail arms every streaming case's update must cover.
const streamTail = `
    case "line": return { ...model, lines: model.lines + 1 };
    case "done": return { ...model, code: msg.code };
    case "sampled": return { ...model, code: msg.code, out: msg.output };
    case "audio_evt": return { ...model, pos: msg.positionMs };
    case "failed": return { ...model, errs: model.errs + 1 };
  }
}
`;

// Slice E: grammar-completeness round — the new statement/operator/
// declaration mappings in REALISTIC combinations (the minimal per-production
// pins live in grammar_matrix.test.ts), plus the new teaching gates.
const grammarCases: Case[] = [
  {
    name: "do-while inside update with model narrowing and a builder",
    src: `
export interface Model { readonly xs: readonly number[]; readonly cursor: number | null; }
export type Msg = { readonly kind: "walk" } | { readonly kind: "noop" };
export function initialModel(): Model { return { xs: [3, 1, 2], cursor: null }; }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "walk": {
      const out: number[] = [];
      let i = 0;
      do {
        if (i < model.xs.length) out.push(model.xs[i] * 2);
        i += 1;
      } while (i < model.xs.length);
      return { ...model, xs: out };
    }
    case "noop": return model;
  }
}`,
  },
  {
    name: "a do-while whose body always exits emits no unreachable trailing test",
    src: `
export function firstByte(xs: Uint8Array): number {
  do {
    if (xs.length > 0) return xs[0];
    return -1;
  } while (true);
}`,
  },
  {
    name: "labeled loops drive nested scans over record arrays",
    src: `
export interface Cell { readonly row: number; readonly col: number; }
export function firstMatch(cells: readonly Cell[], rows: number, cols: number): number {
  let hit = -1;
  outer: for (let r = 0; r < rows; r++) {
    for (let c = 0; c < cols; c++) {
      for (const cell of cells) {
        if (cell.row === r && cell.col === c) { hit = r * 100 + c; break outer; }
      }
    }
  }
  return hit;
}`,
  },
  {
    name: "a default arm coexists with payload captures on the named cases",
    src: `
export interface Model { readonly n: number; }
export type Msg =
  | { readonly kind: "set"; readonly v: number }
  | { readonly kind: "bump"; readonly by: number }
  | { readonly kind: "reset" }
  | { readonly kind: "noop" };
export function initialModel(): Model { return { n: 0 }; }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "set": return { n: msg.v };
    case "bump": return { n: model.n + msg.by };
    default: return model;
  }
}`,
  },
  {
    name: "exponent, shifts, and the compound family flow through inference soundly",
    src: `
export function checksum(xs: Uint8Array): number {
  let h = 0;
  for (const b of xs) {
    h ^= b;
    h <<= 1;
    h >>>= 0;
    h &= 0xffff;
  }
  return h;
}
export function decay(base: number, steps: Uint8Array): number {
  let v = base;
  for (const s of steps) {
    v *= 0.5;
    v += s;
    v **= 1;
  }
  v /= 2;
  return v;
}`,
  },
  {
    name: "destructured const fields feed integer and float domains per field",
    src: `
export interface Frame { readonly width: number; readonly height: number; readonly scale: number; }
export function area(frame: Frame, bytes: Uint8Array): number {
  const { width, height, scale } = frame;
  let cells = 0;
  for (let i = 0; i < bytes.length; i++) {
    if (bytes[i] > 0) cells += 1;
  }
  return width * height * scale + cells;
}`,
  },
  {
    name: "NS1039: the intrinsic SDK module is imported by name",
    gate: "NS1039",
    src: `
import * as sdk from "@native-sdk/core";
export function f(): number { return 1; }`,
  },
  {
    name: "R15d: a const-bound local arrow hoists to a module-level function",
    src: `export function f(): number { const g = (x: number): number => x + 1; return g(1); }`,
  },
  {
    name: "NS1054: a capturing local function value is taught toward parameters",
    gate: "NS1054",
    src: `export function f(n: number): number { const g = (): number => n + 1; return g(); }`,
  },
  {
    name: "export lists bind names over declarations: un-renamed exports pub, renames alias",
    src: `function base(): number { return 2; }
const SCALE = 3;
export { base, SCALE as FACTOR };
export function f(): number { return base() * SCALE; }`,
  },
  {
    name: "NS1047: re-exporting the SDK surface is not the core's to bind",
    gate: "NS1047",
    src: `import { Cmd } from "@native-sdk/core";
export { Cmd };
export function f(): number { return 1; }`,
  },
  {
    name: "NS1047: renaming a generic template has no single value to bind",
    gate: "NS1047",
    src: `function pick<T>(a: T, b: T, first: boolean): T { return first ? a : b; }
export { pick as choose };
export function f(x: number, y: number): number { return pick(x, y, x < y); }`,
  },
  {
    name: "NS1014: a renamed export cannot bind an entry-point name",
    gate: "NS1014",
    src: `
export interface Model { readonly n: number; }
export type Msg = { readonly kind: "a" } | { readonly kind: "b" };
function step(model: Model, msg: Msg): Model { return model; }
export { step as update };
export function initialModel(): Model { return { n: 0 }; }`,
  },
  {
    name: "NS1048: loose equality is taught toward strict",
    gate: "NS1048",
    src: `export function f(a: number, b: number): boolean { return a != b; }`,
  },
  {
    name: "NS1049: var in a for-init is taught toward let",
    gate: "NS1049",
    src: `export function f(n: number): number { let t = 0; for (var i = 0; i < n; i++) { t += i; } return t; }`,
  },
  {
    name: "R15e: a generic helper monomorphizes per call site",
    src: `export function pick<T>(a: T, b: T, first: boolean): T { return first ? a : b; }
export function f(x: number, y: number): number { return pick(x, y, x < y); }`,
  },
  {
    name: "NS1050: a generic function VALUE is taught toward a module-level declaration",
    gate: "NS1050",
    src: `export function f(): number { const id = <T>(x: T): T => x; return id(1); }`,
  },
];

// Slice D: the streaming multi-result ops — subprocess spawn and the audio
// event stream — emit-clean in their documented shapes, gated with the
// taught rules everywhere else.
const streamingCases: Case[] = [
  {
    name: "spawn and the audio verbs emit in their documented shapes",
    src: `
import { Cmd, asciiBytes } from "@native-sdk/core";
${streamMsg}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go":
      if (msg.which === 0) return [model, Cmd.spawn([asciiBytes("/bin/ps"), asciiBytes("-axo")], { key: "ps", line: "line", exit: "done", err: "failed" })];
      if (msg.which === 1) return [model, Cmd.spawn([asciiBytes("/usr/bin/pbcopy")], { key: "copy", stdin: model.out, exit: "done", err: "failed" })];
      if (msg.which === 2) return [model, Cmd.spawn([asciiBytes("/usr/bin/vm_stat")], { key: "mem", collect: true, exit: "sampled", err: "failed" })];
      if (msg.which === 3) return [model, Cmd.cancel("ps")];
      if (msg.which === 4) return [model, Cmd.audioPlay("player", { path: asciiBytes("music/track.mp3") }, { event: "audio_evt" })];
      if (msg.which === 5) return [model, Cmd.audioPlay("player", { url: asciiBytes("https://cdn.test/track.mp3"), cachePath: model.out, expectedBytes: 4096 }, { event: "audio_evt" })];
      if (msg.which === 6) return [model, Cmd.batch([Cmd.audioPause("player"), Cmd.audioResume("player")])];
      if (msg.which === 7) return [model, Cmd.audioSeek("player", 45000)];
      if (msg.which === 8) return [model, Cmd.audioSetVolume("player", 0.5)];
      return [model, Cmd.audioStop("player")];
${streamTail}
`,
  },
  {
    name: "a line-mode spawn exit arm without a single number payload is taught",
    gate: "NS1027",
    src: `
import { Cmd, asciiBytes, type TimestampKind } from "@native-sdk/core";
${streamMsg}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.spawn([asciiBytes("/bin/ps")], { line: "line", exit: "line" as TimestampKind<Msg>, err: "failed" })];
${streamTail}
`,
  },
  {
    name: "a collect spawn exit arm that is not a { code, output } record is taught",
    gate: "NS1027",
    src: `
import { Cmd, asciiBytes, type FetchedKind } from "@native-sdk/core";
${streamMsg}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.spawn([asciiBytes("/bin/ps")], { collect: true, exit: "done" as FetchedKind<Msg>, err: "failed" })];
${streamTail}
`,
  },
  {
    name: "a line arm on a collect spawn is taught (collect has no line framing)",
    gate: "NS1027",
    src: `
import { Cmd, asciiBytes, type SpawnCollectRoute } from "@native-sdk/core";
${streamMsg}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.spawn([asciiBytes("/bin/ps")], { collect: true, line: "line", exit: "sampled", err: "failed" } as SpawnCollectRoute<Msg>)];
${streamTail}
`,
  },
  {
    name: "a dynamic argv value is taught (argv is an inline array literal)",
    gate: "NS1029",
    src: `
import { Cmd, asciiBytes } from "@native-sdk/core";
${streamMsg}
const PS: readonly Uint8Array[] = [asciiBytes("/bin/ps")];
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.spawn(PS, { exit: "done", err: "failed" })];
${streamTail}
`,
  },
  {
    name: "an empty argv stops at compile time",
    gate: "NS1030",
    src: `
import { Cmd } from "@native-sdk/core";
${streamMsg}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.spawn([], { exit: "done", err: "failed" })];
${streamTail}
`,
  },
  {
    name: "more argv elements than the engine accepts stops at compile time",
    gate: "NS1030",
    src: `
import { Cmd, asciiBytes } from "@native-sdk/core";
${streamMsg}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.spawn([${Array.from({ length: 17 }, (_, i) => `asciiBytes("a${i}")`).join(", ")}], { exit: "done", err: "failed" })];
${streamTail}
`,
  },
  {
    name: "an argv block over the engine's byte bound stops at compile time",
    gate: "NS1030",
    src: `
import { Cmd, asciiBytes } from "@native-sdk/core";
${streamMsg}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.spawn([asciiBytes("/bin/echo"), asciiBytes(${JSON.stringify("a".repeat(2048))})], { exit: "done", err: "failed" })];
${streamTail}
`,
  },
  {
    name: "an over-bound stdin literal stops at compile time",
    gate: "NS1030",
    src: `
import { Cmd, asciiBytes } from "@native-sdk/core";
${streamMsg}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.spawn([asciiBytes("/usr/bin/pbcopy")], { stdin: asciiBytes(${JSON.stringify("s".repeat(4097))}), exit: "done", err: "failed" })];
${streamTail}
`,
  },
  {
    name: "an audio event arm whose state union misses a member is taught",
    gate: "NS1027",
    src: `
import { Cmd, asciiBytes, type AudioEventKind } from "@native-sdk/core";
export type NarrowState = "loaded" | "position" | "completed" | "failed" | "rejected";
export interface Model { readonly pos: number; readonly errs: number; }
export type Msg =
  | { readonly kind: "go" }
  | { readonly kind: "audio_evt"; readonly state: NarrowState; readonly positionMs: number; readonly durationMs: number; readonly playing: boolean; readonly buffering: boolean; readonly bands: Uint8Array }
  | { readonly kind: "failed"; readonly why: Uint8Array };
export function initialModel(): Model { return { pos: 0, errs: 0 }; }
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.audioPlay("player", { path: asciiBytes("a.mp3") }, { event: "audio_evt" as AudioEventKind<Msg> })];
    case "audio_evt": return { ...model, pos: msg.positionMs };
    case "failed": return { ...model, errs: model.errs + 1 };
  }
}
`,
  },
  {
    name: "an audio event arm with a wrong field shape is taught",
    gate: "NS1027",
    src: `
import { Cmd, asciiBytes, type AudioEventKind } from "@native-sdk/core";
${streamMsg}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.audioPlay("player", { path: asciiBytes("a.mp3") }, { event: "sampled" as AudioEventKind<Msg> })];
${streamTail}
`,
  },
  {
    name: "an audio source without a path or url is taught (nothing could play)",
    gate: "NS1029",
    src: `
import { Cmd, asciiBytes } from "@native-sdk/core";
${streamMsg}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.audioPlay("player", { cachePath: asciiBytes("cache/a.mp3") }, { event: "audio_evt" })];
${streamTail}
`,
  },
  {
    name: "a dynamic audio key is taught (keys are compile-time routing data)",
    gate: "NS1027",
    src: `
import { Cmd } from "@native-sdk/core";
${streamMsg}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.audioPause(model.errs > 0 ? "a" : "b")];
${streamTail}
`,
  },
  {
    name: "an audio volume literal outside 0..1 stops at compile time",
    gate: "NS1030",
    src: `
import { Cmd } from "@native-sdk/core";
${streamMsg}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.audioSetVolume("player", 1.5)];
${streamTail}
`,
  },
  {
    name: "a negative audio seek literal stops at compile time",
    gate: "NS1030",
    src: `
import { Cmd } from "@native-sdk/core";
${streamMsg}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.audioSeek("player", -250)];
${streamTail}
`,
  },
];

// The multi-file round: a core may split into modules under src/ (relative
// imports with real .ts filenames), and SDK library modules
// ("@native-sdk/core/text") transpile in when imported. Emit cases join the
// zig-compile corpus below; boundary mistakes are gated by NS1034-NS1038
// and the narrowed NS1014 (entry contract).
interface MultiFileCase {
  readonly name: string;
  readonly gate?: string;
  readonly files: Record<string, string>;
}

const multiFileCases: MultiFileCase[] = [
  {
    name: "namespace imports alias in-graph modules: values, calls, qualified types, cross-class args",
    files: {
      "core.ts": `
import * as util from "./util.ts";
export interface Model { readonly n: number; }
export type Msg = { readonly kind: "bump" } | { readonly kind: "reset" };
export function initialModel(): Model { return { n: util.SEED }; }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "bump": {
      const cfg: util.Cfg = { step: 2, scale: 1.5 };
      return { n: util.grow(model.n, cfg) };
    }
    case "reset": return { n: util.SEED };
  }
}`,
      "util.ts": `
export interface Cfg { readonly step: number; readonly scale: number; }
export const SEED = 5;
export function grow(n: number, cfg: Cfg): number { return n + cfg.step * cfg.scale; }`,
    },
  },
  {
    name: "NS1039: a namespace alias used as a value is taught",
    gate: "NS1039",
    files: {
      "core.ts": `
import * as util from "./util.ts";
const grabbed = util;
export function f(): number { return grabbed.SEED; }`,
      "util.ts": `export const SEED = 5;`,
    },
  },
  {
    name: "NS1038: a type and a same-file exported value cannot share a name",
    gate: "NS1038",
    files: {
      "core.ts": `
export interface Config { readonly n: number; }
export const Config = { n: 1 };
export function f(c: Config): number { return c.n; }`,
    },
  },
  {
    name: "value re-exports chain across modules and renames bind new names",
    files: {
      "core.ts": `
import { bump } from "./api.ts";
function tripled(n: number): number { return n * 3; }
export { tripled as thrice };
export { bump } from "./api.ts";
export function f(n: number): number { return bump(n) + tripled(n); }`,
      "api.ts": `export { bump } from "./impl.ts";`,
      "impl.ts": `export function bump(n: number): number { return n + 1; }`,
    },
  },
  {
    name: "NS1014: an imported module list-exporting an entry point is taught",
    gate: "NS1014",
    files: {
      "core.ts": `
import { helper } from "./extra.ts";
export interface Model { readonly n: number; }
export type Msg = { readonly kind: "a" } | { readonly kind: "b" };
export function initialModel(): Model { return { n: helper() }; }
export function update(model: Model, msg: Msg): Model { return model; }`,
      "extra.ts": `
export function helper(): number { return 1; }
function subscriptions(): number { return 2; }
export { subscriptions };`,
    },
  },
  {
    name: "NS1014: the entry re-exporting an entry point from an imported module is taught",
    gate: "NS1014",
    files: {
      "core.ts": `
export interface Model { readonly n: number; }
export type Msg = { readonly kind: "a" } | { readonly kind: "b" };
export { update } from "./logic.ts";
export function initialModel(): Model { return { n: 0 }; }`,
      "logic.ts": `
import type { Model, Msg } from "./core.ts";
export function update(model: Model, msg: Msg): Model { return model; }`,
    },
  },
  {
    name: "a renamed export-list helper joins the model binding surface under its exported name",
    files: {
      "core.ts": `
export interface Model { readonly tasks: readonly number[]; }
export type Msg = { readonly kind: "a" } | { readonly kind: "b" };
export function initialModel(): Model { return { tasks: [] }; }
export function update(model: Model, msg: Msg): Model { return model; }
function taskTotal(model: Model): number { return model.tasks.length; }
export { taskTotal as taskCount };
export const viewUnbound = ["taskCount"] as const;`,
    },
  },
  {
    name: "NS1038: a renamed export colliding with another module's exported value is taught",
    gate: "NS1038",
    files: {
      "core.ts": `
import { pickOne } from "./util.ts";
function localPick(): number { return 2; }
export { localPick as pickOne };
export function f(): number { return pickOne() + localPick(); }`,
      "util.ts": `export function pickOne(): number { return 1; }`,
    },
  },
  {
    name: "cross-file types, tables, consts, and helpers resolve and emit",
    files: {
      "core.ts": `
import { asciiBytes } from "@native-sdk/core";
import { LIMIT, SEEDS, capped, label, type Item, type Level } from "./tables.ts";
export interface Model { readonly items: readonly Item[]; readonly count: number; readonly level: Level; }
export type Msg = { readonly kind: "add" } | { readonly kind: "reset" };
export function initialModel(): Model {
  return { items: SEEDS, count: 0, level: "low" };
}
export function title(model: Model): Uint8Array {
  return label(model.level);
}
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "add": return { ...model, count: capped(model.count + 1), level: model.count + 1 >= LIMIT ? "high" : "low" };
    case "reset": return { ...model, count: LIMIT - LIMIT, level: "low" };
  }
}
`,
      "tables.ts": `
import { asciiBytes } from "@native-sdk/core";
export type Level = "low" | "high";
export interface Item { readonly id: number; readonly name: Uint8Array; }
export const LIMIT = 3;
export const SEEDS: readonly Item[] = [
  { id: 1, name: asciiBytes("one") },
  { id: 2, name: asciiBytes("two") },
];
export function capped(n: number): number {
  return n > LIMIT ? LIMIT : n;
}
export function label(level: Level): Uint8Array {
  return level === "low" ? asciiBytes("Low") : asciiBytes("High");
}
`,
    },
  },
  {
    name: "cross-file discriminated union payloads and subdirectory modules",
    files: {
      "core.ts": `
import { emptyView, viewName, type View } from "./ui/views.ts";
export interface Model { readonly view: View; }
export type Msg = { readonly kind: "open"; readonly id: number } | { readonly kind: "close" };
export function initialModel(): Model { return { view: emptyView() }; }
export function currentView(model: Model): Uint8Array { return viewName(model.view); }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "open": return { view: { kind: "detail", id: msg.id } };
    case "close": return { view: emptyView() };
  }
}
`,
      "ui/views.ts": `
import { asciiBytes } from "@native-sdk/core";
export type View = { readonly kind: "list" } | { readonly kind: "detail"; readonly id: number };
export function emptyView(): View { return { kind: "list" }; }
export function viewName(view: View): Uint8Array {
  switch (view.kind) {
    case "list": return asciiBytes("list");
    case "detail": return asciiBytes("detail");
  }
  return asciiBytes("list");
}
`,
    },
  },
  {
    name: "the SDK text library transpiles in when imported",
    files: {
      "core.ts": `
import { asciiBytes } from "@native-sdk/core";
import { applyTextInputEvent, containsIgnoreCase, trimAsciiSpaces, type TextEditState, type TextInputEvent } from "@native-sdk/core/text";
export interface Model { readonly draft: Uint8Array; }
export type Msg = { readonly kind: "edit"; readonly edit: TextInputEvent } | { readonly kind: "clear" };
export function initialModel(): Model { return { draft: new Uint8Array(0) }; }
export function matchesHello(model: Model): boolean {
  return containsIgnoreCase(trimAsciiSpaces(model.draft), asciiBytes("hello"));
}
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "edit": {
      const state: TextEditState = { text: model.draft, selection: { anchor: model.draft.length, focus: model.draft.length }, composition: null };
      const next = applyTextInputEvent(state, msg.edit, 64);
      if (next === null) return model;
      return { draft: next.text };
    }
    case "clear": return { draft: new Uint8Array(0) };
  }
}
`,
    },
  },
  {
    name: "type-only back-edges are legal (helpers over the entry's Model)",
    files: {
      "core.ts": `
import { bump } from "./logic.ts";
export interface Model { readonly count: number; }
export type Msg = { readonly kind: "add" } | { readonly kind: "noop" };
export function initialModel(): Model { return { count: 0 }; }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "add": return bump(model);
    case "noop": return model;
  }
}
`,
      "logic.ts": `
import type { Model } from "./core.ts";
export function bump(model: Model): Model {
  return { ...model, count: model.count + 1 };
}
`,
    },
  },
  {
    name: "colliding PRIVATE helpers unique with a per-module prefix",
    files: {
      "core.ts": `
import { first } from "./a.ts";
import { second } from "./b.ts";
export interface Model { readonly count: number; }
export type Msg = { readonly kind: "go" } | { readonly kind: "noop" };
export function initialModel(): Model { return { count: 0 }; }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "go": return { count: first(model.count) + second(model.count) };
    case "noop": return model;
  }
}
`,
      "a.ts": `
function scale(n: number): number { return n * 2; }
export function first(n: number): number { return scale(n); }
`,
      "b.ts": `
function scale(n: number): number { return n * 3; }
export function second(n: number): number { return scale(n); }
`,
    },
  },
  {
    name: "an import escaping src/ is taught (NS1034)",
    gate: "NS1034",
    files: {
      "core.ts": `
// @ts-expect-error the escape is rejected before resolution matters.
import { helper } from "../outside.ts";
export const y = helper;
`,
    },
  },
  {
    name: "a bare npm runtime import is taught (NS1035)",
    gate: "NS1035",
    files: {
      "core.ts": `
// @ts-expect-error the package deliberately does not resolve.
import { thing } from "lodash";
export const y = thing;
`,
    },
  },
  {
    name: "a runtime import cycle is taught (NS1036)",
    gate: "NS1036",
    files: {
      "core.ts": `
import { a } from "./a.ts";
export const y = a;
`,
      "a.ts": `
import { b } from "./b.ts";
export const a = b + 1;
`,
      "b.ts": `
import { a } from "./a.ts";
export const b = a + 1;
`,
    },
  },
  {
    name: "a missing module file is taught (NS1037)",
    gate: "NS1037",
    files: {
      "core.ts": `
// @ts-expect-error the module deliberately does not exist.
import { gone } from "./gone.ts";
export const y = gone;
`,
    },
  },
  {
    name: "an unknown @native-sdk module is taught (NS1037)",
    gate: "NS1037",
    files: {
      "core.ts": `
// @ts-expect-error the SDK ships no such module.
import { nope } from "@native-sdk/core/nope";
export const y = nope;
`,
    },
  },
  {
    name: "a cross-file type-name collision is taught (NS1038)",
    gate: "NS1038",
    files: {
      "core.ts": `
import { seed } from "./other.ts";
export interface Item { readonly id: number; }
export const first: Item = { id: 1 };
export const second = seed;
`,
      "other.ts": `
export interface Item { readonly id: number; readonly extra: boolean; }
export function seed(): Item { return { id: 2, extra: true }; }
`,
    },
  },
  {
    name: "a cross-file EXPORTED value collision is taught (NS1038)",
    gate: "NS1038",
    files: {
      "core.ts": `
import { helper } from "./other.ts";
export function scale(n: number): number { return n * 2; }
export const y = helper(scale(2));
`,
      "other.ts": `
export function scale(n: number): number { return n * 3; }
export function helper(n: number): number { return scale(n); }
`,
    },
  },
  {
    name: "update exported from an imported module is taught (NS1014, the entry contract)",
    gate: "NS1014",
    files: {
      "core.ts": `
import { seed } from "./logic.ts";
export interface Model { readonly count: number; }
export type Msg = { readonly kind: "add" } | { readonly kind: "noop" };
export function initialModel(): Model { return seed(); }
`,
      "logic.ts": `
import type { Model, Msg } from "./core.ts";
export function seed(): Model { return { count: 0 }; }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "add": return { count: model.count + 1 };
    case "noop": return model;
  }
}
`,
    },
  },
  {
    name: "viewUnbound declared in an imported module is taught (NS1014)",
    gate: "NS1014",
    files: {
      "core.ts": `
import { seed } from "./logic.ts";
export interface Model { readonly count: number; }
export type Msg = { readonly kind: "add" } | { readonly kind: "noop" };
export function initialModel(): Model { return seed(); }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "add": return { count: model.count + 1 };
    case "noop": return model;
  }
}
`,
      "logic.ts": `
import type { Model } from "./core.ts";
export function seed(): Model { return { count: 0 }; }
export const viewUnbound = ["count"] as const;
`,
    },
  },
];

const completeLangTier2Cases: Case[] = [
  {
    name: "arrays of byte buffers follow array ownership, not the bytes legacy branch",
    src: `
export function concatAll(parts: readonly Uint8Array[]): Uint8Array {
  let total = 0;
  for (const p of parts) total += p.length;
  const out = new Uint8Array(total);
  let off = 0;
  for (const p of parts) { out.set(p, off); off += p.length; }
  return out;
}
export function join(a: Uint8Array, b: Uint8Array): Uint8Array {
  const parts: Uint8Array[] = [];
  parts.push(a);
  parts.push(b);
  return concatAll(parts);
}
`,
  },
  {
    name: "a shared array of byte buffers still teaches ownership on push",
    gate: "NS1001",
    src: `
export function collect(parts: Uint8Array[], extra: Uint8Array): number {
  parts.push(extra);
  return parts.length;
}
`,
  },
  {
    name: "bare module-function references inline as array callbacks",
    src: `
function double(n: number): number { return n * 2; }
function isPositive(n: number): boolean { return n > 0; }
function add(a: number, b: number): number { return a + b; }
function byAscending(a: number, b: number): number { return a - b; }
export function f(xs: readonly number[]): number {
  return xs.map(double).filter(isPositive).toSorted(byAscending).reduce(add, 0);
}
`,
  },
  {
    name: "a bare reference to a hoisted function-expression helper is a callback too",
    src: `
export function f(xs: readonly number[]): readonly number[] {
  const scale = function (x: number): number { return x * 3; };
  return xs.map(scale);
}
`,
  },
];

const dataClassCases: Case[] = [
  {
    name: "R19b: static methods and static readonly consts lower to module-level declarations",
    src: `
import { asciiBytes } from "@native-sdk/core";
export class Task {
  id: number;
  done: boolean = false;
  static readonly LIMIT = 9;
  static readonly LABEL = asciiBytes("task");
  constructor(id: number) { this.id = id; }
  static clampId(n: number): number { return n > Task.LIMIT ? Task.LIMIT : n; }
  static labelLength(): number { return Task.LABEL.length; }
  bump(): void { this.id += 1; }
}
export function f(n: number): number {
  const t = new Task(Task.clampId(n));
  t.bump();
  return t.id + Task.LIMIT + Task.labelLength();
}
`,
  },
  {
    name: "R19b: private and protected keywords erase (tsc enforces them at the type level)",
    src: `
export class Counter {
  private n: number = 0;
  protected step: number = 1;
  private raise(): void { this.n += this.step; }
  bump(): void { this.raise(); }
  value(): number { return this.n; }
}
export function f(): number { const c = new Counter(); c.bump(); c.bump(); return c.value(); }
`,
  },
  {
    name: "NS1010: a mutable static field is module state",
    gate: "NS1010",
    src: `
export class Config { static shared: number = 2; }
export function f(): number { return 1; }
`,
  },
  {
    name: "NS1056: this inside a static member is taught toward the class name",
    gate: "NS1056",
    src: `
export class Config {
  static readonly K = 1;
  static bad(): number { return this.K; }
}
export function f(): number { return 1; }
`,
  },
  {
    name: "data class: fields, constructor, mutating and reading methods",
    src: `
export class Counter {
  count: number = 0;
  step: number;
  constructor(step: number) { this.step = step; }
  bump(): void { this.count += this.step; }
  value(): number { return this.count; }
}
export function f(): number {
  const c = new Counter(2);
  c.bump();
  c.bump();
  return c.value();
}
`,
  },
  {
    name: "data class: bytes and array fields, rebuild-style field assignment",
    src: `
import { asciiBytes } from "@native-sdk/core";
export class Log {
  title: Uint8Array;
  entries: readonly number[] = [];
  constructor(title: Uint8Array) { this.title = title; }
  add(n: number): void { this.entries = [...this.entries, n]; }
  total(): number {
    let sum = 0;
    for (const e of this.entries) sum += e;
    return sum;
  }
}
export function f(): number {
  const log = new Log(asciiBytes("run"));
  log.add(1.5);
  log.add(2);
  return log.total() + log.title.length;
}
`,
  },
  {
    name: "class instances flow as record-shaped values between functions (read-only)",
    src: `
export class Point {
  x: number;
  y: number;
  constructor(x: number, y: number) { this.x = x; this.y = y; }
  norm(): number { return this.x * this.x + this.y * this.y; }
}
function sumNorms(ps: readonly Point[]): number {
  let total = 0;
  for (const p of ps) total += p.norm();
  return total;
}
export function f(): number {
  const ps: readonly Point[] = [new Point(1, 2), new Point(3, 4)];
  return sumNorms(ps);
}
`,
  },
  {
    name: "extends teaches inheritance",
    gate: "NS1055",
    src: `
class Base { n: number = 0; }
export class Derived extends Base { m: number = 1; }
export function f(): number { return 1; }
`,
  },
  {
    name: "accessors, statics, and #-privates teach the member surface",
    gate: "NS1056",
    src: `
export class Config {
  #secret: number = 1;
  static shared: number = 2;
  get doubled(): number { return 4; }
}
export function f(): number { return 1; }
`,
  },
  {
    name: "an unannotated class field teaches the annotation form",
    gate: "NS1056",
    src: `
export class Counter { n = 0; }
export function f(): number { return 1; }
`,
  },
  {
    name: "`this` escaping as a value teaches",
    gate: "NS1056",
    src: `
export class Chain {
  n: number = 0;
  add(x: number): Chain { this.n += x; return this; }
}
export function f(): number { return 1; }
`,
  },
  {
    name: "generic classes teach the concrete-struct rule",
    gate: "NS1053",
    src: `
export class Box<T> { v: T | null = null; }
export function f(): number { return 1; }
`,
  },
  {
    name: "a mutating method on a parameter instance teaches ownership",
    gate: "NS1001",
    src: `
export class Counter {
  n: number = 0;
  bump(): void { this.n += 1; }
}
export function f(c: Counter): number { c.bump(); return c.n; }
`,
  },
  {
    name: "a mutating method after the instance escaped teaches NS1051",
    gate: "NS1051",
    src: `
export class Counter {
  n: number = 0;
  bump(): void { this.n += 1; }
}
function observe(c: Counter): number { return c.n; }
export function f(): number {
  const c = new Counter();
  const seen = observe(c);
  c.bump();
  return seen;
}
`,
  },
  {
    name: "instanceof on a class instance still teaches runtime type tests",
    gate: "NS1041",
    src: `
export class Counter { n: number = 0; }
export function f(v: Counter | null): number {
  if (v instanceof Counter) return 1;
  return 0;
}
`,
  },
  {
    name: "class instances in the Model tree teach the record form (flagged follow-up)",
    gate: "NS1056",
    src: `
export class Task {
  id: number;
  constructor(id: number) { this.id = id; }
}
export interface Model { readonly tasks: readonly Task[]; }
export function initialModel(): Model { return { tasks: [] }; }
`,
  },
  {
    name: "records built FROM class data keep the Model record-shaped",
    src: `
export class Builder {
  count: number = 0;
  bump(): void { this.count += 1; }
}
export interface Model { readonly count: number; }
export type Msg =
  | { readonly kind: "recount"; readonly upTo: number }
  | { readonly kind: "noop" };
export function initialModel(): Model { return { count: 0 }; }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "recount": {
      const b = new Builder();
      for (let i = 0; i < msg.upTo; i++) b.bump();
      return { count: b.count };
    }
    case "noop": return model;
  }
}
`,
  },
];

const exceptionCases: Case[] = [
  {
    name: "heterogeneous throws merge into the thrown union; catch narrows by kind",
    src: `
export interface ParseError { readonly kind: "parse"; readonly at: number; }
export interface IoError { readonly kind: "io"; readonly code: number; readonly hard: boolean; }
function go(n: number): number {
  if (n < 0) throw { kind: "parse", at: n } as ParseError;
  if (n > 100) throw { kind: "io", code: n, hard: n > 1000 } as IoError;
  return n * 2;
}
export function f(n: number): number {
  try { return go(n); } catch (e) {
    if (e.kind === "parse") return e.at - 1000;
    if (e.kind === "io") return e.hard ? -e.code : e.code;
    return -1;
  }
}
`,
  },
  {
    name: "a declared union whose arms equal the thrown set carries the slot (as stays legal)",
    src: `
export interface ParseError { readonly kind: "parse"; readonly at: number; }
export type AppError = { readonly kind: "parse"; readonly at: number } | { readonly kind: "empty" };
function go(n: number): number {
  if (n < 0) throw { kind: "parse", at: n } as ParseError;
  if (n === 0) throw { kind: "empty" } as AppError;
  return n;
}
export function f(n: number): number {
  try { return go(n); } catch (e) {
    const err = e as AppError;
    if (err.kind === "parse") return err.at;
    return -2;
  }
}
`,
  },
  {
    name: "a member union's value rethrows through the thrown union (re-tagged arm by arm)",
    src: `
export type Low = { readonly kind: "under"; readonly by: number } | { readonly kind: "zero" };
export interface High { readonly kind: "over"; readonly by: number; readonly hard: boolean; }
function check(n: number): number {
  if (n < 0) { const e: Low = n === -1 ? { kind: "zero" } : { kind: "under", by: n }; throw e; }
  if (n > 10) throw { kind: "over", by: n - 10, hard: n > 100 } as High;
  return n;
}
export function f(n: number): number {
  try { return check(n); } catch (e) {
    switch (e.kind) {
      case "under": return e.by - 100;
      case "zero": return -1;
      case "over": return e.hard ? e.by + 1000 : e.by;
      default: return -999;
    }
  }
}
`,
  },
  {
    name: "single-shape catch reads its fields directly, no as ceremony",
    src: `
export interface Bad { readonly kind: "bad"; readonly at: number; }
function go(n: number): number { if (n < 0) throw { kind: "bad", at: n } as Bad; return n; }
export function f(n: number): number {
  try { return go(n); } catch (e) { return e.at; }
}
`,
  },
  {
    name: "NS1057: a shape without a kind tag cannot join a heterogeneous thrown set",
    gate: "NS1057",
    src: `
export interface ParseError { readonly kind: "parse"; readonly at: number; }
export function f(n: number): number {
  if (n < 0) throw { kind: "parse", at: n } as ParseError;
  if (n > 100) throw n;
  return n;
}
`,
  },
  {
    name: "NS1057: two thrown shapes sharing a kind with different payloads are ambiguous",
    gate: "NS1057",
    src: `
export interface AErr { readonly kind: "boom"; readonly at: number; }
export interface BErr { readonly kind: "boom"; readonly code: boolean; }
export function f(n: number): number {
  if (n < 0) throw { kind: "boom", at: n } as AErr;
  if (n > 100) throw { kind: "boom", code: true } as BErr;
  return n;
}
`,
  },
  {
    name: "NS1057: asserting one member shape in a heterogeneous core is taught toward kind tests",
    gate: "NS1057",
    src: `
export interface ParseError { readonly kind: "parse"; readonly at: number; }
export interface IoError { readonly kind: "io"; readonly code: number; }
function go(n: number): number {
  if (n < 0) throw { kind: "parse", at: n } as ParseError;
  if (n > 100) throw { kind: "io", code: n } as IoError;
  return n;
}
export function f(n: number): number {
  try { return go(n); } catch (e) {
    const err = e as ParseError;
    return err.at;
  }
}
`,
  },
  {
    name: "NS1057: the catch binding escaping into a call is taught toward narrowing",
    gate: "NS1057",
    src: `
export interface Bad { readonly kind: "bad"; readonly at: number; }
function width(x: Bad): number { return x.at; }
function go(n: number): number { if (n < 0) throw { kind: "bad", at: n } as Bad; return n; }
export function f(n: number): number {
  try { return go(n); } catch (e) { return width(e); }
}
`,
  },
  {
    name: "try/catch/finally: parser throws a tagged error, caller narrows it",
    src: `
export type ParseError =
  | { readonly kind: "bad_digit"; readonly at: number }
  | { readonly kind: "empty" };
function parseDigits(bytes: Uint8Array): number {
  if (bytes.length === 0) throw { kind: "empty" } as ParseError;
  let n = 0;
  for (let i = 0; i < bytes.length; i++) {
    const b = bytes[i];
    if (b < 48 || b > 57) throw { kind: "bad_digit", at: i } as ParseError;
    n = n * 10 + (b - 48);
  }
  return n;
}
export function safeParse(bytes: Uint8Array): number {
  try {
    return parseDigits(bytes);
  } catch (e) {
    const err = e as ParseError;
    if (err.kind === "bad_digit") return -err.at - 1;
    return -1000;
  }
}
`,
  },
  {
    name: "throw inside a map callback unwinds out of the lowered loop",
    src: `
export type Bad = { readonly kind: "bad"; readonly at: number } | { readonly kind: "none" };
export function firstBad(xs: readonly number[]): number {
  try {
    const doubled = xs.map((x, i) => {
      if (x < 0) throw { kind: "bad", at: i } as Bad;
      return x * 2;
    });
    return doubled.length;
  } catch (e) {
    const err = e as Bad;
    return err.kind === "bad" ? -err.at - 1 : -99;
  }
}
`,
  },
  {
    name: "rethrow and nested try; finally runs on both paths",
    src: `
export type Fail = { readonly kind: "inner"; readonly n: number } | { readonly kind: "outer"; readonly n: number };
export function f(x: number): number {
  let log = 0;
  try {
    try {
      if (x > 0) throw { kind: "inner", n: x } as Fail;
      log += 1;
    } catch (e) {
      const err = e as Fail;
      if (err.kind === "inner") {
        if (err.n > 5) throw { kind: "outer", n: err.n } as Fail;
      }
      throw e;
    } finally {
      log += 10;
    }
  } catch (e) {
    const err = e as Fail;
    const tag = err.kind === "outer" ? 2 : 1;
    return log * 100 + tag;
  }
  return log;
}
`,
  },
  {
    name: "an uncaught throw at an exported boundary compiles to a defined panic",
    src: `
export type Boom = { readonly kind: "boom" } | { readonly kind: "other" };
export function mustBePositive(n: number): number {
  if (n <= 0) throw { kind: "boom" } as Boom;
  return n;
}
`,
  },
  {
    name: "throw mid-mutation of an owned array: prior pushes persist into the catch",
    src: `
export type Halt = { readonly kind: "halt" } | { readonly kind: "never" };
export function f(stop: number): number {
  const xs: number[] = [];
  try {
    xs.push(1);
    xs.push(2);
    if (xs.length >= stop) throw { kind: "halt" } as Halt;
    xs.push(3);
  } catch {
    return xs.length;
  }
  return xs.length * 10;
}
`,
  },
  {
    name: "class methods can throw; the constructor can too",
    src: `
export type RangeError2 = { readonly kind: "range"; readonly v: number } | { readonly kind: "none" };
export class Gauge {
  v: number;
  constructor(v: number) {
    if (v < 0) throw { kind: "range", v } as RangeError2;
    this.v = v;
  }
  add(d: number): void {
    if (this.v + d > 100) throw { kind: "range", v: this.v + d } as RangeError2;
    this.v += d;
  }
}
export function f(start: number, d: number): number {
  try {
    const g = new Gauge(start);
    g.add(d);
    return g.v;
  } catch (e) {
    const err = e as RangeError2;
    return err.kind === "range" ? -err.v : -1;
  }
}
`,
  },
  {
    name: "two different thrown shapes teach the one-shape rule",
    gate: "NS1057",
    src: `
export function f(x: number): number {
  if (x < 0) throw 1;
  if (x > 10) throw true;
  return x;
}
`,
  },
  {
    name: "a directly-used catch binding teaches the single-narrowing rule",
    gate: "NS1057",
    src: `
export function f(): number {
  try { return 1; } catch (e) { return e === null ? 0 : 2; }
}
`,
  },
  {
    name: "`throw new Error` teaches the subset-value rule",
    gate: "NS1057",
    src: `export function f(): number { throw new Error("x"); }`,
  },
  {
    name: "`return` inside finally teaches no-unsafe-finally",
    gate: "NS1058",
    src: `export function f(): number { try { return 1; } finally { return 0; } }`,
  },
];

// Shapes that first failed in RELEASE-mode app builds (wave-2 eval trials):
// Debug-lane-only compilation let them escape, which is why the compile test
// below runs the driver in both Debug and ReleaseFast.
const releaseModeCases: Case[] = [
  {
    name: "annotated enum local from a runtime ternary (pomodoro phase flip)",
    src: `
export type Phase = "focus" | "rest";
export interface Model { readonly phase: Phase; readonly remaining: number; readonly completed: number; }
export type Msg = { readonly kind: "tick" } | { readonly kind: "reset" };
export function initialModel(): Model { return { phase: "focus", remaining: 1500, completed: 0 }; }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "tick": {
      const nextPhase: Phase = model.phase === "focus" ? "rest" : "focus";
      const nextDuration = nextPhase === "focus" ? 1500 : 300;
      const nextCompleted = model.phase === "focus" ? model.completed + 1 : model.completed;
      return { phase: nextPhase, remaining: nextDuration, completed: nextCompleted };
    }
    case "reset": return { ...model, phase: "focus" };
  }
}
`,
  },
  {
    name: "reassigned enum local anchors its enum type",
    src: `
export type Phase = "focus" | "rest";
export function flip(count: number): Phase {
  let phase: Phase = "focus";
  if (count > 1) phase = "rest";
  return phase;
}
`,
  },
  {
    name: "bytes parameter written through set() and indexed stores (notes serializer)",
    src: `
function writeChunk(out: Uint8Array, offset: number, chunk: Uint8Array): number {
  out.set(chunk, offset);
  out[offset] = 65;
  return offset + chunk.length;
}
export function pack(chunks: readonly Uint8Array[]): Uint8Array {
  let total = 0;
  for (const c of chunks) total += c.length;
  const out = new Uint8Array(total);
  let offset = 0;
  for (const c of chunks) offset = writeChunk(out, offset, c);
  return out;
}
`,
  },
];

// The byte-text method surface (R11t): the everyday string methods on core
// bytes, exercised through the type boundaries the per-method matrix
// (grammar_matrix.test.ts) does not cover — model integration, aliases,
// optional receivers, result classes feeding integer flows, split
// ownership — plus the taught edges that need FLOW (not literal) fixtures.
const textMethodCases: Case[] = [
  {
    name: "case-mapped search filter through a Bytes alias in the update path",
    src: `
import { asciiBytes } from "@native-sdk/core";
export type Bytes = Uint8Array;
export interface Item { readonly id: number; readonly title: Bytes; }
export interface Model { readonly items: readonly Item[]; readonly query: Bytes; }
export type Msg =
  | { readonly kind: "set_query"; readonly text: Bytes }
  | { readonly kind: "clear" };
export function initialModel(): Model {
  return { items: [{ id: 1, title: asciiBytes("Alpha") }], query: new Uint8Array(0) };
}
export function visible(model: Model): readonly Item[] {
  const q = model.query.toLowerCase();
  return model.items.filter((it) => it.title.toLowerCase().includes(q));
}
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "set_query": return { ...model, query: msg.text.trim() };
    case "clear": return { ...model, query: new Uint8Array(0) };
  }
}
`,
  },
  {
    name: "indexOf result guards a subarray bound (integer-classed offset)",
    src: `
export function afterColon(line: Uint8Array, sep: Uint8Array): Uint8Array {
  const at = line.indexOf(sep);
  if (at === -1) return line;
  return line.subarray(at + sep.length);
}
export function tail(line: Uint8Array): number {
  const last = line.lastIndexOf(32);
  return last === -1 ? line.length : last;
}
`,
  },
  {
    name: "split parts are locally owned (push after split) and iterate",
    src: `
import { asciiBytes } from "@native-sdk/core";
export function fields(row: Uint8Array): number {
  const parts = row.split(asciiBytes(","));
  parts.push(asciiBytes("total"));
  let bytes = 0;
  for (const p of parts) bytes += p.trim().length;
  return bytes + parts.length;
}
`,
  },
  {
    name: "at() folds with ?? and tests === undefined (the one-empty rule)",
    src: `
export function lastByte(s: Uint8Array): number {
  const b = s.at(-1);
  if (b === undefined) return -1;
  return b;
}
export function firstOrZero(s: Uint8Array): number {
  return s.at(0) ?? 0;
}
`,
  },
  {
    name: "optional-chained text methods over a nullable receiver",
    src: `
export interface Model { readonly note: Uint8Array | null; }
export function noteLen(model: Model): number {
  return (model.note?.trim() ?? new Uint8Array(0)).length;
}
export function shout(model: Model): Uint8Array {
  return model.note?.toUpperCase() ?? new Uint8Array(0);
}
`,
  },
  {
    name: "pad targets and repeat counts ride integer flows into the helpers",
    src: `
import { asciiBytes } from "@native-sdk/core";
export function gauge(width: number, used: number): Uint8Array {
  const bar = asciiBytes("#").repeat(used);
  return bar.padEnd(width, asciiBytes("."));
}
export function label(name: Uint8Array, col: number): Uint8Array {
  return name.padStart(col);
}
`,
  },
  {
    name: "dispatch by argument type: byte membership vs substring on one receiver",
    src: `
export function hasBoth(s: Uint8Array, sub: Uint8Array, byte: number): boolean {
  return s.includes(sub) && s.includes(byte);
}
`,
  },
  {
    name: "repeat count fed by a float FLOW (not a literal) is the taught slot conflict",
    gate: "NS1016",
    src: `
export function f(s: Uint8Array, x: number): Uint8Array {
  const n = x / 2;
  return s.repeat(n);
}
`,
  },
  {
    name: "padStart target fed by a fractional literal is the taught slot conflict",
    gate: "NS1016",
    src: `
export function f(s: Uint8Array): Uint8Array {
  return s.padStart(4.5);
}
`,
  },
  {
    name: "split parts cannot be pushed after the array escapes",
    gate: "NS1051",
    src: `
import { asciiBytes } from "@native-sdk/core";
function count(xs: readonly Uint8Array[]): number { return xs.length; }
export function f(row: Uint8Array, sink: Uint8Array[][]): number {
  const parts = row.split(asciiBytes(","));
  sink.push(parts);
  parts.push(asciiBytes("late"));
  return count(parts);
}
`,
  },
];

// Ternaries whose arms lower STATEMENTS (spread object literals build their
// arena copy line by line). Those statements must scope to the branch that
// actually runs: hoisting them above the conditional both evaluates the
// untaken arm and reads a null-narrowing capture before it binds ("use of
// undeclared identifier"), and a skipped narrow path leaves optional reads
// un-unwrapped in the arm ("expected type 'f64', found '?f64'"). Every
// position a value ternary can sit in is pinned: declaration initializer,
// return, argument, object field, plus the orelse fusion and the
// switch-payload shapes that route the same lowering.
const ternarySpreadArmCases: Case[] = [
  {
    name: "null-narrowed ternary with a spread arm in return position",
    src: `
export type QuoteState = "idle" | "ok" | "failed";
export interface Quote { readonly id: number; readonly state: QuoteState; readonly price: number; }
export function apply(q: Quote, parsed: number | null): Quote {
  return parsed === null ? q : { ...q, state: "ok", price: parsed };
}
`,
  },
  {
    name: "null-narrowed ternary with a spread arm as a declaration initializer",
    src: `
export type QuoteState = "idle" | "ok" | "failed";
export interface Quote { readonly id: number; readonly state: QuoteState; readonly price: number; }
export function apply(q: Quote, parsed: number | null): Quote {
  const updated: Quote = parsed === null ? q : { ...q, state: "ok", price: parsed };
  return updated;
}
`,
  },
  {
    name: "hit-test polarity (!== null) with spread arms on BOTH branches",
    src: `
export type QuoteState = "idle" | "ok" | "failed";
export interface Quote { readonly id: number; readonly state: QuoteState; readonly price: number; }
export function apply(q: Quote, parsed: number | null): Quote {
  return parsed !== null ? { ...q, state: "ok", price: parsed } : { ...q, state: "failed" };
}
`,
  },
  {
    name: "nested ternary with spread arms (arm-within-arm) as an annotated declaration",
    src: `
export type QuoteState = "idle" | "ok" | "failed";
export interface Quote { readonly id: number; readonly state: QuoteState; readonly price: number; }
export function apply(q: Quote, parsed: number | null): Quote {
  const updated: Quote = parsed === null
    ? (q.state === "ok" ? q : { ...q, state: "failed" })
    : { ...q, state: "ok", price: parsed };
  return updated;
}
`,
  },
  {
    name: "spread-arm ternary in argument position",
    src: `
export type QuoteState = "idle" | "ok" | "failed";
export interface Quote { readonly id: number; readonly state: QuoteState; readonly price: number; }
export function cost(q: Quote): number { return q.price; }
export function probe(q: Quote, parsed: number | null): number {
  return cost(parsed === null ? q : { ...q, state: "ok", price: parsed });
}
`,
  },
  {
    name: "spread-arm ternary as an object-literal field value",
    src: `
export type QuoteState = "idle" | "ok" | "failed";
export interface Quote { readonly id: number; readonly state: QuoteState; readonly price: number; }
export interface Model { readonly quote: Quote; readonly n: number; }
export function apply(model: Model, parsed: number | null): Model {
  return { ...model, quote: parsed === null ? model.quote : { ...model.quote, state: "ok", price: parsed } };
}
`,
  },
  {
    name: "orelse-fusion shape whose miss arm is a spread literal",
    src: `
export type QuoteState = "idle" | "ok" | "failed";
export interface Quote { readonly id: number; readonly state: QuoteState; readonly price: number; }
export function pick(q: Quote | null, fallback: Quote): Quote {
  return q === null ? { ...fallback, state: "idle" } : q;
}
`,
  },
  {
    // The annotated declaration above supplies an expected type that masks
    // the inference path: with NO annotation the ternary's own computed type
    // is the local's type, and computing it from the raw optional arm types
    // the local `?Quote` — its first non-optional use then fails Zig
    // compilation ("expected type 'Quote', found '?Quote'"). The condition's
    // null test narrows the arm that reuses the tested value, so the local
    // must value as the non-optional Quote, exactly as tsc types it.
    name: "INFERRED local from a miss-test spread-arm ternary values non-optional",
    src: `
export type QuoteState = "idle" | "ok" | "failed";
export interface Quote { readonly id: number; readonly state: QuoteState; readonly price: number; }
export function pick(q: Quote | null, fallback: Quote): Quote {
  const picked = q === null ? { ...fallback, price: 0 } : q;
  return picked;
}
`,
  },
  {
    name: "INFERRED local, hit-test polarity (q !== null ? q : spread) values non-optional",
    src: `
export type QuoteState = "idle" | "ok" | "failed";
export interface Quote { readonly id: number; readonly state: QuoteState; readonly price: number; }
export function pick(q: Quote | null, fallback: Quote): Quote {
  const picked = q !== null ? q : { ...fallback, price: 0 };
  return picked;
}
`,
  },
  {
    name: "TEA reducer: spread-arm ternary reads a switch payload through a local",
    src: `
export type QuoteState = "idle" | "ok" | "failed";
export interface Quote { readonly id: number; readonly state: QuoteState; readonly price: number; }
export interface Model { readonly quote: Quote; }
export type Msg = { readonly kind: "got"; readonly parsed: number | null } | { readonly kind: "noop" };
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "got": {
      const parsed = msg.parsed;
      const q = model.quote;
      const updated: Quote = parsed === null
        ? (q.state === "ok" ? q : { ...q, state: "failed" })
        : { ...q, state: "ok", price: parsed };
      return { ...model, quote: updated };
    }
    case "noop": {
      const q = model.quote;
      const updated: Quote = q.state === "ok" ? q : { ...q, state: "failed" };
      return { ...model, quote: updated };
    }
  }
}
`,
  },
  {
    name: "TEA reducer: spread-arm ternary reads the optional switch payload directly",
    src: `
export type QuoteState = "idle" | "ok" | "failed";
export interface Quote { readonly id: number; readonly state: QuoteState; readonly price: number; }
export interface Model { readonly quote: Quote; }
export type Msg = { readonly kind: "got"; readonly parsed: number | null } | { readonly kind: "noop" };
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "got":
      return { ...model, quote: msg.parsed === null ? model.quote : { ...model.quote, state: "ok", price: msg.parsed } };
    case "noop":
      return model;
  }
}
`,
  },
  {
    name: "optional switch payload stays optional through its capture (guarded use compiles)",
    src: `
export type QuoteState = "idle" | "ok" | "failed";
export interface Quote { readonly id: number; readonly state: QuoteState; readonly price: number; }
export interface Model { readonly quote: Quote; }
export type Msg = { readonly kind: "got"; readonly parsed: number | null } | { readonly kind: "noop" };
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "got": {
      const parsed = msg.parsed;
      if (parsed !== null) {
        return { ...model, quote: { ...model.quote, state: "ok", price: parsed } };
      }
      return model;
    }
    case "noop": return model;
  }
}
`,
  },
  {
    // A parenthesized arm is still the tested target: `(q)` must value the
    // inferred local as the non-optional Quote exactly like the bare `q`
    // spelling — parens defeating the match typed the local `?Quote` and
    // its field reads failed to compile.
    name: "INFERRED local from a spread-arm ternary whose narrowed arm is parenthesized",
    src: `
export type QuoteState = "idle" | "ok" | "failed";
export interface Quote { readonly id: number; readonly state: QuoteState; readonly price: number; }
export function pick(q: Quote | null, fallback: Quote): number {
  const picked = q === null ? { ...fallback, price: 0 } : (q);
  return picked.price + picked.id;
}
`,
  },
  {
    // The statement-free flavor routes through the orelse fusion instead of
    // the temp lowering; the parenthesized arm must fuse the same way.
    name: "orelse fusion still fires when the narrowed ternary arm is parenthesized",
    src: `
export type QuoteState = "idle" | "ok" | "failed";
export interface Quote { readonly id: number; readonly state: QuoteState; readonly price: number; }
export function pick(q: Quote | null, fallback: Quote): number {
  const picked = q === null ? fallback : (q);
  return picked.price + picked.id;
}
`,
  },
  {
    // Doubly parenthesized: paren stripping must recurse, not peel one layer.
    name: "a doubly-parenthesized narrowed ternary arm still matches the tested target",
    src: `
export type QuoteState = "idle" | "ok" | "failed";
export interface Quote { readonly id: number; readonly state: QuoteState; readonly price: number; }
export function pick(q: Quote | null, fallback: Quote): number {
  const picked = q === null ? { ...fallback, price: 0 } : ((q));
  return picked.price + picked.id;
}
`,
  },
  {
    // The tested side of the condition can carry the parens too.
    name: "a parenthesized tested target still narrows its ternary arm",
    src: `
export type QuoteState = "idle" | "ok" | "failed";
export interface Quote { readonly id: number; readonly state: QuoteState; readonly price: number; }
export function pick(q: Quote | null, fallback: Quote): number {
  const picked = (q) === null ? { ...fallback, price: 0 } : q;
  return picked.price + picked.id;
}
`,
  },
  {
    // A parenthesized null ARM is still a null arm: `(null)` must make the
    // ternary's value optional exactly like the bare `null` spelling.
    // Reading it as a non-null arm typed the local non-optional, the later
    // guard's unwrap was skipped, and the field read hit the raw optional.
    name: "a parenthesized null arm still values the ternary optional",
    src: `
export interface P { readonly v: number; }
export function f(q: P | null): number {
  const picked = q === null ? (null) : q;
  if (picked === null) return -1;
  return picked.v;
}
`,
  },
  {
    name: "a parenthesized null arm on the OTHER side values the ternary optional too",
    src: `
export interface P { readonly v: number; }
export function f(q: P | null): number {
  const picked = q !== null ? q : (null);
  if (picked === null) return -1;
  return picked.v;
}
`,
  },
  {
    // Doubly wrapped: the null-literal check must recurse through every
    // paren layer, not peel one.
    name: "a doubly-parenthesized null arm still values the ternary optional",
    src: `
export interface P { readonly v: number; }
export function f(q: P | null): number {
  const picked = q === null ? ((null)) : q;
  if (picked === null) return -1;
  return picked.v;
}
`,
  },
  {
    // Emission erases non-null assertions exactly like parens, so the
    // arm-identity comparison must see through them: `q!` IS the tested
    // `q`, the ternary values non-optional, and the spread arm's temp
    // types the struct — not `?Quote` with a field read Zig rejects.
    name: "a non-null-asserted narrowed ternary arm still matches the tested target",
    src: `
export interface Quote { readonly price: number; readonly qty: number; }
export function pick(q: Quote | null, fallback: Quote): number {
  const picked = q !== null ? q! : { ...fallback, price: 0 };
  return picked.price + picked.qty;
}
`,
  },
  {
    // The `as` spelling of the same wrapper erasure.
    name: "an as-cast narrowed ternary arm still matches the tested target",
    src: `
export interface Quote { readonly price: number; readonly qty: number; }
export function pick(q: Quote | null, fallback: Quote): number {
  const picked = q !== null ? (q as Quote) : { ...fallback, price: 0 };
  return picked.price + picked.qty;
}
`,
  },
  {
    // The `satisfies` spelling too — all three wrappers canonicalize in
    // the narrowing key itself, so every consumer agrees at once.
    name: "a satisfies-wrapped narrowed ternary arm still matches the tested target",
    src: `
export interface Quote { readonly price: number; readonly qty: number; }
export function pick(q: Quote | null, fallback: Quote): number {
  const picked = q !== null ? (q satisfies Quote) : { ...fallback, price: 0 };
  return picked.price + picked.qty;
}
`,
  },
  {
    // A wrapper on the TESTED side narrows too: tsc sees through `q!` when
    // narrowing `q`, so the capture form must fire exactly as for the bare
    // spelling (the erased assertion emits the same `q != null` test).
    name: "a non-null-asserted tested target still narrows its ternary arm",
    src: `
export interface Quote { readonly price: number; readonly qty: number; }
export function pick(q: Quote | null, fallback: Quote): number {
  const picked = q! !== null ? q! : { ...fallback, price: 0 };
  return picked.price + picked.qty;
}
`,
  },
  {
    // The orelse fold recognizes the wrapped arm as the tested value:
    // `q === null ? A : q!` is `q orelse A`, never a lowered temp.
    name: "a non-null-asserted miss-test arm still folds to orelse",
    src: `
export function fold(q: number | null): number {
  return q === null ? -1 : q!;
}
`,
  },
  {
    // The statement-level orelse fusion sees through the wrapper on the
    // guard's tested side too, and matches by declaration identity (tsc
    // itself narrows through `!` — it is a reference candidate — so the
    // follow-up read is tsc-clean).
    name: "a non-null-asserted early-exit guard still fuses to orelse",
    src: `
export interface Quote { readonly price: number; readonly qty: number; }
export function first(qs: readonly Quote[]): number {
  const q = qs.find((x) => x.qty > 0);
  if (q! === undefined) return -1;
  return q.price;
}
`,
  },
  {
    // tsc does NOT narrow through `as` in tested position, so the
    // follow-up read carries its own assertion — and the canonicalized
    // key routes it onto the fusion's capture all the same.
    name: "an as-wrapped guard with an asserted follow-up read still fuses to orelse",
    src: `
export interface Quote { readonly price: number; readonly qty: number; }
export function first(qs: readonly Quote[]): number {
  const q = qs.find((x) => x.qty > 0);
  if ((q as Quote | undefined) === undefined) return -1;
  return q!.price;
}
`,
  },
  {
    // The global `undefined` in arm position is an EMPTY exactly like the
    // null keyword — its internal type is void, so a ZType-based arm check
    // reads it as a non-empty value, types the local non-optional, skips
    // the later guard's unwrap, and the field read hits the raw optional.
    name: "an undefined alternate arm still values the ternary optional",
    src: `
export interface P { readonly v: number; }
export function pick(q: P | null): number {
  const picked = q === null ? undefined : q;
  if (picked === undefined) return 0;
  return picked.v;
}
`,
  },
  {
    name: "an undefined arm on the OTHER side values the ternary optional too",
    src: `
export interface P { readonly v: number; }
export function pick(q: P | null): number {
  const picked = q !== null ? q : undefined;
  if (picked === undefined) return 0;
  return picked.v;
}
`,
  },
  {
    // Wrapper canonicalization composes with the undefined-empty decision:
    // an `as`-wrapped undefined arm paired with an `as`-wrapped tested
    // value keeps the optional and fuses the guard exactly like the bare
    // spelling.
    name: "as-wrapped undefined and value arms still value the ternary optional",
    src: `
export interface P { readonly v: number; }
export function pick(q: P | null): number {
  const picked = q === null ? (undefined as P | undefined) : (q as P);
  if (picked === undefined) return 0;
  return picked.v;
}
`,
  },
  {
    // The doubly-parenthesized undefined spelling, symmetric with the
    // `((null))` case above: the empty check recurses through every layer.
    name: "a doubly-parenthesized undefined arm still values the ternary optional",
    src: `
export interface P { readonly v: number; }
export function pick(q: P | null): number {
  const picked = q === null ? ((undefined)) : q;
  if (picked === undefined) return 0;
  return picked.v;
}
`,
  },
  {
    // Ternary arms are ALTERNATIVES: probing/lowering one arm must not
    // apply its flow effects to the sibling. The map callback here assigns
    // the outer narrowed local — killing that narrow in shared flow state
    // stripped the ELSE arm of its unwrap, and the sibling read the raw
    // optional (invalid Zig). Each arm emits from the entry state; the
    // kill joins only after both arms.
    name: "a callback assignment in one ternary arm does not strip the sibling arm's narrow",
    src: `
export interface P { readonly v: number; }
export function f(xs: number[], flag: boolean, seed: P | null): number {
  let q: P | null = seed;
  if (q === null) return 0;
  const r = flag ? xs.map((x) => { q = null; return x * 2; }).length : q.v;
  return r;
}
`,
  },
  {
    // The capture-lowered (empty-test) ternary flavor of the same law: the
    // narrowed arm's callback assigns a DIFFERENT outer narrowed local;
    // the other arm still reads that local through its unwrap.
    name: "a callback assignment in the narrowed arm does not strip the other arm's narrow",
    src: `
export interface P { readonly v: number; }
export function g(xs: number[], q: P | null, seed: P | null): number {
  let p: P | null = seed;
  if (p === null) return 0;
  const r = q !== null ? xs.map((x) => { p = null; return x + q.v; }).length : p.v;
  return r;
}
`,
  },
  {
    // Capture gates compare declaration-QUALIFIED keys, never source text:
    // the map callback's parameter shadows the tested `box`, so its
    // `box.q` is NOT a read of the outer target — a text match would bind
    // a capture the declaration-keyed substitution never rewrites, a Zig
    // unused-capture error. The arm reads only the shadow: no capture.
    name: "a shadowed property spelling in a ternary arm binds no capture",
    src: `
export interface B { readonly q: number | null; }
export function g(box: B, xs: readonly B[]): number {
  return box.q === null ? 0 : xs.map((box) => box.q === null ? 0 : 1).length;
}
`,
  },
  {
    // The dual: the arm reads the OUTER target too, so the capture binds
    // and the outer read rewrites onto it while the shadowed read keeps
    // its own declaration.
    name: "a ternary arm reading both the outer property and a shadow binds a used capture",
    src: `
export interface B { readonly q: number | null; }
export function g(box: B, xs: readonly B[]): number {
  return box.q === null ? 0 : box.q + xs.map((box) => box.q === null ? 0 : 1).length;
}
`,
  },
  {
    // The if-statement capture gate (branchReadsTarget) under the same
    // shadowing: the then-branch reads only the shadow, so the plain
    // comparison form emits, capture-free.
    name: "a shadowed property spelling in a guarded branch binds no capture",
    src: `
export interface B { readonly q: number | null; }
export function g(box: B, xs: readonly B[]): number {
  if (box.q !== null) {
    return xs.map((box) => box.q === null ? 0 : 1).length;
  }
  return 0;
}
`,
  },
  {
    // The early-exit fusion gate (followingReadsTarget) under the same
    // shadowing: nothing after the guard reads the outer target, so no
    // orelse capture binds.
    name: "a shadowed property spelling after an exit guard binds no orelse capture",
    src: `
export interface B { readonly q: number | null; }
export function g(box: B, xs: readonly B[]): number {
  if (box.q === null) return 0;
  return xs.map((box) => box.q === null ? 0 : 1).length;
}
`,
  },
  {
    // The switch payload-use gate under a same-named field: `box.v` is
    // not a read of the payload field `v`, so no payload capture binds
    // for the arm.
    name: "a same-named field of another value binds no switch payload capture",
    src: `
export type Msg = { readonly kind: "set"; readonly v: number } | { readonly kind: "clear" };
export interface Box { readonly v: number; }
export function upd(m: Msg, box: Box): number {
  switch (m.kind) {
    case "set": return box.v + 1;
    case "clear": return 0;
  }
}
`,
  },
];

// Plain lexical blocks are NOT merge boundaries: tsc's narrowing is
// flow-based, so a guard inside a fall-through `{ ... }` narrows the
// statements AFTER the block too (and a kill inside it stays dead there).
// The emitter flattens such blocks into the enclosing list, which also
// keeps any unwrap capture lowered inside the block in scope for the
// post-block reads that rely on it. Merge contexts (if/else arms, loop
// bodies, labeled blocks) still bracket: narrows established inside them
// die at their exit.
const lexicalBlockFlowCases: Case[] = [
  {
    // The narrowing must survive the block's end: restoring entry state at
    // the block exit re-optionalized `p` and the post-block read failed to
    // compile.
    name: "a guard inside a plain block narrows the statements after the block",
    src: `
export interface P { readonly v: number; }
export function f(p: P | null): number {
  { if (p === null) return -1; }
  return p.v;
}
`,
  },
  {
    // The Zig-scope half: the guard's unwrap capture is lowered INSIDE the
    // TS block, and the post-block reads go through it — flattening is what
    // keeps that capture in the same Zig scope (the compile is the
    // assertion).
    name: "a narrow established in a block is readable after it through its capture",
    src: `
export interface P { readonly v: number; }
export function f(q: P | null): number {
  {
    if (q === null) return -1;
    if (q.v < 0) return -2;
  }
  return q.v + 1;
}
`,
  },
  {
    // Containment control: a block inside an if ARM flows through to the
    // arm's scope, but the arm itself still brackets — the post-arm
    // re-check must read the LIVE optional, not a leaked capture.
    name: "a block inside an if arm flows through to the arm; the arm still brackets",
    src: `
export interface P { readonly v: number; }
export function f(p: P | null, c: boolean): number {
  if (c) {
    { if (p === null) return -1; }
    return p.v;
  }
  if (p === null) return 0;
  return p.v + 1;
}
`,
  },
  {
    name: "nested plain blocks flow through both boundaries",
    src: `
export interface P { readonly v: number; }
export function f(p: P | null): number {
  {
    {
      if (p === null) return -1;
    }
    if (p.v === 7) return 7;
  }
  return p.v;
}
`,
  },
  {
    // Kills flow through a plain block exactly like narrows do: the killing
    // assignment sits inside the block and the post-block re-check must
    // read the live optional.
    name: "a kill inside a plain block stays dead after the block",
    src: `
export function f(q: number | null, flag: boolean): number {
  let p: number | null = q;
  if (p === null) return -1;
  {
    if (flag) { p = null; }
  }
  if (p === null) return 0;
  return p;
}
`,
  },
  {
    // Flattening must not collide block-local declarations with later
    // same-named ones: name uniquing is function-wide, so the second `a`
    // takes a fresh spelling.
    name: "a block-local const does not collide with a later same-named local",
    src: `
export function f(flag: boolean): number {
  {
    const a = 1;
    if (flag) return a;
  }
  const a = 2;
  return a;
}
`,
  },
  {
    // A block-scoped alias's guard fuses inside the flattened region; the
    // outer value stays optional past the block, so the post-block re-check
    // still reads the live slot.
    name: "a block-local alias guard leaves the outer optional unnarrowed",
    src: `
export interface P { readonly v: number; }
export function f(q: P | null): number {
  {
    const inner = q;
    if (inner === null) return -1;
    if (inner.v === 7) return 7;
  }
  if (q === null) return 0;
  return q.v;
}
`,
  },
];

// Flow-exit guard narrowing: tsc narrows after ANY statement that never
// falls through — return, break, continue, throw — so a loop's early-exit
// guard must narrow the remainder of the loop body exactly like an early
// return narrows the rest of the function. The dogfooding report behind
// these: `if (r === null) break;` inside a parse loop emitted Zig field
// access on the still-optional `r`. The scope cases pin the other half:
// the narrowing ENDS with the block the guard sits in (a break path may
// bypass it), so reads after the loop or branch see the unnarrowed value.
const exitGuardNarrowingCases: Case[] = [
  {
    name: "break guard narrows an optional for the rest of the loop body (the report's parse loop)",
    src: `
export interface NumResult { readonly value: number; readonly next: number; }
export function parseNumber(body: Uint8Array, i: number): NumResult | null {
  if (i >= body.length) return null;
  return { value: body[i], next: i + 1 };
}
export function collect(body: Uint8Array): readonly number[] {
  const out: number[] = [];
  let i = 0;
  while (i < body.length) {
    const r = parseNumber(body, i);
    if (r === null) break;
    out.push(r.value);
    i = r.next;
  }
  return out;
}
`,
  },
  {
    name: "continue guard narrows an optional for the rest of the iteration",
    src: `
export interface Hit { readonly value: number; }
export function lookup(i: number): Hit | null {
  if (i % 2 === 0) return null;
  return { value: i * 3 };
}
export function oddTotal(n: number): number {
  let sum = 0;
  for (let i = 0; i < n; i += 1) {
    const r = lookup(i);
    if (r === null) continue;
    sum += r.value;
  }
  return sum;
}
`,
  },
  {
    name: "kind guard with break narrows the union payload for the rest of the loop body",
    src: `
export type Msg =
  | { readonly kind: "num"; readonly value: number }
  | { readonly kind: "stop" };
export function prefixTotal(msgs: readonly Msg[]): number {
  let sum = 0;
  for (const msg of msgs) {
    if (msg.kind !== "num") break;
    sum += msg.value;
  }
  return sum;
}
`,
  },
  {
    name: "kind guard with continue skips non-matching arms and narrows the rest",
    src: `
export type Msg =
  | { readonly kind: "num"; readonly value: number }
  | { readonly kind: "stop" };
export function numTotal(msgs: readonly Msg[]): number {
  let sum = 0;
  for (const msg of msgs) {
    if (msg.kind !== "num") continue;
    sum += msg.value;
  }
  return sum;
}
`,
  },
  {
    name: "labeled break guard narrows through nested loops",
    src: `
export interface Cell { readonly weight: number; }
export function probe(r: number, c: number): Cell | null {
  if (r + c > 4) return null;
  return { weight: r * 10 + c };
}
export function scan(rows: number, cols: number): number {
  let sum = 0;
  outer: for (let r = 0; r < rows; r += 1) {
    for (let c = 0; c < cols; c += 1) {
      const cell = probe(r, c);
      if (cell === null) break outer;
      sum += cell.weight;
    }
  }
  return sum;
}
`,
  },
  {
    name: "multi-statement break exit still narrows (block-form orelse)",
    src: `
export interface P { readonly v: number; }
export function next(i: number): P | null {
  if (i >= 3) return null;
  return { v: i };
}
export function run(n: number): number {
  let sum = 0;
  let misses = 0;
  for (let i = 0; i < n; i += 1) {
    const p = next(i);
    if (p === null) {
      misses += 1;
      break;
    }
    sum += p.v;
  }
  return sum + misses;
}
`,
  },
  {
    name: "throw exit on a property target narrows the rest (block-form guard)",
    src: `
export interface ParseError { readonly kind: "parse"; readonly at: number; }
export interface Sel { readonly value: number; }
export interface Model { readonly sel: Sel | null; }
function selValue(model: Model, at: number): number {
  if (model.sel === null) throw { kind: "parse", at: at } as ParseError;
  return model.sel.value;
}
export function readSel(model: Model, at: number): number {
  try {
    return selValue(model, at);
  } catch (e) {
    return e.at - 1;
  }
}
`,
  },
  {
    name: "present-test with a break else-arm narrows after the if",
    src: `
export interface Tok { readonly v: number; readonly n: number; }
export function read(i: number): Tok | null {
  if (i >= 5) return null;
  return { v: i, n: i + 1 };
}
export function consume(limit: number): number {
  let acc = 0;
  let i = 0;
  while (i < limit) {
    const t = read(i);
    if (t !== null) {
      acc += t.v;
    } else {
      break;
    }
    i = t.n;
  }
  return acc;
}
`,
  },
  {
    name: "present-test with a return else-arm narrows after the if (no read inside the hit arm)",
    src: `
export interface R2 { readonly value: number; }
export function tally(r: R2 | null): number {
  let t = 0;
  if (r !== null) {
    t += 1;
  } else {
    return 0;
  }
  return t + r.value;
}
`,
  },
  {
    name: "the narrowing ends with the loop body: post-loop reads re-test the optional",
    src: `
export interface Sel { readonly value: number; }
export interface Model { readonly sel: Sel | null; readonly count: number; }
export function drain(model: Model): number {
  let total = 0;
  let i = 0;
  while (i < model.count) {
    if (model.sel === null) break;
    total += model.sel.value;
    i += 1;
  }
  return model.sel === null ? total : total + model.sel.value;
}
`,
  },
  {
    name: "the narrowing ends with the branch: a guard under a flag never leaks to the merge",
    src: `
export interface Sel { readonly value: number; }
export interface Model { readonly sel: Sel | null; readonly count: number; }
export function pick(flag: boolean, model: Model): number {
  let total = 0;
  for (let i = 0; i < model.count; i += 1) {
    if (flag) {
      if (model.sel === null) break;
      total += model.sel.value;
    }
    total += model.sel === null ? 0 : model.sel.value;
  }
  return total;
}
`,
  },
  {
    name: "return guard regression pin: the long-supported early return still narrows",
    src: `
export interface Parsed { readonly value: number; readonly rest: number; }
export function parseOne(body: Uint8Array, i: number): Parsed | null {
  if (i >= body.length) return null;
  return { value: body[i], rest: i + 1 };
}
export function first(body: Uint8Array): number {
  const r = parseOne(body, 0);
  if (r === null) return -1;
  return r.value + r.rest;
}
`,
  },
  {
    name: "a do-while body ending in break drops the (unreachable) trailing test",
    src: `
export interface Sel { readonly value: number; }
export interface Model { readonly sel: Sel | null; }
export function once(model: Model): number {
  let total = 0;
  do {
    if (model.sel !== null) {
      total += model.sel.value;
    }
    break;
  } while (total < 3);
  return total;
}
`,
  },
  {
    name: "break guard inside a do-while narrows the rest of its body",
    src: `
export interface Sel { readonly value: number; }
export interface Model { readonly sel: Sel | null; }
export function drainDo(model: Model): number {
  let total = 0;
  do {
    if (model.sel === null) break;
    total += model.sel.value;
  } while (total < 10);
  return total;
}
`,
  },
  {
    // Post-if narrowing must survive every exit path from the if emission:
    // the else-if chain path returned before applying it, leaving the
    // fall-through read on the still-optional value.
    name: "an exiting null guard heading an else-if chain narrows after the statement",
    src: `
export interface P { readonly v: number; }
export function pick(x: P | null, flag: boolean): number {
  let n = 1;
  if (x === null) {
    return -1;
  } else if (flag) {
    n = 2;
  }
  return x.v + n;
}
`,
  },
  {
    name: "an exiting null guard heading an else-if-else chain narrows after the statement",
    src: `
export interface P { readonly v: number; }
export function pick(x: P | null, flag: boolean): number {
  let n = 1;
  if (x === null) {
    return -1;
  } else if (flag) {
    n = 2;
  } else {
    n = 3;
  }
  return x.v + n;
}
`,
  },
  {
    name: "an exiting null guard heading a chained else-if-else-if narrows after the statement",
    src: `
export interface P { readonly v: number; }
export function pick(x: P | null, a: boolean, b: boolean): number {
  let n = 1;
  if (x === null) {
    return -1;
  } else if (a) {
    n = 2;
  } else if (b) {
    n = 3;
  }
  return x.v + n;
}
`,
  },
  {
    name: "a present test whose else-if chain always exits narrows after the statement (other polarity)",
    src: `
export interface P { readonly v: number; }
export function pick(x: P | null, flag: boolean): number {
  let n = 1;
  if (x !== null) {
    n = 2;
  } else if (flag) {
    return -1;
  } else {
    return -2;
  }
  return x.v + n;
}
`,
  },
  {
    name: "a reassigned let with an adjacent continue guard stays assignable (no const fusion)",
    src: `
export interface P { readonly v: number; readonly tag: number; }
export function next(i: number): P | null {
  if (i % 2 === 0) return null;
  return { v: i, tag: i };
}
export function total(n: number): number {
  let sum = 0;
  for (let i = 0; i < n; i += 1) {
    let p = next(i);
    if (p === null) continue;
    p = { ...p, v: 10 };
    sum += p.v;
  }
  return sum;
}
`,
  },
  {
    name: "an early break out of a switch clause is gated (Zig break binds loops, not switches)",
    gate: "NS9001",
    src: `
export type Msg =
  | { readonly kind: "a"; readonly v: number }
  | { readonly kind: "b" };
export function f(msgs: readonly Msg[]): number {
  let sum = 0;
  for (const m of msgs) {
    switch (m.kind) {
      case "a":
        if (m.v > 10) break;
        sum += m.v;
        break;
      case "b":
        sum += 1;
        break;
    }
  }
  return sum;
}
`,
  },
];

// Scoped kind-narrowing must restore EVERY map it mutates. narrowUnion
// writes memberSubst, narrowedUnion, and — for optional payload fields —
// stillOptionalSubst; a wrapper that snapshots only the first two leaves
// the optional marker overwritten on exit, so the payload capture reads as
// non-null afterward and null tests route around the narrowing lowerings.
const kindNarrowRestoreCases: Case[] = [
  {
    name: "a redundant kind guard inside a payload capture keeps the payload optional after it",
    src: `
export type Msg =
  | { readonly kind: "got"; readonly parsed: number | null }
  | { readonly kind: "miss" };
export function score(msg: Msg): number {
  switch (msg.kind) {
    case "got": {
      const marker = msg.kind === "got" ? 1 : 2;
      return msg.parsed !== null ? msg.parsed + marker : 0;
    }
    case "miss":
      return -1;
  }
}
`,
  },
  {
    name: "a nested kind guard STATEMENT inside the capture keeps the optional too",
    src: `
export type Msg =
  | { readonly kind: "got"; readonly parsed: number | null }
  | { readonly kind: "miss" };
export function tally(msg: Msg): number {
  switch (msg.kind) {
    case "got": {
      let bonus = 0;
      if (msg.kind === "got") {
        bonus = 5;
      }
      return msg.parsed === null ? bonus : msg.parsed + bonus;
    }
    case "miss":
      return -1;
  }
}
`,
  },
  {
    // The narrowing maps key on the tested expression's TEXT, so a
    // DIFFERENT variable spelling the same name collides the key: a
    // callback parameter shadowing the switch subject. The kind guard over
    // the shadow overwrites the subject's optional-payload marker under
    // the shared "e.value" key, and only a full-map restore puts the
    // subject's marker back — a delete-additions-only restore leaves the
    // stale marker, the later null test reads the payload as already
    // non-null, and the narrowing lowering is skipped (an optional lands
    // in integer arithmetic).
    name: "a kind guard over a SHADOWING callback parameter keeps the subject's payload optional",
    src: `
export type Entry =
  | { readonly kind: "score"; readonly value: number | null; readonly bonus: number }
  | { readonly kind: "empty" };
export function total(e: Entry, others: readonly Entry[]): number {
  switch (e.kind) {
    case "score": {
      const anyPositive = others.some((e) => (e.kind === "score" ? e.bonus > 0 : false));
      const boost = anyPositive ? 1 : 0;
      if (e.value !== null) {
        return e.value + e.bonus + boost;
      }
      return e.bonus + boost;
    }
    case "empty":
      return 0;
  }
}
`,
  },
  {
    // Statement spelling of the shadow: a block-scoped declaration of the
    // same union-typed name inside the payload capture's scope, with a
    // kind-guard STATEMENT over it, then a null test on the subject's
    // payload after the block closes. The block boundary must hand back
    // the subject's markers untouched by the shadow's narrowing.
    name: "a kind guard over a block-scoped SHADOWING declaration keeps the subject's payload optional",
    src: `
export type Entry =
  | { readonly kind: "score"; readonly value: number | null; readonly bonus: number }
  | { readonly kind: "empty" };
export function tally(e: Entry, other: Entry): number {
  switch (e.kind) {
    case "score": {
      let acc = 0;
      {
        const e = other;
        if (e.kind === "score") {
          acc = e.bonus;
        }
      }
      if (e.value !== null) {
        return e.value + e.bonus + acc;
      }
      return e.bonus + acc;
    }
    case "empty":
      return 0;
  }
}
`,
  },
  {
    // A redundant nested SWITCH on the same subject inside an already-
    // narrowed arm overwrites the arm's capture entries with the inner
    // capture name; the continuation after the inner switch must read the
    // OUTER capture again (the inner one's block has closed in Zig).
    name: "a redundant nested switch on the same subject hands back the outer capture",
    src: `
export type Ev =
  | { readonly kind: "hit"; readonly value: number }
  | { readonly kind: "miss" };
export function score(e: Ev): number {
  switch (e.kind) {
    case "hit": {
      let bonus = 0;
      switch (e.kind) {
        case "hit": {
          bonus = e.value * 2;
          break;
        }
        default:
          break;
      }
      return e.value + bonus;
    }
    case "miss":
      return 0;
  }
}
`,
  },
];

// Narrowing INVALIDATION must survive the merge: a branch that assigns a
// possibly-null value to a narrowed local kills its `.?` substitution at the
// assignment, and the block-exit snapshot restore (which exists for
// CONTAINMENT — narrowings added inside a branch must not leak out) must not
// resurrect the dead narrow. A resurrected narrow makes the post-merge
// re-check emit `p.? == null` — "comparison of 'f64' with null" in Zig. The
// merge is deliberately conservative: a kill on ANY path deletes the narrow
// at the merge point, so the author's post-merge re-check (which tsc demands
// anyway — the branch widened the type back) always compiles.
const narrowInvalidationMergeCases: Case[] = [
  {
    name: "a branch reassigning a narrowed local to null kills the narrow past the merge",
    src: `
export function f(q: number | null, flag: boolean): number {
  let p: number | null = q;
  if (p === null) { return -1; }
  if (flag) {
    p = null;
  }
  if (p === null) { return 0; }
  return p;
}
`,
  },
  {
    name: "a branch reassigning from an optional-returning call kills the narrow past the merge",
    src: `
export function pick(xs: readonly number[], i: number): number | null {
  return i >= 0 && i < xs.length ? xs[i] : null;
}
export function f(q: number | null, xs: readonly number[], i: number): number {
  let p: number | null = q;
  if (p === null) { return -1; }
  if (i > 0) {
    p = pick(xs, i);
  }
  if (p === null) { return 0; }
  return p;
}
`,
  },
  {
    name: "an ELSE branch reassigning to null kills the narrow past the merge",
    src: `
export function f(q: number | null, flag: boolean): number {
  let p: number | null = q;
  if (p === null) { return -1; }
  if (flag) {
    // this path keeps the narrow; the merge must still drop it
  } else {
    p = null;
  }
  if (p === null) { return 0; }
  return p;
}
`,
  },
  {
    name: "a nested inner branch's kill propagates through BOTH block exits to the merge",
    src: `
export function f(q: number | null, a: boolean, b: boolean): number {
  let p: number | null = q;
  if (p === null) { return -1; }
  if (a) {
    if (b) {
      p = null;
    }
  }
  if (p === null) { return 0; }
  return p;
}
`,
  },
  {
    name: "a branch that reads the narrow and then kills it still drops it at the merge",
    src: `
export function f(q: number | null): number {
  let p: number | null = q;
  if (p === null) { return -1; }
  let acc: number = 0;
  if (p > 2) {
    acc = p;
    p = null;
  }
  if (p === null) { return acc; }
  return p;
}
`,
  },
  {
    name: "a switch arm reassigning to null kills the narrow past the switch",
    src: `
export type Msg = { readonly kind: "set"; readonly value: number } | { readonly kind: "clear" };
export function f(q: number | null, msg: Msg): number {
  let p: number | null = q;
  if (p === null) { return -1; }
  switch (msg.kind) {
    case "set": {
      p = p + msg.value;
      break;
    }
    case "clear": {
      p = null;
      break;
    }
  }
  if (p === null) { return 0; }
  return p;
}
`,
  },
  {
    name: "a kind-guarded branch reassigning to null kills the narrow past the merge",
    src: `
export type Msg = { readonly kind: "set"; readonly flag: boolean } | { readonly kind: "clear" };
export function g(q: number | null, msg: Msg): number {
  let p: number | null = q;
  if (p === null) { return -1; }
  if (msg.kind === "set" && msg.flag) {
    p = null;
  }
  if (p === null) { return 0; }
  return p;
}
`,
  },
  {
    // A compound null guard (`r !== null && r > 0`) routes its branch
    // emission through the chain-substitution scope, whose own full-map
    // restore runs AFTER the branch's kill re-apply. Without the kill-frame
    // bracket on that scope, the kill of p's narrow resurrects at the
    // restore and the post-merge re-check emits `p.? == null` —
    // "comparison of 'f64' with null".
    name: "a kill inside a compound-null-guarded branch stays dead past the merge",
    src: `
export function f(q: number | null, r: number | null): number {
  let p: number | null = q;
  if (p === null) return -1;
  if (r !== null && r > 0) {
    p = null;
  } else {}
  if (p === null) return 0;
  return p;
}
`,
  },
  {
    name: "a kill in the ELSE of a compound-null-guarded if stays dead past the merge",
    src: `
export function f(q: number | null, r: number | null): number {
  let p: number | null = q;
  if (p === null) return -1;
  if (r !== null && r > 0) {
    // the guarded path keeps the narrow; the merge must still drop it
  } else {
    p = null;
  }
  if (p === null) return 0;
  return p;
}
`,
  },
  {
    name: "a compound-guard kill nested inside a kind guard escapes both scopes",
    src: `
export type Msg = { readonly kind: "set"; readonly flag: boolean } | { readonly kind: "clear" };
export function f(q: number | null, r: number | null, msg: Msg): number {
  let p: number | null = q;
  if (p === null) return -1;
  if (msg.kind === "set" && msg.flag) {
    if (r !== null && r > 0) {
      p = null;
    }
  }
  if (p === null) return 0;
  return p;
}
`,
  },
  {
    // The containment half must stay intact: a narrowing ESTABLISHED inside
    // a branch still dies at the branch exit. If it leaked, the post-merge
    // null test would read the narrowed spelling and emit the same
    // comparison-with-null error the kill cases pin.
    name: "containment pin: a narrow established inside a branch still does not leak out",
    src: `
export function f(q: number | null, flag: boolean): number {
  let acc: number = 0;
  if (flag) {
    if (q === null) { return -1; }
    acc = q;
  }
  return acc + (q === null ? 0 : q);
}
`,
  },
];

// The kill merge is flow-sensitive the way tsc is: a branch that kills a
// narrow and then always LEAVES the function cannot reach the merge, so its
// kill applies nowhere — tsc keeps the narrow on the surviving flow, and a
// read there depends on the substitution's unwrap spelling (a dropped
// spelling emits a field access or plain read on an optional, not a
// re-check). Kills on paths that resume inside the function still apply —
// and they apply where control resumes: a true fall-through merges; a
// branch whose only in-function routes are non-local edges stages its kills
// at each edge's destination instead (a caught throw at the post-try
// continuation, a break at its target construct's post-state, a continue at
// the loop's exit join, a lowered callback return after the value block) —
// never into flow the killing path cannot reach.
const killFallthroughCases: Case[] = [
  {
    name: "a branch that kills and returns leaves the surviving flow's capture narrow intact",
    src: `
export interface P { readonly v: number; }
export function f(p0: P | null): number {
  let p: P | null = p0;
  if (p !== null) {
    if (p.v < 0) { p = null; return -1; }
    return p.v;
  }
  return 0;
}
`,
  },
  {
    name: "a branch that kills and returns leaves the surviving flow's orelse narrow intact",
    src: `
export function f(q: number | null, flag: boolean): number {
  let p: number | null = q;
  if (p === null) { return -1; }
  if (flag) { p = null; return -2; }
  return p;
}
`,
  },
  {
    name: "a branch that kills and throws (uncaught) leaves the surviving narrow intact",
    src: `
export interface P { readonly v: number; }
export interface NegError { readonly kind: "neg"; readonly at: number; }
export function f(p0: P | null): number {
  let p: P | null = p0;
  if (p !== null) {
    if (p.v < 0) { p = null; throw { kind: "neg", at: 0 } as NegError; }
    return p.v;
  }
  return 0;
}
`,
  },
  {
    name: "a kill two blocks deep on an always-returning path stays off the surviving reads",
    src: `
export interface P { readonly v: number; }
export function f(p0: P | null, a: boolean, b: boolean): number {
  let p: P | null = p0;
  if (p !== null) {
    if (a) {
      if (b) { p = null; return -1; }
      return p.v;
    }
    return p.v + 1;
  }
  return 0;
}
`,
  },
  {
    // One arm exits and kills (its kill is unreachable at the merge); the
    // other falls through and kills (its kill must survive). The post-merge
    // re-check reads the LIVE slot, so a resurrected narrow here is the
    // comparison-with-null compile error the invalidation cases pin.
    name: "mixed arms: the exiting arm's kill drops, the fall-through arm's kill merges",
    src: `
export function f(q: number | null, flag: boolean): number {
  let p: number | null = q;
  if (p === null) { return -1; }
  if (flag) {
    p = null;
    return -2;
  } else {
    p = null;
  }
  if (p === null) { return 0; }
  return p;
}
`,
  },
  {
    // `break` leaves the loop, not the function: control resumes right
    // after it, where the kill must hold for the re-check to compile.
    name: "a break-guarded kill still reaches the code after the loop",
    src: `
export function f(q: number | null, xs: readonly number[]): number {
  let p: number | null = q;
  if (p === null) { return -1; }
  for (const x of xs) {
    if (x < 0) { p = null; break; }
  }
  if (p === null) { return 0; }
  return p;
}
`,
  },
  {
    // `continue` resumes at the next iteration and the loop still falls
    // through to the code after it, so the kill merges there too.
    name: "a continue-guarded kill still reaches the code after the loop",
    src: `
export function f(q: number | null, xs: readonly number[]): number {
  let p: number | null = q;
  if (p === null) { return -1; }
  let acc: number = 0;
  for (const x of xs) {
    if (x < 0) { p = null; continue; }
    acc = acc + x;
  }
  if (p === null) { return acc; }
  return p + acc;
}
`,
  },
  {
    // Kills travel the same edges control does: a branch whose only
    // in-function route is a caught throw resumes at the POST-try
    // continuation, never at the try body's remaining statements — so the
    // intra-try read keeps its narrow (tsc agrees) while the post-try
    // re-check reads the live optional. Merging the kill intra-try
    // stripped the surviving path's unwrap and the read failed to compile.
    name: "a caught-throw kill skips the intra-try flow and lands after the try",
    src: `
export interface P { readonly v: number; }
export interface Boom { readonly kind: "boom"; }
export function f(q: P | null, flag: boolean): number {
  let p: P | null = q;
  if (p === null) return -1;
  try {
    if (flag) { p = null; throw { kind: "boom" } as Boom; }
    return p.v;
  } catch {}
  if (p === null) return 0;
  return p.v + 1;
}
`,
  },
  {
    // Control: a branch with BOTH a caught-throw route and a normal
    // fallthrough still merges intra-try — the fallthrough carries the
    // kill into the try's remaining statements legitimately.
    name: "a branch with a caught throw AND fallthrough still merges its kill intra-try",
    src: `
export interface P { readonly v: number; }
export interface Boom { readonly kind: "boom"; }
export function f(q: P | null, flag: boolean, deep: boolean): number {
  let p: P | null = q;
  if (p === null) return -1;
  try {
    if (flag) { p = null; if (deep) { throw { kind: "boom" } as Boom; } }
    if (p === null) return -2;
    return p.v;
  } catch {}
  if (p === null) return 0;
  return p.v + 1;
}
`,
  },
  {
    // Nested tries: a throw caught by the INNER catch that falls through
    // resumes at the inner try's continuation — the kill lands THERE (and
    // flows outward from that point), while the intra-inner-try read keeps
    // its narrow.
    name: "a caught-throw kill in a nested try lands at the inner continuation",
    src: `
export interface P { readonly v: number; }
export interface Boom { readonly kind: "boom"; }
export function f(q: P | null, flag: boolean): number {
  let p: P | null = q;
  if (p === null) return -1;
  let acc: number = 0;
  try {
    try {
      if (flag) { p = null; throw { kind: "boom" } as Boom; }
      acc = p.v;
    } catch {}
    if (p === null) { acc = acc - 1; }
  } catch {}
  if (p === null) return acc;
  return p.v + acc;
}
`,
  },
  {
    // Control: a kill in the CATCH block itself merges at the post-try
    // continuation exactly as before the exception-kills channel.
    name: "a kill in the catch block still reaches the post-try re-check",
    src: `
export interface P { readonly v: number; }
export interface Boom { readonly kind: "boom"; }
export function f(q: P | null, flag: boolean): number {
  let p: P | null = q;
  if (p === null) return -1;
  try {
    if (flag) { throw { kind: "boom" } as Boom; }
  } catch {
    p = null;
  }
  if (p === null) return 0;
  return p.v;
}
`,
  },
  {
    // A throw under an enclosing try lands in the catch, not out of the
    // function; control resumes after the try/catch, where p may be null.
    name: "a kill before a locally-caught throw still reaches past the catch",
    src: `
export interface NegError { readonly kind: "neg"; readonly at: number; }
export function f(q: number | null, flag: boolean): number {
  let p: number | null = q;
  if (p === null) { return -1; }
  try {
    if (flag) { p = null; throw { kind: "neg", at: 0 } as NegError; }
  } catch {
  }
  if (p === null) { return 0; }
  return p;
}
`,
  },
  {
    // The try body's terminal `return` is not its only exit: the call
    // before it can throw, land in the catch, and fall through to the
    // re-check — which must then read the LIVE optional, not a stale
    // unwrap (tsc types p as P | null here for the same reason).
    name: "a kill before a throwing call in a try body reaches past a fall-through catch",
    src: `
export interface P { readonly v: number; }
export interface Boom { readonly kind: "boom"; }
function g(flag: boolean): void {
  if (flag) { throw { kind: "boom" } as Boom; }
}
export function f(q: P | null, flag: boolean): number {
  let p: P | null = q;
  if (p === null) { return -1; }
  try {
    p = null;
    g(flag);
    return -2;
  } catch {
  }
  if (p === null) { return 0; }
  return p.v;
}
`,
  },
  {
    // A catch that always leaves the function closes every exception route
    // to the merge, so the body's kill drops on its terminal return and the
    // surviving flow's read keeps its narrow (tsc agrees: no path through
    // the try/catch reaches `return p.v`).
    name: "a kill in a try body whose catch always returns stays off the surviving reads",
    src: `
export interface P { readonly v: number; }
export interface Boom { readonly kind: "boom"; }
function g(flag: boolean): void {
  if (flag) { throw { kind: "boom" } as Boom; }
}
export function f(p0: P | null, flag: boolean): number {
  let p: P | null = p0;
  if (p !== null) {
    if (p.v < 0) {
      try { p = null; g(flag); return -1; } catch { return -2; }
    }
    return p.v;
  }
  return 0;
}
`,
  },
  {
    // try/finally has no catch fallthrough: a mid-body throw propagates out
    // of the function (after the finally), so the body's terminal return
    // still drops its kills and the post-construct read keeps its narrow.
    name: "a kill in a returning try/finally body stays off the code after it",
    src: `
export function f(q: number | null, flag: boolean): number {
  let p: number | null = q;
  if (p === null) { return -1; }
  let cleanup: number = 0;
  if (flag) {
    try {
      p = null;
      return -2;
    } finally {
      cleanup = 1;
    }
  }
  return p + cleanup;
}
`,
  },
  {
    // Control: a kill inside an exiting branch of a try body with NO local
    // catch behaves exactly like one outside any try — the branch's kill
    // drops, and the body's later read keeps the surviving narrow.
    name: "an exiting-branch kill inside a catchless try body still drops",
    src: `
export function f(q: number | null, flag: boolean): number {
  let p: number | null = q;
  if (p === null) { return -1; }
  let acc: number = 0;
  try {
    if (flag) { p = null; return -2; }
    acc = p;
  } finally {
    acc = acc + 1;
  }
  return acc;
}
`,
  },
  {
    // The body's terminal return is not its only route out: the earlier
    // break escapes the loop carrying the kill, so the post-loop re-check
    // must read the LIVE optional (tsc types p as number | null there).
    name: "a mid-list break escapes a loop body whose terminal statement returns",
    src: `
export function f(q: number | null, xs: readonly number[]): number {
  let p: number | null = q;
  if (p === null) { return -1; }
  for (const x of xs) {
    if (x < 0) { p = null; break; }
    return -2;
  }
  if (p === null) { return 0; }
  return p;
}
`,
  },
  {
    // Control: a break bound to a loop WHOLLY inside the exiting branch
    // resumes inside it and is no route out — the branch's kill still
    // drops, and the surviving read keeps its capture narrow.
    name: "a break bound to a loop wholly inside an exiting branch is no escape",
    src: `
export interface P { readonly v: number; }
export function f(p0: P | null, xs: readonly number[]): number {
  let p: P | null = p0;
  if (p !== null) {
    if (p.v < 0) {
      p = null;
      let acc: number = 0;
      for (const x of xs) {
        if (x < 0) { break; }
        acc = acc + x;
      }
      return acc;
    }
    return p.v;
  }
  return 0;
}
`,
  },
  {
    // The continue flavor of the mid-list escape: the loop resumes, then
    // falls through to the re-check, which needs the live value.
    name: "a mid-list continue escapes a loop body whose terminal statement returns",
    src: `
export function f(q: number | null, xs: readonly number[]): number {
  let p: number | null = q;
  if (p === null) { return -1; }
  for (const x of xs) {
    if (x < 0) { p = null; continue; }
    return -2;
  }
  if (p === null) { return 0; }
  return p;
}
`,
  },
  {
    // A catch that ends in return still has a route back into the
    // function when a call inside it can throw to an OUTER catch that
    // falls through — the inner body's kill must reach the outer merge.
    name: "a throwing call in an exiting catch escapes to an outer fall-through catch",
    src: `
export interface Boom { readonly kind: "boom"; }
function g(flag: boolean): void {
  if (flag) { throw { kind: "boom" } as Boom; }
}
export function f(q: number | null, a: boolean, b: boolean): number {
  let p: number | null = q;
  if (p === null) { return -1; }
  try {
    try {
      p = null;
      g(a);
      return -2;
    } catch {
      g(b);
      return -3;
    }
  } catch {
  }
  if (p === null) { return 0; }
  return p;
}
`,
  },
  {
    // Control: when the OUTER catch also always leaves, every escape from
    // the inner catch's throwing call still exits the function — the inner
    // body's kill drops and the surviving read keeps its capture narrow.
    name: "an exiting catch whose throws land in an exiting outer catch still closes the body",
    src: `
export interface P { readonly v: number; }
export interface Boom { readonly kind: "boom"; }
function g(flag: boolean): void {
  if (flag) { throw { kind: "boom" } as Boom; }
}
export function f(p0: P | null, a: boolean, b: boolean): number {
  let p: P | null = p0;
  if (p !== null) {
    if (p.v < 0) {
      try {
        try { p = null; g(a); return -1; } catch { g(b); return -2; }
      } catch {
        return -3;
      }
    }
    return p.v;
  }
  return 0;
}
`,
  },
  {
    // A labeled break out of a labeled block resumes right after the
    // block — inside the function — so its kill reaches the re-check even
    // though the block's terminal statement returns.
    name: "a labeled break out of a labeled block carries its kill past the block",
    src: `
export function f(q: number | null, flag: boolean): number {
  let p: number | null = q;
  if (p === null) { return -1; }
  outer: {
    if (flag) { p = null; break outer; }
    return -2;
  }
  if (p === null) { return 0; }
  return p;
}
`,
  },
  {
    // The do-while flavor of the mid-list escape.
    name: "a mid-list break in a do-while body whose terminal statement returns",
    src: `
export function f(q: number | null, flag: boolean): number {
  let p: number | null = q;
  if (p === null) { return -1; }
  do {
    if (flag) { p = null; break; }
    return -2;
  } while (flag);
  if (p === null) { return 0; }
  return p;
}
`,
  },
  {
    // Control: clause-terminating breaks bind the switch inside the list,
    // resume inside it, and are no routes out — the exiting branch's kill
    // still drops past the terminal return.
    name: "a switch-bound break inside an exiting branch is no escape",
    src: `
export interface P { readonly v: number; }
export type Mode = "a" | "b";
export function f(p0: P | null, m: Mode): number {
  let p: P | null = p0;
  if (p !== null) {
    if (p.v < 0) {
      p = null;
      let acc: number = 0;
      switch (m) {
        case "a": acc = 1; break;
        case "b": acc = 2; break;
      }
      return acc;
    }
    return p.v;
  }
  return 0;
}
`,
  },
  {
    // tsc treats `while (true)` without a break bound to it as never
    // completing: the killing branch never reaches the merge, so the
    // post-merge read keeps the pre-branch narrow. The kill must DROP —
    // merging it resurrects the optional and the read emits optional
    // arithmetic Zig rejects. (Zig agrees the loop is noreturn, so the
    // branch body emits as-is.)
    name: "a kill sealed behind while(true) never reaches the merge",
    src: `
export function f(q: number | null, flag: boolean, bump: number): number {
  let p: number | null = q;
  if (p === null) { return -1; }
  if (flag) {
    p = null;
    while (true) {}
  }
  return p + bump;
}
`,
  },
  {
    // The classic-for spelling of the same seal. The subset's classic-for
    // mapping requires init/cond/increment, so the literal-true condition
    // is the emittable spelling of an infinite for loop (`for (;;)` stops
    // at NS9001 before narrowing matters).
    name: "a kill sealed behind a literal-true classic for never reaches the merge",
    src: `
export function f(q: number | null, flag: boolean, bump: number): number {
  let p: number | null = q;
  if (p === null) { return -1; }
  if (flag) {
    p = null;
    for (let i = 0; true; i += 1) {}
  }
  return p + bump;
}
`,
  },
  {
    // The do-while spelling: the body runs before the first test, but a
    // literal-true test with no bound break still never lets the loop
    // complete.
    name: "a kill sealed behind do-while(true) never reaches the merge",
    src: `
export function f(q: number | null, flag: boolean, bump: number): number {
  let p: number | null = q;
  if (p === null) { return -1; }
  if (flag) {
    p = null;
    do {} while (true);
  }
  return p + bump;
}
`,
  },
  {
    // A break bound to the loop makes its end reachable: the killing
    // branch DOES reach the merge, so the kill must still merge and the
    // post-loop re-check reads the live slot.
    name: "a break bound to an infinite loop carries the kill past it",
    src: `
export function f(q: number | null, flag: boolean): number {
  let p: number | null = q;
  if (p === null) { return -1; }
  if (flag) {
    p = null;
    while (true) {
      if (flag) { break; }
    }
  }
  if (p === null) { return 0; }
  return p;
}
`,
  },
  {
    // A return inside the infinite loop leaves the function without
    // completing the loop: the branch still counts as function-leaving,
    // so its kill drops and the surviving flow keeps the narrow.
    name: "a return nested in an infinite loop still makes the branch leave the function",
    src: `
export function f(q: number | null, flag: boolean, n: number): number {
  let p: number | null = q;
  if (p === null) { return -1; }
  if (flag) {
    p = null;
    while (true) {
      if (n > 0) { return n; }
    }
  }
  return p + 2;
}
`,
  },
  {
    // Guard against over-recognition: a non-literal-true condition can be
    // false on entry, the loop completes, and the kill reaches the merge —
    // the re-check must read the live slot.
    name: "a while over a non-literal condition is never terminal",
    src: `
export function f(q: number | null, flag: boolean, n: number): number {
  let p: number | null = q;
  if (p === null) { return -1; }
  if (flag) {
    p = null;
    let i: number = n;
    while (i > 0) { i = i - 1; }
  }
  if (p === null) { return 0; }
  return p;
}
`,
  },
  {
    // A throw caught by a fall-through catch resumes at the statements
    // AFTER the try — here a terminal return — so every route through the
    // branch (throw -> catch -> return; no-throw -> return) leaves the
    // function. The kill must DROP: tsc keeps the narrow on the surviving
    // flow, and merging would strip the unwrap off `return p.v`.
    name: "a caught throw whose fall-through catch resumes into a returning tail still drops",
    src: `
export interface NegError { readonly kind: "neg"; readonly at: number; }
export interface P { readonly v: number; }
export function f(q: P | null, flag: boolean): number {
  let p: P | null = q;
  if (p === null) { return -1; }
  if (p.v < 0) {
    try {
      p = null;
      if (flag) { throw { kind: "neg", at: 0 } as NegError; }
    } catch {
    }
    return -2;
  }
  return p.v;
}
`,
  },
  {
    // Control for the continuation logic: when the statements after the
    // try do NOT all leave (a conditional return, then fallthrough), the
    // caught throw's route reaches the merge and the kill must still
    // MERGE — the post-branch re-check reads the live slot.
    name: "a caught throw whose continuation can fall through still merges its kill",
    src: `
export interface NegError { readonly kind: "neg"; readonly at: number; }
export interface P { readonly v: number; }
export function f(q: P | null, flag: boolean): number {
  let p: P | null = q;
  if (p === null) { return -1; }
  if (p.v < 0) {
    try {
      p = null;
      if (flag) { throw { kind: "neg", at: 0 } as NegError; }
    } catch {
    }
    if (flag) { return -2; }
  }
  if (p === null) { return 0; }
  return p.v;
}
`,
  },
  {
    // Composition pin: a catch that itself returns closes the throw route
    // without consulting the continuation, and the no-throw path leaves on
    // the try's own terminal return — drop either way.
    name: "a caught throw whose catch returns drops without consulting the continuation",
    src: `
export interface NegError { readonly kind: "neg"; readonly at: number; }
export interface P { readonly v: number; }
export function f(q: P | null, flag: boolean): number {
  let p: P | null = q;
  if (p === null) { return -1; }
  if (p.v < 0) {
    try {
      p = null;
      if (flag) { throw { kind: "neg", at: 0 } as NegError; }
    } catch {
      return -2;
    }
    return -3;
  }
  return p.v;
}
`,
  },
];

// Destination-specific kill staging: an arm whose only in-function routes
// are non-local edges (break, continue, a lowered callback return) applies
// its kills where those edges LAND — the target construct's post-state, the
// loop's exit join, the post-value-block continuation — never at the arm's
// own fall-through merge, a point the killing path cannot reach. tsc keeps
// the fall-through narrow there, and the reads depend on the unwrap
// spelling: a misrouted kill emits arithmetic or field access on a bare
// optional, which Zig rejects.
const edgeKillStagingCases: Case[] = [
  {
    // The core shape: the kill+break arm leaves the loop, so the
    // fall-through read after it keeps the narrow (tsc agrees — the
    // killing path cannot reach it), while the POST-loop state is where
    // the break lands and must re-check.
    name: "a kill+break arm leaves the loop-body fall-through narrow intact",
    src: `
export function tally(vals: readonly number[], limit: number): number {
  let p: number | null = 10;
  if (p === null) return -1;
  let sum: number = 0;
  for (const v of vals) {
    if (v > limit) { p = null; break; }
    sum += p;
  }
  if (p === null) return -sum;
  return sum + p;
}
`,
  },
  {
    // An unlabeled break binds the INNER loop: its kill lands post-inner —
    // the outer body's re-check — while the inner fall-through keeps the
    // narrow.
    name: "a nested inner-targeted break stages its kill at the inner loop only",
    src: `
export function nested(grid: readonly number[], cols: number): number {
  let p: number | null = 5;
  if (p === null) return -1;
  let sum: number = 0;
  for (const r of grid) {
    for (const c of grid) {
      if (c > cols) { p = null; break; }
      sum += p;
    }
    if (p === null) break;
    sum += p;
  }
  return sum;
}
`,
  },
  {
    // A labeled break out of both loops lands post-OUTER: the outer body's
    // read after the inner loop keeps the narrow (the killing path skipped
    // it), and only the post-outer state re-checks.
    name: "a labeled break out of two loops stages its kill post-outer",
    src: `
export function labeled(grid: readonly number[], cols: number): number {
  let p: number | null = 5;
  if (p === null) return -1;
  let sum: number = 0;
  outer: for (const r of grid) {
    for (const c of grid) {
      if (c > cols) { p = null; break outer; }
      sum += p;
    }
    sum += p;
  }
  if (p === null) return -2;
  return sum + p;
}
`,
  },
  {
    // A continue-edge kill rides the back edge: the fall-through read
    // after the arm keeps its per-iteration narrow (tsc agrees), the next
    // iteration re-guards (tsc REQUIRES it — the loop-entry state widens
    // for back-edge kills, so an unguarded read is TS18047 and never
    // reaches emission), and the loop's exit join re-checks.
    name: "a kill+continue arm leaves the same-iteration fall-through narrow intact",
    src: `
export function contGood(vals: readonly number[], limit: number): number {
  let p: number | null = 10;
  let sum: number = 0;
  for (const v of vals) {
    if (p === null) break;
    sum += p;
    if (v > limit) { p = null; continue; }
    sum += p;
  }
  if (p === null) return -sum;
  return sum + p;
}
`,
  },
  {
    // Mixed sibling arms route per class: the kill+break arm's kill stages
    // post-loop (the join never sees it), so the fall-through read past
    // BOTH arms keeps the narrow — only the loop's own exit re-checks.
    name: "mixed arms: the kill+break sibling stays out of the join the pure arm feeds",
    src: `
export function mixedArms(xs: readonly number[]): number {
  let p: number | null = 4;
  if (p === null) return -1;
  let acc: number = 0;
  for (const x of xs) {
    if (x < 0) { p = null; break; }
    else if (x === 0) { acc += 1; }
    acc += p;
  }
  if (p === null) return acc;
  return acc + p;
}
`,
  },
  {
    // The do-while flavor: the kill+break arm leaves the body, the
    // fall-through read keeps its narrow, and the trailing loop test plus
    // the post-loop state see the staged kill.
    name: "a kill+break arm in a do-while body leaves the fall-through narrow intact",
    src: `
export function viaDoWhile(q: number | null, flag: boolean): number {
  let p: number | null = q;
  if (p === null) return -1;
  let acc: number = 0;
  do {
    if (flag) { p = null; break; }
    acc += p;
  } while (acc < 10);
  if (p === null) return acc;
  return acc + p;
}
`,
  },
  {
    // The R7d guarded-condition while: the loop's own chain unwraps q per
    // iteration while the kill+break arm's kill on ANOTHER local stages
    // post-loop, keeping the body's fall-through read narrowed.
    name: "a kill+break under a null-guarded while condition stages past the loop",
    src: `
export interface Q { readonly v: number; }
export function guarded(q0: Q | null, flag: boolean): number {
  let p: number | null = 3;
  if (p === null) return -1;
  let q: Q | null = q0;
  let acc: number = 0;
  while (q !== null && q.v > 0) {
    if (flag) { p = null; break; }
    acc += p + q.v;
    q = null;
  }
  if (p === null) return acc;
  return acc + p;
}
`,
  },
  {
    // A lowered callback return is an edge to the continuation AFTER the
    // value block: the kill+return arm leaves the trailing in-callback
    // read narrowed (tsc agrees), and the post-callback state re-checks.
    name: "a kill+return arm in a lifted callback leaves the trailing read narrow intact",
    src: `
export function viaCallback(vals: readonly number[], limit: number): number {
  let p: number | null = 7;
  const mapped = vals.map((v) => {
    if (p === null) return 0;
    if (v > limit) { p = null; return 0; }
    return p + v;
  });
  let sum: number = 0;
  for (const m of mapped) sum += m;
  if (p === null) return -sum;
  return sum + p;
}
`,
  },
  {
    // Switch reconciliation: the clause-terminating break's kill rides the
    // sibling JOIN to the post-switch state — applied once, dropped
    // nowhere — while the LATER clause keeps its entry narrow (sibling
    // isolation) and the post-switch read re-checks.
    name: "a switch clause kill+break kills post-switch but not its later siblings",
    src: `
export type Tag = "a" | "b" | "c";
export function viaSwitch(tag: Tag, limit: number): number {
  let p: number | null = 3;
  if (p === null) return -1;
  let out: number = 0;
  switch (tag) {
    case "a": {
      p = null;
      break;
    }
    case "b": {
      out = p + limit;
      break;
    }
    case "c": {
      out = p * 2;
      break;
    }
  }
  if (p === null) return -out;
  return out + p;
}
`,
  },
  {
    // A labeled continue targets the OUTER loop's back edge: the rest of
    // the outer body keeps its (re-guarded) flow, and both the outer exit
    // join and the post-loop state re-check. The in-body read after the
    // inner loop re-guards because tsc widens the outer loop's entry for
    // the back-edge kill.
    name: "a labeled continue stages its kill at the outer loop's exit join",
    src: `
export function labeledCont(xs: readonly number[]): number {
  let p: number | null = 6;
  let acc: number = 0;
  outer: for (const a of xs) {
    for (const b of xs) {
      if (b < 0) { p = null; continue outer; }
    }
    if (p === null) return -acc;
    acc += p + a;
  }
  if (p === null) return acc;
  return acc + p;
}
`,
  },
];

// A finally clause emits as a Zig defer whose TEXT precedes the try body's,
// but whose FLOW follows it: the finally runs at the construct's exits. Its
// kills must therefore stage until the construct's exit — never apply to the
// body emitted after the defer's text, where tsc keeps the narrow (the
// finally has not run at those program points). In the other temporal
// direction, tsc types the finally itself from the pre-try state minus every
// key the try or catch may assign null to, path-insensitively (an exception
// can enter the finally from between any two statements), so a finally read
// of such a key re-checks the LIVE optional — never a stale capture.
const finallyFlowOrderCases: Case[] = [
  {
    // The try body's read keeps its narrow even though the defer carrying
    // the kill is emitted first: flow order, not emission order.
    name: "a finally-clause kill stays off the try body's own reads",
    src: `
export interface P { readonly v: number; }
export function f(q: P | null): number {
  let p: P | null = q;
  if (p === null) { return -1; }
  try {
    return p.v;
  } finally {
    p = null;
  }
}
`,
  },
  {
    // tsc widens the killed key inside the finally (the kill may or may not
    // have run when an exception hands control over), so the finally's read
    // re-checks and must test the live variable, not a pre-try capture.
    name: "a finally clause re-checks a narrow the try body killed",
    src: `
export function f(q: number | null, drop: boolean): number {
  let p: number | null = q;
  if (p === null) { return -1; }
  let seen: number = 0;
  try {
    if (drop) { p = null; }
  } finally {
    if (p !== null) { seen = p + 1; }
  }
  return seen;
}
`,
  },
  {
    // Kills in all three regions land where flow says: the try's kill is
    // visible in the finally and after the construct; the catch's kill
    // falls through to the post-try state; the finally's own kill applies
    // at the construct's exit — and none of them touches the try body's
    // reads before the killing statement.
    name: "kills in try, catch, and finally each land at their flow destinations",
    src: `
export interface Boom { readonly kind: "boom"; }
function mayThrow(flag: boolean): void {
  if (flag) { throw { kind: "boom" } as Boom; }
}
export function f(q: number | null, r: number | null, s: number | null, flag: boolean): number {
  let a: number | null = q;
  let b: number | null = r;
  let c: number | null = s;
  if (a === null) { return -1; }
  if (b === null) { return -2; }
  if (c === null) { return -3; }
  let out: number = 0;
  try {
    a = null;
    mayThrow(flag);
    out += b;
  } catch {
    b = null;
  } finally {
    c = null;
    if (a !== null) { out += a; }
  }
  if (a !== null) { out += a; }
  if (b !== null) { out += b; }
  if (c !== null) { out += c; }
  return out;
}
`,
  },
];

// Kills that ride a throw edge into a catch are the catch's INPUT state,
// not a post-try constant: the catch body's reads see them, and their
// propagation OUT follows the catch's own routes. A catch that falls
// through carries them to the post-try continuation; a catch that
// breaks/continues stages them at that edge's landing point; a catch whose
// every route leaves the function drops them — the post-try continuation
// is then reached only by clean paths, where tsc keeps the narrow.
const catchRouteKillCases: Case[] = [
  {
    // The killed path is throw -> catch -> break -> post-loop; the code
    // after the try inside the loop is reached only by the clean path, so
    // its read keeps the narrow (tsc agrees) while the post-loop state
    // re-checks.
    name: "an exception kill follows the catch's break to the post-loop state",
    src: `
export interface Boom { readonly kind: "boom"; }
export function f(q: number | null, fail: boolean): number {
  let p: number | null = q;
  if (p === null) { return -1; }
  while (true) {
    try {
      if (fail) { p = null; throw { kind: "boom" } as Boom; }
    } catch {
      break;
    }
    return p + 1;
  }
  return -2;
}
`,
  },
  {
    // A labeled break out of both loops lands post-OUTER: the reads on the
    // clean path through both bodies keep the narrow, and only the
    // post-outer state re-checks.
    name: "an exception kill follows a labeled break out of nested loops",
    src: `
export interface Boom { readonly kind: "boom"; }
export function f(q: number | null, limit: number, grid: readonly number[]): number {
  let p: number | null = q;
  if (p === null) { return -1; }
  let sum: number = 0;
  outer: for (const r of grid) {
    for (const x of grid) {
      try {
        if (x > limit) { p = null; throw { kind: "boom" } as Boom; }
      } catch {
        break outer;
      }
      sum += p + x;
    }
    sum += p + r;
  }
  if (p === null) { return -sum; }
  return sum + p;
}
`,
  },
  {
    // A catch that re-kills the carried key and falls through merges it
    // once at the post-try state — same destination, no double application.
    name: "a catch that re-kills the carried key merges it once on fallthrough",
    src: `
export interface Boom { readonly kind: "boom"; }
export function f(q: number | null, fail: boolean): number {
  let p: number | null = q;
  if (p === null) { return -1; }
  try {
    if (fail) { p = null; throw { kind: "boom" } as Boom; }
  } catch {
    p = null;
  }
  if (p === null) { return 0; }
  return p;
}
`,
  },
  {
    // A catch whose every route returns closes the exception path: the
    // post-try continuation is reached only by the clean path and its read
    // keeps the narrow (tsc agrees — no re-check is even legal to require).
    name: "an exception kill drops with a catch that always returns",
    src: `
export interface Boom { readonly kind: "boom"; }
export function f(q: number | null, fail: boolean): number {
  let p: number | null = q;
  if (p === null) { return -1; }
  try {
    if (fail) { p = null; throw { kind: "boom" } as Boom; }
  } catch {
    return -2;
  }
  return p + 1;
}
`,
  },
];

// A lifted block-body callback whose only return is the trailing statement
// emits as straight-line statements plus that value. The statement prefix
// and the trailing expression are ONE flow in tsc — a guard in the prefix
// narrows the expression after it — so they must share one narrowing scope:
// a scope closed between them restores the maps before the expression they
// guard, emitting the read against the unnarrowed optional.
const callbackTrailingNarrowCases: Case[] = [
  {
    name: "a throw guard in a map callback narrows the trailing return expression",
    src: `
export interface P { readonly v: number; }
export interface BadError { readonly kind: "bad"; readonly at: number; }
export function f(xs: readonly (P | null)[]): readonly number[] {
  return xs.map((p) => {
    if (p === null) { throw { kind: "bad", at: 0 } as BadError; }
    return p.v;
  });
}
`,
  },
  {
    name: "a kind guard in a map callback narrows the trailing payload read",
    src: `
export type Msg = { readonly kind: "num"; readonly value: number } | { readonly kind: "none" };
export interface BadError { readonly kind: "bad"; readonly at: number; }
export function f(xs: readonly Msg[]): readonly number[] {
  return xs.map((m) => {
    if (m.kind !== "num") { throw { kind: "bad", at: 0 } as BadError; }
    return m.value;
  });
}
`,
  },
  {
    // The early-return spelling lifts as a labeled value block whose whole
    // body already shares one scope; pinned so the two lifting paths keep
    // agreeing on where a prefix guard's narrowing ends.
    name: "an early-return guard in a map callback narrows the trailing return too",
    src: `
export interface P { readonly v: number; }
export function f(xs: readonly (P | null)[]): readonly number[] {
  return xs.map((p) => {
    if (p === null) { return -1; }
    return p.v;
  });
}
`,
  },
];

// tsc evaluates a do-while's condition AFTER the body and carries the
// body's flow state into it: a terminal guard in the body narrows the
// trailing test. The `while (true)` + trailing-exit-test lowering emits the
// body list and the lowered `if (!(cond)) break;` inside ONE narrowing
// scope, restored only at the loop boundary — a restore between them strips
// the narrow before the read it covers. The first-pass-flag form (a body
// binding `continue`) instead hoists the test ahead of the body, where the
// condition reads the live optional: the continue edge carries kills into
// the test, so tsc widens it there (the bare read is a TS18047 the checker
// already rejects — pinned in emitter.test.ts).
const doWhileTrailingTestCases: Case[] = [
  {
    // The regression repro: transpile reported success while the emitted
    // trailing test read the raw `?P`.
    name: "a terminal guard in a do-while body narrows the trailing test",
    src: `
export interface P { readonly v: number; }
export function g(q: P | null): number {
  let n = 0;
  const p: P | null = q;
  do {
    if (p === null) return -1;
    n += p.v;
    n += 1;
  } while (p.v > 0 && n < 10);
  return n;
}
`,
  },
  {
    // A capture that serves ONLY the trailing test: the follower walk must
    // see the condition, or the guard binds no capture and the test reads
    // the raw optional; and having bound one, the test must use it (an
    // unused Zig const is a compile error).
    name: "a do-while guard read only by the trailing test still binds its capture",
    src: `
export interface P { readonly v: number; }
export function g(q: P | null): number {
  let n = 0;
  const p: P | null = q;
  do {
    if (p === null) return -1;
    n += 1;
  } while (p.v > n);
  return n;
}
`,
  },
  {
    // Back-edge semantics: the body-top read on the second iteration
    // arrives via the back edge, which re-narrowed after the kill — tsc
    // accepts the join of the pre-loop and end-of-body narrows, and the
    // live `.?` read keeps the reassigned slot's value. The end-of-body
    // guard's narrow must still reach the trailing test.
    name: "a do-while body kill re-narrowed before the trailing test",
    src: `
export interface P { readonly v: number; }
export function g(q: P | null, r: P | null): number {
  let p: P | null = q;
  if (p === null) return -1;
  let n = 0;
  do {
    n += p.v;
    p = r;
    if (p === null) return -1;
  } while (p.v > 0 && n < 10);
  return n;
}
`,
  },
  {
    // Kill + continue: the continue edge jumps TO the test carrying the
    // kill, so tsc widens the condition and the lowering must read the
    // live optional in the hoisted first-pass head.
    name: "a do-while continue-carried kill leaves the test on the live optional",
    src: `
export interface P { readonly v: number; }
export function g(q: P | null, r: P | null): number {
  let p: P | null = q;
  let n = 0;
  do {
    if (p === null) return -1;
    n += p.v;
    if (n < 3) {
      p = r;
      continue;
    }
    n += 1;
  } while (p !== null && p.v > 0 && n < 10);
  return n;
}
`,
  },
  {
    // Kill + break: the break edge SKIPS the test, so the fall-through
    // narrow stays on the condition, and the kill lands only on the
    // post-loop state (where the read must re-guard the live optional).
    name: "a do-while kill+break arm keeps the test narrowed and widens post-loop",
    src: `
export interface P { readonly v: number; }
export function g(q: P | null, r: P | null): number {
  let p: P | null = q;
  if (p === null) return -1;
  let n = 0;
  do {
    n += p.v;
    if (n > 3) {
      p = r;
      break;
    }
    n += 1;
  } while (p.v < 100);
  return p === null ? -2 : p.v;
}
`,
  },
  {
    // Nested do-whiles sharing one narrowed outer target: the inner body
    // and inner test read the outer guard's capture, and the outer test
    // still sees it after the inner loop's scope closes.
    name: "nested do-whiles share a narrowed outer target through both tests",
    src: `
export interface P { readonly v: number; }
export function g(q: P | null): number {
  const p: P | null = q;
  let n = 0;
  do {
    if (p === null) return -1;
    let m = 0;
    do {
      n += p.v;
      m += 1;
    } while (p.v > 0 && m < 2);
  } while (p.v > n);
  return n;
}
`,
  },
];

// Terminality must read constructs the way tsc's CFA does, not clause by
// clause or wrapper by wrapper: stacked case labels share the next
// statement-bearing clause's body (JS falls through empty clauses; the
// switch emitters coalesce the labels into one arm), and a label adds
// exactly one edge — `break label` resumes right after the labeled
// statement. Judging a stacked clause empty-handed or a labeled statement
// as never-terminal merges kills from branches that cannot reach the
// merge, stripping the surviving flow of a narrowing tsc keeps there —
// and the read emits raw optional arithmetic Zig rejects.
const terminalityGroupingCases: Case[] = [
  {
    // Stacked labels on a kind switch: every group exits, so the killing
    // branch never reaches the merge and the surviving read keeps its
    // unwrap. Judged clause by clause, the empty "inc" clause reads as
    // non-exiting and the merged kill emits `p + 1` on a raw `?f64`.
    name: "stacked case labels whose shared bodies all exit keep the branch terminal (kind switch)",
    src: `
export type Msg =
  | { readonly kind: "inc" }
  | { readonly kind: "dec" }
  | { readonly kind: "reset" };
export function f(q: number | null, flag: boolean, msg: Msg): number {
  let p: number | null = q;
  if (p === null) { return -1; }
  if (flag) {
    p = null;
    switch (msg.kind) {
      case "inc":
      case "dec":
        return 10;
      case "reset":
        return 20;
    }
  }
  return p + 1;
}
`,
  },
  {
    // The defaulted value-switch spelling of the same shape (the else
    // prong is the group tail for the trailing labels' semantics).
    name: "stacked case labels whose shared bodies all exit keep the branch terminal (defaulted value switch)",
    src: `
export type Mode = "a" | "b" | "c" | "d";
export function f(q: number | null, flag: boolean, mode: Mode): number {
  let p: number | null = q;
  if (p === null) { return -1; }
  if (flag) {
    p = null;
    switch (mode) {
      case "a":
      case "b":
        return 10;
      default:
        return 20;
    }
  }
  return p + 1;
}
`,
  },
  {
    // Non-regression: a group whose shared body does NOT exit falls out of
    // the switch, so the kill still merges and the post-branch re-check
    // reads the live slot.
    name: "a stacked group that falls out of the switch still merges its kill",
    src: `
export type Msg =
  | { readonly kind: "inc" }
  | { readonly kind: "dec" }
  | { readonly kind: "reset" };
export function f(q: number | null, flag: boolean, msg: Msg): number {
  let p: number | null = q;
  if (p === null) { return -1; }
  if (flag) {
    p = null;
    switch (msg.kind) {
      case "inc":
      case "dec":
        return 10;
      case "reset":
        p = q;
    }
  }
  if (p === null) { return 0; }
  return p + 1;
}
`,
  },
  {
    // A trailing run of empty clauses has no body at all: control falls
    // out of the switch (JS no-op labels), the branch is nonterminal, and
    // the kill merges into the re-check.
    name: "trailing empty clauses make the switch nonterminal and merge the kill",
    src: `
export type Msg =
  | { readonly kind: "inc" }
  | { readonly kind: "dec" }
  | { readonly kind: "reset" };
export function f(q: number | null, flag: boolean, msg: Msg): number {
  let p: number | null = q;
  if (p === null) { return -1; }
  if (flag) {
    p = null;
    switch (msg.kind) {
      case "inc":
        return 10;
      case "dec":
      case "reset":
    }
  }
  if (p === null) { return 0; }
  return p + 1;
}
`,
  },
  {
    // An empty clause before `default` shares the default's body in JS,
    // but the emitters have no clean arm mapping for that shape and stop
    // with the fall-into-default teaching.
    name: "an empty case falling into default gates at emission",
    gate: "NS9001",
    src: `
export type Mode = "a" | "b" | "c";
export function f(mode: Mode): number {
  switch (mode) {
    case "a":
      return 1;
    case "b":
    default:
      return 2;
  }
}
`,
  },
  {
    // A label is not a break: the constant-true loop under it still never
    // completes, so the killing branch leaves the function and the
    // surviving read keeps its unwrap. Judged as a bare LabeledStatement,
    // the branch reads nonterminal and the merged kill emits `p + 1` on a
    // raw `?f64`.
    name: "a labeled constant-true loop with no break to the label stays terminal",
    src: `
export function f(q: number | null, flag: boolean): number {
  let p: number | null = q;
  if (p === null) { return -1; }
  if (flag) {
    p = null;
    spin: while (true) {}
  }
  return p + 1;
}
`,
  },
  {
    // Non-regression: a break naming the label makes the loop's end
    // reachable — the killing branch DOES reach the merge, so the
    // post-branch re-check must read the live slot.
    name: "a break to the label carries the kill past the labeled loop",
    src: `
export function f(q: number | null, flag: boolean): number {
  let p: number | null = q;
  if (p === null) { return -1; }
  if (flag) {
    p = null;
    spin: while (true) {
      if (flag) { break spin; }
    }
  }
  if (p === null) { return 0; }
  return p + 1;
}
`,
  },
  {
    // A labeled block whose statement list exits, with no break to the
    // label, is as terminal as the bare block.
    name: "a labeled terminal block with no break to the label stays terminal",
    src: `
export function f(q: number | null, flag: boolean): number {
  let p: number | null = q;
  if (p === null) { return -1; }
  if (flag) {
    p = null;
    blk: {
      return 5;
    }
  }
  return p + 1;
}
`,
  },
  {
    // ... and one break to the label re-opens the block's end: the kill
    // merges and the re-check reads the live slot.
    name: "a break to the label re-opens a labeled block's end and merges the kill",
    src: `
export function f(q: number | null, flag: boolean): number {
  let p: number | null = q;
  if (p === null) { return -1; }
  if (flag) {
    p = null;
    blk: {
      if (flag) { break blk; }
      return 5;
    }
  }
  if (p === null) { return 0; }
  return p + 1;
}
`,
  },
];

// A value switch without a `default` is still terminal when its case labels
// cover the scrutinee's literal-union type — tsc's own exhaustiveness
// judgment, which its CFA uses to keep a narrowing past a branch that ends
// in such a switch. Reading the defaultless switch as nonterminal merges
// kills from branches that cannot reach the merge and emits raw optional
// arithmetic Zig rejects. The consult stays on literal-union scrutinees
// (string/number/boolean literals) with literal case labels; anything wider
// keeps the conservative merge. The lowering already closes the
// never-reached fallthrough (string enums emit a Zig-exhaustive switch with
// no else; numeric aliases emit `else => unreachable`), so the terminality
// claim and the emitted shape agree.
const valueSwitchExhaustivenessCases: Case[] = [
  {
    // Every member has its own exiting case: the killing branch never
    // reaches the merge, so the surviving read keeps its unwrap. Judged
    // defaultless-therefore-nonterminal, the merged kill emits `p + 1` on
    // a raw `?f64`.
    name: "a defaultless value switch covering every union member keeps the branch terminal",
    src: `
export type Mode = "a" | "b" | "c";
export function f(q: number | null, flag: boolean, mode: Mode): number {
  let p: number | null = q;
  if (p === null) { return -1; }
  if (flag) {
    p = null;
    switch (mode) {
      case "a":
        return 1;
      case "b":
        return 2;
      case "c":
        return 3;
    }
  }
  return p + 1;
}
`,
  },
  {
    // Coverage counts stacked labels through their shared body: a stacked
    // group plus a separate case covers all three members.
    name: "exhaustiveness coverage reads stacked labels alongside separate cases",
    src: `
export type Mode = "a" | "b" | "c";
export function f(q: number | null, flag: boolean, mode: Mode): number {
  let p: number | null = q;
  if (p === null) { return -1; }
  if (flag) {
    p = null;
    switch (mode) {
      case "a":
      case "b":
        return 10;
      case "c":
        return 20;
    }
  }
  return p + 1;
}
`,
  },
  {
    // Non-regression: one member uncovered means the switch may be skipped
    // entirely — the kill merges and the re-check reads the live slot.
    name: "a value switch leaving one member uncovered still merges its kill",
    src: `
export type Mode = "a" | "b" | "c";
export function f(q: number | null, flag: boolean, mode: Mode): number {
  let p: number | null = q;
  if (p === null) { return -1; }
  if (flag) {
    p = null;
    switch (mode) {
      case "a":
      case "b":
        return 10;
    }
  }
  if (p === null) { return 0; }
  return p + 1;
}
`,
  },
  {
    // A plain string scrutinee has no enumerable members: the consult
    // answers conservatively and the kill merges.
    name: "a switch on a plain string stays conservative and merges the kill",
    src: `
export function f(q: number | null, flag: boolean, s: string): number {
  let p: number | null = q;
  if (p === null) { return -1; }
  if (flag) {
    p = null;
    switch (s) {
      case "x":
        return 10;
      case "y":
        return 20;
    }
  }
  if (p === null) { return 0; }
  return p + 1;
}
`,
  },
  {
    // Boolean literal unions are enumerable to the exhaustiveness consult
    // (case true + case false covers `boolean`), but the v1 switch
    // lowerings have no boolean-scrutinee mapping, so the shape gates at
    // emission before terminality can matter end to end.
    name: "a switch on a boolean scrutinee gates at emission",
    gate: "NS9001",
    src: `
export function f(q: number | null, flag: boolean): number {
  let p: number | null = q;
  if (p === null) { return -1; }
  switch (flag) {
    case true:
      return 1;
    case false:
      return 2;
  }
}
`,
  },
  {
    // Numeric literal unions enumerate the same way; the lowering closes
    // the integer scrutinee's required else arm with `unreachable`.
    name: "a defaultless numeric-literal-union switch covering every member keeps the branch terminal",
    src: `
export type Level = 0 | 1 | 2;
export function f(q: number | null, flag: boolean, lvl: Level): number {
  let p: number | null = q;
  if (p === null) { return -1; }
  if (flag) {
    p = null;
    switch (lvl) {
      case 0:
      case 1:
        return 10;
      case 2:
        return 20;
    }
  }
  return p + 1;
}
`,
  },
  {
    // The emission/terminality agreement case: an exhaustive defaultless
    // switch as a function's final statement must leave Zig no reachable
    // missing-return path.
    name: "an exhaustive defaultless value switch may end a value-returning function",
    src: `
export type Mode = "a" | "b" | "c";
export function f(mode: Mode): number {
  switch (mode) {
    case "a":
    case "b":
      return 10;
    case "c":
      return 20;
  }
}
export type Level = 0 | 1 | 2;
export function g(lvl: Level): number {
  switch (lvl) {
    case 0:
      return 1;
    case 1:
    case 2:
      return 2;
  }
}
`,
  },
];

// The exhaustiveness consult must never trust a flow type a callback
// assignment can falsify: tsc keeps `k` narrowed to "a" across
// `xs.map(() => { k = "b"; })` (it never widens locals for nested-function
// assignments), so judging coverage by the flow type claims terminality for
// a switch real execution skips — and the aligned lowering closes the
// skipped fallthrough with an `else => unreachable` execution then REACHES.
// The judgment reads the scrutinee's DECLARED union instead; a local never
// assigned inside any nested function may still keep the flow type (the
// straight-line CFA is exact for unaliased, uncaptured locals).
const flowTypeSoundnessCases: Case[] = [
  {
    // The callback-mutation repro: declared "a" | "b", flow type "a",
    // cases cover only "a". The coverage claim must decline — the kill
    // merges (the re-check below stays legal) and the lowered else
    // completes instead of trapping.
    name: "a callback-mutated scrutinee declines flow-type coverage and merges the kill",
    src: `
export type AB = "a" | "b";
export function f(q: number | null, flag: boolean, xs: readonly number[]): number {
  let p: number | null = q;
  if (p === null) return -1;
  let k: AB = "a";
  const ys = xs.map((x) => {
    k = "b";
    return x;
  });
  if (flag) {
    p = null;
    switch (k) {
      case "a":
        return 1;
    }
  }
  if (p === null) return ys.length;
  return p + 1;
}
`,
  },
  {
    // The precise middle, pinned: flow narrowing on a local no nested
    // function assigns still claims coverage — the guard's exclusion holds
    // on every real path, the branch stays terminal, and the killing
    // branch's kill never reaches the merge (the unguarded read compiles).
    name: "flow-narrowed coverage still claims for a local never assigned in a callback",
    src: `
export type Mode = "a" | "b" | "c";
export function f(q: number | null, flag: boolean, mode: Mode): number {
  let p: number | null = q;
  if (p === null) return -1;
  if (mode === "c") return 30;
  if (flag) {
    p = null;
    switch (mode) {
      case "a":
        return 1;
      case "b":
        return 2;
    }
  }
  return p + 1;
}
`,
  },
  {
    // A callback assignment elsewhere in the function demotes even a
    // DECLARED-uncovered flow claim: with "c" excluded by the guard but k
    // assignable by the callback, only the declared union may judge — it
    // is not covered, so the kill merges and the re-check stays legal.
    name: "a callback assignment demotes flow-narrowed coverage to the declared union",
    src: `
export type Mode = "a" | "b" | "c";
export function f(q: number | null, flag: boolean, mode: Mode, xs: readonly number[]): number {
  let p: number | null = q;
  if (p === null) return -1;
  let k: Mode = mode;
  const ys = xs.map((x) => {
    k = "c";
    return x;
  });
  if (k === "c") return 30;
  if (flag) {
    p = null;
    switch (k) {
      case "a":
        return 1;
      case "b":
        return 2;
    }
  }
  if (p === null) return ys.length;
  return p + 1;
}
`,
  },
  {
    // Declared-union coverage stays sound whatever any callback does: all
    // members armed and exiting keeps the branch terminal and the merge
    // kill dropped (the unguarded read compiles).
    name: "declared-union coverage keeps terminality despite a callback assignment",
    src: `
export type AB = "a" | "b";
export function f(q: number | null, flag: boolean, ab: AB, xs: readonly number[]): number {
  let p: number | null = q;
  if (p === null) return -1;
  let k: AB = ab;
  const ys = xs.map((x) => {
    k = "b";
    return x;
  });
  if (flag) {
    p = null;
    switch (k) {
      case "a":
        return 1 + ys.length;
      case "b":
        return 2;
    }
  }
  return p + 1;
}
`,
  },
];

// finallyEntryKills counts exactly the may-assigns tsc's CFA counts. Two
// pinned exclusions (probed against the checker provider): code under a
// keyword-literal constant condition tsc treats as unreachable, and nested
// function/callback bodies (tsc keeps the finally narrowed even when a
// callback defined in the try assigns the target). Counting either kills a
// narrow tsc typed the finally's reads with and emits member access on a
// raw optional — invalid Zig.
const finallyStaticExclusionCases: Case[] = [
  {
    // The repro: `if (false) p = null` is unreachable to tsc, so the
    // finally still types `p.v` against the narrow — the emitted read must
    // keep its substitution.
    name: "an if-false assignment in a try never kills the finally's narrow",
    src: `
export interface P { readonly v: number; }
export function f(q: P | null): number {
  let p: P | null = q;
  if (p === null) return -1;
  let n = 0;
  try {
    if (false) p = null;
    n += 1;
  } finally {
    n += p.v;
  }
  return n;
}
`,
  },
  {
    // The else of a constant-true if is equally unreachable to tsc.
    name: "the else of an if-true in a try never kills the finally's narrow",
    src: `
export interface P { readonly v: number; }
export function f(q: P | null): number {
  let p: P | null = q;
  if (p === null) return -1;
  let n = 0;
  try {
    if (true) {
      n += 1;
    } else {
      p = null;
    }
  } finally {
    n += p.v;
  }
  return n;
}
`,
  },
  {
    // A while-false body never runs under tsc's CFA either.
    name: "a while-false body in a try never kills the finally's narrow",
    src: `
export interface P { readonly v: number; }
export function f(q: P | null): number {
  let p: P | null = q;
  if (p === null) return -1;
  let n = 0;
  try {
    while (false) {
      p = null;
    }
    n += 1;
  } finally {
    n += p.v;
  }
  return n;
}
`,
  },
  {
    // A callback defined in the try assigning the target does not widen
    // tsc's finally typing (probed — called or not), so the scan must not
    // descend into nested function bodies.
    name: "a callback assignment inside a try never kills the finally's narrow",
    src: `
export interface P { readonly v: number; }
export function f(q: P | null, xs: readonly number[]): number {
  let p: P | null = q;
  if (p === null) return -1;
  let n = 0;
  try {
    const ys = xs.map((x) => {
      p = null;
      return x;
    });
    n += ys.length;
  } finally {
    n += p.v;
  }
  return n;
}
`,
  },
  {
    // Non-regression: a genuinely conditional assignment still widens the
    // finally (tsc's path-insensitive may-assign), so the finally must
    // re-guard its read — the kill must still land.
    name: "a flag-conditional assignment in a try still kills the finally's narrow",
    src: `
export interface P { readonly v: number; }
export function f(q: P | null, flag: boolean): number {
  let p: P | null = q;
  if (p === null) return -1;
  let n = 0;
  try {
    if (flag) p = null;
    n += 1;
  } finally {
    if (p !== null) {
      n += p.v;
    }
  }
  return n;
}
`,
  },
];

// A guarded capture serves READS only: the bare target of a plain `=`
// assignment writes the raw slot, never the capture, so an arm that only
// writes the guarded local must decline the capture form (a Zig capture
// nothing consumes is an unused-capture error). Compound assignments and
// `++`/`--` read the slot and still gate the capture on.
const writeOnlyArmCaptureCases: Case[] = [
  {
    // The repro: the hit arm's only occurrence of `p` is a callback's
    // plain assignment — no read, so no capture; the plain `!= null`
    // comparison keeps the ternary valid.
    name: "a write-only ternary hit arm declines the capture",
    src: `
export interface P { readonly v: number; }
export function f(q: P | null, xs: readonly number[]): number {
  let p: P | null = q;
  return p !== null ? xs.map((x) => { p = null; return x; }).length : 0;
}
`,
  },
  {
    // The `=== null` dual: TS narrows the ELSE arm, so the same read-aware
    // judgment gates that side's capture.
    name: "a write-only ternary miss-arm dual declines the capture",
    src: `
export interface P { readonly v: number; }
export function f(q: P | null, xs: readonly number[]): number {
  let p: P | null = q;
  return p === null ? 0 : xs.map((x) => { p = null; return x; }).length;
}
`,
  },
  {
    // Non-regression: an arm that READS the target still binds the capture
    // (and the unwrapped read consumes it).
    name: "a reading ternary arm still binds the capture",
    src: `
export interface P { readonly v: number; }
export function f(q: P | null): number {
  return q !== null ? q.v : 0;
}
`,
  },
  {
    // A guarded while-chain whose body only writes the target takes the
    // same judgment: no read, no capture.
    name: "a write-only guarded while body declines the capture",
    src: `
export interface P { readonly v: number; }
export function f(q: P | null, flag: boolean): number {
  let p: P | null = q;
  let n = 0;
  while (p !== null && n < 3) {
    p = null;
    n += 1;
  }
  return n;
}
`,
  },
];

// Branch arms tsc's CFA excludes (tscExcludedArm: bare keyword-literal
// conditions only) contribute NO kills to the branch join — the same
// judgment the finally-entry scan applies. The arm still emits (Zig
// compiles `if (false)` fine); only the flow bookkeeping skips it. A kill
// from such an arm would strip a narrow tsc typed the fall-through reads
// with, emitting member access on a raw optional — invalid Zig.
const staticBranchJoinCases: Case[] = [
  {
    // The repro: tsc keeps `p` narrowed past `if (false) p = null`, so the
    // fall-through read must keep its unwrap.
    name: "an if-false arm's kill never reaches the branch join",
    src: `
export interface P { readonly v: number; }
function make(a: number): P | null {
  if (a < 0) return null;
  return { v: a };
}
export function f(a: number): number {
  let p: P | null = make(a);
  if (p === null) return -1;
  if (false) p = null;
  return p.v;
}
`,
  },
  {
    // The else of a constant-true if is equally excluded.
    name: "an if-true else arm's kill never reaches the branch join",
    src: `
export interface P { readonly v: number; }
function make(a: number): P | null {
  if (a < 0) return null;
  return { v: a };
}
export function f(a: number): number {
  let p: P | null = make(a);
  if (p === null) return -1;
  let n = 0;
  if (true) {
    n += 1;
  } else {
    p = null;
  }
  return n + p.v;
}
`,
  },
  {
    // A while-false body never runs under tsc's CFA.
    name: "a while-false body's kill never reaches the post-loop state",
    src: `
export interface P { readonly v: number; }
function make(a: number): P | null {
  if (a < 0) return null;
  return { v: a };
}
export function f(a: number): number {
  let p: P | null = make(a);
  if (p === null) return -1;
  while (false) {
    p = null;
  }
  return p.v;
}
`,
  },
  {
    // The distinction: a do-while(false) body runs ONCE (the test follows
    // the body), so its kill DOES count — tsc widens, the source re-guards,
    // and the emitted read re-checks. (The kill stays conditional: a
    // definite `p = null` would leave tsc typing the fall-through read
    // against `never`.)
    name: "a do-while-false body's kill still counts (the body runs once)",
    src: `
export interface P { readonly v: number; }
function make(a: number): P | null {
  if (a < 0) return null;
  return { v: a };
}
export function f(a: number): number {
  let p: P | null = make(a);
  if (p === null) return -1;
  do {
    if (a > 2) p = null;
  } while (false);
  if (p === null) return -2;
  return p.v;
}
`,
  },
  {
    // Non-regression: a genuinely conditional kill still joins (tsc's
    // path-insensitive may-assign), so the fall-through read re-guards.
    name: "a flag-conditional kill still reaches the branch join",
    src: `
export interface P { readonly v: number; }
function make(a: number): P | null {
  if (a < 0) return null;
  return { v: a };
}
export function f(a: number, flag: boolean): number {
  let p: P | null = make(a);
  if (p === null) return -1;
  if (flag) p = null;
  if (p === null) return -2;
  return p.v;
}
`,
  },
];

// Multi-alternative constructs (if/else arms, else-if chains, switch
// clauses) JOIN their assignment kills: every arm is an alternative from
// the construct's ENTRY state — tsc types each one as if no sibling ran —
// so one arm's kill must not strip a sibling of a narrowing tsc keeps
// there. The kills apply to the surviving flow only after the last arm.
const branchKillJoinCases: Case[] = [
  {
    // The then arm kills; the else arm is a SIBLING typed from the entry
    // state (p non-null after the guard), so its read must still unwrap.
    // A sequential merge deletes the narrow before the else arm emits and
    // the read hits the bare optional — invalid Zig.
    name: "a kill in the then arm leaves the else arm's entry narrow intact",
    src: `
export interface P { readonly v: number; }
export function f(a: P | null, flag: boolean): number {
  let p: P | null = a;
  if (p === null) return -1;
  if (flag) {
    p = null;
  } else {
    return p.v;
  }
  return 0;
}
`,
  },
  {
    // Same join across an else-if chain: the middle arm kills, the last
    // arm reads — every arm of the chain is a sibling of every other.
    name: "a kill in a middle else-if arm leaves the last arm's narrow intact",
    src: `
export interface P { readonly v: number; }
export function f(a: P | null, sel: number): number {
  let p: P | null = a;
  if (p === null) return -1;
  if (sel === 1) {
    return 1;
  } else if (sel === 2) {
    p = null;
  } else if (sel === 3) {
    return p.v;
  }
  if (p === null) return 0;
  return p.v;
}
`,
  },
  {
    // Switch clauses are pure siblings (tsc's noFallthroughCasesInSwitch
    // keeps a non-empty clause from falling into the next): a kill in an
    // earlier clause must not reach a later clause's reads, and the joined
    // kill still reaches the post-switch re-check.
    name: "a kill in one switch clause leaves a later clause's narrow intact",
    src: `
export type Msg =
  | { readonly kind: "kill" }
  | { readonly kind: "use" }
  | { readonly kind: "skip" };
export interface P { readonly v: number; }
export function f(a: P | null, msg: Msg): number {
  let p: P | null = a;
  if (p === null) return -1;
  switch (msg.kind) {
    case "kill":
      p = null;
      break;
    case "use":
      return p.v;
    case "skip":
      break;
  }
  if (p === null) return 0;
  return p.v;
}
`,
  },
  {
    // Kills travel the edges control does: an always-throwing arm's kill
    // rides the throw into the catch, so the catch body types from a state
    // where the narrow is dead (tsc kills anything the try assigns before
    // a possible throw) and its re-check reads the live slot. The
    // intra-try flow after the arm keeps the entry narrow.
    name: "a kill on an always-throwing path is dead inside the catch arm",
    src: `
export interface P { readonly v: number; }
export interface BoomError { readonly kind: "boom"; readonly at: number; }
export function f(a: P | null, flag: boolean): number {
  let p: P | null = a;
  if (p === null) return -1;
  let n = 0;
  try {
    if (flag) { p = null; throw { kind: "boom", at: 0 } as BoomError; }
    n += p.v;
  } catch (err) {
    if (p === null) {
      n += 1;
    } else {
      n += p.v;
    }
  }
  if (p === null) return n;
  return n + p.v;
}
`,
  },
];

// tsc's POST-construct narrow is the guard-implied narrow MINUS the arms'
// kills: an exiting empty-test arm narrows the code after the statement
// only on the paths that kept the value non-null. A surviving arm that
// re-assigned null buries the narrow — the post-construct install must
// subtract the joined kill set or it resurrects a `.?` spelling against a
// slot that can be null again (a comparison-with-null compile error at the
// re-check, a wrong unwrap past it).
const postNarrowKillSubtractionCases: Case[] = [
  {
    // The head arm exits (guard-implied narrow); the else-if arm kills.
    // The post-if state is unnarrowed, so the re-check reads the plain
    // optional and the read past it unwraps through the re-check.
    name: "an else-if arm's kill subtracts from the exiting guard's post-if narrow",
    src: `
export interface P { readonly v: number; }
export function f(a: P | null, flag: boolean): number {
  let p: P | null = a;
  if (p === null) return -1;
  else if (flag) {
    p = null;
  }
  if (p === null) return 0;
  return p.v;
}
`,
  },
  {
    // Same subtraction on the generic if/else tail: the else arm never
    // reads the target, so the statement routes through the generic
    // lowering and its post-if narrow application.
    name: "a kill in a non-reading else arm subtracts from the post-if narrow",
    src: `
export interface P { readonly v: number; }
export function f(a: P | null, flag: boolean): number {
  let p: P | null = a;
  let n = 0;
  if (p === null) {
    return -1;
  } else {
    if (flag) { p = null; }
    n += 1;
  }
  if (p === null) return n;
  return n + p.v;
}
`,
  },
  {
    // The reading else arm takes the capture form; its conditional kill
    // still subtracts from the miss-exit's post-if narrow.
    name: "a kill in a reading else arm subtracts from the capture form's post-if narrow",
    src: `
export interface P { readonly v: number; }
export function f(a: P | null, flag: boolean): number {
  let p: P | null = a;
  let n = 0;
  if (p === null) {
    return -1;
  } else {
    n += p.v;
    if (flag) { p = null; }
  }
  if (p === null) return n;
  return n + p.v;
}
`,
  },
  {
    // The present-test mirror: the then arm reads (capture form), the
    // else arm exits, and the then arm's kill subtracts the same way.
    name: "a kill in the present-test's then arm subtracts from the post-if narrow",
    src: `
export interface P { readonly v: number; }
export function f(a: P | null, flag: boolean): number {
  let p: P | null = a;
  let n = 0;
  if (p !== null) {
    n += p.v;
    if (flag) { p = null; }
  } else {
    return -1;
  }
  if (p === null) return n;
  return n + p.v;
}
`,
  },
  {
    // No kills anywhere: the post-if narrow still installs, and the read
    // after the statement unwraps without a re-check (non-regression for
    // the subtraction — an empty kill set must subtract nothing).
    name: "the post-if narrow still installs when no arm kills the target",
    src: `
export interface P { readonly v: number; }
export function f(a: P | null): number {
  let n = 0;
  const p = a;
  n += 1;
  if (p === null) {
    return -1;
  } else {
    n += 2;
  }
  return n + p.v;
}
`,
  },
];

// Narrowing keys are DECLARATION-qualified, so two same-named declarations
// can never collide in the narrowing maps. Emission flattens plain lexical
// blocks (a fall-through block is not a merge boundary), which leaves no
// restore point at the block's end — with raw text keys, a block-local
// shadow's entries stayed live for the OUTER name after the block, binding
// its null checks and reads to the inner declaration's capture. Callback
// parameters share the enclosing maps the same way.
const shadowedDeclarationCases: Case[] = [
  {
    // A shadow in a flattened block: the inner guard's capture must not
    // rewrite the outer q's re-check after the block (with text keys it
    // emitted a null test against the inner non-optional capture).
    name: "a block-local shadow's narrow dies with the block despite flattening",
    src: `
export interface P { readonly v: number; }
export function f(a: P | null, b: P | null): number {
  let q: P | null = a;
  let n = 0;
  {
    const q = b;
    n += 1;
    if (q === null) return -2;
    n += q.v;
  }
  if (q === null) return -1;
  return q.v + n;
}
`,
  },
  {
    // A shadow in an if-arm while the OUTER name's capture narrow is
    // active: the inner declaration's guard must bind the inner value,
    // not the outer capture.
    name: "an arm-local shadow narrows independently of the outer capture",
    src: `
export interface P { readonly v: number; }
export function f(a: P | null, b: P | null, flag: boolean): number {
  const q = a;
  let n = 0;
  n += 1;
  if (q === null) return -1;
  if (flag) {
    const q = b;
    if (q === null) return -2;
    return q.v + n;
  }
  return q.v + n;
}
`,
  },
  {
    // A callback parameter named like an actively narrowed outer local:
    // the parameter's reads must bind the loop capture, never the outer
    // one (with text keys the filter tested the outer value — code that
    // compiled and ran wrong; the run-fidelity corpus pins the behavior).
    name: "a callback parameter shadowing a narrowed outer local reads its own capture",
    src: `
export interface P { readonly v: number; }
export function f(a: P | null, xs: readonly P[]): number {
  const q = a;
  let n = 0;
  n += 1;
  if (q === null) return -1;
  const found = xs.filter((q) => q.v > 0);
  let m = 0;
  for (const g of found) m += g.v;
  return q.v + m + n;
}
`,
  },
  {
    // Two shadows deep inside nested flattened blocks: every level keys
    // its own declaration, and the outer re-check still reads the outer
    // slot.
    name: "nested block shadows two deep keep all three narrows separate",
    src: `
export interface P { readonly v: number; }
export function f(a: P | null, b: P | null, c: P | null): number {
  let q: P | null = a;
  let n = 0;
  {
    const q = b;
    n += 1;
    if (q === null) return -2;
    n += q.v;
    {
      const q = c;
      n += 1;
      if (q === null) return -3;
      n += q.v;
    }
  }
  if (q === null) return -1;
  return q.v + n;
}
`,
  },
];

const elementAccessKeyCases: Case[] = [
  {
    // Element-access narrows key like property chains: base declaration
    // plus canonical index. With text keys, the inner shadow's guard
    // capture stayed live past the flattened block and rewrote the outer
    // read (compiled clean and returned the inner element's value; the
    // run-fidelity corpus pins the values).
    name: "a shadowed declaration's element-access narrow dies with its block",
    src: `
export interface BoxOpt { readonly b: number | null; }
export function f(): number {
  const xs: BoxOpt[] = [{ b: 10 }];
  let total = 0;
  {
    const xs: BoxOpt[] = [{ b: 3 }];
    if (xs[0].b === null) return -2;
    total += xs[0].b;
  }
  if (xs[0].b === null) return -1;
  total += xs[0].b;
  return total;
}
`,
  },
  {
    // The chain composes in both directions: a property base under the
    // element access (`a.rows[0]`) and a property read off the element
    // (`...[0].b`) — the shadowed base must key its own declaration
    // through both hops.
    name: "element-of-property narrows key the base declaration through the chain",
    src: `
export interface Row { readonly b: number | null; }
export interface Grid { readonly rows: readonly Row[]; }
export function f(a: Grid, c: Grid): number {
  let total = 0;
  {
    const a = c;
    if (a.rows[0].b === null) return -2;
    total += a.rows[0].b;
  }
  if (a.rows[0].b === null) return -1;
  total += a.rows[0].b;
  return total;
}
`,
  },
  {
    // An identifier index keys the index's OWN declaration: a shadowed
    // `i` selects a different element, so the inner narrow must not
    // serve the outer read.
    name: "an identifier index keys its declaration, so a shadowed index narrows apart",
    src: `
export interface BoxOpt { readonly b: number | null; }
export function f(): number {
  const xs: BoxOpt[] = [{ b: 10 }, { b: 3 }];
  const i = 0;
  let total = 0;
  {
    const i = 1;
    if (xs[i].b === null) return -2;
    total += xs[i].b;
  }
  if (xs[i].b === null) return -1;
  total += xs[i].b;
  return total;
}
`,
  },
  {
    // A computed index is not a stable reference to one element, so it
    // has no narrowing key: the guard stays a plain test and the read
    // stays a live optional (tsc does not narrow it either).
    name: "a computed element index declines narrowing; reads stay live optionals",
    src: `
export interface BoxOpt { readonly b: number | null; }
export function f(): number {
  const xs: BoxOpt[] = [{ b: 10 }, { b: 3 }];
  let total = 0;
  if (xs[0 + 1].b !== null) {
    const v = xs[0 + 1].b;
    if (v !== null) total += v;
  }
  return total;
}
`,
  },
];

const nonNullReassignCases: Case[] = [
  {
    // tsc keeps the target narrowed through a provably non-null
    // reassignment. A capture would bind unused (every read follows the
    // assignment), so the branch takes the plain-test form and reads go
    // through the live slot.
    name: "a non-null reassignment inside the guarded branch keeps the narrow",
    src: `
export interface P { readonly v: number; }
export function f(q: P | null): number {
  let p: P | null = q;
  if (p !== null) {
    p = { v: 2 };
    return p.v;
  }
  return 0;
}
`,
  },
  {
    // Reads on both sides of the assignment: the early read consumes the
    // capture, and the substitution transitions to the live-slot spelling
    // at the assignment so the later read sees the reassigned value.
    name: "reads before and after a non-null reassignment both stay narrowed",
    src: `
export interface P { readonly v: number; }
export function f(q: P | null): number {
  let p: P | null = q;
  let total = 0;
  if (p !== null) {
    total += p.v;
    p = { v: total + 5 };
    total += p.v;
  }
  return total;
}
`,
  },
  {
    // All reads follow the assignment (several statements' worth): no
    // capture may bind, and every read goes through the live slot.
    name: "a branch whose reads all follow the reassignment binds no capture",
    src: `
export interface P { readonly v: number; }
export function f(q: P | null): number {
  let p: P | null = q;
  let total = 0;
  if (p !== null) {
    p = { v: 7 };
    total += p.v;
    total += p.v;
  }
  return total;
}
`,
  },
  {
    // A reassignment nested in an inner if: tsc keeps the target
    // non-null on both paths out of the inner statement (this case's
    // clean tsc gate pins that), so the read after it must too — the
    // live-slot spelling is the one form valid on both paths.
    name: "a conditional non-null reassignment keeps the read after it narrowed",
    src: `
export interface P { readonly v: number; }
export function f(q: P | null, flag: boolean): number {
  let p: P | null = q;
  if (p !== null) {
    if (flag) {
      p = { v: p.v + 10 };
    }
    return p.v;
  }
  return -1;
}
`,
  },
  {
    // The dual arm shape: the else branch holds the narrow and reassigns.
    name: "a non-null reassignment in the narrowed else arm keeps its reads",
    src: `
export interface P { readonly v: number; }
export function f(q: P | null): number {
  let p: P | null = q;
  if (p === null) {
    return 0;
  } else {
    p = { v: 2 };
    return p.v;
  }
}
`,
  },
  {
    // A loop body that reads and then reassigns: the back edge hands the
    // reassigned value to the next iteration's read, so the branch takes
    // the live-slot form for every read.
    name: "a loop that reassigns the narrowed target reads the live slot",
    src: `
export interface P { readonly v: number; }
export function f(q: P | null, n: number): number {
  let p: P | null = q;
  let total = 0;
  if (p !== null) {
    for (let k = 0; k < n; k++) {
      total += p.v;
      p = { v: total };
    }
  }
  return total;
}
`,
  },
  {
    // Reassignment to a possibly-null value still kills the narrow —
    // the read must re-guard, and the re-guard binds its own capture.
    name: "a possibly-null reassignment still kills the narrow",
    src: `
export interface P { readonly v: number; }
export function f(q: P | null, r: P | null): number {
  let p: P | null = q;
  if (p !== null) {
    p = r;
    if (p !== null) {
      return p.v;
    }
  }
  return 0;
}
`,
  },
];

const corpus: Case[] = [
  ...branchKillJoinCases,
  ...postNarrowKillSubtractionCases,
  ...shadowedDeclarationCases,
  ...elementAccessKeyCases,
  ...nonNullReassignCases,
  ...exitGuardNarrowingCases,
  ...kindNarrowRestoreCases,
  ...narrowInvalidationMergeCases,
  ...killFallthroughCases,
  ...edgeKillStagingCases,
  ...finallyFlowOrderCases,
  ...catchRouteKillCases,
  ...callbackTrailingNarrowCases,
  ...doWhileTrailingTestCases,
  ...terminalityGroupingCases,
  ...valueSwitchExhaustivenessCases,
  ...flowTypeSoundnessCases,
  ...finallyStaticExclusionCases,
  ...writeOnlyArmCaptureCases,
  ...staticBranchJoinCases,
  ...textMethodCases,
  ...releaseModeCases,
  ...completeLangTier2Cases,
  ...dataClassCases,
  ...exceptionCases,
  ...enumCases,
  ...numberCases,
  ...structuralCases,
  ...cmdCases,
  ...cmdV2Cases,
  ...namedOpCases,
  ...contractCases,
  ...bindingSurfaceCases,
  ...stackedUnionCases,
  ...iterationCases,
  ...builderSortCases,
  ...localMutationCases,
  ...mathAndTableCases,
  ...arrayStaticCases,
  ...modelTierCases,
  ...streamingCases,
  ...grammarCases,
  ...ternarySpreadArmCases,
  ...lexicalBlockFlowCases,
];

test("corpus: gated cases teach at check time, emit cases transpile clean", () => {
  for (const c of corpus) {
    const result = transpile(c.src);
    assert.equal(result.typeErrors.length, 0, `${c.name}: tsc errors\n${result.typeErrors.join("\n")}`);
    if (c.gate) {
      assert.equal(result.ok, false, `${c.name}: expected ${c.gate}, but transpile succeeded`);
      const ids = result.diagnostics.map((d) => d.id);
      assert.ok(ids.includes(c.gate), `${c.name}: expected ${c.gate}, got ${ids.join(", ") || "none"}`);
    } else {
      const details = result.diagnostics.map((d) => `${d.id} ${d.message}`).join("\n");
      assert.equal(result.ok, true, `${c.name}: transpile failed\n${details}`);
    }
  }
});

test("multi-file corpus: gated cases teach, emit cases transpile clean", () => {
  for (const c of multiFileCases) {
    const result = transpileFiles(c.files);
    if (c.gate) {
      assert.equal(result.ok, false, `${c.name}: expected ${c.gate}, but transpile succeeded`);
      const ids = result.diagnostics.map((d) => d.id);
      assert.ok(ids.includes(c.gate), `${c.name}: expected ${c.gate}, got ${ids.join(", ") || "none"}`);
    } else {
      assert.equal(result.typeErrors.length, 0, `${c.name}: tsc errors\n${result.typeErrors.join("\n")}`);
      const details = result.diagnostics.map((d) => `${d.id} ${d.message}`).join("\n");
      assert.equal(result.ok, true, `${c.name}: transpile failed\n${details}`);
      // The staleness contract: every module of the graph is an input.
      assert.ok(result.inputs.length >= Object.keys(c.files).length, `${c.name}: inputs missing (${result.inputs.length})`);
    }
  }
});

test("private cross-file collisions take a per-module prefix in the emitted Zig", () => {
  const c = multiFileCases.find((x) => x.name.includes("PRIVATE helpers"))!;
  const result = transpileFiles(c.files);
  assert.equal(result.ok, true);
  // One `scale` keeps its name (first claim); the other gets `b_scale`.
  assert.ok(result.zig!.includes("fn scale("), "first claimer keeps its spelling");
  assert.ok(result.zig!.includes("fn b_scale("), `the collider takes the module prefix:\n${result.zig}`);
  assert.ok(result.zig!.includes("b_scale(n)"), "references land on the prefixed name");
});

test("corpus: emitted Zig always compiles", { skip: !hasZig, timeout: 600_000 }, () => {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "native-core-conformance-"));
  try {
    fs.copyFileSync(path.join(pkg, "rt", "rt.zig"), path.join(work, "rt.zig"));
    const imports: string[] = [];
    corpus.forEach((c, i) => {
      if (c.gate) return;
      const result = transpile(c.src);
      assert.equal(result.ok, true, `${c.name}: transpile failed before the zig step`);
      const file = `case_${String(i).padStart(2, "0")}.zig`;
      fs.writeFileSync(path.join(work, file), result.zig!);
      imports.push(`    // ${c.name}\n    refAllDecls(@import("${file}"));`);
    });
    multiFileCases.forEach((c, i) => {
      if (c.gate) return;
      const result = transpileFiles(c.files);
      assert.equal(result.ok, true, `${c.name}: transpile failed before the zig step`);
      const file = `multi_${String(i).padStart(2, "0")}.zig`;
      fs.writeFileSync(path.join(work, file), result.zig!);
      imports.push(`    // ${c.name}\n    refAllDecls(@import("${file}"));`);
    });
    const driver = [
      `// Generated driver: reference every public decl of every emitted core so`,
      `// the compiler semantically analyzes all of them (nothing runs).`,
      `const refAllDecls = @import("std").testing.refAllDecls;`,
      ``,
      `test {`,
      ...imports,
      `}`,
      ``,
    ].join("\n");
    fs.writeFileSync(path.join(work, "driver.zig"), driver);
    // Both optimize modes, because they analyze differently: the wave-2
    // release-only miscompiles (comptime-only enum literals under runtime
    // control flow; @memcpy into a `[]const u8` parameter) surfaced only
    // when an app's ReleaseFast build was the first release-mode analysis
    // the emitted core ever got.
    for (const mode of [[], ["-OReleaseFast"]] as const) {
      try {
        execFileSync("zig", ["test", ...mode, "driver.zig"], { cwd: work, encoding: "utf8", stdio: "pipe" });
      } catch (e) {
        const err = e as { stderr?: string; stdout?: string };
        assert.fail(`emitted Zig failed to compile (${mode[0] ?? "Debug"}):\n${err.stderr ?? ""}${err.stdout ?? ""}`);
      }
    }
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
});

test("NS1028: Cmd.persist still compiles but teaches the writeFile path as a warning", () => {
  const result = transpile(`
import { Cmd } from "@native-sdk/core";
export interface Model { readonly count: number; }
export type Msg = { readonly kind: "add" } | { readonly kind: "noop" };
export function initialModel(): Model { return { count: 0 }; }
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "add": return [{ count: model.count + 1 }, Cmd.persist()];
    case "noop": return model;
  }
}
`);
  // The warning never gates: the op compiles, emits its wire record, and
  // the notice rides the separate channel.
  assert.equal(result.ok, true, "persist must keep compiling");
  assert.equal(result.diagnostics.length, 0);
  const w = result.warnings.find((d) => d.id === "NS1028");
  assert.ok(w, "reports NS1028 as a warning");
  assert.ok(w.message.includes("writeFile"), "points at the writeFile path");
  assert.ok(result.zig!.includes("rt.cmdPersist()"), "wire support stays");
});

test("NS1016 speaks in rule, fix, and why", () => {
  const result = transpile(`
export function read(bytes: Uint8Array): number {
  let i = 0;
  i = 1.5;
  return bytes[i];
}
`);
  assert.equal(result.ok, false);
  const d = result.diagnostics.find((x) => x.id === "NS1016");
  assert.ok(d, "reports NS1016");
  assert.ok(d.message.includes("must be an integer"), "names the conflict");
  assert.ok(d.message.toLowerCase().includes("machine type"), "says why");
});
