import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = ["runtime_policy.ts", "canvas_scene_observation.ts"].map(name => readFileSync(new URL(`../src/${name}`, import.meta.url), "utf8")).join("\n");
const { nscvCanvasSceneObservation: plan, native_window_policy: dispatch } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport {nscvCanvasSceneObservation};").toString("base64")}`);
function request(mode: number, previous: (bigint | null)[] = [], current: (bigint | null)[] = []): Uint8Array {
  const bytes = new Uint8Array(mode > 2 ? 128 : 64 + (previous.length + current.length) * 32), w = new DataView(bytes.buffer);
  bytes.set([76, 1, mode, 0]); w.setUint32(4, previous.length, true); w.setUint32(8, current.length, true);
  if (mode === 0) { w.setBigUint64(16, 1n, true); w.setBigUint64(32, 0xffffffffffffffffn, true); }
  [...previous, ...current].forEach((id, i) => { if (id !== null) { w.setUint32(64 + i * 32, 1, true); w.setBigUint64(68 + i * 32, id, true); } });
  return bytes;
}
function checked(bytes: Uint8Array): DataView {
  const before = bytes.slice(), backing = new Uint8Array(bytes.length + 29); backing.set(bytes, 13);
  const result = plan(backing.subarray(13, 13 + bytes.length));
  assert.deepEqual(bytes, before); assert.deepEqual(result, dispatch(bytes));
  const copy = result.slice(); backing.fill(255); bytes.fill(255); assert.deepEqual(result, copy);
  assert.equal(new DataView(result.buffer, result.byteOffset, result.byteLength).getUint32(0, true), 1);
  assert.deepEqual(result.slice(32, 64), new Uint8Array(32));
  return new DataView(result.buffer, result.byteOffset, result.byteLength);
}
test("scene diff preserves exact identities, duplicate first matches and ordered removals", () => {
  const ids = [null, 0n, 1n, 0x100000000n, 9007199254740993n, 0xffffffffffffffffn];
  for (const id of ids) {
    const out = checked(request(0, [id, 7n, id], [id, id, 9n]));
    const expected = id === null ? [[1, 1, 0xffffffff], [0, 0xffffffff, 2]] : [[1, 1, 0xffffffff], [2, 0, 0], [2, 0, 1], [0, 0xffffffff, 2]];
    assert.equal(out.getUint32(4, true), expected.length);
    expected.forEach((row, i) => assert.deepEqual([0, 4, 8].map(at => out.getUint32(64 + i * 16 + at, true)), row));
  }
});
test("scene diff keeps exact revisions and the first action beyond output capacity", () => {
  for (const revision of [0n, 0x100000000n, 9007199254740993n, 0xffffffffffffffffn]) {
    const bytes = request(0, [1n], [2n]), w = new DataView(bytes.buffer); w.setBigUint64(16, revision, true); w.setBigUint64(24, revision, true);
    assert.equal(checked(bytes).byteLength, 64);
  }
  for (const capacity of [0n, 1n, 2n, 0x100000000n]) {
    const bytes = request(0, [1n, 2n], [3n]), w = new DataView(bytes.buffer); w.setBigUint64(32, capacity, true);
    assert.equal(checked(bytes).getUint32(4, true), Number(capacity > 2n ? 3n : capacity + 1n));
  }
  for (const same of [true, false]) {
    const bytes = request(0), w = new DataView(bytes.buffer); w.setBigUint64(16, 9007199254740993n, true); w.setBigUint64(24, same ? 9007199254740993n : 9007199254740992n, true); w.setUint32(40, 1, true);
    assert.equal(checked(bytes).getUint32(8, true), same ? 0 : 1);
  }
});
test("scene probes request only the next unkeyed bounds and stop on the first present result", () => {
  for (const observed of [0, 1, 2]) for (const start of [0, 1, 2, 3, 4]) {
    const bytes = request(1, [], [0n, null, 9n, null]), w = new DataView(bytes.buffer); w.setUint32(12, start, true); w.setUint32(40, observed, true);
    const out = checked(bytes); assert.equal(out.getUint32(4, true), observed === 2 ? 1 : 0);
    if (observed !== 2) assert.equal(out.getUint32(8, true), start <= 1 ? 1 : start <= 3 ? 3 : 4);
  }
  for (let flags = 0; flags < 4; flags++) {
    const bytes = request(2, [], [1n]), w = new DataView(bytes.buffer); w.setUint32(64, flags, true); if ((flags & 1) === 0) w.setBigUint64(68, 0n, true);
    assert.equal(checked(bytes).getUint32(4, true), flags === 2 ? 1 : 0);
  }
});
function rect(bytes: Uint8Array, at: number, values: number[] | null): void {
  const w = new DataView(bytes.buffer); w.setUint32(at, values === null ? 0 : 1, true);
  if (values !== null) values.forEach((v, i) => w.setFloat32(at + 4 + i * 4, v, true));
}
test("scene bounds normalize single unions and project clipped damage into host coordinates", () => {
  const bytes = request(3); rect(bytes, 64, [-0, 4, -8, -2]);
  const union = checked(bytes); assert.deepEqual([16, 20, 24, 28].map(at => union.getFloat32(at, true)), [-8, 2, 8, 2]);
  const project = request(4); rect(project, 64, [100, 50, -64, 48]); rect(project, 96, [-1, 2, 8, 6]);
  const out = checked(project); assert.deepEqual([16, 20, 24, 28].map(at => out.getFloat32(at, true)), [36, 52, 7, 6]);
  const empty = request(4); rect(empty, 64, [0, 0, 64, 48]); rect(empty, 96, [100, 2, 8, 6]); assert.equal(checked(empty).getUint32(4, true), 0);
});
test("scene clear colors use float32 clamp multiplication and round-to-byte preparation", () => {
  const bytes = request(5), w = new DataView(bytes.buffer); [-1, 0.5, 1, Infinity].forEach((v, i) => w.setFloat32(64 + i * 4, v, true));
  const out = checked(bytes); assert.deepEqual([16, 17, 18, 19].map(at => out.getUint8(at)), [0, 128, 255, 255]);
  const nan = request(5); new DataView(nan.buffer).setFloat32(64, NaN, true);
  assert.equal(checked(nan).getUint8(16), 255);
  for (const macos of [0, 1]) { const bytes = request(6); new DataView(bytes.buffer).setUint32(64, macos, true); assert.equal(checked(bytes).getFloat32(16, true), macos === 1 ? 3 : 1); }
});
test("scene observation rejects truncated, invalid and unclaimed transport fields", () => {
  for (const mode of [0, 1, 2, 3, 4, 5, 6]) {
    const bytes = request(mode);
    for (let length = 0; length < bytes.length; length++) assert.throws(() => plan(bytes.subarray(0, length)));
    const extra = new Uint8Array(bytes.length + 1); extra.set(bytes); assert.throws(() => plan(extra));
    for (const at of [0, 1, 2, 3, 44, 48, 52, 56, 60]) { const bad = bytes.slice(); bad[at] = 255; assert.throws(() => plan(bad)); }
  }
});
