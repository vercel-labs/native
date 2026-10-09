import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = ["runtime_policy.ts", "render_resources.ts", "gpu_planning.ts"].map(name => readFileSync(new URL(`../src/${name}`, import.meta.url), "utf8")).join("\n");
const { nscvGpuPlanning: plan, native_window_policy: dispatch } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport {nscvGpuPlanning};").toString("base64")}`);
function request(mode = 0, capacity = 20): Uint8Array {
  const packet = mode < 2, count = packet ? 15 : 0, glyphs = packet ? 2 : 0, batches = packet ? 0 : 5;
  const bytes = new Uint8Array(96 + count * 64 + glyphs * 4 + batches * 4), w = new DataView(bytes.buffer);
  bytes.set([65, 1, mode, 5]); w.setUint32(4, count, true); w.setUint32(8, capacity, true); w.setUint32(12, 1, true); w.setUint32(16, glyphs, true); w.setUint32(20, batches, true);
  for (let family = 0; family < 8; family++) w.setUint32(24 + family * 4, family % 3, true);
  if (packet) {
    for (let i = 0; i < count; i++) {
      const at = 96 + i * 64; w.setUint32(at, i, true); w.setUint32(at + 4, i >= 5 && i <= 10 ? i % 2 : 4294967295, true);
      w.setUint32(at + 8, i === 12 ? 1 : 0, true); w.setUint32(at + 12, i > 12 ? 2 : 0, true); w.setUint32(at + 16, i === 12 ? 2 : 0, true);
      for (const off of [32, 48]) { w.setFloat32(at + off, -0, true); w.setFloat32(at + off + 4, 2, true); w.setFloat32(at + off + 8, -7.25, true); w.setFloat32(at + off + 12, 9.5, true); }
    }
    w.setUint32(96 + count * 64, 1, true); w.setUint32(100 + count * 64, 65535, true);
  } else [0, 0, 2, 2, 0].forEach((value, i) => w.setUint32(96 + i * 4, value, true));
  return bytes;
}
function checked(bytes: Uint8Array): Uint8Array {
  const before = bytes.slice(), result = plan(bytes);
  assert.deepEqual(bytes, before); assert.deepEqual(result, dispatch(bytes)); return result;
}
test("GPU planner admits full command kinds and glyph boundaries with copied ownership", () => {
  const bytes = request(), output = checked(bytes), w = new DataView(output.buffer);
  assert.deepEqual(Array.from({ length: 15 }, (_, i) => w.getUint32(36 + i * 32, true)), [14, 14, 14, 14, 14, 1, 4, 3, 6, 8, 9, 10, 11, 12, 13]);
  assert.equal(w.getUint32(16, true), 5);
  assert.deepEqual([w.getFloat32(32 + 5 * 32 + 16, true), w.getFloat32(32 + 5 * 32 + 20, true)], [-7.25, 2]);
  const mutated = bytes.slice(), m = new DataView(mutated.buffer); m.setUint32(mutated.length - 4, 65536, true);
  const rejected = checked(mutated); assert.equal(new DataView(rejected.buffer).getUint32(36 + 12 * 32, true), 14);
  const copy = output.slice(); bytes.fill(255); assert.deepEqual(output, copy);
  const backing = new Uint8Array(mutated.length + 23); backing.set(mutated, 11); assert.deepEqual(checked(backing.subarray(11, 11 + mutated.length)), rejected);
});
test("GPU packet capacities preserve prefixes while summary culling remains complete", () => {
  const complete = checked(request());
  for (let capacity = 0; capacity <= 16; capacity++) {
    const result = checked(request(0, capacity)), w = new DataView(result.buffer);
    assert.equal(w.getUint32(4, true), Math.min(capacity, 15)); assert.equal(w.getUint32(8, true), capacity < 15 ? 1 : 0);
    assert.deepEqual(result.subarray(32), complete.subarray(32, 32 + Math.min(capacity, 15) * 32));
  }
  const bytes = request(1), w = new DataView(bytes.buffer); w.setUint32(12, 3, true);
  w.setFloat32(56, -10, true); w.setFloat32(60, 0, true); w.setFloat32(64, 20, true); w.setFloat32(68, 20, true);
  const result = checked(bytes); assert.equal(result.length, 32); assert.equal(new DataView(result.buffer).getUint32(4, true), 15);
  w.setFloat32(64, 0, true); assert.equal(new DataView(checked(bytes).buffer).getUint32(4, true), 0);
  w.setUint32(12, 0, true); bytes.fill(0, 56, 72); assert.deepEqual(Array.from(checked(bytes)), [1, ...Array(31).fill(0)]);
});
test("GPU encoder preserves cache family order pipeline changes and every capacity prefix", () => {
  const bytes = request(2, 64), full = checked(bytes), w = new DataView(full.buffer);
  const count = w.getUint32(4, true); assert.equal(count, 17); assert.equal(w.getUint32(20, true), 3);
  assert.deepEqual(Array.from({ length: count }, (_, i) => w.getUint32(32 + i * 8, true)), [0, 3, 4, 4, 6, 7, 7, 9, 10, 11, 11, 10, 11, 11, 10, 11, 12]);
  for (let capacity = 0; capacity <= count + 1; capacity++) {
    const result = checked(request(2, capacity)), out = new DataView(result.buffer);
    assert.equal(out.getUint32(4, true), Math.min(capacity, count)); assert.equal(out.getUint32(8, true), capacity < count ? 1 : 0);
    assert.deepEqual(result.subarray(32), full.subarray(32, 32 + Math.min(capacity, count) * 8));
  }
  const summary = checked(request(3)), out = new DataView(summary.buffer); assert.equal(summary.length, 32); assert.equal(out.getUint32(4, true), count);
});
test("GPU planner rejects malformed shape reserved fields and glyph slices", () => {
  const bytes = request();
  for (const length of [0, 3, 95, 96, bytes.length - 1]) assert.throws(() => plan(bytes.subarray(0, length)), /invalid/);
  for (const [at, value] of [[4, 4294967295], [12, 4], [72, 1], [100, 0], [108, 1], [112, 1], [124, 1]]) {
    const next = bytes.slice(); new DataView(next.buffer).setUint32(at, value, true); assert.throws(() => plan(next), /invalid/);
  }
  const encoder = request(2), w = new DataView(encoder.buffer); w.setUint32(96, 7, true); assert.throws(() => plan(encoder), /invalid/);
});
