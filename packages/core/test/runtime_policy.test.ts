import { native_status_policy } from "../src/runtime_policy.ts";
import { native_theme_policy } from "../src/runtime_policy.ts";
import assert from "node:assert/strict";
import test from "node:test";
import { native_timer_policy, native_db_policy, native_effect_policy } from "../src/runtime_policy.ts";

const lifecycle = (...bytes: number[]) => native_effect_policy(new Uint8Array([18, ...bytes]));
test("app lifecycle plans order installation and flush after the committed update", () => {
  assert.deepEqual([...lifecycle(1, 1, 1, 1, 1)], [1, 4, 5, 6, 7, 8, 9, 10, ...Array(24).fill(0)]);
  assert.deepEqual([...lifecycle(1, 0, 1, 1, 0).subarray(0, 8)], [2, 4, 6, 7, 8, 9, 10, 0]);
  assert.deepEqual([...lifecycle(1, 0, 0, 1, 0).subarray(0, 8)], [3, 4, 6, 7, 8, 9, 10, 0]);
  assert.deepEqual([...lifecycle(1, 0, 0, 0, 0).subarray(0, 6)], [4, 7, 8, 9, 10, 0]);
  for (const event of [2, 4]) {
    assert.deepEqual([...lifecycle(0, event, 1, 0, 0).subarray(0, 2)], [1, 0]);
    assert.deepEqual([...lifecycle(0, event, 0, 0, 0).subarray(0, 2)], [0, 1]);
  }
  // An intervening ordinary event preserves the pending post-commit flush.
  assert.deepEqual([...lifecycle(0, 1, 0, 1, 0).subarray(0, 2)], [1, 0]);
  assert.deepEqual([...lifecycle(0, 5, 0, 1, 0).subarray(0, 2)], [0, 1]);
  assert.deepEqual([...lifecycle(0, 5, 0, 0, 0).subarray(0, 2)], [0, 0]);
});

test("app restore plans preserve replay isolation, migration refusal and complete reasons", () => {
  assert.equal(lifecycle(2, 0, 1, 1)[0], 0);
  assert.equal(lifecycle(2, 1, 1, 1)[0], 1);
  assert.equal(lifecycle(2, 1, 0, 1)[0], 2);
  assert.equal(lifecycle(2, 1, 0, 0)[0], 3);
  const request = new Uint8Array(16); request.set([18, 3, 2, 1, 1, 0]);
  const data = new DataView(request.buffer);
  for (const [low, high, outcome] of [[16777215, 0, 0], [16777216, 0, 0], [16777217, 0, 6], [0, 1, 6], [0xffffffff, 0xffffffff, 6]]) {
    data.setUint32(8, low!, true); data.setUint32(12, high!, true);
    const plan = native_effect_policy(request);
    assert.equal(plan[0], outcome);
    assert.deepEqual([...plan.subarray(1, 6)], outcome === 0 ? [1, 2, 3, 0, 1] : [3, 0, 0, 0, 0]);
  }
  request[4] = 0; assert.equal(native_effect_policy(request)[0], 4);
  request[2] = 0; request[5] = 0;
  assert.deepEqual([...native_effect_policy(request).subarray(0, 6)], [0, 1, 0, 0, 0, 1]);
  request[3] = 0; assert.equal(native_effect_policy(request)[0], 255);
  for (const [outcome, reason] of ["", "", "corrupt", "version_unknown", "migrate_failed", "io_failed", "rejected"].entries()) {
    const plan = lifecycle(4, outcome);
    assert.equal(plan[0], outcome === 0 ? 1 : outcome === 1 ? 2 : 3);
    assert.equal(new TextDecoder().decode(plan.subarray(2, 2 + plan[1]!)), reason);
  }
  assert.equal(lifecycle(5, 0)[0], 0);
  assert.equal(new TextDecoder().decode(lifecycle(5, 1).subarray(2, 11)), "io_failed");
  assert.equal(new TextDecoder().decode(lifecycle(5, 2).subarray(2, 10)), "rejected");
});

test("app launch plans keep declaration order, old-journal fallback and exact index carry", () => {
  const request = new Uint8Array(32); request.set([18, 6, 1]);
  const data = new DataView(request.buffer); data.setUint32(16, 3, true);
  assert.deepEqual([...native_effect_policy(request).subarray(0, 2)], [1, 1]);
  data.setUint32(8, 2, true);
  for (let i = 0; i < 3; i++) {
    data.setUint32(24, i, true);
    const plan = native_effect_policy(request);
    assert.equal(plan[0], i < 2 ? 2 : 0);
    if (i < 2) assert.equal(new DataView(plan.buffer).getUint32(16, true), i + 1);
  }
  data.setUint32(8, 0, true); data.setUint32(12, 2, true); data.setUint32(24, 0xffffffff, true);
  const plan = native_effect_policy(request), out = new DataView(plan.buffer);
  assert.equal(out.getUint32(8, true), 0xffffffff);
  assert.equal(out.getUint32(16, true), 0); assert.equal(out.getUint32(20, true), 1);
  request[2] = 0; assert.equal(native_effect_policy(request)[0], 0);
});

test("app carrier plans reserve only exact persistence verbs and preserve worker ordering", () => {
  for (const operation of [0, 1]) for (const name of ["core.persist", "core.persist.flush", "core.persist.more", "core.persist\0", "service.read", ""]) {
    const bytes = new TextEncoder().encode(name);
    const request = new Uint8Array(3 + bytes.length); request.set([18, 7, operation]); request.set(bytes, 3);
    assert.equal(native_effect_policy(request)[0], name === "core.persist" || name === "core.persist.flush" ? 2 : 1);
  }
  for (let operation = 2; operation < 8; operation++)
    assert.deepEqual([...lifecycle(7, operation).subarray(0, 2)], operation < 5 ? [1, 0] : [1, 2]);
});

test("app lifecycle rejects malformed packets and retains borrowed input and owned output", () => {
  const packets = [
    [18, 0, 4, 1, 0, 0], [18, 1, 1, 1, 1, 1], [18, 2, 1, 1, 1],
    [18, 3, 2, 1, 1, 0, 0, 0, ...Array(8).fill(0)], [18, 4, 6], [18, 5, 2],
    [18, 6, 1, ...Array(29).fill(0)], [18, 7, 5],
  ];
  for (const bytes of packets) {
    const wrapped = new Uint8Array(bytes.length + 13).fill(211), request = wrapped.subarray(7, 7 + bytes.length);
    request.set(bytes); const frozen = wrapped.slice(), plan = native_effect_policy(request), owned = plan.slice();
    assert.deepEqual(wrapped, frozen);
    native_effect_policy(new Uint8Array(bytes)); assert.deepEqual(plan, owned);
    for (let length = 0; length < request.length; length++) assert.throws(() => native_effect_policy(request.subarray(0, length)));
    assert.throws(() => native_effect_policy(new Uint8Array([...bytes, 0])));
  }
  for (const packet of [[18, 8], [18, 0, 6, 0, 0, 0], [18, 0, 0, 2, 0, 0], [18, 1, 0, 0, 2, 0], [18, 2, 0, 2, 0], [18, 4, 7], [18, 5, 3], [18, 7, 8]])
    assert.throws(() => native_effect_policy(new Uint8Array(packet)));
  const restore = new Uint8Array(packets[3]!); restore[6] = 1;
  assert.throws(() => native_effect_policy(restore));
  const env = new Uint8Array(packets[6]!); env[7] = 1;
  assert.throws(() => native_effect_policy(env));
});

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

