import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = ["runtime_policy.ts", "widget_routing.ts"].map(p => readFileSync(new URL(`../src/${p}`, import.meta.url), "utf8")).join("\n");
const { nscvWidgetRouting: route } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport { nscvWidgetRouting };").toString("base64")}`);
const missing = 0xffffffff;
const wire = (b: Uint8Array) => new DataView(b.buffer, b.byteOffset, b.byteLength);
interface Node { kind?: number; role?: number; parent?: number; depth?: number; id?: bigint; flags?: number; observed?: boolean; actions?: number; value?: number; layer?: number; frame?: number[]; transform?: number[] }
function packet(op: number, nodes: Node[], options: { param?: number; subject?: number; id?: bigint; point?: number[]; capacity?: number; layers?: number[] } = {}) {
  const b = new Uint8Array(64 + nodes.length * 96), w = wire(b);
  b.set([24, 1, op, options.param ?? 0]); w.setUint32(4, nodes.length, true); w.setUint32(8, options.subject ?? missing, true); w.setUint32(12, options.capacity ?? 63, true);
  w.setUint32(48, Number(options.id !== undefined), true); w.setBigUint64(16, options.id ?? 0n, true); (options.point ?? [5, 5]).forEach((v, i) => w.setFloat32(24 + i * 4, v, true)); (options.layers ?? [0, 10, 20, 30]).forEach((v, i) => w.setInt32(32 + i * 4, v, true));
  nodes.forEach((n, i) => { const p = 64 + i * 96;
    for (const [at, v] of [[0, n.kind ?? 31], [4, n.role ?? 0], [8, n.parent ?? missing], [12, n.depth ?? i], [24, (n.flags ?? 0) | (n.observed === false ? 0 : 2048)], [28, n.actions ?? 0]]) w.setUint32(p + at!, v!, true);
    w.setBigUint64(p + 16, n.id ?? BigInt(i + 1), true); w.setFloat32(p + 32, n.value ?? 0, true); w.setInt32(p + 36, n.layer ?? 0, true);
    (n.frame ?? [0, 0, 30, 30]).forEach((v, t) => w.setFloat32(p + 40 + t * 4, v, true)); (n.transform ?? [1, 0, 0, 1, 0, 0]).forEach((v, t) => w.setFloat32(p + 56 + t * 4, v, true));
  }); return b;
}
function result(b: Uint8Array) { const w = wire(b), entries: number[][] = []; for (let i = 0; i < w.getUint32(12, true); i++) entries.push([w.getUint32(24 + i * 8, true), w.getUint32(28 + i * 8, true)]); return { status: b[2], target: w.getUint32(4, true), press: w.getUint32(8, true), entries }; }
test("pointer capture phases preserve exact identities and never retarget a missing capture", () => {
  const id = 0xfedcba9876543210n, nodes = [{ kind: 1 }, { parent: 0, id }];
  for (const param of [2, 3, 4]) {
    assert.equal(result(route(packet(6, nodes, { id, param, point: [1000, 1000] }))).target, 1);
    assert.equal(result(route(packet(6, nodes, { id: id - 1n, param }))).target, missing);
    assert.equal(result(route(packet(6, nodes, { id: 0n, param }))).target, missing);
  }
  for (const param of [0, 1, 5]) assert.equal(result(route(packet(6, nodes, { id, param, point: [1000, 1000] }))).target, missing);
  assert.equal(result(route(packet(6, nodes, { param: 2 }))).target, 1);
});
test("complete event paths preserve phase order, depth errors and the written overflow prefix", () => {
  const nodes = [{ kind: 1 }, { kind: 1, parent: 0 }, { parent: 1 }];
  const expected = [[0, 0], [1, 0], [2, 1], [1, 2], [0, 2]];
  assert.deepEqual(result(route(packet(6, nodes))), { status: 0, target: 2, press: 2, entries: expected });
  for (let capacity = 0; capacity < 5; capacity++) assert.deepEqual(result(route(packet(6, nodes, { capacity }))).entries, expected.slice(0, capacity));
  assert.equal(result(route(packet(6, nodes, { capacity: 4 }))).status, 2);
  const deep = Array.from({ length: 33 }, (_, i) => ({ parent: i === 0 ? missing : i - 1 }));
  assert.deepEqual(result(route(packet(6, deep))), { status: 1, target: 32, press: 32, entries: [] });
  deep.pop(); assert.equal(result(route(packet(6, deep))).entries.length, 63);
});
test("hover listeners preserve containment without taking interactive hits or claiming window drag", () => {
  const nodes = [{ kind: 1, flags: 64 | 32 }, { kind: 26, parent: 0 }, { kind: 1, flags: 32 }];
  assert.equal(result(route(packet(0, nodes))).target, 1); assert.equal(result(route(packet(1, nodes))).target, 2);
  assert.equal(result(route(packet(5, nodes, { subject: 1 }))).target, 0);
  assert.equal(result(route(packet(2, nodes, { subject: 1 }))).target, missing);
  nodes[1]!.kind = 31; assert.equal(result(route(packet(5, nodes, { subject: 1 }))).target, missing);
  const chain = Array.from({ length: 40 }, (_, i) => ({ kind: 1, flags: 32, parent: i === 0 ? missing : i - 1 }));
  assert.deepEqual(result(route(packet(4, chain, { subject: 39, capacity: 3 }))).entries, [[8, 0], [9, 0], [10, 0]]);
});
test("window surfaces use effective modal layers, mount ties, explicit layers and hidden ancestry", () => {
  const nodes: Node[] = [{ kind: 19 }, { kind: 40, parent: 0, flags: 8 }, { flags: 8 }];
  assert.equal(result(route(packet(0, nodes))).target, 0); // tooltip is decoration, modal still wins
  nodes[1]!.kind = 31; assert.equal(result(route(packet(0, nodes))).target, 1);
  nodes[2]!.flags = 8 | 512; nodes[2]!.layer = 21; assert.equal(result(route(packet(0, nodes))).target, 2);
  nodes[0]!.flags = 1; nodes[2]!.flags = 8; assert.equal(result(route(packet(0, nodes))).target, 2);
});
test("hit geometry is transformed locally and uses half-open normalized bounds", () => {
  const nodes: Node[] = [{ frame: [30, 30, -30, -30], transform: [1, 0, 0, 1, 40, 0] }];
  assert.equal(result(route(packet(0, nodes, { point: [40, 0] }))).target, 0);
  assert.equal(result(route(packet(0, nodes, { point: [70, 0] }))).target, missing);
  nodes[0]!.transform = [0, 0, 0, 1, 0, 0]; assert.equal(result(route(packet(0, nodes))).target, missing);
});
test("focus wraps without repeating current, preserves logical clipped targets and spatial ties", () => {
  const nodes: Node[] = [{ kind: 22, flags: 16, frame: [0, 0, 100, 100] }, { parent: 0, frame: [10, 10, 20, 20] }, { parent: 0, frame: [60, 10, 20, 20] }, { parent: 0, frame: [60, 10, 20, 20] }, { parent: 0, frame: [150, 10, 20, 20] }];
  assert.equal(result(route(packet(10, nodes, { id: 2n, param: 3 }))).target, 2);
  assert.equal(result(route(packet(10, nodes, { id: 4n }))).target, 1);
  assert.equal(result(route(packet(10, nodes, { id: 2n, param: 1 }))).target, 3);
  assert.equal(result(route(packet(12, nodes, { subject: 4 }))).target, missing);
  assert.equal(result(route(packet(13, nodes, { subject: 4 }))).target, 4);
  assert.equal(result(route(packet(10, [{ id: 0xffffffffffffffffn }], { id: 0xffffffffffffffffn }))).target, missing);
});
test("file-drop reverses mounted order while drag falls through to its eligible ancestor", () => {
  const nodes: Node[] = [{ kind: 1, actions: 256 }, { kind: 26, parent: 0 }, { kind: 1, actions: 512 }, { kind: 1, actions: 512 }];
  assert.equal(result(route(packet(9, nodes, { id: 2n }))).target, 0);
  assert.equal(result(route(packet(8, nodes, { param: 1 }))).target, 3);
  assert.equal(result(route(packet(8, nodes))).target, missing);
  nodes[3]!.flags = 2; assert.equal(result(route(packet(8, nodes, { param: 1 }))).target, 2);
});
test("focus asks only for necessary semantic facts and resumes in reference order", () => {
  const nodes: Node[] = [{ kind: 1, observed: false }, { kind: 1, observed: false }, { observed: false }, { kind: 1, observed: false }];
  // Indexed and keyboard focus on a button need no scroll observation,
  // including when unrelated containers have no supplied facts.
  for (const op of [7, 11]) assert.equal(result(route(packet(op, nodes, { id: 3n }))).status, 0);
  for (const op of [12, 13]) assert.equal(result(route(packet(op, nodes, { subject: 2 }))).status, 0);
  const request = packet(10, nodes);
  assert.deepEqual(result(route(request)), { status: 3, target: 0, press: missing, entries: [] });
  wire(request).setUint32(64 + 24, 2048, true);
  assert.deepEqual(result(route(request)), { status: 3, target: 1, press: missing, entries: [] });
  wire(request).setUint32(64 + 96 + 24, 2048 | 256, true);
  assert.deepEqual(result(route(request)), { status: 0, target: 1, press: missing, entries: [] });
  // A disabled candidate stands down before it can request a fact.
  assert.equal(result(route(packet(13, [{ kind: 1, flags: 2, observed: false }], { subject: 0 }))).status, 0);
});
test("hover keeps a caller's complete link or unclaimed hit and reconstructs claiming ancestors", () => {
  const nodes: Node[] = [{ kind: 1 }, { kind: 26, parent: 0 }];
  let out = route(packet(3, nodes, { subject: 1, param: 1 })); assert.equal(out[3], 1); assert.equal(result(out).target, 1);
  nodes[0]!.actions = 2;
  out = route(packet(3, nodes, { subject: 1, param: 1 })); assert.equal(out[3], 1); assert.equal(result(out).target, 1);
  out = route(packet(3, nodes, { subject: 1, param: 3 })); assert.equal(out[3], 0); assert.equal(result(out).target, 0);
  nodes[0]!.actions = 0;
  out = route(packet(3, nodes, { subject: 1 })); assert.equal(out[3], 1); assert.equal(result(out).target, 1);
  nodes[0]!.kind = 43;
  out = route(packet(3, nodes, { subject: 1, param: 4 })); assert.equal(out[3], 0); assert.equal(result(out).target, 0);
});
test("requests reject truncation, trailing bytes, cycles, future parents and unknown facts", () => {
  const valid = packet(0, [{}]);
  for (let i = 0; i < valid.length; i++) assert.throws(() => route(valid.subarray(0, i)));
  const trailing = new Uint8Array(valid.length + 1); trailing.set(valid); assert.throws(() => route(trailing));
  for (const [at, value] of [[0, 0], [1, 2], [2, 14], [3, 1], [48, 2], [52, 1], [64, 63], [68, 27], [72, 0], [88, 4096], [92, 2048], [144, 1]]) { const bad = valid.slice(); if (at! < 4) bad[at!] = value!; else wire(bad).setUint32(at!, value!, true); assert.throws(() => route(bad), `field ${at}`); }
});
