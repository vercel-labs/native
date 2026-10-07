import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = readFileSync(new URL("../src/widget_changes.ts", import.meta.url), "utf8");
const { nscvWidgetChanges: plan } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport { nscvWidgetChanges };").toString("base64")}`);
const wire = (b: Uint8Array) => new DataView(b.buffer, b.byteOffset, b.byteLength);
function bytes(text: number[]): Uint8Array { const b = new Uint8Array(5 + text.length); b[0] = 7; wire(b).setUint32(1, text.length, true); b.set(text, 5); return b; }
function float(value: number): Uint8Array { const b = new Uint8Array(5); b[0] = 3; wire(b).setFloat32(1, value, true); return b; }
interface Node { id: bigint; flags?: number; groups?: Uint8Array[] }
function packet(before: Node[], after: Node[], capacity = 100, roots?: number[][]): Uint8Array {
  const nodes = [...before, ...after].map(n => ({ ...n, groups: n.groups ?? Array.from({ length: 9 }, () => bytes([])) }));
  const result = new Uint8Array(64 + nodes.reduce((v, n) => v + 52 + n.groups.reduce((a, b) => a + b.length, 0), 0)), v = wire(result);
  result.set([25, 1, 0, 0]); v.setUint32(4, before.length, true); v.setUint32(8, after.length, true); v.setUint32(12, capacity, true);
  if (roots) { v.setUint32(16, 3, true); roots.forEach((r, i) => r.forEach((f, j) => v.setFloat32(24 + i * 16 + j * 4, f, true))); }
  let at = 64;
  for (const n of nodes) {
    v.setBigUint64(at, n.id, true); v.setUint32(at + 8, n.flags ?? 0, true);
    n.groups.forEach((g, i) => v.setUint32(at + 16 + i * 4, g.length, true)); at += 52;
    for (const g of n.groups) { result.set(g, at); at += g.length; }
  }
  return result;
}
function result(b: Uint8Array) { const v = wire(b); return { status: b[2], entries: Array.from({ length: v.getUint32(4, true) }, (_, i) => Array.from({ length: 4 }, (_, j) => v.getUint32(16 + i * 16 + j * 4, true))) }; }
const missing = 0xffffffff;
test("retained plans preserve wide identities, previous order and complete capacity prefixes", () => {
  const before = [{ id: 0n }, { id: 9007199254740993n }, { id: 0xffffffffffffffffn }], after = [{ id: 9007199254740994n }, { id: 0n }];
  const expected = [[0, 1, missing, 7], [0, 2, missing, 7], [2, missing, 0, 7]];
  for (let capacity = 0; capacity < 5; capacity++) assert.deepEqual(result(plan(packet(before, after, capacity))), { status: capacity < 3 ? 2 : 0, entries: expected.slice(0, capacity) });
});
test("duplicate validation precedes every write even at zero caller capacity", () => {
  for (const [before, after] of [[[1n, 1n], []], [[], [1n, 1n]], [[0n, 0n], [0n, 0n]]]) {
    assert.deepEqual(result(plan(packet(before!.map(id => ({ id })), after!.map(id => ({ id })), 0))), { status: before!.includes(1n) || after!.includes(1n) ? 1 : 0, entries: [] });
  }
});
test("all dependency groups keep independent paint, layout and semantic obligations", () => {
  const original = Array.from({ length: 9 }, () => bytes([]));
  // Layout; content; command; visual; state; semantics; layer; static offset;
  // opacity/transform observation (also part of the complete visual group).
  const expected = [7, 6, 4, 2, 6, 4, 66, 6];
  for (let group = 0; group < 8; group++) {
    const changed = [...original]; changed[group] = bytes([255, 0]);
    assert.deepEqual(result(plan(packet([{ id: 1n, groups: original }], [{ id: 1n, groups: changed }]))).entries, [[1, 0, 0, expected[group]]]);
  }
  const changed = [...original]; changed[3] = bytes([1]); changed[8] = bytes([1]);
  assert.deepEqual(result(plan(packet([{ id: 1n, groups: original }], [{ id: 1n, groups: changed }]))).entries, [[1, 0, 0, 34]]);
});
test("float equality retains NaN repaint and signed-zero parity", () => {
  for (const [left, right, dirty] of [[-0, 0, false], [Infinity, Infinity, false], [NaN, NaN, true], [1, 1.0000001192092896, true]] as const) {
    const a = Array.from({ length: 9 }, () => bytes([])), b = [...a]; a[1] = float(left); b[1] = float(right);
    assert.deepEqual(result(plan(packet([{ id: 1n, groups: a }], [{ id: 1n, groups: b }]))).entries, dirty ? [[1, 0, 0, 6]] : []);
  }
});
test("root resize is limited to surviving root nodes, code masks ignore dormant offsets and bound terminals repaint", () => {
  const roots = [[0, 0, 300, 200], [0, 0, 301, 200]];
  for (const flags of [0, 1, 2, 4]) {
    const a = Array.from({ length: 9 }, () => bytes([])), b = [...a]; b[7] = bytes([1]);
    const entries = result(plan(packet([{ id: 1n, flags, groups: a }], [{ id: 1n, flags, groups: b }], 10, roots))).entries;
    assert.deepEqual(entries, flags === 2 ? [] : [[1, 0, 0, flags === 1 ? 15 : 6]]);
  }
});
test("copied plans survive input mutation and reject malformed framing before classification", () => {
  const input = packet([{ id: 1n }], []), frozen = input.slice(), output = plan(input);
  assert.deepEqual(input, frozen); input.fill(0); assert.deepEqual(result(output).entries, [[0, 0, missing, 7]]);
  for (let length = 0; length < frozen.length; length++) assert.throws(() => plan(frozen.subarray(0, length)));
  const trailing = new Uint8Array(frozen.length + 1); trailing.set(frozen); assert.throws(() => plan(trailing));
  const reserved = frozen.slice(); reserved[20] = 1; assert.throws(() => plan(reserved));
  const invalid = frozen.slice(); invalid[116] = 8; assert.throws(() => plan(invalid));
});

