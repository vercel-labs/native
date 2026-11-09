import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = ["runtime_policy.ts", "status_validation.ts", "system_admission.ts"].map(n => readFileSync(new URL(`../src/${n}`, import.meta.url), "utf8")).join("\n");
const { nscvSystemAdmission: derive, native_window_policy: dispatch } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport { nscvSystemAdmission };").toString("base64")}`);
function packet(mode: number): Uint8Array { const b = new Uint8Array(64); b.set([86, 1, mode]); return b; }
function word(b: Uint8Array, at: number, value: number): void { new DataView(b.buffer, b.byteOffset, b.byteLength).setUint32(at, value, true); }
function wide(b: Uint8Array, at: number, value: bigint): void { new DataView(b.buffer, b.byteOffset, b.byteLength).setBigUint64(at, value, true); }
function result(b: Uint8Array): number[] { const r = derive(b); assert.deepEqual(r, dispatch(b)); return Array.from({length: 4}, (_, i) => new DataView(r.buffer).getUint32(i * 4, true)); }
function field(category: number, value: string | Uint8Array, length?: bigint): number {
  const raw = typeof value === "string" ? new TextEncoder().encode(value) : value;
  const b = new Uint8Array(32 + raw.length); b.set([86, 1, 0, category]); wide(b, 8, length ?? BigInt(raw.length)); b.set(raw, 32);
  return result(b)[2]!;
}
test("system fields retain raw bytes and native empty/size/NUL precedence", () => {
  for (const [category, limit, invalid, large, required] of [[0,4096,1,2,true],[1,4096,3,4,true],[2,512,5,6,false],[3,4096,5,6,false],[4,4096,5,6,false],[5,128,5,6,true],[6,128,5,6,false],[7,256,5,6,false],[8,1024,5,6,true],[9,128,7,8,false],[10,128,7,8,false],[11,128,7,8,false],[12,1024,7,8,false],[13,128,7,8,false],[14,128,7,8,false]] as const) {
    assert.equal(field(category, ""), required ? invalid : 0);
    for (const size of [1, limit]) { const raw = new Uint8Array(size).fill(255); assert.equal(field(category, raw), 0); raw[size - 1] = 0; assert.equal(field(category, raw), invalid); }
    const raw = new Uint8Array(limit).fill(0);
    for (const length of [BigInt(limit + 1), 1n << 32n, 9007199254740993n, (1n << 64n) - 1n]) assert.equal(field(category, raw, length), large);
  }
});
test("clipboard MIME and opaque payload admission preserve permissive slash rules", () => {
  for (const value of ["text/plain", "/", "text", "a/b/c", new Uint8Array([255])]) assert.equal(field(15, value), 0);
  for (const value of ["", "a\\b", "a b", "a\t", "a\0", "a\x7f"]) assert.equal(field(15, value), 10);
  for (const length of [0n, 65536n]) assert.equal(field(16, "", length), 0);
  for (const length of [65537n, 1n << 32n, (1n << 64n) - 1n]) assert.equal(field(16, "", length), 11);
  const b = packet(5); word(b, 32, 10); wide(b, 8, 65537n); assert.equal(result(b)[2], 10);
  word(b, 32, 0); assert.equal(result(b)[2], 11); wide(b, 8, 65536n); assert.equal(result(b)[2], 0);
});
test("file dialogs preserve empty output buffer and ordered declaration errors", () => {
  for (const mode of [1, 2]) {
    const b = packet(mode); word(b, 32, 6); word(b, 36, 5); word(b, 40, 6);
    assert.equal(result(b)[2], 5); wide(b, 8, 1n); assert.equal(result(b)[2], 6);
    word(b, 32, 0); assert.equal(result(b)[2], 5); word(b, 36, 0); assert.equal(result(b)[2], mode === 1 ? 0 : 6);
  }
  const b = packet(3); word(b, 32, 6); word(b, 44, 5); assert.equal(result(b)[2], 6);
  word(b, 32, 0); assert.equal(result(b)[2], 5); word(b, 44, 0); assert.equal(result(b)[2], 0);
});
test("filter continuations preserve delimiters and the exact flattened boundary", () => {
  assert.equal(field(8, "x;"), 5); assert.equal(field(8, "x/y"), 0);
  const b = packet(6); wide(b, 16, 1024n); assert.deepEqual(result(b).slice(2), [0,1025]);
  word(b, 8, 1023); wide(b, 16, 1n); assert.deepEqual(result(b).slice(2), [0,1025]);
  word(b, 8, 1024); assert.equal(result(b)[2], 6);
  word(b, 8, 1025); word(b, 32, 5); assert.equal(result(b)[2], 5);
  word(b, 32, 0); assert.equal(result(b)[2], 6);
});
test("notifications preserve title-first admission, field order and paired commands", () => {
  const b = packet(4); word(b, 32, 8); word(b, 36, 7); word(b, 56, 9);
  assert.equal(result(b)[2], 7); wide(b, 8, 1n); assert.equal(result(b)[2], 8);
  word(b, 32, 0); assert.equal(result(b)[2], 7); word(b, 36, 0); assert.equal(result(b)[2], 0);
  wide(b, 16, 1n); assert.equal(result(b)[2], 7); wide(b, 24, 1n); assert.equal(result(b)[2], 9);
  word(b, 56, 0); assert.equal(result(b)[2], 0);
  for (const value of ["app.notice", "app.check-for-updates", "white space", new Uint8Array([255])]) assert.equal(field(17, value), 0);
  for (const value of ["", ".", "..", "a/b", "a\\b", "a\n", "a\r", "a\t", "a\0"]) assert.equal(field(17, value), 9);
  assert.equal(field(14, "a/command"), 0); assert.equal(field(14, "a\0command"), 7);
});
test("system transport rejects truncation and retains nonzero byte offsets", () => {
  const b = packet(4); wide(b, 8, 1n);
  for (let n = 0; n < 64; n++) assert.throws(() => derive(b.subarray(0,n)));
  const backing = new Uint8Array(80); backing.set(b, 7); assert.deepEqual(derive(backing.subarray(7,71)), derive(b));
  for (const [at,value] of [[0,85],[1,2],[2,7],[3,1],[32,12]]) { const copy = b.slice(); copy[at!] = value!; assert.throws(() => derive(copy)); }
  const f = new Uint8Array(32); f.set([86,1,0,0]); wide(f,8,1n); assert.throws(() => derive(f));
});
