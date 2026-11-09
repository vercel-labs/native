import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = ["runtime_policy.ts", "window_lifecycle.ts"].map(name => readFileSync(new URL(`../src/${name}`, import.meta.url), "utf8")).join("\n");
const { nscvWindowLifecycle: plan, native_window_policy: dispatch } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport {nscvWindowLifecycle};").toString("base64")}`);
interface Window { id?: bigint; flags?: number; label?: string }
interface View { id?: bigint; active?: boolean }
interface Query { id?: bigint; variant?: number; value?: boolean; cursor?: number; target?: number; saved?: number; outcome?: number; label?: string; active?: boolean; frame?: number[] }
function packet(mode: number, windows: Window[] = [], views: View[] = [], q: Query = {}): Uint8Array {
  const bytes = new Uint8Array(128 + windows.length * 128 + views.length * 16), w = new DataView(bytes.buffer);
  bytes.set([81, 1, mode, q.variant ?? 0]); w.setUint32(4, windows.length, true); w.setUint32(8, views.length, true); w.setUint32(12, q.value ? 1 : 0, true); w.setBigUint64(16, q.id ?? 1n, true);
  w.setUint32(24, q.cursor ?? 0, true); w.setUint32(28, q.target ?? 0, true); w.setUint32(32, q.saved ?? 0, true); w.setUint32(36, q.outcome ?? 0, true); w.setUint32(44, q.active === false ? 0 : 1, true);
  const text = (at: number, lengthAt: number, value: string): void => { const b = Buffer.from(value); w.setUint32(lengthAt, b.length, true); bytes.set(b, at); };
  text(64, 40, q.label ?? ""); (q.frame ?? [0, 0, 0, 0]).forEach((v, i) => w.setFloat32(48 + i * 4, v, true));
  windows.forEach((v, i) => { const at = 128 + i * 128; w.setBigUint64(at, v.id ?? 1n, true); w.setUint32(at + 8, v.flags ?? 11, true); text(at + 64, at + 12, v.label ?? "main"); });
  views.forEach((v, i) => { const at = 128 + windows.length * 128 + i * 16; w.setBigUint64(at, v.id ?? 1n, true); w.setUint32(at + 8, v.active ? 1 : 0, true); });
  return bytes;
}
function result(b: Uint8Array): number[] {
  const saved = b.slice(), shifted = new Uint8Array(b.length + 17); shifted.set(b, 7);
  const output = plan(shifted.subarray(7, 7 + b.length)); assert.deepEqual(output, dispatch(b)); assert.deepEqual(b, saved);
  const owned = output.slice(); shifted.fill(255); b.fill(255); assert.deepEqual(output, owned);
  const w = new DataView(output.buffer, output.byteOffset, output.byteLength); return Array.from({ length: 16 }, (_, i) => w.getUint32(i * 4, true));
}
test("window lifecycle preserves exact identity and verb-specific liveness admission", () => {
  for (const id of [1n, 9007199254740993n, 0xfedcba9876543210n, 0xffffffffffffffffn]) for (let state = 0; state < 32; state++) for (let verb = 0; verb < 5; verb++) {
    const r = result(packet(0, [{ id: id - 1n }, { id, flags: state }], [], { id, variant: verb }));
    assert.equal(r[2], verb > 0 && !(state & 1) ? 1 : 0); assert.equal(r[3], 1);
    assert.equal(result(packet(0, [{ id: id - 1n }], [], { id, variant: verb }))[2], 1);
  }
});
test("window lifecycle stages exact flags before capabilities and retains hidden focus routing", () => {
  for (let state = 0; state < 32; state++) {
    const close = result(packet(0, [{ flags: state }])); assert.deepEqual(close.slice(4, 8), [0, 7, 0, 0]);
    if (!(state & 1)) continue;
    assert.deepEqual(result(packet(0, [{ flags: state }], [], { variant: 1 })).slice(4, 8), [0, 6, 4, 0]);
    assert.deepEqual(result(packet(0, [{ flags: state }], [], { variant: 2 })).slice(4, 8), [0, 4, 0, 0]);
    assert.equal(result(packet(0, [{ flags: state }], [], { variant: 3 }))[4], state & 4 ? 16 : 0);
  }
});
test("window lifecycle rolls back only original fields and admits only the replay close exception", () => {
  for (let verb = 0; verb < 4; verb++) for (let saved = 0; saved < 8; saved++) for (let outcome = 0; outcome < 3; outcome++) for (const replay of [false, true]) {
    const r = result(packet(1, [{}], [], { variant: verb, saved, outcome, value: replay }));
    const rollback = outcome !== 0 && !(verb === 0 && replay && outcome === 2);
    const mask = rollback ? [7, 6, 4, 0][verb]! : 0;
    assert.equal(r[4], rollback ? 8 : [3, 2, 6, 6][verb]); assert.equal(r[5], mask); assert.equal(r[6], saved & mask);
  }
  assert.equal(result(packet(1, [{ flags: 1 }], [], { variant: 2 }))[4], 2);
});
test("window lifecycle observes passive show after callback rather than freezing admission flags", () => {
  assert.equal(result(packet(1, [{ flags: 9 }], [], { variant: 2 }))[4], 6);
  assert.equal(result(packet(1, [{ flags: 1 }], [], { variant: 2 }))[4], 2);
  assert.equal(result(packet(1, [{ flags: 0 }], [], { variant: 3 }))[4], 6);
});
test("window lifecycle projects keyboard gates by current exact window and application activity", () => {
  const id = 9007199254740993n;
  for (const active of [false, true]) for (const focused of [false, true]) for (const prior of [false, true]) {
    for (const variant of [0, 1]) {
      const r = result(packet(3, [{ id, flags: focused ? 3 : 1 }], [{ id, active: prior }], { variant, value: focused, active }));
      assert.equal(r[7], active && focused ? 1 : 0); assert.equal(r[4], prior !== (active && focused) ? 1 : 0);
    }
  }
  assert.equal(result(packet(3, [{ id }], [{ id: 1n, active: true }], { value: true }))[4], 0);
  assert.deepEqual(result(packet(3, [{ id }], [{ id: 1n, active: true }], { variant: 1 })).slice(4, 8), [1, 0, 0, 0]);
});
test("window lifecycle records each focus edge and exact focused-index projection", () => {
  for (let flags = 0; flags < 32; flags++) for (const value of [false, true]) {
    const r = result(packet(2, [{ flags }], [], { value })); assert.equal(r[4], flags & 2 && !value ? 32 : 0); assert.equal(r[5], 2); assert.equal(r[6], value ? 2 : 0);
  }
  assert.equal(result(packet(6, [{}, {}], [], { cursor: 1, target: 1 }))[7], 1);
  assert.equal(result(packet(6, [{}], [], { target: 0xffffffff }))[7], 0);
});
test("window lifecycle derives host flags and preserves f32 content bits and authored main bounds", () => {
  for (let saved = 0; saved < 8; saved++) for (const main of [false, true]) {
    const r = result(packet(4, [{ flags: main ? 16 : 0 }], [], { saved, frame: [91, -53, -0, Infinity] }));
    assert.equal(r[4], (saved & 2 ? 4 : 16) | (main ? 0 : 128)); assert.equal(r[5], 5); assert.equal(r[6], saved & 5);
    assert.deepEqual(r.slice(8, 12), main ? [0, 0, 0, 0] : [0, 0, 0x80000000, 0x7f800000]);
  }
});
test("window lifecycle replay uses complete opaque labels and retained closed-slot admission", () => {
  for (const label of ["main", "日本\0panel", "a".repeat(64)]) for (const closed of [false, true]) {
    const r = result(packet(5, [{ label: "other" }, { label }], [], { label, value: closed }));
    assert.equal(r[3], 1); assert.equal(r[4], closed ? 3 : 6); assert.equal(r[5], closed ? 7 : 4);
    assert.equal(result(packet(5, [{ label, flags: 0 }], [], { label, value: closed }))[4], 64);
  }
  assert.equal(result(packet(5, [{ label: "main" }], [], { label: "absent" }))[4], 64);
  const oversized = packet(5, [{ label: "a".repeat(64) }]);
  new DataView(oversized.buffer).setUint32(40, 65, true);
  assert.equal(result(oversized)[4], 64);
});
test("window lifecycle transport refuses truncated and malformed bounds before table access", () => {
  const valid = packet(3, [{}], [{}]);
  for (let length = 0; length < valid.length; length++) assert.throws(() => plan(valid.subarray(0, length)));
  for (const [offset, value] of [[0, 80], [1, 2], [2, 7], [3, 5], [4, 17], [8, 33], [12, 2], [24, 1], [28, 1], [32, 32], [36, 3], [40, 65], [44, 2], [128 + 8, 32], [128 + 12, 65], [128 + 16, 1], [128 + 60, 1], [256 + 8, 2], [256 + 12, 1]]) {
    const changed = valid.slice(); new DataView(changed.buffer).setUint32(offset!, value!, true); assert.throws(() => plan(changed));
  }
});
