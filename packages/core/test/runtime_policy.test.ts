import assert from "node:assert/strict";
import test from "node:test";
import { native_timer_policy } from "../src/runtime_policy.ts";

interface Slot { used: boolean; key: Uint8Array; every: number; tag: number }
const empty = (): Slot[] => Array.from({ length: 16 }, () => ({ used: false, key: new Uint8Array(0), every: 0, tag: 0 }));
const key = (s: string) => new TextEncoder().encode(s);
function request(slots: Slot[], name: Uint8Array, every: number, tag: number, seen = 0): Uint8Array {
  const bytes = new Uint8Array(13 + name.length + slots.reduce((n, s) => n + 10 + s.key.length, 0));
  const data = new DataView(bytes.buffer); data.setUint16(1, seen, true); bytes[3] = name.length; bytes.set(name, 4);
  let at = 4 + name.length; data.setFloat64(at, every, true); bytes[at + 8] = tag; at += 9;
  for (const s of slots) { bytes[at] = +s.used; bytes[at + 1] = s.key.length; bytes.set(s.key, at + 2); at += 2 + s.key.length; data.setFloat64(at, s.every, true); at += 8; }
  return bytes;
}
function reference(slots: Slot[], name: Uint8Array, every: number, tag: number, seen: number): number[] {
  let slot = -1;
  slots.forEach((s, i) => { if (s.used && Buffer.from(s.key).equals(name)) slot = i; });
  if (slot < 0) slot = slots.findIndex(s => !s.used);
  if (slot < 0) throw new Error("capacity");
  return [slot, +(slots[slot]!.used === false || slots[slot]!.every !== every), tag, Math.round(every), seen | (1 << slot)];
}
const decode = (out: Uint8Array): number[] => {
  const data = new DataView(out.buffer, out.byteOffset, out.byteLength);
  return [out[0]!, out[1]!, out[2]!, data.getFloat64(4, true), data.getUint16(12, true)];
};

test("timer plans match slot order, exact intervals, duplicate keys, routes and masks", () => {
  const slots = empty();
  const names = [key(""), key("pulse"), key("café"), new Uint8Array(255).fill(255), new Uint8Array([0, 255])];
  const intervals = [1, 1.4999999999999998, 1.5, 2.4999999999999996, 500.5, 31535999999.5, 31536000000];
  for (let occupied = 0; occupied <= 16; occupied++) {
    slots.forEach((s, i) => { s.used = i < occupied; s.key = names[i % names.length]!; s.every = intervals[i % intervals.length]!; });
    for (const name of names) for (const every of intervals) for (const tag of [0, 127, 255]) for (const seen of [0, 1, 0x5555, 0xffff]) {
      const want = reference(slots, name, every, tag, seen);
      assert.deepEqual(decode(native_timer_policy(request(slots, name, every, tag, seen))), want);
    }
  }
  // First free means first slot, regardless of prior cancelled keys.
  for (let free = 0; free < 16; free++) {
    slots.forEach((s, i) => { s.used = i !== free; s.key = key("other"); s.every = 1; });
    assert.equal(decode(native_timer_policy(request(slots, key("new"), 1, 0)))[0], free);
  }
  slots.forEach(s => { s.used = true; });
  assert.throws(() => native_timer_policy(request(slots, key("new"), 1, 0)), /more than 16/);
});

test("timer retirement preserves all used/seen combinations per slot", () => {
  for (let bit = 0; bit < 16; bit++) for (const used of [0, 1 << bit, 0xffff]) for (const seen of [0, 1 << bit, 0xffff]) {
    const bytes = new Uint8Array(5), data = new DataView(bytes.buffer); bytes[0] = 1; data.setUint16(1, used, true); data.setUint16(3, seen, true);
    assert.equal(new DataView(native_timer_policy(bytes).buffer).getUint16(0, true), used & ~seen);
  }
});

test("malformed timer requests fail before publishing a plan", () => {
  const valid = request(empty(), key("pulse"), 1, 255);
  for (let n = 0; n < valid.length; n++) assert.throws(() => native_timer_policy(valid.subarray(0, n)), /timer/);
  assert.throws(() => native_timer_policy(new Uint8Array([...valid, 0])), /trailing/);
  for (const every of [NaN, Infinity, -Infinity, 0, 0.99, 31536000001]) assert.throws(() => native_timer_policy(request(empty(), key("x"), every, 0)), /interval/);
  const bad = valid.slice(); bad[0] = 2; assert.throws(() => native_timer_policy(bad), /request/);
  bad[0] = 0; bad[18] = 2; assert.throws(() => native_timer_policy(bad), /slot/);
});
