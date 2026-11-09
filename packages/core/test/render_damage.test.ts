import assert from "node:assert/strict";
import test from "node:test";
import { native_window_policy } from "../src/runtime_policy.ts";
type Rect = [number, number, number, number];
type Entry = { key: bigint; fingerprint: bigint; bounds: Rect };
function request(mode: number, options: { full?: boolean; refined?: boolean; scale?: number; oldScale?: number; surface?: [number, number]; bounds?: Rect; overrides?: Rect; animation?: Rect; refinement?: Rect; rects?: Rect[]; changes?: (Rect | null)[]; baseline?: Entry[]; current?: Entry[]; blurs?: { bounds: Rect; radius: number; clip?: Rect; opacity?: number; transform?: number[] }[]; multiplier?: number } = {}) {
  const { rects = [], changes = [], baseline = [], current = [], blurs = [] } = options;
  const bytes = new Uint8Array(128 + changes.length * 20 + rects.length * 16 + blurs.length * 68 + (baseline.length + current.length) * 32), w = new DataView(bytes.buffer);
  bytes[0] = 15; bytes[1] = mode; bytes[2] = 3; bytes[3] = (options.full ? 1 : 0) | (options.refined ? 2 : 0);
  const rect = (at: number, r: Rect) => r.forEach((v, i) => w.setFloat32(at + i * 4, v, true));
  const optional = (at: number, r: Rect | null | undefined) => { w.setUint32(at, r ? 1 : 0, true); if (r) rect(at + 4, r); };
  w.setFloat32(4, options.surface?.[0] ?? 800, true); w.setFloat32(8, options.surface?.[1] ?? 600, true); w.setFloat32(12, options.scale ?? 1, true);
  optional(16, options.bounds); optional(36, options.overrides); optional(56, options.animation); optional(76, options.refinement);
  w.setFloat32(96, options.multiplier ?? 1, true); w.setFloat32(100, options.oldScale ?? 2, true);
  [changes.length, rects.length, blurs.length, baseline.length, current.length, 8].forEach((v, i) => w.setUint32(104 + i * 4, v, true));
  let at = 128;
  for (const r of changes) { optional(at, r); at += 20; }
  for (const r of rects) { rect(at, r); at += 16; }
  for (const blur of blurs) { rect(at, blur.bounds); (blur.transform ?? [1, 0, 0, 1, 0, 0]).forEach((v, i) => w.setFloat32(at + 16 + i * 4, v, true)); optional(at + 40, blur.clip); w.setFloat32(at + 60, blur.opacity ?? 1, true); w.setFloat32(at + 64, blur.radius, true); at += 68; }
  for (const entry of [...baseline, ...current]) { w.setBigUint64(at, entry.key, true); w.setBigUint64(at + 8, entry.fingerprint, true); rect(at + 16, entry.bounds); at += 32; }
  return bytes;
}
function decode(bytes: Uint8Array) {
  const w = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength), count = w.getUint32(4, true), written = w.getUint32(8, true);
  return { full: w.getUint32(0, true), count, written, valid: w.getUint32(12, true), bounds: w.getUint32(16, true) ? Array.from({ length: 4 }, (_, i) => w.getFloat32(20 + i * 4, true)) : null, rects: Array.from({ length: written }, (_, i) => Array.from({ length: 4 }, (_, j) => w.getFloat32(64 + i * 16 + j * 4, true))), flags: Array.from(bytes.subarray(64 + written * 16)) };
}
const entry = (key: bigint, fingerprint: bigint, bounds: Rect): Entry => ({ key, fingerprint, bounds });
test("retained damage preserves exact u64 identities old and new extents and complete flags", () => {
  const id = 9007199254740993n;
  const r = decode(native_window_policy(request(3, { baseline: [entry(id, 7n, [10, 20, 4, 6]), entry(id + 1n, 8n, [80, 30, 4, 5])], current: [entry(id, 9n, [12, 20, 4, 6]), entry(id + 2n, 8n, [120, 40, 4, 5])] })));
  assert.equal(r.valid, 1); assert.deepEqual(r.bounds, [10, 20, 114, 25]); assert.deepEqual(r.flags, [1, 0, 0, 0, 1, 1]); assert.equal(r.count, 3);
});
test("unchanged command reorder refuses refinement after preserving complete scratch state", () => {
  const a = entry(0n, 1n, [1, 2, 3, 4]), b = entry(18446744073709551615n, 2n, [10, 20, 3, 4]);
  const r = decode(native_window_policy(request(3, { baseline: [a, b], current: [b, a] })));
  assert.equal(r.valid, 0); assert.equal(r.bounds, null); assert.deepEqual(r.flags, [1, 1, 1, 1, 0, 0]);
});
test("cluster overflow picks first least-area growth and preserves insertion order", () => {
  const current = Array.from({ length: 9 }, (_, i) => entry(BigInt(i), 1n, [i * 20, 5, 3, 4]));
  const r = decode(native_window_policy(request(3, { current })));
  assert.equal(r.count, 8); assert.deepEqual(r.rects[7], [140, 5, 23, 4]); assert.deepEqual(r.rects[0], [0, 5, 3, 4]);
});
test("separate clusters avoid blur in the bounding gap but apron damage forces full replay", () => {
  const blur = { bounds: [40, 10, 10, 10] as Rect, radius: 3 };
  const refined = { refined: true, refinement: [10, 10, 82, 10] as Rect, rects: [[10, 10, 2, 2], [90, 10, 2, 2]] as Rect[], blurs: [blur] };
  const incremental = decode(native_window_policy(request(1, refined)));
  assert.equal(incremental.full, 0); assert.equal(incremental.count, 2);
  const full = decode(native_window_policy(request(1, { ...refined, overrides: [38, 10, 1, 1] })));
  assert.equal(full.full, 1); assert.equal(full.count, 0); assert.deepEqual(full.bounds, [0, 0, 800, 600]); assert.equal(full.written, 3);
});
test("integer-boundary surface clipping keeps aligned stored rectangles and drops offscreen clusters", () => {
  const r = decode(native_window_policy(request(2, { scale: 1.3, surface: [100, 80], bounds: [99, 1, 4, 3], rects: [[900, 900, 2, 2], [10, 20, 3, 4]] })));
  assert.equal(r.count, 0); assert.equal(r.written, 1); assert.ok(r.bounds); assert.ok(r.bounds[0]! + r.bounds[2]! <= 100.00001);
});
test("full repaint and effective-scale no ops preserve original unsnapped bounds", () => {
  const bounds: Rect = [-0, 0.125, 15.5, 8.25];
  const r = decode(native_window_policy(request(2, { full: true, bounds, rects: [bounds] })));
  assert.deepEqual(r.bounds, bounds); assert.deepEqual(r.rects, [bounds]); assert.equal(r.count, 1);
});
test("damage copied outputs survive sliced input and later calls", () => {
  const r = request(0, { changes: [[10, 20, -4, -6]] }), padded = new Uint8Array(r.length + 10); padded.set(r, 3);
  const output = native_window_policy(padded.subarray(3, 3 + r.length)), saved = output.slice();
  native_window_policy(request(0, { full: true })); assert.deepEqual(output, saved);
});
test("damage wire rejects truncation inconsistent counts optional flags and cluster capacities", () => {
  const r = request(0, { changes: [[10, 20, 4, 6]] });
  for (let i = 1; i < r.length; i++) assert.throws(() => native_window_policy(r.subarray(0, i)));
  assert.throws(() => native_window_policy(new Uint8Array([...r, 0])));
  for (const at of [1, 2, 3, 16, 36, 56, 76, 104, 108, 112, 116, 120, 124, 128]) { const bad = r.slice(); bad[at] = 255; assert.throws(() => native_window_policy(bad)); }
});