interface RenderState { ids?: (bigint | null)[]; active?: boolean; hover?: number[]; drag?: number[]; offset?: number[] }
interface RenderNode { id: bigint; kind?: number; parent?: number; state?: number; terminal?: number }
function renderPacket(nodes: RenderNode[], before: RenderState, after: RenderState): Uint8Array {
  const b = new Uint8Array(160 + nodes.length * 24), v = wire(b); b.set([25, 1, 1, 0]); v.setUint32(4, nodes.length, true);
  [before, after].forEach((s, n) => {
    const at = 16 + n * 72; let flags = s.active ? 128 : 0;
    for (let i = 0; i < 5; i++) { const id = s.ids?.[i]; if (id !== undefined && id !== null) flags |= 1 << i; v.setBigUint64(at + 8 + i * 8, id ?? 0n, true); }
    if (s.hover) flags |= 32; if (s.drag) flags |= 64; v.setUint32(at, flags, true);
    [...(s.hover ?? [0, 0]), ...(s.drag ?? [0, 0]), ...(s.offset ?? [0, 0])].forEach((f, i) => v.setFloat32(at + 48 + i * 4, f, true));
  });
  nodes.forEach((n, i) => { const at = 160 + i * 24; v.setUint32(at, n.kind ?? 31, true); v.setUint32(at + 4, n.parent ?? missing, true); v.setBigUint64(at + 8, n.id, true); v.setUint32(at + 16, n.state ?? 0, true); v.setUint32(at + 20, n.terminal ?? 0, true); });
  return b;
}
function renderResult(b: Uint8Array) {
  const v = wire(b), count = v.getUint32(4, true), groups = [v.getUint32(8, true), v.getUint32(12, true)]; let at = 32 + count * 16;
  return { flags: v.getUint32(16, true), entries: Array.from({ length: count }, (_, i) => Array.from({ length: 4 }, (_, j) => v.getUint32(32 + i * 16 + j * 4, true))), groups: groups.map(length => Array.from({ length }, () => { const n = v.getUint32(at, true); at += 4; return n; })) };
}
test("menu logical focus and ordinary focus-visible controls project independently", () => {
  const id = 9007199254740993n;
  for (const kind of [31, 41, 44]) {
    const value = renderResult(plan(renderPacket([{ id, kind }], {}, { ids: [id] })));
    assert.deepEqual(value, { flags: 0, entries: kind === 41 ? [[0, 1, 0, 4]] : [], groups: [[], []] });
  }
  assert.deepEqual(renderResult(plan(renderPacket([{ id, state: 4 }], {}, { ids: [0n] }))).entries, []);
});
test("terminal logical focus follows activity and baked focus while ended or cursorless grids stay clean", () => {
  for (let terminal = 0; terminal < 8; terminal++) {
    const value = renderResult(plan(renderPacket([{ id: 1n, kind: 62, state: 4, terminal }], {}, { active: true })));
    assert.deepEqual(value.entries, terminal === 7 ? [[0, 2, 4, 4]] : []);
  }
});
test("focus-within ancestry keeps both ordered ancestor groups and overlay invalidation stays separate", () => {
  const nodes = [{ id: 1n, kind: 60 }, { id: 2n, kind: 60, parent: 0 }, { id: 3n, parent: 1 }, { id: 4n, parent: 0 }];
  const value = renderResult(plan(renderPacket(nodes, { ids: [3n, 3n] }, { ids: [4n, 4n], hover: [0, 1], drag: [2, 3], offset: [4, 5] })));
  assert.deepEqual(value, { flags: 3, entries: [[2, 1, 4, 0], [3, 1, 0, 4]], groups: [[1, 0], [0]] });
  assert.throws(() => plan(renderPacket([{ id: 1n, kind: 60, parent: 0 }], {}, { ids: [1n, 1n] })));
});
test("render changes reject incomplete packets and preserve caller bytes", () => {
  const b = renderPacket([{ id: 1n }], {}, {}), frozen = b.slice(); assert.deepEqual(renderResult(plan(b)), { flags: 0, entries: [], groups: [[], []] }); assert.deepEqual(b, frozen);
  for (let n = 0; n < b.length; n++) assert.throws(() => plan(b.subarray(0, n)));
  b[160] = 63; assert.throws(() => plan(b));
});
