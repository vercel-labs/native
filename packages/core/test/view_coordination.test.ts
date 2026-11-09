import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = ["runtime_policy.ts", "view_coordination.ts"].map(name => readFileSync(new URL(`../src/${name}`, import.meta.url), "utf8")).join("\n");
const { nscvViewCoordination: plan, native_window_policy: dispatch } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport {nscvViewCoordination};").toString("base64")}`);
interface Window { id?: bigint; flags?: number; frame?: number[]; mainFrame?: number[] }
interface View { window?: bigint; label: string; parent?: string; flags?: number; frame?: number[]; local?: number[] }
interface Query { window?: bigint; label?: string; parent?: string; capacity?: number; depth?: number; cursor?: number; clear?: boolean; variant?: number; frame?: number[] }
const wire = (bytes: Uint8Array): DataView => new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
function packet(mode: number, windows: Window[] = [], natives: View[] = [], webviews: View[] = [], q: Query = {}): Uint8Array {
  const bytes = new Uint8Array(192 + windows.length * 64 + (natives.length + webviews.length) * 192), w = wire(bytes);
  bytes.set([80, 1, mode, q.variant ?? 0]);
  w.setUint32(4, windows.length, true); w.setUint32(8, natives.length, true); w.setUint32(12, webviews.length, true); w.setBigUint64(16, q.window ?? 1n, true);
  const text = (at: number, lengthAt: number, value: string | undefined): void => {
    if (value === undefined) { w.setUint32(lengthAt, 0xffffffff, true); return; }
    const b = Buffer.from(value); w.setUint32(lengthAt, b.length, true); bytes.set(b.subarray(0, 64), at);
  };
  const frame = (at: number, values: number[]): void => values.forEach((v, i) => w.setFloat32(at + i * 4, v, true));
  text(64, 24, q.label ?? ""); text(128, 28, q.parent);
  w.setUint32(32, q.capacity ?? 49, true); w.setUint32(36, q.depth ?? 0, true); w.setUint32(40, q.cursor ?? 0, true); w.setUint32(44, q.clear ? 1 : 0, true);
  frame(48, q.frame ?? [0, 0, 0, 0]);
  windows.forEach((v, i) => { const at = 192 + i * 64; w.setBigUint64(at, v.id ?? 1n, true); w.setUint32(at + 8, v.flags ?? 3, true); frame(at + 16, v.frame ?? [40, 50, 320, 240]); frame(at + 32, v.mainFrame ?? [2, 3, 300, 200]); });
  [...natives, ...webviews].forEach((v, i) => {
    const at = 192 + windows.length * 64 + i * 192;
    w.setBigUint64(at, v.window ?? 1n, true); w.setUint32(at + 8, v.flags ?? 7, true); text(at + 64, at + 16, v.label); text(at + 128, at + 20, v.parent);
    frame(at + 32, v.frame ?? [10, 20, 100, 80]); frame(at + 48, v.local ?? [1, 2, 100, 80]);
  });
  return bytes;
}
function result(b: Uint8Array): { status: number; decision: number; selected: number[]; members: number[][]; frame: number[] } {
  const saved = b.slice(), shifted = new Uint8Array(b.length + 19); shifted.set(b, 7);
  const output = plan(shifted.subarray(7, 7 + b.length)); assert.deepEqual(output, dispatch(b)); assert.deepEqual(b, saved);
  const owned = output.slice(); shifted.fill(255); b.fill(255); assert.deepEqual(output, owned);
  const w = wire(output), mode = w.getUint32(4, true), status = w.getUint32(8, true), count = w.getUint32(24, true);
  return { status, decision: w.getUint32(12, true), selected: [w.getUint32(16, true), w.getUint32(20, true)], members: Array.from({ length: count }, (_, i) => [w.getUint32(32 + i * 8, true), w.getUint32(36 + i * 8, true)]), frame: status === 0 && mode >= 4 && mode <= 6 ? Array.from({ length: 4 }, (_, i) => w.getFloat32(32 + i * 4, true)) : [] };
}
test("view coordination lists the complete ordered capacity prefix with exact window identities", () => {
  const id = 0xfedcba9876543210n;
  const views = [{ label: "closed", flags: 6, window: id }, { label: "hidden", flags: 5, window: id }, { label: "other", window: id - 1n }, { label: "enabled", window: id }];
  const all = [[1, 0], [2, 1], [2, 3], [3, 0]];
  for (const capacity of [0, 1, 2, 3, 4, 49]) assert.deepEqual(result(packet(0, [{ id }], views, [{ label: "preview", window: id }], { window: id, capacity })).members, all.slice(0, capacity));
  assert.deepEqual(result(packet(0, [{ flags: 1 }], [{ label: "canvas" }])).members, [[2, 0]]);
  assert.deepEqual(result(packet(0, [{ flags: 2 }], [{ label: "canvas" }])).members, []);
  assert.deepEqual(result(packet(0, [], [{ label: "canvas" }])).members, []);
});
test("view coordination focus wraps from the last eligible focused slot", () => {
  const natives = [{ label: "first", flags: 15 }, { label: "hidden", flags: 13 }, { label: "last", flags: 15 }];
  assert.deepEqual(result(packet(1, [{}], natives, [{ label: "preview" }])).selected, [3, 0]);
  assert.deepEqual(result(packet(1, [{}], natives, [], { variant: 1 })).selected, [2, 0]);
  assert.deepEqual(result(packet(1, [{ flags: 7 }], [], [], { variant: 1 })).selected, [1, 0]);
  assert.deepEqual(result(packet(1, [{}], [{ label: "only" }], [], { variant: 1 })).selected, [2, 0]);
  assert.equal(result(packet(1, [{ flags: 1 }], [{ label: "disabled", flags: 3 }])).status, 4);
  assert.equal(result(packet(1, [{ flags: 2 }], [{ label: "only" }])).status, 1);
});
test("view coordination repairs focus only when no eligible slot already owns it", () => {
  assert.equal(result(packet(2, [{}], [{ label: "focused", flags: 15 }])).decision, 0);
  const r = result(packet(2, [{}], [{ label: "hidden", flags: 13 }, { label: "other" }])); assert.equal(r.decision, 2); assert.deepEqual(r.selected, [1, 0]);
  assert.equal(result(packet(2, [{ flags: 1 }], [{ label: "disabled", flags: 3 }])).decision, 1);
  assert.equal(result(packet(2, [], [{ label: "focused", flags: 15 }])).decision, 1);
});
test("view coordination observes each focus mutation and blur without adding eligibility gates", () => {
  const natives = [{ label: "target", flags: 0 }, { label: "prior", flags: 15 }, { label: "foreign", flags: 15, window: 2n }];
  assert.equal(result(packet(9, [{ flags: 0 }], natives, [], { variant: 2, label: "target" })).decision, 3);
  assert.equal(result(packet(9, [{}], natives, [], { variant: 2, cursor: 1, label: "target" })).decision, 5);
  assert.equal(result(packet(9, [{}], natives, [], { variant: 2, cursor: 2, label: "target" })).decision, 0);
  assert.equal(result(packet(9, [{}], natives, [], { variant: 2, cursor: 1, clear: true })).decision, 5);
  assert.equal(result(packet(9, [{ flags: 0 }], [], [], { variant: 1, label: "main" })).decision, 3);
  assert.equal(result(packet(9, [{}], [], [], { variant: 1, label: "main", clear: true })).decision, 1);
  assert.equal(result(packet(9, [{}], [], [{ label: "preview", flags: 15 }], { variant: 3, label: "main" })).decision, 5);
});
test("view coordination checks exact parent bytes and self-parent error precedence", () => {
  assert.equal(result(packet(3, [], [], [], { label: "missing", parent: "missing" })).status, 3);
  assert.equal(result(packet(3, [], [], [], { label: "child", parent: "missing" })).status, 2);
  assert.equal(result(packet(3, [], [], [], { label: "child", parent: "main" })).status, 2);
  assert.equal(result(packet(3, [{ flags: 0 }], [], [], { label: "child", parent: "main" })).status, 0);
  assert.equal(result(packet(3, [{}], [], [], { window: 9007199254740993n, label: "child", parent: "main" })).status, 2);
  assert.equal(result(packet(3, [{}], [{ label: "日本" }], [], { label: "child", parent: "日本" })).status, 0);
  assert.equal(result(packet(3, [{}], [{ label: "日本", flags: 6 }], [], { label: "child", parent: "日本" })).status, 2);
});
test("view coordination preserves native f32 ancestor accumulation and already-absolute WebView frames", () => {
  const natives = [{ label: "root", frame: [16777216, 7, 100, 80] }, { label: "middle", parent: "root", frame: [1, 2, 90, 70] }, { label: "leaf", parent: "middle", frame: [-16777216, 3, -0, 50] }];
  assert.deepEqual(result(packet(4, [{}], natives, [], { label: "leaf" })).frame, [0, 12, -0, 50]);
  assert.deepEqual(result(packet(4, [{}], natives, [{ label: "preview", parent: "missing", frame: [51, 62, 40, 30] }], { label: "preview" })).frame, [51, 62, 40, 30]);
  assert.deepEqual(result(packet(5, [{}], natives, [], { parent: "middle", frame: [1, 3, 5, 6] })).frame, [16777216, 12, 5, 6]);
  assert.deepEqual(result(packet(6, [{}], natives, [], { parent: "middle", frame: [16777216, 12, 5, 6] })).frame, [0, 3, 5, 6]);
  for (const mode of [5, 6]) assert.deepEqual(result(packet(mode, [], [], [], { frame: [-0, -0, -0, -0] })).frame, [-0, -0, -0, -0]);
});
test("view coordination retains main-frame fallback and geometry depth/error distinctions", () => {
  assert.deepEqual(result(packet(4, [{ flags: 0 }], [], [], { label: "main" })).frame, [0, 0, 320, 240]);
  assert.deepEqual(result(packet(4, [{ flags: 8 }], [], [], { label: "main" })).frame, [2, 3, 300, 200]);
  assert.equal(result(packet(4, [], [], [], { label: "main" })).status, 1);
  assert.equal(result(packet(4, [], [], [], { label: "missing" })).status, 2);
  assert.equal(result(packet(4, [], [], [], { label: "main", depth: 49 })).status, 3);
  const cycle = [{ label: "a", parent: "b" }, { label: "b", parent: "a" }];
  assert.equal(result(packet(4, [{}], cycle, [], { label: "a" })).status, 3);
});
test("view coordination orders raw descendants and OS call phases without filtering closed children", () => {
  const natives = [{ label: "a", parent: "root", flags: 0 }, { label: "nested", parent: "a" }, { label: "b", parent: "root" }], webviews = [{ label: "preview", parent: "root" }, { label: "foreign", parent: "root", window: 2n }];
  for (const variant of [0, 1]) {
    const r = result(packet(7, [{}], natives, webviews, { label: "root", variant })); assert.deepEqual(r.members, [[2, 0], [2, 2], [3, 0]]); assert.equal(r.decision, variant + 1);
  }
  assert.deepEqual(result(packet(7, [{}], natives, webviews, { label: "root", depth: 48 })).members, []);
  for (const [cursor, members] of [[1, [[2, 0]]], [2, []], [3, [[2, 2]]], [33, [[3, 0]]], [34, []]] as const)
    assert.deepEqual(result(packet(7, [{}], natives, webviews, { label: "root", cursor })).members, members);
  assert.throws(() => plan(packet(7, [], [], [], { cursor: 49 })));
});
test("view coordination finds complete subtree focus and independently checks duplicate table labels", () => {
  const natives = [{ label: "root", flags: 0 }, { label: "child", parent: "root" }, { label: "leaf", parent: "child", flags: 15 }];
  assert.equal(result(packet(8, [{}], natives, [], { label: "root" })).decision, 1);
  assert.equal(result(packet(8, [{}], natives, [], { label: "root", depth: 48 })).decision, 0);
  assert.equal(result(packet(8, [{ flags: 7 }], [], [], { label: "main" })).decision, 0);
  assert.equal(result(packet(8, [{}], [{ label: "duplicate" }], [{ label: "duplicate", flags: 15 }], { label: "duplicate" })).decision, 1);
  assert.equal(result(packet(8, [{}], [{ label: "cycle", parent: "cycle" }], [], { label: "cycle" })).decision, 0);
});
test("view coordination rejects malformed observation schemas and bounds", () => {
  const original = packet(0, [{}], [{ label: "test" }]);
  for (const [at, value] of [[0, 79], [1, 0], [2, 11], [3, 1]]) { const b = original.slice(); b[at!] = value!; assert.throws(() => plan(b)); }
  for (const [at, value] of [[4, 17], [8, 33], [12, 17], [32, 50], [44, 2], [192 + 12, 1], [256 + 16, 65]]) { const b = original.slice(); wire(b).setUint32(at!, value!, true); assert.throws(() => plan(b)); }
  assert.throws(() => plan(original.subarray(0, original.length - 1)));
  assert.throws(() => plan(packet(9, [], [], [], { variant: 2 })));
});