interface EffectSlot { used: boolean; dropped: boolean; key: Uint8Array; ok: number; err: number }
const effectEmpty = (): EffectSlot[] => Array.from({ length: 16 }, (_, i) => ({ used: false, dropped: false, key: key(""), ok: i * 16, err: 255 - i * 16 }));
function effectRequest(slots: EffectSlot[], name: Uint8Array, blocked?: boolean): Uint8Array {
  const bytes = new Uint8Array(2 + name.length + (blocked === undefined ? 0 : 3) + slots.reduce((n, s) => n + 5 + s.key.length, 0));
  bytes[0] = blocked === undefined ? 1 : 0; bytes[1] = name.length; bytes.set(name, 2);
  let at = 2 + name.length;
  if (blocked !== undefined) { bytes[at++] = +blocked; bytes[at++] = 127; bytes[at++] = 255; }
  for (const s of slots) { bytes[at++] = +s.used; bytes[at++] = +s.dropped; bytes[at++] = s.key.length; bytes.set(s.key, at); at += s.key.length; bytes[at++] = s.ok; bytes[at++] = s.err; }
  return bytes;
}
function effectCompletion(slots: EffectSlot[], slot: number, kind: number, ok: number, cut: number): Uint8Array {
  const bytes = new Uint8Array(69); bytes.set([2, slot, kind, ok, cut]);
  slots.forEach((s, i) => bytes.set([+s.used, +s.dropped, s.ok, s.err], 5 + i * 4));
  return bytes;
}

test("named effects retain dropped slots, match first live keys and allocate independent empty keys", () => {
  const slots = effectEmpty();
  const names = [key(""), key("read"), key("café"), new Uint8Array([0, 255]), new Uint8Array(255).fill(255)];
  for (let occupied = 0; occupied <= 16; occupied++) for (let drops = 0; drops < 4; drops++) {
    slots.forEach((s, i) => { s.used = i < occupied; s.dropped = (i + drops) % 3 === 0; s.key = names[i % names.length]!; });
    for (const name of names) {
      const match = slots.findIndex(s => s.used && !s.dropped && Buffer.from(s.key).equals(name));
      const free = slots.findIndex(s => !s.used);
      assert.deepEqual([...native_effect_policy(effectRequest(slots, name))], [match < 0 ? 255 : match]);
      for (const blocked of [false, true]) assert.deepEqual([...native_effect_policy(effectRequest(slots, name, blocked))], [
        +!blocked, blocked || free < 0 ? 255 : free, blocked || name.length === 0 || match < 0 ? 255 : match, 127, 255,
      ]);
    }
  }
  for (let hole = 0; hole < 16; hole++) {
    slots.forEach((s, i) => { s.used = i !== hole; s.dropped = false; s.key = key("same"); });
    assert.equal(native_effect_policy(effectRequest(slots, key("same"), false))[1], hole);
  }
  slots.forEach(s => { s.used = true; s.dropped = false; s.key = key("same"); });
  assert.deepEqual([...native_effect_policy(effectRequest(slots, key("same"), false))], [1, 255, 0, 127, 255]);
});

test("named completions preserve route, payload shape, truncation and silent-drop retirement", () => {
  const slots = effectEmpty(); slots.forEach(s => { s.used = true; });
  for (let slot = 0; slot < 16; slot++) for (let kind = 0; kind < 4; kind++) for (const ok of [0, 1]) for (const cut of [0, 1]) for (const dropped of [false, true]) {
    slots[slot]!.dropped = dropped;
    const s = slots[slot]!, success = ok === 1 && !(kind === 3 && cut === 1);
    assert.deepEqual([...native_effect_policy(effectCompletion(slots, slot, kind, ok, cut))], [slot,
      dropped || !success ? s.err : s.ok, dropped ? 0 : success ? kind + 1 : 5,
      dropped || success ? 0 : ok === 1 && kind === 3 && cut === 1 ? 2 : 1,
    ]);
  }
});

test("named policy rejects malformed tables and returns owned results without mutating inputs", () => {
  const slots = effectEmpty(); slots[0]!.used = true; slots[0]!.key = key("read");
  for (const req of [effectRequest(slots, key("read")), effectRequest(slots, key("read"), false), effectCompletion(slots, 0, 3, 1, 1)]) {
    for (let n = 0; n < req.length; n++) assert.throws(() => native_effect_policy(req.subarray(0, n)));
    assert.throws(() => native_effect_policy(new Uint8Array([...req, 0])));
    const before = req.slice(), out = native_effect_policy(req), result = out.slice();
    assert.deepEqual(req, before); req.fill(0); native_effect_policy(effectRequest(slots, key("new"), true)); assert.deepEqual(out, result);
  }
  for (const [slot, kind, ok, cut] of [[16, 0, 1, 0], [0, 4, 1, 0], [0, 0, 2, 0], [0, 0, 1, 2], [1, 0, 1, 0]]) assert.throws(() => native_effect_policy(effectCompletion(slots, slot!, kind!, ok!, cut!)));
  const bad = effectRequest(slots, key(""), false); bad[2] = 2; assert.throws(() => native_effect_policy(bad), /admission/);
  bad[2] = 0; bad[5] = 2; assert.throws(() => native_effect_policy(bad), /slot/);
  bad[5] = 1; bad[6] = 2; assert.throws(() => native_effect_policy(bad), /slot/);
});

function windowRequest(operation: number, live: readonly (readonly [Uint8Array, Uint8Array])[], declared: readonly Uint8Array[] = [], name = key("new"), canvas = key("new-canvas")): Uint8Array {
  const out: number[] = [operation];
  const label = (bytes: Uint8Array) => { const size = new Uint8Array(4); new DataView(size.buffer).setUint32(0, bytes.length, true); out.push(...size, ...bytes); };
  if (operation === 0) { out.push(declared.length); declared.forEach(label); }
  else { label(key("main")); label(name); label(canvas); }
  out.push(live.length); live.forEach(([a, b]) => { label(a); label(b); });
  return new Uint8Array(out);
}

import { native_window_policy } from "../src/runtime_policy.ts";
test("window plans preserve opaque keys, first-match lookup and admission order", () => {
  const names = [key(""), key("new"), key("other"), key("café"), new Uint8Array([0, 255]), new Uint8Array(64).fill(255), new Uint8Array(65).fill(255)];
  const canvases = [key(""), key("main"), key("new-canvas"), key("occupied"), new Uint8Array([0, 255]), new Uint8Array(64).fill(255), new Uint8Array(65).fill(255)];
  for (let count = 0; count <= 4; count++) {
    const live = Array.from({ length: count }, (_, i) => [names[1 + i % 4]!, key("occupied")] as const);
    for (const name of names) for (const canvas of canvases) {
      const index = live.findIndex(([label]) => Buffer.from(label).equals(name));
      const expected = index >= 0 ? [1, index] : count === 4 ? [2, 255] :
        name.length === 0 || name.length > 64 || canvas.length === 0 || canvas.length > 64 ? [3, 255] :
        Buffer.from(canvas).equals(key("main")) || live.some(([, value]) => Buffer.from(value).equals(canvas)) ? [4, 255] : [0, 255];
      assert.deepEqual([...native_window_policy(windowRequest(1, live, [], name, canvas))], expected);
    }
  }
  const duplicate = [[key("same"), key("first")], [key("same"), key("last")]] as const;
  assert.deepEqual([...native_window_policy(windowRequest(1, duplicate, [], key("same"), key("")))], [1, 0]);
});

test("window retirement follows current slot order including swap-removal", () => {
  const live = Array.from({ length: 4 }, (_, i) => [key(String(i)), key(`canvas-${i}`)] as const);
  for (let mask = 0; mask < 16; mask++) {
    const declared = live.filter((_, i) => mask & (1 << i)).map(([name]) => name);
    const slots = [...live]; const removed: number[] = [];
    for (;;) {
      const expected = slots.findIndex(([name]) => !declared.some(value => Buffer.from(value).equals(name)));
      const decision = native_window_policy(windowRequest(0, slots, declared));
      assert.deepEqual([...decision], [0, expected < 0 ? 255 : expected]);
      if (expected < 0) break;
      removed.push(Number(new TextDecoder().decode(slots[expected]![0])));
      slots[expected] = slots[slots.length - 1]!; slots.pop();
    }
    assert.equal(removed.length, 4 - declared.length);
  }
});

test("window requests refuse malformed counts, labels, operations and trailing bytes", () => {
  for (const valid of [windowRequest(0, [[key("x"), key("canvas")]], [key("x")]), windowRequest(1, [])]) {
    for (let length = 0; length < valid.length; length++) assert.throws(() => native_window_policy(valid.subarray(0, length)), /window/);
    assert.throws(() => native_window_policy(new Uint8Array([...valid, 0])), /trailing/);
  }
  assert.throws(() => native_window_policy(new Uint8Array([255])), /operation/);
  assert.throws(() => native_window_policy(new Uint8Array([0, 5])), /count/);
  assert.throws(() => native_window_policy(new Uint8Array([0, 0, 5])), /count/);
});

