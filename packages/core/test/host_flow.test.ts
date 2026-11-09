import assert from "node:assert/strict";
import test from "node:test";
import { hostFlowPolicy } from "../src/host_flow.ts";
function request(stage: number, kind = 0, a = 0, b = 0, count = 0, used = 0, cost = 0, head = 0, delivered = 0) {
  const input = new Uint8Array(64); input.set([31, 1, stage, kind, a, b]);
  const w = new DataView(input.buffer); [count, used, cost, head, delivered].forEach((value, i) => w.setUint32(8 + i * 4, value, true));
  const saved = input.slice(), output = hostFlowPolicy(input); assert.deepEqual(input, saved); assert.equal(output.length, 64); return output;
}
test("host flow coalesces only adjacent unobserved frames before queue and byte refusal", () => {
  for (const count of [1, 4095, 4096]) for (const used of [0, 4194240, 4194304]) {
    assert.equal(request(0, 4, 1, 0, count, used, 64)[0], 1);
    assert.equal(request(0, 20, 1, 0, count, used, 64)[0], count === 4096 || used === 4194304 ? 2 : 3);
  }
  const accepted = request(0, 4, 1, 0, 0, 0, 64); assert.equal(accepted[0], 3); assert.equal(new DataView(accepted.buffer).getUint32(8, true), 4194240);
  assert.equal(request(0, 18, 0, 0, 0, 4194240, 64)[0], 3);
  assert.equal(request(0, 18, 0, 0, 0, 4194241, 64)[0], 2);
});
test("host flow distinguishes successful queue reuse, compaction and delivered-turn boundaries", () => {
  assert.equal(request(1, 0, 0, 0, 0, 0, 0, 4096)[0], 1);
  for (const [head, count, expected] of [[4095, 1, 0], [4095, 4096, 0], [4096, 4096, 2], [4097, 1, 2]]) assert.equal(request(1, 0, 0, 0, count!, 0, 0, head!)[0], expected);
  assert.equal(request(3, 0, 0, 0, 0, 0, 0, 0, 4096)[0], 0);
  assert.equal(request(3, 0, 0, 0, 1, 0, 0, 0, 4095)[0], 1);
  assert.equal(request(3, 0, 0, 0, 1, 0, 0, 0, 4096)[0], 2);
  assert.equal(request(4, 0, 1, 1)[0], 1); assert.equal(request(4, 0, 0, 1)[0], 2); assert.equal(request(4)[0], 0);
});
test("host flow stop fallback and watcher teardown remain ordered and copied", () => {
  assert.deepEqual(Array.from(request(9, 0, 0, 1).subarray(0, 5)), [1, 2, 3, 4, 0]);
  assert.deepEqual(Array.from(request(9, 0, 1, 1).subarray(0, 4)), [1, 3, 4, 0]);
  assert.deepEqual(Array.from(request(9, 0, 0, 0).subarray(0, 4)), [1, 2, 3, 0]);
  const out = request(8), saved = out.slice(); request(5, 5); assert.deepEqual(out, saved);
  assert.equal(request(6, 4, 0, 1)[0], 0); assert.equal(request(6, 4, 1, 0)[0], 2); assert.equal(request(6, 4, 1, 1)[0], 1);
});
test("host flow closes only prior-open windows and preserves neutral app notifications", () => {
  for (const a of [0, 1]) for (const b of [0, 1]) assert.equal(request(6, 1, a, b)[0], a && !b ? 1 : 0);
  assert.deepEqual(Array.from(request(7, 2).subarray(0, 5)), [4, 5, 1, 2, 0]);
  for (const kind of [18, 19]) assert.deepEqual(Array.from(request(7, kind).subarray(0, 3)), [4, 5, 0]);
  for (const kind of [1, 25]) assert.equal(request(7, kind)[2], 3);
  for (const kind of [3, 17, 20]) assert.equal(request(7, kind)[2], 2);
  for (const kind of [4, 20]) { assert.equal(request(6, 0, kind, 0)[0], 0); assert.equal(request(6, 0, kind, 1)[0], 1); }
  for (const refusal of [1, 2, 3]) assert.equal(request(6, 7, refusal)[0], 1); assert.equal(request(6, 7, 4)[0], 0);
});
test("host flow admits every platform route and refuses invalid transport and route tags", () => {
  for (let kind = 0; kind < 29; kind++) { const out = request(5, kind); assert.notEqual(out[0], 0); assert.ok(out.includes(0)); }
  for (const stage of [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]) assert.equal(request(stage).length, 64);
  for (let n = 0; n < 64; n++) assert.throws(() => hostFlowPolicy(new Uint8Array(n)));
  for (const [at, value] of [[0, 30], [1, 2], [2, 12]]) { const input = new Uint8Array(64); input.set([31, 1]); input[at!] = value!; assert.throws(() => hostFlowPolicy(input)); }
  assert.throws(() => request(5, 29)); assert.throws(() => request(7, 27)); assert.throws(() => request(6, 10));
});

test("host flow rejects reserved bytes, invalid booleans and impossible queue facts", () => {
  for (const at of [6, 7, ...Array.from({ length: 36 }, (_, i) => i + 28)]) {
    const input = new Uint8Array(64); input.set([31, 1, 8]); input[at] = 1;
    assert.throws(() => hostFlowPolicy(input));
  }
  for (const stage of [2, 4, 9]) { assert.throws(() => request(stage, 0, 2)); assert.throws(() => request(stage, 0, 0, 2)); }
  assert.throws(() => request(0, 0, 0, 0, 4097));
  assert.throws(() => request(0, 0, 0, 0, 0, 4194305));
  assert.throws(() => request(3, 0, 0, 0, 1, 0, 0, 0, 4097));
});

test("host flow owns journal entry, checkpoint and sealing order even on error unwind", () => {
  for (let kind = 0; kind < 29; kind++) for (const recorded of [0, 1]) for (const dirty of [0, 1]) {
    const trace = kind !== 4 && kind !== 20 || dirty !== 0;
    const entry: number[] = []; if (recorded) entry.push(1); if (trace) entry.push(2); entry.push(0);
    assert.deepEqual(Array.from(request(10, kind, recorded, dirty).subarray(0, entry.length)), entry);
    const exit = recorded ? kind === 5 ? [1, 2, 3, 0] : [1, 2, 0] : [0];
    assert.deepEqual(Array.from(request(11, kind, recorded).subarray(0, exit.length)), exit);
    assert.equal(request(6, 9, kind)[0], kind === 0 ? 1 : 0);
  }
});
