import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = ["runtime_policy.ts", "control_content.ts"].map(name => readFileSync(new URL(`../src/${name}`, import.meta.url), "utf8")).join("\n");
const { nscvControlContent: derive } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport { nscvControlContent }; ").toString("base64")}`);
function packet(op: number) {
  const b = new Uint8Array(128), w = new DataView(b.buffer); b.set([30, 1, op, 0]);
  [5, 7, 120, 30].forEach((v, i) => w.setFloat32(16 + i * 4, v, true));
  w.setFloat32(48, 2, true); w.setFloat32(52, 14, true); w.setFloat32(56, 8, true); return b;
}
const values = (b: Uint8Array, at: number, count: number) => Array.from({length: count}, (_, i) => new DataView(b.buffer).getFloat32(at + i * 4, true));
test("measured icon blocks center and preserve leading and trailing label bounds", () => {
  const b = packet(11), w = new DataView(b.buffer); w.setUint32(4, 8, true);
  w.setFloat32(60, 40, true); w.setFloat32(64, 16, true); w.setFloat32(68, 6, true);
  let out = derive(b); assert.deepEqual(values(out, 8, 4), [34, 14, 16, 16]); assert.deepEqual(values(out, 24, 4), [56, 7, 61, 30]);
  w.setUint32(4, 12, true); out = derive(b); assert.deepEqual(values(out, 8, 4), [80, 14, 16, 16]); assert.deepEqual(values(out, 24, 4), [34, 7, 40, 30]);
  w.setUint32(4, 0, true); out = derive(b); assert.deepEqual(values(out, 8, 4), [57, 14, 16, 16]); assert.equal(new DataView(out.buffer).getUint32(4, true), 1);
});
test("crisp hairlines retain metadata while reducing only eligible device widths", () => {
  const b = packet(10), w = new DataView(b.buffer); w.setUint32(4, 1, true); w.setFloat32(48, 1.5, true); w.setFloat32(88, 1, true);
  for (let i = 0; i < 4; i++) w.setFloat32(32 + i * 4, 6, true);
  const out = derive(b); assert.equal(values(out, 64, 1)[0], Math.fround(1 / 1.5));
  w.setFloat32(88, 3, true); const unsnapped = derive(b); assert.deepEqual(Array.from(unsnapped.subarray(8, 24)), Array.from(b.subarray(16, 32)));
});
test("disabled snapping preserves raw point and radius payloads", () => {
  const b = packet(2), w = new DataView(b.buffer); w.setUint32(16, 0x7f812345, true); w.setUint32(20, 0x80000000, true);
  assert.deepEqual(Array.from(derive(b).subarray(56, 64)), Array.from(b.subarray(16, 24)));
  b[2] = 10; w.setUint32(32, 0xff812345, true); assert.deepEqual(Array.from(derive(b).subarray(40, 56)), Array.from(b.subarray(32, 48)));
});
test("label layout follows the bounded one-pixel minimum and measured baseline", () => {
  const b = packet(4), w = new DataView(b.buffer); assert.deepEqual(values(derive(b), 64, 2), [104, 17.5]);
  w.setFloat32(24, 10, true); assert.deepEqual(values(derive(b), 64, 2), [1, 17.5]);
  b[2] = 3; assert.deepEqual(values(derive(b), 56, 2), [13, 27.25]);
});
test("content packets reject malformed headers reserved bytes and truncation", () => {
  for (const at of [0, 1, 2, 3, 8, 9, 10, 11, 12, 92, 127]) { const b = packet(0); b[at] = 255; assert.throws(() => derive(b), /invalid control content/); }
  assert.throws(() => derive(packet(0).subarray(0, 127)), /shape/);
  assert.throws(() => derive(new Uint8Array(129)), /shape/);
});
test("editable layout keeps clipping and chooses wrap from code and field facts", () => {
  const b = packet(15), w = new DataView(b.buffer); w.setFloat32(64, 24, true);
  assert.deepEqual(values(derive(b), 64, 2), [88, 17.5]);
  b[8] = 2; assert.equal(new DataView(derive(b).buffer).getUint32(72, true), 1);
  w.setUint32(4, 12, true); assert.equal(new DataView(derive(b).buffer).getUint32(72, true), 0);
  w.setUint32(4, 4, true); assert.equal(new DataView(derive(b).buffer).getUint32(72, true), 1);
});
test("clear targets reserve the trailing icon without shrinking code gutters", () => {
  const b = packet(18), w = new DataView(b.buffer);
  w.setUint32(4, 16, true); assert.equal(values(derive(b), 64, 1)[0], 18);
  w.setUint32(4, 20, true); assert.equal(values(derive(b), 64, 1)[0], 0);
  b[2] = 16; assert.deepEqual(values(derive(b), 8, 4), [107, 17, 10, 10]);
});
