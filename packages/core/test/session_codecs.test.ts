import assert from "node:assert/strict";
import test from "node:test";
import { sessionCodecPolicy } from "../src/session_codecs.ts";
const enc = new TextEncoder(), dec = new TextDecoder();
const scalar = (n: bigint, width = 8) => { const b = new Uint8Array(width); for (let i = 0; i < width; i++) { b[i] = Number(n & 255n); n >>= 8n; } return b; };
function request(record: number, decode: boolean, payload: Uint8Array, slots: [string, Uint8Array][] = [], name = "", capacity = 1048576, bits = 64) {
  const label = enc.encode(name), rows = slots.map(([key, bytes]) => { const path = enc.encode(key), out = new Uint8Array(8 + path.length + bytes.length), w = new DataView(out.buffer); w.setUint32(0, path.length, true); w.setUint32(4, bytes.length, true); out.set(path, 8); out.set(bytes, 8 + path.length); return out; });
  const b = new Uint8Array(24 + label.length + rows.reduce((n, row) => n + row.length, 0) + payload.length), w = new DataView(b.buffer);
  b.set([30, 1, decode ? 1 : 0, record]); w.setUint32(4, capacity, true); w.setUint32(8, bits, true); w.setUint32(12, label.length, true); w.setUint32(16, slots.length, true); w.setUint32(20, payload.length, true); b.set(label, 24);
  let at = 24 + label.length; for (const row of rows) { b.set(row, at); at += row.length; } b.set(payload, at); return b;
}
function run(b: Uint8Array) {
  const saved = b.slice(), out = sessionCodecPolicy(b), w = new DataView(out.buffer); assert.deepEqual(b, saved);
  const nameLength = w.getUint32(12, true), name = dec.decode(out.subarray(16, 16 + nameLength));
  return { status: w.getUint32(4, true), count: w.getUint32(8, true), name, body: out.slice(16 + nameLength), out };
}
function spans(out: ReturnType<typeof run>, payload: Uint8Array) {
  const w = new DataView(out.body.buffer), rows = new Map<string, Uint8Array>(); let at = 0;
  for (let i = 0; i < out.count; i++) { const length = w.getUint32(at, true); at += 4; const path = dec.decode(out.body.subarray(at, at + length)); at += length; const first = w.getUint32(at, true), count = w.getUint32(at + 4, true); at += 8; assert.ok(first + count <= payload.length); rows.set(path, payload.subarray(first, first + count)); }
  assert.equal(at, out.body.length); return rows;
}
const concat = (...parts: Uint8Array[]) => { const b = new Uint8Array(parts.reduce((n, p) => n + p.length, 0)); let at = 0; for (const p of parts) { b.set(p, at); at += p.length; } return b; };
const str = (b: Uint8Array) => concat(scalar(BigInt(b.length), 4), b);

test("session codecs retain all wide bits and exact written prefixes at every capacity", () => {
  const values = [0n, 1n, 4294967295n, 9007199254740993n, 18446744073709551615n];
  for (const n of values) {
    const slots: [string, Uint8Array][] = [["event_ordinal", scalar(n)], ["frame_index", scalar(n ^ 1n)], ["fingerprint", scalar(~n)]], expected = concat(...slots.map(s => s[1]));
    for (let capacity = 0; capacity <= 25; capacity++) {
      const out = run(request(4, false, new Uint8Array(0), slots, "", capacity));
      assert.equal(out.status, capacity < 24 ? 2 : 0); assert.deepEqual(out.body, expected.subarray(0, Math.min(24, Math.floor(capacity / 8) * 8)));
    }
    for (let length = 0; length <= 25; length++) {
      const bytes = length <= 24 ? expected.slice(0, length) : concat(expected, scalar(0n, 1)), out = run(request(4, true, bytes));
      assert.equal(out.status, length === 24 ? 0 : 1); assert.equal(out.count, Math.min(3, Math.floor(length / 8)));
    }
  }
});
test("all stable event tags map independently of native union order", () => {
  for (const [name, tag] of [["app_start", 1], ["app_activated", 2], ["app_deactivated", 3], ["frame_requested", 5], ["app_shutdown", 6], ["wake", 16]] as const) {
    assert.deepEqual(run(request(2, false, new Uint8Array(0), [], name)).body, scalar(BigInt(tag), 1));
    const out = run(request(2, true, scalar(BigInt(tag), 1))); assert.equal(out.status, 0); assert.equal(out.name, name);
  }
  for (const tag of [0, 30, 127, 255]) assert.equal(run(request(2, true, scalar(BigInt(tag), 1))).status, 1);
});
test("drop decode retains completed borrowed paths before malformed later paths or trailing bytes", () => {
  const raw = new Uint8Array([255, 0, 239, 187, 191]), first = concat(scalar(17n, 1), scalar(1n), str(enc.encode("canvas")), scalar(0n, 1), scalar(2n, 2), str(raw));
  for (const suffix of [new Uint8Array(0), scalar(3n, 4), concat(scalar(3n, 4), new Uint8Array([1, 2]))]) {
    const payload = concat(first, suffix), out = run(request(2, true, payload)); assert.equal(out.status, 1); assert.deepEqual(spans(out, payload).get("paths/0"), raw); assert.equal(spans(out, payload).has("paths/1"), false);
  }
  const payload = concat(first, str(new Uint8Array(0))), out = run(request(2, true, payload)); assert.equal(out.status, 0); assert.deepEqual(spans(out, payload).get("paths/0"), raw);
  assert.equal(run(request(2, true, concat(payload, scalar(0n, 1)))).status, 1);
});
test("optional selection rejects native-width overflow in order and retains floating bit patterns", () => {
  const slots: [string, Uint8Array][] = [["window_id", scalar(1n)], ["label", enc.encode("main")], ["id", scalar(2n)], ["action", scalar(6n, 4)], ["text", new Uint8Array([0, 255])], ["selection", scalar(1n, 1)], ["selection.start", scalar(4294967296n)], ["selection.end", scalar(18446744073709551615n)]];
  const encoded = run(request(2, false, new Uint8Array(0), slots, "widget_accessibility_action")); assert.equal(encoded.status, 0);
  assert.equal(run(request(2, true, encoded.body, [], "", 0, 64)).status, 0);
  const out = run(request(2, true, encoded.body, [], "", 0, 32)); assert.equal(out.status, 1); assert.equal(spans(out, encoded.body).has("selection.end"), false);
  for (const n of [0n, 2147483648n, 2139095040n, 4286578688n, 2143294004n]) {
    const bits = scalar(n, 4), payload = concat(scalar(3n), str(new Uint8Array(0)), bits, scalar(1n), scalar(2n)), result = run(request(5, true, payload));
    assert.equal(result.status, 0); assert.deepEqual(spans(result, payload).get("scale"), bits);
  }
});
test("journal storage transport rejects malformed extents and copied results survive future calls", () => {
  const valid = request(2, true, scalar(1n, 1)), out = run(valid).out, saved = out.slice();
  for (let i = 0; i < 24; i++) assert.throws(() => sessionCodecPolicy(valid.subarray(0, i)));
  for (const [at, value] of [[0, 29], [1, 2], [2, 2], [3, 0], [3, 8], [8, 16], [16, 1], [20, 9]]) { const b = valid.slice(); b[at] = value; assert.throws(() => sessionCodecPolicy(b)); }
  run(request(2, true, scalar(255n, 1))); valid.fill(0); assert.deepEqual(out, saved);
});
