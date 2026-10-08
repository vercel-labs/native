import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const helpers = `function nscvShellMin(a,b){return Number.isNaN(a)?b:Number.isNaN(b)?a:Math.min(a,b);} function nscvShellMax(a,b){return Number.isNaN(a)?b:Number.isNaN(b)?a:Math.max(a,b);}`;
const source = helpers + stripTypeScriptTypes(readFileSync(new URL("../src/text_span_queries.ts", import.meta.url), "utf8"));
const { nscvTextSpanQueries: plan, nscvTextSpanBounds: bounds, nscvSpanLineFloat: lineFloat } = await import(`data:text/javascript;base64,${Buffer.from(source + "\nexport {nscvTextSpanQueries,nscvTextSpanBounds,nscvSpanLineFloat};").toString("base64")}`);
function clipping(text: string, width: number, left: number, right: number): Uint8Array {
  const raw = new TextEncoder().encode(text), runAt = 528, advanceAt = runAt + 160 * 32 + raw.length, paragraphAt = advanceAt + raw.length * 4;
  const b = new Uint8Array(paragraphAt + raw.length), v = new DataView(b.buffer); b.set([56, 1, 0, 0]);
  for (const [at, value] of [[12, b.length], [16, paragraphAt], [24, 512], [28, 1], [32, runAt], [36, advanceAt], [40, raw.length], [512, paragraphAt], [516, raw.length], [runAt + 4, runAt + 160 * 32], [runAt + 8, raw.length]]) v.setUint32(at!, value!, true);
  for (const [at, value] of [[60, width], [64, left], [68, right]]) v.setFloat32(at!, value!, true);
  b.set(raw, runAt + 160 * 32); b.set(raw, paragraphAt); return b;
}
function clip(input: Uint8Array, advances?: number[]): { first: number; last: number; x: number; present: boolean; calls: number[] } {
  const b = input.slice(), v = new DataView(b.buffer), calls: number[] = [];
  for (let count = 0; count < 1000; count++) {
    const original = b.slice(), r = plan(b); assert.equal(r.length, 512); assert.deepEqual(b, original);
    const q = new DataView(r.buffer); if (r[3] === 2) return { first: q.getUint32(116, true), last: q.getUint32(120, true), x: q.getFloat32(128, true), present: q.getUint32(112, true) === 1, calls };
    b.set(r); const action = q.getUint32(80, true);
    if (action === 2) { v.setUint32(104, advances ? 1 : 0, true); advances?.forEach((value, i) => v.setFloat32(v.getUint32(36, true) + i * 4, value, true)); }
    else { assert.equal(action, 3); const prefix = q.getUint32(92, true); calls.push(prefix); v.setFloat32(100, prefix * 5, true); }
    v.setUint32(96, 1, true);
  }
  throw new Error("clipping did not finish");
}
test("rich-text clipping keeps complete clusters and borrowed source ownership", () => {
  const b = clipping("abcdefghij", 50, 12, 27), before = b.slice();
  assert.deepEqual(clip(b, Array(10).fill(5)), { first: 1, last: 7, x: 5, present: true, calls: [] });
  assert.deepEqual(b, before);
  const contextual = clip(b); assert.equal(contextual.present, true); assert.equal(contextual.first, 1); assert.equal(contextual.last, 7); assert.equal(contextual.x, 5); assert.ok(contextual.calls.length > 0);
  assert.equal(clip(clipping("", 0, 1, 2)).present, false);
  assert.equal(clip(clipping("abc", 15, NaN, 1)).last, 3);
  assert.equal(clip(clipping("~~~~", 0, 2, 5), [0, 0, 0, 0]).last, 4);
});
test("rich-text continuations reject corrupt source metadata, reserved bytes and acknowledgments", () => {
  const b = clipping("abc", 15, 1, 8), v = new DataView(b.buffer);
  for (const at of [12, 24, 28, 32, 36, 40, 512, 516, 524]) { const bad = b.slice(); new DataView(bad.buffer).setUint32(at, 4294967295, true); assert.throws(() => plan(bad)); }
  const r = plan(b); b.set(r); assert.throws(() => plan(b), /reply missing/);
  v.setUint32(96, 1, true); b[400] = 1; assert.throws(() => plan(b), /reserved/);
  b[400] = 0; v.setUint32(108, 25, true); assert.throws(() => plan(b), /reply phase/);
});
test("rich-text bounds preserve exact 64-bit line rounding beyond f64 halfway loss", () => {
  const base = 1n << 63n, halfway = base + (1n << 39n), above = halfway + 1n;
  const float = (value: bigint) => lineFloat(Number(value & 0xffffffffn), Number(value >> 32n));
  assert.equal(float(halfway), Math.fround(Number(base)));
  assert.equal(float(above), Math.fround(Number(base + (1n << 40n))));
  assert.equal(float((1n << 64n) - 1n), Math.fround(2 ** 64));
  const b = new Uint8Array(24 + 3 * 24), v = new DataView(b.buffer); b.set([57, 1]); v.setUint32(4, 3, true); v.setBigUint64(8, 0xffffffffffffffffn, true); v.setFloat32(16, 10, true);
  [[0xffffffffffffffffn, 0n, -2, 12], [1n, 0n, 999, 999], [0xffffffffffffffffn, 2n, 4, 8]].forEach(([id, line, x, width], i) => { const at = 24 + i * 24; v.setBigUint64(at, id as bigint, true); v.setBigUint64(at + 8, line as bigint, true); v.setFloat32(at + 16, x as number, true); v.setFloat32(at + 20, width as number, true); });
  const r = new DataView(bounds(b).buffer); assert.equal(r.getUint32(0, true), 1); assert.deepEqual([4, 8, 12, 16].map(at => r.getFloat32(at, true)), [-2, 0, 14, 30]);
  assert.throws(() => bounds(b.subarray(1))); assert.throws(() => bounds(b.subarray(0, b.length - 1)));
  v.setFloat32(16, 0, true);
  assert.deepEqual(Array.from(new Uint8Array(bounds(b).buffer).subarray(4)), Array(16).fill(0));
});
