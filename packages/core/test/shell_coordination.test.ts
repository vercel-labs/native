import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = ["runtime_policy.ts", "shell_coordination.ts"].map(n => readFileSync(new URL(`../src/${n}`, import.meta.url), "utf8")).join("\n");
const { nscvShellCoordination: derive, native_window_policy: dispatch } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport {nscvShellCoordination};").toString("base64")}`);
function packet(mode: number, facts = 0, count = 0, cursor = 0, tail = 0): Uint8Array {
  const b = new Uint8Array(64 + tail), w = new DataView(b.buffer);
  b.set([84, 1, mode]); [facts, count, cursor].forEach((v, i) => w.setUint32(4 + i * 4, v, true)); return b;
}
function result(b: Uint8Array): number[] {
  const r = derive(b); assert.deepEqual(r, dispatch(b));
  return Array.from({ length: r.length / 4 }, (_, i) => new DataView(r.buffer).getUint32(i * 4, true));
}
test("shell scene routes complete hybrid windows with hidden and first-present precedence", () => {
  for (const empty of [0, 1]) for (const hidden of [0, 1]) {
    const windows = [[{ kind: 0, label: "main" }], [{ kind: 17, label: "canvas" }], [{ kind: 17, label: "canvas" }, { kind: 0, label: "child" }], []];
    const b = packet(0, empty, windows.length, 0, windows.reduce((n, v) => n + 4 + v.length * 13, 0)), w = new DataView(b.buffer);
    let at = 64;
    for (const views of windows) {
      b[at] = hidden; b[at + 1] = 1; w.setUint16(at + 2, views.length, true); at += 4;
      for (const view of views) { b[at] = view.kind; w.setBigUint64(at + 1, BigInt(view.label.length), true); b.set(new TextEncoder().encode(view.label).subarray(0, 4), at + 9); at += 13; }
    }
    const choices = result(b); assert.equal(choices[3], 1);
    assert.deepEqual(choices.slice(6).map(v => v & 15), [8 | 4 | (hidden ? 1 : 0), 8 | (hidden ? 1 : 2), 8 | (empty ? 0 : 4) | (hidden ? 1 : 2), 8 | (empty ? 0 : 4) | (hidden ? 1 : 0)]);
  }
  assert.equal(result(packet(0, 0))[3], 0);
});
test("shell exact label chunks preserve opaque bytes and long-length admission", () => {
  for (let n = 0; n <= 16; n++) {
    const b = packet(1, 1, n); for (let i = 0; i < n; i++) b[16 + i] = b[32 + i] = i * 17;
    assert.equal(result(b)[3], 1);
    if (n) { b[32 + n - 1]! ^= 1; assert.equal(result(b)[3], 0); }
    new DataView(b.buffer).setUint32(4, 0, true); assert.equal(result(b)[3], 0);
  }
});
test("shell installation keeps main updates, missing-view refusals and reverse rollback", () => {
  for (let facts = 0; facts < 8; facts++) for (const kind of [0, 7, 17]) {
    const update = !!(facts & 1), main = !!(facts & 2) && kind === 0, missing = !!(facts & 4);
    const b = packet(2, facts); new DataView(b.buffer).setUint32(16, kind, true);
    assert.equal(result(b)[3], (main ? 1 : 0) | (!update && !main ? 2 : 4) | (update && missing ? 8 : 0));
  }
  for (let count = 0; count <= 128; count++) for (let cursor = 0; cursor <= count; cursor++) assert.equal(result(packet(3, 0, count, cursor))[4], cursor ? cursor - 1 : 4294967295);
});
test("shell rollback restoration compares raw f32 fields and preserves layer/error order", () => {
  for (let facts = 0; facts < 4; facts++) for (const unequal of [false, true]) for (const layer of [0, 1]) {
    const b = packet(4, facts, 0xffffffff, layer ? 0 : 0xffffffff), w = new DataView(b.buffer);
    for (let i = 0; i < 4; i++) { w.setFloat32(16 + i * 4, i + 0.125, true); w.setFloat32(32 + i * 4, i + 0.125, true); }
    if (unequal) w.setFloat32(32, NaN, true);
    assert.equal(result(b)[3], facts & 1 ? ((facts & 2) || unequal ? 1 : 0) | (layer ? 2 : 0) : 0);
  }
  const signed = packet(4, 1); new DataView(signed.buffer).setFloat32(16, -0, true); assert.equal(result(signed)[3], 0);
});
test("shell bindings retain first exact u64 identity and commit only after copy success", () => {
  const ids = [9007199254740992n, 9007199254740993n, (1n << 64n) - 1n];
  for (const id of [...ids, 0n]) {
    const b = packet(5, 0, ids.length, 0, ids.length * 8), w = new DataView(b.buffer); w.setBigUint64(16, id, true); ids.forEach((v, i) => w.setBigUint64(64 + i * 8, v, true));
    assert.deepEqual(result(b).slice(2, 5), [0, ids.includes(id) ? 0 : 1, ids.includes(id) ? ids.indexOf(id) : ids.length]);
  }
  const b = packet(5, 0, 16, 0, 128), w = new DataView(b.buffer); w.setBigUint64(16, 99n, true);
  assert.deepEqual(result(b).slice(2, 5), [1, 0, 4294967295]);
});
test("shell admission preserves duplicate and native-before-webview capacity precedence", () => {
  for (let facts = 0; facts < 8; facts++) for (const kind of [0, 7, 17]) {
    const b = packet(6, facts); new DataView(b.buffer).setUint32(16, kind, true);
    const main = kind === 0 && (facts & 4) !== 0, duplicate = !!(facts & 1) || !main && !!(facts & 2);
    assert.deepEqual(result(b).slice(2, 4), [duplicate ? 2 : 0, duplicate || main ? 0 : kind === 0 ? 1 : 2]);
  }
  for (const native of [0, 1, 32, 33, 128]) for (const web of [0, 1, 16, 17, 128]) {
    const b = packet(6, 0, 0, 1), w = new DataView(b.buffer); w.setUint32(20, native, true); w.setUint32(24, web, true);
    assert.equal(result(b)[2], native > 32 ? 3 : web > 16 ? 4 : 0);
  }
});
test("shell protocol refuses malformed packets and respects byteOffset", () => {
  const b = packet(7, 5, 2, 0, 2); b.set([0, 17], 64); assert.equal(result(b)[3], 13);
  for (let n = 0; n < b.length; n++) assert.throws(() => derive(b.subarray(0, n)));
  for (const [at, v] of [[0, 83], [1, 2], [2, 8], [3, 1], [48, 1], [63, 1], [64, 19]]) { const copy = b.slice(); copy[at!] = v!; assert.throws(() => derive(copy)); }
  const offset = new Uint8Array(b.length + 12); offset.set(b, 5); assert.deepEqual(derive(offset.subarray(5, 5 + b.length)), derive(b));
});
