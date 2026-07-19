// Run-fidelity corpus: a subset program that transpiles must not just compile
// to Zig (conformance.test.ts pins that) — it must RUN with byte-identical
// observable behavior to the same source executing as plain TypeScript. Each
// case here runs twice from one source: the node side imports the module
// directly (type stripping; the A/B shape the spike harness proved), the
// native side runs the emitted Zig against the rt kernel, and the two
// transcripts are compared byte for byte.
//
// Canonical value text (both drivers emit exactly this grammar):
//   n:<16 hex digits>   a number, as its f64 bit pattern (any NaN -> n:nan) —
//                       bit-comparing sidesteps float formatting and makes
//                       -0, precision, and rounding corners first-class
//   b:true / b:false    a boolean
//   null                a null
//   x:<hex bytes>       bytes, strings, and literal-union members (tag name)
//   [v,v,...]           a number array, elementwise
//
// The corpus leans on the JS corners where naive Zig disagrees: NaN through
// comparisons and Math.min/max, signed zeros, Math.round's half-toward-+inf,
// ToInt32 bitwise wrapping, float division/remainder by zero, and null-safe
// optional comparisons. Both halves skip when no zig toolchain is on PATH.

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

type Arg =
  | { readonly t: "i"; readonly v: number }
  | { readonly t: "f"; readonly v: number | "nan" | "inf" | "-inf" | "-0" }
  | { readonly t: "b"; readonly v: boolean }
  | { readonly t: "null" }
  | { readonly t: "bytes"; readonly v: readonly number[] }
  | { readonly t: "nums"; readonly v: readonly (number | "nan" | "-0")[] }
  | { readonly t: "tag"; readonly v: string }
  | { readonly t: "str"; readonly v: string };

interface Call {
  readonly fn: string;
  readonly args: readonly Arg[];
}

interface RunCase {
  readonly name: string;
  readonly src: string;
  /// Additional modules beside the entry (multi-file cores): filename ->
  /// source. `src` stays the entry (core.ts); every file lands in the
  /// case's own directory, so relative imports spell "./name.ts".
  readonly files?: Record<string, string>;
  /// Primitive probe calls, spelled identically for both drivers.
  readonly calls?: readonly Call[];
  /// Custom driver bodies for shapes the call vocabulary cannot spell
  /// (dispatch loops over Msg unions, the Cmd effects channel). The node
  /// body sees `mod` and pushes formatted lines through `line(tag, value)`;
  /// the zig body sees `m` and the `row(tag, value)` helper. Both must emit
  /// the same tags in the same order.
  readonly node?: string;
  readonly zig?: string;
  /// Transpile options for the native side (kernel capacities — node has a
  /// GC and no arenas, so the same source runs unchanged there; the
  /// transcripts must STILL match byte for byte).
  readonly options?: import("../src/transpile.ts").TranspileOptions;
}

const i = (v: number): Arg => ({ t: "i", v });
const f = (v: number | "nan" | "inf" | "-inf" | "-0"): Arg => ({ t: "f", v });