test("theme policy parses every byte at every accent position with exact native hex semantics", () => {
  const hex = (b: number): number => b >= 48 && b <= 57 ? b - 48 : b >= 65 && b <= 70 ? b - 55 : b >= 97 && b <= 102 ? b - 87 : -1;
  const base = new Uint8Array([0, ...key("#12aBcF")]);
  for (let position = 1; position < 8; position++) for (let byte = 0; byte < 256; byte++) {
    const input = base.slice(); input[position] = byte;
    const digits = [...input.slice(2)].map(hex);
    const expected = input[1] === 35 && digits.every(n => n >= 0)
      ? [1, digits[0]! * 16 + digits[1]!, digits[2]! * 16 + digits[3]!, digits[4]! * 16 + digits[5]!]
      : [0, 0, 0, 0];
    assert.deepEqual([...native_theme_policy(input)], expected);
  }
  for (const text of ["", "#fff", "#1234567", " #123456", "#123456\n", "#12é45", "#12\0b45"]) {
    assert.deepEqual([...native_theme_policy(new Uint8Array([0, ...key(text)]))], [0, 0, 0, 0]);
  }
  const backing = new Uint8Array(18); backing.set(base, 5);
  assert.deepEqual([...native_theme_policy(backing.subarray(5, 13))], [1, 18, 171, 207]);
});

test("theme policy retains native pack, scheme and high-contrast accent precedence", () => {
  for (let model = 0; model < 3; model++) for (let fallback = 1; fallback < 3; fallback++)
  for (let scheme = 0; scheme < 3; scheme++) for (let os = 0; os < 2; os++)
  for (let contrast = 0; contrast < 2; contrast++) for (let accent = 0; accent < 2; accent++) for (let manifest = 0; manifest < 2; manifest++) {
    assert.deepEqual([...native_theme_policy(new Uint8Array([1, model, fallback, scheme, os, contrast, accent, manifest]))],
      [model || fallback, scheme === 0 ? os : scheme - 1, contrast ? 0 : accent ? 1 : manifest ? 2 : 0, 0]);
  }
});

