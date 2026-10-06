import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = readFileSync(new URL("../src/component_composition.ts", import.meta.url), "utf8");
const { nscvCompositionPolicy: policy } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport { nscvCompositionPolicy };\n").toString("base64")}`);
function request(op: number, flags = 0, active = 0n, index = 0n, count = 0n) {
  const r = new Uint8Array(64), w = new DataView(r.buffer); r.set([19, op, flags]);
  w.setBigUint64(8, active, true); w.setBigUint64(16, index, true); w.setBigUint64(24, count, true); return r;
}
const float = (out: Uint8Array, slot: number) => new DataView(out.buffer).getFloat32(32 + slot * 4, true);
test("composition preserves exact navigation indices through max u64", () => {
  for (const active of [0n, 1n, 9007199254740993n, 18446744073709551615n]) {
    const p = policy(request(6, 0, active, 0n, 3n)), w = new DataView(p.buffer);
    assert.equal(w.getBigUint64(8, true), active > 2n ? 2n : active);
    assert.equal(w.getBigUint64(16, true), 1n); assert.equal(p[0], 1);
    const retained = policy(request(6, 1, active, 0n, 3n)); assert.equal(new DataView(retained.buffer).getBigUint64(16, true), 3n);
  }
  assert.equal(new DataView(policy(request(6, 1, 99n)).buffer).getBigUint64(16, true), 0n);
});
test("step recipes retain exact comparisons and accessible state names", () => {
  const value = 9007199254740993n;
  for (const [index, state, selected] of [[value - 1n, "completed", false], [value, "active", true], [value + 1n, "pending", false]] as const) {
    const p = policy(request(4, 0, value, index));
    assert.equal(new TextDecoder().decode(p.slice(104, 104 + p[100]!)), state);
    assert.equal((p[1]! & 2) !== 0, selected); assert.equal(float(p, 0), 6);
  }
  for (const count of [0n, 1n, 4n, 9007199254740993n])
    assert.equal(new DataView(policy(request(3, 0, 0n, 0n, count)).buffer).getBigUint64(16, true), count === 0n ? 0n : count * 2n - 1n);
});
test("grouped input retains authored chrome and copied float words", () => {
  for (let mask = 0; mask < 16; mask++) {
    const r = request(1, mask), w = new DataView(r.buffer); w.setUint32(32, 0x7fc00037, true);
    const p = policy(r); assert.equal(p[1], mask & 7);
    assert.equal(new DataView(p.buffer).getUint32(56, true), mask & 8 ? 0x3f800000 : 0x7fc00037);
    r.fill(0); assert.equal(p[1], mask & 7);
  }
  const group = policy(request(0, 1)); assert.equal(group[3], 2); assert.equal(group[0], 1);
  const actions = request(2); new DataView(actions.buffer).setUint32(36, 0x80000000, true);
  const p = policy(actions); assert.equal(new DataView(p.buffer).getUint32(32, true), 0x80000000);
  assert.deepEqual([2, 3, 4, 5].map(i => float(p, i)), [4, 8, 8, 8]);
});
test("timeline plans describe every optional subtree and f32 span scale", () => {
  for (let mask = 0; mask < 32; mask++) {
    const p = policy(request(5, mask)); assert.equal(p[1], mask & 15);
    assert.equal(p[3], 1 + (mask & 2 ? 1 : 0) + (mask & 4 ? 1 : 0));
    assert.equal(float(p, 7), mask & 16 ? 10 : 0); assert.equal(float(p, 9), mask & 1 ? 4 : 0);
    assert.equal(float(p, 16), Math.fround(0.9));
  }
});
test("composition refuses truncations, trailing data, invalid flags and reserved words", () => {
  for (let op = 0; op < 8; op++) {
    const r = request(op);
    for (let n = 0; n < r.length; n++) assert.throws(() => policy(r.slice(0, n)));
    assert.throws(() => policy(new Uint8Array([...r, 0])));
    r[2] = 63; assert.throws(() => policy(r));
  }
  const r = request(0); r[3] = 27; assert.throws(() => policy(r));
  r[3] = 0; r[4] = 1; assert.throws(() => policy(r));
});
