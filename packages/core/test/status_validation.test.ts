import { nscvStatusValidation as validate } from "../src/status_validation.ts";
import { strict as assert } from "node:assert";
import { test } from "node:test";

function packet(operation: number, words: readonly number[], tail: Uint8Array = new Uint8Array()): Uint8Array {
  const bytes = new Uint8Array(4 + words.length * 4 + tail.length); bytes.set([70, operation, 0, 0]);
  const data = new DataView(bytes.buffer); words.forEach((word, slot) => data.setUint32(4 + slot * 4, word, true)); bytes.set(tail, 4 + words.length * 4); return bytes;
}
function title(bytes: Uint8Array): Uint8Array { return packet(2, [bytes.length], bytes.subarray(0, 64)); }

test("status field admission preserves byte limits before embedded NUL errors", () => {
  for (let byte = 0; byte < 256; byte++) for (const length of [0, 1, 63, 64, 65]) {
    const input = new Uint8Array(length).fill(byte);
    assert.deepEqual([...validate(title(input))], [length > 64 ? 2 : length > 0 && byte === 0 ? 1 : 0, 0, 0, 0]);
  }
  for (const id of [0, 1, 0xffffffff]) assert.deepEqual([...validate(packet(5, [id]))], [id === 0 ? 1 : 0, 0, 0, 0]);
  assert.deepEqual([...validate(packet(4, [33]))], [1, 0, 0, 0]);
});

test("status presentation checks the native f32 values and title error order", () => {
  for (const value of [NaN, Infinity, -Infinity, -1, -0, 0, 0.5, 1, 64, 65, 3.4028234663852886e38]) for (let field = 0; field < 3; field++) {
    const input = packet(3, [0], new Uint8Array(12)), data = new DataView(input.buffer); data.setFloat32(12, 1, true); data.setFloat32(8 + field * 4, value, true);
    const applied = data.getFloat32(8 + field * 4, true);
    assert.equal(validate(input)[0], !Number.isFinite(applied) || applied < 0 || (field === 1 && applied > 1) || (field === 2 && applied > 64) ? 1 : 0);
  }
  const overlong = packet(3, [65], new Uint8Array(64 + 12)); new DataView(overlong.buffer).setFloat32(72, NaN, true);
  assert.equal(validate(overlong)[0], 2);
});

test("status identity chunk comparisons preserve all query slots and exclude their own row", () => {
  const queries = 256, count = 128, input = packet(6, [31, queries, count], new Uint8Array(queries * 8 + count * 4)), data = new DataView(input.buffer);
  for (let slot = 0; slot < queries; slot++) { const at = 16 + slot * 8; input[at] = Math.floor(slot / 8); input[at + 1] = slot % 8; data.setUint32(at + 4, slot === 0 ? 0xffffffff : slot, true); }
  for (let value = 0; value < count; value++) data.setUint32(16 + queries * 8 + value * 4, value === 0 ? 0xffffffff : value * 2, true);
  const result = validate(input); assert.equal(result.length, queries);
  for (let slot = 0; slot < queries; slot++) assert.equal(result[slot], slot < 248 && (slot === 0 || slot % 2 === 0) ? 1 : 0);
  input[18] = 1; assert.throws(() => validate(input));
});

test("every status packet truncation tail and reserved field is rejected", () => {
  const inputs = [packet(0, [0, 0, 0, 0, 0x3f800000, 0, 0, 0, 0, 0, 0]), packet(1, [0, 0, 0, 0, 0]), title(new TextEncoder().encode("title")), packet(3, [0], new Uint8Array(12)), packet(4, [0]), packet(5, [1]), packet(6, [0, 0, 0])];
  for (const input of inputs) {
    for (let length = 0; length < input.length; length++) assert.throws(() => validate(input.subarray(0, length)));
    const extra = new Uint8Array(input.length + 1); extra.set(input); assert.throws(() => validate(extra));
    for (const offset of [2, 3]) { const bad = input.slice(); bad[offset] = 1; assert.throws(() => validate(bad)); }
    const padded = new Uint8Array(input.length + 8); padded.set(input, 4); assert.deepEqual(validate(padded.subarray(4, 4 + input.length)), validate(input));
  }
});
