// Subset checker tests: one violation in -> the teaching rule's ID out.

import test from "node:test";
import assert from "node:assert/strict";
import { checkOnly, ruleIds, transpile } from "./helpers.ts";

const core = `
export interface Model { readonly count: number; }
export type Msg = { readonly kind: "tick" };
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "tick":
      return { count: model.count + 1 };
  }
}
`;

test("clean core passes the checker", () => {
  assert.deepEqual(ruleIds(checkOnly(core)), []);
});

test("NS1001 mutating array methods", () => {
  const ids = ruleIds(
    checkOnly(`
export interface Model { readonly items: readonly number[]; }
export function update(model: Model): Model {
  (model.items as number[]).push(1);
  return model;
}
`),
  );
  assert.ok(ids.includes("NS1001"), `got ${ids}`);
});

test("NS1002 async and await", () => {
  const ids = ruleIds(
    checkOnly(`
export async function update(x: number): Promise<number> {
  return await Promise.resolve(x);
}
`),
  );
  assert.ok(ids.includes("NS1002"), `got ${ids}`);
});

test("NS1003 functions stored in the model", () => {
  const ids = ruleIds(
    checkOnly(`
export interface Model { readonly onTick: () => void; }
export function update(model: Model): Model { return model; }
`),
  );
  assert.ok(ids.includes("NS1003"), `got ${ids}`);
});

test("NS1004 string length, indexing, charCodeAt, relational", () => {
  for (const expr of ["s.length", "s[0]", "s.charCodeAt(0)", 's < "z" ? 1 : 2']) {
    const ids = ruleIds(checkOnly(`export function f(s: string): number { return ${expr} as number; }`));
    assert.ok(ids.includes("NS1004"), `${expr}: got ${ids}`);
  }
});

test("NS1004 relational comparison on string-literal union values", () => {
  const ids = ruleIds(
    checkOnly(`
export type Rank = "bronze" | "silver" | "gold";
export function before(a: Rank, b: Rank): boolean { return a < b; }
`),
  );
  assert.ok(ids.includes("NS1004"), `got ${ids}`);
});

test("NS1004 fires on a hand-rolled ascii bridge (the SDK intrinsic replaced structural recognition)", () => {
  const result = checkOnly(`
export function asciiBytes(s: string): Uint8Array {
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}
`);
  const ids = ruleIds(result);
  assert.deepEqual(ids, ["NS1004"]);
  const d = result.diagnostics[0];
  assert.ok(d.message.includes("asciiBytes"), "the fix names the SDK intrinsic");
  assert.ok(d.message.includes("@native-sdk/core"), "the fix names where it comes from");
});

test("the SDK asciiBytes intrinsic passes the checker", () => {
  const ids = ruleIds(
    checkOnly(`
import { asciiBytes } from "@native-sdk/core";
export function greeting(): Uint8Array { return asciiBytes("hello"); }
`),
  );
  assert.deepEqual(ids, []);
});

test("NS1005 ambient time and randomness", () => {
  for (const expr of ["Math.random()", "Date.now()"]) {
    const ids = ruleIds(checkOnly(`export function f(): number { return ${expr}; }`));
    assert.ok(ids.includes("NS1005"), `${expr}: got ${ids}`);
  }
});

test("NS1006 class expressions and `this` outside members", () => {
  const ids = ruleIds(checkOnly(`export const C = class { id: number = 1; };`));
  assert.ok(ids.includes("NS1006"), `got ${ids}`);
  const ids2 = ruleIds(checkOnly(`export function f(): number { return (this as { n: number }).n; }`));
  assert.ok(ids2.includes("NS1006"), `got ${ids2}`);
});

test("data classes pass the checker; the banned tail teaches by name", () => {
  const ok = checkOnly(`
export class Counter {
  count: number = 0;
  bump(): void { this.count += 1; }
}
export function f(): number { const c = new Counter(); c.bump(); return c.count; }
`);
  assert.deepEqual(ruleIds(ok), []);
  const ids = ruleIds(checkOnly(`
class A { n: number = 0; }
export class B extends A { get twice(): number { return 2; } static s: number = 1; }
`));
  assert.ok(ids.includes("NS1055"), `extends: got ${ids}`);
  assert.ok(ids.includes("NS1056"), `accessor/static: got ${ids}`);
});

