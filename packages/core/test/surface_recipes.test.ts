import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = ["runtime_policy.ts", "control_appearance.ts", "control_content.ts", "surface_recipes.ts"].map(name => readFileSync(new URL(`../src/${name}`, import.meta.url), "utf8")).join("\n");
const { nscvSurfaceRecipes: derive } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport { nscvSurfaceRecipes }; ").toString("base64")}`);
function packet(op: number) {
  const b = new Uint8Array(560), w = new DataView(b.buffer); b.set([31, 1, op, 0]);
  [5, 7, 120, 60].forEach((value, i) => w.setFloat32(16 + i * 4, value, true));
  for (let i = 0; i < 4; i++) w.setFloat32(32 + i * 4, 6, true);
  for (const [at, value] of [[48, 14], [52, 8], [56, 16], [60, 6], [64, 40], [68, 2], [88, 2], [92, 4], [100, 1], [104, 1], [108, 10], [124, 2], [144, 6], [148, 4], [152, 10]]) w.setFloat32(at!, value!, true);
  for (let at = 160; at < 528; at += 16) { w.setFloat32(at, at / 1000, true); w.setFloat32(at + 12, 1, true); }
  b.fill(0, 464, 480); return b;
}
const word = (b: Uint8Array, at: number) => new DataView(b.buffer).getUint32(at, true);
const value = (b: Uint8Array, at: number) => new DataView(b.buffer).getFloat32(at, true);
const commands = (b: Uint8Array) => Array.from({ length: word(b, 4) }, (_, i) => [word(b, 64 + i * 128), word(b, 68 + i * 128)]);
test("surface recipes retain ordered shadow fill border and optional title", () => {
  const b = packet(2), w = new DataView(b.buffer); w.setUint32(4, 1, true);
  const out = derive(b); assert.deepEqual(commands(out), [[2, 1], [0, 2], [1, 3], [3, 4]]); assert.equal(value(out, 64 + 3 * 128 + 64), 104);
  assert.ok(out.subarray(64 + 4 * 128).every((x: number) => x === 0));
  b[2] = 3; w.setFloat32(172, 0.5, true); assert.deepEqual(commands(derive(b)), [[0, 2], [1, 3]]);
});
test("bubble ghost chrome and descendant ink follow explicit optional colors", () => {
  const b = packet(4), w = new DataView(b.buffer); b[12] = 4; assert.deepEqual(commands(derive(b)), []);
  w.setUint32(8, 3, true); assert.deepEqual(commands(derive(b)), [[0, 2], [1, 3]]);
  b[2] = 6; b[12] = 1; w.setUint32(8, 8, true); const out = derive(b); assert.equal(word(out, 8), 2);
  assert.deepEqual([...out.subarray(32, 48)], [...b.subarray(448, 464)]); assert.equal(value(out, 60), Math.fround(0.7));
});
test("reaction measurement is requested only after admission and yields complete copied geometry", () => {
  const b = packet(8), w = new DataView(b.buffer); w.setUint32(4, 513, true);
  assert.equal(word(derive(b), 8), 8); assert.deepEqual(commands(derive(b)), []);
  w.setUint32(4, 641, true); w.setFloat32(116, 40.25, true); b[13] = 2; const out = derive(b);
  assert.equal(word(out, 8), 4); assert.deepEqual(commands(out), [[0, 4], [0, 5], [3, 6]]); assert.equal(value(out, 16), 60); assert.equal(value(out, 24), 53);
  b.fill(0); assert.equal(value(out, 16), 60);
  const empty = packet(8); new DataView(empty.buffer).setUint32(4, 512, true); assert.equal(word(derive(empty), 8), 0);
});
test("accordion suppresses content after empty padding and tabs admit only positive underline widths", () => {
  const b = packet(9), w = new DataView(b.buffer); w.setFloat32(72, 100, true); w.setFloat32(80, 100, true); w.setUint32(4, 7, true);
  assert.deepEqual(commands(derive(b)), [[4, 2]]);
  b[2] = 11; w.setUint32(4, 16, true); w.setFloat32(100, 0, true); assert.deepEqual(commands(derive(b)), []);
  w.setFloat32(100, 1, true); assert.deepEqual(commands(derive(b)), [[6, 2]]);
});
test("unsnapped surface facts preserve raw exceptional palette and frame bytes", () => {
  const b = packet(1), w = new DataView(b.buffer); w.setUint32(16, 0x7f812345, true); w.setUint32(160, 0xff812345, true);
  const out = derive(b); assert.equal(word(out, 72), 0x7f812345); assert.equal(word(out, 104), 0xff812345); assert.equal(word(out, 200), 0x7f812345);
});
test("recipe headers reserved bytes and truncated packets reject", () => {
  for (const at of [0, 1, 2, 3, 6, 10, 12, 13, 14, 15, 528, 559]) { const b = packet(0); b[at] = 255; assert.throws(() => derive(b), /invalid surface recipe/); }
  assert.throws(() => derive(new Uint8Array(559)), /shape/); assert.throws(() => derive(new Uint8Array(561)), /shape/);
});

test("bubble radii retain the explicit native signaling-extrema capability", () => {
  const b = packet(5), w = new DataView(b.buffer); w.setUint32(4, 256, true); w.setUint32(112, 0xff812345, true);
  assert.equal(word(derive(b), 16), 0); b[15] = 16; assert.equal(word(derive(b), 16), 0xffc12345);
  w.setUint32(4, 0, true); w.setUint32(108, 0x7f812345, true); assert.equal(word(derive(b), 16), 0x7fc12345);
});
