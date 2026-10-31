import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = ["runtime_policy.ts", "widget_presentation.ts", "widget_paint_walk.ts"].map(p => readFileSync(new URL(`../src/${p}`, import.meta.url), "utf8")).join("\n");
const { nscvWidgetPaintWalk: derive } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport { nscvWidgetPaintWalk };").toString("base64")}`);
function packet(kinds: number[], parents: (number | null)[], layers: (number | null)[]) {
  const b = new Uint8Array(80 + kinds.length * 96), w = new DataView(b.buffer);
  b.set([28, 1, 0, 0]); w.setUint32(4, kinds.length, true); w.setUint32(16, 1, true); w.setUint32(76, 0x7fc00000, true);
  [0, 100, 200, 300].forEach((v, i) => w.setInt32(20 + i * 4, v, true));
  kinds.forEach((kind, i) => {
    const at = 80 + i * 96;
    w.setUint32(at, kind, true); w.setUint32(at + 4, (parents[i] === null ? 0 : 1) | (layers[i] === null ? 0 : 8), true);
    w.setUint32(at + 8, parents[i] ?? 0, true); w.setUint32(at + 16, i + 1, true); w.setUint32(at + 24, 1000 + i, true); w.setUint32(at + 32, parents[i] === null ? 0 : 1, true); w.setInt32(at + 40, layers[i] ?? 0, true);
    [0, 0, 100, 100].forEach((v, j) => w.setFloat32(at + 44 + j * 4, v, true));
    [1, 0, 0, 1, 0, 0].forEach((v, j) => w.setFloat32(at + 60 + j * 4, v, true)); w.setFloat32(at + 84, 1, true);
  });
  return b;
}
const word = (b: Uint8Array, at: number) => new DataView(b.buffer, b.byteOffset, b.byteLength).getUint32(at, true);
test("paint traversal orders ties by retained slot and stamps visible group positions", () => {
  const b = packet([9, 31, 31, 31], [null, 0, 0, 0], [null, 20, -1, 20]);
  const r = derive(b);
  assert.equal(word(r, 8), 0); assert.equal(word(r, 24 + 12), 2);
  assert.equal(word(r, 24 + 2 * 120 + 8), 1); assert.equal(word(r, 24 + 1 * 120 + 8), 3);
  assert.deepEqual([1, 2, 3].map(i => word(r, 24 + i * 120 + 28)), [1, 2, 3]);
  new DataView(b.buffer).setUint32(80 + 2 * 96 + 4, 13, true);
  assert.deepEqual([1, 3].map(i => word(derive(b), 24 + i * 120 + 28)), [1, 3]);
});
test("surface layers inherit modal strata while explicit layers remain authoritative", () => {
  const b = packet([19, 40, 24], [null, 0, 0], [500, null, -10]), w = new DataView(b.buffer);
  w.setUint32(80 + 96 + 4, 3, true); w.setUint32(80 + 192 + 4, 11, true);
  const r = derive(b); assert.equal(word(r, 12), 2); assert.equal(word(r, 24 + 120 + 4), 500);
  assert.equal(word(r, 24 + 2 * 120 + 16), 0); assert.equal(word(r, 24 + 16), 1);
});
test("logical menu focus and focus visible rings project separately from preview baked state", () => {
  const b = packet([41, 31], [null, null], [null, null]), w = new DataView(b.buffer);
  w.setUint32(16, 7, true); w.setUint32(36, 1, true); w.setUint32(44, 2, true);
  const r = derive(b);
  assert.equal(word(r, 24 + 32) & 1, 1); assert.equal(word(r, 24 + 120 + 32) & 1, 1);
  assert.equal(word(r, 24 + 76) & 1, 0); assert.equal(word(r, 24 + 120 + 76) & 1, 0);
});
test("paint traversal accepts forward and invalid full width parents and rejects cycles or malformed packets", () => {
  const b = packet([26, 22], [1, null], [null, null]); assert.equal(word(derive(b), 24 + 120 + 12), 0);
  const w = new DataView(b.buffer); w.setUint32(80 + 12, 1, true); assert.equal(word(derive(b), 24 + 120 + 12), 0xffffffff);
  w.setUint32(80 + 12, 0, true); w.setUint32(80 + 96 + 4, 1, true); assert.throws(() => derive(b), /cycle/);
  const valid = packet([26], [null], [null]);
  for (const at of [1, 2, 3, 16, 76, 80, 84]) { const bad = valid.slice(); if (at === 76) new DataView(bad.buffer).setUint32(at, 0, true); else if (at === 16 || at === 84) new DataView(bad.buffer).setUint32(at, 0xffffffff, true); else bad[at] = 255; assert.throws(() => derive(bad), /invalid paint walk/); }
  assert.throws(() => derive(valid.subarray(0, valid.length - 1)), /shape/);
});

test("invalid-operation NaNs use the explicit target word without rewriting operand payloads", () => {
  for (const nan of [0x7fc00000, 0xffc00000]) for (const scalar of [0, 2]) {
    const b = packet([26], [null], [null]), w = new DataView(b.buffer);
    b[3] = scalar; w.setUint32(76, nan, true); w.setFloat32(80 + 64, Infinity, true);
    const r = derive(b); assert.equal(word(r, 24 + 32 + 20), nan); assert.equal(word(r, 24 + 32 + 24), scalar === 0 ? nan : (nan ^ 0x80000000) >>> 0);
  }
});

test("signaling NaN opacity follows the supplied target clamp descriptor", () => {
  for (const flag of [0, 1]) {
    const b = packet([26], [null], [null]), w = new DataView(b.buffer); b[3] = flag; w.setUint32(80 + 84, 0x7f812345, true);
    const r = derive(b); assert.equal(new DataView(r.buffer).getFloat32(24 + 32 + 4, true), flag === 0 ? 1 : 0);
  }
});