test("R20 exceptions: try/catch/throw pass the checker; the discipline rules teach", () => {
  const ok = checkOnly(`
export type Failure = { readonly kind: "negative" } | { readonly kind: "bad" };
export function f(x: number): number {
  try {
    if (x < 0) throw { kind: "negative" } as Failure;
  } catch (e) {
    const err = e as Failure;
    return err.kind === "negative" ? 0 : 1;
  }
  return x;
}
`);
  assert.deepEqual(ruleIds(ok), []);
  // NS1057: `new Error` has no native shape.
  const ids = ruleIds(checkOnly(`export function f(): number { throw new Error("x"); }`));
  assert.ok(ids.includes("NS1057"), `got ${ids}`);
  // NS1057: two distinct thrown shapes.
  const ids2 = ruleIds(
    checkOnly(`
export function f(x: number): number {
  if (x < 0) throw 1;
  if (x > 10) throw true;
  return x;
}
`),
  );
  assert.ok(ids2.includes("NS1057"), `got ${ids2}`);
  // NS1057: a directly-used catch binding.
  const ids3 = ruleIds(
    checkOnly(`
export function f(): number {
  try { return 1; } catch (e) { return e === null ? 0 : 2; }
}
`),
  );
  assert.ok(ids3.includes("NS1057"), `got ${ids3}`);
  // NS1058: control flow out of finally.
  const ids4 = ruleIds(
    checkOnly(`export function f(): number { try { return 1; } finally { return 0; } }`),
  );
  assert.ok(ids4.includes("NS1058"), `got ${ids4}`);
  // ...while a break WITHIN a loop inside finally is that loop's own.
  const ids5 = ruleIds(
    checkOnly(`
export function f(): number {
  let n = 0;
  try { n = 1; } finally {
    for (let i = 0; i < 3; i++) { if (i === 1) break; n += 1; }
  }
  return n;
}
`),
  );
  assert.deepEqual(ids5, []);
});

test("NS1008 non-erasable syntax (enum)", () => {
  const ids = ruleIds(checkOnly(`export enum Filter { All, Active }`));
  assert.ok(ids.includes("NS1008"), `got ${ids}`);
});

test("NS1009 for/in", () => {
  const ids = ruleIds(
    checkOnly(`
export function f(o: { readonly a: number }): number {
  let n = 0;
  for (const k in o) n += 1;
  return n;
}
`),
  );
  assert.ok(ids.includes("NS1009"), `got ${ids}`);
});

test("NS1010 module-level let", () => {
  const ids = ruleIds(checkOnly(`let counter = 0;\nexport function f(): number { return counter; }`));
  assert.ok(ids.includes("NS1010"), `got ${ids}`);
});

test("NS1011 object-keyed Map", () => {
  const ids = ruleIds(
    checkOnly(`
export interface Key { readonly id: number; }
export function f(): number {
  const m = new Map<Key, number>();
  return m.size;
}
`),
  );
  assert.ok(ids.includes("NS1011"), `got ${ids}`);
});

test("NS1011 bare new Map() and new Set() teach the id-keyed-array idiom", () => {
  for (const expr of ["new Map()", "new Map<number, number>()", "new Set()"]) {
    const result = checkOnly(`export function f(): number { const m = ${expr}; return m.size; }`);
    const ids = ruleIds(result);
    assert.ok(ids.includes("NS1011"), `${expr}: got ${ids}`);
    const d = result.diagnostics.find((x) => x.id === "NS1011");
    assert.ok(d && d.message.includes("id-keyed array"), `${expr}: teaches the idiom`);
  }
});

test("NS1012 delete", () => {
  const ids = ruleIds(
    checkOnly(`
export function f(o: { a?: number }): void {
  delete o.a;
}
`),
  );
  assert.ok(ids.includes("NS1012"), `got ${ids}`);
});

test("NS1013 eval and dynamic import", () => {
  const ids = ruleIds(checkOnly(`export function f(): void { eval("1"); }`));
  assert.ok(ids.includes("NS1013"), `got ${ids}`);
});

test("NS1035 runtime npm import (module boundary rules live in the graph resolver)", () => {
  const result = transpile(`import x from "some-npm-package";\nexport const y = x;`);
  assert.equal(result.ok, false);
  const d = result.diagnostics.find((x) => x.id === "NS1035");
  assert.ok(d, `got ${result.diagnostics.map((x) => x.id)}`);
  assert.ok(d.title.includes("npm packages"), "teaches the npm rule");
});

