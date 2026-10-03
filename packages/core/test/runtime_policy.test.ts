import assert from "node:assert/strict";
import test from "node:test";
import { native_timer_policy, native_db_policy, native_status_policy } from "../src/runtime_policy.ts";

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
  const bad = valid.slice(); bad[0] = 255; assert.throws(() => native_timer_policy(bad), /request/);
  bad[0] = 0; bad[18] = 2; assert.throws(() => native_timer_policy(bad), /slot/);
});

function delayRequest(slots: Slot[], name: Uint8Array, after: number | null, tag = 0, blocked = 0): Uint8Array {
  const bytes = new Uint8Array(2 + name.length + (after === null ? 0 : 10) + slots.reduce((n, s) => n + 3 + s.key.length, 0));
  bytes[0] = after === null ? 3 : 2; bytes[1] = name.length; bytes.set(name, 2);
  let at = 2 + name.length;
  if (after !== null) { new DataView(bytes.buffer).setFloat64(at, after, true); bytes[at + 8] = tag; bytes[at + 9] = blocked; at += 10; }
  for (const s of slots) { bytes[at] = +s.used; bytes[at + 1] = s.key.length; bytes.set(s.key, at + 2); at += 2 + s.key.length; bytes[at++] = s.tag; }
  return bytes;
}

function completion(slot: number, used: number): Uint8Array {
  const bytes = new Uint8Array(20); bytes[0] = 4; bytes[1] = slot;
  new DataView(bytes.buffer).setUint16(2, used, true);
  for (let i = 0; i < 16; i++) bytes[4 + i] = i * 17;
  return bytes;
}

test("delay plans preserve first matching key, independent empty keys and first free slots", () => {
  const slots = empty();
  const names = [key(""), key("reminder"), key("café"), new Uint8Array(255).fill(255), new Uint8Array([0, 255])];
  const intervals = [1, 1.4999999999999998, 1.5, 2.4999999999999996, 700.5, 31535999999.5, 31536000000];
  for (let occupied = 0; occupied <= 16; occupied++) {
    slots.forEach((s, i) => { s.used = i < occupied; s.key = names[i % names.length]!; s.tag = i * 17; });
    for (const name of names) {
      const matching = slots.findIndex(s => s.used && Buffer.from(s.key).equals(name));
      assert.deepEqual([...native_timer_policy(delayRequest(slots, name, null))], [matching < 0 ? 255 : matching]);
      const slot = name.length > 0 && matching >= 0 ? matching : slots.findIndex(s => !s.used);
      for (const after of intervals) for (const tag of [0, 127, 255]) {
        const req = delayRequest(slots, name, after, tag);
        if (slot < 0) { assert.throws(() => native_timer_policy(req), /more than 16/); continue; }
        const out = native_timer_policy(req);
        assert.deepEqual([out[0], out[1], new DataView(out.buffer).getFloat64(2, true)], [slot, tag, Math.round(after)]);
      }
    }
  }
  for (let free = 0; free < 16; free++) {
    slots.forEach((s, i) => { s.used = i !== free; s.key = key("other"); });
    assert.equal(native_timer_policy(delayRequest(slots, key("new"), 1))[0], free);
  }
});

test("delay completions route only armed slots and return an independent retirement plan", () => {
  for (let slot = 0; slot < 16; slot++) for (const used of [0, 1 << slot, 0x5555, 0xaaaa, 0xffff]) {
    const req = completion(slot, used);
    if (!(used & (1 << slot))) { assert.throws(() => native_timer_policy(req), /not armed/); continue; }
    const out = native_timer_policy(req); req.fill(0);
    native_timer_policy(completion(15, 0xffff));
    assert.deepEqual([...out], [slot, slot * 17]);
  }
});

test("delay operations reject truncated tables, invalid occupancy, capacity and interval boundaries", () => {
  for (const valid of [delayRequest(empty(), key("reminder"), 1, 255), delayRequest(empty(), key("reminder"), null), completion(0, 1)]) {
    for (let n = 0; n < valid.length; n++) assert.throws(() => native_timer_policy(valid.subarray(0, n)));
    assert.throws(() => native_timer_policy(new Uint8Array([...valid, 0])));
  }
  for (const after of [NaN, Infinity, -Infinity, 0, 0.99, 31536000001]) assert.throws(() => native_timer_policy(delayRequest(empty(), key("x"), after)), /interval/);
  for (const after of [1, null]) {
    const bad = delayRequest(empty(), key(""), after); bad[after === null ? 2 : 12] = 2;
    assert.throws(() => native_timer_policy(bad), /slot/);
  }
  assert.throws(() => native_timer_policy(completion(16, 0xffff)), /request/);
});


test("delay admission preserves file streams after validating the declaration", () => {
  const slots = empty(); slots.forEach(s => { s.used = true; });
  assert.equal(native_timer_policy(delayRequest(slots, key("file"), 700.5, 255, 1))[0], 255);
  assert.throws(() => native_timer_policy(delayRequest(slots, key("file"), NaN, 0, 1)), /interval/);
  assert.throws(() => native_timer_policy(delayRequest(slots, key("file"), 1, 0, 2)), /admission/);
});


