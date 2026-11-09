import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = readFileSync(new URL("../src/widget_retention.ts", import.meta.url), "utf8");
const { nscvWidgetRetention: plan } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport { nscvWidgetRetention };").toString("base64")}`);
interface Fact { id: bigint; kind: number; flags?: number; value?: number }
function packet(operation: number, nodes: Fact[], sources: Fact[] = [], capacity = 1024, states = nodes.length): Uint8Array {
  const b = new Uint8Array(24 + (nodes.length + sources.length) * 16), v = new DataView(b.buffer);
  b.set([92, operation]); v.setUint32(4, nodes.length, true); v.setUint32(8, sources.length, true);
  v.setUint32(12, capacity, true); v.setUint32(16, states, true);
  [...nodes, ...sources].forEach((n, i) => {
    const at = 24 + i * 16; v.setBigUint64(at, n.id, true); b[at + 8] = n.kind; b[at + 9] = n.flags ?? 0;
    v.setFloat32(at + 12, n.value ?? 0, true);
  }); return b;
}
function decode(b: Uint8Array) {
  const v = new DataView(b.buffer, b.byteOffset, b.byteLength);
  return { target: v.getUint32(8, true), entries: Array.from({ length: v.getUint32(4, true) }, (_, i) =>
    [v.getUint32(16 + i * 12, true), v.getUint32(20 + i * 12, true), v.getUint32(24 + i * 12, true)]) };
}
const missing = 0xffffffff;
test("retention covers every canonical kind with complete capacity prefixes", () => {
  const kinds = [[6, 57], [14, 32, 41, 42, 44, 46, 48, 51], [14, 16, 32, 41, 42, 44, 46, 47, 48, 49, 50, 51], [6], [35, 36, 37, 38, 39], [35, 36, 37, 38, 39]];
  const nodes = Array.from({ length: 63 }, (_, kind) => ({ id: BigInt(kind + 1), kind }));
  kinds.forEach((expected, operation) => {
    for (const capacity of [0, 1, 3, 1024]) assert.deepEqual(decode(plan(packet(operation, nodes, [], capacity))).entries,
      expected.slice(0, capacity).map(kind => [kind, missing, kind === 16 ? 2 : 0]));
  });
  assert.deepEqual(decode(plan(packet(3, nodes, [], 1024, 6))).entries, []);
});
test("retained text distinguishes collapsed selections and keeps first id-kind match", () => {
  const id = 9007199254740993n;
  const nodes = [{ id, kind: 26, flags: 2 }, { id, kind: 26, flags: 6 }, { id, kind: 39, flags: 8 }, { id: id + 1n, kind: 39 }];
  const sources = [{ id, kind: 38 }, { id, kind: 39 }, { id, kind: 39 }];
  assert.deepEqual(decode(plan(packet(5, nodes, sources))).entries, [[1, missing, 0], [2, 1, 4], [3, missing, 0]]);
});
test("autofocus scans beyond tracked capacity and preserves duplicates and opaque ids", () => {
  const nodes = [0n, 9007199254740992n, 9007199254740993n, 0xffffffffffffffffn, 0xffffffffffffffffn].map(id => ({ id, kind: 36, flags: 1 }));
  for (const capacity of [0, 1, 2, 1024]) {
    const input = packet(6, nodes, [{ id: nodes[1]!.id, kind: 0 }], capacity);
    assert.deepEqual(decode(plan(input)), { target: 2, entries: [1, 2, 3, 4].slice(0, capacity).map(i => [i, i === 1 ? 0 : missing, 0]) });
  }
  assert.equal(decode(plan(packet(6, nodes, nodes.slice(1).map(n => ({ id: n.id, kind: 0 }))))).target, missing);
});
test("control boolean selection follows native float comparison including NaN and signed zero", () => {
  for (const [value, selected] of [[-0, false], [0.499, false], [0.5, true], [Infinity, true], [NaN, false]] as const)
    for (const flag of [0, 16]) assert.equal(decode(plan(packet(1, [{ id: 1n, kind: 32, value, flags: flag }]))).entries[0]![2], flag === 16 || selected ? 1 : 0);
});
test("plans own output and validate all facts even with zero capacity", () => {
  const input = packet(5, [{ id: 1n, kind: 39 }], [{ id: 1n, kind: 39 }]), copy = input.slice(), output = plan(input);
  assert.deepEqual(input, copy); input.fill(0); assert.deepEqual(decode(output).entries, [[0, 0, 0]]);
  for (let length = 0; length < copy.length; length++) assert.throws(() => plan(copy.subarray(0, length)));
  for (const at of [2, 3, 20, 34, 35, 50, 51]) { const b = copy.slice(); b[at] = 1; assert.throws(() => plan(b)); }
  const b = packet(0, [{ id: 1n, kind: 6 }, { id: 2n, kind: 63 }], [], 0); assert.throws(() => plan(b));
});