test("type-only npm imports are allowed by the graph resolver", () => {
  // The type-only edge erases at the boundary: no NS103x code fires (the
  // unresolvable package then surfaces as an ordinary tsc error).
  const result = transpile(`import type { X } from "some-npm-package";\nexport const y = 1;`);
  assert.equal(result.diagnostics.length, 0, `got ${result.diagnostics.map((x) => x.id)}`);
});

test("NS1037 a relative import must name a real .ts file", () => {
  const result = transpile(`import { helper } from "./helper_mod";\nexport const y = helper;`);
  assert.equal(result.ok, false);
  const d = result.diagnostics.find((x) => x.id === "NS1037");
  assert.ok(d, `got ${result.diagnostics.map((x) => x.id)}`);
  assert.ok(d.message.includes("extension") || d.message.includes("names no"), "teaches the real-filename rule");
});

test("NS1018 string concatenation with +", () => {
  for (const src of [
    `export function f(s: string): string { return "hi " + s; }`,
    `export function f(s: string, n: number): string { return s + n; }`,
    `export function f(s: string): string { let t = s; t += "!"; return t; }`,
  ]) {
    const ids = ruleIds(checkOnly(src));
    assert.ok(ids.includes("NS1018"), `${src}: got ${ids}`);
  }
});

test("numeric + does not trip the concatenation rule", () => {
  const ids = ruleIds(checkOnly(`export function f(a: number, b: number): number { return a + b; }`));
  assert.ok(!ids.includes("NS1018"), `got ${ids}`);
});

test("NS1019 parameter default values", () => {
  const ids = ruleIds(
    checkOnly(`
function step(n: number, by: number = 1): number { return n + by; }
export function f(n: number): number { return step(n); }
`),
  );
  assert.ok(ids.includes("NS1019"), `got ${ids}`);
});

test("NS1021 null test on an optional chain", () => {
  for (const expr of ["model.inner?.x === null", "model.inner?.x !== null", "undefined === model.inner?.x"]) {
    const ids = ruleIds(
      checkOnly(`
export interface Inner { readonly x: number | null; }
export interface Model { readonly inner: Inner | null; }
export function f(model: Model): boolean { return ${expr}; }
`),
    );
    assert.ok(ids.includes("NS1021"), `${expr}: got ${ids}`);
  }
});

test("?? and value comparisons on optional chains stay checker-clean", () => {
  const ids = ruleIds(
    checkOnly(`
export interface Inner { readonly x: number; }
export interface Model { readonly inner: Inner | null; }
export function f(model: Model): number { return model.inner?.x ?? 0; }
export function g(model: Model): boolean { return model.inner?.x === 5; }
`),
  );
  assert.deepEqual(ids, []);
});

const cmdCore = (update: string) => `
import { Cmd } from "@native-sdk/core";
export interface Model { readonly count: number; }
export type Msg =
  | { readonly kind: "add" }
  | { readonly kind: "tick"; readonly at: number };
${update}
`;

test("Cmd in update's return path passes the checker", () => {
  const ids = ruleIds(
    checkOnly(
      cmdCore(`
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "add": return [{ count: model.count + 1 }, Cmd.batch([Cmd.persist(), Cmd.now("tick")])];
    case "tick": return { count: msg.at };
  }
}
`),
    ),
  );
  assert.deepEqual(ids, []);
});

test("NS1017 Cmd stored in a local", () => {
  const ids = ruleIds(
    checkOnly(
      cmdCore(`
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  const cmd = Cmd.persist();
  switch (msg.kind) {
    case "add": return [model, cmd];
    case "tick": return model;
  }
}
`),
    ),
  );
  assert.ok(ids.includes("NS1017"), `got ${ids}`);
});

test("NS1017 Cmd built in a helper", () => {
  const ids = ruleIds(
    checkOnly(
      cmdCore(`
function saveCmd(): Cmd<Msg> {
  return Cmd.persist();
}
export function update(model: Model, msg: Msg): Model { return model; }
`),
    ),
  );
  assert.ok(ids.includes("NS1017"), `got ${ids}`);
});

test("NS1017 Cmd stored in the model", () => {
  const ids = ruleIds(
    checkOnly(`
import { Cmd } from "@native-sdk/core";
export type Msg = { readonly kind: "add" } | { readonly kind: "noop" };
export interface Model { readonly pending: Cmd<Msg>; }
export function update(model: Model, msg: Msg): Model { return model; }
`),
  );
  assert.ok(ids.includes("NS1017"), `got ${ids}`);
});