type DbSlot = { used: boolean; live: boolean; key: Uint8Array; signature: Uint8Array };
const dbEmpty = (): DbSlot[] => Array.from({ length: 16 }, () => ({ used: false, live: false, key: key(""), signature: new Uint8Array(8) }));
function dbRequest(slots: DbSlot[], name: Uint8Array | Uint8Array[], signature?: Uint8Array, seen = 0): Uint8Array {
  const retention = Array.isArray(name), keys = retention ? name : [name];
  const prefix = retention ? 5 + keys.reduce((n, k) => n + 1 + k.length, 0) : (signature ? 15 : 2) + keys[0]!.length;
  const bytes = new Uint8Array(prefix + slots.reduce((n, s) => n + 11 + s.key.length, 0));
  const view = new DataView(bytes.buffer); let at = prefix;
  bytes[0] = retention ? 1 : signature ? 2 : 0;
  if (retention) { view.setUint32(1, prefix - 5, true); let pos = 5; for (const k of keys) { bytes[pos++] = k.length; bytes.set(k, pos); pos += k.length; } }
  else if (signature) { view.setUint16(1, seen, true); bytes[3] = keys[0]!.length; bytes.set(keys[0]!, 4); bytes.set(signature, 4 + keys[0]!.length); bytes.set([7, 127, 255], 12 + keys[0]!.length); }
  else { bytes[1] = keys[0]!.length; bytes.set(keys[0]!, 2); }
  for (const s of slots) { bytes[at] = +s.used; bytes[at + 1] = +s.live; bytes[at + 2] = s.key.length; bytes.set(s.key, at + 3); bytes.set(s.signature, at + 3 + s.key.length); at += 11 + s.key.length; }
  return bytes;
}

test("database policy preserves first-match retention, command collisions, slots and exact fingerprint bytes", () => {
  const names = [key("query"), key("café"), new Uint8Array([0, 255]), new Uint8Array(255).fill(255), key("absent")];
  for (let occupied = 0; occupied <= 16; occupied++) for (const live of [false, true]) {
    const slots = dbEmpty(); slots.forEach((s, i) => { s.used = i < occupied; s.live = live; s.key = names[i % 4]!; s.signature.fill(255); });
    for (const name of names) {
      const matching = slots.findIndex(s => s.used && Buffer.from(s.key).equals(name));
      assert.equal(native_db_policy(dbRequest(slots, name))[0], matching < 0 ? 255 : matching);
      assert.equal(new DataView(native_db_policy(dbRequest(slots, [name])).buffer).getUint16(0, true), matching < 0 || !live ? 0 : 1 << matching);
      for (let changedByte = -1; changedByte < 8; changedByte++) {
        const signature = new Uint8Array(8).fill(255); if (changedByte >= 0) signature[changedByte] = 254;
        const slot = matching >= 0 ? matching : slots.findIndex(s => !s.used);
        const req = dbRequest(slots, name, signature, 0x8000 & ~(1 << Math.max(slot, 0)));
        if (slot < 0) { assert.throws(() => native_db_policy(req), /full/); continue; }
        if (matching >= 0 && !live) { assert.throws(() => native_db_policy(req), /collides/); continue; }
        const out = native_db_policy(req), start = matching < 0 || changedByte >= 0;
        assert.deepEqual([...out.subarray(0, 6)], [slot, +start, +(matching >= 0 && start), 7, 127, 255]);
        assert.equal(new DataView(out.buffer).getUint16(6, true), (0x8000 & ~(1 << slot)) | (1 << slot));
        assert.throws(() => native_db_policy(dbRequest(slots, name, signature, 1 << slot)), /duplicate/);
      }
    }
    assert.equal(native_db_policy(dbRequest(slots, key("")))[0], 255);
  }
  const slots = dbEmpty(); slots[0] = { used: true, live: false, key: key("same"), signature: new Uint8Array(8) }; slots[1] = { ...slots[0], live: true };
  assert.deepEqual([...native_db_policy(dbRequest(slots, [key("same"), key("same")]))], [0, 0]);
  for (let hole = 0; hole < 16; hole++) {
    slots.forEach((s, i) => { s.used = i !== hole; s.key = key("occupied"); });
    assert.equal(native_db_policy(dbRequest(slots, key("new"), new Uint8Array(8)))[0], hole);
  }
});

test("database decisions reject damaged records and preserve copied result ownership", () => {
  const requests = [dbRequest(dbEmpty(), key("x")), dbRequest(dbEmpty(), [key("x"), key("y")]), dbRequest(dbEmpty(), key("x"), new Uint8Array(8))];
  for (const request of requests) {
    for (let n = 0; n < request.length; n++) assert.throws(() => native_db_policy(request.subarray(0, n)));
    assert.throws(() => native_db_policy(new Uint8Array([...request, 0])), /trailing/);
    const copy = request.slice(); copy[copy.length - 11] = 2; assert.throws(() => native_db_policy(copy), /slot/);
  }
  assert.throws(() => native_db_policy(dbRequest(dbEmpty(), key(""), new Uint8Array(8))), /non-empty/);
  assert.throws(() => native_db_policy(dbRequest(dbEmpty(), [key("")])), /key list/);
  const request = requests[2]!, out = native_db_policy(request), copy = out.slice(); request.fill(0);
  native_db_policy(requests[0]!); assert.deepEqual(out, copy);
});

