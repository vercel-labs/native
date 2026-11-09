import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = ["runtime_policy.ts", "widget_presentation.ts"].map(p => readFileSync(new URL(`../src/${p}`, import.meta.url), "utf8")).join("\n");
const { nscvWidgetPresentation: derive } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport { nscvWidgetPresentation };").toString("base64")}`);
function packet(parent = 0, flags = 1, transform = [1, 0, 0, 1, 0, 0]) {
  const b = new Uint8Array(192), w = new DataView(b.buffer);
  b.set([27, 1, 1, 0]); w.setUint32(4, 2, true);
  [0, 0, 100, 100].forEach((v, i) => w.setFloat32(64 + 24 + i * 4, v, true));
  w.setUint32(64, 6, true);
  [1, 0, 0, 1, 0, 0].forEach((v, i) => w.setFloat32(64 + 40 + i * 4, v, true));
  w.setUint32(128, 26, true); w.setUint32(132, flags | 8, true); w.setUint32(136, parent, true);
  [80, 80, 50, 50].forEach((v, i) => w.setFloat32(128 + 24 + i * 4, v, true));
  transform.forEach((v, i) => w.setFloat32(128 + 40 + i * 4, v, true));
  return b;
}
function visible(b: Uint8Array) { const w = new DataView(b.buffer); return w.getUint32(56 + 152 + 112, true) === 0 ? null : [0, 1, 2, 3].map(i => w.getFloat32(56 + 152 + 116 + i * 4, true)); }
test("presentation clips spans in local space and hoists anchored roots", () => {
  assert.deepEqual(visible(derive(packet())), [80, 80, 20, 20]);
  assert.deepEqual(visible(derive(packet(0, 3))), [80, 80, 20, 20]);
  assert.deepEqual(visible(derive(packet(0, 1, [1, 0, 0, 1, 10, 10]))), [80, 80, 10, 10]);
  assert.equal(visible(derive(packet(0, 1, [0, 0, 0, 0, 0, 0]))), null);
});
test("present invalid full-width parents do not become roots", () => {
  for (const p of [0xffffffff, 2]) assert.equal(visible(derive(packet(p))), null);
  const b = packet(); new DataView(b.buffer).setUint32(140, 1, true); assert.equal(visible(derive(b)), null);
  const result = derive(packet(0xffffffff, 0)); assert.deepEqual(visible(result), [80, 80, 50, 50]);
});
test("malformed presentation packets fail before output", () => {
  const valid = packet();
  for (const at of [1, 2, 3, 12, 60, 64, 132]) { const b = valid.slice(); b[at] = 255; assert.throws(() => derive(b), /invalid presentation/); }
  assert.throws(() => derive(valid.subarray(0, 191)), /invalid presentation/);
});
