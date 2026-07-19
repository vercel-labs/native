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

// The image-load fixture: the fourteen-state union and the five-field
// result arm imageLoad routes (id echoes the requested ImageId).
const imageMsg = `
export type ImageState =
  | "loaded" | "rejected" | "not_found" | "io_failed" | "connect_failed"
  | "tls_failed" | "protocol_failed" | "timed_out" | "http_status"
  | "cancelled" | "too_large" | "unsupported" | "decode_failed" | "registry_full";
export interface Model { readonly w: number; readonly errs: number; }
export type Msg =
  | { readonly kind: "go"; readonly which: number }
  | { readonly kind: "image_done"; readonly id: number; readonly state: ImageState; readonly width: number; readonly height: number; readonly status: number };
export function initialModel(): Model { return { w: 0, errs: 0 }; }
`;

const imageTail = `
    case "image_done": return msg.state === "loaded" ? { ...model, w: msg.width } : { ...model, errs: model.errs + 1 };
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
    name: "the window verbs emit in their documented shapes",
    src: `
import { Cmd } from "@native-sdk/core";
${streamMsg}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go":
      if (msg.which === 0) return [model, Cmd.showWindow("player")];
      if (msg.which === 1) return [model, Cmd.batch([Cmd.showWindow("player"), Cmd.quitApp()])];
      return [model, Cmd.quitApp()];
${streamTail}
`,
  },
  {
    name: "a dynamic showWindow label is taught (window labels are declarations)",
    gate: "NS1027",
    src: `
import { Cmd } from "@native-sdk/core";
${streamMsg}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": {
      const label = msg.which === 0 ? "player" : "settings";
      return [model, Cmd.showWindow(label)];
    }
${streamTail}
`,
  },
  {
    // The wire's label length prefix counts BYTES: 100 CJK characters
    // are 100 UTF-16 code units but 300 UTF-8 bytes, so the 255-byte
    // teaching must fire on the byte count, not on \`.length\`.
    name: "a showWindow label over 255 UTF-8 bytes is taught (100 CJK chars = 300 bytes)",
    gate: "NS9001",
    src: `
import { Cmd } from "@native-sdk/core";
${streamMsg}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go":
      return [model, Cmd.showWindow("${"音".repeat(100)}")];
${streamTail}
`,
  },
  {
    // The under-bound twin: a multibyte label whose BYTE length fits
    // (250 bytes) emits and compiles — the byte gate must not over-refuse.
    name: "a multibyte showWindow label under 255 bytes emits (250 UTF-8 bytes)",
    src: `
import { Cmd } from "@native-sdk/core";
${streamMsg}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go":
      return [model, Cmd.showWindow("${"音".repeat(83)}x")];
${streamTail}
`,
  },
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
  {
    name: "imageLoad emits in its documented shapes (path, url+cache, model-expression ids)",
    src: `
import { Cmd, asciiBytes } from "@native-sdk/core";
${imageMsg}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go":
      if (msg.which === 0) return [model, Cmd.imageLoad(7, { path: asciiBytes("art/cover.png") }, { event: "image_done" })];
      if (msg.which === 1) return [model, Cmd.imageLoad(model.w + 1, { url: asciiBytes("https://cdn.test/a.png"), cachePath: asciiBytes("cache/a.png"), expectedBytes: 2048 }, { event: "image_done" })];
      return [model, Cmd.imageLoad(9, { path: asciiBytes("art/b.png"), url: asciiBytes("https://cdn.test/b.png") }, { event: "image_done" })];
${imageTail}
`,
  },
  {
    name: "an image result arm whose state union misses a member is taught",
    gate: "NS1027",
    src: `
import { Cmd, asciiBytes, type ImageEventKind } from "@native-sdk/core";
export type NarrowState = "loaded" | "rejected" | "decode_failed";
export interface Model { readonly w: number; readonly errs: number; }
export type Msg =
  | { readonly kind: "go"; readonly which: number }
  | { readonly kind: "image_done"; readonly id: number; readonly state: NarrowState; readonly width: number; readonly height: number; readonly status: number };
export function initialModel(): Model { return { w: 0, errs: 0 }; }
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.imageLoad(7, { path: asciiBytes("a.png") }, { event: "image_done" as ImageEventKind<Msg> })];
    case "image_done": return { ...model, w: msg.width };
  }
}
`,
  },
  {
    name: "an image result arm with a wrong field shape is taught",
    gate: "NS1027",
    src: `
import { Cmd, asciiBytes, type ImageEventKind } from "@native-sdk/core";
${imageMsg}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.imageLoad(7, { path: asciiBytes("a.png") }, { event: "go" as ImageEventKind<Msg> })];
${imageTail}
`,
  },
  {
    name: "an image source without a path or url is taught (nothing could load)",
    gate: "NS1029",
    src: `
