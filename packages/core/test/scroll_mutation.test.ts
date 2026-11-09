import assert from "node:assert/strict";
import test from "node:test";
import { stripTypeScriptTypes } from "node:module";
import { readFileSync } from "node:fs";
const source = readFileSync(new URL("../src/scroll_mutation.ts", import.meta.url), "utf8");
const { nscvScrollMutation: program } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport { nscvScrollMutation };").toString("base64")}`);
function request(mode = 0, phase = 0, facts = 1 | 2 | 16 | 32, source = 0, vertical = 1): Uint8Array {
  const b = new Uint8Array(16); b.set([101, mode, phase, source, vertical]);
  new DataView(b.buffer).setUint32(8, facts, true); return b;
}
function plan(...args: Parameters<typeof request>): [number, number[]] {
  const p = program(request(...args)); return [p[2], [...p.subarray(8)]];
}
test("scroll mutation keeps retained writes before unchanged exits and publishes after geometry", () => {
  assert.deepEqual(plan(0, 1, 1 | 2 | 16 | 256, 2), [2, [2, 6, 8, 9]]);
  assert.deepEqual(plan(0, 2, 1 | 2 | 16 | 256), [255, []]);
  assert.deepEqual(plan(0, 2, 1 | 2 | 16 | 256 | 512), [255, [11, 12, 13, 14, 15, 16]]);
  assert.deepEqual(plan(1, 1, 1 | 4 | 256, 1), [2, [3, 6, 10]]);
  assert.deepEqual(plan(1, 2, 1 | 4 | 256 | 512), [255, [11, 14, 15, 16]]);
  assert.deepEqual(plan(2, 1, 1 | 2 | 16 | 32 | 256), [2, [2, 17, 18, 21]]);
  assert.deepEqual(plan(3, 1, 1 | 2 | 32 | 256, 1), [2, [2, 20, 21]]);
  assert.deepEqual(plan(2, 2, 512), [255, [22, 23, 13, 14, 15, 16]]);
});
test("scroll mutation admission separates textarea native momentum and rubber band ownership", () => {
  assert.deepEqual(plan(0, 0, 1 | 4 | 8 | 16), [255, [4]]);
  assert.deepEqual(plan(0, 0, 1 | 4 | 16, 0, 0), [255, []]);
  for (const facts of [0, 1, 1 | 2 | 8 | 16, 1 | 2]) assert.deepEqual(plan(0, 0, facts), [255, []]);
  assert.deepEqual(plan(1, 0, 1 | 4), [1, [1]]);
  assert.deepEqual(plan(4, 0, 1 | 2 | 16 | 64), [255, []]);
  assert.deepEqual(plan(2, 0, 1 | 2 | 16 | 64), [1, [0]]);
  assert.deepEqual(plan(0, 1, 256 | 128, 1), [2, [2, 5, 9]]);
  assert.deepEqual(plan(0, 1, 256 | 128 | 64, 1), [2, [2, 6, 9]]);
  assert.deepEqual(plan(0, 1, 256 | 128, 0), [2, [2, 7, 9]]);
});
test("scroll mutation kinetic stages store stopped axes and refresh once after all regions", () => {
  assert.deepEqual(plan(4, 1, 0), [255, [24]]);
  assert.deepEqual(plan(4, 1, 256 | 16), [2, [2, 25]]);
  assert.deepEqual(plan(4, 2, 16 | 32 | 1024), [3, [27, 26]]);
  assert.deepEqual(plan(4, 2, 32), [3, [29, 26]]);
  assert.deepEqual(plan(4, 3, 32 | 1024), [4, [28, 21]]);
  assert.deepEqual(plan(4, 3, 0), [4, [30, 21]]);
  assert.deepEqual(plan(4, 4, 512), [255, [22, 23, 13, 31]]);
  assert.deepEqual(plan(5, 0, 512), [255, [14, 15]]);
  assert.deepEqual(plan(5, 0, 0), [255, []]);
});
test("scroll mutation rejects truncated reserved and invalid state and owns result bytes", () => {
  const b = request(), result = program(b), saved = result.slice();
  for (let n = 0; n < 16; n++) assert.throws(() => program(b.subarray(0, n)));
  assert.throws(() => program(new Uint8Array([...b, 0])));
  for (const at of [0, 1, 2, 3, 4, 5, 6, 7, 9, 12, 15]) {
    const bad = b.slice(); bad[at] = 255; assert.throws(() => program(bad));
  }
  assert.throws(() => program(request(5, 1)));
  assert.throws(() => program(request(3, 0, 0, 2)));
  assert.throws(() => program(request(0, 3)));
  b.fill(255); program(request(4, 3)); assert.deepEqual(result, saved);
});
test("scroll mutation batches kinetic admission with bounded independently owned masks", () => {
  const b = new Uint8Array(16 + 1024); b[0] = 101; b[1] = 6;
  new DataView(b.buffer).setUint32(8, 1024, true);
  b[16 + 512] = 2; b[16 + 513] = 2 | 64; b[16 + 514] = 2 | 8;
  const result = program(b); assert.equal(result.length, 1032);
  assert.equal(result[8 + 512], 1); assert.equal(result.subarray(8).reduce((a: number, b: number) => a + b, 0), 1);
  b.fill(0); assert.equal(result[8 + 512], 1);
  const empty = request(6, 0, 0, 0, 0); assert.equal(program(empty).length, 8);
  for (const at of [0, 2, 3, 4, 5, 6, 7, 8, 12]) { const bad = empty.slice(); bad[at] = 255; assert.throws(() => program(bad)); }
  assert.throws(() => program(new Uint8Array([...empty, 0])));
});
