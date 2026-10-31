import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = readFileSync(new URL("../src/markup_scalars.ts", import.meta.url), "utf8");
const { nscvMarkupScalars: scalar } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport { nscvMarkupScalars };").toString("base64")}`);
const minimum = -(1n << 63n), maximum = (1n << 63n) - 1n;
function integers(cap: number, a: bigint, b = 0n): Uint8Array {
  const request = new Uint8Array(48), wire = new DataView(request.buffer);
  request.set([105, 1, cap, 2, 2]); wire.setBigInt64(8, a, true); wire.setBigInt64(16, b, true);
  wire.setFloat32(24, Number(a), true); wire.setFloat32(28, Number(b), true);
  return request;
}
function expectInteger(cap: number, a: bigint, b = 0n): void {
  const expected = cap === 2 ? -a : cap === 4 ? a + b : cap === 5 ? a - b : cap === 6 ? a * b :
    cap === 27 ? a < b ? a : b : cap === 28 ? a > b ? a : b : cap === 29 ? a < 0n ? -a : a : a;
  const actual = scalar(integers(cap, a, b));
  if (expected < minimum || expected > maximum) {
    assert.deepEqual(actual, Uint8Array.of(105, 1, 1, 0, cap === 29 ? 9 : 6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0));
  } else {
    assert.equal(actual[2], 0); assert.equal(actual[3], 2);
    assert.equal(new DataView(actual.buffer).getBigInt64(8, true), expected, `${cap}: ${a}, ${b}`);
  }
}
test("scalar i64 arithmetic matches an independent exact integer oracle", () => {
  const edges = [minimum, minimum + 1n, -(1n << 53n) - 1n, -4294967297n, -65536n, -1n, 0n, 1n,
    65535n, 65536n, 4294967295n, 4294967296n, (1n << 53n) + 1n, maximum - 1n, maximum];
  for (const a of edges) for (const b of edges) for (const cap of [2, 4, 5, 6, 27, 28, 29, 30, 31, 32]) expectInteger(cap, a, b);
  let state = 0x976a2d93b7c8e541n;
  const next = (): bigint => { state = BigInt.asUintN(64, state * 6364136223846793005n + 1442695040888963407n); return BigInt.asIntN(64, state); };
  for (let i = 0; i < 4096; i++) {
    const a = next(), b = next();
    for (const cap of [2, 4, 5, 6, 27, 28, 29]) expectInteger(cap, a, b);
    expectInteger(6, BigInt.asIntN(32, a), BigInt.asIntN(32, b));
  }
  for (let a = -128n; a <= 127n; a++) for (let b = -128n; b <= 127n; b++) expectInteger(6, a, b);
});
test("scalar equality keeps integer precision distinct from f32 ordering", () => {
  for (const cap of [9, 10]) {
    const request = integers(cap, (1n << 53n) + 1n, 1n << 53n);
    assert.equal(scalar(request)[5], cap === 10 ? 1 : 0);
    request[4] = 3; new DataView(request.buffer).setFloat32(16, Number(1n << 53n), true);
    assert.equal(scalar(request)[5], cap === 9 ? 1 : 0);
  }
  const request = integers(11, 16777216n, 16777217n);
  assert.equal(scalar(request)[5], 0);
  request[2] = 12; assert.equal(scalar(request)[5], 1);
});
test("scalar truthiness preserves full integer and string lengths and NaN behavior", () => {
  for (const value of [minimum, -1n, 0n, 1n, maximum]) {
    const request = integers(36, value);
    assert.equal(scalar(request)[5], value === 0n ? 0 : 1);
    request[3] = 1; assert.equal(scalar(request)[5], value === 0n ? 0 : 1);
  }
  for (const value of [-Infinity, -0, 0, 0.5, Infinity, NaN]) {
    const request = integers(36, 0n); request[3] = 3;
    new DataView(request.buffer).setFloat32(24, value, true);
    assert.equal(scalar(request)[5], value === 0 ? 0 : 1);
  }
});
test("scalar string comparison returns owned blocks and validates the entire transport", () => {
  const request = new Uint8Array(48); request.set([105, 1, 9, 1, 1]);
  assert.equal(scalar(request)[2], 2);
  request[5] = 1; request[6] = 1; assert.equal(scalar(request)[5], 1);
  request[2] = 10; assert.equal(scalar(request)[5], 0);
  for (const length of [0, 1, 255, 256]) {
    const block = new Uint8Array(16 + length * 2); block.set([105, 1, 9, 1, 1, 2]);
    const wire = new DataView(block.buffer); wire.setUint16(8, length, true); wire.setUint16(10, length, true);
    for (let i = 0; i < length; i++) block[16 + i] = block[16 + length + i] = i;
    const result = scalar(block), copy = result.slice(); assert.equal(result[5], 1);
    for (const position of [0, length - 1]) if (position >= 0 && length > 0) {
      block[16 + position] ^= 255; assert.equal(scalar(block)[5], 0); block[16 + position] ^= 255;
    }
    block.fill(0); scalar(request); assert.deepEqual(result, copy);
  }
  const good = integers(4, 1n, 2n);
  for (let i = 0; i < good.length; i++) assert.throws(() => scalar(good.subarray(0, i)));
  for (const i of [0, 1, 2, 3, 4, 5, 6, 7, 36, 40, 44]) {
    const bad = good.slice(); bad[i] = 255; assert.throws(() => scalar(bad));
  }
  const block = new Uint8Array(16); block.set([105, 1, 9, 1, 1, 2]);
  new DataView(block.buffer).setUint16(8, 257, true); assert.throws(() => scalar(block));
});