test("NS1017 Cmd in the model slot of the returned tuple", () => {
  const ids = ruleIds(
    checkOnly(
      cmdCore(`
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "add": return [[model, Cmd.persist()][0], Cmd.none];
    case "tick": return model;
  }
}
`),
    ),
  );
  assert.ok(ids.includes("NS1017"), `got ${ids}`);
});

test("Cmd in initialModel's boot pair passes the checker (the init command)", () => {
  const ids = ruleIds(
    checkOnly(
      cmdCore(`
export function initialModel(): [Model, Cmd<Msg>] {
  return [{ count: 0 }, Cmd.now("tick")];
}
export function update(model: Model, msg: Msg): Model { return model; }
`),
    ),
  );
  assert.deepEqual(ids, []);
});

test("Sub in subscriptions' return path passes the checker", () => {
  const ids = ruleIds(
    checkOnly(`
import { Sub } from "@native-sdk/core";
export interface Model { readonly running: boolean; }
export type Msg = { readonly kind: "toggle" } | { readonly kind: "tick"; readonly at: number };
export function update(model: Model, msg: Msg): Model { return model; }
export function subscriptions(model: Model): Sub<Msg> {
  return model.running ? Sub.timer("tick", 100, "tick") : Sub.none;
}
`),
  );
  assert.deepEqual(ids, []);
});

test("NS1025 Sub built anywhere else", () => {
  const result = checkOnly(`
import { Sub } from "@native-sdk/core";
export interface Model { readonly running: boolean; }
export type Msg = { readonly kind: "toggle" } | { readonly kind: "tick"; readonly at: number };
export function update(model: Model, msg: Msg): Model { return model; }
function timers(model: Model): Sub<Msg> {
  return Sub.timer("tick", 100, "tick");
}
`);
  const d = result.diagnostics.find((x) => x.id === "NS1025");
  assert.ok(d, `got ${ruleIds(result)}`);
  assert.ok(d.message.includes("subscriptions"), "names the home");
  assert.ok(d.message.toLowerCase().includes("replay"), "says why");
});

test("diagnostics carry rule, fix, and why", () => {
  const result = checkOnly(`export function f(): number { return Math.random(); }`);
  const d = result.diagnostics.find((x) => x.id === "NS1005");
  assert.ok(d);
  assert.ok(d.title.length > 0, "has a rule title");
  assert.ok(d.message.includes("Cmd."), "shows the idiomatic rewrite");
  assert.ok(d.message.toLowerCase().includes("replay"), "says why");
});

test("NS1022 in-place sort teaches the toSorted rewrite", () => {
  const result = checkOnly(`
export function ordered(xs: number[]): number[] {
  xs.sort((a, b) => a - b);
  return xs;
}
`);
  const d = result.diagnostics.find((x) => x.id === "NS1022");
  assert.ok(d, `got ${ruleIds(result)}`);
  assert.ok(d.message.includes(".toSorted"), "names the copying rewrite");
});

test("NS1022 fires on sort even where the base looks readonly", () => {
  const ids = ruleIds(
    checkOnly(`
export interface Model { readonly xs: readonly number[]; }
export function f(model: Model): readonly number[] {
  (model.xs as number[]).sort((a, b) => a - b);
  return model.xs;
}
`),
  );
  assert.ok(ids.includes("NS1022"), `got ${ids}`);
});

test("NS1023 boolean comparator is taught beneath tsc's own signature error", () => {
  // tsc's toSorted signature already rejects a boolean comparator (TS2345
  // gates the pipeline first); the checker rule is the teaching layer, and
  // the emitter re-derives it.
  const result = checkOnly(`
export function ordered(xs: readonly number[]): readonly number[] {
  return xs.toSorted((a, b) => a > b);
}
`);
  const d = result.diagnostics.find((x) => x.id === "NS1023");
  assert.ok(d, `got ${ruleIds(result)}`);
  assert.ok(d.message.includes("a - b"), "names the sign-returning fix");
});

test("push on a local builder array is the emitter's to shape, not NS1001", () => {
  const ids = ruleIds(
    checkOnly(`
export function collect(xs: readonly number[]): readonly number[] {
  const out: number[] = [];
  for (const x of xs) {
    if (x > 0) out.push(x);
  }
  return out;
}
`),
  );
  assert.deepEqual(ids, []);
});