const runCorpus: RunCase[] = [
  {
    name: "optional numeric comparisons are null-safe (null equals only null)",
    src: `
export function isZero(cls: number | null): boolean {
  return cls === 0;
}
export function nonZero(cls: number | null): boolean {
  return cls !== 0;
}
export function label(cls: number | null): number {
  return cls === 0 ? 1 : cls !== 0 ? 2 : 3;
}
export function gate(cls: number | null, flag: boolean): boolean {
  return flag && cls === 1;
}
export function either(a: number | null, b: number | null): boolean {
  return a === b;
}
`,
    calls: [
      { fn: "isZero", args: [{ t: "null" }] },
      { fn: "isZero", args: [i(0)] },
      { fn: "isZero", args: [i(1)] },
      { fn: "nonZero", args: [{ t: "null" }] },
      { fn: "nonZero", args: [i(0)] },
      { fn: "nonZero", args: [i(5)] },
      { fn: "label", args: [{ t: "null" }] },
      { fn: "label", args: [i(0)] },
      { fn: "label", args: [i(9)] },
      { fn: "gate", args: [{ t: "null" }, { t: "b", v: true }] },
      { fn: "gate", args: [i(1), { t: "b", v: true }] },
      { fn: "gate", args: [{ t: "null" }, { t: "b", v: false }] },
      { fn: "either", args: [{ t: "null" }, { t: "null" }] },
      { fn: "either", args: [{ t: "null" }, f(2)] },
      { fn: "either", args: [f(2), f(2)] },
      { fn: "either", args: [f(2), f(3)] },
    ],
  },
  {
    name: "null flows: orelse fusion, nullish fallback, optional guard in a switch arm",
    src: `
export type Msg = { readonly kind: "set"; readonly v: number } | { readonly kind: "clear" };
export function find(xs: Uint8Array, want: number): number | null {
  for (let idx = 0; idx < xs.length; idx++) {
    if (xs[idx] === want) return idx;
  }
  return null;
}
export function findOrZero(xs: Uint8Array, want: number): number {
  const hit = find(xs, want);
  if (hit === null) return 0;
  return hit;
}
export function fallback(cursor: number | null): number {
  return cursor ?? 7;
}
export function apply(sel: number, v: number, prev: number | null): number {
  const msg: Msg = sel === 0 ? { kind: "set", v: v } : { kind: "clear" };
  switch (msg.kind) {
    case "set": return prev === 0 ? msg.v + 100 : msg.v;
    case "clear": return prev !== 0 ? 1 : 0;
  }
}
`,
    calls: [
      { fn: "find", args: [{ t: "bytes", v: [9, 4, 7] }, i(7)] },
      { fn: "find", args: [{ t: "bytes", v: [9, 4, 7] }, i(5)] },
      { fn: "findOrZero", args: [{ t: "bytes", v: [9, 4, 7] }, i(4)] },
      { fn: "findOrZero", args: [{ t: "bytes", v: [] }, i(4)] },
      { fn: "fallback", args: [{ t: "null" }] },
      { fn: "fallback", args: [i(3)] },
      { fn: "apply", args: [i(0), i(5), i(0)] },
      { fn: "apply", args: [i(0), i(5), { t: "null" }] },
      { fn: "apply", args: [i(1), i(5), { t: "null" }] },
      { fn: "apply", args: [i(1), i(5), i(0)] },
      { fn: "apply", args: [i(1), i(5), i(2)] },
    ],
  },
  {
    // A branch that reassigns a narrowed optional to null widens it back;
    // the post-merge null check must test the LIVE value. If the branch
    // exit resurrected the dead narrow, the null path here would read the
    // pre-branch payload (returning v + 1) instead of taking the re-check
    // (returning 0) — the transcripts would diverge on the flag=true rows.
    name: "a branch reassigning a narrowed optional to null drives the post-merge re-check",
    src: `
export function merge(q: number | null, flag: boolean): number {
  let p: number | null = q;
  if (p === null) { return -1; }
  if (flag) {
    p = null;
  }
  if (p === null) { return 0; }
  return p + 1;
}
`,
    calls: [
      { fn: "merge", args: [{ t: "null" }, { t: "b", v: true }] },
      { fn: "merge", args: [{ t: "null" }, { t: "b", v: false }] },
      { fn: "merge", args: [f(4), { t: "b", v: true }] },
      { fn: "merge", args: [f(4), { t: "b", v: false }] },
    ],
  },
  {
    name: "orelse fusion over a ternary initializer keeps both arms (parenthesized conditional)",
    src: `
export function low(bytes: Uint8Array): number | null {
  if (bytes.length === 0) return null;
  return bytes[0];
}
export function high(bytes: Uint8Array): number | null {
  if (bytes.length < 2) return null;
  return bytes[1];
}
export function pick(first: boolean, bytes: Uint8Array): number {
  const v = first ? low(bytes) : high(bytes);
  if (v === null) return -1;
  return v;
}
`,
    calls: [
      { fn: "pick", args: [{ t: "b", v: true }, { t: "bytes", v: [9, 4] }] },
      { fn: "pick", args: [{ t: "b", v: false }, { t: "bytes", v: [9, 4] }] },
      { fn: "pick", args: [{ t: "b", v: true }, { t: "bytes", v: [] }] },
      { fn: "pick", args: [{ t: "b", v: false }, { t: "bytes", v: [9] }] },
    ],
  },
  {
    name: "float arithmetic corners: precision, signed zero, division and remainder by zero",
    src: `
export function fadd(a: number, b: number): number {
  return a + b;
}
export function fmul(a: number, b: number): number {
  return a * b;
}
export function fdiv(a: number, b: number): number {
  return a / b;
}
export function fmod(a: number, b: number): number {
  return a % b;
}
export function feq(a: number, b: number): boolean {
  return a === b;
}
export function flt(a: number, b: number): boolean {
  return a < b;
}
export function fge(a: number, b: number): boolean {
  return a >= b;
}
export function halfLen(bytes: Uint8Array): number {
  return bytes.length / 2;
}
`,
    calls: [
      { fn: "fadd", args: [f(0.1), f(0.2)] },
      { fn: "fmul", args: [f(-1), f(0)] },
      { fn: "fmul", args: [f(0.1), f(0.1)] },
      { fn: "fdiv", args: [f(1), f(3)] },
      { fn: "fdiv", args: [f(1), f(0)] },
      { fn: "fdiv", args: [f(-1), f(0)] },
      { fn: "fdiv", args: [f(1), f("-0")] },
      { fn: "fdiv", args: [f(0), f(0)] },
      { fn: "fdiv", args: [f(5), f(2)] },
      { fn: "fmod", args: [f(5.5), f(2)] },
      { fn: "fmod", args: [f(-5.5), f(2)] },
      { fn: "fmod", args: [f(1), f(0)] },
      { fn: "fmod", args: [f("inf"), f(2)] },
      { fn: "fmod", args: [f(3), f("inf")] },
      { fn: "feq", args: [f("nan"), f("nan")] },
      { fn: "feq", args: [f(0), f("-0")] },
      { fn: "flt", args: [f("nan"), f(1)] },
      { fn: "fge", args: [f("nan"), f(1)] },
      { fn: "flt", args: [f("-inf"), f(1)] },
      { fn: "halfLen", args: [{ t: "bytes", v: [1, 2, 3, 4, 5] }] },
      { fn: "halfLen", args: [{ t: "bytes", v: [1, 2, 3] }] },
    ],
  },
  {
    name: "Math corners: min/max NaN propagation and zero order, round half toward +inf",
    src: `
export function lo(a: number, b: number): number {
  return Math.min(a, b);
}
export function hi(a: number, b: number): number {
  return Math.max(a, b);
}
export function nearest(x: number): number {
  return Math.round(x);
}
`,
    calls: [
      { fn: "lo", args: [f("nan"), f(1)] },
      { fn: "lo", args: [f(1), f("nan")] },
      { fn: "lo", args: [f(0), f("-0")] },
      { fn: "lo", args: [f("-0"), f(0)] },
      { fn: "lo", args: [f(2), f(3)] },
      { fn: "hi", args: [f(0), f("-0")] },
      { fn: "hi", args: [f("-0"), f("-0")] },
      { fn: "hi", args: [f("nan"), f("-inf")] },
      { fn: "hi", args: [f(2), f(3)] },
      { fn: "nearest", args: [f(0.5)] },
      { fn: "nearest", args: [f(-0.5)] },
      { fn: "nearest", args: [f(2.5)] },
      { fn: "nearest", args: [f(-2.5)] },
      { fn: "nearest", args: [f(0.49999999999999994)] },
      { fn: "nearest", args: [f(-0.4)] },
      { fn: "nearest", args: [f("-0")] },
      { fn: "nearest", args: [f(4503599627370495.5)] },
      { fn: "nearest", args: [f("nan")] },
      { fn: "nearest", args: [f("inf")] },
      { fn: "nearest", args: [f(1.5)] },
    ],
  },
  {
    name: "bitwise ToInt32: out-of-range and negative operands wrap like the source",
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
    calls: [
      { fn: "band", args: [i(1099511627776), i(1099511627776)] },
      { fn: "band", args: [i(-1), i(255)] },
      { fn: "bor", args: [i(4294967296), i(1)] },
      { fn: "bor", args: [i(-2), i(1)] },
      { fn: "bxor", args: [i(-1), i(1099511627776)] },
      { fn: "bxor", args: [i(2147483648), i(0)] },
      { fn: "bmask", args: [i(1099511627781)] },
      { fn: "bmask", args: [i(-1)] },
      { fn: "band", args: [i(12), i(10)] },
    ],
  },
  {
    name: "integer paths: counting loops, byte reads, template holes, remainder indexing",
    src: `
import { asciiBytes } from "@native-sdk/core";
export function spaces(bytes: Uint8Array): number {
  let n = 0;
  for (let idx = 0; idx < bytes.length; idx++) {
    if (bytes[idx] === 32) n += 1;
  }
  return n;
}
export function label(n: number, bytes: Uint8Array): Uint8Array {
  const probe = bytes[n];
  return asciiBytes(\`item \${n + probe}\`);
}
export function wrapAt(bytes: Uint8Array, at: number): number {
  return bytes[at % bytes.length];
}
`,
    calls: [
      { fn: "spaces", args: [{ t: "bytes", v: [32, 65, 32, 32, 66] }] },
      { fn: "spaces", args: [{ t: "bytes", v: [] }] },
      { fn: "label", args: [i(1), { t: "bytes", v: [10, 20, 30] }] },
      { fn: "wrapAt", args: [{ t: "bytes", v: [5, 6, 7] }, i(7)] },
      { fn: "wrapAt", args: [{ t: "bytes", v: [5, 6, 7] }, i(2)] },
    ],
  },
  {
    name: "bytes ops: subarray views, slice copies, set stitching",
    src: `
export function tail(bytes: Uint8Array, from: number): Uint8Array {
  return bytes.slice(from, bytes.length);
}
export function head(bytes: Uint8Array, upTo: number): Uint8Array {
  return bytes.subarray(0, upTo);
}
export function stitch(a: Uint8Array, b: Uint8Array): Uint8Array {
  const out = new Uint8Array(a.length + b.length);
  out.set(a, 0);
  out.set(b, a.length);
  return out;
}
`,
    calls: [
      { fn: "tail", args: [{ t: "bytes", v: [1, 2, 3, 4] }, i(2)] },
      { fn: "tail", args: [{ t: "bytes", v: [1, 2] }, i(2)] },
      { fn: "head", args: [{ t: "bytes", v: [9, 8, 7] }, i(2)] },
      { fn: "stitch", args: [{ t: "bytes", v: [1, 2] }, { t: "bytes", v: [3] }] },
      { fn: "stitch", args: [{ t: "bytes", v: [] }, { t: "bytes", v: [] }] },
    ],
  },
  {
    name: "literal unions at runtime: cross-enum equality, optional tags, re-tagging",
    src: `
export type Category = "food" | "travel" | "gear";
export type CategoryFilter = "all" | "food" | "travel" | "gear";
export function matches(category: Category, filter: CategoryFilter | null): boolean {
  return filter === null || category === filter;
}
export function pick(category: Category, everything: boolean): CategoryFilter {
  const filter: CategoryFilter = everything ? "all" : category;
  return filter;
}
export function differs(s: Category, b: CategoryFilter): boolean {
  return s !== b;
}
export function same(s: Category | null, b: CategoryFilter | null): boolean {
  return s === b;
}
`,
    calls: [
      { fn: "matches", args: [{ t: "tag", v: "food" }, { t: "null" }] },
      { fn: "matches", args: [{ t: "tag", v: "food" }, { t: "tag", v: "food" }] },
      { fn: "matches", args: [{ t: "tag", v: "food" }, { t: "tag", v: "gear" }] },
      { fn: "matches", args: [{ t: "tag", v: "food" }, { t: "tag", v: "all" }] },
      { fn: "pick", args: [{ t: "tag", v: "travel" }, { t: "b", v: false }] },
      { fn: "pick", args: [{ t: "tag", v: "food" }, { t: "b", v: true }] },
      { fn: "differs", args: [{ t: "tag", v: "food" }, { t: "tag", v: "food" }] },
      { fn: "differs", args: [{ t: "tag", v: "food" }, { t: "tag", v: "all" }] },
      { fn: "same", args: [{ t: "null" }, { t: "null" }] },
      { fn: "same", args: [{ t: "null" }, { t: "tag", v: "food" }] },
      { fn: "same", args: [{ t: "tag", v: "food" }, { t: "null" }] },
      { fn: "same", args: [{ t: "tag", v: "food" }, { t: "tag", v: "food" }] },
      { fn: "same", args: [{ t: "tag", v: "gear" }, { t: "tag", v: "all" }] },
    ],
  },
  {
    name: "union narrowing through a selector-built value and payload math",
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
    calls: [
      { fn: "weigh", args: [i(0), { t: "bytes", v: [1, 2, 3] }, f(0), f(0)] },
      { fn: "weigh", args: [i(1), { t: "bytes", v: [] }, f(2.5), f(-1)] },
      { fn: "weigh", args: [i(2), { t: "bytes", v: [] }, f(0), f(0)] },
    ],
  },
  {
    name: "number arrays: map/filter lowering keeps float element math",
    src: `
export function scaled(xs: readonly number[], k: number): readonly number[] {
  return xs.map((x) => x * k);
}
export function bigs(xs: readonly number[], lim: number): readonly number[] {
  return xs.filter((x) => x > lim);
}
`,
    calls: [
      { fn: "scaled", args: [{ t: "nums", v: [1.5, -2, 0.1] }, f(3)] },
      { fn: "scaled", args: [{ t: "nums", v: [] }, f(2)] },
      { fn: "bigs", args: [{ t: "nums", v: [0.5, 2, -3, 7] }, f(1)] },
      { fn: "bigs", args: [{ t: "nums", v: [0.5] }, f(1)] },
    ],
  },
  {
    name: "record model dispatch: spread updates, map toggles, filter purges",
    src: `
export interface Task { readonly id: number; readonly done: boolean; }
export interface Model { readonly tasks: readonly Task[]; readonly nextId: number; }
export type Msg =
  | { readonly kind: "add" }
  | { readonly kind: "toggle"; readonly id: number }
  | { readonly kind: "purge" };
export function initialModel(): Model {
  return { tasks: [], nextId: 1 };
}
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
export function doneCount(model: Model): number {
  return model.tasks.filter((t) => t.done).length;
}
export function idSum(model: Model): number {
  let total = 0;
  for (let idx = 0; idx < model.tasks.length; idx++) {
    total += model.tasks[idx].id;
  }
  return total;
}
`,
    node: `
{
  let model = mod.initialModel();
  model = mod.update(model, { kind: "add" });
  model = mod.update(model, { kind: "add" });
  model = mod.update(model, { kind: "add" });
  model = mod.update(model, { kind: "toggle", id: 2 });
  line("s0", mod.doneCount(model));
  line("s1", mod.idSum(model));
  model = mod.update(model, { kind: "purge" });
  line("s2", mod.idSum(model));
  line("s3", model.nextId);
}
`,
    zig: `
    {
        var model = m.initialModel();
        model = m.update(model, .add);
        model = m.update(model, .add);
        model = m.update(model, .add);
        model = m.update(model, .{ .toggle = 2 });
        row("s0", m.doneCount(model));
        row("s1", m.idSum(model));
        model = m.update(model, .purge);
        row("s2", m.idSum(model));
        row("s3", model.nextId);
    }
`,
  },
  {
    name: "Cmd effects channel: encoded command bytes match the SDK factories",
    src: `
import { Cmd } from "@native-sdk/core";
export interface Model { readonly count: number; readonly saved: number; }
export type Msg =
  | { readonly kind: "add" }
  | { readonly kind: "save" }
  | { readonly kind: "stamp" }
  | { readonly kind: "tick"; readonly at: number };
export function initialModel(): Model {
  return { count: 0, saved: 0 };
}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "add": return { ...model, count: model.count + 1 };
    case "save": return [{ ...model, saved: model.count }, model.count > 2 ? Cmd.persist() : Cmd.none];
    case "stamp": return [model, Cmd.batch([Cmd.now("tick"), Cmd.host("beep", model.count, 0.5)])];
    case "tick": return { ...model, count: msg.at };
  }
}
`,
    node: `
{
  // Msg arm order, for Cmd.now's declaration-order tag byte.
  const kinds = ["add", "save", "stamp", "tick"];
  // Mirror of the rt kernel's Cmd wire format v1 (rt.zig): flat op records,
  // batch = concatenation, args as f64 little-endian.
  const enc = (cmd) => {
    if (cmd.op === "none") return [];
    if (cmd.op === "persist") return [1];
    if (cmd.op === "now") return [2, kinds.indexOf(cmd.msgKind)];
    if (cmd.op === "host") {
      const name = Array.from(new TextEncoder().encode(cmd.name));
      const bytes = [3, name.length, ...name, cmd.args.length];
      for (const a of cmd.args) {
        const dv = new DataView(new ArrayBuffer(8));
        dv.setFloat64(0, a, true);
        for (let idx = 0; idx < 8; idx++) bytes.push(dv.getUint8(idx));
      }
      return bytes;
    }
    return cmd.cmds.flatMap(enc);
  };
  const step = (model, msg) => {
    const r = mod.update(model, msg);
    return Array.isArray(r) ? [r[0], Uint8Array.from(enc(r[1]))] : [r, Uint8Array.from([])];
  };
  let model = mod.initialModel();
  let cmd;
  [model, cmd] = step(model, { kind: "add" });
  line("e0m", model.count);
  line("e0c", cmd);
  [model, cmd] = step(model, { kind: "save" });
  line("e1s", model.saved);
  line("e1c", cmd);
  [model, cmd] = step(model, { kind: "add" });
  [model, cmd] = step(model, { kind: "add" });
  [model, cmd] = step(model, { kind: "save" });
  line("e2s", model.saved);
  line("e2c", cmd);
  [model, cmd] = step(model, { kind: "stamp" });
  line("e3c", cmd);
  [model, cmd] = step(model, { kind: "tick", at: 41 });
  line("e4m", model.count);
  line("e4c", cmd);
}
`,
    zig: `
    {
        var model = m.initialModel();
        var r = m.update(model, .add);
        model = r.model;
        row("e0m", model.count);
        row("e0c", r.cmd);
        r = m.update(model, .save);
        model = r.model;
        row("e1s", model.saved);
        row("e1c", r.cmd);
        r = m.update(model, .add);
        model = r.model;
        r = m.update(model, .add);
        model = r.model;
        r = m.update(model, .save);
        model = r.model;
        row("e2s", model.saved);
        row("e2c", r.cmd);
        r = m.update(model, .stamp);
        model = r.model;
        row("e3c", r.cmd);
        r = m.update(model, .{ .tick = 41 });
        model = r.model;
        row("e4m", model.count);
        row("e4c", r.cmd);
    }
`,
  },
  {
    name: "optional chains: short-circuit and present-value paths behave identically",
    src: `
export interface Sel { readonly at: number; readonly len: number; }
export interface Model { readonly sel: Sel | null; readonly fallback: number; }
export type Msg =
  | { readonly kind: "pick"; readonly at: number; readonly len: number }
  | { readonly kind: "clear" };
export function initialModel(): Model {
  return { sel: null, fallback: 7 };
}
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "pick": return { ...model, sel: { at: msg.at, len: msg.len } };
    case "clear": return { ...model, sel: null };
  }
}
export function selEnd(model: Model): number {
  return (model.sel?.at ?? -1) + (model.sel?.len ?? 0);
}
export function hasWide(model: Model): boolean {
  return (model.sel?.len ?? 0) > 2;
}
export function pickedAtFour(model: Model): number {
  if (model.sel?.at === 4) return 1;
  return 0;
}
export function atOrFallback(model: Model): number {
  return model.sel?.at ?? model.fallback;
}
`,
    node: `
{
  let model = mod.initialModel();
  line("q0", mod.selEnd(model));
  line("q1", mod.hasWide(model));
  line("q2", mod.pickedAtFour(model));
  line("q3", mod.atOrFallback(model));
  model = mod.update(model, { kind: "pick", at: 4, len: 3 });
  line("q4", mod.selEnd(model));
  line("q5", mod.hasWide(model));
  line("q6", mod.pickedAtFour(model));
  line("q7", mod.atOrFallback(model));
  model = mod.update(model, { kind: "clear" });
  line("q8", mod.selEnd(model));
}
`,
    zig: `
    {
        var model = m.initialModel();
        row("q0", m.selEnd(model));
        row("q1", m.hasWide(model));
        row("q2", m.pickedAtFour(model));
        row("q3", m.atOrFallback(model));
        model = m.update(model, .{ .pick = .{ .at = 4, .len = 3 } });
        row("q4", m.selEnd(model));
        row("q5", m.hasWide(model));
        row("q6", m.pickedAtFour(model));
        row("q7", m.atOrFallback(model));
        model = m.update(model, .clear);
        row("q8", m.selEnd(model));
    }
`,
  },
  {
    name: "string equality: content comparison, null table, tag-name against string",
    src: `
export type Filter = "all" | "active" | "done";
export function commandCode(name: string): number {
  if (name === "app.add") return 1;
  if (name !== "app.remove") return 0;
  return 2;
}
export function sameName(a: string, b: string): boolean {
  return a === b;
}
export function pick(name: string | null): number {
  if (name === "left") return 1;
  if (name !== "right") return 2;
  return 3;
}
export function matchesName(f: Filter, name: string): boolean {
  return f === name;
}
`,
    calls: [
      { fn: "commandCode", args: [{ t: "str", v: "app.add" }] },
      { fn: "commandCode", args: [{ t: "str", v: "app.remove" }] },
      { fn: "commandCode", args: [{ t: "str", v: "other" }] },
      { fn: "commandCode", args: [{ t: "str", v: "" }] },
      { fn: "sameName", args: [{ t: "str", v: "a" }, { t: "str", v: "a" }] },
      { fn: "sameName", args: [{ t: "str", v: "a" }, { t: "str", v: "b" }] },
      { fn: "sameName", args: [{ t: "str", v: "" }, { t: "str", v: "" }] },
      { fn: "pick", args: [{ t: "null" }] },
      { fn: "pick", args: [{ t: "str", v: "left" }] },
      { fn: "pick", args: [{ t: "str", v: "right" }] },
      { fn: "pick", args: [{ t: "str", v: "middle" }] },
      { fn: "matchesName", args: [{ t: "tag", v: "all" }, { t: "str", v: "all" }] },
      { fn: "matchesName", args: [{ t: "tag", v: "done" }, { t: "str", v: "all" }] },
      { fn: "matchesName", args: [{ t: "tag", v: "active" }, { t: "str", v: "activex" }] },
    ],
  },
  {
    name: "for...of: sums with break and continue over bytes and number arrays",
    src: `
export function sumBytes(bytes: Uint8Array, stop: number): number {
  let total = 0;
  for (const b of bytes) {
    if (b === stop) break;
    if (b === 0) continue;
    total += b;
  }
  return total;
}
export function product(xs: readonly number[]): number {
  let p = 1;
  for (const x of xs) {
    p = p * x;
  }
  return p;
}
`,
    calls: [
      { fn: "sumBytes", args: [{ t: "bytes", v: [1, 0, 2, 9, 5] }, i(9)] },
      { fn: "sumBytes", args: [{ t: "bytes", v: [] }, i(9)] },
      { fn: "sumBytes", args: [{ t: "bytes", v: [3, 0, 4] }, i(9)] },
      { fn: "product", args: [{ t: "nums", v: [1.5, -2, 0.1] }] },
      { fn: "product", args: [{ t: "nums", v: [] }] },
    ],
  },
  {
    name: "predicate scans: find/findIndex/some/every hits, misses, and empties",
    src: `
export function firstOver(xs: readonly number[], lim: number): number {
  return xs.find((x) => x > lim) ?? -1;
}
export function overAt(xs: readonly number[], lim: number): number {
  return xs.findIndex((x) => x > lim);
}
export function anyOver(xs: readonly number[], lim: number): boolean {
  return xs.some((x) => x > lim);
}
export function allOver(xs: readonly number[], lim: number): boolean {
  return xs.every((x) => x > lim);
}
export function tenfoldHit(xs: readonly number[], lim: number): number {
  const hit = xs.find((x) => x > lim);
  if (hit === undefined) return -1;
  return hit * 10;
}
`,
    calls: [
      { fn: "firstOver", args: [{ t: "nums", v: [0.5, 2, -3, 7] }, f(1)] },
      { fn: "firstOver", args: [{ t: "nums", v: [0.5] }, f(1)] },
      { fn: "firstOver", args: [{ t: "nums", v: [] }, f(1)] },
      { fn: "firstOver", args: [{ t: "nums", v: ["nan", 4] }, f(1)] },
      { fn: "overAt", args: [{ t: "nums", v: [0.5, 2, -3, 7] }, f(1)] },
      { fn: "overAt", args: [{ t: "nums", v: [0.5] }, f(9)] },
      { fn: "anyOver", args: [{ t: "nums", v: [0.5, 2] }, f(1)] },
      { fn: "anyOver", args: [{ t: "nums", v: [] }, f(1)] },
      { fn: "allOver", args: [{ t: "nums", v: [2, 3] }, f(1)] },
      { fn: "allOver", args: [{ t: "nums", v: [2, 0.5] }, f(1)] },
      { fn: "allOver", args: [{ t: "nums", v: [] }, f(1)] },
      { fn: "tenfoldHit", args: [{ t: "nums", v: [0.5, 2] }, f(1)] },
      { fn: "tenfoldHit", args: [{ t: "nums", v: [0.5] }, f(1)] },
    ],
  },
  {
    name: "mixed-class optional equality widens null-safely; miss-first ternaries narrow",
    src: `
export interface Entry { readonly at: number; }
const ENTRIES: readonly Entry[] = [{ at: 0 }, { at: 2 }, { at: 7 }];
export function pickOrFlag(bytes: Uint8Array, key: number, frac: number): number {
  const hit = ENTRIES.find((e) => e.at === key);
  const sel = hit === undefined ? null : hit.at;
  const half = frac * 0.5;
  if (sel === half) return -1;
  if (sel !== null && sel < bytes.length) return bytes[sel];
  return -2;
}
export function offHalf(sel: number | null, frac: number): boolean {
  const half = frac * 0.5;
  return sel !== half;
}
export function missTernary(xs: readonly number[], lim: number): number {
  const hit = xs.find((x) => x > lim);
  return hit === undefined ? -1 : hit * 2;
}
export function selTernary(sel: number | null): number {
  return sel === null ? 0 : sel + 1;
}
`,
    calls: [
      // sel is an INTERNAL optional integer slot (table id through a find
      // miss-ternary, index-demanded); half is float: the 2 === 2.0 hit
      // must agree with node through the null-safe widening.
      { fn: "pickOrFlag", args: [{ t: "bytes", v: [5, 6, 7] }, f(2), f(4)] },
      { fn: "pickOrFlag", args: [{ t: "bytes", v: [5, 6, 7] }, f(0), f(5)] },
      { fn: "pickOrFlag", args: [{ t: "bytes", v: [5, 6, 7] }, f(9), f(4)] },
      { fn: "pickOrFlag", args: [{ t: "bytes", v: [] }, f(7), f(1)] },
      { fn: "offHalf", args: [{ t: "null" }, f(0)] },
      { fn: "offHalf", args: [{ t: "null" }, f("nan")] },
      { fn: "missTernary", args: [{ t: "nums", v: [0.5, 2] }, f(1)] },
      { fn: "missTernary", args: [{ t: "nums", v: [0.5] }, f(1)] },
      { fn: "selTernary", args: [{ t: "null" }] },
      { fn: "selTernary", args: [f(4.5)] },
    ],
  },
  {
    name: "reduce: float accumulation, seeds, and the empty-array initial",
    src: `
export function total(xs: readonly number[]): number {
  return xs.reduce((sum, x) => sum + x, 0);
}
export function totalFrom(xs: readonly number[], seed: number): number {
  return xs.reduce((sum, x) => sum + x, seed);
}
export function countBig(xs: readonly number[], lim: number): number {
  return xs.reduce((n, x) => (x > lim ? n + 1 : n), 0);
}
`,
    calls: [
      { fn: "total", args: [{ t: "nums", v: [0.1, 0.2] }] },
      { fn: "total", args: [{ t: "nums", v: [] }] },
      { fn: "total", args: [{ t: "nums", v: [1, 2, 3] }] },
      { fn: "totalFrom", args: [{ t: "nums", v: [1, 2] }, f(0.5)] },
      { fn: "totalFrom", args: [{ t: "nums", v: [] }, f("-0")] },
      { fn: "countBig", args: [{ t: "nums", v: [0.5, 2, -3, 7] }, f(1)] },
    ],
  },
  {
    name: "slice and concat: negative, clamped, and crossed indices copy like JS",
    src: `
export function sliced(xs: readonly number[], from: number, to: number): readonly number[] {
  return xs.slice(from, to);
}
export function tailFrom(xs: readonly number[], from: number): readonly number[] {
  return xs.slice(from);
}
export function wholeCopy(xs: readonly number[]): readonly number[] {
  return xs.slice();
}
export function stitched(a: readonly number[], b: readonly number[]): readonly number[] {
  return a.concat(b);
}
`,
    calls: [
      { fn: "sliced", args: [{ t: "nums", v: [1, 2, 3] }, i(-2), i(99)] },
      { fn: "sliced", args: [{ t: "nums", v: [1, 2, 3] }, i(1), i(-1)] },
      { fn: "sliced", args: [{ t: "nums", v: [1, 2, 3] }, i(2), i(1)] },
      { fn: "sliced", args: [{ t: "nums", v: [1, 2, 3] }, i(5), i(9)] },
      { fn: "sliced", args: [{ t: "nums", v: [1, 2, 3] }, i(0), i(99)] },
      { fn: "tailFrom", args: [{ t: "nums", v: [1, 2, 3] }, i(-99)] },
      { fn: "tailFrom", args: [{ t: "nums", v: [1, 2, 3] }, i(2)] },
      { fn: "wholeCopy", args: [{ t: "nums", v: [0.5, -0.5] }] },
      { fn: "wholeCopy", args: [{ t: "nums", v: [] }] },
      { fn: "stitched", args: [{ t: "nums", v: [1] }, { t: "nums", v: [2, 3] }] },
      { fn: "stitched", args: [{ t: "nums", v: [] }, { t: "nums", v: [] }] },
    ],
  },
  {
    name: "indexOf and includes: strict equality vs SameValueZero (NaN, signed zero)",
    src: `
export function whereIs(xs: readonly number[], v: number): number {
  return xs.indexOf(v);
}
export function has(xs: readonly number[], v: number): boolean {
  return xs.includes(v);
}
`,
    calls: [
      { fn: "whereIs", args: [{ t: "nums", v: [1, "nan", 3] }, f("nan")] },
      { fn: "has", args: [{ t: "nums", v: [1, "nan", 3] }, f("nan")] },
      { fn: "whereIs", args: [{ t: "nums", v: [0] }, f("-0")] },
      { fn: "has", args: [{ t: "nums", v: [0] }, f("-0")] },
      { fn: "whereIs", args: [{ t: "nums", v: ["-0"] }, f(0)] },
      { fn: "whereIs", args: [{ t: "nums", v: [5, 6, 7] }, f(6)] },
      { fn: "whereIs", args: [{ t: "nums", v: [5] }, f(9)] },
      { fn: "has", args: [{ t: "nums", v: [] }, f(1)] },
    ],
  },
  {
    name: "bytes join: separators fold, empties and single elements match JS ToString",
    src: `
export function dashed(bytes: Uint8Array): string {
  return bytes.join("-");
}
export function commas(bytes: Uint8Array): string {
  return bytes.join();
}
export function bare(bytes: Uint8Array): string {
  return bytes.join("");
}
`,
    calls: [
      { fn: "dashed", args: [{ t: "bytes", v: [1, 255, 0] }] },
      { fn: "dashed", args: [{ t: "bytes", v: [] }] },
      { fn: "dashed", args: [{ t: "bytes", v: [9] }] },
      { fn: "commas", args: [{ t: "bytes", v: [1, 2] }] },
      { fn: "bare", args: [{ t: "bytes", v: [1, 2, 3] }] },
    ],
  },
  {
    name: "record model dispatch through the scan and copy methods",
    src: `
export interface Task { readonly id: number; readonly done: boolean; }
export interface Model { readonly tasks: readonly Task[]; readonly nextId: number; }
export type Msg =
  | { readonly kind: "add" }
  | { readonly kind: "toggle"; readonly id: number };
export function initialModel(): Model {
  return { tasks: [], nextId: 1 };
}
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "add":
      return { ...model, tasks: [...model.tasks, { id: model.nextId, done: false }], nextId: model.nextId + 1 };
    case "toggle":
      return { ...model, tasks: model.tasks.map((t) => (t.id === msg.id ? { ...t, done: !t.done } : t)) };
  }
}
export function firstDoneId(model: Model): number {
  const hit = model.tasks.find((t) => t.done);
  if (hit === undefined) return -1;
  return hit.id;
}
export function doneAt(model: Model): number {
  return model.tasks.findIndex((t) => t.done);
}
export function anyDone(model: Model): boolean {
  return model.tasks.some((t) => t.done);
}
export function allDone(model: Model): boolean {
  return model.tasks.every((t) => t.done);
}
export function idTotal(model: Model): number {
  return model.tasks.reduce((sum, t) => sum + t.id, 0);
}
export function keptCount(model: Model): number {
  return model.tasks.slice(0, 2).length;
}
`,
    node: `
{
  let model = mod.initialModel();
  line("g0", mod.firstDoneId(model));
  line("g1", mod.anyDone(model));
  line("g2", mod.allDone(model));
  model = mod.update(model, { kind: "add" });
  model = mod.update(model, { kind: "add" });
  model = mod.update(model, { kind: "add" });
  model = mod.update(model, { kind: "toggle", id: 2 });
  line("g3", mod.firstDoneId(model));
  line("g4", mod.doneAt(model));
  line("g5", mod.anyDone(model));
  line("g6", mod.allDone(model));
  line("g7", mod.idTotal(model));
  line("g8", mod.keptCount(model));
}
`,
    zig: `
    {
        var model = m.initialModel();
        row("g0", m.firstDoneId(model));
        row("g1", m.anyDone(model));
        row("g2", m.allDone(model));
        model = m.update(model, .add);
        model = m.update(model, .add);
        model = m.update(model, .add);
        model = m.update(model, .{ .toggle = 2 });
        row("g3", m.firstDoneId(model));
        row("g4", m.doneAt(model));
        row("g5", m.anyDone(model));
        row("g6", m.allDone(model));
        row("g7", m.idTotal(model));
        row("g8", m.keptCount(model));
    }
`,
  },
  {
    name: "toSorted: sign comparators over floats, duplicates, signed zeros, and empties",
    src: `
export function asc(xs: readonly number[]): readonly number[] {
  return xs.toSorted((a, b) => a - b);
}
export function desc(xs: readonly number[]): readonly number[] {
  return xs.toSorted((a, b) => b - a);
}
export function keepOrder(xs: readonly number[]): readonly number[] {
  return xs.toSorted((a, b) => 0);
}
export function fractional(xs: readonly number[]): readonly number[] {
  return xs.toSorted((a, b) => (a - b) * 0.5);
}
`,
    calls: [
      { fn: "asc", args: [{ t: "nums", v: [3, 1, 2, 1, 3, 0.5] }] },
      { fn: "asc", args: [{ t: "nums", v: [0, "-0", 0] }] },
      { fn: "asc", args: [{ t: "nums", v: [] }] },
      { fn: "asc", args: [{ t: "nums", v: [5] }] },
      { fn: "asc", args: [{ t: "nums", v: [2, -1, "-0", 7, -1] }] },
      { fn: "desc", args: [{ t: "nums", v: [3, 1, 2, 1, 3] }] },
      { fn: "desc", args: [{ t: "nums", v: [0.25, 0.5, 0.125] }] },
      { fn: "keepOrder", args: [{ t: "nums", v: [3, 1, 2] }] },
      { fn: "fractional", args: [{ t: "nums", v: [3, 1, 2, 1] }] },
    ],
  },
  {
    name: "toSorted stability: equal-key records keep declaration order, byte for byte",
    src: `
export interface Task { readonly id: number; readonly streak: number; }
export interface Model { readonly tasks: readonly Task[]; readonly nextId: number; }
export type Msg = { readonly kind: "seed"; readonly streak: number } | { readonly kind: "noop" };
export function initialModel(): Model {
  return { tasks: [], nextId: 1 };
}
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "seed":
      return { tasks: [...model.tasks, { id: model.nextId, streak: msg.streak }], nextId: model.nextId + 1 };
    case "noop": return model;
  }
}
export function sortedIds(model: Model): readonly number[] {
  const out: number[] = [];
  for (const t of model.tasks.toSorted((a, b) => a.streak - b.streak)) {
    out.push(t.id);
  }
  return out;
}
export function groupedIds(model: Model): readonly number[] {
  const out: number[] = [];
  for (const t of model.tasks.toSorted((a, b) => {
    if (a.streak === b.streak) return 0;
    return b.streak - a.streak;
  })) {
    out.push(t.id);
  }
  return out;
}
`,
    node: `
{
  let model = mod.initialModel();
  for (const s of [2, 1, 2, 1, 2, 0]) model = mod.update(model, { kind: "seed", streak: s });
  line("t0", mod.sortedIds(model));
  line("t1", mod.groupedIds(model));
  line("t2", mod.sortedIds(mod.initialModel()));
}
`,
    zig: `
    {
        var model = m.initialModel();
        for ([_]f64{ 2, 1, 2, 1, 2, 0 }) |s| model = m.update(model, .{ .seed = s });
        row("t0", m.sortedIds(model));
        row("t1", m.groupedIds(model));
        row("t2", m.sortedIds(m.initialModel()));
    }
`,
  },
  {
    name: "push-builder: growth past the seed capacity, conditional pushes, prefix reads",
    src: `
export function keptDoubled(xs: readonly number[], lim: number): readonly number[] {
  const out: number[] = [];
  for (const x of xs) {
    if (x > lim) {
      out.push(x * 2);
    } else if (x === lim) {
      out.push(x);
    }
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
export function firstOrMinusOne(xs: readonly number[], lim: number): number {
  const out: number[] = [];
  for (const x of xs) {
    if (x > lim) out.push(x);
  }
  if (out.length === 0) return -1;
  return out[0];
}
`,
    calls: [
      { fn: "keptDoubled", args: [{ t: "nums", v: [1, 5, 3, 5, 9, 0.5] }, f(3)] },
      { fn: "keptDoubled", args: [{ t: "nums", v: [] }, f(3)] },
      { fn: "keptDoubled", args: [{ t: "nums", v: [1, 2] }, f(9)] },
      { fn: "countdown", args: [i(10)] },
      { fn: "countdown", args: [i(0)] },
      { fn: "firstOrMinusOne", args: [{ t: "nums", v: [1, 7, 9] }, f(5)] },
      { fn: "firstOrMinusOne", args: [{ t: "nums", v: [1] }, f(5)] },
    ],
  },
  {
    name: "local mutation: a push/pop parser-stack helper is byte-identical to node",
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
export function balance(bytes: Uint8Array): number {
  const stack: number[] = [];
  for (const b of bytes) {
    if (b === 40 || b === 91) stack.push(b);
    if (b === 41 || b === 93) {
      const open = stack.pop();
      if (open === undefined) return -1;
      if (b === 41 && open !== 40) return -2;
      if (b === 93 && open !== 91) return -2;
    }
  }
  return stack.length;
}
`,
    calls: [
      // "(()(()))" nests to 3; "(]" mismatches; ")" underflows (pop on empty).
      { fn: "maxDepth", args: [{ t: "bytes", v: [40, 40, 41, 40, 40, 41, 41, 41] }] },
      { fn: "maxDepth", args: [{ t: "bytes", v: [] }] },
      { fn: "maxDepth", args: [{ t: "bytes", v: [41, 41, 40] }] },
      { fn: "balance", args: [{ t: "bytes", v: [40, 91, 93, 41] }] },
      { fn: "balance", args: [{ t: "bytes", v: [40, 93] }] },
      { fn: "balance", args: [{ t: "bytes", v: [41] }] },
      { fn: "balance", args: [{ t: "bytes", v: [40, 40] }] },
    ],
  },
  {
    name: "local mutation: splice corners (negative start, over-delete, insert-larger, past-end)",
    src: `
export function cutAt(xs: readonly number[], start: number, count: number): readonly number[] {
  const work = xs.slice();
  const removed = work.splice(start, count);
  return removed.concat([-99], work);
}
export function cutRest(xs: readonly number[], start: number): readonly number[] {
  const work = xs.slice();
  const removed = work.splice(start);
  return removed.concat([-99], work);
}
export function inject(xs: readonly number[], start: number, count: number): readonly number[] {
  const work = xs.slice();
  const removed = work.splice(start, count, 91, 92, 93);
  return removed.concat([-99], work);
}
`,
    calls: [
      { fn: "cutAt", args: [{ t: "nums", v: [1, 2, 3, 4, 5] }, i(-2), i(1)] },
      { fn: "cutAt", args: [{ t: "nums", v: [1, 2, 3] }, i(1), i(99)] },
      { fn: "cutAt", args: [{ t: "nums", v: [1, 2, 3] }, i(1), i(-5)] },
      { fn: "cutAt", args: [{ t: "nums", v: [1, 2, 3] }, i(99), i(1)] },
      { fn: "cutAt", args: [{ t: "nums", v: [] }, i(0), i(1)] },
      { fn: "cutRest", args: [{ t: "nums", v: [1, 2, 3] }, i(1)] },
      { fn: "cutRest", args: [{ t: "nums", v: [1, 2, 3] }, i(-1)] },
      { fn: "inject", args: [{ t: "nums", v: [1, 2, 3] }, i(1), i(1)] },
      { fn: "inject", args: [{ t: "nums", v: [1, 2, 3] }, i(0), i(0)] },
      { fn: "inject", args: [{ t: "nums", v: [1, 2] }, i(99), i(1)] },
      { fn: "inject", args: [{ t: "nums", v: [] }, i(-3), i(2)] },
    ],
  },
  {
    name: "local mutation: shift/unshift ordering and their growth past the seed capacity",
    src: `
export function rotate(xs: readonly number[]): readonly number[] {
  const q = xs.slice();
  const head = q.shift();
  if (head === undefined) return q;
  q.push(head);
  q.unshift(-1, -2);
  return q;
}
export function frontLoad(n: number): readonly number[] {
  const q: number[] = [];
  for (let i = 0; i < n; i++) q.unshift(i);
  return q;
}
`,
    calls: [
      { fn: "rotate", args: [{ t: "nums", v: [1, 2, 3] }] },
      { fn: "rotate", args: [{ t: "nums", v: [7] }] },
      { fn: "rotate", args: [{ t: "nums", v: [] }] },
      { fn: "frontLoad", args: [i(10)] },
      { fn: "frontLoad", args: [i(0)] },
    ],
  },
  {
    name: "local mutation: in-place sort is stable and equals toSorted, byte for byte",
    src: `
export interface Rec { readonly key: number; readonly seq: number; }
export function stableIds(keys: readonly number[]): readonly number[] {
  const recs: Rec[] = [];
  for (let i = 0; i < keys.length; i++) recs.push({ key: keys[i], seq: i });
  recs.sort((a, b) => a.key - b.key);
  return recs.map((r) => r.seq);
}
export function sortedBoth(xs: readonly number[]): readonly number[] {
  const inPlace = xs.slice();
  inPlace.sort((a, b) => a - b);
  const copied = xs.toSorted((a, b) => a - b);
  return inPlace.concat([-99], copied);
}
`,
    calls: [
      { fn: "stableIds", args: [{ t: "nums", v: [2, 1, 2, 1, 1] }] },
      { fn: "stableIds", args: [{ t: "nums", v: [] }] },
      { fn: "sortedBoth", args: [{ t: "nums", v: [3, 1, 2, 1] }] },
      { fn: "sortedBoth", args: [{ t: "nums", v: [1, "-0", 0, 0.5] }] },
      { fn: "sortedBoth", args: [{ t: "nums", v: [] }] },
    ],
  },
  {
    name: "local mutation: pop on empty flows through the optional machinery",
    src: `
export function drainSum(xs: readonly number[], extraPops: number): number {
  const work = xs.slice();
  let total = 0;
  while (work.length > 0) {
    total += work.pop() ?? 0;
  }
  for (let i = 0; i < extraPops; i++) {
    const gone = work.pop();
    if (gone !== undefined) return -1;
  }
  return total + work.length;
}
export function lastOr(xs: readonly number[], fallback: number): number {
  const work = xs.slice();
  return work.pop() ?? fallback;
}
`,
    calls: [
      { fn: "drainSum", args: [{ t: "nums", v: [1, 2, 3.5] }, i(2)] },
      { fn: "drainSum", args: [{ t: "nums", v: [] }, i(3)] },
      { fn: "lastOr", args: [{ t: "nums", v: [1, 9] }, f(-1)] },
      { fn: "lastOr", args: [{ t: "nums", v: [] }, f(-1)] },
    ],
  },
  {
    name: "local mutation: interleaved mutation and reads (length, elements, fill, reverse, writes)",
    src: `
export function churn(xs: readonly number[], lim: number): readonly number[] {
  const work = xs.slice();
  work.push(lim);
  if (work.length > 3) work.splice(0, work.length - 3);
  work.reverse();
  work.fill(0, 1, -1);
  if (work.length > 0) work[0] = work[work.length - 1] + work.length;
  work.unshift(work.length);
  const dropped = work.pop();
  if (dropped === undefined) return work;
  work.push(dropped * 2);
  return work;
}
export function pushSelfRef(xs: readonly number[]): readonly number[] {
  const out: number[] = [];
  out.push(7);
  // JS evaluates both arguments before the first append: both read len 1.
  out.push(out.length, out.length);
  return out;
}
export function writeDuringForOf(xs: readonly number[]): readonly number[] {
  const work = xs.slice();
  const seen: number[] = [];
  for (const x of work) {
    seen.push(x);
    if (work.length > 2) work[2] = 99;
  }
  return seen.concat([-99], work);
}
`,
    calls: [
      { fn: "churn", args: [{ t: "nums", v: [1, 2, 3, 4, 5] }, f(6)] },
      { fn: "churn", args: [{ t: "nums", v: [] }, f(1)] },
      { fn: "churn", args: [{ t: "nums", v: [2] }, f(0.5)] },
      { fn: "pushSelfRef", args: [{ t: "nums", v: [] }] },
      { fn: "writeDuringForOf", args: [{ t: "nums", v: [1, 2, 3, 4] }] },
      { fn: "writeDuringForOf", args: [{ t: "nums", v: [1] }] },
    ],
  },
  {
    name: "prepend and multi-spread literals copy every segment in order",
    src: `
export function pre(xs: readonly number[], x: number): readonly number[] {
  return [x, ...xs];
}
export function stitch(a: readonly number[], b: readonly number[], x: number): readonly number[] {
  return [...a, x, ...b];
}
export function wrap(xs: readonly number[], lo: number, hi: number): readonly number[] {
  return [lo, ...xs, hi];
}
`,
    calls: [
      { fn: "pre", args: [{ t: "nums", v: [1, 2] }, f(9)] },
      { fn: "pre", args: [{ t: "nums", v: [] }, f(9)] },
      { fn: "stitch", args: [{ t: "nums", v: [1, 2] }, { t: "nums", v: [3] }, f(9)] },
      { fn: "stitch", args: [{ t: "nums", v: [] }, { t: "nums", v: [] }, f(9)] },
      { fn: "wrap", args: [{ t: "nums", v: [5, 6] }, f(0), f(7)] },
      { fn: "wrap", args: [{ t: "nums", v: [] }, f(0), f(7)] },
    ],
  },
  {
    name: "bytes slice clamps out-of-range and negative bounds exactly like JS",
    src: `
export function window(bytes: Uint8Array, from: number, to: number): Uint8Array {
  return bytes.slice(from, to);
}
export function tail(bytes: Uint8Array, from: number): Uint8Array {
  return bytes.slice(from);
}
`,
    calls: [
      { fn: "window", args: [{ t: "bytes", v: [1, 2, 3] }, i(1), i(99)] },
      { fn: "window", args: [{ t: "bytes", v: [1, 2, 3] }, i(-2), i(99)] },
      { fn: "window", args: [{ t: "bytes", v: [1, 2, 3] }, i(2), i(1)] },
      { fn: "window", args: [{ t: "bytes", v: [1, 2, 3] }, i(-99), i(99)] },
      { fn: "window", args: [{ t: "bytes", v: [1, 2, 3] }, i(5), i(9)] },
      { fn: "tail", args: [{ t: "bytes", v: [1, 2, 3] }, i(5)] },
      { fn: "tail", args: [{ t: "bytes", v: [1, 2, 3] }, i(-1)] },
      { fn: "tail", args: [{ t: "bytes", v: [] }, i(-1)] },
    ],
  },
  {
    name: "comptime division folds to the JS f64 value, signed zero and NaN included",
    src: `
export function nanv(): number { return 0 / 0; }
export function posInf(): number { return 1 / 0; }
export function negInf(): number { return -1 / 0; }
export function negZero(): number { return 0 / -1; }
export function half(): number { return 5 / 2; }
`,
    calls: [
      { fn: "nanv", args: [] },
      { fn: "posInf", args: [] },
      { fn: "negInf", args: [] },
      { fn: "negZero", args: [] },
      { fn: "half", args: [] },
    ],
  },
  {
    name: "block-body callbacks behave like their JS bodies, early returns included",
    src: `
export function bigMargins(xs: readonly number[], lim: number): readonly number[] {
  return xs.filter((x) => {
    if (x < 0) return false;
    const margin = x - lim;
    return margin > 0.5;
  });
}
export function firstSpecial(xs: readonly number[], want: number): number {
  const hit = xs.find((x) => {
    if (x === want) return true;
    return x > want * 2;
  });
  return hit ?? -1;
}
export function skewedTotal(xs: readonly number[], lim: number): number {
  return xs.reduce((sum, x) => {
    if (x > lim) return sum + x * 0.5;
    return sum + x;
  }, 0);
}
`,
    calls: [
      { fn: "bigMargins", args: [{ t: "nums", v: [-1, 2, 2.4, 3, 0.5] }, f(1.5)] },
      { fn: "bigMargins", args: [{ t: "nums", v: [] }, f(1.5)] },
      { fn: "firstSpecial", args: [{ t: "nums", v: [1, 9, 4] }, f(4)] },
      { fn: "firstSpecial", args: [{ t: "nums", v: [1, 2] }, f(4)] },
      { fn: "skewedTotal", args: [{ t: "nums", v: [0.1, 0.2, 10] }, f(1)] },
      { fn: "skewedTotal", args: [{ t: "nums", v: [] }, f(1)] },
    ],
  },
  {
    name: "Math floor/ceil/trunc corners: signed zeros, halves, NaN, infinities, big values",
    src: `
export function flo(x: number): number { return Math.floor(x); }
export function cei(x: number): number { return Math.ceil(x); }
export function tru(x: number): number { return Math.trunc(x); }
export function floInt(bytes: Uint8Array): number { return Math.floor(bytes.length); }
export function truInt(bytes: Uint8Array): number { return Math.trunc(bytes.length - 7); }
`,
    calls: [
      { fn: "flo", args: [f("-0")] },
      { fn: "flo", args: [f(0.5)] },
      { fn: "flo", args: [f(-0.5)] },
      { fn: "flo", args: [f("nan")] },
      { fn: "flo", args: [f("inf")] },
      { fn: "flo", args: [f("-inf")] },
      { fn: "flo", args: [f(4503599627370495.5)] },
      { fn: "cei", args: [f("-0")] },
      { fn: "cei", args: [f(-0.5)] },
      { fn: "cei", args: [f(0.5)] },
      { fn: "cei", args: [f("nan")] },
      { fn: "cei", args: [f(-4503599627370495.5)] },
      { fn: "tru", args: [f(-0.5)] },
      { fn: "tru", args: [f("-0")] },
      { fn: "tru", args: [f(2.9)] },
      { fn: "tru", args: [f(-2.9)] },
      { fn: "tru", args: [f("nan")] },
      { fn: "tru", args: [f("inf")] },
      { fn: "floInt", args: [{ t: "bytes", v: [1, 2, 3] }] },
      { fn: "truInt", args: [{ t: "bytes", v: [1, 2, 3] }] },
    ],
  },
  {
    name: "Math abs/sign/sqrt corners: -0 keeps or clears its sign exactly like JS",
    src: `
export function ab(x: number): number { return Math.abs(x); }
export function sg(x: number): number { return Math.sign(x); }
export function sq(x: number): number { return Math.sqrt(x); }
export function abInt(bytes: Uint8Array): number { return Math.abs(bytes.length - 10); }
export function sgInt(bytes: Uint8Array): number { return Math.sign(bytes.length - 2); }
`,
    calls: [
      { fn: "ab", args: [f("-0")] },
      { fn: "ab", args: [f(-5.5)] },
      { fn: "ab", args: [f("nan")] },
      { fn: "ab", args: [f("-inf")] },
      { fn: "sg", args: [f("-0")] },
      { fn: "sg", args: [f(0)] },
      { fn: "sg", args: [f("nan")] },
      { fn: "sg", args: [f(-3.5)] },
      { fn: "sg", args: [f("inf")] },
      { fn: "sg", args: [f("-inf")] },
      { fn: "sq", args: [f("-0")] },
      { fn: "sq", args: [f(-1)] },
      { fn: "sq", args: [f(2)] },
      { fn: "sq", args: [f("nan")] },
      { fn: "sq", args: [f("inf")] },
      { fn: "sq", args: [f(0)] },
      { fn: "abInt", args: [{ t: "bytes", v: [1, 2, 3] }] },
      { fn: "sgInt", args: [{ t: "bytes", v: [1] }] },
      { fn: "sgInt", args: [{ t: "bytes", v: [1, 2] }] },
      { fn: "sgInt", args: [{ t: "bytes", v: [1, 2, 3] }] },
    ],
  },
  {
    name: "Math min/max arities and comptime Math/% folds match node exactly",
    src: `
export const HALF = Math.floor(5 / 2);
export const ROOT = Math.sqrt(2);
export function noArgMin(): number { return Math.min(); }
export function noArgMax(): number { return Math.max(); }
export function oneArg(x: number): number { return Math.max(x); }
export function three(a: number, b: number, c: number): number { return Math.min(a, b, c); }
export function halfConst(): number { return HALF; }
export function rootConst(): number { return ROOT; }
export function floorDown(): number { return Math.floor(-5 / 2); }
export function ceilNegHalf(): number { return Math.ceil(-0.5); }
export function signNegZero(): number { return Math.sign(-0); }
export function remNan(): number { return 5 % 0; }
export function remNegZero(): number { return -5 % 5; }
export function remFrac(): number { return 5.5 % 2; }
`,
    calls: [
      { fn: "noArgMin", args: [] },
      { fn: "noArgMax", args: [] },
      { fn: "oneArg", args: [f("nan")] },
      { fn: "oneArg", args: [f("-0")] },
      { fn: "three", args: [f(2), f("nan"), f(1)] },
      { fn: "three", args: [f(2), f(0.5), f(1)] },
      { fn: "three", args: [f(0), f("-0"), f(0)] },
      { fn: "halfConst", args: [] },
      { fn: "rootConst", args: [] },
      { fn: "floorDown", args: [] },
      { fn: "ceilNegHalf", args: [] },
      { fn: "signNegZero", args: [] },
      { fn: "remNan", args: [] },
      { fn: "remNegZero", args: [] },
      { fn: "remFrac", args: [] },
    ],
  },
  {
    name: "Number classifiers agree with node over every float class",
    src: `
export function isInt(x: number): boolean { return Number.isInteger(x); }
export function isFin(x: number): boolean { return Number.isFinite(x); }
export function isNan(x: number): boolean { return Number.isNaN(x); }
export function intAlways(bytes: Uint8Array): boolean { return Number.isInteger(bytes.length); }
export function intNever(bytes: Uint8Array): boolean { return Number.isNaN(bytes.length); }
export function nanLit(): number { return NaN; }
export function negInfLit(): number { return -Infinity; }
export function isMax(x: number): boolean { return x === Infinity; }
`,
    calls: [
      { fn: "isInt", args: [f("-0")] },
      { fn: "isInt", args: [f(5)] },
      { fn: "isInt", args: [f(5.5)] },
      { fn: "isInt", args: [f("nan")] },
      { fn: "isInt", args: [f("inf")] },
      { fn: "isInt", args: [f(9007199254740992)] },
      { fn: "isFin", args: [f("nan")] },
      { fn: "isFin", args: [f("inf")] },
      { fn: "isFin", args: [f("-0")] },
      { fn: "isNan", args: [f("nan")] },
      { fn: "isNan", args: [f(1)] },
      { fn: "isNan", args: [f("inf")] },
      { fn: "intAlways", args: [{ t: "bytes", v: [7] }] },
      { fn: "intNever", args: [{ t: "bytes", v: [7] }] },
      { fn: "nanLit", args: [] },
      { fn: "negInfLit", args: [] },
      { fn: "isMax", args: [f("inf")] },
      { fn: "isMax", args: [f(1)] },
    ],
  },
  {
    name: "subarray resolves negative, crossed, and out-of-range bounds like JS (views, chained)",
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
    calls: [
      { fn: "window", args: [{ t: "bytes", v: [1, 2, 3] }, i(1), i(99)] },
      { fn: "window", args: [{ t: "bytes", v: [1, 2, 3] }, i(-2), i(99)] },
      { fn: "window", args: [{ t: "bytes", v: [1, 2, 3] }, i(2), i(1)] },
      { fn: "window", args: [{ t: "bytes", v: [1, 2, 3] }, i(-99), i(99)] },
      { fn: "window", args: [{ t: "bytes", v: [1, 2, 3] }, i(5), i(9)] },
      { fn: "window", args: [{ t: "bytes", v: [1, 2, 3] }, i(1), i(-1)] },
      { fn: "tail", args: [{ t: "bytes", v: [1, 2, 3] }, i(5)] },
      { fn: "tail", args: [{ t: "bytes", v: [1, 2, 3] }, i(-1)] },
      { fn: "tail", args: [{ t: "bytes", v: [] }, i(-1)] },
      { fn: "whole", args: [{ t: "bytes", v: [9, 8] }] },
      { fn: "chained", args: [{ t: "bytes", v: [1, 2, 3, 4] }, i(1)] },
      { fn: "chained", args: [{ t: "bytes", v: [1] }, i(0)] },
    ],
  },
  {
    name: "module const tables read identically: arrays, records, enums, derived scans",
    src: `
import { asciiBytes } from "@native-sdk/core";
export type Filter = "all" | "active" | "done";
export const WEEKDAYS = [3, 5, 2, 8];
export const FACTORS: readonly number[] = [0.5, 1, 2];
export const ORDER: readonly Filter[] = ["done", "active", "all"];
export const DEFAULT_FILTER: Filter = "active";
export interface Limits { readonly lo: number; readonly hi: number; }
export const LIMITS: Limits = { lo: 1, hi: 9 };
export const BAND: Limits = { lo: 0.75, hi: 9.5 };
export interface Task { readonly id: number; readonly title: Uint8Array; readonly done: boolean; }
export const SEEDS: readonly Task[] = [
  { id: 1, title: asciiBytes("Ship"), done: false },
  { id: 2, title: asciiBytes("Test"), done: true },
];
export function weekdayAt(i: number): number { return WEEKDAYS[i]; }
export function weekdayCount(): number { return WEEKDAYS.length; }
export function weekdayTotal(): number {
  let t = 0;
  for (const w of WEEKDAYS) t += w;
  return t;
}
export function bigWeekdays(lim: number): readonly number[] { return WEEKDAYS.filter((w) => w > lim); }
export function factorAt(i: number): number { return FACTORS[i]; }
export function orderAt(i: number): Filter { return ORDER[i]; }
export function fallbackFilter(): Filter { return DEFAULT_FILTER; }
export function inRange(n: Uint8Array): boolean { return n.length >= LIMITS.lo && n.length <= LIMITS.hi; }
export function inBand(x: number): boolean { return x >= BAND.lo && x <= BAND.hi; }
export function seedTitle(i: number): Uint8Array { return SEEDS[i].title; }
export function doneSeedIds(): readonly number[] {
  return SEEDS.filter((s) => s.done).map((s) => s.id);
}
`,
    calls: [
      { fn: "weekdayAt", args: [i(0)] },
      { fn: "weekdayAt", args: [i(3)] },
      { fn: "weekdayCount", args: [] },
      { fn: "weekdayTotal", args: [] },
      { fn: "bigWeekdays", args: [f(3)] },
      { fn: "bigWeekdays", args: [f(99)] },
      { fn: "factorAt", args: [i(0)] },
      { fn: "orderAt", args: [i(0)] },
      { fn: "orderAt", args: [i(2)] },
      { fn: "fallbackFilter", args: [] },
      { fn: "inRange", args: [{ t: "bytes", v: [1, 2, 3] }] },
      { fn: "inRange", args: [{ t: "bytes", v: [] }] },
      { fn: "inBand", args: [f(5)] },
      { fn: "inBand", args: [f(0.5)] },
      { fn: "inBand", args: [f(0.75)] },
      { fn: "seedTitle", args: [i(0)] },
      { fn: "seedTitle", args: [i(1)] },
      { fn: "doneSeedIds", args: [] },
    ],
  },
  {
    name: "type-changing map: scalars out of records, bytes out, optional results, block bodies",
    src: `
export interface Task { readonly id: number; readonly title: Uint8Array; readonly streak: number; }
export interface Model { readonly tasks: readonly Task[]; }
export type Msg = { readonly kind: "seed"; readonly streak: number } | { readonly kind: "noop" };
export function initialModel(): Model { return { tasks: [] }; }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "seed": {
      const id = model.tasks.length + 1;
      const task: Task = { id: id, title: new Uint8Array(0), streak: msg.streak };
      return { tasks: [...model.tasks, task] };
    }
    case "noop": return model;
  }
}
export function ids(model: Model): readonly number[] { return model.tasks.map((t) => t.id); }
export function doubled(model: Model): readonly number[] { return model.tasks.map((t) => t.streak * 2); }
export function capped(model: Model, lim: number): readonly number[] {
  return model.tasks.map((t) => {
    if (t.streak > lim) return lim;
    return t.streak;
  });
}
export function mappedCount(model: Model): number { return model.tasks.map((t) => t.id).length; }
export function orNull(xs: readonly number[]): readonly (number | null)[] {
  return xs.map((x) => (x > 0 ? x : null));
}
`,
    node: `
{
  let model = mod.initialModel();
  for (const s of [2, 0.5, 7]) model = mod.update(model, { kind: "seed", streak: s });
  line("m0", mod.ids(model));
  line("m1", mod.doubled(model));
  line("m2", mod.capped(model, 2));
  line("m3", mod.mappedCount(model));
  line("m4", mod.orNull([1, -1, 0, 2.5]));
  line("m5", mod.orNull([]));
}
`,
    zig: `
    {
        var model = m.initialModel();
        for ([_]f64{ 2, 0.5, 7 }) |s| model = m.update(model, .{ .seed = s });
        row("m0", m.ids(model));
        row("m1", m.doubled(model));
        row("m2", m.capped(model, 2));
        row("m3", m.mappedCount(model));
        row("m4", m.orNull(&[_]f64{ 1, -1, 0, 2.5 }));
        row("m5", m.orNull(&[_]f64{}));
    }