interface StatusSlot { active: boolean; id: number }
const statusSlots = (): StatusSlot[] => Array.from({ length: 8 }, () => ({ active: false, id: 0 }));
function statusRequest(slots: StatusSlot[], ids: number[], index = 255, applied = slots.filter(s => s.active).length): Uint8Array {
  const bytes = new Uint8Array(44 + ids.length * 4), data = new DataView(bytes.buffer);
  bytes.set([index === 255 ? 0 : 1, index, ids.length, applied]);
  ids.forEach((id, i) => data.setUint32(4 + i * 4, id, true));
  slots.forEach((slot, i) => { const at = 4 + ids.length * 4 + i * 5; bytes[at] = +slot.active; data.setUint32(at + 1, slot.id, true); });
  return bytes;
}
test("status admission preserves invalid/duplicate refusal, retained lookup and every hole", () => {
  const ids = [0, 7, 4294967295, 7, 2147483648, 100, 200, 300];
  const slots = statusSlots();
  for (let occupied = 0; occupied <= 8; occupied++) {
    slots.forEach((s, i) => { s.active = i < occupied; s.id = ids[(i + 1) % ids.length]!; });
    ids.forEach((id, index) => {
      const matching = slots.findIndex(s => s.active && s.id === id), free = slots.findIndex(s => !s.active);
      const invalid = id === 0 || ids.slice(0, index).includes(id);
      const want = invalid ? [0, 255] : matching >= 0 ? [3, matching] : free >= 0 ? [2, free] : [1, 255];
      assert.deepEqual([...native_status_policy(statusRequest(slots, ids, index))], want);
    });
  }
  for (let hole = 0; hole < 8; hole++) {
    slots.forEach((s, i) => { s.active = i !== hole; s.id = 10 + i; });
    assert.deepEqual([...native_status_policy(statusRequest(slots, [99], 0))], [2, hole]);
    assert.deepEqual([...native_status_policy(statusRequest(slots, [99], 0, 8))], [1, 255]);
    const matching = hole === 0 ? 1 : 0;
    assert.deepEqual([...native_status_policy(statusRequest(slots, [slots[matching]!.id], 0, 8))], [3, matching]);
  }
});
test("status retirement sees all declarations, including duplicates and raw zero ids", () => {
  const slots = statusSlots();slots.forEach((s, i) => { s.active = true; s.id = i; });
  for (let mask = 0; mask < 256; mask++) {
    const ids = slots.filter((_, i) => mask & (1 << i)).map(s => s.id);
    assert.deepEqual([...native_status_policy(statusRequest(slots, ids))], [255 & ~mask, 255]);
  }
  // An invalid duplicate still retains a live identity during the earlier
  // retirement phase; later admission ignores its repeated declaration.
  assert.deepEqual([...native_status_policy(statusRequest(slots, [0, 2, 2]))], [250, 255]);
});
test("status patch plans compare every opaque hash byte independently", () => {
  const bytes = new Uint8Array(49);bytes[0] = 2;
  for (let i = 0; i < 24; i++) bytes[1 + i] = bytes[25 + i] = 255 - i;
  assert.deepEqual([...native_status_policy(bytes)], [0, 255]);
  for (let mask = 0; mask < 8; mask++) for (let byte = 0; byte < 8; byte++) {
    const request = bytes.slice();
    for (let field = 0; field < 3; field++) if (mask & (1 << field)) request[1 + field * 8 + byte]! ^= 1;
    assert.deepEqual([...native_status_policy(request)], [mask, 255]);
  }
});
test("status requests refuse malformed tables and preserve offset views", () => {
  const slots = statusSlots();const requests = [statusRequest(slots, [1], 0), statusRequest(slots, []), new Uint8Array(49)];requests[2]![0] = 2;
  for (const request of requests) {
    for (let n = 0; n < request.length; n++) assert.throws(() => native_status_policy(request.subarray(0, n)));
    assert.throws(() => native_status_policy(new Uint8Array([...request, 0])));
    const padded = new Uint8Array(request.length + 8);padded.set(request, 4);
    assert.deepEqual(native_status_policy(padded.subarray(4, 4 + request.length)), native_status_policy(request));
  }
  const corrupt = statusRequest(slots, [1], 0);corrupt[1] = 1;assert.throws(() => native_status_policy(corrupt));
  corrupt[1] = 0;corrupt[3] = 9;assert.throws(() => native_status_policy(corrupt));
  corrupt[3] = 0;corrupt[8] = 2;assert.throws(() => native_status_policy(corrupt));
  corrupt[8] = 0;corrupt[0] = 3;assert.throws(() => native_status_policy(corrupt));
});
