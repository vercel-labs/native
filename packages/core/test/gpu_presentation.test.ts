import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = ["runtime_policy.ts", "gpu_presentation.ts"].map(name => readFileSync(new URL(`../src/${name}`, import.meta.url), "utf8")).join("\n");
const { nscvGpuPresentation: plan, native_window_policy: dispatch } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport {nscvGpuPresentation};").toString("base64")}`);
function request(phase = 0, outcome = 0, facts = 15, count = 4, upserts = 1, generation = 0n): Uint8Array {
  const bytes = new Uint8Array(64), w = new DataView(bytes.buffer);
  bytes.set([74, 1, phase, outcome]); w.setUint32(4, facts, true); w.setUint32(8, count, true); w.setUint32(12, upserts, true); w.setBigUint64(16, generation, true);
  for (const at of [24, 36]) { w.setFloat32(at, 800.25, true); w.setFloat32(at + 4, 600.5, true); w.setFloat32(at + 8, 1.75, true); }
  return bytes;
}
function checked(bytes: Uint8Array): number[] {
  const before = bytes.slice(), result = plan(bytes);
  assert.deepEqual(bytes, before); assert.deepEqual(result, dispatch(bytes));
  const copy = result.slice(); bytes.fill(255); assert.deepEqual(result, copy);
  return Array.from(new Uint32Array(result.buffer));
}
test("presentation chooses every transport and keeps pixel or mismatched baselines out of patches", () => {
  assert.deepEqual(checked(request()).slice(0, 4), [1, 0, 0, 0]);
  assert.deepEqual(checked(request(0, 0, 2)).slice(0, 4), [1, 5, 0, 0]);
  assert.deepEqual(checked(request(0, 0, 0)).slice(0, 4), [1, 7, 0, 1]);
  for (let facts = 0; facts < 32; facts++) {
    const result = checked(request(1, 0, facts));
    const instruction = (facts & 4) === 0 ? 4 : (facts & 8) !== 0 && (facts & 16) === 0 ? 1 : 3;
    assert.equal(result[1], instruction); assert.equal(result[2], (facts & 4) === 0 ? 1 : 0);
  }
  for (const at of [24, 28, 32, 36, 40, 44]) {
    const bytes = request(1); new DataView(bytes.buffer).setFloat32(at, NaN, true); assert.equal(checked(bytes)[1], 3);
    const unequal = request(1); new DataView(unequal.buffer).setFloat32(at, 2.25, true); assert.equal(checked(unequal)[1], 3);
  }
  for (const count of [0, 1, 4, 4294967295]) for (const upserts of [0, count])
    assert.equal(checked(request(2, 0, 15, count, upserts))[1], upserts < count ? 2 : 3);
});
test("presentation coordinates complete success refusal overflow and resync mutations", () => {
  const table = [
    [3, 0, 15, 6, 4, 0], [3, 1, 15, 3, 0, 0], [3, 2, 15, 3, 3, 0],
    [4, 0, 15, 6, 4, 0], [4, 1, 15, 5, 1, 0], [4, 2, 15, 5, 1, 0],
    [4, 1, 13, 7, 1, 2], [4, 2, 13, 7, 1, 1],
    [5, 0, 15, 6, 8, 0], [5, 1, 15, 5, 0, 0], [5, 2, 15, 5, 0, 0],
    [5, 1, 13, 7, 0, 2], [5, 2, 13, 7, 0, 1],
    [6, 0, 15, 6, 9, 0], [6, 1, 15, 7, 0, 3], [6, 2, 15, 7, 0, 4],
  ];
  for (const [phase, outcome, facts, instruction, mutations, refusal] of table)
    assert.deepEqual(checked(request(phase, outcome, facts)).slice(0, 4), [1, instruction, mutations, refusal]);
});
test("presentation generation rollover preserves all u64 words and borrowed offsets", () => {
  for (const generation of [0n, 1n, 4294967295n, 9007199254740993n, 18446744073709551614n, 18446744073709551615n]) {
    const bytes = request(2, 0, 15, 4, 4, generation), expected = generation === 18446744073709551615n ? 1n : generation + 1n;
    const backing = new Uint8Array(93); backing.set(bytes, 13);
    const result = plan(backing.subarray(13, 77)); assert.equal(new DataView(result.buffer).getBigUint64(16, true), expected);
    for (const phase of [0, 1, 3, 4, 5, 6]) {
      const result = plan(request(phase, 0, 15, 4, 1, generation));
      assert.equal(new DataView(result.buffer).getBigUint64(16, true), generation);
    }
  }
});
test("presentation rejects malformed input without accepting reserved data", () => {
  for (const length of [0, 3, 63, 65]) assert.throws(() => plan(new Uint8Array(length)), /invalid/);
  for (const [at, value] of [[0, 0], [1, 0], [2, 7], [3, 3], [4, 32], [12, 5], [48, 1], [63, 1]]) {
    const bytes = request(); bytes[at] = value; assert.throws(() => plan(bytes), /invalid/);
  }
  assert.throws(() => plan(request(1, 1)), /invalid/);
});
