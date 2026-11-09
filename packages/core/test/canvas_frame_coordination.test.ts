import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = ["runtime_policy.ts", "canvas_frame_coordination.ts"].map(name => readFileSync(new URL(`../src/${name}`, import.meta.url), "utf8")).join("\n");
const { nscvCanvasFrameCoordination: plan, native_window_policy: dispatch } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport {nscvCanvasFrameCoordination};").toString("base64")}`);
function request(mode: number, flags = 0): Uint8Array {
  const bytes = new Uint8Array(320), w = new DataView(bytes.buffer);
  bytes.set([75, 1, mode, 0]); w.setUint32(4, flags, true);
  for (const at of [8, 16, 24, 40, 52]) { w.setFloat32(at, 64.25, true); w.setFloat32(at + 4, 48.5, true); }
  for (const at of [32, 36, 48, 60]) w.setFloat32(at, 1.75, true);
  return bytes;
}
function checked(bytes: Uint8Array): DataView {
  const before = bytes.slice(), backing = new Uint8Array(349); backing.set(bytes, 13);
  const result = plan(backing.subarray(13, 333));
  assert.deepEqual(bytes, before); assert.deepEqual(result, dispatch(bytes));
  const copy = result.slice(); backing.fill(255); bytes.fill(255); assert.deepEqual(result, copy);
  assert.equal(result.byteLength, 64); assert.equal(new DataView(result.buffer).getUint32(0, true), 1);
  assert.deepEqual(result.slice(48), new Uint8Array(16));
  return new DataView(result.buffer);
}
test("frame defaults preserve all source choices and complete 64-bit resource and budget observations", () => {
  assert.equal(checked(request(0)).getUint32(4, true), 7);
  for (let field = 0; field < 23; field++) for (const value of [1n, 0x100000000n, 0xffffffffffffffffn]) {
    const bytes = request(0); new DataView(bytes.buffer).setBigUint64(128 + field * 8, value, true);
    assert.equal(checked(bytes).getUint32(4, true), 3);
  }
  for (const at of [96, 104]) { const bytes = request(0); new DataView(bytes.buffer).setBigUint64(at, 0x100000000n, true); assert.equal(checked(bytes).getUint32(4, true), at === 96 ? 6 : 5); }
  for (const [width, gpuWidth, expected] of [[64.25, 7, 64.25], [0, 7, 7], [-1, -1, 64.25], [NaN, 7, NaN], [0, NaN, NaN]]) {
    const bytes = request(0), w = new DataView(bytes.buffer); w.setFloat32(8, width, true); w.setFloat32(16, gpuWidth, true);
    assert.equal(checked(bytes).getFloat32(8, true), expected);
  }
});
test("frame admission preserves exact u64 revisions, override counts and float32 equality", () => {
  assert.equal(checked(request(1, 2)).getUint32(4, true), 8);
  for (const revision of [0x100000000n, 9007199254740993n, 0xffffffffffffffffn]) {
    const bytes = request(1, 2), w = new DataView(bytes.buffer); w.setBigUint64(64, revision, true); w.setBigUint64(72, revision - 1n, true);
    assert.equal(checked(bytes).getUint32(4, true), 80);
  }
  for (const at of [80, 88]) { const bytes = request(1, 2); new DataView(bytes.buffer).setBigUint64(at, 0x100000000n, true); assert.equal(checked(bytes).getUint32(4, true), 0); }
  for (const at of [8, 12, 32, 40, 44, 48]) { const bytes = request(1, 2); new DataView(bytes.buffer).setFloat32(at, NaN, true); assert.equal(checked(bytes).getUint32(4, true), 160); }
  const signed = request(1, 2), w = new DataView(signed.buffer); w.setFloat32(8, -0, true); w.setFloat32(40, 0, true); assert.equal(checked(signed).getUint32(4, true), 8);
});
test("frame repaint waits for current unkeyed observation and retains exact refinement eligibility", () => {
  for (let flags = 0; flags < 32; flags++) {
    const bytes = request(2, flags), w = new DataView(bytes.buffer); w.setBigUint64(64, 1n, true);
    const full = (flags & 1) !== 0 || (flags & 2) === 0 || (flags & 12) !== 0;
    assert.equal(checked(bytes).getUint32(4, true), full ? 128 : (flags & 16) !== 0 ? 256 : 0);
  }
  for (const at of [52, 56, 60]) { const bytes = request(2, 18), w = new DataView(bytes.buffer); w.setBigUint64(64, 1n, true); w.setFloat32(at, NaN, true); assert.equal(checked(bytes).getUint32(4, true), 0); }
});
test("full repaint bounds normalize negative extents and preserve all copied payload bits", () => {
  const negative = request(3), w = new DataView(negative.buffer); w.setFloat32(8, -64.25, true);
  const out = checked(negative); assert.equal(out.getUint32(4, true), 512); assert.deepEqual([20, 24, 28, 32].map(at => out.getFloat32(at, true)), [-64.25, 0, 64.25, 48.5]);
  const nan = request(3); new DataView(nan.buffer).setUint32(8, 0xffc12345, true); assert.equal(checked(nan).getUint32(28, true), 0xffc12345);
  const fallback = request(3, 64), fw = new DataView(fallback.buffer); fw.setFloat32(8, -0, true);
  const bits = [0xffc12345, 0x80000000, 0x3f800001, 0x7f800000]; bits.forEach((value, i) => fw.setUint32(112 + i * 4, value, true));
  const fo = checked(fallback); assert.equal(fo.getUint32(4, true), 512); assert.deepEqual([20, 24, 28, 32].map(at => fo.getUint32(at, true)), bits);
});
test("presentation and screenshot scales preserve optional precedence and native empty-size behavior", () => {
  for (const mode of [4, 6]) for (const wanted of [0, -0, -1, NaN, Infinity, 2.5]) for (const fallback of [0, -1, NaN, Infinity, 1.75]) {
    const bytes = request(mode, 32), w = new DataView(bytes.buffer); w.setFloat32(32, wanted, true); w.setFloat32(36, fallback, true);
    assert.equal(checked(bytes).getFloat32(16, true), Number.isFinite(wanted) && wanted > 0 ? wanted : Number.isFinite(fallback) && fallback > 0 ? fallback : 1);
  }
  const absent = request(4), w = new DataView(absent.buffer); w.setFloat32(32, 2.5, true); assert.equal(checked(absent).getFloat32(16, true), 1.75);
  const screenshot = request(6), sw = new DataView(screenshot.buffer); sw.setFloat32(16, 0, true); sw.setFloat32(24, 99.25, true); assert.equal(checked(screenshot).getFloat32(8, true), 99.25);
});
test("pixel dimensions use float32 products, exact ceilings and the complete extent cap", () => {
  for (const [width, height, scale] of [[64.25, 48.5, 1.75], [16384, 16384, 1], [1.0000001192092896, 1, 1], [0, 1, 1], [Infinity, 1, 0], [16384, 1, 2], [NaN, 1, 1], [1, 1, NaN]]) {
    const bytes = request(5), w = new DataView(bytes.buffer); w.setFloat32(8, width, true); w.setFloat32(12, height, true); w.setFloat32(32, scale, true);
    const s = Number.isFinite(scale) && scale > 0 ? scale : 1, a = Math.fround(Math.fround(width) * Math.fround(s)), b = Math.fround(Math.fround(height) * Math.fround(s));
    const valid = Number.isFinite(a) && Number.isFinite(b) && a > 0 && b > 0 && a <= 16384 && b <= 16384, out = checked(bytes);
    assert.equal(out.getUint32(4, true), valid ? 0 : 1024);
    assert.deepEqual([36, 40, 44].map(at => out.getUint32(at, true)), valid ? [Math.ceil(a), Math.ceil(b), Math.ceil(a) * Math.ceil(b) * 4] : [0, 0, 0]);
  }
});
test("frame coordination rejects malformed headers and reserved fields", () => {
  for (const length of [0, 3, 319, 321]) assert.throws(() => plan(new Uint8Array(length)), /invalid/);
  for (const [at, value] of [[0, 0], [1, 0], [2, 7], [3, 1], [4, 128], [312, 1], [319, 1]]) { const bytes = request(0); bytes[at] = value; assert.throws(() => plan(bytes), /invalid/); }
});
