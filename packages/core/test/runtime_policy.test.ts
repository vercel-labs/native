import { native_status_policy } from "../src/runtime_policy.ts";
import { native_theme_policy } from "../src/runtime_policy.ts";
import assert from "node:assert/strict";
import test from "node:test";
import { native_timer_policy, native_db_policy, native_effect_policy } from "../src/runtime_policy.ts";

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
  assert.throws(() => native_window_policy(new Uint8Array([6])), /operation/);
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
  }
  for (const bytes of [[], [3], [1], [2], [1, 3, 1, 0, 0, 0, 0, 0], [1, 0, 0, 0, 0, 0, 0, 0], [1, 0, 1, 0, 2, 0, 0, 0], [2, 2, 0, 0, 0], [2, 0, 0, 0, 3]]) {
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
