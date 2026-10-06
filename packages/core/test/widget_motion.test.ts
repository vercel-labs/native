import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = readFileSync(new URL("../src/widget_motion.ts", import.meta.url), "utf8");
const { nscvWidgetMotion: policy } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport { nscvWidgetMotion };").toString("base64")}`);
function packet(op: number, n: number, flags = 0, mode = 0) { const r = new Uint8Array(n); r.set([18, op, flags, mode]); return r; }
const view = (r: Uint8Array) => new DataView(r.buffer, r.byteOffset, r.byteLength);
test("split admission preserves refusal, no-op, retarget, reduction and full-table snaps", () => {
  const r = packet(0, 24, 7 | 32 | 64), w = view(r); w.setUint32(4, 180, true); w.setFloat32(8, 0.5, true); w.setFloat32(12, 0.25, true);
  assert.deepEqual([...policy(r)], [2, 0, 1, 1]); r[2] = 7; assert.deepEqual([...policy(r)], [1, 0, 0, 0]);
  r[2] = 7 | 8 | 64; w.setFloat32(16, 0.25, true); assert.deepEqual([...policy(r)], [0, 0, 0, 0]);
  w.setFloat32(16, 0.75, true); assert.deepEqual([...policy(r)], [3, 0, 1, 1]);
  r[2] |= 16; assert.deepEqual([...policy(r)], [1, 1, 0, 0]); w.setFloat32(8, 0.25, true); assert.deepEqual([...policy(r)], [0, 1, 0, 0]);
  for (let f = 0; f < 128; f++) { r[2] = f; assert.equal(policy(r)[0] === 255, (f & 7) !== 7); }
});
test("source tweens yield to pressed dividers and keep the unset-value sentinel", () => {
  const r = packet(1, 16), w = view(r); w.setUint32(4, 100, true); w.setFloat32(8, 0.3, true);
  for (let flags = 0; flags < 8; flags++) { r[2] = flags; assert.equal(policy(r)[0], flags === 3 ? 1 : 0); }
  r[2] = 3; w.setFloat32(8, -0, true); assert.equal(policy(r)[0], 0); w.setFloat32(8, 0.2, true); w.setUint32(4, 0, true); assert.equal(policy(r)[0], 0);
});
function disclosure(nodes = 2, flips = 8, moves = 256) {
  const r = packet(2, 24 + nodes * 64), w = view(r); w.setUint32(4, 180, true); w.setUint32(8, nodes, true); w.setUint32(12, nodes, true); w.setUint32(16, flips, true); w.setUint32(20, moves, true);
  for (let i = 0; i < nodes; i++) for (let lane = 0; lane < 2; lane++) { const at = 24 + (lane * nodes + i) * 32; w.setBigUint64(at, 9007199254740993n + BigInt(i), true); r[at + 8] = i === 0 ? 14 : 26; w.setFloat32(at + 24, 100, true); w.setFloat32(at + 28, 20, true); }
  return r;
}
test("disclosure plans require stable identity and vertical geometry, including echoes and exact IDs", () => {
  const r = disclosure(), w = view(r), next = 24 + 64; r[next + 9] = 1; w.setFloat32(next + 28, 80, true); w.setFloat32(next + 32 + 20, 80, true);
  let out = policy(r); assert.equal(out[0], 1); assert.equal(view(out).getUint32(4, true), 1); assert.equal(view(out).getUint32(8, true), 2); assert.equal(view(out).getBigUint64(16, true), 9007199254740993n);
  r[next + 9] = 0; r[next + 10] = 1; assert.equal(policy(r)[0], 1);
  r[2] = 1; w.setFloat32(next + 16, 1, true); assert.equal(policy(r)[0], 3); w.setFloat32(next + 16, 0, true); r[3] = 1; assert.equal(policy(r)[0], 3);
  r[3] = 0; r[next + 10] = 0; assert.equal(policy(r)[0], 2);
  w.setBigUint64(next, 9007199254740992n, true); assert.equal(policy(r)[0], 3);
  const small = disclosure(2, 0, 0); small[24 + 64 + 9] = 1; assert.equal(policy(small)[0], 0);
});
test("drag reflow preserves unchanged clocks and uses current offsets or the terminal landing pose", () => {
  const r = packet(3, 72, 1), w = view(r); w.setUint32(4, 180, true); w.setUint32(8, 1, true); w.setUint32(12, 64, true); w.setBigUint64(24, 18446744073709551615n, true); w.setUint32(32, 3 | 4, true); w.setFloat32(36, 10, true); w.setFloat32(44, 20, true); w.setFloat32(52, 4, true);
  let out = policy(r); assert.equal(view(out).getUint32(4, true), 1); assert.equal(view(out).getFloat32(16, true), -6);
  w.setFloat32(44, 10, true); out = policy(r); assert.equal(view(out).getUint32(12, true), 1);
  w.setUint32(32, 3 | 8, true); w.setFloat32(60, 33, true); out = policy(r); assert.equal(view(out).getUint32(12, true), 0); assert.equal(view(out).getFloat32(16, true), 23);
  r[3] = 1; assert.equal(view(policy(r)).getUint32(4, true), 0); assert.equal(policy(r)[0], 1);
});
test("pose samples round each f32 operation and settle to the exact target word", () => {
  const r = packet(4, 32), w = view(r); const a = Math.fround(0.33333334), b = Math.fround(100001.17), p = Math.fround(0.731);
  w.setFloat32(4, p, true); w.setFloat32(8, a, true); w.setFloat32(12, b, true);
  assert.equal(view(policy(r)).getFloat32(4, true), Math.fround(a + Math.fround(Math.fround(b - a) * p)));
  w.setFloat32(4, 1, true); w.setUint32(12, 0x80000000, true); assert.equal(view(policy(r)).getUint32(4, true), 0x80000000);
  r[3] = 3; w.setFloat32(4, p, true); assert.equal(view(policy(r)).getFloat32(4, true), Math.fround(a * Math.fround(1 - p)));
});
test("recorded clocks preserve all u64 words and restart only for zero or backward time", () => {
  const words = [0n, 1n, 0xffffffffn, 0x100000000n, 9007199254740993n, 0xffffffffffffffffn];
  for (const start of words) for (const stamp of words) { const r = packet(5, 24), w = view(r); w.setBigUint64(8, start, true); w.setBigUint64(16, stamp, true); assert.equal(view(policy(r)).getBigUint64(0, true), start === 0n || stamp < start ? stamp : start); }
});
test("caret admission clears stale animation owners, holds after activity and refuses overflow", () => {
  const r = packet(6, 40), w = view(r); w.setBigUint64(8, 9007199254740993n, true); w.setBigUint64(16, 9007199254740992n, true); w.setBigUint64(24, 9007199254740993n, true);
  for (let f = 0; f < 64; f++) { r[2] = f; const out = policy(r); assert.equal(out[0], 1); assert.equal(out[1], f === 63 ? 1 : 0); }
  assert.equal(view(policy(r)).getBigUint64(16, true), 9007199754740993n); w.setBigUint64(8, 9007199254740992n, true); assert.equal(policy(r)[0], 0);
  w.setBigUint64(24, 0xffffffffffffffffn, true); assert.throws(() => policy(r), /overflow/);
});
test("loop phases reuse exact anchors and match saturating integer stagger math", () => {
  for (const period of [0, 1, 1200, 4294967295]) for (const count of [3, 12, 15]) for (const existing of [false, true]) for (const start of [0n, 1000000000n, 9007199254740993n]) for (let segment = 0; segment < count; segment++) {
    const r = packet(7, 48, 31 | (existing ? 32 : 0), 1), w = view(r); w.setUint32(4, period, true); w.setUint32(8, count, true); w.setUint32(12, segment, true); w.setUint32(16, 64, true); w.setFloat32(20, 0.15, true); w.setBigUint64(24, start, true); w.setBigUint64(32, start, true);
    const ns = BigInt(Math.max(1, period)) * 1000000n, anchor = existing ? start : start >= ns ? start - ns : 0n;
    const out = policy(r); assert.equal(view(out).getBigUint64(8, true), anchor + ns / BigInt(count) * BigInt(segment)); assert.equal(out[0], 1);
    w.setUint32(16, count - 1, true); assert.equal(policy(r)[0], 0);
  }
});
test("loop retirement preserves declaration order and distinguishes adjacent wide identities", () => {
  const r = packet(8, 40), w = view(r); w.setUint32(4, 2, true); w.setUint32(8, 1, true); w.setBigUint64(16, 9007199254740992n, true); w.setBigUint64(24, 9007199254740993n, true); w.setBigUint64(32, 9007199254740992n, true);
  const out = policy(r); assert.equal(view(out).getUint32(0, true), 1); assert.equal(view(out).getUint32(4, true), 1);
  const frozen = out.slice(); r.fill(255); assert.deepEqual(out, frozen);
});
test("all operations refuse every truncation, extra byte, reserved word and excessive capacity", () => {
  const loop = packet(7, 48); const retirement = packet(8, 16);
  for (const r of [packet(0, 24), packet(1, 16), disclosure(), packet(3, 24), packet(4, 32), packet(5, 24), packet(6, 40), loop, retirement]) {
    for (let n = 0; n < r.length; n++) assert.throws(() => policy(r.slice(0, n)));
    assert.throws(() => policy(new Uint8Array([...r, 0])));
  }
  const r = disclosure(); view(r).setUint32(16, 9, true); assert.throws(() => policy(r));
  const d = packet(3, 24); view(d).setUint32(12, 65, true); assert.throws(() => policy(d));
});
