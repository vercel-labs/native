import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = ["view_components.ts", "runtime_policy.ts", "widget_routing.ts", "host_input_regions.ts"]
  .map(name => readFileSync(new URL(`../src/${name}`, import.meta.url), "utf8")).join("\n")
  .replace('"@native-sdk/core/text"', JSON.stringify(new URL("../sdk/text.ts", import.meta.url).href));
const { nscvHostInputRegions: plan, native_text_policy: dispatch } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport { nscvHostInputRegions };").toString("base64")}`);
const missing = 0xffffffff;
interface Node {
  kind?: number; id?: bigint; parent?: number; depth?: number; flags?: number; actions?: number;
  value?: number; x?: number; layer?: number; frame?: number[]; transform?: number[]; padding?: number[];
  virtualCount?: bigint; config?: number; measured?: boolean; extent?: number[];
}
interface Region { frame: number[]; exclusion: boolean }
interface Options {
  facts?: number; capacity?: number; rubber?: boolean; frame?: number[]; layers?: number[]; record?: bigint;
  tracked?: { id: bigint; x: number; y: number }[]; previous?: Region[];
}
const wire = (b: Uint8Array): DataView => new DataView(b.buffer, b.byteOffset, b.byteLength);
function packet(mode: number, nodes: Node[], options: Options = {}): Uint8Array {
  const tracked = options.tracked ?? [], previous = options.previous ?? [];
  const b = new Uint8Array(64 + nodes.length * 128 + tracked.length * 16 + previous.length * 20), w = wire(b);
  b.set([79, 1, mode, 0]);
  w.setUint32(4, nodes.length, true); w.setUint32(8, tracked.length, true); w.setUint32(12, previous.length, true);
  w.setUint32(20, options.facts ?? 3, true); w.setUint32(24, options.rubber ? 1 : 0, true); w.setUint32(28, options.capacity ?? 32, true);
  (options.frame ?? [10, 20, 320, 240]).forEach((v, i) => w.setFloat32(32 + i * 4, v, true));
  (options.layers ?? [0, 10, 20, 30]).forEach((v, i) => w.setInt32(48 + i * 4, v, true));
  if (mode === 3) w.setBigUint64(40, options.record ?? 0n, true);
  nodes.forEach((n, i) => {
    const at = 64 + i * 128;
    for (const [offset, value] of [[0, n.kind ?? 6], [8, n.parent ?? missing], [12, n.depth ?? 0], [24, n.flags ?? 0], [28, n.actions ?? 0], [108, n.config ?? 0], [112, n.measured === false ? 0 : 1]]) w.setUint32(at + offset!, value!, true);
    w.setBigUint64(at + 16, n.id ?? BigInt(i + 1), true); w.setFloat32(at + 32, n.value ?? 0, true); w.setInt32(at + 36, n.layer ?? 0, true);
    (n.frame ?? [0, 0, 100, 60]).forEach((v, j) => w.setFloat32(at + 40 + j * 4, v, true));
    (n.transform ?? [1, 0, 0, 1, 0, 0]).forEach((v, j) => w.setFloat32(at + 56 + j * 4, v, true));
    (n.padding ?? [0, 0, 0, 0]).forEach((v, j) => w.setFloat32(at + 80 + j * 4, v, true));
    w.setFloat32(at + 96, n.x ?? 0, true); w.setBigUint64(at + 100, n.virtualCount ?? 0n, true);
    w.setFloat32(at + 116, n.extent?.[0] ?? 160, true); w.setFloat32(at + 120, n.extent?.[1] ?? 200, true);
  });
  tracked.forEach((value, i) => { const at = 64 + nodes.length * 128 + i * 16; w.setBigUint64(at, value.id, true); w.setFloat32(at + 8, value.x, true); w.setFloat32(at + 12, value.y, true); });
  previous.forEach((value, i) => { const at = 64 + nodes.length * 128 + tracked.length * 16 + i * 20; value.frame.forEach((v, j) => w.setFloat32(at + j * 4, v, true)); w.setUint32(at + 16, value.exclusion ? 1 : 0, true); });
  return b;
}
function checked(mode: number, nodes: Node[], options: Options = {}): Uint8Array {
  const b = packet(mode, nodes, options), original = b.slice(), backing = new Uint8Array(b.length + 23);
  backing.set(b, 9); const result = plan(backing.subarray(9, 9 + b.length));
  assert.deepEqual(b, original); assert.deepEqual(result, dispatch(b));
  const saved = result.slice(); backing.fill(255); b.fill(255); assert.deepEqual(result, saved); return result;
}
function decoded(b: Uint8Array) {
  const w = wire(b), stamps: number[] = [], drivers: { id: bigint; parent: bigint; mask: number; flags: number; frame: number[]; size: number[]; offset: number[] }[] = [], occluders: number[][] = [], regions: Region[] = [];
  let at = 32;
  for (let i = 0; i < w.getUint32(12, true); i++) { stamps.push(w.getUint32(at, true)); at += 4; }
  for (let i = 0; i < w.getUint32(16, true); i++) {
    const read = (start: number, count: number) => Array.from({ length: count }, (_, j) => w.getFloat32(at + start + j * 4, true));
    drivers.push({ id: w.getBigUint64(at, true), parent: w.getBigUint64(at + 8, true), mask: w.getUint32(at + 16, true), flags: w.getUint32(at + 20, true), frame: read(24, 4), size: read(40, 2), offset: read(48, 2) });
    assert.equal(w.getBigUint64(at + 56, true), 0n); at += 64;
  }
  for (let i = 0; i < w.getUint32(20, true); i++) { occluders.push(Array.from({ length: 4 }, (_, j) => w.getFloat32(at + j * 4, true))); at += 16; }
  for (let i = 0; i < w.getUint32(24, true); i++) { regions.push({ frame: Array.from({ length: 4 }, (_, j) => w.getFloat32(at + j * 4, true)), exclusion: w.getUint32(at + 16, true) !== 0 }); at += 20; }
  assert.equal(at, b.length); return { stamps, drivers, occluders, regions, detail: w.getUint32(28, true) };
}
test("host input regions stamp complete eligibility including hidden disabled and over-capacity nodes", () => {
  const nodes: Node[] = [{ id: 0n }, { kind: 31 }, { config: 1 }, { config: 1, virtualCount: 1n << 40n }, { flags: 3 }, ...Array.from({ length: 20 }, () => ({}))];
  assert.deepEqual(decoded(checked(0, nodes)).stamps, Array.from({ length: 22 }, (_, i) => i + 3));
  assert.deepEqual(decoded(checked(0, nodes, { facts: 0 })).stamps, []);
  const result = decoded(checked(1, nodes));
  assert.equal(result.drivers.length, 16); assert.equal(result.stamps.length, 22);
  assert.equal(result.drivers[0]!.id, 4n); assert.equal(result.drivers[1]!.id, 5n);
});
test("host input regions request content only after viewport and capacity admission", () => {
  const nodes: Node[] = [{ padding: [70, 0, 0, 0], measured: false }, { measured: false, padding: [2, 3, 4, 5], config: 8 }, ...Array.from({ length: 17 }, () => ({}))];
  const pending = checked(1, nodes), w = wire(pending);
  assert.equal(pending.length, 48); assert.equal(w.getUint32(8, true), 1); assert.equal(w.getUint32(28, true), 1); assert.equal(w.getUint32(12, true), 3);
  assert.deepEqual(Array.from({ length: 4 }, (_, i) => w.getFloat32(32 + i * 4, true)), [5, 2, 92, 54]);
  nodes[1]!.measured = true; nodes[nodes.length - 1]!.measured = false;
  const result = decoded(checked(1, nodes)); assert.equal(result.drivers.length, 16); assert.equal(result.drivers[15]!.id, 17n);
});
test("host input regions preserve independent axes rubber-band overrides exact identities and echo boundaries", () => {
  const id = 0xfedcba9876543210n;
  for (const [config, flags, size, offset] of [[0, 19, [100, 160], [0, 20]], [4, 11, [200, 60], [10, 0]], [8, 27, [200, 160], [10, 20]], [9, 19, [100, 160], [0, 20]]] as const) {
    const d = decoded(checked(1, [{ id, config, virtualCount: 1n, x: 10, value: 20 }])).drivers[0]!;
    assert.deepEqual(d, { id, parent: 0n, mask: 0, flags, frame: [0, 0, 100, 60], size, offset });
  }
  for (const override of [0, 16, 32]) for (const rubber of [false, true]) {
    const d = decoded(checked(1, [{ id, config: 8 | override, x: 10, value: 20 }], { rubber, tracked: [{ id, x: 10.5, y: 20.500001 }] })).drivers[0]!;
    assert.equal((d.flags & 1) !== 0, false); assert.equal((d.flags & 2) !== 0, true);
    assert.equal((d.flags & 4) !== 0, override === 32 || override === 0 && rubber);
  }
});
test("host input regions preserve nesting paint order transformed occluders and safe overflow", () => {
  const nodes: Node[] = [{}, { kind: 23, flags: 8, transform: [1, 0, 0, 1, 20, 30] }, { parent: 1, depth: 1 }, { kind: 19, config: 2 }, { parent: 3, depth: 1 }];
  const result = decoded(checked(1, nodes));
  assert.deepEqual(result.occluders, [[20, 30, 100, 60], [0, 0, 320, 240]]);
  assert.deepEqual(result.drivers.map(d => d.mask), [3, 2, 0]);
  const nested = decoded(checked(1, [{ id: 9007199254740993n, padding: [70, 0, 0, 0] }, { parent: 0, depth: 1, id: 0xffffffffffffffffn }]));
  assert.equal(nested.drivers[0]!.parent, 9007199254740993n);
  const over = decoded(checked(1, [{}, ...Array.from({ length: 9 }, () => ({ kind: 23, flags: 8 }))]));
  assert.deepEqual(over.occluders, [[0, 0, 320, 240]]); assert.equal(over.drivers[0]!.mask, 1);
  assert.deepEqual(decoded(checked(1, [{}, { kind: 40, flags: 8 }, { kind: 23, flags: 9 }, { kind: 14 }, { kind: 23, flags: 8, parent: 3, depth: 1 }])).occluders, []);
});
test("host input regions retain complete drag exclusions and roll back an overflowing header", () => {
  const nodes: Node[] = [{ kind: 3, flags: 64 }, { kind: 31, parent: 0, depth: 1 }, { kind: 3, flags: 64 }, { kind: 3, actions: 2, parent: 2, depth: 1 }, { kind: 31, parent: 2, depth: 1 }];
  assert.deepEqual(decoded(checked(2, nodes, { capacity: 4 })).regions, [{ frame: [0, 0, 100, 60], exclusion: false }, { frame: [0, 0, 100, 60], exclusion: true }]);
  assert.equal(decoded(checked(2, nodes, { capacity: 5 })).regions.length, 5);
  assert.deepEqual(decoded(checked(2, nodes, { capacity: 1 })).regions, []);
  const initial = decoded(checked(2, nodes, { capacity: 4 })); assert.equal(initial.detail, 1);
  assert.equal(decoded(checked(2, nodes, { capacity: 4, facts: 6, previous: initial.regions })).detail, 0);
  assert.equal(decoded(checked(2, [], { facts: 6, previous: initial.regions })).detail, 1);
  assert.equal(decoded(checked(2, [], { facts: 6 })).detail, 0);
  assert.equal(decoded(checked(2, nodes, { facts: 0 })).detail, 0);
});
test("host input regions preserve drag visibility and record unknown and duplicate driver ids", () => {
  assert.equal(decoded(checked(2, [{ kind: 14 }, { kind: 3, flags: 64, parent: 0, depth: 1 }])).regions.length, 1);
  assert.equal(decoded(checked(2, [{ kind: 3, flags: 65 }])).regions.length, 0);
  const tracked = [{ id: 1n, x: 0, y: 0 }, { id: 1n, x: 2, y: 3 }];
  assert.equal(decoded(checked(3, [], { record: 1n, tracked })).detail, 0);
  assert.equal(decoded(checked(3, [], { record: 9007199254740993n, tracked })).detail, 2);
  assert.equal(decoded(checked(3, [], { record: 0n, tracked: Array.from({ length: 16 }, (_, i) => ({ id: BigInt(i + 1), x: i, y: i })) })).detail, missing);
});
test("host input regions reject incomplete records cycles capacities and reserved fields", () => {
  const packetBytes = packet(0, [{}]);
  for (let i = 0; i < packetBytes.length; i++) assert.throws(() => plan(packetBytes.subarray(0, i)));
  for (const at of [0, 1, 2, 3]) { const bad = packetBytes.slice(); bad[at] = 255; assert.throws(() => plan(bad)); }
  for (const at of [4, 8, 12, 16, 20, 24, 28, 64, 68, 88, 92, 172, 176, 188]) { const bad = packetBytes.slice(); wire(bad).setUint32(at, missing, true); assert.throws(() => plan(bad)); }
  assert.throws(() => plan(packet(0, [{ parent: 0 }])));
  assert.throws(() => plan(packet(3, [{}])));
});
