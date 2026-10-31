import assert from "node:assert/strict";
import test from "node:test";
import { native_effect_policy } from "../src/runtime_policy.ts";
const words = [0n, 1n, 4294967295n, 4294967296n, 9007199254740992n, 9007199254740993n, 18446744073709551615n];
const limit = 1114112n;
function input(stage: number): Uint8Array { const b = new Uint8Array(160); b.set([26, stage]); wide(b, 128, limit); return b; }
function wide(b: Uint8Array, at: number, n: bigint): void { new DataView(b.buffer, b.byteOffset, b.byteLength).setBigUint64(at, n, true); }
function value(b: Uint8Array, at: number): bigint { return new DataView(b.buffer, b.byteOffset, b.byteLength).getBigUint64(at, true); }
function plan(b: Uint8Array): Uint8Array {
  const before = b.slice(), out = native_effect_policy(b);
  assert.equal(out.length, 80); assert.deepEqual(out.subarray(2, 4), new Uint8Array(2));
  assert.deepEqual(out.subarray(61, 64), new Uint8Array(3)); assert.deepEqual(b, before);
  return out;
}
function next(kind: number, length: number, remaining: bigint, pos = 16n, flags = 1): Uint8Array {
  const b = input(2); b[2] = flags; wide(b, 8, pos + remaining); wide(b, 16, pos);
  b[112] = kind; new DataView(b.buffer).setUint32(113, length, true); return b;
}
test("journal preamble preserves all fingerprint bits and bad-magic precedence", () => {
  for (const fingerprint of words) {
    const write = input(4); wide(write, 24, fingerprint); const preamble = plan(write).slice(64);
    assert.deepEqual(preamble.slice(0, 8), new TextEncoder().encode("NSDKSJNL")); assert.equal(value(preamble, 8), fingerprint);
    for (let length = 0; length <= 16; length++) {
      const read = input(0); wide(read, 8, BigInt(length)); wide(read, 24, fingerprint); read.set(preamble.subarray(0, length), 112);
      assert.equal(plan(read)[0], length < 16 ? 1 : 0);
      if (length === 16) { assert.equal(value(plan(read), 8), 16n); read[120] = read[120]! ^ 1; assert.equal(plan(read)[0], 2); }
      read[112] = 0; assert.equal(plan(read)[0], 1);
    }
  }
});
test("journal framing preserves exact five-byte headers and both budget boundaries", () => {
  for (let kind = 1; kind <= 7; kind++) for (const length of [0n, 1n, limit - 1n, limit, limit + 1n, ...words.slice(2)])
    for (const capacity of [0n, length + 4n, length + 5n, length + 6n].filter(n => n <= words[6]!)) {
      const b = input(1); b[3] = kind; wide(b, 8, length); wide(b, 16, capacity); const out = plan(b);
      const refused = length > limit || capacity < length + 5n; assert.equal(out[0], refused ? 5 : 0);
      if (!refused) { assert.equal(out[56], kind); assert.equal(new DataView(out.buffer).getUint32(57, true), Number(length)); }
      else assert.deepEqual(out.slice(56, 61), new Uint8Array(5));
    }
});
test("journal admission preserves ended, kind, budget, truncation and header precedence", () => {
  for (let kind = 0; kind <= 255; kind++) for (const length of [0, 1, Number(limit), Number(limit) + 1, 4294967295])
    for (const remaining of [0n, 1n, 4n, 5n, 6n, limit + 5n, 4294967300n]) for (const flags of [0, 1, 2, 3]) {
      const b = next(kind, length, remaining, 16n, flags), out = plan(b);
      const validKind = kind >= 1 && kind <= 7;
      const expected = flags & 2 ? remaining === 0n ? 8 : 4
        : remaining < 5n ? 3 : !validKind ? 4 : BigInt(length) > limit ? 5
        : remaining - 5n < BigInt(length) ? 3 : !(flags & 1) && kind !== 1 ? 6 : flags & 1 && kind === 1 ? 4 : 0;
      assert.equal(out[0], expected);
      const admitted = !(flags & 2) && remaining >= 5n && validKind && BigInt(length) <= limit && remaining - 5n >= BigInt(length);
      assert.equal(value(out, 8), admitted ? 21n + BigInt(length) : 16n);
    }
});
test("journal counters mutate before decoding and carry exact unsigned words independently", () => {
  for (const pos of words.filter(n => n <= words[6]! - 10n)) for (let kind = 1; kind <= 7; kind++) for (const count of words.slice(0, -1)) {
    const b = next(kind, 3, 8n, pos, kind === 1 ? 0 : 1);
    for (let i = 0; i < 5; i++) wide(b, 32 + i * 8, count);
    const out = plan(b); assert.equal(value(out, 8), pos + 8n);
    for (let i = 0; i < 5; i++) assert.equal(value(out, 16 + i * 8), count + BigInt(kind === (i === 4 ? 7 : i + 2)));
    const saved = out.slice(); b.fill(0); plan(input(4)); assert.deepEqual(out, saved);
  }
});
test("journal seal compares all five complete counters and retains copied state", () => {
  for (const count of words) for (const recorded of words) for (let field = 0; field < 5; field++) {
    const b = input(3); for (let i = 0; i < 5; i++) { wide(b, 32 + i * 8, count); wide(b, 72 + i * 8, count); }
    wide(b, 72 + field * 8, recorded); const out = plan(b); assert.equal(out[0], count === recorded ? 0 : 7);
    assert.deepEqual(out.slice(16, 56), b.slice(32, 72));
  }
});
test("journal transport refuses malformed packets before reading native facts", () => {
  for (let length = 0; length < 160; length++) assert.throws(() => native_effect_policy(new Uint8Array(length).fill(26)));
  for (const at of [1, 2, 3, 4, 7, 136, 159]) { const b = input(0); b[at] = 255; assert.throws(() => plan(b)); }
  const b = next(1, 0, 0n); wide(b, 16, 100n); assert.throws(() => plan(b));
});
