import assert from "node:assert/strict";
import test from "node:test";
import { native_effect_policy } from "../src/runtime_policy.ts";
function request(stage: number): Uint8Array {
  const input = new Uint8Array(64); input.set([24, stage, 1, 0, 0, 0, 255]);
  const data = new DataView(input.buffer); data.setUint32(20, 8, true); data.setUint32(24, 256, true);
  return input;
}
function word(input: Uint8Array, at: number, value: bigint): void {
  new DataView(input.buffer).setBigUint64(at, value, true);
}
function plan(input: Uint8Array): Uint8Array {
  const saved = input.slice(), result = native_effect_policy(input);
  assert.deepEqual(input, saved); assert.equal(result.length, 32);
  return result;
}
test("recording gates preserve begin and post-finish write distinctions", () => {
  for (let stage = 0; stage <= 12; stage++) for (let bits = 0; bits < 8; bits++) {
    const input = request(stage); input[2] = bits & 1; input[3] = (bits >> 1) & 1; input[4] = (bits >> 2) & 1;
    if (stage === 2 || stage === 3) input[5] = 1;
    if (stage === 7) input[8] = 1;
    word(input, 32, 1n); word(input, 48, 1024n); word(input, 56, 4096n);
    const skip = stage === 0 ? !!(bits & 5) : stage >= 9 ? !!(bits & 4) : !(bits & 1) || !!(bits & 6);
    assert.equal(plan(input)[0], skip ? 0 : 1, `stage=${stage} flags=${bits}`);
  }
});
test("recording stack recipes keep outer suppression and exact pop ownership", () => {
  for (let depth = 0; depth <= 8; depth++) for (let owner = -1; owner < depth; owner++) for (const outer of [0, 1]) {
    const input = request(1); input[5] = depth; input[6] = owner < 0 ? 255 : owner; input[8] = outer;
    const output = plan(input);
    assert.equal(output[0], depth === 8 ? 2 : owner < 0 ? 1 : 8);
    assert.equal(output[1], depth === 8 ? depth : depth + 1);
    assert.equal(output[2], depth === 8 ? input[6] : owner < 0 && outer ? depth : input[6]);
    if (depth === 0) continue;
    input[1] = 2;
    for (const suppressed of [0, 1]) {
      input[7] = suppressed; const pop = plan(input);
      assert.equal(pop[0], suppressed ? 8 : 1); assert.equal(pop[1], depth - 1);
      assert.equal(pop[2], !suppressed && owner === depth - 1 ? 255 : input[6]);
    }
  }
});
test("recording chrome refuses in source/depth/budget order and selects outer owner", () => {
  for (const unavailable of [0, 1]) for (const depth of [0, 1, 8]) for (const count of [0, 255, 256]) {
    const input = request(3); input[5] = depth; input[12] = unavailable;
    new DataView(input.buffer).setUint32(16, count, true);
    assert.equal(plan(input)[0], unavailable ? 3 : depth === 0 ? 4 : count === 256 ? 5 : 1);
    if (depth > 0 && !unavailable && count < 256) {
      for (let owner = -1; owner < depth; owner++) {
        input[6] = owner < 0 ? 255 : owner; const result = plan(input);
        assert.equal(result[1], owner < 0 ? depth - 1 : owner);
        assert.equal(new DataView(result.buffer).getUint32(16, true), count + 1);
      }
    }
  }
});
test("recording checkpoint and counter words retain adjacent identities above 2^53", () => {
  const ids = [0n, 1n, 4294967295n, 4294967296n, 9007199254740992n, 9007199254740993n, 18446744073709551615n];
  for (const frame of ids) for (const previous of ids) {
    const input = request(4); word(input, 32, frame); word(input, 40, previous);
    assert.equal(plan(input)[0], frame === previous ? 0 : 1);
    input[5] = 1; assert.equal(plan(input)[0], 0);
  }
  for (const count of ids.slice(0, -1)) {
    const input = request(12); word(input, 32, count);
    const retained = plan(input), result = new DataView(retained.buffer).getBigUint64(8, true);
    assert.equal(result, count + 1n); const saved = retained.slice(); plan(request(12)); assert.deepEqual(retained, saved);
  }
});
test("recording effect recipes redact secrets and preserve strict database spill boundary", () => {
  for (let kind = 1; kind <= 20; kind++) for (const length of [0n, 1n, 65536n, 65537n, 18446744073709551615n]) {
    for (const chunk of [0, 1]) for (const get of [0, 1]) for (const ok of [0, 1]) {
      const input = request(7); input[8] = kind; input[9] = chunk; input[10] = get; input[11] = ok;
      word(input, 40, length); word(input, 48, 65536n);
      const expected = kind === 18 ? get && ok ? 7 : 6 : kind === 4 && chunk && length > 0n ? 2
        : kind === 11 && length > 0n ? 3 : kind === 15 && length > 0n ? 1
        : kind === 16 && length > 0n ? 4 : kind === 17 && length > 65536n ? 5 : 0;
      assert.equal(plan(input)[3], expected);
    }
  }
});
test("recording budget recipes compare complete unsigned words and account for headers", () => {
  for (const bytes of [0n, 134217720n, 4294967295n, 9007199254740993n]) {
    for (const length of [0n, 1n, 65536n, 1114112n, 1114113n]) {
      for (const budget of [134217728n, bytes + length + 4n, bytes + length + 5n]) {
        const input = request(9); word(input, 32, bytes); word(input, 40, length); word(input, 48, 1114112n); word(input, 56, budget);
        const result = plan(input), total = bytes + length + 5n;
        assert.equal(result[0], length > 1114112n ? 6 : total > budget ? 7 : 1);
        if (length <= 1114112n) assert.equal(new DataView(result.buffer).getBigUint64(8, true), total);
      }
    }
  }
});
test("recording refuses malformed packets before reads or planning", () => {
  for (let length = 2; length < 64; length++) assert.throws(() => plan(new Uint8Array(length).fill(24)));
  for (const at of [1, 2, 3, 4, 7, 9, 10, 11, 12, 13, 14, 15, 28, 29, 30, 31]) {
    const input = request(0); input[at] = 255; assert.throws(() => plan(input));
  }
  const input = request(1); input[5] = 9; assert.throws(() => plan(input));
  input[5] = 1; input[6] = 1; assert.throws(() => plan(input));
});
