// Emitter tests: one mapping rule per case — small TS in, the rule's Zig
// shape out. Substring asserts, not golden files: the shapes are the spec.

import test from "node:test";
import assert from "node:assert/strict";
import { buildEmitter, emit, transpile } from "./helpers.ts";
import { ts } from "../src/typed_ast.ts";

test("R1 exported const number folds to pub const i64", () => {
  const zig = emit(`export const MAX_TASKS = 64;\nexport function f(n: number): number { return n & MAX_TASKS; }`);
  assert.match(zig, /pub const MAX_TASKS: i64 = 64;/);
});

test("R2 integer demand emits i64; float taint emits f64", () => {
  const zig = emit(`
export function pick(bytes: Uint8Array, i: number): number {
  return bytes[i];
}
export function scale(x: number): number {
  return x * 0.5;
}
`);
  assert.match(zig, /fn pick\(bytes: \[\]const u8, i: i64\) i64/);
  assert.match(zig, /fn scale\(x: f64\) f64/);
});

test("R2 .length widens through jlen", () => {
  const zig = emit(`export function len(bytes: Uint8Array): number { return bytes.length; }`);
  assert.match(zig, /return jlen\(bytes\);/);
});

test("R3a byte-element stores narrow with JS ToUint8 semantics; in-range literals stay bare", () => {
  const zig = emit(`
export function stamp(src: Uint8Array): Uint8Array {
  const out = new Uint8Array(src.length);
  for (let i = 0; i < src.length; i += 1) {
    out[i] = src[i];
  }
  out[0] = 10;
  return out;
}
`);
  // A computed i64 value wraps modulo 256 exactly like node's Uint8Array store.
  assert.match(zig, /= @as\(u8, @truncate\(@as\(u64, @bitCast\(/);
  // Comptime-known in-range literals coerce on their own, unchanged.
  assert.match(zig, /out\[0\] = 10;/);
});

test("R3 Uint8Array alias becomes []const u8", () => {
  const zig = emit(`export type Bytes = Uint8Array;\nexport function id(b: Bytes): Bytes { return b; }`);
  assert.match(zig, /pub const Bytes = \[\]const u8;/);
});

test("R3b SDK asciiBytes intrinsic folds a literal to rodata (recognized by identity, renames honored)", () => {
  const zig = emit(`
import { asciiBytes } from "@native-sdk/core";
export function greeting(): Uint8Array { return asciiBytes("hello"); }
`);
  assert.match(zig, /return "hello";/);
  assert.ok(!zig.includes("fn asciiBytes"), "the intrinsic body is never emitted");

  const renamed = emit(`
import { asciiBytes as ab } from "@native-sdk/core";
export function greeting(): Uint8Array { return ab("hey"); }
`);
  assert.match(renamed, /return "hey";/);
});

test("R3b a local function named asciiBytes shadows the intrinsic, not the reverse", () => {
  // A module-local fn(string): Uint8Array is no longer a blessed second
  // path: its body observes string code units and teaches NS1004.
  const result = transpile(`
export function asciiBytes(s: string): Uint8Array {
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}
export function greeting(): Uint8Array { return asciiBytes("hello"); }
`);
  assert.equal(result.ok, false);
  assert.ok(result.diagnostics.some((d) => d.id === "NS1004"), JSON.stringify(result.diagnostics));
});

test("R4 record promotion: helper record by value, model record behind *const", () => {
  const zig = emit(`
interface Range { readonly start: number; readonly end: number; }
export interface Model { readonly cursor: number; }
export function width(r: Range): number { return r.end - r.start; }
export function bump(model: Model): Model { return { cursor: model.cursor + 1 }; }
`);
  assert.match(zig, /fn width\(r: Range\) i64/);
  assert.match(zig, /fn bump\(model: \*const Model\) \*const Model/);
  assert.match(zig, /rt\.frameCreate\(Model, /);
});

test("R5 string-literal union becomes a wire-stable enum", () => {
  const zig = emit(`
export type Filter = "all" | "active" | "done";
export function next(f: Filter): Filter { return f === "all" ? "active" : "done"; }
`);
  assert.match(zig, /pub const Filter = enum\(u8\) \{ all = 0, active = 1, done = 2 \};/);
  assert.match(zig, /f == \.all/);
});

test("R5 number-literal union keeps its integer repr", () => {
  const zig = emit(`
type RunClass = 0 | 1 | 2;
export function cls(b: number): RunClass { return b === 32 ? 1 : 0; }
`);
  assert.match(zig, /const RunClass = u8;/);
});

test("R5b equality across overlapping literal unions compares tag names", () => {
  const zig = emit(`
export type Category = "food" | "travel" | "gear";
export type CategoryFilter = "all" | "food" | "travel" | "gear";
export function matches(category: Category, filter: CategoryFilter): boolean {
  return filter === "all" || category === filter;
}
`);
  assert.match(zig, /filter == \.all or tagEq\(category, filter\)/);
});

test("R5b assignment across overlapping literal unions re-tags the value", () => {
  const zig = emit(`
export type Category = "food" | "travel" | "gear";
export type CategoryFilter = "all" | "food" | "travel" | "gear";
export function asFilter(category: Category): CategoryFilter {
  return category;
}
`);
  assert.match(zig, /return tagCast\(CategoryFilter, category\);/);
});

test("R2 demand propagates across the assignment into the model field", () => {
  const zig = emit(`
export interface Model { readonly durationSeconds: number; }
export type Msg =
  | { readonly kind: "set_duration"; readonly seconds: number }
  | { readonly kind: "noop" };
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "set_duration": {
      if (msg.seconds <= 0) return model;
      return { durationSeconds: msg.seconds };
    }
    case "noop": return model;
  }
}
`);
  assert.match(zig, /durationSeconds: i64/);
});

test("R2 integer reads widen exactly inside float sites", () => {
  const zig = emit(`export function half(bytes: Uint8Array): number { return bytes.length * 0.5; }`);
  assert.match(zig, /@as\(f64, @floatFromInt\(jlen\(bytes\)\)\) \* 0\.5/);
});

test("R13c inline kind guard narrows payload access to the arm accessor", () => {
  const zig = emit(`
export type Msg = { readonly kind: "add"; readonly n: number } | { readonly kind: "zero" };
export function tally(msg: Msg, bytes: Uint8Array): number {
  let acc = 0;
  if (msg.kind === "add") acc += msg.n;
  return bytes[acc];
}
`);
  assert.match(zig, /if \(msg == \.add\) \{/);
  assert.match(zig, /acc \+= msg\.add;/);
});

test("R6 discriminated union becomes union(enum) with inline payloads", () => {
  const zig = emit(`
export type Msg =
  | { readonly kind: "add" }
  | { readonly kind: "toggle"; readonly id: number }
  | { readonly kind: "move"; readonly dx: number; readonly dy: number };
export interface Model { readonly n: number; }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "add": return { n: model.n + 1 };
    case "toggle": return { n: msg.id };
    case "move": return { n: msg.dx + msg.dy };
  }
}
export function at(model: Model, bytes: Uint8Array): number {
  return bytes[model.n];
}
`);
  assert.match(zig, /pub const Msg = union\(enum\) \{/);
  assert.match(zig, /toggle: i64,/);
  assert.match(zig, /move: struct \{ dx: i64, dy: i64 \},/);
});

test("R7 T|null becomes ?T with orelse fusion", () => {
  const zig = emit(`
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
`);
  assert.match(zig, /\?i64/);
  assert.match(zig, /const hit = find\(xs, want\) orelse return 0;/);
});

test("R7 narrowed ternaries with pure arms keep the tight if-expression and orelse forms", () => {
  const zig = emit(`
export function bump(parsed: number | null): number {
  return parsed === null ? 0 : parsed + 1;
}
export function orZero(parsed: number | null): number {
  return parsed === null ? 0 : parsed;
}
`);
  // Statement-free arms must NOT take the R17b temp lowering — the common
  // case (numbers, tags, field reads) keeps its expression emission.
  assert.match(zig, /return if \(parsed\) \|parsed_2\| parsed_2 \+ 1 else 0;/);
  assert.match(zig, /return parsed orelse 0;/);
  assert.doesNotMatch(zig, /: f64 = undefined;/);
});

test("R7 an early-exit guard whose narrowed value goes unread stays a plain null test", () => {
  const zig = emit(`
export interface Model { readonly now: number | null; readonly nowLen: number; }
export function label(model: Model): number {
  if (model.now === null) return -1;
  return model.nowLen;
}
`);
  // Capturing would bind an unused Zig const (a compile error), and the
  // read test must not match \`model.nowLen\` inside \`model.now...\`.
  assert.match(zig, /if \(model\.now == null\) return -1;/);
  assert.doesNotMatch(zig, /const now = model\.now orelse/);
});

test("R7 a reassigned let never fuses to a const; the guard keeps the live variable", () => {
  const zig = emit(`
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
`);
  // Fusing would emit \`const p = next(i) orelse continue;\` and the later
  // \`p = ...\` would be an assignment to a Zig const. The reassigned binding
  // stays a var; the guard keeps the plain null test and reads unwrap the
  // live variable.
  assert.match(zig, /var p = next\(i\);/);
  assert.match(zig, /if \(p == null\) continue;/);
  assert.match(zig, /sum \+= p\.\?\.v;/);
  assert.doesNotMatch(zig, /const p = next\(i\) orelse/);
});

test("R13 a redundant nested switch on the same subject hands back the outer capture", () => {
  const zig = emit(`
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
`);
  // The inner arm's capture (value_2) overwrites the outer arm's map entry;
  // the arm cleanup must repopulate from its snapshot, or the continuation
  // reads the inner capture after its block closed (undeclared identifier).
  assert.match(zig, /bonus = value_2 \* 2;/);
  assert.match(zig, /return value \+ bonus;/);
});

test("R7 an exiting null guard heading an else-if chain still narrows the fall-through reads", () => {
  const zig = emit(`
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
`);
  // The else-if exit path from the if emission must apply the same post-if
  // narrowing as the common tail; without it the read after the chain
  // lands on the still-optional value (Zig: optional does not support
  // field access).
  assert.match(zig, /return x\.\?\.v \+ n;/);
});

test("R7 a non-reassigned declaration adjacent to its exit guard still fuses to a const orelse", () => {
  const zig = emit(`
export interface P { readonly v: number; }
export function next(i: number): P | null {
  if (i % 2 === 0) return null;
  return { v: i };
}
export function total(n: number): number {
  let sum = 0;
  for (let i = 0; i < n; i += 1) {
    const p = next(i);
    if (p === null) continue;
    sum += p.v;
  }
  return sum;
}
`);
  assert.match(zig, /const p = next\(i\) orelse continue;/);
  assert.match(zig, /sum \+= p\.v;/);
});

test("R7c the global undefined VALUE emits the optional empty, never Zig undefined", () => {
  const zig = emit(`
export interface Task { readonly id: number; }
export function pick(tasks: readonly Task[], want: number): Task | undefined {
  if (want < 0) return undefined;
  return tasks.find((t) => t.id === want);
}
`);
  assert.match(zig, /return null;/);
  assert.doesNotMatch(zig, /return undefined;/);
});

test("R8 Math.min/max map to @min/@max", () => {
  const zig = emit(`export function clamp(a: number, b: number): number { return Math.min(a & 255, Math.max(b & 255, 0)); }`);
  assert.match(zig, /@min\(/);
  assert.match(zig, /@max\(/);
});

test("R9 bitwise ops on proven ints stay integer ops", () => {
  const zig = emit(`export function mask(b: number): number { return (b & 0xc0) === 0x80 ? 1 : 0; }`);
  assert.match(zig, /b & 192/);
  assert.match(zig, /fn mask\(b: i64\) i64/);
});

test("R9 bitwise without a range proof takes the ToInt32 wrap helpers", () => {
  const zig = emit(`
export function band(a: number, b: number): number { return a & b; }
export function bor(a: number, b: number): number { return a | b; }
export function bxor(a: number, b: number): number { return a ^ b; }
`);
  assert.match(zig, /return jsAnd\(a, b\);/);
  assert.match(zig, /return jsOr\(a, b\);/);
  assert.match(zig, /return jsXor\(a, b\);/);
});

test("optional numeric equality emits the null-safe plain operator, never an unwrap", () => {
  const zig = emit(`
export function isZero(cls: number | null): boolean { return cls === 0; }
export function nonZero(cls: number | null): boolean { return cls !== 0; }
`);
  assert.match(zig, /return cls == 0;/);
  assert.match(zig, /return cls != 0;/);
  assert.ok(!zig.includes(".?"), "no unwrap in optional comparisons");
});

test("division widens to IEEE f64 division; remainder maps to @rem", () => {
  const zig = emit(`
export function halfLen(bytes: Uint8Array): number { return bytes.length / 2; }
export function wrapAt(bytes: Uint8Array, at: number): number { return bytes[at % bytes.length]; }
`);
  assert.match(zig, /@as\(f64, @floatFromInt\(jlen\(bytes\)\)\) \/ 2/);
  assert.match(zig, /@rem\(at, jlen\(bytes\)\)/);
});

test("R8 float Math.min/max take the NaN-propagating rt helpers; Math.round maps to rt.jsRound", () => {
  const zig = emit(`
export function lo(a: number, b: number): number { return Math.min(a, b); }
export function nearest(x: number): number { return Math.round(x); }
`);
  assert.match(zig, /return rt\.jsMin\(a, b\);/);
  assert.match(zig, /return rt\.jsRound\(x\);/);
});

test("R10 reassigned let becomes var", () => {
  const zig = emit(`
export function count(bytes: Uint8Array): number {
  let n = 0;
  while (n < bytes.length && bytes[n] === 32) n += 1;
  return n;
}
`);
  assert.match(zig, /var n: i64 = 0;/);
});

test("R11 fresh buffers: alloc, memcpy set, subarray view, slice copy", () => {
  const zig = emit(`
export function build(src: Uint8Array): Uint8Array {
  const out = new Uint8Array(src.length);
  out.set(src.subarray(0, src.length), 0);
  return out;
}
export function copyHalf(src: Uint8Array, mid: number): Uint8Array {
  return src.slice(0, mid);
}
`);
  assert.match(zig, /rt\.frameAlloc\(u8, uz\(jlen\(src\)\)\)/);
  assert.match(zig, /@memcpy\(/);
  // Bytes .slice resolves its bounds like array .slice: clamped, never a trap.
  assert.match(zig, /const copy_from = rt\.sliceIndex\(src\.len, 0\);/);
  assert.match(zig, /const copy_to = @max\(copy_from, rt\.sliceIndex\(src\.len, mid\)\);/);
  assert.match(zig, /@memcpy\(copy, src\[copy_from\.\.copy_to\]\);/);
});

test("R12 if/else chain over an enum scrutinee compares tags", () => {
  const zig = emit(`
export type Dir = "left" | "right";
export function step(d: Dir): number {
  if (d === "left") return -1;
  return 1;
}
`);
  assert.match(zig, /d == \.left/);
});

test("R13 switch on kind with payload capture; R13b guard narrows", () => {
  const zig = emit(`
export type Ev = { readonly kind: "insert"; readonly text: Uint8Array } | { readonly kind: "clear" };
export function size(ev: Ev): number {
  switch (ev.kind) {
    case "insert": return ev.text.length;
    case "clear": return 0;
  }
}
export function insertLen(ev: Ev): number | null {
  if (ev.kind !== "insert") return null;
  const insertion = ev.text;
  return insertion.length;
}
`);
  assert.match(zig, /switch \(ev\) \{/);
  assert.match(zig, /\.insert => \|text\| return jlen\(text\),/);
  assert.match(zig, /if \(ev != \.insert\) return null;/);
  assert.match(zig, /ev\.insert/);
});

test("R15 object spread copies the node and overwrites fields", () => {
  const zig = emit(`
export interface Model { readonly a: number; readonly b: number; }
export function setA(model: Model, a: number): Model {
  return { ...model, a: a };
}
export function idx(model: Model, bytes: Uint8Array): number { return bytes[model.a]; }
`);
  assert.match(zig, /const out = rt\.frameCreate\(Model, model\.\*\);/);
  assert.match(zig, /out\.a = a;/);
  assert.match(zig, /return out;/);
});

test("R16/R17 array of records is []const *const; spread/map/filter lower to loops", () => {
  const zig = emit(`
export interface Task { readonly id: number; readonly done: boolean; }
export interface Model { readonly tasks: readonly Task[]; }
export function add(model: Model, t: Task): Model {
  return { ...model, tasks: [...model.tasks, t] };
}
export function toggle(model: Model, id: number): Model {
  return { ...model, tasks: model.tasks.map((t) => (t.id === id ? { ...t, done: !t.done } : t)) };
}
export function purge(model: Model): Model {
  return { ...model, tasks: model.tasks.filter((t) => !t.done) };
}
`);
  assert.match(zig, /tasks: \[\]const \*const Task/);
  assert.match(zig, /rt\.frameAlloc\(\*const Task, model\.tasks\.len \+ 1\);/);
  assert.match(zig, /for \(model\.tasks, 0\.\.\) \|t, i\| \{/);
  assert.match(zig, /for \(model\.tasks\) \|t\| \{/);
  assert.match(zig, /\[0\.\.tasks_len\]/);
});

test("R12b for...of over an array becomes a for-capture loop with break/continue", () => {
  const zig = emit(`
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
`);
  assert.match(zig, /for \(tasks\) \|t\| \{/);
  assert.match(zig, /continue;/);
  assert.match(zig, /break;/);
});

test("R12b for...of over bytes captures the u8 and widens to the slot's class", () => {
  const zig = emit(`
export function total(bytes: Uint8Array): number {
  let n = 0;
  for (const b of bytes) {
    n += b;
  }
  return n;
}
export function scaled(bytes: Uint8Array): number {
  let n = 0.0;
  for (const b of bytes) {
    n += b * 0.5;
  }
  return n;
}
`);
  assert.match(zig, /for \(bytes\) \|b_byte\| \{/);
  assert.match(zig, /const b: i64 = b_byte;/);
  assert.match(zig, /const b: f64 = @as\(f64, @floatFromInt\(b_byte\)\);/);
});

test("R12d for...of over .entries() lowers the [i, x] pair onto the indexed loop", () => {
  const zig = emit(`
export function sum(xs: readonly number[]): number {
  let total = 0;
  for (const [i, x] of xs.entries()) {
    total += x + i;
  }
  return total;
}
`);
  assert.match(zig, /for \(xs, 0\.\.\) \|x, i_idx\| \{/);
  assert.match(zig, /const i: f64 = @as\(f64, @floatFromInt\(i_idx\)\);/);
});

test("R12d .entries() beyond the [i, x] pair form keeps a tailored teach", () => {
  const result = transpile(`
export function sum(xs: readonly number[]): number {
  let total = 0;
  for (const [i] of xs.entries()) {
    total += i;
  }
  return total;
}
`);
  assert.equal(result.ok, false);
  const d = result.diagnostics.find((x) => x.id === "NS9001");
  assert.ok(d, JSON.stringify(result.diagnostics));
  assert.ok(d.message.includes("[index, element]"), d.message);
});

test("R17d find lowers to an early-exit scan yielding the optional element", () => {
  const zig = emit(`
export interface Task { readonly id: number; readonly done: boolean; }
export function firstDoneId(tasks: readonly Task[]): number {
  const hit = tasks.find((t) => t.done);
  if (hit === undefined) return -1;
  return hit.id;
}
`);
  assert.match(zig, /var found: \?Task = null;/);
  assert.match(zig, /found = t;/);
  // The `=== undefined` miss test fuses into the native orelse.
  assert.match(zig, /const hit = found orelse return -1;/);
});

test("R17d findIndex/some/every carry the JS defaults (-1, false, true)", () => {
  const zig = emit(`
export function at(xs: readonly number[], lim: number): number {
  return xs.findIndex((x) => x > lim);
}
export function any(xs: readonly number[], lim: number): boolean {
  return xs.some((x) => x > lim);
}
export function all(xs: readonly number[], lim: number): boolean {
  return xs.every((x) => x > lim);
}
`);
  assert.match(zig, /var found_at: i64 = -1;/);
  assert.match(zig, /found_at = @intCast\(i\);/);
  assert.match(zig, /var any_match = false;/);
  assert.match(zig, /var all_match = true;/);
  assert.match(zig, /if \(!\(x > lim\)\) \{/);
});

test("R17e reduce lowers to an accumulator loop under the callback's own name", () => {
  const zig = emit(`
export function total(xs: readonly number[]): number {
  return xs.reduce((sum, x) => sum + x, 0);
}
`);
  assert.match(zig, /var sum: f64 = 0;/);
  assert.match(zig, /for \(xs\) \|x\| \{/);
  assert.match(zig, /sum = sum \+ x;/);
});

test("R17e reduce without an initial value is the taught NS1007 stop", () => {
  const result = transpile(`
export function total(xs: readonly number[]): number {
  return xs.reduce((sum, x) => sum + x);
}
`);
  assert.equal(result.ok, false);
  const d = result.diagnostics.find((x) => x.id === "NS1007");
  assert.ok(d, JSON.stringify(result.diagnostics));
  assert.ok(d.message.includes("initial value"), d.message);
});

test("R17f array slice resolves both bounds through rt.sliceIndex and copies", () => {
  const zig = emit(`
export function middle(xs: readonly number[], from: number, to: number): readonly number[] {
  return xs.slice(from, to);
}
`);
  assert.match(zig, /const copied_from = rt\.sliceIndex\(xs\.len, from\);/);
  assert.match(zig, /const copied_to = @max\(copied_from, rt\.sliceIndex\(xs\.len, to\)\);/);
  assert.match(zig, /rt\.frameAlloc\(f64, copied_to - copied_from\)/);
  assert.match(zig, /@memcpy\(copied, xs\[copied_from\.\.copied_to\]\);/);
});

test("R17g concat is one exact-size alloc with a memcpy per part", () => {
  const zig = emit(`
export interface Task { readonly id: number; readonly done: boolean; }
export function stitched(xs: readonly Task[], ys: readonly Task[]): readonly Task[] {
  return xs.concat(ys);
}
`);
  assert.match(zig, /rt\.frameAlloc\(Task, xs\.len \+ ys\.len\)/);
  assert.match(zig, /@memcpy\(combined\[0\.\.xs\.len\], xs\);/);
  assert.match(zig, /@memcpy\(combined\[xs\.len\.\.\], ys\);/);
});

test("R17h indexOf scans with strict equality; includes adds the SameValueZero NaN arm", () => {
  const zig = emit(`
export function whereIs(xs: readonly number[], v: number): number {
  return xs.indexOf(v);
}
export function has(xs: readonly number[], v: number): boolean {
  return xs.includes(v);
}
`);
  assert.match(zig, /var found_at: i64 = -1;/);
  assert.match(zig, /if \(x == v\) \{/);
  assert.match(zig, /if \(x == v or \(std\.math\.isNan\(x\) and std\.math\.isNan\(v\)\)\) \{/);
});

test("R17h indexOf on record elements is a taught stop (JS reference identity)", () => {
  const result = transpile(`
export interface Task { readonly id: number; readonly done: boolean; }
export function has(tasks: readonly Task[], t: Task): number {
  return tasks.indexOf(t);
}
`);
  assert.equal(result.ok, false);
  assert.ok(result.diagnostics.some((d) => d.id === "NS9001"), JSON.stringify(result.diagnostics));
});

test("R18b bytes join prints each byte through {d} with the folded separator", () => {
  const zig = emit(`
export function csv(bytes: Uint8Array): string {
  return bytes.join("-");
}
`);
  assert.match(zig, /rt\.frameAlloc\(u8, if \(bytes\.len == 0\) 0 else bytes\.len \* 3 \+ \(bytes\.len - 1\) \* 1\)/);
  assert.match(zig, /@memcpy\(joined\[joined_len\.\.\]\[0\.\.1\], "-"\);/);
  assert.match(zig, /std\.fmt\.bufPrint\(joined\[joined_len\.\.\], "\{d\}", \.\{b\}\) catch unreachable;/);
  assert.match(zig, /return joined\[0\.\.joined_len\];/);
});

test("R18b join on a number array is a taught stop (float elements)", () => {
  const result = transpile(`
export function csv(xs: readonly number[]): string {
  return xs.join(",");
}
`);
  assert.equal(result.ok, false);
  assert.ok(result.diagnostics.some((d) => d.id === "NS9001"), JSON.stringify(result.diagnostics));
});

test("R7c empty tests must name the value's own empty (null vs undefined)", () => {
  // `=== undefined` on a null-flavored value would be constant-false under
  // node but a hit natively — taught, never emitted.
  const wrongUndef = transpile(`
export function f(cursor: number | null): boolean {
  return cursor === undefined;
}
`);
  assert.equal(wrongUndef.ok, false);
  assert.ok(wrongUndef.diagnostics.some((d) => d.id === "NS9001"), JSON.stringify(wrongUndef.diagnostics));

  // `=== null` on a find result (an undefined-flavored miss) is the same
  // divergence in the other direction.
  const wrongNull = transpile(`
export function f(xs: readonly number[]): number {
  const hit = xs.find((x) => x > 0);
  if (hit === null) return -1;
  return 0;
}
`);
  assert.equal(wrongNull.ok, false);
  assert.ok(wrongNull.diagnostics.some((d) => d.id === "NS9001"), JSON.stringify(wrongNull.diagnostics));
});

test("R7 identifier guards narrow through if-captures (locals and params)", () => {
  const zig = emit(`
export interface Sel { readonly at: number; readonly len: number; }
export function width(sel: Sel | null): number {
  if (sel !== null) {
    const spread = sel.len - sel.at;
    return spread * 2;
  }
  return 0;
}
`);
  assert.match(zig, /if \(sel\) \|sel_2\| \{/);
  assert.match(zig, /sel_2\.len - sel_2\.at/);
});

test("R18 template literal with an integer hole becomes bufPrint {d}", () => {
  const zig = emit(`
import { asciiBytes } from "@native-sdk/core";
export function label(n: number): Uint8Array {
  return asciiBytes(\`Task \${n & 255}\`);
}
`);
  assert.match(zig, /std\.fmt\.bufPrint\(buf, "Task \{d\}"/);
});

test("R7b optional chains lower to null-propagating if-captures", () => {
  const zig = emit(`
export interface Badge { readonly count: number; }
export interface Panel { readonly badge: Badge | null; }
export interface Model { readonly panel: Panel | null; }
export function badgeCount(model: Model): number {
  return model.panel?.badge?.count ?? 0;
}
`);
  assert.match(zig, /\(if \(model\.panel\) \|panel\| panel\.badge else null\)/);
  assert.match(zig, /\|badge\| badge\.count else null\) orelse 0;/);
});

test("R7b a boolean chain in a condition folds its short-circuit to false", () => {
  const zig = emit(`
export interface Flags { readonly urgent: boolean; }
export interface Model { readonly flags: Flags | null; }
export function gate(model: Model): number {
  if (model.flags?.urgent) return 1;
  return 0;
}
`);
  assert.match(zig, /orelse false/);
});

test("NS1021 null test on a parenthesized chain is still taught, never emitted", () => {
  const result = transpile(`
export interface Inner { readonly x: number | null; }
export interface Model { readonly inner: Inner | null; }
export function f(model: Model): boolean { return (model.inner?.x) === null; }
`);
  assert.equal(result.ok, false);
  assert.ok(result.diagnostics.some((d) => d.id === "NS1021"), JSON.stringify(result.diagnostics));
});

test("R5c string equality lowers to strEq; inequality negates it", () => {
  const zig = emit(`
export function commandMsg(name: string): number {
  if (name === "app.add") return 1;
  if (name !== "app.remove") return 2;
  return 0;
}
`);
  assert.match(zig, /if \(strEq\(name, "app\.add"\)\) return 1;/);
  assert.match(zig, /if \(!strEq\(name, "app\.remove"\)\) return 2;/);
});

test("R5c literal-union value against a plain string compares the tag name", () => {
  const zig = emit(`
export type Filter = "all" | "active" | "done";
export function matchesName(f: Filter, name: string): boolean {
  return f === name;
}
`);
  assert.match(zig, /strEq\(@tagName\(f\), name\)/);
});

test("`===` on bytes stops loudly (JS reference identity has no slice mapping)", () => {
  const result = transpile(`export function same(a: Uint8Array, b: Uint8Array): boolean { return a === b; }`);
  assert.equal(result.ok, false);
  assert.ok(result.diagnostics.some((d) => d.id === "NS9001"), JSON.stringify(result.diagnostics));
});

test("NS1020 Cmd.host argument smuggled past the types stops with the rule", () => {
  const result = transpile(`
import { Cmd } from "@native-sdk/core";
export interface Model { readonly count: number; }
export type Msg = { readonly kind: "go"; readonly path: string } | { readonly kind: "noop" };
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.host("open", msg.path as unknown as number)];
    case "noop": return model;
  }
}
`);
  assert.equal(result.ok, false);
  assert.ok(result.diagnostics.some((d) => d.id === "NS1020"), JSON.stringify(result.diagnostics));
});

test("NS1019 default parameter values are taught, never dropped", () => {
  const result = transpile(`
function step(n: number, by: number = 1): number { return n + by; }
export function f(n: number): number { return step(n); }
`);
  assert.equal(result.ok, false);
  assert.ok(result.diagnostics.some((d) => d.id === "NS1019"), JSON.stringify(result.diagnostics));
});

test("NS1018 string + is taught, never emitted", () => {
  const result = transpile(`export function f(s: string): string { return "hi " + s; }`);
  assert.equal(result.ok, false);
  assert.ok(result.diagnostics.some((d) => d.id === "NS1018"), JSON.stringify(result.diagnostics));
});

test("commit walkers are generated from the Model shape", () => {
  const zig = emit(`
export interface Task { readonly id: number; readonly title: Uint8Array; readonly done: boolean; }
export interface Model { readonly tasks: readonly Task[]; readonly name: Uint8Array; }
export function idx(model: Model, bytes: Uint8Array): number { return bytes[model.tasks.length]; }
`);
  assert.match(zig, /fn commitBytes\(bytes: \[\]const u8, mode: CommitMode\) \[\]const u8/);
  assert.match(zig, /fn commitTask\(value: \*const Task, mode: CommitMode\) \*const Task/);
  assert.match(zig, /fn commitTasks\(values: \[\]const \*const Task, mode: CommitMode\)/);
  assert.match(zig, /fn commitModel\(value: \*const Model, mode: CommitMode\)/);
  assert.match(zig, /pub fn commitModelRoot\(next: \*const Model\) \*const Model/);
});

test("Cmd pair-return lowers onto the rt command builders", () => {
  const zig = emit(`
import { Cmd } from "@native-sdk/core";
export interface Model { readonly count: number; readonly saved: number; }
export type Msg =
  | { readonly kind: "add" }
  | { readonly kind: "save" }
  | { readonly kind: "stamp" }
  | { readonly kind: "tick"; readonly at: number }
  | { readonly kind: "quiet" };
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "add": return { ...model, count: model.count + 1 };
    case "save": return [{ ...model, saved: model.count }, Cmd.persist()];
    case "stamp": return [model, Cmd.batch([Cmd.now("tick"), Cmd.host("beep", model.count, 2)])];
    case "tick": return { ...model, count: msg.at };
    case "quiet": return [model, Cmd.none];
  }
}
`);
  // The pair-return contract wraps every return, sugaring bare models.
  assert.match(zig, /pub const UpdateResult = struct \{ model: \*const Model, cmd: rt\.Cmd \};/);
  assert.match(zig, /pub fn update\(model: \*const Model, msg: Msg\) UpdateResult/);
  assert.match(zig, /\.cmd = rt\.cmd_none/);
  // Factories lower onto the rt builders (the versioned effect-bytes channel).
  assert.match(zig, /\.cmd = rt\.cmdPersist\(\)/);
  assert.match(zig, /rt\.cmdNow\(@intFromEnum\(std\.meta\.Tag\(Msg\)\.tick\)\)/);
  assert.match(zig, /rt\.cmdHost\("beep", &\.\{ model\.count, 2 \}\)/);
  assert.match(zig, /rt\.cmdBatch\(&\.\{ rt\.cmdNow\(/);
});

test("Cmd v2 lowers bytes payloads, keyed requests, and cancel onto the rt builders", () => {
  const zig = emit(`
import { Cmd, asciiBytes } from "@native-sdk/core";
export interface Model { readonly draft: Uint8Array; readonly errs: number; }
export type Msg =
  | { readonly kind: "save" }
  | { readonly kind: "load" }
  | { readonly kind: "stop" }
  | { readonly kind: "loaded"; readonly body: Uint8Array }
  | { readonly kind: "failed"; readonly why: Uint8Array };
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "save": return [model, Cmd.host("store.write", model.draft)];
    case "load": return [model, Cmd.request("store.read", asciiBytes("notes.json"), { key: "load", ok: "loaded", err: "failed" })];
    case "stop": return [model, Cmd.cancel("load")];
    case "loaded": return { draft: msg.body, errs: model.errs };
    case "failed": return { ...model, errs: model.errs + 1 };
  }
}
`);
  assert.match(zig, /rt\.cmdHostBytes\("store\.write", model\.draft\)/);
  assert.match(
    zig,
    /rt\.cmdRequest\("store\.read", "load", @intFromEnum\(std\.meta\.Tag\(Msg\)\.loaded\), @intFromEnum\(std\.meta\.Tag\(Msg\)\.failed\), "notes\.json"\)/,
  );
  assert.match(zig, /rt\.cmdCancel\("load"\)/);
});

test("Cmd v2 record payloads lower through the derived encoder, fields sorted by name", () => {
  const zig = emit(`
import { Cmd, asciiBytes } from "@native-sdk/core";
export interface Model { readonly gain: number; readonly on: boolean; }
export type Msg = { readonly kind: "save" } | { readonly kind: "noop" };
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "save": return [model, Cmd.host("cfg.save", { on: model.on, tag: asciiBytes("v2"), gain: model.gain })];
    case "noop": return model;
  }
}
`);
  // gain (f64 LE) first, then on (bool byte), then tag (u32 len + bytes) —
  // sorted by TS field name, exactly what sdk hostRecordBytes produces.
  assert.match(zig, /const payload = rt\.frameAlloc\(u8, 13 \+ p_tag\.len\);/);
  assert.match(zig, /std\.mem\.writeInt\(u64, payload\[0\.\.\]\[0\.\.8\], @bitCast\(@as\(f64, @floatFromInt\(model\.gain\)\)\), \.little\);/);
  assert.match(zig, /payload\[8\] = @intFromBool\(model\.on\);/);
  assert.match(zig, /std\.mem\.writeInt\(u32, payload\[8 \+ 1\.\.\]\[0\.\.4\], @intCast\(p_tag\.len\), \.little\);/);
  assert.match(zig, /@memcpy\(payload\[8 \+ 1 \+ 4\.\.\]\[0\.\.p_tag\.len\], p_tag\);/);
  assert.match(zig, /rt\.cmdHostBytes\("cfg\.save", payload\)/);
});

test("initialModel's boot pair emits InitResult with the same cmd channel", () => {
  const zig = emit(`
import { Cmd } from "@native-sdk/core";
export interface Model { readonly count: number; }
export type Msg = { readonly kind: "tick"; readonly at: number } | { readonly kind: "noop" };
export function initialModel(): [Model, Cmd<Msg>] {
  return [{ count: 0 }, Cmd.now("tick")];
}
export function update(model: Model, msg: Msg): Model { return model; }
`);
  assert.match(zig, /pub const InitResult = struct \{ model: \*const Model, cmd: rt\.Cmd \};/);
  assert.match(zig, /pub fn initialModel\(\) InitResult/);
  assert.match(zig, /\.cmd = rt\.cmdNow\(@intFromEnum\(std\.meta\.Tag\(Msg\)\.tick\)\)/);
});

test("subscriptions lowers onto the rt subscription builders", () => {
  const zig = emit(`
import { Sub } from "@native-sdk/core";
export interface Model { readonly running: boolean; readonly fast: boolean; }
export type Msg = { readonly kind: "toggle" } | { readonly kind: "tick"; readonly at: number };
export function update(model: Model, msg: Msg): Model { return model; }
export function subscriptions(model: Model): Sub<Msg> {
  if (!model.running) return Sub.none;
  return Sub.batch([Sub.timer("tick", model.fast ? 40 : 100, "tick")]);
}
`);
  assert.match(zig, /pub fn subscriptions\(model: \*const Model\) rt\.Sub/);
  assert.match(zig, /return rt\.sub_none;/);
  assert.match(zig, /rt\.subBatch\(&\.\{ rt\.subTimer\("tick", /);
  assert.match(zig, /@intFromEnum\(std\.meta\.Tag\(Msg\)\.tick\)\)/);
});

test("R2 host-boundary params stay f64 under comparison demand (round 2C regression)", () => {
  const zig = emit(`
export function lenIs(bytes: Uint8Array, want: number): boolean {
  return bytes.length === want;
}
export function firstIs(bytes: Uint8Array, want: number): boolean {
  return bytes[0] === want;
}
export function pick(bytes: Uint8Array, i: number): number {
  return bytes[i];
}
`);
  // Comparison against i64-classed values (length, byte read) must not claim
  // the exported parameter — the host may pass any f64; the integer side
  // widens at the site instead.
  assert.match(zig, /pub fn lenIs\(bytes: \[\]const u8, want: f64\) bool/);
  assert.match(zig, /pub fn firstIs\(bytes: \[\]const u8, want: f64\) bool/);
  // Genuine integer demand (a memory index) still claims the parameter:
  // the emitted i64 signature is the contract type.
  assert.match(zig, /pub fn pick\(bytes: \[\]const u8, i: i64\) i64/);
});

test("Cmd.now demands a single-number-payload Msg arm (tsc-level)", () => {
  const result = transpile(`
import { Cmd } from "@native-sdk/core";
export interface Model { readonly count: number; }
export type Msg = { readonly kind: "add" } | { readonly kind: "tick"; readonly at: number };
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "add": return [model, Cmd.now("add")];
    case "tick": return model;
  }
}
`);
  assert.equal(result.ok, false);
  assert.ok(result.typeErrors.some((e) => e.includes("tick")), result.typeErrors.join("\n"));
});

test("the loop-entry model is tsc's: a back-edge kill widens the entry state (tsc-level)", () => {
  // A continue-edge kill reaches the next iteration through the back
  // edge, so tsc widens the loop-entry state and rejects an unguarded
  // read relying on the pre-loop narrow (TS18047). The emitter leans on
  // exactly this: continue-staged kills only need the loop's EXIT join —
  // in-body next-iteration reads that would need the back-edge state
  // never get past the checker.
  const result = transpile(`
export function f(vals: readonly number[], limit: number): number {
  let p: number | null = 10;
  if (p === null) return -1;
  let sum: number = 0;
  for (const v of vals) {
    if (v > limit) { p = null; continue; }
    sum += p;
  }
  return sum;
}
`);
  assert.equal(result.ok, false);
  assert.ok(
    result.typeErrors.some((e) => e.includes("TS18047")),
    result.typeErrors.join("\n") || "expected a possibly-null error",
  );
});

test("a do-while continue edge carries its kill into the trailing test (tsc-level)", () => {
  // `continue` in a do-while jumps TO the condition, so the test's state
  // is the join of the fall-through and every continue edge: a kill on
  // one continue path widens the target there, and tsc rejects the bare
  // condition read (TS18047). The emitter leans on this — the hoisted
  // first-pass head reads the live optional, and any bare-read shape
  // never gets past the checker.
  const result = transpile(`
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
  } while (p.v > 0 && n < 10);
  return n;
}
`);
  assert.equal(result.ok, false);
  assert.ok(
    result.typeErrors.some((e) => e.includes("TS18047")),
    result.typeErrors.join("\n") || "expected a possibly-null error",
  );
});

test("a do-while body narrow does not survive the back edge into the body top (tsc-level)", () => {
  // The body-top state is the join of the pre-loop entry and the back
  // edge: with a widened pre-loop state, a narrow established later in
  // the body never reaches the top read of the next iteration — tsc
  // rejects it on iteration one, and the trailing-test scope must not
  // leak it into iteration entry either.
  const result = transpile(`
export interface P { readonly v: number; }
export function g(q: P | null): number {
  const p: P | null = q;
  let n = 0;
  do {
    n += p.v;
    if (p === null) return -1;
  } while (p.v > 0 && n < 10);
  return n;
}
`);
  assert.equal(result.ok, false);
  assert.ok(
    result.typeErrors.some((e) => e.includes("TS18047")),
    result.typeErrors.join("\n") || "expected a possibly-null error",
  );
});

test("emit-time verification: unsupported constructs stop the build as NS9001", () => {
  const result = transpile(`
export function f(xs: readonly number[]): readonly number[] {
  return xs.flatMap((a) => [a, a]);
}
`);
  assert.equal(result.ok, false);
  assert.ok(result.diagnostics.some((d) => d.id === "NS9001"), JSON.stringify(result.diagnostics));
});

test("R17i block-body callbacks lift: straight-line bodies inline, early returns become a labeled value block", () => {
  const zig = emit(`
export interface Task { readonly id: number; readonly streak: number; readonly done: boolean; }
export function margins(tasks: readonly Task[], lim: number): readonly Task[] {
  return tasks.filter((t) => {
    const margin = lim - t.streak;
    return margin > 0;
  });
}
export function capped(tasks: readonly Task[], lim: number): readonly Task[] {
  return tasks.map((t) => {
    if (t.streak > lim) return { ...t, streak: lim };
    return t;
  });
}
`);
  // Straight-line lift: the local emits in the loop body, the trailing
  // return is the predicate value.
  assert.match(zig, /const margin = lim - t\.streak;/);
  assert.match(zig, /if \(margin > 0\) \{/);
  // Early returns: a labeled value block; `return v` -> `break :label v`.
  assert.match(zig, /const elem: Task = cb: \{/);
  assert.match(zig, /break :cb t;/);
});

test("R17i block-body find and reduce lift with the same rules", () => {
  const zig = emit(`
export interface Task { readonly id: number; readonly streak: number; readonly done: boolean; }
export function pick(tasks: readonly Task[], lim: number): number {
  const hit = tasks.find((t) => {
    if (t.done) return false;
    return t.streak > lim;
  });
  if (hit === undefined) return -1;
  return hit.id;
}
export function tally(tasks: readonly Task[]): number {
  return tasks.reduce((sum, t) => {
    if (t.done) return sum;
    return sum + t.streak;
  }, 0);
}
`);
  assert.match(zig, /const matches: bool = cb: \{/);
  assert.match(zig, /break :cb false;/);
  // `streak` compares against the host-boundary `lim` (which must stay f64,
  // R2), so the accumulator chain resolves float instead of being claimed to
  // i64 by the comparison.
  assert.match(zig, /const next: f64 = cb: \{/);
  assert.match(zig, /break :cb sum \+ t\.streak;/);
});

test("R17i a callback path that falls off the end is a taught stop", () => {
  const result = transpile(`
export function f(xs: readonly number[]): readonly number[] {
  return xs.filter((x) => {
    if (x > 0) return true;
  });
}
`);
  assert.equal(result.ok, false);
  const d = result.diagnostics.find((x) => x.id === "NS9001");
  assert.ok(d, JSON.stringify(result.diagnostics));
  assert.ok(d.message.includes("explicit `return`"), d.message);
});

test("R17j toSorted copies then runs a stable insertion sort on the comparator's sign", () => {
  const zig = emit(`
export interface Task { readonly id: number; readonly streak: number; }
export function byStreak(tasks: readonly Task[]): readonly Task[] {
  return tasks.toSorted((a, b) => a.streak - b.streak);
}
`);
  assert.match(zig, /const sorted = rt\.frameAlloc\(Task, tasks\.len\);/);
  assert.match(zig, /@memcpy\(sorted, tasks\);/);
  assert.match(zig, /stable insertion sort/);
  assert.match(zig, /const a = sorted\[i\];/);
  assert.match(zig, /const b = sorted\[j - 1\];/);
  assert.match(zig, /if \(!\(a\.streak - b\.streak < 0\)\) break;/);
  assert.match(zig, /sorted\[j\] = a;/);
});

test("R17j toSorted without a comparator is a taught stop naming (a, b) => a - b", () => {
  const result = transpile(`
export function f(xs: readonly number[]): readonly number[] {
  return xs.toSorted();
}
`);
  assert.equal(result.ok, false);
  const d = result.diagnostics.find((x) => x.id === "NS9001");
  assert.ok(d, JSON.stringify(result.diagnostics));
  assert.ok(d.message.includes("(a, b) => a - b"), d.message);
});

test("R17k the push-builder lowers to a growable frame builder", () => {
  const zig = emit(`
export function evens(xs: readonly number[]): readonly number[] {
  const out: number[] = [];
  for (const x of xs) {
    if (x > 0) out.push(x);
  }
  return out;
}
`);
  assert.match(zig, /var out = rt\.frameAlloc\(f64, 0\);/);
  assert.match(zig, /var out_len: usize = 0;/);
  assert.match(zig, /if \(out_len == out\.len\) out = rt\.frameGrow\(f64, out\);/);
  assert.match(zig, /out\[out_len\] = x;/);
  assert.match(zig, /out_len \+= 1;/);
  assert.match(zig, /return out\[0\.\.out_len\];/);
});

test("R17m a reassigned binding whose every assignment is a fresh construction stays owned", () => {
  const zig = emit(`
export function f(n: number): readonly number[] {
  let out: number[] = [];
  out.push(n);
  out = [n, n];
  out.push(n + 1);
  return out;
}
`);
  // The reassignment resets the builder's slice and fill count.
  assert.match(zig, /out = rt\.frameAlloc\(f64, 0\);/);
  assert.match(zig, /out_len = out\.len;/);
});

test("R17m push on a MIXED reassigned binding is taught (one alias assignment ends ownership)", () => {
  const result = transpile(`
export function f(xs: number[], n: number): readonly number[] {
  let out: number[] = [];
  out.push(n);
  out = xs;
  return out;
}
`);
  assert.equal(result.ok, false);
  const d = result.diagnostics.find((x) => x.id === "NS1001");
  assert.ok(d, JSON.stringify(result.diagnostics));
  assert.ok(d.message.includes("reassigned"), d.message);
});

test("R17k push on a helper-produced array is taught with the ownership fix", () => {
  const result = transpile(`
function make(): number[] { return [1]; }
export function f(n: number): readonly number[] {
  const out = make();
  out.push(n);
  return out;
}
`);
  assert.equal(result.ok, false);
  const d = result.diagnostics.find((x) => x.id === "NS1001");
  assert.ok(d, JSON.stringify(result.diagnostics));
  assert.ok(d.message.includes(".slice()"), d.message);
});

test("R17k the generalized builder: pop/shift/unshift/splice lower against the live length", () => {
  const zig = emit(`
export function churn(xs: readonly number[]): readonly number[] {
  const work = xs.slice();
  work.pop();
  work.shift();
  work.unshift(-1);
  work.splice(1, 0, 9);
  return work;
}
`);
  assert.match(zig, /var work = work_seed;/);
  assert.match(zig, /var work_len: usize = work\.len;/);
  assert.match(zig, /if \(work_len > 0\) work_len -= 1;/, "pop drops the tail");
  assert.match(zig, /std\.mem\.copyForwards\(f64, work\[0\.\.work_len\], work\[1\.\.work_len \+ 1\]\);/, "shift memmoves the head");
  assert.match(zig, /std\.mem\.copyBackwards\(f64, work\[1\.\.work_len \+ 1\], work\[0\.\.work_len\]\);/, "unshift shifts right");
  assert.match(zig, /rt\.sliceIndex\(work_len, 1\)/, "splice resolves its start the JS way");
  assert.match(zig, /return work\[0\.\.work_len\];/);
});

test("R17j applied in place: an owned sort reuses the stable insertion sort without a copy", () => {
  const zig = emit(`
export function ordered(xs: readonly number[]): readonly number[] {
  const copy = xs.slice();
  copy.sort((a, b) => a - b);
  return copy;
}
`);
  assert.match(zig, /\/\/ JS sort: stable insertion sort; the comparator's sign orders each pair\./);
  assert.match(zig, /if \(!\(a - b < 0\)\) break;/);
  // No second allocation between the slice copy and the sort.
  const allocs = zig.match(/rt\.frameAlloc\(f64/g) ?? [];
  assert.equal(allocs.length, 1, `expected exactly the slice copy's alloc:\n${zig}`);
});

test("R17k a later push argument reading the array is hoisted (JS evaluates args first)", () => {
  const zig = emit(`
export function f(n: number): readonly number[] {
  const out: number[] = [];
  out.push(n);
  out.push(n + 1, out.length);
  return out;
}
`);
  assert.match(zig, /const pushed = n \+ 1;/);
  assert.match(zig, /const pushed_2 = @as\(f64, @floatFromInt\(@as\(i64, @intCast\(out_len\)\)\)\);/);
});

test("R17k push in value position is a taught stop (the JS value is the new length)", () => {
  const result = transpile(`
export function f(n: number): number {
  const out: number[] = [];
  const len = out.push(n);
  return len;
}
`);
  assert.equal(result.ok, false);
  const d = result.diagnostics.find((x) => x.id === "NS9001");
  assert.ok(d, JSON.stringify(result.diagnostics));
  assert.ok(d.message.includes("new length"), d.message);
});

test("R17l prepend and multi-spread array literals copy exact-size segments", () => {
  const zig = emit(`
export function pre(xs: readonly number[], x: number): readonly number[] {
  return [x, ...xs];
}
export function stitch(a: readonly number[], b: readonly number[], x: number): readonly number[] {
  return [...a, x, ...b];
}
`);
  // Prepend: static leading indices, one tail memcpy.
  assert.match(zig, /rt\.frameAlloc\(f64, xs\.len \+ 1\);/);
  assert.match(zig, /prepended\[0\] = x;/);
  assert.match(zig, /@memcpy\(prepended\[1\.\.\], xs\);/);
  // Multi-spread: one exact-size alloc, cursor-advanced segment copies.
  assert.match(zig, /rt\.frameAlloc\(f64, a\.len \+ b\.len \+ 1\);/);
  assert.match(zig, /@memcpy\(combined\[combined_at\.\.\]\[0\.\.a\.len\], a\);/);
  assert.match(zig, /combined\[combined_at\] = x;/);
});

test("comptime division folds to its JS f64 value (0/0 is NaN, never a Zig divide error)", () => {
  const zig = emit(`
export const RATE = 1 / 0;
export function nanv(): number { return 0 / 0; }
export function half(): number { return 5 / 2; }
export function negZero(): number { return 0 / -1; }
`);
  assert.match(zig, /pub const RATE: f64 = std\.math\.inf\(f64\);/);
  assert.match(zig, /return std\.math\.nan\(f64\);/);
  assert.match(zig, /return 2\.5;/);
  assert.match(zig, /return -0\.0;/);
});

test("R8b Math floor/ceil/trunc/abs/sign on float sites map to the IEEE ops (sign via rt.jsSign)", () => {
  const zig = emit(`
export function flo(x: number): number { return Math.floor(x); }
export function cei(x: number): number { return Math.ceil(x); }
export function tru(x: number): number { return Math.trunc(x); }
export function ab(x: number): number { return Math.abs(x); }
export function sg(x: number): number { return Math.sign(x); }
export function sq(x: number): number { return Math.sqrt(x); }
`);
  assert.match(zig, /return @floor\(x\);/);
  assert.match(zig, /return @ceil\(x\);/);
  assert.match(zig, /return @trunc\(x\);/);
  assert.match(zig, /return @abs\(x\);/);
  assert.match(zig, /return rt\.jsSign\(x\);/);
  assert.match(zig, /return @sqrt\(x\);/);
});

test("R8b Math floor/ceil/trunc of an integer-classed value are the identity; abs/sign stay integer", () => {
  const zig = emit(`
export function flo(bytes: Uint8Array): number { return Math.floor(bytes.length); }
export function ab(bytes: Uint8Array): number { return Math.abs(bytes.length - 10); }
export function sg(bytes: Uint8Array): number { return Math.sign(bytes.length - 2); }
`);
  assert.match(zig, /fn flo\(bytes: \[\]const u8\) i64 \{\n    return jlen\(bytes\);/);
  assert.match(zig, /return @as\(i64, @intCast\(@abs\(jlen\(bytes\) - 10\)\)\);/);
  assert.match(zig, /return std\.math\.sign\(jlen\(bytes\) - 2\);/);
});

test("R8 comptime Math calls fold to their JS value (integer folds stay integer-classed)", () => {
  const zig = emit(`
export const HALF = Math.floor(5 / 2);
export const DOWN = Math.floor(-5 / 2);
export const ROOT = Math.sqrt(2);
export function pick(bytes: Uint8Array): number { return bytes[HALF]; }
export function low(): number { return Math.min(3, 2.5); }
`);
  assert.match(zig, /pub const HALF: i64 = 2;/);
  assert.match(zig, /pub const DOWN: i64 = -3;/);
  assert.match(zig, /pub const ROOT: f64 = 1\.4142135623730951;/);
  assert.match(zig, /return 2\.5;/);
});

test("R8 Math.min()/Math.max() with no arguments fold to the JS infinities; one argument is the identity", () => {
  const zig = emit(`
export function lo(): number { return Math.min(); }
export function hi(): number { return Math.max(); }
export function same(x: number): number { return Math.max(x); }
`);
  assert.match(zig, /return std\.math\.inf\(f64\);/);
  assert.match(zig, /return -std\.math\.inf\(f64\);/);
  assert.match(zig, /return x;/);
});

test("Number.isInteger/isFinite/isNaN classify floats; integer-classed arguments are constants", () => {
  const zig = emit(`
export function isInt(x: number): boolean { return Number.isInteger(x); }
export function isFin(x: number): boolean { return Number.isFinite(x); }
export function isNan(x: number): boolean { return Number.isNaN(x); }
export function intAlways(bytes: Uint8Array): boolean { return Number.isInteger(bytes.length); }
export function intNever(bytes: Uint8Array): boolean { return Number.isNaN(bytes.length); }
`);
  assert.match(zig, /return rt\.jsIsInteger\(x\);/);
  assert.match(zig, /return std\.math\.isFinite\(x\);/);
  assert.match(zig, /return std\.math\.isNan\(x\);/);
  assert.match(zig, /fn intAlways\(bytes: \[\]const u8\) bool \{\n    _ = bytes;\n    return true;/);
  assert.match(zig, /fn intNever\(bytes: \[\]const u8\) bool \{\n    _ = bytes;\n    return false;/);
});

test("the NaN and Infinity globals are f64 literals, never leaked identifiers", () => {
  const zig = emit(`
export function nanv(): number { return NaN; }
export function negInf(): number { return -Infinity; }
export function isMissing(x: number): boolean { return Number.isNaN(x); }
`);
  assert.match(zig, /return std\.math\.nan\(f64\);/);
  assert.match(zig, /return -std\.math\.inf\(f64\);/);
});

test("comptime % folds to its JS value (5 % 0 is NaN, -5 % 5 is -0; integer folds stay comptime indices)", () => {
  const zig = emit(`
export function nanv(): number { return 5 % 0; }
export function negZero(): number { return -5 % 5; }
export function frac(): number { return 5.5 % 2; }
export function pick(bytes: Uint8Array): number { return bytes[6 % 4]; }
`);
  assert.match(zig, /return std\.math\.nan\(f64\);/);
  assert.match(zig, /return -0\.0;/);
  assert.match(zig, /return 1\.5;/);
  assert.match(zig, /return bytes\[uz\(2\)\];/);
});

test("R11 subarray resolves both bounds the JS way through rt.subarray (a view, never a trap)", () => {
  const zig = emit(`
export function window(bytes: Uint8Array, from: number, to: number): Uint8Array {
  return bytes.subarray(from, to);
}
export function tail(bytes: Uint8Array, from: number): Uint8Array {
  return bytes.subarray(from);
}
export function whole(bytes: Uint8Array): Uint8Array {
  return bytes.subarray();
}
`);
  assert.match(zig, /return rt\.subarray\(bytes, from, to\);/);
  assert.match(zig, /return rt\.subarray\(bytes, from, null\);/);
  assert.match(zig, /fn whole\(bytes: \[\]const u8\) \[\]const u8 \{\n    return bytes;/);
});

test("R1b module const tables emit as rodata: arrays, records, enum members, asciiBytes names", () => {
  const zig = emit(`
import { asciiBytes } from "@native-sdk/core";
export type Filter = "all" | "active" | "done";
export const WEEKDAYS = [3, 5, 2];
export const ORDER: readonly Filter[] = ["done", "all"];
export const SEED_NAME = asciiBytes("Stretch");
export interface Limits { readonly lo: number; readonly hi: number; }
export const LIMITS: Limits = { lo: 1, hi: 9 };
export const DEFAULT_FILTER: Filter = "active";
export function at(i: number): number { return WEEKDAYS[i]; }
export function count(): number { return WEEKDAYS.length; }
export function loOf(): number { return LIMITS.lo; }
`);
  assert.match(zig, /pub const WEEKDAYS: \[\]const f64 = &\.\{ 3, 5, 2 \};/);
  assert.match(zig, /pub const ORDER: \[\]const Filter = &\.\{ \.done, \.all \};/);
  assert.match(zig, /pub const SEED_NAME: \[\]const u8 = "Stretch";/);
  assert.match(zig, /pub const LIMITS: Limits = \.\{ \.lo = 1, \.hi = 9 \};/);
  assert.match(zig, /pub const DEFAULT_FILTER: Filter = \.active;/);
  assert.match(zig, /return WEEKDAYS\[uz\(i\)\];/);
  assert.match(zig, /return LIMITS\.lo;/);
});

test("R1b a record table of model structs emits pointer elements the commit walkers share", () => {
  const zig = emit(`
import { asciiBytes } from "@native-sdk/core";
export interface Task { readonly id: number; readonly title: Uint8Array; readonly done: boolean; }
export interface Model { readonly tasks: readonly Task[]; }
export const SEEDS: readonly Task[] = [
  { id: 1, title: asciiBytes("Ship"), done: false },
  { id: 2, title: asciiBytes("Test"), done: true },
];
export function initialModel(): Model { return { tasks: SEEDS }; }
`);
  assert.match(zig, /pub const SEEDS: \[\]const \*const Task = &\.\{ &\.\{ \.id = 1, \.title = "Ship", \.done = false \}, &\.\{ \.id = 2, \.title = "Test", \.done = true \} \};/);
});

test("R1b an unannotated record table is taught toward the interface annotation", () => {
  const result = transpile(`
export const LIMITS = { lo: 1, hi: 9 };
export function loOf(): number { return 1; }
`);
  assert.equal(result.ok, false);
  const d = result.diagnostics.find((x) => x.id === "NS9001");
  assert.ok(d, JSON.stringify(result.diagnostics));
  assert.ok(d.message.includes("interface annotation"), d.message);
});

test("R1b spreads and non-comptime values in tables are taught stops", () => {
  const spread = transpile(`
export interface Limits { readonly lo: number; readonly hi: number; }
export const BASE: Limits = { lo: 1, hi: 9 };
export const WIDE: Limits = { ...BASE, hi: 99 };
export function f(): number { return 1; }
`);
  assert.equal(spread.ok, false);
  assert.ok(spread.diagnostics.some((d) => d.id === "NS9001" && d.message.includes("spread")), JSON.stringify(spread.diagnostics));
});

test("R17b a type-changing map allocates the callback's result type, not the source element", () => {
  const zig = emit(`
export interface Task { readonly id: number; readonly title: Uint8Array; readonly done: boolean; }
export function ids(tasks: readonly Task[]): readonly number[] {
  return tasks.map((t) => t.id);
}
export function titles(tasks: readonly Task[]): readonly Uint8Array[] {
  return tasks.map((t) => t.title);
}
export function orNull(xs: readonly number[]): readonly (number | null)[] {
  return xs.map((x) => (x > 0 ? x : null));
}
`);
  assert.match(zig, /const mapped = rt\.frameAlloc\(f64, tasks\.len\);/);
  assert.match(zig, /mapped\[i\] = @as\(f64, @floatFromInt\(t\.id\)\);/);
  assert.match(zig, /rt\.frameAlloc\(\[\]const u8, tasks\.len\);/);
  assert.match(zig, /rt\.frameAlloc\(\?f64, xs\.len\);/);
});

test("R17m callback index parameters bind the loop index in the parameter's class", () => {
  const zig = emit(`
export function weighted(xs: readonly number[]): readonly number[] {
  return xs.map((x, i) => x * i);
}
export function evenSlots(xs: readonly number[]): readonly number[] {
  return xs.filter((x, at) => at % 2 === 0);
}
export function afterTwo(xs: readonly number[]): number {
  return xs.findIndex((x, at) => at >= 2 && x > 0);
}
`);
  // The map index mixes with float elements, so it binds as f64. The source
  // name `i` wins; the generated loop capture yields (`i_2`, never a bare
  // digit suffix that would land in Zig's iN primitive namespace).
  assert.match(zig, /const i: f64 = @floatFromInt\(i_2\);/);
  // Pure index arithmetic stays i64.
  assert.match(zig, /const at: i64 = @intCast\(i\);/);
  assert.match(zig, /@rem\(at, 2\)/);
});

test("R17m a callback declaring the third (array) parameter is a taught stop", () => {
  const result = transpile(`
export function f(xs: readonly number[]): readonly number[] {
  return xs.map((x, i, all) => x + all.length);
}
`);
  assert.equal(result.ok, false);
  assert.ok(result.diagnostics.some((d) => d.id === "NS9001" && d.message.includes("element, index")), JSON.stringify(result.diagnostics));
});

test("array-method calls lower directly inside if conditions (the scan hoists before the if)", () => {
  const zig = emit(`
export function grade(xs: readonly number[]): number {
  if (xs.some((x) => x > 3)) return 1;
  else if (xs.every((x) => x < 0)) return 2;
  return 0;
}
`);
  assert.match(zig, /var any_match = false;/);
  assert.match(zig, /if \(any_match\) \{/);
  assert.match(zig, /var all_match = true;/);
  assert.match(zig, /if \(all_match\) return 2;/);
});

test("names that would shadow Zig primitives take the reserved-word underscore", () => {
  const zig = emit(`
export function f(xs: readonly number[], u8: number): number {
  let total = 0;
  for (const x of xs) total += x * u8;
  return total;
}
`);
  assert.match(zig, /u8_: f64/);
});

test("R13d switch on a literal-union value maps member arms, shared labels, and default to else", () => {
  const zig = emit(`
export type Filter = "all" | "active" | "done";
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
  }
  return n;
}
`);
  assert.match(zig, /\.active, \.done => return 1,/);
  assert.match(zig, /else => return 0,/);
  // A partial value switch skips uncovered members exactly like JS.
  assert.match(zig, /else => \{\},/);
});

test("R13d a callback-mutated scrutinee gets a completing else, never unreachable", () => {
  // tsc keeps k's flow type at "a" across the callback (it never widens
  // locals for nested-function assignments), but execution reaches the
  // switch with k === "b" whenever xs is non-empty: an `else =>
  // unreachable` armed off that flow claim is a safety panic in Debug and
  // UB in ReleaseFast. Coverage judged by the declared union declines
  // here, so the fallthrough must complete.
  const zig = emit(`
export type AB = "a" | "b";
export function f(xs: readonly number[]): number {
  let k: AB = "a";
  const ys = xs.map((x) => { k = "b"; return x; });
  switch (k) {
    case "a":
      return 1;
  }
  return 2 + ys.length;
}
`);
  assert.doesNotMatch(zig, /else => unreachable/);
  assert.match(zig, /else => \{\},/);
});

test("R13d declared-union coverage still closes the numeric else with unreachable", () => {
  // The sound case is untouched: every declared member armed and exiting
  // proves the integer scrutinee's required else arm never runs.
  const zig = emit(`
export type Level = 0 | 1 | 2;
export function f(lvl: Level): number {
  switch (lvl) {
    case 0:
      return 1;
    case 1:
    case 2:
      return 2;
  }
}
`);
  assert.match(zig, /else => unreachable,/);
});

test("R13d flow-narrowed coverage still claims for a local no nested function assigns", () => {
  // The precise middle, pinned: with no capture-site assignment the
  // straight-line CFA is exact for an unaliased local, so the guard's
  // exclusion holds on every real path and the flow type may judge.
  const zig = emit(`
export type Mode = "a" | "b" | "c";
export function f(mode: Mode): number {
  if (mode === "c") return 30;
  switch (mode) {
    case "a":
      return 1;
    case "b":
      return 2;
  }
}
`);
  assert.match(zig, /else => unreachable,/);
});

test("finally reads keep their narrow across tsc-unreachable and callback assignments", () => {
  // finallyEntryKills counts what tsc's CFA counts: `if (false) p = null`
  // sits in a branch tsc excludes, and a callback body's assignment never
  // widens the finally (both probed), so the substituted read survives.
  const zig = emit(`
export interface P { readonly v: number; }
export function f(q: P | null, xs: readonly number[]): number {
  let p: P | null = q;
  if (p === null) return -1;
  let n = 0;
  try {
    if (false) p = null;
    const ys = xs.map((x) => { p = null; return x; });
    n += ys.length;
  } finally {
    n += p.v;
  }
  return n;
}
`);
  assert.match(zig, /n \+= p\.\?\.v;/);
});

test("a write-only ternary arm takes the plain comparison, a reading arm the capture", () => {
  // A guarded capture serves READS: the bare target of a plain `=` inside
  // the hit arm's callback never consumes it, so the arm declines the
  // capture form (a bound-but-unused Zig capture is a compile error) and
  // keeps `!= null`; the reading arm still binds and consumes its capture.
  const zig = emit(`
export interface P { readonly v: number; }
export function writes(q: P | null, xs: readonly number[]): number {
  let p: P | null = q;
  return p !== null ? xs.map((x) => { p = null; return x; }).length : 0;
}
export function reads(q: P | null): number {
  return q !== null ? q.v : 0;
}
`);
  assert.match(zig, /if \(p != null\) \{/);
  assert.doesNotMatch(zig, /if \(p\) \|/);
  assert.match(zig, /if \(q\) \|q_2\| q_2\.v else 0/);
});

test("kills under a keyword-literal false condition never reach the branch join", () => {
  // tscExcludedArm at the join layer: `if (false) p = null` emits (Zig
  // compiles it fine) but contributes no kill, so the fall-through read
  // keeps the unwrap tsc typed it with. The genuinely conditional kill in
  // g still joins and the re-guard re-narrows.
  const zig = emit(`
export interface P { readonly v: number; }
function make(a: number): P | null {
  if (a < 0) return null;
  return { v: a };
}
export function f(a: number): number {
  let p: P | null = make(a);
  if (p === null) return -1;
  if (false) p = null;
  while (false) {
    p = null;
  }
  return p.v;
}
export function g(a: number, flag: boolean): number {
  let p: P | null = make(a);
  if (p === null) return -1;
  if (flag) p = null;
  if (p === null) return -2;
  return p.v;
}
`);
  assert.match(zig, /if \(false\) \{/);
  assert.match(zig, /while \(false\) p = null;/);
  assert.match(zig, /return p\.\?\.v;\n\}\n\npub fn g/);
  assert.match(zig, /const p_2 = p orelse return -2;/);
});

test("tscExcludedArm: bare keyword-literal arms only; a do-while(false) body counts", () => {
  // The one shared judgment both the finally scan and the branch joins
  // consult, pinned direction by direction — including the distinction
  // that a do-while(false) body RUNS once (the test follows the body), so
  // it is never excluded, and that a `const NEVER = false` alias condition
  // widens under tsc, so a reference never excludes.
  const { emitter, file } = buildEmitter(`
const NEVER = false;
export function f(): number {
  let n = 0;
  if (false) n += 1;
  if (true) {
    n += 2;
  } else {
    n += 3;
  }
  while (false) {
    n += 4;
  }
  do {
    n += 5;
  } while (false);
  if (NEVER) n += 6;
  return n;
}
`);
  const excluded = (construct: import("../src/typed_ast.ts").Node, arm: import("../src/typed_ast.ts").Node | undefined): boolean =>
    (emitter as unknown as { tscExcludedArm(c: unknown, a: unknown): boolean }).tscExcludedArm(construct, arm);
  const stmts: any[] = [];
  const fn = (file.statements as readonly any[]).find((s) => s.name?.text === "f");
  for (const s of fn.body.statements) stmts.push(s);
  const [, ifFalse, ifTrue, whileFalse, doWhile, ifAlias] = stmts;
  assert.equal(excluded(ifFalse, ifFalse.thenStatement), true);
  assert.equal(excluded(ifFalse, ifFalse.elseStatement), false);
  assert.equal(excluded(ifTrue, ifTrue.elseStatement), true);
  assert.equal(excluded(ifTrue, ifTrue.thenStatement), false);
  assert.equal(excluded(whileFalse, whileFalse.statement), true);
  assert.equal(excluded(doWhile, doWhile.statement), false);
  assert.equal(excluded(ifAlias, ifAlias.thenStatement), false);
});

test("R13d flow trust is position-aware over nested functions", () => {
  // scrutineeFlowTrustable, all four directions of the reach-before-use
  // rule. The declining directions use shapes the subset checker gates out
  // of end-to-end fixtures (a nested function declaration is NS1046), so
  // they pin here against the raw judgment.
  const trustAt = (src: string): boolean => {
    const { emitter, file } = buildEmitter(src);
    let id: unknown = null;
    const visit = (n: any): void => {
      if (ts.isSwitchStatement(n)) id = n.expression;
      ts.forEachChild(n, visit);
    };
    ts.forEachChild(file as any, visit);
    assert.notEqual(id, null);
    return (emitter as unknown as { scrutineeFlowTrustable(n: unknown): boolean }).scrutineeFlowTrustable(id);
  };
  const wrap = (tail: string): string => `
type Mode = "a" | "b" | "c";
export function f(flag: boolean, xs: readonly number[]): number {
  let k: Mode = flag ? "a" : "b";
  switch (k) {
    case "a": return 1;
    case "b": return 2;
  }
  ${tail}
}
`;
  // An arrow defined AFTER the switch does not exist as a value before it:
  // trust holds.
  assert.equal(trustAt(wrap(`
  const bump = (): void => { k = "c"; };
  bump();
  return 0;`)), true);
  // An arrow defined BEFORE the switch counts (whether anything calls it
  // is not asked): trust declines.
  assert.equal(trustAt(`
type Mode = "a" | "b" | "c";
export function f(flag: boolean): number {
  let k: Mode = flag ? "a" : "b";
  const bump = (): void => { k = "c"; };
  switch (k) {
    case "a": return 1;
    case "b": return 2;
  }
  return 0;
}
`), false);
  // A function DECLARATION hoists — an earlier call can run it — so it
  // counts regardless of sitting after the switch: trust declines.
  assert.equal(trustAt(wrap(`
  function bump(): void { k = "c"; }
  return 0;`)), false);
  // A loop enclosing both lets the later arrow run before a re-entered
  // switch (the back edge): trust declines.
  assert.equal(trustAt(`
type Mode = "a" | "b" | "c";
export function f(xs: readonly number[]): number {
  let total = 0;
  let k: Mode = "a";
  for (const x of xs) {
    switch (k) {
      case "a":
        total += 1;
        break;
    }
    const ys = [x].map((y) => {
      k = "c";
      return y;
    });
    total += ys.length;
  }
  return total;
}
`), false);
});

test("kernel capacities: default header uses the shared default kernel", () => {
  const zig = emit(`export function f(n: number): number { return n & 1; }`);
  assert.match(zig, /pub const rt = @import\("rt\.zig"\)\.default;/);
});

test("kernel capacities: transpile options become comptime Kernel parameters", () => {
  const result = transpile(
    `export function f(n: number): number { return n & 1; }`,
    { frameCap: 262144, heapCap: 524288 },
  );
  assert.equal(result.ok, true);
  assert.match(result.zig!, /pub const rt = @import\("rt\.zig"\)\.Kernel\(\.\{ \.frame_cap = 262144, \.heap_cap = 524288 \}\);/);
});

test("R6b a model union emits an arm-switching walker; scalar arms pass through", () => {
  const zig = emit(`
import { asciiBytes } from "@native-sdk/core";
export type View =
  | { readonly kind: "list"; readonly scroll: number }
  | { readonly kind: "compose"; readonly draft: Uint8Array };
export interface Model { readonly view: View; }
export type Msg = { readonly kind: "a" } | { readonly kind: "b" };
export function initialModel(): Model { return { view: { kind: "list", scroll: 0 } }; }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "a": return { view: { kind: "compose", draft: asciiBytes("d") } };
    case "b": return { view: { kind: "list", scroll: 1 } };
  }
}
`);
  assert.match(zig, /fn commitView\(value: View, mode: CommitMode\) View \{/);
  // The scalar arm shares by value; the bytes arm rewrites its payload.
  assert.match(zig, /\.list => value,/);
  assert.match(zig, /\.compose => \|v\| \.\{ \.compose = commitBytes\(v, mode\) \},/);
  assert.match(zig, /\.view = commitView\(value\.view, mode\)/);
});

test("R6b a union whose arms hold no heap data commits by plain copy", () => {
  const zig = emit(`
export type View =
  | { readonly kind: "list" }
  | { readonly kind: "detail"; readonly id: number };
export interface Model { readonly view: View; }
export type Msg = { readonly kind: "a" } | { readonly kind: "b" };
export function initialModel(): Model { return { view: { kind: "list" } }; }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) { case "a": return model; case "b": return { view: { kind: "detail", id: 1 } }; }
}
`);
  assert.match(zig, /\.view = value\.view,/);
  assert.doesNotMatch(zig, /fn commitView/);
});

test("primitive model arrays commit through the generic scalar walker", () => {
  const zig = emit(`
export interface Model { readonly xs: readonly number[]; readonly flags: readonly boolean[]; readonly pending: readonly number[] | null; }
export type Msg = { readonly kind: "a" } | { readonly kind: "b" };
export function initialModel(): Model { return { xs: [], flags: [], pending: null }; }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) { case "a": return model; case "b": return { ...model, xs: [] }; }
}
`);
  assert.match(zig, /fn commitScalars\(comptime T: type, values: \[\]const T, mode: CommitMode\) \[\]const T \{/);
  assert.match(zig, /\.xs = commitScalars\(f64, value\.xs, mode\)/);
  assert.match(zig, /\.flags = commitScalars\(bool, value\.flags, mode\)/);
  assert.match(zig, /\.pending = if \(value\.pending\) \|opt\| commitScalars\(f64, opt, mode\) else null/);
});

test("R7d null-guarded && chains take the three spellings by position", () => {
  const zig = emit(`
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
export function asValue(model: Model): boolean {
  return model.sel !== null && model.sel.at > 0;
}
export function ternary(model: Model): number {
  return model.sel !== null && model.sel.at > 0 ? model.sel.at : -1;
}
`);
  // Statement without else: nested R7 capture blocks.
  assert.match(zig, /if \(model\.sel\) \|sel\| \{/);
  // Value position: the capturing if-expression.
  assert.match(zig, /\(if \(model\.sel\) \|sel\| sel\.at > 0 else false\)/);
  // Ternary: unwrap spelling so the narrowed branch can read the target.
  assert.match(zig, /if \(model\.sel != null and model\.sel\.\?\.at > 0\) model\.sel\.\?\.at else -1/);
});

test("R7d the || dual narrows after an exiting guard", () => {
  const zig = emit(`
export interface Sel { readonly items: readonly number[]; readonly at: number; }
export function firstOrMinus(sel: Sel | null): number {
  if (sel === null || sel.items.length === 0) return -1;
  return sel.items[0];
}
`);
  assert.match(zig, /if \(sel == null or @as\(i64, @intCast\(sel\.\?\.items\.len\)\) == 0\) \{/);
  assert.match(zig, /return sel\.\?\.items\[0\];/);
});

test("-0 emits the f64 literal, never the integer zero", () => {
  const zig = emit(`
export function negZero(): number { return -0; }
export function prodNegZero(): number { return 0 * -1; }
`);
  assert.match(zig, /pub fn negZero\(\) f64 \{\n    return -0\.0;/);
  assert.match(zig, /pub fn prodNegZero\(\) f64 \{\n    return -0\.0;/);
});

test("exported single-Model-param helpers forward as Model declarations (markup fn-backed scalars)", () => {
  const zig = emit(`
export interface Task { readonly id: number; readonly done: boolean; }
export interface Model { readonly tasks: readonly Task[]; readonly nextId: number; }
export type Msg = { readonly kind: "a" } | { readonly kind: "b" };
export function initialModel(): Model { return { tasks: [], nextId: 1 }; }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) { case "a": return model; case "b": return model; }
}
export function remainingCount(model: Model): number {
  return model.tasks.filter((t) => !t.done).length;
}
export function openTasks(model: Model): readonly Task[] {
  return model.tasks.filter((t) => !t.done);
}
function internalHelper(model: Model): number { return model.nextId; }
export function twoParams(model: Model, n: number): number { return model.nextId + n; }
`);
  // The forwarder rides the Model struct under the helper's own TS name
  // (markup binds {remainingCount}) with the fn-backed-scalar shape
  // (fn (self: *const Model) V).
  assert.match(zig, /pub fn remainingCount\(self: \*const Model\) i64 \{\n        return core_root\.remainingCount\(self\);/);
  // Slice-returning helpers forward too (markup iterables).
  assert.match(zig, /pub fn openTasks\(self: \*const Model\) \[\]const \*const Task \{/);
  // Unexported and multi-parameter functions never forward.
  assert.ok(!zig.includes("internalHelper(self"), "unexported helper must not forward");
  assert.ok(!zig.includes("twoParams(self"), "multi-param helper must not forward");
  // The module-level helper is still emitted for wiring/tests to call.
  assert.match(zig, /pub fn remainingCount\(model: \*const Model\) i64 \{/);
});

test("a helper whose forwarder shares its module-level name forwards through core_root (no self-recursion)", () => {
  const zig = emit(`
export interface Model { readonly count: number; }
export type Msg = { readonly kind: "a" } | { readonly kind: "b" };
export function initialModel(): Model { return { count: 0 }; }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) { case "a": return model; case "b": return model; }
}
export function total(model: Model): number { return model.count + 1; }
`);
  assert.match(zig, /const core_root = @This\(\);/);
  assert.match(zig, /pub fn total\(self: \*const Model\) i64 \{\n        return core_root\.total\(self\);/);
});

test("update/initialModel/subscriptions never forward as Model declarations", () => {
  const zig = emit(`
import { Sub } from "@native-sdk/core";
export interface Model { readonly on: boolean; }
export type Msg = { readonly kind: "tick"; readonly at: number } | { readonly kind: "stop" };
export function initialModel(): Model { return { on: true }; }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) { case "tick": return model; case "stop": return { on: false }; }
}
export function subscriptions(model: Model): Sub<Msg> {
  if (!model.on) return Sub.none;
  return Sub.timer("tick", 1000, "tick");
}
`);
  assert.ok(!zig.includes("pub fn subscriptions(self"), "subscriptions must not forward");
  assert.ok(!zig.includes("pub fn update(self"), "update must not forward");
});

test("viewUnbound emits the view_unbound opt-out on Model and Msg, never a rodata table", () => {
  const zig = emit(`
export interface Model { readonly count: number; readonly nextId: number; }
export type Msg = { readonly kind: "add" } | { readonly kind: "chrome_changed"; readonly inset: number };
export const viewUnbound = ["nextId", "chrome_changed", "auditCount"] as const;
export function initialModel(): Model { return { count: 0, nextId: 1 }; }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) { case "add": return { ...model, count: model.count + 1, nextId: model.nextId + 1 }; case "chrome_changed": return model; }
}
export function auditCount(model: Model): number { return model.count; }
`);
  assert.match(zig, /pub const Model = struct \{[\s\S]*?pub const view_unbound = \.\{ "nextId", "auditCount" \};[\s\S]*?\};/);
  assert.match(zig, /pub const Msg = union\(enum\) \{[\s\S]*?pub const view_unbound = \.\{ "chrome_changed" \};[\s\S]*?\};/);
  assert.ok(!zig.includes("viewUnbound"), "the config list itself never emits");
});

test("R7B envMsgs emits the comptime tuple the wiring walks", () => {
  const zig = emit(`
export interface Model { readonly base: Uint8Array; }
export type Msg =
  | { readonly kind: "noop" }
  | { readonly kind: "set_base"; readonly value: Uint8Array };
export const envMsgs = [{ env: "NATIVE_SDK_MUSIC_URL_BASE", msg: "set_base" }] as const;
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "noop": return model;
    case "set_base": return { base: msg.value };
  }
}
`);
  assert.match(zig, /pub const envMsgs = \.\{/);
  assert.match(zig, /\.\{ \.env = "NATIVE_SDK_MUSIC_URL_BASE", \.msg = "set_base" \}/);
});

test("NS1033 envMsgs targeting a non-bytes arm is taught", () => {
  const result = transpile(`
export interface Model { readonly n: number; }
export type Msg = { readonly kind: "noop" } | { readonly kind: "tick"; readonly at: number };
export const envMsgs = [{ env: "X", msg: "tick" }] as const;
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) { case "noop": return model; case "tick": return { n: msg.at }; }
}
`);
  assert.equal(result.ok, false);
  assert.ok(result.diagnostics.some((d) => d.id === "NS1033"), JSON.stringify(result.diagnostics));
});

test("NS1033 appearanceMsg requires the appearance record shape", () => {
  const result = transpile(`
export interface Model { readonly n: number; }
export type Msg = { readonly kind: "noop" } | { readonly kind: "flipped"; readonly dark: boolean };
export const appearanceMsg = "flipped";
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) { case "noop": return model; case "flipped": return { n: msg.dark ? 1 : 0 }; }
}
`);
  assert.equal(result.ok, false);
  assert.ok(result.diagnostics.some((d) => d.id === "NS1033"), JSON.stringify(result.diagnostics));
});

test("R7B the appearance and chrome channels emit with their declared records", () => {
  const zig = emit(`
export type ColorScheme = "light" | "dark";
export interface ChromeInsets { readonly top: number; readonly right: number; readonly bottom: number; readonly left: number; }
export interface ChromeButtons { readonly x: number; readonly y: number; readonly width: number; readonly height: number; }
export interface Model { readonly dark: boolean; readonly pad: number; }
export type Msg =
  | { readonly kind: "appearance_changed"; readonly colorScheme: ColorScheme; readonly reduceMotion: boolean; readonly highContrast: boolean }
  | { readonly kind: "chrome_changed"; readonly insets: ChromeInsets; readonly buttons: ChromeButtons; readonly tabsProjected: boolean };
export const appearanceMsg = "appearance_changed";
export const chromeMsg = "chrome_changed";
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "appearance_changed": return { ...model, dark: msg.colorScheme === "dark" };
    case "chrome_changed": return { ...model, pad: msg.insets.top };
  }
}
`);
  assert.match(zig, /pub const appearanceMsg = "appearance_changed";/);
  assert.match(zig, /pub const chromeMsg = "chrome_changed";/);
  assert.match(zig, /appearance_changed: struct \{ colorScheme: ColorScheme, reduceMotion: bool, highContrast: bool \}/);
});

test("NS1033 frameMsg and keyMsg shapes are held to the channel contract", () => {
  const bad_frame = transpile(`
export interface Model { readonly w: number; }
export interface FrameEvent { readonly width: number; }
export type Msg = { readonly kind: "a" } | { readonly kind: "b" };
export function frameMsg(model: Model, frame: FrameEvent): Msg | null { return null; }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) { case "a": return model; case "b": return model; }
}
`);
  assert.equal(bad_frame.ok, false);
  assert.ok(bad_frame.diagnostics.some((d) => d.id === "NS1033"), JSON.stringify(bad_frame.diagnostics));

  const bad_key = transpile(`
export interface Model { readonly w: number; }
export interface KeyEvent { readonly key: string; }
export type Msg = { readonly kind: "a" } | { readonly kind: "b" };
export function keyMsg(key: KeyEvent): Msg | null { return null; }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) { case "a": return model; case "b": return model; }
}
`);
  assert.equal(bad_key.ok, false);
  assert.ok(bad_key.diagnostics.some((d) => d.id === "NS1033"), JSON.stringify(bad_key.diagnostics));
});

test("pinchMsg emits with boundary-float record fields and holds its channel contract", () => {
  // The good shape: the record's number fields are HOST values classed
  // f64 even against an integer-literal comparison (`scale === 0` must
  // never int-claim the slot — a rounded magnification delta would zero
  // every zoom product; the same wholesale classing covers the windowId
  // identity field against its `=== 0` comparison), and the zoom chain
  // fed from them floats too.
  const zig = emit(`
export type PinchPhase = "begin" | "change" | "end";
export interface PinchEvent { readonly windowId: number; readonly label: string; readonly phase: PinchPhase; readonly scale: number; readonly x: number; readonly y: number; }
export interface Model { readonly zoom: number; }
export type Msg =
  | { readonly kind: "zoomed"; readonly factor: number }
  | { readonly kind: "noop" };
export function pinchMsg(pinch: PinchEvent): Msg | null {
  if (pinch.phase !== "change" || pinch.scale === 0 || pinch.windowId === 0) return null;
  if (pinch.label !== "board-canvas") return null;
  return { kind: "zoomed", factor: 1 + pinch.scale };
}
export function initialModel(): Model { return { zoom: 1 }; }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "zoomed": return { ...model, zoom: model.zoom * msg.factor };
    case "noop": return model;
  }
}
`);
  assert.match(zig, /scale: f64/);
  assert.match(zig, /windowId: f64/);
  assert.match(zig, /label: \[\]const u8/);
  assert.match(zig, /zoom: f64/);
  assert.match(zig, /pub fn pinchMsg/);

  // The bad shape (missing the anchor and identity fields) is a taught
  // NS1033.
  const bad_pinch = transpile(`
export type PinchPhase = "begin" | "change" | "end";
export interface PinchEvent { readonly phase: PinchPhase; readonly scale: number; }
export interface Model { readonly w: number; }
export type Msg = { readonly kind: "a" } | { readonly kind: "b" };
export function pinchMsg(pinch: PinchEvent): Msg | null { return null; }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) { case "a": return model; case "b": return model; }
}
`);
  assert.equal(bad_pinch.ok, false);
  assert.ok(bad_pinch.diagnostics.some((d) => d.id === "NS1033"), JSON.stringify(bad_pinch.diagnostics));

  // The pre-identity 4-field shape is refused too: the channel record
  // carries its source (windowId/label) — x/y are view-local, so a
  // coordinate without its view is not a position.
  const legacy_pinch = transpile(`
export type PinchPhase = "begin" | "change" | "end";
export interface PinchEvent { readonly phase: PinchPhase; readonly scale: number; readonly x: number; readonly y: number; }
export interface Model { readonly w: number; }
export type Msg = { readonly kind: "a" } | { readonly kind: "b" };
export function pinchMsg(pinch: PinchEvent): Msg | null { return null; }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) { case "a": return model; case "b": return model; }
}
`);
  assert.equal(legacy_pinch.ok, false);
  assert.ok(legacy_pinch.diagnostics.some((d) => d.id === "NS1033"), JSON.stringify(legacy_pinch.diagnostics));
});

test("pinchMsg exported via an export list keeps the boundary-float classing", () => {
  // The export-LIST spelling is first-class for entry points (an
  // un-renamed entry exports the declaration itself), so it must class
  // the pinch record's fields exactly like the inline modifier: `scale
  // === 0` never int-claims the slot. Before the seam covered export
  // lists, this spelling silently emitted `scale: i64` — every real
  // magnification delta rounded to 0 and the host adapter's zero gate
  // dropped the events.
  const zig = emit(`
export type PinchPhase = "begin" | "change" | "end";
export interface PinchEvent { readonly windowId: number; readonly label: string; readonly phase: PinchPhase; readonly scale: number; readonly x: number; readonly y: number; }
export interface Model { readonly zoom: number; }
export type Msg =
  | { readonly kind: "zoomed"; readonly factor: number }
  | { readonly kind: "noop" };
function pinchMsg(pinch: PinchEvent): Msg | null {
  if (pinch.phase !== "change" || pinch.scale === 0 || pinch.windowId === 0) return null;
  if (pinch.label !== "board-canvas") return null;
  return { kind: "zoomed", factor: 1 + pinch.scale };
}
export { pinchMsg };
export function initialModel(): Model { return { zoom: 1 }; }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "zoomed": return { ...model, zoom: model.zoom * msg.factor };
    case "noop": return model;
  }
}
`);
  assert.match(zig, /scale: f64/);
  assert.match(zig, /windowId: f64/);
  assert.match(zig, /zoom: f64/);
  assert.match(zig, /pub fn pinchMsg/);
});

test("frameMsg exported via an export list emits its channel and holds the contract", () => {
  // The sibling channels go through the same export seam: the list
  // spelling emits the wired `pub fn` and the NS1033 shape contract
  // still gates it.
  const zig = emit(`
export interface Model { readonly w: number; }
export interface FrameEvent { readonly width: number; readonly height: number; readonly timestampMs: number; readonly intervalMs: number; }
export type Msg = { readonly kind: "resized"; readonly w: number } | { readonly kind: "noop" };
function frameMsg(model: Model, frame: FrameEvent): Msg | null {
  if (frame.width !== model.w) return { kind: "resized", w: frame.width };
  return null;
}
export { frameMsg };
export function initialModel(): Model { return { w: 0 }; }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) { case "resized": return { w: msg.w }; case "noop": return model; }
}
`);
  assert.match(zig, /pub fn frameMsg/);

  const bad_frame = transpile(`
export interface Model { readonly w: number; }
export interface FrameEvent { readonly width: number; }
export type Msg = { readonly kind: "a" } | { readonly kind: "b" };
function frameMsg(model: Model, frame: FrameEvent): Msg | null { return null; }
export { frameMsg };
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) { case "a": return model; case "b": return model; }
}
`);
  assert.equal(bad_frame.ok, false);
  assert.ok(bad_frame.diagnostics.some((d) => d.id === "NS1033"), JSON.stringify(bad_frame.diagnostics));
});

test("an export-list-exported function's number params are host-boundary", () => {
  // The general shape of the same seam: `export { scaled }` puts the
  // function on the entry's host surface exactly like the modifier, so a
  // `=== 0` comparison must widen instead of int-claiming the parameter
  // (an i64 signature would truncate host f64 arguments).
  const zig = emit(`
function scaled(x: number): number { return x === 0 ? -1 : x * 4; }
export { scaled };
`);
  assert.match(zig, /pub fn scaled\(x: f64\)/);
});

test("NS1014: a renamed export list entry cannot bind a wiring entry name", () => {
  // NS1014's fencing is unchanged by the export-list marking: the build
  // wires the DECLARATION, so a renamed binding over a wiring name is
  // still taught, never silently wired.
  const renamed = transpile(`
export type PinchPhase = "begin" | "change" | "end";
export interface PinchEvent { readonly windowId: number; readonly label: string; readonly phase: PinchPhase; readonly scale: number; readonly x: number; readonly y: number; }
export interface Model { readonly zoom: number; }
export type Msg = { readonly kind: "a" } | { readonly kind: "b" };
function zoomIn(pinch: PinchEvent): Msg | null { return null; }
export { zoomIn as pinchMsg };
export function initialModel(): Model { return { zoom: 1 }; }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) { case "a": return model; case "b": return model; }
}
`);
  assert.equal(renamed.ok, false);
  assert.ok(renamed.diagnostics.some((d) => d.id === "NS1014"), JSON.stringify(renamed.diagnostics));
});
