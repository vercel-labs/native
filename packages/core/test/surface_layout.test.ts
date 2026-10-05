import assert from "node:assert/strict";
import test from "node:test";
import { native_window_policy } from "../src/runtime_policy.ts";

function request(operation: number, a: number, b: number, values: readonly number[]): Uint8Array {
  const bytes = new Uint8Array(4 + values.length * 4);
  bytes.set([3, operation, a, b]);
  const data = new DataView(bytes.buffer);
  values.forEach((value, i) => data.setFloat32(4 + i * 4, value, true));
  return bytes;
}
function frame(bytes: Uint8Array): number[] | null {
  assert.equal(bytes.length, 17);
  if (bytes[0] === 0) return null;
  const data = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  return [1, 5, 9, 13].map(at => data.getFloat32(at, true));
}
const modal = (kind: number, values = [10, 20, 600, 400, 0, 0, 0, 0, 0, 0, 0, 0, 24]) => request(0, kind, 0, values);
const anchored = (placement: number, flags: number, values = [0, 0, 600, 400, 520, 360, 64, 24, 160, 120, 0, 0, 0, 0, 0, 0, 4, 620, 410]) => request(1, placement, flags, values);

test("surface defaults, empty bounds and unsupported kinds retain native behavior", () => {
  assert.deepEqual(frame(native_window_policy(modal(0))), [100, 110, 420, 220]);
  assert.deepEqual(frame(native_window_policy(modal(1))), [10, 140, 600, 280]);
  assert.deepEqual(frame(native_window_policy(modal(2))), [290, 20, 320, 400]);
  assert.equal(frame(native_window_policy(modal(255))), null);
  const empty = modal(0); new DataView(empty.buffer).setFloat32(12, 0, true);
  assert.equal(frame(native_window_policy(empty)), null);
});

test("anchors flip, align, clamp points, and stretch within window space", () => {
  assert.deepEqual(frame(native_window_policy(anchored(0, 0))), [440, 236, 160, 120]);
  assert.deepEqual(frame(native_window_policy(anchored(1, 1))), [424, 236, 160, 120]);
  assert.deepEqual(frame(native_window_policy(anchored(0, 4))), [440, 276, 160, 120]);
  const values = [0, 0, 600, 400, 10, 20, 200, 24, 80, 40, 0, 0, 0, 0, 180, 0, 4, 0, 0];
  assert.deepEqual(frame(native_window_policy(anchored(0, 2, values))), [10, 48, 180, 40]);
});

test("caption clearance preserves leading, trailing and absent reservations", () => {
  assert.deepEqual(frame(native_window_policy(request(2, 1, 1, [0, 0, 600, 40, 0, 0, 80, 30]))), [80, 0, 520, 40]);
  assert.deepEqual(frame(native_window_policy(request(2, 1, 1, [0, 0, 600, 40, 520, 0, 80, 30]))), [0, 0, 520, 40]);
  assert.deepEqual(frame(native_window_policy(request(2, 1, 0, [0, 0, 600, 40, 0, 0, 80, 30]))), [0, 0, 600, 40]);
});

test("surface wire rejects truncation, extra bytes and invalid operation flags", () => {
  for (const valid of [modal(0), anchored(0, 0), request(2, 1, 1, [0, 0, 600, 40, 0, 0, 80, 30])]) {
    for (let n = 1; n < valid.length; n++) assert.throws(() => native_window_policy(valid.subarray(0, n)), /surface/);
    assert.throws(() => native_window_policy(new Uint8Array([...valid, 0])), /surface/);
    const malformed = valid.slice(); malformed[1] = 255;
    assert.throws(() => native_window_policy(malformed), /surface/);
    malformed.set(valid); malformed[2] = 254;
    assert.throws(() => native_window_policy(malformed), /flags/);
    malformed.set(valid); malformed[3] = 255;
    assert.throws(() => native_window_policy(malformed), /flags/);
  }
  assert.throws(() => native_window_policy(anchored(0, 3)), /alignment/);
});

test("surface wire honors offset views and preserves a signed-zero clamp endpoint", () => {
  for (const valid of [modal(0), anchored(0, 0), request(2, 1, 1, [0, 0, 600, 40, 0, 0, 80, 30])]) {
    const storage = new Uint8Array(valid.length + 19).fill(255);
    storage.set(valid, 7);
    assert.deepEqual(native_window_policy(storage.subarray(7, 7 + valid.length)), native_window_policy(valid));
  }
  const values = [-0, 0, 600, 400, 0, 20, 200, 24, 80, 40, 0, 0, 0, 0, 180, 0, 4, 0, 0];
  assert.equal(Object.is(frame(native_window_policy(anchored(0, 0, values)))![0], -0), true);
});
