import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = ["runtime_policy.ts", "render_resources.ts", "terminal_paint.ts"].map(n => readFileSync(new URL(`../src/${n}`, import.meta.url), "utf8")).join("\n");
const { nscvTerminalPaint: paint, native_window_policy: dispatch } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport { nscvTerminalPaint };").toString("base64")}`);
function viewport(cps: number[] = [65, 66], capacity = 100): Uint8Array {
  const bytes = new Uint8Array(272 + 16 + cps.length * 49), w = new DataView(bytes.buffer); bytes.set([78, 1, 0, 5]);
  w.setUint32(4, 3, true); w.setUint32(8, 1, true); w.setUint32(16, capacity, true); w.setUint32(28, 32768, true); w.setUint32(44, 2048, true);
  w.setUint32(64, 0xffffffff, true); w.setUint32(68, 0xfffffffe, true);
  for (const [at, value] of [[80, 300], [84, 100], [104, 13], [108, 8], [112, 18]]) w.setFloat32(at!, value!, true);
  w.setUint32(272, cps.length, true);
  cps.forEach((cp, i) => { const at = 288 + i * 49; w.setUint32(at, cp, true); w.setUint32(at + 8, 1, true); for (let j = 0; j < 4; j++) w.setFloat32(at + 16 + j * 4, 1, true); bytes[at + 48] = cp; });
  return bytes;
}
function checked(b: Uint8Array): Uint8Array {
  const before = b.slice(), out = paint(b); assert.deepEqual(b, before); assert.deepEqual(out, dispatch(b));
  const backing = new Uint8Array(b.length + 17); backing.set(b, 9); assert.deepEqual(out, paint(backing.subarray(9, 9 + b.length)));
  const copy = out.slice(); b.fill(255); assert.deepEqual(out, copy); return out;
}
test("terminal paint preserves copied run bytes and exact high command identities", () => {
  const out = checked(viewport()), w = new DataView(out.buffer); assert.equal(w.getUint32(4, true), 4); assert.equal(w.getUint32(12, true), 2);
  assert.deepEqual(Array.from(out.subarray(32 + 4 * 96)), [65, 66]);
  const at = 32 + 2 * 96; assert.equal(w.getUint32(at, true), 3);
  const base = BigInt.asUintN(64, 0xfffffffeffffffffn << 24n);
  assert.equal(w.getBigUint64(at + 4, true), BigInt.asUintN(64, base + 0x8000n));
  assert.equal(w.getFloat32(at + 20, true), 13.875);
});
test("terminal paint keeps whole row stops and exact error prefixes", () => {
  for (let capacity = 0; capacity <= 4; capacity++) {
    const out = checked(viewport([65, 66], capacity)), w = new DataView(out.buffer);
    assert.equal(w.getUint32(4, true), Math.min(capacity, 4)); assert.equal(w.getUint32(20, true), capacity < 4 ? 1 : 0);
  }
  const b = viewport(); new DataView(b.buffer).setUint32(20, 11, true); const out = checked(b), w = new DataView(out.buffer);
  assert.equal(w.getUint32(4, true), 3); assert.equal(w.getUint32(16, true), 0);
  const textStop = viewport(); new DataView(textStop.buffer).setUint32(36, 32767, true); assert.equal(new DataView(checked(textStop).buffer).getUint32(16, true), 0);
});
test("terminal metrics retain measured fractional pitch, rounding and bounded grid tradeoffs", () => {
  for (const [size, measured, width, height] of [[13, 128.5, 8.03125, 18], [13, 0, 8, 18], [-0, 0, -0, -0]]) {
    const b = new Uint8Array(16), w = new DataView(b.buffer); b.set([78, 1, 1, 0]); w.setFloat32(4, size!, true); w.setFloat32(8, measured!, true);
    const out = new DataView(checked(b).buffer); assert.ok(Object.is(out.getFloat32(4, true), width)); assert.ok(Object.is(out.getFloat32(8, true), height));
  }
  for (const [cols, rows, x, y] of [[0, 0, 2, 2], [400, 100, 320, 22], [4294967295, 4294967295, 320, 22]]) {
    const b = new Uint8Array(16), w = new DataView(b.buffer); b.set([78, 1, 2, 0]); w.setUint32(4, cols!, true); w.setUint32(8, rows!, true);
    const out = new DataView(checked(b).buffer); assert.equal(out.getUint32(4, true), x); assert.equal(out.getUint32(8, true), y);
  }
});
test("terminal paint rejects malformed viewport transport before drawing", () => {
  const good = viewport();
  for (const length of [0, 3, 271, 272, good.length - 1]) assert.throws(() => paint(good.subarray(0, length)), /invalid|truncated/);
  for (const [at, value] of [[4, 32], [8, 4294967295], [28, 32767], [44, 2047], [60, 1], [248, 1], [276, 2], [296, 4294967295], [292, 3], [300, 1]]) {
    const bad = good.slice(); new DataView(bad.buffer).setUint32(at!, value!, true); assert.throws(() => paint(bad), /invalid|truncated/);
  }
});
