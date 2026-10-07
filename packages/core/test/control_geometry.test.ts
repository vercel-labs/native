import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = ["runtime_policy.ts", "control_geometry.ts"].map(name => readFileSync(new URL(`../src/${name}`, import.meta.url), "utf8")).join("\n");
const { nscvControlGeometry: derive } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport { nscvControlGeometry }; ").toString("base64")}`);
function packet(op: number) {
  const b = new Uint8Array(160), w = new DataView(b.buffer);
  b.set([29, 1, op, 0]); b[8] = 1;
  [5, 7, 120, 30].forEach((v, i) => w.setFloat32(16 + i * 4, v, true));
  w.setFloat32(32, 2, true); w.setFloat32(44, 4, true); w.setFloat32(48, 12, true); w.setFloat32(52, 12, true);
  return b;
}
const float = (b: Uint8Array, at: number) => new DataView(b.buffer, b.byteOffset, b.byteLength).getFloat32(at, true);
const word = (b: Uint8Array, at: number) => new DataView(b.buffer, b.byteOffset, b.byteLength).getUint32(at, true);
test("slider endpoints remain bounded and empty ranges do not draw", () => {
  const b = packet(2), w = new DataView(b.buffer);
  for (const [value, x, active] of [[-1, 5, false], [0, 5, false], [0.5, 59, true], [1, 113, true], [2, 113, true]]) {
    w.setFloat32(36, value!, true); const r = derive(b);
    assert.equal(float(r, 24), x); assert.equal((word(r, 4) & 8) !== 0, active);
    assert.equal(float(r, 88), Math.max(0, Math.min(1, value!)));
  }
});
test("scrollbar corner reservations account for the other axis", () => {
  const b = packet(5), w = new DataView(b.buffer); w.setUint32(4, 48, true);
  for (const at of [88, 104]) w.setFloat32(at, 30, true);
  for (const at of [92, 108]) w.setFloat32(at, 120, true);
  assert.equal(float(derive(b), 88), 6);
  w.setUint32(4, 16, true); assert.equal(float(derive(b), 88), 0);
});
test("group shape preserves exact radius words including signaling NaNs", () => {
  const b = packet(8), w = new DataView(b.buffer);
  [0x80000000, 0x7f812345, 0xffc12345, 0x3f800000].forEach((v, i) => w.setUint32(132 + i * 4, v, true));
  assert.deepEqual(Array.from(derive(b).subarray(8, 24)), Array.from(b.subarray(132, 148)));
  w.setUint32(80, 1, true); assert.deepEqual([8, 12, 16, 20].map(at => word(derive(b), at)), [0x80000000, 0, 0, 0x3f800000]);
});
test("geometry packets reject truncated children unsupported operations and reserved bytes", () => {
  const b = packet(6); new DataView(b.buffer).setUint32(12, 1, true);
  assert.throws(() => derive(b), /header/);
  for (const at of [0, 1, 2, 3, 8, 9, 10, 11, 148, 159]) { const bad = packet(0); bad[at] = 255; assert.throws(() => derive(bad), /invalid control geometry/); }
  assert.throws(() => derive(packet(0).subarray(0, 159)), /shape/);
});

test("slider refuses unordered native clamp bounds", () => {
  const b = packet(2); new DataView(b.buffer).setFloat32(16, NaN, true);
  assert.throws(() => derive(b), /unordered control geometry bounds/);
});

test("signaling extrema follow the native scalar descriptor", () => {
  const b = packet(1), w = new DataView(b.buffer); w.setUint32(24, 0x7f812345, true);
  assert.equal(float(derive(b), 16), 52.5);
  b[10] = 2; assert.equal(word(derive(b), 16), 0x7fc12345);
});
