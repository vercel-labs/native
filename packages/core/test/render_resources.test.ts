import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = ["runtime_policy.ts", "render_resources.ts"].map(name => readFileSync(new URL(`../src/${name}`, import.meta.url), "utf8")).join("\n");
const { nscvRenderResources: plan, native_window_policy: policy } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport {nscvRenderResources};").toString("base64")}`);
function hash(bytes: Uint8Array[]): bigint { let value = 14695981039346656037n; for (const part of bytes) for (const byte of part) value = BigInt.asUintN(64, (value ^ BigInt(byte)) * 1099511628211n); return value; }
const text = (value: string) => new TextEncoder().encode(value);
function imagePacket(capacity = 2): Uint8Array {
  const bytes = new Uint8Array(32 + 3 * 48 + 2 * 48), w = new DataView(bytes.buffer); bytes.set([64, 1, 0, 5]); w.setUint32(4, 3, true); w.setUint32(8, capacity, true); w.setUint32(12, 2, true); w.setUint32(16, bytes.length, true);
  for (let i = 0; i < 3; i++) { const at = 32 + i * 48; w.setUint32(at, i * 2, true); w.setUint32(at + 4, 1, true); w.setBigUint64(at + 8, i === 2 ? 0n : 0xffffffffffffffffn, true); w.setBigUint64(at + 16, 0xf123456789abcdefn, true); w.setFloat32(at + 24, i * 2, true); w.setFloat32(at + 28, -0, true); w.setFloat32(at + 32, 7.25, true); w.setFloat32(at + 36, 9.5, true); }
  for (let i = 0; i < 2; i++) { const at = 176 + i * 48; w.setBigUint64(at, 0xf123456789abcdefn, true); w.setBigUint64(at + 8, 0xf123456789abcdefn, true); w.setBigUint64(at + 16, 0xffffffffffffffffn, true); w.setUint32(at + 32, i === 0 ? 65537 : 0, true); }
  return bytes;
}
function checked(request: Uint8Array): Uint8Array { const before = request.slice(), output = plan(request); assert.deepEqual(request, before); assert.deepEqual(output, policy(request)); return output; }
function resume(request: Uint8Array, prefix: Uint8Array, pixels: Uint8Array): Uint8Array {
  const w = new DataView(request.buffer), out = new Uint8Array(w.getUint32(16, true) + prefix.length + pixels.length), next = new DataView(out.buffer), p = new DataView(prefix.buffer); out.set(request.subarray(0, w.getUint32(16, true))); next.setUint32(20, p.getUint32(8, true), true); next.setUint32(24, prefix.length, true); next.setUint32(28, pixels.length, true); out.set(prefix, w.getUint32(16, true)); out.set(pixels, w.getUint32(16, true) + prefix.length); return out;
}
test("image owner streams all raw pixels keeps full-u64 dimensions first matches and coalesces copied output", () => {
  let request = imagePacket(); const pixels = Uint8Array.from({ length: 65537 }, (_, i) => i * 37 & 255);
  for (let draw = 0; draw < 3; draw++) {
    const pending = checked(request), p = new DataView(pending.buffer); assert.equal(p.getUint32(4, true), 2); assert.equal(p.getUint32(8, true), draw); assert.equal(p.getUint32(12, true), 0); assert.equal(p.getUint32(16, true), 0);
    request = resume(request, pending, pixels.subarray(0, 65536)); const rest = checked(request); assert.equal(new DataView(rest.buffer).getUint32(16, true), 65536); request = resume(request, rest, pixels.subarray(65536));
  }
  const result = checked(request), out = new DataView(result.buffer); assert.equal(out.getUint32(0, true), 1); assert.equal(out.getUint32(4, true), 0); assert.equal(out.getUint32(56, true), 3); assert.equal(out.getUint32(44, true), 0); assert.equal(out.getBigUint64(64, true), 0xf123456789abcdefn); assert.equal(out.getBigUint64(72, true), 0xffffffffffffffffn);
  assert.deepEqual([out.getFloat32(84, true), out.getFloat32(88, true), out.getFloat32(92, true), out.getFloat32(96, true)], [0, -0, 11.25, 9.5]); assert.equal(out.getBigUint64(100, true), hash([text("image_texture"), request.slice(48, 56), request.slice(184, 200), pixels]));
  const copy = result.slice(); request.fill(255); assert.deepEqual(result, copy);
});
test("image stamped resources omit pixel reads and capacity failures retain all accepted prefixes", () => {
  for (const capacity of [0, 1, 2]) {
    const request = imagePacket(capacity), w = new DataView(request.buffer); w.setBigUint64(200, 0xffffffffffffffffn, true);
    const result = checked(request), out = new DataView(result.buffer); assert.equal(out.getUint32(0, true), Math.min(1, capacity)); assert.equal(out.getUint32(4, true), capacity === 0 ? 1 : 0);
    if (capacity > 0) assert.equal(out.getBigUint64(100, true), hash([text("image_texture"), request.slice(48, 56), request.slice(184, 208)]));
  }
});
function commandPacket(mode: number, capacity = 1): Uint8Array {
  const bytes = new Uint8Array(196), w = new DataView(bytes.buffer); bytes.set([64, 1, mode, 5]); w.setUint32(4, 1, true); w.setUint32(8, capacity, true); w.setUint32(16, bytes.length, true);
  w.setUint32(36, 14, true); w.setBigUint64(40, 0xffffffffffffffffn, true); w.setUint32(48, 1, true); w.setBigUint64(56, 0xf123456789abcdefn, true);
  w.setFloat32(80, -0, true); w.setFloat32(84, 1, true); w.setFloat32(88, 7.25, true); w.setFloat32(92, 9.5, true); w.setFloat32(96, 0.5, true); w.setFloat32(120, 1, true); w.setFloat32(132, 1, true); w.setUint32(144, 176, true); w.setUint32(148, 20, true);
  w.setFloat32(176, -0, true); w.setFloat32(180, 1, true); w.setFloat32(184, -7.25, true); w.setFloat32(188, 9.5, true); w.setFloat32(192, 0.125, true); return bytes;
}
test("general resource derivation normalizes raw effect bounds and preserves raw fingerprint identity", () => {
  const request = commandPacket(2), result = checked(request), out = new DataView(result.buffer); assert.equal(out.getUint32(32, true), 4); assert.equal(out.getBigUint64(48, true), 0xffffffffffffffffn); assert.equal(out.getBigUint64(104, true), hash([text("blur"), request.slice(176)])); assert.deepEqual([out.getFloat32(56, true), out.getFloat32(60, true), out.getFloat32(64, true), out.getFloat32(68, true)], [-7.375, 0.875, 7.5, 9.75]);
});
test("resource wire rejects malformed facts payload membership and pixel windows before capacity failure", () => {
  for (const mode of [0, 1, 2]) {
    const valid = mode === 0 ? imagePacket(0) : commandPacket(mode, 0);
    for (const at of [0, 1, 2, 3, 4, 16, 20, 24, 28]) { const bytes = valid.slice(); bytes[at] = 255; assert.throws(() => plan(bytes), /invalid/); }
    for (let length = 0; length < valid.length; length++) assert.throws(() => plan(valid.slice(0, length)), /invalid/);
    const extra = new Uint8Array(valid.length + 1); extra.set(valid); assert.throws(() => plan(extra), /invalid/);
  }
  const request = imagePacket(), pending = checked(request);
  assert.throws(() => plan(resume(request, pending, new Uint8Array(65537))), /invalid/);
  assert.throws(() => plan(resume(request, pending, new Uint8Array())), /invalid/);
  const invalid = commandPacket(2); new DataView(invalid.buffer).setUint32(148, 19, true); assert.throws(() => plan(invalid), /invalid/);
});
