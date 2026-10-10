import assert from "node:assert/strict";
import test from "node:test";
import { native_window_policy } from "../src/runtime_policy.ts";

function projection(ids: readonly bigint[], capacity = ids.length): Uint8Array {
  const input = new Uint8Array(40 + ids.length * 32), wire = new DataView(input.buffer);
  input[0] = 68; wire.setUint32(4, ids.length, true); wire.setUint32(8, capacity, true);
  ids.forEach((id, i) => { wire.setBigUint64(40 + i * 32, id, true); wire.setUint32(48 + i * 32, 0xffffffff, true); });
  return input;
}

test("accessibility projection retains exact parent identities beyond the publication capacity", () => {
  const input = projection([9007199254740993n, 0xffffffffffffffffn, 0n], 1), wire = new DataView(input.buffer);
  wire.setUint32(48, 1, true); wire.setUint32(52, 3, true); // link becomes a platform button
  const output = native_window_policy(input), result = new DataView(output.buffer);
  assert.equal(output.length, 36); assert.equal(result.getUint32(0, true), 1);
  assert.equal(result.getBigUint64(8, true), 0xffffffffffffffffn);
  assert.equal(result.getUint32(16, true), 1); assert.equal(result.getUint32(20, true), 4);
  wire.setUint32(48, 2, true);
  const zeroParent = new DataView(native_window_policy(input).buffer);
  assert.equal(zeroParent.getBigUint64(8, true), 0n); assert.equal(zeroParent.getUint32(16, true), 1);
  wire.setUint32(48, 3, true); assert.equal(new DataView(native_window_policy(input).buffer).getUint32(16, true), 0);
});

test("accessibility projection preserves zero identity focus, raw state and NaN selection behavior", () => {
  const input = projection([0n, 9007199254740993n]), wire = new DataView(input.buffer);
  input[2] = input[3] = 1;
  wire.setBigUint64(24, 9007199254740993n, true); wire.setBigUint64(32, 9007199254740993n, true);
  wire.setUint32(84, 17, true); wire.setUint32(92, 4 | 8 | 16, true); wire.setFloat32(96, NaN, true);
  const result = new DataView(native_window_policy(input).buffer);
  assert.equal(result.getUint32(24, true), 3); // zero can be focused but cannot be hovered/pressed
  assert.equal(result.getUint32(52, true), 1 | 4 | 8 | 16 | 256 | 1024);
  wire.setUint32(88, 255, true); wire.setUint32(92, 63, true); wire.setUint32(100, 2047, true);
  const all = new DataView(native_window_policy(input).buffer);
  assert.equal(all.getUint32(52, true), 2046); assert.equal(all.getUint32(56, true), 3); assert.equal(all.getUint32(60, true), 2047);
});

test("accessibility publication compares every fingerprint byte and retries unsuccessful publication", () => {
  for (let changed = -1; changed < 8; changed++) for (const published of [0, 1]) for (let flags = 0; flags < 4; flags++) {
    const request = new Uint8Array(20); request.set([68, 1, published, flags]);
    request.fill(255, 4); if (changed >= 0) request[4 + changed] = 127;
    const action = native_window_policy(request)[0];
    assert.equal(action, published === 1 && changed === -1 ? 0 : flags === 3 ? 1 : 2);
  }
  for (const pending of [0, 1]) for (let flags = 0; flags < 4; flags++) {
    assert.equal(native_window_policy(Uint8Array.of(68, 2, pending, flags))[0], pending === 1 && flags !== 1 ? 1 : 0);
  }
});

test("accessibility packets reject malformed lengths, reserved fields and unsupported facts", () => {
  const good = projection([1n]), padded = new Uint8Array(good.length + 8); padded.set(good, 4);
  assert.deepEqual(native_window_policy(padded.subarray(4, 4 + good.length)), native_window_policy(good));
  assert.throws(() => native_window_policy(good.subarray(0, good.length - 1)));
  for (const [at, value] of [[8, 65], [12, 1], [52, 27], [56, 256], [60, 64], [68, 2048]]) {
    const input = good.slice(); new DataView(input.buffer).setUint32(at!, value!, true);
    assert.throws(() => native_window_policy(input));
  }
  assert.throws(() => native_window_policy(Uint8Array.of(68, 2, 2, 0)));
});