import { Cmd, asciiBytes } from "@native-sdk/core";
${imageMsg}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.imageLoad(7, { cachePath: asciiBytes("cache/a.png") }, { event: "image_done" })];
${imageTail}
`,
  },
  {
    name: "an image id literal the registry must refuse stops at compile time",
    gate: "NS1030",
    src: `
import { Cmd, asciiBytes } from "@native-sdk/core";
${imageMsg}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.imageLoad(0, { path: asciiBytes("a.png") }, { event: "image_done" })];
${imageTail}
`,
  },
  {
    // The id bound is exclusive at 2^53: 2^53 - 1 is the last integer
    // every tier carries exactly, so it builds.
    name: "the top image id literal (2^53 - 1) builds",
    src: `
import { Cmd, asciiBytes } from "@native-sdk/core";
${imageMsg}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.imageLoad(9007199254740991, { path: asciiBytes("a.png") }, { event: "image_done" })];
${imageTail}
`,
  },
  {
    // 2^53 aliases 2^53 + 1 in f64 — the first id the wire cannot carry
    // exactly, so the literal stops the build.
    name: "an image id literal of 2^53 stops at compile time",
    gate: "NS1030",
    src: `
import { Cmd, asciiBytes } from "@native-sdk/core";
${imageMsg}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.imageLoad(9007199254740992, { path: asciiBytes("a.png") }, { event: "image_done" })];
${imageTail}
`,
  },
  {
    // Byte counts are whole numbers: a fractional literal would
    // truncate on the host into a size the app never declared, so the
    // cache would verify every download against the wrong size and
    // re-fetch on every launch. The literal stops the build.
    name: "a fractional image expectedBytes literal stops at compile time",
    gate: "NS1030",
    src: `
import { Cmd, asciiBytes } from "@native-sdk/core";
${imageMsg}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.imageLoad(7, { url: asciiBytes("https://cdn.test/a.png"), cachePath: asciiBytes("cache/a.png"), expectedBytes: 1.5 }, { event: "image_done" })];
${imageTail}
`,
  },
  {
    name: "a whole-number image expectedBytes literal builds",
    src: `
import { Cmd, asciiBytes } from "@native-sdk/core";
${imageMsg}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.imageLoad(7, { url: asciiBytes("https://cdn.test/a.png"), cachePath: asciiBytes("cache/a.png"), expectedBytes: 4096 }, { event: "image_done" })];
${imageTail}
`,
  },
  {
    name: "imageCancel emits: the numeric-id cancel with literal and model-expression ids",
    src: `
import { Cmd, asciiBytes } from "@native-sdk/core";
${imageMsg}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go":
      if (msg.which === 0) return [model, Cmd.imageCancel(7)];
      return [model, Cmd.imageCancel(model.w + 1)];
${imageTail}
`,
  },
  {
    // The same literal gate as imageLoad: an id no load could ever park
    // under has nothing to cancel.
    name: "an imageCancel id literal the registry must refuse stops at compile time",
    gate: "NS1030",
    src: `
import { Cmd, asciiBytes } from "@native-sdk/core";
${imageMsg}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.imageCancel(0)];
${imageTail}
`,
  },
  {
    name: "the top imageCancel id literal (2^53 - 1) builds",
    src: `
import { Cmd, asciiBytes } from "@native-sdk/core";
${imageMsg}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.imageCancel(9007199254740991)];
${imageTail}
`,
  },
  {
    name: "an imageCancel id literal of 2^53 stops at compile time",
    gate: "NS1030",
    src: `
import { Cmd, asciiBytes } from "@native-sdk/core";
${imageMsg}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.imageCancel(9007199254740992)];
${imageTail}
`,
  },
  {
    name: "imageUnregister emits: the numeric-id registry release with literal and model-expression ids",
    src: `
import { Cmd, asciiBytes } from "@native-sdk/core";
${imageMsg}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go":
      if (msg.which === 0) return [model, Cmd.imageUnregister(7)];
      return [model, Cmd.imageUnregister(model.w + 1)];
${imageTail}
`,
  },
  {
    // The same literal gate as imageLoad/imageCancel: an id no load
    // could ever register under has nothing to unregister.
    name: "an imageUnregister id literal the registry must refuse stops at compile time",
    gate: "NS1030",
    src: `
import { Cmd, asciiBytes } from "@native-sdk/core";
${imageMsg}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.imageUnregister(0)];
${imageTail}
`,
  },
  {
    name: "the top imageUnregister id literal (2^53 - 1) builds",
    src: `
import { Cmd, asciiBytes } from "@native-sdk/core";
${imageMsg}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.imageUnregister(9007199254740991)];
${imageTail}
`,
  },
  {
    name: "an imageUnregister id literal of 2^53 stops at compile time",
    gate: "NS1030",
    src: `
import { Cmd, asciiBytes } from "@native-sdk/core";
${imageMsg}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.imageUnregister(9007199254740992)];
${imageTail}
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

const corpus: Case[] = [
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