test("theme policy preserves complete-token precedence and rebuild coordination", () => {
  for (let fn = 0; fn < 2; fn++) for (let fixed = 0; fixed < 2; fixed++) for (let helper = 0; helper < 2; helper++) for (let scheme = 0; scheme < 3; scheme++) {
    const follows = !fn && !fixed && (!helper || scheme === 0);
    assert.deepEqual([...native_theme_policy(new Uint8Array([2, fn, fixed, helper, scheme]))],
      [fn ? 1 : fixed ? 2 : 0, +follows, +(!!fn || !!helper || follows), 0]);
    for (const overrides of [0, 1]) assert.deepEqual([...native_theme_policy(new Uint8Array([2, fn, fixed, helper, scheme, overrides]))],
      [fn ? 1 : fixed ? 2 : 0, +follows, +(!!fn || !!helper || !!overrides || follows), 0]);
  }
  for (const bytes of [[], [3], [1], [2], [1, 3, 1, 0, 0, 0, 0, 0], [1, 0, 0, 0, 0, 0, 0, 0], [1, 0, 1, 0, 2, 0, 0, 0], [2, 2, 0, 0, 0], [2, 0, 0, 0, 3], [2, 0, 0, 0, 0, 2], [2, 0, 0, 0, 0, 0, 0]]) {
    assert.throws(() => native_theme_policy(new Uint8Array(bytes)), /theme policy|theme .*request|theme .*flag/);
  }
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

test("complete timers return explicit admission refusals without hiding malformed wire tables", () => {
  const slots = empty();
  const make = (name: Uint8Array, after: number, blocked = 0) => { const bytes = delayRequest(slots, name, after, 255, blocked); bytes[0] = 6; return bytes; };
  for (const after of [NaN, Infinity, -Infinity, 0, .99, 31536000001]) assert.equal(native_timer_policy(make(key("save"), after))[0], 255);
  for (const after of [1, 1.5, 800, 31536000000]) {
    const out = native_timer_policy(make(key("save"), after));
    assert.deepEqual([out[0], out[1], new DataView(out.buffer).getFloat64(2, true)], [0, 255, Math.round(after)]);
    assert.equal(native_timer_policy(make(key("save"), after, 1))[0], 255);
  }
  slots.forEach((s, i) => { s.used = true; s.key = key(i === 7 ? "save" : "other"); });
  assert.equal(native_timer_policy(make(key("save"), 800))[0], 7);
  assert.equal(native_timer_policy(make(key("other-new"), 800))[0], 255);
  const valid = make(key("save"), 800);
  for (let length = 0; length < valid.length; length++) assert.throws(() => native_timer_policy(valid.subarray(0, length)));
  assert.throws(() => native_timer_policy(new Uint8Array([...valid, 0])), /trailing/);
  assert.throws(() => native_timer_policy(make(key("save"), 800, 2)), /admission/);
});

interface MediaSlot { used: boolean; key: bigint; tag: number; source: number; rate: number; channels: number }
const mediaSlots = (count = 16): MediaSlot[] => Array.from({ length: count }, (_, i) => ({ used: false, key: BigInt(i + 1), tag: 255 - i, source: i % 2, rate: 16000 + i, channels: i % 2 + 1 }));
function mediaRequest(op: number, family: number, slots: MediaSlot[], value: number | bigint, event = 0, tag = 127, source = 0, rate = 48000, channels = 1, expected = 0): Uint8Array {
  const bytes = new Uint8Array(28 + slots.length * 16), wire = new DataView(bytes.buffer);
  bytes.set([op, family, slots.length, event, tag, source, channels]);
  if (typeof value === "bigint") wire.setBigUint64(8, value, true); else wire.setFloat64(8, value, true);
  wire.setUint32(16, rate, true); wire.setFloat64(20, expected, true);
  slots.forEach((slot, i) => { const at = 28 + i * 16; bytes[at] = +slot.used; wire.setBigUint64(at + 1, slot.key, true); bytes[at + 9] = slot.tag; bytes[at + 10] = slot.source; wire.setUint32(at + 11, slot.rate, true); bytes[at + 15] = slot.channels; });
  return bytes;
}
function referenceMedia(op: number, family: number, slots: MediaSlot[], value: number | bigint, event = 0, tag = 127, source = 0, rate = 48000, channels = 1, expected = 0): Uint8Array {
  const result = new Uint8Array(28), wire = new DataView(result.buffer);
  const valid = typeof value === "bigint" || Number.isSafeInteger(value) && value > 0;
  const id = valid ? BigInt(value) : 0n;
  result.set([+valid, 255, tag, 0, source, channels]); wire.setBigUint64(8, id, true); wire.setUint32(24, rate, true);
  wire.setBigUint64(16, Number.isSafeInteger(expected) && expected > 0 ? BigInt(expected) : 0n, true);
  const match = slots.findIndex(slot => slot.used && valid && slot.key === id);
  if (op === 3) {
    const good = family !== 2 || [16000, 24000, 48000].includes(rate) && [1, 2].includes(channels);
    const free = slots.findIndex(slot => !slot.used);
    if (valid && good && match < 0 && free >= 0) result[1] = free;
  } else if (match >= 0) {
    const slot = slots[match]!; result[1] = match; result[2] = slot.tag;
    if (op === 5) {
      result[3] = +(family === 0 || family === 1 && event !== 0 || family === 2 && (event === 3 || event === 4));
      if (family === 2) { result[4] = slot.source; result[5] = channels || slot.channels; wire.setUint32(24, rate || slot.rate, true); }
    }
  } else if (op === 5) throw new Error("missing reference owner");
  return result;
}

test("media admission preserves native key gates, every table hole, duplicates, refusal identity and exact expected sizes", () => {
  const keys = [NaN, -Infinity, Infinity, -1, -0, 0, .5, 1, 2, 1.5, 4294967295, 4294967296, Number.MAX_SAFE_INTEGER, 2 ** 53];
  const sizes = [NaN, Infinity, -1, 0, .5, 1, 1.5, 4294967296, Number.MAX_SAFE_INTEGER, 2 ** 53];
  for (let family = 0; family < 3; family++) for (let hole = -1; hole < (family === 0 ? 16 : 8); hole++) {
    const slots = mediaSlots(family === 0 ? 16 : 8); slots.forEach((slot, i) => { slot.used = i !== hole; slot.key = i % 3 === 0 ? 1n : BigInt(i + 100); });
    for (const value of keys) for (const expected of sizes) for (const [rate, channels] of [[0, 0], [16000, 1], [24000, 2], [48000, 2], [44100, 1], [48000, 3]]) {
      const input = mediaRequest(3, family, slots, value, 0, 253, 1, rate!, channels!, expected);
      assert.deepEqual(native_effect_policy(input), referenceMedia(3, family, slots, value, 0, 253, 1, rate!, channels!, expected));
    }
  }
});

test("media controls and terminal routes retain opaque u64 identities, first-match tags and capture envelope restoration", () => {
  const identities = [0n, 1n, 4294967296n, 9007199254740993n, (1n << 64n) - 1n];
  for (let family = 0; family < 3; family++) for (let slot = 0; slot < (family === 0 ? 16 : 8); slot++) for (const id of identities) {
    const slots = mediaSlots(family === 0 ? 16 : 8); slots[slot] = { used: true, key: id, tag: slot * 16, source: 1, rate: 24000, channels: 2 };
    if (slot + 1 < slots.length) slots[slot + 1] = { ...slots[slot]!, tag: 255 };
    assert.deepEqual(native_effect_policy(mediaRequest(7, family, slots, id)), referenceMedia(7, family, slots, id));
    for (let event = 0; event <= (family === 0 ? 0 : family === 1 ? 2 : 4); event++) for (const [rate, channels] of [[0, 0], [16000, 1], [4294967295, 255]]) {
      assert.deepEqual(native_effect_policy(mediaRequest(5, family, slots, id, event, 127, 0, rate!, channels!)), referenceMedia(5, family, slots, id, event, 127, 0, rate!, channels!));
    }
    for (const value of [Number(id), NaN, Infinity, 0, 1.5, Number.MAX_SAFE_INTEGER]) assert.deepEqual(native_effect_policy(mediaRequest(4, family, slots, value)), referenceMedia(4, family, slots, value));
  }
  for (const id of [1, NaN, Number.MAX_SAFE_INTEGER, 2 ** 53]) assert.deepEqual(native_effect_policy(mediaRequest(4, 0, [], id)), referenceMedia(4, 0, [], id));
});

function transportRequest(video: boolean, used: boolean, owner: number, verb: number, scalar: number, requested: Uint8Array, stored: Uint8Array): Uint8Array {
  const out = new Uint8Array(15 + requested.length + stored.length); out.set([6, +video, +used, owner, verb, requested.length, stored.length]);
  new DataView(out.buffer).setFloat64(7, scalar, true); out.set(requested, 15); out.set(stored, 15 + requested.length); return out;
}
test("playback controls preserve stale keys, foreign ownership, idle volume, token cancellation, re-key and seek saturation", () => {
  const keys = [key(""), key("clip"), new Uint8Array([0, 255]), new Uint8Array(64).fill(255)];
  const values = [NaN, -Infinity, Infinity, -1, -0, 0, .5, 1.5, Number.MAX_SAFE_INTEGER, 2 ** 53, 2 ** 53 + 2, Number.MAX_VALUE];
  for (const video of [false, true]) for (const used of [false, true]) for (let owner = 0; owner < 3; owner++) for (let verb = 0; verb < (video ? 8 : 5); verb++) for (const value of values) for (const a of keys) for (const b of keys) {
    const request = transportRequest(video, used, owner, verb, value, a, b), expected = new Uint8Array(12); expected[0] = 255;
    if (used && Buffer.from(a).equals(b) && (!video || verb === 2 || owner === 1 || verb === 4 && owner === 2)) {
      expected.set([verb, +(verb === 2), +(video && verb === 7)]); expected.set(request.subarray(7, 15), 4);
      const scalar = verb === 3 ? value >= 0 && value <= 2 ** 53 ? Math.floor(value) : video && Number.isFinite(value) && value > 2 ** 53 ? Number.MAX_SAFE_INTEGER : 0 : video && [5, 6].includes(verb) ? +(value !== 0) : null;
      if (scalar !== null) new DataView(expected.buffer).setFloat64(4, scalar === 0 ? 0 : scalar, true);
    }
    assert.deepEqual(native_effect_policy(request), expected);
  }
});

test("media policy rejects damaged packets before a plan and keeps input and output ownership independent", () => {
  const slots = mediaSlots(8); slots[0]!.used = true;
  const requests = [mediaRequest(3, 0, slots, 99), mediaRequest(4, 1, slots, 1), mediaRequest(5, 2, slots, 1n, 3), mediaRequest(7, 0, slots, 1n), transportRequest(true, true, 1, 7, 0, key("clip"), key("clip"))];
  for (const input of requests) {
    for (let end = 0; end < input.length; end++) assert.throws(() => native_effect_policy(input.subarray(0, end)));
    assert.throws(() => native_effect_policy(new Uint8Array([...input, 0])));
    const offset = new Uint8Array(input.length + 11); offset.set(input, 7);
    const before = input.slice(), output = native_effect_policy(offset.subarray(7, 7 + input.length)), saved = output.slice();
    assert.deepEqual(input, before); offset.fill(0); native_effect_policy(requests[0]!); assert.deepEqual(output, saved);
  }
  for (const [at, value] of [[0, 8], [1, 3], [2, 17], [5, 2], [7, 1], [28, 2], [38, 2]]) {
    const broken = requests[0]!.slice(); broken[at!] = value!; assert.throws(() => native_effect_policy(broken));
  }
  assert.throws(() => native_effect_policy(mediaRequest(5, 1, slots, 99n)));
  assert.throws(() => native_effect_policy(mediaRequest(5, 2, slots, 1n, 5)));
  assert.throws(() => native_effect_policy(transportRequest(false, true, 1, 5, 0, key("same"), key("same"))));
  assert.equal(native_effect_policy(transportRequest(true, true, 0, 255, 0, key("same"), key("same")))[0], 255);
});

test("numeric media owners enforce the native family capacities", () => {
  for (const family of [1, 2]) assert.throws(() => native_effect_policy(mediaRequest(3, family, mediaSlots(9), 99)));
});

function playbackLoadRequest(video: boolean, value: number, pathLength: number, url: Uint8Array, tag = 255, flags = 255): Uint8Array {
  const bytes = new Uint8Array(24 + Math.min(url.length, 1024)), data = new DataView(bytes.buffer);
  bytes[0] = 8; bytes[1] = +video; bytes[2] = tag; bytes[3] = flags;
  data.setFloat64(8, value, true); data.setUint32(16, pathLength, true); data.setUint32(20, url.length, true);
  bytes.set(url.subarray(0, 1024), 24); return bytes;
}

test("playback preparation preserves distinct audio and video numeric contracts and owns all result words", () => {
  for (const value of [NaN, -Infinity, Infinity, -1, -0, 0, 0.5, 1, 1.75, 65535, 4294967295.75, 4294967296, 9007199254740991, 9007199254740992, 9007199254740994]) {
    for (const video of [false, true]) {
      const req = playbackLoadRequest(video, value, 1, key(""));
      const copy = req.slice(), result = native_effect_policy(req), data = new DataView(result.buffer);
      assert.deepEqual(req, copy);
      const valid = video ? value >= 1 && value < 2 ** 53 && Math.floor(value) === value : true;
      const size = !video && value >= 1 && value <= 2 ** 53 ? Math.trunc(value) : 0;
      assert.equal(result[0], +valid); assert.equal(result[1], 255); assert.equal(result[2], 7);
      assert.equal(data.getBigUint64(8, true), BigInt(video && valid ? value : 0));
      assert.equal(data.getBigUint64(16, true), BigInt(size));
      req.fill(0); native_effect_policy(playbackLoadRequest(false, 0, 0, key("")));
      assert.equal(data.getBigUint64(16, true), BigInt(size));
    }
  }
});

test("video URI admission preserves byte grammar path limits permissive authority and decimal port syntax", () => {
  const accepted = ["http:", "HTTPS:opaque", "http://host", "http:///", "http://user@", "http://@", "http://h:+65535", "http://h:-00", "http://h:1__2", "http://[anything]junk", "http://[x]:+0", "http://h/\0\ufffd?#", "http://h?bad port"];
  const rejected = ["", "ftp://host", "http", " http:", "http://", "http://?", "http://#", "http://]x", "http://[x", "http://h:", "http://h:-1", "http://h:65536", "http://h:_1", "http://h:1_", "http://h: 1", "http://:1"];
  for (const url of accepted) assert.equal(native_effect_policy(playbackLoadRequest(true, 1, 0, key(url)))[0], 1, url);
  for (const url of rejected) assert.equal(native_effect_policy(playbackLoadRequest(true, 1, 0, key(url)))[0], 0, url);
  assert.equal(native_effect_policy(playbackLoadRequest(true, 1, 1024, key("")))[0], 1);
  assert.equal(native_effect_policy(playbackLoadRequest(true, 1, 1025, key("")))[0], 0);
  const url = new Uint8Array(1025).fill(255); url.set(key("http:/"));
  assert.equal(native_effect_policy(playbackLoadRequest(true, 1, 1, url.subarray(0, 1024)))[0], 1);
  assert.equal(native_effect_policy(playbackLoadRequest(true, 1, 1, url))[0], 0);
});

interface PtySlot { used: boolean; bound: boolean; key: Uint8Array; tag: number }
function ptyRequest(slots: PtySlot[], action: number, name: Uint8Array, cols = 80, rows = 24, blocked = 0, event = 0, engine = 0x5453505400000000n): Uint8Array {
  const bytes = new Uint8Array(32 + name.length + slots.reduce((n, slot) => n + 4 + slot.key.length, 0)), wire = new DataView(bytes.buffer);
  bytes.set([9, action, 4, blocked, event, 231, name.length, 0]); wire.setBigUint64(8, engine, true);
  wire.setFloat64(16, cols, true); wire.setFloat64(24, rows, true); bytes.set(name, 32);
  let at = 32 + name.length;
  for (const slot of slots) { bytes.set([+slot.used, +slot.bound, slot.tag, slot.key.length], at); bytes.set(slot.key, at + 4); at += 4 + slot.key.length; }
  return bytes;
}

test("PTY plans preserve all live and bound states first-match ordering opaque names and ended identities", () => {
  const names = [key(""), key("sh"), new Uint8Array([115, 104, 0, 255]), new Uint8Array(255).fill(255)];
  for (let state = 0; state < 256; state++) {
    const slots = names.map((name, i) => ({ used: !!(state & (1 << (i * 2))), bound: !!(state & (2 << (i * 2))), key: name, tag: i * 63 }));
    for (const name of [...names, key("missing")]) for (const blocked of [0, 1]) for (const action of [0, 1, 2, 3]) {
      const equal = (s: PtySlot) => Buffer.from(s.key).equals(name);
      const live = name.length === 0 ? -1 : slots.findIndex(s => s.used && equal(s));
      const retained = slots.findIndex(s => s.bound && !s.used && equal(s));
      const free = slots.findIndex(s => !s.used && !s.bound);
      const binding = name.length === 0 ? -1 : slots.findIndex(s => (s.used || s.bound) && equal(s));
      const expected = action === 0 ? name.length > 0 && (live >= 0 || blocked) ? -1 : retained >= 0 ? retained : free : action === 3 ? binding : live;
      const req = ptyRequest(slots, action, name, 65535, 1, blocked), copy = req.slice(), result = native_effect_policy(req), wire = new DataView(result.buffer);
      assert.deepEqual(req, copy); assert.equal(result[0], expected < 0 ? 255 : expected);
      assert.equal(result[1], expected < 0 || action === 0 ? 231 : slots[expected]!.tag);
      assert.equal(result[2], 0); assert.equal(result[3], +(action === 3 && expected >= 0));
      assert.equal(wire.getBigUint64(8, true), expected < 0 ? 0n : 0x5453505400000000n + BigInt(expected));
    }
    for (let i = 0; i < 4; i++) for (const kind of [0, 1]) {
      const req = ptyRequest(slots, 4, key(""), 0, 0, 0, kind, 0x5453505400000000n + BigInt(i));
      if (!slots[i]!.used) assert.throws(() => native_effect_policy(req), /owner/);
      else { const result = native_effect_policy(req); assert.deepEqual([...result.subarray(0, 4)], [i, slots[i]!.tag, kind, 0]); req.fill(0); assert.equal(result[1], slots[i]!.tag); }
    }
  }
});

test("PTY resize rejects inexact grids and malformed protocols fail before publishing owned plans", () => {
  const slots = Array.from({ length: 4 }, (_, i) => ({ used: i === 0, bound: false, key: key("sh"), tag: 255 }));
  const invalid = [NaN, Infinity, -Infinity, -0, 0, 0.99, 1.5, 65535.5, 65536];
  for (const value of invalid) for (const cols of [true, false]) {
    const result = native_effect_policy(ptyRequest(slots, 2, key("sh"), cols ? value : 80, cols ? 24 : value));
    assert.equal(result[0], 255);
  }
  const packets = [ptyRequest(slots, 0, key("sh")), playbackLoadRequest(true, 1, 1, key("http://h")), Uint8Array.from([10, 1, 0, 0, 255, 0, 0, 0, 0, 0, 0, 0])];
  for (const packet of packets) {
    for (let i = 0; i < packet.length; i++) assert.throws(() => native_effect_policy(packet.subarray(0, i)));
    assert.throws(() => native_effect_policy(Uint8Array.from([...packet, 0])));
  }
  for (const engine of [0n, 0x54535053ffffffffn, 0x5453505400000004n, 0xffffffffffffffffn]) assert.throws(() => native_effect_policy(ptyRequest(slots, 4, key(""), 0, 0, 0, 0, engine)), /owner/);
  assert.deepEqual([...native_effect_policy(packets[2]!)], [255]);
  const audio = packets[2]!.slice(); audio[1] = 0; assert.throws(() => native_effect_policy(audio), /owner/); audio[2] = 1; audio[3] = 254;
  assert.deepEqual([...native_effect_policy(audio)], [254]);
});

function routedRequestPacket(action = 0, pool = 0, name = new Uint8Array(0), occupied = 0, stored = new Uint8Array(0)): Uint8Array {
  const bytes = new Uint8Array(16 + name.length + 36 * (15 + stored.length));
  bytes.set([11, action, pool, name.length, 0, 0, 7, 8], 0); bytes.set(name, 16);
  let at = 16 + name.length;
  for (let i = 0; i < 36; i++) {
    bytes[at] = +(i < occupied); bytes[at + 1] = stored.length; bytes.set(stored, at + 2);
    const route = at + 2 + stored.length;
    bytes[route] = i; bytes[route + 1] = 255 - i;
    new DataView(bytes.buffer).setBigUint64(route + 5, 0xfedcba9876543210n, true);
    at = route + 13;
  }
  return bytes;
}

test("request coordination preserves cross-pool retirement capacity duplicate priority and anonymous lookup", () => {
  const bytes = routedRequestPacket(0, 2, key("same"), 36, key("else"));
  bytes[16 + 4 + 2] = 115; bytes.set(key("same"), 16 + 4 + 2);
  assert.deepEqual([...native_effect_policy(bytes)], [255, 0, 7, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
  bytes[5] = 1; assert.equal(native_effect_policy(bytes)[1], 255);
  bytes[1] = 3; bytes[11] = 1; assert.equal(native_effect_policy(bytes)[3], 1);
  bytes[3] = 4; bytes.set(key("new!"), 16); assert.equal(native_effect_policy(bytes)[3], 2);
  const anonymous = routedRequestPacket(1, 0, key(""), 1, key(""));
  assert.equal(native_effect_policy(anonymous)[0], 0);
  anonymous[1] = 0; assert.equal(native_effect_policy(anonymous)[0], 1);
  for (let size = 0; size < anonymous.length; size++) assert.throws(() => native_effect_policy(anonymous.subarray(0, size)));
  assert.throws(() => native_effect_policy(new Uint8Array([...anonymous, 0])));
});

test("request completion copies exact channel words and every payload route before packet reuse", () => {
  const bytes = routedRequestPacket(2, 0, key(""), 36, key("route")); bytes[10] = 35;
  const route = 16 + 35 * 20 + 2 + 5;
  for (const ok of [0, 1]) for (const voidResult of [0, 1]) for (const typed of [0, 1]) for (const channel of [0, 1]) {
    bytes[9] = ok; bytes[route + 2] = voidResult; bytes[route + 3] = typed; bytes[route + 4] = channel;
    const plan = native_effect_policy(bytes), copy = plan.slice();
    assert.equal(plan[2], ok ? 35 : 220); assert.equal(plan[3], ok && typed ? 2 : ok && voidResult ? 1 : 0);
    assert.equal(plan[4], 1); assert.equal(plan[5], channel);
    assert.equal(new DataView(plan.buffer).getBigUint64(8, true), channel ? 0xfedcba9876543210n : 0n);
    native_effect_policy(bytes); assert.deepEqual(plan, copy);
  }
});

test("credential policy rejects arbitrary malformed lengths and exposes offsets without secret bytes", () => {
  const name = key("core.credentials.set"), fields = Uint8Array.from([3, 0, 0, 0, 0, 255, 107, 2, 0, 0, 0, 115, 0]);
  const bytes = new Uint8Array(2 + name.length + fields.length); bytes.set([13, name.length]); bytes.set(name, 2); bytes.set(fields, 2 + name.length);
  const plan = native_effect_policy(bytes), data = new DataView(plan.buffer);
  assert.deepEqual([plan[0], plan[1], data.getUint32(4, true), data.getUint32(8, true), data.getUint32(12, true), data.getUint32(16, true)], [1, 0, 4, 3, 11, 2]);
  for (let size = 2 + name.length; size < bytes.length; size++) assert.deepEqual(native_effect_policy(bytes.subarray(0, size)), new Uint8Array(20));
  assert.deepEqual(native_effect_policy(new Uint8Array([...bytes, 0])), new Uint8Array(20));
  const bad = bytes.slice(); new DataView(bad.buffer).setUint32(2 + name.length, 0xffffffff, true);
  assert.deepEqual(native_effect_policy(bad), new Uint8Array(20));
});

interface FileOwner { used: boolean; sink: boolean; busy: boolean; cancelling: boolean; key: Uint8Array; chunk: number; done: number; err: number }
function filePacket(slots: FileOwner[], action: number, name: Uint8Array, blocked = 0, owner = 0, op = 4, event = 0, outcome = 0): Uint8Array {
  const bytes = new Uint8Array(12 + name.length + slots.reduce((n, s) => n + 8 + s.key.length, 0));
  bytes.set([15, action, name.length, blocked, owner, op, event, outcome, 41, 42, 43, 0]); bytes.set(name, 12);
  let at = 12 + name.length;
  for (const s of slots) { bytes.set([+s.used, +s.sink, +s.busy, +s.cancelling, s.chunk, s.done, s.err, s.key.length], at); bytes.set(s.key, at + 8); at += 8 + s.key.length; }
  return bytes;
}
function fileReference(slots: FileOwner[], action: number, name: Uint8Array, blocked = 0, owner = 0, op = 4, event = 0, outcome = 0): Uint8Array {
  const result = new Uint8Array(8); result[0] = 255;
  const matching = slots.findIndex(s => s.used && Buffer.from(s.key).equals(name)), free = slots.findIndex(s => !s.used);
  if (action === 0) { result[0] = matching < 0 ? 255 : matching; return result; }
  result[2] = 43;
  if (action === 1 || action === 2) {
    if (blocked || action === 2 && (name.length === 0 || matching >= 0)) { result[1] = 1; return result; }
    let slot = free;
    if (action === 1 && name.length > 0 && matching >= 0) {
      if (slots[matching]!.sink) { result[1] = 1; return result; }
      slot = matching;
    }
    if (slot < 0) result[1] = 1;
    else { result[0] = slot; result[2] = 42; }
    return result;
  }
  if (action === 3 || action === 4) {
    if (matching < 0 || !slots[matching]!.sink || slots[matching]!.cancelling) result[1] = 2;
    else if (slots[matching]!.busy) result[1] = 3;
    else { result[0] = matching; result[2] = 42; }
    return result;
  }
  const s = slots[owner]!; result[0] = owner; result[2] = s.err; result[3] = 3;
  if (s.cancelling && outcome === 5) result[4] = 1;
  else if (op === 4 && event === 1 && outcome === 0) { result[2] = s.chunk; result[3] = 1; }
  else if (op === 4 && event === 2 && outcome === 0) { result[2] = s.done; result[3] = 2; result[4] = 1; }
  else if (outcome === 0) { result[2] = s.done; result[3] = 0; result[4] = +(op === 7); result[5] = 1; }
  else if (op === 6 && (outcome === 4 || outcome === 7)) result[5] = 1;
  else result[4] = 1;
  return result;
}

test("file lifecycle preserves complete plans anonymous lookup replacement ordering and every terminal", () => {
  const names = [key(""), key("read"), new Uint8Array([0, 255]), new Uint8Array(255).fill(255)];
  for (const name of names) for (const stored of names) for (let mask = 0; mask < 16; mask++) for (let flags = 0; flags < 8; flags++) {
    const slots = Array.from({ length: 4 }, (_, i) => ({ used: !!(mask & (1 << i)), sink: !!(flags & 1), busy: !!(flags & 2), cancelling: !!(flags & 4), key: stored, chunk: i * 63, done: 255 - i, err: i + 4 }));
    for (let action = 0; action < 5; action++) for (const blocked of [0, 1]) assert.deepEqual(native_effect_policy(filePacket(slots, action, name, blocked)), fileReference(slots, action, name, blocked));
  }
  const slots = names.map((name, i) => ({ used: true, sink: false, busy: true, cancelling: false, key: name, chunk: i * 63, done: 255 - i, err: i + 4 }));
  for (const cancelling of [false, true]) for (let owner = 0; owner < 4; owner++) for (let op = 0; op < 9; op++) for (let event = 0; event < 3; event++) for (let outcome = 0; outcome < 9; outcome++) {
    slots[owner]!.cancelling = cancelling;
    assert.deepEqual(native_effect_policy(filePacket(slots, 5, key(""), 0, owner, op, event, outcome)), fileReference(slots, 5, key(""), 0, owner, op, event, outcome));
  }
});

function clipboardPacket(action: number, name: Uint8Array, used: number, stored: Uint8Array, blocked = 0, owner = 0): Uint8Array {
  const bytes = new Uint8Array(8 + name.length + 16 * (3 + stored.length));
  bytes.set([16, action, name.length, blocked, owner, 255, 0, 0]); bytes.set(name, 8);
  let at = 8 + name.length;
  for (let i = 0; i < 16; i++) { bytes.set([+(i < used), i * 16, stored.length], at); bytes.set(stored, at + 3); at += 3 + stored.length; }
  return bytes;
}

test("clipboard plans preserve full capacity complete routing empty names and first-match priority", () => {
  const names = [key(""), key("copy"), new Uint8Array([0, 255]), new Uint8Array(255).fill(255)];
  for (const name of names) for (const stored of names) for (let used = 0; used <= 16; used++) for (const blocked of [0, 1]) {
    const matching = name.length > 0 && used > 0 && Buffer.from(name).equals(stored);
    assert.deepEqual(native_effect_policy(clipboardPacket(0, name, used, stored, blocked)), Uint8Array.from([matching ? 0 : 255, 255, 0, 0]));
    assert.deepEqual(native_effect_policy(clipboardPacket(1, name, used, stored, blocked)), Uint8Array.from([blocked || matching || used === 16 ? 255 : used, 255, 0, 0]));
    for (let owner = 0; owner < used; owner++) assert.deepEqual(native_effect_policy(clipboardPacket(2, name, used, stored, blocked, owner)), Uint8Array.from([owner, owner * 16, 1, 0]));
  }
});

test("file and clipboard packets reject malformed ownership and produce independent copied plans", () => {
  const slots = Array.from({ length: 4 }, () => ({ used: true, sink: true, busy: false, cancelling: false, key: key("r"), chunk: 0, done: 254, err: 255 }));
  const packets = [filePacket(slots, 5, key("r")), clipboardPacket(2, key("r"), 16, key("r"))];
  for (const packet of packets) {
    for (let i = 0; i < packet.length; i++) assert.throws(() => native_effect_policy(packet.subarray(0, i)));
    assert.throws(() => native_effect_policy(new Uint8Array([...packet, 0])));
    const backing = new Uint8Array(packet.length + 9); backing.set(packet, 5);
    const before = backing.slice(), output = native_effect_policy(backing.subarray(5, 5 + packet.length)), frozen = output.slice();
    assert.deepEqual(backing, before); backing.fill(0); native_effect_policy(packet); assert.deepEqual(output, frozen);
  }
  for (const [at, value] of [[1, 6], [3, 2], [4, 4], [5, 9], [6, 3], [7, 9], [11, 1], [13, 2], [14, 2], [15, 2], [16, 2]]) {
    const bad = packets[0]!.slice(); bad[at!] = value!; assert.throws(() => native_effect_policy(bad));
  }
  for (const [at, value] of [[1, 3], [3, 2], [4, 16], [6, 1], [7, 1], [9, 2]]) {
    const bad = packets[1]!.slice(); bad[at!] = value!; assert.throws(() => native_effect_policy(bad));
  }
  const file = packets[0]!.slice(); file[13] = 0; assert.throws(() => native_effect_policy(file));
  const clipboard = packets[1]!.slice(); clipboard[9] = 0; assert.throws(() => native_effect_policy(clipboard));
});

const bufferedBase = 0x5453465800000000n;
function bufferedCompletion(family: number, operation: number, outcome: number, truncated: number, slot: number, dropped = 0): Uint8Array {
  const r = new Uint8Array(88), w = new DataView(r.buffer);
  r.set([17, family, operation, outcome, truncated]);
  w.setBigUint64(8, bufferedBase + BigInt(slot), true); w.setBigUint64(16, bufferedBase, true);
  for (let i = 0; i < 16; i++) r.set([1, i === slot ? dropped : 0, i * 17, 255 - i * 17], 24 + i * 4);
  return r;
}
function timerCompletion(family: number, slot: number, full: number, mode: number, outcome: number, timestamp: bigint): Uint8Array {
  const r = new Uint8Array(96), w = new DataView(r.buffer), base = family === 1 ? 0x5453544900000000n : 0x5453444c00000000n;
  r.set([7, family, outcome]); w.setBigUint64(4, base + BigInt(slot), true);
  w.setBigUint64(12, timestamp, true); w.setBigUint64(20, base, true);
  for (let i = 0; i < 16; i++) r.set([1, full, mode, i * 17], 32 + i * 4);
  return r;
}

test("buffered callback plans own every complete file fetch clipboard route and retirement", () => {
  for (let family = 0; family < 4; family++) for (let operation = 0; operation < (family < 2 ? 9 : 1); operation++) {
    for (let outcome = 0; outcome < (family < 2 ? 9 : family === 2 ? 7 : 4); outcome++) {
      for (let slot = 0; slot < 16; slot++) for (const dropped of [0, 1]) for (const truncated of [0, 1]) {
        const r = bufferedCompletion(family, operation, outcome, truncated, slot, dropped), frozen = r.slice();
        const cut = family === 2 && truncated === 1, success = family === 1 || outcome === 0 && !cut;
        const payload = family === 1 ? 6 : dropped ? 0 : !success ? 5 : family === 2 ? 4 : family === 3 || operation === 0 ? 2 : operation === 3 ? 3 : 1;
        const tag = dropped || !success ? 255 - slot * 17 : slot * 17;
        const reason = family === 1 || dropped || success ? 0 : outcome === 0 && cut ? 2 : 1;
        assert.deepEqual([...native_effect_policy(r)], [slot, tag, payload, reason, 1, dropped, 0, 0]);
        assert.deepEqual(r, frozen);
      }
    }
  }
});

test("timer callback plans preserve every timestamp word exact decimal and completion lifecycle", () => {
  const timestamps = [0n, 1n, 999999n, 1000001n, 4294967295n, 4294967296n, 9007199254740991n, 9007199254740992n, 9007199254740993n, 18446744073709549567n, 18446744073709551615n];
  for (const timestamp of timestamps) for (let family = 0; family < 2; family++) for (let slot = 0; slot < 16; slot++) {
    for (const full of [0, 1]) for (const mode of [0, 1]) for (const outcome of [0, 1]) {
      const r = timerCompletion(family, slot, full, mode, outcome, timestamp);
      if (outcome === 1 && (family === 1 || full === 0)) { assert.throws(() => native_timer_policy(r), /rejected/); continue; }
      // Queued subscription callbacks historically route after retirement.
      if (family === 1) r[32 + slot * 4] = 0;
      const expected = new Uint8Array(40), w = new DataView(expected.buffer);
      expected.set([slot, slot * 17, family === 0 ? full : 0, family === 0 && (full === 0 || mode === 0 || outcome === 1) ? 1 : 0, timestamp.toString().length]);
      w.setFloat64(8, Number(timestamp) / 1000000, true); expected.set(key(timestamp.toString()), 16);
      const frozen = r.slice(); assert.deepEqual(native_timer_policy(r), expected); assert.deepEqual(r, frozen);
    }
  }
});

test("callback plans reject malformed frames and exact adjacent namespaces without aliasing", () => {
  const buffered = bufferedCompletion(0, 0, 0, 0, 0), timer = timerCompletion(0, 0, 1, 1, 0, 1n);
  for (const [r, policy, keyAt, baseAt] of [[buffered, native_effect_policy, 8, 16], [timer, native_timer_policy, 4, 20]] as const) {
    for (let length = 0; length < r.length; length++) assert.throws(() => policy(r.subarray(0, length)));
    assert.throws(() => policy(new Uint8Array([...r, 0])));
    const w = new DataView(r.buffer), base = w.getBigUint64(baseAt, true);
    for (const value of [0n, base - 1n, base + 16n, base + 0x100000000n, 0xffffffffffffffffn]) {
      w.setBigUint64(keyAt, value, true); assert.throws(() => policy(r), /namespace|table/);
    }
    w.setBigUint64(keyAt, base, true);
    const envelope = new Uint8Array(r.length + 10); envelope.set(r, 5);
    assert.deepEqual(policy(envelope.subarray(5, 5 + r.length)), policy(r));
  }
  for (const at of [1, 2, 3, 4, 5, 6, 7, 24, 25]) {
    const r = buffered.slice(); r[at] = 255; assert.throws(() => native_effect_policy(r));
  }
  for (const at of [1, 2, 3, 28, 29, 30, 31, 32, 33, 34]) {
    const r = timer.slice(); r[at] = 255; assert.throws(() => native_timer_policy(r));
  }
  buffered[24] = 0; assert.throws(() => native_effect_policy(buffered), /tracked/);
  timer[32] = 0; assert.throws(() => native_timer_policy(timer), /armed/);
});

const dispatch = (stage: number, a = 0, b = 0) => native_effect_policy(new Uint8Array([19, stage, a, b, 0, 0]));
test("dispatch plans preserve causal admission, complete batch order and error precedence", () => {
  const check = (stage: number, a: number, b: number, actions: number[]) =>
    assert.deepEqual([...dispatch(stage, a, b)], [...actions, ...Array(16 - actions.length).fill(0)]);
  check(0, 0, 0, [1, 2, 3, 4]);
  for (let a = 0; a <= 1; a++) {
    check(1, a, 0, [a ? 5 : 6, 7]);
    check(2, a, 0, a ? [8] : []);
    check(3, a, 0, a ? [9] : []);
    check(4, a, 0, a ? [1, 2, 10, 4] : []);
    check(6, a, 0, a ? [8] : []);
    check(7, a, 0, a ? [] : [12]);
    for (let b = 0; b <= 1; b++) {
      check(5, a, b, a ? [8] : b ? [11] : []);
      check(8, a, b, a && !b ? [13] : []);
      check(10, a, b, !a && b ? [14] : []);
    }
  }
  for (let kind = 0; kind <= 2; kind++) for (let standalone = 0; standalone <= 1; standalone++)
    check(9, kind, standalone, kind === 0 || kind === 2 && standalone ? [13] : []);
});
test("dispatch rejects malformed packets and preserves input, output and independent calls", () => {
  const request = new Uint8Array([19, 0, 0, 0, 0, 0]);
  const frozen = request.slice(), first = native_effect_policy(request);
  request[1] = 1; request[2] = 1;
  const second = native_effect_policy(request);
  assert.deepEqual([...first], [1, 2, 3, 4, ...Array(12).fill(0)]);
  second.fill(99);
  assert.deepEqual(native_effect_policy(frozen), first);
  assert.deepEqual([...frozen], [19, 0, 0, 0, 0, 0]);
  for (let length = 0; length < 6; length++) assert.throws(() => native_effect_policy(frozen.subarray(0, length)));
  assert.throws(() => native_effect_policy(new Uint8Array([...frozen, 0])));
  for (const [at, value] of [[1, 11], [2, 2], [3, 1], [4, 1], [5, 1]]) {
    const bad = frozen.slice(); bad[at!] = value!;
    assert.throws(() => native_effect_policy(bad));
  }
  assert.throws(() => dispatch(9, 3, 0));
  assert.throws(() => dispatch(8, 0, 2));
});

function replayRequest(kind: number): Uint8Array {
  const bytes = new Uint8Array(256); bytes.set([20, kind]); bytes[245] = 1; bytes[246] = 1; bytes[248] = 8;
  const view = new DataView(bytes.buffer);
  for (const [field, value] of [[19,262144],[20,4096],[21,8192],[22,8388608],[23,65536],[24,16777216],[25,262144],[26,2560]]) view.setUint32(24 + field! * 8, value!, true);
  return bytes;
}
test("replay admission refuses every truncated packet and invalid flags", () => {
  const bytes = replayRequest(1);
  for (let n = 0; n < bytes.length; n++) assert.throws(() => native_effect_policy(bytes.subarray(0,n)));
  for (let at = 240; at < 247; at++) { bytes[at] = 2; assert.throws(() => native_effect_policy(bytes)); bytes[at] = at >= 245 ? 1 : 0; }
  for (let at = 247; at < 256; at++) if (at !== 248) { bytes[at] = 1; assert.throws(() => native_effect_policy(bytes)); bytes[at] = 0; }
});
test("replay decisions retain external truth and reject hostile scalar words", () => {
  for (let kind = 1; kind <= 18; kind++) {
    const request = replayRequest(kind), frozen = request.slice();
    const result = native_effect_policy(request); assert.equal(result.length,8); assert.deepEqual(request,frozen);
    assert.equal(result[2],kind === 6 ? 1 : 0);
  }
  const bytes = replayRequest(13), view = new DataView(bytes.buffer); bytes[8] = 4;
  assert.equal(native_effect_policy(bytes)[2],1);
  view.setUint32(24 + 7 * 8 + 4,2097152,true);
  assert.equal(new DataView(native_effect_policy(bytes).buffer).getUint16(0,true) & 32,32);
  view.setUint32(24 + 11 * 8 + 4,1,true);
  assert.equal(new DataView(native_effect_policy(bytes).buffer).getUint16(0,true) & 128,128);
  const file = replayRequest(4); file[5] = 4;
  assert.equal(native_effect_policy(file)[2],0);file[240] = 1;assert.equal(native_effect_policy(file)[2],1);
});

test("replay sequencing preserves refusal precedence and one-drain back-pressure", () => {
  const plan = (stage: number,a: number,b=0,c=0) => native_effect_policy(new Uint8Array([21,stage,a,b,c,0,0,0]))[0];
  assert.equal(plan(0,0,1,0),1);assert.equal(plan(0,1,1,0),2);assert.equal(plan(0,1,0,0),0);
  assert.equal(plan(1,1),3);assert.equal(plan(1,0,1),3);assert.equal(plan(1,0),0);
  assert.equal(plan(2,0),4);assert.equal(plan(2,1),0);
  assert.equal(plan(4,0),7);assert.equal(plan(4,0,1),6);assert.equal(plan(4,1),8);assert.equal(plan(4,2),9);
  assert.equal(plan(5,0),0);assert.equal(plan(5,1),10);assert.equal(plan(6,1),5);
  assert.throws(() => plan(0,2)); assert.throws(() => plan(7,0));
});

function componentPacket(stage: number, a = false, b = false, c = false, x = 0n, y = 0n): Uint8Array {
  const bytes = new Uint8Array(32); bytes.set([22, stage, +a, +b, +c]);
  const view = new DataView(bytes.buffer); view.setBigUint64(8, x, true); view.setBigUint64(16, y, true); return bytes;
}
test("component menu plans preserve exact counts, pinned arenas, recovery and source precedence", () => {
  const words = [0n, 1n, 0xffffffffn, 0x100000000n, 9007199254740993n, 0xffffffffffffffffn];
  for (const x of words) for (const y of words) {
    const result = native_effect_policy(componentPacket(0, false, false, false, x, y));
    assert.equal(new DataView(result.buffer).getBigUint64(8, true), x < y ? x : y);
    assert.deepEqual([...result.subarray(0, 8)], Array(8).fill(0));
  }
  for (let bits = 0; bits < 8; bits++) {
    const a = (bits & 1) !== 0, b = (bits & 2) !== 0, c = (bits & 4) !== 0;
    const expected = [0, a ? 1 : b ? 2 : 0, +(a && b && c), +(a && b && c), +(a && b), +(a && (b || c)), +a | (+(b && c) << 1), a && b ? 1 : 2, +a, +(a && b), +(a && b && c), +(a && b && c), a ? 1 : 2, +(a && !b), +a, +(!a && b && c)];
    for (let stage = 1; stage < 16; stage++) assert.deepEqual([...native_effect_policy(componentPacket(stage, a, b, c, 1n))], [expected[stage], ...Array(15).fill(0)]);
  }
});
function reachPacket(start: boolean, present: boolean, values: number[], vFired = false, hFired = false): Uint8Array {
  const bytes = new Uint8Array(32); bytes.set([23, +start, +present, +vFired, +hFired]);
  const view = new DataView(bytes.buffer); for (let i = 0; i < 6; i++) view.setFloat32(8 + i * 4, values[i]!, true); return bytes;
}
test("scroll reach plans retain vertical priority, horizontal fallback and exact f32 bands", () => {
  for (const start of [false, true]) {
    const axis = (distance: number): number[] => [start ? distance : Math.fround(400 - 100 - distance), 100, 400, 0, 100, 400];
    for (const [distance, expected] of [[100, 2], [100.00003051757812, 0], [150, 0], [150.00001525878906, 1], [0, 2]]) {
      assert.deepEqual([...native_effect_policy(reachPacket(start, true, axis(distance)))], [0, expected, 0, 0, 0, 0, 0, 0]);
      assert.equal(native_effect_policy(reachPacket(start, true, axis(distance), true))[1], expected === 2 ? 0 : expected);
    }
    assert.deepEqual([...native_effect_policy(reachPacket(start, true, [0, 0, 0, start ? 0 : 300, 100, 400]))], [1, 2, 0, 0, 0, 0, 0, 0]);
    assert.equal(native_effect_policy(reachPacket(start, false, [0, 100, 400, 0, 100, 400]))[1], 0);
  }
});
test("component packets reject malformed headers and preserve borrowed and copied ABI buffers", () => {
  for (const operation of [22, 23]) {
    const input = operation === 22 ? componentPacket(6, true, true, true) : reachPacket(true, true, [0, 100, 400, 0, 0, 0]);
    const frozen = input.slice(), result = native_effect_policy(input), owned = result.slice();
    native_effect_policy(componentPacket(0)); assert.deepEqual(input, frozen); assert.deepEqual(result, owned);
    for (let length = 0; length < 32; length++) assert.throws(() => native_effect_policy(input.subarray(0, length)));
    for (const at of [2, 3, 4, 5, 6, 7]) { const invalid = input.slice(); invalid[at] = 2; assert.throws(() => native_effect_policy(invalid)); }
  }
});
