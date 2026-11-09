import assert from "node:assert/strict";
import test from "node:test";
import { native_stream_policy } from "../src/stream_policy.ts";
interface Slot { used: boolean; key: Uint8Array }
const key = (s: string) => new TextEncoder().encode(s);
const empty = (): Slot[] => Array.from({ length: 16 }, () => ({ used: false, key: key("") }));
function declaration(slots: Slot[], name: Uint8Array, fetch: boolean | null, file = 0, effect = 0): Uint8Array {
  const head = fetch === null ? [1, name.length] : [0, +fetch, file, effect, name.length];
  return new Uint8Array([...head, ...name, ...slots.flatMap(s => [+s.used, s.key.length, ...s.key])]);
}
test("stream admission preserves opaque first-match lookup, first-free slots and family asymmetry", () => {
  const names = [key(""), key("source"), key("café"), new Uint8Array([0, 255]), new Uint8Array(255).fill(255)];
  const slots = empty();
  for (let occupied = 0; occupied <= 16; occupied++) {
    slots.forEach((s, i) => { s.used = i < occupied; s.key = names[i % names.length]!; });
    for (const name of names) {
      const matching = slots.findIndex(s => s.used && Buffer.from(s.key).equals(name));
      assert.deepEqual([...native_stream_policy(declaration(slots, name, null))], [matching < 0 ? 255 : matching]);
      for (const fetch of [false, true]) for (const file of [0, 1]) for (const effect of [0, 1]) {
        const blocked = name.length > 0 && (matching >= 0 || file === 1 || fetch && effect === 1);
        const free = slots.findIndex(s => !s.used);
        assert.deepEqual([...native_stream_policy(declaration(slots, name, fetch, file, effect))], [blocked || free < 0 ? 255 : free]);
      }
    }
  }
  for (let hole = 0; hole < 16; hole++) {
    slots.forEach((s, i) => { s.used = i !== hole; s.key = key("other"); });
    assert.equal(native_stream_policy(declaration(slots, key("new"), false))[0], hole);
  }
});
test("line loss and terminal routes match every native control combination", () => {
  for (const tag of [0, 127, 255]) for (const a of [0, 1]) for (const b of [0, 1]) for (const c of [0, 1]) for (const d of [0, 1]) {
    assert.deepEqual([...native_stream_policy(new Uint8Array([2, a, b, c, d, tag]))], [tag, 0, +(b || a && (c || d)), 0, 0]);
    const success = b === 1 && (a === 0 || c === 0);
    assert.deepEqual([...native_stream_policy(new Uint8Array([3, a, b, c, tag, 255 - tag]))], [success ? tag : 255 - tag, success ? a ? 2 : 1 : 0, 0, 1, +(!success && b === 1)]);
    const damaged = a || b || c;
    assert.deepEqual([...native_stream_policy(new Uint8Array([4, a, b, c, d, tag, 255 - tag]))], [d && !damaged ? tag : 255 - tag, +(d && !damaged), +damaged, 1, +(d && damaged)]);
  }
});
test("malformed stream records refuse plans, and copied results own their bytes", () => {
  for (const request of [declaration(empty(), key("source"), true), declaration(empty(), key("source"), null), new Uint8Array([2, 1, 0, 0, 0, 127]), new Uint8Array([3, 1, 1, 0, 127, 255]), new Uint8Array([4, 0, 0, 0, 1, 127, 255])]) {
    for (let n = 0; n < request.length; n++) assert.throws(() => native_stream_policy(request.subarray(0, n)));
    assert.throws(() => native_stream_policy(new Uint8Array([...request, 0])));
    const result = native_stream_policy(request), copy = result.slice(); request.fill(0);
    native_stream_policy(new Uint8Array([3, 0, 1, 0, 0, 1])); assert.deepEqual(result, copy);
  }
  for (const op of [2, 3, 4]) for (let offset = 1; offset < (op === 3 ? 4 : 5); offset++) {
    const request = new Uint8Array(op === 4 ? 7 : 6); request[0] = op; request[offset] = 2;
    assert.throws(() => native_stream_policy(request), /fact/);
  }
  const table = declaration(empty(), key("x"), false); table[6] = 2; assert.throws(() => native_stream_policy(table), /slot/);
  assert.throws(() => native_stream_policy(new Uint8Array([255])), /operation/);
});
