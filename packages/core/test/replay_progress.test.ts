import assert from "node:assert/strict";
import test from "node:test";
import { native_effect_policy } from "../src/runtime_policy.ts";
const max = 18446744073709551615n;
const words = [0n, 1n, 15n, 16n, 4294967295n, 4294967296n, 9007199254740992n, 9007199254740993n, max];
function request(stage: number, count = 0): Uint8Array {
  const bytes = new Uint8Array(96 + 80 * count); bytes.set([25, stage, 0, count]); return bytes;
}
function word(bytes: Uint8Array, at: number, value: bigint): void {
  new DataView(bytes.buffer).setBigUint64(at, value, true);
}
function plan(bytes: Uint8Array): Uint8Array {
  const saved = bytes.slice(), output = native_effect_policy(bytes);
  assert.deepEqual(bytes, saved); assert.equal(output.length, 32);
  assert.equal(output[3], 0); assert.deepEqual(output.subarray(24), new Uint8Array(8)); return output;
}
function value(bytes: Uint8Array, at: number): bigint { return new DataView(bytes.buffer).getBigUint64(at, true); }
function slot(bytes: Uint8Array, i: number, id: bigint, open: boolean, kind = 0, label = new Uint8Array(0)): void {
  const at = 96 + i * 80; bytes.set([Number(open), kind, label.length], at);
  word(bytes, at + 8, id); bytes.set(label, at + 16);
}
test("replay accounting carries full unsigned words and retains copied results", () => {
  for (const count of words.filter(v => v !== max)) {
    const bytes = request(0); word(bytes, 8, count); const output = plan(bytes);
    assert.equal(value(output, 8), count + 1n);
    const saved = output.slice(); plan(request(0)); assert.deepEqual(output, saved);
  }
  const overflow = request(0); word(overflow, 8, max); assert.throws(() => plan(overflow));
});
test("replay comparisons keep exact hashes and only the first sixteen mismatch details", () => {
  for (const count of words.filter(v => v !== max)) for (const mismatch of words.filter(v => v !== max))
    for (const expected of words) for (const actual of words) {
      const bytes = request(1); word(bytes, 8, count); word(bytes, 16, mismatch); word(bytes, 24, expected); word(bytes, 32, actual);
      const output = plan(bytes), different = expected !== actual;
      assert.equal(value(output, 8), count + 1n); assert.equal(output[1], Number(different));
      assert.equal(value(output, 16), mismatch + BigInt(different));
      assert.equal(output[2], different && mismatch < 16n ? Number(mismatch) : 255);
    }
});
test("replay blob admission preserves missing-before-budget precedence and exact length validation", () => {
  for (const length of words) for (const limit of words) for (const present of [0, 1]) {
    const bytes = request(2); bytes[2] = present; word(bytes, 8, length); word(bytes, 16, limit);
    assert.equal(plan(bytes)[0], present === 0 ? 1 : length > limit ? 2 : 0);
    bytes[1] = 3; bytes[2] = 0; assert.equal(plan(bytes)[0], length === limit ? 0 : 3);
  }
  for (let code = 0; code < 3; code++) { const bytes = request(4); bytes[2] = code; assert.equal(plan(bytes)[0], code === 2 ? 4 : 0); }
});
test("replay window selection distinguishes adjacent large IDs and chooses first open match", () => {
  for (const target of words) {
    const bytes = request(5, 16); word(bytes, 8, target);
    for (let i = 0; i < 16; i++) slot(bytes, i, target ^ 1n, true);
    slot(bytes, 0, target, false); slot(bytes, 7, target, true); slot(bytes, 15, target, true);
    assert.equal(new DataView(plan(bytes).buffer).getUint32(4, true), 7);
    bytes[96 + 7 * 80] = 0; assert.equal(new DataView(plan(bytes).buffer).getUint32(4, true), 15);
    bytes[96 + 15 * 80] = 0; assert.equal(new DataView(plan(bytes).buffer).getUint32(4, true), 4294967295);
  }
});
test("replay screenshot selection compares raw bytes, kind, openness and first-match order", () => {
  for (const label of [new Uint8Array(0), Uint8Array.from([0, 255, 195, 40]), new Uint8Array(64).fill(255)]) {
    const bytes = request(6, 32); word(bytes, 8, BigInt(label.length)); bytes.set(label, 32);
    for (let i = 0; i < 32; i++) slot(bytes, i, max, false, 17, label);
    slot(bytes, 0, max, true, 0, label); slot(bytes, 12, max, true, 17, label); slot(bytes, 31, max, true, 17, label);
    assert.equal(new DataView(plan(bytes).buffer).getUint32(4, true), 12);
    bytes[96 + 12 * 80] = 0; assert.equal(new DataView(plan(bytes).buffer).getUint32(4, true), 31);
    word(bytes, 8, 65n); assert.equal(new DataView(plan(bytes).buffer).getUint32(4, true), 4294967295);
  }
});
test("replay refuses truncated, oversized and malformed tables before choosing a target", () => {
  for (let length = 0; length < 96; length++) assert.throws(() => native_effect_policy(new Uint8Array(length).fill(25)));
  for (const at of [1, 2, 3, 4, 40, 95]) { const bytes = request(0); bytes[at] = 255; assert.throws(() => plan(bytes)); }
  const bytes = request(6, 2); slot(bytes, 0, 1n, true, 17);
  bytes[96 + 80] = 2; assert.throws(() => plan(bytes));
  bytes[96 + 80] = 0; bytes[96 + 80 + 2] = 65; assert.throws(() => plan(bytes));
  bytes[96 + 80 + 2] = 0; bytes[96 + 80 + 3] = 1; assert.throws(() => plan(bytes));
  assert.throws(() => plan(request(5, 17))); assert.throws(() => plan(request(6, 33)));
});
