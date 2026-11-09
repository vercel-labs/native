import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const components = readFileSync(new URL("../src/view_components.ts", import.meta.url), "utf8");
const textPolicy = components.slice(components.indexOf("function nscvTextReconcile("), components.indexOf("/** New input: tag 6"));
const source = textPolicy + readFileSync(new URL("../src/widget_reconcile.ts", import.meta.url), "utf8");
const { nscvWidgetReconcile: plan } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport { nscvWidgetReconcile };").toString("base64")}`);
function packet(kind: number, admission = 9, facts = 0, selection = 0): Uint8Array {
  const b = new Uint8Array(72), w = new DataView(b.buffer);
  b[0] = 93; w.setUint32(4, 1, true); b.set([kind, admission, facts], 8); b[28] = selection;
  w.setFloat32(12, 0.25, true); w.setFloat32(16, 0.25, true); w.setFloat32(20, 0.75, true); w.setFloat32(24, 48, true);
  return b;
}
const flags = (b: Uint8Array) => new DataView(plan(b).buffer).getUint32(8, true);
test("reconciliation admission and exclusive source flips cover all control families", () => {
  for (const kind of [14, 32, 41, 42, 44, 46, 47, 48, 49, 50]) {
    assert.equal(flags(packet(kind, 9, 4)), 3);
    for (const admission of [0, 8, 11, 13]) assert.equal(flags(packet(kind, admission, 4)), 0);
  }
  for (const kind of [14, 41, 42, 44, 46, 48]) {
    assert.equal(flags(packet(kind, 25, 2 | 4)), 1);
    assert.equal(flags(packet(kind, 25, 1)), 3);
  }
  assert.equal(flags(packet(32, 9, 2 | 4)), 1);
});
test("text state and exact opaque caret offsets coordinate affinity and cache restoration", () => {
  assert.equal(flags(packet(39, 33, 64)), 1024 | 16 | 32 | 64);
  assert.equal(flags(packet(39, 33, 0)), 1024);
  assert.equal(flags(packet(26, 33, 48)), 64);
  assert.equal(flags(packet(26, 33, 48, 1)), 0);
  assert.equal(flags(packet(39, 97, 64)), 1024 | 16 | 32 | 64 | 256 | 512);
  assert.equal(flags(packet(39, 225, 64)), 1024 | 16 | 32 | 64 | 256);
  const b = packet(39, 33, 16, 1 | 8 | 16);
  const w = new DataView(b.buffer);
  for (const at of [32, 40, 48, 56]) w.setBigUint64(at, 9007199254740993n, true);
  assert.equal(flags(b), 1024 | 32 | 128);
  w.setBigUint64(56, 9007199254740992n, true);
  assert.equal(flags(b), 1024 | 32);
});
test("plans own their bytes and reject every truncation and reserved field", () => {
  const b = packet(39, 33, 64), before = b.slice(), result = plan(b);
  assert.deepEqual(b, before); b.fill(0); assert.equal(new DataView(result.buffer).getUint32(8, true), 1136);
  for (let n = 0; n < before.length; n++) assert.throws(() => plan(before.subarray(0, n)));
  for (const at of [1, 2, 3, 11, 29, 30, 31, 64, 68]) { const changed = before.slice(); changed[at] = 1; assert.throws(() => plan(changed)); }
});
test("scalar restoration follows native clamp and max for non-finite and signed-zero values", () => {
  for (const [input, expected] of [[NaN, 1], [-Infinity, 0], [Infinity, 1], [-0, 0], [0.125, 0.125]] as const) {
    const b = packet(51), w = new DataView(b.buffer); w.setFloat32(20, input, true);
    assert.equal(flags(b), 4); assert.ok(Object.is(new DataView(plan(b).buffer).getFloat32(12, true), expected));
  }
  const b = packet(16); new DataView(b.buffer).setFloat32(20, NaN, true);
  assert.equal(new DataView(plan(b).buffer).getFloat32(12, true), 48);
});