`,
  },
  {
    name: "callback index parameters count exactly like JS across map/filter/scans",
    src: `
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
export function frontLoaded(xs: readonly number[]): boolean {
  return xs.every((x, i) => x >= i);
}
`,
    calls: [
      { fn: "weighted", args: [{ t: "nums", v: [5, 6, 7] }] },
      { fn: "weighted", args: [{ t: "nums", v: ["-0", 2] }] },
      { fn: "weighted", args: [{ t: "nums", v: [] }] },
      { fn: "evenSlots", args: [{ t: "nums", v: [5, 6, 7, 8] }] },
      { fn: "evenSlots", args: [{ t: "nums", v: [] }] },
      { fn: "lateBig", args: [{ t: "nums", v: [9, -1, 4] }, i(0)] },
      { fn: "lateBig", args: [{ t: "nums", v: [9, -1] }, i(0)] },
      { fn: "lateAt", args: [{ t: "nums", v: [9, -1, 4] }, i(1)] },
      { fn: "lateAt", args: [{ t: "nums", v: [9] }, i(1)] },
      { fn: "anyLate", args: [{ t: "nums", v: [1, 2] }, i(0)] },
      { fn: "anyLate", args: [{ t: "nums", v: [1] }, i(5)] },
      { fn: "frontLoaded", args: [{ t: "nums", v: [0, 1, 2] }] },
      { fn: "frontLoaded", args: [{ t: "nums", v: [0, 0.5] }] },
      { fn: "frontLoaded", args: [{ t: "nums", v: [] }] },
    ],
  },
  {
    name: "array-method calls in if/else-if and ternary conditions behave identically",
    src: `
