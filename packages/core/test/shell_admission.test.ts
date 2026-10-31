import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = ["runtime_policy.ts", "shell_admission.ts"].map(n => readFileSync(new URL(`../src/${n}`, import.meta.url), "utf8")).join("\n");
const { nscvShellAdmission: derive, native_window_policy: dispatch } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport {nscvShellAdmission};").toString("base64")}`);
function packet(mode: number, size = 64): Uint8Array { const b = new Uint8Array(size); b.set([85, 1, mode]); return b; }
function words(b: Uint8Array, at: number, ...values: number[]): void { const w = new DataView(b.buffer, b.byteOffset, b.byteLength); values.forEach((v, i) => w.setUint32(at + i * 4, v, true)); }
function result(b: Uint8Array): number[] { const r = derive(b); assert.deepEqual(r, dispatch(b)); return Array.from({ length: 4 }, (_, i) => new DataView(r.buffer).getUint32(i * 4, true)); }
function field(kind: number, value: string | Uint8Array, chunk = 256): number {
  const raw = typeof value === "string" ? new TextEncoder().encode(value) : value;
  let state = 0, at = 0;
  do {
    const count = Math.min(chunk, raw.length - at), b = packet(0, 64 + count), w = new DataView(b.buffer);
    words(b, 4, kind, 0, state); w.setBigUint64(16, BigInt(raw.length), true); w.setBigUint64(24, BigInt(at), true); words(b, 32, count, +(at + count === raw.length));
    b.set(raw.subarray(0, 8), 48); b.set(raw.subarray(at, at + count), 64);
    const r = result(b); if (at + count === raw.length) return r[2]!;
    state = r[3]!; at += count;
  } while (true);
}
test("scene fields retain opaque bytes, limits and complete command error precedence", () => {
  for (const chunk of [1, 3, 7, 256]) {
    for (const value of ["ok", "...", "spaces are names", "\t\n", new Uint8Array([255, 254])]) assert.equal(field(0, value, chunk), 0);
    for (const value of ["", ".", "..", "a/b", "a\\b", "a\0b"]) assert.equal(field(0, value, chunk), 1);
    assert.equal(field(0, "x".repeat(513), chunk), 0); assert.equal(field(1, "x".repeat(65), chunk), 1);
    assert.equal(field(3, "", chunk), 0); assert.equal(field(3, "x".repeat(257), chunk), 1);
    assert.equal(field(4, "x".repeat(1025), chunk), 0); assert.equal(field(4, "x".repeat(512) + "\0", chunk), 1);
    assert.equal(field(5, "\n/", chunk), 1); assert.equal(field(5, "/\n", chunk), 1); assert.equal(field(5, "x\n", chunk), 6);
    assert.equal(field(5, "/".repeat(129), chunk), 6); assert.equal(field(9, "\n/", chunk), 6);
  }
});
test("scene URL admission streams whole hosts while preserving permissive HTTP paths", () => {
  for (const chunk of [1, 7, 256]) {
    for (const value of ["http://x", "https://[::1]:a", "http://x/ \0\t", "http://" + "x".repeat(700) + "/ ", "zero://app/a", "file:///a", "zero://" + "x".repeat(700)]) assert.equal(field(6, value, chunk), 0, value);
    for (const value of ["", "http://", "http:///a", "https://a b/path", "http://" + "x".repeat(512) + "\t/path", "zero://", "zero://a b", "file://a\0", "HTTPS://x", "mailto:a"]) assert.equal(field(6, value, chunk), 8, value);
  }
});
test("chrome vocabulary and titles preserve raw-byte and namespace admission", () => {
  for (const value of ["", "play", "app:my_icon-1", "app:app"]) assert.equal(field(8, value, 1), 0);
  for (const value of ["app:", "App:x", "app:a/b", "a.b", "UPPER", "x".repeat(65)]) assert.equal(field(8, value, 1), 1);
  for (const value of ["title", new Uint8Array([255])]) assert.equal(field(7, value), 0);
  for (const value of ["", "a\t", "\x7f", "x".repeat(129)]) assert.equal(field(7, value), 1);
});
test("hierarchy accepts forward chains at capacity and rejects cycles in every position", () => {
  for (const count of [0, 1, 2, 17, 128]) {
    const b = packet(3, 64 + count * 4); words(b, 16, count);
    for (let i = 0; i < count; i++) words(b, 64 + i * 4, i + 1 === count ? 0xffffffff : i + 1);
    assert.equal(result(b)[2], 0);
    for (let i = 0; i < count; i++) { const cycle = b.slice(); words(cycle, 64 + (count - 1) * 4, i); assert.equal(result(cycle)[2], 2); }
  }
});
test("descriptor selection retains label, duplicate, parent, dimension and content precedence", () => {
  const b = packet(2, 160); words(b, 4, 64 | 128 | 1, 1, 0xffffffff); words(b, 16, 1, 1, 1, 1, 1, 6, 8); words(b, 80, 17, 63, 0);
  assert.equal(result(b)[2], 1); words(b, 16, 0); assert.equal(result(b)[2], 3);
  words(b, 8, 0); assert.equal(result(b)[2], 1); words(b, 20, 0); assert.equal(result(b)[2], 2);
  words(b, 12, 1); assert.equal(result(b)[2], 5);
  new DataView(b.buffer).setFloat32(48, 10, true); assert.equal(result(b)[2], 1);
  words(b, 24, 0, 0, 0); assert.equal(result(b)[2], 6); words(b, 36, 0); assert.equal(result(b)[2], 8);
});
test("runtime frame domains retain NaN, infinity, signed zero and strict WebView behavior", () => {
  for (const value of [NaN, Infinity, -Infinity, -1, -0, 0, 0.125]) for (let category = 0; category < 3; category++) {
    const b = packet(11); words(b, 4, category); const w = new DataView(b.buffer);
    [value, 0, 1, 1].forEach((v, i) => w.setFloat32(16 + i * 4, v, true));
    assert.equal(result(b)[2], category === 0 ? value < 0 ? 11 : 0 : category === 1 ? Number.isFinite(value) ? 0 : 17 : value >= 0 ? 0 : 18);
  }
});
test("native-size length admission never rounds high words or reserved identities", () => {
  for (const size of [0n, 1n, 4n, 64n, 65n, 1n << 32n, 9007199254740993n, (1n << 64n) - 1n]) for (let category = 0; category < 3; category++) {
    const b = packet(10); words(b, 4, category); new DataView(b.buffer).setBigUint64(16, size, true); b.set(new TextEncoder().encode("main"), 40);
    assert.equal(result(b)[2], size === 0n ? category === 0 ? 11 : 18 : size > 64n ? category === 0 ? 12 : 19 : category === 2 && size === 4n ? 20 : 0);
  }
});
test("runtime descriptors preserve ordered fields and explicit GPU configuration admission", () => {
  const b = packet(8, 160); words(b, 4, 17, 1); new DataView(b.buffer).setBigUint64(72, 65n, true); words(b, 120, 6);
  assert.equal(result(b)[2], 11); words(b, 64, 1); assert.equal(result(b)[2], 11); words(b, 72, 1); assert.equal(result(b)[2], 16);
  b.set([1, 1, 1, 1, 1, 1], 16); assert.equal(result(b)[2], 0); b[16] = 3; b[19] = 2; assert.equal(result(b)[2], 0);
  for (let at = 16; at < 22; at++) { const invalid = b.slice(); invalid[at] = 0; assert.equal(result(invalid)[2], 16); }
  words(b, 104, 1); assert.equal(result(b)[2], 6); words(b, 80, 65); assert.equal(result(b)[2], 13);
});
test("shell transport rejects truncation, invalid extents and parent slots and retains byteOffset", () => {
  const b = packet(3, 68); words(b, 16, 1); words(b, 64, 0xffffffff);
  for (let n = 0; n < b.length; n++) assert.throws(() => derive(b.subarray(0, n)));
  const invalid = b.slice(); words(invalid, 64, 1); assert.throws(() => derive(invalid));
  const backing = new Uint8Array(b.length + 17); backing.set(b, 5); assert.deepEqual(derive(backing.subarray(5, 5 + b.length)), derive(b));
  const field = packet(0); words(field, 36, 1); words(field, 24, 1); assert.throws(() => derive(field));
  for (const [at, value] of [[0, 84], [1, 2], [2, 12], [3, 1]]) { const copy = b.slice(); copy[at!] = value!; assert.throws(() => derive(copy)); }
});
