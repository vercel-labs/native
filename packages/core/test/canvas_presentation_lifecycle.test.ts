import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = ["runtime_policy.ts", "canvas_presentation_lifecycle.ts"].map(name => readFileSync(new URL(`../src/${name}`, import.meta.url), "utf8")).join("\n");
const { nscvCanvasPresentationLifecycle: plan, native_window_policy: dispatch } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport {nscvCanvasPresentationLifecycle};").toString("base64")}`);
function request(mode: number, flags = 0, checked = true): Uint8Array {
  const bytes = new Uint8Array(128); bytes.set([77, 1, mode, checked ? 1 : 0]); new DataView(bytes.buffer).setUint32(4, flags, true); return bytes;
}
function set(bytes: Uint8Array, at: number, value: bigint): void { new DataView(bytes.buffer).setBigUint64(at, value, true); }
function checked(bytes: Uint8Array): DataView {
  const saved = bytes.slice(), backing = new Uint8Array(bytes.length + 19); backing.set(bytes, 7);
  const result = plan(backing.subarray(7, 7 + bytes.length));
  assert.deepEqual(bytes, saved); assert.deepEqual(result, dispatch(bytes));
  const copy = result.slice(); backing.fill(255); bytes.fill(255); assert.deepEqual(result, copy);
  assert.deepEqual(result.slice(40), new Uint8Array(24));
  return new DataView(result.buffer, result.byteOffset, result.byteLength);
}
test("presentation lifecycle preserves explicit software and missing-view admission", () => {
  for (const flags of [0, 2, 4, 6]) assert.equal(checked(request(0, flags)).getUint32(4, true), flags === 6 ? 4 : 1);
  const wide = [0n, 1n, 0x100000000n, 9007199254740993n, 0xffffffffffffffffn];
  for (let flags = 0; flags < 16; flags++) for (const commands of wide) for (const capacity of wide) {
    const bytes = request(1, flags); set(bytes, 8, commands); set(bytes, 16, capacity);
    const out = checked(bytes), render = (flags & 1) !== 0, wanted = (flags & 6) !== 6;
    const offered = render && wanted && commands !== 0n && capacity !== 0n;
    assert.equal(out.getUint32(4, true), !render ? 0 : offered && (flags & 8) !== 0 ? 1 : 4);
    assert.equal(out.getUint32(8, true), offered && (flags & 8) === 0 ? 1 : 0);
  }
});
test("presentation lifecycle keeps combined refusal and direct unrepresentable negotiation distinct", () => {
  for (const ok of [false, true]) {
    assert.equal(checked(request(2, ok ? 16 : 0)).getUint32(4, true), ok ? 2 : 4);
    assert.equal(checked(request(3, ok ? 32 : 0)).getUint32(4, true), ok ? 3 : 4);
    assert.equal(checked(request(4, ok ? 32 : 0)).getUint32(4, true), ok ? 5 : 4);
    const direct = checked(request(11, ok ? 16 : 0)); assert.equal(direct.getUint32(4, true), 2); assert.equal(direct.getUint32(8, true), ok ? 1 : 2);
    assert.equal(checked(request(12, ok ? 1 : 0)).getUint32(4, true), ok ? 5 : 0);
  }
});
test("pixel scratch and retained-baseline decisions compare complete unsigned extents", () => {
  const words = [0n, 1n, 0xffffffffn, 0x100000000n, 9007199254740993n, 0xffffffffffffffffn];
  for (const capacity of words) for (const needed of words) for (const render of [false, true]) {
    const bytes = request(5, render ? 1 : 0); set(bytes, 24, capacity); set(bytes, 32, needed);
    assert.equal(checked(bytes).getUint32(12, true), render && capacity >= needed ? 1 : 0);
  }
  for (const enabled of [false, true]) assert.equal(checked(request(6, enabled ? 64 : 0)).getUint32(4, true), enabled ? 6 : 8);
  for (const present of [false, true]) assert.equal(checked(request(7, present ? 128 : 0)).getUint32(4, true), present ? 7 : 8);
});
test("image upload admission preserves missing indices and zero metadata before host calls", () => {
  for (const index of [0n, 1n, 0x100000000n, 0xffffffffffffffffn]) for (const count of [0n, 1n, 0x100000000n, 0xffffffffffffffffn]) for (const flags of [0, 256, 512, 768]) {
    const bytes = request(9, flags); set(bytes, 72, index); set(bytes, 80, count);
    assert.equal(checked(bytes).getUint32(4, true), flags === 768 && index < count ? 9 : 0);
  }
  for (let mask = 0; mask < 8; mask++) {
    const bytes = request(10); [88, 96, 104].forEach((at, i) => set(bytes, at, mask & (1 << i) ? 0x100000000n : 0n));
    assert.equal(checked(bytes).getUint32(4, true), mask === 7 ? 2 : 0);
  }
});
test("fallback diagnostics preserve exact counters, rate limits and checked short-circuiting", () => {
  const max = 0xffffffffffffffffn;
  for (const safety of [false, true]) for (const changed of [false, true]) for (const count of [0n, 1n, 118n, 119n, 120n, 0xffffffffn, 9007199254740993n, max]) for (const logged of [0n, 1n, 118n, 0xffffffffn, 9007199254740993n, max]) {
    const bytes = request(8, 0, safety), w = new DataView(bytes.buffer); set(bytes, 40, count); set(bytes, 48, logged); set(bytes, 56, 0x100000000n); set(bytes, 64, 32n);
    w.setUint32(112, 4, true); w.setUint32(116, changed ? 3 : 4, true);
    const out = checked(bytes), increment = (count + 1n) & max;
    const overflow = safety && (count === max || increment !== 1n && !changed && increment < logged);
    const log = !overflow && (increment === 1n || changed || ((increment - logged) & max) >= 120n);
    assert.equal(out.getUint32(12, true), overflow ? 4 : log ? 2 : 0);
    assert.equal(out.getBigUint64(16, true), safety && count === max ? count : increment);
    assert.equal(out.getBigUint64(24, true), log ? increment : logged);
    assert.equal(out.getBigUint64(32, true), 32n);
  }
});
test("presentation lifecycle rejects incomplete envelopes and unclaimed reserved fields", () => {
  for (let mode = 0; mode <= 12; mode++) {
    const bytes = request(mode);
    for (let len = 0; len < bytes.length; len++) assert.throws(() => plan(bytes.subarray(0, len)));
    for (const at of [0, 1, 2, 3, 4, 112, 116, 120, 124]) { const bad = bytes.slice(); bad[at] = 255; if (at === 4) bad[at + 1] = 255; assert.throws(() => plan(bad)); }
    const extra = new Uint8Array(bytes.length + 1); extra.set(bytes); assert.throws(() => plan(extra));
  }
});
test("presentation lifecycle retains checked and wrapping 32-bit host counters", () => {
  for (const safety of [false, true]) {
    const bytes = request(8, 0, safety); bytes[3]! |= 2; set(bytes, 40, 0xffffffffn);
    const out = checked(bytes); assert.equal(out.getUint32(12, true), safety ? 4 : 0);
    assert.equal(out.getBigUint64(16, true), safety ? 0xffffffffn : 0n);
  }
  const invalid = request(5); invalid[3] = 2; set(invalid, 24, 0x100000000n); assert.throws(() => plan(invalid));
});