export function grade(xs: readonly number[], flag: boolean): number {
  if (flag) return -1;
  else if (xs.some((x) => x > 3)) return 1;
  else if (xs.every((x) => x < 0)) return 2;
  return 0;
}
export function countIf(xs: readonly number[], lim: number): number {
  if (xs.filter((x) => x > lim).length > 1) return 2;
  return xs.findIndex((x) => x > lim) >= 0 ? 1 : 0;
}
`,
    calls: [
      { fn: "grade", args: [{ t: "nums", v: [1, 5] }, { t: "b", v: true }] },
      { fn: "grade", args: [{ t: "nums", v: [1, 5] }, { t: "b", v: false }] },
      { fn: "grade", args: [{ t: "nums", v: [-1, -2] }, { t: "b", v: false }] },
      { fn: "grade", args: [{ t: "nums", v: [1, 2] }, { t: "b", v: false }] },
      { fn: "grade", args: [{ t: "nums", v: [] }, { t: "b", v: false }] },
      { fn: "countIf", args: [{ t: "nums", v: [5, 6, 1] }, f(4)] },
      { fn: "countIf", args: [{ t: "nums", v: [5, 1] }, f(4)] },
      { fn: "countIf", args: [{ t: "nums", v: [1] }, f(4)] },
    ],
  },
  {
    name: "switch on a literal-union value matches JS clause selection exactly",
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
`,
    calls: [
      { fn: "label", args: [{ t: "tag", v: "all" }] },
      { fn: "label", args: [{ t: "tag", v: "active" }] },
      { fn: "label", args: [{ t: "tag", v: "done" }] },
      { fn: "sharedBody", args: [{ t: "tag", v: "active" }] },
      { fn: "sharedBody", args: [{ t: "tag", v: "done" }] },
      { fn: "sharedBody", args: [{ t: "tag", v: "all" }] },
      { fn: "partial", args: [{ t: "tag", v: "done" }] },
      { fn: "partial", args: [{ t: "tag", v: "active" }] },
      { fn: "partial", args: [{ t: "tag", v: "all" }] },
      { fn: "flip", args: [i(0)] },
      { fn: "flip", args: [i(1)] },
    ],
  },
  {
    name: "model union arm churn: alternating arms with deep payloads across committed dispatches",
    // A tiny heap makes the two-space flip fire DURING arm churn: every arm
    // switch kills the old payload, and compaction must copy only through
    // the live arm — a stale-pointer chase would trap or diverge here.
    options: { frameCap: 32768, heapCap: 4096 },
    src: `
import { asciiBytes } from "@native-sdk/core";
export interface Note { readonly id: number; readonly title: Uint8Array; }
export type View =
  | { readonly kind: "list"; readonly scroll: number }
  | { readonly kind: "detail"; readonly note: Note; readonly tags: readonly number[] }
  | { readonly kind: "compose"; readonly draft: Uint8Array };
export interface Model { readonly view: View; readonly visits: number; }
export type Msg =
  | { readonly kind: "open"; readonly id: number }
  | { readonly kind: "compose_new" }
  | { readonly kind: "back" };
export function initialModel(): Model {
  return { view: { kind: "list", scroll: 0 }, visits: 0 };
}
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "open":
      return {
        view: { kind: "detail", note: { id: msg.id, title: asciiBytes(\`note \${msg.id & 255}\`) }, tags: [msg.id, msg.id * 2] },
        visits: model.visits + 1,
      };
    case "compose_new":
      return { view: { kind: "compose", draft: asciiBytes("draft") }, visits: model.visits + 1 };
    case "back":
      return { view: { kind: "list", scroll: model.visits }, visits: model.visits + 1 };
  }
}
export function summary(model: Model): number {
  switch (model.view.kind) {
    case "list": return model.view.scroll;
    case "detail": return model.view.note.id + model.view.tags.length;
    case "compose": return model.view.draft.length;
  }
}
export function title(model: Model): Uint8Array {
  if (model.view.kind === "detail") return model.view.note.title;
  return new Uint8Array(0);
}
export function tagSum(model: Model): number {
  if (model.view.kind === "detail") return model.view.tags.reduce((s, t) => s + t, 0);
  return -1;
}
`,
    node: `
{
  let model = mod.initialModel();
  line("a0", mod.summary(model));
  const script = [
    { kind: "open", id: 7 }, { kind: "compose_new" }, { kind: "back" },
    { kind: "open", id: 40 }, { kind: "open", id: 3 }, { kind: "back" },
    { kind: "compose_new" }, { kind: "open", id: 12 },
  ];
  for (const msg of script) {
    model = mod.update(model, msg);
    line("st", mod.summary(model));
    line("ti", mod.title(model));
    line("tg", mod.tagSum(model));
  }
  line("a1", model.visits);
  for (let r = 0; r < 90; r++) {
    const msg = r % 3 === 0 ? { kind: "open", id: r } : r % 3 === 1 ? { kind: "compose_new" } : { kind: "back" };
    model = mod.update(model, msg);
    if (r % 15 === 0) {
      line("cs", mod.summary(model));
      line("ct", mod.title(model));
    }
  }
  line("cmp", true);
  line("a2", mod.summary(model));
}
`,
    zig: `
    {
        m.rt.resetAll();
        var model = m.commitModelRoot(m.initialModel());
        m.rt.frameReset();
        row("a0", m.summary(model));
        const script = [_]m.Msg{
            .{ .open = 7 }, .compose_new, .back,
            .{ .open = 40 }, .{ .open = 3 }, .back,
            .compose_new, .{ .open = 12 },
        };
        for (script) |msg| {
            model = m.commitModelRoot(m.update(model, msg));
            m.rt.frameReset();
            row("st", m.summary(model));
            row("ti", m.title(model));
            row("tg", m.tagSum(model));
        }
        row("a1", model.visits);
        var r: i64 = 0;
        while (r < 90) : (r += 1) {
            const msg: m.Msg = if (@rem(r, 3) == 0) .{ .open = r } else if (@rem(r, 3) == 1) .compose_new else .back;
            model = m.commitModelRoot(m.update(model, msg));
            m.rt.frameReset();
            if (@rem(r, 15) == 0) {
                row("cs", m.summary(model));
                row("ct", m.title(model));
            }
        }
        row("cmp", m.rt.stat_compactions > 0);
        row("a2", m.summary(model));
    }
`,
  },
  {
    name: "primitive arrays in the model: grow/shrink/replace churn and structural sharing",
    src: `
export interface Model { readonly xs: readonly number[]; readonly flags: readonly boolean[]; readonly ticks: number; }
export type Msg =
  | { readonly kind: "push"; readonly v: number }
  | { readonly kind: "double" }
  | { readonly kind: "drop_first" }
  | { readonly kind: "mark"; readonly on: boolean }
  | { readonly kind: "replace" }
  | { readonly kind: "noop" };
export function initialModel(): Model { return { xs: [], flags: [], ticks: 0 }; }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "push": return { ...model, xs: [...model.xs, msg.v], ticks: model.ticks + 1 };
    case "double": return { ...model, xs: model.xs.map((x) => x * 2), ticks: model.ticks + 1 };
    case "drop_first": return { ...model, xs: model.xs.slice(1), ticks: model.ticks + 1 };
    case "mark": return { ...model, flags: [...model.flags, msg.on], ticks: model.ticks + 1 };
    case "replace": return { ...model, xs: [0.5, -0.5, 3], ticks: model.ticks + 1 };
    case "noop": return { ...model, ticks: model.ticks + 1 };
  }
}
export function xsNow(model: Model): readonly number[] { return model.xs; }
export function trueCount(model: Model): number { return model.flags.filter((f) => f).length; }
`,
    node: `
{
  let model = mod.initialModel();
  const script = [
    { kind: "push", v: 1.5 }, { kind: "push", v: 2 }, { kind: "push", v: 3 },
    { kind: "double" }, { kind: "mark", on: true }, { kind: "drop_first" },
    { kind: "push", v: 4 }, { kind: "replace" }, { kind: "mark", on: false }, { kind: "double" },
  ];
  for (const msg of script) {
    model = mod.update(model, msg);
    line("xs", mod.xsNow(model));
    line("tc", mod.trueCount(model));
  }
  model = mod.update(model, { kind: "noop" });
  line("shr", true);
  line("xs2", mod.xsNow(model));
}
`,
    zig: `
    {
        m.rt.resetAll();
        var model = m.commitModelRoot(m.initialModel());
        m.rt.frameReset();
        const script = [_]m.Msg{
            .{ .push = 1.5 }, .{ .push = 2 }, .{ .push = 3 },
            .double, .{ .mark = true }, .drop_first,
            .{ .push = 4 }, .replace, .{ .mark = false }, .double,
        };
        for (script) |msg| {
            model = m.commitModelRoot(m.update(model, msg));
            m.rt.frameReset();
            row("xs", m.xsNow(model));
            row("tc", m.trueCount(model));
        }
        // Structural sharing: a dispatch that reuses every array commits
        // only the model struct itself (pointer-shared slices copy nothing).
        model = m.commitModelRoot(m.update(model, .noop));
        m.rt.frameReset();
        row("shr", m.rt.stat_commit_last <= @sizeOf(m.Model) + 16);
        row("xs2", m.xsNow(model));
    }
`,
  },
  {
    name: "optional model fields: set/clear cycles over records, bytes, and numbers",
    src: `
import { asciiBytes } from "@native-sdk/core";
export interface Sel { readonly at: number; readonly len: number; }
export interface Model { readonly sel: Sel | null; readonly note: Uint8Array | null; readonly last: number | null; }
export type Msg =
  | { readonly kind: "pick"; readonly at: number; readonly len: number }
  | { readonly kind: "annotate" }
  | { readonly kind: "clear" };
export function initialModel(): Model { return { sel: null, note: null, last: null }; }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "pick": return { sel: { at: msg.at, len: msg.len }, note: model.note, last: msg.at };
    case "annotate":
      return { ...model, note: model.sel !== null && model.sel.len > 0 ? asciiBytes("picked") : null };
    case "clear": return { sel: null, note: null, last: model.last };
  }
}
export function selWidth(model: Model): number {
  return model.sel !== null && model.sel.len > 2 ? model.sel.len : 0;
}
export function noteLen(model: Model): number {
  return model.note === null || model.note.length === 0 ? -1 : model.note.length;
}
export function hasSel(model: Model): boolean {
  return model.sel !== null && model.sel.at >= 0;
}
export function lastOr(model: Model): number {
  return model.last ?? -7;
}
`,
    node: `
{
  let model = mod.initialModel();
  const script = [
    { kind: "annotate" }, { kind: "pick", at: 4, len: 3 }, { kind: "annotate" },
    { kind: "clear" }, { kind: "pick", at: 1, len: 9 }, { kind: "annotate" },
    { kind: "pick", at: -2, len: 0 }, { kind: "annotate" }, { kind: "clear" },
  ];
  for (const msg of script) {
    model = mod.update(model, msg);
    line("w", mod.selWidth(model));
    line("n", mod.noteLen(model));
    line("h", mod.hasSel(model));
    line("l", mod.lastOr(model));
  }
}
`,
    zig: `
    {
        m.rt.resetAll();
        var model = m.commitModelRoot(m.initialModel());
        m.rt.frameReset();
        const script = [_]m.Msg{
            .annotate, .{ .pick = .{ .at = 4, .len = 3 } }, .annotate,
            .clear, .{ .pick = .{ .at = 1, .len = 9 } }, .annotate,
            .{ .pick = .{ .at = -2, .len = 0 } }, .annotate, .clear,
        };
        for (script) |msg| {
            model = m.commitModelRoot(m.update(model, msg));
            m.rt.frameReset();
            row("w", m.selWidth(model));
            row("n", m.noteLen(model));
            row("h", m.hasSel(model));
            row("l", m.lastOr(model));
        }
    }
`,
  },
  {
    name: "null-guarded chains: && / || narrowing over optionals, both orders, loops",
    src: `
export interface Box { readonly items: readonly number[]; readonly tag: number; }
export function hasBig(box: Box | null, lim: number): boolean {
  return box !== null && box.items.length > 0 && box.tag > lim;
}
export function emptyish(box: Box | null): boolean {
  return box === null || box.items.length === 0;
}
export function pickTag(box: Box | null): number {
  return box !== null && box.tag > 0 ? box.tag : -1;
}
export function guardRight(box: Box | null): number {
  if (null !== box && box.tag >= 0) return box.tag + 100;
  return -100;
}
export function below(cls: number | null, lim: number): boolean {
  return cls !== null && cls < lim;
}
export function clamp(cls: number | null): number {
  if (cls === null || cls < 0) return 0;
  return cls;
}
export function walkDown(seed: number): number {
  let cur: Box | null = { items: [seed], tag: seed };
  let hops = 0;
  while (cur !== null && cur.tag > 0) {
    hops += 1;
    cur = cur.tag > 1 ? { items: cur.items, tag: cur.tag - 1 } : null;
  }
  return hops;
}
`,
    node: `
{
  line("d0", mod.hasBig(null, 1));
  line("d1", mod.hasBig({ items: [1, 2], tag: 5 }, 1));
  line("d2", mod.hasBig({ items: [], tag: 5 }, 1));
  line("d3", mod.hasBig({ items: [1], tag: 0 }, 1));
  line("d4", mod.emptyish(null));
  line("d5", mod.emptyish({ items: [], tag: 1 }));
  line("d6", mod.emptyish({ items: [2], tag: 1 }));
  line("d7", mod.pickTag(null));
  line("d8", mod.pickTag({ items: [], tag: 9 }));
  line("d9", mod.pickTag({ items: [], tag: -9 }));
  line("d10", mod.guardRight(null));
  line("d11", mod.guardRight({ items: [], tag: 4 }));
  line("d12", mod.below(null, 5));
  line("d13", mod.below(3, 5));
  line("d14", mod.below(7, 5));
  line("d15", mod.clamp(null));
  line("d16", mod.clamp(-3));
  line("d17", mod.clamp(6));
  line("d18", mod.walkDown(4));
  line("d19", mod.walkDown(0));
}
`,
    zig: `
    {
        row("d0", m.hasBig(null, 1));
        row("d1", m.hasBig(.{ .items = &.{ 1, 2 }, .tag = 5 }, 1));
        row("d2", m.hasBig(.{ .items = &.{}, .tag = 5 }, 1));
        row("d3", m.hasBig(.{ .items = &.{1}, .tag = 0 }, 1));
        row("d4", m.emptyish(null));
        row("d5", m.emptyish(.{ .items = &.{}, .tag = 1 }));
        row("d6", m.emptyish(.{ .items = &.{2}, .tag = 1 }));
        row("d7", m.pickTag(null));
        row("d8", m.pickTag(.{ .items = &.{}, .tag = 9 }));
        row("d9", m.pickTag(.{ .items = &.{}, .tag = -9 }));
        row("d10", m.guardRight(null));
        row("d11", m.guardRight(.{ .items = &.{}, .tag = 4 }));
        row("d12", m.below(null, 5));
        row("d13", m.below(3, 5));
        row("d14", m.below(7, 5));
        row("d15", m.clamp(null));
        row("d16", m.clamp(-3));
        row("d17", m.clamp(6));
        row("d18", m.walkDown(4));
        row("d19", m.walkDown(0));
    }
`,
  },
  {
    name: "-0 literals and -0-producing arithmetic keep the signed zero end to end",
    src: `
export function negZero(): number { return -0; }
export function prodNegZero(): number { return 0 * -1; }
export function viaConst(): number { const z = -0; return z; }
export function timesNeg(x: number): number { return x * -1; }
export function plusZero(x: number): number { return -0 + x; }
`,
    calls: [
      { fn: "negZero", args: [] },
      { fn: "prodNegZero", args: [] },
      { fn: "viaConst", args: [] },
      { fn: "timesNeg", args: [f(0)] },
      { fn: "timesNeg", args: [f("-0")] },
      { fn: "timesNeg", args: [f(2.5)] },
      { fn: "plusZero", args: [f(0)] },
      { fn: "plusZero", args: [f("-0")] },
    ],
  },
  {
    name: "nested callbacks with shared element/index names fold identically",
    src: `
export function weights(xs: readonly number[]): number {
  return xs.map((x, i) => xs.map((y, i2) => y * i2 + i).reduce((acc, v) => acc + v, 0) + x * i).reduce((acc, v) => acc + v, 0);
}
export function pairs(xs: readonly number[]): number {
  return xs.map((x, i) => xs.map((x2, j) => x2 * x + j * i).reduce((a, v) => a + v, 0)).reduce((a, v) => a + v, 0);
}
`,
    calls: [
      { fn: "weights", args: [{ t: "nums", v: [1.5, 2, -3] }] },
      { fn: "weights", args: [{ t: "nums", v: [] }] },
      { fn: "pairs", args: [{ t: "nums", v: [2, 3] }] },
      { fn: "pairs", args: [{ t: "nums", v: [0.5] }] },
    ],
  },
  {
    name: "host-boundary params stay f64: fractional host values compare exactly",
    // Regression (round 2C): comparison against an i64-classed value (a
    // length read, a byte read) must NOT claim an exported parameter to
    // i64 — the host may pass a fraction there, and node compares it
    // exactly. The 2.5/7.5 calls fail to even compile if the claim comes
    // back (the native driver would pass a fraction to an i64 parameter).
    src: `
export function lenIs(bytes: Uint8Array, want: number): boolean {
  return bytes.length === want;
}
export function badge(bytes: Uint8Array, want: number): number {
  return bytes.length === want ? 1 : 0;
}
export function firstIs(bytes: Uint8Array, want: number): boolean {
  return bytes[0] === want;
}
export function pastEnd(bytes: Uint8Array, cursor: number): boolean {
  return cursor >= bytes.length;
}
`,
    calls: [
      { fn: "lenIs", args: [{ t: "bytes", v: [1, 2, 3] }, f(3)] },
      { fn: "lenIs", args: [{ t: "bytes", v: [1, 2, 3] }, f(2.5)] },
      { fn: "lenIs", args: [{ t: "bytes", v: [] }, f(0)] },
      { fn: "lenIs", args: [{ t: "bytes", v: [] }, f("-0")] },
      { fn: "lenIs", args: [{ t: "bytes", v: [1] }, f("nan")] },
      { fn: "badge", args: [{ t: "bytes", v: [1, 2] }, f(2)] },
      { fn: "badge", args: [{ t: "bytes", v: [1, 2] }, f(1.5)] },
      { fn: "firstIs", args: [{ t: "bytes", v: [7, 8] }, f(7)] },
      { fn: "firstIs", args: [{ t: "bytes", v: [7, 8] }, f(7.5)] },
      { fn: "pastEnd", args: [{ t: "bytes", v: [1, 2] }, f(1.5)] },
      { fn: "pastEnd", args: [{ t: "bytes", v: [1, 2] }, f(2)] },
      { fn: "pastEnd", args: [{ t: "bytes", v: [] }, f("-0")] },
    ],
  },
  {
    name: "Cmd v2 host payloads: bytes (empty, large, non-ASCII) and derived records",
    src: `
import { Cmd, asciiBytes } from "@native-sdk/core";
export interface Model { readonly count: number; }
export type Msg =
  | { readonly kind: "put"; readonly blob: Uint8Array }
  | { readonly kind: "empty" }
  | { readonly kind: "cfg"; readonly gain: number; readonly on: boolean };
export function initialModel(): Model { return { count: 0 }; }
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "put": return [{ count: model.count + 1 }, Cmd.host("blob.write", msg.blob)];
    case "empty": return [model, Cmd.host("blob.write", new Uint8Array(0))];
    case "cfg": return [model, Cmd.host("cfg.save", { gain: msg.gain, on: msg.on, tag: asciiBytes("v2") })];
  }
}
`,
    node: `
{
  // Mirror of the rt kernel's Cmd wire format v2 host_bytes record:
  // [0x04][name_len u8][name][payload_len u32 LE][payload].
  const enc = (cmd) => {
    if (cmd.op === "none") return [];
    if (cmd.op === "host_bytes") {
      const name = Array.from(new TextEncoder().encode(cmd.name));
      const len = cmd.payload.length;
      return [4, name.length, ...name, len & 255, (len >> 8) & 255, (len >> 16) & 255, (len >>> 24) & 255, ...cmd.payload];
    }
    return cmd.cmds.flatMap(enc);
  };
  const step = (model, msg) => {
    const r = mod.update(model, msg);
    return Array.isArray(r) ? [r[0], Uint8Array.from(enc(r[1]))] : [r, new Uint8Array(0)];
  };
  let model = mod.initialModel();
  let cmd;
  const big = Uint8Array.from({ length: 300 }, (_, i) => (i * 7) % 251);
  [model, cmd] = step(model, { kind: "put", blob: big });
  line("h0", cmd);
  [model, cmd] = step(model, { kind: "put", blob: Uint8Array.from([0, 255, 128, 10]) });
  line("h1", cmd);
  [model, cmd] = step(model, { kind: "empty" });
  line("h2", cmd);
  [model, cmd] = step(model, { kind: "cfg", gain: 2.5, on: true });
  line("h3", cmd);
  [model, cmd] = step(model, { kind: "cfg", gain: -0, on: false });
  line("h4", cmd);
  line("h5", model.count);
}
`,
    zig: `
    {
        var model = m.initialModel();
        var big: [300]u8 = undefined;
        for (&big, 0..) |*b, i| b.* = @intCast((i * 7) % 251);
        var r = m.update(model, .{ .put = &big });
        model = r.model;
        row("h0", r.cmd);
        r = m.update(model, .{ .put = &[_]u8{ 0, 255, 128, 10 } });
        model = r.model;
        row("h1", r.cmd);
        r = m.update(model, .empty);
        model = r.model;
        row("h2", r.cmd);
        r = m.update(model, .{ .cfg = .{ .gain = 2.5, .on = true } });
        model = r.model;
        row("h3", r.cmd);
        r = m.update(model, .{ .cfg = .{ .gain = -0.0, .on = false } });
        model = r.model;
        row("h4", r.cmd);
        row("h5", model.count);
    }
`,
  },
  {
    name: "Cmd v2 routed requests: init command, ok and err arms delivered as Msgs, cancel",
    src: `
import { Cmd, asciiBytes } from "@native-sdk/core";
export interface Model { readonly data: Uint8Array; readonly errs: number; }
export type Msg =
  | { readonly kind: "load" }
  | { readonly kind: "bad" }
  | { readonly kind: "stop" }
  | { readonly kind: "loaded"; readonly body: Uint8Array }
  | { readonly kind: "failed"; readonly why: Uint8Array };
export function initialModel(): [Model, Cmd<Msg>] {
  return [
    { data: new Uint8Array(0), errs: 0 },
    Cmd.request("store.read", asciiBytes("boot.bin"), { key: "boot", ok: "loaded", err: "failed" }),
  ];
}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "load": return [model, Cmd.request("store.read", asciiBytes("notes.json"), { key: "load", ok: "loaded", err: "failed" })];
    case "bad": return [model, Cmd.request("store.read", asciiBytes("missing.bin"), { ok: "loaded", err: "failed" })];
    case "stop": return [model, Cmd.cancel("load")];
    case "loaded": return { ...model, data: msg.body };
    case "failed": return { ...model, errs: model.errs + 1 };
  }
}
export function dataLen(model: Model): number { return model.data.length; }
`,
    node: `
{
  const kinds = ["load", "bad", "stop", "loaded", "failed"];
  // Mirror of the v2 request/cancel records:
  //   request [0x05][name_len][name][key_len][key][ok][err][len u32 LE][payload]
  //   cancel  [0x06][key_len][key]
  const enc = (cmd) => {
    if (cmd.op === "none") return [];
    if (cmd.op === "cancel") {
      const key = Array.from(new TextEncoder().encode(cmd.key));
      return [6, key.length, ...key];
    }
    if (cmd.op === "request") {
      const name = Array.from(new TextEncoder().encode(cmd.name));
      const key = Array.from(new TextEncoder().encode(cmd.key));
      const p = cmd.payload;
      return [5, name.length, ...name, key.length, ...key, kinds.indexOf(cmd.okKind), kinds.indexOf(cmd.errKind), p.length & 255, (p.length >> 8) & 255, (p.length >> 16) & 255, (p.length >>> 24) & 255, ...p];
    }
    return cmd.cmds.flatMap(enc);
  };
  const step = (model, msg) => {
    const r = mod.update(model, msg);
    return Array.isArray(r) ? [r[0], Uint8Array.from(enc(r[1]))] : [r, new Uint8Array(0)];
  };
  // A scripted host: read the routing tags off the wire and answer with an
  // ordinary Msg built from the named arm's declared shape.
  const routeTags = (bytes) => {
    let at = 1;
    at += 1 + bytes[at];
    at += 1 + bytes[at];
    return [bytes[at], bytes[at + 1]];
  };
  const respond = (model, bytes, okBody, errWhy) => {
    const [ok, err] = routeTags(bytes);
    const msg = okBody !== null ? { kind: kinds[ok], body: okBody } : { kind: kinds[err], why: errWhy };
    return step(model, msg);
  };
  const bytesOf = (s) => new TextEncoder().encode(s);
  const boot = mod.initialModel();
  let model = boot[0];
  let cmd = Uint8Array.from(enc(boot[1]));
  line("r0", cmd);
  [model, cmd] = respond(model, cmd, bytesOf("boot bytes"), null);
  line("r1", cmd);
  line("r2", model.data);
  [model, cmd] = step(model, { kind: "load" });
  line("r3", cmd);
  [model, cmd] = respond(model, cmd, Uint8Array.from([1, 2, 3]), null);
  line("r4", model.data);
  [model, cmd] = step(model, { kind: "bad" });
  line("r5", cmd);
  [model, cmd] = respond(model, cmd, null, bytesOf("not found"));
  line("r6", model.errs);
  line("r7", model.data);
  [model, cmd] = step(model, { kind: "stop" });
  line("r8", cmd);
  line("r9", mod.dataLen(model));
}
`,
    zig: `
    {
        const Host = struct {
            // Read [ok_tag, err_tag] off a wire request record.
            fn routeTags(bytes: []const u8) [2]u8 {
                var at: usize = 1;
                at += 1 + bytes[at];
                at += 1 + bytes[at];
                return .{ bytes[at], bytes[at + 1] };
            }
        };
        const loaded_tag: u8 = @intFromEnum(std.meta.Tag(m.Msg).loaded);
        const boot = m.initialModel();
        var model = boot.model;
        row("r0", boot.cmd);
        var t = Host.routeTags(boot.cmd);
        var r = m.update(model, if (t[0] == loaded_tag) m.Msg{ .loaded = "boot bytes" } else m.Msg{ .failed = "?" });
        model = r.model;
        row("r1", r.cmd);
        row("r2", model.data);
        r = m.update(model, .load);
        model = r.model;
        row("r3", r.cmd);
        t = Host.routeTags(r.cmd);
        r = m.update(model, if (t[0] == loaded_tag) m.Msg{ .loaded = &[_]u8{ 1, 2, 3 } } else m.Msg{ .failed = "?" });
        model = r.model;
        row("r4", model.data);
        r = m.update(model, .bad);
        model = r.model;
        row("r5", r.cmd);
        t = Host.routeTags(r.cmd);
        r = m.update(model, if (t[1] == @intFromEnum(std.meta.Tag(m.Msg).failed)) m.Msg{ .failed = "not found" } else m.Msg{ .loaded = "?" });
        model = r.model;
        row("r6", model.errs);
        row("r7", model.data);
        r = m.update(model, .stop);
        model = r.model;
        row("r8", r.cmd);
        row("r9", m.dataLen(model));
    }
`,
  },
  {
    name: "subscriptions under virtual time: reconcile-by-key, re-arm on interval change, pause and resume",
    src: `
import { Sub } from "@native-sdk/core";
export interface Model { readonly running: boolean; readonly fast: boolean; readonly ticks: number; readonly blinks: number; readonly lastAt: number; }
export type Msg =
  | { readonly kind: "toggle" }
  | { readonly kind: "speed" }
  | { readonly kind: "tick"; readonly at: number }
  | { readonly kind: "blink"; readonly at: number };
export function initialModel(): Model {
  return { running: true, fast: false, ticks: 0, blinks: 0, lastAt: -1 };
}
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "toggle": return { ...model, running: !model.running };
    case "speed": return { ...model, fast: !model.fast };
    case "tick": return { ...model, ticks: model.ticks + 1, lastAt: msg.at };
    case "blink": return { ...model, blinks: model.blinks + 1, lastAt: msg.at };
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
    node: `
{
  const kinds = ["toggle", "speed", "tick", "blink"];
  // Mirror of the v2 timer record: [0x01][key_len][key][every f64 LE][tag].
  const encSub = (s) => {
    if (s.op === "none") return [];
    if (s.op === "timer") {
      const key = Array.from(new TextEncoder().encode(s.key));
      const dv = new DataView(new ArrayBuffer(8));
      dv.setFloat64(0, s.everyMs, true);
      const every = [];
      for (let i = 0; i < 8; i++) every.push(dv.getUint8(i));
      return [1, key.length, ...key, ...every, kinds.indexOf(s.msgKind)];
    }
    return s.subs.flatMap(encSub);
  };
  const parseSubs = (bytes) => {
    const out = [];
    let at = 0;
    while (at < bytes.length) {
      at += 1;
      const keyLen = bytes[at]; at += 1;
      let key = "";
      for (let i = 0; i < keyLen; i++) key += String.fromCharCode(bytes[at + i]);
      at += keyLen;
      const dv = new DataView(Uint8Array.from(bytes.slice(at, at + 8)).buffer);
      out.push({ key, every: dv.getFloat64(0, true), tag: bytes[at + 8] });
      at += 9;
    }
    return out;
  };
  let model = mod.initialModel();
  let now = 0;
  // Four fixed timer slots, reconciled by key: same algorithm as the zig
  // driver, so firing order is identical by construction.
  const timers = [null, null, null, null];
  const reconcile = () => {
    const bytes = encSub(mod.subscriptions(model));
    const want = parseSubs(bytes);
    const seen = [false, false, false, false];
    for (const w of want) {
      let slot = -1;
      for (let i = 0; i < 4; i++) if (timers[i] !== null && timers[i].key === w.key) slot = i;
      if (slot >= 0) {
        seen[slot] = true;
        if (timers[slot].every !== w.every) {
          timers[slot].every = w.every;
          timers[slot].next = now + w.every;
        }
        timers[slot].tag = w.tag;
      } else {
        for (let i = 0; i < 4; i++) {
          if (timers[i] === null) {
            timers[i] = { key: w.key, every: w.every, next: now + w.every, tag: w.tag };
            seen[i] = true;
            break;
          }
        }
      }
    }
    for (let i = 0; i < 4; i++) if (timers[i] !== null && !seen[i]) timers[i] = null;
    return bytes;
  };
  line("v0", Uint8Array.from(reconcile()));
  const inject = { 8: "speed", 14: "toggle", 20: "toggle" };
  for (let step = 1; step <= 26; step++) {
    now += 25;
    for (;;) {
      let idx = -1;
      for (let i = 0; i < 4; i++) {
        if (timers[i] !== null && timers[i].next <= now) { idx = i; break; }
      }
      if (idx < 0) break;
      timers[idx].next += timers[idx].every;
      model = mod.update(model, { kind: kinds[timers[idx].tag], at: now });
      reconcile();
    }
    if (inject[step] !== undefined) {
      model = mod.update(model, { kind: inject[step] });
      line("vr" + step, Uint8Array.from(reconcile()));
    }
  }
  line("v1", model.ticks);
  line("v2", model.blinks);
  line("v3", model.lastAt);
  line("v4", Uint8Array.from(encSub(mod.subscriptions(model))));
}
`,
    zig: `
    {
        const Timer = struct { key: [16]u8, key_len: usize, every: f64, next: f64, tag: u8, live: bool };
        const Host = struct {
            // Reconcile the four fixed slots against a wire descriptor set:
            // match by key, re-arm on interval change, cancel the missing.
            fn reconcile(timers: []Timer, now: f64, subs: []const u8) void {
                var seen = [_]bool{false} ** 4;
                var at: usize = 0;
                while (at < subs.len) {
                    at += 1; // timer op
                    const key_len: usize = subs[at];
                    at += 1;
                    const key = subs[at .. at + key_len];
                    at += key_len;
                    const every: f64 = @bitCast(std.mem.readInt(u64, subs[at..][0..8], .little));
                    at += 8;
                    const tag = subs[at];
                    at += 1;
                    var slot: ?usize = null;
                    for (timers, 0..) |t, i| {
                        if (t.live and std.mem.eql(u8, t.key[0..t.key_len], key)) slot = i;
                    }
                    if (slot) |i| {
                        seen[i] = true;
                        if (timers[i].every != every) {
                            timers[i].every = every;
                            timers[i].next = now + every;
                        }
                        timers[i].tag = tag;
                    } else {
                        for (timers, 0..) |t, i| {
                            if (!t.live) {
                                seen[i] = true;
                                timers[i] = .{ .key = undefined, .key_len = key_len, .every = every, .next = now + every, .tag = tag, .live = true };
                                @memcpy(timers[i].key[0..key_len], key);
                                break;
                            }
                        }
                    }
                }
                for (timers, 0..) |t, i| {
                    if (t.live and !seen[i]) timers[i].live = false;
                }
            }
        };
        var timers = [1]Timer{.{ .key = undefined, .key_len = 0, .every = 0, .next = 0, .tag = 0, .live = false }} ** 4;
        var model = m.initialModel();
        var now: f64 = 0;
        {
            const subs = m.subscriptions(model);
            Host.reconcile(&timers, now, subs);
            row("v0", subs);
        }
        const tick_tag: u8 = @intFromEnum(std.meta.Tag(m.Msg).tick);
        var step: i64 = 1;
        while (step <= 26) : (step += 1) {
            now += 25;
            while (true) {
                var idx: ?usize = null;
                for (timers, 0..) |t, i| {
                    if (t.live and t.next <= now) {
                        idx = i;
                        break;
                    }
                }
                const i = idx orelse break;
                timers[i].next += timers[i].every;
                const msg: m.Msg = if (timers[i].tag == tick_tag) .{ .tick = now } else .{ .blink = now };
                model = m.update(model, msg);
                Host.reconcile(&timers, now, m.subscriptions(model));
            }
            if (step == 8 or step == 14 or step == 20) {
                model = m.update(model, if (step == 8) m.Msg.speed else m.Msg.toggle);
                const subs = m.subscriptions(model);
                Host.reconcile(&timers, now, subs);
                if (step == 8) row("vr8", subs) else if (step == 14) row("vr14", subs) else row("vr20", subs);
            }
        }
        row("v1", model.ticks);
        row("v2", model.blinks);
        row("v3", model.lastAt);
        row("v4", m.subscriptions(model));
    }
`,
  },
  {
    name: "walker determinism under forced compaction: tiny heap, sustained churn",
    options: { frameCap: 32768, heapCap: 8192 },
    src: `
import { asciiBytes } from "@native-sdk/core";
export interface Entry { readonly id: number; readonly label: Uint8Array; }
export interface Model { readonly entries: readonly Entry[]; readonly total: number; }
export type Msg =
  | { readonly kind: "note"; readonly id: number }
  | { readonly kind: "trim" };
export function initialModel(): Model { return { entries: [], total: 0 }; }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "note": {
      const label = asciiBytes(\`entry \${msg.id & 1023}\`);
      return { entries: [...model.entries, { id: msg.id, label: label }], total: model.total + label.length };
    }
    case "trim": return { ...model, entries: model.entries.slice(1) };
  }
}
export function idSum(model: Model): number {
  let t = 0;
  for (const e of model.entries) t += e.id;
  return t;
}
export function labelBytes(model: Model): number {
  let t = 0;
  for (const e of model.entries) t += e.label.length;
  return t;
}
export function count(model: Model): number { return model.entries.length; }
`,
    node: `
{
  let model = mod.initialModel();
  for (let r = 0; r < 120; r++) {
    model = mod.update(model, { kind: "note", id: r });
    model = mod.update(model, { kind: "note", id: r + 500 });
    model = mod.update(model, { kind: "trim" });
    if (r % 20 === 0) {
      line("c", mod.count(model));
      line("s", mod.idSum(model));
      line("b", mod.labelBytes(model));
    }
  }
  line("cmp", true);
  line("fin", mod.idSum(model));
  line("tot", model.total);
}
`,
    zig: `
    {
        m.rt.resetAll();
        var model = m.commitModelRoot(m.initialModel());
        m.rt.frameReset();
        var r: i64 = 0;
        while (r < 120) : (r += 1) {
            model = m.commitModelRoot(m.update(model, .{ .note = r }));
            m.rt.frameReset();
            model = m.commitModelRoot(m.update(model, .{ .note = r + 500 }));
            m.rt.frameReset();
            model = m.commitModelRoot(m.update(model, .trim));
            m.rt.frameReset();
            if (@rem(r, 20) == 0) {
                row("c", m.count(model));
                row("s", m.idSum(model));
                row("b", m.labelBytes(model));
            }
        }
        // The tiny heap makes the two-space flip fire for real: silence here
        // would mean the case stopped proving compaction determinism.
        row("cmp", m.rt.stat_compactions > 0);
        row("fin", m.idSum(model));
        row("tot", model.total);
    }
`,
  },
  {
    name: "named file/clipboard ops: wire records and ok/void/err arms under a virtual host",
    src: `
import { Cmd, asciiBytes } from "@native-sdk/core";
export interface Model { readonly data: Uint8Array; readonly saved: number; readonly errs: number; readonly lastErr: Uint8Array; }
export type Msg =
  | { readonly kind: "load" }
  | { readonly kind: "save" }
  | { readonly kind: "copy" }
  | { readonly kind: "paste" }
  | { readonly kind: "loaded"; readonly body: Uint8Array }
  | { readonly kind: "wrote" }
  | { readonly kind: "failed"; readonly why: Uint8Array };
export function initialModel(): Model { return { data: new Uint8Array(0), saved: 0, errs: 0, lastErr: new Uint8Array(0) }; }
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "load": return [model, Cmd.readFile(asciiBytes("store.bin"), { key: "io", ok: "loaded", err: "failed" })];
    case "save": return [model, Cmd.writeFile(asciiBytes("store.bin"), model.data, { key: "io", ok: "wrote", err: "failed" })];
    case "copy": return [model, Cmd.clipboardWrite(model.data)];
    case "paste": return [model, Cmd.clipboardRead({ key: "clip", ok: "loaded", err: "failed" })];
    case "loaded": return { ...model, data: msg.body };
    case "wrote": return { ...model, saved: model.saved + 1 };
    case "failed": return { ...model, errs: model.errs + 1, lastErr: msg.why };
  }
}
`,
    node: `
{
  const kinds = ["load", "save", "copy", "paste", "loaded", "wrote", "failed"];
  const te = new TextEncoder();
  // Mirrors of the named-op wire records (rt.zig): routed head =
  // [op][key_len][key][ok][err]; long fields = [len u32 LE][bytes].
  const long = (b) => [b.length & 255, (b.length >> 8) & 255, (b.length >> 16) & 255, (b.length >>> 24) & 255, ...b];
  const head = (op, c) => { const k = Array.from(te.encode(c.key)); return [op, k.length, ...k, kinds.indexOf(c.okKind), kinds.indexOf(c.errKind)]; };
  const enc = (cmd) => {
    if (cmd.op === "none") return [];
    if (cmd.op === "read_file") return [...head(7, cmd), ...long(Array.from(cmd.path))];
    if (cmd.op === "write_file") return [...head(8, cmd), ...long(Array.from(cmd.path)), ...long(Array.from(cmd.bytes))];
    if (cmd.op === "clip_write") return [10, ...long(Array.from(cmd.bytes))];
    if (cmd.op === "clip_read") return head(11, cmd);
    return cmd.cmds.flatMap(enc);
  };
  const step = (model, msg) => { const r = mod.update(model, msg); return Array.isArray(r) ? [r[0], Uint8Array.from(enc(r[1]))] : [r, new Uint8Array(0)]; };
  // ok/err tags sit right after the key on every routed head.
  const routeTags = (bytes) => { let at = 1; at += 1 + bytes[at]; return [bytes[at], bytes[at + 1]]; };
  let model = mod.initialModel();
  let cmd;
  [model, cmd] = step(model, { kind: "load" });
  line("f0", cmd);
  let t = routeTags(cmd);
  [model, cmd] = step(model, { kind: kinds[t[0]], body: te.encode("disk!") });
  line("f1", model.data);
  [model, cmd] = step(model, { kind: "save" });
  line("f2", cmd);
  t = routeTags(cmd);
  [model, cmd] = step(model, { kind: kinds[t[0]] });
  line("f3", model.saved);
  [model, cmd] = step(model, { kind: "save" });
  t = routeTags(cmd);
  [model, cmd] = step(model, { kind: kinds[t[1]], why: te.encode("io_failed") });
  line("f4", model.errs);
  line("f5", model.lastErr);
  [model, cmd] = step(model, { kind: "copy" });
  line("f6", cmd);
  [model, cmd] = step(model, { kind: "paste" });
  line("f7", cmd);
  t = routeTags(cmd);
  [model, cmd] = step(model, { kind: kinds[t[0]], body: new Uint8Array(0) });
  line("f8", model.data);
  [model, cmd] = step(model, { kind: "paste" });
  t = routeTags(cmd);
  [model, cmd] = step(model, { kind: kinds[t[1]], why: te.encode("failed") });
  line("f9", model.errs);
  line("f10", model.lastErr);
}
`,
    zig: `
    {
        const Host = struct {
            // ok/err tags sit right after the key on every routed head.
            fn routeTags(bytes: []const u8) [2]u8 {
                var at: usize = 1;
                at += 1 + bytes[at];
                return .{ bytes[at], bytes[at + 1] };
            }
        };
        const loaded_tag: u8 = @intFromEnum(std.meta.Tag(m.Msg).loaded);
        const wrote_tag: u8 = @intFromEnum(std.meta.Tag(m.Msg).wrote);
        var model = m.initialModel();
        var r = m.update(model, .load);
        model = r.model;
        row("f0", r.cmd);
        var t = Host.routeTags(r.cmd);
        r = m.update(model, if (t[0] == loaded_tag) m.Msg{ .loaded = "disk!" } else m.Msg{ .failed = "?" });
        model = r.model;
        row("f1", model.data);
        r = m.update(model, .save);
        model = r.model;
        row("f2", r.cmd);
        t = Host.routeTags(r.cmd);
        r = m.update(model, if (t[0] == wrote_tag) m.Msg.wrote else m.Msg{ .failed = "?" });
        model = r.model;
        row("f3", model.saved);
        r = m.update(model, .save);
        model = r.model;
        t = Host.routeTags(r.cmd);
        r = m.update(model, if (t[1] == @intFromEnum(std.meta.Tag(m.Msg).failed)) m.Msg{ .failed = "io_failed" } else m.Msg.wrote);
        model = r.model;
        row("f4", model.errs);
        row("f5", model.lastErr);
        r = m.update(model, .copy);
        model = r.model;
        row("f6", r.cmd);
        r = m.update(model, .paste);
        model = r.model;
        row("f7", r.cmd);
        t = Host.routeTags(r.cmd);
        r = m.update(model, if (t[0] == loaded_tag) m.Msg{ .loaded = "" } else m.Msg{ .failed = "?" });
        model = r.model;
        row("f8", model.data);
        r = m.update(model, .paste);
        model = r.model;
        t = Host.routeTags(r.cmd);
        r = m.update(model, if (t[1] == @intFromEnum(std.meta.Tag(m.Msg).failed)) m.Msg{ .failed = "failed" } else m.Msg.wrote);
        model = r.model;
        row("f9", model.errs);
        row("f10", model.lastErr);
    }
`,
  },
  {
    name: "fetch {status, body} records and one-shot delays under virtual time",
    src: `
import { Cmd, asciiBytes } from "@native-sdk/core";
export interface Model { readonly code: number; readonly body: Uint8Array; readonly errs: number; readonly lastErr: Uint8Array; readonly fires: number; readonly lastAt: number; }
export type Msg =
  | { readonly kind: "get" }
  | { readonly kind: "ping" }
  | { readonly kind: "secure" }
  | { readonly kind: "wait" }
  | { readonly kind: "wait_fast" }
  | { readonly kind: "stop" }
  | { readonly kind: "fetched"; readonly status: number; readonly body: Uint8Array }
  | { readonly kind: "fired"; readonly at: number }
  | { readonly kind: "failed"; readonly why: Uint8Array };
export function initialModel(): Model { return { code: -1, body: new Uint8Array(0), errs: 0, lastErr: new Uint8Array(0), fires: 0, lastAt: -1 }; }
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "get": return [model, Cmd.fetch({ url: asciiBytes("https://api.test/items"), method: "POST", headers: { "x-b": "2", "x-a": "1" }, body: asciiBytes("q=1"), timeoutMs: 750 }, { key: "get", ok: "fetched", err: "failed" })];
    case "ping": return [model, Cmd.fetch({ url: model.body }, { ok: "fetched", err: "failed" })];
    case "secure": return [model, Cmd.fetch({ url: asciiBytes("https://api.test/private"), headers: { authorization: model.body, "x-static": "yes" } }, { key: "auth", ok: "fetched", err: "failed" })];
    case "wait": return [model, Cmd.delay("tick", 100, "fired")];
    case "wait_fast": return [model, Cmd.delay("tick", 40, "fired")];
    case "stop": return [model, Cmd.cancel("tick")];
    case "fetched": return { ...model, code: msg.status, body: msg.body };
    case "fired": return { ...model, fires: model.fires + 1, lastAt: msg.at };
    case "failed": return { ...model, errs: model.errs + 1, lastErr: msg.why };
  }
}
`,
    node: `
{
  const kinds = ["get", "ping", "secure", "wait", "wait_fast", "stop", "fetched", "fired", "failed"];
  const te = new TextEncoder();
  const methods = ["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD"];
  // Mirrors of the fetch/delay/cancel wire records (rt.zig). A header
  // value is compile-time text (string) or runtime bytes (Uint8Array);
  // both encode as the same length-prefixed value field.
  const long = (b) => [b.length & 255, (b.length >> 8) & 255, (b.length >> 16) & 255, (b.length >>> 24) & 255, ...b];
  const f64le = (v) => { const dv = new DataView(new ArrayBuffer(8)); dv.setFloat64(0, v, true); const out = []; for (let i = 0; i < 8; i++) out.push(dv.getUint8(i)); return out; };
  const enc = (cmd) => {
    if (cmd.op === "none") return [];
    if (cmd.op === "fetch") {
      const k = Array.from(te.encode(cmd.key));
      const t = cmd.timeoutMs;
      const out = [9, k.length, ...k, kinds.indexOf(cmd.okKind), kinds.indexOf(cmd.errKind), methods.indexOf(cmd.method), t & 255, (t >> 8) & 255, (t >> 16) & 255, (t >>> 24) & 255, ...long(Array.from(cmd.url)), cmd.headers.length];
      for (const h of cmd.headers) { const n = Array.from(te.encode(h.name)); const v = typeof h.value === "string" ? Array.from(te.encode(h.value)) : Array.from(h.value); out.push(n.length, ...n, ...long(v)); }
      out.push(...long(Array.from(cmd.body)));
      return out;
    }
    if (cmd.op === "delay") { const k = Array.from(te.encode(cmd.key)); return [12, k.length, ...k, ...f64le(cmd.afterMs), kinds.indexOf(cmd.msgKind)]; }
    if (cmd.op === "cancel") { const k = Array.from(te.encode(cmd.key)); return [6, k.length, ...k]; }
    return cmd.cmds.flatMap(enc);
  };
  const step = (model, msg) => { const r = mod.update(model, msg); return Array.isArray(r) ? [r[0], Uint8Array.from(enc(r[1]))] : [r, new Uint8Array(0)]; };
  const routeTags = (bytes) => { let at = 1; at += 1 + bytes[at]; return [bytes[at], bytes[at + 1]]; };
  let model = mod.initialModel();
  let cmd;
  [model, cmd] = step(model, { kind: "get" });
  line("g0", cmd);
  let t = routeTags(cmd);
  [model, cmd] = step(model, { kind: kinds[t[0]], status: 200, body: te.encode("hello") });
  line("g1", model.code);
  line("g2", model.body);
  // A RUNTIME Authorization header value (model.body) rides the same
  // record as the literal x-static header, in name-sort order —
  // byte-identical under node and native.
  [model, cmd] = step(model, { kind: "secure" });
  line("s0", cmd);
  t = routeTags(cmd);
  [model, cmd] = step(model, { kind: kinds[t[0]], status: 201, body: te.encode("hello") });
  line("s1", model.code);
  line("s2", model.body);
  // A dynamic bytes URL flows through the same record.
  [model, cmd] = step(model, { kind: "ping" });
  line("g3", cmd);
  t = routeTags(cmd);
  [model, cmd] = step(model, { kind: kinds[t[0]], status: 204, body: new Uint8Array(0) });
  line("g4", model.code);
  line("g5", model.body);
  [model, cmd] = step(model, { kind: "get" });
  t = routeTags(cmd);
  [model, cmd] = step(model, { kind: kinds[t[1]], why: te.encode("timed_out") });
  line("g6", model.errs);
  line("g7", model.lastErr);
  // Delay under virtual time: arm at now=0 for 100ms, re-arm the live
  // key for 40ms (replace), fire once at 40 with the delay's own tag.
  [model, cmd] = step(model, { kind: "wait" });
  line("d0", cmd);
  const tag0 = cmd[cmd.length - 1];
  [model, cmd] = step(model, { kind: "wait_fast" });
  line("d1", cmd);
  const tag1 = cmd[cmd.length - 1];
  line("d2", tag0 === tag1);
  [model, cmd] = step(model, { kind: kinds[tag1], at: 40 });
  line("d3", model.fires);
  line("d4", model.lastAt);
  // Re-arm then cancel: the delay never fires, nothing routes.
  [model, cmd] = step(model, { kind: "wait" });
  [model, cmd] = step(model, { kind: "stop" });
  line("d5", cmd);
  line("d6", model.fires);
}
`,
    zig: `
    {
        const Host = struct {
            fn routeTags(bytes: []const u8) [2]u8 {
                var at: usize = 1;
                at += 1 + bytes[at];
                return .{ bytes[at], bytes[at + 1] };
            }
        };
        const fetched_tag: u8 = @intFromEnum(std.meta.Tag(m.Msg).fetched);
        var model = m.initialModel();
        var r = m.update(model, .get);
        model = r.model;
        row("g0", r.cmd);
        var t = Host.routeTags(r.cmd);
        r = m.update(model, if (t[0] == fetched_tag) m.Msg{ .fetched = .{ .status = 200, .body = "hello" } } else m.Msg{ .failed = "?" });
        model = r.model;
        row("g1", model.code);
        row("g2", model.body);
        r = m.update(model, .secure);
        model = r.model;
        row("s0", r.cmd);
        t = Host.routeTags(r.cmd);
        r = m.update(model, if (t[0] == fetched_tag) m.Msg{ .fetched = .{ .status = 201, .body = "hello" } } else m.Msg{ .failed = "?" });
        model = r.model;
        row("s1", model.code);
        row("s2", model.body);
        r = m.update(model, .ping);
        model = r.model;
        row("g3", r.cmd);
        t = Host.routeTags(r.cmd);
        r = m.update(model, if (t[0] == fetched_tag) m.Msg{ .fetched = .{ .status = 204, .body = "" } } else m.Msg{ .failed = "?" });
        model = r.model;
        row("g4", model.code);
        row("g5", model.body);
        r = m.update(model, .get);
        model = r.model;
        t = Host.routeTags(r.cmd);
        r = m.update(model, if (t[1] == @intFromEnum(std.meta.Tag(m.Msg).failed)) m.Msg{ .failed = "timed_out" } else m.Msg{ .failed = "?" });
        model = r.model;
        row("g6", model.errs);
        row("g7", model.lastErr);
        r = m.update(model, .wait);
        model = r.model;
        row("d0", r.cmd);
        const tag0 = r.cmd[r.cmd.len - 1];
        r = m.update(model, .wait_fast);
        model = r.model;
        row("d1", r.cmd);
        const tag1 = r.cmd[r.cmd.len - 1];
        row("d2", tag0 == tag1);
        r = m.update(model, if (tag1 == @intFromEnum(std.meta.Tag(m.Msg).fired)) m.Msg{ .fired = 40 } else m.Msg{ .failed = "?" });
        model = r.model;
        row("d3", model.fires);
        row("d4", model.lastAt);
        r = m.update(model, .wait);
        model = r.model;
        r = m.update(model, .stop);
        model = r.model;
        row("d5", r.cmd);
        row("d6", model.fires);
    }
`,
  },
  {
    name: "spawn streams and audio events under the virtual host: ordering, cancel mid-stream, collect",
    src: `
import { Cmd, asciiBytes } from "@native-sdk/core";
export type AudioState = "loaded" | "position" | "completed" | "failed" | "rejected" | "spectrum";
export interface Model {
  readonly lines: number; readonly last: Uint8Array; readonly code: number; readonly out: Uint8Array;
  readonly errs: number; readonly lastErr: Uint8Array;
  readonly state: AudioState; readonly pos: number; readonly dur: number; readonly playing: boolean;
  readonly bands: Uint8Array; readonly events: number;
}
export type Msg =
  | { readonly kind: "sample" }
  | { readonly kind: "gather" }
  | { readonly kind: "halt" }
  | { readonly kind: "play" }
  | { readonly kind: "drive" }
  | { readonly kind: "line"; readonly text: Uint8Array }
  | { readonly kind: "done"; readonly code: number }
  | { readonly kind: "sampled"; readonly code: number; readonly output: Uint8Array }
  | { readonly kind: "audio_evt"; readonly state: AudioState; readonly positionMs: number; readonly durationMs: number; readonly playing: boolean; readonly buffering: boolean; readonly bands: Uint8Array }
  | { readonly kind: "failed"; readonly why: Uint8Array };
export function initialModel(): Model {
  return { lines: 0, last: new Uint8Array(0), code: -1, out: new Uint8Array(0), errs: 0, lastErr: new Uint8Array(0), state: "rejected", pos: -1, dur: -1, playing: false, bands: new Uint8Array(0), events: 0 };
}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "sample": return [model, Cmd.spawn([asciiBytes("/bin/probe"), asciiBytes("--cpu")], { key: "job", stdin: model.last, line: "line", exit: "done", err: "failed" })];
    case "gather": return [model, Cmd.spawn([asciiBytes("/bin/gather")], { key: "job", collect: true, exit: "sampled", err: "failed" })];
    case "halt": return [model, Cmd.cancel("job")];
    case "play": return [model, Cmd.audioPlay("track", { path: asciiBytes("a.mp3"), url: asciiBytes("https://c.test/a.mp3"), cachePath: asciiBytes("cache/a"), expectedBytes: 2048 }, { event: "audio_evt" })];
    case "drive": return [model, Cmd.batch([Cmd.audioPause("track"), Cmd.audioSeek("track", 30000), Cmd.audioSetVolume("track", 0.5), Cmd.audioStop("track")])];
    case "line": return { ...model, lines: model.lines + 1, last: msg.text };
    case "done": return { ...model, code: msg.code };
    case "sampled": return { ...model, code: msg.code, out: msg.output };
    case "audio_evt": return { ...model, state: msg.state, pos: msg.positionMs, dur: msg.durationMs, playing: msg.playing, bands: msg.bands, events: model.events + 1 };
    case "failed": return { ...model, errs: model.errs + 1, lastErr: msg.why };
  }
}
`,
    node: `
{
  const kinds = ["sample", "gather", "halt", "play", "drive", "line", "done", "sampled", "audio_evt", "failed"];
  const states = ["loaded", "position", "completed", "failed", "rejected", "spectrum"];
  const te = new TextEncoder();
  // Mirrors of the streaming wire records (rt.zig).
  const long = (b) => [b.length & 255, (b.length >> 8) & 255, (b.length >> 16) & 255, (b.length >>> 24) & 255, ...b];
  const f64le = (v) => { const dv = new DataView(new ArrayBuffer(8)); dv.setFloat64(0, v, true); const out = []; for (let i = 0; i < 8; i++) out.push(dv.getUint8(i)); return out; };
  const verbs = ["pause", "resume", "stop", "seek", "volume"];
  const enc = (cmd) => {
    if (cmd.op === "none") return [];
    if (cmd.op === "cancel") { const k = Array.from(te.encode(cmd.key)); return [6, k.length, ...k]; }
    if (cmd.op === "spawn") {
      const k = Array.from(te.encode(cmd.key));
      const lineTag = cmd.lineKind === "" ? 0xff : kinds.indexOf(cmd.lineKind);
      const out = [13, k.length, ...k, lineTag, kinds.indexOf(cmd.exitKind), kinds.indexOf(cmd.errKind), cmd.collect ? 1 : 0, cmd.argv.length];
      for (const arg of cmd.argv) out.push(...long(Array.from(arg)));
      out.push(...long(Array.from(cmd.stdin)));
      return out;
    }
    if (cmd.op === "audio_play") {
      const k = Array.from(te.encode(cmd.key));
      return [14, k.length, ...k, kinds.indexOf(cmd.eventKind), ...long(Array.from(cmd.path)), ...long(Array.from(cmd.url)), ...long(Array.from(cmd.cachePath)), ...f64le(cmd.expectedBytes)];
    }
    if (cmd.op === "audio_ctl") {
      const k = Array.from(te.encode(cmd.key));
      return [15, k.length, ...k, verbs.indexOf(cmd.verb), ...f64le(cmd.value)];
    }
    return cmd.cmds.flatMap(enc);
  };
  const step = (model, msg) => { const r = mod.update(model, msg); return Array.isArray(r) ? [r[0], Uint8Array.from(enc(r[1]))] : [r, new Uint8Array(0)]; };
  // The virtual host reads a spawn record's routing tags off the wire:
  // [op][key][line][exit][err] — the canned scripts below dispatch arms
  // built from exactly these bytes, mirroring the zig driver.
  const spawnTags = (bytes) => { let at = 1; at += 1 + bytes[at]; return { line: bytes[at], exit: bytes[at + 1], err: bytes[at + 2] }; };
  const audioTag = (bytes) => { let at = 1; at += 1 + bytes[at]; return bytes[at]; };
  let model = mod.initialModel();
  let cmd;

  // Audio stream: play opens it; a canned event script drives the arm.
  [model, cmd] = step(model, { kind: "play" });
  line("a0", cmd);
  const evTag = audioTag(cmd);
  const bands0 = new Uint8Array(32);
  const ev = (state, positionMs, durationMs, playing, buffering, bands) => ({ kind: kinds[evTag], state, positionMs, durationMs, playing, buffering, bands });
  [model, cmd] = step(model, ev("loaded", 0, 180000, true, false, bands0));
  line("a1", model.state);
  line("a2", model.dur);
  line("a3", model.playing);
  [model, cmd] = step(model, ev("position", 500, 180000, true, false, bands0));
  line("a4", model.pos);
  const bands = Uint8Array.from({ length: 32 }, (_, i) => i * 5);
  [model, cmd] = step(model, ev("spectrum", 750, 180000, true, false, bands));
  line("a5", model.bands);
  line("a6", model.events);
  [model, cmd] = step(model, { kind: "drive" });
  line("a7", cmd);

  // Line spawn: lines route across dispatches in order, then cancel
  // mid-stream delivers the err arm — never silent.
  [model, cmd] = step(model, { kind: "sample" });
  line("s0", cmd);
  const t = spawnTags(cmd);
  [model, cmd] = step(model, { kind: kinds[t.line], text: te.encode("cpu 40") });
  line("s1", model.lines);
  line("s2", model.last);
  [model, cmd] = step(model, { kind: kinds[t.line], text: te.encode("cpu 7") });
  line("s3", model.lines);
  [model, cmd] = step(model, { kind: "halt" });
  line("s4", cmd);
  [model, cmd] = step(model, { kind: kinds[t.err], why: te.encode("cancelled") });
  line("s5", model.errs);
  line("s6", model.lastErr);

  // The key is free again: a fresh stream exits cleanly with its code.
  [model, cmd] = step(model, { kind: "sample" });
  line("s7", cmd);
  [model, cmd] = step(model, { kind: kinds[t.exit], code: 3 });
  line("s8", model.code);

  // Collect spawn: the exit carries { code, output } whole.
  [model, cmd] = step(model, { kind: "gather" });
  line("g0", cmd);
  const tc = spawnTags(cmd);
  [model, cmd] = step(model, { kind: kinds[tc.exit], code: 0, output: te.encode("PID CPU\\n17 99.0\\n") });
  line("g1", model.code);
  line("g2", model.out);
}
`,
    zig: `
    {
        const Host = struct {
            fn spawnTags(bytes: []const u8) [3]u8 {
                var at: usize = 1;
                at += 1 + bytes[at];
                return .{ bytes[at], bytes[at + 1], bytes[at + 2] };
            }
            fn audioTag(bytes: []const u8) u8 {
                var at: usize = 1;
                at += 1 + bytes[at];
                return bytes[at];
            }
        };
        const line_tag: u8 = @intFromEnum(std.meta.Tag(m.Msg).line);
        const done_tag: u8 = @intFromEnum(std.meta.Tag(m.Msg).done);
        const sampled_tag: u8 = @intFromEnum(std.meta.Tag(m.Msg).sampled);
        const audio_tag: u8 = @intFromEnum(std.meta.Tag(m.Msg).audio_evt);
        const failed_tag: u8 = @intFromEnum(std.meta.Tag(m.Msg).failed);
        var model = m.initialModel();

        var r = m.update(model, .play);
        model = r.model;
        row("a0", r.cmd);
        const ev_tag = Host.audioTag(r.cmd);
        const bands0 = [_]u8{0} ** 32;
        r = m.update(model, if (ev_tag == audio_tag) m.Msg{ .audio_evt = .{ .state = .loaded, .positionMs = 0, .durationMs = 180000, .playing = true, .buffering = false, .bands = &bands0 } } else m.Msg{ .failed = "?" });
        model = r.model;
        row("a1", model.state);
        row("a2", model.dur);
        row("a3", model.playing);
        r = m.update(model, .{ .audio_evt = .{ .state = .position, .positionMs = 500, .durationMs = 180000, .playing = true, .buffering = false, .bands = &bands0 } });
        model = r.model;
        row("a4", model.pos);
        var bands: [32]u8 = undefined;
        for (&bands, 0..) |*b, i| b.* = @intCast(i * 5);
        r = m.update(model, .{ .audio_evt = .{ .state = .spectrum, .positionMs = 750, .durationMs = 180000, .playing = true, .buffering = false, .bands = &bands } });
        model = r.model;
        row("a5", model.bands);
        row("a6", model.events);
        r = m.update(model, .drive);
        model = r.model;
        row("a7", r.cmd);

        r = m.update(model, .sample);
        model = r.model;
        row("s0", r.cmd);
        const t = Host.spawnTags(r.cmd);
        r = m.update(model, if (t[0] == line_tag) m.Msg{ .line = "cpu 40" } else m.Msg{ .failed = "?" });
        model = r.model;
        row("s1", model.lines);
        row("s2", model.last);
        r = m.update(model, if (t[0] == line_tag) m.Msg{ .line = "cpu 7" } else m.Msg{ .failed = "?" });
        model = r.model;
        row("s3", model.lines);
        r = m.update(model, .halt);
        model = r.model;
        row("s4", r.cmd);
        r = m.update(model, if (t[2] == failed_tag) m.Msg{ .failed = "cancelled" } else m.Msg{ .failed = "?" });
        model = r.model;
        row("s5", model.errs);
        row("s6", model.lastErr);

        r = m.update(model, .sample);
        model = r.model;
        row("s7", r.cmd);
        r = m.update(model, if (t[1] == done_tag) m.Msg{ .done = 3 } else m.Msg{ .failed = "?" });
        model = r.model;
        row("s8", model.code);

        r = m.update(model, .gather);
        model = r.model;
        row("g0", r.cmd);
        const tc = Host.spawnTags(r.cmd);
        r = m.update(model, if (tc[1] == sampled_tag) m.Msg{ .sampled = .{ .code = 0, .output = "PID CPU\\n17 99.0\\n" } } else m.Msg{ .failed = "?" });
        model = r.model;
        row("g1", model.code);
        row("g2", model.out);
    }
`,
  },
  {
    name: "declared text-input mirror union: payload arms, stacked verbs, byte-splice reducer",
    src: `
export type TextCaretDirection = "previous" | "next" | "previous_word" | "next_word" | "start" | "end";
export interface TextCaretMove { readonly direction: TextCaretDirection; readonly extend: boolean; }
export interface TextSelection { readonly anchor: number; readonly focus: number; }
export type TextInputEvent =
  | { readonly kind: "insert_text"; readonly text: Uint8Array }
  | { readonly kind: "delete_backward" }
  | { readonly kind: "delete_forward" }
  | { readonly kind: "delete_word_backward" }
  | { readonly kind: "delete_word_forward" }
  | { readonly kind: "clear" }
  | { readonly kind: "move_caret"; readonly move: TextCaretMove }
  | { readonly kind: "set_selection"; readonly selection: TextSelection }
  | { readonly kind: "set_composition"; readonly text: Uint8Array; readonly cursor: number | null }
  | { readonly kind: "commit_composition" }
  | { readonly kind: "cancel_composition" };
export interface Model { readonly draft: Uint8Array; readonly moves: number; }
export type Msg =
  | { readonly kind: "draft_edit"; readonly edit: TextInputEvent }
  | { readonly kind: "reset" };
function applyDraftEdit(draft: Uint8Array, edit: TextInputEvent): Uint8Array {
  switch (edit.kind) {
    case "insert_text": {
      const out = new Uint8Array(draft.length + edit.text.length);
      out.set(draft, 0);
      out.set(edit.text, draft.length);
      return out;
    }
    case "delete_backward":
      return draft.length === 0 ? draft : draft.subarray(0, draft.length - 1);
    case "clear":
      return new Uint8Array(0);
    case "delete_forward":
    case "delete_word_backward":
    case "delete_word_forward":
    case "move_caret":
    case "set_selection":
    case "set_composition":
    case "commit_composition":
    case "cancel_composition":
      return draft;
  }
}
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "draft_edit":
      return { draft: applyDraftEdit(model.draft, msg.edit), moves: model.moves + 1 };
    case "reset":
      return { draft: new Uint8Array(0), moves: 0 };
  }
}
export function initialModel(): Model { return { draft: new Uint8Array(0), moves: 0 }; }
`,
    node: `
{
  const te = new TextEncoder();
  let model = mod.initialModel();
  const edits = [
    { kind: "insert_text", text: te.encode("hi") },
    { kind: "insert_text", text: te.encode(" there") },
    { kind: "delete_backward" },
    { kind: "move_caret", move: { direction: "previous_word", extend: true } },
    { kind: "set_selection", selection: { anchor: 1, focus: 3 } },
    { kind: "set_composition", text: te.encode("x"), cursor: null },
    { kind: "delete_forward" },
    { kind: "clear" },
    { kind: "insert_text", text: te.encode("z") },
  ];
  for (const edit of edits) {
    model = mod.update(model, { kind: "draft_edit", edit: edit });
    line("d", model.draft);
    line("m", model.moves);
  }
  model = mod.update(model, { kind: "reset" });
  line("d2", model.draft);
  line("m2", model.moves);
}
`,
    zig: `
    {
        m.rt.resetAll();
        var model = m.commitModelRoot(m.initialModel());
        m.rt.frameReset();
        const edits = [_]m.TextInputEvent{
            .{ .insert_text = "hi" },
            .{ .insert_text = " there" },
            .delete_backward,
            .{ .move_caret = .{ .direction = .previous_word, .extend = true } },
            .{ .set_selection = .{ .anchor = 1, .focus = 3 } },
            .{ .set_composition = .{ .text = "x", .cursor = null } },
            .delete_forward,
            .clear,
            .{ .insert_text = "z" },
        };
        for (edits) |edit| {
            model = m.commitModelRoot(m.update(model, .{ .draft_edit = edit }));
            m.rt.frameReset();
            row("d", model.draft);
            row("m", model.moves);
        }
        model = m.commitModelRoot(m.update(model, .reset));
        m.rt.frameReset();
        row("d2", model.draft);
        row("m2", model.moves);
    }
`,
  },
  {
    name: "multi-file core: cross-file helpers/consts and the SDK text engine agree with node",
    src: `
import { applyTextInputEvent, containsIgnoreCase, trimAsciiSpaces, type TextEditState, type TextInputEvent } from "@native-sdk/core/text";
import { STEP, scaled, splitPoint } from "./util.ts";

export function typed(seed: Uint8Array, insert: Uint8Array, caret: number): Uint8Array {
  const state: TextEditState = { text: seed, selection: { anchor: caret, focus: caret }, composition: null };
  const event: TextInputEvent = { kind: "insert_text", text: insert };
  const next = applyTextInputEvent(state, event, 16);
  if (next === null) return seed;
  return next.text;
}
export function wordDeleted(seed: Uint8Array, caret: number): Uint8Array {
  const state: TextEditState = { text: seed, selection: { anchor: caret, focus: caret }, composition: null };
  const event: TextInputEvent = { kind: "delete_word_backward" };
  const next = applyTextInputEvent(state, event, 64);
  if (next === null) return seed;
  return next.text;
}
export function caretAfterHome(seed: Uint8Array, caret: number): number {
  const state: TextEditState = { text: seed, selection: { anchor: caret, focus: caret }, composition: null };
  const event: TextInputEvent = { kind: "move_caret", move: { direction: "start", extend: false } };
  const next = applyTextInputEvent(state, event, 64);
  if (next === null) return caret;
  return next.selection.focus;
}
export function matches(hay: Uint8Array, needle: Uint8Array): boolean {
  return containsIgnoreCase(trimAsciiSpaces(hay), needle);
}
export function stepped(n: number): number {
  return scaled(n) + STEP;
}
export function pivot(xs: Uint8Array): number {
  return splitPoint(xs);
}
`,
    files: {
      "util.ts": `
export const STEP = 7;
export function scaled(n: number): number {
  return n * 3;
}
export function splitPoint(bytes: Uint8Array): number {
  let i = 0;
  while (i < bytes.length && bytes[i] !== 0x2c) i += 1;
  return i;
}
`,
    },
    calls: [
      // Insert mid-text (caret 2 of "hello"), and an over-capacity refusal.
      { fn: "typed", args: [{ t: "bytes", v: [0x68, 0x65, 0x6c, 0x6c, 0x6f] }, { t: "bytes", v: [0x2d, 0x2d] }, i(2)] },
      { fn: "typed", args: [{ t: "bytes", v: [0x68, 0x65, 0x6c, 0x6c, 0x6f] }, { t: "bytes", v: [0x61, 0x61, 0x61, 0x61, 0x61, 0x61, 0x61, 0x61, 0x61, 0x61, 0x61, 0x61] }, i(5)] },
      // Word-delete from the end of "one two", and from inside a word.
      { fn: "wordDeleted", args: [{ t: "bytes", v: [0x6f, 0x6e, 0x65, 0x20, 0x74, 0x77, 0x6f] }, i(7)] },
      { fn: "wordDeleted", args: [{ t: "bytes", v: [0x6f, 0x6e, 0x65, 0x20, 0x74, 0x77, 0x6f] }, i(5)] },
      { fn: "caretAfterHome", args: [{ t: "bytes", v: [0x61, 0x62, 0x63] }, i(2)] },
      // ASCII case-insensitive contains over a trimmed haystack.
      { fn: "matches", args: [{ t: "bytes", v: [0x20, 0x48, 0x65, 0x4c, 0x6c, 0x4f, 0x20] }, { t: "bytes", v: [0x65, 0x6c, 0x6c] }] },
      { fn: "matches", args: [{ t: "bytes", v: [0x20, 0x48, 0x65, 0x4c, 0x6c, 0x4f, 0x20] }, { t: "bytes", v: [0x7a] }] },
      // Cross-file const + helper, and a cross-file byte scan.
      { fn: "stepped", args: [i(5)] },
      { fn: "pivot", args: [{ t: "bytes", v: [0x61, 0x62, 0x2c, 0x63] }] },
      { fn: "pivot", args: [{ t: "bytes", v: [0x61, 0x62] }] },
    ],
  },
  {
    name: "do-while runs its body before the first test; continue jumps to the test",
    src: `
export function runsOnce(n: number): number {
  let i = 0;
  let total = 0;
  do { total += 1; i += 1; } while (i < n);
  return total;
}
export function evenHits(limit: number): number {
  let m = 0;
  let hits = 0;
  do {
    m += 1;
    if (m % 2 === 1) continue;
    hits += 1;
  } while (m < limit);
  return hits;
}
export function drains(xs: Uint8Array): number {
  let idx = 0;
  let total = 0;
  do {
    if (idx >= xs.length) break;
    total += xs[idx];
    idx += 1;
  } while (true);
  return total;
}`,
    calls: [
      { fn: "runsOnce", args: [i(0)] }, // body-first: runs once even when the test is false
      { fn: "runsOnce", args: [i(3)] },
      { fn: "evenHits", args: [i(5)] },
      { fn: "evenHits", args: [i(0)] },
      { fn: "drains", args: [{ t: "bytes", v: [3, 4, 5] }] },
      { fn: "drains", args: [{ t: "bytes", v: [] }] },
    ],
  },
  {
    name: "labeled continue re-enters the labeled loop; labeled break exits it; labeled blocks break forward",
    src: `
export function grid(): number {
  let acc = 0;
  outer: for (let i = 0; i < 3; i++) {
    for (let j = 0; j < 3; j++) {
      if (j === 1) continue outer;
      acc += i * 10 + j;
    }
  }
  return acc;
}
export function firstPair(xs: Uint8Array, ys: Uint8Array, want: number): number {
  let found = -1;
  scan: for (const x of xs) {
    for (const y of ys) {
      if (x + y === want) { found = x * 100 + y; break scan; }
    }
  }
  return found;
}
export function gated(b: boolean): number {
  let acc = 0;
  work: {
    acc += 1;
    if (b) break work;
    acc += 10;
  }
  return acc;
}
export function labeledWhile(n: number): number {
  let m = 0;
  let spins = 0;
  pump: while (spins < 50) {
    spins += 1;
    if (m >= n) break pump;
    m += 2;
    continue pump;
  }
  return m + spins;
}`,
    calls: [
      { fn: "grid", args: [] },
      { fn: "firstPair", args: [{ t: "bytes", v: [1, 2, 3] }, { t: "bytes", v: [7, 5] }, i(8)] },
      { fn: "firstPair", args: [{ t: "bytes", v: [1, 2] }, { t: "bytes", v: [1] }, i(99)] },
      { fn: "gated", args: [{ t: "b", v: true }] },
      { fn: "gated", args: [{ t: "b", v: false }] },
      { fn: "labeledWhile", args: [i(5)] },
      { fn: "labeledWhile", args: [i(0)] },
    ],
  },
  {
    name: "** matches JS pow exactly: right-associativity, the NaN-exponent and +-1**Infinity corners, fractional results",
    src: `
export function pow(a: number, b: number): number { return a ** b; }
export function towers(): number { return 2 ** 3 ** 2; }
export function squared(x: number): number { let v = x; v **= 2; return v; }`,
    calls: [
      { fn: "pow", args: [f(3), f(4)] },
      { fn: "pow", args: [f(2), f(-2)] }, // 0.25 — float always
      { fn: "pow", args: [f(1), f("nan")] }, // JS: NaN (libm says 1)
      { fn: "pow", args: [f("nan"), f(0)] }, // JS: 1
      { fn: "pow", args: [f(1), f("inf")] }, // JS: NaN
      { fn: "pow", args: [f(-1), f("-inf")] }, // JS: NaN
      { fn: "pow", args: [f(0), f(-1)] }, // Infinity
      { fn: "pow", args: [f("-0"), f(-1)] }, // -Infinity
      { fn: "pow", args: [f(-2), f(0.5)] }, // NaN
      { fn: "pow", args: [f(-2), f(3)] }, // -8
      { fn: "towers", args: [] }, // 512, not 64
      { fn: "squared", args: [f(3)] },
      { fn: "squared", args: [f(-0.5)] },
    ],
  },
  {
    name: "shifts wrap to 32 bits with the count masked, >>> is unsigned, ~ is ToInt32 not",
    src: `
export function shl(a: number, b: number): number {
  let x = 0; let n = 0;
  x = a | 0; n = b | 0;
  return x << n;
}
export function shr(a: number, b: number): number {
  let x = 0; let n = 0;
  x = a | 0; n = b | 0;
  return x >> n;
}
export function ushr(a: number, b: number): number {
  let x = 0; let n = 0;
  x = a | 0; n = b | 0;
  return x >>> n;
}
export function bitNot(a: number): number {
  let x = 0;
  x = a | 0;
  return ~x;
}
export function shiftCompound(a: number): number {
  let v = 0;
  v = a | 0;
  v <<= 3;
  v >>= 1;
  v >>>= 1;
  return v;
}`,
    calls: [
      { fn: "shl", args: [i(1), i(35)] }, // count masked & 31 -> 8
      { fn: "shl", args: [i(5), i(31)] }, // wraps to -2147483648
      { fn: "shl", args: [i(5), i(-1)] }, // count -1 & 31 = 31
      { fn: "shr", args: [i(-9), i(1)] }, // arithmetic: -5
      { fn: "ushr", args: [i(-1), i(0)] }, // 4294967295
      { fn: "ushr", args: [i(-9), i(1)] }, // 2147483643
      { fn: "bitNot", args: [i(5)] }, // -6
      { fn: "bitNot", args: [i(-1)] }, // 0
      { fn: "shiftCompound", args: [i(-3)] },
      { fn: "shiftCompound", args: [i(1000)] },
    ],
  },
  {
    name: "compound assignments equal their x = x op v spellings; logical forms guard the assignment",
    src: `
export function arith(a: number): number {
  let v = a;
  v *= 3;
  v -= 1;
  v %= 7;
  return v;
}
export function floaty(a: number): number {
  let v = a;
  v /= 4;
  v *= 0.5;
  return v;
}
export function bitwise(a: number): number {
  let v = 0;
  v = a | 0;
  v &= 255;
  v |= 16;
  v ^= 3;
  return v;
}
export function logicals(a: boolean, b: boolean): boolean {
  let x = a;
  x &&= b;
  x ||= !b;
  return x;
}
export function nullish(n: number | null): number {
  let v = n;
  v ??= 42;
  return v ?? -1;
}`,
    calls: [
      { fn: "arith", args: [f(6)] },
      { fn: "arith", args: [f(-6)] }, // (-17) % 7 = -3 (truncated, keeps sign)
      { fn: "floaty", args: [f(3)] }, // 0.375
      { fn: "floaty", args: [f("-0")] }, // -0 preserved
      { fn: "bitwise", args: [i(300)] },
      { fn: "bitwise", args: [i(-2)] },
      { fn: "logicals", args: [{ t: "b", v: true }, { t: "b", v: false }] },
      { fn: "logicals", args: [{ t: "b", v: false }, { t: "b", v: true }] },
      { fn: "logicals", args: [{ t: "b", v: true }, { t: "b", v: true }] },
      { fn: "nullish", args: [{ t: "null" }] },
      { fn: "nullish", args: [f(7)] },
      { fn: "nullish", args: [f(0)] }, // 0 is NOT nullish: stays 0
    ],
  },
  {
    name: "a default arm on a union-kind switch matches exactly the uncovered kinds",
    src: `
export type Msg =
  | { readonly kind: "add"; readonly v: number }
  | { readonly kind: "sub"; readonly v: number }
  | { readonly kind: "reset" }
  | { readonly kind: "noop" };
export function apply(sel: number, v: number, acc: number): number {
  const msg: Msg =
    sel === 0 ? { kind: "add", v: v } : sel === 1 ? { kind: "sub", v: v } : sel === 2 ? { kind: "reset" } : { kind: "noop" };
  switch (msg.kind) {
    case "add": return acc + msg.v;
    default: return -1000;
  }
}
function pickSmall(sel: number): Msg {
  return sel === 0 ? { kind: "reset" } : { kind: "noop" };
}
export function applyCovered(sel: number, acc: number): number {
  const msg = pickSmall(sel);
  // Every kind written out plus a default: the default is JS dead code.
  switch (msg.kind) {
    case "add": return acc + 1;
    case "sub": return acc - 1;
    case "reset": return 0;
    case "noop": return acc;
    default: return -1000;
  }
}`,
    calls: [
      { fn: "apply", args: [i(0), f(5), f(10)] },
      { fn: "apply", args: [i(1), f(5), f(10)] },
      { fn: "apply", args: [i(2), f(5), f(10)] },
      { fn: "apply", args: [i(3), f(5), f(10)] },
      { fn: "applyCovered", args: [i(0), f(9)] },
      { fn: "applyCovered", args: [i(1), f(9)] },
    ],
  },
  {
    name: "multi-declaration for-inits and comma incrementors step every counter per iteration",
    src: `
export function meet(n: number): number {
  let acc = 0;
  for (let lo = 0, hi = n; lo < hi; lo++, hi--) {
    acc += 1;
  }
  return acc;
}
export function weave(xs: Uint8Array): number {
  let sum = 0;
  for (let a = 0, b = xs.length - 1; a < b; a += 1, b -= 1) {
    sum += xs[a] * 10 + xs[b];
  }
  return sum;
}
export function countdown(n: number): number {
  let acc = 0;
  for (let i = n; i > 0; i--) acc += i;
  return acc;
}`,
    calls: [
      { fn: "meet", args: [i(6)] },
      { fn: "meet", args: [i(7)] },
      { fn: "meet", args: [i(0)] },
      { fn: "weave", args: [{ t: "bytes", v: [1, 2, 3, 4] }] },
      { fn: "weave", args: [{ t: "bytes", v: [5] }] },
      { fn: "countdown", args: [i(4)] },
      { fn: "countdown", args: [i(0)] },
    ],
  },
  {
    name: "const record destructuring aliases fields exactly (renames, bytes, optionals, float classes)",
    src: `
export interface Stats {
  readonly total: number;
  readonly done: number;
  readonly ratio: number;
  readonly label: Uint8Array;
  readonly last: number | null;
}
function build(total: number, done: number, ratio: number, label: Uint8Array, last: number | null): Stats {
  return { total: total, done: done, ratio: ratio, label: label, last: last };
}
export function summary(total: number, done: number, ratio: number, label: Uint8Array, last: number | null): number {
  const stats = build(total, done, ratio, label, last);
  const { total: totalCount, done: doneCount, ratio: r, last: l } = stats;
  if (totalCount === 0) return -1;
  return doneCount + r * 2 + (l ?? 0) * 100 + totalCount;
}
export function tagByte(label: Uint8Array): number {
  const stats = build(1, 0, 0, label, null);
  const { label: tag } = stats;
  if (tag.length === 0) return -1;
  return tag[0];
}`,
    calls: [
      { fn: "summary", args: [f(4), f(2), f(0.25), { t: "bytes", v: [7] }, f(3)] },
      { fn: "summary", args: [f(0), f(2), f(0.25), { t: "bytes", v: [7] }, { t: "null" }] },
      { fn: "summary", args: [f(4), f(2), f(0.25), { t: "bytes", v: [7] }, { t: "null" }] },
      { fn: "tagByte", args: [{ t: "bytes", v: [65, 66] }] },
      { fn: "tagByte", args: [{ t: "bytes", v: [] }] },
    ],
  },
  {
    name: "unary plus is the identity on numbers (NaN and -0 included); ; is a no-op",
    src: `
export function idPlus(x: number): number { return +x; }
export function stepped(x: number): number { ; let v = +x + 1; ; return v; }`,
    calls: [
      { fn: "idPlus", args: [f(5)] },
      { fn: "idPlus", args: [f("nan")] },
      { fn: "idPlus", args: [f("-0")] },
      { fn: "idPlus", args: [f("-inf")] },
      { fn: "stepped", args: [f(2.5)] },
    ],
  },
  {
    name: "namespace imports alias the target module exactly: values, calls, and qualified types",
    files: {
      "util.ts": `
export interface Cfg { readonly step: number; readonly scale: number; }
export const SEED = 7;
export function bump(n: number, c: Cfg): number { return n + c.step * c.scale; }
export function half(x: number): number { return x / 2; }`,
    },
    src: `
import * as util from "./util.ts";
export function seeded(): number { return util.SEED; }
export function stepped(n: number): number {
  const cfg: util.Cfg = { step: 2, scale: 3 };
  return util.bump(n, cfg);
}
export function halved(x: number): number { return util.half(x); }`,
    calls: [
      { fn: "seeded", args: [] },
      { fn: "stepped", args: [f(10)] },
      { fn: "halved", args: [f(5)] }, // 2.5 — the float class crosses the alias
      { fn: "halved", args: [f("-0")] },
    ],
  },
  {
    name: "entries loop: [i, x] pair over arrays and bytes (index and element agree with node)",
    src: `
export function weighted(xs: readonly number[]): number {
  let t = 0;
  for (const [i, x] of xs.entries()) { t += (i + 1) * x; }
  return t;
}
export function firstMatchIndex(bs: Uint8Array, want: number): number {
  for (const [i, b] of bs.entries()) { if (b === want) return i; }
  return -1;
}
`,
    calls: [
      { fn: "weighted", args: [{ t: "nums", v: [2, 3.5, "-0"] }] },
      { fn: "weighted", args: [{ t: "nums", v: [] }] },
      { fn: "firstMatchIndex", args: [{ t: "bytes", v: [9, 4, 4] }, i(4)] },
      { fn: "firstMatchIndex", args: [{ t: "bytes", v: [9] }, i(4)] },
    ],
  },
  {
    name: "steps in value position: arr[i++] scan order, pre-step value, assignment value",
    src: `
export function everyOther(bs: Uint8Array): number {
  let i = 0;
  let t = 0;
  while (i < bs.length) { t = t * 100 + bs[i++]; i++; }
  return t;
}
export function preStep(): number {
  let count = 4;
  const n = ++count;
  return n * 10 + count;
}
export function assignValue(x: number): number {
  let y = 0;
  const z = (y = x);
  const w = (y += 2);
  return z + w * 1000 + y;
}
`,
    calls: [
      { fn: "everyOther", args: [{ t: "bytes", v: [1, 2, 3, 4, 5] }] },
      { fn: "everyOther", args: [{ t: "bytes", v: [] }] },
      { fn: "preStep", args: [] },
      { fn: "assignValue", args: [f(7)] },
      { fn: "assignValue", args: [f("-0")] },
    ],
  },
  {
    name: "optional chains: element hops, method hops, and the ?? fold",
    src: `
export interface M { readonly xs: Uint8Array; }
export function firstByte(m: M | null): number { return m?.xs[0] ?? -1; }
export function second(xs: readonly number[] | null): number { return xs?.[1] ?? -1; }
export function hasThree(xs: readonly number[] | null): boolean { return xs?.includes(3) ?? false; }
export function windowLen(xs: readonly number[] | null): number {
  const w = xs?.slice(1, 9);
  if (w === undefined) return -1;
  return w.length;
}
`,
    node: `
line("m_hit", mod.firstByte({ xs: Uint8Array.from([7, 8]) }));
line("m_null", mod.firstByte(null));
line("el_hit", mod.second([4, 5, 6]));
line("el_null", mod.second(null));
line("inc_hit", mod.hasThree([1, 3]));
line("inc_null", mod.hasThree(null));
line("win_hit", mod.windowLen([1, 2, 3]));
line("win_null", mod.windowLen(null));
`,
    zig: `
row("m_hit", m.firstByte(.{ .xs = &[_]u8{ 7, 8 } }));
row("m_null", m.firstByte(null));
row("el_hit", m.second(&[_]f64{ 4, 5, 6 }));
row("el_null", m.second(null));
row("inc_hit", m.hasThree(&[_]f64{ 1, 3 }));
row("inc_null", m.hasThree(null));
row("win_hit", m.windowLen(&[_]f64{ 1, 2, 3 }));
row("win_null", m.windowLen(null));
`,
  },
  {
    name: "plain switch: strict equality, case order, mid-position default, gaps",
    src: `
export function grade(n: number): number {
  switch (n) {
    case 1: return 10;
    default: return -1;
    case 2:
    case 3: return 23;
  }
}
export function gapped(n: number): number {
  let out = 0;
  switch (n) {
    case 5: out = 50; break;
    case 6: out = 60; break;
  }
  return out;
}
export function tagOf(s: string): number {
  switch (s) { case "a": return 1; case "b": return 2; default: return 0; }
}
`,
    calls: [
      { fn: "grade", args: [f(1)] },
      { fn: "grade", args: [f(2)] },
      { fn: "grade", args: [f(3)] },
      { fn: "grade", args: [f(9)] },
      { fn: "grade", args: [f("nan")] },
      { fn: "grade", args: [f("-0")] },
      { fn: "grade", args: [f(2.5)] },
      { fn: "gapped", args: [f(5)] },
      { fn: "gapped", args: [f(7)] },
      { fn: "tagOf", args: [{ t: "str", v: "b" }] },
      { fn: "tagOf", args: [{ t: "str", v: "zz" }] },
    ],
  },
  {
    name: "generics: monomorphized helpers behave identically under node (records, optionals, floats, recursion)",
    src: `
export interface Task { readonly id: number; readonly done: boolean; }
export function pick<T>(xs: readonly T[], idx: number): T { return xs[idx]; }
export function first<T>(xs: readonly T[]): T | null {
  return xs.length > 0 ? pick(xs, 0) : null;
}
export function sizeAfter<T>(xs: readonly T[], drop: number): number {
  if (drop <= 0) return xs.length;
  return sizeAfter(xs.slice(1), drop - 1);
}
export function lastNum(xs: readonly number[]): number { return pick(xs, xs.length - 1); }
export function firstDoneId(tasks: readonly Task[]): number {
  const t = first(tasks);
  if (t === null) return -1;
  return t.done ? t.id : -2;
}
export function shrink(xs: readonly number[], n2: number): number { return sizeAfter(xs, n2); }
`,
    node: `
line("last", mod.lastNum([2, 3.5]));
line("last_neg0", mod.lastNum([1, -0]));
line("done", mod.firstDoneId([{ id: 4, done: true }]));
line("not_done", mod.firstDoneId([{ id: 4, done: false }]));
line("empty", mod.firstDoneId([]));
line("shrunk", mod.shrink([9, 9, 9, 9], 3));
`,
    zig: `
row("last", m.lastNum(&[_]f64{ 2, 3.5 }));
row("last_neg0", m.lastNum(&[_]f64{ 1, -0.0 }));
row("done", m.firstDoneId(&[_]m.Task{.{ .id = 4, .done = true }}));
row("not_done", m.firstDoneId(&[_]m.Task{.{ .id = 4, .done = false }}));
row("empty", m.firstDoneId(&[_]m.Task{}));
row("shrunk", m.shrink(&[_]f64{ 9, 9, 9, 9 }, 3));
`,
  },
  {
    name: "local function values: hoisted helpers by direct call, callback pass, and recursion",
    src: `
export function scaled(xs: readonly number[]): readonly number[] {
  const triple = (x: number): number => x * 3;
  return xs.map(triple);
}
export function factorial(n: number): number {
  const fact = (v: number): number => v <= 1 ? 1 : v * fact(v - 1);
  return fact(n);
}
export function applyTwice(x: number): number {
  const bump = (v: number): number => v + 1.5;
  return bump(bump(x));
}
`,
    calls: [
      { fn: "scaled", args: [{ t: "nums", v: [1, 2.5] }] },
      { fn: "factorial", args: [f(5)] },
      { fn: "factorial", args: [f(0)] },
      { fn: "applyTwice", args: [f("-0")] },
      { fn: "applyTwice", args: [f("nan")] },
    ],
  },
  {
    name: "arrays of byte buffers: push-built parts concatenate byte-identically",
    src: `
export function concatAll(parts: readonly Uint8Array[]): Uint8Array {
  let total = 0;
  for (const p of parts) total += p.length;
  const out = new Uint8Array(total);
  let off = 0;
  for (const p of parts) { out.set(p, off); off += p.length; }
  return out;
}
export function joined(a: Uint8Array, b: Uint8Array): Uint8Array {
  const parts: Uint8Array[] = [];
  parts.push(a);
  parts.push(b);
  return concatAll(parts);
}
`,
    calls: [
      { fn: "joined", args: [{ t: "bytes", v: [1, 2] }, { t: "bytes", v: [3, 4, 5] }] },
      { fn: "joined", args: [{ t: "bytes", v: [] }, { t: "bytes", v: [7] }] },
      { fn: "joined", args: [{ t: "bytes", v: [] }, { t: "bytes", v: [] }] },
    ],
  },
  {
    name: "bare function references: map/filter/reduce/toSorted callbacks match the arrow forms",
    src: `
function double(n: number): number { return n * 2; }
function isPositive(n: number): boolean { return n > 0; }
function add(a: number, b: number): number { return a + b; }
function byAscending(a: number, b: number): number { return a - b; }
export function total(xs: readonly number[]): number {
  return xs.map(double).filter(isPositive).reduce(add, 0);
}
export function sorted(xs: readonly number[]): readonly number[] {
  return xs.toSorted(byAscending);
}
`,
    calls: [
      { fn: "total", args: [{ t: "nums", v: [1.5, -2, 3] }] },
      { fn: "total", args: [{ t: "nums", v: [] }] },
      { fn: "sorted", args: [{ t: "nums", v: [3, "-0", 1.25, 2] }] },
      { fn: "sorted", args: [{ t: "nums", v: [] }] },
    ],
  },
  {
    name: "data classes: constructor defaults, mutating methods, field reads match node",
    src: `
export class Counter {
  count: number = 0;
  step: number;
  constructor(step: number) { this.step = step; }
  bump(): void { this.count += this.step; }
  scaled(by: number): number { return this.count * by; }
}
export class Accumulator {
  values: readonly number[] = [];
  push(v: number): void { this.values = [...this.values, v]; }
  total(): number {
    let sum = 0;
    for (const v of this.values) sum += v;
    return sum;
  }
}
export function run(step: number, times: number): number {
  const c = new Counter(step);
  for (let i = 0; i < times; i++) c.bump();
  return c.scaled(2);
}
export function accumulate(xs: readonly number[]): number {
  const a = new Accumulator();
  for (const x of xs) a.push(x);
  return a.total();
}
export function direct(seed: number): number {
  const c = new Counter(seed);
  c.count = 10;
  c.count += seed;
  return c.count;
}
`,
    calls: [
      { fn: "run", args: [f(2.5), i(3)] },
      { fn: "run", args: [i(4), i(0)] },
      { fn: "accumulate", args: [{ t: "nums", v: [1.25, -2, "-0"] }] },
      { fn: "accumulate", args: [{ t: "nums", v: [] }] },
      { fn: "direct", args: [f(0.5)] },
      { fn: "direct", args: [i(7)] },
    ],
  },
  {
    name: "exceptions: parser throw/catch/narrow chain matches node byte for byte",
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
    calls: [
      { fn: "safeParse", args: [{ t: "bytes", v: [49, 50, 51] }] },
      { fn: "safeParse", args: [{ t: "bytes", v: [49, 65, 51] }] },
      { fn: "safeParse", args: [{ t: "bytes", v: [65] }] },
      { fn: "safeParse", args: [{ t: "bytes", v: [] }] },
    ],
  },
  {
    name: "exceptions: a throw inside a map callback unwinds out of the lowered loop",
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
    calls: [
      { fn: "firstBad", args: [{ t: "nums", v: [1, 2, -3, 4] }] },
      { fn: "firstBad", args: [{ t: "nums", v: [-1] }] },
      { fn: "firstBad", args: [{ t: "nums", v: [1, 2] }] },
      { fn: "firstBad", args: [{ t: "nums", v: [] }] },
    ],
  },
  {
    name: "exceptions: rethrow, nested try, and finally ordering match node",
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
    calls: [
      { fn: "f", args: [f(3)] },
      { fn: "f", args: [f(9)] },
      { fn: "f", args: [f(-1)] },
      { fn: "f", args: [f(0.5)] },
    ],
  },
  {
    name: "exceptions: try/finally interleaves with loop break and continue like node",
    src: `
export type Never2 = { readonly kind: "never" } | { readonly kind: "either" };
export function loopLog(n: number): number {
  let log = 0;
  for (let i = 0; i < n; i++) {
    try {
      if (i === 1) continue;
      if (i === 3) break;
      log = log * 10 + 1;
    } finally {
      log = log * 10 + 2;
    }
  }
  return log;
}
export function sumUntilNeg(xs: readonly number[]): number {
  let sum = 0;
  try {
    for (const x of xs) {
      if (x < 0) throw { kind: "never" } as Never2;
      sum += x;
    }
    return sum;
  } catch {
    return -sum;
  }
}
`,
    calls: [
      { fn: "loopLog", args: [i(0)] },
      { fn: "loopLog", args: [i(1)] },
      { fn: "loopLog", args: [i(2)] },
      { fn: "loopLog", args: [i(6)] },
      { fn: "sumUntilNeg", args: [{ t: "nums", v: [1, 2.5, -1, 4] }] },
      { fn: "sumUntilNeg", args: [{ t: "nums", v: [1, 2] }] },
    ],
  },
  {
    name: "exceptions: a throw mid-mutation keeps the owned array's prior state (node parity)",
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
    calls: [
      { fn: "f", args: [i(2)] },
      { fn: "f", args: [i(1)] },
      { fn: "f", args: [i(5)] },
    ],
  },
  {
    name: "exceptions: class constructors and methods throw like node",
    src: `
export type Range2 = { readonly kind: "range"; readonly v: number } | { readonly kind: "none" };
export class Gauge {
  v: number;
  constructor(v: number) {
    if (v < 0) throw { kind: "range", v } as Range2;
    this.v = v;
  }
  add(d: number): void {
    if (this.v + d > 100) throw { kind: "range", v: this.v + d } as Range2;
    this.v += d;
  }
}
export function run(start: number, d: number): number {
  try {
    const g = new Gauge(start);
    g.add(d);
    return g.v;
  } catch (e) {
    const err = e as Range2;
    return err.kind === "range" ? -err.v : -1;
  }
}
`,
    calls: [
      { fn: "run", args: [f(10), f(5.5)] },
      { fn: "run", args: [f(-2), f(0)] },
      { fn: "run", args: [f(60), f(50)] },
    ],
  },
  {
    name: "exceptions: number-shaped throws ride the f64 payload slot",
    src: `
export function g(x: number): number {
  try {
    if (x > 5) throw x * 2;
    return x;
  } catch (e) {
    const n = e as number;
    return n + 0.5;
  }
}
`,
    calls: [
      { fn: "g", args: [f(1.5)] },
      { fn: "g", args: [f(6)] },
      { fn: "g", args: [f(7.25)] },
    ],
  },
  {
    name: "exceptions: switch-case throws, try inside callbacks, labeled-loop throws",
    src: `
export type E = { readonly kind: "bad" } | { readonly kind: "stop" };
export function viaSwitch(n: number): number {
  try {
    switch (n) {
      case 1: throw { kind: "bad" } as E;
      case 2: return 20;
      default: return 0;
    }
  } catch { return -1; }
}
function classify(x: number): number {
  if (x < 0) throw { kind: "bad" } as E;
  return x * 2;
}
export function mapWithLocalCatch(xs: readonly number[]): readonly number[] {
  return xs.map((x) => {
    try {
      return classify(x);
    } catch {
      return -1;
    }
  });
}
export function labeled(n: number): number {
  let acc = 0;
  try {
    outer: for (let i = 0; i < n; i++) {
      for (let j = 0; j < 3; j++) {
        if (i + j === 4) throw { kind: "stop" } as E;
        if (j === 2) continue outer;
        acc += 1;
      }
    }
    return acc;
  } catch {
    return -acc;
  }
}
`,
    calls: [
      { fn: "viaSwitch", args: [i(1)] },
      { fn: "viaSwitch", args: [i(2)] },
      { fn: "viaSwitch", args: [i(9)] },
      { fn: "mapWithLocalCatch", args: [{ t: "nums", v: [1, -2, 3.5] }] },
      { fn: "mapWithLocalCatch", args: [{ t: "nums", v: [] }] },
      { fn: "labeled", args: [i(2)] },
      { fn: "labeled", args: [i(6)] },
      { fn: "labeled", args: [i(0)] },
    ],
  },
  {
    name: "export lists and value re-exports: renamed bindings and a re-export chain agree with node",
    src: `
import { bump } from "./api.ts";
function tripled(n: number): number { return n * 3; }
export { tripled as thrice };
export { bump } from "./api.ts";
export { OFFSET as BASE } from "./api.ts";
export function combined(n: number): number { return bump(n) + tripled(n); }
`,
    files: {
      "api.ts": `
export { bump, OFFSET } from "./impl.ts";
`,
      "impl.ts": `
export const OFFSET = 40;
export function bump(n: number): number { return n + OFFSET; }
`,
    },
    calls: [
      { fn: "combined", args: [i(5)] },
      { fn: "combined", args: [i(-3)] },
      { fn: "thrice", args: [i(7)] },
      { fn: "bump", args: [i(2)] },
    ],
  },
  {
    name: "an export-list entry function's number params stay host-boundary f64",
    // The un-renamed list spelling puts the declaration on the entry's
    // host surface exactly like the inline modifier, so a `=== 0`
    // comparison against an all-integer body must never int-claim the
    // parameter: the host passes fractional f64s there (an i64 signature
    // would not even accept the driver's 0.25).
    src: `
function scaledOr1(n: number): number { return n === 0 ? -1 : n * 4; }
export { scaledOr1 };
`,
    calls: [
      { fn: "scaledOr1", args: [f(0.25)] },
      { fn: "scaledOr1", args: [f(0.3)] },
      { fn: "scaledOr1", args: [f(0)] },
      { fn: "scaledOr1", args: [f("-0")] },
    ],
  },
  {
    name: "heterogeneous throws: the thrown union narrows by kind in the catch, chains and callbacks included",
    src: `
export interface ParseError { readonly kind: "parse"; readonly at: number; }
export interface IoError { readonly kind: "io"; readonly code: number; readonly hard: boolean; }
export type Low = { readonly kind: "under"; readonly by: number } | { readonly kind: "zero" };
function inner(n: number): number {
  if (n < 0) throw { kind: "parse", at: n } as ParseError;
  if (n > 100) throw { kind: "io", code: n, hard: n > 1000 } as IoError;
  return n * 2;
}
function middle(n: number): number {
  // A throw two frames down unwinds through this one untouched.
  return inner(n) + 1;
}
export function catches(n: number): number {
  try {
    return middle(n);
  } catch (e) {
    if (e.kind === "parse") return e.at - 1000;
    if (e.kind === "io") return e.hard ? -e.code : e.code;
    return -1;
  }
}
export function viaSwitchAndUnion(n: number): number {
  try {
    if (n < 0) { const low: Low = n === -1 ? { kind: "zero" } : { kind: "under", by: n }; throw low; }
    return inner(n);
  } catch (e) {
    switch (e.kind) {
      case "under": return e.by - 100;
      case "zero": return -7;
      case "io": return e.code + 5;
      default: return -2;
    }
  }
}
export function callbackThrows(xs: readonly number[]): number {
  try {
    const doubled = xs.map((x) => {
      if (x < 0) throw { kind: "parse", at: x } as ParseError;
      if (x > 100) throw { kind: "io", code: x, hard: false } as IoError;
      return x * 2;
    });
    return doubled.length;
  } catch (e) {
    if (e.kind === "parse") return e.at;
    if (e.kind === "io") return e.code + 900;
    return -3;
  }
}
export function narrowedInCallback(xs: readonly number[], n: number): number {
  try {
    return inner(n);
  } catch (e) {
    if (e.kind === "io") {
      // The narrowed arm's payload read inside an inline callback.
      return xs.filter((x) => x > e.code).length;
    }
    return -4;
  }
}
export function rethrowNarrowed(n: number): number {
  try {
    try {
      return inner(n);
    } catch (e) {
      if (e.kind === "io") throw e; // rethrow of a narrowed arm re-raises the bound value
      return -5;
    }
  } catch (e2) {
    if (e2.kind === "io") return e2.hard ? e2.code + 7000 : e2.code + 70;
    return -9;
  }
}
`,
    calls: [
      { fn: "catches", args: [i(4)] },
      { fn: "catches", args: [i(-6)] },
      { fn: "catches", args: [i(300)] },
      { fn: "catches", args: [i(3000)] },
      { fn: "viaSwitchAndUnion", args: [i(5)] },
      { fn: "viaSwitchAndUnion", args: [i(-1)] },
      { fn: "viaSwitchAndUnion", args: [i(-8)] },
      { fn: "viaSwitchAndUnion", args: [i(200)] },
      { fn: "callbackThrows", args: [{ t: "nums", v: [1, 2, 3] }] },
      { fn: "callbackThrows", args: [{ t: "nums", v: [1, -4, 3] }] },
      { fn: "callbackThrows", args: [{ t: "nums", v: [1, 400, -2] }] },
      { fn: "narrowedInCallback", args: [{ t: "nums", v: [50, 150, 250] }, i(120)] },
      { fn: "narrowedInCallback", args: [{ t: "nums", v: [50, 150, 250] }, i(7)] },
      { fn: "rethrowNarrowed", args: [i(6)] },
      { fn: "rethrowNarrowed", args: [i(-2)] },
      { fn: "rethrowNarrowed", args: [i(500)] },
      { fn: "rethrowNarrowed", args: [i(5000)] },
    ],
  },
  {
    name: "class statics: static methods and consts behave identically under node and native",
    src: `
export class Gauge {
  reading: number;
  static readonly CEILING = 100;
  static readonly FLOOR = -10;
  constructor(reading: number) { this.reading = reading; }
  static clamp(v: number): number {
    if (v > Gauge.CEILING) return Gauge.CEILING;
    if (v < Gauge.FLOOR) return Gauge.FLOOR;
    return v;
  }
  static span(): number { return Gauge.CEILING - Gauge.FLOOR; }
  private normalized(): number { return Gauge.clamp(this.reading); }
  read(): number { return this.normalized(); }
}
export function measure(v: number): number {
  const g = new Gauge(v);
  return g.read() + Gauge.span();
}
export function clamped(v: number): number {
  return Gauge.clamp(v);
}
`,
    calls: [
      { fn: "measure", args: [i(50)] },
      { fn: "measure", args: [i(500)] },
      { fn: "measure", args: [i(-50)] },
      { fn: "clamped", args: [f(99.5)] },
      { fn: "clamped", args: [f("nan")] },
    ],
  },
  {
    name: "mutation loosenings: append writes, reassigned owning bindings, and readonly borrows match node",
    src: `
function total(xs: readonly number[]): number {
  let t = 0;
  for (const x of xs) { t += x; }
  return t;
}
function spread(xs: readonly number[]): number {
  // A borrowed slice read through nested borrowing calls.
  return total(xs) - xs.length;
}
export function appends(xs: readonly number[]): readonly number[] {
  const out: number[] = [];
  for (const x of xs) {
    if (x >= 0) out[out.length] = x * 2;
    else out.push(-x);
  }
  out[out.length] = total(out);
  return out;
}
export function rebuilt(xs: readonly number[], flip: boolean): readonly number[] {
  let w = xs.slice();
  w.push(100);
  if (flip) {
    w = xs.filter((x) => x > 0);
    w.push(200);
  }
  w.sort((a, b) => a - b);
  return w;
}
export function resetToEmpty(n: number): number {
  let acc: number[] = [n, n + 1];
  acc.push(n + 2);
  acc = [];
  acc.push(n * 10);
  return acc.length * 1000 + acc[0];
}
export function borrowed(n: number): number {
  const out: number[] = [n];
  const before = spread(out);
  out.push(n + 1);
  out[out.length] = n + 2;
  const mid = total(out);
  out.push(n + 3);
  return before + mid + total(out);
}
`,
    calls: [
      { fn: "appends", args: [{ t: "nums", v: [1, -2, 3] }] },
      { fn: "appends", args: [{ t: "nums", v: [] }] },
      { fn: "rebuilt", args: [{ t: "nums", v: [3, -1, 2] }, { t: "b", v: true }] },
      { fn: "rebuilt", args: [{ t: "nums", v: [3, -1, 2] }, { t: "b", v: false }] },
      { fn: "resetToEmpty", args: [i(4)] },
      { fn: "borrowed", args: [i(5)] },
      { fn: "borrowed", args: [i(-7)] },
    ],
  },
  {
    name: "byte text: simple case mapping is byte-identical (ASCII, Greek, Cyrillic, growth, invalid passthrough)",
    src: `
export function up(s: Uint8Array): Uint8Array { return s.toUpperCase(); }
export function low(s: Uint8Array): Uint8Array { return s.toLowerCase(); }
export function roundTrip(s: Uint8Array): Uint8Array { return s.toUpperCase().toLowerCase(); }
`,
    calls: [
      { fn: "up", args: [{ t: "bytes", v: [104, 101, 108, 108, 111, 33] }] }, // "hello!"
      { fn: "up", args: [{ t: "bytes", v: [207, 131, 206, 175, 207, 131, 207, 133, 207, 134, 206, 191, 207, 130] }] }, // σίσυφος (final sigma)
      { fn: "low", args: [{ t: "bytes", v: [208, 159, 208, 160, 208, 152, 208, 146, 208, 149, 208, 162] }] }, // ПРИВЕТ
      { fn: "up", args: [{ t: "bytes", v: [115, 116, 114, 97, 195, 159, 101] }] }, // straße: ß has NO simple upper — stays ß
      { fn: "up", args: [{ t: "bytes", v: [197, 191] }] }, // ſ -> S (2 bytes -> 1)
      { fn: "up", args: [{ t: "bytes", v: [194, 181] }] }, // µ -> Μ (2 -> 2)
      { fn: "up", args: [{ t: "bytes", v: [200, 191] }] }, // ȿ U+023F -> U+2C7E (2 -> 3, growth)
      { fn: "up", args: [{ t: "bytes", v: [240, 144, 144, 168] }] }, // Deseret U+10428 -> U+10400 (4 -> 4)
      { fn: "up", args: [{ t: "bytes", v: [97, 255, 195] }] }, // invalid lead + truncated tail pass through
      { fn: "low", args: [{ t: "bytes", v: [224, 128, 97, 128, 65] }] }, // overlong lead, lone continuation
      { fn: "up", args: [{ t: "bytes", v: [237, 160, 128, 66] }] }, // surrogate encoding is invalid: passthrough
      { fn: "up", args: [{ t: "bytes", v: [] }] },
      { fn: "roundTrip", args: [{ t: "bytes", v: [206, 163, 206, 145, 206, 155] }] }, // ΣΑΛ -> σαλ (Σ lowers to σ, never final ς)
    ],
  },
  {
    name: "byte text: repeat edges and byte-honest padding (multi-byte fill truncates by bytes)",
    src: `
import { asciiBytes } from "@native-sdk/core";
export function rep(s: Uint8Array, n: number): Uint8Array { return s.repeat(n); }
export function padDefault(s: Uint8Array, n: number): Uint8Array { return s.padStart(n); }
export function padCustom(s: Uint8Array, n: number, fill: Uint8Array): Uint8Array { return s.padStart(n, fill); }
export function padEndCustom(s: Uint8Array, n: number, fill: Uint8Array): Uint8Array { return s.padEnd(n, fill); }
export function gauge(used: number): Uint8Array { return asciiBytes("#").repeat(used).padEnd(8, asciiBytes(".")); }
`,
    calls: [
      { fn: "rep", args: [{ t: "bytes", v: [97, 98] }, i(3)] },
      { fn: "rep", args: [{ t: "bytes", v: [97, 98] }, i(0)] },
      { fn: "rep", args: [{ t: "bytes", v: [] }, i(5)] },
      { fn: "rep", args: [{ t: "bytes", v: [195, 169] }, i(2)] }, // multi-byte é
      { fn: "padDefault", args: [{ t: "bytes", v: [97, 98] }, i(5)] },
      { fn: "padDefault", args: [{ t: "bytes", v: [97, 98] }, i(1)] }, // at/under target: unchanged
      { fn: "padDefault", args: [{ t: "bytes", v: [97, 98] }, i(-3)] }, // negative target: unchanged
      { fn: "padCustom", args: [{ t: "bytes", v: [97, 98] }, i(8), { t: "bytes", v: [120, 121] }] }, // xy fill truncates
      { fn: "padCustom", args: [{ t: "bytes", v: [97] }, i(4), { t: "bytes", v: [195, 169] }] }, // é fill cut MID-SEQUENCE at byte 3: byte-honest, identical both sides
      { fn: "padCustom", args: [{ t: "bytes", v: [97, 98] }, i(9), { t: "bytes", v: [] }] }, // empty fill: unchanged
      { fn: "padEndCustom", args: [{ t: "bytes", v: [97, 98] }, i(7), { t: "bytes", v: [46] }] },
      { fn: "padDefault", args: [{ t: "bytes", v: [195, 169] }, i(4)] }, // é is 2 BYTES: 2 pad bytes, not 3
      { fn: "gauge", args: [i(3)] },
    ],
  },
  {
    name: "byte text: search dispatches by argument type (bytes substring vs byte element)",
    src: `
export function starts(s: Uint8Array, t: Uint8Array): boolean { return s.startsWith(t); }
export function ends(s: Uint8Array, t: Uint8Array): boolean { return s.endsWith(t); }
export function hasSub(s: Uint8Array, t: Uint8Array): boolean { return s.includes(t); }
export function hasByte(s: Uint8Array, b: number): boolean { return s.includes(b); }
export function idxSub(s: Uint8Array, t: Uint8Array): number { return s.indexOf(t); }
export function idxByte(s: Uint8Array, b: number): number { return s.indexOf(b); }
export function lastSub(s: Uint8Array, t: Uint8Array): number { return s.lastIndexOf(t); }
export function lastByte(s: Uint8Array, b: number): number { return s.lastIndexOf(b); }
`,
    calls: [
      { fn: "starts", args: [{ t: "bytes", v: [97, 98, 99] }, { t: "bytes", v: [97, 98] }] },
      { fn: "starts", args: [{ t: "bytes", v: [97, 98, 99] }, { t: "bytes", v: [] }] }, // empty needle: true
      { fn: "starts", args: [{ t: "bytes", v: [97] }, { t: "bytes", v: [97, 98] }] }, // needle longer than hay
      { fn: "ends", args: [{ t: "bytes", v: [97, 98, 99] }, { t: "bytes", v: [98, 99] }] },
      { fn: "ends", args: [{ t: "bytes", v: [97, 98, 99] }, { t: "bytes", v: [] }] },
      { fn: "hasSub", args: [{ t: "bytes", v: [97, 88, 98, 88] }, { t: "bytes", v: [88, 98] }] },
      { fn: "hasSub", args: [{ t: "bytes", v: [97, 98] }, { t: "bytes", v: [99] }] },
      { fn: "hasByte", args: [{ t: "bytes", v: [65, 66, 67] }, i(66)] },
      { fn: "hasByte", args: [{ t: "bytes", v: [65, 66, 67] }, f(66.5)] }, // SameValueZero: no byte is 66.5
      { fn: "hasByte", args: [{ t: "bytes", v: [0, 1] }, f("-0")] }, // -0 matches 0
      { fn: "hasByte", args: [{ t: "bytes", v: [65] }, f("nan")] }, // NaN matches nothing
      { fn: "hasByte", args: [{ t: "bytes", v: [65] }, i(300)] }, // out of byte range
      { fn: "idxSub", args: [{ t: "bytes", v: [97, 88, 98, 88] }, { t: "bytes", v: [88] }] },
      { fn: "idxSub", args: [{ t: "bytes", v: [97, 98, 99] }, { t: "bytes", v: [] }] }, // empty: 0
      { fn: "idxSub", args: [{ t: "bytes", v: [97] }, { t: "bytes", v: [98] }] }, // missing: -1
      { fn: "idxByte", args: [{ t: "bytes", v: [65, 66, 67, 66] }, i(66)] },
      { fn: "lastSub", args: [{ t: "bytes", v: [97, 97, 97, 97] }, { t: "bytes", v: [97, 97] }] }, // overlap: 2
      { fn: "lastSub", args: [{ t: "bytes", v: [97, 98, 99] }, { t: "bytes", v: [] }] }, // empty: hay.length
      { fn: "lastByte", args: [{ t: "bytes", v: [65, 66, 67, 66] }, i(66)] },
      { fn: "lastByte", args: [{ t: "bytes", v: [65] }, i(90)] },
    ],
  },
  {
    name: "byte text: the trim family strips the JS whitespace set over UTF-8, views only",
    src: `
import { trimAsciiSpaces } from "@native-sdk/core/text";
export function t(s: Uint8Array): Uint8Array { return s.trim(); }
export function ts(s: Uint8Array): Uint8Array { return s.trimStart(); }
export function te(s: Uint8Array): Uint8Array { return s.trimEnd(); }
export function sdkDiff(s: Uint8Array): number {
  // Reconciliation pin: .trim() strips the JS set (\\n included); the SDK's
  // trimAsciiSpaces stays byte-exact ASCII (space/tab/CR, never LF).
  return s.trim().length * 100 + trimAsciiSpaces(s).length;
}
`,
    calls: [
      { fn: "t", args: [{ t: "bytes", v: [194, 160, 9, 32, 97, 32, 98, 32, 10, 227, 128, 128] }] }, // NBSP \t sp "a b" sp \n IDEOGRAPHIC SPACE
      { fn: "ts", args: [{ t: "bytes", v: [239, 187, 191, 97] }] }, // U+FEFF is JS whitespace
      { fn: "te", args: [{ t: "bytes", v: [97, 13, 10] }] },
      { fn: "t", args: [{ t: "bytes", v: [255, 32, 97, 32, 255] }] }, // invalid bytes stop the trim
      { fn: "t", args: [{ t: "bytes", v: [32, 32, 32] }] }, // all whitespace -> empty
      { fn: "t", args: [{ t: "bytes", v: [] }] },
      { fn: "sdkDiff", args: [{ t: "bytes", v: [32, 97, 10, 32] }] }, // " a\\n " -> trim 1, trimAsciiSpaces 2 ("a\\n")
    ],
  },
  {
    name: "byte text: split shapes, multi-byte separators, ownership of the parts array, and at()",
    src: `
import { asciiBytes } from "@native-sdk/core";
export function parts(s: Uint8Array, sep: Uint8Array): number { return s.split(sep).length; }
export function part(s: Uint8Array, sep: Uint8Array, i: number): Uint8Array {
  const xs = s.split(sep);
  return xs[i];
}
export function grown(s: Uint8Array): number {
  const xs = s.split(asciiBytes(","));
  xs.push(asciiBytes("tail"));
  let total = 0;
  for (const p of xs) total += p.length;
  return total * 10 + xs.length;
}
export function at(s: Uint8Array, i: number): number { return s.at(i) ?? -1; }
export function atMiss(s: Uint8Array, i: number): boolean { return s.at(i) === undefined; }
`,
    calls: [
      { fn: "parts", args: [{ t: "bytes", v: [88, 97, 88, 98, 88] }, { t: "bytes", v: [88] }] }, // "XaXbX" -> 4
      { fn: "parts", args: [{ t: "bytes", v: [97, 88, 88, 98] }, { t: "bytes", v: [88] }] }, // adjacent -> 3
      { fn: "parts", args: [{ t: "bytes", v: [97, 98] }, { t: "bytes", v: [90] }] }, // no match -> 1
      { fn: "parts", args: [{ t: "bytes", v: [] }, { t: "bytes", v: [88] }] }, // "" -> [""]
      { fn: "parts", args: [{ t: "bytes", v: [97, 97, 97, 97] }, { t: "bytes", v: [97, 97] }] }, // non-overlapping -> 3
      { fn: "part", args: [{ t: "bytes", v: [88, 97, 88, 98, 88] }, { t: "bytes", v: [88] }, i(0)] },
      { fn: "part", args: [{ t: "bytes", v: [88, 97, 88, 98, 88] }, { t: "bytes", v: [88] }, i(1)] },
      { fn: "part", args: [{ t: "bytes", v: [88, 97, 88, 98, 88] }, { t: "bytes", v: [88] }, i(3)] },
      { fn: "part", args: [{ t: "bytes", v: [97, 195, 169, 98] }, { t: "bytes", v: [195, 169] }, i(1)] }, // multi-byte separator
      { fn: "grown", args: [{ t: "bytes", v: [97, 44, 98, 98] }] },
      { fn: "at", args: [{ t: "bytes", v: [65, 66, 67] }, i(0)] },
      { fn: "at", args: [{ t: "bytes", v: [65, 66, 67] }, i(-1)] },
      { fn: "at", args: [{ t: "bytes", v: [65, 66, 67] }, i(-4)] }, // out of range from the end
      { fn: "at", args: [{ t: "bytes", v: [65, 66, 67] }, i(3)] },
      { fn: "atMiss", args: [{ t: "bytes", v: [65] }, i(2)] },
      { fn: "atMiss", args: [{ t: "bytes", v: [65] }, i(0)] },
    ],
  },
  {
    // Ternaries whose arms are spread literals lower to per-branch statement
    // blocks; both arms of every conditional are driven here so the reducer's
    // values pin that exactly the taken arm's copy runs (the model after a
    // kept-`q` arm must be the untouched quote, never a fresh copy with a
    // stale overwrite).
    name: "spread-arm ternaries: nested and single-level reducer arms match node on both branches",
    src: `
export type QuoteState = "idle" | "ok" | "failed";
export interface Quote { readonly id: number; readonly state: QuoteState; readonly price: number; }
export interface Model { readonly quote: Quote; }
export type Msg = { readonly kind: "got"; readonly parsed: number | null } | { readonly kind: "noop" };
export function initialModel(): Model {
  return { quote: { id: 1, state: "idle", price: 0.5 } };
}
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
export function pick(q: Quote | null, fallback: Quote): Quote {
  return q === null ? { ...fallback, state: "idle" } : q;
}
`,
    node: `
{
  let model = mod.initialModel();
  // noop on a non-ok quote: single-level ternary takes the spread arm.
  model = mod.update(model, { kind: "noop" });
  line("s0", model.quote.state);
  line("s1", model.quote.price);
  // got with a value: nested ternary's narrowed arm (spread + capture read).
  model = mod.update(model, { kind: "got", parsed: 42.5 });
  line("s2", model.quote.state);
  line("s3", model.quote.price);
  // noop on an ok quote: single-level ternary keeps q untouched.
  model = mod.update(model, { kind: "noop" });
  line("s4", model.quote.state);
  line("s5", model.quote.price);
  // got(null) on an ok quote: inner ternary keeps q untouched.
  model = mod.update(model, { kind: "got", parsed: null });
  line("s6", model.quote.state);
  line("s7", model.quote.price);
  // got(null) after a failure path: inner ternary takes its spread arm.
  const failed = mod.update(mod.initialModel(), { kind: "got", parsed: null });
  line("s8", failed.quote.state);
  line("s9", failed.quote.price);
  // orelse-fusion shape with a spread miss arm, both branches.
  const chosen = mod.pick(model.quote, failed.quote);
  line("s10", chosen.state);
  const fallen = mod.pick(null, failed.quote);
  line("s11", fallen.state);
  line("s12", fallen.id);
}
`,
    zig: `
    {
        var model = m.initialModel();
        model = m.update(model, .noop);
        row("s0", model.quote.state);
        row("s1", model.quote.price);
        model = m.update(model, .{ .got = 42.5 });
        row("s2", model.quote.state);
        row("s3", model.quote.price);
        model = m.update(model, .noop);
        row("s4", model.quote.state);
        row("s5", model.quote.price);
        model = m.update(model, .{ .got = null });
        row("s6", model.quote.state);
        row("s7", model.quote.price);
        const failed = m.update(m.initialModel(), .{ .got = null });
        row("s8", failed.quote.state);
        row("s9", failed.quote.price);
        const chosen = m.pick(model.quote, failed.quote);
        row("s10", chosen.state);
        const fallen = m.pick(null, failed.quote);
        row("s11", fallen.state);
        row("s12", fallen.id);
    }
`,
  },
  {
    // The INFERRED-local spelling of the spread-arm ternary (no `: Quote`
    // annotation, so the local's type comes from the ternary itself). Both
    // polarities and both branches are driven: the hit branch must hand back
    // the quote untouched, the miss branch must build the fallback copy with
    // its overwrite applied.
    name: "inferred-local spread-arm ternaries: both polarities and both branches match node",
    src: `
export type QuoteState = "idle" | "ok" | "failed";
export interface Quote { readonly id: number; readonly state: QuoteState; readonly price: number; }
export function pickMiss(q: Quote | null, fallback: Quote): Quote {
  const picked = q === null ? { ...fallback, price: 0 } : q;
  return picked;
}
export function pickHit(q: Quote | null, fallback: Quote): Quote {
  const picked = q !== null ? q : { ...fallback, price: 0 };
  return picked;
}
`,
    node: `
{
  const base = { id: 7, state: "ok", price: 12 };
  const fallback = { id: 9, state: "failed", price: 3 };
  const a = mod.pickMiss(base, fallback);
  line("p0", a.id);
  line("p1", a.state);
  line("p2", a.price);
  const b = mod.pickMiss(null, fallback);
  line("p3", b.id);
  line("p4", b.state);
  line("p5", b.price);
  const c = mod.pickHit(base, fallback);
  line("p6", c.id);
  line("p7", c.state);
  line("p8", c.price);
  const d = mod.pickHit(null, fallback);
  line("p9", d.id);
  line("p10", d.state);
  line("p11", d.price);
}
`,
    zig: `
    {
        const base = m.Quote{ .id = 7, .state = .ok, .price = 12 };
        const fallback = m.Quote{ .id = 9, .state = .failed, .price = 3 };
        const a = m.pickMiss(base, fallback);
        row("p0", a.id);
        row("p1", a.state);
        row("p2", a.price);
        const b = m.pickMiss(null, fallback);
        row("p3", b.id);
        row("p4", b.state);
        row("p5", b.price);
        const c = m.pickHit(base, fallback);
        row("p6", c.id);
        row("p7", c.state);
        row("p8", c.price);
        const d = m.pickHit(null, fallback);
        row("p9", d.id);
        row("p10", d.state);
        row("p11", d.price);
    }
`,
  },
  {
    name: "flow-exit guard narrowing in loops runs byte-identically (break, continue, kind guard, post-loop reads)",
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
export type Msg = { readonly kind: "num"; readonly value: number } | { readonly kind: "stop" };
export function prefixTotal(raw: readonly number[]): number {
  let sum = 0;
  for (const x of raw) {
    const msg: Msg = x < 0 ? { kind: "stop" } : { kind: "num", value: x };
    if (msg.kind !== "num") break;
    sum += msg.value;
  }
  return sum;
}
export interface Sel { readonly value: number; }
export interface Model { readonly sel: Sel | null; readonly count: number; }
export function drain(count: number, selVal: number, hasSel: boolean): number {
  const model: Model = { sel: hasSel ? { value: selVal } : null, count: count };
  let total = 0;
  let i = 0;
  while (i < model.count) {
    if (model.sel === null) break;
    total += model.sel.value;
    i += 1;
  }
  return model.sel === null ? total - 1 : total + model.sel.value;
}
`,
    calls: [
      { fn: "collect", args: [{ t: "bytes", v: [3, 7, 9] }] },
      { fn: "collect", args: [{ t: "bytes", v: [] }] },
      { fn: "oddTotal", args: [i(6)] },
      { fn: "oddTotal", args: [i(0)] },
      { fn: "prefixTotal", args: [{ t: "nums", v: [4, 5, -1, 9] }] },
      { fn: "prefixTotal", args: [{ t: "nums", v: [-2, 8] }] },
      { fn: "prefixTotal", args: [{ t: "nums", v: [] }] },
      { fn: "drain", args: [i(3), i(5), { t: "b", v: true }] },
      { fn: "drain", args: [i(3), i(5), { t: "b", v: false }] },
      { fn: "drain", args: [i(0), i(5), { t: "b", v: true }] },
    ],
  },
  {
    name: "a reassigned let behind a continue guard lands its spread reassignment",
    src: `
export interface P { readonly v: number; readonly tag: number; }
export function next(i: number): P | null {
  if (i % 2 === 0) return null;
  return { v: i, tag: i * 7 };
}
export function total(n: number): number {
  let sum = 0;
  for (let i = 0; i < n; i += 1) {
    let p = next(i);
    if (p === null) continue;
    p = { ...p, v: 10 };
    sum += p.v + p.tag;
  }
  return sum;
}
`,
    calls: [
      { fn: "total", args: [i(6)] },
      { fn: "total", args: [i(1)] },
      { fn: "total", args: [i(0)] },
    ],
  },
];

// ------------------------------------------------------------ arg spelling

function numToZig(v: number): string {
  if (Object.is(v, -0)) return "-0.0";
  const s = String(v);
  return /[.eE]/.test(s) ? s : `${s}.0`;
}

function zigArg(a: Arg): string {
  switch (a.t) {
    case "i":
      return String(a.v);
    case "f":
      if (a.v === "nan") return "std.math.nan(f64)";
      if (a.v === "inf") return "std.math.inf(f64)";
      if (a.v === "-inf") return "-std.math.inf(f64)";
      if (a.v === "-0") return "-0.0";
      return numToZig(a.v);
    case "b":
      return a.v ? "true" : "false";
    case "null":
      return "null";
    case "bytes":
      return `&[_]u8{${a.v.join(", ")}}`;
    case "nums":
      return `&[_]f64{${a.v.map(numElemToZig).join(", ")}}`;
    case "tag":
      return `.${a.v}`;
    case "str":
      return JSON.stringify(a.v);
  }
}

function numElemToZig(v: number | "nan" | "-0"): string {
  if (v === "nan") return "std.math.nan(f64)";
  if (v === "-0") return "-0.0";
  return numToZig(v);
}

function nodeArg(a: Arg): string {
  switch (a.t) {
    case "i":
      return String(a.v);
    case "f":
      if (a.v === "nan") return "NaN";
      if (a.v === "inf") return "Infinity";
      if (a.v === "-inf") return "-Infinity";
      if (a.v === "-0") return "-0";
      return String(a.v);
    case "b":
      return a.v ? "true" : "false";
    case "null":
      return "null";
    case "bytes":
      return `Uint8Array.from([${a.v.join(", ")}])`;
    case "nums":
      return `[${a.v.map((v) => (v === "nan" ? "NaN" : String(v))).join(", ")}]`;
    case "tag":
      return JSON.stringify(a.v);
    case "str":
      return JSON.stringify(a.v);
  }
}

// --------------------------------------------------------- driver assembly

function caseId(idx: number): string {
  return `case_${String(idx).padStart(2, "0")}`;
}

function nodeDriver(cases: readonly RunCase[]): string {
  const lines: string[] = [
    "// Generated run-fidelity driver, plain-TS side: import each case module",
    "// as-is and print the canonical transcript to stdout.",
    "// The byte-text methods install before any call runs — the same tables",
    "// rt.zig case-maps from, so the two transcripts must match bytewise.",
    'import { installTextMethods } from "./text_polyfill.ts";',
  ];
  cases.forEach((c, idx) =>
    lines.push(`import * as ${caseId(idx)} from "./${c.files ? `${caseId(idx)}/core.ts` : `${caseId(idx)}.ts`}";`),
  );
  lines.push(
    "",
    "installTextMethods();",
    "const out = [];",
    "function hex(bytes) {",
    '  let s = "";',
    '  for (const b of bytes) s += b.toString(16).padStart(2, "0");',
    "  return s;",
    "}",
    "function fmt(v) {",
    '  if (v === null) return "null";',
    '  if (typeof v === "boolean") return v ? "b:true" : "b:false";',
    '  if (typeof v === "number") {',
    '    if (Number.isNaN(v)) return "n:nan";',
    "    const dv = new DataView(new ArrayBuffer(8));",
    "    dv.setFloat64(0, v);",
    '    let s = "n:";',
    '    for (let idx = 0; idx < 8; idx++) s += dv.getUint8(idx).toString(16).padStart(2, "0");',
    "    return s;",
    "  }",
    '  if (typeof v === "string") return "x:" + hex(new TextEncoder().encode(v));',
    '  if (v instanceof Uint8Array) return "x:" + hex(v);',
    '  if (Array.isArray(v)) return "[" + v.map(fmt).join(",") + "]";',
    '  throw new Error("unsupported value in the run-fidelity transcript");',
    "}",
    "",
  );
  cases.forEach((c, idx) => {
    const id = caseId(idx);
    for (const [ci, call] of (c.calls ?? []).entries()) {
      lines.push(`out.push("${id}.${ci} " + fmt(${id}.${call.fn}(${call.args.map(nodeArg).join(", ")})));`);
    }
    if (c.node) {
      lines.push(`{`);
      lines.push(`  const mod = ${id};`);
      lines.push(`  const line = (tag, v) => out.push("${id}." + tag + " " + fmt(v));`);
      lines.push(c.node.trim());
      lines.push(`}`);
    }
  });
  lines.push("", 'process.stdout.write(out.join("\\n") + "\\n");', "");
  return lines.join("\n");
}

function zigDriver(cases: readonly RunCase[]): string {
  const lines: string[] = [
    "//! Generated run-fidelity driver, native side: run every case's emitted",
    "//! module and write the canonical transcript; the plain-TS driver must",
    "//! produce identical bytes.",
    "",
    'const std = @import("std");',
  ];
  cases.forEach((_, idx) => lines.push(`const ${caseId(idx)} = @import("${caseId(idx)}.zig");`));
  lines.push(
    "",
    "var sink: std.ArrayList(u8) = .empty;",
    "var gpa: std.mem.Allocator = undefined;",
    "",
    "fn put(s: []const u8) void {",
    '    sink.appendSlice(gpa, s) catch @panic("oom");',
    "}",
    "",
    "fn putHexByte(b: u8) void {",
    '    const digits = "0123456789abcdef";',
    '    sink.append(gpa, digits[b >> 4]) catch @panic("oom");',
    '    sink.append(gpa, digits[b & 0xf]) catch @panic("oom");',
    "}",
    "",
    "// Numbers travel as f64 bit patterns (any NaN canonicalizes to n:nan),",
    "// so the transcript never depends on float-to-text formatting.",
    "fn putNum(x: f64) void {",
    "    if (std.math.isNan(x)) {",
    '        put("n:nan");',
    "        return;",
    "    }",
    '    put("n:");',
    "    const bits: u64 = @bitCast(x);",
    "    var idx: usize = 0;",
    "    while (idx < 8) : (idx += 1) {",
    "        putHexByte(@truncate(bits >> @intCast((7 - idx) * 8)));",
    "    }",
    "}",
    "",
    "fn putValue(v: anytype) void {",
    "    const T = @TypeOf(v);",
    "    switch (@typeInfo(T)) {",
    '        .bool => put(if (v) "b:true" else "b:false"),',
    "        .int, .comptime_int => putNum(@floatFromInt(v)),",
    "        .float, .comptime_float => putNum(v),",
    '        .optional => if (v) |inner| putValue(inner) else put("null"),',
    '        .@"enum" => {',
    '            put("x:");',
    "            for (@tagName(v)) |b| putHexByte(b);",
    "        },",
    "        .pointer => |p| {",
    "            if (p.size == .slice and p.child == u8) {",
    '                put("x:");',
    "                for (v) |b| putHexByte(b);",
    "            } else if (p.size == .slice) {",
    '                put("[");',
    "                for (v, 0..) |elem, idx| {",
    '                    if (idx > 0) put(",");',
    "                    putValue(elem);",
    "                }",
    '                put("]");',
    "            } else {",
    '                @compileError("unsupported pointer value in the transcript");',
    "            }",
    "        },",
    '        else => @compileError("unsupported value type in the transcript"),',
    "    }",
    "}",
    "",
    "fn tagged(tag: []const u8, v: anytype) void {",
    "    put(tag);",
    '    put(" ");',
    "    putValue(v);",
    '    put("\\n");',
    "}",
    "",
    "pub fn main(init: std.process.Init) !void {",
    "    gpa = init.arena.allocator();",
  );
  cases.forEach((c, idx) => {
    const id = caseId(idx);
    for (const [ci, call] of (c.calls ?? []).entries()) {
      lines.push(`    tagged("${id}.${ci}", ${id}.${call.fn}(${call.args.map(zigArg).join(", ")}));`);
    }
    if (c.zig) {
      lines.push(`    {`);
      lines.push(`        const m = ${id};`);
      lines.push(`        const Row = struct {`);
      lines.push(`            fn emit(tag: []const u8, v: anytype) void {`);
      lines.push(`                put("${id}.");`);
      lines.push(`                tagged(tag, v);`);
      lines.push(`            }`);
      lines.push(`        };`);
      lines.push(`        const row = Row.emit;`);
      lines.push(c.zig.replace(/^\n+|\n+$/g, "").replace(/^ {4}/gm, "        "));
      lines.push(`    }`);
    }
  });
  lines.push(
    '    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = "zig_transcript.txt", .data = sink.items });',
    "}",
    "",
  );
  return lines.join("\n");
}

// ------------------------------------------------------------------- tests

test("run corpus: every case transpiles clean", () => {
  for (const c of runCorpus) {
    const result = c.files
      ? transpileFiles({ "core.ts": c.src, ...c.files }, c.options ?? {})
      : transpile(c.src, c.options ?? {});
    assert.equal(result.typeErrors.length, 0, `${c.name}: tsc errors\n${result.typeErrors.join("\n")}`);
    const details = result.diagnostics.map((d) => `${d.id} ${d.message}`).join("\n");
    assert.equal(result.ok, true, `${c.name}: transpile failed\n${details}`);
  }
});

test("run corpus: emitted Zig behaves byte-identically to the same source under node", { skip: !hasZig, timeout: 600_000 }, () => {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "native-core-runfidelity-"));
  try {
    // Native side: emitted modules + rt kernel + generated driver.
    fs.copyFileSync(path.join(pkg, "rt", "rt.zig"), path.join(work, "rt.zig"));
    runCorpus.forEach((c, idx) => {
      const result = c.files
        ? transpileFiles({ "core.ts": c.src, ...c.files }, c.options ?? {})
        : transpile(c.src, c.options ?? {});
      assert.equal(result.ok, true, `${c.name}: transpile failed before the run step`);
      fs.writeFileSync(path.join(work, `${caseId(idx)}.zig`), result.zig!);
    });
    fs.writeFileSync(path.join(work, "driver.zig"), zigDriver(runCorpus));

    // Plain-TS side: the same sources verbatim, with only the SDK import
    // specifier resolved to a file path (a resolution detail, not semantics).
    const sdkCopy = path.join(work, "sdk_core.ts");
    fs.copyFileSync(path.join(pkg, "sdk", "core.ts"), sdkCopy);
    fs.copyFileSync(path.join(pkg, "sdk", "text.ts"), path.join(work, "sdk_text.ts"));
    // The byte-text polyfill and its generated tables — the node half of
    // the text-method surface the zig half gets from rt.zig.
    fs.copyFileSync(path.join(pkg, "src", "text_polyfill.ts"), path.join(work, "text_polyfill.ts"));
    fs.copyFileSync(path.join(pkg, "src", "text_tables.ts"), path.join(work, "text_tables.ts"));
    const resolveSdk = (src: string, prefix: string): string =>
      src
        .replace(/"@native-sdk\/core\/text"/g, `"${prefix}sdk_text.ts"`)
        .replace(/"@native-sdk\/core"/g, `"${prefix}sdk_core.ts"`);
    runCorpus.forEach((c, idx) => {
      if (c.files) {
        // Multi-file case: its own directory, so relative imports between
        // the modules keep their spellings (only SDK specifiers resolve).
        const dir = path.join(work, caseId(idx));
        fs.mkdirSync(dir, { recursive: true });
        for (const [name, source] of Object.entries({ "core.ts": c.src, ...c.files })) {
          fs.mkdirSync(path.dirname(path.join(dir, name)), { recursive: true });
          fs.writeFileSync(path.join(dir, name), resolveSdk(source, "../"));
        }
        return;
      }
      fs.writeFileSync(path.join(work, `${caseId(idx)}.ts`), resolveSdk(c.src, "./"));
    });
    fs.writeFileSync(path.join(work, "driver.ts"), nodeDriver(runCorpus));

    let nodeOut: string;
    try {
      nodeOut = execFileSync(process.execPath, [path.join(work, "driver.ts")], {
        cwd: work,
        encoding: "utf8",
      });
    } catch (e) {
      const err = e as { stderr?: string; stdout?: string };
      assert.fail(`plain-TS driver failed:\n${err.stderr ?? ""}${err.stdout ?? ""}`);
    }

    try {
      execFileSync("zig", ["run", "driver.zig"], { cwd: work, encoding: "utf8", stdio: "pipe" });
    } catch (e) {
      const err = e as { stderr?: string; stdout?: string };
      assert.fail(`native driver failed:\n${err.stderr ?? ""}${err.stdout ?? ""}`);
    }
    const zigOut = fs.readFileSync(path.join(work, "zig_transcript.txt"), "utf8");

    if (nodeOut !== zigOut) {
      const nodeLines = nodeOut.split("\n");
      const zigLines = zigOut.split("\n");
      const diffs: string[] = [];
      const max = Math.max(nodeLines.length, zigLines.length);
      for (let idx = 0; idx < max; idx++) {
        if (nodeLines[idx] !== zigLines[idx]) {
          diffs.push(`  ts:  ${nodeLines[idx] ?? "<missing>"}\n  zig: ${zigLines[idx] ?? "<missing>"}`);
        }
      }
      assert.fail(`run transcripts diverge (${diffs.length} lines):\n${diffs.join("\n")}`);
    }
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
});
