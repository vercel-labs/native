import assert from "node:assert/strict";
import test from "node:test";
import { native_window_policy } from "../src/runtime_policy.ts";

interface View { kind: number; label: number[]; parent?: number[]; edge?: number; axis?: number; fill?: boolean; geometry?: (number | null)[] }
const label = (s: string) => [...new TextEncoder().encode(s)];
function request(views: View[]): Uint8Array {
  const bytes = new Uint8Array(19 + views.reduce((n, v) => n + 41 + v.label.length + (v.parent?.length ?? 0), 0));
  const data = new DataView(bytes.buffer); bytes[0] = 2; data.setUint16(1, views.length, true);
  data.setFloat32(11, 800, true); data.setFloat32(15, 600, true); let at = 19;
  for (const view of views) {
    bytes[at++] = view.kind; bytes[at++] = view.edge ?? 255; bytes[at++] = view.axis ?? 0; bytes[at++] = +!!view.fill;
    const values = Array.from({ length: 8 }, (_, field) => view.geometry?.[field] ?? null);
    bytes[at++] = values.reduce<number>((mask, value, field) => mask | (value === null ? 0 : 1 << field), 0);
    for (const value of values) { data.setFloat32(at, value ?? 0, true); at += 4; }
    data.setUint16(at, view.label.length, true); at += 2; bytes.set(view.label, at); at += view.label.length;
    data.setUint16(at, view.parent?.length ?? 65535, true); at += 2;
    if (view.parent) { bytes.set(view.parent, at); at += view.parent.length; }
  }
  assert.equal(at, bytes.length); return bytes;
}
function decode(bytes: Uint8Array) {
  const data = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  return { refused: !!bytes[0], items: Array.from({ length: data.getUint16(1, true) }, (_, i) => {
    const at = 3 + i * 50;
    return { index: data.getUint16(at, true), rects: Array.from({ length: 12 }, (_, f) => data.getFloat32(at + 2 + f * 4, true)) };
  }) };
}

test("shell fill preconsumes later docks and nested main frames are absolute", () => {
  const result = decode(native_window_policy(request([
    { kind: 0, label: label("main"), parent: label("stack"), geometry: [2, 3, 100, 60] },
    { kind: 17, label: label("fill"), fill: true },
    { kind: 1, label: label("top"), edge: 0 },
    { kind: 3, label: label("side"), edge: 3 },
    { kind: 6, label: label("stack"), geometry: [20, 30, 300, 80] },
  ])));
  assert.equal(result.refused, false);
  assert.deepEqual(result.items.map(item => item.index), [1, 2, 3, 4, 0]);
  assert.deepEqual(result.items[0]!.rects.slice(0, 4), [240, 48, 560, 552]);
  assert.deepEqual(result.items[4]!.rects, [2, 3, 100, 60, 22, 33, 100, 60, 22, 33, 100, 60]);
});

test("shell stack explicit positions do not advance cursors while split positions do", () => {
  for (const kind of [5, 6]) {
    const out = decode(native_window_policy(request([
      { kind, label: label("p"), geometry: [0, 0, 300, 80] },
      { kind: 7, label: label("explicit"), parent: label("p"), geometry: [20, 0, 50, 32] },
      { kind: 7, label: label("next"), parent: label("p"), geometry: [null, null, 40, 32] },
    ])));
    assert.equal(out.items[2]!.rects[0], kind === 5 ? 70 : 8);
  }
});

test("shell unresolved graphs retain the complete valid prefix and raw label identity", () => {
  const out = decode(native_window_policy(request([
    { kind: 7, label: [1], parent: [255, 0] },
    { kind: 6, label: [255, 0], parent: [1] },
    { kind: 15, label: [255, 1], geometry: [0, 0, 32, 24] },
  ])));
  assert.equal(out.refused, true); assert.deepEqual(out.items.map(item => item.index), [2]);
  assert.deepEqual(out.items[0]!.rects, [0, 0, 32, 24, 0, 0, 32, 24, 0, 0, 32, 24]);
});

test("shell duplicate parent labels select the first recorded declaration", () => {
  const out = decode(native_window_policy(request([
    { kind: 6, label: label("dup"), parent: label("later"), geometry: [null, null, 80, 40] },
    { kind: 0, label: label("main"), parent: label("dup"), geometry: [2, 0, 16, 24] },
    { kind: 5, label: label("dup"), geometry: [5, 0, 200, 80] },
    { kind: 6, label: label("later"), geometry: [40, 0, 400, 160] },
  ])));
  assert.deepEqual(out.items.map(item => item.index), [2, 3, 0, 1]);
  assert.equal(out.items[3]!.rects[8], 7);
});

test("shell requests reject malformed data and honor input byte offsets", () => {
  const valid = request([{ kind: 7, label: label("button") }]);
  for (let length = 0; length < valid.length; length++) assert.throws(() => native_window_policy(valid.subarray(0, length)));
  assert.throws(() => native_window_policy(new Uint8Array([...valid, 0])), /trailing/);
  for (const [offset, value] of [[1, 129], [19, 19], [20, 4], [21, 2], [22, 2]]) {
    const bad = valid.slice(); bad[offset!] = value!; assert.throws(() => native_window_policy(bad), /invalid/);
  }
  const padded = new Uint8Array(valid.length + 13); padded.set(valid, 7);
  assert.deepEqual(native_window_policy(padded.subarray(7, 7 + valid.length)), native_window_policy(valid));
  const retained = native_window_policy(valid); valid.fill(255);
  native_window_policy(request([]));
  assert.equal(decode(retained).items[0]!.rects[2], 96);
});