test("NS1001 still fires for push on a parameter array", () => {
  const ids = ruleIds(
    checkOnly(`
export function grow(xs: number[], x: number): number[] {
  xs.push(x);
  return xs;
}
`),
  );
  assert.ok(ids.includes("NS1001"), `got ${ids}`);
});

test("local mutation: the full owned method set passes the checker clean", () => {
  const ids = ruleIds(
    checkOnly(`
export function work(xs: readonly number[]): readonly number[] {
  const copy = xs.slice();
  copy.push(1);
  copy.pop();
  copy.shift();
  copy.unshift(0);
  copy.splice(1, 1, 9);
  copy.reverse();
  copy.fill(0, 0, 1);
  copy.sort((a, b) => a - b);
  copy[0] = 5;
  return copy;
}
`),
  );
  assert.deepEqual(ids, []);
});

test("NS1051 mutation after the array was passed to a call, with the escape named", () => {
  const result = checkOnly(`
function probe(xs: number[]): number { return xs.length; }
export function f(): number {
  const out: number[] = [1];
  const t = probe(out);
  out.push(2);
  return t;
}
`);
  const d = result.diagnostics.find((x) => x.id === "NS1051");
  assert.ok(d, `got ${ruleIds(result)}`);
  assert.ok(d.message.includes("was passed to a call"), d.message);
  assert.ok(/line \d/.test(d.message), "names the escape line");
});

test("NS1051 mutation after storing the array into a record", () => {
  const ids = ruleIds(
    checkOnly(`
export interface Pair { readonly xs: readonly number[]; }
export function f(): Pair {
  const out: number[] = [1];
  const pair: Pair = { xs: out };
  out.pop();
  return pair;
}
`),
  );
  assert.ok(ids.includes("NS1051"), `got ${ids}`);
});

test("NS1051 aliasing ends the original binding's ownership", () => {
  const ids = ruleIds(
    checkOnly(`
export function f(): number {
  const a: number[] = [1];
  const b = a;
  a.push(2);
  return b.length;
}
`),
  );
  assert.ok(ids.includes("NS1051"), `got ${ids}`);
});

test("an early-exit return is terminal, not an escape (mutation after it stays legal)", () => {
  const ids = ruleIds(
    checkOnly(`
export function padded(xs: readonly number[], min: number): readonly number[] {
  const work = xs.slice();
  if (work.length >= min) return work;
  while (work.length < min) work.push(0);
  return work;
}
`),
  );
  assert.deepEqual(ids, []);
});

test("an escape inside a loop gates mutations anywhere in that loop", () => {
  const ids = ruleIds(
    checkOnly(`
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
`),
  );
  assert.ok(ids.includes("NS1051"), `got ${ids}`);
});

test("NS1001 mutating the alias of an owned array (the alias owns nothing)", () => {
  const result = checkOnly(`
export function f(): number {
  const a: number[] = [1];
  const b = a;
  b.push(2);
  return a.length;
}
`);
  const d = result.diagnostics.find((x) => x.id === "NS1001");
  assert.ok(d, `got ${ruleIds(result)}`);
  assert.ok(d.message.includes("aliases"), d.message);
});

test("NS1001 mutating a module-level table", () => {
  const ids = ruleIds(
    checkOnly(`
const TABLE: number[] = [1, 2];
export function f(): number {
  TABLE.push(3);
  return TABLE.length;
}
`),
  );
  assert.ok(ids.includes("NS1001"), `got ${ids}`);
});

test("NS1001 indexed writes through parameters and NS1051 after an escape", () => {
  const paramWrite = ruleIds(
    checkOnly(`
export function f(xs: number[]): number {
  xs[0] = 1;
  return xs[0];
}
`),
  );
  assert.ok(paramWrite.includes("NS1001"), `got ${paramWrite}`);
  const escapedWrite = ruleIds(
    checkOnly(`
function probe(xs: number[]): number { return xs.length; }
export function f(): number {
  const out: number[] = [1];
  const t = probe(out);
  out[0] = 2;
  return t;
}
`),
  );
  assert.ok(escapedWrite.includes("NS1051"), `got ${escapedWrite}`);
});

test("NS1022 keeps teaching on shared sorts and now names the local-copy idiom", () => {
  const result = checkOnly(`
export function ordered(xs: number[]): number[] {
  xs.sort((a, b) => a - b);
  return xs;
}
`);
  const d = result.diagnostics.find((x) => x.id === "NS1022");
  assert.ok(d, `got ${ruleIds(result)}`);
  assert.ok(d.message.includes("copy.sort"), "names the slice-copy idiom");
  assert.ok(d.message.includes(".toSorted"), "keeps the copying rewrite");
});

