import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = ["runtime_policy.ts", "vector_effects.ts"].map(name => readFileSync(new URL(`../src/${name}`, import.meta.url), "utf8")).join("\n");
const { nscvVectorEffects: plan, native_window_policy: policy } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport {nscvVectorEffects};").toString("base64")}`);
function packet(mode: number, count: number, capacity = count, elements: number[][] = []): Uint8Array {
  const stride = mode === 0 ? 72 : 80, bytes = new Uint8Array(16 + count * stride + elements.reduce((n, verbs) => n + verbs.length * 28, 0)), w = new DataView(bytes.buffer);
  bytes.set([63, 1, mode, 5]); w.setUint32(4, count, true); w.setUint32(8, capacity, true); let payload = 16 + count * stride;
  for (let i = 0; i < count; i++) {
    const at = 16 + i * stride; w.setUint32(at, i * 2 + 1, true); w.setUint32(at + 4, i % 2, true);
    if (mode === 0) {
      w.setUint32(at + 8, 1, true); w.setBigUint64(at + 16, 0xf123456789abcdefn, true);
      for (let j = 0; j < 4; j++) w.setFloat32(at + 24 + j * 4, j + 0.125, true);
      w.setFloat32(at + 40, 1, true); w.setFloat32(at + 52, 1, true); w.setFloat32(at + 64, 1.25, true);
      const verbs = elements[i] ?? []; w.setUint32(at + 68, verbs.length, true);
      for (const verb of verbs) { w.setUint32(payload, verb, true); for (let j = 0; j < 6; j++) w.setFloat32(payload + 4 + j * 4, j * -1.25, true); payload += 28; }
    } else {
      w.setBigUint64(at + 8, i === 0 ? 0xffffffffffffffffn : 0n, true);
      for (let j = 0; j < 16; j++) w.setFloat32(at + 16 + j * 4, j * 0.125, true);
      w.setFloat32(at + 24, -1.25, true); w.setFloat32(at + 28, -2.5, true);
    }
  }
  return bytes;
}
function checked(request: Uint8Array) {
  const before = request.slice(), output = plan(request); assert.deepEqual(request, before);
  assert.deepEqual(output, policy(request)); return { output, w: new DataView(output.buffer) };
}
function hash(parts: Uint8Array[]): bigint {
  let h = 14695981039346656037n; for (const part of parts) for (const byte of part) h = BigInt.asUintN(64, (h ^ BigInt(byte)) * 1099511628211n); return h;
}
function size(value: number): Uint8Array { const b = new Uint8Array(8); new DataView(b.buffer).setBigUint64(0, BigInt(value), true); return b; }
const text = (value: string) => new TextEncoder().encode(value);
test("vector plans own full-u64 identities complete geometry counts and raw path hashes", () => {
  const request = packet(0, 2, 2, [[0, 1, 2, 3, 4], [0, 1, 2, 3, 4]]), { output, w } = checked(request);
  assert.equal(w.getUint32(0, true), 2); assert.equal(w.getUint32(4, true), 0);
  assert.deepEqual(Array.from({ length: 8 }, (_, i) => w.getUint32(56 + i * 4, true)), [5, 1, 2, 1, 1, 26, 26, 72]);
  assert.equal(w.getBigUint64(32, true), 0xf123456789abcdefn); assert.equal(w.getFloat32(88, true), 0);
  const requestWire = new DataView(request.buffer), parts = [text("path_geometryfill"), new Uint8Array([1]), request.slice(32, 40), request.slice(56, 80), text("path"), size(5)];
  for (let i = 0; i < 5; i++) { const at = 160 + i * 28; parts.push(size(requestWire.getUint32(at, true)), request.slice(at + 4, at + 28)); }
  parts.push(new Uint8Array(4)); assert.equal(w.getBigUint64(96, true), hash(parts));
  const owned = output.slice(); request.fill(255); assert.deepEqual(output, owned);
});
test("vector admission skips empty paths and preserves error prefixes at every capacity", () => {
  for (const capacity of [0, 1, 2, 3]) {
    const { w } = checked(packet(0, 3, capacity, [[0, 1, 1, 4], [], [0, 1, 1, 4]]));
    assert.equal(w.getUint32(0, true), Math.min(capacity, 2)); assert.equal(w.getUint32(4, true), capacity < 2 ? 1 : 0);
    if (capacity > 1) assert.equal(w.getUint32(104, true), 5);
  }
  for (let verb = 0; verb < 5; verb++) checked(packet(0, 1, 0, [[verb]]));
});
test("effect plans preserve source fingerprint bytes and normalize bounds with f32 order", () => {
  const request = packet(1, 2), { w } = checked(request);
  assert.equal(w.getBigUint64(24, true), 0xffffffffffffffffn);
  assert.equal(w.getUint32(128, true), 0); assert.equal(w.getUint32(132, true), 0); // blur corner defaults
  const f = Math.fround, wire = new DataView(request.buffer), blur = wire.getFloat32(72, true), spread = wire.getFloat32(76, true), margin = f(Math.abs(spread) + blur);
  assert.deepEqual(Array.from({ length: 4 }, (_, i) => w.getFloat32(32 + i * 4, true)), [f(f(-1.25 + 1) - margin), f(f(f(0.125 - 2.5) + 1.125) - margin), f(f(1.25 + margin) + margin), f(f(2.5 + margin) + margin)]);
  assert.equal(w.getBigUint64(80, true), hash([text("shadow"), request.slice(32, 48), request.slice(48, 80), request.slice(80, 96)]));
  for (const capacity of [0, 1, 2, 3]) { const r = checked(packet(1, 2, capacity)); assert.equal(r.w.getUint32(0, true), Math.min(capacity, 2)); assert.equal(r.w.getUint32(4, true), capacity < 2 ? 1 : 0); }
});
test("copied vector resource transport rejects malformed membership before capacity failure", () => {
  for (const mode of [0, 1]) {
    const valid = packet(mode, 2, 0, mode === 0 ? [[0, 1, 4], [0, 1, 4]] : []);
    for (const at of [0, 1, 2, 3, 4, 12, 20]) { const b = valid.slice(); b[at] = 255; assert.throws(() => plan(b), /invalid/); }
    for (let length = 0; length < valid.length; length++) assert.throws(() => plan(valid.slice(0, length)), /invalid/);
    const tail = new Uint8Array(valid.length + 1); tail.set(valid); assert.throws(() => plan(tail), /invalid/);
    const unordered = valid.slice(), u = new DataView(unordered.buffer); u.setUint32(16 + (mode === 0 ? 72 : 80), 1, true); assert.throws(() => plan(unordered), /invalid/);
  }
  const verb = packet(0, 1, 0, [[0, 1, 4]]); new DataView(verb.buffer).setUint32(88, 5, true); assert.throws(() => plan(verb), /invalid/);
  const absent = packet(0, 1, 0, [[0, 1, 4]]); new DataView(absent.buffer).setUint32(24, 0, true); assert.throws(() => plan(absent), /invalid/);
});
test("effect maxNum reproduces separate shadow and backdrop signed-zero rules without changing raw hashes", () => {
  const request = packet(1, 2), wire = new DataView(request.buffer); wire.setFloat32(72, -0, true); wire.setFloat32(76, 0, true); wire.setFloat32(152, -0, true);
  const canonical = checked(request); assert.ok(Object.is(canonical.w.getFloat32(72, true), 0));
  request[3] = 21; const preserved = checked(request); assert.ok(Object.is(preserved.w.getFloat32(72, true), -0));
  assert.ok(Object.is(preserved.w.getFloat32(152, true), 0));
  assert.equal(canonical.w.getBigUint64(80, true), preserved.w.getBigUint64(80, true));
});
