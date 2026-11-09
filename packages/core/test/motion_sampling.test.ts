import assert from "node:assert/strict";
import test from "node:test";
import { stripTypeScriptTypes } from "node:module";
import { readFileSync } from "node:fs";
const source = ["runtime_policy.ts", "motion_sampling.ts"].map(name => readFileSync(new URL(`../src/${name}`, import.meta.url), "utf8")).join("\n") + "\nexport { nscvMotionSampling };";
const { nscvMotionSampling: plan } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source)).toString("base64")}`);
type Animation = { id?: bigint; start?: bigint; duration?: number; loop?: number; easing?: number; spring?: number[]; mask?: number; from?: number; to?: number; rotation?: number[]; center?: number[] };
const f = Math.fround, max = (1n << 64n) - 1n;
function request(records: Animation[], now: bigint, capacity = records.length): Uint8Array {
  const b = new Uint8Array(32 + records.length * 144), w = new DataView(b.buffer);
  b.set([73, 1, 0, 0]); w.setUint32(4, records.length, true); w.setUint32(8, capacity, true); w.setBigUint64(16, now, true);
  records.forEach((a, i) => {
    const at = 32 + i * 144;
    w.setBigUint64(at, a.id ?? 9007199254740993n, true); w.setBigUint64(at + 8, a.start ?? 0n, true);
    w.setUint32(at + 16, a.duration ?? 1, true); w.setUint32(at + 20, a.easing ?? 0, true); w.setUint32(at + 24, a.loop ?? 0, true); w.setUint32(at + 28, a.mask ?? 3, true);
    (a.spring ?? [1, 220, 28]).forEach((v, j) => w.setFloat32(at + 32 + j * 4, v, true));
    w.setFloat32(at + 44, a.from ?? 0, true); w.setFloat32(at + 48, a.to ?? 1, true);
    for (const off of [52, 76]) [1, 0, 0, 1, 0, 0].forEach((v, j) => w.setFloat32(at + off + j * 4, v, true));
    (a.rotation ?? [0, 360]).forEach((v, j) => w.setFloat32(at + 100 + j * 4, v, true));
    (a.center ?? [2, 3]).forEach((v, j) => w.setFloat32(at + 108 + j * 4, v, true));
  }); return b;
}
function checked(bytes: Uint8Array): Uint8Array {
  const before = bytes.slice(), result = plan(bytes); assert.deepEqual(bytes, before); return result;
}
function run(bytes: Uint8Array) {
  const w = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength), batches: number[][] = [];
  for (let step = 0; step < 4; step++) {
    const result = checked(bytes), r = new DataView(result.buffer);
    if (r.getUint32(4, true) !== 1) return { result, batches };
    const ops: number[] = [];
    for (let i = 0; i < r.getUint32(8, true); i++) {
      const at = 32 + i * 16, target = 32 + r.getUint32(at, true) * 144, slot = r.getUint32(at + 4, true), op = r.getUint32(at + 8, true), arg = r.getFloat32(at + 12, true);
      assert.equal(w.getUint32(target + 116, true) & (1 << slot), 0);
      const value = f([Math.exp, Math.cos, Math.sin, Math.sqrt][op]!(arg));
      w.setFloat32(target + 120 + slot * 4, value, true); w.setUint32(target + 116, w.getUint32(target + 116, true) | (1 << slot), true); ops.push(op);
    } batches.push(ops);
  } throw new Error("nonterminating numeric continuation");
}
function phase(start: bigint, now: bigint, duration: number, loop: number): number {
  if (!duration) return 1; if (now <= start) return 0;
  const span = BigInt(duration) * 1000000n, elapsed = now - start;
  if (!loop) return elapsed >= span ? 1 : f(f(Number(elapsed)) / f(Number(span)));
  const rem = elapsed % (loop === 1 ? span * 2n : span), back = loop === 1 && rem >= span;
  const t = f(f(Number(back ? rem - span : rem)) / f(Number(span))); return back ? f(1 - t) : t;
}
test("motion phase preserves all u64 words and large ping-pong divisors", () => {
  for (const start of [0n, 4294967295n, 9007199254740993n, max - 1000000n, max]) for (const duration of [0, 1, 500, 4294967295]) for (const loop of [0, 1, 2]) {
    const span = BigInt(duration) * 1000000n;
    for (const now of new Set([0n, start, start + 1n, start + span - 1n, start + span, start + span * 2n, max].filter(v => v >= 0n && v <= max))) {
      const { result, batches } = run(request([{ start, duration, loop }], now));
      assert.equal(new DataView(result.buffer).getFloat32(52, true), phase(start, now, duration, loop)); assert.equal(batches.length, 0);
    }
  }
});
test("sampling preserves duplicate identities, omitted channels and capacity prefixes", () => {
  const records: Animation[] = [0, 1, 2, 3, 4, 8, 12, 16, 32, 48, 63].map(mask => ({ mask })); records.unshift({ mask: 3, id: 0n } as Animation);
  const full = run(request(records, 500000n)).result, w = new DataView(full.buffer);
  assert.deepEqual(Array.from({ length: w.getUint32(8, true) }, (_, i) => w.getUint32(32 + i * 48, true)), [4, 7, 10, 11]);
  for (let capacity = 0; capacity < 4; capacity++) {
    const result = run(request(records, 500000n, capacity)).result, r = new DataView(result.buffer);
    assert.equal(r.getUint32(4, true), 2); assert.equal(r.getUint32(8, true), capacity);
    assert.deepEqual(result.subarray(32), full.subarray(32, 32 + capacity * 48));
  }
});
test("spring and rotation math requests are batched across the complete input", () => {
  const records = Array.from({ length: 100 }, () => ({ easing: 3, mask: 63 })), bytes = request(records, 125000n);
  const { result, batches } = run(bytes);
  assert.deepEqual(batches.map(v => v.length), [200, 100, 200]);
  assert.deepEqual(batches.map(v => [...new Set(v)]), [[3, 0], [1], [1, 2]]);
  assert.equal(new DataView(result.buffer).getUint32(8, true), 100);
});
test("shared layout progress uses the same eased float32 result as render opacity", () => {
  for (const easing of [0, 1, 2, 3]) for (const now of [0n, 123456n, 999999n, 1000000n]) {
    const a = request([{ easing }], now), b = a.slice(); b[2] = 1;
    assert.equal(new DataView(run(a).result.buffer).getUint32(52, true), new DataView(run(b).result.buffer).getUint32(52, true));
  }
});
test("copied input slices and output owners survive later invocations", () => {
  const bytes = request([{ mask: 3, from: -0, to: -0 }], 0n), backing = new Uint8Array(bytes.length + 13); backing.set(bytes, 7);
  const result = checked(backing.subarray(7, 7 + bytes.length)), copy = result.slice();
  checked(request([], 0n)); backing.fill(255); assert.deepEqual(result, copy);
});
test("sampling refuses malformed headers, reserved words and record tags", () => {
  const good = request([{}], 0n);
  for (let size = 0; size < good.length; size++) assert.throws(() => plan(good.subarray(0, size)), /invalid/);
  for (const at of [0, 1, 2, 3, 4, 12, 24, 28, 52, 56, 60, 148, 172]) { const bad = good.slice(); bad[at] = 255; assert.throws(() => plan(bad), /invalid/); }
  assert.throws(() => plan(new Uint8Array([...good, 0])), /invalid/);
});
