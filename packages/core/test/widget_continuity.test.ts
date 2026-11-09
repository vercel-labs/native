import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = readFileSync(new URL("../src/widget_continuity.ts", import.meta.url), "utf8");
const { nscvWidgetContinuity: plan } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport { nscvWidgetContinuity };").toString("base64")}`);
function packet(mode: number, facts: readonly number[]): Uint8Array {
  const b = new Uint8Array(8 + facts.length * 24), w = new DataView(b.buffer);
  b[0] = 95; b[1] = mode; w.setUint32(4, facts.length, true);
  facts.forEach((flags, i) => { b[8 + i * 24] = flags; });
  return b;
}
test("rebuild continuity retains velocities independently and admits exact source overlays", () => {
  for (let facts = 0; facts < 256; facts++) for (const mode of [0, 1]) {
    const b = packet(mode, [facts]), w = new DataView(b.buffer);
    w.setFloat32(12, -0, true); w.setFloat32(20, 0, true);
    w.setFloat32(16, 7.25, true); w.setFloat32(24, 8.25, true);
    const expected = mode === 1 ? (facts & 160) === 160 ? 2 : 0 :
      ((facts & 96) === 96 ? 1 : 0) | ((facts & 23) === 23 ? 4 : 0);
    assert.deepEqual([...plan(b).subarray(8)], [expected]);
  }
  const b = packet(0, [255]), w = new DataView(b.buffer);
  w.setFloat32(12, NaN, true); w.setFloat32(20, NaN, true);
  w.setFloat32(16, Infinity, true); w.setFloat32(24, Infinity, true);
  assert.equal(plan(b)[8], 9);
});
test("continuity plans reject malformed boundaries and own their results", () => {
  const b = packet(0, [255]);
  const result = plan(b); b.fill(0); assert.equal(result[8], 13);
  const valid = packet(0, [255]);
  for (let n = 0; n < valid.length; n++) assert.throws(() => plan(valid.subarray(0, n)));
  for (const at of [1, 2, 3, 9, 10, 11, 28, 31]) {
    const changed = valid.slice(); changed[at] = 2; assert.throws(() => plan(changed));
  }
  assert.equal(plan(packet(1, [])).length, 8);
  assert.deepEqual([...plan(packet(1, Array(1024).fill(160))).subarray(8)], Array(1024).fill(2));
  assert.throws(() => plan(packet(1, Array(1025).fill(160))));
});