test("NS1023 fires on an in-place sort's boolean comparator too", () => {
  const result = checkOnly(`
export function ordered(xs: readonly number[]): readonly number[] {
  const copy = xs.slice();
  copy.sort((a, b) => a > b);
  return copy;
}
`);
  const d = result.diagnostics.find((x) => x.id === "NS1023");
  assert.ok(d, `got ${ruleIds(result)}`);
  assert.ok(d.message.includes("a - b"), "names the sign-returning fix");
});

test("NS1024 string model fields are taught at the declaration, not first use", () => {
  const result = checkOnly(`
export interface Model { readonly title: string; readonly n: number; }
export type Msg = { readonly kind: "a" } | { readonly kind: "b" };
export function initialModel(): Model { return { title: "x", n: 0 }; }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) { case "a": return model; case "b": return model; }
}
export function read(model: Model): boolean { return model.title === "x"; }
`);
  const d = result.diagnostics.find((x) => x.id === "NS1024");
  assert.ok(d, `expected NS1024, got ${ruleIds(result)}`);
  // The declaration sits on line 2 (the interface); first use is far below.
  assert.equal(d.line, 2);
  assert.ok(d.message.includes("`title`"), d.message);
  assert.ok(d.message.includes("Uint8Array"), d.message);
});

test("NS1024 does not fire for literal-union tag fields or Msg payload strings", () => {
  const ids = ruleIds(
    checkOnly(`
export type Filter = "all" | "done";
export interface Model { readonly filter: Filter; }
export type Msg = { readonly kind: "run"; readonly name: string } | { readonly kind: "stop" };
export function initialModel(): Model { return { filter: "all" }; }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) { case "run": return model; case "stop": return model; }
}
`),
  );
  assert.ok(!ids.includes("NS1024"), `got ${ids}`);
});

test("NS1031 an exported helper colliding with a model field's emitted name is taught", () => {
  const result = checkOnly(`
interface Totals { readonly doneCount: number; }
export interface Model { readonly totals: Totals; readonly doneCount: number; }
export type Msg = { readonly kind: "a" } | { readonly kind: "b" };
export function initialModel(): Model { return { totals: { doneCount: 0 }, doneCount: 0 }; }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) { case "a": return model; case "b": return model; }
}
export function doneCount(model: Model): number { return model.totals.doneCount; }
`);
  const d = result.diagnostics.find((x) => x.id === "NS1031");
  assert.ok(d, `expected NS1031, got ${ruleIds(result)}`);
  assert.ok(d.message.includes("doneCount"), d.message);
});

test("NS1031 does not fire across casings: names emit verbatim, so doneCount and done_count coexist", () => {
  const result = checkOnly(`
export interface Model { readonly done_count: number; }
export type Msg = { readonly kind: "a" } | { readonly kind: "b" };
export function initialModel(): Model { return { done_count: 0 }; }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) { case "a": return model; case "b": return model; }
}
export function doneCount(model: Model): number { return model.done_count; }
`);
  assert.ok(!ruleIds(result).includes("NS1031"), `got ${ruleIds(result)}`);
});

test("NS1032 viewUnbound entries must name the model surface", () => {
  const result = checkOnly(`
export interface Model { readonly count: number; }
export type Msg = { readonly kind: "add" } | { readonly kind: "tick"; readonly at: number };
export const viewUnbound = ["count", "tick", "nope"] as const;
export function initialModel(): Model { return { count: 0 }; }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) { case "add": return model; case "tick": return model; }
}
`);
  const d = result.diagnostics.find((x) => x.id === "NS1032");
  assert.ok(d, `expected NS1032, got ${ruleIds(result)}`);
  assert.ok(d.message.includes('"nope"'), d.message);
  // The two valid entries alone are clean.
  const clean = checkOnly(`
export interface Model { readonly count: number; }
export type Msg = { readonly kind: "add" } | { readonly kind: "tick"; readonly at: number };
export const viewUnbound = ["count", "tick"] as const;
export function initialModel(): Model { return { count: 0 }; }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) { case "add": return model; case "tick": return model; }
}
`);
  assert.ok(!ruleIds(clean).includes("NS1032"), `got ${ruleIds(clean)}`);
});
